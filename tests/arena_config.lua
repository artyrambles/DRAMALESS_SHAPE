-- data/battle_arenas.lua, edited in place by line.
--
-- The arena editor (tests/arena_editor.lua) writes this file back every time
-- a map is committed, and most of what is in it is PROSE: which alternatives
-- were rejected for each area and what was wrong with them. That argument is
-- the part a tool cannot reconstruct, so nothing here regenerates the file --
-- an entry that changed has its own lines replaced, a new one is appended,
-- and every other byte comes through exactly as it was.
--
-- Kept out of the driver so it can be tested without a game: a bug in here
-- writes a config file, and the failure mode of a bad one is silent -- every
-- map loses its authored spot and battles quietly start happening somewhere
-- else. `apply` therefore never decides on its own that its output is good;
-- it hands back the text and the caller parses it back and checks it says
-- what was asked for before anything is overwritten.
--
--   local Config = dofile("mods/DramaticShapeVoxelMod/tests/arena_config.lua")
--   local text, report = Config.apply(oldText, { ROUTE_1 = { x = 4, y = 14,
--                                                            shape = "narrow" } })
--
-- An edit's value is an entry table, `false` for an authored refusal, or
-- Config.REMOVE to take the entry out altogether.
local Config = {}

Config.REMOVE = setmetatable({}, { __tostring = function() return "REMOVE" end })

-- The heading new maps are collected under, so a file worked over several
-- sessions grows one list rather than one heading per session.
Config.SECTION = "  -- ------- added by tests/arena_editor"

-- Lossless both ways: a trailing newline becomes a trailing empty line, and
-- concat puts it back.
function Config.splitLines(text)
  local out, pos = {}, 1
  while true do
    local a, b = text:find("\n", pos, true)
    if not a then
      out[#out + 1] = text:sub(pos)
      break
    end
    out[#out + 1] = text:sub(pos, a - 1)
    pos = b + 1
  end
  return out
end

-- One entry, laid out the way the file already lays them out: on one line
-- where it fits inside the file's own margin, and wrapped under the brace
-- where it does not (which is how the cross-floor entries are written).
function Config.entryLines(id, entry)
  if entry == false then
    return { ("  [%q] = false,"):format(id) }
  end
  local head = ("  [%q] = { "):format(id)
  local parts = {}
  if entry.map then parts[#parts + 1] = ("map = %q"):format(entry.map) end
  parts[#parts + 1] = ("x = %d"):format(entry.x)
  parts[#parts + 1] = ("y = %d"):format(entry.y)
  parts[#parts + 1] = ("shape = %q"):format(entry.shape or "wide")
  if (entry.turn or 0) ~= 0 then
    parts[#parts + 1] = ("turn = %d"):format(entry.turn)
  end
  if entry.cam then parts[#parts + 1] = ("cam = %q"):format(entry.cam) end
  local one = head .. table.concat(parts, ", ") .. " },"
  if #one <= 79 then return { one } end
  local first = entry.map and 3 or 2
  return {
    head .. table.concat(parts, ", ", 1, first) .. ",",
    (" "):rep(#head) .. table.concat(parts, ", ", first + 1) .. " },",
  }
end

-- Where an id's entry starts and ends, plus how many comment lines sit
-- directly above it. The end is the first line that closes the table, so a
-- wrapped entry is found whole rather than half-replaced.
function Config.findEntry(lines, id)
  local pat = '^%s*%["' .. id:gsub("(%W)", "%%%1") .. '"%]%s*='
  for i = 1, #lines do
    if lines[i]:find(pat) then
      local note = 0
      while i - note - 1 >= 1 and lines[i - note - 1]:find("^%s*%-%-") do
        note = note + 1
      end
      if lines[i]:find("=%s*false%s*,?%s*$") then return i, i, note end
      for j = i, #lines do
        if lines[j]:find("}%s*,?%s*$") then return i, j, note end
      end
      return i, i, note
    end
  end
  return nil
end

-- The `}` that closes the returned table: new entries go in above it.
function Config.closingLine(lines)
  for i = #lines, 1, -1 do
    if lines[i]:find("^}") then return i end
  end
  return #lines + 1
end

-- Apply `edits` (map id -> entry | false | REMOVE) to `text`.
--
-- Returns the new text and a report: `changed`, `added`, `removed` and
-- `stale` as lists of map ids. `stale` is the one worth acting on -- those
-- entries had comment lines directly above them, and a comment above an
-- entry that has just moved describes where it USED to be.
function Config.apply(text, edits)
  local lines = Config.splitLines(text)
  local report = { changed = {}, added = {}, removed = {}, stale = {} }

  local ordered = {}
  for id in pairs(edits) do ordered[#ordered + 1] = id end
  table.sort(ordered)

  local appended = {}
  for _, id in ipairs(ordered) do
    local entry = edits[id]
    -- found again per edit rather than indexed once up front: each
    -- replacement changes the line count under every index after it
    local from, to, note = Config.findEntry(lines, id)
    if entry == Config.REMOVE then
      if from then
        for _ = from, to do table.remove(lines, from) end
        report.removed[#report.removed + 1] = id
        if note > 0 then report.stale[#report.stale + 1] = id end
      end
    elseif from then
      local new = Config.entryLines(id, entry)
      for _ = from, to do table.remove(lines, from) end
      for k = #new, 1, -1 do table.insert(lines, from, new[k]) end
      report.changed[#report.changed + 1] = id
      if note > 0 then report.stale[#report.stale + 1] = id end
    else
      appended[#appended + 1] = id
      report.added[#report.added + 1] = id
    end
  end

  if #appended > 0 then
    local at, block = nil, {}
    for i = 1, #lines do
      if lines[i]:find("^%s*%-%-%s+%-+ added by tests/arena_editor") then
        at = i + 1
      end
    end
    if not at then
      at = Config.closingLine(lines)
      block[#block + 1] = ""
      block[#block + 1] = Config.SECTION
    end
    for _, id in ipairs(appended) do
      for _, l in ipairs(Config.entryLines(id, edits[id])) do
        block[#block + 1] = l
      end
    end
    for k = #block, 1, -1 do table.insert(lines, at, block[k]) end
  end

  return table.concat(lines, "\n"), report
end

-- Whether two entries say the same thing. `false` and nil are values here --
-- a refusal is not the absence of one -- so this is an equality test and not
-- a truthiness one.
function Config.same(a, b)
  if a == b then return true end
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  return a.x == b.x and a.y == b.y
     and (a.shape or "wide") == (b.shape or "wide")
     and (a.turn or 0) == (b.turn or 0)
     and a.cam == b.cam and a.map == b.map
end

-- Parse a config back and check it says what was committed. This is what
-- stands between a bug in the surgery above and a data file that no longer
-- loads, so it is run on the TEXT before that text replaces anything.
-- Returns the parsed table, or nil and why not.
function Config.verify(text, edits, chunkName)
  local chunk, err = load(text, "@" .. (chunkName or "battle_arenas"))
  if not chunk then return nil, "would not compile: " .. tostring(err) end
  local ok, list = pcall(chunk)
  if not (ok and type(list) == "table") then
    return nil, "did not return a table: " .. tostring(list)
  end
  for id, want in pairs(edits) do
    local got = list[id]
    if want == Config.REMOVE then
      if got ~= nil then return nil, id .. " is still in the file" end
    elseif not Config.same(want, got) then
      return nil, id .. " did not read back as it was committed"
    end
  end
  return list
end

return Config
