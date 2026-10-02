/*
===========================================================================
Copyright (C) 1999-2005 Id Software, Inc.

This file is part of Quake III Arena source code.

Quake III Arena source code is free software; you can redistribute it
and/or modify it under the terms of the GNU General Public License as
published by the Free Software Foundation; either version 2 of the License,
or (at your option) any later version.

Quake III Arena source code is distributed in the hope that it will be
useful, but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with Quake III Arena source code; if not, write to the Free Software
Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA
===========================================================================
*/
/*
 * visionOS GLimp: ANGLE (GLES 1.1 -> Metal) via EGL. Replaces code/sdl/sdl_glimp.c
 * and sdl_gamma.c (ADR-002). Derived from iortcw sdl_glimp.c: the GLES shims,
 * proc-address loading, extension setup and glConfig fill are kept verbatim;
 * only the SDL window/context layer is replaced.
 *
 * Surface: a CAMetalLayer window surface supplied by the Swift host through
 * VOS_SetNativeLayer() (M2); falls back to a headless pbuffer when none is set.
 */

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

#include "renderer/tr_local.h"
#include "sys/sys_local.h"
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include "vos_xr.h"
#include "vos_flat.h"

#define SDL_GL_GetProcAddress( name ) ( (void *)eglGetProcAddress( name ) )
#define SDL_GL_ExtensionSupported( name ) GLimp_ExtensionSupported( name )

void myglMultiTexCoord2f( GLenum texture, GLfloat s, GLfloat t )
{
	qglMultiTexCoord4f(texture, s, t, 0, 1);
}

static EGLDisplay vos_display = EGL_NO_DISPLAY;
static EGLSurface vos_surface = EGL_NO_SURFACE;
static EGLContext vos_context = EGL_NO_CONTEXT;

static void *vos_layer;          // CAMetalLayer*, owned by the Swift view
static int vos_layerWidth, vos_layerHeight;

void VOS_SetNativeLayer( void *layer, int pixelWidth, int pixelHeight )
{
	vos_layer = layer;
	vos_layerWidth = pixelWidth;
	vos_layerHeight = pixelHeight;
}

cvar_t *r_allowSoftwareGL;
cvar_t *r_allowResize;
cvar_t *r_centerWindow;
cvar_t *r_sdlDriver;

int qglMajorVersion, qglMinorVersion;
int qglesMajorVersion, qglesMinorVersion;

void (APIENTRYP qglActiveTextureARB) (GLenum texture);
void (APIENTRYP qglClientActiveTextureARB) (GLenum texture);
void (APIENTRYP qglMultiTexCoord2fARB) (GLenum target, GLfloat s, GLfloat t);

void (APIENTRYP qglLockArraysEXT) (GLint first, GLsizei count);
void (APIENTRYP qglUnlockArraysEXT) (void);

#define GLE(ret, name, ...) name##proc * qgl##name = NULL;
QGL_1_1_PROCS;
QGL_1_1_FIXED_FUNCTION_PROCS;
QGL_DESKTOP_1_1_PROCS;
QGL_DESKTOP_1_1_FIXED_FUNCTION_PROCS;
QGL_ES_1_1_PROCS;
QGL_ES_1_1_FIXED_FUNCTION_PROCS;
QGL_1_3_PROCS;
QGL_1_5_PROCS;
QGL_2_0_PROCS;
QGL_3_0_PROCS;
QGL_ARB_occlusion_query_PROCS;
QGL_ARB_framebuffer_object_PROCS;
QGL_ARB_vertex_array_object_PROCS;
QGL_EXT_direct_state_access_PROCS;
#undef GLE

static qboolean GLimp_ExtensionSupported( const char *name )
{
	const char *exts = (const char *)qglGetString( GL_EXTENSIONS );
	size_t len = strlen( name );
	const char *p = exts;

	while ( p && ( p = strstr( p, name ) ) ) {
		if ( ( p == exts || p[-1] == ' ' ) && ( p[len] == ' ' || p[len] == '\0' ) )
			return qtrue;
		p += len;
	}
	return qfalse;
}

static void GLimp_DestroyEGL( void )
{
	if ( vos_display == EGL_NO_DISPLAY )
		return;
	eglMakeCurrent( vos_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT );
	if ( vos_context != EGL_NO_CONTEXT ) eglDestroyContext( vos_display, vos_context );
	if ( vos_surface != EGL_NO_SURFACE ) eglDestroySurface( vos_display, vos_surface );
	eglTerminate( vos_display );
	vos_display = EGL_NO_DISPLAY;
	vos_surface = EGL_NO_SURFACE;
	vos_context = EGL_NO_CONTEXT;
}

void GLimp_Shutdown( void )
{
	ri.IN_Shutdown();
	GLimp_DestroyEGL();
	Com_Memset( &glConfig, 0, sizeof( glConfig ) );
	Com_Memset( &glState, 0, sizeof( glState ) );
}

void GLimp_Minimize( void ) {}

void GLimp_LogComment( char *comment ) { (void)comment; }

void GLimp_SetGamma( unsigned char red[256], unsigned char green[256], unsigned char blue[256] ) {}

#ifdef USE_OPENGLES
/*
===============
OpenGL ES compatibility
===============
*/
static void APIENTRY GLimp_GLES_ClearDepth( GLclampd depth ) {
	qglClearDepthf( depth );
}

static void APIENTRY GLimp_GLES_ClipPlane( GLenum plane, const GLdouble *equation ) {
	GLfloat values[4];
	values[0] = equation[0];
	values[1] = equation[1];
	values[2] = equation[2];
	values[3] = equation[3];
	qglClipPlanef( plane, values );
}

static void APIENTRY GLimp_GLES_Color3f( GLfloat red, GLfloat green, GLfloat blue ) {
	qglColor4f( red, green, blue, 1.0f );
}

static void APIENTRY GLimp_GLES_Color4ubv( const GLubyte *v ) {
	qglColor4ub( v[0], v[1], v[2], v[3] );
}

static void APIENTRY GLimp_GLES_DepthRange( GLclampd near_val, GLclampd far_val ) {
	qglDepthRangef( near_val, far_val );
}

static void APIENTRY GLimp_GLES_DrawBuffer( GLenum mode ) {
	// Immersive stereo: the backend's per-eye draw buffer selects the eye framebuffer.
	if ( VOS_XR_Active() ) {
		if ( mode == VOS_GL_BACK_SCREEN )
			VOS_XR_BindScreen();
		else
			VOS_XR_BindEye( mode == VOS_GL_BACK_RIGHT ? 1 : 0 );
	} else if ( vos_layer ) {
		VOS_Flat_Bind();
	}
}

static void APIENTRY GLimp_GLES_Frustum( GLdouble left, GLdouble right, GLdouble bottom, GLdouble top, GLdouble near_val, GLdouble far_val ) {
	qglFrustumf( left, right, bottom, top, near_val, far_val );
}

static void APIENTRY GLimp_GLES_Ortho( GLdouble left, GLdouble right, GLdouble bottom, GLdouble top, GLdouble near_val, GLdouble far_val ) {
	qglOrthof( left, right, bottom, top, near_val, far_val );
}

static void APIENTRY GLimp_GLES_PolygonMode( GLenum face, GLenum mode ) {
	// unsupported
}

/*Added*/
static void APIENTRY GLimp_GLES_Fogi( GLenum pname, GLint param ) {
	qglFogf( pname, param );
}
#endif

/*
===============
GLimp_GetProcAddresses

Get addresses for OpenGL functions.
===============
*/
static qboolean GLimp_GetProcAddresses( qboolean fixedFunction ) {
	qboolean success = qtrue;
	const char *version;

#ifdef __SDL_NOGETPROCADDR__
#define GLE( ret, name, ... ) qgl##name = gl#name;
#else
#define GLE( ret, name, ... ) qgl##name = (name##proc *) SDL_GL_GetProcAddress("gl" #name); \
	if ( qgl##name == NULL ) { \
		ri.Printf( PRINT_ALL, "ERROR: Missing OpenGL function %s\n", "gl" #name ); \
		success = qfalse; \
	}
#endif

	// OpenGL 1.0 and OpenGL ES 1.0
	GLE(const GLubyte *, GetString, GLenum name)

	if ( !qglGetString ) {
		Com_Error( ERR_FATAL, "glGetString is NULL" );
	}

	version = (const char *)qglGetString( GL_VERSION );

	if ( !version ) {
		Com_Error( ERR_FATAL, "GL_VERSION is NULL" );
	}

	if ( Q_stricmpn( "OpenGL ES", version, 9 ) == 0 ) {
		char profile[6]; // ES, ES-CM, or ES-CL
		sscanf( version, "OpenGL %5s %d.%d", profile, &qglesMajorVersion, &qglesMinorVersion );
		// common lite profile (no floating point) is not supported
		if ( Q_stricmp( profile, "ES-CL" ) == 0 ) {
			qglesMajorVersion = 0;
			qglesMinorVersion = 0;
		}
	} else {
		sscanf( version, "%d.%d", &qglMajorVersion, &qglMinorVersion );
	}

	if ( fixedFunction ) {
		if ( QGL_VERSION_ATLEAST( 1, 1 ) ) {
			QGL_1_1_PROCS;
			QGL_1_1_FIXED_FUNCTION_PROCS;
			QGL_DESKTOP_1_1_PROCS;
			QGL_DESKTOP_1_1_FIXED_FUNCTION_PROCS;
		} else if ( qglesMajorVersion == 1 && qglesMinorVersion >= 1 ) {
			// OpenGL ES 1.1 (2.0 is not backward compatible)
			QGL_1_1_PROCS;
			QGL_1_1_FIXED_FUNCTION_PROCS;
			QGL_ES_1_1_PROCS;
			QGL_ES_1_1_FIXED_FUNCTION_PROCS;

#ifdef USE_OPENGLES
			qglClearDepth = GLimp_GLES_ClearDepth;
			qglClipPlane = GLimp_GLES_ClipPlane;
			qglColor3f = GLimp_GLES_Color3f;
			qglColor4ubv = GLimp_GLES_Color4ubv;
			qglDepthRange = GLimp_GLES_DepthRange;
			qglDrawBuffer = GLimp_GLES_DrawBuffer;
			qglFrustum = GLimp_GLES_Frustum;
			qglOrtho = GLimp_GLES_Ortho;
			qglPolygonMode = GLimp_GLES_PolygonMode;
			qglFogi = GLimp_GLES_Fogi; /*Added*/
#else
			// error so this doesn't segfault due to NULL desktop GL functions being used
			Com_Error( ERR_FATAL, "Unsupported OpenGL Version: %s", version );
#endif
		} else {
			Com_Error( ERR_FATAL, "Unsupported OpenGL Version (%s), OpenGL 1.1 is required", version );
		}
	} else {
		if ( QGL_VERSION_ATLEAST( 2, 0 ) ) {
			QGL_1_1_PROCS;
			QGL_DESKTOP_1_1_PROCS;
			QGL_1_3_PROCS;
			QGL_1_5_PROCS;
			QGL_2_0_PROCS;
		} else if ( QGLES_VERSION_ATLEAST( 2, 0 ) ) {
			QGL_1_1_PROCS;
			QGL_ES_1_1_PROCS;
			QGL_1_3_PROCS;
			QGL_1_5_PROCS;
			QGL_2_0_PROCS;
			// error so this doesn't segfault due to NULL desktop GL functions being used
			Com_Error( ERR_FATAL, "Unsupported OpenGL Version: %s", version );
		} else {
			Com_Error( ERR_FATAL, "Unsupported OpenGL Version (%s), OpenGL 2.0 is required", version );
		}
	}

	if ( QGL_VERSION_ATLEAST( 3, 0 ) || QGLES_VERSION_ATLEAST( 3, 0 ) ) {
		QGL_3_0_PROCS;
	}

#undef GLE

	return success;
}

/*
===============
GLimp_ClearProcAddresses

Clear addresses for OpenGL functions.
===============
*/
static void GLimp_ClearProcAddresses( void ) {
#define GLE( ret, name, ... ) qgl##name = NULL;

	qglMajorVersion = 0;
	qglMinorVersion = 0;
	qglesMajorVersion = 0;
	qglesMinorVersion = 0;

	QGL_1_1_PROCS;
	QGL_1_1_FIXED_FUNCTION_PROCS;
	QGL_DESKTOP_1_1_PROCS;
	QGL_DESKTOP_1_1_FIXED_FUNCTION_PROCS;
	QGL_ES_1_1_PROCS;
	QGL_ES_1_1_FIXED_FUNCTION_PROCS;
	QGL_1_3_PROCS;
	QGL_1_5_PROCS;
	QGL_2_0_PROCS;
	QGL_3_0_PROCS;
	QGL_ARB_occlusion_query_PROCS;
	QGL_ARB_framebuffer_object_PROCS;
	QGL_ARB_vertex_array_object_PROCS;
	QGL_EXT_direct_state_access_PROCS;

	qglActiveTextureARB = NULL;
	qglClientActiveTextureARB = NULL;
	qglMultiTexCoord2fARB = NULL;

	qglLockArraysEXT = NULL;
	qglUnlockArraysEXT = NULL;

#undef GLE
}

/*
===============
GLimp_SetMode
===============
*/

/*
===============
GLimp_StartDriverAndSetMode

EGL on ANGLE's Metal backend with a GLES 1.1 context.
===============
*/
static qboolean GLimp_StartDriverAndSetMode( int mode, qboolean fixedFunction )
{
	static const EGLint cfgAttr[] = {
		EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
		EGL_DEPTH_SIZE, 24, EGL_STENCIL_SIZE, 8,
		EGL_SURFACE_TYPE, EGL_WINDOW_BIT | EGL_PBUFFER_BIT,
		EGL_RENDERABLE_TYPE, EGL_OPENGL_ES_BIT,
		EGL_NONE
	};
	static const EGLint ctxAttr[] = { EGL_CONTEXT_CLIENT_VERSION, 1, EGL_NONE };
	EGLint major, minor, numCfg, pbAttr[5];
	EGLConfig cfg;
	int width, height;

	if ( VOS_XR_Active() ) {
		width = height = 16;   // placeholder pbuffer; eye framebuffers come from Compositor Services
	} else if ( vos_layer && vos_layerWidth > 0 && vos_layerHeight > 0 ) {
		width = vos_layerWidth;
		height = vos_layerHeight;
		glConfig.windowAspect = (float)width / (float)height;
	} else if ( !R_GetModeInfo( &width, &height, &glConfig.windowAspect, mode ) ) {
		width = 1280; height = 720; glConfig.windowAspect = 16.0f / 9.0f;
	}

	vos_display = eglGetDisplay( EGL_DEFAULT_DISPLAY );
	if ( vos_display == EGL_NO_DISPLAY || !eglInitialize( vos_display, &major, &minor ) ) {
		ri.Printf( PRINT_ALL, "GLimp: eglInitialize failed (0x%x)\n", eglGetError() );
		return qfalse;
	}
	ri.Printf( PRINT_ALL, "GLimp: EGL %d.%d, %s\n", major, minor, eglQueryString( vos_display, EGL_VENDOR ) );

	if ( !eglChooseConfig( vos_display, cfgAttr, &cfg, 1, &numCfg ) || numCfg < 1 ) {
		ri.Printf( PRINT_ALL, "GLimp: eglChooseConfig failed (0x%x)\n", eglGetError() );
		GLimp_DestroyEGL();
		return qfalse;
	}

	// Always a small pbuffer: flat and immersive both render into our own FBOs and
	// present through Metal (vos_flat.m / vos_xr.m).
	pbAttr[0] = EGL_WIDTH; pbAttr[1] = 16; pbAttr[2] = EGL_HEIGHT; pbAttr[3] = 16; pbAttr[4] = EGL_NONE;
	vos_surface = eglCreatePbufferSurface( vos_display, cfg, pbAttr );
	vos_context = eglCreateContext( vos_display, cfg, EGL_NO_CONTEXT, ctxAttr );
	if ( vos_surface == EGL_NO_SURFACE || vos_context == EGL_NO_CONTEXT ||
		!eglMakeCurrent( vos_display, vos_surface, vos_surface, vos_context ) ) {
		ri.Printf( PRINT_ALL, "GLimp: EGL surface/context failed (0x%x)\n", eglGetError() );
		GLimp_DestroyEGL();
		return qfalse;
	}

	if ( VOS_XR_Active() ) {
		if ( !VOS_XR_Init( vos_display, &width, &height ) ) {
			ri.Printf( PRINT_ALL, "GLimp: Compositor Services frame acquisition failed\n" );
			GLimp_DestroyEGL();
			return qfalse;
		}
		glConfig.windowAspect = (float)width / (float)height;
	} else if ( vos_layer ) {
		if ( !VOS_Flat_Init( vos_display, vos_layer, width, height ) ) {
			GLimp_DestroyEGL();
			return qfalse;
		}
	} else {
		EGLint sw = 0, sh = 0;
		eglQuerySurface( vos_display, vos_surface, EGL_WIDTH, &sw );
		eglQuerySurface( vos_display, vos_surface, EGL_HEIGHT, &sh );
		ri.Printf( PRINT_ALL, "GLimp: requested %dx%d, EGL surface %dx%d\n", width, height, sw, sh );
		if ( sw > 0 && sh > 0 ) { width = sw; height = sh; glConfig.windowAspect = (float)sw / sh; }
	}

	glConfig.vidWidth = width;
	glConfig.vidHeight = height;
	glConfig.colorBits = 32;
	glConfig.depthBits = 24;
	glConfig.stencilBits = 8;
	glConfig.isFullscreen = qfalse;
	glConfig.stereoEnabled = VOS_XR_Active() && VOS_XR_EyeCount() >= 2;
	if ( VOS_XR_Active() )
		VOS_XR_SetStereoRendering( glConfig.stereoEnabled );

	if ( !GLimp_GetProcAddresses( fixedFunction ) ) {
		ri.Printf( PRINT_ALL, "GLimp_GetProcAddresses() failed\n" );
		GLimp_ClearProcAddresses();
		GLimp_DestroyEGL();
		return qfalse;
	}

	ri.Printf( PRINT_ALL, "GLimp: %dx%d %s, GL_VERSION %s\n", width, height, VOS_XR_Active() ? "immersive per-eye" : vos_layer ? "CAMetalLayer" : "pbuffer", (const char *)qglGetString( GL_VERSION ) );
	return qtrue;
}


/*
===============
GLimp_InitExtensions
===============
*/
static void GLimp_InitExtensions( qboolean fixedFunction )
{
	if ( !r_allowExtensions->integer )
	{
		ri.Printf( PRINT_ALL, "* IGNORING OPENGL EXTENSIONS *\n" );
		return;
	}

	ri.Printf( PRINT_ALL, "Initializing OpenGL extensions\n" );

	glConfig.textureCompression = TC_NONE;

	// GL_EXT_texture_compression_s3tc
	if ( SDL_GL_ExtensionSupported( "GL_ARB_texture_compression" ) &&
	     SDL_GL_ExtensionSupported( "GL_EXT_texture_compression_s3tc" ) )
	{
		if ( r_ext_compressed_textures->value )
		{
			glConfig.textureCompression = TC_S3TC_ARB;
			ri.Printf( PRINT_ALL, "...using GL_EXT_texture_compression_s3tc\n" );
		}
		else
		{
			ri.Printf( PRINT_ALL, "...ignoring GL_EXT_texture_compression_s3tc\n" );
		}
	}
	else
	{
		ri.Printf( PRINT_ALL, "...GL_EXT_texture_compression_s3tc not found\n" );
	}

	// GL_S3_s3tc ... legacy extension before GL_EXT_texture_compression_s3tc.
	if (glConfig.textureCompression == TC_NONE)
	{
		if ( SDL_GL_ExtensionSupported( "GL_S3_s3tc" ) )
		{
			if ( r_ext_compressed_textures->value )
			{
				glConfig.textureCompression = TC_S3TC;
				ri.Printf( PRINT_ALL, "...using GL_S3_s3tc\n" );
			}
			else
			{
				ri.Printf( PRINT_ALL, "...ignoring GL_S3_s3tc\n" );
			}
		}
		else
		{
			ri.Printf( PRINT_ALL, "...GL_S3_s3tc not found\n" );
		}
	}

	// OpenGL 1 fixed function pipeline
	if ( fixedFunction )
	{
		// GL_EXT_texture_env_add
#ifdef USE_OPENGLES
		glConfig.textureEnvAddAvailable = qtrue;
		ri.Printf( PRINT_ALL, "...using GL_EXT_texture_env_add\n" );
#else
		glConfig.textureEnvAddAvailable = qfalse;
		if ( SDL_GL_ExtensionSupported( "GL_EXT_texture_env_add" ) )
		{
			if ( r_ext_texture_env_add->integer )
			{
				glConfig.textureEnvAddAvailable = qtrue;
				ri.Printf( PRINT_ALL, "...using GL_EXT_texture_env_add\n" );
			}
			else
			{
				glConfig.textureEnvAddAvailable = qfalse;
				ri.Printf( PRINT_ALL, "...ignoring GL_EXT_texture_env_add\n" );
			}
		}
		else
		{
			ri.Printf( PRINT_ALL, "...GL_EXT_texture_env_add not found\n" );
		}
#endif

		// GL_ARB_multitexture
		qglMultiTexCoord2fARB = NULL;
		qglActiveTextureARB = NULL;
		qglClientActiveTextureARB = NULL;
#ifdef USE_OPENGLES
		qglGetIntegerv( GL_MAX_TEXTURE_UNITS, &glConfig.numTextureUnits );
		//ri.Printf( PRINT_ALL, "...not using GL_ARB_multitexture, %i texture units\n", glConfig.maxActiveTextures );
		//glConfig.maxActiveTextures=4;
		qglMultiTexCoord2fARB = myglMultiTexCoord2f;
		qglActiveTextureARB = SDL_GL_GetProcAddress( "glActiveTexture" );
		qglClientActiveTextureARB = SDL_GL_GetProcAddress( "glClientActiveTexture" );
		if ( glConfig.numTextureUnits > 1 )
		{
			ri.Printf( PRINT_ALL, "...using GL_ARB_multitexture (%i texture units)\n", glConfig.numTextureUnits );
		}
		else
		{
			qglMultiTexCoord2fARB = NULL;
			qglActiveTextureARB = NULL;
			qglClientActiveTextureARB = NULL;
			ri.Printf( PRINT_ALL, "...not using GL_ARB_multitexture, < 2 texture units\n" );
		}
#else
		if ( SDL_GL_ExtensionSupported( "GL_ARB_multitexture" ) )
		{
			if ( r_ext_multitexture->value )
			{
				qglMultiTexCoord2fARB = SDL_GL_GetProcAddress( "glMultiTexCoord2fARB" );
				qglActiveTextureARB = SDL_GL_GetProcAddress( "glActiveTextureARB" );
				qglClientActiveTextureARB = SDL_GL_GetProcAddress( "glClientActiveTextureARB" );

				if ( qglActiveTextureARB )
				{
					GLint glint = 0;
					qglGetIntegerv( GL_MAX_TEXTURE_UNITS_ARB, &glint );
					glConfig.numTextureUnits = (int) glint;
					if ( glConfig.numTextureUnits > 1 )
					{
						ri.Printf( PRINT_ALL, "...using GL_ARB_multitexture\n" );
					}
					else
					{
						qglMultiTexCoord2fARB = NULL;
						qglActiveTextureARB = NULL;
						qglClientActiveTextureARB = NULL;
						ri.Printf( PRINT_ALL, "...not using GL_ARB_multitexture, < 2 texture units\n" );
					}
				}
			}
			else
			{
				ri.Printf( PRINT_ALL, "...ignoring GL_ARB_multitexture\n" );
			}
		}
		else
		{
			ri.Printf( PRINT_ALL, "...GL_ARB_multitexture not found\n" );
		}
#endif

		// GL_EXT_compiled_vertex_array
		if ( SDL_GL_ExtensionSupported( "GL_EXT_compiled_vertex_array" ) )
		{
			if ( r_ext_compiled_vertex_array->value )
			{
				ri.Printf( PRINT_ALL, "...using GL_EXT_compiled_vertex_array\n" );
				qglLockArraysEXT = ( void ( APIENTRY * )( GLint, GLint ) ) SDL_GL_GetProcAddress( "glLockArraysEXT" );
				qglUnlockArraysEXT = ( void ( APIENTRY * )( void ) ) SDL_GL_GetProcAddress( "glUnlockArraysEXT" );
				if (!qglLockArraysEXT || !qglUnlockArraysEXT)
				{
					ri.Error (ERR_FATAL, "bad getprocaddress");
				}
			}
			else
			{
				ri.Printf( PRINT_ALL, "...ignoring GL_EXT_compiled_vertex_array\n" );
			}
		}
		else
		{
			ri.Printf( PRINT_ALL, "...GL_EXT_compiled_vertex_array not found\n" );
		}
	}

	textureFilterAnisotropic = qfalse;
	if ( SDL_GL_ExtensionSupported( "GL_EXT_texture_filter_anisotropic" ) )
	{
		if ( r_ext_texture_filter_anisotropic->integer ) {
			qglGetIntegerv( GL_MAX_TEXTURE_MAX_ANISOTROPY_EXT, (GLint *)&maxAnisotropy );
			if ( maxAnisotropy <= 0 ) {
				ri.Printf( PRINT_ALL, "...GL_EXT_texture_filter_anisotropic not properly supported!\n" );
				maxAnisotropy = 0;
			}
			else
			{
				ri.Printf( PRINT_ALL, "...using GL_EXT_texture_filter_anisotropic (max: %i)\n", maxAnisotropy );
				textureFilterAnisotropic = qtrue;
			}
		}
		else
		{
			ri.Printf( PRINT_ALL, "...ignoring GL_EXT_texture_filter_anisotropic\n" );
		}
	}
	else
	{
		ri.Printf( PRINT_ALL, "...GL_EXT_texture_filter_anisotropic not found\n" );
	}

	haveClampToEdge = qfalse;
	if ( QGL_VERSION_ATLEAST( 1, 2 ) || QGLES_VERSION_ATLEAST( 1, 0 ) || SDL_GL_ExtensionSupported( "GL_SGIS_texture_edge_clamp" ) )
	{
		ri.Printf( PRINT_ALL, "...using GL_SGIS_texture_edge_clamp\n" );
		haveClampToEdge = qtrue;
	}
	else
	{
		ri.Printf( PRINT_ALL, "...GL_SGIS_texture_edge_clamp not found\n" );
	}
}

#define R_MODE_FALLBACK 3 // 640 * 480

/*
===============
GLimp_Init

This routine is responsible for initializing the OS specific portions
of OpenGL
===============
*/

/*
===============
GLimp_Init
===============
*/
void GLimp_Init( qboolean fixedFunction )
{
	ri.Printf( PRINT_DEVELOPER, "Glimp_Init( )\n" );

	r_allowSoftwareGL = ri.Cvar_Get( "r_allowSoftwareGL", "0", CVAR_LATCH );
	r_sdlDriver = ri.Cvar_Get( "r_sdlDriver", "ANGLE", CVAR_ROM );
	r_allowResize = ri.Cvar_Get( "r_allowResize", "0", CVAR_ARCHIVE | CVAR_LATCH );
	r_centerWindow = ri.Cvar_Get( "r_centerWindow", "0", CVAR_ARCHIVE | CVAR_LATCH );

	ri.Sys_GLimpInit( );

	if ( !GLimp_StartDriverAndSetMode( r_mode->integer, fixedFunction ) ) {
		ri.Error( ERR_FATAL, "GLimp_Init() - could not start ANGLE/EGL" );
	}

	// These values force the UI to disable driver selection
	glConfig.driverType = GLDRV_ICD;
	glConfig.hardwareType = GLHW_GENERIC;

	// Only using SDL_SetWindowBrightness to determine if hardware gamma is supported
	glConfig.deviceSupportsGamma = !r_ignorehwgamma->integer &&
		qfalse;

	// get our config strings
	Q_strncpyz( glConfig.vendor_string, (char *) qglGetString (GL_VENDOR), sizeof( glConfig.vendor_string ) );
	Q_strncpyz( glConfig.renderer_string, (char *) qglGetString (GL_RENDERER), sizeof( glConfig.renderer_string ) );
	if (*glConfig.renderer_string && glConfig.renderer_string[strlen(glConfig.renderer_string) - 1] == '\n')
		glConfig.renderer_string[strlen(glConfig.renderer_string) - 1] = 0;
	Q_strncpyz( glConfig.version_string, (char *) qglGetString (GL_VERSION), sizeof( glConfig.version_string ) );

#ifndef USE_OPENGLES
	// manually create extension list if using OpenGL 3
	if ( qglGetStringi )
	{
		int i, numExtensions, extensionLength, listLength;
		const char *extension;

		qglGetIntegerv( GL_NUM_EXTENSIONS, &numExtensions );
		listLength = 0;

		for ( i = 0; i < numExtensions; i++ )
		{
			extension = (char *) qglGetStringi( GL_EXTENSIONS, i );
			extensionLength = strlen( extension );

			if ( ( listLength + extensionLength + 1 ) >= sizeof( glConfig.extensions_string ) )
				break;

			if ( i > 0 ) {
				Q_strcat( glConfig.extensions_string, sizeof( glConfig.extensions_string ), " " );
				listLength++;
			}

			Q_strcat( glConfig.extensions_string, sizeof( glConfig.extensions_string ), extension );
			listLength += extensionLength;
		}
	}
	else
#endif
	{
		Q_strncpyz( glConfig.extensions_string, (char *) qglGetString (GL_EXTENSIONS), sizeof( glConfig.extensions_string ) );
	}

	// initialize extensions
	GLimp_InitExtensions( fixedFunction );

	ri.Cvar_Get( "r_availableModes", "", CVAR_ROM );

	// This depends on SDL_INIT_VIDEO, hence having it here
	ri.IN_Init( NULL );
}

/*
===============
GLimp_EndFrame
===============
*/
void GLimp_EndFrame( void )
{
	if ( VOS_XR_Active() )
		VOS_XR_EndFrame();
	else if ( vos_layer )
		VOS_Flat_Present();
	else
		eglSwapBuffers( vos_display, vos_surface );
}
