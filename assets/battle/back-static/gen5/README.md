# Generation 5 static back sprites

Source reference: [Pokémon Database sprite archive](https://pokemondb.net/sprites)

The importer downloads individual files using the documented asset pattern,
for example `https://img.pokemondb.net/sprites/black-white/back-normal/pikachu.png`.

```powershell
python tools/import_black_white_static_back_sprites.py --root .
```

The importer writes the first 151 ordinary PNGs here. Artwork is ignored by
Git and is not covered by the mod's MIT license. Verify that you have the
right to use and distribute it.
