-- What the model build COSTS -- the numbers that decide whether it can run
-- on a phone.
--
--   luajit mods/DramaticShapeVoxelMod/tests/stadium_budget_test.lua [--rom=PATH]
--
-- Run from the PROJECT ROOT.
--
-- ------- why this is a test and not a note
--
-- The extraction is pure Lua on purpose -- no FFI, no native helper, no
-- second process -- specifically so it can run everywhere LOVE does, phones
-- included. That claim is about MEMORY as much as about which functions
-- exist: a desktop will not notice a transient peak that would have a mobile
-- OS kill the process, and the peak is not visible by reading the code.
--
-- So this measures it, and fails if the two things that must stay bounded
-- stop being bounded:
--
--   the WORKING SET must not grow with the number of species done, or the
--   build gets heavier the longer it runs and dies somewhere in the 140s
--
--   the PEAK must stay under a budget a phone can be expected to have
--   spare, on top of a game that is already running
--
-- The ROM itself is most of the floor and cannot be avoided -- the archive is
-- addressed by absolute offset -- so it is reported separately from the
-- per-species work built on top of it.

local args = {}
for _, a in ipairs({ ... }) do
  local k, v = a:match("^%-%-([%w_]+)=(.*)$")
  if k then args[k] = v end
end

local MOD = "mods/DramaticShapeVoxelMod"
local ROM = args.rom or (MOD .. "/model_extract/baseroms/us/baserom.z64")

-- How much headroom the whole build may take on top of the ROM, in MB. Sized
-- against the smallest thing this is expected to run on rather than against
-- what is convenient: a mid-range phone from several years ago, with a game
-- already resident.
local PEAK_BUDGET_MB = 220

-- How much the working set may drift between the first ten species and the
-- last ten, in MB. Not zero -- species differ in size by a factor of ten, and
-- the collector is not obliged to run on any particular schedule -- but a
-- genuine leak shows up here as tens of megabytes.
local DRIFT_BUDGET_MB = 24

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

local function mb()
  return collectgarbage("count") / 1024
end

-- A single collectgarbage() is not guaranteed to finish a cycle, and a
-- half-finished one reads tens of megabytes high -- which showed up here as
-- "settled" figures BELOW the baseline they were measured against. Run it
-- until the number stops moving.
local function settle()
  local last = mb()
  for _ = 1, 8 do
    collectgarbage("collect")
    local now = mb()
    if now >= last - 0.05 then return now end
    last = now
  end
  return mb()
end

-- The baseline is taken BEFORE the ROM is read, or the file is already on the
-- heap when it is measured and the ROM appears to cost nothing.
local base = settle()

local fp = io.open(ROM, "rb")
if not fp then
  io.stderr:write("no ROM at " .. ROM .. "\n")
  os.exit(2)
end
local romBytes = fp:read("*a")
fp:close()

local rom = assert(StadiumRom.open(romBytes))
local withRom = settle()

local peak, settled = withRom, {}
local bytes = 0
local t0 = os.clock()

for fileno = 0, StadiumRom.N_POKEMON - 1 do
  local res = assert(StadiumBuild.species(rom, fileno))
  bytes = bytes + #res.bytes
  -- the live peak, before the collector has been asked for anything: this is
  -- what the allocator actually had to find
  local live = mb()
  if live > peak then peak = live end
  -- and the settled working set, which is what must not creep
  settled[fileno + 1] = settle()
end

local dt = os.clock() - t0

local function avg(from, to)
  local sum = 0
  for i = from, to do sum = sum + settled[i] end
  return sum / (to - from + 1)
end

local first = avg(1, 10)
local last = avg(#settled - 9, #settled)
local drift = last - first

io.write(("ROM               %6.1f MB   (the file, held for the whole build)\n")
         :format(withRom - base))
io.write(("peak working set  %6.1f MB   (over the ROM)\n"):format(peak - withRom))
io.write(("settled, first 10 %6.1f MB\n"):format(first - withRom))
io.write(("settled, last 10  %6.1f MB\n"):format(last - withRom))
io.write(("drift             %+6.1f MB   (budget %.0f)\n")
         :format(drift, DRIFT_BUDGET_MB))
io.write(("total peak        %6.1f MB   (budget %.0f)\n")
         :format(peak, PEAK_BUDGET_MB))
io.write(("output            %6.1f MB in %.1fs (%.0f ms a species)\n")
         :format(bytes / 1e6, dt, dt * 1000 / StadiumRom.N_POKEMON))

local fail = false
if peak > PEAK_BUDGET_MB then
  io.write(("FAIL peak %.1f MB is over the %.0f MB budget\n")
           :format(peak, PEAK_BUDGET_MB))
  fail = true
end
if drift > DRIFT_BUDGET_MB then
  io.write(("FAIL the working set grew %.1f MB across the run -- something is "
            .. "being retained per species\n"):format(drift))
  fail = true
end
if fail then os.exit(1) end
io.write("PASS -- bounded working set, peak within budget\n")
