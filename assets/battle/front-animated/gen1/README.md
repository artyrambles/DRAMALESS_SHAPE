# Generation 1 front compatibility set

These 151 front sprites are the **International Yellow (Game Boy Color) front
sprites** ripped from Pokémon Yellow (international release, GBC).

Source: [International Yellow sprites (Game Boy Color) — Bulbagarden
Archives](https://archives.bulbagarden.net/wiki/Category:International_Yellow_sprites_(Game_Boy_Color))

The files were fetched from the Bulbagarden archive file path for each species
in National Dex order (001 Bulbasaur … 151 Mew), e.g.
`Spr_1y_001.png` … `Spr_1y_151.png`, and renamed to the lowercase species
slugs used across the battle-art folders (`bulbasaur.png`, `mr-mime.png`,
`farfetchd.png`, etc.).

Unlike the Gen 2–5 collections, these are ordinary single-frame PNGs rather
than animation atlases: no Lua sidecar, frame grid, or timing metadata is
required. They are used as the default `ANIM FRONT GEN: GEN 1` front set, and
as the front fallback when `DUPLICATE FIX: MODDED` is selected and no shiny override
is present. Author opponent art facing left. Missing or malformed species fall
back directly to the ROM front sprite rather than borrowing from another
generation.

Front Pokémon remain world-placed in the current renderer. A separate
`FRONT PLACEMENT` selector is not implemented yet.

## Licensing / provenance

The Pokémon sprite artwork is third-party and is **not** covered by this mod's
MIT license. It is ignored by Git (see the repo `.gitignore`) and must be
supplied locally; verify that you have the right to use and redistribute it
before shipping a build that includes these files.
