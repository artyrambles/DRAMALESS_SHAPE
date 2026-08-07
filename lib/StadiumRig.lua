-- STADIUM battles: posing a skeleton and skinning it, on the CPU.
--
-- One instance of this is one Pokemon standing on the map -- the meshes it
-- draws through and the scratch space its pose is computed in. The MODEL
-- (geometry, bones, animations, textures) is shared and read-only; this is
-- everything about it that is per-Pokemon and changes every frame.
--
-- ------- why the CPU
--
-- Because these models are tiny and the mod's shader already exists. A
-- battle model is 674 vertices on average and 1311 at the worst, of which
-- exactly two are on screen at a time -- so skinning them by hand costs
-- about two thousand vertex transforms a frame, which is less than the
-- grass pass does on an empty route. What it buys is that the finished
-- vertices go into Voxel3D's OWN vertex format, through Voxel3D's OWN
-- shader, and therefore get every single thing the rest of the diorama
-- gets for free: the depth buffer decides what is in front of what, the
-- sun pass throws a real shadow of the actual pose, the hour's tint lands
-- on it, the hit flash flattens it, and the tilt-shift and the
-- depth-of-field see it as part of the picture. A GPU skinning path would
-- have needed a second shader that then had to re-implement all of that,
-- and a second shadow shader beside it.
--
-- It is also what makes the FORMAT work. Every vertex in the Stadium set is
-- rigidly bound to ONE bone with weight 1 (model_extract/README.md), so
-- skinning is a single matrix multiply per vertex with no blend -- and the
-- per-vertex `shade` Voxel3D wants, which no glTF has, is computed here
-- from the bone-local normal.
--
-- ------- the two matrix chains
--
-- The game keeps bone scale OUT of the matrix chain (func_800143C0): scale
-- accumulates in its own stack, a bone's local translation is
-- pre-multiplied by its parent's accumulated scale, and a bone's own
-- accumulated scale is applied to the finished matrix only at draw time.
-- glTF cannot express that -- its node scale propagates to children -- and
-- the reference export works around it by splitting every bone into two
-- nodes.
--
-- Here it falls out naturally, as two arrays:
--
--   pivot   rotation and translation only. This is what a CHILD inherits,
--           and it is a pure rotation, which is also why the normals are
--           transformed with it rather than with the draw matrix.
--   draw    the same matrix with the bone's accumulated scale applied on
--           the right, which is the one vertices go through.
--
-- Folding the scale into the chain instead is the obvious mistake and it
-- applies every ancestor's scale once per generation. It is caught by the
-- suite: tools/stadium_pack.py measures the bind pose with this exact walk
-- and its answer matches the verified glTF export on all 151 species.

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local Voxel3D = V.require("Voxel3D")
local StadiumPack = V.require("StadiumPack")

local StadiumRig = {}
StadiumRig.__index = StadiumRig

local sin, cos, floor = math.sin, math.cos, math.floor

-- binary angle (32768 = pi) to radians
local ANG = math.pi / 32768

-- ------- how a surface is lit
--
-- Voxel3D shades a face by its DIRECTION rather than by a light uniform:
-- every terrain and character mesh in this mode carries a per-vertex
-- `shade` baked from which way its face points, and the shadow map
-- multiplies on top of that (see Voxel3D.FACE_SHADE). A skinned model has
-- no fixed faces to bake, so the same answer is computed per vertex from
-- the posed normal -- and these four numbers are FACE_SHADE's own six
-- values, fitted:
--
--     +Y up 1.00   -Y down 0.55   +X east 0.84   -X west 0.72
--     +Z south 0.90   -Z north 0.68
--
-- so a Pokemon's flank catches the same southeastern sun the roof of the
-- house behind it does, and the two read as being in one picture.
local SHADE_BASE = 0.7725
local SHADE_X = 0.06
local SHADE_Y = 0.225
local SHADE_Z = 0.11

-- ------- an instance

-- `model` is a StadiumPack model. Returns nil where meshes cannot be made,
-- which is the same "no 3D" answer every other GPU object in this mod gives.
function StadiumRig.new(model)
  if not (model and model.prims) then return nil end
  if not (love.graphics and love.graphics.newMesh) then return nil end

  local self = setmetatable({
    model = model,
    -- The two chains, flat: twelve numbers a bone, row-major 3x4.
    --
    -- Named with the M rather than `pivot` and `draw` because an instance
    -- field called `draw` shadows the DRAW METHOD through __index, and the
    -- failure that causes is a nasty one: the shadow pass calls caster()
    -- and keeps working, so a Pokemon casts a perfect animated shadow onto
    -- ground it is not standing on.
    pivotM = {},
    drawM = {},
    -- the accumulated scale, which is the third thing the game's own walk
    -- carries and neither matrix can hold
    accX = {}, accY = {}, accZ = {},
    parts = {},
    -- what the pose walk last answered, so a frame that neither moved the
    -- animation nor turned the model can skip the whole thing
    poseKey = nil,
    -- scratch for the body-centre estimate (see anchor), kept on the rig so
    -- a per-frame measurement allocates nothing
    cx = {}, cy = {}, cz = {},
  }, StadiumRig)

  -- One mesh per primitive: a primitive is already "the triangles sharing
  -- one texture", which is exactly one draw call's worth.
  --
  -- "dynamic" rather than "static": every vertex is rewritten every frame
  -- the pose changes, which is what the usage hint exists to say.
  for i, prim in ipairs(model.prims) do
    local rows = {}
    local uv = prim.uv
    for k = 1, prim.vertCount do
      -- position and shade are filled by skin(); the texture coordinates
      -- never change, so they are written once here
      rows[k] = { 0, 0, 0, uv[k * 2 - 1], uv[k * 2], 1 }
    end
    local ok, mesh = pcall(love.graphics.newMesh, Voxel3D.FORMAT, rows,
                           "triangles", "dynamic")
    if not ok then return nil end
    pcall(mesh.setVertexMap, mesh, prim.index)
    self.parts[i] = { mesh = mesh, rows = rows, prim = prim }
  end
  -- the spot the animations are measured against, taken while there is no
  -- pose to overwrite (see measureBind)
  pcall(self.measureBind, self)
  return self
end

function StadiumRig:release()
  for _, part in ipairs(self.parts or {}) do
    if part.mesh and part.mesh.release then
      pcall(part.mesh.release, part.mesh)
    end
  end
  self.parts = {}
end

-- ------- sampling one track
--
-- `c` is the pack's own fold: a bare number when the component holds still
-- for the whole animation, or one value a frame when it does not. Two frame
-- indices and a blend come in because the caller has already resolved what
-- "between frame 12 and 13, three tenths of the way" means for THIS
-- animation's looping.

-- One component at one frame.
local function sampleAt(c, i)
  if type(c) == "number" then return c end
  return c[i]
end

-- ------- interpolation, and the one place it must not happen
--
-- These streams are not keyframes: they carry ONE VALUE PER FRAME at 30 Hz,
-- and the game steps them a frame at a time. So at 60 Hz the honest replay
-- is each pose held for two frames -- which is exactly what it looks like,
-- a set of models moving at half the frame rate of everything around them.
-- Blending between consecutive entries is therefore not reconstructing
-- something the source had; it is INVENTING the halfway pose. It is worth
-- inventing, because a 30 Hz step against a 60 Hz camera reads as a stutter
-- and the halfway pose is right far more often than it is wrong.
--
-- Where it IS wrong is the reason a naive version of this shipped once and
-- had to be taken out: bones snapping to an upside-down pose for a frame,
-- arms turning inside out for a few. Rotations here are EULER TRIPLES, and
-- a Euler triple is not a direction you can walk along. Two triples can
-- describe nearly the same orientation and be nowhere near each other
-- component by component -- (0, 20976, 32736) and (0, -19936, -5904) are a
-- real pair out of the set -- so walking from one to the other passes
-- through orientations that are nothing like either end. That is precisely
-- a bone flipping over and back inside one frame.
--
-- Shortest-arc wrapping (below) fixes the easy half of that, where a
-- component crosses the +-pi seam. It cannot fix the hard half, where the
-- source simply RE-EXPRESSES a rotation. So the hard half is not fixed, it
-- is DETECTED: a bone whose rotation moves more than BREAK_ANGLE in a
-- single frame is not being animated, it is being re-expressed or snapped,
-- and that bone holds its frame instead of blending. Per bone and all three
-- components together, because the three are one rotation and blending two
-- of them while holding the third is its own wrong answer.
--
-- The same guard, in the same spirit, for TRANSLATION: BREAK_MOVE of the
-- model's own height inside one frame is a teleport rather than a stride.
-- Scale needs none -- a linear blend of two scales lies between them, and
-- there is no way for that to be a pose neither end had.

-- 32768 binary-angle units is pi, so this is a quarter turn in one 30 Hz
-- frame -- 2700 degrees a second. Nothing in the set genuinely moves that
-- fast; everything that reads as moving that fast is a re-expression.
local BREAK_ANGLE = 16384

-- and half the Pokemon's own height in one frame, which is fifteen body
-- heights a second
local BREAK_MOVE = 0.5

-- The signed distance from `c[i0]` to `c[i1]` the SHORT way round, for a
-- binary angle. Interpolating 32700 toward -32700 the long way spins the
-- bone most of a full turn inside one frame; the short way is 136 units,
-- which is what actually happened.
local function angleDelta(c, i0, i1)
  if type(c) == "number" then return 0 end
  local d = c[i1] - c[i0]
  if d > 32768 then d = d - 65536 elseif d < -32768 then d = d + 65536 end
  return d
end

local function linearDelta(c, i0, i1)
  if type(c) == "number" then return 0 end
  return c[i1] - c[i0]
end

-- ------- the pose
--
-- `anim` is an index into model.anims (or nil for the bind pose), `frame` a
-- FLOAT frame in that animation's own 30 Hz timeline, and `wrap` whether
-- the far end joins back to loopStart (a standby loop) or holds on the last
-- frame (a faint).
function StadiumRig:pose(anim, frame, wrap)
  local model = self.model
  local n = model.boneCount
  local tracks = anim and StadiumPack.tracks(model, anim) or nil
  local frames = anim and model.anims[anim] and model.anims[anim].frames or 1

  -- The two frames this instant falls between, and how far. `k` is 0 on
  -- every whole frame, so a caller that steps in whole frames -- the test
  -- suite, the blink probe -- sees exactly the frame it asked for.
  local i0, i1, k = 1, 1, 0
  if tracks and frames > 1 then
    local f = frame
    if f < 0 then f = 0 end
    local base = floor(f)
    k = f - base
    local loop = model.anims[anim].loopStart or 0
    if not (loop > 0 and loop < frames) then loop = 0 end
    if base >= frames then
      if wrap then
        -- the far end joins back to loopStart, which is where the game's own
        -- player sends the counter (func_80016FBC)
        base = loop + (base - loop) % (frames - loop)
      else
        base = frames - 1                   -- a faint holds where it fell
        k = 0
      end
    end
    i0 = base + 1
    if i0 > frames then i0 = frames end
    if i0 < 1 then i0 = 1 end
    -- and the frame after it, which past the end of a loop is loopStart --
    -- the same seam the counter itself crosses. An animation that HOLDS
    -- (a faint) has nothing after its last frame, so it blends with itself.
    if i0 < frames then
      i1 = i0 + 1
    elseif wrap then
      i1 = loop + 1
    else
      i1, k = i0, 0
    end
  end

  -- The frame this animation is actually SHOWING, after the wrap or the
  -- hold, 0-based -- the WHOLE frame, never the blend. A texture swap has no
  -- halfway: an eye is open or it is shut, and a pupil interpolated toward a
  -- swirl is not a thing the hardware could draw. So the skeleton runs at 60
  -- and the textures step at 30, which is what the game does with both.
  -- Stashed rather than recomputed because the texture
  -- animation is sampled at the very same frame (see textures) -- in the
  -- game one counter drives both, and 73% of the paired animations in the
  -- set are the same length as each other, which is what that looks like
  -- from the outside. Two copies of this arithmetic would be two things to
  -- keep in step; one number cannot drift from itself.
  self.frameAt = i0 - 1

  local parent = model.parent
  local restT, restR, restS = model.restT, model.restR, model.restS
  local pivot, drw = self.pivotM, self.drawM
  local accX, accY, accZ = self.accX, self.accY, self.accZ

  -- how far a bone may travel in one frame before it is read as a teleport
  -- rather than a stride. In the vertices' own RAW units, which is what the
  -- tracks are in: model.height is measured after the model_root scale.
  local moveBreak = nil
  if k > 0 then
    local root = model.rootScale
    if not (root and root > 0) then root = 1 end
    local h = (model.height or 0) / root
    if h > 0 then moveBreak = h * BREAK_MOVE end
  end

  for b = 1, n do
    local o3 = (b - 1) * 3
    local tx, ty, tz, rx, ry, rz, kx, ky, kz
    local comps = tracks and tracks[b]
    if comps then
      tx = sampleAt(comps[1], i0)
      ty = sampleAt(comps[2], i0)
      tz = sampleAt(comps[3], i0)
      rx = sampleAt(comps[4], i0)
      ry = sampleAt(comps[5], i0)
      rz = sampleAt(comps[6], i0)
      kx = sampleAt(comps[7], i0)
      ky = sampleAt(comps[8], i0)
      kz = sampleAt(comps[9], i0)
      if k > 0 then
        -- ROTATION, all three at once: a bone that snaps holds its frame,
        -- and a bone that moves holds none of it (see BREAK_ANGLE)
        local dx = angleDelta(comps[4], i0, i1)
        local dy = angleDelta(comps[5], i0, i1)
        local dz = angleDelta(comps[6], i0, i1)
        if dx < 0 then dx = -dx end
        if dy < 0 then dy = -dy end
        if dz < 0 then dz = -dz end
        if dx <= BREAK_ANGLE and dy <= BREAK_ANGLE and dz <= BREAK_ANGLE then
          rx = rx + angleDelta(comps[4], i0, i1) * k
          ry = ry + angleDelta(comps[5], i0, i1) * k
          rz = rz + angleDelta(comps[6], i0, i1) * k
        end
        -- TRANSLATION, likewise together: the three are one offset
        local mx = linearDelta(comps[1], i0, i1)
        local my = linearDelta(comps[2], i0, i1)
        local mz = linearDelta(comps[3], i0, i1)
        local far = false
        if moveBreak then
          far = (mx > moveBreak or mx < -moveBreak)
                or (my > moveBreak or my < -moveBreak)
                or (mz > moveBreak or mz < -moveBreak)
        end
        if not far then
          tx, ty, tz = tx + mx * k, ty + my * k, tz + mz * k
        end
        -- SCALE, which cannot land anywhere the two ends did not bracket
        kx = kx + linearDelta(comps[7], i0, i1) * k
        ky = ky + linearDelta(comps[8], i0, i1) * k
        kz = kz + linearDelta(comps[9], i0, i1) * k
      end
    else
      -- a bone this animation never touches keeps its rest transform
      tx, ty, tz = restT[o3 + 1], restT[o3 + 2], restT[o3 + 3]
      rx, ry, rz = restR[o3 + 1], restR[o3 + 2], restR[o3 + 3]
      kx, ky, kz = restS[o3 + 1], restS[o3 + 2], restS[o3 + 3]
    end

    local p = parent[b]
    local pax, pay, paz = 1, 1, 1
    if p > 0 then pax, pay, paz = accX[p], accY[p], accZ[p] end
    -- the parent's accumulated scale, applied to the CHILD's offset. This
    -- is the whole of what the game does instead of propagating scale.
    tx, ty, tz = tx * pax, ty * pay, tz * paz

    -- Rx * Ry * Rz in the game's own row-vector form (src/F420.c
    -- func_8000F730), written out as the rows of a 3x3
    local ax, ay, az = rx * ANG, ry * ANG, rz * ANG
    local sx, cx = sin(ax), cos(ax)
    local sy, cy = sin(ay), cos(ay)
    local sz, cz = sin(az), cos(az)
    local m11, m12, m13 = cy * cz, sx * sy * cz - cx * sz, cx * sy * cz + sx * sz
    local m21, m22, m23 = cy * sz, sx * sy * sz + cx * cz, cx * sy * sz - sx * cz
    local m31, m32, m33 = -sy, sx * cy, cx * cy

    local o = (b - 1) * 12
    if p > 0 then
      local q = (p - 1) * 12
      local a1, a2, a3, a4 = pivot[q + 1], pivot[q + 2], pivot[q + 3], pivot[q + 4]
      local b1, b2, b3, b4 = pivot[q + 5], pivot[q + 6], pivot[q + 7], pivot[q + 8]
      local c1, c2, c3, c4 = pivot[q + 9], pivot[q + 10], pivot[q + 11], pivot[q + 12]
      pivot[o + 1] = a1 * m11 + a2 * m21 + a3 * m31
      pivot[o + 2] = a1 * m12 + a2 * m22 + a3 * m32
      pivot[o + 3] = a1 * m13 + a2 * m23 + a3 * m33
      pivot[o + 4] = a1 * tx + a2 * ty + a3 * tz + a4
      pivot[o + 5] = b1 * m11 + b2 * m21 + b3 * m31
      pivot[o + 6] = b1 * m12 + b2 * m22 + b3 * m32
      pivot[o + 7] = b1 * m13 + b2 * m23 + b3 * m33
      pivot[o + 8] = b1 * tx + b2 * ty + b3 * tz + b4
      pivot[o + 9] = c1 * m11 + c2 * m21 + c3 * m31
      pivot[o + 10] = c1 * m12 + c2 * m22 + c3 * m32
      pivot[o + 11] = c1 * m13 + c2 * m23 + c3 * m33
      pivot[o + 12] = c1 * tx + c2 * ty + c3 * tz + c4
    else
      pivot[o + 1], pivot[o + 2], pivot[o + 3], pivot[o + 4] = m11, m12, m13, tx
      pivot[o + 5], pivot[o + 6], pivot[o + 7], pivot[o + 8] = m21, m22, m23, ty
      pivot[o + 9], pivot[o + 10], pivot[o + 11], pivot[o + 12] = m31, m32, m33, tz
    end

    local ex, ey, ez = pax * kx, pay * ky, paz * kz
    accX[b], accY[b], accZ[b] = ex, ey, ez
    -- the bone's own accumulated scale, on the right: it scales the axes of
    -- THIS bone's space and cannot reach the children, which is exactly the
    -- game's draw-time application
    drw[o + 1], drw[o + 2] = pivot[o + 1] * ex, pivot[o + 2] * ey
    drw[o + 3], drw[o + 4] = pivot[o + 3] * ez, pivot[o + 4]
    drw[o + 5], drw[o + 6] = pivot[o + 5] * ex, pivot[o + 6] * ey
    drw[o + 7], drw[o + 8] = pivot[o + 7] * ez, pivot[o + 8]
    drw[o + 9], drw[o + 10] = pivot[o + 9] * ex, pivot[o + 10] * ey
    drw[o + 11], drw[o + 12] = pivot[o + 11] * ez, pivot[o + 12]
  end
end

-- ------- keeping the Pokemon on its own tile
--
-- Stadium's animations MOVE the Pokemon, and they move it a long way. Half
-- the set's send-out entrances walk the body more than its own height off
-- the spot it started on; Dewgong's faint travels nearly ten body-heights,
-- and its entrance seven and a half. Every one of them ends exactly where it
-- began, because that game framed each Pokemon with a camera of its OWN that
-- followed the performance around a stage.
--
-- This mode has one camera, solved to put two named map cells at two fixed
-- points in a 160x144 frame (BattleCam), and a Pokemon that travels seven
-- body-heights out of that frame is simply GONE -- which is what sending out
-- a Farfetch'd looked like: an empty tile for three and a half seconds,
-- while its animation played somewhere off to the left of the shot.
--
-- So the bulk travel is taken back out. The pose is measured, and whatever
-- has carried the body further than `limit` from where the bind pose put it
-- is subtracted from every bone.
--
-- ------- why a LIMIT and not an anchor
--
-- Pinning the body outright would flatten the animations into mime: a lunge,
-- a hop, a recoil and a collapse are all the body moving, and they are the
-- part worth having. What breaks the shot is not motion, it is EXCURSION --
-- and the two are told apart by how far. Inside the limit nothing is touched
-- at all, so the 83 species whose animations stay put are bit-for-bit what
-- they were; past it the excess alone is removed, so a big move still reads
-- as big and still comes back to the tile it left.
--
-- ------- where the body IS, and why it is not the median
--
-- The first version of this took the median bone origin, on the reasoning
-- that a handful of bones flung anywhere cannot move a median. True, and it
-- had a worse problem: a median is a RANK, and a rank flips. On a bird most
-- of the skeleton is wing, so as the wings beat, which bone sits at the
-- middle of the sorted list swaps between the up cluster and the down one --
-- and the estimate jumps with it. Measured on Pidgey's standby loop the
-- median moved a tenth of a body-height between adjacent half-frames, and on
-- Pidgeot three whole body-heights. The anchor turns that straight into a
-- translation of the ENTIRE Pokemon, so the body counter-shook against its
-- own wings and the flapping read as twice its real speed. That is the
-- "Pidgey's wings flap super fast" this comment exists because of.
--
-- The centre is now the bone origins averaged, WEIGHTED BY HOW MANY VERTICES
-- EACH BONE MOVES. That fixes both halves at once:
--
--   * the weights are a property of the MESH, computed once and never
--     changing, so there is no rank to flip and no discontinuity available
--     to it -- the estimate is as smooth as the bones themselves
--   * a bone with little geometry on it barely counts, which is exactly the
--     robustness the median was for. Farfetch'd's trail is thirty vertices
--     on five bones -- 1.6% of the model -- so streaking three thousand
--     units out moves this by nothing worth measuring
--
-- Against the median it is two to five times smoother on every species
-- tested and measures the same travel to within a few percent.

-- How far the body estimate may move in ONE 30 Hz frame of a species' own
-- standby loop before that species is judged unmeasurable and left
-- unanchored (see measureBind). The fastest genuine motion in the set is
-- about a fifth of a body-height a frame; the one species that fails this
-- moves three.
StadiumRig.ANCHOR_STEADY = 0.5

-- Which context slot the standby loop is, without requiring StadiumPack --
-- this module is below it and a require would be circular. Position 1 of
-- StadiumPack.CONTEXT, which is the format's own contract.
local IDLE_SLOT = 1

-- How much of the model each bone actually carries. Cached on the shared
-- model: it is a fact about the mesh, not about this instance.
local function boneWeights(model)
  if model.boneW then return model.boneW, model.boneWTotal end
  local w, total = {}, 0
  for b = 1, model.boneCount do w[b] = 0 end
  for _, prim in ipairs(model.prims) do
    local bone = prim.bone
    for k = 1, prim.vertCount do
      local b = bone[k]
      if w[b] then w[b] = w[b] + 1; total = total + 1 end
    end
  end
  model.boneW, model.boneWTotal = w, total
  return w, total
end

-- The body centre of the pose currently in drawM.
local function centre(self, n)
  local model = self.model
  local w, total = boneWeights(model)
  if not (total > 0) then return nil end
  local x, y, z = 0, 0, 0
  local d = self.drawM
  for b = 1, n do
    local q = w[b]
    if q and q > 0 then
      local o = (b - 1) * 12
      x = x + d[o + 4] * q
      y = y + d[o + 8] * q
      z = z + d[o + 12] * q
    end
  end
  return x / total, y / total, z / total
end

-- Where the BIND pose puts it -- the spot every animation is measured
-- against. Cached on the shared MODEL, because it is a fact about the model
-- and not about this instance of it.
--
-- Called once, from new(), and deliberately not lazily from anchor(): taking
-- this measurement means POSING the bind pose, which would overwrite the
-- animated pose anchor() was called to correct. Doing it while the rig is
-- still being built is the one moment there is no pose to lose.
function StadiumRig:measureBind()
  local model = self.model
  if model.bindCX then return end
  self:pose(nil, 0, false)
  model.bindCX, model.bindCY, model.bindCZ = centre(self, model.boneCount)

  -- ------- and whether this species can be anchored at all
  --
  -- Decided ONCE, per model, offline, by walking its standby loop and asking
  -- how far the body estimate moves between one frame and the next.
  --
  -- Everything the anchor does rests on that estimate being a description of
  -- where the Pokemon is. For 147 species it is: the fastest real motion in
  -- the set moves the body about a fifth of a body-height per 30 Hz frame.
  -- Pidgeot's standby loop moves it THREE, because a few of its rotation
  -- frames are junk (the worst data in the set, and a known issue in its own
  -- right). There is no filter setting that both tracks a real excursion and
  -- rejects that -- measured, at four time constants, either the excursions
  -- came back or the shake did -- because the two are only a factor of
  -- fifteen apart and a filter is a proportion.
  --
  -- So a species whose own idle says its estimate cannot be trusted is not
  -- anchored, and plays exactly as it did before the anchor existed: it
  -- travels as far as its animation says, and it does not vibrate. One
  -- species trading a framing problem for no problem beats 147 trading a
  -- solved framing problem for a shake.
  --
  -- Cheap: forty-odd poses on a model that is about to be posed sixty times
  -- a second anyway.
  local idle = model.ctx and model.ctx[IDLE_SLOT]
  local anim = (idle and idle ~= 0xFFFF) and (idle + 1) or nil
  local rec = anim and model.anims and model.anims[anim]
  model.anchorOk = true
  if rec and rec.frames and rec.frames > 1 then
    local root = model.rootScale
    if not (root and root > 0) then root = 1 end
    local h = (model.height or 0) / root
    if h > 0 then
      local px, py, pz, worst = nil, nil, nil, 0
      for f = 0, rec.frames - 1 do
        self:pose(anim, f, true)
        local x, y, z = centre(self, model.boneCount)
        if x and px then
          local d = (((x - px) ^ 2 + (y - py) ^ 2 + (z - pz) ^ 2) ^ 0.5) / h
          if d > worst then worst = d end
        end
        px, py, pz = x, y, z
      end
      if worst > StadiumRig.ANCHOR_STEADY then
        model.anchorOk = false
        V.mod.log:info("stadium: species %s moves its own body %.1f "
                       .. "body-heights in one frame of its standby loop -- "
                       .. "not anchoring it, the measurement cannot be "
                       .. "trusted", tostring(model.species), worst)
      end
    end
  end
  -- and leave the bind pose behind, not the last frame of the idle
  self:pose(nil, 0, false)
end

-- ------- and why the offset is SMOOTHED
--
-- A better centre is not enough on its own. Any estimate that follows the
-- pose carries the pose's own frame-to-frame wobble into it, and the anchor
-- multiplies that up into a translation of the whole Pokemon -- so a species
-- whose source data is erratic (Pidgeot's standby loop has a few frames of
-- junk in it, and no estimator can smooth data that is genuinely wrong)
-- would shake bodily rather than in the one bone that is wrong.
--
-- So the offset is low-passed. What the anchor is FOR is a slow excursion --
-- a Pokemon swimming seven body-heights away over two seconds -- and that
-- survives a filter with this time constant untouched, while anything
-- oscillating frame to frame is flattened. The correction ends up describing
-- where the Pokemon has drifted TO, never how it is shaking on the way.
--
-- HALF_LIFE is in seconds: the time the offset takes to close half of any
-- gap between where it is and where the pose says it should be. Short enough
-- that a real excursion is caught within a few frames of starting, long
-- enough that a 30 Hz wobble does not survive it.
StadiumRig.ANCHOR_HALF_LIFE = 0.05


-- ------- what this does NOT fix, and why it stops here
--
-- The filter is a proportion, so it divides the input wobble down rather than
-- bounding it -- and one species' data is bad enough to get through anyway.
-- Pidgeot's standby loop carries a few frames of junk rotation (the worst in
-- the set, and a known issue since before the anchor existed), which moves
-- the body estimate three body-heights inside a single frame; filtered, that
-- is still about three pixels a frame on a fourteen-pixel model.
--
-- Two further mechanisms were built and MEASURED against the set, and both
-- were taken back out:
--
--   a rate limit on the correction bounded the shake to a third of a pixel,
--   and cost so much tracking that 33 of the 148 entrances went back to
--   leaving the frame -- half the problem the anchor exists to solve
--
--   a rate limit on the MEASUREMENT, to tell a spike from an excursion by
--   speed, could not separate them: the fastest real excursion (Dewgong's
--   entrance, five and a half body-heights a second) is close enough to
--   Pidgeot's sustained junk that any threshold either clipped Dewgong or
--   passed Pidgeot, and freezing on distrust made both worse
--
-- So it stops here, at the setting that is right for the 147 species whose
-- data is not broken. Pidgeot is a data problem and belongs with the other
-- data problems in the CHANGELOG's Known section, not in this control loop:
-- the alternative was distorting every other Pokemon's animation to flatter
-- one whose source frames are wrong.

-- Pull the pose back toward the tile. `limit` is in the Pokemon's own
-- body-heights; nil or a non-positive value leaves the pose exactly as posed.
-- `dt` is the frame's own delta; without one the offset is applied whole,
-- which is what a still (the QA sweep, a probe) wants.
function StadiumRig:anchor(limit, dt)
  if not (limit and limit > 0) then return end
  local model = self.model
  local n = model.boneCount
  -- the vertices are in RAW units, before the model_root scale that
  -- model.height is measured after
  local root = model.rootScale
  if not (root and root > 0) then root = 1 end
  local h = (model.height or 0) / root
  if not (h > 0) then return end

  local bx, by, bz = model.bindCX, model.bindCY, model.bindCZ
  if not bx then return end          -- never measured; leave the pose alone
  if model.anchorOk == false then return end   -- and unmeasurable, at that
  local x, y, z = centre(self, n)
  if not x then return end

  local dx, dy, dz = x - bx, y - by, z - bz
  local dist = (dx * dx + dy * dy + dz * dz) ^ 0.5
  local allow = limit * h

  -- what the pose alone asks for: the EXCESS beyond the limit, so what is
  -- inside it stays and the motion keeps its shape
  local ox, oy, oz = 0, 0, 0
  if dist > allow and dist > 0 then
    local k = (dist - allow) / dist
    ox, oy, oz = dx * k, dy * k, dz * k
  end

  -- and then toward it rather than straight to it (see ANCHOR_HALF_LIFE),
  -- and never faster than ANCHOR_RATE
  if dt and dt > 0 then
    local half = StadiumRig.ANCHOR_HALF_LIFE
    local a = (half > 0) and (1 - 0.5 ^ (dt / half)) or 1
    if a > 1 then a = 1 end
    local px, py, pz = self.anchorX or ox, self.anchorY or oy, self.anchorZ or oz
    ox = px + (ox - px) * a
    oy = py + (oy - py) * a
    oz = pz + (oz - pz) * a
  end
  self.anchorX, self.anchorY, self.anchorZ = ox, oy, oz
  if ox == 0 and oy == 0 and oz == 0 then return end

  local pivot, drw = self.pivotM, self.drawM
  for b = 1, n do
    local o = (b - 1) * 12
    pivot[o + 4] = pivot[o + 4] - ox
    pivot[o + 8] = pivot[o + 8] - oy
    pivot[o + 12] = pivot[o + 12] - oz
    drw[o + 4] = drw[o + 4] - ox
    drw[o + 8] = drw[o + 8] - oy
    drw[o + 12] = drw[o + 12] - oz
  end
end

-- ------- the skin
--
-- Every vertex through its one bone's draw matrix, and its normal through
-- the same bone's pivot (a pure rotation, so the normal survives a
-- non-uniformly scaled bone -- which several species have).
--
-- `yaw` is the model matrix's own turn, and it is folded in HERE rather
-- than left to the matrix because the shade has to be computed against the
-- WORLD normal: a Pokemon turned to face its opponent has a differently lit
-- flank than one facing the camera, and the sun does not turn with it.
function StadiumRig:skin(yaw)
  local cy, sy = cos(yaw or 0), sin(yaw or 0)
  local drw, piv = self.drawM, self.pivotM
  for _, part in ipairs(self.parts) do
    local prim, rows = part.prim, part.rows
    local px, py, pz = prim.px, prim.py, prim.pz
    local nx, ny, nz = prim.nx, prim.ny, prim.nz
    local bone = prim.bone
    for k = 1, prim.vertCount do
      local o = (bone[k] - 1) * 12
      local x, y, z = px[k], py[k], pz[k]
      local row = rows[k]
      row[1] = drw[o + 1] * x + drw[o + 2] * y + drw[o + 3] * z + drw[o + 4]
      row[2] = drw[o + 5] * x + drw[o + 6] * y + drw[o + 7] * z + drw[o + 8]
      row[3] = drw[o + 9] * x + drw[o + 10] * y + drw[o + 11] * z + drw[o + 12]
      local ax, ay, az = nx[k], ny[k], nz[k]
      local wx = piv[o + 1] * ax + piv[o + 2] * ay + piv[o + 3] * az
      local wy = piv[o + 5] * ax + piv[o + 6] * ay + piv[o + 7] * az
      local wz = piv[o + 9] * ax + piv[o + 10] * ay + piv[o + 11] * az
      -- the model matrix's yaw, by hand: (x, z) turned, y untouched
      row[6] = SHADE_BASE + SHADE_X * (cy * wx + sy * wz) + SHADE_Y * wy
               + SHADE_Z * (cy * wz - sy * wx)
    end
    pcall(part.mesh.setVertices, part.mesh, rows)
  end
end

-- ------- which texture each part wears this frame
--
-- The eyes. A primitive whose display list carried geo command 0x23 with a
-- channel index has its texture REPLACED every frame from a stream of
-- texture-table indices (src/18140.c func_800176DC) -- which is how every
-- Pokemon in the game blinks, and how a confused one gets swirls. glTF has
-- no channel for that, so the .glb files carry only the first frame; the
-- pack carries the streams.
--
-- `aux` is an index into model.auxAnims (the stream set) and `frame` its
-- own frame counter, which runs independently of the skeletal one.
-- The eyes, and everything else a material swaps per frame.
--
-- Sampled at the SKELETAL animation's own frame -- the one pose() just
-- resolved -- and CLAMPED past the end of the stream rather than wrapped.
-- Both halves of that matter, and getting either wrong is visible.
--
-- The frame is the skeleton's because in the game a single counter drives
-- both; the data says so plainly, since 507 of the 691 paired animations in
-- the set have a texture animation exactly as long as the skeletal one it
-- rides with.
--
-- The clamp is what the game's own sampler does (func_80017540 indexes the
-- stream and holds the last entry past its end), and it is the whole
-- difference between a blink and a twitch. Rattata's standby loop is forty
-- frames and its blink is FIVE -- `6 8 7 8 6`, open through closed and back.
-- Wrapped on the blink's own length that plays six times a second, which is
-- what it looked like. Clamped, the eye blinks once at the top of the loop
-- and stays open for the remaining thirty-five frames, so it blinks about
-- once a second and a half.
function StadiumRig:textures(aux)
  local model = self.model
  local anim = aux and model.auxAnims and model.auxAnims[aux] or nil
  local frame = self.frameAt or 0
  for _, part in ipairs(self.parts) do
    local prim = part.prim
    local index = prim.tex
    if anim and prim.texAnim and prim.texAnim >= 0 and prim.texMap then
      local stream = anim.channels[prim.texAnim + 1]
      local n = stream and #stream or 0
      if n > 0 then
        local at = frame + 1
        if at > n then at = n end
        if at < 1 then at = 1 end
        local mapped = prim.texMap[stream[at]]
        if mapped then index = mapped end
      end
    end
    part.texture = StadiumPack.image(model, index)
  end
end

-- ------- the draw
--
-- `model` here is the MODEL MATRIX -- where this Pokemon stands, how big
-- and which way round -- and `sunModel` the transform the shadow pass drew
-- it with, which for these is the same matrix (unlike a character's leaning
-- card; see Voxel3D.draw).
--
-- Seams off for the whole of it: the voxel wireframe draws the integer
-- planes of a mesh's own model space, and these vertices are in the N64's
-- own units where an integer plane means nothing (see VoxelGrid). Glass off
-- for the same reason the sprite passes turn it off -- the mask's
-- coordinates belong to the tileset atlas, not to a Pokemon's texture.
function StadiumRig:draw(matrix, pull)
  Voxel3D.seams(false)
  Voxel3D.glass(false)
  local additive = nil
  for _, part in ipairs(self.parts) do
    if part.prim.additive then
      -- held back to a second pass so the flames composite over the body
      -- rather than depth-fighting it
      additive = additive or {}
      additive[#additive + 1] = part
    elseif part.texture then
      Voxel3D.draw(part.mesh, part.texture, matrix, pull)
    end
  end
  if additive then
    Voxel3D.blend("add")
    for _, part in ipairs(additive) do
      if part.texture then
        Voxel3D.draw(part.mesh, part.texture, matrix, pull)
      end
    end
    Voxel3D.blend(nil)
  end
  Voxel3D.glass(true)
  Voxel3D.seams(true)
end

-- The same geometry as the SUN sees it: no camera-ward pull (a trick for
-- the view's own depth buffer, which would drag a shadow off its owner) and
-- through the shadow pass's own draw call. The generated flame prims are
-- skipped -- a fire casts light, not a shadow.
function StadiumRig:caster(shadowMap, matrix)
  for _, part in ipairs(self.parts) do
    if part.texture and not part.prim.additive then
      shadowMap.draw(part.mesh, part.texture, matrix)
    end
  end
end

return StadiumRig
