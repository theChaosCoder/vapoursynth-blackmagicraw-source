//! AviSynth+ C API binding via translate-c in dynamic-loading mode.
//! AVSC_NO_DECLSPEC means no import library is needed — the host functions
//! are resolved at runtime into an AVS_Library table by avs_loader.c.

pub const c = @cImport({
    @cDefine("AVSC_NO_DECLSPEC", "1");
    @cInclude("avs_win_min.h");
    @cInclude("avisynth_c.h");
});
