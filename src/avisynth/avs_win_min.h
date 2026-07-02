#ifndef BSRC_AVS_WIN_MIN_H
#define BSRC_AVS_WIN_MIN_H
/* Minimal stand-ins so Zig's translate-c can parse avisynth_c.h's dynamic-loader
 * inline (avs_load_library) WITHOUT the full mingw windows.h, which translate-c
 * cannot parse. The real loader is compiled from avs_loader.c by clang with the
 * genuine windows.h; the Zig side never calls avs_load_library (it calls
 * bsrc_load_avs_library from that shim), so the inline is dead code here —
 * these declarations only let it translate. (Pattern from autoadjuster.) */
extern void *malloc();
extern void free(void *ptr);
typedef void *HMODULE;
extern HMODULE LoadLibraryA(const char *name);
extern void *GetProcAddress(HMODULE module, const char *name);
extern int FreeLibrary(HMODULE module);
#endif
