local V = ...

local PixelCanvas = {}

-- Every canvas that can be attached to, copied from, or sampled alongside the
-- scene canvas must use the same DPI rule. Native-DPI versions of all three
-- targets exceed the practical canvas budget on older high-density phones
-- such as the Galaxy S9. Keep the caller's format/readability options and pin
-- the complete family to one physical texel per requested pixel.
function PixelCanvas.new(w, h, options)
  local opts = {}
  for key, value in pairs(options or {}) do opts[key] = value end
  opts.dpiscale = 1
  return pcall(love.graphics.newCanvas, w, h, opts)
end

return PixelCanvas
