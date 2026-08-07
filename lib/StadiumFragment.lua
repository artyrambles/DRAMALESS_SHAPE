-- STADIUM battles: one FRAGMENT module -> geometry, textures, skeleton,
-- animations.
--
-- A port of model_extract/pipeline/fragment.py, structure for structure and
-- name for name, so the two can be read side by side and diffed. The Python
-- is the reference implementation and stays the ORACLE:
-- tools/stadium_pack.py drives it over the same ROM and
-- tests/stadium_extract_test.lua requires the finished .dsm files to agree
-- byte for byte. That is the only way a port of this much numeric code can
-- be trusted -- reading it twice is not enough.
--
-- ------- the three things it does
--
-- THE GEO LAYOUT is a little bytecode: a tree of nodes with an open/close
-- stack, where some nodes are bones, some set the current material, and some
-- hand a display list to whichever bone is live. Walking it builds the
-- skeleton and decides which triangles belong to which bone.
--
-- THE DISPLAY LISTS are F3DEX2, the N64's own graphics microcode. Only four
-- of its commands matter here -- load vertices, draw triangle(s), set the
-- geometry mode (which carries the cull bits), call/branch -- because
-- everything else is render state this rebuilds from the texture table
-- instead.
--
-- THE ANIMATIONS are packed per-frame streams of 12- or 16-bit fields for
-- 146 of the 151 species. The other five -- Pidgeot, Dodrio, Exeggutor,
-- Tangela and Magmar -- use the game's hermite-keyframe mode (flags & 8),
-- some for every animation, some for a subset.
--
-- ------- arithmetic, and why there are no bit operations here
--
-- Every shift and mask is written as multiply/divide/modulo. Two reasons.
-- LuaJIT's `bit` library works on SIGNED 32-bit integers, so every value that
-- crosses 0x80000000 -- which pointers in this file constantly do -- would
-- need a conversion back, and each of those is a place to be wrong. And the
-- one shift that genuinely needs care (`bitfield` below) has to be exact to
-- 32 bits, which a double can do only if the value is reduced BEFORE it is
-- shifted up. Doing it in arithmetic makes that reduction visible instead of
-- hiding it behind an operator that silently truncates.

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local StadiumFragment = {}

local byte = string.byte
local char = string.char
local sub = string.sub
local concat = table.concat
local floor = math.floor

-- Where the module is linked to run. Every pointer inside it is an address in
-- that space, so subtracting this turns one into a file offset.
local BASE = 0x8FF00000

-- Size of each geo-layout command, by opcode. A command this does not
-- understand is still stepped over correctly, which is what lets an unknown
-- one be a warning rather than the end of the walk.
local CMD_SIZES = {
  [0x00] = 0x08, [0x01] = 0x04, [0x02] = 0x08, [0x03] = 0x08, [0x04] = 0x04,
  [0x05] = 0x04, [0x06] = 0x04, [0x07] = 0x08, [0x08] = 0x0C, [0x09] = 0x04,
  [0x0A] = 0x08, [0x0B] = 0x18, [0x0C] = 0x04, [0x0D] = 0x04, [0x0E] = 0x04,
  [0x0F] = 0x04, [0x10] = 0x04, [0x11] = 0x04, [0x12] = 0x04, [0x13] = 0x08,
  [0x14] = 0x0C, [0x15] = 0x0C, [0x16] = 0x04, [0x17] = 0x14, [0x18] = 0x08,
  [0x19] = 0x08, [0x1A] = 0x04, [0x1B] = 0x10, [0x1C] = 0x10, [0x1D] = 0x1C,
  [0x1E] = 0x08, [0x1F] = 0x18, [0x20] = 0x14, [0x21] = 0x10, [0x22] = 0x08,
  [0x23] = 0x10, [0x24] = 0x04, [0x25] = 0x04, [0x26] = 0x14,
}

StadiumFragment.CMD_SIZES = CMD_SIZES

-- ------- rounding
--
-- Python rounds half to EVEN, and the packer's numbers go through `round`
-- three times over (fold a track to a constant, quantise a scale to 16.16,
-- quantise a UV to 1/512). Rounding half away from zero instead would put
-- this one off by one wherever a value lands exactly on a boundary, and a
-- single byte is all it takes for the oracle diff to fail -- so it is worth
-- the six lines to do it the same way.

local function roundHalfEven(x)
  local f = floor(x)
  local d = x - f
  if d > 0.5 then return f + 1 end
  if d < 0.5 then return f end
  if f % 2 == 0 then return f end
  return f + 1
end

-- Python's round(x, nd). Multiplying by 10^nd first is WRONG: the multiply
-- itself rounds, and a value just under a decimal boundary can land exactly
-- on it -- Magmar's attack scale track holds 1.008874999..., whose *1e5 is
-- exactly 100887.5, and the fold then differed from the oracle by one bit.
-- Python rounds the EXACT binary expansion, and so does LuaJIT's own float
-- formatter, so the digits come from string.format instead.
local function roundTo(x, nd)
  if nd == 0 then return roundHalfEven(x) end
  if x ~= x or x == math.huge or x == -math.huge then return x end
  -- A true decimal tie -- the exact expansion terminating one digit past nd
  -- with a 5 -- only a dyadic value can produce, and its zeros then run out
  -- forever; any other double shows a nonzero digit within ~18 places. The
  -- formatter rounds such a tie away from zero where Python rounds it to
  -- even, so it is the one case the digits cannot settle.
  local s = string.format("%." .. (nd + 24) .. "f", x)
  local dot = s:find(".", 1, true)
  local tail = s:sub(dot + nd + 1)
  if not tail:match("^50*$") then
    return tonumber(string.format("%." .. nd .. "f", x))
  end
  local head = s:sub(1, dot + nd)         -- sign, integer part, nd digits
  local last = head:byte(-1) - 48
  if last % 2 == 0 then return tonumber(head) end
  -- an odd digit bumps to even with no carry
  return tonumber(head:sub(1, -2) .. string.char(head:byte(-1) + 1))
end

StadiumFragment.roundHalfEven = roundHalfEven
StadiumFragment.roundTo = roundTo

-- Two's-complement reading of an n-bit field.
local function signed(v, bits)
  local m = 2 ^ (bits - 1)
  if v >= m then return v - m * 2 end
  return v
end

StadiumFragment.signed = signed

-- The distinct values of an array, in the order they first appear. The Python
-- reached for a set here and that decided the order textures were registered
-- in -- see fragment.py's own `unique`.
local function unique(seq, n)
  local seen, out, m = {}, {}, 0
  for i = 1, n or #seq do
    local v = seq[i]
    if v ~= nil and not seen[v] then
      seen[v] = true
      m = m + 1
      out[m] = v
    end
  end
  return out, m
end

-- ------- the module

local Frag = {}
Frag.__index = Frag

function Frag:u8(o)
  return byte(self.d, o + 1)
end

function Frag:s8(o)
  local v = byte(self.d, o + 1)
  if v >= 128 then return v - 256 end
  return v
end

function Frag:u16(o)
  local a, b = byte(self.d, o + 1, o + 2)
  return a * 256 + b
end

function Frag:s16(o)
  local a, b = byte(self.d, o + 1, o + 2)
  local v = a * 256 + b
  if v >= 32768 then return v - 65536 end
  return v
end

function Frag:u32(o)
  local a, b, c, d = byte(self.d, o + 1, o + 4)
  return ((a * 256 + b) * 256 + c) * 256 + d
end

function Frag:s32(o)
  local v = self:u32(o)
  if v >= 2147483648 then return v - 4294967296 end
  return v
end

-- A pointer as a file offset, or nil for the null pointer.
function Frag:off(ptr)
  if ptr == 0 then return nil end
  return ptr - BASE
end

function Frag:ptr(o)
  return self:off(self:u32(o))
end

-- The entry stub ends with `lui rX, hi; addiu rX, rX, lo`, which is MIPS for
-- "load the address of the root struct". Finding that pair is how the root is
-- located without a symbol table.
function Frag:root()
  for o = 0x20, 0x7C, 4 do
    local w = self:u32(o)
    if floor(w / 0x4000000) == 0x0F then              -- lui
      local reg = floor(w / 0x10000) % 0x20
      local w2 = self:u32(o + 4)
      if floor(w2 / 0x4000000) == 0x09                -- addiu rX, rX, imm
          and floor(w2 / 0x200000) % 0x20 == reg then
        return self:u16(o + 2) * 65536 + self:s16(o + 6) - BASE
      end
    end
  end
  return nil
end

-- A null-terminated run of pointers.
function Frag:ptrList(o)
  local out, n = {}, 0
  while true do
    local p = self:ptr(o)
    if p == nil then return out, n end
    n = n + 1
    out[n] = p
    o = o + 4
  end
end

-- `data` is one decompressed archive entry.
function StadiumFragment.open(data, name)
  if type(data) ~= "string" or #data < 0x20 then
    return nil, (name or "?") .. ": too short to be a module"
  end
  if sub(data, 9, 16) ~= "FRAGMENT" then
    return nil, (name or "?") .. ": not a FRAGMENT module"
  end
  return setmetatable({ d = data, name = name or "<bytes>" }, Frag)
end

-- ------- walking the geo layout and running the display lists

local Model = {}
Model.__index = Model

local function newModel(frag)
  local r = frag:root()
  if not r then return nil, frag.name .. ": could not locate root struct" end
  local geo = frag:ptr(r + 0x08)
  local anims = frag:ptr(r + 0x0C)
  local aux = frag:ptr(r + 0x10)
  local m = setmetatable({
    f = frag,
    species = frag:u16(r),
    geoLayouts = geo and frag:ptrList(geo) or {},
    anims = anims and frag:ptrList(anims) or {},
    auxAnims = aux and frag:ptrList(aux) or {},
    textures = {},          -- { fmt, siz, w, h, texels, data }
    tluts = {},             -- palettes: { count, data, dl }
    bones = {},             -- { parent, boneId, flags, chan, t, r, s }
    boneById = {},
    prims = {},             -- { tex, tlut, mat, texAnim, cull, verts, tris }
    primsByKey = {},
    rootScale = { 1.0, 1.0, 1.0 },
    fx = {},                -- geo cmd 0x08 procedural effect nodes
    warnings = {},
  }, Model)
  return m
end

function Model:readTextureTable(off, count)
  local f = self.f
  local t = self.textures
  for i = 0, count - 1 do
    local o = off + i * 0xC
    t[#t + 1] = {
      fmt = f:u8(o), siz = f:u8(o + 1), w = f:s16(o + 2),
      h = f:u16(o + 4), texels = f:u16(o + 6), data = f:ptr(o + 8),
    }
  end
end

-- Palettes reuse the texture-record layout: the count sits in the width
-- field, the palette data in the next word, and unk_08 is the display list
-- that loads it (src/12D80.c func_80015B20). The list is authoritative, so it
-- is run rather than trusted.
function Model:readTlutTable(off, count)
  local f = self.f
  for i = 0, count - 1 do
    local o = off + i * 0xC
    local rec = { count = f:u16(o + 2), data = f:ptr(o + 4), dl = f:ptr(o + 8) }
    local dl = rec.dl
    if dl ~= nil then
      for _ = 1, 16 do
        local w0, w1 = f:u32(dl), f:u32(dl + 4)
        local op = floor(w0 / 0x1000000)
        if op == 0xFD then                            -- G_SETTIMG
          rec.data = f:off(w1)
        elseif op == 0xF0 then                        -- G_LOADTLUT
          rec.count = floor(w1 / 0x4000) % 0x400 + 1
        elseif op == 0xDF then
          break
        end
        dl = dl + 8
      end
    end
    self.tluts[#self.tluts + 1] = rec
  end
end

-- The bone whose matrix is live. Mirrors gCurGraphNodeList in
-- src/geo_layout.c: the top of the stack is the slot the NEXT node command
-- writes to, so the node that owns the current one is the slot below
-- (func_80017AC4).
function Model:curBone()
  local n = #self.stack
  if n >= 2 then return self.stack[n - 1] end
  return -1
end

function Model:build()
  self.curTex = -1
  self.curTlut = -1
  self.curMat = nil
  self.curTexAnim = -1
  self.stack = { -1 }
  -- The RSP vertex cache persists ACROSS display lists: a bone's list often
  -- preloads vertices that the next bone's list then indexes, which is how
  -- these models get blended joints. Each slot remembers the bone whose
  -- matrix was current when it was loaded.
  self.vbuf = {}
  if not self.geoLayouts[1] then
    self.warnings[#self.warnings + 1] = "no geo layout"
    return
  end
  self:walk(self.geoLayouts[1], 0)
end

function Model:walk(o, depth)
  local f = self.f
  if depth > 32 or o == nil then return end
  while true do
    local cmd = f:u8(o)
    local size = CMD_SIZES[cmd]
    if size == nil then
      self.warnings[#self.warnings + 1] =
        ("unknown geo cmd 0x%02x at 0x%x"):format(cmd or -1, o)
      return
    end
    if cmd == 0x01 or cmd == 0x04 then                -- end / return
      return
    elseif cmd == 0x00 or cmd == 0x03 then            -- branch (with return)
      self:walk(f:ptr(o + 4), depth + 1)
    elseif cmd == 0x02 then                           -- jump (no return)
      o = f:ptr(o + 4)
      if o == nil then return end
      cmd = nil                                       -- skip the o = o + size
    elseif cmd == 0x05 then                           -- open node
      local n = #self.stack
      self.stack[n + 1] = self.stack[n]
    elseif cmd == 0x06 then                           -- close node
      self.stack[#self.stack] = nil
    elseif cmd == 0x17 then                           -- model header
      self:readTextureTable(f:ptr(o + 8), f:s16(o + 2))
      if f:ptr(o + 0xC) then
        self:readTlutTable(f:ptr(o + 0xC), f:s16(o + 4))
      end
      self.vtxBase = f:ptr(o + 0x10)
      self.nVerts = f:s16(o + 6)
    elseif cmd == 0x08 then                           -- effect callback
      self.fx[#self.fx + 1] = { bone = self:curBone(), callback = f:u32(o + 4),
                                arg = f:ptr(o + 8) }
    elseif cmd == 0x1C then                           -- uniform scale node
      self.rootScale = { f:s32(o + 4) / 65536.0, f:s32(o + 8) / 65536.0,
                         f:s32(o + 0xC) / 65536.0 }
    elseif cmd == 0x1D then                           -- bone / joint node
      local idx = #self.bones                         -- 0-based, as the file
      self.bones[idx + 1] = {
        parent = self:curBone(), boneId = f:u8(o + 1), flags = f:u8(o + 2),
        chan = f:s8(o + 3),
        t = { f:s16(o + 4), f:s16(o + 6), f:s16(o + 8) },
        r = { f:s16(o + 0xA), f:s16(o + 0xC), f:s16(o + 0xE) },
        s = { f:s32(o + 0x10) / 65536.0, f:s32(o + 0x14) / 65536.0,
              f:s32(o + 0x18) / 65536.0 },
      }
      self.boneById[f:u8(o + 1)] = idx
      self.stack[#self.stack] = idx
    elseif cmd == 0x23 then                           -- set texture / material
      self.curTex = f:s16(o + 8)
      self.curTlut = f:s16(o + 0xA)
      self.curMat = f:ptr(o + 4)
      -- offset 0x02 is the texture-animation channel; -1 means static.
      -- func_800176DC swaps this material's texture per frame out of the
      -- auxiliary animation's stream.
      self.curTexAnim = f:s16(o + 2)
    elseif cmd == 0x22 then                           -- DL on current bone
      self:runDL(f:ptr(o + 4), self:curBone(), 0)
    elseif cmd == 0x1E then                           -- DL on named bone
      local named = self.boneById[f:s16(o + 2)]
      self:runDL(f:ptr(o + 4), named or self:curBone(), 0)
    elseif cmd == 0x20 or cmd == 0x21 then            -- DL + own transform
      self:runDL(f:ptr(o + (cmd == 0x20 and 0x10 or 0xC)), self:curBone(), 0)
    end
    if cmd ~= nil then o = o + size end
  end
end

function Model:primFor(tex, tlut, mat, texAnim, cull)
  local key = tex .. "," .. tlut .. "," .. tostring(mat) .. ","
              .. texAnim .. "," .. cull
  local p = self.primsByKey[key]
  if p == nil then
    p = { tex = tex, tlut = tlut, mat = mat, texAnim = texAnim, cull = cull,
          verts = {}, nverts = 0, tris = {}, ntris = 0, remap = {} }
    self.primsByKey[key] = p
    self.prims[#self.prims + 1] = p
  end
  return p
end

-- Bitwise AND and OR over the low `bits` bits, in arithmetic. See the module
-- header for why there is no `bit` library in here.
local function band(a, b, bits)
  local r, p = 0, 1
  for _ = 1, bits do
    if a % 2 == 1 and b % 2 == 1 then r = r + p end
    a, b, p = floor(a / 2), floor(b / 2), p * 2
  end
  return r
end

local function bor(a, b, bits)
  local r, p = 0, 1
  for _ = 1, bits do
    if a % 2 == 1 or b % 2 == 1 then r = r + p end
    a, b, p = floor(a / 2), floor(b / 2), p * 2
  end
  return r
end

-- One triangle out of the vertex cache and into a prim, deduplicating
-- vertices as it goes.
--
-- A file-level function rather than a closure inside runDL: it is called
-- once per triangle -- some two hundred thousand times over the set -- and a
-- closure there would allocate one per display-list command.
--
-- A triangle naming a cache slot that was never loaded is DROPPED, not
-- faulted. That happens where a display list indexes past what its own G_VTX
-- filled, which the hardware would read as stale cache; there is nothing
-- meaningful to draw.
--
-- It is abandoned MID-TRIANGLE, exactly where the missing corner is found,
-- and the corners already walked keep the slots they were just given in the
-- vertex list. That looks like a detail and is not: those vertices stay in
-- the prim, so they shift every later vertex's index by one. Checking all
-- three corners up front instead -- which is what a careful reader writes --
-- silently produces a different, equally plausible vertex list, and every
-- index in the file after that point moves.
local function emit(prim, vbuf, flip, ia, ib, ic)
  local remap, verts = prim.remap, prim.verts
  local tri = { 0, 0, 0 }
  for k = 1, 3 do
    local v = vbuf[k == 1 and ia or (k == 2 and ib or ic)]
    if v == nil then return end
    local key = v[1] .. "," .. v[2] .. "," .. v[3] .. "," .. v[4] .. ","
                .. v[5] .. "," .. v[6] .. "," .. v[7] .. "," .. v[8]
                .. "," .. v[9] .. "," .. v[10]
    local j = remap[key]
    if j == nil then
      j = prim.nverts                                 -- 0-based, as the file
      remap[key] = j
      prim.nverts = j + 1
      verts[j + 1] = v
    end
    tri[k] = j
  end
  if flip then tri[1], tri[3] = tri[3], tri[1] end
  prim.ntris = prim.ntris + 1
  prim.tris[prim.ntris] = tri
end

function Model:runDL(o, bone, depth)
  if o == nil or depth > 8 then return end
  local f = self.f
  local vbuf = self.vbuf
  local cull = 0x400
  while true do
    local w0, w1 = f:u32(o), f:u32(o + 4)
    local op = floor(w0 / 0x1000000)
    o = o + 8
    if op == 0xDF then                                -- G_ENDDL
      return
    elseif op == 0xDE then                            -- G_DL
      self:runDL(f:off(w1), bone, depth + 1)
      if floor(w0 / 0x10000) % 256 ~= 0 then          -- branch, not call
        return
      end
    elseif op == 0x01 then                            -- G_VTX
      local n = floor(w0 / 0x1000) % 256
      local v0 = floor((w0 % 0x1000) / 2) - n
      local a = f:off(w1)
      if a then
        for i = 0, n - 1 do
          local p = a + i * 0x10
          local slot = v0 + i
          if slot >= 0 and slot < 64 then
            -- s and t are S10.5 and kept RAW here; the /32 happens once, on
            -- the way out, so that the dedup key below compares integers
            vbuf[slot] = { f:s16(p), f:s16(p + 2), f:s16(p + 4),
                           f:s16(p + 8), f:s16(p + 10),
                           f:s8(p + 12), f:s8(p + 13), f:s8(p + 14),
                           f:u8(p + 15), bone }
          end
        end
      end
    elseif op == 0xD9 then                            -- G_GEOMETRYMODE
      -- `cull = (cull & (w0 & 0xFFFFFF)) | w1`.
      --
      -- Only bits 9 and 10 -- G_CULL_FRONT and G_CULL_BACK -- are ever read
      -- out of this, so the whole word is kept to eleven bits and the AND and
      -- OR done over those. Bits above that cannot influence bits 9 and 10
      -- under either operator, so nothing is lost and the two loops that used
      -- to run 24 times each now run 11.
      cull = bor(band(cull, w0 % 0x800, 11), w1 % 0x800, 11)
    elseif op == 0x05 or op == 0x06 then              -- G_TRI1 / G_TRI2
      local prim = self:primFor(self.curTex, self.curTlut, self.curMat,
                                self.curTexAnim, cull % 0x800 - cull % 0x200)
      local flip = (floor(cull / 0x200) % 2 == 1)
                   and (floor(cull / 0x400) % 2 == 0)
      emit(prim, vbuf, flip,
           floor(floor(w0 / 0x10000) % 256 / 2),
           floor(floor(w0 / 0x100) % 256 / 2),
           floor(w0 % 256 / 2))
      if op == 0x06 then
        emit(prim, vbuf, flip,
             floor(floor(w1 / 0x10000) % 256 / 2),
             floor(floor(w1 / 0x100) % 256 / 2),
             floor(w1 % 256 / 2))
      end
    end
    -- everything else (SETTILE / sync / ...) is render state this rebuilds
    -- from the texture table instead, so it is skipped
  end
end

-- CI4 selects a 16-entry block of the palette through the render tile's
-- palette field; read it out of the material display list's last G_SETTILE.
function Model:tilePalette(mat)
  if mat == nil then return 0 end
  local f = self.f
  local pal = 0
  for _ = 1, 16 do
    local w0, w1 = f:u32(mat), f:u32(mat + 4)
    local op = floor(w0 / 0x1000000)
    if op == 0xF5 and floor(w1 / 0x1000000) % 8 == 0 then   -- render tile
      pal = floor(w1 / 0x100000) % 16
    elseif op == 0xDF then
      break
    end
    mat = mat + 8
  end
  return pal
end

-- ------- animations

-- src/F420.c func_80010500: a signed `bits`-wide field at bit index*bits.
--
-- C integer division truncates toward zero and Lua's floor() does not, which
-- only differs for a NEGATIVE index -- and a negative index is exactly what an
-- empty channel produces, so the truncating form is the one that matches the
-- hardware.
--
-- The shift is the part that needs care. `(v << rem) & 0xFFFFFFFF` on a
-- 32-bit v would want 63 bits of intermediate, and a double holds 53 exactly.
-- Masking FIRST -- dropping the bits the shift would push out anyway -- keeps
-- the product under 2^32 and therefore exact.
local function bitfield(f, base, index, bits)
  local bitpos = index * bits
  local word
  if bitpos >= 0 then
    word = floor(bitpos / 16)
  else
    word = -floor(-bitpos / 16)
  end
  local rem = bitpos - word * 16
  local o = base + word * 2
  local v = f:u16(o) * 65536 + f:u16(o + 2)
  local shift = rem % 32
  local keep = 2 ^ (32 - shift)
  v = (v % keep) * 2 ^ shift
  return signed(floor(v / 2 ^ (32 - bits)), bits)
end

StadiumFragment.bitfield = bitfield

local Anim = {}
Anim.__index = Anim

local function newAnim(frag, off)
  return setmetatable({
    f = frag, off = off,
    -- the u16 at +0: the flag bits live in its LOW byte, so a u8 read at +0
    -- gets the always-zero high byte and silently hides hermite mode
    flags      = frag:u16(off),
    startFrame = frag:u16(off + 4),
    loopStart  = frag:u16(off + 6),
    nChannels  = frag:u16(off + 8),
    nFrames    = frag:u16(off + 0xA),
    chanTable  = frag:ptr(off + 0xC),
    scaleData  = frag:ptr(off + 0x10),
    rotData    = frag:ptr(off + 0x14),
    transData  = frag:ptr(off + 0x18),
  }, Anim)
end

function Anim:chan(i)
  local o = self.chanTable + i * 0xA
  local f = self.f
  return { nScale = f:u8(o), nRot = f:u8(o + 1), nTrans = f:u8(o + 2),
           interp = f:u8(o + 3), oScale = f:u16(o + 4),
           oRot = f:u16(o + 6), oTrans = f:u16(o + 8) }
end

-- Packed per-frame streams (flags & 8 == 0).
--
-- A count of 0 means the component has no stream. In the ROM that only ever
-- happens in HERMITE animations, where a count under 2 means "the offset
-- field IS the constant value" -- no packed animation of any of the 151
-- species carries an empty channel, so the bind-pose fallback (the nil
-- return) is dead code kept as a safety net.
function Anim:transPacked(c, frame)
  if c.nTrans == 0 then return nil end
  local wide = floor(self.flags / 4) % 2 == 1
  local bits = wide and 16 or 12
  if c.nTrans == 1 then
    -- func_80016848 reads the u16 offset field back as a SIGNED constant
    if wide then return signed(c.oTrans, 16) + 0.0 end
    return floor(signed(c.oTrans * 16 % 65536, 16) / 16) + 0.0
  end
  local i = c.oTrans + (frame < c.nTrans - 1 and frame or c.nTrans - 1)
  return bitfield(self.f, self.transData, i, bits) + 0.0
end

function Anim:rotPacked(c, frame)
  if c.nRot == 0 then return nil end
  if c.nRot == 1 then return signed(c.oRot * 16 % 65536, 16) end
  local i = c.oRot + (frame < c.nRot - 1 and frame or c.nRot - 1)
  return signed(bitfield(self.f, self.rotData, i, 12) * 16 % 65536, 16)
end

function Anim:scalePacked(c, frame)
  if c.nScale == 0 then return nil end
  if c.nScale == 1 then return c.oScale / 1000.0 end
  local i = c.oScale + (frame < c.nScale - 1 and frame or c.nScale - 1)
  return self.f:s16(self.scaleData + i * 2) / 1000.0
end

-- Hermite keyframes (flags & 8): Pidgeot, Dodrio, Exeggutor, Tangela and
-- Magmar. src/17300.c func_80016934 (narrow, 6-byte keys) and func_80016B30
-- (wide, 8-byte keys with a separate out-tangent).
function Anim:hermite(base, n, frame, wide)
  local f = self.f
  local stride = wide and 8 or 6
  local function key(i)
    local o = base + i * stride
    return f:s16(o), f:s16(o + 2), f:s16(o + 4),
           wide and f:s16(o + 6) or f:s16(o + 4)
  end
  local k0t, k0v = key(0)
  if k0t >= frame then return k0v + 0.0 end
  local lt, lv = key(n - 1)
  if frame >= lt then return lv + 0.0 end
  local i = 0
  while i < n - 2 do
    if frame < (key(i + 1)) then break end
    i = i + 1
  end
  local at, av, ao, aw = key(i)
  local bt, bv, bo = key(i + 1)
  local x = (frame - at) / 30.0
  local y = 30.0 / (bt - at)
  local x2, x3 = x * x, x * x * x
  local y2, y3 = y * y, y * y * y
  return av * (2 * x3 * y3 - 3 * x2 * y2 + 1)
         + bv * (-2 * x3 * y3 + 3 * x2 * y2)
         + (wide and aw or ao) * (x3 * y2 - 2 * x2 * y + x)
         + bo * (x3 * y2 - x2 * y)
end

function Anim:transKey(c, frame)
  if c.nTrans < 2 then return signed(c.oTrans, 16) + 0.0 end
  return self:hermite(self.transData + c.oTrans * 2, c.nTrans, frame,
                      c.interp % 2 == 1)
end

function Anim:rotKey(c, frame)
  local deg
  if c.nRot < 2 then
    deg = signed(c.oRot, 16) / 10.0
  else
    deg = self:hermite(self.rotData + c.oRot * 2, c.nRot, frame,
                       floor(c.interp / 2) % 2 == 1) / 10.0
  end
  deg = deg % 360.0
  -- func_80016DE0 returns s16: the f32 -> s16 cast WRAPS an angle above 180
  -- degrees to its negative twin, and the pack writer clamps i16, so an
  -- unwrapped value would pin at 32767 instead
  return signed(floor(deg / 360.0 * 65536.0) % 65536, 16)
end

function Anim:scaleKey(c, frame)
  if c.nScale < 2 then return signed(c.oScale, 16) / 100.0 end
  return self:hermite(self.scaleData + c.oScale * 2, c.nScale, frame,
                      floor(c.interp / 4) % 2 == 1) / 100.0
end

-- (translation, rotation, scale) for one bone at one frame. Components whose
-- channel carries no data fall back to the bone's bind value.
function Anim:sampleTrs(chanIndex, frame, bt, br, bs)
  local base = chanIndex * 3
  if base < 0 or base + 2 >= self.nChannels then return nil end
  local c1, c2, c3 = self:chan(base), self:chan(base + 1), self:chan(base + 2)
  local t, r, s = {}, {}, {}
  if floor(self.flags / 8) % 2 == 1 then
    t[1], t[2], t[3] = self:transKey(c1, frame), self:transKey(c2, frame),
                       self:transKey(c3, frame)
    r[1], r[2], r[3] = self:rotKey(c1, frame), self:rotKey(c2, frame),
                       self:rotKey(c3, frame)
    s[1], s[2], s[3] = self:scaleKey(c1, frame), self:scaleKey(c2, frame),
                       self:scaleKey(c3, frame)
  else
    t[1], t[2], t[3] = self:transPacked(c1, frame), self:transPacked(c2, frame),
                       self:transPacked(c3, frame)
    r[1], r[2], r[3] = self:rotPacked(c1, frame), self:rotPacked(c2, frame),
                       self:rotPacked(c3, frame)
    s[1], s[2], s[3] = self:scalePacked(c1, frame),
                       self:scalePacked(c2, frame), self:scalePacked(c3, frame)
  end
  for k = 1, 3 do
    if t[k] == nil then t[k] = bt[k] end
    if r[k] == nil then r[k] = br[k] end
    if s[k] == nil then s[k] = bs[k] end
  end
  return t, r, s
end

-- Texture animation (src/18140.c). Same header shape as a skeletal animation,
-- but each channel is a per-frame stream of texture-table indices that
-- func_800176DC substitutes into a material.
local Aux = {}
Aux.__index = Aux

local function newAux(frag, off)
  return setmetatable({
    f = frag,
    flags      = frag:u16(off),   -- low byte, same layout as Anim

    startFrame = frag:u16(off + 4),
    loopStart  = frag:u16(off + 6),
    nChannels  = frag:u16(off + 8),
    nFrames    = frag:u16(off + 0xA),
    chanTable  = frag:ptr(off + 0xC),
    data       = frag:ptr(off + 0x10),
  }, Aux)
end

-- func_80017540: index into the stream, clamped to the channel's length.
function Aux:sample(chan, frame)
  if chan < 0 or chan >= self.nChannels or self.chanTable == nil then
    return nil
  end
  local o = self.chanTable + chan * 4
  local count, base = self.f:u16(o), self.f:u16(o + 2)
  if count == 0 then return nil end
  local i = base + (frame < count and frame or count - 1)
  return self.f:u8(self.data + i)
end

function Aux:track(chan)
  local n = self.nFrames > 1 and self.nFrames or 1
  local out = {}
  for i = 0, n - 1 do out[i + 1] = self:sample(chan, i) end
  return out, n
end

-- ------- textures

local function rgba5551(p)
  return floor(floor(p / 2048) % 32 * 255 / 31),
         floor(floor(p / 64) % 32 * 255 / 31),
         floor(floor(p / 2) % 32 * 255 / 31),
         (p % 2 == 1) and 255 or 0
end

-- (w, h, RGBA8 string) for the N64 texture formats these models use.
local function decodeTexture(f, tex, tlut, palette)
  local w, h, fmt, siz, addr = tex.w, tex.h, tex.fmt, tex.siz, tex.data
  local n = w * h
  if n <= 0 or addr == nil then
    return w, h, string.rep("\255\0\255\255", n > 0 and n or 0)
  end
  local d = f.d
  local out = {}

  local function nibble(i)
    local v = byte(d, addr + floor(i / 2) + 1)
    if i % 2 == 1 then return v % 16 end
    return floor(v / 16)
  end

  if fmt == 0 and siz == 2 then                       -- RGBA16 (5/5/5/1)
    for i = 0, n - 1 do
      local a, b = byte(d, addr + i * 2 + 1, addr + i * 2 + 2)
      out[i + 1] = char(rgba5551(a * 256 + b))
    end
  elseif fmt == 0 and siz == 3 then                   -- RGBA32
    return w, h, sub(d, addr + 1, addr + n * 4)
  elseif fmt == 2 then                                -- CI4 / CI8
    local pal, np = {}, 0
    if tlut ~= nil and tlut.data ~= nil then
      local base = tlut.data + (siz == 0 and palette * 16 * 2 or 0)
      np = (siz == 0) and 16 or 256
      for i = 0, np - 1 do
        local a, b = byte(d, base + i * 2 + 1, base + i * 2 + 2)
        pal[i + 1] = char(rgba5551(a * 256 + b))
      end
    end
    if np == 0 then
      np = 256
      for i = 1, np do pal[i] = "\255\0\255\255" end
    end
    for i = 0, n - 1 do
      local idx = (siz == 0) and nibble(i) or byte(d, addr + i + 1)
      out[i + 1] = pal[idx % np + 1]
    end
  elseif fmt == 3 then                                -- IA16 / IA8 / IA4
    for i = 0, n - 1 do
      local l, a
      if siz == 2 then
        local x, y = byte(d, addr + i * 2 + 1, addr + i * 2 + 2)
        l, a = x, y
      elseif siz == 1 then
        local v = byte(d, addr + i + 1)
        l, a = floor(v / 16) * 17, v % 16 * 17
      else
        local v = nibble(i)
        l, a = floor(floor(v / 2) * 255 / 7), (v % 2 == 1) and 255 or 0
      end
      out[i + 1] = char(l, l, l, a)
    end
  elseif fmt == 4 then                                -- I8 / I4
    for i = 0, n - 1 do
      local l = (siz == 1) and byte(d, addr + i + 1) or nibble(i) * 17
      out[i + 1] = char(l, l, l, 255)
    end
  else
    for i = 0, n - 1 do out[i + 1] = "\255\0\255\255" end
  end
  return w, h, concat(out)
end

StadiumFragment.decodeTexture = decodeTexture

-- ------- the whole model

-- Constant tracks collapse to a scalar; most channels never move, and that
-- fold is most of the reason the packed set is 34 megabytes rather than a
-- great deal more.
local function compress(values, n, nd)
  local first = roundTo(values[1], nd)
  for i = 2, n do
    if roundTo(values[i], nd) ~= first then
      local out = {}
      for k = 1, n do out[k] = roundTo(values[k], nd) end
      return out
    end
  end
  return first
end

-- Every distinct effect callback in the geo layout, once, in the order it
-- first appears -- see fragment.py's dedupe_fx for why the order is written
-- down rather than left to a hash table.
local function dedupeFx(nodes)
  local seen, out = {}, {}
  for i = 1, #nodes do
    local node = nodes[i]
    local key = node.bone .. "," .. node.callback .. "," .. tostring(node.arg)
    if not seen[key] then
      seen[key] = true
      out[#out + 1] = { bone = node.bone, callback = node.callback,
                        arg = node.arg }
    end
  end
  return out
end

-- One decompressed archive entry -> the table StadiumBuild packs. Mirrors
-- fragment.extract, including which fields exist and what they are named.
function StadiumFragment.extract(data, name)
  local frag, err = StadiumFragment.open(data, name)
  if not frag then return nil, err end
  local m, mErr = newModel(frag)
  if not m then return nil, mErr end
  m:build()

  local auxAnims = {}
  for i = 1, #m.auxAnims do auxAnims[i] = newAux(frag, m.auxAnims[i]) end

  local texIndexMap, texOut = {}, {}

  local function register(texIdx, tlut, pal)
    local key = texIdx .. "," .. tlut .. "," .. pal
    local hit = texIndexMap[key]
    if hit ~= nil then return hit end
    if texIdx < 0 or texIdx >= #m.textures then return -1 end
    local slot = #texOut                              -- 0-based, as the file
    texIndexMap[key] = slot
    local tl = (tlut >= 0 and tlut < #m.tluts) and m.tluts[tlut + 1] or nil
    local w, h, rgba = decodeTexture(frag, m.textures[texIdx + 1], tl, pal)
    texOut[slot + 1] = { index = texIdx, w = w, h = h, rgba = rgba }
    return slot
  end

  -- an animated material can swap to any texture its channel names, so all of
  -- them have to be decoded up front
  for _, p in ipairs(m.prims) do
    if p.ntris > 0 then
      local pal = m:tilePalette(p.mat)
      register(p.tex, p.tlut, pal)
      if p.texAnim >= 0 then
        for _, a in ipairs(auxAnims) do
          local tr, tn = a:track(p.texAnim)
          local vals, vn = unique(tr, tn)
          for i = 1, vn do register(vals[i], p.tlut, pal) end
        end
      end
    end
  end

  local prims = {}
  for _, p in ipairs(m.prims) do
    if p.ntris > 0 then
      local pal = m:tilePalette(p.mat)
      local ti = texIndexMap[p.tex .. "," .. p.tlut .. "," .. pal] or -1
      -- texture-table index -> slot in texOut, for the animated swap
      local texMap = nil
      if p.texAnim >= 0 then
        for _, a in ipairs(auxAnims) do
          local tr, tn = a:track(p.texAnim)
          local vals, vn = unique(tr, tn)
          for i = 1, vn do
            local slot = texIndexMap[vals[i] .. "," .. p.tlut .. "," .. pal]
            if slot ~= nil then
              texMap = texMap or {}
              texMap[vals[i]] = slot
            end
          end
        end
      end
      local tw, th = 32, 32
      if ti >= 0 then
        tw, th = m.textures[p.tex + 1].w, m.textures[p.tex + 1].h
      end
      local pos, uv, nrm, skin, idx = {}, {}, {}, {}, {}
      for i = 1, p.nverts do
        local v = p.verts[i]
        pos[i * 3 - 2], pos[i * 3 - 1], pos[i * 3] = v[1], v[2], v[3]
        uv[i * 2 - 1] = (v[4] / 32.0) / tw
        uv[i * 2] = (v[5] / 32.0) / th
        nrm[i * 3 - 2] = v[6] / 127.0
        nrm[i * 3 - 1] = v[7] / 127.0
        nrm[i * 3] = v[8] / 127.0
        skin[i] = v[10]
      end
      local ni = 0
      for i = 1, p.ntris do
        local tri = p.tris[i]
        idx[ni + 1], idx[ni + 2], idx[ni + 3] = tri[1], tri[2], tri[3]
        ni = ni + 3
      end
      prims[#prims + 1] = {
        tex = ti, cull = p.cull, texAnim = p.texAnim, texMap = texMap,
        pos = pos, uv = uv, nrm = nrm, skin = skin, nverts = p.nverts,
        idx = idx, nidx = ni,
      }
    end
  end

  local anims = {}
  for i = 1, #m.anims do
    local a = newAnim(frag, m.anims[i])
    local nf = a.nFrames > 1 and a.nFrames or 1
    local tracks = {}
    for bi = 1, #m.bones do
      local b = m.bones[bi]
      local ch = b.chan
      if ch >= 0 and a:sampleTrs(ch, 0, b.t, b.r, b.s) ~= nil then
        local ts, rs, ss = {}, {}, {}
        for k = 1, 3 do ts[k], rs[k], ss[k] = {}, {}, {} end
        for fr = 0, nf - 1 do
          local t, r, s = a:sampleTrs(ch, fr, b.t, b.r, b.s)
          for k = 1, 3 do
            ts[k][fr + 1], rs[k][fr + 1], ss[k][fr + 1] = t[k], r[k], s[k]
          end
        end
        tracks[bi] = {
          t = { compress(ts[1], nf, 3), compress(ts[2], nf, 3),
                compress(ts[3], nf, 3) },
          r = { compress(rs[1], nf, 0), compress(rs[2], nf, 0),
                compress(rs[3], nf, 0) },
          s = { compress(ss[1], nf, 5), compress(ss[2], nf, 5),
                compress(ss[3], nf, 5) },
        }
      end
    end
    anims[i] = { index = i - 1, frames = nf, flags = a.flags,
                 channels = a.nChannels, loopStart = a.loopStart,
                 tracks = tracks }
  end

  local auxOut = {}
  for i = 1, #auxAnims do
    local a = auxAnims[i]
    local chans = {}
    for c = 0, a.nChannels - 1 do
      local tr, tn = a:track(c)
      tr.n = tn
      chans[c + 1] = tr
    end
    auxOut[i] = { index = i - 1, frames = a.nFrames > 1 and a.nFrames or 1,
                  flags = a.flags, loopStart = a.loopStart, channels = chans }
  end

  return {
    species = m.species,
    file = name,
    rootScale = m.rootScale,
    bones = m.bones,
    textures = texOut,
    prims = prims,
    anims = anims,
    auxAnims = auxOut,
    fx = dedupeFx(m.fx),
    warnings = m.warnings,
  }
end

return StadiumFragment
