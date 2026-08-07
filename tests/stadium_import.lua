-- Driver: import a Stadium ROM through the OPTIONS row, with the modal file
-- dialog stubbed out.
--
-- Everything except the dialog itself is the real path: the row is built the
-- way the OPTIONS menu builds it, its step() is pressed, StadiumRomPick reads
-- the file with io.open (love.filesystem cannot see an absolute path),
-- StadiumInstall builds from those bytes, and the loading screen goes up over
-- whatever asked. A modal dialog cannot be driven, so choose() is replaced
-- with the answer a player would have given it.
return function(game)
  local U = dofile("tests/drivers/util.lua")
  local DIR = os.getenv("SHOT_DIR") or ".scratchpad"
  local lib = game.mods.exports.DRAMALESS_SHAPE.lib
  local Pick = lib.require("StadiumRomPick")
  local Install = lib.require("StadiumInstall")
  local Pack = lib.require("StadiumPack")
  local Battles = lib.require("OverworldBattle")

  U.teleport(game, "ROUTE_1", 5, 8, "down")
  U.wait(30)

  -- FIRST let the automatic first-run build finish. A ROM is sitting in
  -- baseroms/ in this checkout, so StadiumScreen.maybePush has already pushed
  -- a loading screen and started one -- and import() refuses to start a
  -- second while that runs, so every step below would silently no-op against
  -- it. maybePush asks ONCE per boot, so once this is drained it stays
  -- drained and the purge below cannot be undone behind our backs.
  local drain = 0
  while (Install.pending() or Install.status.state == "building")
        and drain < 5400 do
    U.wait(10); drain = drain + 10
  end
  while game.stack:top() and game.stack:top() ~= game.overworld do
    U.wait(10)
  end
  U.log(("drained the automatic first-run build in %d frames"):format(drain))

  -- back to a machine that has never built them, whatever earlier runs left
  for _, name in ipairs(love.filesystem.getDirectoryItems(Pack.CACHE_DIR)) do
    love.filesystem.remove(Pack.CACHE_DIR .. "/" .. name)
  end
  Install.forget()
  Pack.forget()

  local function settle(what)
    local waited = 0
    while Install.status.state == "building" and waited < 5400 do
      U.wait(10)
      waited = waited + 10
    end
    U.log(("%s: %d frames (%.1fs) -- state=%s error=%s")
          :format(what, waited, waited / 60, tostring(Install.status.state),
                  tostring(Install.status.error)))
    return waited
  end

  U.log(("picker available on this platform: %s"):format(
        tostring(Pick.available())))
  U.log(("BEFORE: models available = %s, 3D-BTL offers %d rungs")
        :format(tostring(Install.available()), Battles.setting:rungs()))

  local row = Pick.row()
  if not row then U.log("no import row on this platform") return end
  U.log(("row reads: %s = %s"):format(row.label, row.value()))

  -- ------- the wrong file first, because a refusal must not leave a mess
  U.log("-- picking a file that is not a Stadium ROM --")
  Pick.choose = function() return "/not/a/real/path.z64" end
  local realRead = Pick.read
  Pick.read = function() return ("\x80\x37\x12\x40"):rep(4096) end
  row.step(game)
  settle("wrong file")
  U.shot(game, ("%s/import_1_refused.png"):format(DIR))
  U.log(("  still not installed: %s, row still reads %s")
        :format(tostring(not Install.available()), row.value()))
  U.wait(300)   -- let the failure notice time out and pop itself

  -- ------- and now the real one
  U.log("-- picking the real ROM --")
  Pick.read = realRead
  local abs = love.filesystem.getWorkingDirectory() .. "/baseroms/baserom.z64"
  local picked = false
  Pick.choose = function() picked = true return abs end
  Install.status.state = "idle"
  row.step(game)
  U.log(("  choose() called: %s, state = %s, loading screen on top: %s")
        :format(tostring(picked), tostring(Install.status.state),
                tostring(game.stack:top() ~= game.overworld)))
  U.wait(30)
  U.shot(game, ("%s/import_2_building.png"):format(DIR))
  settle("real ROM")
  U.wait(120)

  U.log(("AFTER: models available = %s, 3D-BTL offers %d rungs, row reads %s")
        :format(tostring(Install.available()), Battles.setting:rungs(),
                row.value()))
  Battles.setting:setValue("stadium", game)
  U.log(("  and 3D-BTL can now be set to STADIUM A: %s")
        :format(tostring(Battles.setting:get() == "stadium")))
  -- and the ROM was NOT copied anywhere: the only baserom physfs can see is
  -- the one in the game folder this checkout already had, never a copy in
  -- the save directory (which is where a mod's writes land)
  local where = love.filesystem.getRealDirectory("baseroms/baserom.z64")
  U.log(("  the only ROM on the read path is the game folder's own: %s (%s)")
        :format(tostring(where == love.filesystem.getWorkingDirectory()),
                tostring(where)))
  U.log(("  the save directory has no baseroms folder: %s")
        :format(tostring(love.filesystem.getInfo(
                  love.filesystem.getSaveDirectory() .. "/baseroms") == nil)))

  -- ------- and the wrong file, now that a GOOD set is installed
  --
  -- The serious case. The marker is the only thing that makes 151 files on
  -- disk count as installed, so a refusal that writes one anyway would
  -- UNINSTALL a working set -- and the player would have pressed a row called
  -- STADIUM ROM, picked the wrong file, and lost the models they already had.
  U.log("-- picking the wrong file again, with models already installed --")
  Pick.read = function() return ("7@"):rep(4096) end
  Install.status.state = "idle"
  row.step(game)
  settle("wrong file over a good install")
  U.wait(300)
  Install.forget()
  Pack.forget()
  U.log(("  the good install SURVIVED: %s, row reads %s, 3D-BTL offers %d rungs")
        :format(tostring(Install.available()), row.value(),
                Battles.setting:rungs()))
  U.log(("  and a real model still loads: %s")
        :format(tostring(Pack.load(25) ~= nil)))
  U.log("done -- " .. DIR)
end
