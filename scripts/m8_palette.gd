class_name M8Palette
extends RefCounted
## M8Palette — the ONE source of the PocketVJ M8-Classic colours for the sequencer
## widgets (FolderTabBar / ClipGrid / SequenceStrip). Pure black, one green accent,
## red for destructive only — see PROJECT_STATE "M8 palette". pipeline.gd keeps its
## own copies for the main-bar chrome; these consts back the sequencer surface so a
## new widget references the shared value instead of re-typing the literals.

const GREEN := Color(0.0, 1.0, 0.255)             ## #00FF41 — the one accent
## #FFB000 — DECK B. The first secondary this palette has ever carried, and it
## earns the exception: the app became genuinely dual-deck (both lanes play at
## once), and until now the ONLY thing naming which deck a tap would fire into
## was "SEQ A" at font 14 / 60% alpha — the dimmest text on the screen. Colour
## carries the deck now, so green ALWAYS means lane A and amber ALWAYS means
## lane B, on every surface. A clip in both sequences shows BOTH badges rather
## than a third hue, which is what keeps that reading true everywhere.
## ⚠️ Warm, like RED — they sit 30° apart (41° vs 12°) and RED is only ever one
## small destructive button, but check them together on the panel before adding
## any third warm colour.
const AMBER := Color(1.0, 0.690, 0.0)
const RED := Color(1.0, 0.267, 0.133)             ## #FF4422 — destructive only
const TEXT := Color(0.929, 0.929, 0.929)          ## #EDEDED — white values
const DIMTEXT := Color(0.929, 0.929, 0.929, 0.6)  ## readouts
const LABEL := Color(0.929, 0.929, 0.929, 0.42)   ## dim cell labels
const LINE := Color(0.0, 1.0, 0.255, 0.16)        ## green hairline rules/borders
const BLACK := Color(0, 0, 0, 1)
