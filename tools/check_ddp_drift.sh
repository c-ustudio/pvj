#!/usr/bin/env bash
# Fail if scripts/ddp_output.gd has drifted from the led-matrix-bridge copy.
#
# WHY THIS EXISTS
# ddp_output.gd is a VENDORED FILE. The authoritative copy lives in
# c-ustudio/led-matrix-bridge (pocketvj/ddp_output.gd), where its wire format is
# asserted byte-for-byte against the TouchDesigner sender by
# tests/test_ddp_roundtrip.py — 86 checks. One firmware build serves both
# senders, so the moment the two GDScript copies disagree, PocketVJ is speaking a
# protocol nothing tests. That failure is silent: frames still send, the panel
# still lights, and only the corrupt ones tell you.
#
# ⚠️ EDIT THE BRIDGE COPY, NOT THIS ONE. A fix made here is a fix that gets
# reverted by the next sync, and the round-trip tests never see it.
#
# TWO DIRECTIONS OF DRIFT, both caught:
#   1. The PocketVJ copy was edited      -> local hash != recorded hash
#   2. Upstream moved and we did not     -> bridge hash != recorded hash
#
# The recorded hash in tools/ddp_output.upstream.sha256 is what makes case 1 work
# WITHOUT the bridge repo present — on CI, on a fresh clone, on anyone else's
# machine. The bridge comparison is an upgrade when the repo is there, not a
# requirement.
#
# Usage:  tools/check_ddp_drift.sh
# Bridge repo location: $DDP_BRIDGE_REPO, else ~/led-matrix-bridge

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDORED="$REPO_ROOT/scripts/ddp_output.gd"
MANIFEST="$REPO_ROOT/tools/ddp_output.upstream.sha256"
BRIDGE_REPO="${DDP_BRIDGE_REPO:-$HOME/led-matrix-bridge}"
UPSTREAM="$BRIDGE_REPO/pocketvj/ddp_output.gd"

red()  { printf '\033[31m%s\033[0m\n' "$*"; }
ylw()  { printf '\033[33m%s\033[0m\n' "$*"; }
grn()  { printf '\033[32m%s\033[0m\n' "$*"; }

fail() {
	red "═══════════════════════════════════════════════════════════════"
	red " DDP DRIFT CHECK FAILED"
	red "═══════════════════════════════════════════════════════════════"
	printf '%s\n' "$@"
	echo
	echo "ddp_output.gd is vendored from c-ustudio/led-matrix-bridge, where its"
	echo "wire format is asserted byte-for-byte against the TouchDesigner sender."
	echo "A silent divergence means PocketVJ speaks a protocol nothing tests."
	echo
	echo "To bypass once (you had better be sure):  git commit --no-verify"
	exit 1
}

[ -f "$VENDORED" ] || fail "Missing vendored file: $VENDORED"
[ -f "$MANIFEST" ] || fail "Missing manifest: $MANIFEST" \
	"Regenerate with: sha256sum scripts/ddp_output.gd | awk '{print \$1}' > tools/ddp_output.upstream.sha256"

recorded="$(tr -d '[:space:]' < "$MANIFEST")"
local_hash="$(sha256sum "$VENDORED" | awk '{print $1}')"

# ── Case 1: the vendored copy was edited in this repo ────────────────────
if [ "$local_hash" != "$recorded" ]; then
	details="scripts/ddp_output.gd does not match the recorded upstream hash.

  recorded : $recorded
  local    : $local_hash"
	if [ -f "$UPSTREAM" ]; then
		details="$details

Diff against the bridge copy ($UPSTREAM):
$(diff -u "$UPSTREAM" "$VENDORED" | head -40)"
	fi
	fail "$details" "
If this change is WANTED, make it in the bridge repo first, let
tests/test_ddp_roundtrip.py pass there, then re-sync:

  cp \"$UPSTREAM\" scripts/ddp_output.gd
  sha256sum scripts/ddp_output.gd | awk '{print \$1}' > tools/ddp_output.upstream.sha256"
fi

# ── Case 2: upstream moved and we did not ────────────────────────────────
if [ ! -f "$UPSTREAM" ]; then
	ylw "[ddp-drift] bridge repo not found at $BRIDGE_REPO — upstream comparison skipped."
	ylw "[ddp-drift] local copy matches the recorded hash, which is the check that"
	ylw "            works everywhere. Set DDP_BRIDGE_REPO to enable the full check."
	grn "[ddp-drift] OK (local vs recorded)"
	exit 0
fi

upstream_hash="$(sha256sum "$UPSTREAM" | awk '{print $1}')"
if [ "$upstream_hash" != "$recorded" ]; then
	fail "The BRIDGE copy has moved ahead — PocketVJ is stale.

  recorded : $recorded
  bridge   : $upstream_hash
  local    : $local_hash  (matches recorded, so nothing was edited here)

Diff (bridge -> local):
$(diff -u "$UPSTREAM" "$VENDORED" | head -40)" "
Re-sync and record the new hash:

  cp \"$UPSTREAM\" scripts/ddp_output.gd
  sha256sum scripts/ddp_output.gd | awk '{print \$1}' > tools/ddp_output.upstream.sha256"
fi

grn "[ddp-drift] OK — vendored copy matches the bridge and the recorded hash."
exit 0
