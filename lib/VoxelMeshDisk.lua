-- Persistent raw voxel-mesh streams.
--
-- LOVE Mesh objects are driver/session resources and cannot survive a restart.
-- The six-float vertex streams which create them can: cache those under the
-- save directory, then upload them cooperatively next session instead of
-- rerunning Structures and the terrain carve.
--
-- Every read fails open. Missing, truncated, corrupt, or fingerprint-mismatched
-- files are removed and the ordinary mesher rebuilds them. No user setting or
-- cache id is exposed; CACHE_REVISION is the format/geometry contract and must
-- be bumped whenever emitted vertices change in a way the fingerprint cannot
-- observe directly.

local V = ...

local Budget = V.require("BuildBudget")

local ffi = nil
do
  local ok, value = pcall(require, "ffi")
  if ok then ffi = value end
end

local Disk = {}

Disk.CACHE_REVISION = 1
Disk.DIRECTORY = "mod-derived/BATTLE_ART_VOXEL_FORK/mesh-cache-v1"

local MAGIC = "BAVC"
local FORMAT = 2
local RAW_CHUNK = 1024 * 1024

local function available()
  local fs = love and love.filesystem
  return ffi ~= nil and fs and fs.read and fs.write and fs.createDirectory
    and fs.newFile and fs.getDirectoryItems
    and love.data and love.data.newByteData
    and love.data.compress and love.data.decompress
    and love.graphics and love.graphics.newMesh
end

function Disk.available()
  return available()
end

local function u32(n)
  n = math.floor(tonumber(n) or 0) % 4294967296
  return string.char(n % 256, math.floor(n / 256) % 256,
                     math.floor(n / 65536) % 256,
                     math.floor(n / 16777216) % 256)
end

local function readU32(s, pos)
  if not s or pos + 3 > #s then return nil end
  return s:byte(pos) + s:byte(pos + 1) * 256
       + s:byte(pos + 2) * 65536 + s:byte(pos + 3) * 16777216
end

local function addList(parts, list)
  parts[#parts + 1] = tostring(#(list or {}))
  for _, value in ipairs(list or {}) do
    if type(value) == "table" then
      addList(parts, value)
    else
      parts[#parts + 1] = tostring(value)
    end
  end
end

-- Exact canonical input description rather than a short probabilistic hash.
-- Map block edits, tileset replacements, connection-mask changes and void-fill
-- changes therefore invalidate themselves without relying on a remembered
-- cleanup event. The revision covers algorithm/data rules not present here.
function Disk.fingerprint(map, slot, masks, kind)
  local def, tileset = map.def or {}, map.tileset or {}
  local parts = {
    "rev", tostring(Disk.CACHE_REVISION),
    "mod", tostring(V.mod and V.mod.version),
    "kind", tostring(kind), "slot", tostring(slot),
    "map", tostring(map.id), "tileset", tostring(def.tileset),
    "size", tostring(def.width), tostring(def.height),
    "border", tostring(def.borderBlock),
    "image", tostring(tileset.image),
    "imageSize", tostring(tileset.imageWidth), tostring(tileset.imageHeight),
    "row", tostring(tileset.tilesPerRow),
    "trueColor", tileset.trueColor and "1" or "0",
  }
  local okTR, TileRenderer = pcall(require, "src.render.TileRenderer")
  parts[#parts + 1] = "void"
  parts[#parts + 1] = tostring(okTR and TileRenderer.voidFill or "trees")
  parts[#parts + 1] = "blocks"
  addList(parts, def.blocks)
  parts[#parts + 1] = "tiles"
  addList(parts, tileset.blocks)
  parts[#parts + 1] = "masks"
  addList(parts, masks)
  return table.concat(parts, "|")
end

local function safeId(id)
  return tostring(id):gsub("[^%w_.-]", "_")
end

local function pathFor(map, slot, kind)
  local suffix = kind == "aux" and "aux" or (tostring(slot) .. ".terrain")
  return Disk.DIRECTORY .. "/" .. safeId(map.id) .. "." .. suffix .. ".bavc"
end

local function remove(path)
  if love and love.filesystem and love.filesystem.remove then
    pcall(love.filesystem.remove, path)
  end
end

local function header(fp)
  return MAGIC .. u32(FORMAT) .. u32(#fp) .. fp
end

local function parseHeader(blob, expected)
  if not blob or #blob < 12 or blob:sub(1, 4) ~= MAGIC then return nil end
  local format = readU32(blob, 5)
  local n = readU32(blob, 9)
  if format ~= FORMAT or not n or 12 + n > #blob then return nil end
  local first = 13
  if blob:sub(first, first + n - 1) ~= expected then return nil end
  return first + n
end

local function streamRecord(blob, pos)
  local n = readU32(blob, pos)
  if not n then return nil end
  local chunks = readU32(blob, pos + 4)
  if not chunks or chunks > 65536 then return nil end
  pos = pos + 8
  local expected, decoded = n * 6 * 4, {}
  if chunks ~= (expected > 0 and math.ceil(expected / RAW_CHUNK) or 0) then
    return nil
  end
  local total = 0
  for _ = 1, chunks do
    local rawBytes = readU32(blob, pos)
    local packedBytes = readU32(blob, pos + 4)
    if not rawBytes or rawBytes > RAW_CHUNK
       or total + rawBytes > expected
       or not packedBytes or packedBytes > #blob - pos - 7 then
      return nil
    end
    local first = pos + 8
    local packed = blob:sub(first, first + packedBytes - 1)
    local ok, raw = pcall(love.data.decompress, "string", "lz4", packed)
    if not ok or type(raw) ~= "string" or #raw ~= rawBytes then return nil end
    decoded[#decoded + 1] = raw
    total = total + rawBytes
    pos = first + packedBytes
    Budget.check()
  end
  if total ~= expected or (expected == 0 and chunks ~= 0) then return nil end
  local raw = table.concat(decoded)
  return { n = n, blob = raw, offset = 0 }, pos
end

local function readValidated(path, fp)
  if not available() then return nil end
  local ok, blob = pcall(love.filesystem.read, path)
  if not ok or not blob then return nil end
  local pos = parseHeader(blob, fp)
  if not pos then remove(path); return nil end
  return blob, pos
end

function Disk.loadTerrain(map, slot, masks)
  local path = pathFor(map, slot, "terrain")
  local fp = Disk.fingerprint(map, slot, masks, "terrain")
  local blob, pos = readValidated(path, fp)
  if not blob then return nil end
  local terrain, nextPos = streamRecord(blob, pos)
  local water, finalPos = nextPos and streamRecord(blob, nextPos) or nil
  if not terrain or not water or finalPos ~= #blob + 1 then
    remove(path)
    return nil
  end
  return { terrain = terrain, water = water }
end

local function float4(blob, pos)
  if pos + 15 > #blob then return nil end
  local values = ffi.new("float[4]")
  ffi.copy(values, ffi.cast("const uint8_t*", blob) + pos - 1, 16)
  return { values[0], values[1], values[2], values[3] }, pos + 16
end

function Disk.loadAux(map)
  local path = pathFor(map, "aux", "aux")
  local fp = Disk.fingerprint(map, "aux", nil, "aux")
  local blob, pos = readValidated(path, fp)
  if not blob then return nil end
  local grass, p2 = streamRecord(blob, pos)
  local flowers, p3 = p2 and streamRecord(blob, p2) or nil
  local count = p3 and readU32(blob, p3) or nil
  if not grass or not flowers or not count or count > 1024 then
    remove(path); return nil
  end
  pos = p3 + 4
  local figures = {}
  for _ = 1, count do
    local stream, nextPos = streamRecord(blob, pos)
    local meta, finalPos = nextPos and float4(blob, nextPos) or nil
    if not stream or not meta then remove(path); return nil end
    stream.wx, stream.wz, stream.y, stream.w = meta[1], meta[2], meta[3], meta[4]
    figures[#figures + 1] = stream
    pos = finalPos
  end
  if pos ~= #blob + 1 then remove(path); return nil end
  return { grass = grass, flowers = flowers, figures = figures }
end

local function write(file, bytes)
  local ok, err = file:write(bytes)
  if not ok then error(err or "voxel cache write failed", 0) end
end

local function writeChunked(file, ptr, n)
  write(file, u32(n or 0))
  local bytes = (n or 0) * 6 * 4
  local chunks = bytes > 0 and math.ceil(bytes / RAW_CHUNK) or 0
  write(file, u32(chunks))
  if not ptr or not n or n == 0 then return true end
  local offset = 0
  while offset < bytes do
    local count = math.min(RAW_CHUNK, bytes - offset)
    local raw = ffi.string(ffi.cast("const uint8_t*", ptr) + offset, count)
    local packed = love.data.compress("string", "lz4", raw)
    write(file, u32(count))
    write(file, u32(#packed))
    write(file, packed)
    offset = offset + count
    Budget.check()
  end
  return true
end

local function writeFile(path, fp, writer)
  if not available() then return false end
  local ok = pcall(function()
    assert(love.filesystem.createDirectory(Disk.DIRECTORY))
    local file = assert(love.filesystem.newFile(path, "w"))
    local wrote, err = pcall(function()
      write(file, header(fp))
      writer(file)
    end)
    file:close()
    if not wrote then error(err, 0) end
  end)
  if not ok then remove(path) end
  return ok
end

function Disk.saveTerrain(map, slot, masks, terrain, water)
  local path = pathFor(map, slot, "terrain")
  local fp = Disk.fingerprint(map, slot, masks, "terrain")
  return writeFile(path, fp, function(file)
    writeChunked(file, terrain and terrain.ptr, terrain and terrain.n or 0)
    writeChunked(file, water and water.ptr, water and water.n or 0)
  end)
end

local function f32x4(a, b, c, d)
  local values = ffi.new("float[4]", { a or 0, b or 0, c or 0, d or 0 })
  return ffi.string(values, 16)
end

function Disk.saveAux(map, aux)
  local path = pathFor(map, "aux", "aux")
  local fp = Disk.fingerprint(map, "aux", nil, "aux")
  return writeFile(path, fp, function(file)
    writeChunked(file, aux.grass and aux.grass.ptr, aux.grass and aux.grass.n or 0)
    writeChunked(file, aux.flowers and aux.flowers.ptr,
                 aux.flowers and aux.flowers.n or 0)
    write(file, u32(#(aux.figures or {})))
    for _, figure in ipairs(aux.figures or {}) do
      writeChunked(file, figure.ptr, figure.n)
      write(file, f32x4(figure.wx, figure.wz, figure.y, figure.w))
      Budget.check()
    end
  end)
end

-- Remove every file belonging to a dirty map. Fingerprints would reject them
-- anyway; eager deletion prevents edited maps from leaving dead files behind.
function Disk.invalidate(mapId)
  if not (available() and mapId) then return end
  local prefix = safeId(mapId) .. "."
  local ok, names = pcall(love.filesystem.getDirectoryItems, Disk.DIRECTORY)
  if not ok then return end
  for _, name in ipairs(names or {}) do
    if name:sub(1, #prefix) == prefix then remove(Disk.DIRECTORY .. "/" .. name) end
  end
end

return Disk
