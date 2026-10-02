// GLES helpers for immersive eye targets (vos_xr_gl.c).
#ifndef VOS_XR_GL_H
#define VOS_XR_GL_H

typedef struct {
	void *image;                 // EGLImageKHR wrapping our MTLTexture
	unsigned int tex, fbo, depth;
	unsigned int msaaFbo, msaaColor, msaaDepth;   // MSAA render target (samples > 1)
	int width, height, samples;
} vosEyeGL_t;

// samples: 0/1 = no MSAA, 2 or 4 = render into a multisampled FBO, resolved by VOS_GL_Resolve.
int  VOS_GL_CreateEyeTarget( void *display, void *mtlTexture, int width, int height, vosEyeGL_t *out );
int  VOS_GL_CreateEyeTargetMS( void *display, void *mtlTexture, int width, int height, int samples, vosEyeGL_t *out );
void VOS_GL_Resolve( const vosEyeGL_t *t );
void VOS_GL_DestroyEyeTarget( void *display, vosEyeGL_t *t );
void VOS_GL_BindTarget( const vosEyeGL_t *t );
void VOS_GL_Blit( const vosEyeGL_t *src, const vosEyeGL_t *dst, int w, int h );
void VOS_GL_ForceOpaque( const vosEyeGL_t *t );
void VOS_GL_ClearColor( const vosEyeGL_t *t, float r, float g, float b );
int  VOS_GL_SignalSharedEvent( void *display, void *mtlSharedEvent, unsigned long long value );
void VOS_GL_Finish( void );

#endif
