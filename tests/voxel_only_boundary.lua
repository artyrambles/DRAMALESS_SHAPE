local function exists(path)
  local file = io.open(path, "rb")
  if file then file:close(); return true end
  return false
end

for _, path in ipairs({
  "lib/OverworldBattle.lua", "lib/BattleArt.lua", "lib/Stadium.lua",
  "lib/StadiumStage.lua", "lib/VR.lua", "assets/vr/openxr_loader.dll",
  "data/animated_battle_sprites_gen5.lua",
}) do
  assert(not exists(path), "legacy presentation file remains: " .. path)
end

local required = {
  "main.lua", "lib/VoxelBattleArenaProvider.lua", "lib/VoxelBattleScene.lua",
  "lib/VoxelBattleCardProvider.lua", "lib/VoxelBattleStandalone.lua",
  "lib/StadiumBattleFxBridge.lua", "lib/BattleCam.lua", "lib/DramalessLog.lua",
  "lib/DramalessLogExport.lua",
}
for _, path in ipairs(required) do assert(exists(path), "missing 2.0 file: " .. path) end

local manifest = assert(io.open("manifest.json", "rb")):read("*a")
assert(manifest:find('"version": "2.0.0"', 1, true))
assert(manifest:find('"experimental": true', 1, true))
assert(manifest:find('STADIUM_BATTLE_FX@<2.0.0', 1, true))

local provider = assert(io.open("lib/VoxelBattleArenaProvider.lua", "rb")):read("*a")
local scene = assert(io.open("lib/VoxelBattleScene.lua", "rb")):read("*a")
assert(provider:find("context.services.camera", 1, true),
  "arena provider does not forward the host camera")
assert(scene:find("hostCamera.pose", 1, true),
  "voxel scene does not consume the host camera")

local bridge = assert(io.open("lib/StadiumBattleFxBridge.lua", "rb")):read("*a")
assert(bridge:find('"models", "voxel-cards"', 1, true),
  "native 2D cards are not registered in Stadium's model selector")
local standalone = assert(io.open("lib/VoxelBattleStandalone.lua", "rb")):read("*a")
assert(standalone:find("StadiumBattleFX is absent", 1, true),
  "standalone 2D battle ownership is not explicitly scoped")

print("ok Dramaless 2.0 voxel environment plus narrow 2D-card boundary")
