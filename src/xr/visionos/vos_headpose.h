// Head pose -> Quake angles and head/body split (vos_headpose.c).
#ifndef VOS_HEADPOSE_H
#define VOS_HEADPOSE_H

// m: column-major 4x4 origin-from-device transform (ARKit). angles: PITCH, YAW, ROLL.
void  VOS_PoseToAngles( const float m[16], float angles[3] );

void  VOS_Head_SetPose( const float m[16] );    // XR thread, once per frame
void  VOS_Head_Invalidate( void );
// Client (CL_CreateCmd): pitch from head, yaw += head yaw delta. Returns 1 if applied.
int   VOS_Head_ApplyToViewAngles( float viewangles[3] );
// Head position in Quake basis (meters).
void  VOS_PoseToPosition( const float m[16], float pos[3] );
// Head displacement since the reference (first pose / recenter), in game-world axes for the
// given body yaw, horizontal part clamped to maxHorizontal meters. Returns 1 if valid.
int   VOS_Head_PositionOffset( float bodyYawDeg, float maxHorizontal, float out[3] );
void  VOS_Head_Recenter( void );          // also clears the gyro pitch offset
// Gyro fine-aim (M5): pitch offset added on top of head pitch, clamped to +/-limit degrees.
void  VOS_Head_AddPitchOffset( float deg, float limit );
// Renderer: head roll in degrees (0 when no pose).
float VOS_Head_Roll( void );

#endif
