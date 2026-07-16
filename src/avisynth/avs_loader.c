/* avs_load_library() is a static-inline helper in avisynth_c.h (AVSC_NO_DECLSPEC
 * mode): it LoadLibrary()s avisynth and GetProcAddress()es every API function
 * into a freshly-allocated AVS_Library table. Zig's translate-c can't emit that
 * inline body, so we compile it here with the real C compiler and expose a
 * plain (non-inline) wrapper the Zig adapter links against.
 *
 * This file also marshals the AviSynth C API's by-value AVS_Value boundaries:
 * Zig's calling-convention lowering passes/returns small structs indirectly on
 * Windows, so every by-value AVS_Value crossing goes through C and reaches Zig
 * BY POINTER. (Pattern proven in autoadjuster.) */
#ifndef AVSC_NO_DECLSPEC
#define AVSC_NO_DECLSPEC
#endif
#include <windows.h>
#include "avisynth_c.h"

static AVS_Library *g_L = 0;

AVS_Library *bsrc_load_avs_library(void) {
    g_L = avs_load_library();
    return g_L;
}

/* --- by-value AVS_Value marshalling --- */

AVS_Clip *bsrc_new_c_filter(AVS_ScriptEnvironment *env, AVS_FilterInfo **fi,
                            const AVS_Value *child, int store_child) {
    return g_L->avs_new_c_filter(env, fi, *child, store_child);
}

/* Apply-callback trampoline: registered with avs_add_function, called by the
 * host with the correct AVSC_CC ABI; forwards to the Zig adapter by pointer. */
extern void bsrc_create_impl(AVS_ScriptEnvironment *env, const AVS_Value *args,
                             AVS_Value *out, void *user_data);

static AVS_Value AVSC_CC bsrc_create_trampoline(AVS_ScriptEnvironment *env, AVS_Value args,
                                                void *user_data) {
    AVS_Value out;
    bsrc_create_impl(env, &args, &out, user_data);
    return out;
}

void *bsrc_apply_func(void) {
    return (void *)bsrc_create_trampoline;
}

/* Directory containing this DLL (for the BlackmagicRawAPI search path).
 * Wide API + UTF-8 conversion: the ANSI variant garbles non-ASCII install
 * paths, which then fail the runtime search. The loader consumes UTF-8. */
int bsrc_module_dir(char *buf, int len) {
    HMODULE mod = NULL;
    if (!GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                                GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                            (LPCSTR)&bsrc_module_dir, &mod))
        return 0;
    WCHAR wbuf[MAX_PATH];
    DWORD wn = GetModuleFileNameW(mod, wbuf, MAX_PATH);
    if (wn == 0 || wn >= MAX_PATH)
        return 0;
    int n = WideCharToMultiByte(CP_UTF8, 0, wbuf, (int)wn, buf, len - 1, NULL, NULL);
    if (n <= 0)
        return 0;
    buf[n] = 0;
    for (int i = (int)n - 1; i >= 0; i--) {
        if (buf[i] == '\\' || buf[i] == '/') {
            buf[i] = 0;
            return i;
        }
    }
    return 0;
}
