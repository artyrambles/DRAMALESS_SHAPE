-- Driver: the send-out ENTRANCE, frame by frame, for the two species the
-- animation QA sweep flags as flying apart in that animation alone.
return function(game)
  local U = dofile("tests/drivers/util.lua")
  local DIR = os.getenv("SHOT_DIR") or ".scratchpad"
  local Pokemon = require("src.pokemon.Pokemon")
  local BattleState = require("src.battle.BattleState")
  local lib = game.mods.exports.DRAMALESS_SHAPE.lib
  local Battles = lib.require("OverworldBattle")
  local Stadium = lib.require("Stadium")
  local Install = lib.require("StadiumInstall")

  game.save.player.name = "RED"
  U.teleport(game, "ROUTE_1", 5, 8, "down")
  local waited = 0
  while (Install.pending() or Install.status.state == "building")
        and waited < 5400 do U.wait(10); waited = waited + 10 end
  while game.stack:top() and game.stack:top() ~= game.overworld do U.wait(10) end

  Battles.setting:setValue(os.getenv("DS_RUNG") or "stadiumB", game)
  Battles.backSetting:setValue(false, game)
  lib.require("DayNight").setting:setValue("day", game)
  U.wait(60)

  for _, name in ipairs({ "FARFETCHD", "DEWGONG" }) do
    game.save.party = { Pokemon.new(game.data, name, 40) }
    local battle = BattleState.newWild(game, "PIKACHU", 20)
    battle.onFinish = function() end
    game.overworld:pushBattle(battle)
    -- ONE loop from the first frame: the send-out needs taps to get past
    -- the intro text, and the entrance starts the instant it happens -- so
    -- watching and tapping have to be the same loop or the animation is over
    -- before the watching begins (which is exactly what a split loop did).
    local shot, sawEntrance = 0, false
    for f = 1, 900 do
      U.wait(1)
      local anim = Stadium.animOf("player")
      if anim == "entrance" then
        sawEntrance = true
        if f % 14 == 0 and shot < 8 then
          shot = shot + 1
          U.shot(game, ("%s/%s_entrance_%d.png"):format(DIR, name:lower(), shot))
        end
      elseif sawEntrance then
        break
      end
      if not sawEntrance and f % 12 == 0 then U.tap(game, "a") end
    end
    U.log(("%s: took %d entrance stills, anim now %s")
          :format(name, shot, tostring(Stadium.animOf("player"))))
    while game.stack:top() and game.stack:top() ~= game.overworld do
      game.stack:pop()
    end
    U.wait(10)
  end
  U.log("done -- " .. DIR)
end
