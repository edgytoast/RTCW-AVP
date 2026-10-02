/*
 * Head pose -> Quake view angles (M4, ADR-003). Pure C, unit-tested on the Mac
 * (tests/test_headpose.c, scripts/test-headpose.sh).
 *
 * ARKit/Compositor space: right-handed, +X right, +Y up, -Z forward.
 * Quake space: +X forward, +Y left, +Z up. Mapping: quake(v) = (-v.z, -v.x, v.y).
 *
 * Head/body split (RTCWQuest cl_input.c): pitch comes from the head; the head's
 * yaw *delta* is added to the body yaw, so stick turning and head turning add up;
 * roll is applied by the renderer only (no gameplay effect).
 */
#include <math.h>
#include "vos_headpose.h"

#define RAD2DEG( a ) ( (a) * 57.29577951308232f )

static float headAngles[3];   // PITCH, YAW, ROLL (Quake degrees)
static float headPos[3];      // Quake basis (x fwd, y left, z up), meters, world
static float refPos[3];
static int haveRef;
static float pitchOffset;     // gyro fine-aim on top of head pitch (degrees)
static int headValid;
static float lastYaw;
static int haveLastYaw;

void VOS_PoseToAngles( const float m[16], float angles[3] )
{
	// Column-major: columns 0,1,2 are the head's right, up, back axes in world space.
	const float *c0 = m, *c1 = m + 4, *c2 = m + 8;
	float fx = c2[2], fy = c2[0], fz = -c2[1];     // forward = quake(-back) = (back.z, back.x, -back.y)
	float lz = -c0[1];                             // left.z  = quake(-right).z = -right.y
	float uz = c1[1];                              // up.z    = quake(up).z = up.y
	float cp;

	if ( fz > 1.0f ) fz = 1.0f;
	if ( fz < -1.0f ) fz = -1.0f;
	angles[0] = -RAD2DEG( asinf( fz ) );            // PITCH: positive looks down
	angles[1] = RAD2DEG( atan2f( fy, fx ) );        // YAW: positive turns left
	cp = cosf( asinf( fz ) );
	angles[2] = cp > 1e-4f ? RAD2DEG( atan2f( lz, uz ) ) : 0.0f;   // ROLL
}

static float AngleDelta( float a, float b )
{
	float d = fmodf( a - b, 360.0f );
	if ( d > 180.0f ) d -= 360.0f;
	if ( d < -180.0f ) d += 360.0f;
	return d;
}

void VOS_PoseToPosition( const float m[16], float pos[3] )
{
	pos[0] = -m[14];   // quake(v) = (-v.z, -v.x, v.y) on the translation column
	pos[1] = -m[12];
	pos[2] = m[13];
}

void VOS_Head_SetPose( const float m[16] )
{
	VOS_PoseToAngles( m, headAngles );
	VOS_PoseToPosition( m, headPos );
	if ( !haveRef ) {
		refPos[0] = headPos[0]; refPos[1] = headPos[1]; refPos[2] = headPos[2];
		haveRef = 1;
	}
	headValid = 1;
}

void VOS_Head_Recenter( void )
{
	haveRef = 0;
	pitchOffset = 0;
}

void VOS_Head_AddPitchOffset( float deg, float limit )
{
	pitchOffset += deg;
	if ( pitchOffset > limit ) pitchOffset = limit;
	if ( pitchOffset < -limit ) pitchOffset = -limit;
}

int VOS_Head_PositionOffset( float bodyYawDeg, float maxHorizontal, float out[3] )
{
	float d[3], k, c, s, len;

	if ( !headValid || !haveRef )
		return 0;
	d[0] = headPos[0] - refPos[0];
	d[1] = headPos[1] - refPos[1];
	d[2] = headPos[2] - refPos[2];
	// Tracking space -> game world: rotate by the offset between body yaw and head yaw.
	k = ( bodyYawDeg - headAngles[1] ) * 0.017453292f;
	c = cosf( k ); s = sinf( k );
	out[0] = d[0] * c - d[1] * s;
	out[1] = d[0] * s + d[1] * c;
	out[2] = d[2];
	len = sqrtf( out[0] * out[0] + out[1] * out[1] );
	if ( maxHorizontal > 0 && len > maxHorizontal ) {
		out[0] *= maxHorizontal / len;
		out[1] *= maxHorizontal / len;
	}
	return 1;
}

void VOS_Head_Invalidate( void )
{
	headValid = 0;
}

int VOS_Head_ApplyToViewAngles( float viewangles[3] )
{
	if ( !headValid )
		return 0;
	if ( haveLastYaw )
		viewangles[1] += AngleDelta( headAngles[1], lastYaw );
	lastYaw = headAngles[1];
	haveLastYaw = 1;
	viewangles[0] = headAngles[0] + pitchOffset;
	return 1;
}

float VOS_Head_Roll( void )
{
	return headValid ? headAngles[2] : 0.0f;
}
