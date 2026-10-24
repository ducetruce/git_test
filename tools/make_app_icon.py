"""Draws the app icon (1024x1024, full-bleed; iOS applies the rounded mask).

    pip install Pillow
    python3 tools/make_app_icon.py App/NarwalLocal/Assets.xcassets/AppIcon.appiconset/AppIcon.png

A top-down robot vacuum in white on a blue-to-teal gradient, with a small
house in the lidar turret: local, at home, no cloud.
"""

import sys

from PIL import Image, ImageDraw, ImageFilter

S = 1024
SS = 4  # supersampling for smooth edges


def lerp(a, b, t):
    return tuple(round(x + (y - x) * t) for x, y in zip(a, b))


def main(out: str) -> None:
    n = S * SS
    top, bottom = (31, 99, 222), (18, 186, 196)
    gradient = Image.new("RGB", (1, n))
    for y in range(n):
        gradient.putpixel((0, y), lerp(top, bottom, y / (n - 1)))
    img = gradient.resize((n, n))
    d = ImageDraw.Draw(img)
    cx, cy, r = n // 2, n // 2 + 20 * SS, 330 * SS

    # Soft shadow under the robot.
    shadow = Image.new("L", (n, n), 0)
    ImageDraw.Draw(shadow).ellipse((cx - r, cy - r + 28 * SS, cx + r, cy + r + 28 * SS), fill=90)
    shadow = shadow.filter(ImageFilter.GaussianBlur(30 * SS))
    img.paste((10, 40, 90), (0, 0), shadow)
    d = ImageDraw.Draw(img)

    # Body, bumper line and turret.
    d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=(255, 255, 255))
    br = r - 46 * SS
    d.arc((cx - br, cy - br, cx + br, cy + br), start=200, end=340, fill=(205, 222, 240), width=14 * SS)
    tr = 112 * SS
    ty = cy - 120 * SS
    d.ellipse((cx - tr, ty - tr, cx + tr, ty + tr), fill=(31, 99, 222))

    # House glyph inside the turret.
    hw, hh = 62 * SS, 46 * SS
    roof_top = ty - 58 * SS
    d.polygon([(cx, roof_top), (cx + hw + 14 * SS, ty - 6 * SS), (cx - hw - 14 * SS, ty - 6 * SS)],
              fill=(255, 255, 255))
    d.rectangle((cx - hw, ty - 8 * SS, cx + hw, ty + hh), fill=(255, 255, 255))
    d.rectangle((cx - 16 * SS, ty + 6 * SS, cx + 16 * SS, ty + hh), fill=(31, 99, 222))

    # Side brushes hint: two small dots at the front.
    for dx in (-215, 215):
        x, y = cx + dx * SS, cy + 150 * SS
        d.ellipse((x - 26 * SS, y - 26 * SS, x + 26 * SS, y + 26 * SS), fill=(18, 186, 196))

    img.resize((S, S), Image.LANCZOS).save(out)
    print("wrote", out)


if __name__ == "__main__":
    main(sys.argv[1])
