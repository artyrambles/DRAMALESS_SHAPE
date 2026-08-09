-- Public battle-preset composition for Dramaless Shape.
--
-- The original 3D-BTL setting was a closed five-value ladder.  Four values
-- selected one of Dramaless's own combinations (GB cards or Stadium models,
-- on the map or on discs), and OFF selected the engine battle screen.  That
-- is a good set of defaults, but it made another mod choose between replacing
-- the entire battle backend and patching private Dramaless modules.
--
-- This module turns those combinations into FALLBACKS.  A companion mod adds
-- a named preset, points it at one fallback, and supplies only the component
-- slots it owns.  A camera mod can therefore replace `camera` while inheriting
-- the stage and battlers; a model mod can replace `battlers` while inheriting
-- Dramaless's map/disc staging.  There is deliberately no priority number:
-- every custom preset is an equal choice on the 3D-BTL row, and the player
-- decides which one is active.
--
-- Dramaless itself currently consumes the `stage` and `battlers` slots.  The
-- resolver accepts any non-empty slot name so companion mods can compose a
-- larger contract (animations, camera, effects, lighting, HUD) without a
-- second registry.  Such slots become meaningful to Dramaless itself as the
-- corresponding backend seams are adopted.

local V = ...

local BattlePresets = {}

-- Public sentinel for a provider which was asked at runtime and cannot serve
-- this battle.  Returning nil from a provider method is an ordinary Lua
-- command result; returning FALLBACK explicitly asks the caller to continue
-- down the preset's declared fallback chain.
BattlePresets.FALLBACK = {}

BattlePresets.ID_2D_A = "dramaless:2d-a"
BattlePresets.ID_2D_B = "dramaless:2d-b"
BattlePresets.ID_STADIUM_A = "dramaless:stadium-a"
BattlePresets.ID_STADIUM_B = "dramaless:stadium-b"
BattlePresets.ID_OFF = "dramaless:off"

-- Stored values are intentionally unchanged.  Old options files continue to
-- read exactly as they did before this API existed; only custom presets use a
-- canonical owner:id string as their stored value.
local legacyToId = {
  [true] = BattlePresets.ID_2D_A,
  flatB = BattlePresets.ID_2D_B,
  stadium = BattlePresets.ID_STADIUM_A,
  stadiumB = BattlePresets.ID_STADIUM_B,
  [false] = BattlePresets.ID_OFF,
}

local idToLegacy = {
  [BattlePresets.ID_2D_A] = true,
  [BattlePresets.ID_2D_B] = "flatB",
  [BattlePresets.ID_STADIUM_A] = "stadium",
  [BattlePresets.ID_STADIUM_B] = "stadiumB",
  [BattlePresets.ID_OFF] = false,
}

-- A stage is a provider just like a battler renderer.  Keeping the map search
-- and generated-disc construction behind this tiny interface is what lets a
-- third-party preset replace one without impersonating the other.
local mapStage = { id = "map", portable = false, discs = false }
function mapStage:arena(ctx, state)
  local BattleArena = V.require("BattleArena")
  local ok, arena = pcall(BattleArena.find, state.map,
                          state.player.cellX, state.player.cellY,
                          state.player.surfing)
  return (ok and arena) or BattlePresets.FALLBACK
end

local discStage = {
  id = "discs", portable = true, replacesMap = true, discs = true,
}
function discStage:arena(ctx, state)
  local ok, arena = pcall(function()
    return V.require("StadiumStage").arena(state.map)
  end)
  -- 2D-B and STADIUM-B both inherit an A preset.  If a driver cannot build
  -- the generated stage, this explicit decline follows that inheritance and
  -- attempts the map instead of dropping the battle immediately.
  return (ok and arena) or BattlePresets.FALLBACK
end
function discStage:cast(ctx, shadowMap, arena, groundY)
  return V.require("StadiumStage").cast(shadowMap, arena, groundY)
end
function discStage:draw(ctx, arena, groundY)
  return V.require("StadiumStage").draw(arena, groundY)
end

-- Stadium predates this provider contract and exposes plain functions rather
-- than colon methods.  The adapter is intentionally boring: it preserves the
-- proven Stadium implementation while making it one provider among any number
-- of model mods.  Third-party providers implement the method-shaped surface
-- documented in docs/BATTLE_PRESETS.md.
local stadiumBattlers = { id = "dramaless:stadium-battlers" }
local function stadium() return V.require("Stadium") end
function stadiumBattlers:available() return stadium().enabled() end
function stadiumBattlers:install() return stadium().install() end
function stadiumBattlers:begin(ctx, arena) return stadium().begin(arena) end
function stadiumBattlers:finish() return stadium().finish() end
function stadiumBattlers:update(ctx, dt, battle, groundY)
  return stadium().update(dt, battle, groundY)
end
function stadiumBattlers:covers(ctx, battle, side)
  return stadium().covers(battle, side)
end
function stadiumBattlers:standing() return stadium().standing() end
function stadiumBattlers:cast(ctx, shadowMap) return stadium().cast(shadowMap) end
function stadiumBattlers:draw(ctx, pull) return stadium().draw(pull) end
function stadiumBattlers:invalidate() return stadium().invalidate() end
function stadiumBattlers:report(ctx, err) return stadium().report(err) end
function stadiumBattlers:attachment(ctx, side, tag)
  return stadium().attachment(side, tag)
end
function stadiumBattlers:hit(ctx, side, effectiveness)
  return stadium().hit(side, effectiveness)
end

-- Component entries use `{ provider = value, available = fn }` rather than
-- treating every table or function specially.  A provider is allowed to be a
-- table, function, scalar token, or false; false is an explicit "none" and
-- stops fallback, whereas an absent component continues to the next preset.
local function component(provider, available)
  return { provider = provider, available = available }
end

local builtins = {
  [BattlePresets.ID_2D_A] = {
    id = BattlePresets.ID_2D_A, label = "2D-3D A", builtin = true,
    components = { stage = component(mapStage), battlers = component(false) },
  },
  [BattlePresets.ID_2D_B] = {
    id = BattlePresets.ID_2D_B, label = "2D-3D B", builtin = true,
    fallback = BattlePresets.ID_2D_A,
    components = { stage = component(discStage) },
  },
  [BattlePresets.ID_STADIUM_A] = {
    id = BattlePresets.ID_STADIUM_A, label = "STADIUM A", builtin = true,
    fallback = BattlePresets.ID_2D_A,
    components = { battlers = component(stadiumBattlers) },
    available = function()
      local ok, install = pcall(V.require, "StadiumInstall")
      return ok and install and install.available()
    end,
  },
  [BattlePresets.ID_STADIUM_B] = {
    id = BattlePresets.ID_STADIUM_B, label = "STADIUM B", builtin = true,
    fallback = BattlePresets.ID_2D_B,
    components = { battlers = component(stadiumBattlers) },
    available = function()
      local ok, install = pcall(V.require, "StadiumInstall")
      return ok and install and install.available()
    end,
  },
  [BattlePresets.ID_OFF] = {
    id = BattlePresets.ID_OFF, label = "OFF", builtin = true,
    components = { stage = component(false), battlers = component(false) },
  },
}

local custom = {}
local setting = nil
local warned = {}

local function ownerActive(preset)
  if not (preset and preset.owner) then return true end
  local mod = V.mod
  if not (mod and type(mod.find) == "function") then return true end
  local ok, handle = pcall(mod.find, mod, preset.owner)
  return ok and handle ~= nil
end

local function logFailure(key, fmt, ...)
  if warned[key] then return end
  warned[key] = true
  local mod = V.mod
  if mod and mod.log and mod.log.warn then mod.log:warn(fmt, ...) end
end

local function canonical(value)
  if legacyToId[value] then return legacyToId[value] end
  if type(value) == "string" and value ~= "" then return value end
  return BattlePresets.ID_2D_A
end

function BattlePresets.id(value) return canonical(value) end

function BattlePresets.storedValue(id)
  id = canonical(id)
  if idToLegacy[id] ~= nil then return idToLegacy[id] end
  -- false cannot be detected through `~= nil`, so handle OFF explicitly.
  if id == BattlePresets.ID_OFF then return false end
  return id
end

function BattlePresets.get(value)
  local id = canonical(value)
  return custom[id] or builtins[id]
end

local function customList()
  local out = {}
  for _, preset in pairs(custom) do out[#out + 1] = preset end
  -- Equal priority must not accidentally become load priority.  Labels make
  -- the player-facing order pleasant; owner:id makes equal labels stable on
  -- every machine regardless of filesystem or dependency traversal order.
  table.sort(out, function(a, b)
    local al, bl = a.label:lower(), b.label:lower()
    if al ~= bl then return al < bl end
    return a.id < b.id
  end)
  return out
end

function BattlePresets.list()
  local out = {
    builtins[BattlePresets.ID_2D_A],
    builtins[BattlePresets.ID_2D_B],
    builtins[BattlePresets.ID_STADIUM_A],
    builtins[BattlePresets.ID_STADIUM_B],
  }
  for _, preset in ipairs(customList()) do out[#out + 1] = preset end
  -- OFF remains the final escape hatch even when many companion mods add
  -- choices; a player can always step once past the last custom preset.
  out[#out + 1] = builtins[BattlePresets.ID_OFF]
  return out
end

function BattlePresets.choices()
  local values, labels = {}, {}
  for _, preset in ipairs(BattlePresets.list()) do
    values[#values + 1] = BattlePresets.storedValue(preset.id)
    labels[#labels + 1] = preset.label
  end
  return values, labels
end

local function refreshSetting()
  if not setting then return end
  local values, labels = BattlePresets.choices()
  setting:replaceChoices(values, labels)
end

function BattlePresets.bindSetting(value)
  setting = value
  refreshSetting()
end

-- Register one equal-standing player choice.  `owner` is the registering
-- mod's manifest id and `localId` is private to it; namespacing here prevents
-- two unrelated mods from colliding without inventing priority rules.
function BattlePresets.register(owner, localId, def)
  assert(type(owner) == "string" and owner ~= "", "battle preset owner is required")
  assert(type(localId) == "string" and localId:match("^[%w_.-]+$"),
    "battle preset id must contain only letters, numbers, dot, dash or underscore")
  assert(type(def) == "table", "battle preset definition is required")
  assert(def.priority == nil,
    "battle presets have equal priority; use fallback and component ownership")
  assert(type(def.label) == "string" and def.label ~= "",
    "battle preset label is required")
  assert(type(def.components) == "table", "battle preset components are required")

  local id = owner .. ":" .. localId
  assert(not builtins[id] and not custom[id], "battle preset already registered: " .. id)

  local fallbackValue = def.fallback
  if fallbackValue == nil then fallbackValue = BattlePresets.ID_2D_A end
  local fallback = canonical(fallbackValue)
  assert(fallback ~= id, "battle preset cannot fall back to itself: " .. id)

  local components = {}
  for slot, spec in pairs(def.components) do
    assert(type(slot) == "string" and slot ~= "", "battle component name is required")
    -- A plain value is convenience for static providers.  The expanded form
    -- supplies a per-component availability gate without changing the value.
    if type(spec) == "table" and spec.provider ~= nil then
      components[slot] = { provider = spec.provider, available = spec.available }
    elseif spec == false then
      components[slot] = component(false)
    else
      components[slot] = component(spec)
    end
  end

  custom[id] = {
    id = id, owner = owner, label = def.label, fallback = fallback,
    components = components, available = def.available,
    description = def.description,
  }
  refreshSetting()
  return id
end

function BattlePresets.available(value, ctx)
  local preset = BattlePresets.get(value)
  if not preset then return false end
  -- Export calls are outside the engine content-registry journal. If a
  -- dependent mod registers and then fails later in its entry point, mod.find
  -- stops exposing it; treating that owner as unavailable prevents a ghost
  -- preset from surviving the failed load.
  if not ownerActive(preset) then return false end
  if not preset.available then return true end
  local ok, available = pcall(preset.available, ctx, preset)
  if not ok then
    logFailure("available:" .. preset.id,
      "battle preset %s availability failed: %s", preset.id, tostring(available))
    return false
  end
  return available and true or false
end

-- Called after the loader has finalized every mod. Failed dependents are
-- removed entirely so the manager schema is refreshed as well as the in-game
-- gate. Normal disable/reload starts a new Dramaless module and a fresh table.
function BattlePresets.pruneInactive()
  local changed = false
  for id, preset in pairs(custom) do
    if not ownerActive(preset) then custom[id], changed = nil, true end
  end
  if changed then refreshSetting() end
  return changed
end

-- Return providers from the selected preset through its fallback chain.
-- Missing slots continue; false is included as a terminal provider because
-- it means "this component is deliberately absent", not "I do not own it".
function BattlePresets.providers(value, slot, ctx)
  assert(type(slot) == "string" and slot ~= "", "battle component name is required")
  local out, seen = {}, {}
  local id = canonical(value)
  while id and not seen[id] do
    seen[id] = true
    local preset = custom[id] or builtins[id]
    if not preset then break end
    -- An unavailable preset contributes no components, but its fallback still
    -- does. This matters when a custom preset inherits Stadium on a machine
    -- without extracted packs: the chain reaches 2D cards instead of handing
    -- out a provider whose prerequisite is absent.
    local presetAllowed = BattlePresets.available(preset.id, ctx)
    local spec = presetAllowed and preset.components and preset.components[slot]
    if spec then
      local allowed = true
      if spec.available then
        local ok, answer = pcall(spec.available, ctx, preset)
        allowed = ok and answer and true or false
        if not ok then
          logFailure("component:" .. preset.id .. ":" .. slot,
            "battle preset %s component %s availability failed: %s",
            preset.id, slot, tostring(answer))
        end
      end
      if allowed then
        local provider = spec.provider
        if provider ~= nil then
          out[#out + 1] = { provider = provider, preset = preset }
          if provider == false then break end
        end
      end
    end
    id = preset.fallback and canonical(preset.fallback) or nil
  end
  if id and seen[id] then
    logFailure("cycle:" .. id,
      "battle preset fallback cycle reached %s; the cycle was stopped", id)
  end
  return out
end

function BattlePresets.component(value, slot, ctx)
  local list = BattlePresets.providers(value, slot, ctx)
  local first = list[1]
  -- Do not use `first and first.provider or nil`: false is a meaningful,
  -- terminal provider (explicitly disable this component), not absence.
  if not first then return nil, nil end
  return first.provider, first.preset
end

function BattlePresets.uses(value, slot, provider, ctx)
  local selected = BattlePresets.component(value, slot, ctx)
  return selected == provider
end

function BattlePresets.stadiumBattlers()
  return stadiumBattlers
end

-- Generic public resolver for slots Dramaless does not consume yet.  This is
-- intentionally data-only: lifecycle dispatch belongs to the subsystem that
-- understands a component's method contract.
function BattlePresets.resolve(value, slot, ctx)
  return BattlePresets.component(value, slot, ctx)
end

return BattlePresets
