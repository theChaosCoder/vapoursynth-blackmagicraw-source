//! Hand-written binding to the Blackmagic RAW SDK 5.1 C++ COM-style API.
//!
//! Ground truth: vendor/braw-sdk/Linux/BlackmagicRawAPI.h (Linux/macOS) and
//! vendor/braw-sdk/Win/BlackmagicRawAPI.idl (Windows). Interfaces are
//! IUnknown-derived pure-virtual classes; an interface pointer is a pointer
//! to a struct whose first member is the vtable pointer. Vtable slot order
//! is the declaration order in those files and is identical on all three
//! platforms for the public methods. The trailing virtual-destructor slots
//! that exist on Linux/macOS (Itanium ABI, 2 slots) come AFTER all public
//! methods, so they are irrelevant for interfaces we only call — they only
//! matter for the one interface we implement (IBlackmagicRawCallback, see
//! decoder.zig).
//!
//! Platform differences (see PLAN.md):
//!   strings   Linux `const char*` / macOS `CFStringRef` / Windows `BSTR`
//!   Variant   own 16-byte struct (Unix) / OLE VARIANT, 24 bytes (Windows)
//!   REFIID    16-byte struct BY VALUE (Unix) / pointer to GUID (Windows)
//!   ULONG     c_ulong (Unix) / u32 (Windows)

const std = @import("std");
const builtin = @import("builtin");

pub const is_windows = builtin.os.tag == .windows;
pub const is_macos = builtin.os.tag.isDarwin();

// ---------------------------------------------------------------------------
// COM base types
// ---------------------------------------------------------------------------

pub const HRESULT = i32;
pub const S_OK: HRESULT = 0;
pub const S_FALSE: HRESULT = 1;
/// Same value on all platforms; the SDK uses it for dropped frames.
pub const E_UNEXPECTED: HRESULT = @bitCast(@as(u32, 0x8000FFFF));
pub const E_NOTIMPL: HRESULT = if (is_windows)
    @bitCast(@as(u32, 0x80004001))
else
    @bitCast(@as(u32, 0x80000001));
pub const E_FAIL: HRESULT = if (is_windows)
    @bitCast(@as(u32, 0x80004005))
else
    @bitCast(@as(u32, 0x80000008));

pub inline fn succeeded(hr: HRESULT) bool {
    return hr >= 0;
}

pub const ULONG = if (is_windows) u32 else c_ulong;

/// `string` in the SDK docs: const char* / CFStringRef / BSTR.
pub const StringRaw = if (is_windows)
    ?[*:0]u16 // BSTR (length-prefixed, but NUL-terminated for reading)
else if (is_macos)
    ?*anyopaque // CFStringRef
else
    ?[*:0]const u8;

/// GUID with the platform's in-memory layout.
/// Unix: raw bytes exactly as written in the header initializers.
/// Windows: {u32,u16,u16,[8]u8} with the leading fields little-endian.
pub const Guid = if (is_windows) extern struct {
    d1: u32,
    d2: u16,
    d3: u16,
    d4: [8]u8,
} else extern struct {
    bytes: [16]u8,
};

/// QueryInterface parameter: by-value on Unix, pointer on Windows.
pub const RefIid = if (is_windows) *const Guid else Guid;

pub inline fn refIid(g: *const Guid) RefIid {
    return if (is_windows) g else g.*;
}

/// Parse a canonical GUID string into the platform representation.
pub fn guid(comptime s: *const [36]u8) Guid {
    @setEvalBranchQuota(10_000);
    comptime var bytes: [16]u8 = undefined;
    comptime {
        var i: usize = 0; // index into s
        var o: usize = 0; // index into bytes
        while (o < 16) : (o += 1) {
            if (s[i] == '-') i += 1;
            bytes[o] = std.fmt.parseInt(u8, s[i .. i + 2], 16) catch
                @compileError("invalid GUID: " ++ s);
            i += 2;
        }
    }
    if (is_windows) {
        return .{
            .d1 = (@as(u32, bytes[0]) << 24) | (@as(u32, bytes[1]) << 16) |
                (@as(u32, bytes[2]) << 8) | bytes[3],
            .d2 = (@as(u16, bytes[4]) << 8) | bytes[5],
            .d3 = (@as(u16, bytes[6]) << 8) | bytes[7],
            .d4 = bytes[8..16].*,
        };
    }
    return .{ .bytes = bytes };
}

// ---------------------------------------------------------------------------
// Interface IDs (from BlackmagicRawAPI.h)
// ---------------------------------------------------------------------------

pub const iid_factory = guid("78DEEB84-98C9-434A-B7E5-7AACC2988399");
pub const iid_codec = guid("558ABA39-B344-4E9B-A484-116CF2A4B5C6");
pub const iid_configuration = guid("267E9866-FB40-4BFB-8BF8-96EA3F7DA36E");
pub const iid_metadata_iterator = guid("F85AE78D-5DC2-40BC-8C1D-D0D805523ADA");
pub const iid_clip_processing_attributes = guid("1F53C8AE-2295-4C8E-B17F-5931F4F146AC");
pub const iid_frame_processing_attributes = guid("5F7C5C0F-7138-445A-9D0D-6111B6409D17");
pub const iid_processed_image = guid("D87A0F72-A883-42BB-8488-0089411C5035");
pub const iid_job = guid("34C05ACF-7118-45EA-8B71-887E0515395D");
pub const iid_read_job_hints = guid("1069F99C-A4E2-415A-91C4-5E0CE0C6AF77");
pub const iid_callback = guid("E9F98FAC-33DB-4A65-BB94-8A82B027AED0");
pub const iid_clip_audio = guid("76D4ACED-E0D6-45BB-B547-56B7435B2A1D");
pub const iid_frame = guid("A500B253-1808-4EF2-8692-D23C692404EA");
pub const iid_frame_ex = guid("F8C6C374-D7FB-4BD3-AD0B-C533464FF450");
pub const iid_clip = guid("A2910203-787B-4BF2-A374-B1A459E2D351");
pub const iid_clip_ex = guid("D260C7D0-93BD-4D68-B600-93B4CAB7F870");
pub const iid_clip_resolutions = guid("C63C290F-525B-4EBE-AB56-87B010CACE19");

// ---------------------------------------------------------------------------
// Enums (FourCC-valued unless noted)
// ---------------------------------------------------------------------------

pub const ResourceType = enum(u32) {
    buffer_cpu = 0x63707562, // 'cpub'
    buffer_metal = 0x6D657462,
    buffer_cuda = 0x63756462,
    buffer_opencl = 0x6F636C62,
    _,
};

pub const ResourceFormat = enum(u32) {
    rgba_u8 = 0x72676261, // 'rgba'
    bgra_u8 = 0x62677261, // 'bgra'
    rgb_u16 = 0x3136696C, // '16il'
    rgba_u16 = 0x3136616C, // '16al'
    bgra_u16 = 0x31366C61, // '16la'
    rgb_u16_planar = 0x3136706C, // '16pl'
    rgb_f32 = 0x66333273, // 'f32s'
    rgba_f32 = 0x6633326C, // 'f32l'
    bgra_f32 = 0x66333261, // 'f32a'
    rgb_f32_planar = 0x66333270, // 'f32p'
    rgb_f16 = 0x66313673, // 'f16s'
    rgba_f16 = 0x6631366C, // 'f16l'
    bgra_f16 = 0x66313661, // 'f16a'
    rgb_f16_planar = 0x66313670, // 'f16p'
    _,
};

pub const Pipeline = enum(u32) {
    cpu = 0x63707562, // 'cpub'
    cuda = 0x63756461,
    metal = 0x6D65746C,
    opencl = 0x6F70636C,
    _,
};

pub const Interop = enum(u32) {
    none = 0x6E6F6E65, // 'none'
    opengl = 0x6F70676C, // 'opgl'
    _,
};

pub const AudioFormat = enum(u32) {
    pcm_little_endian = 0x70636D6C, // 'pcml'
    _,
};

pub const ResolutionScale = enum(u32) {
    full = 0x66756C6C, // 'full'
    half = 0x68616C66, // 'half'
    quarter = 0x71727472, // 'qrtr'
    eighth = 0x65697468, // 'eith'
    _,
};

pub const ClipProcessingAttribute = enum(u32) {
    color_science_gen = 0x6373676E, // 'csgn' u16
    gamma = 0x67616D61, // 'gama' string
    gamut = 0x67616D74, // 'gamt' string
    tone_curve_contrast = 0x74636F6E, // float
    tone_curve_saturation = 0x74736174,
    tone_curve_midpoint = 0x746D6964,
    tone_curve_highlights = 0x74686968,
    tone_curve_shadows = 0x74736861,
    tone_curve_video_black_level = 0x7476626C, // u16
    tone_curve_black_level = 0x74626C6B, // float
    tone_curve_white_level = 0x74776974, // float
    highlight_recovery = 0x686C7279, // 'hlry' u16
    analog_gain_is_constant = 0x61676963, // u16
    analog_gain = 0x6761696E, // float
    post_3dlut_mode = 0x6C75746D, // string
    embedded_3dlut_name = 0x656D6C6E,
    embedded_3dlut_title = 0x656D6C74,
    embedded_3dlut_size = 0x656D6C73,
    embedded_3dlut_data = 0x656D6C64,
    sidecar_3dlut_name = 0x73636C6E,
    sidecar_3dlut_title = 0x73636C74,
    sidecar_3dlut_size = 0x73636C73,
    sidecar_3dlut_data = 0x73636C64,
    gamut_compression_enable = 0x67616365, // 'gace' u16
    _,
};

pub const FrameProcessingAttribute = enum(u32) {
    white_balance_kelvin = 0x77626B76, // 'wbkv' u32
    white_balance_tint = 0x7762746E, // 'wbtn' s16
    exposure = 0x6578706F, // 'expo' float
    iso = 0x6669736F, // 'fiso' u32
    analog_gain = 0x61677066, // 'agpf' float (read-only)
    _,
};

// ---------------------------------------------------------------------------
// Variant / SafeArray
// ---------------------------------------------------------------------------

/// BlackmagicRawVariantType values. On Windows these are OLE VT_* codes,
/// on Unix a small sequential enum — normalize through `VariantTag`.
pub const vt_unix = struct {
    pub const empty: u32 = 0;
    pub const u8_: u32 = 1;
    pub const s16: u32 = 2;
    pub const u16_: u32 = 3;
    pub const s32: u32 = 4;
    pub const u32_: u32 = 5;
    pub const f32_: u32 = 6;
    pub const string: u32 = 7;
    pub const safe_array: u32 = 8;
    pub const f64_: u32 = 9;
};

pub const vt_win = struct {
    pub const empty: u16 = 0; // VT_EMPTY
    pub const s16: u16 = 2; // VT_I2
    pub const s32: u16 = 3; // VT_I4
    pub const f32_: u16 = 4; // VT_R4
    pub const f64_: u16 = 5; // VT_R8
    pub const string: u16 = 8; // VT_BSTR
    pub const u8_: u16 = 17; // VT_UI1
    pub const u16_: u16 = 18; // VT_UI2
    pub const u32_: u16 = 19; // VT_UI4
    pub const safe_array: u16 = 27; // VT_SAFEARRAY
    pub const vt_array_flag: u16 = 0x2000; // VT_ARRAY | VT_*
};

pub const SafeArrayBound = if (is_windows) extern struct {
    cElements: u32,
    lLbound: i32,
} else extern struct {
    lLbound: u32,
    cElements: u32,
};

pub const SafeArray = if (is_windows) extern struct {
    cDims: u16,
    fFeatures: u16,
    cbElements: u32,
    cLocks: u32,
    pvData: ?[*]u8,
    rgsabound: [1]SafeArrayBound,
} else extern struct {
    variantType: u32,
    cDims: u32,
    data: ?[*]u8,
    bounds: SafeArrayBound,
};

pub const Variant = if (is_windows) extern struct {
    vt: u16,
    r1: u16 = 0,
    r2: u16 = 0,
    r3: u16 = 0,
    u: extern union {
        iVal: i16,
        uiVal: u16,
        intVal: i32,
        uintVal: u32,
        fltVal: f32,
        dblVal: f64,
        bstrVal: StringRaw,
        parray: ?*SafeArray,
        record: extern struct { pv: ?*anyopaque, pi: ?*anyopaque },
    },

    pub const empty: @This() = .{ .vt = vt_win.empty, .u = .{ .dblVal = 0 } };
} else extern struct {
    vt: u32,
    u: extern union {
        iVal: i16,
        uiVal: u16,
        intVal: i32,
        uintVal: u32,
        fltVal: f32,
        dblVal: f64,
        bstrVal: StringRaw,
        parray: ?*SafeArray,
    },

    pub const empty: @This() = .{ .vt = vt_unix.empty, .u = .{ .dblVal = 0 } };
};

// Typed Variant constructors: the vt code differs per platform (OLE VT_*
// vs the SDK's own enumeration), so pairing tag and union member lives
// here exactly once.
pub fn variantU16(x: u16) Variant {
    var v: Variant = .empty;
    v.vt = if (is_windows) vt_win.u16_ else vt_unix.u16_;
    v.u = .{ .uiVal = x };
    return v;
}

pub fn variantU32(x: u32) Variant {
    var v: Variant = .empty;
    v.vt = if (is_windows) vt_win.u32_ else vt_unix.u32_;
    v.u = .{ .uintVal = x };
    return v;
}

pub fn variantI16(x: i16) Variant {
    var v: Variant = .empty;
    v.vt = if (is_windows) vt_win.s16 else vt_unix.s16;
    v.u = .{ .iVal = x };
    return v;
}

pub fn variantF32(x: f32) Variant {
    var v: Variant = .empty;
    v.vt = if (is_windows) vt_win.f32_ else vt_unix.f32_;
    v.u = .{ .fltVal = x };
    return v;
}

pub fn variantString(raw: StringRaw) Variant {
    var v: Variant = .empty;
    v.vt = if (is_windows) vt_win.string else vt_unix.string;
    v.u = .{ .bstrVal = raw };
    return v;
}

comptime {
    if (is_windows) {
        std.debug.assert(@sizeOf(Variant) == 24);
    } else {
        std.debug.assert(@sizeOf(Variant) == 16);
        std.debug.assert(@sizeOf(SafeArray) == 24);
    }
    std.debug.assert(@sizeOf(Guid) == 16);
}

test "variant constructors pair tag and member" {
    const v = variantU32(6870);
    try std.testing.expectEqual(@as(u32, 6870), v.u.uintVal);
    const expect_vt: u32 = if (is_windows) vt_win.u32_ else vt_unix.u32_;
    try std.testing.expectEqual(expect_vt, @as(u32, v.vt));
    const t = variantI16(-20);
    try std.testing.expectEqual(@as(i16, -20), t.u.iVal);
}

// ---------------------------------------------------------------------------
// Interfaces. Every vtable starts with the IUnknown trio; method slots are
// declared in exact header/IDL order. Methods we never call are typed as
// `UnusedSlot` (still a pointer-sized slot).
// ---------------------------------------------------------------------------

pub const UnusedSlot = *const fn () callconv(.c) void;

fn UnknownVt() type {
    return extern struct {
        qi: *const fn (*anyopaque, RefIid, *?*anyopaque) callconv(.c) HRESULT,
        addRef: *const fn (*anyopaque) callconv(.c) ULONG,
        release: *const fn (*anyopaque) callconv(.c) ULONG,
    };
}

/// Generic QueryInterface helper: works on any binding type below.
pub fn queryInterface(obj: anytype, comptime T: type, iid_ptr: *const Guid) ?*T {
    var out: ?*anyopaque = null;
    if (obj.v.unknown.qi(@ptrCast(obj), refIid(iid_ptr), &out) != S_OK) return null;
    return @ptrCast(@alignCast(out orelse return null));
}

pub fn release(obj: anytype) void {
    _ = obj.v.unknown.release(@ptrCast(obj));
}

pub const IBlackmagicRawFactory = extern struct {
    v: *const VTable,
    const Self = @This();
    pub const VTable = extern struct {
        unknown: UnknownVt(),
        createCodec: *const fn (*Self, *?*IBlackmagicRaw) callconv(.c) HRESULT,
        createPipelineIterator: UnusedSlot,
        createPipelineDeviceIterator: *const fn (*Self, Pipeline, Interop, *?*IBlackmagicRawPipelineDeviceIterator) callconv(.c) HRESULT,
        createClipGeometry: UnusedSlot,
    };

    pub fn createCodec(self: *Self) ?*IBlackmagicRaw {
        var out: ?*IBlackmagicRaw = null;
        if (self.v.createCodec(self, &out) != S_OK) return null;
        return out;
    }
};

pub const IBlackmagicRawPipelineDeviceIterator = extern struct {
    v: *const VTable,
    const Self = @This();
    pub const VTable = extern struct {
        unknown: UnknownVt(),
        next: *const fn (*Self) callconv(.c) HRESULT,
        getPipeline: *const fn (*Self, *Pipeline) callconv(.c) HRESULT,
        getInterop: *const fn (*Self, *Interop) callconv(.c) HRESULT,
        createDevice: *const fn (*Self, *?*IBlackmagicRawPipelineDevice) callconv(.c) HRESULT,
    };
};

pub const IBlackmagicRawPipelineDevice = extern struct {
    v: *const VTable,
    const Self = @This();
    pub const VTable = extern struct {
        unknown: UnknownVt(),
        setBestInstructionSet: UnusedSlot,
        setInstructionSet: UnusedSlot,
        getInstructionSet: UnusedSlot,
        getIndex: UnusedSlot,
        getName: *const fn (*Self, *StringRaw) callconv(.c) HRESULT,
        getInterop: UnusedSlot,
        getPipeline: *const fn (*Self, *Pipeline, *?*anyopaque, *?*anyopaque) callconv(.c) HRESULT,
        getPipelineName: UnusedSlot,
        getOpenGLInteropHelper: UnusedSlot,
        getSupportedResourceFormats: UnusedSlot,
        getMaximumTextureSize: UnusedSlot,
    };
};

pub const IBlackmagicRaw = extern struct {
    v: *const VTable,
    const Self = @This();
    pub const VTable = extern struct {
        unknown: UnknownVt(),
        openClip: *const fn (*Self, StringRaw, *?*IBlackmagicRawClip) callconv(.c) HRESULT,
        openClipWithGeometry: UnusedSlot,
        setCallback: *const fn (*Self, *anyopaque) callconv(.c) HRESULT,
        preparePipeline: UnusedSlot,
        preparePipelineForDevice: UnusedSlot,
        flushJobs: *const fn (*Self) callconv(.c) HRESULT,
    };

    pub fn openClip(self: *Self, file_name: StringRaw) !*IBlackmagicRawClip {
        var out: ?*IBlackmagicRawClip = null;
        const hr = self.v.openClip(self, file_name, &out);
        if (hr != S_OK) return error.OpenClipFailed;
        return out orelse error.OpenClipFailed;
    }

    pub fn setCallback(self: *Self, cb: *anyopaque) HRESULT {
        return self.v.setCallback(self, cb);
    }

    pub fn flushJobs(self: *Self) void {
        _ = self.v.flushJobs(self);
    }
};

pub const IBlackmagicRawConfiguration = extern struct {
    v: *const VTable,
    const Self = @This();
    pub const VTable = extern struct {
        unknown: UnknownVt(),
        setPipeline: *const fn (*Self, Pipeline, ?*anyopaque, ?*anyopaque) callconv(.c) HRESULT,
        getPipeline: UnusedSlot,
        isPipelineSupported: *const fn (*Self, Pipeline, *bool) callconv(.c) HRESULT,
        setCPUThreads: *const fn (*Self, u32) callconv(.c) HRESULT,
        getCPUThreads: *const fn (*Self, *u32) callconv(.c) HRESULT,
        getMaxCPUThreadCount: *const fn (*Self, *u32) callconv(.c) HRESULT,
        setWriteMetadataPerFrame: UnusedSlot,
        getWriteMetadataPerFrame: UnusedSlot,
        setFromDevice: *const fn (*Self, *IBlackmagicRawPipelineDevice) callconv(.c) HRESULT,
        getVersion: *const fn (*Self, *StringRaw) callconv(.c) HRESULT,
        getCameraSupportVersion: *const fn (*Self, *StringRaw) callconv(.c) HRESULT,
    };
};

pub const IBlackmagicRawMetadataIterator = extern struct {
    v: *const VTable,
    const Self = @This();
    pub const VTable = extern struct {
        unknown: UnknownVt(),
        next: *const fn (*Self) callconv(.c) HRESULT,
        getKey: *const fn (*Self, *StringRaw) callconv(.c) HRESULT,
        getData: *const fn (*Self, *Variant) callconv(.c) HRESULT,
    };
};

pub const IBlackmagicRawClipProcessingAttributes = extern struct {
    v: *const VTable,
    const Self = @This();
    pub const VTable = extern struct {
        unknown: UnknownVt(),
        getClipAttribute: *const fn (*Self, ClipProcessingAttribute, *Variant) callconv(.c) HRESULT,
        setClipAttribute: *const fn (*Self, ClipProcessingAttribute, *Variant) callconv(.c) HRESULT,
        getClipAttributeRange: UnusedSlot,
        getClipAttributeList: *const fn (*Self, ClipProcessingAttribute, ?[*]Variant, ?*u32, *bool) callconv(.c) HRESULT,
        getISOList: *const fn (*Self, ?[*]u32, ?*u32, *bool) callconv(.c) HRESULT,
        getPost3DLUT: UnusedSlot,
    };
};

pub const IBlackmagicRawFrameProcessingAttributes = extern struct {
    v: *const VTable,
    const Self = @This();
    pub const VTable = extern struct {
        unknown: UnknownVt(),
        getFrameAttribute: *const fn (*Self, FrameProcessingAttribute, *Variant) callconv(.c) HRESULT,
        setFrameAttribute: *const fn (*Self, FrameProcessingAttribute, *Variant) callconv(.c) HRESULT,
        getFrameAttributeRange: UnusedSlot,
        getFrameAttributeList: *const fn (*Self, FrameProcessingAttribute, ?[*]Variant, ?*u32, *bool) callconv(.c) HRESULT,
        getISOList: *const fn (*Self, ?[*]u32, ?*u32, *bool) callconv(.c) HRESULT,
    };
};

pub const IBlackmagicRawProcessedImage = extern struct {
    v: *const VTable,
    const Self = @This();
    pub const VTable = extern struct {
        unknown: UnknownVt(),
        getWidth: *const fn (*Self, *u32) callconv(.c) HRESULT,
        getHeight: *const fn (*Self, *u32) callconv(.c) HRESULT,
        getResource: *const fn (*Self, *?*anyopaque) callconv(.c) HRESULT,
        getResourceType: *const fn (*Self, *ResourceType) callconv(.c) HRESULT,
        getResourceFormat: *const fn (*Self, *ResourceFormat) callconv(.c) HRESULT,
        getResourceSizeBytes: *const fn (*Self, *u32) callconv(.c) HRESULT,
        getResourceContextAndCommandQueue: UnusedSlot,
    };
};

pub const IBlackmagicRawJob = extern struct {
    v: *const VTable,
    const Self = @This();
    pub const VTable = extern struct {
        unknown: UnknownVt(),
        submit: *const fn (*Self) callconv(.c) HRESULT,
        abort: *const fn (*Self) callconv(.c) HRESULT,
        setUserData: *const fn (*Self, ?*anyopaque) callconv(.c) HRESULT,
        getUserData: *const fn (*Self, *?*anyopaque) callconv(.c) HRESULT,
    };

    pub fn userData(self: *Self, comptime T: type) ?*T {
        var out: ?*anyopaque = null;
        if (self.v.getUserData(self, &out) != S_OK) return null;
        return @ptrCast(@alignCast(out orelse return null));
    }
};

pub const IBlackmagicRawClipAudio = extern struct {
    v: *const VTable,
    const Self = @This();
    pub const VTable = extern struct {
        unknown: UnknownVt(),
        getAudioFormat: *const fn (*Self, *AudioFormat) callconv(.c) HRESULT,
        getAudioBitDepth: *const fn (*Self, *u32) callconv(.c) HRESULT,
        getAudioChannelCount: *const fn (*Self, *u32) callconv(.c) HRESULT,
        getAudioSampleRate: *const fn (*Self, *u32) callconv(.c) HRESULT,
        getAudioSampleCount: *const fn (*Self, *u64) callconv(.c) HRESULT,
        getAudioSamples: *const fn (*Self, i64, ?*anyopaque, u32, u32, ?*u32, ?*u32) callconv(.c) HRESULT,
    };
};

pub const IBlackmagicRawFrame = extern struct {
    v: *const VTable,
    const Self = @This();
    pub const VTable = extern struct {
        unknown: UnknownVt(),
        getFrameIndex: *const fn (*Self, *u64) callconv(.c) HRESULT,
        getTimecode: *const fn (*Self, *StringRaw) callconv(.c) HRESULT,
        getMetadataIterator: *const fn (*Self, *?*IBlackmagicRawMetadataIterator) callconv(.c) HRESULT,
        getMetadata: *const fn (*Self, StringRaw, *Variant) callconv(.c) HRESULT,
        setMetadata: UnusedSlot,
        cloneFrameProcessingAttributes: *const fn (*Self, *?*IBlackmagicRawFrameProcessingAttributes) callconv(.c) HRESULT,
        setResolutionScale: *const fn (*Self, ResolutionScale) callconv(.c) HRESULT,
        getResolutionScale: *const fn (*Self, *ResolutionScale) callconv(.c) HRESULT,
        setResourceFormat: *const fn (*Self, ResourceFormat) callconv(.c) HRESULT,
        getResourceFormat: *const fn (*Self, *ResourceFormat) callconv(.c) HRESULT,
        getSensorRate: *const fn (*Self, *f32) callconv(.c) HRESULT,
        createJobDecodeAndProcessFrame: *const fn (*Self, ?*IBlackmagicRawClipProcessingAttributes, ?*IBlackmagicRawFrameProcessingAttributes, *?*IBlackmagicRawJob) callconv(.c) HRESULT,
    };
};

pub const IBlackmagicRawFrameEx = extern struct {
    v: *const VTable,
    const Self = @This();
    pub const VTable = extern struct {
        unknown: UnknownVt(),
        getBitStreamSizeBytes: *const fn (*Self, *u32) callconv(.c) HRESULT,
        getProcessedImageResolution: *const fn (*Self, *u32, *u32) callconv(.c) HRESULT,
    };
};

pub const IBlackmagicRawClip = extern struct {
    v: *const VTable,
    const Self = @This();
    pub const VTable = extern struct {
        unknown: UnknownVt(),
        getWidth: *const fn (*Self, *u32) callconv(.c) HRESULT,
        getHeight: *const fn (*Self, *u32) callconv(.c) HRESULT,
        getFrameRate: *const fn (*Self, *f32) callconv(.c) HRESULT,
        getFrameCount: *const fn (*Self, *u64) callconv(.c) HRESULT,
        getTimecodeForFrame: *const fn (*Self, u64, *StringRaw) callconv(.c) HRESULT,
        getMetadataIterator: *const fn (*Self, *?*IBlackmagicRawMetadataIterator) callconv(.c) HRESULT,
        getMetadata: *const fn (*Self, StringRaw, *Variant) callconv(.c) HRESULT,
        setMetadata: UnusedSlot,
        getCameraType: *const fn (*Self, *StringRaw) callconv(.c) HRESULT,
        cloneClipProcessingAttributes: *const fn (*Self, *?*IBlackmagicRawClipProcessingAttributes) callconv(.c) HRESULT,
        getMulticardFileCount: *const fn (*Self, *u32) callconv(.c) HRESULT,
        isMulticardFilePresent: *const fn (*Self, u32, *bool) callconv(.c) HRESULT,
        getSidecarFileAttached: *const fn (*Self, *bool) callconv(.c) HRESULT,
        saveSidecarFile: UnusedSlot,
        reloadSidecarFile: UnusedSlot,
        createJobReadFrame: *const fn (*Self, u64, *?*IBlackmagicRawJob) callconv(.c) HRESULT,
        createJobTrim: UnusedSlot,
        cloneWithGeometry: UnusedSlot,
    };
};

pub const IBlackmagicRawClipEx = extern struct {
    v: *const VTable,
    const Self = @This();
    pub const VTable = extern struct {
        unknown: UnknownVt(),
        getMaxBitStreamSizeBytes: *const fn (*Self, *u32) callconv(.c) HRESULT,
        getBitStreamSizeBytes: *const fn (*Self, u64, *u32) callconv(.c) HRESULT,
        createJobReadFrame: UnusedSlot,
        queryTimecodeInfo: *const fn (*Self, *u32, *bool) callconv(.c) HRESULT,
    };
};

pub const IBlackmagicRawClipResolutions = extern struct {
    v: *const VTable,
    const Self = @This();
    pub const VTable = extern struct {
        unknown: UnknownVt(),
        getResolutionCount: *const fn (*Self, *u32) callconv(.c) HRESULT,
        getResolution: *const fn (*Self, u32, *u32, *u32) callconv(.c) HRESULT,
        getRecordedResolution: *const fn (*Self, u32, *u32, *u32) callconv(.c) HRESULT,
        getClosestResolutionForScale: *const fn (*Self, ResolutionScale, *u32, *u32) callconv(.c) HRESULT,
        getClosestScaleForResolution: *const fn (*Self, u32, u32, *ResolutionScale) callconv(.c) HRESULT,
    };
};

// ---------------------------------------------------------------------------
// IBlackmagicRawCallback — the one interface WE implement (see decoder.zig).
// Vtable layout: IUnknown trio, the 8 callback methods in declaration order,
// then on Linux/macOS two trailing virtual-destructor slots (Itanium ABI:
// complete + deleting destructor). The SDK releases the callback via
// Release() and never virtual-destructs it, but the slots must exist.
// ---------------------------------------------------------------------------

pub const CallbackMethods = extern struct {
    readComplete: *const fn (*anyopaque, *IBlackmagicRawJob, HRESULT, ?*IBlackmagicRawFrame) callconv(.c) void,
    decodeComplete: *const fn (*anyopaque, *IBlackmagicRawJob, HRESULT) callconv(.c) void,
    processComplete: *const fn (*anyopaque, *IBlackmagicRawJob, HRESULT, ?*IBlackmagicRawProcessedImage) callconv(.c) void,
    trimProgress: *const fn (*anyopaque, *IBlackmagicRawJob, f32) callconv(.c) void,
    trimComplete: *const fn (*anyopaque, *IBlackmagicRawJob, HRESULT) callconv(.c) void,
    sidecarMetadataParseWarning: *const fn (*anyopaque, *IBlackmagicRawClip, StringRaw, u32, StringRaw) callconv(.c) void,
    sidecarMetadataParseError: *const fn (*anyopaque, *IBlackmagicRawClip, StringRaw, u32, StringRaw) callconv(.c) void,
    preparePipelineComplete: *const fn (*anyopaque, ?*anyopaque, HRESULT) callconv(.c) void,
};

pub const CallbackVTable = if (is_windows) extern struct {
    unknown: UnknownVt(),
    methods: CallbackMethods,
} else extern struct {
    unknown: UnknownVt(),
    methods: CallbackMethods,
    dtor_complete: *const fn (*anyopaque) callconv(.c) void,
    dtor_deleting: *const fn (*anyopaque) callconv(.c) void,
};

comptime {
    const ptr = @sizeOf(usize);
    const want: usize = if (is_windows) 11 else 13;
    std.debug.assert(@sizeOf(CallbackVTable) == want * ptr);
    // Interface structs must be exactly one vtable pointer.
    std.debug.assert(@sizeOf(IBlackmagicRawClip) == ptr);
}

test "guid parsing matches header byte layout" {
    const g = guid("558ABA39-B344-4E9B-A484-116CF2A4B5C6");
    if (is_windows) {
        try std.testing.expectEqual(@as(u32, 0x558ABA39), g.d1);
        try std.testing.expectEqual(@as(u16, 0xB344), g.d2);
        try std.testing.expectEqual(@as(u16, 0x4E9B), g.d3);
        try std.testing.expectEqualSlices(u8, &.{ 0xA4, 0x84, 0x11, 0x6C, 0xF2, 0xA4, 0xB5, 0xC6 }, &g.d4);
    } else {
        try std.testing.expectEqualSlices(u8, &.{
            0x55, 0x8A, 0xBA, 0x39, 0xB3, 0x44, 0x4E, 0x9B,
            0xA4, 0x84, 0x11, 0x6C, 0xF2, 0xA4, 0xB5, 0xC6,
        }, &g.bytes);
    }
}

test "fourcc enum values" {
    try std.testing.expectEqual(@as(u32, 0x66756C6C), @intFromEnum(ResolutionScale.full));
    try std.testing.expectEqual(@as(u32, 0x3136706C), @intFromEnum(ResourceFormat.rgb_u16_planar));
}
