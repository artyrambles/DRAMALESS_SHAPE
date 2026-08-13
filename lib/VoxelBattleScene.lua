-- Voxel-map arena rendering for StadiumBattleFX API 1.
-- Dramaless owns the environment pass; the host injects battle actors.

local V = ...

local Mat4 = V.require("Mat4")
local Voxel3D = V.require("Voxel3D")
local ChunkMesher = V.require("ChunkMesher")
local TerrainAtlas = V.require("TerrainAtlas")
local VoxelScene = V.require("VoxelScene")
local BattleCam = V.require("BattleCam")
local DayNight = V.require("DayNight")
local AntiAlias = V.require("AntiAlias")
local PaletteFX = require("src.render.PaletteFX")
local Map = require("src.world.Map")

local Scene = {}
local GB_W, GB_H = 160, 144
local INDOOR_SHADE = 4

local function pixelSize()
  if love.graphics.getPixelDimensions then
    local w, h = love.graphics.getPixelDimensions()
    if w and h and w > 0 and h > 0 then return w, h end
  end
  if love.graphics.getDimensions then return love.graphics.getDimensions() end
  return GB_W, GB_H
end

local function fitScale()
  local ok, Renderer = pcall(require, "src.render.Renderer")
  if ok and Renderer and type(Renderer.fitScale) == "function" then
    local okScale, scale = pcall(Renderer.fitScale, Renderer)
    if okScale and type(scale) == "number" and scale > 0 then return scale end
  end
  local w, h = pixelSize()
  return math.max(1, math.floor(math.min(w / GB_W, h / GB_H)))
end

local function windowCamera(camera, ph, scale)
  if not camera then return nil end
  local out = {}
  for key, value in pairs(camera) do out[key] = value end
  local span = GB_H * math.max(1, scale or 1)
  if type(out.fov) == "number" and span > 0 then
    out.fov = 2 * math.atan(math.tan(out.fov / 2) * ph / span)
  end
  return out
end

local function captureGraphics()
  local g = love.graphics
  local sx, sy, sw, sh
  if g.getScissor then sx, sy, sw, sh = g.getScissor() end
  local blend, alpha = g.getBlendMode()
  local depth, write = g.getDepthMode()
  return {
    canvas = g.getCanvas(), shader = g.getShader(),
    blend = blend, alpha = alpha, depth = depth, write = write,
    color = { g.getColor() }, scissor = sx and { sx, sy, sw, sh } or false,
  }
end

local function restoreGraphics(saved)
  local g = love.graphics
  g.setCanvas(saved.canvas)
  g.setShader(saved.shader)
  if saved.depth then g.setDepthMode(saved.depth, saved.write)
  else g.setDepthMode() end
  g.setBlendMode(saved.blend or "alpha", saved.alpha)
  g.setColor(unpack(saved.color))
  if saved.scissor then g.setScissor(unpack(saved.scissor))
  else g.setScissor() end
end

local function paletteFor(state, home)
  return function(map)
    return PaletteFX.pal(require("src.core.Game").data,
      state:paletteNameFor(map or home))
  end
end

local function prefetch(state, host)
  if host == state.map then return VoxelScene.prefetch(state) end
  local live = { [host.id] = true, [state.map.id] = true }
  for _, nb in ipairs(state.neighbors or {}) do live[nb.map.id] = true end
  ChunkMesher.setLive(live)
  TerrainAtlas.setLive(live)
  ChunkMesher.request(host, false, nil, true)
  local terrain, water = ChunkMesher.pair(host, false)
  if not terrain then terrain, water = ChunkMesher.pair(host, true) end
  return terrain, {}, water, {}
end


function Scene.ready(state, arena)
  if not (state and state.map and arena) or not Voxel3D.available() then return false end
  local terrain = prefetch(state, arena.map or state.map)
  return terrain ~= nil
end

local function groundAt(host, arena)
  local cell = arena and arena.playerCell
  if not cell then return 0 end
  local ok, height = pcall(VoxelScene.groundAt, host, cell[1], cell[2])
  return ok and height or 0
end

local function frameHeight(camera, fallback)
  if not (camera and type(camera.eye) == "table"
      and type(camera.focus) == "table" and type(camera.fov) == "number") then
    return fallback
  end
  local dx = camera.eye[1] - camera.focus[1]
  local dy = camera.eye[2] - camera.focus[2]
  local dz = camera.eye[3] - camera.focus[3]
  local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
  if distance < 1e-6 then return fallback end
  return 2 * distance * math.tan(camera.fov / 2)
end

function Scene.render(state, arena, drawActors, hostCamera)
  if not (state and state.map and arena and type(drawActors) == "function") then
    return nil
  end
  if not Voxel3D.available() then return nil end

  local host = arena.map or state.map
  local neighbors = host == state.map and (state.neighbors or {}) or {}
  local terrain, nbMesh, water, nbWater = prefetch(state, host)
  if not terrain then return nil end

  local colors = paletteFor(state, host)
  local function atlasFor(map)
    return TerrainAtlas.forMap(map, VoxelScene._modeColors(colors, map))
  end

  local outdoor = host.def and Map.isOutdoor(host.def) or false
  DayNight.applyRig(outdoor)
  Voxel3D.tint = DayNight.tint(outdoor or DayNight.isCanopy(host))
  local GlassMask = V.require("GlassMask")
  Voxel3D.glassMask = outdoor and GlassMask.texture(host.tileset) or nil
  Voxel3D.glassNight = outdoor and DayNight.windowLight() or 0
  Voxel3D.glassGlint = 0

  local groundY = groundAt(host, arena)
  local pw, ph = pixelSize()
  local camera = hostCamera and hostCamera.pose
  local pitch = hostCamera and hostCamera.pitch
  if not camera then camera, pitch = BattleCam.rig(arena, groundY) end
  camera = windowCamera(camera, ph, fitScale())
  local cx, cy = arena.mid[1], arena.mid[2]
  local vh = frameHeight(camera, BattleCam.frameH(arena))
  local vw = vh * pw / ph
  local sky = VoxelScene.skyColor(host, 1)
    or VoxelScene.skyShade(INDOOR_SHADE, 1)
  local rw, rh = AntiAlias.expand(pw, ph)

  -- Voxel3D and AntiAlias historically rendered as the top-level overworld
  -- pass and therefore ended with setCanvas(). Under API 1 this function is
  -- nested inside StadiumBattleFX's battle surface; preserve the complete
  -- caller state so the resolved arena, actors, HUD, and text all land back
  -- on that surface instead of the window or a stale intermediate canvas.
  local graphics = captureGraphics()
  Voxel3D.camera = camera
  local ok, result = pcall(function()
    if not Voxel3D.beginScene(rw, rh, cx, cy, vw, vh, sky, "battle") then
      return nil
    end
    Voxel3D.draw(terrain, atlasFor(host), nil)
    for i, nb in ipairs(neighbors) do
      Voxel3D.draw(nbMesh[i], atlasFor(nb.map), Mat4.translate(nb.ox, 0, nb.oy))
    end
    if water then Voxel3D.draw(water, atlasFor(host)) end
    for i, nb in ipairs(neighbors) do
      if nbWater and nbWater[i] then
        Voxel3D.draw(nbWater[i], atlasFor(nb.map), Mat4.translate(nb.ox, 0, nb.oy))
      end
    end

    local pull = VoxelScene.pull(math.max(pitch or 0, 0.05))
    Voxel3D.draw(ChunkMesher.grass(host), atlasFor(host), nil, pull)
    for _, nb in ipairs(neighbors) do
      Voxel3D.draw(ChunkMesher.grass(nb.map), atlasFor(nb.map),
        Mat4.translate(nb.ox, 0, nb.oy), pull)
    end
    local fpull = math.max(0, pull - 8 * math.sin(math.max(pitch or 0, 0.05)))
    Voxel3D.draw(ChunkMesher.flowers(host), atlasFor(host), nil, fpull)
    for _, nb in ipairs(neighbors) do
      Voxel3D.draw(ChunkMesher.flowers(nb.map), atlasFor(nb.map),
        Mat4.translate(nb.ox, 0, nb.oy), fpull)
    end

    -- Actor rendering may bind its own shader. It is intentionally the last
    -- draw in this depth pass so Dramaless never has to restore host internals.
    drawActors({
      vp = Voxel3D.vp,
      groundY = groundY,
      width = rw,
      height = rh,
    })

    return AntiAlias.resolve(Voxel3D.endScene(), pw, ph, "battle")
  end)
  Voxel3D.camera = nil
  restoreGraphics(graphics)
  if not ok then
    error(result, 0)
  end
  return result
end

return Scene
