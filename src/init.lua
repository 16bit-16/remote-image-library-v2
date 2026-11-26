--------------------------------------------------------------------------------
--
-- Remote-Image-Library (./init.lua)
--
-- plainenglish
-- December 2023 (v1), ported to the Content-based EditableImage API (v2)
--
-- A library to create an EditableImage from a remote PNG url.
-- Utilises MaximumADHD's Roblox-PNG-Library to parse the png data, packed into
-- a single file for simplicity's sake.
-- (https://github.com/MaximumADHD/Roblox-PNG-Library/tree/master)
--
-- v2 notes:
--   * EditableImage is no longer an Instance. It is created with
--     AssetService:CreateEditableImage and displayed through Content
--     properties (ImageLabel.ImageContent, MeshPart.TextureContent, ...).
--     Use `apply(target, image)` instead of `image.Parent = target`.
--   * Pixels are moved as an 8-bit RGBA buffer (WritePixelsBuffer), including
--     over the client remote, instead of a giant table of floats.
--
--------------------------------------------------------------------------------

local VERSION = "v2.0.0"
local HTTP_QUEUE_REQUESTS_PER_SEC = 2
local MAX_SIZE = 1024
local PRINT_LEADER = "[Remote-Image-Library]: "

local asset_service = game:GetService("AssetService")
local http_service = game:GetService("HttpService")
local run_service = game:GetService("RunService")

local png = require(script.png)
export type png = typeof(png.new(""))

local is_server = run_service:IsServer()
local builtin = {}

-- Which Content property shows an image, per class.
local CONTENT_PROPERTY = {
	ImageLabel = "ImageContent",
	ImageButton = "ImageContent",
	MeshPart = "TextureContent",
	Decal = "TextureContent",
	Texture = "TextureContent",
}

--------------------------------------------------------------------------------
--
-- http_get_async
--
-- Performs a queued HTTP GET, yielding until it completes.
-- Returns the response body, or errors in the calling thread on failure.
--
--------------------------------------------------------------------------------
local http_queue: { { url: string, thread: thread } } = {}
local queue_active = false

local function run_queue()
	while #http_queue > 0 do
		local req = table.remove(http_queue, 1)

		local success, res = pcall(http_service.GetAsync, http_service, req.url)
		task.spawn(req.thread, success, res)

		task.wait(1 / HTTP_QUEUE_REQUESTS_PER_SEC)
	end

	queue_active = false
end

local function http_get_async(url: string): string
	assert(is_server, PRINT_LEADER .. "http_get_async can only be called on the server.")

	table.insert(http_queue, { url = url, thread = coroutine.running() })

	if not queue_active then
		queue_active = true
		-- Deferred so this thread has yielded before the worker can resume it
		-- (matters when GetAsync or a mock returns without yielding).
		task.defer(run_queue)
	end

	local success, res = coroutine.yield()

	if not success then
		error(PRINT_LEADER .. "GET " .. url .. " failed with: " .. tostring(res), 2)
	end

	return res
end

--------------------------------------------------------------------------------
--
-- fetch
--
-- Fetches raw PNG bytes, honouring the _G.REMOTE_IMG_CUSTOM_GET override.
-- The override receives (url, http_get_async) so it can fall back to the
-- built-in queue.
--
--------------------------------------------------------------------------------
local function fetch(url: string): string
	local custom = _G.REMOTE_IMG_CUSTOM_GET

	if typeof(custom) == "function" then
		local res = custom(url, http_get_async)
		assert(typeof(res) == "string" or typeof(res) == "buffer",
			PRINT_LEADER .. "REMOTE_IMG_CUSTOM_GET must return a string or buffer.")

		return if typeof(res) == "buffer" then buffer.tostring(res) else res
	end

	return http_get_async(url)
end

--------------------------------------------------------------------------------
--
-- decode
--
-- Decodes PNG bytes into (rgba_buffer, width, height).
--
--------------------------------------------------------------------------------
local function decode(data: string): (buffer, number, number)
	local image = png.new(data)

	if image.Width > MAX_SIZE or image.Height > MAX_SIZE then
		error(string.format(
			"%sImage is %dx%d, EditableImage is limited to %dx%d.",
			PRINT_LEADER, image.Width, image.Height, MAX_SIZE, MAX_SIZE
		), 2)
	end

	return image:ToRGBABuffer(), image.Width, image.Height
end

--------------------------------------------------------------------------------
--
-- create_image_from_array
--
-- Creates an EditableImage from pixel data.
--   * buffer: tightly packed 8-bit RGBA, width * height * 4 bytes.
--   * table:  flat RGBA numbers in 0-1 (the v1 format), converted to a buffer.
--
--------------------------------------------------------------------------------
local function create_image_from_array(pixels: buffer | { number }, width: number, height: number): EditableImage
	assert(width >= 1 and height >= 1, PRINT_LEADER .. "Width and height must be at least 1.")
	assert(width <= MAX_SIZE and height <= MAX_SIZE,
		PRINT_LEADER .. "EditableImage is limited to " .. MAX_SIZE .. "x" .. MAX_SIZE .. ".")

	local expected = width * height * 4
	local buf: buffer

	if typeof(pixels) == "buffer" then
		buf = pixels
	else
		buf = buffer.create(expected)
		for i = 1, math.min(#pixels, expected) do
			buffer.writeu8(buf, i - 1, math.clamp(math.floor(pixels[i] * 255 + 0.5), 0, 255))
		end
	end

	assert(buffer.len(buf) == expected, string.format(
		"%sPixel data is %d bytes, expected %d (%dx%dx4).",
		PRINT_LEADER, buffer.len(buf), expected, width, height
	))

	local size = Vector2.new(width, height)
	local ok, editable_img = pcall(asset_service.CreateEditableImage, asset_service, { Size = size })

	if not ok or not editable_img then
		error(
			PRINT_LEADER .. "CreateEditableImage failed: " .. tostring(editable_img)
			.. " (Is EditableImage enabled for this experience, and is the memory budget exhausted?)",
			2
		)
	end

	editable_img:WritePixelsBuffer(Vector2.zero, size, buf)

	return editable_img
end

--------------------------------------------------------------------------------
--
-- create_image_from_string
--
-- Creates an EditableImage from a PNG binary string or buffer.
--
--------------------------------------------------------------------------------
local function create_image_from_string(data: string | buffer): EditableImage
	if typeof(data) == "buffer" then
		data = buffer.tostring(data)
	end

	return create_image_from_array(decode(data :: string))
end

--------------------------------------------------------------------------------
--
-- create_image
--
-- Creates an EditableImage from a PNG url. On the client the server must have
-- called `serve()`; the server fetches and decodes, the client builds the image.
--
--------------------------------------------------------------------------------
local function create_image(url: string): EditableImage
	if is_server then
		return create_image_from_array(decode(fetch(url)))
	end

	local remote = script:WaitForChild("communicator") :: RemoteFunction
	local res = remote:InvokeServer(url)

	assert(typeof(res) == "table", PRINT_LEADER .. "Request unauthorised.")
	assert(res.ok, PRINT_LEADER .. "Server failed to load image: " .. tostring(res.err))

	return create_image_from_array(res.pixels, res.width, res.height)
end

--------------------------------------------------------------------------------
--
-- apply
--
-- Displays an EditableImage on a GUI image, MeshPart, Decal or Texture by
-- setting the matching Content property. Replaces v1's `image.Parent = target`.
--
--------------------------------------------------------------------------------
local function apply(target: Instance, image: EditableImage): ()
	local property = CONTENT_PROPERTY[target.ClassName]
	assert(property, PRINT_LEADER .. "Don't know how to apply an image to a " .. target.ClassName .. ".")

	local instance: any = target
	instance[property] = Content.fromObject(image)
end

--------------------------------------------------------------------------------
--
-- serve
--
-- Allows clients to execute 'create_image'. Pixels are sent back as a buffer.
--
--------------------------------------------------------------------------------
local function serve(auth_func: ((Player, string) -> boolean)?): ()
	assert(is_server, PRINT_LEADER .. "serve can only be called on the server.")

	if not auth_func then
		warn(
			PRINT_LEADER
			.. "No auth_func provided, all users have the ability to"
			.. " use the create_image function. Pass 'builtin.allow_all'"
			.. " into 'serve()' to silence this message."
		)
	end

	if script:FindFirstChild("communicator") then
		warn(PRINT_LEADER .. "serve() was already called, ignoring.")
		return
	end

	local remote = Instance.new("RemoteFunction")
	remote.Name = "communicator"

	remote.OnServerInvoke = function(player: Player, url: unknown)
		if typeof(url) ~= "string" then
			return nil
		end

		if auth_func and not auth_func(player, url) then
			return nil
		end

		local ok, pixels, width, height = pcall(function()
			return decode(fetch(url))
		end)

		if not ok then
			return { ok = false, err = tostring(pixels) }
		end

		return { ok = true, pixels = pixels, width = width, height = height }
	end

	remote.Parent = script
end

--------------------------------------------------------------------------------
--
-- URL helpers used by the builtin checks.
--
--------------------------------------------------------------------------------
local function split_url(url: string): (string?, string?, string?)
	local protocol, rest = string.match(url, "^(%a[%w+.-]*)://(.*)$")
	if not protocol then
		return nil, nil, nil
	end

	local host, path = string.match(rest, "^([^/?#]*)(.*)$")
	if path == "" then
		path = "/"
	end

	return string.lower(protocol), string.lower(host), path
end

--------------------------------------------------------------------------------
--
-- builtin.protocols
--
-- Returns true if the url uses one of the passed protocols (e.g. {"https"}).
--
--------------------------------------------------------------------------------
function builtin.protocols(url: string, protocols: { string }): boolean
	local protocol = split_url(url)
	return protocol ~= nil and table.find(protocols, protocol) ~= nil
end

--------------------------------------------------------------------------------
--
-- builtin.hosts
--
-- Returns true if the url's host is one of the passed hosts (exact match).
--
--------------------------------------------------------------------------------
function builtin.hosts(url: string, hosts: { string }): boolean
	local _, host = split_url(url)
	return host ~= nil and table.find(hosts, host) ~= nil
end

--------------------------------------------------------------------------------
--
-- builtin.paths
--
-- Returns true if the url's path (including any query) is one of the passed
-- paths, e.g. {"/eX24dFX.png"}.
--
--------------------------------------------------------------------------------
function builtin.paths(url: string, paths: { string }): boolean
	local _, _, path = split_url(url)
	return path ~= nil and table.find(paths, path) ~= nil
end

--------------------------------------------------------------------------------
--
-- builtin.user_ids
--
-- Returns true if the player has one of the passed user ids.
--
--------------------------------------------------------------------------------
function builtin.user_ids(player: Player, user_ids: { number }): boolean
	return table.find(user_ids, player.UserId) ~= nil
end

--------------------------------------------------------------------------------
--
-- builtin.allow_all
--
-- Always returns true.
--
--------------------------------------------------------------------------------
function builtin.allow_all(): boolean
	return true
end

--------------------------------------------------------------------------------
-- Export:

return {
	create_image = create_image,
	create_image_from_array = create_image_from_array,
	create_image_from_string = create_image_from_string,
	apply = apply,
	serve = serve,
	builtin = builtin,
	http_get_async = http_get_async,
	version = VERSION,
}
