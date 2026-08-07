return function(game)
  local U = dofile("tests/drivers/util.lua")
  local Pokemon = require("src.pokemon.Pokemon")
  local BattleState = require("src.battle.BattleState")
  local lib = game.mods.exports.DRAMALESS_SHAPE.lib
  local Battles = lib.require("OverworldBattle")
  local Stadium = lib.require("Stadium")
  local Install = lib.require("StadiumInstall")

  U.teleport(game, "ROUTE_1", 5, 8, "down")
  local w = 0
  while (Install.pending() or Install.status.state == "building") and w < 5400 do
    U.wait(10); w = w + 10
  end
  while game.stack:top() and game.stack:top() ~= game.overworld do U.wait(10) end
  Battles.setting:setValue("stadium", game)
  Battles.backSetting:setValue(false, game)
  U.wait(60)

  local marks = {}
  local inner = BattleState.startGrowIn
  BattleState.startGrowIn = function(self, b)
    marks[#marks + 1] = { side = (b == self.player) and "player" or "enemy" }
    return inner(self, b)
  end

  game.save.party = { Pokemon.new(game.data, "PIDGEY", 30) }
  local battle = BattleState.newWild(game, "PIKACHU", 5)
  battle.onFinish = function() end
  game.overworld:pushBattle(battle)

  local seen, lastState, lastGrow, nMark = {}, "?", false, 0
  local shotAt = {}
  for f = 1, 500 do
    U.wait(1)
    if f % 10 == 0 and battle.phase ~= "menu" then U.tap(game, "a") end
    local st = Stadium.animOf("player") or "-"
    local grow = battle.growIn ~= nil
    if #marks > nMark then
      nMark = #marks
      U.log(("f=%3d  >> startGrowIn(%s)   player model present: %s, state %s")
            :format(f, marks[nMark].side, tostring(Stadium.showing("player")),
                    st))
    end
    local poof = (battle.animPlaying and battle.animName == "POOF_ANIM")
                 and true or false
    local key = ("%s|%s|%s|%s|%s|%s|%s|%s|%s"):format(st,
      tostring(math.floor((Stadium.scaleOf("player") or 1) * 20)),
      tostring(poof), tostring(battle.sendingOut),
      tostring(battle.phase), tostring(Stadium.showing("player")),
      tostring(battle.showPlayerBack), tostring(battle.playerBackPic ~= nil),
      tostring((battle.introSlide or 0) > 0))
    if key ~= lastState then
      U.log(("f=%3d state=%-9s sendingOut=%-5s poof=%-5s growIn=%-5s "
             .. "growScale=%-6s model=%s")
            :format(f, st, tostring(battle.sendingOut), tostring(poof),
                    tostring(grow), tostring(Stadium.scaleOf("player")),
                    tostring(Stadium.showing("player"))))
      lastState = key
    end
    -- stills across the grow, so the ramp can be looked at and not just read
    local sc = Stadium.scaleOf("player")
    if Stadium.showing("player") and sc then
      for _, want in ipairs({ 0.15, 0.45, 0.75, 1.0 }) do
        if not shotAt[want] and sc >= want then
          shotAt[want] = true
          U.shot(game, ("%s/grow_%02d.png")
                 :format(os.getenv("SHOT_DIR") or ".", want * 100))
        end
      end
    end
    seen[st] = true
  end
  for i = 1, 4 do
    U.shot(game, (os.getenv("SHOT_DIR") or ".") .. ("/pidgey_%d.png"):format(i))
    U.wait(2)
  end
  local list = {}
  for k in pairs(seen) do list[#list + 1] = k end
  table.sort(list)
  U.log("states the player's side passed through: " .. table.concat(list, ", "))
  U.log("startGrowIn calls: " .. #marks)
  U.log("done")
end
