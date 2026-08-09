local loader = love and love.filesystem and love.filesystem.load or loadfile

local mons = {}
local stadiumProvider = {}
local shot = {
  vp = {}, lx = 10, ly = 20, scale = 2, pw = 640, ph = 480,
}
local V = { require = function(name)
  if name == "Voxel3D" then return { available = function() return true end } end
  if name == "StadiumPack" then return {} end
  if name == "BattlePresets" then
    return {
      component = function() return stadiumProvider end,
      stadiumBattlers = function() return stadiumProvider end,
    }
  end
  if name == "OverworldBattle" then
    return {
      setting = { get = function() return "stadium" end },
      discs = function() return false end,
      shot = function() return shot end,
    }
  end
  if name == "BattleScene" then
    return { toGB = function(vp, x, y, z, lx, ly, scale, pw, ph)
      assert(vp == shot.vp and lx == 10 and ly == 20)
      assert(scale == 2 and pw == 640 and ph == 480)
      return x, y + z
    end }
  end
  if name == "StadiumMon" then
    return { new = function(side)
      local mon = { side = side, visible = true }
      function mon:release() end
      mons[side] = mon
      return mon
    end }
  end
  error(name)
end }

local Stadium = assert(loader("lib/Stadium.lua"))(V)
assert(Stadium.begin({}))

local enemy = mons.enemy
enemy.model = { attachments = {
  { tag = 0x0A, bone = 2 },
  { tag = 0x64, bone = 3 },
  { tag = 0x07, bone = 4 },
} }
enemy.rig = { attachment = function(_, bone)
  return bone, bone + 1, bone + 2
end }
enemy.model_matrix = {
  1, 0, 0, 10,
  0, 1, 0, 20,
  0, 0, 1, 30,
  0, 0, 0, 1,
}

-- The conventional request prefers 0x0A over 0x64.
local x, y = Stadium.attachment("enemy", 0x64)
assert(x == 12 and y == 57)

-- A named tag resolves directly.
x, y = Stadium.attachment("enemy", 0x07)
assert(x == 14 and y == 61)

-- A missing named tag falls back to 0x64, not 0x0A.
x, y = Stadium.attachment("enemy", 0x0E)
assert(x == 13 and y == 59)

assert(Stadium.attachment("middle", 0x07) == nil)
enemy.visible = false
assert(Stadium.attachment("enemy", 0x07) == nil)

print("ok stadium attachment API")
