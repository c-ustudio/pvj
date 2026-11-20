#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = ["numpy", "pillow"]
# ///
"""The PVJ ident: a 10 s seamless Game of Life loop that spells COLLECTIVE
(over) unconscious, then PVJ.

    uv run tools/ident/make_ident.py
    uv run tools/ident/make_ident.py --rule B36/S23 --name highlife

Writes dist/ident/pvj-ident-v1-life-1080.mp4, -720.mp4 and
pvj-ident-v1-life-preview.gif, plus the icon source and the idle copy
(below). The launch splash (clip + boot still) is NOT made here: it is cut
from the organic ident by tools/ident/make_splash_organic.py;
with --name, only the loop, into dist/ident/rules/<name>/ as
pvj-ident-<name>-*.mp4 instead. --rule takes any Life-like rule in B/S
notation (Conway's Life is B3/S23; HighLife is B36/S23).

The hold phases pin the letters exactly: every letter cell alive, the
1-cell ring around the letters dead, so nothing accretes on the strokes
and no stroke erodes. The letter masks are dilated by DILATE cells and
set with LETTER_SPACING cells between glyphs (V and J touched before).
During a hold the background reseed runs at HOLD_RESEED of its rate.

The icon source is its own small square simulation (ICON_GRID cells): the
word fills ICON_TEXT of the inner safe area, and the outer ICON_MARGIN ring
is cleared, so the adaptive-icon mask clips no gliders.

300 frames at 30 fps; the simulation's frame 300 is
asserted equal to frame 0 before anything is encoded, so the loop closes.

How a letter forms: every letter cell has a fixed place in a lock-in order
(several octaves of noise plus per-cell jitter). As the eased ramp rises,
cells lock alive in that order, so the letters grow as feathered patches
out of the running Life instead of snapping solid. Letter cells just ahead
of the lock-in front get an extra birth chance, so Life gathers before the
letter sets; live cells outside get an extra death chance on the same curve,
strongest near the letters and light far from them. The hold keeps every
cell locked and runs plain Life elsewhere; the release unlocks them in
reverse order, so the letters erode into Life rather than dying in one step.

Blending the parts: the word windows overlap, one eroding while the next
gathers, and wherever the background thins out, compact clumps of soup are
dropped every few frames, so the field never goes empty without blinking.
The last 45 frames dissolve into the last 45 warm-up steps, the Life run
that ends AT frame 0: every cell has a fixed random threshold and follows
that run once the crossfade passes it, so frame 300 is frame 0 by
construction and the motion carries straight through the cut (a static
frame-0 target froze the field for the last few frames, then jumped back
into motion).
"""
import argparse
import os
import subprocess
import time

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

def find_root(start):
    """The repo (the folder with project.godot), so a copy of this script
    saved next to its renders still finds the fonts and writes to dist/."""
    d = start
    while not os.path.exists(os.path.join(d, "project.godot")):
        if os.path.dirname(d) == d:
            return os.path.dirname(start)
        d = os.path.dirname(d)
    return d


ROOT = find_root(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "dist", "ident")

# --- knobs ------------------------------------------------------------------
SEED = 20261006
RULE = "B3/S23"                    # Conway's Life; any Life-like B/S rule works
GRID_W, GRID_H = 192, 108          # cells; 10 px each at 1080p
WIDTH, HEIGHT = 1920, 1080
FPS = 30
FRAMES = 300
CELL_GAP = 2                       # px of black gap between cells (0 = none)
DILATE = 1                         # cells: the letter masks grow this much
LETTER_SPACING = 1                 # cells of extra space between glyphs
HOLD_RESEED = 0.6                  # background reseed rate during a hold

# The brand pixel face; when FONT_NATIVE_PX is set the glyphs are rendered at
# that size and scaled by a whole number, so every letter pixel is a whole
# block of cells. Set it to None for a vector font.
FONT_PATH = os.path.join(ROOT, "fonts", "PressStart2P-Regular.ttf")
FONT_NATIVE_PX = 8
FONT_FALLBACK = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
PIXEL_MIN_SCALE = 2                # below this the word gets FONT_FALLBACK
TEXT_AREA = 0.70                   # letters stay inside the inner 70%

SOUP_DENSITY = 0.35                # the seed soup...
WARMUP = 400                       # ...run this long, so frame 0 already looks like Life

BIRTH_BIAS = 0.06                  # extra birth chance in unlocked letter cells at bias 1
DEATH_BIAS = 0.18                  # extra death chance outside the letters at bias 1
HALO = 7                           # cells: the clearing is strongest this close to the letters
HALO_FAR = 0.15                    # ...and this fraction of it far from them
RESEED = 0.3                       # soup density of a reseed clump...
RESEED_EVERY = 6                   # ...dropped every this many frames...
RESEED_CLUMP = 0.8                 # ...where the drifting noise is above this
RESEED_TARGET = 0.6                # refill up to this fraction of frame 0's density
RESEED_PATCHES = (12, 7)           # the drifting noise is this coarse
# lock-in order: noise octaves as ((cols, rows), weight); fewer cols = bigger patches
ORDER_OCTAVES = (((7, 4), 1.0), ((20, 11), 0.55), ((48, 27), 0.3))
ORDER_JITTER = 0.4                 # per-cell randomness in the order: 0 = clean blobs
FRONT = 0.3                        # Life gathers this far (in order) ahead of the lock-in
EASE = 0.5                         # 0 = linear pace, 1 = full smoothstep

# (start, end) frame windows; a phase covers start <= f < end. The windows
# overlap on purpose: one word erodes while the next is already gathering.
WORDS = [
    # word,  ramp up,      hold,         release
    ("COLLECTIVE\nunconscious", (55, 105), (105, 135), (135, 178)),
    ("PVJ", (158, 210), (210, 240), (240, 282)),
]
# The icon source: its own square simulation. The word fills ICON_TEXT of the
# inner safe area (the adaptive mask keeps the inner ~66 %), and everything in
# the outer ICON_MARGIN ring is cleared.
ICON_PX, ICON_GRID = 1024, 128     # 128 cells square at 8 px each
ICON_MARGIN = 0.15                 # the ring that is cleared
ICON_TEXT = 0.80                   # of the inner square
ICON_WORD = ("PVJ", (40, 90), (90, 120), (120, 160))
ICON_FRAME = 105                   # mid-hold
CONVERGE = (255, 300)              # dissolve into the run that ends at frame 0
# ----------------------------------------------------------------------------


def parse_rule(rule):
    """'B36/S23' → (born, survives), each a lookup by neighbour count."""
    born, survives = np.zeros(9, bool), np.zeros(9, bool)
    for part in rule.upper().split("/"):
        table = {"B": born, "S": survives}[part[0]]
        table[[int(c) for c in part[1:]]] = True
    return born, survives


def life_step(g):
    n = sum(np.roll(np.roll(g, dy, 0), dx, 1).astype(np.uint8)
            for dy in (-1, 0, 1) for dx in (-1, 0, 1) if dy or dx)
    born, survives = parse_rule(RULE)
    return np.where(g, survives[n], born[n])


def glyph_ink(ch, font, pixel):
    """One glyph's ink as a bool array, cropped, plus its advance in px."""
    probe = ImageDraw.Draw(Image.new("L", (1, 1)))
    l, t, r, b = probe.textbbox((0, 0), ch, font=font)
    adv = font.getlength(ch)
    img = Image.new("L", (int(np.ceil(r)) + 4, int(np.ceil(b)) + 4), 0)
    d = ImageDraw.Draw(img)
    if pixel:
        d.fontmode = "1"           # no antialiasing on a pixel face
    d.text((2, 2), ch, font=font, fill=255)
    a = np.array(img) > 127
    return a, adv


def render_text(word, path, size, pixel, spacing_px):
    """The word drawn glyph by glyph (so the letter spacing can be set),
    lines centred, cropped to its ink. spacing_px goes between glyphs."""
    font = ImageFont.truetype(path, size)
    line_gap = size // (4 if pixel else 8)
    asc, desc = font.getmetrics()
    line_h = asc + desc
    lines = word.split("\n")
    rows = []
    for line in lines:
        x = 0.0
        canvas = Image.new("L", (int(size * len(line) * 1.5) + 8, line_h + 8), 0)
        d = ImageDraw.Draw(canvas)
        if pixel:
            d.fontmode = "1"
        for ch in line:
            d.text((int(round(x)) + 2, 2), ch, font=font, fill=255)
            x += font.getlength(ch) + spacing_px
        a = np.array(canvas) > 127
        xs = np.nonzero(a.any(0))[0]
        rows.append(a[:, xs.min():xs.max() + 1] if xs.size else a[:, :1])
    w = max(r.shape[1] for r in rows)
    out = np.zeros((line_h * len(rows) + line_gap * (len(rows) - 1) + 8, w), bool)
    y = 0
    for r in rows:
        x0 = (w - r.shape[1]) // 2
        out[y:y + r.shape[0], x0:x0 + r.shape[1]] |= r
        y += line_h + line_gap
    ys, xs = np.nonzero(out)
    return out[ys.min():ys.max() + 1, xs.min():xs.max() + 1]


def pixel_word(word, path, size, s):
    """The pixel face at scale s: every glyph a whole block of cells, laid
    out in cell space with LETTER_SPACING cells between glyphs (a spacing in
    native px would be s cells, too wide)."""
    font = ImageFont.truetype(path, size)
    asc, desc = font.getmetrics()
    line_h = asc + desc
    line_gap = (size // 4) * s
    rows = []
    for line in word.split("\n"):
        parts = []
        for ch in line:
            adv = int(round(font.getlength(ch)))
            canvas = Image.new("L", (adv + 8, line_h + 4), 0)
            d = ImageDraw.Draw(canvas)
            d.fontmode = "1"
            d.text((2, 2), ch, font=font, fill=255)
            a = (np.array(canvas) > 127)[:, 2:2 + adv]
            parts.append(np.kron(a, np.ones((s, s), bool)))
            parts.append(np.zeros((a.shape[0] * s, LETTER_SPACING), bool))
        row = np.concatenate(parts[:-1], 1)
        xs = np.nonzero(row.any(0))[0]
        rows.append(row[:, xs.min():xs.max() + 1])
    w = max(r.shape[1] for r in rows)
    h = sum(r.shape[0] for r in rows) + line_gap * (len(rows) - 1)
    out = np.zeros((h, w), bool)
    y = 0
    for r in rows:
        x0 = (w - r.shape[1]) // 2
        out[y:y + r.shape[0], x0:x0 + r.shape[1]] = r
        y += r.shape[0] + line_gap
    ys, xs = np.nonzero(out)
    return out[ys.min():ys.max() + 1, xs.min():xs.max() + 1]


def dilate(m, n=1):
    """Grow a mask by n cells (8-neighbourhood)."""
    for _ in range(n):
        m = m | sum(np.roll(np.roll(m, dy, 0), dx, 1)
                    for dy in (-1, 0, 1) for dx in (-1, 0, 1) if dy or dx).astype(bool)
    return m


def word_mask(word, grid, area):
    """The word as a bool cell grid, centred, fit inside `area` of `grid`,
    dilated by DILATE cells with LETTER_SPACING cells between glyphs. The
    pixel face is used only when it fits at PIXEL_MIN_SCALE or more; a long
    word at 1x has 1-cell strokes that Life chews up, so it gets the bold
    sans fallback, fit to the box."""
    gw, gh = grid
    box_w, box_h = int(gw * area), int(gh * area)
    pad = 2 * DILATE
    if FONT_NATIVE_PX and os.path.exists(FONT_PATH):
        a = render_text(word, FONT_PATH, FONT_NATIVE_PX, True, 0)
        h, w = a.shape
        s = min((box_w - pad) // w, (box_h - pad) // h)
        if s >= PIXEL_MIN_SCALE:
            cells = pixel_word(word, FONT_PATH, FONT_NATIVE_PX, s)
            return place(dilate(cells_pad(cells, DILATE), DILATE), grid)
    path = FONT_PATH if os.path.exists(FONT_PATH) and not FONT_NATIVE_PX \
        else FONT_FALLBACK
    a = render_text(word, path, 400, False, 0)
    h, w = a.shape
    s = min((box_w - pad) / w, (box_h - pad) / h)
    a = render_text(word, path, 400, False, LETTER_SPACING / s)
    h, w = a.shape
    s = min((box_w - pad) / w, (box_h - pad) / h)
    cw, ch = max(1, round(w * s)), max(1, round(h * s))
    cells = np.array(Image.fromarray(a.astype(np.uint8) * 255)
                     .resize((cw, ch), Image.BOX)) > 127
    return place(dilate(cells_pad(cells, DILATE), DILATE), grid)


def cells_pad(cells, n):
    return np.pad(cells, n)


def place(cells, grid):
    """Centre a cell pattern on the grid."""
    gw, gh = grid
    m = np.zeros((gh, gw), bool)
    h, w = cells.shape
    y0, x0 = (gh - h) // 2, (gw - w) // 2
    m[y0:y0 + h, x0:x0 + w] = cells
    return m


def ramp(f, a, b):
    return min(max((f - a) / (b - a), 0.0), 1.0)


def smoothstep(x):
    return x * x * (3 - 2 * x)


def ease(x):
    return (1 - EASE) * x + EASE * smoothstep(x)


def lock_order(m, rng):
    """Each letter cell's lock-in point in [0, 1), evenly spread, so the
    locked fraction follows the eased curve exactly."""
    gh, gw = m.shape
    raw = ORDER_JITTER * rng.random(m.shape)
    for (cols, rows), weight in ORDER_OCTAVES:
        coarse = rng.random((rows, cols)).astype(np.float32)
        raw += weight * np.array(Image.fromarray(coarse).resize(
            (gw, gh), Image.BICUBIC))
    order = np.ones(m.shape)       # never locks outside the mask
    idx = np.argsort(raw[m], kind="stable")
    ranks = np.empty(idx.size)
    ranks[idx] = np.arange(idx.size) / idx.size
    order[m] = ranks
    return order


def halo(m):
    """1 on and near the letters, falling to HALO_FAR within ~2*HALO cells."""
    img = Image.fromarray(m.astype(np.uint8) * 255)
    blur = np.array(img.filter(ImageFilter.GaussianBlur(HALO))) / 255.0
    near = np.clip(blur / max(blur.max(), 1e-6) * 2.5, 0.0, 1.0)
    return HALO_FAR + (1.0 - HALO_FAR) * near


def word_bias(f, up, hold, rel):
    """The eased 0→1→0 curve that drives one word."""
    if up[0] <= f < up[1]:
        return ease(ramp(f, up[0], up[1] - 1))
    if hold[0] <= f < hold[1]:
        return 1.0
    if rel[0] <= f < rel[1]:
        return 1.0 - ease(ramp(f, rel[0] - 1, rel[1] - 1))
    return 0.0


def simulate(grid=(GRID_W, GRID_H), words=WORDS, frames=FRAMES,
             converge=CONVERGE, area=TEXT_AREA, seed=SEED):
    """Run the loop on a grid of (w, h) cells; returns the states (frames+1
    of them) and the word masks. With converge=None the run just ends."""
    gw, gh = grid
    rng = np.random.default_rng(seed)
    g = rng.random((gh, gw)) < SOUP_DENSITY
    warm = [g]
    for _ in range(WARMUP):
        g = life_step(g)
        warm.append(g)
    f0 = g.copy()
    masks = [word_mask(w, grid, area) for w, *_ in words]
    rings = [dilate(m) & ~m for m in masks]  # the 1-cell halo kept clear
    settle = rng.random((gh, gw))             # per-cell crossfade threshold
    orders = [lock_order(m, rng) for m in masks]
    halos = [halo(m) for m in masks]
    target = f0.mean() * RESEED_TARGET        # the background density to keep
    coarse = rng.random(RESEED_PATCHES[::-1]).astype(np.float32)
    patches = np.array(Image.fromarray(coarse).resize((gw, gh), Image.BICUBIC))

    states = [f0]
    for f in range(1, frames + 1):
        g = life_step(g)
        locked = np.zeros_like(g)
        cleared = np.zeros_like(g)
        clearing = np.zeros(g.shape)        # how hard the words clear each cell
        holding = False
        for m, ring, order, hl, (_, up, hold, rel) in zip(masks, rings, orders,
                                                          halos, words):
            bias = word_bias(f, up, hold, rel)
            if bias <= 0.0:
                continue
            r = rng.random(g.shape)
            # births peak just ahead of the lock-in front and fade out FRONT
            # beyond it, so Life gathers where the letter is about to set
            near = np.clip(1.0 - (order - bias) / FRONT, 0.0, 1.0)
            g = np.where(m, g | (r < BIRTH_BIAS * near),
                         g & ~(r < DEATH_BIAS * bias * hl))
            clearing = np.maximum(clearing, bias * hl)
            if hold[0] <= f < hold[1]:
                # the hold: the whole letter alive, its 1-cell ring dead,
                # so nothing grows onto a stroke and no stroke erodes
                holding = True
                locked |= m
                cleared |= ring
            else:
                locked |= order < bias
        # where the background has thinned out, drop a few compact clumps of
        # soup, away from wherever a word is clearing; a clump grows into
        # proper Life, where scattered single cells only blinked
        free = clearing < 0.3
        deficit = max(0.0, 1.0 - g[free].mean() / target) if free.any() else 0
        if deficit > 0 and f % RESEED_EVERY == 0:
            drift = np.roll(patches, (f // 4, f // 2), (0, 1))
            clump = (drift > RESEED_CLUMP) & (clearing < 0.3)
            rate = RESEED * (HOLD_RESEED if holding else 1.0)
            g |= clump & (rng.random(g.shape) < rate * min(1.0, 2 * deficit))
        g |= locked                         # locked letter cells stay alive
        g &= ~cleared                       # the hold ring stays dead
        if converge and f >= converge[0]:
            x = ramp(f, *converge)
            alpha = smoothstep(x)           # exactly 1 at the last frame
            g = np.where(settle < alpha, warm[WARMUP + f - frames], g)
        states.append(g.copy())
    return np.array(states), masks


def cell_map(n_px, n_cells, gap):
    """Pixel → cell index, and which pixels are the gap at a cell's end."""
    px = np.arange(n_px)
    idx = (px * n_cells) // n_px
    end = -((-(idx + 1) * n_px) // n_cells)     # first px of the next cell
    return idx, px >= end - gap


def renderer(w, h, gap, cells=(GRID_W, GRID_H)):
    xi, xg = cell_map(w, cells[0], gap)
    yi, yg = cell_map(h, cells[1], gap)
    keep = ~(yg[:, None] | xg[None, :]) if gap else np.ones((h, w), bool)

    def render(g):
        return (g[yi][:, xi] & keep).astype(np.uint8) * 255
    return render


def encode(states, w, h, path, frames=FRAMES):
    render = renderer(w, h, CELL_GAP)
    cmd = ["ffmpeg", "-y", "-loglevel", "error",
           "-f", "rawvideo", "-pix_fmt", "gray", "-s", f"{w}x{h}",
           "-r", str(FPS), "-i", "-", "-an",
           "-c:v", "libx264", "-crf", "18", "-pix_fmt", "yuv420p",
           "-r", str(FPS), "-color_primaries", "bt709",
           "-color_trc", "bt709", "-colorspace", "bt709",
           "-movflags", "+faststart", path]
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE)
    for g in states[:frames]:
        p.stdin.write(render(g).tobytes())
    p.stdin.close()
    if p.wait():
        raise SystemExit(f"ffmpeg failed on {path}")


def write_gif(states, path):
    render = renderer(480, 270, 0)        # 2.5 px cells: a gap would eat them
    frames = [Image.fromarray(render(g)).convert("P")
              for g in states[:FRAMES:FPS // 10]]
    frames[0].save(path, save_all=True, append_images=frames[1:],
                   duration=100, loop=0, optimize=False)


def write_icon():
    """The icon source: a square simulation of its own, so the word sits at
    ICON_TEXT of the inner safe square and the outer ICON_MARGIN ring is
    clear of gliders. ICON_FRAME is mid-hold, so the letters are pinned."""
    n = ICON_GRID
    area = (1 - 2 * ICON_MARGIN) * ICON_TEXT
    states, (mask,) = simulate((n, n), [ICON_WORD], ICON_WORD[3][1],
                               converge=None, area=area, seed=SEED + 1)
    g = states[ICON_FRAME].copy()
    m = int(round(n * ICON_MARGIN))
    g[:m, :] = g[-m:, :] = False
    g[:, :m] = g[:, -m:] = False
    ys, xs = np.nonzero(mask)
    print(f"icon word: {xs.max() - xs.min() + 1}x{ys.max() - ys.min() + 1} "
          f"of {n} cells ({(xs.max() - xs.min() + 1) / n:.0%} of the width), "
          f"ring of {m} cells cleared")
    path = os.path.join(OUT, "pvj-icon-src.png")
    Image.fromarray(renderer(ICON_PX, ICON_PX, CELL_GAP, (n, n))(g)).save(path)
    return path


def write_idle(src, path):
    """The in-app idle screen: the 720p loop, stream-copied, no audio track."""
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", src,
                    "-map", "0:v", "-c", "copy", "-an",
                    "-movflags", "+faststart", path], check=True)


def frame_count(path):
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0", "-count_frames",
         "-show_entries", "stream=nb_read_frames,r_frame_rate,width,height",
         "-of", "csv=p=0", path], capture_output=True, text=True, check=True)
    return out.stdout.strip()


def main():
    global RULE, OUT, SOUP_DENSITY
    ap = argparse.ArgumentParser()
    ap.add_argument("--rule", default=RULE, help="Life-like rule, e.g. B36/S23")
    ap.add_argument("--name", help="write into dist/ident/rules/<name>/")
    ap.add_argument("--soup", type=float, default=SOUP_DENSITY,
                    help="seed density; rules that thin out need more")
    args = ap.parse_args()
    RULE, SOUP_DENSITY = args.rule, args.soup
    parse_rule(RULE)                         # fail early on a bad rule
    tag = "v1-life"
    if args.name:
        OUT = os.path.join(OUT, "rules", args.name)
        tag = args.name
    t0 = time.time()
    os.makedirs(OUT, exist_ok=True)
    print(f"rule {RULE}, soup {SOUP_DENSITY} -> {OUT}")
    states, masks = simulate()

    assert np.array_equal(states[FRAMES], states[0]), "loop does not close"
    steps = [int((states[i] != states[i + 1]).sum()) for i in range(FRAMES)]
    print(f"loop closes: sim frame {FRAMES} == frame 0 "
          f"({int(states[0].sum())} live cells)")
    print(f"cells changed 299->0: {steps[-1]}; per-frame median "
          f"{int(np.median(steps))}, min {min(steps)}, max {max(steps)}")
    for (w, *_), m in zip(WORDS, masks):
        ys, xs = np.nonzero(m)
        print(f"mask {w!r}: {xs.max() - xs.min() + 1}x{ys.max() - ys.min() + 1}"
              f" cells, x {xs.min()}-{xs.max()}, y {ys.min()}-{ys.max()}")
    # the holds pin the letters: every letter cell alive, the ring dead
    for m, (_, up, hold, rel) in zip(masks, WORDS):
        ring = dilate(m) & ~m
        for f in range(hold[0], hold[1]):
            assert states[f][m].all() and not states[f][ring].any(), \
                f"hold broken at frame {f}"

    for name, (w, h) in (("1080", (WIDTH, HEIGHT)), ("720", (1280, 720))):
        path = os.path.join(OUT, f"pvj-ident-{tag}-{name}.mp4")
        encode(states, w, h, path)
        print(f"{path}: {frame_count(path)}")
    gif = os.path.join(OUT, f"pvj-ident-{tag}-preview.gif")
    write_gif(states, gif)
    print(f"{gif}: {len(range(0, FRAMES, FPS // 10))} frames")
    if not args.name:
        icon = write_icon()
        print(f"{icon}: {Image.open(icon).size}")
        idle = os.path.join(OUT, "pvj-idle-720.mp4")
        write_idle(os.path.join(OUT, f"pvj-ident-{tag}-720.mp4"), idle)
        print(f"{idle}: {frame_count(idle)}")
    print(f"total {time.time() - t0:.1f} s")


if __name__ == "__main__":
    main()
