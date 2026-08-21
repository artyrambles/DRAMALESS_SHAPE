-- Shared zero-dependency test support for LuaJIT 2.x / Lua 5.1.

local Bootstrap = {}

local function normalize(path)
  return (path:gsub("\\", "/"):gsub("/+", "/"))
end

local source = debug.getinfo(1, "S").source:gsub("^@", "")
source = normalize(source)
local toolsDir = source:match("^(.*)/[^/]+$") or "."
Bootstrap.root = toolsDir:match("^(.*)/tools$") or "."

function Bootstrap.path(relative)
  relative = normalize(relative)
  if relative:sub(1, 1) == "/" or relative:match("^%a:/") then return relative end
  return normalize(Bootstrap.root .. "/" .. relative)
end

function Bootstrap.read(relative)
  local path = Bootstrap.path(relative)
  local file, err = io.open(path, "rb")
  if not file then error(("cannot read %s: %s"):format(path, tostring(err)), 2) end
  local body = file:read("*a")
  file:close()
  return body
end

function Bootstrap.loadFile(relative)
  local path = Bootstrap.path(relative)
  local chunk, err = loadfile(path)
  if not chunk then error(("cannot load %s: %s"):format(path, tostring(err)), 2) end
  return chunk()
end

function Bootstrap.loadCore(name)
  assert(type(name) == "string" and name:match("^[%w_]+$"), "invalid core module name")
  return Bootstrap.loadFile("src/core/" .. name .. ".lua")
end

local function render(value)
  if type(value) == "string" then return string.format("%q", value) end
  return tostring(value)
end

local function fail(message, level)
  error(message, (level or 1) + 1)
end

local function deepEqual(actual, expected, seen, path)
  if actual == expected then return true end
  if type(actual) ~= type(expected) then
    return false, path .. ": types differ (" .. type(actual) .. " vs "
      .. type(expected) .. ")"
  end
  if type(actual) ~= "table" then
    return false, path .. ": " .. render(actual) .. " ~= " .. render(expected)
  end
  seen = seen or {}
  if seen[actual] then
    if seen[actual] == expected then return true end
    return false, path .. ": table cycle differs"
  end
  seen[actual] = expected
  for key, value in pairs(actual) do
    local ok, err = deepEqual(value, expected[key], seen,
      path .. "[" .. render(key) .. "]")
    if not ok then return false, err end
  end
  for key in pairs(expected) do
    if actual[key] == nil and expected[key] ~= nil then
      return false, path .. ": missing key " .. render(key)
    end
  end
  return true
end

function Bootstrap.newTestAPI(register)
  local T = { root = Bootstrap.root, read = Bootstrap.read,
              path = Bootstrap.path, loadFile = Bootstrap.loadFile,
              loadCore = Bootstrap.loadCore }

  function T.test(name, fn)
    assert(type(name) == "string" and name ~= "", "test needs a name")
    assert(type(fn) == "function", "test needs a function")
    register(name, fn)
  end

  function T.equal(actual, expected, message)
    if actual ~= expected then
      fail(message or (render(actual) .. " ~= " .. render(expected)), 1)
    end
    return actual
  end

  function T.notEqual(actual, expected, message)
    if actual == expected then
      fail(message or (render(actual) .. " unexpectedly equals " .. render(expected)), 1)
    end
    return actual
  end

  function T.deepEqual(actual, expected, message)
    local ok, err = deepEqual(actual, expected, {}, "value")
    if not ok then fail(message or err, 1) end
    return actual
  end

  function T.truthy(value, message)
    if not value then fail(message or "expected a truthy value", 1) end
    return value
  end

  function T.falsy(value, message)
    if value then fail(message or "expected a falsy value", 1) end
    return value
  end

  function T.near(actual, expected, epsilon, message)
    epsilon = epsilon or 1e-9
    if type(actual) ~= "number" or math.abs(actual - expected) > epsilon then
      fail(message or (render(actual) .. " is not near " .. render(expected)), 1)
    end
    return actual
  end

  function T.raises(fn, pattern, message)
    local ok, err = pcall(fn)
    if ok then fail(message or "expected an error", 1) end
    if pattern and not tostring(err):match(pattern) then
      fail(message or ("error did not match %q: %s"):format(pattern, tostring(err)), 1)
    end
    return err
  end

  return T
end

Bootstrap.normalize = normalize

return Bootstrap
