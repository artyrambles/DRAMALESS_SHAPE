-- STADIUM battles: the two Pokemon as real 3D models.
--
-- The 3D-BTL row's two STADIUM rungs. OFF is the engine's own white battle
-- field; the 2D-3D rungs stand the GB's own pics up as quads
-- (BattleBillboard); STADIUM replaces those quads with the Pokemon Stadium
-- battle models -- skinned, animated, and playing the animation the move
-- being used actually calls for. A or B decides whether that happens on the
-- map or on two discs, and is the same choice on either pair of rungs.
--
-- The models come out of the Stadium ROM through model_extract, and are
-- packed into assets/stadium/NNN.dsm by tools/stadium_pack.py. Nothing here
-- knows about the ROM; the pack is the interface.
--
-- ------- what this file is, and is not
--
-- It is the MODE: which species is out on each side, which animation the
-- fight is asking each of them for, whether the model or the flat pic is
-- standing in this frame, and the two draw calls. The arithmetic is
-- StadiumRig's, the file format is StadiumPack's, and one side's own state
-- is StadiumMon's.
--
-- It is not a rewrite of the staged battle. The arena is picked the same
-- way, the camera is solved the same way, the HUDs and the text box and the
-- move animations and the depth of field are all exactly what 2D-3D draws
-- -- because all of those are hung off the arena's CELLS, not off the
-- pics. Swapping what stands on a cell changes nothing about where the cell
-- projects to. That is why this is an option on the mode rather than a
-- second mode.
--
-- ------- declining, per Pokemon
--
-- Every gate here is per SIDE and per FRAME, not per battle:
--
--   no pack for that species, or its meshes would not build -> that side
--   falls back to its flat pic, and the other side keeps its model
--
--   the side is showing a TRAINER (the foe's class before the send-out,
--   the player's own back before "Go!") -> that is not a Pokemon and there
--   is no model for it; the pic stands, exactly as in 2D-3D
--
--   a SUBSTITUTE is up -> the engine replaces the pic with the mini doll,
--   which is the thing the player is being told is there. A model of the
--   Pokemon behind the doll would be a lie about the battle state.
--
-- So `covers` is asked per side per frame, and OverworldBattle renders a
-- billboard texture for exactly the sides it answers false for.

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local Voxel3D = V.require("Voxel3D")
local StadiumPack = V.require("StadiumPack")
local StadiumMon = V.require("StadiumMon")

local Stadium = {}

-- The stored values of the two 3D-BTL rungs that select this mode. Strings
-- rather than further booleans so an older save's `true` still means the
-- 2D-3D it was written for (see OverworldBattle.setting).
--
--   A  the models on the MAP -- real ground, the map's own light and sky
--   B  the models on two DISCS against the sky, with no map at all
--
-- Everything below is shared: which species is out, which animation the
-- fight is asking for, the skinning, the draw. The difference is entirely
-- in what the camera is pointed at, which is BattleScene's business and
-- StadiumStage's.
Stadium.VALUE = "stadium"
Stadium.VALUE_B = "stadiumB"

-- ------- the live pair

local session = nil     -- nil when no staged fight is running

local function game()
  return require("src.core.Game")
end

-- Whether the row is on this rung. Deliberately NOT gated on whether the
-- packs are installed: a mod folder without assets/stadium still cycles the
-- row, and each Pokemon declines on its own when its pack does not load --
-- which is one message on the console rather than a row that silently
-- refuses to move.
function Stadium.selected()
  return Stadium.mode() ~= nil
end

-- "A", "B", or nil when the row is on neither stadium rung.
function Stadium.mode()
  local OverworldBattle = V.require("OverworldBattle")
  local value = OverworldBattle.setting:get()
  if value == Stadium.VALUE then return "A" end
  if value == Stadium.VALUE_B then return "B" end
  return nil
end

-- Whether the fight is staged on the DISCS rather than on the map.
--
-- Not this file's question any more: the flat 2D-3D B rung stands the game's
-- own pics on the same two discs with no model anywhere in the frame, so the
-- stage and the actors are chosen separately (see OverworldBattle's ladder).
-- Kept as a forwarder because "are we on discs" is a fair thing to ask the
-- module named after the mode, and because the shot drivers ask it here.
function Stadium.discs()
  return V.require("OverworldBattle").discs()
end

function Stadium.enabled()
  if not Stadium.selected() then return false end
  return Voxel3D.available()
end

-- A staged fight has begun on `arena`. Called from OverworldBattle.begin,
-- which is the one place that knows a fight is being staged at all.
function Stadium.begin(arena)
  Stadium.finish()
  if not Stadium.enabled() then return false end
  -- a new fight gets its own first complaint: `reported` is a one-shot so the
  -- console is not filled sixty times a second, but latched for the whole
  -- process it would swallow every failure after the first one ever
  Stadium.reported = false
  session = {
    arena = arena,
    groundY = 0,
    player = StadiumMon.new("player"),
    enemy = StadiumMon.new("enemy"),
    -- what each side has been TRANSFORMED into, if anything (see install)
    transform = {},
    -- sides that are going to collapse, but whose HP bar has not finished
    -- emptying yet (see faintReady)
    faintPending = {},
    -- who was standing in each slot last frame, so a replacement is noticed
    -- even when it is the same species (see update)
    at = {},
  }
  return true
end

function Stadium.finish()
  if not session then return end
  session.player:release()
  session.enemy:release()
  session = nil
end

function Stadium.active()
  return session ~= nil
end

-- ------- which species each side is showing

-- The National Dex number for a battler, which is the number the Stadium
-- packs are keyed by. The engine's species are string keys ("PIKACHU") and
-- carry their dex number on the definition, so this is one lookup rather
-- than a table of its own.
local function dexOf(species)
  if not species then return nil end
  local data = game() and game().data
  local def = data and data.pokemon and data.pokemon[species]
  return def and def.dex or nil
end

-- Whether this side is showing a TRAINER rather than a Pokemon.
local function showingTrainer(battle, side)
  if side == "enemy" then
    return (battle.showEnemyTrainer and battle.trainerPic) and true or false
  end
  return (battle.showPlayerBack and battle.playerBackPic) and true or false
end

-- Whether this side has anything on the field at all this frame.
--
-- Mirrors BattleState's own guards, the same way OverworldBattle.sideVisible
-- mirrors them for the flat cards: there is no seam that reports "the foe is
-- off screen right now", and a model left standing through a send-out or a
-- damage blink would be the one thing in the frame that ignored the battle.
-- ------- and the collapse gets to finish
--
-- A fainted Pokemon leaves the field when its pic does, which is the end of
-- the engine's slide -- SlideDownFaintedMonPic, seven rows two frames apart,
-- FOURTEEN frames of a 60 Hz clock. Under a quarter of a second.
--
-- The Stadium faint animations are nothing like that short. The briefest in
-- the set is 49 frames of a 30 Hz clock -- a second and two thirds -- the
-- median is 110 and the longest 230, which is nearly eight seconds. Held to
-- the pic's window every one of them was cut off inside its first fifth: the
-- Pokemon began to fall and vanished mid-fall, which is worse than not
-- animating at all, because the eye has been told something is happening and
-- then had it taken away.
--
-- So a model that is COLLAPSING stays until it has finished collapsing, and
-- the two timings stop being tied to each other. That is the whole of the
-- divergence: the slide is how long a flat pic takes to slide off the bottom
-- of a 160x144 frame, and it has nothing to say about how long it takes a
-- Gyarados to fall over.
--
-- Bounded at both ends rather than open-ended. It ends when the animation
-- does (StadiumMon.finished), not when the battle moves on -- so nothing is
-- left lying on the field for the rest of the fight -- and the side is reset
-- outright the moment a different battler stands in that slot (see update),
-- which is what stops the next Pokemon out of the ball arriving face down.
local function onField(battle, side, mon)
  local battler = side == "player" and battle.player or battle.enemy
  if not (battler and battler.sprite) then return false end
  -- A model that is GROWING out of its ball is on the field by definition --
  -- that is what the grow is -- even though the engine still calls the side
  -- "sending out", because the flat pic it wrote that flag for does not
  -- appear until the ball has finished opening and this one comes out with
  -- it (see StadiumMon.GROW_TIME).
  local growing = (mon and mon.grow) and true or false
  if side == "enemy" then
    if battle.enemyHidden then return false end
    if battle.enemySendingOut and not growing then return false end
  else
    if battle.safari or battle.demo then return false end
    if battle.sendingOut and not growing then return false end
    -- ------- and not before the battle has even opened
    --
    -- The player's Pokemon is not out during the INTRO. Every other guard
    -- here is a field the engine sets once the battle is running, and during
    -- the opening none of them is set yet: `showPlayerBack` is still nil
    -- (BattleState assigns it further in, when the back pic is built),
    -- `playerBackPic` is nil with it, and `sendingOut` does not go true until
    -- the ball is actually thrown. So the whole opening read as "this
    -- Pokemon is standing on the field" and the model was drawn through it --
    -- two and a half seconds of it, on its tile, playing its standby loop,
    -- before the trainer sprite it is supposed to be hiding behind had even
    -- appeared. It then vanished when that sprite arrived and came back with
    -- its entrance when the ball opened, so the first Pokemon of a battle
    -- appeared, left and arrived again.
    --
    -- A SWITCH has no intro, which is why a switch always looked right and
    -- was the thing worth comparing against.
    --
    -- Gated on the PHASE rather than on a flag latched at the send-out: a
    -- latch that never fires (a link battle, a script pushing a battle
    -- straight to the menu) would hide the Pokemon for good, and being wrong
    -- in that direction is far worse than the two seconds this fixes.
    if battle.phase == "intro" then return false end
  end
  local ok, hidden = pcall(battle.fxHidden, battle, battler)
  if ok and hidden then return false end
  -- ------- FLY and DIG: the Pokemon that is not there
  --
  -- `fxHidden` above is the damage BLINK and nothing else. The other way a
  -- Pokemon leaves the screen -- the important one -- is the engine's
  -- per-battler pic program, `picFx`, and that is where the two-turn moves
  -- live: FLY runs SE_SLIDE_MON_OFF and DIG SE_SLIDE_MON_DOWN on the charge
  -- turn, each a 19-24 frame slide that ENDS by setting `hidden`, and the
  -- release turn puts the pic back through SE_SLIDE_MON_UP /
  -- SE_SHOW_MON_PIC. Every other vanishing act is the same field: the user
  -- of Explosion, a Pokemon that has been Teleported away.
  --
  -- Without this the model simply stood on its tile while the game said it
  -- was underground -- and said it in the strongest way it has, by making
  -- every attack aimed at it miss. That is the one thing in the frame
  -- contradicting the battle it is part of.
  --
  -- Read as the engine's own answer rather than as a list of moves: this
  -- mode's whole method is to let the battle decide and follow it, and a
  -- table of move ids here would be a second place for the same facts to
  -- live and would go stale against a mod that adds a third one.
  --
  -- The engine's slide is 19-24 frames, so the model plays the opening of
  -- its own FLY or DIG animation while the pic slides and is gone when the
  -- pic is. It is NOT held to the end of that animation the way a collapse
  -- is (see below), and the difference is not an oversight: the Stadium
  -- animations are authored as the WHOLE move -- Charizard's DIG is 3.83
  -- seconds of burrow, emerge and hit -- because Stadium plays it in one
  -- turn. Gen 1 splits it across two, so cutting at the engine's own hide
  -- shows the burrowing and holds the strike back for the turn it lands on,
  -- which is the right half of the animation for the turn being played.
  local pf = battle.picFx and battle.picFx[battler]
  if pf and pf.hidden then return false end
  if battler.fainted then
    local okF, sliding = pcall(battle.fxFaintActive, battle, battler)
    if okF and sliding then return true end
    -- the pic has finished sliding away; the model has not finished falling
    return (mon and mon.state == "faint" and not mon:finished()) and true
           or false
  end
  return true
end

Stadium._onField = onField

-- Whether the 3D model is standing in for this side's pic this frame. The
-- one question OverworldBattle asks, and the answer that decides whether a
-- billboard texture gets rendered for that side at all.
function Stadium.covers(battle, side)
  if not (session and battle) then return false end
  local mon = session[side]
  if not (mon and mon.rig) then return false end
  if showingTrainer(battle, side) then return false end
  local battler = side == "player" and battle.player or battle.enemy
  -- the substitute doll is what the player is being shown is out there
  if battler and battler.substituteHP then return false end
  return true
end

-- ------- the collapse waits for the bar
--
-- `onFaint` runs the instant HP reaches zero, which is NOT when a Pokemon
-- falls over. The engine queues the collapse -- the slide, the cry, the
-- "fainted!" line -- to run after the move animation and the HP-bar drain
-- (BattleState.onFaint's own comment), and the drain takes real frames: a
-- 150 HP mon's bar walks down over some four seconds.
--
-- So asking for the faint animation at `onFaint` played it against a bar
-- that was still emptying: the Pokemon lay down, and then its health went on
-- draining above the corpse. What the player reads as the moment of death is
-- the bar hitting zero, and that is what this waits for.
--
-- `shownHP` is the engine's own bar position (BattleState.stepHPDrain walks
-- it toward mon.hp a point at a time), so this is not a guess at the timing
-- -- it is the same number the bar is drawn from.
local function faintReady(battler)
  if not battler then return false end
  -- nothing is animating the bar for this battler: there is nothing to wait
  -- for, and waiting forever would mean never collapsing at all
  if battler.shownHP == nil then return true end
  return battler.shownHP <= 0
end

-- Whether a pending collapse is still owed. A switch, a revive or a battler
-- that was replaced under us drops it rather than firing late at whoever is
-- standing there now.
local function faintStillDue(battler)
  return (battler and battler.faintQueued
          and battler.mon and (battler.mon.hp or 0) <= 0) and true or false
end

-- named for the suite: these timing rules are the whole of what decides when
-- a Pokemon falls and when it goes, and they are testable without a graphics
-- context where the mode itself is not
Stadium._faintReady = faintReady
Stadium._faintStillDue = faintStillDue

-- ------- per frame
--
-- Runs from OverworldBattle.update, before the pics are rendered and before
-- the scene is drawn: what this decides is exactly which sides need a pic.
function Stadium.update(dt, battle, groundY)
  if not session then return end
  session.groundY = groundY or session.groundY or 0
  if not battle then return end

  local arena = session.arena
  for _, side in ipairs({ "enemy", "player" }) do
    local mon = session[side]
    local battler = side == "player" and battle.player or battle.enemy
    local dex = nil
    if battler and not showingTrainer(battle, side) then
      dex = session.transform[side] or dexOf(battler.mon and battler.mon.species)
    end

    -- A DIFFERENT POKEMON IS IN THIS SLOT. Normally that shows up as a
    -- change of species and setSpecies rebuilds everything -- but a trainer
    -- who leads with two Rattata sends the second one out onto the first
    -- one's dex number, so nothing downstream would notice. What it would
    -- inherit is the state, and the state after a faint is `faint`, which
    -- refuses every request there is (see StadiumMon.request -- a faint is
    -- meant to be final). The new Pokemon would arrive lying on the ground.
    --
    -- The battler TABLE is the identity here rather than the species or the
    -- mon: it is the slot's occupant, and the engine replaces it on a switch,
    -- a send-out and a new battle alike.
    if session.at[side] ~= battler then
      session.at[side] = battler
      -- a fresh arrival: this Pokemon has not grown out of its ball yet
      if mon then mon.grow, mon.grewOwn = nil, nil end
      if mon and mon.rig and mon.state == "faint" then mon:play("idle") end
    end
    -- the collapse this side is owed, once its bar has finished emptying
    if session.faintPending and session.faintPending[side] then
      if not faintStillDue(battler) then
        session.faintPending[side] = nil
      elseif faintReady(battler) then
        session.faintPending[side] = nil
        if mon and mon.rig then mon:request("faint") end
      end
    end

    mon:setSpecies(dex)
    -- and tell the pack cache this one is standing there, every frame. Its
    -- eviction order is keyed on LOADS, and a side only loads when its
    -- species changes -- so without this a Pokemon that has been out for a
    -- few turns is the least recently loaded thing in the cache and gets its
    -- textures released out from under it the moment a fifth species enters
    -- the battle (see StadiumPack.keep).
    if mon.species then StadiumPack.keep(mon.species) end
    mon.visible = (mon.rig ~= nil) and onField(battle, side, mon)
                  and not (battler and battler.substituteHP)
    -- cleared up front, so a side that has just lost its rig cannot leave
    -- last frame's matrix behind it
    mon.model_matrix = nil

    if mon.rig then
      -- ------- the ball is opening: start growing out of it
      --
      -- The POOF is the ball coming apart, and it is where a Pokemon should
      -- begin to exist -- not 27 frames later when the engine starts scaling
      -- up the flat pic it was written for. Only for a side the battle says
      -- is actually sending out, so the same animation played at a thrown
      -- Poke Ball (a capture attempt, which aims it at the FOE) cannot start
      -- the wrong Pokemon growing.
      local poof = (battle.animPlaying
                    and battle.animName == "POOF_ANIM") and true or false
      local sending = (side == "player") and battle.sendingOut
                      or battle.enemySendingOut
      if poof and sending and mon:beginGrow() then
        -- and the arrival animation with it, so the whole thing is one
        -- performance rather than a grow followed by a flourish
        mon:request("entrance")
      end

      -- how big it is drawn. Its own ramp while it is growing (see
      -- StadiumMon.growScale); the engine's three-step one otherwise, which
      -- still covers a send-out that never showed a poof.
      if mon.grow then
        mon.scale = mon:growScale()
      elseif mon.grewOwn then
        mon.scale = 1
      else
        local okG, grow = pcall(battle.growInScale, battle, battler)
        mon.scale = (okG and grow) or 1
      end
      mon:update(dt or 0)
      if mon.visible and arena then
        local cell = arena[side]
        local other = arena[side == "player" and "enemy" or "player"]
        if cell and other then
          -- posed and skinned inside the same guard the draws use: this is
          -- where a bad track or a released texture is first touched, and a
          -- throw here would take the OTHER side's update with it (the
          -- caller wraps this whole function in one pcall)
          Stadium.guard(side, mon, "build", function()
            mon.model_matrix = mon:matrix(cell[1], session.groundY, cell[2],
                                          other[1] - cell[1],
                                          other[2] - cell[2])
            mon:build()
          end)
        else
          mon.model_matrix = nil
        end
      else
        mon.model_matrix = nil
      end
    end
  end
  Stadium.debug(dt)
end

-- ------- the draws
--
-- Both take the pass as they find it: this is called from inside
-- BattleScene's own beginScene/endScene window (and, in a headset, from
-- VoxelScene's), so the camera, the shadow map, the hour's tint and the hit
-- flash are all already set. StadiumRig turns the wireframe and the glass
-- mask off around its own draws and puts them back.

-- ------- one model going wrong is not both
--
-- These two draws used to be a bare loop inside the caller's single pcall,
-- which had two consequences and both were bad. A throw on the FIRST side
-- skipped the second, so one broken Pokemon took its opponent off the screen
-- with it. And nothing recorded that it had happened, so the same throw came
-- back every frame for the rest of the fight -- the mode's own fallback (that
-- side draws its flat pic instead) was sitting right there and never reached,
-- because falling back needs somebody to decide the model is not working.
--
-- So each side is drawn inside its own pcall, and a side that throws is
-- RETIRED: its rig is released, which is exactly the state a species with no
-- pack is in, and OverworldBattle renders a billboard for it from the next
-- frame on. The fight carries on with a flat Pokemon instead of a missing
-- one, which is the difference the player actually sees.
-- On the TABLE rather than a local, because Stadium.update calls it and sits
-- above this line: a local would still be nil there.
function Stadium.guard(side, mon, what, fn)
  local ok, err = pcall(fn)
  if ok then return true end
  Stadium.report(err)
  -- release rather than merely hide: the rig holds meshes and texture
  -- references, and whatever went wrong with them is not going to be better
  -- next frame. setSpecies rebuilds from scratch if this Pokemon is sent out
  -- again later.
  if mon.rig then pcall(mon.release, mon) end
  mon.rig, mon.visible, mon.model_matrix = nil, false, nil
  if session then session.broken = session.broken or {} end
  if session then session.broken[side] = what end
  return false
end

function Stadium.draw(pull)
  if not session then return end
  for _, side in ipairs({ "enemy", "player" }) do
    local mon = session[side]
    if mon.rig and mon.visible and mon.model_matrix then
      Stadium.guard(side, mon, "draw", function()
        mon.rig:draw(mon.model_matrix, pull)
      end)
    end
  end
end

-- The same models as the SUN sees them, so a Pokemon throws the shadow of
-- the pose it is actually in -- an outstretched wing puts an outstretched
-- wing on the ground.
function Stadium.cast(shadowMap)
  if not session then return end
  for _, side in ipairs({ "enemy", "player" }) do
    local mon = session[side]
    if mon.rig and mon.visible and mon.model_matrix then
      Stadium.guard(side, mon, "cast", function()
        mon.rig:caster(shadowMap, mon.model_matrix)
      end)
    end
  end
end

-- Which state a side's model is playing, or nil. Named for the shot drivers:
-- checking that an animation starts on the right FRAME is an ordering
-- question, and a screenshot cannot answer one.
function Stadium.animOf(side)
  if not session then return nil end
  local mon = session[side]
  return mon and mon.state or nil
end

-- Whether this side's model is actually being drawn this frame. Named for
-- the shot drivers alongside animOf: "how long does it stay" is a span, and
-- a screenshot taken at one moment has no span in it.
function Stadium.showing(side)
  if not session then return false end
  local mon = session[side]
  return (mon and mon.visible) and true or false
end

-- How big this side's model is being drawn this frame, 0..1 -- the send-out
-- grow. Named for the shot drivers: a ramp is a curve over time and a
-- screenshot has one point of it.
function Stadium.scaleOf(side)
  if not session then return nil end
  local mon = session[side]
  return mon and mon.scale or nil
end

-- How wide the Pokemon on `side` stands, in world pixels, or nil when there
-- is not one. What STADIUM B sizes that side's platform to (StadiumStage).
function Stadium.footprint(side)
  if not session then return nil end
  local mon = session[side]
  if not (mon and mon.model) then return nil end
  local r = mon:worldRadius()
  return (r > 0) and r or nil
end

-- Whether anything at all is standing this frame -- what the shadow
-- signature keys on alongside the pics' own token.
function Stadium.standing()
  if not session then return false end
  return (session.player.visible or session.enemy.visible) and true or false
end

-- ------- what the fight asks for
--
-- The animation state machine is driven from four points in the engine's
-- own battle, and each is a wrap rather than a rewrite: the inner function
-- runs exactly as it always did and this reads what went past.

local function sideOf(battle, battler)
  if not (session and battler) then return nil end
  if battler == battle.player then return "player" end
  if battler == battle.enemy then return "enemy" end
  return nil
end

local function ask(battle, battler, state, animIndex, auxIndex)
  local side = sideOf(battle, battler)
  if not side then return end
  local mon = session[side]
  if mon and mon.rig then mon:request(state, animIndex, auxIndex) end
end

function Stadium.install()
  local BattleState = require("src.battle.BattleState")
  if BattleState.dramaticShapeStadiumHook then return end
  BattleState.dramaticShapeStadiumHook = true

  -- THE ATTACK. performMove is the one place a move is actually used, and
  -- the move's own `index` is the Gen 1 move id the Stadium tables are
  -- keyed by -- so the species' own animation for that move comes straight
  -- out of the pack, with no name mapping and no per-move code.
  local innerMove = BattleState.performMove
  function BattleState:performMove(user, target, moveInst, isCalled)
    if session then
      local side = sideOf(self, user)
      local mon = side and session[side]
      if mon and mon.rig then
        local okDef, def = pcall(self.moveDef, self, moveInst)
        local index = okDef and def and def.index or nil
        if not (index and mon:attack(index)) then
          -- a move the table has nothing for still swings: the generic
          -- attack is what the species' own reaction slot resolves to
          mon:request("attack")
        end
      end
    end
    return innerMove(self, user, target, moveInst, isCalled)
  end

  -- THE HIT is deliberately NOT hooked. There is no damage reaction in this
  -- set to play -- what looked like one is the species' default attack (see
  -- StadiumMon's STATES), which is why being hit used to look like swinging.
  -- The engine's own flash, pic blink and bar drain are what say "that hurt",
  -- and they are already in the frame.

  -- THE FAINT. Held on its last frame rather than looped (see StadiumMon's
  -- STATES), because a Pokemon that collapses and then stands back up
  -- while the message is still on screen is worse than no animation.
  --
  -- RECORDED HERE, PLAYED LATER. This runs the moment HP reaches zero, which
  -- is several seconds before the Pokemon is supposed to fall over -- the
  -- engine queues the collapse behind the move animation and the HP-bar
  -- drain. Marking the side and letting Stadium.update fire it when the bar
  -- empties is what keeps the two together (see faintReady).
  local innerFaint = BattleState.onFaint
  function BattleState:onFaint(battler)
    if session and not (battler and battler.faintQueued) then
      local side = sideOf(self, battler)
      if side and session.faintPending then
        session.faintPending[side] = true
      end
    end
    return innerFaint(self, battler)
  end

  -- THE ENTRANCE. startGrowIn is the send-out: the ball opens, the pic
  -- scales up over twelve frames, and the model plays the animation the
  -- battle system's own entrance slot names.
  local innerGrow = BattleState.startGrowIn
  function BattleState:startGrowIn(battler)
    if session then
      -- unless the model is already on its way out of the ball, in which
      -- case the entrance started with the POOF (see update) and asking
      -- again here would restart it a third of a second in
      local side = sideOf(self, battler)
      local mon = side and session[side]
      if not (mon and mon.grow) then ask(self, battler, "entrance") end
    end
    return innerGrow(self, battler)
  end

  -- TRANSFORM. The engine records a transform by swapping the battler's
  -- sprite and nothing else, so this is the only seam that reports one --
  -- and it reports the side, which is all that is needed to point that
  -- side's model at the copied species. Cleared when a side's own species
  -- changes under it (a switch, or the next battle).
  local innerSpecies = BattleState.speciesSprite
  function BattleState:speciesSprite(species, isPlayerSide)
    if session then
      session.transform[isPlayerSide and "player" or "enemy"] = dexOf(species)
    end
    return innerSpecies(self, species, isPlayerSide)
  end

  -- and a switch or a send-out ends any transform on that side
  local innerSwitch = BattleState.resolveSwitch
  function BattleState:resolveSwitch(newMon)
    if session then session.transform.player = nil end
    return innerSwitch(self, newMon)
  end
end

-- ------- when a draw goes wrong
--
-- The draw and the shadow cast are both called through a pcall, because a
-- throw inside the scene pass would hand the whole voxel mode to Pipelines'
-- guard and retire it for the session. Swallowed silently, though, a broken
-- model is indistinguishable from an invisible one -- so the first failure
-- of a battle says so, once, and the rest of the fight carries on without
-- it.
Stadium.reported = false

function Stadium.report(err)
  if Stadium.reported then return end
  Stadium.reported = true
  V.mod.log:warn("stadium: a model failed and was retired for this battle: "
                 .. "%s -- that Pokemon falls back to its flat battle pic, "
                 .. "and its opponent is unaffected", tostring(err))
end

-- DS_STADIUM_DEBUG=1 prints what each side resolved to once a second, which
-- is how "nothing is on screen" gets told apart from "nothing was asked
-- for". Read through pcall: the loader's sandbox does not hand a mod `os`,
-- and a diagnostic must never be why the mod fails to load.
local DEBUG = select(2, pcall(function() return os.getenv("DS_STADIUM_DEBUG") end))
if DEBUG == nil or DEBUG == false then DEBUG = nil end

local debugAt = 0

function Stadium.debug(dt)
  if not (DEBUG and session) then return end
  debugAt = debugAt + (dt or 0)
  if debugAt < 1 then return end
  debugAt = 0
  for _, side in ipairs({ "enemy", "player" }) do
    local mon = session[side]
    local m = mon.model_matrix
    V.mod.log:info("stadium %s: dex=%s rig=%s visible=%s anim=%s t=%.2f "
                   .. "height=%.1f at=%s",
                   side, tostring(mon.species), tostring(mon.rig ~= nil),
                   tostring(mon.visible), tostring(mon.anim), mon.time or 0,
                   mon.model and mon:worldHeight() or 0,
                   m and ("%.0f,%.0f,%.0f"):format(m[4], m[8], m[12]) or "-")
  end
end

function Stadium.invalidate()
  if session then
    session.player:release()
    session.enemy:release()
  end
  StadiumPack.invalidate()
  -- the discs are a mesh and a texture like anything else, and a graphics
  -- context that went away took them with it
  pcall(function() V.require("StadiumStage").invalidate() end)
end

return Stadium
