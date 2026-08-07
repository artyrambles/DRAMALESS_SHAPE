-- Driver: one STADIUM screenshot per species, every one of the 151 standing
-- on the ENEMY mark in its standby loop.
--
-- stadium_shots.lua photographs a handful of deliberately awkward cases; this
-- is the exhaustive sweep behind it. What it exists to catch is the class of
-- fault that is per-MODEL and invisible to the headless QA pass -- a texture
-- that comes out magenta, a mon standing in the floor or floating over it, a
-- silhouette that is subtly the wrong shape -- none of which is a number
-- stadium_anim_qa.lua can measure.
--
--   SHOT_DIR=mods/DramaticShapeVoxelMod/.claude/stadium_verify \
--   POKEPORT_SPEED=4 \
--   POKEPORT_DRIVER=mods/DramaticShapeVoxelMod/tests/stadium_all_shots.lua \
--   lovec.exe .
--
-- Files land as NNN_species.png in dex order. Run from the PROJECT ROOT.
--
-- ------- everything but the foe is nailed down
--
-- The whole value of 151 shots is that they are comparable, so the staging is
-- identical in every one: same map, same cells, same hour (the day/night
-- cycle would otherwise relight every shot), same rung, and the same small
-- Pokemon on the player's mark -- DIGLETT, chosen because it is the shortest
-- model in the set and so hides the least of the arena behind it. Whatever
-- differs between two of these shots is the foe.
--
-- ------- the model/sprite verdict is the other half
--
-- A species whose pack will not load, or whose animation data the packer
-- declined, does not error: StadiumMon.setSpecies answers false and the mode
-- quietly stands the Game Boy's flat pic on the tile instead. That is the
-- correct behaviour and it is nearly invisible in a screenshot at a glance --
-- which is exactly why it needs counting rather than looking. Stadium.showing
-- is asked for every species and the ones that decline are listed at the end.
return function(game)
  local U = dofile("tests/drivers/util.lua")
  local DIR = os.getenv("SHOT_DIR") or ".claude/stadium_verify"
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

  -- every real species the merged data carries, in dex order
  local species = {}
  for id, def in pairs(game.data.pokemon) do
    if type(id) == "string" and type(def) == "table"
       and def.dex and def.dex >= 1 and def.dex <= 151 then
      species[#species + 1] = { id = id, dex = def.dex }
    end
  end
  table.sort(species, function(a, b) return a.dex < b.dex end)

  game.save.player.name = "RED"

  -- ONTO THE MAP FIRST: the model build (if one is owed) is pushed from the
  -- mod's update hook on the first frame the overworld is the top state, so
  -- waiting for it before teleporting waits forever.
  U.teleport(game, "ROUTE_1", 5, 8, "down")

  local waited = 0
  while (Install.pending() or Install.status.state == "building")
        and waited < 5400 do
    U.wait(10)
    waited = waited + 10
  end
  if waited > 0 then
    U.log(("waited %.1fs for the model build -- %s")
          :format(waited / 60, tostring(Install.status.state)))
  end

  Battles.setting:setValue("stadium", game)
  Battles.backSetting:setValue(false, game)
  lib.require("DayNight").setting:setValue(os.getenv("DS_TOD") or "day", game)

  local have = 0
  for dex = 1, 151 do
    if Pack.available(dex) then have = have + 1 end
  end
  U.log(("%d species, %d/151 packs on disk, rung = %s")
        :format(#species, have, tostring(Battles.setting:get())))

  -- let the neighbourhood's meshes land, so the first fight opens on the
  -- real arena rather than the flat fallback
  U.wait(90)

  local asPic, stuck, missed = {}, {}, {}

  for _, s in ipairs(species) do
    -- the player's side is a constant (see the header), so the only thing
    -- that changes between two shots is the Pokemon being verified
    game.save.party = { Pokemon.new(game.data, "DIGLETT", 40) }

    local battle = BattleState.newWild(game, s.id, 30)
    battle.onFinish = function() end
    game.overworld:pushBattle(battle)

    -- the wipe and the intro chatter, then far enough past it that the
    -- player's own Pokemon has been sent out -- before that the player's
    -- side is legitimately the trainer's back sprite and the foe is still
    -- sliding in
    U.wait(70)
    for _ = 1, 40 do
      if battle.phase == "menu" then break end
      U.tap(game, "a")
      U.wait(10)
    end
    if battle.phase ~= "menu" then
      stuck[#stuck + 1] = s.id
      U.log(("STUCK before menu: %s (phase %s)")
            :format(s.id, tostring(battle.phase)))
    end
    -- and let the send-out beat finish so the mon is standing still in its
    -- standby loop rather than mid-arrival
    U.wait(45)

    -- model or flat pic? asked here, with the fight actually on screen
    if not Stadium.showing("enemy") then
      asPic[#asPic + 1] = ("%03d %s"):format(s.dex, s.id)
    end

    local path = ("%s/%03d_%s.png"):format(DIR, s.dex, s.id:lower())
    if not U.shot(game, path) then
      missed[#missed + 1] = s.id
    end

    while game.stack:top() and game.stack:top() ~= game.overworld do
      game.stack:pop()
    end
    U.wait(10)
  end

  U.log(("---- %d shots -> %s"):format(#species - #missed, DIR))
  if #asPic > 0 then
    U.log(("%d species declined to a model and were shot as FLAT PICS: %s")
          :format(#asPic, table.concat(asPic, ", ")))
  else
    U.log("all species stood as MODELS -- none fell back to a flat pic")
  end
  if #stuck > 0 then
    U.log(("%d never reached the battle menu: %s")
          :format(#stuck, table.concat(stuck, ", ")))
  end
  if #missed > 0 then
    U.log(("%d screenshots did not reach disk: %s")
          :format(#missed, table.concat(missed, ", ")))
  end
  U.log("done -- " .. DIR)
end
