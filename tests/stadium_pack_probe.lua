-- Probe: read the .dsm packs back with the mod's OWN reader and print what
-- it made of them, so the Lua side can be diffed against the packer's
-- --report output. Headless -- no love.graphics, no meshes.
--
--   luajit mods/DramaticShapeVoxelMod/tests/stadium_pack_probe.lua [dex ...]
--
-- Run from the repository root.

package.path = "./?.lua;./?/init.lua;" .. package.path

local ROOT = "mods/DramaticShapeVoxelMod"

-- the mod namespace lib/ modules expect (see main.lua), with just enough of
-- it for the two files under test
local V = {}
local modules = {}
V.mod = {
  log = {
    warn = function(_, fmt, ...) print("[warn] " .. fmt:format(...)) end,
    info = function(_, fmt, ...) print("[info] " .. fmt:format(...)) end,
  },
  read = function(_, rel)
    local fp = io.open(ROOT .. "/" .. rel, "rb")
    if not fp then return nil end
    local bytes = fp:read("*a")
    fp:close()
    return bytes
  end,
}
function V.require(name)
  if modules[name] then return modules[name] end
  local chunk = assert(loadfile(ROOT .. "/lib/" .. name .. ".lua"))
  modules[name] = chunk(V)
  return modules[name]
end

-- StadiumRig pulls in Voxel3D, which needs love; the pose walk itself does
-- not, so the require is stubbed out to the one field it reads.
modules.Voxel3D = { FORMAT = {} }

local Pack = V.require("StadiumPack")
local Rig = V.require("StadiumRig")

local want = {}
for i = 1, #arg do want[#want + 1] = tonumber(arg[i]) end
if #want == 0 then want = { 25, 6, 130, 95, 50, 10, 143, 92, 41, 73 } end

print(("%-4s %-6s %6s %6s %6s %8s %8s %8s %8s")
      :format("dex", "bones", "prims", "anims", "tex", "root", "height",
              "floor", "radius"))
for _, dex in ipairs(want) do
  local m = Pack.load(dex)
  if not m then
    print(("%-4d  -- did not load"):format(dex))
  else
    print(("%-4d %-6d %6d %6d %6d %8.4f %8.2f %8.2f %8.2f")
          :format(dex, m.boneCount, m.primCount, m.animCount, m.texCount,
                  m.rootScale, m.height, m.floor, m.radius))

    -- the bind pose, walked by the REAL rig code on a bare instance (no
    -- meshes, so no graphics context needed), measured the same way
    -- tools/stadium_pack.py measures it. Agreement here means the byte
    -- format, the bone tree, the rotation basis and the two-chain scale
    -- split all survived the trip into Lua.
    local rig = setmetatable({
      model = m, pivotM = {}, drawM = {}, accX = {}, accY = {}, accZ = {},
      parts = {},
    }, Rig)
    local function boxAt(anim, frame, wrap)
      rig:pose(anim, frame, wrap)
      local drw = rig.drawM
      local lo, hi = math.huge, -math.huge
      for _, prim in ipairs(m.prims) do
        for k = 1, prim.vertCount do
          local o = (prim.bone[k] - 1) * 12
          local x, y, z = prim.px[k], prim.py[k], prim.pz[k]
          local wy = drw[o + 5] * x + drw[o + 6] * y + drw[o + 7] * z
                     + drw[o + 8]
          wy = wy * m.rootScale
          if wy < lo then lo = wy end
          if wy > hi then hi = wy end
        end
      end
      return hi - lo, lo
    end

    local h, f = boxAt(nil, 0, false)
    print(("     bind pose walked in Lua: height %8.2f floor %8.2f  "
           .. "(header says %8.2f / %8.2f)%s")
          :format(h, f, m.height, m.floor,
                  (math.abs(h - m.height) < 0.5
                   and math.abs(f - m.floor) < 0.5) and "  OK" or "  MISMATCH"))

    -- the animation tables, decoded lazily like the game does it
    local idle = m.ctx[Pack.SLOT.idle]
    local names = {}
    for i, a in ipairs(m.anims) do names[i] = a.name end
    print(("     anims: %s"):format(table.concat(names, " ")))
    print(("     idle slot -> %s, entrance -> %s, faint -> %s")
          :format(tostring(idle), tostring(m.ctx[Pack.SLOT.entrance]),
                  tostring(m.ctx[Pack.SLOT.faint])))
    local tracks = Pack.tracks(m, (idle or 0) + 1)
    local animated = 0
    for b = 1, m.boneCount do if tracks and tracks[b] then animated = animated + 1 end end
    print(("     idle: %d frames, %d/%d bones animated")
          :format(m.anims[(idle or 0) + 1].frames, animated, m.boneCount))
    -- the POSED extent, which is what actually gets drawn. Compare against
    -- tools/stadium_pack.py's anim_sample, which was checked frame for
    -- frame against the reference glTF export.
    for _, fr in ipairs({ 0, 1, 5 }) do
      local ah, af = boxAt((idle or 0) + 1, fr, true)
      print(("     idle frame %d: y %8.2f .. %8.2f"):format(fr, af, af + ah))
    end
  end
end
