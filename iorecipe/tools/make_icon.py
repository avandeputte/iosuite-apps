# Draws the ioRecipe icon: a plate with a gold rim line between a fork and a knife on green, without a wordmark (like
# the other ioThing app icons). A square, opaque 1024 px tile: iOS rounds the corners itself.
#   python3 tools/make_icon.py iOS/Assets.xcassets/AppIcon.appiconset/icon-1024.png
import sys
from PIL import Image, ImageDraw, ImageFilter

S = 2048  # drawn at 2x, then downsampled
k = S / 1024

GOLD = (246, 207, 114, 255)          # the same gold as ioPix and ioNote
GREEN_DARK = (44, 84, 22, 255)
GREEN_LIGHT = (98, 150, 50, 255)     # around ioRecipe's own green, #4a7c23
CREAM = (253, 250, 242, 255)
SHADE = (232, 226, 208, 255)


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


tile = gradient(GREEN_DARK, GREEN_LIGHT)

glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(glow).ellipse(box(512, 512, 640, 640), fill=(190, 230, 140, 80))
tile.alpha_composite(glow.filter(ImageFilter.GaussianBlur(90 * k)))

shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
sd = ImageDraw.Draw(shadow)
art = Image.new("RGBA", (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(art)


def both(draw):
    draw(sd, (0, 0, 0, 90), 14)
    draw(d, None, 0)


# the plate
both(lambda dr, c, off: dr.ellipse(box(512, 512 + off, 500, 500), fill=c or CREAM))
d.ellipse(box(512, 512, 372, 372), fill=SHADE)
d.ellipse(box(512, 512, 352, 352), fill=CREAM)
d.ellipse(box(512, 512, 430, 430), outline=GOLD, width=int(9 * k))

# the fork, left
def fork(dr, c, off):
    c = c or CREAM
    for x in (150, 186, 222):
        dr.rounded_rectangle(box(x, 330 + off, 20, 200), 10 * k, fill=c)
    dr.rounded_rectangle(box(186, 440 + off, 92, 70), 30 * k, fill=c)
    dr.rounded_rectangle(box(186, 630 + off, 34, 360), 17 * k, fill=c)


# the knife, right
def knife(dr, c, off):
    c = c or CREAM
    dr.pieslice([790 * k, (230 + off) * k, 930 * k, (760 + off) * k], 90, 270, fill=c)
    dr.rounded_rectangle(box(843, 660 + off, 34, 300), 17 * k, fill=c)


both(fork)
both(knife)

tile.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(16 * k)))
tile.alpha_composite(art)
tile.convert("RGB").resize((1024, 1024), Image.LANCZOS).save(sys.argv[1])
