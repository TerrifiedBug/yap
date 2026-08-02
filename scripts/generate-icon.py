#!/usr/bin/env python3
"""Regenerate packaging/yap.icns and packaging/yap.png.

    pip install pillow cairosvg
    python3 scripts/generate-icon.py

Run this rather than editing the binaries: they are output, and without the
source here the icon could be replaced but never adjusted.

Two marks, not one scaled. The outlined glyph — the same Lucide `speech` the
menu bar uses, see Sources/yap/UI/StatusIcon.swift — is right from 128 px up.
By 32 px the head interior is about three pixels across and it collapses into
a white smudge, so the small sizes get a solid filled bust instead. Apple
redraws small sizes for the same reason.

Every constant below was chosen by rendering it and looking, not by taste:
graphite because the coloured options read as consumer apps beside a menu-bar
utility, 48% because 44% looks timid and 52% crowds the corners, and the
solid/outline boundary above 64 because 64 was visibly thin as an outline
between a solid 32 and a clean 128.
"""
import io
import pathlib
import shutil
import subprocess
import sys

try:
    import cairosvg
    from PIL import Image, ImageDraw, ImageFilter
except ImportError:
    sys.exit("needs pillow and cairosvg: pip install pillow cairosvg")

ROOT = pathlib.Path(__file__).resolve().parent.parent
PACKAGING = ROOT / "packaging"

TOP, BOTTOM = (0x4A, 0x4E, 0x54), (0x24, 0x27, 0x2B)

# 128 px and up. Kept identical to the menu-bar mark.
OUTLINE = """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none"
 stroke="#FFFFFF" stroke-width="{sw}" stroke-linecap="round" stroke-linejoin="round">
<path d="M8.8 20v-4.1l1.9.2a2.3 2.3 0 0 0 2.164-2.1V8.3A5.37 5.37 0 0 0 2 8.25c0 2.8.656
 3.054 1 4.55a5.77 5.77 0 0 1 .029 2.758L2 20"/>
<path d="M19.8 17.8a7.5 7.5 0 0 0 .003-10.603"/>
<path d="M17 15a3.5 3.5 0 0 0-.025-4.975"/>
</svg>"""

# 64 px and below. Same idea, drawn as mass so it survives.
SOLID = """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none"
 stroke="#FFFFFF" stroke-width="{sw}" stroke-linecap="round">
<circle cx="8.5" cy="7" r="3.6" fill="#FFFFFF" stroke="none"/>
<path d="M2.6 20.5v-1.2A5.9 5.9 0 0 1 8.5 13.4a5.9 5.9 0 0 1 5.9 5.9v1.2z"
 fill="#FFFFFF" stroke="none"/>
<path d="M17.6 9.4a4.6 4.6 0 0 1 0 5.2"/>
<path d="M21 6.8a9 9 0 0 1 0 10.4"/>
</svg>"""

# px: (svg, ink width as a fraction of the tile, stroke width)
TUNING = [
    (16, SOLID, 0.62, "2.6"),
    (32, SOLID, 0.68, "3.0"),
    (64, SOLID, 0.64, "2.6"),
    (128, OUTLINE, 0.50, "1.8"),
    (10_000, OUTLINE, 0.48, "1.6"),
]


def squircle(size):
    """macOS Big Sur+ tile. Apple's shape is a superellipse; a rounded rect at
    22.37% radius is the usual approximation, drawn 4x and downsampled so the
    curve is not stair-stepped."""
    mask = Image.new("L", (size * 4, size * 4), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, size * 4 - 1, size * 4 - 1], radius=int(size * 4 * 0.2237), fill=255
    )
    return mask.resize((size, size), Image.LANCZOS)


def gradient(size):
    strip = Image.new("RGB", (1, size))
    for y in range(size):
        t = y / (size - 1) if size > 1 else 0
        strip.putpixel((0, y), tuple(int(TOP[i] + (BOTTOM[i] - TOP[i]) * t) for i in range(3)))
    return strip.resize((size, size), Image.BICUBIC)


def glyph(svg, px, stroke):
    png = cairosvg.svg2png(
        bytestring=svg.format(sw=stroke).encode(), output_width=px, output_height=px
    )
    return Image.open(io.BytesIO(png)).convert("RGBA")


def tile(size):
    svg, frac, stroke = next((s, f, w) for px, s, f, w in TUNING if size <= px)
    icon = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    icon.paste(gradient(size), (0, 0), squircle(size))

    # Centre the ink, not the artboard: the sound waves hang off one side, so
    # centring the 24x24 viewBox leaves the mark visibly left of centre.
    probe = glyph(svg, size * 4, stroke)
    box = probe.getchannel("A").getbbox()
    scale = (size * frac) / ((box[2] - box[0]) / 4)
    mark = glyph(svg, max(8, int(size * scale)), stroke)
    mark = mark.crop(mark.getchannel("A").getbbox())

    x, y = (size - mark.width) // 2, (size - mark.height) // 2
    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    shadow.paste(mark, (x, y + max(1, size // 200)), mark)
    shadow = shadow.filter(ImageFilter.GaussianBlur(max(1, size // 110)))
    shadow.putalpha(shadow.getchannel("A").point(lambda v: int(v * 0.28)))
    icon = Image.alpha_composite(icon, shadow)
    icon.paste(mark, (x, y), mark)
    return icon


def main():
    iconset = PACKAGING / "yap.iconset"
    if iconset.exists():
        shutil.rmtree(iconset)
    iconset.mkdir(parents=True)

    # The names iconutil expects; anything else is silently ignored.
    for point in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            suffix = "" if scale == 1 else "@2x"
            tile(point * scale).save(iconset / f"icon_{point}x{point}{suffix}.png")

    subprocess.run(
        ["iconutil", "-c", "icns", str(iconset), "-o", str(PACKAGING / "yap.icns")],
        check=True,
    )
    # 256 px for the readme; .icns does not render on GitHub.
    tile(256).save(PACKAGING / "yap.png", optimize=True)
    shutil.rmtree(iconset)
    print(f"wrote {PACKAGING/'yap.icns'} and {PACKAGING/'yap.png'}")


if __name__ == "__main__":
    main()
