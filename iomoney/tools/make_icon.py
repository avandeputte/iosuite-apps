# Draws the ioMoney icon: three coins in a stack, the top one gold, under a rising line, on warm amber, without a
# wordmark (like the other ioThing app icons). A square, opaque 1024 px tile: iOS rounds the corners itself.
#   python3 tools/make_icon.py iOS/Assets.xcassets/AppIcon.appiconset/icon-1024.png
import sys
from PIL import Image, ImageDraw, ImageFilter

S = 2048  # drawn at 2x, then downsampled
k = S / 1024

GOLD = (246, 207, 114, 255)          # the same gold as ioPix and ioNote
GOLD_DARK = (214, 168, 70, 255)
AMBER_DARK = (104, 68, 6, 255)
AMBER_LIGHT = (178, 128, 22, 255)    # around ioMoney's own colour, #94650a
CREAM = (253, 250, 242, 255)
SHADE = (226, 216, 190, 255)


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(len(a)))


def gradient(c1, c2):
    g = Image.new("RGBA", (256, 256))
    px = g.load()
    for y in range(256):
        for x in range(256):
            px[x, y] = lerp(c1, c2, (x * 0.45 + (255 - y) * 0.55) / 255)
    return g.resize((S, S), Image.BICUBIC)


def box(cx, cy, w, h):
    return [(cx - w / 2) * k, (cy - h / 2) * k, (cx + w / 2) * k, (cy + h / 2) * k]


tile = gradient(AMBER_DARK, AMBER_LIGHT)
glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(glow).ellipse(box(512, 560, 660, 560), fill=(255, 226, 150, 70))
tile.alpha_composite(glow.filter(ImageFilter.GaussianBlur(90 * k)))

shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
sd = ImageDraw.Draw(shadow)
art = Image.new("RGBA", (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(art)


def coin(cy, face, edge):
    """A coin seen from a little above: its edge, then its face."""
    w, h, thick = 470, 150, 64
    sd.ellipse(box(512, cy + thick + 16, w, h), fill=(0, 0, 0, 80))
    d.ellipse(box(512, cy + thick, w, h), fill=edge)
    d.rectangle([(512 - w / 2) * k, cy * k, (512 + w / 2) * k, (cy + thick) * k], fill=edge)
    d.ellipse(box(512, cy, w, h), fill=face)
    d.ellipse(box(512, cy, w - 70, h - 34), outline=edge, width=int(7 * k))


coin(720, CREAM, SHADE)
coin(620, CREAM, SHADE)
coin(520, GOLD, GOLD_DARK)

# the rising line, with its arrowhead
pts = [(250, 400), (410, 300), (530, 350), (760, 190)]
line = [(x * k, y * k) for x, y in pts]
sd.line([(x, y + 14 * k) for x, y in line], fill=(0, 0, 0, 80), width=int(34 * k), joint="curve")
d.line(line, fill=CREAM, width=int(34 * k), joint="curve")
for x, y in line[:-1]:
    d.ellipse([x - 17 * k, y - 17 * k, x + 17 * k, y + 17 * k], fill=CREAM)
d.polygon([(800 * k, 160 * k), (690 * k, 176 * k), (776 * k, 268 * k)], fill=CREAM)

tile.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(16 * k)))
tile.alpha_composite(art)
tile.convert("RGB").resize((1024, 1024), Image.LANCZOS).save(sys.argv[1])
