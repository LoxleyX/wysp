//! Recording Overlay
//!
//! A small floating window that appears when recording.
//! Shows a visual indicator that wysp is listening.
//! - Linux: GTK window
//! - Windows: Win32 layered window

const std = @import("std");
const builtin = @import("builtin");

pub const OverlayError = error{
    InitFailed,
    NotSupported,
};

/// Platform-specific overlay implementation
const OverlayImpl = switch (builtin.os.tag) {
    .linux => LinuxOverlay,
    .windows => WindowsOverlay,
    else => UnsupportedOverlay,
};

var overlay_instance: ?OverlayImpl = null;

/// Initialize GTK (Linux only, call once at startup)
pub fn initGtk() void {
    if (builtin.os.tag == .linux) {
        LinuxOverlay.initGtk();
    }
}

/// Create the overlay window (hidden initially)
pub fn create() !void {
    overlay_instance = try OverlayImpl.init();
}

/// Show the overlay
pub fn show() void {
    if (overlay_instance) |*inst| {
        inst.show();
    }
}

/// Hide the overlay
pub fn hide() void {
    if (overlay_instance) |*inst| {
        inst.hide();
    }
}

/// Update the overlay text
pub fn setText(text: []const u8) void {
    if (overlay_instance) |*inst| {
        inst.setText(text);
    }
}

/// Cleanup
pub fn destroy() void {
    if (overlay_instance) |*inst| {
        inst.deinit();
        overlay_instance = null;
    }
}

/// Process events (call periodically from main loop)
pub fn processEvents() void {
    if (overlay_instance) |*inst| {
        inst.processEvents();
    }
}

// =============================================================================
// Linux Implementation (GTK)
// =============================================================================

const LinuxOverlay = struct {
    window: ?*gtk.GtkWidget,
    label: ?*gtk.GtkWidget,

    const Self = @This();

    const gtk = @cImport({
        @cInclude("gtk/gtk.h");
    });

    var gtk_initialized: bool = false;

    pub fn initGtk() void {
        if (!gtk_initialized) {
            _ = gtk.gtk_init_check(null, null);
            gtk_initialized = true;
        }
    }

    pub fn init() !Self {
        LinuxOverlay.initGtk();

        const window = gtk.gtk_window_new(gtk.GTK_WINDOW_POPUP);
        if (window == null) return OverlayError.InitFailed;

        gtk.gtk_window_set_title(@ptrCast(window), "Wysp");
        gtk.gtk_window_set_default_size(@ptrCast(window), 200, 60);
        gtk.gtk_window_set_position(@ptrCast(window), gtk.GTK_WIN_POS_CENTER);
        gtk.gtk_window_set_keep_above(@ptrCast(window), 1);
        gtk.gtk_window_set_decorated(@ptrCast(window), 0);
        gtk.gtk_window_set_skip_taskbar_hint(@ptrCast(window), 1);
        gtk.gtk_window_set_skip_pager_hint(@ptrCast(window), 1);

        const screen = gtk.gtk_widget_get_screen(window);
        const visual = gtk.gdk_screen_get_rgba_visual(screen);
        if (visual != null) {
            gtk.gtk_widget_set_visual(window, visual);
        }
        gtk.gtk_widget_set_app_paintable(window, 1);

        const label = gtk.gtk_label_new("Recording...");
        if (label) |lbl| {
            const css_provider = gtk.gtk_css_provider_new();
            const css =
                \\window {
                \\  background-color: rgba(0, 0, 0, 0.8);
                \\  border-radius: 10px;
                \\}
                \\label {
                \\  color: #00ffcc;
                \\  font-size: 18px;
                \\  font-weight: bold;
                \\  padding: 15px 30px;
                \\}
            ;
            _ = gtk.gtk_css_provider_load_from_data(css_provider, css, -1, null);

            const style_context = gtk.gtk_widget_get_style_context(window);
            gtk.gtk_style_context_add_provider(
                style_context,
                @ptrCast(css_provider),
                gtk.GTK_STYLE_PROVIDER_PRIORITY_APPLICATION,
            );

            const label_style = gtk.gtk_widget_get_style_context(lbl);
            gtk.gtk_style_context_add_provider(
                label_style,
                @ptrCast(css_provider),
                gtk.GTK_STYLE_PROVIDER_PRIORITY_APPLICATION,
            );

            gtk.gtk_container_add(@ptrCast(window), lbl);
        }

        return Self{
            .window = window,
            .label = label,
        };
    }

    // Thread-safe state for GTK updates
    var pending_show: bool = false;
    var pending_hide: bool = false;
    var pending_text: ?[]const u8 = null;

    fn idleShowOverlay(_: ?*anyopaque) callconv(.C) c_int {
        if (pending_show) {
            pending_show = false;
            if (overlay_instance) |*inst| {
                inst.doShow();
            }
        }
        return 0;
    }

    fn idleHideOverlay(_: ?*anyopaque) callconv(.C) c_int {
        if (pending_hide) {
            pending_hide = false;
            if (overlay_instance) |*inst| {
                inst.doHide();
            }
        }
        return 0;
    }

    fn idleSetText(_: ?*anyopaque) callconv(.C) c_int {
        if (pending_text) |text| {
            pending_text = null;
            if (overlay_instance) |*inst| {
                inst.doSetText(text);
            }
        }
        return 0;
    }

    pub fn show(_: *Self) void {
        pending_show = true;
        _ = gtk.g_idle_add(@ptrCast(&idleShowOverlay), null);
    }

    pub fn hide(_: *Self) void {
        pending_hide = true;
        _ = gtk.g_idle_add(@ptrCast(&idleHideOverlay), null);
    }

    pub fn setText(_: *Self, text: []const u8) void {
        pending_text = text;
        _ = gtk.g_idle_add(@ptrCast(&idleSetText), null);
    }

    fn doShow(self: *Self) void {
        if (self.window) |win| {
            gtk.gtk_widget_show_all(win);
        }
    }

    fn doHide(self: *Self) void {
        if (self.window) |win| {
            gtk.gtk_widget_hide(win);
        }
    }

    fn doSetText(self: *Self, text: []const u8) void {
        if (self.label) |lbl| {
            const text_z = std.heap.c_allocator.dupeZ(u8, text) catch return;
            defer std.heap.c_allocator.free(text_z);
            gtk.gtk_label_set_text(@ptrCast(lbl), text_z);
        }
    }

    pub fn processEvents(_: *Self) void {
        while (gtk.gtk_events_pending() != 0) {
            _ = gtk.gtk_main_iteration();
        }
    }

    pub fn deinit(self: *Self) void {
        if (self.window) |win| {
            gtk.gtk_widget_destroy(win);
            self.window = null;
            self.label = null;
        }
    }
};

// =============================================================================
// Windows Implementation (Win32 layered window)
// =============================================================================

const WindowsOverlay = struct {
    hwnd: ?win32.HWND,
    visible: bool,
    text: [128]u8,
    text_len: usize,

    const Self = @This();

    const win32 = struct {
        const DWORD = u32;
        const UINT = u32;
        const WORD = u16;
        const BOOL = i32;
        const HWND = ?*anyopaque;
        const HDC = ?*anyopaque;
        const HBRUSH = ?*anyopaque;
        const HFONT = ?*anyopaque;
        const HINSTANCE = ?*anyopaque;
        const WPARAM = usize;
        const LPARAM = isize;
        const LRESULT = isize;
        const COLORREF = DWORD;

        const WS_EX_LAYERED: DWORD = 0x00080000;
        const WS_EX_TOPMOST: DWORD = 0x00000008;
        const WS_EX_TOOLWINDOW: DWORD = 0x00000080;
        const WS_POPUP: DWORD = 0x80000000;
        const WS_VISIBLE: DWORD = 0x10000000;

        const SW_SHOW: i32 = 5;
        const SW_HIDE: i32 = 0;
        const LWA_ALPHA: DWORD = 2;
        const DT_CENTER: UINT = 1;
        const DT_VCENTER: UINT = 4;
        const DT_SINGLELINE: UINT = 32;
        const TRANSPARENT: i32 = 1;
        const FW_BOLD: i32 = 700;

        const WM_PAINT: UINT = 0x000F;

        const RECT = extern struct { left: i32, top: i32, right: i32, bottom: i32 };
        const PAINTSTRUCT = extern struct {
            hdc: HDC,
            fErase: BOOL,
            rcPaint: RECT,
            fRestore: BOOL,
            fIncUpdate: BOOL,
            rgbReserved: [32]u8,
        };

        const WNDCLASSEXA = extern struct {
            cbSize: UINT = @sizeOf(WNDCLASSEXA),
            style: UINT = 0,
            lpfnWndProc: *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.C) LRESULT,
            cbClsExtra: i32 = 0,
            cbWndExtra: i32 = 0,
            hInstance: HINSTANCE = null,
            hIcon: ?*anyopaque = null,
            hCursor: ?*anyopaque = null,
            hbrBackground: HBRUSH = null,
            lpszMenuName: ?[*:0]const u8 = null,
            lpszClassName: [*:0]const u8,
            hIconSm: ?*anyopaque = null,
        };

        const MSG = extern struct {
            hwnd: HWND,
            message: UINT,
            wParam: WPARAM,
            lParam: LPARAM,
            time: DWORD,
            pt: extern struct { x: i32, y: i32 },
        };

        extern "user32" fn RegisterClassExA(lpwcx: *const WNDCLASSEXA) callconv(.C) WORD;
        extern "user32" fn CreateWindowExA(dwExStyle: DWORD, lpClassName: [*:0]const u8, lpWindowName: [*:0]const u8, dwStyle: DWORD, x: i32, y: i32, nWidth: i32, nHeight: i32, hWndParent: HWND, hMenu: ?*anyopaque, hInstance: HINSTANCE, lpParam: ?*anyopaque) callconv(.C) HWND;
        extern "user32" fn DestroyWindow(hWnd: HWND) callconv(.C) BOOL;
        extern "user32" fn ShowWindow(hWnd: HWND, nCmdShow: i32) callconv(.C) BOOL;
        extern "user32" fn SetLayeredWindowAttributes(hwnd: HWND, crKey: COLORREF, bAlpha: u8, dwFlags: DWORD) callconv(.C) BOOL;
        extern "user32" fn InvalidateRect(hWnd: HWND, lpRect: ?*const RECT, bErase: BOOL) callconv(.C) BOOL;
        extern "user32" fn DefWindowProcA(hWnd: HWND, Msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.C) LRESULT;
        extern "user32" fn BeginPaint(hWnd: HWND, lpPaint: *PAINTSTRUCT) callconv(.C) HDC;
        extern "user32" fn EndPaint(hWnd: HWND, lpPaint: *const PAINTSTRUCT) callconv(.C) BOOL;
        extern "user32" fn GetClientRect(hWnd: HWND, lpRect: *RECT) callconv(.C) BOOL;
        extern "user32" fn FillRect(hDC: HDC, lprc: *const RECT, hbr: HBRUSH) callconv(.C) i32;
        extern "user32" fn DrawTextA(hdc: HDC, lpchText: [*]const u8, cchText: i32, lprc: *RECT, format: UINT) callconv(.C) i32;
        extern "user32" fn GetSystemMetrics(nIndex: i32) callconv(.C) i32;
        extern "user32" fn PeekMessageA(lpMsg: *MSG, hWnd: HWND, wMsgFilterMin: UINT, wMsgFilterMax: UINT, wRemoveMsg: UINT) callconv(.C) BOOL;
        extern "user32" fn TranslateMessage(lpMsg: *const MSG) callconv(.C) BOOL;
        extern "user32" fn DispatchMessageA(lpMsg: *const MSG) callconv(.C) LRESULT;
        extern "gdi32" fn CreateSolidBrush(color: COLORREF) callconv(.C) HBRUSH;
        extern "gdi32" fn DeleteObject(ho: ?*anyopaque) callconv(.C) BOOL;
        extern "gdi32" fn SetTextColor(hdc: HDC, color: COLORREF) callconv(.C) COLORREF;
        extern "gdi32" fn SetBkMode(hdc: HDC, mode: i32) callconv(.C) i32;
        extern "gdi32" fn CreateFontA(cHeight: i32, cWidth: i32, cEscapement: i32, cOrientation: i32, cWeight: i32, bItalic: DWORD, bUnderline: DWORD, bStrikeOut: DWORD, iCharSet: DWORD, iOutPrecision: DWORD, iClipPrecision: DWORD, iQuality: DWORD, iPitchAndFamily: DWORD, pszFaceName: [*:0]const u8) callconv(.C) HFONT;
        extern "gdi32" fn SelectObject(hdc: HDC, h: ?*anyopaque) callconv(.C) ?*anyopaque;
        extern "kernel32" fn GetModuleHandleA(lpModuleName: ?[*:0]const u8) callconv(.C) HINSTANCE;

        fn RGB(r: u8, g: u8, b: u8) COLORREF {
            return @as(COLORREF, r) | (@as(COLORREF, g) << 8) | (@as(COLORREF, b) << 16);
        }
    };

    var g_self: ?*Self = null;

    pub fn init() !Self {
        const hInstance = win32.GetModuleHandleA(null);

        const wc = win32.WNDCLASSEXA{
            .lpfnWndProc = wndProc,
            .hInstance = hInstance,
            .hbrBackground = win32.CreateSolidBrush(win32.RGB(20, 20, 20)),
            .lpszClassName = "WyspOverlay",
        };

        _ = win32.RegisterClassExA(&wc);

        // Center on screen
        const screen_width = win32.GetSystemMetrics(0); // SM_CXSCREEN
        const screen_height = win32.GetSystemMetrics(1); // SM_CYSCREEN
        const width: i32 = 200;
        const height: i32 = 60;
        const x = @divTrunc(screen_width - width, 2);
        const y = @divTrunc(screen_height - height, 2);

        const hwnd = win32.CreateWindowExA(
            win32.WS_EX_LAYERED | win32.WS_EX_TOPMOST | win32.WS_EX_TOOLWINDOW,
            "WyspOverlay",
            "Wysp",
            win32.WS_POPUP,
            x,
            y,
            width,
            height,
            null,
            null,
            hInstance,
            null,
        );

        if (hwnd == null) return OverlayError.InitFailed;

        _ = win32.SetLayeredWindowAttributes(hwnd, 0, 200, win32.LWA_ALPHA);

        var self = Self{
            .hwnd = hwnd,
            .visible = false,
            .text = undefined,
            .text_len = 0,
        };

        const default_text = "Recording...";
        @memcpy(self.text[0..default_text.len], default_text);
        self.text_len = default_text.len;

        g_self = &self;

        return self;
    }

    pub fn show(self: *Self) void {
        if (self.hwnd) |hwnd| {
            _ = win32.ShowWindow(hwnd, win32.SW_SHOW);
            self.visible = true;
        }
    }

    pub fn hide(self: *Self) void {
        if (self.hwnd) |hwnd| {
            _ = win32.ShowWindow(hwnd, win32.SW_HIDE);
            self.visible = false;
        }
    }

    pub fn setText(self: *Self, text: []const u8) void {
        const len = @min(text.len, 127);
        @memcpy(self.text[0..len], text[0..len]);
        self.text_len = len;
        if (self.hwnd) |hwnd| {
            _ = win32.InvalidateRect(hwnd, null, 1);
        }
    }

    pub fn processEvents(_: *Self) void {
        var msg: win32.MSG = undefined;
        while (win32.PeekMessageA(&msg, null, 0, 0, 1) != 0) {
            _ = win32.TranslateMessage(&msg);
            _ = win32.DispatchMessageA(&msg);
        }
    }

    pub fn deinit(self: *Self) void {
        if (self.hwnd) |hwnd| {
            _ = win32.DestroyWindow(hwnd);
            self.hwnd = null;
        }
        g_self = null;
    }

    fn wndProc(hwnd: win32.HWND, msg: win32.UINT, wParam: win32.WPARAM, lParam: win32.LPARAM) callconv(.C) win32.LRESULT {
        switch (msg) {
            win32.WM_PAINT => {
                var ps: win32.PAINTSTRUCT = undefined;
                const hdc = win32.BeginPaint(hwnd, &ps);

                var rect: win32.RECT = undefined;
                _ = win32.GetClientRect(hwnd, &rect);

                // Draw background
                const brush = win32.CreateSolidBrush(win32.RGB(20, 20, 20));
                _ = win32.FillRect(hdc, &rect, brush);
                _ = win32.DeleteObject(brush);

                // Draw text
                _ = win32.SetBkMode(hdc, win32.TRANSPARENT);
                _ = win32.SetTextColor(hdc, win32.RGB(0, 255, 204)); // Cyan

                const font = win32.CreateFontA(24, 0, 0, 0, win32.FW_BOLD, 0, 0, 0, 0, 0, 0, 0, 0, "Segoe UI");
                const old_font = win32.SelectObject(hdc, font);

                if (g_self) |self| {
                    _ = win32.DrawTextA(hdc, &self.text, @intCast(self.text_len), &rect, win32.DT_CENTER | win32.DT_VCENTER | win32.DT_SINGLELINE);
                }

                _ = win32.SelectObject(hdc, old_font);
                _ = win32.DeleteObject(font);

                _ = win32.EndPaint(hwnd, &ps);
                return 0;
            },
            else => return win32.DefWindowProcA(hwnd, msg, wParam, lParam),
        }
    }
};

// =============================================================================
// Unsupported Platform
// =============================================================================

const UnsupportedOverlay = struct {
    const Self = @This();

    pub fn init() !Self {
        return OverlayError.NotSupported;
    }

    pub fn show(_: *Self) void {}
    pub fn hide(_: *Self) void {}
    pub fn setText(_: *Self, _: []const u8) void {}
    pub fn processEvents(_: *Self) void {}
    pub fn deinit(_: *Self) void {}
};
