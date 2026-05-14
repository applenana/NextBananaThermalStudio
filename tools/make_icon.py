"""Convert user-provided PNG to Windows multi-size ICO."""
import os
from PIL import Image

SRC = r'D:\Github_project\flutterThermalHub\assets\icons\icon.png'
OUT = r'D:\Github_project\flutterThermalHub\windows\runner\resources\app_icon.ico'
SIZES = [256, 128, 64, 48, 32, 16]

src = Image.open(SRC).convert('RGBA')
bbox = src.getbbox()
if bbox:
    src = src.crop(bbox)
w, h = src.size
side = max(w, h)
canvas = Image.new('RGBA', (side, side), (0, 0, 0, 0))
canvas.paste(src, ((side - w)//2, (side - h)//2))

images = [canvas.resize((s, s), Image.LANCZOS) for s in SIZES]
images[0].save(OUT, format='ICO', sizes=[(s, s) for s in SIZES], append_images=images[1:])
print('wrote', OUT)
