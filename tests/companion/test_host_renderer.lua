return function(T)
  local function load_renderer(V)
    local source = T.read("lib/VoxelCompanionRenderer.lua")
    local chunk, err = loadstring(source, "@lib/VoxelCompanionRenderer.lua")
    if not chunk then error(err, 0) end
    return chunk(V)
  end

  local function new_graphics()
    local graphics = { colors = {}, depths = {} }
    function graphics.setColor(...)
      graphics.colors[#graphics.colors + 1] = { ... }
    end
    function graphics.setDepthMode(...)
      graphics.depths[#graphics.depths + 1] = { ... }
    end
    return graphics
  end

  local function new_voxel3d()
    local voxel = {
      meshes = {}, draws = {}, glassStates = {}, depthStates = {},
    }
    function voxel.newMesh(vertices, indices)
      local mesh = {
        vertices = vertices,
        indices = indices,
        releases = 0,
      }
      function mesh:release() self.releases = self.releases + 1 end
      voxel.meshes[#voxel.meshes + 1] = mesh
      return mesh
    end
    function voxel.draw(mesh, texture, model)
      voxel.draws[#voxel.draws + 1] = {
        mesh = mesh, texture = texture, model = model,
      }
    end
    function voxel.glass(value)
      voxel.glassStates[#voxel.glassStates + 1] = value
    end
    function voxel.depth(value)
      voxel.depthStates[#voxel.depthStates + 1] = value
    end
    return voxel
  end

  local function new_renderer(options)
    options = options or {}
    local voxel = options.voxel3d or new_voxel3d()
    local graphics = options.graphics or new_graphics()
    local V = { require = function(name) error("unexpected require: " .. name, 2) end }
    local Renderer = load_renderer(V)
    local renderer, err = Renderer.new({
      voxel3d = voxel,
      mat4 = {},
      graphics = graphics,
      max_cache_entries = options.max_cache_entries,
      max_cache_bytes = options.max_cache_bytes,
      max_items = options.max_items,
      max_vertices = options.max_vertices,
    })
    return renderer, err, voxel, graphics, Renderer
  end

  local function context(generation)
    generation = generation or 1
    return {
      phase = "opaque_after_terrain",
      world = {
        id = "PALLET_TOWN",
        key = "red:PALLET_TOWN:" .. generation,
        atlasRevision = "OVERWORLD:" .. generation,
        width = 2,
        height = 2,
        cellSize = 16,
      },
      map = {
        tileset = {
          id = "OVERWORLD", tilesPerRow = 16,
          imageWidth = 128, imageHeight = 48,
        },
      },
      atlas = { id = "borrowed-atlas" },
      frame = { sequence = generation },
    }
  end

  local function base_command(kind, key, fields)
    local command = {
      schemaVersion = 1,
      cacheKey = key,
      kind = kind,
      owner = "renderer.test",
      phase = "opaque_after_terrain",
      sequence = 1,
      sortKey = key,
      material = "host:test",
    }
    for field, value in pairs(fields or {}) do command[field] = value end
    return command
  end

  local function mesh_command(key, geometry, fields)
    fields = fields or {}
    fields.geometry = geometry or {
      primitive = "plane", width = 1, depth = 1,
    }
    return base_command("mesh", key, fields)
  end

  local function instances_command(key, prototype, items, fields)
    fields = fields or {}
    fields.prototype = prototype
    fields.items = items
    return base_command("instances", key, fields)
  end

  local function billboards_command(key, items, fields)
    fields = fields or {}
    fields.items = items
    return base_command("billboards", key, fields)
  end

  T.test("creates and reuses one cache-keyed host mesh", function()
    local renderer, err, voxel = new_renderer()
    T.truthy(renderer, err)
    local command = mesh_command("mesh.box.g1", {
      primitive = "box", width = 4, height = 5, depth = 6,
    }, { material = "world:apron" })
    local ctx = context(1)
    T.equal(renderer:mesh(command, ctx), true)
    T.equal(#voxel.meshes, 1)
    T.equal(#voxel.meshes[1].vertices, 24)
    T.equal(#voxel.meshes[1].indices, 36)
    T.equal(#voxel.draws, 1)
    T.equal(renderer:mesh(command, ctx), true)
    T.equal(#voxel.meshes, 1)
    T.equal(#voxel.draws, 2)
    T.equal(renderer:status().cacheEntries, 1)
    T.truthy(renderer:status().cacheBytes > 0)
  end)

  T.test("batches instance and billboard packets into one draw each", function()
    local renderer, err, voxel = new_renderer()
    T.truthy(renderer, err)
    local ctx = context()
    T.equal(renderer:instances(instances_command(
      "instances.wall.g1",
      { primitive = "box", width = 4, height = 8, depth = 1 },
      {
        { x = 1, y = 4, z = 1 },
        { x = 6, y = 4, z = 1 },
      },
      { material = "interior:wall" }
    ), ctx), true)
    T.equal(#voxel.meshes[1].vertices, 48)
    T.equal(renderer:billboards(billboards_command(
      "billboards.bird.g1",
      { { x = 4, y = 16, z = 8 } },
      { material = "wildlife:bird" }
    ), ctx), true)
    T.equal(#voxel.meshes[2].vertices, 8)
    T.equal(#voxel.draws, 2)
  end)

  T.test("cuts away nearby KFP ceiling and wall boxes from the public player cell", function()
    for _, role in ipairs({ "ceiling", "wall" }) do
      local renderer, err, voxel = new_renderer()
      T.truthy(renderer, err)
      local ctx = context()
      ctx.world.player = { cellX = 10, cellZ = 10 }
      local command = instances_command(
        "instances.cutaway." .. role,
        { primitive = "box", role = role, cutaway = true,
          width = 4, height = 4, depth = 4 },
        {
          { x = 10, y = 2, z = 10, cellX = 10, cellZ = 10 },
          { x = 14, y = 2, z = 6, cellX = 14, cellZ = 6 },
          { x = 15, y = 2, z = 10, cellX = 15, cellZ = 10 },
          { x = 30, y = 2, z = 30 },
        }
      )

      T.equal(renderer:instances(command, ctx), true)
      T.equal(#voxel.meshes, 1)
      T.equal(#voxel.meshes[1].vertices, 48)
      T.equal(#voxel.meshes[1].indices, 72)
      T.equal(#voxel.draws, 1)
    end
  end)

  T.test("keeps non-cutaway and non-interior boxes visible", function()
    local renderer, err, voxel = new_renderer()
    T.truthy(renderer, err)
    local ctx = context()
    ctx.world.player = { cellX = 0, cellZ = 0 }
    local items = {
      { x = 0, y = 2, z = 0, cellX = 0, cellZ = 0 },
      { x = 1, y = 2, z = 1, cellX = 1, cellZ = 1 },
    }

    T.equal(renderer:instances(instances_command(
      "instances.cutaway.disabled",
      { primitive = "box", role = "ceiling", cutaway = false }, items
    ), ctx), true)
    T.equal(renderer:instances(instances_command(
      "instances.cutaway.other-role",
      { primitive = "box", role = "battle_prop", cutaway = true }, items
    ), ctx), true)

    T.equal(#voxel.meshes, 2)
    T.equal(#voxel.meshes[1].vertices, 48)
    T.equal(#voxel.meshes[2].vertices, 48)
    T.equal(#voxel.draws, 2)
  end)

  T.test("fails open when cutaway coordinates are incomplete", function()
    local cases = {
      { contextPlayer = nil,
        item = { x = 1, y = 2, z = 1, cellX = 1, cellZ = 1 } },
      { contextPlayer = { cellX = 1 },
        item = { x = 1, y = 2, z = 1, cellX = 1, cellZ = 1 } },
      { contextPlayer = { cellX = 1, cellZ = 1 },
        item = { x = 1, y = 2, z = 1, cellX = 1 } },
    }
    for index, case in ipairs(cases) do
      local renderer, err, voxel = new_renderer()
      T.truthy(renderer, err)
      local ctx = context()
      ctx.world.player = case.contextPlayer
      T.equal(renderer:instances(instances_command(
        "instances.cutaway.incomplete." .. index,
        { primitive = "box", role = "ceiling", cutaway = true },
        { case.item }
      ), ctx), true)
      T.equal(#voxel.meshes, 1)
      T.equal(#voxel.meshes[1].vertices, 24)
      T.equal(#voxel.draws, 1)
    end
  end)

  T.test("uses bounded player-cell variants for moving cutaways", function()
    local renderer, err, voxel = new_renderer()
    T.truthy(renderer, err)
    local command = instances_command(
      "instances.cutaway.moving",
      { primitive = "box", role = "ceiling", cutaway = true },
      {
        { x = 1, y = 2, z = 1, cellX = 1, cellZ = 1 },
        { x = 20, y = 2, z = 20, cellX = 20, cellZ = 20 },
      }
    )
    local ctx = context()
    ctx.world.player = { cellX = 1, cellZ = 1 }
    T.equal(renderer:instances(command, ctx), true)
    local first = voxel.draws[1].mesh

    ctx.world.player = { cellX = 20, cellZ = 20 }
    T.equal(renderer:instances(command, ctx), true)
    local second = voxel.draws[2].mesh
    T.truthy(first ~= second)
    T.equal(#voxel.meshes, 2)

    ctx.world.player = { cellX = 1, cellZ = 1 }
    T.equal(renderer:instances(command, ctx), true)
    T.equal(voxel.draws[3].mesh, first)
    T.equal(#voxel.meshes, 2)
    T.equal(renderer:status().cacheEntries, 2)
  end)

  T.test("evicts old moving-cutaway variants through the shared LRU", function()
    local renderer, err, voxel = new_renderer({ max_cache_entries = 2 })
    T.truthy(renderer, err)
    local command = instances_command(
      "instances.cutaway.variant-lru",
      { primitive = "box", role = "wall", cutaway = true },
      {
        { x = 1, y = 2, z = 1, cellX = 1, cellZ = 1 },
        { x = 20, y = 2, z = 20, cellX = 20, cellZ = 20 },
        { x = 40, y = 2, z = 40, cellX = 40, cellZ = 40 },
      }
    )
    local ctx = context()
    for _, cell in ipairs({ 1, 20, 40 }) do
      ctx.world.player = { cellX = cell, cellZ = cell }
      T.equal(renderer:instances(command, ctx), true)
    end

    T.equal(#voxel.meshes, 3)
    T.equal(renderer:status().cacheEntries, 2)
    T.equal(voxel.meshes[1].releases, 1)
    T.equal(voxel.meshes[2].releases, 0)
    T.equal(voxel.meshes[3].releases, 0)
    T.truthy(renderer:dispose())
    for _, mesh in ipairs(voxel.meshes) do T.equal(mesh.releases, 1) end
  end)

  T.test("accepts a fully cut-away batch without allocation", function()
    local renderer, err, voxel = new_renderer()
    T.truthy(renderer, err)
    local command = instances_command(
      "instances.cutaway.empty",
      { primitive = "box", role = "wall", cutaway = true },
      { { x = 2, y = 2, z = 2, cellX = 2, cellZ = 2 } }
    )
    local ctx = context()
    ctx.world.player = { cellX = 2, cellZ = 2 }
    T.equal(renderer:instances(command, ctx), true)
    T.equal(#voxel.meshes, 0)
    T.equal(#voxel.draws, 0)
    T.equal(renderer:status().cacheEntries, 0)

    ctx.world.player = { cellX = 20, cellZ = 20 }
    T.equal(renderer:instances(command, ctx), true)
    T.equal(#voxel.meshes, 1)
    T.equal(#voxel.draws, 1)
  end)

  T.test("builds deterministic procedural stars within the item limit", function()
    local renderer, err, voxel = new_renderer({ max_items = 10 })
    T.truthy(renderer, err)
    local command = base_command("billboards", "billboards.stars.g1", {
      material = "sky:stars",
      procedural = { kind = "stars", count = 5, seed = 42 },
    })
    T.equal(renderer:billboards(command, context()), true)
    T.equal(#voxel.meshes[1].vertices, 40)
    local first = voxel.meshes[1].vertices[1]
    renderer:invalidate()
    T.equal(renderer:billboards(command, context()), true)
    T.deepEqual(voxel.meshes[2].vertices[1], first)
  end)

  T.test("borrows atlas handles and resolves semantic materials", function()
    local renderer, err, voxel = new_renderer()
    T.truthy(renderer, err)
    local ctx = context()
    local atlas = renderer:resolveMaterial("atlas:OVERWORLD:17", ctx)
    T.equal(atlas.id, "atlas:OVERWORLD:17")
    T.equal(atlas.texture, ctx.atlas)
    T.truthy(atlas.atlas)
    local first = renderer:resolveMaterial("flora:grass", ctx)
    local second = renderer:resolveMaterial("flora:grass", ctx)
    T.deepEqual(first, second)
    T.falsy(first.atlas)

    local command = mesh_command("mesh.atlas.g1", {
      primitive = "plane", width = 4, depth = 4,
    }, { material = "atlas:OVERWORLD:17" })
    T.equal(renderer:mesh(command, ctx), true)
    T.equal(voxel.draws[1].texture, ctx.atlas)
    T.truthy(voxel.glassStates[1])
  end)

  T.test("draws a direct extension mesh without claiming or releasing it", function()
    local renderer, err, voxel = new_renderer()
    T.truthy(renderer, err)
    local resource = { releases = 0 }
    function resource:release() self.releases = self.releases + 1 end
    local command = base_command("mesh", "mesh.direct.g1", {
      material = "host:borrowed",
      mesh = resource,
    })
    T.equal(renderer:mesh(command, context()), true)
    T.equal(#voxel.meshes, 0)
    T.equal(voxel.draws[1].mesh, resource)
    T.truthy(renderer:dispose())
    T.equal(resource.releases, 0)
  end)

  T.test("rejects cache-key content and context collisions without replacement", function()
    local renderer, err, voxel = new_renderer()
    T.truthy(renderer, err)
    local original = mesh_command("mesh.collision", {
      primitive = "plane", width = 2, depth = 2,
    })
    local original_context = context(1)
    T.equal(renderer:mesh(original, original_context), true)
    local retained = voxel.meshes[1]

    local changed = mesh_command("mesh.collision", {
      primitive = "plane", width = 3, depth = 2,
    })
    local result, draw_error = renderer:mesh(changed, original_context)
    T.falsy(result)
    T.truthy(tostring(draw_error):find("content collision", 1, true))
    T.equal(#voxel.meshes, 1)
    T.equal(retained.releases, 0)

    result, draw_error = renderer:mesh(original, context(2))
    T.falsy(result)
    T.truthy(tostring(draw_error):find("content collision", 1, true))
    T.equal(#voxel.meshes, 1)
    T.equal(retained.releases, 0)

    T.equal(renderer:mesh(original, original_context), true)
    T.equal(#voxel.meshes, 1)
    T.equal(renderer:status().cacheEntries, 1)
  end)

  T.test("does not retain callback commands or opaque textures", function()
    local renderer, err, voxel = new_renderer()
    T.truthy(renderer, err)
    local weak = setmetatable({}, { __mode = "k" })
    local texture = { id = "callback-texture" }
    local command = mesh_command("mesh.gc.g1", {
      primitive = "plane", width = 2, depth = 2,
    }, { texture = texture })
    weak[command] = "command"
    weak[texture] = "texture"
    T.equal(renderer:mesh(command, context()), true)
    T.equal(renderer:status().cacheEntries, 1)

    -- The mock records draw arguments for assertions. The production draw call
    -- does not transfer ownership, so remove this test-only history first.
    voxel.draws = {}
    command, texture = nil, nil
    collectgarbage("collect")
    collectgarbage("collect")

    local retained = 0
    for _ in pairs(weak) do retained = retained + 1 end
    T.equal(retained, 0)
    T.equal(renderer:status().cacheEntries, 1)
  end)

  T.test("evicts by byte-cap LRU and releases each mesh exactly once", function()
    local renderer, err, voxel = new_renderer({
      max_cache_entries = 8,
      max_cache_bytes = 1024,
    })
    T.truthy(renderer, err)
    local first = mesh_command("mesh.lru.g1.first", {
      primitive = "plane", width = 2, depth = 2,
    })
    local second = mesh_command("mesh.lru.g1.second", {
      primitive = "plane", width = 3, depth = 3,
    })
    local third = mesh_command("mesh.lru.g2.third", {
      primitive = "plane", width = 4, depth = 4,
    })

    T.equal(renderer:mesh(first, context(1)), true)
    local first_mesh = voxel.meshes[1]
    T.equal(renderer:mesh(second, context(1)), true)
    local second_mesh = voxel.meshes[2]
    T.equal(renderer:mesh(first, context(1)), true)
    T.equal(renderer:mesh(third, context(2)), true)
    local third_mesh = voxel.meshes[3]

    T.equal(first_mesh.releases, 0)
    T.equal(second_mesh.releases, 1)
    T.equal(third_mesh.releases, 0)
    local status = renderer:status()
    T.equal(status.cacheEntries, 2)
    T.equal(status.maxCacheEntries, 8)
    T.equal(status.cacheBytes, 752)
    T.equal(status.maxCacheBytes, 1024)

    T.truthy(renderer:dispose())
    T.truthy(renderer:dispose())
    T.equal(first_mesh.releases, 1)
    T.equal(second_mesh.releases, 1)
    T.equal(third_mesh.releases, 1)
    T.equal(renderer:status().cacheBytes, 0)
  end)

  T.test("releases an over-budget mesh without caching it", function()
    local renderer, err, voxel = new_renderer({ max_cache_bytes = 1024 })
    T.truthy(renderer, err)
    local command = mesh_command("mesh.oversize.g1", {
      primitive = "world_apron",
      width = 32,
      depth = 32,
      skirtDepth = 128,
    })
    local result, draw_error = renderer:mesh(command, context())
    T.falsy(result)
    T.truthy(tostring(draw_error):find("cache byte limit", 1, true))
    T.equal(#voxel.meshes, 1)
    T.equal(voxel.meshes[1].releases, 1)
    T.equal(renderer:status().cacheEntries, 0)
    T.equal(renderer:status().cacheBytes, 0)
    T.truthy(renderer:dispose())
    T.equal(voxel.meshes[1].releases, 1)
  end)

  T.test("rejects unsupported terrain and shadow primitives", function()
    local renderer, err = new_renderer()
    T.truthy(renderer, err)
    local cases = {
      { primitive = "raised_structure", message = "terrain_patch" },
      { primitive = "shadow_caster", message = "not supported" },
    }
    for index, case in ipairs(cases) do
      T.raises(function()
        renderer:instances(instances_command(
          "instances.unsupported." .. index,
          { primitive = case.primitive },
          { { x = 0, y = 0, z = 0 } }
        ), context())
      end, case.message)
    end
    T.falsy(renderer.lights)
    T.falsy(renderer.postprocess)
  end)

  T.test("enforces dense item and vertex limits", function()
    local renderer, err = new_renderer({ max_items = 1, max_vertices = 24 })
    T.truthy(renderer, err)
    T.raises(function()
      renderer:billboards(billboards_command(
        "billboards.limit.items",
        { { x = 0, y = 0, z = 0 }, { x = 1, y = 0, z = 0 } }
      ), context())
    end, "item limit")
    T.raises(function()
      renderer:instances(instances_command(
        "instances.limit.items",
        { primitive = "box" },
        { { x = 0, y = 0, z = 0 }, { x = 1, y = 0, z = 0 } }
      ), context())
    end, "item limit")
    T.raises(function()
      renderer:mesh(mesh_command("mesh.limit.vertices", {
        primitive = "world_apron",
        width = 32,
        depth = 32,
        skirtDepth = 128,
      }), context())
    end, "vertex limit")
  end)

  T.test("rejects every draw kind after disposal without allocation", function()
    local renderer, err, voxel = new_renderer()
    T.truthy(renderer, err)
    T.equal(renderer:mesh(mesh_command("mesh.before.dispose", {
      primitive = "plane", width = 2, depth = 2,
    }), context()), true)
    T.equal(#voxel.meshes, 1)
    T.truthy(renderer:dispose())
    T.equal(voxel.meshes[1].releases, 1)
    T.equal(renderer:status().cacheEntries, 0)
    T.equal(renderer:status().cacheBytes, 0)

    local calls = {
      function()
        return renderer:mesh(mesh_command("mesh.after.dispose", {
          primitive = "plane", width = 3, depth = 3,
        }), context())
      end,
      function()
        return renderer:instances(instances_command(
          "instances.after.dispose",
          { primitive = "box", width = 1, height = 1, depth = 1 },
          { { x = 0, y = 0, z = 0 } }
        ), context())
      end,
      function()
        return renderer:billboards(billboards_command(
          "billboards.after.dispose",
          { { x = 0, y = 0, z = 0 } }
        ), context())
      end,
    }
    for _, call in ipairs(calls) do
      local result, draw_error = call()
      T.falsy(result)
      T.truthy(tostring(draw_error):find("disposed", 1, true))
      T.equal(#voxel.meshes, 1)
      T.equal(renderer:status().cacheEntries, 0)
      T.equal(renderer:status().cacheBytes, 0)
    end
  end)

  T.test("scopes translucent depth writes and restores host draw state", function()
    local renderer, err, voxel, graphics = new_renderer()
    T.truthy(renderer, err)
    renderer:beginPhase("translucent_after_actors")
    T.deepEqual(graphics.depths[1], { "lequal", false })
    renderer:endPhase("translucent_after_actors")
    T.equal(voxel.depthStates[1], "test")
    T.deepEqual(graphics.colors[#graphics.colors], { 1, 1, 1, 1 })
    T.truthy(renderer:dispose())
    T.raises(function() renderer:beginPhase("background") end, "disposed")
  end)
end
