-- STADIUM battles: getting at the Pokemon Stadium ROM.
--
-- Byte order, the archive the battle models are packed into, the Yay0
-- decompressor that unwraps each one, and the per-species battle tables. It
-- is a port of model_extract/pipeline/rom.py, function for function, and the
-- Python remains the reference: tools/stadium_pack.py drives that side and
-- tests/stadium_extract_test.lua diffs this side's finished packs against it
-- byte for byte.
--
-- ------- why this exists in Lua at all
--
-- The mod cannot ship the models. They are ROM data, so what ships is the
-- READER, and the player supplies the ROM -- exactly the arrangement the
-- engine itself already has for the Game Boy ROM it is a recompilation of
-- (src/import/RomImporter.lua). Everything from `baserom.z64` to
-- `assets/stadium/NNN.dsm` therefore has to happen here, on the machine, in
-- Lua, with no Python and no build step.
--
-- ------- what makes that tractable
--
-- Three steps, and none of them needs a decompilation toolchain:
--
--   1. BYTE ORDER. The three N64 dump conventions differ by a swap that is
--      detected from the magic word and undone once, on load.
--   2. THE ARCHIVE. The segment at 0x920000 is a count and a table of
--      (offset, size) records. No compression at that level, no names.
--   3. Yay0. Nintendo's LZ variant: a bitstream where a 1 copies a literal
--      byte and a 0 pulls a (distance, length) pair out of a side table.
--      Thirty lines, and the same thirty lines the Python has.
--
-- Verified in the Python by decompressing all 215 entries and diffing against
-- what the decompilation's own `make init` produces: 215/215 identical.

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local StadiumRom = {}

local byte = string.byte
local char = string.char
local concat = table.concat
local sub = string.sub
local floor = math.floor

-- ROM offsets, from pokestadium-us.yaml by way of pipeline/rom.py.
StadiumRom.POKEMON_MODELS = 0x920000    -- archive of the 215 battle models
StadiumRom.BATTLE_DATA    = 0x70D3A0    -- per-species battle tables
StadiumRom.MAIN_ROM       = 0x1000      -- main code segment ...
StadiumRom.MAIN_VRAM      = 0x80000400  -- ... and where it lands in RAM
StadiumRom.PTR_TABLE_VRAM = 0x80075BD0  -- D_80075BD0[species - 1]

-- The revision every offset above is keyed to. A different ROM still runs --
-- it may well be a regional variant with the same layout -- but the caller is
-- told, because "the models came out as garbage" and "that is not the ROM
-- this was written against" are the same fact and only one of them is useful.
StadiumRom.US_MD5 = "ed1378bc12115f71209a77844965ba50"

-- The battle table's shape: 0xB90 bytes a species, as 0x10-byte entries.
-- Entries 0..164 are the moves (entry n drives move n + 1) and 165 up are the
-- fixed battle contexts.
StadiumRom.STRIDE = 0xB90
StadiumRom.ENTRY = 0x10
StadiumRom.N_MOVES = 165

-- How many of the archive's 215 models are the battle Pokemon. The rest are
-- props and trophies with no battle table.
StadiumRom.N_POKEMON = 151

-- ------- byte order
--
-- .z64 is big-endian and native; .v64 has each pair of bytes swapped; .n64
-- has each word reversed. `gsub` with a capture-reversing replacement does
-- either in one call through C rather than a Lua loop over 33 million bytes.

local MAGIC_Z64 = "\128\055\018\064"
local MAGIC_V64 = "\055\128\064\018"
local MAGIC_N64 = "\064\018\055\128"

-- Normalise a dump to .z64 order, or nil when it is not an N64 ROM at all.
function StadiumRom.normalise(bytes)
  if type(bytes) ~= "string" or #bytes < 0x1000 then return nil end
  local magic = sub(bytes, 1, 4)
  if magic == MAGIC_Z64 then return bytes end
  if magic == MAGIC_V64 then return (bytes:gsub("(.)(.)", "%2%1")) end
  if magic == MAGIC_N64 then
    return (bytes:gsub("(.)(.)(.)(.)", "%4%3%2%1"))
  end
  return nil
end

-- ------- Yay0
--
-- The output has to be RANDOM ACCESS while it is being written -- a back
-- reference copies from what has already been produced, and overlapping runs
-- are legal and common -- so it is built in a flat table of byte values and
-- turned into a string at the end.
--
-- The string.char conversion is the part that wants care: it is variadic and
-- has an argument limit, so the table is walked in blocks and the blocks
-- concatenated. Blocks of 4096 keep the call count and the intermediate
-- string count both low; the whole 151-model set converts in well under a
-- second on LuaJIT, which is what made an FFI buffer unnecessary here and
-- kept this module portable to any Lua the engine runs on.

local CHUNK = 4096

-- LuaJIT keeps `unpack` global; 5.2+ moved it onto table.
local unpack = unpack or table.unpack

local function bytesToString(out, n)
  if n == 0 then return "" end
  local parts, np = {}, 0
  local i = 1
  while i <= n do
    local j = i + CHUNK - 1
    if j > n then j = n end
    np = np + 1
    parts[np] = char(unpack(out, i, j))
    i = j + 1
  end
  return concat(parts)
end

-- Nintendo Yay0. Header: magic, decompressed size, link table offset, chunk
-- offset; then a bitstream read a word at a time.
function StadiumRom.yay0(src, base)
  base = base or 0
  if sub(src, base + 1, base + 4) ~= "Yay0" then return nil, "not Yay0" end
  local function be32(o)
    local a, b, c, d = byte(src, base + o + 1, base + o + 4)
    return ((a * 256 + b) * 256 + c) * 256 + d
  end
  local size = be32(4)
  -- all three cursors are 1-based indices into `src`; the mask stream starts
  -- immediately after the 16-byte header
  local maskP = base + 0x10 + 1
  local linkP = base + be32(8) + 1
  local chunkP = base + be32(12) + 1

  local out = {}
  local pos = 0                      -- bytes produced so far
  local mask, bits = 0, 0

  while pos < size do
    if bits == 0 then
      local a, b, c, d = byte(src, maskP, maskP + 3)
      mask = ((a * 256 + b) * 256 + c) * 256 + d
      maskP = maskP + 4
      bits = 32
    end
    if mask >= 0x80000000 then
      pos = pos + 1
      out[pos] = byte(src, chunkP)
      chunkP = chunkP + 1
    else
      local a, b = byte(src, linkP, linkP + 1)
      linkP = linkP + 2
      local link = a * 256 + b
      local dist = link % 0x1000
      local count = floor(link / 0x1000)
      if count == 0 then
        count = byte(src, chunkP) + 0x12
        chunkP = chunkP + 1
      else
        count = count + 2
      end
      -- overlapping runs are legal: copying one byte at a time from the
      -- output as it grows is the behaviour, not a naive version of it
      local copy = pos - dist
      for _ = 1, count do
        pos = pos + 1
        out[pos] = out[copy]
        copy = copy + 1
      end
    end
    mask = (mask * 2) % 0x100000000
    bits = bits - 1
  end

  return bytesToString(out, size)
end

-- Unwrap whatever container an asset arrived in. The model archive's entries
-- are PERS-SZP: an eight-byte magic plus a header size, wrapping a Yay0
-- stream.
function StadiumRom.decompress(blob)
  if sub(blob, 1, 8) == "PERS-SZP" then
    local a, b, c, d = byte(blob, 9, 12)
    local header = ((a * 256 + b) * 256 + c) * 256 + d
    return StadiumRom.yay0(blob, header)
  end
  if sub(blob, 1, 4) == "Yay0" then return StadiumRom.yay0(blob, 0) end
  return blob
end

-- ------- the ROM

local Rom = {}
Rom.__index = Rom

-- `bytes` is the whole file. Returns the ROM, or nil plus why.
function StadiumRom.open(bytes)
  local data = StadiumRom.normalise(bytes)
  if not data then return nil, "not an N64 ROM (bad magic)" end
  return setmetatable({ data = data }, Rom)
end

function Rom:u8(o)
  return byte(self.data, o + 1)
end

function Rom:u32(o)
  local a, b, c, d = byte(self.data, o + 1, o + 4)
  if not d then return 0 end
  return ((a * 256 + b) * 256 + c) * 256 + d
end

function Rom:vramToRom(vram)
  return StadiumRom.MAIN_ROM + (vram - StadiumRom.MAIN_VRAM)
end

-- The md5 of the normalised image, or nil where LOVE's hash is not there
-- (the headless suite). Only ever used to tell the player which ROM they
-- gave us, never to refuse one.
function Rom:md5()
  if self.hash ~= nil then return self.hash or nil end
  local ok, hex = pcall(function()
    local digest = love.data.hash("md5", self.data)
    if type(digest) == "userdata" and digest.getString then
      digest = digest:getString()
    end
    return love.data.encode("string", "hex", digest)
  end)
  self.hash = (ok and hex) or false
  return self.hash or nil
end

function Rom:isExpectedUS()
  local hex = self:md5()
  return hex == nil or hex == StadiumRom.US_MD5
end

-- ------- the archive
--
-- Segments that hold many files start with
--     u32 tag, u32 0, u32 totalSize, u32 fileCount
-- followed by fileCount { u32 offset, u32 size, u32 pad[2] } records, all
-- relative to the start of the segment.
--
-- Only the top three bytes of the first word are reliably zero: the model
-- archive puts a nonzero value in the low byte, which is the same quirk the
-- decompilation's own tools/unpack_asset.py works around.
--
-- Returns a list of { start, size } rather than the bytes, so nothing is
-- copied until a caller actually wants a file.
function Rom:archive(off)
  local tag = self:u32(off)
  if (tag - tag % 256) ~= 0 or self:u32(off + 4) ~= 0 then return nil end
  local count = self:u32(off + 12)
  if count <= 0 or count >= 4096 then return nil end
  local out = {}
  for i = 0, count - 1 do
    local rec = off + 0x10 + i * 0x10
    out[i + 1] = { start = off + self:u32(rec), size = self:u32(rec + 4) }
  end
  return out
end

-- The entries of the battle-model archive, uncopied.
function Rom:models()
  if not self.modelDir then
    self.modelDir = self:archive(StadiumRom.POKEMON_MODELS) or {}
  end
  return self.modelDir
end

function Rom:modelCount()
  return #self:models()
end

-- One model fragment, decompressed. `fileno` is 0-based, as in the Python and
-- in the source-file names: `N.bin` holds species N + 1.
function Rom:model(fileno)
  local rec = self:models()[fileno + 1]
  if not rec then return nil end
  return StadiumRom.decompress(sub(self.data, rec.start + 1,
                                   rec.start + rec.size))
end

-- ------- the per-species battle tables
--
-- func_84302658 in src/fragments/62 DMAs 0xB90 bytes a species out of the
-- 0x70D3A0 segment, addressed through the D_80075BD0 pointer table. Byte 0 of
-- each 0x10-byte entry indexes that Pokemon's animation list and byte 1 its
-- auxiliary (texture) animation list.
--
-- Returns a 0-based array-like table of { anim, aux }, aux 0xFF meaning none
-- and coming back as -1 -- the shape the packer writes.
function Rom:battleRows(species)
  local ptrTable = self:vramToRom(StadiumRom.PTR_TABLE_VRAM)
  local raw = self:u32(ptrTable + (species - 1) * 4)
  local o = StadiumRom.BATTLE_DATA + raw % 0x1000000
  local rows = {}
  local n = StadiumRom.STRIDE / StadiumRom.ENTRY
  for e = 0, n - 1 do
    local anim = self:u8(o + e * StadiumRom.ENTRY)
    local aux = self:u8(o + e * StadiumRom.ENTRY + 1)
    rows[e] = { anim, aux == 0xFF and -1 or aux }
  end
  rows.n = n
  return rows
end

return StadiumRom
