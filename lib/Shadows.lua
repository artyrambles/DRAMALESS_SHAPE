-- Global cast-shadow switch for both free roam and staged battles.
--
-- Keep the persisted key compatible with the mobile/quality fork, whose
-- larger LOW/HIGH/SOFT ladder also uses `shadowQuality`. This branch exposes
-- only the distinction it actually implements: the existing full shadow-map
-- path, or no shadow-map path.

local V = ...

local ModSetting = V.require("ModSetting")

local Shadows = {}

Shadows.setting = ModSetting.new("shadowQuality", "SHADOWS",
                                 { "high", "off" },
                                 { "ON", "OFF" })

function Shadows.enabled()
  return Shadows.setting:get() ~= "off"
end

function Shadows.off()
  return not Shadows.enabled()
end

return Shadows
