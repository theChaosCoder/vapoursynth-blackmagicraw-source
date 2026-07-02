//! VapourSynth adapter: braw.Source (video). braw.AudioSource follows in M4.

const std = @import("std");
const vapoursynth = @import("vapoursynth");
const core_mod = @import("core");

const vs = vapoursynth.vapoursynth4;
const vsc = vapoursynth.vsconstants;
const ZAPI = vapoursynth.ZAPI;

const allocator = std.heap.c_allocator;

const plugin_id = "com.thechaoscoder.braw";

const SourceData = struct {
    dec: *core_mod.Decoder,
    vi: vs.VideoInfo,
    alpha_format: vs.VideoFormat, // valid when alpha
    alpha: bool,
    fps: core_mod.meta.Rational,
};

// ---------------------------------------------------------------------------
// helpers for runtime-keyed frame properties
// ---------------------------------------------------------------------------

fn propSetMeta(zapi: *const ZAPI, map: ?*vs.Map, name: [:0]const u8, value: *const core_mod.MetaValue) void {
    const api = zapi.vsapi;
    switch (value.*) {
        .empty => {},
        .int => |i| _ = api.mapSetInt.?(map, name.ptr, i, .Replace),
        .float => |f| _ = api.mapSetFloat.?(map, name.ptr, f, .Replace),
        .string => |s| _ = api.mapSetData.?(map, name.ptr, s.ptr, @intCast(s.len), .Utf8, .Replace),
        .int_array => |a| _ = api.mapSetIntArray.?(map, name.ptr, a.ptr, @intCast(a.len)),
        .float_array => |a| _ = api.mapSetFloatArray.?(map, name.ptr, a.ptr, @intCast(a.len)),
    }
}

fn propSetList(zapi: *const ZAPI, map: ?*vs.Map, list: *const core_mod.meta.PropList) void {
    for (list.items.items) |*p| {
        propSetMeta(zapi, map, p.name, &p.value);
    }
}

// ---------------------------------------------------------------------------
// braw.Source
// ---------------------------------------------------------------------------

fn sourceGetFrame(
    n: c_int,
    activation_reason: vs.ActivationReason,
    instance_data: ?*anyopaque,
    frame_data: ?*?*anyopaque,
    frame_ctx: ?*vs.FrameContext,
    core: ?*vs.Core,
    vsapi: ?*const vs.API,
) callconv(.c) ?*const vs.Frame {
    _ = frame_data;
    if (activation_reason != .Initial) return null;

    const d: *SourceData = @ptrCast(@alignCast(instance_data));
    const zapi = ZAPI.init(vsapi, core, frame_ctx);

    if (n < 0 or n >= d.vi.numFrames) {
        zapi.setFilterError("braw.Source: frame index out of range");
        return null;
    }

    const w: u32 = @intCast(d.vi.width);
    const h: u32 = @intCast(d.vi.height);

    const dst = zapi.newVideoFrame(&d.vi.format, d.vi.width, d.vi.height, null) orelse {
        zapi.setFilterError("braw.Source: failed to allocate frame");
        return null;
    };
    var alpha_frame: ?*vs.Frame = null;
    if (d.alpha) {
        alpha_frame = zapi.newVideoFrame(&d.alpha_format, d.vi.width, d.vi.height, null);
        if (alpha_frame == null) {
            zapi.freeFrame(dst);
            zapi.setFilterError("braw.Source: failed to allocate alpha frame");
            return null;
        }
    }

    var dest: core_mod.formats.Dest = .{
        .width = w,
        .height = h,
        .planes = .{
            zapi.getWritePtr(dst, 0),
            zapi.getWritePtr(dst, 1),
            zapi.getWritePtr(dst, 2),
            if (alpha_frame) |af| zapi.getWritePtr(af, 0) else null,
        },
        .strides = .{
            @intCast(zapi.getStride(dst, 0)),
            @intCast(zapi.getStride(dst, 1)),
            @intCast(zapi.getStride(dst, 2)),
            if (alpha_frame) |af| @intCast(zapi.getStride(af, 0)) else 0,
        },
    };

    var fm: core_mod.FrameMeta = .{};
    defer fm.deinit(allocator);
    d.dec.decodeFrame(@intCast(n), &dest, &fm) catch |e| {
        zapi.freeFrame(dst);
        if (alpha_frame) |af| zapi.freeFrame(af);
        var buf: [512]u8 = undefined;
        zapi.setFilterError(core_mod.decoder.formatDecodeError(&buf, "braw.Source", e, n, &fm));
        return null;
    };

    const props_map = zapi.getFramePropertiesRW(dst);
    const props = zapi.initZMap(props_map);

    props.setDurationNum(d.fps.den);
    props.setDurationDen(d.fps.num);
    props.setMatrix(.RGB);
    // modern range prop: 1 = full range (the deprecated _ColorRange alias
    // is derived by the core)
    props.setInt("_Range", 1, .Replace);
    props.setFieldBased(.PROGRESSIVE);
    // tag transfer/primaries when the effective gamma/gamut has a CICP code
    // (e.g. gamut="Rec.709"); Blackmagic-native spaces stay untagged
    if (d.dec.info.cicp_transfer) |t| props.setInt("_Transfer", t, .Replace);
    if (d.dec.info.cicp_primaries) |p| props.setInt("_Primaries", p, .Replace);
    props.setInt("BRAWSidecarAttached", @intFromBool(d.dec.info.sidecar_attached), .Replace);
    const abs_time = @as(f64, @floatFromInt(n)) * @as(f64, @floatFromInt(d.fps.den)) / @as(f64, @floatFromInt(d.fps.num));
    props.setFloat("_AbsoluteTime", abs_time, .Replace);

    if (fm.timecode) |tc| {
        _ = zapi.vsapi.mapSetData.?(props_map, "BRAWTimecode", tc.ptr, @intCast(tc.len), .Utf8, .Replace);
    }
    if (fm.sensor_rate) |sr| {
        props.setFloat("BRAWSensorRate", if (sr[1] != 0) sr[0] / sr[1] else sr[0], .Replace);
    }
    propSetList(&zapi, props_map, &d.dec.clip_props);
    propSetList(&zapi, props_map, &d.dec.clip_props_all);
    propSetList(&zapi, props_map, &fm.props);
    propSetList(&zapi, props_map, &fm.props_all);

    if (alpha_frame) |af| {
        const aprops = zapi.initZMap(zapi.getFramePropertiesRW(af));
        aprops.setInt("_Range", 1, .Replace);
        props.setAlpha(af);
    }

    return dst;
}

fn sourceFree(instance_data: ?*anyopaque, core: ?*vs.Core, vsapi: ?*const vs.API) callconv(.c) void {
    _ = core;
    _ = vsapi;
    const d: *SourceData = @ptrCast(@alignCast(instance_data));
    d.dec.close();
    allocator.destroy(d);
}

// ---------------------------------------------------------------------------
// braw.AudioSource
// ---------------------------------------------------------------------------

const AudioData = struct {
    dec: *core_mod.Decoder,
    ai: vs.AudioInfo,
    bit_depth: u32,
    channels: u32,
    packed_bytes_per_sample_frame: usize, // channels * bit_depth/8
};

fn audioGetFrame(
    n: c_int,
    activation_reason: vs.ActivationReason,
    instance_data: ?*anyopaque,
    frame_data: ?*?*anyopaque,
    frame_ctx: ?*vs.FrameContext,
    core: ?*vs.Core,
    vsapi: ?*const vs.API,
) callconv(.c) ?*const vs.Frame {
    _ = frame_data;
    if (activation_reason != .Initial) return null;

    const d: *AudioData = @ptrCast(@alignCast(instance_data));
    const zapi = ZAPI.init(vsapi, core, frame_ctx);

    const start: i64 = @as(i64, n) * vs.AUDIO_FRAME_SAMPLES;
    if (n < 0 or start >= d.ai.numSamples) {
        zapi.setFilterError("braw.AudioSource: frame index out of range");
        return null;
    }
    const want: u32 = @intCast(@min(@as(i64, vs.AUDIO_FRAME_SAMPLES), d.ai.numSamples - start));

    const packed_buf = allocator.alloc(u8, @as(usize, want) * d.packed_bytes_per_sample_frame) catch {
        zapi.setFilterError("braw.AudioSource: out of memory");
        return null;
    };
    defer allocator.free(packed_buf);

    // The SDK may return fewer samples per call; loop until the frame is full.
    var got: u32 = 0;
    while (got < want) {
        const off = @as(usize, got) * d.packed_bytes_per_sample_frame;
        const res = d.dec.readAudio(start + got, packed_buf[off..], want - got) catch {
            zapi.setFilterError("braw.AudioSource: audio read failed");
            return null;
        };
        if (res.samples == 0) break;
        got += res.samples;
    }
    if (got < want) {
        // zero-fill anything the SDK could not deliver at EOF
        @memset(packed_buf[@as(usize, got) * d.packed_bytes_per_sample_frame ..], 0);
    }

    const frame = zapi.newAudioFrame(&d.ai.format, @intCast(want), null) orelse {
        zapi.setFilterError("braw.AudioSource: failed to allocate audio frame");
        return null;
    };

    var ch: u32 = 0;
    while (ch < d.channels) : (ch += 1) {
        const plane = zapi.getWritePtr(frame, @intCast(ch));
        core_mod.audio.unpackChannelToVs(d.bit_depth, d.channels, packed_buf, ch, plane, want) catch {
            zapi.freeFrame(frame);
            zapi.setFilterError("braw.AudioSource: unsupported bit depth");
            return null;
        };
    }
    return frame;
}

fn audioFree(instance_data: ?*anyopaque, core: ?*vs.Core, vsapi: ?*const vs.API) callconv(.c) void {
    _ = core;
    _ = vsapi;
    const d: *AudioData = @ptrCast(@alignCast(instance_data));
    d.dec.close();
    allocator.destroy(d);
}

fn audioCreate(in_map: ?*const vs.Map, out_map: ?*vs.Map, user_data: ?*anyopaque, core: ?*vs.Core, vsapi: ?*const vs.API) callconv(.c) void {
    _ = user_data;
    const zapi = ZAPI.init(vsapi, core, null);
    const map_in = zapi.initZMap(in_map);
    var err_buf: [2048]u8 = undefined;
    const map_out = zapi.initZMap2(out_map, &err_buf);

    const source = map_in.getData("source", 0) orelse {
        map_out.setError("braw.AudioSource: 'source' is required");
        return;
    };
    const libpath = map_in.getData("libpath", 0);

    const dec = openFromMap(vsapi, core, map_out, "braw.AudioSource", source, .{
        .libpath = libpath,
    }) orelse return;

    const au = dec.info.audio orelse {
        dec.close();
        map_out.setError("braw.AudioSource: clip has no audio track");
        return;
    };
    if (au.bit_depth != 16 and au.bit_depth != 24 and au.bit_depth != 32) {
        dec.close();
        map_out.setError2("braw.AudioSource: unsupported audio bit depth {d}", .{au.bit_depth});
        return;
    }
    if (au.sample_count > std.math.maxInt(i64)) {
        dec.close();
        map_out.setError("braw.AudioSource: too many samples");
        return;
    }

    // channel layout: mono = front center, stereo = FL|FR, otherwise the
    // first N channel positions
    const layout: u64 = switch (au.channels) {
        1 => 1 << @intFromEnum(vs.AudioChannels.FrontCenter),
        2 => (1 << @intFromEnum(vs.AudioChannels.FrontLeft)) | (1 << @intFromEnum(vs.AudioChannels.FrontRight)),
        else => (@as(u64, 1) << @intCast(au.channels)) - 1,
    };

    const d = allocator.create(AudioData) catch {
        dec.close();
        map_out.setError("braw.AudioSource: out of memory");
        return;
    };

    var af: vs.AudioFormat = .{};
    if (zapi.queryAudioFormat(&af, .Integer, @intCast(au.bit_depth), layout) == 0) {
        dec.close();
        allocator.destroy(d);
        map_out.setError("braw.AudioSource: audio format rejected by core");
        return;
    }

    const num_samples: i64 = @intCast(au.sample_count);
    d.* = .{
        .dec = dec,
        .ai = .{
            .format = af,
            .sampleRate = @intCast(au.sample_rate),
            .numSamples = num_samples,
            .numFrames = @intCast(@divTrunc(num_samples + vs.AUDIO_FRAME_SAMPLES - 1, vs.AUDIO_FRAME_SAMPLES)),
        },
        .bit_depth = au.bit_depth,
        .channels = au.channels,
        .packed_bytes_per_sample_frame = @as(usize, au.channels) * (au.bit_depth / 8),
    };

    zapi.createAudioFilter(out_map, "AudioSource", &d.ai, audioGetFrame, audioFree, .Unordered, null, d);
}

fn pluginDir(vsapi: ?*const vs.API, core: ?*vs.Core, buf: []u8) ?[]const u8 {
    const plugin = vsapi.?.getPluginByID.?(plugin_id, core) orelse return null;
    const path_raw = vsapi.?.getPluginPath.?(plugin) orelse return null;
    const path = std.mem.span(path_raw);
    const dir = std.fs.path.dirname(path) orelse return null;
    if (dir.len > buf.len) return null;
    @memcpy(buf[0..dir.len], dir);
    return buf[0..dir.len];
}

/// Shared open path of Source/AudioSource: plugin-dir discovery, decoder
/// open, error reporting with searched-path details.
fn openFromMap(
    vsapi: ?*const vs.API,
    core: ?*vs.Core,
    map_out: anytype,
    comptime fname: []const u8,
    source: []const u8,
    opts_in: core_mod.OpenOptions,
) ?*core_mod.Decoder {
    var opts = opts_in;
    var plugin_dir_buf: [4096]u8 = undefined;
    opts.plugin_dir = pluginDir(vsapi, core, &plugin_dir_buf);

    var err_detail: ?[]u8 = null;
    return core_mod.Decoder.open(allocator, source, opts, &err_detail) catch |e| {
        defer if (err_detail) |ed| allocator.free(ed);
        map_out.setError2(fname ++ ": failed to open '{s}': {s}{s}{s}", .{
            source,
            @errorName(e),
            if (err_detail != null) "\n" else "",
            if (err_detail) |ed| ed else "",
        });
        return null;
    };
}

fn depthErrorMsg(comptime fname: []const u8, e: core_mod.formats.DepthSelectError) [:0]const u8 {
    return switch (e) {
        error.NoFloat8 => fname ++ ": there is no 8-bit float format",
        error.BadBitdepth => fname ++ ": 'bitdepth' must be 8, 16 or 32",
        error.FpRequiresBitdepth => fname ++ ": 'fp' requires 'bitdepth'",
    };
}

fn overrideErrorMsg(comptime fname: []const u8, e: core_mod.decoder.OverrideError) [:0]const u8 {
    return switch (e) {
        error.KelvinOutOfRange => fname ++ ": 'kelvin' out of range",
        error.TintOutOfRange => fname ++ ": 'tint' out of range",
        error.IsoOutOfRange => fname ++ ": 'iso' out of range",
        error.ColorScienceOutOfRange => fname ++ ": 'colorscience' out of range",
    };
}

fn sourceCreate(in_map: ?*const vs.Map, out_map: ?*vs.Map, user_data: ?*anyopaque, core: ?*vs.Core, vsapi: ?*const vs.API) callconv(.c) void {
    _ = user_data;
    const zapi = ZAPI.init(vsapi, core, null);
    const map_in = zapi.initZMap(in_map);
    var err_buf: [2048]u8 = undefined;
    const map_out = zapi.initZMap2(out_map, &err_buf);

    const source = map_in.getData("source", 0) orelse {
        map_out.setError("braw.Source: 'source' is required");
        return;
    };

    const depth = core_mod.formats.resolveDepth(
        map_in.getInt(i64, "bitdepth"),
        map_in.getBool("fp"),
    ) catch |e| {
        map_out.setError(depthErrorMsg("braw.Source", e));
        return;
    };
    const alpha = map_in.getBool("alpha") orelse false;
    var scale: core_mod.decoder.Scale = .full;
    if (map_in.getInt(i64, "scale")) |s| {
        scale = core_mod.decoder.Scale.fromInt(s) orelse {
            map_out.setError("braw.Source: 'scale' must be 1, 2, 4 or 8");
            return;
        };
    }

    const frame_overrides = core_mod.decoder.frameOverridesFromParams(
        map_in.getInt(i64, "kelvin"),
        map_in.getInt(i64, "tint"),
        map_in.getFloat(f64, "exposure"),
        map_in.getInt(i64, "iso"),
    ) catch |e| {
        map_out.setError(overrideErrorMsg("braw.Source", e));
        return;
    };
    const clip_overrides = core_mod.decoder.clipOverridesFromParams(
        map_in.getData("gamma", 0),
        map_in.getData("gamut", 0),
        map_in.getInt(i64, "colorscience"),
        map_in.getBool("highlightrecovery"),
        map_in.getBool("gamutcompression"),
    ) catch |e| {
        map_out.setError(overrideErrorMsg("braw.Source", e));
        return;
    };

    const threads: u32 = if (map_in.getInt(i64, "threads")) |t| std.math.cast(u32, t) orelse 0 else 0;
    const collect_all = map_in.getBool("allmetaprops") orelse false;
    const libpath = map_in.getData("libpath", 0);

    var pipeline: core_mod.decoder.Pipeline = .cpu;
    if (map_in.getData("pipeline", 0)) |p| {
        pipeline = core_mod.decoder.Pipeline.parse(p) orelse {
            map_out.setError("braw.Source: 'pipeline' must be 'cpu', 'cuda' or 'metal'");
            return;
        };
    }

    const dec = openFromMap(vsapi, core, map_out, "braw.Source", source, .{
        .libpath = libpath,
        .threads = threads,
        .pipeline = pipeline,
        .depth = depth,
        .alpha = alpha,
        .scale = scale,
        .collect_all_meta = collect_all,
        .frame_overrides = frame_overrides,
        .clip_overrides = clip_overrides,
    }) orelse return;

    const info = dec.info;
    if (info.frame_count == 0 or info.frame_count > std.math.maxInt(c_int)) {
        dec.close();
        map_out.setError("braw.Source: clip has no (or too many) frames");
        return;
    }

    const d = allocator.create(SourceData) catch {
        dec.close();
        map_out.setError("braw.Source: out of memory");
        return;
    };

    // the decoder resolved auto depth against the effective gamma
    const eff_depth = dec.depth;
    var vf: vs.VideoFormat = undefined;
    const sample_type: vs.SampleType = switch (eff_depth) {
        .u8_, .u16_ => .Integer,
        .f16, .f32_ => .Float,
    };
    const bits: i32 = switch (eff_depth) {
        .u8_ => 8,
        .u16_, .f16 => 16,
        .f32_ => 32,
    };
    if (zapi.queryVideoFormat(&vf, .RGB, sample_type, bits, 0, 0) == 0) {
        dec.close();
        allocator.destroy(d);
        map_out.setError("braw.Source: video format rejected by core");
        return;
    }
    var af: vs.VideoFormat = undefined;
    if (alpha) {
        if (zapi.queryVideoFormat(&af, .Gray, sample_type, bits, 0, 0) == 0) {
            dec.close();
            allocator.destroy(d);
            map_out.setError("braw.Source: alpha format rejected by core");
            return;
        }
    }

    d.* = .{
        .dec = dec,
        .vi = .{
            .format = vf,
            .fpsNum = info.fps.num,
            .fpsDen = info.fps.den,
            .width = @intCast(info.out_width),
            .height = @intCast(info.out_height),
            .numFrames = @intCast(info.frame_count),
        },
        .alpha_format = if (alpha) af else undefined,
        .alpha = alpha,
        .fps = info.fps,
    };

    zapi.createVideoFilter(out_map, "Source", &d.vi, sourceGetFrame, sourceFree, .Unordered, null, d);
}

export fn VapourSynthPluginInit2(plugin: *vs.Plugin, vspapi: *const vs.PLUGINAPI) void {
    ZAPI.Plugin.config(
        plugin_id,
        "braw",
        "Blackmagic RAW source",
        .{ .major = 0, .minor = 1, .patch = 0 },
        plugin,
        vspapi,
    );
    ZAPI.Plugin.function(
        "Source",
        "source:data;bitdepth:int:opt;fp:int:opt;pipeline:data:opt;alpha:int:opt;scale:int:opt;" ++
            "kelvin:int:opt;tint:int:opt;exposure:float:opt;iso:int:opt;" ++
            "gamma:data:opt;gamut:data:opt;colorscience:int:opt;" ++
            "highlightrecovery:int:opt;gamutcompression:int:opt;" ++
            "allmetaprops:int:opt;threads:int:opt;libpath:data:opt;",
        "clip:vnode;",
        sourceCreate,
        plugin,
        vspapi,
    );
    ZAPI.Plugin.function(
        "AudioSource",
        "source:data;libpath:data:opt;",
        "clip:anode;",
        audioCreate,
        plugin,
        vspapi,
    );
}
