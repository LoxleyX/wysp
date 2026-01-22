//! Wysp - Local voice input tool
//!
//! Completely local, privacy-respecting speech-to-text.
//! Configurable hotkey (default: Ctrl+Shift+Space) to record and transcribe.

const std = @import("std");
const whisper = @import("whisper.zig");
const audio = @import("audio.zig");
const inject = @import("inject.zig");
const hotkey = @import("hotkey.zig");
const tray = @import("tray.zig");
const overlay = @import("overlay.zig");
const config = @import("config.zig");

// Global state for callbacks
var g_capture: ?*audio.AudioCapture = null;
var g_stt: ?*whisper.Whisper = null;
var g_injector: ?*inject.TextInjector = null;
var g_allocator: std.mem.Allocator = undefined;
var g_running: bool = true;
var g_config: config.Config = .{};

// Settings
var g_toggle_mode: bool = false;
var g_is_recording: bool = false;

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
    const capture = g_capture orelse return;
    if (g_is_recording) return;

    capture.start() catch return;
    g_is_recording = true;
    tray.setRecording(true);
    overlay.show();
}

fn stopRecordingAndTranscribe() void {
    const capture = g_capture orelse return;
    const stt = g_stt orelse return;
    const injector = g_injector orelse return;

    if (!g_is_recording) return;
    g_is_recording = false;

    tray.setRecording(false);
    overlay.setText("Processing...");

    const samples = capture.stop() catch {
        overlay.hide();
        return;
    };
    defer if (samples.len > 0) g_allocator.free(samples);

    // Need at least 0.3 seconds of audio
    if (samples.len < 16000 * 0.3) {
        overlay.hide();
        return;
    }

    // Transcribe
    const text = stt.transcribe(samples) catch {
        overlay.hide();
        return;
    };
    defer g_allocator.free(text);

    overlay.hide();

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
    g_running = false;
}

pub fn getHotkeyString() ?[]const u8 {
    return g_config.hotkey.format(g_allocator) catch null;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    g_allocator = allocator;

    const stderr = std.io.getStdErr().writer();

    // Load config
    g_config = config.Config.load(allocator) catch .{};
    g_toggle_mode = g_config.toggle_mode;

    // Find and load whisper model (suppress stdout during load)
    const model_path = whisper.findDefaultModel(allocator) orelse {
        try stderr.print("Error: No whisper model found.\n", .{});
        try stderr.print("Download a model to ~/.ziew/models/ or ~/.wysp/models/\n", .{});
        return;
    };
    defer allocator.free(model_path);

    var stt = whisper.Whisper.init(allocator, model_path) catch |err| {
        try stderr.print("Failed to load model: {}\n", .{err});
        return;
    };
    defer stt.deinit();
    g_stt = &stt;

    // Initialize audio capture
    var capture = audio.AudioCapture.init(allocator) catch |err| {
        try stderr.print("Failed to init audio: {}\n", .{err});
        return;
    };
    defer capture.deinit();
    g_capture = &capture;

    // Initialize text injector
    var injector = inject.TextInjector.init(allocator) catch |err| {
        try stderr.print("Failed to init text injection: {}\n", .{err});
        return;
    };
    defer injector.deinit();
    g_injector = &injector;

    // Initialize overlay
    overlay.create() catch |err| {
        try stderr.print("Failed to create overlay: {}\n", .{err});
        return;
    };
    defer overlay.destroy();

    // Initialize tray
    tray.create() catch |err| {
        try stderr.print("Failed to create tray: {}\n", .{err});
        return;
    };
    defer tray.destroy();
    tray.onQuitClick(onQuit);

    // Initialize hotkey with config
    hotkey.initWithConfig(g_config.hotkey) catch |err| {
        try stderr.print("Failed to init hotkey: {}\n", .{err});
        return;
    };
    defer hotkey.deinit();
    hotkey.setCallbacks(onKeyPress, onKeyRelease);

    // Show startup message with configured hotkey
    const hotkey_str = g_config.hotkey.format(allocator) catch "Ctrl+Shift+Space";
    defer if (!std.mem.eql(u8, hotkey_str, "Ctrl+Shift+Space")) allocator.free(hotkey_str);
    try stderr.print("Wysp running. Hold {s} to record. Right-click tray to quit.\n", .{hotkey_str});

    // Main loop - process GTK events
    while (g_running) {
        overlay.processEvents();
        std.time.sleep(50 * std.time.ns_per_ms);
    }
}
