// Flat-mode presentation via Metal (vos_flat.m).
#ifndef VOS_FLAT_H
#define VOS_FLAT_H
int  VOS_Flat_Init( void *eglDisplay, void *metalLayer, int width, int height );
void VOS_Flat_Bind( void );
void VOS_Flat_Present( void );
#endif
