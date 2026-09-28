"""Draws Leonard's app icon and writes a macOS .iconset.

The icon is the menu bar mark — a ring around a dot — on the macOS rounded
square, in Leonard's indigo. Drawn at 4x and downsampled, so every size is
antialiased. Needs only Pillow.

    python3 scripts/make_icon.py LeonardApp/Resources/AppIcon.iconset
    iconutil -c icns LeonardApp/Resources/AppIcon.iconset    # macOS only
"""

from __future__ import annotations

import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

TOP = (84, 82, 214)       # #5452D6
BOTTOM = (38, 34, 120)    # #262278
RING = (255, 255, 255)
DOT = (255, 184, 76)      # amber: "something needs you"


def draw(size: int = 1024, scale: int = 4) -> Image.Image:
    s = size * scale
    canvas = Image.new("RGBA", (s, s), (0, 0, 0, 0))

    # Apple's grid: an 824-pt squircle-ish rounded rect centered in 1024.
    inset = int(s * 100 / 1024)
    box = (inset, inset, s - inset, s - inset)
    radius = int(s * 185 / 1024)

    shadow = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        (box[0], box[1] + int(s * 0.012), box[2], box[3] + int(s * 0.012)), radius, fill=(0, 0, 0, 90)
    )
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(s * 0.012)))

    gradient = Image.new("RGBA", (s, s))
    top, bottom = TOP, BOTTOM
    pixels = gradient.load()
    for y in range(s):
        t = y / (s - 1)
        row = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)) + (255,)
        for x in range(s):
            pixels[x, y] = row
    mask = Image.new("L", (s, s), 0)
    ImageDraw.Draw(mask).rounded_rectangle(box, radius, fill=255)
    canvas.paste(gradient, (0, 0), mask)

    center = s / 2
    # A faint glow behind the dot: the moment something needs you.
    glow = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    g = s * 0.17
    ImageDraw.Draw(glow).ellipse((center - g, center - g, center + g, center + g), fill=DOT + (70,))
    canvas.alpha_composite(Image.composite(glow.filter(ImageFilter.GaussianBlur(s * 0.05)), Image.new("RGBA", (s, s)), mask))

    outer = s * 0.25
    width = s * 0.042
    draw = ImageDraw.Draw(canvas)
    draw.ellipse((center - outer, center - outer, center + outer, center + outer), outline=RING + (242,), width=int(width))
    inner = s * 0.088
    draw.ellipse((center - inner, center - inner, center + inner, center + inner), fill=DOT + (255,))

    return canvas.resize((size, size), Image.LANCZOS)


def main(out: Path) -> None:
    out.mkdir(parents=True, exist_ok=True)
    master = draw(1024)
    for points in (16, 32, 128, 256, 512):
        for factor in (1, 2):
            pixels = points * factor
            name = f"icon_{points}x{points}{'@2x' if factor == 2 else ''}.png"
            master.resize((pixels, pixels), Image.LANCZOS).save(out / name)
    master.save(out.parent / "AppIcon-1024.png")


if __name__ == "__main__":
    main(Path(sys.argv[1] if len(sys.argv) > 1 else "LeonardApp/Resources/AppIcon.iconset"))
