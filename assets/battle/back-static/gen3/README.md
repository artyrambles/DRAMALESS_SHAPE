# Generation 3 static back sprites

Source reference: [Emerald back sprites — Bulbagarden Archives](https://archives.bulbagarden.net/wiki/Category:Emerald_back_sprites)

```powershell
python tools/import_emerald_back_sprites.py --root .
```

The importer copies the ordinary `Spr b 3r` PNGs here and builds the separate
animated `Spr b 3e` collection. Artwork is ignored by Git and is not covered
by the mod's MIT license. Verify that you have the right to use and distribute
it.
