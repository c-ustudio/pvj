#!/usr/bin/env python3
"""Play listing screenshots from raw phone captures — see docs/STORE_LISTING.md.

    python3 tools/store_screenshots.py dist/store/screenshots/raw_<date> dist/store/play_screenshots [--16x9-only]

The raw captures are `adb exec-out screencap -p` from the Pixel 8 (2400x1080,
2.22:1 — wider than Play's 2:1 limit). Nothing is ever cropped; each one is
letterboxed with black:

  * NN_name.png       2400x1200, the capture at 1:1 with 60 px bars top and bottom (2:1);
  * NN_name_16x9.png  1920x1080, the capture scaled to 1920x864, 108 px bars (16:9).

`--16x9-only` writes just the second. Plus _contact_sheet.png (every output,
labelled). Exit status 1 if an input is not 2400x1080 or an output is 8 MB or
more (Play's per-screenshot limit).
"""
import os
import sys

from PIL import Image, ImageDraw

RAW_SIZE = (2400, 1080)
MAX_BYTES = 8 * 1024 * 1024


def letterbox(img: Image.Image, size: tuple) -> Image.Image:
    """`img` scaled to fit `size` (never up), centred on black."""
    w, h = size
    s = min(w / img.width, h / img.height, 1.0)
    fit = img if s == 1.0 else img.resize((round(img.width * s), round(img.height * s)), Image.LANCZOS)
    out = Image.new("RGB", size, (0, 0, 0))
    out.paste(fit, ((w - fit.width) // 2, (h - fit.height) // 2))
    return out


def contact_sheet(paths: list, out_path: str) -> None:
    """Every output in two columns, in order, each tile 800 px wide and labelled."""
    tile_w, pad, label_h, cols = 800, 24, 34, 2
    tiles = []
    for p in paths:
        im = Image.open(p)
        tiles.append((f"{os.path.basename(p)}  ({im.width}x{im.height})",
                      im.resize((tile_w, tile_w * im.height // im.width))))
    row_h = label_h + max(t.height for _, t in tiles)
    rows = (len(tiles) + cols - 1) // cols
    sheet = Image.new("RGB", (pad + cols * (tile_w + pad), pad + rows * (row_h + pad)), (24, 24, 24))
    d = ImageDraw.Draw(sheet)
    for i, (label, tile) in enumerate(tiles):
        x = pad + (i % cols) * (tile_w + pad)
        y = pad + (i // cols) * (row_h + pad)
        d.text((x, y + 8), label, fill=(0, 255, 65))
        sheet.paste(tile, (x, y + label_h))
    sheet.save(out_path, optimize=True)


def main() -> int:
    args = [a for a in sys.argv[1:] if a != "--16x9-only"]
    if len(args) != 2:
        print(__doc__)
        return 2
    raw_dir, out_dir = args
    sizes = (("_16x9", (1920, 1080)),) if "--16x9-only" in sys.argv else (("", (2400, 1200)), ("_16x9", (1920, 1080)))
    os.makedirs(out_dir, exist_ok=True)
    bad = 0
    made = []
    for name in sorted(f for f in os.listdir(raw_dir) if f.endswith(".png")):
        img = Image.open(os.path.join(raw_dir, name)).convert("RGB")
        if img.size != RAW_SIZE:
            print(f"{name}: {img.size[0]}x{img.size[1]}, expected {RAW_SIZE[0]}x{RAW_SIZE[1]} — skipped")
            bad = 1
            continue
        for suffix, size in sizes:
            out = os.path.join(out_dir, name.replace(".png", suffix + ".png"))
            letterbox(img, size).save(out, optimize=True)
            n = os.path.getsize(out)
            flag = "" if n < MAX_BYTES else "   <-- 8 MB OR MORE"
            bad |= n >= MAX_BYTES
            print(f"{os.path.basename(out)}: {size[0]}x{size[1]}, {n / 1e6:.2f} MB{flag}")
            made.append(out)
    if made:
        contact_sheet(made, os.path.join(out_dir, "_contact_sheet.png"))
        print("_contact_sheet.png")
    return bad


if __name__ == "__main__":
    sys.exit(main())
