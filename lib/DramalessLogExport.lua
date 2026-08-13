-- Cross-platform diagnostic-log export, including SteamOS desktop/game mode.

local V = ...
local Export = {}
local NAME = "DramalessShape-log.txt"
local last = { state = "EXPORT" }

local function osName()
  local ok, value = pcall(function() return love.system.getOS() end)
  return ok and value or nil
end

local function output(command)
  local ok, pipe = pcall(io.popen, command)
  if not (ok and pipe) then return nil end
  local readOk, value = pcall(pipe.read, pipe, "*a")
  pcall(pipe.close, pipe)
  value = readOk and type(value) == "string" and value:gsub("^%s+", ""):gsub("%s+$", "")
  return value ~= "" and value or nil
end

local function destination()
  local platform = osName()
  if platform == "Windows" then
    return output([[powershell -NoProfile -STA -Command "Add-Type -AssemblyName System.Windows.Forms;$d=New-Object System.Windows.Forms.SaveFileDialog;$d.FileName='DramalessShape-log.txt';$d.Filter='Text log (*.txt)|*.txt';if($d.ShowDialog() -eq 'OK'){[Console]::Write($d.FileName)}"]])
  elseif platform == "OS X" then
    return output([[osascript -e 'POSIX path of (choose file name with default name "DramalessShape-log.txt")' 2>/dev/null]])
  elseif platform == "Linux" then
    local display = os.getenv("DISPLAY") or os.getenv("WAYLAND_DISPLAY")
    if display and output("command -v zenity 2>/dev/null") then
      return output([[zenity --file-selection --save --confirm-overwrite --filename="DramalessShape-log.txt" 2>/dev/null]])
    end
    if display and output("command -v kdialog 2>/dev/null") then
      return output([[kdialog --getsavefilename "$HOME/DramalessShape-log.txt" "*.txt|Text log" 2>/dev/null]])
    end
    local downloads = output("xdg-user-dir DOWNLOAD 2>/dev/null")
    if downloads then return downloads .. "/" .. NAME end
    local home = os.getenv("HOME")
    if home and home ~= "" then return home .. "/Downloads/" .. NAME end
  end
  --local ok, save = pcall(function() return love.filesystem.getSaveDirectory() end)
  --return ok and save and (save .. "/" .. NAME) or nil
  return nil
end

function Export.export()
  local path = destination()
  if not path then last = { state = "CANCELLED" }; return false end
  local file = io.open(path, "wb")
  if not file and osName() == "Linux" then
    --local ok, save = pcall(function() return love.filesystem.getSaveDirectory() end)
    --if ok and save then path = save .. "/" .. NAME; file = io.open(path, "wb") end
  end
  if not file then last = { state = "FAILED" }; return false end
  local wrote, writeErr = pcall(file.write, file, V.log:contents())
  local closed, closeErr = pcall(file.close, file)
  if not (wrote and closed) then
    last = { state = "FAILED" }
    V.log:event("logging", "export-failed", {
      platform = osName() or "unknown", error = writeErr or closeErr,
    })
    return false
  end
  last = { state = "SAVED", path = path }
  V.log:event("logging", "exported", { platform = osName() or "unknown" })
  return true
end

function Export.row()
  return {
    id = "DRAMALESS_SHAPE:exportLog", label = "EXPORT DIAGNOSTIC LOG",
    value = function() return last.state end,
    step = function() return Export.export() end,
  }
end

return Export
