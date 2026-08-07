-- STADIUM battles: reading one species' model off disk.
--
-- `NNN.dsm` holds one Pokemon Stadium battle model. It is written by
-- StadiumBuild, out of the player's own copy of that ROM, the first time the
-- mod runs (see StadiumInstall) -- and by tools/stadium_pack.py, which is the
-- oracle that Lua path is tested against. This file is the other half of that
-- format and nothing else: bytes in, tables out. What the tables MEAN is
-- StadiumRig's business (posing a skeleton) and StadiumMon's (which animation
-- a fight is asking for).
--
-- Three things shape it.
--
-- BINARY, NOT LUA. A species is a couple of hundred kilobytes of numbers,
-- most of it animation, and a Lua source file of that is a parse the loader
-- would pay for on every boot whether a battle happened or not. A byte
-- string is read once, on the frame a fight starts, and only for the two
-- species actually fighting.
--
-- LAZY ANIMATIONS. Geometry, bones and textures are decoded on load --
-- they are small, and every one of them is needed the moment the mon
-- appears. The animations are not: a fight uses idle, an entrance and
-- whichever handful of attacks come up, out of the seven to twenty-one a
-- species carries. So the load pass SCANS the animation block, recording
-- where each one starts and skipping the rest, and a track is decoded the
-- first time something plays it. That turns a 200 KB decode into a 20 KB
-- one plus a few milliseconds spread over the fight.
--
-- AN LRU OF FOUR. A model is shared by everything that draws that species
-- -- both sides of a mirror match, both VR eyes -- and kept for a few
-- battles after, because the next fight on the same route is very often
-- the same Pokemon. Four is enough for a wild fight (two) plus the
-- trainer's next two, and it bounds what the mode can hold to a few
-- megabytes.
--
-- Everything is pcall-guarded and every failure answers nil: a missing
-- pack, a truncated file or a driver that will not make an image all end
-- at the same place, which is the flat 2D-3D card this mode falls back to
-- (see Stadium).

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local StadiumPack = {}

local byte = string.byte
local floor = math.floor

-- ------- where a pack comes from
--
-- Two places, asked in this order.
--
-- CACHE_DIR is in the save directory and is what actually ships: the mod
-- carries no models (they are Pokemon Stadium's data), so StadiumInstall
-- builds them out of the player's own ROM on first run and writes them here.
--
-- DIR is inside the mod, and exists for a developer checkout that has run
-- tools/stadium_pack.py -- which is also how the oracle the Lua extractor is
-- tested against gets built. It is second because a locally built CURRENT
-- cache should win over whatever a checkout happens to have lying around --
-- current as judged by StadiumInstall's marker, so a cache an old extractor
-- built does not shadow a fresh set (see readPack).
StadiumPack.CACHE_DIR = "dramatic_shape/stadium"
StadiumPack.DIR = "assets/stadium"

local function readPack(species)
  -- The cache only counts when StadiumInstall's marker says it is a
  -- complete, CURRENT build -- an old cache (a rev the extractor has since
  -- fixed, a format that moved) must not shadow a fresh shipped set, and a
  -- half-written folder must not be read at all. Required lazily: Install
  -- requires this module at load, so the reverse edge cannot be taken then.
  local rel = ("%s/%03d.dsm"):format(StadiumPack.CACHE_DIR, species)
  if love and love.filesystem and love.filesystem.getInfo
     and V.require("StadiumInstall").ready() then
    local okInfo, info = pcall(love.filesystem.getInfo, rel, "file")
    if okInfo and info then
      local ok, bytes = pcall(love.filesystem.read, rel)
      if ok and type(bytes) == "string" and #bytes > 4 then return bytes end
    end
  end
  local mod = V.mod
  if not (mod and mod.read) then return nil end
  local ok, bytes = pcall(mod.read, mod,
                          ("%s/%03d.dsm"):format(StadiumPack.DIR, species))
  if ok and type(bytes) == "string" and #bytes > 4 then return bytes end
  return nil
end

-- The battle system's context slots, in the order tools/stadium_pack.py
-- writes them -- slot 165 upward (see model_extract/manifest.json's
-- animationSlots). Indexed by POSITION, so this list is the format's
-- contract and the packer's CONTEXTS must stay identical to it.
-- Position 2 was called "hit" until the move table was read against it: it
-- is the animation most of a species' MOVES play, which makes it the default
-- attack and not a damage reaction (see StadiumMon's STATES). The slot TABLE
-- is indexed by position, but the name also reaches the packed files: the
-- packers bake it into the animation NAME strings, so it has to match
-- tools/stadium_pack.py's CONTEXTS *and* pipeline/battle.py's CONTEXT_SLOTS,
-- or the oracle diff reports every species.
StadiumPack.CONTEXT = {
  "idle", "attack_default", "faint", "entrance", "reaction_169", "reaction_170",
  "reaction_171", "reaction_172", "reaction_173", "reaction_174",
  "struggle", "idle_alt", "faint_alt", "flinch", "reaction_179",
  "reaction_180", "reaction_181", "reaction_182", "entrance_alt",
  "idle_return",
}

-- name -> slot position, for callers that ask by name
StadiumPack.SLOT = {}
for i, name in ipairs(StadiumPack.CONTEXT) do StadiumPack.SLOT[name] = i end

StadiumPack.N_MOVES = 165
StadiumPack.NONE = 0xFFFF

-- The frame rate every animation in the set is authored at
-- (model_extract/README.md: keyframe times are frame / 30).
StadiumPack.FPS = 30

-- ------- readers
--
-- One cursor threaded through by hand rather than an object: this runs over
-- a couple of hundred thousand values on the frame a battle starts, and a
-- method call per value is the difference between a hitch and no hitch.

local function u8(s, p) return byte(s, p), p + 1 end

local function u16(s, p)
  local a, b = byte(s, p, p + 1)
  return a + b * 256, p + 2
end

local function i16(s, p)
  local a, b = byte(s, p, p + 1)
  local v = a + b * 256
  if v >= 32768 then v = v - 65536 end
  return v, p + 2
end

local function u32(s, p)
  local a, b, c, d = byte(s, p, p + 3)
  return a + b * 256 + c * 65536 + d * 16777216, p + 4
end

local function i32(s, p)
  local v
  v, p = u32(s, p)
  if v >= 2147483648 then v = v - 4294967296 end
  return v, p
end

-- IEEE 754 single, by hand. LOVE has love.data.unpack, but this file reads
-- exactly four floats per model (the header's extents) and a hand decode
-- costs nothing while removing a version floor from the mod's whole
-- STADIUM path.
local function f32(s, p)
  local b1, b2, b3, b4 = byte(s, p, p + 3)
  local sign = 1
  if b4 >= 128 then sign, b4 = -1, b4 - 128 end
  local expo = b4 * 2 + floor(b3 / 128)
  local mant = (b3 % 128) * 65536 + b2 * 256 + b1
  if expo == 255 then
    if mant == 0 then return sign * math.huge, p + 4 end
    return 0, p + 4
  end
  if expo == 0 then return sign * mant * 2 ^ -149, p + 4 end
  return sign * (1 + mant / 8388608) * 2 ^ (expo - 127), p + 4
end

-- 16.16 fixed point, which is how bone scales are stored (they run from
-- about -31 to 100 across the set and a float would cost twice the bytes
-- for precision nothing can see).
local function fixed(s, p)
  local v
  v, p = i32(s, p)
  return v / 65536, p
end

-- ------- the load

local function readHeader(s, p, model)
  model.species, p = u16(s, p)
  model.boneCount, p = u16(s, p)
  model.primCount, p = u16(s, p)
  model.texCount, p = u16(s, p)
  model.animCount, p = u16(s, p)
  model.auxCount, p = u16(s, p)
  model.rootScale, p = f32(s, p)
  -- a species whose standby loop is corrupt in the source extraction, and
  -- which the mod therefore holds at its bind pose (see the packer's
  -- idle_is_broken). Three of the 151.
  local static
  static, p = u8(s, p)
  model.staticPose = static ~= 0
  model.height, p = f32(s, p)
  model.floor, p = f32(s, p)
  model.radius, p = f32(s, p)

  local moveAnim, moveAux, ctx = {}, {}, {}
  for i = 1, StadiumPack.N_MOVES do moveAnim[i], p = u16(s, p) end
  for i = 1, StadiumPack.N_MOVES do moveAux[i], p = i16(s, p) end
  for i = 1, #StadiumPack.CONTEXT do ctx[i], p = u16(s, p) end
  model.moveAnim, model.moveAux, model.ctx = moveAnim, moveAux, ctx
  return p
end

-- The bone tree, as flat parallel arrays: a rig walk touches every bone
-- every frame and an array of little tables would be a cache miss per bone
-- and a table per bone to collect.
local function readBones(s, p, model)
  local n = model.boneCount
  local parent, t, r, sc = {}, {}, {}, {}
  for i = 1, n do
    -- 0-based in the file, 1-based here, and 0 for "no parent" so the rig's
    -- walk can test it without a sentinel comparison
    local par
    par, p = i16(s, p)
    parent[i] = par + 1
    local b = (i - 1) * 3
    t[b + 1], p = i16(s, p)
    t[b + 2], p = i16(s, p)
    t[b + 3], p = i16(s, p)
    r[b + 1], p = i16(s, p)
    r[b + 2], p = i16(s, p)
    r[b + 3], p = i16(s, p)
    sc[b + 1], p = fixed(s, p)
    sc[b + 2], p = fixed(s, p)
    sc[b + 3], p = fixed(s, p)
  end
  model.parent, model.restT, model.restR, model.restS = parent, t, r, sc
  return p
end

-- One drawable piece: the triangles that share a texture and a cull mode.
--
-- Positions and normals stay in BONE-LOCAL space, exactly as the display
-- list had them, because that is what makes the skinning a single matrix
-- multiply per vertex (every vertex in the set is rigidly bound to one bone
-- -- see model_extract/README.md) rather than a weighted blend.
local function readPrims(s, p, model)
  local prims = {}
  for i = 1, model.primCount do
    local prim = {}
    prim.tex, p = u16(s, p)
    prim.tex = prim.tex + 1
    local cull, blend
    cull, p = u8(s, p)
    blend, p = u8(s, p)
    prim.cull = cull ~= 0
    prim.additive = blend ~= 0
    prim.texAnim, p = i16(s, p)

    -- the texture-animation channel's value -> which texture to swap in.
    -- Keyed by the stream's own byte, so the rig can look one up without
    -- searching.
    local mapN
    mapN, p = u8(s, p)
    if mapN > 0 then
      local map = {}
      for _ = 1, mapN do
        local key, tex
        key, p = u8(s, p)
        tex, p = u16(s, p)
        map[key] = tex + 1
      end
      prim.texMap = map
    end

    local fxN
    fxN, p = u16(s, p)
    if fxN > 0 then
      local frames = {}
      for k = 1, fxN do
        frames[k], p = u16(s, p)
        frames[k] = frames[k] + 1
      end
      prim.fxFrames = frames
    end

    local nv, ni
    nv, p = u16(s, p)
    ni, p = u16(s, p)
    prim.vertCount, prim.indexCount = nv, ni

    -- five arrays rather than one array of vertices, for the same reason
    -- the bones are flat: the skinning loop reads them in step and writes
    -- one LOVE vertex row out
    local px, py, pz = {}, {}, {}
    local uv = {}
    local nx, ny, nz = {}, {}, {}
    local bone = {}
    for k = 1, nv do
      px[k], p = i16(s, p)
      py[k], p = i16(s, p)
      pz[k], p = i16(s, p)
      local u, v
      u, p = i16(s, p)
      v, p = i16(s, p)
      uv[k * 2 - 1], uv[k * 2] = u / 512, v / 512
      local a, b, c
      a, p = u8(s, p)
      b, p = u8(s, p)
      c, p = u8(s, p)
      if a >= 128 then a = a - 256 end
      if b >= 128 then b = b - 256 end
      if c >= 128 then c = c - 256 end
      nx[k], ny[k], nz[k] = a / 127, b / 127, c / 127
      bone[k], p = u8(s, p)
      bone[k] = bone[k] + 1
    end
    prim.px, prim.py, prim.pz = px, py, pz
    prim.uv = uv
    prim.nx, prim.ny, prim.nz = nx, ny, nz
    prim.bone = bone

    local idx = {}
    for k = 1, ni do
      idx[k], p = u16(s, p)
      idx[k] = idx[k] + 1
    end
    prim.index = idx
    prims[i] = prim
  end
  model.prims = prims
  return p
end

-- The textures, kept as the raw RGBA8 they arrived as and turned into
-- images on first use. A species carries every frame of every blink and
-- every dizzy swirl; a fight that never shows one should not pay to
-- upload it.
--
-- Raw rather than PNG, which is what DSM3 changed: an ImageData over these
-- bytes is a memcpy where a PNG is a decode on the frame a battle starts,
-- and -- the reason it was actually done -- uncompressed pixels are the same
-- pixels whichever side wrote them, so the Lua extractor's output can be
-- diffed against the Python packer's byte for byte. Two deflate
-- implementations need not agree; two arrays of pixels do.
local function readTextures(s, p, model)
  local tex = {}
  for i = 1, model.texCount do
    local w, h, len
    w, p = u16(s, p)
    h, p = u16(s, p)
    len, p = u32(s, p)
    tex[i] = { w = w, h = h, rgba = s:sub(p, p + len - 1) }
    p = p + len
  end
  model.textures = tex
  return p
end

-- How many bytes one animation's track block occupies, without decoding
-- any of it. This is the scan that makes lazy animations possible: nine
-- components a bone, each either one value or one a frame, and the only
-- thing that has to be READ is the byte that says which.
local COMP_BYTES = { 2, 2, 2, 2, 2, 2, 4, 4, 4 }   -- t t t r r r s s s

local function skipTracks(s, p, boneCount, frames)
  for _ = 1, boneCount do
    local present
    present, p = u8(s, p)
    if present ~= 0 then
      for c = 1, 9 do
        local kind
        kind, p = u8(s, p)
        p = p + COMP_BYTES[c] * (kind == 0 and 1 or frames)
      end
    end
  end
  return p
end

local function readAnims(s, p, model)
  local anims = {}
  for i = 1, model.animCount do
    local len
    len, p = u8(s, p)
    local name = s:sub(p, p + len - 1)
    p = p + len
    local frames, loopStart, aux
    frames, p = u16(s, p)
    loopStart, p = u16(s, p)
    aux, p = i16(s, p)
    anims[i] = {
      name = name, frames = frames, loopStart = loopStart,
      aux = aux >= 0 and (aux + 1) or nil,
      seconds = frames / StadiumPack.FPS,
      offset = p,                    -- where its tracks start; decoded later
    }
    p = skipTracks(s, p, model.boneCount, frames)
  end
  model.anims = anims
  return p
end

local function readAux(s, p, model)
  local aux = {}
  for i = 1, model.auxCount do
    local frames, loopStart, chanN
    frames, p = u16(s, p)
    loopStart, p = u16(s, p)
    chanN, p = u16(s, p)
    local chans = {}
    for c = 1, chanN do
      local n
      n, p = u16(s, p)
      local stream = {}
      for k = 1, n do stream[k], p = u16(s, p) end
      chans[c] = stream
    end
    aux[i] = { frames = frames, loopStart = loopStart, channels = chans }
  end
  model.auxAnims = aux
  return p
end

-- ------- a track block, decoded on demand
--
-- The shape a pose walk wants: `tracks[bone]` is either nil (this bone
-- holds its rest transform for the whole animation) or nine entries, each
-- either a number (constant) or an array of one value per frame.
--
-- That fold is the source data's own, not something imposed here: a bone
-- that only rotates costs two bytes for each of its six other components,
-- and across the 151 species it is most of the reason the whole set is 24
-- megabytes rather than a hundred.
function StadiumPack.tracks(model, index)
  local anim = model.anims and model.anims[index]
  if not anim then return nil end
  if anim.tracks then return anim.tracks end
  local s, p = model.bytes, anim.offset
  if not (s and p) then return nil end
  local frames = anim.frames
  local out = {}
  for b = 1, model.boneCount do
    local present
    present, p = u8(s, p)
    if present ~= 0 then
      local comps = {}
      for c = 1, 9 do
        local kind
        kind, p = u8(s, p)
        local read = (c >= 7) and fixed or i16
        if kind == 0 then
          comps[c], p = read(s, p)
        else
          local arr = {}
          for k = 1, frames do arr[k], p = read(s, p) end
          comps[c] = arr
        end
      end
      out[b] = comps
    end
  end
  anim.tracks = out
  return out
end

-- One texture as a LOVE image, decoded on first ask.
function StadiumPack.image(model, index)
  local slot = model.textures and model.textures[index]
  if not slot then return nil end
  if slot.image ~= nil then return slot.image or nil end
  local ok, img = pcall(function()
    local data = love.image.newImageData(slot.w, slot.h, "rgba8", slot.rgba)
    local image = love.graphics.newImage(data)
    -- N64 art at N64 resolution: nearest keeps the texels the size the
    -- artist drew them, exactly as every other texture in this mode
    image:setFilter("nearest", "nearest")
    return image
  end)
  slot.image = (ok and img) or false
  return slot.image or nil
end

-- ------- the cache

local cache = {}          -- species -> model
local order = {}          -- species, least recently used first
StadiumPack.KEEP = 4

local function touch(species)
  for i = #order, 1, -1 do
    if order[i] == species then table.remove(order, i) end
  end
  order[#order + 1] = species
  while #order > StadiumPack.KEEP do
    local drop = table.remove(order, 1)
    local model = cache[drop]
    cache[drop] = nil
    if model and model.textures then
      for _, slot in ipairs(model.textures) do
        if slot.image and slot.image.release then
          pcall(slot.image.release, slot.image)
        end
        -- CLEARED, not just released. A released Image is still a truthy
        -- value, and `image()` below hands back whatever is in this field
        -- without looking at it -- so leaving the corpse here meant the next
        -- ask returned a dead object, which reached mesh:setTexture and threw
        -- "Cannot use object after it has been released" from inside the
        -- scene pass. Nil means the next ask decodes it again, which is the
        -- whole point of the slot being lazy.
        slot.image = nil
      end
    end
  end
end

-- Say that this species is IN USE, so the cache does not evict it.
--
-- The eviction order above is a least-recently-LOADED list, not a
-- least-recently-used one: `touch` runs from `load`, and `load` is only
-- reached when a side's species CHANGES (StadiumMon.setSpecies returns early
-- otherwise). A Pokemon that stands on the field for several turns therefore
-- never refreshes its position, drifts to the front of the queue, and is
-- evicted -- its textures released -- while it is still being drawn sixty
-- times a second. That is what a fifth species entering a battle did: call
-- out a Clefairy and whatever had been standing longest lost its textures
-- mid-fight.
--
-- So the mode says, every frame, which two species are actually standing
-- there (see Stadium.update). With KEEP at 4 and two sides, the two in use
-- are always the two most recent and cannot reach the front of the queue.
function StadiumPack.keep(species)
  if species and cache[species] then touch(species) end
end

-- Whether a pack for this species is on disk at all. Cheap enough to ask
-- before a battle commits to the mode, and the honest test: a mod
-- installed without its assets folder must decline rather than error.
function StadiumPack.available(species)
  if cache[species] then return true end
  return readPack(species) ~= nil
end

-- The model for a National Dex number (1..151), or nil.
function StadiumPack.load(species)
  if not (species and species >= 1 and species <= 151) then return nil end
  local hit = cache[species]
  if hit ~= nil then
    touch(species)
    return hit or nil
  end

  local bytes = readPack(species)
  if not bytes then
    cache[species] = false
    return nil
  end

  local ok, model = pcall(function()
    if bytes:sub(1, 4) ~= "DSM3" then
      error("not a DSM3 pack -- delete it and let the mod rebuild it", 0)
    end
    local m = { bytes = bytes }
    local p = 5
    p = readHeader(bytes, p, m)
    p = readBones(bytes, p, m)
    p = readPrims(bytes, p, m)
    p = readTextures(bytes, p, m)
    p = readAnims(bytes, p, m)
    readAux(bytes, p, m)
    return m
  end)
  if not ok then
    V.mod.log:warn("stadium: %03d.dsm did not read: %s -- that Pokemon "
                   .. "falls back to its flat pic", species, tostring(model))
    cache[species] = false
    return nil
  end

  cache[species] = model
  touch(species)
  return model
end

-- Drop everything (hot reload, or a graphics context that went away).
function StadiumPack.invalidate()
  for _, model in pairs(cache) do
    if model and model.textures then
      for _, slot in ipairs(model.textures) do
        if slot.image and slot.image.release then
          pcall(slot.image.release, slot.image)
        end
        slot.image = nil
      end
    end
  end
end

function StadiumPack.forget()
  StadiumPack.invalidate()
  cache, order = {}, {}
end

return StadiumPack
