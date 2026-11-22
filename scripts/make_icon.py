"""Draws Skyfi/Assets.xcassets/AppIcon.appiconset/icon-1024.png: an amber wireframe globe at night with a cyan flight arc."""

import math
import os

from PIL import Image, ImageDraw, ImageFilter

S = 1024
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "Skyfi", "Assets.xcassets", "AppIcon.appiconset", "icon-1024.png")
AMBER = (255, 181, 71)
CYAN = (90, 209, 255)


def main():
    img = Image.new("RGB", (S, S))
    px = img.load()
    for y in range(S):
        for x in range(S):
            d = math.hypot(x - S * 0.5, y - S * 0.42) / (S * 0.75)
            t = min(d, 1)
            px[x, y] = (int(22 - 14 * t), int(30 - 18 * t), int(46 - 26 * t))

    layer = Image.new("RGBA", (S * 2, S * 2), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    cx, cy, r = S, S * 1.04, S * 0.66
    w = 10
    d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=AMBER + (255,), width=w + 4)
    for k in (0.35, 0.7):
        rx = r * k
        d.ellipse([cx - rx, cy - r, cx + rx, cy + r], outline=AMBER + (170,), width=w)
    d.line([cx, cy - r, cx, cy + r], fill=AMBER + (170,), width=w)
    for lat in (-50, -20, 20, 50):
        yy = cy - r * math.sin(math.radians(lat))
        half = r * math.cos(math.radians(lat))
        d.line([cx - half, yy, cx + half, yy], fill=AMBER + (150,), width=w)
    d.line([cx - r, cy, cx + r, cy], fill=AMBER + (190,), width=w)

    # Flight arc and plane.
    arc_box = [cx - r * 1.25, cy - r * 1.05, cx + r * 1.05, cy + r * 1.45]
    d.arc(arc_box, start=200, end=318, fill=CYAN + (255,), width=w + 2)
    a = math.radians(318)
    ax = (arc_box[0] + arc_box[2]) / 2 + (arc_box[2] - arc_box[0]) / 2 * math.cos(a)
    ay = (arc_box[1] + arc_box[3]) / 2 + (arc_box[3] - arc_box[1]) / 2 * math.sin(a)
    heading = a + math.pi / 2
    def rot(px_, py_):
        return (ax + px_ * math.cos(heading) - py_ * math.sin(heading),
                ay + px_ * math.sin(heading) + py_ * math.cos(heading))
    u = 34
    plane = [(3.2, 0), (1.0, 0.35), (0.2, 2.6), (-0.4, 2.6), (0.0, 0.4), (-1.7, 0.35), (-2.3, 1.2),
             (-2.7, 1.2), (-2.3, 0), (-2.7, -1.2), (-2.3, -1.2), (-1.7, -0.35), (0.0, -0.4), (-0.4, -2.6),
             (0.2, -2.6), (1.0, -0.35)]
    d.polygon([rot(x * u, y * u) for x, y in plane], fill=(255, 255, 255, 255))

    glow = layer.filter(ImageFilter.GaussianBlur(18))
    base = img.convert("RGBA").resize((S * 2, S * 2))
    base.alpha_composite(glow)
    base.alpha_composite(layer)
    base.resize((S, S), Image.LANCZOS).convert("RGB").save(OUT)
    print("wrote", os.path.relpath(OUT, ROOT))


if __name__ == "__main__":
    main()
