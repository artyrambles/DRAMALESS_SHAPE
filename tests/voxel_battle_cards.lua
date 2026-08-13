local draws, captures, bypasses = {}, {}, 0
local currentCanvas

love = {
  graphics = {
    newCanvas = function(w, h)
      return { setFilter = function() end, getDimensions = function() return w, h end }
    end,
    getCanvas = function() return currentCanvas end,
    setCanvas = function(canvas) currentCanvas = canvas end,
    clear = function() end,
    getShader = function() return nil end,
    setShader = function() end,
    getBlendMode = function() return "alpha", "alphamultiply" end,
    setBlendMode = function() end,
    getColor = function() return 1, 1, 1, 1 end,
    setColor = function() end,
    getScissor = function() return nil end,
    setScissor = function() end,
    push = function() end,
    pop = function() end,
    setDepthMode = function() end,
    draw = function(texture, x, y, rotation, sx, sy)
      draws[#draws + 1] = { texture, x, y, rotation, sx, sy }
    end,
  },
}

local battle = {
  player = { sprite = {} },
  enemy = { sprite = {} },
  fxHidden = function() return false end,
  drawPicsLayer = function(_, _, _, _, side, skipClip)
    assert(side == "player" or side == "enemy")
    assert(skipClip == true)
    captures[#captures + 1] = side
  end,
}

local context = {
  battle = battle,
  arena = { player = { 10, 20 }, enemy = { -10, -20 } },
  groundY = 0,
  services = {
    withNativeBattlePics = function(fn)
      bypasses = bypasses + 1
      local ok, err = pcall(fn)
      return ok, err
    end,
    project = function(x, y, z)
      return 200 + x, 300 - y + z * 0
    end,
    log = { warn = function() end },
  },
}

local pinBack = false
local provider = assert(loadfile("lib/VoxelBattleCardProvider.lua"))({
  backSpritesSetting = { get = function() return pinBack end },
})
assert(provider:available(context))
assert(provider:begin(context, context.arena))
assert(#captures == 2 and bypasses == 2)
assert(provider:drawWorld(context))
assert(#draws == 2)
assert(provider:covers(context, "player"))
assert(provider:covers(context, "enemy"))
assert(provider:showing(context, "player"))
assert(provider:center(context, "enemy"))
assert(provider:footprint(context, "player").height > 0)

pinBack = true
provider:update(context)
assert(provider:drawWorld(context))
assert(not provider:covers(context, "player"),
  "BACK SPRITES must leave the native player picture unsuppressed")
assert(provider:covers(context, "enemy"),
  "BACK SPRITES must keep the enemy on its world card")
provider:finish()
assert(not provider:covers(context, "player"))

local ModSetting = assert(loadfile("lib/ModSetting.lua"))({
  mod = { id = "DRAMALESS_SHAPE", options = { get = function() return nil end } },
})
local standalone = ModSetting.new("voxel_2d_battles", "VOXEL ARENA + 2D CARDS",
  { false, true }, { "OFF", "ON" }, 2)
assert(standalone:schema("standalone").default == true,
  "standalone battle setting must advertise its requested ON default")

print("ok native 2D card provider capture, projection, and coverage")
