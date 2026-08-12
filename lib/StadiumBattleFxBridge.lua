-- Optional registration bridge from Dramaless 2.x to StadiumBattleFX API 1.
-- Dramaless contributes its voxel-map arena and its narrow native-2D-card
-- provider. StadiumBattleFX remains the selector and lifecycle host.

local V = ...
local Bridge = {
  registered = false,
  id = nil,
  modelId = nil,
  lastError = nil,
}

local function host()
  local mod = V and V.mod
  if not (mod and type(mod.find) == "function") then return nil end
  local ok, found = pcall(mod.find, "STADIUM_BATTLE_FX")
  if not ok or not found then return nil end
  local api = found.exports and found.exports.battles
  if not (api and api.version == 1
      and type(api.registerComponent) == "function") then return nil end
  return api
end

function Bridge.register(arenaProvider, cardProvider)
  if Bridge.registered then return true, Bridge.id, Bridge.modelId end
  if type(arenaProvider) ~= "table" then
    Bridge.lastError = "voxel arena provider is required"
    return false, Bridge.lastError
  end
  local api = host()
  if not api then
    Bridge.lastError = "StadiumBattleFX battle API 1 is unavailable"
    return false, Bridge.lastError
  end
  V.stadiumBattleApi = api
  local ok, id = pcall(api.registerComponent, api,
    "DRAMALESS_SHAPE", "arena", "voxel-map", {
      label = "VOXEL MAP",
      description = "Stages battles in the current Dramaless voxel environment",
      provider = arenaProvider,
      available = function(context)
        if type(arenaProvider.available) ~= "function" then return true end
        return arenaProvider:available(context)
      end,
    })
  if not ok then
    Bridge.lastError = tostring(id)
    return false, Bridge.lastError
  end
  Bridge.id = id

  if type(cardProvider) == "table" then
    local modelsOk, modelId = pcall(api.registerComponent, api,
      "DRAMALESS_SHAPE", "models", "voxel-cards", {
        label = "VOXEL 2D CARDS",
        description = "Uses Gen 1 battle pictures as arena-positioned cards",
        provider = cardProvider,
        available = function(context)
          if type(cardProvider.available) ~= "function" then return true end
          return cardProvider:available(context)
        end,
      })
    if not modelsOk then
      Bridge.lastError = tostring(modelId)
      return false, Bridge.lastError
    end
    Bridge.modelId = modelId
  end

  Bridge.registered, Bridge.lastError = true, nil
  return true, Bridge.id, Bridge.modelId
end

function Bridge.retry(arenaProvider, cardProvider)
  if Bridge.registered then return true, Bridge.id, Bridge.modelId end
  return Bridge.register(arenaProvider, cardProvider)
end

return Bridge
