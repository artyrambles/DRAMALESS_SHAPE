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
local animationBegan, animationUpdated, animationDrew = 0, 0, 0
local animationCast, animationFinished = 0, 0
local announced, screenDrawn = nil, 0
local stageUpdated, stageInvalidated, stageFinished = 0, 0, 0
local arena = { playerCell = { 1, 1 }, enemyCell = { 2, 2 } }
local stage = {
  id = "TEST:stage", portable = true, replacesMap = true,
  arena = function(self, ctx, state)
    assert(ctx.state == state and ctx.preset == "TEST:composed")
    return arena
  end,
  update = function() stageUpdated = stageUpdated + 1 end,
  invalidate = function() stageInvalidated = stageInvalidated + 1 end,
  finish = function() stageFinished = stageFinished + 1 end,
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
local baselineAnimation = {
  id = "TEST:baseline-animation",
  begin = function() animationBegan = animationBegan + 1 return true end,
  update = function() animationUpdated = animationUpdated + 1 end,
  drawWorld = function() animationDrew = animationDrew + 1 end,
  cast = function() animationCast = animationCast + 1 end,
  finish = function() animationFinished = animationFinished + 1 end,
}
local declinedAnimation = {
  id = "OTHER:declined-animation",
  begin = function() return modules.BattlePresets.FALLBACK end,
}
local announcer = {
  id = "VOICE:announcer",
  event = function(self, ctx, name, payload)
    announced = { name = name, payload = payload, battle = ctx.battle }
  end,
}
local camera = {
  id = "CAMERA:cinematic",
  camera = function(self, ctx, inherited)
    return { fov = 33, inherited = inherited }, 0.25, 96
  end,
}
local screen = {
  id = "SCREEN:custom",
  drawScreen = function() screenDrawn = screenDrawn + 1 return true end,
}

local selected = modules.BattlePresets.register("TEST", "composed", {
  label = "TEST COMPOSED",
  fallback = modules.BattlePresets.ID_2D_A,
  components = {
    stage = stage, battlers = actors, animations = baselineAnimation,
  },
})

-- Each independently stored row selects a provider from a different mod.
-- The animation selection deliberately declines so only that slot falls back
-- to the animation inherited from the selected 3D-BTL preset.
local selectors = {}
for _, item in ipairs(modules.BattlePresets.componentSettings()) do
  selectors[item.slot] = item.setting
end
local animationId = modules.BattlePresets.registerComponent(
  "OTHER", "animations", "decline", {
    label = "DECLINING ANIMATION", provider = declinedAnimation,
  })
local announcerId = modules.BattlePresets.registerComponent(
  "VOICE", "announcer", "calls", {
    label = "VOICE CALLS", provider = announcer,
  })
local cameraId = modules.BattlePresets.registerComponent(
  "CAMERA", "camera", "cinematic", {
    label = "CINEMATIC CAMERA", provider = camera,
  })
local screenId = modules.BattlePresets.registerComponent(
  "SCREEN", "screen", "complete", {
    label = "COMPLETE SCREEN", provider = screen,
  })
selectors.animations:setValue(animationId)
selectors.announcer:setValue(announcerId)
selectors.camera:setValue(cameraId)
selectors.screen:setValue(screenId)

modules.OverworldBattle = assert(loadfile("lib/OverworldBattle.lua"))(V)
modules.OverworldBattle.setting:setValue(selected)

local state = { map = { id = "TEST_MAP" }, player = {}, entities = {}, ghosts = {} }
local battle = {}
assert(modules.OverworldBattle.begin(state, battle))
assert(began == 1)
assert(modules.OverworldBattle.arena() == arena)
assert(arena.stageReplacesMap == true)
assert(modules.OverworldBattle.battlerProvider() == actors)
assert(animationBegan == 1)
assert(modules.OverworldBattle.componentProvider("animations") == baselineAnimation)
assert(modules.OverworldBattle.componentProvider("announcer") == announcer)

modules.OverworldBattle.componentsCall("update", 1 / 60, battle, 0)
modules.OverworldBattle.componentsCall("drawWorld", 0, arena, 0)
modules.OverworldBattle.componentsCall("cast", {}, arena, 0)
assert(animationUpdated == 1 and animationDrew == 1 and animationCast == 1)
modules.OverworldBattle.stageCall("update", 1 / 60, battle, 0)
modules.OverworldBattle.invalidate()
assert(stageUpdated == 1 and stageInvalidated == 1)

local supplied, pitch, frameH = modules.OverworldBattle.componentCall(
  "camera", "camera", { fov = 55 })
assert(supplied.fov == 33 and supplied.inherited.fov == 55)
assert(pitch == 0.25 and frameH == 96)
assert(modules.OverworldBattle.componentCall(
  "screen", "drawScreen", {}, {}) == true)
assert(screenDrawn == 1)

local eventPayload = { battle = battle, move = "THUNDERBOLT" }
modules.OverworldBattle.event("battle.move_used", eventPayload)
assert(announced.name == "battle.move_used")
assert(announced.payload == eventPayload and announced.battle == battle)

-- FALLBACK retires TEST:actors. Its inherited 2D provider is explicit false,
-- so the backend exposes the ordinary billboard instead of another model.
assert(modules.OverworldBattle.battlerCall("covers", battle, "enemy") == nil)
assert(finished == 1)
assert(modules.OverworldBattle.battlerProvider() == nil)

modules.OverworldBattle.finish()
assert(animationFinished == 1)
assert(stageFinished == 1)
assert(state.entities ~= nil and state.ghosts ~= nil)

package.loaded["src.core.Game"] = nil
print("ok battle provider integration")
