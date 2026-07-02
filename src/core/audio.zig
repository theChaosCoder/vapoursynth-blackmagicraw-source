//! PCM unpacking helpers. The SDK delivers packed interleaved little-endian
//! PCM (24-bit = 3 bytes per sample). Host conventions differ:
//!   VapourSynth: planar per channel; 24-bit stored MSB-aligned in i32
//!                (value << 8), 16-bit as plain i16, 32-bit as plain i32.
//!   AviSynth:    interleaved packed — the SDK layout passes through as-is.

const std = @import("std");

/// 3-byte little-endian signed 24-bit -> VS MSB-aligned i32 (low byte 0).
pub inline fn sample24ToVs(bytes: *const [3]u8) i32 {
    return @bitCast((@as(u32, bytes[2]) << 24) | (@as(u32, bytes[1]) << 16) | (@as(u32, bytes[0]) << 8));
}

/// Extract one channel from packed interleaved PCM into a VS audio plane.
/// `bit_depth` in {16, 24, 32}; `out` must hold `nsamples` container values
/// (2 bytes for 16-bit, 4 bytes otherwise).
pub fn unpackChannelToVs(
    bit_depth: u32,
    channels: u32,
    pcm: []const u8,
    ch: u32,
    out: [*]u8,
    nsamples: usize,
) error{UnsupportedBitDepth}!void {
    const nch: usize = channels;
    const c: usize = ch;
    switch (bit_depth) {
        16 => {
            const dst: [*]align(1) i16 = @ptrCast(out);
            var s: usize = 0;
            while (s < nsamples) : (s += 1) {
                const off = (s * nch + c) * 2;
                dst[s] = std.mem.readInt(i16, pcm[off..][0..2], .little);
            }
        },
        24 => {
            const dst: [*]align(1) i32 = @ptrCast(out);
            var s: usize = 0;
            while (s < nsamples) : (s += 1) {
                const off = (s * nch + c) * 3;
                dst[s] = sample24ToVs(pcm[off..][0..3]);
            }
        },
        32 => {
            const dst: [*]align(1) i32 = @ptrCast(out);
            var s: usize = 0;
            while (s < nsamples) : (s += 1) {
                const off = (s * nch + c) * 4;
                dst[s] = std.mem.readInt(i32, pcm[off..][0..4], .little);
            }
        },
        else => return error.UnsupportedBitDepth,
    }
}

test "24-bit VS alignment matches the core convention" {
    // same values verified against BestSource: 1 -> 256, -1 -> -256,
    // 0x7FFFFF -> 0x7FFFFF00, -0x800000 -> minInt(i32)
    try std.testing.expectEqual(@as(i32, 256), sample24ToVs(&.{ 1, 0, 0 }));
    try std.testing.expectEqual(@as(i32, -256), sample24ToVs(&.{ 0xFF, 0xFF, 0xFF }));
    try std.testing.expectEqual(@as(i32, 0x7FFFFF00), sample24ToVs(&.{ 0xFF, 0xFF, 0x7F }));
    try std.testing.expectEqual(std.math.minInt(i32), sample24ToVs(&.{ 0, 0, 0x80 }));
}

test "unpack interleaved stereo 24-bit" {
    // L0 R0 L1 R1 with recognizable values
    const packed_pcm = [_]u8{
        0x01, 0x00, 0x00, // L0 = 1
        0xFF, 0xFF, 0xFF, // R0 = -1
        0x00, 0x00, 0x01, // L1 = 0x010000
        0x02, 0x00, 0x00, // R1 = 2
    };
    var left: [2]i32 = undefined;
    var right: [2]i32 = undefined;
    try unpackChannelToVs(24, 2, &packed_pcm, 0, @ptrCast(&left), 2);
    try unpackChannelToVs(24, 2, &packed_pcm, 1, @ptrCast(&right), 2);
    try std.testing.expectEqual(@as(i32, 256), left[0]);
    try std.testing.expectEqual(@as(i32, 0x01000000), left[1]);
    try std.testing.expectEqual(@as(i32, -256), right[0]);
    try std.testing.expectEqual(@as(i32, 512), right[1]);
}

test "unpack 16-bit" {
    const packed_pcm = [_]u8{ 0x34, 0x12, 0xCC, 0xED };
    var l: [1]i16 = undefined;
    var r: [1]i16 = undefined;
    try unpackChannelToVs(16, 2, &packed_pcm, 0, @ptrCast(&l), 1);
    try unpackChannelToVs(16, 2, &packed_pcm, 1, @ptrCast(&r), 1);
    try std.testing.expectEqual(@as(i16, 0x1234), l[0]);
    try std.testing.expectEqual(@as(i16, -0x1234), r[0]);
}
