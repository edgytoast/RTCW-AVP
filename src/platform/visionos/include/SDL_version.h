/* Shim: iortcw sys_local.h includes SDL_version.h for a version check.
 * visionOS has no SDL; report a version that satisfies the check. */
#ifndef VOS_SDL_VERSION_SHIM_H
#define VOS_SDL_VERSION_SHIM_H
#define SDL_VERSIONNUM(X, Y, Z) ((X)*1000 + (Y)*100 + (Z))
#define SDL_VERSION_ATLEAST(X, Y, Z) 1
#endif
