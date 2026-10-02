# RTCW for Apple Vision Pro

Play your own copy of **Return to Castle Wolfenstein** (single player) on Apple Vision Pro, in **VR** (stereo, head tracking, virtual menu screen, DualSense controls) or in a **flat window**.

This repository is a build kit: scripts plus the visionOS platform layer and patches. You build it on your Mac and install it on your own headset. It contains no game data. Use the `.pk3` files from your own GOG or Steam copy.

## Build

Requires a Mac with Xcode 26+, an Apple ID (a free one works), and Apple Vision Pro on visionOS 26+.

```bash
make setup      # downloads everything else (visionOS SDK, xcodegen, iortcw, ANGLE), finds your game data
make vr         # build + install on the headset, then open RTCW from the Home View
```

See **[QUICKSTART.md](QUICKSTART.md)** for pairing the headset, controls, settings and troubleshooting.

## What's inside

| Path | What |
|---|---|
| `scripts/`, `Makefile` | Setup, build, install and run automation |
| `src/platform/visionos/` | SwiftUI app, engine host, input (GameController), audio (AVAudioEngine) |
| `src/xr/visionos/` | Compositor Services immersive rendering, ARKit head tracking |
| `src/renderer/` | ANGLE/EGL GL backend and the flat-mode Metal presenter |
| `src/patches/iortcw/` | The engine changes, applied to a pinned iortcw checkout |
| `src/patches/angle/` | The visionOS build patch for a pinned ANGLE revision |
| `upstream/PINS` | Exact upstream commits used for the build |

## Credits

- [iortcw](https://github.com/iortcw/iortcw): the engine (GPLv3)
- [RTCWQuest](https://github.com/DrBeef/RTCWQuest): VR design reference (head/body split, stereo, world scale)
- [halflife-visionos](https://github.com/illixion/halflife-visionos): the ANGLE-for-visionOS build approach
- [ANGLE](https://chromium.googlesource.com/angle/angle): OpenGL ES on Metal
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## License

GPLv3 (see `LICENSE`), like iortcw. Return to Castle Wolfenstein game data is © id Software / ZeniMax and is not part of this project.
