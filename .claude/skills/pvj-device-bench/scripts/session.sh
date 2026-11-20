#!/usr/bin/env bash
# session.sh <serial> <label> <n> — one measured PVJ session on the DEBUG app.
#
# launch (am start -W) → 25 s boot window → 2 min performing (a cut every 4 s,
# an FX change every 16 s) → LIB ▸ CLIP GRID, long-press clip n into SEQ A,
# SAVE slot 1 → HOME → force-stop → du/file counts of files/ and cache/.
#
# Output: runs/<label>/s<n>.{log,start,du,grid.png} next to this script (or
# $RUNS), and a summary on stdout. Tap coordinates are Pixel 9a screen px
# (2424x1080 landscape); check them with a screencap on any other phone.
# Needs a build with scripts/boot_timing.gd (the [boot] / [perf] lines).
set -u
S=$1; LABEL=$2; N=$3
PKG=${PKG:-studio.cu.pvj.debug}
OUT=${RUNS:-$(dirname "$0")/runs}/$LABEL; mkdir -p "$OUT"
a() { adb -s "$S" shell "$@"; }
a am force-stop "$PKG"; sleep 1; a am force-stop "$PKG"
a logcat -c
adb -s "$S" logcat -v time -s godot VJMIXStorage > "$OUT/s$N.log" 2>&1 &
LP=$!
a input keyevent WAKEUP
START=$(a am start -W --display 0 -n "$PKG/com.godot.game.GodotAppLauncher")
echo "$START" > "$OUT/s$N.start"
grep -q "Starting: Intent" <<<"$START" || echo "WARN: launch did not report Starting: Intent"
sleep 25
for k in $(seq 1 30); do                # 2 min: a cut every 4 s, FX change every 16 s
  sleep 4
  a input keyevent KEYCODE_DPAD_RIGHT
  (( k % 4 == 0 )) && a input keyevent KEYCODE_SPACE
done
a input tap 1676 96; sleep 1.2           # LIB
a input tap 300 220; sleep 1             # [+] SOURCES & LIBRARY (collapsed after every launch)
a input tap 200 330; sleep 3             # CLIP GRID…
COL=$(( (N - 1) % 8 )); ROW=$(( (N - 1) / 8 % 3 ))
a input swipe $((248 + COL * 275)) $((220 + ROW * 215)) $((248 + COL * 275)) $((220 + ROW * 215)) 900
sleep 1
a input tap 874 834; sleep 1.5           # SAVE (slot 1)
adb -s "$S" exec-out screencap -p > "$OUT/s$N.grid.png"
a input tap 2294 58; sleep 1             # DONE
a input keyevent HOME; sleep 3
a am force-stop "$PKG"; sleep 1
kill $LP 2>/dev/null
a "run-as $PKG sh -c 'cd /data/data/$PKG && du -sk files cache code_cache files/* cache/* 2>/dev/null; echo; echo files_n \$(find files -type f | wc -l); echo cache_n \$(find cache -type f | wc -l); echo thumbs_n \$(ls cache/thumbs 2>/dev/null | wc -l); echo shader_n \$(find files/shader_cache -type f 2>/dev/null | wc -l)'" > "$OUT/s$N.du"
echo "== $LABEL session $N"; grep -E "TotalTime" "$OUT/s$N.start"
grep -E "\[boot\]|\[perf\]|prewarm|self-clean|orphaned" "$OUT/s$N.log" | sed 's/^.*godot *([0-9 ]*): //'
grep -E "^[0-9]+\s+(files|cache)$|_n " "$OUT/s$N.du" | tr '\n' ' '; echo
