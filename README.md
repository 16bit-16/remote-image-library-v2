# Remote Image Library v2

> Fork of [plainenglishh/remote-image-library](https://github.com/plainenglishh/remote-image-library) (MIT), ported to the current EditableImage API.

Remote Image Library is a Luau library that creates `EditableImage`s from PNG files loaded from remote URLs, binary strings and pixel data.

**v2** targets the current EditableImage API: images are created with `AssetService:CreateEditableImage` and shown through Content properties (`ImageLabel.ImageContent`, `MeshPart.TextureContent`, `Decal.TextureContent`, ...). EditableImage is no longer an Instance, so v1's `image.Parent = decal` no longer works. Use `remote_img.apply(target, image)` instead. See [Migrating from v1](#migrating-from-v1).

### Table of Contents
- [1. Features](#1-features)
- [2. Requirements & Limits](#2-requirements--limits)
- [3. Usage](#3-usage)
- [4. Migrating from v1](#migrating-from-v1)
- [5. Installation](#5-installation)
- [6. API Reference](#6-api-reference)
- [7. Attributions](#7-attributions)

## 1. Features
- Load PNGs from URLs, binary strings/buffers, or raw RGBA pixel data.
- Queued HTTP requests to stay under rate limits.
- Optional `http_get_async` override for your own proxy/cache.
- Client usage with server-side authorisation. Pixels cross the remote as a compact `buffer`.

## 2. Requirements & Limits

> [!WARNING]
> This library was created as a demonstration. It is your responsibility to make sure your use complies with Roblox's Terms of Use.

- **EditableImage must be enabled for published experiences.** It fails by default; the experience owner must be 13+ and ID-verified, then enable it in Game Settings. It works in Studio regardless.
- **HttpService must be enabled** (Game Settings → Security → Allow HTTP Requests).
- EditableImages are **not replicated**. An image created on the server is only visible on the server. To show an image to players, create it on the client via `serve()` + client `create_image`.
- Maximum size is **1024×1024**.
- PNG only: 8-bit or 16-bit (16-bit is reduced to 8-bit), non-interlaced. Colour types: greyscale, greyscale+alpha, RGB, RGBA, 8-bit palette (with `tRNS` transparency). Bit depths 1/2/4 and interlaced (Adam7) files are rejected with an error.
- Decoding is done in pure Luau and is not fast. Prefer small images.

## 3. Usage

### 3.1. Client (recommended: players can see the image)
```lua
-- SERVER
local remote_img = require(path.to.remote_img)

remote_img.serve(function(player: Player, url: string)
	return remote_img.builtin.protocols(url, { "https" })
		and remote_img.builtin.hosts(url, { "i.imgur.com" })
end)

-- CLIENT (LocalScript)
local remote_img = require(path.to.remote_img)

local image = remote_img.create_image("https://i.imgur.com/eX24dFX.png")
remote_img.apply(script.Parent.ImageLabel, image)
```

### 3.2. Server
```lua
local remote_img = require(path.to.remote_img)

local image = remote_img.create_image("https://i.imgur.com/eX24dFX.png")
remote_img.apply(workspace.SpawnLocation.Decal, image)
```

### 3.3. Without `apply`
`apply` just sets the right Content property. You can do it yourself for any property that accepts an image:
```lua
image_label.ImageContent = Content.fromObject(image)
```

### 3.4. Overriding the HTTP GET
Set `_G.REMOTE_IMG_CUSTOM_GET` to a function. It receives the URL and the built-in queued `http_get_async`, and must return the PNG as a string or buffer.
```lua
_G.REMOTE_IMG_CUSTOM_GET = function(url: string, http_get_async: (string) -> string): string
	print(url, "requested.")
	return http_get_async("https://my-proxy.example.com/?url=" .. game:GetService("HttpService"):UrlEncode(url))
end
```

## Migrating from v1
| v1 | v2 |
| --- | --- |
| `image.Parent = decal` | `remote_img.apply(decal, image)` or `decal.TextureContent = Content.fromObject(image)` |
| `Instance.new("EditableImage")` internally | `AssetService:CreateEditableImage` |
| Pixel table of `0-1` floats over the remote | 8-bit RGBA `buffer` over the remote |
| `builtin.paths(url, {"eX24dFX.png"})` | `builtin.paths(url, {"/eX24dFX.png"})` (path now includes the leading `/`) |
| `_G.REMOTE_IMG_CUSTOM_GET` was not actually called | It is called as `(url, http_get_async)` |

`create_image_from_array` still accepts the v1 table of `0-1` floats, and now also accepts an 8-bit RGBA `buffer`.

### Bugs fixed in v2
- A failed HTTP request crashed the queue worker, and the calling thread waited forever.
- The queue waited 2 seconds between requests. `HTTP_QUEUE_REQUESTS_PER_SEC = 2` now means 2 per second.
- `_G.REMOTE_IMG_CUSTOM_GET` was used as the response body instead of being called.
- `builtin.paths` compared an off-by-one substring. `builtin.hosts`/`protocols` errored on URLs without `://` and were case-sensitive.
- Greyscale PNGs were decoded as white (`Color3.fromHSV` was given 0-255 instead of 0-1).
- Library functions leaked as globals.

## 5. Installation

### 5.1. Prebuilt model
Insert `remote_img.rbxmx` into `ReplicatedStorage` so both server and client can require it.

### 5.2. Rojo
Copy `./src` into your project, or build the model:
```bash
git clone https://github.com/16bit-16/remote-image-library-v2.git
cd remote-image-library-v2
rojo build -o remote_img.rbxmx
# or, without Rojo:
lune run scripts/build.luau
```

### 5.3. Running the tests
See [tests/README.md](tests/README.md).

## 6. API Reference

### create_image
```lua
create_image(url: string): EditableImage
```
Fetches and decodes the PNG at `url`. On the server it fetches directly. On the client it asks the server (which must have called `serve`) and builds the image locally. Errors if the request fails, is unauthorised, or the PNG is unsupported.

### create_image_from_string
```lua
create_image_from_string(data: string | buffer): EditableImage
```
Decodes PNG bytes.

### create_image_from_array
```lua
create_image_from_array(pixels: buffer | { number }, width: number, height: number): EditableImage
```
- `buffer`: tightly packed 8-bit RGBA, exactly `width * height * 4` bytes.
- `{ number }`: flat RGBA floats in `0-1` (v1 format).
```lua
local red = buffer.create(2 * 2 * 4)
for i = 0, 3 do
	buffer.writeu32(red, i * 4, 0xFF0000FF) -- little-endian: R=FF G=00 B=00 A=FF
end
local image = remote_img.create_image_from_array(red, 2, 2)
```

### apply
```lua
apply(target: Instance, image: EditableImage): ()
```
Sets `ImageContent` (ImageLabel, ImageButton) or `TextureContent` (MeshPart, Decal, Texture) to `Content.fromObject(image)`. Errors for other classes.

### serve
```lua
serve(auth: ((Player, string) -> boolean)?): ()
```
Server only. Lets clients call `create_image`. `auth` is called with the requesting player and URL; return `true` to allow. With no `auth`, all requests are allowed and a warning is printed (pass `builtin.allow_all` to silence it).

### builtin.protocols / hosts / paths / user_ids / allow_all
```lua
builtin.protocols(url: string, protocols: { string }): boolean -- {"https"}
builtin.hosts(url: string, hosts: { string }): boolean         -- exact host incl. subdomain, case-insensitive: {"i.imgur.com"}
builtin.paths(url: string, paths: { string }): boolean         -- path incl. leading "/" and query: {"/eX24dFX.png"}
builtin.user_ids(player: Player, user_ids: { number }): boolean
builtin.allow_all(): boolean
```

### http_get_async
```lua
http_get_async(url: string): string
```
Server only. Queued `HttpService:GetAsync`. Returns the body or errors in the calling thread.

## 7. Attributions
PNG decoding uses MaximumADHD's [Roblox-PNG-Library](https://github.com/MaximumADHD/Roblox-PNG-Library) (MIT), with small fixes for v2.
