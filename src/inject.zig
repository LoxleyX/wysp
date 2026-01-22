//! Text injection - types text at current cursor position
//!
//! Cross-platform implementation:
//! - Linux X11: XTest extension (no external dependencies)
//! - Linux Wayland: wtype/ydotool fallback (TODO: native)
//! - macOS: CGEventPost (TODO)
//! - Windows: SendInput (TODO)

const std = @import("std");
const builtin = @import("builtin");

pub const InjectError = error{
    InitFailed,
    InjectFailed,
    NotSupported,
    OutOfMemory,
};

/// Platform-specific text injector
pub const TextInjector = switch (builtin.os.tag) {
    .linux => LinuxInjector,
    .macos => MacOSInjector,
    .windows => WindowsInjector,
    else => UnsupportedInjector,
};

// =============================================================================
// Linux Implementation (X11 XTest)
// =============================================================================

const LinuxInjector = struct {
    allocator: std.mem.Allocator,
    display: ?*x11.Display,
    use_fallback: bool,

    const Self = @This();

    const x11 = @cImport({
        @cInclude("X11/Xlib.h");
        @cInclude("X11/keysym.h");
        @cInclude("X11/extensions/XTest.h");
    });

    pub fn init(allocator: std.mem.Allocator) !Self {
        // Try to open X11 display
        const display = x11.XOpenDisplay(null);

        if (display == null) {
            // No X11 (probably Wayland), try fallback tools
            if (toolExists(allocator, "wtype") or toolExists(allocator, "ydotool")) {
                return Self{
                    .allocator = allocator,
                    .display = null,
                    .use_fallback = true,
                };
            }
            return InjectError.InitFailed;
        }

        return Self{
            .allocator = allocator,
            .display = display,
            .use_fallback = false,
        };
    }

    pub fn typeText(self: *Self, text: []const u8) !void {
        if (self.use_fallback) {
            return self.typeTextFallback(text);
        }

        const display = self.display orelse return InjectError.InitFailed;

        for (text) |char| {
            self.typeChar(display, char);
        }

        // Flush to ensure all events are sent
        _ = x11.XFlush(display);
    }

    fn typeChar(self: *Self, display: *x11.Display, char: u8) void {
        _ = self;

        // Convert ASCII to KeySym
        const keysym: x11.KeySym = if (char >= 32 and char <= 126)
            @intCast(char)
        else if (char == '\n')
            x11.XK_Return
        else if (char == '\t')
            x11.XK_Tab
        else
            return; // Skip unsupported characters

        // Get keycode for this keysym
        const keycode = x11.XKeysymToKeycode(display, keysym);
        if (keycode == 0) return;

        // Check if shift is needed (uppercase letters, symbols)
        const needs_shift = (char >= 'A' and char <= 'Z') or
            (std.mem.indexOfScalar(u8, "~!@#$%^&*()_+{}|:\"<>?", char) != null);

        if (needs_shift) {
            _ = x11.XTestFakeKeyEvent(display, x11.XKeysymToKeycode(display, x11.XK_Shift_L), 1, 0);
        }

        // Key press
        _ = x11.XTestFakeKeyEvent(display, keycode, 1, 0);
        // Key release
        _ = x11.XTestFakeKeyEvent(display, keycode, 0, 0);

        if (needs_shift) {
            _ = x11.XTestFakeKeyEvent(display, x11.XKeysymToKeycode(display, x11.XK_Shift_L), 0, 0);
        }
    }

    fn typeTextFallback(self: *Self, text: []const u8) !void {
        // Use wtype or ydotool as fallback (Wayland)
        const tool: []const u8 = if (toolExists(self.allocator, "wtype"))
            "wtype"
        else if (toolExists(self.allocator, "ydotool"))
            "ydotool"
        else
            return InjectError.NotSupported;

        const argv: []const []const u8 = if (std.mem.eql(u8, tool, "wtype"))
            &[_][]const u8{ "wtype", "--", text }
        else
            &[_][]const u8{ "ydotool", "type", "--", text };

        var child = std.process.Child.init(argv, self.allocator);
        child.stderr_behavior = .Ignore;
        child.stdout_behavior = .Ignore;

        _ = try child.spawnAndWait();
    }

    pub fn deinit(self: *Self) void {
        if (self.display) |d| {
            _ = x11.XCloseDisplay(d);
        }
    }

    fn toolExists(allocator: std.mem.Allocator, tool: []const u8) bool {
        var child = std.process.Child.init(&[_][]const u8{ "which", tool }, allocator);
        child.stderr_behavior = .Ignore;
        child.stdout_behavior = .Ignore;

        const result = child.spawnAndWait() catch return false;
        return result.Exited == 0;
    }
};

// =============================================================================
// macOS Implementation (TODO)
// =============================================================================

const MacOSInjector = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        // TODO: Implement CGEventPost
        return Self{ .allocator = allocator };
    }

    pub fn typeText(self: *Self, text: []const u8) !void {
        _ = self;
        _ = text;
        // TODO: Use CGEventCreateKeyboardEvent + CGEventPost
        return InjectError.NotSupported;
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }
};

// =============================================================================
// Windows Implementation (SendInput)
// =============================================================================

const WindowsInjector = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    const win32 = struct {
        const WORD = u16;
        const DWORD = u32;
        const LONG = i32;
        const ULONG_PTR = usize;

        const INPUT_KEYBOARD: DWORD = 1;
        const KEYEVENTF_KEYUP: DWORD = 0x0002;
        const KEYEVENTF_UNICODE: DWORD = 0x0004;

        const KEYBDINPUT = extern struct {
            wVk: WORD = 0,
            wScan: WORD = 0,
            dwFlags: DWORD = 0,
            time: DWORD = 0,
            dwExtraInfo: ULONG_PTR = 0,
        };

        const INPUT = extern struct {
            type: DWORD,
            data: extern union {
                ki: KEYBDINPUT,
                padding: [64]u8, // Ensure struct is large enough
            },
        };

        extern "user32" fn SendInput(cInputs: u32, pInputs: [*]INPUT, cbSize: i32) callconv(.C) u32;
    };

    pub fn init(allocator: std.mem.Allocator) !Self {
        return Self{ .allocator = allocator };
    }

    pub fn typeText(self: *Self, text: []const u8) !void {
        _ = self;

        // Convert UTF-8 to UTF-16 for Windows
        var inputs: [256]win32.INPUT = undefined;
        var input_count: usize = 0;

        var i: usize = 0;
        while (i < text.len and input_count + 2 <= inputs.len) {
            const codepoint = std.unicode.utf8Decode(text[i..@min(i + 4, text.len)]) catch {
                i += 1;
                continue;
            };
            const len = std.unicode.utf8CodepointSequenceLength(text[i]) catch 1;
            i += len;

            // Handle BMP characters (most common)
            if (codepoint <= 0xFFFF) {
                // Key down
                inputs[input_count] = .{
                    .type = win32.INPUT_KEYBOARD,
                    .data = .{ .ki = .{
                        .wScan = @intCast(codepoint),
                        .dwFlags = win32.KEYEVENTF_UNICODE,
                    } },
                };
                input_count += 1;

                // Key up
                inputs[input_count] = .{
                    .type = win32.INPUT_KEYBOARD,
                    .data = .{ .ki = .{
                        .wScan = @intCast(codepoint),
                        .dwFlags = win32.KEYEVENTF_UNICODE | win32.KEYEVENTF_KEYUP,
                    } },
                };
                input_count += 1;
            }
            // TODO: Handle surrogate pairs for codepoints > 0xFFFF
        }

        if (input_count > 0) {
            const result = win32.SendInput(@intCast(input_count), &inputs, @sizeOf(win32.INPUT));
            if (result == 0) {
                return InjectError.InjectFailed;
            }
        }
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }
};

// =============================================================================
// Unsupported Platform
// =============================================================================

const UnsupportedInjector = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        _ = allocator;
        return InjectError.NotSupported;
    }

    pub fn typeText(self: *Self, text: []const u8) !void {
        _ = self;
        _ = text;
        return InjectError.NotSupported;
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }
};
