-- Compile every module touched by the battle-preset integration. This catches
-- syntax regressions without constructing the graphics-heavy runtime modules.

for _, path in ipairs({
  "lib/BattlePresets.lua",
  "lib/ModSetting.lua",
  "lib/OverworldBattle.lua",
  "lib/BattleScene.lua",
  "lib/Stadium.lua",
  "main.lua",
}) do
  local chunk, err = loadfile(path)
  assert(chunk, path .. ": " .. tostring(err))
end

print("ok battle preset syntax")
