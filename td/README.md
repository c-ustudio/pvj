# `pvj-link.toe` — PocketVJ ↔ TouchDesigner over SRT (M3, bidirectional)

TouchDesigner side of the video link. The live file is
`../td_pvj_link/pvj-link.toe` (TD's numbered history in `Backup/`); this repo
copy is refreshed at each milestone. Everything lives in one COMP:
**`/project1/pvj_link`**. Full narrative: `SESSION_30_NOTES.md`,
`VIDEO_LINK_SPEC.md`.

## `ab_player.tox` — the bundled TD deck

The A/B deck player (two Movie File In decks, playlist / cue-table /
timed / **beat-grid** drive modes, XF-style crossfade automation, remote
`seq` asks) exported as a drop-in component. The pair — link COMP + deck
.tox — is the "drop into any rig" story: drop both, point the deck's
`Grid COMP` par at the link COMP (default `/project1/pvj_link`) and the
link's `Seq Target` par back at the deck, and the phones' clock drives it.
Self-contained (audited: no external ties beyond that intentional pair
wiring); with no grid present, beat/XF modes HOLD — timed/cue/external
modes work standalone. Settings doc: the `readme` DAT + the
"AB PLAYER - settings" annotate inside the COMP (kept in sync).
Re-export at each milestone:
`op('/project1/movies_sc1/ab_player').save('<repo>/td/ab_player.tox')`.

## Workflow

```
RECEIVE  phone deck ──SRT──▶ srt_in0 :4861 ──▶ out1 ──▶ /project1 composite
         (2nd peer  ──SRT──▶ srt_in1 :4862, not wired to out1 yet)

SEND     src_deck (Select ▶ /project1/movies_sc1/out1 = the ab_player deck)
         ──▶ send_fit (fit to 1280×720) ──▶ srt_out :4860 ──SRT──▶ phone
         (src_motion placeholder deleted 2026-08-19; repoint src_deck or
         rewire send_fit to change what TD sends)

CONTROL  link_thread: UDP beacon  :4849   "PVJ1|name|role|srt|4860|4850"
                      TCP verbs   :4850   request_stream / stop / srt_arm / srt_disarm / beat / seq
         beacon_exec (onFrameStart): drains the verb queue, force-cooks the srt_ins,
         runs the two-frame srt_out re-arm

GRID     beat verb (from the master phone, 1/bar + on tempo change/tap) lands as
         custom pars on the pvj_link COMP, page "PVJ Grid": Bpm / Beat / Bar /
         Phase. Phase is the bar-phase AT THE STAMP, not a ramp — derive ramps
         from Bpm + the stored rx time (host.fetch('beat_rx')). The queue keeps
         only the LATEST beat (a paused TD must not replay a backlog on unpause).
         TD is a grid CONSUMER only — it must never derive or send a competing
         clock while a master phone is on the mesh (N4 rule: one authority).
         The 'seq' verb (the master phone's strip: slot / auto) routes to the
         COMP named by the Seqtarget par (default ab_player) via
         tgt.OnRemoteSeq(cmd) — the receiver quantizes to its next grid bar.
```

**The one rule:** `srt_out` serves exactly **one** client session per Active
cycle, then refuses silently (no detectable error — `srt_out_info`'s
`packet_loss_ratio` stays −1 even while serving). Peers must send `srt_arm`
on TCP 4850 **before every dial** of :4860; `beacon_exec` re-arms it across
two frames. `srt_disarm` (or plain `stop`) parks it — Active=Off is the
resting state.

## Nodes: what to change, inputs and outputs

| Node | Type | In → Out | Change it when… |
|---|---|---|---|
| `srt_out` | Video Stream Out | `send_fit` → SRT listener :4860 | Codec/bitrate tuning only. Never rewire — feed `send_fit` instead. |
| `send_fit` | Fit | `src_deck` → `srt_out` | **Rewire this input** to change what TD sends. Res: 1280×720. |
| `src_deck` | Select | `/project1/movies_sc1/out1` → `send_fit` | The ab_player deck (2c). Repoint to change the outbound source. |
| `srt_in0` | Video Stream In | SRT :4861 → `out1` | Nothing. **Disable Buffering must stay On** (else runaway lag). |
| `srt_in1` | Video Stream In | SRT :4862 → (unwired) | Wire to the mix when a second peer streams in. Same buffering rule. |
| `out1` | Out | `srt_in0` → `/project1/null1` | Composite/alpha changes belong at project level, not here. |
| `link_thread` | Text DAT (module) | — | **Ports & device name** (constants at top), beacon/verb protocol. |
| `link_control` | Text DAT | — | Main-thread API: `request_stream(name, codec='h264', transport='srt', port=4861)`, and **the conductor**: `conduct_slot(name, slot)`, `conduct_auto(name, on)`, `conduct_all_slot/auto(...)` — TD commands any phone's sequencer, receiver-quantized to its next bar (`at='now'` = panic). Tempo is deliberately NOT conductable (one authority: the master phone; the handover design lands with the OSC namespace). |
| `beacon_exec` | Execute DAT | — | The frame pump. **Never `time.sleep` in here.** |
| `srt_in0_info` / `srt_out_info` | Info CHOP | taps | Health only. Growing `srt_in0` queue = buffering re-enabled or frame loop stalled. |
| `recv0` + `recv0_callbacks` | Script TOP | TCP :4852 | Legacy Stage-0 JPEG receive — fallback for non-SRT peers. |
| `send_exec` | Execute DAT | TCP :4851 | Legacy Stage-0 JPEG send — fallback for `codec=jpeg` asks. |
| `test_src` | Movie File In | — | Scratch source for manual send tests; not in the live chain. |

## The Essentia layer (`movies_sc1`, 2026-08-19)

`audiofilein1` (the track) feeds five Essentia CHOPs (Rhythm / Spectrum /
Loudness / Spectral / Tonal). Live wires: `bpm_follow` sends the tracker's
bpm to the master via `/pvj/bpm` (deadband, rate limit, confidence gate,
octave fold); `xfade_follow` maps rms → `/pvj/xfade` at 10 Hz (TD automates
the phone's mix — its `Active` par is the kill switch); ab_player's Retime
rides rms (0.8–4.0 speed) and its XF AUDIO input takes `onset_strength`
(threshold 1.6, armed); `level_energy` (Level TOP, ab_player → out1) pumps
brightness with rms — the deck output and the phone's lane B behind it
breathe with the track. Same notes live in the .toe's `workflow_notes` +
per-node comments.

## Ports

| Port | Owner | Purpose |
|---|---|---|
| 4849 | UDP | Discovery beacon (both directions) |
| 4850 | TCP | Control verbs |
| 4851/4852 | TCP | Legacy JPEG send/receive |
| 4860 | SRT | TD → phone video (doorbell-armed listener) |
| 4861/4862 | SRT | Phone → TD video (peer 1 / peer 2) |

## Traps (each cost real time)

- Phone peer-dict field is `codec`; `link_thread`'s peer table uses `fmt`.
- Video Stream In only listens **while cooked** — the frame pump keeps it alive.
- A `time.sleep` in any exec freezes the frame loop and queues every live stream.
- The same network + annotations exist inside the .toe (`workflow_notes` box +
  per-node comments) — keep both in sync when the topology changes.
