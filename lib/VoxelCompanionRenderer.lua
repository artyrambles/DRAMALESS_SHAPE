-- Bounded renderer for Voxel Companion API v1 command packets.
--
-- Commands remain owned by the extension. This adapter either draws an
-- extension-owned mesh immediately or builds a host-owned, bounded mesh from
-- declarative geometry. Host-owned meshes are released on eviction,
-- invalidation, and disposal. No command table is changed.

local V = ...

local Renderer = {}
Renderer.__index = Renderer

local DEFAULT_MAX_CACHE = 128
local DEFAULT_MAX_ITEMS = 2048
local DEFAULT_MAX_VERTICES = 196608
local MAX_CACHE = 512
local MAX_ITEMS = 8192
local MAX_VERTICES = 786432

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
    local radius = math.max(width, depth) * 0.7 + size * 8
    local height = size * 10
    add_vertical(builder, cx, -size, cz - radius, radius * 2, height, 0)
    add_vertical(builder, cx, -size, cz + radius, radius * 2, height, math.pi)
    add_vertical(builder, cx - radius, -size, cz, radius * 2, height, math.pi * 0.5)
    add_vertical(builder, cx + radius, -size, cz, radius * 2, height, -math.pi * 0.5)
  elseif primitive == "cloud_layer" then
    add_plane(builder, cx, size * (5 + finite(geometry.layer or 1, "cloud layer")), cz,
      width + size * 16, depth + size * 16)
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
    _max_items = bounded_integer(options.max_items, DEFAULT_MAX_ITEMS, 1, MAX_ITEMS),
    _max_vertices = bounded_integer(options.max_vertices, DEFAULT_MAX_VERTICES, 24, MAX_VERTICES),
    _cache = {},
    _cache_sequence = 0,
    _disposed = false,
    _translucent = false,
  }, Renderer)
end

function Renderer:_release(entry)
  local mesh = entry and entry.mesh
  if mesh and type(mesh.release) == "function" then pcall(mesh.release, mesh) end
  if entry then entry.mesh = nil end
end

function Renderer:_evictIfNeeded()
  local count = 0
  for _ in pairs(self._cache) do count = count + 1 end
  if count < self._max_cache then return end
  local oldest_command, oldest_entry
  for command, entry in pairs(self._cache) do
    if not oldest_entry or entry.last < oldest_entry.last then
      oldest_command, oldest_entry = command, entry
    end
  end
  if oldest_entry then
    self:_release(oldest_entry)
    self._cache[oldest_command] = nil
  end
end

function Renderer:_cached(command, signature, build)
  self._cache_sequence = self._cache_sequence + 1
  local entry = self._cache[command]
  if entry and entry.signature == signature and entry.mesh then
    entry.last = self._cache_sequence
    return entry.mesh
  end
  if entry then
    self:_release(entry)
    self._cache[command] = nil
  end
  self:_evictIfNeeded()
  local mesh, err = build()
  if not mesh then return nil, err end
  self._cache[command] = {
    mesh = mesh,
    signature = signature,
    last = self._cache_sequence,
  }
  return mesh
end

function Renderer:_finish(builder)
  if #builder.vertices == 0 then return nil, "declarative draw produced no geometry" end
  local mesh = self._voxel3d.newMesh(builder.vertices, builder.indices)
  if not mesh then return nil, "host could not allocate a declarative mesh" end
  return mesh
end

function Renderer:_signature(kind, command, context, material)
  local world = context.world or {}
  return table.concat({
    kind,
    tostring(world.key or world.id or "world"),
    tostring(world.atlasRevision or "0"),
    material.id,
    tostring(command.geometry or command.prototype or command.items or command.procedural),
  }, "\31")
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

function Renderer:_submit(mesh, material, model)
  if self._disposed then return nil, "Voxel Companion renderer is disposed" end
  self:_setMaterial(material)
  self._voxel3d.draw(mesh, material.texture, model)
  self:_restoreMaterial()
  return 1
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
  if type(command) ~= "table" then return nil, "mesh command must be a table" end
  local material = material_info(command, context or {})
  local resource = command.mesh or command.resource
  if resource ~= nil then
    return self:_submit(resource, material, command.model)
  end
  local signature = self:_signature("mesh", command, context or {}, material)
  local mesh, err = self:_cached(command, signature, function()
    local builder = new_builder(material.uv, self._max_vertices)
    emit_mesh_geometry(builder, command.geometry, context or {})
    return self:_finish(builder)
  end)
  if not mesh then return nil, err end
  return self:_submit(mesh, material)
end

function Renderer:instances(command, context)
  if type(command) ~= "table" then return nil, "instances command must be a table" end
  local count = dense_array(command.items, "instances.items", self._max_items)
  if count == 0 then return true end
  local material = material_info(command, context or {})
  local signature = self:_signature("instances", command, context or {}, material)
  local mesh, err = self:_cached(command, signature, function()
    local builder = new_builder(material.uv, self._max_vertices)
    for index = 1, count do emit_prototype(builder, command.prototype, command.items[index], context or {}) end
    return self:_finish(builder)
  end)
  if not mesh then return nil, err end
  return self:_submit(mesh, material)
end

function Renderer:billboards(command, context)
  if type(command) ~= "table" then return nil, "billboards command must be a table" end
  context = context or {}
  local items = command.items or procedural_items(command, context, self._max_items)
  local count = dense_array(items, "billboards.items", self._max_items)
  if count == 0 then return true end
  local material = material_info(command, context)
  local signature = self:_signature("billboards", command, context, material)
  local mesh, err = self:_cached(command, signature, function()
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
  return self:_submit(mesh, material)
end

function Renderer:beginPhase(phase)
  if self._disposed then error("Voxel Companion renderer is disposed", 2) end
  self._translucent = phase == "translucent_after_actors"
  if self._translucent and self._graphics and type(self._graphics.setDepthMode) == "function" then
    self._graphics.setDepthMode("lequal", false)
  end
end

function Renderer:endPhase()
  if self._translucent and self._voxel3d.depth then pcall(self._voxel3d.depth, "test") end
  self._translucent = false
  self:_restoreMaterial()
end

function Renderer:invalidate()
  for command, entry in pairs(self._cache) do
    self:_release(entry)
    self._cache[command] = nil
  end
  return true
end

function Renderer:dispose()
  if self._disposed then return true end
  self:invalidate()
  self._disposed = true
  return true
end

function Renderer:status()
  local count = 0
  for _ in pairs(self._cache) do count = count + 1 end
  return {
    cacheEntries = count,
    maxCacheEntries = self._max_cache,
    maxItems = self._max_items,
    maxVertices = self._max_vertices,
    disposed = self._disposed,
  }
end

return Renderer
