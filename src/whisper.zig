//! Whisper.cpp bindings for speech-to-text
//!
//! Audio must be 16kHz mono float32 (WHISPER_SAMPLE_RATE = 16000)

const std = @import("std");

const c = @cImport({
    @cInclude("whisper.h");
});

pub const SAMPLE_RATE: u32 = 16000;

pub const WhisperError = error{
    ModelLoadFailed,
    TranscribeFailed,
    NoSegments,
    OutOfMemory,
};

/// Whisper speech-to-text engine
pub const Whisper = struct {
    allocator: std.mem.Allocator,
    ctx: *c.whisper_context,

    const Self = @This();

    /// Initialize with a model file path
    pub fn init(allocator: std.mem.Allocator, model_path: []const u8) !Self {
        const path_z = try allocator.dupeZ(u8, model_path);
        defer allocator.free(path_z);

        var ctx_params = c.whisper_context_default_params();
        ctx_params.flash_attn = true; // Use flash attention if available

        const ctx = c.whisper_init_from_file_with_params(path_z.ptr, ctx_params) orelse {
            return WhisperError.ModelLoadFailed;
        };

        return Self{
            .allocator = allocator,
            .ctx = ctx,
        };
    }

    /// Transcribe audio samples to text
    /// Audio must be 16kHz mono float32
    pub fn transcribe(self: *Self, audio: []const f32) ![]const u8 {
        var params = c.whisper_full_default_params(c.WHISPER_SAMPLING_GREEDY);
        params.print_progress = false;
        params.print_special = false;
        params.print_realtime = false;
        params.print_timestamps = false;
        params.language = "en";

        // Speed optimizations
        params.single_segment = false; // Allow segmentation for better accuracy
        params.no_context = true; // Don't use context from previous audio
        params.n_threads = @intCast(@min(8, std.Thread.getCpuCount() catch 4));

        const result = c.whisper_full(
            self.ctx,
            params,
            audio.ptr,
            @intCast(audio.len),
        );

        if (result != 0) {
            return WhisperError.TranscribeFailed;
        }

        const n_segments = c.whisper_full_n_segments(self.ctx);
        if (n_segments == 0) {
            return WhisperError.NoSegments;
        }

        // Collect all segment text
        var text_list = std.ArrayList(u8).init(self.allocator);
        errdefer text_list.deinit();

        var i: c_int = 0;
        while (i < n_segments) : (i += 1) {
            const segment_text = c.whisper_full_get_segment_text(self.ctx, i);
            if (segment_text != null) {
                const slice = std.mem.span(segment_text);
                try text_list.appendSlice(slice);
            }
        }

        return try text_list.toOwnedSlice();
    }

    /// Clean up resources
    pub fn deinit(self: *Self) void {
        c.whisper_free(self.ctx);
    }
};

/// Find default model in ~/.ziew/models/ or ~/.wysp/models/
pub fn findDefaultModel(allocator: std.mem.Allocator) ?[]const u8 {
    const home = std.posix.getenv("HOME") orelse return null;

    // Try ~/.ziew/models/ first (shared with ziew)
    const ziew_path = std.fmt.allocPrint(allocator, "{s}/.ziew/models/whisper-base-en.bin", .{home}) catch return null;
    if (std.fs.cwd().access(ziew_path, .{})) |_| {
        return ziew_path;
    } else |_| {
        allocator.free(ziew_path);
    }

    // Try ~/.wysp/models/
    const wysp_path = std.fmt.allocPrint(allocator, "{s}/.wysp/models/ggml-base.en.bin", .{home}) catch return null;
    if (std.fs.cwd().access(wysp_path, .{})) |_| {
        return wysp_path;
    } else |_| {
        allocator.free(wysp_path);
    }

    return null;
}
