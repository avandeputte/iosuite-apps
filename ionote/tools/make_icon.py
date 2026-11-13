# Draws the ionote icon: a clipped note card with a gold-highlighted line on deep teal, without a wordmark
# (like the other ioThing app icons). python3 tools/make_icon.py out.png [--ios]
# --ios: a square, opaque 1024 px tile for iPhone and iPad (iOS rounds the corners itself).
import sys, math
from PIL import Image, ImageDraw, ImageFilter

S = 2048  # drawn at 2x, then downsampled
k = S / 1024
IOS = "--ios" in sys.argv
sys.argv = [a for a in sys.argv if a != "--ios"]

GOLD = (246, 207, 114, 255)          # same gold as iopix
TEAL_DARK = (18, 72, 78, 255)
TEAL_LIGHT = (38, 128, 122, 255)
PAPER_TOP = (253, 250, 242, 255)
PAPER_BOT = (241, 235, 220, 255)
INK = (120, 150, 150, 255)
CLIP = (30, 52, 60, 255)


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(len(a)))


def linear_gradient(size, c1, c2, angle_deg):
    w, h = size
    g = Image.new("RGBA", size)
    px = g.load()
    a = math.radians(angle_deg)
    dx, dy = math.cos(a), math.sin(a)
    span = abs(w * dx) + abs(h * dy)
    for y in range(h):
        for x in range(w):
            px[x, y] = lerp(c1, c2, max(0, min(1, (x * dx + y * dy) / span)))
    return g


def vgrad(size, c1, c2):
    w, h = size
    g = Image.new("RGBA", (1, h))
    for y in range(h):
        g.putpixel((0, y), lerp(c1, c2, y / max(1, h - 1)))
    return g.resize((w, h))


def rounded_mask(size, box, r):
    m = Image.new("L", size, 0)
    ImageDraw.Draw(m).rounded_rectangle(box, r, fill=255)
    return m


tile = Image.new("RGBA", (S, S), (0, 0, 0, 0))
tile.alpha_composite(linear_gradient((256, 256), TEAL_DARK, TEAL_LIGHT, 55).resize((S, S), Image.BICUBIC))

# soft glow behind the card
glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(glow).ellipse([260 * k, 232 * k, 780 * k, 752 * k], fill=(120, 210, 190, 70))
tile.alpha_composite(glow.filter(ImageFilter.GaussianBlur(90 * k)))

# the note card, drawn upright then tilted
W, H = int(480 * k), int(470 * k)
card = Image.new("RGBA", (W, H), (0, 0, 0, 0))
fold = int(92 * k)
paper = vgrad((W, H), PAPER_TOP, PAPER_BOT)
pm = Image.new("L", (W, H), 0)
pd = ImageDraw.Draw(pm)
pd.rounded_rectangle([0, 0, W - 1, H - 1], int(34 * k), fill=255)
pd.polygon([(W - fold, H), (W, H - fold), (W, H)], fill=0)        # cut the corner
pd.rectangle([W - fold + 10, H - 40, W, H], fill=0)
pd.polygon([(W - fold, H - 1), (W - 1, H - fold), (W - 1, H - 1)], fill=0)
card.paste(paper, (0, 0), pm)
d = ImageDraw.Draw(card)
# folded corner
d.polygon([(W - fold, H - 1), (W - fold, H - fold), (W - 1, H - fold)], fill=(224, 214, 188, 255))
d.line([(W - fold, H - 1), (W - 1, H - fold)], fill=(205, 194, 166, 255), width=int(3 * k))
# text lines; the second one highlighted in gold, the way you'd mark the bit worth keeping
lh = int(20 * k)
rows = [(70, 380), (70, 330), (70, 360), (70, 250)]
for i, (x1, x2) in enumerate(rows):
    y = int((150 + i * 70) * k)
    if i == 1:
        d.rounded_rectangle([int((x1 - 18) * k), y - int(22 * k), int((x2 + 22) * k), y + lh + int(22 * k)],
                            int(16 * k), fill=GOLD)
    d.rounded_rectangle([int(x1 * k), y, int(x2 * k), y + lh], lh // 2,
                        fill=(92, 112, 108, 255) if i == 1 else INK)
card = card.rotate(-6, resample=Image.BICUBIC, expand=True)

cx, cy = 512 * k, 530 * k  # the card and its clip, centred in the tile
pos = (int(cx - card.size[0] / 2), int(cy - card.size[1] / 2))
shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
alpha = card.split()[3].point(lambda a: int(a * 0.45))
shadow.paste((5, 30, 34, 255), (pos[0] + int(10 * k), pos[1] + int(26 * k)), alpha)
tile.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(26 * k)))
tile.alpha_composite(card, pos)

# a clip at the top of the card: this note came off the clipboard
d = ImageDraw.Draw(tile)
clip_cx, clip_top = cx - 18 * k, cy - 268 * k
d.rounded_rectangle([clip_cx - 92 * k, clip_top + 18 * k, clip_cx + 92 * k, clip_top + 92 * k], int(22 * k), fill=CLIP)
d.rounded_rectangle([clip_cx - 50 * k, clip_top - 14 * k, clip_cx + 50 * k, clip_top + 44 * k], int(28 * k), outline=CLIP, width=int(18 * k))
d.rounded_rectangle([clip_cx - 70 * k, clip_top + 36 * k, clip_cx + 70 * k, clip_top + 48 * k], int(6 * k), fill=(70, 100, 108, 255))

if IOS:
    box = [int(100 * k), int(100 * k), int(924 * k), int(924 * k)]
    tile.crop(box).resize((1024, 1024), Image.LANCZOS).convert("RGB").save(sys.argv[1])
    sys.exit()

out = Image.new("RGBA", (S, S), (0, 0, 0, 0))
out.paste(tile, (0, 0), rounded_mask((S, S), [int(100 * k), int(100 * k), int(924 * k), int(924 * k)], int(185 * k)))
out.resize((1024, 1024), Image.LANCZOS).save(sys.argv[1])
