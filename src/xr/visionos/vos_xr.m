/*
 * visionOS immersive rendering (ADR-002/ADR-003, M3).
 *
 * The engine thread drives Compositor Services: at the end of every engine
 * frame (GLimp_EndFrame) the current drawable is presented and the next one is
 * acquired, so the whole next Com_Frame renders into it. ANGLE renders each eye
 * into our own BGRA8 MTLTexture (wrapped as an EGLImage via
 * EGL_ANGLE_metal_texture_client_buffer); a Metal pass then composites it into the
 * compositor's texture (RGBA16Float on device), converting sRGB -> linear and
 * clearing depth. Wrapping the compositor's RGBA16Float textures directly renders
 * nothing on hardware.
 *
 * Stereo (M3b): with two views the renderer runs with glConfig.stereoEnabled;
 * its DrawBuffer(GL_BACK_LEFT/RIGHT) binds the eye framebuffer (VOS_XR_BindEye)
 * and R_SetupProjection takes each eye's tangents and offset (VOS_XR_GetEye).
 */

#import <Metal/Metal.h>
#import <CompositorServices/CompositorServices.h>
#import <ARKit/ARKit.h>
#include <TargetConditionals.h>

#include "vos_xr.h"
#include "vos_xr_gl.h"
#include "vos_headpose.h"

// Log to the engine console (rtcwconsole.log, fetched by `make headset-log`).
extern void Com_Printf( const char *fmt, ... ) __attribute__(( format( printf, 1, 2 ) ));
extern float Cvar_VariableValue( const char *name );
extern void Cvar_Set( const char *name, const char *value );
extern void *Cvar_Get( const char *name, const char *value, int flags );
#define VOS_CVAR_ARCHIVE 0x0001
#define XR_LOG( fmt, ... ) Com_Printf( "VOS XR: " fmt "\n", ##__VA_ARGS__ )

#define MAX_EYES 2

typedef struct {
	id<MTLTexture> texture;   // our BGRA8 render target (ANGLE draws here)
	vosEyeGL_t gl;
	int width, height;
} eyeTarget_t;

static cp_layer_renderer_t layerRenderer;
static id<MTLDevice> device;
static id<MTLCommandQueue> presentQueue;
static id<MTLRenderPipelineState> compositePipeline;
static id<MTLDepthStencilState> compositeDepthState;
static id<MTLSharedEvent> glDoneEvent;     // vr_sync 1: ANGLE -> Metal GPU-side sync
static unsigned long long glDoneValue;
static int syncFallbacks;
static void *eglDisplay;

static eyeTarget_t eyes[ MAX_EYES ];

// Virtual screen (M5, issue #1): menus/cinematics are drawn once into `screen` and shown
// on a world-locked quad placed in front of the user when screen mode starts.
static eyeTarget_t screen;
static int screenMode, screenWasOn;
static simd_float4x4 screenModel;
static simd_float4x4 headTransform;   // latest device pose (identity until tracked)
static id<MTLRenderPipelineState> quadPipeline;
static id<MTLDepthStencilState> quadDepthState;
#define SCREEN_DISTANCE  2.5f   // meters
#define SCREEN_HALF_W    1.2f   // 2.4 m wide, 4:3
#define SCREEN_HALF_H    0.9f

static cp_frame_t curFrame;
static cp_drawable_t curDrawable;
static eyeTarget_t *curEyes[ MAX_EYES ];
static int curEyeCount;
static int eyeWidth, eyeHeight;
static unsigned long long framesPresented;

static float CvarOr( const char *name, float def )
{
	float v = Cvar_VariableValue( name );
	return v > 0 ? v : def;
}

static int stereoRendering;
static int boundEye;          // eye whose FBO is bound, -1 = virtual screen

void VOS_XR_SetLayerRenderer( void *renderer )
{
	layerRenderer = (__bridge cp_layer_renderer_t)renderer;
}

int VOS_XR_Active( void )
{
	return layerRenderer != nil;
}

void VOS_XR_SetStereoRendering( int on )
{
	stereoRendering = on;
}

int VOS_XR_StereoRendering( void )
{
	return stereoRendering;
}

// ARKit world tracking: the compositor needs the device pose each frame (a drawable
// without a device anchor is not displayed on hardware). M4 also uses it for head pose.
#if !TARGET_OS_SIMULATOR
static ar_session_t arSession;
static ar_world_tracking_provider_t worldTracking;
static ar_device_anchor_t deviceAnchor;
#endif
static int anchorsSet, anchorsMissed;

static void StartWorldTracking( void )
{
#if !TARGET_OS_SIMULATOR
	if ( !ar_world_tracking_provider_is_supported() ) {
		XR_LOG( "world tracking not supported" );
		return;
	}
	worldTracking = ar_world_tracking_provider_create( ar_world_tracking_configuration_create() );
	arSession = ar_session_create();
	ar_session_run( arSession, ar_data_providers_create_with_data_providers( worldTracking, nil ) );
	deviceAnchor = ar_device_anchor_create();
	XR_LOG( "world tracking started" );
#endif
}

static void SetDeviceAnchor( cp_drawable_t drawable )
{
#if !TARGET_OS_SIMULATOR
	cp_frame_timing_t timing;
	CFTimeInterval t;

	if ( !worldTracking )
		return;
	timing = cp_drawable_get_frame_timing( drawable );
	t = cp_time_to_cf_time_interval( cp_frame_timing_get_presentation_time( timing ) );
	if ( ar_world_tracking_provider_query_device_anchor_at_timestamp( worldTracking, t, deviceAnchor )
			== ar_device_anchor_query_status_success ) {
		simd_float4x4 h = ar_anchor_get_origin_from_anchor_transform( deviceAnchor );
		cp_drawable_set_device_anchor( drawable, deviceAnchor );
		VOS_Head_SetPose( (const float *)&h );   // M4: head drives the game camera
		headTransform = h;
		anchorsSet++;
	} else {
		VOS_Head_Invalidate();
		anchorsMissed++;
	}
#endif
}

static int CreateEyeTargets( int width, int height, int count, int samples )
{
	int i;
	MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
		width:width height:height mipmapped:NO];
	d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
	d.storageMode = MTLStorageModePrivate;

	for ( i = 0; i < count; i++ ) {
		eyes[i].texture = [device newTextureWithDescriptor:d];
		eyes[i].width = width;
		eyes[i].height = height;
		if ( !VOS_GL_CreateEyeTargetMS( eglDisplay, (__bridge void *)eyes[i].texture, width, height, samples, &eyes[i].gl ) ) {
			XR_LOG( "eye %d render target failed", i );
			return 0;
		}
	}
	// Same size as an eye: the renderer's 2D/viewport code uses glConfig.vidWidth/Height.
	screen.texture = [device newTextureWithDescriptor:d];
	screen.width = width;
	screen.height = height;
	if ( !VOS_GL_CreateEyeTarget( eglDisplay, (__bridge void *)screen.texture, width, height, &screen.gl ) ) {
		XR_LOG( "screen render target failed" );
		return 0;
	}
	return 1;
}

static int CreateCompositePipeline( MTLPixelFormat colorFormat, MTLPixelFormat depthFormat )
{
	// The fragment stage also writes depth: on hardware the compositor treats depth 0
	// (reverse-Z infinity) as "no content", so a full-screen image at depth 0 is invisible.
	static const char *src =
		"#include <metal_stdlib>\n"
		"using namespace metal;\n"
		"struct V { float4 pos [[position]]; float2 uv; };\n"
		"struct F { float4 color [[color(0)]]; float depth [[depth(any)]]; };\n"
		"vertex V vs( uint id [[vertex_id]] ) {\n"
		"  float2 p = float2( ( id << 1 ) & 2, id & 2 );\n"
		"  V o; o.pos = float4( p * 2.0 - 1.0, 0.0, 1.0 ); o.uv = float2( p.x, 1.0 - p.y ); return o; }\n"
		"fragment F fs( V in [[stage_in]], texture2d<float> t [[texture(0)]], constant float &depth [[buffer(0)]], constant float &gamma [[buffer(1)]], constant float &sharpen [[buffer(2)]] ) {\n"
		"  constexpr sampler s( filter::linear );\n"
		"  float2 px = 1.0 / float2( t.get_width(), t.get_height() );\n"
		"  float3 c = t.sample( s, in.uv ).rgb;\n"
		"  float3 n = t.sample( s, in.uv + float2( px.x, 0 ) ).rgb + t.sample( s, in.uv - float2( px.x, 0 ) ).rgb\n"
		"           + t.sample( s, in.uv + float2( 0, px.y ) ).rgb + t.sample( s, in.uv - float2( 0, px.y ) ).rgb;\n"
		"  c = saturate( c + sharpen * ( c - n * 0.25 ) );  // unsharp mask (vr_sharpen)\n"
		"  c = pow( c, float3( 1.0 / gamma ) );  // stands in for RTCW's hardware gamma\n"
		"  c = select( pow( ( c + 0.055 ) / 1.055, 2.4 ), c / 12.92, c <= 0.04045 );  // sRGB -> linear\n"
		"  F o; o.color = float4( c, 1.0 ); o.depth = depth; return o; }\n"
		"vertex V vsQuad( uint id [[vertex_id]], constant float4x4 &mvp [[buffer(1)]] ) {\n"
		"  float2 c = float2( ( id & 1 ) ? 1.0 : -1.0, ( id & 2 ) ? 1.0 : -1.0 );\n"
		"  V o; o.pos = mvp * float4( c, 0.0, 1.0 ); o.uv = float2( c.x * 0.5 + 0.5, 0.5 - c.y * 0.5 ); return o; }\n"
		"fragment float4 fsQuad( V in [[stage_in]], texture2d<float> t [[texture(0)]], constant float &gamma [[buffer(0)]] ) {\n"
		"  constexpr sampler s( filter::linear, address::clamp_to_edge );\n"
		"  float3 c = pow( t.sample( s, in.uv ).rgb, float3( 1.0 / gamma ) );\n"
		"  c = select( pow( ( c + 0.055 ) / 1.055, 2.4 ), c / 12.92, c <= 0.04045 );\n"
		"  return float4( c, 1.0 ); }\n";
	NSError *err = nil;
	id<MTLLibrary> lib = [device newLibraryWithSource:@(src) options:nil error:&err];
	MTLRenderPipelineDescriptor *pd;

	if ( !lib ) {
		XR_LOG( "composite shader failed: %s", err.localizedDescription.UTF8String );
		return 0;
	}
	pd = [MTLRenderPipelineDescriptor new];
	pd.vertexFunction = [lib newFunctionWithName:@"vs"];
	pd.fragmentFunction = [lib newFunctionWithName:@"fs"];
	pd.colorAttachments[0].pixelFormat = colorFormat;
	pd.depthAttachmentPixelFormat = depthFormat;
	{
		MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new];
		dd.depthCompareFunction = MTLCompareFunctionAlways;
		dd.depthWriteEnabled = YES;
		compositeDepthState = [device newDepthStencilStateWithDescriptor:dd];
	}
	compositePipeline = [device newRenderPipelineStateWithDescriptor:pd error:&err];
	if ( !compositePipeline ) {
		XR_LOG( "composite pipeline failed: %s", err.localizedDescription.UTF8String );
		return 0;
	}

	pd.vertexFunction = [lib newFunctionWithName:@"vsQuad"];
	pd.fragmentFunction = [lib newFunctionWithName:@"fsQuad"];
	quadPipeline = [device newRenderPipelineStateWithDescriptor:pd error:&err];
	if ( !quadPipeline ) {
		XR_LOG( "quad pipeline failed: %s", err.localizedDescription.UTF8String );
		return 0;
	}
	{
		MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new];
		dd.depthCompareFunction = MTLCompareFunctionGreater;   // reverse-Z
		dd.depthWriteEnabled = YES;
		quadDepthState = [device newDepthStencilStateWithDescriptor:dd];
	}
	return 1;
}

// Reverse-Z projection from compositor tangents (magnitudes left,right,top,bottom) and depth range (far, near).
static simd_float4x4 EyeProjection( simd_float4 t, simd_float2 range )
{
	float l = t.x, r = t.y, tp = t.z, b = t.w, f = range.x, n = range.y;
	float A = isinf( f ) ? 0.0f : n / ( f - n ), B = isinf( f ) ? n : n * f / ( f - n );
	simd_float4x4 P = { {
		{ 2.0f / ( l + r ), 0, 0, 0 },
		{ 0, 2.0f / ( tp + b ), 0, 0 },
		{ ( r - l ) / ( l + r ), ( tp - b ) / ( tp + b ), A, -1.0f },
		{ 0, 0, B, 0 } } };
	return P;
}

static void PlaceScreen( void )
{
	simd_float3 pos = headTransform.columns[3].xyz;
	simd_float3 fwd = -headTransform.columns[2].xyz;
	simd_float3 flat = simd_normalize( simd_make_float3( fwd.x, 0, fwd.z ) );
	simd_float3 right = simd_make_float3( -flat.z, 0, flat.x );
	simd_float3 center = pos + flat * SCREEN_DISTANCE;

	if ( !isfinite( flat.x ) )   // looking straight up/down: face -Z
		flat = simd_make_float3( 0, 0, -1 ), right = simd_make_float3( 1, 0, 0 ), center = pos + flat * SCREEN_DISTANCE;
	screenModel = (simd_float4x4){ {
		simd_make_float4( right * SCREEN_HALF_W, 0 ),
		simd_make_float4( 0, SCREEN_HALF_H, 0, 0 ),
		simd_make_float4( -flat, 0 ),
		simd_make_float4( center, 1 ) } };
	XR_LOG( "virtual screen placed %.2f m ahead", SCREEN_DISTANCE );
}

int VOS_XR_UseScreen( int want )
{
	if ( want && !screenWasOn )
		PlaceScreen();
	screenWasOn = want;
	screenMode = want;
	return want;
}

int VOS_XR_ScreenMode( void )
{
	return screenMode;
}

void VOS_XR_BindScreen( void )
{
	boundEye = -1;
	if ( screen.texture )
		VOS_GL_BindTarget( &screen.gl );
}

// Draw the virtual screen quad into each eye (black, depth-0 background = nothing).
static void CompositeScreen( id<MTLCommandBuffer> cmd )
{
	int i;
	float gamma = CvarOr( "vr_gamma", 1.3f );
	simd_float2 range = cp_drawable_get_depth_range( curDrawable );

	for ( i = 0; i < curEyeCount; i++ ) {
		cp_view_t view = cp_drawable_get_view( curDrawable, i );
		simd_float4x4 eyeWorld = simd_mul( headTransform, cp_view_get_transform( view ) );
		simd_float4x4 mvp = simd_mul( EyeProjection( cp_view_get_tangents( view ), range ),
			simd_mul( simd_inverse( eyeWorld ), screenModel ) );
		MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
		id<MTLRenderCommandEncoder> enc;

		rp.colorAttachments[0].texture = cp_drawable_get_color_texture( curDrawable, i );
		rp.colorAttachments[0].loadAction = MTLLoadActionClear;
		rp.colorAttachments[0].clearColor = MTLClearColorMake( 0, 0, 0, 1 );
		rp.colorAttachments[0].storeAction = MTLStoreActionStore;
		rp.depthAttachment.texture = cp_drawable_get_depth_texture( curDrawable, i );
		rp.depthAttachment.loadAction = MTLLoadActionClear;
		rp.depthAttachment.clearDepth = 0.0;
		rp.depthAttachment.storeAction = MTLStoreActionStore;

		enc = [cmd renderCommandEncoderWithDescriptor:rp];
		[enc setRenderPipelineState:quadPipeline];
		[enc setDepthStencilState:quadDepthState];
		[enc setVertexBytes:&mvp length:sizeof( mvp ) atIndex:1];
		[enc setFragmentTexture:screen.texture atIndex:0];
		[enc setFragmentBytes:&gamma length:sizeof( gamma ) atIndex:0];
		[enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
		[enc endEncoding];
	}
}

// Copy each eye into the compositor's textures (format conversion + depth clear to far, reverse-Z 0).
static void Composite( id<MTLCommandBuffer> cmd )
{
	int i;
	// Reverse-Z depth of a point 10 m away: d = n (f - z) / (z (f - n)); depthRange = (far, near).
	simd_float2 range = cp_drawable_get_depth_range( curDrawable );
	float f = range.x, n = range.y, z = 10.0f;
	float depth = isinf( f ) ? n / z : n * ( f - z ) / ( z * ( f - n ) );
	float gamma = CvarOr( "vr_gamma", 1.3f );
	float sharpen = Cvar_VariableValue( "vr_sharpen" );

	if ( ( framesPresented % 900 ) == 0 )
		XR_LOG( "composite depth %.5f (near %.3f far %.1f)", depth, n, f );
	for ( i = 0; i < curEyeCount; i++ ) {
		MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
		id<MTLRenderCommandEncoder> enc;

		rp.colorAttachments[0].texture = cp_drawable_get_color_texture( curDrawable, i );
		rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
		rp.colorAttachments[0].storeAction = MTLStoreActionStore;
		rp.depthAttachment.texture = cp_drawable_get_depth_texture( curDrawable, i );
		rp.depthAttachment.loadAction = MTLLoadActionClear;
		rp.depthAttachment.clearDepth = 0.0;
		rp.depthAttachment.storeAction = MTLStoreActionStore;

		enc = [cmd renderCommandEncoderWithDescriptor:rp];
		[enc setRenderPipelineState:compositePipeline];
		[enc setDepthStencilState:compositeDepthState];
		[enc setFragmentTexture:eyes[i].texture atIndex:0];
		[enc setFragmentBytes:&depth length:sizeof( depth ) atIndex:0];
		[enc setFragmentBytes:&gamma length:sizeof( gamma ) atIndex:1];
		[enc setFragmentBytes:&sharpen length:sizeof( sharpen ) atIndex:2];
		[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
		[enc endEncoding];
	}
}

// Acquire the next compositor frame and bind eye 0 for the engine to draw into.
static int AcquireFrame( void )
{
	cp_frame_timing_t timing;
	cp_drawable_array_t drawables;
	size_t i, n;

	for ( ;; ) {
		switch ( cp_layer_renderer_get_state( layerRenderer ) ) {
		case cp_layer_renderer_state_paused:
			cp_layer_renderer_wait_until_running( layerRenderer );
			continue;
		case cp_layer_renderer_state_invalidated:
			return 0;
		default:
			break;
		}
		break;
	}

	curFrame = cp_layer_renderer_query_next_frame( layerRenderer );
	if ( !curFrame )
		return 0;

	cp_frame_start_update( curFrame );
	cp_frame_end_update( curFrame );

	timing = cp_frame_predict_timing( curFrame );
	if ( timing )
		cp_time_wait_until( cp_frame_timing_get_optimal_input_time( timing ) );

	cp_frame_start_submission( curFrame );

	curDrawable = NULL;
	drawables = cp_frame_query_drawables( curFrame );
	n = drawables ? cp_drawable_array_get_count( drawables ) : 0;
	for ( i = 0; i < n; i++ ) {
		cp_drawable_t d = cp_drawable_array_get_drawable( drawables, i );
		if ( cp_drawable_get_target( d ) == cp_drawable_target_built_in ) {
			curDrawable = d;
			break;
		}
	}
	if ( !curDrawable ) {
		cp_frame_end_submission( curFrame );
		curFrame = NULL;
		return 0;
	}

	SetDeviceAnchor( curDrawable );

	// Dedicated layout: one compositor texture per view; we render into our own targets.
	curEyeCount = (int)MIN( cp_drawable_get_view_count( curDrawable ), MAX_EYES );
	for ( i = 0; i < (size_t)curEyeCount; i++ )
		curEyes[i] = &eyes[i];

	if ( eyes[0].texture )
		VOS_GL_BindTarget( &eyes[0].gl );
	boundEye = 0;
	return 1;
}

int VOS_XR_Init( void *display, int *width, int *height )
{
	id<MTLTexture> ct, dt;

	eglDisplay = display;
	headTransform = matrix_identity_float4x4;
	device = cp_layer_renderer_get_device( layerRenderer );
	presentQueue = [device newCommandQueue];
	StartWorldTracking();

	if ( !AcquireFrame() )
		return 0;

	// Visual quality settings (M6), archived so console changes persist. Size/MSAA apply at launch.
	Cvar_Get( "vr_resolutionScale", "1.0", VOS_CVAR_ARCHIVE );
	Cvar_Get( "vr_msaa", "0", VOS_CVAR_ARCHIVE );
	Cvar_Get( "vr_sharpen", "0.3", VOS_CVAR_ARCHIVE );
	Cvar_Get( "vr_gamma", "1.3", VOS_CVAR_ARCHIVE );
	Cvar_Get( "vr_hudScale", "0.5", VOS_CVAR_ARCHIVE );
	Cvar_Get( "vr_hudDepth", "1.5", VOS_CVAR_ARCHIVE );
	Cvar_Get( "vr_sync", "0", VOS_CVAR_ARCHIVE );

	ct = cp_drawable_get_color_texture( curDrawable, 0 );
	dt = cp_drawable_get_depth_texture( curDrawable, 0 );
	{
		float scale = CvarOr( "vr_resolutionScale", 1.0f );
		int samples = (int)Cvar_VariableValue( "vr_msaa" );
		if ( scale < 0.5f ) scale = 0.5f;
		if ( scale > 1.5f ) scale = 1.5f;
		eyeWidth = (int)( ct.width * scale );
		eyeHeight = (int)( ct.height * scale );
		XR_LOG( "eye render target %dx%d (scale %.2f), MSAA %dx", eyeWidth, eyeHeight, scale, samples > 1 ? samples : 1 );
		if ( !CreateEyeTargets( eyeWidth, eyeHeight, curEyeCount, samples ) )
			return 0;
	}
	if (
		!CreateCompositePipeline( ct.pixelFormat, dt.pixelFormat ) )
		return 0;
	VOS_GL_BindTarget( &eyes[0].gl );

	// VR comfort (M5): no view bob or run tilt (cgame keeps existing cvar values).
	Cvar_Set( "cg_bobup", "0" );
	Cvar_Set( "cg_bobpitch", "0" );
	Cvar_Set( "cg_bobroll", "0" );
	Cvar_Set( "cg_runpitch", "0" );
	Cvar_Set( "cg_runroll", "0" );

	*width = eyeWidth;
	*height = eyeHeight;
	XR_LOG( "immersive, %d view(s), %dx%d per eye, color format %lu, depth format %lu, textures %zu",
		curEyeCount, eyeWidth, eyeHeight,
		(unsigned long)cp_drawable_get_color_texture( curDrawable, 0 ).pixelFormat,
		(unsigned long)cp_drawable_get_depth_texture( curDrawable, 0 ).pixelFormat,
		cp_drawable_get_texture_count( curDrawable ) );
	for ( int e = 0; e < curEyeCount; e++ ) {
		float t[4], x;
		if ( VOS_XR_GetEye( e, t, &x ) )
			XR_LOG( "eye %d tangents L%.3f R%.3f T%.3f B%.3f offset %.4f m", e, t[0], t[1], t[2], t[3], x );
	}
	return 1;
}

void VOS_XR_EndFrame( void )
{
	int i;
	id<MTLCommandBuffer> cmd;

	if ( !curFrame || !curDrawable ) {
		AcquireFrame();
		return;
	}

	// Mono fallback (stereo disabled): copy eye 0 to the other eyes.
	for ( i = 1; i < curEyeCount && !VOS_XR_StereoRendering(); i++ )
		VOS_GL_Blit( &curEyes[0]->gl, &curEyes[i]->gl, curEyes[0]->width, curEyes[0]->height );

	for ( i = 0; i < curEyeCount; i++ )
		VOS_GL_Resolve( &curEyes[i]->gl );   // MSAA -> eye texture (no-op without MSAA)

	cmd = [presentQueue commandBuffer];

	// Sync ANGLE's GL work before our Metal pass reads the eye textures.
	// vr_sync 1: GPU-side wait on a shared event (no CPU stall); default: glFinish.
	if ( Cvar_VariableValue( "vr_sync" ) >= 1.0f ) {
		if ( !glDoneEvent )
			glDoneEvent = [device newSharedEvent];
		if ( VOS_GL_SignalSharedEvent( eglDisplay, (__bridge void *)glDoneEvent, ++glDoneValue ) ) {
			[cmd encodeWaitForEvent:glDoneEvent value:glDoneValue];
		} else {
			syncFallbacks++;
			VOS_GL_Finish();
		}
	} else {
		VOS_GL_Finish();
	}
	if ( screenMode )
		CompositeScreen( cmd );
	else
		Composite( cmd );
	cp_drawable_encode_present( curDrawable, cmd );
	[cmd commit];
	cp_frame_end_submission( curFrame );
	curFrame = NULL;
	curDrawable = NULL;

	if ( ( ++framesPresented % 900 ) == 1 )
		XR_LOG( "presented frame %llu (device anchors set %d, missed %d, sync %s, fallbacks %d)", framesPresented,
			anchorsSet, anchorsMissed, Cvar_VariableValue( "vr_sync" ) >= 1.0f ? "event" : "finish", syncFallbacks );

	AcquireFrame();
}

// In-game 2D (HUD) in VR: scale it toward the view center (vr_hudScale) and give it
// stereo depth by shifting it per eye so it converges at vr_hudDepth meters.
int VOS_XR_Hud2D( int w, int h, float ortho[4] )
{
	float t[4], ex, s, d, cx, cy, left, top;

	if ( !layerRenderer || boundEye < 0 || screenMode || !VOS_XR_GetEye( boundEye, t, &ex ) )
		return 0;
	s = CvarOr( "vr_hudScale", 0.5f );
	d = CvarOr( "vr_hudDepth", 1.5f );
	cx = ( -ex / d + t[0] ) / ( t[0] + t[1] ) * w;   // HUD center: straight ahead at distance d
	cy = t[2] / ( t[2] + t[3] ) * h;                 // tangent 0 vertically (top-origin pixels)
	left = w * 0.5f - cx / s;
	top = h * 0.5f - cy / s;
	ortho[0] = left; ortho[1] = left + w / s;          // left, right
	ortho[2] = top + h / s; ortho[3] = top;            // bottom, top
	return 1;
}

int VOS_XR_EyeCount( void )
{
	return curEyeCount;
}

void VOS_XR_BindEye( int eye )
{
	boundEye = eye;
	if ( eye >= 0 && eye < curEyeCount && curEyes[eye] )
		VOS_GL_BindTarget( &curEyes[eye]->gl );
}

int VOS_XR_GetEye( int eye, float tangents[4], float *offsetX )
{
	cp_view_t view;
	simd_float4 t;

	if ( !curDrawable || eye < 0 || eye >= curEyeCount )
		return 0;
	view = cp_drawable_get_view( curDrawable, eye );
	t = cp_view_get_tangents( view );             // left, right, top, bottom (magnitudes)
	tangents[0] = t.x; tangents[1] = t.y; tangents[2] = t.z; tangents[3] = t.w;
	*offsetX = cp_view_get_transform( view ).columns[3].x;   // eye position in device space, meters
	return 1;
}

unsigned long long VOS_XR_FramesPresented( void )
{
	return framesPresented;
}
