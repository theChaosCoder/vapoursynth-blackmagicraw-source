//! Per-platform handling of the SDK's `string` type:
//!   Linux   const char* (UTF-8)      — out-params are borrowed, copy them
//!   macOS   CFStringRef              — out-params follow the CF create rule
//!   Windows BSTR (UTF-16)            — out-params are caller-freed
//!
//! `dupe` copies an SDK-returned string into caller-owned UTF-8 and applies
//! the platform release policy. `make`/`free` build strings we PASS to the
//! SDK (OpenClip file name, string-valued attributes).

const std = @import("std");
const api = @import("api.zig");

const is_windows = api.is_windows;
const is_macos = api.is_macos;

// --- macOS CoreFoundation, loaded lazily via dlopen -------------------------
// dlopen instead of framework linking keeps mac targets cross-compilable
// without a macOS SDK sysroot (CoreFoundation is always present at runtime).
const cf = if (is_macos) struct {
    const CFIndex = isize;
    const CFStringEncoding = u32;
    const utf8: CFStringEncoding = 0x08000100;

    const Fns = struct {
        getLength: *const fn (?*anyopaque) callconv(.c) CFIndex,
        maxSize: *const fn (CFIndex, CFStringEncoding) callconv(.c) CFIndex,
        getCString: *const fn (?*anyopaque, [*]u8, CFIndex, CFStringEncoding) callconv(.c) u8,
        createWithBytes: *const fn (?*anyopaque, [*]const u8, CFIndex, CFStringEncoding, u8) callconv(.c) ?*anyopaque,
        release: *const fn (?*anyopaque) callconv(.c) void,
    };

    var fns: ?Fns = null;
    var load_done: bool = false;
    var load_mutex: @import("../sync.zig").Mutex = .{};

    fn load() void {
        const path = "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation";
        const h = std.c.dlopen(path, .{ .NOW = true }) orelse return;
        const sym = struct {
            fn f(comptime T: type, handle: *anyopaque, name: [:0]const u8) ?T {
                const p = std.c.dlsym(handle, name.ptr) orelse return null;
                return @ptrCast(@alignCast(p));
            }
        }.f;
        fns = .{
            .getLength = sym(@FieldType(Fns, "getLength"), h, "CFStringGetLength") orelse return,
            .maxSize = sym(@FieldType(Fns, "maxSize"), h, "CFStringGetMaximumSizeForEncoding") orelse return,
            .getCString = sym(@FieldType(Fns, "getCString"), h, "CFStringGetCString") orelse return,
            .createWithBytes = sym(@FieldType(Fns, "createWithBytes"), h, "CFStringCreateWithBytes") orelse return,
            .release = sym(@FieldType(Fns, "release"), h, "CFRelease") orelse return,
        };
    }

    fn get() ?*const Fns {
        if (!@atomicLoad(bool, &load_done, .acquire)) {
            load_mutex.lock();
            defer load_mutex.unlock();
            if (!load_done) {
                load();
                @atomicStore(bool, &load_done, true, .release);
            }
        }
        return if (fns) |*f| f else null;
    }
} else struct {};

// --- Windows oleaut32 externs ---
const ole = if (is_windows) struct {
    extern "oleaut32" fn SysAllocStringLen(?[*]const u16, u32) callconv(.c) ?[*:0]u16;
    extern "oleaut32" fn SysFreeString(?[*:0]u16) callconv(.c) void;
    extern "oleaut32" fn SysStringLen(?[*:0]u16) callconv(.c) u32;
} else struct {};

/// Copy an SDK-returned string to caller-owned, NUL-terminated UTF-8.
/// `take`: whether we own the raw string and must release it (BSTR out-params
/// and CFStringRef out-params yes; borrowed `const char*` on Linux no;
/// callback arguments on any platform no).
pub fn dupe(gpa: std.mem.Allocator, raw: api.StringRaw, take: bool) ![:0]u8 {
    const r = raw orelse return try gpa.dupeZ(u8, "");
    if (is_windows) {
        defer if (take) ole.SysFreeString(r);
        const len = ole.SysStringLen(r);
        return try std.unicode.utf16LeToUtf8AllocZ(gpa, r[0..len]);
    } else if (is_macos) {
        const f = cf.get() orelse return error.StringConversionFailed;
        defer if (take) f.release(r);
        const cflen = f.getLength(r);
        const max = f.maxSize(cflen, cf.utf8) + 1;
        const buf = try gpa.alloc(u8, @intCast(max));
        defer gpa.free(buf);
        if (f.getCString(r, buf.ptr, max, cf.utf8) == 0) {
            return error.StringConversionFailed;
        }
        const n = std.mem.indexOfScalar(u8, buf, 0) orelse @as(usize, @intCast(max - 1));
        return try gpa.dupeZ(u8, buf[0..n]);
    } else {
        return try gpa.dupeZ(u8, std.mem.span(r));
    }
}

/// Platform string handle we own, for passing INTO the SDK.
pub const Owned = struct {
    raw: api.StringRaw,
    // Linux: the NUL-terminated buffer backing `raw`.
    buf: ?[:0]u8 = null,

    pub fn deinit(self: *Owned, gpa: std.mem.Allocator) void {
        if (is_windows) {
            ole.SysFreeString(self.raw);
        } else if (is_macos) {
            if (self.raw) |r| {
                if (cf.get()) |f| f.release(r);
            }
        } else if (self.buf) |b| {
            gpa.free(b);
        }
        self.* = .{ .raw = null };
    }
};

pub fn make(gpa: std.mem.Allocator, utf8: []const u8) !Owned {
    if (is_windows) {
        const w = try std.unicode.utf8ToUtf16LeAlloc(gpa, utf8);
        defer gpa.free(w);
        const b = ole.SysAllocStringLen(w.ptr, @intCast(w.len)) orelse return error.OutOfMemory;
        return .{ .raw = b };
    } else if (is_macos) {
        const f = cf.get() orelse return error.StringConversionFailed;
        const s = f.createWithBytes(null, utf8.ptr, @intCast(utf8.len), cf.utf8, 0) orelse
            return error.OutOfMemory;
        return .{ .raw = s };
    } else {
        const z = try gpa.dupeZ(u8, utf8);
        return .{ .raw = z.ptr, .buf = z };
    }
}

test "make/dupe roundtrip (native)" {
    const gpa = std.testing.allocator;
    var s = try make(gpa, "hello/päth.braw");
    defer s.deinit(gpa);
    // On Linux the raw pointer is our own buffer; dupe with take=false copies.
    const back = try dupe(gpa, s.raw, false);
    defer gpa.free(back);
    try std.testing.expectEqualStrings("hello/päth.braw", back);
}

test "dupe of null yields empty string" {
    const gpa = std.testing.allocator;
    const s = try dupe(gpa, null, false);
    defer gpa.free(s);
    try std.testing.expectEqualStrings("", s);
}
