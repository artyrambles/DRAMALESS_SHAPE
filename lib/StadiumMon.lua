-- STADIUM battles: one Pokemon, standing on its tile.
--
-- The side's live state -- which species is out, the rig posing it, which
-- animation the fight has asked for and how far through it is, and the
-- matrix that puts it on its cell at the right size facing the right way.
-- Stadium owns the pair of these; StadiumRig owns the arithmetic.
--
-- ------- how big a Pokemon is
--
-- The one genuinely invented number in this mode, and it is worth saying
-- why it is invented rather than measured.
--
-- The flat 2D-3D mode has an exact answer: a full-size 56-pixel pic covers
-- one 16-pixel overworld square, so a canvas pixel is a fixed number of
-- world pixels and every species comes out at whatever its own artwork's
-- size implies (see BattleBillboard.FULL_W). The camera is then SOLVED to
-- make one square that big on screen (BattleCam).
--
-- The Stadium models have no such anchor. Their units are the N64's, they
-- run from Caterpie at 9 units to Gyarados at 147 -- a sixteenfold spread,
-- where the Gen 1 pics span barely one and a half -- and the game they come
-- from framed each one with its own camera, which a fight staged on the
-- overworld cannot do because the two mons share a shot.
--
-- Taken literally, that spread puts Caterpie at a couple of pixels on a
-- 144-pixel screen while Gyarados leaves the frame. So the range is
-- COMPRESSED rather than either honoured or discarded: a species is drawn
-- at REF_HEIGHT world pixels scaled by its own height over the set's
-- median, raised to SQUASH. At 1 that would be the raw sixteenfold spread;
-- at 0 every Pokemon would be the same size; at 0.55 the order and the
-- feel of the differences survive -- Onix and Gyarados tower, Diglett and
-- Caterpie are small enough to have to look for -- inside a range a shared
-- frame can hold.
--
-- ------- and where its feet are
--
-- The pack measures each model's lowest point against its own origin
-- (tools/stadium_pack.py's `stance`), and the answer splits the set in
-- three. 119 species sit within 5% of zero: the origin IS the floor, and
-- the game stood them on its field with it. A handful sit ABOVE it --
-- Zubat, Magnemite, Geodude -- which is a hover the model is authored with.
-- The rest hang BELOW it -- Tentacruel, Gastly, Haunter, Weezing, Zapdos --
-- which is a model centred on its origin rather than standing on it.
--
-- So a model is stood on its own lowest point, and then given back as much
-- of its authored hover as the shot can hold -- HOVER_CAP of its own height,
-- no more. The middle group is unaffected either way, which is the check
-- that the rule is reading the data rather than correcting it.
--
-- The cap is not tidiness. Stadium framed one Pokemon per camera and could
-- afford to hang Zubat three body-heights off the floor; this shot has the
-- foe's feet on GB row 56 of 144, so the same hover puts Zubat off the top
-- of the frame entirely -- which is exactly what it did before the cap. The
-- flat 2D-3D mode has the same constraint and answers it by bottom-aligning
-- every pic, hovering species included; this keeps the hover but spends
-- only the room there is.

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local Mat4 = V.require("Mat4")
local StadiumPack = V.require("StadiumPack")
local StadiumRig = V.require("StadiumRig")

local StadiumMon = {}
StadiumMon.__index = StadiumMon

-- How tall a median Pokemon stands, in world pixels.
--
-- Not picked by eye: it is what the FLAT mode already puts on those cells.
-- A full-size Gen 1 pic is 56 pixels for the foe and 64 for the player's
-- own, drawn with its feet on GB rows 56 and 96 of a 144-row frame -- so a
-- full-size mon covers 39% of the frame at the far cell and 44% at the near
-- one. Against the lens BattleCam solves (about 38 world pixels of frame at
-- the far cell, 30 at the near one, because the near one is closer) both of
-- those work out at roughly fourteen world pixels.
--
-- So this is the number that makes a median Stadium model exactly as big as
-- the artwork it replaces, which is what keeps the composition the camera
-- was solved for.
StadiumMon.REF_HEIGHT = 14 * 1.3

-- The set's own median bind height, in game units (tools/stadium_pack.py
-- --report prints it). Only ever a reference point for the ratio above, so
-- a re-extraction that moved it slightly changes nothing but the middle of
-- the ladder.
StadiumMon.MEDIAN = 52.25 * 1.3

-- How much of the raw size spread survives. See the header.
StadiumMon.SQUASH = 0.5

-- And hard stops either end, because a compression is not a guarantee. The
-- ceiling is what keeps Onix and Gyarados inside a frame whose top edge is
-- only 56 GB rows above the foe's own feet: past about this they stop being
-- imposing and start being cropped.
StadiumMon.MIN_HEIGHT = 5 * 1.3
StadiumMon.MAX_HEIGHT = 18 * 1.3

-- How much of an authored hover survives, as a fraction of the Pokemon's
-- own height. See the header: Stadium could hang a flier three body-heights
-- up because it framed one Pokemon at a time.
StadiumMon.HOVER_CAP = 0.5

-- The animation clock. Every animation in the set is authored at 30 fps
-- (model_extract/README.md), and the eyes run on their own counter at the
-- same rate.
StadiumMon.FPS = StadiumPack.FPS

-- ------- coming out of the ball
--
-- The engine grows its flat pic in the Game Boy's own three steps -- 0, then
-- 3/7, then 5/7, then full -- across the twelve frames after the ball opens
-- (BattleState.growInScale). Two things about that do not carry to a model.
--
-- It is three steps, which on a 56-pixel sprite is a chunky pop and on a
-- smooth 3D model is just a pop. And it starts AFTER the ball: measured, the
-- poof animation runs for 27 frames and `startGrowIn` fires on the frame
-- after it ends, so the Pokemon does not begin to exist until the ball has
-- finished opening -- which reads as the ball opening and then a Pokemon
-- being switched on beside it.
--
-- So the model runs its own ramp, started when the POOF begins rather than
-- when it ends, and continuous rather than stepped: it grows out of nothing
-- while the ball is opening and reaches full size as the engine's own grow
-- finishes. GROW_TIME is measured off that -- 27 frames of poof plus the
-- engine's 12 of grow is 39, which is this.
StadiumMon.GROW_TIME = 0.65

-- How far an animation may carry the Pokemon off its tile, in the Pokemon's
-- own body-heights, before the excess is taken back out (StadiumRig.anchor).
--
-- Measured against the frame rather than chosen by eye. A mon is drawn
-- REF_HEIGHT world pixels tall and the GB frame holds about 38 world pixels
-- at the far cell, with the foe's feet on row 56 of 144 -- so there is
-- roughly one body-height of room above it and about one and a half either
-- side. Three quarters of a height keeps every part of a travelling Pokemon
-- inside that with a margin, and leaves the 83 species that never reach it
-- untouched.
StadiumMon.TRAVEL = 0.75

-- ------- the animation the fight is asking for
--
-- Each entry says which context slot to look up, whether it loops, and
-- what it falls back to when the species has no animation in that slot.
-- ------- the defender reaction
--
-- This used to carry `hit` and `flinch` states, played when damage landed,
-- resolving through context slots 166 and 178. Both were wrong, and the data
-- says so plainly once the move table is read alongside them:
--
--   Bulbasaur's slot 166 is a 95-frame animation that 66 of its moves play.
--   Pidgey's is 138 frames -- four and a half seconds -- and 111 of its moves
--   play it. Slot 178, and 173, 179, 180 and 181, all point at the same one.
--
-- A four-and-a-half-second animation that most of the move table uses is the
-- species' DEFAULT ATTACK, not a flinch, which is why being hit looked like
-- swinging: it literally was the swing.
--
-- Stadium's defender-impact handler instead requests context slot 168 for
-- ordinary and super-effective damage. That slot is also used for entrance:
-- Stadium deliberately reuses the same species-specific recovery motion in
-- both contexts. Resisted damage selects idle and is filtered by Stadium.hit
-- before it reaches this state machine.
local STATES = {
  idle = { slot = "idle", loop = true },
  entrance = { slot = "entrance", loop = false, next = "idle" },
  hit = { slot = "entrance", loop = false, next = "idle" },
  faint = { slot = "faint", loop = false, hold = true },
  -- A move names its own animation out of the move table. `attack_default`
  -- is the fallback for one the table has nothing for -- which is what slot
  -- 166 actually is, so the generic swing is now a real swing rather than
  -- the standby loop it used to resolve to.
  attack = { slot = "attack_default", loop = false, next = "idle" },
}

function StadiumMon.new(side)
  return setmetatable({
    side = side,               -- "player" or "enemy"
    species = nil,             -- the dex number currently modelled
    model = nil,
    rig = nil,
    state = "idle",
    anim = nil,                -- index into model.anims
    time = 0,                  -- seconds into it
    loop = true,
    hold = false,
    aux = nil,                 -- the texture animation running alongside
    visible = false,
    scale = 1,                 -- the send-out grow, 1 the rest of the time
  }, StadiumMon)
end

function StadiumMon:release()
  if self.rig then self.rig:release() end
  self.rig, self.model, self.species = nil, nil, nil
end

-- ------- which species this side is showing
--
-- Returns true when the model is ready to draw. A species with no pack, one
-- whose meshes would not build, or one whose animation data is corrupt at
-- source answers false -- and Stadium then leaves that side to the flat
-- card, which is a per-POKEMON decline rather than a per-battle one: a fight
-- can perfectly well have a model on one side and a pic on the other.
--
-- ------- staticPose: the corrupt-idle escape hatch
--
-- StadiumBuild.idleIsBroken measures whether a species' standby loop throws
-- bones off the body, and the pack carries the verdict as `staticPose`. A
-- species so marked DECLINES here -- the Game Boy's own battle sprite
-- stands on the tile instead, drawn by the same 2D-3D path every species
-- uses when its model is unavailable -- because a bind pose held for a
-- whole fight reads as broken, not as "this one does not animate".
--
-- No species is marked today. Exeggutor, Tangela and Magmar used to be:
-- their animations are hermite keyframes (flags & 8), the extractor misread
-- the flags byte and decoded them as packed streams, and the exploding
-- result tripped the detector (Pidgeot and Dodrio were garbled by the same
-- bug, just not hard enough to trip it). The detector stays, keyed on the
-- DATA rather than a list of dex numbers, so a future extraction bug that
-- corrupts a species' idle falls back to the sprite instead of coming
-- apart on the field -- and nothing here has to be edited when it does.
function StadiumMon:setSpecies(dex)
  if dex == self.species then return self.rig ~= nil end
  if self.rig then self.rig:release() end
  self.rig, self.model, self.species = nil, nil, dex
  self.grow, self.grewOwn = nil, nil
  if not dex then return false end
  local model = StadiumPack.load(dex)
  if not model then return false end
  if model.staticPose then return false end
  local rig = StadiumRig.new(model)
  if not rig then return false end
  self.model, self.rig = model, rig
  -- a new Pokemon on the field opens on its standby loop; whoever sent it
  -- out asks for the entrance a moment later
  self.state, self.anim, self.time = nil, nil, 0
  self:play("idle")
  return true
end

-- ------- the state machine

-- Which animation a context slot resolves to for this species, or nil.
function StadiumMon:slotAnim(name)
  local model = self.model
  local slot = model and StadiumPack.SLOT[name]
  if not slot then return nil end
  local index = model.ctx[slot]
  if not index or index == StadiumPack.NONE then return nil end
  return index + 1
end

-- Start a state. `animIndex` overrides the state's own slot lookup, which
-- is what an attack uses.
function StadiumMon:play(state, animIndex, auxIndex)
  local model = self.model
  if not model then return false end
  local def = STATES[state] or STATES.idle
  local index = animIndex
  if not index and def.slot then index = self:slotAnim(def.slot) end
  if not index and def.fallback then index = self:slotAnim(def.fallback) end
  if not index then
    -- the species has nothing for this; the standby loop is always there
    if state == "idle" then index = 1 else return self:play("idle") end
  end
  local anim = model.anims[index]
  if not anim then return false end

  self.state, self.anim, self.time = state, index, 0
  self.done = false
  -- (a species whose animations are corrupt at source never gets this far:
  -- setSpecies declines it outright and its flat pic stands instead)
  self.loop = def.loop and true or false
  self.hold = def.hold and true or false
  -- The eyes that go with it. Every skeletal animation carries the texture
  -- animation the battle table most often set alongside it (the pack's own
  -- `aux`), and a move may name a different one -- a hit that leaves the
  -- Pokemon confused swaps the open eye for the dizzy swirl.
  self.aux = auxIndex or anim.aux
  return true
end

-- Ask for a state, but never interrupt one that outranks it. A faint is
-- final, and an entrance cannot be cut short by the standby loop it hands
-- on to.
local RANK = { idle = 0, entrance = 1, attack = 2, hit = 2, faint = 3 }

function StadiumMon:request(state, animIndex, auxIndex)
  if not self.model then return false end
  local now = RANK[self.state] or 0
  local want = RANK[state] or 0
  if self.state == "faint" then return false end
  -- an equal-ranked request RESTARTS: the second move of a two-hit turn
  -- should swing again rather than be swallowed by the first
  if want < now then return false end
  return self:play(state, animIndex, auxIndex)
end

-- The animation a move plays for this species, from the battle system's own
-- per-species table (model_extract's moves.json, packed into the .dsm).
-- `moveIndex` is the Gen 1 move id, which the engine's move defs carry as
-- `index` -- the same numbering, so no name mapping is needed.
function StadiumMon:attack(moveIndex)
  local model = self.model
  if not (model and moveIndex and moveIndex >= 1
          and moveIndex <= StadiumPack.N_MOVES) then
    return false
  end
  local index = model.moveAnim[moveIndex]
  if not index or index == StadiumPack.NONE then return false end
  local aux = model.moveAux[moveIndex]
  return self:request("attack", index + 1,
                      (aux and aux >= 0) and (aux + 1) or nil)
end

-- ------- per frame

function StadiumMon:update(dt)
  -- kept for build(), which runs later in the same frame and needs it to
  -- advance the anchor's filter (StadiumRig.anchor). Stashed before the
  -- early-outs below, so a species with nothing to play still has one.
  self.dt = dt or 0
  -- the ball-to-full-size ramp, which runs whether or not there is an
  -- animation to play alongside it
  if self.grow then
    self.grow = self.grow + (dt or 0) / StadiumMon.GROW_TIME
    if self.grow >= 1 then self.grow = nil end
  end
  local model = self.model
  if not (model and self.anim) then return end
  local anim = model.anims[self.anim]
  if not anim then return end
  self.time = self.time + (dt or 0)
  if self.time >= anim.seconds and not self.loop then
    if self.hold then
      -- a faint stays down: hold the last frame rather than snapping back
      -- to a standing pose the moment the animation runs out
      self.time = math.max(0, anim.seconds - 1 / StadiumMon.FPS)
      -- and SAY so, once. The clamp above means the clock can no longer be
      -- asked whether the animation is over -- it stops a frame short of the
      -- end and stays there forever -- and something has to know, because a
      -- collapse that has finished is the moment the Pokemon may leave the
      -- field (see Stadium's onField).
      self.done = true
    else
      local nextState = (STATES[self.state] or {}).next or "idle"
      self:play(nextState)
    end
  end
end

-- ------- the grow
--
-- Begin coming out of the ball. Answers whether it actually started, so the
-- caller can play the entrance alongside it and the engine's own send-out
-- seam a moment later does not restart what is already running.
function StadiumMon:beginGrow()
  if self.grow or not self.model then return false end
  self.grow = 0
  -- and remember that THIS arrival was ours to size, so the engine's own
  -- three-step ramp is not consulted again for it. Ours starts earlier and
  -- finishes a few frames sooner, and in that gap the engine's ramp still
  -- reads 5/7 -- so falling back to it shrank the Pokemon from 0.96 back to
  -- 0.71 and then snapped it to full, a visible hitch at the end of an
  -- animation that exists to not have one.
  self.grewOwn = true
  return true
end

-- How big this Pokemon is drawn this frame, as a fraction of its real size.
--
-- Smoothstep rather than a straight ramp or an ease-out: the ball is opening
-- for the first half of this, so a curve that is already near full size by
-- then would have the Pokemon standing there while the ball is still coming
-- apart. Slow, then quick through the middle, then settling exactly as the
-- engine's own grow ends.
function StadiumMon:growScale()
  local t = self.grow
  if not t then return 1 end
  if t <= 0 then return 0 end
  if t >= 1 then return 1 end
  return t * t * (3 - 2 * t)
end

-- Whether a HELD animation -- which in practice means a faint -- has played
-- all the way through and is now sitting on its last frame. Always false for
-- a looping one, which never finishes, and for one that hands on to another
-- state, which has already stopped being itself by the time anyone can ask.
function StadiumMon:finished()
  return self.done and true or false
end

-- How tall this species stands on the map, in world pixels.
function StadiumMon:worldHeight()
  local model = self.model
  local h = model and model.height or 0
  if not (h > 0) then return StadiumMon.REF_HEIGHT end
  local k = (h / StadiumMon.MEDIAN) ^ StadiumMon.SQUASH
  local out = StadiumMon.REF_HEIGHT * k
  if out < StadiumMon.MIN_HEIGHT then out = StadiumMon.MIN_HEIGHT end
  if out > StadiumMon.MAX_HEIGHT then out = StadiumMon.MAX_HEIGHT end
  return out
end

-- How wide this Pokemon stands, in world pixels -- the same scale
-- worldHeight is in, so a caller can size something to its footprint.
--
-- Only STADIUM B asks: it needs to know how big a platform to put under a
-- mon, and "as tall as it is" is the wrong answer for a Snorlax, which is
-- half as tall as an Onix and three times as wide.
--
-- The send-out grow is deliberately NOT folded in. A Pokemon scaling up out
-- of its ball should arrive on a platform that was already there, not one
-- that inflates under its feet.
function StadiumMon:worldRadius()
  local model = self.model
  if not model then return 0 end
  local h = model.height or 0
  if not (h > 0) then return 0 end
  return (model.radius or 0) * self:worldHeight() / h
end

-- The model matrix: stand this Pokemon on world (x, groundY, z) facing
-- (faceX, faceZ), at whatever the send-out grow has done to its size.
--
-- The vertices the rig writes are in the model's RAW units -- before the
-- model_root scale the game applies -- so the scale here carries that too,
-- and the floor offset is measured in the same raw units on the way in.
function StadiumMon:matrix(x, groundY, z, faceX, faceZ)
  local model = self.model
  if not model then return nil end
  local root = model.rootScale
  if not (root and root > 0) then root = 1 end
  local k = root * self:worldHeight() / math.max(model.height, 1e-6)
  k = k * (self.scale or 1)
  -- stand it on its own lowest point, then give back as much of the
  -- authored hover as the shot can hold (see the header)
  local floor = model.floor or 0
  local hover = math.min(math.max(floor, 0),
                         StadiumMon.HOVER_CAP * math.max(model.height, 0))
  local lift = (floor - hover) / root
  local yaw = 0
  if faceX and faceZ and (faceX ~= 0 or faceZ ~= 0) then
    -- the card and the model share this convention: an unrotated model
    -- faces +Z, which is map SOUTH, which is what "facing down" is in the
    -- flat game (see Voxel3D's axis note)
    yaw = math.atan2(faceX, faceZ)
  end
  self.yaw = yaw
  return Mat4.mul(
    Mat4.mul(Mat4.mul(Mat4.translate(x, groundY, z), Mat4.rotateY(yaw)),
             Mat4.scale(k, k, k)),
    Mat4.translate(0, -lift, 0))
end

-- Pose and skin for this frame. Separate from the draw because both the
-- SUN and the camera -- and, in a headset, both eyes -- want the same
-- skinned mesh, and skinning it once is the whole reason this is worth
-- doing on the CPU.
function StadiumMon:build()
  if not (self.rig and self.model) then return false end
  -- self.anim is nil while a species has nothing to play, and pose() reads
  -- that as "the bind pose", which is exactly what is wanted
  self.rig:pose(self.anim, self.time * StadiumMon.FPS, self.loop)
  -- and then back onto the tile, because these animations were authored for
  -- a camera that followed the Pokemon and this one does not move (see
  -- StadiumRig.anchor)
  self.rig:anchor(StadiumMon.TRAVEL, self.dt)
  self.rig:skin(self.yaw or 0)
  -- no clock of its own: the texture animation rides the frame pose() just
  -- resolved, which is what keeps a blink inside its standby loop and a
  -- fainted Pokemon's eyes shut once it has stopped moving
  self.rig:textures(self.aux)
  return true
end

return StadiumMon
