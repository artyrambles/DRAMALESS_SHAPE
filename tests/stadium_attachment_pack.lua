local loader = love and love.filesystem and love.filesystem.load or loadfile

-- Lua 5.3 removed math.frexp; the game runtime retains it, while the small
-- portable interpreter used by this test does not.
if not math.frexp then
  function math.frexp(x)
    if x == 0 then return 0, 0 end
    local e = math.floor(math.log(math.abs(x)) / math.log(2)) + 1
    return x / (2 ^ e), e
  end
end

local N_MOVES, NONE = 165, 0xFFFF
local Build = assert(loader("lib/StadiumBuild.lua"))({ require = function(name)
  if name == "StadiumRom" then return { N_MOVES = N_MOVES } end
  if name == "StadiumFragment" then
    return { roundHalfEven = function(x) return math.floor(x + 0.5) end }
  end
  if name == "StadiumFx" then return {} end
  error(name)
end })

local data = {
  rootScale = { 1, 1, 1 },
  bones = { {
    parent = -1, t = { 0, 0, 0 }, r = { 0, 0, 0 }, s = { 1, 1, 1 },
  } },
  attachments = {
    { bone = 0, tag = 0x07 },
    { bone = 0, tag = 0x64 },
  },
  prims = { {
    tex = 0, cull = 0, texAnim = -1, nverts = 1, nidx = 0,
    pos = { 0, 0, 0 }, uv = { 0, 0 }, nrm = { 0, 1, 0 }, skin = { 0 }, idx = {},
  } },
  textures = {}, anims = {}, auxAnims = {},
}
local ctx = {}
for i = 1, 20 do ctx[i] = NONE end
local bytes = assert(Build.pack(data, 1, {}, ctx))
assert(bytes:sub(1, 4) == "DSM4")

local Pack
Pack = assert(loader("lib/StadiumPack.lua"))({
  mod = { read = function() return bytes end },
  require = function(name)
    if name == "StadiumInstall" then return { ready = function() return false end } end
    error(name)
  end,
})
local model = assert(Pack.load(1))
assert(model.attachmentCount == 2)
assert(model.attachments[1].tag == 0x07 and model.attachments[1].bone == 1)
assert(model.attachments[2].tag == 0x64 and model.attachments[2].bone == 1)

print("ok stadium attachment pack")
