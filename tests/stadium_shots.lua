-- Driver: screenshot a STADIUM battle -- the 3D-BTL row's third rung, where
-- the two Pokemon are the Pokemon Stadium battle models rather than the
-- game's own pics stood up on their tiles.
--
-- What has to be looked at is a SPREAD OF SPECIES, because almost everything
-- that can go wrong here is per-model: how big it comes out (the size ladder
-- compresses a sixteenfold spread of authored heights -- see StadiumMon),
-- whether its feet are on the ground (the floor rule has to tell a hovering
-- Zubat from a Tentacruel centred on its own origin), whether the eyes
-- animate, and whether the species carries generated flame prims. So the
-- list below is deliberately awkward: the smallest and the largest in the
-- set, a hoverer, a floater, and the two species whose idle animation is
-- known to be wrong in the source data.
--
--   SHOT_DIR=.scratchpad DS_STADIUM_DEBUG=1 \
--     POKEPORT_DRIVER=mods/DramaticShapeVoxelMod/tests/stadium_shots.lua love .
--
-- SHOT_DIR must already exist: the capture writes with io.open, which does
-- not create directories.
return function(game)
  local U = dofile("tests/drivers/util.lua")
  local DIR = os.getenv("SHOT_DIR") or ".scratchpad"
  local Pokemon = require("src.pokemon.Pokemon")
  local BattleState = require("src.battle.BattleState")

  local exports = game.mods and game.mods.exports
  local lib = exports and exports.DRAMALESS_SHAPE and exports.DRAMALESS_SHAPE.lib
  if not lib then
    U.log("DRAMALESS_SHAPE is not loaded -- enable it and run again")
    return
  end
  local Battles = lib.require("OverworldBattle")
  local Stadium = lib.require("Stadium")
  local Pack = lib.require("StadiumPack")

  local Install = lib.require("StadiumInstall")

  game.save.player.name = "RED"

  -- foe, and the player's own, chosen to put two different problems in one
  -- frame wherever possible
  local CASES = {
    { "PIKACHU", "CHARIZARD" },   -- the reference pair; Charizard has flame
    { "ONIX", "DIGLETT" },        -- the tallest against nearly the shortest
    { "ZUBAT", "TENTACRUEL" },    -- hovers above its origin / hangs below it
    { "GASTLY", "CATERPIE" },     -- a floater and the smallest in the set
    -- the five hermite-keyframe species (flags & 8), which the extractor
    -- used to misread as packed streams: Exeggutor, Tangela and Magmar came
    -- out so garbled the packer declined them to flat pics, and Pidgeot and
    -- Dodrio animated garbled. All five must now stand as MODELS in a sane
    -- standby loop (see StadiumFragment's animation notes).
    { "EXEGGUTOR", "MAGMAR" },
    { "PIDGEOT", "TANGELA" },
    { "DODRIO", "PIDGEOTTO" },    -- with its packed-stream evolution as control
    { "GYARADOS", "SNORLAX" },    -- the two biggest bodies in the set
  }

  -- ONTO THE MAP FIRST, before anything below waits on anything.
  --
  -- The models are built out of the player's own ROM on first run, on a
  -- loading screen, and that screen is pushed from the mod's update hook on
  -- the first frame THE OVERWORLD IS THE TOP STATE (StadiumScreen.maybePush).
  -- A driver that waits for the build before it has got the player onto a map
  -- waits forever: the condition that starts the build is the very thing the
  -- waiting is postponing.
  -- DS_MAP puts the fight somewhere else. It exists for STADIUM B, whose
  -- whole claim is that it carries its stage: the shot has to be checked in a
  -- CAVE and in a SHOP as well as on a route, both because those are the
  -- places the map-staged rungs decline, and because the rung is supposed to
  -- take that place's own sky and light with it.
  local MAP = os.getenv("DS_MAP") or "ROUTE_1"
  local MX = tonumber(os.getenv("DS_X") or "") or 5
  local MY = tonumber(os.getenv("DS_Y") or "") or 8
  U.teleport(game, MAP, MX, MY, "down")

  -- Now wait it out, and say how long it took -- that number is what decides
  -- whether the loading screen is acceptable rather than merely correct.
  local waited, shotLoad = 0, false
  while (Install.pending() or Install.status.state == "building")
        and waited < 5400 do
    if not shotLoad and Install.status.state == "building"
        and (Install.status.done or 0) > 20 then
      U.shot(game, ("%s/00_loading.png"):format(DIR))
      shotLoad = true
    end
    U.wait(10)
    waited = waited + 10
  end
  if waited > 0 then
    U.log(("waited %d frames (%.1fs) for the model build -- %s")
          :format(waited, waited / 60, tostring(Install.status.state)))
    if Install.status.error then
      U.log("build error: " .. tostring(Install.status.error))
    end
  end
  U.log(("rom present: %s, packs ready: %s, stadium available: %s")
        :format(tostring(Install.romPresent()), tostring(Install.ready()),
                tostring(Install.available())))

  -- the rung under test, and the back pic OFF: BACK SPRITES would keep the
  -- player's own side on the menu, which is exactly the half of the shot
  -- this driver exists to look at
  local RUNGS = { cards = true, cardsb = "flatB", a = "stadium",
                  b = "stadiumB" }
  local rung = RUNGS[os.getenv("DS_RUNG") or "a"] or "stadium"
  Battles.setting:setValue(rung, game)
  Battles.backSetting:setValue(false, game)
  -- and PIN THE CLOCK. The hour multiplies everything in the shot -- the sky,
  -- the tint, the weight of the shadows -- so a driver left on CYCLE
  -- photographs a different scene every run, and two runs of it cannot be
  -- compared. DS_TOD overrides for a deliberate look at dusk or night.
  lib.require("DayNight").setting:setValue(os.getenv("DS_TOD") or "day", game)
  U.log(("3D-BTL = %s, stadium enabled = %s, discs = %s")
        :format(tostring(Battles.setting:get()), tostring(Stadium.enabled()),
                tostring(Stadium.discs())))

  -- did the models actually get built? one line rather than 151 silent
  -- declines
  local have, missing = 0, {}
  for dex = 1, 151 do
    if Pack.available(dex) then have = have + 1
    elseif #missing < 6 then missing[#missing + 1] = dex end
  end
  U.log(("stadium packs present: %d/151%s"):format(
        have, #missing > 0 and (" (missing " .. table.concat(missing, ",")
                                .. "...)") or ""))

  -- let the neighbourhood's meshes land before the first fight, so the
  -- opening frame is not the flat fallback
  U.wait(90)

  -- ------- DS_BLINK: how often does the eye actually change?
  --
  -- The texture animation rides the SKELETAL animation's frame and clamps
  -- past the end of its own stream (StadiumRig.textures). Get either wrong
  -- and a blink becomes a twitch: Rattata's standby loop is forty frames and
  -- its blink is five, so wrapping on the blink's own length plays it six
  -- times a second.
  --
  -- Counted rather than looked at, because "too fast" is a RATE and a
  -- screenshot has no rate in it. This walks the idle loop frame by frame and
  -- reports how many times the eye texture changes per second.
  if os.getenv("DS_BLINK") then
    local Pack = lib.require("StadiumPack")
    local Rig = lib.require("StadiumRig")
    for _, dex in ipairs({ 19, 4, 1, 25 }) do
      local model = Pack.load(dex)
      local rig = model and Rig.new(model)
      if rig then
        local idle = model.ctx[Pack.SLOT.idle]
        local anim = (idle ~= Pack.NONE) and (idle + 1) or nil
        local rec = anim and model.anims[anim]
        -- which prim carries the eye, and what it shows each frame
        local seen, changes, last = {}, 0, nil
        local SECONDS = 4
        for f = 0, SECONDS * Pack.FPS - 1 do
          rig:pose(anim, f, true)
          rig:textures(rec and rec.aux or nil)
          local key = {}
          for i, part in ipairs(rig.parts) do
            if part.prim.texAnim and part.prim.texAnim >= 0 then
              key[#key + 1] = i .. ":" .. tostring(part.texture)
            end
          end
          key = table.concat(key, ",")
          if last and key ~= last then changes = changes + 1 end
          last = key
          seen[key] = true
        end
        local looks = 0
        for _ in pairs(seen) do looks = looks + 1 end
        local period = rec and (rec.frames / Pack.FPS) or 0
        U.log(("BLINK dex %3d: idle %s frames (%.2fs), aux %s frames -- "
               .. "%d texture changes in %ds, %d distinct looks; the idle "
               .. "loop comes round every %.2fs, so that is %.1f changes a "
               .. "cycle")
              :format(dex, tostring(rec and rec.frames), period,
                      tostring(rec and rec.aux
                               and model.auxAnims[rec.aux].frames),
                      changes, SECONDS, looks, period,
                      period > 0 and changes / (SECONDS / period) or 0))
        rig:release()
      end
    end
    U.log("done -- " .. DIR)
    return
  end

  -- ------- DS_FLY: does the Pokemon actually leave?
  --
  -- FLY and DIG take the user off the field for a turn, and the engine says
  -- so through `picFx[battler].hidden` rather than through fxHidden (which is
  -- the damage blink alone). A model that ignores that stands on its tile
  -- while every attack aimed at it misses into empty air.
  --
  -- A TIMELINE again, not a still: what is being checked is that the model
  -- goes when the pic goes and comes back when it comes back, which is three
  -- moments and a screenshot has one.
  if os.getenv("DS_FLY") then
    local Stadium2 = lib.require("Stadium")
    local move = os.getenv("DS_MOVE") or "FLY"
    local mine = Pokemon.new(game.data, "CHARIZARD", 60)
    -- give it the move outright: what is under test is the vanish, not
    -- whether this species learns it by level 60
    mine.moves = { { id = move, pp = 15 } }
    game.save.party = { mine }
    local battle = BattleState.newWild(game, "PIKACHU", 5)
    battle.onFinish = function() end
    game.overworld:pushBattle(battle)
    U.wait(70)
    for _ = 1, 40 do
      if battle.phase == "menu" then break end
      U.tap(game, "a")
      U.wait(10)
    end
    U.tap(game, "a")      -- FIGHT
    U.wait(12)
    U.tap(game, "a")      -- the first (only) move

    local goneAt, backAt, wasGone = nil, nil, false
    for f = 1, 400 do
      if f % 20 == 0 then U.tap(game, "a") end
      U.wait(1)
      local me = battle.player
      local pf = battle.picFx and battle.picFx[me]
      local picHidden = (pf and pf.hidden) and true or false
      local showing = Stadium2.showing("player")
      if f % 25 == 0 or (picHidden ~= wasGone) then
        U.log(("  f=%3d picHidden=%-5s model=%-5s anim=%s")
              :format(f, tostring(picHidden), tostring(showing),
                      tostring(Stadium2.animOf("player"))))
      end
      if picHidden and not goneAt then goneAt = f end
      if picHidden and not showing and not wasGone then
        wasGone = true
        U.shot(game, ("%s/fly_1_gone.png"):format(DIR))
      end
      if wasGone and not picHidden and not backAt then
        backAt = f
        U.shot(game, ("%s/fly_2_back.png"):format(DIR))
        break
      end
    end
    U.log(("%s: the pic hid at frame %s, the model was gone with it (%s), "
           .. "and both came back at %s")
          :format(move, tostring(goneAt), tostring(wasGone), tostring(backAt)))
    U.log(wasGone and "  OK -- the model leaves the field with the pic"
          or "  WRONG -- the model stood there while the game said it was gone")
    while game.stack:top() and game.stack:top() ~= game.overworld do
      game.stack:pop()
    end
    U.wait(10)
    U.log("done -- " .. DIR)
    return
  end

  -- ------- DS_FAINT: does the collapse wait for the bar?
  --
  -- The faint animation must not start until the foe's HP bar has finished
  -- emptying: `onFaint` fires the instant HP reaches zero, but the engine
  -- queues the visible collapse behind the move animation and the drain, and
  -- a Pokemon that lies down while its own health is still draining above it
  -- reads as a bug (see Stadium's faintReady).
  --
  -- A TIMELINE rather than a screenshot, because what is being checked is an
  -- ORDER: the frame the bar reaches zero against the frame the animation
  -- changes. One printed line per frame settles that; two stills cannot.
  if os.getenv("DS_FAINT") then
    local Stadium2 = lib.require("Stadium")
    game.save.party = { Pokemon.new(game.data, "CHARIZARD", 60) }
    local battle = BattleState.newWild(game, "PIKACHU", 5)
    battle.onFinish = function() end
    game.overworld:pushBattle(battle)
    U.wait(70)
    for _ = 1, 40 do
      if battle.phase == "menu" then break end
      U.tap(game, "a")
      U.wait(10)
    end
    U.tap(game, "a")
    U.wait(12)
    U.tap(game, "a")

    local barZeroAt, animAt, shot, stood = nil, nil, false, 0
    for f = 1, 700 do
      -- keep advancing the text, as a player would. Without this the queue
      -- blocks on the damage message and the HP bar never drains at all --
      -- which is a perfectly good demonstration that the collapse now waits,
      -- and no demonstration whatever that it eventually arrives.
      if f % 20 == 0 then U.tap(game, "a") end
      U.wait(1)
      local foe = battle.enemy
      local shown = foe and foe.shownHP
      local anim = Stadium2.animOf and Stadium2.animOf("enemy") or nil
      if f % 25 == 0 or (shown and shown <= 0 and not barZeroAt) then
        U.log(("  f=%3d phase=%s shownHP=%s hp=%s queued=%s anim=%s")
              :format(f, tostring(battle.phase), tostring(shown),
                      tostring(foe and foe.mon and foe.mon.hp),
                      tostring(foe and foe.faintQueued), tostring(anim)))
      end
      if shown and shown <= 0 and not barZeroAt then barZeroAt = f end
      if anim == "faint" and not animAt then animAt = f end
      -- a still from the middle of the drain: the foe must still be standing
      if shown and shown > 0 and not shot and barZeroAt == nil
          and foe and foe.faintQueued then
        U.shot(game, ("%s/faint_1_draining.png"):format(DIR))
        shot = true
      end
      -- and how long the model then STAYS. The engine takes the flat pic off
      -- after a fourteen-frame slide; the animation runs for one to eight
      -- seconds, and being cut off mid-fall is worse than not falling at all.
      if animAt and Stadium2.showing("enemy") then stood = f - animAt end
      if animAt and f == animAt + 20 then
        U.shot(game, ("%s/faint_2_collapsing.png"):format(DIR))
      end
      if animAt and f == animAt + 90 then
        U.shot(game, ("%s/faint_3_still_falling.png"):format(DIR))
      end
      if animAt and f > animAt + 20 and not Stadium2.showing("enemy") then
        U.shot(game, ("%s/faint_4_gone.png"):format(DIR))
        break
      end
    end
    U.log(("FAINT: bar reached zero at frame %s, faint animation began at %s")
          :format(tostring(barZeroAt), tostring(animAt)))
    if barZeroAt and animAt then
      U.log((animAt >= barZeroAt)
            and "  OK -- the collapse waits for the bar"
            or "  WRONG -- the collapse ran while the bar was still draining")
    end
    U.log(("  the model stayed on the field for %d frames (%.2fs) after the "
           .. "collapse began; the engine's own pic slide is 14 (%.2fs)")
          :format(stood, stood / 60, 14 / 60))
    while game.stack:top() and game.stack:top() ~= game.overworld do
      game.stack:pop()
    end
    U.wait(10)
    U.log("done -- " .. DIR)
    return
  end

  for i, case in ipairs(CASES) do
    local foe, mine = case[1], case[2]
    local tag = ("%02d_%s_vs_%s"):format(i, mine:lower(), foe:lower())
    game.save.party = { Pokemon.new(game.data, mine, 40) }

    local battle = BattleState.newWild(game, foe, 30)
    battle.onFinish = function() end
    game.overworld:pushBattle(battle)

    -- The wipe, then the intro chatter, and -- the part that matters --
    -- far enough past it that the player's own Pokemon has been SENT OUT.
    -- Before that the player's side is legitimately the trainer's back
    -- sprite, with no Pokemon on the field to model at all; a shot taken
    -- there looks exactly like a bug and is not one.
    U.wait(70)
    -- tap until the FIGHT menu is up, which is the first moment BOTH
    -- Pokemon are on the field in their standby loop
    for _ = 1, 40 do
      if battle.phase == "menu" then break end
      U.tap(game, "a")
      U.wait(10)
    end
    U.wait(45)
    U.shot(game, ("%s/%s_1_idle.png"):format(DIR, tag))

    -- FIGHT -> the first move, which is where the attack animation is
    U.tap(game, "a")
    U.wait(12)
    U.tap(game, "a")
    U.wait(22)
    U.shot(game, ("%s/%s_2_attack.png"):format(DIR, tag))
    U.wait(45)
    U.shot(game, ("%s/%s_3_hit.png"):format(DIR, tag))

    while game.stack:top() and game.stack:top() ~= game.overworld do
      game.stack:pop()
    end
    U.wait(10)
  end

  U.log("done -- " .. DIR)
end
