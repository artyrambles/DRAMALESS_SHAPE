local function loader(path)
  local chunk, err = loadfile(path)
  if chunk then return chunk end
  -- if love and love.filesystem and love.filesystem.load then
  --   return love.filesystem.load(path)
  -- end
  return nil, err
end

local realGraphics = love.graphics
local parentCanvas, parentShader = {}, {}
local state = {
  canvas = parentCanvas, shader = parentShader,
  depth = "less", write = true,
  blend = "alpha", alpha = "alphamultiply",
  color = { 0.2, 0.3, 0.4, 0.5 },
  scissor = { 2, 3, 120, 80 },
}
local g = {}
function g.getCanvas() return state.canvas end
function g.setCanvas(value) state.canvas = value end
function g.getShader() return state.shader end
function g.setShader(value) state.shader = value end
function g.getDepthMode() return state.depth, state.write end
function g.setDepthMode(value, write) state.depth, state.write = value, write end
function g.getBlendMode() return state.blend, state.alpha end
function g.setBlendMode(value, alpha) state.blend, state.alpha = value, alpha end
function g.getColor() return unpack(state.color) end
function g.setColor(...) state.color = { ... } end
function g.getScissor() return unpack(state.scissor or {}) end
function g.setScissor(...) local v = { ... }; state.scissor = #v > 0 and v or nil end
love.graphics = g

local surface = {}
local Voxel3D = { available = function() return true end, vp = {} }
function Voxel3D.beginScene()
  state.canvas, state.shader, state.depth = {}, {}, "lequal"
  return true
end
function Voxel3D.draw() end
function Voxel3D.endScene()
  state.canvas, state.shader, state.depth = nil, nil, nil
  return surface
end

local modules = {
  Mat4 = { translate = function() return {} end },
  Voxel3D = Voxel3D,
  ChunkMesher = {
    setLive = function() end, request = function() end,
    pair = function() return {} end, grass = function() end,
    flowers = function() end,
  },
  TerrainAtlas = { setLive = function() end, forMap = function() return {} end },
  VoxelScene = {
    prefetch = function() return {}, {}, nil, {} end,
    groundAt = function() return 0 end,
    skyColor = function() return { 0, 0, 0, 1 } end,
    skyShade = function() return { 0, 0, 0, 1 } end,
    pull = function() return 0 end,
    _modeColors = function() return nil end,
  },
  BattleCam = {
    rig = function() return { eye = { 0, 1, 2 }, focus = { 0, 0, 0 }, fov = 1 }, 1 end,
    frameH = function() return 10 end,
  },
  DayNight = {
    applyRig = function() end, tint = function() return { 1, 1, 1 } end,
    isCanopy = function() return false end, windowLight = function() return 0 end,
  },
  AntiAlias = {
    expand = function(w, h) return w, h end,
    resolve = function(value)
      state.canvas, state.shader, state.depth = nil, nil, nil
      return value
    end,
  },
  GlassMask = { texture = function() end },
}

package.preload["src.render.PaletteFX"] = function()
  return { pal = function() return nil end }
end
package.preload["src.world.Map"] = function()
  return { isOutdoor = function() return false end }
end
package.preload["src.core.Game"] = function() return { data = {} } end

local Scene = assert(loader("lib/VoxelBattleScene.lua"))({
  require = function(name) return assert(modules[name], name) end,
})
local map = { id = "TEST", def = {} }
local overworld = { map = map, neighbors = {}, paletteNameFor = function() return "PAL" end }
local arena = { map = map, playerCell = { 0, 0 }, mid = { 0, 0 } }
assert(Scene.render(overworld, arena, function() end) == surface)
assert(state.canvas == parentCanvas and state.shader == parentShader,
  "voxel battle pass did not restore the parent canvas/shader")
assert(state.depth == "less" and state.write == true,
  "voxel battle pass did not restore depth state")
assert(state.blend == "alpha" and state.alpha == "alphamultiply",
  "voxel battle pass did not restore blend state")
assert(state.scissor and state.scissor[1] == 2 and state.scissor[4] == 80,
  "voxel battle pass did not restore its caller's scissor")

love.graphics = realGraphics
print("ok voxel battle provider restores parent graphics state")
