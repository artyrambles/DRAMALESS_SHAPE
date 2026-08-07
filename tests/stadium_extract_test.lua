-- The Lua ROM extractor, against the Python packer that is its oracle.
--
--   luajit mods/DramaticShapeVoxelMod/tests/stadium_extract_test.lua \
--          [--rom=PATH] [--oracle=DIR] [--only=25,6] [--out=DIR]
--
-- Run from the PROJECT ROOT. Defaults: the ROM under
-- model_extract/baseroms/, the oracle in assets/stadium (whatever
-- tools/stadium_pack.py last wrote there).
--
-- ------- what this is for
--
-- lib/StadiumRom, StadiumFragment, StadiumFx and StadiumBuild are a port of
-- roughly fifteen hundred lines of dense numeric Python -- an F3DEX2
-- interpreter, six texture codecs, a bit-packed animation sampler, a noise
-- generator and a binary writer. Reading a port of that twice does not
-- establish that it is right. Producing the same thirty-four megabytes,
-- byte for byte, does.
--
-- It is also the guard on the two of them DRIFTING. The packer and the
-- extractor have to keep agreeing about the format forever, and a change to
-- one that is not made to the other shows up here as a differing offset
-- rather than as a Pokemon that renders as noise three months later.
--
-- Headless: no LOVE, no graphics. Everything these four modules do is
-- arithmetic on strings.

local args = {}
for _, a in ipairs({ ... }) do
  local k, v = a:match("^%-%-([%w_]+)=(.*)$")
  if k then args[k] = v else args[a:gsub("^%-%-", "")] = true end
end

local MOD = "mods/DramaticShapeVoxelMod"
local ROM = args.rom or (MOD .. "/model_extract/baseroms/us/baserom.z64")
local ORACLE = args.oracle or (MOD .. "/assets/stadium")

-- ------- the mod namespace, enough of it to load four modules

local loaded = {}
local V = {}
function V.require(name)
  if loaded[name] == nil then
    local chunk = assert(loadfile(MOD .. "/lib/" .. name .. ".lua"))
    loaded[name] = chunk(V)
  end
  return loaded[name]
end
V.mod = { log = { warn = function() end, info = function() end } }

local StadiumRom = V.require("StadiumRom")
local StadiumBuild = V.require("StadiumBuild")

-- ------- run

local function readFile(path)
  local fp = io.open(path, "rb")
  if not fp then return nil end
  local data = fp:read("*a")
  fp:close()
  return data
end

local romBytes = readFile(ROM)
if not romBytes then
  io.stderr:write("no ROM at " .. ROM .. "\n")
  os.exit(2)
end

local rom, err = StadiumRom.open(romBytes)
if not rom then
  io.stderr:write("could not open ROM: " .. tostring(err) .. "\n")
  os.exit(2)
end

local only = nil
if args.only then
  only = {}
  for n in args.only:gmatch("%d+") do only[tonumber(n)] = true end
end

local checked, matched, missing, failed = 0, 0, 0, 0
local firstBad = nil
local t0 = os.clock()

for fileno = 0, StadiumRom.N_POKEMON - 1 do
  local ok, res = pcall(StadiumBuild.species, rom, fileno)
  if not ok or not res then
    -- res carries the message on the error path
    io.write(("file %d: EXTRACT FAILED: %s\n"):format(fileno, tostring(res)))
    failed = failed + 1
  elseif not only or only[res.species] then
    checked = checked + 1
    if args.out then
      local fp = io.open(("%s/%03d.dsm"):format(args.out, res.species), "wb")
      if fp then fp:write(res.bytes) fp:close() end
    end
    local want = readFile(("%s/%03d.dsm"):format(ORACLE, res.species))
    if not want then
      missing = missing + 1
    elseif want == res.bytes then
      matched = matched + 1
    else
      -- where, exactly: the first differing byte localises a format mistake
      -- far faster than "the file is wrong" does
      local at = nil
      local n = math.min(#want, #res.bytes)
      for i = 1, n do
        if want:sub(i, i) ~= res.bytes:sub(i, i) then at = i break end
      end
      io.write(("%03d.dsm DIFFERS: %d bytes vs %d, first at %s\n")
               :format(res.species, #res.bytes, #want,
                       at and ("offset " .. at) or "(one is a prefix)"))
      if not firstBad then firstBad = res.species end
    end
  end
end

io.write(("\n%d checked, %d identical, %d differ, %d oracle files missing, "
          .. "%d extractions failed  (%.1fs)\n")
         :format(checked, matched, checked - matched - missing, missing,
                 failed, os.clock() - t0))

if matched == checked and failed == 0 and missing == 0 then
  io.write("PASS -- the Lua extractor reproduces the packer exactly\n")
  os.exit(0)
end
io.write("FAIL\n")
os.exit(1)
