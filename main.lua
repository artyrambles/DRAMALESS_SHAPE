-- Dramaless Shape Voxel Mod: a full 3D diorama overworld, shipped as a
-- rendering pipeline mod featuring edits by Stahltier and code by BrenoBertucci.
--
-- The engine's render_pipelines registry (src/mods/Schemas.lua) lets a mod
-- own part of the frame.  This mod registers two:
--
--  st_voxel      a drawWorld pipeline.  Instead of the flat tile blit, the
--              overworld's terrain is extruded into real geometry, walked
--              by a depth-buffered 3D camera, with characters as leaning
--              sprite slabs and a shadow map throwing real cast shadows
--              across whatever they land on.  Occlusion is the depth
--              buffer, not a y-sort: walk behind a building and the
--              building is simply in front.
--
--   st_tiltshift  a worldPresent pipeline -- the stage that post-processes
--              the finished world BEFORE the UI composites over it.  A
--              tilt-shift blur that sells the miniature-model look, on the
--              diorama only, leaving text boxes and menus crisp.
--
-- Everything a display mode needs beyond the two draw functions -- the
-- OFF/15/35/50 ladder, the options rows, the hotkeys, persistence in
-- save.options.pipelines, the free-roam gate, the mutual exclusion with
-- the engine's TILT mode -- is engine plumbing driven by the records
-- below.  This file declares; lib/ draws.
--
-- Nothing here reaches collision, movement, triggers or scripts.  Voxel
-- mode is purely presentational: it changes what the world LOOKS like and
-- nothing about what it IS.

local mod = ...

-- ------- the mod namespace
--
-- lib/ modules require each other through V rather than package.path: a
-- mod directory is not on it, and may live inside a mounted .love archive
-- that plain require cannot reach.  Each module is loaded once, with V
-- passed in as its vararg (`local V = ...`).

local V = { mod = mod, path = mod.path }

-- Registry keys unique to this fork so DRAMATIC_SHAPE (upstream) can load
-- beside us without overwriting the same pipeline / transition slots.
local PIPE_VOXEL = "st_voxel"
local PIPE_TILT  = "st_tiltshift"
V.PIPE_VOXEL, V.PIPE_TILT = PIPE_VOXEL, PIPE_TILT

-- Letter keys: free of engine 2-5 and of upstream DRAMATIC_SHAPE's 3/5/6/7/8/9,
-- so both mods can be enabled without fighting for the same presses.
local KEY_VOXEL  = "v"   -- VOXEL camera ladder (skips FULL)
local KEY_GRID   = "g"   -- V-GRID wireframe
local KEY_TILT   = "t"   -- T-SHIFT blur
local KEY_CURVE  = "c"   -- V-CURVE horizon
local KEY_BATTLE = "b"   -- 3D-BTL
local KEY_WILD   = "n"   -- WILD roam ladder
local KEY_MAP    = "p"   -- minimap ON/FULL/OFF
V.KEYS = {
  voxel = KEY_VOXEL, grid = KEY_GRID, tilt = KEY_TILT,
  curve = KEY_CURVE, battle = KEY_BATTLE, wild = KEY_WILD, map = KEY_MAP,
}

local function chunkFor(rel)
  local source = mod:read(rel)
  if not source then
    error(("DRAMALESS_SHAPE: %s is missing -- reinstall the mod"):format(rel), 0)
  end
  local chunk, err = load(source, "@" .. mod.path .. "/" .. rel)
  if not chunk then
    error(("DRAMALESS_SHAPE: %s did not compile: %s"):format(rel, tostring(err)), 0)
  end
  return chunk
end

local modules = {}
function V.require(name)
  local hit = modules[name]
  if hit ~= nil then return hit end
  local value = chunkFor("lib/" .. name .. ".lua")(V)
  modules[name] = value
  return value
end

local dataFiles = {}
function V.data(name)
  local hit = dataFiles[name]
  if hit ~= nil then return hit end
  local value = chunkFor("data/" .. name .. ".lua")(V)
  dataFiles[name] = value
  return value
end

-- ------- pipelines

local Voxel = V.require("VoxelState")
local Voxel3D = V.require("Voxel3D")
local VoxelScene = V.require("VoxelScene")
local TiltShift = V.require("TiltShift")
local ChunkMesher = V.require("ChunkMesher")
local VoxelGrid = V.require("VoxelGrid")
local WorldCurve = V.require("WorldCurve")
local OverworldBattle = V.require("OverworldBattle")
local WildRoamers = V.require("WildRoamers")
local BattleExit = V.require("BattleExit")
local DayNight = V.require("DayNight")
local DayTint = V.require("DayTint")
local Quality = V.require("Quality")
local Wind = V.require("Wind")
local Water = V.require("Water")
local ForestAtmos = V.require("ForestAtmos")
local AntiAlias = V.require("AntiAlias")
local FirstPerson = V.require("FirstPerson")
local FreeMove = V.require("FreeMove")
local CamControl = V.require("CamControl")
local VR = V.require("VR")
local Light = V.require("Light")
local RayFX = V.require("RayFX")
local AmbientLife = V.require("AmbientLife")
local WindFX = V.require("WindFX")
local Weather = V.require("Weather")
local Sky = V.require("Sky")
local GroundFX = V.require("GroundFX")
local Ecology = V.require("Ecology")
local AmbientSound = V.require("AmbientSound")
local Interiors = V.require("Interiors")
local CityLife = V.require("CityLife")
local StreetLamps = V.require("StreetLamps")
local Carry = V.require("Carry")
local Shelter = V.require("Shelter")
local Routines = V.require("Routines")
local AutoFarm = V.require("AutoFarm")
local QoL = V.require("QoL")
local HiddenItems = V.require("HiddenItems")
local ExpShare = V.require("ExpShare")
local Comforts = V.require("Comforts")
local MiniMap = V.require("MiniMap")

-- Forward declaration: the voxel pipeline's update hook (registered below)
-- calls this, and it is defined further down with the settings it drives.
-- Declared rather than left global -- a mod writing to _G would leak into
-- every other mod's namespace.
local applyFull

-- The last VOID FILL the terrain was meshed under; see the update hook.
-- The scene canvas's size, in FRAMEBUFFER PIXELS.
--
-- `ctx.width/height` are the window measured in LOVE UNITS
-- (love.graphics.getDimensions), but the engine composites a pipeline's
-- returned canvas with `draw(canvas, 0, 0, 0, 1/dpiX, 1/dpiY)` -- a scale
-- that only covers the window when the canvas is at PIXEL resolution.
-- Sizing it in units costs the DPI scale TWICE: the canvas is that much
-- smaller, then it is drawn that much smaller again, so the diorama lands
-- in the top-left corner at 1/dpi of the screen.  Desktop never sees it --
-- units and pixels are the same thing there -- but on Android the DPI scale
-- is the display density (2.625 on a 420dpi panel), and the world came out
-- a third of the size in each direction.
--
-- So ask for the pixel dimensions rather than trusting the ctx.  That is
-- the number a fixed engine would hand over, so this keeps working either
-- way instead of double-correcting.  It also squares the FX pass: ctx.scale
-- is ALREADY in pixels per world pixel (Zoom.scale over Renderer:fitScale,
-- which measures the drawable), so the closures ctx.drawFx runs were being
-- scaled for a canvas 2.6x bigger than the one they drew into.
local function sceneSize(ctx)
  if love.graphics and love.graphics.getPixelDimensions then
    local pw, ph = love.graphics.getPixelDimensions()
    if pw and ph and pw > 0 and ph > 0 then return pw, ph end
  end
  return ctx.width, ctx.height
end

local voidFill = { last = nil }
function voidFill.check()
  local TileRenderer = require("src.render.TileRenderer")
  local now = TileRenderer.voidFill
  if voidFill.last ~= nil and now ~= voidFill.last then
    ChunkMesher.invalidate()   -- no map id: every ring on every map is stale
  end
  voidFill.last = now
end

mod.content.render_pipelines:register(PIPE_VOXEL, {
  label = "VOXEL",
  levels = Voxel.ANGLE_LABELS,
  -- Letter key (not the engine's 3/TILT): see hotkey block. Free of
  -- upstream DRAMATIC_SHAPE so both can be enabled together.
  hotkey = KEY_VOXEL,
  -- above tiltshift, so the two sort together in the options list with the
  -- mode first and its post-process under it
  priority = 20,

  -- Headless runs and drivers without a depth canvas or shader support
  -- answer false here, and the engine keeps the vanilla 2D path -- which
  -- is why no caller ever has to guard for a missing 3D pass.
  available = function()
    return Voxel3D.available()
  end,

  -- the engine hands over the live level; we ease the camera toward it.
  -- pump() advances queued mesh builds inside a few-millisecond budget,
  -- so entering voxel mode (and streaming neighbours while walking)
  -- costs frames nothing visible -- the old synchronous build froze the
  -- first frame for seconds. prefetch() runs here as well as in the
  -- draw, because update ticks even while a warp's Transition covers
  -- the screen: the destination's meshes start building the moment the
  -- map swaps behind the fade, and the fade-covered frames get a wider
  -- pump slice -- so stepping out of a door lands on terrain that is
  -- already there instead of a flat flash.
  update = function(dt, level)
    -- FULL is a preset, so it is applied ON THE PRESS rather than held every
    -- frame: it SETS the other rows and then leaves them alone. Holding them
    -- would make the zoom keys and the wheel dead while the mode was on, and
    -- would fight anyone who changed one deliberately.
    applyFull(level)
    Voxel.update(dt, level)
    -- the day/night clock, on the same always-running tick: Pipelines.update
    -- runs whatever the level, so time passes with the mode off, through
    -- battles and menus, and a CYCLE evening falls mid-fight exactly as it
    -- would mid-walk
    DayNight.update(dt)
    -- The overworld battle rides this hook rather than owning a pipeline of
    -- its own, because it owns no pass of the FRAME: it draws under a battle
    -- screen the engine composites, which is not a stage the registry has.
    -- What it needs is a tick that keeps running once the overworld stops
    -- being the top state, and this is one -- Game:update calls
    -- Pipelines.update unconditionally, so it survives the transition wipe
    -- and the whole battle. Ahead of the active() gate below, because a 3D
    -- battle does not require the free-roam mode to be switched on.
    OverworldBattle.update(dt)
    -- The one-time build of the Pokemon Stadium battle models out of the
    -- player's own ROM, if there is one to build from and it has not been
    -- done (see StadiumInstall). Rides this hook for the same reason the
    -- battle does -- it is the tick that runs whatever is on the stack -- and
    -- asks exactly once, on the first frame the player is actually in the
    -- world, so it is never fighting the engine's own launcher for the
    -- screen.
    pcall(function() V.require("StadiumScreen").maybePush() end)
    -- and a ROM the system file picker dropped in the save directory while
    -- we were not the top activity (Android; see StadiumRomPick.poll)
    pcall(function()
      V.require("StadiumRomPick").poll(require("src.core.Game"))
    end)
    -- The wild Pokemon standing in the grass ride the same hook for one of
    -- the same two reasons: it is the tick that keeps running whatever is on
    -- top, which is what lets the population notice a map arriving while a
    -- warp's transition still covers the screen. The other reason does not
    -- apply and the module gates on it itself -- nothing may be spawned into
    -- the world while a battle owns the cast list. Ahead of the active()
    -- gate, because what is standing in the grass is not a question about
    -- the camera.
    WildRoamers.update()
    -- The ambient life -- butterflies, fireflies, birds, wind-blown leaves
    -- -- keeps its clocks on the same tick, and gates itself down to the
    -- frames where there is a diorama on screen to be alive on.
    AmbientLife.update(dt, Voxel.active())
    -- The weather, on the same tick and AHEAD of everything that reads it.
    -- It is not a drawing with a clock, it is a clock several other things
    -- read: this call is what writes DayNight.overcast and Water.wet for the
    -- frame, so the sky, the hour's tint and the pond's glint all take their
    -- values from a shower that has already advanced rather than from the one
    -- before it. Ahead of the active() gate too, because a shower is a fact
    -- about Kanto and not about the camera -- it keeps building while you are
    -- in a fight, and the 2D world darkens under it either way.
    Weather.update(dt)
    -- and what the weather LEAVES: the ground soaking through a shower and
    -- drying out over the ten minutes after it, the snow settling and
    -- melting, the footprints filling back in. Immediately behind Weather,
    -- because it reads the number that call just wrote -- and ahead of the
    -- active() gate for the same reason the shower itself is: how wet the
    -- ground is is a fact about Kanto, so it keeps soaking while you are
    -- indoors, in a fight, or playing with the camera switched off.
    GroundFX.update(dt)
    -- and the air itself, made visible. BEHIND Weather, because the gust
    -- envelope it throws its fronts off is advanced by Wind.step and that
    -- call is inside Weather's tick -- reading it ahead of that would spawn
    -- every front one frame late and off the previous gust. Gated on the
    -- camera unlike the two above, and honestly so: dust blowing across a
    -- meadow is a DRAWING, not a fact about Kanto, and there is nothing for
    -- it to blow across on the flat 2D path.
    WindFX.update(dt, Voxel.active())
    -- and what it sounds like out there. Also ahead of the gate, and for a
    -- plainer reason than the weather's: a sound needs no camera, so the
    -- crickets come out at night on the flat 2D world too.
    AmbientSound.update(dt)
    -- The street Pokemon ride the same tick and gate themselves exactly
    -- like the wild ones do -- and like them, they are real map objects,
    -- so they walk the flat 2D world too.
    CityLife.update()
    -- and what the town DOES about the weather: when it comes down hard the
    -- civilians walk to the nearest door and stand in it, and the street
    -- Pokemon go in and are gone until it passes. Immediately BEHIND
    -- CityLife, because it drops that module's cast and sets the flag that
    -- stops it refilling the street behind them -- and behind Weather for
    -- the plainer reason that it reads the shower that call just advanced.
    Shelter.update()
    -- and what the people do the rest of the time. Behind Shelter because
    -- both write `facing` and the rain outranks a conversation: somebody
    -- walking to a door has already been taken out of the routine's hands
    -- (it skips anybody carrying `dsShelter`), and running them the other
    -- way round would spend a frame with the two disagreeing.
    Routines.update(dt)
    -- and the sleeper indoors, which is a real map object for the same
    -- reason and gates itself the same way. Its steam is a drawing and waits
    -- for the overlay; the cat itself is standing there in both modes.
    Interiors.update()
    -- and the quality-of-life watchers (auto-repel), same tick, same gates
    QoL.update()
    -- how much fits in the bag, kept in step with the two rows. Polled for
    -- the same reason voidFill is: the value can move from the OPTIONS row,
    -- the mod manager and applyOptions on a load, and none of them says so.
    Carry.update()
    -- what is buried on this map. Rebuilt only when the map CHANGES -- the
    -- glints re-check `hiddenTaken` per frame in the draw, so walking over
    -- one puts its own light out with nothing having to announce it.
    HiddenItems.update()
    -- VOID FILL picks the block the border ring is made of, and in this
    -- mode that ring is BAKED INTO THE MESH rather than drawn each frame.
    -- So the option has to reach the cache or nothing happens on screen
    -- until the meshes are dropped for some other reason -- which reads
    -- exactly like the option doing nothing at all. Polled rather than
    -- hooked because the engine changes it from three places (the options
    -- row, applyOptions on load, TileRenderer.setVoidFill) and none of
    -- them announces it. Ahead of the active() gate, so switching it
    -- while voxel mode is OFF still invalidates what is cached.
    voidFill.check()
    VR.update(dt)
    if not Voxel.active() then return end
    local Game = require("src.core.Game")
    local ow = Game and Game.overworld
    if ow and ow.map and ow.camera then
      pcall(VoxelScene.prefetch, ow)
    end
    -- COVERED says nothing of the world is on screen to hitch, which is
    -- worth four times the slice (see ChunkMesher's own note). Another
    -- scene on top of the stack is one way that happens. A WARP is the
    -- other, and it was the one missing: a door's fade is drawn BY the
    -- overworld, so the stack is still pointing AT the overworld for
    -- exactly the frames the fade is covering, and the test below answers
    -- "visible" for every one of them. Which is how the fat slice written
    -- for a door fade never once ran under a door fade. `transitioning`
    -- is the flag the rest of the mod already reads as "stand down, the
    -- screen is not the player's right now" (Weather, AmbientSound,
    -- WildRoamers all gate on it), and it is the honest answer here too.
    ChunkMesher.pump((Game and Game.stack and Game.stack:top() ~= ow)
                     or (ow and ow.transitioning) or false)
  end,

  drawWorld = function(ctx)
    -- VR support experimental...
    VR.paletteFor = ctx.paletteFor
    if VR.active() then
      local sw, sh = sceneSize(ctx)
      local m = VR.mirror(sw, sh)
      if m then return m end
    end
    -- Terrain and characters are geometry; the field FX stay ordinary 2D
    -- draws composited on top, anchored through the same camera the 3D
    -- pass used (ctx.drawFx below).  The scene renders at the window's
    -- PIXEL resolution (see sceneSize) so the 3D pass is crisp rather than
    -- a magnified low-res image, while the FX closures keep drawing in
    -- world-pixel units.
    local sw, sh = sceneSize(ctx)
    --local rw, rh = AntiAlias.expand(sw, sh)
    local canvas = VoxelScene.render(ctx.state, sw, sh,
                                     ctx.vw, ctx.vh, ctx.paletteFor)
    if not canvas then return nil end   -- fall back to the 2D path
    if Voxel3D.beginOverlay() then
      ctx.drawFx(function(wx, wy) return Voxel3D.project(wx, 0, wy) end,
                 ctx.scale * AntiAlias.factor()) -- anti-alias added back in
      -- the ambient life composites through the same overlay, anchored by
      -- the same camera -- but with its height honest, so a bird crossing
      -- at 40 world pixels is projected AT 40 world pixels
      AmbientLife.draw(Voxel3D.project, ctx.scale)
      -- the air, through the same projection and immediately behind the
      -- ambient life: a blown leaf and a streak of dust are the same wind
      -- carrying two different things, and they have to be composited
      -- together or the leaf reads as flying under its own power. Ahead of
      -- the weather for the same reason everything else is -- rain falls in
      -- front of what it is falling past.
      WindFX.draw(Voxel3D.project, ctx.scale)
      -- the steam off a mug and the Zs over a sleeping Meowth, indoors,
      -- through the same projection for the same reason
      Interiors.draw(Voxel3D.project, ctx.scale)
      -- the glint over a buried item, through the same projection -- and
      -- before the weather, so rain falls in FRONT of it the way it falls in
      -- front of everything else standing in the world
      HiddenItems.draw(Voxel3D.project, ctx.scale)
      -- and the weather LAST of the three, because rain is in front of
      -- everything by definition: its splashes are world-space and land
      -- among the rest of this, but its streaks fall between the camera and
      -- the whole diorama, so they have to be painted over it. The canvas
      -- size goes with them -- the streaks are screen-space and the surface
      -- they cross is this one, not the window (see sceneSize).
      Weather.draw(Voxel3D.project, ctx.scale, sw, sh)
      Voxel3D.endOverlay()
    end
    -- Orientation radar on the finished (upscaled) world canvas. Screen-
    -- space corner HUD -- not inside the RES-downsampled 3D pass. When
    -- T-SHIFT is on, worldPresent re-paints it AFTER the blur so the
    -- radar stays sharp (see tiltshift worldPresent below).
    MiniMap.present(canvas)
    --return canvas
    return AntiAlias.resolve(canvas, sw, sh, "world")
  end,

  invalidate = function()
    Voxel3D.invalidate()
    OverworldBattle.invalidate()
    AntiAlias.invalidate()
    ChunkMesher.invalidate()   -- no map id = every cached mesh
    -- the ground decals are GPU objects on the same footing: meshes and two
    -- generated strips, all rebuilt on demand
    GroundFX.dropGPU()
    Water.dropGPU()
    MiniMap.invalidate()
    ForestAtmos.invalidate()   -- shaft/particle meshes and shader sentinels
    VR.invalidate()            -- the mirror, and FBO ids of dead canvases
  end,
})

mod.content.render_pipelines:register(PIPE_TILT, {
  label = "T-SHIFT",
  levels = TiltShift.LABELS,
  -- Letter key (not upstream's 6): registry + wrap handle it.
  hotkey = KEY_TILT,
  priority = 10,

  update = function(dt, level)
    TiltShift.update(dt, level)
  end,

  -- worldPresent, not present: the blur belongs on the diorama, not on the
  -- dialog box in front of it.  A pass-through when the level is 0 or the
  -- shader is unavailable, so the frame is untouched in every other case.
  -- When the blur actually ran, re-paint the orientation radar on top so
  -- it is not smeared with the diorama (drawWorld already painted it once).
  worldPresent = function(canvas)
    canvas = TiltShift.apply(canvas)
    if (TiltShift.level or 0) > 0 then
      canvas = MiniMap.present(canvas)
    end
    return canvas
  end,

  invalidate = function()
    TiltShift.invalidate()
  end,
})

-- ------- this mod's own settings
--
-- Neither of these is a pipeline: they own no pass of the frame, they
-- PARAMETERISE the voxel one, so they have nothing to put in drawWorld or
-- present and the registry would rightly reject them.  Plain mod settings
-- instead -- see ModSetting for where they persist and how the two rows
-- each ends up on stay in step.

-- ------- the FULL preset
--
-- Everything the mode wants switched to at once. Applied when the VOXEL row
-- ARRIVES at FULL and not again, so the player can still move the camera or
-- the zoom afterwards -- it is a starting point, not a lock.
--
-- Leaving FULL deliberately does NOT undo any of it. A preset that reverted
-- would throw away whatever the player had changed since, and "put it back
-- how it was" is not a thing this can know.
local fullWas = nil

applyFull = function(level)
  local isFull = Voxel.isFull(level)
  local was = fullWas
  fullWas = isFull
  if not isFull or was == true or was == nil then return end

  local Game = require("src.core.Game")
  local Pipelines = require("src.render.Pipelines")
  local Zoom = require("src.render.Zoom")
  local opts = Game.save and Game.save.options
  if not opts then return end

  -- the miniature blur at its strongest: FULL is the diorama look, and the
  -- tilt-shift is most of what makes it read as a model
  Pipelines.setLevel(PIPE_TILT, Pipelines.maxLevel(PIPE_TILT))
  Pipelines.syncOptions(opts)
  -- the horizon flat. The curve bends the world away from a walking player,
  -- which fights a fixed diorama framing
  WorldCurve.setting:setIndex(1, Game)
  -- and the view fitted to the window
  opts.zoom = 0
  Zoom.applyOptions(opts)
  -- battles on the map too: FULL means the whole mode, and a fight is where
  -- half of it is spent. Set and then LET GO of -- unlike the rows above, both
  -- battle rows stay on the menu under FULL (see the rows hook), so this is
  -- where the preset puts them and not where they are held.
  OverworldBattle.setting:setIndex(1, Game)
  -- with both mons out there on it: BACK SPRITES keeps the player's own on the
  -- menu, which is the one part of the old screen FULL is least about. Set the
  -- same way, and changed back on the same row a keypress later.
  OverworldBattle.backSetting:setIndex(1, Game)
  -- and the battle screen the staged fight is composed for. WIDE re-lays that
  -- screen out on a 304x144 surface, which moves every anchor the arena camera
  -- is solved against (OverworldBattle.forceOG); FULL has just switched staged
  -- fights on, so the layout follows them.
  OverworldBattle.forceOG(Game)
  -- and the sky on the clock on the wall: FULL pins DAYTIME to SYNC. Unlike
  -- the rest of the preset this one IS held, not just set -- the row is off
  -- the menu while FULL owns it (the rows hook below), so a value changed
  -- under it could never be seen or changed back.
  DayNight.forceSync(Game)
  if Game.writeOptions then pcall(Game.writeOptions, Game) end
end

-- Whether a fight can be staged on the map, as far as the OPTIONS menu is
-- concerned: the 3D-BTL row, and nothing else.
--
-- It used to answer yes under FULL as well, on the grounds that FULL owned
-- that row and switched it on. FULL no longer owns it -- the row stays on the
-- menu under FULL and can be switched off there (see the rows hook) -- so that
-- clause would now claim staged battles for a preset the player had just
-- turned them off inside, pinning BATTLE LAYOUT to OG for a fight that is
-- never staged. The row is the only thing that decides, which is what every
-- other reader of this setting already believed: OverworldBattle.begin and
-- wantsFront both gate on enabled() alone.
--
-- Deliberately NOT gated on Voxel3D.available(): the engine offers a
-- pipeline's row whether or not the hardware can run it (Pipelines.rows), so
-- this mode's rows say ON on a machine without a depth buffer too, and a menu
-- that claims 3D battles are on must not also offer the layout they cannot be
-- drawn in.
local function stagedBattles()
  return OverworldBattle.enabled()
end

local SETTINGS = {
  -- `full` for the AA reason: additive shafts are fill rate, and under 4X
  -- supersampling that is a question about the hardware, not the look.
-- { ForestAtmos.setting,
--   "The air of the deep woods (Viridian Forest): a ground haze, and "
--   .. "volumetric light let down through the unseen canopy overhead -- "
--   .. "gold spears of sun by day, silver moon rays at night, pollen "
--   .. "drifting through the beams and fireflies once they cool. LOW "
--   .. "keeps the haze, halves the beam march and stands the particles "
--   .. "down. On a phone the row offers LOW alone: the beams need a "
--   .. "depth texture the pass can read back, and no mobile driver here "
--   .. "grants one.",
--   full = true },
-- `full` marks a row FULL does not take away. FULL owns the diorama's own
-- knobs; what a battle is drawn over, and how it is framed, are not that.
-- Off the OPTIONS menu while VR is on: the headset REQUIRES staged
-- battles (OverworldBattle.enabled answers true regardless of this row)
-- and forbids back sprites (backPinned answers false), so both rows
-- decide nothing there and a dead switch on the menu reads as broken.
{ OverworldBattle.setting,
  "Fight in three dimensions, shot over the shoulder with a slow parallax "
  .. "drift. 2D-3D stands the game's own battle pics up as cards; STADIUM "
  .. "replaces them with the Pokemon Stadium battle models, animated, "
  .. "playing the animation the move being used actually calls for. A "
  .. "stages the fight on the MAP -- the nearest clear ground, in that "
  .. "place's own weather and light; B stands it on two discs against the "
  .. "sky instead, which works everywhere, including the caves and shop "
  .. "floors that have nowhere to stage a fight. The STADIUM rungs only "
  .. "appear once the models have been built, and building them needs a "
  .. "Pokemon Stadium (US) 1.0 ROM of your own -- import it from the "
  .. "STADIUM ROM row, or drop it in the baseroms folder and restart. No "
  .. "other version works: the reader is keyed to that one cartridge.",
  when = function() return not VR.enabled() end, full = true },
-- Only offered while a fight can actually be staged on the map: with 3D-BTL
-- off the engine draws the classic screen, which is this row's ON already,
-- and a row that no longer decides anything is worse than no row.
{ OverworldBattle.backSetting,
  "Keep your own Pokemon on the battle menu, seen from behind in its "
  .. "original slot, instead of standing it on the map facing the foe. "
  .. "The foe is still out there on its own tile.",
  when = function() return stagedBattles() and not VR.enabled() end,
  full = true },
  -- `full` on both: FULL owns the rows that describe the LOOK, and what
  -- this device can afford to draw is not one of them. A preset that took
  -- the performance rows off the menu would be a preset a player on a slow
  -- phone could not climb back out of -- FULL is the heaviest thing this
  -- mod does, so it is exactly when these two need to be reachable.
  { Quality.setting,
    "How much of the panel's resolution the 3D pass renders at, before it "
    .. "is scaled back up. Lower is squarer and much faster -- this is the "
    .. "one that decides whether the diorama runs at all on a slow device.",
    full = true },
  { Quality.shadowSetting,
    "LOW keeps real cast shadows on a smaller map with a harder edge and "
    .. "no neighbouring maps casting. OFF drops the sun pass entirely and "
    .. "puts the flat drop shadows back under people's feet.",
    full = true },
  -- `full = true` as well, and for a plainer reason than the two above:
  -- FULL is the preset most people arrive at, and taking the wind off the
  -- menu there would hide the one row that decides whether the world looks
  -- alive.
  { Wind.setting,
    "Wind through the tall grass and the flowers, and the dust and spray "
    .. "it carries across open ground. AUTO hands the row itself to the "
    .. "climate: near-still on a calm night, breeze by day, and it reaches "
    .. "gale on its own under a front -- so a storm feels like a storm "
    .. "without you walking back to this menu. BREEZE and GALE are the two "
    .. "fixed windows onto that same living air; OFF is silence. The grass "
    .. "is geometry here: the base stays planted, the tip bends and DROPS "
    .. "as it goes over, each tuft has its own stiffness, rain weighs it "
    .. "down and damps it, settled snow bows it over, feet flatten it and "
    .. "it springs back.",
    full = true },
  { Water.setting,
    "The water surface as geometry rather than a scrolling picture: it "
    .. "rises and falls on two crossing swells, cel-shaded into flat "
    .. "dithered bands -- crests a shade lighter, troughs deeper -- with "
    .. "a hard-ringed toon glint where a crest turns into the sun, and "
    .. "white FOAM lapping the shoreline on the tide's own clock. FLAT "
    .. "is the old still plane.",
    full = true },
  { Light.setting,
    "SKY lights the world with two lights instead of one -- the sun, warm "
    .. "and directional, and the sky, cool and from everywhere. A shadow "
    .. "then reads as somewhere the SKY is lighting rather than as a dimmer, "
    .. "which is what makes it look outdoors. Indoors there is no sky, so "
    .. "shadows stay grey. FLAT is the single tint it used to be.",
    full = true },
  -- `full = true` for the same reason the two performance rows above have
  -- it: this is the row that costs the most per rung, so FULL -- the
  -- heaviest thing the mod does -- is exactly when it has to be reachable.
  { RayFX.setting,
    "Fake ray tracing: everything here is a ray marched across the depth "
    .. "buffer the 3D pass already filled, so it costs fetches rather than "
    .. "geometry. AO darkens the corners the sky cannot reach -- doorways, "
    .. "the foot of a wall, the gap between two trees. RT adds real "
    .. "reflections on the water: the ray leaves along the swell's own "
    .. "normal and lands on whatever is actually standing there, so the "
    .. "reflection travels with the crest carrying it. MAX adds light "
    .. "shafts through the gaps, marched toward the sun's own disc.",
    full = true },
  -- `full = true` for the same reason WIND has it: this is a row that
  -- decides whether the world looks alive, and FULL is the preset most
  -- people watch it from.
  { AmbientLife.setting,
    "Ambient life: butterflies and ground birds by day (the birds startle "
    .. "and fly off when you get close), dragonflies darting over the "
    .. "water, fireflies blinking through the night, a flock crossing the "
    .. "sky, leaves on the wind -- and civilian NPCs glance at you as you "
    .. "pass, then go back to what they were doing. Trainers never turn: "
    .. "their facing is their line of sight, and it stays theirs.",
    full = true },
  -- `full = true` for the reason AMBIENT has it: weather is not a knob on
  -- the camera, it is what the world is doing, and FULL is the preset most
  -- people are watching it from when it starts to rain.
  { Weather.setting,
    "Weather. AUTO gives the sky occasional showers -- a minute or two of "
    .. "rain every few, arriving and clearing on their own. Rain falls in "
    .. "two registers at once: flat cel-shaded streaks across the frame, "
    .. "leaning on the WIND row's own bearing, and splashes that open on "
    .. "the ground around you, standing in the world where the camera can "
    .. "move past them. The whole sky goes over with it -- the bands lose "
    .. "their blue to a flat stratus, the light drops and goes cool on the "
    .. "diorama AND on the flat 2D world, a sunset behind the front loses "
    .. "its gold, and the water loses its glint and gains chop, because "
    .. "rain breaks every crest that was catching the sun. The heaviest of "
    .. "it brings lightning, and the thunder arrives after the flash by "
    .. "however far away the strike was. SNOW drifts instead, in the "
    .. "diorama rather than across the lens, and AUTO chooses it on its own "
    .. "through the winter of the same clock the DAYTIME row's SYNC rung "
    .. "follows.",
    full = true },
  -- `full = true` like WEATHER: clouds are what the sky is doing, not a
  -- camera filter, and FULL is where people watch a storm roll in.
  { Sky.cloudSetting,
    "Volumetric clouds in the sky pass -- cel density, checker-dithered, "
    .. "pushed along by the WIND row. ON keeps a few fair-weather puffs that "
    .. "thicken into a deck as a shower builds (DayNight.overcast). THICK is "
    .. "a heavy sky even on a clear hour. OFF is bands only. Step count "
    .. "follows the RES row so a phone never raymarches what it cannot "
    .. "afford; at 1/4 the clouds switch off with the other ornaments.",
    full = true },
  -- `full = true` like WEATHER, and for the same reason: what the ground is
  -- doing after a shower is what the world is doing, not a knob on the
  -- camera. Offered only while the WEATHER row can produce something to
  -- leave behind -- with the sky pinned OFF there is never a puddle to draw,
  -- and a row that decides nothing is worse than no row.
  { GroundFX.setting,
    "What the weather LEAVES on the ground. Puddles gather through a shower "
    .. "and are still there for the ten minutes after it, hashed off the "
    .. "cell so the same low corner of the same yard holds water every time "
    .. "-- and they wear the SKY's own colour, because a puddle is a piece of "
    .. "the sky lying on the ground and one that stayed grey through a sunset "
    .. "would be the only thing on screen not taking part in the evening. "
    .. "Snow settles in drifts that thicken as it falls, and everybody "
    .. "walking on it -- you, the NPCs, the wild Pokemon in the grass -- "
    .. "leaves a trail of prints behind them that fills back in over half a "
    .. "minute, faster while it is still coming down. All of it is drawn as "
    .. "geometry BETWEEN the ground and the people standing on it, so it "
    .. "takes the hour's light and the sun's shadows and never paints over "
    .. "anybody's feet -- which is also why it wants the VOXEL camera on, "
    .. "like the steam off a mug.",
    when = function() return Weather.enabled() end, full = true },
  -- `full = true` because it is not a knob on the look at all: it is what
  -- the place sounds like, and a preset that owns the camera has no business
  -- taking the crickets away.
  { AmbientSound.setting,
    "The sound of the place: crickets after dark, birdsong through the "
    .. "morning and the day, water moving whenever there is water within a "
    .. "few cells of you, rain when it rains and thunder after the flash. "
    .. "They are BEDS rather than beeps -- crossfaded by what the world is "
    .. "doing, so nightfall brings the crickets up instead of switching "
    .. "them on, and walking away from a river takes the river down. Rain "
    .. "keeps playing indoors, quieter and pitched down, because that is "
    .. "what a roof is for. CC0 recordings, with the Game Boy's own "
    .. "channels underneath as the fallback if a file is missing. Sits "
    .. "under the map's own music and obeys the SFX volume row. Works with "
    .. "the diorama off: a sound needs no camera.",
    full = true },
  -- `full = true` like TOWN, and for the same reason: these are things
  -- standing in rooms, not a setting on the pass that draws them.
  { Interiors.setting,
    "Houses that somebody lives in. About two in five have a Pokemon "
    .. "asleep on the floor -- usually the family Meowth, wearing its own "
    .. "art, curled against a wall and out of the doorway. Press A and it "
    .. "stirs, yawns its own cry and goes back to sleep; it never wanders "
    .. "and never wants a fight. Which house has one is decided by the "
    .. "house's own name, so it is always the same Pokemon asleep in the "
    .. "same corner rather than a different one each time you walk in. And "
    .. "mugs left on the tables, still steaming -- found through the mod's "
    .. "own shape profile, so a table it has never been told about gets one "
    .. "as soon as somebody pins it. The sleeper stands in the room in both "
    .. "modes; the steam and the Zs are drawn into the diorama, so those two "
    .. "want the VOXEL camera on.",
    full = true },
  -- `full = true` like WILD, and for the same reason: this is what the
  -- streets are made of, not a knob on the camera.
  { CityLife.setting,
    "Pokemon in the streets: trainers' companions and strays out in the "
    .. "towns, wearing their own art, wandering like anybody else. Most "
    .. "are just out for a stroll -- press A to hear them. About one in "
    .. "three STARES you down as you pass: that one wants to battle, at "
    .. "your own lead's level, and pressing A lets you accept or walk on.",
    full = true },
  -- `full = true` for the same reason CityLife's is: this is what the streets
  -- are made of. Both rows are people rather than pixels.
  { Shelter.setting,
    "Everybody goes in out of the rain. When a shower comes down hard the "
    .. "town's wandering civilians walk to the nearest door and stand in "
    .. "it until it passes, and the street Pokemon go inside and are gone "
    .. "until the sky clears. Trainers, shopkeepers and anybody a script "
    .. "is talking to stay exactly where the map put them.",
    when = function() return Weather.enabled() end, full = true },
  -- `full = true` like the other rows that are not about the look at all:
  -- this is what fits in the bag, and a camera preset has no business
  -- shrinking a player's carrying capacity.
  { Carry.setting,
    "How many DIFFERENT items the bag holds. Gen 1 allows twenty, which is "
    .. "most of the way gone on the HMs, the TMs and the key items before a "
    .. "single Potion goes in. MAX is 999 against a game that ships about a "
    .. "hundred and ten items -- you cannot fill it. Set 20 for the "
    .. "original.",
    full = true },
  { Carry.stackSetting,
    "How many of ONE item the bag holds. Gen 1 stops at ninety-nine. Note "
    .. "that a single purchase is still capped at ninety-nine by the shop's "
    .. "own quantity box -- what this lifts is the size of the PILE, so you "
    .. "can go back and buy more. Set 99 for the original.",
    full = true },
  { Routines.setting,
    "The people have something to do. Civilians look around, turn toward "
    .. "the sign or the door they are standing beside, and stand in pairs "
    .. "facing each other having a conversation -- then go back to the way "
    .. "the map drew them. Nobody moves off their cell: this is where they "
    .. "are LOOKING, so no script, no gate guard and no shop counter "
    .. "changes. Trainers are never touched.",
    full = true },
  -- `full = true` because this row is not about the look at all -- it is a
  -- bot, and a preset that owns the camera has no business taking it away.
  -- { AutoFarm.setting,
  --   "Auto-farm: pick a party slot and a bot trains that Pokemon -- walks "
  --   .. "the grass, starts fights, always picks the strongest move against "
  --   .. "what it is facing, runs from a fight it is losing, and answers "
  --   .. "the learn-a-move prompt by VALUE, so a good move is never thrown "
  --   .. "away for a useless one. The chosen Pokemon leads the party while "
  --   .. "it runs, and below half health the bot drinks potions from the "
  --   .. "bag, weakest first. Stops on its own -- and sets itself OFF -- "
  --   .. "only when PP runs out or HP is critical with an empty bag.",
  --   full = true },
  -- `full = true` like the battle rows: none of this is a knob on the
  -- diorama, and a preset that owns the look has no business taking a
  -- player's conveniences away.
  { QoL.setting,
    "Quality of life, seven mercies in one switch. HIDDEN ITEMS GLINT on "
    .. "the ground -- the eighty-odd items Gen 1 buries with no way to find "
    .. "them but pressing A on every tile. It does not name them and does "
    .. "not take them: you still have to notice, walk there and press A. "
    .. "HOLD B TO RUN on the "
    .. "overworld -- ten frames a step against sixteen, and it stands down "
    .. "on the bike, which is still faster. FIELD POISON STOPS AT 1 HP "
    .. "instead of killing: it still needs an Antidote, it just cannot walk "
    .. "a Pokemon into a black-out. TRADE EVOLUTIONS happen at level 37 "
    .. "without a second machine, so Alakazam, Machamp, Golem and Gengar "
    .. "exist in a solo game -- a real trade still evolves them instantly. "
    .. "Plus effectiveness markers "
    .. "on the battle move menu (+ super effective, - resisted, x immune, "
    .. "against the Pokemon actually in front of you); a fresh REPEL used "
    .. "from the bag the moment one wears off; and HMs on the A button -- "
    .. "A at a tree CUTs it, A facing water SURFs, A at a boulder wakes "
    .. "STRENGTH, all behind the same badges and party checks the menu "
    .. "applies. Plus three more: a BAG SORTED INTO POCKETS -- balls, "
    .. "medicine, TMs and HMs, key items -- that wraps top to bottom and "
    .. "takes a held direction, instead of twenty slots in pickup order; the "
    .. "PC following a catch into whichever BOX it landed in, and rolling a "
    .. "full box forward instead of refusing the deposit; and RENAME on the "
    .. "party menu beside STATS and SWITCH, because Kanto has no NAME RATER "
    .. "and a nickname typed in a hurry at level 5 is otherwise forever. "
    .. "OFF is the full 1996 friction.",
    full = true },
  -- Its own row rather than a tenth mercy on QOL, and the difference is real:
  -- everything on that row removes friction without touching the game's
  -- numbers, and this one changes the difficulty curve. A player who wants
  -- the conveniences and the original's pace can have both.
  { ExpShare.setting,
    "Experience for the whole team. Gen 1 pays only the Pokemon that "
    .. "fought, which is why a Gen 1 party is one Pokemon and five "
    .. "passengers -- the only way to bring a second one up is to send it "
    .. "out, let it take a hit and switch back, every battle, for the whole "
    .. "game. TEAM gives every Pokemon still standing what the fighters got, "
    .. "the way the series itself has worked since Gen 6. SPLIT divides that "
    .. "same total among them instead, so the party still moves together but "
    .. "the pace is the one the game was balanced on. Only the Pokemon that "
    .. "actually fought gets the text box, so a six-strong party does not "
    .. "cost six presses after every fight. OFF is the original's rule. "
    .. "Fainted Pokemon are paid nothing at every rung.",
    full = true },
  { VoxelGrid.setting, "One-pixel wireframe along every voxel edge." },
  { WorldCurve.setting,
    "Bend the world down over the horizon, Animal Crossing style." },
  { WildRoamers.setting,
    "Wild Pokemon you can see: the map's own encounter table decides who is "
    .. "standing in the grass right now, wearing their own art and wandering "
    .. "their own patch, and the fight starts when you walk into one. ROAM "
    .. "switches the blind roll off, so what you fight is what you walked "
    .. "into; MIX leaves it on as well; OFF is the dice alone.",
    full = true },
  -- Only offered while something is out there to count. With WILD OFF the
  -- number of them is zero whatever this says, and a row that no longer
  -- decides anything is worse than no row.
  { WildRoamers.countSetting,
    "How many wild Pokemon stand within reach at once. Each is one more "
    .. "sprite card in the frame, so FEW is the setting for a slow device.",
    when = function() return WildRoamers.enabled() end, full = true },
  -- `full = true` for the reason WILD has it: this is not a knob on the
  -- diorama, it is what is out there. Offered whatever WILD is set to,
  -- because it reaches the blind roll as well as the visible Pokemon --
  -- the engine's own encounter.species seam is where the dice get it.
  { Ecology.setting,
    "Who is out RIGHT NOW. Gen 2 gave every route a morning, a day and a "
    .. "night table and it is most of what made Johto feel like a place; "
    .. "this is that, built out of Gen 1's one table. Nothing is added to a "
    .. "route and nothing is taken away -- what moves is the ODDS: the "
    .. "nocturnal half of the dex (Zubat, Gastly, Oddish, Meowth, Drowzee "
    .. "and the rest of Gen 2's own night list) comes up after dark and "
    .. "thins out by noon, and the birds and the caterpillars do the "
    .. "opposite, on the same clock the DAYTIME row sets. Never to zero: a "
    .. "Zubat at noon is the least likely thing on Route 4, not an absent "
    .. "one, because a dex you are halfway through should not become a "
    .. "waiting game. ON adds the sky to it -- while it rains the water "
    .. "types come up and the fire types go in, and near open water "
    .. "something from the map's OWN water roster may come ashore at the "
    .. "route's own levels. TIME is the hour alone. Indoors none of it "
    .. "applies, for the reason a cave at midnight is exactly as dark as a "
    .. "cave at noon.",
    full = true },
  { DayNight.setting,
    "What time it is outdoors: pin the sky to DAY, NIGHT, DUSK or DAWN, "
    .. "let CYCLE run it -- ten minutes of sun, ten of moon, with the "
    .. "shadows, the sky and the light following -- or SYNC it to the "
    .. "clock on the wall, so Kanto's evening falls when yours does." },
  -- Night depth and street lamps travel together in the options list: DEEP
  -- only reads as a city night when something is lit on the street, and
  -- LAMPS only matter once the sky is dark enough to need them.
  { DayNight.darkSetting,
    "How dark night is. DEEP takes a large step down from the soft blue "
    .. "night so a town reads as lit windows and street lamps in real "
    .. "darkness -- the sky and the world's tint both drop. SOFT is the "
    .. "older, more readable blue night. Windows and street-lamp heads "
    .. "are exempt either way: they burn after the hour's multiply.",
    full = true },
  -- { StreetLamps.setting,
  --   "Street lamps in towns and cities. ON plants three models of post "
  --   .. "(classic, twin-head, globe) on sidewalk cells next to buildings, "
  --   .. "deterministic per map so the same corner always has the same "
  --   .. "lamp. After dusk the heads burn in the hour's lamp colour so a "
  --   .. "DEEP night still has light on the street. Routes and forests get "
  --   .. "none -- only outdoor maps without a grass encounter table.",
  --   full = true },
  -- Orientation radar. Always-on by default at the cheap rung; FULL adds a
  -- local 4-colour cell grid. Not the classic Town Map item -- that stays
  -- untouched. full = true so a phone on FULL RES can still hide it.
  { MiniMap.setting,
    "Corner orientation radar on free-roam. ON is player + facing + "
    .. "Center/Gym/Gate icons from the map's own warps; FULL also paints a "
    .. "4-colour walkability grid of the current map (regenerated only on "
    .. "map change). OFF is nothing. Drops detail on low RES. Purely HUD -- "
    .. "nothing here writes collision, flags or scripts.",
    full = true },
    -- Marked `full` for the opposite reason the battle rows are: this is not a
  -- knob on the look at all, it is what the look COSTS. FULL is a preset for
  -- the diorama, not a licence to spend four times the fill rate on the
  -- machine it happens to be running on, so it neither sets this nor takes
  -- the row away -- the player decides what their hardware can carry, from
  -- inside FULL like anywhere else.
  { AntiAlias.setting,
    "Smooth the stair-stepped edges of the 3D world -- roof ridges, ledge "
    .. "lips, a tree against the sky -- by rendering the diorama larger than "
    .. "the window and folding it back down. Every edge in the picture "
    .. "softens with them, the tileset's own texels included, so the diorama "
    .. "reads smoother rather than sharper. 2X costs half again as many "
    .. "pixels in each direction and 4X twice, which makes this the most "
    .. "expensive row in the mod.",
    full = true },
  -- `full` for the same reason as AA: not a knob on the look, a question
  -- about the hardware on the desk.
  { VR.setting,
    "PCVR through OpenXR (SteamVR, Oculus, WMR). The diorama becomes a "
    .. "tabletop model your head moves around; the 1ST rung stands you "
    .. "inside the world at life size, looking where the headset looks. "
    .. "Menus and dialogs float on a panel. Needs a Windows OpenXR runtime "
    .. "and the mod running from a real folder; without them the row stays "
    .. "and the game stays flat, with the reason on the console.",
    -- on Windows the row stays even when a runtime is missing (the console
    -- says why); off Windows -- mobile above all -- there is no VR to have
    -- and the row does not exist
    when = function() return VR.supported() end, full = true },
  -- Under the VR row and only while it is ON: a comfort setting for a
  -- device that is not plugged in decides nothing, and this one is read
  -- exclusively by the headset's right stick.
  { VR.smoothTurn,
    "Turn smoothly with the right stick instead of snapping 45 degrees a "
    .. "flick. OFF by default, and deliberately: a software turn moves the "
    .. "world past a head that did not move, which is the most reliable way "
    .. "to make somebody ill in a headset. Turn it on if you have your sea "
    .. "legs and want the continuity.",
    when = function() return VR.enabled() end, full = true },
}

local schema = {}
for i, entry in ipairs(SETTINGS) do
  -- the VR rows are absent from the mod manager's page too where the
  -- platform cannot do VR at all -- the OPTIONS menu's `when` gates are
  -- situational (a row hidden for now), this one is existential
  local vrOnly = entry[1] == VR.setting or entry[1] == VR.smoothTurn
  if not vrOnly or VR.supported() then
    schema[i] = entry[1]:schema(entry[2])
  end
end
mod.options:define(schema)

-- ------- this mod's hotkeys
--
--   v  VOXEL    cycle the camera ladder      (skips FULL)
--   g  V-GRID   toggle the wireframe
--   t  T-SHIFT  cycle the blur ladder
--   c  V-CURVE  cycle the horizon bend
--   b  3D-BTL   toggle overworld battles
--   n  WILD     cycle ROAM / MIX / OFF
--   p  MAP      minimap ON / FULL / OFF
--
-- Upstream DRAMATIC_SHAPE still uses 3/5/6/7/8/9. These letter keys are the
-- independence surface: both mods can load and neither steals the other's
-- presses. Engine keys 2 COLORS / 3 TILT / 4 ZOOM / 5 GBC FX stay free of our
-- HOTKEYS table; pinEngineFx still holds TILT and GBC FX at off while we are
-- installed (they fight the diorama), and the registry still drops TILT when
-- a world pipeline owns the pass.
--
-- Game:keypressed still has to be wrapped: settings without a pipeline have
-- no registry hotkey route, and the VOXEL key walks a custom ladder that
-- skips FULL. Polling in update() would fire alongside the engine instead
-- of instead of it.
--
-- Everything the engine does around a pipeline hotkey has to happen here
-- too, so the work is DELEGATED rather than reimplemented: Pipelines.hotkey
-- applies its own gate and ladder, and the lines after it are the engine's
-- own (syncOptions, the tilt exclusion, writeOptions).

local HOTKEYS = {
  [KEY_VOXEL]  = "pipeline",
  [KEY_TILT]   = "pipeline",
  [KEY_GRID]   = VoxelGrid.setting,
  [KEY_CURVE]  = WorldCurve.setting,
  [KEY_BATTLE] = OverworldBattle.setting,
  [KEY_WILD]   = WildRoamers.setting,
  [KEY_MAP]    = MiniMap.setting,
}


do
  local Game = require("src.core.Game")
  local Pipelines = require("src.render.Pipelines")
  local inner = Game.keypressed

  function Game:keypressed(key)
    local claim = HOTKEYS[key]
    local top = self.stack and self.stack:top()
    -- A screen with its own key handler gets the key first, exactly as the
    -- engine's first branch does: typing a nickname must not toggle a
    -- render mode. Only free-roam presses are ours to take.
    if claim and not (top and top.onKeyPressed) then
      if claim == "pipeline" then
        -- VOXEL key walks the ANGLE rungs and steps over FULL (Voxel.HOTKEY_ORDER),
        -- so the registry's plain "advance one and wrap" is not what it
        -- wants; T-SHIFT still is. The gate is the registry's own either way.
        local stepped = false
        if key == KEY_VOXEL then
          if Pipelines.canToggle(PIPE_VOXEL, top, self.overworld) then
            Pipelines.setLevel(PIPE_VOXEL,
              Voxel.nextHotkeyLevel(Pipelines.level(PIPE_VOXEL)))
            stepped = true
          end
        else
          stepped = Pipelines.hotkey(key, top, self.overworld) and true
        end
        if stepped then
          Pipelines.syncOptions(self.save.options)
          -- VOXEL press still clears TILT/GBC FX so a pre-mod save cannot leave
          -- either fighting the diorama with no path back to off.
          -- A player who left either running before enabling the mod would
          -- otherwise have no way back to off, and both fight the diorama:
          -- TILT is the flat fake of what this mode does for real, and GBC
          -- FX is a full-screen present pass over the top of it. So the
          -- VOXEL key clears them on EVERY press, not just the press that
          -- switches the mode on -- cycling back round to OFF leaves them
          -- off too, which is the state the key is now the only route to.
          if key == KEY_VOXEL then
            self.save.options.tilt = 0
            self.save.options.gbcfx = 0
            require("src.render.GBCFX").setLevel(0)
          end
          require("src.render.Tilt").setLevel(self.save.options.tilt or 0)
          self:writeOptions()
          return
        end
      elseif Pipelines.canToggle(PIPE_VOXEL, top, self.overworld) then
        -- All four answer to the voxel pass's own free-roam gate --
        -- borrowed from the registry rather than restated, so a press
        -- mid-warp or mid-cutscene is refused for the wireframe exactly when
        -- it would be for the mode itself. Two of them parameterise that
        -- pass; 3D-BTL decides what a battle is drawn over, and wants the
        -- same gate for a different reason: the answer is read when the fight
        -- starts, so flipping it from inside one would be a switch that
        -- appeared to do nothing. WILD wants it for a third: it adds and
        -- removes map objects, which is nothing to be doing while a script
        -- is walking the cast around.
        claim:cycle(self)
        -- 3D-BTL is one of the two ways staged battles get switched on, and they
        -- pin BATTLE LAYOUT to OG (see the rows hook). The other two keys
        -- parameterise the pass and leave the layout alone; the guard answers
        -- for all three, so nothing here has to know which key it was.
        if stagedBattles() then OverworldBattle.forceOG(self) end
        return
      end
    end
    return inner(self, key)
  end
end

-- ------- the mode's rows, kept together
--
-- The engine splices a pipeline's row in beside TILT, because a display mode
-- belongs with the other display modes; a mod's own ui.options.rows
-- additions land at the END of the list. That left this mod's four rows in
-- two places with unrelated engine rows between them, which reads as two
-- unrelated features rather than one mode with settings.
--
-- So the plain settings are inserted directly after the last of this mod's
-- PIPELINE rows instead of appended. Nothing else moves: the block lands
-- where the engine already decided display modes go.
local function insertGrouped(out, extra)
  local anchor = nil
  for i, row in ipairs(out) do
    local id = type(row) == "table" and row.id
    if id == "pipeline:" .. PIPE_VOXEL or id == "pipeline:" .. PIPE_TILT then anchor = i end
  end
  if not anchor then
    for _, row in ipairs(extra) do out[#out + 1] = row end
    return out
  end
  for i, row in ipairs(extra) do table.insert(out, anchor + i, row) end
  return out
end

-- FULL owns the settings that describe the LOOK, so while it is selected those
-- are taken off the menu rather than left to be changed under it -- including
-- T-SHIFT, which is a pipeline row the engine put there. A row that no longer
-- decides anything is worse than no row.
--
-- The battle rows are the exception and they stay; see the rows hook.
local function dropRow(out, id)
  for i = #out, 1, -1 do
    if type(out[i]) == "table" and out[i].id == id then table.remove(out, i) end
  end
  return out
end

-- ------- TILT and GBC FX are gone while this mod is installed
--
-- Both fight the diorama, and both were already half-taken: the mode's own key
-- (3) forces them off on every press, and the registry switches TILT off
-- whenever a world pipeline takes the pass. What was left was two rows the
-- player could set and watch get reverted -- TILT is the flat fake of what
-- this mode does for real, and GBC FX is a full-screen present pass over the
-- top of the whole thing.
--
-- So they come OFF the menu, and are HELD at zero rather than merely dropped.
-- Hiding a live setting is a trap: a save written before the mod was installed
-- can carry TILT 3, and a row that is not there is a row that cannot turn it
-- back off. Pinned wherever the value could have arrived from -- the menu
-- opening, a save being loaded or begun -- so there is no route by which one
-- of them is on and unreachable.
--
-- Everything they did is still reachable: uninstall the mod and both rows are
-- back, at whatever they were last set to.
local function pinEngineFx(game)
  game = game or require("src.core.Game")
  local opts = game and game.save and game.save.options
  local Tilt = require("src.render.Tilt")
  local GBCFX = require("src.render.GBCFX")
  local changed = false
  if opts then
    changed = (opts.tilt or 0) ~= 0 or (opts.gbcfx or 0) ~= 0
    opts.tilt, opts.gbcfx = 0, 0
  end
  pcall(Tilt.setLevel, 0)
  pcall(GBCFX.setLevel, 0)
  if changed and game.writeOptions then pcall(game.writeOptions, game) end
end

-- call next() first and decorate what comes back, so every other mod's
-- rows survive this one
mod.hooks:wrap("ui.options.rows", function(next, game, rows)
  local out = next(game, rows)
  if type(out) ~= "table" then return out end
  local Pipelines = require("src.render.Pipelines")
  -- ahead of every branch below, including FULL's early return: these two are
  -- off the menu whatever else this mod is or is not doing
  pinEngineFx(game)
  dropRow(out, "tilt")
  dropRow(out, "gbcfx")
  -- and BATTLE BG with them: this mode fills the window with the map, so
  -- the row's whole question -- what to put in the voids around the battle
  -- -- no longer has voids to be about (see pinEngineFx)
  dropRow(out, "battleBg")
  -- BATTLE LAYOUT is the ENGINE's row, and this is the one place the mod takes
  -- one away. While a fight can be staged on the map, OG is the only layout it
  -- can be composed in (OverworldBattle.forceOG), so the value is pinned there
  -- and the row comes off the list on the same reasoning as the rows FULL owns:
  -- a row that no longer decides anything is worse than no row. Nothing is
  -- lost by switching 3D-BTL off -- the row is back, WIDE and all, on the same
  -- keypress.
  if stagedBattles() then
    OverworldBattle.forceOG(game)
    dropRow(out, "battleLayout")
  end
  local full = Voxel.isFull(Pipelines.level(PIPE_VOXEL))
  if full then
    -- FULL owns the rows that PARAMETERISE the diorama -- the wireframe, the
    -- horizon bend, the blur, the hour -- so those come off the menu and
    -- DAYTIME is held at SYNC while its row is unreachable.
    DayNight.forceSync(game)
    dropRow(out, "pipeline:" .. PIPE_TILT)
  end
  local extra = {}
  for _, entry in ipairs(SETTINGS) do
    -- Two things decide whether a row is offered.
    --
    -- FULL: a preset that owns the look, so the rows that describe the look go
    -- with it. The BATTLE rows are not that -- 3D-BTL decides what a fight is
    -- drawn OVER and BACK SPRITES how it is framed, and neither is a knob on
    -- the diorama FULL is a preset for. FULL still SETS them on arrival (see
    -- applyFull); it does not hold them, so leaving them on the menu is the
    -- difference between a preset and a lock.
    --
    -- And a row whose own switch is off the table this frame (BACK SPRITES,
    -- which needs a staged fight to be about) is left off with it. The mod
    -- manager's page carries every one of them either way.
    local offered = (entry.full or not full)
                    and (not entry.when or entry.when())
    if offered then extra[#extra + 1] = entry[1]:row() end
  end
  -- and the ROM import, which is an ACTION and not a setting: there is no
  -- rung to store, nothing for the mod manager's page to persist and nothing
  -- to restore on the next boot, so it is appended here rather than living in
  -- SETTINGS. nil on a platform with no file dialog, which takes it off the
  -- menu rather than offering a button that cannot do anything.
  -- On EVERY platform. Where there is no file dialog it says WHERE? and
  -- shows the folder to put the cartridge in, which is the one thing a
  -- player on a phone could not otherwise find out -- the row used to vanish
  -- there, which reads as the feature being missing rather than manual.
  local okPick, importRow = pcall(function()
    return V.require("StadiumRomPick").row()
  end)
  if okPick and importRow then extra[#extra + 1] = importRow end
  return insertGrouped(out, extra)
end)

-- The mod manager writes and persists on its own, so the only thing left
-- to do is move our cached index and pick the new value up.
mod.events:on("mod.options_changed", function(payload)
  if not (payload and payload.mod == mod.id) then return end
  for _, entry in ipairs(SETTINGS) do
    if payload.key == entry[1].key then entry[1]:sync(payload.value) end
  end
  -- 3D-BTL switched on from the manager's page pins BATTLE LAYOUT exactly as
  -- the OPTIONS row does. The manager persists its own value; this is the one
  -- that has to follow it.
  if stagedBattles() then OverworldBattle.forceOG() end
  -- and DAYTIME changed from the manager's page while FULL owns it snaps
  -- straight back to SYNC -- the OPTIONS row is hidden, but the manager's is
  -- not, and FULL's pin must hold against both
  local Pipelines = require("src.render.Pipelines")
  if Voxel.isFull(Pipelines.level(PIPE_VOXEL)) then DayNight.forceSync() end
end)

-- ------- keeping the geometry in step with the world
--
-- Terrain meshes are derived from a map's block layer, so anything that
-- rewrites a block (a cut tree, a smashed rock, a script's replaceBlock)
-- has to drop that map's cached mesh or the 3D world keeps showing the
-- tree that is no longer there.  The 2D tile renderer invalidates its own
-- caches off the same edit.

-- refresh, not invalidate: the stale mesh keeps drawing while the
-- replacement builds in the background, so a one-block edit (Cut, a
-- door stamp, the tree regrowing on re-entry) repopulates in place
-- instead of blinking the whole scene down to the flat 2D path
mod.events:on("world.block_replaced", function(payload)
  local mapId = payload and (payload.mapId or (payload.map and payload.map.id))
  if mapId then ChunkMesher.refresh(mapId) end
  -- and the ground decals with it: a Cut tree is a new cell to stand on,
  -- and therefore a new cell that could hold a puddle
  GroundFX.invalidate()
end)

-- The event above is the ANNOUNCED edit -- OverworldState:replaceBlock
-- emits it, which is the path Victory Road's barriers and a script's
-- replaceBlock take. Several edits do not go through it:
--
--   Cut          swaps the tree block and rebuilds the 2D renderer
--   the regrowth restores those blocks when the map is re-entered
--   card-key doors are stamped closed on floor load
--
-- all of them writing the block layer directly. Meshes derived from that
-- layer went stale with no announcement -- the cut tree stayed standing,
-- and after a round trip through a door the stump stayed cut because this
-- map's mesh survives in the cache (that is what prevLive is for).
--
-- The engine could announce each of those, and an earlier cut of this
-- work changed it to. That is the wrong place: it edits the game for one
-- mod's benefit, and every future path that writes a block has to
-- remember to do the same. They all funnel through ONE choke point --
-- Map:setBlock -- so wrap that from here instead. Map is a plain
-- metatable shared by every map instance, so this covers all of them,
-- including paths written after this mod.
--
-- Read back rather than trust the argument: setBlock silently ignores an
-- out-of-bounds write, and a stamp that rewrites a block with the value
-- it already held (the door code guards for this, the regrowth does not)
-- is not a change and must not throw the mesh away.
do
  local Map = require("src.world.Map")
  if not Map.dramaticShapeBlockHook then
    local setBlock = Map.setBlock
    Map.setBlock = function(self, bx, by, block)
      local before = self:blockAt(bx, by)
      setBlock(self, bx, by, block)
      if self.id and self:blockAt(bx, by) ~= before then
        ChunkMesher.refresh(self.id)
        GroundFX.invalidate()
      end
    end
    Map.dramaticShapeBlockHook = true
  end
end

-- A reloaded map is rebuilt from scratch (warps that re-enter the same map,
-- hot reload), so its mesh is stale for the same reason -- with one
-- exception, and it is the common one.
--
-- A palette switch reloads the map ONLY to rebuild its atlas
-- (PaletteFX.setMode -> reloadMap(id, "colors")). The geometry that comes
-- back is identical: this mesher reads block layout and tile ids and never
-- reads colour, and the palette lives entirely in the texture TerrainAtlas
-- hands back per frame -- which is keyed BY palette, so the new colours are
-- already built by the time the next frame draws.
--
-- Dropping the mesh anyway cost a visible flash of the flat 2D world on
-- every palette toggle. Mesh builds are asynchronous, so the frames between
-- the drop and the first finished mesh have no terrain to draw, and
-- drawWorld returning nil IS the 2D fallback. Keeping the geometry lets the
-- new colours land on the diorama already on screen, in one frame, which is
-- what a palette toggle should look like from inside voxel mode.
mod.events:on("map.reloaded", function(payload)
  if payload and payload.reason == "colors" then return end
  local mapId = payload and (payload.mapId or (payload.map and payload.map.id))
  if mapId then ChunkMesher.invalidate(mapId) end
  -- the atmosphere's layout stands on the same carved stamps the meshes
  -- do, so it goes stale on exactly the same event
  if mapId then ForestAtmos.invalidate(mapId) end
end)

-- ------- rows come and go, so the menu has to notice
--
-- OptionsMenu builds its row list ONCE, when it is opened, and then reads
-- that list every frame. So stepping the VOXEL row onto or off FULL changed
-- which rows the hook would return but not which rows were on screen -- the
-- settings FULL owns stayed visible until the menu was closed and reopened,
-- and a player who stepped off FULL could not see the rows come back.
--
-- Rebuilt in place, and only on a step that changes the LIST: crossing FULL,
-- toggling 3D-BTL, which is the other row that owns one (BATTLE LAYOUT), or
-- WILD arriving at or leaving OFF, which takes W-COUNT with it.
-- Every other rung returns the same list, and rebuilding on all of them would
-- rerun every mod's ui.options.rows hook once per keypress. The cursor is
-- clamped rather than reset, so it stays on the row it was just used on
-- instead of jumping to the top when the list below it shortens.
do
  local OptionsMenu = require("src.ui.OptionsMenu")
  if not OptionsMenu.dramaticShapeFullHook then
    local Pipelines = require("src.render.Pipelines")
    local inner = OptionsMenu.update

    local function idAt(menu, index)
      local row = menu.rows and menu.rows[index or 1]
      return type(row) == "table" and row.id or nil
    end

    function OptionsMenu:update(dt)
      local before = Pipelines.level(PIPE_VOXEL)
      local hadBattles = OverworldBattle.enabled()
      local hadVR = VR.enabled()
      local hadWild = WildRoamers.enabled()
      local hadWeather = Weather.enabled()
      local wasOn = idAt(self, self.index)
      inner(self, dt)
      local after = Pipelines.level(PIPE_VOXEL)
      local crossedFull = after ~= before
                          and (Voxel.isFull(before) or Voxel.isFull(after))
      if crossedFull or OverworldBattle.enabled() ~= hadBattles
         or WildRoamers.enabled() ~= hadWild
         or VR.enabled() ~= hadVR
         -- WEATHER arriving at or leaving OFF takes GROUND with it, for the
         -- same reason WILD takes W-COUNT: with no sky there is never a
         -- puddle for that row to decide anything about
         or Weather.enabled() ~= hadWeather then
        local rebuilt = OptionsMenu.new(self.game)
        self.rows = rebuilt.rows
        -- Follow the row the cursor was ON rather than the slot it was in:
        -- 3D-BTL takes BATTLE LAYOUT off the list ABOVE itself, which would
        -- otherwise slide the cursor onto the row under the one just used.
        for i = 1, #self.rows do
          if wasOn and idAt(self, i) == wasOn then self.index = i; break end
        end
        local cancel = #self.rows + 1
        if (self.index or 1) > cancel then self.index = cancel end
      end
    end

    OptionsMenu.dramaticShapeFullHook = true
  end
end

-- ------- battles on the map
--
-- The wraps this needs -- OverworldState:pushBattle, BattleState:draw and
-- BattleState:drawHUDs -- all live in lib/OverworldBattle.lua, which is
-- where the reasoning for each one is written down. Installed once, here,
-- so this file keeps naming every engine seam the mod touches.
OverworldBattle.install()

-- ------- wild Pokemon standing in the grass
--
-- The two seams this needs -- Player:tryMove, which is where walking into
-- one is refused, and OverworldState:talkTo, which is where pressing A at
-- one lands -- live in lib/WildRoamers.lua with the reasoning for each.
--
-- Nothing here reaches the encounter TABLES: which species and how likely
-- each is are still the ROM's, read through the same records the roll reads.
-- What changes is that the roll happens in the open, some distance away,
-- and you can see its answer standing in the grass before you decide
-- whether to walk into it.
WildRoamers.install()

-- ------- Pokemon in the streets
--
-- One seam -- OverworldState:talkTo, chained behind WildRoamers' wrap of
-- the same method -- where pressing A at a street Pokemon becomes a cry
-- and a line of flavour text, or a challenge. lib/CityLife.lua holds the
-- reasoning.
CityLife.install()

-- ------- and asleep on the floor indoors
--
-- The same seam again, chained behind both of the wraps above -- each checks
-- its own mark and passes everything else along -- where pressing A at a
-- sleeping house pet is a slowed cry and a line, and never a battle.
Interiors.install()

-- ------- what the world sounds like
--
-- Registered rather than merely built: every one of these is a Game Boy
-- channel program assembled by the engine's own authoring path
-- (src.audio.ChipAsm, one of the three src modules the loader names as a
-- supported require) and handed to the engine's own sfx registry -- so they
-- are real entries under real ids, and a sound pack can override
-- DS_AMB_CRICKET with a file of its own and be played instead. Nothing here
-- ships an audio asset; the crickets, the birds, the water, the rain and the
-- thunder are all synthesized from about two hundred bytes of note table
-- each. See lib/AmbientSound.lua for what every program is.
--
-- At load time on purpose: assembly touches no love.* at all, so it works on
-- a headless boot and in the manager's dry load, and the registry has the
-- entries before anything can ask to play one.
AmbientSound.register(mod)

-- ------- quality of life
--
-- Three seams, each wrapped in lib/QoL.lua with the reasoning beside it:
-- OverworldState:interact (A at a tree or the water runs the field move
-- the party menu would have), OverworldState:talkTo (A at a boulder wakes
-- STRENGTH), and BattleState:drawTextArea (effectiveness markers on the
-- move menu, from the same TypeChart the damage formula reads).
QoL.install()
Carry.install()
-- Walk-on-ice when frozen, gated on Surf (Soul Badge + party knows SURF).
if Water.installWalk then pcall(Water.installWalk) end

-- ------- three more mercies on the same row
--
-- The box that fills up (the PC follows the catch, and a full box rolls
-- forward instead of refusing a deposit), the bag sorted into pockets, and
-- RENAME on the party submenu. Every one of them rides a hook or an event
-- the engine already put there -- pokemon.caught, ui.list_menu,
-- ui.party.submenu -- plus two constructor wraps for the two menus that
-- have no hook of their own. lib/Comforts.lua holds the reasoning.
Comforts.install(mod)

-- ------- and experience for the whole team
--
-- battle.exp_award, whose own comment in the engine names this exact case.
-- Nothing here computes experience: the engine hands over the helper it
-- uses itself, and this only decides who it is called for.
ExpShare.install(mod)

-- Two more of its mercies ride engine HOOKS rather than wraps, because the
-- engine put hooks exactly where they were needed.
--
-- `movement.speed` exists, in the engine's own words, for "running shoes,
-- dash, etc." -- so holding B to jog goes through the front door. next()
-- first, so a mod loaded before this one that already changed the pace keeps
-- its answer and this only ever takes the faster of the two.
mod.hooks:wrap("movement.speed", function(next, frames, ctx)
  return QoL.runSpeed(next(frames, ctx), ctx)
end)

-- And `evolution.check` is the seam for cancelling or forcing any evolution,
-- which is what a trade evolution on a single machine needs: Kadabra,
-- Machoke, Graveler and Haunter evolve by trade and by nothing else, so four
-- species are simply absent from a solo game. next() FIRST and its yes is
-- final -- a real link trade still evolves them the instant it completes, and
-- this only ever adds a second way in.
mod.hooks:wrap("evolution.check", function(next, game, mon, evo, trigger)
  return QoL.tradeEvolution(next(game, mon, evo, trigger),
                            game, mon, evo, trigger)
end)

-- ------- the auto-farm bot
--
-- One seam of its own -- MoveLearnMenu:enter, where the forget-a-move
-- prompt would otherwise wait for a player who is not driving -- wrapped in
-- lib/AutoFarm.lua with the reasoning beside it. Everything else the bot
-- does goes through the engine's own front door: synthetic presses on the
-- same Input queue the tests and drivers write, which is why every menu,
-- message and battle behaves exactly as if a very fast player were at the
-- keys.
--AutoFarm.install()

-- The bot's tick rides `input.step`, the boundary Game:step runs for
-- exactly this class of mod -- "before Input:step promotes queued edges so
-- a button chosen here is visible to this logic tick". next() first, so an
-- accessibility driver or another autoplay mod loaded before this one
-- still gets its buttons in ahead of ours.
mod.hooks:wrap("input.step", function(next, game, dt)
  local out = next(game, dt)
  --AutoFarm.update()
  return out
end)

-- The blind roll, switched off exactly where this feature has replaced it.
--
-- encounter.roll is the engine's own seam for it (OverworldState:rollEncounter
-- offers every wild pick to this chain and takes nil for "nothing this
-- step"), so no encounter code is touched -- and next() is not called at all
-- on the terrain we cover, which leaves the vanilla RNG draws unspent rather
-- than rolling and discarding.
--
-- Answered per TERRAIN, not per map: `covers` is only true for ground this
-- feature has actually stood something on, so a map with no encounter table,
-- no room, or art that would not bake keeps the dice it has always had. The
-- one thing worse than a blind encounter is no encounter.
mod.hooks:wrap("encounter.roll", function(next, encDef, ctx)
  if WildRoamers.covers(ctx and ctx.terrain) then return nil end
  return next(encDef, ctx)
end)

-- And the hour and the sky on whatever that roll came back with.
--
-- encounter.species is the engine's own second seam, run on a non-nil roll
-- and BEFORE the repel filter, which is exactly the right place: what
-- changes here is which Pokemon it is, and everything downstream -- repel,
-- the ghost rule, the Safari menu, the battle itself -- goes on reading the
-- answer rather than the question.
--
-- This is the path for MIX and for OFF, the two rungs where the dice are
-- still being thrown, so a player who never switched the visible Pokemon on
-- gets the same world. Under ROAM the roll above already returned nil on
-- the terrain this mod covers, so this is never reached there -- the tilt
-- happened when the roamer was placed, in the open, which is the whole
-- point of that row.
--
-- next() first and only then decorated, so a mod that replaces the species
-- outright still has the last word on WHICH creature; this only ever moves
-- the odds inside the map's own table.
mod.hooks:wrap("encounter.species", function(next, enc, ctx)
  local out = next(enc, ctx)
  if not Ecology.enabled() then return out end
  local ok, tuned = pcall(Ecology.substitute, out, ctx)
  return (ok and tuned) or out
end)

-- The overworld's own pushBattle is the choke point for a wild encounter or
-- a trainer, and it is wrapped. A battle that arrives some other way -- a
-- link battle, a script pushing a BattleState directly -- reaches this
-- instead, which stages the arena from wherever the player is standing.
-- Nothing visible is lost by being late: the cull only has to beat the
-- battle screen, and the wipe those battles skip is where it would have
-- shown.
mod.events:on("battle.started", function(payload)
  OverworldBattle.ensure(payload and payload.battle)
end)

-- Both mons face the camera, so the player's side wants its FRONT pic where
-- the battle screen would have used the back one. The engine's own
-- pokemon.sprite hook is the seam for exactly this: it is asked for every
-- battle pic with the side it is resolving, so swapping one side's answer
-- needs no battle code at all -- and every path that builds a battler goes
-- through it, including a Transform mid-fight.
--
-- next() first, so a sprite-replacing mod loaded before this one still gets
-- the last word on WHICH art is used; this only changes which SIDE is asked
-- for.
mod.hooks:wrap("pokemon.sprite", function(next, path, ctx)
  local out = next(path, ctx)
  if not (ctx and ctx.kind == "battle" and ctx.side == "back") then
    return out
  end
  if not OverworldBattle.wantsFront() then return out end
  local def = ctx.data and ctx.data.pokemon and ctx.data.pokemon[ctx.species]
  return (def and def.spriteFront) or out
end)

-- Every ending path emits this, including a battle skipped before it drew,
-- so this is where the map's cast comes back.
mod.events:on("battle.ended", function()
  OverworldBattle.finish()
end)

-- ------- and the way back out
--
-- The engine wipes INTO a battle with one of the original's eight transitions
-- and cuts straight OUT of it. That cut is between two very different cameras
-- in this mode, so while voxel mode is on the battle fades out, closes behind
-- the black, and the map fades up. The two seams it needs -- BattleState:finish
-- and Renderer:endFrame -- and the reasoning for each live in lib/BattleExit.lua.
--
-- Declared as a transitions record rather than a constant in that file, so the
-- fade is retunable in data exactly like the eight wipes it answers, and a total
-- conversion can make it as long or as short as its own pacing wants.
mod.content.transitions:register(BattleExit.ID, {
  frames = BattleExit.FRAMES,
})

BattleExit.install()

-- ------- and the hour on the flat world
--
-- The clock reaches the diorama through the voxel shader's own tint uniform,
-- which the 2D tile path never runs -- so with the mode off, the same evening
-- that fell on the diorama left the flat world at permanent noon. One clock,
-- two worlds, one of them ignoring it. DayTint paints the same multiply over
-- the composited flat world, between the world blit and the UI blit; the
-- reasoning for that exact instant is in the file.
DayTint.install()

-- ------- what time it is
--
-- The cycle's clock rides the SAVE SLOT (save.modData, via mod.save): what
-- time it is in Kanto is a fact about that journey, like where the player is
-- standing. Written on the engine's save.writing event -- the moment before
-- the bytes hit disk -- and read back whenever a save is opened or begun. A
-- save with no clock in it starts at day; that is DayNight.restore's
-- fallback, and also the DAYTIME row's own default.
mod.events:on("save.writing", function()
  DayNight.store()
end)

mod.events:on("save.loaded", function()
  DayNight.restore()
  -- a save written before this mod was installed can carry TILT or GBC FX
  -- switched on, and their rows are not there to switch them back off (see
  -- pinEngineFx). Answered here rather than only when the menu opens, so a
  -- player who never opens it is not left playing under one.
  pinEngineFx()
end)

mod.events:on("save.created", function()
  DayNight.restore()
  pinEngineFx()
end)

-- The engine's own time-of-day seam. OverworldState:timeOfDay() is an
-- eternal "DAY" until a mod answers here; answering it hands the period to
-- the map.palette hook (ctx.tod) and music.select, so a palette or music
-- pack keyed to night works with this mod's clock for free. next() first: a
-- mod loaded before this one that already moved the time keeps its answer.
mod.hooks:wrap("world.tod", function(next, tod, ctx)
  local out = next(tod, ctx)
  if out ~= tod then return out end
  return DayNight.tod()
end)

mod.exports.version = "1.6.2.ST"
-- exposed so a companion mod can pin its own tiles' shapes or read the
-- camera without reaching into this mod's file layout
mod.exports.lib = V
mod.exports.pipelines = { voxel = PIPE_VOXEL, tiltshift = PIPE_TILT }
mod.exports.keys = V.KEYS
