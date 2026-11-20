# PocketVJ — Help cards (spec / as built)

**Status:** designed and built 2026-09-30 (the same evening as Mod v2). One mechanism, three doors, one text file. The texts are a first pass written by the person who built the features; they want reading by the person who uses them.

## 1. What help is for, here

A VJ reads help in the dark, one-handed, with a set running. Nobody opens a manual. So help has to be **in place** (about the control under the finger, without leaving the panel), **short** (what it does, what to set it to, what it affects — three lines), and **never in the way** (no first-run wizard that stands between the performer and the picture).

The public build adds a second reader: someone who has just installed the app and has no idea what WRP or MSK are. They need the *lay of the land* once, and then the same in-place help as everyone else.

## 2. Three doors to one card

1. **Hold.** Hold any control for half a second — a panel row, a chip, a section header, a nav cell — and its card opens. The touch that opened the card does not act (the row is not toggled, the panel is not opened). The fast path; invisible until you know it, which is why the tour and the HELP section both say it.
2. **Help mode.** MODE ▸ HELP ▸ "Help mode": arm it, and the NEXT tap on a control shows its card instead of acting — then the mode is off again. One card per arming. (A sticky mode trapped the person who turned it on: the switch to turn it off was itself a row, so it showed its card instead of switching. Found on the device the first evening.) Nav cells, section headers and the HELP rows are exempt and keep working. It is also the only door for the **clip grid** and the **sequencer slots**, whose holds are already taken (lift a clip, reorder a slot): they are registered as *areas* — a help-mode tap shows their card, a hold does what it always did. The strip's buttons (A, B, SLOT, SAVE, LOAD, DEL, CLEAR, BARS/SLOT, SHUFFLE, AUTO) take a hold like any row; the grid and the strip carry a `press_gate` the pipeline sets, so the release after a card never plays, lifts, or clears anything.

The hit-test asks the GUI what is under the finger (`gui_get_hovered_control`) and picks the smallest registered ancestor — a rectangle test alone found the LIB row *behind* a clip tile and answered a tap on the tile with a card.
3. **The tour.** Four cards on the first run — what the deck is, how the picture gets to the projector, where the sound comes in, where help lives — with NEXT/SKIP, shown once and never again unless asked (MODE ▸ HELP ▸ "Show the welcome tour"). It waits a second after the deck is up, so it never delays the picture.

A card is an `M8Dialog.note`: title, a few lines, OK. Same look as every other box in the app; BACK and tap-outside close it.

## 3. One text file, keyed by where the control is

`scripts/help_text.gd` (`HelpText`) holds every card as `KEY: [title, body]`. Keys are **where the control lives**, not what variable it sets: `"MOD MATRIX/AMOUNT"`, `"BEAT FLIP/TRIGGER"`, `"NAV/WRP"`, `"FX GLITCH/BLOCK SIZE"`, and a section's own card at `"MOD MATRIX"`.

The panel builders register every row they make under `<section>/<caption>` automatically — nothing at the call sites changes, and a new row is covered the moment someone writes its card. A row whose caption changes with its value ("SLOT 1   LOW", "→ FX A · BLOCK SIZE") is found by the **longest key that its caption starts with** (`"MOD MATRIX/SLOT"`, `"MOD MATRIX/→"`).

Writing a card is therefore: find the caption on the screen, add one line to `help_text.gd`. `tools/verify_help.gd` lists every registered control that has no card, so the gap is always known.

## 4. What the texts say (the rule)

Three sentences at most, in this order: **what it does · what to set it to · what it affects.** Present tense, second person where a person is involved ("hold the phone"), the app's own words for things (a *slot*, a *lane*, the *deck*). No history, no reasons — those live in the specs. If a control needs more than three lines to explain, that is a note against the control, not a longer card.

## 5. Not built, on purpose

- No tooltips on hover (there is no hover on a phone).
- No search, no index page, no "help centre". The card is under the finger or it is not worth having.
- No help inside the full-screen editors (warp, masks, camera keystone) yet: their strips already carry a hint line, and holding a strip cell there would collide with the editors' own press handling. The section cards for WRP and MSK cover the basics; the editors are the next place this goes.
- No pictures. The M8 boxes are text; so are these.

## 6. Verified

`tools/verify_help.gd` (32 checks): every registered control on every panel resolves to a card (the list of misses is printed and gated to zero); a hold on a row opens its card and swallows the touch; help mode leaves a nav cell and the HELP MODE toggle alone, shows a row's card once and is then off; a hold on the sequencer opens nothing; a help-mode tap on a slot shows SEQUENCER (not CLIP GRID, though the strip sits inside the grid) and on the grid shows CLIP GRID, with both gates taking the touch; every strip button has a card; the tour runs its four cards and records itself as seen.

**Owed:** a read of every text by someone who did not write the features; the editors' strips; the public build's wording for pro-only rows (they say what the thing does; they do not yet say "pro").
