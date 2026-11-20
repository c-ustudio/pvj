#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = ["numpy", "pillow"]
# ///
"""The PVJ launch splash, cut from the ORGANIC ident (v2, 2026-10-06).

    uv run tools/ident/make_splash_organic.py
    uv run tools/ident/make_splash_organic.py --sheet /tmp/sheet.png
    uv run tools/ident/make_splash_organic.py --color 00FF41 --name green

With --color the live cells are that colour instead of white (the gaps and
the field stay black) and every output gets "-<name>" before its extension,
so a tinted try never overwrites the white set. 00FF41 is the deck's green
(M8_GREEN), the colour of the splash subtitle.

Writes, into dist/ident/:
    pvj-splash-720.mp4          the in-app clip: SPLASH_PAD copies of the
                                first frame, then SPLASH_CLIP of the loop, at
                                1280x720, 97 frames, 3.2 s, no audio
    pvj-splash-1080.png         the boot still: the clip's FIRST frame,
                                upscaled 1.5x bilinear to 1920x1080
    pvj-splash-720-preview.gif  the clip at 10 fps, to look at

The simulation below is the v2 "organic" ident verbatim (same seed, knobs,
timeline), so the clip is a true cut of that loop: frames 135-225. Frame 135
is the end of the COLLECTIVE unconscious hold; the clip erodes it (1.0 s),
gathers PVJ out of the Life (1.5 s) and holds PVJ (0.5 s). The app plays
the clip over the still and freezes on the last frame, then fades.

The pad: GoZen presents its first frame at the time elapsed since play
started, so the first frame on screen was clip frame 4-5 (measured on the
Pixel 9a, 2026-10-08) and the erosion started with a jump. SPLASH_PAD
copies of frame 135 at the head of the clip put that skip inside a hold:
what is lost is still, not motion. The still stays frame 135.

Why the still is an upscale of the clip and not a native 1080p render: the
clip is 720p and the GPU scales it 1.5x with a linear filter, which softens
the 1 px cell gaps. A native 1080p render would have crisp 1 px gaps at a
different proportion (10 % of a cell instead of 15 %), so the hand-over
from the still to the clip's first frame would pop. The upscaled still is
what the clip's first frame looks like on screen, so the hand-over is
invisible, as it was with the 1080p clip.

With --reference the renders are checked against the original v2 mp4: the
two frames at the cut's ends are decoded and compared, so a drifted numpy
or Pillow would show up as a large mean difference.

v2's own text, kept: a 10 s seamless Game of Life loop that spells
COLLECTIVE (over) unconscious, then PVJ. How a letter forms: every letter
cell has a fixed place in a lock-in order (several octaves of noise plus
per-cell jitter). As the eased ramp rises, cells lock alive in that order,
so the letters grow as feathered patches out of the running Life instead
of snapping solid. Letter cells just ahead of the lock-in front get an
extra birth chance, so Life gathers before the letter sets; live cells
outside get an extra death chance on the same curve. The hold keeps every
cell locked and runs plain Life elsewhere; the release unlocks them in
reverse order on the same curve, so the letters erode into Life rather
than dying in one step. (No stroke pinning, no dilation, no reseed: that is
what makes v2 organic and v1 clean.)
"""
import argparse
import os
import subprocess
import time

import numpy as np
from PIL import Image, ImageDraw, ImageFont


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
REFERENCE = os.path.join(OUT, "v2-organic", "pvj-ident-720.mp4")

# --- the splash --------------------------------------------------------------
CLIP_W, CLIP_H = 1280, 720         # the clip (the phone decodes this)
STILL_W, STILL_H = 1920, 1080      # the boot still (the clip's first frame)
SPLASH_CLIP = (135, 226)           # loop frames start <= f < end: 91 = 3.0 s
SPLASH_PAD = 6                     # copies of the first frame ahead of it (0.2 s)
SPLASH_WORD_AT = 210               # the PVJ hold starts (2.7 s into the clip)

# --- v2 knobs, verbatim -----------------------------------------------------
SEED = 20261006
GRID_W, GRID_H = 192, 108          # cells; 10 px each at 1080p
FPS = 30
FRAMES = 300
CELL_GAP = True                    # 1 px black gap between cells (mp4s only)

# The brand pixel face; when FONT_NATIVE_PX is set the glyphs are rendered at
# that size and scaled by a whole number, so every letter pixel is a whole
# block of cells. Set it to None for a vector font.
FONT_PATH = os.path.join(ROOT, "fonts", "PressStart2P-Regular.ttf")
FONT_NATIVE_PX = 8
FONT_FALLBACK = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
PIXEL_MIN_SCALE = 2                # below this the word gets FONT_FALLBACK
TEXT_AREA = 0.70                   # letters stay inside the inner 70%

SOUP_DENSITY = 0.35                # the seed soup...
WARMUP = 120                       # ...run this long, so frame 0 already looks like Life

BIRTH_BIAS = 0.12                  # extra birth chance in unlocked letter cells at bias 1
DEATH_BIAS = 0.18                  # extra death chance outside the letters at bias 1
# lock-in order: noise octaves as ((cols, rows), weight); fewer cols = bigger patches
ORDER_OCTAVES = (((7, 4), 1.0), ((20, 11), 0.55), ((48, 27), 0.3))
ORDER_JITTER = 0.55                # per-cell randomness in the order: 0 = clean blobs
FRONT = 0.3                        # Life gathers this far (in order) ahead of the lock-in
EASE = 0.5                         # 0 = linear pace, 1 = full smoothstep

# (start, end) frame windows; a phase covers start <= f < end
WORDS = [
    # word,  ramp up,      hold,         release
    ("COLLECTIVE\nunconscious", (60, 105), (105, 135), (135, 165)),
    ("PVJ", (165, 210), (210, 240), (240, 270)),
]
CONVERGE = (270, 300)              # dissolve into the run that ends at frame 0
# ----------------------------------------------------------------------------


def life_step(g):
    n = sum(np.roll(np.roll(g, dy, 0), dx, 1)
            for dy in (-1, 0, 1) for dx in (-1, 0, 1) if dy or dx)
    return (n == 3) | (g & (n == 2))


def render_text(word, path, size, pixel):
    """The word drawn once, centred line by line, cropped to its ink."""
    font = ImageFont.truetype(path, size)
    spacing = size // (4 if pixel else 8)   # between lines of a "\n" word
    probe = ImageDraw.Draw(Image.new("L", (1, 1)))
    l, t, r, b = probe.multiline_textbbox((0, 0), word, font=font,
                                          spacing=spacing, align="center")
    l, t, r, b = (int(np.floor(l)), int(np.floor(t)),
                  int(np.ceil(r)), int(np.ceil(b)))
    img = Image.new("L", (r - l + 4, b - t + 4), 0)
    d = ImageDraw.Draw(img)
    if pixel:
        d.fontmode = "1"           # no antialiasing on a pixel face
    d.multiline_text((2 - l, 2 - t), word, font=font, fill=255,
                     spacing=spacing, align="center")
    a = np.array(img) > 127
    ys, xs = np.nonzero(a)
    return a[ys.min():ys.max() + 1, xs.min():xs.max() + 1]


def word_mask(word):
    """The word as a bool cell grid, centred, fit inside TEXT_AREA. The
    pixel face is used only when it fits at PIXEL_MIN_SCALE or more; a long
    word at 1x has 1-cell strokes that Life chews up, so it gets the bold
    sans fallback, fit to the box."""
    box_w, box_h = int(GRID_W * TEXT_AREA), int(GRID_H * TEXT_AREA)
    if FONT_NATIVE_PX and os.path.exists(FONT_PATH):
        a = render_text(word, FONT_PATH, FONT_NATIVE_PX, True)
        h, w = a.shape
        s = min(box_w // w, box_h // h)
        if s >= PIXEL_MIN_SCALE:
            cells = np.kron(a, np.ones((s, s), bool))
            return place(cells)
    path = FONT_PATH if os.path.exists(FONT_PATH) and not FONT_NATIVE_PX \
        else FONT_FALLBACK
    a = render_text(word, path, 400, False)
    h, w = a.shape
    s = min(box_w / w, box_h / h)
    cw, ch = max(1, round(w * s)), max(1, round(h * s))
    cells = np.array(Image.fromarray(a.astype(np.uint8) * 255)
                     .resize((cw, ch), Image.BOX)) > 127
    return place(cells)


def place(cells):
    """Centre a cell pattern on the grid."""
    m = np.zeros((GRID_H, GRID_W), bool)
    h, w = cells.shape
    y0, x0 = (GRID_H - h) // 2, (GRID_W - w) // 2
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
    raw = ORDER_JITTER * rng.random(m.shape)
    for (cols, rows), weight in ORDER_OCTAVES:
        coarse = rng.random((rows, cols)).astype(np.float32)
        raw += weight * np.array(Image.fromarray(coarse).resize(
            (GRID_W, GRID_H), Image.BICUBIC))
    order = np.ones(m.shape)       # never locks outside the mask
    idx = np.argsort(raw[m], kind="stable")
    ranks = np.empty(idx.size)
    ranks[idx] = np.arange(idx.size) / idx.size
    order[m] = ranks
    return order


def word_bias(f, up, hold, rel):
    """The eased 0→1→0 curve that drives one word."""
    if up[0] <= f < up[1]:
        return ease(ramp(f, up[0], up[1] - 1))
    if hold[0] <= f < hold[1]:
        return 1.0
    if rel[0] <= f < rel[1]:
        return 1.0 - ease(ramp(f, rel[0] - 1, rel[1] - 1))
    return 0.0


def simulate():
    rng = np.random.default_rng(SEED)
    g = rng.random((GRID_H, GRID_W)) < SOUP_DENSITY
    warm = [g]
    for _ in range(WARMUP):
        g = life_step(g)
        warm.append(g)
    f0 = g.copy()
    masks = [word_mask(w) for w, *_ in WORDS]
    settle = rng.random((GRID_H, GRID_W))   # per-cell crossfade threshold
    orders = [lock_order(m, rng) for m in masks]

    states = [f0]
    for f in range(1, FRAMES + 1):
        g = life_step(g)
        for m, order, (_, up, hold, rel) in zip(masks, orders, WORDS):
            bias = word_bias(f, up, hold, rel)
            if bias <= 0.0:
                continue
            r = rng.random(g.shape)
            # births peak just ahead of the lock-in front and fade out FRONT
            # beyond it, so Life gathers where the letter is about to set
            near = np.clip(1.0 - (order - bias) / FRONT, 0.0, 1.0)
            g = np.where(m, g | (r < BIRTH_BIAS * near),
                         g & ~(r < DEATH_BIAS * bias))
            g |= order < bias              # locked letter cells stay alive
        if f >= CONVERGE[0]:
            x = ramp(f, *CONVERGE)
            alpha = smoothstep(x)           # exactly 1 at frame 300
            g = np.where(settle < alpha, warm[WARMUP + f - FRAMES], g)
        states.append(g.copy())
    return np.array(states), masks


def cell_map(n_px, n_cells):
    """Pixel → cell index, and which pixels are the last of their cell."""
    idx = (np.arange(n_px) * n_cells) // n_px
    last = np.append(idx[1:] != idx[:-1], True)
    return idx, last


COLOR = None                       # (r, g, b) tint of the live cells; None = white


def renderer(w, h, gap):
    """Frames as uint8 arrays: gray (h, w) when COLOR is None, else RGB
    (h, w, 3) with the live cells in COLOR."""
    xi, xl = cell_map(w, GRID_W)
    yi, yl = cell_map(h, GRID_H)
    keep = ~(yl[:, None] | xl[None, :]) if gap else np.ones((h, w), bool)
    tint = None if COLOR is None else np.array(COLOR, np.uint8)

    def render(g):
        on = g[yi][:, xi] & keep
        if tint is None:
            return on.astype(np.uint8) * 255
        return on[:, :, None] * tint
    return render


def encode(states, w, h, path):
    render = renderer(w, h, CELL_GAP)
    cmd = ["ffmpeg", "-y", "-loglevel", "error",
           "-f", "rawvideo", "-pix_fmt", "gray" if COLOR is None else "rgb24",
           "-s", f"{w}x{h}",
           "-r", str(FPS), "-i", "-", "-an",
           "-c:v", "libx264", "-crf", "18", "-pix_fmt", "yuv420p",
           "-r", str(FPS), "-color_primaries", "bt709",
           "-color_trc", "bt709", "-colorspace", "bt709",
           "-movflags", "+faststart", path]
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE)
    for g in states:
        p.stdin.write(render(g).tobytes())
    p.stdin.close()
    if p.wait():
        raise SystemExit(f"ffmpeg failed on {path}")


def write_gif(states, path):
    render = renderer(480, 270, False)    # 2.5 px cells: a gap would eat them
    frames = [Image.fromarray(render(g)).convert("P", palette=Image.ADAPTIVE)
              for g in states[::FPS // 10]]
    frames[0].save(path, save_all=True, append_images=frames[1:],
                   duration=100, loop=0, optimize=False)
    return len(frames)


def write_still(state, path):
    """The boot still: the clip's first frame as the screen shows it, the
    720p render scaled 1.5x with a linear filter (see the module text)."""
    small = Image.fromarray(renderer(CLIP_W, CLIP_H, CELL_GAP)(state))
    small.resize((STILL_W, STILL_H), Image.BILINEAR).save(path)


def write_sheet(states, path, every=15):
    """A contact sheet of the clip, one 320x180 tile every `every` frames."""
    render = renderer(320, 180, False)
    picks = list(range(0, len(states), every))
    if picks[-1] != len(states) - 1:
        picks.append(len(states) - 1)
    sheet = Image.new("RGB", (320 * len(picks), 180 + 14), 0)
    d = ImageDraw.Draw(sheet)
    for i, f in enumerate(picks):
        sheet.paste(Image.fromarray(render(states[f])).convert("RGB"), (320 * i, 14))
        d.text((320 * i + 4, 1), f"clip {f}  loop "
               f"{SPLASH_CLIP[0] + max(0, f - SPLASH_PAD)}  {f / FPS:.2f} s",
               fill=(255, 255, 255))
    sheet.save(path)
    return picks


def decode_frame(path, index, w, h):
    """One frame of an mp4 as a gray uint8 array."""
    out = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", path, "-vf", f"select=eq(n\\,{index})",
         "-vframes", "1", "-f", "rawvideo", "-pix_fmt", "gray", "-"],
        capture_output=True, check=True).stdout
    return np.frombuffer(out, np.uint8).reshape(h, w)


def frame_count(path):
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0", "-count_frames",
         "-show_entries", "stream=nb_read_frames,r_frame_rate,width,height",
         "-of", "csv=p=0", path], capture_output=True, text=True, check=True)
    return out.stdout.strip()


def main():
    global COLOR
    ap = argparse.ArgumentParser()
    ap.add_argument("--color", help="hex RGB tint of the live cells, e.g. 00FF41")
    ap.add_argument("--name", help="suffix for the outputs (default: the hex)")
    ap.add_argument("--reference", default=REFERENCE,
                    help="the original v2 720p loop to check the render against")
    ap.add_argument("--sheet", help="also write a contact sheet PNG here")
    args = ap.parse_args()
    suffix = ""
    if args.color:
        c = args.color.lstrip("#")
        COLOR = tuple(int(c[i:i + 2], 16) for i in (0, 2, 4))
        suffix = "-" + (args.name or c.lower())
        print(f"tint {COLOR} -> *{suffix}.*")
    t0 = time.time()
    os.makedirs(OUT, exist_ok=True)
    states, masks = simulate()
    assert np.array_equal(states[FRAMES], states[0]), "loop does not close"
    for (w, *_), m in zip(WORDS, masks):
        ys, xs = np.nonzero(m)
        print(f"mask {w!r}: {xs.max() - xs.min() + 1}x{ys.max() - ys.min() + 1}"
              f" cells, x {xs.min()}-{xs.max()}, y {ys.min()}-{ys.max()}")

    a, b = SPLASH_CLIP
    clip = np.concatenate([np.repeat(states[a:a + 1], SPLASH_PAD, 0), states[a:b]])
    word_at = SPLASH_PAD + SPLASH_WORD_AT - a
    print(f"clip: {SPLASH_PAD} x frame {a}, then loop frames {a}-{b - 1}: "
          f"{len(clip)} frames, {len(clip) / FPS:.2f} s; PVJ held from clip "
          f"frame {word_at} ({word_at / FPS:.2f} s)")
    # the cut's ends: COLLECTIVE still whole at the start, PVJ whole at the end
    col, pvj = masks
    print(f"frame {a}: {states[a][col].mean():.1%} of COLLECTIVE alive; "
          f"frame {b - 1}: {states[b - 1][pvj].mean():.1%} of PVJ alive, "
          f"{states[b - 1].mean():.1%} of the field")

    if COLOR is None and args.reference and os.path.exists(args.reference):
        render = renderer(CLIP_W, CLIP_H, CELL_GAP)
        for f in (a, b - 1):
            ref = decode_frame(args.reference, f, CLIP_W, CLIP_H)
            diff = np.abs(ref.astype(int) - render(states[f]).astype(int)).mean()
            print(f"vs {os.path.relpath(args.reference, ROOT)} frame {f}: "
                  f"mean abs diff {diff:.2f}/255")
            assert diff < 3.0, "this is not the v2 render"

    mp4 = os.path.join(OUT, f"pvj-splash-720{suffix}.mp4")
    encode(clip, CLIP_W, CLIP_H, mp4)
    print(f"{mp4}: {frame_count(mp4)}, {os.path.getsize(mp4) // 1024} KB")
    still = os.path.join(OUT, f"pvj-splash-1080{suffix}.png")
    write_still(clip[0], still)
    print(f"{still}: {Image.open(still).size}")
    gif = os.path.join(OUT, f"pvj-splash-720{suffix}-preview.gif")
    print(f"{gif}: {write_gif(clip, gif)} frames")
    if args.sheet:
        print(f"{args.sheet}: frames {write_sheet(clip, args.sheet)}")
    print(f"total {time.time() - t0:.1f} s")


if __name__ == "__main__":
    main()
