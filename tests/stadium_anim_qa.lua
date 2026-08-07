-- STADIUM battles: every Pokemon, every animation, every frame.
--
--   luajit mods/DramaticShapeVoxelMod/tests/stadium_anim_qa.lua \
--     [--packs=DIR] [--dex=N[,N...]] [--step=0.5] [--quiet]
--
-- Run from the PROJECT ROOT.
--
-- ------- what this is for
--
-- A battle asks a species for one of its animations and then poses, skins,
-- re-textures and draws it sixty times a second. Nothing in that chain is
-- exercised by the pack probe, which reads the format and walks a bind pose,
-- and nothing in it is exercised by the shot drivers, which show one species
-- in one animation at a time. So the failures that only some species have --
-- a texture index nothing maps, an animation that throws a bone into orbit,
-- a track that indexes off its own end -- have had no way of being found
-- except by a player calling that Pokemon out.
--
-- This is that sweep, headless: the REAL StadiumPack, the REAL StadiumRig
-- and the REAL StadiumMon over stubs for the three things a graphics context
-- provides (a mesh, an image, the draw call). Every species, every animation
-- it carries, every frame of it, plus the battle state machine over every
-- one of the 165 move slots.
--
-- ------- the stubs are not lenient
--
-- The fake mesh and the fake image behave like LOVE's do in the one way that
-- matters: an object that has been released THROWS when it is used, with
-- LOVE's own message. That is deliberate -- a released texture reaching a
-- draw call is a real failure mode of this mode (see the LRU note in
-- StadiumPack), and a stub that quietly accepted one would hide exactly the
-- class of bug this sweep exists to find.

local args = {}
local only = nil
for _, a in ipairs({ ... }) do
  local k, v = a:match("^%-%-([%w_]+)=(.*)$")
  if k then args[k] = v elseif a == "--quiet" then args.quiet = "1" end
end
if args.dex then
  only = {}
  for n in args.dex:gmatch("%d+") do only[#only + 1] = tonumber(n) end
end

local MOD = "mods/DramaticShapeVoxelMod"

-- Where the .dsm packs are. The mod builds them into LOVE's save directory
-- on first run (StadiumInstall), which is where a developer machine actually
-- has them; a checkout that has run tools/stadium_pack.py has them in the
-- mod instead. Both are tried, and --packs overrides.
local PACK_DIRS = {}
local function lookIn(dir)
  if dir and dir ~= "" then PACK_DIRS[#PACK_DIRS + 1] = dir end
end
lookIn(args.packs)
lookIn(os.getenv("APPDATA")
       and os.getenv("APPDATA") .. "/LOVE/pokemon-love2d/dramatic_shape/stadium")
lookIn(os.getenv("HOME")
       and os.getenv("HOME")
           .. "/.local/share/love/pokemon-love2d/dramatic_shape/stadium")
lookIn(MOD .. "/assets/stadium")

-- How far apart the sampled frames are, in the animation's own 30 Hz frames.
-- A half frame rather than a whole one because the rig INTERPOLATES between
-- entries, and the blend has guards of its own that only run when k > 0 --
-- sampling on whole frames alone would never execute them.
local STEP = tonumber(args.step or "0.5")

-- How much taller than its own bind pose a posed model may stand before it
-- is called broken. Generous on purpose: a Pokemon that rears up, a wing
-- that opens, a Gyarados that lunges are all genuinely several times their
-- standing height. What this catches is the other thing -- a bone thrown
-- hundreds of units off the body, which comes out in the dozens.
local EXPLODE = 6.0

-- The texture index of a primitive the source says has no texture. The pack
-- stores indices one-based, so the packer's 0xFFFF sentinel arrives as this.
local UNTEXTURED = 0xFFFF + 1

-- species -> true, for the ones that carry such a primitive. Counted rather
-- than reported (see the texture check).
local untextured = {}

-- species the rig refuses to anchor because their own standby loop says the
-- body estimate cannot be trusted (StadiumRig.ANCHOR_STEADY)
local unanchored = {}

-- How far the mode lets an animation carry the Pokemon off its tile, in body
-- heights. Read from StadiumMon rather than repeated, so the sweep cannot go
-- on passing against a number the mode has since changed.
local TRAVEL = nil

-- ------- the harness

package.path = "./?.lua;./?/init.lua;" .. package.path

local packDir = nil
for _, dir in ipairs(PACK_DIRS) do
  if dir and dir ~= "" then
    local fp = io.open(dir .. "/001.dsm", "rb")
    if fp then fp:close() packDir = dir break end
  end
end
if not packDir then
  print("no .dsm packs found -- pass --packs=DIR")
  print("looked in:")
  for _, dir in ipairs(PACK_DIRS) do
    if dir and dir ~= "" then print("  " .. dir) end
  end
  os.exit(1)
end

local function readFile(path)
  local fp = io.open(path, "rb")
  if not fp then return nil end
  local bytes = fp:read("*a")
  fp:close()
  return bytes
end

-- ------- the three things a graphics context provides
--
-- A released object throws, exactly as LOVE's does. See the header.

local RELEASED = "Cannot use object after it has been released."

local function checkLive(obj)
  if obj and obj.released then error(RELEASED, 0) end
end

local function newFakeImage(w, h)
  local img = { w = w, h = h, released = false }
  function img:setFilter() checkLive(self) end
  function img:setWrap() checkLive(self) end
  function img:release() self.released = true return true end
  function img:type() return "Image" end
  return img
end

local function newFakeMesh(format, rows)
  local mesh = { released = false, verts = rows }
  function mesh:setVertexMap() checkLive(self) end
  function mesh:setVertices(v) checkLive(self) self.verts = v end
  function mesh:setTexture(t) checkLive(self) checkLive(t) self.tex = t end
  function mesh:release() self.released = true return true end
  function mesh:type() return "Mesh" end
  return mesh
end

love = {
  filesystem = {
    getInfo = function(rel)
      -- the mod asks for "dramatic_shape/stadium/NNN.dsm" relative to the
      -- save directory; the sweep serves that out of packDir
      local name = rel:match("([^/]+)$")
      local fp = io.open(packDir .. "/" .. name, "rb")
      if not fp then return nil end
      fp:close()
      return { type = "file" }
    end,
    read = function(rel)
      local name = rel:match("([^/]+)$")
      return readFile(packDir .. "/" .. name)
    end,
  },
  graphics = {
    newMesh = function(format, rows, mode, usage) return newFakeMesh(format, rows) end,
    newImage = function(data) return newFakeImage(data.w, data.h) end,
  },
  image = {
    newImageData = function(w, h, fmt, bytes) return { w = w, h = h } end,
  },
}

local V = {}
local modules = {}
V.mod = {
  log = {
    warn = function(_, fmt, ...) print("[warn] " .. fmt:format(...)) end,
    info = function(_, fmt, ...) print("[info] " .. fmt:format(...)) end,
  },
  read = function(_, rel) return readFile(MOD .. "/" .. rel) end,
}
function V.require(name)
  if modules[name] then return modules[name] end
  local chunk = assert(loadfile(MOD .. "/lib/" .. name .. ".lua"))
  modules[name] = chunk(V)
  return modules[name]
end

-- Voxel3D, to the extent the rig touches it. `draw` mirrors the real one's
-- first act -- binding the texture to the mesh -- because that is the line a
-- released texture dies on (Voxel3D.draw), and the whole point of the stub
-- is that it dies there here too.
local drawn, skipped = 0, 0
modules.Voxel3D = {
  FORMAT = {},
  seams = function() end,
  glass = function() end,
  blend = function() end,
  draw = function(mesh, texture, model, pull, sunModel)
    if not mesh then return end
    if texture then mesh:setTexture(texture) end
    drawn = drawn + 1
  end,
}
-- the shadow pass, same shape
local shadowMap = { draw = function(mesh, texture, model)
  if texture then mesh:setTexture(texture) end
end }

local Pack = V.require("StadiumPack")
local Rig = V.require("StadiumRig")
local Mon = V.require("StadiumMon")
TRAVEL = Mon.TRAVEL

-- ------- findings

local findings = {}      -- kind -> { {dex=, anim=, frame=, detail=} ... }
local kinds = {}         -- kind order, first seen first

local function report(kind, dex, anim, frame, detail)
  if not findings[kind] then
    findings[kind] = {}
    kinds[#kinds + 1] = kind
  end
  local list = findings[kind]
  list[#list + 1] = { dex = dex, anim = anim, frame = frame, detail = detail }
end

-- ------- one animation, frame by frame

-- Where the BODY of a posed rig is: the bone origins averaged, weighted by
-- how many vertices each bone moves.
--
-- The same QUANTITY StadiumRig.anchor corrects, written out a second time
-- rather than called: a check that shared the code it is checking would agree
-- with it by construction. It must be the same quantity, though -- an earlier
-- version of this measured the MEDIAN instead, and reported 27,965 findings
-- purely because it was asking a different question than the anchor answers.
local function bodyCentreOf(rig)
  local m = rig.model
  local w, total = m.qaWeights, m.qaWeightTotal
  if not w then
    w, total = {}, 0
    for b = 1, m.boneCount do w[b] = 0 end
    for _, prim in ipairs(m.prims) do
      for k = 1, prim.vertCount do
        local b = prim.bone[k]
        if w[b] then w[b] = w[b] + 1; total = total + 1 end
      end
    end
    m.qaWeights, m.qaWeightTotal = w, total
  end
  if not (total > 0) then return 0, 0, 0 end
  local x, y, z, d = 0, 0, 0, rig.drawM
  for b = 1, m.boneCount do
    local q = w[b]
    if q > 0 then
      local o = (b - 1) * 12
      x = x + d[o + 4] * q
      y = y + d[o + 8] * q
      z = z + d[o + 12] * q
    end
  end
  return x / total, y / total, z / total
end

local function bboxOf(rig)
  local lo, hi = math.huge, -math.huge
  local bad = false
  for _, part in ipairs(rig.parts) do
    local rows = part.rows
    for k = 1, part.prim.vertCount do
      local row = rows[k]
      local x, y, z = row[1], row[2], row[3]
      -- NaN is the only value not equal to itself; infinity survives that
      -- test and has to be asked about separately
      if x ~= x or y ~= y or z ~= z
         or x == math.huge or x == -math.huge
         or y == math.huge or y == -math.huge
         or z == math.huge or z == -math.huge then
        bad = true
      else
        if y < lo then lo = y end
        if y > hi then hi = y end
      end
    end
  end
  if lo > hi then return 0, bad end
  return hi - lo, bad
end

-- A species' worth of work. Returns the number of frames stepped.
local function sweepSpecies(dex)
  local model = Pack.load(dex)
  if not model then
    -- say WHY, or a sweep that ran out of file handles reads as 108 broken
    -- Pokemon
    local _, err = io.open(("%s/%03d.dsm"):format(packDir, dex), "rb")
    report("pack did not load", dex, nil, nil,
           ("StadiumPack.load returned nil (io.open says: %s)")
           :format(tostring(err)))
    return 0
  end

  local rig = Rig.new(model)
  if not rig then
    report("rig would not build", dex, nil, nil,
           ("%d prims, %d bones"):format(model.primCount, model.boneCount))
    return 0
  end

  -- the bind pose, as the yardstick every posed frame is measured against
  rig:measureBind()
  rig:pose(nil, 0, false)
  rig:skin(0)
  local bind = bboxOf(rig)
  if not (bind > 0) then bind = 1 end
  -- and where the bind pose puts the BODY, for the travel check below. The
  -- tracks are in raw units, before the model_root scale model.height is
  -- measured after.
  if model.anchorOk == false then unanchored[dex] = true end
  local bcx, bcy, bcz = bodyCentreOf(rig)
  local rawHeight = (model.height or 0)
                    / ((model.rootScale or 0) > 0 and model.rootScale or 1)
  if not (rawHeight > 0) then rawHeight = 1 end

  local steps = 0
  for index, anim in ipairs(model.anims) do
    local name = anim.name or ("#" .. index)
    local frames = anim.frames or 1
    if frames < 1 then
      report("animation has no frames", dex, name, nil,
             ("frames=%d"):format(frames))
    end
    -- the loop start has to be inside the animation or the wrap arithmetic
    -- lands outside the track arrays
    local loop = anim.loopStart or 0
    if loop < 0 or loop >= frames then
      report("loopStart out of range", dex, name, nil,
             ("loopStart=%d of %d frames"):format(loop, frames))
    end
    if anim.aux and not (model.auxAnims and model.auxAnims[anim.aux]) then
      report("aux animation missing", dex, name, nil,
             ("anim.aux=%s, %d aux animations")
             :format(tostring(anim.aux), model.auxCount or 0))
    end

    -- Both ways round: a standby loop WRAPS at the far end and a faint HOLDS
    -- on its last frame, and the two take different branches of the pose
    -- walk. Sampled a little past the end on purpose -- that is where a
    -- battle actually leaves them.
    for _, wrap in ipairs({ true, false }) do
      local f = 0
      while f < frames + 2 do
        local ok, err = pcall(function()
          rig:pose(index, f, wrap)
          rig:skin(0.5)
          rig:textures(anim.aux)
          rig:draw({ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }, 0)
        end)
        steps = steps + 1
        if not ok then
          report("threw while playing", dex, name, f, tostring(err))
          break
        end
        -- ------- does it stay on its tile?
        --
        -- Stadium's animations were authored for a camera that FOLLOWED the
        -- Pokemon around a stage; this mode's camera is solved to hold two
        -- fixed map cells and does not move. So an animation that walks the
        -- body several of its own heights away does not look dramatic here,
        -- it looks like the Pokemon is missing -- which is what sending out
        -- a Farfetch'd did for three and a half seconds.
        --
        -- StadiumRig.anchor takes the excess back out, and this is the check
        -- that it did: measured AFTER the anchor, the same way the mode
        -- draws it, so what is reported is what a player would actually see.
        rig:anchor(TRAVEL)
        local cx, cy, cz = bodyCentreOf(rig)
        local drift = (((cx - bcx) ^ 2 + (cy - bcy) ^ 2 + (cz - bcz) ^ 2) ^ 0.5)
                      / rawHeight
        -- a species the rig has judged unmeasurable is deliberately NOT
        -- anchored (StadiumRig.measureBind), so of course it still travels --
        -- reporting that would be reporting a decision as a defect
        if model.anchorOk ~= false and drift > TRAVEL * 1.05 then
          report("animation walks the Pokemon off its tile", dex, name, f,
                 ("body centre %.1f body-heights from where it started")
                 :format(drift))
        end

        local h, bad = bboxOf(rig)
        if bad then
          report("posed vertex is NaN or infinite", dex, name, f, "")
        elseif h > bind * EXPLODE then
          report("pose flies apart", dex, name, f,
                 ("%.0f units tall against a %.0f-unit bind pose (%.1fx)")
                 :format(h, bind, h / bind))
        end
        -- Every piece of the Pokemon has to have a texture to be drawn with,
        -- and one that resolves to nothing is a limb that is simply not
        -- there -- EXCEPT where the source says it has none.
        --
        -- StadiumPack stores the texture index one-based (`u16 + 1`), so the
        -- packer's 0xFFFF "this primitive is untextured" sentinel arrives
        -- here as 65536. That is 39 primitives across 37 species, 1.6% of the
        -- set's vertices, and every one of them has all-zero UVs -- they are
        -- flat-shaded geometry in the original, not a texture that went
        -- missing. Reported as a finding they were 104,728 lines of noise
        -- (one per prim per sampled frame) burying two real bugs.
        --
        -- Counted rather than dropped: "how much of this set is untextured"
        -- is worth knowing, and a number that suddenly moves is worth seeing.
        for i, part in ipairs(rig.parts) do
          if not part.texture then
            if part.prim.tex == UNTEXTURED then
              untextured[dex] = true
            else
              report("part has no texture", dex, name, f,
                     ("prim %d wants texture %s of %d")
                     :format(i, tostring(part.prim.tex), model.texCount or 0))
            end
          end
        end
        f = f + STEP
      end
    end
  end

  -- ------- and the same species as a BATTLE drives it
  --
  -- The sweep above plays the animations; this plays the STATE MACHINE, which
  -- is what a fight actually touches: the context slots behind idle, the
  -- entrance, the two reactions and the collapse, and then all 165 move slots
  -- -- because a move's animation is looked up by move id in a table the
  -- species carries, and an index in that table that points nowhere is a
  -- crash on the frame that move is used.
  local mon = Mon.new("player")
  mon.rig, mon.model, mon.species = rig, model, dex
  mon.state, mon.anim, mon.time = nil, nil, 0

  for _, state in ipairs({ "idle", "entrance", "attack", "faint" }) do
    local ok, err = pcall(function()
      mon:play(state)
      -- a whole second of it at 60 Hz, which is what the fight does
      for _ = 1, 60 do
        mon:update(1 / 60)
        mon:build()
      end
    end)
    if not ok then
      report("threw while playing", dex, state, nil, tostring(err))
    end
  end

  for moveIndex = 1, Pack.N_MOVES do
    local slot = model.moveAnim[moveIndex]
    if slot and slot ~= Pack.NONE then
      if not model.anims[slot + 1] then
        report("move points at an animation that is not there", dex,
               ("move %d"):format(moveIndex), nil,
               ("anim index %d of %d"):format(slot + 1, model.animCount or 0))
      else
        local aux = model.moveAux[moveIndex]
        if aux and aux >= 0 and not (model.auxAnims and model.auxAnims[aux + 1]) then
          report("move points at an aux that is not there", dex,
                 ("move %d"):format(moveIndex), nil,
                 ("aux index %d of %d"):format(aux + 1, model.auxCount or 0))
        end
        local ok, err = pcall(function()
          mon:attack(moveIndex)
          for _ = 1, 30 do
            mon:update(1 / 60)
            mon:build()
          end
        end)
        if not ok then
          report("threw while playing", dex, ("move %d"):format(moveIndex),
                 nil, tostring(err))
        end
      end
    end
  end

  rig:release()
  return steps
end

-- ------- the sweep

local list = only
if not list then
  list = {}
  for dex = 1, 151 do list[dex] = dex end
end

local started = os.clock()
local steps = 0
local staticPose = {}
for _, dex in ipairs(list) do
  local m = Pack.load(dex)
  -- SKIPPED, not swept. The packer measures each species' standby loop
  -- against its own bind pose and flags the ones whose animation data is
  -- corrupt at source, and StadiumMon declines those outright -- they stand
  -- as flat battle pics and no frame of them is ever posed in a game. Sweeping
  -- them anyway produced 356 of the 362 "pose flies apart" findings, which is
  -- a report that is mostly about Pokemon this mode does not draw.
  if m and m.staticPose then
    staticPose[#staticPose + 1] = dex
  else
    local ok, err = pcall(function() steps = steps + sweepSpecies(dex) end)
    if not ok then
      report("the sweep itself threw", dex, nil, nil, tostring(err))
    end
  end
  if not args.quiet and dex % 10 == 0 then
    io.write(("  ... %d/%d  %.0f MB\n")
             :format(dex, #list, collectgarbage("count") / 1024))
    io.flush()
  end
end

-- ------- the LRU, which is the one failure a frame sweep cannot reach
--
-- A model is evicted by SPECIES COUNT, not by whether anything is still
-- standing on it -- so a battle that has seen five species while two of them
-- are on the field releases the textures of a Pokemon that is still being
-- drawn. That is not something playing one species' animations can produce;
-- it takes a sixth load. Reproduced here directly.
local function sweepEviction()
  local held = {}
  -- two Pokemon out, as a battle has
  for _, dex in ipairs({ 1, 4 }) do
    local model = Pack.load(dex)
    local rig = model and Rig.new(model)
    if rig then held[#held + 1] = { dex = dex, model = model, rig = rig } end
  end
  if #held < 2 then return end
  for _, h in ipairs(held) do
    h.rig:pose(1, 0, true)
    h.rig:skin(0)
    h.rig:textures(nil)
  end
  -- and then the fight sees more species than the cache keeps
  for _, dex in ipairs({ 7, 10, 13, 16, 19, 25 }) do Pack.load(dex) end
  for _, h in ipairs(held) do
    local ok, err = pcall(function()
      h.rig:textures(nil)
      h.rig:draw({ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }, 0)
    end)
    if not ok then
      report("threw after the pack cache evicted a model still on the field",
             h.dex, "idle", nil, tostring(err))
    end
  end
  for _, h in ipairs(held) do h.rig:release() end
end
sweepEviction()

local elapsed = os.clock() - started

-- ------- what it found

print("")
print(("stadium animation QA: %d species, %d posed frames, %.1fs")
      :format(#list, steps, elapsed))
print(("packs: %s"):format(packDir))
local nUntextured = 0
for _ in pairs(untextured) do nUntextured = nUntextured + 1 end
if nUntextured > 0 then
  print(("species with flat-shaded (untextured) primitives: %d -- expected, "
         .. "the source has no texture for those"):format(nUntextured))
end
local anchorList = {}
for dex in pairs(unanchored) do anchorList[#anchorList + 1] = dex end
table.sort(anchorList)
if #anchorList > 0 then
  print(("not anchored (standby loop too unsteady to measure, so they travel "
         .. "as authored): %s"):format(table.concat(anchorList, " ")))
end
if #staticPose > 0 then
  print(("staticPose (declined by the packer, never drawn, not swept): %s")
        :format(table.concat(staticPose, " ")))
end
print("")

local total = 0
for _, kind in ipairs(kinds) do total = total + #findings[kind] end

if total == 0 then
  print("no findings")
  os.exit(0)
end

for _, kind in ipairs(kinds) do
  local list2 = findings[kind]
  print(("---- %s (%d)"):format(kind, #list2))
  -- one line per species per kind, with the first example and a count, so a
  -- fault that spans every frame of an animation reads as one fault
  local seen, order = {}, {}
  for _, f in ipairs(list2) do
    local key = ("%03d|%s"):format(f.dex or 0, tostring(f.anim))
    if not seen[key] then
      seen[key] = { n = 0, f = f }
      order[#order + 1] = key
    end
    seen[key].n = seen[key].n + 1
  end
  for _, key in ipairs(order) do
    local e = seen[key]
    print(("  %03d %-14s %s%s%s")
          :format(e.f.dex or 0, tostring(e.f.anim),
                  e.f.frame and ("frame %.1f: "):format(e.f.frame) or "",
                  e.detail or e.f.detail or "",
                  e.n > 1 and (" (x%d)"):format(e.n) or ""))
  end
  print("")
end

print(("%d findings in %d kinds"):format(total, #kinds))
os.exit(total > 0 and 1 or 0)
