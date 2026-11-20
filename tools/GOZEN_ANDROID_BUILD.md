# Rebuilding libgozen for Android (16 KB pages, NEON)

The two `addons/gde_gozen/bin/libgozen.android.template_{debug,release}.arm64.so`
in this repo are NOT upstream's binaries. Upstream's compiled builds (v9.6 and
v9.8, checked 2026-10-01) are linked with NDK r23 — 4 KB-aligned, which Google
Play refuses for apps targeting Android 15+ — and decode in plain C
(`--disable-asm`). These were built from source on 2026-10-01 (commits
`41c0203`, `8f8ea02`). This is how.

## Source

- `gde_gozen` at `b852674` (2026-04-09, "Update to FFmpeg 7.1"). That is the
  commit whose `video_playback.gd` equals the v9.6 zip's, so the PATCHED
  `addons/gde_gozen/video_playback.gd` in this repo still matches the library.
  (`https://github.com/VoylinsGamedevJourney/gde_gozen`; upstream has since
  moved to Codeberg.)
- Submodules at that commit: FFmpeg `5a1f107` (release/7.1), libvpx `3fce57e`,
  libaom `de575da`, godot-cpp `b0e3b1e`; LibreSSL 3.9.2 is downloaded by
  `build.py`.
- `tools/gozen_android_16kb_neon.patch` — the only source changes (two lines).

## Toolchain (Linux / WSL, no sudo needed)

- Android NDK **r28c** (`android-ndk-r28c-linux.zip` from dl.google.com). r28
  links 16 KB-aligned by default; that is the whole "16 KB fix".
- A Python venv with `pip install cmake scons ninja pkgconf`.
- godot-cpp 4.2 looks for the NDK at `$ANDROID_HOME/ndk/23.2.8568313`: make
  that path a symlink to the r28c directory.

## Build

```bash
git clone https://github.com/VoylinsGamedevJourney/gde_gozen.git && cd gde_gozen
git checkout b852674
git submodule update --init --depth 1 ffmpeg godot_cpp libvpx libaom
git apply /path/to/PocketVJ-v0.2/tools/gozen_android_16kb_neon.patch

export PATH="$VENV/bin:$PATH" ANDROID_NDK_ROOT="$NDK" ANDROID_HOME="$SDK"   # $SDK/ndk/23.2.8568313 -> $NDK
python3 -c "import build; build.compile_ffmpeg('android', 'arm64')"          # vpx, aom, libressl, ffmpeg
scons -j8 target=template_release platform=android arch=arm64
scons -j8 target=template_debug   platform=android arch=arm64
# -> test_room/addons/gde_gozen/bin/libgozen.android.template_*.arm64.so
```

## What the patch does, and why

- `build.py`, `compile_ffmpeg_android`: `--disable-asm` removed, so FFmpeg's
  arm64 NEON assembly is built. Six masks on their own 720p clip plus the deck
  hold 59-60 fps on a Pixel 8 with a projector attached (commit `5817e44`).
- `SConstruct`, android `LINKFLAGS`: `-Wl,-Bsymbolic` added. Without it lld
  refuses the assembly's relocations against FFmpeg's own tables
  (`R_AARCH64_ADR_PREL_PG_HI21 cannot be used against symbol ff_tx_tab_*`).

## Check the result

```bash
readelf -lW libgozen.android.template_release.arm64.so | grep LOAD   # last column 0x4000
readelf -d  libgozen.android.template_release.arm64.so | grep -c TEXTREL   # 0
adb shell dumpsys package studio.cu.pvj | grep pageSizeCompat         # 0 on the device
```

## Build paths

The compilers bake source paths into the binaries (LibreSSL's `__FILE__`
strings, 216 of them), so the build directory ends up in every APK. The
committed `.so` files had the builder's home directory patched out after the
fact, same length: `/home/<user>/` → `/home/build/` (strings only, 1080 bytes,
nothing else changed). On the next rebuild, build under `/home/build/` or add
`-ffile-prefix-map=$PWD=.` to the C/C++ flags of FFmpeg, LibreSSL and GoZen
instead, then check with `strings -a libgozen.android.*.so | grep /home/`.

## Tried and rejected

Limiting each decoder to two threads (upstream asks for cores-1 per decoder):
3-4 fps instead of 59-60 in the same six-mask test. Do not do it.
