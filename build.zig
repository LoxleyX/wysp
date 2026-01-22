const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "wysp",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Audio capture (C wrapper around miniaudio)
    exe.addIncludePath(b.path("vendor"));
    exe.addCSourceFile(.{
        .file = b.path("vendor/audio_capture.c"),
        .flags = &.{"-DMINIAUDIO_IMPLEMENTATION"},
    });

    // System libraries
    exe.linkLibC();

    const target_os = target.result.os.tag;

    if (target_os == .linux) {
        // Whisper.cpp libraries - check env vars first (CI), then fallback to ~/.ziew/
        const home = std.posix.getenv("HOME") orelse "/home/user";
        const whisper_lib = std.posix.getenv("WHISPER_LIB") orelse b.fmt("{s}/.ziew/lib", .{home});
        const whisper_include = std.posix.getenv("WHISPER_INCLUDE") orelse b.fmt("{s}/.ziew/include", .{home});

        exe.addLibraryPath(.{ .cwd_relative = whisper_lib });
        exe.addIncludePath(.{ .cwd_relative = whisper_include });
        exe.linkSystemLibrary("whisper");
        exe.linkSystemLibrary("ggml");
        exe.linkSystemLibrary("ggml-base");
        exe.linkSystemLibrary("ggml-cpu");

        // Required by miniaudio on Linux
        exe.linkSystemLibrary("pthread");
        exe.linkSystemLibrary("m");
        exe.linkSystemLibrary("dl");

        // X11 for text injection and hotkeys
        exe.linkSystemLibrary("X11");
        exe.linkSystemLibrary("Xtst");

        // GTK for tray icon and overlay
        exe.linkSystemLibrary("gtk+-3.0");

        // Set rpath so it finds whisper libs at runtime
        exe.addRPath(.{ .cwd_relative = whisper_lib });
    } else if (target_os == .windows) {
        // Windows libraries - check env vars for whisper location
        if (std.posix.getenv("WHISPER_LIB")) |whisper_lib| {
            exe.addLibraryPath(.{ .cwd_relative = whisper_lib });
        }
        if (std.posix.getenv("WHISPER_INCLUDE")) |whisper_include| {
            exe.addIncludePath(.{ .cwd_relative = whisper_include });
        }
        exe.linkSystemLibrary("whisper");
        exe.linkSystemLibrary("ggml");
        exe.linkSystemLibrary("ggml-base");
        exe.linkSystemLibrary("ggml-cpu");

        // Windows system libraries
        exe.linkSystemLibrary("user32");
        exe.linkSystemLibrary("shell32");
        exe.linkSystemLibrary("kernel32");
        exe.linkSystemLibrary("ole32");
        exe.linkSystemLibrary("winmm");
    }

    b.installArtifact(exe);

    // Run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run wysp");
    run_step.dependOn(&run_cmd.step);
}
