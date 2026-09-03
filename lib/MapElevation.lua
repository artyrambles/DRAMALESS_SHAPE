-- Regional ground elevation for issue #41: ledges used to be a flat world
-- with a 6px curb standing at the jump tile (data/voxel_heights.lua's
-- `ledge` class) and nothing else acknowledging the step. lib/MapGrids.lua
-- now carries a per-cell elevation draft (in "ledge steps": 0.5 per hop
-- half, 1.0 per full hop); this turns that into the world-pixel offset the
-- mesher and the walker's ground height both read.
--
-- A map absent from MapGrids -- everything the draft hasn't reached yet --
-- reads as flat, so this is a pure addition until a map gets an entry.

local V = ...

local MapGrids = V.require("MapGrids") or {}
local ModSetting = V.require("ModSetting")

-- World pixels per 1.0 of MapGrids elevation. Sized so a single mapped
-- ledge (a 0.5 step either side of the hop tile) matches the curb height
-- the `ledge` tile class already rendered, so a freshly-mapped map's ledges
-- read at the same height they always did -- just carried across the whole
-- slope instead of stopping at the hop tile.
local UNIT = 12

local cache = {}   -- map id -> { [y * 4096 + x] = world px } | false (no data)

local function tableFor(mapId)
  local t = cache[mapId]
  if t ~= nil then return t end
  local src = MapGrids[mapId]
  if not src or not src.z then
    cache[mapId] = false
    return false
  end
  t = {}
  for _, e in ipairs(src.z) do
    t[e[2] * 4096 + e[1]] = e[3] * UNIT
  end
  cache[mapId] = t
  return t
end

-- A mapped ledge tile itself renders one full tile above its own resolved
-- slope value (the midpoint between the plateau it hops off and the one it
-- lands on) -- a lip standing proud of the terrace edge it belongs to,
-- rather than sitting flush with the slope like ordinary sloped ground
-- does. Stairs (TileShape's `stair` art) are a separate mechanism entirely
-- and never read this.
local LEDGE_LIP = 8

local MapElevation = { UNIT = UNIT, LEDGE_LIP = LEDGE_LIP }

-- Whether the derived terrain elevation applies at all. This is the ONE
-- place every consumer (ChunkMesher, VoxelScene) reads elevation through,
-- so gating it here is enough on its own -- OFF folds worldHeight back to
-- 0 everywhere, which puts ledges back on their original flat curb
-- (TileShape's `ledge` class height), buildings back at their doorway's
-- floor level, and grass/flowers/signs back at the height they were
-- authored at, all without any of those call sites needing their own
-- OFF path or MapGrids.lua itself changing at all.
MapElevation.setting = ModSetting.new(
  "elevation", "ELEVATION", { true, false }, { "ON", "OFF" })

function MapElevation.enabled()
  return MapElevation.setting:get() and true or false
end

-- The extra ground height (world pixels, +up) MapGrids assigns cell
-- (cx, cy) on `map`, or 0 where the map has no draft data yet, or the
-- setting above is OFF.
function MapElevation.worldHeight(map, cx, cy)
  if not MapElevation.enabled() then return 0 end
  local t = tableFor(map.id)
  if not t then return 0 end
  return t[cy * 4096 + cx] or 0
end

-- Whether `mapId` has any MapGrids draft at all -- callers use this to keep
-- the old per-tile ledge bump on maps this draft hasn't reached, rather
-- than silently flattening ledges that just aren't mapped yet.
function MapElevation.hasData(mapId)
  return tableFor(mapId) ~= false
end

return MapElevation
