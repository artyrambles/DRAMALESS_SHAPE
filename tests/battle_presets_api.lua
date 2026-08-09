-- Public battle-preset composition: defaults, equal-priority ordering,
-- component inheritance and dynamic option-ladder refresh.

local modules = {
  StadiumInstall = { available = function() return true end },
  BattleArena = { find = function() return { kind = "map" } end },
  StadiumStage = { arena = function() return { kind = "discs" } end },
}
local warnings = {}
local V = {
  mod = { log = { warn = function(_, fmt, ...)
    warnings[#warnings + 1] = string.format(fmt, ...)
  end } },
  require = function(name)
    if modules[name] then return modules[name] end
    error("unexpected module: " .. tostring(name))
  end,
}

local BattlePresets = assert(loadfile("lib/BattlePresets.lua"))(V)

-- A persisted custom id can be read before its provider mod registers. Keep
-- the raw value so expanding the ladder later restores that selection.
V.mod.options = { get = function() return "LATE:preset" end }
local ModSetting = assert(loadfile("lib/ModSetting.lua"))(V)
local late = ModSetting.new("battles", "3D-BTL", { true, false }, { "A", "OFF" })
assert(late:get() == true)
late:replaceChoices({ true, "LATE:preset", false }, { "A", "LATE", "OFF" })
assert(late:get() == "LATE:preset")
V.mod.options = nil

local values, labels = BattlePresets.choices()
assert(values[1] == true and values[2] == "flatB")
assert(values[3] == "stadium" and values[4] == "stadiumB")
assert(values[5] == false)
assert(labels[1] == "2D-3D A" and labels[5] == "OFF")

-- A setting already published through options:define is refreshed when a
-- dependent mod registers later in the load order.
local refreshed = nil
BattlePresets.bindSetting({ replaceChoices = function(_, v, l)
  refreshed = { values = v, labels = l }
end })
assert(refreshed and #refreshed.values == 5)

local camera = { id = "camera:orbit" }
local models = { id = "actors:new" }
local modelPreset = BattlePresets.register("ZZ_MODELS", "new_mons", {
  label = "NEW MODELS",
  fallback = BattlePresets.ID_STADIUM_B,
  components = { battlers = models },
})
local cameraPreset = BattlePresets.register("AA_CAMERA", "orbit", {
  label = "CINEMATIC",
  fallback = modelPreset,
  components = { camera = camera },
})

assert(#refreshed.values == 7)
-- Custom choices are alphabetical and therefore independent of load or
-- manifest priority: CINEMATIC was registered second but is shown first.
assert(refreshed.labels[5] == "CINEMATIC")
assert(refreshed.labels[6] == "NEW MODELS")
assert(refreshed.labels[7] == "OFF")

-- Each component walks the same declared fallback chain independently.
assert(BattlePresets.resolve(cameraPreset, "camera") == camera)
assert(BattlePresets.resolve(cameraPreset, "battlers") == models)
local stage = BattlePresets.resolve(cameraPreset, "stage")
assert(stage and stage.discs == true)

-- Explicit false stops inheritance; omission is what requests inheritance.
local noActors = BattlePresets.register("NO_ACTORS", "empty", {
  label = "EMPTY",
  fallback = modelPreset,
  components = { battlers = false },
})
assert(BattlePresets.resolve(noActors, "battlers") == false)

-- A component may decline before battle time and expose its fallback.
local unavailable = BattlePresets.register("OPTIONAL", "camera", {
  label = "OPTIONAL CAMERA",
  fallback = cameraPreset,
  components = {
    camera = { provider = { id = "missing" },
               available = function() return false end },
  },
})
assert(BattlePresets.resolve(unavailable, "camera") == camera)

local stadiumFallback = BattlePresets.register("OPTIONAL", "stadium", {
  label = "OPTIONAL STADIUM",
  fallback = BattlePresets.ID_STADIUM_A,
  components = { camera = {} },
})
modules.StadiumInstall.available = function() return false end
assert(BattlePresets.resolve(stadiumFallback, "battlers") == false)
modules.StadiumInstall.available = function() return true end

-- The real ModSetting schema is held by the manager by reference. Late
-- registrations rewrite its choices as well as the in-game row.
local liveValues, liveLabels = BattlePresets.choices()
local liveSetting = ModSetting.new("battles", "3D-BTL", liveValues, liveLabels)
local liveSchema = liveSetting:schema("test")
BattlePresets.bindSetting(liveSetting)
local beforeSchema = #liveSchema.choices
BattlePresets.register("SCHEMA", "late", {
  label = "SCHEMA LATE", fallback = true, components = { camera = {} },
})
assert(#liveSchema.choices == beforeSchema + 1)

-- Priority is rejected rather than silently creating a hidden winner.
local ok, err = pcall(BattlePresets.register, "BAD", "priority", {
  label = "BAD", priority = 100, components = { stage = {} },
})
assert(not ok and tostring(err):find("equal priority", 1, true))

-- A mod which registers and then fails does not leave a ghost option behind
-- once the loader's mods.loaded event asks Dramaless to prune inactive owners.
V.mod.find = function(_, id)
  if id == "GHOST" then return nil end
  return { id = id }
end
local ghost = BattlePresets.register("GHOST", "failed", {
  label = "GHOST", components = { camera = {} },
})
assert(not BattlePresets.available(ghost))
assert(BattlePresets.pruneInactive())
assert(BattlePresets.get(ghost) == nil)
V.mod.find = nil

-- Unknown/cyclic fallbacks cannot hang resolution. A later preset may name
-- an earlier one, so cycles are detected while walking rather than rejected
-- at registration time.
local cycleA = BattlePresets.register("CYCLE", "a", {
  label = "CYCLE A", fallback = "CYCLE:b", components = { camera = {} },
})
BattlePresets.register("CYCLE", "b", {
  label = "CYCLE B", fallback = cycleA, components = { effects = {} },
})
assert(BattlePresets.resolve(cycleA, "hud") == nil)
assert(#warnings >= 1)

print("ok battle preset API")
