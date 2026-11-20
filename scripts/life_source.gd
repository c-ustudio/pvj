class_name LifeSource
extends Node
## A life-like cellular automaton rendered into its own SubViewport.
##
## Port of the TouchDesigner `life` component in c-ustudio/led-matrix-bridge
## (touchdesigner/life.py). Same rule table, same seed styles, same stagnation
## and cycling behaviour — the numbers are copied deliberately, because they
## were tuned by watching the panel and a "cleaner" value is just an untested
## one.
##
## ⚠️ NOT VENDORED, unlike ddp_output.gd. This is a PocketVJ component that
## happens to have a TouchDesigner sibling; there is no wire format to keep
## byte-identical, so the drift check does not cover it and the two are free to
## diverge. If you fix a RULE or a SEED here, the sibling is still wrong.
##
## ── SHAPE, AND WHY IT IS A VIEWPORT ──────────────────────────────────────
## The sim runs on the CPU and could hand bytes straight to DdpOutput, which
## would be the shortest path to the panel. It produces a SubViewport instead so
## that it is a SOURCE in the same sense OutputWorld is: something with a
## texture that any consumer can read. That is what lets the panel read it today
## and the deck read it later without this file changing.
##
## At 64x64 the whole thing is 4096 cells. One generation is ~33k array reads,
## and generations run at GEN_HZ (~12/s) rather than per frame, so the cost is
## about 400k operations a second — irrelevant next to a single video decode.

## Emitted when the rule changes, so a UI can show which one is running.
signal rule_changed(id: String, label: String, spec: String)

# ── Rules ────────────────────────────────────────────────────────────────
# (id, label, Born/Survive, preferred seed density, seed style)
#
# ⚠️ SEEDING MATTERS AS MUCH AS THE RULE. Gnarl sown at Conway's 0.28 saturates
# into noise within a few generations; sown at 0.004 it grows into the structure
# it is famous for. The density column is per-rule for that reason, and the
# Density knob SCALES these rather than replacing them.
#
# Ordered to alternate busy and sparse — a run of similar-looking rules reads as
# nothing happening.
const RULES := [
	["conway",     "Conway",         "B3/S23",        0.28,  "pattern"],
	["highlife",   "HighLife",       "B36/S23",       0.28,  "pattern"],
	["maze",       "Maze",           "B3/S12345",     0.06,  "random"],
	["mazectric",  "Mazectric",      "B3/S1234",      0.06,  "random"],
	["coral",      "Coral",          "B3/S45678",     0.30,  "random"],
	["serviettes", "Serviettes",     "B234/S",        0.0,   "block"],
	["fredkin",    "Fredkin",        "B1357/S02468",  0.0,   "single"],
	["lwod",       "Life w/o Death", "B3/S012345678", 0.015, "random"],
	["gnarl",      "Gnarl",          "B1/S1",         0.004, "random"],
	["seeds",      "Seeds",          "B2/S",          0.02,  "random"],
	["daynight",   "Day & Night",    "B3678/S34678",  0.40,  "random"],
	["diamoeba",   "Diamoeba",       "B35678/S5678",  0.48,  "random"],
	["walledcity", "Walled Cities",  "B45678/S2345",  0.42,  "random"],
	["replicator", "Replicator",     "B1357/S1357",   0.0,   "single"],
]

# ── Palettes ─────────────────────────────────────────────────────────────
# (live, trail, background). The tail fades from the trail colour toward the
# background, so those two want real contrast or no tail is visible at all.
const PALETTES := {
	"ice":    [Color(0.90, 0.95, 1.00), Color(0.10, 0.45, 0.85), Color(0, 0, 0)],
	"ember":  [Color(1.00, 0.88, 0.60), Color(0.75, 0.16, 0.02), Color(0, 0, 0)],
	"acid":   [Color(0.85, 1.00, 0.55), Color(0.10, 0.60, 0.18), Color(0, 0, 0)],
	"magma":  [Color(1.00, 0.95, 0.85), Color(0.80, 0.08, 0.34), Color(0.03, 0, 0.04)],
	"mono":   [Color(1, 1, 1),          Color(0.26, 0.28, 0.32), Color(0, 0, 0)],
	"violet": [Color(0.95, 0.85, 1.00), Color(0.42, 0.10, 0.75), Color(0, 0, 0.02)],
}
const PALETTE_IDS := ["ice", "ember", "acid", "magma", "mono", "violet"]

# ── Seed patterns ────────────────────────────────────────────────────────
# Random soup is fine but forgettable. These are the structures Life is famous
# for, and on a 64x64 torus they read beautifully.
#
# ⚠️ Conway-family constructs ONLY. Under Seeds or Diamoeba they dissolve, so
# only rules whose seed style is "pattern" draw from them.
const PATTERNS := {
	# Emits a glider every 30 generations, forever.
	"gosper_gun": "........................O...........\n......................O.O...........\n............OO......OO............OO\n...........O...O....OO............OO\nOO........O.....O...OO..............\nOO........O...O.OO....O.O...........\n..........O.....O.......O...........\n...........O...O....................\n............OO......................",
	# 7 cells, runs 5206 generations before stabilising.
	"acorn": ".O.....\n...O...\nOO..OOO",
	# 5 cells, 1103 generations. The original methuselah.
	"r_pentomino": ".OO\nOO.\n.O.",
	# Period-3 oscillator, the most symmetric thing in the catalogue.
	"pulsar": "..OOO...OOO..\n.............\nO....O.O....O\nO....O.O....O\nO....O.O....O\n..OOO...OOO..\n.............\n..OOO...OOO..\nO....O.O....O\nO....O.O....O\nO....O.O....O\n.............\n..OOO...OOO..",
}
const PATTERN_CHOICES := ["gosper_gun", "acorn", "r_pentomino", "pulsar"]
const GLIDER := ".O.\n..O\nOOO"

# ── Tunables ─────────────────────────────────────────────────────────────

## Grid size. 64x64 matches the panel exactly, which is the point for the DDP
## path — no downsample, no resample softening the one-pixel cells. Kept a
## variable rather than a constant so a later deck-side use can run larger.
@export var grid_size: Vector2i = Vector2i(64, 64)

## Generations per second in FREE mode. WALL-CLOCK, not per frame: the sim must
## run at a watchable speed whether the deck is at 60 fps or struggling at 30,
## and a per-frame step would make the automaton's speed a performance artefact.
@export_range(1.0, 60.0, 0.5) var gen_hz: float = 12.0

## What drives generations.
##
##   FREE  gen_hz, free-running. Independent of tempo.
##   BEAT  gens_per_beat against the deck's BPM, PHASE-LOCKED to the beat.
##
## ⚠️ BEAT LOCKS RATE *AND* PHASE, and both halves matter. Deriving the interval
## from BPM alone makes the sim the right SPEED but leaves it drifting against
## the music — generations land wherever they happen to fall, and the eye reads
## that as "fast" rather than "on the beat". on_beat() therefore also resets the
## accumulator, so every beat lands a generation exactly on it and the
## subdivisions fill in evenly behind. Rate without phase is the version that
## looks broken for reasons nobody can name.
enum Clock { FREE, BEAT }
@export var clock_mode: Clock = Clock.FREE

## Generations per beat in BEAT mode. 1/2/4/8 are the musical values; at 90 BPM
## and 4/beat that is 6 generations a second, close to the FREE default.
@export var gens_per_beat: float = 4.0

## The deck's tempo, pushed in — LifeSource does not reach for BeatClock itself,
## so it stays a plain node that can be tested and reused without an autoload.
var bpm: float = 120.0

## Trail decay per GENERATION.
## ⚠️ PER GENERATION, NOT PER FRAME — the sibling shipped this bug and it is
## worth not repeating: decaying per frame compounds ~60 times a second against
## ~12 generations, so 0.72 extinguished the tail in about a tenth of a second
## and no trail was ever visible.
@export_range(0.0, 0.99, 0.01) var trail_decay: float = 0.82

## Torus edges. Off, the border acts as permanent dead cells and growth stalls
## against it; on, gliders come back around, which is most of the charm.
@export var wrap: bool = true

## Scales every rule's own density together, so one knob works across the table.
@export_range(0.1, 4.0, 0.05) var density_scale: float = 1.0

## Generations of stagnation tolerated before reseeding.
@export_range(1, 60, 1) var stale_gens: int = 12

## Advance to the next rule automatically.
@export var cycle: bool = true

## How long each rule gets when cycling, in SECONDS.
@export_range(5.0, 600.0, 5.0) var hold_secs: float = 45.0

@export var palette: String = "ice": set = set_palette

var _live := Color(0.90, 0.95, 1.00)
var _trail_col := Color(0.10, 0.45, 0.85)
var _bg := Color(0, 0, 0)

# ── State ────────────────────────────────────────────────────────────────

var _view: SubViewport = null
var _rect: TextureRect = null
var _tex: ImageTexture = null
var _img: Image = null

var _grid: PackedByteArray = PackedByteArray()
var _prev: PackedByteArray = PackedByteArray()
var _prev2: PackedByteArray = PackedByteArray()
var _trail: PackedFloat32Array = PackedFloat32Array()

var _born: Array[int] = []
var _survive: Array[int] = []
var _rule_idx: int = 0
var _stale: int = 0
var _gen: int = 0
var _rule_started: float = 0.0
var _accum: float = 0.0
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.randomize()
	_build_viewport()
	set_palette(palette)
	select_rule(0)
	# ⚠️ NOT RUNNING BY DEFAULT. The sim is cheap but it is not free, and the
	# common case is a deck with no panel attached at all — the same reasoning
	# that keeps DdpOutput's taps unbuilt until enabled. The owner calls
	# set_running(true) when the panel is actually pointed at this.
	set_process(false)


## Start/stop stepping. Stopping leaves the last generation on the viewport
## rather than clearing it, so a consumer still reading the texture sees a frozen
## automaton instead of a black frame — a black panel reads as a fault.
func set_running(on: bool) -> void:
	set_process(on)
	if on:
		_accum = 0.0
		# The hold restarts too: a rule that was mid-innings when the source was
		# switched away should not immediately cycle on the way back in.
		_rule_started = _now()


## The viewport any consumer reads. DdpOutput.set_source() /
## set_independent_source() take exactly this.
func get_viewport_source() -> SubViewport:
	return _view


func _build_viewport() -> void:
	_view = SubViewport.new()
	_view.size = grid_size
	_view.transparent_bg = false
	_view.gui_disable_input = true
	# UPDATE_ONCE per generation, NOT UPDATE_ALWAYS. The image only changes when
	# a generation advances (~12/s), so rendering every frame would be ~48 wasted
	# 64x64 passes a second. _render() re-arms it each time it writes.
	_view.render_target_update_mode = SubViewport.UPDATE_DISABLED

	_rect = TextureRect.new()
	_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_rect.stretch_mode = TextureRect.STRETCH_SCALE
	_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# ⚠️ NEAREST, deliberately. Cells are one pixel and the panel is one pixel
	# per LED; linear filtering would smear each cell into its neighbours and
	# turn the automaton into a blur. This is the opposite of the DDP taps,
	# where linear IS the point — different job, different filter.
	_rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_view.add_child(_rect)
	add_child(_view)

	_img = Image.create(grid_size.x, grid_size.y, false, Image.FORMAT_RGB8)
	_tex = ImageTexture.create_from_image(_img)
	_rect.texture = _tex


# ── Rules ────────────────────────────────────────────────────────────────

## "B36/S23" -> [[3, 6], [2, 3]]. An EMPTY survive set is legal and load-bearing
## — Seeds (B2/S) and Serviettes (B234/S) are nothing but empty survive sets.
static func parse_rule(spec: String) -> Array:
	var halves := spec.to_upper().split("/")
	var born: Array[int] = []
	var survive: Array[int] = []
	for ch in halves[0].substr(1):
		if ch.is_valid_int():
			born.append(int(ch))
	if halves.size() > 1:
		for ch in halves[1].substr(1):
			if ch.is_valid_int():
				survive.append(int(ch))
	return [born, survive]


func rule_label() -> String:
	return "%s" % RULES[_rule_idx][1]


func rule_spec() -> String:
	return "%s" % RULES[_rule_idx][2]


func select_rule(idx: int, reseed_now: bool = true) -> void:
	_rule_idx = posmod(idx, RULES.size())
	var parsed := parse_rule(RULES[_rule_idx][2])
	_born = parsed[0]
	_survive = parsed[1]
	_gen = 0
	_rule_started = _now()
	if reseed_now:
		reseed()
	rule_changed.emit(RULES[_rule_idx][0], RULES[_rule_idx][1], RULES[_rule_idx][2])


func next_rule() -> void:
	select_rule(_rule_idx + 1)


func _now() -> float:
	return float(Time.get_ticks_msec()) / 1000.0


# ── Seeding ──────────────────────────────────────────────────────────────

func reseed() -> void:
	var w := grid_size.x
	var h := grid_size.y
	var n := w * h
	_grid = PackedByteArray()
	_grid.resize(n)
	_trail = PackedFloat32Array()
	_trail.resize(n)

	var style: String = RULES[_rule_idx][4]
	match style:
		"single", "block":
			# The fractal growers want the smallest possible seed — denser and
			# the expanding wavefronts collide before the structure is legible.
			# "block" exists because a rule with an EMPTY survive set kills a
			# lone cell before its neighbours ever reach the 2+ they need to be
			# born, so it needs a 2x2 to get going at all.
			var cy := h / 2
			var cx := w / 2
			_set_cell(cx, cy, 1)
			if style == "block":
				_set_cell(cx + 1, cy, 1)
				_set_cell(cx, cy + 1, 1)
				_set_cell(cx + 1, cy + 1, 1)
		"pattern":
			var name: String = PATTERN_CHOICES[_rng.randi_range(0, PATTERN_CHOICES.size() - 1)]
			var pat := _pattern_rows(PATTERNS[name])
			_stamp(pat, (h - pat.size()) / 2, (w - _pattern_width(pat)) / 2)
			# A few gliders give the pattern something to collide with, which is
			# what stops a lone oscillator sitting unchanged until the stagnation
			# check reseeds it.
			var glider := _pattern_rows(GLIDER)
			for _i in range(_rng.randi_range(2, 4)):
				_stamp(glider, _rng.randi_range(0, h - 1), _rng.randi_range(0, w - 1))
		_:
			# `or 0.15` covers forcing random onto a rule that normally seeds
			# from a single cell and so carries no density of its own.
			var base: float = float(RULES[_rule_idx][3])
			if base <= 0.0:
				base = 0.15
			var density := clampf(base * density_scale, 0.0005, 0.9)
			for i in range(n):
				_grid[i] = 1 if _rng.randf() < density else 0

	for i in range(n):
		_trail[i] = float(_grid[i])
	_prev = PackedByteArray()
	_prev.resize(n)
	_prev2 = PackedByteArray()
	_prev2.resize(n)
	_stale = 0
	_render()


func _pattern_rows(text: String) -> PackedStringArray:
	var out := PackedStringArray()
	for row in text.split("\n"):
		if row.strip_edges() != "":
			out.append(row)
	return out


func _pattern_width(rows: PackedStringArray) -> int:
	var m := 0
	for r in rows:
		m = maxi(m, r.length())
	return m


## Draw a pattern at (top, left), wrapping at the edges.
func _stamp(rows: PackedStringArray, top: int, left: int) -> void:
	for y in range(rows.size()):
		var row: String = rows[y]
		for x in range(row.length()):
			if row[x] == "O":
				_set_cell(left + x, top + y, 1)


## NOT named _set: Object declares _set(StringName, Variant) -> bool as a
## virtual, and a same-named method with a different signature is a parse error,
## not an override.
func _set_cell(x: int, y: int, v: int) -> void:
	var w := grid_size.x
	var h := grid_size.y
	_grid[posmod(y, h) * w + posmod(x, w)] = v


# ── Simulation ───────────────────────────────────────────────────────────

## Seconds between generations under whichever clock is selected.
func _interval() -> float:
	if clock_mode == Clock.BEAT and bpm > 0.0 and gens_per_beat > 0.0:
		return 60.0 / bpm / gens_per_beat
	return 1.0 / maxf(gen_hz, 0.001)


func set_bpm(value: float) -> void:
	bpm = value


## Called on every beat. Steps ON the beat and re-zeroes the accumulator, which
## is what phase-locks the sim rather than merely rate-matching it.
##
## No-op in FREE mode and while stopped, so the pipeline can wire this to
## BeatClock once and never think about it again.
func on_beat() -> void:
	if clock_mode != Clock.BEAT or not is_processing():
		return
	_accum = 0.0
	step()


func _process(delta: float) -> void:
	var interval := _interval()
	if interval <= 0.0:
		return
	_accum += delta
	# Cap the catch-up: after a stall (a clip load, a resume) a large delta must
	# not fire a burst of generations that skips the whole visible evolution.
	var budget := 4
	while _accum >= interval and budget > 0:
		_accum -= interval
		budget -= 1
		step()
	if _accum > interval:
		_accum = 0.0


func step() -> void:
	var w := grid_size.x
	var h := grid_size.y
	var n := w * h
	var nxt := PackedByteArray()
	nxt.resize(n)

	for y in range(h):
		for x in range(w):
			var count := _neighbours(x, y, w, h)
			var i := y * w + x
			if _grid[i] == 0:
				nxt[i] = 1 if _born.has(count) else 0
			else:
				nxt[i] = 1 if _survive.has(count) else 0

	# Stagnation: a still life matches the previous generation, a period-2
	# oscillator matches the one before that. Both are dull to watch, so they get
	# a few generations' grace and then a reseed.
	var alive := 0
	for i in range(n):
		alive += nxt[i]
	if alive == 0:
		_stale = 999                      # extinct — restart immediately
	elif nxt == _grid or nxt == _prev:
		_stale += 1
	else:
		_stale = 0

	if _stale >= stale_gens:
		reseed()
		_maybe_cycle()                    # a stagnant generation still counts
		return

	_prev2 = _prev
	_prev = _grid
	_grid = nxt
	_gen += 1

	for i in range(n):
		_trail[i] = maxf(_trail[i] * trail_decay, float(_grid[i]))

	_render()
	_maybe_cycle()


func _neighbours(x: int, y: int, w: int, h: int) -> int:
	var count := 0
	# range(), not a [-1, 0, 1] literal: iterating an untyped array yields Variant,
	# so `var nx := x + dx` has nothing to infer from and fails to parse.
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			if dx == 0 and dy == 0:
				continue
			var nx := x + dx
			var ny := y + dy
			if wrap:
				nx = posmod(nx, w)
				ny = posmod(ny, h)
			elif nx < 0 or ny < 0 or nx >= w or ny >= h:
				continue
			count += _grid[ny * w + nx]
	return count


func _maybe_cycle() -> void:
	if not cycle:
		return
	if _now() - _rule_started < hold_secs:
		return
	select_rule(_rule_idx + 1)


# ── Render ───────────────────────────────────────────────────────────────

func set_palette(value: String) -> void:
	palette = value
	if not PALETTES.has(value):
		return
	var p: Array = PALETTES[value]
	_live = p[0]
	_trail_col = p[1]
	_bg = p[2]
	if _img != null:
		_render()


## Paint the grid and re-arm the viewport for exactly one render.
##
## Live cells take the live colour outright; dead cells fade from the trail
## colour toward the background by their trail value. Drawing the tail through a
## SEPARATE colour rather than dimming the live one is what keeps it readable —
## a dimmed live colour on an LED panel just reads as a dead pixel.
func _render() -> void:
	if _img == null:
		return
	var w := grid_size.x
	var h := grid_size.y
	# ⚠️ GUARD ON THE GRID, NOT JUST THE IMAGE. set_palette() renders so a colour
	# change is visible immediately, and _ready() calls it BEFORE select_rule()
	# has seeded anything — the viewport exists, the grid is still empty, and
	# every _grid[i] below is out of bounds. Shipped exactly that: "Out of bounds
	# get index '0' (on base: 'PackedByteArray')" once per boot. Reordering
	# _ready would fix this instance and leave the next caller to rediscover it.
	if _grid.size() != w * h or _trail.size() != w * h:
		return
	for y in range(h):
		for x in range(w):
			var i := y * w + x
			var col: Color
			if _grid[i] == 1:
				col = _live
			else:
				col = _bg.lerp(_trail_col, clampf(_trail[i], 0.0, 1.0))
			_img.set_pixel(x, y, col)
	_tex.update(_img)
	if _view != null:
		_view.render_target_update_mode = SubViewport.UPDATE_ONCE
