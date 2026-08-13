local pipe = assert(io.popen([[git ls-files --cached --others --exclude-standard "*.lua"]]))
local count = 0
for path in pipe:lines() do
  if not path:match("^tests/") then
    local chunk, err = loadfile(path)
    assert(chunk, path .. ": " .. tostring(err))
    count = count + 1
  end
end
pipe:close()
local bc, bcErr = loadfile("../BattleCinematics-0.7.96-StadiumBridge/main.lua")
assert(bc, "Battle Cinematics Stadium bridge: " .. tostring(bcErr))
assert(count > 0)
print("ok compiled " .. count .. " runtime Lua files")
