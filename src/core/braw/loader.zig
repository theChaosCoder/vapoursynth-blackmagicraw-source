//! Runtime loading of the Blackmagic RAW library (the plugin is never linked
//! against it). Mirrors the SDK's own BlackmagicRawAPIDispatch.cpp:
//! dlopen/LoadLibraryExW + resolve `CreateBlackmagicRawFactoryInstance`.
//!
//! One library handle is shared process-wide (the factory is a singleton in
//! the SDK anyway); `acquire`/`release` refcount it.

const std = @import("std");
const builtin = @import("builtin");
const api = @import("api.zig");
const sync = @import("../sync.zig");

const is_windows = api.is_windows;
const is_macos = api.is_macos;

pub const lib_file_name = if (is_windows)
    "BlackmagicRawAPI.dll"
else if (is_macos)
    "BlackmagicRawAPI.framework/BlackmagicRawAPI"
else
    "libBlackmagicRawAPI.so";

/// Primary deployment location: a per-OS deps folder next to the plugin
/// binary. The runtime libraries (BlackmagicRawAPI + sibling decoders)
/// are simply copied in there.
pub const deps_subdir = if (is_windows)
    "blackmagic_win_deps"
else if (is_macos)
    "blackmagic_mac_deps"
else
    "blackmagic_linux_deps";

/// pip-wheel deployment location: the plugin lands in
/// site-packages/vapoursynth/plugins/, and the runtime lives two levels up
/// in site-packages/vapoursynth_brawsource.libs/ (the auditwheel
/// convention, e.g. BestSource). It cannot live inside plugins/: the
/// VapourSynth autoloader recursively tries every *.so there and warns
/// about each runtime library.
pub const pip_libs_subdir = ".." ++ std.fs.path.sep_str ++ ".." ++ std.fs.path.sep_str ++ "vapoursynth_brawsource.libs";

/// Default install locations of the Blackmagic RAW runtime per OS
/// (Blackmagic RAW desktop software and DaVinci Resolve).
pub const default_dirs: []const []const u8 = if (is_windows) &.{
    "C:\\Program Files\\Blackmagic Design\\Blackmagic RAW\\BlackmagicRawAPI",
    "C:\\Program Files (x86)\\Blackmagic Design\\Blackmagic RAW\\BlackmagicRawAPI",
    "C:\\Program Files\\Blackmagic Design\\DaVinci Resolve",
} else if (is_macos) &.{
    "/Applications/Blackmagic RAW/Blackmagic RAW SDK/Mac/Libraries",
    "/Applications/DaVinci Resolve/DaVinci Resolve.app/Contents/Libraries",
    "/Library/Application Support/Blackmagic Design/Blackmagic RAW/Libraries",
} else &.{
    "/usr/lib64/blackmagic/BlackmagicRAWPlayer/BlackmagicRawAPI",
    "/usr/lib64/blackmagic/BlackmagicRAWSpeedTest/BlackmagicRawAPI",
    "/usr/lib/blackmagic/BlackmagicRAWPlayer/BlackmagicRawAPI",
    "/opt/resolve/libs",
};

pub const env_var = "BRAW_LIBRARY";

// Win32 externs (zig 0.16's std.os.windows.kernel32 no longer declares these)
const win32 = if (is_windows) struct {
    pub const INVALID_FILE_ATTRIBUTES: u32 = 0xFFFF_FFFF;
    pub const FILE_ATTRIBUTE_DIRECTORY: u32 = 0x10;
    pub const LOAD_WITH_ALTERED_SEARCH_PATH: u32 = 0x8;
    pub extern "kernel32" fn GetFileAttributesW([*:0]const u16) callconv(.winapi) u32;
    pub extern "kernel32" fn LoadLibraryExW([*:0]const u16, ?*anyopaque, u32) callconv(.winapi) ?*anyopaque;
    pub extern "kernel32" fn GetProcAddress(*anyopaque, [*:0]const u8) callconv(.winapi) ?*const anyopaque;
} else struct {};

// Filesystem probing goes through libc/win32 directly: the core must stay
// free of the std.Io plumbing (it runs inside host plugin threads).
fn pathExists(path: [:0]const u8) bool {
    if (api.is_windows) {
        const w = std.unicode.utf8ToUtf16LeAllocZ(std.heap.c_allocator, path) catch return false;
        defer std.heap.c_allocator.free(w);
        return win32.GetFileAttributesW(w.ptr) != win32.INVALID_FILE_ATTRIBUTES;
    }
    return std.c.access(path.ptr, 0) == 0;
}

fn isDir(path: []const u8) bool {
    const z = std.heap.c_allocator.dupeZ(u8, path) catch return false;
    defer std.heap.c_allocator.free(z);
    if (api.is_windows) {
        const w = std.unicode.utf8ToUtf16LeAllocZ(std.heap.c_allocator, z) catch return false;
        defer std.heap.c_allocator.free(w);
        const attrs = win32.GetFileAttributesW(w.ptr);
        if (attrs == win32.INVALID_FILE_ATTRIBUTES) return false;
        return attrs & win32.FILE_ATTRIBUTE_DIRECTORY != 0;
    }
    const d = std.c.opendir(z.ptr) orelse return false;
    _ = std.c.closedir(d);
    return true;
}

fn getEnv(name: [:0]const u8) ?[]const u8 {
    const v = std.c.getenv(name.ptr) orelse return null;
    const s = std.mem.span(v);
    return if (s.len == 0) null else s;
}

const CreateFactoryFn = *const fn () callconv(.c) ?*api.IBlackmagicRawFactory;
const VariantFn = *const fn (*api.Variant) callconv(.c) api.HRESULT;
const SafeArrayDataFn = *const fn (*api.SafeArray, *?*anyopaque) callconv(.c) api.HRESULT;
const SafeArrayNoArgFn = *const fn (*api.SafeArray) callconv(.c) api.HRESULT;

pub const Lib = struct {
    handle: *anyopaque,
    path: [:0]u8,
    refs: usize,

    createFactory: CreateFactoryFn,
    variantInit: VariantFn,
    variantClear: VariantFn,
    safeArrayAccessData: SafeArrayDataFn,
    safeArrayUnaccessData: SafeArrayNoArgFn,
};

var global: ?*Lib = null;
var global_mutex: sync.Mutex = .{};

pub const Error = error{ LibraryNotFound, SymbolNotFound, OutOfMemory };

/// Build the candidate list for diagnostics and probing.
/// `explicit` may be a file or a directory. Caller frees the result.
pub fn candidatePaths(
    gpa: std.mem.Allocator,
    explicit: ?[]const u8,
    plugin_dir: ?[]const u8,
) ![][:0]u8 {
    var list: std.ArrayList([:0]u8) = .empty;
    errdefer {
        for (list.items) |p| gpa.free(p);
        list.deinit(gpa);
    }

    // an explicit path or env var may point at the library file itself or
    // at the directory containing it
    const appendFileOrDir = struct {
        fn f(g: std.mem.Allocator, l: *std.ArrayList([:0]u8), base: []const u8) !void {
            if (isDir(base)) {
                try l.append(g, try std.fs.path.joinZ(g, &.{ base, lib_file_name }));
            } else {
                try l.append(g, try g.dupeZ(u8, base));
            }
        }
    }.f;

    if (explicit) |e| {
        try appendFileOrDir(gpa, &list, e);
        return try list.toOwnedSlice(gpa);
    }
    if (getEnv(env_var)) |env_val| {
        try appendFileOrDir(gpa, &list, env_val);
        return try list.toOwnedSlice(gpa);
    }

    if (plugin_dir) |pd| {
        try list.append(gpa, try std.fs.path.joinZ(gpa, &.{ pd, deps_subdir, lib_file_name }));
        try list.append(gpa, try std.fs.path.joinZ(gpa, &.{ pd, pip_libs_subdir, lib_file_name }));
        try list.append(gpa, try std.fs.path.joinZ(gpa, &.{ pd, "BlackmagicRawAPI", lib_file_name }));
        try list.append(gpa, try std.fs.path.joinZ(gpa, &.{ pd, lib_file_name }));
    }
    for (default_dirs) |d| {
        try list.append(gpa, try std.fs.path.joinZ(gpa, &.{ d, lib_file_name }));
    }
    return try list.toOwnedSlice(gpa);
}

pub fn freeCandidates(gpa: std.mem.Allocator, paths: [][:0]u8) void {
    for (paths) |p| gpa.free(p);
    gpa.free(paths);
}

fn dlopenAbs(path: [:0]const u8) ?*anyopaque {
    if (is_windows) {
        const w = std.unicode.utf8ToUtf16LeAllocZ(std.heap.c_allocator, path) catch return null;
        defer std.heap.c_allocator.free(w);
        // LOAD_WITH_ALTERED_SEARCH_PATH so sibling decoder DLLs resolve.
        return win32.LoadLibraryExW(w.ptr, null, win32.LOAD_WITH_ALTERED_SEARCH_PATH);
    }
    return std.c.dlopen(path.ptr, .{ .NOW = true, .GLOBAL = false });
}

fn dlsymFn(comptime T: type, handle: *anyopaque, name: [:0]const u8) ?T {
    if (is_windows) {
        const p = win32.GetProcAddress(handle, name.ptr) orelse return null;
        return @ptrCast(@alignCast(p));
    }
    const p = std.c.dlsym(handle, name.ptr) orelse return null;
    return @ptrCast(@alignCast(p));
}

/// Acquire the shared library handle, loading it on first use.
/// On failure returns LibraryNotFound; `diagnostics` (optional) receives a
/// newline-separated list of every path tried (caller frees).
pub fn acquire(
    gpa: std.mem.Allocator,
    explicit: ?[]const u8,
    plugin_dir: ?[]const u8,
    diagnostics: ?*?[]u8,
) Error!*Lib {
    global_mutex.lock();
    defer global_mutex.unlock();

    if (global) |lib| {
        lib.refs += 1;
        return lib;
    }

    const paths = candidatePaths(gpa, explicit, plugin_dir) catch return error.OutOfMemory;
    defer freeCandidates(gpa, paths);

    // The Lib registration lives for the rest of the process (the SDK spins
    // up worker threads; unloading from a plugin is unsafe), so it must not
    // borrow the caller's allocator.
    const process_gpa = std.heap.c_allocator;

    var handle: ?*anyopaque = null;
    var loaded_path: ?[:0]u8 = null;
    for (paths) |p| {
        if (!pathExists(p)) continue;
        if (dlopenAbs(p)) |h| {
            handle = h;
            loaded_path = process_gpa.dupeZ(u8, p) catch return error.OutOfMemory;
            break;
        }
    }
    const h = handle orelse {
        if (diagnostics) |d| {
            var buf: std.ArrayList(u8) = .empty;
            for (paths) |p| {
                buf.appendSlice(gpa, p) catch break;
                buf.append(gpa, '\n') catch break;
            }
            d.* = buf.toOwnedSlice(gpa) catch null;
        }
        return error.LibraryNotFound;
    };

    const lib = process_gpa.create(Lib) catch return error.OutOfMemory;
    errdefer process_gpa.destroy(lib);

    // On Windows Variant/SafeArray helpers come from oleaut32 (see
    // variant.zig); the BRAW dll only provides the factory.
    if (is_windows) {
        lib.* = .{
            .handle = h,
            .path = loaded_path.?,
            .refs = 1,
            .createFactory = dlsymFn(CreateFactoryFn, h, "CreateBlackmagicRawFactoryInstance") orelse
                return error.SymbolNotFound,
            .variantInit = undefined,
            .variantClear = undefined,
            .safeArrayAccessData = undefined,
            .safeArrayUnaccessData = undefined,
        };
    } else {
        lib.* = .{
            .handle = h,
            .path = loaded_path.?,
            .refs = 1,
            .createFactory = dlsymFn(CreateFactoryFn, h, "CreateBlackmagicRawFactoryInstance") orelse
                return error.SymbolNotFound,
            .variantInit = dlsymFn(VariantFn, h, "VariantInit") orelse
                return error.SymbolNotFound,
            .variantClear = dlsymFn(VariantFn, h, "VariantClear") orelse
                return error.SymbolNotFound,
            .safeArrayAccessData = dlsymFn(SafeArrayDataFn, h, "SafeArrayAccessData") orelse
                return error.SymbolNotFound,
            .safeArrayUnaccessData = dlsymFn(SafeArrayNoArgFn, h, "SafeArrayUnaccessData") orelse
                return error.SymbolNotFound,
        };
    }

    global = lib;
    return lib;
}

/// Drop a reference. The library intentionally stays loaded until process
/// exit even at refcount 0: the SDK spins up internal worker threads and
/// unloading it from a plugin is not safe.
pub fn release(lib: *Lib) void {
    global_mutex.lock();
    defer global_mutex.unlock();
    if (lib.refs > 0) lib.refs -= 1;
}

test "candidate paths: explicit file wins" {
    const gpa = std.testing.allocator;
    const paths = try candidatePaths(gpa, "/nonexistent/libFoo.so", null);
    defer freeCandidates(gpa, paths);
    try std.testing.expectEqual(@as(usize, 1), paths.len);
    try std.testing.expectEqualStrings("/nonexistent/libFoo.so", paths[0]);
}

test "candidate paths: per-os deps dir first, then pip libs, then fallbacks" {
    const gpa = std.testing.allocator;
    const paths = try candidatePaths(gpa, null, "/plug");
    defer freeCandidates(gpa, paths);
    try std.testing.expect(paths.len >= 4 + default_dirs.len);
    try std.testing.expect(std.mem.indexOf(u8, paths[0], deps_subdir) != null);
    try std.testing.expect(std.mem.startsWith(u8, paths[0], "/plug"));
    try std.testing.expect(std.mem.indexOf(u8, paths[1], "vapoursynth_brawsource.libs") != null);
    try std.testing.expect(std.mem.indexOf(u8, paths[2], "BlackmagicRawAPI") != null);
}
