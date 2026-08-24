-- Dramaless Shape 2.0: voxel environments for gen1recomp.
-- Native 2D voxel battles work standalone; StadiumBattleFX owns the modular
-- selector/host and all Stadium model presentation when it is installed.

local mod = ...
mod.exports.version = "2.0.3"

local V = { mod = mod, path = mod.path }
local modules, dataFiles = {}, {}
local module_path = mod.path .. "/lib/"

local function chunkFor(rel)
  local source = mod:read(rel)
  if not source then error(("DRAMALESS_SHAPE: missing %s"):format(rel), 0) end
  local chunk, err = load(source, "@" .. mod.path .. "/" .. rel)
  if not chunk then error(("DRAMALESS_SHAPE: %s did not compile: %s"):format(rel, err), 0) end
  return chunk
end

function V.require(name)
  if modules[name] ~= nil then return modules[name] end
  local value = chunkFor("lib/" .. name .. ".lua")(V)
  modules[name] = value
  return value
end

-- newly added in 2.0.3, replaces the previous way of loading the modules
-- not ready yet, must test it first. the old function may be fine.
-- function V.require(name)
--   if modules[name] ~= nil then return modules[name] end
--   local value = require(module_path .. name .. "lua")
--   if value then
--     modules[name] = value
--     return value
--   else
--     mod.log:error("[DRAMALESS_SHAPE] Could not load a required module. Mod will not work.")
--     return nil
--   end
-- end

function V.data(name)
  if dataFiles[name] ~= nil then return dataFiles[name] end
  local value = chunkFor("data/" .. name .. ".lua")(V)
  dataFiles[name] = value
  return value
end

local Log = V.require("DramalessLog")
V.log = Log.new(mod.log)
V.log:event("runtime", "session-start", { version = mod.exports.version })

local KEY_VOXEL, KEY_GRID, KEY_TILT, KEY_CURVE = "v", "g", "t", "c"
V.KEYS = { voxel = KEY_VOXEL, grid = KEY_GRID, tilt = KEY_TILT, curve = KEY_CURVE }

local Voxel = V.require("VoxelState")
local Voxel3D = V.require("Voxel3D")
local VoxelScene = V.require("VoxelScene")
local TiltShift = V.require("TiltShift")
local ChunkMesher = V.require("ChunkMesher")
local MapElevation = V.require("MapElevation")
local VoxelPrecache = V.require("VoxelPrecache")
local VoxelLoadingVeil = V.require("VoxelLoadingVeil")
local VoxelGrid = V.require("VoxelGrid")
local WorldCurve = V.require("WorldCurve")
local DayNight = V.require("DayNight")
local DayTint = V.require("DayTint")
local Water = V.require("Water")
local Shadows = V.require("Shadows")
local AntiAlias = V.require("AntiAlias")
local FirstPerson = V.require("FirstPerson")
local FreeMove = V.require("FreeMove")
local CamControl = V.require("CamControl")
local Quality = V.require("Quality")
local PoisonFlash = V.require("PoisonFlash")

local applyFull

local function sceneSize(ctx)
  if love.graphics and love.graphics.getPixelDimensions then
    local w, h = love.graphics.getPixelDimensions()
    if w and h and w > 0 and h > 0 then return w, h end
  end
  return ctx.width, ctx.height
end

local voidFill = { last = nil }
function voidFill.check()
  local now = require("src.render.TileRenderer").voidFill
  if voidFill.last ~= nil and now ~= voidFill.last then
    ChunkMesher.invalidate()
    V.log:event("mesh", "void-fill-invalidated", {})
  end
  voidFill.last = now
end

-- The ELEVATION setting is baked straight into chunk mesh vertex
-- positions at build time (see ChunkMesher.elevAt), not read fresh per
-- frame like most settings, so flipping it needs the same full-rebuild
-- reaction void-fill above already gets for the same reason. Polled here
-- rather than off "mod.options_changed" -- that event fires reliably from
-- the mod manager's own settings page, but the quick in-game OPTIONS row
-- writes the value through ModSetting:setIndex directly and was observed
-- not to raise it at all.
local elevationCheck = { last = nil }
function elevationCheck.check()
  local now = MapElevation.enabled()
  if elevationCheck.last ~= nil and now ~= elevationCheck.last then
    ChunkMesher.invalidate()
    V.log:event("mesh", "elevation-invalidated", {})
  end
  elevationCheck.last = now
end

mod.content.render_pipelines:register("voxel", {
  label = "VOXEL",
  levels = Voxel.ANGLE_LABELS,
  hotkey = KEY_VOXEL,
  priority = 20,
  available = function() return Voxel3D.available() end,
  update = function(dt, level)
    applyFull(level)
    Voxel.update(dt, level)
    FirstPerson.update(dt)
    DayNight.update(dt)
    voidFill.check()
    elevationCheck.check()
    if not Voxel.active() then return end
    local Game = require("src.core.Game")
    local ow = Game and Game.overworld
    if ow and ow.map and ow.camera then
      pcall(VoxelScene.prefetch, ow)
      pcall(VoxelPrecache.update, Game)
    end
    ChunkMesher.pump(Game and Game.stack and Game.stack:top() ~= ow)
  end,
  drawWorld = function(ctx)
    -- Terrain and characters are geometry; the field FX stay ordinary 2D
    -- draws composited on top, anchored through the same camera the 3D
    -- pass used (ctx.drawFx below).  The scene renders at the window's
    -- PIXEL resolution (see sceneSize) so the 3D pass is crisp rather than
    -- a magnified low-res image, while the FX closures keep drawing in
    -- world-pixel units.
    local sw, sh = sceneSize(ctx)
    local rw, rh = AntiAlias.expand(sw, sh)
    local canvas = VoxelScene.render(ctx.state, rw, rh, ctx.vw, ctx.vh, ctx.paletteFor)
    if not canvas then
      local map = ctx.state and ctx.state.map
      if map and not ChunkMesher.slotKnown(map, false) then
        return VoxelLoadingVeil.get(sw, sh)
      end
      return nil
    end
    if Voxel3D.beginOverlay() then
      ctx.drawFx(function(wx, wy) return Voxel3D.project(wx, 0, wy) end,
        ctx.scale * AntiAlias.factor())
      Voxel3D.endOverlay()
    end
    return AntiAlias.resolve(canvas, sw, sh, "world")
  end,
  invalidate = function()
    Voxel3D.invalidate()
    AntiAlias.invalidate()
    VoxelLoadingVeil.invalidate()
    ChunkMesher.invalidate()
    V.log:event("graphics", "invalidated", {})
  end,
})

mod.content.render_pipelines:register("tiltshift", {
  label = "T-SHIFT",
  levels = TiltShift.LABELS,
  hotkey = KEY_TILT,
  priority = 10,
  update = function(dt, level) TiltShift.update(dt, level) end,
  worldPresent = function(canvas) return TiltShift.apply(canvas) end,
  invalidate = function() TiltShift.invalidate() end,
})

local fullWas
applyFull = function(level)
  local full = Voxel.isFull(level)
  local previous = fullWas
  fullWas = full
  if not full or previous == true or previous == nil then return end
  local Game = require("src.core.Game")
  local Pipelines = require("src.render.Pipelines")
  local Zoom = require("src.render.Zoom")
  local opts = Game.save and Game.save.options
  if not opts then return end
  Pipelines.setLevel("tiltshift", Pipelines.maxLevel("tiltshift"))
  Pipelines.syncOptions(opts)
  WorldCurve.setting:setIndex(1, Game)
  Water.setting:setIndex(1, Game)
  opts.zoom = 0
  Zoom.applyOptions(opts)
  DayNight.forceSync(Game)
  if Game.writeOptions then pcall(Game.writeOptions, Game) end
  V.log:event("options", "full-preset-applied", {})
end

-- Dramaless keeps its original native-card presentation controls. Stadium
-- model ownership moved to SBFX; this setting did not.
local BackSpritesSetting = V.require("ModSetting").new(
  "battleBack", "BACK SPRITES", { false, true }, { "OFF", "ON" })
V.backSpritesSetting = BackSpritesSetting

-- Used only when StadiumBattleFX is absent. With Stadium installed the same
-- card renderer is controlled by Stadium's BTL MODELS selector instead.
local VoxelBattleSetting = V.require("ModSetting").new(
  "voxel_2d_battles", "VOXEL ARENA + 2D CARDS",
  { false, true }, { "OFF", "ON" }, 2)

local CARD_PROVIDER_ID = "DRAMALESS_SHAPE:voxel-cards"
local function stadiumBattleApi()
  if not (mod and type(mod.find) == "function") then return nil end
  local ok, found = pcall(mod.find, "STADIUM_BATTLE_FX")
  return ok and found and found.exports and found.exports.battles or nil
end

local function cardBattlesEnabled()
  local api = stadiumBattleApi()
  if api and type(api.selectedId) == "function" then
    local ok, selected = pcall(api.selectedId, api, "models")
    return ok and selected == CARD_PROVIDER_ID
  end
  return VoxelBattleSetting:get() and true or false
end

local SETTINGS = {
  { VoxelGrid.setting, "One-pixel wireframe along every voxel edge." },
  { WorldCurve.setting, "Bend the world down over the horizon." },
  { DayNight.setting, "Choose DAY, NIGHT, DUSK, DAWN, CYCLE, or clock-synced lighting." },
  { Water.setting, "Reflections on water: FULL, SKY, or OFF." },
  { Shadows.setting, "Enable voxel-world cast shadows.", full = true },
  { AntiAlias.setting, "Supersample the voxel world for smoother geometry edges.", full = true },
  { Quality.setting, "Choose the voxel render resolution scale.", full = true },
  { Quality.renderDistanceSetting, "Choose the render distance.", full = true },
 -- { Quality.shadowSetting, "Choose full, low-cost, or disabled cast shadows.", full = true },
  { BackSpritesSetting,
    "Keep your own Pokemon on the battle menu, seen from behind in its original slot, while the foe remains a world card.",
    when = cardBattlesEnabled, full = true },
  { VoxelScene.silhouetteSetting,
  "Draw silhouettes for characters hidden behind voxel geometry. "
  .. "OFF disables the silhouette pass completely." },
  { MapElevation.setting,
  "Render ledges, hills and terraces with real elevation instead of a "
  .. "flat plane. OFF returns every map to the flat ground it always had." },
    -- 1ST's own look input, not a diorama knob -- offered whether or not FULL
    -- is on, and only while there's a first-person rung to look with.
  { FirstPerson.invertLookY,
    "Invert the right stick's up/down look in 1ST: pull back to look up, "
    .. "push forward to look down.",
    when = function() return FirstPerson.engaged() end, full = true },
}

local schema = {}
for i, entry in ipairs(SETTINGS) do schema[i] = entry[1]:schema(entry[2]) end
schema[#schema + 1] = VoxelBattleSetting:schema(
  "Use a fully 3D voxel-map arena with native Gen 1 2D battle cards when StadiumBattleFX is absent.")
mod.options:define(schema)

local HOTKEYS = {
  [KEY_VOXEL] = "pipeline", [KEY_TILT] = "pipeline",
  [KEY_GRID] = VoxelGrid.setting, [KEY_CURVE] = WorldCurve.setting,
  ["9"] = Water.setting,
}

do
  local Game = require("src.core.Game")
  local Pipelines = require("src.render.Pipelines")
  local inner = Game.keypressed
  function Game:keypressed(key)
    local claim = HOTKEYS[key]
    local top = self.stack and self.stack:top()
    if claim and not (top and top.onKeyPressed) then
      if claim == "pipeline" then
        local stepped = false
        if key == KEY_VOXEL then
          if Pipelines.canToggle("voxel", top, self.overworld) then
            Pipelines.setLevel("voxel", Voxel.nextHotkeyLevel(Pipelines.level("voxel")))
            stepped = true
          end
        else
          stepped = Pipelines.hotkey(key, top, self.overworld) and true or false
        end
        if stepped then
          Pipelines.syncOptions(self.save.options)
          self.save.options.tilt, self.save.options.gbcfx = 0, 0
          require("src.render.Tilt").setLevel(0)
          require("src.render.GBCFX").setLevel(0)
          self:writeOptions()
          V.log:event("options", "hotkey", { key = key })
          return
        end
      elseif Pipelines.canToggle("voxel", top, self.overworld) then
        claim:cycle(self)
        V.log:event("options", "hotkey", { key = key })
        return
      end
    end
    return inner(self, key)
  end
end

local function insertGrouped(out, extra)
  local anchor
  for i, row in ipairs(out) do
    local id = type(row) == "table" and row.id
    if id == "pipeline:voxel" or id == "pipeline:tiltshift" then anchor = i end
  end
  if not anchor then
    for _, row in ipairs(extra) do out[#out + 1] = row end
    return out
  end
  for i, row in ipairs(extra) do table.insert(out, anchor + i, row) end
  return out
end

local function dropRow(out, id)
  for i = #out, 1, -1 do
    if type(out[i]) == "table" and out[i].id == id then table.remove(out, i) end
  end
end

local function pinEngineFx(game)
  game = game or require("src.core.Game")
  local opts = game and game.save and game.save.options
  local changed = opts and ((opts.tilt or 0) ~= 0 or (opts.gbcfx or 0) ~= 0)
  if opts then opts.tilt, opts.gbcfx = 0, 0 end
  pcall(require("src.render.Tilt").setLevel, 0)
  pcall(require("src.render.GBCFX").setLevel, 0)
  if changed and game.writeOptions then pcall(game.writeOptions, game) end
end

mod.hooks:wrap("ui.options.rows", function(next, game, rows)
  local out = next(game, rows)
  if type(out) ~= "table" then return out end
  pinEngineFx(game)
  dropRow(out, "tilt")
  dropRow(out, "gbcfx")
  local full = Voxel.isFull(require("src.render.Pipelines").level("voxel"))
  if full then
    DayNight.forceSync(game)
    dropRow(out, "pipeline:tiltshift")
  end
  local extra = {}
  for _, entry in ipairs(SETTINGS) do
    if (not entry.when or entry.when()) and (entry.full or not full) then
      extra[#extra + 1] = entry[1]:row()
    end
  end
  local hasStadium = false
  if mod.find then
    local ok, found = pcall(mod.find, "STADIUM_BATTLE_FX")
    hasStadium = ok and found and true or false
  end
  if not hasStadium then extra[#extra + 1] = VoxelBattleSetting:row() end
  extra[#extra + 1] = V.require("DramalessLogExport").row()
  return insertGrouped(out, extra)
end)

mod.events:on("mod.options_changed", function(payload)
  if not (payload and payload.mod == mod.id) then return end
  for _, entry in ipairs(SETTINGS) do
    if payload.key == entry[1].key then entry[1]:sync(payload.value) end
  end
  if payload.key == VoxelBattleSetting.key then
    VoxelBattleSetting:sync(payload.value)
    if payload.value == false then
      pcall(function() V.require("VoxelBattleStandalone").finish("option-disabled") end)
    end
  end
  if Voxel.isFull(require("src.render.Pipelines").level("voxel")) then
    DayNight.forceSync()
  end
  V.log:event("options", "changed", { key = payload.key, value = payload.value })
end)

mod.events:on("world.block_replaced", function(payload)
  local mapId = payload and (payload.mapId or (payload.map and payload.map.id))
  if mapId then
    ChunkMesher.refresh(mapId)
    V.log:event("mesh", "block-refresh", { map = mapId })
  end
end)

do
  local Map = require("src.world.Map")
  if not Map.dramalessShapeBlockHook then
    local setBlock = Map.setBlock
    Map.setBlock = function(self, bx, by, block)
      local before = self:blockAt(bx, by)
      setBlock(self, bx, by, block)
      if self.id and self:blockAt(bx, by) ~= before then
        ChunkMesher.refresh(self.id)
      end
    end
    Map.dramalessShapeBlockHook = true
  end
end

mod.events:on("map.reloaded", function(payload)
  if payload and payload.reason == "colors" then return end
  local mapId = payload and (payload.mapId or (payload.map and payload.map.id))
  if mapId then ChunkMesher.invalidate(mapId) end
end)

do
  local OptionsMenu = require("src.ui.OptionsMenu")
  if not OptionsMenu.dramalessShapeFullHook then
    local Pipelines = require("src.render.Pipelines")
    local inner = OptionsMenu.update
    function OptionsMenu:update(dt)
      local before = Pipelines.level("voxel")
      inner(self, dt)
      local after = Pipelines.level("voxel")
      if after ~= before and (Voxel.isFull(before) or Voxel.isFull(after)) then
        local rebuilt = OptionsMenu.new(self.game)
        self.rows = rebuilt.rows
        self.index = math.min(self.index or 1, #self.rows + 1)
      end
    end
    OptionsMenu.dramalessShapeFullHook = true
  end
end

FirstPerson.install()
FreeMove.install()
CamControl.install()
PoisonFlash.install()
DayTint.install()

mod.events:on("save.writing", function() DayNight.store() end)
local function restore(payload)
  local save = payload and payload.save
  if save and Voxel.seedOptions(save.options) then
    require("src.render.Pipelines").applyOptions(save.options)
  end
  DayNight.restore()
  pinEngineFx()
end
mod.events:on("save.loaded", restore)
mod.events:on("save.created", restore)

mod.hooks:wrap("world.tod", function(next, tod, ctx)
  local out = next(tod, ctx)
  return out ~= tod and out or DayNight.tod()
end)

local arenaProvider = V.require("VoxelBattleArenaProvider")
local cardProvider = V.require("VoxelBattleCardProvider")
local standaloneBattle = V.require("VoxelBattleStandalone")
local bridge = V.require("StadiumBattleFxBridge")

-- Original Dramaless world cards use the player's front illustration and
-- mirror it toward the foe. BACK SPRITES deliberately keeps the native back
-- illustration instead. Preserve sprite-replacement mods by asking next()
-- first, exactly as the legacy compositor did.
mod.hooks:wrap("pokemon.sprite", function(next, path, ctx)
  local out = next(path, ctx)
  if not (ctx and ctx.kind == "battle" and ctx.side == "back") then return out end
  if not cardBattlesEnabled() or BackSpritesSetting:get() then return out end
  local def = ctx.data and ctx.data.pokemon and ctx.data.pokemon[ctx.species]
  return (def and def.spriteFront) or out
end)
local function registerArena()
  local ok, value, modelValue = bridge.retry(arenaProvider, cardProvider)
  if ok then
    V.log:event("integration", "stadium-battle-providers-registered", {
      arena = value,
      models = modelValue,
    })
  elseif bridge.lastError ~= "StadiumBattleFX battle API 1 is unavailable" then
    V.log:event("integration", "stadium-provider-registration-failed", { error = value })
  end
end
registerArena()
mod.events:on("mods.loaded", function()
  registerArena()
  if not bridge.registered and VoxelBattleSetting:get() then
    local ok, installed = pcall(standaloneBattle.install)
    if not ok then
      V.log:error("standalone voxel 2D battle hook failed: %s", tostring(installed))
    else
      V.log:event("integration", "standalone-voxel-2d-ready", {
        installed = installed and true or false,
      })
    end
  end
end)

mod.hooks:wrap("input.step", function(next, game, dt)
  local result = next(game, dt)
  if not bridge.registered and VoxelBattleSetting:get() then
    standaloneBattle.update(dt)
  end
  return result
end)

mod.events:on("battle.started", function(payload)
  if bridge.registered or not VoxelBattleSetting:get() then return end
  local ok, err = pcall(standaloneBattle.install)
  if not ok then
    V.log:error("standalone voxel 2D battle reattachment failed: %s", tostring(err))
    return
  end
  standaloneBattle.begin(payload and payload.battle, arenaProvider, cardProvider)
end)

mod.events:on("battle.ended", function()
  if not bridge.registered then standaloneBattle.finish("battle.ended") end
end)

mod.exports.voxelArenaProvider = arenaProvider
mod.exports.voxelCardProvider = cardProvider
mod.exports.voxel2DBattleHost = standaloneBattle
mod.exports.lib = V
mod.exports.module_path = module_path