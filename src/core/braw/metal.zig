//! Metal GPU readback via the Objective-C runtime, loaded lazily through
//! dlopen (libobjc) so the plugin needs no macOS SDK at build time and stays
//! cross-compilable from Linux — the same pattern as the CoreFoundation
//! binding in strings.zig.
//!
//! The SDK's Metal pipeline produces the decoded frame as a PRIVATE MTLBuffer
//! (GPU-only). To read it on the CPU we blit it into a managed staging buffer
//! and copy out its contents — mirroring the ProcessClipMetal SDK sample. On
//! Apple Silicon the blit is on-chip (unified memory), far cheaper than a
//! discrete GPU's PCIe readback, but still required.
//!
//! NOTE: implemented against the SDK sample and the Metal/objc ABI; it builds
//! for the macOS target but is UNTESTED on real hardware (no Mac available).

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
    sel_release: Sel,
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
        .sel_release = registerName("release"),
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
inline fn sendCopy(o: *const Objc, recv: Id, sel: Sel, src: Id, so: usize, dst: Id, do_: usize, sz: usize) void {
    const f: *const fn (Id, Sel, Id, usize, Id, usize, usize) callconv(.c) void = @ptrCast(o.msgSend);
    f(recv, sel, src, so, dst, do_, sz);
}

pub const Error = error{ MetalUnavailable, ReadbackFailed };

/// Blit a private MTLBuffer (`src_buffer`, from the SDK) into a managed
/// staging buffer via `command_queue` (also from the SDK) and copy its
/// `size` bytes to `dst`. Wrapped in an autorelease pool since the command
/// buffer / encoder are autoreleased.
pub fn readback(command_queue: *anyopaque, src_buffer: *anyopaque, dst: [*]u8, size: usize) Error!void {
    const o = get() orelse return error.MetalUnavailable;
    const pool = o.poolPush();
    defer o.poolPop(pool);

    const cq: Id = command_queue;
    const src: Id = src_buffer;

    const device = send0(o, cq, o.sel_device) orelse return error.ReadbackFailed;
    const staging = sendBuf(o, device, o.sel_newBuffer, size, MTLResourceStorageModeManaged) orelse
        return error.ReadbackFailed;
    defer send0v(o, staging, o.sel_release);

    const cb = send0(o, cq, o.sel_commandBuffer) orelse return error.ReadbackFailed;
    const blit = send0(o, cb, o.sel_blitEncoder) orelse return error.ReadbackFailed;
    sendCopy(o, blit, o.sel_copy, src, 0, staging, 0, size);
    sendSync(o, blit, o.sel_synchronize, staging);
    send0v(o, blit, o.sel_endEncoding);
    send0v(o, cb, o.sel_commit);
    send0v(o, cb, o.sel_waitUntil);

    const contents = send0(o, staging, o.sel_contents) orelse return error.ReadbackFailed;
    const cptr: [*]const u8 = @ptrCast(contents);
    @memcpy(dst[0..size], cptr[0..size]);
}
