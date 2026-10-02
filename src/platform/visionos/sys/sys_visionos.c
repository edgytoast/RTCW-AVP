/*
 * visionOS replacement for iortcw code/sys/sys_main.c (+ sys_osx.m).
 * Derived from iortcw sys_main.c (GPLv3). SDL removed; no process main():
 * the Swift app drives the engine through vos_engine.h.
 */

#include <signal.h>
#include <stdlib.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <os/log.h>
#include <execinfo.h>
#include <dlfcn.h>
#include <mach-o/getsect.h>
#include <mach-o/loader.h>

#include "sys/sys_local.h"
#include "sys/sys_loadlib.h"
#include "vos_engine.h"

static char binaryPath[ MAX_OSPATH ] = { 0 };
static char installPath[ MAX_OSPATH ] = { 0 };

void Sys_SetBinaryPath( const char *path ) { Q_strncpyz( binaryPath, path, sizeof( binaryPath ) ); }
char *Sys_BinaryPath( void ) { return binaryPath; }
void Sys_SetDefaultInstallPath( const char *path ) { Q_strncpyz( installPath, path, sizeof( installPath ) ); }
char *Sys_DefaultInstallPath( void ) { return *installPath ? installPath : Sys_Cwd(); }
char *Sys_DefaultAppPath( void ) { return Sys_BinaryPath(); }

void Sys_In_Restart_f( void ) { IN_Restart(); }
char *Sys_ConsoleInput( void ) { return NULL; }
char *Sys_GetClipboardData( void ) { return NULL; }

void Sys_InitPIDFile( const char *gamedir ) { (void)gamedir; }
void Sys_RemovePIDFile( const char *gamedir ) { (void)gamedir; }

static __attribute__ ((noreturn)) void Sys_Exit( int exitCode )
{
	CON_Shutdown();
	NET_Shutdown();
	Sys_PlatformExit();
	exit( exitCode );
}

void Sys_Quit( void ) { Sys_Exit( 0 ); }

cpuFeatures_t Sys_GetProcessorFeatures( void ) { return 0; }

void Sys_Init( void )
{
	Cmd_AddCommand( "in_restart", Sys_In_Restart_f );
	Cvar_Set( "arch", OS_STRING " " ARCH_STRING );
	Cvar_Set( "username", Sys_GetCurrentUser() );
}

void Sys_AnsiColorPrint( const char *msg ) { fputs( msg, stderr ); }

void Sys_Print( const char *msg )
{
	CON_LogWrite( msg );
	os_log( OS_LOG_DEFAULT, "%{public}s", msg );
	CON_Print( msg );
}

void Sys_Error( const char *error, ... )
{
	va_list argptr;
	char string[ 1024 ];

	va_start( argptr, error );
	Q_vsnprintf( string, sizeof( string ), error, argptr );
	va_end( argptr );

	Sys_ErrorDialog( string );
	Sys_Exit( 3 );
}

int Sys_FileTime( char *path )
{
	struct stat buf;
	return stat( path, &buf ) == -1 ? -1 : (int)buf.st_mtime;
}

dialogResult_t Sys_Dialog( dialogType_t type, const char *message, const char *title )
{
	os_log_error( OS_LOG_DEFAULT, "RTCW dialog [%{public}s]: %{public}s", title, message );
	return type == DT_YES_NO || type == DT_OK_CANCEL ? DR_NO : DR_OK;
}

/* ---- Dynamic libraries: none on visionOS ---- */

void Sys_UnloadDll( void *dllHandle ) { (void)dllHandle; }

void *Sys_LoadDll( const char *name, qboolean useSystemLib )
{
	Com_Printf( "Sys_LoadDll(%s): dynamic loading unsupported on visionOS\n", name );
	return NULL;
}

/* Game modules are statically linked (ADR-001). Each module object exports
 * only <module>_dllEntry / <module>_vmMain; see modules/*.exp. */
typedef void (*dllEntry_t)( intptr_t (*syscallptr)( intptr_t, ... ) );

#define VOS_MODULE( m ) \
	extern void m##_dllEntry( intptr_t (*)( intptr_t, ... ) ); \
	extern intptr_t m##_vmMain( intptr_t, intptr_t, intptr_t, intptr_t, intptr_t, intptr_t, \
		intptr_t, intptr_t, intptr_t, intptr_t, intptr_t, intptr_t, intptr_t );
VOS_MODULE( cgame )
VOS_MODULE( qagame )
VOS_MODULE( ui )

static const struct {
	const char *name;
	dllEntry_t  dllEntry;
	vmMainProc  vmMain;
} vos_modules[] = {
	{ "cgame",  cgame_dllEntry,  (vmMainProc)cgame_vmMain },
	{ "qagame", qagame_dllEntry, (vmMainProc)qagame_vmMain },
	{ "ui",     ui_dllEntry,     (vmMainProc)ui_vmMain },
};

/* A dlopen'ed module starts with fresh globals on every load (map change, death
 * reload, vid_restart). Static modules keep theirs, leaving dangling pointers
 * (crash in AICast_UpdateBattleInventory after dying). Each module's writable data
 * is linked into its own sections (gen-project.py: -rename_section), so on every
 * load we restore __<m>_data from a first-load snapshot and zero __<m>_bss. */
static struct { void *snapshot; unsigned long size; } vos_moduleData[ 3 ];

static void VOS_ResetModuleData( int index, const char *module, void *symbolInModule )
{
	Dl_info info;
	const struct mach_header_64 *mh;
	char sect[ 32 ];
	unsigned long size = 0;
	uint8_t *data, *bss;

	if ( !dladdr( symbolInModule, &info ) || !info.dli_fbase )
		return;
	mh = (const struct mach_header_64 *)info.dli_fbase;

	Com_sprintf( sect, sizeof( sect ), "__%s_data", module );
	data = getsectiondata( mh, "__DATA", sect, &size );
	if ( data && size ) {
		if ( !vos_moduleData[ index ].snapshot ) {
			vos_moduleData[ index ].snapshot = malloc( size );
			memcpy( vos_moduleData[ index ].snapshot, data, size );
			vos_moduleData[ index ].size = size;
		} else {
			memcpy( data, vos_moduleData[ index ].snapshot, vos_moduleData[ index ].size );
		}
	}

	Com_sprintf( sect, sizeof( sect ), "__%s_bss", module );
	bss = getsectiondata( mh, "__DATA", sect, &size );
	if ( bss && size )
		memset( bss, 0, size );

	Com_DPrintf( "Sys_LoadGameDll(%s): module data %s\n", module, data ? "reset" : "NOT FOUND" );
}

void *Sys_LoadGameDll( const char *name, vmMainProc *entryPoint,
	intptr_t (*systemcalls)( intptr_t, ... ) )
{
	int i;

	for ( i = 0; i < ARRAY_LEN( vos_modules ); i++ ) {
		if ( !Q_stricmp( name, vos_modules[ i ].name ) ) {
			VOS_ResetModuleData( i, vos_modules[ i ].name, (void *)vos_modules[ i ].vmMain );
			vos_modules[ i ].dllEntry( systemcalls );
			*entryPoint = vos_modules[ i ].vmMain;
			Com_DPrintf( "Sys_LoadGameDll(%s): static module\n", name );
			return (void *)&vos_modules[ i ];
		}
	}
	return NULL;
}

void Sys_ParseArgs( int argc, char **argv ) { (void)argc; (void)argv; }

void Sys_SigHandler( int signal )
{
	Sys_Exit( signal == SIGTERM ? 1 : 2 );
}

/* ---- Engine entry points for the Swift host (replaces main) ---- */

/* Visual quality defaults (M6): full-resolution textures, 16x anisotropic filtering,
 * highest model LOD, smoother curves. Applied once; see VOS_NeedDefaults. */
#define VOS_QUALITY_DEFAULTS_VERSION "1"
#define VOS_QUALITY_DEFAULTS \
	"+set r_picmip 0 +set r_ext_texture_filter_anisotropic 1 +set r_ext_max_anisotropy 16 " \
	"+set r_lodbias -2 +set r_subdivisions 2 +seta vos_defaults " VOS_QUALITY_DEFAULTS_VERSION

static qboolean VOS_NeedDefaults( const char *homeDir )
{
	char path[ MAX_OSPATH ], line[ 256 ];
	qboolean need = qtrue;
	FILE *f;

	Com_sprintf( path, sizeof( path ), "%s/main/wolfconfig.cfg", homeDir );
	if ( ( f = fopen( path, "r" ) ) ) {
		while ( fgets( line, sizeof( line ), f ) ) {
			if ( strstr( line, "seta vos_defaults \"" VOS_QUALITY_DEFAULTS_VERSION "\"" ) ) {
				need = qfalse;
				break;
			}
		}
		fclose( f );
	}
	return need;
}

// Diagnostics: log who calls exit() (a silent process exit leaves no crash report).
static void VOS_AtExit( void )
{
	void *frames[ 32 ];
	int i, n = backtrace( frames, 32 );
	char **names = backtrace_symbols( frames, n );
	for ( i = 0; i < n; i++ )
		os_log_error( OS_LOG_DEFAULT, "RTCW exit backtrace: %{public}s", names ? names[i] : "?" );
}

void VOS_EngineInit( const char *installDir, const char *homeDir, const char *commandLine )
{
	char cmd[ MAX_STRING_CHARS ];

	// stdout is not a tty under the simulator/device console: force line buffering
	// so console output (and the M1 heartbeat) is visible promptly.
	setvbuf( stdout, NULL, _IOLBF, 0 );

	atexit( VOS_AtExit );
	CON_Init();
	Sys_PlatformInit();
	Sys_SetBinaryPath( installDir );
	Sys_SetDefaultInstallPath( installDir );
	// fs_homepath goes through the command line: the cvar system does not exist before Com_Init.

	// logfile 2: console always written (flushed) to rtcwconsole.log, fetched by `make headset-log`.
	// Quality defaults are applied once (vos_defaults): command-line +set overrides the saved
	// config, so after the first run the user's own changes (archived in wolfconfig.cfg) win.
	Com_sprintf( cmd, sizeof( cmd ), "+set fs_homepath \"%s\" +set logfile 2 %s %s", homeDir,
		VOS_NeedDefaults( homeDir ) ? VOS_QUALITY_DEFAULTS : "", commandLine ? commandLine : "" );
	Com_Init( cmd );
	NET_Init();

	// Only SIGTERM exits cleanly. Crash signals are left to the OS so they produce a
	// crash report instead of a silent exit.
	signal( SIGTERM, Sys_SigHandler );
}

/* Test hook: `vos_after <ms> <command...>` runs a console command after a real-time
 * delay (frame-counted `wait` drifts during loading). Up to 8 pending. */
static struct { int at; char cmd[ MAX_STRING_CHARS ]; } vosAfter[ 8 ];

void VOS_After_f( void )   // registered in IN_Init (before startup commands run)
{
	int i;
	if ( Cmd_Argc() < 3 ) {
		Com_Printf( "usage: vos_after <ms> <command>\n" );
		return;
	}
	for ( i = 0; i < ARRAY_LEN( vosAfter ); i++ ) {
		if ( !vosAfter[i].at ) {
			vosAfter[i].at = Sys_Milliseconds() + atoi( Cmd_Argv( 1 ) );
			Q_strncpyz( vosAfter[i].cmd, Cmd_ArgsFrom( 2 ), sizeof( vosAfter[i].cmd ) );
			return;
		}
	}
}

static void VOS_RunAfter( void )
{
	int i, now = Sys_Milliseconds();
	for ( i = 0; i < ARRAY_LEN( vosAfter ); i++ ) {
		if ( vosAfter[i].at && now >= vosAfter[i].at ) {
			vosAfter[i].at = 0;
			Com_Printf( "vos_after: %s\n", vosAfter[i].cmd );
			Cbuf_AddText( va( "%s\n", vosAfter[i].cmd ) );
		}
	}
}

void VOS_EngineFrame( void )
{
	VOS_RunAfter();
	static int frames, lastReport;
	int now;

	Com_Frame();

	// Heartbeat for gate verification (M1): proves the loop keeps running.
	frames++;
	now = Sys_Milliseconds();
	if ( now - lastReport >= 10000 ) {
		extern int SNDDMA_GetDMAPos( void );
		Com_Printf( "VOS: heartbeat frame=%d t=%ds sndpos=%d\n", frames, now / 1000, SNDDMA_GetDMAPos() );
		lastReport = now;
	}
}
