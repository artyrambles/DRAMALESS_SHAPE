-- A flat top must not stamp its rim twice.
--
-- ChunkMesher.flatTopRow decides which drawn row a flat-topped volume's top
-- face wears at each depth. Where the drawing is a RIM over a uniform body
-- -- every cliff mound in the game, and the mound the Diglett's Cave mouth
-- is cut into -- the rim belongs at the plateau's north edge and nowhere
-- else. Cycling the first two rows lays it again every second tile.
--
-- The invariant: on such a run the sampled row never goes BACKWARDS as ty
-- moves south. Art that genuinely repeats (the Safari Zone's fence
-- alternates two tiles the whole way down) is exempt: there the repeat is
-- what the drawing says, and the run is not rim-over-body.
--
--   POKEPORT_DRIVER=mods/DRAMALESS_SHAPE/tests/flat_top_test.lua lovec .
return function(game)
  local U = dofile("tests/drivers/util.lua")

  local V = game.mods.exports["DRAMALESS_SHAPE"]
  V = V and V.lib
  local Structures = V and V.require("Structures")
  local ChunkMesher = V and V.require("ChunkMesher")
  if not (Structures and ChunkMesher and ChunkMesher.flatTopRow) then
    print("[flattop] FAIL mod, Structures or ChunkMesher.flatTopRow missing")
    love.event.quit(1)
    return
  end
  local function keyOf(tx, ty) return (ty + 64) * 4096 + (tx + 64) end

  local MAPS = {}
  for id in pairs((game.data and game.data.maps) or {}) do
    MAPS[#MAPS + 1] = id
  end
  table.sort(MAPS)

  local checked, offenders, examples = 0, 0, {}
  for _, mapId in ipairs(MAPS) do
    U.teleport(game, mapId, 5, 5, "up")
    U.wait(6)
    local ow = game.overworld
    if ow and ow.map and ow.map.def and ow.map.def.id == mapId then
      local map = ow.map
      local S = Structures.forMap(map)
      local seen = {}
      for tx = 0, map.def.width * 4 - 1 do
        for ty = 0, map.def.height * 4 - 1 do
          local run = S.runs[keyOf(tx, ty)]
          local sig = run and (tostring(run) .. ":" .. tx)
          if run and not seen[sig] and (run.rise or 0) == 0 then
            seen[sig] = true
            local ext = run.front - run.north + 1
            -- rim over a uniform body: the shape the rim must not repeat on
            local uniform = ext > 2
            if uniform then
              local body = map:tileAt(tx, run.north + 1)
              for d = 2, ext - 1 do
                if map:tileAt(tx, run.north + d) ~= body then
                  uniform = false
                  break
                end
              end
            end
            if uniform then
              checked = checked + 1
              local prev = -1
              for ty2 = run.north, run.front do
                local row = ChunkMesher.flatTopRow(run, ty2)
                if row < prev then
                  offenders = offenders + 1
                  if #examples < 5 then
                    examples[#examples + 1] = ("%s tx=%d north=%d ext=%d "
                      .. "went back to row %d at ty %d")
                      :format(mapId, tx, run.north, ext, row, ty2)
                  end
                  break
                end
                prev = row
              end
            end
          end
        end
      end
    end
  end

  print(("[flattop] %d rim-over-body runs checked, %d repeat their rim")
        :format(checked, offenders))
  for _, e in ipairs(examples) do print("[flattop]   " .. e) end
  if offenders > 0 then
    print("[flattop] FAIL")
    love.event.quit(1)
  else
    print("[flattop] PASS")
    love.event.quit(0)
  end
end
