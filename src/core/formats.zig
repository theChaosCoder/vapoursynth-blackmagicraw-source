//! Output format selection and pixel copying from SDK buffers into host
//! frame planes.
//!
//! The SDK decodes into tightly packed buffers (verified at runtime against
//! GetResourceSizeBytes). Without alpha we request the *planar* RGB variants
//! and do straight row copies; with alpha only interleaved RGBA exists, so
//! rows are de-interleaved. Plane order for planar formats is R, G, B.

const std = @import("std");
const api = @import("braw/api.zig");

pub const Depth = enum {
    u8_,
    u16_,
    f16,
    f32_,

    pub fn bytesPerSample(self: Depth) u32 {
        return switch (self) {
            .u8_ => 1,
            .u16_ => 2,
            .f16 => 2,
            .f32_ => 4,
        };
    }

    pub fn parse(s: []const u8) ?Depth {
        if (std.ascii.eqlIgnoreCase(s, "u8")) return .u8_;
        if (std.ascii.eqlIgnoreCase(s, "u16")) return .u16_;
        if (std.ascii.eqlIgnoreCase(s, "f16")) return .f16;
        if (std.ascii.eqlIgnoreCase(s, "f32")) return .f32_;
        return null;
    }
};

pub const DepthSelectError = error{
    BadFormatString,
    NoFloat8,
    BadBitdepth,
    FpRequiresBitdepth,
};

/// Resolve the user-facing depth selection (shared by both adapters):
/// `bitdepth` 8/16/32 with optional `fp` is the primary API, `format`
/// ("auto"/"u8"/"u16"/"f16"/"f32") the legacy alias; bitdepth wins.
/// Returns null for automatic selection.
pub fn resolveDepth(format_str: ?[]const u8, bitdepth: ?i64, fp: ?bool) DepthSelectError!?Depth {
    var depth: ?Depth = null;
    if (format_str) |s| {
        if (!std.ascii.eqlIgnoreCase(s, "auto")) {
            depth = Depth.parse(s) orelse return error.BadFormatString;
        }
    }
    if (bitdepth) |b| {
        const want_fp = fp orelse false;
        depth = switch (b) {
            8 => if (want_fp) return error.NoFloat8 else .u8_,
            16 => if (want_fp) .f16 else .u16_,
            32 => .f32_,
            else => return error.BadBitdepth,
        };
    } else if (fp != null) {
        return error.FpRequiresBitdepth;
    }
    return depth;
}

/// Pick the SDK resource format for a depth/alpha combination.
/// u8 has no planar variant, so it is always interleaved RGBA.
/// The CPU pipeline rejects the f16 formats (E_INVALIDARG, GPU-only), so
/// f16 output decodes as f32 and is converted during the plane copy.
pub fn resourceFormat(depth: Depth, alpha: bool) api.ResourceFormat {
    return switch (depth) {
        .u8_ => .rgba_u8,
        .u16_ => if (alpha) .rgba_u16 else .rgb_u16_planar,
        .f16 => if (alpha) .rgba_f32 else .rgb_f32_planar,
        .f32_ => if (alpha) .rgba_f32 else .rgb_f32_planar,
    };
}

pub fn isInterleaved(fmt: api.ResourceFormat) bool {
    return switch (fmt) {
        .rgb_u16_planar, .rgb_f16_planar, .rgb_f32_planar => false,
        else => true,
    };
}

pub fn channelCount(fmt: api.ResourceFormat) u32 {
    return switch (fmt) {
        .rgb_u16, .rgb_f32, .rgb_f16, .rgb_u16_planar, .rgb_f32_planar, .rgb_f16_planar => 3,
        else => 4,
    };
}

pub fn sampleBytes(fmt: api.ResourceFormat) u32 {
    return switch (fmt) {
        .rgba_u8, .bgra_u8 => 1,
        .rgb_u16, .rgba_u16, .bgra_u16, .rgb_u16_planar => 2,
        .rgb_f16, .rgba_f16, .bgra_f16, .rgb_f16_planar => 2,
        else => 4,
    };
}

pub fn expectedSizeBytes(fmt: api.ResourceFormat, w: u32, h: u32) u64 {
    return @as(u64, w) * h * channelCount(fmt) * sampleBytes(fmt);
}

/// Destination description: up to 4 planes (R, G, B, A). A null alpha plane
/// with an alpha-carrying source skips the alpha channel. Strides in bytes.
pub const Dest = struct {
    width: u32,
    height: u32,
    planes: [4]?[*]u8,
    strides: [4]usize,
};

pub const CopyError = error{ UnsupportedFormat, SizeMismatch };

/// Copy/convert a packed SDK buffer into destination planes.
/// `dst_depth` may differ from the resource depth only for f32 -> f16.
pub fn copyImage(fmt: api.ResourceFormat, src: [*]const u8, src_size: u64, dst: *const Dest, dst_depth: Depth) CopyError!void {
    if (src_size < expectedSizeBytes(fmt, dst.width, dst.height)) return error.SizeMismatch;
    const narrow_f16 = dst_depth == .f16;
    switch (fmt) {
        .rgb_u16_planar => copyPlanar(u16, u16, src, dst),
        .rgb_f16_planar => copyPlanar(u16, u16, src, dst), // f16 bits, no interpretation needed
        .rgb_f32_planar => if (narrow_f16) copyPlanar(f32, f16, src, dst) else copyPlanar(u32, u32, src, dst),
        .rgba_u8 => deinterleave(u8, u8, src, dst),
        .rgba_u16 => deinterleave(u16, u16, src, dst),
        .rgba_f16 => deinterleave(u16, u16, src, dst),
        .rgba_f32 => if (narrow_f16) deinterleave(f32, f16, src, dst) else deinterleave(u32, u32, src, dst),
        else => return error.UnsupportedFormat,
    }
}

inline fn convert(comptime Src: type, comptime Dst: type, v: Src) Dst {
    return if (Src == Dst) v else @floatCast(v);
}

fn copyPlanar(comptime Src: type, comptime Dst: type, src_raw: [*]const u8, dst: *const Dest) void {
    const w: usize = dst.width;
    const h: usize = dst.height;
    const src: [*]align(1) const Src = @ptrCast(src_raw);
    var plane: usize = 0;
    while (plane < 3) : (plane += 1) {
        const dp = dst.planes[plane] orelse continue;
        const stride = dst.strides[plane];
        const base = src + plane * w * h;
        var y: usize = 0;
        while (y < h) : (y += 1) {
            const row = base + y * w;
            if (Src == Dst) {
                const row_bytes = w * @sizeOf(Src);
                @memcpy(dp[y * stride ..][0..row_bytes], @as([*]const u8, @ptrCast(row))[0..row_bytes]);
            } else {
                const out: [*]align(1) Dst = @ptrCast(dp + y * stride);
                var x: usize = 0;
                while (x < w) : (x += 1) {
                    out[x] = convert(Src, Dst, row[x]);
                }
            }
        }
    }
}

fn deinterleave(comptime Src: type, comptime Dst: type, src_raw: [*]const u8, dst: *const Dest) void {
    const w: usize = dst.width;
    const h: usize = dst.height;
    const src: [*]align(1) const Src = @ptrCast(src_raw);
    const nch: usize = 4;

    var y: usize = 0;
    while (y < h) : (y += 1) {
        const row = src + y * w * nch;
        var c: usize = 0;
        while (c < 4) : (c += 1) {
            const dp = dst.planes[c] orelse continue;
            const out: [*]align(1) Dst = @ptrCast(dp + y * dst.strides[c]);
            var x: usize = 0;
            while (x < w) : (x += 1) {
                out[x] = convert(Src, Dst, row[x * nch + c]);
            }
        }
    }
}

// ---------------------------------------------------------------------------

fn testDest(comptime T: type, w: u32, h: u32, bufs: *[4][]T, want_alpha: bool) Dest {
    var d: Dest = .{
        .width = w,
        .height = h,
        .planes = .{ null, null, null, null },
        .strides = .{ 0, 0, 0, 0 },
    };
    const n: usize = if (want_alpha) 4 else 3;
    for (0..n) |i| {
        d.planes[i] = @ptrCast(bufs[i].ptr);
        d.strides[i] = w * @sizeOf(T) + 8; // deliberately padded stride
    }
    return d;
}

test "resolveDepth: bitdepth wins, errors on bad input" {
    try std.testing.expectEqual(@as(?Depth, null), try resolveDepth(null, null, null));
    try std.testing.expectEqual(@as(?Depth, null), try resolveDepth("auto", null, null));
    try std.testing.expectEqual(@as(?Depth, .f32_), try resolveDepth(null, 32, null));
    try std.testing.expectEqual(@as(?Depth, .f16), try resolveDepth(null, 16, true));
    try std.testing.expectEqual(@as(?Depth, .u8_), try resolveDepth(null, 8, false));
    try std.testing.expectEqual(@as(?Depth, .u16_), try resolveDepth("f32", 16, null)); // bitdepth wins
    try std.testing.expectEqual(@as(?Depth, .f32_), try resolveDepth("f32", null, null));
    try std.testing.expectError(error.NoFloat8, resolveDepth(null, 8, true));
    try std.testing.expectError(error.BadBitdepth, resolveDepth(null, 12, null));
    try std.testing.expectError(error.FpRequiresBitdepth, resolveDepth(null, null, true));
    try std.testing.expectError(error.BadFormatString, resolveDepth("yuv", null, null));
}

test "planar u16 copy respects stride" {
    const gpa = std.testing.allocator;
    const w = 2;
    const h = 2;
    // src: 3 planes of 2x2 u16, values R=1..4, G=5..8, B=9..12
    var src: [12]u16 = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 };
    var bufs: [4][]u16 = undefined;
    for (0..3) |i| bufs[i] = try gpa.alloc(u16, (w * @sizeOf(u16) + 8) / 2 * h);
    defer for (0..3) |i| gpa.free(bufs[i]);
    for (0..3) |i| @memset(bufs[i], 0xAAAA);

    const d = testDest(u16, w, h, &bufs, false);
    try copyImage(.rgb_u16_planar, @ptrCast(&src), src.len * 2, &d, .u16_);

    // plane R row0: 1,2 ; row1 starts after stride (w*2+8 bytes = 6 u16)
    try std.testing.expectEqual(@as(u16, 1), bufs[0][0]);
    try std.testing.expectEqual(@as(u16, 2), bufs[0][1]);
    try std.testing.expectEqual(@as(u16, 0xAAAA), bufs[0][2]); // padding untouched
    try std.testing.expectEqual(@as(u16, 3), bufs[0][6]);
    try std.testing.expectEqual(@as(u16, 4), bufs[0][7]);
    try std.testing.expectEqual(@as(u16, 5), bufs[1][0]); // G plane
    try std.testing.expectEqual(@as(u16, 12), bufs[2][7]); // B plane last
}

test "deinterleave rgba u8 with and without alpha" {
    const gpa = std.testing.allocator;
    const w = 2;
    const h = 1;
    // RGBA RGBA: (1,2,3,4) (5,6,7,8)
    var src: [8]u8 = .{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var bufs: [4][]u8 = undefined;
    for (0..4) |i| bufs[i] = try gpa.alloc(u8, (w + 8) * h);
    defer for (0..4) |i| gpa.free(bufs[i]);
    for (0..4) |i| @memset(bufs[i], 0xCC);

    var d = testDest(u8, w, h, &bufs, true);
    try copyImage(.rgba_u8, @ptrCast(&src), src.len, &d, .u8_);
    try std.testing.expectEqual(@as(u8, 1), bufs[0][0]);
    try std.testing.expectEqual(@as(u8, 5), bufs[0][1]);
    try std.testing.expectEqual(@as(u8, 2), bufs[1][0]);
    try std.testing.expectEqual(@as(u8, 4), bufs[3][0]); // alpha
    try std.testing.expectEqual(@as(u8, 8), bufs[3][1]);

    // without alpha plane: must not crash, alpha skipped
    d.planes[3] = null;
    try copyImage(.rgba_u8, @ptrCast(&src), src.len, &d, .u8_);
}

test "size mismatch rejected" {
    var buf: [4]u8 = .{ 0, 0, 0, 0 };
    var bufs: [4][]u8 = undefined;
    _ = &bufs;
    const d: Dest = .{ .width = 4, .height = 4, .planes = .{ @ptrCast(&buf), null, null, null }, .strides = .{ 4, 0, 0, 0 } };
    try std.testing.expectError(error.SizeMismatch, copyImage(.rgba_u8, @ptrCast(&buf), 4, &d, .u8_));
}

test "f32 planar narrows to f16 destination" {
    const gpa = std.testing.allocator;
    var src: [3]f32 = .{ 0.25, 0.5, 1.0 };
    var bufs: [4][]u16 = undefined;
    for (0..3) |i| bufs[i] = try gpa.alloc(u16, 8);
    defer for (0..3) |i| gpa.free(bufs[i]);

    const d = testDest(u16, 1, 1, &bufs, false);
    try copyImage(.rgb_f32_planar, @ptrCast(&src), 12, &d, .f16);
    const r: f16 = @bitCast(bufs[0][0]);
    const b: f16 = @bitCast(bufs[2][0]);
    try std.testing.expectEqual(@as(f16, 0.25), r);
    try std.testing.expectEqual(@as(f16, 1.0), b);
}

test "f32 planar copy" {
    const gpa = std.testing.allocator;
    const w = 1;
    const h = 1;
    var src: [3]f32 = .{ 0.25, 0.5, 1.0 };
    var bufs: [4][]u32 = undefined;
    for (0..3) |i| bufs[i] = try gpa.alloc(u32, 4);
    defer for (0..3) |i| gpa.free(bufs[i]);

    const d = testDest(u32, w, h, &bufs, false);
    try copyImage(.rgb_f32_planar, @ptrCast(&src), 12, &d, .f32_);
    try std.testing.expectEqual(@as(f32, 0.25), @as(f32, @bitCast(bufs[0][0])));
    try std.testing.expectEqual(@as(f32, 1.0), @as(f32, @bitCast(bufs[2][0])));
}
