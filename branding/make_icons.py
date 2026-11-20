#!/usr/bin/env python3
"""Generate the PVJ launcher icons: a keystoned projection frame with a play
triangle, and PVJ in a pixel face under it — the studio's reference mark
(2026-09-30), green on black. Also writes icon.svg for the desktop/project.

    python3 branding/make_icons.py
"""
import os
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))   # the repo root
OUT = f"{ROOT}/branding"
FONT = f"{ROOT}/fonts/PressStart2P-Regular.ttf"   # the pixel face of the reference
os.makedirs(OUT, exist_ok=True)

BLACK = (0, 0, 0, 255)
GREEN = (51, 255, 102, 255)     # #33ff66, the brand neon
GLOW = (51, 255, 102, 110)

# The mark, in a unit box: a keystone (wider at the top, tilted a touch, as a
# projection lands on a wall seen from beside the projector), the play
# triangle inside it, PVJ underneath.
FRAME = [(0.05, 0.11), (0.97, 0.02), (0.87, 0.60), (0.19, 0.63)]
TRI = [(0.37, 0.20), (0.69, 0.35), (0.37, 0.50)]
TEXT_TOP, TEXT_H = 0.70, 0.27


def P(box, p):
    x, y, w, h = box
    return (x + p[0] * w, y + p[1] * h)


def draw_mark(img, box, ss):
    """Frame + triangle + PVJ into `box` = (x, y, w, h) at supersample ss."""
    x, y, w, h = box
    stroke = max(2, int(w * 0.055))
    # Glow: the same shapes, blurred, under everything.
    glow = Image.new("RGBA", img.size, (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    frame = [P(box, p) for p in FRAME]
    tri = [P(box, p) for p in TRI]
    gd.line(frame + [frame[0]], fill=GLOW, width=int(stroke * 2.2), joint="curve")
    gd.polygon(tri, fill=GLOW)
    glow = glow.filter(ImageFilter.GaussianBlur(radius=w * 0.045))
    img.alpha_composite(glow)
    d = ImageDraw.Draw(img)
    d.line(frame + [frame[0]], fill=GREEN, width=stroke, joint="curve")
    # Square corners like the reference: cap each corner with a dot.
    for c in frame:
        d.ellipse([c[0] - stroke / 2, c[1] - stroke / 2, c[0] + stroke / 2, c[1] + stroke / 2], fill=GREEN)
    d.polygon(tri, fill=GREEN)
    # PVJ, fitted to the box's width.
    size = int(h * TEXT_H)
    f = ImageFont.truetype(FONT, size)
    while d.textlength("PVJ", font=f) > w * 0.98 and size > 8:
        size -= 1
        f = ImageFont.truetype(FONT, size)
    tb = d.textbbox((0, 0), "PVJ", font=f)
    tw, th = tb[2] - tb[0], tb[3] - tb[1]
    tx = x + (w - tw) / 2 - tb[0]
    ty = y + h * TEXT_TOP + (h * TEXT_H - th) / 2 - tb[1]
    tglow = Image.new("RGBA", img.size, (0, 0, 0, 0))
    ImageDraw.Draw(tglow).text((tx, ty), "PVJ", font=f, fill=GLOW)
    img.alpha_composite(tglow.filter(ImageFilter.GaussianBlur(radius=w * 0.03)))
    d.text((tx, ty), "PVJ", font=f, fill=GREEN)


def rounded_square(size, radius_frac=0.22):
    ss = 4
    img = Image.new("RGBA", (size * ss, size * ss), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([0, 0, size * ss - 1, size * ss - 1], radius=int(size * ss * radius_frac), fill=BLACK)
    inset = size * ss * 0.09
    draw_mark(img, (inset, inset, size * ss - 2 * inset, size * ss - 2 * inset), ss)
    return img.resize((size, size), Image.LANCZOS)


def adaptive_foreground(size=432):
    """Transparent; the mark inside a CIRCLE of 66/108 of the icon — the
    launcher's mask on the Pixels. The mark's corners reach ~0.69 of its
    box from the centre, so the box is 0.44 of the icon (0.44*0.69 = 0.30 <
    the circle's 0.306 radius)."""
    ss = 4
    img = Image.new("RGBA", (size * ss, size * ss), (0, 0, 0, 0))
    safe = size * ss * 0.44
    off = (size * ss - safe) / 2
    draw_mark(img, (off, off, safe, safe), ss)
    return img.resize((size, size), Image.LANCZOS)


def adaptive_background(size=432):
    return Image.new("RGBA", (size, size), BLACK)


def project_svg(path):
    """icon.svg: the same mark, PVJ built from pixel rectangles (Godot's SVG
    renderer has no text)."""
    glyphs = {
        "P": ["###.", "#..#", "###.", "#...", "#..."],
        "V": ["#...#", "#...#", "#...#", ".#.#.", "..#.."],
        "J": ["..###", "....#", "....#", "#...#", ".###."],
    }
    s = 128
    box = (12, 12, 104, 104)
    fr = " ".join("%.1f,%.1f" % P(box, p) for p in FRAME)
    tr = " ".join("%.1f,%.1f" % P(box, p) for p in TRI)
    rects = []
    # 4+1+5+1+5 = 16 cells across, 5 down, fitted to the box width.
    cols = sum(len(g[0]) for g in glyphs.values()) + 2
    cell = box[2] / cols
    top = box[1] + box[3] * TEXT_TOP + (box[3] * TEXT_H - 5 * cell) / 2
    cx = box[0]
    for ch in "PVJ":
        g = glyphs[ch]
        for r, row in enumerate(g):
            for c, v in enumerate(row):
                if v == "#":
                    rects.append('<rect x="%.2f" y="%.2f" width="%.2f" height="%.2f" fill="#33ff66"/>'
                                 % (cx + c * cell, top + r * cell, cell + 0.2, cell + 0.2))
        cx += (len(g[0]) + 1) * cell
    svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="{s}" height="{s}" viewBox="0 0 {s} {s}">
  <rect width="{s}" height="{s}" rx="28" fill="#000000"/>
  <!-- PVJ: a keystoned projection frame, the play triangle, the name in pixels (branding/make_icons.py) -->
  <polygon points="{fr}" fill="none" stroke="#33ff66" stroke-width="6" stroke-linejoin="round"/>
  <polygon points="{tr}" fill="#33ff66"/>
  {chr(10).join("  " + r for r in rects)}
</svg>
'''
    open(path, "w").write(svg)


rounded_square(192).save(f"{OUT}/icon_main_192.png")
adaptive_foreground(432).save(f"{OUT}/icon_fg_432.png")
adaptive_background(432).save(f"{OUT}/icon_bg_432.png")
project_svg(f"{ROOT}/icon.svg")
# A 512 preview composited like the launcher (bg + fg), and the square one.
bg = adaptive_background(512)
bg.alpha_composite(adaptive_foreground(512))
bg.save("/tmp/pvj_icon_adaptive_preview.png")
rounded_square(512).save("/tmp/pvj_icon_square_preview.png")
print("wrote icons to", OUT)
