#!/usr/bin/env bash
# M8a sweep — docs/MEDIAPIPE_MODULE.md §13.7.1 / §13.7.2
#
# Runs the tracking module across a matrix of settings, one app restart per
# cell, and prints a summary table. Built because the analysis stream was
# never 720p (§13.7.2): every range number this project holds was measured at
# CameraX's ~640x480 default, so the whole matrix needs re-taking.
#
#   usage:  tools/m8a_sweep.sh <adb-target> [cell ...]
#           tools/m8a_sweep.sh <P8-ip>:41234
#           tools/m8a_sweep.sh <P8-ip>:41234 crowd:720:edl0_int8:0.4
#
#   env:    LENS=rear|front (default rear — the crowd case)
#           SAMPLES=20  SETTLE=12  SWEEP_OUT=/path
#
#   cell format:  <mode>:<analysis_res>:<model>:<min_conf>[:<zoom>]
#     mode          crowd | landmark
#     analysis_res  480 | 720 | 1080
#     model         edl0_int8 | edl0_fp16 | edl0_fp32 | ssd   (crowd only)
#     min_conf      detector floor, 0.05..0.9                 (crowd only)
#     zoom          camera zoom ratio, default 1.0 — the LIVE range control
#
# ⚠️ Reads the ACTUAL values back from logcat (`analysis stream ACTUAL`,
# `started: ... delegate= model=`) and prints them beside what was asked for.
# A configured value is not a measured one — the delegate=cpu episode of
# 2026-09-10 cost an hour and a wrong conclusion.
set -uo pipefail

TARGET="${1:-}"
[ -z "$TARGET" ] && { echo "usage: $0 <adb-target> [mode:res:model:conf ...]"; exit 2; }
shift || true

CELLS=("$@")
if [ ${#CELLS[@]} -eq 0 ]; then
	# The default matrix: the range curve, then the model question at whatever
	# resolution turns out to be usable.
	CELLS=(
		crowd:480:edl0_int8:0.4      # the baseline every old number was taken at
		crowd:720:edl0_int8:0.4      # what §8 always assumed
		crowd:1080:edl0_int8:0.4     # is range still climbing?
		crowd:720:edl0_int8:0.25     # threshold, not resolution?
		crowd:720:edl0_fp32:0.4      # is int8 falling off XNNPACK?
		crowd:720:ssd:0.4            # different architecture
		crowd:720:edl0_int8:0.4:3.0  # ⚠️ ZOOM 3x at fixed res — separates "more
		                             #    pixels on target" from "narrower view".
		                             #    Zoom buys reach by SPENDING field of
		                             #    view; resolution buys it for free. If
		                             #    both work, the useful rig composes them.
		landmark:720:edl0_int8:0.4   # ⚠️ re-measure the face path: its 0.8-1 m
		                             #    is what §13.1 uses to argue faces
		                             #    cannot reach a crowd, and it was
		                             #    taken at 480p like everything else
	)
fi

PKG=com.pocketvj.app
ACT=$PKG/com.godot.game.GodotAppLauncher
CFG=/data/data/$PKG/files/settings.cfg
OUT="${SWEEP_OUT:-/tmp/m8a_$(date +%H%M%S)}"
LENS="${LENS:-rear}"        # ⚠️ the crowd case is the REAR lens pointed at a
                            #    room; front is the close-range convenience
                            #    case and will flatter every range number
SETTLE="${SETTLE:-12}"      # seconds before sampling starts
SAMPLES="${SAMPLES:-20}"    # 1 Hz stats lines to collect per cell
mkdir -p "$OUT"

A() { timeout 30 adb -s "$TARGET" "$@"; }

# A working settings.cfg to mutate. Pulled from the device so the operator's
# own deck/effect state is preserved — only [tracking] is touched.
BASE="$OUT/base.cfg"
A shell "run-as $PKG cat $CFG" 2>/dev/null | tr -d '\r' > "$BASE"
[ -s "$BASE" ] || { echo "!! could not read $CFG (device offline? run-as blocked?)"; exit 1; }
echo "base settings: $(wc -l < "$BASE") lines -> $OUT"

write_cell() {   # mode res model conf zoom -> stdout cfg
	python3 - "$BASE" "$1" "$2" "$3" "$4" "$LENS" "$5" <<'PY'
import io,re,sys
base,mode,res,model,conf,lens,zoom = sys.argv[1:8]
s = io.open(base, encoding='utf-8').read()
# [tracking] rebuilt wholesale so a stale key from a previous cell cannot leak
i = s.index('[tracking]')
j = s.index('[', i+10)
keep = {'lens': '"%s"' % lens}
for k in ('filter_min_cutoff','filter_beta','inference_hz','hands',
          'hands_only','publish_rot'):
    m = re.search(r'^%s=(.*)$' % k, s[i:j], re.M)
    if m: keep[k] = m.group(1)
blk  = '[tracking]\n\nenabled=true\n'
blk += 'crowd_spike=%s\n' % ('true' if mode == 'crowd' else 'false')
blk += 'analysis_res=%s\n' % res
blk += 'crowd_model="%s"\n' % model
blk += 'crowd_min_conf=%s\n' % conf
blk += 'zoom=%s\n' % zoom
for k, v in keep.items():
    blk += '%s=%s\n' % (k, v)
blk += '\n'
out = s[:i] + blk + s[j:]
# ⚠️ Deck on CAMERA (source=2) for the run. The screencap is the ONLY record of
# what the lens was actually pointed at, and without it a cell reading n=0
# cannot be told apart from "nobody was in shot" — which would invalidate the
# whole recall gate. Costs a little GPU; buys the difference between a
# measurement and a guess.
di = out.index('[deck]'); dj = out.index('[', di+7)
out = out[:di] + re.sub(r'^source=\d$', 'source=2', out[di:dj], flags=re.M) + out[dj:]
sys.stdout.write(out)
PY
}

echo
echo "⚠️  THE APP WILL RESTART ONCE PER CELL (${#CELLS[@]} times, ~20 s apart)."
echo "    That is the harness, NOT a crash. It has been mistaken for one twice."
echo "    Keep the subjects in frame throughout; each restart takes ~10 s to settle."
printf '\n%-30s %-11s %-10s %5s %5s %6s %5s %5s %6s\n' \
	CELL "ACTUAL res" "zoom rng" a_hz r_hz lat_ms n maxn score
printf '%s\n' "----------------------------------------------------------------------------------------------"

for CELL in "${CELLS[@]}"; do
	IFS=: read -r MODE RES MODEL CONF ZOOM <<< "$CELL"
	ZOOM="${ZOOM:-1.0}"
	LOG="$OUT/$MODE-$RES-$MODEL-$CONF-z$ZOOM.log"

	write_cell "$MODE" "$RES" "$MODEL" "$CONF" "$ZOOM" > "$OUT/cell.cfg"
	base64 -w0 "$OUT/cell.cfg" > "$OUT/cell.b64"

	A shell am force-stop $PKG >/dev/null 2>&1
	A push "$OUT/cell.b64" /data/local/tmp/cell.b64 >/dev/null 2>&1
	A shell "run-as $PKG sh -c 'base64 -d /data/local/tmp/cell.b64 > $CFG'" >/dev/null 2>&1
	A logcat -c >/dev/null 2>&1
	( timeout $((SETTLE + SAMPLES + 25)) adb -s "$TARGET" logcat -v time > "$LOG" 2>&1 ) &
	LPID=$!
	sleep 1
	A shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1
	A shell am start --display 0 -a android.intent.action.MAIN \
		-c android.intent.category.LAUNCHER -n $ACT >/dev/null 2>&1

	# Wait for enough stats lines, or give up — a cell that never produces
	# any is itself the result (see: the GPU delegate that never inferred).
	KEY='crowd|'; [ "$MODE" = landmark ] && KEY='|media|'
	# ⚠️ `grep -c` PRINTS 0 and EXITS 1 on no-match, so `|| echo 0` appends a
	# second 0 and the test sees "0\n0" -> "integer expression expected" -> the
	# while exits at once. That bug relaunched the app 8 times in 20 s and
	# looked exactly like the app crashing.
	DEADLINE=$((SECONDS + SETTLE + SAMPLES + 20))
	while :; do
		CNT=$(grep -ac -- "$KEY" "$LOG" 2>/dev/null); CNT=${CNT:-0}
		[ "$CNT" -ge "$SAMPLES" ] && break
		[ $SECONDS -ge $DEADLINE ] && break
		sleep 2
	done

	A shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1
	A shell screencap -p /data/local/tmp/c.png >/dev/null 2>&1
	# ⚠️ zoom belongs in the PNG name too — without it the z3.0 cell overwrote
	# the z1.0 one and the framing comparison was lost.
	A pull /data/local/tmp/c.png "$OUT/$MODE-$RES-$MODEL-$CONF-z$ZOOM.png" >/dev/null 2>&1
	kill $LPID 2>/dev/null; wait $LPID 2>/dev/null

	ACTUAL=$(grep -a "analysis stream ACTUAL" "$LOG" | tail -1 | sed 's/.*ACTUAL: //;s/ (asked.*//')
	ZRANGE=$(grep -a "zoom range:" "$LOG" | tail -1 | sed 's/.*zoom range: //;s/ (wanted.*//')
	if grep -aq "NO ANALYSIS FRAMES" "$LOG"; then ACTUAL="NO-FRAMES"; fi
	DELEG=$(grep -a "started: lens" "$LOG" | tail -1 | grep -oE "delegate=[a-z]+" | cut -d= -f2)
	# median-ish: drop the first samples (warm-up), average the rest
	read -r AHZ RHZ LAT NN MAXN SCORE <<< "$(
		grep -a -- "$KEY" "$LOG" | tail -n +4 | sed 's/.*: //' | awk -F'|' '
			{a+=$2;r+=$3;l+=$5;n+=$7;if($8>m)m=$8;s+=$9;c++}
			END{if(c)printf "%.1f %.1f %.0f %.1f %d %.2f",a/c,r/c,l/c,n/c,m,s/c;
			    else print "- - - - - -"}')"
	printf '%-30s %-11s %-10s %5s %5s %6s %5s %5s %6s\n' \
		"$CELL" "${ACTUAL:-?}" "${ZRANGE:-?}" "$AHZ" "$RHZ" "$LAT" "$NN" "$MAXN" "$SCORE"
done

echo
echo "logs + screencaps: $OUT"
echo "columns: a_hz=frames analyzed  r_hz=inferences COMPLETED (the real rate)"
echo "         n=mean persons found  maxn=most seen  score=mean confidence"
echo "⚠️ compare n against the ACTUAL number of people in frame — the harness"
echo "   cannot know it, and recall is the §13.7 go/no-go."
