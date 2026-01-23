//! Wysp - Local voice input tool
//!
//! Completely local, privacy-respecting speech-to-text.
//! Built on Ziew's HeadlessApp with tray, hotkeys, and whisper plugins.

const std = @import("std");
const ziew = @import("ziew");
const hotkeys = ziew.plugins.hotkeys;
const whisper = ziew.plugins.whisper;

// Wysp-specific implementations (keep these - they have more features than ziew's plugins)
const tray = @import("tray.zig");
const inject = @import("inject.zig");
const overlay = @import("overlay.zig");
const config = @import("config.zig");
const cli = @import("cli.zig");

// Global state for callbacks
var g_recorder: ?*whisper.Recorder = null;
var g_injector: ?*inject.TextInjector = null;
var g_app: ?*ziew.HeadlessApp = null;
var g_allocator: std.mem.Allocator = undefined;
var g_config: config.Config = .{};

// Settings
var g_toggle_mode: bool = false;
var g_is_recording: bool = false;
var g_is_processing: bool = false;

// Recent transcriptions (circular buffer)
const MAX_RECENT = 10;
var g_recent: [MAX_RECENT]?[]const u8 = [_]?[]const u8{null} ** MAX_RECENT;
var g_recent_index: usize = 0;
var g_recent_count: usize = 0;

fn addRecent(text: []const u8) void {
    // Free old entry if exists
    if (g_recent[g_recent_index]) |old| {
        g_allocator.free(old);
    }
    // Store copy
    g_recent[g_recent_index] = g_allocator.dupe(u8, text) catch null;
    g_recent_index = (g_recent_index + 1) % MAX_RECENT;
    if (g_recent_count < MAX_RECENT) g_recent_count += 1;
}

pub fn getRecentTranscriptions() []const ?[]const u8 {
    return g_recent[0..g_recent_count];
}

pub fn clearRecentTranscriptions() void {
    for (&g_recent) |*entry| {
        if (entry.*) |text| {
            g_allocator.free(text);
            entry.* = null;
        }
    }
    g_recent_index = 0;
    g_recent_count = 0;
}

pub fn setToggleMode(enabled: bool) void {
    g_toggle_mode = enabled;
    // If switching to hold mode while recording, stop recording
    if (!enabled and g_is_recording) {
        stopRecordingAndTranscribe();
    }
}

pub fn isToggleMode() bool {
    return g_toggle_mode;
}

fn startRecording() void {
    const recorder = g_recorder orelse return;
    if (g_is_recording) return;
    if (g_is_processing) return; // Block while still processing previous recording

    recorder.startRecording() catch return;
    g_is_recording = true;
    tray.setRecording(true);
    overlay.show();
}

fn stopRecordingAndTranscribe() void {
    const recorder = g_recorder orelse return;
    const injector = g_injector orelse return;

    if (!g_is_recording) return;
    g_is_recording = false;
    g_is_processing = true;

    tray.setRecording(false);
    overlay.setText("Processing...");

    defer {
        g_is_processing = false;
        overlay.hide();
    }

    // Transcribe with configured language
    const lang_code = g_config.language.whisperCode();
    const text = recorder.stopAndTranscribeWithLanguage(lang_code) catch return;
    defer g_allocator.free(text);

    if (text.len == 0) return;

    // Trim leading/trailing whitespace
    const trimmed = std.mem.trim(u8, text, " \t\n");
    if (trimmed.len == 0) return;

    // Skip if whisper detected silence
    if (std.mem.indexOf(u8, trimmed, "[BLANK_AUDIO]") != null) return;

    // Add to recent transcriptions
    addRecent(trimmed);

    // Inject text
    injector.typeText(trimmed) catch return;
}

fn onKeyPress() void {
    if (g_toggle_mode) {
        // Toggle mode: tap to start/stop
        if (g_is_recording) {
            stopRecordingAndTranscribe();
        } else {
            startRecording();
        }
    } else {
        // Hold mode: press to start
        startRecording();
    }
}

fn onKeyRelease() void {
    if (!g_toggle_mode) {
        // Hold mode: release to stop
        stopRecordingAndTranscribe();
    }
    // In toggle mode, release does nothing
}

fn onQuit() void {
    if (g_app) |app| {
        app.terminate();
    }
}

pub fn getHotkeyString() ?[]const u8 {
    return g_config.hotkey.format(g_allocator) catch null;
}

pub fn getConfig() config.Config {
    return g_config;
}

pub fn setConfig(cfg: config.Config) void {
    g_config = cfg;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    g_allocator = allocator;

    const stderr = std.io.getStdErr().writer();

    // Parse command line arguments
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    var cli_mode = false;
    var cli_options = cli.CliOptions{};
    var show_help = false;

    _ = args.next(); // skip program name
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            show_help = true;
        } else if (std.mem.eql(u8, arg, "--cli")) {
            cli_mode = true;
        } else if (std.mem.eql(u8, arg, "--tmux")) {
            cli_mode = true;
            // Check if next arg is a target (doesn't start with -)
            if (args.next()) |next| {
                if (next.len > 0 and next[0] != '-') {
                    cli_options.tmux_target = next;
                } else {
                    cli_options.tmux_target = ""; // auto-detect
                    if (std.mem.eql(u8, next, "--clip")) {
                        cli_options.clipboard = true;
                    } else if (std.mem.eql(u8, next, "--duration")) {
                        if (args.next()) |dur| {
                            cli_options.duration = std.fmt.parseInt(u32, dur, 10) catch null;
                        }
                    }
                }
            } else {
                cli_options.tmux_target = ""; // auto-detect
            }
        } else if (std.mem.eql(u8, arg, "--clip")) {
            cli_mode = true;
            cli_options.clipboard = true;
        } else if (std.mem.eql(u8, arg, "--duration")) {
            cli_mode = true;
            if (args.next()) |dur| {
                cli_options.duration = std.fmt.parseInt(u32, dur, 10) catch null;
            }
        }
    }

    if (show_help) {
        try stderr.print(
            \\Wysp - Local voice-to-text
            \\
            \\Usage: wysp [OPTIONS]
            \\
            \\Options:
            \\  --help, -h         Show this help message
            \\  --cli              Run in CLI mode (no GUI)
            \\  --tmux [TARGET]    Send transcription to tmux pane
            \\  --clip             Copy transcription to clipboard
            \\  --duration N       Record for N seconds (default: press Enter)
            \\
            \\GUI Mode (default):
            \\  Runs in system tray. Hold hotkey to record, release to transcribe.
            \\  Right-click tray icon for settings.
            \\
            \\CLI Mode:
            \\  Press Enter to start/stop recording. Output goes to stdout.
            \\  Combine with --tmux or --clip for different output targets.
            \\
            \\Examples:
            \\  wysp                     Start GUI mode
            \\  wysp --cli               CLI mode, output to stdout
            \\  wysp --tmux              Send to last active tmux pane
            \\  wysp --tmux 0:1          Send to specific tmux pane
            \\  wysp --clip              Copy to clipboard
            \\  wysp --duration 5        Record for 5 seconds
            \\
        , .{});
        return;
    }

    if (cli_mode) {
        cli.run(allocator, cli_options) catch |err| {
            if (err != error.NoModel) {
                try stderr.print("CLI error: {}\n", .{err});
            }
        };
        return;
    }

    // Load config
    g_config = config.Config.load(allocator) catch .{};
    g_toggle_mode = g_config.toggle_mode;

    // Initialize HeadlessApp (provides GTK event loop)
    var app = try ziew.HeadlessApp.init(allocator, .{
        .name = "Wysp",
    });
    defer app.deinit();
    g_app = &app;

    // Find and load whisper model using ziew's whisper plugin
    const model_path = whisper.findModel(allocator, null) orelse {
        try stderr.print("Error: No whisper model found.\n", .{});
        try stderr.print("Download a model to ~/.ziew/models/ or ~/.wysp/models/\n", .{});
        return;
    };
    defer allocator.free(model_path);

    // Initialize whisper recorder using ziew's whisper plugin
    var recorder = whisper.Recorder.init(allocator, model_path) catch |err| {
        try stderr.print("Failed to init whisper: {}\n", .{err});
        return;
    };
    defer recorder.deinit();
    g_recorder = &recorder;

    // Initialize text injector (wysp-specific for now)
    var injector = inject.TextInjector.init(allocator) catch |err| {
        try stderr.print("Failed to init text injection: {}\n", .{err});
        return;
    };
    defer injector.deinit();
    g_injector = &injector;

    // Initialize overlay (wysp-specific visual feedback)
    overlay.create() catch |err| {
        try stderr.print("Failed to create overlay: {}\n", .{err});
        return;
    };
    defer overlay.destroy();

    // Initialize tray (wysp's own tray with full menu features)
    tray.create() catch |err| {
        try stderr.print("Failed to create tray: {}\n", .{err});
        return;
    };
    defer tray.destroy();
    tray.onQuitClick(onQuit);

    // Initialize hotkeys using ziew plugin
    hotkeys.init(allocator) catch |err| {
        try stderr.print("Failed to init hotkeys: {}\n", .{err});
        return;
    };
    defer hotkeys.deinit();

    // Parse hotkey from config
    const hotkey_str = g_config.hotkey.format(allocator) catch "Ctrl+Shift+Space";
    defer if (!std.mem.eql(u8, hotkey_str, "Ctrl+Shift+Space")) allocator.free(hotkey_str);

    const hk = hotkeys.parseHotkey(hotkey_str) catch {
        try stderr.print("Invalid hotkey config\n", .{});
        return;
    };

    // Register hotkey with press and release callbacks
    // Hold mode: press starts, release stops
    // Toggle mode: press toggles (release does nothing)
    try hotkeys.register(hk.modifiers, hk.key, onKeyPress, onKeyRelease);

    try stderr.print("Wysp running. Press {s} to record. Right-click tray to quit.\n", .{hotkey_str});

    // Run the app (blocking)
    app.run();
}
