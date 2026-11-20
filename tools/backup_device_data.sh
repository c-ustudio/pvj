#!/usr/bin/env bash
# tools/backup_device_data.sh — copy a PVJ install's app data off a phone
# BEFORE any scripted device test. Run it at the start of every test session.
#
#     tools/backup_device_data.sh                         # studio.cu.pvj.debug, the only device
#     tools/backup_device_data.sh -s <9a-ip>:34387  # pick the device
#     tools/backup_device_data.sh -s <serial> com.pocketvj.app
#     ANDROID_ADB_SERVER_PORT=5038 tools/backup_device_data.sh -s <P8-serial>   # USB Pixel 8
#
# What: everything in the app's user:// (= /data/user/0/<pkg>/files) except
# rebuildable caches — settings.cfg, storage.cfg, sequence.tres, sequence_b.tres,
# sequences/ (the six slots), playlist, warp/regions/calibration, masks/,
# mask_sets/, drive auth/cache… Skipped: thumbs/, thumb_cache/, clips/,
# demo_stage/, calib_dump/, logs/, shader_cache/, profileInstalled, S4 csv dumps. The clips themselves live in
# the SAF folder (Movies/PVJ), not here.
#
# Where: $PVJ_BACKUP_DIR (default ~/pvj_backups — OUTSIDE the repo: drive_auth
# holds tokens) / <pkg>_<model>_<YYYY-MM-DD_HHMMSS>/, plus MANIFEST.txt with the
# device, the app version and a sha256 per file.
#
# How: `adb exec-out run-as <pkg> tar` — so the package MUST be debuggable.
# The release apps (studio.cu.pvj, signed release) are NOT: run-as refuses,
# their data cannot be copied off, and that is exactly why scripted SAVE / DEL /
# LOAD tests run only on the debug build (tools/release_build.sh <v> debug →
# studio.cu.pvj.debug, its own data next to the real app). This script exits 3
# for a non-debuggable package rather than pretending.
#
# Restore by hand if ever needed (debuggable package, app force-stopped):
#     tar -cf - -C <backup dir> <items> | adb exec-in run-as <pkg> tar -xf - -C files
set -euo pipefail

SERIAL=""
if [[ "${1:-}" == "-s" ]]; then SERIAL="${2:?-s needs a serial}"; shift 2; fi
PKG="${1:-studio.cu.pvj.debug}"
OUT_ROOT="${PVJ_BACKUP_DIR:-$HOME/pvj_backups}"
SKIP=(thumbs thumb_cache clips demo_stage calib_dump logs shader_cache profileInstalled)

ADB=(adb)
[[ -n "$SERIAL" ]] && ADB=(adb -s "$SERIAL")
die() { echo "backup_device_data: $1" >&2; exit "${2:-1}"; }

[[ "$("${ADB[@]}" get-state 2>/dev/null)" == "device" ]] || die "no device${SERIAL:+ $SERIAL} (ANDROID_ADB_SERVER_PORT=${ANDROID_ADB_SERVER_PORT:-5037})"
MODEL="$("${ADB[@]}" shell getprop ro.product.model | tr -d '\r' | tr ' ' '_')"
# ⚠️ No early-exit greps (grep -q / -m) straight on adb output: under pipefail the
# writer dies of SIGPIPE and set -e quits SILENTLY with 141. Capture, then grep.
pm_path="$("${ADB[@]}" shell pm path "$PKG" 2>/dev/null || true)"
[[ "$pm_path" == *package:* ]] || die "$PKG is not installed on $MODEL" 2

# run-as is the gate: it only works for a debuggable package.
if ! probe="$("${ADB[@]}" shell run-as "$PKG" true 2>&1)" || [[ -n "${probe//[$'\r\n']/}" ]]; then
    die "$PKG on $MODEL is not debuggable (run-as: ${probe//[$'\r\n']/ }).
  Its data CANNOT be backed up — do not run scripted SAVE/DEL/LOAD tests on it.
  Test on the debug build instead: tools/release_build.sh <version> debug → studio.cu.pvj.debug" 3
fi

# What is in user:// right now, minus the caches.
mapfile -t ALL < <("${ADB[@]}" shell "run-as $PKG sh -c 'cd files 2>/dev/null && ls -1A'" | tr -d '\r')
ITEMS=()
SKIPPED=()
for f in "${ALL[@]}"; do
    [[ -z "$f" ]] && continue
    skip=0
    for s in "${SKIP[@]}"; do [[ "$f" == "$s" ]] && skip=1; done
    [[ "$f" == s4_*.csv ]] && skip=1
    if (( skip )); then SKIPPED+=("$f"); else ITEMS+=("$f"); fi
done
(( ${#ITEMS[@]} )) || die "$PKG on $MODEL has no app data yet (files/ is empty) — nothing to back up" 4

STAMP="$(date +%Y-%m-%d_%H%M%S)"
DEST="$OUT_ROOT/${PKG}_${MODEL}_${STAMP}"
mkdir -p "$DEST"
"${ADB[@]}" exec-out "run-as $PKG tar -cf - -C files ${ITEMS[*]}" > "$DEST/.data.tar"
[[ -s "$DEST/.data.tar" ]] || die "tar from the device came back empty — nothing written to $DEST"
tar -xf "$DEST/.data.tar" -C "$DEST"
rm -f "$DEST/.data.tar"

# Cross-check: as many files as the device has under the same items.
want="$("${ADB[@]}" shell "run-as $PKG sh -c 'cd files && find ${ITEMS[*]} -type f | wc -l'" | tr -d '\r ')"
got="$(cd "$DEST" && find . -type f | wc -l | tr -d ' ')"
[[ "$want" == "$got" ]] || die "copied $got files but the device has $want — backup in $DEST is INCOMPLETE"

pkg_dump="$("${ADB[@]}" shell dumpsys package "$PKG" | tr -d '\r')"
VER="$(grep -E 'versionName|versionCode' <<<"$pkg_dump" | head -2 | sed 's/^ *//' | tr '\n' ' ')"
{
    echo "package: $PKG"
    echo "device:  $MODEL ${SERIAL:+($SERIAL)}"
    echo "app:     $VER"
    echo "taken:   $(date -Iseconds)"
    echo "skipped: ${SKIPPED[*]:-(none)}"
    echo
    (cd "$DEST" && find . -type f ! -name MANIFEST.txt -print0 | sort -z | xargs -0 sha256sum)
} > "$DEST/MANIFEST.txt"

echo "backed up $got files from $PKG on $MODEL -> $DEST"
if [[ -d "$DEST/sequences" ]]; then
    for f in "$DEST"/sequences/slot_*.tres; do
        [[ -f "$f" ]] || continue
        n="$(grep -m1 '^entries' "$f" | grep -o '"[^"]*"' | wc -l | tr -d ' ')"
        printf '  %s  label="%s"  %s clips\n' "$(basename "$f")" \
            "$(grep -m1 '^label' "$f" | cut -d'"' -f2)" "$n"
    done
fi
