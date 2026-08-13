local nativePics, fieldFills, clears, overrides = 0, 0, 0, 0
local currentCanvas

love = {
  graphics = {
    getDimensions = function() return 1920, 1080 end,
    getCanvas = function() return currentCanvas end,
    getColor = function() return .8, .7, .6, 1 end,
    clear = function() clears = clears + 1 end,
    rectangle = function(mode, x, y, w, h)
      assert(mode == "fill" and x == 0 and y == 0 and w == 304 and h == 144)
      fieldFills = fieldFills + 1
    end,
  },
}

local BattleState = {}
function BattleState:drawPicsLayer()
  nativePics = nativePics + 1
end
function BattleState:draw()
  -- WideBattle's palette-paper field, then the engine pictures, followed by
  -- a second full-screen fill representing a move flash that must survive.
  love.graphics.rectangle("fill", 0, 0, 304, 144)
  self:drawPicsLayer(0, 0, 0)
  love.graphics.rectangle("fill", 0, 0, 304, 144)
end
package.preload["src.battle.BattleState"] = function() return BattleState end

local arenaProvider = {
  arena = function()
    return { id = "dramaless:test", player = { 1, 2 }, enemy = { 3, 4 } }
  end,
  begin = function() return true end,
  render = function(_, _, _, drawActors)
    drawActors({
      width = 1920, height = 1080, groundY = 0,
      project = function(x, y) return x, y end,
    })
    return { getDimensions = function() return 1920, 1080 end }
  end,
  finish = function() end,
}

local cardProvider = {
  begin = function() return true end,
  drawWorld = function() return true end,
  showing = function() return true end,
  covers = function() return true end,
  finish = function() end,
}

local log = {
  error = function(_, message) error(message) end,
  event = function() end,
}
local Host = assert(loadfile("lib/VoxelBattleStandalone.lua"))({ log = log })
assert(Host.install())

local battle = setmetatable({
  player = {}, enemy = {},
  game = { renderer = {
    setWorldOverride = function(_, surface)
      assert(surface)
      overrides = overrides + 1
    end,
  } },
}, { __index = BattleState })

assert(Host.begin(battle, arenaProvider, cardProvider))

-- Capture must bypass the installed suppression layer.
local captureOk = Host.session.context.services.withNativeBattlePics(function()
  battle:drawPicsLayer(0, 0, 0, "enemy", true)
end)
assert(captureOk and nativePics == 1)

battle:draw()
assert(overrides == 1, "3D voxel arena was not presented")
assert(nativePics == 1, "engine picture layer doubled the projected cards")
assert(fieldFills == 1, "wide flat field was not suppressed or move flash was lost")
assert(clears >= 1, "transparent UI composition was not initialized")

print("ok standalone 3D voxel arena and single native-card layer")
