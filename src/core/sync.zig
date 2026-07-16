//! Minimal blocking sync primitives on top of the platform's native APIs.
//!
//! Zig 0.16 moved std's blocking primitives into the std.Io interface; this
//! core runs inside host plugin worker threads where no Io context exists,
//! so we go straight to pthreads (Linux/macOS) and SRWLOCK/CONDITION_VARIABLE
//! (Windows) — the same primitives the SDK's own dispatch shim uses.

const std = @import("std");
const builtin = @import("builtin");

const is_windows = builtin.os.tag == .windows;

const win = if (is_windows) struct {
    pub const SRWLOCK = usize; // SRWLOCK_INIT == 0
    pub const CONDITION_VARIABLE = usize; // CONDITION_VARIABLE_INIT == 0
    pub extern "kernel32" fn AcquireSRWLockExclusive(*SRWLOCK) callconv(.winapi) void;
    pub extern "kernel32" fn ReleaseSRWLockExclusive(*SRWLOCK) callconv(.winapi) void;
    pub extern "kernel32" fn SleepConditionVariableSRW(*CONDITION_VARIABLE, *SRWLOCK, u32, u32) callconv(.winapi) i32;
    pub extern "kernel32" fn WakeAllConditionVariable(*CONDITION_VARIABLE) callconv(.winapi) void;
} else struct {};

pub const Mutex = struct {
    impl: Impl = init_impl,

    const Impl = if (is_windows) win.SRWLOCK else std.c.pthread_mutex_t;
    const init_impl: Impl = if (is_windows) 0 else .{};

    pub fn lock(self: *Mutex) void {
        if (is_windows) {
            win.AcquireSRWLockExclusive(&self.impl);
        } else {
            _ = std.c.pthread_mutex_lock(&self.impl);
        }
    }

    pub fn unlock(self: *Mutex) void {
        if (is_windows) {
            win.ReleaseSRWLockExclusive(&self.impl);
        } else {
            _ = std.c.pthread_mutex_unlock(&self.impl);
        }
    }
};

/// One-shot event: a waiter blocks until `set` is called (possibly from a
/// foreign, non-Zig thread — the SDK's decoder workers).
pub const Event = struct {
    mutex: Mutex = .{},
    cond: Cond = cond_init,
    flag: bool = false,

    const Cond = if (is_windows) win.CONDITION_VARIABLE else std.c.pthread_cond_t;
    const cond_init: Cond = if (is_windows) 0 else .{};

    pub fn set(self: *Event) void {
        self.mutex.lock();
        self.flag = true;
        if (is_windows) {
            win.WakeAllConditionVariable(&self.cond);
        } else {
            _ = std.c.pthread_cond_broadcast(&self.cond);
        }
        self.mutex.unlock();
    }

    pub fn wait(self: *Event) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (!self.flag) {
            if (is_windows) {
                _ = win.SleepConditionVariableSRW(&self.cond, &self.mutex.impl, 0xFFFFFFFF, 0);
            } else {
                _ = std.c.pthread_cond_wait(&self.cond, &self.mutex.impl);
            }
        }
    }

    pub fn timedWait(self: *Event, timeout_ns: u64) error{Timeout}!void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (is_windows) {
            var remaining_ms: u64 = timeout_ns / std.time.ns_per_ms;
            while (!self.flag) {
                if (remaining_ms == 0) return error.Timeout;
                const chunk: u32 = @intCast(@min(remaining_ms, 0xFFFF_FFF0));
                if (win.SleepConditionVariableSRW(&self.cond, &self.mutex.impl, chunk, 0) == 0) {
                    // WAIT timed out (or failed) — treat as elapsed chunk
                    remaining_ms -= chunk;
                } // else: woken, loop re-checks flag
            }
            return;
        }

        var now: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.REALTIME, &now);
        const deadline_ns = @as(u64, @intCast(now.sec)) * std.time.ns_per_s +
            @as(u64, @intCast(now.nsec)) + timeout_ns;
        var abs: std.c.timespec = .{
            .sec = @intCast(deadline_ns / std.time.ns_per_s),
            .nsec = @intCast(deadline_ns % std.time.ns_per_s),
        };
        while (!self.flag) {
            const rc = std.c.pthread_cond_timedwait(&self.cond, &self.mutex.impl, &abs);
            if (rc == .TIMEDOUT) {
                if (self.flag) return;
                return error.Timeout;
            }
        }
    }
};

test "event set before wait" {
    var ev: Event = .{};
    ev.set();
    ev.wait(); // must not block
    try ev.timedWait(1); // already set
}

test "event timedWait times out" {
    var ev: Event = .{};
    try std.testing.expectError(error.Timeout, ev.timedWait(10 * std.time.ns_per_ms));
}

test "event cross-thread signaling" {
    var ev: Event = .{};
    const t = try std.Thread.spawn(.{}, struct {
        fn run(e: *Event) void {
            // brief portable delay so the waiter is very likely parked
            // before the set — an Event that is never signaled is the one
            // sleep primitive this module already has on every platform
            var pause: Event = .{};
            pause.timedWait(5 * std.time.ns_per_ms) catch {};
            e.set();
        }
    }.run, .{&ev});
    defer t.join();
    try ev.timedWait(5 * std.time.ns_per_s);
}

test "mutex basic" {
    var m: Mutex = .{};
    m.lock();
    m.unlock();
}
