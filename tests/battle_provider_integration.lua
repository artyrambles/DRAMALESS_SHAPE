-- The public catalog is not only metadata: OverworldBattle must actually use
-- a custom stage and battler provider, then retire it into the declared
-- Game-Boy-card fallback when it declines at runtime.

local warnings = {}
local modules = {}
local V = {
  mod = {
    id = "DRAMALESS_SHAPE",
    options = { get = function() return true end },
    log = { warn = function(_, fmt, ...)
      warnings[#warnings + 1] = string.format(fmt, ...)
    end },
  },
}
function V.require(name)
  if modules[name] ~= nil then return modules[name] end
  error("unexpected module: " .. tostring(name))
end

modules.ModSetting = assert(loadfile("lib/ModSetting.lua"))(V)
modules.BattlePresets = assert(loadfile("lib/BattlePresets.lua"))(V)
modules.BattleArena = { find = function() return nil end }
modules.BattleCam = { reset = function() end }
modules.BattleScene = { groundY = function() return 0 end }
modules.BattleDOF = { invalidate = function() end }
modules.BattleHud = { invalidate = function() end }
modules.BattlePics = { invalidate = function() end }
modules.Voxel3D = { available = function() return true end }
modules.ChunkMesher = {}

local game = { save = { options = { battleLayout = "og" } } }
package.loaded["src.core.Game"] = game

local began, finished = 0, 0
local arena = { playerCell = { 1, 1 }, enemyCell = { 2, 2 } }
local stage = {
  id = "TEST:stage", portable = true, replacesMap = true,
  arena = function(self, ctx, state)
    assert(ctx.state == state and ctx.preset == "TEST:composed")
    return arena
  end,
}
local actors = {
  id = "TEST:actors",
  begin = function(self, ctx, gotArena)
    assert(gotArena == arena and ctx.arena == arena)
    began = began + 1
    return true
  end,
  covers = function() return modules.BattlePresets.FALLBACK end,
  finish = function() finished = finished + 1 end,
}

local selected = modules.BattlePresets.register("TEST", "composed", {
  label = "TEST COMPOSED",
  fallback = modules.BattlePresets.ID_2D_A,
  components = { stage = stage, battlers = actors },
})

modules.OverworldBattle = assert(loadfile("lib/OverworldBattle.lua"))(V)
modules.OverworldBattle.setting:setValue(selected)

local state = { map = { id = "TEST_MAP" }, player = {}, entities = {}, ghosts = {} }
local battle = {}
assert(modules.OverworldBattle.begin(state, battle))
assert(began == 1)
assert(modules.OverworldBattle.arena() == arena)
assert(arena.stageReplacesMap == true)
assert(modules.OverworldBattle.battlerProvider() == actors)

-- FALLBACK retires TEST:actors. Its inherited 2D provider is explicit false,
-- so the backend exposes the ordinary billboard instead of another model.
assert(modules.OverworldBattle.battlerCall("covers", battle, "enemy") == nil)
assert(finished == 1)
assert(modules.OverworldBattle.battlerProvider() == nil)

modules.OverworldBattle.finish()
assert(state.entities ~= nil and state.ghosts ~= nil)

package.loaded["src.core.Game"] = nil
print("ok battle provider integration")
