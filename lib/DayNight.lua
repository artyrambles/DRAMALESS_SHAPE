-- Voxel world mode: the day/night cycle -- one clock, and everything the
-- frame asks it.
--
-- THE CLOCK is twenty minutes around: ten of day, ten of night. The DAYTIME
-- row either PINS it -- DAY, NIGHT, DUSK and DAWN are fixed times on that
-- dial, not separate looks -- or lets it run (CYCLE), in which case the pin
-- the player left is where the cycle picks up. Everything below is a pure
-- function of the clock, so the pinned settings and the running cycle can
-- never drift apart: DUSK is simply the cycle stopped at sunset.
--
-- THE SUN's noon is this mod's existing sun, exactly: shear (-0.85, -0.55),
-- hanging in the southeast about 45 degrees up. That is the DAY setting and
-- the default, so a player who never touches the row sees the mod they
-- already had. From there the arc swings NORTH at both ends -- rising 70
-- degrees north of east, setting the mirror of that -- because the camera
-- looks north and the northern sky is the only sky it ever frames: a sun
-- that rose due east would light the world for ten minutes without once
-- being seen. Swung north, the disc stands in frame through dawn and dusk
-- (the hours worth looking at) and passes overhead-behind-the-camera
-- through midday, which is where a noon sun belongs.
--
-- THE MOON arcs entirely through the northern sky -- rising northeast, due
-- north at mid-night, setting northwest -- so it hangs over the diorama all
-- night and the pinned NIGHT setting puts it dead centre. Its shadows fall
-- softly south, away from it, at about two-thirds the sun's weight.
--
-- SHADOWS are the shear the light throws: direction opposite the body's
-- bearing, length its elevation's cotangent (clamped -- a rising sun throws
-- a long shadow, not an infinite one), strength fading to nothing over the
-- last twelve degrees before the horizon so the handoff between sun and
-- moon is a soft gap rather than a snap. Face shading (Voxel3D.FACE_SHADE)
-- deliberately stays the noon bake: it is a subtle angle term baked into
-- every mesh, and rebaking the world's geometry per phase buys less than
-- the cast shadows, the sky and the tint already say.
--
-- OUTDOOR ONLY. Indoors keeps the noon rig, the untinted world and no sky:
-- a cave at midnight is exactly as dark as a cave at noon, which is what a
-- room with no windows looks like. Map.isOutdoor is the same test the sky
-- already rests on; the caller passes its answer in (applyRig/tint).
--
-- Persistence: the running cycle's clock is written into the mod's own
-- save-file bucket (save.modData.<mod.id>, via mod.save) on the
-- engine's save.writing event, and read back on save.loaded/created. A save
-- with no clock in it starts at noon.

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local ModSetting = V.require("ModSetting")
local PaletteFX = require("src.render.PaletteFX")

local DayNight = {}

-- ------- the dial

DayNight.CYCLE = 1200         -- seconds around the whole dial
DayNight.DAY_LEN = 600        -- the sun's half; the moon has the rest
DayNight.BLEND = 75           -- seconds of palette blend either side of a twilight

-- where the pinned settings stop the clock
DayNight.T = { dawn = 0, day = 300, dusk = 600, night = 900 }

DayNight.KEY = "daytime"
DayNight.LABEL = "DAYTIME"

-- "sync" first: an unset or unreadable value follows the machine's own
-- clock, per the row's contract (ModSetting values[1] is the default) --
-- and forceSync below reaches for it by the same position.
DayNight.setting = ModSetting.new(DayNight.KEY, DayNight.LABEL,
                                  { "sync", "day", "night", "dusk",
                                    "dawn", "cycle" },
                                  { "SYNC", "DAY", "NIGHT", "DUSK",
                                    "DAWN", "CYCLE" })

-- The one writer for the FULL pin. While VOXEL sits on FULL the DAYTIME
-- row is off the menu with the rest of the rows the preset owns, and the
-- value is held HERE at SYNC -- the diorama preset's sky follows the clock
-- on the wall, whatever was chosen before. Called from every path that can
-- arrive at or act under FULL (main.lua: the preset itself, the rows hook,
-- the manager's options_changed), mirroring OverworldBattle.forceOG.
function DayNight.forceSync(game)
  if DayNight.setting:get() ~= "sync" then
    DayNight.setting:setIndex(1, game)
  end
end

DayNight.clock = DayNight.T.day     -- the running cycle's own position

-- ------- the two arcs
--
-- Bearings in DEGREES from east toward south (the world's +X is east, +Z
-- south), elevations in degrees up from the ground plane.

-- noon IS the existing sun: shear (-0.85, -0.55) hangs it at
-- atan2(0.55, 0.85) south of east, atan(1/hypot) = 44.65 degrees up
local NOON_KX, NOON_KZ = -0.85, -0.55
local TH_NOON = math.deg(math.atan2(-NOON_KZ, -NOON_KX))
local EL_NOON = math.deg(math.atan(1 / math.sqrt(NOON_KX * NOON_KX
                                                 + NOON_KZ * NOON_KZ)))

local TH_RISE, TH_SET = -70, 250            -- north of east / north of west
local TH_MRISE, TH_MMID, TH_MSET = -20, -90, -160
local EL_MOON = 40

DayNight.FADE_DEG = 12        -- shadows fade out over the last degrees of a rise/set

-- Shear clamp: the longest a shadow may be, in multiples of its caster's
-- height. It is a BACKSTOP against the arithmetic, not a look: 1/tan runs
-- away to infinity as the sun reaches the horizon and something has to hold
-- it, or a lamp post throws a shadow across the whole map.
--
-- It is 1/tan(FADE_DEG) exactly, and that is the whole derivation. Below
-- FADE_DEG degrees `strengthAt` is already fading the shadow out; at
-- 1/tan(FADE_DEG) the clamp cannot engage until the sun is inside that
-- window. So the clamp can only ever shorten a shadow that is ALREADY on
-- its way to nothing, which is precisely what a backstop should do.
--
-- It used to be 2.0, and 2.0 is 1/tan(26.6 deg) -- more than twice as high
-- in the sky as the fade. Measured a second at a time over the cycle, that
-- clamp was active for 520 of 1200 seconds, and for 300 OF THOSE THE SHADOW
-- WAS AT FULL STRENGTH: five minutes of every twenty spent cutting a
-- shadow the player was looking at, right through the golden hour, which is
-- the one time of day a long raking shadow is the entire point. At 4.7 that
-- number is 2 seconds.
--
-- WHAT IT COSTS, measured rather than assumed (tests/shadow_length_probe):
-- not frame time. The caster set is Quality's business, not the frustum's,
-- so a longer shadow adds no draws -- the palindrome at the worst hour came
-- back at +0.015 ms, +0.1%, on a run whose same-K spread was 1.2%. What it
-- costs is SHARPNESS, through ShadowMap.fit's `reach`, which widens the
-- light frustum onto a fixed texel budget. At the default LOW rung the
-- worst hour goes from 1.247 to 1.425 world pixels per shadow texel, +14%.
-- At HIGH -- already on the top rung, so it cannot buy its way out by
-- stepping up the ladder -- it goes 0.468 to 0.712, +52%, which sounds much
-- worse than it looks: both are still UNDER one world pixel per texel, so
-- the edge still resolves inside the diorama's own smallest unit.
DayNight.K_MAX = 1 / math.tan(math.rad(12))     -- = 4.70, see FADE_DEG above

-- The reference weights: what fraction of the light is directional. These
-- two are still the anchors -- ALPHA_SUN is the midday shadow the whole
-- mod was tuned against, and shadowScale reports against it -- but the
-- value the rig actually uses is now the curve below.
DayNight.ALPHA_SUN = 0.40     -- the existing midday shadow weight
DayNight.ALPHA_MOON = 0.26    -- moonlight is a softer press

-- Shadow weight per phase. This was one number for the whole sunlit day,
-- which made noon and the golden hour equally contrasty -- and they are
-- not. A high sun fills its own shadows, because the bright part of the sky
-- is directly above them; a low one does not, and the shadows it throws are
-- both longer and DEEPER. That is the half of "late afternoon" that length
-- alone does not buy.
--
-- It reaches further than the shadow, because this number is also `direct`
-- in Light.split: raising it moves light out of the cool sky fill and into
-- the warm directional term, which is the correct direction for a golden
-- hour and the reason the numbers here are not symmetrical about day.
-- Their sum through Light.split stays within about two per cent of what it
-- was, which is the invariant that file's header promises -- the probe
-- prints it at every sample rather than trusting this comment.
--
-- `day` and `night` are the two anchors above, unchanged: noon and midnight
-- must look exactly as they did.
DayNight.ALPHAS = {
  day = DayNight.ALPHA_SUN,
  golden = 0.52,
  dawn = 0.50,
  dusk = 0.52,
  violet = 0.34,
  night = DayNight.ALPHA_MOON,
}

-- disc PLACEMENT only: the true elevation would put the noon sun far above
-- any frame, so the arc the discs ride is squashed toward the horizon. The
-- shadows always use the true elevation.
DayNight.ELEV_SQUASH = 0.14

-- three-point arc: a at s=0, b at s=0.5, c at s=1
local function arc(a, b, c, s)
  if s < 0.5 then return a + (b - a) * 2 * s end
  return b + (c - b) * (2 * s - 1)
end

-- The body lighting the world at clock `t`: bearing and elevation in
-- degrees, and whether it is the moon. The t == DAY_LEN boundary belongs to
-- the SUN, so the pinned DUSK setting is the sun half-set in the northwest,
-- not the moon rising.
function DayNight.bodyAt(t)
  t = t % DayNight.CYCLE
  if t <= DayNight.DAY_LEN then
    local s = t / DayNight.DAY_LEN
    return arc(TH_RISE, TH_NOON, TH_SET, s),
           EL_NOON * math.sin(math.pi * s), false
  end
  local s = (t - DayNight.DAY_LEN) / (DayNight.CYCLE - DayNight.DAY_LEN)
  return arc(TH_MRISE, TH_MMID, TH_MSET, s),
         EL_MOON * math.sin(math.pi * s), true
end

-- The shadow shear that body throws: drift per pixel of height, opposite
-- the bearing, cot(elevation) long, clamped.
function DayNight.shearAt(t)
  local th, el, moon = DayNight.bodyAt(t)
  if el < 0.5 then el = 0.5 end
  local k = math.min(DayNight.K_MAX, 1 / math.tan(math.rad(el)))
  return -math.cos(math.rad(th)) * k, -math.sin(math.rad(th)) * k, moon
end

-- How much shadow the light can press right now, 0..1 of the body's own
-- weight: full up high, gone at the horizon, so sunset hands off to
-- moonrise through a soft shadowless gap instead of snapping.
function DayNight.strengthAt(t)
  local _, el = DayNight.bodyAt(t)
  local s = el / DayNight.FADE_DEG
  if s < 0 then return 0 end
  return s < 1 and s or 1
end

-- ------- the palettes
--
-- Sky bands, lightest FIRST (the horizon end), exactly the shape Sky.bands
-- reads. Six bands, not four: twilight is the whole show here, and six rungs
-- of it is what keeps a sunset reading as a gradient rather than as stripes.
-- Every channel is a multiple of 8 -- the 5-bit GBC lattice -- including
-- after blending, which re-quantises onto it.
-- `golden` and `violet` are not pins -- the DAYTIME menu cannot stop on
-- them -- but they are not mere waypoints either: the dial below holds each
-- of them, because a palette that is only ever passed THROUGH is a palette
-- nobody sees. What they exist for is the blend: day's blue horizon and
-- dusk's gold one are near-complements, and a straight lerp between
-- complements bottoms out in grey -- mid-transition the whole sky went the
-- colour of dishwater, and gold-to-navy did the same on the far side of
-- sunset. So the evening bends through a golden hour (horizon warming,
-- zenith still blue -- late afternoon), and both edges of the night bend
-- through a violet civil twilight (rose horizon under a violet sky -- the
-- real colour of that half hour).
--
-- The MORNING uses the same golden. It was left out originally on the
-- grounds that dawn's pinks and day's blues share a family and blend clean
-- without help -- which is true, and beside the point: the reason to put a
-- golden hour after sunrise is not that the blend needs rescuing, it is
-- that the hour is there in the world and the palette for it was already
-- written. Sunrise now runs dawn -> golden -> day, mirroring the evening's
-- day -> golden -> dusk, which is also the order the real sky does it in.
DayNight.PALETTES = {
  day = { { 184, 216, 248 }, { 144, 192, 248 }, { 104, 160, 240 },
          { 72, 128, 224 }, { 48, 96, 200 }, { 40, 72, 168 } },
  golden = { { 248, 216, 144 }, { 232, 184, 136 }, { 176, 152, 168 },
             { 120, 128, 192 }, { 80, 104, 184 }, { 56, 80, 152 } },
  dawn = { { 248, 216, 152 }, { 248, 176, 136 }, { 232, 136, 144 },
           { 176, 104, 168 }, { 112, 80, 168 }, { 64, 64, 136 } },
  dusk = { { 248, 200, 112 }, { 248, 152, 96 }, { 232, 104, 96 },
           { 184, 80, 136 }, { 120, 64, 152 }, { 56, 48, 120 } },
  violet = { { 200, 136, 160 }, { 152, 104, 160 }, { 112, 80, 152 },
             { 72, 56, 128 }, { 40, 40, 96 }, { 16, 24, 64 } },
  night = { { 88, 104, 160 }, { 64, 80, 136 }, { 48, 56, 112 },
            { 32, 40, 88 }, { 16, 24, 64 }, { 8, 8, 40 } },
}

-- what the world's own colours are multiplied by, per phase (0..255)
--
-- NIGHT IS DARK, and it is allowed to be, because of what the night has that
-- the old brighter one did not: a lit window is EXEMPT from this multiply.
-- The scene shader mixes the lamp colour over the finished fragment (see
-- Voxel3D, `rgb = mix(pane, lamp, glassNight * glass)`), after the hour's
-- tint and after the shadow -- so the darker this gets, the more a town
-- reads as a set of lit windows in the dark rather than as a blue-filtered
-- daytime. Dropping night from {120,136,192} to {88,104,168} takes about a
-- quarter of the light out of the world and leaves every window where it
-- was, which is most of what "the city has lighting" means here.
--
-- Violet comes down with it by a smaller step, so the descent into the dark
-- stays a slope rather than becoming a step at the last blend.
DayNight.TINTS = {
  day = { 255, 255, 255 },
  golden = { 255, 232, 208 },
  dawn = { 255, 216, 192 },
  dusk = { 255, 192, 168 },
  violet = { 160, 136, 192 },
  night = { 88, 104, 168 },
}

-- ------- how dark the night is allowed to get
--
-- SOFT is the night above: blue-filtered, readable everywhere, what this
-- file shipped with.  DEEP takes another large step down so a town reads
-- as lit windows and street lamps in real darkness rather than as a blue
-- daytime.  Windows (glassNight) and street lamps (StreetLamps, flatten to
-- lampColor) are exempt from this multiply -- they burn after the hour's
-- tint -- so DEEP only works when something is lit; with LAMPS OFF a DEEP
-- rural night is deliberately hard to read.
--
-- Only night and violet move.  Day/golden/dawn/dusk stay put: this row is
-- about the dark half of the cycle, not a global dimmer.
DayNight.darkSetting = ModSetting.new("nightDark", "N-DARK",
                                      { "deep", "soft" },
                                      { "DEEP", "SOFT" })

DayNight.TINTS_DEEP = {
  violet = { 88, 72, 120 },
  night = { 36, 44, 80 },
}

-- Matching sky palettes so the dome and the ground agree when DEEP is on.
-- Softer ladder than the soft night: same six-rung shape, every rung darker.
DayNight.PALETTES_DEEP = {
  violet = { { 140, 96, 128 }, { 104, 72, 120 }, { 72, 56, 112 },
             { 48, 40, 96 }, { 28, 28, 72 }, { 12, 16, 48 } },
  night = { { 48, 56, 96 }, { 32, 40, 80 }, { 24, 28, 64 },
            { 16, 20, 48 }, { 8, 12, 36 }, { 4, 4, 24 } },
}

function DayNight.deepNight()
  local ok, v = pcall(DayNight.darkSetting.get, DayNight.darkSetting)
  return ok and v == "deep"
end

-- ------- the weather's share of the light
--
-- One number, 0..1, written from OUTSIDE this file (lib/Weather.lua sets it
-- every tick, and zeroes it indoors and when the row is off). It is here
-- rather than read from there because the dependency only runs one way:
-- Weather asks this file what hour it is and what season the clock says, so
-- a require back the other way would be a cycle. A plain field the weather
-- pushes into costs nothing and keeps the arrow pointing one way.
--
-- What it does is the two things an overcast sky does to a world: the SKY
-- loses its colour toward a flat stratus grey, and the LIGHT under it drops
-- and goes blue, because the sun is behind cloud and what is left is skylight.
-- Both are blends, so a shower that builds over ten seconds darkens over ten
-- seconds, and both fold into the same per-second memo the hour already uses.
DayNight.overcast = 0

-- The sky with the sun taken out of it: six flat rungs of stratus, the same
-- shape as every palette above, on the same 5-bit lattice. Deliberately not
-- black -- an overcast noon is BRIGHT and grey, and the thing that says
-- "storm" is the loss of blue, not the loss of light.
DayNight.OVERCAST_SKY = { { 168, 168, 176 }, { 144, 144, 152 },
                          { 120, 120, 128 }, { 96, 96, 104 },
                          { 72, 72, 80 }, { 48, 48, 56 } }

-- and what it multiplies the world by: down a third, and cool -- the colour
-- of a day with the sun switched off
DayNight.OVERCAST_TINT = { 152, 160, 184 }

-- Overcast is fully in charge at NOON and barely speaks at MIDNIGHT: there is
-- no sun for a cloud to take away from a night sky, and dropping the light
-- further would make a rainy night unreadable rather than atmospheric.
local function cloudWeight(mix)
  local lit = (mix.day or 0) + (mix.golden or 0)
             + 0.7 * ((mix.dawn or 0) + (mix.dusk or 0))
             + 0.35 * (mix.violet or 0) + 0.25 * (mix.night or 0)
  return math.max(0, math.min(1, lit))
end

-- 0..1 as the palettes and the tint below actually apply it
local function cloudAt(mix)
  local amount = DayNight.overcast or 0
  if amount <= 0 then return 0 end
  if amount > 1 then amount = 1 end
  return amount * cloudWeight(mix)
end

-- the twilight glow around the low sun, and the discs' own four-shade
-- palettes (lightest first, so a display mode transforms them like any
-- other palette)
DayNight.GLOWS = { dawn = { 248, 232, 176 }, dusk = { 248, 224, 168 } }
DayNight.SUN_COLORS = { { 248, 240, 200 }, { 248, 208, 96 },
                        { 248, 144, 80 }, { 216, 96, 64 } }
DayNight.MOON_COLORS = { { 240, 244, 248 }, { 224, 232, 240 },
                         { 168, 184, 208 }, { 120, 136, 168 } }

-- The dial as keyframes: a repeated name is a PLATEAU, a change is a ramp
-- between the two.
--
-- ------- why every phase gets a plateau
--
-- The dial this replaces named all six phases and held only two of them.
-- Measured over the cycle a second at a time, `day` held full weight for
-- 376s and `night` for 451s -- and `dawn`, `golden` and `dusk` for ONE
-- second each, `violet` for none at all. Sixty-nine per cent of the cycle
-- was one of two flat colours and the other four palettes were only ever
-- crossed. That is not a subtle mistuning: four sets of six hand-quantised
-- rungs, the glow colours, the lamp curve and the cloud weights were all
-- being paid for and never painted. A screenshot could not show it, because
-- every frame it produced was a defensible blend of two real palettes.
--
-- So the keyframes below are laid out to give each phase a plateau it is
-- actually held at, on a fifteen-second grid (a fifth of BLEND -- the
-- coarsest step on which every edge here lands whole):
--
--     dawn      0 ->   45      45s   sun on the horizon, glowing
--     golden   120 ->  195     75s   the morning warm hour (new)
--     day      270 ->  420    150s   noon proper
--     golden   465 ->  525     60s   late afternoon
--     dusk     555 ->  600     45s   ending exactly at sunset
--     violet   645 ->  705     60s   civil twilight
--     night    780 -> 1020    240s   the moon's own hours
--     violet  1095 -> 1140     45s   the far side of the night
--
-- with the ramps taking the rest. Two constraints shape it and neither may
-- be given up:
--
-- THE PINS STAY WHERE THEY ARE. DayNight.T is unchanged, so SYNC still maps
-- the wall clock the way it did and a save still restores to the same sky.
-- Each of the four pinned times now lands INSIDE its own phase's plateau
-- rather than on a one-second spike: choosing DUSK in the menu hands the
-- player the dusk palette, which is what the row always claimed to do.
--
-- DUSK ENDS AT THE SUN, NOT ACROSS IT. The plateau closes exactly on
-- DAY_LEN, because `glow` returns nothing once bodyAt says moon (a moonrise
-- is silver, not gold). A dusk plateau straddling that boundary would have
-- its halo cut out from under it halfway through, in one frame. Ending on
-- it instead means the glow burns for the whole of dusk and goes out with
-- the sun -- which is what a sunset does.
local DIAL
local function dial()
  if DIAL then return DIAL end
  local B, D, C = DayNight.BLEND, DayNight.DAY_LEN, DayNight.CYCLE
  local u = B / 5                     -- the grid above, 15s as shipped
  DIAL = {
    { 0, "dawn" },           { 3 * u, "dawn" },
    { 8 * u, "golden" },     { 13 * u, "golden" },
    { 18 * u, "day" },       { 28 * u, "day" },
    { 31 * u, "golden" },    { 35 * u, "golden" },
    { 37 * u, "dusk" },      { D, "dusk" },
    { D + 3 * u, "violet" }, { D + 7 * u, "violet" },
    { D + 12 * u, "night" }, { C - 12 * u, "night" },
    { C - 7 * u, "violet" }, { C - 4 * u, "violet" },
    { C, "dawn" },
  }
  return DIAL
end

-- Phase weights at clock `t`, off the dial above.
function DayNight.mix(t)
  t = t % DayNight.CYCLE
  local d = dial()
  for i = 1, #d - 1 do
    local a, b = d[i], d[i + 1]
    if t >= a[1] and t < b[1] then
      if a[2] == b[2] then return { [a[2]] = 1 } end
      local u = (t - a[1]) / (b[1] - a[1])
      return { [a[2]] = 1 - u, [b[2]] = u }
    end
  end
  return { dawn = 1 }
end

-- back onto the 5-bit lattice after any blend
local function q8(v)
  v = math.floor(v / 8 + 0.5) * 8
  if v < 0 then return 0 end
  return v > 248 and 248 or v
end

local function blend3(key, mix, fallback)
  local r, g, b = 0, 0, 0
  for name, w in pairs(mix) do
    local c = key[name] or fallback
    r = r + c[1] * w
    g = g + c[2] * w
    b = b + c[3] * w
  end
  return { q8(r), q8(g), q8(b) }
end

-- The sky palette for clock `t`, blended between the phase palettes and
-- re-quantised to the lattice. Memoised per whole second AND per rung of
-- cloud: the answer only moves as the cycle runs or a shower builds, and both
-- move it slowly.
local palCache = { key = nil, pal = nil }

-- cloud in 32 rungs, so a building shower re-blends the sky about as often as
-- the clock does rather than once per frame
local function cacheKey(t)
  -- +1 bit for DEEP/SOFT so flipping N-DARK rebuilds the memo rather than
  -- serving a soft sky under a deep tint (or the reverse) for a second
  return math.floor(t % DayNight.CYCLE) * 64
         + math.floor(math.max(0, math.min(1, DayNight.overcast or 0)) * 31)
         + (DayNight.deepNight() and 32 or 0)
end

function DayNight.palette(t)
  t = t or DayNight.time()
  local key = cacheKey(t)
  if palCache.key == key then return palCache.pal end
  local mix = DayNight.mix(t)
  local cloud = cloudAt(mix)
  local deep = DayNight.deepNight()
  local pal = {}
  for i = 1, #DayNight.PALETTES.day do
    local r, g, b = 0, 0, 0
    for name, w in pairs(mix) do
      local bank = DayNight.PALETTES[name]
      if deep and DayNight.PALETTES_DEEP[name] then
        bank = DayNight.PALETTES_DEEP[name]
      end
      local c = bank[i]
      r = r + c[1] * w
      g = g + c[2] * w
      b = b + c[3] * w
    end
    -- and then toward the stratus, band by band, so the gradient survives:
    -- an overcast sky is still lighter at the horizon than overhead
    if cloud > 0 then
      local o = DayNight.OVERCAST_SKY[i] or DayNight.OVERCAST_SKY[1]
      r = r + (o[1] - r) * cloud
      g = g + (o[2] - g) * cloud
      b = b + (o[3] - b) * cloud
    end
    pal[i] = { q8(r), q8(g), q8(b) }
  end
  palCache.key, palCache.pal = key, pal
  return pal
end

-- The world tint for clock `t`, {r, g, b} in 0..1. Neutral indoors -- the
-- caller answers for where it is standing (see the header).
local tintCache = { key = nil, tint = nil }
local NEUTRAL = { 1, 1, 1 }

function DayNight.tint(outdoor, t)
  if not outdoor then return NEUTRAL end
  t = t or DayNight.time()
  local key = cacheKey(t)
  if tintCache.key ~= key then
    -- NOT re-quantised: this is a light level the shader multiplies by, not
    -- a palette colour, and the lattice's 248 ceiling would make even noon
    -- fractionally dim
    local mix = DayNight.mix(t)
    local deep = DayNight.deepNight()
    local r, g, b = 0, 0, 0
    for name, w in pairs(mix) do
      local c = DayNight.TINTS[name] or DayNight.TINTS.day
      if deep and DayNight.TINTS_DEEP[name] then
        c = DayNight.TINTS_DEEP[name]
      end
      r = r + c[1] * w
      g = g + c[2] * w
      b = b + c[3] * w
    end
    -- the cloud, on the same blend as the sky above it, so the world under a
    -- shower and the sky over it darken together rather than in two steps
    local cloud = cloudAt(mix)
    if cloud > 0 then
      local o = DayNight.OVERCAST_TINT
      r = r + (o[1] - r) * cloud
      g = g + (o[2] - g) * cloud
      b = b + (o[3] - b) * cloud
    end
    tintCache.key = key
    tintCache.tint = { r / 255, g / 255, b / 255 }
  end
  return tintCache.tint
end

-- The twilight glow: how strongly (0..1) and in what colour the sky warms
-- around the low sun. Only the SUN glows -- a moonrise is silver, not gold.
function DayNight.glow(t)
  t = t or DayNight.time()
  local _, _, moon = DayNight.bodyAt(t)
  if moon then return 0, nil end
  local mix = DayNight.mix(t)
  local amt = (mix.dawn or 0) + (mix.dusk or 0)
  if amt <= 0 then return 0, nil end
  -- cloud takes the glow with the disc: a sunset behind a rain front has no
  -- gold in it, and leaving the halo lit while the sky went grey read as the
  -- sun burning a hole through the storm
  amt = amt * (1 - cloudAt(mix))
  if amt <= 0.001 then return 0, nil end
  return amt, blend3(DayNight.GLOWS, mix, DayNight.GLOWS.dusk)
end

-- ------- the clock itself

local lastMode = nil

local function mode()
  return DayNight.setting:get() or "day"
end

-- Where SYNC reads the real clock: local hours, 0..24 with the minutes as
-- fraction. A named seam rather than a bare os.date call, so the suite can
-- hand it a fixed hour.
function DayNight.hours()
  local d = os.date("*t")
  return d.hour + d.min / 60 + d.sec / 3600
end

-- The other half of the wall clock: what MONTH it is, 1-12. A named seam for
-- the same reason `hours` is one -- the suite hands it a fixed month, and the
-- weather reads the calendar through here rather than calling os.date itself,
-- so the two halves of "the clock on the wall" can be pinned together.
function DayNight.month()
  local d = os.date("*t")
  return d.month or 1
end

-- SYNC: the machine's own time of day laid onto the dial. Local noon is
-- the DAY pin, midnight the NIGHT pin, six and eighteen the twilights --
-- an hour of the real day is fifty seconds of dial, and Kanto's evening
-- falls when the player's does.
function DayNight.syncTime()
  return ((DayNight.hours() - 6) * (DayNight.CYCLE / 24)) % DayNight.CYCLE
end

-- The effective time: the pin, the running clock under CYCLE, or the wall
-- clock under SYNC.
function DayNight.time()
  local m = mode()
  if m == "cycle" then return DayNight.clock end
  if m == "sync" then return DayNight.syncTime() end
  return DayNight.T[m] or DayNight.T.day
end

-- Advance the cycle. Runs every frame from the voxel pipeline's update hook
-- (which ticks through battles and menus too, so night falls during a long
-- fight exactly as it does on a walk). Stepping ONTO cycle picks up from
-- the pin the player was just looking at: DUSK then CYCLE rolls on into
-- night rather than teleporting the sky.
function DayNight.update(dt)
  local m = mode()
  if m ~= lastMode then
    if m == "cycle" then
      -- from a pin, its time; from SYNC, wherever the real sky already was
      DayNight.clock = DayNight.T[lastMode]
                       or (lastMode == "sync" and DayNight.syncTime())
                       or DayNight.clock
    end
    lastMode = m
  end
  if m == "cycle" and dt and dt > 0 then
    DayNight.clock = (DayNight.clock + dt) % DayNight.CYCLE
  end
end

-- The clock the RIG runs on: quantised, so the shadow map redraws a few
-- times a minute as the sun crawls rather than every frame.
DayNight.STEP = 2

function DayNight.rigTime()
  local t = DayNight.time()
  return math.floor(t / DayNight.STEP) * DayNight.STEP
end

-- ------- what the frame reads

-- Point the shared light rig at the clock -- or at noon, indoors. This
-- writes the same fields everything already reads (ShadowMap.KX/KZ for the
-- sun pass and its frustum, Voxel3D.SHADOW_* for the decal fallback and the
-- sunDark uniform), so no draw path changes to follow the sun; they follow
-- the rig, and the rig follows the clock.
-- The hour's own shadow weight, off DayNight.ALPHAS, blended like every
-- other per-phase table here. It replaces the sun-or-moon pick this used to
-- make: the phase already knows which body is up -- the dial's dusk plateau
-- closes exactly on DAY_LEN and violet opens on it -- so asking the phase
-- gives the same answer at noon and midnight and a graded one in between.
function DayNight.alphaAt(t)
  local mix = DayNight.mix(t or DayNight.rigTime())
  local a = 0
  for name, w in pairs(mix) do
    a = a + (DayNight.ALPHAS[name] or DayNight.ALPHA_SUN) * w
  end
  return a
end

function DayNight.applyRig(outdoor)
  local ShadowMap = V.require("ShadowMap")
  local Voxel3D = V.require("Voxel3D")
  local t = outdoor and DayNight.rigTime() or DayNight.T.day
  local kx, kz = DayNight.shearAt(t)
  ShadowMap.KX, ShadowMap.KZ = kx, kz
  Voxel3D.SHADOW_KX, Voxel3D.SHADOW_KZ = kx, kz
  Voxel3D.SHADOW_ALPHA = DayNight.alphaAt(t) * DayNight.strengthAt(t)
  return t
end

-- How much of a pass's OWN shadow weight the hour leaves it, 0..1 -- for a
-- caller that sets its own alpha (the battle arena) and should still lose
-- its shadows to a sunset.
function DayNight.shadowScale(outdoor, t)
  if not outdoor then return 1 end
  t = t or DayNight.rigTime()
  -- against ALPHA_SUN, so this still reports 1.0 at noon and the moon's
  -- old ratio at midnight -- the contract callers were written to -- while
  -- following the per-phase curve everywhere between
  return DayNight.alphaAt(t) / DayNight.ALPHA_SUN * DayNight.strengthAt(t)
end

-- The disc to hang in the sky, or nil when the body is set or behind the
-- camera's half of the sky. Returns a direction for the PLACEMENT arc --
-- true bearing, squashed elevation (see ELEV_SQUASH) -- plus which body it
-- is; the caller projects it through its own camera.
function DayNight.body(t)
  t = t or DayNight.time()
  local th, el, moon = DayNight.bodyAt(t)
  if el < -2 then return nil end
  local e = math.rad(el * DayNight.ELEV_SQUASH)
  local b = math.rad(th)
  return {
    dx = math.cos(b) * math.cos(e),
    dy = math.sin(e),
    dz = math.sin(b) * math.cos(e),
    moon = moon,
  }
end

-- Maps under a CANOPY: not outdoor -- there is no sky to paint and no sun
-- or moon to see, so the shadow rig stays the mod's fixed noon light,
-- which is all that ever filtered through the leaves -- but not a sealed
-- room either: night still FALLS in them. Of everything the clock does,
-- exactly one thing reaches a canopy map: the hour's tint.
DayNight.CANOPY = { VIRIDIAN_FOREST = true }

function DayNight.isCanopy(map)
  return (map and map.id and DayNight.CANOPY[map.id]) and true or false
end

-- How lit the WINDOWS are, 0..1 -- the lamps behind the glass, not the sky.
-- They come on through dusk (a lit window against a sunset is half the point
-- of having either), burn all night, and are mostly out again by dawn:
-- people wake before it is bright, they do not read at sunrise.
local LAMPS = { night = 1, violet = 1, dusk = 0.7, dawn = 0.25 }

function DayNight.windowLight(t)
  local mix = DayNight.mix(t or DayNight.time())
  local lit = 0
  for name, w in pairs(mix) do
    lit = lit + (LAMPS[name] or 0) * w
  end
  return lit
end

-- How deep into the night the hour is, 0..1, ignoring the weather. Its own
-- curve rather than `1 - windowLight` because the lamps and the darkness do
-- not track each other: a window is fully lit through the whole violet
-- twilight, while the SKY behind it is still coming down.
local DEPTH = { night = 1, violet = 0.55, dusk = 0.12, dawn = 0.08 }

local function nightDepth(mix)
  local d = 0
  for name, w in pairs(mix) do d = d + (DEPTH[name] or 0) * w end
  if d < 0 then return 0 end
  return d > 1 and 1 or d
end

-- How much of the star field is out, 0..1. The depth curve, times the
-- weather: an overcast night has NO stars, and that is the one thing about
-- them that has to be right -- a star field burning through a rain front is
-- the same mistake the glow made before cloud was taken out of it (see
-- `glow` above). Read by lib/Sky.lua, which paints them.
--
-- THE RAW `overcast`, NOT `cloudAt`. That distinction cost a probe run to
-- find. cloudAt weights the cloud BY THE HOUR on purpose -- overcast rules
-- at noon and barely speaks at midnight, because taking more light out of a
-- rainy night would make it unreadable. But that is an argument about
-- BRIGHTNESS. A cloud deck is opaque at every hour: it does not hide a
-- quarter of the stars at midnight because there is no sun to lose, it
-- hides all of them. Going through cloudAt left three quarters of the field
-- burning through a downpour.
function DayNight.starAmount(t)
  local cloud = DayNight.overcast or 0
  if cloud < 0 then cloud = 0 elseif cloud > 1 then cloud = 1 end
  local amt = nightDepth(DayNight.mix(t or DayNight.time())) * (1 - cloud)
  return amt > 0.001 and amt or 0
end

-- What colour the lamps behind the glass burn, 0..255. A constant in the
-- shader until now, which meant a window at dusk and a window at two in the
-- morning were the same colour -- and they are not: early on there is still
-- daylight to compete with and the pane reads pale, while deep in the night
-- the lamp is the warmest thing in the frame and nothing is arguing with it.
-- Same multiply either way, so this costs one uniform and no work.
DayNight.LAMP_EARLY = { 248, 232, 192 }
DayNight.LAMP_DEEP = { 255, 214, 128 }

function DayNight.lampColor(t)
  local d = nightDepth(DayNight.mix(t or DayNight.time()))
  local a, b = DayNight.LAMP_EARLY, DayNight.LAMP_DEEP
  return { (a[1] + (b[1] - a[1]) * d) / 255,
           (a[2] + (b[2] - a[2]) * d) / 255,
           (a[3] + (b[3] - a[3]) * d) / 255 }
end

-- The period name for the engine's world.tod hook (map.palette ctx.tod,
-- music.select): the dominant phase, in the vocabulary day/night mods use.
local TOD = { day = "DAY", golden = "DAY", night = "NIGHT",
              violet = "NIGHT", dawn = "MORNING", dusk = "EVENING" }

function DayNight.tod(t)
  local mix = DayNight.mix(t or DayNight.time())
  local best, bestW = "day", -1
  for name, w in pairs(mix) do
    if w > bestW then best, bestW = name, w end
  end
  return TOD[best] or "DAY"
end

-- ------- persistence
--
-- The clock rides the SAVE SLOT, not the options file: what time it is in
-- Kanto is a fact about that journey, like where the player is standing.
-- mod.save is the loader's per-mod bucket in save.modData, which persists
-- with the slot on its own -- writing the value is all there is to do.

DayNight.SAVE_KEY = "clock"

function DayNight.store()
  local saveApi = V.mod and V.mod.save
  if not (saveApi and saveApi.set) then return end
  pcall(saveApi.set, saveApi, DayNight.SAVE_KEY, DayNight.clock)
end

function DayNight.restore()
  local saveApi = V.mod and V.mod.save
  local stored = nil
  if saveApi and saveApi.get then
    local ok, got = pcall(saveApi.get, saveApi, DayNight.SAVE_KEY)
    if ok then stored = got end
  end
  -- no time set: it is day (the requirement, verbatim)
  DayNight.clock = type(stored) == "number"
                   and stored % DayNight.CYCLE or DayNight.T.day
end

return DayNight
