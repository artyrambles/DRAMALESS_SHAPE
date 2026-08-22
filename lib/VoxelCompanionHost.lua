-- DRAMALESS_SHAPE adapter for Voxel Companion API v1.
--
-- The adapter owns the bridge, not the extension. It exposes bounded, borrowed
-- facades and calls extensions only from seams in the existing voxel pipeline.
-- It never registers a second pipeline and never takes drawWorld ownership.

local V = ...

local CompanionApi = V.require("VoxelCompanionApi")

local Host = {}
Host.__index = Host

Host.SAFE_PHASES = {
  background = true,
  opaque_after_terrain = true,
  translucent_after_actors = true,
}

Host.CAPABILITIES = {
  "render_phases",
  "camera_delta",
  "world_snapshot",
  "quality_tier",
  "integrity_status",
}

Host.LEGACY_MARKERS = {
  "Ceiling.draw",
}

Host.LIMITS = {
  cells = 262144,
  actors = 2048,
  neighbors = 8,
  drawCommandsPerFrame = 4096,
}

local RAW_SHAPE_TAGS = {
  cylinder = true,
  canopy = true,
  stump = true,
  planter = true,
  cliff = true,
  roof = true,
}

local MOUNTAIN_CANDIDATE_KINDS = {
  wall = true,
  cliff = true,
  rock = true,
}

local CARDINAL_DELTAS = {
  { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 },
}

local function finite(value, fallback)
  value = tonumber(value)
  if not value or value ~= value or value == math.huge or value == -math.huge then
    return fallback
  end
  return value
end

local function integer(value, fallback)
  value = finite(value, fallback)
  return value == nil and nil or math.floor(value)
end

local function copy_vector(value, fallback)
  value = type(value) == "table" and value or fallback or {}
  return {
    finite(value[1] or value.x, 0),
    finite(value[2] or value.y, 0),
    finite(value[3] or value.z, 0),
  }
end

local function copy_table(source)
  local out = {}
  for key, value in pairs(source or {}) do out[key] = value end
  return out
end

local function safe_call(object, name, ...)
  local method = object and object[name]
  if type(method) ~= "function" then return nil end
  local ok, value = pcall(method, object, ...)
  if not ok then return nil end
  return value
end

local function normalized_game_id(value)
  value = type(value) == "string" and value:lower() or ""
  if value:find("yellow", 1, true) then return "yellow" end
  if value:find("blue", 1, true) then return "blue" end
  return "red"
end

local function normalized_facing(value)
  value = type(value) == "string" and value:lower() or "down"
  if value == "north" then return "up" end
  if value == "south" then return "down" end
  if value == "east" then return "right" end
  if value == "west" then return "left" end
  if value ~= "up" and value ~= "down" and value ~= "left" and value ~= "right" then
    return "down"
  end
  return value
end

local function map_id(map)
  local value = map and (map.id or (map.def and map.def.id))
  if type(value) == "string" and value ~= "" then return value end
  if type(value) == "number" then return tostring(value) end
  return nil
end

local function vector_add(a, b)
  return { a[1] + b[1], a[2] + b[2], a[3] + b[3] }
end

local function vector_sub(a, b)
  return { a[1] - b[1], a[2] - b[2], a[3] - b[3] }
end

local function vector_dot(a, b)
  return a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
end

local function vector_cross(a, b)
  return {
    a[2] * b[3] - a[3] * b[2],
    a[3] * b[1] - a[1] * b[3],
    a[1] * b[2] - a[2] * b[1],
  }
end

local function vector_scale(value, scale)
  return { value[1] * scale, value[2] * scale, value[3] * scale }
end

local function vector_length(value)
  return math.sqrt(vector_dot(value, value))
end

local function vector_normalize(value, fallback)
  local length = vector_length(value)
  if length < 1e-9 then return copy_vector(fallback or { 0, 1, 0 }) end
  return vector_scale(value, 1 / length)
end

local function rotate_axis(value, axis, angle)
  if angle == 0 then return copy_vector(value) end
  axis = vector_normalize(axis, { 0, 1, 0 })
  local cosine, sine = math.cos(angle), math.sin(angle)
  return vector_add(
    vector_add(vector_scale(value, cosine), vector_scale(vector_cross(axis, value), sine)),
    vector_scale(axis, vector_dot(axis, value) * (1 - cosine))
  )
end

local function method_arguments(facade, first, second, third)
  if first == facade then return second, third end
  return first, second
end

local function default_logger(V, event)
  local log = V and V.log
  if not (log and type(log.event) == "function") then return end
  pcall(log.event, log, "companion", event.code or "event", {
    level = event.level,
    message = event.message,
    extension = event.extension,
    stage = event.stage,
  })
end

-- Read-only check. The adapter never deletes, rewrites, or migrates a legacy
-- patch. It only declines to export the API when the known source marker is
-- present, which prevents the old file-splice path and the API path combining.
function Host.checkLegacySource(read_source)
  if type(read_source) ~= "function" then
    return nil, "legacy marker check needs a read function"
  end
  local ok, source = pcall(read_source, "lib/VoxelScene.lua")
  if not ok or type(source) ~= "string" then
    return nil, "cannot verify lib/VoxelScene.lua for legacy KFP markers"
  end
  for _, marker in ipairs(Host.LEGACY_MARKERS) do
    if source:find(marker, 1, true) then
      return nil, "legacy KFP file patch marker found: " .. marker
    end
  end
  return true
end

local function make_facades(self)
  local world, materials, draw, quality, integrity = {}, {}, {}, {}, {}

  world.snapshot = function()
    return self:_snapshot(self._current_state)
  end
  world.revision = function()
    return self._world_revision
  end

  materials.resolve = function(first, second, third)
    local material, context = method_arguments(materials, first, second, third)
    if type(material) ~= "string" or material == "" then
      error("material id must be a non-empty string", 2)
    end
    if not self._render then error("materials are available only during a render callback", 2) end
    local resolver = self._backend and self._backend.resolveMaterial
    if type(resolver) ~= "function" then return nil end
    return resolver(self._backend, material, self:_backendContext(context))
  end
  materials.atlas = function()
    return self._render and self._render.atlas or nil
  end

  quality.current = function()
    return self:_quality()
  end
  quality.tier = function()
    return self:_quality().resolved
  end
  quality.getTier = quality.tier

  integrity.host = function()
    return {
      id = self._host_id,
      version = self._host_version,
      api = CompanionApi.VERSION,
    }
  end
  integrity.supportsPhase = function(first, second)
    local phase = first == integrity and second or first
    return Host.SAFE_PHASES[phase] == true
  end
  integrity.limits = function()
    return copy_table(Host.LIMITS)
  end
  integrity.legacyPatchDetected = function()
    return false
  end
  integrity.features = function()
    return {
      terrainPatch = false,
      shadowCasters = false,
      battleOpaque = false,
      lights = false,
      postprocess = false,
      readOnlyLegacyCheck = true,
    }
  end
  integrity.status = function()
    return {
      clean = true,
      legacyMarkers = false,
      host = self._host_id,
      version = self._host_version,
      api = CompanionApi.VERSION,
    }
  end

  draw.mesh = function(command, context)
    return self:_draw("mesh", command, context)
  end
  draw.instances = function(command, context)
    return self:_draw("instances", command, context)
  end
  draw.billboards = function(command, context)
    return self:_draw("billboards", command, context)
  end

  return {
    world = world,
    materials = materials,
    draw = draw,
    quality = quality,
    integrity = integrity,
  }
end

function Host.new(options)
  options = options or {}
  local mod = options.mod or V.mod
  if type(mod) ~= "table" then return nil, "Voxel Companion host needs the mod object" end

  local read_source = options.read_source or function(path) return mod:read(path) end
  local clean, legacy_error = Host.checkLegacySource(read_source)
  if not clean then return nil, legacy_error end

  local backend = options.backend
  if not backend then
    local Renderer = V.require("VoxelCompanionRenderer")
    local renderer_error
    backend, renderer_error = Renderer.new({
      voxel3d = options.voxel3d or V.require("Voxel3D"),
      mat4 = options.mat4 or V.require("Mat4"),
      max_cache_entries = options.max_cache_entries,
      max_cache_bytes = options.max_cache_bytes,
      max_items = options.max_draw_items,
      max_vertices = options.max_draw_vertices,
    })
    if not backend then return nil, renderer_error end
  end

  local self = setmetatable({
    _mod = mod,
    _host_id = options.host_id or mod.id or "DRAMALESS_SHAPE",
    _host_version = options.host_version
      or (mod.exports and mod.exports.version) or "0.0.0",
    _backend = backend,
    _log = options.logger or function(event) default_logger(V, event) end,
    _clock = options.clock or os.clock,
    _voxel3d = options.voxel3d or V.require("Voxel3D"),
    _voxel = options.voxel or V.require("VoxelState"),
    _quality_module = options.quality or V.require("Quality"),
    _tile_shape = options.tile_shape or V.require("TileShape"),
    _ground_at = options.ground_at,
    _mode = options.mode,
    _game_id = options.game_id,
    _game = nil,
    _current_state = nil,
    _current_map = nil,
    _world_revision = 0,
    _world_notified_revision = -1,
    _world_dirty = true,
    _snapshot_cache = nil,
    _snapshot_map = nil,
    _snapshot_revision = -1,
    _frame_sequence = 0,
    _last_dt = 0,
    _last_level = 0,
    _render = nil,
    _render_context = nil,
    _camera_restore = nil,
    _draw_count = 0,
    _disposed = false,
  }, Host)

  self._services = make_facades(self)
  self._dispatcher = CompanionApi.new({
    host_id = self._host_id,
    host_version = self._host_version,
    capabilities = Host.CAPABILITIES,
    max_extensions = options.max_extensions or 64,
    max_errors = options.max_errors or 64,
    clock = self._clock,
    logger = function(event)
      self:_emit("error", "extension-fault", tostring(event.message or "extension fault"), {
        extension = event.extension,
        stage = event.stage,
      })
    end,
  })

  local attached, attach_error = self._dispatcher:attach(self._services)
  if not attached then
    self:_releaseBackend("attach-failed")
    return nil, attach_error
  end

  self._start_context = {
    host = { id = self._host_id, version = self._host_version },
    services = self._services,
    reason = "host-load",
  }
  local started, start_error = self._dispatcher:start(self._start_context)
  if not started then
    self:_releaseBackend("start-failed")
    return nil, start_error
  end

  local provider = self._dispatcher:provider()
  provider.register = function(spec)
    return self:register(spec)
  end
  self._provider = provider
  return self
end

function Host:_emit(level, code, message, fields)
  local event = copy_table(fields)
  event.level, event.code, event.message = level, code, message
  pcall(self._log, event)
end

function Host:_releaseBackend(reason)
  local backend = self._backend
  if not backend then return end
  if type(backend.dispose) == "function" then
    local ok, err = pcall(backend.dispose, backend, reason)
    if not ok then self:_emit("error", "backend-dispose", tostring(err)) end
  elseif type(backend.invalidate) == "function" then
    pcall(backend.invalidate, backend, reason)
  end
end

function Host:provider()
  return self._provider
end

function Host:register(spec)
  if self._disposed then return nil, "Voxel Companion host is disposed" end
  -- The v1 wire vocabulary includes host-optional seams. Reject unsupported
  -- seams at registration so an extension cannot start with handlers that this
  -- host will never call.
  if type(spec) == "table" then
    for _, field in ipairs({ "phases", "render" }) do
      local handlers = spec[field]
      if type(handlers) == "table" then
        for phase, handler in pairs(handlers) do
          local supported = phase == "update" or phase == "map_changed"
            or Host.SAFE_PHASES[phase] == true
          if handler ~= nil and not supported then
            return nil, ("DRAMALESS_SHAPE does not expose phase %s")
              :format(tostring(phase))
          end
        end
      end
    end
  end
  local context = self:_context("late-register")
  return self._dispatcher:register(spec, context)
end

function Host:setGame(game)
  self._game = game
end

function Host:markWorldDirty(reason)
  local was_dirty = self._world_dirty
  self._world_revision = self._world_revision + 1
  self._world_dirty = true
  self._snapshot_cache = nil
  if not was_dirty then
    self:_emit("info", "world-dirty", tostring(reason or "world-changed"))
  end
end

function Host:_quality()
  local scale = 2
  if self._quality_module and type(self._quality_module.scale) == "function" then
    local ok, value = pcall(self._quality_module.scale)
    if ok then scale = integer(value, 2) end
  end
  local resolved = scale <= 1 and "HIGH" or (scale == 2 and "BALANCED" or "LOW")
  local policy = {
    HIGH = { density = 1.0, drawCallTarget = 48, panoramaWidth = 4096 },
    BALANCED = { density = 0.6, drawCallTarget = 32, panoramaWidth = 2048 },
    LOW = { density = 0.3, drawCallTarget = 20, panoramaWidth = 1024 },
  }
  local out = copy_table(policy[resolved])
  out.resolved, out.hostScale = resolved, scale
  return out
end

function Host:_modeName()
  if type(self._mode) == "function" then
    local ok, value = pcall(self._mode)
    if ok and type(value) == "string" and value ~= "" then return value end
  end
  local voxel = self._voxel
  local level = self._last_level
  if voxel and type(voxel.isFirstPerson) == "function" then
    local ok, value = pcall(voxel.isFirstPerson, level)
    if ok and value then return "first_person" end
  end
  if voxel and type(voxel.isThirdPerson) == "function" then
    local ok, value = pcall(voxel.isThirdPerson, level)
    if ok and value then return "third_person" end
  end
  return "diorama"
end

function Host:_gameId(map)
  if self._game_id then return normalized_game_id(self._game_id) end
  local save = self._game and self._game.save
  local data = self._game and self._game.data
  return normalized_game_id(
    (save and save.version)
      or (data and (data.game or data.version or data.id))
      or (map and map.game)
      or "red"
  )
end

function Host:_worldTags(map)
  local tags = {}
  local def = map and map.def or {}
  local id = (map_id(map) or ""):upper()
  local tileset = tostring(def.tileset or (map and map.tileset and map.tileset.id) or ""):upper()
  local indoor = def.outdoor == false
    or (def.outdoor == nil and tileset ~= "" and tileset ~= "OVERWORLD")
  if indoor then tags.interior, tags.building = true, true end
  if id:find("CAVE", 1, true) or id:find("CAVERN", 1, true)
      or tileset:find("CAVE", 1, true) then
    tags.cave = true
  end
  if id:find("FOREST", 1, true) then tags.forest = true end
  if id:find("LAVENDER", 1, true) then tags.lavender = true end
  if id:find("CITY", 1, true) then tags.city, tags.town = true, true end
  if id:find("TOWN", 1, true) then tags.town = true end
  if id:find("ROUTE", 1, true) then tags.route = true end
  if not indoor then tags.outdoor = true end
  return tags
end

function Host:_shapeAt(map, x, z, shapes, tile)
  if tile == nil or type(shapes) ~= "table" then return nil end
  local at = self._tile_shape and self._tile_shape.at
  if type(at) == "function" then
    -- Map:cellTile is the cell's canonical bottom-left 8x8 tile.  TileShape
    -- uses tile coordinates and the same south row is `z * 2 + 1`.
    local ok, shape = pcall(at, map, shapes, tile, x * 2, z * 2 + 1)
    if ok and type(shape) == "table" then return shape end
  end
  local shape = shapes[tile]
  return type(shape) == "table" and shape or nil
end

function Host:_cell(map, x, z, shapes, world_tags)
  world_tags = world_tags or {}
  local walkable_value = safe_call(map, "isWalkableCell", x, z)
  local water_value = safe_call(map, "isWaterCell", x, z)
  local walkable = walkable_value == true
  local water = water_value == true
  local grass = safe_call(map, "isGrassCell", x, z) == true
  local warp = safe_call(map, "warpAtCell", x, z)
    or safe_call(map, "isWarpTileCell", x, z) == true
  local door = safe_call(map, "isDoorTileCell", x, z) == true
  local tile = safe_call(map, "cellTile", x, z)
  if tile == nil then tile = safe_call(map, "tileAt", x * 2, z * 2 + 1) end
  local shape = self:_shapeAt(map, x, z, shapes, tile)
  local class = shape and shape.class or (water and "water" or (walkable and "ground" or "wall"))
  local is_water = water or class == "water"
  -- A missing or failed collision query is not proof of a solid support.
  local solid = walkable_value == false and not is_water
  local tags = {}
  if world_tags.interior then tags.interior, tags.room = true, true end
  if world_tags.cave then tags.cave = true end
  if world_tags.forest then tags.forest = true end
  if is_water then tags.water = true end
  if grass or class == "grass" then tags.grass = true end
  if RAW_SHAPE_TAGS[class] then tags[class] = true end

  local semantic = type(shape and shape.companion_tags) == "table"
    and shape.companion_tags or {}
  local support_ok = world_tags.outdoor == true and solid and not walkable
    and not is_water
  if support_ok and (class == "tree" or semantic.tree_support == true) then
    tags.tree, tags.tree_support = true, true
  end
  if support_ok and semantic.boulder_tree == true then
    tags.boulder_tree = true
  end
  -- This is an internal candidate until the bounded cluster pass below
  -- verifies it.  It is removed before a snapshot can escape.
  if support_ok and semantic.mountain_seed == true then
    tags.mountain_seed = true
  end
  if warp or door then tags.door = true end
  if solid then tags.object = true end

  local ground = 0
  if type(self._ground_at) == "function" then
    local ok, value = pcall(self._ground_at, map, x, z)
    if ok then ground = finite(value, 0) end
  end
  local tileset = map.tileset or {}
  local tileset_id = tostring(tileset.id or (map.def and map.def.tileset) or "unknown")
  local tile_id = integer(tile, 0)
  return {
    x = x,
    z = z,
    y = ground,
    worldY = ground,
    height = finite(shape and shape.h, 0),
    kind = class,
    material = ("atlas:%s:%d"):format(tileset_id, tile_id),
    atlas = "host:terrain",
    solid = solid,
    walkable = walkable,
    tags = tags,
    metadata = {
      tile = tile_id,
      tileset = tileset_id,
      warp = warp and true or false,
    },
  }
end

-- The public mountain tags reproduce the last safe legacy policy without its
-- source splice.  Exact authored rock seeds vouch for at most two cardinal
-- cells of solid wall/cliff/rock.  Roof proximity rejects every candidate;
-- door proximity rejects non-seed flood cells.  This prevents generic walls,
-- buildings, and roofs from becoming mountains.
function Host:_classifyMountainTags(map, cells, width, height, world_tags)
  local function cell_at(x, z)
    if x < 0 or z < 0 or x >= width or z >= height then return nil end
    return cells[z * width + x + 1]
  end

  local connections = map and map.def and map.def.connections or {}
  local function in_connection_band(cell)
    return (connections.north and cell.z < 2)
      or (connections.south and cell.z > height - 3)
      or (connections.west and cell.x < 2)
      or (connections.east and cell.x > width - 3)
  end

  local roof_near, door_near = {}, {}
  local function mark_near(target, cell)
    for dz = -2, 2 do
      for dx = -2, 2 do
        if dx ~= 0 or dz ~= 0 then
          local x, z = cell.x + dx, cell.z + dz
          if x >= 0 and z >= 0 and x < width and z < height then
            target[z * width + x + 1] = true
          end
        end
      end
    end
  end
  for _, cell in ipairs(cells) do
    if cell.tags.roof then mark_near(roof_near, cell) end
    if cell.tags.door then mark_near(door_near, cell) end
  end

  local candidates, queue = {}, {}
  for index, cell in ipairs(cells) do
    local seed = cell.tags.mountain_seed == true
    cell.tags.mountain_seed = nil
    local candidate = world_tags.outdoor == true and cell.solid == true
      and cell.walkable == false and not cell.tags.water
      and MOUNTAIN_CANDIDATE_KINDS[cell.kind] == true
      and not in_connection_band(cell)
      and not roof_near[index]
      and (seed or not door_near[index])
    if candidate then
      candidates[index] = { cell = cell, seed = seed }
      if seed then
        candidates[index].reach = 0
        queue[#queue + 1] = index
      end
    end
  end

  local head = 1
  while queue[head] do
    local index = queue[head]
    head = head + 1
    local current = candidates[index]
    if current.reach < 2 then
      for _, delta in ipairs(CARDINAL_DELTAS) do
        local x = current.cell.x + delta[1]
        local z = current.cell.z + delta[2]
        if x >= 0 and z >= 0 and x < width and z < height then
          local next_index = z * width + x + 1
          local neighbor = candidates[next_index]
          if neighbor and neighbor.reach == nil then
            neighbor.reach = current.reach + 1
            queue[#queue + 1] = next_index
          end
        end
      end
    end
  end

  if #queue == 0 then return end

  world_tags.mountain = true
  for _, candidate in pairs(candidates) do
    if candidate.reach ~= nil then
      local tags = candidate.cell.tags
      tags.mountain, tags.mountain_support = true, true
      if candidate.seed then tags.mountain_seed = true end
    end
  end
end

function Host:_actors(state, map)
  local actors = {}
  for index, entity in ipairs(type(state.entities) == "table" and state.entities or {}) do
    if index > Host.LIMITS.actors then break end
    local cell_x, cell_z = integer(entity.cellX, 0), integer(entity.cellY, 0)
    local ground = 0
    if type(self._ground_at) == "function" then
      local ok, value = pcall(self._ground_at, map, cell_x, cell_z)
      if ok then ground = finite(value, 0) end
    end
    local actor = {
      id = tostring(entity.id or entity.name or index),
      kind = entity == state.player and "player" or "npc",
      pose = {
        x = finite(entity.px, cell_x * 16) + 8,
        y = ground,
        z = finite(entity.py, cell_z * 16) + 8,
        cellX = cell_x,
        cellZ = cell_z,
        facing = normalized_facing(entity.facing),
      },
      tags = {},
    }
    if entity == state.player then actor.tags.player = true end
    actors[#actors + 1] = actor
  end
  return actors
end

function Host:_neighbors(state)
  local neighbors = {}
  for index, neighbor in ipairs(type(state.neighbors) == "table" and state.neighbors or {}) do
    if index > Host.LIMITS.neighbors then break end
    local id = map_id(neighbor.map)
    if id then
      neighbors[#neighbors + 1] = {
        id = id,
        revision = self._world_revision,
        offsetX = finite(neighbor.ox, 0),
        offsetZ = finite(neighbor.oy, 0),
        atlas = "host:terrain",
        tilesetRevision = tostring(neighbor.map and neighbor.map.tileset
          and neighbor.map.tileset.id or "0"),
        tags = self:_worldTags(neighbor.map),
      }
    end
  end
  return neighbors
end

function Host:_snapshotView(base, state)
  local snapshot = copy_table(base)
  local actors = self:_actors(state, state.map)
  local player = {
    x = 0, y = 0, z = 0, cellX = 0, cellZ = 0, facing = "down",
  }
  for _, actor in ipairs(actors) do
    if actor.tags.player then player = copy_table(actor.pose) break end
  end
  snapshot.mode = self:_modeName()
  snapshot.player = player
  snapshot.actors = actors
  snapshot.neighbors = self:_neighbors(state)
  snapshot.time = finite(self._clock(), 0)
  snapshot.key = table.concat({
    snapshot.game, snapshot.id, snapshot.revision, snapshot.paletteRevision,
    snapshot.tilesetRevision, snapshot.atlasRevision, snapshot.mode, snapshot.weather,
  }, ":")
  return snapshot
end

function Host:_snapshot(state)
  state = state or self._current_state
  local map = state and state.map
  local id = map_id(map)
  if not id then return nil end
  if self._snapshot_cache and self._snapshot_map == map
      and self._snapshot_revision == self._world_revision and not self._world_dirty then
    return self:_snapshotView(self._snapshot_cache, state)
  end

  local width = integer(map.widthCells or (map.def and map.def.width and map.def.width * 2), nil)
  local height = integer(map.heightCells or (map.def and map.def.height and map.def.height * 2), nil)
  if not width or not height or width < 1 or height < 1
      or width * height > Host.LIMITS.cells then
    self:_emit("error", "world-bounds", "world snapshot bounds are invalid", {
      map = id,
      width = width,
      height = height,
    })
    return nil
  end

  local world_tags = self:_worldTags(map)
  local shapes
  if self._tile_shape and type(self._tile_shape.forMap) == "function" then
    local ok, value = pcall(self._tile_shape.forMap, map)
    if ok then shapes = value end
  end
  local cells = {}
  for z = 0, height - 1 do
    for x = 0, width - 1 do
      cells[#cells + 1] = self:_cell(map, x, z, shapes, world_tags)
    end
  end
  self:_classifyMountainTags(map, cells, width, height, world_tags)
  local function cell_at(x, z)
    if x < 0 or z < 0 or x >= width or z >= height then return nil end
    return cells[z * width + x + 1]
  end
  for _, cell in ipairs(cells) do
    if cell.tags.water then world_tags.water = true end
    if cell.tags.grass then world_tags.grass = true end
    if cell.walkable then
      local x, z = cell.x, cell.z
      local shore = (cell_at(x - 1, z) and cell_at(x - 1, z).tags.water)
        or (cell_at(x + 1, z) and cell_at(x + 1, z).tags.water)
        or (cell_at(x, z - 1) and cell_at(x, z - 1).tags.water)
        or (cell_at(x, z + 1) and cell_at(x, z + 1).tags.water)
      if shore then cell.tags.shore, world_tags.shore = true, true end
    end
  end

  local tileset_id = tostring(map.tileset and map.tileset.id
    or (map.def and map.def.tileset) or "0")
  local snapshot = {
    id = id,
    revision = self._world_revision,
    game = self:_gameId(map),
    width = width,
    height = height,
    cellSize = 16,
    paletteRevision = tostring(self._world_revision),
    tilesetRevision = tileset_id,
    atlasRevision = tileset_id .. ":" .. tostring(self._world_revision),
    mode = self:_modeName(),
    tags = world_tags,
    player = {},
    actors = {},
    neighbors = {},
    cells = cells,
    time = 0,
    weather = "clear",
  }
  snapshot.key = table.concat({
    snapshot.game, snapshot.id, snapshot.revision, snapshot.paletteRevision,
    snapshot.tilesetRevision, snapshot.atlasRevision, snapshot.mode, snapshot.weather,
  }, ":")
  self._snapshot_cache = snapshot
  self._snapshot_map = map
  self._snapshot_revision = self._world_revision
  self._world_dirty = false
  return self:_snapshotView(snapshot, state)
end

function Host:_adoptState(state)
  if type(state) ~= "table" or not state.map then return nil end
  local previous_map, previous_id = self._current_map, map_id(self._current_map)
  self._current_state, self._current_map = state, state.map
  if previous_map ~= state.map or previous_id ~= map_id(state.map) then
    self:markWorldDirty("map-changed")
  end
  local snapshot = self:_snapshot(state)
  if snapshot and self._world_notified_revision ~= snapshot.revision then
    local report, err = self._dispatcher:world_changed(snapshot)
    if report then
      self._world_notified_revision = snapshot.revision
    else
      self:_emit("error", "world-change-dispatch", tostring(err))
    end
  end
  return snapshot
end

function Host:_cameraBase(spec)
  local placed = self._voxel3d and self._voxel3d.camera
  if placed then
    return {
      eye = copy_vector(placed.eye),
      focus = copy_vector(placed.focus),
      up = copy_vector(placed.up, { 0, 1, 0 }),
      fov = finite(placed.fov, math.rad(65)),
      curve = placed.curve,
      mode = self:_modeName(),
    }, placed
  end
  local voxel = self._voxel or {}
  local focal = finite(voxel.FOCAL, 1.2)
  local angle = finite(voxel.angle, math.pi / 2)
  local distance = focal * math.max(1, finite(spec.vh, 144))
  local cx, cy = finite(spec.cx, 0), finite(spec.cy, 0)
  return {
    eye = { cx, distance * math.cos(angle), cy + distance * math.sin(angle) },
    focus = { cx, 0, cy },
    up = { 0, math.sin(angle), -math.cos(angle) },
    fov = 2 * math.atan(1 / (2 * focal)),
    curve = nil,
    mode = self:_modeName(),
  }, nil
end

function Host:_cameraWithDelta(base, delta)
  local position = delta.positionDelta or {}
  local rotation = delta.rotationDelta or {}
  local offset = {
    finite(position.x, 0), finite(position.y, 0), finite(position.z, 0),
  }
  local eye = vector_add(base.eye, offset)
  local focus = vector_add(base.focus, offset)
  local direction = vector_sub(focus, eye)
  local up = vector_normalize(base.up, { 0, 1, 0 })
  local yaw = finite(rotation.yaw, 0)
  local pitch = finite(rotation.pitch, 0)
  local roll = finite(rotation.roll, 0)
  direction = rotate_axis(direction, { 0, 1, 0 }, yaw)
  up = rotate_axis(up, { 0, 1, 0 }, yaw)
  local right = vector_normalize(vector_cross(direction, up), { 1, 0, 0 })
  direction = rotate_axis(direction, right, pitch)
  up = rotate_axis(up, right, pitch)
  up = rotate_axis(up, vector_normalize(direction, { 0, 0, 1 }), roll)
  focus = vector_add(eye, direction)
  local fov = base.fov + finite(delta.fovDelta, 0)
  fov = math.max(math.rad(15), math.min(math.rad(120), fov))
  return {
    eye = eye,
    focus = focus,
    up = vector_normalize(up, { 0, 1, 0 }),
    fov = fov,
    curve = base.curve,
    mode = base.mode,
  }
end

function Host:_applyCamera(spec)
  local base, owner = self:_cameraBase(spec)
  self._render_context.camera = base
  local delta, report = self._dispatcher:modifyCamera(base)
  if not delta then
    self:_emit("error", "camera-dispatch", tostring(report))
    return base
  end
  local adjusted = self:_cameraWithDelta(base, delta)
  self._render_context.camera = adjusted

  local changed = math.abs(finite(delta.positionDelta and delta.positionDelta.x, 0)) > 0
    or math.abs(finite(delta.positionDelta and delta.positionDelta.y, 0)) > 0
    or math.abs(finite(delta.positionDelta and delta.positionDelta.z, 0)) > 0
    or math.abs(finite(delta.fovDelta, 0)) > 0
    or math.abs(finite(delta.rotationDelta and delta.rotationDelta.yaw, 0)) > 0
    or math.abs(finite(delta.rotationDelta and delta.rotationDelta.pitch, 0)) > 0
    or math.abs(finite(delta.rotationDelta and delta.rotationDelta.roll, 0)) > 0
  if not changed then return adjusted end

  if owner then
    self._camera_restore = {
      owner = owner,
      eye = owner.eye,
      focus = owner.focus,
      up = owner.up,
      fov = owner.fov,
      curve = owner.curve,
    }
    owner.eye, owner.focus, owner.up = adjusted.eye, adjusted.focus, adjusted.up
    owner.fov, owner.curve = adjusted.fov, adjusted.curve
  else
    self._camera_restore = { owner = false, previous = self._voxel3d.camera }
    self._voxel3d.camera = adjusted
  end
  return adjusted
end

function Host:_restoreCamera()
  local restore = self._camera_restore
  self._camera_restore = nil
  if not restore then return end
  if restore.owner then
    local owner = restore.owner
    owner.eye, owner.focus, owner.up = restore.eye, restore.focus, restore.up
    owner.fov, owner.curve = restore.fov, restore.curve
  else
    self._voxel3d.camera = restore.previous
  end
end

function Host:_frameData(reason)
  local frame = self._render and self._render.frame or {
    sequence = self._frame_sequence,
    dt = self._last_dt,
    level = self._last_level,
    time = finite(self._clock(), 0),
  }
  frame.reason = reason
  frame.qualityTier = self:_quality().resolved
  frame.mode = self:_modeName()
  return frame
end

function Host:_context(reason)
  local snapshot = self:_snapshot(self._current_state)
  return {
    world = snapshot,
    camera = self._render_context and self._render_context.camera or {},
    frame = self:_frameData(reason),
    materials = self._services and self._services.materials or {},
    draw = self._services and self._services.draw or {},
    quality = self:_quality(),
    integrity = self._services and self._services.integrity or {},
    reason = reason,
  }
end

function Host:update(dt, level, state)
  if self._disposed then return nil, "Voxel Companion host is disposed" end
  self._last_dt = math.max(0, math.min(0.25, finite(dt, 0)))
  self._last_level = finite(level, 0)
  local snapshot = self:_adoptState(state)
  if not snapshot then return true end
  local report, err = self._dispatcher:update(self:_frameData("update"))
  if not report then
    self:_emit("error", "update-dispatch", tostring(err))
    return nil, err
  end
  return report
end

function Host:beginWorldFrame(spec)
  if self._disposed then return nil, "Voxel Companion host is disposed" end
  if self._render then return nil, "a Voxel Companion world frame is already active" end
  spec = spec or {}
  local snapshot = self:_adoptState(spec.state)
  if not snapshot then return nil, "world frame needs an active map" end
  self._frame_sequence = self._frame_sequence + 1
  local atlas
  if type(spec.atlasFor) == "function" then
    local ok, value = pcall(spec.atlasFor, spec.state.map)
    if ok then atlas = value end
  else
    atlas = spec.atlas
  end
  local frame = {
    sequence = self._frame_sequence,
    dt = self._last_dt,
    level = self._last_level,
    time = finite(self._clock(), 0),
    width = finite(spec.width, 0),
    height = finite(spec.height, 0),
    viewWidth = finite(spec.vw, 0),
    viewHeight = finite(spec.vh, 0),
  }
  self._render = {
    state = spec.state,
    map = spec.state.map,
    atlas = atlas,
    atlasFor = spec.atlasFor,
    frame = frame,
    phase = "camera",
  }
  self._draw_count = 0
  self._render_context = {
    world = snapshot,
    camera = {},
    frame = frame,
    materials = self._services.materials,
    draw = self._services.draw,
    quality = self:_quality(),
    integrity = self._services.integrity,
    phase = "camera",
  }
  local camera_ok, camera_error = xpcall(function()
    self:_applyCamera(spec)
  end, function(problem)
    if debug and debug.traceback then return debug.traceback(tostring(problem), 2) end
    return tostring(problem)
  end)
  if not camera_ok then
    self:_restoreCamera()
    self._render, self._render_context = nil, nil
    self:_emit("error", "camera-apply", tostring(camera_error))
    return nil, camera_error
  end
  return true
end

function Host:_backendContext(public_context)
  local render = self._render
  return {
    state = render and render.state,
    map = render and render.map,
    atlas = render and render.atlas,
    atlasFor = render and render.atlasFor,
    frame = render and render.frame,
    phase = render and render.phase,
    world = self._render_context and self._render_context.world,
    camera = self._render_context and self._render_context.camera,
    publicContext = public_context,
  }
end

function Host:_draw(kind, command, context)
  if not self._render or not self._render.phase then
    error("draw facade is available only during a render phase", 2)
  end
  if not Host.SAFE_PHASES[self._render.phase] then
    error("draw facade is unavailable in phase " .. tostring(self._render.phase), 2)
  end
  local valid, validation_error = CompanionApi.validate_draw_command(command, kind)
  if not valid then error(tostring(validation_error), 2) end
  if command.phase ~= self._render.phase then
    error("draw command phase does not match the active host phase", 2)
  end
  if type(context) ~= "table" then error("draw command needs its borrowed context", 2) end
  local ok, phase, sequence = pcall(function()
    return context.phase, context.frame and context.frame.sequence
  end)
  if not ok or phase ~= self._render.phase or sequence ~= self._frame_sequence then
    error("draw command used an expired or foreign render context", 2)
  end
  if self._draw_count >= Host.LIMITS.drawCommandsPerFrame then
    error("draw command limit reached for this frame", 2)
  end
  local method = self._backend and self._backend[kind]
  if type(method) ~= "function" then error("host draw backend does not support " .. kind, 2) end
  self._draw_count = self._draw_count + 1
  local result, err = method(self._backend, command, self:_backendContext(context))
  if result ~= true then
    error(tostring(err or (kind .. " draw backend must return true")), 2)
  end
  return true
end

function Host:dispatchRenderPhase(phase)
  if not Host.SAFE_PHASES[phase] then
    return nil, "DRAMALESS_SHAPE does not expose phase " .. tostring(phase)
  end
  if not self._render or not self._render_context then
    return nil, "render phase called outside a world frame"
  end
  self._render.phase = phase
  self._render_context.phase = phase
  local backend = self._backend
  if backend and type(backend.beginPhase) == "function" then
    local ok, err = pcall(backend.beginPhase, backend, phase, self:_backendContext())
    if not ok then
      self:_emit("error", "backend-phase-begin", tostring(err), { phase = phase })
      self._render.phase, self._render_context.phase = nil, nil
      return nil, err
    end
  end
  local dispatch_ok, report, err = pcall(
    self._dispatcher.render,
    self._dispatcher,
    phase,
    self._render_context
  )
  if not dispatch_ok then
    err, report = report, nil
  end
  if backend and type(backend.endPhase) == "function" then
    local ok, close_error = pcall(backend.endPhase, backend, phase, self:_backendContext())
    if not ok then self:_emit("error", "backend-phase-end", tostring(close_error), { phase = phase }) end
  end
  self._render.phase, self._render_context.phase = nil, nil
  if not report then self:_emit("error", "phase-dispatch", tostring(err), { phase = phase }) end
  return report, err
end

function Host:endWorldFrame(reason)
  if not self._render then return true end
  self:_restoreCamera()
  self._render, self._render_context = nil, nil
  return true
end

function Host:invalidate(reason)
  if self._disposed then return true end
  self:endWorldFrame("invalidate")
  local context = self:_context(reason or "host-invalidate")
  local report, err = self._dispatcher:invalidate(context, reason or "host-invalidate")
  if self._backend and type(self._backend.invalidate) == "function" then
    local ok, backend_error = pcall(self._backend.invalidate, self._backend, reason)
    if not ok then self:_emit("error", "backend-invalidate", tostring(backend_error)) end
  end
  return report, err
end

function Host:dispose(reason)
  if self._disposed then return true end
  self:endWorldFrame("dispose")
  local context = self:_context(reason or "host-dispose")
  local report, err = self._dispatcher:dispose(context, reason or "host-dispose")
  self:_releaseBackend(reason or "host-dispose")
  self._disposed = true
  return report, err
end

function Host:status()
  local status = self._dispatcher:status()
  status.safePhases = {
    "background", "opaque_after_terrain", "translucent_after_actors",
  }
  status.worldRevision = self._world_revision
  status.frameSequence = self._frame_sequence
  status.drawCommands = self._draw_count
  return status
end

return Host
