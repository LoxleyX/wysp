//! CLI Mode for Wysp
//!
//! Headless voice-to-text without GUI components.
//! Useful for terminals, tmux, SSH sessions, and Termux on Android.

const std = @import("std");
const builtin = @import("builtin");
const whisper = @import("whisper.zig");
const audio = @import("audio.zig");
const config = @import("config.zig");

pub const CliOptions = struct {
    tmux_target: ?[]const u8 = null, // null = no tmux, "" = auto, "0:1" = specific pane
    clipboard: bool = false,
    duration: ?u32 = null, // seconds, null = press Enter to stop
};

pub fn run(allocator: std.mem.Allocator, options: CliOptions) !void {
    const stderr = std.io.getStdErr().writer();
    const stdout = std.io.getStdOut().writer();
    const stdin = std.io.getStdIn();

    // Load config for model/language settings
    const cfg = config.Config.load(allocator) catch config.Config{};

    // Find and load whisper model
    const model_path = whisper.findModel(allocator, cfg) orelse {
        try stderr.print("Error: No whisper model found.\n", .{});
        try stderr.print("Download a model to ~/.wysp/models/ or select one in the GUI first.\n", .{});
        return error.NoModel;
    };
    defer allocator.free(model_path);

    try stderr.print("Loading model: {s}\n", .{std.fs.path.basename(model_path)});

    var stt = whisper.Whisper.init(allocator, model_path) catch |err| {
        try stderr.print("Failed to load model: {}\n", .{err});
        return err;
    };
    defer stt.deinit();

    // Initialize audio capture
    var capture = audio.AudioCapture.init(allocator) catch |err| {
        try stderr.print("Failed to init audio: {}\n", .{err});
        return err;
    };
    defer capture.deinit();

    try stderr.print("Ready.\n\n", .{});

    // Main loop
    while (true) {
        if (options.duration) |dur| {
            try stderr.print("Recording for {} seconds... (Ctrl+C to cancel)\n", .{dur});
        } else {
            try stderr.print("Press Enter to start recording (Ctrl+C to quit): ", .{});
            _ = stdin.reader().readByte() catch break;
            try stderr.print("Recording... (press Enter to stop)\n", .{});
        }

        // Start recording
        try capture.start();

        // Wait for stop condition
        if (options.duration) |dur| {
            std.time.sleep(@as(u64, dur) * std.time.ns_per_s);
        } else {
            _ = stdin.reader().readByte() catch break;
        }

        // Stop and get samples
        const samples = try capture.stop();
        defer if (samples.len > 0) allocator.free(samples);

        // Check minimum audio length
        if (samples.len < 16000 * 0.3) {
            try stderr.print("Audio too short (minimum 0.3 seconds)\n\n", .{});
            continue;
        }

        try stderr.print("Transcribing...\n", .{});

        // Transcribe
        const lang_code = cfg.language.whisperCode();
        const text = stt.transcribeWithLanguage(samples, lang_code) catch |err| {
            try stderr.print("Transcription failed: {}\n\n", .{err});
            continue;
        };
        defer allocator.free(text);

        // Trim whitespace
        const trimmed = std.mem.trim(u8, text, " \t\n");
        if (trimmed.len == 0 or std.mem.indexOf(u8, trimmed, "[BLANK_AUDIO]") != null) {
            try stderr.print("(no speech detected)\n\n", .{});
            continue;
        }

        // Output based on options
        if (options.tmux_target) |target| {
            try sendToTmux(allocator, trimmed, target);
            try stderr.print("Sent to tmux\n\n", .{});
        } else if (options.clipboard) {
            try copyToClipboard(allocator, trimmed);
            try stderr.print("Copied to clipboard\n\n", .{});
        } else {
            // Default: print to stdout
            try stdout.print("{s}\n", .{trimmed});
            try stderr.print("\n", .{});
        }

        // If duration mode, only run once
        if (options.duration != null) break;
    }
}

fn sendToTmux(allocator: std.mem.Allocator, text: []const u8, target: []const u8) !void {
    // Escape single quotes in text for shell
    var escaped = std.ArrayList(u8).init(allocator);
    defer escaped.deinit();

    for (text) |c| {
        if (c == '\'') {
            try escaped.appendSlice("'\"'\"'");
        } else {
            try escaped.append(c);
        }
    }

    // Build tmux command
    var args = std.ArrayList([]const u8).init(allocator);
    defer args.deinit();

    try args.append("tmux");
    try args.append("send-keys");

    if (target.len > 0) {
        try args.append("-t");
        try args.append(target);
    }

    const quoted = try std.fmt.allocPrint(allocator, "'{s}'", .{escaped.items});
    defer allocator.free(quoted);
    try args.append(quoted);

    var child = std.process.Child.init(args.items, allocator);
    child.stderr_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    _ = try child.spawnAndWait();
}

fn copyToClipboard(allocator: std.mem.Allocator, text: []const u8) !void {
    const clipboard_cmds = if (builtin.os.tag == .linux)
        // Try wayland first, then X11
        [_][]const []const u8{
            &[_][]const u8{ "wl-copy", "--" },
            &[_][]const u8{ "xclip", "-selection", "clipboard" },
            &[_][]const u8{ "xsel", "--clipboard", "--input" },
            &[_][]const u8{"termux-clipboard-set"}, // Termux fallback
        }
    else if (builtin.os.tag == .macos)
        [_][]const []const u8{
            &[_][]const u8{"pbcopy"},
        }
    else
        [_][]const []const u8{};

    for (clipboard_cmds) |cmd| {
        var child = std.process.Child.init(cmd, allocator);
        child.stdin_behavior = .Pipe;
        child.stderr_behavior = .Ignore;
        child.stdout_behavior = .Ignore;

        if (child.spawn()) |_| {
            if (child.stdin) |stdin| {
                stdin.writeAll(text) catch {};
                stdin.close();
                child.stdin = null;
            }
            _ = child.wait() catch {};
            return;
        } else |_| {
            continue;
        }
    }

    return error.NoClipboardTool;
}
