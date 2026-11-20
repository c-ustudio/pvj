#!/usr/bin/env bash
# tools/release_build.sh — the PVJ release exports and their checks, from WSL.
# Setup: README.md, "Building". Machine paths and the signing env come from
# the environment or tools/local.env (see tools/local.env.example).
#
#     tools/release_build.sh 0.6.0-beta1            # everything into dist/
#     tools/release_build.sh 0.6.0-beta1 public     # only the public .aab + .apk
#     tools/release_build.sh 0.6.0-beta1 apk        # only the public .apk (+ .sha256)
#     tools/release_build.sh 0.6.0-beta1 aab        # only the public .aab
#     tools/release_build.sh 0.6.0-beta1 pro        # only the pro .apk
#     tools/release_build.sh 0.6.0-beta1 debug      # the DEBUG test .apk (studio.cu.pvj.debug)
#     tools/release_build.sh 0.6.0-beta1 check      # only the checks on dist/
#
# Produces  dist/pvj-<v>.aab  dist/pvj-<v>.apk  dist/pvj-<v>.apk.sha256
#           dist/pvjpro-<v>.apk
#           dist/pvj-debug-<v>.apk   (debug only — never shipped)
#
# The DEBUG build is for device testing: package studio.cu.pvj.debug ("PVJ
# debug"), so it installs NEXT TO the real app with its own data, debuggable so
# `adb shell run-as` works (tools/backup_device_data.sh), signed with the
# editor's debug keystore. Scripted SAVE/DEL/LOAD tests run on it, never on the
# performer's studio.cu.pvj. Debug template: measure fps on a release build.
# all RELEASE builds signed with the upload key (GODOT_ANDROID_KEYSTORE_RELEASE_*
# from $PVJ_KEYS_ENV, passed to the Windows Godot through WSLENV).
#
# The version is NOT taken from here: version/name and version/code live in
# export_presets.cfg — the argument only names the files, and the script
# refuses to run when the two disagree.
set -euo pipefail

VERSION="${1:?usage: release_build.sh <versionName> [all|public|apk|aab|pro|debug|check]}"
WHAT="${2:-all}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Machine-specific paths come from the environment, or from tools/local.env
# (git-ignored; copy tools/local.env.example). Nothing here defaults to one
# person's machine.
[[ -f "$ROOT/tools/local.env" ]] && { set -a; # shellcheck disable=SC1091
    source "$ROOT/tools/local.env"; set +a; }
# The Godot 4.6.3 console binary (on WSL, the Windows *_console.exe).
GODOT="${GODOT:-}"
# A file that exports GODOT_ANDROID_KEYSTORE_RELEASE_PATH/_USER/_PASSWORD.
# Keep it, and the keystore, outside the repository.
PVJ_KEYS_ENV="${PVJ_KEYS_ENV:-}"
# Optional: a SEPARATE Play upload key for the .aab only. Same variable names
# as PVJ_KEYS_ENV; the sideload .apk keeps the app signing key. Unset = the
# .aab is signed with PVJ_KEYS_ENV too.
PVJ_AAB_KEYS_ENV="${PVJ_AAB_KEYS_ENV:-}"
SDK="${ANDROID_SDK:-}"
BT="$SDK/build-tools/37.0.0"
JAVA="${JAVA:-/mnt/c/Program Files/Android/Android Studio/jbr/bin/java.exe}"
BUNDLETOOL="${BUNDLETOOL:-}"
PRESET_PUBLIC="VJMIX Mobile"        # preset.0 — studio.cu.pvj
PRESET_PRO="VJMIX Mobile Pro"       # preset.1 — com.pocketvj.app
PRESET_DEBUG="VJMIX Mobile Debug"   # preset.2 — studio.cu.pvj.debug (debug template)
WROOT="$(wslpath -w "$ROOT")"

PUB_AAB="dist/pvj-$VERSION.aab"
PUB_APK="dist/pvj-$VERSION.apk"
PRO_APK="dist/pvjpro-$VERSION.apk"
DEBUG_APK="dist/pvj-debug-$VERSION.apk"

log() { printf '\n\033[1m[release] %s\033[0m\n' "$*"; }

# ── preconditions ───────────────────────────────────────────────────────────
preset_version="$(grep -m1 '^version/name=' export_presets.cfg | cut -d'"' -f2)"
if [[ "$preset_version" != "$VERSION" ]]; then
    echo "export_presets.cfg says version/name=$preset_version, you asked for $VERSION — fix the preset first." >&2
    exit 2
fi
# (the checks need Godot too: tools/scan_gdc_strings.gd)
[[ -n "$GODOT" && -x "$GODOT" ]] || { echo "no Godot at '$GODOT' — set GODOT (or tools/local.env) to the Godot 4.6.3 console binary" >&2; exit 2; }
# Release keys: needed for release exports only. The debug build is signed with
# the editor's debug keystore, so contributors can build it with no keys at all.
if [[ "$WHAT" != "check" && "$WHAT" != "debug" ]]; then
    [[ -n "$PVJ_KEYS_ENV" && -f "$PVJ_KEYS_ENV" ]] || { echo "no keystore env at '$PVJ_KEYS_ENV' — set PVJ_KEYS_ENV (README, Building)" >&2; exit 2; }
    set -a; # shellcheck disable=SC1090
    source "$PVJ_KEYS_ENV"; set +a
    : "${GODOT_ANDROID_KEYSTORE_RELEASE_PATH:?}" "${GODOT_ANDROID_KEYSTORE_RELEASE_USER:?}" "${GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD:?}"
    export WSLENV="${WSLENV:+$WSLENV:}GODOT_ANDROID_KEYSTORE_RELEASE_PATH:GODOT_ANDROID_KEYSTORE_RELEASE_USER:GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD"
    # Godot checks the key for the DEBUG keystore even on a release export
    # when package/signed is on; leaving it empty uses the editor's default.
fi
mkdir -p dist
[[ -f dist/.gdignore ]] || : > dist/.gdignore   # Godot must never import dist/

# ── the preset's export_format must match the extension (Godot refuses
#    "x.apk" from an AAB preset and vice versa), so flip it per export and put
#    the committed value back whatever happens. ────────────────────────────
ORIG_PRESETS="$(mktemp)"; cp export_presets.cfg "$ORIG_PRESETS"
restore() { cp "$ORIG_PRESETS" export_presets.cfg; rm -f "$ORIG_PRESETS"; }
trap restore EXIT

set_format() {   # set_format <preset index> <0=apk|1=aab>
    python3 - "$1" "$2" <<'PY'
import re, sys
idx, fmt = sys.argv[1], sys.argv[2]
s = open("export_presets.cfg", encoding="utf-8").read()
head = f"[preset.{idx}.options]"
a = s.index(head); b = s.find("\n[preset.", a + 1); b = len(s) if b < 0 else b
sec = re.sub(r"^gradle_build/export_format=\d", f"gradle_build/export_format={fmt}", s[a:b], count=1, flags=re.M)
open("export_presets.cfg", "w", encoding="utf-8", newline="\n").write(s[:a] + sec + s[b:])
PY
}

export_one() {   # export_one <preset name> <relative out path> [release|debug]
    local out_win="$WROOT\\${2//\//\\}"
    local mode="--export-${3:-release}"
    local elog="build/export-$(basename "$2").log"
    log "${mode#--} \"$1\" -> $2   (full log: $elog)"
    rm -f "$2"; mkdir -p build
    # ⚠️ Godot's output goes to a FILE, never through a pipe that may close:
    # a Windows exe started from WSL BLOCKS for ever on a write to a closed
    # pipe (a `| head` here once left a finished export hanging at 6 MB RSS).
    "$GODOT" --headless --path "$WROOT" "$mode" "$1" "$out_win" > "$elog" 2>&1 &
    local gpid=$!
    # ⚠️ Godot does NOT exit after a Gradle export on this box (seen twice on
    # 2026-10-07: artifact complete, "[ DONE ] export" in the log, 6 MB RSS,
    # for ever). Wait for the log to say done or failed, give the file copy a
    # moment, then put the console exe down. (The editor is a different image
    # name, Godot_v4.6.3-stable_win64.exe, and is left alone.)
    while kill -0 "$gpid" 2>/dev/null; do
        if grep -q 'DONE.*export\|export for preset .* failed\|ERROR: Cannot export' "$elog" 2>/dev/null; then
            sleep 8
            taskkill.exe /IM "$(basename "$GODOT")" /F >/dev/null 2>&1 || true
            wait "$gpid" 2>/dev/null || true
            break
        fi
        sleep 5
    done
    grep -Ei 'error|fail|vjmix|tier|BUILD (SUCCESSFUL|FAILED)|savepack|Done' "$elog" | grep -v '^\s*$' | tail -15 || true
    [[ -s "$2" ]] || { echo "export produced no $2" >&2; exit 1; }
}

# ── exports ─────────────────────────────────────────────────────────────────
if [[ "$WHAT" == "all" || "$WHAT" == "public" || "$WHAT" == "aab" ]]; then
    set_format 0 1
    if [[ -n "$PVJ_AAB_KEYS_ENV" ]]; then
        [[ -f "$PVJ_AAB_KEYS_ENV" ]] || { echo "no upload-key env at $PVJ_AAB_KEYS_ENV" >&2; exit 2; }
        ( set -a; source "$PVJ_AAB_KEYS_ENV"; set +a; export_one "$PRESET_PUBLIC" "$PUB_AAB" )
    else
        export_one "$PRESET_PUBLIC" "$PUB_AAB"
    fi
fi
if [[ "$WHAT" == "all" || "$WHAT" == "public" || "$WHAT" == "apk" ]]; then
    set_format 0 0; export_one "$PRESET_PUBLIC" "$PUB_APK"
    (cd dist && sha256sum "$(basename "$PUB_APK")" > "$(basename "$PUB_APK").sha256")
fi
if [[ "$WHAT" == "all" || "$WHAT" == "pro" ]]; then
    set_format 1 0; export_one "$PRESET_PRO" "$PRO_APK"
fi
if [[ "$WHAT" == "debug" ]]; then   # never part of "all": it is not a release artifact
    set_format 2 0; export_one "$PRESET_DEBUG" "$DEBUG_APK" debug
fi
restore; trap - EXIT

# ── checks ──────────────────────────────────────────────────────────────────
log "artifacts"
ls -la dist/*"$VERSION"* 2>/dev/null || true

for apk in "$PUB_APK" "$PRO_APK" "$DEBUG_APK"; do
    [[ -f "$apk" ]] || continue
    log "$apk — manifest (aapt2)"
    "$BT/aapt2.exe" dump badging "$(wslpath -w "$apk")" | grep -E "^package:|^application-label:|^application-debuggable|^minSdkVersion|^targetSdkVersion|uses-permission|^native-code" || true
    log "$apk — zipalign -c -P 16"
    "$BT/zipalign.exe" -c -P 16 -v 4 "$(wslpath -w "$apk")" | tail -1
    log "$apk — signer"
    # (apksigner.bat prints nothing when started from WSL: run its jar.)
    "$JAVA" -jar "$(wslpath -w "$BT/lib/apksigner.jar")" verify --print-certs "$(wslpath -w "$apk")" 2>&1 | tr -d '\r' | grep -iE "certificate DN|SHA-256 digest|DOES NOT VERIFY|ERROR" || true
done
if [[ -f "$PUB_AAB" ]]; then
    log "$PUB_AAB — signer (the Play upload key)"
    "$(dirname "$JAVA")/keytool.exe" -printcert -jarfile "$(wslpath -w "$PUB_AAB")" 2>&1 | tr -d '\r' | grep -E "Owner:|SHA256:" | head -2 || true
    log "$PUB_AAB — manifest (bundletool)"
    "$JAVA" -jar "$(wslpath -w "$BUNDLETOOL")" dump manifest --bundle="$(wslpath -w "$PUB_AAB")" \
        | grep -Eo 'package="[^"]+"|versionCode="[^"]+"|versionName="[^"]+"|android:name="android\.permission\.[A-Z_]+"|minSdkVersion="[^"]+"|targetSdkVersion="[^"]+"' | sort -u
fi

# ── permission allowlist (public + debug) ───────────────────────────────────
# The public app asks for the camera and the mic and NOTHING else: no storage,
# no media, no network (STORAGE_REWORK_PLAN §D). The third entry is androidx's
# app-private signature permission, named after the package. Anything else —
# a new library's manifest merging in INTERNET, say — fails the build here,
# before it reaches Play. minSdk must be 30 (recordings land in the gallery by
# path from Android 11). The pro build is not checked (it adds network on
# purpose; "Later: pro").
ALLOWED_PERMS="android.permission.CAMERA android.permission.RECORD_AUDIO"
MIN_SDK=30
PERM_FAIL=0
check_perms() {   # $1 label, $2 package, $3 minSdk; stdin: one permission per line
    local bad="" p
    while read -r p; do
        [[ -z "$p" ]] && continue
        case " $ALLOWED_PERMS $2.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION " in
            *" $p "*) ;;
            *) bad+=" $p" ;;
        esac
    done
    if [[ -n "$bad" ]]; then
        echo "PERMISSION NOT ALLOWED in $1:$bad"; PERM_FAIL=1
    else
        echo "$1: permissions OK (camera, mic, the androidx receiver permission)"
    fi
    if [[ "$3" != "$MIN_SDK" ]]; then
        echo "$1: minSdk is '$3', must be $MIN_SDK"; PERM_FAIL=1
    fi
}
log "permission allowlist"
for apk in "$PUB_APK" "$DEBUG_APK"; do
    [[ -f "$apk" ]] || continue
    badging=$("$BT/aapt2.exe" dump badging "$(wslpath -w "$apk")" | tr -d '\r')
    pkg=$(sed -n "s/^package: name='\([^']*\)'.*/\1/p" <<< "$badging")
    sdk=$(sed -n "s/^minSdkVersion:'\([0-9]*\)'.*/\1/p" <<< "$badging")
    check_perms "$apk" "$pkg" "$sdk" < <(sed -n "s/^uses-permission: name='\([^']*\)'.*/\1/p" <<< "$badging")
done
if [[ -f "$PUB_AAB" ]]; then
    man=$("$JAVA" -jar "$(wslpath -w "$BUNDLETOOL")" dump manifest --bundle="$(wslpath -w "$PUB_AAB")" | tr -d '\r')
    pkg=$(grep -m1 -Eo 'package="[^"]+"' <<< "$man" | cut -d'"' -f2)
    sdk=$(grep -m1 -Eo 'minSdkVersion="[^"]+"' <<< "$man" | cut -d'"' -f2)
    check_perms "$PUB_AAB" "$pkg" "$sdk" < <(grep -A2 '<uses-permission' <<< "$man" | grep -Eo 'android:name="[^"]+"' | cut -d'"' -f2)
fi

# ── no pro network code in a public artifact ────────────────────────────────
# ClipServer / DriveAuth / DriveClient, their browsers and the OAuth client
# secret are pro only (export_presets.cfg exclude_filter). The files must be
# absent, and no compiled script may carry a Google OAuth / API string. The
# .gdc files are zstd-compressed, so tools/scan_gdc_strings.gd decodes them —
# a byte grep misses the secret even in the beta2 builds that shipped it.
PRO_NET_FILES='scripts/(clip_server|drive_auth|drive_client|clip_browser_ui|drive_browser_ui)\.gd|(ClipBrowser|DriveBrowser)\.(tscn|scn)'
GOOGLE_STRINGS=(GOCSPX apps.googleusercontent.com googleapis.com accounts.google.com)
NET_FAIL=0
check_no_pro_net() {   # $1 artifact (apk or aab)
    local hits tmp
    hits=$(unzip -Z1 "$1" | grep -E "$PRO_NET_FILES" || true)
    if [[ -n "$hits" ]]; then
        echo "$1: pro network files inside:"; sed 's/^/    /' <<< "$hits"; NET_FAIL=1
    fi
    tmp=$(mktemp -d -p "$ROOT/build")
    unzip -q "$1" '*assets/*' -d "$tmp" 2>/dev/null || true
    if ! "$GODOT" --headless --path "$WROOT" --script tools/scan_gdc_strings.gd -- \
            "$(wslpath -w "$tmp")" "${GOOGLE_STRINGS[@]}" > "$tmp.log" 2>&1; then
        echo "$1: Google OAuth/API strings in its scripts (or nothing readable):"
        grep -E '^(HIT|UNREADABLE)|scan_gdc_strings' "$tmp.log" | sed 's/^/    /'; NET_FAIL=1
    elif grep -rlaE "$(IFS='|'; echo "${GOOGLE_STRINGS[*]}")" "$tmp" > "$tmp.grep"; then
        echo "$1: Google OAuth/API strings in its assets:"; sed 's/^/    /' "$tmp.grep"; NET_FAIL=1
    else
        # (only the summary line: Godot's own output also has "N files" in it)
        echo "$1: no pro network code ($(grep -o 'scan_gdc_strings: [0-9]* files' "$tmp.log" | grep -o '[0-9]* files') scanned)"
    fi
    rm -rf "$tmp" "$tmp.log" "$tmp.grep"
}
log "no pro network code in the public build"
for f in "$PUB_AAB" "$PUB_APK" "$DEBUG_APK"; do
    [[ -f "$f" ]] && check_no_pro_net "$f"
done
# (no `grep -q` on a pipe: under pipefail its early exit fails unzip with SIGPIPE)
if [[ -f "$PRO_APK" ]] && [[ "$(unzip -Z1 "$PRO_APK" | grep -c 'scripts/drive_auth.gdc')" == 0 ]]; then
    echo "$PRO_APK: drive_auth.gdc missing — the pro build lost its Drive browser"; NET_FAIL=1
fi

log "16 KB alignment + sha256"
ALIGN_RC=0
python3 tools/check_android_artifact.py $(ls dist/*"$VERSION".aab dist/*"$VERSION".apk 2>/dev/null) || ALIGN_RC=$?
if [[ $PERM_FAIL -ne 0 ]]; then
    echo "RELEASE CHECK FAILED: a public/debug artifact asks for a permission outside the allowlist, or minSdk is wrong (see above)" >&2
    exit 3
fi
if [[ $NET_FAIL -ne 0 ]]; then
    echo "RELEASE CHECK FAILED: pro network code or a Google OAuth string in a public artifact (see above)" >&2
    exit 4
fi
exit $ALIGN_RC
