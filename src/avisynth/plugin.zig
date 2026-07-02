//! AviSynth+ adapter: BRAWSource (video + attached audio track), Windows x64.
//!
//! ABI strategy (proven in autoadjuster):
//!  - avisynth_c.h imported with AVSC_NO_DECLSPEC + a minimal windows.h stub
//!  - avs_loader.c compiles the real dynamic loader and marshals every
//!    by-value AVS_Value crossing (Zig mislowers small by-value structs)
//!  - a hand-typed callconv(.winapi) API table (translate-c drops __stdcall)
//!  - exports.def pins the undecorated init exports

const std = @import("std");
const core_mod = @import("core");
const avs = @import("avs.zig");
const c = avs.c;

const cc: std.builtin.CallingConvention = .winapi;
const allocator = std.heap.c_allocator;

const VI = c.AVS_VideoInfo;
const VF = c.AVS_VideoFrame;
const Clip = c.AVS_Clip;
const Env = c.AVS_ScriptEnvironment;
const Val = c.AVS_Value;
const Map = c.AVS_Map;
const FI = c.AVS_FilterInfo;
const ApplyFn = *const fn (?*Env, Val, ?*anyopaque) callconv(cc) Val;

extern fn bsrc_load_avs_library() ?*c.AVS_Library;
extern fn bsrc_new_c_filter(?*Env, *?*FI, *const Val, c_int) ?*Clip;
extern fn bsrc_apply_func() ?*anyopaque;
extern fn bsrc_module_dir([*]u8, c_int) c_int;

var g_lib: ?*c.AVS_Library = null;

const Api = struct {
    new_video_frame_p_a: *const fn (?*Env, ?*const VI, ?*VF, c_int) callconv(cc) ?*VF,
    release_video_frame: *const fn (?*VF) callconv(cc) void,
    get_write_ptr_p: *const fn (?*VF, c_int) callconv(cc) [*c]u8,
    get_pitch_p: *const fn (?*const VF, c_int) callconv(cc) c_int,
    get_frame_props_rw: *const fn (?*Env, ?*VF) callconv(cc) ?*Map,
    prop_set_int: *const fn (?*Env, ?*Map, [*c]const u8, i64, c_int) callconv(cc) c_int,
    prop_set_float: *const fn (?*Env, ?*Map, [*c]const u8, f64, c_int) callconv(cc) c_int,
    prop_set_data: *const fn (?*Env, ?*Map, [*c]const u8, [*c]const u8, c_int, c_int) callconv(cc) c_int,
    prop_set_int_array: *const fn (?*Env, ?*Map, [*c]const u8, [*c]const i64, c_int) callconv(cc) c_int,
    prop_set_float_array: *const fn (?*Env, ?*Map, [*c]const u8, [*c]const f64, c_int) callconv(cc) c_int,
    release_clip: *const fn (?*Clip) callconv(cc) void,
    set_to_clip: *const fn (?*Val, ?*Clip) callconv(cc) void,
    add_function: *const fn (?*Env, [*c]const u8, [*c]const u8, ApplyFn, ?*anyopaque) callconv(cc) c_int,
    save_string: *const fn (?*Env, [*c]const u8, c_int) callconv(cc) [*c]u8,
};
var api: Api = undefined;

fn loadApi() void {
    const L = g_lib.?;
    api = .{
        .new_video_frame_p_a = @ptrCast(L.avs_new_video_frame_p_a.?),
        .release_video_frame = @ptrCast(L.avs_release_video_frame.?),
        .get_write_ptr_p = @ptrCast(L.avs_get_write_ptr_p.?),
        .get_pitch_p = @ptrCast(L.avs_get_pitch_p.?),
        .get_frame_props_rw = @ptrCast(L.avs_get_frame_props_rw.?),
        .prop_set_int = @ptrCast(L.avs_prop_set_int.?),
        .prop_set_float = @ptrCast(L.avs_prop_set_float.?),
        .prop_set_data = @ptrCast(L.avs_prop_set_data.?),
        .prop_set_int_array = @ptrCast(L.avs_prop_set_int_array.?),
        .prop_set_float_array = @ptrCast(L.avs_prop_set_float_array.?),
        .release_clip = @ptrCast(L.avs_release_clip.?),
        .set_to_clip = @ptrCast(L.avs_set_to_clip.?),
        .add_function = @ptrCast(L.avs_add_function.?),
        .save_string = @ptrCast(L.avs_save_string.?),
    };
}

const FilterData = struct {
    dec: *core_mod.Decoder,
    alpha: bool,
    fps: core_mod.meta.Rational,
    bit_depth: u32,
    channels: u32,
    packed_bytes_per_sample_frame: usize,
};

// --- AVS_Value helpers (plain memory reads/writes, no ABI crossing) --------

fn argAt(args: *const Val, i: usize) Val {
    if (args.type == 'a' and i < @as(usize, @intCast(args.array_size))) {
        return args.d.array[i];
    }
    if (i == 0) return args.*;
    var v: Val = std.mem.zeroes(Val);
    v.type = 'v';
    return v;
}

fn defined(v: Val) bool {
    return v.type != 'v';
}

fn asStr(v: Val) ?[]const u8 {
    if (v.type != 's' or v.d.string == null) return null;
    return std.mem.span(@as([*:0]const u8, @ptrCast(v.d.string)));
}

fn asInt(v: Val) ?i64 {
    return switch (v.type) {
        'i' => v.d.integer,
        'l' => v.d.longlong,
        else => null,
    };
}

fn asBool(v: Val) ?bool {
    return if (v.type == 'b') v.d.boolean != 0 else null;
}

fn asFloat(v: Val) ?f64 {
    return switch (v.type) {
        'f' => v.d.floating_pt,
        'd' => v.d.double_pt,
        'i' => @floatFromInt(v.d.integer),
        'l' => @floatFromInt(v.d.longlong),
        else => null,
    };
}

fn setErrorVal(env: ?*Env, out: *Val, msg: []const u8) void {
    out.* = std.mem.zeroes(Val);
    out.type = 'e';
    out.d.string = api.save_string(env, msg.ptr, @intCast(msg.len));
}

// --- frame properties -------------------------------------------------------

fn propSetMeta(env: ?*Env, map: ?*Map, name: [:0]const u8, value: *const core_mod.MetaValue) void {
    switch (value.*) {
        .empty => {},
        .int => |i| _ = api.prop_set_int(env, map, name.ptr, i, 0),
        .float => |f| _ = api.prop_set_float(env, map, name.ptr, f, 0),
        .string => |s| _ = api.prop_set_data(env, map, name.ptr, s.ptr, @intCast(s.len), 0),
        .int_array => |a| _ = api.prop_set_int_array(env, map, name.ptr, a.ptr, @intCast(a.len)),
        .float_array => |a| _ = api.prop_set_float_array(env, map, name.ptr, a.ptr, @intCast(a.len)),
    }
}

fn propSetList(env: ?*Env, map: ?*Map, list: *const core_mod.meta.PropList) void {
    for (list.items.items) |*p| {
        propSetMeta(env, map, p.name, &p.value);
    }
}

// --- filter callbacks --------------------------------------------------------

fn getFrame(fi_opt: [*c]FI, n: c_int) callconv(cc) ?*VF {
    const fi: *FI = fi_opt;
    const d: *FilterData = @ptrCast(@alignCast(fi.user_data));

    if (n < 0 or n >= fi.vi.num_frames) {
        fi.@"error" = "BRAWSource: frame index out of range";
        return null;
    }

    const frame = api.new_video_frame_p_a(fi.env, &fi.vi, null, c.AVS_FRAME_ALIGN) orelse {
        fi.@"error" = "BRAWSource: failed to allocate frame";
        return null;
    };

    const planes = [4]c_int{ c.AVS_PLANAR_R, c.AVS_PLANAR_G, c.AVS_PLANAR_B, c.AVS_PLANAR_A };
    var dest: core_mod.formats.Dest = .{
        .width = @intCast(fi.vi.width),
        .height = @intCast(fi.vi.height),
        .planes = .{ null, null, null, null },
        .strides = .{ 0, 0, 0, 0 },
    };
    const nplanes: usize = if (d.alpha) 4 else 3;
    for (0..nplanes) |i| {
        dest.planes[i] = api.get_write_ptr_p(frame, planes[i]);
        dest.strides[i] = @intCast(api.get_pitch_p(frame, planes[i]));
    }

    var fm: core_mod.FrameMeta = .{};
    defer fm.deinit(allocator);
    d.dec.decodeFrame(@intCast(n), &dest, &fm) catch |e| {
        api.release_video_frame(frame);
        var buf: [512]u8 = undefined;
        const msg = core_mod.decoder.formatDecodeError(&buf, "BRAWSource", e, n, &fm);
        fi.@"error" = api.save_string(fi.env, msg.ptr, @intCast(msg.len));
        return null;
    };

    const map = api.get_frame_props_rw(fi.env, frame);
    _ = api.prop_set_int(fi.env, map, "_Matrix", 0, 0);
    _ = api.prop_set_int(fi.env, map, "_ColorRange", 0, 0); // AviSynth: 0 = full
    _ = api.prop_set_int(fi.env, map, "_FieldBased", 0, 0);
    if (d.dec.info.cicp_transfer) |t| _ = api.prop_set_int(fi.env, map, "_Transfer", t, 0);
    if (d.dec.info.cicp_primaries) |p| _ = api.prop_set_int(fi.env, map, "_Primaries", p, 0);
    _ = api.prop_set_int(fi.env, map, "BRAWSidecarAttached", @intFromBool(d.dec.info.sidecar_attached), 0);
    _ = api.prop_set_int(fi.env, map, "_DurationNum", d.fps.den, 0);
    _ = api.prop_set_int(fi.env, map, "_DurationDen", d.fps.num, 0);
    const abs_time = @as(f64, @floatFromInt(n)) * @as(f64, @floatFromInt(d.fps.den)) / @as(f64, @floatFromInt(d.fps.num));
    _ = api.prop_set_float(fi.env, map, "_AbsoluteTime", abs_time, 0);
    if (fm.timecode) |tc| {
        _ = api.prop_set_data(fi.env, map, "BRAWTimecode", tc.ptr, @intCast(tc.len), 0);
    }
    if (fm.sensor_rate) |sr| {
        _ = api.prop_set_float(fi.env, map, "BRAWSensorRate", if (sr[1] != 0) sr[0] / sr[1] else sr[0], 0);
    }
    propSetList(fi.env, map, &d.dec.clip_props);
    propSetList(fi.env, map, &d.dec.clip_props_all);
    propSetList(fi.env, map, &fm.props);
    propSetList(fi.env, map, &fm.props_all);

    return frame;
}

fn getParity(fi: [*c]FI, n: c_int) callconv(cc) c_int {
    _ = fi;
    _ = n;
    return 0;
}

fn getAudio(fi_opt: [*c]FI, buf_opt: ?*anyopaque, start: i64, count: i64) callconv(cc) c_int {
    const fi: *FI = fi_opt;
    const d: *FilterData = @ptrCast(@alignCast(fi.user_data));
    const buf: [*]u8 = @ptrCast(buf_opt orelse return -1);
    if (count <= 0) return 0;

    const total_bytes = @as(usize, @intCast(count)) * d.packed_bytes_per_sample_frame;
    const out = buf[0..total_bytes];

    var got: i64 = 0;
    while (got < count) {
        const off = @as(usize, @intCast(got)) * d.packed_bytes_per_sample_frame;
        const want: u32 = @intCast(@min(count - got, 1 << 20));
        const res = d.dec.readAudio(start + got, out[off..], want) catch {
            fi.@"error" = "BRAWSource: audio read failed";
            @memset(out[off..], 0);
            return -1;
        };
        if (res.samples == 0) break;
        got += res.samples;
    }
    if (got < count) {
        @memset(out[@as(usize, @intCast(got)) * d.packed_bytes_per_sample_frame ..], 0);
    }
    return 0;
}

fn freeFilter(fi_opt: [*c]FI) callconv(cc) void {
    const fi: *FI = fi_opt;
    if (fi.user_data) |ud| {
        const d: *FilterData = @ptrCast(@alignCast(ud));
        d.dec.close();
        allocator.destroy(d);
        fi.user_data = null;
    }
}

// --- create ------------------------------------------------------------------

// arg indices per the registration string below
const arg_source = 0;
const arg_bitdepth = 1;
const arg_fp = 2;
const arg_alpha = 3;
const arg_audio = 4;
const arg_scale = 5;
const arg_kelvin = 6;
const arg_tint = 7;
const arg_exposure = 8;
const arg_iso = 9;
const arg_gamma = 10;
const arg_gamut = 11;
const arg_colorscience = 12;
const arg_highlightrecovery = 13;
const arg_gamutcompression = 14;
const arg_allmetaprops = 15;
const arg_threads = 16;
const arg_libpath = 17;

const params_string =
    "s[bitdepth]i[fp]b[alpha]b[audio]b[scale]i[kelvin]i[tint]i[exposure]f[iso]i" ++
    "[gamma]s[gamut]s[colorscience]i[highlightrecovery]b[gamutcompression]b" ++
    "[allmetaprops]b[threads]i[libpath]s";

export fn bsrc_create_impl(env: ?*Env, args: *const Val, out: *Val, user_data: ?*anyopaque) void {
    _ = user_data;

    const source = asStr(argAt(args, arg_source)) orelse {
        setErrorVal(env, out, "BRAWSource: source path is required");
        return;
    };

    const depth = core_mod.formats.resolveDepth(
        asInt(argAt(args, arg_bitdepth)),
        asBool(argAt(args, arg_fp)),
    ) catch |e| {
        setErrorVal(env, out, switch (e) {
            error.NoFloat8 => "BRAWSource: there is no 8-bit float format",
            error.BadBitdepth => "BRAWSource: bitdepth must be 8, 16 or 32",
            error.FpRequiresBitdepth => "BRAWSource: fp requires bitdepth",
        });
        return;
    };
    if (depth) |dep| {
        if (dep == .f16) {
            setErrorVal(env, out, "BRAWSource: 16-bit float is not supported by AviSynth (use bitdepth=16 or 32)");
            return;
        }
    }
    const alpha = asBool(argAt(args, arg_alpha)) orelse false;
    const want_audio = asBool(argAt(args, arg_audio)) orelse true;

    var scale: core_mod.decoder.Scale = .full;
    if (asInt(argAt(args, arg_scale))) |s| {
        scale = core_mod.decoder.Scale.fromInt(s) orelse {
            setErrorVal(env, out, "BRAWSource: scale must be 1, 2, 4 or 8");
            return;
        };
    }

    const override_err_msg = struct {
        fn f(e: core_mod.decoder.OverrideError) []const u8 {
            return switch (e) {
                error.KelvinOutOfRange => "BRAWSource: kelvin out of range",
                error.TintOutOfRange => "BRAWSource: tint out of range",
                error.IsoOutOfRange => "BRAWSource: iso out of range",
                error.ColorScienceOutOfRange => "BRAWSource: colorscience out of range",
            };
        }
    }.f;
    const frame_overrides = core_mod.decoder.frameOverridesFromParams(
        asInt(argAt(args, arg_kelvin)),
        asInt(argAt(args, arg_tint)),
        asFloat(argAt(args, arg_exposure)),
        asInt(argAt(args, arg_iso)),
    ) catch |e| {
        setErrorVal(env, out, override_err_msg(e));
        return;
    };
    const clip_overrides = core_mod.decoder.clipOverridesFromParams(
        asStr(argAt(args, arg_gamma)),
        asStr(argAt(args, arg_gamut)),
        asInt(argAt(args, arg_colorscience)),
        asBool(argAt(args, arg_highlightrecovery)),
        asBool(argAt(args, arg_gamutcompression)),
    ) catch |e| {
        setErrorVal(env, out, override_err_msg(e));
        return;
    };

    const collect_all = asBool(argAt(args, arg_allmetaprops)) orelse false;
    const threads: u32 = if (asInt(argAt(args, arg_threads))) |t| std.math.cast(u32, t) orelse 0 else 0;
    const libpath = asStr(argAt(args, arg_libpath));

    var dir_buf: [4096]u8 = undefined;
    const dir_len = bsrc_module_dir(&dir_buf, dir_buf.len);
    const plugin_dir: ?[]const u8 = if (dir_len > 0) dir_buf[0..@intCast(dir_len)] else null;

    var err_detail: ?[]u8 = null;
    const dec = core_mod.Decoder.open(allocator, source, .{
        .libpath = libpath,
        .plugin_dir = plugin_dir,
        .threads = threads,
        .depth = depth,
        .alpha = alpha,
        .scale = scale,
        .collect_all_meta = collect_all,
        .frame_overrides = frame_overrides,
        .clip_overrides = clip_overrides,
    }, &err_detail) catch |e| {
        defer if (err_detail) |ed| allocator.free(ed);
        var buf: [4096]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "BRAWSource: failed to open '{s}': {s}{s}{s}", .{
            source,
            @errorName(e),
            if (err_detail != null) " - " else "",
            if (err_detail) |ed| ed else "",
        }) catch "BRAWSource: open failed";
        setErrorVal(env, out, msg);
        return;
    };

    const info = dec.info;
    if (info.frame_count == 0 or info.frame_count > std.math.maxInt(c_int)) {
        dec.close();
        setErrorVal(env, out, "BRAWSource: clip has no (or too many) frames");
        return;
    }

    const d = allocator.create(FilterData) catch {
        dec.close();
        setErrorVal(env, out, "BRAWSource: out of memory");
        return;
    };

    var fi: ?*FI = null;
    var child: Val = std.mem.zeroes(Val);
    child.type = 'v';
    const clip = bsrc_new_c_filter(env, &fi, &child, 0) orelse {
        dec.close();
        allocator.destroy(d);
        setErrorVal(env, out, "BRAWSource: avs_new_c_filter failed");
        return;
    };
    const f = fi.?;

    var au_info: ?core_mod.decoder.AudioInfo = null;
    if (want_audio) au_info = info.audio;

    d.* = .{
        .dec = dec,
        .alpha = alpha,
        .fps = info.fps,
        .bit_depth = if (au_info) |au| au.bit_depth else 0,
        .channels = if (au_info) |au| au.channels else 0,
        .packed_bytes_per_sample_frame = if (au_info) |au| @as(usize, au.channels) * (au.bit_depth / 8) else 0,
    };

    f.vi = std.mem.zeroes(VI);
    f.vi.width = @intCast(info.out_width);
    f.vi.height = @intCast(info.out_height);
    f.vi.fps_numerator = @intCast(info.fps.num);
    f.vi.fps_denominator = @intCast(info.fps.den);
    f.vi.num_frames = @intCast(info.frame_count);
    f.vi.pixel_type = switch (dec.depth) {
        .u8_ => if (alpha) c.AVS_CS_RGBAP else c.AVS_CS_RGBP,
        .u16_ => if (alpha) c.AVS_CS_RGBAP16 else c.AVS_CS_RGBP16,
        .f32_ => if (alpha) c.AVS_CS_RGBAPS else c.AVS_CS_RGBPS,
        // auto never resolves to f16; explicit f16 was rejected above
        .f16 => unreachable,
    };
    if (au_info) |au| {
        if (au.bit_depth == 16 or au.bit_depth == 24 or au.bit_depth == 32) {
            f.vi.audio_samples_per_second = @intCast(au.sample_rate);
            f.vi.num_audio_samples = @intCast(au.sample_count);
            f.vi.nchannels = @intCast(au.channels);
            f.vi.sample_type = switch (au.bit_depth) {
                16 => c.AVS_SAMPLE_INT16,
                24 => c.AVS_SAMPLE_INT24,
                else => c.AVS_SAMPLE_INT32,
            };
        }
    }

    f.user_data = d;
    f.get_frame = @ptrCast(&getFrame);
    f.get_parity = @ptrCast(&getParity);
    f.free_filter = @ptrCast(&freeFilter);
    if (f.vi.audio_samples_per_second != 0) {
        f.get_audio = @ptrCast(&getAudio);
    }

    api.set_to_clip(out, clip);
    api.release_clip(clip);
}

// --- plugin init ---------------------------------------------------------------

fn pluginInit(env: ?*Env) [*c]const u8 {
    if (g_lib == null) {
        g_lib = bsrc_load_avs_library();
        if (g_lib == null) return "BRAWSource: failed to load the AviSynth library";
        loadApi();
    }
    _ = api.add_function(env, "BRAWSource", params_string, @ptrCast(@alignCast(bsrc_apply_func().?)), null);
    return "Blackmagic RAW source";
}

export fn avisynth_c_plugin_init(env: ?*Env) callconv(cc) [*c]const u8 {
    return pluginInit(env);
}

export fn avisynth_c_plugin_init2(env: ?*Env) callconv(cc) [*c]const u8 {
    return pluginInit(env);
}
