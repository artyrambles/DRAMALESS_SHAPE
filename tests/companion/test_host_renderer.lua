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
      max_items = options.max_items,
      max_vertices = options.max_vertices,
    })
    return renderer, err, voxel, graphics, Renderer
  end

  local function context()
    return {
      phase = "opaque_after_terrain",
      world = {
        id = "PALLET_TOWN",
        key = "red:PALLET_TOWN:1",
        atlasRevision = "OVERWORLD:1",
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
      frame = { sequence = 1 },
    }
  end

  T.test("creates and reuses bounded host-owned meshes", function()
    local renderer, err, voxel = new_renderer()
    T.truthy(renderer, err)
    local command = {
      kind = "mesh",
      material = "world:apron",
      geometry = { primitive = "box", width = 4, height = 5, depth = 6 },
    }
    T.equal(renderer:mesh(command, context()), 1)
    T.equal(#voxel.meshes, 1)
    T.equal(#voxel.meshes[1].vertices, 24)
    T.equal(#voxel.meshes[1].indices, 36)
    T.equal(#voxel.draws, 1)
    T.equal(renderer:mesh(command, context()), 1)
    T.equal(#voxel.meshes, 1)
    T.equal(#voxel.draws, 2)
    T.equal(renderer:status().cacheEntries, 1)
  end)

  T.test("batches instance and billboard command packets into one draw each", function()
    local renderer, err, voxel = new_renderer()
    T.truthy(renderer, err)
    local ctx = context()
    T.equal(renderer:instances({
      kind = "instances",
      material = "interior:wall",
      prototype = { primitive = "box", width = 4, height = 8, depth = 1 },
      items = {
        { x = 1, y = 4, z = 1 },
        { x = 6, y = 4, z = 1 },
      },
    }, ctx), 1)
    T.equal(#voxel.meshes[1].vertices, 48)
    T.equal(renderer:billboards({
      kind = "billboards",
      material = "wildlife:bird",
      items = { { x = 4, y = 16, z = 8 } },
    }, ctx), 1)
    T.equal(#voxel.meshes[2].vertices, 8)
    T.equal(#voxel.draws, 2)
  end)

  T.test("builds deterministic procedural stars within the item limit", function()
    local renderer, err, voxel = new_renderer({ max_items = 10 })
    T.truthy(renderer, err)
    local command = {
      kind = "billboards",
      material = "sky:stars",
      procedural = { kind = "stars", count = 5, seed = 42 },
    }
    T.equal(renderer:billboards(command, context()), 1)
    T.equal(#voxel.meshes[1].vertices, 40)
    local first = voxel.meshes[1].vertices[1]
    renderer:invalidate()
    T.equal(renderer:billboards(command, context()), 1)
    T.deepEqual(voxel.meshes[2].vertices[1], first)
  end)

  T.test("borrows atlas handles and resolves stable semantic materials", function()
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

    local command = {
      kind = "mesh",
      material = "atlas:OVERWORLD:17",
      geometry = { primitive = "plane", width = 4, depth = 4 },
    }
    T.equal(renderer:mesh(command, ctx), 1)
    T.equal(voxel.draws[1].texture, ctx.atlas)
    T.truthy(voxel.glassStates[1])
  end)

  T.test("draws an extension-owned mesh without claiming or releasing it", function()
    local renderer, err, voxel = new_renderer()
    T.truthy(renderer, err)
    local resource = { releases = 0 }
    function resource:release() self.releases = self.releases + 1 end
    T.equal(renderer:mesh({
      kind = "mesh",
      material = "host:borrowed",
      mesh = resource,
    }, context()), 1)
    T.equal(#voxel.meshes, 0)
    T.equal(voxel.draws[1].mesh, resource)
    T.truthy(renderer:dispose())
    T.equal(resource.releases, 0)
  end)

  T.test("releases derived meshes once on replacement eviction and disposal", function()
    local renderer, err, voxel = new_renderer({ max_cache_entries = 1 })
    T.truthy(renderer, err)
    local ctx = context()
    local first = {
      material = "one",
      geometry = { primitive = "plane", width = 2, depth = 2 },
    }
    local second = {
      material = "two",
      geometry = { primitive = "plane", width = 3, depth = 3 },
    }
    T.equal(renderer:mesh(first, ctx), 1)
    local first_mesh = voxel.meshes[1]
    T.equal(renderer:mesh(second, ctx), 1)
    T.equal(first_mesh.releases, 1)
    local second_mesh = voxel.meshes[2]
    ctx.world.key = "red:PALLET_TOWN:2"
    T.equal(renderer:mesh(second, ctx), 1)
    T.equal(second_mesh.releases, 1)
    local replacement = voxel.meshes[3]
    T.truthy(renderer:dispose())
    T.truthy(renderer:dispose())
    T.equal(replacement.releases, 1)
  end)

  T.test("rejects unsupported terrain and shadow primitives", function()
    local renderer, err = new_renderer()
    T.truthy(renderer, err)
    for _, primitive in ipairs({ "raised_structure", "shadow_caster" }) do
      T.raises(function()
        renderer:instances({
          kind = "instances",
          material = "test",
          prototype = { primitive = primitive },
          items = { { x = 0, y = 0, z = 0 } },
        }, context())
      end, primitive == "raised_structure" and "terrain_patch" or "not supported")
    end
    T.falsy(renderer.lights)
    T.falsy(renderer.postprocess)
  end)

  T.test("enforces dense item and vertex limits", function()
    local renderer, err = new_renderer({ max_items = 1, max_vertices = 24 })
    T.truthy(renderer, err)
    T.raises(function()
      renderer:billboards({
        material = "test",
        items = { { x = 0 }, { x = 1 } },
      }, context())
    end, "item limit")
    T.raises(function()
      renderer:instances({
        material = "test",
        prototype = { primitive = "box" },
        items = { { x = 0 }, { x = 1 } },
      }, context())
    end, "item limit")
    T.raises(function()
      renderer:mesh({
        material = "test",
        geometry = { primitive = "world_apron" },
      }, context())
    end, "vertex limit")
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
