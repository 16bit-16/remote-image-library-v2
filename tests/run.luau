local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")
local task = require("@lune/task")
local process = require("@lune/process")

-- Usage (from tests/fixtures): lune run ../run.luau ../../src
local SRC = process.args[1] or "../../src"
local expected = serde.decode("json", fs.readFile("expected.json"))

local passed, failed = 0, 0
local function check(name, cond, msg)
	if cond then
		passed += 1
		print("PASS " .. name)
	else
		failed += 1
		print("FAIL " .. name .. ": " .. tostring(msg))
	end
end

-- Load png.lua with Roblox datatypes available.
local png_env = { Color3 = roblox.Color3 }
local png = luau.load(fs.readFile(SRC .. "/png.lua"), { debugName = "png", environment = png_env })()

-- Mocks ------------------------------------------------------------------
local http_log = {}
local http_responses = {}
local HttpService = {}
function HttpService:GetAsync(url)
	table.insert(http_log, { url = url, t = os.clock() })
	local r = http_responses[url]
	if r == nil then
		error("HTTP 404 (mock)")
	end
	return r
end

local created = {}
local AssetService = {}
function AssetService:CreateEditableImage(opts)
	local img = { Size = opts.Size }
	function img:WritePixelsBuffer(pos, size, buf)
		self.written = { pos = pos, size = size, buf = buf }
	end
	table.insert(created, img)
	return img
end

local is_server = true
local RunService = {}
function RunService:IsServer() return is_server end

local services = { HttpService = HttpService, AssetService = AssetService, RunService = RunService }
local game = {}
function game:GetService(n) return assert(services[n], n) end

local Content = {}
function Content.fromObject(o) return { kind = "Object", object = o } end

local script = { png = "PNG_MODULE" }
function script:FindFirstChild(n) return rawget(self, "_children") and self._children[n] end

local instance_new = function() error("Instance.new not mocked") end
local function load_lib()
	local env = {
		Instance = { new = function(...) return instance_new(...) end },
		game = game,
		script = script,
		Content = Content,
		Vector2 = roblox.Vector2,
		task = task,
		_G = {},
		require = function(m) assert(m == "PNG_MODULE") return png end,
		warn = function(...) print("[warn]", ...) end,
	}
	return luau.load(fs.readFile(SRC .. "/init.lua"), { debugName = "init", environment = env })(), env
end

local lib, env = load_lib()

-- Decoder tests ----------------------------------------------------------
for name, exp in expected do
	local ok, err = pcall(function()
		local image = lib.create_image_from_string(fs.readFile(name .. ".png"))
		local buf = image.written.buf
		assert(buffer.len(buf) == #exp, "len " .. buffer.len(buf) .. " vs " .. #exp)
		for i = 1, #exp do
			local got = buffer.readu8(buf, i - 1)
			if got ~= exp[i] then
				error(string.format("byte %d: got %d expected %d", i - 1, got, exp[i]))
			end
		end
		assert(image.Size.X == 7 and image.Size.Y == 5, "size")
		assert(image.written.size.X == 7, "write size")
	end)
	check("decode " .. name, ok, err)
end

-- buffer input to create_image_from_string
do
	local ok, err = pcall(function()
		local image = lib.create_image_from_string(buffer.fromstring(fs.readFile("rgb8.png")))
		assert(buffer.readu8(image.written.buf, 3) == 255)
	end)
	check("create_image_from_string(buffer)", ok, err)
end

for _, name in { "bit1", "interlaced", "big" } do
	local ok, err = pcall(lib.create_image_from_string, fs.readFile(name .. ".png"))
	check("rejects " .. name, not ok, "did not error")
	print("     -> " .. tostring(err))
end

-- v1-style float table
do
	local ok, err = pcall(function()
		local image = lib.create_image_from_array({ 1, 0, 0.5, 1, 0, 1, 0, 0 }, 2, 1)
		local b = image.written.buf
		assert(buffer.readu8(b, 0) == 255 and buffer.readu8(b, 2) == 128 and buffer.readu8(b, 7) == 0)
	end)
	check("create_image_from_array(table)", ok, err)
	local ok2 = pcall(lib.create_image_from_array, buffer.create(10), 2, 2)
	check("create_image_from_array wrong length errors", not ok2)
end

-- HTTP queue -------------------------------------------------------------
http_responses["https://i.imgur.com/a.png"] = fs.readFile("rgba8.png")
http_responses["https://i.imgur.com/b.png"] = fs.readFile("rgb8.png")
do
	local results = {}
	local start = os.clock()
	for i, u in { "https://i.imgur.com/a.png", "https://i.imgur.com/b.png", "https://i.imgur.com/missing.png" } do
		task.spawn(function()
			local ok, res = pcall(lib.create_image, u)
			results[i] = { ok = ok, res = res }
		end)
	end
	local deadline = os.clock() + 5
	while (not results[1] or not results[2] or not results[3]) and os.clock() < deadline do
		task.wait(0.05)
	end
	check("queue completes all requests", results[1] and results[2] and results[3], "timed out")
	check("queue success a", results[1] and results[1].ok, results[1] and results[1].res)
	check("queue success b", results[2] and results[2].ok, results[2] and results[2].res)
	check("queue failure propagates to caller", results[3] and not results[3].ok, "no error")
	if results[3] then print("     -> " .. tostring(results[3].res)) end
	local gap = http_log[2].t - http_log[1].t
	check("queue spaces requests ~0.5s", gap >= 0.4, gap)
	-- queue restarts after idle
	task.wait(0.6)
	local ok, err = pcall(lib.create_image, "https://i.imgur.com/a.png")
	check("queue restarts after draining", ok, err)
end

-- Custom GET override ----------------------------------------------------
do
	local seen
	env._G.REMOTE_IMG_CUSTOM_GET = function(url, original)
		seen = url
		return original("https://i.imgur.com/b.png")
	end
	local ok, err = pcall(lib.create_image, "custom://x")
	check("REMOTE_IMG_CUSTOM_GET is called and can use original", ok and seen == "custom://x", err)
	env._G.REMOTE_IMG_CUSTOM_GET = function() return buffer.fromstring(fs.readFile("gray8.png")) end
	ok, err = pcall(lib.create_image, "custom://y")
	check("REMOTE_IMG_CUSTOM_GET may return a buffer", ok, err)
	env._G.REMOTE_IMG_CUSTOM_GET = nil
end

-- builtin ----------------------------------------------------------------
local b = lib.builtin
check("protocols https", b.protocols("https://i.imgur.com/x.png", { "https" }))
check("protocols http rejected", not b.protocols("http://i.imgur.com/x.png", { "https" }))
check("protocols garbage", not b.protocols("not a url", { "https" }))
check("hosts match", b.hosts("https://i.imgur.com/x.png", { "i.imgur.com" }))
check("hosts case-insensitive", b.hosts("https://I.IMGUR.com/x.png", { "i.imgur.com" }))
check("hosts no path", b.hosts("https://i.imgur.com", { "i.imgur.com" }))
check("hosts spoof rejected", not b.hosts("https://i.imgur.com.evil.io/x.png", { "i.imgur.com" }))
check("hosts garbage", not b.hosts("garbage", { "i.imgur.com" }))
check("paths match", b.paths("https://i.imgur.com/eX24dFX.png", { "/eX24dFX.png" }))
check("paths mismatch", not b.paths("https://i.imgur.com/other.png", { "/eX24dFX.png" }))
check("user_ids", b.user_ids({ UserId = 5 }, { 5 }) and not b.user_ids({ UserId = 6 }, { 5 }))

-- apply ------------------------------------------------------------------
do
	local label = { ClassName = "ImageLabel" }
	local part = { ClassName = "MeshPart" }
	local decal = { ClassName = "Decal" }
	local img = created[1]
	lib.apply(label, img); lib.apply(part, img); lib.apply(decal, img)
	check("apply ImageLabel", label.ImageContent and label.ImageContent.object == img)
	check("apply MeshPart", part.TextureContent and part.TextureContent.object == img)
	check("apply Decal", decal.TextureContent and decal.TextureContent.object == img)
	check("apply unknown errors", not pcall(lib.apply, { ClassName = "Part" }, img))
end

-- serve / client round trip ---------------------------------------------
do
	local remote
	instance_new = function(c)
		assert(c == "RemoteFunction")
		remote = { ClassName = c }
		return setmetatable(remote, { __newindex = function(t, k, v)
			rawset(t, k, v)
			if k == "Parent" then script._children = { communicator = t } end
		end })
	end
	lib.serve(function(player, url) return b.hosts(url, { "i.imgur.com" }) and player.UserId == 1 end)
	check("serve creates communicator", script._children and script._children.communicator == remote)

	local denied = remote.OnServerInvoke({ UserId = 2 }, "https://i.imgur.com/a.png")
	check("serve denies unauthorised", denied == nil)
	check("serve rejects non-string url", remote.OnServerInvoke({ UserId = 1 }, 123) == nil)
	local res = remote.OnServerInvoke({ UserId = 1 }, "https://i.imgur.com/a.png")
	check("serve returns buffer", res and res.ok and typeof(res.pixels) == "buffer" and res.width == 7, res)
	local bad = remote.OnServerInvoke({ UserId = 1 }, "https://i.imgur.com/missing.png")
	check("serve reports fetch errors", bad and bad.ok == false and bad.err, bad)

	-- client side
	is_server = false
	local client = load_lib()
	function script:WaitForChild(n)
		local r = self._children[n]
		return { InvokeServer = function(_, url) return r.OnServerInvoke({ UserId = 1 }, url) end }
	end
	local ok, img = pcall(client.create_image, "https://i.imgur.com/a.png")
	check("client create_image", ok and buffer.readu8(img.written.buf, 0) == expected.rgba8[1], img)
	local ok2, err2 = pcall(client.create_image, "https://evil.io/a.png")
	check("client unauthorised errors", not ok2, "no error")
	print("     -> " .. tostring(err2))
	is_server = true
end

print(string.format("\n%d passed, %d failed", passed, failed))
process.exit(if failed == 0 then 0 else 1)
