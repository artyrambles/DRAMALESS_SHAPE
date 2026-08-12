local selected = {
  provider_arena = "DRAMALESS_SHAPE:voxel-map",
  provider_models = "DRAMALESS_SHAPE:voxel-cards",
}
local stadiumNamespace = {
  mod = {
    id = "STADIUM_BATTLE_FX",
    options = { get = function(_, key) return selected[key] end },
    find = function(_, id)
      if id == "DRAMALESS_SHAPE" then return { id = id } end
    end,
  },
  log = { info = function() end, warn = function() end },
}
local registryChunk = assert(loadfile("../StadiumBattleFX/lib/BattleProviders.lua"))
local api = registryChunk(stadiumNamespace)
local registrationApi = {
  version = api.VERSION,
  FALLBACK = api.FALLBACK,
  registerComponent = function(_, owner, slot, id, definition)
    return api.registerComponent(owner, slot, id, definition)
  end,
}

local provider = { available = function() return true end }
local cards = { available = function() return true end }
local bridgeChunk = assert(loadfile("lib/StadiumBattleFxBridge.lua"))
local bridge = bridgeChunk({
  mod = { find = function(id)
    if id == "STADIUM_BATTLE_FX" then
      return { exports = { battles = registrationApi } }
    end
  end },
})
local ok, id, modelId = bridge.register(provider, cards)
assert(ok and id == "DRAMALESS_SHAPE:voxel-map")
local resolved, entry = api.resolve("arena", {})
assert(resolved == provider and entry.id == id)
assert(#api.componentList("arena") == 1)
local resolvedModels, modelEntry = api.resolve("models", {})
assert(resolvedModels == cards and modelEntry.id == modelId)
assert(#api.componentList("models") == 1)
print("ok real Stadium registry accepts Dramaless arena and card providers")
