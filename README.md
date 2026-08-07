# Dramaless Shape

Draws the overworld as a 3D diorama. Fork with edits by Stahltier, including code and
assets from TERRARIUM by BrenoBertucci.

> ### This is a fork, not the original or main version of the Dramatic Shape Voxel mod!
>
> **Dramaless Shape is a fork of the [Dramatic Shape Voxel Mod](https://github.com/DramaticShape/DramaticShapeVoxelMod)
> by [Dramatic Shape](https://github.com/DramaticShape).**
> I've made many edits and merged in code and assets from the [TERRARIUM](https://github.com/BrenoBertucci/Terrarium)
> fork created by BrenoBertucci.
>
> **The original and main version of the mod is found here:**
> https://github.com/DramaticShape/DramaticShapeVoxelMod
>
> It ships under its own mod id `TERRARIUM` and its own folder, so it can
> sit **beside** the original without overwriting it. Both can be installed;
> both can be installed and enabled together: this fork uses letter hotkeys
> (v/g/t/c/b/n/p) and its own pipeline ids, so it does not fight upstream's
> 3/5/6/7/8/9. Still only one world pipeline should own the frame at a time.

A mod for the [PokÃ©mon Gen 1 Recompilation
Project](https://github.com/bryanthaboi/gen1recomp). The overworld becomes a
3D diorama: terrain extruded into real geometry, cast shadows that stretch
through the afternoon, a six-phase day/night cycle with a painted sky and
stars, weather that leaves puddles and snow on the ground, and wild PokÃ©mon
standing in the grass where you can see them.

> **This is a fan-made modification. It is not a game, and it contains no part
> of any Nintendo product.** Please read [Legal](#legal) before anything else.

---

## Legal

**PokÃ©mon Red, PokÃ©mon Blue and PokÃ©mon Yellow are Â© 1996â€“1999 Nintendo,
Creatures Inc. and GAME FREAK Inc. "PokÃ©mon", "Nintendo" and "Game Boy" are
trademarks of their respective owners. All rights in the games, characters,
names, artwork, music and every other element of them belong to those
companies and to nobody else.**

This project is:

- **Unofficial and unaffiliated.** It is not made by, endorsed by, sponsored
  by, licensed by, or associated with Nintendo, Creatures Inc., GAME FREAK
  Inc., The PokÃ©mon Company, or any of their subsidiaries or partners.
- **Not a game, and not a way to get one.** It is a modification: a set of
  Lua scripts and original art that changes how an already-installed program
  draws itself. On its own it does nothing at all.
- **Free of Nintendo's data.** This repository contains **no ROM, no ROM
  patch, no game code, no sprite, no map, no music and no sound** taken from
  any PokÃ©mon title. It never has and it never will â€” the `.gitignore` here
  blocks ROMs, dumps, saves and patch files (`.bps`, `.ips`, `.ups`) so that
  one cannot be committed by accident.
- **Dependent on a copy you already own.** Gen1Recomp reads a ROM that the
  player dumps from their own cartridge. **Do not ask this project for a ROM,
  and do not link one in an issue or a pull request** â€” such a request will be
  closed and such a link removed.
- **Non-commercial.** It is given away. No part of it is sold, and no
  donations, ads or paid tiers are attached to it. It is a hobby project made
  out of affection for a thirty-year-old game.

The original art assets shipped here (ground textures, voxel models) were
drawn or generated for this mod. The ambient audio is CC0 public domain, with
every source and author named in
[`assets/audio/CREDITS.md`](assets/audio/CREDITS.md).

**If a rights holder objects to anything in this repository, open an issue or
contact me and it will be taken down promptly.** No argument, no delay.

---

## Made with AI assistance (Terrarium Code ONLY)

**Large parts of the Terrarium fork were written with the help of AI coding
assistants** (Anthropic's Claude, among others). This is stated plainly and up
front, not buried, because you have a right to know what you are installing
and reviewing.

What that means in practice:

- The code was **directed, tested and accepted by a human** â€” me. Features
  were specified, measured, and rejected when the measurement did not support
  them. It is not generated and dumped.
- Much of it is **verified by probes rather than by eye.** The `tests/`
  directory holds twenty self-contained probes that drive the real game
  headless and write numbers to a log â€” shadow lengths, palette ramps, pixel
  classifications, frame-time medians. Where this README claims a number, a
  probe produced it.
- It carries the usual caveat all the same: **read it before you trust it.**
  AI-assisted code can be confidently wrong, and some of this is in the render
  path of a program you are running on your own machine.

## NOT made with AI or AI assistance

***Any additions and edits that the Dramaless Shape fork make were NOT created or
in any way touched by AI.***
**My code is all 100% organic home-grown human-made
spaghetti baby**

---

## What the fork(s) is/are based on

The base is Dramatic Shape's **1.6.2**: the voxel diorama, the depth-buffered
occlusion, the leaning sprite slabs, the shadow map, VR, AA, the tilt-shift 
pass, the Stadium ROM compatibility, and the over-the-shoulder battles.
All of that is his work, and it is the reason any of this exists.

Terrarium uses Dramatic Shape 1.3.0 as its base. 
My edits were based on 1.6.2 and carry the `.ST` version numbering. 
See [`CHANGELOG.md`](CHANGELOG.md) for the full history.

### Changes made by Stahltier (Dramaless Shape Code)
- VoxelGrid option is now respected in the 3D Battle screen, if turned OFF it no
  no longer draws the voxel outlines.
- Stadium ROM install path fixed for unrooted mobile devices. Please see the
  STADIUM_ROM_GUIDE.md for instructions how to install the ROM properly on mobile.
- Larger Stadium models. They were scaled up in comparison to the environment so
  your big ass Gyarados will no longer look like a little blue Caterpie next to a flower.
- Adjusted Battle Cam and Stadium Stages. To account for the larger models, the battle
  camera's position and FoV was adjusted, and the battlers were moved further apart.
  The ground discs of Stadium Mode B were also scaled accordingly.

### It runs on weak hardware (Terrarium Code)

This was the whole point of the fork. The original targeted a desktop; this
one was made to run on an entry-level Android (a Samsung A14 5G â€” two-core
Mali, 2408Ã—1080 panel) and on a low-end PC. Development and every measurement
in this repo happen on an **Intel i3-1115G4 with integrated UHD graphics**.

Two new rows on the OPTIONS menu, both visible under every preset:

| row | values | default | what it does |
| --- | --- | --- | --- |
| **RES** | 1/2 | 1/3 | 1/4 | FULL | **1/2** | divides the resolution the 3D pass rasterises at before it is scaled back up. Every cost in the pass is quadratic in it: 1/2 is four times less of everything, 1/3 is nine. Upscaled *nearest*, so the result is chunkier, not blurrier â€” the right defect for this art. |
| **SHADOWS** | LOW | OFF | HIGH | SOFT | **LOW** | LOW keeps real cast shadows on a 512â€“1024 texel map instead of 2048, one tap instead of four, no neighbouring maps casting, redrawn every second frame while walking. |

Plus spatial culling, and a shadow-map size ladder chosen per frame from how
much world is actually in view.

### Wild PokÃ©mon you can see (Terrarium Code)

The **WILD** row. The map's own encounter table decides who is standing in the
grass right now; they wander their own patch in their own art, and the fight
starts when you walk into one â€” so a route can be picked through, hunted, or
crossed without a single battle.

This is the one feature that touches the game rather than the drawing of it,
which is exactly why it is a row with an OFF: **switch it off and the game
rolls its dice precisely as it always did.**

### And the rest of it (Terrarium Code)

| row | what it is |
| --- | --- |
| **RTX** | a screen-space row walked through the depth buffer the 3D pass already filled: ambient occlusion in corners the sky cannot reach, reflections marched across the water's own swell, light shafts toward the sun. OFF is byte-for-byte the old frame. |
| **CITY** | PokÃ©mon loose in the streets of every town, and civilian NPCs that glance as you pass |
| **ROUTINES / SHELTER** | civilians look around, turn toward the sign they are standing beside, talk in pairs â€” and walk to the nearest doorway when a shower comes down hard |
| **WEATHER** | rain and snow, folded into the light rather than drawn over it |
| **WIND** | the tall grass is geometry, so wind is a bend and not a slid picture: the base stays planted, the tip gives and drops as it goes over, each tuft has its own stiffness, and the gust travels across a meadow. Rain weighs the blades down and damps them; settled snow bows them and piles white on the crowns; walkers lay them flat and they spring back, leaving a trail you can turn round and see. AUTO hands the row to the climate -- calm night, breeze by day, gale under a front, no menu trips. Plus the air itself: dust and spray streaks, and a gust front crossing the frame as a line |
| **GROUND** | what the weather leaves behind: puddles that gather through a shower and are still there ten minutes later wearing the sky's own colour, snow settling in drifts, footprints behind everyone walking on it |
| **ECOLOGY** | Gen 2's time-of-day encounters built out of Gen 1's single table â€” the nocturnal half of the dex comes up after dark, birds and caterpillars by day, by reweighting the map's own ten slot buckets rather than adding or removing anything |
| **WATER** | a cel-shaded swell: two crossing wave trains, analytic normals, depth-rung colour and binary foam (toon water ideas, hard steps only â€” not PBR). CALM / SWELL / FLAT. Rain and wind feed chop energy; freeze turns the surface into walkable ice when the party can Surf |
| **QOL** | type-effectiveness hints on the FIGHT menu, auto-repel, and HMs on an A press (CUT at a tree, SURF at water, STRENGTH at a boulder) |
| **BAG / STACK** | twenty item slots and ninety-nine per stack were Game Boy save-RAM limits, not design. Raise both. |
| **AUTO-FARM** | pick a party slot and a bot trains it, always picking the strongest move against what it faces |
| **GLINT** | a thin reflection sweeping across window panes as you walk |

### Cel water (measured) (Terrarium Code)

The water is geometry, not a flat scrolling tile. Identity is the height test
alone (`y < -1` â€” recessed two world pixels so the shoreline shows a lip).
Displacement is Y = f(XZ) only, so an unindexed mesh never opens a seam.
The normal is two cosines of the same trains â€” analytic, free, exact.

Paint stays in the mod's four-colour dialect: hard `step`s, checker dither,
bands re-evaluated on a world-XZ cell (the sky's own `floor(sc/cell)` idiom).
Ideas from [Roy Stan's Toon Water Shader](https://roystan.net/articles/toon-water/)
are adapted here (depth-rung tint, binary surface-noise foam, shoreline foam)
without a second render target, without a normal map, and without soft
airbrush gradients. See [Credits](#credits).

**Shimmer is a number, not a screenshot.** `tests/water_shimmer_probe.lua`
freezes weather, wind, clock and NPCs, builds a water mask by FLAT-vs-SWELL
diff, then counts water pixels that change between consecutive frames under
ablations (tile roll / geometry / glint window / SSR). On VERMILION_CITY at
the default RES 1/2 rung, with climate off:

| | continuous background | of sampled water |
| --- | ---: | ---: |
| before anti-crawl pass | ~4125 px | **~5.9%** |
| after (`RATE` 0.9â†’0.55 + mid-pond foam gated on chop/rain) | ~1510â€“1890 px | **~2.2â€“2.7%** |

So about **half the continuous churn** on a calm clear pond. Ablation on the
pre-pass baseline: almost all of that churn was swell + cel paint; the
tileset roll, the glint rings and SSR each moved under 5% of the count.
`PAINT_PHASE_STEP` (temporal snap of paint phase) and a coarser paint cell
were tried and rejected â€” the first turned crawl into full-pond flashes, the
second made the palindrome unreadable. Knobs remain in `lib/Water.lua` at
safe defaults. Puddle SSR shares RayFX with the pond; `tests/puddle_rtx_probe.lua`
is the regression gate and still passes.

### Day, night, and the sky (Terrarium Code)

The clock runs a six-phase dial â€” dawn, golden hour, day, dusk, violet
twilight, night â€” with a hand-quantised sky palette per phase on the Game Boy
Color's own 5-bit lattice, a dithered gradient, and a cell-art sun and moon.

The most recent work went here, and it is measured rather than eyeballed:

- **Every phase is now actually painted.** The dial used to hold `day` and
  `night` and pass *through* the other four: measured a second at a time,
  `dawn`, `golden` and `dusk` held for one second each and `violet` for none
  at all â€” four hand-authored palettes that were never shown. They now hold
  45â€“137 seconds each, and the sunrise runs dawn â†’ golden â†’ day the way the
  evening already ran day â†’ golden â†’ dusk.
- **Stars, and the occasional meteor.** A fixed 96-star field on the sky's own
  cell grid, posterised to four brightness rungs and twinkling on their own
  phases, fading in with the night and gone under an overcast. Star count is a
  rung on the quality ladder.
- **The night is darker, and the town is lit.** A lit window is exempt from
  the hour's tint in the shader, so taking a quarter of the light out of the
  night makes a town read as windows in the dark rather than as a blue-filtered
  afternoon. Each pane now burns at its own brightness, so a wall of windows
  is a wall of rooms.
- **Evening shadows stretch.** The shear clamp was cutting a full-strength
  shadow for 300 seconds of every 1200 â€” right through the golden hour. It is
  now derived from the fade angle instead, so it can only ever shorten a
  shadow already on its way out. Measured cost: `+0.015 ms` per frame.

---

## Requirements

- **[Gen1Recomp](https://github.com/bryanthaboi/gen1recomp) v0.1.70 or newer**
  (developed against v0.1.69)
- A Pokemon Gen1 ROM you dumped yourself. **This project does not supply one.**
- If Stadium Models should be used, you also need an US Stadium 1.0 ROM. Which is
  obviously also not included here, even if I tried to make the install process
  easier and smoother.

## Installing

Drop the folder into your Gen1Recomp `mods/` directory, or import the packaged
zip through the launcher's mods tab.

**Name the installed folder `DRAMALESS_SHAPE`.** That matches the mod id in
`manifest.json`. Probes under `tests/` launch as
`mods/DRAMALESS_SHAPE/tests/<probe>.lua`.

This fork is **independent** of upstream `DRAMATIC_SHAPE`: different id,
different folder, different pipeline registry keys (`st_voxel` /
`st_tiltshift`).
`TERRARIUM` is also NOT required.

In fact, I listed both DRAMATIC_SHAPE and TERRARIUM as hard incompatibilities.
Please disable both if you install DRAMALESS_SHAPE, to prevent any possible bugs.

**Letter hotkeys (DRAMALESS_SHAPE):** `v` VOXEL | `g` V-GRID | `t` T-SHIFT | `c` V-CURVE | `b` 3D-BTL | `n` WILD | `p` MAP.
`c` V-CURVE | `b` 3D-BTL | `n` WILD | `p` MAP.

## Quiver / launcher packaging

- Install folder must be `mods/DRAMALESS_SHAPE` (matches `manifest.json` id).
- Catalog metadata for a future index entry lives in
  [`quiver-catalog-entry.json`](quiver-catalog-entry.json) (folder key
  `stahl@DRAMALESS_SHAPE`) and a one-mod local index in
  [`quiver-local-index.json`](quiver-local-index.json).
- Pack manifest with hashes: [`.modkit/pack.json`](.modkit/pack.json).
- Reinstalling upstream `DRAMATIC_SHAPE` from Quiver only touches that
  folder; it cannot overwrite `DRAMALESS_SHAPE`.


Every feature is a row on the OPTIONS menu with an OFF. If something is too
slow, too bright or too much, turn that row off; nothing here is load-bearing
for anything else.

## Repository layout

| path | what it is |
| --- | --- |
| [`FEATURES.md`](FEATURES.md) | the full manual â€” every row, every control, every rule |
| [`MOBILE.md`](MOBILE.md) | why the fork exists and what was changed to make it run (Portuguese) |
| [`CHANGELOG.md`](CHANGELOG.md) | thirty-one releases, with the reasoning for each |
| [`STADIUM_ROM_GUIDE.md`](STADIUM_ROM_GUIDE.md) | info for installing Stadium models on mobile devices |
| `lib/` | the mod itself |
| `tests/` | twenty self-contained probes that drive the real game and write numbers |
| `assets/` | original art, CC0 audio, and the building/voxel documentation |
| `tools/` | authoring scripts â€” they run by hand, not at play time |

---

## Licence â€” please read before forking

**The upstream mod does not currently carry a licence file**, and neither does
the TERRARIUM fork. Under default copyright that means the code is *not* granted for
redistribution or modification, however freely it is shared in practice, and
[an open request for one](https://github.com/DramaticShape/DramaticShapeVoxelMod/issues/45)
is sitting on the original repository.

This fork is published in the spirit the original was â€” freely, for other
people to read, run and learn from â€” but I cannot grant you rights over code
that is not mine to license. If you plan to build on this, **please talk to
Dramatic Shape first.** If a licence lands upstream, this fork will adopt it.

Permission to make my fork (DRAMALESS_SHAPE) was given by DramaticShape aka
KingOfSpain in the BOI'S CLUB GAMES Discord (see ForkPermission.jpg).
Anyone is free to use my edits and additions to the code to add to their own
forks or versions of the mod as long as you don't try to impersonate me or
try to make money off it.

## Credits

- **[Dramatic Shape](https://github.com/DramaticShape/DramaticShapeVoxelMod)**
  â€” the voxel mod this is built on. The diorama, the battles and the shape of
  the whole thing are his.
- **[bryanthaboi](https://github.com/bryanthaboi/gen1recomp)** and the
  Gen1Recomp contributors â€” the engine, and a mod platform generous enough
  that almost none of this needed a patch.
- **[Terrarium](https://github.com/BrenoBertucci/Terrarium)**
  The fork created by BrenoBertucci from which my fork heavily draws assets and
  code, see further above for a full list of their work.
- **Water shading heavily inspired by Roy Stanâ€™s Toon Water Shader tutorial**
  ([article](https://roystan.net/articles/toon-water/),
  [source](https://github.com/IronWarrior/ToonWaterShader)) â€” depth-rung
  colour, binary surface-noise foam, and shoreline foam ideas adapted to the
  modâ€™s voxel/cel system (hard steps, checker dither, analytic swell, no
  depth/normals buffer RT). Not a port of the Unity shader.
- **Ambient audio** â€” CC0, every recordist named in
  [`assets/audio/CREDITS.md`](assets/audio/CREDITS.md).
- **Nintendo, Creatures Inc. and GAME FREAK Inc.** â€” for the game. It is
  theirs. This is only a coat of paint on a program that loads it.
