// visionOS immersive rendering bridge (ADR-003). C interface used by the
// renderer (vos_glimp.c) and the Swift host.
#ifndef VOS_XR_H
#define VOS_XR_H

#ifdef __cplusplus
extern "C" {
#endif

// Swift: hand over the CompositorLayer's LayerRenderer before VOS_EngineInit.
void VOS_XR_SetLayerRenderer( void *layerRenderer );

// Nonzero when running in immersive mode.
int VOS_XR_Active( void );

// Renderer, on the engine thread with the EGL context current: acquires the
// first frame and returns the per-eye render size.
int VOS_XR_Init( void *eglDisplay, int *width, int *height );

// Renderer: present the current frame, acquire and bind the next one.
void VOS_XR_EndFrame( void );

unsigned long long VOS_XR_FramesPresented( void );

// Stereo (M3b)
int  VOS_XR_EyeCount( void );
void VOS_XR_BindEye( int eye );
// Per-eye tangents {left, right, top, bottom} and eye x offset in meters (device space).
int  VOS_XR_GetEye( int eye, float tangents[4], float *offsetX );
void VOS_XR_SetStereoRendering( int on );
int  VOS_XR_StereoRendering( void );

// Virtual screen (M5): client asks per frame; returns `want`. Renderer binds it for STEREO_CENTER.
int  VOS_XR_UseScreen( int want );
void VOS_XR_BindScreen( void );
int  VOS_XR_ScreenMode( void );

// HUD in VR: ortho bounds {left, right, bottom, top} for 2D drawn into the bound eye.
int  VOS_XR_Hud2D( int w, int h, float ortho[4] );

#ifdef __cplusplus
}
#endif

#endif
