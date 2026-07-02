//! Normalizes SDK Variants/SafeArrays (whose layout and type codes differ
//! per platform, see api.zig) into caller-owned Zig values.

const std = @import("std");
const api = @import("api.zig");
const strings = @import("strings.zig");
const loader = @import("loader.zig");

const is_windows = api.is_windows;

const ole = if (is_windows) struct {
    extern "oleaut32" fn VariantInit(*api.Variant) callconv(.c) api.HRESULT;
    extern "oleaut32" fn VariantClear(*api.Variant) callconv(.c) api.HRESULT;
    extern "oleaut32" fn SafeArrayAccessData(*api.SafeArray, *?*anyopaque) callconv(.c) api.HRESULT;
    extern "oleaut32" fn SafeArrayUnaccessData(*api.SafeArray) callconv(.c) api.HRESULT;
    extern "oleaut32" fn SafeArrayGetVartype(*api.SafeArray, *u16) callconv(.c) api.HRESULT;
} else struct {};

pub fn variantInit(lib: *loader.Lib, v: *api.Variant) void {
    if (is_windows) {
        _ = ole.VariantInit(v);
    } else {
        _ = lib.variantInit(v);
    }
}

/// Frees whatever the SDK allocated into the Variant (strings, arrays).
pub fn variantClear(lib: *loader.Lib, v: *api.Variant) void {
    if (is_windows) {
        _ = ole.VariantClear(v);
    } else {
        _ = lib.variantClear(v);
    }
}

pub const MetaValue = union(enum) {
    empty,
    int: i64,
    float: f64,
    string: [:0]u8, // owned UTF-8, NUL-terminated for host C APIs
    int_array: []i64, // owned
    float_array: []f64, // owned

    pub fn deinit(self: *MetaValue, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .string => |s| gpa.free(s),
            .int_array => |a| gpa.free(a),
            .float_array => |a| gpa.free(a),
            else => {},
        }
        self.* = .empty;
    }

    pub fn format(self: MetaValue, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .empty => try writer.writeAll("<empty>"),
            .int => |i| try writer.print("{d}", .{i}),
            .float => |f| try writer.print("{d}", .{f}),
            .string => |s| try writer.writeAll(s),
            .int_array => |a| for (a, 0..) |x, i| {
                if (i != 0) try writer.writeAll(" ");
                try writer.print("{d}", .{x});
            },
            .float_array => |a| for (a, 0..) |x, i| {
                if (i != 0) try writer.writeAll(" ");
                try writer.print("{d}", .{x});
            },
        }
    }
};

const ElemKind = enum { i, f, skip };

/// Map platform variant-type codes onto the unix enumeration so every
/// downstream switch exists exactly once.
fn normVt(vt_raw: u32) u32 {
    if (!is_windows) return vt_raw;
    return switch (@as(u16, @intCast(vt_raw & 0xFFFF))) {
        api.vt_win.empty => api.vt_unix.empty,
        api.vt_win.u8_ => api.vt_unix.u8_,
        api.vt_win.s16 => api.vt_unix.s16,
        api.vt_win.u16_ => api.vt_unix.u16_,
        api.vt_win.s32 => api.vt_unix.s32,
        api.vt_win.u32_ => api.vt_unix.u32_,
        api.vt_win.f32_ => api.vt_unix.f32_,
        api.vt_win.f64_ => api.vt_unix.f64_,
        api.vt_win.string => api.vt_unix.string,
        api.vt_win.safe_array => api.vt_unix.safe_array,
        else => 0xFFFF_FFFF,
    };
}

/// The following take NORMALIZED (unix) type codes.
fn elemInfo(vt: u32) struct { kind: ElemKind, size: usize } {
    return switch (vt) {
        api.vt_unix.u8_ => .{ .kind = .i, .size = 1 },
        api.vt_unix.s16 => .{ .kind = .i, .size = 2 },
        api.vt_unix.u16_ => .{ .kind = .i, .size = 2 },
        api.vt_unix.s32 => .{ .kind = .i, .size = 4 },
        api.vt_unix.u32_ => .{ .kind = .i, .size = 4 },
        api.vt_unix.f32_ => .{ .kind = .f, .size = 4 },
        api.vt_unix.f64_ => .{ .kind = .f, .size = 8 },
        else => .{ .kind = .skip, .size = 0 },
    };
}

fn elemToI64(vt: u32, p: [*]const u8) i64 {
    return switch (vt) {
        api.vt_unix.u8_ => p[0],
        api.vt_unix.s16 => std.mem.readInt(i16, p[0..2], .little),
        api.vt_unix.u16_ => std.mem.readInt(u16, p[0..2], .little),
        api.vt_unix.s32 => std.mem.readInt(i32, p[0..4], .little),
        api.vt_unix.u32_ => std.mem.readInt(u32, p[0..4], .little),
        else => 0,
    };
}

fn elemToF64(vt: u32, p: [*]const u8) f64 {
    if (vt == api.vt_unix.f32_) return @as(f32, @bitCast(std.mem.readInt(u32, p[0..4], .little)));
    return @bitCast(std.mem.readInt(u64, p[0..8], .little));
}

fn safeArrayToMeta(gpa: std.mem.Allocator, lib: *loader.Lib, sa: *api.SafeArray) !MetaValue {
    var elem_vt: u32 = undefined;
    var count: usize = undefined;
    var data: ?*anyopaque = null;

    if (is_windows) {
        var vt16: u16 = 0;
        if (ole.SafeArrayGetVartype(sa, &vt16) != api.S_OK) return .empty;
        elem_vt = normVt(vt16);
        count = sa.rgsabound[0].cElements;
        if (ole.SafeArrayAccessData(sa, &data) != api.S_OK) return .empty;
    } else {
        elem_vt = sa.variantType;
        count = sa.bounds.cElements;
        if (lib.safeArrayAccessData(sa, &data) != api.S_OK) return .empty;
    }
    defer if (is_windows) {
        _ = ole.SafeArrayUnaccessData(sa);
    } else {
        _ = lib.safeArrayUnaccessData(sa);
    };

    const info = elemInfo(elem_vt);
    if (info.kind == .skip or count == 0 or data == null) return .empty;
    const bytes: [*]const u8 = @ptrCast(data.?);

    switch (info.kind) {
        .i => {
            const out = try gpa.alloc(i64, count);
            for (out, 0..) |*o, idx| o.* = elemToI64(elem_vt, bytes + idx * info.size);
            return .{ .int_array = out };
        },
        .f => {
            const out = try gpa.alloc(f64, count);
            for (out, 0..) |*o, idx| o.* = elemToF64(elem_vt, bytes + idx * info.size);
            return .{ .float_array = out };
        },
        .skip => unreachable,
    }
}

/// Convert a Variant into an owned MetaValue. Does NOT clear the variant;
/// callers pair this with variantInit/variantClear.
pub fn toMeta(gpa: std.mem.Allocator, lib: *loader.Lib, v: *api.Variant) !MetaValue {
    // Windows-only: arrays may arrive as VT_ARRAY|<elem> instead of
    // VT_SAFEARRAY; fold that onto the common safe-array path.
    if (is_windows and (@as(u16, @intCast(v.vt)) & api.vt_win.vt_array_flag) != 0) {
        const sa = v.u.parray orelse return .empty;
        return try safeArrayToMeta(gpa, lib, sa);
    }
    return switch (normVt(v.vt)) {
        api.vt_unix.empty => .empty,
        api.vt_unix.u8_ => .{ .int = @as(u8, @truncate(v.u.uiVal)) },
        api.vt_unix.s16 => .{ .int = v.u.iVal },
        api.vt_unix.u16_ => .{ .int = v.u.uiVal },
        api.vt_unix.s32 => .{ .int = v.u.intVal },
        api.vt_unix.u32_ => .{ .int = v.u.uintVal },
        api.vt_unix.f32_ => .{ .float = v.u.fltVal },
        api.vt_unix.f64_ => .{ .float = v.u.dblVal },
        api.vt_unix.string => .{ .string = try strings.dupe(gpa, v.u.bstrVal, false) },
        api.vt_unix.safe_array => blk: {
            const sa = v.u.parray orelse break :blk .empty;
            break :blk try safeArrayToMeta(gpa, lib, sa);
        },
        else => .empty,
    };
}

test "meta value formatting" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const v: MetaValue = .{ .float = 1.5 };
    try v.format(&w);
    try std.testing.expectEqualStrings("1.5", w.buffered());
}
