//! braw-probe — development/verification CLI for the brawsource core.
//!
//! Usage:
//!   braw-probe [options] <clip.braw>
//!     --libpath <path>   BlackmagicRawAPI library file or directory
//!     --frame <n>        decode frame n (default: no decode)
//!     --out <file.ppm>   write decoded frame as PPM (u8/u16) or raw floats
//!     --depth <d>        u8 | u16 | f16 | f32 (default u16)
//!     --alpha            request alpha
//!     --scale <s>        1 | 2 | 4 | 8 (default 1)
//!     --all-meta         dump every metadata key
//!     --audio <file.raw> dump first ~2s of packed PCM to file

const std = @import("std");
const core = @import("core");

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("error: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

const is_windows = @import("builtin").os.tag == .windows;
const win32 = if (is_windows) struct {
    pub extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
} else struct {};

fn nowMs() i64 {
    if (is_windows) return @intCast(win32.GetTickCount64());
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
}

const Args = struct {
    clip: ?[]const u8 = null,
    libpath: ?[]const u8 = null,
    frame: ?u64 = null,
    out: ?[]const u8 = null,
    depth: core.formats.Depth = .u16_,
    alpha: bool = false,
    scale: core.decoder.Scale = .full,
    all_meta: bool = false,
    list_attrs: bool = false,
    pipeline: core.decoder.Pipeline = .cpu,
    bench: u32 = 0,
    audio_out: ?[]const u8 = null,
};

fn nextValue(it: *std.process.Args.Iterator) []const u8 {
    return it.next() orelse fatal("missing value for option", .{});
}

fn parseArgs(args: std.process.Args, gpa: std.mem.Allocator) Args {
    var it = std.process.Args.Iterator.initAllocator(args, gpa) catch fatal("arg parsing failed", .{});
    _ = it.next(); // argv[0]
    var a: Args = .{};
    // retained values are duped: on Windows the iterator's buffer is reused
    const keep = struct {
        fn f(g: std.mem.Allocator, s: []const u8) []const u8 {
            return g.dupe(u8, s) catch fatal("oom", .{});
        }
    }.f;
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--libpath")) {
            a.libpath = keep(gpa, nextValue(&it));
        } else if (std.mem.eql(u8, arg, "--frame")) {
            a.frame = std.fmt.parseInt(u64, nextValue(&it), 10) catch fatal("bad --frame", .{});
        } else if (std.mem.eql(u8, arg, "--out")) {
            a.out = keep(gpa, nextValue(&it));
        } else if (std.mem.eql(u8, arg, "--depth")) {
            a.depth = core.formats.Depth.parse(nextValue(&it)) orelse fatal("bad --depth", .{});
        } else if (std.mem.eql(u8, arg, "--alpha")) {
            a.alpha = true;
        } else if (std.mem.eql(u8, arg, "--scale")) {
            const v = std.fmt.parseInt(i64, nextValue(&it), 10) catch fatal("bad --scale", .{});
            a.scale = core.decoder.Scale.fromInt(v) orelse fatal("scale must be 1|2|4|8", .{});
        } else if (std.mem.eql(u8, arg, "--all-meta")) {
            a.all_meta = true;
        } else if (std.mem.eql(u8, arg, "--list-attrs")) {
            a.list_attrs = true;
        } else if (std.mem.eql(u8, arg, "--pipeline")) {
            a.pipeline = core.decoder.Pipeline.parse(nextValue(&it)) orelse fatal("pipeline must be cpu|cuda", .{});
        } else if (std.mem.eql(u8, arg, "--bench")) {
            a.bench = std.fmt.parseInt(u32, nextValue(&it), 10) catch fatal("bad --bench", .{});
        } else if (std.mem.eql(u8, arg, "--audio")) {
            a.audio_out = keep(gpa, nextValue(&it));
        } else if (std.mem.startsWith(u8, arg, "--")) {
            fatal("unknown option {s}", .{arg});
        } else {
            a.clip = keep(gpa, arg);
        }
    }
    return a;
}

fn printProps(w: *std.Io.Writer, label: []const u8, list: *const core.meta.PropList) !void {
    if (list.items.items.len == 0) return;
    try w.print("{s}:\n", .{label});
    for (list.items.items) |p| {
        try w.print("  {s} = {f}\n", .{ p.name, p.value });
    }
}

/// Decode `--bench` frames single-threaded (each decodeFrame is synchronous),
/// cycling through the clip, into a reused destination. Reports fps for the
/// selected pipeline. Includes a small warmup that is excluded from timing.
fn runBench(gpa: std.mem.Allocator, w: *std.Io.Writer, dec: *core.Decoder, a: Args) !void {
    const info = dec.info;
    const width = info.out_width;
    const height = info.out_height;
    const bps = a.depth.bytesPerSample();
    const stride: usize = @as(usize, width) * bps;
    var bufs: [3][]u8 = undefined;
    for (0..3) |i| bufs[i] = try gpa.alloc(u8, stride * height);
    defer for (0..3) |i| gpa.free(bufs[i]);
    const dest: core.formats.Dest = .{
        .width = width,
        .height = height,
        .planes = .{ bufs[0].ptr, bufs[1].ptr, bufs[2].ptr, null },
        .strides = .{ stride, stride, stride, stride },
    };

    const fc = info.frame_count;
    var fm: core.FrameMeta = .{};
    defer fm.deinit(gpa);
    // warmup
    var wi: u64 = 0;
    while (wi < @min(fc, 4)) : (wi += 1) {
        dec.decodeFrame(wi, &dest, &fm) catch {};
    }

    const t0 = nowMs();
    var done: u32 = 0;
    var i: u32 = 0;
    while (i < a.bench) : (i += 1) {
        const n = @as(u64, i) % fc;
        dec.decodeFrame(n, &dest, &fm) catch |e| fatal("bench decode failed: {t} ({s})", .{ e, fm.fail_stage });
        done += 1;
    }
    const t1 = nowMs();
    const sec = @as(f64, @floatFromInt(t1 - t0)) / 1000.0;
    try w.print("\nbench [{t}]: {d} frames in {d:.3}s = {d:.2} fps ({d}x{d}, {t})\n", .{
        a.pipeline, done, sec, @as(f64, @floatFromInt(done)) / sec, width, height, a.depth,
    });
    if (dec.cuda_ctx) |*ctx| try w.print("  GPU: {s}\n", .{ctx.name()});
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const a = parseArgs(init.minimal.args, gpa);
    const clip_path = a.clip orelse fatal("usage: braw-probe [options] <clip.braw>", .{});

    var stdout_buf: [4096]u8 = undefined;
    var stdout_w = std.Io.File.stdout().writer(io, &stdout_buf);
    const w = &stdout_w.interface;

    var err_detail: ?[]u8 = null;
    const dec = core.Decoder.open(gpa, clip_path, .{
        .libpath = a.libpath,
        .pipeline = a.pipeline,
        .depth = a.depth,
        .alpha = a.alpha,
        .scale = a.scale,
        .collect_all_meta = a.all_meta,
    }, &err_detail) catch |e| {
        if (err_detail) |d| {
            std.debug.print("{s}\n", .{d});
        }
        fatal("open failed: {t}", .{e});
    };
    defer dec.close();

    const info = dec.info;
    try w.print("clip:          {s}\n", .{clip_path});
    try w.print("camera:        {s}\n", .{dec.camera_type});
    try w.print("dimensions:    {d}x{d}", .{ info.width, info.height });
    if (info.out_width != info.width) {
        try w.print("  (scaled: {d}x{d})", .{ info.out_width, info.out_height });
    }
    try w.print("\nframes:        {d}\n", .{info.frame_count});
    try w.print("rate (float):  {d}\n", .{info.frame_rate});
    try w.print("fps rational:  {d}/{d}\n", .{ info.fps.num, info.fps.den });
    try w.print("sidecar:       {}\n", .{info.sidecar_attached});
    try w.print("timecode base: {d} (drop frame: {})\n", .{ info.base_frame_index, info.drop_frame_timecode });
    if (info.audio) |au| {
        try w.print("audio:         {d} ch, {d} Hz, {d} bit, {d} samples\n", .{ au.channels, au.sample_rate, au.bit_depth, au.sample_count });
    } else {
        try w.print("audio:         none\n", .{});
    }
    try printProps(w, "clip props", &dec.clip_props);
    if (a.all_meta) try printProps(w, "clip metadata (all)", &dec.clip_props_all);

    if (a.list_attrs) {
        const attrs = [_]struct { name: []const u8, attr: core.api.ClipProcessingAttribute }{
            .{ .name = "gamma", .attr = .gamma },
            .{ .name = "gamut", .attr = .gamut },
            .{ .name = "colorscience", .attr = .color_science_gen },
        };
        for (attrs) |entry| {
            const values = dec.listClipAttribute(entry.attr, gpa) catch continue;
            defer {
                for (values) |s| gpa.free(s);
                gpa.free(values);
            }
            try w.print("valid {s} values:\n", .{entry.name});
            for (values) |v| try w.print("  {s}\n", .{v});
        }
    }
    try w.flush();

    if (a.bench > 0) {
        try runBench(gpa, w, dec, a);
        try w.flush();
    }

    if (a.frame) |n| {
        const t0 = nowMs();
        const width = info.out_width;
        const height = info.out_height;
        const bps = a.depth.bytesPerSample();
        const nplanes: usize = if (a.alpha) 4 else 3;

        const stride: usize = @as(usize, width) * bps;
        var planes: [4]?[*]u8 = .{ null, null, null, null };
        var bufs: [4][]u8 = undefined;
        for (0..nplanes) |i| {
            bufs[i] = try gpa.alloc(u8, stride * height);
            planes[i] = bufs[i].ptr;
        }
        defer for (0..nplanes) |i| gpa.free(bufs[i]);

        const dest: core.formats.Dest = .{
            .width = width,
            .height = height,
            .planes = planes,
            .strides = .{ stride, stride, stride, stride },
        };

        var fm: core.FrameMeta = .{};
        defer fm.deinit(gpa);
        dec.decodeFrame(n, &dest, &fm) catch |e| {
            fatal("decode frame {d} failed: {t} (stage: {s}, hr=0x{x})", .{ n, e, fm.fail_stage, @as(u32, @bitCast(fm.fail_hr)) });
        };
        const t1 = nowMs();

        try w.print("\nframe {d} decoded in {d} ms ({d}x{d}, {t}{s})\n", .{ n, t1 - t0, width, height, a.depth, if (a.alpha) " + alpha" else "" });
        if (fm.timecode) |tc| try w.print("timecode:      {s}\n", .{tc});
        if (fm.sensor_rate) |sr| try w.print("sensor rate:   {d}/{d}\n", .{ sr[0], sr[1] });
        try printProps(w, "frame props", &fm.props);
        if (a.all_meta) try printProps(w, "frame metadata (all)", &fm.props_all);
        try w.flush();

        if (a.out) |out_path| {
            try writeImage(io, out_path, a.depth, width, height, bufs);
            try w.print("wrote {s}\n", .{out_path});
            try w.flush();
        }
    }

    if (a.audio_out) |audio_path| {
        const au = info.audio orelse fatal("clip has no audio", .{});
        const want: u32 = @intCast(@min(@as(u64, au.sample_rate) * 2, au.sample_count));
        const bytes_needed = @as(usize, want) * au.channels * ((au.bit_depth + 7) / 8);
        const buf = try gpa.alloc(u8, bytes_needed);
        defer gpa.free(buf);
        const res = try dec.readAudio(0, buf, want);

        var f = try std.Io.Dir.cwd().createFile(io, audio_path, .{});
        defer f.close(io);
        var fbuf: [1 << 14]u8 = undefined;
        var fw = f.writer(io, &fbuf);
        try fw.interface.writeAll(buf[0..res.bytes]);
        try fw.interface.flush();
        try w.print("wrote {d} samples ({d} bytes) to {s}\n", .{ res.samples, res.bytes, audio_path });
        try w.flush();
    }
}

/// PPM (P6) for u8/u16; raw little-endian plane dump for float depths.
fn writeImage(io: std.Io, path: []const u8, depth: core.formats.Depth, w: u32, h: u32, bufs: [4][]u8) !void {
    var f = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    var write_buf: [1 << 16]u8 = undefined;
    var fw = f.writer(io, &write_buf);
    const out = &fw.interface;

    switch (depth) {
        .u8_, .u16_ => {
            const maxval: u32 = if (depth == .u8_) 255 else 65535;
            try out.print("P6\n{d} {d}\n{d}\n", .{ w, h, maxval });
            const npix: usize = @as(usize, w) * h;
            if (depth == .u8_) {
                var i: usize = 0;
                while (i < npix) : (i += 1) {
                    try out.writeByte(bufs[0][i]);
                    try out.writeByte(bufs[1][i]);
                    try out.writeByte(bufs[2][i]);
                }
            } else {
                // PPM 16-bit is big-endian
                var i: usize = 0;
                while (i < npix) : (i += 1) {
                    inline for (0..3) |p| {
                        const v = std.mem.readInt(u16, bufs[p][i * 2 ..][0..2], .little);
                        try out.writeInt(u16, v, .big);
                    }
                }
            }
        },
        .f16, .f32_ => {
            for (0..3) |p| try out.writeAll(bufs[p]);
        },
    }
    try out.flush();
}
