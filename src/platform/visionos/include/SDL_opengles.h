/* Shim: iortcw qgl.h includes SDL_opengles.h under USE_OPENGLES.
 * On visionOS the GLES 1.x API comes from ANGLE (ADR-002). */
#ifndef VOS_SDL_OPENGLES_SHIM_H
#define VOS_SDL_OPENGLES_SHIM_H
#ifndef GL_GLES_PROTOTYPES
#define GL_GLES_PROTOTYPES 1   /* ANGLE's GLES/gl.h hides core prototypes unless set */
#endif
#ifndef GL_GLEXT_PROTOTYPES
#define GL_GLEXT_PROTOTYPES 1
#endif
#include <GLES/gl.h>
#include <GLES/glext.h>
#ifndef APIENTRY
#define APIENTRY GL_APIENTRY
#endif
#endif
