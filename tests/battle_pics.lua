local function imageData(w, h)
  local pixels = {}
  local data = {}
  function data:getDimensions() return w, h end
  function data:getPixel(x, y)
    local p = pixels[y * w + x] or { 0, 0, 0, 0 }
    return p[1], p[2], p[3], p[4]
  end
  function data:setPixel(x, y, r, g, b, a)
    pixels[y * w + x] = { r, g, b, a }
  end
  function data:clone()
    local copy = imageData(w, h)
    for key, p in pairs(pixels) do
      copy:setPixel(key % w, math.floor(key / w), unpack(p))
    end
    return copy
  end
  return data
end

local currentCanvas
love = { graphics = {} }
local g = love.graphics
function g.getCanvas() return currentCanvas end
function g.setCanvas(value) currentCanvas = value end
function g.getBlendMode() return "alpha", "alphamultiply" end
function g.setBlendMode() end
function g.getColor() return 1, 1, 1, 1 end
function g.setColor() end
function g.clear() end
function g.newCanvas(w, h)
  return {
    data = imageData(w, h),
    newImageData = function(self) return self.data:clone() end,
    release = function() end,
  }
end
function g.draw(image)
  currentCanvas.data = image.data:clone()
end
function g.newImage(data)
  return {
    data = data,
    getDimensions = function(self) return self.data:getDimensions() end,
    setFilter = function() end,
  }
end

local data = imageData(12, 10)
for x = 1, 10 do data:setPixel(x, 1, 1, 1, 1, 1) end
for y = 1, 8 do
  data:setPixel(1, y, 1, 1, 1, 1)
  data:setPixel(10, y, 1, 1, 1, 1)
end
local image = g.newImage(data)
local BattlePics = assert(loadfile("lib/BattlePics.lua"))({})

assert(BattlePics.filled(image, false) == image,
  "wide bottom opening must remain arena-visible for a world card")
local sealed = BattlePics.filled(image, true)
assert(sealed ~= image, "pinned back sprite must seal its bottom opening")
local _, _, _, alpha = sealed.data:getPixel(5, 5)
assert(alpha == 1, "enclosed player body must regain opaque paper")

print("ok battle picture paper fill and pinned-back bottom seal")
