#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = ["pillow"]
# ///
"""The PVJ launcher + store icons from the ident (beta2 §2.2, §4).

    uv run branding/make_ident_icons.py

Reads dist/ident/pvj-icon-src.png (1024², letters in the inner safe square,
outer 15 % clear — tools/ident/make_ident.py) and pvj-splash-1080.png, writes:

  branding/icon_fg_432.png      adaptive foreground: the letters, transparent elsewhere
  branding/icon_bg_432.png      adaptive background: black
  branding/icon_main_192.png    legacy icon: black rounded square + the letters
  dist/store/pvj-icon-512.png   the Play icon (opaque, no alpha, Play rounds it)
  dist/store/pvj-feature-1024x500.png   the feature graphic: the splash frame, cropped

Godot's exporter makes every mipmap density from the 192 / 432 inputs.
"""
import os
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "dist", "ident", "pvj-icon-src.png")
SPLASH = os.path.join(ROOT, "dist", "ident", "pvj-splash-1080.png")
BR = os.path.join(ROOT, "branding")
STORE = os.path.join(ROOT, "dist", "store")
os.makedirs(STORE, exist_ok=True)

src = Image.open(SRC).convert("L")


def letters_rgba(size):
    """White cells on transparent, a box filter: cells and gaps average to a soft grid at icon sizes."""
    g = src.resize((size, size), Image.BOX)
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    white = Image.new("RGBA", (size, size), (255, 255, 255, 255))
    out.paste(white, (0, 0), g)
    return out


def on_black(size, radius=0):
    bg = Image.new("RGBA", (size, size), (0, 0, 0, 255))
    bg.alpha_composite(letters_rgba(size))
    if radius:
        from PIL import ImageDraw
        mask = Image.new("L", (size, size), 0)
        ImageDraw.Draw(mask).rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
        bg.putalpha(mask)
    return bg


letters_rgba(432).save(os.path.join(BR, "icon_fg_432.png"))
Image.new("RGBA", (432, 432), (0, 0, 0, 255)).save(os.path.join(BR, "icon_bg_432.png"))
# The legacy icon is shown whole (no mask): crop to the inner 70 % so the
# letters fill it like the adaptive one does after masking.
inner = src.crop((154, 154, 1024 - 154, 1024 - 154))
legacy = Image.new("RGBA", (192, 192), (0, 0, 0, 255))
w = Image.new("RGBA", (192, 192), (255, 255, 255, 255))
legacy.paste(w, (0, 0), inner.resize((192, 192), Image.BOX))
from PIL import ImageDraw
m = Image.new("L", (192, 192), 0)
ImageDraw.Draw(m).rounded_rectangle([0, 0, 191, 191], radius=40, fill=255)
legacy.putalpha(m)
legacy.save(os.path.join(BR, "icon_main_192.png"))
# Play's 512 icon: full square, opaque, no alpha channel.
play = Image.new("RGB", (512, 512), (0, 0, 0))
play.paste((255, 255, 255), (0, 0), inner.resize((512, 512), Image.BOX))
play.save(os.path.join(STORE, "pvj-icon-512.png"))
# Feature graphic 1024×500: the splash frame scaled to width, centre crop.
sp = Image.open(SPLASH).convert("RGB").resize((1024, 576), Image.BOX)
sp.crop((0, 38, 1024, 538)).save(os.path.join(STORE, "pvj-feature-1024x500.png"))
for f in ("icon_fg_432.png", "icon_bg_432.png", "icon_main_192.png"):
    print(f, Image.open(os.path.join(BR, f)).size)
for f in ("pvj-icon-512.png", "pvj-feature-1024x500.png"):
    im = Image.open(os.path.join(STORE, f)); print(f, im.size, im.mode)
