return function(T)
  local function load_with_argument(relative, argument)
    local source = T.read(relative)
    local chunk, err = loadstring(source, "@" .. relative)
    if not chunk then error(err, 0) end
    return chunk(argument)
  end

  local function load_fixture(relative)
    local source = T.read(relative)
    local chunk, err = loadstring(source, "@" .. relative)
    if not chunk then error(err, 0) end
    return chunk()
  end

  local function load_real_tile_shape()
    return load_with_argument("lib/TileShape.lua", {
      data = function(name)
        T.equal(name, "voxel_heights")
        return load_fixture("data/voxel_heights.lua")
      end,
    })
  end

  local function new_backend()
    local backend = {
      calls = {}, phases = {}, invalidations = 0, disposals = 0,
      releases = 0,
    }
    function backend:beginPhase(phase)
      self.phases[#self.phases + 1] = "begin:" .. phase
    end
    function backend:endPhase(phase)
      self.phases[#self.phases + 1] = "end:" .. phase
    end
    local function draw(self, kind, command, context)
      self.calls[#self.calls + 1] = {
        kind = kind,
        owner = command.owner,
        phase = context.phase,
        sequence = context.frame.sequence,
      }
      return true
    end
    function backend:mesh(command, context) return draw(self, "mesh", command, context) end
    function backend:instances(command, context) return draw(self, "instances", command, context) end
    function backend:billboards(command, context) return draw(self, "billboards", command, context) end
    function backend:resolveMaterial(id) return { id = id, resolved = true } end
    function backend:invalidate()
      self.invalidations = self.invalidations + 1
      return true
    end
    function backend:dispose()
      self.disposals = self.disposals + 1
      return true
    end
    return backend
  end

  local function new_map(id)
    local map = {
      id = id or "PALLET_TOWN",
      widthCells = 2,
      heightCells = 2,
      def = { id = id or "PALLET_TOWN", width = 1, height = 1,
        tileset = "OVERWORLD", outdoor = true },
      tileset = { id = "OVERWORLD", tilesPerRow = 16,
        imageWidth = 128, imageHeight = 48 },
    }
    function map:isWalkableCell(x) return x == 0 end
    function map:isWaterCell(x) return x == 1 end
    function map:isGrassCell(x, z) return x == 0 and z == 1 end
    function map:warpAtCell() return nil end
    function map:isWarpTileCell() return false end
    function map:cellTile(x) return x == 1 and 1 or 0 end
    return map
  end

  local function new_state(id)
    local player = {
      id = "player", cellX = 0, cellY = 1,
      px = 4, py = 20, facing = "north",
    }
    return {
      map = new_map(id),
      player = player,
      entities = { player },
      neighbors = {},
    }
  end

  local function new_environment(T, options)
    options = options or {}
    local API = load_with_argument("lib/VoxelCompanionApi.lua")
    local V = {
      require = function(name)
        if name == "VoxelCompanionApi" then return API end
        error("unexpected module request: " .. tostring(name), 2)
      end,
    }
    local Host = load_with_argument("lib/VoxelCompanionHost.lua", V)
    local backend = options.backend or new_backend()
    local camera = options.camera or {
      eye = { 0, 1, 2 },
      focus = { 0, 1, 3 },
      up = { 0, 1, 0 },
      fov = math.rad(60),
      curve = 0.25,
    }
    local events = {}
    local host, err = Host.new({
      mod = { id = "DRAMALESS_SHAPE", exports = { version = "2.0.3" } },
      host_id = "DRAMALESS_SHAPE",
      host_version = "2.0.3",
      backend = backend,
      voxel3d = { camera = camera },
      voxel = {
        FOCAL = 1.2,
        angle = math.pi / 2,
        isFirstPerson = function() return true end,
        isThirdPerson = function() return false end,
      },
      quality = { scale = function() return options.quality_scale or 2 end },
      tile_shape = options.tile_shape or {
        forMap = function()
          return {
            [0] = { class = "ground", h = 0 },
            [1] = { class = "water", h = -2 },
          }
        end,
      },
      ground_at = function(_, x, z) return x + z end,
      read_source = options.read_source or function()
        return T.read("tests/fixtures/clean_voxel_scene.lua")
      end,
      clock = function() return 12.5 end,
      logger = function(event) events[#events + 1] = event end,
    })
    return {
      API = API,
      Host = Host,
      host = host,
      error = err,
      backend = backend,
      camera = camera,
      events = events,
    }
  end

  local function extension(id, fields)
    fields = fields or {}
    return {
      api = 1,
      id = id,
      version = "1.0.0",
      priority = fields.priority or 0,
      requires = fields.requires or { "render_phases" },
      optional = fields.optional,
      attach = fields.attach,
      worldChanged = fields.worldChanged,
      update = fields.update,
      render = fields.render,
      modifyCamera = fields.modifyCamera,
      invalidate = fields.invalidate,
      dispose = fields.dispose,
      lifecycle = fields.lifecycle,
      phases = fields.phases,
      camera = fields.camera,
      terrain = fields.terrain,
      terrainPatch = fields.terrainPatch,
    }
  end

  local function draw_packet(kind, phase, sequence, fields)
    local command = {
      schemaVersion = 1,
      cacheKey = ("adapter:%s:%d"):format(phase, sequence),
      kind = kind,
      owner = "adapter.test",
      phase = phase,
      sequence = sequence,
      sortKey = ("adapter:%04d"):format(sequence),
      material = "host:test",
    }
    if kind == "mesh" then
      command.geometry = { primitive = "plane", width = 1, depth = 1 }
    elseif kind == "instances" then
      command.prototype = {
        primitive = "box", width = 1, height = 1, depth = 1,
      }
      command.items = { { x = 0, y = 0, z = 0 } }
    elseif kind == "billboards" then
      command.items = { { x = 0, y = 0, z = 0, width = 1, height = 1 } }
    end
    for key, value in pairs(fields or {}) do command[key] = value end
    return command
  end

  local function begin_frame(env, state)
    return env.host:beginWorldFrame({
      state = state,
      width = 640,
      height = 360,
      vw = 160,
      vh = 144,
      cx = 16,
      cy = 16,
      atlasFor = function() return { id = "borrowed-atlas" } end,
    })
  end

  T.test("exports only the safe locked capabilities and normalized facades", function()
    local env = new_environment(T)
    T.truthy(env.host, env.error)
    local provider = env.host:provider()
    T.equal(provider.api, 1)
    T.equal(provider.host.id, "DRAMALESS_SHAPE")
    T.equal(provider.host.version, "2.0.3")
    T.equal(provider.capabilities.world_snapshot, 1)
    T.equal(provider.capabilities.camera_delta, 1)
    T.equal(provider.capabilities.render_phases, 1)
    T.equal(provider.capabilities.quality_tier, 1)
    T.equal(provider.capabilities.integrity_status, 1)
    T.falsy(provider.capabilities.terrain_patch)
    T.falsy(provider.capabilities.shadow_pass)
    T.falsy(provider.capabilities.battle_pass)
    T.falsy(provider.capabilities.materials)
    T.falsy(provider.capabilities.draw)

    local attached
    local handle, err = provider.register(extension("facades", {
      requires = { "world_snapshot", "quality_tier", "integrity_status" },
      attach = function(services)
        attached = {
          world = services.world,
          materials = services.materials,
          draw = services.draw,
          quality = services.quality,
          integrity = services.integrity,
        }
      end,
    }))
    T.truthy(handle, err)
    T.equal(attached.quality:getTier(), "BALANCED")
    T.equal(attached.quality:tier(), "BALANCED")
    T.truthy(attached.integrity:status().clean)
    T.falsy(attached.integrity:status().legacyMarkers)
    T.truthy(attached.integrity:supportsPhase("background"))
    T.falsy(attached.integrity:supportsPhase("shadow_casters"))
  end)

  T.test("refuses legacy splice markers with a read-only check", function()
    local reads = 0
    local before = T.read("tests/fixtures/legacy_kfp_voxel_scene.lua")
    local env = new_environment(T, {
      read_source = function(path)
        reads = reads + 1
        T.equal(path, "lib/VoxelScene.lua")
        return before
      end,
    })
    T.falsy(env.host)
    T.truthy(tostring(env.error):find("Ceiling.draw", 1, true))
    T.equal(reads, 1)
    T.equal(env.backend.disposals, 0)
    T.equal(T.read("tests/fixtures/legacy_kfp_voxel_scene.lua"), before)

    local clean, err = env.Host.checkLegacySource(function() error("read failed") end)
    T.falsy(clean)
    T.truthy(tostring(err):find("cannot verify", 1, true))
  end)

  T.test("builds a bounded world snapshot with ground and shore semantics", function()
    local env = new_environment(T)
    local services
    local changes, updates = {}, 0
    local handle, err = env.host:provider().register(extension("world", {
      requires = { "world_snapshot", "render_phases" },
      attach = function(value)
        services = { world = value.world }
      end,
      worldChanged = function(snapshot)
          changes[#changes + 1] = {
            id = snapshot.id,
            revision = snapshot.revision,
          }
      end,
      update = function(frame)
        T.equal(frame.qualityTier, "BALANCED")
        updates = updates + 1
      end,
    }))
    T.truthy(handle, err)
    local state = new_state("PALLET_TOWN")
    T.truthy(env.host:update(1 / 60, 3, state))
    T.truthy(env.host:update(1 / 60, 3, state))
    T.equal(#changes, 1)
    T.equal(updates, 2)
    local snapshot = services.world:snapshot()
    T.equal(snapshot.id, "PALLET_TOWN")
    T.equal(snapshot.width, 2)
    T.equal(snapshot.height, 2)
    T.equal(#snapshot.cells, 4)
    T.equal(snapshot.cells[3].worldY, 1)
    T.truthy(snapshot.cells[1].tags.shore)
    T.truthy(snapshot.tags.water)
    T.truthy(snapshot.tags.shore)
    T.truthy(snapshot.tags.town)
    T.equal(snapshot.player.facing, "up")

    local cached_cells = snapshot.cells
    state.player.px = 12
    local moved = services.world:snapshot()
    T.equal(moved.cells, cached_cells)
    T.equal(moved.player.x, 20)
    T.equal(moved.revision, snapshot.revision)

    local old_revision = snapshot.revision
    env.host:markWorldDirty("test")
    T.truthy(services.world:snapshot().revision > old_revision)
    T.truthy(env.host:update(1 / 60, 3, state))
    T.equal(#changes, 2)
    T.equal(changes[2].id, "PALLET_TOWN")
    T.truthy(changes[2].revision > old_revision)
    local next_state = new_state("CERULEAN_CITY")
    T.truthy(env.host:update(1 / 60, 3, next_state))
    T.equal(#changes, 3)
    T.equal(changes[3].id, "CERULEAN_CITY")
  end)

  T.test("normalizes exact shape semantics and fails closed on walkable cells", function()
    local shape_at = {}
    local classes = {
      [1] = "tree",
      [2] = "canopy",
      [3] = "stump",
      [4] = "planter",
      [5] = "cliff",
      [6] = "roof",
      [7] = "tree",
      [8] = "tree",
      [9] = "tree",
    }
    local tile_shape = {
      forMap = function()
        local shapes = {}
        for tile, class in pairs(classes) do
          shapes[tile] = { class = class, h = 16 }
        end
        return shapes
      end,
      at = function(_, shapes, tile, tx, ty)
        shape_at[#shape_at + 1] = { tile, tx, ty }
        return shapes[tile]
      end,
    }
    local map = {
      id = "SEMANTIC_CLASSES",
      widthCells = 9,
      heightCells = 1,
      def = { id = "SEMANTIC_CLASSES", width = 4, height = 1,
        tileset = "CUSTOM", outdoor = true },
      tileset = { id = "CUSTOM", imageWidth = 128, imageHeight = 48 },
    }
    function map:isWalkableCell(x)
      if x == 8 then return nil end
      return x == 6
    end
    function map:isWaterCell(x) return x == 7 end
    function map:isGrassCell() return false end
    function map:warpAtCell() return nil end
    function map:isWarpTileCell() return false end
    function map:cellTile(x) return x + 1 end

    local player = { id = "player", cellX = 0, cellY = 0,
      px = 0, py = 0, facing = "south" }
    local state = { map = map, player = player, entities = { player }, neighbors = {} }
    local env = new_environment(T, { tile_shape = tile_shape })
    local services
    local handle, err = env.host:provider().register(extension("semantic-classes", {
      requires = { "world_snapshot" },
      attach = function(value) services = { world = value.world } end,
    }))
    T.truthy(handle, err)
    T.truthy(env.host:update(1 / 60, 1, state))
    local snapshot = services.world:snapshot()

    local function cell(x, tile, class, solid, walkable, tags)
      return {
        x = x, z = 0, y = x, worldY = x, height = 16,
        kind = class,
        material = ("atlas:CUSTOM:%d"):format(tile),
        atlas = "host:terrain",
        solid = solid,
        walkable = walkable,
        tags = tags,
        metadata = { tile = tile, tileset = "CUSTOM", warp = false },
      }
    end
    T.deepEqual(snapshot.cells, {
      cell(0, 1, "tree", true, false,
        { tree = true, tree_support = true, object = true }),
      cell(1, 2, "canopy", true, false,
        { canopy = true, object = true }),
      cell(2, 3, "stump", true, false,
        { stump = true, object = true }),
      cell(3, 4, "planter", true, false,
        { planter = true, object = true }),
      cell(4, 5, "cliff", true, false,
        { cliff = true, object = true }),
      cell(5, 6, "roof", true, false,
        { roof = true, object = true }),
      cell(6, 7, "tree", false, true, { shore = true }),
      cell(7, 8, "tree", false, false, { water = true }),
      cell(8, 9, "tree", false, false, {}),
    })
    T.deepEqual(shape_at, {
      { 1, 0, 1 }, { 2, 2, 1 }, { 3, 4, 1 }, { 4, 6, 1 },
      { 5, 8, 1 }, { 6, 10, 1 }, { 7, 12, 1 }, { 8, 14, 1 },
      { 9, 16, 1 },
    })
  end)

  T.test("exports exact authored tree boulder and mountain support tags", function()
    local tile_shape = load_real_tile_shape()
    local tiles = { 64, 42, 2, 36 }
    local map = {
      id = "AUTHORED_ROUTE",
      widthCells = 4,
      heightCells = 1,
      def = { id = "AUTHORED_ROUTE", width = 2, height = 1,
        tileset = "OVERWORLD", outdoor = true, connections = {} },
      tileset = { id = "OVERWORLD", imageWidth = 128, imageHeight = 48,
        animatedTiles = {} },
      waterTiles = {},
      walkable = {},
    }
    function map:isWalkableCell() return false end
    function map:isWaterCell() return false end
    function map:isGrassCell() return false end
    function map:warpAtCell() return nil end
    function map:isWarpTileCell() return false end
    function map:isDoorTileCell() return false end
    function map:cellTile(x) return tiles[x + 1] end
    function map:tileAt(tx) return tiles[math.floor(tx / 2) + 1] end

    local player = { id = "player", cellX = 0, cellY = 0,
      px = 0, py = 0, facing = "south" }
    local state = { map = map, player = player, entities = { player }, neighbors = {} }
    local env = new_environment(T, { tile_shape = tile_shape })
    local services
    local handle, err = env.host:provider().register(extension("authored-semantics", {
      requires = { "world_snapshot" },
      attach = function(value) services = { world = value.world } end,
    }))
    T.truthy(handle, err)
    T.truthy(env.host:update(1 / 60, 1, state))
    local snapshot = services.world:snapshot()
    T.truthy(snapshot.tags.mountain)

    local function cell(x, tile, class, tags)
      return {
        x = x, z = 0, y = x, worldY = x, height = 16,
        kind = class,
        material = ("atlas:OVERWORLD:%d"):format(tile),
        atlas = "host:terrain",
        solid = true,
        walkable = false,
        tags = tags,
        metadata = { tile = tile, tileset = "OVERWORLD", warp = false },
      }
    end
    T.deepEqual(snapshot.cells, {
      cell(0, 64, "cylinder", {
        cylinder = true, tree = true, tree_support = true, object = true,
      }),
      cell(1, 42, "cylinder", {
        cylinder = true, boulder_tree = true, object = true,
      }),
      cell(2, 2, "wall", {
        object = true, mountain = true, mountain_support = true,
        mountain_seed = true,
      }),
      cell(3, 36, "wall", {
        object = true, mountain = true, mountain_support = true,
        mountain_seed = true,
      }),
    })
  end)

  T.test("exports bounded semantic eligibility through the world callback", function()
    local tile_shape = load_real_tile_shape()
    local width, height = 14, 8
    local tiles = {}
    local function key(x, z) return z * width + x end
    local function put(x, z, tile) tiles[key(x, z)] = tile end

    put(0, 0, 64)   -- exact tree tile exposed by a walkable connection ghost
    put(13, 0, 2)   -- exact seed inside the active north connection band
    put(0, 4, 2)    -- valid seed
    put(1, 4, 10)   -- support at reach one
    put(2, 4, 10)   -- support at reach two
    put(3, 4, 10)   -- candidate beyond the bounded reach
    put(5, 6, 10)   -- non-seed support vetoed by the nearby door
    put(6, 6, 36)   -- exact seed that keeps the cave-mouth exception

    local map = {
      id = "SEMANTIC_ROUTE",
      widthCells = width,
      heightCells = height,
      def = { id = "SEMANTIC_ROUTE", width = width / 2, height = height / 2,
        tileset = "OVERWORLD", outdoor = true, connections = { north = {} } },
      tileset = { id = "OVERWORLD", tilesPerRow = 16,
        imageWidth = 128, imageHeight = 48, animatedTiles = {} },
      waterTiles = {},
      walkable = { [0] = true },
    }
    function map:cellTile(x, z) return tiles[key(x, z)] or 0 end
    function map:tileAt(tx, ty)
      return self:cellTile(math.floor(tx / 2), math.floor((ty - 1) / 2))
    end
    function map:isWalkableCell(x, z)
      return (x == 0 and z == 0) or self:cellTile(x, z) == 0
    end
    function map:isWaterCell() return false end
    function map:isGrassCell() return false end
    function map:warpAtCell(x, z)
      return x == 7 and z == 6 and { target = "SYNTHETIC_CAVE" } or nil
    end
    function map:isWarpTileCell() return false end
    function map:isDoorTileCell(x, z) return x == 7 and z == 6 end

    local player = { id = "player", cellX = 0, cellY = 0,
      px = 0, py = 0, facing = "south" }
    local state = { map = map, player = player, entities = { player }, neighbors = {} }
    local env = new_environment(T, { tile_shape = tile_shape })
    local services, callback_snapshot
    local function copy_plain(value)
      if type(value) ~= "table" then return value end
      local result = {}
      for item_key, item_value in pairs(value) do
        result[copy_plain(item_key)] = copy_plain(item_value)
      end
      return result
    end
    local handle, err = env.host:provider().register(extension("semantic-eligibility", {
      requires = { "world_snapshot" },
      attach = function(value) services = { world = value.world } end,
      worldChanged = function(snapshot)
        callback_snapshot = {
          id = snapshot.id,
          cells = copy_plain(snapshot.cells),
        }
      end,
    }))
    T.truthy(handle, err)
    T.truthy(env.host:update(1 / 60, 1, state))
    local snapshot = services.world:snapshot()
    T.truthy(callback_snapshot)
    T.equal(callback_snapshot.id, "SEMANTIC_ROUTE")
    T.truthy(snapshot.tags.mountain)

    local function at(x, z) return snapshot.cells[z * width + x + 1] end
    local function expected(x, z, tile, class, height_value, solid, walkable, tags,
        warp)
      return {
        x = x, z = z, y = x + z, worldY = x + z, height = height_value,
        kind = class,
        material = ("atlas:OVERWORLD:%d"):format(tile),
        atlas = "host:terrain",
        solid = solid,
        walkable = walkable,
        tags = tags,
        metadata = { tile = tile, tileset = "OVERWORLD", warp = warp or false },
      }
    end

    T.deepEqual({
      walkable_tree_ghost = at(0, 0),
      connection_seed = at(13, 0),
      seed = at(0, 4),
      support_one = at(1, 4),
      support_two = at(2, 4),
      beyond_reach = at(3, 4),
      door_vetoed_support = at(5, 6),
      door_near_seed = at(6, 6),
      door = at(7, 6),
    }, {
      walkable_tree_ghost = expected(0, 0, 64, "cylinder", 16, false, true,
        { cylinder = true }),
      connection_seed = expected(13, 0, 2, "wall", 16, true, false,
        { object = true }),
      seed = expected(0, 4, 2, "wall", 16, true, false,
        { object = true, mountain = true, mountain_support = true,
          mountain_seed = true }),
      support_one = expected(1, 4, 10, "wall", 16, true, false,
        { object = true, mountain = true, mountain_support = true }),
      support_two = expected(2, 4, 10, "wall", 16, true, false,
        { object = true, mountain = true, mountain_support = true }),
      beyond_reach = expected(3, 4, 10, "wall", 16, true, false,
        { object = true }),
      door_vetoed_support = expected(5, 6, 10, "wall", 16, true, false,
        { object = true }),
      door_near_seed = expected(6, 6, 36, "wall", 16, true, false,
        { object = true, mountain = true, mountain_support = true,
          mountain_seed = true }),
      door = expected(7, 6, 0, "ground", 0, false, true,
        { door = true }, true),
    })

    T.deepEqual(callback_snapshot.cells[1], at(0, 0))
  end)

  T.test("rejects mountain seeds near roofs and unknown round objects", function()
    local classes = {
      [1] = { class = "cliff", h = 32,
        companion_tags = { mountain_seed = true } },
      [2] = { class = "cliff", h = 32 },
      [3] = { class = "roof", h = 28 },
      [4] = { class = "cylinder", h = 16 },
    }
    local tile_shape = {
      forMap = function() return classes end,
      at = function(_, shapes, tile) return shapes[tile] end,
    }
    local map = {
      id = "ROOF_VETO",
      widthCells = 4,
      heightCells = 1,
      def = { id = "ROOF_VETO", width = 2, height = 1,
        tileset = "CUSTOM", outdoor = true, connections = {} },
      tileset = { id = "CUSTOM", imageWidth = 128, imageHeight = 48 },
    }
    function map:isWalkableCell() return false end
    function map:isWaterCell() return false end
    function map:isGrassCell() return false end
    function map:cellTile(x) return x + 1 end
    local player = { id = "player", cellX = 0, cellY = 0,
      px = 0, py = 0, facing = "south" }
    local state = { map = map, player = player, entities = { player }, neighbors = {} }
    local env = new_environment(T, { tile_shape = tile_shape })
    local services
    local handle, err = env.host:provider().register(extension("roof-veto", {
      requires = { "world_snapshot" },
      attach = function(value) services = { world = value.world } end,
    }))
    T.truthy(handle, err)
    T.truthy(env.host:update(1 / 60, 1, state))
    local snapshot = services.world:snapshot()
    T.falsy(snapshot.tags.mountain)
    for _, cell in ipairs(snapshot.cells) do
      T.falsy(cell.tags.mountain)
      T.falsy(cell.tags.mountain_support)
      T.falsy(cell.tags.mountain_seed)
      T.falsy(cell.tags.boulder_tree)
      T.falsy(cell.tags.tree_support)
    end
    T.truthy(snapshot.cells[1].tags.cliff)
    T.truthy(snapshot.cells[2].tags.cliff)
    T.truthy(snapshot.cells[3].tags.roof)
    T.truthy(snapshot.cells[4].tags.cylinder)
  end)

  T.test("exports isolated mountain seeds as eligibility facts", function()
    local shape = { class = "cliff", h = 32,
      companion_tags = { mountain_seed = true } }
    local tile_shape = {
      forMap = function() return { [1] = shape } end,
      at = function() return shape end,
    }
    local map = {
      id = "ISOLATED_ROCK_SEED",
      widthCells = 1,
      heightCells = 1,
      def = { id = "ISOLATED_ROCK_SEED", width = 1, height = 1,
        tileset = "CUSTOM", outdoor = true, connections = {} },
      tileset = { id = "CUSTOM", imageWidth = 128, imageHeight = 48 },
    }
    function map:isWalkableCell() return false end
    function map:isWaterCell() return false end
    function map:isGrassCell() return false end
    function map:cellTile() return 1 end
    local player = { id = "player", cellX = 0, cellY = 0,
      px = 0, py = 0, facing = "south" }
    local state = { map = map, player = player, entities = { player }, neighbors = {} }
    local env = new_environment(T, { tile_shape = tile_shape })
    local services
    local handle, err = env.host:provider().register(extension("isolated-seed", {
      requires = { "world_snapshot" },
      attach = function(value) services = { world = value.world } end,
    }))
    T.truthy(handle, err)
    T.truthy(env.host:update(1 / 60, 1, state))
    local snapshot = services.world:snapshot()
    T.truthy(snapshot.tags.mountain)
    T.truthy(snapshot.cells[1].tags.mountain)
    T.truthy(snapshot.cells[1].tags.mountain_support)
    T.truthy(snapshot.cells[1].tags.mountain_seed)
  end)

  T.test("keeps profile semantics exact across ambiguous TileShape classes", function()
    local TileShape = load_real_tile_shape()
    local function map_for(id)
      local map = {
        def = { id = id .. "_TEST", tileset = id, outdoor = id ~= "GYM" },
        tileset = { id = id, imageWidth = 128, imageHeight = 48,
          animatedTiles = {} },
        waterTiles = {}, walkable = {},
      }
      function map:isWalkableCell() return false end
      function map:isWaterCell() return false end
      function map:tileAt() return 0 end
      return map
    end
    local overworld = TileShape.forMap(map_for("OVERWORLD"))
    T.truthy(overworld[64].companion_tags.tree_support)
    T.falsy(overworld[64].companion_tags.boulder_tree)
    T.truthy(overworld[42].companion_tags.boulder_tree)
    T.falsy(overworld[42].companion_tags.tree_support)
    T.truthy(overworld[2].companion_tags.mountain_seed)

    local forest = TileShape.forMap(map_for("FOREST"))
    T.equal(forest[4].class, "canopy")
    T.truthy(forest[4].companion_tags.canopy)
    T.falsy(forest[4].companion_tags.tree_support)
    T.equal(forest[2].class, "stump")
    T.truthy(forest[2].companion_tags.stump)
    T.falsy(forest[2].companion_tags.tree_support)
    T.truthy(forest.classes.planter.companion_tags.planter)
    T.falsy(forest.classes.planter.companion_tags.tree_support)

    local gym = TileShape.forMap(map_for("GYM"))
    T.truthy(gym[44].companion_tags.boulder_tree)
    T.falsy(gym[44].companion_tags.tree_support)
  end)

  T.test("uses the public game ready save version for world identity", function()
    local env = new_environment(T)
    local capturedGame
    local handle, err = env.host:provider().register(extension("yellow-world", {
      requires = { "world_snapshot", "render_phases" },
      worldChanged = function(snapshot) capturedGame = snapshot.game end,
    }))
    T.truthy(handle, err)
    env.host:setGame({ save = { version = "yellow" }, data = {} })
    T.truthy(env.host:update(1 / 60, 3, new_state("PALLET_TOWN")))
    T.equal(capturedGame, "yellow")
  end)

  T.test("dispatches safe phases through the existing frame and restores camera", function()
    local env = new_environment(T)
    local state = new_state()
    T.truthy(env.host:update(1 / 60, 3, state))
    local original_eye = env.camera.eye
    local original_focus = env.camera.focus
    local original_up = env.camera.up
    local original_fov = env.camera.fov
    local order, camera_calls = {}, 0
    local handle, err = env.host:provider().register(extension("render", {
      requires = { "world_snapshot", "camera_delta", "render_phases" },
      render = {
        background = function(context)
          order[#order + 1] = "background"
          context.draw.mesh(draw_packet("mesh", "background", 1, {
            owner = "render",
          }), context)
        end,
        opaque_after_terrain = function(context)
          order[#order + 1] = "opaque"
          context.draw.instances(draw_packet(
            "instances", "opaque_after_terrain", 2, { owner = "render" }
          ), context)
        end,
        translucent_after_actors = function(context)
          order[#order + 1] = "translucent"
          context.draw.billboards(draw_packet(
            "billboards", "translucent_after_actors", 3, { owner = "render" }
          ), context)
        end,
      },
      modifyCamera = function(camera)
        camera_calls = camera_calls + 1
        T.equal(camera.mode, "first_person")
        return {
          positionDelta = { x = 1, y = 2, z = 3 },
          rotationDelta = { yaw = 0, pitch = 0, roll = 0 },
          fovDelta = 0.05,
        }
      end,
    }))
    T.truthy(handle, err)
    T.truthy(handle:is_active())
    T.truthy(begin_frame(env, state))
    for _, event in ipairs(env.events) do
      if event.code == "extension-fault" then error(event.message, 0) end
    end
    T.equal(camera_calls, 1)
    T.near(env.camera.eye[1], 1)
    T.near(env.camera.eye[2], 3)
    T.near(env.camera.eye[3], 5)
    T.near(env.camera.fov, original_fov + 0.05)
    T.truthy(env.host:dispatchRenderPhase("background"))
    T.truthy(env.host:dispatchRenderPhase("opaque_after_terrain"))
    T.truthy(env.host:dispatchRenderPhase("translucent_after_actors"))
    T.truthy(env.host:endWorldFrame("test"))
    T.deepEqual(order, { "background", "opaque", "translucent" })
    T.equal(#env.backend.calls, 3)
    T.deepEqual(env.backend.phases, {
      "begin:background", "end:background",
      "begin:opaque_after_terrain", "end:opaque_after_terrain",
      "begin:translucent_after_actors", "end:translucent_after_actors",
    })
    T.equal(env.camera.eye, original_eye)
    T.equal(env.camera.focus, original_focus)
    T.equal(env.camera.up, original_up)
    T.equal(env.camera.fov, original_fov)
  end)

  T.test("executes the frozen baseline fixture through adapter and renderer", function()
    local fixture = load_fixture("tests/fixtures/voxel_companion_draw_v1.lua")
    local voxel = { meshes = {}, draws = 0 }
    function voxel.newMesh(vertices, indices)
      local mesh = { vertices = vertices, indices = indices, releases = 0 }
      function mesh:release() self.releases = self.releases + 1 end
      voxel.meshes[#voxel.meshes + 1] = mesh
      return mesh
    end
    function voxel.draw() voxel.draws = voxel.draws + 1 end
    function voxel.glass() end
    function voxel.depth() end
    local Renderer = load_with_argument("lib/VoxelCompanionRenderer.lua", {
      require = function(name) error("unexpected module request: " .. name, 2) end,
    })
    local backend, backend_error = Renderer.new({
      voxel3d = voxel,
      mat4 = {},
      graphics = { setColor = function() end, setDepthMode = function() end },
    })
    T.truthy(backend, backend_error)
    local env = new_environment(T, { backend = backend })
    local state = new_state()
    T.truthy(env.host:update(1 / 60, 3, state))

    local render = {}
    for _, name in ipairs({
      "background", "opaque_after_terrain", "translucent_after_actors",
    }) do
      local phase = name
      render[phase] = function(context)
        for _, command in ipairs(fixture.phases[phase]) do
          context.draw[command.kind](command, context)
        end
      end
    end
    local handle, register_error = env.host:provider().register(extension(
      "golden.fixture",
      { render = render }
    ))
    T.truthy(handle, register_error)

    for pass = 1, 2 do
      T.truthy(begin_frame(env, state))
      for _, phase in ipairs({
        "background", "opaque_after_terrain", "translucent_after_actors",
      }) do
        local report, render_error = env.host:dispatchRenderPhase(phase)
        T.truthy(report, render_error)
        T.equal(report.succeeded, 1)
      end
      T.truthy(env.host:endWorldFrame("fixture-pass-" .. pass))
    end

    T.equal(fixture.commandCount, 23)
    T.equal(#fixture.instancePrimitives, 15)
    T.equal(#voxel.meshes, fixture.commandCount)
    T.equal(voxel.draws, fixture.commandCount * 2)
    T.equal(backend:status().cacheEntries, fixture.commandCount)
    T.truthy(env.host:dispose("fixture-complete"))
    for _, mesh in ipairs(voxel.meshes) do T.equal(mesh.releases, 1) end
  end)

  T.test("passes live public player cells to cutaway rendering", function()
    local voxel = { meshes = {}, draws = {} }
    function voxel.newMesh(vertices, indices)
      local mesh = { vertices = vertices, indices = indices, releases = 0 }
      function mesh:release() self.releases = self.releases + 1 end
      voxel.meshes[#voxel.meshes + 1] = mesh
      return mesh
    end
    function voxel.draw(mesh) voxel.draws[#voxel.draws + 1] = mesh end
    function voxel.glass() end
    function voxel.depth() end
    local Renderer = load_with_argument("lib/VoxelCompanionRenderer.lua", {
      require = function(name) error("unexpected module request: " .. name, 2) end,
    })
    local backend, backend_error = Renderer.new({
      voxel3d = voxel,
      mat4 = {},
      graphics = { setColor = function() end, setDepthMode = function() end },
    })
    T.truthy(backend, backend_error)
    local env = new_environment(T, { backend = backend })
    local state = new_state()
    T.truthy(env.host:update(1 / 60, 3, state))
    local items = {
      { x = 0, y = 4, z = 1, cellX = 0, cellZ = 1 },
      { x = 10, y = 4, z = 10, cellX = 10, cellZ = 10 },
    }
    local cutaway = draw_packet("instances", "opaque_after_terrain", 1, {
      cacheKey = "adapter:cutaway:live",
      prototype = { primitive = "box", role = "ceiling", cutaway = true },
      items = items,
    })
    local sealed = draw_packet("instances", "opaque_after_terrain", 2, {
      cacheKey = "adapter:cutaway:sealed",
      prototype = { primitive = "box", role = "ceiling", cutaway = false },
      items = items,
    })
    local handle, register_error = env.host:provider().register(extension(
      "cutaway.live-context",
      { render = { opaque_after_terrain = function(context)
        context.draw.instances(cutaway, context)
        context.draw.instances(sealed, context)
      end } }
    ))
    T.truthy(handle, register_error)

    T.truthy(begin_frame(env, state))
    local report, render_error = env.host:dispatchRenderPhase("opaque_after_terrain")
    T.truthy(report, render_error)
    T.truthy(env.host:endWorldFrame("cutaway-near-first"))
    T.equal(#voxel.meshes, 2)
    T.equal(#voxel.meshes[1].vertices, 24)
    T.equal(#voxel.meshes[2].vertices, 48)

    state.player.cellX, state.player.cellY = 10, 10
    T.truthy(begin_frame(env, state))
    report, render_error = env.host:dispatchRenderPhase("opaque_after_terrain")
    T.truthy(report, render_error)
    T.truthy(env.host:endWorldFrame("cutaway-near-second"))
    T.equal(#voxel.meshes, 3)
    T.equal(#voxel.meshes[3].vertices, 24)
    T.equal(voxel.draws[2], voxel.draws[4])
    T.equal(backend:status().cacheEntries, 3)
  end)

  T.test("borrows an opaque extension texture for one validated draw call", function()
    local backend = new_backend()
    local released, saw_texture = 0, false
    local texture = {
      release = function() released = released + 1 end,
    }
    function backend:mesh(command, context)
      T.equal(command.texture, texture)
      T.equal(context.phase, "background")
      saw_texture = true
      return true
    end
    local env = new_environment(T, { backend = backend })
    local state = new_state()
    T.truthy(env.host:update(1 / 60, 3, state))
    local handle, err = env.host:provider().register(extension("opaque.texture", {
      render = { background = function(context)
        context.draw.mesh(draw_packet("mesh", "background", 1, {
          owner = "opaque.texture",
          material = "horizon:test",
          texture = texture,
          geometry = {
            primitive = "panorama",
            sourceWidth = 4096,
            targetWidth = 2048,
          },
        }), context)
      end },
    }))
    T.truthy(handle, err)
    T.truthy(begin_frame(env, state))
    local report, render_error = env.host:dispatchRenderPhase("background")
    T.truthy(report, render_error)
    T.equal(report.succeeded, 1)
    T.truthy(saw_texture)
    T.equal(released, 0)
    env.host:endWorldFrame()
    T.equal(released, 0)
  end)

  T.test("rejects path-bearing packets before the backend and continues", function()
    local env = new_environment(T)
    local state = new_state()
    T.truthy(env.host:update(1 / 60, 3, state))
    local invalid = env.host:provider().register(extension("a.path", {
      render = { background = function(context)
        context.draw.mesh(draw_packet("mesh", "background", 1, {
          owner = "a.path",
          texture = "assets/legacy/horizons/backdrop.png",
        }), context)
      end },
    }))
    T.truthy(invalid)
    T.truthy(env.host:provider().register(extension("b.safe", {
      priority = 1,
      render = { background = function(context)
        context.draw.mesh(draw_packet("mesh", "background", 2, {
          owner = "b.safe",
        }), context)
      end },
    })))
    T.truthy(begin_frame(env, state))
    local report, render_error = env.host:dispatchRenderPhase("background")
    T.truthy(report, render_error)
    T.equal(report.failed, 1)
    T.equal(report.succeeded, 1)
    T.truthy(invalid:status().faulted)
    T.equal(#env.backend.calls, 1)
    T.equal(env.backend.calls[1].owner, "b.safe")
    env.host:endWorldFrame()
  end)

  T.test("requires the draw backend to return exact true", function()
    local backend = new_backend()
    function backend:mesh() return "truthy-but-not-true" end
    local env = new_environment(T, { backend = backend })
    local state = new_state()
    T.truthy(env.host:update(1 / 60, 3, state))
    local handle, err = env.host:provider().register(extension("backend.result", {
      render = { background = function(context)
        context.draw.mesh(draw_packet("mesh", "background", 1), context)
      end },
    }))
    T.truthy(handle, err)
    T.truthy(begin_frame(env, state))
    local report, render_error = env.host:dispatchRenderPhase("background")
    T.truthy(report, render_error)
    T.equal(report.failed, 1)
    T.truthy(handle:status().faulted)
    env.host:endWorldFrame()
  end)

  T.test("rejects optional seams and terrain that the host cannot run", function()
    local env = new_environment(T)
    local provider = env.host:provider()
    for _, phase in ipairs({ "shadow_casters", "battle_opaque" }) do
      local handle, err = provider.register(extension("no_" .. phase, {
        render = { [phase] = function() end },
      }))
      T.falsy(handle)
      T.truthy(tostring(err):find(phase, 1, true))
    end
    local handle, err = provider.register(extension("no_terrain", {
      render = {},
      terrainPatch = function() return {} end,
    }))
    T.falsy(handle)
    T.truthy(tostring(err):find("terrain_patch", 1, true))
    T.falsy(env.host:dispatchRenderPhase("shadow_casters"))
    T.falsy(env.host:dispatchRenderPhase("battle_opaque"))
  end)

  T.test("rolls back a frame when camera dispatch fails internally", function()
    local env = new_environment(T)
    local state = new_state()
    T.truthy(env.host:update(1 / 60, 3, state))
    local eye, focus, up, fov = env.camera.eye, env.camera.focus,
      env.camera.up, env.camera.fov
    env.host._dispatcher.modifyCamera = function()
      error("camera bridge fault")
    end
    local active, err = begin_frame(env, state)
    T.falsy(active)
    T.truthy(tostring(err):find("camera bridge fault", 1, true))
    T.equal(env.camera.eye, eye)
    T.equal(env.camera.focus, focus)
    T.equal(env.camera.up, up)
    T.equal(env.camera.fov, fov)
    T.truthy(env.host:endWorldFrame("after-fault"))
  end)

  T.test("isolates extension faults and continues deterministic phase order", function()
    local env = new_environment(T)
    local state = new_state()
    T.truthy(env.host:update(1 / 60, 3, state))
    local disposed = 0
    T.truthy(env.host:provider().register(extension("a.bad", {
      priority = 0,
      dispose = function() disposed = disposed + 1 end,
      render = { background = function() error("intentional fault") end },
    })))
    T.truthy(env.host:provider().register(extension("b.good", {
      priority = 1,
      render = { background = function(context)
        context.draw.mesh(draw_packet("mesh", "background", 1, {
          owner = "b.good",
        }), context)
      end },
    })))
    T.truthy(begin_frame(env, state))
    local report, err = env.host:dispatchRenderPhase("background")
    T.truthy(report, err)
    T.equal(report.failed, 1)
    T.equal(report.succeeded, 1)
    T.equal(#env.backend.calls, 1)
    T.equal(env.backend.calls[1].owner, "b.good")
    T.equal(disposed, 1)
    env.host:endWorldFrame()
  end)

  T.test("rejects an expired render context and still calls later extensions", function()
    local env = new_environment(T)
    local state = new_state()
    T.truthy(env.host:update(1 / 60, 3, state))
    local old_context
    T.truthy(env.host:provider().register(extension("a.lease", {
      render = {
        background = function(context) old_context = context end,
        opaque_after_terrain = function(context)
          context.draw.mesh(draw_packet("mesh", "opaque_after_terrain", 1, {
            owner = "a.lease",
          }), old_context)
        end,
      },
    })))
    T.truthy(env.host:provider().register(extension("b.after", {
      priority = 1,
      render = { opaque_after_terrain = function(context)
        context.draw.mesh(draw_packet("mesh", "opaque_after_terrain", 2, {
          owner = "b.after",
        }), context)
      end },
    })))
    T.truthy(begin_frame(env, state))
    T.truthy(env.host:dispatchRenderPhase("background"))
    local report, err = env.host:dispatchRenderPhase("opaque_after_terrain")
    T.truthy(report, err)
    T.equal(report.failed, 1)
    T.equal(report.succeeded, 1)
    T.equal(#env.backend.calls, 1)
    T.equal(env.backend.calls[1].owner, "b.after")
    env.host:endWorldFrame()
  end)

  T.test("bounds invalid worlds without stopping the host", function()
    local env = new_environment(T)
    local state = new_state()
    state.map.widthCells = 262145
    state.map.heightCells = 2
    T.truthy(env.host:update(1 / 60, 3, state))
    local found = false
    for _, event in ipairs(env.events) do
      if event.code == "world-bounds" then found = true end
    end
    T.truthy(found)
  end)

  T.test("invalidates resources and disposes each owner exactly once", function()
    local env = new_environment(T)
    local lifecycle = { invalidate = 0, dispose = 0 }
    local handle, err = env.host:provider().register(extension("lifecycle", {
      invalidate = function() lifecycle.invalidate = lifecycle.invalidate + 1 end,
      dispose = function() lifecycle.dispose = lifecycle.dispose + 1 end,
    }))
    T.truthy(handle, err)
    T.truthy(env.host:invalidate("graphics"))
    T.equal(lifecycle.invalidate, 1)
    T.equal(env.backend.invalidations, 1)
    T.truthy(handle:dispose({}, "test"))
    T.truthy(handle:dispose({}, "again"))
    T.equal(lifecycle.dispose, 1)
    T.truthy(env.host:dispose("shutdown"))
    T.truthy(env.host:dispose("again"))
    T.equal(lifecycle.dispose, 1)
    T.equal(env.backend.disposals, 1)
  end)
end
