//! Configuration - ~/.wysp/config.json
//!
//! Stores user preferences including hotkey binding.

const std = @import("std");
const builtin = @import("builtin");

pub const Config = struct {
    hotkey: Hotkey = .{},
    toggle_mode: bool = false,

    pub const Hotkey = struct {
        // Modifiers
        ctrl: bool = true,
        shift: bool = true,
        alt: bool = false,
        super: bool = false,

        // Key (lowercase)
        key: []const u8 = "space",

        /// Parse a hotkey string like "Ctrl+Shift+Space"
        pub fn parse(allocator: std.mem.Allocator, str: []const u8) !Hotkey {
            var hotkey = Hotkey{
                .ctrl = false,
                .shift = false,
                .alt = false,
                .super = false,
                .key = "",
            };

            var iter = std.mem.splitSequence(u8, str, "+");
            var last_part: []const u8 = "";

            while (iter.next()) |part| {
                const trimmed = std.mem.trim(u8, part, " ");
                const lower = try allocator.dupe(u8, trimmed);
                defer allocator.free(lower);
                toLower(lower);

                if (std.mem.eql(u8, lower, "ctrl") or std.mem.eql(u8, lower, "control")) {
                    hotkey.ctrl = true;
                } else if (std.mem.eql(u8, lower, "shift")) {
                    hotkey.shift = true;
                } else if (std.mem.eql(u8, lower, "alt")) {
                    hotkey.alt = true;
                } else if (std.mem.eql(u8, lower, "super") or std.mem.eql(u8, lower, "win") or std.mem.eql(u8, lower, "meta")) {
                    hotkey.super = true;
                } else {
                    last_part = trimmed;
                }
            }

            if (last_part.len == 0) {
                return error.InvalidHotkey;
            }

            hotkey.key = try allocator.dupe(u8, last_part);
            toLower(@constCast(hotkey.key));

            return hotkey;
        }

        /// Format hotkey as string (e.g., "Ctrl+Shift+Space")
        pub fn format(self: Hotkey, allocator: std.mem.Allocator) ![]const u8 {
            var parts = std.ArrayList([]const u8).init(allocator);
            defer parts.deinit();

            if (self.ctrl) try parts.append("Ctrl");
            if (self.shift) try parts.append("Shift");
            if (self.alt) try parts.append("Alt");
            if (self.super) try parts.append("Super");

            // Capitalize key name
            var key_cap = try allocator.dupe(u8, self.key);
            if (key_cap.len > 0) {
                key_cap[0] = std.ascii.toUpper(key_cap[0]);
            }
            try parts.append(key_cap);

            // Join with +
            var result = std.ArrayList(u8).init(allocator);
            for (parts.items, 0..) |part, i| {
                if (i > 0) try result.append('+');
                try result.appendSlice(part);
            }

            // Free the capitalized key
            allocator.free(key_cap);

            return result.toOwnedSlice();
        }

        pub fn deinit(self: *Hotkey, allocator: std.mem.Allocator) void {
            if (self.key.len > 0 and !isDefaultKey(self.key)) {
                allocator.free(self.key);
            }
        }

        fn isDefaultKey(key: []const u8) bool {
            return std.mem.eql(u8, key, "space");
        }
    };

    const Self = @This();

    /// Load config from ~/.wysp/config.json
    pub fn load(allocator: std.mem.Allocator) !Self {
        const path = try getConfigPath(allocator);
        defer allocator.free(path);

        const file = std.fs.openFileAbsolute(path, .{}) catch {
            // Return defaults if file doesn't exist
            return Self{};
        };
        defer file.close();

        const content = try file.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(content);

        return parseJson(allocator, content);
    }

    /// Save config to ~/.wysp/config.json
    pub fn save(self: Self, allocator: std.mem.Allocator) !void {
        const dir_path = try getConfigDir(allocator);
        defer allocator.free(dir_path);

        // Ensure directory exists
        std.fs.makeDirAbsolute(dir_path) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        const path = try getConfigPath(allocator);
        defer allocator.free(path);

        const file = try std.fs.createFileAbsolute(path, .{});
        defer file.close();

        const hotkey_str = try self.hotkey.format(allocator);
        defer allocator.free(hotkey_str);

        try file.writer().print(
            \\{{
            \\  "hotkey": "{s}",
            \\  "toggle_mode": {s}
            \\}}
            \\
        , .{ hotkey_str, if (self.toggle_mode) "true" else "false" });
    }

    fn parseJson(allocator: std.mem.Allocator, content: []const u8) !Self {
        var config = Self{};

        // Simple JSON parsing for our specific format
        if (std.mem.indexOf(u8, content, "\"hotkey\"")) |_| {
            if (extractStringValue(content, "hotkey")) |hotkey_str| {
                config.hotkey = Hotkey.parse(allocator, hotkey_str) catch .{};
            }
        }

        if (std.mem.indexOf(u8, content, "\"toggle_mode\"")) |_| {
            config.toggle_mode = std.mem.indexOf(u8, content, "true") != null;
        }

        return config;
    }

    fn extractStringValue(content: []const u8, key: []const u8) ?[]const u8 {
        // Find "key": "value"
        const key_pattern = std.fmt.allocPrint(std.heap.page_allocator, "\"{s}\"", .{key}) catch return null;
        defer std.heap.page_allocator.free(key_pattern);

        const key_pos = std.mem.indexOf(u8, content, key_pattern) orelse return null;
        const after_key = content[key_pos + key_pattern.len ..];

        // Find the colon and opening quote
        const colon_pos = std.mem.indexOf(u8, after_key, ":") orelse return null;
        const after_colon = after_key[colon_pos + 1 ..];
        const quote_start = std.mem.indexOf(u8, after_colon, "\"") orelse return null;
        const value_start = after_colon[quote_start + 1 ..];
        const quote_end = std.mem.indexOf(u8, value_start, "\"") orelse return null;

        return value_start[0..quote_end];
    }

    fn getConfigDir(allocator: std.mem.Allocator) ![]const u8 {
        const home = std.posix.getenv("HOME") orelse std.posix.getenv("USERPROFILE") orelse return error.NoHomeDir;
        return std.fmt.allocPrint(allocator, "{s}/.wysp", .{home});
    }

    fn getConfigPath(allocator: std.mem.Allocator) ![]const u8 {
        const home = std.posix.getenv("HOME") orelse std.posix.getenv("USERPROFILE") orelse return error.NoHomeDir;
        return std.fmt.allocPrint(allocator, "{s}/.wysp/config.json", .{home});
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.hotkey.deinit(allocator);
    }
};

fn toLower(str: []u8) void {
    for (str) |*c| {
        c.* = std.ascii.toLower(c.*);
    }
}

// Key name to X11 keysym mapping
pub fn keyNameToX11Keysym(name: []const u8) ?c_ulong {
    const lower = blk: {
        var buf: [32]u8 = undefined;
        if (name.len > buf.len) return null;
        @memcpy(buf[0..name.len], name);
        toLower(buf[0..name.len]);
        break :blk buf[0..name.len];
    };

    // Common keys
    if (std.mem.eql(u8, lower, "space")) return 0x0020;
    if (std.mem.eql(u8, lower, "return") or std.mem.eql(u8, lower, "enter")) return 0xff0d;
    if (std.mem.eql(u8, lower, "tab")) return 0xff09;
    if (std.mem.eql(u8, lower, "escape") or std.mem.eql(u8, lower, "esc")) return 0xff1b;
    if (std.mem.eql(u8, lower, "backspace")) return 0xff08;
    if (std.mem.eql(u8, lower, "delete")) return 0xffff;
    if (std.mem.eql(u8, lower, "insert")) return 0xff63;
    if (std.mem.eql(u8, lower, "home")) return 0xff50;
    if (std.mem.eql(u8, lower, "end")) return 0xff57;
    if (std.mem.eql(u8, lower, "pageup")) return 0xff55;
    if (std.mem.eql(u8, lower, "pagedown")) return 0xff56;

    // Arrow keys
    if (std.mem.eql(u8, lower, "up")) return 0xff52;
    if (std.mem.eql(u8, lower, "down")) return 0xff54;
    if (std.mem.eql(u8, lower, "left")) return 0xff51;
    if (std.mem.eql(u8, lower, "right")) return 0xff53;

    // Function keys
    if (std.mem.eql(u8, lower, "f1")) return 0xffbe;
    if (std.mem.eql(u8, lower, "f2")) return 0xffbf;
    if (std.mem.eql(u8, lower, "f3")) return 0xffc0;
    if (std.mem.eql(u8, lower, "f4")) return 0xffc1;
    if (std.mem.eql(u8, lower, "f5")) return 0xffc2;
    if (std.mem.eql(u8, lower, "f6")) return 0xffc3;
    if (std.mem.eql(u8, lower, "f7")) return 0xffc4;
    if (std.mem.eql(u8, lower, "f8")) return 0xffc5;
    if (std.mem.eql(u8, lower, "f9")) return 0xffc6;
    if (std.mem.eql(u8, lower, "f10")) return 0xffc7;
    if (std.mem.eql(u8, lower, "f11")) return 0xffc8;
    if (std.mem.eql(u8, lower, "f12")) return 0xffc9;

    // Single letter/number (ASCII)
    if (lower.len == 1) {
        const c = lower[0];
        if (c >= 'a' and c <= 'z') return @as(c_ulong, c);
        if (c >= '0' and c <= '9') return @as(c_ulong, c);
    }

    return null;
}

// Key name to evdev code mapping
pub fn keyNameToEvdev(name: []const u8) ?u16 {
    var buf: [32]u8 = undefined;
    if (name.len > buf.len) return null;
    @memcpy(buf[0..name.len], name);
    toLower(buf[0..name.len]);
    const lower = buf[0..name.len];

    // Common keys
    if (std.mem.eql(u8, lower, "space")) return 57;
    if (std.mem.eql(u8, lower, "return") or std.mem.eql(u8, lower, "enter")) return 28;
    if (std.mem.eql(u8, lower, "tab")) return 15;
    if (std.mem.eql(u8, lower, "escape") or std.mem.eql(u8, lower, "esc")) return 1;
    if (std.mem.eql(u8, lower, "backspace")) return 14;
    if (std.mem.eql(u8, lower, "delete")) return 111;
    if (std.mem.eql(u8, lower, "insert")) return 110;
    if (std.mem.eql(u8, lower, "home")) return 102;
    if (std.mem.eql(u8, lower, "end")) return 107;
    if (std.mem.eql(u8, lower, "pageup")) return 104;
    if (std.mem.eql(u8, lower, "pagedown")) return 109;

    // Arrow keys
    if (std.mem.eql(u8, lower, "up")) return 103;
    if (std.mem.eql(u8, lower, "down")) return 108;
    if (std.mem.eql(u8, lower, "left")) return 105;
    if (std.mem.eql(u8, lower, "right")) return 106;

    // Function keys
    if (std.mem.eql(u8, lower, "f1")) return 59;
    if (std.mem.eql(u8, lower, "f2")) return 60;
    if (std.mem.eql(u8, lower, "f3")) return 61;
    if (std.mem.eql(u8, lower, "f4")) return 62;
    if (std.mem.eql(u8, lower, "f5")) return 63;
    if (std.mem.eql(u8, lower, "f6")) return 64;
    if (std.mem.eql(u8, lower, "f7")) return 65;
    if (std.mem.eql(u8, lower, "f8")) return 66;
    if (std.mem.eql(u8, lower, "f9")) return 67;
    if (std.mem.eql(u8, lower, "f10")) return 68;
    if (std.mem.eql(u8, lower, "f11")) return 87;
    if (std.mem.eql(u8, lower, "f12")) return 88;

    // Letter keys (a-z)
    if (lower.len == 1 and lower[0] >= 'a' and lower[0] <= 'z') {
        const offsets = [_]u16{ 30, 48, 46, 32, 18, 33, 34, 35, 23, 36, 37, 38, 50, 49, 24, 25, 16, 19, 31, 20, 22, 47, 17, 45, 21, 44 };
        return offsets[lower[0] - 'a'];
    }

    // Number keys (0-9)
    if (lower.len == 1 and lower[0] >= '0' and lower[0] <= '9') {
        if (lower[0] == '0') return 11;
        return @as(u16, lower[0] - '0') + 1;
    }

    return null;
}

// Key name to Windows virtual key code
pub fn keyNameToVK(name: []const u8) ?u32 {
    var buf: [32]u8 = undefined;
    if (name.len > buf.len) return null;
    @memcpy(buf[0..name.len], name);
    toLower(buf[0..name.len]);
    const lower = buf[0..name.len];

    // Common keys
    if (std.mem.eql(u8, lower, "space")) return 0x20;
    if (std.mem.eql(u8, lower, "return") or std.mem.eql(u8, lower, "enter")) return 0x0D;
    if (std.mem.eql(u8, lower, "tab")) return 0x09;
    if (std.mem.eql(u8, lower, "escape") or std.mem.eql(u8, lower, "esc")) return 0x1B;
    if (std.mem.eql(u8, lower, "backspace")) return 0x08;
    if (std.mem.eql(u8, lower, "delete")) return 0x2E;
    if (std.mem.eql(u8, lower, "insert")) return 0x2D;
    if (std.mem.eql(u8, lower, "home")) return 0x24;
    if (std.mem.eql(u8, lower, "end")) return 0x23;
    if (std.mem.eql(u8, lower, "pageup")) return 0x21;
    if (std.mem.eql(u8, lower, "pagedown")) return 0x22;

    // Arrow keys
    if (std.mem.eql(u8, lower, "up")) return 0x26;
    if (std.mem.eql(u8, lower, "down")) return 0x28;
    if (std.mem.eql(u8, lower, "left")) return 0x25;
    if (std.mem.eql(u8, lower, "right")) return 0x27;

    // Function keys
    if (std.mem.eql(u8, lower, "f1")) return 0x70;
    if (std.mem.eql(u8, lower, "f2")) return 0x71;
    if (std.mem.eql(u8, lower, "f3")) return 0x72;
    if (std.mem.eql(u8, lower, "f4")) return 0x73;
    if (std.mem.eql(u8, lower, "f5")) return 0x74;
    if (std.mem.eql(u8, lower, "f6")) return 0x75;
    if (std.mem.eql(u8, lower, "f7")) return 0x76;
    if (std.mem.eql(u8, lower, "f8")) return 0x77;
    if (std.mem.eql(u8, lower, "f9")) return 0x78;
    if (std.mem.eql(u8, lower, "f10")) return 0x79;
    if (std.mem.eql(u8, lower, "f11")) return 0x7A;
    if (std.mem.eql(u8, lower, "f12")) return 0x7B;

    // Letter keys (A-Z are 0x41-0x5A)
    if (lower.len == 1 and lower[0] >= 'a' and lower[0] <= 'z') {
        return @as(u32, lower[0] - 'a') + 0x41;
    }

    // Number keys (0-9 are 0x30-0x39)
    if (lower.len == 1 and lower[0] >= '0' and lower[0] <= '9') {
        return @as(u32, lower[0] - '0') + 0x30;
    }

    return null;
}
