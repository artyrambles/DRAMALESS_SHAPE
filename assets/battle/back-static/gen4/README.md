# Generation 4 static back sprites

Source reference: [Pokémon Platinum back sprites — Bulbagarden Archives](https://archives.bulbagarden.net/wiki/Category:Platinum_back_sprites)

```powershell
python tools/import_platinum_back_sprites.py --root .
```

The importer selects the ordinary image for each of the first 151 species,
preferring the male variant where the archive has a gender pair. Artwork is
ignored by Git and is not covered by the mod's MIT license. Verify that you
have the right to use and distribute it.
