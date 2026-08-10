# Front animated battle art

Optional opponent/player-front collections are grouped here as `gen1/`
through `gen5/`. Gen 1 is a single-frame PNG compatibility set; Gen 2–5 are
animated atlases. Local PNG files are ignored by Git. `ANIM FRONT GEN`
chooses exactly one folder in ANIMATED mode; missing or malformed art falls
back to the ROM sprite rather than silently mixing generations.

GIF decoding is authoring-only. The game reads PNG atlases, extracts every
cell at its native logical resolution, and uses nearest-neighbour filtering.
The importer creates both the Gen 2–5 atlases and the selected set's shared
metadata; users do not write one Lua file per Pokemon. Gen 1 instead accepts
one ordinary species PNG with no metadata. From the repository root, run one
of `python tools/import_animated_sprites.py --set gen2`, `--set gen3`,
`--set gen4`, or `--set gen5`. Gen 2 uses Crystal fronts, Gen 3 uses Emerald
fronts, Gen 4 uses Diamond/Pearl animated PNGs, and Gen 5 uses Black/White
fronts.

## Gen 1 filename exceptions

Most species use their ordinary lowercase name (`pikachu.png`). These four
engine names need the following exact filenames:

| Species | Expected filename | Do not use |
| --- | --- | --- |
| Mr. Mime | `mr-mime.png` | `mrmime.png`, `mr.mime.png` |
| Farfetch’d | `farfetchd.png` | `farfetched.png`, `farfetch-d.png` |
| Nidoran♀ | `nidoran-f.png` | `nidoran.png`, `nidoran-female.png` |
| Nidoran♂ | `nidoran-m.png` | `nidoran.png`, `nidoran-male.png` |

Filenames are lowercase. The same names apply in every battle-art folder.

Opponent trainer front pictures can never be animated and are not read from this
folder. Put every opponent trainer PNG in `../front-static/`, including while
`BATTLE ART` is set to `ANIMATED`.
