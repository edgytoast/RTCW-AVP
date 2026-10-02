#!/usr/bin/env python3
"""Generate src/platform/visionos/project.yml (xcodegen) from explicit file lists.

Engine lists mirror upstream iortcw SP Makefile (Q3OBJ, Q3ROBJ, JPGOBJ, Q3CGOBJ,
Q3GOBJ, Q3UIOBJ) minus SDL/Cocoa/x86/dlopen pieces (ADR-001). Sources are read
from the staged tree build/iortcw/code (scripts/stage-engine.sh).
Run: python3 scripts/gen-project.py && xcodegen -s src/platform/visionos/project.yml
"""
import os, sys

TEAM_ID = os.environ.get("TEAM_ID") or sys.exit("TEAM_ID not set: run via 'make project' (reads config.local)")
BUNDLE_ID = os.environ.get("BUNDLE_ID") or sys.exit("BUNDLE_ID not set: run via 'make project'")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CODE = os.path.join(ROOT, "build/iortcw/code")
PROJ_DIR = os.path.join(ROOT, "src/platform/visionos")

ENGINE = {
    "client": "cl_cgame cl_cin cl_console cl_input cl_keys cl_main cl_net_chan cl_parse cl_scrn cl_ui cl_avi "
              "snd_adpcm snd_dma snd_mem snd_mix snd_wavelet snd_main snd_codec snd_codec_wav qal snd_openal",
    "qcommon": "cm_load cm_patch cm_polylib cm_test cm_trace cmd common cvar files md4 md5 msg net_chan net_ip "
               "huffman q_math q_shared puff vm vm_interpreted",
    "zlib-1.2.11": "unzip ioapi",
    "server": "sv_bot sv_ccmds sv_client sv_game sv_init sv_main sv_net_chan sv_snapshot sv_world",
    "botlib": "be_aas_bspq3 be_aas_cluster be_aas_debug be_aas_entity be_aas_file be_aas_main be_aas_move "
              "be_aas_optimize be_aas_reach be_aas_route be_aas_routealt be_aas_routetable be_aas_sample "
              "be_ai_char be_ai_chat be_ai_gen be_ai_goal be_ai_move be_ai_weap be_ai_weight be_ea "
              "be_interface l_crc l_libvar l_log l_memory l_precomp l_script l_struct",
    "splines": "math_angles math_matrix math_quaternion math_vector q_parse splines util_str",
    "sys": "con_log con_passive sys_unix",
}
ENGINE_CPP = {"splines"}  # splines/*.cpp
RENDERER = ("tr_animation tr_backend tr_bsp tr_cmds tr_cmesh tr_curve tr_flares tr_font tr_image tr_image_bmp "
            "tr_image_jpg tr_image_pcx tr_image_png tr_image_tga tr_init tr_light tr_main tr_marks tr_mesh "
            "tr_model tr_model_iqm tr_noise tr_scene tr_shade tr_shade_calc tr_shader tr_shadows tr_sky "
            "tr_surface tr_world")
JPEG = ("jaricom jcapimin jcapistd jcarith jccoefct jccolor jcdctmgr jchuff jcinit jcmainct jcmarker jcmaster "
        "jcomapi jcparam jcprepct jcsample jctrans jdapimin jdapistd jdarith jdatadst jdatasrc jdcoefct jdcolor "
        "jddctmgr jdhuff jdinput jdmainct jdmarker jdmaster jdmerge jdpostct jdsample jdtrans jerror jfdctflt "
        "jfdctfst jfdctint jidctflt jidctfst jidctint jmemmgr jmemnobs jquant1 jquant2 jutils")
MODULES = {
    "cgame": ("CGAMEDLL CGAME", [("cgame", "cg_main bg_animation bg_misc bg_pmove bg_slidemove bg_lib "
        "cg_consolecmds cg_draw cg_drawtools cg_effects cg_ents cg_event cg_flamethrower cg_info cg_localents "
        "cg_marks cg_newdraw cg_particles cg_players cg_playerstate cg_predict cg_scoreboard cg_servercmds "
        "cg_snapshot cg_sound cg_trails cg_view cg_weapons cg_syscalls"), ("ui", "ui_shared"),
        ("qcommon", "q_math q_shared")]),
    "qagame": ("GAMEDLL QAGAME", [("game", "g_main ai_cast ai_cast_characters ai_cast_debug ai_cast_events "
        "ai_cast_fight ai_cast_func_attack ai_cast_func_boss1 ai_cast_funcs ai_cast_script_actions ai_cast_script "
        "ai_cast_script_ents ai_cast_sight ai_cast_think ai_chat ai_cmd ai_dmnet ai_dmq3 ai_main ai_team "
        "bg_animation bg_misc bg_pmove bg_slidemove bg_lib g_active g_alarm g_bot g_client g_cmds g_combat "
        "g_items g_mem g_misc g_missile g_mover g_props g_save g_script_actions g_script g_session g_spawn "
        "g_svcmds g_target g_team g_tramcar g_trigger g_utils g_weapon g_syscalls"),
        ("qcommon", "q_math q_shared")]),
    "ui": ("UI", [("ui", "ui_main ui_atoms ui_gameinfo ui_players ui_shared ui_syscalls"),
        ("game", "bg_misc bg_lib"), ("qcommon", "q_math q_shared")]),
}

def resolve(d, names, exts=(".c",)):
    out = []
    for n in names.split():
        # Makefile builds e.g. cgame/bg_*.o from game/, so fall back like it does.
        cands = [os.path.join(CODE, dd, n + e) for dd in (d, "game", "ui", "qcommon") for e in exts]
        p = next((c for c in cands if os.path.exists(c)), None)
        if not p:
            sys.exit(f"missing source: {d}/{n}")
        out.append(os.path.relpath(p, PROJ_DIR))
    return out

def srcs(paths, indent=6):
    return "\n".join(" " * indent + f"- path: {p}" for p in paths)

engine = []
for d, names in ENGINE.items():
    engine += resolve(d, names, (".cpp", ".c") if d in ENGINE_CPP else (".c",))
engine += ["sys/sys_visionos.c", "sys/vos_input.m", "sys/vos_snd.m"]
renderer = resolve("renderer", RENDERER) + resolve("jpeg-8c", JPEG) + ["../../renderer/vos_glimp.c", "../../renderer/vos_flat.m", "../../xr/visionos/vos_xr.m", "../../xr/visionos/vos_xr_gl.c", "../../xr/visionos/vos_headpose.c"]

INC = ["$(SRCROOT)/include", "$(SRCROOT)/../../xr/visionos", "$(SRCROOT)/../../renderer", "$(SRCROOT)/../../../build/iortcw/code/jpeg-8c", "$(SRCROOT)/sys", "$(SRCROOT)/../../../build/iortcw/code",
       "$(SRCROOT)/../../../build/angle/include"]
COMMON_DEFS = ["VISIONOS", "EGL_EGLEXT_PROTOTYPES", "C_ONLY", "NO_VM_COMPILED", "BOTLIB_NONE_PLACEHOLDER", "USE_OPENGLES", "USE_LOCAL_HEADERS",
               "USE_INTERNAL_JPEG", "STANDALONE_NONE_PLACEHOLDER"]
COMMON_DEFS = [d for d in COMMON_DEFS if "PLACEHOLDER" not in d]

def settings(defs, extra=""):
    d = " ".join(defs)
    inc = " ".join(f'"{i}"' for i in INC)
    return f"""    settings:
      base:
        GCC_PREPROCESSOR_DEFINITIONS: "{d}"  # no $(inherited): Xcode DEBUG=1 enables stale iortcw debug code
        HEADER_SEARCH_PATHS: '$(inherited) {inc}'
        GCC_WARN_INHIBIT_ALL_WARNINGS: YES
        CLANG_ENABLE_OBJC_ARC: YES
        GCC_C_LANGUAGE_STANDARD: gnu99
{extra}"""

yml = f"""# GENERATED by scripts/gen-project.py — edit the script, not this file.
name: RTCW
options:
  bundleIdPrefix: {BUNDLE_ID.rsplit(".", 1)[0]}
  deploymentTarget:
    visionOS: "26.0"
settings:
  base:
    DEVELOPMENT_TEAM: {TEAM_ID}
    CODE_SIGN_STYLE: Automatic
    ARCHS: arm64
targets:
  RTCWEngine:
    type: library.static
    platform: visionOS
    sources:
{srcs(engine)}
{settings(COMMON_DEFS + ["BOTLIB"])}
  RTCWRenderer:
    type: library.static
    platform: visionOS
    sources:
{srcs(renderer)}
{settings(COMMON_DEFS)}
"""
for m, (defs, groups) in MODULES.items():
    files = []
    for d, names in groups:
        files += resolve(d, names)
    extra = f"""        GENERATE_MASTER_OBJECT_FILE: YES
        STRIP_INSTALLED_PRODUCT: NO
        OTHER_CFLAGS: -fno-common
        PRELINK_FLAGS: "-exported_symbols_list $(SRCROOT)/modules/{m}.exp -rename_section __DATA __data __DATA __{m}_data -rename_section __DATA __bss __DATA __{m}_bss -rename_section __DATA __common __DATA __{m}_bss"
"""
    yml += f"""  RTCW_{m}:
    type: library.static
    platform: visionOS
    sources:
{srcs(files)}
{settings(COMMON_DEFS + defs.split() + [f"vmMain={m}_vmMain", f"dllEntry={m}_dllEntry"], extra)}
"""
yml += f"""  RTCW:
    type: application
    platform: visionOS
    sources:
      - path: App
    info:
      path: App/Info.plist
      properties:
        # Without these visionOS routes the DualSense to system UI navigation.
        GCSupportsControllerUserInteraction: true
        GCSupportedGameControllers:
          - GCControllerProfile: ExtendedGamepad
        # Required to open the ImmersiveSpace (VR mode).
        UIApplicationSceneManifest:
          UIApplicationSupportsMultipleScenes: true
          UIApplicationPreferredDefaultSceneSessionRole: UIWindowSceneSessionRoleApplication
          UISceneConfigurations: {{}}
    dependencies:
      - target: RTCWEngine
      - target: RTCWRenderer
      - target: RTCW_cgame
      - target: RTCW_qagame
      - target: RTCW_ui
      - sdk: libz.tbd
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: {BUNDLE_ID}
        GENERATE_INFOPLIST_FILE: YES
        INFOPLIST_KEY_CFBundleDisplayName: RTCW
        INFOPLIST_KEY_UIFileSharingEnabled: YES
        INFOPLIST_KEY_LSSupportsOpeningDocumentsInPlace: YES
        SWIFT_VERSION: "6.0"
        SWIFT_OBJC_BRIDGING_HEADER: App/RTCW-Bridging-Header.h
        HEADER_SEARCH_PATHS: '$(inherited) "$(SRCROOT)/sys" "$(SRCROOT)/../../xr/visionos"'
        OTHER_LDFLAGS: "$(inherited) -lc++ -framework Metal -framework IOSurface -framework QuartzCore -framework CoreGraphics"
        "OTHER_LDFLAGS[sdk=xros*]": "$(inherited) -lc++ -framework Metal -framework IOSurface -framework QuartzCore -framework CoreGraphics $(SRCROOT)/../../../build/angle/lib/libANGLE.a"
        "OTHER_LDFLAGS[sdk=xrsimulator*]": "$(inherited) -lc++ -framework Metal -framework IOSurface -framework QuartzCore -framework CoreGraphics $(SRCROOT)/../../../build/angle/lib/libANGLE-sim.a"
"""
open(os.path.join(PROJ_DIR, "project.yml"), "w").write(yml)
print(f"wrote project.yml: engine={len(engine)} renderer={len(renderer)} files")
