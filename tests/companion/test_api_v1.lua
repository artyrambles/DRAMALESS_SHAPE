return function(T)
  local function load_api()
    local source = T.read("lib/VoxelCompanionApi.lua")
    local chunk, err = loadstring(source, "@lib/VoxelCompanionApi.lua")
    if not chunk then error(err, 0) end
    return chunk()
  end

  local function all_capabilities(API)
    return {
      API.CAPABILITIES.RENDER_PHASES,
      API.CAPABILITIES.CAMERA_DELTA,
      API.CAPABILITIES.TERRAIN_PATCH,
      API.CAPABILITIES.WORLD,
      API.CAPABILITIES.QUALITY,
      API.CAPABILITIES.SHADOW_PASS,
      API.CAPABILITIES.BATTLE_PASS,
      API.CAPABILITIES.INTEGRITY,
    }
  end

  local function host_services(draw_counts)
    draw_counts = draw_counts or { mesh = 0, instances = 0, billboards = 0 }
    local draw = {
      mesh = function() draw_counts.mesh = draw_counts.mesh + 1 end,
      instances = function() draw_counts.instances = draw_counts.instances + 1 end,
      billboards = function() draw_counts.billboards = draw_counts.billboards + 1 end,
    }
    return {
      world = { id = "world-service" },
      materials = { id = "material-service" },
      draw = draw,
      quality = { tier = "test" },
      integrity = { valid = true },
    }, draw_counts
  end

  local function render_context(services)
    return {
      world = services.world,
      camera = { yaw = 0 },
      frame = { index = 1, dt = 1 / 60 },
      materials = services.materials,
      draw = services.draw,
    }
  end

  local DRAW_PHASE_ID = {
    background = 1,
    opaque_after_terrain = 2,
    translucent_after_actors = 3,
    shadow_casters = 4,
    battle_opaque = 5,
  }

  local function draw_key(phase, sequence, content)
    return ("kfp1:0123abcd:4:%d:%d:%s"):format(
      DRAW_PHASE_ID[phase],
      sequence,
      content or "0123456789abcdef"
    )
  end

  local function new_running(API, capabilities)
    local dispatcher = API.new({
      host_id = "test-host",
      capabilities = capabilities or all_capabilities(API),
    })
    local services = host_services()
    local attached, attach_err = dispatcher:attach(services)
    T.truthy(attached, attach_err)
    local started, start_err = dispatcher:start(render_context(services))
    T.truthy(started, start_err)
    return dispatcher, services
  end

  local function attempt_cleanup_reentry(dispatcher, id)
    local attempts = {}
    attempts.dispatch, attempts.dispatchError = dispatcher:dispatch("update", {})
    attempts.register, attempts.registerError = dispatcher:register({
      api = 1,
      id = "cleanup.reentry." .. id,
      lifecycle = { start = function() end },
    }, {})
    attempts.dispose, attempts.disposeError = dispatcher:dispose({}, "cleanup-reentry")
    return attempts
  end

  local function expect_cleanup_reentry_blocked(attempts)
    T.falsy(attempts.dispatch)
    T.truthy(type(attempts.dispatchError) == "string"
      and attempts.dispatchError:match("reentrant dispatch"))
    T.falsy(attempts.register)
    T.truthy(type(attempts.registerError) == "string"
      and attempts.registerError:match("register during dispatch"))
    T.falsy(attempts.dispose)
    T.truthy(type(attempts.disposeError) == "string"
      and attempts.disposeError:match("dispose during dispatch"))
  end

  T.test("exports stable v1 constants", function()
    local API = load_api()
    T.equal(API.VERSION, 1)
    T.equal(API.CAPABILITIES.CAMERA_DELTA, "camera_delta")
    T.equal(API.CAPABILITIES.TERRAIN_PATCH, "terrain_patch")
    T.equal(API.CAPABILITIES.WORLD_SNAPSHOT, "world_snapshot")
    T.equal(API.CAPABILITIES.QUALITY_TIER, "quality_tier")
    T.equal(API.CAPABILITIES.SHADOW_PASS, "shadow_pass")
    T.equal(API.CAPABILITIES.BATTLE_PASS, "battle_pass")
    T.equal(API.CAPABILITIES.INTEGRITY_STATUS, "integrity_status")
    T.equal(API.CAPABILITIES.MATERIALS, nil)
    T.equal(API.CAPABILITIES.DRAW, nil)
    T.equal(API.DRAW_SCHEMA_VERSION, 1)
    T.equal(API.DRAW_KINDS.MESH, "mesh")
    T.equal(API.DRAW_KINDS.INSTANCES, "instances")
    T.equal(API.DRAW_KINDS.BILLBOARDS, "billboards")
    T.equal(API.DRAW_LIMITS.cacheKeyBytes, 64)
    T.deepEqual(API.PHASES, {
      "update", "map_changed", "background", "opaque_after_terrain",
      "translucent_after_actors", "shadow_casters", "battle_opaque",
    })
  end)

  T.test("validates the exact baseline draw packet schema", function()
    local API = load_api()
    local texture = { id = "extension-owned-texture" }
    local mesh = {
      schemaVersion = 1,
      cacheKey = draw_key("background", 1),
      kind = "mesh",
      owner = "kfp.atmosphere",
      phase = "background",
      sequence = 1,
      sortKey = "00:horizon",
      material = "horizon:valley",
      texture = texture,
      geometry = {
        primitive = "panorama",
        sourceWidth = 4096,
        targetWidth = 2048,
        deepSkirt = true,
        distanceHaze = true,
      },
    }
    local ok, err = API.validate_draw_command(mesh, "mesh")
    T.truthy(ok, err)
    T.equal(mesh.texture, texture)

    mesh.cacheKey = "other.extension:scene_4-cache.1"
    ok, err = API.validate_draw_command(mesh, "mesh")
    T.truthy(ok, err)
    mesh.cacheKey = draw_key("background", 1)

    ok, err = API.validate_draw_command({
      schemaVersion = 1,
      cacheKey = draw_key("opaque_after_terrain", 2),
      kind = "instances",
      owner = "kfp.interior",
      phase = "opaque_after_terrain",
      sequence = 2,
      sortKey = "interior:wall",
      material = "atlas:OVERWORLD:17",
      key = "walls",
      prototype = {
        primitive = "box",
        width = 16,
        height = 24,
        depth = 1,
        cutaway = true,
        role = "wall",
      },
      items = {
        { x = 8, y = 12, z = 8, cellX = 0, cellZ = 0, side = "north" },
      },
    }, "instances")
    T.truthy(ok, err)

    ok, err = API.validate_draw_command({
      schemaVersion = 1,
      cacheKey = draw_key("background", 3),
      kind = "billboards",
      owner = "kfp.atmosphere",
      phase = "background",
      sequence = 3,
      sortKey = "20:stars",
      material = "sky:stars",
      procedural = {
        kind = "stars",
        count = 64,
        seed = 42,
        twinkle = true,
        nebula = true,
        shootingStars = false,
      },
    }, "billboards")
    T.truthy(ok, err)
  end)

  T.test("rejects path strings, unversioned commands, and non-baseline fields", function()
    local API = load_api()
    local function plane()
      return {
        schemaVersion = 1,
        cacheKey = draw_key("opaque_after_terrain", 1),
        kind = "mesh",
        owner = "kfp.world",
        phase = "opaque_after_terrain",
        sequence = 1,
        sortKey = "world:plane",
        material = "world:apron",
        geometry = { primitive = "plane", width = 16, depth = 16 },
      }
    end

    local command = plane()
    command.schemaVersion = nil
    local ok, err = API.validate_draw_command(command)
    T.falsy(ok)
    T.truthy(err:match("schemaVersion"))

    command = plane()
    command.cacheKey = "kfp1:0123abcd:" .. string.rep("9", 40)
      .. ":2:1:0123456789abcdef"
    ok, err = API.validate_draw_command(command)
    T.falsy(ok)
    T.truthy(err:match("at most 64"))

    command = plane()
    command.cacheKey = "other extension/scene"
    ok, err = API.validate_draw_command(command)
    T.falsy(ok)
    T.truthy(err:match("can contain only"))

    command = plane()
    command.geometry.asset = "assets/legacy/horizons/backdrop.png"
    ok, err = API.validate_draw_command(command)
    T.falsy(ok)
    T.truthy(err:match("unknown field"))

    command = plane()
    command.texture = "assets/legacy/horizons/backdrop.png"
    ok, err = API.validate_draw_command(command)
    T.falsy(ok)
    T.truthy(err:match("asset/path string"))

    command = plane()
    command.material = "assets/legacy/material.png"
    ok, err = API.validate_draw_command(command)
    T.falsy(ok)
    T.truthy(err:match("asset or path string"))

    command = plane()
    command.geometry = { primitive = "raised_structure" }
    ok, err = API.validate_draw_command(command)
    T.falsy(ok)
    T.truthy(err:match("not in the API v1 baseline"))

    command = plane()
    command.geometry = nil
    command.mesh = { id = "extension-owned-mesh" }
    command.texture = { id = "extension-owned-texture" }
    ok, err = API.validate_draw_command(command)
    T.falsy(ok)
    T.truthy(err:match("cannot combine an opaque mesh/resource with a texture"))

    command.mesh = nil
    command.resource = { id = "extension-owned-resource" }
    ok, err = API.validate_draw_command(command)
    T.falsy(ok)
    T.truthy(err:match("cannot combine an opaque mesh/resource with a texture"))

    command = plane()
    command.phase = "background"
    command.cacheKey = draw_key("background", 1)
    command.geometry = {
      primitive = "cloud_layer", layer = 1, parallax = 0.14,
      density = 1, seed = 11,
    }
    ok, err = API.validate_draw_command(command)
    T.falsy(ok)
    T.truthy(err:match("texture is required"))

    ok, err = API.validate_draw_command({
      schemaVersion = 1,
      cacheKey = draw_key("translucent_after_actors", 1),
      kind = "billboards",
      owner = "kfp.wildlife",
      phase = "translucent_after_actors",
      sequence = 1,
      sortKey = "wildlife:bird",
      material = "wildlife:bird",
      items = {
        { x = 1, y = 2, z = 3, extra = { derivedAsset = "birds" } },
      },
    })
    T.falsy(ok)
    T.truthy(err:match("forbidden resource locator"))
  end)

  T.test("formats untrusted table keys without conversion callbacks", function()
    local API = load_api()
    local conversion_calls = 0
    local hostile_key = setmetatable({}, {
      __tostring = function()
        conversion_calls = conversion_calls + 1
        error("untrusted key conversion ran")
      end,
    })
    local command = {
      schemaVersion = 1,
      cacheKey = draw_key("opaque_after_terrain", 1),
      kind = "mesh",
      owner = "kfp.world",
      phase = "opaque_after_terrain",
      sequence = 1,
      sortKey = "world:plane",
      material = "world:apron",
      geometry = { primitive = "plane", width = 16, depth = 16 },
    }
    command[hostile_key] = true

    local call_ok, valid, err = pcall(API.validate_draw_command, command, "mesh")
    T.truthy(call_ok)
    T.falsy(valid)
    T.truthy(type(err) == "string" and err:match("<table key>"))

    command[hostile_key] = nil
    command.kind = hostile_key
    call_ok, valid, err = pcall(API.validate_draw_command, command, "mesh")
    T.truthy(call_ok)
    T.falsy(valid)
    T.truthy(type(err) == "string" and err:match("<table key>"))

    local dispatcher = API.new({ capabilities = {} })
    call_ok, valid, err = pcall(dispatcher.dispatch, dispatcher, hostile_key, {})
    T.truthy(call_ok)
    T.falsy(valid)
    T.truthy(type(err) == "string" and err:match("<table key>"))
    T.equal(conversion_calls, 0)
  end)

  T.test("uses draw kind methods with command and the current borrowed context", function()
    local API = load_api()
    local seen_context
    local services = host_services()
    services.draw.mesh = function(command, context)
      T.equal(command.cacheKey, draw_key("background", 1))
      T.equal(context.frame.index, 1)
      seen_context = context
    end
    local dispatcher = API.new({ capabilities = { API.CAPABILITIES.RENDER_PHASES } })
    local handle, err = dispatcher:register({
      api = 1,
      id = "draw.signature",
      render = {
        background = function(context)
          context.draw.mesh({
            schemaVersion = 1,
            cacheKey = draw_key("background", 1),
            kind = "mesh",
            owner = "draw.signature",
            phase = "background",
            sequence = 1,
            sortKey = "draw:signature",
            material = "host:test",
            geometry = { primitive = "plane", width = 1, depth = 1 },
          }, context)
        end,
      },
    })
    T.truthy(handle, err)
    T.truthy(dispatcher:attach(services))
    T.truthy(dispatcher:start(render_context(services)))
    T.truthy(dispatcher:render("background", render_context(services)))
    T.raises(function() return seen_context.frame end, "no longer valid")
  end)

  T.test("builds the voxel_companion wire descriptor expected by clients", function()
    local API = load_api()
    local dispatcher = API.new({
      host_id = "DRAMALESS_SHAPE",
      host_version = "2.0.3",
      capabilities = {
        API.CAPABILITIES.WORLD_SNAPSHOT,
        API.CAPABILITIES.CAMERA_DELTA,
      },
    })
    local provider = dispatcher:provider()
    T.equal(provider.api, 1)
    T.equal(provider.host.id, "DRAMALESS_SHAPE")
    T.equal(provider.host.version, "2.0.3")
    T.equal(provider.capabilities.world_snapshot, 1)
    T.equal(provider.capabilities.camera_delta, 1)
    T.truthy(type(provider.register) == "function")

    local handle, err = provider.register({
      api = 1,
      id = "wire.lifecycle",
      lifecycle = { start = function() end },
    })
    T.truthy(handle, err)
    T.truthy(type(handle.dispose) == "function")
  end)

  T.test("rejects malformed extensions and unavailable capabilities", function()
    local API = load_api()
    local dispatcher = API.new({ capabilities = {} })

    local handle, err = dispatcher:register({ api = 2, id = "bad", phases = {} })
    T.falsy(handle)
    T.truthy(err:match("extension.api"))

    handle, err = dispatcher:register({
      api = 1,
      id = "bad id",
      camera = function() end,
    })
    T.falsy(handle)
    T.truthy(err:match("extension.id"))

    handle, err = dispatcher:register({
      api = 1,
      id = "needs.camera",
      camera = function() end,
    })
    T.falsy(handle)
    T.truthy(err:match("camera_delta"))

    handle, err = dispatcher:register({
      api = 1,
      id = "unknown.phase",
      phases = { not_a_phase = function() end },
    })
    T.falsy(handle)
    T.truthy(err:match("unknown field"))
  end)

  T.test("negotiates optional capabilities without making them required", function()
    local API = load_api()
    local dispatcher = API.new({
      capabilities = {
        API.CAPABILITIES.RENDER_PHASES,
        API.CAPABILITIES.WORLD_SNAPSHOT,
      },
    })
    local handle, err = dispatcher:register({
      api = 1,
      id = "optional.features",
      requires = { API.CAPABILITIES.RENDER_PHASES },
      optional = {
        API.CAPABILITIES.SHADOW_PASS,
        API.CAPABILITIES.BATTLE_PASS,
      },
      phases = { update = function() end },
    })
    T.truthy(handle, err)

    local duplicate
    duplicate, err = dispatcher:register({
      api = 1,
      id = "optional.duplicate",
      requires = { API.CAPABILITIES.RENDER_PHASES },
      optional = { API.CAPABILITIES.RENDER_PHASES },
      phases = { update = function() end },
    })
    T.falsy(duplicate)
    T.truthy(err:match("both required and optional"))

    local unsupported
    unsupported, err = dispatcher:register({
      api = 1,
      id = "optional.unsupported.handler",
      render = { shadow_casters = function() end },
    })
    T.falsy(unsupported)
    T.truthy(err:match("shadow_pass"))
  end)

  T.test("supports the canonical flat callback descriptor", function()
    local API = load_api()
    local dispatcher = API.new({ capabilities = all_capabilities(API) })
    local calls = {}
    local handle, err = dispatcher:register({
      api = 1,
      id = "canonical.callbacks",
      attach = function() calls[#calls + 1] = "attach" end,
      worldChanged = function(snapshot) calls[#calls + 1] = "world:" .. snapshot.id end,
      update = function(frame) calls[#calls + 1] = "update:" .. frame.index end,
      modifyCamera = function(camera)
        T.equal(camera.mode, "first_person")
        return { fovDelta = 0.01 }
      end,
      terrainPatch = function()
        return { cacheKey = "canonical", tags = { canonical = true } }
      end,
      render = {
        background = function() calls[#calls + 1] = "background" end,
      },
      invalidate = function(reason) calls[#calls + 1] = "invalidate:" .. reason end,
      dispose = function() calls[#calls + 1] = "dispose" end,
    })
    T.truthy(handle, err)
    local services = host_services()
    T.truthy(dispatcher:attach(services))
    T.truthy(dispatcher:start(render_context(services)))
    T.truthy(dispatcher:world_changed({ id = "PALLET_TOWN" }))
    T.truthy(dispatcher:update({ index = 7 }))
    T.truthy(dispatcher:render("background", render_context(services)))
    local camera = dispatcher:modifyCamera({ mode = "first_person" })
    T.near(camera.fovDelta, 0.01)
    local terrain = dispatcher:terrainPatch(render_context(services))
    T.truthy(terrain.tags.canonical)
    T.truthy(handle:invalidate({}, "map"))
    T.truthy(handle:dispose({}, "done"))
    T.deepEqual(calls, {
      "attach", "world:PALLET_TOWN", "update:7", "background",
      "invalidate:map", "dispose",
    })
  end)

  T.test("captures flat lifecycle callbacks at registration", function()
    local API = load_api()
    local calls = {}
    local spec = {
      api = 1,
      id = "flat.callback.snapshot",
      invalidate = function(reason) calls[#calls + 1] = "invalidate:" .. reason end,
      dispose = function() calls[#calls + 1] = "dispose" end,
    }
    local dispatcher = API.new({ capabilities = {} })
    local handle, err = dispatcher:register(spec)
    T.truthy(handle, err)

    spec.invalidate = function() error("mutated invalidate callback ran") end
    spec.dispose = function() error("mutated dispose callback ran") end

    T.truthy(dispatcher:attach({}))
    T.truthy(dispatcher:start({}))
    local invalidation = dispatcher:invalidate({}, "map")
    T.equal(invalidation.succeeded, 1)
    T.truthy(dispatcher:dispose({}, "shutdown"))
    T.deepEqual(calls, { "invalidate:map", "dispose" })
  end)

  T.test("bounds the registered extension set", function()
    local API = load_api()
    local dispatcher = API.new({ capabilities = {}, max_extensions = 1 })
    T.truthy(dispatcher:register({
      api = 1,
      id = "only.extension",
      lifecycle = { start = function() end },
    }))
    local handle, err = dispatcher:register({
      api = 1,
      id = "too.many",
      lifecycle = { start = function() end },
    })
    T.falsy(handle)
    T.truthy(err:match("extension limit"))
  end)

  T.test("treats materials and draw as render services, not capabilities", function()
    local API = load_api()
    T.raises(function()
      API.new({ capabilities = { "draw" } })
    end, "not a standard API v1 capability")

    local dispatcher = API.new({ capabilities = { API.CAPABILITIES.RENDER_PHASES } })
    local handle, err = dispatcher:register({
      api = 1,
      id = "render.services",
      render = { background = function() end },
    })
    T.truthy(handle, err)
    local ok
    ok, err = dispatcher:attach({})
    T.falsy(ok)
    T.truthy(err:match("materials"))
    ok, err = dispatcher:attach({
      materials = {},
      draw = { mesh = function() end },
    })
    T.falsy(ok)
    T.truthy(err:match("instances"))
    ok, err = dispatcher:attach({
      materials = {},
      draw = {
        mesh = function() end,
        instances = function() end,
        billboards = function() end,
      },
    })
    T.truthy(ok, err)

    local other = API.new({ capabilities = {} })
    handle, err = other:register({
      api = 1,
      id = "invalid.facade.capability",
      requires = { "materials" },
      lifecycle = { start = function() end },
    })
    T.falsy(handle)
    T.truthy(err:match("not a standard API v1 capability"))
  end)

  T.test("runs attach start invalidate and dispose in a bounded lifecycle", function()
    local API = load_api()
    local calls = {}
    local dispatcher = API.new({ capabilities = {} })
    local spec = {
      api = 1,
      id = "lifecycle.feature",
      lifecycle = {
        attach = function(services)
          calls[#calls + 1] = "attach:" .. services.quality.tier
        end,
        start = function(context)
          calls[#calls + 1] = "start:" .. context.mode
        end,
        invalidate = function(_, reason)
          calls[#calls + 1] = "invalidate:" .. reason
        end,
        dispose = function(_, reason)
          calls[#calls + 1] = "dispose:" .. reason
        end,
      },
    }
    local handle, err = dispatcher:register(spec)
    T.truthy(handle, err)
    local same = dispatcher:register(spec)
    T.truthy(same == handle)
    T.truthy(dispatcher:attach({ quality = { tier = "mid" } }))
    T.truthy(dispatcher:start({ mode = "play" }))
    T.truthy(dispatcher:start({ mode = "ignored" }))
    T.truthy(dispatcher:invalidate({}, "map-change"))
    T.truthy(handle:invalidate("direct"))
    T.truthy(dispatcher:dispose({}, "shutdown"))
    T.truthy(dispatcher:dispose({}, "again"))
    T.deepEqual(calls, {
      "attach:mid",
      "start:play",
      "invalidate:map-change",
      "invalidate:direct",
      "dispose:shutdown",
    })
    T.falsy(handle:is_active())
  end)

  T.test("provider registration joins an already running host", function()
    local API = load_api()
    local dispatcher = API.new({ capabilities = {} })
    local provider = dispatcher:provider()
    T.truthy(dispatcher:attach({}))
    T.truthy(dispatcher:start({ mode = "running" }))
    local calls = {}
    local handle, err = provider.register({
      api = 1,
      id = "late.extension",
      lifecycle = {
        attach = function() calls[#calls + 1] = "attach" end,
        start = function(context) calls[#calls + 1] = context.mode end,
      },
    })
    T.truthy(handle, err)
    T.truthy(handle:is_active())
    T.deepEqual(calls, { "attach", "running" })
  end)

  T.test("hot attach fault cleanup cannot reenter or dispose the dispatcher", function()
    local API = load_api()
    local dispatcher = new_running(API, {})
    local attempts
    local handle, err = dispatcher:register({
      api = 1,
      id = "fault.guard.hot.attach",
      lifecycle = {
        attach = function() error("expected hot attach fault") end,
        dispose = function()
          attempts = attempt_cleanup_reentry(dispatcher, "hot.attach")
        end,
      },
    }, {})
    T.truthy(handle, err)
    T.truthy(handle:status().faulted)
    expect_cleanup_reentry_blocked(attempts)
    T.equal(dispatcher:status().state, "running")
    local disposed, disposeError = dispatcher:dispose({}, "test-end")
    T.truthy(disposed, disposeError)
  end)

  T.test("hot start fault cleanup cannot reenter or dispose the dispatcher", function()
    local API = load_api()
    local dispatcher = new_running(API, {})
    local attempts
    local handle, err = dispatcher:register({
      api = 1,
      id = "fault.guard.hot.start",
      lifecycle = {
        start = function() error("expected hot start fault") end,
        dispose = function()
          attempts = attempt_cleanup_reentry(dispatcher, "hot.start")
        end,
      },
    }, {})
    T.truthy(handle, err)
    T.truthy(handle:status().faulted)
    expect_cleanup_reentry_blocked(attempts)
    T.equal(dispatcher:status().state, "running")
    local disposed, disposeError = dispatcher:dispose({}, "test-end")
    T.truthy(disposed, disposeError)
  end)

  T.test("handle invalidate fault cleanup cannot reenter or dispose the dispatcher", function()
    local API = load_api()
    local dispatcher = new_running(API, {})
    local attempts
    local handle, err = dispatcher:register({
      api = 1,
      id = "fault.guard.handle.invalidate",
      lifecycle = {
        invalidate = function() error("expected handle invalidate fault") end,
        dispose = function()
          attempts = attempt_cleanup_reentry(dispatcher, "handle.invalidate")
        end,
      },
    }, {})
    T.truthy(handle, err)
    local invalidated, invalidateError = handle:invalidate({}, "test")
    T.falsy(invalidated)
    T.truthy(type(invalidateError) == "string"
      and invalidateError:match("expected handle invalidate fault"))
    T.truthy(handle:status().faulted)
    expect_cleanup_reentry_blocked(attempts)
    T.equal(dispatcher:status().state, "running")
    local disposed, disposeError = dispatcher:dispose({}, "test-end")
    T.truthy(disposed, disposeError)
  end)

  T.test("dispatches phases in priority and id order", function()
    local API = load_api()
    local dispatcher = API.new({ capabilities = { API.CAPABILITIES.RENDER_PHASES } })
    local order = {}
    local function add(id, priority)
      local handle, err = dispatcher:register({
        api = 1,
        id = id,
        priority = priority,
        phases = {
          update = function() order[#order + 1] = id end,
        },
      })
      T.truthy(handle, err)
    end
    add("z.last", 10)
    add("b.second", 0)
    add("a.first", 0)
    T.truthy(dispatcher:attach({}))
    T.truthy(dispatcher:start({}))
    local report = dispatcher:dispatch("update", { dt = 0.1 })
    T.equal(report.succeeded, 3)
    T.deepEqual(order, { "a.first", "b.second", "z.last" })
  end)

  T.test("clears dispatch state after validation failures", function()
    local API = load_api()
    local services = host_services()
    local calls = 0
    local dispatcher = API.new({ capabilities = { API.CAPABILITIES.RENDER_PHASES } })
    T.truthy(dispatcher:register({
      api = 1,
      id = "dispatch.validation.recovery",
      render = { background = function() calls = calls + 1 end },
    }))
    T.truthy(dispatcher:attach(services))
    T.truthy(dispatcher:start(render_context(services)))

    local report, err = dispatcher:dispatch("background", {})
    T.falsy(report)
    T.truthy(err:match("world"))

    local hostile_context = setmetatable({}, {
      __index = function() error("validation proxy access failed") end,
    })
    report, err = dispatcher:dispatch("background", hostile_context)
    T.falsy(report)
    T.truthy(err:match("validation proxy access failed"))

    report, err = dispatcher:dispatch("background", render_context(services))
    T.truthy(report, err)
    T.equal(report.succeeded, 1)
    T.equal(calls, 1)
  end)

  T.test("isolates a phase fault and continues later extensions", function()
    local API = load_api()
    local dispatcher = API.new({ capabilities = { API.CAPABILITIES.RENDER_PHASES } })
    local ran, disposed = false, 0
    T.truthy(dispatcher:register({
      api = 1,
      id = "a.fault",
      phases = { update = function() error("expected boom") end },
      lifecycle = { dispose = function() disposed = disposed + 1 end },
    }))
    T.truthy(dispatcher:register({
      api = 1,
      id = "b.healthy",
      phases = { update = function() ran = true end },
    }))
    T.truthy(dispatcher:attach({}))
    T.truthy(dispatcher:start({}))

    local report = dispatcher:dispatch("update", {})
    T.equal(report.failed, 1)
    T.equal(report.succeeded, 1)
    T.truthy(ran)
    T.equal(disposed, 1)
    local again = dispatcher:dispatch("update", {})
    T.equal(again.skipped, 1)
    T.equal(#dispatcher:errors(), 1)
  end)

  T.test("enforces the top-level borrowed context lease", function()
    local API = load_api()
    local dispatcher = API.new({ capabilities = { API.CAPABILITIES.RENDER_PHASES } })
    local stored, assignment_failed = nil, false
    local handle = dispatcher:register({
      api = 1,
      id = "borrow.check",
      phases = {
        update = function(context)
          stored = context
          assignment_failed = not pcall(function() context.dt = 4 end)
          T.equal(context.dt, 0.25)
        end,
      },
    })
    T.truthy(handle)
    T.truthy(dispatcher:attach({}))
    T.truthy(dispatcher:start({}))
    T.truthy(dispatcher:dispatch("update", { dt = 0.25 }))
    T.truthy(assignment_failed)
    local ok, err = pcall(function() return stored.dt end)
    T.falsy(ok)
    T.truthy(tostring(err):match("no longer valid"))
  end)

  T.test("detects rawset attempts on borrowed context", function()
    local API = load_api()
    local dispatcher = API.new({ capabilities = { API.CAPABILITIES.RENDER_PHASES } })
    local handle = dispatcher:register({
      api = 1,
      id = "borrow.rawset",
      phases = { update = function(context) rawset(context, "hidden", true) end },
    })
    T.truthy(handle)
    T.truthy(dispatcher:attach({}))
    T.truthy(dispatcher:start({}))
    local report = dispatcher:dispatch("update", {})
    T.equal(report.failed, 1)
    T.truthy(handle:status().faulted)
  end)

  T.test("merges strictly additive camera deltas", function()
    local API = load_api()
    local dispatcher, services = new_running(API)
    local function register(id, priority, result)
      local handle, err = dispatcher:register({
        api = 1,
        id = id,
        priority = priority,
        camera = function() return result end,
      }, render_context(services))
      T.truthy(handle, err)
    end
    register("camera.a", 0, {
      positionDelta = { x = 1, y = 2 },
      rotationDelta = { yaw = 0.25 },
      fovDelta = 0.1,
    })
    register("camera.b", 1, {
      positionDelta = { x = -0.5, z = 3 },
      rotationDelta = { pitch = -0.1, roll = 0.05 },
      fovDelta = -0.02,
    })
    local result, report = dispatcher:dispatch_camera(render_context(services))
    T.deepEqual(result, {
      positionDelta = { x = 0.5, y = 2, z = 3 },
      rotationDelta = { yaw = 0.25, pitch = -0.1, roll = 0.05 },
      fovDelta = 0.08,
    })
    T.deepEqual(report.contributors, { "camera.a", "camera.b" })
  end)

  T.test("faults an invalid camera result without losing valid deltas", function()
    local API = load_api()
    local dispatcher, services = new_running(API)
    local valid = dispatcher:register({
      api = 1,
      id = "camera.valid",
      camera = function() return { positionDelta = { y = 4 } } end,
    }, render_context(services))
    local invalid = dispatcher:register({
      api = 1,
      id = "camera.invalid",
      camera = function() return { absolutePosition = { x = 99 } } end,
    }, render_context(services))
    T.truthy(valid)
    T.truthy(invalid)
    local result, report = dispatcher:dispatch_camera(render_context(services))
    T.equal(result.positionDelta.y, 4)
    T.equal(report.failed, 1)
    T.truthy(invalid:status().faulted)
  end)

  T.test("rejects only a camera contribution that overflows the aggregate", function()
    local API = load_api()
    local dispatcher, services = new_running(API)
    local context = render_context(services)
    T.truthy(dispatcher:register({
      api = 1,
      id = "camera.large.first",
      priority = 0,
      camera = function()
        return {
          positionDelta = { x = 1e308 },
          rotationDelta = { yaw = 1e308 },
          fovDelta = 1e308,
        }
      end,
    }, context))
    local overflow = dispatcher:register({
      api = 1,
      id = "camera.large.overflow",
      priority = 1,
      camera = function()
        return { positionDelta = { x = 1e308, y = 50 } }
      end,
    }, context)
    T.truthy(overflow)
    T.truthy(dispatcher:register({
      api = 1,
      id = "camera.large.recovery",
      priority = 2,
      camera = function()
        return {
          positionDelta = { x = -1e308, y = 2 },
          rotationDelta = { yaw = -1e308 },
          fovDelta = -1e308,
        }
      end,
    }, context))

    local result, report = dispatcher:dispatch_camera(context)
    T.equal(result.positionDelta.x, 0)
    T.equal(result.positionDelta.y, 2)
    T.equal(result.rotationDelta.yaw, 0)
    T.equal(result.fovDelta, 0)
    T.equal(report.succeeded, 2)
    T.equal(report.failed, 1)
    T.deepEqual(report.contributors, {
      "camera.large.first",
      "camera.large.recovery",
    })
    T.truthy(overflow:status().faulted)
  end)

  T.test("merges declarative terrain patches without drawing", function()
    local API = load_api()
    local dispatcher, services = new_running(API)
    local draw_counts = { mesh = 0, instances = 0, billboards = 0 }
    services.draw.mesh = function() draw_counts.mesh = draw_counts.mesh + 1 end
    services.draw.instances = function() draw_counts.instances = draw_counts.instances + 1 end
    services.draw.billboards = function() draw_counts.billboards = draw_counts.billboards + 1 end

    T.truthy(dispatcher:register({
      api = 1,
      id = "terrain.a",
      priority = 0,
      terrain = function()
        return {
          cacheKey = "map:1",
          suppressCells = { "cell:1", { key = "cell:2", x = 2, y = 3 } },
          transforms = { { key = "tree:1", dy = 8 } },
          instances = { { kind = "trunk", x = 1, y = 2 } },
          tags = { biome = "forest", shared = "a" },
        }
      end,
    }, render_context(services)))
    T.truthy(dispatcher:register({
      api = 1,
      id = "terrain.b",
      priority = 1,
      terrain = function()
        return {
          cacheKey = "weather:dry",
          transforms = { { key = "tree:2", dy = 4 } },
          tags = { shared = "b", weather = "dry" },
          invalidate = true,
        }
      end,
    }, render_context(services)))

    local patch, report = dispatcher:dispatch_terrain(render_context(services))
    T.equal(#patch.suppressCells, 2)
    T.equal(#patch.transforms, 2)
    T.equal(#patch.instances, 1)
    T.equal(patch.tags.biome, "forest")
    T.equal(patch.tags.shared, "b")
    T.equal(patch.tags.weather, "dry")
    T.truthy(patch.invalidate)
    T.truthy(type(patch.cacheKey) == "string" and #patch.cacheKey > 0)
    T.deepEqual(report.contributors, { "terrain.a", "terrain.b" })
    T.deepEqual(draw_counts, { mesh = 0, instances = 0, billboards = 0 })
  end)

  T.test("rejects later terrain suppression and transform conflicts transactionally", function()
    local API = load_api()
    local dispatcher, services = new_running(API)
    local context = render_context(services)
    T.truthy(dispatcher:register({
      api = 1,
      id = "terrain.owner",
      terrain = function()
        return {
          cacheKey = "owner",
          suppressCells = { "same-cell" },
          transforms = { { key = "same-transform", dy = 1 } },
          instances = { { kind = "owner" } },
        }
      end,
    }, context))
    local conflict = dispatcher:register({
      api = 1,
      id = "terrain.later",
      priority = 1,
      terrain = function()
        return {
          cacheKey = "later",
          suppressCells = { "same-cell" },
          transforms = { { key = "unique-transform", dy = 2 } },
          instances = { { kind = "must-not-merge" } },
        }
      end,
    }, context)
    T.truthy(conflict)

    local patch, report = dispatcher:dispatch_terrain(context)
    T.equal(report.failed, 1)
    T.equal(#patch.suppressCells, 1)
    T.equal(#patch.transforms, 1)
    T.equal(#patch.instances, 1)
    T.equal(patch.instances[1].kind, "owner")
    T.truthy(conflict:status().faulted)
  end)

  T.test("rejects a later transform owner without rejecting the first owner", function()
    local API = load_api()
    local dispatcher, services = new_running(API)
    local context = render_context(services)
    T.truthy(dispatcher:register({
      api = 1,
      id = "transform.first",
      terrain = function()
        return { cacheKey = "first", transforms = { { key = "tree:7", dy = 7 } } }
      end,
    }, context))
    local later = dispatcher:register({
      api = 1,
      id = "transform.second",
      priority = 1,
      terrain = function()
        return { cacheKey = "second", transforms = { { key = "tree:7", dy = 9 } } }
      end,
    }, context)
    T.truthy(later)

    local patch, report = dispatcher:dispatch_terrain(context)
    T.equal(report.failed, 1)
    T.equal(#patch.transforms, 1)
    T.equal(patch.transforms[1].dy, 7)
    T.truthy(later:status().faulted)
  end)

  T.test("bounds diagnostics and protects them from logger mutation", function()
    local API = load_api()
    local logged
    local dispatcher = API.new({
      capabilities = { API.CAPABILITIES.RENDER_PHASES },
      max_errors = 1,
      logger = function(event)
        logged = event
        event.fault.message = "logger changed copy"
      end,
    })
    T.truthy(dispatcher:register({
      api = 1,
      id = "diagnostic.bound",
      phases = { update = function() error(string.rep("x", 5000)) end },
    }))
    T.truthy(dispatcher:attach({}))
    T.truthy(dispatcher:start({}))
    T.truthy(dispatcher:dispatch("update", {}))

    local errors = dispatcher:errors()
    T.equal(#errors, 1)
    T.truthy(#errors[1].message <= 4096)
    T.truthy(errors[1].message ~= logged.fault.message)
  end)

  T.test("does not require terrain_patch capability for other features", function()
    local API = load_api()
    local dispatcher = API.new({
      capabilities = {
        API.CAPABILITIES.RENDER_PHASES,
        API.CAPABILITIES.CAMERA_DELTA,
      },
    })
    local phase, phase_err = dispatcher:register({
      api = 1,
      id = "render.only",
      phases = { update = function() end },
    })
    T.truthy(phase, phase_err)
    local terrain, terrain_err = dispatcher:register({
      api = 1,
      id = "terrain.optional",
      terrain = function() return {} end,
    })
    T.falsy(terrain)
    T.truthy(terrain_err:match("terrain_patch"))
  end)

  T.test("requires a normalized render context only when a render handler runs", function()
    local API = load_api()
    local dispatcher = API.new({ capabilities = { API.CAPABILITIES.RENDER_PHASES } })
    local services = host_services()
    T.truthy(dispatcher:attach(services))
    T.truthy(dispatcher:start({}))
    local empty = dispatcher:dispatch("background", {})
    T.truthy(empty)

    T.truthy(dispatcher:register({
      api = 1,
      id = "render.context",
      phases = { background = function() end },
    }, {}))
    local report, err = dispatcher:dispatch("background", {})
    T.falsy(report)
    T.truthy(err:match("world"))
  end)

  T.test("handle disposal is idempotent and permits a clean replacement", function()
    local API = load_api()
    local dispatcher = API.new({ capabilities = {} })
    local disposed = 0
    local handle = dispatcher:register({
      api = 1,
      id = "replaceable",
      lifecycle = { dispose = function() disposed = disposed + 1 end },
    })
    T.truthy(handle)
    T.truthy(dispatcher:attach({}))
    T.truthy(dispatcher:start({}))
    T.truthy(handle:dispose({}, "remove"))
    T.truthy(handle:dispose({}, "again"))
    T.equal(disposed, 1)

    local replacement, err = dispatcher:register({
      api = 1,
      id = "replaceable",
      lifecycle = { start = function() end },
    }, {})
    T.truthy(replacement, err)
    T.truthy(replacement ~= handle)
  end)
end
