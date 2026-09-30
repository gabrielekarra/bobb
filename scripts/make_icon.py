"""Draws Bobb's app icon and writes a macOS .iconset.

The mark is a pair of round glasses whose eyes look up and left: black on a soft white tile, on
the macOS rounded square. The same geometry, in unit coordinates, is drawn
by `LeonardApp/Sources/LeonardApp/UI/Glasses.swift` for the menu bar and the
interface, so the three never drift apart. Drawn at 4x and downsampled, so
every size is antialiased. Needs only Pillow.

    uv run --with pillow python scripts/make_icon.py LeonardApp/Resources/AppIcon.iconset
    iconutil -c icns LeonardApp/Resources/AppIcon.iconset    # macOS only
"""

from __future__ import annotations

import math
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

# --- The glyph, in a unit box 1 wide and HEIGHT tall, y pointing down.
# Keep in sync with Glasses.swift.
HEIGHT = 0.46
LENS_R = 0.2
LENS_DX = 0.255          # lens centers at 0.5 ± LENS_DX
LENS_Y = 0.25
PUPIL_R = 0.074
PUPIL_TRAVEL = 0.082     # how far a pupil moves from the lens center
LINE = 0.05              # stroke width, in glyph widths
BRIDGE_LIFT = 0.045      # how far the bridge arches above its ends
BRIDGE_DEG = 28          # where the bridge meets each lens, degrees above horizontal
TEMPLE_DEG = 22          # where each temple leaves its lens
TEMPLE = (0.05, 0.035)   # temple stub: dx outwards, dy upwards

BLACK = (0, 0, 0, 255)


def _quad(p0, c, p1, steps=48):
    pts = []
    for i in range(steps + 1):
        t = i / steps
        x = (1 - t) ** 2 * p0[0] + 2 * (1 - t) * t * c[0] + t**2 * p1[0]
        y = (1 - t) ** 2 * p0[1] + 2 * (1 - t) * t * c[1] + t**2 * p1[1]
        pts.append((x, y))
    return pts


def _stroke(draw: ImageDraw.ImageDraw, pts, width: float, fill) -> None:
    """A round-capped stroke along a polyline, stamped as discs: Pillow's own
    wide lines break up on curves."""
    r = width / 2
    step = max(1.0, width / 8)
    for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
        n = max(1, int(((x1 - x0) ** 2 + (y1 - y0) ** 2) ** 0.5 / step))
        for i in range(n + 1):
            x = x0 + (x1 - x0) * i / n
            y = y0 + (y1 - y0) * i / n
            draw.ellipse((x - r, y - r, x + r, y + r), fill=fill)


def _on_lens(cx: float, degrees: float) -> tuple[float, float]:
    """A point on a lens's rim; 0° is to the right, 90° is up."""
    a = math.radians(degrees)
    return (cx + LENS_R * math.cos(a), LENS_Y - LENS_R * math.sin(a))


def draw_glyph(draw: ImageDraw.ImageDraw, origin: tuple[float, float], width: float,
               look: tuple[float, float] = (-math.sqrt(0.5), -math.sqrt(0.5)), fill=BLACK) -> None:
    ox, oy = origin

    def P(x, y):
        return (ox + x * width, oy + y * width)

    line = LINE * width
    left, right = 0.5 - LENS_DX, 0.5 + LENS_DX
    for cx in (left, right):
        x0, y0 = P(cx - LENS_R, LENS_Y - LENS_R)
        x1, y1 = P(cx + LENS_R, LENS_Y + LENS_R)
        draw.ellipse((x0, y0, x1, y1), outline=fill, width=int(round(line)))
        # Pupil, looking where `look` points (unit vector, y down).
        px, py = P(cx + look[0] * PUPIL_TRAVEL, LENS_Y + look[1] * PUPIL_TRAVEL)
        pr = PUPIL_R * width
        draw.ellipse((px - pr, py - pr, px + pr, py + pr), fill=fill)

    # Temple stubs leave each lens's outer rim, rising outwards.
    for cx, deg, side in ((left, 180 - TEMPLE_DEG, -1), (right, TEMPLE_DEG, 1)):
        sx, sy = _on_lens(cx, deg)
        _stroke(draw, [P(sx, sy), P(sx + side * TEMPLE[0], sy - TEMPLE[1])], line, fill)

    # Bridge, arching up between the lenses' inner rims.
    a = _on_lens(left, BRIDGE_DEG)
    b = _on_lens(right, 180 - BRIDGE_DEG)
    pts = _quad(P(*a), P(0.5, a[1] - 2 * BRIDGE_LIFT), P(*b))
    _stroke(draw, pts, line, fill)


def draw(size: int = 1024, scale: int = 4) -> Image.Image:
    s = size * scale
    canvas = Image.new("RGBA", (s, s), (0, 0, 0, 0))

    # Apple's grid: an 824-pt rounded square centered in 1024.
    inset = s * 100 / 1024
    box = (inset, inset, s - inset, s - inset)
    radius = s * 185 / 1024

    shadow = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        (box[0], box[1] + s * 0.012, box[2], box[3] + s * 0.012), radius, fill=(0, 0, 0, 110)
    )
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(s * 0.012)))

    tile = ImageDraw.Draw(canvas)
    tile.rounded_rectangle(box, radius, fill=(248, 249, 252, 255))
    # A hairline edge so the black tile still reads on a dark Dock.
    tile.rounded_rectangle(box, radius, outline=(0, 0, 0, 18), width=max(1, int(s * 0.002)))

    glyph_w = s * 0.66
    origin = ((s - glyph_w) / 2, (s - HEIGHT * glyph_w) / 2 + s * 0.01)
    draw_glyph(ImageDraw.Draw(canvas), origin, glyph_w)

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
    mark = Image.new("RGBA", (2048, 1024), (0, 0, 0, 0))
    draw_glyph(ImageDraw.Draw(mark), (64, (1024 - HEIGHT * 1920) / 2), 1920)
    mark.resize((1024, 512), Image.LANCZOS).save(out.parent / "BobbMark.png")


if __name__ == "__main__":
    main(Path(sys.argv[1] if len(sys.argv) > 1 else "LeonardApp/Resources/AppIcon.iconset"))
