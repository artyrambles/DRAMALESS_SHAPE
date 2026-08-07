-- One of this mod's own settings: a ladder of values, where it persists,
-- and the row the player cycles it on.
--
-- The engine gives a render pipeline all of this for free -- ladder,
-- options row, hotkey, persistence -- but only to something that OWNS a
-- pass of the frame. The voxel wireframe and the world curve do not: they
-- parameterise the voxel pass, so they have nothing to put in drawWorld or
-- present and the registry rightly rejects them. What is left is a plain
-- mod setting, and this is the boilerplate two of them would otherwise
-- each carry a copy of:
--
--   options:define   a home in options.modOptions.DRAMALESS_SHAPE, plus a row
--                    on this mod's page in the mod manager.
--   ui.options.rows  the same setting on the OPTIONS menu, where the
--                    player already goes for VOXEL and T-SHIFT.
--
-- Both rows read and write the one stored value, so they cannot disagree.
-- Writing mirrors what the manager's own page does (ManagerState:setOption):
-- the live save's options table, the loader's copy that mod.options:get
-- reads, and then the file.

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local ModSetting = {}
ModSetting.__index = ModSetting

local function modId()
  local mod = V.mod
  return (mod and mod.id) or "DRAMALESS_SHAPE"
end

-- `values` are the stored values in ladder order and `labels` what the row
-- shows for each; values[1] is the default, and the one an unreadable or
-- unrecognised stored value falls back to.
function ModSetting.new(key, label, values, labels)
  return setmetatable({
    key = key, label = label, values = values, labels = labels,
    index = nil,          -- nil = not yet read back from the persisted options
  }, ModSetting)
end

local function indexOf(self, value)
  for i, v in ipairs(self.values) do
    if v == value then return i end
  end
  return 1
end

-- ------- rungs that are not always there
--
-- A ladder may carry a rung that cannot be selected right now -- STADIUM
-- needs models built out of a ROM the player supplies, and until that has
-- happened there is nothing behind the option. `gate` is asked per rung and
-- decides whether it exists at all this frame.
--
-- Skipped rather than shown-and-refused, deliberately. A row that can be
-- cycled onto and then does nothing is indistinguishable from a broken mod;
-- a row that simply has fewer stops reads as the mod not offering something,
-- which is the truth. What the player is missing, and how to get it, is said
-- once in the row's help text instead of implied by a dead setting.
--
-- values[1] is never gated: it is the default and the fallback, so there is
-- always at least one rung to land on.
function ModSetting:setGate(gate)
  self.gate = gate
  return self
end

function ModSetting:allows(i)
  if i == 1 or not self.gate then return true end
  local ok, allowed = pcall(self.gate, self.values[i], i)
  return (not ok) or allowed and true or false
end

-- How many rungs are live, for a caller that wants to know whether a row is
-- worth showing at all.
function ModSetting:rungs()
  local n = 0
  for i = 1, #self.values do
    if self:allows(i) then n = n + 1 end
  end
  return n
end

-- What the player left it at last session. Read lazily rather than at load
-- time: the loader fills modOptions before a mod runs, but reading through
-- the API keeps this honest about where the value lives.
function ModSetting:read()
  if self.index then return self.index end
  local mod = V.mod
  local value
  if mod and mod.options then
    local ok, got = pcall(mod.options.get, mod.options, self.key)
    if ok then value = got end
  end
  self.index = indexOf(self, value)
  return self.index
end

function ModSetting:get()
  local i = self:read()
  -- a rung that was live when it was stored and is not now -- the player
  -- moved the ROM, or opened the same save on another machine -- reads as
  -- the default rather than as a mode with nothing behind it. The stored
  -- value is left alone, so putting the ROM back restores their choice.
  if not self:allows(i) then return self.values[1] end
  return self.values[i]
end

function ModSetting:level()
  return self:read() - 1
end

function ModSetting:setIndex(i, game)
  local n = #self.values
  i = ((i - 1) % n + n) % n + 1
  self.index = i
  local value, id = self.values[i], modId()
  local opts = game and game.save and game.save.options
  if opts then
    opts.modOptions = opts.modOptions or {}
    opts.modOptions[id] = opts.modOptions[id] or {}
    opts.modOptions[id][self.key] = value
  end
  local loader = game and game.mods
  if loader then
    loader.modOptions = loader.modOptions or {}
    loader.modOptions[id] = loader.modOptions[id] or {}
    loader.modOptions[id][self.key] = value
  end
  if game and game.writeOptions then pcall(game.writeOptions, game) end
  return value
end

-- Set by the STORED VALUE rather than by its place on the ladder, for a
-- caller that knows which setting it wants and not where it sits -- a
-- preset, or an assertion. An unrecognised value lands on values[1], the
-- same default indexOf answers everywhere else, so this can never leave a
-- setting holding something the row cannot display.
--
-- Worth having as its own entry point because a ladder's ORDER is not a
-- promise: 3D-BTL grew a third rung in the middle of itself (see
-- OverworldBattle), and every caller that had counted to two would have
-- silently meant something else afterwards.
function ModSetting:setValue(value, game)
  return self:setIndex(indexOf(self, value), game)
end

-- Step to the next rung that is actually live, in `dir`. Bounded by the
-- ladder's length so a gate that refuses everything still terminates on
-- values[1], which allows() never gates.
function ModSetting:cycle(game, dir)
  dir = dir or 1
  local n = #self.values
  local i = self:read()
  for _ = 1, n do
    i = ((i + dir - 1) % n + n) % n + 1
    if self:allows(i) then break end
  end
  return self:setIndex(i, game)
end

-- Adopt a value set from somewhere else (the mod manager's settings page,
-- which writes and persists on its own). Nothing to store: just move the
-- cached index so the next read agrees with it.
function ModSetting:sync(value)
  self.index = indexOf(self, value)
end

-- The descriptor src/ui/OptionRows.lua renders, in the shape the
-- ui.options.rows hook appends.
function ModSetting:row()
  local self_ = self
  return {
    id = "DRAMALESS_SHAPE:" .. self.key,
    label = self.label,
    -- the label of the rung actually in force, which is not the stored one
    -- when that rung has been gated away (see get)
    value = function()
      local i = self_:read()
      return self_.labels[self_:allows(i) and i or 1]
    end,
    step = function(game, dir)
      self_:cycle(game, dir)
      return true
    end,
  }
end

-- The row the mod manager's own settings page builds for this mod.
function ModSetting:schema(help)
  local choices = {}
  -- gated rungs are left off the manager's page too, so the two rows agree
  -- about what can be chosen
  for i, v in ipairs(self.values) do
    if self:allows(i) then choices[#choices + 1] = { self.labels[i], v } end
  end
  if #self.values == 2 and self.values[1] == false then
    return { key = self.key, type = "toggle", label = self.label,
             default = self.values[1], help = help }
  end
  return { key = self.key, type = "choice", label = self.label,
           choices = choices, default = self.values[1], help = help }
end

return ModSetting
