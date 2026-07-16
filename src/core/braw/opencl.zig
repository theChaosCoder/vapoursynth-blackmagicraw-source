//! Minimal OpenCL binding, loaded lazily via dlopen so the plugin never
//! links against OpenCL and runs fine on machines without it — the same
//! pattern as cuda.zig. Only the entry points needed to (1) adopt the
//! cl_context/cl_command_queue the SDK's OpenCL pipeline device creates and
//! (2) read a decoded cl_mem buffer back to host memory.
//!
//! Readback never uses the SDK's own command queue: that queue carries the
//! decode kernels, and OpenCL in-order queues would serialize our DMA behind
//! them. Instead the decoder pools separate queues on the same context
//! (mirroring the CUDA non-blocking stream pool), so transfers overlap the
//! SDK's decode of the next frame.
//!
//! The SDK creates its output cl_mem with host access forbidden
//! (CL_MEM_HOST_WRITE_ONLY/HOST_NO_ACCESS — clEnqueueReadBuffer* fails with
//! CL_INVALID_OPERATION, observed on NVIDIA), so pixels reach the host via a
//! device-side clEnqueueCopyBuffer into our own CL_MEM_ALLOC_HOST_PTR
//! staging buffer plus a blocking map — the OpenCL equivalent of the Metal
//! blit-to-managed-staging pattern. Drivers back ALLOC_HOST_PTR with
//! page-locked memory, so the copy DMAs at full rate; the map is zero-copy.
//! The direct ReadBufferRect path is still attempted first (per frame, one
//! cheap failing call on restricted buffers) in case a driver/SDK combo
//! allows host reads — then planes land in the frame with no CPU copy.

const std = @import("std");
const builtin = @import("builtin");
const sync = @import("../sync.zig");

const is_windows = builtin.os.tag == .windows;
const is_macos = builtin.os.tag.isDarwin();
const lib_name = if (is_windows)
    "OpenCL.dll"
else if (is_macos)
    "/System/Library/Frameworks/OpenCL.framework/OpenCL"
else
    "libOpenCL.so.1";

pub const CL_SUCCESS: i32 = 0;
// Host access forbidden on the buffer (CL_MEM_HOST_WRITE_ONLY/NO_ACCESS):
// deterministic per buffer flags, so the caller can stop retrying.
const CL_INVALID_OPERATION: i32 = -59;

// clGetCommandQueueInfo params
const CL_QUEUE_CONTEXT: u32 = 0x1090;
const CL_QUEUE_DEVICE: u32 = 0x1091;

// cl_mem_flags / cl_map_flags (both cl_bitfield = u64)
const CL_MEM_READ_WRITE: u64 = 1 << 0;
const CL_MEM_ALLOC_HOST_PTR: u64 = 1 << 4;
const CL_MAP_READ: u64 = 1 << 0;

const CL_TRUE: u32 = 1;
const CL_FALSE: u32 = 0;

pub const Mem = *anyopaque; // cl_mem
pub const Queue = *anyopaque; // cl_command_queue
const ClContext = *anyopaque;
const ClDevice = *anyopaque;

/// One tightly-packed device plane -> one strided host plane. The device
/// plane starts `origin_y` rows into the buffer (rect addressing with
/// row pitch = width_bytes, so byte offset = origin_y * width_bytes).
pub const PlaneCopy = struct {
    dst: [*]u8,
    dst_pitch: usize,
    origin_y: usize,
    width_bytes: usize,
    height: usize,
};

const Fns = struct {
    getCommandQueueInfo: *const fn (Queue, u32, usize, ?*anyopaque, ?*usize) callconv(.c) i32,
    retainContext: *const fn (ClContext) callconv(.c) i32,
    releaseContext: *const fn (ClContext) callconv(.c) i32,
    createCommandQueue: *const fn (ClContext, ClDevice, u64, *i32) callconv(.c) ?Queue,
    releaseCommandQueue: *const fn (Queue) callconv(.c) i32,
    createBuffer: *const fn (ClContext, u64, usize, ?*anyopaque, *i32) callconv(.c) ?Mem,
    releaseMemObject: *const fn (Mem) callconv(.c) i32,
    enqueueMapBuffer: *const fn (Queue, Mem, u32, u64, usize, usize, u32, ?*const anyopaque, ?*?*anyopaque, *i32) callconv(.c) ?*anyopaque,
    enqueueUnmapMemObject: *const fn (Queue, Mem, *anyopaque, u32, ?*const anyopaque, ?*?*anyopaque) callconv(.c) i32,
    enqueueReadBufferRect: *const fn (Queue, Mem, u32, *const [3]usize, *const [3]usize, *const [3]usize, usize, usize, usize, usize, *anyopaque, u32, ?*const anyopaque, ?*?*anyopaque) callconv(.c) i32,
    enqueueCopyBuffer: *const fn (Queue, Mem, Mem, usize, usize, usize, u32, ?*const anyopaque, ?*?*anyopaque) callconv(.c) i32,
    finish: *const fn (Queue) callconv(.c) i32,
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
        .getCommandQueueInfo = sym(@FieldType(Fns, "getCommandQueueInfo"), h, "clGetCommandQueueInfo") orelse return,
        .retainContext = sym(@FieldType(Fns, "retainContext"), h, "clRetainContext") orelse return,
        .releaseContext = sym(@FieldType(Fns, "releaseContext"), h, "clReleaseContext") orelse return,
        .createCommandQueue = sym(@FieldType(Fns, "createCommandQueue"), h, "clCreateCommandQueue") orelse return,
        .releaseCommandQueue = sym(@FieldType(Fns, "releaseCommandQueue"), h, "clReleaseCommandQueue") orelse return,
        .createBuffer = sym(@FieldType(Fns, "createBuffer"), h, "clCreateBuffer") orelse return,
        .releaseMemObject = sym(@FieldType(Fns, "releaseMemObject"), h, "clReleaseMemObject") orelse return,
        .enqueueMapBuffer = sym(@FieldType(Fns, "enqueueMapBuffer"), h, "clEnqueueMapBuffer") orelse return,
        .enqueueUnmapMemObject = sym(@FieldType(Fns, "enqueueUnmapMemObject"), h, "clEnqueueUnmapMemObject") orelse return,
        .enqueueReadBufferRect = sym(@FieldType(Fns, "enqueueReadBufferRect"), h, "clEnqueueReadBufferRect") orelse return,
        .enqueueCopyBuffer = sym(@FieldType(Fns, "enqueueCopyBuffer"), h, "clEnqueueCopyBuffer") orelse return,
        .finish = sym(@FieldType(Fns, "finish"), h, "clFinish") orelse return,
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

pub fn available() bool {
    return get() != null;
}

/// HostAccessForbidden = CL_INVALID_OPERATION on a read/map: the buffer was
/// created host-inaccessible. Deterministic per buffer, so callers disable
/// the failing path instead of retrying every frame.
pub const Error = error{ OpenClUnavailable, ContextFailed, CopyFailed, HostAccessForbidden, OutOfMemory };

/// Print a failed CL call when BRAW_OCL_DEBUG is set (diagnosing driver
/// quirks in the field without a debug build). Same off-values as the
/// decoder's envFlag: 0/n/f.
fn debugErr(what: []const u8, rc: i32) void {
    const v = std.c.getenv("BRAW_OCL_DEBUG") orelse return;
    switch (v[0]) {
        0, '0', 'n', 'N', 'f', 'F' => return,
        else => {},
    }
    std.debug.print("[braw-opencl] {s} failed: {d}\n", .{ what, rc });
}

/// Map a failed read/map result to the Error that tells the caller whether
/// retrying can ever succeed.
fn copyError(rc: i32) Error {
    return if (rc == CL_INVALID_OPERATION) error.HostAccessForbidden else error.CopyFailed;
}

/// A pinned host-visible staging buffer (mapped per frame).
pub const Staging = struct {
    mem: Mem,
    len: usize,
};

/// The cl_context/cl_device the SDK's pipeline device runs on, adopted from
/// the SDK's command queue, plus a private service queue for map/unmap of
/// staging buffers. Readback queues are pooled by the decoder via
/// createQueue/destroyQueue.
pub const Context = struct {
    context: ClContext,
    device: ClDevice,
    service_queue: Queue,
    destroyed: bool = false,

    /// Adopt the context/device behind the SDK's cl_command_queue. Retains
    /// the context so it outlives our queues even if the SDK device is
    /// released first.
    pub fn fromSdkQueue(sdk_queue: Queue) Error!Context {
        const f = get() orelse return error.OpenClUnavailable;

        var ctx: ?ClContext = null;
        if (f.getCommandQueueInfo(sdk_queue, CL_QUEUE_CONTEXT, @sizeOf(?ClContext), @ptrCast(&ctx), null) != CL_SUCCESS or ctx == null)
            return error.ContextFailed;
        var dev: ?ClDevice = null;
        if (f.getCommandQueueInfo(sdk_queue, CL_QUEUE_DEVICE, @sizeOf(?ClDevice), @ptrCast(&dev), null) != CL_SUCCESS or dev == null)
            return error.ContextFailed;

        if (f.retainContext(ctx.?) != CL_SUCCESS) return error.ContextFailed;

        var self: Context = .{ .context = ctx.?, .device = dev.?, .service_queue = undefined };
        var err: i32 = CL_SUCCESS;
        self.service_queue = f.createCommandQueue(ctx.?, dev.?, 0, &err) orelse {
            debugErr("clCreateCommandQueue", err);
            _ = f.releaseContext(ctx.?);
            return error.ContextFailed;
        };
        return self;
    }

    pub fn destroy(self: *Context) void {
        if (self.destroyed) return;
        self.destroyed = true;
        const f = get() orelse return;
        _ = f.releaseCommandQueue(self.service_queue);
        _ = f.releaseContext(self.context);
    }

    /// Create an in-order queue on the adopted context for readback,
    /// separate from the SDK's decode queue so transfers overlap decode.
    /// Uses the OpenCL 1.x clCreateCommandQueue (deprecated in 2.0) on
    /// purpose: it exists in every ICD, and default in-order behavior is
    /// exactly what the copy paths need.
    pub fn createQueue(self: *const Context) Error!Queue {
        const f = get() orelse return error.OpenClUnavailable;
        var err: i32 = CL_SUCCESS;
        return f.createCommandQueue(self.context, self.device, 0, &err) orelse {
            debugErr("clCreateCommandQueue", err);
            return error.ContextFailed;
        };
    }

    pub fn destroyQueue(_: *const Context, q: Queue) void {
        const f = get() orelse return;
        _ = f.releaseCommandQueue(q);
    }

    /// Copy each tightly-packed device plane straight into its (strided)
    /// host destination plane via clEnqueueReadBufferRect — no staging
    /// buffer, no CPU plane copy. Reads are enqueued non-blocking and
    /// drained once. On failure the queue is drained before returning so no
    /// copy is still in flight when the caller runs its fallback.
    pub fn copyPlanesToHost(_: *const Context, queue: Queue, mem: Mem, planes: []const PlaneCopy) Error!void {
        const f = get() orelse return error.OpenClUnavailable;
        for (planes) |p| {
            const buffer_origin: [3]usize = .{ 0, p.origin_y, 0 };
            const host_origin: [3]usize = .{ 0, 0, 0 };
            const region: [3]usize = .{ p.width_bytes, p.height, 1 };
            const rc = f.enqueueReadBufferRect(
                queue,
                mem,
                CL_FALSE,
                &buffer_origin,
                &host_origin,
                &region,
                p.width_bytes, // buffer_row_pitch
                0, // buffer_slice_pitch
                p.dst_pitch, // host_row_pitch
                0, // host_slice_pitch
                p.dst,
                0,
                null,
                null,
            );
            if (rc != CL_SUCCESS) {
                debugErr("clEnqueueReadBufferRect", rc);
                _ = f.finish(queue); // drain queued copies before fallback
                return copyError(rc);
            }
        }
        // A failing clFinish means the queue/context died (device lost) —
        // same residual as the CUDA path's streamSync; nothing to drain.
        if (f.finish(queue) != CL_SUCCESS) return error.CopyFailed;
    }

    /// Allocate a pinned (CL_MEM_ALLOC_HOST_PTR) staging buffer. Mapped per
    /// frame via stageAndMap — the SDK's output buffer forbids host access,
    /// so pixels reach the host through a device-side copy into this buffer
    /// followed by a (zero-copy) map.
    pub fn createStaging(self: *const Context, size: usize) Error!Staging {
        const f = get() orelse return error.OpenClUnavailable;
        var err: i32 = CL_SUCCESS;
        const mem = f.createBuffer(self.context, CL_MEM_READ_WRITE | CL_MEM_ALLOC_HOST_PTR, size, null, &err) orelse
            return error.OutOfMemory;
        return .{ .mem = mem, .len = size };
    }

    pub fn destroyStaging(_: *const Context, s: Staging) void {
        const f = get() orelse return;
        _ = f.releaseMemObject(s.mem);
    }

    /// Device-side copy of the SDK's (host-inaccessible) buffer into `stg`,
    /// then blocking map for read. Returns the mapped pointer; pair with
    /// unmapStaging on the same queue.
    pub fn stageAndMap(_: *const Context, queue: Queue, src: Mem, stg: Staging, size: usize) Error![*]const u8 {
        const f = get() orelse return error.OpenClUnavailable;
        const rc = f.enqueueCopyBuffer(queue, src, stg.mem, 0, 0, size, 0, null, null);
        if (rc != CL_SUCCESS) {
            // rejected at enqueue: nothing in flight, no drain needed
            debugErr("clEnqueueCopyBuffer", rc);
            return error.CopyFailed;
        }
        var err: i32 = CL_SUCCESS;
        const ptr = f.enqueueMapBuffer(queue, stg.mem, CL_TRUE, CL_MAP_READ, 0, size, 0, null, null, &err) orelse {
            debugErr("clEnqueueMapBuffer", err);
            // the copy IS in flight: drain before the caller releases the
            // source image and pools the staging buffer/queue
            _ = f.finish(queue);
            return copyError(err);
        };
        return @ptrCast(ptr);
    }

    /// Unmap after the CPU copy and drain the queue, so the staging buffer
    /// carries no in-flight unmap when it returns to the pool (the next
    /// frame may borrow a different queue).
    pub fn unmapStaging(_: *const Context, queue: Queue, stg: Staging, ptr: [*]const u8) void {
        const f = get() orelse return;
        _ = f.enqueueUnmapMemObject(queue, stg.mem, @constCast(ptr), 0, null, null);
        _ = f.finish(queue);
    }
};
