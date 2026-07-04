//! Output format selection and pixel copying from SDK buffers into host
//! frame planes.
//!
//! The SDK decodes into tightly packed buffers (verified at runtime against
//! GetResourceSizeBytes). The 16/32-bit depths use the *planar* RGB variants
//! and do straight row copies; u8 has no planar variant, so it decodes as
//! interleaved RGBA and is de-interleaved into R, G, B. Plane order is R, G, B.

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
    NoFloat8,
    BadBitdepth,
    FpRequiresBitdepth,
};

/// Resolve the user-facing depth selection (shared by both adapters):
/// `bitdepth` 8/16/32 with optional `fp` (16+fp = half float).
/// Returns null for automatic selection.
pub fn resolveDepth(bitdepth: ?i64, fp: ?bool) DepthSelectError!?Depth {
    if (bitdepth) |b| {
        const want_fp = fp orelse false;
        return switch (b) {
            8 => if (want_fp) error.NoFloat8 else .u8_,
            16 => if (want_fp) .f16 else .u16_,
            32 => .f32_,
            else => error.BadBitdepth,
        };
    }
    if (fp != null) return error.FpRequiresBitdepth;
    return null;
}

/// Pick the SDK resource format for a depth. BRAW has no alpha channel, so
/// the output is always RGB. u8 has no planar variant, so it decodes as
/// interleaved RGBA (the padding channel is dropped during the plane copy).
/// The CPU pipeline rejects the f16 formats (E_INVALIDARG, GPU-only), so
/// f16 output decodes there as f32 and is narrowed during the plane copy;
/// GPU pipelines decode f16 natively (half the readback, no conversion).
pub fn resourceFormat(depth: Depth, gpu_pipeline: bool) api.ResourceFormat {
    return switch (depth) {
        .u8_ => .rgba_u8,
        .u16_ => .rgb_u16_planar,
        .f16 => if (gpu_pipeline) .rgb_f16_planar else .rgb_f32_planar,
        .f32_ => .rgb_f32_planar,
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

/// Destination description: R, G, B planes. The 4th slot exists only because
/// the u8 path decodes as interleaved RGBA; it is always null, so the padding
/// channel is skipped during de-interleave. Strides in bytes.
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
        .rgba_u8 => deinterleaveU8(src, dst),
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
        if (Src == Dst and stride == w * @sizeOf(Src)) {
            // destination rows are tightly packed: one copy per plane
            const plane_bytes = w * @sizeOf(Src) * h;
            @memcpy(dp[0..plane_bytes], @as([*]const u8, @ptrCast(base))[0..plane_bytes]);
            continue;
        }
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

/// SIMD de-interleave of the SDK's packed RGBA8 buffer into planar R,G,B(,A).
/// The SDK has no planar u8 format, so 8-bit output always arrives interleaved
/// and must be split by hand. Two wins over the generic scalar path: each
/// 16-pixel chunk is loaded ONCE and scattered to every present plane (the old
/// loop re-read the row once per plane), and the per-channel gather is a single
/// `@shuffle` (pshufb-class) instead of a stride-4 scalar loop. A scalar tail
/// handles the last <16 pixels. Channel c maps to plane c (R,G,B,A), matching
/// the scalar path exactly.
fn deinterleaveU8(src_raw: [*]const u8, dst: *const Dest) void {
    const w: usize = dst.width;
    const h: usize = dst.height;
    // gather indices for channel 0 across 16 pixels; +c picks the other channels
    const base: @Vector(16, i32) = .{ 0, 4, 8, 12, 16, 20, 24, 28, 32, 36, 40, 44, 48, 52, 56, 60 };
    const simd_w = w - (w % 16);
    var y: usize = 0;
    while (y < h) : (y += 1) {
        const row = src_raw + y * w * 4;
        var x: usize = 0;
        while (x < simd_w) : (x += 16) {
            const chunk: @Vector(64, u8) = @as(*align(1) const @Vector(64, u8), @ptrCast(row + x * 4)).*;
            inline for (0..4) |c| {
                if (dst.planes[c]) |dp| {
                    const mask = comptime base + @as(@Vector(16, i32), @splat(@as(i32, c)));
                    const picked = @shuffle(u8, chunk, @as(@Vector(64, u8), undefined), mask);
                    const outp = dp + y * dst.strides[c] + x;
                    @as(*align(1) @Vector(16, u8), @ptrCast(outp)).* = picked;
                }
            }
        }
        while (x < w) : (x += 1) {
            inline for (0..4) |c| {
                if (dst.planes[c]) |dp| (dp + y * dst.strides[c])[x] = row[x * 4 + c];
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

test "resolveDepth: mappings and errors" {
    try std.testing.expectEqual(@as(?Depth, null), try resolveDepth(null, null));
    try std.testing.expectEqual(@as(?Depth, .u8_), try resolveDepth(8, null));
    try std.testing.expectEqual(@as(?Depth, .u16_), try resolveDepth(16, null));
    try std.testing.expectEqual(@as(?Depth, .f16), try resolveDepth(16, true));
    try std.testing.expectEqual(@as(?Depth, .f32_), try resolveDepth(32, null));
    try std.testing.expectEqual(@as(?Depth, .f32_), try resolveDepth(32, true));
    try std.testing.expectError(error.NoFloat8, resolveDepth(8, true));
    try std.testing.expectError(error.BadBitdepth, resolveDepth(12, null));
    try std.testing.expectError(error.FpRequiresBitdepth, resolveDepth(null, true));
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

test "deinterleaveU8 SIMD path matches scalar reference (width > 16 + remainder)" {
    const gpa = std.testing.allocator;
    const w: u32 = 37; // 32 pixels via SIMD (2x16), 5 via the scalar tail
    const h: u32 = 3;
    const src = try gpa.alloc(u8, w * h * 4);
    defer gpa.free(src);
    for (0..src.len) |i| src[i] = @truncate(i *% 7 +% 1); // deterministic RGBA pattern
    const stride: usize = w + 8; // padded, like a real frame
    var bufs: [4][]u8 = undefined;
    for (0..4) |i| bufs[i] = try gpa.alloc(u8, stride * h);
    defer for (0..4) |i| gpa.free(bufs[i]);
    for (0..4) |i| @memset(bufs[i], 0xCC);

    var d = testDest(u8, w, h, &bufs, false); // R,G,B planes, alpha null (production case)
    try copyImage(.rgba_u8, src.ptr, src.len, &d, .u8_);

    for (0..h) |y| {
        for (0..w) |x| {
            inline for (0..3) |c| {
                try std.testing.expectEqual(src[(y * w + x) * 4 + c], bufs[c][y * d.strides[c] + x]);
            }
        }
        for (w..stride) |x| try std.testing.expectEqual(@as(u8, 0xCC), bufs[0][y * d.strides[0] + x]); // padding untouched
    }
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
