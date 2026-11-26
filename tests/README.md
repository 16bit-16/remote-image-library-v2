# Tests

Runs the library under [Lune](https://github.com/lune-org/lune) with mocked `AssetService`, `HttpService`, `RunService` and `Content`, so it checks the logic but not the real engine.

```bash
cd tests/fixtures
lune run ../run.luau ../../src
```

Covers PNG decoding (greyscale, greyscale+alpha, RGB, RGBA, palette+tRNS, 16-bit) against Pillow byte for byte, rejection of 1-bit/interlaced/oversized images, the HTTP queue (rate, failures, restart), the custom GET override, the builtin URL checks, `apply`, and the `serve` ↔ client round trip.

Regenerate fixtures with `python3 ../gen_fixtures.py` (needs Pillow).
