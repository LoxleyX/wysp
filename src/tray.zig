//! System Tray Icon
//!
//! Shows wysp in the system tray with a menu.
//! - Linux: GTK StatusIcon
//! - Windows: Shell_NotifyIcon

const std = @import("std");
const builtin = @import("builtin");

pub const TrayError = error{
    InitFailed,
    NotSupported,
};

/// Platform-specific tray implementation
const TrayImpl = switch (builtin.os.tag) {
    .linux => LinuxTray,
    .windows => WindowsTray,
    else => UnsupportedTray,
};

var tray_instance: ?TrayImpl = null;
var quit_callback: ?*const fn () void = null;

/// Create tray icon
pub fn create() !void {
    tray_instance = try TrayImpl.init();
}

/// Set quit callback
pub fn onQuitClick(callback: *const fn () void) void {
    quit_callback = callback;
    if (tray_instance) |*inst| {
        inst.setQuitCallback(callback);
    }
}

/// Update tooltip
pub fn setTooltip(text: []const u8) void {
    if (tray_instance) |*inst| {
        inst.setTooltip(text);
    }
}

/// Set recording state (changes icon)
pub fn setRecording(recording: bool) void {
    if (tray_instance) |*inst| {
        inst.setRecording(recording);
    }
}

/// Cleanup
pub fn destroy() void {
    if (tray_instance) |*inst| {
        inst.deinit();
        tray_instance = null;
    }
}

// =============================================================================
// Linux Implementation (GTK StatusIcon)
// =============================================================================

const LinuxTray = struct {
    status_icon: ?*gtk.GtkStatusIcon,
    menu: ?*gtk.GtkMenu,
    icon_path: ?[]const u8,
    recording_icon_path: ?[]const u8,

    const Self = @This();
    const overlay = @import("overlay.zig");
    const config = @import("config.zig");

    const gtk = @cImport({
        @cInclude("gtk/gtk.h");
    });

    pub fn init() !Self {
        overlay.initGtk();

        // Try to find custom logo in various locations
        const home = std.posix.getenv("HOME") orelse "/tmp";
        var icon_path: ?[]const u8 = null;
        var recording_icon_path: ?[]const u8 = null;

        // Build paths to check
        var home_icon_buf: [256]u8 = undefined;
        var home_rec_buf: [256]u8 = undefined;

        const home_icon = std.fmt.bufPrint(&home_icon_buf, "{s}/.wysp/logo.png", .{home}) catch null;
        const home_rec = std.fmt.bufPrint(&home_rec_buf, "{s}/.wysp/logo-recording.png", .{home}) catch null;

        // Check for logo: current dir, then ~/.wysp/
        if (std.fs.cwd().access("logo.png", .{})) |_| {
            icon_path = "logo.png";
        } else |_| {
            if (home_icon) |p| {
                if (std.fs.cwd().access(p, .{})) |_| {
                    icon_path = p;
                } else |_| {}
            }
        }

        // Check for recording logo
        if (std.fs.cwd().access("logo-recording.png", .{})) |_| {
            recording_icon_path = "logo-recording.png";
        } else |_| {
            if (home_rec) |p| {
                if (std.fs.cwd().access(p, .{})) |_| {
                    recording_icon_path = p;
                } else |_| {}
            }
        }

        var status_icon: ?*gtk.GtkStatusIcon = null;

        if (icon_path) |path| {
            const path_z = std.heap.c_allocator.dupeZ(u8, path) catch null;
            if (path_z) |pz| {
                defer std.heap.c_allocator.free(pz);
                status_icon = gtk.gtk_status_icon_new_from_file(pz.ptr);
            }
        }

        if (status_icon == null) {
            status_icon = gtk.gtk_status_icon_new_from_icon_name("audio-input-microphone");
        }
        if (status_icon == null) {
            status_icon = gtk.gtk_status_icon_new_from_icon_name("applications-multimedia");
        }

        if (status_icon == null) {
            return TrayError.InitFailed;
        }

        // Set tooltip with configured hotkey
        const main = @import("main.zig");
        var tooltip_buf: [128]u8 = [_]u8{0} ** 128;
        const hotkey_str = main.getHotkeyString() orelse "Ctrl+Shift+Space";
        defer if (!std.mem.eql(u8, hotkey_str, "Ctrl+Shift+Space")) std.heap.c_allocator.free(@constCast(hotkey_str));
        _ = std.fmt.bufPrint(&tooltip_buf, "Wysp - Hold {s} to record", .{hotkey_str}) catch {};
        gtk.gtk_status_icon_set_tooltip_text(status_icon, @ptrCast(&tooltip_buf));
        gtk.gtk_status_icon_set_visible(status_icon, 1);

        _ = gtk.g_signal_connect_data(
            @ptrCast(status_icon),
            "popup-menu",
            @ptrCast(&onPopupMenu),
            null,
            null,
            0,
        );

        // Menu is built dynamically in onPopupMenu
        const menu: ?*gtk.GtkMenu = null;

        return Self{
            .status_icon = status_icon,
            .menu = menu,
            .icon_path = icon_path,
            .recording_icon_path = recording_icon_path,
        };
    }

    pub fn setQuitCallback(_: *Self, _: *const fn () void) void {
        // Callback stored in module-level quit_callback
    }

    pub fn setTooltip(self: *Self, text: []const u8) void {
        if (self.status_icon) |icon| {
            const text_z = std.heap.c_allocator.dupeZ(u8, text) catch return;
            defer std.heap.c_allocator.free(text_z);
            gtk.gtk_status_icon_set_tooltip_text(icon, text_z);
        }
    }

    pub fn setRecording(self: *Self, recording: bool) void {
        if (self.status_icon) |icon| {
            if (recording) {
                // Use custom recording icon if available
                if (self.recording_icon_path) |path| {
                    const path_z = std.heap.c_allocator.dupeZ(u8, path) catch null;
                    if (path_z) |pz| {
                        defer std.heap.c_allocator.free(pz);
                        gtk.gtk_status_icon_set_from_file(icon, pz.ptr);
                    }
                } else {
                    gtk.gtk_status_icon_set_from_icon_name(icon, "media-record");
                }
                gtk.gtk_status_icon_set_tooltip_text(icon, "Wysp - Recording...");
            } else {
                // Use custom icon if available
                if (self.icon_path) |path| {
                    const path_z = std.heap.c_allocator.dupeZ(u8, path) catch null;
                    if (path_z) |pz| {
                        defer std.heap.c_allocator.free(pz);
                        gtk.gtk_status_icon_set_from_file(icon, pz.ptr);
                    }
                } else {
                    gtk.gtk_status_icon_set_from_icon_name(icon, "audio-input-microphone");
                }
                // Set tooltip with configured hotkey
                const main = @import("main.zig");
                var tooltip_buf: [128]u8 = [_]u8{0} ** 128;
                const hotkey_str = main.getHotkeyString() orelse "Ctrl+Shift+Space";
                defer if (!std.mem.eql(u8, hotkey_str, "Ctrl+Shift+Space")) std.heap.c_allocator.free(@constCast(hotkey_str));
                _ = std.fmt.bufPrint(&tooltip_buf, "Wysp - Hold {s} to record", .{hotkey_str}) catch {};
                gtk.gtk_status_icon_set_tooltip_text(icon, @ptrCast(&tooltip_buf));
            }
        }
    }

    pub fn deinit(self: *Self) void {
        if (self.menu) |m| {
            gtk.gtk_widget_destroy(@ptrCast(m));
            self.menu = null;
        }
        if (self.status_icon) |icon| {
            gtk.g_object_unref(icon);
            self.status_icon = null;
        }
    }

    fn onPopupMenu(_: ?*gtk.GtkStatusIcon, button: gtk.guint, activate_time: gtk.guint32, _: ?*anyopaque) callconv(.C) void {
        const main = @import("main.zig");

        // Build menu dynamically each time
        const menu: *gtk.GtkMenu = @ptrCast(gtk.gtk_menu_new());

        // Hotkey display (disabled item showing current hotkey)
        var hotkey_label_buf: [128]u8 = [_]u8{0} ** 128;
        const hotkey_str = main.getHotkeyString() orelse "Ctrl+Shift+Space";
        defer if (!std.mem.eql(u8, hotkey_str, "Ctrl+Shift+Space")) std.heap.c_allocator.free(@constCast(hotkey_str));
        _ = std.fmt.bufPrint(&hotkey_label_buf, "Hotkey: {s}", .{hotkey_str}) catch {};
        const hotkey_item = gtk.gtk_menu_item_new_with_label(@ptrCast(&hotkey_label_buf));
        gtk.gtk_widget_set_sensitive(hotkey_item, 0); // Disabled - just for display
        gtk.gtk_menu_shell_append(@ptrCast(menu), hotkey_item);

        // Edit config option
        const config_item = gtk.gtk_menu_item_new_with_label("Edit Config (~/.wysp/config.json)");
        _ = gtk.g_signal_connect_data(@ptrCast(config_item), "activate", @ptrCast(&onEditConfig), null, null, 0);
        gtk.gtk_menu_shell_append(@ptrCast(menu), config_item);

        // Separator
        gtk.gtk_menu_shell_append(@ptrCast(menu), gtk.gtk_separator_menu_item_new());

        // Toggle mode checkbox
        const toggle_item = gtk.gtk_check_menu_item_new_with_label("Toggle Mode (tap to start/stop)");
        gtk.gtk_check_menu_item_set_active(@ptrCast(toggle_item), if (main.isToggleMode()) 1 else 0);
        _ = gtk.g_signal_connect_data(@ptrCast(toggle_item), "toggled", @ptrCast(&onToggleMode), null, null, 0);
        gtk.gtk_menu_shell_append(@ptrCast(menu), toggle_item);

        // Separator
        gtk.gtk_menu_shell_append(@ptrCast(menu), gtk.gtk_separator_menu_item_new());

        // Model selector submenu
        const cfg = main.getConfig();
        const download = @import("download.zig");

        const model_item = gtk.gtk_menu_item_new_with_label("Model");
        const model_menu: *gtk.GtkMenu = @ptrCast(gtk.gtk_menu_new());

        // Add model options
        const models = [_]config.Config.Model{ .tiny, .base, .small, .medium, .large };
        for (models) |model| {
            var label_buf: [128]u8 = [_]u8{0} ** 128;
            const display = model.displayName();

            // Check if model exists
            var test_cfg = config.Config{ .model = model, .language = cfg.language };
            const exists = test_cfg.modelExists(std.heap.c_allocator);

            if (cfg.model == model) {
                _ = std.fmt.bufPrint(&label_buf, "* {s}{s}", .{ display, if (!exists) " [Download]" else "" }) catch {};
            } else {
                _ = std.fmt.bufPrint(&label_buf, "  {s}{s}", .{ display, if (!exists) " [Download]" else "" }) catch {};
            }

            const item = gtk.gtk_menu_item_new_with_label(@ptrCast(&label_buf));
            // Store model index as user data
            _ = gtk.g_signal_connect_data(@ptrCast(item), "activate", @ptrCast(&onModelSelect), @ptrFromInt(@intFromEnum(model)), null, 0);
            gtk.gtk_menu_shell_append(@ptrCast(model_menu), item);
        }

        gtk.gtk_menu_item_set_submenu(@ptrCast(model_item), @ptrCast(model_menu));
        gtk.gtk_menu_shell_append(@ptrCast(menu), model_item);

        // Language selector submenu
        const lang_item = gtk.gtk_menu_item_new_with_label("Language");
        const lang_menu: *gtk.GtkMenu = @ptrCast(gtk.gtk_menu_new());

        const languages = [_]config.Config.Language{ .english, .multilingual };
        for (languages) |language| {
            var label_buf: [128]u8 = [_]u8{0} ** 128;
            const display = language.displayName();

            if (cfg.language == language) {
                _ = std.fmt.bufPrint(&label_buf, "* {s}", .{display}) catch {};
            } else {
                _ = std.fmt.bufPrint(&label_buf, "  {s}", .{display}) catch {};
            }

            const item = gtk.gtk_menu_item_new_with_label(@ptrCast(&label_buf));
            _ = gtk.g_signal_connect_data(@ptrCast(item), "activate", @ptrCast(&onLanguageSelect), @ptrFromInt(@intFromEnum(language)), null, 0);
            gtk.gtk_menu_shell_append(@ptrCast(lang_menu), item);
        }

        gtk.gtk_menu_item_set_submenu(@ptrCast(lang_item), @ptrCast(lang_menu));
        gtk.gtk_menu_shell_append(@ptrCast(menu), lang_item);

        // Show download status if downloading
        if (download.isDownloading()) {
            const downloading_item = gtk.gtk_menu_item_new_with_label("Downloading model...");
            gtk.gtk_widget_set_sensitive(downloading_item, 0);
            gtk.gtk_menu_shell_append(@ptrCast(menu), downloading_item);
        }

        // Separator
        gtk.gtk_menu_shell_append(@ptrCast(menu), gtk.gtk_separator_menu_item_new());

        // Recent transcriptions submenu
        const recent_item = gtk.gtk_menu_item_new_with_label("Recent Transcriptions");
        const recent_menu: *gtk.GtkMenu = @ptrCast(gtk.gtk_menu_new());

        const recent = main.getRecentTranscriptions();
        var has_recent = false;

        // Show recent in reverse order (newest first)
        var i: usize = recent.len;
        while (i > 0) {
            i -= 1;
            if (recent[i]) |text| {
                has_recent = true;
                // Truncate to first 30 chars + ...
                var label_buf: [48]u8 = [_]u8{0} ** 48;
                const max_display: usize = 30;
                const display_len: usize = if (text.len < max_display) text.len else max_display;

                var j: usize = 0;
                while (j < display_len) : (j += 1) {
                    label_buf[j] = text[j];
                }

                if (text.len > max_display) {
                    label_buf[display_len] = '.';
                    label_buf[display_len + 1] = '.';
                    label_buf[display_len + 2] = '.';
                }
                // Buffer is already zero-initialized, no need to set null terminator

                const item = gtk.gtk_menu_item_new_with_label(@ptrCast(&label_buf));
                // Store the full text pointer as user data
                _ = gtk.g_signal_connect_data(@ptrCast(item), "activate", @ptrCast(&onRecentClick), @constCast(@ptrCast(text.ptr)), null, 0);
                gtk.gtk_menu_shell_append(@ptrCast(recent_menu), item);
            }
        }

        if (!has_recent) {
            const empty_item = gtk.gtk_menu_item_new_with_label("(no recent transcriptions)");
            gtk.gtk_widget_set_sensitive(empty_item, 0);
            gtk.gtk_menu_shell_append(@ptrCast(recent_menu), empty_item);
        } else {
            // Add separator and clear option
            gtk.gtk_menu_shell_append(@ptrCast(recent_menu), gtk.gtk_separator_menu_item_new());
            const clear_item = gtk.gtk_menu_item_new_with_label("Clear History");
            _ = gtk.g_signal_connect_data(@ptrCast(clear_item), "activate", @ptrCast(&onClearHistory), null, null, 0);
            gtk.gtk_menu_shell_append(@ptrCast(recent_menu), clear_item);
        }

        gtk.gtk_menu_item_set_submenu(@ptrCast(recent_item), @ptrCast(recent_menu));
        gtk.gtk_menu_shell_append(@ptrCast(menu), recent_item);

        // Separator
        gtk.gtk_menu_shell_append(@ptrCast(menu), gtk.gtk_separator_menu_item_new());

        // Quit
        const quit_item = gtk.gtk_menu_item_new_with_label("Quit");
        _ = gtk.g_signal_connect_data(@ptrCast(quit_item), "activate", @ptrCast(&onQuit), null, null, 0);
        gtk.gtk_menu_shell_append(@ptrCast(menu), quit_item);

        gtk.gtk_widget_show_all(@ptrCast(menu));
        gtk.gtk_menu_popup(menu, null, null, null, null, button, activate_time);
    }

    fn onToggleMode(item: *gtk.GtkCheckMenuItem, _: ?*anyopaque) callconv(.C) void {
        const main = @import("main.zig");
        const active = gtk.gtk_check_menu_item_get_active(item) != 0;
        main.setToggleMode(active);
    }

    fn onRecentClick(_: *gtk.GtkMenuItem, user_data: ?*anyopaque) callconv(.C) void {
        if (user_data) |ptr| {
            // Find the text length by scanning for null or using stored recent
            const main = @import("main.zig");
            const recent = main.getRecentTranscriptions();

            // Find matching text
            for (recent) |entry| {
                if (entry) |text| {
                    if (text.ptr == @as([*]const u8, @ptrCast(ptr))) {
                        // Copy to clipboard
                        const clipboard = gtk.gtk_clipboard_get(gtk.GDK_SELECTION_CLIPBOARD);
                        const text_z = std.heap.c_allocator.dupeZ(u8, text) catch return;
                        defer std.heap.c_allocator.free(text_z);
                        gtk.gtk_clipboard_set_text(clipboard, text_z.ptr, @intCast(text.len));

                        // Show brief notification via tooltip
                        if (tray_instance) |*inst| {
                            if (inst.status_icon) |icon| {
                                gtk.gtk_status_icon_set_tooltip_text(icon, "Copied to clipboard!");
                                // Reset tooltip after a moment (simple approach)
                            }
                        }
                        return;
                    }
                }
            }
        }
    }

    fn onClearHistory(_: *gtk.GtkMenuItem, _: ?*anyopaque) callconv(.C) void {
        const main = @import("main.zig");
        main.clearRecentTranscriptions();
    }

    fn onModelSelect(_: *gtk.GtkMenuItem, user_data: ?*anyopaque) callconv(.C) void {
        const main = @import("main.zig");
        const download = @import("download.zig");

        const model_int: usize = @intFromPtr(user_data);
        const model: config.Config.Model = @enumFromInt(model_int);

        // Update config
        var cfg = main.getConfig();
        cfg.model = model;
        cfg.save(std.heap.c_allocator) catch {};
        main.setConfig(cfg);

        // Check if model exists, if not, download it
        if (!cfg.modelExists(std.heap.c_allocator)) {
            download.startDownload(model, cfg.language) catch {};

            // Update tooltip to show downloading
            if (tray_instance) |*inst| {
                if (inst.status_icon) |icon| {
                    var msg_buf: [128]u8 = [_]u8{0} ** 128;
                    _ = std.fmt.bufPrint(&msg_buf, "Downloading {s}...", .{model.displayName()}) catch {};
                    gtk.gtk_status_icon_set_tooltip_text(icon, @ptrCast(&msg_buf));
                }
            }
        }
    }

    fn onLanguageSelect(_: *gtk.GtkMenuItem, user_data: ?*anyopaque) callconv(.C) void {
        const main = @import("main.zig");
        const download = @import("download.zig");

        const lang_int: usize = @intFromPtr(user_data);
        const language: config.Config.Language = @enumFromInt(lang_int);

        // Update config
        var cfg = main.getConfig();
        cfg.language = language;
        cfg.save(std.heap.c_allocator) catch {};
        main.setConfig(cfg);

        // Check if model exists with new language, if not, download it
        if (!cfg.modelExists(std.heap.c_allocator)) {
            download.startDownload(cfg.model, language) catch {};

            // Update tooltip to show downloading
            if (tray_instance) |*inst| {
                if (inst.status_icon) |icon| {
                    gtk.gtk_status_icon_set_tooltip_text(icon, "Downloading model...");
                }
            }
        }
    }

    fn onEditConfig(_: *gtk.GtkMenuItem, _: ?*anyopaque) callconv(.C) void {
        // Ensure config file exists with defaults
        var cfg = config.Config.load(std.heap.c_allocator) catch config.Config{};
        cfg.save(std.heap.c_allocator) catch {};

        // Get config path
        const home = std.posix.getenv("HOME") orelse return;
        var path_buf: [256]u8 = [_]u8{0} ** 256;
        const path = std.fmt.bufPrint(&path_buf, "{s}/.wysp/config.json", .{home}) catch return;

        // Try $VISUAL, then $EDITOR, then fallbacks
        const editor = std.posix.getenv("VISUAL") orelse
            std.posix.getenv("EDITOR") orelse
            "nano"; // Common default

        // Check if editor is a terminal-based one that needs a terminal emulator
        const needs_terminal = std.mem.eql(u8, editor, "nano") or
            std.mem.eql(u8, editor, "vim") or
            std.mem.eql(u8, editor, "vi") or
            std.mem.eql(u8, editor, "nvim") or
            std.mem.eql(u8, editor, "emacs") or
            std.mem.eql(u8, editor, "micro");

        if (needs_terminal) {
            // Try to find a terminal emulator
            const terminals = [_][]const u8{ "x-terminal-emulator", "gnome-terminal", "konsole", "xfce4-terminal", "xterm" };
            for (terminals) |term| {
                // gnome-terminal uses -- to separate its args
                if (std.mem.eql(u8, term, "gnome-terminal")) {
                    var child = std.process.Child.init(&[_][]const u8{ term, "--", editor, path }, std.heap.c_allocator);
                    if (child.spawn()) |_| return else |_| continue;
                } else {
                    var child = std.process.Child.init(&[_][]const u8{ term, "-e", editor, path }, std.heap.c_allocator);
                    if (child.spawn()) |_| return else |_| continue;
                }
            }
        }

        // Try editor directly (for GUI editors like code, gedit, kate)
        var child = std.process.Child.init(&[_][]const u8{ editor, path }, std.heap.c_allocator);
        _ = child.spawn() catch {
            // Last resort: xdg-open
            var fallback = std.process.Child.init(&[_][]const u8{ "xdg-open", path }, std.heap.c_allocator);
            _ = fallback.spawn() catch return;
        };
    }

    fn onQuit(_: *gtk.GtkMenuItem, _: ?*anyopaque) callconv(.C) void {
        if (quit_callback) |cb| cb();
    }
};

// =============================================================================
// Windows Implementation (Shell_NotifyIcon)
// =============================================================================

const WindowsTray = struct {
    hwnd: ?win32.HWND,
    icon_added: bool,
    thread: ?std.Thread,
    running: bool,

    const Self = @This();
    const config = @import("config.zig");

    const win32 = struct {
        const DWORD = u32;
        const UINT = u32;
        const WORD = u16;
        const BOOL = i32;
        const HWND = ?*anyopaque;
        const HICON = ?*anyopaque;
        const HINSTANCE = ?*anyopaque;
        const HMENU = ?*anyopaque;
        const WPARAM = usize;
        const LPARAM = isize;
        const LRESULT = isize;
        const GUID = extern struct { a: u32, b: u16, c: u16, d: [8]u8 };

        const WM_USER: UINT = 0x0400;
        const WM_TRAYICON: UINT = WM_USER + 1;
        const WM_COMMAND: UINT = 0x0111;
        const WM_RBUTTONUP: UINT = 0x0205;

        const NIM_ADD: DWORD = 0;
        const NIM_MODIFY: DWORD = 1;
        const NIM_DELETE: DWORD = 2;
        const NIF_MESSAGE: UINT = 1;
        const NIF_ICON: UINT = 2;
        const NIF_TIP: UINT = 4;

        const IDI_APPLICATION: usize = 32512;
        const MF_STRING: UINT = 0x0000;
        const MF_SEPARATOR: UINT = 0x0800;
        const MF_POPUP: UINT = 0x0010;
        const MF_CHECKED: UINT = 0x0008;
        const MF_UNCHECKED: UINT = 0x0000;
        const MF_GRAYED: UINT = 0x0001;
        const TPM_BOTTOMALIGN: UINT = 0x0020;
        const TPM_LEFTALIGN: UINT = 0x0000;
        const TPM_RETURNCMD: UINT = 0x0100;

        // Menu item IDs
        const ID_QUIT: usize = 1;
        const ID_TOGGLE_MODE: usize = 10;
        const ID_EDIT_CONFIG: usize = 20;
        const ID_CLEAR_HISTORY: usize = 30;
        const ID_MODEL_BASE: usize = 100; // 100-104 for models
        const ID_LANG_BASE: usize = 200; // 200-201 for languages
        const ID_RECENT_BASE: usize = 300; // 300-309 for recent

        const NOTIFYICONDATAA = extern struct {
            cbSize: DWORD,
            hWnd: HWND,
            uID: UINT,
            uFlags: UINT,
            uCallbackMessage: UINT,
            hIcon: HICON,
            szTip: [128]u8,
            dwState: DWORD = 0,
            dwStateMask: DWORD = 0,
            szInfo: [256]u8 = [_]u8{0} ** 256,
            uVersion: UINT = 0,
            szInfoTitle: [64]u8 = [_]u8{0} ** 64,
            dwInfoFlags: DWORD = 0,
            guidItem: GUID = .{ .a = 0, .b = 0, .c = 0, .d = [_]u8{0} ** 8 },
            hBalloonIcon: HICON = null,
        };

        const WNDCLASSEXA = extern struct {
            cbSize: UINT = @sizeOf(WNDCLASSEXA),
            style: UINT = 0,
            lpfnWndProc: *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.C) LRESULT,
            cbClsExtra: i32 = 0,
            cbWndExtra: i32 = 0,
            hInstance: HINSTANCE = null,
            hIcon: HICON = null,
            hCursor: HICON = null,
            hbrBackground: ?*anyopaque = null,
            lpszMenuName: ?[*:0]const u8 = null,
            lpszClassName: [*:0]const u8,
            hIconSm: HICON = null,
        };

        const MSG = extern struct {
            hwnd: HWND,
            message: UINT,
            wParam: WPARAM,
            lParam: LPARAM,
            time: DWORD,
            pt: extern struct { x: i32, y: i32 },
        };

        const POINT = extern struct { x: i32, y: i32 };

        extern "shell32" fn Shell_NotifyIconA(dwMessage: DWORD, lpData: *NOTIFYICONDATAA) callconv(.C) BOOL;
        extern "user32" fn LoadIconA(hInstance: HINSTANCE, lpIconName: usize) callconv(.C) HICON;
        extern "user32" fn RegisterClassExA(lpwcx: *const WNDCLASSEXA) callconv(.C) WORD;
        extern "user32" fn CreateWindowExA(dwExStyle: DWORD, lpClassName: [*:0]const u8, lpWindowName: [*:0]const u8, dwStyle: DWORD, x: i32, y: i32, nWidth: i32, nHeight: i32, hWndParent: HWND, hMenu: HMENU, hInstance: HINSTANCE, lpParam: ?*anyopaque) callconv(.C) HWND;
        extern "user32" fn DestroyWindow(hWnd: HWND) callconv(.C) BOOL;
        extern "user32" fn DefWindowProcA(hWnd: HWND, Msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.C) LRESULT;
        extern "user32" fn GetMessageA(lpMsg: *MSG, hWnd: HWND, wMsgFilterMin: UINT, wMsgFilterMax: UINT) callconv(.C) BOOL;
        extern "user32" fn TranslateMessage(lpMsg: *const MSG) callconv(.C) BOOL;
        extern "user32" fn DispatchMessageA(lpMsg: *const MSG) callconv(.C) LRESULT;
        extern "user32" fn PostQuitMessage(nExitCode: i32) callconv(.C) void;
        extern "user32" fn CreatePopupMenu() callconv(.C) HMENU;
        extern "user32" fn AppendMenuA(hMenu: HMENU, uFlags: UINT, uIDNewItem: usize, lpNewItem: ?[*:0]const u8) callconv(.C) BOOL;
        extern "user32" fn TrackPopupMenu(hMenu: HMENU, uFlags: UINT, x: i32, y: i32, nReserved: i32, hWnd: HWND, prcRect: ?*anyopaque) callconv(.C) BOOL;
        extern "user32" fn DestroyMenu(hMenu: HMENU) callconv(.C) BOOL;
        extern "user32" fn GetCursorPos(lpPoint: *POINT) callconv(.C) BOOL;
        extern "user32" fn SetForegroundWindow(hWnd: HWND) callconv(.C) BOOL;
        extern "user32" fn OpenClipboard(hWndNewOwner: HWND) callconv(.C) BOOL;
        extern "user32" fn CloseClipboard() callconv(.C) BOOL;
        extern "user32" fn EmptyClipboard() callconv(.C) BOOL;
        extern "user32" fn SetClipboardData(uFormat: UINT, hMem: ?*anyopaque) callconv(.C) ?*anyopaque;
        extern "kernel32" fn GetModuleHandleA(lpModuleName: ?[*:0]const u8) callconv(.C) HINSTANCE;
        extern "kernel32" fn GlobalAlloc(uFlags: UINT, dwBytes: usize) callconv(.C) ?*anyopaque;
        extern "kernel32" fn GlobalLock(hMem: ?*anyopaque) callconv(.C) ?*anyopaque;
        extern "kernel32" fn GlobalUnlock(hMem: ?*anyopaque) callconv(.C) BOOL;
    };

    var g_nid: win32.NOTIFYICONDATAA = undefined;
    var g_self: ?*Self = null;

    pub fn init() !Self {
        var self = Self{
            .hwnd = null,
            .icon_added = false,
            .thread = null,
            .running = true,
        };

        g_self = &self;
        self.thread = try std.Thread.spawn(.{}, windowThread, .{&self});

        // Wait for window creation
        std.time.sleep(100 * std.time.ns_per_ms);

        return self;
    }

    pub fn setQuitCallback(_: *Self, _: *const fn () void) void {}

    pub fn setTooltip(self: *Self, text: []const u8) void {
        if (!self.icon_added) return;
        @memset(&g_nid.szTip, 0);
        const len = @min(text.len, 127);
        @memcpy(g_nid.szTip[0..len], text[0..len]);
        _ = win32.Shell_NotifyIconA(win32.NIM_MODIFY, &g_nid);
    }

    pub fn setRecording(self: *Self, recording: bool) void {
        if (!self.icon_added) return;
        @memset(&g_nid.szTip, 0);
        if (recording) {
            const tip = "Wysp - Recording...";
            @memcpy(g_nid.szTip[0..tip.len], tip);
        } else {
            // Get configured hotkey
            const main = @import("main.zig");
            var tip_buf: [127]u8 = undefined;
            const hotkey_str = main.getHotkeyString() orelse "Ctrl+Shift+Space";
            const tip = std.fmt.bufPrint(&tip_buf, "Wysp - Hold {s} to record", .{hotkey_str}) catch "Wysp";
            @memcpy(g_nid.szTip[0..tip.len], tip);
        }
        _ = win32.Shell_NotifyIconA(win32.NIM_MODIFY, &g_nid);
    }

    pub fn deinit(self: *Self) void {
        self.running = false;
        if (self.icon_added) {
            _ = win32.Shell_NotifyIconA(win32.NIM_DELETE, &g_nid);
        }
        if (self.hwnd) |hwnd| {
            _ = win32.DestroyWindow(hwnd);
        }
        if (self.thread) |t| {
            t.join();
        }
        g_self = null;
    }

    fn windowThread(self: *Self) void {
        const hInstance = win32.GetModuleHandleA(null);

        const wc = win32.WNDCLASSEXA{
            .lpfnWndProc = wndProc,
            .hInstance = hInstance,
            .lpszClassName = "WyspTray",
        };

        _ = win32.RegisterClassExA(&wc);

        self.hwnd = win32.CreateWindowExA(0, "WyspTray", "Wysp", 0, 0, 0, 0, 0, null, null, hInstance, null);

        if (self.hwnd) |hwnd| {
            g_nid = std.mem.zeroes(win32.NOTIFYICONDATAA);
            g_nid.cbSize = @sizeOf(win32.NOTIFYICONDATAA);
            g_nid.hWnd = hwnd;
            g_nid.uID = 1;
            g_nid.uFlags = win32.NIF_MESSAGE | win32.NIF_ICON | win32.NIF_TIP;
            g_nid.uCallbackMessage = win32.WM_TRAYICON;
            g_nid.hIcon = win32.LoadIconA(null, win32.IDI_APPLICATION);

            const tip = "Wysp - Hold Ctrl+Shift+Space to record";
            @memcpy(g_nid.szTip[0..tip.len], tip);

            if (win32.Shell_NotifyIconA(win32.NIM_ADD, &g_nid) != 0) {
                self.icon_added = true;
            }
        }

        var msg: win32.MSG = undefined;
        while (self.running and win32.GetMessageA(&msg, null, 0, 0) > 0) {
            _ = win32.TranslateMessage(&msg);
            _ = win32.DispatchMessageA(&msg);
        }
    }

    fn wndProc(hwnd: win32.HWND, msg: win32.UINT, wParam: win32.WPARAM, lParam: win32.LPARAM) callconv(.C) win32.LRESULT {
        switch (msg) {
            win32.WM_TRAYICON => {
                if (@as(win32.UINT, @truncate(@as(usize, @bitCast(lParam)))) == win32.WM_RBUTTONUP) {
                    showContextMenu(hwnd);
                }
                return 0;
            },
            win32.WM_COMMAND => {
                handleMenuCommand(wParam);
                return 0;
            },
            else => return win32.DefWindowProcA(hwnd, msg, wParam, lParam),
        }
    }

    fn showContextMenu(hwnd: win32.HWND) void {
        const main = @import("main.zig");
        const download = @import("download.zig");

        const menu = win32.CreatePopupMenu() orelse return;

        // Hotkey display (disabled)
        var hotkey_buf: [128]u8 = [_]u8{0} ** 128;
        const hotkey_str = main.getHotkeyString() orelse "Ctrl+Shift+Space";
        _ = std.fmt.bufPrint(&hotkey_buf, "Hotkey: {s}", .{hotkey_str}) catch {};
        _ = win32.AppendMenuA(menu, win32.MF_STRING | win32.MF_GRAYED, 0, @ptrCast(&hotkey_buf));

        // Edit Config
        _ = win32.AppendMenuA(menu, win32.MF_STRING, win32.ID_EDIT_CONFIG, "Edit Config");

        // Separator
        _ = win32.AppendMenuA(menu, win32.MF_SEPARATOR, 0, null);

        // Toggle Mode
        const toggle_flags = win32.MF_STRING | (if (main.isToggleMode()) win32.MF_CHECKED else win32.MF_UNCHECKED);
        _ = win32.AppendMenuA(menu, toggle_flags, win32.ID_TOGGLE_MODE, "Toggle Mode (tap to start/stop)");

        // Separator
        _ = win32.AppendMenuA(menu, win32.MF_SEPARATOR, 0, null);

        // Model submenu
        const cfg = main.getConfig();
        const model_menu = win32.CreatePopupMenu();
        if (model_menu) |mm| {
            const models = [_]config.Config.Model{ .tiny, .base, .small, .medium, .large };
            for (models, 0..) |model, i| {
                var label_buf: [64]u8 = [_]u8{0} ** 64;
                const display = model.displayName();

                var test_cfg = config.Config{ .model = model, .language = cfg.language };
                const exists = test_cfg.modelExists(std.heap.c_allocator);

                const prefix: []const u8 = if (cfg.model == model) "* " else "  ";
                const suffix: []const u8 = if (!exists) " [Download]" else "";
                _ = std.fmt.bufPrint(&label_buf, "{s}{s}{s}", .{ prefix, display, suffix }) catch {};

                const flags = win32.MF_STRING | (if (cfg.model == model) win32.MF_CHECKED else win32.MF_UNCHECKED);
                _ = win32.AppendMenuA(mm, flags, win32.ID_MODEL_BASE + i, @ptrCast(&label_buf));
            }
            _ = win32.AppendMenuA(menu, win32.MF_POPUP, @intFromPtr(mm), "Model");
        }

        // Language submenu
        const lang_menu = win32.CreatePopupMenu();
        if (lang_menu) |lm| {
            const languages = [_]config.Config.Language{ .english, .multilingual };
            for (languages, 0..) |language, i| {
                var label_buf: [64]u8 = [_]u8{0} ** 64;
                const display = language.displayName();

                const prefix: []const u8 = if (cfg.language == language) "* " else "  ";
                _ = std.fmt.bufPrint(&label_buf, "{s}{s}", .{ prefix, display }) catch {};

                const flags = win32.MF_STRING | (if (cfg.language == language) win32.MF_CHECKED else win32.MF_UNCHECKED);
                _ = win32.AppendMenuA(lm, flags, win32.ID_LANG_BASE + i, @ptrCast(&label_buf));
            }
            _ = win32.AppendMenuA(menu, win32.MF_POPUP, @intFromPtr(lm), "Language");
        }

        // Download status
        if (download.isDownloading()) {
            _ = win32.AppendMenuA(menu, win32.MF_STRING | win32.MF_GRAYED, 0, "Downloading model...");
        }

        // Separator
        _ = win32.AppendMenuA(menu, win32.MF_SEPARATOR, 0, null);

        // Recent transcriptions submenu
        const recent_menu = win32.CreatePopupMenu();
        if (recent_menu) |rm| {
            const recent = main.getRecentTranscriptions();
            var has_recent = false;

            var idx: usize = recent.len;
            var menu_idx: usize = 0;
            while (idx > 0 and menu_idx < 10) {
                idx -= 1;
                if (recent[idx]) |text| {
                    has_recent = true;
                    var label_buf: [48]u8 = [_]u8{0} ** 48;
                    const max_display: usize = 30;
                    const display_len: usize = @min(text.len, max_display);

                    @memcpy(label_buf[0..display_len], text[0..display_len]);
                    if (text.len > max_display) {
                        label_buf[display_len] = '.';
                        label_buf[display_len + 1] = '.';
                        label_buf[display_len + 2] = '.';
                    }

                    _ = win32.AppendMenuA(rm, win32.MF_STRING, win32.ID_RECENT_BASE + menu_idx, @ptrCast(&label_buf));
                    menu_idx += 1;
                }
            }

            if (!has_recent) {
                _ = win32.AppendMenuA(rm, win32.MF_STRING | win32.MF_GRAYED, 0, "(no recent transcriptions)");
            } else {
                _ = win32.AppendMenuA(rm, win32.MF_SEPARATOR, 0, null);
                _ = win32.AppendMenuA(rm, win32.MF_STRING, win32.ID_CLEAR_HISTORY, "Clear History");
            }
            _ = win32.AppendMenuA(menu, win32.MF_POPUP, @intFromPtr(rm), "Recent Transcriptions");
        }

        // Separator
        _ = win32.AppendMenuA(menu, win32.MF_SEPARATOR, 0, null);

        // Quit
        _ = win32.AppendMenuA(menu, win32.MF_STRING, win32.ID_QUIT, "Quit");

        var pt: win32.POINT = undefined;
        _ = win32.GetCursorPos(&pt);
        _ = win32.SetForegroundWindow(hwnd);
        _ = win32.TrackPopupMenu(menu, win32.TPM_BOTTOMALIGN | win32.TPM_LEFTALIGN, pt.x, pt.y, 0, hwnd, null);
        _ = win32.DestroyMenu(menu);
    }

    fn handleMenuCommand(wParam: win32.WPARAM) void {
        const main = @import("main.zig");
        const download = @import("download.zig");
        const cmd = @as(u16, @truncate(wParam));

        if (cmd == win32.ID_QUIT) {
            if (quit_callback) |cb| cb();
        } else if (cmd == win32.ID_TOGGLE_MODE) {
            main.setToggleMode(!main.isToggleMode());
        } else if (cmd == win32.ID_EDIT_CONFIG) {
            openConfigEditor();
        } else if (cmd == win32.ID_CLEAR_HISTORY) {
            main.clearRecentTranscriptions();
        } else if (cmd >= win32.ID_MODEL_BASE and cmd < win32.ID_MODEL_BASE + 5) {
            // Model selection
            const model_idx = cmd - win32.ID_MODEL_BASE;
            const models = [_]config.Config.Model{ .tiny, .base, .small, .medium, .large };
            if (model_idx < models.len) {
                const model = models[model_idx];
                var cfg = main.getConfig();
                cfg.model = model;
                cfg.save(std.heap.c_allocator) catch {};
                main.setConfig(cfg);

                if (!cfg.modelExists(std.heap.c_allocator)) {
                    download.startDownload(model, cfg.language) catch {};
                }
            }
        } else if (cmd >= win32.ID_LANG_BASE and cmd < win32.ID_LANG_BASE + 2) {
            // Language selection
            const lang_idx = cmd - win32.ID_LANG_BASE;
            const languages = [_]config.Config.Language{ .english, .multilingual };
            if (lang_idx < languages.len) {
                const language = languages[lang_idx];
                var cfg = main.getConfig();
                cfg.language = language;
                cfg.save(std.heap.c_allocator) catch {};
                main.setConfig(cfg);

                if (!cfg.modelExists(std.heap.c_allocator)) {
                    download.startDownload(cfg.model, language) catch {};
                }
            }
        } else if (cmd >= win32.ID_RECENT_BASE and cmd < win32.ID_RECENT_BASE + 10) {
            // Recent transcription - copy to clipboard
            const recent_idx = cmd - win32.ID_RECENT_BASE;
            const recent = main.getRecentTranscriptions();

            // Find the item (reverse order like menu)
            var idx: usize = recent.len;
            var menu_idx: usize = 0;
            while (idx > 0) {
                idx -= 1;
                if (recent[idx]) |text| {
                    if (menu_idx == recent_idx) {
                        copyToClipboard(text);
                        return;
                    }
                    menu_idx += 1;
                }
            }
        }
    }

    fn openConfigEditor() void {
        // Ensure config exists
        var cfg = config.Config.load(std.heap.c_allocator) catch config.Config{};
        cfg.save(std.heap.c_allocator) catch {};

        // Get config path
        const appdata = std.process.getEnvVarOwned(std.heap.c_allocator, "USERPROFILE") catch return;
        defer std.heap.c_allocator.free(appdata);

        var path_buf: [512]u8 = [_]u8{0} ** 512;
        const path = std.fmt.bufPrint(&path_buf, "{s}\\.wysp\\config.json", .{appdata}) catch return;

        // Open with default editor (notepad on Windows)
        var child = std.process.Child.init(&[_][]const u8{ "notepad.exe", path }, std.heap.c_allocator);
        _ = child.spawn() catch {};
    }

    fn copyToClipboard(text: []const u8) void {
        const text_z = std.heap.c_allocator.dupeZ(u8, text) catch return;
        defer std.heap.c_allocator.free(text_z);

        if (win32.OpenClipboard(null) == 0) return;
        defer _ = win32.CloseClipboard();

        _ = win32.EmptyClipboard();

        const hmem = win32.GlobalAlloc(0x0002, text.len + 1); // GMEM_MOVEABLE
        if (hmem) |h| {
            if (win32.GlobalLock(h)) |ptr| {
                @memcpy(@as([*]u8, @ptrCast(ptr))[0..text.len], text);
                @as([*]u8, @ptrCast(ptr))[text.len] = 0;
                _ = win32.GlobalUnlock(h);
                _ = win32.SetClipboardData(1, h); // CF_TEXT
            }
        }
    }
};

// =============================================================================
// Unsupported Platform
// =============================================================================

const UnsupportedTray = struct {
    const Self = @This();

    pub fn init() !Self {
        return TrayError.NotSupported;
    }

    pub fn setQuitCallback(_: *Self, _: *const fn () void) void {}
    pub fn setTooltip(_: *Self, _: []const u8) void {}
    pub fn setRecording(_: *Self, _: bool) void {}
    pub fn deinit(_: *Self) void {}
};
