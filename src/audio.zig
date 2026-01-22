//! Audio capture via miniaudio (C wrapper)
//!
//! Captures from default microphone at 16kHz mono float32
//! (the format required by Whisper)

const std = @import("std");

const c = @cImport({
    @cInclude("audio_capture.h");
});

pub const AudioError = error{
    InitFailed,
    DeviceFailed,
    StartFailed,
    NotRecording,
};

/// Audio capture state
pub const AudioCapture = struct {
    allocator: std.mem.Allocator,
    handle: *c.AudioCapture,

    const Self = @This();

    /// Initialize audio capture (16kHz mono)
    pub fn init(allocator: std.mem.Allocator) !Self {
        const handle = c.audio_capture_create() orelse {
            return AudioError.DeviceFailed;
        };

        return Self{
            .allocator = allocator,
            .handle = handle,
        };
    }

    /// Start recording
    pub fn start(self: *Self) !void {
        if (c.audio_capture_start(self.handle) != 0) {
            return AudioError.StartFailed;
        }
    }

    /// Stop recording and return captured audio
    pub fn stop(self: *Self) ![]const f32 {
        // Get sample count
        const count: usize = @intCast(c.audio_capture_stop(self.handle, null, 0));

        if (count == 0) {
            return &[_]f32{};
        }

        // Allocate buffer and copy samples
        const buffer = try self.allocator.alloc(f32, count);
        _ = c.audio_capture_stop(self.handle, buffer.ptr, @intCast(count));

        return buffer;
    }

    /// Clean up resources
    pub fn deinit(self: *Self) void {
        c.audio_capture_destroy(self.handle);
    }

    /// Get debug info
    pub fn getCallbackCount(self: *Self) u32 {
        return @intCast(c.audio_capture_get_callback_count(self.handle));
    }
};
