//! Synchronous bridge over the SDK's asynchronous job model.
//!
//! Per opened clip: one codec, one clip, one callback object. Each frame
//! request submits a read job carrying a `Request` as user data; the SDK
//! calls back on its own worker threads:
//!   ReadComplete    -> harvest frame metadata, set format/scale, chain the
//!                      decode+process job (same user data)
//!   ProcessComplete -> copy pixels straight into the destination planes,
//!                      then signal the waiting requester.
//! Callbacks touch only the Request and raw memory — never host APIs.
//! Multiple requests may be in flight concurrently (the SDK decodes FIFO).

const std = @import("std");
pub const api = @import("braw/api.zig");
const strings = @import("braw/strings.zig");
const variant = @import("braw/variant.zig");
const loader = @import("braw/loader.zig");
const cuda = @import("braw/cuda.zig");
const metal = @import("braw/metal.zig");
const formats = @import("formats.zig");
const meta = @import("meta.zig");
const sync = @import("sync.zig");

/// SDK-returned out-param strings: BSTR and CFStringRef are owned by the
/// caller, Linux `const char*` is borrowed.
const take_out_strings = api.is_windows or api.is_macos;

pub const Scale = enum(u8) {
    full = 1,
    half = 2,
    quarter = 4,
    eighth = 8,

    pub fn toApi(self: Scale) api.ResolutionScale {
        return switch (self) {
            .full => .full,
            .half => .half,
            .quarter => .quarter,
            .eighth => .eighth,
        };
    }

    pub fn fromInt(v: i64) ?Scale {
        return switch (v) {
            1 => .full,
            2 => .half,
            4 => .quarter,
            8 => .eighth,
            else => null,
        };
    }
};

pub const FrameOverrides = struct {
    kelvin: ?u32 = null,
    tint: ?i16 = null,
    exposure: ?f32 = null,
    iso: ?u32 = null,

    pub fn any(self: FrameOverrides) bool {
        return self.kelvin != null or self.tint != null or
            self.exposure != null or self.iso != null;
    }
};

pub const ClipOverrides = struct {
    gamma: ?[]const u8 = null,
    gamut: ?[]const u8 = null,
    colorscience: ?u16 = null,
    highlight_recovery: ?bool = null,
    gamut_compression: ?bool = null,

    pub fn any(self: ClipOverrides) bool {
        return self.gamma != null or self.gamut != null or self.colorscience != null or
            self.highlight_recovery != null or self.gamut_compression != null;
    }
};

pub const OverrideError = error{
    KelvinOutOfRange,
    TintOutOfRange,
    IsoOutOfRange,
    ColorScienceOutOfRange,
};

/// Build FrameOverrides from raw host parameters with range validation —
/// shared by both adapters so limits live in exactly one place.
pub fn frameOverridesFromParams(kelvin: ?i64, tint: ?i64, exposure: ?f64, iso: ?i64) OverrideError!FrameOverrides {
    var o: FrameOverrides = .{};
    if (kelvin) |v| o.kelvin = std.math.cast(u32, v) orelse return error.KelvinOutOfRange;
    if (tint) |v| o.tint = std.math.cast(i16, v) orelse return error.TintOutOfRange;
    if (exposure) |v| o.exposure = @floatCast(v);
    if (iso) |v| o.iso = std.math.cast(u32, v) orelse return error.IsoOutOfRange;
    return o;
}

pub fn clipOverridesFromParams(
    gamma: ?[]const u8,
    gamut: ?[]const u8,
    colorscience: ?i64,
    highlight_recovery: ?bool,
    gamut_compression: ?bool,
) OverrideError!ClipOverrides {
    var o: ClipOverrides = .{
        .gamma = gamma,
        .gamut = gamut,
        .highlight_recovery = highlight_recovery,
        .gamut_compression = gamut_compression,
    };
    if (colorscience) |v| o.colorscience = std.math.cast(u16, v) orelse return error.ColorScienceOutOfRange;
    return o;
}

pub const Pipeline = enum {
    cpu,
    cuda, // NVIDIA (Linux/Windows)
    metal, // Apple GPU (macOS)

    pub fn parse(s: []const u8) ?Pipeline {
        if (std.ascii.eqlIgnoreCase(s, "cpu")) return .cpu;
        if (std.ascii.eqlIgnoreCase(s, "cuda")) return .cuda;
        if (std.ascii.eqlIgnoreCase(s, "metal")) return .metal;
        return null;
    }
};

pub const OpenOptions = struct {
    libpath: ?[]const u8 = null,
    plugin_dir: ?[]const u8 = null,
    threads: u32 = 0,
    pipeline: Pipeline = .cpu,
    /// null = automatic: 16-bit integer, except 32-bit float when the
    /// effective gamma is "Linear" (scene-linear values exceed 1.0 and
    /// would clip in integer formats).
    depth: ?formats.Depth = null,
    alpha: bool = false,
    scale: Scale = .full,
    collect_all_meta: bool = false,
    frame_overrides: FrameOverrides = .{},
    clip_overrides: ClipOverrides = .{},
};

pub const AudioInfo = struct {
    bit_depth: u32,
    channels: u32,
    sample_rate: u32,
    sample_count: u64, // per channel
};

pub const Info = struct {
    width: u32, // full-resolution clip dimensions
    height: u32,
    out_width: u32, // after resolution scale
    out_height: u32,
    frame_count: u64,
    frame_rate: f32,
    fps: meta.Rational,
    sidecar_attached: bool,
    base_frame_index: u32,
    drop_frame_timecode: bool,
    audio: ?AudioInfo,
    /// CICP codes for the EFFECTIVE gamma/gamut (override, else clip
    /// metadata) when they correspond to a standard; null for the
    /// Blackmagic-native spaces.
    cicp_transfer: ?i64,
    cicp_primaries: ?i64,
};

pub const OpenError = error{
    LibraryNotFound,
    SymbolNotFound,
    FactoryFailed,
    CodecFailed,
    OpenClipFailed,
    InvalidProcessingAttribute,
    GpuUnavailable,
    PipelineUnsupported,
    OutOfMemory,
};

pub const DecodeError = error{
    DroppedFrame,
    DecodeFailed,
    OutOfMemory,
};

/// Render the standard decode-failure message (shared by both adapters,
/// which only differ in the function-name prefix).
pub fn formatDecodeError(
    buf: []u8,
    comptime prefix: []const u8,
    e: DecodeError,
    n: i64,
    fm: *const FrameMeta,
) [:0]const u8 {
    return std.fmt.bufPrintZ(buf, prefix ++ ": {s} for frame {d} ({s}, hr=0x{x})", .{
        switch (e) {
            error.DroppedFrame => "dropped frame in source clip",
            error.OutOfMemory => "out of memory",
            error.DecodeFailed => "decode failed",
        },
        n,
        fm.fail_stage,
        @as(u32, @bitCast(fm.fail_hr)),
    }) catch prefix ++ ": decode failed";
}

/// Result metadata of a single decoded frame. Owned by the caller.
pub const FrameMeta = struct {
    timecode: ?[:0]u8 = null,
    sensor_rate: ?[2]f64 = null,
    props: meta.PropList = .{}, // curated BRAW* names
    props_all: meta.PropList = .{}, // raw keys (collect_all_meta only)
    fail_stage: []const u8 = "",
    fail_hr: api.HRESULT = api.S_OK,

    pub fn deinit(self: *FrameMeta, gpa: std.mem.Allocator) void {
        if (self.timecode) |t| gpa.free(t);
        self.props.deinit(gpa);
        self.props_all.deinit(gpa);
        self.* = .{};
    }
};

const Request = struct {
    decoder: *Decoder,
    gpa: std.mem.Allocator,
    expected_index: u64,
    dest: ?*const formats.Dest, // null => metadata-probe read (no decode)
    resource_format: api.ResourceFormat,
    scale: api.ResolutionScale,
    collect_all_meta: bool,
    frame_attrs: ?*api.IBlackmagicRawFrameProcessingAttributes = null,

    event: sync.Event = .{},
    hr: api.HRESULT = api.S_OK,
    fail_stage: []const u8 = "",
    oom: bool = false,

    timecode: ?[:0]u8 = null,
    sensor_rate: ?[2]f64 = null,
    props: meta.PropList = .{},
    props_all: meta.PropList = .{},

    fn fail(self: *Request, hr: api.HRESULT, stage: []const u8) void {
        self.hr = hr;
        self.fail_stage = stage;
    }
};

// ---------------------------------------------------------------------------
// Callback implementation (the one COM interface we provide to the SDK)
// ---------------------------------------------------------------------------

const CallbackShell = extern struct {
    v: *const api.CallbackVTable,
    decoder: *Decoder,
};

fn cbQi(_: *anyopaque, _: api.RefIid, out: *?*anyopaque) callconv(.c) api.HRESULT {
    out.* = null;
    return api.E_NOTIMPL;
}

fn cbAddRef(_: *anyopaque) callconv(.c) api.ULONG {
    return 0;
}

fn cbRelease(_: *anyopaque) callconv(.c) api.ULONG {
    return 0;
}

fn cbNoopDtor(_: *anyopaque) callconv(.c) void {}

fn reqFromJob(job: *api.IBlackmagicRawJob) ?*Request {
    return job.userData(Request);
}

fn failAndSignal(req: *Request, hr: api.HRESULT, stage: []const u8) void {
    req.fail(hr, stage);
    req.event.set();
}

fn cbReadComplete(_: *anyopaque, job: *api.IBlackmagicRawJob, hr: api.HRESULT, frame_opt: ?*api.IBlackmagicRawFrame) callconv(.c) void {
    defer api.release(job);
    const req = reqFromJob(job) orelse return;

    if (hr != api.S_OK) return failAndSignal(req, hr, "read frame");
    const frame = frame_opt orelse
        return failAndSignal(req, api.E_FAIL, "read frame (no frame object)");

    harvestFrameMeta(req, frame);

    // frame-accuracy invariant: the SDK must hand us exactly the frame we asked for
    var got_index: u64 = 0;
    if (frame.v.getFrameIndex(frame, &got_index) == api.S_OK and got_index != req.expected_index) {
        return failAndSignal(req, api.E_FAIL, "frame index mismatch");
    }

    if (req.dest == null) {
        // metadata probe only
        req.event.set();
        return;
    }

    if (req.scale != .full) {
        const shr = frame.v.setResolutionScale(frame, req.scale);
        if (shr != api.S_OK) return failAndSignal(req, shr, "set resolution scale");
    }
    const fhr = frame.v.setResourceFormat(frame, req.resource_format);
    if (fhr != api.S_OK) return failAndSignal(req, fhr, "set resource format");

    if (req.decoder.frame_overrides.any()) {
        req.frame_attrs = buildFrameAttrs(req.decoder, frame) catch
            return failAndSignal(req, api.E_FAIL, "apply frame processing overrides");
    }

    var decode_job: ?*api.IBlackmagicRawJob = null;
    const dhr = frame.v.createJobDecodeAndProcessFrame(frame, req.decoder.clip_attrs, req.frame_attrs, &decode_job);
    if (dhr != api.S_OK or decode_job == null) {
        return failAndSignal(req, dhr, "create decode job");
    }
    const dj = decode_job.?;
    _ = dj.v.setUserData(dj, req);
    const shr2 = dj.v.submit(dj);
    if (shr2 != api.S_OK) {
        api.release(dj);
        return failAndSignal(req, shr2, "submit decode job");
    }
}

fn cbProcessComplete(_: *anyopaque, job: *api.IBlackmagicRawJob, hr: api.HRESULT, image_opt: ?*api.IBlackmagicRawProcessedImage) callconv(.c) void {
    const req = reqFromJob(job) orelse {
        api.release(job);
        return;
    };
    defer {
        if (req.frame_attrs) |fa| {
            api.release(fa);
            req.frame_attrs = null;
        }
        api.release(job);
        req.event.set();
    }

    if (hr != api.S_OK) {
        req.fail(hr, "decode/process");
        return;
    }
    const image = image_opt orelse {
        req.fail(api.E_FAIL, "decode/process (no image)");
        return;
    };
    const dest = req.dest orelse return;

    var w: u32 = 0;
    var h: u32 = 0;
    _ = image.v.getWidth(image, &w);
    _ = image.v.getHeight(image, &h);
    if (w != dest.width or h != dest.height) {
        req.fail(api.E_FAIL, "unexpected output dimensions");
        return;
    }
    var got_fmt: api.ResourceFormat = @enumFromInt(0);
    _ = image.v.getResourceFormat(image, &got_fmt);
    if (got_fmt != req.resource_format) {
        req.fail(api.E_FAIL, "unexpected resource format");
        return;
    }
    var size_bytes: u32 = 0;
    _ = image.v.getResourceSizeBytes(image, &size_bytes);
    var resource: ?*anyopaque = null;
    if (image.v.getResource(image, &resource) != api.S_OK or resource == null) {
        req.fail(api.E_FAIL, "get resource");
        return;
    }

    // On a GPU pipeline the resource lives in device memory: read it back
    // into a host staging buffer (pooled) before the copy.
    var host_src: [*]const u8 = @ptrCast(resource.?);
    var staging: ?[]u8 = null;
    defer if (staging) |s| req.decoder.releasePinned(s);
    if (req.decoder.cuda_ctx != null or req.decoder.metal_queue != null) {
        const buf = req.decoder.acquirePinned(size_bytes) catch {
            req.oom = true;
            return;
        };
        staging = buf;
        if (req.decoder.cuda_ctx) |*ctx| {
            ctx.readback(buf.ptr, @intFromPtr(resource.?), size_bytes) catch {
                req.fail(api.E_FAIL, "GPU readback (cuMemcpyDtoH)");
                return;
            };
        } else {
            metal.readback(req.decoder.metal_queue.?, resource.?, buf.ptr, size_bytes) catch {
                req.fail(api.E_FAIL, "GPU readback (Metal blit)");
                return;
            };
        }
        host_src = buf.ptr;
    }

    formats.copyImage(got_fmt, host_src, size_bytes, dest, req.decoder.depth) catch |e| {
        req.fail(api.E_FAIL, switch (e) {
            error.SizeMismatch => "resource size mismatch (padded buffer?)",
            error.UnsupportedFormat => "unsupported resource format",
        });
        return;
    };
}

fn cbDecodeComplete(_: *anyopaque, _: *api.IBlackmagicRawJob, _: api.HRESULT) callconv(.c) void {}
fn cbTrimProgress(_: *anyopaque, _: *api.IBlackmagicRawJob, _: f32) callconv(.c) void {}
fn cbTrimComplete(_: *anyopaque, _: *api.IBlackmagicRawJob, _: api.HRESULT) callconv(.c) void {}
fn cbSidecarWarn(_: *anyopaque, _: *api.IBlackmagicRawClip, _: api.StringRaw, _: u32, _: api.StringRaw) callconv(.c) void {}
fn cbSidecarErr(_: *anyopaque, _: *api.IBlackmagicRawClip, _: api.StringRaw, _: u32, _: api.StringRaw) callconv(.c) void {}
fn cbPreparePipeline(_: *anyopaque, _: ?*anyopaque, _: api.HRESULT) callconv(.c) void {}

const callback_methods: api.CallbackMethods = .{
    .readComplete = cbReadComplete,
    .decodeComplete = cbDecodeComplete,
    .processComplete = cbProcessComplete,
    .trimProgress = cbTrimProgress,
    .trimComplete = cbTrimComplete,
    .sidecarMetadataParseWarning = cbSidecarWarn,
    .sidecarMetadataParseError = cbSidecarErr,
    .preparePipelineComplete = cbPreparePipeline,
};

const callback_vtable: api.CallbackVTable = if (api.is_windows) .{
    .unknown = .{ .qi = cbQi, .addRef = cbAddRef, .release = cbRelease },
    .methods = callback_methods,
} else .{
    .unknown = .{ .qi = cbQi, .addRef = cbAddRef, .release = cbRelease },
    .methods = callback_methods,
    .dtor_complete = cbNoopDtor,
    .dtor_deleting = cbNoopDtor,
};

// ---------------------------------------------------------------------------
// Metadata harvesting (called on SDK threads; touches only Request memory)
// ---------------------------------------------------------------------------

/// Walk a metadata iterator: getKey -> Variant -> MetaValue, then hand each
/// entry to `handler`. The handler returns true when it took ownership of
/// the value; otherwise it is freed here. Allocation failures propagate.
fn iterateMetadata(
    lib: *loader.Lib,
    gpa: std.mem.Allocator,
    it: *api.IBlackmagicRawMetadataIterator,
    ctx: anytype,
    comptime handler: fn (@TypeOf(ctx), []const u8, *variant.MetaValue) std.mem.Allocator.Error!bool,
) std.mem.Allocator.Error!void {
    var key_raw: api.StringRaw = null;
    while (it.v.getKey(it, &key_raw) == api.S_OK) {
        defer {
            key_raw = null;
            _ = it.v.next(it);
        }
        // dupe's error set is platform-dependent (UTF-16 decode errors on
        // Windows); only OOM aborts, malformed keys are skipped
        const key = strings.dupe(gpa, key_raw, false) catch |e| {
            if (e == error.OutOfMemory) return error.OutOfMemory;
            continue;
        };
        defer gpa.free(key);

        var v: api.Variant = .empty;
        variant.variantInit(lib, &v);
        if (it.v.getData(it, &v) != api.S_OK) continue;
        defer variant.variantClear(lib, &v);

        // toMeta's error set is platform-dependent (StringConversionFailed
        // exists only on macOS), so no exhaustive switch here
        var mv = variant.toMeta(gpa, lib, &v) catch |e| {
            if (e == error.OutOfMemory) return error.OutOfMemory;
            continue;
        };
        errdefer mv.deinit(gpa);
        if (!try handler(ctx, key, &mv)) mv.deinit(gpa);
    }
}

/// Append `mv` to the curated list when the key is known, or (optionally)
/// to the raw list as BRAW_<key>. Returns whether the value was consumed.
fn dispatchMeta(
    gpa: std.mem.Allocator,
    key: []const u8,
    mv: *variant.MetaValue,
    prop_name: ?[]const u8,
    collect_all: bool,
    curated: *meta.PropList,
    all: *meta.PropList,
) std.mem.Allocator.Error!bool {
    if (prop_name) |name| {
        try curated.append(gpa, name, mv.*);
        return true;
    }
    if (collect_all) {
        var namebuf: [128]u8 = undefined;
        const pname = std.fmt.bufPrint(&namebuf, "BRAW_{s}", .{key}) catch key;
        try all.append(gpa, pname, mv.*);
        return true;
    }
    return false;
}

fn frameMetaHandler(req: *Request, key: []const u8, mv: *variant.MetaValue) std.mem.Allocator.Error!bool {
    if (std.mem.eql(u8, key, "sensor_rate")) {
        switch (mv.*) {
            .float_array => |a| if (a.len >= 2) {
                req.sensor_rate = .{ a[0], a[1] };
            },
            .int_array => |a| if (a.len >= 2) {
                req.sensor_rate = .{ @floatFromInt(a[0]), @floatFromInt(a[1]) };
            },
            else => {},
        }
    }
    return dispatchMeta(req.gpa, key, mv, meta.framePropName(key), req.collect_all_meta, &req.props, &req.props_all);
}

/// Sink for the clip-level metadata pass: curated/all props on the decoder
/// plus capture of the viewing gamma/gamut names for depth/CICP resolution.
const ClipMetaCtx = struct {
    dec: *Decoder,
    gamma_buf: [64]u8 = undefined,
    gamma_len: usize = 0,
    gamut_buf: [64]u8 = undefined,
    gamut_len: usize = 0,
};

fn clipMetaHandler(ctx: *ClipMetaCtx, key: []const u8, mv: *variant.MetaValue) std.mem.Allocator.Error!bool {
    switch (mv.*) {
        .string => |s| {
            if (std.mem.eql(u8, key, "viewing_gamma") and s.len <= ctx.gamma_buf.len) {
                @memcpy(ctx.gamma_buf[0..s.len], s);
                ctx.gamma_len = s.len;
            } else if (std.mem.eql(u8, key, "viewing_gamut") and s.len <= ctx.gamut_buf.len) {
                @memcpy(ctx.gamut_buf[0..s.len], s);
                ctx.gamut_len = s.len;
            }
        },
        else => {},
    }
    const dec = ctx.dec;
    return dispatchMeta(dec.gpa, key, mv, meta.clipPropName(key), dec.collect_all_meta, &dec.clip_props, &dec.clip_props_all);
}

fn harvestFrameMeta(req: *Request, frame: *api.IBlackmagicRawFrame) void {
    const gpa = req.gpa;

    var tc_raw: api.StringRaw = null;
    if (frame.v.getTimecode(frame, &tc_raw) == api.S_OK) {
        req.timecode = strings.dupe(gpa, tc_raw, take_out_strings) catch null;
    }

    var it_opt: ?*api.IBlackmagicRawMetadataIterator = null;
    if (frame.v.getMetadataIterator(frame, &it_opt) != api.S_OK) return;
    const it = it_opt orelse return;
    defer api.release(it);

    iterateMetadata(req.decoder.lib, gpa, it, req, frameMetaHandler) catch {
        req.oom = true;
    };
}

fn setFrameAttr(
    fa: *api.IBlackmagicRawFrameProcessingAttributes,
    attr: api.FrameProcessingAttribute,
    value: api.Variant,
) error{AttrFailed}!void {
    var v = value;
    if (fa.v.setFrameAttribute(fa, attr, &v) != api.S_OK) return error.AttrFailed;
}

fn buildFrameAttrs(d: *Decoder, frame: *api.IBlackmagicRawFrame) !*api.IBlackmagicRawFrameProcessingAttributes {
    var fa_opt: ?*api.IBlackmagicRawFrameProcessingAttributes = null;
    if (frame.v.cloneFrameProcessingAttributes(frame, &fa_opt) != api.S_OK) return error.AttrFailed;
    const fa = fa_opt orelse return error.AttrFailed;
    errdefer api.release(fa);

    const o = d.frame_overrides;
    if (o.kelvin) |k| try setFrameAttr(fa, .white_balance_kelvin, api.variantU32(k));
    if (o.tint) |t| try setFrameAttr(fa, .white_balance_tint, api.variantI16(t));
    if (o.exposure) |e| try setFrameAttr(fa, .exposure, api.variantF32(e));
    if (o.iso) |i| try setFrameAttr(fa, .iso, api.variantU32(i));
    return fa;
}

// ---------------------------------------------------------------------------
// Decoder
// ---------------------------------------------------------------------------

pub const Decoder = struct {
    gpa: std.mem.Allocator,
    lib: *loader.Lib,
    factory: *api.IBlackmagicRawFactory,
    codec: *api.IBlackmagicRaw,
    clip: *api.IBlackmagicRawClip,
    clip_ex: ?*api.IBlackmagicRawClipEx,
    audio_if: ?*api.IBlackmagicRawClipAudio,
    clip_attrs: ?*api.IBlackmagicRawClipProcessingAttributes,
    callback: CallbackShell,
    submit_mutex: sync.Mutex = .{},
    audio_mutex: sync.Mutex = .{},

    // GPU pipeline state. CUDA: context + a pool of pinned host staging
    // buffers for the device->host readback (pinned alloc per frame is slow).
    // Metal: the SDK pipeline device, whose MTLCommandQueue drives the blit
    // readback; the staging buffer is Metal-managed inside metal.zig.
    pipeline: Pipeline,
    cuda_ctx: ?cuda.Context = null,
    metal_device: ?*api.IBlackmagicRawPipelineDevice = null,
    metal_queue: ?*anyopaque = null,
    pinned_pool: std.ArrayList([]u8) = .empty,
    pinned_mutex: sync.Mutex = .{},

    depth: formats.Depth,
    alpha: bool,
    scale: Scale,
    resource_format: api.ResourceFormat,
    collect_all_meta: bool,
    frame_overrides: FrameOverrides,

    info: Info,
    camera_type: [:0]u8,
    clip_props: meta.PropList,
    clip_props_all: meta.PropList,

    /// On open failure, a human-readable detail (e.g. searched paths) is
    /// written to `err_detail` (caller owns and frees).
    pub fn open(
        gpa: std.mem.Allocator,
        path: []const u8,
        opts: OpenOptions,
        err_detail: *?[]u8,
    ) OpenError!*Decoder {
        err_detail.* = null;

        var diag: ?[]u8 = null;
        const lib = loader.acquire(gpa, opts.libpath, opts.plugin_dir, &diag) catch |e| {
            if (diag) |dtext| {
                err_detail.* = std.fmt.allocPrint(gpa, "BlackmagicRawAPI library not found; searched:\n{s}", .{dtext}) catch null;
                gpa.free(dtext);
            }
            return switch (e) {
                error.OutOfMemory => error.OutOfMemory,
                error.SymbolNotFound => error.SymbolNotFound,
                else => error.LibraryNotFound,
            };
        };
        errdefer loader.release(lib);

        const self = try gpa.create(Decoder);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .lib = lib,
            .factory = undefined,
            .codec = undefined,
            .clip = undefined,
            .clip_ex = null,
            .audio_if = null,
            .clip_attrs = null,
            .callback = .{ .v = &callback_vtable, .decoder = self },
            .pipeline = opts.pipeline,
            // provisional when depth is auto; finalized in collectClipInfo
            // once the effective gamma is known
            .depth = opts.depth orelse .u16_,
            .alpha = opts.alpha,
            .scale = opts.scale,
            .resource_format = formats.resourceFormat(opts.depth orelse .u16_, opts.alpha),
            .collect_all_meta = opts.collect_all_meta,
            .frame_overrides = opts.frame_overrides,
            .info = undefined,
            .camera_type = @constCast(""),
            .clip_props = .{},
            .clip_props_all = .{},
        };

        self.factory = lib.createFactory() orelse return error.FactoryFailed;
        errdefer api.release(self.factory);

        self.codec = self.factory.createCodec() orelse return error.CodecFailed;
        errdefer {
            self.codec.flushJobs();
            api.release(self.codec);
        }
        errdefer if (self.cuda_ctx) |*ctx| ctx.destroy();
        errdefer if (self.metal_device) |d| api.release(d);

        // configuration is read at the first OpenClip, so pipeline + threads
        // must be set beforehand
        if (opts.threads > 0 or opts.pipeline != .cpu) {
            const cfg = api.queryInterface(self.codec, api.IBlackmagicRawConfiguration, &api.iid_configuration) orelse {
                if (opts.pipeline != .cpu) return error.PipelineUnsupported;
                return error.FactoryFailed;
            };
            defer api.release(cfg);

            if (opts.threads > 0) _ = cfg.v.setCPUThreads(cfg, opts.threads);

            switch (opts.pipeline) {
                .cpu => {},
                .cuda => {
                    self.cuda_ctx = cuda.Context.create() catch |e| {
                        err_detail.* = std.fmt.allocPrint(gpa, "CUDA pipeline requested but unavailable: {s}", .{@errorName(e)}) catch null;
                        return error.GpuUnavailable;
                    };
                    var supported = false;
                    _ = cfg.v.isPipelineSupported(cfg, .cuda, &supported);
                    if (!supported) {
                        err_detail.* = std.fmt.allocPrint(gpa, "the BlackmagicRaw CUDA decoder is not available (libDecoderCUDA missing?)", .{}) catch null;
                        return error.PipelineUnsupported;
                    }
                    if (cfg.v.setPipeline(cfg, .cuda, self.cuda_ctx.?.handle, null) != api.S_OK) {
                        return error.PipelineUnsupported;
                    }
                },
                .metal => {
                    try self.setupMetal(cfg, err_detail);
                },
            }
        }

        _ = self.codec.setCallback(@ptrCast(&self.callback));

        var path_s = strings.make(gpa, path) catch return error.OutOfMemory;
        defer path_s.deinit(gpa);
        self.clip = self.codec.openClip(path_s.raw) catch {
            err_detail.* = std.fmt.allocPrint(gpa, "OpenClip failed for '{s}' (not a .braw file, or unreadable)", .{path}) catch null;
            return error.OpenClipFailed;
        };
        errdefer api.release(self.clip);

        self.clip_ex = api.queryInterface(self.clip, api.IBlackmagicRawClipEx, &api.iid_clip_ex);
        self.audio_if = api.queryInterface(self.clip, api.IBlackmagicRawClipAudio, &api.iid_clip_audio);
        errdefer {
            if (self.clip_attrs) |a| api.release(a);
            if (self.audio_if) |a| api.release(a);
            if (self.clip_ex) |e| api.release(e);
        }

        if (opts.clip_overrides.any()) {
            self.applyClipOverrides(opts.clip_overrides, err_detail) catch |e| return e;
        }

        try self.collectClipInfo(opts);
        return self;
    }

    fn attrRejected(self: *Decoder, err_detail: *?[]u8, name: []const u8) OpenError {
        err_detail.* = std.fmt.allocPrint(
            self.gpa,
            "the SDK rejected the '{s}' override (invalid value for this clip; " ++
                "valid values can be listed with braw-probe or DaVinci Resolve)",
            .{name},
        ) catch null;
        return error.InvalidProcessingAttribute;
    }

    fn setClipAttr(
        self: *Decoder,
        err_detail: *?[]u8,
        ca: *api.IBlackmagicRawClipProcessingAttributes,
        attr: api.ClipProcessingAttribute,
        value: api.Variant,
        name: []const u8,
    ) OpenError!void {
        var v = value;
        if (ca.v.setClipAttribute(ca, attr, &v) != api.S_OK) {
            return self.attrRejected(err_detail, name);
        }
    }

    fn setClipAttrString(
        self: *Decoder,
        err_detail: *?[]u8,
        ca: *api.IBlackmagicRawClipProcessingAttributes,
        attr: api.ClipProcessingAttribute,
        value: []const u8,
        name: []const u8,
    ) OpenError!void {
        var owned = strings.make(self.gpa, value) catch return error.OutOfMemory;
        defer owned.deinit(self.gpa);
        try self.setClipAttr(err_detail, ca, attr, api.variantString(owned.raw), name);
    }

    fn applyClipOverrides(self: *Decoder, o: ClipOverrides, err_detail: *?[]u8) OpenError!void {
        var ca_opt: ?*api.IBlackmagicRawClipProcessingAttributes = null;
        if (self.clip.v.cloneClipProcessingAttributes(self.clip, &ca_opt) != api.S_OK) {
            return self.attrRejected(err_detail, "clip processing attributes");
        }
        const ca = ca_opt orelse return self.attrRejected(err_detail, "clip processing attributes");
        self.clip_attrs = ca;

        if (o.colorscience) |g| {
            try self.setClipAttr(err_detail, ca, .color_science_gen, api.variantU16(g), "colorscience");
        }
        if (o.gamma) |s| {
            try self.setClipAttrString(err_detail, ca, .gamma, s, "gamma");
        }
        if (o.gamut) |s| {
            try self.setClipAttrString(err_detail, ca, .gamut, s, "gamut");
        }
        if (o.highlight_recovery) |b| {
            try self.setClipAttr(err_detail, ca, .highlight_recovery, api.variantU16(@intFromBool(b)), "highlightrecovery");
        }
        if (o.gamut_compression) |b| {
            try self.setClipAttr(err_detail, ca, .gamut_compression_enable, api.variantU16(@intFromBool(b)), "gamutcompression");
        }
    }

    fn collectClipInfo(self: *Decoder, opts: OpenOptions) OpenError!void {
        const gpa = self.gpa;
        const clip = self.clip;

        var w: u32 = 0;
        var h: u32 = 0;
        var rate: f32 = 0;
        var count: u64 = 0;
        _ = clip.v.getWidth(clip, &w);
        _ = clip.v.getHeight(clip, &h);
        _ = clip.v.getFrameRate(clip, &rate);
        _ = clip.v.getFrameCount(clip, &count);

        var camera_raw: api.StringRaw = null;
        if (clip.v.getCameraType(clip, &camera_raw) == api.S_OK) {
            self.camera_type = strings.dupe(gpa, camera_raw, take_out_strings) catch return error.OutOfMemory;
        }

        var sidecar = false;
        _ = clip.v.getSidecarFileAttached(clip, &sidecar);

        var base_frame: u32 = 0;
        var drop = false;
        if (self.clip_ex) |ex| {
            _ = ex.v.queryTimecodeInfo(ex, &base_frame, &drop);
        }

        // clip-level metadata
        var clip_ctx: ClipMetaCtx = .{ .dec = self };
        var it_opt: ?*api.IBlackmagicRawMetadataIterator = null;
        if (clip.v.getMetadataIterator(clip, &it_opt) == api.S_OK) {
            if (it_opt) |it| {
                defer api.release(it);
                try iterateMetadata(self.lib, gpa, it, &clip_ctx, clipMetaHandler);
            }
        }
        const gamma_buf = clip_ctx.gamma_buf;
        const gamma_len = clip_ctx.gamma_len;
        const gamut_buf = clip_ctx.gamut_buf;
        const gamut_len = clip_ctx.gamut_len;

        // metadata-probe frame 0 for the sensor_rate rational
        var probe_meta: FrameMeta = .{};
        defer probe_meta.deinit(gpa);
        var sensor: ?[2]f64 = null;
        if (count > 0) {
            if (self.readFrameMetaOnly(0, &probe_meta)) {
                sensor = probe_meta.sensor_rate;
            } else |_| {}
        }

        // output dimensions under resolution scale
        var out_w = w;
        var out_h = h;
        if (opts.scale != .full) {
            if (api.queryInterface(self.clip, api.IBlackmagicRawClipResolutions, &api.iid_clip_resolutions)) |res| {
                defer api.release(res);
                var rw: u32 = 0;
                var rh: u32 = 0;
                if (res.v.getClosestResolutionForScale(res, opts.scale.toApi(), &rw, &rh) == api.S_OK and rw > 0 and rh > 0) {
                    out_w = rw;
                    out_h = rh;
                } else {
                    const div: u32 = @intFromEnum(opts.scale);
                    out_w = (w + div - 1) / div;
                    out_h = (h + div - 1) / div;
                }
            } else {
                const div: u32 = @intFromEnum(opts.scale);
                out_w = (w + div - 1) / div;
                out_h = (h + div - 1) / div;
            }
        }

        var audio_info: ?AudioInfo = null;
        if (self.audio_if) |au| {
            var bits: u32 = 0;
            var ch: u32 = 0;
            var sr: u32 = 0;
            var sc: u64 = 0;
            _ = au.v.getAudioBitDepth(au, &bits);
            _ = au.v.getAudioChannelCount(au, &ch);
            _ = au.v.getAudioSampleRate(au, &sr);
            _ = au.v.getAudioSampleCount(au, &sc);
            if (ch > 0 and sr > 0 and sc > 0 and bits > 0) {
                audio_info = .{ .bit_depth = bits, .channels = ch, .sample_rate = sr, .sample_count = sc };
            }
        }

        const eff_gamma: []const u8 = opts.clip_overrides.gamma orelse gamma_buf[0..gamma_len];
        const eff_gamut: []const u8 = opts.clip_overrides.gamut orelse gamut_buf[0..gamut_len];

        // automatic depth: 16-bit int, except scene-linear -> 32-bit float
        if (opts.depth == null) {
            self.depth = if (std.mem.eql(u8, eff_gamma, "Linear")) .f32_ else .u16_;
            self.resource_format = formats.resourceFormat(self.depth, self.alpha);
        }

        self.info = .{
            .width = w,
            .height = h,
            .out_width = out_w,
            .out_height = out_h,
            .frame_count = count,
            .frame_rate = rate,
            .fps = meta.rationalizeFps(rate, sensor),
            .sidecar_attached = sidecar,
            .base_frame_index = base_frame,
            .drop_frame_timecode = drop,
            .audio = audio_info,
            .cicp_transfer = meta.cicpTransferFromGamma(eff_gamma),
            .cicp_primaries = meta.cicpPrimariesFromGamut(eff_gamut),
        };
    }

    // --- Metal pipeline setup (macOS) ---

    fn setupMetal(self: *Decoder, cfg: *api.IBlackmagicRawConfiguration, err_detail: *?[]u8) OpenError!void {
        const gpa = self.gpa;
        if (!metal.available()) {
            err_detail.* = std.fmt.allocPrint(gpa, "Metal pipeline requested but the Objective-C/Metal runtime could not be loaded", .{}) catch null;
            return error.GpuUnavailable; // GPU runtime not loadable
        }
        // the SDK creates the Metal device for us (no manual MTLDevice)
        var iter_opt: ?*api.IBlackmagicRawPipelineDeviceIterator = null;
        if (self.factory.v.createPipelineDeviceIterator(self.factory, .metal, .none, &iter_opt) != api.S_OK or iter_opt == null) {
            err_detail.* = std.fmt.allocPrint(gpa, "the BlackmagicRaw Metal decoder is not available on this system", .{}) catch null;
            return error.PipelineUnsupported;
        }
        const iter = iter_opt.?;
        defer api.release(iter);

        var dev_opt: ?*api.IBlackmagicRawPipelineDevice = null;
        if (iter.v.createDevice(iter, &dev_opt) != api.S_OK or dev_opt == null) {
            return error.PipelineUnsupported;
        }
        self.metal_device = dev_opt.?;

        if (cfg.v.setFromDevice(cfg, self.metal_device.?) != api.S_OK) {
            return error.PipelineUnsupported;
        }
        // cache the native MTLCommandQueue for the readback path
        var pl: api.Pipeline = .metal;
        var ctx_out: ?*anyopaque = null;
        var queue_out: ?*anyopaque = null;
        if (self.metal_device.?.v.getPipeline(self.metal_device.?, &pl, &ctx_out, &queue_out) != api.S_OK or queue_out == null) {
            return error.PipelineUnsupported;
        }
        self.metal_queue = queue_out;
    }

    // --- host staging pool (GPU readback) ---
    // CUDA uses pinned host memory (faster DtoH); Metal copies into plain
    // host memory. Either way buffers are pooled since per-frame allocation
    // is wasteful.

    fn allocStaging(self: *Decoder, size: usize) ![]u8 {
        if (self.cuda_ctx) |*ctx| return ctx.allocPinned(size) catch error.OutOfMemory;
        return self.gpa.alloc(u8, size);
    }

    fn freeStaging(self: *Decoder, buf: []u8) void {
        if (self.cuda_ctx) |*ctx| ctx.freePinned(buf) else self.gpa.free(buf);
    }

    fn acquirePinned(self: *Decoder, size: u32) ![]u8 {
        self.pinned_mutex.lock();
        defer self.pinned_mutex.unlock();
        while (self.pinned_pool.pop()) |buf| {
            if (buf.len >= size) return buf;
            self.freeStaging(buf); // stale (smaller) buffer; drop it
        }
        return self.allocStaging(size);
    }

    fn releasePinned(self: *Decoder, buf: []u8) void {
        self.pinned_mutex.lock();
        defer self.pinned_mutex.unlock();
        self.pinned_pool.append(self.gpa, buf) catch {
            self.freeStaging(buf);
        };
    }

    pub fn close(self: *Decoder) void {
        const gpa = self.gpa;
        self.codec.flushJobs();
        if (self.clip_attrs) |a| api.release(a);
        if (self.audio_if) |a| api.release(a);
        if (self.clip_ex) |e| api.release(e);
        api.release(self.clip);
        api.release(self.codec);
        // drain the staging pool with the right free (pinned vs gpa) before
        // the CUDA context is destroyed
        if (self.cuda_ctx != null or self.metal_queue != null) {
            for (self.pinned_pool.items) |buf| self.freeStaging(buf);
            self.pinned_pool.deinit(gpa);
        }
        if (self.cuda_ctx) |*ctx| ctx.destroy();
        if (self.metal_device) |d| api.release(d);
        api.release(self.factory);
        loader.release(self.lib);
        if (self.camera_type.len > 0) gpa.free(self.camera_type);
        self.clip_props.deinit(gpa);
        self.clip_props_all.deinit(gpa);
        gpa.destroy(self);
    }

    fn submitRead(self: *Decoder, n: u64, req: *Request) !void {
        self.submit_mutex.lock();
        defer self.submit_mutex.unlock();
        var job_opt: ?*api.IBlackmagicRawJob = null;
        if (self.clip.v.createJobReadFrame(self.clip, n, &job_opt) != api.S_OK) return error.DecodeFailed;
        const job = job_opt orelse return error.DecodeFailed;
        _ = job.v.setUserData(job, req);
        if (job.v.submit(job) != api.S_OK) {
            api.release(job);
            return error.DecodeFailed;
        }
    }

    fn waitRequest(self: *Decoder, req: *Request) void {
        // 120s should cover 12K CPU decodes on slow machines; if it trips,
        // FlushJobs drains everything and guarantees our callbacks ran.
        req.event.timedWait(120 * std.time.ns_per_s) catch {
            self.codec.flushJobs();
            req.event.wait();
        };
    }

    fn readFrameMetaOnly(self: *Decoder, n: u64, out: *FrameMeta) DecodeError!void {
        var req = Request{
            .decoder = self,
            .gpa = self.gpa,
            .expected_index = n,
            .dest = null,
            .resource_format = self.resource_format,
            .scale = self.scale.toApi(),
            .collect_all_meta = false,
        };
        try self.submitRead(n, &req);
        self.waitRequest(&req);
        moveReqMeta(&req, out);
        if (req.oom) return error.OutOfMemory;
        if (req.hr != api.S_OK) return error.DecodeFailed;
    }

    /// Decode frame `n` into `dest` (plane pointers/strides prepared by the
    /// adapter). Frame metadata lands in `out`.
    pub fn decodeFrame(self: *Decoder, n: u64, dest: *const formats.Dest, out: *FrameMeta) DecodeError!void {
        var req = Request{
            .decoder = self,
            .gpa = self.gpa,
            .expected_index = n,
            .dest = dest,
            .resource_format = self.resource_format,
            .scale = self.scale.toApi(),
            .collect_all_meta = self.collect_all_meta,
        };
        try self.submitRead(n, &req);
        self.waitRequest(&req);
        moveReqMeta(&req, out);
        out.fail_stage = req.fail_stage;
        out.fail_hr = req.hr;
        if (req.oom) return error.OutOfMemory;
        if (req.hr != api.S_OK) {
            return if (req.hr == api.E_UNEXPECTED) error.DroppedFrame else error.DecodeFailed;
        }
    }

    /// List the valid values for a string-valued clip processing attribute
    /// (gamma/gamut). Caller owns the returned list.
    pub fn listClipAttribute(self: *Decoder, attr: api.ClipProcessingAttribute, gpa: std.mem.Allocator) ![][:0]u8 {
        var ca_opt: ?*api.IBlackmagicRawClipProcessingAttributes = self.clip_attrs;
        var owned_ca = false;
        if (ca_opt == null) {
            if (self.clip.v.cloneClipProcessingAttributes(self.clip, &ca_opt) != api.S_OK) return error.AttrFailed;
            owned_ca = true;
        }
        const ca = ca_opt orelse return error.AttrFailed;
        defer if (owned_ca) api.release(ca);

        var count: u32 = 0;
        var read_only = false;
        if (ca.v.getClipAttributeList(ca, attr, null, &count, &read_only) != api.S_OK) return error.AttrFailed;
        if (count == 0) return try gpa.alloc([:0]u8, 0);

        const variants = try gpa.alloc(api.Variant, count);
        defer gpa.free(variants);
        for (variants) |*v| {
            v.* = .empty;
            variant.variantInit(self.lib, v);
        }
        if (ca.v.getClipAttributeList(ca, attr, variants.ptr, &count, &read_only) != api.S_OK) return error.AttrFailed;
        defer for (variants) |*v| variant.variantClear(self.lib, v);

        var list: std.ArrayList([:0]u8) = .empty;
        errdefer {
            for (list.items) |s| gpa.free(s);
            list.deinit(gpa);
        }
        for (variants[0..count]) |*v| {
            var mv = try variant.toMeta(gpa, self.lib, v);
            defer mv.deinit(gpa);
            switch (mv) {
                .string => |s| try list.append(gpa, try gpa.dupeZ(u8, s)),
                .int => |i| {
                    const s = try std.fmt.allocPrintSentinel(gpa, "{d}", .{i}, 0);
                    try list.append(gpa, s);
                },
                else => {},
            }
        }
        return try list.toOwnedSlice(gpa);
    }

    /// Read packed interleaved PCM starting at `start_sample` (per-channel
    /// index). Returns samples/bytes read. Thread-safe.
    pub fn readAudio(self: *Decoder, start_sample: i64, buf: []u8, max_samples: u32) DecodeError!struct { samples: u32, bytes: u32 } {
        const au = self.audio_if orelse return error.DecodeFailed;
        self.audio_mutex.lock();
        defer self.audio_mutex.unlock();
        var samples_read: u32 = 0;
        var bytes_read: u32 = 0;
        const hr = au.v.getAudioSamples(au, start_sample, buf.ptr, @intCast(buf.len), max_samples, &samples_read, &bytes_read);
        if (hr != api.S_OK) return error.DecodeFailed;
        return .{ .samples = samples_read, .bytes = bytes_read };
    }
};

fn moveReqMeta(req: *Request, out: *FrameMeta) void {
    out.timecode = req.timecode;
    out.sensor_rate = req.sensor_rate;
    out.props = req.props;
    out.props_all = req.props_all;
    req.timecode = null;
    req.props = .{};
    req.props_all = .{};
}

test {
    _ = @import("braw/api.zig");
}
