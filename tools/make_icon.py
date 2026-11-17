#!/usr/bin/env python3
"""Draws the SkiLo app icon: assets/AppIcon.icns (+ .png preview) for the Mac and a full-bleed
iOS/App/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png for the iPhone.

Design: macOS rounded-square tile, dusk-blue sky, two snowy peaks, and a rising Elo line that
climbs past the summit and ends in an arrow — skiing + rating in one mark.

    python3 tools/make_icon.py          # needs Pillow; uses `iconutil` (macOS) for the .icns
"""
import math
import os
import shutil
import subprocess
import tempfile

from PIL import Image, ImageChops, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(ROOT, "assets")
S = 4                       # supersampling factor
N = 1024 * S                # working canvas
BODY = 824 * S              # Apple's icon grid: 824 pt tile inside a 1024 canvas
INSET = (N - BODY) // 2
RADIUS = int(185 * S)


def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(len(a)))


def vertical_gradient(size, stops):
    """stops: [(t, (r,g,b)), ...] with t in 0..1 from top to bottom."""
    w, h = size
    img = Image.new("RGB", size)
    px = img.load()
    for y in range(h):
        t = y / (h - 1)
        for i in range(len(stops) - 1):
            t0, c0 = stops[i]
            t1, c1 = stops[i + 1]
            if t0 <= t <= t1:
                c = lerp(c0, c1, (t - t0) / (t1 - t0))
                break
        for x in range(w):
            px[x, y] = c
    return img


def tile_mask():
    m = Image.new("L", (N, N), 0)
    ImageDraw.Draw(m).rounded_rectangle([INSET, INSET, INSET + BODY, INSET + BODY], RADIUS, fill=255)
    return m


def P(x, y):
    """Design coordinates are 0..1 inside the tile."""
    return (INSET + x * BODY, INSET + y * BODY)


def draw_icon():
    # --- sky ---
    sky = vertical_gradient((N // 8, N // 8), [(0, (40, 92, 196)), (0.55, (24, 58, 140)), (1, (11, 27, 74))])
    sky = sky.resize((N, N), Image.BICUBIC)
    art = sky.convert("RGBA")
    d = ImageDraw.Draw(art)

    # soft glow behind the summit
    glow = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    cx, cy = P(0.56, 0.36)
    r = 0.36 * BODY
    gd.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(120, 190, 255, 90))
    art = Image.alpha_composite(art, glow.filter(ImageFilter.GaussianBlur(60 * S)))
    d = ImageDraw.Draw(art)

    # a few stars
    for (x, y, rr) in [(0.16, 0.16, 5), (0.30, 0.09, 3.5), (0.84, 0.14, 4), (0.75, 0.27, 3), (0.12, 0.36, 3)]:
        sx, sy = P(x, y)
        d.ellipse([sx - rr * S, sy - rr * S, sx + rr * S, sy + rr * S], fill=(225, 236, 255, 200))

    # --- back range (muted) ---
    back = [P(-0.05, 0.78), P(0.16, 0.52), P(0.27, 0.60), P(0.40, 0.46), P(0.50, 0.56), P(0.80, 0.40), P(1.05, 0.62), P(1.05, 1.05), P(-0.05, 1.05)]
    d.polygon(back, fill=(58, 96, 168, 255))

    # --- main peak ---
    peak = P(0.56, 0.26)
    left_base, right_base = P(0.02, 1.05), P(1.08, 1.05)
    d.polygon([left_base, peak, right_base], fill=(214, 228, 248, 255))
    # shaded right face
    d.polygon([peak, P(0.66, 0.62), P(0.60, 1.05), right_base], fill=(150, 178, 222, 255))
    # snow line: everything below the cap gets a cooler, darker rock-blue
    rock = [P(0.02, 1.05), P(0.30, 0.62), P(0.38, 0.66), P(0.46, 0.58), P(0.55, 0.65), P(0.64, 0.57),
            P(0.74, 0.66), P(0.84, 0.60), P(1.08, 0.86), P(1.08, 1.05)]
    d.polygon(rock, fill=(46, 84, 152, 255))
    # lighter snowy foreground slope
    fg = [P(-0.05, 0.90), P(0.30, 0.78), P(0.62, 0.86), P(1.05, 0.74), P(1.05, 1.05), P(-0.05, 1.05)]
    d.polygon(fg, fill=(236, 243, 252, 255))
    d.polygon([P(0.62, 0.86), P(1.05, 0.74), P(1.05, 1.05), P(0.75, 1.05)], fill=(205, 220, 242, 255))

    # --- rising Elo line with arrow ---
    pts = [P(0.10, 0.80), P(0.30, 0.68), P(0.43, 0.73), P(0.63, 0.47), P(0.74, 0.53), P(0.88, 0.22)]
    width = int(46 * S)
    line = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    ld = ImageDraw.Draw(line)
    # dark under-stroke for contrast on snow
    ld.line(pts, fill=(8, 22, 60, 120), width=width + int(22 * S), joint="curve")
    art = Image.alpha_composite(art, line.filter(ImageFilter.GaussianBlur(10 * S)))

    line = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    ld = ImageDraw.Draw(line)
    ld.line(pts, fill=(255, 255, 255, 255), width=width, joint="curve")
    for p in pts[:-1]:
        rr = width / 2
        ld.ellipse([p[0] - rr, p[1] - rr, p[0] + rr, p[1] + rr], fill=(255, 255, 255, 255))
    # arrow head along the last segment
    (x1, y1), (x2, y2) = pts[-2], pts[-1]
    ang = math.atan2(y2 - y1, x2 - x1)
    head_len, head_w = 150 * S, 130 * S
    tip = (x2 + math.cos(ang) * head_len * 0.55, y2 + math.sin(ang) * head_len * 0.55)
    base = (tip[0] - math.cos(ang) * head_len, tip[1] - math.sin(ang) * head_len)
    nx, ny = -math.sin(ang), math.cos(ang)
    ld.polygon([tip, (base[0] + nx * head_w / 2, base[1] + ny * head_w / 2), (base[0] - nx * head_w / 2, base[1] - ny * head_w / 2)],
               fill=(255, 255, 255, 255))
    # green→gold tint so it reads as "progress"
    tint = Image.new("RGBA", (N, N))
    tint_grad = vertical_gradient((N // 8, N // 8), [(0, (255, 214, 92)), (0.5, (120, 232, 150)), (1, (64, 214, 160))]).resize((N, N), Image.BICUBIC)
    tint.paste(tint_grad.convert("RGBA"))
    colored = ImageChops.multiply(line, tint)
    colored.putalpha(line.getchannel("A"))
    art = Image.alpha_composite(art, colored)

    # iPhone: full-bleed square (iOS rounds the corners itself; no transparency allowed)
    ios = art.crop((INSET, INSET, INSET + BODY, INSET + BODY)).convert("RGB").resize((1024, 1024), Image.LANCZOS)

    # --- Mac: clip to the tile, add drop shadow ---
    mask = tile_mask()
    tile = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    tile.paste(art, (0, 0), mask)
    # inner top highlight
    hl = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    ImageDraw.Draw(hl).rounded_rectangle([INSET, INSET, INSET + BODY, INSET + BODY], RADIUS, outline=(255, 255, 255, 60), width=4 * S)
    tile = Image.alpha_composite(tile, hl)

    shadow = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    sm = mask.point(lambda v: int(v * 0.45))
    shadow.putalpha(sm)
    shadow = shadow.transform((N, N), Image.AFFINE, (1, 0, 0, 0, 1, -12 * S)).filter(ImageFilter.GaussianBlur(22 * S))
    out = Image.alpha_composite(shadow, tile)
    return out.resize((1024, 1024), Image.LANCZOS), ios


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    icon, ios = draw_icon()
    ios_dir = os.path.join(ROOT, "iOS", "App", "Assets.xcassets", "AppIcon.appiconset")
    os.makedirs(ios_dir, exist_ok=True)
    ios.save(os.path.join(ios_dir, "AppIcon-1024.png"))
    print("wrote", os.path.join(ios_dir, "AppIcon-1024.png"))
    png_path = os.path.join(OUT_DIR, "AppIcon.png")
    icon.save(png_path)
    with tempfile.TemporaryDirectory() as tmp:
        iconset = os.path.join(tmp, "AppIcon.iconset")
        os.makedirs(iconset)
        for size in (16, 32, 128, 256, 512):
            icon.resize((size, size), Image.LANCZOS).save(os.path.join(iconset, f"icon_{size}x{size}.png"))
            icon.resize((size * 2, size * 2), Image.LANCZOS).save(os.path.join(iconset, f"icon_{size}x{size}@2x.png"))
        icns = os.path.join(OUT_DIR, "AppIcon.icns")
        if shutil.which("iconutil"):
            subprocess.run(["iconutil", "-c", "icns", iconset, "-o", icns], check=True)
            print("wrote", icns)
        else:
            print("iconutil not found (macOS only); wrote PNG only")
    print("wrote", png_path)


if __name__ == "__main__":
    main()
