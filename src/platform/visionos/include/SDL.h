/* Shim: iortcw includes SDL.h in a few engine headers. visionOS has no SDL;
 * only the loadso mapping (unused at runtime: modules are static) is provided. */
#ifndef VOS_SDL_SHIM_H
#define VOS_SDL_SHIM_H
#include <dlfcn.h>
#define SDL_LoadObject(f)      dlopen((f), RTLD_NOW)
#define SDL_UnloadObject(h)    dlclose(h)
#define SDL_LoadFunction(h, f) dlsym((h), (f))
#define SDL_GetError()         dlerror()
#endif
