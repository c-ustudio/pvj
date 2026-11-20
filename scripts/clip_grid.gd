class_name ClipGrid
extends Control
## ClipGrid — virtualized thumbnail matrix, the visual clip browser (sequencer
## Step 3). Replaces the playlist list as the primary browse+play surface.
##
## Renders ClipLibrary.get_folder(folder_id).clip_ids as a scrollable grid. Only
## visible cells (+ a one-row margin) are realized; cells are pooled and their
## textures freed when they scroll off (PocketVJ_Architecture §3, §7 risk 3). Tap
## a cell -> play immediately via ClipEngine.jump() (the warm-aware manual path).
##
## M8 CLASSIC: pure black, one green accent (#00FF41), uppercase tracked mono,
## flat header. The root's .theme is set by pipeline (a CanvasLayer breaks theme
## inheritance to the first Control level; children inherit from this root).
##
## Step 5+: the grid emits INTENT — tap -> clip_activated, long-press starts a
## GRAB (Step 6). Pipeline wires those to the engine / Sequence; the grid never
## calls the engine to *command* a play (it still reads clip_changed to track
## which cell is live — read-only observation).
##
## Grab model (Step 6): a long-press arms a drag of that clip. Pipeline floats a
## proxy and asks the strip for an insertion index; releasing over the strip
## inserts there, releasing anywhere else appends. This coexists with drag-to-
## scroll because a *moving* touch scrolls and only a still hold starts the grab.

signal clip_activated(clip_id: String)                    ## tap — play immediately
signal clip_park_toggled(clip_id: String)                 ## tap in CURATE mode — flip LIVE/PARKED
signal clip_grab_started(clip_id: String, tex: Texture2D, global_pos: Vector2)
signal clip_grab_moved(global_pos: Vector2)
signal clip_grab_ended(global_pos: Vector2)
## Option C step 3 — a grab released ONTO ANOTHER CELL means "put it here" rather than
## "add to the sequence". Emitted INSTEAD of clip_grab_ended in that case, so the two
## meanings can never both fire from one release.
signal clip_reorder_requested(moved_id: String, target_id: String)
## Option C step 4 — long-press while CURATE is armed means "delete this clip from the
## device". Intent only: the grid never touches the file. Pipeline confirms and removes.
signal clip_remove_requested(clip_id: String)
## Deck filter: 0 = ALL, 1 = lane A's clips only, 2 = lane B's. The "split" the
## grid never had — on demand, so it costs no rows when you do not want it.
signal deck_filter_changed(mode: int)
## The empty grid's buttons (beta2 §2.3): "demo", "pack", "more". Intent only —
## pipeline wires them to LOAD DEMO CLIPS / IMPORT PACK / GET MORE CLIPS.
signal empty_action(action: String)

# Shared M8 palette (see M8Palette — the durable PocketVJ values).
const GREEN := M8Palette.GREEN
const AMBER := M8Palette.AMBER   ## deck B — the grid shows BOTH decks' playing cells at once
const TEXT := M8Palette.TEXT
const DIMTEXT := M8Palette.DIMTEXT
const LABEL := M8Palette.LABEL
const LINE := M8Palette.LINE
const BLACK := M8Palette.BLACK

## ⚠️ THESE ARE LOGICAL px, NOT screen px. project.godot never sets a base
## viewport, so Godot's default 1152x648 + stretch/aspect="expand" lays the UI
## out in ~1454x648 on the 9a and scales it 1.667x to 2424x1080. The old cells
## (260x176) were therefore 433x293 REAL pixels — which is why only 5x2 = 10 of
## a 220-clip library fitted on screen, and why the chrome looked small next to
## them. Measured against a live capture, not derived.
##
## Shrinking the cell buys BOTH more clips and bigger chrome: 151x115 gives
## 8 cols x 3 rows = 24 visible. Vertical budget (648): HEADER_H 72 + strip 172
## leaves 404; 16 pad + 3 * (115 + 12) = 397, so three rows fit with room over.
const CELL_W := 151.0
const THUMB_H := 85.0         ## 16:9 under CELL_W
const LABEL_H := 30.0
const CELL_H := THUMB_H + LABEL_H
## GAP 14, not 12, so three rows fill the view almost exactly: 16 pad +
## 3 * (115 + 14) = 403 of the 404 logical px available. At 12 a fourth row
## began 7 px before the cut and bled a band of sliced thumbnails above the
## strip. Still fits 8 columns: 8 * 151 + 7 * 14 = 1306 of 1422.
const GAP := 14.0
const PAD := 16.0
const HEADER_H := 72.0
## The type scale, named once. Every size here used to be a bare literal on a
## per-node override, which is how the sequencer drifted to 13-16 px while the
## app theme sat at 20 — raising the theme could never reach it.
const TITLE_FS := 22
const COUNT_FS := 15
const CELL_FS := 15
const BADGE_FS := 14
const DECK_FS := 18        ## the DECK filter, sized to sit beside CURATE/DONE (theme 20)
const HDR_BTN_H := 44.0    ## header buttons were 56 in a 92 px header; 44 in a 72 px one
const TITLE_W := 190.0     ## "CLIP GRID" at TITLE_FS; the park button's x derives from it
const PARK_W := 130.0
const DECK_W := 150.0      ## the DECK filter; the FolderTabBar starts after it (see _layout_header_widget)
const HEADER_RIGHT_RESERVE := 290.0   ## DONE (150) + the count text: the FolderTabBar stays left of this
const TAP_SLOP := 16.0        ## px of movement above which a touch is a scroll, not a tap
const LONGPRESS_SEC := 0.4    ## hold this long (no move) over a cell -> queue it

var _engine: ClipEngine
var _folder_id: String = "all"
var _font_label: Font
var _bottom_inset: float = 0.0   ## reserved for the SequenceStrip (Step 5)

var _ids: Array[String] = []
var _empty: Control = null          ## the no-clips state: dimmed ident + three buttons
var _empty_video: VideoPlayback = null
var _cols: int = 1
var _left_margin: float = PAD
var _content_h: float = 0.0
var _scroll_y: float = 0.0
## ONE INDEX PER DECK, not one shared. Both lanes play at once, so the grid has
## to be able to show two rings in two colours — and the shared index was also a
## BUG: the grid is set up with deck A's engine, so with lane B armed a tap set
## the highlight optimistically and deck A's clip_changed echo immediately pulled
## it back to A's clip. The ring pointed at a clip you had not fired.
var _active_a: int = -1       ## grid index of deck A's playing clip (-1 = none/off-view)
var _active_b: int = -1       ## grid index of deck B's playing clip
var _armed_lane: int = 0      ## which deck a tap fires; pipeline pushes it on every lane switch
## Which sequence(s) each clip already belongs to — the answer to "what belongs
## to what deck", which nothing in this grid could express before. Pushed by
## pipeline (the grid never reaches into a lane's model).
var _mem_a: Dictionary = {}   ## clip id -> true when it sits in lane A's sequence
var _mem_b: Dictionary = {}

var _cells: Dictionary = {}       ## grid index -> Panel (realized)
var _id_to_cell: Dictionary = {}  ## clip id -> Panel (realized), for thumbnail routing
var _pool: Array[Panel] = []

# tap/drag tracking
var _press_pos: Vector2 = Vector2.ZERO
var _press_index: int = -1
var _moved: float = 0.0
var _dragging: bool = false
var _saw_touch: bool = false      ## once real touch is seen, ignore emulated mouse
var _longpress_t: float = 0.0
var _longpressed: bool = false    ## a long-press fired -> suppress the release tap
## Help cards (HELP_CARDS_SPEC.md): the pipeline sets this; when it answers true
## the touch belongs to a card — no tap, no long-press. The grid has a hold of
## its own, so help reaches it through HELP MODE (a tap), never a hold.
var press_gate: Callable = Callable()
var _grabbing: bool = false       ## a grab drag is in flight (Step 6)
var _drop_target: int = -1        ## grid index a reorder would drop onto (-1 = none)

# CURATE mode (Option C step 2): while armed, a tap flips the clip's LIVE/PARKED flag
# instead of playing it. A MODE rather than a gesture because the grid's gesture budget
# is fully spent — tap plays, drag scrolls, long-press grabs into the sequence — and
# the two remaining candidates were both worse: double-tap would have to defer the play
# to disambiguate, and multi-touch is unsafe here (this control reads _gui_input, which
# cannot be trusted with pointer index >= 1; see warp_editor's note on why the editors
# use raw _input instead).
#
# CURATE also forks the LONG-PRESS (Option C step 4): armed, a hold is REMOVE — the
# only capability the retired playlist panel had that the grid did not. It goes here
# rather than on its own gesture for the same reason park did (the gesture budget is
# spent), and it is safe on a destructive action because CURATE must be armed
# deliberately, disarms on every open, and the hold only raises a confirm dialog.
# ⚠️ Reorder (grab-and-drop-onto-a-cell) therefore lives in NORMAL mode only. The two
# meanings of a long-press are split by the mode, so one hold can never mean both.
#
# ⚠️ NEVER PERSISTED, AND CLEARED IN on_shown(). A mode that survives into a set is the
# failure this codebase has already paid for once — the sequencer's AUTO stayed armed
# across switch modes and silently captured all four. The grid is a transient overlay
# with a DONE button, so tying the disarm to "the overlay was opened" makes leaving it
# armed structurally impossible rather than merely unlikely.
var _park_mode: bool = false
var _btn_park: Button
## 0 = ALL, 1 = A only, 2 = B only. A CYCLE button rather than three tabs: the
## header has ~150 px free left of the centred folder tabs, and cycling is
## already this app's idiom for a small enumerated choice (SLOT, B SRC, BAR/SLOT).
var _deck_filter: int = 0
var _btn_deck: Button

var _bg: ColorRect
var _content: Control             ## clips grid cells live here (clipped)
var _title: Label
var _count_lbl: Label
var _header_widget: Control       ## FolderTabBar, centred in the header (step 4)
var _btn_done: Button             ## kept, so the armed deck's hue can repaint it
var _rule: ColorRect              ## the header's hairline; chrome, so it follows the deck


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true

	_bg = ColorRect.new()
	_bg.color = BLACK
	_bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_bg)

	# Content BEFORE the header so the opaque header draws on top: cells scrolled up
	# past HEADER_H are covered by the header instead of overlapping its text/DONE.
	_content = Control.new()
	_content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_content.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_content)

	_build_empty()
	_build_header()

	resized.connect(_on_resized)


func setup(engine: ClipEngine, font_label: Font) -> void:
	_engine = engine
	_font_label = font_label
	if _title != null and font_label != null:
		_title.add_theme_font_override("font", font_label)
		_count_lbl.add_theme_font_override("font", font_label)
		# _build_header() ran in _ready(), before this font existed.
		_btn_park.add_theme_font_override("font", font_label)
	if not _engine.clip_changed.is_connected(_on_clip_changed):
		_engine.clip_changed.connect(_on_clip_changed)
	if not ThumbnailService.thumbnail_ready.is_connected(_on_thumb_ready):
		ThumbnailService.thumbnail_ready.connect(_on_thumb_ready)
	if not ThumbnailService.thumbnail_failed.is_connected(_on_thumb_failed):
		ThumbnailService.thumbnail_failed.connect(_on_thumb_failed)
	if not ClipLibrary.folder_updated.is_connected(_on_folder_updated):
		ClipLibrary.folder_updated.connect(_on_folder_updated)


## Called by pipeline when the overlay is shown/hidden.
func on_shown() -> void:
	# THE STRUCTURAL DISARM (see _park_mode). Every time the grid comes up it comes up
	# in PLAY mode, so curate can never be inherited from a previous visit — and a
	# performer who taps a clip expecting it to play always gets a clip.
	_set_park_mode(false)
	# The DECK filter disarms on the same rule and for the same reason: a view
	# that hides most of the library must never be inherited from a previous
	# visit. Reopening the grid to 12 of 220 clips, with no memory of having
	# filtered, reads as a broken library rather than an armed mode.
	_deck_filter = 0
	_restyle_deck_filter()
	# ...and it opens at the TOP. Without this the grid reopened wherever it was
	# last scrolled, clipping the first row under the header — which reads as a
	# broken layout rather than as retained scroll.
	_scroll_y = 0.0
	reload()


## Android BACK while the grid is up (S24 §3). CURATE is a DESTRUCTIVE mode — a tap
## parks, a long-press deletes from the device — so BACK disarms it first and closes
## the grid only on a second press. Same reasoning as on_shown()'s structural disarm:
## the armed state must never survive a transition the performer didn't aim at.
func handle_back() -> void:
	if _park_mode:
		_set_park_mode(false)
		return
	hide()


# --- CURATE mode ---------------------------------------------------------

func _toggle_park_mode() -> void:
	_set_park_mode(not _park_mode)


func _set_park_mode(on: bool) -> void:
	if on == _park_mode:
		return
	_park_mode = on
	_restyle_park()


## Loud armed state: the button fills green and the TITLE changes. The title is the
## part that matters — the button is small and a performer scanning the screen mid-set
## needs the header itself to say the grid will not play anything right now.
func _restyle_park() -> void:
	if _btn_park == null:
		return
	_btn_park.text = "CURATE ■" if _park_mode else "CURATE ▶"
	_btn_park.add_theme_color_override("font_color", BLACK if _park_mode else LABEL)
	var sb := StyleBoxFlat.new()
	sb.bg_color = accent() if _park_mode else BLACK
	sb.set_border_width_all(2 if _park_mode else 1)
	sb.border_color = accent() if _park_mode else _hairline()
	_btn_park.add_theme_stylebox_override("normal", sb)
	_btn_park.add_theme_stylebox_override("hover", sb)
	_btn_park.add_theme_stylebox_override("pressed", sb)
	if _title != null:
		_title.text = "CURATE POOL" if _park_mode else "CLIP GRID"
	_update_count()


## ALL -> A -> B -> ALL. Filtering is a VIEW, exactly like the folder tabs: it
## never changes what is in a sequence, only which clips are on screen.
func _cycle_deck_filter() -> void:
	_deck_filter = (_deck_filter + 1) % 3
	_restyle_deck_filter()
	_scroll_y = 0.0        # a new view starts at the top, like set_folder
	reload()
	deck_filter_changed.emit(_deck_filter)


## The button wears the hue of the deck it is filtering to, so the filter and
## the badges it is matching read as the same system.
func _restyle_deck_filter() -> void:
	if _btn_deck == null:
		return
	var hue := LABEL
	var txt := "DECK: ALL"
	if _deck_filter == 1:
		hue = GREEN
		txt = "DECK: A"
	elif _deck_filter == 2:
		hue = AMBER
		txt = "DECK: B"
	_btn_deck.text = txt
	_btn_deck.add_theme_color_override("font_color", BLACK if _deck_filter != 0 else LABEL)
	var sb := StyleBoxFlat.new()
	sb.bg_color = hue if _deck_filter != 0 else BLACK
	sb.set_border_width_all(1 if _deck_filter == 0 else 2)
	sb.border_color = _hairline() if _deck_filter == 0 else hue
	for s: String in ["normal", "hover", "pressed", "focus"]:
		_btn_deck.add_theme_stylebox_override(s, sb)


## Dock a widget (the FolderTabBar) centred in the header. Added after the header
## chrome so it draws on top of the header background; re-centred on resize.
func mount_header_center(w: Control) -> void:
	_header_widget = w
	add_child(w)
	# The widget sizes itself later (in its own setup, after this add_child), so
	# re-centre whenever its size changes — not just once here.
	w.resized.connect(_layout_header_widget)
	_layout_header_widget()


func _layout_header_widget() -> void:
	if _header_widget == null:
		return
	var left0 := _btn_deck.position.x + _btn_deck.size.x + 10.0 if _btn_deck != null else 0.0
	if _header_widget.has_method("set_max_width"):
		_header_widget.call("set_max_width", maxf(0.0, size.x - HEADER_RIGHT_RESERVE - left0))
	var sz := _header_widget.size
	# Centred — but never over the DECK filter on its left or the count on its
	# right. Sub-folder chips (beta2) make the bar wider than the free centre, and
	# the translucent ALL tab sitting on "DECK: ALL" read as "ALLALL" on the P8.
	# Wider than the whole free span: left-aligned, the count's empty left part
	# (its text is right-aligned) absorbs the overflow before DONE does.
	var left := 0.0
	if _btn_deck != null:
		left = _btn_deck.position.x + _btn_deck.size.x + 10.0
	var right := size.x - HEADER_RIGHT_RESERVE
	var x := (size.x - sz.x) * 0.5
	x = left if sz.x > right - left else clampf(x, left, right - sz.x)
	_header_widget.position = Vector2(x, (HEADER_H - sz.y) * 0.5)


func current_folder() -> String:
	return _folder_id


func set_folder(folder_id: String) -> void:
	if folder_id == _folder_id:
		return
	_folder_id = folder_id
	_scroll_y = 0.0   # a new view starts at the top
	reload()


## The empty state (beta2 §2.3): the ident loop, dimmed and muted, behind
## LOAD DEMO CLIPS / IMPORT PACK / GET MORE CLIPS. Shown only when the whole
## library is empty — an empty LIVE or folder view is just an empty grid.
func _build_empty() -> void:
	_empty = Control.new()
	_empty.visible = false
	_empty.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_empty.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_empty)
	var path := Storage.idle_clip_path()
	if path != "":
		_empty_video = VideoPlayback.new()
		_empty_video.enable_audio = false
		_empty_video.loop = true
		_empty_video.enable_auto_play = true
		_empty_video.modulate = Color(1, 1, 1, 0.28)
		_empty_video.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_empty_video.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_empty.add_child(_empty_video)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_empty.add_child(center)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	center.add_child(box)
	var lbl := Label.new()
	lbl.text = "NO CLIPS YET"
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", 18)
	lbl.add_theme_color_override("font_color", LABEL)
	box.add_child(lbl)
	for pair: Array in [["LOAD DEMO CLIPS", "demo"], ["IMPORT PACK (.ZIP)…", "pack"], ["GET MORE CLIPS…", "more"]]:
		var b := Button.new()
		b.text = pair[0]
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size = Vector2(360, 56)
		b.add_theme_font_size_override("font_size", 18)
		b.pressed.connect(func(): empty_action.emit(pair[1]))
		box.add_child(b)


func _update_empty() -> void:
	if _empty == null:
		return
	var show := ClipLibrary.get_folder("all").clip_ids.is_empty()
	if show == _empty.visible:
		return
	_empty.visible = show
	if _empty_video == null:
		return
	if show:
		if not _empty_video.is_open():
			_empty_video.set_video_path(Storage.idle_clip_path())
		else:
			_empty_video.play()
	else:
		_empty_video.pause()


## Rebuild the id list from the library and relayout from the top.
func reload() -> void:
	_ids = ClipLibrary.get_folder(_folder_id).clip_ids
	_update_empty()
	# The deck filter narrows the folder view to one lane's sequence. It stacks
	# WITH the folder tabs (ALL/LIVE/PARKED) rather than replacing them — two
	# independent questions: "which library view" and "which deck owns it".
	if _deck_filter != 0:
		var mem: Dictionary = _mem_a if _deck_filter == 1 else _mem_b
		var kept: Array[String] = []
		for id: String in _ids:
			if mem.has(id):
				kept.append(id)
		_ids = kept
	_sync_active_from_engine()
	_relayout()
	_update_count()


## The count doubles as the CURATE legend. Both of that mode's gestures are invisible
## otherwise — a hold that deletes a file needs to announce itself somewhere the eye
## already goes, and the title has no room left beside the CURATE button.
func _update_count() -> void:
	if _count_lbl == null:
		return
	if _park_mode:
		_count_lbl.text = "TAP PARK · HOLD REMOVE"
	else:
		_count_lbl.text = "%d CLIP%s" % [_ids.size(), "" if _ids.size() == 1 else "S"]


# --- Layout --------------------------------------------------------------

func _relayout() -> void:
	var grid_w := size.x - PAD * 2.0
	_cols = maxi(1, int((grid_w + GAP) / (CELL_W + GAP)))
	var used := float(_cols) * CELL_W + float(_cols - 1) * GAP
	_left_margin = PAD + maxf(0.0, (grid_w - used) * 0.5)
	var rows := int(ceil(float(_ids.size()) / float(_cols)))
	_content_h = float(rows) * (CELL_H + GAP)
	_scroll_y = clampf(_scroll_y, 0.0, _max_scroll())
	# Everything currently realized is now stale (cols/positions changed): recycle all.
	for idx: int in _cells.keys():
		_free_cell(idx)
	_refresh_visible()


## Reserve space at the bottom for the SequenceStrip so grid rows never lay out
## (or scroll) under it. Re-lays out immediately.
func set_bottom_inset(px: float) -> void:
	if is_equal_approx(px, _bottom_inset):
		return
	_bottom_inset = px
	_relayout()


func _view_h() -> float:
	return size.y - HEADER_H - _bottom_inset


func _max_scroll() -> float:
	return maxf(0.0, _content_h - _view_h() + PAD * 2.0)


func _refresh_visible() -> void:
	if not visible or _ids.is_empty():
		return
	var view_h := _view_h()
	var row_h := CELL_H + GAP
	var first_row := maxi(0, int(_scroll_y / row_h) - 1)
	var last_row := int((_scroll_y + view_h) / row_h) + 1
	var first_i := first_row * _cols
	var last_i := mini(_ids.size() - 1, (last_row + 1) * _cols - 1)
	for idx: int in _cells.keys():
		if idx < first_i or idx > last_i:
			_free_cell(idx)
	for i: int in range(first_i, last_i + 1):
		var cell := _cells.get(i) as Panel
		if cell == null:
			cell = _acquire_cell()
			_cells[i] = cell
			_configure_cell(cell, i)
		_position_cell(cell, i)


func _position_cell(cell: Panel, i: int) -> void:
	var row := i / _cols
	var col := i % _cols
	cell.position = Vector2(
		_left_margin + float(col) * (CELL_W + GAP),
		HEADER_H + PAD + float(row) * (CELL_H + GAP) - _scroll_y)
	cell.size = Vector2(CELL_W, CELL_H)


# --- Cells (pooled) ------------------------------------------------------

func _acquire_cell() -> Panel:
	var cell: Panel
	if not _pool.is_empty():
		cell = _pool.pop_back()
		cell.visible = true
	else:
		cell = _make_cell()
		_content.add_child(cell)
	return cell


func _make_cell() -> Panel:
	var cell := Panel.new()
	cell.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cell.add_theme_stylebox_override("panel", _cell_sb(false))

	var tr := TextureRect.new()
	tr.name = "thumb"
	tr.position = Vector2(2, 2)
	tr.size = Vector2(CELL_W - 4.0, THUMB_H)
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	tr.clip_contents = true
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cell.add_child(tr)

	var lbl := Label.new()
	lbl.name = "label"
	lbl.position = Vector2(6, THUMB_H + 2.0)
	lbl.size = Vector2(CELL_W - 12.0, LABEL_H)
	lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", CELL_FS)
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if _font_label != null:
		lbl.add_theme_font_override("font", _font_label)
	cell.add_child(lbl)

	# Deck membership, top-left over the thumbnail: "A", "B" or "AB". Outlined
	# because it sits on moving video, the same reason the strip's slot numbers
	# are. Empty string = in neither sequence, which is most of the library.
	var deck := Label.new()
	deck.name = "deck"
	deck.position = Vector2(5, 3)
	deck.size = Vector2(CELL_W - 10.0, 20.0)
	deck.add_theme_font_size_override("font_size", BADGE_FS)
	deck.add_theme_color_override("font_outline_color", BLACK)
	deck.add_theme_constant_override("outline_size", 6)
	deck.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if _font_label != null:
		deck.add_theme_font_override("font", _font_label)
	cell.add_child(deck)
	return cell


func _configure_cell(cell: Panel, i: int) -> void:
	var id := _ids[i]
	cell.set_meta("id", id)
	_id_to_cell[id] = cell
	var cd := ClipLibrary.get_clip(id)
	var tr := cell.get_node("thumb") as TextureRect
	var lbl := cell.get_node("label") as Label
	var deck := cell.get_node("deck") as Label
	tr.texture = null   # placeholder (black cell) until the thumbnail arrives
	# A clip can be playing on BOTH decks at once. The ring then takes the ARMED
	# lane's hue — that is the deck the next tap would fire, so it is the one the
	# eye needs — and the membership badges below still name both.
	var on_a := (i == _active_a)
	var on_b := (i == _active_b)
	var active := on_a or on_b
	var hue := GREEN
	if on_b and (not on_a or _armed_lane == 1):
		hue = AMBER
	var live := cd != null and cd.is_live
	lbl.text = (cd.display_name if cd != null else id).to_upper()
	lbl.add_theme_color_override("font_color", hue if active else (TEXT if live else LABEL))
	cell.add_theme_stylebox_override("panel", _cell_sb(active, i == _drop_target, hue))
	cell.modulate = Color(1, 1, 1, 1) if (live or active) else Color(1, 1, 1, 0.5)
	_apply_deck_badge(deck, id)
	if ThumbnailService.is_failed(id):
		_mark_cant_play(cell)
	ThumbnailService.request(id)


## "A" green, "B" amber, "AB" both — drawn as one string with the A half tinted,
## which Label cannot do, so the common case (one deck) is coloured and the rare
## both-decks case falls back to TEXT with both letters. Legible beats clever.
func _apply_deck_badge(deck: Label, id: String) -> void:
	var in_a: bool = _mem_a.has(id)
	var in_b: bool = _mem_b.has(id)
	if in_a and in_b:
		deck.text = "AB"
		deck.add_theme_color_override("font_color", TEXT)
	elif in_a:
		deck.text = "A"
		deck.add_theme_color_override("font_color", GREEN)
	elif in_b:
		deck.text = "B"
		deck.add_theme_color_override("font_color", AMBER)
	else:
		deck.text = ""


func _free_cell(idx: int) -> void:
	var cell := _cells.get(idx) as Panel
	if cell == null:
		return
	_cells.erase(idx)
	if cell.has_meta("id"):
		var id := str(cell.get_meta("id"))
		if _id_to_cell.get(id) == cell:
			_id_to_cell.erase(id)
	var tr := cell.get_node("thumb") as TextureRect
	tr.texture = null          # free the off-screen texture (§7 risk 3)
	cell.visible = false
	_pool.append(cell)


func _cell_sb(active: bool, drop: bool = false, hue: Color = GREEN) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(hue.r, hue.g, hue.b, 0.10) if active else BLACK
	sb.set_border_width_all(2 if active else 1)
	# ⚠️ The RING takes the owning deck's hue (identity — deck A stays green even
	# while B is armed, so you can see both decks playing). The HAIRLINE takes the
	# ARMED deck's hue (chrome), which is what turns the whole surface amber.
	sb.border_color = hue if active else _hairline()
	# Reorder drop target: a thick bright border, distinct from the ACTIVE (playing)
	# cell so the two cannot be confused mid-drag. Takes the ARMED deck's hue —
	# a drop adds to the armed lane, so it should look like that lane.
	if drop:
		var dh := accent()
		sb.bg_color = Color(dh.r, dh.g, dh.b, 0.22)
		sb.set_border_width_all(4)
		sb.border_color = dh
	return sb


## The armed deck's colour — green for lane A, amber for lane B. The one hue
## question this widget asks, and the header, the drop target and an optimistic
## tap all read it from here.
func accent() -> Color:
	return AMBER if _armed_lane == 1 else GREEN


## LINE is a GREEN-tinted hairline, so every inactive cell kept a green edge even
## with deck B armed — the one thing that stopped the surface reading as amber.
## Same 0.16 alpha, the armed deck's hue.
func _hairline() -> Color:
	var a := accent()
	return Color(a.r, a.g, a.b, 0.16)


# --- Header --------------------------------------------------------------

func _build_header() -> void:
	var hb := ColorRect.new()
	hb.color = BLACK
	hb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hb.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	hb.offset_bottom = HEADER_H
	add_child(hb)

	_rule = ColorRect.new()
	_rule.color = _hairline()
	_rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rule.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_rule.offset_top = HEADER_H - 1.0
	_rule.offset_bottom = HEADER_H
	add_child(_rule)

	_title = Label.new()
	_title.text = "CLIP GRID"
	_title.position = Vector2(PAD + 6.0, 0)
	_title.size = Vector2(TITLE_W, HEADER_H)
	_title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_title.add_theme_font_size_override("font_size", TITLE_FS)
	_title.add_theme_color_override("font_color", GREEN)
	_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_title)

	# CURATE arm/disarm. Left cluster, clear of the centred FolderTabBar and the
	# count/DONE pair on the right.
	var park_x := PAD + 6.0 + TITLE_W + 12.0
	_btn_park = Button.new()
	_btn_park.custom_minimum_size = Vector2(PARK_W, HDR_BTN_H)
	_btn_park.position = Vector2(park_x, (HEADER_H - HDR_BTN_H) * 0.5)
	_btn_park.size = Vector2(PARK_W, HDR_BTN_H)
	_btn_park.mouse_filter = Control.MOUSE_FILTER_STOP
	if _font_label != null:
		_btn_park.add_theme_font_override("font", _font_label)
	_btn_park.pressed.connect(_toggle_park_mode)
	add_child(_btn_park)
	_restyle_park()

	# DECK filter — the on-demand split. Sits right of CURATE and ends before the
	# centred FolderTabBar; it is the one control that answers "show me only what
	# belongs to this deck" without permanently halving the grid.
	_btn_deck = Button.new()
	_btn_deck.custom_minimum_size = Vector2(DECK_W, HDR_BTN_H)
	_btn_deck.position = Vector2(park_x + PARK_W + 10.0, (HEADER_H - HDR_BTN_H) * 0.5)
	_btn_deck.size = Vector2(DECK_W, HDR_BTN_H)
	_btn_deck.focus_mode = Control.FOCUS_NONE
	_btn_deck.mouse_filter = Control.MOUSE_FILTER_STOP
	_btn_deck.add_theme_font_size_override("font_size", DECK_FS)
	if _font_label != null:
		_btn_deck.add_theme_font_override("font", _font_label)
	_btn_deck.pressed.connect(_cycle_deck_filter)
	add_child(_btn_deck)
	_restyle_deck_filter()

	# Count sits at the RIGHT, just left of DONE, so the header CENTRE is free for
	# the FolderTabBar (added as a child by pipeline in step 4).
	_count_lbl = Label.new()
	_count_lbl.text = ""
	_count_lbl.anchor_left = 1.0
	_count_lbl.anchor_right = 1.0
	_count_lbl.offset_left = -560.0   # wide enough for the CURATE legend; still clear
	                                  # of the centred FolderTabBar
	_count_lbl.offset_right = -150.0
	_count_lbl.offset_top = 0.0
	_count_lbl.offset_bottom = HEADER_H
	_count_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_count_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_count_lbl.add_theme_font_size_override("font_size", COUNT_FS)
	_count_lbl.add_theme_color_override("font_color", DIMTEXT)
	_count_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_count_lbl)

	_btn_done = Button.new()
	_btn_done.text = "DONE"
	_btn_done.custom_minimum_size = Vector2(120, HDR_BTN_H)
	_btn_done.position = Vector2(0, (HEADER_H - HDR_BTN_H) * 0.5)
	_btn_done.anchor_left = 1.0
	_btn_done.anchor_right = 1.0
	_btn_done.offset_left = -138.0
	_btn_done.offset_right = -18.0
	_btn_done.focus_mode = Control.FOCUS_NONE
	_btn_done.mouse_filter = Control.MOUSE_FILTER_STOP
	if _font_label != null:
		_btn_done.add_theme_font_override("font", _font_label)
	_btn_done.pressed.connect(func() -> void: hide())
	add_child(_btn_done)
	_restyle_done()


# --- Input (tap-to-play + drag-to-scroll) --------------------------------

func _gui_input(e: InputEvent) -> void:
	if e is InputEventScreenTouch:
		_saw_touch = true
		_press((e as InputEventScreenTouch).position, (e as InputEventScreenTouch).pressed)
	elif e is InputEventScreenDrag:
		var d := e as InputEventScreenDrag
		_drag(d.relative, d.position)
	elif e is InputEventMouseButton and not _saw_touch:
		var mb := e as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_press(mb.position, mb.pressed)
	elif e is InputEventMouseMotion and not _saw_touch:
		var mm := e as InputEventMouseMotion
		if mm.button_mask & MOUSE_BUTTON_MASK_LEFT:
			_drag(mm.relative, mm.position)


func _press(pos: Vector2, pressed: bool) -> void:
	if pressed:
		_press_pos = pos
		_press_index = _index_at(pos)
		_moved = 0.0
		_dragging = false
		_longpressed = false
		_grabbing = false
		_longpress_t = 0.0
		set_process(_press_index >= 0)   # tick the long-press timer only over a cell
		return
	set_process(false)
	if _grabbing:
		_grabbing = false
		var over := _index_at(pos)
		_set_drop_target(-1)
		# ⚠️ THE DROP TARGET DISAMBIGUATES, so one release can only ever mean one thing.
		# Released onto ANOTHER cell -> reorder ("put it here"). Released on empty grid
		# space or over the sequence strip -> the existing grab behaviour (add to the
		# sequence). Dropping onto a specific clip reads as placement, not as queueing.
		if over >= 0 and over < _ids.size() and over != _press_index and _press_index >= 0:
			clip_reorder_requested.emit(_ids[_press_index], _ids[over])
			return
		clip_grab_ended.emit(_to_global(pos))
		return
	if _longpressed:
		return   # the long-press consumed this touch; don't also tap
	if press_gate.is_valid() and press_gate.call():
		return   # a help card took this touch
	# A tap is press+release at ~the same spot. Check the press->release DISTANCE, not
	# just accumulated drag: a fast swipe can deliver DOWN+UP with sparse drag events,
	# so _dragging alone can miss it and turn a scroll into an accidental play.
	if not _dragging and _press_pos.distance_to(pos) <= TAP_SLOP:
		_try_tap(pos)


func _drag(rel: Vector2, pos: Vector2) -> void:
	if _grabbing:
		# Show where a reorder would land. Without this the drop point is invisible and
		# the gesture is a guess.
		var over := _index_at(pos)
		_set_drop_target(over if (over >= 0 and over != _press_index) else -1)
		clip_grab_moved.emit(_to_global(pos))   # proxy follows; strip previews the drop
		return
	_moved += absf(rel.x) + absf(rel.y)
	if _moved > TAP_SLOP:
		_dragging = true
		set_process(false)   # a scroll cancels the pending long-press
	_scroll_y = clampf(_scroll_y - rel.y, 0.0, _max_scroll())
	_refresh_visible()


func _process(delta: float) -> void:
	# Only ticks while a finger rests on a cell: after LONGPRESS_SEC with no drag,
	# start a grab of that clip (Step 6). Pipeline floats the proxy from here.
	_longpress_t += delta
	if _longpress_t >= LONGPRESS_SEC and not _dragging and not _longpressed:
		set_process(false)
		if press_gate.is_valid() and press_gate.call():
			return   # a help card took this touch
		if _press_index >= 0 and _press_index < _ids.size():
			_longpressed = true
			# The CURATE fork. _grabbing stays false, so the release path below skips
			# the grab/reorder branch entirely and this hold cannot also queue or move
			# the clip it just asked to delete.
			if _park_mode:
				clip_remove_requested.emit(_ids[_press_index])
				return
			_grabbing = true
			var id := _ids[_press_index]
			var cell := _cells.get(_press_index) as Panel
			var tex: Texture2D = null
			if cell != null:
				tex = (cell.get_node("thumb") as TextureRect).texture
			clip_grab_started.emit(id, tex, _to_global(_press_pos))


func _to_global(local: Vector2) -> Vector2:
	return global_position + local


func _try_tap(pos: Vector2) -> void:
	var i := _index_at(pos)
	if i < 0:
		return
	# The one fork. In CURATE the tap NEVER reaches _play, so the two meanings cannot
	# both fire from one touch — the same "a drag has exactly one possible meaning"
	# property the warp editor's two sub-modes rely on, and the reason this is a mode
	# rather than a proximity or timing test that could be got wrong.
	if _park_mode:
		clip_park_toggled.emit(_ids[i])
	else:
		_play(i)


func _index_at(pos: Vector2) -> int:
	if pos.y < HEADER_H or pos.y > size.y - _bottom_inset:
		return -1
	var row_h := CELL_H + GAP
	var cy := pos.y - (HEADER_H + PAD) + _scroll_y
	if cy < 0.0:
		return -1
	var row := int(cy / row_h)
	if cy - float(row) * row_h > CELL_H:
		return -1   # in the gap between rows
	var cx := pos.x - _left_margin
	if cx < 0.0:
		return -1
	var col := int(cx / (CELL_W + GAP))
	if cx - float(col) * (CELL_W + GAP) > CELL_W:
		return -1   # in the gap between columns
	if col >= _cols:
		return -1
	var i := row * _cols + col
	return i if i >= 0 and i < _ids.size() else -1


func _play(i: int) -> void:
	# Emit intent; pipeline resolves the id to an engine index and jumps. The
	# optimistic highlight goes on the ARMED deck — feedback before clip_changed
	# echoes back, and on the lane that will actually play it.
	_set_deck_index(_armed_lane, i)
	clip_activated.emit(_ids[i])


# --- Active-clip highlight + library changes -----------------------------

## Engine A's echo. It updates DECK A's ring and nothing else — before the
## split it wrote the one shared index, which is how it overwrote a lane-B tap.
func _on_clip_changed(_name: String, index: int, _count: int) -> void:
	if index < 0 or index >= _engine.clips.size():
		return
	var id := ClipLibrary.id_for_path(_engine.clips[index])
	_set_deck_index(0, _ids.find(id))


## Deck A only — this grid is constructed with engine A. Deck B's ring arrives
## through set_deck_active(), pushed by pipeline from engine B.
func _sync_active_from_engine() -> void:
	if _engine == null or _engine.current_index < 0 or _engine.current_index >= _engine.clips.size():
		_active_a = -1
		return
	var id := ClipLibrary.id_for_path(_engine.clips[_engine.current_index])
	_active_a = _ids.find(id)


func _set_deck_index(lane: int, gi: int) -> void:
	var prev := _active_b if lane == 1 else _active_a
	if gi == prev:
		return
	if lane == 1:
		_active_b = gi
	else:
		_active_a = gi
	_restyle_index(prev)
	_restyle_index(gi)


## Pipeline pushes each deck's playing clip here — deck A from its own engine,
## deck B from engine B. "" clears that deck's ring.
func set_deck_active(lane: int, clip_id: String) -> void:
	_set_deck_index(lane, _ids.find(clip_id) if clip_id != "" else -1)


## Which deck a tap fires. Repaints everything that carries the hue, so the
## whole surface says where the next tap lands rather than one dim word.
func set_armed_lane(lane: int) -> void:
	if lane == _armed_lane:
		return
	_armed_lane = lane
	_restyle_all()


## The clip ids in each lane's sequence. Pushed on every sequence change and on
## every open — the grid holds no model, it only renders what it is handed.
func set_membership(a_ids: Array, b_ids: Array) -> void:
	_mem_a.clear()
	_mem_b.clear()
	for id: String in a_ids:
		_mem_a[id] = true
	for id: String in b_ids:
		_mem_b[id] = true
	# ⚠️ While a DECK filter is up, membership decides the VISIBLE LIST, not just
	# the badges — so a clip added to that lane has to enter the view, and one
	# removed has to leave it. Restyling alone left the filtered list stale.
	if _deck_filter != 0:
		reload()
	else:
		_restyle_all()


## Repaint every piece of CHROME in the armed deck's hue. Identity stays put:
## the cells' rings and A/B badges are re-derived in _configure_cell from which
## deck OWNS them, so deck A keeps its green ring while deck B is armed.
func _restyle_all() -> void:
	if _title != null:
		_title.add_theme_color_override("font_color", accent())
	if _rule != null:
		_rule.color = _hairline()
	if _header_widget != null and _header_widget.has_method("set_accent"):
		_header_widget.call("set_accent", accent())
	_restyle_park()
	_restyle_deck_filter()
	_restyle_done()
	for idx: int in _cells.keys():
		_restyle_index(idx)


## DONE is chrome — the way out of the grid, not a deck's property.
func _restyle_done() -> void:
	if _btn_done == null:
		return
	var a := accent()
	_btn_done.add_theme_color_override("font_color", a)
	_btn_done.add_theme_color_override("font_hover_color", a)
	_btn_done.add_theme_color_override("font_pressed_color", BLACK)
	var sb := StyleBoxFlat.new()
	sb.bg_color = BLACK
	sb.set_border_width_all(1)
	sb.border_color = a
	for s: String in ["normal", "hover", "pressed", "focus"]:
		_btn_done.add_theme_stylebox_override(s, sb)


## Highlight the cell a reorder would drop onto. -1 clears.
func _set_drop_target(i: int) -> void:
	if i == _drop_target:
		return
	var prev := _drop_target
	_drop_target = i
	_restyle_index(prev)
	_restyle_index(i)


func _restyle_index(i: int) -> void:
	if i < 0:
		return
	var cell := _cells.get(i) as Panel
	if cell != null:
		_configure_cell(cell, i)   # re-applies active border + label color


func _on_thumb_ready(clip_id: String, tex: Texture2D) -> void:
	var cell := _id_to_cell.get(clip_id) as Panel
	if cell != null:
		(cell.get_node("thumb") as TextureRect).texture = tex


func _on_thumb_failed(clip_id: String) -> void:
	var cell := _id_to_cell.get(clip_id) as Panel
	if cell != null:
		_mark_cant_play(cell)


## A clip that never gave a frame: say so on the tile instead of a black cell.
func _mark_cant_play(cell: Panel) -> void:
	var lbl := cell.get_node("label") as Label
	if not lbl.text.begins_with("CAN'T PLAY"):
		lbl.text = "CAN'T PLAY · " + lbl.text   # words, not a colour: RED is for destructive actions only


func _on_folder_updated(folder_id: String) -> void:
	if visible and folder_id == _folder_id:
		reload()


func _on_resized() -> void:
	_layout_header_widget()
	_relayout()
