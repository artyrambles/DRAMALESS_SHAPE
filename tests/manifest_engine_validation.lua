package.path = "../Gen1Recomp/?.lua;../Gen1Recomp/?/init.lua;" .. package.path
local Manifest = require("src.mods.Manifest")
local Semver = require("src.mods.Semver")
local Json = require("src.link.Json")

local function decode(path)
  local file = assert(io.open(path, "rb"))
  local text = file:read("*a")
  file:close()
  return Json.decode(text)
end

local dramaless = Manifest.validate(decode("manifest.json"), "mods/DRAMALESS_SHAPE")
local stadium = Manifest.validate(decode("../StadiumBattleFX/manifest.json"),
  "mods/STADIUM_BATTLE_FX")
local cinematics = Manifest.validate(
  decode("../BattleCinematics-0.7.96-StadiumBridge/manifest.json"),
  "mods/BATTLE_CINEMATICS")
assert(dramaless.version == "2.0.0" and stadium.version == "2.0.0")
assert(dramaless.optionalSpecs[1].id == "STADIUM_BATTLE_FX")
assert(Semver.satisfies("2.0.0", dramaless.optionalSpecs[1].range))
assert(not Semver.satisfies("1.6.4", dramaless.optionalSpecs[1].range))
assert(dramaless.conflictSpecs[#dramaless.conflictSpecs].range == "<2.0.0")
assert(stadium.conflictSpecs[1].id == "DRAMALESS_SHAPE")
assert(Semver.satisfies("1.6.4", stadium.conflictSpecs[1].range))
assert(not Semver.satisfies("2.0.0", stadium.conflictSpecs[1].range))
assert(cinematics.version == "0.7.96-sbfx.1")
assert(cinematics.optionalSpecs[1].id == "STADIUM_BATTLE_FX")
assert(Semver.satisfies("2.0.0", cinematics.optionalSpecs[1].range))
assert(not Semver.satisfies("1.1.2", cinematics.optionalSpecs[1].range))
assert(#stadium.optionalSpecs == 0,
  "Stadium must not create an optional-dependency cycle with Battle Cinematics")
print("ok Gen1Recomp validates 2.0 manifests and mixed-version gates")
