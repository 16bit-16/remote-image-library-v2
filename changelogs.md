# v2.0.0 - 25 Nov 2026
## Changed (breaking):
- Ported to the Content-based EditableImage API. Images are created with `AssetService:CreateEditableImage` and written with `WritePixelsBuffer`.
- EditableImage can no longer be parented; use the new `apply(target, image)` or set a Content property with `Content.fromObject`.
- Client requests now receive 8-bit RGBA buffers instead of float tables.
- `builtin.paths` now matches the full path including the leading `/`.
- `_G.REMOTE_IMG_CUSTOM_GET` is now called as `(url, http_get_async)` and may return a string or buffer.

## Added:
- `apply(target, image)`.
- `create_image_from_array` accepts an RGBA buffer.
- `PNG:ToRGBABuffer()` in the bundled decoder.
- Clear errors for images over 1024x1024, interlaced PNGs and 1/2/4-bit PNGs.

## Fixed:
- HTTP failures no longer crash the queue or hang the caller.
- Queue rate now matches `HTTP_QUEUE_REQUESTS_PER_SEC`.
- Greyscale PNGs decoded as white.
- URL helpers erroring on malformed URLs; host/protocol checks are case-insensitive.
- Library functions leaking as globals.

# v1.0.2 - 02 Dec 2023
## Fixed:
- Fixed spelling mistake in readme.

# v1.0.1 - 02 Dec 2023
## Added:
- changelogs.md.

## Changed:
- Changed .luau extensions to .lua because of GITHUB HIGHLIGHTING!!!!!!

# v1.0.0 - 02 Dec 2023
## Added:
- The library.