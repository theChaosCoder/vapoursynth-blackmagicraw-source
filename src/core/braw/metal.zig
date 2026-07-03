//! Metal GPU readback via the Objective-C runtime, loaded lazily through
//! dlopen (libobjc) so the plugin needs no macOS SDK at build time and stays
//! cross-compilable from Linux — the same pattern as the CoreFoundation
//! binding in strings.zig.
//!
//! The SDK's Metal pipeline produces the decoded frame as a PRIVATE MTLBuffer
//! (GPU-only). To read it on the CPU we blit it into a managed staging buffer
//! (pooled by the decoder — a 4.6K frame is 68 MB, allocating one per frame
//! is expensive) and read its contents pointer directly — mirroring the
//! ProcessClipMetal SDK sample. The blit is committed on the SDK callback
//! thread (beginBlit) but awaited on the requesting thread (finishBlit), so
//! the SDK's serial callback dispatch never blocks on the GPU. On Apple
//! Silicon the blit is on-chip (unified memory), far cheaper than a discrete
//! GPU's PCIe readback, but still required.
//!
//! Verified on Apple Silicon (M1 Pro, macOS 26): device iteration with
//! interop `none`, managed staging + synchronizeResource, and the
//! objc_msgSend signatures below all behave as the SDK sample implies;
//! decoded frames match the CPU pipeline to within GPU/CPU rounding.

const std = @import("std");
const builtin = @import("builtin");
const sync = @import("../sync.zig");

const is_macos = builtin.os.tag.isDarwin();

// MTLResourceStorageModeManaged = MTLStorageModeManaged(1) << shift(4)
const MTLResourceStorageModeManaged: usize = 1 << 4;

const Id = ?*anyopaque;
const Sel = ?*anyopaque;

/// generic function-pointer type for objc_msgSend; cast to the concrete
/// signature per call site (all fn pointers share alignment, so the casts
/// don't trip the alignment checker like a data pointer would)
const MsgSend = *const fn () callconv(.c) void;

const Objc = struct {
    getClass: *const fn ([*:0]const u8) callconv(.c) Id,
    registerName: *const fn ([*:0]const u8) callconv(.c) Sel,
    msgSend: MsgSend, // objc_msgSend, cast per call site
    poolPush: *const fn () callconv(.c) Id,
    poolPop: *const fn (Id) callconv(.c) void,

    // cached selectors
    sel_device: Sel,
    sel_newBuffer: Sel,
    sel_commandBuffer: Sel,
    sel_blitEncoder: Sel,
    sel_copy: Sel,
    sel_synchronize: Sel,
    sel_endEncoding: Sel,
    sel_commit: Sel,
    sel_waitUntil: Sel,
    sel_contents: Sel,
    sel_retain: Sel,
    sel_release: Sel,
    sel_status: Sel,
};

var objc: ?Objc = null;
var load_done: bool = false;
var load_mutex: sync.Mutex = .{};

fn sym(comptime T: type, h: *anyopaque, name: [:0]const u8) ?T {
    const p = std.c.dlsym(h, name.ptr) orelse return null;
    return @ptrCast(@alignCast(p));
}

fn load() void {
    if (!is_macos) return;
    const h = std.c.dlopen("/usr/lib/libobjc.A.dylib", .{ .NOW = true, .GLOBAL = true }) orelse return;
    const getClass = sym(@FieldType(Objc, "getClass"), h, "objc_getClass") orelse return;
    const registerName = sym(@FieldType(Objc, "registerName"), h, "sel_registerName") orelse return;
    const msgSend = sym(MsgSend, h, "objc_msgSend") orelse return;
    const poolPush = sym(@FieldType(Objc, "poolPush"), h, "objc_autoreleasePoolPush") orelse return;
    const poolPop = sym(@FieldType(Objc, "poolPop"), h, "objc_autoreleasePoolPop") orelse return;

    objc = .{
        .getClass = getClass,
        .registerName = registerName,
        .msgSend = msgSend,
        .poolPush = poolPush,
        .poolPop = poolPop,
        .sel_device = registerName("device"),
        .sel_newBuffer = registerName("newBufferWithLength:options:"),
        .sel_commandBuffer = registerName("commandBuffer"),
        .sel_blitEncoder = registerName("blitCommandEncoder"),
        .sel_copy = registerName("copyFromBuffer:sourceOffset:toBuffer:destinationOffset:size:"),
        .sel_synchronize = registerName("synchronizeResource:"),
        .sel_endEncoding = registerName("endEncoding"),
        .sel_commit = registerName("commit"),
        .sel_waitUntil = registerName("waitUntilCompleted"),
        .sel_contents = registerName("contents"),
        .sel_retain = registerName("retain"),
        .sel_release = registerName("release"),
        .sel_status = registerName("status"),
    };
}

fn get() ?*const Objc {
    if (!@atomicLoad(bool, &load_done, .acquire)) {
        load_mutex.lock();
        defer load_mutex.unlock();
        if (!load_done) {
            load();
            @atomicStore(bool, &load_done, true, .release);
        }
    }
    return if (objc) |*o| o else null;
}

pub fn available() bool {
    return is_macos and get() != null;
}

// objc_msgSend cast helpers (Id receiver, Sel selector, then typed args)
inline fn send0(o: *const Objc, recv: Id, sel: Sel) Id {
    const f: *const fn (Id, Sel) callconv(.c) Id = @ptrCast(o.msgSend);
    return f(recv, sel);
}
inline fn send0v(o: *const Objc, recv: Id, sel: Sel) void {
    const f: *const fn (Id, Sel) callconv(.c) void = @ptrCast(o.msgSend);
    f(recv, sel);
}
inline fn sendBuf(o: *const Objc, recv: Id, sel: Sel, len: usize, opts: usize) Id {
    const f: *const fn (Id, Sel, usize, usize) callconv(.c) Id = @ptrCast(o.msgSend);
    return f(recv, sel, len, opts);
}
inline fn sendSync(o: *const Objc, recv: Id, sel: Sel, res: Id) void {
    const f: *const fn (Id, Sel, Id) callconv(.c) void = @ptrCast(o.msgSend);
    f(recv, sel, res);
}
inline fn sendUsize(o: *const Objc, recv: Id, sel: Sel) usize {
    const f: *const fn (Id, Sel) callconv(.c) usize = @ptrCast(o.msgSend);
    return f(recv, sel);
}
inline fn sendCopy(o: *const Objc, recv: Id, sel: Sel, src: Id, so: usize, dst: Id, do_: usize, sz: usize) void {
    const f: *const fn (Id, Sel, Id, usize, Id, usize, usize) callconv(.c) void = @ptrCast(o.msgSend);
    f(recv, sel, src, so, dst, do_, sz);
}

pub const Error = error{ MetalUnavailable, ReadbackFailed };

/// A reusable managed staging buffer (retained MTLBuffer + its CPU-visible
/// contents pointer, which is stable for the buffer's lifetime).
pub const Staging = struct {
    buffer: *anyopaque,
    contents: [*]const u8,
    len: usize,
};

/// Allocate a managed staging buffer of `size` bytes on `command_queue`'s
/// device. The result is retained; pair with `destroyStaging`.
pub fn createStaging(command_queue: *anyopaque, size: usize) Error!Staging {
    const o = get() orelse return error.MetalUnavailable;
    const pool = o.poolPush();
    defer o.poolPop(pool);

    const device = send0(o, command_queue, o.sel_device) orelse return error.ReadbackFailed;
    const buf = sendBuf(o, device, o.sel_newBuffer, size, MTLResourceStorageModeManaged) orelse
        return error.ReadbackFailed;
    const contents = send0(o, buf, o.sel_contents) orelse {
        send0v(o, buf, o.sel_release);
        return error.ReadbackFailed;
    };
    return .{ .buffer = buf, .contents = @ptrCast(contents), .len = size };
}

pub fn destroyStaging(s: Staging) void {
    const o = get() orelse return;
    send0v(o, s.buffer, o.sel_release);
}

/// Encode and commit a blit of `size` bytes from a private MTLBuffer
/// (`src_buffer`, from the SDK) into `staging` — WITHOUT waiting, so the
/// SDK's serial callback thread isn't blocked on the GPU. Returns the
/// retained command buffer; hand it to `finishBlit` (any thread) to wait,
/// after which `staging.contents` holds the pixels. Wrapped in an
/// autorelease pool since the command buffer / encoder are autoreleased.
pub fn beginBlit(command_queue: *anyopaque, src_buffer: *anyopaque, staging: Staging, size: usize) Error!*anyopaque {
    const o = get() orelse return error.MetalUnavailable;
    const pool = o.poolPush();
    defer o.poolPop(pool);

    const cb = send0(o, command_queue, o.sel_commandBuffer) orelse return error.ReadbackFailed;
    const blit = send0(o, cb, o.sel_blitEncoder) orelse return error.ReadbackFailed;
    sendCopy(o, blit, o.sel_copy, src_buffer, 0, staging.buffer, 0, size);
    sendSync(o, blit, o.sel_synchronize, staging.buffer);
    send0v(o, blit, o.sel_endEncoding);
    _ = send0(o, cb, o.sel_retain); // survive the autorelease pool
    send0v(o, cb, o.sel_commit);
    return cb;
}

/// Wait for a `beginBlit` command buffer to finish and release it.
pub fn finishBlit(cmdbuf: *anyopaque) Error!void {
    const o = get() orelse return error.MetalUnavailable;
    send0v(o, cmdbuf, o.sel_waitUntil);
    const status = sendUsize(o, cmdbuf, o.sel_status);
    send0v(o, cmdbuf, o.sel_release);
    if (status == 5) return error.ReadbackFailed; // MTLCommandBufferStatusError
}
