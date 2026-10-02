// C interface the Swift host uses to drive the engine (ADR-003).
#ifndef VOS_ENGINE_H
#define VOS_ENGINE_H

#ifdef __cplusplus
extern "C" {
#endif

// Give the renderer its CAMetalLayer (pixel size) before VOS_EngineInit.
void VOS_SetNativeLayer( void *layer, int pixelWidth, int pixelHeight );

// Call once on the engine thread. installDir holds main/*.pk3.
void VOS_EngineInit( const char *installDir, const char *homeDir, const char *commandLine );

// Call once per frame on the engine thread.
void VOS_EngineFrame( void );

#ifdef __cplusplus
}
#endif

#endif
