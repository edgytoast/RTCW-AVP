/*
 * Flat (windowed) presentation (M6). Same scheme as immersive mode: ANGLE renders
 * into our own BGRA8 MTLTexture (EGLImage-backed FBO); a Metal pass presents it into
 * the window's CAMetalLayer with gamma (vr_gamma, stands in for RTCW's hardware gamma)
 * and aspect-preserving letterboxing, so window resizes need no renderer restart.
 */

#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#include <simd/simd.h>

#include "vos_xr_gl.h"
#include "vos_flat.h"

extern void Com_Printf( const char *fmt, ... ) __attribute__(( format( printf, 1, 2 ) ));
extern float Cvar_VariableValue( const char *name );
extern void *Cvar_Get( const char *name, const char *value, int flags );

static CAMetalLayer *layer;
static id<MTLDevice> device;
static id<MTLCommandQueue> queue;
static id<MTLRenderPipelineState> pipeline;
static id<MTLTexture> target;
static vosEyeGL_t targetGL;
static int targetW, targetH;

int VOS_Flat_Init( void *eglDisplay, void *metalLayer, int width, int height )
{
	static const char *src =
		"#include <metal_stdlib>\n"
		"using namespace metal;\n"
		"struct V { float4 pos [[position]]; float2 uv; };\n"
		"vertex V vs( uint id [[vertex_id]], constant float2 &scale [[buffer(0)]] ) {\n"
		"  float2 p = float2( ( id << 1 ) & 2, id & 2 );\n"
		"  V o; o.pos = float4( ( p * 2.0 - 1.0 ) * scale, 0.0, 1.0 ); o.uv = float2( p.x, 1.0 - p.y ); return o; }\n"
		"fragment float4 fs( V in [[stage_in]], texture2d<float> t [[texture(0)]], constant float &gamma [[buffer(0)]], constant float &sharpen [[buffer(1)]] ) {\n"
		"  constexpr sampler s( filter::linear );\n"
		"  float2 px = 1.0 / float2( t.get_width(), t.get_height() );\n"
		"  float3 c = t.sample( s, in.uv ).rgb;\n"
		"  float3 n = t.sample( s, in.uv + float2( px.x, 0 ) ).rgb + t.sample( s, in.uv - float2( px.x, 0 ) ).rgb\n"
		"           + t.sample( s, in.uv + float2( 0, px.y ) ).rgb + t.sample( s, in.uv - float2( 0, px.y ) ).rgb;\n"
		"  c = saturate( c + sharpen * ( c - n * 0.25 ) );\n"
		"  return float4( pow( c, float3( 1.0 / gamma ) ), 1.0 ); }\n";
	NSError *err = nil;
	id<MTLLibrary> lib;
	MTLRenderPipelineDescriptor *pd;
	MTLTextureDescriptor *td;

	Cvar_Get( "vr_gamma", "1.3", 1 /* CVAR_ARCHIVE */ );
	Cvar_Get( "vr_sharpen", "0.3", 1 );
	layer = (__bridge CAMetalLayer *)metalLayer;
	device = MTLCreateSystemDefaultDevice();
	layer.device = device;
	layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
	layer.framebufferOnly = YES;
	queue = [device newCommandQueue];

	lib = [device newLibraryWithSource:@(src) options:nil error:&err];
	if ( !lib ) {
		Com_Printf( "VOS flat: shader failed: %s\n", err.localizedDescription.UTF8String );
		return 0;
	}
	pd = [MTLRenderPipelineDescriptor new];
	pd.vertexFunction = [lib newFunctionWithName:@"vs"];
	pd.fragmentFunction = [lib newFunctionWithName:@"fs"];
	pd.colorAttachments[0].pixelFormat = layer.pixelFormat;
	pipeline = [device newRenderPipelineStateWithDescriptor:pd error:&err];
	if ( !pipeline ) {
		Com_Printf( "VOS flat: pipeline failed: %s\n", err.localizedDescription.UTF8String );
		return 0;
	}

	td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
		width:width height:height mipmapped:NO];
	td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
	td.storageMode = MTLStorageModePrivate;
	target = [device newTextureWithDescriptor:td];
	targetW = width;
	targetH = height;
	if ( !VOS_GL_CreateEyeTarget( eglDisplay, (__bridge void *)target, width, height, &targetGL ) )
		return 0;
	VOS_GL_BindTarget( &targetGL );
	Com_Printf( "VOS flat: %dx%d render target, Metal present\n", width, height );
	return 1;
}

void VOS_Flat_Bind( void )
{
	VOS_GL_BindTarget( &targetGL );
}

void VOS_Flat_Present( void )
{
	id<CAMetalDrawable> drawable;
	id<MTLCommandBuffer> cmd;
	id<MTLRenderCommandEncoder> enc;
	MTLRenderPassDescriptor *rp;
	float gamma = Cvar_VariableValue( "vr_gamma" ), sharpen = Cvar_VariableValue( "vr_sharpen" ), dw, dh, ta, da;
	simd_float2 scale = { 1, 1 };

	VOS_GL_Finish();   // ANGLE's work must land before Metal samples the texture

	drawable = [layer nextDrawable];
	if ( !drawable ) {
		VOS_GL_BindTarget( &targetGL );
		return;
	}
	if ( gamma <= 0 )
		gamma = 1.3f;

	// Letterbox: keep the render target's aspect inside the (possibly resized) window.
	dw = drawable.texture.width;
	dh = drawable.texture.height;
	ta = (float)targetW / targetH;
	da = dw / dh;
	if ( da > ta ) scale.x = ta / da; else scale.y = da / ta;

	rp = [MTLRenderPassDescriptor renderPassDescriptor];
	rp.colorAttachments[0].texture = drawable.texture;
	rp.colorAttachments[0].loadAction = MTLLoadActionClear;
	rp.colorAttachments[0].clearColor = MTLClearColorMake( 0, 0, 0, 1 );
	rp.colorAttachments[0].storeAction = MTLStoreActionStore;

	cmd = [queue commandBuffer];
	enc = [cmd renderCommandEncoderWithDescriptor:rp];
	[enc setRenderPipelineState:pipeline];
	[enc setVertexBytes:&scale length:sizeof( scale ) atIndex:0];
	[enc setFragmentTexture:target atIndex:0];
	[enc setFragmentBytes:&gamma length:sizeof( gamma ) atIndex:0];
	[enc setFragmentBytes:&sharpen length:sizeof( sharpen ) atIndex:1];
	[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
	[enc endEncoding];
	[cmd presentDrawable:drawable];
	[cmd commit];

	VOS_GL_BindTarget( &targetGL );
}
