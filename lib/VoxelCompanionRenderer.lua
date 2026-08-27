-- Bounded renderer for Voxel Companion API v1 command packets.
--
-- Commands remain owned by the extension. This adapter either draws an
-- extension-owned mesh immediately or builds a host-owned, bounded mesh from
-- declarative geometry. A cost-aware LRU uses copied string keys and content
-- digests; it never retains a command table or borrowed resource. Host-owned
-- meshes are released on eviction, invalidation, and disposal. No command
-- table is changed.

local V = ...

local Renderer = {}
Renderer.__index = Renderer

local DEFAULT_MAX_CACHE = 128
local DEFAULT_MAX_CACHE_BYTES = 48 * 1024 * 1024
local DEFAULT_MAX_ITEMS = 2048
local DEFAULT_MAX_VERTICES = 196608
local MAX_CACHE = 512
local MAX_CACHE_BYTES = 256 * 1024 * 1024
local MAX_ITEMS = 8192
local MAX_VERTICES = 786432
local VERTEX_BYTES = 24
local INDEX_BYTES = 4
local MESH_OVERHEAD_BYTES = 256
local CUTAWAY_RADIUS_CELLS = 4
local PANORAMA_RADIUS = 900
local PANORAMA_SEGMENTS = 64
local PANORAMA_BOTTOM = -1
local PANORAMA_TOP = 300
local PANORAMA_DEEP = -1400
local CLOUD_SPAN = 7200
local CLOUD_CELLS = 24
local CLOUD_LIFT = 900
local CLOUD_HEIGHTS = { 210, 300, 410 }

local CACHE_KEY_PATTERN = "^[A-Za-z0-9%._:%-]+$"
local SKIP_RESOURCE_FIELD = {
  texture = true,
  mesh = true,
  resource = true,
  model = true,
}

local FACE_SHADE = { 0.84, 0.72, 1.00, 0.55, 0.90, 0.68 }

local function finite(value, name)
  value = tonumber(value)
  if not value or value ~= value or value == math.huge or value == -math.huge then
    error((name or "value") .. " must be finite", 3)
  end
  return value
end

local function positive(value, fallback, name)
  value = value == nil and fallback or value
  value = finite(value, name)
  if value <= 0 then error((name or "value") .. " must be positive", 3) end
  return value
end

local function bounded_integer(value, fallback, low, high)
  value = math.floor(tonumber(value) or fallback)
  return math.max(low, math.min(high, value))
end

local function dense_array(value, name, limit)
  if type(value) ~= "table" then error(name .. " must be an array", 3) end
  local count = 0
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
      error(name .. " must be a dense array", 3)
    end
    if key > count then count = key end
  end
  if count > limit then error(name .. " exceeds its item limit", 3) end
  for index = 1, count do
    if value[index] == nil then error(name .. " must be a dense array", 3) end
  end
  return count
end

local function cache_key(command)
  local key = command and command.cacheKey
  if type(key) ~= "string" or #key < 1 or #key > 64
      or not key:match(CACHE_KEY_PATTERN) then
    return nil, "draw command.cacheKey must be 1-64 safe ASCII characters"
  end
  return key
end

-- Hash only bounded declarative data. Opaque extension resources are borrowed
-- for one callback, so the host must not inspect, retain, hash, or release them.
-- Four independent 32-bit streams make accidental cache-key collisions fail
-- closed without retaining the extension command graph.
local function content_signature(command, context)
  local h1, h2, h3, h4 = 5381, 2166136261, 2246822519, 3266489917
  local bytes, nodes = 0, 0

  local function feed(text)
    text = tostring(text)
    bytes = bytes + #text
    if bytes > 256 * 1024 then error("draw command exceeds signature byte limit", 3) end
    for index = 1, #text do
      local byte = text:byte(index)
      h1 = (h1 * 33 + byte) % 4294967296
      h2 = (h2 * 65599 + byte) % 4294967296
      h3 = (h3 * 131 + byte) % 4294967296
      h4 = (h4 * 257 + byte) % 4294967296
    end
  end

  local walk
  walk = function(value, depth, command_root)
    nodes = nodes + 1
    if nodes > 32768 then error("draw command exceeds signature node limit", 3) end
    if depth > 16 then error("draw command exceeds signature depth limit", 3) end
    local kind = type(value)
    if kind == "nil" then
      feed("n;")
    elseif kind == "boolean" then
      feed(value and "b1;" or "b0;")
    elseif kind == "number" then
      feed("d" .. string.format("%.17g", finite(value, "signature number")) .. ";")
    elseif kind == "string" then
      feed("s" .. #value .. ":" .. value .. ";")
    elseif kind == "table" then
      if getmetatable(value) ~= nil then error("draw command data must be plain tables", 3) end
      local keys = {}
      for key in pairs(value) do
        if not (command_root and SKIP_RESOURCE_FIELD[key]) then
          local key_kind = type(key)
          if key_kind ~= "string" and key_kind ~= "number" then
            error("draw command data has an unsupported key type", 3)
          end
          keys[#keys + 1] = key
        end
      end
      table.sort(keys, function(a, b)
        local ak, bk = type(a), type(b)
        if ak ~= bk then return ak < bk end
        return a < b
      end)
      feed("{")
      for index = 1, #keys do
        local key = keys[index]
        walk(key, depth + 1, false)
        walk(value[key], depth + 1, false)
      end
      feed("}")
    else
      error("draw command data contains an unsupported value", 3)
    end
  end

  walk(command, 0, true)
  local world = context and context.world or {}
  local map = context and context.map or {}
  local tileset = map.tileset or {}
  feed("|host-context|")
  for _, value in ipairs({
    world.key or world.id or "world",
    world.atlasRevision or 0,
    world.width or 1,
    world.height or 1,
    world.cellSize or 16,
    tileset.id or "tileset",
    tileset.tilesPerRow or 16,
    tileset.imageWidth or 128,
    tileset.imageHeight or 48,
  }) do
    walk(value, 0, false)
  end
  return string.format("%08x%08x%08x%08x:%d:%d", h1, h2, h3, h4, bytes, nodes)
end

local function hash_text(value)
  local hash = 2166136261
  value = tostring(value or "material")
  for index = 1, #value do
    hash = (hash * 16777619 + value:byte(index)) % 4294967296
  end
  return hash
end

local function semantic_color(material)
  local hash = hash_text(material)
  local r = 0.42 + ((hash % 97) / 96) * 0.38
  local g = 0.42 + ((math.floor(hash / 97) % 89) / 88) * 0.38
  local b = 0.42 + ((math.floor(hash / 8633) % 83) / 82) * 0.38
  local alpha = 1
  local lower = material:lower()
  if lower:find("shadow", 1, true) then r, g, b, alpha = 0.05, 0.06, 0.08, 0.58 end
  if lower:find("fog", 1, true) then r, g, b, alpha = 0.58, 0.54, 0.72, 0.7 end
  if lower:find("water", 1, true) or lower:find("foam", 1, true) then
    r, g, b, alpha = 0.45, 0.72, 0.92, 0.76
  end
  if lower:find("firefly", 1, true) or lower:find("light", 1, true) then
    r, g, b, alpha = 1.0, 0.86, 0.38, 0.92
  end
  return { r, g, b, alpha }
end

local function command_color(command, fallback)
  local source = type(command.color) == "table" and command.color or fallback
  if type(source) ~= "table" then return { 1, 1, 1, 1 } end
  return {
    math.max(0, math.min(1, finite(source[1] or source.r or 1, "color.r"))),
    math.max(0, math.min(1, finite(source[2] or source.g or 1, "color.g"))),
    math.max(0, math.min(1, finite(source[3] or source.b or 1, "color.b"))),
    math.max(0, math.min(1, finite(source[4] or source.a or 1, "color.a"))),
  }
end

local function material_info(command, context)
  local material = type(command.material) == "string" and command.material or "host:default"
  local texture = command.texture
  local uv = { 0, 0, 1, 1 }
  local atlas_id, tile_text = material:match("^atlas:(.*):(-?%d+)$")
  local atlas = atlas_id and context and context.atlas or nil
  if atlas_id and atlas then
    local map = context.map or {}
    local tileset = map.tileset or {}
    local tile = tonumber(tile_text) or 0
    local per_row = math.max(1, tonumber(tileset.tilesPerRow) or 16)
    local width = math.max(8, tonumber(tileset.imageWidth) or per_row * 8)
    local height = math.max(8, tonumber(tileset.imageHeight) or 48)
    local inset = 0.02
    local column, row = tile % per_row, math.floor(tile / per_row)
    uv = {
      (column * 8 + inset) / width,
      (row * 8 + inset) / height,
      (column * 8 + 8 - inset) / width,
      (row * 8 + 8 - inset) / height,
    }
    texture = texture or atlas
  end
  return {
    id = material,
    texture = texture,
    uv = uv,
    color = command_color(command, atlas_id and { 1, 1, 1, 1 } or semantic_color(material)),
    atlas = atlas_id ~= nil,
  }
end

local function new_builder(uv, max_vertices)
  local builder = { vertices = {}, indices = {}, quads = 0, max = max_vertices, uv = uv }

  function builder:check(add)
    if #self.vertices + add > self.max then error("declarative mesh vertex limit reached", 3) end
  end

  function builder:quad(a, b, c, d, shade)
    self:check(4)
    local u0, v0, u1, v1 = self.uv[1], self.uv[2], self.uv[3], self.uv[4]
    local base = #self.vertices
    self.vertices[base + 1] = { a[1], a[2], a[3], u0, v1, shade }
    self.vertices[base + 2] = { b[1], b[2], b[3], u1, v1, shade }
    self.vertices[base + 3] = { c[1], c[2], c[3], u1, v0, shade }
    self.vertices[base + 4] = { d[1], d[2], d[3], u0, v0, shade }
    local map = self.indices
    map[#map + 1], map[#map + 2], map[#map + 3] = base + 1, base + 2, base + 3
    map[#map + 1], map[#map + 2], map[#map + 3] = base + 1, base + 3, base + 4
    self.quads = self.quads + 1
  end

  function builder:quad_uv(a, b, c, d, shade, auv, buv, cuv, duv)
    self:check(4)
    local base = #self.vertices
    self.vertices[base + 1] = { a[1], a[2], a[3], auv[1], auv[2], shade }
    self.vertices[base + 2] = { b[1], b[2], b[3], buv[1], buv[2], shade }
    self.vertices[base + 3] = { c[1], c[2], c[3], cuv[1], cuv[2], shade }
    self.vertices[base + 4] = { d[1], d[2], d[3], duv[1], duv[2], shade }
    local map = self.indices
    map[#map + 1], map[#map + 2], map[#map + 3] = base + 1, base + 2, base + 3
    map[#map + 1], map[#map + 2], map[#map + 3] = base + 1, base + 3, base + 4
    self.quads = self.quads + 1
  end

  function builder:triangle(a, b, c, shade)
    self:check(3)
    local u0, v0, u1, v1 = self.uv[1], self.uv[2], self.uv[3], self.uv[4]
    local base = #self.vertices
    self.vertices[base + 1] = { a[1], a[2], a[3], u0, v1, shade }
    self.vertices[base + 2] = { b[1], b[2], b[3], u1, v1, shade }
    self.vertices[base + 3] = { c[1], c[2], c[3], (u0 + u1) * 0.5, v0, shade }
    local map = self.indices
    map[#map + 1], map[#map + 2], map[#map + 3] = base + 1, base + 2, base + 3
  end

  return builder
end

local function add_box(builder, x, y, z, width, height, depth)
  width, height, depth = positive(width, 1, "box width"),
    positive(height, 1, "box height"), positive(depth, 1, "box depth")
  x, y, z = finite(x, "box x"), finite(y, "box y"), finite(z, "box z")
  local x0, x1 = x - width * 0.5, x + width * 0.5
  local y0, y1 = y - height * 0.5, y + height * 0.5
  local z0, z1 = z - depth * 0.5, z + depth * 0.5
  builder:quad({ x1, y0, z0 }, { x1, y0, z1 }, { x1, y1, z1 }, { x1, y1, z0 }, FACE_SHADE[1])
  builder:quad({ x0, y0, z1 }, { x0, y0, z0 }, { x0, y1, z0 }, { x0, y1, z1 }, FACE_SHADE[2])
  builder:quad({ x0, y1, z0 }, { x1, y1, z0 }, { x1, y1, z1 }, { x0, y1, z1 }, FACE_SHADE[3])
  builder:quad({ x0, y0, z1 }, { x1, y0, z1 }, { x1, y0, z0 }, { x0, y0, z0 }, FACE_SHADE[4])
  builder:quad({ x0, y0, z1 }, { x1, y0, z1 }, { x1, y1, z1 }, { x0, y1, z1 }, FACE_SHADE[5])
  builder:quad({ x1, y0, z0 }, { x0, y0, z0 }, { x0, y1, z0 }, { x1, y1, z0 }, FACE_SHADE[6])
end

local function add_plane(builder, x, y, z, width, depth)
  width, depth = positive(width, 1, "plane width"), positive(depth, 1, "plane depth")
  x, y, z = finite(x, "plane x"), finite(y, "plane y"), finite(z, "plane z")
  local hw, hd = width * 0.5, depth * 0.5
  builder:quad({ x - hw, y, z - hd }, { x + hw, y, z - hd },
    { x + hw, y, z + hd }, { x - hw, y, z + hd }, FACE_SHADE[3])
end

local function add_vertical(builder, x, y, z, width, height, yaw)
  width, height = positive(width, 1, "billboard width"), positive(height, 1, "billboard height")
  x, y, z, yaw = finite(x, "billboard x"), finite(y, "billboard y"),
    finite(z, "billboard z"), finite(yaw or 0, "billboard yaw")
  local dx, dz = math.cos(yaw) * width * 0.5, -math.sin(yaw) * width * 0.5
  builder:quad(
    { x - dx, y, z - dz }, { x + dx, y, z + dz },
    { x + dx, y + height, z + dz }, { x - dx, y + height, z - dz },
    FACE_SHADE[5]
  )
end

local function add_crossed(builder, x, y, z, width, height)
  add_vertical(builder, x, y, z, width, height, 0)
  add_vertical(builder, x, y, z, width, height, math.pi * 0.5)
end

local function unit(value, fallback, name)
  value = value == nil and fallback or value
  value = finite(value, name)
  if value < 0 or value > 1 then
    error((name or "value") .. " must be between zero and one", 3)
  end
  return value
end

-- A panorama's pixel width is a quality choice, not a world-space size.
-- Map the image once around a player-centred ring. The fixed physical scale
-- matches the legacy composition and prevents four repeated paintings and
-- the independent-quad corner gaps produced by the old box approximation.
local function add_panorama(builder, deep_skirt)
  for index = 0, PANORAMA_SEGMENTS - 1 do
    local u0, u1 = index / PANORAMA_SEGMENTS, (index + 1) / PANORAMA_SEGMENTS
    local a0, a1 = u0 * math.pi * 2, u1 * math.pi * 2
    local x0, z0 = math.cos(a0) * PANORAMA_RADIUS, math.sin(a0) * PANORAMA_RADIUS
    local x1, z1 = math.cos(a1) * PANORAMA_RADIUS, math.sin(a1) * PANORAMA_RADIUS
    builder:quad_uv(
      { x1, PANORAMA_BOTTOM, z1 }, { x0, PANORAMA_BOTTOM, z0 },
      { x0, PANORAMA_TOP, z0 }, { x1, PANORAMA_TOP, z1 }, FACE_SHADE[5],
      { u1, 1 }, { u0, 1 }, { u0, 0 }, { u1, 0 }
    )
    if deep_skirt then
      -- Clamp to the image's bottom row. This seals the below-world view
      -- without stretching the full illustration down into a dark wedge.
      builder:quad_uv(
        { x1, PANORAMA_DEEP, z1 }, { x0, PANORAMA_DEEP, z0 },
        { x0, PANORAMA_BOTTOM, z0 }, { x1, PANORAMA_BOTTOM, z1 }, FACE_SHADE[5],
        { u1, 1 }, { u0, 1 }, { u0, 1 }, { u1, 1 }
      )
    end
  end
end

-- Binary-coverage cloud textures repeat per cell over a high deck. Raising
-- each corner by its squared radius keeps the far deck above the horizon.
-- The texture handle stays borrowed; only the derived mesh is cached.
local function add_cloud_layer(builder, layer, density)
  layer = bounded_integer(layer, 1, 1, #CLOUD_HEIGHTS)
  density = unit(density, 1, "cloud density")
  local half, step = CLOUD_SPAN * 0.5, CLOUD_SPAN / CLOUD_CELLS
  -- Density must not punch 300x300 holes into the deck. Keep one continuous
  -- topology and make lower tiers subtler by lifting and flattening the whole
  -- sheet. Material RGB supplies the matching opaque visual attenuation.
  local height = CLOUD_HEIGHTS[layer] + (1 - density) * 96
  local lift_scale = 0.8 + density * 0.2
  local function lift(x, z)
    local rx, rz = x / half, z / half
    local radius = math.min(1.2, math.sqrt(rx * rx + rz * rz))
    return height + radius * radius * CLOUD_LIFT * lift_scale
  end
  local function emit(grid_x, grid_z)
    local x0, z0 = -half + grid_x * step, -half + grid_z * step
    local x1, z1 = x0 + step, z0 + step
    builder:quad_uv(
      { x0, lift(x0, z1), z1 }, { x1, lift(x1, z1), z1 },
      { x1, lift(x1, z0), z0 }, { x0, lift(x0, z0), z0 }, FACE_SHADE[3],
      { 0, 1 }, { 1, 1 }, { 1, 0 }, { 0, 0 }
    )
  end
  for grid_z = 0, CLOUD_CELLS - 1 do
    for grid_x = 0, CLOUD_CELLS - 1 do
      local x0, z0 = -half + grid_x * step, -half + grid_z * step
      local x1, z1 = x0 + step, z0 + step
      local middle_x, middle_z = (x0 + x1) * 0.5 / half, (z0 + z1) * 0.5 / half
      if math.sqrt(middle_x * middle_x + middle_z * middle_z) <= 1.02 then
        emit(grid_x, grid_z)
      end
    end
  end
end

local function add_pyramid(builder, x, y, z, width, height, depth)
  width, height, depth = positive(width, 1, "pyramid width"),
    positive(height, 1, "pyramid height"), positive(depth, width, "pyramid depth")
  local hw, hd = width * 0.5, depth * 0.5
  local p1, p2 = { x - hw, y, z - hd }, { x + hw, y, z - hd }
  local p3, p4, top = { x + hw, y, z + hd }, { x - hw, y, z + hd }, { x, y + height, z }
  builder:quad(p1, p2, p3, p4, FACE_SHADE[4])
  builder:triangle(p1, p2, top, FACE_SHADE[6])
  builder:triangle(p2, p3, top, FACE_SHADE[1])
  builder:triangle(p3, p4, top, FACE_SHADE[5])
  builder:triangle(p4, p1, top, FACE_SHADE[2])
end

local function item_position(item)
  if type(item) ~= "table" then error("draw item must be a table", 3) end
  return finite(item.x or 0, "item.x"), finite(item.y or 0, "item.y"),
    finite(item.z or 0, "item.z")
end

local function integer_or_nil(value)
  value = tonumber(value)
  if not value or value ~= value or value == math.huge or value == -math.huge then
    return nil
  end
  return math.floor(value)
end

-- KFP marks only its interior box batches as player-relative cutaways. The
-- normalized public world view carries both ends of this comparison, so the
-- renderer does not need host-private state. Missing coordinates fail open:
-- geometry stays visible instead of making a room disappear on weak context.
local function cutaway_player(prototype, context)
  if type(prototype) ~= "table" or prototype.cutaway ~= true then
    return nil, nil
  end
  local interior = prototype.primitive == "box"
    and (prototype.role == "ceiling" or prototype.role == "wall")
  local canopy = prototype.primitive == "canopy"
  if not interior and not canopy then
    return nil, nil
  end
  local world = type(context) == "table" and context.world or nil
  if canopy and (type(world) ~= "table" or world.mode ~= "first_person") then
    return nil, nil
  end
  local player = type(world) == "table" and world.player or nil
  if type(player) ~= "table" then return nil, nil end
  return integer_or_nil(player.cellX), integer_or_nil(player.cellZ)
end

local function item_is_cutaway(item, player_x, player_z, role)
  if player_x == nil or player_z == nil or type(item) ~= "table" then return false end
  local cell_x, cell_z = integer_or_nil(item.cellX), integer_or_nil(item.cellZ)
  if cell_x == nil or cell_z == nil then return false end
  -- The ceiling opens a local square above the player. Boundary walls use
  -- the legacy Sims cross-section: the player's row and rows south of it
  -- melt, while the far/north shell stays visible. Applying the ceiling
  -- radius to walls can remove every wall of a small room.
  if role == "wall" then return cell_z >= player_z end
  return math.abs(player_x - cell_x) <= CUTAWAY_RADIUS_CELLS
    and math.abs(player_z - cell_z) <= CUTAWAY_RADIUS_CELLS
end

local function facing_yaw(value)
  value = type(value) == "string" and value:lower() or "south"
  if value == "north" or value == "up" then return math.pi end
  if value == "east" or value == "right" then return math.pi * 0.5 end
  if value == "west" or value == "left" then return -math.pi * 0.5 end
  return 0
end

local function emit_prototype(builder, prototype, item, context)
  prototype = type(prototype) == "table" and prototype or {}
  local primitive = prototype.primitive
  if type(primitive) ~= "string" or primitive == "" then
    error("instance prototype needs a primitive", 3)
  end
  local x, y, z = item_position(item)
  local size = positive(context and context.world and context.world.cellSize, 16, "cell size")

  if primitive == "box" then
    add_box(builder, x, y, z, prototype.width or size, prototype.height or size,
      prototype.depth or size)
  elseif primitive == "plane" then
    add_plane(builder, x, y, z, prototype.width or size, prototype.depth or size)
  elseif primitive == "door_frame" then
    local width, height, post = size, size * 1.45, math.max(1, size * 0.12)
    add_box(builder, x - width * 0.5 + post * 0.5, y + height * 0.5, z, post, height, post)
    add_box(builder, x + width * 0.5 - post * 0.5, y + height * 0.5, z, post, height, post)
    add_box(builder, x, y + height - post * 0.5, z, width, post, post)
  elseif primitive == "window" or primitive == "poster" then
    add_vertical(builder, x, y, z, size * 0.65, size * 0.55,
      facing_yaw(item.facing))
  elseif primitive == "rail" then
    add_box(builder, x, y + size * 0.25, z, size, size * 0.5, math.max(1, size * 0.1))
  elseif primitive == "fixture" or primitive == "sconce" then
    add_box(builder, x, y, z, size * 0.25, size * 0.25, size * 0.25)
  elseif primitive == "grass_clump" then
    add_crossed(builder, x, y, z, prototype.width or size, size * 0.32)
  elseif primitive == "canopy" then
    add_box(builder, x, y, z, prototype.width or size * 1.4, size * 0.45,
      prototype.width or size * 1.4)
  elseif primitive == "vine" then
    add_crossed(builder, x, y - size, z, size * 0.22, size)
  elseif primitive == "cave_roof" then
    add_box(builder, x, y, z, prototype.width or size, math.max(1, size * 0.15),
      prototype.depth or size)
  elseif primitive == "mountain" then
    add_pyramid(builder, x, y, z, size, size * (item.summit and 2.6 or 1.8), size)
  elseif primitive == "hood" then
    add_box(builder, x, y + size * 0.6, z, size, size * 1.2, size)
  elseif primitive == "umbrella" then
    add_pyramid(builder, x, y, z, size * 0.9, size * 0.24, size * 0.9)
    add_box(builder, x, y - size * 0.35, z, math.max(0.5, size * 0.05), size * 0.7,
      math.max(0.5, size * 0.05))
  elseif primitive == "raised_structure" then
    error("raised_structure requires the terrain_patch capability", 3)
  elseif primitive == "shadow_caster" then
    error("shadow_caster is not supported by this host adapter", 3)
  else
    error("unsupported declarative primitive: " .. primitive, 3)
  end
end

local function emit_mesh_geometry(builder, geometry, context)
  if type(geometry) ~= "table" then error("mesh command needs geometry", 3) end
  local primitive = geometry.primitive
  local world = context and context.world or {}
  local size = positive(world.cellSize, 16, "cell size")
  local width = positive(world.width, 1, "world width") * size
  local depth = positive(world.height, 1, "world height") * size
  local cx, cz = width * 0.5, depth * 0.5

  if primitive == "box" then
    add_box(builder, geometry.x or 0, geometry.y or 0, geometry.z or 0,
      geometry.width, geometry.height, geometry.depth)
  elseif primitive == "plane" then
    add_plane(builder, geometry.x or 0, geometry.y or 0, geometry.z or 0,
      geometry.width, geometry.depth)
  elseif primitive == "world_apron" then
    local skirt = positive(geometry.skirtDepth, size * 8, "skirt depth")
    local thick = math.max(1, size * 0.125)
    add_box(builder, cx, -skirt * 0.5, -thick * 0.5, width + thick * 2, skirt, thick)
    add_box(builder, cx, -skirt * 0.5, depth + thick * 0.5, width + thick * 2, skirt, thick)
    add_box(builder, -thick * 0.5, -skirt * 0.5, cz, thick, skirt, depth)
    add_box(builder, width + thick * 0.5, -skirt * 0.5, cz, thick, skirt, depth)
  elseif primitive == "panorama" then
    add_panorama(builder, geometry.deepSkirt == true)
  elseif primitive == "cloud_layer" then
    add_cloud_layer(builder, geometry.layer, geometry.density)
  elseif primitive == "rainbow" then
    add_vertical(builder, cx, size * 2, cz - depth * 0.45, math.max(size * 8, width * 0.6),
      size * 5, 0)
  else
    error("unsupported declarative mesh: " .. tostring(primitive), 3)
  end
end

local function procedural_items(command, context, limit)
  local procedural = command.procedural
  if type(procedural) ~= "table" or procedural.kind ~= "stars" then return nil end
  local count = bounded_integer(procedural.count, 24, 1, limit)
  local seed = bounded_integer(procedural.seed, 1, 0, 2147483646) + 1
  local world = context.world or {}
  local width = math.max(16, finite(world.width or 1, "world width") * finite(world.cellSize or 16, "cell size"))
  local depth = math.max(16, finite(world.height or 1, "world height") * finite(world.cellSize or 16, "cell size"))
  local items = {}
  local function unit()
    seed = (seed * 48271) % 2147483647
    return seed / 2147483647
  end
  for index = 1, count do
    items[index] = {
      x = unit() * width,
      y = finite(world.cellSize or 16, "cell size") * (5 + unit() * 6),
      z = unit() * depth,
      width = 0.8 + unit() * 1.5,
      height = 0.8 + unit() * 1.5,
    }
  end
  return items
end

local function billboard_size(material, item, context)
  local size = finite(context.world and context.world.cellSize or 16, "cell size")
  local lower = material:lower()
  local width, height = size * 0.22, size * 0.22
  if lower:find("rain", 1, true) then width, height = 0.6, size * 0.9 end
  if lower:find("bird", 1, true) then width, height = size * 0.65, size * 0.35 end
  if lower:find("aircraft", 1, true) then width, height = size * 1.4, size * 0.45 end
  if lower:find("smoke", 1, true) or lower:find("shaft", 1, true) then
    width, height = size * 0.5, size * 1.8
  end
  return positive(item.width, width, "billboard width"),
    positive(item.height, item.height or height, "billboard height")
end

function Renderer.new(options)
  options = options or {}
  local voxel3d = options.voxel3d or V.require("Voxel3D")
  if type(voxel3d) ~= "table" or type(voxel3d.newMesh) ~= "function"
      or type(voxel3d.draw) ~= "function" then
    return nil, "Voxel Companion renderer needs Voxel3D.newMesh and Voxel3D.draw"
  end
  return setmetatable({
    _voxel3d = voxel3d,
    _mat4 = options.mat4 or V.require("Mat4"),
    _graphics = options.graphics or (love and love.graphics),
    _max_cache = bounded_integer(options.max_cache_entries, DEFAULT_MAX_CACHE, 1, MAX_CACHE),
    _max_cache_bytes = bounded_integer(
      options.max_cache_bytes,
      DEFAULT_MAX_CACHE_BYTES,
      1024,
      MAX_CACHE_BYTES
    ),
    _max_items = bounded_integer(options.max_items, DEFAULT_MAX_ITEMS, 1, MAX_ITEMS),
    _max_vertices = bounded_integer(options.max_vertices, DEFAULT_MAX_VERTICES, 24, MAX_VERTICES),
    _cache = {},
    _cache_count = 0,
    _cache_bytes = 0,
    _cache_sequence = 0,
    _disposed = false,
    _translucent = false,
    _background = false,
  }, Renderer)
end

function Renderer:_release(entry)
  local mesh = entry and entry.mesh
  if mesh and type(mesh.release) == "function" then pcall(mesh.release, mesh) end
  if entry then entry.mesh = nil end
end

function Renderer:_remove(key)
  local entry = self._cache[key]
  if not entry then return false end
  self._cache[key] = nil
  self._cache_count = math.max(0, self._cache_count - 1)
  self._cache_bytes = math.max(0, self._cache_bytes - (entry.cost or 0))
  self:_release(entry)
  return true
end

function Renderer:_evictFor(cost)
  while self._cache_count >= self._max_cache
      or self._cache_bytes + cost > self._max_cache_bytes do
    local oldest_key, oldest_entry
    for key, entry in pairs(self._cache) do
      if not oldest_entry or entry.last < oldest_entry.last then
        oldest_key, oldest_entry = key, entry
      end
    end
    if not oldest_entry then return end
    self:_remove(oldest_key)
  end
end

function Renderer:_cached(command, context, build, variant)
  if self._disposed then return nil, "Voxel Companion renderer is disposed" end
  local key, key_error = cache_key(command)
  if not key then return nil, key_error end
  local signature = content_signature(command, context)
  if variant ~= nil then key = key .. "\0" .. tostring(variant) end
  self._cache_sequence = self._cache_sequence + 1
  local entry = self._cache[key]
  if entry then
    if entry.signature ~= signature then
      return nil, "draw cache key content collision"
    end
    if not entry.mesh then return nil, "draw cache entry has no mesh" end
    entry.last = self._cache_sequence
    return entry.mesh
  end

  local mesh, err, cost = build()
  if not mesh then return nil, err end
  cost = bounded_integer(cost, MESH_OVERHEAD_BYTES, 1, MAX_CACHE_BYTES + 1)
  if cost > self._max_cache_bytes then
    self:_release({ mesh = mesh })
    return nil, "declarative mesh exceeds host cache byte limit"
  end
  self:_evictFor(cost)
  self._cache[key] = {
    mesh = mesh,
    signature = signature,
    last = self._cache_sequence,
    cost = cost,
  }
  self._cache_count = self._cache_count + 1
  self._cache_bytes = self._cache_bytes + cost
  return mesh
end

function Renderer:_finish(builder)
  if #builder.vertices == 0 then return nil, "declarative draw produced no geometry" end
  local vertex_count, index_count = #builder.vertices, #builder.indices
  local mesh = self._voxel3d.newMesh(builder.vertices, builder.indices)
  if not mesh then return nil, "host could not allocate a declarative mesh" end
  local cost = MESH_OVERHEAD_BYTES + vertex_count * VERTEX_BYTES + index_count * INDEX_BYTES
  return mesh, nil, cost
end

function Renderer:_setMaterial(material)
  local graphics = self._graphics
  if self._voxel3d.glass then pcall(self._voxel3d.glass, material.atlas) end
  if graphics and type(graphics.setColor) == "function" then
    pcall(graphics.setColor, material.color[1], material.color[2], material.color[3], material.color[4])
  end
end

function Renderer:_restoreMaterial()
  local graphics = self._graphics
  if graphics and type(graphics.setColor) == "function" then pcall(graphics.setColor, 1, 1, 1, 1) end
  if self._voxel3d.glass then pcall(self._voxel3d.glass, true) end
end

function Renderer:_discardMesh(mesh)
  for key, entry in pairs(self._cache) do
    if entry.mesh == mesh then
      self:_remove(key)
      return true
    end
  end
  return false
end

function Renderer:_submit(mesh, material, model, presentation, host_owned)
  if self._disposed then return nil, "Voxel Companion renderer is disposed" end
  local unlit = presentation and presentation.unlit
  self:_setMaterial(material)
  if unlit and self._voxel3d.lighting then pcall(self._voxel3d.lighting, false) end
  if unlit and self._voxel3d.seams then pcall(self._voxel3d.seams, false) end
  local ok, draw_error = pcall(self._voxel3d.draw, mesh, material.texture, model)
  local detached, detach_error = true, nil
  if host_owned and material.texture ~= nil and type(mesh.setTexture) == "function" then
    -- Voxel3D.draw binds its texture to the LOVE mesh. The command texture is
    -- borrowed only for this callback, so remove that attachment immediately,
    -- even when the driver draw throws. The mesh cache must contain geometry,
    -- never an extension-owned image handle.
    detached, detach_error = pcall(mesh.setTexture, mesh)
  end
  if not detached then self:_discardMesh(mesh) end
  if unlit and self._voxel3d.lighting then pcall(self._voxel3d.lighting, true) end
  if unlit and self._voxel3d.seams then pcall(self._voxel3d.seams, true) end
  self:_restoreMaterial()
  if not detached then
    local detail = "could not detach borrowed texture: " .. tostring(detach_error)
    if not ok then detail = tostring(draw_error) .. "; " .. detail end
    error(detail, 0)
  end
  if not ok then error(draw_error, 0) end
  return true
end

function Renderer:_skyModel(context, parallax, seed)
  local world = type(context) == "table" and context.world or nil
  local player = type(world) == "table" and world.player or nil
  local translate = self._mat4 and self._mat4.translate
  if type(player) ~= "table" or type(translate) ~= "function" then return nil end
  local factor = 1
  if parallax ~= nil then
    factor = 1 - math.max(-2, math.min(2, finite(parallax, "cloud parallax")))
  end
  local offset_x, offset_z = 0, 0
  if seed ~= nil then
    local state = math.floor(finite(seed, "cloud seed")) % 2147483647
    state = (state * 48271 + 12820163) % 2147483647
    offset_x = (state / 2147483647 - 0.5) * (CLOUD_SPAN / CLOUD_CELLS)
    state = (state * 48271 + 44488) % 2147483647
    offset_z = (state / 2147483647 - 0.5) * (CLOUD_SPAN / CLOUD_CELLS)
  end
  return translate(finite(player.x or 0, "player.x") * factor + offset_x, 0,
    finite(player.z or 0, "player.z") * factor + offset_z)
end

function Renderer:resolveMaterial(material, context)
  if type(material) ~= "string" or material == "" then return nil end
  local info = material_info({ material = material }, context or {})
  return {
    id = info.id,
    texture = info.texture,
    color = { info.color[1], info.color[2], info.color[3], info.color[4] },
    atlas = info.atlas,
  }
end

function Renderer:mesh(command, context)
  if self._disposed then return nil, "Voxel Companion renderer is disposed" end
  if type(command) ~= "table" then return nil, "mesh command must be a table" end
  local material = material_info(command, context or {})
  local resource = command.mesh or command.resource
  if resource ~= nil then
    if material.texture ~= nil then
      return nil, "direct opaque mesh/resource cannot use a borrowed texture"
    end
    return self:_submit(resource, material, command.model)
  end
  local geometry = type(command.geometry) == "table" and command.geometry or {}
  if geometry.primitive == "cloud_layer" and command.texture == nil then
    return nil, "cloud_layer geometry requires a binary-coverage texture"
  end
  if geometry.primitive == "panorama" then
    -- Keep presentation alpha opaque. The borrowed image alone defines the
    -- horizon silhouette; partial material alpha becomes ordered coverage on
    -- voxel shaders and caused the visible checkerboard bands.
    material.color = geometry.distanceHaze == true
      and { 0.92, 0.94, 0.98, 1 } or { 1, 1, 1, 1 }
  elseif geometry.primitive == "cloud_layer" then
    local density = unit(geometry.density, 1, "cloud density")
    material.color = { 0.72 + density * 0.21, 0.82 + density * 0.14, 1, 1 }
    if density == 0 then return true end
  end
  local mesh, err = self:_cached(command, context or {}, function()
    local builder = new_builder(material.uv, self._max_vertices)
    emit_mesh_geometry(builder, geometry, context or {})
    return self:_finish(builder)
  end)
  if not mesh then return nil, err end
  if geometry.primitive == "panorama" then
    return self:_submit(mesh, material, self:_skyModel(context), { unlit = true }, true)
  elseif geometry.primitive == "cloud_layer" then
    return self:_submit(mesh, material,
      self:_skyModel(context, geometry.parallax, geometry.seed), { unlit = true }, true)
  end
  return self:_submit(mesh, material, nil, nil, true)
end

function Renderer:instances(command, context)
  if self._disposed then return nil, "Voxel Companion renderer is disposed" end
  if type(command) ~= "table" then return nil, "instances command must be a table" end
  context = context or {}
  local count = dense_array(command.items, "instances.items", self._max_items)
  if count == 0 then return true end
  local player_x, player_z = cutaway_player(command.prototype, context)
  local variant
  if player_x ~= nil and player_z ~= nil then
    variant = ("cutaway:%d:%d"):format(player_x, player_z)
    local visible = 0
    for index = 1, count do
      if not item_is_cutaway(command.items[index], player_x, player_z,
          command.prototype.role or command.prototype.primitive) then
        visible = visible + 1
      end
    end
    if visible == 0 then return true end
  end
  local material = material_info(command, context)
  local mesh, err = self:_cached(command, context, function()
    local builder = new_builder(material.uv, self._max_vertices)
    for index = 1, count do
      local item = command.items[index]
      if not item_is_cutaway(item, player_x, player_z,
          command.prototype.role or command.prototype.primitive) then
        emit_prototype(builder, command.prototype, item, context)
      end
    end
    return self:_finish(builder)
  end, variant)
  if not mesh then return nil, err end
  return self:_submit(mesh, material, nil, nil, true)
end

function Renderer:billboards(command, context)
  if self._disposed then return nil, "Voxel Companion renderer is disposed" end
  if type(command) ~= "table" then return nil, "billboards command must be a table" end
  context = context or {}
  local items = command.items or procedural_items(command, context, self._max_items)
  local count = dense_array(items, "billboards.items", self._max_items)
  if count == 0 then return true end
  local material = material_info(command, context)
  local mesh, err = self:_cached(command, context, function()
    local builder = new_builder(material.uv, self._max_vertices)
    for index = 1, count do
      local item = items[index]
      local x, y, z = item_position(item)
      local width, height = billboard_size(material.id, item, context)
      -- Crossed quads are camera-independent. They retain a one-call batch and
      -- avoid rebuilding thousands of vertices when first-person yaw changes.
      add_crossed(builder, x, y, z, width, height)
    end
    return self:_finish(builder)
  end)
  if not mesh then return nil, err end
  return self:_submit(mesh, material, nil, nil, true)
end

function Renderer:beginPhase(phase)
  if self._disposed then error("Voxel Companion renderer is disposed", 2) end
  self._translucent = phase == "translucent_after_actors"
  self._background = phase == "background"
  if self._background and self._graphics and type(self._graphics.setDepthMode) == "function" then
    self._graphics.setDepthMode("lequal", false)
  elseif self._translucent and self._graphics and type(self._graphics.setDepthMode) == "function" then
    self._graphics.setDepthMode("lequal", false)
  end
end

function Renderer:endPhase()
  if (self._translucent or self._background) and self._voxel3d.depth then
    pcall(self._voxel3d.depth, "test")
  end
  self._translucent = false
  self._background = false
  self:_restoreMaterial()
end

function Renderer:invalidate()
  for key, entry in pairs(self._cache) do
    self:_release(entry)
    self._cache[key] = nil
  end
  self._cache_count = 0
  self._cache_bytes = 0
  return true
end

function Renderer:dispose()
  if self._disposed then return true end
  self:invalidate()
  self._disposed = true
  return true
end

function Renderer:status()
  return {
    cacheEntries = self._cache_count,
    maxCacheEntries = self._max_cache,
    cacheBytes = self._cache_bytes,
    maxCacheBytes = self._max_cache_bytes,
    maxItems = self._max_items,
    maxVertices = self._max_vertices,
    disposed = self._disposed,
  }
end

return Renderer
