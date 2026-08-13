-- Persistent structured diagnostics for Dramaless and its provider bridge.

local V = ...
local Log = {}
Log.__index = Log
local PATH = "dramaless_shape/dramaless_shape.log"
local MAX_LINES = 1200

local function clean(value)
  return tostring(value == nil and "nil" or value):gsub("[\r\n\t]+", " "):gsub("%s+", " ")
end

local function now()
  return os and os.date and os.date("!%Y-%m-%dT%H:%M:%SZ") or "runtime"
end

function Log.new(host)
  local self = setmetatable({ host = host, lines = {} }, Log)
  local fs = love and love.filesystem
  if fs and fs.read and fs.getInfo and fs.getInfo(PATH, "file") then
    local ok, contents = pcall(fs.read, PATH)
    if ok and type(contents) == "string" then
      for line in contents:gmatch("[^\r\n]+") do self.lines[#self.lines + 1] = line end
    end
  end
  return self
end

function Log:flush()
  local fs = love and love.filesystem
  if not (fs and fs.createDirectory and fs.write) then return false end
  if fs.createDirectory("dramaless_shape") == false then return false end
  return pcall(fs.write, PATH, table.concat(self.lines, "\n") .. "\n")
end

function Log:record(level, message, ...)
  local formatted = tostring(message)
  if select("#", ...) > 0 then
    local ok, value = pcall(string.format, formatted, ...)
    if ok then formatted = value end
  end
  local line = ("%s [%s] %s"):format(now(), level, clean(formatted))
  self.lines[#self.lines + 1] = line
  while #self.lines > MAX_LINES do table.remove(self.lines, 1) end
  self:flush()
  local fn = self.host and self.host[level:lower()]
  if type(fn) == "function" then pcall(fn, self.host, "%s", line) end
  return line
end

function Log:info(message, ...) return self:record("INFO", message, ...) end
function Log:warn(message, ...) return self:record("WARN", message, ...) end
function Log:error(message, ...) return self:record("ERROR", message, ...) end

function Log:event(scope, name, fields)
  local parts = {}
  for key, value in pairs(type(fields) == "table" and fields or {}) do
    parts[#parts + 1] = clean(key) .. "=" .. clean(value)
  end
  table.sort(parts)
  return self:info("[%s] %s%s", clean(scope), clean(name),
    #parts > 0 and (" " .. table.concat(parts, " ")) or "")
end

function Log:scope(scope)
  local parent = self
  return {
    info = function(_, message, ...) return parent:info("[%s] " .. message, scope, ...) end,
    warn = function(_, message, ...) return parent:warn("[%s] " .. message, scope, ...) end,
    error = function(_, message, ...) return parent:error("[%s] " .. message, scope, ...) end,
    event = function(_, name, fields) return parent:event(scope, name, fields) end,
  }
end

function Log:contents() return table.concat(self.lines, "\n") .. "\n" end
return Log
