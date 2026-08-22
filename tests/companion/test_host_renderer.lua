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
      lightingStates = {}, seamStates = {},
    }
    function voxel.newMesh(vertices, indices)
      local mesh = {
        vertices = vertices,
        indices = indices,
        releases = 0,
        attachments = 0,
        detachments = 0,
      }
      function mesh:release() self.releases = self.releases + 1 end
      function mesh:setTexture(texture)
        self.texture = texture
        if texture == nil then
          self.detachments = self.detachments + 1
        else
          self.attachments = self.attachments + 1
        end
      end
      voxel.meshes[#voxel.meshes + 1] = mesh
      return mesh
    end
    function voxel.draw(mesh, texture, model)
      if texture and type(mesh.setTexture) == "function" then mesh:setTexture(texture) end
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
    function voxel.lighting(value)
      voxel.lightingStates[#voxel.lightingStates + 1] = value
    end
    function voxel.seams(value)
      voxel.seamStates[#voxel.seamStates + 1] = value
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
      mat4 = options.mat4 or {},
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

  T.test("maps a panorama once around a fixed player-centred ring", function()
    local translations = {}
    local renderer, err, voxel, graphics = new_renderer({
      mat4 = { translate = function(x, y, z)
        local model = { x = x, y = y, z = z }
        translations[#translations + 1] = model
        return model
      end },
    })
    T.truthy(renderer, err)
    local ctx = context()
    ctx.world.player = { x = 96, z = 144 }
    local command = mesh_command("mesh.panorama.g1", {
      primitive = "panorama", sourceWidth = 4096, targetWidth = 1024,
      deepSkirt = true, distanceHaze = true,
    }, { material = "horizon:valley", texture = { id = "panorama" } })

    T.equal(renderer:mesh(command, ctx), true)
    T.equal(#voxel.meshes, 1)
    T.equal(#voxel.meshes[1].vertices, 64 * 8)
    T.equal(#voxel.meshes[1].indices, 64 * 12)
    T.equal(voxel.meshes[1].vertices[1][4], 1 / 64)
    T.equal(voxel.meshes[1].vertices[2][4], 0)
    T.equal(voxel.meshes[1].vertices[64 * 8 - 7][4], 1)
    T.equal(voxel.meshes[1].vertices[64 * 8 - 6][4], 63 / 64)
    T.equal(math.floor(voxel.meshes[1].vertices[2][1] + 0.5), 900)
    T.equal(voxel.meshes[1].vertices[2][2], -1)
    T.equal(voxel.meshes[1].vertices[3][2], 300)
    T.deepEqual(translations[1], { x = 96, y = 0, z = 144 })
    T.deepEqual(voxel.lightingStates, { false, true })
    T.deepEqual(voxel.seamStates, { false, true })
    T.deepEqual(graphics.colors[1], { 0.92, 0.94, 0.98, 1 })
    T.equal(voxel.meshes[1].texture, nil)
    T.equal(voxel.meshes[1].attachments, 1)
    T.equal(voxel.meshes[1].detachments, 1)
  end)

  T.test("does not turn texture resolution into panorama world scale", function()
    local renderer, err, voxel = new_renderer()
    T.truthy(renderer, err)
    for index, target_width in ipairs({ 4096, 1024 }) do
      T.equal(renderer:mesh(mesh_command("mesh.panorama.scale." .. index, {
        primitive = "panorama", sourceWidth = 4096, targetWidth = target_width,
      }, { material = "horizon:kanto", texture = { id = index } }), context()), true)
    end
    T.equal(voxel.meshes[1].vertices[2][1], voxel.meshes[2].vertices[2][1])
    T.equal(voxel.meshes[1].vertices[3][2], voxel.meshes[2].vertices[3][2])
  end)

  T.test("rejects an untextured cloud layer without allocation", function()
    local renderer, err, voxel = new_renderer()
    T.truthy(renderer, err)
    local ok, draw_error = renderer:mesh(mesh_command("mesh.clouds.g1", {
      primitive = "cloud_layer", layer = 1, parallax = 0.1,
      density = 0.6, seed = 42,
    }, { material = "sky:clouds:1" }), context())
    T.falsy(ok)
    T.truthy(draw_error:match("binary%-coverage texture"))
    T.equal(#voxel.meshes, 0)
    T.equal(#voxel.draws, 0)
    T.equal(renderer:status().cacheEntries, 0)
  end)

  T.test("draws a high curved cloud deck from a borrowed texture", function()
    local released, translations = 0, {}
    local texture = { release = function() released = released + 1 end }
    local renderer, err, voxel, graphics = new_renderer({
      mat4 = { translate = function(x, y, z)
        local model = { x = x, y = y, z = z }
        translations[#translations + 1] = model
        return model
      end },
    })
    T.truthy(renderer, err)
    local ctx = context()
    ctx.world.player = { x = 80, z = 112 }
    T.equal(renderer:mesh(mesh_command("mesh.clouds.textured.g1", {
      primitive = "cloud_layer", layer = 1, parallax = 0.14,
      density = 0.6, seed = 42,
    }, { material = "sky:clouds:1", texture = texture }), ctx), true)
    T.truthy(#voxel.meshes[1].vertices > 1000)
    local minimum_y = math.huge
    for _, vertex in ipairs(voxel.meshes[1].vertices) do
      minimum_y = math.min(minimum_y, vertex[2])
    end
    T.truthy(math.abs(minimum_y - 248.4) < 0.000001)
    T.equal(voxel.draws[1].texture, texture)
    T.truthy(math.abs(translations[1].x - 68.8) <= 150)
    T.truthy(math.abs(translations[1].z - 96.32) <= 150)
    T.equal(translations[1].y, 0)
    T.deepEqual(voxel.lightingStates, { false, true })
    T.deepEqual(voxel.seamStates, { false, true })
    T.truthy(math.abs(graphics.colors[1][1] - 0.846) < 0.000001)
    T.truthy(math.abs(graphics.colors[1][2] - 0.904) < 0.000001)
    T.equal(graphics.colors[1][3], 1)
    T.equal(graphics.colors[1][4], 1)
    T.equal(voxel.meshes[1].texture, nil)
    T.equal(voxel.meshes[1].attachments, 1)
    T.equal(voxel.meshes[1].detachments, 1)
    T.truthy(renderer:dispose())
    T.equal(released, 0)
  end)

  T.test("keeps continuous cloud topology across quality densities", function()
    local function build(key, density, seed)
      local renderer, err, voxel, graphics = new_renderer({
        mat4 = { translate = function(x, y, z) return { x = x, y = y, z = z } end },
      })
      T.truthy(renderer, err)
      local ctx = context()
      ctx.world.player = { x = 80, z = 112 }
      T.equal(renderer:mesh(mesh_command(key, {
        primitive = "cloud_layer", layer = 2, parallax = 0.2,
        density = density, seed = seed,
      }, { material = "sky:clouds:2", texture = { id = key } }), ctx), true)
      return voxel.meshes[1], voxel.draws[1].model, graphics.colors[1]
    end

    local high, high_model, high_color = build("mesh.clouds.high", 1, 17)
    local balanced, balanced_model = build("mesh.clouds.balanced", 0.6, 17)
    local low, low_model, low_color = build("mesh.clouds.low", 0.3, 17)
    local repeat_low, repeat_model = build("mesh.clouds.low-repeat", 0.3, 17)
    local other_seed, other_model = build("mesh.clouds.other-seed", 0.3, 99)
    T.truthy(#high.vertices > 1000, "cloud deck must keep the full bounded topology")
    T.equal(#high.vertices, #balanced.vertices)
    T.equal(#high.vertices, #low.vertices)
    T.deepEqual(high.indices, balanced.indices)
    T.deepEqual(high.indices, low.indices)
    for index = 1, #high.vertices do
      T.equal(high.vertices[index][1], balanced.vertices[index][1])
      T.equal(high.vertices[index][1], low.vertices[index][1])
      T.equal(high.vertices[index][3], balanced.vertices[index][3])
      T.equal(high.vertices[index][3], low.vertices[index][3])
    end
    local function minimum_y(mesh)
      local result = math.huge
      for index = 1, #mesh.vertices do
        result = math.min(result, mesh.vertices[index][2])
      end
      return result
    end
    T.truthy(minimum_y(high) < minimum_y(balanced),
      "Balanced must lift the opaque deck above High")
    T.truthy(minimum_y(balanced) < minimum_y(low),
      "Low must lift the opaque deck above Balanced")
    T.deepEqual(low.vertices, repeat_low.vertices)
    T.deepEqual(low_model, repeat_model)
    T.falsy(other_model.x == low_model.x and other_model.z == low_model.z)
    T.equal(high_model.y, 0)
    T.equal(balanced_model.y, 0)
    T.equal(other_seed.texture, nil)
    T.equal(high_color[4], 1)
    T.equal(low_color[4], 1)

    local zero_renderer, zero_error, zero_voxel = new_renderer()
    T.truthy(zero_renderer, zero_error)
    T.equal(zero_renderer:mesh(mesh_command("mesh.clouds.zero", {
      primitive = "cloud_layer", layer = 1, parallax = 0,
      density = 0, seed = 1,
    }, { material = "sky:clouds:1", texture = { id = "zero" } }), context()), true)
    T.equal(#zero_voxel.meshes, 0)
    T.equal(zero_renderer:status().cacheEntries, 0)
  end)

  T.test("background phase tests depth without writing and restores it", function()
    local renderer, err, voxel, graphics = new_renderer()
    T.truthy(renderer, err)
    renderer:beginPhase("background")
    T.deepEqual(graphics.depths[1], { "lequal", false })
    renderer:endPhase()
    T.deepEqual(voxel.depthStates, { "test" })
  end)

  T.test("restores panorama presentation state after a draw fault", function()
    local voxel = new_voxel3d()
    local released = 0
    local texture = { release = function() released = released + 1 end }
    function voxel.draw(mesh, borrowed)
      mesh:setTexture(borrowed)
      error("injected panorama draw fault")
    end
    local renderer, err, _, graphics = new_renderer({ voxel3d = voxel })
    T.truthy(renderer, err)
    local ok, draw_error = pcall(renderer.mesh, renderer, mesh_command(
      "mesh.panorama.fault", {
        primitive = "panorama", sourceWidth = 4096, targetWidth = 2048,
      }, { material = "horizon:fault", texture = texture }
    ), context())
    T.falsy(ok)
    T.truthy(tostring(draw_error):match("injected panorama draw fault"))
    T.deepEqual(voxel.lightingStates, { false, true })
    T.deepEqual(voxel.seamStates, { false, true })
    T.equal(voxel.glassStates[#voxel.glassStates], true)
    T.deepEqual(graphics.colors[#graphics.colors], { 1, 1, 1, 1 })
    T.equal(voxel.meshes[1].texture, nil)
    T.equal(voxel.meshes[1].attachments, 1)
    T.equal(voxel.meshes[1].detachments, 1)
    T.equal(released, 0)
  end)

  T.test("detaches a borrowed texture after a successful cached draw", function()
    local released = 0
    local texture = { release = function() released = released + 1 end }
    local renderer, err, voxel = new_renderer()
    T.truthy(renderer, err)
    T.equal(renderer:mesh(mesh_command("mesh.borrowed.detach", {
      primitive = "plane", width = 4, depth = 4,
    }, { material = "host:borrowed", texture = texture }), context()), true)
    local mesh = voxel.meshes[1]
    T.equal(mesh.texture, nil)
    T.equal(mesh.attachments, 1)
    T.equal(mesh.detachments, 1)
    T.truthy(renderer:dispose())
    T.equal(released, 0)
  end)

  T.test("evicts and releases a cached mesh when texture detachment fails", function()
    local voxel = new_voxel3d()
    local base_new_mesh = voxel.newMesh
    function voxel.newMesh(vertices, indices)
      local mesh = base_new_mesh(vertices, indices)
      local base_set_texture = mesh.setTexture
      function mesh:setTexture(texture)
        if texture == nil then error("injected detach fault") end
        return base_set_texture(self, texture)
      end
      return mesh
    end
    local released = 0
    local texture = { release = function() released = released + 1 end }
    local renderer, err = new_renderer({ voxel3d = voxel })
    T.truthy(renderer, err)
    local ok, draw_error = pcall(renderer.mesh, renderer, mesh_command(
      "mesh.borrowed.detach-fault", { primitive = "plane", width = 4, depth = 4 },
      { material = "host:borrowed", texture = texture }
    ), context())
    T.falsy(ok)
    T.truthy(tostring(draw_error):match("could not detach borrowed texture"))
    T.equal(renderer:status().cacheEntries, 0)
    T.equal(renderer:status().cacheBytes, 0)
    T.equal(voxel.meshes[1].releases, 1)
    T.equal(released, 0)
    T.truthy(renderer:dispose())
    T.equal(voxel.meshes[1].releases, 1)
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

  T.test("keeps the far wall shell while melting the player row southward", function()
    local renderer, err, voxel = new_renderer()
    T.truthy(renderer, err)
    local ctx = context()
    ctx.world.player = { cellX = 10, cellZ = 10 }
    T.equal(renderer:instances(instances_command(
      "instances.cutaway.wall-cross-section",
      { primitive = "box", role = "wall", cutaway = true },
      {
        { x = 2, y = 2, z = 2, cellX = 2, cellZ = 2 },
        { x = 10, y = 2, z = 9, cellX = 10, cellZ = 9 },
        { x = 20, y = 2, z = 20, cellX = 20, cellZ = 20 },
      }
    ), ctx), true)
    T.equal(#voxel.meshes[1].vertices, 48)
  end)

  T.test("opens first-person canopy near the player without changing other modes", function()
    local command = instances_command(
      "instances.cutaway.canopy",
      { primitive = "canopy", width = 16, cutaway = true },
      {
        { x = 10, y = 24, z = 10, cellX = 10, cellZ = 10 },
        { x = 20, y = 24, z = 20, cellX = 20, cellZ = 20 },
      }
    )

    local first_renderer, first_error, first_voxel = new_renderer()
    T.truthy(first_renderer, first_error)
    local first_context = context()
    first_context.world.mode = "first_person"
    first_context.world.player = { cellX = 10, cellZ = 10 }
    T.equal(first_renderer:instances(command, first_context), true)
    T.equal(#first_voxel.meshes[1].vertices, 24)

    local third_renderer, third_error, third_voxel = new_renderer()
    T.truthy(third_renderer, third_error)
    local third_context = context()
    third_context.world.mode = "third_person"
    third_context.world.player = { cellX = 10, cellZ = 10 }
    T.equal(third_renderer:instances(command, third_context), true)
    T.equal(#third_voxel.meshes[1].vertices, 48)
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
      { primitive = "box", role = "ceiling", cutaway = true },
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

  T.test("rejects a borrowed texture on a direct opaque mesh or resource", function()
    for _, field in ipairs({ "mesh", "resource" }) do
      local renderer, err, voxel = new_renderer()
      T.truthy(renderer, err)
      local mutations, resource_releases, texture_releases = 0, 0, 0
      local resource = {
        setTexture = function() mutations = mutations + 1 end,
        release = function() resource_releases = resource_releases + 1 end,
      }
      local texture = { release = function() texture_releases = texture_releases + 1 end }
      local fields = { material = "host:borrowed", texture = texture }
      fields[field] = resource
      local result, draw_error = renderer:mesh(base_command(
        "mesh", "mesh.direct-texture." .. field, fields
      ), context())
      T.falsy(result)
      T.truthy(tostring(draw_error):match("cannot use a borrowed texture"))
      T.equal(#voxel.draws, 0)
      T.equal(mutations, 0)
      T.equal(resource_releases, 0)
      T.equal(texture_releases, 0)
    end
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
