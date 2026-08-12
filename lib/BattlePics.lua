-- Restore the lightest Gen 1 shade that the decoded battle PNG keys to
-- transparency. The original white battle field supplied these pixels; a
-- voxel world exposes them as holes unless enclosed paper is put back.

local BattlePics = { FILL = { 1, 1, 1, 1 }, DRAIN = 6 }
local CUT = 0.5

local function newCache()
  return {
    [false] = setmetatable({}, { __mode = "k" }),
    [true] = setmetatable({}, { __mode = "k" }),
  }
end
local cache = newCache()

-- Read the final, palette-baked image from the GPU. dpiscale=1 is essential:
-- otherwise high-DPI mobile canvases magnify only the sprites that need fill.
local function readBack(image)
  local w, h = image:getDimensions()
  if w <= 0 or h <= 0 then return nil end
  local g = love.graphics
  local priorCanvas = g.getCanvas()
  local priorBlend, priorAlpha = g.getBlendMode()
  local r, green, b, a = g.getColor()
  local data
  local ok = pcall(function()
    local canvas = g.newCanvas(w, h, { dpiscale = 1 })
    g.setCanvas(canvas)
    g.clear(0, 0, 0, 0)
    g.setBlendMode("replace", "premultiplied")
    g.setColor(1, 1, 1, 1)
    g.draw(image, 0, 0)
    g.setCanvas()
    data = canvas:newImageData()
    if canvas.release then pcall(canvas.release, canvas) end
  end)
  if priorCanvas then g.setCanvas(priorCanvas) else g.setCanvas() end
  g.setBlendMode(priorBlend or "alpha", priorAlpha)
  g.setColor(r or 1, green or 1, b or 1, a or 1)
  return ok and data or nil
end

local function inkBounds(data, w, h)
  local x0, y0, x1, y1 = w, h, -1, -1
  for y = 0, h - 1 do
    for x = 0, w - 1 do
      local _, _, _, alpha = data:getPixel(x, y)
      if alpha > CUT then
        x0, y0 = math.min(x0, x), math.min(y0, y)
        x1, y1 = math.max(x1, x), math.max(y1, y)
      end
    end
  end
  if x1 < x0 then return nil end
  return x0, y0, x1, y1
end

local function paperColor(data, x0, y0, x1, y1)
  local best, pr, pg, pb = -1
  for y = y0, y1 do
    for x = x0, x1 do
      local r, g, b, a = data:getPixel(x, y)
      local luminance = r + g + b
      if a > CUT and luminance > best then
        best, pr, pg, pb = luminance, r, g, b
      end
    end
  end
  return pr, pg, pb
end

-- Flood transparent background from the artwork bounds. Narrow bottom gaps
-- are drains from pale bodies and are sealed; wide gaps are real space
-- between legs. A player back sprite standing on the menu seals the whole
-- bottom because the text box, rather than the arena, is beneath its feet.
local function outsidePixels(data, w, x0, y0, x1, y1, sealBottom)
  local outside, stack, top = {}, {}, 0
  local function clear(x, y)
    local _, _, _, a = data:getPixel(x, y)
    return a <= CUT
  end
  local function push(x, y)
    if x < x0 or x > x1 or y < y0 or y > y1 or not clear(x, y) then return end
    local key = y * w + x
    if outside[key] then return end
    outside[key], top, stack[top + 1] = true, top + 1, key
  end
  for x = x0, x1 do push(x, y0) end
  for y = y0, y1 do push(x0, y); push(x1, y) end
  if not sealBottom then
    local x = x0
    while x <= x1 do
      if clear(x, y1) then
        local first = x
        while x <= x1 and clear(x, y1) do x = x + 1 end
        if x - first > BattlePics.DRAIN then
          for bx = first, x - 1 do push(bx, y1) end
        end
      else
        x = x + 1
      end
    end
  end
  while top > 0 do
    local key = stack[top]
    stack[top], top = nil, top - 1
    local x, y = key % w, math.floor(key / w)
    push(x - 1, y); push(x + 1, y); push(x, y - 1); push(x, y + 1)
  end
  return outside
end

function BattlePics.filled(image, sealBottom)
  if not image then return image end
  sealBottom = sealBottom and true or false
  local slot, made = cache[sealBottom]
  local hit = slot[image]
  if hit ~= nil then return hit or image end
  local ok = pcall(function()
    local data = readBack(image)
    if not data then return end
    local w, h = data:getDimensions()
    local x0, y0, x1, y1 = inkBounds(data, w, h)
    if not x0 then return end
    local outside = outsidePixels(data, w, x0, y0, x1, y1, sealBottom)
    local fr, fg, fb = paperColor(data, x0, y0, x1, y1)
    fr, fg, fb = fr or 1, fg or 1, fb or 1
    local changed = false
    for y = y0, y1 do
      for x = x0, x1 do
        local key = y * w + x
        local _, _, _, alpha = data:getPixel(x, y)
        if not outside[key] and alpha <= CUT then
          data:setPixel(x, y, fr, fg, fb, 1)
          changed = true
        end
      end
    end
    if changed then
      made = love.graphics.newImage(data)
      made:setFilter("nearest", "nearest")
    end
  end)
  slot[image] = (ok and made) or false
  return made or image
end

function BattlePics.invalidate()
  cache = newCache()
end

return BattlePics
