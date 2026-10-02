/*
 * visionOS input (replaces iortcw code/sdl/sdl_input.c). DualSense-first via
 * GameController (ADR-003, M5 input priority). Polled on the engine thread in
 * IN_Frame; mirrors sdl_input.c IN_GamepadMove semantics (K_PAD0_* keys, SDL
 * axis conventions for CL_JoystickMove: axis 0/1 = left X/Y, 2/3 = right X/Y,
 * Y positive = down).
 *
 * Menus (UI/console key catcher): left stick or DualSense touchpad drives the
 * mouse cursor, touchpad press = click, cross = Enter (activates the focused
 * item), circle = escape, d-pad = arrow keys. Options button is always Escape.
 */

#import <GameController/GameController.h>

#include "client/client.h"
#include "vos_xr.h"
#include "vos_headpose.h"

enum { B_A, B_B, B_X, B_Y, B_BACK, B_GUIDE, B_START, B_LSTICK, B_RSTICK, B_LSHOULDER,
       B_RSHOULDER, B_DUP, B_DDOWN, B_DLEFT, B_DRIGHT, B_LTRIGGER, B_RTRIGGER, B_TOUCHPAD, B_COUNT };

static qboolean btnState[ B_COUNT ];
static int axisState[ 4 ];
static int simButton = -1, simFrames, simAt;
static cvar_t *in_joystickThreshold;
static cvar_t *in_menuCursorSpeed;
static cvar_t *in_padDebug;
static cvar_t *in_touchpadSpeed;
static cvar_t *vr_snapTurn;      // VR comfort: degrees per right-stick flick, 0 = smooth turn
static qboolean snapLatched;
static cvar_t *in_gyroAim;        // DualSense gyro fine-aim (M5)
static cvar_t *in_gyroSensitivity;
static int gyroLastMs;
static float touchPrevX, touchPrevY;
static qboolean touchActive;

static const char *defaultBinds[][2] = {
	{ "PAD0_RIGHTTRIGGER", "+attack" },
	{ "PAD0_LEFTTRIGGER", "weapalt" },
	{ "PAD0_RIGHTSHOULDER", "weapnext" },
	{ "PAD0_LEFTSHOULDER", "weapprev" },
	{ "PAD0_A", "+moveup" },
	{ "PAD0_B", "+movedown" },
	{ "PAD0_X", "+reload" },
	{ "PAD0_Y", "+activate" },
	{ "PAD0_LEFTSTICK_CLICK", "+sprint" },
	{ "PAD0_RIGHTSTICK_CLICK", "+kick" },
	{ "PAD0_DPAD_LEFT", "+leanleft" },
	{ "PAD0_DPAD_RIGHT", "+leanright" },
	{ "PAD0_DPAD_UP", "+zoom" },
	{ "PAD0_DPAD_DOWN", "notebook" },
	{ "PAD0_BACK", "+scores" },
	{ "PAD0_TOUCHPAD", "gyro_toggle" },
};

// The post-load "pregame" screen eats every key except MOUSE1 (cl_keys.c) and its
// only action is the forward arrow in the bottom-right corner (ui/pregame.menu).
static qboolean InPregame( void )
{
	return uivm && ( Key_GetCatcher() & KEYCATCH_UI ) &&
		VM_Call( uivm, UI_GET_ACTIVE_MENU ) == UIMENU_PREGAME;
}

static int ButtonKey( int b, qboolean menu )
{
	if ( b == B_START ) return K_ESCAPE;
	if ( menu ) {
		switch ( b ) {
		case B_A: return K_ENTER;    // activates the focused item (d-pad or cursor hover)
		case B_TOUCHPAD: return K_MOUSE1;                      // click at the cursor
		case B_B: return K_ESCAPE;
		case B_DUP: return K_UPARROW;
		case B_DDOWN: return K_DOWNARROW;
		case B_DLEFT: return K_LEFTARROW;
		case B_DRIGHT: return K_RIGHTARROW;
		default: break;
		}
	}
	switch ( b ) {
	case B_TOUCHPAD: return K_PAD0_TOUCHPAD;
	case B_LTRIGGER: return K_PAD0_LEFTTRIGGER;
	case B_RTRIGGER: return K_PAD0_RIGHTTRIGGER;
	default: return K_PAD0_A + b;   // A..DPAD_RIGHT follow SDL button order
	}
}

static void KeyEvent( int key, qboolean down )
{
	Com_QueueEvent( 0, SE_KEY, key, down, 0, NULL );
	if ( in_padDebug->integer || com_developer->integer )
		Com_Printf( "VOS pad: %s %s (catcher=0x%x state=%d)\n", Key_KeynumToString( key, qfalse ),
			down ? "down" : "up", Key_GetCatcher(), clc.state );
}

static int ScaleAxis( float v )
{
	float t = in_joystickThreshold->value;
	float f = ( fabsf( v ) - t ) / ( 1.0f - t );
	if ( f < 0.0f ) f = 0.0f;
	if ( f > 1.0f ) f = 1.0f;
	return (int)( 32767.0f * ( v < 0 ? -f : f ) );
}

static void IN_PadSim_f( void )
{
	if ( Cmd_Argc() < 2 ) {
		Com_Printf( "usage: vos_padsim <button 0-%d> [delay ms]\n", B_COUNT - 1 );
		return;
	}
	simButton = atoi( Cmd_Argv( 1 ) );
	simAt = Sys_Milliseconds() + ( Cmd_Argc() > 2 ? atoi( Cmd_Argv( 2 ) ) : 0 );
	simFrames = 3;
}

static void IN_GyroToggle_f( void )
{
	Cvar_SetValue( "in_gyroAim", in_gyroAim->integer ? 0 : 1 );
	Com_Printf( "Gyro aim %s\n", in_gyroAim->integer ? "on" : "off" );
}

// Gyro fine-aim: controller rotation rate (rad/s) -> view yaw, and pitch (flat) or a
// pitch offset on top of the head (VR). Controller space: x = pitch, y = yaw.
static void IN_GyroAim( GCExtendedGamepad *pad, qboolean menu )
{
	GCMotion *motion = pad.controller.motion;
	int now = Sys_Milliseconds();
	float dt = ( now - gyroLastMs ) * 0.001f, k, yawRate, pitchRate;

	gyroLastMs = now;
	if ( !motion || !in_gyroAim->integer || menu || dt <= 0 || dt > 0.1f )
		return;
	if ( motion.sensorsRequireManualActivation && !motion.sensorsActive )
		motion.sensorsActive = YES;
	if ( !motion.hasRotationRate )
		return;

	yawRate = motion.rotationRate.y;
	pitchRate = motion.rotationRate.x;
	if ( fabsf( yawRate ) < 0.02f ) yawRate = 0;      // deadzone (rad/s)
	if ( fabsf( pitchRate ) < 0.02f ) pitchRate = 0;
	k = dt * 57.29578f * in_gyroSensitivity->value;

	cl.viewangles[YAW] += yawRate * k;
	if ( VOS_XR_Active() )
		VOS_Head_AddPitchOffset( -pitchRate * k, 25.0f );
	else
		cl.viewangles[PITCH] -= pitchRate * k;
}

static void IN_MouseSim_f( void )
{
	Com_QueueEvent( 0, SE_MOUSE, atoi( Cmd_Argv( 1 ) ), atoi( Cmd_Argv( 2 ) ), 0, NULL );
}

void IN_Init( void *windowData )
{
	int i;
	(void)windowData;

	in_joystickThreshold = Cvar_Get( "in_joystickThreshold", "0.15", CVAR_ARCHIVE );
	in_menuCursorSpeed = Cvar_Get( "in_menuCursorSpeed", "12", CVAR_ARCHIVE );
	in_padDebug = Cvar_Get( "in_padDebug", "0", 0 );
	in_touchpadSpeed = Cvar_Get( "in_touchpadSpeed", "400", CVAR_ARCHIVE );
	vr_snapTurn = Cvar_Get( "vr_snapTurn", "45", CVAR_ARCHIVE );
	in_gyroAim = Cvar_Get( "in_gyroAim", "1", CVAR_ARCHIVE );
	in_gyroSensitivity = Cvar_Get( "in_gyroSensitivity", "1.0", CVAR_ARCHIVE );
	Cvar_Get( "in_joystick", "1", CVAR_ARCHIVE );
	Cmd_AddCommand( "vos_padsim", IN_PadSim_f );
	Cmd_AddCommand( "vos_mousesim", IN_MouseSim_f );   // test hook: relative cursor move
	Cmd_AddCommand( "vr_recenter", VOS_Head_Recenter );   // reset the positional-tracking origin
	Cmd_AddCommand( "gyro_toggle", IN_GyroToggle_f );
	{ extern void VOS_After_f( void ); Cmd_AddCommand( "vos_after", VOS_After_f ); }   // test hook

	for ( i = 0; i < ARRAY_LEN( defaultBinds ); i++ ) {
		int key = Key_StringToKeynum( (char *)defaultBinds[i][0] );
		const char *cur = Key_GetBinding( key );   // NULL when never bound
		if ( key >= 0 && ( !cur || !cur[0] ) )
			Key_SetBinding( key, defaultBinds[i][1] );
		else if ( key == K_PAD0_TOUCHPAD && cur && !Q_stricmp( cur, "notebook" ) )
			Key_SetBinding( key, "gyro_toggle" );   // earlier default; notebook stays on d-pad down
	}

	for ( GCController *c in GCController.controllers )
		Com_Printf( "IN_Init: controller '%s' (%s)\n", c.vendorName.UTF8String ?: "?", c.productCategory.UTF8String ?: "?" );
	Com_Printf( "IN_Init: GameController, %d controller(s) connected\n", (int)GCController.controllers.count );
}

void IN_Frame( void )
{
	GCExtendedGamepad *pad = GCController.current.extendedGamepad ?: GCController.controllers.firstObject.extendedGamepad;
	qboolean menu = ( Key_GetCatcher() & ( KEYCATCH_UI | KEYCATCH_CONSOLE ) ) != 0;
	qboolean now[ B_COUNT ] = { 0 };
	float ax[ 4 ] = { 0 };
	int i;

	if ( pad ) {
		now[B_A] = pad.buttonA.pressed;           now[B_B] = pad.buttonB.pressed;
		now[B_X] = pad.buttonX.pressed;           now[B_Y] = pad.buttonY.pressed;
		now[B_BACK] = pad.buttonOptions.pressed;  now[B_GUIDE] = pad.buttonHome.pressed;
		now[B_START] = pad.buttonMenu.pressed;
		now[B_LSTICK] = pad.leftThumbstickButton.pressed;
		now[B_RSTICK] = pad.rightThumbstickButton.pressed;
		now[B_LSHOULDER] = pad.leftShoulder.pressed; now[B_RSHOULDER] = pad.rightShoulder.pressed;
		now[B_DUP] = pad.dpad.up.pressed;         now[B_DDOWN] = pad.dpad.down.pressed;
		now[B_DLEFT] = pad.dpad.left.pressed;     now[B_DRIGHT] = pad.dpad.right.pressed;
		now[B_LTRIGGER] = pad.leftTrigger.value > 0.3f;
		now[B_RTRIGGER] = pad.rightTrigger.value > 0.3f;
		if ( [pad isKindOfClass:[GCDualSenseGamepad class]] )
			now[B_TOUCHPAD] = ( (GCDualSenseGamepad *)pad ).touchpadButton.pressed;
		ax[0] = pad.leftThumbstick.xAxis.value;   ax[1] = -pad.leftThumbstick.yAxis.value;
		ax[2] = pad.rightThumbstick.xAxis.value;  ax[3] = -pad.rightThumbstick.yAxis.value;
		IN_GyroAim( pad, menu );
	}

	if ( simFrames > 0 && simButton >= 0 && simButton < B_COUNT && Sys_Milliseconds() >= simAt ) {
		now[ simButton ] = --simFrames > 0;   // held for 2 frames, then released
	}

	for ( i = 0; i < B_COUNT; i++ ) {
		if ( now[i] != btnState[i] ) {
			// Cross on the pregame screen: do what its forward arrow does
			// (ui_main.c uiScript "playerstart"), no cursor aiming needed.
			if ( i == B_A && now[i] && menu && InPregame() ) {
				Cbuf_AddText( "fade 0 0 0 0 3\n" );
				Cvar_Set( "g_playerstart", "1" );
				VM_Call( uivm, UI_SET_ACTIVE_MENU, UIMENU_NONE );
				Com_Printf( "VOS pad: CROSS -> playerstart\n" );
				btnState[i] = now[i];
				continue;
			}
			KeyEvent( ButtonKey( i, menu ), now[i] );
			btnState[i] = now[i];
		}
	}

	// DualSense touchpad as a trackpad for the menu cursor (relative motion while touched).
	if ( menu && [pad isKindOfClass:[GCDualSenseGamepad class]] ) {
		GCControllerDirectionPad *tp = ( (GCDualSenseGamepad *)pad ).touchpadPrimary;
		float tx = tp.xAxis.value, ty = tp.yAxis.value;
		qboolean touching = tx != 0.0f || ty != 0.0f;
		if ( touching && touchActive ) {
			int dx = (int)( ( tx - touchPrevX ) * in_touchpadSpeed->value );
			int dy = (int)( ( touchPrevY - ty ) * in_touchpadSpeed->value );
			if ( dx || dy )
				Com_QueueEvent( 0, SE_MOUSE, dx, dy, 0, NULL );
		}
		touchActive = touching;
		touchPrevX = tx; touchPrevY = ty;
	} else {
		touchActive = qfalse;
	}

	if ( menu ) {
		int dx = (int)( ax[0] * in_menuCursorSpeed->value ), dy = (int)( ax[1] * in_menuCursorSpeed->value );
		if ( dx || dy )
			Com_QueueEvent( 0, SE_MOUSE, dx, dy, 0, NULL );
		for ( i = 0; i < 4; i++ ) ax[i] = 0;
	}

	// VR snap turn (comfort, M5): right stick X flicks rotate the body by vr_snapTurn degrees.
	if ( !menu && VOS_XR_Active() && vr_snapTurn->value > 0 ) {
		if ( !snapLatched && fabsf( ax[2] ) > 0.6f ) {
			cl.viewangles[YAW] -= ( ax[2] > 0 ? 1.0f : -1.0f ) * vr_snapTurn->value;
			snapLatched = qtrue;
		} else if ( fabsf( ax[2] ) < 0.3f ) {
			snapLatched = qfalse;
		}
		ax[2] = 0;   // no smooth yaw
	}
	// VR: pitch comes from the head (M4); ignore right stick Y.
	if ( VOS_XR_Active() )
		ax[3] = 0;

	for ( i = 0; i < 4; i++ ) {
		int v = ScaleAxis( ax[i] );
		if ( v != axisState[i] ) {
			Com_QueueEvent( 0, SE_JOYSTICK_AXIS, i, v, 0, NULL );
			axisState[i] = v;
		}
	}
}

void IN_Shutdown( void )
{
	Cmd_RemoveCommand( "vos_padsim" );
	Cmd_RemoveCommand( "vos_mousesim" );
	Cmd_RemoveCommand( "vr_recenter" );
	Cmd_RemoveCommand( "gyro_toggle" );
	Cmd_RemoveCommand( "vos_after" );
}

void IN_Restart( void )
{
	IN_Shutdown();
	IN_Init( NULL );
}
