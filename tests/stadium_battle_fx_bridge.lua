local function loader(path)
  local chunk, err = loadfile(path)
  if chunk then return chunk end
  -- if love and love.filesystem and love.filesystem.load then
  --   return love.filesystem.load(path)
  -- end
  return nil, err
end
local registrations = {}
local api = {
  version = 1,
  registerComponent = function(_, owner, slot, id, definition)
    registrations[#registrations + 1] = { owner, slot, id, definition }
    return owner .. ":" .. id
  end,
}
local provider = { available = function() return true end }
local cards = { available = function() return true end }
local Bridge = assert(loader("lib/StadiumBattleFxBridge.lua"))({
  mod = {
    find = function(id)
      assert(id == "STADIUM_BATTLE_FX")
      return { exports = { battles = api } }
    end,
    log = { info = function() end },
  },
})

local ok, id, modelId = Bridge.register(provider, cards)
assert(ok and id == "DRAMALESS_SHAPE:voxel-map")
assert(modelId == "DRAMALESS_SHAPE:voxel-cards")
local arena = registrations[1]
local models = registrations[2]
assert(arena[1] == "DRAMALESS_SHAPE" and arena[2] == "arena")
assert(arena[3] == "voxel-map" and arena[4].provider == provider)
assert(arena[4].available({}) == true)
assert(models[1] == "DRAMALESS_SHAPE" and models[2] == "models")
assert(models[3] == "voxel-cards" and models[4].provider == cards)
assert(models[4].available({}) == true)
assert(Bridge.retry(provider, cards) and Bridge.registered)
print("ok optional StadiumBattleFX API-1 bridge")
