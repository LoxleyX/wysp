//! Global Hotkey - Push-to-talk style
//!
//! Hold Ctrl+Shift+Space to record, release to stop and transcribe.
//! - X11: Uses XGrabKey for global hotkey capture
//! - Wayland: Uses evdev for direct keyboard input (requires input group)
//! - Windows: Uses RegisterHotKey (TODO)

const std = @import("std");
const builtin = @import("builtin");

pub const HotkeyError = error{
    InitFailed,
    NotSupported,
};

/// Platform-specific hotkey implementation
pub const Hotkey = switch (builtin.os.tag) {
    .linux => LinuxHotkey,
    .windows => WindowsHotkey,
    else => UnsupportedHotkey,
};

// Module-level state (for compatibility with existing code)
var instance: ?*Hotkey = null;
var instance_storage: Hotkey = undefined;

/// Initialize hotkey system
pub fn init() !void {
    instance_storage = try Hotkey.init();
    instance = &instance_storage;
    try instance_storage.start();
}

/// Set callbacks for press and release
pub fn setCallbacks(press_cb: *const fn () void, release_cb: *const fn () void) void {
    if (instance) |inst| {
        inst.setCallbacks(press_cb, release_cb);
    }
}

/// Cleanup
pub fn deinit() void {
    if (instance) |inst| {
        inst.deinit();
        instance = null;
    }
}

// =============================================================================
// Linux Implementation (X11 + Wayland/evdev fallback)
// =============================================================================

const LinuxHotkey = struct {
    backend: Backend,
    on_press: ?*const fn () void = null,
    on_release: ?*const fn () void = null,
    running: bool = false,
    event_thread: ?std.Thread = null,

    const Self = @This();

    // Global pointer for thread access (threads can't safely use stack pointers)
    var g_instance: ?*Self = null;

    const Backend = union(enum) {
        x11: X11Backend,
        evdev: EvdevBackend,
    };

    const x11 = @cImport({
        @cInclude("X11/Xlib.h");
        @cInclude("X11/keysym.h");
    });

    const X11Backend = struct {
        display: *x11.Display,
        root_window: x11.Window,
        target_keycode: x11.KeyCode,
    };

    const EvdevBackend = struct {
        fd: std.posix.fd_t,
    };

    // evdev input event structure
    const InputEvent = extern struct {
        time: extern struct {
            tv_sec: isize,
            tv_usec: isize,
        },
        type: u16,
        code: u16,
        value: i32,
    };

    // evdev constants
    const EV_KEY: u16 = 0x01;
    const KEY_LEFTCTRL: u16 = 29;
    const KEY_RIGHTCTRL: u16 = 97;
    const KEY_LEFTSHIFT: u16 = 42;
    const KEY_RIGHTSHIFT: u16 = 54;
    const KEY_SPACE: u16 = 57;

    pub fn init() !Self {
        // Try X11 first
        if (x11.XOpenDisplay(null)) |display| {
            const root_window = x11.DefaultRootWindow(display);
            const keysym = x11.XK_space;
            const target_keycode = x11.XKeysymToKeycode(display, keysym);

            // Grab key with Ctrl+Shift modifier (and variants for caps/num lock)
            const mod = x11.ControlMask | x11.ShiftMask;
            const mod_combos = [_]c_uint{
                mod,
                mod | x11.Mod2Mask,
                mod | x11.LockMask,
                mod | x11.Mod2Mask | x11.LockMask,
            };

            for (mod_combos) |mods| {
                _ = x11.XGrabKey(
                    display,
                    target_keycode,
                    mods,
                    root_window,
                    x11.True,
                    x11.GrabModeAsync,
                    x11.GrabModeAsync,
                );
            }

            return Self{
                .backend = .{ .x11 = .{
                    .display = display,
                    .root_window = root_window,
                    .target_keycode = target_keycode,
                } },
            };
        }

        // Fall back to evdev for Wayland
        const fd = try findKeyboardDevice();
        return Self{
            .backend = .{ .evdev = .{ .fd = fd } },
        };
    }

    /// Start the event loop thread (call after instance is in final memory location)
    pub fn start(self: *Self) !void {
        g_instance = self;
        self.running = true;
        self.event_thread = try std.Thread.spawn(.{}, eventLoop, .{});
    }

    fn eventLoop() void {
        const self = g_instance orelse return;
        switch (self.backend) {
            .x11 => x11EventLoopImpl(self),
            .evdev => evdevEventLoopImpl(self),
        }
    }

    pub fn setCallbacks(self: *Self, press_cb: *const fn () void, release_cb: *const fn () void) void {
        self.on_press = press_cb;
        self.on_release = release_cb;
    }

    pub fn deinit(self: *Self) void {
        self.running = false;
        g_instance = null;

        if (self.event_thread) |t| {
            t.join();
        }

        switch (self.backend) {
            .x11 => |b| {
                const mod = x11.ControlMask | x11.ShiftMask;
                const mod_combos = [_]c_uint{
                    mod,
                    mod | x11.Mod2Mask,
                    mod | x11.LockMask,
                    mod | x11.Mod2Mask | x11.LockMask,
                };
                for (mod_combos) |mods| {
                    _ = x11.XUngrabKey(b.display, b.target_keycode, mods, b.root_window);
                }
                _ = x11.XCloseDisplay(b.display);
            },
            .evdev => |b| {
                std.posix.close(b.fd);
            },
        }
    }

    fn x11EventLoopImpl(self: *Self) void {
        const b = switch (self.backend) {
            .x11 => |*backend| backend,
            else => return,
        };

        var event: x11.XEvent = undefined;

        while (self.running) {
            if (x11.XPending(b.display) > 0) {
                _ = x11.XNextEvent(b.display, &event);

                if (event.type == x11.KeyPress) {
                    const key_event = event.xkey;
                    if (key_event.keycode == b.target_keycode) {
                        if (self.on_press) |cb| cb();
                    }
                } else if (event.type == x11.KeyRelease) {
                    const key_event = event.xkey;
                    if (key_event.keycode == b.target_keycode) {
                        // Check for key repeat
                        if (x11.XPending(b.display) > 0) {
                            var next_event: x11.XEvent = undefined;
                            _ = x11.XPeekEvent(b.display, &next_event);
                            if (next_event.type == x11.KeyPress and
                                next_event.xkey.keycode == key_event.keycode and
                                next_event.xkey.time == key_event.time)
                            {
                                _ = x11.XNextEvent(b.display, &next_event);
                                continue;
                            }
                        }
                        if (self.on_release) |cb| cb();
                    }
                }
            } else {
                std.time.sleep(10 * std.time.ns_per_ms);
            }
        }
    }

    fn evdevEventLoopImpl(self: *Self) void {
        const b = switch (self.backend) {
            .evdev => |*backend| backend,
            else => return,
        };

        var ctrl_held = false;
        var shift_held = false;
        var space_held = false;
        var hotkey_active = false;

        var buf: [@sizeOf(InputEvent) * 64]u8 = undefined;

        while (self.running) {
            const bytes_read = std.posix.read(b.fd, &buf) catch |err| {
                if (err == error.WouldBlock) {
                    std.time.sleep(10 * std.time.ns_per_ms);
                    continue;
                }
                break;
            };

            const events = std.mem.bytesAsSlice(InputEvent, buf[0..bytes_read]);
            for (events) |ev| {
                if (ev.type != EV_KEY) continue;

                const pressed = ev.value == 1;
                const released = ev.value == 0;

                switch (ev.code) {
                    KEY_LEFTCTRL, KEY_RIGHTCTRL => ctrl_held = pressed or (ctrl_held and !released),
                    KEY_LEFTSHIFT, KEY_RIGHTSHIFT => shift_held = pressed or (shift_held and !released),
                    KEY_SPACE => space_held = pressed or (space_held and !released),
                    else => {},
                }

                // Check hotkey state
                const hotkey_pressed = ctrl_held and shift_held and space_held;

                if (hotkey_pressed and !hotkey_active) {
                    hotkey_active = true;
                    if (self.on_press) |cb| cb();
                } else if (!hotkey_pressed and hotkey_active) {
                    hotkey_active = false;
                    if (self.on_release) |cb| cb();
                }
            }
        }
    }

    fn findKeyboardDevice() !std.posix.fd_t {
        // Try to find a keyboard device in /dev/input/
        var dir = std.fs.openDirAbsolute("/dev/input", .{ .iterate = true }) catch {
            return HotkeyError.InitFailed;
        };
        defer dir.close();

        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            if (!std.mem.startsWith(u8, entry.name, "event")) continue;

            var path_buf: [64]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "/dev/input/{s}", .{entry.name}) catch continue;
            const path_z = std.mem.sliceTo(path_buf[0..path.len :0], 0);

            const fd = std.posix.open(path_z, .{ .ACCMODE = .RDONLY, .NONBLOCK = true }, 0) catch continue;

            // Check if this device has keyboard capabilities using ioctl
            // For simplicity, try to read from it - if it works, use it
            // A more robust check would use EVIOCGBIT ioctl
            if (isKeyboardDevice(fd)) {
                return fd;
            }
            std.posix.close(fd);
        }

        return HotkeyError.InitFailed;
    }

    fn isKeyboardDevice(fd: std.posix.fd_t) bool {
        // Use EVIOCGBIT to check for keyboard keys
        // ioctl number for EVIOCGBIT(EV_KEY, size) = 0x80000000 | (size << 16) | ('E' << 8) | 0x21
        const EVIOCGBIT_KEY = 0x80004521 | (@as(u32, 96) << 16); // 96 bytes = 768 bits for keys

        var bits: [96]u8 = undefined;
        const result = std.os.linux.ioctl(fd, EVIOCGBIT_KEY, @intFromPtr(&bits));
        if (result != 0) return false;

        // Check if space key (57) is supported - indicates keyboard
        const space_byte = KEY_SPACE / 8;
        const space_bit: u3 = @intCast(KEY_SPACE % 8);
        return (bits[space_byte] & (@as(u8, 1) << space_bit)) != 0;
    }
};

// =============================================================================
// Windows Implementation (Low-level keyboard hook)
// =============================================================================

const WindowsHotkey = struct {
    on_press: ?*const fn () void = null,
    on_release: ?*const fn () void = null,
    running: bool = false,
    event_thread: ?std.Thread = null,

    const Self = @This();

    const win32 = struct {
        const DWORD = u32;
        const WPARAM = usize;
        const LPARAM = isize;
        const LRESULT = isize;
        const HHOOK = ?*anyopaque;
        const HINSTANCE = ?*anyopaque;
        const HWND = ?*anyopaque;
        const BOOL = i32;

        const WH_KEYBOARD_LL: i32 = 13;
        const WM_KEYDOWN: WPARAM = 0x0100;
        const WM_KEYUP: WPARAM = 0x0101;
        const WM_SYSKEYDOWN: WPARAM = 0x0104;
        const WM_SYSKEYUP: WPARAM = 0x0105;
        const HC_ACTION: i32 = 0;

        const VK_CONTROL: DWORD = 0x11;
        const VK_SHIFT: DWORD = 0x10;
        const VK_SPACE: DWORD = 0x20;

        const KBDLLHOOKSTRUCT = extern struct {
            vkCode: DWORD,
            scanCode: DWORD,
            flags: DWORD,
            time: DWORD,
            dwExtraInfo: usize,
        };

        const MSG = extern struct {
            hwnd: HWND,
            message: u32,
            wParam: WPARAM,
            lParam: LPARAM,
            time: DWORD,
            pt: extern struct { x: i32, y: i32 },
        };

        const HOOKPROC = *const fn (code: i32, wParam: WPARAM, lParam: LPARAM) callconv(.C) LRESULT;

        extern "user32" fn SetWindowsHookExA(idHook: i32, lpfn: HOOKPROC, hmod: HINSTANCE, dwThreadId: DWORD) callconv(.C) HHOOK;
        extern "user32" fn UnhookWindowsHookEx(hhk: HHOOK) callconv(.C) BOOL;
        extern "user32" fn CallNextHookEx(hhk: HHOOK, nCode: i32, wParam: WPARAM, lParam: LPARAM) callconv(.C) LRESULT;
        extern "user32" fn GetMessageA(lpMsg: *MSG, hWnd: HWND, wMsgFilterMin: u32, wMsgFilterMax: u32) callconv(.C) BOOL;
        extern "user32" fn TranslateMessage(lpMsg: *const MSG) callconv(.C) BOOL;
        extern "user32" fn DispatchMessageA(lpMsg: *const MSG) callconv(.C) LRESULT;
        extern "user32" fn PostThreadMessageA(idThread: DWORD, Msg: u32, wParam: WPARAM, lParam: LPARAM) callconv(.C) BOOL;
        extern "kernel32" fn GetCurrentThreadId() callconv(.C) DWORD;
    };

    // Global state for hook callback (Windows hooks require global state)
    var g_hook: win32.HHOOK = null;
    var g_instance: ?*Self = null;
    var g_ctrl_held: bool = false;
    var g_shift_held: bool = false;
    var g_space_held: bool = false;
    var g_hotkey_active: bool = false;
    var g_thread_id: win32.DWORD = 0;

    pub fn init() !Self {
        var self = Self{};
        self.running = true;
        self.event_thread = try std.Thread.spawn(.{}, messageLoop, .{&self});

        // Wait for hook to be installed
        std.time.sleep(100 * std.time.ns_per_ms);

        if (g_hook == null) {
            self.running = false;
            if (self.event_thread) |t| t.join();
            return HotkeyError.InitFailed;
        }

        return self;
    }

    pub fn setCallbacks(self: *Self, press_cb: *const fn () void, release_cb: *const fn () void) void {
        self.on_press = press_cb;
        self.on_release = release_cb;
        g_instance = self;
    }

    pub fn deinit(self: *Self) void {
        self.running = false;

        // Post quit message to message loop
        if (g_thread_id != 0) {
            _ = win32.PostThreadMessageA(g_thread_id, 0x0012, 0, 0); // WM_QUIT
        }

        if (self.event_thread) |t| {
            t.join();
        }

        if (g_hook) |hook| {
            _ = win32.UnhookWindowsHookEx(hook);
            g_hook = null;
        }

        g_instance = null;
    }

    fn messageLoop(self: *Self) void {
        _ = self;
        g_thread_id = win32.GetCurrentThreadId();

        // Install low-level keyboard hook
        g_hook = win32.SetWindowsHookExA(win32.WH_KEYBOARD_LL, keyboardProc, null, 0);

        if (g_hook == null) return;

        // Message loop (required for hook to work)
        var msg: win32.MSG = undefined;
        while (win32.GetMessageA(&msg, null, 0, 0) > 0) {
            _ = win32.TranslateMessage(&msg);
            _ = win32.DispatchMessageA(&msg);
        }
    }

    fn keyboardProc(nCode: i32, wParam: win32.WPARAM, lParam: win32.LPARAM) callconv(.C) win32.LRESULT {
        if (nCode == win32.HC_ACTION) {
            const kbd: *win32.KBDLLHOOKSTRUCT = @ptrFromInt(@as(usize, @bitCast(lParam)));
            const pressed = (wParam == win32.WM_KEYDOWN or wParam == win32.WM_SYSKEYDOWN);
            const released = (wParam == win32.WM_KEYUP or wParam == win32.WM_SYSKEYUP);

            switch (kbd.vkCode) {
                win32.VK_CONTROL => g_ctrl_held = pressed or (g_ctrl_held and !released),
                win32.VK_SHIFT => g_shift_held = pressed or (g_shift_held and !released),
                win32.VK_SPACE => g_space_held = pressed or (g_space_held and !released),
                else => {},
            }

            const hotkey_pressed = g_ctrl_held and g_shift_held and g_space_held;

            if (hotkey_pressed and !g_hotkey_active) {
                g_hotkey_active = true;
                if (g_instance) |inst| {
                    if (inst.on_press) |cb| cb();
                }
            } else if (!hotkey_pressed and g_hotkey_active) {
                g_hotkey_active = false;
                if (g_instance) |inst| {
                    if (inst.on_release) |cb| cb();
                }
            }
        }

        return win32.CallNextHookEx(g_hook, nCode, wParam, lParam);
    }
};

// =============================================================================
// Unsupported Platform
// =============================================================================

const UnsupportedHotkey = struct {
    const Self = @This();

    pub fn init() !Self {
        return HotkeyError.NotSupported;
    }

    pub fn setCallbacks(self: *Self, press_cb: *const fn () void, release_cb: *const fn () void) void {
        _ = self;
        _ = press_cb;
        _ = release_cb;
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }
};
