# third_party/

Source and licence texts for what PVJ ships in binary form inside
`addons/gde_gozen/bin/`. Godot skips this folder (`.gdignore`); nothing here is
part of the app or the APK.

## `gde_gozen/` — the source of PVJ's Android libgozen

GDE GoZen (LGPL-2.1, `gde_gozen/LICENSE`) at upstream commit
[`b852674`](https://github.com/VoylinsGamedevJourney/gde_gozen/tree/b852674)
("Update to FFmpeg 7.1", 2026-04-09), GoZen's own files only (`src/`,
`SConstruct`, `build.py`, docs). `SConstruct` and `build.py` carry PVJ's
change, one line each (also in `tools/gozen_android_16kb_neon.patch`):

- `build.py`: `--disable-asm` commented out, so FFmpeg's arm64 NEON code is built
- `SConstruct`: `-Wl,-Bsymbolic` added to the Android link flags

`gde_gozen/FFMPEG_CONFIGURE.txt` is FFmpeg's exact configure line from that
build (`$BUILD` = the build directory). It has no `--enable-gpl`,
`--enable-nonfree` or `--enable-version3`.

The libraries GoZen links in statically, all unmodified, at the submodule
commits of `b852674`:

| Component | Version | Source | Licence text |
| --- | --- | --- | --- |
| FFmpeg | release/7.1 at [`5a1f107b4c78`](https://github.com/FFmpeg/FFmpeg/tree/5a1f107b4c78318f318897900acad1b6c6aa3f9d) (reports 7.1.3; not the `n7.1.3` tag) | [git.ffmpeg.org/ffmpeg.git](https://git.ffmpeg.org/ffmpeg.git), [tarball of that commit](https://github.com/FFmpeg/FFmpeg/archive/5a1f107b4c78318f318897900acad1b6c6aa3f9d.tar.gz) | `licenses/FFmpeg-*` (LGPL-2.1-or-later) |
| libvpx | [`3fce57ecc905`](https://chromium.googlesource.com/webm/libvpx/+/3fce57ecc905d95a4619f33d09851d68c5a88663) | chromium.googlesource.com/webm/libvpx | `licenses/libvpx-*` (BSD-3-Clause + patent grant) |
| libaom | [`de575da20409`](https://aomedia.googlesource.com/aom/+/de575da20409b4e1fa477c5615837715999c905a) | aomedia.googlesource.com/aom | `licenses/libaom-*` (BSD-2-Clause + AOM patent licence) |
| LibreSSL | 3.9.2 (`libressl-3.9.2.tar.gz`, sha256 `7b031dac64a59eb6ee3304f7ffb75dad33ab8c9d279c847f92c89fb846068f97`) | [ftp.openbsd.org/pub/OpenBSD/LibreSSL](https://ftp.openbsd.org/pub/OpenBSD/LibreSSL/) | `licenses/LibreSSL-COPYING` |
| godot-cpp | [`b0e3b1e4b78a`](https://github.com/godotengine/godot-cpp/tree/b0e3b1e4b78a606f48d162898afb5eeda533d2a9) | github.com/godotengine/godot-cpp | `licenses/godot-cpp-LICENSE.md` (MIT) |

All of it in one archive, the complete corresponding source of the shipped
Android libraries: `pvj-gozen-src-<version>.tar.xz`, published next to each PVJ
APK download.

## Rebuild and relink

1. Build libgozen from this source: `tools/GOZEN_ANDROID_BUILD.md` (NDK r28c,
   16 KB pages).
2. Replace `addons/gde_gozen/bin/libgozen.android.template_{release,debug}.arm64.so`
   in a PVJ checkout with yours.
3. Export the APK (README, "Build it"). PVJ talks to libgozen only through
   Godot's GDExtension API and loads it as a separate shared library, so a
   compatible build drops straight in.

The committed Android `.so` files had one change after the build: the builder's
home directory in 216 LibreSSL `__FILE__` strings was replaced, same length,
with `/home/build/`.

The Windows DLLs next to them (editor and desktop only, not in the APK) are
upstream's own GoZen v9.6 release binaries, FFmpeg 7.1, unmodified; their
source is upstream GDE GoZen v9.6.
