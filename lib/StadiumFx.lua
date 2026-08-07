-- STADIUM battles: the generated fire and gas stand-ins.
--
-- A port of model_extract/pipeline/effects.py, plus the bind-pose measurement
-- build.py sizes them against.
--
-- IMPORTANT: nothing here is extracted game data. The real tail flame, mane
-- fire and gas are drawn by procedural callbacks that live in a different
-- fragment -- geo command 0x08 records an attachment point and
-- func_80014A60 calls node->unk_10, and the model file supplies only two
-- empty display lists plus zeroed scratch buffers for it to fill. Those
-- callbacks have not been ported, so the models genuinely contain no flame
-- mesh and no flame texture: Charmander's texture set is eyes, claws, teeth
-- and skin.
--
-- What follows is an ORIGINAL, procedurally generated replacement -- looping
-- flipbook noise on a pair of crossed quads, anchored to the exact bone the
-- callback hangs off so it sits where the real effect would and follows the
-- animation. Seeds derive from the species number, so a given Pokemon always
-- generates the same flame.
--
-- Which species get one is the game's own grouping: every species sharing a
-- callback shares an effect.
--
--   0x810000D8  Charmander, Charmeleon, Charizard, Magmar, Moltres   tail flame
--   0x81000108  Ponyta, Rapidash, Moltres's wings                    small flame
--   0x810000E0  Gastly (only)                                        gas cloud

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local StadiumFx = {}

local floor = math.floor
local sqrt = math.sqrt
local sin, cos = math.sin, math.cos
local char = string.char
local concat = table.concat
local pi = math.pi

local FIRE_TAIL  = 0x810000D8
local FIRE_SMALL = 0x81000108
local AURA       = 0x810000E0

-- Desired size as a fraction of the model's world-space height: length, width.
StadiumFx.SIZES = {
  fire_tail  = { 0.40, 0.22 },
  fire_small = { 0.075, 0.042 },
  gas        = { 1.05, 1.05 },
}

-- ------- 32-bit exclusive-or, in arithmetic
--
-- The generator below is an xorshift, so it needs a real 32-bit xor and a
-- real 32-bit wrap. Written out rather than taken from LuaJIT's `bit`, which
-- works in SIGNED 32-bit and would need converting back on every step -- see
-- the same note in StadiumFragment.

local function bxor32(a, b)
  local r, p = 0, 1
  for _ = 1, 32 do
    local x, y = a % 2, b % 2
    if x ~= y then r = r + p end
    a, b, p = floor(a / 2), floor(b / 2), p * 2
  end
  return r
end

-- ------- deterministic noise

local Rng = {}
Rng.__index = Rng

local function newRng(seed)
  local s = seed % 0x100000000
  if s == 0 then s = 0x9E3779B9 end
  return setmetatable({ s = s }, Rng)
end

function Rng:next()
  local x = self.s
  x = bxor32(x, (x % 0x80000) * 0x2000)               -- x ^= (x << 13)
  x = bxor32(x, floor(x / 0x20000))                   -- x ^= x >> 17
  x = bxor32(x, (x % 0x8000000) * 0x20)               -- x ^= (x << 5)
  self.s = x % 0x100000000
  return self.s
end

function Rng:unit()
  return self:next() / 0x100000000
end

-- A w-by-h lattice of unit noise, consumed row by row so the sequence -- and
-- therefore the texture -- is reproducible.
local function lattice(rng, w, h)
  local g = {}
  for y = 1, h do
    local row = {}
    for x = 1, w do row[x] = rng:unit() end
    g[y] = row
  end
  return g
end

local function smooth(t)
  return t * t * (3 - 2 * t)
end

-- Bilinear value noise on a torus, so the field tiles in both axes.
local function sample(grid, x, y)
  local h = #grid
  local w = #grid[1]
  local fx0, fy0 = floor(x), floor(y)
  local x0, y0 = fx0 % w, fy0 % h
  local x1, y1 = (x0 + 1) % w, (y0 + 1) % h
  local fx, fy = smooth(x - fx0), smooth(y - fy0)
  local r0, r1 = grid[y0 + 1], grid[y1 + 1]
  local a = r0[x0 + 1] + (r0[x1 + 1] - r0[x0 + 1]) * fx
  local b = r1[x0 + 1] + (r1[x1 + 1] - r1[x0 + 1]) * fx
  return a + (b - a) * fy
end

-- Sum octaves of tileable noise.
local function fbm(grids, x, y, scale)
  local total, amp, norm = 0.0, 1.0, 0.0
  for i = 1, #grids do
    local f = scale * 2 ^ (i - 1)
    total = total + sample(grids[i], x * f, y * f) * amp
    norm = norm + amp
    amp = amp * 0.5
  end
  return total / norm
end

-- Intensity -> RGBA, through a piecewise ramp.
local function ramp(stops, t)
  if t < 0.0 then t = 0.0 elseif t > 1.0 then t = 1.0 end
  for i = 1, #stops - 1 do
    local a, b = stops[i], stops[i + 1]
    if t <= b[1] then
      local k = 0.0
      if b[1] ~= a[1] then k = (t - a[1]) / (b[1] - a[1]) end
      return floor(a[2] + (b[2] - a[2]) * k), floor(a[3] + (b[3] - a[3]) * k),
             floor(a[4] + (b[4] - a[4]) * k), floor(a[5] + (b[5] - a[5]) * k)
    end
  end
  local last = stops[#stops]
  return last[2], last[3], last[4], last[5]
end

local FIRE_RAMP = {
  { 0.00, 0, 0, 0, 0 },
  { 0.30, 120, 24, 8, 90 },
  { 0.52, 226, 78, 16, 205 },
  { 0.74, 252, 176, 44, 245 },
  { 1.00, 255, 246, 214, 255 },
}

local GAS_RAMP = {
  { 0.00, 0, 0, 0, 0 },
  { 0.34, 52, 26, 78, 70 },
  { 0.60, 96, 52, 140, 140 },
  { 0.82, 148, 96, 196, 190 },
  { 1.00, 208, 176, 236, 215 },
}

local TRANSPARENT = char(0, 0, 0, 0)

-- An upward-advected noise plume. Scrolling by an exact multiple of the
-- lattice over the frame count is what makes the loop seamless.
local function fireFrames(seed, w, h, frames, wisp)
  wisp = wisp or 1.0
  local rng = newRng(seed)
  local grids = { lattice(rng, 8, 8), lattice(rng, 16, 16),
                  lattice(rng, 32, 32) }
  local out = {}
  for f = 0, frames - 1 do
    local t = f / frames
    local buf = {}
    for i = 1, w * h do buf[i] = TRANSPARENT end
    for y = 0, h - 1 do
      local v = y / (h - 1)                 -- 0 at the base, 1 at the tip
      -- plume envelope: wide and hot at the base, pinched at the tip
      local taper = 1.0 - v
      if taper < 0.0 then taper = 0.0 end
      taper = taper ^ 0.42
      for x = 0, w - 1 do
        local u = (x / (w - 1)) * 2 - 1     -- -1 .. 1 across the flame
        local denom = taper * 0.95
        if denom < 0.10 then denom = 0.10 end
        local radial = 1.0 - (u < 0 and -u or u) / denom
        if radial > 0 then
          radial = radial ^ 0.7
          local n = fbm(grids, x / w, (y / h) - t, 3.0)
          local lick = 0.55 + 0.75 * (n - 0.5) * wisp
          local inten = radial * (0.55 + 0.8 * taper) * lick
          inten = inten - 0.16 * v           -- cool towards the tip
          if inten > 0.02 then
            local r, g, b, a = ramp(FIRE_RAMP, inten)
            -- +Y in texture space is up
            buf[(h - 1 - y) * w + x + 1] = char(r, g, b, a)
          end
        end
      end
    end
    out[f + 1] = concat(buf)
  end
  return w, h, out
end

-- Slow swirling haze that fades out towards the rim.
local function gasFrames(seed, w, h, frames)
  local rng = newRng(seed)
  local grids = { lattice(rng, 8, 8), lattice(rng, 16, 16),
                  lattice(rng, 32, 32) }
  local out = {}
  for f = 0, frames - 1 do
    local t = f / frames
    local buf = {}
    for i = 1, w * h do buf[i] = TRANSPARENT end
    local ang = t * 2 * pi
    local ca, sa = cos(ang), sin(ang)
    for y = 0, h - 1 do
      for x = 0, w - 1 do
        local dx = (x / (w - 1)) * 2 - 1
        local dy = (y / (h - 1)) * 2 - 1
        local d = sqrt(dx * dx + dy * dy)
        if d < 1.0 then
          local falloff = (1.0 - d) ^ 0.85
          -- rotate the sample point so the haze churns without popping
          local sx = dx * ca - dy * sa
          local sy = dx * sa + dy * ca
          local n = fbm(grids, sx * 0.5 + 0.5, sy * 0.5 + 0.5 - t, 2.5)
          local inten = falloff * (0.78 + 1.30 * (n - 0.44))
          if inten > 0.03 then
            local r, g, b, a = ramp(GAS_RAMP, inten)
            buf[y * w + x + 1] = char(r, g, b, a)
          end
        end
      end
    end
    out[f + 1] = concat(buf)
  end
  return w, h, out
end

-- Two quads at right angles, so the effect reads from any angle. `axis` picks
-- which bone-local direction the quad grows along: bone-local +X runs down the
-- limb, so a flame laid out along X comes out lying sideways, and 'y' is that
-- same quad turned a quarter left about Z, which stands it up. `centred`
-- straddles the origin instead of growing from it.
local function crossedQuads(bone, length, width, axis, centred)
  local pos, uv, nrm, skin, idx = {}, {}, {}, {}, {}
  local ST = { { 0, 0 }, { 1, 0 }, { 1, 1 }, { 0, 1 } }
  local nv, ni = 0, 0
  for q = 0, 1 do
    local base = nv
    for k = 1, 4 do
      local s, t = ST[k][1], ST[k][2]
      local a = (s - 0.5) * width
      local b = centred and (t - 0.5) * length or t * length
      local px, py, pz
      if axis == "x" then
        if q == 0 then px, py, pz = b, a, 0.0 else px, py, pz = b, 0.0, a end
      else                                       -- (x, y) -> (-y, x)
        if q == 0 then px, py, pz = -a, b, 0.0 else px, py, pz = 0.0, b, a end
      end
      pos[nv * 3 + 1], pos[nv * 3 + 2], pos[nv * 3 + 3] = px, py, pz
      uv[nv * 2 + 1], uv[nv * 2 + 2] = s, 1.0 - t
      if q == 0 then
        nrm[nv * 3 + 1], nrm[nv * 3 + 2], nrm[nv * 3 + 3] = 0.0, 0.0, 1.0
      else
        nrm[nv * 3 + 1], nrm[nv * 3 + 2], nrm[nv * 3 + 3] = 1.0, 0.0, 0.0
      end
      skin[nv + 1] = bone
      nv = nv + 1
    end
    idx[ni + 1], idx[ni + 2], idx[ni + 3] = base, base + 1, base + 2
    idx[ni + 4], idx[ni + 5], idx[ni + 6] = base, base + 2, base + 3
    ni = ni + 6
  end
  return { pos = pos, uv = uv, nrm = nrm, skin = skin, nverts = nv,
           idx = idx, nidx = ni }
end

-- ------- the bind pose these are sized against
--
-- build.py's bind_extent, kept in its own 4x4 column-major convention rather
-- than folded into StadiumBuild's 3x4 walk. The two agree -- they are the
-- same skeleton -- but the effect sizes come out of THIS one's per-bone scale
-- measurement, and rewriting it into the other convention is exactly the kind
-- of change that moves a byte without anyone noticing.

local function trs(t, r, s)
  local function S(v) return sin(v / 32768 * pi) end
  local function C(v) return cos(v / 32768 * pi) end
  local sx, cx = S(r[1]), C(r[1])
  local sy, cy = S(r[2]), C(r[2])
  local sz, cz = S(r[3]), C(r[3])
  return { cy * cz * s[1], cy * sz * s[1], -sy * s[1], 0,
           (sx * sy * cz - cx * sz) * s[2], (sx * sy * sz + cx * cz) * s[2],
           sx * cy * s[2], 0,
           (cx * sy * cz + sx * sz) * s[3], (cx * sy * sz - sx * cz) * s[3],
           cx * cy * s[3], 0,
           t[1], t[2], t[3], 1 }
end

local function mul(a, b)
  local r = {}
  for c = 0, 3 do
    for i = 1, 4 do
      r[c * 4 + i] = a[i] * b[c * 4 + 1] + a[4 + i] * b[c * 4 + 2]
                     + a[8 + i] * b[c * 4 + 3] + a[12 + i] * b[c * 4 + 4]
    end
  end
  return r
end

-- (height of the bind pose, per-bone local scale). Height rather than the
-- largest dimension: sizing off the max would scale Moltres's flames to its
-- wingspan.
function StadiumFx.bindExtent(data)
  local root = trs({ 0, 0, 0 }, { 0, 0, 0 }, data.rootScale)
  local acc, uns, mats = {}, {}, {}
  for i = 1, #data.bones do
    local b = data.bones[i]
    local p = b.parent
    local pa = (p >= 0) and acc[p + 1] or { 1.0, 1.0, 1.0 }
    local pu = (p >= 0) and uns[p + 1] or root
    local u = mul(pu, trs({ b.t[1] * pa[1], b.t[2] * pa[2], b.t[3] * pa[3] },
                          b.r, { 1, 1, 1 }))
    local a = { pa[1] * b.s[1], pa[2] * b.s[2], pa[3] * b.s[3] }
    local m = {}
    for k = 1, 16 do m[k] = u[k] end
    for k = 1, 4 do
      m[k] = m[k] * a[1]
      m[4 + k] = m[4 + k] * a[2]
      m[8 + k] = m[8 + k] * a[3]
    end
    acc[i], uns[i], mats[i] = a, u, m
  end

  local lo = { 1e9, 1e9, 1e9 }
  local hi = { -1e9, -1e9, -1e9 }
  for _, prim in ipairs(data.prims) do
    local pos, skin = prim.pos, prim.skin
    for i = 1, prim.nverts do
      local m = mats[skin[i] + 1]
      if m then
        local x, y, z = pos[i * 3 - 2], pos[i * 3 - 1], pos[i * 3]
        local wx = m[1] * x + m[5] * y + m[9] * z + m[13]
        local wy = m[2] * x + m[6] * y + m[10] * z + m[14]
        local wz = m[3] * x + m[7] * y + m[11] * z + m[15]
        if wx < lo[1] then lo[1] = wx end
        if wy < lo[2] then lo[2] = wy end
        if wz < lo[3] then lo[3] = wz end
        if wx > hi[1] then hi[1] = wx end
        if wy > hi[2] then hi[2] = wy end
        if wz > hi[3] then hi[3] = wz end
      end
    end
  end
  local extent = (lo[1] <= hi[1]) and (hi[2] - lo[2]) or 1.0

  -- how much each bone scales its own local space, so an effect can divide it
  -- back out and come out the size it asked for wherever it hangs
  local scales = {}
  for i = 1, #mats do
    local m = mats[i]
    scales[i] = sqrt(m[1] * m[1] + m[2] * m[2] + m[3] * m[3])
  end
  return extent, scales
end

-- ------- what a species gets

-- Returns a list of { kind, bone, geo, w, h, frames }, or an empty list.
function StadiumFx.buildFor(species, fx, extent, boneScale)
  local out = {}
  for _, node in ipairs(fx) do
    local cb, bone = node.callback, node.bone
    if bone >= 0 and bone < #boneScale then
      local k = boneScale[bone + 1]
      if k == 0 then k = 1.0 end
      if cb == FIRE_TAIL then
        local fl, fw = StadiumFx.SIZES.fire_tail[1], StadiumFx.SIZES.fire_tail[2]
        local w, h, fr = fireFrames(species * 7919 + 1, 32, 64, 8)
        out[#out + 1] = { kind = "fire", bone = bone, w = w, h = h, frames = fr,
                          geo = crossedQuads(bone, extent * fl / k,
                                             extent * fw / k, "y", false) }
      elseif cb == FIRE_SMALL then
        local fl, fw = StadiumFx.SIZES.fire_small[1],
                       StadiumFx.SIZES.fire_small[2]
        local w, h, fr = fireFrames(species * 6271 + bone, 24, 40, 8, 1.25)
        out[#out + 1] = { kind = "fire", bone = bone, w = w, h = h, frames = fr,
                          geo = crossedQuads(bone, extent * fl / k,
                                             extent * fw / k, "y", false) }
      elseif cb == AURA and species == 92 then        -- Gastly only
        local fl, fw = StadiumFx.SIZES.gas[1], StadiumFx.SIZES.gas[2]
        local w, h, fr = gasFrames(species * 5237 + 3, 48, 48, 10)
        out[#out + 1] = { kind = "gas", bone = bone, w = w, h = h, frames = fr,
                          geo = crossedQuads(bone, extent * fl / k,
                                             extent * fw / k, "y", true) }
      end
    end
  end
  return out
end

-- Append the generated prims and their flipbook textures to a model, exactly
-- as build.py's attach_effects does. Returns how many were made.
function StadiumFx.attach(data, species)
  if not (data.fx and #data.fx > 0) then return 0 end
  local extent, boneScale = StadiumFx.bindExtent(data)
  local made = StadiumFx.buildFor(species, data.fx, extent, boneScale)
  for _, e in ipairs(made) do
    local first = #data.textures                      -- 0-based, as the file
    for i = 1, #e.frames do
      data.textures[first + i] = { index = -1, w = e.w, h = e.h,
                                   generated = true, rgba = e.frames[i] }
    end
    local g = e.geo
    local fxFrames = {}
    for i = 1, #e.frames do fxFrames[i] = first + i - 1 end
    data.prims[#data.prims + 1] = {
      tex = first, cull = 0, texAnim = -1, texMap = nil,
      generated = true, effect = e.kind,
      blend = (e.kind == "fire") and "add" or "alpha",
      fxFrames = fxFrames,
      pos = g.pos, uv = g.uv, nrm = g.nrm, skin = g.skin, nverts = g.nverts,
      idx = g.idx, nidx = g.nidx,
    }
  end
  return #made
end

return StadiumFx
