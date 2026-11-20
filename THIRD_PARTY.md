# Third-party components

PVJ bundles these. Each keeps its own licence; PVJ's MIT licence does not apply to them. This list describes what is in the tree. It is not legal advice.

| Component | Where | Licence |
| --- | --- | --- |
| GDE GoZen (video decoding GDExtension), Android libs built from `b852674` + PVJ's two-line patch; Windows DLLs upstream v9.6 | `addons/gde_gozen/` (source: `third_party/gde_gozen/`) | LGPL-2.1 (`addons/gde_gozen/LICENSE`) |
| ↳ linked into libgozen: FFmpeg, release/7.1 at `5a1f107` (reports 7.1.3), unmodified | `addons/gde_gozen/bin/` | LGPL-2.1-or-later (`third_party/licenses/FFmpeg-*`); configured without `--enable-gpl`, `--enable-nonfree` or `--enable-version3` (`third_party/gde_gozen/FFMPEG_CONFIGURE.txt`) |
| ↳ libvpx `3fce57e`, unmodified | `addons/gde_gozen/bin/` | BSD-3-Clause + patent grant (`third_party/licenses/libvpx-*`) |
| ↳ libaom `de575da`, unmodified | `addons/gde_gozen/bin/` | BSD-2-Clause + AOMedia patent licence (`third_party/licenses/libaom-*`) |
| ↳ LibreSSL 3.9.2, unmodified | `addons/gde_gozen/bin/` | OpenSSL / ISC-style (`third_party/licenses/LibreSSL-COPYING`) |
| ↳ godot-cpp `b0e3b1e`, unmodified | `addons/gde_gozen/bin/` | MIT (`third_party/licenses/godot-cpp-LICENSE.md`) |
| MediaPipe models (face landmarker, hand landmarker, EfficientDet-Lite0, SSD MobileNetV2) | `android/tracking_assets/mediapipe/` (Pro build only) | Apache-2.0, per Google's MediaPipe model cards (`LICENSE-Apache-2.0.txt` next to them) |
| MediaPipe Tasks Vision (`com.google.mediapipe:tasks-vision`) | fetched by Gradle for the Pro build | Apache-2.0 |
| Departure Mono, © 2022–2024 Helena Zhang | `fonts/DepartureMono-Regular.otf` | SIL Open Font License 1.1 (`fonts/OFL-DepartureMono.txt`) |
| JetBrains Mono, © 2020 The JetBrains Mono Project Authors | `fonts/JetBrainsMono-*.ttf` | SIL Open Font License 1.1 (`fonts/OFL-JetBrainsMono.txt`) |
| Press Start 2P, © 2012 The Press Start 2P Project Authors | `fonts/PressStart2P-Regular.ttf` | SIL Open Font License 1.1, Reserved Font Name "Press Start 2P" (`fonts/OFL-PressStart2P.txt`) |
| Godot Engine Android build template | generated into `android/build/` | MIT |

## GoZen, FFmpeg and the LGPL

This software uses code of [FFmpeg](https://ffmpeg.org) licensed under the LGPL-2.1, through GDE GoZen (LGPL-2.1).

- **How it is linked.** FFmpeg and the other codec libraries are linked statically into GoZen's own shared library (`libgozen.*`), which Godot loads at runtime as a separate file. PVJ's code talks to it only through the GDExtension API, so the LGPL does not decide the licence of PVJ's code.
- **Source.** `third_party/gde_gozen/` holds GoZen's source exactly as built, with PVJ's change (one line in `build.py`: FFmpeg's arm64 NEON code on; one in `SConstruct`: `-Wl,-Bsymbolic`), FFmpeg's exact configure line, and the commit of every library linked in, with links ([third_party/README.md](third_party/README.md)). The complete corresponding source of the shipped Android libraries, FFmpeg and all, is one archive, `pvj-gozen-src-<version>.tar.xz`, published next to each APK download.
- **Rebuild and relink.** Build libgozen with [tools/GOZEN_ANDROID_BUILD.md](tools/GOZEN_ANDROID_BUILD.md) (NDK r28c, 16 KB pages), drop your `libgozen.android.template_{release,debug}.arm64.so` into `addons/gde_gozen/bin/` of a PVJ checkout and export the APK (README, "Build it"). The whole app is open source, so the APK can always be rebuilt around a modified library.
- **One post-build change** to the committed Android libraries: the builder's home directory in 216 LibreSSL `__FILE__` strings was replaced, same length, with `/home/build/`.
- **Licence texts:** GoZen `addons/gde_gozen/LICENSE`; FFmpeg, libvpx, libaom, LibreSSL and godot-cpp in `third_party/licenses/`.
- **In the app:** MODE ▸ ABOUT shows "This software uses libraries from the FFmpeg project under the LGPLv2.1." and its **Open-source licences…** row opens this file.

## Left out of this repository

The **HUD** and **HUD Rings** tracking effects in the Pro build port code from a Shadertoy shader (Dsf3WH) that is under Shadertoy's default licence, CC BY-NC-SA 3.0. That isn't compatible with MIT, so their shaders (`shaders/hud.gdshader`, `shaders/hud_rings.gdshader`) are not included. The app adds those two effects only if the files are present, so an original replacement with the same uniforms brings them back.

## Not third-party

The demo loops in `demo_clips/` are CC BY-NC 4.0 (see `demo_clips/LICENSE.md`). The PVJ name, icons, ident and splash are covered by [TRADEMARKS.md](TRADEMARKS.md).
