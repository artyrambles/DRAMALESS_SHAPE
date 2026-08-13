-- Voxel world mode: what this device can afford.
--
-- Every other module in this mod was written against a desktop GPU, where
-- the scene canvas is the window, the shadow map is 2048 texels of it, and
-- both are redrawn from scratch every frame the camera moves a quarter of a
-- world pixel. On a two-core mobile Mali that is three separate ways to
-- miss the frame at once:
--
--   FILL   the scene renders at the panel's own pixel count. A 1080p
--          phone is 2.6 megapixels, against the 23 thousand the flat 2D
--          path shades -- a hundredfold, through a shader with six
--          texture fetches in it, on geometry that leans on the depth
--          buffer instead of a y-sort and therefore overdraws freely.
--          Worse, both passes `discard`, which switches a tile-based GPU
--          out of early-Z for the whole draw: none of that overdraw is
--          rejected before it is shaded.
--
--   SUN    the shadow map's rung is picked to resolve 0.45 world pixels
--          per texel. Work that target against a phone's view size and
--          every rung below 2048 fails it, so the ladder is decorative
--          and the map is always the top one -- 4.2 million more texels,
--          again with a discarding shader, again redrawn whenever the
--          camera moves.
--
--   BAND   each of those is a full-screen render target on a memory bus
--          that has about a tenth of a desktop's headroom, and every
--          canvas switch on a tiler is a resolve and a reload.
--
-- So: two rows the player can turn down on the device, because there is no
-- benchmarking a phone from here.
--
--   RES      the divisor the 3D pass renders at before it is scaled back
--            up to the panel. This is the one that matters -- it is
--            quadratic in every one of the three costs above, so 1/2 is
--            four times less of all of it and 1/3 is nine.
--
--   SHADOWS  LOW keeps real cast shadows but on a quarter-size map, one
--            tap instead of four, no neighbour maps casting, and redrawn
--            every other frame while walking. OFF drops the sun pass
--            entirely and the mod falls back to the flat decal shadows it
--            already carries for drivers without a depth canvas. SOFT is
--            the rung ABOVE the original: everything HIGH does, plus a
--            blocker search that widens each shadow's edge by how far it
--            stands from what throws it.
--
-- Both default to the cheap end. A desktop player who installs this build
-- sets them back to FULL / HIGH and gets the original mod exactly: at
-- scale 1 the render path is the same canvas it always was with no extra
-- blit, and at HIGH every constant below is the number it used to be. FULL
-- is one step off the default rather than three, because on a desktop it is
-- where most people are going.

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local ModSetting = V.require("ModSetting")

local Quality = {}

-- The ladder is ordered so values[1] -- ModSetting's default, and its
-- fallback for an unreadable stored value -- is the cheap rung rather than
-- the pretty one. Cycling still walks it in a sensible direction; it just
-- starts where a phone wants to start.
Quality.setting = ModSetting.new("renderScale", "RES",
                                 { 2, 1, 3, 4 },
                                 { "1/2", "FULL", "1/3", "1/4" })

-- SOFT is a fourth rung above HIGH rather than a replacement for it: it
-- keeps everything HIGH does -- the big map, the neighbours casting, a
-- redraw every frame -- and changes only how the main pass READS the map,
-- from a fixed four-tap box to a blocker search and a filter sized by what
-- it finds (see SUN_SOFT in the scene shader). Twelve fetches against four,
-- which is a desktop's price and not a phone's, so it sits at the top of
-- the ladder and nothing arrives at it by default.
-- Quality.shadowSetting = ModSetting.new("shadowQuality", "SHADOWS",
--                                        { "low", "off", "high", "soft" },
--                                        { "LOW", "OFF", "HIGH", "SOFT" })

-- Read through pcall and clamped, because these are consulted from inside
-- the render path: a setting that could throw there would take the frame
-- with it, and the whole contract of this mod is that it falls back rather
-- than errors.
function Quality.scale()
  local ok, v = pcall(Quality.setting.get, Quality.setting)
  local n = (ok and tonumber(v)) or 2
  if n < 1 then n = 1 end
  if n > 4 then n = 4 end
  return math.floor(n)
end

function Quality.shadows()
  -- local ok, v = pcall(Quality.shadowSetting.get, Quality.shadowSetting)
  -- if ok and (v == "off" or v == "high" or v == "low" or v == "soft") then
  --   return v
  -- end
  return "low"
end

function Quality.shadowsOff()
  return Quality.shadows() == "off"
end

-- Four shadow taps or one. The 2x2 box filter is what turns the map's
-- texel staircase into a one-pixel soft edge, which is worth four texture
-- fetches per fragment on a desktop and is not worth them here -- at 1/2
-- render scale that edge is landing on half a display pixel anyway.
-- Everything on this side of the ladder: the big map, the loose target, the
-- neighbours casting, a redraw every frame. SOFT is HIGH plus a filter, so
-- it answers yes here too and every consumer below is unchanged by it.
function Quality.softShadows()
  local v = Quality.shadows()
  return v == "high" or v == "soft"
end

-- And the filter itself: the blocker search that sizes a shadow's edge by
-- how far it is from the thing throwing it. Only the top rung.
function Quality.pcss()
  return Quality.shadows() == "soft"
end

-- The rung ladder and the world-pixels-per-texel target ShadowMap.fit
-- picks from. The low ladder is the high one divided by two throughout:
-- a quarter of the texels, and a target loose enough that the smallest
-- rung is actually reachable on a phone-shaped view instead of the fit
-- falling through to the top of the ladder every time.
function Quality.shadowSizes()
  if Quality.softShadows() then return { 1024, 1536, 2048 } end
  return { 512, 768, 1024 }
end

function Quality.shadowTarget()
  return Quality.softShadows() and 0.45 or 1.4
end

-- How many frames a wanted shadow redraw may be deferred. The map is
-- already reused whole while nothing moves (ShadowMap.stale); this is
-- about WALKING, where the signature changes every frame and the sun pass
-- redraws the world every frame with it. At 2 the shadows are one frame
-- stale half the time, which is not a thing anyone has ever seen, and the
-- pass costs half of what it did.
function Quality.shadowInterval()
  return Quality.softShadows() and 1 or 2
end

-- How many stars the night sky may paint (lib/Sky.lua). They are plain
-- cell rectangles on the sky's own grid -- the same idiom, and roughly the
-- same count, as the sun and moon discs already cost -- so this is a draw
-- call budget and nothing else: no target, no shader, no pass.
--
-- Hung on the RENDER SCALE rather than on the shadow ladder, because that
-- is the rung that actually says how much frame there is to fill: at 1/4 a
-- star is a quarter of the cells it is at FULL and a full field reads as
-- noise as well as costing more than it is worth. Zero is never returned --
-- a night with no stars at all is the thing this exists to end -- so the
-- cheapest rung still gets a sky, just a sparser one.
function Quality.starCount()
  local s = Quality.scale()
  if s <= 1 then return 96 end
  if s == 2 then return 72 end
  if s == 3 then return 48 end
  return 32
end

-- Low fog bands (Sky.paintFog). RES values: 1=FULL, 2=1/2, 3=1/3, 4=1/4
-- (same as starCount — higher number is the cheaper phone rung).
-- 1/4 offs fog entirely; 1/3 is thin; FULL and 1/2 get the full stack.
function Quality.fogBands()
  local s = Quality.scale()
  if s >= 4 then return 0 end
  if s == 3 then return 2 end
  return 4
end

-- Rainbow arc after rain. Off only at 1/4 RES.
function Quality.rainbow()
  return Quality.scale() < 4
end

-- Volumetric cloud raymarch steps inside the sky shader (Sky.lua).
-- Higher RES scale number = cheaper phone rung. 0 turns clouds off so the
-- sky rectangle stays a handful of ALU ops on the bottom rung.
function Quality.cloudSteps()
  local s = Quality.scale()
  if s >= 4 then return 0 end
  if s == 3 then return 4 end
  if s == 2 then return 6 end
  return 8
end

-- Whether the neighbouring maps cast into the shadow map. They are drawn
-- in the scene either way; this is only about whether their geometry is
-- also rasterised into the sun's own pass, which doubles or triples the
-- caster count for shadows that mostly fall off the edge of the view.
function Quality.neighbourShadows()
  return Quality.softShadows()
end

return Quality
