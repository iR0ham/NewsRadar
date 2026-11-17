#!/usr/bin/env python3
"""Draws the News Radar app icon in the wine/maroon palette.

Run from the repository root:  python3 scripts/make_icon.py
Writes Resources/AppIcon.png and regenerates Resources/AppIcon.icns.

The icon is drawn at 4x and downsampled, because PIL has no antialiased arcs.
"""
import math
import os
import shutil
import subprocess
import tempfile

from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
SS = 4          # supersampling factor
W = SIZE * SS

# The palette, kept in step with Sources/NewsRadar/UI/Theme.swift.
MAROON_TOP = (188, 44, 58)      # #BC2C3A
MAROON_BOTTOM = (108, 16, 30)    # #6C101E
SLATE = (27, 29, 36)            # #1B1D24


def squircle_mask(size: int, radius_ratio: float = 0.225) -> Image.Image:
    """A macOS-ish squircle: rounded rect with a slightly superelliptical corner."""
    m = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(m)
    r = int(size * radius_ratio)
    d.rounded_rectangle([0, 0, size - 1, size - 1], radius=r, fill=255)
    return m


def gradient(size: int, top: tuple, bottom: tuple) -> Image.Image:
    """Vertical-diagonal gradient built one row at a time."""
    g = Image.new("RGB", (size, size))
    px = g.load()
    for y in range(size):
        t = y / max(1, size - 1)
        # Slight horizontal tilt so the gradient reads as light from the top left.
        for x in range(0, size, 1):
            u = (t * 0.82) + (x / max(1, size - 1)) * 0.18
            px[x, y] = (
                int(top[0] + (bottom[0] - top[0]) * u),
                int(top[1] + (bottom[1] - top[1]) * u),
                int(top[2] + (bottom[2] - top[2]) * u),
            )
    return g


def draw_icon() -> Image.Image:
    base = gradient(W, MAROON_TOP, MAROON_BOTTOM).convert("RGBA")

    # A dark slate wash in the lower left keeps the tile from glowing flat red.
    wash = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    wd = ImageDraw.Draw(wash)
    wd.ellipse([-int(W * 0.35), int(W * 0.42), int(W * 0.72), int(W * 1.28)],
               fill=SLATE + (110,))
    wash = wash.filter(ImageFilter.GaussianBlur(W * 0.10))
    base = Image.alpha_composite(base, wash)

    # Radar glyph: a source dot with three arcs opening to the top right.
    #
    # Shadows and light come from separate layers, and the light layer is drawn
    # last with its own canvas. Compositing a layer and then reusing the older
    # ImageDraw handle silently throws the light strokes away.
    cx, cy = int(W * 0.355), int(W * 0.655)
    sweep = (-92, -2)  # degrees, the way PIL's arc() measures them
    radii = (int(W * 0.185), int(W * 0.300), int(W * 0.415))
    widths = (int(W * 0.062), int(W * 0.058), int(W * 0.054))

    shadow_layer = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow_layer)
    light_layer = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    ld = ImageDraw.Draw(light_layer)

    for radius, width in zip(radii, widths):
        box = [cx - radius, cy - radius, cx + radius, cy + radius]
        sd.arc([b + int(W * 0.010) for b in box], sweep[0], sweep[1],
               fill=(0, 0, 0, 130), width=width)
        ld.arc(box, sweep[0], sweep[1], fill=(255, 249, 245, 255), width=width)

    dot_r = int(W * 0.068)
    sd.ellipse([cx - dot_r + int(W * 0.010), cy - dot_r + int(W * 0.010),
                cx + dot_r + int(W * 0.010), cy + dot_r + int(W * 0.010)],
               fill=(0, 0, 0, 140))
    ld.ellipse([cx - dot_r, cy - dot_r, cx + dot_r, cy + dot_r],
               fill=(255, 249, 245, 255))

    base = Image.alpha_composite(base, shadow_layer.filter(
        ImageFilter.GaussianBlur(W * 0.006)))
    base = Image.alpha_composite(base, light_layer)

    # Hairline rim, so the tile separates from a white or black desktop.
    rim = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    rd = ImageDraw.Draw(rim)
    rd.rounded_rectangle([2, 2, W - 3, W - 3], radius=int(W * 0.225),
                         outline=(255, 255, 255, 46), width=int(W * 0.004))
    base = Image.alpha_composite(base, rim)

    mask = squircle_mask(W)
    out = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    out.paste(base, (0, 0), mask)
    return out.resize((SIZE, SIZE), Image.LANCZOS)


def main() -> None:
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    res = os.path.join(root, "Resources")
    png = os.path.join(res, "AppIcon.png")
    icon = draw_icon()
    icon.save(png)
    print("wrote", png)

    iconset = tempfile.mkdtemp(suffix=".iconset")
    try:
        for px in (16, 32, 64, 128, 256, 512, 1024):
            icon.resize((px, px), Image.LANCZOS).save(
                os.path.join(iconset, f"icon_{px}x{px}.png"))
            if px <= 512:
                icon.resize((px * 2, px * 2), Image.LANCZOS).save(
                    os.path.join(iconset, f"icon_{px}x{px}@2x.png"))
        icns = os.path.join(res, "AppIcon.icns")
        subprocess.run(["iconutil", "-c", "icns", iconset, "-o", icns], check=True)
        print("wrote", icns)
    finally:
        shutil.rmtree(iconset, ignore_errors=True)


if __name__ == "__main__":
    main()
