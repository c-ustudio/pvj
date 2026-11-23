# PocketVJ — the OSC namespace (spec + v1)

**Status: v1 INBOUND SHIPPED 2026-08-19** (this session). The pillar that
makes it "pro" (`POCKETVJ_PRO_NORTHSTAR.md` §2.3, `INTERCHANGE_SPEC.md`
§2/§2a): speak the standard the whole booth speaks — TD, Resolume, OBS,
TouchOSC, lighting desks — so PocketVJ drops into any rig. Building to
Resolume's standards is building to everyone's standards.

## 1. Transport

- **UDP port 4855**, plain OSC 1.0: messages and `#bundle`s (bundle
  timetags ignored — applied on arrival; the receiver's own bar
  quantization is the musical clock, not NTP).
- Type tags supported: `i` (int32), `f` (float32), `s` (string). Anything
  else in a message = the whole packet is dropped (strict parse — garbage
  must not half-apply).
- **Addressing is by transport, not by namespace**: send to the phone you
  mean. No `/pvj/1/...` device prefixes — the IP is the device selector,
  and every phone speaks the same tree. (A fan-out is the sender looping
  over peers, exactly like `conduct_all_*`.)
- Config: `[osc] enabled` (default **true** — a LAN instrument, zero-config
  like the beacon) and `[osc] port` (default 4855) in settings.cfg.

## 2. The laws (inherited, not invented)

1. **The performer always wins.** `/pvj/xfade` IS a hand on the fader: it
   demotes any crossfade automation to MANUAL instantly, same as touching
   the panel row. OSC is an operator, not a backdoor.
2. **The receiver quantizes.** `/pvj/seq/*` rides the exact `_seq_pending`
   path the link's `seq` verb uses — applied on the phone's own next
   downbeat. (No `at=now` in v1 OSC; the link verb keeps the panic path.)
3. **One tempo authority.** `/pvj/bpm` is "human-set on this device". Sent
   to the MASTER (role main) it re-distributes automatically — set_bpm →
   bpm_changed → `_send_link_beat` → every slave and TD's grid pars follow.
   Sent to a slave it applies but the master's next stamps correct it back
   (law v2 doing its job). **Conduct tempo THROUGH the master, never around
   it** — this is the TD-as-tempo-master handover, resolved: TD doesn't
   become a master, it commands the master.
4. **Silence reads as broken**: discrete ops flash on the status line
   (`OSC: SLOT 3 @ BAR`). The continuous fader does not (it would strobe
   the flash), matching the panel row's behavior.

## 3. The namespace — v1 (inbound, implemented)

| Address | Args | Action |
|---|---|---|
| `/pvj/xfade` | f 0–1 | Crossfade position — manual, demotes automation |
| `/pvj/xfade/mode` | s \| i | `manual\|beat\|audio\|lfo` (or index 0–3) |
| `/pvj/bpm` | f | Tempo, human-set on this device (see law 3) |
| `/pvj/mode` | s \| i | Switch mode `manual\|sequential\|random\|lfo` |
| `/pvj/seq/slot` | i [s lane] | Load sequence slot 1–6, bar-quantized (lane `a` default, `b` optional) |
| `/pvj/seq/auto` | i 0/1 [s lane] | Sequencer auto-advance, bar-quantized |
| `/pvj/lane_b/arm` | i 0/1 | Arm lane B |
| `/pvj/lane_b/source` | s \| i | `clip\|net\|td` — the lane B destination switch (`net` = the peer phone's slot, `td` = TD's SRT slot; SEQ2 Stage 3.2) |
| `/pvj/deck/next` | — | Next clip, **at once** — the NEXT cell's call (`clip_engine.next_clip()`): warm cue, dead-clip skip |
| `/pvj/deck/prev` | — | Previous clip, at once — the PREV cell's call; steps back over a clip that never opened |
| `/pvj/deck/clip` | i \| s | Jump to a clip, at once — the grid tap's call (`clip_engine.jump`). `i` = the number the status line shows (`CLIP 3/31` → 3), 1-based, 0 / past the end refused (never wrapped). `s` = a ClipLibrary id, the path under the clips folder (`pack1/beam.mp4`), the file name (what `/pvj/out/clip` sends — echo it back and it round-trips) or the bare name; case-insensitive, first in deck order on a shared name. Unknown = dropped, one log line per 5 s |
| `/pvj/lane_b/clip` | i \| s | Lane B's twin of `/pvj/deck/clip`: jump **deck B** to a clip, at once — the grid tap aimed at lane B (`_lane_b_jump` → `_clip_engine_b.jump`). Same argument rules, resolved against deck B's own list (`i` = 1-based number; `s` = id, path, file name or bare name). Refused, one log line per 5 s, where the tap is refused: lane B not armed, or its source not `clip`; and an unknown clip. With lane B's sequencer auto on, its next step still wins (law 1) |
| `/pvj/fx/ascii/text` | s | **A message on screen — takes over the look**: FX = ASCII, mode Custom, the cells spell the text (the FX panel's own calls: `_set_effect`, `_set_ascii_mode`, `_set_ascii_text`). Max 64 cells, plus one trailing space when there is room so the repeats read HELLO HELLO, not HELLOHELLO; A–Z / 0–9 show, anything else is a blank cell; case is ignored |
| `/pvj/fx/ascii/mode` | s \| i | ASCII glyph mode `brightness\|binary\|random\|custom` (or index 0–3) — the mode buttons' call; does NOT switch the effect on |

**Deck commands are immediate, not bar-quantized** (added SESSION_45). They
stand for a button tap, and a tap cuts when it lands; the warm back decoder
makes that cut ~instant. A sender wanting a cut ON the beat sends on the beat,
or uses `/pvj/seq/slot`, which is quantized (law 2). Law 1 holds the simple
way: it is the same call as the performer's tap, so whichever lands last wins
and no automation is suspended or re-armed. `/pvj/deck/*` drives deck A
(`clip_engine`); `/pvj/lane_b/clip` drives deck B. Together with `/pvj/xfade`
that is the A/B ping-pong a desk needs: load the next clip on the lane the
fader hides, fade to it, next time load the other lane. No `/pvj/lane_b/next|prev`
yet: lane B steps through its pattern, so "next" has no single meaning there.

**`/pvj/fx/ascii/text` takes over on purpose** (owner's call, SESSION_45): it is
for audience / chat messages, which must show without the performer setting
anything up. Law 1 still holds the simple way — every step is a panel call, so
the FX panel shows ASCII · CUSTOM and the text, and one tap undoes it. A
message that arrives later wins again. Moderate upstream: the Logos bridge runs
every message through its blocklist, length cap and per-sender cooldown.

Unknown addresses are dropped with one rate-limited log line — a rig
speaking tomorrow's namespace at yesterday's build must not spam.

## 4. Reserved (designed now, built later)

- `/pvj/fx/...` — effect select/intensity (the FX fader + slot system).
- `/pvj/warp/...`, `/pvj/mask/...` — the mapping surface
  (`INTERCHANGE_SPEC.md` §1's export is the sibling of this).
- **Outbound (`/pvj/out/...`)** — ✅ **BUILT 2026-08-20** (v1): phone →
  desk state feedback so Resolume/TD control surfaces can mirror.
  `scripts/osc_output.gd` (encoder + change/keyframe scheduler; headless
  round-trip-proven against the OscInput parser by
  `tools/verify_osc_output.gd`) + `pipeline._osc_out_snapshot()`. Opt-in:
  `[osc] out_enabled` (default false), `out_targets` "ip:port,ip:port",
  `out_rate_hz` (default 30). Sends on change (float deadband 0.001) in
  one #bundle per pass + a 1 Hz full keyframe (the UDP recovery story).
  v1 addresses: `/pvj/out/xfade`, `/pvj/out/xfade/mode`, `/pvj/out/bpm`,
  `/pvj/out/mode`, `/pvj/out/clip`, `/pvj/out/seq/auto`,
  `/pvj/out/lane_b/arm|source|clip`, `/pvj/out/beat`, `/pvj/out/bar`.
  `/pvj/out/lane_b/clip` is deck B's file name (empty until lane B has
  shown a clip), the same form `/pvj/lane_b/clip` accepts.
  Menu values go out as the same lowercase names the inbound parser
  accepts, so a desk can echo a value straight back and it round-trips.
  **LIB ▸ OSC (pro, SESSION_45):** OSC IN readout (port + this phone's
  LAN IPv4 — the address a sender types in), OSC OUT toggle, OUT TARGETS
  (`ip:port[,ip:port]`, up to 8; a list with one bad entry — no port, port
  < 1024, a host name — is refused whole and the flash names it), OUT RATE
  1–60 Hz, OUT STATUS (`OSC OUT → 192.168.1.20:9000 @ 30 HZ` / `ON · NO
  TARGETS (SILENT)` / `OFF`). All live, all persisted to `[osc]`; TRACKING's
  OSC out button + readout mirror the same state. `/pvj/out/clip` is an `s`:
  the clip's FILE NAME with its extension (`pvj_loop_03.mp4`), changed on
  every cut and re-sent in the 1 Hz keyframe; the tracking module's
  `/pvj/out/track|field/...` (docs/MEDIAPIPE_MODULE.md §6) rides this,
  and `/pvj/out/crowd/...` — aggregates plus opt-in per-person
  `p<n>/x|y|size|present` — is **reserved** for crowd mode
  (docs/MEDIAPIPE_MODULE.md §13.5, M8).
- `/pvj/tap` — network tap tempo (jitter makes it a research toy; bpm
  floats are the honest wire).

## 5. Implementation notes (v1, as built)

- **`scripts/osc_input.gd`** (`OscInput`, ~150 lines): PacketPeerUDP bound
  to `[osc] port`, drained per frame; strict OSC 1.0 parser (padded
  strings, big-endian i/f, `,` type tags, recursive `#bundle`); emits
  `message(address, args)`; malformed packets dropped whole.
- **pipeline**: `_on_osc()` maps the table above onto the SAME functions
  the panel rows call (`_set_xfade_manual`, `_set_xfade_mode`,
  `_set_lane_b_armed/_source`, `_set_mode`, `BeatClock.set_bpm`) and the
  SAME `_seq_pending` queue the link verbs use. No new state machines —
  OSC is another widget, like the link verbs before it.
- **TD sender**: `link_control.osc(name, address, *args)` — a ~20-line
  python OSC encoder + `sendto(peer_ip, 4855)`, for textport conducting
  and scripts. Real TD patches use the native OSC Out CHOP/DAT at the same
  address:port; Resolume/TouchOSC point at the phone's IP:4855 directly.
