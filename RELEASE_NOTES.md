# Release notes

## 0.8.0-beta4 — PVJ Pro (sideload APK)

`pvjpro-0.8.0-beta4.apk` · package `com.pocketvj.app` · versionCode 9 · Android 11+ (arm64)

```
sha256  a6e6b21a493d7605b92122dce621027cf249be401488bb5002a68959db44444b  pvjpro-0.8.0-beta4.apk
```

Check it before installing: `sha256sum pvjpro-0.8.0-beta4.apk` (Linux, macOS),
`certutil -hashfile pvjpro-0.8.0-beta4.apk SHA256` (Windows). It installs over
an earlier PVJ Pro and keeps your clips and settings.

### Changed

- **Clip browser script fixed.** The beta3 Pro build packed a network clip
  browser script that failed to compile, so the browser could not load. It
  compiles again (checked at build time and by `tools/verify_pro_network.gd`;
  not yet tried against a running clip server).
- **HUD and HUD Rings removed.** Their shaders port non-commercial Shadertoy
  code, which can't ship in an MIT-licensed open-source app
  ([THIRD_PARTY.md](THIRD_PARTY.md)). The FX list now ends with **Crowd**. If a
  saved setup used HUD or HUD Rings, it opens on another effect.
- **Open source.** Built from this repository; the video decoder's LGPL source
  (GDE GoZen + FFmpeg) is published next to the APK as
  `pvj-gozen-src-0.8.0-beta4.tar.xz` ([third_party/](third_party/README.md)).
- **FFmpeg credit in the app.** MODE ▸ ABOUT now says "This software uses
  libraries from the FFmpeg project under the LGPLv2.1.", and a new
  **Open-source licences…** row opens [THIRD_PARTY.md](THIRD_PARTY.md) in the
  browser.

### Known limitations

- **Google Drive import is not configured in this build.** It has no Google
  OAuth client, so Drive sign-in says it isn't configured. Import clips over
  USB or with the clip server instead. If you build PVJ yourself, add your own
  client in `secrets/drive_oauth.cfg` (README, "Build it").
- **Clip server address.** The clip server (laptop) address has no in-app
  setting yet and defaults to a placeholder; set `server_ip` in
  `scripts/clip_server.gd` in your own build.
- **Tracking (Crowd) on phones with 16 KB memory pages.** Two MediaPipe
  libraries in the APK are 4 KB-aligned (upstream). On phones that use 16 KB
  memory pages, tracking may not load, or Android may show a compatibility
  warning. Everything else is 16 KB-aligned. Pixel 8 and Pixel 9a (4 KB pages)
  are not affected.

### Verified

Pixel 8 (Android 17), this APK: boots to interactive in 6.4 s, OSC listening
on UDP 4855, MODE ▸ ABOUT shows the FFmpeg credit, and **Open-source
licences…** opens THIRD_PARTY.md in the browser. HDMI was checked on the
build before it, whose contents differ only in the two scripts that add the
credit: projector over USB-C → HDMI at 1920×1080, decoding on every beat in
sequencer mode, output at 57–60 fps.
