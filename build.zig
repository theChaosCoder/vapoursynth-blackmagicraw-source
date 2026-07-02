const std = @import("std");

pub fn build(b: *std.Build) void {
    var target = b.standardTargetOptions(.{});
    // On linux-gnu, always link zig's bundled glibc instead of the system
    // CRT: bleeding-edge distro crt1.o (gcc 16 .sframe sections) breaks the
    // self-hosted linker, and pinning glibc keeps builds reproducible.
    if (target.query.isNative() and target.result.os.tag == .linux and target.result.abi == .gnu) {
        var q = target.query;
        q.glibc_version = target.result.os.version_range.linux.glibc;
        target = b.resolveTargetQuery(q);
    }
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

    // Host-free shared core: BRAW SDK binding + decoder bridge. Created
    // target-less so every consumer compiles it under its own target.
    const core_mod = b.createModule(.{ .root_source_file = b.path("src/core/core.zig") });

    // --- unit tests (native) ---
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/core/core.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.link_libc = true;
    const core_tests = b.addTest(.{ .root_module = test_mod });
    const test_step = b.step("test", "Run core unit tests");
    test_step.dependOn(&b.addRunArtifact(core_tests).step);

    // --- braw-probe CLI (native debugging/verification tool) ---
    const probe_mod = b.createModule(.{
        .root_source_file = b.path("tools/braw-probe/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    probe_mod.addImport("core", core_mod);
    probe_mod.link_libc = true;
    const probe = b.addExecutable(.{ .name = "braw-probe", .root_module = probe_mod });
    b.installArtifact(probe);

    // --- VapourSynth plugin ---
    const build_vs = b.option(bool, "vs", "Build the VapourSynth plugin") orelse true;
    var vs_lib_step: ?*std.Build.Step.Compile = null;
    if (build_vs) {
        const vs_dep = b.dependency("vapoursynth", .{ .target = target, .optimize = optimize });
        const vs_mod = b.createModule(.{
            .root_source_file = b.path("src/vapoursynth/plugin.zig"),
            .target = target,
            .optimize = optimize,
        });
        vs_mod.addImport("vapoursynth", vs_dep.module("vapoursynth"));
        vs_mod.addImport("core", core_mod);
        vs_mod.link_libc = true;
        const vs_lib = b.addLibrary(.{ .name = "brawsource", .linkage = .dynamic, .root_module = vs_mod });
        // separate dirs: the AviSynth DLL differs from the VS one only by
        // case, which collides on Windows filesystems
        const vs_install = b.addInstallArtifact(vs_lib, .{ .dest_dir = .{ .override = .{ .custom = "vapoursynth" } } });
        b.getInstallStep().dependOn(&vs_install.step);
        vs_lib_step = vs_lib;
    }

    // --- AviSynth+ plugin (Windows x64 only) ---
    const build_avs = b.option(bool, "avs", "Build the AviSynth plugin (win x64)") orelse true;
    var avs_lib_step: ?*std.Build.Step.Compile = null;
    if (build_avs) {
        const avs_target = b.resolveTargetQuery(.{
            .cpu_arch = .x86_64,
            .os_tag = .windows,
            .abi = .gnu,
        });
        const avs_mod = b.createModule(.{
            .root_source_file = b.path("src/avisynth/plugin.zig"),
            .target = avs_target,
            .optimize = optimize,
        });
        avs_mod.addImport("core", core_mod);
        avs_mod.link_libc = true;
        avs_mod.addIncludePath(b.path("vendor/avisynth_sdk"));
        avs_mod.addIncludePath(b.path("src/avisynth"));
        avs_mod.addCSourceFile(.{
            .file = b.path("src/avisynth/avs_loader.c"),
            .flags = &.{"-DAVSC_NO_DECLSPEC"},
        });
        const avs_lib = b.addLibrary(.{ .name = "BRAWSource", .linkage = .dynamic, .root_module = avs_mod });
        avs_lib.win32_module_definition = b.path("src/avisynth/exports.def");
        const avs_install = b.addInstallArtifact(avs_lib, .{ .dest_dir = .{ .override = .{ .custom = "avisynth" } } });
        b.getInstallStep().dependOn(&avs_install.step);
        avs_lib_step = avs_lib;
    }

    // --- compile check for ZLS build-on-save ---
    const check = b.step("check", "Compile-check without emitting binaries");
    check.dependOn(&core_tests.step);
    check.dependOn(&probe.step);
    if (vs_lib_step) |l| check.dependOn(&l.step);
    if (avs_lib_step) |l| check.dependOn(&l.step);

    // --- release matrix: all shipped targets, ReleaseFast ---
    const release_targets = [_]struct { q: std.Target.Query, label: []const u8 }{
        // glibc pinned old for broad distro compatibility (dlopen only)
        .{ .q = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu, .glibc_version = .{ .major = 2, .minor = 17, .patch = 0 } }, .label = "vapoursynth-linux-x86_64" },
        .{ .q = .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu }, .label = "vapoursynth-windows-x86_64" },
        .{ .q = .{ .cpu_arch = .x86_64, .os_tag = .macos }, .label = "vapoursynth-macos-x86_64" },
        .{ .q = .{ .cpu_arch = .aarch64, .os_tag = .macos }, .label = "vapoursynth-macos-arm64" },
    };
    const release = b.step("release", "Build all release artifacts (ReleaseFast)");
    for (release_targets) |rt| {
        const rtarget = b.resolveTargetQuery(rt.q);
        const vs_dep = b.dependency("vapoursynth", .{ .target = rtarget, .optimize = .ReleaseFast });
        const rmod = b.createModule(.{
            .root_source_file = b.path("src/vapoursynth/plugin.zig"),
            .target = rtarget,
            .optimize = .ReleaseFast,
        });
        rmod.addImport("vapoursynth", vs_dep.module("vapoursynth"));
        rmod.addImport("core", core_mod);
        rmod.link_libc = true;
        const rlib = b.addLibrary(.{ .name = "brawsource", .linkage = .dynamic, .root_module = rmod });
        const inst = b.addInstallArtifact(rlib, .{ .dest_dir = .{ .override = .{ .custom = b.fmt("release/{s}", .{rt.label}) } } });
        release.dependOn(&inst.step);
    }
    {
        const avs_target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu });
        const rmod = b.createModule(.{
            .root_source_file = b.path("src/avisynth/plugin.zig"),
            .target = avs_target,
            .optimize = .ReleaseFast,
        });
        rmod.addImport("core", core_mod);
        rmod.link_libc = true;
        rmod.addIncludePath(b.path("vendor/avisynth_sdk"));
        rmod.addIncludePath(b.path("src/avisynth"));
        rmod.addCSourceFile(.{
            .file = b.path("src/avisynth/avs_loader.c"),
            .flags = &.{"-DAVSC_NO_DECLSPEC"},
        });
        const rlib = b.addLibrary(.{ .name = "BRAWSource", .linkage = .dynamic, .root_module = rmod });
        rlib.win32_module_definition = b.path("src/avisynth/exports.def");
        const inst = b.addInstallArtifact(rlib, .{ .dest_dir = .{ .override = .{ .custom = "release/avisynth-windows-x86_64" } } });
        release.dependOn(&inst.step);
    }
}
