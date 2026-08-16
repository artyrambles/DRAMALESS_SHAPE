-- Voxel world mode: the screen-space pass -- fake ray tracing.
--
-- Everything in this file is a RAY MARCH against the depth buffer the 3D
-- pass has already filled. Nothing here traces the world: there is no BVH,
-- no voxel octree, no second scene. There is one image of the world and one
-- record of how far away each of its pixels is, and every effect below is a
-- question asked by walking a straight line across that record and reading
-- what it hits. That is the whole trick, and it is why this costs texture
-- fetches rather than geometry -- the scene is drawn exactly once either
-- way.
--
-- Three questions get asked, on a ladder, because they cost very different
-- amounts:
--
--   AO      "how much of the sky can this point actually see?" Eight
--           neighbours in a ring, each one asked whether it stands ABOVE
--           this point's own surface plane. Where many do, the point is in
--           a corner and the sky is boxed out of it -- so the inside of
--           every doorway, the foot of every wall and the gap between two
--           trees darkens, which is the single cheapest thing that makes a
--           diorama read as built out of solid objects rather than assembled
--           from stickers. This is the rung that matters most per
--           millisecond and it is on at every rung above OFF.
--
--   SSR     the water reflects -- the ponds AND the puddles, and the two are
--           not the same surface. See the PUDDLES section below and the note
--           over PUDDLE_AMOUNT: they were sharing one Fresnel curve and one
--           ripple, and both belonged to the pond. A puddle is a film over
--           dark paving with nothing underneath it to look into, so it is
--           nearly all reflection at every camera rung -- and what moves on
--           it is the RAIN landing in it, at the scale of a raindrop, not the
--           sea's swell at the scale of five cells.
--
--           A real reflection off the swell: the ray
--           leaves the surface along the wave's OWN normal -- the analytic
--           one the vertex shader displaced it by, recomputed here from the
--           same two crossing trains -- and is marched across the depth
--           buffer until it lands on something, which is then read out of
--           the colour buffer. So a pond reflects the tree standing beside
--           it, the reflection MOVES with the crest that carries it, and
--           what it reflects is whatever is actually there rather than a
--           painted-in guess. Where the ray runs off the edge of the frame
--           or finds nothing, the sky's own haze fills in -- which is the
--           honest answer, since a ray that leaves the screen going upward
--           left toward the sky.
--
--   SHAFTS  light through the gaps. A march from every pixel TOWARD the
--           sun's disc (the same one the sky already hangs, projected
--           through the same camera), counting how much of that line is
--           open sky. A pixel with a clear run to the sun gets the whole
--           beam; one with a roof in the way gets none, and the boundary
--           between them is a god ray. Only at MAX, because it is a march
--           across the entire frame rather than across the water.
--
-- ------- why this is a separate pass and not more shader in the scene
--
-- Because none of it can be answered while the scene is being drawn. A
-- fragment being shaded knows its own depth and nothing else's; the
-- reflection of a building that has not been rasterised yet is not in any
-- buffer to read. So the scene finishes, and THEN this runs over the
-- finished pair of images -- which is also what makes it free of the draw
-- order entirely: nothing here cares what was submitted when.
--
-- ------- where it sits in the frame
--
-- Inside Voxel3D.endScene, at the resolution the scene was RASTERISED at
-- rather than the one it is presented at. That matters at RES 1/2 or below:
-- running a screen-space pass over an already-upscaled image is paying four
-- times over to march through detail that was never rendered. It also means
-- the battle arena gets all of this for nothing -- it renders through the
-- same beginScene / endScene pair, into a slot of its own, and this follows
-- the slot.
--
-- ------- what it does to the art
--
-- Deliberately little. This is a four-colour world drawn on a pixel grid,
-- and the failure mode of every effect here is the same one: a soft
-- gradient laid over hard-edged art, which reads as dirt. So the AO is
-- weak enough to be a shading of the corner rather than a smudge in it,
-- the reflection is gated behind a Fresnel term that keeps a pond seen from
-- above mostly sky (which is what a pond seen from above is), and the
-- shafts are additive light rather than a fog. The whole ladder is one
-- OPTIONS row with OFF on it, and OFF is byte-identical to the mod without
-- this file -- the scene pass does not even allocate the readable depth
-- buffer.

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local ModSetting = V.require("ModSetting")
local Mat4 = V.require("Mat4")
local Water = V.require("Water")
local Sky = V.require("Sky")
local DayNight = V.require("DayNight")

local RayFX = {}

-- The ladder, cheapest-useful first. values[1] is ModSetting's default and
-- its fallback for an unreadable stored value, and it is RT rather than OFF
-- on purpose: this is what the row is for, and a graphics setting whose
-- default is "none of it" is a setting nobody finds. Cycling walks DOWN
-- from there and wraps through MAX, the same shape Quality's own RES row
-- has.
RayFX.setting = ModSetting.new("rayfx", "RTX",
                               { "rt", "ao", "off", "max" },
                               { "RT", "AO", "OFF", "MAX" })

-- ------- the dials
--
-- All four are tuned against the art rather than against physics, and all
-- four are deliberately timid. See the header.

-- How far the AO ring reaches, as a fraction of the canvas height. A
-- fraction rather than a pixel count so it covers the same amount of WORLD
-- at every RES rung and every window size -- a performance row that also
-- restyled the shading would be a bad row.
RayFX.AO_SPAN = 0.020
RayFX.AO_MIN, RayFX.AO_MAX = 3, 14

-- How far away a neighbour can stand and still shade this point, in world
-- pixels. About a cell and a half: the wall you are standing against
-- shades you, the building across the street does not.
RayFX.AO_RANGE = 20

-- And how hard. At 1.6 a right-angle corner lands around 0.78 of its lit
-- value, which is a shading; at 3 it is a stain.
RayFX.AO_POWER = 1.6

-- How much of a mirror the water is at its most reflective (straight-on
-- grazing). Short of 1 because a Gen 1 pond is not a mirror, and because
-- the surface's own art -- the tileset's water tile, which the shader has
-- already sparkled -- is worth keeping visible under the reflection.
RayFX.SSR_AMOUNT = 0.80

-- The shafts' strength at their brightest, and how much more the twilight
-- gets: low sun is when a god ray is a real thing you see, so the glow the
-- sky already computes for dawn and dusk drives this too.
RayFX.SHAFT_AMOUNT = 0.16
RayFX.SHAFT_GLOW = 0.22

-- The sun's own colour when the hour has no twilight glow of its own, in
-- 0..1 -- the palest of DayNight's sun ramp, which is what noon is.
RayFX.SHAFT_COLOR = { 0.97, 0.94, 0.78 }

-- ------- which pixels are water, and the two ways that went wrong
--
-- Water is identified GEOMETRICALLY rather than by a flag: it is the only
-- class in the shape profile that stands below zero (see Water.lua), so a
-- reconstructed point below the ceiling below, whose surface faces up, is
-- the water surface. There is no water mask to sample -- the pass runs after
-- the scene and has only the colour and the depth.
--
-- That test was open at BOTH ends, and each was a real bug.
--
-- At the top: the V-CURVE row bends the world down over the horizon by
-- subtracting the square of the distance from the camera's focus (see
-- WorldCurve and the vertex shader). The depth buffer records the BENT
-- world, so `worldAt` hands back a bent point -- and past a certain radius
-- every pixel in the frame stands below the water ceiling. With V-CURVE on,
-- the whole distant world was classified as a pond and reflected. So the
-- curve is undone before the test: the classification asks about the FLAT
-- world, which is the one the shape profile's heights are written in.
--
-- At the bottom: nothing. A point a hundred pixels down was as much "water"
-- as one at -2, so any reconstruction outlier, any geometry a total
-- conversion sinks, and the bent horizon again all qualified. Water lives in
-- a BAND -- recessed to -2, lifted and dropped by the swell -- and the band
-- is what is tested now.
RayFX.WATER_Y = -0.4          -- the ceiling: above this is bank, not water
RayFX.WATER_BASE = -2         -- the class's own recess (TileShape.water)
RayFX.WATER_SLACK = 1.2       -- below the deepest trough, for the floor

-- ------- and the PUDDLES, which are water this pass would never have found
--
-- A puddle is a decal the GROUND row lays on top of the floor (see
-- GroundFX), not a class in the shape profile -- so it stands ABOVE zero and
-- every test above rules it out. It is still water: it is a piece of sky
-- lying on the road, and the one thing a pond does that it did not was
-- reflect.
--
-- For two releases there was nothing to identify it BY except its height:
-- this pass gets the colour buffer and the depth buffer and no third thing,
-- and a mask, a stencil or a water channel each read as a whole extra render
-- target on a build whose argument is that it runs on a phone. The height
-- was tried absolute (worked on Route 1, missed raised town paving), then as
-- a FRACTION (0.7 is a puddle at any height, and no class in the shape
-- profile stands at a fraction). The fraction is what the probe took apart:
-- a character card leans back by the camera's pitch and its height crosses
-- 0.7 a dozen times up the player's own face. See PUDDLE_AMOUNT for the
-- three gates that failed and why a fourth was not attempted.
--
-- What it took was noticing that the third thing was already there. The
-- colour buffer has an ALPHA channel; the void uses it and no drawn pixel
-- does, because the alpha blend saturates every one of them to exactly 1.0.
-- So the ground row stamps its decals into it in a second masked draw, at no
-- extra target and no extra fetch, and a puddle is finally a thing this pass
-- KNOWS rather than infers. The argument in full is over
-- Voxel3D.beginAlphaStamp; what lands here is one comparison.
--
-- The two files hold the same constant and must agree; neither can require
-- the other, so it is written down twice with a note in both -- the same way
-- the decal's float height is written in GroundFX.PUDDLE.
--
-- Voxel3D.PUDDLE_TAG is this same number in the file that writes it, and the
-- probes check that the two agree.
RayFX.PUDDLE_TAG = 254 / 255
-- How far off it a byte may land and still count. TIGHT on purpose, and the
-- number is not a tolerance for noise -- there is none to tolerate. The
-- channel is 8-bit unorm and the value arrives back as exactly 254/255, so
-- the only thing this has to do is stay clear of the neighbouring step:
-- geometry is at 255/255, which is 0.0039 away. Half a step is 0.002, and
-- anything looser would classify the entire world as standing water.
RayFX.PUDDLE_TAG_W = 0.002

-- A puddle is an inch deep and a pond is not, so it takes only a share of
-- the swell's tilt -- enough that the reflection breathes with the rain
-- landing in it, not enough to look like surf in a pothole.
RayFX.PUDDLE_RIPPLE = 0.35

-- ------- and how much of a MIRROR a puddle is, which is where this went
-- wrong and why the row looked like it did nothing
--
-- A pond and a puddle were sharing one Fresnel curve, and they must not.
--
-- The curve is `mix(0.10, 1.0, (1 - cos)^3)` -- almost nothing seen from
-- above, a full mirror seen along the surface -- and for a POND that is
-- right: a pond has a body. There is water under the surface, it has a
-- colour, and looking down into it you see the water rather than the sky. So
-- the reflection is allowed to be a tenth of the pixel at a steep camera.
--
-- A puddle has no body. It is a film over dark paving, and there is nothing
-- underneath it to see: what a wet street shows you IS the reflection, at
-- every angle you can stand at. Running it through the pond's curve gave it
-- the tenth, and then GroundFX composited that tenth under a decal drawn at
-- 90% alpha in a dark sky tint -- so the "reflection" landed at about a
-- twelfth of the final pixel and the feature was, correctly, invisible.
--
-- Worked through at the four camera rungs, the old numbers were:
--
--   15 deg  f*ssr = 0.080      35 deg  0.084
--   50 deg  0.113              75 deg  0.373
--
-- Only the 75-degree rung -- the one nobody plays at -- ever showed it. The
-- floor below is what makes a puddle read as standing water at 15 and 35,
-- which is where the camera actually is. The same four rungs, with it:
--
--   15 deg  0.595            35 deg  0.597
--   50 deg  0.612            75 deg  0.744
--
-- Nearly flat across the ladder, which is the point: the reflection is what
-- the surface IS, so it should not appear as the player tips the camera. It
-- still opens up at 75 because a grazing view of any water reflects more,
-- and the pond's curve is left exactly as it was.
--
-- Not taken to 1. The decal underneath is painted in the sky's own hue at
-- PUDDLE_TONE, and that dark blue showing through the reflection is what
-- says the reflection is IN something -- a pool at a flat 1.0 is a hole in
-- the road with a building in it.
-- ------- AND WHY THEY SPENT A RELEASE AT THE POND'S NUMBERS
--
-- Everything above is a correct description of what a puddle should reflect,
-- and it shipped switched OFF -- both values set to the pond's -- because
-- the pass could not tell a puddle from a person, and these two numbers are
-- what decided whether that mattered.
--
-- The identifier was the FRACTION of the height: a pool floats 0.7 above
-- whatever ground it lies on, and no class in the shape profile stands at a
-- fraction. The probe took it apart. A CHARACTER is a card leaned back by
-- exactly the camera's pitch, so its world height climbs its own face and
-- crosses point-seven a dozen times on the way up; its normal is aimed at
-- the camera, so it passed the faces-up test at every rung. The player,
-- every NPC, every wild and street Pokemon and the carved rim of every hedge
-- were being classified as standing water -- and at the tenth of a pixel the
-- pond's curve gives them, which is where this sat since the row shipped,
-- nobody could see it. Raising a puddle to the strength it should have was
-- therefore not a tuning change, it was what made a latent bug visible: at
-- 0.6 the player mirrored the sky in horizontal stripes.
--
-- Two gates were tried against the probe and both failed. They are kept here
-- because they rule out a whole family of fixes:
--
--   FLATNESS (four depth taps, reject a surface whose neighbours sit off its
--   plane) has no discriminating power at high render resolution -- a screen
--   texel there covers a fraction of a world pixel, so every surface is
--   locally flat. Tightened until it rejected the player, it rejected the
--   puddles too.
--
--   A STRICT NORMAL (N.y > 0.98) is resolution-independent and does reject
--   the cards, but the puddles only pass it at the near-top-down rung: at 35
--   and 75 degrees not one pool qualified. Which also exposed the larger
--   problem -- at those rungs the pools were not passing the FRACTION test
--   either, so the identifier had never worked there at all.
--
-- ------- AND WHAT REPLACED IT: THE MARK
--
-- Not a third guess at geometry. The ground row now STAMPS its puddle decals
-- into the alpha channel of this very buffer, in a second draw of the same
-- meshes with the colour write masked down to alpha alone -- so the question
-- "is this pixel a puddle" is answered by the pixel itself, exactly, at the
-- cost of no fetch at all (`src` is read on the first line of effect for its
-- colour). No render target was added, no attribute, no remesh: the channel
-- was already there and already meaningful, and every ordinary draw
-- SATURATES it to 1.0, so nothing can land on the mark by accident. The full
-- argument is over Voxel3D.beginAlphaStamp.
--
-- Which is why the two numbers below are the ones the table above describes
-- rather than the pond's. The player is not classified as water at any rung,
-- so a puddle may finally reflect like one.
RayFX.PUDDLE_AMOUNT = 0.96
RayFX.PUDDLE_FRESNEL = 0.62

-- Paint the puddle classification instead of reflecting with it: every pixel
-- the pass calls a pool comes out flat magenta. OFF in every build a player
-- runs, and the only thing that turns it on is a probe.
--
-- It exists because the honest test of a mask cannot be a before/after pair.
-- Two shots of a rain shower are two different frames of an animation, so a
-- pixel diff between them is contaminated by every ripple and every falling
-- drop -- the last session lost itself in exactly that. Where the colour
-- LANDS is a single-frame question with a single-frame answer.
RayFX.DEBUG_MASK = false

-- ------- what the rain does to the surface it is landing in
--
-- The old ripple was the SEA's swell, taken at a third. That is the wrong
-- shape twice over and it is the whole of "it does not react".
--
-- Wrong in SCALE: the swell's two trains have wavelengths around eighty
-- world pixels, which is five cells. A puddle is one or two cells across, so
-- the whole pool sat inside a fraction of one wave and tilted as a single
-- plane -- the reflection slid about as a slab instead of breaking up.
--
-- Wrong in CAUSE: `Water.swell()` is the WATER row, and the row's first rung
-- is FLAT. A player who does not want the sea to heave was also switching
-- off every ripple in every puddle in Kanto, in a downpour, which is not
-- what that row promises. And on the maps this matters most on -- a town,
-- which has no water in it at all -- the swell is whatever the row says and
-- has nothing to do with the shower overhead.
--
-- So the puddle gets its own surface, off `Water.rain()` (which is the
-- shower, clamped) rather than off the swell:
--
--   CHOP   two crossing trains at about five world pixels, which is the
--          scale of the scatter rain leaves on standing water. This is what
--          turns a mirror into a wet mirror.
--   RINGS  one impact per cell on its own clock, expanding and dying -- the
--          thing you actually watch a puddle for. Radially symmetric, so the
--          slope points out of the impact, which is what makes a ring read
--          as a ring rather than as a bright circle.
--
-- Both die to nothing as the shower does, so the pool goes glassy still in
-- the ten minutes of aftermath GroundFX keeps it around for -- and a still
-- puddle reflecting a sharp roofline is the shot this whole row is for.
-- Both AMPLITUDES are wave HEIGHTS in world pixels, not slopes -- the shader
-- multiplies each by its own frequency to get the slope, because that is
-- what the derivative of a sine is. Worth writing down because the numbers
-- look far too small otherwise: a puddle's ripple is a fraction of one world
-- pixel deep, and the slope is what you see.
--
--   chop  0.09 x 1.25, twice over  ->  about a tenth, near 10 degrees of
--         tilt. A shimmer. Taken to the four tenths it started at, the
--         normal swung nearly forty degrees and the reflection came apart
--         into noise -- which is a puddle in a hurricane, not in rain.
--   ring  0.55 x 0.62  ->  about a third, near 19 degrees at the crest. A
--         ring is a SHAPE and is meant to be seen; the chop is a texture and
--         is not.
--
-- The REACH is under a cell on purpose. Each cell computes only its OWN
-- impact -- one hash and one sine per pixel, which is what keeps this
-- affordable on a phone -- so a ring that travelled further than its cell
-- would be clipped square at the cell boundary. Six and a half pixels from a
-- centre kept to the middle of the cell stays inside it, and at four rings
-- across a full-size pool that is the right scale anyway.
RayFX.RAIN_CHOP = 0.09        -- the scatter's wave height, world pixels
RayFX.RAIN_CHOP_FREQ = 1.25   -- radians per world pixel: ~5px between crests
RayFX.RAIN_RING = 0.55        -- an impact ring's own height
RayFX.RAIN_RING_FREQ = 0.62   -- and its wavelength, ~10px: one crest per ring
RayFX.RAIN_RING_REACH = 6.5   -- world pixels a ring travels before it dies
RayFX.RAIN_RATE = 1.9         -- impacts per cell per second at full power

local SHADER = [[
  uniform Image depthTex;
  uniform mat4 invVP;       // clip -> world: the camera matrix run backwards
  uniform vec3 eye;
  uniform vec2 texel;       // one canvas pixel, in uv
  uniform float aspect;     // canvas w/h, so a screen radius is round

  // The cleared value. Nothing was drawn there, so it is sky -- which every
  // march below treats as "keep going, there is nothing here to hit".
#define SKY_DEPTH 0.9999

  float depthAt(vec2 uv) {
    return Texel(depthTex, uv).r;
  }

  // The per-pixel random number, as interleaved gradient noise over the
  // PIXEL grid rather than fract(sin(dot(uv,...))*43758).  The sin hash is
  // the usual one and it is broken exactly where this mod ships: at
  // mediump -- the fragment default on GLSL ES -- the 43758 multiply
  // amplifies a 10-bit mantissa's rounding into visible bands, so the AO
  // ring's rotation collapsed back into fixed spokes on the same class of
  // driver the 1.2.1 sky fix was for.  IGN is built from small constants
  // that survive mediump, and its blue-noise-ish spectrum is the better
  // dither anyway.
  float hashAt(vec2 px) {
    px = floor(px);
    return fract(52.9829189 * fract(dot(px, vec2(0.06711056, 0.00583715))));
  }

  // THE ONE PIECE OF MATH THE WHOLE FILE RESTS ON: a canvas pixel and its
  // stored depth, back to the world point that wrote them.
  //
  // uv*2-1 on both axes with no flip, because the camera matrix already
  // carries the clip-space Y flip that puts north at the top of a canvas
  // whose rows run downward (see Voxel3D.viewProjection) -- so a canvas uv
  // and a clip coordinate agree about which way is up, and Voxel3D.project
  // going the other way is this same mapping read forwards.
  vec3 worldAt(vec2 uv, float d) {
    vec4 c = invVP * vec4(uv * 2.0 - 1.0, d * 2.0 - 1.0, 1.0);
    return c.xyz / c.w;
  }

#ifdef RT_AO
  uniform float aoRadius;   // the ring, in canvas pixels
  uniform float aoRange;    // and how far a neighbour still shades, world px
  uniform float aoPower;

  // The surface normal, out of four neighbouring depths rather than out of
  // fwidth().
  //
  // Derivatives would be one instruction and are the usual way to do this.
  // They are also the one part of a shader a driver is allowed to refuse
  // (see VoxelGrid, which carries a whole separate compilation because of
  // it), and they are WRONG at exactly the place this pass is most visible:
  // a silhouette edge, where the two-by-two quad the derivative is taken
  // over straddles a depth cliff and reports a normal belonging to neither
  // surface. Four taps and the NEARER neighbour on each axis costs three
  // more fetches and takes its answer from the surface the pixel actually
  // belongs to.
  //
  // This world is built out of axis-aligned flat faces, so a normal
  // recovered this way is not an approximation of anything -- on the
  // interior of a face it is exact.
  vec3 normalAt(vec2 uv, float d, vec3 P) {
    float dl = depthAt(uv - vec2(texel.x, 0.0));
    float dr = depthAt(uv + vec2(texel.x, 0.0));
    float du = depthAt(uv - vec2(0.0, texel.y));
    float dd = depthAt(uv + vec2(0.0, texel.y));
    vec3 hx = abs(dr - d) < abs(dl - d)
            ? worldAt(uv + vec2(texel.x, 0.0), dr) - P
            : P - worldAt(uv - vec2(texel.x, 0.0), dl);
    vec3 hy = abs(dd - d) < abs(du - d)
            ? worldAt(uv + vec2(0.0, texel.y), dd) - P
            : P - worldAt(uv - vec2(0.0, texel.y), du);
    vec3 n = cross(hx, hy);
    float l = length(n);
    // a face seen exactly edge-on has no area in the quad and no normal to
    // recover; call it flat ground and let the AO come out at nothing
    if (l < 1e-6) return vec3(0.0, 1.0, 0.0);
    n /= l;
    // the cross product's sign follows the winding of the depth quad, which
    // flips across the frame; only one of the two answers faces the camera
    if (dot(n, eye - P) < 0.0) n = -n;
    return n;
  }

  // One direction of the ring, turned by this pixel's own angle and scaled
  // to the ring's radius. Kept as a function rather than a macro because
  // the shading language here is the ES dialect, which does not take a
  // backslash line continuation -- a multi-line macro simply will not
  // compile, and a one-line one is unreadable.
  vec2 aoDir(float kx, float ky, float ca, float sa) {
    return vec2(kx * ca - ky * sa, kx * sa + ky * ca) * aoRadius;
  }

  // And one tap. This is the whole of the technique: a neighbour occludes
  // this point if it stands on the POSITIVE side of the point's own surface
  // plane -- dot(N, toNeighbour) > 0 -- which is to say it is in the way of
  // the hemisphere of sky the point would otherwise see. The bias throws
  // away the neighbours that are merely on the same flat face, where that
  // dot is zero and rounding decides its sign; the falloff lets distance
  // forgive, so a wall two cells off shades much less than the one you are
  // leaning against -- and the hard cutoff at twice the range is what
  // makes "the building across the street does not shade you" true rather
  // than aspirational: the old falloff alone still let a wall three ranges
  // out keep a quarter of its weight, which read as a grey wash between
  // buildings that face each other.
  float aoTap(vec2 uv, vec3 P, vec3 N, vec2 off) {
    vec2 su = uv + off * texel;
    float sd = depthAt(su);
    if (sd >= SKY_DEPTH) return 0.0;
    vec3 v = worldAt(su, sd) - P;
    float len = length(v);
    if (len <= 0.25) return 0.0;
    float fall = max(0.0, 1.0 - len / (aoRange * 2.0));
    return max(0.0, dot(N, v / len) - 0.10) * fall / (1.0 + len / aoRange);
  }

  float ambient(vec2 uv, vec3 P, vec3 N) {
    // A per-pixel turn on the ring. Eight fixed directions sampled the same
    // way at every pixel draw eight fixed spokes around every post in the
    // world; turned by a hash of the pixel's own position they average out
    // into a ring instead. It does not have to be a good random number, it
    // has to be a different one next door -- AND still be one at mediump,
    // which is what hashAt is for (see its note).
    float a = hashAt(uv / texel) * 6.2831853;
    float ca = cos(a), sa = sin(a);
    // two rings: the inner four are the contact shading at the foot of a
    // wall, the outer four the room a corner stands in
    float occ = aoTap(uv, P, N, aoDir( 0.35,  0.00, ca, sa))
              + aoTap(uv, P, N, aoDir(-0.25,  0.25, ca, sa))
              + aoTap(uv, P, N, aoDir( 0.00, -0.35, ca, sa))
              + aoTap(uv, P, N, aoDir( 0.25,  0.25, ca, sa))
              + aoTap(uv, P, N, aoDir( 0.90,  0.20, ca, sa))
              + aoTap(uv, P, N, aoDir(-0.60,  0.70, ca, sa))
              + aoTap(uv, P, N, aoDir(-0.70, -0.60, ca, sa))
              + aoTap(uv, P, N, aoDir( 0.30, -0.90, ca, sa));
    return clamp(1.0 - occ * aoPower * 0.125, 0.0, 1.0);
  }
#endif

#ifdef RT_SSR
  uniform mat4 vp;          // world -> clip, to walk the ray across the frame
  uniform vec3 skyColor;    // what a ray that hits nothing came back with
  uniform float swell;      // the water uniforms, exactly as the scene has them
  uniform vec2 swellA;
  uniform vec2 swellB;
  uniform float swellPhase;
  uniform float ssrAmount;
  uniform float waterY;      // the band's ceiling, in the FLAT world
  uniform float waterLo;     // and its floor
  uniform float puddleTag;      // the mark the GROUND row stamps into alpha
  uniform float puddleTagW;     // and how far off it a byte may land
  uniform float puddleRipple;
  uniform float puddleAmount;   // a film over paving reflects nearly all of it
  uniform float puddleFresnel;  // and never drops below this, at any pitch
  // The probe's eye: paint what the pass CLASSIFIES rather than shade with
  // it. A reflection that lands on the wrong surface is invisible until it
  // is strong enough to be a bug, and the pair of shots that would show it
  // are two different frames of a rain animation -- so the only honest test
  // of a mask is to look at the mask. 0 in every build the player runs.
  uniform float debugMask;
  uniform vec3 curveK;       // xy = the bend's focus in world XZ, z = k
  // The shower, and the clock it rides. `rain` is Water.rain() -- 0 when
  // nothing is falling, which is what makes a drying pool go glassy still.
  uniform float rain;
  uniform float rainPhase;      // seconds, absolute (see Water.phase)
  uniform float rainChop;       // the scatter's slope at full downpour
  uniform float rainChopFreq;   // radians per world pixel
  uniform float rainRing;       // an impact ring's own slope
  uniform float rainRingFreq;
  uniform float rainReach;      // world px a ring travels before it is gone
  uniform float rainRate;       // impacts per cell per second

  // How far the V-CURVE dropped this column. The same expression the vertex
  // shader applies, read here so it can be taken back off: everything the
  // depth buffer holds is bent, and the question "is this the water class"
  // is a question about the world the heights were authored in.
  float curveDrop(vec2 xz) {
    if (curveK.z <= 0.0) return 0.0;
    vec2 cd = xz - curveK.xy;
    return dot(cd, cd) * curveK.z;
  }

  // ------- IS THIS ACTUALLY A PUDDLE
  //
  // There is no test here any more, and that is the fix rather than a
  // deletion. Every version of this question that asked the GEOMETRY failed,
  // and they failed in a way that generalises: what the depth buffer holds
  // is a height field, and a puddle and a leaning character card are not
  // separable in a height field. The fraction of the height crossed 0.7 up
  // the player's own face; flatness had no discriminating power at render
  // resolution; a strict normal rejected the cards and the puddles both. The
  // constants those three needed -- puddleY, puddleWindow, puddleFlat -- and
  // the four depth taps flatHere cost are all gone with them.
  //
  // A puddle now says so itself, in the alpha channel of the colour buffer
  // this pass is already reading. See `pool` in effect below, and the note
  // over Voxel3D.beginAlphaStamp for why that channel is free.

  // How many samples the ray gets, how far off the surface it starts, how
  // far it is allowed to travel and how thick a thing it hits is assumed to
  // be. The reach is generous -- a route is wide -- and costs nothing extra
  // because the spacing is quadratic: the first steps are two world pixels
  // apart, where a reflection's contact point lives, and the last are a
  // hundred, out where the ray is looking at the horizon.
#define SSR_STEPS 20
#define SSR_NEAR 2.0
#define SSR_REACH 900.0
#define SSR_THICK 26.0

  // ------- THE RAIN'S OWN SURFACE, which is what a puddle actually does
  //
  // Returns a SLOPE (dHeight/dxz) rather than a normal, because the caller
  // has two other slopes to add it to and the gradients of summed height
  // fields simply add -- the same arithmetic the curve already rides in on.
  //
  // Two terms, and they answer two different halves of "wet":
  //
  //   the CHOP is the scatter a downpour leaves over standing water --
  //   crests about five world pixels apart, which is under half a cell, so a
  //   pool a cell and a half across holds a dozen of them. It is what breaks
  //   a mirror into a wet mirror, and it is the term doing most of the work
  //   at a glance.
  //
  //   the RINGS are what you look at a puddle FOR. One impact per 16-pixel
  //   cell, on a clock offset by the cell's own hash so no two land together,
  //   expanding from a hashed point inside the cell and dying as it goes. The
  //   slope points radially out of the impact, which is the whole difference
  //   between a ring and a bright disc.
  //
  // Both scale with `rain` and both vanish with it: a pool in the aftermath
  // is a still mirror, which is the shot the GROUND row's long dry-out is
  // there to give.
  vec2 rainSlope(vec2 xz) {
    if (rain <= 0.0) return vec2(0.0);
    float f = rainChopFreq;
    float a = xz.x * f + xz.y * (f * 0.60) + rainPhase * 5.0;
    float b = xz.x * (f * 0.55) - xz.y * f - rainPhase * 4.1;
    float ca = cos(a), cb = cos(b);
    vec2 g = vec2(ca * f + cb * (f * 0.55),
                  ca * (f * 0.60) - cb * f) * (rainChop * rain);

    // The impact point, kept to the middle of its cell: only this cell's own
    // ring is computed, so a drop landing near a border would throw an arc
    // into the next cell that nothing there draws -- a ring cut off square
    // along a grid line, which is the one artefact that would give the whole
    // trick away. Middle half of the cell, with a reach under the margin.
    vec2 cell = floor(xz / 16.0);
    float k = hashAt(cell);
    vec2 c = (cell + vec2(0.30 + k * 0.40,
                          0.30 + hashAt(cell + vec2(37.0, 17.0)) * 0.40))
             * 16.0;
    vec2 d = xz - c;
    float r = length(d);
    // the impact itself has no radius and no slope; everything outside it
    // does, and dividing by r at the centre is the one way this returns NaN
    if (r > 0.001) {
      // one drop per cell per (1/rainRate) seconds, its phase its own
      float life = fract(rainPhase * rainRate + k);
      float R = life * rainReach;
      // a crest at the ring's FRONT, fading behind it, and the whole ring
      // fading as the drop's turn ends -- so a ring is born at the impact,
      // travels out and is gone rather than piling up on the next one
      float env = exp(-abs(r - R) * 0.45) * (1.0 - life);
      g += (d / r) * (-sin((r - R) * rainRingFreq)
                      * rainRingFreq * env * rainRing * rain);
    }
    return g;
  }

  // The swell's own normal, recomputed rather than passed. The height is
  // two sines of world XZ (see Water.lua and the scene's vertex shader), so
  // its gradient is two cosines -- the exact analytic slope of the surface
  // at this point, which is what the crest has to be reflecting off for the
  // reflection to travel with the wave instead of sitting still under it.
  //
  // Recomputing is not a compromise here: it is the SAME function of the
  // same world position with the same uniforms, so it agrees with the
  // geometry to the last bit, and it costs two sines against a whole extra
  // render target's worth of bandwidth to have carried it over.
  //
  // The BEND is folded in with it, and it has to be: the ray marches through
  // the space the depth buffer recorded, which is the bent one, so a pond
  // reflecting off its flat normal while lying on a tilted plane pointed its
  // reflections at the wrong part of the frame. The curve's own height field
  // is -k*|xz - c|², whose gradient is -2k*(xz - c); the two gradients simply
  // add, because the two displacements did.
  // `ripple` scales the swell's share: 1 for the sea, a fraction for a
  // puddle, which is an inch deep and should breathe rather than heave.
  // `rainy` is 1 on a puddle and 0 on a pond: the pond already takes the
  // shower through the swell it is handed (Water.CHOP lifts it), and giving
  // it rings as well would put a downpour's worth of them on the sea.
  vec3 waveNormal(vec2 xz, float ripple, float rainy) {
    vec2 g = vec2(0.0);
    if (swell > 0.0) {
      float a = dot(xz, swellA) - swellPhase;
      float b = dot(xz, swellB) + swellPhase * 0.7;
      g = (swellA * (cos(a) * 0.55) + swellB * (cos(b) * 0.45)) * swell * ripple;
    }
    // Added OUTSIDE the swell's own gate on purpose: the WATER row's first
    // rung is FLAT, and a player who does not want the sea to heave has not
    // asked for the rain to stop falling into the puddles.
    if (rainy > 0.0) g += rainSlope(xz);
    if (curveK.z > 0.0) g -= 2.0 * curveK.z * (xz - curveK.xy);
    if (g == vec2(0.0)) return vec3(0.0, 1.0, 0.0);
    return normalize(vec3(-g.x, 1.0, -g.y));
  }

  // March `R` from `P` and return what it landed on: rgb, and an alpha that
  // is 0 for a miss and eases off at the frame's rim.
  //
  // The walk happens in CLIP space, between the two endpoints projected
  // once. That is exact rather than an approximation: the projection is
  // linear in homogeneous coordinates, so a straight line in the world is a
  // straight line between its two clip points, and interpolating them and
  // dividing by w at each step is the same as projecting each step
  // separately -- for the price of one matrix multiply instead of twenty.
  //
  // The hit test is in WORLD DISTANCE from the eye rather than in stored
  // depth, because stored depth is not linear and a threshold on it means
  // something different at every distance. Distances come out of worldAt,
  // which the pass needs anyway.
  vec4 traceSSR(Image tex, vec3 P, vec3 R) {
    vec3 a = P + R * SSR_NEAR;
    vec3 b = P + R * SSR_REACH;
    vec4 ca = vp * vec4(a, 1.0);
    vec4 cb = vp * vec4(b, 1.0);
    float tPrev = 0.0;
    for (int i = 1; i <= SSR_STEPS; i++) {
      float t = float(i) / float(SSR_STEPS);
      t = t * t;
      vec4 c = mix(ca, cb, t);
      if (c.w <= 0.001) return vec4(0.0);          // gone behind the camera
      vec2 uv = (c.xy / c.w) * 0.5 + 0.5;
      if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
        return vec4(0.0);                          // and off the frame
      }
      float sd = depthAt(uv);
      if (sd < SKY_DEPTH) {
        float dRay = distance(eye, mix(a, b, t));
        float dHit = distance(eye, worldAt(uv, sd));
        // behind the recorded surface, but not so far behind that the ray
        // has passed clean through and out the other side of it
        if (dRay > dHit && dRay < dHit + SSR_THICK) {
          // The march's quadratic spacing is what buys its reach, and it is
          // also a staircase: out where steps are fifty pixels apart, every
          // reflected edge landed on whichever step overshot it, so a
          // reflected tree came back as a column of slabs.  Four bisections
          // between the last miss and this hit walk the overshoot back in --
          // sixteen times the precision for four extra fetches, and only on
          // the pixels that actually hit something.
          float lo = tPrev;
          float hi = t;
          for (int j = 0; j < 4; j++) {
            float tm = 0.5 * (lo + hi);
            vec4 cm = mix(ca, cb, tm);
            vec2 um = clamp((cm.xy / cm.w) * 0.5 + 0.5, 0.0, 1.0);
            float sm = depthAt(um);
            if (sm < SKY_DEPTH
                && distance(eye, mix(a, b, tm)) > distance(eye, worldAt(um, sm))) {
              hi = tm;
            } else {
              lo = tm;
            }
          }
          vec4 ch = mix(ca, cb, hi);
          vec2 uh = clamp((ch.xy / ch.w) * 0.5 + 0.5, 0.0, 1.0);
          vec2 e = min(uh, 1.0 - uh);
          return vec4(Texel(tex, uh).rgb,
                      smoothstep(0.0, 0.10, min(e.x, e.y)));
        }
      }
      tPrev = t;
    }
    return vec4(0.0);
  }
#endif

#ifdef RT_SHAFTS
  uniform vec2 sunUV;
  uniform vec3 shaftColor;
  uniform float shaftAmount;   // 0 = no body worth marching toward

#define SHAFT_STEPS 14
#define SHAFT_DENSITY 0.85
#define SHAFT_DECAY 0.93
#define SHAFT_RANGE 0.85

  // What the march reads at a point that may be past the frame's edge.  A
  // depth texture clamps, so the old read repeated the edge texel out to
  // infinity: a building against the frame's rim threw its blockage across
  // every beam that marched past it, and a sun just off the top -- exactly
  // when the shafts reach furthest, which is why the disc is allowed off
  // frame at all -- was shaded by whatever happened to sit on the top row.
  // Off the frame there is nothing recorded, and toward the sun the honest
  // guess for nothing is open sky.
  float shaftDepth(vec2 p) {
    if (p.x < 0.0 || p.x > 1.0 || p.y < 0.0 || p.y > 1.0) return 1.0;
    return depthAt(p);
  }

  // Every pixel walks toward the sun and counts how much of the walk was
  // open sky. Weighted so the samples nearest the pixel count most, which
  // is what keeps a beam attached to the edge that casts it instead of
  // smearing the whole frame toward the disc.  The march starts a random
  // fraction of one step in (hashAt): fourteen fixed steps land every
  // pixel's samples on the same fourteen rings, which read as bands around
  // the disc; jittered per pixel the same average light lands with the
  // banding traded for noise the pixel grid absorbs.
  vec3 shaftsAt(vec2 uv) {
    if (shaftAmount <= 0.0) return vec3(0.0);
    vec2 d = (sunUV - uv) * (SHAFT_DENSITY / float(SHAFT_STEPS));
    vec2 p = uv + d * hashAt(uv / texel);
    float w = 1.0, acc = 0.0, tot = 0.0;
    for (int i = 0; i < SHAFT_STEPS; i++) {
      p += d;
      acc += step(SKY_DEPTH, shaftDepth(p)) * w;
      tot += w;
      w *= SHAFT_DECAY;
    }
    // and it dies with distance from the disc, on a circle rather than an
    // ellipse -- the aspect correction is why the shafts do not go oval in
    // a wide window
    vec2 r = (uv - sunUV) * vec2(aspect, 1.0);
    float fall = 1.0 - smoothstep(0.0, SHAFT_RANGE, length(r));
    return shaftColor * (acc / max(tot, 0.001)) * fall * shaftAmount;
  }
#endif

  vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
    vec4 src = Texel(tex, tc);
    float d = depthAt(tc);
    vec3 rgb = src.rgb;
    if (d < SKY_DEPTH) {
      vec3 P = worldAt(tc, d);
#ifdef RT_AO
      vec3 N = normalAt(tc, d, P);
      rgb *= ambient(tc, P, N);
#endif
#ifdef RT_SSR
      // Water, identified geometrically and not by a flag: it is the only
      // class that stands in a band below zero, and its surface faces up.
      //
      // The BAND, and the FLAT world, are both load-bearing -- see the note
      // over WATER_Y. Below the ceiling alone, in the world as drawn, meant
      // "every pixel the V-CURVE has bent far enough down", which is most of
      // a route past the middle distance; the whole horizon reflected.
      //
      // `N.y > 0.6` is the other half and always was: it keeps the shoreline
      // LIP out, whose side faces run from -2 up to the bank and would
      // otherwise read as a strip of water standing on end.
      float flatY = P.y + curveDrop(P.xz);
      // THE POND is still geometry, and for it that is sound: the sea is the
      // only thing in this world standing in a band below zero, and it is
      // built rather than stamped.
      bool pond = flatY < waterY && flatY > waterLo;
      // THE PUDDLE is a mark. `src` was fetched on the first line of this
      // function for its colour, so this costs no tap, no neighbour and no
      // arithmetic on the height: the ground row stamped the tag into this
      // pixel's alpha when it drew the decal, and every other drawn pixel in
      // the frame is at exactly 1.0 because the alpha blend saturates it
      // there. Which is why this can be an equality rather than a threshold.
      bool pool = abs(src.a - puddleTag) < puddleTagW;
      // The probe's eye. Painted BEFORE the reflection so it shows the
      // classification and not the effect -- a mask that lands on the player
      // is the bug this row spent a release on, and a magenta player is a
      // thing a screenshot can settle in one frame.
      if (debugMask > 0.5 && pool) return vec4(1.0, 0.0, 1.0, src.a);
      // How far up a surface has to face to be water at all -- THE POND'S
      // TEST, and it always was. It is there to keep the shoreline LIP out,
      // whose side faces run from -2 up to the bank and would otherwise read
      // as a strip of water standing on end.
      //
      // The puddles are out from under it, and that fixes a second bug on
      // the way past: a pool's outermost ring is a decal one world pixel
      // across, so the four-tap normal there straddles the step down to the
      // road and reported a near-vertical face. That ring is the one the art
      // draws BRIGHT, so a pool came out as a dry lit outline around a
      // reflecting middle. A marked pixel is a puddle whatever a normal
      // reconstructed across its rim has to say about it.
      if (pool || (pond && N.y > 0.6)) {
        vec3 Wn = waveNormal(P.xz, pool ? puddleRipple : 1.0,
                             pool ? 1.0 : 0.0);
        vec3 Vd = normalize(P - eye);
        vec3 R = reflect(Vd, Wn);
        // a crest steep enough to turn the ray back down into the water it
        // came off has nothing to reflect; flatten it rather than march
        if (R.y < 0.02) R.y = 0.02;
        R = normalize(R);
        vec4 hit = traceSSR(tex, P, R);
        vec3 refl = mix(skyColor, hit.rgb, hit.a);
        // Fresnel: a pond seen from straight above is mostly its own water
        // and a pond seen along the surface is mostly a mirror, which is
        // also exactly how the camera ladder moves -- 15 degrees barely
        // reflects and 75 reflects the whole far bank.
        //
        // A PUDDLE gets its own floor and its own amount, and that split is
        // the fix rather than a tuning of it -- see PUDDLE_AMOUNT. A pond has
        // a body to look into and a film over paving has none, so the curve
        // that is honest for one is what made the other invisible at every
        // camera rung anybody plays at.
        float fMin = pool ? puddleFresnel : 0.10;
        float amt = pool ? puddleAmount : ssrAmount;
        float f = mix(fMin, 1.0,
                      pow(1.0 - clamp(dot(Wn, -Vd), 0.0, 1.0), 3.0));
        rgb = mix(rgb, refl, clamp(f * amt, 0.0, 1.0));
      }
#endif
    }
#ifdef RT_SHAFTS
    // times the source alpha, so a rung whose void is transparent does not
    // get light painted onto the letterbox behind the diorama
    rgb += shaftsAt(tc) * src.a;
#endif
    return vec4(rgb, src.a) * color;
  }
]]

-- Compilations of SHADER, keyed by the rung they were built for. Each entry
-- is nil = untried, false = would not build. A rung that will not compile
-- costs that rung and nothing else -- apply() hands the scene back
-- untouched, which is the same thing OFF does.
local shaders = {}

-- The canvas each SLOT writes into, sized to that slot's render resolution.
-- Two callers, two slots (free roam and the battle arena), each stable for
-- a session -- the same arrangement, and for the same reason, as Voxel3D's
-- own scene slots.
local outs = {}

function RayFX.level()
  local ok, v = pcall(RayFX.setting.get, RayFX.setting)
  if ok and (v == "off" or v == "ao" or v == "rt" or v == "max") then
    return v
  end
  return "rt"
end

-- Whether the scene pass should keep a READABLE depth buffer this frame.
--
-- Consulted by Voxel3D.beginScene before it binds its canvas, and it is the
-- whole of what OFF costs: with nothing here to read the depth, the pass
-- attaches the plain write-only buffer it always attached and no second
-- texture is ever allocated.
function RayFX.wanted()
  return RayFX.level() ~= "off"
end

function RayFX.row()
  return RayFX.setting:row()
end

local function getShader(level)
  if shaders[level] == nil then
    local src = "#define RT_AO 1\n"
    if level == "rt" or level == "max" then
      src = src .. "#define RT_SSR 1\n"
    end
    if level == "max" then src = src .. "#define RT_SHAFTS 1\n" end
    local ok, sh = pcall(love.graphics.newShader, src .. SHADER)
    shaders[level] = (ok and sh) or false
    -- kept for the same reason Voxel3D keeps its own: a rung that will not
    -- build is meant to fall back quietly, and quietly is also how a typo
    -- in a define-gated branch survives a release. The driver's log is the
    -- only thing that says why.
    if not ok then RayFX.shaderError = tostring(sh) end
  end
  return shaders[level] or nil
end

-- Build one rung's shader and say whether it took. Named for the suite:
-- every rung here is a separate compilation behind a define, so "does this
-- build on this driver" is three questions rather than one, and the answer
-- to each is otherwise only visible as an effect quietly not happening.
function RayFX.compile(level)
  return getShader(level) ~= nil
end

local function outCanvas(name, w, h)
  local held = outs[name]
  if held and held.w == w and held.h == h then return held.canvas end
  local ok, c = pcall(love.graphics.newCanvas, w, h)
  if not (ok and c) then return nil end
  -- nearest, like every other canvas in this mode: what comes out of here
  -- is either blitted 1:1 or scaled up by the present pass, and this world
  -- is pixel art on a fixed grid
  c:setFilter("nearest", "nearest")
  if held and held.canvas and held.canvas.release then
    pcall(held.canvas.release, held.canvas)
  end
  outs[name] = { canvas = c, w = w, h = h }
  return c
end

-- What the shafts are lit by this hour: how strong, and in what colour.
-- Zero for the moon (a moonbeam is not a thing this world has) and zero
-- when the disc is not in frame at all -- a march toward something behind
-- the camera would drag light the wrong way across the whole picture.
local function shaftLight(body, w, h)
  if not (body and not body.moon) then return 0, RayFX.SHAFT_COLOR end
  local u, v = body.x / math.max(1, w), body.y / math.max(1, h)
  -- a little past the edge still counts: a sun just off the top of the
  -- frame is exactly when the beams reach furthest down it
  if u < -0.35 or u > 1.35 or v < -0.35 or v > 1.35 then
    return 0, RayFX.SHAFT_COLOR
  end
  local amt, glow = DayNight.glow()
  amt = amt or 0
  local color = RayFX.SHAFT_COLOR
  if glow then
    color = { glow[1] / 255, glow[2] / 255, glow[3] / 255 }
  end
  return RayFX.SHAFT_AMOUNT + RayFX.SHAFT_GLOW * amt, color
end

-- Run the pass over `o.canvas` and hand back the processed canvas, or nil
-- to say "nothing happened here" -- which every caller treats as "keep what
-- you had". nil is the answer for OFF, for a shader that would not build,
-- for a driver with no readable depth, and for a camera matrix with no
-- inverse; in none of those cases is losing the frame better than losing
-- the effect.
--
-- `o` is { canvas, depth, vp, eye, slot, w, h, sky, body }:
--   canvas  the finished scene, at render resolution
--   depth   its depth buffer, as a readable texture
--   vp/eye  the camera it was drawn with
--   slot    which cached output canvas to use
--   w/h     the render resolution, which is canvas's own size
--   sky     the {r,g,b,a} the void was cleared to, or nil indoors
--   body    Voxel3D.skyBody's answer for this camera, or nil
--   curve   { focusX, focusZ, k } -- the V-CURVE bend this frame was drawn
--           with, so the water test can be asked of the FLAT world
function RayFX.apply(o)
  local level = RayFX.level()
  if level == "off" then return nil end
  if not (o and o.canvas and o.depth and o.vp and o.w and o.h) then
    return nil
  end
  local sh = getShader(level)
  if not sh then return nil end
  local inv = Mat4.invert(o.vp)
  if not inv then return nil end
  local out = outCanvas((o.slot or "world") .. "#rt", o.w, o.h)
  if not out then return nil end

  local send = function(name, ...) pcall(sh.send, sh, name, ...) end
  send("depthTex", o.depth)
  send("invVP", "row", inv)
  send("eye", o.eye or { 0, 0, 0 })
  send("texel", { 1 / o.w, 1 / o.h })
  send("aspect", o.w / math.max(1, o.h))

  -- AO runs at every rung above OFF
  local radius = math.max(RayFX.AO_MIN,
                          math.min(RayFX.AO_MAX, o.h * RayFX.AO_SPAN))
  send("aoRadius", radius)
  send("aoRange", RayFX.AO_RANGE)
  send("aoPower", RayFX.AO_POWER)

  if level == "rt" or level == "max" then
    send("vp", "row", o.vp)
    -- what a reflected ray that hit nothing came back with. The sky the
    -- void was cleared to is the right answer where there is one; indoors
    -- there is no sky and the haze stands in, and with neither the water
    -- simply reflects nothing and shows its own surface.
    local sky = o.sky or Sky.haze()
    send("skyColor", { sky and sky[1] or 0.5,
                       sky and sky[2] or 0.6,
                       sky and sky[3] or 0.7 })
    send("swell", Water.swell())
    send("swellA", Water.WAVE_A)
    send("swellB", Water.WAVE_B)
    send("swellPhase", Water.phase())
    send("ssrAmount", RayFX.SSR_AMOUNT)
    send("waterY", RayFX.WATER_Y)
    -- the floor of the band: the class's own recess, the deepest the swell
    -- can pull a trough below it, and a little slack for the reconstruction
    send("waterLo", RayFX.WATER_BASE - (Water.swell() or 0)
                    - RayFX.WATER_SLACK)
    -- and the puddles, which are the GROUND row's decals rather than a class
    -- in the shape profile: recognised by the mark that row stamps into this
    -- buffer's alpha, because a decal has no geometry this pass could tell
    -- from a person's (see PUDDLE_TAG)
    send("puddleTag", RayFX.PUDDLE_TAG)
    send("puddleTagW", RayFX.PUDDLE_TAG_W)
    send("puddleRipple", RayFX.PUDDLE_RIPPLE)
    send("puddleAmount", RayFX.PUDDLE_AMOUNT)
    send("puddleFresnel", RayFX.PUDDLE_FRESNEL)
    send("debugMask", RayFX.DEBUG_MASK and 1 or 0)
    -- the shower itself, which is what a puddle's surface is made of. Read
    -- off Water rather than off Weather so this file gains no dependency it
    -- did not already have: Weather writes that number every tick precisely
    -- so the things downstream of it do not have to require it back.
    send("rain", Water.rain())
    -- Absolute time, like the swell's own phase and for the same reason: two
    -- callers read this pass per frame (free roam and a staged battle) and an
    -- accumulator advanced per read would run at twice the rate in a fight.
    --
    -- FOLDED at a thousand seconds, which `Water.phase` also does and for the
    -- same reason: a session's uptime handed to a fragment shader is a number
    -- in the tens of thousands, and `fract` of one of those has lost the part
    -- the ring's clock is made of. A thousand rather than a round power of
    -- two because the rings' rate divides it exactly (1000 * 1.9 = 1900), so
    -- the fold lands on a whole drop cycle and the rings do not skip through
    -- it. The chop's own two rates do not divide it and step a fraction of a
    -- crest once every seventeen minutes, which is a sixteenth of a pixel of
    -- ripple in a downpour and has never been the thing anybody sees.
    send("rainPhase", (love.timer and love.timer.getTime
                       and love.timer.getTime() or 0) % 1000)
    send("rainChop", RayFX.RAIN_CHOP)
    send("rainChopFreq", RayFX.RAIN_CHOP_FREQ)
    send("rainRing", RayFX.RAIN_RING)
    send("rainRingFreq", RayFX.RAIN_RING_FREQ)
    send("rainReach", RayFX.RAIN_RING_REACH)
    send("rainRate", RayFX.RAIN_RATE)
    -- and the bend, so the classification and the surface normal can both
    -- ask about the world the heights were authored in. Handed over by the
    -- caller rather than read from Voxel3D: this file is loaded BY that one,
    -- and requiring it back would be a cycle.
    local c = o.curve
    send("curveK", { c and c[1] or 0, c and c[2] or 0, c and c[3] or 0 })
  end

  if level == "max" then
    local amount, color = shaftLight(o.body, o.w, o.h)
    send("sunUV", { (o.body and o.body.x or 0) / math.max(1, o.w),
                    (o.body and o.body.y or 0) / math.max(1, o.h) })
    send("shaftColor", color)
    send("shaftAmount", amount)
  end

  local prevBlend, prevAlpha = love.graphics.getBlendMode()
  local ok = pcall(function()
    love.graphics.setCanvas(out)
    love.graphics.setShader(sh)
    love.graphics.setColor(1, 1, 1, 1)
    -- replace, not alpha blend: this is an image-processing copy and the
    -- scene's own alpha is meaningful -- the void is transparent at every
    -- rung below the one that paints a sky
    love.graphics.setBlendMode("replace", "premultiplied")
    love.graphics.draw(o.canvas)
  end)
  love.graphics.setCanvas()
  love.graphics.setShader()
  love.graphics.setBlendMode(prevBlend or "alpha", prevAlpha)
  if not ok then return nil end
  return out
end

-- Drop the GPU objects (window resize, hot reload). The shaders survive: a
-- compilation is not tied to a canvas size, and rebuilding one costs a
-- stall the resize does not need.
function RayFX.invalidate()
  for name, held in pairs(outs) do
    if held.canvas and held.canvas.release then
      pcall(held.canvas.release, held.canvas)
    end
    outs[name] = nil
  end
end

return RayFX
