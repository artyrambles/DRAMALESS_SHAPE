-- Discover and run every public test module below tests/.
-- Protocol: return function(T) T.test("name", function() ... end) end

local function normalize(path)
  return (path:gsub("\\", "/"):gsub("/+", "/"))
end

local source = normalize(debug.getinfo(1, "S").source:gsub("^@", ""))
local toolsDir = source:match("^(.*)/[^/]+$") or "."
local Bootstrap = assert(loadfile(toolsDir .. "/test_bootstrap.lua"))()

local function shellQuote(path)
  if package.config:sub(1, 1) == "\\" then
    return '"' .. path:gsub('"', '""') .. '"'
  end
  return "'" .. path:gsub("'", "'\\''") .. "'"
end

local function discover()
  local testsRoot = Bootstrap.path("tests")
  local windows = package.config:sub(1, 1) == "\\"
  local commands
  if windows then
    commands = {
      "dir /b /s " .. shellQuote(testsRoot .. "\\test_*.lua") .. " 2>NUL",
      "dir /b /s " .. shellQuote(testsRoot .. "\\*_test.lua") .. " 2>NUL",
    }
  else
    commands = {
      "find " .. shellQuote(testsRoot)
        .. " -type f \\( -name 'test_*.lua' -o -name '*_test.lua' \\) -print 2>/dev/null",
    }
  end

  local found, seen = {}, {}
  for _, command in ipairs(commands) do
    local pipe = io.popen(command, "r")
    if pipe then
      for line in pipe:lines() do
        local path = normalize(line)
        local privateFixture = path:find("/fixtures/", 1, true)
          or path:find("/fixture/", 1, true)
          or path:find("/_fixtures/", 1, true)
          or path:find("/_fixture/", 1, true)
        if path ~= "" and not privateFixture
            and not seen[path] then
          seen[path] = true
          found[#found + 1] = path
        end
      end
      pipe:close()
    end
  end
  table.sort(found)
  return found
end

local filters = {}
for index = 1, #(arg or {}) do filters[#filters + 1] = tostring(arg[index]):lower() end

local function selected(path, name)
  if #filters == 0 then return true end
  local haystack = (path .. " " .. name):lower()
  for _, filter in ipairs(filters) do
    if haystack:find(filter, 1, true) then return true end
  end
  return false
end

local passed, failed, registered = 0, 0, 0
local files = discover()

for _, path in ipairs(files) do
  local relative = path
  local rootPrefix = normalize(Bootstrap.root) .. "/"
  if relative:sub(1, #rootPrefix) == rootPrefix then
    relative = relative:sub(#rootPrefix + 1)
  end

  local cases = {}
  local T = Bootstrap.newTestAPI(function(name, fn)
    cases[#cases + 1] = { name = name, run = fn }
  end)
  local chunk, loadErr = loadfile(path)
  if not chunk then
    failed = failed + 1
    io.stderr:write("FAIL ", relative, " :: load\n", tostring(loadErr), "\n")
  else
    local okModule, module = pcall(chunk)
    if not okModule then
      failed = failed + 1
      io.stderr:write("FAIL ", relative, " :: module\n", tostring(module), "\n")
    elseif type(module) ~= "function" then
      failed = failed + 1
      io.stderr:write("FAIL ", relative,
        " :: protocol\nexpected `return function(T) ... end`\n")
    else
      local okRegister, registerErr = pcall(module, T)
      if not okRegister then
        failed = failed + 1
        io.stderr:write("FAIL ", relative, " :: registration\n",
          tostring(registerErr), "\n")
      end
    end
  end

  for _, case in ipairs(cases) do
    if selected(relative, case.name) then
      registered = registered + 1
      local ok, err = pcall(case.run)
      if ok then
        passed = passed + 1
        io.write("PASS ", relative, " :: ", case.name, "\n")
      else
        failed = failed + 1
        io.stderr:write("FAIL ", relative, " :: ", case.name, "\n",
          tostring(err), "\n")
      end
    end
  end
end

if #files == 0 then
  failed = failed + 1
  io.stderr:write("FAIL no tests were discovered under tests/\n")
elseif registered == 0 and #filters > 0 then
  failed = failed + 1
  io.stderr:write("FAIL test filter selected no cases\n")
end

io.write(("\n%d passed, %d failed, %d selected (%d files)\n")
  :format(passed, failed, registered, #files))
if failed > 0 then os.exit(1) end
