-- Opaque world surface shown while the current voxel mesh is still cooking.
--
-- Returning nil from a drawWorld pipeline asks the engine to draw its normal
-- 2D world.  That is a useful failure fallback, but it makes a healthy cold
-- build visibly jump from flat tiles to voxels.  During a known in-flight mesh
-- build this module supplies a plain black canvas instead; update keeps running
-- behind it and the first revealed world frame is already voxelized.

local V = ...

local PixelCanvas = V.require("PixelCanvas")

local Veil = {}
local target = nil

local function releaseTarget()
  if target and target.canvas and target.canvas.release then
    pcall(target.canvas.release, target.canvas)
  end
  target = nil
end

function Veil.get(w, h)
  if not (love and love.graphics and w and h and w > 0 and h > 0) then
    return nil
  end
  if not (target and target.w == w and target.h == h) then
    releaseTarget()
    local ok, canvas = PixelCanvas.new(w, h)
    if not (ok and canvas) then return nil end
    pcall(canvas.setFilter, canvas, "nearest", "nearest")

    local graphics = love.graphics
    local previous = graphics.getCanvas()
    local painted = pcall(function()
      graphics.setCanvas(canvas)
      graphics.clear(0, 0, 0, 1)
    end)
    pcall(graphics.setCanvas, previous)
    if not painted then
      if canvas.release then pcall(canvas.release, canvas) end
      return nil
    end
    target = { canvas = canvas, w = w, h = h }
  end
  return target.canvas
end

function Veil.invalidate()
  releaseTarget()
end

return Veil
