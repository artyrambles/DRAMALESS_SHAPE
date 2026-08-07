-- Driver: the two sloped-roof drawings in Pallet Town, shot at the orbit
-- rungs, to see what the roof surface wears down a TAPERED flank.
--
-- A tapered column's first drawn row is its silhouette cap, and the cap is
-- outline black. The depth map spends most of the roof's depth above that
-- cap, so a surface clamped onto it paints the outline the length of the
-- slope and the course cycle beats against it -- black teeth marching down
-- the hip. The surface belongs on the column's first PAINTED row instead.
--
--   POKEPORT_DRIVER=mods/DramaticShapeVoxelMod/tests/roof_cap_shots.lua \
--   SHOT_DIR=.scratchpad/roofcap AB_TAG=before lovec.exe .
return function(game)
  local U = dofile("tests/drivers/util.lua")
  local Pipelines = require("src.render.Pipelines")

  local ROOT = (os.getenv("SHOT_DIR") or "shots/roofcap")
    .. "/" .. (os.getenv("AB_TAG") or "after")

  local handle = game.mods.exports["DRAMALESS_SHAPE"]
  if not (handle and handle.lib) then
    print("[cap] DRAMALESS_SHAPE mod not loaded")
    return
  end
  local V = handle.lib
  local DayNight = V.require("DayNight")
  local ChunkMesher = V.require("ChunkMesher")
  local Voxel = V.require("VoxelState")

  require("src.world.OverworldController").rollEncounter = function() return nil end
  local TileRenderer = require("src.render.TileRenderer")
  TileRenderer.tick = function() end
  TileRenderer.animFrame = function() return 0 end
  DayNight.setting:sync("day")

  pcall(os.execute, 'mkdir -p "' .. ROOT .. '" 2>/dev/null')
  pcall(os.execute, 'mkdir "' .. ROOT:gsub("/", "\\") .. '" 2>nul')

  local Zoom = require("src.render.Zoom")
  pcall(function()
    game.save.options.zoom = 1
    Zoom.applyOptions(game.save.options)
  end)

  local function settle()
    for _ = 1, 900 do
      if ChunkMesher.pending() == 0 then break end
      U.wait(1)
    end
    for _ = 1, 300 do
      if Voxel.t >= 1 and Voxel.ready and ChunkMesher.pending() == 0 then break end
      U.wait(1)
    end
    U.wait(30)
  end

  -- B07 (the gabled house: Red's and Blue's) and B31 (Oak's lab) are the
  -- two tapered roof bands standing on one map -- 16 drawn rows and 32,
  -- the two groups every other sloped building borrows its band table
  -- from. Standing south of each puts the hip end across the frame.
  local SCENES = {
    { map = "PALLET_TOWN", x = 5,  y = 6,  face = "up", label = "reds_house" },
    { map = "PALLET_TOWN", x = 13, y = 3,  face = "up", label = "blues_house" },
    { map = "PALLET_TOWN", x = 12, y = 12, face = "up", label = "oaks_lab" },
  }

  local shots = 0
  for _, s in ipairs(SCENES) do
    for _, rung in ipairs({ 3, 5 }) do
      U.teleport(game, s.map, s.x, s.y, s.face)
      Pipelines.setLevel("voxel", rung)
      Pipelines.setLevel("tiltshift", 0)
      settle()
      local path = ("%s/%s_v%d.png"):format(ROOT, s.label, rung)
      game.capturePath = path
      U.wait(8)
      local f = io.open(path, "rb")
      if f then f:close() shots = shots + 1
      else print("[cap] capture missed: " .. path) end
    end
  end
  print(("[cap] %d shots into %s"):format(shots, ROOT))
  love.event.quit()
end
