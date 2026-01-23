const std = @import("std");
const builtin = @import("builtin");

/// Cross-platform environment variable getter.
/// Returns owned memory that must be freed with the provided allocator.
/// Returns null if the variable is not set.
pub fn getEnvAlloc(allocator: std.mem.Allocator, key: []const u8) ?[]const u8 {
    return std.process.getEnvVarOwned(allocator, key) catch null;
}

/// Get HOME directory (or USERPROFILE on Windows).
/// Returns owned memory that must be freed.
pub fn getHomeDir(allocator: std.mem.Allocator) ?[]const u8 {
    if (builtin.os.tag == .windows) {
        return getEnvAlloc(allocator, "USERPROFILE");
    } else {
        return getEnvAlloc(allocator, "HOME");
    }
}
