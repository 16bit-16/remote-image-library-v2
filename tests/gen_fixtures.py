# Generates PNG fixtures and expected RGBA bytes for tests/run.luau.
# Run from tests/fixtures:  python3 ../gen_fixtures.py   (needs Pillow)
from PIL import Image
import random, json, zlib, struct

random.seed(1)
W, H = 7, 5
rgba = [(random.randrange(256), random.randrange(256), random.randrange(256), random.randrange(256)) for _ in range(W * H)]
cases = {}

def px(img):
    return list(img.getdata())

def save(name, img, expected, **kw):
    img.save(f"{name}.png", **kw)
    cases[name] = expected

im = Image.new("RGBA", (W, H)); im.putdata(rgba)
save("rgba8", im, [c for p in rgba for c in p])
rgb = im.convert("RGB"); save("rgb8", rgb, [c for p in px(rgb) for c in (*p, 255)])
L = im.convert("L"); save("gray8", L, [c for v in px(L) for c in (v, v, v, 255)])
LA = im.convert("LA"); save("graya8", LA, [c for (v, a) in px(LA) for c in (v, v, v, a)])
P = im.convert("RGB").quantize(8)
pal = P.getpalette()[:24]
trns = bytes([255, 0, 128, 64, 32, 200, 10, 99])
exp = []
for i in px(P):
    exp += [pal[i * 3], pal[i * 3 + 1], pal[i * 3 + 2], trns[i]]
save("palette8", P, exp, transparency=trns, bits=8)

def chunk(t, d):
    return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)

# 16-bit RGB, low bytes are noise; expected = high bytes.
raw = b"".join(
    b"\x00" + b"".join(struct.pack(">HHH", r * 256 + (255 - r), g * 256 + 7, b * 256) for (r, g, b, a) in rgba[y * W:(y + 1) * W])
    for y in range(H))
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 16, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")
open("rgb16.png", "wb").write(png)
cases["rgb16"] = [c for (r, g, b, a) in rgba for c in (r, g, b, 255)]

im.convert("1").save("bit1.png")
# Pillow can't write Adam7, so flag an RGBA PNG as interlaced (the decoder
# must reject it before touching the pixel data).
d = bytearray(open("rgba8.png", "rb").read())
d[28] = 1
d[29:33] = struct.pack(">I", zlib.crc32(bytes(d[12:29])) & 0xffffffff)
open("interlaced.png", "wb").write(d)
im.resize((1100, 4)).save("big.png")
json.dump(cases, open("expected.json", "w"))
