-- Battle textbox paper replacement.
--
-- The engine draws every battle box into its 160x144 UI canvas with an
-- opaque-white rectangle followed by border and text glyphs. Recolouring that
-- exact rectangle keeps the paper and its corners in one coordinate space;
-- Renderer can then present the whole canvas with either BATTLE SIZE FIXED's
-- integer scale or FILL's fractional scale without the two drifting apart.

local TextboxStyle = {}

local unpackValues = table.unpack or unpack

local function pack(...)
  return { n = select("#", ...), ... }
end

local function setBlend(graphics, mode, alphaMode)
  if alphaMode ~= nil then
    graphics.setBlendMode(mode, alphaMode)
  else
    graphics.setBlendMode(mode)
  end
end

local function setCanvas(graphics, canvas)
  if canvas ~= nil then
    graphics.setCanvas(canvas)
  else
    graphics.setCanvas()
  end
end

local function restoreState(graphics, color, blend)
  graphics.setColor(color[1], color[2], color[3], color[4])
  setBlend(graphics, blend[1], blend[2])
end

-- Run draw while replacing only opaque-white fill rectangles.
--
-- style = { r, g, b, a } draws the engine-owned rectangle with that colour.
-- style = nil suppresses the paper while leaving borders, text and coloured
-- effects alone.
--
-- Styled fills use replace blending. Font.drawBox can issue overlapping boxes
-- for the action menu and TYPE/PP panel; normal alpha blending would stack two
-- HALF fills into a darker seam, while replace leaves every covered pixel at
-- the requested opacity.
function TextboxStyle.withFill(graphics, style, draw, ...)
  local rectangle = graphics.rectangle
  local initialColor = pack(graphics.getColor())
  local initialBlend = pack(graphics.getBlendMode())
  local args = pack(...)

  graphics.rectangle = function(mode, x, y, w, h, ...)
    if mode == "fill" then
      local r, g, b, a = graphics.getColor()
      if r > 0.99 and g > 0.99 and b > 0.99 and a > 0.99 then
        if style == nil then return end

        local color = pack(r, g, b, a)
        local blend = pack(graphics.getBlendMode())
        setBlend(graphics, "replace")
        graphics.setColor(style[1], style[2], style[3], style[4])
        local result = pack(pcall(rectangle, mode, x, y, w, h, ...))
        restoreState(graphics, color, blend)
        if not result[1] then error(result[2], 0) end
        return unpackValues(result, 2, result.n)
      end
    end
    return rectangle(mode, x, y, w, h, ...)
  end

  local result = pack(pcall(draw, unpackValues(args, 1, args.n)))
  graphics.rectangle = rectangle
  if not result[1] then
    restoreState(graphics, initialColor, initialBlend)
    error(result[2], 0)
  end
  return unpackValues(result, 2, result.n)
end

-- Draw the stateful engine text area once, into the glyph-flip scratch layer.
-- Opaque-white paper fills are mirrored to the destination canvas with the
-- selected style, then replaced by transparency in the scratch layer. The
-- transparent replacement matters for overlapping Font.drawBox calls and the
-- move menu's 8x8 tile wipes: those fills intentionally erase border pixels
-- drawn earlier in the same pass.
function TextboxStyle.withWhiteInk(graphics, style, draw, flipInk)
  local rectangle = graphics.rectangle
  local destination = graphics.getCanvas()
  local initialColor = pack(graphics.getColor())
  local initialBlend = pack(graphics.getBlendMode())
  local initialCanvas = destination
  local coveredPaper = {}

  -- Return the pieces of a rectangle not already covered by earlier paper in
  -- this same engine draw. BattleState deliberately stacks several boxes and
  -- two 8x8 tile wipes; on a translucent canvas those layers can accumulate
  -- even when the draw blend is nominally replace. Building their union as
  -- disjoint rectangles guarantees every destination pixel receives HALF
  -- exactly once. The ink canvas still receives every original full-size
  -- clear below, because those overlaps erase borders by design.
  local function uncoveredPaper(x, y, w, h)
    local pieces = { { x, y, w, h } }
    for _, cover in ipairs(coveredPaper) do
      local nextPieces = {}
      local cx1, cy1 = cover[1], cover[2]
      local cx2, cy2 = cx1 + cover[3], cy1 + cover[4]
      for _, p in ipairs(pieces) do
        local px1, py1 = p[1], p[2]
        local px2, py2 = px1 + p[3], py1 + p[4]
        local ix1, iy1 = math.max(px1, cx1), math.max(py1, cy1)
        local ix2, iy2 = math.min(px2, cx2), math.min(py2, cy2)
        if ix1 >= ix2 or iy1 >= iy2 then
          nextPieces[#nextPieces + 1] = p
        else
          if py1 < iy1 then
            nextPieces[#nextPieces + 1] = { px1, py1, p[3], iy1 - py1 }
          end
          if iy2 < py2 then
            nextPieces[#nextPieces + 1] = { px1, iy2, p[3], py2 - iy2 }
          end
          if px1 < ix1 then
            nextPieces[#nextPieces + 1] = { px1, iy1, ix1 - px1, iy2 - iy1 }
          end
          if ix2 < px2 then
            nextPieces[#nextPieces + 1] = { ix2, iy1, px2 - ix2, iy2 - iy1 }
          end
        end
      end
      pieces = nextPieces
    end
    coveredPaper[#coveredPaper + 1] = { x, y, w, h }
    return pieces
  end

  local function drawInk()
    graphics.rectangle = function(mode, x, y, w, h, ...)
      if mode == "fill" then
        local r, g, b, a = graphics.getColor()
        if r > 0.99 and g > 0.99 and b > 0.99 and a > 0.99 then
          local inkCanvas = graphics.getCanvas()

          -- flipGlyphs runs its callback directly when its shader or scratch
          -- canvas is unavailable. Keep the engine's safe opaque-white box in
          -- that fallback instead of producing unreadable dark-on-dark ink.
          if inkCanvas == destination then
            return rectangle(mode, x, y, w, h, ...)
          end

          local color = pack(r, g, b, a)
          local blend = pack(graphics.getBlendMode())
          local rectangleArgs = pack(...)
          local result = pack(pcall(function()
            if style ~= nil then
              setCanvas(graphics, destination)
              setBlend(graphics, "replace")
              graphics.setColor(style[1], style[2], style[3], style[4])
              for _, piece in ipairs(uncoveredPaper(x, y, w, h)) do
                rectangle(mode, piece[1], piece[2], piece[3], piece[4])
              end
            end

            setCanvas(graphics, inkCanvas)
            setBlend(graphics, "replace")
            graphics.setColor(0, 0, 0, 0)
            return rectangle(mode, x, y, w, h,
                             unpackValues(rectangleArgs, 1, rectangleArgs.n))
          end))

          -- Restore the ink target and draw state even if either rectangle
          -- failed, so the caller can safely unwind its own scratch pass.
          setCanvas(graphics, inkCanvas)
          restoreState(graphics, color, blend)
          if not result[1] then error(result[2], 0) end
          return unpackValues(result, 2, result.n)
        end
      end
      return rectangle(mode, x, y, w, h, ...)
    end

    return draw()
  end

  local result = pack(pcall(flipInk, drawInk))
  graphics.rectangle = rectangle
  if not result[1] then
    setCanvas(graphics, initialCanvas)
    restoreState(graphics, initialColor, initialBlend)
    error(result[2], 0)
  end
  return unpackValues(result, 2, result.n)
end

return TextboxStyle
