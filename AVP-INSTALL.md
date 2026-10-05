# Installing RTCW for Apple Vision Pro

Play your own copy of *Return to Castle Wolfenstein* (single player) on Apple Vision Pro, in VR (stereo, head tracking, a virtual menu screen, DualSense controls) or in a flat window. This repository is a build kit: scripts plus the visionOS platform layer and patches for a pinned [iortcw](https://github.com/iortcw/iortcw) checkout. You build it on your Mac and install it on your own headset. [QUICKSTART.md](QUICKSTART.md) is the full walkthrough, with controls, settings and troubleshooting.

## What you need

- A Mac with Xcode 26 or newer (from the App Store, launched once) and about 30 GB free. `make setup` downloads everything else.
- Apple Vision Pro on visionOS 26 or newer
- Your Apple ID signed in to Xcode, with an Apple Development certificate (a free account works)
- RTCW game data from your own GOG or Steam copy: `pak0.pk3`, `sp_pak1.pk3`, `sp_pak2.pk3`, `sp_pak3.pk3`, and `sp_pak4.pk3` if you have it, from the game's `Main` folder
- Recommended: a PS5 DualSense controller paired to the headset

## Your game files

This repository contains no game data. Use the `.pk3` files from your own copy; never commit or share them.

- `make setup` looks for them in common GOG and Steam folders. If it doesn't find them, it asks you to drag the `Main` folder into Terminal, or you can import them later in the app.
- `make vr` and `make flat` copy any missing `.pk3` files to the headset.
- On the headset, the start screen has **Import game files…**. Put the `.pk3` files (or the whole `Main` folder) in iCloud Drive or AirDrop them to the headset, then pick them there.

## Build from source

There's no prebuilt app. From a checkout of this repository:

```sh
make setup
```

It shows what it's about to download, then runs without further questions: the visionOS SDK and Simulator (about 8 GB), a local copy of xcodegen in `build/tools/`, the iortcw engine source at the pinned commit (about 150 MB), and ANGLE, the OpenGL to Metal layer (about 12 GB and up to an hour; re-running resumes). It reads your signing team from your Mac's Apple Development certificate and saves its settings in `config.local`. Run `make config` if your certificate or data folder changes.

No signing certificate? In Xcode, go to **Settings → Accounts**, add your Apple ID, then **Manage Certificates → + → Apple Development**, and run `make setup` again.

## Install on Apple Vision Pro

1. Pair the headset once. On the Vision Pro, open **Settings → General → Remote Devices** and keep that screen open. On the Mac, open **Xcode → Window → Devices and Simulators**, pair it, and enable Developer Mode when the headset asks. The Mac and headset must be on the same Wi-Fi, with any VPN on the Mac turned off.
2. Build and install:

   ```sh
   make vr      # or: make flat
   ```

3. Open RTCW from the Home View on the headset. The first time only, go to **Settings → General → VPN & Device Management → your Apple ID → Trust**.

## Notes

- With a free Apple ID, the app expires after 7 days. Run `make vr` again; your saves and game files are kept.
- In VR you aim with your head; tilting the controller fine-tunes the aim (gyro).
- `make headset-log` fetches the game's console log to `build/logs/device.log`.
- The engine is GPLv3 (iortcw). Return to Castle Wolfenstein game data is © id Software / ZeniMax and is not part of this project.
