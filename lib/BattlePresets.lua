-- Public battle-preset composition for Dramaless Shape.
--
-- The original 3D-BTL setting was a closed five-value ladder.  Four values
-- selected one of Dramaless's own combinations (GB cards or Stadium models,
-- on the map or on discs), and OFF selected the engine battle screen.  That
-- is a good set of defaults, but it made another mod choose between replacing
-- the entire battle backend and patching private Dramaless modules.
--
-- This module turns those combinations into FALLBACKS and, more importantly,
-- exposes an independent selector for every presentation component. A player
-- can keep a Dramaless baseline while choosing an arena from mod A, battler
-- models from mod B, animations from mod C and an announcer from mod D. There
-- is deliberately no priority number: providers are equal catalog entries and
-- only the player's selection decides which one is active.
--
-- Named presets remain useful as one-click bundles and for compatibility, but
-- they are not required to mix mods. Every component selector has DEFAULT as
-- its first choice; DEFAULT inherits that component from the selected 3D-BTL
-- baseline. A selected mod provider falls back to that same baseline when it
-- declines a particular battle or fails safely at runtime.

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
BattlePresets.INHERIT = "dramaless:default"

-- Components with concrete Dramaless runtime dispatch. `stage` and
-- `battlers` have specialized contracts because they construct the arena and
-- decide whether each Game Boy card is covered. These slots share the generic
-- lifecycle documented below: begin, event, update, cast, drawWorld,
-- beforeScreen, drawScreen, afterScreen, invalidate and finish.
--
-- The order is deterministic but is NOT priority. It only makes callbacks
-- reproducible when several independently selected services are active (for
-- example animations, an announcer and a HUD). Provider choice happens on
-- each slot's own row; this order never lets one mod outrank another.
BattlePresets.RUNTIME_SLOTS = {
  "animations", "camera", "effects", "audio", "announcer",
  "hud", "overlay", "screen", "transitions", "presentation",
}

-- `stage` and `battlers` use specialized renderer contracts; the remaining
-- rows use the generic lifecycle. Keeping this catalog explicit gives the
-- options UI stable names and storage keys while provider dispatch stays open
-- enough for a catch-all `presentation` service.
BattlePresets.SELECTABLE_SLOTS = {
  { id = "stage", label = "BTL ARENA",
    help = "Choose the battle arena provider. DEFAULT uses the arena from 3D-BTL." },
  { id = "battlers", label = "BTL MODELS",
    help = "Choose Pokemon cards or model provider. DEFAULT uses 3D-BTL." },
  { id = "animations", label = "BTL ANIM",
    help = "Choose world-space battle animations from any installed mod." },
  { id = "camera", label = "BTL CAMERA",
    help = "Choose the battle camera provider from any installed mod." },
  { id = "effects", label = "BTL EFFECTS",
    help = "Choose particles and world post-processing from any installed mod." },
  { id = "audio", label = "BTL AUDIO",
    help = "Choose battle music and sound presentation from any installed mod." },
  { id = "announcer", label = "BTL VOICE",
    help = "Choose an announcer or spoken callout provider." },
  { id = "hud", label = "BTL HUD",
    help = "Choose the battle HUD provider from any installed mod." },
  { id = "overlay", label = "BTL OVERLAY",
    help = "Choose a battle overlay provider from any installed mod." },
  { id = "screen", label = "BTL SCREEN",
    help = "Choose a provider that may replace the complete battle screen." },
  { id = "transitions", label = "BTL TRANS",
    help = "Choose battle presentation transitions from any installed mod." },
  { id = "presentation", label = "BTL PRESENT",
    help = "Choose a catch-all presentation service from any installed mod." },
}

function BattlePresets.runtimeSlots()
  local out = {}
  for i, slot in ipairs(BattlePresets.RUNTIME_SLOTS) do out[i] = slot end
  return out
end

function BattlePresets.selectableSlots()
  local out = {}
  for i, item in ipairs(BattlePresets.SELECTABLE_SLOTS) do
    out[i] = { id = item.id, label = item.label, help = item.help }
  end
  return out
end

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
local componentCatalog = {}
local componentSettings = {}
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

local function slotDefinition(slot)
  for _, item in ipairs(BattlePresets.SELECTABLE_SLOTS) do
    if item.id == slot then return item end
  end
  return nil
end

local function componentList(slot)
  local out = {}
  for _, entry in pairs(componentCatalog[slot] or {}) do
    out[#out + 1] = entry
  end
  -- Alphabetical presentation, then a namespaced stable tie-breaker, is the
  -- whole priority model: every installed mod gets one equal player choice.
  table.sort(out, function(a, b)
    local al, bl = a.label:lower(), b.label:lower()
    if al ~= bl then return al < bl end
    return a.id < b.id
  end)
  return out
end

function BattlePresets.componentList(slot)
  local out = {}
  for i, entry in ipairs(componentList(slot)) do out[i] = entry end
  return out
end

function BattlePresets.componentChoices(slot)
  assert(slotDefinition(slot), "unknown selectable battle component: " .. tostring(slot))
  local values, labels = { BattlePresets.INHERIT }, { "DEFAULT" }
  for _, entry in ipairs(componentList(slot)) do
    values[#values + 1], labels[#labels + 1] = entry.id, entry.label
  end
  return values, labels
end

local function refreshComponentSetting(slot)
  local selectedSetting = componentSettings[slot]
  if not selectedSetting then return end
  local values, labels = BattlePresets.componentChoices(slot)
  selectedSetting:replaceChoices(values, labels)
end

-- Return the live settings used by both the in-game OPTIONS screen and the
-- mod-manager page. They are created lazily so registry-only tests and tools
-- can inspect this module without constructing UI state.
function BattlePresets.componentSettings()
  local ModSetting = V.require("ModSetting")
  local out = {}
  for _, item in ipairs(BattlePresets.SELECTABLE_SLOTS) do
    if not componentSettings[item.id] then
      local values, labels = BattlePresets.componentChoices(item.id)
      componentSettings[item.id] = ModSetting.new(
        "battle_component_" .. item.id, item.label, values, labels)
    end
    out[#out + 1] = {
      slot = item.id, setting = componentSettings[item.id], help = item.help,
    }
  end
  return out
end

function BattlePresets.componentSelection(slot)
  local selectedSetting = componentSettings[slot]
  return selectedSetting and selectedSetting:get() or BattlePresets.INHERIT
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

-- Register one independently selectable asset/provider. The same local id may
-- be reused in another slot because each options row has its own namespace;
-- within a slot, OWNER:local_id is unique and stable in saved options.
function BattlePresets.registerComponent(owner, slot, localId, def)
  assert(type(owner) == "string" and owner ~= "",
    "battle component owner is required")
  assert(slotDefinition(slot),
    "unknown selectable battle component: " .. tostring(slot))
  assert(type(localId) == "string" and localId:match("^[%w_.-]+$"),
    "battle component id must contain only letters, numbers, dot, dash or underscore")
  assert(type(def) == "table", "battle component definition is required")
  assert(def.priority == nil,
    "battle components have equal priority; the player selects the provider")
  assert(type(def.label) == "string" and def.label ~= "",
    "battle component label is required")
  assert(def.provider ~= nil, "battle component provider is required")

  local id = owner .. ":" .. localId
  componentCatalog[slot] = componentCatalog[slot] or {}
  assert(not componentCatalog[slot][id],
    "battle component already registered for " .. slot .. ": " .. id)
  componentCatalog[slot][id] = {
    id = id, owner = owner, slot = slot, label = def.label,
    provider = def.provider, available = def.available,
    description = def.description,
  }
  refreshComponentSetting(slot)
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
  for slot, entries in pairs(componentCatalog) do
    local slotChanged = false
    for id, entry in pairs(entries) do
      if not ownerActive(entry) then
        entries[id], changed, slotChanged = nil, true, true
      end
    end
    if slotChanged then refreshComponentSetting(slot) end
  end
  if changed then refreshSetting() end
  return changed
end

-- Return providers from the selected preset through its fallback chain.
-- Missing slots continue; false is included as a terminal provider because
-- it means "this component is deliberately absent", not "I do not own it".
function BattlePresets.providers(value, slot, ctx)
  assert(type(slot) == "string" and slot ~= "", "battle component name is required")
  local out, seen, providerSeen = {}, {}, {}
  local function append(provider, source)
    -- A provider selected independently may also be present in a bundle's
    -- baseline. Never activate the same object twice when it requests fallback.
    if providerSeen[provider] then return false end
    providerSeen[provider] = true
    out[#out + 1] = { provider = provider, preset = source }
    return provider == false
  end

  -- The component row has the first and only say over this slot. If its
  -- selected provider is unavailable, it simply contributes nothing and the
  -- selected 3D-BTL baseline below remains the safe fallback. We never try a
  -- different mod automatically because that would recreate hidden priority.
  local selectedId = BattlePresets.componentSelection(slot)
  local selected = selectedId ~= BattlePresets.INHERIT
                   and componentCatalog[slot]
                   and componentCatalog[slot][selectedId] or nil
  if selected and ownerActive(selected) then
    local allowed = true
    if selected.available then
      local ok, answer = pcall(selected.available, ctx, selected)
      allowed = ok and answer and true or false
      if not ok then
        logFailure("selected-component:" .. slot .. ":" .. selected.id,
          "battle component %s availability failed: %s",
          selected.id, tostring(answer))
      end
    end
    if allowed and append(selected.provider, selected) then return out end
  end

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
          if append(provider, preset) then break end
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
