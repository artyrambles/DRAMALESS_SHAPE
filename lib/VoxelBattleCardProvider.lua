-- Native Gen 1 battle pictures presented as camera-facing cards.
--
-- This is the intentionally narrow 2D exception to Dramaless 2.0's
-- environment boundary. It captures only the engine's side-only pics layer
-- and draws it at the selected arena cells. It owns no battle camera, HUD,
-- transition, move animation, portable stage, or lifecycle policy.

local V = ...

local Provider = { id = "DRAMALESS_SHAPE:voxel-cards" }
local GB_W, GB_H = 160, 144
local WORLD_PER_PIC_PIXEL = 16 / 56
local WORLD_CARD_HEIGHT = GB_H * WORLD_PER_PIC_PIXEL
local TEX_AX, TEX_AY = 80, 96

-- Anchors of the engine's native slots. The enemy's 7x7 front/trainer slot
-- is centred at x=124 with its baseline at y=56. The player's scaled back
-- slot is centred at x=64 with its feet at y=96.
local ANCHOR = {
  enemy = { x = 124, y = 56 },
  player = { x = 64, y = 96 },
}

local canvases = {}
local textures = {}
local visible = { player = false, enemy = false }
local drawn = { player = false, enemy = false }
local active = false
local installedPicImage, innerPicImage

local function backPinned()
  local setting = V and V.backSpritesSetting
  if not (setting and type(setting.get) == "function") then return false end
  local ok, value = pcall(setting.get, setting)
  return ok and value and true or false
end

local function voxelArena(context)
  local id = context and context.arena and context.arena.id
  return type(id) == "string" and id:match("^dramaless:voxel%-map:") ~= nil
end

local function syncCamera(context, recenter)
  if not voxelArena(context) then return end
  local ok, camera = pcall(V.require, "BattleCam")
  if not (ok and camera) then return end

  -- Native Gen 1 move animations and Poke Ball throws remain screen-space
  -- effects at the engine's fixed battle anchors. The voxel cards only line
  -- up with those effects when BattleCam uses the canonical solved shot.
  -- Lock out drift/zoom/steering while these 2D cards are active instead of
  -- letting the camera move the cards away from the effects that target them.
  camera.steerable = false
  camera.still = true
  if recenter and type(camera.recentre) == "function" then camera.recentre() end
end

local function canvasFor(side)
  local canvas = canvases[side]
  if canvas then return canvas end
  local ok, made = pcall(love.graphics.newCanvas, GB_W, GB_H, { dpiscale = 1 })
  if not (ok and made) then return nil end
  made:setFilter("nearest", "nearest")
  canvases[side] = made
  return made
end

local function fxHidden(battle, battler)
  if not (battle and battler and type(battle.fxHidden) == "function") then
    return false
  end
  local ok, hidden = pcall(battle.fxHidden, battle, battler)
  return ok and hidden and true or false
end

local function sideVisible(battle, side)
  if not battle then return false end
  if side == "enemy" then
    if battle.showEnemyTrainer and battle.trainerPic then return true end
    return battle.enemy and battle.enemy.sprite
      and not battle.enemyHidden and not battle.enemySendingOut
      and not fxHidden(battle, battle.enemy) and true or false
  end
  if battle.showPlayerBack and battle.playerBackPic then return true end
  return battle.player and battle.player.sprite
    and not battle.safari and not battle.demo and not battle.sendingOut
    and not fxHidden(battle, battle.player) and true or false
end

-- Original Dramaless rendered both world cards at 1:1 into a known texture
-- anchor. The billboard's world transform performed the only scaling. Keep
-- these overrides scoped to the synchronous native-pics callback.
local function withOriginalPlacement(fn)
  local okState, BattleState = pcall(require, "src.battle.BattleState")
  if not (okState and BattleState) then return fn() end
  local scale, back, front = BattleState.resolveBattleScale,
    BattleState.backPlacement, BattleState.frontPlacement
  if type(scale) ~= "function" or type(back) ~= "function"
      or type(front) ~= "function" then return fn() end

  BattleState.resolveBattleScale = function() return 1 end
  BattleState.backPlacement = function(w, h, pad, padL, spriteScale)
    local _, _, state = back(w, h, pad, padL, spriteScale)
    spriteScale = tonumber(spriteScale) or 1
    return TEX_AX - w * spriteScale / 2,
      TEX_AY - (h - (pad or 0)) * spriteScale, state
  end
  BattleState.frontPlacement = function(ex, ey, w, h, spriteScale)
    local _, _, state = front(ex, ey, w, h, spriteScale)
    spriteScale = tonumber(spriteScale) or 1
    return TEX_AX - w * spriteScale / 2,
      TEX_AY - h * spriteScale, state
  end
  local results = { pcall(fn) }
  BattleState.resolveBattleScale, BattleState.backPlacement,
    BattleState.frontPlacement = scale, back, front
  if not results[1] then error(results[2], 0) end
  table.remove(results, 1)
  return unpack(results)
end

local function withNativePics(context, fn)
  local service = context and context.services
    and context.services.withNativeBattlePics
  if type(service) == "function" then return service(fn) end
  local ok, result = pcall(fn)
  return ok, result
end

local function battlerForSide(battle, side)
  if not battle then return nil end
  return side == "player" and battle.player or battle.enemy
end

-- Splash's SE_BOUNCE_UP_AND_DOWN is implemented by the engine as repeated
-- tilemap Y displacement on the user's native battle picture. Baking that
-- displacement into a 160x144 capture makes the card clip/wrap inside its
-- texture before the texture is mounted in 3D. Keep the captured card stable
-- and promote only this displacement to the billboard's world transform.
local function bounceWorldOffset(battle, side)
  local battler = battlerForSide(battle, side)
  local pf = battler and battle.picFx and battle.picFx[battler]
  if not (pf and pf.kind == "bounce") then return 0 end
  local t = tonumber(pf.t) or 0
  -- The native effect slides the 2D tilemap downward and resets it five
  -- times. In world space that would push the billboard through the floor.
  -- Preserve the stepped timing as a small above-ground hop instead:
  --   0, 8, 16, 24, 16, 8, 0 pixels over each 21-frame pass.
  local phase = math.floor((t % 21) / 3)
  local step = phase <= 3 and phase or (6 - phase)
  return step * 8 * WORLD_PER_PIC_PIXEL
end

local function withoutCapturedBounce(battle, side, fn)
  local battler = battlerForSide(battle, side)
  local pf = battler and battle.picFx and battle.picFx[battler]
  if not (pf and pf.kind == "bounce") then return fn() end

  local kind, t = pf.kind, pf.t
  pf.kind = nil
  local results = { pcall(fn) }
  pf.kind, pf.t = kind, t
  if not results[1] then error(results[2], 0) end
  table.remove(results, 1)
  return unpack(results)
end

local function captureSide(context, side)
  local battle = context and context.battle
  if side == "player" and backPinned() then
    visible[side] = false
    textures[side] = nil
    return true
  end
  visible[side] = sideVisible(battle, side)
  if not visible[side] then
    textures[side] = nil
    return true
  end
  if not (battle and type(battle.drawPicsLayer) == "function") then
    textures[side] = nil
    return false
  end
  local canvas = canvasFor(side)
  if not canvas then
    textures[side] = nil
    return false
  end

  local g = love.graphics
  local priorCanvas = g.getCanvas()
  local priorShader = g.getShader and g.getShader() or nil
  local priorBlend, priorAlpha = g.getBlendMode()
  local cr, cg, cb, ca = g.getColor()
  local sx, sy, sw, sh
  if g.getScissor then sx, sy, sw, sh = g.getScissor() end

  local ok, err = withNativePics(context, function()
    g.setCanvas(canvas)
    g.clear(0, 0, 0, 0)
    if g.setShader then g.setShader() end
    g.setBlendMode("alpha")
    g.setColor(1, 1, 1, 1)
    if g.setScissor then g.setScissor() end
    withOriginalPlacement(function()
      withoutCapturedBounce(battle, side, function()
        battle:drawPicsLayer(0, 0, 0, side, true)
      end)
    end)
  end)

  if priorCanvas then g.setCanvas(priorCanvas) else g.setCanvas() end
  if g.setShader then g.setShader(priorShader) end
  g.setBlendMode(priorBlend or "alpha", priorAlpha)
  g.setColor(cr or 1, cg or 1, cb or 1, ca or 1)
  if g.setScissor then
    if sx then g.setScissor(sx, sy, sw, sh) else g.setScissor() end
  end
  if not ok then
    textures[side] = nil
    local log = context and context.services and context.services.log
    if log and log.warn then
      log:warn("[DRAMALESS_SHAPE] native card capture failed: side=%s error=%s",
        tostring(side), tostring(err))
    end
    return false
  end
  local ax, ay, trainer = TEX_AX, TEX_AY, false
  if side == "enemy" and battle.showEnemyTrainer and battle.trainerPic then
    ax, ay, trainer = ANCHOR.enemy.x, ANCHOR.enemy.y, true
  elseif side == "player" and battle.showPlayerBack and battle.playerBackPic then
    trainer = true
  end
  textures[side] = {
    canvas = canvas, ax = ax, ay = ay, trainer = trainer,
    worldYOffset = bounceWorldOffset(battle, side),
  }
  return true
end

local function capture(context)
  captureSide(context, "enemy")
  captureSide(context, "player")
end

local function cellFor(context, side)
  local arena = context and context.arena
  return arena and arena[side] or nil
end

local function drawSide(context, side)
  local card = textures[side]
  local cell = cellFor(context, side)
  local project = context and context.services and context.services.project
  if not (card and card.canvas and cell and type(project) == "function") then
    return false
  end

  local ground = (tonumber(context.groundY) or 0) + (card.worldYOffset or 0)
  local fx, fy = project(cell[1], ground, cell[2])
  local tx, ty = project(cell[1], ground + WORLD_CARD_HEIGHT, cell[2])
  if not (fx and fy and tx and ty) then return false end
  local scale = math.abs(fy - ty) / GB_H
  if not (scale > 0 and scale < 64) then return false end

  love.graphics.draw(card.canvas,
    fx - card.ax * scale,
    fy - card.ay * scale,
    0, scale, scale)
  return true
end

local function drawVoxelSide(context, side)
  local card, cell = textures[side], cellFor(context, side)
  if not (card and card.canvas and cell) then return false end
  local Billboard = V.require("BattleBillboard")
  local Voxel3D = V.require("Voxel3D")
  local mesh = Billboard.mesh()
  if not mesh then return false end
  local model = Billboard.matrix(card.canvas, card.ax, card.ay,
    cell[1], (tonumber(context.groundY) or 0) + (card.worldYOffset or 0), cell[2],
    side == "player" and not card.trainer)
  Voxel3D.seams(false)
  Voxel3D.glass(false)
  Voxel3D.draw(mesh, card.canvas, model, Billboard.PULL)
  Voxel3D.glass(true)
  Voxel3D.seams(true)
  return true
end

function Provider:available(context)
  local battle = context and context.battle
  return love and love.graphics and battle
    and type(battle.drawPicsLayer) == "function" and true or false
end

function Provider:install()
  local ok, BattleState = pcall(require, "src.battle.BattleState")
  if not (ok and BattleState and type(BattleState.picImage) == "function") then
    return true
  end
  if BattleState.picImage == installedPicImage then return true end
  innerPicImage = BattleState.picImage
  installedPicImage = function(battle, image)
    local out = innerPicImage(battle, image)
    if not active then return out end
    local player = battle and battle.player
    local pinned = backPinned() and battle and
      (image == battle.playerBackPic or (player and image == player.sprite))
    return V.require("BattlePics").filled(out, pinned)
  end
  BattleState.picImage = installedPicImage
  return true
end

function Provider:begin(context, arena)
  self:install(context)
  active = true
  context.arena = arena or context.arena
  textures.player, textures.enemy = nil, nil
  visible.player, visible.enemy = false, false
  drawn.player, drawn.enemy = false, false
  capture(context)
  syncCamera(context, true)
  return true
end

function Provider:update(context)
  syncCamera(context, false)
  capture(context)
end

function Provider:drawWorld(context)
  drawn.player, drawn.enemy = false, false
  if not (context and context.services) then return false end
  if voxelArena(context) then
    drawn.enemy = drawVoxelSide(context, "enemy")
    drawn.player = drawVoxelSide(context, "player")
    return drawn.player or drawn.enemy
  end
  if type(context.services.project) ~= "function" then return false end
  local g = love.graphics
  if g.push then g.push("all") end
  if g.setShader then g.setShader() end
  if g.setDepthMode then g.setDepthMode("always", false) end
  g.setBlendMode("alpha", "premultiplied")
  g.setColor(1, 1, 1, 1)
  drawn.enemy = drawSide(context, "enemy")
  drawn.player = drawSide(context, "player")
  if g.pop then g.pop() end
  return drawn.player or drawn.enemy
end

function Provider:covers(context, side)
  return (side == "player" or side == "enemy") and drawn[side] == true
end

function Provider:showing(context, side)
  return (side == "player" or side == "enemy") and visible[side] == true
end

function Provider:center(context, side)
  local cell = cellFor(context, side)
  if not cell then return nil end
  return { cell[1], (tonumber(context.groundY) or 0) + WORLD_CARD_HEIGHT * .45,
           cell[2] }
end

function Provider:footprint(context, side)
  local cell = cellFor(context, side)
  if not cell then return nil end
  return { x = cell[1], y = tonumber(context.groundY) or 0, z = cell[2],
           radius = 8, height = WORLD_CARD_HEIGHT }
end

function Provider:cameraLocked(context)
  -- StadiumBattleFX owns the host camera when it is installed.  Our local
  -- BattleCam lock above cannot affect that camera, so explicitly ask the
  -- host to keep Dramaless' authored base shot while native 2D cards are
  -- staged on the voxel arena.  That base shot is solved against the same
  -- fixed Gen 1 move/Poke Ball anchors as the captured cards.
  return backPinned() or (active and voxelArena(context))
end

function Provider:finish()
  active = false
  textures.player, textures.enemy = nil, nil
  visible.player, visible.enemy = false, false
  drawn.player, drawn.enemy = false, false
  local ok, camera = pcall(V.require, "BattleCam")
  if ok and camera then
    camera.steerable = true
    camera.still = false
  end
end

function Provider:invalidate()
  self:finish()
  canvases = {}
  local ok, billboard = pcall(V.require, "BattleBillboard")
  if ok and billboard and billboard.invalidate then billboard.invalidate() end
  local picsOk, pics = pcall(V.require, "BattlePics")
  if picsOk and pics and pics.invalidate then pics.invalidate() end
end

return Provider
