return function(T)
  local loader = loadstring or load

  local function load_with_argument(relative, argument)
    local source = T.read(relative)
    local chunk, err = loader(source, "@" .. relative)
    if not chunk then error(err, 0) end
    return chunk(argument)
  end

  local function with_modules(modules, fn)
    local saved = {}
    for name, value in pairs(modules) do
      saved[name] = package.loaded[name]
      package.loaded[name] = value
    end
    local ok, result = pcall(fn)
    for name in pairs(modules) do package.loaded[name] = saved[name] end
    if not ok then error(result, 0) end
    return result
  end

  T.test("WIDE selects dedicated battle camera rigs without changing CLASSIC", function()
    local Cam = load_with_argument("lib/BattleCam.lua", {})
    T.equal(Cam.rigFor({}), Cam.RIGS.tele)
    T.equal(Cam.rigFor({ cam = "wide" }), Cam.RIGS.wide)
    T.truthy(Cam.RIGS.tele_uiwide, "missing WIDE tele rig")
    T.truthy(Cam.RIGS.wide_uiwide, "missing WIDE close rig")
    T.equal(Cam.rigFor({ uiWide = true }), Cam.RIGS.tele_uiwide)
    T.equal(Cam.rigFor({ uiWide = true, cam = "wide" }), Cam.RIGS.wide_uiwide)
  end)

  T.test("arena provider tags WIDE before publishing the canonical camera", function()
    local seenUiWide
    local arena = { map = { id = "TEST" }, mid = { 0, 0 } }
    local state = { map = arena.map, player = { cellX = 1, cellY = 2 } }
    local BattleArena = { find = function() return arena end }
    local Scene = { ready = function() return true end }
    local Cam = {
      rigFor = function(a)
        seenUiWide = a.uiWide
        return { side = 1, back = 2, height = 3, lookX = 4, lookY = 5, frameH = 6 }
      end,
      reset = function() end,
      update = function() end,
    }
    local V = {
      require = function(name)
        if name == "BattleArena" then return BattleArena end
        if name == "VoxelBattleScene" then return Scene end
        if name == "BattleCam" then return Cam end
        if name == "Voxel3D" then return { available = function() return true end } end
        error("unexpected V.require " .. tostring(name), 2)
      end,
    }
    with_modules({ ["src.core.Game"] = { overworld = state } }, function()
      local Provider = load_with_argument("lib/VoxelBattleArenaProvider.lua", V)
      local out = Provider:arena({
        battle = { isWideBattleLayout = function() return true end },
        services = {},
      })
      T.equal(out, arena)
      T.equal(arena.uiWide, true)
      T.equal(seenUiWide, true, "camera was chosen before WIDE was tagged")
    end)
  end)

  T.test("WIDE FILL uses Renderer frameRects Up instead of integer fitScale", function()
    local capturedFov
    local Voxel3D
    Voxel3D = {
      available = function() return true end,
      beginScene = function()
        capturedFov = Voxel3D.camera and Voxel3D.camera.fov
        return true
      end,
      draw = function() end,
      endScene = function() return {} end,
      seams = function() end,
      glass = function() end,
    }
    local ChunkMesher = {
      setLive = function() end, request = function() end,
      pair = function() return {}, nil end,
      grass = function() return nil end, flowers = function() return nil end,
    }
    local VoxelScene = {
      prefetch = function() return {}, {}, nil, {} end,
      groundAt = function() return 0 end,
      skyColor = function() return { 0, 0, 0, 1 } end,
      skyShade = function() return { 0, 0, 0, 1 } end,
      pull = function() return 0 end,
      _modeColors = function() return {} end,
    }
    local BattleCam = {
      rig = function() return nil end,
      frameH = function() return 32 end,
    }
    local AntiAlias = {
      expand = function(w, h) return w, h end,
      resolve = function(scene) return scene end,
    }
    local DayNight = {
      applyRig = function() end, tint = function() return {1,1,1,1} end,
      isCanopy = function() return false end, windowLight = function() return 0 end,
    }
    local V = {
      require = function(name)
        local mods = {
          Mat4 = { translate = function() return {} end },
          Voxel3D = Voxel3D, ChunkMesher = ChunkMesher,
          TerrainAtlas = { setLive = function() end, forMap = function() return {} end },
          VoxelScene = VoxelScene, BattleCam = BattleCam, DayNight = DayNight,
          AntiAlias = AntiAlias, GlassMask = { texture = function() return nil end },
        }
        local value = mods[name]
        if value then return value end
        error("unexpected V.require " .. tostring(name), 2)
      end,
    }
    local graphics = {
      getPixelDimensions = function() return 304, 144 end,
      getCanvas = function() return nil end, setCanvas = function() end,
      getShader = function() return nil end, setShader = function() end,
      getBlendMode = function() return "alpha", "alphamultiply" end,
      setBlendMode = function() end,
      getDepthMode = function() return nil, false end, setDepthMode = function() end,
      getColor = function() return 1,1,1,1 end, setColor = function() end,
      getScissor = function() return nil end, setScissor = function() end,
    }
    local renderer = {
      fitScale = function() return 2 end,
      frameRects = function() return { Up = 2.25 } end,
    }
    local oldLove = love
    love = { graphics = graphics }
    local ok, err = pcall(function()
      with_modules({
        ["src.render.Renderer"] = renderer,
        ["src.render.PaletteFX"] = { pal = function() return {} end },
        ["src.world.Map"] = { isOutdoor = function() return false end },
      }, function()
        local Scene = load_with_argument("lib/VoxelBattleScene.lua", V)
        local state = {
          map = { id = "TEST", def = {}, tileset = {} },
          player = {}, neighbors = {},
          paletteNameFor = function() return "x" end,
        }
        local arena = {
          uiWide = true, map = state.map, playerCell = {0,0},
          mid = {0,0},
        }
        local inputFov = 1
        Scene.render(state, arena, function() end, {
          pose = { eye={0,0,10}, focus={0,0,0}, fov=inputFov }, pitch = 0,
        })
        local expected = 2 * math.atan(math.tan(inputFov / 2) / 2.25)
        T.near(capturedFov, expected, 1e-9)
      end)
    end)
    love = oldLove
    if not ok then error(err, 0) end
  end)

  T.test("Splash is captured stationary and promoted to an above-ground card hop", function()
    local captureKind, matrixY
    local canvas = { setFilter = function() end }
    local graphics = {
      newCanvas = function() return canvas end,
      getCanvas = function() return nil end, setCanvas = function() end,
      getShader = function() return nil end, setShader = function() end,
      getBlendMode = function() return "alpha", "alphamultiply" end,
      setBlendMode = function() end,
      getColor = function() return 1,1,1,1 end, setColor = function() end,
      getScissor = function() return nil end, setScissor = function() end,
      clear = function() end,
    }
    local BattleState = {
      picImage = function(_, image) return image end,
      resolveBattleScale = function() return 1 end,
      backPlacement = function() return 0, 0, "back" end,
      frontPlacement = function() return 0, 0, "front" end,
    }
    local Cam = { steerable = true }
    local Billboard = {
      PULL = 0,
      mesh = function() return {} end,
      matrix = function(_, _, _, _, y)
        matrixY = y
        return {}
      end,
    }
    local Voxel3D = { seams=function() end, glass=function() end, draw=function() end }
    local V = {
      backSpritesSetting = { get = function() return false end },
      require = function(name)
        if name == "BattleCam" then return Cam end
        if name == "BattleBillboard" then return Billboard end
        if name == "Voxel3D" then return Voxel3D end
        if name == "BattlePics" then return { filled=function(image) return image end } end
        error("unexpected V.require " .. tostring(name), 2)
      end,
    }
    local oldLove = love
    love = { graphics = graphics }
    local ok, err = pcall(function()
      with_modules({ ["src.battle.BattleState"] = BattleState }, function()
        local Provider = load_with_argument("lib/VoxelBattleCardProvider.lua", V)
        local player = { sprite = {} }
        local battle = {
          player = player,
          picFx = { [player] = { kind = "bounce", t = 9 } },
          drawPicsLayer = function(self)
            captureKind = self.picFx[player].kind
          end,
        }
        local context = {
          battle = battle,
          arena = { id = "dramaless:voxel-map:TEST", player = { 1, 2 } },
          groundY = 10,
          services = {},
        }
        Provider:begin(context, context.arena)
        T.equal(captureKind, nil, "bounce leaked into the captured texture")
        T.equal(Provider:cameraLocked(context), true)
        Provider:drawWorld(context)
        local expectedHop = 3 * 8 * (16 / 56)
        T.near(matrixY, 10 + expectedHop, 1e-9)
        Provider:finish()
        T.equal(Provider:cameraLocked(context), false)
      end)
    end)
    love = oldLove
    if not ok then error(err, 0) end
  end)
end
