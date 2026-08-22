-- Voxel world mode: how much world the neighbourhood holds.
--
-- The engine draws the current map plus a set of connected neighbours,
-- sized for the FLAT camera: two connection hops out, widened by the
-- top-down view's half-extents (OverworldState:rebuildNeighbors). Every
-- orbit rung frames exactly that view height -- Voxel3D derives its field
-- of view from it -- so the loaded set and the framed rect agree. The
-- free-cam rungs do not: the eye stands in the world and looks along the
-- ground, so the horizon runs far past a rect measured in top-down
-- screenfuls, and the maps out there were never loaded.
--
-- The widening term is the engine's. The hop count is ours to move --
-- constants.world.neighborHops, re-read on every rebuild -- so raise it
-- while the eye is in the world and let the engine do the loading: the
-- pass that places the maps is the one that tells the eviction which to
-- keep. How far it goes is the player's, on the row that already claims
-- to own it (Quality.reachHops).

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local Voxel = V.require("VoxelState")
local FirstPerson = V.require("FirstPerson")
local Quality = V.require("Quality")

local WorldReach = {}

-- what the engine had before this module touched it. `false` is "no copy
-- taken yet", which nil -- the key unset, FieldDefaults answering for it
-- -- must not be confused with.
local saved = false

local function worldConstants(Game)
  local constants = Game and Game.data and Game.data.constants
  return constants and constants.world
end

-- only on a real change: a rebuild loads maps and re-places every ghost
-- NPC standing on them, which is not a per-frame thing
local function apply(Game, world, hops)
  if world.neighborHops == hops then return end
  world.neighborHops = hops
  local ow = Game.overworld
  if ow and ow.map and ow.rebuildNeighbors then
    pcall(ow.rebuildNeighbors, ow)
  end
  V.log:event("world", "neighbor-hops", { hops = hops })
end

-- Held for the whole blend rather than for the rung: the fly-out is half
-- a second of camera still standing in the world, and dropping the far
-- maps on the keypress would empty the horizon in front of the player.
function WorldReach.update()
  local Game = require("src.core.Game")
  local world = worldConstants(Game)
  if not world then return end

  if Voxel.isFreeCam() or (FirstPerson.blend or 0) > 0 then
    if saved == false then saved = world.neighborHops end
    apply(Game, world, Quality.reachHops())
  elseif saved ~= false then
    local restore = saved
    saved = false
    apply(Game, world, restore)
  end
end

return WorldReach
