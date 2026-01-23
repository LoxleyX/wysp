//! Model Downloader
//!
//! Downloads whisper models from Hugging Face using curl.

const std = @import("std");
const config = @import("config.zig");
const utils = @import("utils.zig");

pub const DownloadError = error{
    CurlNotFound,
    DownloadFailed,
    CreateDirFailed,
};

pub const DownloadState = enum {
    idle,
    downloading,
    completed,
    failed,
};

// Global download state
var g_state: DownloadState = .idle;
var g_progress: u8 = 0;
var g_download_thread: ?std.Thread = null;
var g_current_model: ?config.Config.Model = null;
var g_current_language: ?config.Config.Language = null;

pub fn getState() DownloadState {
    return g_state;
}

pub fn getProgress() u8 {
    return g_progress;
}

pub fn getCurrentModel() ?config.Config.Model {
    return g_current_model;
}

pub fn isDownloading() bool {
    return g_state == .downloading;
}

/// Start downloading a model in the background
pub fn startDownload(model: config.Config.Model, language: config.Config.Language) !void {
    if (g_state == .downloading) {
        return; // Already downloading
    }

    g_state = .downloading;
    g_progress = 0;
    g_current_model = model;
    g_current_language = language;

    g_download_thread = try std.Thread.spawn(.{}, downloadThread, .{ model, language });
}

fn downloadThread(model: config.Config.Model, language: config.Config.Language) void {
    const allocator = std.heap.c_allocator;

    // Get paths
    const home = utils.getHomeDir(allocator) orelse {
        g_state = .failed;
        return;
    };
    defer allocator.free(home);

    // Ensure models directory exists
    var models_dir_buf: [256]u8 = undefined;
    const models_dir = std.fmt.bufPrint(&models_dir_buf, "{s}/.wysp/models", .{home}) catch {
        g_state = .failed;
        return;
    };

    std.fs.makeDirAbsolute(models_dir) catch |err| {
        if (err != error.PathAlreadyExists) {
            g_state = .failed;
            return;
        }
    };

    // Get URL and output path
    var cfg = config.Config{ .model = model, .language = language };
    const url = cfg.getModelUrl();

    const filename = model.fileName(language);
    var output_path_buf: [512]u8 = undefined;
    const output_path = std.fmt.bufPrint(&output_path_buf, "{s}/.wysp/models/{s}", .{ home, filename }) catch {
        g_state = .failed;
        return;
    };

    // Make it null-terminated for exec
    var url_z: [512:0]u8 = undefined;
    @memcpy(url_z[0..url.len], url);
    url_z[url.len] = 0;

    var output_z: [512:0]u8 = undefined;
    @memcpy(output_z[0..output_path.len], output_path);
    output_z[output_path.len] = 0;

    // Run curl with progress
    // -L follows redirects, -o output file, --progress-bar for progress
    var child = std.process.Child.init(
        &[_][]const u8{
            "curl",
            "-L",
            "--progress-bar",
            "-o",
            output_z[0..output_path.len :0],
            url_z[0..url.len :0],
        },
        allocator,
    );

    child.spawn() catch {
        g_state = .failed;
        return;
    };

    // Wait for completion
    const result = child.wait() catch {
        g_state = .failed;
        return;
    };

    if (result.Exited == 0) {
        g_state = .completed;
        g_progress = 100;
    } else {
        g_state = .failed;
    }
}

/// Check if curl is available
pub fn curlAvailable() bool {
    var child = std.process.Child.init(
        &[_][]const u8{ "curl", "--version" },
        std.heap.c_allocator,
    );
    child.spawn() catch return false;
    const result = child.wait() catch return false;
    return result.Exited == 0;
}

/// Reset state after completion/failure
pub fn reset() void {
    if (g_download_thread) |t| {
        t.detach();
        g_download_thread = null;
    }
    g_state = .idle;
    g_progress = 0;
    g_current_model = null;
    g_current_language = null;
}
