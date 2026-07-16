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
    target: std.Build.ResolvedTarget, // always Windows x64, CPU model may vary
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
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
        const avs_target = b.resolveTargetQuery(avs_target_query);
        const avs_lib = addAvsLib(b, core_mod, avs_target, optimize);
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
    // x86_64 ships twice: baseline (SSE2, runs on anything) and -v3 (AVX2 +
    // F16C, CPUs from ~2013) — the pixel copy loops vectorize far better
    // under v3 (pshufb de-interleave, hardware f32->f16 instead of a libcall
    // per sample). Intel macOS gets ivybridge (AVX + F16C, no AVX2): the Mac
    // Pro 2013 is the oldest machine that runs a macOS the SDK supports.
    const release_targets = [_]struct { q: std.Target.Query, label: []const u8 }{
        // glibc pinned old for broad distro compatibility (dlopen only)
        .{ .q = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu, .glibc_version = .{ .major = 2, .minor = 17, .patch = 0 } }, .label = "release/vapoursynth-linux-x86_64" },
        .{ .q = .{ .cpu_arch = .x86_64, .cpu_model = v3_model, .os_tag = .linux, .abi = .gnu, .glibc_version = .{ .major = 2, .minor = 17, .patch = 0 } }, .label = "release/vapoursynth-linux-x86_64-v3" },
        .{ .q = .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu }, .label = "release/vapoursynth-windows-x86_64" },
        .{ .q = .{ .cpu_arch = .x86_64, .cpu_model = v3_model, .os_tag = .windows, .abi = .gnu }, .label = "release/vapoursynth-windows-x86_64-v3" },
        // macOS floor = 12.0: the bundled BRAW 5.1 runtime is built with
        // minos 12.0, and Zig's default (13.0) would contradict the wheel
        // platform tags (macosx_12_0). Keep all three in sync.
        .{ .q = .{ .cpu_arch = .x86_64, .cpu_model = .{ .explicit = &std.Target.x86.cpu.ivybridge }, .os_tag = .macos, .os_version_min = .{ .semver = .{ .major = 12, .minor = 0, .patch = 0 } } }, .label = "release/vapoursynth-macos-x86_64" },
        .{ .q = .{ .cpu_arch = .aarch64, .os_tag = .macos, .os_version_min = .{ .semver = .{ .major = 12, .minor = 0, .patch = 0 } } }, .label = "release/vapoursynth-macos-arm64" },
    };
    const release = b.step("release", "Build all release artifacts (ReleaseFast)");
    // releases must never ship with failing unit tests
    release.dependOn(&b.addRunArtifact(core_tests).step);
    for (release_targets) |rt| {
        const rlib = addVsLib(b, core_mod, b.resolveTargetQuery(rt.q), .ReleaseFast);
        // no debug sections / absolute build paths in shipped binaries;
        // stripped builds are also byte-reproducible across checkouts
        rlib.root_module.strip = true;
        release.dependOn(&installTo(b, rlib, rt.label).step);
    }
    const avs_release = addAvsLib(b, core_mod, b.resolveTargetQuery(avs_target_query), .ReleaseFast);
    avs_release.root_module.strip = true;
    release.dependOn(&installTo(b, avs_release, "release/avisynth-windows-x86_64").step);
    var avs_v3_query = avs_target_query;
    avs_v3_query.cpu_model = v3_model;
    const avs_release_v3 = addAvsLib(b, core_mod, b.resolveTargetQuery(avs_v3_query), .ReleaseFast);
    avs_release_v3.root_module.strip = true;
    release.dependOn(&installTo(b, avs_release_v3, "release/avisynth-windows-x86_64-v3").step);
}

const v3_model: std.Target.Query.CpuModel = .{ .explicit = &std.Target.x86.cpu.x86_64_v3 };

// AviSynth+ runs on Windows x64 only; the CPU model is the one degree of freedom.
const avs_target_query: std.Target.Query = .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu };
