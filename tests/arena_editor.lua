-- Driver: the interactive battle-arena editor.
--
-- data/battle_arenas.lua holds one authored spot per area -- where that map's
-- 3D battles are staged. tests/arena_pick.lua AUTHORS that file in a batch:
-- it takes the search's answer for every map, photographs each one, and
-- leaves a pile of PNGs and PICK lines to be read afterwards. This is the
-- other way round. It is one window you sit in front of: pick a map, slide
-- the arena around on a plan of it, watch the fit and the sightlines answer
-- as you move, stage a REAL battle on the spot to see what the shot actually
-- looks like, and commit. Committing rewrites the config.
--
-- The plan is the MAP'S OWN ART -- the tiles extracted from the cartridge,
-- drawn from the game's own atlas through the game's own palette -- with the
-- walk grid washed over it, because "where may an arena stand" and "what is
-- it standing in" are two different questions and a spot has to answer both.
--
--   POKEPORT_DRIVER=mods/DramaticShapeVoxelMod/tests/arena_editor.lua \
--     "/c/Program Files/LOVE/lovec.exe" .
--
-- from the PROJECT ROOT, with this mod enabled. lovec rather than love, so
-- the console is attached: every commit prints its line there too, and the
-- console transcript alone is enough to redo a session by hand.
--
-- ------- the keys
--
--   arrows      move the arena's north-west corner (hold shift for 5 cells)
--   [  ]        previous / next map
--   s           cycle the SHAPE -- wide (3x6, with the apron) or narrow (1x4)
--   r           TURN the whole staging a quarter (shift: the other way) --
--               footprint, both mons and the camera together, so the picture
--               is unchanged and only the ground under it moves. What it is
--               for: a long arena down a corridor that runs east-west, and
--               swapping what stands behind the pair
--   c           cycle the LENS -- the long default, or cam = "wide"
--   h           cycle the HOST map: stage this map's fight on a sibling floor
--   w           water counts as ground for the search (the surf routes)
--   g           what the plan shows: the map's own tiles, the walk grid over
--               them, or the walk grid alone
--   f           scan this map for every arena that fits, clear ones first
--   n  p        step through that scan
--   a           jump to the automatic pick (what arena_pick would have said)
--   u           back to whatever the config file holds for this map
--   t           TEST: stage a real battle here and look at it
--   y           screenshot
--   enter       COMMIT this map (shift+enter: commit and go to the next map)
--   backspace   commit a REFUSAL: nowhere on this map a fight can be seen
--   delete      commit a REMOVAL: no entry, so battle time falls back to the
--               nearest-clear search
--   e           export now (a commit exports on its own; this is for after a
--               revert, or just to be sure)
--   F1          the key legend on screen
--   escape      quit (in TEST, back to the editor)
--
-- In TEST every key except t / escape / y goes to the GAME, so the fight is
-- driven with the game's own buttons and the camera steered with the mod's
-- own Q/E and mouse -- what you are judging is the shot a player gets.
--
-- ------- what it writes
--
-- The export is data/battle_arenas.lua REWRITTEN LINE BY LINE rather than
-- regenerated: an entry that changed has its lines replaced in place, a new
-- one is appended, and every other line of that file -- which is mostly the
-- prose explaining why each spot is the spot -- comes through untouched. A
-- comment sitting directly above a replaced entry describes the OLD spot, so
-- each of those is reported by id at export time and is yours to re-word.
--
-- It lands in .scratchpad/arena_editor/battle_arenas.lua by default, so a
-- session is a file to diff and copy over rather than an edit to the mod
-- under a running game. ARENA_WRITE=1 writes to data/battle_arenas.lua
-- itself, keeping a .bak of what was there. Either way the written text is
-- parsed back and checked against what was committed BEFORE it replaces
-- anything -- a tool that writes a config file must never be the reason one
-- stops loading.
--
-- Re-run and the session resumes: the export is a complete config, so it is
-- read back as the base when it exists (ARENA_FRESH=1 starts from the mod's
-- own file instead).
--
-- ------- environment
--
--   ARENA_MAPS=ID,ID   work this list instead of every map a fight happens on
--   ARENA_OUT=path     where the config is written
--   ARENA_WRITE=1      write to data/battle_arenas.lua (keeps a .bak)
--   ARENA_FRESH=1      ignore an existing export and start from the mod's file
--   ARENA_MON=SPECIES  what to fight in TEST (default NIDORINO)
--   ARENA_LEVEL=N      its level (default 20)
--   ARENA_RUNG=N       the voxel angle rung to sit on (default 3)
--   ARENA_MARGIN=N     keep the scan this far off the map's edge (default: 2
--                      outdoors, where the outermost cells are the connection
--                      border, and 0 indoors)
--   SHOT_DIR=path      screenshots and the default export directory
return function(game)
  local U = dofile("tests/drivers/util.lua")
  -- the config's line surgery, kept in its own file so it can be tested
  -- without a game (see the header there)
  local Config = dofile("mods/DramaticShapeVoxelMod/tests/arena_config.lua")

  local function truthy(v) return v ~= nil and v ~= "" and v ~= "0" end

  local DIR = os.getenv("SHOT_DIR")
  if not DIR or DIR == "" then DIR = ".scratchpad/arena_editor" end
  local DATA = "mods/DramaticShapeVoxelMod/data/battle_arenas.lua"
  local IN_PLACE = truthy(os.getenv("ARENA_WRITE"))
  local OUT = os.getenv("ARENA_OUT")
  if not OUT or OUT == "" then
    OUT = IN_PLACE and DATA or (DIR .. "/battle_arenas.lua")
  end
  local FRESH = truthy(os.getenv("ARENA_FRESH"))
  local SELFTEST = truthy(os.getenv("ARENA_SELFTEST"))
  if SELFTEST then
    -- never the mod's own file, whatever the environment says: the check runs
    -- unattended and its whole point is that it can be thrown away
    IN_PLACE = false
    OUT = DIR .. "/selftest_battle_arenas.lua"
    FRESH = true          -- and always from the mod's own file, so a rerun
  end                     -- checks the same surgery on the same text
  local SPECIES = os.getenv("ARENA_MON")
  if not SPECIES or SPECIES == "" then SPECIES = "NIDORINO" end
  local LEVEL = tonumber(os.getenv("ARENA_LEVEL") or "") or 20
  local RUNG = tonumber(os.getenv("ARENA_RUNG") or "") or 3
  local MARGIN = tonumber(os.getenv("ARENA_MARGIN") or "")

  -- SHOT_DIR is created with both spellings: U.shot's own mkdir is
  -- Unix-flavoured and silently does nothing on Windows, which is where this
  -- tool is driven from, and a screenshot that never reaches disk is the one
  -- failure a screenshot tool must not have.
  -- U.shot's own mkdir is Unix-flavoured, and this tool is driven from
  -- Windows, where `2>/dev/null` is cmd.exe being asked to redirect into a
  -- directory that does not exist -- which prints "the system cannot find the
  -- path specified" for every call and creates nothing. So the shell is asked
  -- in its own language.
  local WINDOWS = love.system and love.system.getOS() == "Windows"

  local function mkdirp(dir)
    if not dir or dir == "" then return end
    if WINDOWS then
      os.execute('if not exist "' .. dir:gsub("/", "\\") .. '" mkdir "'
                 .. dir:gsub("/", "\\") .. '"')
    else
      os.execute('mkdir -p "' .. dir .. '" 2>/dev/null')
    end
  end
  mkdirp(DIR)

  local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local text = f:read("*a")
    f:close()
    return text
  end

  local function writeFile(path, text)
    mkdirp(path:match("^(.*)[/\\][^/\\]+$"))
    local f = io.open(path, "wb")
    if not f then return false end
    f:write(text)
    f:close()
    return true
  end

  -- ------- the mod, and the modes this tool needs it in

  local exports = game.mods and game.mods.exports
  local lib = exports and exports.DRAMALESS_SHAPE and exports.DRAMALESS_SHAPE.lib
  if not lib then
    U.log("DRAMALESS_SHAPE is not loaded -- enable it and run again")
    return
  end
  local Arena = lib.require("BattleArena")
  local Battles = lib.require("OverworldBattle")
  local BattleCam = lib.require("BattleCam")
  local DayNight = lib.require("DayNight")
  local ChunkMesher = lib.require("ChunkMesher")
  local Voxel3D = lib.require("Voxel3D")
  local Pipelines = require("src.render.Pipelines")
  local PaletteFX = require("src.render.PaletteFX")
  local BattleState = require("src.battle.BattleState")
  local Pokemon = require("src.pokemon.Pokemon")
  local MapLoader = require("src.world.MapLoader")
  local Map = require("src.world.Map")

  game.save.party = { Pokemon.new(game.data, "CHARIZARD", 45) }
  game.save.player.name = "RED"

  -- Every mod setting is set WITHOUT a game argument, deliberately: passing
  -- one persists the value into the player's own options file, and a tool
  -- that is borrowing their install for an hour should not come back out
  -- having changed what they play with. ModSetting caches the index it is
  -- given, which is what every reader asks, so the modes are live for this
  -- process and stored nowhere.
  Battles.setting:setValue(true)             -- 2D-3D A: the fight on the map
  Battles.backSetting:setValue(false)        -- both mons out there on it
  DayNight.setting:setValue("day")           -- one light to judge them all in
  -- the rung IS persisted by the engine's own registry, so it is noted here
  -- and put back on the way out
  local wasRung = Pipelines.level("voxel")
  Pipelines.setLevel("voxel", RUNG)
  if not Voxel3D.available() then
    U.log("no 3D pass available here -- the editor still picks and exports, "
          .. "but TEST will draw the flat battle screen")
  end

  -- ------- which maps get a spot
  --
  -- The same filter arena_pick uses, and for the same reason: authoring a
  -- spot for a shop floor is authoring a spot for a fight that never happens
  -- there. The encounter tables are their own registry keyed by map id, NOT a
  -- field on the map record -- reading def.encounters answers nil for every
  -- map in the game and silently narrows this to trainer maps alone.
  local function fights(id, def)
    local enc = game.data.encounters and game.data.encounters[id]
    if enc then
      for _, kind in ipairs({ "grass", "water" }) do
        local t = enc[kind]
        if t and (t.rate or 0) > 0 and t.slots and t.slots[1] then
          return true
        end
      end
    end
    for _, obj in ipairs(def.objects or {}) do
      if obj.trainer or obj.trainerClass or obj.species then return true end
    end
    return false
  end

  local ids = {}
  local explicit = os.getenv("ARENA_MAPS")
  if explicit and explicit ~= "" then
    for id in explicit:gmatch("[^,%s]+") do ids[#ids + 1] = id end
  else
    for id, def in pairs(game.data.maps) do
      if type(id) == "string" and type(def) == "table" and fights(id, def) then
        ids[#ids + 1] = id
      end
    end
    table.sort(ids)
  end
  if #ids == 0 then
    U.log("no maps to work on")
    return
  end

  -- ------- the config this session starts from
  --
  -- The export is a complete config file, so when one is already there it is
  -- what we read back: a session that ran out of evening resumes exactly
  -- where it stopped, and the file being rewritten is the same one being
  -- read, which keeps the prose in it accumulating rather than reverting.
  local baseFrom = OUT
  local baseText = (not FRESH) and readFile(OUT) or nil
  if not baseText then
    baseFrom = DATA
    baseText = readFile(DATA)
  end
  local base = {}
  if baseText then
    local chunk = load(baseText, "@" .. baseFrom)
    local ok, list = pcall(chunk)
    if ok and type(list) == "table" then
      base = list
    else
      U.log(("could not read %s (%s) -- starting from an empty config")
            :format(baseFrom, tostring(list)))
      baseText = "return {\n}\n"
      baseFrom = "(empty)"
    end
  else
    U.log("no config file found -- starting from an empty one")
    baseText = "return {\n}\n"
    baseFrom = "(empty)"
  end
  U.log(("base config: %s (%d maps)"):format(baseFrom, (function()
    local n = 0
    for _ in pairs(base) do n = n + 1 end
    return n
  end)()))

  -- What this session has decided, per map id: an entry table, `false` for a
  -- refusal, or REMOVE for "take the entry out and let the search answer".
  -- Kept apart from `base` so the export knows which lines it may touch.
  local REMOVE = Config.REMOVE
  local edits = {}
  local sameEntry = Config.same

  local backedUp = false

  -- Apply every committed edit to the base text and write it out. Returns
  -- ok, message.
  local function export()
    local n = 0
    for _ in pairs(edits) do n = n + 1 end
    local text, report = Config.apply(baseText, edits)

    -- Parsed back and checked against what was committed BEFORE it replaces
    -- anything. A config file this tool has made unloadable would take the
    -- authored spot away from every map in the game, and the failure would
    -- turn up as battles quietly happening somewhere else.
    local list, why = Config.verify(text, edits, OUT)
    if not list then return false, why end

    if IN_PLACE and not backedUp then
      if writeFile(DATA .. ".bak", baseText) then
        U.log("kept the original at " .. DATA .. ".bak")
      end
      backedUp = true
    end
    if not writeFile(OUT, text) then
      return false, "could not open " .. OUT .. " for writing"
    end

    -- the written file becomes the base, so the next export edits the text it
    -- just produced and every edit is applied exactly once
    baseText, base, edits = text, list, {}

    if #report.added > 0 then
      U.log("ADDED  " .. table.concat(report.added, ", "))
    end
    if #report.removed > 0 then
      U.log("REMOVED  " .. table.concat(report.removed, ", "))
    end
    if #report.stale > 0 then
      U.log("NOTE   these entries had comments above them that describe the "
            .. "spot they USED to be: " .. table.concat(report.stale, ", "))
    end
    return true, ("wrote %s (%d %s)"):format(OUT, n, n == 1 and "map" or "maps")
  end

  -- ------- the editor's state

  local S = {
    i = 1,                  -- which map, into ids
    map = nil,              -- the live Map for it
    pick = nil,             -- the working spot: a table, false, or nil
    fits = false,           -- does its footprint lie on open ground
    clear = false,          -- would both mons be seen from the battle camera
    arena = nil,            -- the arena record the two above were judged on
    host = nil,             -- the map that arena stands on (a sibling floor)
    cands = nil,            -- the last scan
    ci = 0,
    surf = false,           -- water counts as ground for the search
    mode = "edit",
    msg = "",
    legend = true,
    planMode = 1,           -- the map's own tiles, with the walk grid over
    tiles = nil,            -- that map, baked from its own tileset
    shooting = false,       -- the overlay stands aside for a screenshot
    quit = false,
    done = {},              -- ids committed at some point this session
    doneN = 0,
    overrideOn = nil,       -- the map whose entry we have forced, if any
  }

  local queue = {}
  local function post(cmd, arg) queue[#queue + 1] = { cmd = cmd, arg = arg } end
  local function say(fmt, ...)
    S.msg = select("#", ...) > 0 and fmt:format(...) or fmt
  end

  local function mapId() return ids[S.i] end

  local hosts = {}
  local function hostMap(id)
    if id == nil or (S.map and id == S.map.id) then return S.map end
    if hosts[id] ~= nil then return hosts[id] or nil end
    local ok, m = pcall(MapLoader.load, game.data, id)
    hosts[id] = (ok and m) or false
    return hosts[id] or nil
  end

  local function shapeFor(id)
    for _, s in ipairs(Arena.SHAPES) do
      if s.id == (id or "wide") then return s end
    end
    return Arena.SHAPES[1]
  end

  -- Does this spot's whole footprint lie on ground an arena may be laid on?
  --
  -- Water counts, whatever the player is doing, because that is what
  -- BattleArena.find does for an AUTHORED entry: the surfing test exists to
  -- stop the automatic search staging a walker's fight out at sea, and an
  -- entry chosen by a person who is looking at it is not that.
  -- the footprint a shape covers at this turn: a quarter turn swaps how far
  -- it reaches each way, which is the whole reason a corridor takes one
  -- orientation and refuses the other
  local function extentOf(shapeId, turn)
    return Arena.extent(shapeFor(shapeId), turn)
  end

  local function footprintFits(host, x, y, shapeId, turn)
    local w, h = extentOf(shapeId, turn)
    for cy = y, y + h - 1 do
      for cx = x, x + w - 1 do
        if not Arena.openCell(host, cx, cy, true) then return false end
      end
    end
    return true
  end

  -- Re-judge the working pick and hand the same answer to the mod, so a TEST
  -- stages exactly what is on screen rather than whatever the search would
  -- have found from the player's cell.
  local function evaluate()
    S.fits, S.clear, S.arena, S.host = false, false, nil, nil
    -- The working spot is handed to the mod as this map's authored entry, so
    -- a TEST stages what is on screen. Any map we forced earlier is let go
    -- first: an override outlives the map it was set on, and one left behind
    -- would quietly stage some other area's fight on a spot that was never
    -- committed.
    if S.overrideOn and S.overrideOn ~= mapId() then
      Arena.setOverride(S.overrideOn, nil)
    end
    S.overrideOn = mapId()
    Arena.setOverride(mapId(), S.pick)
    local p = S.pick
    if type(p) ~= "table" or not S.map then return end
    local host = hostMap(p.map)
    if not host then
      say("host map %s could not be loaded", tostring(p.map))
      return
    end
    S.host = host
    if not footprintFits(host, p.x, p.y, p.shape, p.turn) then return end
    S.fits = true
    local arena = Arena.at(p.x, p.y, p.shape, p.turn)
    if not arena then return end
    arena.map, arena.cam = host, p.cam
    S.arena = arena
    local ok, clear = pcall(Arena.clearance, host, arena)
    S.clear = (ok and clear) and true or false
  end

  local function setPick(entry, why)
    S.pick = entry
    evaluate()
    if why then say(why) end
  end

  -- Put the player on the near mon's cell, so the free-roam camera is looking
  -- at the spot being edited and the meshes around it are the ones built.
  -- Written the way OverworldController's own placement writes it -- cell,
  -- pixel and the half-finished step alike -- because setting the cell alone
  -- leaves the body mid-stride toward wherever it was walking.
  local function standOnPick()
    local p, ow = S.pick, game.overworld
    if type(p) ~= "table" or not (ow and ow.player) then return end
    if S.host and S.map and S.host.id ~= S.map.id then return end
    -- through the placed record rather than the shape's own offsets, so the
    -- near mon's cell is the turned one
    local arena = Arena.at(p.x, p.y, p.shape, p.turn)
    if not arena then return end
    local cx, cy = arena.playerCell[1], arena.playerCell[2]
    if not S.map:inBounds(cx, cy) then return end
    local player = ow.player
    player.cellX, player.cellY = cx, cy
    player.px, player.py = cx * 16, cy * 16
    player.moving = false
    player.targetX, player.targetY = nil, nil
    player.facing = "up"
  end

  -- ------- what the map looks like from above
  --
  -- THE MAP'S OWN ART, first: the plan is the surface a spot is chosen on,
  -- and a grid of coloured squares is a map of the walk grid rather than of
  -- the place. What tells you the fight will be staged in the clearing north
  -- of the ledge, or on the jetty rather than the sand, is the tiles -- the
  -- game's own, extracted from the cartridge, drawn from the same atlas and
  -- through the same shade-remap shader the flat 2D world uses.
  --
  -- Baked ONCE per map into a canvas rather than drawn per frame: the tile
  -- layer is a static SpriteBatch over the whole body, and asking the engine
  -- for it sixty times a second would refill that batch against a window the
  -- game is also using. Baked during UPDATE, never inside a draw, because it
  -- binds a canvas of its own -- the same reason the battle's scene pass
  -- lives on the update hook.
  local PLAN_MAX = 2048     -- the largest bake, in pixels on the long side

  -- The four colours this map's ground is drawn in: its own SGB palette,
  -- looked up exactly as the overworld looks it up, so a cave is a cave's
  -- grey and Viridian Forest is its own green. Falls back to the boot ROM's
  -- background palette, which is what the engine falls back to.
  local function paletteFor(m)
    local ow = game.overworld
    if ow and ow.paletteNameFor then
      local okName, name = pcall(ow.paletteNameFor, ow, m)
      if okName and name then
        local okPal, colours = pcall(PaletteFX.pal, game.data, name)
        if okPal and colours then return colours end
      end
    end
    local okOg, og = pcall(PaletteFX.ogBg)
    return okOg and og or nil
  end

  local function bakeTiles()
    if S.tiles then pcall(S.tiles.release, S.tiles) end
    S.tiles = nil
    local m = S.map
    if not (m and m.renderer and love.graphics and love.graphics.newCanvas) then
      return
    end
    local w, h = m.widthCells * 16, m.heightCells * 16
    local scale = math.min(1, PLAN_MAX / math.max(w, h))
    local okNew, canvas = pcall(love.graphics.newCanvas,
                                math.max(1, math.floor(w * scale)),
                                math.max(1, math.floor(h * scale)))
    if not (okNew and canvas) then return end
    -- linear, deliberately, and the one place in this mod where that is
    -- right: the plan is this art MINIFIED to a panel, where nearest
    -- sampling throws away most of the tiles and keeps a moire of whichever
    -- texels the ratio happens to land on
    pcall(canvas.setFilter, canvas, "linear", "linear")

    local g = love.graphics
    local prev = g.getCanvas()
    -- the true-colour marks a RED++ atlas registers are for the frame the
    -- engine is composing, not for a canvas baked outside one
    local wasTrue = m.renderer.trueColor
    m.renderer.trueColor = false
    local ok, err = pcall(function()
      g.push("all")
      g.origin()
      g.setCanvas(canvas)
      g.clear(0, 0, 0, 0)
      g.setBlendMode("alpha")
      g.setColor(1, 1, 1, 1)
      g.scale(scale, scale)
      -- the atlas is the Game Boy's four greys; this is the pass that turns
      -- them into the map's colours, and it is the engine's own
      local shader = PaletteFX.shader()
      local colours = paletteFor(m)
      if shader and colours then
        g.setShader(shader)
        PaletteFX.sendColors(shader, colours)
      end
      m.renderer:drawMapOnly(0, 0, w, h)
      g.pop()
    end)
    m.renderer.trueColor = wasTrue
    if prev then pcall(g.setCanvas, prev) else pcall(g.setCanvas) end
    if not ok then
      pcall(canvas.release, canvas)
      U.log("could not bake the map's tiles: " .. tostring(err))
      return
    end
    S.tiles = canvas
  end

  -- And the walk grid over it, one class per cell, built once with it. The
  -- art says what the place looks like; this says where an arena may legally
  -- go, which is not visible in the art -- a ledge lip and the path beside it
  -- are the same three pixels of grass.
  --
  -- How much of it is laid over the art is the `g` key. Declared up here
  -- rather than beside the drawing that reads it: a local declared further
  -- down the chunk would leave the key handler above reading a GLOBAL of the
  -- same name, which is nil forever and takes the key silently with it.
  local PLAN_MODES = { "both", "tiles", "grid" }

  local CELL_COLOUR = {
    open  = { 0.78, 0.74, 0.63 },
    grass = { 0.33, 0.60, 0.30 },
    water = { 0.24, 0.44, 0.78 },
    warp  = { 0.85, 0.68, 0.20 },
    solid = { 0.17, 0.17, 0.20 },
  }

  local function buildPlan()
    local m = S.map
    if not m then S.plan = nil return end
    local w, h = m.widthCells, m.heightCells
    local plan = { w = w, h = h }
    for cy = 0, h - 1 do
      for cx = 0, w - 1 do
        local kind
        if not m:isWalkableCell(cx, cy) then
          kind = m:isWaterCell(cx, cy) and "water" or "solid"
        elseif m:warpAtCell(cx, cy) or m:isWarpTileCell(cx, cy) then
          kind = "warp"
        elseif m.isGrassCell and m:isGrassCell(cx, cy) then
          kind = "grass"
        else
          kind = "open"
        end
        plan[cy * w + cx] = kind
      end
    end
    S.plan = plan
  end

  -- ------- moving between maps

  local function autoPick(quiet)
    if not S.map then return nil end
    local def = game.data.maps[mapId()]
    -- def.width/height are in BLOCKS and a block is two cells, so the map's
    -- middle in cells is the width itself
    local ox, oy = math.floor(def.width), math.floor(def.height)
    if S.surf then
      -- A surf route's land is a rim of beach around the edge of the map, so
      -- a search from the middle always lands on the rim and the fight is
      -- staged on sand at the corner of a sea. Starting from the middle of
      -- the BIGGEST body of water puts it out in the open instead -- biggest,
      -- not all of it at once, because a map with a lake and an ocean has a
      -- centroid between them that is on neither.
      local m = S.map
      local w, h = m.widthCells, m.heightCells
      local seen, best = {}, nil
      for y0 = 0, h - 1 do
        for x0 = 0, w - 1 do
          if not seen[y0 * w + x0] and m:isWaterCell(x0, y0) then
            local stack, n, sx, sy = { { x0, y0 } }, 0, 0, 0
            seen[y0 * w + x0] = true
            while #stack > 0 do
              local cell = table.remove(stack)
              local cx, cy = cell[1], cell[2]
              n, sx, sy = n + 1, sx + cx, sy + cy
              for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
                local nx, ny = cx + d[1], cy + d[2]
                local key = ny * w + nx
                if nx >= 0 and ny >= 0 and nx < w and ny < h and not seen[key]
                   and m:isWaterCell(nx, ny) then
                  seen[key] = true
                  stack[#stack + 1] = { nx, ny }
                end
              end
            end
            if not best or n > best.n then
              best = { n = n, x = sx / n, y = sy / n }
            end
          end
        end
      end
      if best then ox, oy = best.x, best.y end
    end
    local found = Arena.search(S.map, ox, oy, S.surf, true)
    local why = "clear"
    if not found then
      found = Arena.search(S.map, ox, oy, S.surf)
      -- The shipped search asks about the DEFAULT lens only, which is what
      -- makes it say this about rooms it cannot stand back from. `f` asks
      -- about both, so it is the thing to reach for next rather than a
      -- conclusion that the map has nowhere to fight.
      why = "OBSTRUCTED on the long lens -- try f, which also tries the wide one"
    end
    if not found then
      if not quiet then say("no arena of either shape fits on this map") end
      return nil
    end
    if not quiet then
      say("automatic pick, %s", why)
    end
    return { x = found.x, y = found.y, shape = found.shape }
  end

  local function enterMap(index)
    S.i = ((index - 1) % #ids) + 1
    local id = mapId()
    S.cands, S.ci = nil, 0
    local ok, err = pcall(function() U.teleport(game, id, 1, 1, "down") end)
    if not ok then
      S.map, S.plan = nil, nil
      say("could not enter %s (%s)", id, tostring(err))
      U.log(("SKIP   %s -- could not enter (%s)"):format(id, tostring(err)))
      return
    end
    S.map = game.overworld.map
    buildPlan()
    bakeTiles()
    -- the entry this map already has wins; a map with none gets the search's
    -- answer as a starting point, uncommitted
    local entry = edits[id]
    if entry == REMOVE then entry = nil end
    if entry == nil then entry = base[id] end
    if entry == nil then
      setPick(autoPick(true), nil)
      say("%s: no entry yet -- this is the automatic pick", id)
    else
      if entry == false then
        setPick(false, nil)
        say("%s: the config refuses this map", id)
      else
        setPick({ x = entry.x, y = entry.y, shape = entry.shape or "wide",
                  turn = entry.turn, cam = entry.cam, map = entry.map }, nil)
        say("%s: from the config", id)
      end
    end
    standOnPick()
  end

  -- ------- the frame
  --
  -- The driver harness turns the frame cap off (main.lua: a scripted run is
  -- not paced), so each step is held to a 60th of a second by hand. Without
  -- it the game's logic runs at the refresh rate of whatever monitor this is
  -- on, and a battle intro on a 165Hz panel is over before it can be read.
  local lastT = love.timer.getTime()
  local function step(n)
    for _ = 1, (n or 1) do
      local rest = (1 / 60) - (love.timer.getTime() - lastT)
      if rest > 0 then love.timer.sleep(rest) end
      lastT = love.timer.getTime()
      U.wait(1)
    end
  end

  -- `withHud` keeps the overlay in the shot, which is how a spot is filed
  -- with its own plan and verdict beside it; the plain shot is the picture a
  -- player would get and is the one to judge by.
  local function shoot(name, withHud)
    local path = ("%s/%s.png"):format(DIR, name)
    S.shooting = not withHud
    game.capturePath = path
    for _ = 1, 120 do
      if not game.capturePath then break end
      step(1)
    end
    step(2)
    S.shooting = false
    local f = io.open(path, "rb")
    if f then
      f:close()
      -- the panel gets the file name and the console the whole path: one is
      -- read at a glance and the other is pasted into something
      say("shot %s.png", name)
      U.log("SHOT   " .. path)
    else
      say("screenshot did not reach disk: %s", path)
    end
  end

  -- The spot IS the filename, so a directory of these is a contact sheet of
  -- decisions rather than a pile of numbered frames -- and the mode is in it
  -- too, or the shot of the staged fight lands on top of the shot of the
  -- ground it was staged on.
  local function shotName(kind)
    local p = S.pick
    local where = mapId():lower()
    if type(p) == "table" then
      where = ("%s_x%d_y%d_%s"):format(where, p.x, p.y, p.shape or "wide")
      -- the turn is part of the spot's identity, or the same corner shot two
      -- ways round writes one file twice and the comparison is impossible
      if (p.turn or 0) ~= 0 then where = ("%s_t%d"):format(where, p.turn) end
    end
    return where .. "_" .. (kind or (S.mode == "test" and "battle" or "plan"))
  end

  -- ------- TEST: a real fight on the spot
  --
  -- Staged through the mod's own path -- the override is already installed by
  -- evaluate(), the overworld's own pushBattle is what starts it -- so what
  -- appears is a battle, not a mock of one. Judging a spot against anything
  -- less is how a spot that reads on a plan and hides a Pokemon in the game
  -- gets committed.
  local function beginTest()
    if type(S.pick) ~= "table" then
      say("nothing to stage here")
      return
    end
    if not S.fits then
      say("that footprint is not on open ground -- nothing would stage")
      return
    end
    standOnPick()
    say("staging...")
    -- let the terrain around the arena finish building before the shot needs
    -- it, so the first battle frame is not the flat fallback
    for _ = 1, 120 do
      if (ChunkMesher.pending and ChunkMesher.pending() or 0) == 0 then break end
      step(1)
    end
    step(20)
    local battle = BattleState.newWild(game, SPECIES, LEVEL)
    -- the fight is a fixture, so it must not run the real one's aftermath
    battle.onFinish = function() end
    game.overworld:pushBattle(battle)
    S.mode = "test"
    -- Drive it to the MENU. Anything earlier is the intro, where the player's
    -- side legitimately shows the trainer's back and there is no Pokemon on
    -- the field at all -- which looks exactly like a broken arena and is not.
    for _ = 1, 200 do
      if battle.phase == "menu" then break end
      U.tap(game, "a")
      step(6)
    end
    local staged = Battles.arena()
    if staged then
      say("TEST at %d,%d %s -- t or escape to come back", staged.x, staged.y,
          staged.shape)
    else
      say("TEST: nothing staged, this is the flat battle screen")
    end
    U.log(("TEST   %s phase=%s staged=%s"):format(mapId(),
          tostring(battle.phase), staged and "yes" or "no"))
  end

  local function endTest()
    U.log("TEST   left")
    while game.stack:top() and game.stack:top() ~= game.overworld do
      game.stack:pop()
    end
    step(8)
    S.mode = "edit"
    standOnPick()
    say("back in the editor")
  end

  -- ------- the scan
  --
  -- Every arena that fits anywhere on this map, clear ones first. The
  -- clearance test is what makes the list worth stepping through: an
  -- obstructed spot is not a candidate however good the ground under it
  -- looks, and half the ground on a route is obstructed from a camera this
  -- low.
  local function scan()
    local m = S.map
    if not m then return end
    local margin = MARGIN
    if not margin then
      -- outdoors the outermost cells are the CONNECTION BORDER, the strip the
      -- neighbouring map is drawn into: ground there passes every test and is
      -- still the wrong answer, because a fight staged on it happens at the
      -- edge of the world. Indoors there is no such strip and the walls are
      -- already off the table, so nothing is kept back.
      margin = Map.isOutdoor(m.def) and 2 or 0
    end
    local list = {}
    local mx = (m.widthCells - 1) / 2
    local my = (m.heightCells - 1) / 2
    -- Both footprints, because a quarter turn is what lets the 3x6 shape into
    -- an east-west corridor at all: turns 0 and 2 cover the same ground and
    -- so do 1 and 3, so the GROUND is walked twice and the four ways round
    -- are asked about each patch that takes one.
    for _, shape in ipairs(Arena.SHAPES) do
      for _, lie in ipairs({ 0, 90 }) do
        local fw, fh = Arena.extent(shape, lie)
        -- the square footprint the narrow shape never has, and the wide one
        -- never has either -- so nothing is scanned twice
        local twice = (fw == shape.w and fh == shape.h and lie ~= 0)
        for y = margin, m.heightCells - fh - margin do
          for x = margin, m.widthCells - fw - margin do
            local fits = not twice
            if fits then
              for cy = y, y + fh - 1 do
                for cx = x, x + fw - 1 do
                  if not Arena.openCell(m, cx, cy, S.surf) then
                    fits = false
                    break
                  end
                end
                if not fits then break end
              end
            end
            if fits then
              -- Judged on both TURNS that share this footprint and on both
              -- LENSES, because which way round a fight stands and what it is
              -- shot on are part of the answer, not separate questions asked
              -- afterwards.
              --
              -- The lens matters most indoors: the long default cannot stand
              -- back from a small room -- its eye lands outside the walls, and
              -- on an indoor map that is inside the border ring this mode
              -- extrudes into a cliff -- so a gym where nothing is clear on
              -- the tele lens can be entirely clear on the 44-degree one. That
              -- is what `cam = "wide"` is for on the three gyms in the shipped
              -- file, and an editor that only asked about the default lens
              -- would report those maps as having nowhere to fight.
              --
              -- The turn matters most against a wall: the two ends of the same
              -- axis put the camera on opposite sides of the pair, and one of
              -- them is often looking into the rock the other has behind it.
              --
              -- First combination that reads wins, in preference order, so the
              -- common case -- clear, as it lies, on the default lens -- costs
              -- exactly one clearance test.
              local clear, cam, turn = false, nil, lie
              for _, t in ipairs({ lie, lie + 180 }) do
                for _, lens in ipairs({ false, "wide" }) do
                  local a = Arena.at(x, y, shape.id, t)
                  a.cam = lens or nil
                  local ok, got = pcall(Arena.clearance, m, a)
                  if ok and got then
                    clear, cam, turn = true, lens or nil, t
                    break
                  end
                end
                if clear then break end
              end
              local dx = x + (fw - 1) / 2 - mx
              local dy = y + (fh - 1) / 2 - my
              list[#list + 1] = { x = x, y = y, shape = shape.id, turn = turn,
                                  clear = clear, cam = cam,
                                  d = dx * dx + dy * dy }
            end
          end
          say("scanning %s%s... %d found", shape.id,
              lie ~= 0 and " (turned)" or "", #list)
          step(1)
        end
      end
    end
    -- Clear before obstructed; among the clear, the default lens before the
    -- one that had to be widened to get there; then the wide arena shape
    -- before the narrow one, since that is the shot this mode is framed for;
    -- and within all that, nearest to the middle of the map -- which is the
    -- order arena_pick's own answer comes first in, so `f` then `n` walks
    -- outward from the spot the batch tool would have chosen.
    table.sort(list, function(a, b)
      if a.clear ~= b.clear then return a.clear end
      if (a.cam ~= nil) ~= (b.cam ~= nil) then return a.cam == nil end
      if a.shape ~= b.shape then return a.shape == "wide" end
      -- and the way round the mode was drawn for before the three that had
      -- to be turned to get there
      if (a.turn or 0) ~= (b.turn or 0) then
        return (a.turn or 0) < (b.turn or 0)
      end
      return a.d < b.d
    end)
    local clearN, wideN = 0, 0
    for _, c in ipairs(list) do
      if c.clear then
        clearN = clearN + 1
        if c.cam then wideN = wideN + 1 end
      end
    end
    S.cands, S.ci = list, 0
    S.candClear, S.candWide = clearN, wideN
    if #list == 0 then
      say("nothing fits anywhere on this map")
    else
      say("%d spots fit, %d of them clear%s -- n and p step through them",
          #list, clearN,
          wideN > 0 and (" (%d only on the wide lens)"):format(wideN) or "")
    end
  end

  local function stepCandidate(dir)
    if not S.cands or #S.cands == 0 then
      say("scan the map first (f)")
      return
    end
    S.ci = ((S.ci + dir - 1) % #S.cands + #S.cands) % #S.cands + 1
    local c = S.cands[S.ci]
    local keep = type(S.pick) == "table" and S.pick or {}
    -- the turn and the lens come WITH the candidate: the scan reached its
    -- verdict about one particular way round on one particular lens, and
    -- landing on the spot with either of the others selected would show a
    -- verdict that was never about this shot
    setPick({ x = c.x, y = c.y, shape = c.shape, turn = c.turn,
              cam = c.clear and c.cam or keep.cam, map = keep.map })
    standOnPick()
    say("candidate %d/%d  %s%s%s", S.ci, #S.cands,
        c.clear and "clear" or "OBSTRUCTED",
        (c.turn or 0) ~= 0 and (" turned %d"):format(c.turn) or "",
        c.cam and " on the wide lens" or "")
  end

  -- ------- committing

  local function commit(entry, advance)
    local id = mapId()
    local was = base[id]
    if entry == nil then
      -- there is no spot to commit. Saying so is the honest answer; a map
      -- with nowhere a fight can be seen is committed with backspace, which
      -- writes a refusal the mod reads rather than silence it has to guess at
      say("no spot here to commit -- backspace commits a refusal instead")
      return
    end
    if not S.done[id] then
      S.done[id] = true
      S.doneN = S.doneN + 1
    end
    if entry == REMOVE then
      if was == nil then
        edits[id] = nil
        say("%s has no entry to remove", id)
        return
      end
      edits[id] = REMOVE
      U.log(("REMOVE %s -- battle time falls back to the search"):format(id))
    elseif entry == false then
      edits[id] = false
      U.log(("PICK   [%q] = false,"):format(id))
    else
      if sameEntry(entry, was) then
        edits[id] = nil
        say("%s already says exactly that", id)
        if advance then post("map", 1) end
        return
      end
      edits[id] = { x = entry.x, y = entry.y, shape = entry.shape or "wide",
                    turn = ((entry.turn or 0) ~= 0) and entry.turn or nil,
                    cam = entry.cam, map = entry.map }
      U.log(("PICK   [%q] = { %sx = %d, y = %d, shape = %q%s%s },%s")
            :format(id, entry.map and ("map = %q, "):format(entry.map) or "",
                    entry.x, entry.y, entry.shape or "wide",
                    ((entry.turn or 0) ~= 0)
                      and (", turn = %d"):format(entry.turn) or "",
                    entry.cam and (", cam = %q"):format(entry.cam) or "",
                    S.clear and "" or "   -- OBSTRUCTED"))
    end
    local ok, msg = export()
    if ok then
      say("committed %s -- %s", id, msg)
    else
      say("COMMITTED BUT NOT WRITTEN: %s", msg)
      U.log("EXPORT FAILED: " .. msg)
    end
    if advance then post("map", 1) end
  end

  -- ------- the keys
  --
  -- Wrapped around love.keypressed rather than polled, so a press is taken
  -- INSTEAD of reaching the game rather than as well as -- an arrow key that
  -- moved the arena and walked the player would fight itself. Only the keys
  -- below are claimed; everything else falls through, which is what leaves
  -- the mod's own hotkeys (the rung, the water, the wireframe) working while
  -- the editor is up, and the whole keyboard working inside a TEST.
  local function shifted()
    return love.keyboard.isDown("lshift") or love.keyboard.isDown("rshift")
  end

  -- Keep the corner on the map, measured against the footprint as it
  -- currently lies -- a shape that has just been turned or swapped reaches a
  -- different distance each way from the same corner.
  local function clampPick()
    local p = S.pick
    if type(p) ~= "table" then return end
    local fw, fh = extentOf(p.shape, p.turn)
    local w = S.host and S.host.widthCells or (S.map and S.map.widthCells) or 0
    local h = S.host and S.host.heightCells or (S.map and S.map.heightCells) or 0
    p.x = math.max(0, math.min(w - fw, p.x))
    p.y = math.max(0, math.min(h - fh, p.y))
  end

  local function nudge(dx, dy)
    local p = S.pick
    if type(p) ~= "table" then
      setPick(autoPick(true), "no spot here yet -- took the automatic one")
      return
    end
    local n = shifted() and 5 or 1
    p.x, p.y = p.x + dx * n, p.y + dy * n
    clampPick()
    evaluate()
    standOnPick()
    say("%d,%d %s", p.x, p.y, p.shape or "wide")
  end

  -- A quarter turn of the whole staging: the footprint, both mons and the
  -- camera together (see BattleArena's `turn`). The picture does not change --
  -- the pair land on the same screen anchors at the same size -- so what this
  -- is for is the GROUND: fitting a long arena down a corridor that runs the
  -- other way, and swapping what is standing behind the pair.
  local function rotate(dir)
    local p = S.pick
    if type(p) ~= "table" then return end
    p.turn = (((p.turn or 0) + dir * 90) % 360 + 360) % 360
    clampPick()
    evaluate()
    standOnPick()
    local fw, fh = extentOf(p.shape, p.turn)
    say("turned %d degrees -- %dx%d cells, foe to the %s", p.turn, fw, fh,
        ({ [0] = "north", [90] = "east", [180] = "south",
           [270] = "west" })[p.turn])
  end

  local function cycleShape()
    local p = S.pick
    if type(p) ~= "table" then return end
    p.shape = (p.shape == "narrow") and "wide" or "narrow"
    -- the wide shape is 3x6 and the narrow one 1x4, so a corner that was
    -- legal for the smaller one can hang off the map with the bigger
    clampPick()
    evaluate()
    standOnPick()
    say("shape %s", p.shape)
  end

  local function cycleCam()
    local p = S.pick
    if type(p) ~= "table" then return end
    p.cam = (p.cam == nil) and "wide" or nil
    evaluate()
    say("lens %s", p.cam or "tele (the long default)")
  end

  -- The floors of the same cave or building, for an entry that stages its
  -- fight on one of them. Family is the id with its floor suffix taken off,
  -- which is how these are actually named: POKEMON_TOWER_4F borrows
  -- POKEMON_TOWER_3F, CERULEAN_CAVE_2F borrows CERULEAN_CAVE_B1F.
  local function family(id)
    return (id:gsub("_B?%d+F", ""))
  end

  local function cycleHost()
    local p = S.pick
    if type(p) ~= "table" then return end
    local id = mapId()
    local kin = { id }
    for other in pairs(game.data.maps) do
      if type(other) == "string" and other ~= id
         and family(other) == family(id) then
        kin[#kin + 1] = other
      end
    end
    table.sort(kin)
    if #kin == 1 then
      say("%s has no sibling floors to stage on", id)
      return
    end
    local at = 1
    for k, other in ipairs(kin) do
      if other == (p.map or id) then at = k end
    end
    local nextId = kin[(at % #kin) + 1]
    p.map = (nextId ~= id) and nextId or nil
    -- the corner is a coordinate on the HOST, so a floor change is a fresh
    -- question about where on it -- clamp it in, then let the fit test speak
    evaluate()
    if S.host then
      clampPick()
      evaluate()
    end
    standOnPick()
    say("staging on %s", p.map or "this map")
  end

  local function handle(key)
    if S.mode == "test" then
      if key == "t" or key == "escape" then post("endtest") return true end
      if key == "y" then post("shot", shifted() and "hud" or nil) return true end
      if key == "f1" then S.legend = not S.legend return true end
      return false
    end

    if key == "up" then nudge(0, -1) return true end
    if key == "down" then nudge(0, 1) return true end
    if key == "left" then nudge(-1, 0) return true end
    if key == "right" then nudge(1, 0) return true end
    if key == "[" then post("map", -1) return true end
    if key == "]" then post("map", 1) return true end
    if key == "s" then cycleShape() return true end
    if key == "r" then rotate(shifted() and -1 or 1) return true end
    if key == "c" then cycleCam() return true end
    if key == "h" then cycleHost() return true end
    if key == "w" then
      S.surf = not S.surf
      say("the search %s water as ground",
          S.surf and "counts" or "does not count")
      return true
    end
    if key == "g" then
      S.planMode = (S.planMode % #PLAN_MODES) + 1
      say("plan: %s", PLAN_MODES[S.planMode])
      return true
    end
    if key == "f" then post("scan") return true end
    if key == "n" then stepCandidate(1) return true end
    if key == "p" then stepCandidate(-1) return true end
    if key == "a" then
      local found = autoPick()
      if found then
        setPick(found)
        standOnPick()
      end
      return true
    end
    -- `u` for undo, because `r` is rotate: the strongest convention on each
    -- wins, and this one is only ever wanted after a change you regret
    if key == "u" then
      local id = mapId()
      local entry = base[id]
      edits[id] = nil
      if entry == nil then
        setPick(autoPick(true), "no entry in the config -- automatic pick")
      elseif entry == false then
        setPick(false, "the config refuses this map")
      else
        setPick({ x = entry.x, y = entry.y, shape = entry.shape or "wide",
                  turn = entry.turn, cam = entry.cam, map = entry.map },
                "back to the config")
      end
      standOnPick()
      return true
    end
    if key == "t" then post("test") return true end
    if key == "y" then post("shot", shifted() and "hud" or nil) return true end
    if key == "return" or key == "kpenter" then
      post("commit", shifted() and "advance" or "stay")
      return true
    end
    if key == "backspace" then post("refuse") return true end
    if key == "delete" then post("drop") return true end
    if key == "e" then post("export") return true end
    if key == "f1" then S.legend = not S.legend return true end
    if key == "escape" then S.quit = true return true end
    return false
  end

  local innerKey = love.keypressed
  function love.keypressed(key, scancode, isrepeat)
    -- the unattended check drives handle() directly, so anything arriving
    -- HERE during one is a real key from the window and worth naming
    if SELFTEST then U.log("KEY    " .. tostring(key)) end
    local ok, claimed = pcall(handle, key)
    if ok and claimed then return end
    if not ok then U.log("key error: " .. tostring(claimed)) end
    if innerKey then return innerKey(key, scancode, isrepeat) end
  end

  -- ------- the overlay
  --
  -- Drawn after the game's own frame, over it. The plan on the right is what
  -- the spot is CHOSEN on -- open ground, grass, water, the walls -- and the
  -- two lines drawn across it from the camera's eye are why a spot that looks
  -- open gets rejected: they are the sightlines the clearance test walks, and
  -- seeing them cross a building is the whole explanation.
  local font = love.graphics.newFont(13)
  local smallFont = love.graphics.newFont(11)

  local function drawPlan(x, y, w, h)
    local plan = S.plan
    if not plan then return end
    local g = love.graphics
    local cell = math.min(w / plan.w, h / plan.h)
    if cell < 1 then cell = 1 end
    local pw, ph = plan.w * cell, plan.h * cell
    local ox, oy = x + (w - pw) / 2, y + (h - ph) / 2
    g.setColor(0, 0, 0, 0.55)
    g.rectangle("fill", ox - 4, oy - 4, pw + 8, ph + 8)

    local mode = PLAN_MODES[S.planMode or 1]
    -- the map itself, from its own tiles
    if S.tiles and mode ~= "grid" then
      g.setColor(1, 1, 1, 1)
      g.draw(S.tiles, ox, oy, 0, pw / S.tiles:getWidth(),
             ph / S.tiles:getHeight())
    end
    -- and the walk grid over it: opaque with no art under it, and a wash
    -- when there is -- enough to read where an arena may go without hiding
    -- what it would be standing on. Open ground is never washed: it is what
    -- the art is being read for.
    if mode ~= "tiles" then
      local alpha = (mode == "grid" or not S.tiles) and 1 or 0.22
      for cy = 0, plan.h - 1 do
        for cx = 0, plan.w - 1 do
          local kind = plan[cy * plan.w + cx]
          local c = CELL_COLOUR[kind]
          if c and not (alpha < 1 and kind == "open") then
            g.setColor(c[1], c[2], c[3], alpha)
            g.rectangle("fill", ox + cx * cell, oy + cy * cell, cell, cell)
          end
        end
      end
    end

    -- The candidates, so a scan is a picture of where the map will take a
    -- fight at all rather than a number to press n against.
    --
    -- One mark at each one's middle rather than its footprint filled in: on a
    -- route most open ground is a candidate, and painting all of them lays a
    -- sheet of colour over the very art the spot is being chosen from. A dot
    -- says "here, and here" without hiding what is there.
    if S.cands then
      local r = math.max(1.5, cell * 0.35)
      for _, c in ipairs(S.cands) do
        local fw, fh = extentOf(c.shape, c.turn)
        if c.clear then
          -- green for the default lens, amber for one that only reads on the
          -- wide one -- the difference is a decision, not a detail
          if c.cam then g.setColor(1, 0.8, 0.2, 0.85)
          else g.setColor(0.3, 1, 0.4, 0.85) end
        else
          g.setColor(1, 0.35, 0.2, 0.35)
        end
        g.circle("fill", ox + (c.x + fw / 2) * cell,
                 oy + (c.y + fh / 2) * cell, r)
      end
    end

    local ow = game.overworld
    if ow and ow.player then
      g.setColor(1, 1, 1, 0.8)
      g.circle("fill", ox + (ow.player.cellX + 0.5) * cell,
               oy + (ow.player.cellY + 0.5) * cell, math.max(2, cell * 0.4))
    end

    -- the spot itself, on whichever map it is measured against
    local p = S.pick
    local onHost = not (S.host and S.map and S.host.id ~= S.map.id)
    -- laid out through the placed record rather than from the shape's own
    -- offsets, so a turned arena is drawn the way it will actually stand.
    -- Built even when it does not fit -- a footprint half off the map is
    -- exactly the thing you need to see to move it back on.
    local shot = type(p) == "table" and Arena.at(p.x, p.y, p.shape, p.turn)
    if shot and onHost then
      g.setColor(S.fits and (S.clear and 0.2 or 1) or 1,
                 S.fits and 1 or 0.3, S.fits and (S.clear and 1 or 0.2) or 0.3,
                 0.9)
      g.setLineWidth(2)
      g.rectangle("line", ox + shot.x * cell, oy + shot.y * cell,
                  shot.w * cell, shot.h * cell)
      g.setLineWidth(1)
      local ex, ey = shot.enemyCell[1], shot.enemyCell[2]
      local px, py = shot.playerCell[1], shot.playerCell[2]
      g.setColor(0.95, 0.35, 0.35, 1)
      g.rectangle("fill", ox + ex * cell, oy + ey * cell, cell, cell)
      g.setColor(0.4, 0.65, 1, 1)
      g.rectangle("fill", ox + px * cell, oy + py * cell, cell, cell)

      -- the camera, and what it is looking through
      if S.arena then
        local ok, rig = pcall(BattleCam.rig, S.arena, 0, true)
        if ok and rig and rig.eye then
          local eyeX = ox + (rig.eye[1] / 16) * cell
          local eyeY = oy + (rig.eye[3] / 16) * cell
          if S.clear then g.setColor(0.3, 1, 0.5, 0.85)
          else g.setColor(1, 0.35, 0.3, 0.85) end
          g.line(eyeX, eyeY, ox + (ex + 0.5) * cell, oy + (ey + 0.5) * cell)
          g.line(eyeX, eyeY, ox + (px + 0.5) * cell, oy + (py + 0.5) * cell)
          g.circle("fill", eyeX, eyeY, 4)
        end
      end
    end
    g.setColor(1, 1, 1, 1)
  end

  local LEGEND = {
    "arrows  move the corner (shift x5)",
    "[  ]    previous / next map",
    "s       shape: wide / narrow",
    "r       turn it 90 (shift: the other way)",
    "c       lens: tele / wide",
    "h       stage on a sibling floor",
    "w       search over water",
    "g       plan: tiles / walk grid / both",
    "f       scan the map     n p  step",
    "a       automatic pick   u    revert",
    "t       TEST a real battle here",
    "y       screenshot (shift: with this panel)",
    "enter   commit   (shift: and next map)",
    "bksp    commit a refusal",
    "del     commit a removal",
    "e       export      F1  this list",
    "escape  quit",
  }

  local function drawOverlay()
    local g = love.graphics
    local W, H = g.getDimensions()

    if S.mode == "test" then
      g.setFont(font)
      g.setColor(0, 0, 0, 0.65)
      g.rectangle("fill", 0, 0, W, 26)
      g.setColor(1, 0.85, 0.3, 1)
      g.print(("TEST  %s  %s   [t] back   [y] shot")
              :format(mapId(), S.msg), 8, 5)
      g.setColor(1, 1, 1, 1)
      return
    end

    local panel = math.min(340, W * 0.34)
    g.setFont(font)
    g.setColor(0, 0, 0, 0.68)
    g.rectangle("fill", 0, 0, panel, H)

    local p = S.pick
    local id = mapId()
    local mark = S.done[id] and " *" or ""
    local lines = {}
    local function add(fmt, ...)
      lines[#lines + 1] = select("#", ...) > 0 and fmt:format(...) or fmt
    end
    add("ARENA EDITOR   %d/%d%s", S.i, #ids, mark)
    add("%s", id)
    if S.map then
      add("%d x %d cells", S.map.widthCells, S.map.heightCells)
    end
    add("")
    if p == false then
      add("REFUSAL -- no fight is staged here")
    elseif type(p) ~= "table" then
      add("no spot")
    else
      local fw, fh = extentOf(p.shape, p.turn)
      add("x %d   y %d   %s  (%dx%d)", p.x, p.y, p.shape or "wide", fw, fh)
      add("turn %d   foe to the %s", p.turn or 0,
          ({ [0] = "north", [90] = "east", [180] = "south",
             [270] = "west" })[p.turn or 0] or "?")
      add("lens %s", p.cam or "tele")
      add("host %s", p.map or "this map")
      add("")
      add("fits    %s", S.fits and "YES" or "NO -- not open ground")
      add("clear   %s", S.clear and "YES"
                        or (S.fits and "NO -- a mon is hidden" or "-"))
    end
    add("")
    -- what the CONFIG says right now, which after a commit is what was just
    -- written to it -- an export rebases on its own output, so "pending" is
    -- never a state this can be left in
    local held = edits[id]
    if held == nil then held = base[id] end
    if held == REMOVE or held == nil then
      add("config  no entry (the search answers)")
    elseif held == false then
      add("config  refuses this map")
    else
      add("config  %d,%d %s%s%s%s", held.x, held.y, held.shape or "wide",
          ((held.turn or 0) ~= 0) and (" turn=" .. held.turn) or "",
          held.cam and (" cam=" .. held.cam) or "",
          held.map and (" on " .. held.map) or "")
    end
    if not sameEntry(p, held) then
      add("NOT COMMITTED -- enter writes it")
    elseif S.done[id] then
      add("committed this session")
    else
      add("unchanged")
    end
    if S.cands then
      add("scan  %d fit, %d clear (%d need the wide lens)%s",
          #S.cands, S.candClear or 0, S.candWide or 0,
          S.ci > 0 and ("   at %d"):format(S.ci) or "")
    end
    add("water %s", S.surf and "counts as ground" or "is not searched")
    add("done  %d of %d maps this session", S.doneN, #ids)
    add("out   %s", OUT)

    g.setColor(1, 1, 1, 1)
    local y = 10
    for _, l in ipairs(lines) do
      g.print(l, 10, y)
      y = y + 16
    end

    y = y + 6
    g.setColor(1, 0.85, 0.35, 1)
    g.setFont(smallFont)
    local msg = S.msg or ""
    local _, wrapped = smallFont:getWrap(msg, panel - 20)
    g.printf(msg, 10, y, panel - 20)
    y = y + 13 * math.max(1, #wrapped)

    -- what the marks on the plan mean, in the marks themselves
    if S.cands then
      y = y + 8
      local key = { { { 0.3, 1, 0.4 }, "clear" },
                    { { 1, 0.8, 0.2 }, "wide lens only" },
                    { { 1, 0.35, 0.2 }, "obstructed" } }
      local kx = 14
      for _, entry in ipairs(key) do
        g.setColor(entry[1][1], entry[1][2], entry[1][3], 0.9)
        g.circle("fill", kx, y + 5, 3.5)
        g.setColor(0.8, 0.8, 0.85, 1)
        g.print(entry[2], kx + 9, y - 1)
        kx = kx + 12 + smallFont:getWidth(entry[2]) + 10
      end
      y = y + 16
    end

    if S.legend then
      y = y + 10
      g.setColor(0.75, 0.8, 0.9, 1)
      for _, l in ipairs(LEGEND) do
        g.print(l, 10, y)
        y = y + 14
      end
    end

    -- the plan, in whatever is left of the window
    local px = panel + 12
    drawPlan(px, 12, W - px - 12, H - 24)
    g.setColor(1, 1, 1, 1)
  end

  local innerDraw = love.draw
  function love.draw()
    if innerDraw then innerDraw() end
    if S.shooting then return end
    local g = love.graphics
    g.push("all")
    g.origin()
    local ok, err = pcall(drawOverlay)
    g.pop()
    if not ok and not S.drawWarned then
      S.drawWarned = true
      U.log("overlay draw failed: " .. tostring(err))
    end
  end

  -- ------- the session

  U.log("arena editor -- " .. #ids .. " maps")
  for _, l in ipairs(LEGEND) do U.log("  " .. l) end
  U.log("exports to " .. OUT)

  enterMap(1)

  local function dispatch(job)
    if job.cmd == "map" then
      enterMap(S.i + job.arg)
    elseif job.cmd == "scan" then
      scan()
    elseif job.cmd == "test" then
      beginTest()
    elseif job.cmd == "endtest" then
      endTest()
    elseif job.cmd == "shot" then
      local hud = job.arg == "hud"
      shoot(shotName(hud and "sheet" or nil), hud)
    elseif job.cmd == "commit" then
      commit(S.pick, job.arg == "advance")
    elseif job.cmd == "refuse" then
      commit(false, false)
    elseif job.cmd == "drop" then
      commit(REMOVE, false)
    elseif job.cmd == "export" then
      local ok, msg = export()
      say("%s", msg)
      U.log((ok and "EXPORT " or "EXPORT FAILED ") .. msg)
    end
  end

  -- One frame of the session: the next thing a key asked for, or a frame of
  -- standing still while the game runs underneath.
  local function pump(frames)
    for _ = 1, (frames or 1) do
      local job = table.remove(queue, 1)
      if job then dispatch(job) else step(1) end
      if S.quit then return end
    end
  end

  -- ------- ARENA_SELFTEST=1: the same session, with the keys pressed for you
  --
  -- Every command this tool has, driven through the SAME entry point the
  -- keyboard drives -- so it exercises the real handler, the real staging and
  -- the real export rather than a parallel script that can drift from them.
  -- It is how the tool is checked after a change without a person sitting in
  -- front of it, and it writes to its own file, never to the mod's.
  if SELFTEST then
    local function press(key, frames)
      local ok, err = pcall(handle, key)
      if not ok then U.log("SELFTEST key failed: " .. tostring(err)) end
      pump(frames or 20)
      U.log(("SELFTEST %-9s %s"):format(key, S.msg or ""))
    end
    press("f", 900)         -- scan this map
    press("n")              -- and step through what it found
    press("n")
    press("s")              -- both shapes
    press("s")
    press("r")              -- all four ways round, and back to where it was
    press("r")
    press("r")
    press("r")
    press("right")          -- nudge, with and without shift
    press("down")
    press("c")              -- both lenses
    press("c")
    press("h")              -- a sibling floor, and back off it
    press("h", 40)
    press("a", 60)          -- the automatic pick
    press("n", 60)          -- back onto the scan's best answer
    -- and the rest of the run happens TURNED, so what gets photographed and
    -- committed is a turned staging: the projection maths is proved in the
    -- suite, but whether the whole pipeline behind it -- the shadow cast, the
    -- billboards, the pinned pics -- still composes at a turn is the kind of
    -- thing only a picture settles.
    --
    -- HALF a turn, twice, rather than a quarter: the candidate under us fits
    -- the ground it was found on, and 180 keeps that footprint exactly while
    -- moving the camera to the other end of it. A quarter turn swaps the
    -- footprint's reach, so on a lane that is six cells one way and three the
    -- other it lands on a wall -- which the tool rightly refuses to stage, and
    -- which would leave this check photographing nothing.
    press("r")
    press("r", 60)
    post("shot", "hud")     -- and one with the panel in it, which is the
    pump(240)               -- only thing that proves the overlay draws
    press("y", 240)         -- a screenshot of the free-roam view
    press("g")              -- each way of drawing the plan
    press("g")
    press("g")
    press("t", 1200)        -- a real battle on the spot
    press("y", 240)         -- and one of that
    press("t", 90)          -- out of the test, by the key that is not also
                            -- the quit key -- escape is checked at the end
    press("return", 120)    -- commit it, which exports
    press("]", 200)         -- the next map
    press("backspace", 120) -- commit a refusal there
    press("delete", 120)    -- and take the entry out again
    press("e", 60)          -- an explicit export
    press("escape", 5)      -- and the way out
    U.log("SELFTEST done -- " .. tostring(S.msg))
    S.quit = true
  end

  while not S.quit do pump(1) end

  -- Hand the install back the way it was found: the forced entry let go, the
  -- baked plan released, the two wraps unwound and the camera rung put back.
  -- The mod settings this tool moved were never persisted (see the top), so
  -- there is nothing to undo there.
  if S.overrideOn then Arena.setOverride(S.overrideOn, nil) end
  if S.tiles then pcall(S.tiles.release, S.tiles) end
  love.draw = innerDraw
  love.keypressed = innerKey
  pcall(Pipelines.setLevel, "voxel", wasRung)
  U.log("done -- " .. OUT)
end
