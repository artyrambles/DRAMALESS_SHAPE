# Front static battle art

Drop `<species>.png` files here, for example `caterpie.png` or `mr-mime.png`.
Files may use any pixel dimensions. Existing alpha is preserved; a fully
opaque image has its corner-coloured, border-connected background keyed out.

These local PNGs are ignored by Git. Missing or invalid files fall back to the
ROM sprite. Enemy sprites are used as authored (facing left).
Static species fronts preserve their authored brightness and colour in staged
battles: day/night tint is omitted for these PNGs, while display filters,
hit effects, depth occlusion, lighting and alpha-shaped shadows still apply.

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

## Static opponent trainer fronts

Opponent trainer pictures are never animated. Put complete opponent sets in
`gen1`, `gen2`, and `gen3`; the `TRAINER ART` option selects one of those
folders even when `BATTLE ART` is set to `ANIMATED`. The filename is the
engine trainer class in lowercase with underscores changed to hyphens:

youngster.png       bug-catcher.png     lass.png
sailor.png          jr-trainer-m.png    jr-trainer-f.png
pokemaniac.png      super-nerd.png      hiker.png
biker.png           burglar.png         engineer.png
fisher.png          swimmer.png         agatha.png
cue-ball.png        gambler.png         beauty.png
psychic-tr.png      rocker.png          juggler.png
tamer.png           bird-keeper.png     blackbelt.png
rival1.png          prof-oak.png        lance.png
scientist.png       giovanni.png        rocket.png
cooltrainer-m.png   cooltrainer-f.png   bruno.png
brock.png           misty.png           lt-surge.png
erika.png           koga.png            blaine.png
sabrina.png         gentleman.png       rival2.png
rival3.png          lorelei.png         channeler.png

Yellow's special Rocket pair uses `jessie-james.png`; other Rocket trainers
use `rocket.png`. A missing file in the selected generation retains the ROM
trainer picture. The runtime does not borrow it from either of the other sets.

The front static sprites work differently than animated, to allow mix & match.
Basically put any rightsized sprite named in here, and it will be in the game.