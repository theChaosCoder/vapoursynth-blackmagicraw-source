//! Minimal CUDA Driver API binding, loaded lazily via dlopen so the plugin
//! never links against CUDA and runs fine on machines without it. Only the
//! handful of entry points needed to (1) create a context to hand to the
//! SDK's CUDA pipeline and (2) read a decoded GPU buffer back to pinned host
//! memory. Versioned symbol names (_v2) match the ABI the header remaps to.

const std = @import("std");
const builtin = @import("builtin");
const sync = @import("../sync.zig");

const is_windows = builtin.os.tag == .windows;
const lib_name = if (is_windows) "nvcuda.dll" else "libcuda.so.1";

pub const CUresult = c_int;
pub const CU_SUCCESS: CUresult = 0;
pub const CUdevice = c_int;
pub const CUcontext = ?*anyopaque;
pub const CUdeviceptr = usize;

// context creation flags (match the SDK sample)
const CU_CTX_SCHED_BLOCKING_SYNC: c_uint = 0x04;
const CU_CTX_MAP_HOST: c_uint = 0x08;

// CUmemorytype values used by cuMemcpy2D
const CU_MEMORYTYPE_HOST: c_uint = 0x01;
const CU_MEMORYTYPE_DEVICE: c_uint = 0x02;

// Opt the stream out of the implicit device-wide sync with the legacy default
// stream, so a DtoH copy on it overlaps the SDK's concurrent decode work.
const CU_STREAM_NON_BLOCKING: c_uint = 0x01;

/// A CUDA stream handle (opaque driver pointer). null == the default stream.
pub const Stream = ?*anyopaque;

/// Mirrors the driver's CUDA_MEMCPY2D struct (field order + padding must match
/// the C ABI exactly). Only the fields we use are set; the rest default to 0.
pub const Memcpy2D = extern struct {
    srcXInBytes: usize = 0,
    srcY: usize = 0,
    srcMemoryType: c_uint = 0,
    srcHost: ?*const anyopaque = null,
    srcDevice: CUdeviceptr = 0,
    srcArray: ?*anyopaque = null,
    srcPitch: usize = 0,
    dstXInBytes: usize = 0,
    dstY: usize = 0,
    dstMemoryType: c_uint = 0,
    dstHost: ?*anyopaque = null,
    dstDevice: CUdeviceptr = 0,
    dstArray: ?*anyopaque = null,
    dstPitch: usize = 0,
    WidthInBytes: usize = 0,
    Height: usize = 0,
};

/// One tightly-packed device plane -> one strided host plane.
pub const PlaneCopy = struct {
    dst: [*]u8,
    dst_pitch: usize,
    device_ptr: usize,
    width_bytes: usize,
    height: usize,
};

const Fns = struct {
    init: *const fn (c_uint) callconv(.c) CUresult,
    deviceGetCount: *const fn (*c_int) callconv(.c) CUresult,
    deviceGet: *const fn (*CUdevice, c_int) callconv(.c) CUresult,
    deviceGetName: *const fn ([*]u8, c_int, CUdevice) callconv(.c) CUresult,
    ctxCreate: *const fn (*CUcontext, c_uint, CUdevice) callconv(.c) CUresult,
    ctxDestroy: *const fn (CUcontext) callconv(.c) CUresult,
    ctxPushCurrent: *const fn (CUcontext) callconv(.c) CUresult,
    ctxPopCurrent: *const fn (*CUcontext) callconv(.c) CUresult,
    memcpyDtoH: *const fn (*anyopaque, CUdeviceptr, usize) callconv(.c) CUresult,
    memcpyDtoHAsync: *const fn (*anyopaque, CUdeviceptr, usize, Stream) callconv(.c) CUresult,
    memcpy2D: *const fn (*const Memcpy2D) callconv(.c) CUresult,
    memcpy2DAsync: *const fn (*const Memcpy2D, Stream) callconv(.c) CUresult,
    memAllocHost: *const fn (*?*anyopaque, usize) callconv(.c) CUresult,
    memFreeHost: *const fn (*anyopaque) callconv(.c) CUresult,
    hostRegister: *const fn (*anyopaque, usize, c_uint) callconv(.c) CUresult,
    hostUnregister: *const fn (*anyopaque) callconv(.c) CUresult,
    streamCreate: *const fn (*Stream, c_uint) callconv(.c) CUresult,
    streamDestroy: *const fn (Stream) callconv(.c) CUresult,
    streamSync: *const fn (Stream) callconv(.c) CUresult,
};

var fns: ?Fns = null;
var load_done: bool = false;
var load_mutex: sync.Mutex = .{};

fn sym(comptime T: type, h: *anyopaque, name: [:0]const u8) ?T {
    const p = if (is_windows) blk: {
        const win = struct {
            extern "kernel32" fn GetProcAddress(*anyopaque, [*:0]const u8) callconv(.winapi) ?*const anyopaque;
        };
        break :blk win.GetProcAddress(h, name.ptr) orelse return null;
    } else std.c.dlsym(h, name.ptr) orelse return null;
    return @ptrCast(@alignCast(p));
}

fn load() void {
    const h = if (is_windows) blk: {
        const win = struct {
            extern "kernel32" fn LoadLibraryA([*:0]const u8) callconv(.winapi) ?*anyopaque;
        };
        break :blk win.LoadLibraryA(lib_name) orelse return;
    } else std.c.dlopen(lib_name, .{ .NOW = true, .GLOBAL = false }) orelse return;

    fns = .{
        .init = sym(@FieldType(Fns, "init"), h, "cuInit") orelse return,
        .deviceGetCount = sym(@FieldType(Fns, "deviceGetCount"), h, "cuDeviceGetCount") orelse return,
        .deviceGet = sym(@FieldType(Fns, "deviceGet"), h, "cuDeviceGet") orelse return,
        .deviceGetName = sym(@FieldType(Fns, "deviceGetName"), h, "cuDeviceGetName") orelse return,
        .ctxCreate = sym(@FieldType(Fns, "ctxCreate"), h, "cuCtxCreate_v2") orelse return,
        .ctxDestroy = sym(@FieldType(Fns, "ctxDestroy"), h, "cuCtxDestroy_v2") orelse return,
        .ctxPushCurrent = sym(@FieldType(Fns, "ctxPushCurrent"), h, "cuCtxPushCurrent_v2") orelse return,
        .ctxPopCurrent = sym(@FieldType(Fns, "ctxPopCurrent"), h, "cuCtxPopCurrent_v2") orelse return,
        .memcpyDtoH = sym(@FieldType(Fns, "memcpyDtoH"), h, "cuMemcpyDtoH_v2") orelse return,
        .memcpyDtoHAsync = sym(@FieldType(Fns, "memcpyDtoHAsync"), h, "cuMemcpyDtoHAsync_v2") orelse return,
        .memcpy2D = sym(@FieldType(Fns, "memcpy2D"), h, "cuMemcpy2D_v2") orelse return,
        .memcpy2DAsync = sym(@FieldType(Fns, "memcpy2DAsync"), h, "cuMemcpy2DAsync_v2") orelse return,
        .memAllocHost = sym(@FieldType(Fns, "memAllocHost"), h, "cuMemAllocHost_v2") orelse return,
        .memFreeHost = sym(@FieldType(Fns, "memFreeHost"), h, "cuMemFreeHost") orelse return,
        .hostRegister = sym(@FieldType(Fns, "hostRegister"), h, "cuMemHostRegister_v2") orelse return,
        .hostUnregister = sym(@FieldType(Fns, "hostUnregister"), h, "cuMemHostUnregister") orelse return,
        .streamCreate = sym(@FieldType(Fns, "streamCreate"), h, "cuStreamCreate") orelse return,
        .streamDestroy = sym(@FieldType(Fns, "streamDestroy"), h, "cuStreamDestroy_v2") orelse return,
        .streamSync = sym(@FieldType(Fns, "streamSync"), h, "cuStreamSynchronize") orelse return,
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

pub const Error = error{ CudaUnavailable, NoDevice, ContextFailed, CopyFailed, OutOfMemory };

pub const Context = struct {
    handle: CUcontext,
    device_name: [256]u8 = [_]u8{0} ** 256,

    /// Create a context on device 0 and pop it off the current thread (the
    /// SDK re-pushes it on its own worker threads; we push explicitly for
    /// readback). Returns CudaUnavailable if the driver can't be loaded.
    pub fn create() Error!Context {
        const f = get() orelse return error.CudaUnavailable;
        if (f.init(0) != CU_SUCCESS) return error.CudaUnavailable;
        var count: c_int = 0;
        if (f.deviceGetCount(&count) != CU_SUCCESS or count == 0) return error.NoDevice;
        var dev: CUdevice = 0;
        if (f.deviceGet(&dev, 0) != CU_SUCCESS) return error.NoDevice;

        var self: Context = .{ .handle = null };
        _ = f.deviceGetName(&self.device_name, self.device_name.len - 1, dev);

        if (f.ctxCreate(&self.handle, CU_CTX_MAP_HOST | CU_CTX_SCHED_BLOCKING_SYNC, dev) != CU_SUCCESS)
            return error.ContextFailed;
        // don't leave the context current on the caller thread
        var popped: CUcontext = null;
        _ = f.ctxPopCurrent(&popped);
        return self;
    }

    pub fn destroy(self: *Context) void {
        if (self.handle == null) return;
        if (get()) |f| _ = f.ctxDestroy(self.handle);
        self.handle = null;
    }

    pub fn name(self: *const Context) []const u8 {
        const n = std.mem.indexOfScalar(u8, &self.device_name, 0) orelse self.device_name.len;
        return self.device_name[0..n];
    }

    /// Copy `size` bytes from a device pointer to host memory, pushing this
    /// context for the duration (callable from any thread).
    pub fn readback(self: *const Context, dst: [*]u8, device_ptr: usize, size: usize) Error!void {
        const f = get() orelse return error.CudaUnavailable;
        if (f.ctxPushCurrent(self.handle) != CU_SUCCESS) return error.CopyFailed;
        defer {
            var popped: CUcontext = null;
            _ = f.ctxPopCurrent(&popped);
        }
        if (f.memcpyDtoH(dst, device_ptr, size) != CU_SUCCESS) return error.CopyFailed;
    }

    /// Like readback, but issued on a (non-blocking) stream so the transfer
    /// skips the legacy default stream's device-wide barrier and overlaps the
    /// SDK's concurrent decode work. Waits for completion, so the stream is
    /// idle again when this returns. The destination must be page-locked for
    /// the copy to actually run asynchronously.
    pub fn readbackAsync(self: *const Context, dst: [*]u8, device_ptr: usize, size: usize, stream: Stream) Error!void {
        const f = get() orelse return error.CudaUnavailable;
        if (f.ctxPushCurrent(self.handle) != CU_SUCCESS) return error.CopyFailed;
        defer {
            var popped: CUcontext = null;
            _ = f.ctxPopCurrent(&popped);
        }
        if (f.memcpyDtoHAsync(dst, device_ptr, size, stream) != CU_SUCCESS) return error.CopyFailed;
        if (f.streamSync(stream) != CU_SUCCESS) return error.CopyFailed;
    }

    /// Copy each tightly-packed device plane straight into its (strided) host
    /// destination plane via cuMemcpy2D — skips the intermediate host staging
    /// buffer and the CPU plane copy entirely. Context pushed once for all
    /// planes. Callable from any thread.
    pub fn copyPlanesDtoH(self: *const Context, planes: []const PlaneCopy) Error!void {
        const f = get() orelse return error.CudaUnavailable;
        if (f.ctxPushCurrent(self.handle) != CU_SUCCESS) return error.CopyFailed;
        defer {
            var popped: CUcontext = null;
            _ = f.ctxPopCurrent(&popped);
        }
        for (planes) |p| {
            const c = Memcpy2D{
                .srcMemoryType = CU_MEMORYTYPE_DEVICE,
                .srcDevice = p.device_ptr,
                .srcPitch = p.width_bytes,
                .dstMemoryType = CU_MEMORYTYPE_HOST,
                .dstHost = p.dst,
                .dstPitch = p.dst_pitch,
                .WidthInBytes = p.width_bytes,
                .Height = p.height,
            };
            if (f.memcpy2D(&c) != CU_SUCCESS) return error.CopyFailed;
        }
    }

    /// Create a non-blocking stream. A DtoH copy issued on it does not insert
    /// the device-wide barrier that the legacy default stream would, so it
    /// overlaps the SDK's decode of the next frame. Context pushed for the call.
    pub fn createStream(self: *const Context) Error!Stream {
        const f = get() orelse return error.CudaUnavailable;
        if (f.ctxPushCurrent(self.handle) != CU_SUCCESS) return error.ContextFailed;
        defer {
            var popped: CUcontext = null;
            _ = f.ctxPopCurrent(&popped);
        }
        var s: Stream = null;
        if (f.streamCreate(&s, CU_STREAM_NON_BLOCKING) != CU_SUCCESS) return error.ContextFailed;
        return s;
    }

    pub fn destroyStream(self: *const Context, s: Stream) void {
        const f = get() orelse return;
        if (f.ctxPushCurrent(self.handle) != CU_SUCCESS) return;
        defer {
            var popped: CUcontext = null;
            _ = f.ctxPopCurrent(&popped);
        }
        _ = f.streamDestroy(s);
    }

    /// Like copyPlanesDtoH, but issues each plane copy asynchronously on a
    /// non-blocking stream and waits once at the end. With page-locked
    /// destinations the transfers run on the copy engine concurrently with the
    /// SDK's decode work instead of serializing on the default stream. On any
    /// failure the stream is drained before returning so no copy is still in
    /// flight into the destination when the caller runs its fallback.
    pub fn copyPlanesDtoHAsync(self: *const Context, planes: []const PlaneCopy, stream: Stream) Error!void {
        const f = get() orelse return error.CudaUnavailable;
        if (f.ctxPushCurrent(self.handle) != CU_SUCCESS) return error.CopyFailed;
        defer {
            var popped: CUcontext = null;
            _ = f.ctxPopCurrent(&popped);
        }
        for (planes) |p| {
            const c = Memcpy2D{
                .srcMemoryType = CU_MEMORYTYPE_DEVICE,
                .srcDevice = p.device_ptr,
                .srcPitch = p.width_bytes,
                .dstMemoryType = CU_MEMORYTYPE_HOST,
                .dstHost = p.dst,
                .dstPitch = p.dst_pitch,
                .WidthInBytes = p.width_bytes,
                .Height = p.height,
            };
            if (f.memcpy2DAsync(&c, stream) != CU_SUCCESS) {
                _ = f.streamSync(stream); // drain queued copies before fallback
                return error.CopyFailed;
            }
        }
        if (f.streamSync(stream) != CU_SUCCESS) return error.CopyFailed;
    }

    /// Page-lock a host region so DtoH into it runs at full (pinned) PCIe rate
    /// instead of the ~half-rate pageable path. Best-effort; context pushed.
    pub fn hostRegister(self: *const Context, ptr: *anyopaque, size: usize) Error!void {
        const f = get() orelse return error.CudaUnavailable;
        if (f.ctxPushCurrent(self.handle) != CU_SUCCESS) return error.CopyFailed;
        defer {
            var popped: CUcontext = null;
            _ = f.ctxPopCurrent(&popped);
        }
        if (f.hostRegister(ptr, size, 0) != CU_SUCCESS) return error.CopyFailed;
    }

    pub fn hostUnregister(self: *const Context, ptr: *anyopaque) void {
        const f = get() orelse return;
        if (f.ctxPushCurrent(self.handle) != CU_SUCCESS) return;
        defer {
            var popped: CUcontext = null;
            _ = f.ctxPopCurrent(&popped);
        }
        _ = f.hostUnregister(ptr);
    }

    /// Allocate pinned host memory (much faster device->host transfers).
    /// Requires this context to be current, so it is pushed here.
    pub fn allocPinned(self: *const Context, size: usize) Error![]u8 {
        const f = get() orelse return error.CudaUnavailable;
        if (f.ctxPushCurrent(self.handle) != CU_SUCCESS) return error.OutOfMemory;
        defer {
            var popped: CUcontext = null;
            _ = f.ctxPopCurrent(&popped);
        }
        var p: ?*anyopaque = null;
        if (f.memAllocHost(&p, size) != CU_SUCCESS) return error.OutOfMemory;
        const ptr: [*]u8 = @ptrCast(p.?);
        return ptr[0..size];
    }

    pub fn freePinned(_: *const Context, buf: []u8) void {
        if (get()) |f| _ = f.memFreeHost(buf.ptr);
    }
};

pub fn available() bool {
    return get() != null;
}
