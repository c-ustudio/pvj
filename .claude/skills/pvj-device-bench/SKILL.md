---
name: pvj-device-bench
description: Measure PVJ on a real phone or the API 37 16 KB emulator — launch time, fps, frame stalls, app-storage growth across sessions, before/after a change. Use when asked to reproduce a slowdown, compare builds on a device, check what PVJ writes to storage, test a cleanup, or run PVJ on the Android 17 / 16 KB emulator. Covers the debug-app rule, building + installing test APKs from WSL, the unattended session driver, library scaling, planting leftovers, the summary table, and the emulator.
---

# PVJ device bench

Built during the 2026-11-02 storage-growth audit (docs/STORAGE_GROWTH_AUDIT.md §4 is a worked
result). Everything here runs from WSL against `studio.cu.pvj.debug`.

## 0. Rules (docs/RELEASE.md §3b — not optional)

- Scripted runs, installs and `run-as` writes go to the **debug app only** (`studio.cu.pvj.debug`).
  The release `studio.cu.pvj` on a phone is the owner's real data: look-only (screenshots, `dumpsys
  diskstats` totals), never install over it, never `run-as` (it is not debuggable anyway).
- Before the first run of a session: `tools/backup_device_data.sh -s <serial> studio.cu.pvj.debug`.
- Anything pushed to the phone's shared storage (test zips in Download, `/sdcard/ui.xml` from
  uiautomator) is deleted at the end.
- No commit or push without showing the owner the diff.

## 1. adb on this box

- Linux adb only. If `adb devices` prints nothing or `adb start-server` hangs: stop that call,
  `pkill -x adb`, run `adb nodaemon server` as a background task, THEN in a separate call
  `adb connect <ip:port>` for each device (racing them kills the server).
- **A Godot export kills the adb server.** After every build: repeat the dance, re-connect, re-check
  `adb devices`. Never build while a session is running on a phone.
- **A phone on a USB cable is the exception** (SESSION_45): it sits on Windows USB (`usbipd` says "Not
  shared"), so only the WINDOWS adb sees it, and the WSL adb (v34) and Windows adb (v37) fight over
  127.0.0.1:5037 under mirrored networking. Then never call `/usr/bin/adb`; use
  `ADB=/mnt/c/Users/<you>/AppData/Local/Android/Sdk/platform-tools/adb.exe`, start its server detached:
  `powershell.exe -NoProfile -Command "Start-Process -FilePath 'C:\Users\<you>\AppData\Local\Android\Sdk\platform-tools\adb.exe' -ArgumentList 'start-server' -WindowStyle Hidden"`,
  and pass APKs as `"$(wslpath -w dist/x.apk)"`.
- **After every export the USB phone shows `unauthorized`**: the export's adb server comes up without
  the trusted key. Fix: `$ADB kill-server`, start the server detached again (above), wait ~8 s. If it is
  still unauthorized, the owner taps Allow (tick "Always allow"); wait in a background loop, don't poll.
- Identify phones with `getprop ro.product.model`, never by address (they move). On 2026-11-02 the
  9a was on Android 17 with 4 KB pages.
- 9a battery drains ~17%/h under load and HDMI blocks charging; check `dumpsys battery` between
  batches.

## 2. Build a test APK

```bash
cp dist/pvj-debug-<v>.apk "$SCRATCH"/   # the script rm's it; put it back at the end, sha256 -c
for i in 1 2 3; do rm -f addons/gde_gozen/bin/~libgozen*
  tools/release_build.sh <preset version> debug > build/rb_$i.log 2>&1
  [ -s dist/pvj-debug-<v>.apk ] && break; done
rm -f addons/gde_gozen/bin/~libgozen*
```

- The version must equal the preset's `version/name` (else exit 2), so a test build overwrites the
  shipped debug artifact: back it up first, restore and verify after.
- The first export often dies silently (leaves `~libgozen…dll`): that's what the loop is for.
- Exit 1 with "ELF NOT 16 KB" for `libmediapipe_*` / `libimage_processing_util_jni` is known (the
  debug preset packs the pro MediaPipe libs); the APK is fine.
- Prove the build is fresh by content, not mtime: e.g. `unzip -p x.apk 'classes*.dex' | grep -a -c
  <new Kotlin string>`; GDScript changes show as new `assets/scripts/*.gdc` entries. Copy each build
  to the scratchpad as `before-debug.apk` / `after-debug.apk`.
- Compile check without a phone: `"$GODOT" --headless --path "$(wslpath -w .)" --quit-after 300 >
  build/headless_check.log 2>&1; grep -E "SCRIPT ERROR|Parse Error" …`. ⚠️ This runs the app against
  the PC's own user data (`AppData/Roaming/Godot/app_userdata/PVJ`), including Storage.self_clean.
- Install over Wi-Fi takes ~2 min for 134 MB: run `adb install -r` as a background task. `-r` keeps
  the debug app's data.

## 3. Run sessions

`scripts/session.sh <serial> <label> <n>` (set `RUNS=$SCRATCH/runs`): force-stop, `am start -W`,
25 s boot window, 2 min performing by KEYS (DPAD_RIGHT cut every 4 s, SPACE = next FX every 16 s, so
new shader variants compile), then LIB ▸ CLIP GRID, long-press clip n into SEQ A, SAVE, DONE, HOME,
force-stop, `du` + file counts via `run-as`. ~3.5 min each; run batches in the background (the tool
timeout is 10 min) and wait with an until-loop on the output file.

- Tap coordinates are 9a screen px (2424x1080). On another phone take a screencap and re-measure.
  LIB's SOURCES & LIBRARY accordion is collapsed after every launch — the script taps it first.
- What it reads needs `scripts/boot_timing.gd` (in the build since ff0f701):
  `[boot] <ms> storage ready (self-clean: …)`, `pipeline ready`, `first clip on the deck`,
  `splash gone — interactive` (ms since ENGINE start; the splash clip makes "interactive" ~6.5 s by
  design), `[boot] first 20 s: … over 50 ms`, `[perf] 30 s: fps, frames over 33 ms`, plus
  `[Thumbs] prewarm: N cached, M to generate` and `orphaned thumbnails removed`.
- Healthy 9a baseline (28 clips): storage ready 1.4–2.0 s, 1–3 boot stalls, 10–20 frames over 33 ms
  per 30 s at 59.7–60 fps. `am start` TotalTime is noisy (280–870 ms) — don't trend on it.
- `scripts/summarize.py "$RUNS" before after` prints the markdown table.

### Scaling the library without disk

Hard links are refused by SELinux under `run-as`; **symlinks** work and PVJ treats them as clips
(listing, ids, thumbnails, decode):

```bash
adb -s $S shell "run-as studio.cu.pvj.debug sh -c 'cd files/clips && mkdir -p bulk_a && for r in 1 2 3 4; do for f in pvj_audit_20/*.mp4; do ln -s \"/data/data/studio.cu.pvj.debug/files/clips/\$f\" \"bulk_a/x\${r}_\$(basename \"\$f\")\"; done; done'"
```

Renaming the folder (`mv bulk_b bulk_c`) = N new clips + N orphaned thumbnails in one step. The first
session after growing generates thumbnails (costly); the second is steady state — run both.
Importing for real: push a zip to `/sdcard/Download`, LIB ▸ [+] SOURCES ▸ IMPORT PACK, then in the
portrait picker roots ▸ Pixel 9a ▸ Download ▸ Search (pushed files are not in MediaStore).

### Testing a cleanup: plant, run, check

Plant one of each leftover in the debug app (`run-as … sh -c '…'`), one session, then `ls` what is
left. Always plant a file that MUST survive next to each one that must go (e.g. a mask image a
config names). ⚠️ Don't build the test on file mtimes: `FileAccess.get_modified_time` mis-orders files
on the 9a, and toybox `touch -d 2026-10-01 f` backdating is real but won't save a GDScript sort.

## 4. The Android 17 / API 37 16 KB emulator

AVD `pvj_api37_16k` (image `android-37.2;google_apis_ps16k;x86_64` r07, hand-installed; no
sdkmanager on this box). Boot, as a background task:

```bash
cd /mnt/c/Users/<you>/AppData/Local/Android/Sdk/emulator && ./emulator.exe -avd pvj_api37_16k -no-snapshot -no-boot-anim -port 5560 -gpu host
```

~3 min cold boot; the Linux adb sees `emulator-5560` (WSL mirrored networking). `getconf PAGESIZE`
= 16384. Check `dumpsys package <pkg> | grep pageSizeCompat` (0 = aligned).

- PVJ is arm64-only and the image is x86_64 → everything runs under libndk_translation: a
  FUNCTION test (install, launch, dialogs, decode, self-clean, 16 KB alignment), never a speed test.
  Expect 55 s to storage ready on the first launch (10 s later), 13–24 fps, the splash clip timing
  out (still fallback), `am start -W` timing out, `OS.get_memory_info()` = -1. The UWB HAL
  tombstone at boot is the image's own noise.
- First run shows "PLAY YOUR OWN CLIPS?": NOT NOW is at 550,898 (2400x1080).
- Shut down with `adb -s emulator-5560 shell reboot -p` (`emu kill` is refused here), then
  `adb disconnect 127.0.0.1:5561`.

## 5. Report

A before/after table (summarize.py), what was NOT reproduced said plainly, test plants called out
in the table, and the shipped debug APK restored in `dist/` (sha256 checked).
