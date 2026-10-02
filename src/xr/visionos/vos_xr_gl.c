/*
 * GLES side of the immersive eye targets (ANGLE). Kept in plain C: in Objective-C
 * files the SDK's OpenGLES module (unavailable on visionOS) shadows ANGLE's headers.
 */
#include <stdio.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <EGL/eglext_angle.h>
#include "SDL_opengles.h"   // ANGLE GLES 1.x with prototypes (same path as the renderer)

#include "vos_xr_gl.h"

// GL_ANGLE_framebuffer_blit (GLES2/gl2ext.h cannot be mixed with GLES1 headers).
#define GL_READ_FRAMEBUFFER_ANGLE 0x8CA8
#define GL_DRAW_FRAMEBUFFER_ANGLE 0x8CA9
GL_API void GL_APIENTRY glBlitFramebufferANGLE( GLint srcX0, GLint srcY0, GLint srcX1, GLint srcY1,
	GLint dstX0, GLint dstY0, GLint dstX1, GLint dstY1, GLbitfield mask, GLenum filter );

// GL_MESA_framebuffer_flip_y: Metal textures are top-left origin, GL renders bottom-left.
#define GL_FRAMEBUFFER_FLIP_Y_MESA 0x8BBB
typedef void ( GL_APIENTRY *framebufferParameteriMESA_t )( GLenum target, GLenum pname, GLint param );
static framebufferParameteriMESA_t qglFramebufferParameteriMESA;

// GL_ANGLE_framebuffer_multisample
#define GL_MAX_SAMPLES_ANGLE 0x8D57
typedef void ( GL_APIENTRY *renderbufferStorageMultisampleANGLE_t )( GLenum, GLsizei, GLenum, GLsizei, GLsizei );

int VOS_GL_CreateEyeTargetMS( void *display, void *mtlTexture, int width, int height, int samples, vosEyeGL_t *out )
{
	static renderbufferStorageMultisampleANGLE_t storageMS;
	GLint maxSamples = 0;

	if ( !VOS_GL_CreateEyeTarget( display, mtlTexture, width, height, out ) )
		return 0;
	if ( samples <= 1 )
		return 1;

	if ( !storageMS )
		storageMS = (renderbufferStorageMultisampleANGLE_t)eglGetProcAddress( "glRenderbufferStorageMultisampleANGLE" );
	glGetIntegerv( GL_MAX_SAMPLES_ANGLE, &maxSamples );
	if ( !storageMS || maxSamples < 2 ) {
		fprintf( stderr, "VOS: MSAA unavailable (max samples %d)\n", maxSamples );
		return 1;
	}
	if ( samples > maxSamples )
		samples = maxSamples;

	glGenRenderbuffersOES( 1, &out->msaaColor );
	glBindRenderbufferOES( GL_RENDERBUFFER_OES, out->msaaColor );
	storageMS( GL_RENDERBUFFER_OES, samples, GL_RGBA8_OES, width, height );
	glGenRenderbuffersOES( 1, &out->msaaDepth );
	glBindRenderbufferOES( GL_RENDERBUFFER_OES, out->msaaDepth );
	storageMS( GL_RENDERBUFFER_OES, samples, GL_DEPTH24_STENCIL8_OES, width, height );

	glGenFramebuffersOES( 1, &out->msaaFbo );
	glBindFramebufferOES( GL_FRAMEBUFFER_OES, out->msaaFbo );
	glFramebufferRenderbufferOES( GL_FRAMEBUFFER_OES, GL_COLOR_ATTACHMENT0_OES, GL_RENDERBUFFER_OES, out->msaaColor );
	glFramebufferRenderbufferOES( GL_FRAMEBUFFER_OES, GL_DEPTH_ATTACHMENT_OES, GL_RENDERBUFFER_OES, out->msaaDepth );
	glFramebufferRenderbufferOES( GL_FRAMEBUFFER_OES, GL_STENCIL_ATTACHMENT_OES, GL_RENDERBUFFER_OES, out->msaaDepth );
	if ( glCheckFramebufferStatusOES( GL_FRAMEBUFFER_OES ) != GL_FRAMEBUFFER_COMPLETE_OES ) {
		fprintf( stderr, "VOS: MSAA framebuffer incomplete, MSAA off\n" );
		glDeleteFramebuffersOES( 1, &out->msaaFbo );
		out->msaaFbo = 0;
		return 1;
	}
	out->samples = samples;
	return 1;
}

// Resolve MSAA into the texture FBO (no-op without MSAA). The Y flip happens once, at resolve.
void VOS_GL_Resolve( const vosEyeGL_t *t )
{
	if ( !t->msaaFbo )
		return;
	glBindFramebufferOES( GL_READ_FRAMEBUFFER_ANGLE, t->msaaFbo );
	glBindFramebufferOES( GL_DRAW_FRAMEBUFFER_ANGLE, t->fbo );
	glBlitFramebufferANGLE( 0, 0, t->width, t->height, 0, 0, t->width, t->height, GL_COLOR_BUFFER_BIT, GL_NEAREST );
}

int VOS_GL_CreateEyeTarget( void *display, void *mtlTexture, int width, int height, vosEyeGL_t *out )
{
	out->width = width;
	out->height = height;
	out->samples = 1;
	out->msaaFbo = out->msaaColor = out->msaaDepth = 0;
	EGLint attrs[] = { EGL_NONE };
	GLenum status;

	out->image = eglCreateImageKHR( (EGLDisplay)display, EGL_NO_CONTEXT, EGL_METAL_TEXTURE_ANGLE,
		(EGLClientBuffer)mtlTexture, attrs );
	if ( out->image == EGL_NO_IMAGE_KHR ) {
		fprintf( stderr, "VOS XR: eglCreateImageKHR failed 0x%x\n", eglGetError() );
		return 0;
	}

	glGenTextures( 1, &out->tex );
	glBindTexture( GL_TEXTURE_2D, out->tex );
	glEGLImageTargetTexture2DOES( GL_TEXTURE_2D, (GLeglImageOES)out->image );

	glGenRenderbuffersOES( 1, &out->depth );
	glBindRenderbufferOES( GL_RENDERBUFFER_OES, out->depth );
	glRenderbufferStorageOES( GL_RENDERBUFFER_OES, GL_DEPTH24_STENCIL8_OES, width, height );

	glGenFramebuffersOES( 1, &out->fbo );
	glBindFramebufferOES( GL_FRAMEBUFFER_OES, out->fbo );
	glFramebufferTexture2DOES( GL_FRAMEBUFFER_OES, GL_COLOR_ATTACHMENT0_OES, GL_TEXTURE_2D, out->tex, 0 );
	glFramebufferRenderbufferOES( GL_FRAMEBUFFER_OES, GL_DEPTH_ATTACHMENT_OES, GL_RENDERBUFFER_OES, out->depth );
	glFramebufferRenderbufferOES( GL_FRAMEBUFFER_OES, GL_STENCIL_ATTACHMENT_OES, GL_RENDERBUFFER_OES, out->depth );

	if ( !qglFramebufferParameteriMESA )
		qglFramebufferParameteriMESA = (framebufferParameteriMESA_t)eglGetProcAddress( "glFramebufferParameteriMESA" );
	if ( qglFramebufferParameteriMESA )
		qglFramebufferParameteriMESA( GL_FRAMEBUFFER_OES, GL_FRAMEBUFFER_FLIP_Y_MESA, 1 );
	else
		fprintf( stderr, "VOS XR: GL_MESA_framebuffer_flip_y unavailable, image will be upside down\n" );

	status = glCheckFramebufferStatusOES( GL_FRAMEBUFFER_OES );
	if ( status != GL_FRAMEBUFFER_COMPLETE_OES ) {
		fprintf( stderr, "VOS XR: eye framebuffer incomplete 0x%x\n", status );
		return 0;
	}
	return 1;
}

void VOS_GL_DestroyEyeTarget( void *display, vosEyeGL_t *t )
{
	if ( t->fbo ) glDeleteFramebuffersOES( 1, &t->fbo );
	if ( t->depth ) glDeleteRenderbuffersOES( 1, &t->depth );
	if ( t->tex ) glDeleteTextures( 1, &t->tex );
	if ( t->image ) eglDestroyImageKHR( (EGLDisplay)display, (EGLImageKHR)t->image );
	t->fbo = t->depth = t->tex = 0;
	t->image = 0;
}

void VOS_GL_BindTarget( const vosEyeGL_t *t )
{
	glBindFramebufferOES( GL_FRAMEBUFFER_OES, t->msaaFbo ? t->msaaFbo : t->fbo );
}

void VOS_GL_Blit( const vosEyeGL_t *src, const vosEyeGL_t *dst, int w, int h )
{
	glBindFramebufferOES( GL_READ_FRAMEBUFFER_ANGLE, src->fbo );
	glBindFramebufferOES( GL_DRAW_FRAMEBUFFER_ANGLE, dst->fbo );
	glBlitFramebufferANGLE( 0, 0, w, h, 0, 0, w, h, GL_COLOR_BUFFER_BIT, GL_NEAREST );
}

// The compositor treats alpha as coverage; the Q3 renderer leaves alpha undefined/0.
void VOS_GL_ForceOpaque( const vosEyeGL_t *t )
{
	glBindFramebufferOES( GL_FRAMEBUFFER_OES, t->fbo );
	glColorMask( GL_FALSE, GL_FALSE, GL_FALSE, GL_TRUE );
	glClearColor( 0, 0, 0, 1 );
	glClear( GL_COLOR_BUFFER_BIT );
	glColorMask( GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE );
}

// Diagnostic: fill an eye with a solid color (visible only where the engine does not draw).
void VOS_GL_ClearColor( const vosEyeGL_t *t, float r, float g, float b )
{
	glBindFramebufferOES( GL_FRAMEBUFFER_OES, t->fbo );
	glClearColor( r, g, b, 1 );
	glClear( GL_COLOR_BUFFER_BIT );
}

// EGL_ANGLE_metal_shared_event_sync: have the GPU signal `event` to `value` once all GL work
// submitted so far completes, without stalling the CPU (replaces glFinish). Returns 0 on failure.
int VOS_GL_SignalSharedEvent( void *display, void *mtlSharedEvent, unsigned long long value )
{
	EGLAttrib attrs[] = {
		EGL_SYNC_METAL_SHARED_EVENT_OBJECT_ANGLE, (EGLAttrib)mtlSharedEvent,
		EGL_SYNC_METAL_SHARED_EVENT_SIGNAL_VALUE_LO_ANGLE, (EGLAttrib)( value & 0xffffffffu ),
		EGL_SYNC_METAL_SHARED_EVENT_SIGNAL_VALUE_HI_ANGLE, (EGLAttrib)( value >> 32 ),
		EGL_NONE };
	EGLSync sync = eglCreateSync( (EGLDisplay)display, EGL_SYNC_METAL_SHARED_EVENT_ANGLE, attrs );

	if ( sync == EGL_NO_SYNC )
		return 0;
	glFlush();
	eglDestroySync( (EGLDisplay)display, sync );
	return 1;
}

void VOS_GL_Finish( void )
{
	glFinish();
}
