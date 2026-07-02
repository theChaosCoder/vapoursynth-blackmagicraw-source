//! Host-free core of the brawsource plugin: Blackmagic RAW SDK binding,
//! synchronous decoder bridge, format conversion and metadata mapping.
//! Nothing in here depends on VapourSynth or AviSynth, so the whole core is
//! unit-testable (and usable from the braw-probe CLI) on its own.

pub const api = @import("braw/api.zig");
pub const strings = @import("braw/strings.zig");
pub const variant = @import("braw/variant.zig");
pub const loader = @import("braw/loader.zig");
pub const cuda = @import("braw/cuda.zig");
pub const formats = @import("formats.zig");
pub const meta = @import("meta.zig");
pub const decoder = @import("decoder.zig");
pub const sync = @import("sync.zig");
pub const audio = @import("audio.zig");

pub const Decoder = decoder.Decoder;
pub const OpenOptions = decoder.OpenOptions;
pub const FrameMeta = decoder.FrameMeta;
pub const MetaValue = variant.MetaValue;

test {
    _ = api;
    _ = strings;
    _ = variant;
    _ = loader;
    _ = formats;
    _ = meta;
    _ = decoder;
    _ = sync;
    _ = audio;
}
