-- Driver: screenshot the forest's atmosphere.
--
-- Viridian Forest through the pins: gold shafts and drifting pollen by
-- day, silver moon rays and fireflies at night, the haze under both, one
-- first-person frame standing inside a beam, and the control shots -- the
-- row OFF (which must be pixel-identical to a run before the feature
-- existed) and LOW (haze, half the shafts, no particles).
--
-- Deterministic on purpose: encounters killed, tile animation frozen, the
-- atmosphere's own clock pinned, so an AB_TAG=before/after pair diffs
-- clean (see tools/voxel-survey.md for the workflow).
--
--   SHOT_DIR=.scratchpad/forestfog AB_TAG=after \
--   POKEPORT_DRIVER=mods/DramaticShapeVoxelMod/tests/forest_fog_shots.lua lovec.exe .
return function(game)
  local U = dofile("tests/drivers/util.lua")
  local Pipelines = require("src.render.Pipelines")

  local ROOT = (os.getenv("SHOT_DIR") or ".scratchpad/forestfog")
    .. "/" .. (os.getenv("AB_TAG") or "after")

  local exports = game.mods and game.mods.exports
  local handle = exports and exports.DRAMALESS_SHAPE
  if not (handle and handle.lib) then
    U.log("DRAMALESS_SHAPE is not loaded -- enable it and run again")
    return
  end
  local lib = handle.lib
  local DayNight = lib.require("DayNight")
  local ChunkMesher = lib.require("ChunkMesher")
  local Voxel = lib.require("VoxelState")
  local ForestAtmos = lib.require("ForestAtmos")

  if not (game.data.maps and game.data.maps.VIRIDIAN_FOREST) then
    U.log("no VIRIDIAN_FOREST in this dataset")
    return
  end

  -- ------- the determinism recipe (see round_regress_shots)
  require("src.world.OverworldController").rollEncounter =
    function() return nil end
  local TileRenderer = require("src.render.TileRenderer")
  TileRenderer.tick = function() end
  TileRenderer.animFrame = function() return 0 end
  local Zoom = require("src.render.Zoom")
  pcall(function()
    game.save.options.zoom = 1
    Zoom.applyOptions(game.save.options)
  end)
  -- pin the atmosphere's own clock: every shimmer and every mote is a
  -- pure function of this number
  ForestAtmos.frozen = true
  ForestAtmos.time = 5

  local function setTime(value)
    DayNight.setting:sync(value)
    DayNight.update(0)
  end

  local function settle()
    for _ = 1, 900 do
      if ChunkMesher.pending() == 0 then break end
      U.wait(1)
    end
    for _ = 1, 300 do
      if Voxel.t >= 1 and Voxel.ready and ChunkMesher.pending() == 0 then
        break
      end
      U.wait(1)
    end
    U.wait(40)
  end

  local function go(x, y, face, rung)
    U.teleport(game, "VIRIDIAN_FOREST", x, y, face or "up")
    Pipelines.setLevel("voxel", rung or 5)
    Pipelines.setLevel("tiltshift", 0)   -- judge the atmosphere, not the blur
    settle()
  end

  ForestAtmos.setting:sync("full")

  -- ------- day: gold spears and pollen, three vantages
  setTime("day")
  go(17, 20)
  U.shot(game, ROOT .. "/10_day_17_20.png")
  go(16, 20)
  U.shot(game, ROOT .. "/11_day_16_20.png")
  go(16, 24)
  U.shot(game, ROOT .. "/12_day_16_24.png")

  -- ------- night: moon rays and fireflies, same vantages
  setTime("night")
  go(17, 20)
  U.shot(game, ROOT .. "/20_night_17_20.png")
  go(16, 20)
  U.shot(game, ROOT .. "/21_night_16_20.png")
  go(16, 24)
  U.shot(game, ROOT .. "/22_night_16_24.png")

  -- ------- first person, standing in a beam
  --
  -- The shafts are dealt by seed, so ask the layout where one landed and
  -- walk into it rather than guessing a cell.
  local shaft
  pcall(function()
    local map = game.overworld and game.overworld.map
    local L = map and ForestAtmos.layoutFor(map)
    shaft = L and L.shafts and L.shafts[1]
  end)
  if shaft then
    local cx = math.floor(shaft.x / 16)
    local cy = math.floor(shaft.z / 16)
    setTime("day")
    go(cx, cy + 1, "up", 6)              -- the 1ST rung, facing the beam
    U.shot(game, ROOT .. "/30_fp_in_beam_day.png")
    setTime("night")
    U.wait(30)
    U.shot(game, ROOT .. "/31_fp_in_beam_night.png")
  else
    U.log("no shaft landed -- check the layout seed")
  end

  -- ------- the controls
  setTime("day")
  ForestAtmos.setting:sync("low")
  go(17, 20)
  U.shot(game, ROOT .. "/40_low_day.png")
  ForestAtmos.setting:sync("off")
  go(17, 20)
  U.shot(game, ROOT .. "/41_off_day.png")   -- must match a pre-feature run

  ForestAtmos.setting:sync("full")
  ForestAtmos.frozen = false
  setTime("day")
  U.log("done -- " .. ROOT)
end
