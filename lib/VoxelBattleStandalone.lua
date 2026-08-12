-- Standalone host for Dramaless's retained voxel-map + native-2D-card mode.
-- It is activated only when StadiumBattleFX is absent. With Stadium present,
-- the same two providers are registered there and this host stays dormant.

local V = ...

local Host = { session = nil }
local GB_W, GB_H = 160, 144
local installedDraw, installedPicsLayer

local function project(vp, width, height, x, y, z)
  local cx = vp[1] * x + vp[2] * y + vp[3] * z + vp[4]
  local cy = vp[5] * x + vp[6] * y + vp[7] * z + vp[8]
  local cw = vp[13] * x + vp[14] * y + vp[15] * z + vp[16]
  if cw <= 1e-6 then return nil end
  return (cx / cw * .5 + .5) * width, (cy / cw * .5 + .5) * height
end

local function invoke(session, owner, method, ...)
  local fn = owner and owner[method]
  if type(fn) ~= "function" then return true, nil end
  local ok, a, b = pcall(fn, owner, session.context, ...)
  if not ok then
    V.log:error("standalone voxel battle provider failed: method=%s error=%s",
      tostring(method), tostring(a))
    return false, a
  end
  return true, a, b
end

local function contextFor(battle)
  local context = {
    apiVersion = 1,
    battle = battle,
    game = battle and battle.game,
    encounter = { kind = battle and battle.kind },
    sides = {
      player = { battler = battle and battle.player },
      enemy = { battler = battle and battle.enemy },
    },
    phase = "intro",
    groundY = 0,
    services = { log = V.log },
  }
  context.services.withNativeBattlePics = function(fn, ...)
    local session = Host.session
    if not (session and session.battle == battle and type(fn) == "function") then
      return false, "standalone voxel battle session is not active"
    end
    session.capturingNativePics = true
    local results = { pcall(fn, ...) }
    session.capturingNativePics = nil
    if not results[1] then return false, results[2] end
    table.remove(results, 1)
    return true, unpack(results)
  end
  return context
end

function Host.begin(battle, arenaProvider, cardProvider)
  Host.finish("replaced")
  if not (battle and arenaProvider and cardProvider) then return false end
  local session = {
    battle = battle,
    arenaProvider = arenaProvider,
    cardProvider = cardProvider,
    context = contextFor(battle),
  }
  Host.session = session

  local okArena, arena = invoke(session, arenaProvider, "arena")
  if not (okArena and arena) then
    Host.session = nil
    return false
  end
  session.context.arena = arena
  local installedCards, installAnswer = invoke(session, cardProvider, "install")
  if not installedCards or installAnswer == false then
    Host.finish("cards-install-declined")
    return false
  end
  local beganArena, acceptedArena = invoke(session, arenaProvider, "begin", arena)
  if not beganArena or acceptedArena == false then
    Host.finish("arena-declined")
    return false
  end
  local beganCards, acceptedCards = invoke(session, cardProvider, "begin", arena)
  if not beganCards or acceptedCards == false then
    Host.finish("cards-declined")
    return false
  end
  V.log:event("battle", "standalone-voxel-2d-begin", {
    arena = arena.id or "unknown",
  })
  return true
end

function Host.update(dt)
  local session = Host.session
  if not session then return end
  invoke(session, session.arenaProvider, "update", dt or 0,
    session.context.arena)
  invoke(session, session.cardProvider, "update", dt or 0)
end

-- Suppress each native picture side only after its projected card was drawn
-- into the voxel scene. Hooking
-- drawBattlerPic is insufficient: trainer pictures and send-out growth frames
-- are drawn directly by drawPicsLayer and would otherwise appear a second
-- time over the arena.
function Host.coversSide(battle, side)
  local session = Host.session
  if not (session and session.battle == battle and session.presented
      and not session.capturingNativePics) then return false end
  local ok, covered = invoke(session, session.cardProvider, "covers", side)
  return ok and covered and true or false
end

local function presentWorld(session, surface)
  local renderer = session.battle and session.battle.game
    and session.battle.game.renderer
  if not (renderer and renderer.setWorldOverride and surface) then return false end
  renderer:setWorldOverride(surface)
  session.presented = true
  return true
end

function Host.draw(battle)
  local session = Host.session
  if not (session and session.battle == battle) then return false end
  session.presented = false
  local function drawActors(world)
    world = world or {}
    local width, height = tonumber(world.width), tonumber(world.height)
    if not (width and height and width > 0 and height > 0) then
      width, height = love.graphics.getDimensions()
    end
    if tonumber(world.groundY) then session.context.groundY = world.groundY end
    if type(world.project) == "function" then
      session.context.services.project = world.project
    elseif world.vp then
      session.context.services.project = function(x, y, z)
        return project(world.vp, width, height, x, y, z)
      end
    end
    session.context.services.renderSize = { width = width, height = height }
    invoke(session, session.cardProvider, "drawWorld", 0)
  end
  local ok, surface = invoke(session, session.arenaProvider, "render",
    session.context.arena, drawActors)
  return ok and surface and presentWorld(session, surface) or false
end

function Host.finish(reason)
  local session = Host.session
  if not session then return end
  invoke(session, session.cardProvider, "finish", reason or "ended")
  invoke(session, session.arenaProvider, "finish", reason or "ended")
  V.log:event("battle", "standalone-voxel-2d-finish", {
    reason = reason or "ended",
  })
  Host.session = nil
end

local function withoutBattleField(battle, fn)
  local g = love.graphics
  local rectangle = g.rectangle
  local fieldSuppressed = false
  g.rectangle = function(mode, x, y, w, h, ...)
    -- Classic battles paint a 160x144 white field; the wide layout paints a
    -- 304x144 palette-paper field. Remove the first opaque field fill in
    -- either layout so Dramaless's 3D world override remains visible. Later
    -- full-screen fills (move flashes) are deliberately preserved.
    local _, _, _, a = g.getColor()
    if not fieldSuppressed and mode == "fill" and x == 0 and y == 0
        and h == GB_H and (w == GB_W or w == 304) and (a or 1) > .99 then
      fieldSuppressed = true
      local target = g.getCanvas()
      if target ~= nil and (target == battle.bgCanvas
          or target == battle.waveCanvas) then
        g.clear(0, 0, 0, 0)
      end
      return
    end
    return rectangle(mode, x, y, w, h, ...)
  end
  local ok, result = pcall(fn)
  g.rectangle = rectangle
  if not ok then error(result, 0) end
  return result
end

function Host.install()
  local BattleState = require("src.battle.BattleState")
  if BattleState.draw == installedDraw
      and BattleState.drawPicsLayer == installedPicsLayer then return false end

  if BattleState.drawPicsLayer ~= installedPicsLayer then
    local innerPicsLayer = BattleState.drawPicsLayer
    installedPicsLayer = function(self, slide, sx, sy, onlySide, skipMenuClip)
      if onlySide == "player" or onlySide == "enemy" then
        if Host.coversSide(self, onlySide) then return end
        return innerPicsLayer(self, slide, sx, sy, onlySide, skipMenuClip)
      end
      local playerCovered = Host.coversSide(self, "player")
      local enemyCovered = Host.coversSide(self, "enemy")
      if playerCovered and enemyCovered then return end
      if playerCovered then onlySide = "enemy"
      elseif enemyCovered then onlySide = "player" end
      return innerPicsLayer(self, slide, sx, sy, onlySide, skipMenuClip)
    end
    BattleState.drawPicsLayer = installedPicsLayer
  end

  if BattleState.draw ~= installedDraw then
    local innerDraw = BattleState.draw
    installedDraw = function(self, ...)
      local args = { ... }
      local world = Host.draw(self)
      if not world then
        self.letterboxWhite = nil
        return innerDraw(self, unpack(args))
      end
      self.letterboxWhite = false
      love.graphics.clear(0, 0, 0, 0)
      return withoutBattleField(self, function()
        return innerDraw(self, unpack(args))
      end)
    end
    BattleState.draw = installedDraw
  end
  BattleState.dramalessVoxel2DBattleHook = true
  return true
end

function Host.invalidate()
  local session = Host.session
  if session then
    invoke(session, session.cardProvider, "invalidate")
    invoke(session, session.arenaProvider, "invalidate")
  end
  Host.finish("invalidate")
end

return Host
