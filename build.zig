const std = @import("std");

fn addVsLib(
    b: *std.Build,
    core_mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const vs_dep = b.dependency("vapoursynth", .{ .target = target, .optimize = optimize });
    const mod = b.createModule(.{
        .root_source_file = b.path("src/vapoursynth/plugin.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("vapoursynth", vs_dep.module("vapoursynth"));
    mod.addImport("core", core_mod);
    mod.link_libc = true;
    return b.addLibrary(.{ .name = "brawsource", .linkage = .dynamic, .root_module = mod });
}

fn addAvsLib(
    b: *std.Build,
    core_mod: *std.Build.Module,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    // AviSynth+ target is fixed: Windows x64
    const target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu });
    const mod = b.createModule(.{
        .root_source_file = b.path("src/avisynth/plugin.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("core", core_mod);
    mod.link_libc = true;
    mod.addIncludePath(b.path("vendor/avisynth_sdk"));
    mod.addIncludePath(b.path("src/avisynth"));
    mod.addCSourceFile(.{
        .file = b.path("src/avisynth/avs_loader.c"),
        .flags = &.{"-DAVSC_NO_DECLSPEC"},
    });
    const lib = b.addLibrary(.{ .name = "BRAWSource", .linkage = .dynamic, .root_module = mod });
    lib.win32_module_definition = b.path("src/avisynth/exports.def");
    return lib;
}

fn installTo(b: *std.Build, lib: *std.Build.Step.Compile, dir: []const u8) *std.Build.Step.InstallArtifact {
    return b.addInstallArtifact(lib, .{ .dest_dir = .{ .override = .{ .custom = dir } } });
}

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

    // --- plugins (separate install dirs: the AviSynth DLL differs from the
    // VS one only by case, which collides on Windows filesystems) ---
    const build_vs = b.option(bool, "vs", "Build the VapourSynth plugin") orelse true;
    var vs_lib_step: ?*std.Build.Step.Compile = null;
    if (build_vs) {
        const vs_lib = addVsLib(b, core_mod, target, optimize);
        b.getInstallStep().dependOn(&installTo(b, vs_lib, "vapoursynth").step);
        vs_lib_step = vs_lib;
    }

    const build_avs = b.option(bool, "avs", "Build the AviSynth plugin (win x64)") orelse true;
    var avs_lib_step: ?*std.Build.Step.Compile = null;
    if (build_avs) {
        const avs_lib = addAvsLib(b, core_mod, optimize);
        b.getInstallStep().dependOn(&installTo(b, avs_lib, "avisynth").step);
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
        .{ .q = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu, .glibc_version = .{ .major = 2, .minor = 17, .patch = 0 } }, .label = "release/vapoursynth-linux-x86_64" },
        .{ .q = .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu }, .label = "release/vapoursynth-windows-x86_64" },
        .{ .q = .{ .cpu_arch = .x86_64, .os_tag = .macos }, .label = "release/vapoursynth-macos-x86_64" },
        .{ .q = .{ .cpu_arch = .aarch64, .os_tag = .macos }, .label = "release/vapoursynth-macos-arm64" },
    };
    const release = b.step("release", "Build all release artifacts (ReleaseFast)");
    for (release_targets) |rt| {
        const rlib = addVsLib(b, core_mod, b.resolveTargetQuery(rt.q), .ReleaseFast);
        release.dependOn(&installTo(b, rlib, rt.label).step);
    }
    const avs_release = addAvsLib(b, core_mod, .ReleaseFast);
    release.dependOn(&installTo(b, avs_release, "release/avisynth-windows-x86_64").step);
}
