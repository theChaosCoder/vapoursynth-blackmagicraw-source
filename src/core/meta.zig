//! Metadata handling: exact frame-rate derivation and mapping of SDK
//! metadata keys to host frame-property names.

const std = @import("std");
const variant = @import("braw/variant.zig");

pub const Rational = struct {
    num: i64,
    den: i64,
};

fn gcd(a_: i64, b_: i64) i64 {
    var a = if (a_ < 0) -a_ else a_;
    var b = if (b_ < 0) -b_ else b_;
    while (b != 0) {
        const t = @mod(a, b);
        a = b;
        b = t;
    }
    return if (a == 0) 1 else a;
}

fn reduced(num: i64, den: i64) Rational {
    const g = gcd(num, den);
    return .{ .num = @divTrunc(num, g), .den = @divTrunc(den, g) };
}

const snap_table = [_]Rational{
    .{ .num = 24000, .den = 1001 },
    .{ .num = 24, .den = 1 },
    .{ .num = 25, .den = 1 },
    .{ .num = 30000, .den = 1001 },
    .{ .num = 30, .den = 1 },
    .{ .num = 48000, .den = 1001 },
    .{ .num = 48, .den = 1 },
    .{ .num = 50, .den = 1 },
    .{ .num = 60000, .den = 1001 },
    .{ .num = 60, .den = 1 },
    .{ .num = 100, .den = 1 },
    .{ .num = 120000, .den = 1001 },
    .{ .num = 120, .den = 1 },
};

/// Tight tolerance: 24.0 vs 24000/1001 differ by only 1e-3 relative, and
/// they MUST resolve differently. Float rates reported by the SDK are far
/// closer than 1e-4 to their true value.
const snap_tolerance = 1e-4;

fn snap(rate: f64) ?Rational {
    for (snap_table) |r| {
        const v = @as(f64, @floatFromInt(r.num)) / @as(f64, @floatFromInt(r.den));
        if (@abs(v - rate) / v < snap_tolerance) return r;
    }
    return null;
}

/// Derive an exact rational frame rate from the float clip rate and, when
/// available and consistent, the `sensor_rate` metadata rational.
pub fn rationalizeFps(clip_rate: f32, sensor: ?[2]f64) Rational {
    const rate: f64 = clip_rate;
    if (sensor) |s| {
        const num = s[0];
        const den = s[1];
        if (den > 0 and num > 0) {
            const v = num / den;
            // use the metadata rational only when it matches the clip rate
            // (off-speed recordings have sensor rate != playback rate)
            if (rate <= 0 or @abs(v - rate) / v < snap_tolerance) {
                // integer rational straight from metadata
                if (num == @trunc(num) and den == @trunc(den)) {
                    return reduced(@intFromFloat(num), @intFromFloat(den));
                }
                if (snap(v)) |r| return r;
            }
        }
    }
    if (rate <= 0) return .{ .num = 24, .den = 1 };
    if (snap(rate)) |r| return r;
    return reduced(@intFromFloat(@round(rate * 1000.0)), 1000);
}

/// Curated SDK metadata key -> host frame property name.
/// Everything else is exposed only via `allmetaprops` with a BRAW_ prefix.
const KeyMap = struct { key: []const u8, prop: []const u8 };

pub const frame_key_map = [_]KeyMap{
    .{ .key = "iso", .prop = "BRAWISO" },
    .{ .key = "white_balance_kelvin", .prop = "BRAWWhiteBalanceKelvin" },
    .{ .key = "white_balance_tint", .prop = "BRAWWhiteBalanceTint" },
    .{ .key = "as_shot_kelvin", .prop = "BRAWAsShotKelvin" },
    .{ .key = "as_shot_tint", .prop = "BRAWAsShotTint" },
    .{ .key = "exposure", .prop = "BRAWExposure" },
    .{ .key = "aperture", .prop = "BRAWAperture" },
    .{ .key = "focal_length", .prop = "BRAWFocalLength" },
    .{ .key = "shutter_value", .prop = "BRAWShutterValue" },
    .{ .key = "distance", .prop = "BRAWDistance" },
    .{ .key = "internal_nd", .prop = "BRAWInternalND" },
    .{ .key = "analog_gain", .prop = "BRAWAnalogGain" },
};

pub const clip_key_map = [_]KeyMap{
    .{ .key = "camera_type", .prop = "BRAWCameraType" },
    .{ .key = "camera_id", .prop = "BRAWCameraId" },
    .{ .key = "camera_number", .prop = "BRAWCameraNumber" },
    .{ .key = "firmware_version", .prop = "BRAWFirmwareVersion" },
    .{ .key = "braw_compression_ratio", .prop = "BRAWCompressionRatio" },
    .{ .key = "clip_number", .prop = "BRAWClipNumber" },
    .{ .key = "reel_name", .prop = "BRAWReelName" },
    .{ .key = "scene", .prop = "BRAWScene" },
    .{ .key = "take", .prop = "BRAWTake" },
    .{ .key = "good_take", .prop = "BRAWGoodTake" },
    .{ .key = "lens_type", .prop = "BRAWLensType" },
    .{ .key = "viewing_gamma", .prop = "BRAWGamma" },
    .{ .key = "viewing_gamut", .prop = "BRAWGamut" },
    .{ .key = "viewing_bmdgen", .prop = "BRAWColorScienceGen" },
    .{ .key = "date_recorded", .prop = "BRAWDateRecorded" },
};

pub fn framePropName(key: []const u8) ?[]const u8 {
    for (frame_key_map) |m| {
        if (std.mem.eql(u8, m.key, key)) return m.prop;
    }
    return null;
}

pub fn clipPropName(key: []const u8) ?[]const u8 {
    for (clip_key_map) |m| {
        if (std.mem.eql(u8, m.key, key)) return m.prop;
    }
    return null;
}

/// CICP transfer characteristics for SDK gamma names that have a standard
/// code; Blackmagic's own gammas have none and stay untagged.
pub fn cicpTransferFromGamma(gamma: []const u8) ?i64 {
    const map = [_]struct { name: []const u8, code: i64 }{
        .{ .name = "Rec.709", .code = 1 },
        .{ .name = "sRGB", .code = 13 },
        .{ .name = "Linear", .code = 8 },
        .{ .name = "Rec.2100 ST2084 (PQ)", .code = 16 },
        .{ .name = "Rec.2100 Hybrid Log Gamma", .code = 18 },
    };
    for (map) |m| {
        if (std.mem.eql(u8, m.name, gamma)) return m.code;
    }
    return null;
}

/// CICP color primaries for SDK gamut names that have a standard code.
pub fn cicpPrimariesFromGamut(gamut: []const u8) ?i64 {
    const map = [_]struct { name: []const u8, code: i64 }{
        .{ .name = "Rec.709", .code = 1 },
        .{ .name = "Rec.2020", .code = 9 },
        .{ .name = "DCI-P3 D65", .code = 12 },
        .{ .name = "DCI-P3 Theater", .code = 11 },
        .{ .name = "CIE 1931 XYZ D65", .code = 10 },
    };
    for (map) |m| {
        if (std.mem.eql(u8, m.name, gamut)) return m.code;
    }
    return null;
}

/// A named metadata value with a curated or raw property name.
/// Names are NUL-terminated for direct use with the host C APIs.
pub const Prop = struct {
    name: [:0]u8, // owned
    value: variant.MetaValue, // owned

    pub fn deinit(self: *Prop, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        self.value.deinit(gpa);
    }
};

pub const PropList = struct {
    items: std.ArrayList(Prop) = .empty,

    pub fn append(self: *PropList, gpa: std.mem.Allocator, name: []const u8, value: variant.MetaValue) !void {
        const n = try gpa.dupeZ(u8, name);
        try self.items.append(gpa, .{ .name = n, .value = value });
    }

    pub fn deinit(self: *PropList, gpa: std.mem.Allocator) void {
        for (self.items.items) |*p| p.deinit(gpa);
        self.items.deinit(gpa);
    }

    pub fn get(self: *const PropList, name: []const u8) ?*const variant.MetaValue {
        for (self.items.items) |*p| {
            if (std.mem.eql(u8, p.name, name)) return &p.value;
        }
        return null;
    }
};

test "fps: sensor rational preferred when consistent" {
    const r = rationalizeFps(24.0, .{ 24.0, 1.0 });
    try std.testing.expectEqual(@as(i64, 24), r.num);
    try std.testing.expectEqual(@as(i64, 1), r.den);
}

test "fps: ntsc rates snap to 1001" {
    const r = rationalizeFps(23.976, null);
    try std.testing.expectEqual(@as(i64, 24000), r.num);
    try std.testing.expectEqual(@as(i64, 1001), r.den);
    const r2 = rationalizeFps(29.97, .{ 30000.0, 1001.0 });
    try std.testing.expectEqual(@as(i64, 30000), r2.num);
    try std.testing.expectEqual(@as(i64, 1001), r2.den);
}

test "fps: off-speed sensor rate is ignored" {
    // sensor 48fps but playback 24fps -> use playback
    const r = rationalizeFps(24.0, .{ 48.0, 1.0 });
    try std.testing.expectEqual(@as(i64, 24), r.num);
    try std.testing.expectEqual(@as(i64, 1), r.den);
}

test "fps: odd rates fall back to milli-precision rational" {
    const r = rationalizeFps(17.5, null);
    try std.testing.expectEqual(@as(i64, 35), r.num);
    try std.testing.expectEqual(@as(i64, 2), r.den);
}

test "key mapping" {
    try std.testing.expectEqualStrings("BRAWISO", framePropName("iso").?);
    try std.testing.expect(framePropName("lens_shading_points") == null);
    try std.testing.expectEqualStrings("BRAWGamma", clipPropName("viewing_gamma").?);
}

test "cicp mapping" {
    try std.testing.expectEqual(@as(i64, 1), cicpTransferFromGamma("Rec.709").?);
    try std.testing.expectEqual(@as(i64, 16), cicpTransferFromGamma("Rec.2100 ST2084 (PQ)").?);
    try std.testing.expect(cicpTransferFromGamma("Blackmagic Design Film") == null);
    try std.testing.expectEqual(@as(i64, 9), cicpPrimariesFromGamut("Rec.2020").?);
    try std.testing.expect(cicpPrimariesFromGamut("Blackmagic Design") == null);
}
