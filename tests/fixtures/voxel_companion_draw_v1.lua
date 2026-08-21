-- Shared ROM-free golden fixture for the Voxel Companion draw schema v1.

local INSTANCE_PRIMITIVES = {
  "box", "plane", "door_frame", "window", "poster", "rail", "fixture",
  "sconce", "cave_roof", "grass_clump", "canopy", "vine", "umbrella",
  "mountain", "hood",
}

local INSTANCE_PROTOTYPES = {
  box = { primitive = "box", width = 4, height = 6, depth = 4 },
  plane = { primitive = "plane", width = 4, depth = 4 },
  door_frame = { primitive = "door_frame", role = "door" },
  window = { primitive = "window", role = "window" },
  poster = { primitive = "poster", role = "poster" },
  rail = { primitive = "rail", role = "rail" },
  fixture = { primitive = "fixture", role = "light_fixture" },
  sconce = { primitive = "sconce", role = "sconce" },
  cave_roof = { primitive = "cave_roof", width = 4, depth = 4,
    role = "cave_roof" },
  grass_clump = { primitive = "grass_clump", width = 4, wind = "BREEZE" },
  canopy = { primitive = "canopy", width = 4, cutaway = true },
  vine = { primitive = "vine", animated = true },
  umbrella = { primitive = "umbrella" },
  mountain = { primitive = "mountain", role = "mountain", shadow = true },
  hood = { primitive = "hood", role = "boulder_tree", shadow = true },
}

local GOLDEN_TEXTURE = { fixture = "callback_borrowed_texture" }

local phases = {
  background = {},
  opaque_after_terrain = {},
  translucent_after_actors = {},
}

local phaseIds = {
  background = 1,
  opaque_after_terrain = 2,
  translucent_after_actors = 3,
}

local sequence = 0
local function add(phase, command)
  sequence = sequence + 1
  command.schemaVersion = 1
  command.cacheKey = table.concat({
    "kfp1", "0123abcd", "1", tostring(phaseIds[phase]), tostring(sequence),
    string.format("%016x", sequence),
  }, ":")
  command.sequence = sequence
  command.phase = phase
  command.owner = "golden"
  command.sortKey = string.format("%02d:%s", sequence, command.kind)
  phases[phase][#phases[phase] + 1] = command
end

add("background", {
  kind = "mesh",
  material = "golden:box",
  geometry = { primitive = "box", x = 4, y = 2, z = 4,
    width = 4, height = 4, depth = 4 },
})

add("background", {
  kind = "mesh",
  material = "golden:plane",
  geometry = { primitive = "plane", x = 8, y = 0, z = 8,
    width = 16, depth = 16 },
})

add("opaque_after_terrain", {
  kind = "mesh",
  material = "golden:apron",
  geometry = { primitive = "world_apron", width = 32, depth = 32,
    skirtDepth = 16 },
})

for index, primitive in ipairs(INSTANCE_PRIMITIVES) do
  local command = {
    kind = "instances",
    material = "golden:" .. primitive,
    prototype = INSTANCE_PROTOTYPES[primitive],
    items = { { x = index * 2, y = 3, z = 12 } },
  }
  if primitive == "poster" then command.texture = GOLDEN_TEXTURE end
  add("opaque_after_terrain", command)
end

add("translucent_after_actors", {
  kind = "billboards",
  material = "golden:particles",
  items = {
    { x = 6, y = 8, z = 6, width = 2, height = 3 },
    { x = 10, y = 9, z = 10, width = 2, height = 3 },
  },
})

return {
  schemaVersion = 1,
  context = {
    world = {
      id = "golden",
      key = "golden",
      width = 2,
      height = 2,
      cellSize = 16,
      atlasRevision = 0,
    },
  },
  phases = phases,
  instancePrimitives = INSTANCE_PRIMITIVES,
  commandCount = sequence,
}
