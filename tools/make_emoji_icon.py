"""Generate launcher icon by compositing the Twemoji banana 1f34c PNG
onto a soft-orange gradient background.

Source emoji PNG (CC BY 4.0 Twitter): tools/twemoji_banana_72.png
Output: assets/icons/icon_emoji.png  (1024x1024)
"""
import os
from PIL import Image, ImageDraw

HERE = os.path.dirname(__file__)
SRC = os.path.join(HERE, 'twemoji_banana_72.png')
OUT = os.path.join(HERE, '..', 'assets', 'icons', 'icon_emoji.png')

SIZE = 1024
RADIUS = 220
EMOJI_SIZE = 720

grad = Image.new('RGB', (SIZE, SIZE))
for y in range(SIZE):
    for x in range(SIZE):
        t = (x + y) / (2 * (SIZE - 1))
        r = int(0xFF * (1 - t) + 0xFF * t)
        g = int(0x70 * (1 - t) + 0xB1 * t)
        b = int(0x43 * (1 - t) + 0x99 * t)
        grad.putpixel((x, y), (r, g, b))

mask = Image.new('L', (SIZE, SIZE), 0)
md = ImageDraw.Draw(mask)
md.pieslice([0, 0, RADIUS * 2, RADIUS * 2], 180, 270, fill=255)
md.pieslice([SIZE - RADIUS * 2, 0, SIZE, RADIUS * 2], 270, 360, fill=255)
md.pieslice([0, SIZE - RADIUS * 2, RADIUS * 2, SIZE], 90, 180, fill=255)
md.pieslice([SIZE - RADIUS * 2, SIZE - RADIUS * 2, SIZE, SIZE], 0, 90, fill=255)
md.rectangle([RADIUS, 0, SIZE - RADIUS, SIZE], fill=255)
md.rectangle([0, RADIUS, SIZE, SIZE - RADIUS], fill=255)

bg = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
bg.paste(grad, mask=mask)

emoji = Image.open(SRC).convert('RGBA')
emoji = emoji.resize((EMOJI_SIZE, EMOJI_SIZE), Image.LANCZOS)
ex = (SIZE - EMOJI_SIZE) // 2
ey = (SIZE - EMOJI_SIZE) // 2
bg.paste(emoji, (ex, ey), emoji)

os.makedirs(os.path.dirname(OUT), exist_ok=True)
bg.save(OUT, format='PNG')
print('wrote', os.path.abspath(OUT))
