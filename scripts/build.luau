-- Builds remote_img.rbxmx without Rojo.
-- Usage: lune run scripts/build.luau src remote_img.rbxmx
local fs = require("@lune/fs")
local roblox = require("@lune/roblox")
local process = require("@lune/process")
local src, out = process.args[1] or "src", process.args[2] or "remote_img.rbxmx"
local root = roblox.Instance.new("ModuleScript")
root.Name = "remote_img"
root.Source = fs.readFile(src .. "/init.lua")
local p = roblox.Instance.new("ModuleScript")
p.Name = "png"
p.Source = fs.readFile(src .. "/png.lua")
p.Parent = root
fs.writeFile(out, roblox.serializeModel({ root }, true))
local back = roblox.deserializeModel(fs.readFile(out))
print(back[1].Name, back[1]:GetChildren()[1].Name, #back[1].Source, #back[1]:GetChildren()[1].Source)
