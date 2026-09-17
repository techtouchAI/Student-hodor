#!/usr/bin/env python3
"""Regenerate all Android launcher icons from the committed master artwork.

Source: assets/icon/app_icon_source.png (1024x1024, teal #0D6E5F background).
Outputs (all committed):
  - assets/icon/app_icon.png                      1024 master, bg normalized
  - mipmap-{mdpi,hdpi,xhdpi,xxhdpi,xxxhdpi}/       legacy square + round icons
  - drawable-{...}/ic_launcher_foreground.png      adaptive foreground (transparent)
  - drawable-{...}/ic_launcher_monochrome.png      Android 13+ themed icon (white)
  - values/icon_colors.xml                        adaptive background color

Run only when the icon artwork changes. Requires Pillow (pip install pillow).
Idempotent: re-running on an already-generated tree is a no-op.
"""

import math
import re
import sys
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    sys.exit("Pillow is required: pip install pillow")

ROOT = Path(__file__).resolve().parents[1]
RES = ROOT / "android" / "app" / "src" / "main" / "res"
MASTER = ROOT / "assets" / "icon" / "app_icon_source.png"
APP_ICON = ROOT / "assets" / "icon" / "app_icon.png"

# App primary (lib/app.dart seedColor, badge_spec.header): icon bg must match
# exactly so the adaptive foreground blends seamlessly with icon_colors.xml.
TEAL = (13, 110, 95)

MIPMAP = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}
DRAWABLE = {"mdpi": 108, "hdpi": 162, "xhdpi": 216, "xxhdpi": 324, "xxxhdpi": 432}

# Adaptive safe zone: artwork bbox is fitted inside this fraction of the
# 432px foreground canvas (guideline: keylines within the center 66dp circle).
SAFE_FIT = 0.63


def normalize_background(img: Image.Image) -> Image.Image:
    """Snap near-background pixels to exactly TEAL (kills generator noise so
    the matte and icon_colors.xml agree to the last bit)."""
    px = img.load()
    w, h = img.size
    for y in range(h):
        for x in range(w):
            r, g, b = px[x, y][:3]
            dist = math.sqrt(
                (r - TEAL[0]) ** 2 + (g - TEAL[1]) ** 2 + (b - TEAL[2]) ** 2
            )
            if dist <= 10:
                px[x, y] = TEAL if img.mode == "RGB" else TEAL + (255,)
    return img


def difference_matte(img: Image.Image) -> Image.Image:
    """Transparent-background RGBA of the artwork via difference matting
    against TEAL; soft edges (laser glow) keep smooth partial alpha."""
    rgb = img.convert("RGB")
    w, h = rgb.size
    out = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    src, dst = rgb.load(), out.load()
    for y in range(h):
        for x in range(w):
            r, g, b = src[x, y]
            dist = math.sqrt(
                (r - TEAL[0]) ** 2 + (g - TEAL[1]) ** 2 + (b - TEAL[2]) ** 2
            )
            alpha = int(max(0.0, min(1.0, (dist - 8) / 24)) * 255)
            if alpha:
                dst[x, y] = (r, g, b, alpha)
    return out


def circle_mask(size: int) -> Image.Image:
    """Antialiased inscribed-circle alpha mask (4x supersampled)."""
    big = size * 4
    m = Image.new("L", (big, big), 0)
    px = m.load()
    c, r = big / 2, big / 2
    for y in range(big):
        for x in range(big):
            if (x + 0.5 - c) ** 2 + (y + 0.5 - c) ** 2 <= r * r:
                px[x, y] = 255
    return m.resize((size, size), Image.LANCZOS)


def main() -> None:
    master = Image.open(MASTER).convert("RGB")
    if master.size != (1024, 1024):
        # Center-crop to square, then scale: generator output must never
        # stretch.
        side = min(master.size)
        left = (master.width - side) // 2
        top = (master.height - side) // 2
        master = master.crop((left, top, left + side, top + side))
        master = master.resize((1024, 1024), Image.LANCZOS)
    master = normalize_background(master)
    master.save(APP_ICON, optimize=True)
    master.save(MASTER)  # normalized master stays the single source of truth

    for density, size in MIPMAP.items():
        legacy = master.resize((size, size), Image.LANCZOS)
        legacy.save(RES / f"mipmap-{density}" / "ic_launcher.png")
        rounded = legacy.convert("RGBA")
        rounded.putalpha(circle_mask(size))
        rounded.save(RES / f"mipmap-{density}" / "ic_launcher_round.png")

    matte = difference_matte(master)
    # Size from the *white* artwork (brackets/barcode/student): the yellow
    # laser core and gold check would otherwise pollute the measured extent.
    # The full soft crop is still pasted, so glow edges stay smooth.
    rgb = master.load()
    minx, miny, maxx, maxy = 1024, 1024, 0, 0
    for y in range(1024):
        for x in range(1024):
            r, g, b = rgb[x, y]
            if min(r, g, b) > 150:
                if x < minx:
                    minx = x
                if x > maxx:
                    maxx = x
                if y < miny:
                    miny = y
                if y > maxy:
                    maxy = y
    assert maxx >= minx, "no artwork found in master"
    fit = int(432 * SAFE_FIT)
    scale = fit / max(maxx - minx + 1, maxy - miny + 1)
    bbox = matte.getbbox()
    assert bbox is not None
    pad = 8
    crop = matte.crop(
        (max(0, bbox[0] - pad), max(0, bbox[1] - pad),
         min(1024, bbox[2] + pad), min(1024, bbox[3] + pad))
    )
    crop = crop.resize(
        (max(1, round(crop.width * scale)), max(1, round(crop.height * scale))),
        Image.LANCZOS,
    )
    fg432 = Image.new("RGBA", (432, 432), (0, 0, 0, 0))
    fg432.paste(
        crop, ((432 - crop.width) // 2, (432 - crop.height) // 2), crop
    )

    for density, size in DRAWABLE.items():
        fg = fg432.resize((size, size), Image.LANCZOS)
        fg.save(RES / f"drawable-{density}" / "ic_launcher_foreground.png")
        # Themed icon: white silhouette, glow haze cut, edges kept smooth.
        alpha = fg.getchannel("A").point(
            lambda a: 0 if a < 40 else min(255, (a - 40) * 255 // 160)
        )
        mono = Image.merge("LA", (Image.new("L", fg.size, 255), alpha))
        mono.save(RES / f"drawable-{density}" / "ic_launcher_monochrome.png")

    colors_path = RES / "values" / "icon_colors.xml"
    hex_teal = "#{:02X}{:02X}{:02X}".format(*TEAL)
    text = colors_path.read_text(encoding="utf-8")
    start = text.index(">itu", 0) if False else None  # placeholder, unused
    # Surgical text replacement: keep the file's original formatting intact.
    import re

    new_text, count = re.subn(
        r'(<color name="ic_launcher_background">)#[0-9A-Fa-f]{6}(</color>)',
        rf"\g<1>{hex_teal}\g<2>",
        text,
    )
    assert count == 1, f"expected 1 background color entry, found {count}"
    colors_path.write_text(new_text, encoding="utf-8")

    print(f"icon rebuilt from {MASTER.name}, background {hex_teal}")


if __name__ == "__main__":
    sys.exit(main())
