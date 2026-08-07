-- The B rungs: the two discs the fight is staged on.
--
-- Where an A rung puts the fight on the MAP -- real ground, whatever the
-- route happens to look like -- a B rung puts it on two platforms against
-- the sky and draws no map at all.
--
-- ------- one stage, two rungs
--
-- The discs do not know what is standing on them. 2D-3D B stands the Game
-- Boy's own battle pics there and STADIUM B stands the Pokemon Stadium
-- models, and this file is identical for both: it draws two platforms at two
-- cells and sizes each to whatever footprint it is given. That is why the
-- flat disc rung cost a value in the 3D-BTL ladder and nothing else.
--
-- ------- why this is a rung and not a fix
--
-- Staging on the map is the better picture when the map cooperates, and it
-- often does not. Half of Kanto's interiors are furniture; a cave floor can
-- be nothing but two-cell corridors; some maps have nowhere a fight can be
-- SEEN from a low camera and are declined outright (see BattleArena), which
-- drops the player back to the flat battle screen with no warning. And even
-- where a spot exists, the ground behind the foe is a hedge or a shop counter
-- rather than anything a battle wants behind it.
--
-- Discs have none of those problems, because the stage is CARRIED rather than
-- found: it works on every map, in every building, at every step, and the
-- framing is the same every time. What it gives up is the thing STADIUM A is
-- for -- fighting somewhere real.
--
-- ------- what stays
--
-- The sky, and the light. A battle outdoors is under the hour's own sky, with
-- its bands and its sun or moon (Voxel3D.beginScene paints it when handed a
-- dressed one); a battle in a cave or a room is under that place's own void
-- and its own neutral light, exactly as the map itself would be. So the mode
-- is abstracted from the GROUND, not from the world -- walk into a cave at
-- midnight and the fight looks like a cave at midnight.
--
-- And the framing. The camera, the pins, the HUDs, the text box, the move
-- animations and the depth of field are all identical, because every one of
-- them is hung off the arena's CELLS rather than off what is under them. That
-- is the same reason STADIUM A could be an option on the mode rather than a
-- second mode, and it is why this file is a few hundred lines and not a few
-- thousand.

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local Mat4 = V.require("Mat4")
local Voxel3D = V.require("Voxel3D")

local StadiumStage = {}

local floor = math.floor
local sin, cos = math.sin, math.cos
local pi = math.pi

-- ------- the shape of a disc
--
-- Radius in world pixels, where a map cell is 16 and the two mons stand three
-- cells apart.
--
-- A PLATFORM FOLLOWS WHAT STANDS ON IT rather than being one fixed size,
-- because the set's footprints run nearly tenfold: a Caterpie is under four
-- world pixels across and Moltres, wings out, is twenty-six. One radius for
-- both is either a dinner plate under the caterpillar or a doily under the
-- bird.
--
-- RADIUS is the floor, and it is the number most species land on -- it is a
-- little over the map cell a Pokemon is sized to cover, which is the
-- proportion the Game Boy's own battle platforms have. PAD is the margin
-- around a mon that needs more than that, and MAX_RADIUS stops Moltres from
-- being handed something the frame cannot hold.
--
-- These are the FULL radius, out to where the fade has finished; the solid
-- centre a Pokemon actually stands on is SOLID of it. PAD is sized so that a
-- mon's own footprint fits inside that centre rather than out over the
-- stipple -- 1.8 x 0.70 is a little over 1.25, so a big Pokemon still has
-- solid ground under its edges.
StadiumStage.RADIUS = 18 * 1.3
StadiumStage.MAX_RADIUS = 34 * 1.3
StadiumStage.PAD = 1.8 * 1.3

-- The platform for a mon of this footprint. `r` may be nil -- nothing is
-- standing there yet, which is every frame of the send-out before the model
-- appears, and it is also the whole of the flat 2D-3D B rung, where a
-- Pokemon is a battle pic sized to cover exactly one map cell and RADIUS is
-- already a little over that. Either way the platform is the plain one, and
-- it has to be there BEFORE the Pokemon lands on it.
function StadiumStage.radiusFor(r)
  local want = (r or 0) * StadiumStage.PAD
  if want < StadiumStage.RADIUS then return StadiumStage.RADIUS end
  if want > StadiumStage.MAX_RADIUS then return StadiumStage.MAX_RADIUS end
  return want
end

-- Per-vertex shading, in the same terms StadiumRig lights the models with, so
-- a disc and the Pokemon standing on it agree about where the sun is. Fitted
-- to Voxel3D.FACE_SHADE's six values: the constant is the average, and each
-- axis term is half the spread between that axis's two faces.
local SHADE_BASE = 0.7725
local SHADE_X = 0.06
local SHADE_Y = 0.225
local SHADE_Z = 0.11

local function shadeFor(nx, ny, nz)
  local s = SHADE_BASE + nx * SHADE_X + ny * SHADE_Y + nz * SHADE_Z
  if s < 0.30 then return 0.30 end
  if s > 1.00 then return 1.00 end
  return s
end

-- ------- the texture
--
-- The platform is a FLAT painted disc that fades out at its rim -- no rim
-- wall, no thickness, the whole thing carried in one texture on one quad
-- lying on the ground plane. That is what the Game Boy's own battle
-- platforms are, and it is what keeps the stage from competing with the
-- Pokemon standing on it.
--
-- ------- why the fade is DITHERED
--
-- The scene shader discards any texel under half alpha outright (it has to:
-- that is what keeps a sprite's transparent corners out of the depth buffer).
-- So a smooth alpha ramp does not fade -- it comes out as a hard circle cut
-- at wherever the ramp crosses 0.5, which is the one thing this must not be.
--
-- The fade is therefore an ORDERED DITHER baked into the texture's alpha:
-- every texel is fully on or fully off, and the proportion that are on falls
-- away toward the rim. It is the same trick the sky already uses for its
-- bands (Sky.DITHER), it needs no shader change and so risks nothing in any
-- other pass, and on a mode built out of visible texels it reads as intended
-- rather than as a limitation.
--
-- The COLOUR is deliberately neutral. Everything the shader does to it after
-- this is the environment's: Voxel3D.tint carries the hour outdoors and the
-- room's own flat light indoors, and the shadow pass darkens whatever the
-- Pokemon standing on it occludes. So one texture is a sunlit platform, a
-- dusk platform and a cave platform, without a variant for each.
-- stahl's note to self: put a branch here to select different stage based on environment 
StadiumStage.TEX = 128

-- Where the solid centre ends, as a fraction of the disc's radius. Inside
-- this everything is opaque; from here to the rim the dither thins out.
StadiumStage.SOLID = 0.76

local TOP = { 0.74, 0.71, 0.63 }
local TOP_ALT = { 0.67, 0.64, 0.57 }

local texture = nil

-- A small deterministic scatter, for the surface itself. Not a random one: an
-- authored constant that happens to look unpatterned is worth more here than
-- a seed, because it can never change under a different Lua.
--
-- Quantised into blocks, so the surface reads as TEXELS rather than as noise.
-- Per-pixel it came out as a fine mottle that fought the dithered rim for
-- attention -- and the rim is the thing worth looking at. At this size the
-- grain is roughly the size of the voxels everywhere else in the mode.
StadiumStage.GRAIN = 4

local function grain(x, y)
  local bx = (x - x % StadiumStage.GRAIN) / StadiumStage.GRAIN
  local by = (y - y % StadiumStage.GRAIN) / StadiumStage.GRAIN
  local v = (bx * 37 + by * 71 + ((bx * by) % 13) * 17) % 100
  return v < 34
end

-- The 8x8 ordered (Bayer) matrix, as thresholds in 0..63. Ordered rather than
-- random because a random dither crawls: this pattern is fixed in the
-- texture, so the fade holds still while the camera drifts across it.
local BAYER = {
  { 0, 32,  8, 40,  2, 34, 10, 42 },
  { 48, 16, 56, 24, 50, 18, 58, 26 },
  { 12, 44,  4, 36, 14, 46,  6, 38 },
  { 60, 28, 52, 20, 62, 30, 54, 22 },
  {  3, 35, 11, 43,  1, 33,  9, 41 },
  { 51, 19, 59, 27, 49, 17, 57, 25 },
  { 15, 47,  7, 39, 13, 45,  5, 37 },
  { 63, 31, 55, 23, 61, 29, 53, 21 },
}

function StadiumStage.texture()
  if texture ~= nil then return texture or nil end
  local ok, img = pcall(function()
    local n = StadiumStage.TEX
    local data = love.image.newImageData(n, n)
    local half = (n - 1) / 2
    local solid = StadiumStage.SOLID
    for y = 0, n - 1 do
      local dy = (y - half) / half
      for x = 0, n - 1 do
        local dx = (x - half) / half
        local d = (dx * dx + dy * dy) ^ 0.5
        -- how much of this texel's neighbourhood should survive: everything
        -- inside the solid core, nothing past the rim, and a smooth ramp
        -- between the two that the dither turns into a stipple
        local cover
        if d <= solid then
          cover = 1.0
        elseif d >= 1.0 then
          cover = 0.0
        else
          local t = (d - solid) / (1.0 - solid)
          cover = 1.0 - t * t * (3 - 2 * t)     -- smoothstep, falling
        end
        local threshold = (BAYER[y % 8 + 1][x % 8 + 1] + 0.5) / 64
        local a = (cover > threshold) and 1 or 0
        local c = grain(x, y) and TOP_ALT or TOP
        data:setPixel(x, y, c[1], c[2], c[3], a)
      end
    end
    local image = love.graphics.newImage(data)
    -- nearest, like every other texture in this mode: the grain and the
    -- stipple are both meant to read as texels. Clamped rather than
    -- repeating now that one texture covers the whole disc.
    image:setFilter("nearest", "nearest")
    image:setWrap("clampzero", "clampzero")
    return image
  end)
  texture = (ok and img) or false
  return texture or nil
end

-- ------- the mesh
--
-- One quad, lying flat on the ground plane, spanning -1..1 in x and z with
-- the whole texture stretched across it. The DISC is the texture's business,
-- not the geometry's -- everything outside the painted circle is alpha the
-- shader discards -- which is what "a flat texture that fades out at the
-- edges" means and what makes this four vertices rather than a hundred and
-- fifty.
--
-- Shaded as a face pointing straight up, because it is one.

local mesh = nil

local function build()
  local s = shadeFor(0, 1, 0)
  local verts = {
    { -1, 0, -1, 0, 0, s },
    {  1, 0, -1, 1, 0, s },
    {  1, 0,  1, 1, 1, s },
    { -1, 0,  1, 0, 1, s },
  }
  return Voxel3D.newMesh(verts, { 1, 2, 3, 1, 3, 4 })
end

function StadiumStage.mesh()
  if mesh == nil then mesh = build() or false end
  return mesh or nil
end

function StadiumStage.invalidate()
  if texture and texture.release then pcall(texture.release, texture) end
  if mesh and mesh.release then pcall(mesh.release, mesh) end
  texture, mesh = nil, nil
end

-- How far under the ground plane the disc actually sits. A hair, and only so
-- that a flat-footed Pokemon's sole -- which is AT the ground plane -- is not
-- coplanar with it and left to the depth buffer's mercy.
StadiumStage.SINK = 0.06

-- Where one disc sits: centred on a cell, at the ground plane, so a Pokemon
-- placed at that same height stands ON it rather than in it.
function StadiumStage.matrix(x, groundY, z, radius)
  radius = radius or StadiumStage.RADIUS
  return Mat4.mul(Mat4.translate(x, groundY - StadiumStage.SINK, z),
                  Mat4.scale(radius, 1, radius))
end

-- The two platforms this frame, as (side, matrix) -- shared by the camera's
-- pass and the sun's, so the two can never disagree about where they are.
local function each(arena, groundY, fn)
  local ok, Stadium = pcall(V.require, "Stadium")
  for _, side in ipairs({ "enemy", "player" }) do
    local cell = arena[side]
    if cell then
      local footprint = ok and Stadium and Stadium.footprint(side) or nil
      fn(StadiumStage.matrix(cell[1], groundY, cell[2],
                             StadiumStage.radiusFor(footprint)))
    end
  end
end

-- ------- the synthetic arena
--
-- A B rung does not search the map, because it does not stand on it. The
-- arena is the same WIDE shape every other staged fight uses -- so the two
-- cells are three apart down the middle and BattleCam frames them exactly as
-- it always has -- just placed at a fixed spot rather than a found one.
--
-- Away from the origin on purpose. The coordinates run through the camera
-- solve, the sun's frustum fit and the projection to Game Boy pixels, and
-- putting a stage at (0, 0) is the kind of thing that hides a sign error for
-- months.
StadiumStage.ORIGIN = { 16, 16 }

function StadiumStage.arena(map)
  local BattleArena = V.require("BattleArena")
  local arena = BattleArena.at(StadiumStage.ORIGIN[1], StadiumStage.ORIGIN[2],
                               "wide")
  if not arena then return nil end
  -- the map is carried for its SKY and its palette only -- what kind of place
  -- the fight is happening in -- never for its geometry
  arena.map = map
  arena.discs = true
  return arena
end

-- ------- the draws

-- The discs, in the main pass. No wireframe: everything else in this frame is
-- built a unit per voxel and wears the seams that fall out of that, and a
-- disc is a turned solid with no grid to draw.
function StadiumStage.draw(arena, groundY)
  if not (arena and arena.discs) then return end
  local m = StadiumStage.mesh()
  local tex = StadiumStage.texture()
  if not (m and tex) then return end
  Voxel3D.seams(false)
  Voxel3D.glass(false)
  each(arena, groundY, function(matrix) Voxel3D.draw(m, tex, matrix) end)
  Voxel3D.glass(true)
  Voxel3D.seams(true)
end

-- And into the sun, so the two Pokemon put real shadows on the platforms they
-- are standing on. Without this the shadow map is empty where the discs are
-- and a mon casts onto nothing at all -- which, with no ground behind it
-- either, reads as the pair floating.
function StadiumStage.cast(shadowMap, arena, groundY)
  if not (arena and arena.discs and shadowMap) then return end
  local m = StadiumStage.mesh()
  local tex = StadiumStage.texture()
  if not (m and tex) then return end
  each(arena, groundY, function(matrix) shadowMap.draw(m, tex, matrix) end)
end

return StadiumStage
