-- Overworld battles: fights that happen on the map you were standing on.
--
-- The engine's battle is a screen: a white field with two pics on it, pushed
-- over a frozen overworld that stops drawing. This turns that white field
-- into the world -- the same terrain the free-roam mode extrudes, shot from
-- a placed over-the-shoulder camera at a clear patch of ground nearby --
-- while leaving the battle ITSELF alone. Every pic, HUD, HP bar, move
-- animation, faint slide and text box is the engine's own, drawn in the
-- engine's own order. What changes is what is behind them, and where the two
-- pics stand.
--
-- The sequence, from the moment something picks a fight:
--
--   1. the overworld cast is culled -- every NPC vanishes, so the wipe
--      plays over an empty map and no bystander is left standing in the
--      arena shot
--   2. the engine's own transition wipes the screen (untouched: it is the
--      right wipe, picked by the right three bits)
--   3. the battle draws over a live, window-resolution render of the arena,
--      with each mon PINNED to the cell it is standing on, the camera
--      drifting slowly enough to read as parallax, and a depth-of-field pass
--      holding the slab of world the two of them occupy sharp
--   4. the battle ends, the cast comes back, and the player is exactly
--      where they were standing
--
-- WHAT DOES NOT MOVE. The arena is where the CAMERA goes, not where the
-- player goes: nothing here writes a cell, a facing, a flag or a warp. A
-- real warp would have to survive trainer sight-lines, post-battle
-- dialogue, the blackout path and every script that assumes the player is
-- where it left them -- and it would have to put them back afterwards.
-- Moving the camera buys the whole shot and owes nothing back.
--
-- The feature declines cleanly rather than half-working: no depth support,
-- no open ground on the map, the row switched off, or a mesh still building
-- all end at the same place, which is the battle screen the engine has
-- always drawn.

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local ModSetting = V.require("ModSetting")
local BattleArena = V.require("BattleArena")
local BattleCam = V.require("BattleCam")
local BattleScene = V.require("BattleScene")
local BattleDOF = V.require("BattleDOF")
local BattleHud = V.require("BattleHud")
local BattlePresentation = V.require("BattlePresentation")
local UiBackplates = V.require("UiBackplates")
local TextboxStyle = V.require("TextboxStyle")
local BattlePics = V.require("BattlePics")
local BattleArt = V.require("BattleArt")
local AnimatedBattleArt = V.require("AnimatedBattleArt")
local Voxel3D = V.require("Voxel3D")
local ChunkMesher = V.require("ChunkMesher")

local OverworldBattle = {}
local session = nil

-- iOS cannot run the HUD-snap (snapHUDs) path: it renders the HUDs
-- upside-down and opaque, so on that platform we skip it and fall back to
-- the engine's own (opaque) HUD/textbox draw. Mirrors upstream PR #48.
local function isIOS()
  return love.system and love.system.getOS and love.system.getOS() == "iOS"
end

-- DS_BATTLE_DEBUG=1 logs what the HUD's brightness probe is reading, once a
-- second, which is how the glyph flip is checked from a shot run. Read
-- through pcall: the loader's sandbox does not hand a mod `os`, and a
-- diagnostic must never be the reason the mod fails to load.
local DEBUG = select(2, pcall(function() return os.getenv("DS_BATTLE_DEBUG") end))
if DEBUG == nil or DEBUG == false then DEBUG = nil end

OverworldBattle.KEY = "battles"
OverworldBattle.LABEL = "3D-BTL"

-- Five rungs. Two independent choices, laid out as one ladder because they
-- are one question to the player -- WHAT is standing there, and WHERE:
--
--              on the MAP              on two DISCS
--   pics       2D-3D A                 2D-3D B
--   models     STADIUM A               STADIUM B
--
--   2D-3D A    the mode this file was written for: the fight is staged on
--              the map and the two Pokemon are the GB's OWN PICS, stood up
--              on their tiles as quads (BattleBillboard).
--   2D-3D B    those same pics on a pair of DISCS against the sky, with no
--              map at all (see lib/StadiumStage.lua). The Game Boy's own
--              framing with the Game Boy's own art, in three dimensions --
--              and, like every B rung, it works everywhere, including the
--              caves and shop floors that have nowhere to stage a fight.
--   STADIUM A  the staged fight with the Pokemon Stadium battle models in
--              place of those quads -- skinned, animated, and playing the
--              animation the move being used actually calls for (see
--              lib/Stadium.lua). The world is still the world: the fight
--              happens on real ground, in the map's own weather and light.
--   STADIUM B  the models on the discs: both halves swapped at once.
--   OFF        the engine's own white battle screen.
--
-- A and B is the STAGE and it is the same stage either way -- the discs do
-- not know what is standing on them and BattleScene draws them off
-- `arena.discs` alone, which is why the second column cost a value in this
-- table and nothing else. The four combinations are all reachable rather
-- than only the diagonal, because a player who cannot use the STADIUM rungs
-- -- no ROM, or a ROM they would rather not go and find -- should still be
-- able to have the disc framing, and because the discs are the answer to
-- "this map has nowhere to fight" whichever art is standing on them.
--
-- 2D-3D A stays FIRST because ModSetting's values[1] is both the default and
-- what an unrecognised stored value falls back to, and the stored value for
-- this row has been `true` since the row existed. Keeping `true` at the head
-- means every save written before the later rungs existed reads back as the
-- 2D-3D it was written for, and a mod whose headline is "the world in 3D"
-- still does not need the player to go and find the switch.
--
-- Every other stored value is likewise the one it has always been --
-- "stadium" from before there was a B, "stadiumB" from before there was a
-- flat one -- so no save loses the mode it chose.
--
-- Both STADIUM rungs are GATED on the models existing: the mod ships no
-- Pokemon Stadium data, and until the player's own ROM has been found and
-- built from (StadiumInstall) the row simply has two fewer stops. See
-- ModSetting.setGate for why they are skipped rather than shown and refused.
-- 2D-3D B is NOT gated: its stage is generated in Lua and its Pokemon are
-- the game's own art, so it needs nothing the base game did not ship.
OverworldBattle.FLAT_B = "flatB"

OverworldBattle.setting =
  ModSetting.new(OverworldBattle.KEY, OverworldBattle.LABEL,
                 { true, "flatB", "stadium", "stadiumB", false },
                 { "2D-3D A", "2D-3D B", "STADIUM A", "STADIUM B", "OFF" })
  :setGate(function(value)
    if value ~= "stadium" and value ~= "stadiumB" then return true end
    local ok, install = pcall(V.require, "StadiumInstall")
    return ok and install and install.available()
  end)

-- Whether the fight stands on the two carried DISCS rather than on the map
-- -- the B column above, whichever row of it. Asked by stageFor (what to
-- stage on), wantsFront (whether this map needs an arena at all) and, once
-- the arena carries the answer as `arena.discs`, by BattleScene and
-- VoxelScene for what to draw.
--
-- Read straight off the row rather than through Stadium, because it is a
-- question about the STAGE and half the rungs that answer yes have no
-- Stadium models on them at all.
function OverworldBattle.discs()
  local value = OverworldBattle.setting:get()
  return (value == OverworldBattle.FLAT_B or value == "stadiumB")
end

-- Whether the VR row is ON -- read lazily, because VR requires modules
-- that sit above this one. While it is, this mode stops being optional:
-- the headset's battle seat, the pokedex screen and the effects plane
-- all assume a fight standing on the world, and a white-field battle
-- inside a headset is exactly the flat screen VR exists to replace.
local function vrOn()
  local ok, vr = pcall(V.require, "VR")
  return ok and vr and vr.enabled and vr.enabled() or false
end

-- HUD SCALE: SCALED draws the player/opponent HUD at the battle's zoom factor
-- (hs = zoom - 1), the look this mod ships with. OG pins the HUD to the
-- window-fit scale (hs = fitScale), like upstream gen1recomp's player HUD --
-- the HUD grows and shrinks with the window, which is the scale external
-- EXP-bar mods assume (they adapted to the window-scaling default). The
-- backplates are untouched: only the HUD's on-screen size follows the window.
OverworldBattle.hudScaleSetting = ModSetting.new("hudScale", "HUD SCALE",
                                                  { "scaled", "og" },
                                                  { "SCALED", "OG" }, 1)

function OverworldBattle.enabled()
  if vrOn() then return true end
  return OverworldBattle.setting:get() and true or false
end

-- Whether the STADIUM rung is the one selected -- read through Stadium so
-- there is one answer to that question and it lives with the mode it
-- describes. Required lazily: Stadium sits above this file and requires it
-- back (for the row), which a load-time require would deadlock.
function OverworldBattle.stadium()
  local ok, stadium = pcall(V.require, "Stadium")
  return (ok and stadium and stadium.enabled()) and true or false
end

-- this was duplicated and appears again further down.
-- -- Public compatibility seam used by Crystal Animated Sprites v1.4+: it asks
-- -- whether its BattleState is the one currently being captured into voxel
-- -- billboards before choosing its staged palette/transparency path.
-- function OverworldBattle.battle()
--   return session and session.battle or nil
-- end

-- ------- battle-art view
--
-- The staged shot stands BOTH mons on the map, which is the mode's whole
-- claim -- but it costs the one piece of framing Gen 1 is most recognisable
-- by: your own Pokemon, seen from behind, sitting on top of the battle menu
-- with its feet on the box. That silhouette is the series' shot.
--
-- Placement is deliberately independent from the selected art set. WORLD and
-- OG UI are useful authoring overrides; AUTO follows the intended presentation:
-- STATIC puts supplied art and ROM fallback in the world, ANIMATED puts a
-- supplied PNG/atlas in the world but leaves a missing ROM fallback on the
-- original UI anchor, and ROM uses that OG anchor outright.
function OverworldBattle.backPinned()
  if not OverworldBattle.enabled() then return false end
  if vrOn() then return false end
  local battle = session and session.battle
  local trainerBack = battle and battle.showPlayerBack
                      and battle.playerBackPic
  -- PLAYER controls Pokemon views, not the trainer intro. A trainer back can
  -- still use OG UI while FRONT SPRITES keeps the later Pokemon card in-world.
  if not trainerBack and BattleArt.playerSide() ~= "back" then return false end
  local placement = BattleArt.backPlacementSetting:get()
  if placement == "world" then return false end
  if placement == "ui" then return true end

  local artMode = BattleArt.setting:get()
  if artMode == "static" then return false end
  if artMode == "rom" then return true end

  if not battle then return false end
  -- Trainer backs never use the Pokemon atlas manager. A supplied player,
  -- Oak or Old Man PNG is marked external by BattleArt; a ROM trainer pic is
  -- not. Animated player-trainer art deliberately stays on OG UI in AUTO:
  -- its one-shot frames are synchronised to that layer's leftward slide.
  if trainerBack then
    return true
  end
  return battle.player and not AnimatedBattleArt.hasWorldBack(battle.player)
         or false
end

-- A supplied species back is already a full-display PNG (56px and up), not
-- the ROM's half-resolution 32px picture. OG UI draws it at native 1x and
-- moves the COMPLETE engine draw so its alpha silhouette, rather than its
-- transparent canvas, owns the classic player anchor. Keeping this as an
-- outer translation preserves send-out growth, damage bounce and shake.
local function pinnedSpeciesMetric()
  local battle = session and session.battle
  if not (battle and battle.player and battle.player.sprite)
     or battle.showPlayerBack or not OverworldBattle.backPinned() then
    return nil
  end
  local image = battle.player.sprite
  if not BattleArt.isExternal(image) then return nil end
  return BattleArt.metrics(image)
end

function OverworldBattle.backPinOffset(metric, grow)
  if not metric then return 0, 0 end
  local scale = tonumber(grow) or 1
  local left = 8 + metric.w * (1 - scale) / 2
  local center = left + metric.center * scale
  local dx = OverworldBattle.ANCHOR.player[1] - center
  -- Wide supplied backs can extend farther left of the classic 32px slot
  -- than its centre anchor has room for. Keep that centre when it fits, but
  -- never let the opaque silhouette cross the UI canvas edge.
  local opaqueLeft = left + (metric.x0 or 0) * scale
  dx = math.max(dx, 1 - opaqueLeft)
  return dx,
         (metric.padBottom or 0) * scale
end

-- Whether a pic is the one drawn in the GB's own slot with its feet on the
-- text box, rather than geometry standing out on the map.
--
-- Exactly the player's side under BACK SPRITES -- its mon, or the trainer back
-- that holds the slot until "Go!" -- because that is the only pic this mod
-- ever leaves flat (see drawPicsLayer below). The foe is a billboard on its
-- tile whichever mode is on, and with the mode off the player's side is one
-- too, so both of those keep the open bottom that lets the arena through a
-- stride. What the answer buys is in BattlePics: a pic on the box has nothing
-- behind its lowest row, so its bottom edge seals.
-- Read by TRUTHINESS rather than against nil, because sideTexture blanks the
-- side it is not rendering by setting the field to FALSE (see OFF) and holds
-- it that way for the whole render -- during which the pic layer runs, and
-- picImage asks this. A nil test passes a `false` straight through to the
-- index below, and the error comes out of sideTexture into the pcall that
-- calls it: the foe's billboard is dropped for the frame and the Pokemon
-- simply is not there.
function OverworldBattle.pinnedPic(battle, img)
  if not (battle and img) then return false end
  if not OverworldBattle.backPinned() then return false end
  if img == battle.playerBackPic then return true end
  local player = battle.player
  return (player and img == player.sprite) and true or false
end

-- Whether this image is one of the two live Pokemon pictures rather than a
-- trainer intro. Kept as an identity test so ROM paths, palettes and species
-- names never have to be guessed.
function OverworldBattle.isPokemonPic(battle, img)
  if not (battle and img) then return false end
  return ((battle.enemy and img == battle.enemy.sprite)
          or (battle.player and img == battle.player.sprite)) and true or false
end

-- ------- both mons face you
--
-- Standing on a map, seen from in front, a Pokemon showing you its BACK is
-- wrong twice over: it is turned away from the camera that is looking at it,
-- and the back pics are a different, smaller drawing made for a slot the
-- player never really sees. So the player's side asks for the FRONT pic too,
-- through the engine's own pokemon.sprite hook -- the seam that exists for
-- exactly this, so no battle code has to be touched to get it.
--
-- PLAYER chooses whether the near card asks for front or back sprites.
--
-- Answered BEFORE a battle exists, because the battler is built before the
-- battle is pushed. So it cannot ask whether this fight is staged; it asks
-- whether one on this map WOULD be -- the row is on, the 3D pass is
-- available, and the map has an arena -- which is the same question with the
-- same answer a moment later. Cached per map, because the arena search walks
-- the whole grid and this runs once per battler.
local staged = { mapId = nil, ok = false }

function OverworldBattle.wantsFront()
  if not OverworldBattle.enabled() then return false end
  if BattleArt.playerSide() ~= "front" then return false end
  if not Voxel3D.available() then return false end
  -- required here rather than through the file's own helper: this runs
  -- while a battler is being built, which is before that helper is defined
  local g = require("src.core.Game")
  local ow = g and g.overworld
  if not (ow and ow.map and ow.player) then return false end
  -- a B rung carries its own stage, so the answer is yes on every map and
  -- there is nothing to search or to cache
  if OverworldBattle.discs() then return true end
  if staged.mapId ~= ow.map.id then
    local ok, arena = pcall(BattleArena.find, ow.map,
                            ow.player.cellX, ow.player.cellY,
                            ow.player.surfing)
    staged = { mapId = ow.map.id, ok = (ok and arena) and true or false }
  end
  return staged.ok
end

-- ------- where the engine's own pics stand
--
-- The GB draws the player's back pic with its feet on the text box at row 96
-- and its 7x7-tile slot centred on x=40, and the enemy's front pic
-- bottom-aligned in a 7x7 slot centred on x=124 ending at row 56. Those two
-- points are the pics' FEET, they hold for every species at every scale (the
-- engine's placement helpers pin the bottom edge and the centre), and they
-- are what BattleCam is solved to put the two arena cells under.
--
-- Which makes the pin a subtraction: whatever the drift has done to the
-- camera this frame, each pic moves by its own cell's projected position
-- minus its anchor. At the middle of the drift that is zero.
OverworldBattle.ANCHOR = {
  player = { 26, 96 },
  enemy = { 124, 56 },
}

-- How far apart the two anchors are: the spacing every move animation was
-- authored against, and so the yardstick the live pair is measured with.
OverworldBattle.ANCHOR_SPAN = math.sqrt(
  (OverworldBattle.ANCHOR.enemy[1] - OverworldBattle.ANCHOR.player[1]) ^ 2
  + (OverworldBattle.ANCHOR.enemy[2] - OverworldBattle.ANCHOR.player[2]) ^ 2)

-- The effects layer's scale for this shot: how far apart the two mons
-- actually are on screen, over how far apart the slots they were authored
-- for were. Clamped hard at both ends -- an effect is pixel art and a wild
-- factor is worse than a slightly wrong one -- and held at exactly 1 when
-- the marks coincide, which is a projection about to degenerate rather
-- than a pair that has genuinely closed up.
OverworldBattle.ANIM_SCALE_MIN = 0.5
OverworldBattle.ANIM_SCALE_MAX = 2.0

function OverworldBattle.animScale(shot, px, py)
  if not (shot and shot.enemy and px and py) then return 1 end
  local dx, dy = shot.enemy[1] - px, shot.enemy[2] - py
  local span = math.sqrt(dx * dx + dy * dy)
  if not (span > 1) then return 1 end
  local k = span / OverworldBattle.ANCHOR_SPAN
  return math.max(OverworldBattle.ANIM_SCALE_MIN,
                  math.min(OverworldBattle.ANIM_SCALE_MAX, k))
end

-- ------- how big a mon is
--
-- Not a decision made here. A pic is drawn at its own integer scale -- 1x for
-- a 56px front pic, 2x for a 32px back one -- because that is the only way it
-- keeps every pixel the artist drew, and the CAMERA is solved so that one
-- overworld square is that big on screen (see BattleCam). The mon fits its
-- tile because the tile was sized to the mon, not the other way round.
OverworldBattle.SLOT_W = { front = 56, back = 32 }

-- The two HUD blocks, as the pixel spans DrawEnemyHUDAndHPBar and
-- DrawPlayerHUDAndHPBar actually reach. Neither overlaps its side's pic at
-- the anchors above.
OverworldBattle.HUD_RECT = {
  enemy = { 8, 0, 80, 32 },
  player = { 72, 56, 88, 40 },
}

-- ------- the box at the bottom, on the same glass
--
-- The HUDs got frosted panels because black glyphs on grass are not readable.
-- The battle's text box and its menu had the opposite problem and the same
-- cause: they are drawn as an OPAQUE WHITE slab with a black border, which was
-- the field's own colour when the field was white and is a sheet of paper laid
-- over the bottom third of the diorama now that it is not.
--
-- So the box gets exactly what the HUDs get: the world behind it, blurred to
-- frosted glass and laid back down translucent, with the border and the text
-- drawn over it unchanged, and the same brightness verdict flipping the ink
-- when the ground under it is dark. Only the FILL is taken away -- every glyph
-- the engine draws inside the box is still the engine's own, in its own place.
--
-- These are the boxes BattleState:drawTextArea lays down, as GB-frame rects.
-- READ-ONLY duplicates of that function's own branches, the same kind of
-- mirror hudLive is and for the same reason: there is no seam that reports "a
-- move menu is up", and glass has to go down BEFORE the box that sits on it.
-- The worst a future engine change can do is frost a rectangle nothing lands
-- on, or leave a box unfrosted -- never break a battle.
--
-- Each rect stops where the next one starts rather than overlapping it: two
-- panels over the same pixels would frost it twice and leave a visible step
-- along the seam.
OverworldBattle.TEXT_RECT = {
  box = { 0, 96, 160, 48 },       -- Font.drawBox(0, 12, 20, 6), always
  -- moveSelect's TYPE/PP box, Font.drawBox(0, 8, 11, 5), trimmed to the rows
  -- above the box above -- its last tile row sits inside that one
  moves = { 0, 64, 88, 32 },
  -- mimicSelect's copy menu, Font.drawBox(0, 7, 16, 6), trimmed the same way
  mimic = { 0, 56, 128, 40 },
}

-- How far apart the two anchors are: the spacing every move animation was
-- authored against, and so the yardstick the live pair is measured with.
OverworldBattle.ANCHOR_SPAN = math.sqrt(
  (OverworldBattle.ANCHOR.enemy[1] - OverworldBattle.ANCHOR.player[1]) ^ 2
  + (OverworldBattle.ANCHOR.enemy[2] - OverworldBattle.ANCHOR.player[2]) ^ 2)

-- The effects layer's scale for this shot: how far apart the two mons
-- actually are on screen, over how far apart the slots they were authored
-- for were. Clamped hard at both ends -- an effect is pixel art and a wild
-- factor is worse than a slightly wrong one -- and held at exactly 1 when
-- the marks coincide, which is a projection about to degenerate rather
-- than a pair that has genuinely closed up.
OverworldBattle.ANIM_SCALE_MIN = 0.5
OverworldBattle.ANIM_SCALE_MAX = 2.0

function OverworldBattle.animScale(shot, px, py)
  if not (shot and shot.enemy and px and py) then return 1 end
  local dx, dy = shot.enemy[1] - px, shot.enemy[2] - py
  local span = math.sqrt(dx * dx + dy * dy)
  if not (span > 1) then return 1 end
  local k = span / OverworldBattle.ANCHOR_SPAN
  return math.max(OverworldBattle.ANIM_SCALE_MIN,
                  math.min(OverworldBattle.ANIM_SCALE_MAX, k))
end

function OverworldBattle.textRects(battle)
  if not battle or battle.blankForAskName then return {} end
  local r = OverworldBattle.TEXT_RECT
  local out = { box = r.box }
  if battle.phase == "moveSelect" then
    out.moves = r.moves
  elseif battle.phase == "mimicSelect" then
    out.mimic = r.mimic
  end
  return out
end

-- Paper rectangles for the selected textbox mode. HALF deliberately leaves
-- the whole TYPE/PP box paperless. Its bottom tile row overlaps the ordinary
-- text box, so merely omitting `moves` would still leave HALF paper showing
-- through there; split the main box around that 88x8 overlap as well. BLACK
-- and WHITE retain the normal union, while OFF has no paper anywhere.
function OverworldBattle.textPaperRects(battle, mode)
  if mode == "OFF" then return {} end
  if mode == "HALF" and battle and battle.phase == "moveSelect" then
    return {
      boxRightTop = { 88, 96, 72, 8 },
      boxBottom = { 0, 104, 160, 40 },
    }
  end
  return OverworldBattle.textRects(battle)
end

-- ------- the HUDs, out at the window's own edges
--
-- The battle screen is 160x144 in the MIDDLE of the window and the world is the
-- whole of it. That left both HUD blocks huddled together in the middle of the
-- frame with map showing on either side of them, which reads as a Game Boy
-- screenshot pasted over a diorama rather than as the diorama's own furniture.
--
-- So each block is snapped to its own side: the foe's to the left edge of the
-- window, the player's to the right. The near/player block is one INTEGER
-- display rung smaller than the battle letterbox. At the common 2x layout it
-- is therefore native 1x: every source pixel stays a sharp screen pixel while
-- the block no longer reaches halfway across the arena and covers the foe.
-- The enemy block uses that same compact rung, so neither side dominates the
-- screen merely because its HUD was left at the letterbox scale.
--
-- They cannot simply be MOVED there: the engine draws them into the 160x144 UI
-- canvas and everything outside it is clipped away. So the layer is rendered to
-- a texture and composited into the WORLD image instead, which is the one
-- surface in this mode that covers the whole window.

-- The rows each block is cut out of, full width. Generous on purpose:
-- AnimationShakeEnemyHUD nudges the foe's block sideways, a long name reaches
-- further than the panel does, and the pokeball rows and the safari ball count
-- belong to the block whose rows they sit in. Nothing drawHUDs draws lies
-- outside rows 0-96, and the two bands split that between them.
OverworldBattle.HUD_BAND = {
  enemy = { 0, 0, 160, 48 },
  player = { 0, 48, 160, 48 },
}

-- Where each block lands, in WORLD-canvas pixels: the panel rect the frosted
-- glass is cut to, plus the x its band is blitted at.
--
-- The foe's panel starts near the window's left edge and the player panel keeps
-- two logical pixels clear of the right one. The vertical is untouched, so both
-- stay on the rows the GB put them on. A band's own origin sits outside the
-- window by the panel's inset --
-- the couple of pixels a HUD shake can push past the edge are clipped there,
-- which is the whole cost of the snap and is invisible.
function OverworldBattle.snapRects(shot)
  local s = shot.scale
  local hs = math.max(1, s - 1)
  -- HUD SCALE: OG pins the HUD to the window-fit scale (hs = fitScale), like
  -- upstream gen1recomp's player HUD, so an external XP-bar mod (which assumes
  -- a window-scaling HUD) lines up; SCALED is the mod's default (hs follows
  -- the battle zoom).
  if OverworldBattle.hudScaleSetting:get() == "og" then hs = s end
  local e, p = OverworldBattle.HUD_RECT.enemy, OverworldBattle.HUD_RECT.player
  -- Leave two logical pixels between the foe's name and the window edge.
  -- The whole enemy band moves with the panel, so long names and HUD shakes
  -- keep their original internal alignment instead of being clipped.
  local ex = (2 - e[1]) * hs
  -- Keep two logical pixels of breathing room at the right window edge.
  -- NOTE: this +2 previously shifted the whole player HUD left by 2*hs, which
  -- desynced it from the engine's player status box (and any external EXP-bar
  -- mod that anchors to that box). Removed so our player HUD shares the
  -- engine's status-box origin -- the external bar then lines up with it.
  local px = shot.pw - (p[1] + p[3]) * hs
  local rects = {
    enemy = { ex + e[1] * hs, shot.ly + e[2] * s, e[3] * hs, e[4] * hs },
    player = { px + p[1] * hs, shot.ly + p[2] * s,
               p[3] * hs, p[4] * hs },
  }
  local playerBand = OverworldBattle.HUD_BAND.player
  return rects, {
    enemy = { x = ex, y = shot.ly, scale = hs },
    -- Preserve the HUD's original top row while shrinking its internal
    -- distance from the band boundary. This leaves clear world between its
    -- lower bracket and the live textbox rather than placing it underneath.
    player = {
      x = px,
      y = shot.ly + p[2] * s - (p[2] - playerBand[2]) * hs,
      scale = hs,
    },
  }
end

-- A rect measured in the GB frame, in WORLD-canvas pixels: where the letterbox
-- blit will actually put it. The text box has not moved anywhere -- it is drawn
-- where it always was -- but its glass is laid into the world image alongside
-- the HUDs' (see snapHUDs), which is the surface that reaches the screen a
-- pixel to a pixel rather than magnified out of a 160x144 canvas.
local function toWorld(rect, shot)
  local s = shot.scale
  return { shot.lx + rect[1] * s, shot.ly + rect[2] * s,
           rect[3] * s, rect[4] * s }
end

-- ------- the live battle
--
-- nil when no overworld battle is running. Never more than one: battles do
-- not nest.
session = nil

local function game()
  return require("src.core.Game")
end

-- Whether this frame's HUDs went out to the window's edges instead of being
-- drawn in the GB frame. False whenever the composite could not be made, which
-- is what leaves the in-frame HUD as the fallback rather than no HUD at all.
local function snapped()
  return (session and session.snapped) and true or false
end

-- Put the map's cast back. Both lists are handed back by identity, so
-- anything that captured one before the battle still sees the same table.
local function restoreCast()
  if not (session and session.state) then return end
  if session.entities then session.state.entities = session.entities end
  if session.ghosts then session.state.ghosts = session.ghosts end
  session.entities, session.ghosts = nil, nil
end

-- Cull them. The player stays -- they are not an NPC, they are who the
-- battle belongs to, and Fly/surf animations and the save's own capture read
-- state.player through this list.
--
-- Only the DRAW lists are touched, and only while the overworld is frozen
-- underneath a battle: StateStack updates the top state alone, so nothing
-- walks, wanders, triggers or collides against a list that is short for
-- these frames. The originals go back at battle.ended.
local function cullCast(state)
  session.entities = state.entities
  session.ghosts = state.ghosts
  state.entities = { state.player }
  state.ghosts = {}
end

-- ------- one right battle layout
--
-- Everything this file composes is measured in the GB's own 160x144 frame: the
-- two ANCHORs the arena camera is solved to put a cell under, the HUD_RECTs
-- the frosted panels are cut to, and the full-frame white intercepted to let
-- the world through. BATTLE LAYOUT's WIDE lays the same battle out on a
-- 304x144 surface (src/battle/WideBattle.lua), which moves every one of those
-- -- the mons would stand where no camera was solved for them, and the panels
-- would land beside the HUDs they are supposed to be under.
--
-- So while a fight can be staged on the map there is one right answer, and it
-- is SET rather than worked around. The engine reads the option live
-- (BattleState:isWideBattleLayout is asked per frame, and Renderer asks the
-- top state for its surface the same way), so writing it here lands on the
-- battle being pushed as well as every one after it.
--
-- This is the last line rather than the first: the OPTIONS menu takes the row
-- off the list and pins the value while 3D-BTL is on (see main.lua), so a
-- player is never offered a switch that gets reverted under them. What reaches
-- here is a value that arrived some other way -- a save written before the mod
-- was installed, the mod manager's own page, another mod.
function OverworldBattle.forceOG(g)
  g = g or game()
  local opts = g and g.save and g.save.options
  if not opts or opts.battleLayout ~= "wide" then return false end
  opts.battleLayout = "og"
  if g.writeOptions then pcall(g.writeOptions, g) end
  return true
end

-- Where THIS fight stands, on whichever rung is running: the map's own
-- ground, or the pair of discs a B rung carries with it.
--
-- The one place the two columns actually diverge, and it is worth stating
-- plainly. On an A rung the answer can be NO -- a corridor, a shop floor, a
-- map whose authored entry is a refusal -- and the battle then plays exactly
-- as the vanilla game does. A B rung cannot fail: its stage is not something
-- the map has to have room for, so a fight in the tightest cave in Kanto is
-- staged as readily as one on Route 1.
function OverworldBattle.stageFor(state)
  if OverworldBattle.discs() and Voxel3D.available() then
    local okStage, arena = pcall(function()
      return V.require("StadiumStage").arena(state.map)
    end)
    if okStage and arena then return arena end
    -- the discs could not be built; fall through to the map, which is a
    -- worse picture but a real one
  end
  local okFind, arena = pcall(BattleArena.find, state.map,
                              state.player.cellX, state.player.cellY,
                              state.player.surfing)
  return (okFind and arena) or nil
end

-- Stage a battle triggered from `state`, if this mode can. Returns true when
-- a session started -- which is also the only case where anything visible
-- changes, so a map with no room for an arena plays exactly the vanilla
-- battle it always did, cast and all.
function OverworldBattle.begin(state, battle)
  OverworldBattle.finish()
  if not OverworldBattle.enabled() then return false end
  if not (state and state.map and state.player) then return false end
  if not Voxel3D.available() then return false end

  local ok, arena = pcall(BattleArena.find, state.map,
                          state.player.cellX, state.player.cellY,
                          state.player.surfing)
  if not (ok and arena) then return false end

  -- the fight is staged from here on, so the layout it is composed for is not
  -- optional any more (see forceOG)
  OverworldBattle.forceOG()

  session = { state = state, arena = arena, battle = battle, shot = nil,
              armed = false, token = 0 }
  cullCast(state)
  BattleCam.reset()
  -- and, on the STADIUM rung, the pair of models that will stand on this
  -- arena's two cells. Declines quietly on any other rung.
  pcall(function() V.require("Stadium").begin(arena) end)
  return true
end

-- The fallback entry point: a battle that arrived without going through the
-- overworld's own pushBattle (a link battle, a script pushing a BattleState
-- directly). Nothing visible depends on the cull for those -- the wipe has
-- already been and gone -- but the arena still has to be picked.
function OverworldBattle.ensure(battle)
  if session then
    -- a battle pushed through the overworld reaches begin() before it is
    -- built far enough to draw; battle.started is where it is finished
    if battle and not session.battle then session.battle = battle end
    return
  end
  local g = game()
  local ow = g and g.overworld
  if ow and ow.map then OverworldBattle.begin(ow, battle) end
end

-- The arena this battle is staged on, or nil. Read by the shot driver so a
-- screenshot can be labelled with the ground it was taken on.
function OverworldBattle.arena()
  return session and session.arena or nil
end

function OverworldBattle.finish()
  if not session then return end
  AnimatedBattleArt.finish(session.battle)
  restoreCast()
  session = nil
  Voxel3D.camera = nil
  pcall(function() V.require("Stadium").finish() end)
end

-- ------- per-frame
--
-- Driven from the voxel pipeline's update hook, which the engine ticks every
-- frame regardless of which state is on top -- including the frames the
-- transition wipe covers, which is what gets the arena's meshes built before
-- the first battle frame needs them.
--
-- The scene is rendered HERE rather than inside the battle's draw, because
-- update runs with no canvas bound: a 3D pass that binds a depth target and
-- unbinds to the screen when it is done cannot do that in the middle of
-- someone else's frame without putting the frame back itself.
function OverworldBattle.update(dt)
  if not session then return end

  local g = game()
  local top = g and g.stack and g.stack:top()
  local ow = g and g.overworld
  -- A battle that ended without saying so (a script tearing the state down,
  -- a path that never emits battle.ended) would otherwise leave the cast
  -- culled for good. Armed only once something has actually covered the
  -- overworld, because begin() runs while the overworld is still on top.
  if top ~= nil and top ~= ow then
    session.armed = true
  elseif session.armed then
    OverworldBattle.finish()
    return
  end

  -- Whether the shot is the player's to steer at all. BACK SPRITES pins
  -- their own mon to the GB's slot on the menu while the foe stands out on
  -- the map, and there is no angle that half-framed, half-solid
  -- composition survives -- so under it the camera holds the shot the rig
  -- was solved for (the slow drift aside, which was always there). Polled
  -- per frame rather than latched at battle start: the row is reachable
  -- from the mod manager's page mid-session.
  BattleCam.steerable = not OverworldBattle.backPinned()
  -- the right stick, read as a rate before the rig is built from it: the
  -- wheel, the keys, the mouse and a drag all arrive as events and have
  -- already landed, but a stick is a HELD position and only a tick can
  -- turn it into travel (CamControl, which owns every one of those inputs)
  pcall(V.require("CamControl").tick, dt)
  BattleCam.update(dt)
  -- the battle only exists once it has been pushed; a session opened at
  -- pushBattle time has it, one opened from battle.started was handed it
  session.battle = session.battle or (top ~= ow and top or nil)
  AnimatedBattleArt.update(session.battle, dt)
  -- the world pass is hidden behind the battle, so mesh builds get the wide
  -- slice: nothing visible can hitch on them
  ChunkMesher.pump(true)

  -- The STADIUM models, ahead of the pics, because what they decide is
  -- WHICH pics are needed: a side a model is standing on gets no billboard
  -- texture rendered for it at all (see Stadium.covers). Posed and skinned
  -- here too, once for the frame -- the sun pass, the camera and, in a
  -- headset, both eyes all draw the same skinned meshes.
  pcall(function()
    local host = (session.arena and session.arena.map) or session.state.map
    V.require("Stadium").update(dt, session.battle,
                                BattleScene.groundY(host, session.arena))
  end)

  -- The mons' textures are rendered HERE, with no canvas bound, for the same
  -- reason the scene is: the pics layer binds its own targets, and doing that
  -- inside somebody else's frame means putting the frame back afterwards.
  local okTex, textures = pcall(OverworldBattle.textures, session.battle)
  if not okTex then textures = nil end
  -- stashed for the VR eye pass, which stands these same pics on the map
  -- in ITS view of the world (VoxelScene's eyes path). Stashed HERE
  -- because rendering them binds canvases, which the eye pass -- mid-scene
  -- when it wants them -- must never do; reading a stashed canvas is free.
  session.textures = textures
  -- and the move-animation layer, for the same eyes -- rendered only
  -- while a headset is actually watching, because only the VR world
  -- pass draws it (the flat screen has the animations in-frame already)
  session.animTex = nil
  local okVR, vrOn = pcall(function()
    local vr = V.require("VR")
    return vr.active and vr.active() or false
  end)
  if okVR and vrOn and session.battle then
    local okA, anim = pcall(OverworldBattle.animTexture, session.battle)
    if okA then session.animTex = anim end
  end
  session.token = (session.token or 0) + 1
  local ok, shot = pcall(BattleScene.render, session.state, session.arena,
                         textures, session.token)
  if not ok then
    -- One failure retires the arena for THIS battle and nothing else: the
    -- battle screen carries on as the engine's own, the free-roam pipeline
    -- this runs inside keeps rendering the overworld, and the next battle
    -- tries again. Rethrowing would hand the whole voxel mode to Pipelines'
    -- guard, which retires a pipeline for the session.
    session.shot = nil
    session.snapped = false
    session.broken = true
    V.mod.log:warn("overworld battle scene failed: %s -- this battle draws "
                   .. "on the plain battle background", tostring(shot))
    return
  end
  session.snapped = false
  if shot and shot.canvas then
    -- the depth of field is measured off the two marks: the slab in focus is
    -- the one the mons are standing in, at whatever the drift has done to
    -- where that lands
    local y1 = shot.ly + shot.player[2] * shot.scale
    local y2 = shot.ly + shot.enemy[2] * shot.scale
    local focusY, band, range = BattleDOF.bandFor(y1, y2, shot.ph)
    local okDof, blurred = pcall(BattleDOF.apply, shot.canvas,
                                 focusY, band, range)
    if okDof and blurred then shot.canvas = blurred end
    -- Backplates are absent, so no frost/downsample or zero-alpha composite
    -- touches the finished arena. The HUDs go directly ON that backdrop,
    -- snapped out to the window's own
    -- edges (snapHUDs). Here rather than in the battle's draw for the same
    -- reason the scene is: it binds a canvas of its own. Their only contrast
    -- treatment is pure white ink plus a dark one-pixel shadow.
    local ios = isIOS()
    local okHud, up = false, false
    -- iOS cannot run the snapped HUD path: the HUD texture is rendered into a
    -- scratch canvas and blitted back, and on iOS that Canvas-to-Canvas blit is
    -- presented upside-down. Every flip formula tried (center-mirror in 1.7.3,
    -- in-place in 1.7.4) mis-places one of the two bands, because the enemy
    -- band [0,48] and player band [48,96] are not symmetric about the 144px
    -- canvas center, so a single flip expression cannot land both correctly.
    -- Fall back to the engine's own in-frame HUD on iOS, which the engine
    -- positions correctly; drawHudPanels already elides the backplate there, so
    -- the HUD stays transparent. The text boxes are the engine's Font.drawBox
    -- (opaque white) and unaffected.
    if not ios then
      okHud, up = pcall(OverworldBattle.snapHUDs, session.battle, shot)
    end
    session.snapped = (okHud and up) and true or false
    -- once per battle, not once per frame: a driver that cannot do this cannot
    -- do it sixty times a second either, and the fallback is silent and fine
    if not ios and not okHud and not session.hudWarned then
      session.hudWarned = true
      V.mod.log:warn("overworld battle HUD snap failed: %s -- the HUDs draw "
                     .. "in the battle frame this battle", tostring(up))
    end
  end
  session.shot = shot
end

-- The finished shot for this frame, or nil when there is none and the battle
-- should draw the way it always did.
function OverworldBattle.shot()
  if not session or session.broken then return nil end
  local s = session.shot
  if s and s.canvas then return s end
  return nil
end

-- The staged fight's WORLD-side pieces, for a pass that stands the mons in
-- its own view of the map rather than in the arena's composed shot -- the
-- VR eyes. Returns the two cards as BattleScene.monCards builds them (yawed
-- toward whatever Voxel3D.eye is at CALL time, so a per-eye caller gets
-- per-eye cards), the live textures table (for the hit-flash flag), and the
-- token the shadow signature keys on. nil while nothing is staged, the
-- arena is broken, or the pics have not been rendered yet.
function OverworldBattle.worldCards()
  if not (session and session.arena and not session.broken) then return nil end
  local tex = session.textures
  if not tex then return nil end
  local host = (session.state and session.state.map) or nil
  if not host then return nil end
  local groundY = BattleScene.groundY(host, session.arena)
  return BattleScene.monCards(session.arena, groundY, tex), tex, session.token
end

-- The live session's BATTLE STATE, once the pushed battle has been met
-- (session.battle fills in from the stack in update). The VR quad reads
-- it to tell "the battle screen is on top" from "a menu is over the
-- battle" -- the UI-only panel is right for the first and wrong for the
-- second. nil with no session, a broken one, or a battle not yet pushed.
function OverworldBattle.battle()
  if not (session and not session.broken) then return nil end
  return session.battle
end

-- The move-animation layer as a texture: the engine's own drawAnimLayer,
-- rendered UNSHIFTED (slot-authored coordinates) into a GB-sized
-- transparent canvas of its own. This is what stands the effects up in
-- the VR eyes' world -- see worldAnim below -- the same move the pics
-- made through sideTexture: let the engine draw what it always draws,
-- catch it on a canvas, stand the canvas in the scene.
local animLayer = nil
-- the engine's own drawAnimLayer, captured by install(). Declared HERE,
-- above the function that reads it: a local declared further down the
-- chunk would leave this function reading a global of the same name --
-- nil forever, and the effects silently absent from the eyes (the bug
-- this comment is the tombstone of).
local innerAnim = nil

function OverworldBattle.animTexture(battle)
  if not (innerAnim and battle) then return nil end
  if not (love.graphics and love.graphics.newCanvas) then return nil end
  if not animLayer then
    local ok, c = pcall(love.graphics.newCanvas,
                        BattleScene.GB_W, BattleScene.GB_H)
    if not (ok and c) then return nil end
    pcall(c.setFilter, c, "nearest", "nearest")
    animLayer = c
  end
  local g = love.graphics
  local prevCanvas = g.getCanvas()
  local ok = pcall(function()
    g.push("all")
    g.origin()
    g.setCanvas(animLayer)
    g.clear(0, 0, 0, 0)
    g.setBlendMode("alpha")
    g.setColor(1, 1, 1, 1)
    innerAnim(battle, false)
    g.pop()
  end)
  if not ok then pcall(g.pop, g) end
  if prevCanvas then pcall(g.setCanvas, g, prevCanvas)
  else pcall(g.setCanvas, g) end
  return ok and animLayer or nil
end

-- The staged fight's effects, for the VR eyes: the animation layer plus
-- the plane to stand it on (BattleScene.fxCard -- anchored so a hit
-- authored at a slot lands on the mon standing in for that slot). nil
-- while nothing is staged or no layer was rendered this frame.
function OverworldBattle.worldAnim()
  if not (session and session.arena and not session.broken) then return nil end
  local tex = session.animTex
  if not tex then return nil end
  local host = (session.state and session.state.map) or nil
  if not host then return nil end
  local groundY = BattleScene.groundY(host, session.arena)
  local model = BattleScene.fxCard(session.arena, groundY,
                                   OverworldBattle.ANCHOR)
  if not model then return nil end
  return tex, model
end

-- Where the staged fight STANDS -- the arena and its floor height -- for a
-- camera that wants to look at it rather than draw it (the VR battle
-- mount). Answered as soon as the stage exists, textures or not: the
-- camera should be seated behind the fade before the first pic lands.
-- nil whenever no fight is staged on the world.
function OverworldBattle.stage()
  if not (session and session.arena and not session.broken) then return nil end
  local host = (session.state and session.state.map) or nil
  if not host then return nil end
  return session.arena, BattleScene.groundY(host, session.arena)
end

function OverworldBattle.invalidate()
  BattleDOF.invalidate()
  BattleHud.invalidate()
  BattlePics.invalidate()
  -- the STADIUM models hold meshes and textures of this graphics context
  -- like everything else here does
  pcall(function() V.require("Stadium").invalidate() end)
  -- Put the ROM image back before BattleArt drops the frame registry. A map
  -- or palette rebuild during a battle can then recreate filtered frames
  -- without mistaking an old animation frame for the battler's original.
  AnimatedBattleArt.finish(session and session.battle)
  BattleArt.invalidate()
  AnimatedBattleArt.invalidate()
end

-- ------- the battle screen's background
--
-- BattleState opens by filling 160x144 white -- that fill IS the battle's
-- background, and in the colorized pipeline it is also the BG canvas's clear
-- (nothing else clears it, so skipping it outright would ghost last frame).
-- So for the length of one draw, that one call is intercepted: on the two
-- offscreen canvases it becomes a transparent clear, so the shade-remap pass
-- composites the HUD and the text box over the arena and leaves the empty
-- field showing it; on the screen it is simply dropped, because the UI canvas
-- has already been cleared transparent for the world to show through.
--
-- Matched exactly -- fill, the full frame, at the origin, in opaque white --
-- so the text box (a 20x6 box lower down), a mon pic, an HP bar and the
-- move-animation flash (which is white at 0.85) all pass through untouched.
--
-- This is a shim over love.graphics and it is the one invasive thing here,
-- so it is scoped as tightly as it can be: installed around a single call,
-- removed on the way out including on error, and never live outside a battle
-- frame this mode is drawing.
local function withoutBackgroundFill(battle, fn)
  local g = love.graphics
  local rectangle = g.rectangle
  g.rectangle = function(mode, x, y, w, h, ...)
    if mode == "fill" and x == 0 and y == 0
       and w == BattleScene.GB_W and h == BattleScene.GB_H then
      local r, gr, b, a = g.getColor()
      if r > 0.99 and gr > 0.99 and b > 0.99 then
        -- Two different full-frame whites, both replaced rather than drawn.
        --
        -- OPAQUE is the battle's background, and on the offscreen canvases it
        -- doubles as their clear, so there it becomes a transparent one.
        --
        -- TRANSLUCENT is the hit flash. Over a white field that reads as a
        -- flash; over a world it whites out the map, the HUD and the text box
        -- together. BattleScene puts it back on the mons alone.
        if a > 0.99 then
          local target = g.getCanvas()
          if target ~= nil
             and (target == battle.bgCanvas or target == battle.waveCanvas) then
            g.clear(0, 0, 0, 0)
          end
        end
        return
      end
    end
    return rectangle(mode, x, y, w, h, ...)
  end
  local ok, err = pcall(fn, battle)
  g.rectangle = rectangle
  if not ok then error(err, 0) end
end

-- ------- the battle box's own paper
--
-- Font.drawBox issues its fill, border and ink into the engine's 160x144 UI
-- canvas. Styling the opaque-white fills inside that exact draw keeps the
-- paper and its corners together under both BATTLE SIZE FIXED's integer scale
-- and FILL's fractional scale. v1.68 drew a second slab into shot.canvas using
-- shot.scale, which is why HALF only lined up in FIXED.
local function drawStyledTextArea(battle, draw)
  local graphics = love.graphics
  local style = UiBackplates.textboxFillStyle()
  local whiteInk = UiBackplates.textboxUsesWhiteInk()
  local drawEngineText = function() draw(battle) end

  -- Preserve the latest build's WHITE rendering, including its black-ink
  -- treatment. Dark and paperless modes composite their paper separately so
  -- the white-ink shader cannot mistake a black slab for glyphs.
  if not whiteInk then
    return BattleHud.flipGlyphs(BattleScene.GB_W, BattleScene.GB_H, function()
      TextboxStyle.withFill(graphics, style, drawEngineText)
    end, true)
  end

  -- v1.68's clean junction came from keeping the engine ink pass completely
  -- paperless: the two hardware-style 8x8 wipes were suppressed along with
  -- Font.drawBox's fills, so they could not leave a second translucent tile
  -- around the PP count. Keep that proven draw order, but place the selected
  -- paper directly in the 160x144 UI canvas first. Unlike v1.68's old
  -- world-canvas slab, this still scales with the border in both FIXED and
  -- FILL layouts.
  if style ~= nil then
    local color = { graphics.getColor() }
    local blend = { graphics.getBlendMode() }
    graphics.setBlendMode("replace")
    graphics.setColor(style[1], style[2], style[3], style[4])
    for _, rect in pairs(OverworldBattle.textPaperRects(
                           battle, UiBackplates.textboxMode())) do
      graphics.rectangle("fill", rect[1], rect[2], rect[3], rect[4])
    end
    graphics.setColor(color[1], color[2], color[3], color[4])
    graphics.setBlendMode(blend[1], blend[2])
  end

  return BattleHud.flipGlyphs(BattleScene.GB_W, BattleScene.GB_H, function()
    TextboxStyle.withFill(graphics, nil, drawEngineText)
  end, false)
end

-- ------- the hour's light, on a pic that is not geometry
--
-- Everything standing in the arena goes through the voxel shader, and that
-- shader multiplies by the hour's tint: at dusk the whole diorama warms, at
-- night it goes blue, and the two mons' cards go with it because they are
-- drawn in the same pass as the ground they stand on.
--
-- A back pic pinned to the menu is not in that pass. It is the engine's own
-- flat blit over the finished shot, so it arrived at noon while the world
-- behind it was at midnight -- a mon lit by nothing in the frame.
--
-- So the tint is applied by hand, to that one draw. Every colour the pics
-- layer sets is multiplied on its way past, which is the whole of it: the
-- layer draws the pic with love.graphics.draw and LOVE multiplies by the draw
-- colour, so tinting the colour tints the pixels -- and the alpha, the faint
-- slide's fade and the blink's own colour all compose with it rather than
-- being overwritten.
--
-- What this does NOT get is the sun: the cards are shadow-mapped, so one
-- standing under a tree is darker than the tint alone, and this pic has no
-- position in the scene to be shadowed at. It carries the hour and not the
-- weather, which is the part the eye reads.
local function withTint(tint, fn, ...)
  if not tint then return fn(...) end
  local r, g, b = tint[1] or 1, tint[2] or 1, tint[3] or 1
  if r > 0.999 and g > 0.999 and b > 0.999 then return fn(...) end
  local gfx = love.graphics
  local setColor = gfx.setColor
  gfx.setColor = function(cr, cg, cb, ca, ...)
    if type(cr) == "table" then
      return setColor({ (cr[1] or 1) * r, (cr[2] or 1) * g, (cr[3] or 1) * b,
                        cr[4] }, cg, ...)
    end
    if cr == nil then return setColor(cr, cg, cb, ca, ...) end
    return setColor(cr * r, (cg or 1) * g, (cb or 1) * b, ca, ...)
  end
  local ok, err = pcall(fn, ...)
  gfx.setColor = setColor
  -- the layer leaves whatever colour it last set, and that one is tinted;
  -- hand the next caller plain white rather than a dimmed one
  setColor(1, 1, 1, 1)
  if not ok then error(err, 0) end
end

-- ------- the mons, as textures for the 3D pass
--
-- The two Pokemon are not composited over the world any more: they are quads
-- standing in it (see BattleBillboard). What that needs from the battle
-- screen is a TEXTURE per side -- and the honest way to get one is to let the
-- engine draw its own pics layer, unchanged, into a canvas.
--
-- So the layer is rendered twice, once per side, with the other side
-- falsified out of existence by nulling exactly the fields its branches
-- test. Everything the engine does to a pic comes along for free that way:
-- the trainer pic before the send-out, the grow-out-of-the-ball scale, the
-- faint slide, the damage blink, the squish, every SE displacement. None of
-- it is reimplemented and none of it can drift.
--
-- Two things are forced during that render. The scale, to 1, so the texture
-- carries the artwork's own pixels and the BILLBOARD does the sizing; and the
-- placement, so the pic lands centred on a known column with its feet on a
-- known row. That known point is what the quad is then hung from.
local TEX_AX, TEX_AY = 80, 96          -- forced pic centre and baseline
local TRAINER_AX, TRAINER_AY = 124, 56 -- the intro trainer pic's own slot
local OPPONENT_TRAINER_SCALE = 1       -- trainer cards only; Pokemon stay 1x

OverworldBattle.TEX_AX, OverworldBattle.TEX_AY = TEX_AX, TEX_AY

-- Which side is being rendered, or nil. The placement wrappers read it.
local texturing = nil
local texturingMetric = nil
local texturingAx, texturingAy = TEX_AX, TEX_AY

local texCanvas = {}
local innerPics = nil                   -- captured by install()
local innerHUDs = nil                   -- likewise, for the snapped HUD layer
-- (innerAnim, their sibling, is declared up beside animTexture, which
-- sits earlier in the chunk than this group and must see the local)

local function texCanvasFor(side, w, h)
  local c = texCanvas[side]
  w, h = w or BattleScene.GB_W, h or BattleScene.GB_H
  if c and c:getWidth() == w and c:getHeight() == h then return c end
  local ok, made = pcall(love.graphics.newCanvas, w, h, { dpiscale = 1 })
  if not ok then return nil end
  made:setFilter("nearest", "nearest")
  texCanvas[side] = made
  return made
end

-- Whether this side has anything to draw at all. Mirrors drawPicsLayer's own
-- guards, so an empty canvas is never hung on a quad: a fainted, hidden or
-- not-yet-sent-out mon simply has no billboard this frame.
local function sideVisible(battle, side)
  if side == "enemy" then
    if battle.showEnemyTrainer and battle.trainerPic then return true end
    return (battle.enemy and battle.enemy.sprite and not battle.enemyHidden
            and not battle.enemySendingOut
            and not battle:fxHidden(battle.enemy)) and true or false
  end
  if battle.showPlayerBack and battle.playerBackPic then return true end
  local hide = battle.safari or battle.demo
  return (battle.player and battle.player.sprite and not hide
          and not battle.sendingOut
          and not battle:fxHidden(battle.player)) and true or false
end

local OFF = {
  enemy = { player = false, showPlayerBack = false },
  player = { enemy = false, showEnemyTrainer = false },
}

-- Whether the player's captured world card should keep the horizontal
-- orientation already present in its image. Backs always do. Fronts normally
-- receive Battle Art's face-the-opponent mirror, unless the user has selected
-- DEFAULT for an external sprite that is already authored for the player side.
function OverworldBattle.playerCardNoMirror()
  return BattleArt.playerSide() == "back"
         or not BattleArt.flipsPlayerFront()
end

-- Render one side's pics layer into its canvas and report where the pic's
-- feet ended up, in canvas coordinates.
function OverworldBattle.sideTexture(battle, side)
  if not (innerPics and battle) then return nil end
  -- On the STADIUM rung a side standing a MODEL needs no pic: rendering one
  -- anyway would hang a second, flat copy of the same Pokemon on the same
  -- cell. Asked per side, so a species with no pack -- or a substitute
  -- doll, or the trainer before the send-out -- still comes through here.
  local okS, covered = pcall(function()
    return V.require("Stadium").covers(battle, side)
  end)
  if okS and covered then return nil end
  BattleArt.apply(battle)
  if not sideVisible(battle, side) then return nil end
  local battler = side == "enemy" and battle.enemy or battle.player
  local showingTrainer = (side == "enemy" and battle.showEnemyTrainer
                           and battle.trainerPic)
                         or (side == "player" and battle.showPlayerBack
                             and battle.playerBackPic)
  local shownImage = showingTrainer
                     and (side == "enemy" and battle.trainerPic
                          or battle.playerBackPic)
                     or (battler and battler.sprite)
  local metric = BattleArt.metrics(shownImage)
  local cw, ch = BattleScene.GB_W, BattleScene.GB_H
  local ax, ay = TEX_AX, TEX_AY
  if metric then
    cw = math.max(cw, metric.w + 2)
    ch = math.max(ch, metric.h + 2)
    ax = cw / 2
    ay = math.max(TEX_AY, metric.h + 1)
  end
  local canvas = texCanvasFor(side, cw, ch)
  if not canvas then return nil end

  local g = love.graphics
  local prevCanvas = g.getCanvas()
  local prevBlend, prevAlpha = g.getBlendMode()
  -- The pic-window scissors are in the battle screen's fixed coordinates and
  -- would clip a pic that has been moved to the middle of its own canvas.
  -- There is nothing here for them to protect -- no HUD, no text box, just
  -- the one pic -- so they are switched off for the render.
  local setScissor, intersectScissor = g.setScissor, g.intersectScissor
  local getScissor = g.getScissor
  g.setScissor = function() end
  g.intersectScissor = function() end
  g.getScissor = function() return nil end

  local saved = {}
  for k, v in pairs(OFF[side]) do saved[k] = battle[k]; battle[k] = v end
  texturing = side
  texturingMetric = metric
  texturingAx, texturingAy = ax, ay

  local ok, err = pcall(function()
    g.setCanvas(canvas)
    g.clear(0, 0, 0, 0)
    g.setBlendMode("alpha")
    g.setColor(1, 1, 1, 1)
    if side == "enemy" and showingTrainer and metric then
      local img = battle:picImage(battle.trainerPic)
      g.draw(img, ax - metric.center, ay - (metric.y1 + 1))
    else
      innerPics(battle, 0, 0, 0)
    end
  end)

  texturing = nil
  texturingMetric = nil
  texturingAx, texturingAy = TEX_AX, TEX_AY
  for k in pairs(OFF[side]) do battle[k] = saved[k] end
  g.setScissor, g.intersectScissor, g.getScissor =
    setScissor, intersectScissor, getScissor
  if prevCanvas then g.setCanvas(prevCanvas) else g.setCanvas() end
  g.setBlendMode(prevBlend or "alpha", prevAlpha)
  if not ok then error(err, 0) end

  local trainer = showingTrainer and true or false
  -- The intro trainer pic draws itself straight into its own 7x7 slot rather
  -- than through the placement helpers, so it is hung from that slot instead.
  if side == "enemy" and battle.showEnemyTrainer and battle.trainerPic
     and not metric then
    ax, ay = TRAINER_AX, TRAINER_AY
  end
  local playerNoMirror = side == "player"
                         and OverworldBattle.playerCardNoMirror()
  return { canvas = canvas, ax = ax, ay = ay, trainer = trainer,
           noDayTint = BattleArt.isStaticFront(shownImage),
           -- Opponent trainer cards are authored for a compact intro slot.
           -- Enlarge only those cards in world space, whichever generation
           -- supplied them. Pokemon remain native 1x and untouched.
           presentationScale = side == "enemy" and trainer
                               and OPPONENT_TRAINER_SCALE or 1,
           noMirror = playerNoMirror }
end

-- Whether the hit flash is showing this frame.
--
-- Mirrors BattleState:draw's own test, because the flash is a DRAW-time
-- decision there (a counter plus the frame parity that makes it flicker) and
-- there is no seam that reports it. Read-only, so the worst a future engine
-- change can do is flash on a frame the engine would not have.
function OverworldBattle.flashing(battle)
  local fx = battle and battle.fx
  if not (fx and fx.flash and fx.flash > 0) then return false end
  return (battle.frame or 0) % 4 < 2
end

-- Both sides, or nil when neither has anything to show.
--
-- One side under BACK SPRITES: the player's mon is not standing on the map at all
-- there, it is on the menu, so it has no card to be a texture for -- and
-- nothing downstream has to know that. No billboard, and no shadow on the
-- ground under a mon that is not on it.
function OverworldBattle.textures(battle)
  if not battle then return nil end
  local out = {}
  local okE, enemy = pcall(OverworldBattle.sideTexture, battle, "enemy")
  local okP, player = true, nil
  if not OverworldBattle.backPinned() then
    okP, player = pcall(OverworldBattle.sideTexture, battle, "player")
  end
  out.enemy = okE and enemy or nil
  out.player = okP and player or nil
  -- On the STADIUM rung both sides can legitimately have no pic -- the pair
  -- of them are models -- and this table must still come back, because it
  -- carries the HIT FLASH, and because the VR eye pass uses its presence to
  -- decide there is a staged fight to draw at all.
  local okStanding, standing = pcall(function()
    return V.require("Stadium").standing()
  end)
  if not (out.enemy or out.player or (okStanding and standing)) then
    return nil
  end
  if not (out.enemy or out.player) then return nil end
  out.flash = OverworldBattle.flashing(battle)
  return out
end

-- ------- engine seams
--
-- Four wraps, each idempotent so a hot reload cannot stack them.

function OverworldBattle.install()
  local OverworldState = require("src.world.OverworldController")
  if not OverworldState.dramaticShapeBattleHook then
    local inner = OverworldState.pushBattle
    -- The one place the overworld starts a battle, and it runs BEFORE the
    -- transition is pushed -- which is what lets the cull happen off-screen
    -- and the wipe play over a map with nobody on it.
    function OverworldState:pushBattle(battle)
      pcall(OverworldBattle.begin, self, battle)
      return inner(self, battle)
    end
    OverworldState.dramaticShapeBattleHook = true
  end

  -- the STADIUM rung's own four wraps, which drive the models' animations
  -- off the fight (see Stadium.install). Idempotent in the same way, and
  -- installed whichever rung the row is on: the wraps do nothing at all
  -- while no stadium session is live.
  pcall(function() V.require("Stadium").install() end)

  local BattleState = require("src.battle.BattleState")

  -- Crystal Animated Sprites advances by assigning battler.sprite after the
  -- engine update. DUPLICATE FIX: BATTLE ART owns that same field, so retain
  -- our already-selected frame when (and only when) Crystal's exported image
  -- predicate confirms that its loop overwrote it. The optional dependency in
  -- manifest.json makes this wrapper outermost even with Crystal v1.5's 980
  -- priority. Engine effects and unknown sprite mods pass through untouched.
  if not BattleState.dramaticShapeDuplicateFixHook then
    local innerUpdate = BattleState.update
    function BattleState:update(dt)
      local enemy = self.enemy
      local player = self.player
      local ownedEnemy = enemy and BattleArt.isExternal(enemy.sprite)
                         and enemy.sprite or nil
      local ownedPlayer = player and BattleArt.isExternal(player.sprite)
                          and player.sprite or nil
      local enemySpecies = BattleArt.speciesFor(enemy)
      local playerSpecies = BattleArt.speciesFor(player)
      local result = innerUpdate(self, dt)
      if not BattleArt.prefersModded() then
        if ownedEnemy and enemy and enemySpecies == BattleArt.speciesFor(enemy)
           and BattleArt.isCrystalImage(enemy.sprite) then
          enemy.sprite = ownedEnemy
        end
        if ownedPlayer and player
           and playerSpecies == BattleArt.speciesFor(player)
           and BattleArt.isCrystalImage(player.sprite) then
          player.sprite = ownedPlayer
        end
      end
      return result
    end
    BattleState.dramaticShapeDuplicateFixHook = true
  end

  if not BattleState.dramaticShapeTrainerPartyHook then
    local newTrainer = BattleState.newTrainer
    function BattleState.newTrainer(game_, oppClass, partyIndex)
      local battle = newTrainer(game_, oppClass, partyIndex)
      battle.dramaticShapeTrainerParty = partyIndex or 1
      return battle
    end
    BattleState.dramaticShapeTrainerPartyHook = true
  end

  -- A staged battle is already a finished window-sized world image.  The
  -- engine's generic warp fade is composited over that image in endFrame,
  -- after the snapped HUD has been baked into it but before the live dialog
  -- canvas is drawn.  If a Transition leaves worldFadeAlpha armed, that makes
  -- the arena and its name/HP blocks uniformly gray while the dialog below
  -- stays bright white.  Battle entry has BattleTransition's own wipe and
  -- battle exit has BattleExit's finished-frame veil, so the overworld warp
  -- fade has no job on this path.  Suppress only that overlay while this
  -- module's world override is actually active; ordinary map fades and flat
  -- fallback battles remain untouched.
  local Renderer = require("src.render.Renderer")
  if not Renderer.dramaticShapeBattleFadeHook then
    local innerEndFrame = Renderer.endFrame
    function Renderer:endFrame(zones, worldZones)
      local staged = OverworldBattle.shot() and self.worldOverride
      if staged then
        self.worldFadeAlpha = nil
      end

      -- Newer renderer chains can decide to paint their transition after an
      -- outer wrapper has entered endFrame.  Clearing the field above is then
      -- one instruction too early.  Guard the actual compositor rectangle as
      -- well: a translucent, window-sized black fill inside Renderer:endFrame
      -- is its world fade and nothing else.  The battle-entry cascade uses
      -- opaque tile/strip rects, while BattleExit paints after this wrapper has
      -- returned, so both deliberate transitions remain intact.
      local gfx = love.graphics
      local rectangle = gfx.rectangle
      if staged and rectangle then
        gfx.rectangle = function(mode, x, y, w, h, ...)
          if mode == "fill" and x == 0 and y == 0 then
            local ww, wh = gfx.getDimensions()
            local r, g, b, a = gfx.getColor()
            if w >= ww and h >= wh and r < 0.001 and g < 0.001 and b < 0.001
               and a > 0 and a < 0.999 then
              if session and not session.fadeWarned then
                session.fadeWarned = true
                V.mod.log:info("suppressed staged battle compositor fade "
                               .. "(alpha %.3f)", a)
              end
              return
            end
          end
          return rectangle(mode, x, y, w, h, ...)
        end
      end

      local ok, result = pcall(innerEndFrame, self, zones, worldZones)
      gfx.rectangle = rectangle
      if not ok then error(result, 0) end
      return result
    end
    Renderer.dramaticShapeBattleFadeHook = true
  end

  -- The renderer guard above is intentionally installed before this return.
  -- Mod replacement can preserve the engine class and its existing battle
  -- wrappers for the running process; a newly added renderer seam must still
  -- be allowed to install in that session.
  if BattleState.dramaticShapeBattleHook then return end

  -- Integer scales only. The camera is solved to make one overworld square
  -- exactly big enough for a pic at its own integer scale (see BattleCam), so
  -- the fit never has to come out of the pixels -- and a species override or
  -- a battle_sprite_scales entry that asks for 1.7x would undo that and
  -- resample the sprite into mush. Rounded rather than refused, so such a mod
  -- still gets the bigger or smaller mon it asked for, on the pixel grid.
  local innerScale = BattleState.resolveBattleScale
  function BattleState.resolveBattleScale(data, side, path, species)
    local base = innerScale(data, side, path, species)
    -- 1:1 into the billboard texture: the artwork's own pixels, with the
    -- quad's world size doing every bit of the scaling. Anything else would
    -- resample the sprite twice -- once into the texture and again on the way
    -- to the screen -- and a twice-resampled Gen 1 pic is mush.
    if texturing then return 1 end
    -- The engine's trainer/back slot defaults to 2x because ROM back pictures
    -- are authored at half display resolution. Supplied species backs and
    -- custom player-trainer PNGs are already full-display art, so both static
    -- PLAYER ART images and animated atlas frames stay native 1x on OG UI.
    -- ROM backs retain their intended 2x scale.
    local battle = session and session.battle
    if side == "back" and pinnedSpeciesMetric() then return 1 end
    if side == "back" and battle and battle.showPlayerBack
       and BattleArt.isExternal(battle.playerBackPic) then
      return 1
    end
    if side == "back" and AnimatedBattleArt.hasPlayerTrainerFrame(battle) then
      return 1
    end
    if not OverworldBattle.shot() then return base end
    return math.max(1, math.floor((tonumber(base) or 1) + 0.5))
  end

  -- Keyed-out whites inside a pic used to be filled by the white field
  -- behind it. There is a world back there now, so they are filled here
  -- instead -- see BattlePics, which puts the paper back without touching
  -- the silhouette.
  --
  -- Native Pokemon pics use a sealed lower silhouette whether they stand in
  -- the world or sit on the box. Yellow's pale-bodied sprites often carry
  -- their shade-0 paper all the way to the lower edge; treating that opening
  -- as scenery turns Jigglypuff, Seel and friends into outlines. Native
  -- trainer art keeps the open-bottom rule so the world can still show
  -- between authored legs. Passed the pre-bake image, because that is the
  -- one the battle holds a reference to.
  local innerPic = BattleState.picImage
  function BattleState:picImage(img)
    local out = innerPic(self, img)
    if not OverworldBattle.shot() then return out end
    -- Authored Battle Art PNGs already distinguish white paint from alpha.
    -- Crystal Animated Sprites does too and publishes an identity predicate
    -- for generated/transform frames. Do not reinterpret either one's holes.
    if BattleArt.isExternal(img) or BattleArt.isExternal(out)
       or BattleArt.isCrystalImage(img) or BattleArt.isCrystalImage(out) then
      return out
    end

    -- Everything left is the engine's decoded ROM art. Its shade-0 paper was
    -- keyed to alpha because the original battle field was itself white.
    local pokemon = OverworldBattle.isPokemonPic(self, img)
    local sealBottom = pokemon or OverworldBattle.pinnedPic(self, img)
    return BattlePics.filled(out, sealBottom)
  end

  -- While a billboard texture is being rendered both pics are put in the same
  -- known place -- centred on TEX_AX with their feet on TEX_AY -- so the quad
  -- has one anchor to hang from whichever side and whichever species it is
  -- carrying. Outside that render both helpers answer exactly as they always
  -- did.
  local innerBack = BattleState.backPlacement
  function BattleState.backPlacement(w, h, pad, padL, scale)
    local x, y, s = innerBack(w, h, pad, padL, scale)
    if not texturing then return x, y, s end
    if texturingMetric then
      return texturingAx - texturingMetric.center * scale,
             texturingAy - (texturingMetric.y1 + 1) * scale, s
    end
    return texturingAx - w * scale / 2,
           texturingAy - (h - pad) * scale, s
  end

  local innerFront = BattleState.frontPlacement
  function BattleState.frontPlacement(ex, ey, w, h, scale)
    local x, y, s = innerFront(ex, ey, w, h, scale)
    if not texturing then return x, y, s end
    if texturingMetric then
      return texturingAx - texturingMetric.center * scale,
             texturingAy - (texturingMetric.y1 + 1) * scale, s
    end
    return texturingAx - w * scale / 2, texturingAy - h * scale, s
  end

  local innerDraw = BattleState.draw
  function BattleState:draw()
    local shot = OverworldBattle.shot()
    -- AskName blanks the field on purpose (the nickname prompt is meant to
    -- sit on nothing); leave that one alone.
    if not shot or self.blankForAskName then
      -- nil, not false: the class default is inherited again, so a battle
      -- that loses its arena mid-fight goes back to white voids
      self.letterboxWhite = nil
      self.dramaticShapeShot = nil
      return innerDraw(self)
    end
    self.dramaticShapeShot = shot
    -- The world reaches the screen through the seam a render pipeline's
    -- finished world image already uses: one window-resolution canvas,
    -- blitted a pixel to a pixel, with the 160x144 UI canvas composited over
    -- it in the classic letterbox afterwards. That is what makes the backdrop
    -- as crisp as the free-roam diorama while the pics and text stay GB art.
    local renderer = game().renderer
    if renderer and renderer.setWorldOverride then
      renderer:setWorldOverride(shot.canvas)
    end
    -- beginFrame clears the UI canvas white for an opaque state; the world is
    -- under it now, so clear it back to nothing and let it through. Safe to
    -- do here: an opaque battle is the lowest state drawn, so nothing has
    -- drawn into this canvas yet.
    love.graphics.clear(0, 0, 0, 0)
    -- the white letterbox exists so the window matches the white battle
    -- canvas; there is a world out to the window edges now
    self.letterboxWhite = false
    OverworldBattle.drawHudPanels(self)
    withoutBackgroundFill(self, innerDraw)
  end

  -- The mons are geometry standing on the map now, drawn in the 3D pass
  -- before this screen is composited at all, so the flat pics layer has
  -- nothing left to do here. Skipped rather than left to draw underneath, or
  -- every Pokemon would appear twice: once on its tile and once in its slot.
  --
  -- Except when a selected generated back is missing or invalid. That fallback
  -- deliberately never becomes geometry, and this layer is the only thing
  -- that draws it. The engine's own onlySide argument does the whole job: one
  -- call, the player's branches alone, in the slot and at the scale the GB
  -- always put them -- feet on the box, 2x, back view.
  innerPics = BattleState.drawPicsLayer
  function BattleState:drawPicsLayer(slide, sx, sy, onlySide, skipMenuClip)
    local shot = self.dramaticShapeShot
    if not shot then
      return innerPics(self, slide, sx, sy, onlySide, skipMenuClip)
    end
    if OverworldBattle.backPinned() and onlySide ~= "enemy" then
      -- under the hour's own light, like everything else in the frame -- see
      -- withTint, and the tint BattleScene hands over with the shot.
      --
      -- Except on the wavy path, where the pic is baked into the GRAYSCALE bg
      -- canvas for the zone pass to colour by region. That pass keys off the
      -- red channel, and a night tint pulls red down -- it would not darken
      -- the mon, it would remap it to the wrong shade. SE_WAVY_SCREEN lasts a
      -- second and the hour survives it fine.
      -- SPRITE LIGHT: UNLIT draws the player back pic flat and true-colour,
      -- with no night tint -- same as the 3D cards in BattleScene. Neutralise
      -- the shot's hour tint (and the wavy-path exception below) when unlit.
      local tint = not self.grayPics and (UiBackplates.spritesUnlit()
                    and { 1, 1, 1 } or shot.tint) or nil
      local metric = pinnedSpeciesMetric()
      if metric then
        local grow = self.player and self:growInScale(self.player) or nil
        local dx, dy = OverworldBattle.backPinOffset(metric, grow)
        love.graphics.push()
        love.graphics.translate(math.floor(dx + 0.5), math.floor(dy + 0.5))
        local ok, result = pcall(withTint, tint, innerPics, self, slide,
                                 sx, sy, "player", skipMenuClip)
        love.graphics.pop()
        if not ok then error(result, 0) end
        return result
      end
      return withTint(tint, innerPics, self, slide, sx, sy, "player",
                      skipMenuClip)
    end
  end

  -- The battle's text box and its menus, over the frosted glass laid down for
  -- them rather than over their own white paper -- and their ink flipped with
  -- the HUD's when the ground under the frame is dark, by the same rule and
  -- off the same verdict.
  local innerText = BattleState.drawTextArea
  function BattleState:drawTextArea()
    if not self.dramaticShapeShot then return innerText(self) end
    if BattlePresentation.suppressed("text", self) then return end
    if isIOS() then return innerText(self) end
    return drawStyledTextArea(self, innerText)
  end

  local innerAnim = BattleState.drawAnimLayer
  function BattleState:drawAnimLayer(colorized)
    local shot = self.dramaticShapeShot
    if not shot then return innerAnim(self, colorized) end
    -- Move animations are authored against the pics' fixed slots, and a single
    -- animation reaches across both sides, so there is no per-side offset to
    -- give them. They ride to where the PAIR went: the midpoint of the two
    -- mons' projected positions, less the midpoint of the slots they used to
    -- sit in. A hit still lands on the mon it is aimed at.
  --
  -- And they ride the pair's SEPARATION as well, because the mons
  -- themselves do. Both are geometry standing on the map, so the camera
  -- sizes them: zoom in and they grow, swing round to side-on and the two
  -- marks close up as the axis foreshortens. A layer that only slid would
  -- have held the authored 106-pixel spacing through all of it -- a beam
  -- fired between two mons that are no longer that far apart, ending in
  -- the air beside the one it was aimed at. Scaling about the same
  -- midpoint keeps every authored offset the same fraction of the gap it
  -- was authored as.
  local a = OverworldBattle.ANCHOR
  -- BACK SPRITES leaves the player's mon exactly where the GB put it, so that side
  -- contributes no movement at all and the pair's centre has gone half as
  -- far as the foe's mark did.
  local px, py = shot.player[1], shot.player[2]
  if OverworldBattle.backPinned() then px, py = a.player[1], a.player[2] end
  local cx, cy = (shot.enemy[1] + px) / 2, (shot.enemy[2] + py) / 2
  local ax = (a.enemy[1] + a.player[1]) / 2
  local ay = (a.enemy[2] + a.player[2]) / 2
  love.graphics.push()
  love.graphics.translate(cx - ax, cy - ay)
  -- Clamped, and skipped outright if the marks ever coincide: a
  -- degenerate projection must leave the effects the size they were
  -- rather than collapse them to nothing or blow them across the screen.
  local k = OverworldBattle.animScale(shot, px, py)
  if k ~= 1 then
    love.graphics.translate(ax, ay)
    love.graphics.scale(k, k)
    love.graphics.translate(-ax, -ay)
  end
  local ok, err = pcall(innerAnim, self, colorized)
  love.graphics.pop()
  if not ok then error(err, 0) end
  end

  -- The engine's flash has a SECOND half, and it is the one that reaches the
  -- menu. Beside the white rectangle (dropped above) the flash moves are
  -- driven by a BGP palette fade -- BGP_LIGHT and friends -- which the
  -- colorized pipeline applies in drawZonePass to the WHOLE background
  -- canvas. That canvas carries the HUD glyphs and the text box, so a fade
  -- meant for the two mons washed the menu out with them.
  --
  -- The fade is left switched on for the pics, which read it through
  -- picImage, and switched off for the zone pass alone. So the mons flash
  -- and the furniture around them does not.
  --
  -- The zone pass has a SECOND thing it paints, and this is the one that
  -- reads as the menu box flashing. A screen shake makes it fill every zone
  -- with the zone's own color 0 before it draws the offset copy -- the
  -- hardware showing empty BG in the strip the shake vacated. On a white
  -- battle field that fill is invisible; over a world it is an opaque white
  -- sheet across the whole frame, and since a shake program alternates
  -- offset and no-offset frames (SE_SHAKE_SCREEN steps dx 1, 0, 1, 0...) it
  -- switches on and off a few times a second. It is dropped: the background
  -- here is the map, so what the shake vacates should show the map.
  local innerZone = BattleState.drawZonePass
  function BattleState:drawZonePass(src, sx, sy)
    if not self.dramaticShapeShot then return innerZone(self, src, sx, sy) end
    -- shadow the method on the instance for this call only; putting the
    -- field back to whatever it was (normally nil) lets the class method be
    -- found again
    local had = rawget(self, "activeBgp")
    self.activeBgp = function() return nil end
    local g = love.graphics
    local rectangle = g.rectangle
    g.rectangle = function(mode, ...)
      -- the pass draws no other rectangle; the shake still shifts the copy
      if mode == "fill" then return end
      return rectangle(mode, ...)
    end
    local ok, err = pcall(innerZone, self, src, sx, sy)
    g.rectangle = rectangle
    self.activeBgp = had
    if not ok then error(err, 0) end
  end

  -- Black glyphs on grass are not readable; over a frosted panel measured
  -- dark they are not readable either, so they go white. Mapped rather than
  -- rewritten: the HUD sets pure black for its text and nothing else, and in
  -- the colorized pipeline this lands in the grayscale BG canvas, where
  -- white IS shade 0 and the zone pass then colours it like every other
  -- lightest-shade surface. One rule, both pipelines.
  --
  -- The HP bar is untouched: it is drawn in its own greens and reds, and
  -- only an exactly-black set is remapped.
  innerHUDs = BattleState.drawHUDs
  function BattleState:drawHUDs(slide)
    if self.dramaticShapeShot
       and BattlePresentation.suppressed("hud", self) then return end
    -- Normally the HUDs have already been drawn this frame, snapped out to the
    -- window's edges and composited into the world image (snapHUDs). Drawing
    -- them here as well would show each block twice, once in each place.
    if self.dramaticShapeShot and snapped() then return end
    -- COLOR preserves the engine's black glyphs and HP-bar colours, adding a
    -- white shadow; INVERTED maps its ink to white with a black shadow. The
    -- former also owns ARENA FILL: WHITE, where white ink would disappear.
    local color = UiBackplates.hudUsesColor()
    local colorShadow = UiBackplates.hudUsesColorShadow()
    if not (self.dramaticShapeShot and (self.dramaticShapeDark or color)) then
      return innerHUDs(self, slide)
    end
    local battle = self
    BattleHud.flipGlyphs(BattleScene.GB_W, BattleScene.GB_H, function()
      innerHUDs(battle, slide)
    end, color, nil, colorShadow)
  end

  BattleState.dramaticShapeBattleHook = true
end

-- Whether each HUD block is on screen this frame.
--
-- READ-ONLY duplicates of drawHUDs' own two guards, because there is no seam
-- that reports "the enemy HUD is up". A panel under a HUD that is not there
-- would be a frosted slab floating in the arena, so it is worth mirroring;
-- the worst a future engine change can do is show an empty one for a frame,
-- never break a battle.
function OverworldBattle.hudLive(battle, slide)
  local enemy = battle.enemy and not battle.showEnemyTrainer
                and not battle.enemySendingOut
                and not battle:growInScale(battle.enemy) and slide == 0
                and not battle.enemy.fainted
  local player = battle.player and not (battle.safari or battle.demo)
                 and not battle.showPlayerBack and slide == 0
  return enemy and true or false, player and true or false
end

-- ------- the snapped composite
--
-- The engine's own HUD layer, rendered into a texture.
--
-- One thing is falsified for the render, and it is falsified because this layer
-- never reaches the battle's zone pass -- it is composited into the world image,
-- outside the frame that pass covers. In the colorized pipeline drawHUDs leaves
-- the HP bar's fill as DMG gray for the zone pass to colour by region (#229);
-- answered false, it tints its own greens and reds instead, exactly as it does
-- on the flat path. The glyphs are pure black either way, which is what the
-- flip in BattleHud.layerTexture is measured against.
--
-- Shadowed on the instance for this call only, the way drawZonePass shadows
-- activeBgp: putting the field back to whatever it was (normally nil) lets the
-- class method be found again.
function OverworldBattle.hudTexture(battle, slide, dark, inverted, colorShadow)
  if not (innerHUDs and battle) then return nil end
  local had = rawget(battle, "colorMode")
  battle.colorMode = function() return false end
  local ok, layer = pcall(BattleHud.layerTexture,
                          BattleScene.GB_W, BattleScene.GB_H, dark,
                          function() innerHUDs(battle, slide) end,
                          inverted, colorShadow, battle)
  battle.colorMode = had
  return ok and layer or nil
end

-- Draw both HUD blocks into the world image at the window's edges, each on its
-- own frosted panel. Returns true when the frame's HUDs are up there and the
-- in-frame draw must be skipped; false leaves the battle screen's own HUD
-- exactly as it was before any of this existed.
--
-- Both bands are blitted whether or not that side's HUD is LIVE, because a band
-- carries more than the HUD: the pokeball rows of the intro and of an enemy
-- faint, and the safari ball count, all draw in these rows and belong at the
-- same edge as the block they share it with. The panels are the ones that
-- follow hudLive -- frosted glass under nothing is a slab floating in the arena.
function OverworldBattle.snapHUDs(battle, shot)
  if not (battle and shot and shot.canvas and (shot.scale or 0) > 0) then
    return false
  end
  local ios = isIOS()
  local slide = (battle.introSlide or 0) * 4
  local rects, bandPlacement = OverworldBattle.snapRects(shot)
  local enemy, player = OverworldBattle.hudLive(battle, slide)
  local live = {}
  if enemy then live.enemy = rects.enemy end
  if player then live.player = rects.player end
  -- On iOS the text box's frosted panel is mirrored upward by the
  -- Canvas-to-Canvas path, producing a large ghost rectangle behind the
  -- mons, so only the box's backing is skipped there -- the box itself stays
  -- in the GB frame as the engine's own opaque-white panel (black glyphs),
  -- which is exactly the look we want. On every other platform the box's glass
  -- goes into this same world-canvas pass.
  if not ios then
    for key, rect in pairs(OverworldBattle.textRects(battle)) do
      live[key] = toWorld(rect, shot)
    end
  end
  -- Both HUD modes run the contrast pass: COLOR preserves black glyphs and
  -- coloured bars with a white shadow; INVERTED makes the ink white with a
  -- black shadow. iOS does not reach this function (it uses the engine's own
  -- in-frame HUD); see update().
  local color = UiBackplates.hudUsesColor()
  local colorShadow = UiBackplates.hudUsesColorShadow()
  local panelDark = not UiBackplates.arenaWhite()
  if session then session.dark = panelDark end
  local layer = OverworldBattle.hudTexture(battle, slide, true, color,
                                           colorShadow)
  if not layer then return false end

  local g = love.graphics
  local prevCanvas = g.getCanvas()
  local prevBlend, prevAlpha = g.getBlendMode()
  local ok, err = pcall(function()
    g.setCanvas(shot.canvas)
    g.setBlendMode("alpha")
    for key, rect in pairs(live) do
      BattleHud.panel(rect, shot, panelDark, true)
    end
    g.setColor(1, 1, 1, 1)
    for side, band in pairs(OverworldBattle.HUD_BAND) do
      local placement = bandPlacement[side]
      local quad = g.newQuad(band[1], band[2], band[3], band[4],
                             BattleScene.GB_W, BattleScene.GB_H)
      g.draw(layer, quad, placement.x + band[1] * placement.scale,
             placement.y, 0, placement.scale, placement.scale)
    end
  end)
  if prevCanvas then g.setCanvas(prevCanvas) else g.setCanvas() end
  g.setBlendMode(prevBlend or "alpha", prevAlpha)
  g.setColor(1, 1, 1, 1)
  if not ok then error(err, 0) end
  return true
end

-- Lay the frosted glass down under whichever HUD and box are about to draw,
-- and record which way the glyphs have to flip.
--
-- The panels are the fallback path only: normally the HUDs are snapped out to
-- the window's edges and their glass, and the box's, went into the world image
-- with them (snapHUDs). The VERDICT is needed either way -- the box's ink is
-- drawn here, in the GB frame, whichever path laid the glass under it.
function OverworldBattle.drawHudPanels(battle)
  local shot = battle.dramaticShapeShot
  battle.dramaticShapeDark = nil
  if not shot then return end
  if isIOS() then
    -- iOS HUDs are transparent: the snapped path (snapHUDs) blits the
    -- player/opponent glyphs straight onto the diorama with no backplate
    -- (matching upstream PR #119), so there is nothing to lay down here. The
    -- text box / action-select / move-list / type / yes-no / move-learn boxes
    -- remain opaque white because they are the engine's own Font.drawBox, which
    -- drawTextArea preserves on iOS. This in-frame branch is only the fallback
    -- when the snapped composite could not be made.
    return
  end
  if snapped() then
    battle.dramaticShapeDark = true
    return
  end
  local slide = (battle.introSlide or 0) * 4
  local enemy, player = OverworldBattle.hudLive(battle, slide)
  local rect = OverworldBattle.HUD_RECT
  local live = {}
  if enemy then live.enemy = rect.enemy end
  if player then live.player = rect.player end
  for key, r in pairs(OverworldBattle.textRects(battle)) do live[key] = r end
  if not next(live) then return end
  battle.dramaticShapeDark = true
  for key, r in pairs(live) do
    BattleHud.panel(r, shot, true)
  end
end

return OverworldBattle
