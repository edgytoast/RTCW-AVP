/*
 * visionOS audio DMA (replaces iortcw code/sdl/sdl_snd.c). The engine mixer
 * paints 16-bit interleaved stereo into dma.buffer; an AVAudioSourceNode pulls
 * from it on the render thread, the same ring-buffer scheme as sdl_snd.c's
 * SNDDMA_AudioCallback. Spatial audio is M5+ work; this is plain stereo.
 */

#import <AVFAudio/AVFAudio.h>
#include <os/lock.h>

#include "client/snd_local.h"

#define VOS_SND_RATE     44100
#define VOS_SND_CHANNELS 2

static AVAudioEngine *engine;
static AVAudioSourceNode *source;
static os_unfair_lock dmaLock = OS_UNFAIR_LOCK_INIT;
static int dmapos;      // in samples (mono samples, like sdl_snd.c)
static int dmasize;     // in bytes

qboolean SNDDMA_Init( void )
{
	NSError *err = nil;
	AVAudioFormat *fmt;

	if ( engine )
		return qtrue;

	[[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:&err];
	[[AVAudioSession sharedInstance] setActive:YES error:&err];

	dma.samplebits = 16;
	dma.isfloat = qfalse;
	dma.channels = VOS_SND_CHANNELS;
	dma.speed = VOS_SND_RATE;
	dma.samples = 1024 * VOS_SND_CHANNELS * 10;   // same sizing rule as sdl_snd.c
	dma.fullsamples = dma.samples / dma.channels;
	dma.submission_chunk = 1;
	dmasize = dma.samples * ( dma.samplebits / 8 );
	dma.buffer = calloc( 1, dmasize );
	dmapos = 0;

	fmt = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:VOS_SND_RATE channels:VOS_SND_CHANNELS];
	source = [[AVAudioSourceNode alloc] initWithFormat:fmt renderBlock:
		^OSStatus( BOOL *isSilence, const AudioTimeStamp *ts, AVAudioFrameCount frames, AudioBufferList *out ) {
			float *l = (float *)out->mBuffers[0].mData;
			float *r = out->mNumberBuffers > 1 ? (float *)out->mBuffers[1].mData : NULL;
			const short *buf = (const short *)dma.buffer;
			AVAudioFrameCount i;

			os_unfair_lock_lock( &dmaLock );
			for ( i = 0; i < frames; i++ ) {
				if ( dmapos >= dma.samples )
					dmapos = 0;
				l[i] = buf[ dmapos ] / 32768.0f;
				if ( r ) r[i] = buf[ dmapos + 1 ] / 32768.0f;
				dmapos += VOS_SND_CHANNELS;
			}
			os_unfair_lock_unlock( &dmaLock );
			return noErr;
		}];

	engine = [[AVAudioEngine alloc] init];
	[engine attachNode:source];
	[engine connect:source to:engine.mainMixerNode format:fmt];
	if ( ![engine startAndReturnError:&err] ) {
		Com_Printf( "SNDDMA_Init: AVAudioEngine failed: %s\n", err.localizedDescription.UTF8String );
		SNDDMA_Shutdown();
		return qfalse;
	}

	Com_Printf( "SNDDMA_Init: AVAudioEngine %d Hz, %d ch, %d-bit, %d samples\n",
		dma.speed, dma.channels, dma.samplebits, dma.samples );
	return qtrue;
}

int SNDDMA_GetDMAPos( void )
{
	return dmapos;
}

void SNDDMA_Shutdown( void )
{
	[engine stop];
	engine = nil;
	source = nil;
	free( dma.buffer );
	dma.buffer = NULL;
	dmapos = dmasize = 0;
}

void SNDDMA_BeginPainting( void )
{
	os_unfair_lock_lock( &dmaLock );
}

void SNDDMA_Submit( void )
{
	os_unfair_lock_unlock( &dmaLock );
}

#ifdef USE_VOIP
void SNDDMA_StartCapture( void ) {}
int SNDDMA_AvailableCaptureSamples( void ) { return 0; }
void SNDDMA_Capture( int samples, byte *data ) {}
void SNDDMA_StopCapture( void ) {}
void SNDDMA_MasterGain( float val ) {}
#endif
