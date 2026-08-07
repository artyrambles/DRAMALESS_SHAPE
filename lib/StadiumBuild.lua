-- STADIUM battles: turning the ROM into assets/stadium/NNN.dsm.
--
-- The Lua half of tools/stadium_pack.py: measure the bind pose, decide
-- whether a species' standby loop can be trusted, and write the packed file.
-- Together with StadiumRom, StadiumFragment and StadiumFx this is everything
-- between `baserom.z64` and a Pokemon standing on a battle tile.
--
-- The Python remains the ORACLE. tests/stadium_extract_test.lua runs this
-- over the same ROM and requires all 151 files to come out byte for byte
-- identical to what the packer writes. That is a strong test in a way a unit
-- test of any one function here would not be: every rounding mode, every
-- iteration order, every off-by-one in an index shows up as a differing byte,
-- and there are thirty-four megabytes of them.
--
-- ------- stepped, not blocking
--
-- `StadiumBuild.job()` returns a coroutine-backed job that does one species
-- per `step()`, so the caller can draw a progress bar between them
-- (StadiumInstall). A species is a few tens of milliseconds; the whole set is
-- around half a minute, which is far too long to spend inside one frame and
-- perfectly fine spread across a loading screen.

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local StadiumRom = V.require("StadiumRom")
local StadiumFragment = V.require("StadiumFragment")
local StadiumFx = V.require("StadiumFx")

local StadiumBuild = {}

local floor = math.floor
local sin, cos = math.sin, math.cos
local pi = math.pi
local char = string.char
local concat = table.concat
local frexp = math.frexp
local roundHalfEven = StadiumFragment.roundHalfEven

-- The battle system's fixed context slots, in slot order from 165. The mod
-- indexes this list by POSITION, so the ORDER is the format's contract and
-- has to stay identical to StadiumPack.CONTEXT and to the packer's CONTEXTS.
StadiumBuild.CONTEXTS = {
  "idle", "attack_default", "faint", "entrance", "reaction_169", "reaction_170",
  "reaction_171", "reaction_172", "reaction_173", "reaction_174",
  "struggle", "idle_alt", "faint_alt", "flinch", "reaction_179",
  "reaction_180", "reaction_181", "reaction_182", "entrance_alt",
  "idle_return",
}

-- Which context name wins when several claim the same animation.
local NAME_PREF = { "idle", "attack_default", "faint", "entrance",
                    "struggle", "flinch" }

local N_MOVES = StadiumRom.N_MOVES
local CTX_BASE = 165
local NONE16 = 0xFFFF

-- ------- the bind pose

-- The game's rotation as a 3x3, rows first (src/F420.c func_8000F730):
-- Rx*Ry*Rz in row-vector form.
local function quatBasis(r)
  local sx, cx = sin(r[1] / 32768 * pi), cos(r[1] / 32768 * pi)
  local sy, cy = sin(r[2] / 32768 * pi), cos(r[2] / 32768 * pi)
  local sz, cz = sin(r[3] / 32768 * pi), cos(r[3] / 32768 * pi)
  return { cy * cz, sx * sy * cz - cx * sz, cx * sy * cz + sx * sz },
         { cy * sz, sx * sy * sz + cx * cz, cx * sy * sz - sx * cz },
         { -sy, sx * cy, cx * cy }
end

-- 3x4 (three rotation rows plus a translation column) times the same.
local function matMul(a, b)
  local out = {}
  for r = 1, 3 do
    local ar = a[r]
    out[r] = {
      ar[1] * b[1][1] + ar[2] * b[2][1] + ar[3] * b[3][1],
      ar[1] * b[1][2] + ar[2] * b[2][2] + ar[3] * b[3][2],
      ar[1] * b[1][3] + ar[2] * b[2][3] + ar[3] * b[3][3],
      ar[1] * b[1][4] + ar[2] * b[2][4] + ar[3] * b[3][4] + ar[4],
    }
  end
  return out
end

-- One component of one bone's t/r/s at a frame. The extractor's own shape: a
-- bare number when the component holds still for the whole animation, one
-- number a frame when it does not.
local function component(comps, i, frame, fallback)
  if comps == nil then return fallback end
  local c = comps[i]
  if type(c) == "table" then
    local n = #c
    if n == 0 then return fallback end
    return c[frame % n + 1]
  end
  return c
end

-- The bone TRS an animation holds at `frame`, rest where it is silent.
local function animSample(bones, anim, frame)
  local tracks = anim.tracks
  return function(i)
    local b = bones[i]
    local tr = tracks[i]
    if not tr then return b.t, b.r, b.s end
    return { component(tr.t, 1, frame, b.t[1]),
             component(tr.t, 2, frame, b.t[2]),
             component(tr.t, 3, frame, b.t[3]) },
           { component(tr.r, 1, frame, b.r[1]),
             component(tr.r, 2, frame, b.r[2]),
             component(tr.r, 3, frame, b.r[3]) },
           { component(tr.s, 1, frame, b.s[1]),
             component(tr.s, 2, frame, b.s[2]),
             component(tr.s, 3, frame, b.s[3]) }
  end
end

local function restSample(bones)
  return function(i)
    local b = bones[i]
    return b.t, b.r, b.s
  end
end

-- Every bone's draw matrix at one instant, as 3x4 rows.
--
-- The game keeps bone scale OUT of the matrix chain: it accumulates in its own
-- stack, a bone's local translation is pre-multiplied by the PARENT's
-- accumulated scale, and the bone's own accumulated scale is applied to the
-- finished matrix at draw time.
--
-- Two chains, and the distinction is the whole point: `pivot` is the
-- rotation/translation a CHILD inherits, and the draw matrix is that with the
-- bone's own accumulated scale applied on the right. Folding the scale into
-- the chain instead applies every ancestor's scale twice -- which is exactly
-- the multiplicative propagation glTF has and the game does not.
local function bindMatrices(bones, sample)
  sample = sample or restSample(bones)
  local pivot, draw, acc = {}, {}, {}
  local IDENT = { { 1, 0, 0, 0 }, { 0, 1, 0, 0 }, { 0, 0, 1, 0 } }
  for i = 1, #bones do
    local bt, br, bs = sample(i)
    local p = bones[i].parent
    local pa = (p >= 0) and acc[p + 1] or { 1.0, 1.0, 1.0 }
    local pm = (p >= 0) and pivot[p + 1] or IDENT
    local r1, r2, r3 = quatBasis(br)
    local m = matMul(pm, {
      { r1[1], r1[2], r1[3], bt[1] * pa[1] },
      { r2[1], r2[2], r2[3], bt[2] * pa[2] },
      { r3[1], r3[2], r3[3], bt[3] * pa[3] },
    })
    local a = { pa[1] * bs[1], pa[2] * bs[2], pa[3] * bs[3] }
    acc[i] = a
    pivot[i] = m
    -- scale on the right: the bone's own space, so it cannot reach children
    draw[i] = {
      { m[1][1] * a[1], m[1][2] * a[2], m[1][3] * a[3], m[1][4] },
      { m[2][1] * a[1], m[2][2] * a[2], m[2][3] * a[3], m[2][4] },
      { m[3][1] * a[1], m[3][2] * a[2], m[3][3] * a[3], m[3][4] },
    }
  end
  return draw
end

StadiumBuild.bindMatrices = bindMatrices
StadiumBuild.animSample = animSample

-- The axis-aligned box the whole model occupies under `mats`, in game units
-- after the model_root scale.
local function poseBox(data, mats)
  local root = data.rootScale[1]
  local lo1, lo2, lo3 = 1e30, 1e30, 1e30
  local hi1, hi2, hi3 = -1e30, -1e30, -1e30
  for _, prim in ipairs(data.prims) do
    local pos, skin = prim.pos, prim.skin
    for i = 1, prim.nverts do
      local m = mats[skin[i] + 1]
      if m then
        local x, y, z = pos[i * 3 - 2], pos[i * 3 - 1], pos[i * 3]
        local a = (m[1][1] * x + m[1][2] * y + m[1][3] * z + m[1][4]) * root
        local b = (m[2][1] * x + m[2][2] * y + m[2][3] * z + m[2][4]) * root
        local c = (m[3][1] * x + m[3][2] * y + m[3][3] * z + m[3][4]) * root
        if a < lo1 then lo1 = a end
        if b < lo2 then lo2 = b end
        if c < lo3 then lo3 = c end
        if a > hi1 then hi1 = a end
        if b > hi2 then hi2 = b end
        if c > hi3 then hi3 = c end
      end
    end
  end
  return lo1, lo2, lo3, hi1, hi2, hi3
end

-- (height, floor, radius): how tall the mon is, where its lowest point sits
-- relative to the model's own origin, and how wide it is -- all in game units
-- after the model_root scale.
--
-- Measured on the BIND POSE, which is the one pose in the set that can be
-- trusted for this. It reproduces the verified glTF export exactly on all 151
-- species, and it is immune to the animation quirks a handful of them carry
-- (see idleIsBroken) -- quirks that would otherwise decide how big every OTHER
-- frame of those species is drawn.
--
-- The floor is the interesting number, and it reads cleanly: 119 of the 151
-- sit within 5% of zero, which says the model origin IS where the game stands
-- a Pokemon on its field. Every species that does not is one that hovers.
local function stance(data)
  local lo1, lo2, lo3, hi1, hi2, hi3 = poseBox(data, bindMatrices(data.bones))
  if lo1 > hi1 then return 0.0, 0.0, 0.0 end
  local w, d = hi1 - lo1, hi3 - lo3
  return hi2 - lo2, lo2, (w > d and w or d) / 2
end

StadiumBuild.stance = stance

-- Whether this species' standby loop is corrupt as extracted.
--
-- No species trips this today. Exeggutor, Tangela and Magmar used to, when
-- the flags byte was misread and their hermite-keyframe animations were
-- decoded as packed streams, throwing bones hundreds of units off the body.
-- It stays as the guard against the next extraction bug: played, a broken
-- idle looks like a Pokemon coming apart, and the mod would rather show
-- the sprite fallback (see StadiumMon).
--
-- The test is deliberately narrow, because "differs from the bind pose" is NOT
-- brokenness. It is asked only of the STANDBY loop -- the one animation that
-- is supposed to stay where it is, since a faint is meant to end far from the
-- standing pose and an attack is meant to lunge -- and it wants both a large
-- size blow-up and real drift, or an enormous amount of one. Dewgong is what
-- calibrates it: its idle is 2.4x its own bind pose because the BIND is the
-- collapsed one, and it drifts barely at all, so it must not be caught.
local function idleIsBroken(data, idle)
  if idle == nil then return false end
  local bones = data.bones
  local _, lo2, _, _, hi2 = poseBox(data, bindMatrices(bones))
  local span = hi2 - lo2
  if span <= 0 then return false end
  local worstH, worstDrift = 1.0, 0.0
  local frame = 0
  while frame < idle.frames do
    local _, flo2, _, _, fhi2 = poseBox(data,
      bindMatrices(bones, animSample(bones, idle, frame)))
    local h = (fhi2 - flo2) / span
    if h > worstH then worstH = h end
    local d1 = (flo2 - lo2) / span
    local d2 = (fhi2 - hi2) / span
    if d1 < 0 then d1 = -d1 end
    if d2 < 0 then d2 = -d2 end
    if d1 > worstDrift then worstDrift = d1 end
    if d2 > worstDrift then worstDrift = d2 end
    frame = frame + 3
  end
  return (worstH > 2.5 and worstDrift > 1.5)
         or worstDrift > 2.0 or worstH > 3.4
end

-- ------- writing

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

-- Toward zero, which is what Python's int() does to a float and NOT what
-- floor() does to a negative one.
--
-- It matters in exactly one place, and it is easy to miss: almost everything
-- reaching the integer writers below has already been rounded, so truncation
-- is a no-op on it. The exception is the generated effects' crossed quads
-- (StadiumFx), whose vertices are raw floats and straddle the origin -- so
-- the ones at negative x, and only those, come out a unit adrift if this
-- floors.
local function trunc(v)
  if v >= 0 then return floor(v) end
  return -floor(-v)
end

-- 16.16, which holds every bone scale in the set (-31 .. 100) with more
-- precision than anything can see.
local function fixed(v)
  return clamp(roundHalfEven(v * 65536), -2147483648, 2147483647)
end

-- IEEE 754 single, little-endian, rounded to nearest with ties to even -- the
-- same rounding Python's struct.pack('<f') does, so the four floats in the
-- header come out bit for bit the same as the packer's.
local function f32(x)
  local sign = 0
  if x < 0 or (x == 0 and 1 / x < 0) then
    sign = 128
    x = -x
  end
  if x ~= x then return char(0, 0, 192, 127 + sign) end        -- NaN
  if x == math.huge then return char(0, 0, 128, 127 + sign) end
  if x == 0 then return char(0, 0, 0, sign) end
  local m, e = frexp(x)                       -- x = m * 2^e, 0.5 <= m < 1
  local E = e - 1 + 127
  local mant
  if E >= 255 then
    return char(0, 0, 128, 127 + sign)                          -- overflow
  elseif E <= 0 then
    -- subnormal: no exponent left, so the mantissa carries the whole value
    mant = roundHalfEven(x / 2 ^ -149)
    if mant >= 8388608 then
      mant, E = mant - 8388608, 1
    else
      E = 0
    end
  else
    mant = roundHalfEven((m * 2 - 1) * 8388608)
    if mant == 8388608 then                   -- rounded up into the next
      mant, E = 0, E + 1
      if E >= 255 then return char(0, 0, 128, 127 + sign) end
    end
  end
  local b4 = sign + floor(E / 2)
  local b3 = (E % 2) * 128 + floor(mant / 65536)
  local b2 = floor(mant / 256) % 256
  local b1 = mant % 256
  return char(b1, b2, b3, b4)
end

StadiumBuild.f32 = f32

local Writer = {}
Writer.__index = Writer

local function newWriter()
  return setmetatable({ parts = {}, n = 0 }, Writer)
end

function Writer:raw(s)
  self.n = self.n + 1
  self.parts[self.n] = s
end

function Writer:u8(v)
  self:raw(char(v % 256))
end

function Writer:i8(v)
  v = clamp(trunc(v), -128, 127)
  self:raw(char(v % 256))
end

function Writer:u16(v)
  v = v % 65536
  self:raw(char(v % 256, floor(v / 256)))
end

function Writer:i16(v)
  v = clamp(trunc(v), -32768, 32767) % 65536
  self:raw(char(v % 256, floor(v / 256)))
end

function Writer:u32(v)
  v = v % 4294967296
  self:raw(char(v % 256, floor(v / 256) % 256, floor(v / 65536) % 256,
                floor(v / 16777216) % 256))
end

function Writer:i32(v)
  v = clamp(trunc(v), -2147483648, 2147483647) % 4294967296
  self:raw(char(v % 256, floor(v / 256) % 256, floor(v / 65536) % 256,
                floor(v / 16777216) % 256))
end

function Writer:f32(v)
  self:raw(f32(v))
end

function Writer:bytes()
  return concat(self.parts)
end

-- One component of one bone's t/r/s in one animation. `values` is the
-- extractor's own shape: a bare number when the component holds still for the
-- whole animation, or one number a frame when it does not. That fold is where
-- most of the size saving is -- a bone that only rotates costs two bytes for
-- each of its six other components.
local function writeTrackComponent(w, values, kind)
  local isArray = type(values) == "table"
  w:u8(isArray and 1 or 0)
  if kind == "s" then
    if isArray then
      for i = 1, #values do w:i32(fixed(values[i])) end
    else
      w:i32(fixed(values))
    end
  else
    if isArray then
      for i = 1, #values do w:i16(roundHalfEven(values[i])) end
    else
      w:i16(roundHalfEven(values))
    end
  end
end

-- Which animation each fixed battle context slot resolves to: entries 165
-- upward of the species' own battle table, in slot order. An entry naming an
-- animation the species does not have is written as "none" rather than
-- clamped -- the mod would rather fall back than play the wrong clip.
function StadiumBuild.contextTable(rows, nAnims)
  local ctx = {}
  for i = 1, #StadiumBuild.CONTEXTS do
    local row = rows[CTX_BASE + i - 1]
    local ai = row and row[1] or nil
    ctx[i] = (ai ~= nil and ai < nAnims) and ai or NONE16
  end
  return ctx
end

-- ------- naming the animations
--
-- build.py's label_animations. The names are not read at runtime -- the mod
-- addresses animations by index through the move and context tables -- but
-- they are in the format, so they have to be produced the same way for the
-- oracle diff to mean anything. They also make a packed file readable in a
-- hex dump, which is worth the byte apiece.

local function labelAnimations(data, rows, nAux)
  local anims = data.anims
  local n = #anims
  local uses, moveUses = {}, {}
  local auxOrder, auxCount = {}, {}
  for i = 1, n do
    uses[i], moveUses[i] = {}, 0
    auxOrder[i], auxCount[i] = {}, {}
  end
  for e = 0, rows.n - 1 do
    local ai = rows[e][1]
    if ai < n then
      if e < N_MOVES then
        moveUses[ai + 1] = moveUses[ai + 1] + 1
      elseif e >= CTX_BASE and e < CTX_BASE + #StadiumBuild.CONTEXTS then
        local list = uses[ai + 1]
        list[#list + 1] = StadiumBuild.CONTEXTS[e - CTX_BASE + 1]
      end
      local ax = rows[e][2]
      if ax >= 0 and ax < nAux then
        local counts, order = auxCount[ai + 1], auxOrder[ai + 1]
        if counts[ax] == nil then
          counts[ax] = 0
          order[#order + 1] = ax
        end
        counts[ax] = counts[ax] + 1
      end
    end
  end

  for i = 1, n do
    -- sorted(set(uses)) -- the alphabetically first context is the fallback
    -- name, so the ordering is part of the answer
    local seen, ctx = {}, {}
    for _, name in ipairs(uses[i]) do
      if not seen[name] then
        seen[name] = true
        ctx[#ctx + 1] = name
      end
    end
    table.sort(ctx)
    local name = nil
    for _, pref in ipairs(NAME_PREF) do
      if seen[pref] then
        name = pref
        break
      end
    end
    if not name then
      if moveUses[i] > 0 then
        name = "attack"
      elseif ctx[1] then
        name = ctx[1]
      else
        name = "anim" .. (i - 1)
      end
    end
    anims[i].name = name
    -- Counter.most_common(1): the highest count, and on a tie the one that
    -- was inserted first
    local best, bestN = -1, -1
    local order, counts = auxOrder[i], auxCount[i]
    for _, ax in ipairs(order) do
      if counts[ax] > bestN then
        best, bestN = ax, counts[ax]
      end
    end
    anims[i].aux = best
  end

  local seenName = {}
  for i = 1, n do
    local base = anims[i].name
    local k = seenName[base] or 0
    seenName[base] = k + 1
    if k > 0 then anims[i].name = base .. "_" .. (k + 1) end
  end
end

-- ------- the pack

function StadiumBuild.pack(data, species, moveRows, ctx)
  local w = newWriter()
  local bones, prims = data.bones, data.prims
  local textures, anims, aux = data.textures, data.anims, data.auxAnims

  local height, floorY, radius = stance(data)

  local idleIndex = ctx[1]                    -- CONTEXTS[1] is "idle"
  local idle = (idleIndex ~= NONE16) and anims[idleIndex + 1] or nil
  local static = idleIsBroken(data, idle)

  w:raw("DSM3")
  w:u16(species)
  w:u16(#bones)
  w:u16(#prims)
  w:u16(#textures)
  w:u16(#anims)
  w:u16(#aux)
  w:f32(data.rootScale[1])
  -- 1 = hold the bind pose, never play an animation
  w:u8(static and 1 or 0)
  w:f32(height)
  w:f32(floorY)
  w:f32(radius)

  for m = 1, N_MOVES do
    local row = moveRows[m]
    w:u16((row and row[1] < #anims) and row[1] or NONE16)
  end
  for m = 1, N_MOVES do
    local row = moveRows[m]
    w:i16((row and row[2] >= 0 and row[2] < #aux) and row[2] or -1)
  end
  for i = 1, #ctx do w:u16(ctx[i]) end

  for i = 1, #bones do
    local b = bones[i]
    w:i16(b.parent)
    for k = 1, 3 do w:i16(roundHalfEven(b.t[k])) end
    for k = 1, 3 do w:i16(b.r[k]) end
    for k = 1, 3 do w:i32(fixed(b.s[k])) end
  end

  for i = 1, #prims do
    local p = prims[i]
    w:u16(p.tex)
    -- the display list's own cull mode: 1024 is G_CULL_BACK
    w:u8((p.cull and p.cull ~= 0) and 1 or 0)
    w:u8((p.blend == "add") and 1 or 0)
    w:i16(p.texAnim or -1)
    -- sorted by the stream's own byte, which is what the reader keys on
    local keys = {}
    if p.texMap then
      for k in pairs(p.texMap) do keys[#keys + 1] = k end
      table.sort(keys)
    end
    w:u8(#keys)
    for _, k in ipairs(keys) do
      w:u8(k)
      w:u16(p.texMap[k])
    end
    local frames = p.fxFrames
    w:u16(frames and #frames or 0)
    if frames then
      for k = 1, #frames do w:u16(frames[k]) end
    end
    local pos, uv, nrm, skin = p.pos, p.uv, p.nrm, p.skin
    w:u16(p.nverts)
    w:u16(p.nidx)
    for k = 1, p.nverts do
      w:i16(pos[k * 3 - 2])
      w:i16(pos[k * 3 - 1])
      w:i16(pos[k * 3])
      -- 1/512, which puts a texel of the largest texture in the set well
      -- inside a step and still reaches the +-32 the wrapped coordinates of
      -- some display lists run to
      w:i16(roundHalfEven(uv[k * 2 - 1] * 512))
      w:i16(roundHalfEven(uv[k * 2] * 512))
      w:i8(roundHalfEven(nrm[k * 3 - 2] * 127))
      w:i8(roundHalfEven(nrm[k * 3 - 1] * 127))
      w:i8(roundHalfEven(nrm[k * 3] * 127))
      w:u8(skin[k])
    end
    for k = 1, p.nidx do w:u16(p.idx[k]) end
  end

  for i = 1, #textures do
    local t = textures[i]
    w:u16(t.w)
    w:u16(t.h)
    w:u32(#t.rgba)
    w:raw(t.rgba)
  end

  local REST = { t = { 0, 0, 0 }, r = { 0, 0, 0 }, s = { 1.0, 1.0, 1.0 } }
  for i = 1, #anims do
    local a = anims[i]
    local name = a.name or ""
    if #name > 255 then name = name:sub(1, 255) end
    w:u8(#name)
    w:raw(name)
    w:u16(a.frames)
    w:u16(a.loopStart or 0)
    w:i16(a.aux or -1)
    for bi = 1, #bones do
      local tr = a.tracks[bi]
      if not tr then
        w:u8(0)
      else
        w:u8(1)
        for _, key in ipairs({ "t", "r", "s" }) do
          local comps = tr[key]
          if comps == nil then
            -- a bone the animation leaves at its rest value for this path:
            -- written as three constants so the reader never has to branch on
            -- a missing path
            comps = bones[bi][key] or REST[key]
          end
          for c = 1, 3 do writeTrackComponent(w, comps[c], key) end
        end
      end
    end
  end

  for i = 1, #aux do
    local a = aux[i]
    w:u16(a.frames)
    w:u16(a.loopStart or 0)
    w:u16(#a.channels)
    for _, ch in ipairs(a.channels) do
      w:u16(ch.n)
      for k = 1, ch.n do w:u16(ch[k]) end
    end
  end

  return w:bytes(), height, floorY, radius
end

-- ------- one species, end to end

-- The same three steps build.py takes: parse the fragment, label the
-- animations off the species' battle table, then hang the generated fire/gas
-- stand-ins on the bones the game's own effect callbacks hang off.
function StadiumBuild.species(rom, fileno)
  local blob = rom:model(fileno)
  if not blob then return nil, ("file %d is not in the archive"):format(fileno) end
  local data, err = StadiumFragment.extract(blob, ("%d.bin"):format(fileno))
  if not data then return nil, err end
  local species = data.species
  local rows = rom:battleRows(species)
  labelAnimations(data, rows, #data.auxAnims)
  StadiumFx.attach(data, species)

  local moveRows = {}
  for m = 1, N_MOVES do moveRows[m] = rows[m - 1] end
  local ctx = StadiumBuild.contextTable(rows, #data.anims)
  local bytes, height, floorY, radius =
    StadiumBuild.pack(data, species, moveRows, ctx)
  return { species = species, bytes = bytes, height = height,
           floor = floorY, radius = radius, bones = #data.bones,
           prims = #data.prims, anims = #data.anims,
           warnings = data.warnings }
end

-- ------- the stepped job
--
-- `write(species, bytes)` is called for each finished pack and must answer
-- truthy; anything else stops the job with an error. Returning a job rather
-- than taking a callback for progress keeps the caller in charge of when work
-- happens, which is what lets a loading screen stay responsive.
function StadiumBuild.job(rom, write, count)
  local total = count or StadiumRom.N_POKEMON
  local n = rom:modelCount()
  if total > n then total = n end
  local job = { total = total, done = 0, bytes = 0, failed = {}, species = nil }

  function job:step()
    if self.done >= self.total then return false end
    local fileno = self.done
    local ok, res, err = pcall(StadiumBuild.species, rom, fileno)
    if ok and res then
      local wrote, wErr = write(res.species, res.bytes)
      if not wrote then
        self.error = wErr or ("could not write species " .. res.species)
        self.done = self.total
        return false
      end
      self.bytes = self.bytes + #res.bytes
      self.species = res.species
    else
      self.failed[#self.failed + 1] = fileno
      self.lastError = ok and err or res
    end
    self.done = self.done + 1
    return self.done < self.total
  end

  function job:progress()
    if self.total <= 0 then return 1 end
    return self.done / self.total
  end

  return job
end

return StadiumBuild
