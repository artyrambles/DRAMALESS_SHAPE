-- Voxel-map arena provider shared by the standalone native-card mode and the
-- optional StadiumBattleFX integration.

local V = ...
local Provider = {}
local BattleArena = V.require("BattleArena")
local Scene = V.require("VoxelBattleScene")

local function overworld()
  local Game = require("src.core.Game")
  return Game and Game.overworld
end

function Provider:available()
  local state = overworld()
  return state and state.map and state.player and V.require("Voxel3D").available()
end

function Provider:arena(context)
  local state = overworld()
  local log = context and context.services and context.services.log
  local function decline(reason)
    if log and log.warn then
      log:warn("[DRAMALESS_SHAPE] voxel arena declined: %s", tostring(reason))
    end
    return nil
  end
  if not (state and state.map and state.player) then
    return decline("overworld state unavailable")
  end
  local ok, arena = pcall(BattleArena.find, state.map,
    state.player.cellX, state.player.cellY, state.player.surfing)
  if not (ok and arena) then
    return decline(ok and "no suitable arena on current map" or ("arena search failed: " .. tostring(arena)))
  end
  if not Scene.ready(state, arena) then
    return decline("voxel terrain is not ready")
  end
  -- Publish the same canonical rig original Dramaless solves this arena
  -- against. SBFX reads this public arena field for its default camera, so
  -- hosting the voxel stage does not silently substitute Stadium's taller,
  -- farther-back court framing. Custom SBFX camera providers can still
  -- override it through the normal camera slot.
  local BattleCam = V.require("BattleCam")
  local rig = BattleCam.rigFor(arena)
  if rig then
    arena.camera = {
      side = rig.side, back = rig.back, height = rig.height,
      lookX = rig.lookX, lookY = rig.lookY, frameH = rig.frameH,
    }
  end
  arena.id = "dramaless:voxel-map:" .. tostring(arena.map and arena.map.id or state.map.id)
  return arena
end

function Provider:begin(context, arena)
  self.state = overworld()
  self.log = context and context.services and context.services.log
  V.require("BattleCam").reset()
  if self.log and self.log.event then
    self.log:event("DRAMALESS_SHAPE", "voxel-arena-begin", {
      map = arena and arena.map and arena.map.id or "unknown",
      arena = arena and arena.id or "unknown",
    })
  end
  return self.state and true or (V.stadiumBattleApi and V.stadiumBattleApi.FALLBACK)
end

function Provider:update(context, dt)
  V.require("BattleCam").update(dt or 0)
end

function Provider:render(context, arena, drawActors)
  if not self.state then return V.stadiumBattleApi and V.stadiumBattleApi.FALLBACK end
  local camera = context and context.services and context.services.camera
  local canvas = Scene.render(self.state, arena, drawActors, camera)
  return canvas or (V.stadiumBattleApi and V.stadiumBattleApi.FALLBACK)
end

function Provider:finish()
  self.state, self.log = nil, nil
end

function Provider:invalidate()
  self:finish()
end

return Provider
