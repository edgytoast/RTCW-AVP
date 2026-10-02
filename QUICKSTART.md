# Quickstart: RTCW on Apple Vision Pro

Play your own copy of *Return to Castle Wolfenstein* on Apple Vision Pro, in VR or in a flat window. This is for personal use: you build it on your Mac and install it on your own headset.

## You need

- A Mac with **Xcode 26 or newer** (App Store) and about **30 GB free**; everything else is downloaded by `make setup`
- **Apple Vision Pro** on visionOS 26 or newer, paired with Xcode (see step 3)
- Your **Apple ID** signed in to Xcode (a free account works)
- **RTCW game data** from your own copy (GOG or Steam): `pak0.pk3`, `sp_pak1.pk3`, `sp_pak2.pk3`, `sp_pak3.pk3`, and `sp_pak4.pk3` if you have it, found in the game's `Main` folder
- Recommended: a **PS5 DualSense** controller paired to the headset

## 1. One-time setup

```bash
git clone <this repo> rtcw-visionos && cd rtcw-visionos
make setup
```

`make setup` downloads and prepares everything automatically. It shows what it's about to download, then runs without questions:

| Step | Automatic? |
|---|---|
| Xcode | **No.** Install it from the App Store (setup opens the page) and launch it once. |
| visionOS SDK + Simulator (~8 GB) | Yes |
| xcodegen | Yes: a local copy in `build/tools/`; no Homebrew or admin rights needed |
| iortcw engine source at the pinned commit (~150 MB) | Yes |
| ANGLE, the OpenGL→Metal layer (~12 GB, up to an hour) | Yes; re-running resumes |
| Signing team | Yes: read from your Mac's "Apple Development" certificate |
| **Game files** | **Your own copy.** Found automatically in common GOG/Steam folders; otherwise you're asked to drag the `Main` folder into Terminal, or you can import it later inside the app. |

Settings are saved in `config.local` (git-ignored). Re-run `make config` if your certificate or data folder changes.

## 2. No signing certificate?

Xcode → Settings → Accounts → add your Apple ID → Manage Certificates → **+** → Apple Development. Then run `make setup` again.

## 3. Pair the headset (once)

1. On the Vision Pro: Settings → General → Remote Devices, and keep that screen open.
2. On the Mac: Xcode → Window → Devices and Simulators. Pair it, and enable Developer Mode when the headset asks.

The Mac and headset must be on the **same Wi-Fi**, with any VPN on the Mac turned off.

## 4. Install and play

```bash
make vr      # or: make flat
```

This builds, installs, and copies your game files to the headset if they're missing. Then open **RTCW from the Home View** on the headset. Free Apple IDs can't launch the app remotely.

- **First time only:** on the headset, Settings → General → VPN & Device Management → your Apple ID → **Trust**.
- **Game files another way:** the start screen has **Import game files…**. Put the pk3 files (or the whole `Main` folder) in iCloud Drive or AirDrop them to the headset, then pick them there.
- **Free Apple ID:** the app expires after **7 days**. Run `make vr` again; your saves and game files are kept.

## Controls (DualSense)

| | Menus | In game |
|---|---|---|
| Left stick | move cursor | move |
| Right stick | — | turn (VR: 45° snap) |
| D-pad | navigate | lean left/right, binoculars (up), notebook (down) |
| ✕ | select | jump |
| ○ | back | crouch |
| □ / △ | — | reload / use |
| R2 / L2 | — | fire / alternate fire |
| R1 / L1 | — | next / previous weapon |
| L3 / R3 | — | sprint / kick |
| Touchpad | slide = cursor, press = click | press = gyro aim on/off |
| Options | menu | menu |

In VR you aim with your head; tilting the controller fine-tunes the aim (gyro).

## Settings (game console)

| Setting | Default | Effect |
|---|---|---|
| `vr_snapTurn` | 45 | Snap-turn degrees; 0 = smooth turning |
| `vr_gamma` | 1.3 | Brightness (VR and flat) |
| `vr_sharpen` | 0.3 | Sharpening |
| `vr_msaa` | 0 | Anti-aliasing: 2 or 4. Restart the app to apply. |
| `vr_resolutionScale` | 1.0 | Per-eye render size, 0.5–1.5. Restart the app to apply. |
| `vr_hudScale`, `vr_hudDepth` | 0.5, 1.5 | HUD size and distance (meters) |
| `in_gyroAim`, `in_gyroSensitivity` | 1, 1.0 | Gyro aim |
| `vr_recenter` | command | Reset the leaning/crouching origin |

## Troubleshooting

| Problem | Fix |
|---|---|
| Setup says Xcode isn't installed, but it is | Fixed in the current version: setup picks the newest installed `Xcode*.app` (26+) even when it isn't named `Xcode.app` or `xcode-select` points elsewhere. The choice is saved as `DEVELOPER_DIR` in `config.local`; delete that line to re-detect. |
| `Vision Pro not reachable` | Wear and unlock the headset, same Wi-Fi as the Mac, VPN off, Settings → General → Remote Devices open. `make vr` waits 90 s for it. |
| `remote launch was refused` | Expected with a free Apple ID: open RTCW from the Home View. |
| The app won't open on the headset | Trust your Apple ID (step 4). If 7 days have passed, run `make vr` again. |
| Controller doesn't respond while looking at the window | Update to the latest build; the app claims gamepad input via `GCEventInteraction`. |
| Too dark or too bright | Adjust `vr_gamma` in the console |
| Game files missing on the headset | `make vr` copies them, or use **Import game files…** in the app |
| Something else | Run `make headset-log`, which fetches the game's console log to `build/logs/device.log` |

## More

- `make help` lists all commands (`make sim` runs it in the Simulator).
- The engine is GPL (iortcw). Game data is © id Software / Bethesda; use your own copy and never commit or share the pk3 files.
