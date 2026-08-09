local loader = love and love.filesystem and love.filesystem.load or loadfile

-- Public API: only a visible live model accepts a reaction, resisted damage
-- is intentionally motionless, and neutral/super damage requests `hit`.
local requested = {}
local mons = {}
local stadiumProvider = {}
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
    return { setting = { get = function() return "stadium" end },
      discs = function() return false end }
  end
  if name == "StadiumMon" then
    return { new = function(side)
      local mon = { side = side, rig = {}, visible = true }
      function mon:request(state)
        requested[#requested + 1] = { self.side, state }
        return true
      end
      function mon:release() end
      mons[side] = mon
      return mon
    end }
  end
  error(name)
end }

local Stadium = assert(loader("lib/Stadium.lua"))(V)
assert(Stadium.begin({}))
assert(Stadium.hit("enemy", "neutral"))
assert(Stadium.hit("player", "super"))
assert(Stadium.hit("enemy", 5))
assert(#requested == 2)
assert(requested[1][1] == "enemy" and requested[1][2] == "hit")
assert(requested[2][1] == "player" and requested[2][2] == "hit")
assert(not Stadium.hit("middle", "neutral"))
assert(not Stadium.hit("enemy", "unknown"))
mons.enemy.visible = false
assert(not Stadium.hit("enemy", "neutral"))

-- State mapping: the `hit` state resolves through context slot 168, which is
-- position four (`entrance`) in the packed context table, then returns idle.
local Pack = {
  FPS = 30, NONE = 0xFFFF, N_MOVES = 165,
  SLOT = { idle = 1, entrance = 4 },
}
local Mon = assert(loader("lib/StadiumMon.lua"))({ require = function(name)
  if name == "StadiumPack" then return Pack end
  if name == "StadiumRig" then return {} end
  if name == "Mat4" then return {} end
  error(name)
end })
local mon = Mon.new("enemy")
mon.model = {
  ctx = { [1] = 1, [4] = 0 },
  anims = { { seconds = 1 }, { seconds = 1 } },
}
mon.rig = {}
assert(mon:request("hit"))
assert(mon.state == "hit" and mon.anim == 1 and not mon.loop and not mon.hold)
mon:update(1.1)
assert(mon.state == "idle" and mon.anim == 2 and mon.loop)
print("ok stadium public hit API")
