-- STADIUM battles: finding the ROM, and building the models out of it once.
--
-- The mod does not ship the Pokemon Stadium models and cannot: they are that
-- game's data. What it ships is the READER -- StadiumRom, StadiumFragment,
-- StadiumFx and StadiumBuild -- and the player supplies the cartridge, which
-- is exactly the arrangement this engine already has for the Game Boy ROM it
-- is a recompilation of (src/import/RomImporter.lua).
--
-- So: supply a Pokemon Stadium (US) 1.0 ROM -- the OPTIONS row opens a file
-- picker for one, or drop it in `baseroms/` -- and the first time the
-- game runs with the mod on, the models are built. Once, on a loading screen,
-- in about ten seconds. After that the packs sit in the save directory and
-- the mod reads them like any other asset.
--
-- ------- where "baseroms/" is
--
-- One relative path, and it deliberately covers two different places at once,
-- because PhysFS searches the save directory AND the game folder under the
-- same names:
--
--   * a folder install, or a checkout -- `baseroms/` next to main.lua
--   * a packaged or fused build, where the game folder is inside an archive
--     and cannot be written to -- `baseroms/` in the save directory, whose
--     absolute path this reports on screen so it can be found
--
-- The file goes STRAIGHT IN THERE, with no revision subfolder under it. The
-- decompilation's own `make init` uses `baseroms/us/`, and the offline
-- pipeline under model_extract/ still reads from there because it shares that
-- tree -- but the instruction given to a player is "drop the file in this
-- folder", and one folder is the whole of it.
--
-- Any of `.z64`, `.n64` and `.v64` is accepted; StadiumRom normalises the
-- byte order on load.
--
-- ------- what "installed" means
--
-- A marker file next to the packs, holding the format magic, how many species
-- were written and the md5 of the ROM they came from. All three matter. The
-- magic catches a format change (the packs are rebuilt rather than read as
-- garbage), the count catches a build that was interrupted half way, and the
-- md5 catches the player swapping the ROM for a different revision.

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local StadiumPack = V.require("StadiumPack")

local StadiumInstall = {}

-- Where a ROM is looked for, and where the built packs are kept.
StadiumInstall.ROM_DIR = "baseroms"
StadiumInstall.DIR = StadiumPack.CACHE_DIR
StadiumInstall.MARKER = StadiumInstall.DIR .. "/pack.info"

-- Bumped whenever the .dsm format changes, so an old cache is rebuilt rather
-- than misread. Must track StadiumPack's magic.
StadiumInstall.FORMAT = "DSM4"

-- Bumped when the packs' CONTENT changes without the byte layout moving, so
-- a cache built by an older extractor is rebuilt rather than trusted. Rev 2
-- is the hermite-animation decode fix: the five keyframe species (Pidgeot,
-- Dodrio, Exeggutor, Tangela, Magmar) come out garbled or bind-posed from
-- any rev-1 build.
StadiumInstall.REV = 2

StadiumInstall.COUNT = 151

-- Named ROM files, then any ROM at all sitting in the folder.
--
-- Flat in `baseroms/`, with no revision subfolder: the offline pipeline under
-- model_extract/ keeps the decompilation's own `baseroms/us/` convention
-- because it shares that tree, but what is being asked of a PLAYER here is
-- "drop the file in this folder", and one folder is the whole of that
-- instruction. A path they have to build out of two parts is a path half of
-- them will get wrong, and the failure is silent -- the rungs are simply not
-- on the row.
local NAMED = {
  StadiumInstall.ROM_DIR .. "/baserom.z64",
  StadiumInstall.ROM_DIR .. "/baserom.n64",
  StadiumInstall.ROM_DIR .. "/baserom.v64",
}

local function fs()
  return love and love.filesystem
end

local function isFile(path)
  local f = fs()
  if not (f and f.getInfo) then return false end
  local ok, info = pcall(f.getInfo, path, "file")
  return (ok and info) and true or false
end

-- The ROM's path on the PhysFS read path, or nil.
function StadiumInstall.romPath()
  local f = fs()
  if not f then return nil end
  for _, path in ipairs(NAMED) do
    if isFile(path) then return path end
  end
  local ok, items = pcall(f.getDirectoryItems, StadiumInstall.ROM_DIR)
  if ok and items then
    table.sort(items)
    for _, name in ipairs(items) do
      if name:lower():match("%.[nvz]64$") then
        local path = StadiumInstall.ROM_DIR .. "/" .. name
        if isFile(path) then return path end
      end
    end
  end
  return nil
end

function StadiumInstall.romPresent()
  return StadiumInstall.romPath() ~= nil
end

-- Where to tell the player to put it. The save directory is the answer that
-- is always writable, and it is the one a packaged build needs.
function StadiumInstall.romHint()
  local f = fs()
  local base = (f and f.getSaveDirectory and select(2, pcall(f.getSaveDirectory)))
  if type(base) ~= "string" then base = "the game folder" end
  return base .. "/" .. StadiumInstall.ROM_DIR
end

-- The same thing with a FILENAME on the end, which is what a player actually
-- needs: a folder alone leaves them guessing what to call the file, and the
-- guess is not obviously "baserom.z64".
--
-- Taken from the head of NAMED rather than retyped, so the name shown is by
-- construction the first name looked for. It is not the ONLY one that works
-- -- `.n64` and `.v64` are accepted, and so is any other name carrying one
-- of those extensions -- but an instruction that names one file is one a
-- player can follow, and an instruction that lists every possibility is one
-- they have to interpret.
function StadiumInstall.romHintFile()
  return StadiumInstall.romHint() .. "/" .. (NAMED[1]:match("[^/]+$") or "")
end

-- ------- the marker

local function readMarker()
  local f = fs()
  if not (f and isFile(StadiumInstall.MARKER)) then return nil end
  local ok, text = pcall(f.read, StadiumInstall.MARKER)
  if not (ok and type(text) == "string") then return nil end
  local format, count, md5, rev = text:match("^(%S+)%s+(%d+)%s*(%S*)%s*(%S*)")
  if not format then return nil end
  return { format = format, count = tonumber(count), md5 = md5,
           rev = tonumber(rev) }
end

-- Whether a complete, current set of packs is on disk.
local readyCache = nil

function StadiumInstall.ready()
  if readyCache ~= nil then return readyCache end
  local m = readMarker()
  readyCache = (m ~= nil and m.format == StadiumInstall.FORMAT
                and m.count == StadiumInstall.COUNT
                and m.rev == StadiumInstall.REV) and true or false
  return readyCache
end

-- Whether a complete set came WITH the mod folder -- a developer checkout
-- that has run tools/stadium_pack.py. Never true of a released build, which
-- carries no models at all.
--
-- Sampled at both ends of the dex rather than counted. The question being
-- asked is "did somebody run the packer here", not "is every one of the 151
-- present"; a genuinely half-written folder is a case for the marker file,
-- which is what catches an interrupted RUNTIME build.
local function shipped()
  local mod = V.mod
  if not (mod and mod.read) then return false end
  for _, dex in ipairs({ 1, 151 }) do
    local ok, bytes = pcall(mod.read, mod,
                            ("%s/%03d.dsm"):format(StadiumPack.DIR, dex))
    if not (ok and type(bytes) == "string" and #bytes > 4) then return false end
  end
  return true
end

-- Whether the STADIUM rungs can be offered at all: either the packs have been
-- built from the player's ROM, or the mod folder already carries a set.
function StadiumInstall.available()
  if StadiumInstall.ready() then return true end
  return shipped()
end

-- Whether there is work to do: something to build from, and nothing usable
-- yet.
--
-- A checkout that already carries a set is NOT pending. Building anyway would
-- be correct and would also mean a ten-second loading screen on the first run
-- of every checkout, to arrive at the files that were already sitting there.
function StadiumInstall.pending()
  if StadiumInstall.available() then return false end
  return StadiumInstall.romPresent()
end

function StadiumInstall.forget()
  readyCache = nil
end

-- ------- building

local job = nil
local status = { state = "idle", done = 0, total = StadiumInstall.COUNT }

StadiumInstall.status = status

local function writePack(species, bytes)
  local f = fs()
  if not f then return false, "no filesystem" end
  local ok, err = f.write(("%s/%03d.dsm"):format(StadiumInstall.DIR, species),
                          bytes)
  if not ok then return false, tostring(err) end
  return true
end

-- Open the ROM found in `baseroms/` and start a stepped build. Returns false
-- plus a reason when there is nothing to build from.
function StadiumInstall.begin()
  local f = fs()
  if not f then return false, "no filesystem" end
  local path = StadiumInstall.romPath()
  if not path then return false, "no ROM in " .. StadiumInstall.ROM_DIR end

  local okRead, bytes = pcall(f.read, path)
  if not (okRead and type(bytes) == "string") then
    return false, "could not read " .. path
  end
  return StadiumInstall.beginFrom(bytes, path)
end

-- The same, from bytes somebody else has already got hold of -- which is the
-- IMPORTED path (StadiumRomPick), where the file is at an absolute location
-- love.filesystem cannot see and was read with io.open.
--
-- The two entry points share everything from here down on purpose: an
-- imported cartridge and a dropped one produce the same 151 files, the same
-- marker and the same md5, so there is exactly one build in this mod and no
-- second one to keep in step.
--
-- `label` is only ever used to say WHICH file a complaint is about.
function StadiumInstall.beginFrom(bytes, label)
  local f = fs()
  if not f then return false, "no filesystem" end
  if type(bytes) ~= "string" or #bytes == 0 then return false, "empty file" end

  local StadiumRom = V.require("StadiumRom")
  local StadiumBuild = V.require("StadiumBuild")
  local rom, err = StadiumRom.open(bytes)
  if not rom then return false, tostring(err) end
  status.wrongVersion = false
  if not rom:isExpectedUS() then
    -- Built anyway rather than refused: a dump can differ from the reference
    -- for reasons that do not move a single model offset (a byte-order
    -- variant already normalised on load, a trimmed overdump). But every
    -- offset in this reader was measured against US 1.0 and nothing else is
    -- promised, so it is said loudly, with the md5 that IS expected so the
    -- player can check their own file against it.
    status.wrongVersion = true
    V.mod.log:warn("stadium: %s is md5 %s -- the model offsets are keyed to "
                   .. "Pokemon Stadium (US) 1.0, which is md5 %s. Building "
                   .. "anyway, but the models may be wrong or fail to build.",
                   tostring(label or "the ROM"), tostring(rom:md5()),
                   tostring(StadiumRom.US_MD5))
  end

  -- ------- refuse a ROM with no models in it, BEFORE anything is written
  --
  -- A file picker invites the wrong file -- most obviously the Game Boy
  -- cartridge the player already imported once -- and the reader's answer to
  -- one is a model count of zero. That has to be caught HERE rather than
  -- allowed to become an empty build, because an empty build is
  -- indistinguishable from a finished one further down: `job.total` is
  -- clamped to the count, `step` completes on the first call with nothing
  -- attempted and therefore nothing FAILED, and the marker gets written
  -- saying the current format has zero models.
  --
  -- On a fresh machine that is merely a lie on the loading screen -- READY,
  -- with no models. On one that already HAD them it is worse: the marker is
  -- the only thing that makes 151 files on disk count as installed, so
  -- overwriting it with a zero uninstalls a good set and the STADIUM rungs
  -- vanish off the row. Nothing below this line runs for a file that cannot
  -- possibly produce a build.
  local models = rom:modelCount()
  if not (models and models >= StadiumInstall.COUNT) then
    return false, "needs Pokemon Stadium US 1.0"
  end

  pcall(f.createDirectory, StadiumInstall.DIR)
  job = StadiumBuild.job(rom, writePack, StadiumInstall.COUNT)
  job.md5 = rom:md5()
  status.state = "building"
  status.done = 0
  status.total = job.total
  status.error = nil
  return true
end

-- One species. Returns true while there is more to do.
function StadiumInstall.step()
  if not job then return false end
  local more = job:step()
  status.done = job.done
  status.species = job.species
  if job.error then
    status.state = "failed"
    status.error = job.error
    job = nil
    return false
  end
  if not more then
    local f = fs()
    -- `job.total > 0` as well as "nothing failed", because a job with nothing
    -- IN it satisfies the second on its own -- and the marker this writes is
    -- what makes a set count as installed, so it must never be written for a
    -- build that did not happen. beginFrom refuses such a ROM outright; this
    -- is the same rule stated where the consequence is.
    local wrote = #job.failed == 0 and job.total > 0
    if wrote and f then
      pcall(f.write, StadiumInstall.MARKER,
            ("%s %d %s %d\n"):format(StadiumInstall.FORMAT, job.total,
                                     tostring(job.md5 or ""),
                                     StadiumInstall.REV))
      readyCache = nil
      StadiumPack.forget()
    end
    if not wrote then
      status.state = "failed"
      -- EVERY species failing is not a bad build, it is the wrong file: the
      -- offsets the reader walks are Pokemon Stadium's, so a different game
      -- -- or the Game Boy cartridge the player already imported once, which
      -- is the mistake a file picker invites -- misses on all 151 rather than
      -- on a few. Worth telling apart, because "0 of 151 models were built"
      -- reads as a broken mod and this reads as a wrong click.
      if #job.failed >= job.total then
        status.error = "needs Pokemon Stadium US 1.0"
      else
        status.error = ("%d of %d models could not be built")
                       :format(#job.failed, job.total)
      end
    else
      status.state = "done"
    end
    job = nil
    return false
  end
  return true
end

function StadiumInstall.cancel()
  job = nil
  status.state = "idle"
end

return StadiumInstall
