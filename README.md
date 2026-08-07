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

**Pokémon Red, Pokémon Blue and Pokémon Yellow are © 1996-1999 Nintendo,
Creatures Inc. and GAME FREAK Inc. "Pokémon", "Nintendo" and "Game Boy" are
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
  any PokÃ©mon title. It never has and it never will. The `.gitignore` here
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
drawn or generated for this mod.

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
- Added Shadow Quality options to the menu for performance improvements.

### It runs on weak hardware (Terrarium Code)

The Quality options were made for the TERRARIUM fork, and I've included it
with my version.

Two new rows on the OPTIONS menu, both visible under every preset:

| row | values | default | what it does |
| --- | --- | --- | --- |
| **RES** | 1/2 | 1/3 | 1/4 | FULL | **1/2** | divides the resolution the 3D pass rasterises at before it is scaled back up. Every cost in the pass is quadratic in it: 1/2 is four times less of everything, 1/3 is nine. Upscaled *nearest*, so the result is chunkier, not blurrier â€” the right defect for this art. |
| **SHADOWS** | LOW | OFF | HIGH | SOFT | **LOW** | LOW keeps real cast shadows on a 512â€“1024 texel map instead of 2048, one tap instead of four, no neighbouring maps casting, redrawn every second frame while walking. |

Plus spatial culling, and a shadow-map size ladder chosen per frame from how
much world is actually in view.

---

## Requirements

- **[Gen1Recomp](https://github.com/bryanthaboi/gen1recomp) v0.1.70 or newer**
  (developed against v0.1.69)
- A Pokemon Gen1 ROM you dumped yourself. **This project does not supply one.**
- If Stadium Models should be used, you also need an US Stadium 1.0 ROM. Which is
  obviously also not included here, but I tried to make the install process
  easier and smoother.

## Installing

Drop the unzipped folder into your Gen1Recomp `mods/` directory, or import the 
packaged zip through the launcher's mods tab.

**Name the installed folder `DRAMALESS_SHAPE`.** That matches the mod id in
`manifest.json`.

This fork is **independent** of upstream `DRAMATIC_SHAPE`: different id,
different folder, different cache.
`TERRARIUM` is also NOT required.

In fact, I listed both DRAMATIC_SHAPE and TERRARIUM as hard incompatibilities.
Please disable both if you install DRAMALESS_SHAPE, to prevent any possible bugs.

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
| `assets/` | contains a dll for VR mode |

---

## License - please read before forking

**The original mod is now defunct as it was taken down by its creator**. 
Please see the LICENSE.md for details about what you are allowed or not allowed
to do with the code of this mod.

This fork is published in the spirit the original was: freely, for other
people to read, run and learn from, but I cannot grant you rights over code
that is not mine to license. If you plan to build on this, **please read and
follow the LICENSE document.**

Permission to make my fork (DRAMALESS_SHAPE) was given by DramaticShape aka
KingOfSpain in the BOI'S CLUB GAMES Discord (see ForkPermission.jpg).
Anyone is free to use my edits and additions to the code to add to their own
forks or versions of the mod as long as you don't try to impersonate me or
try to make money off it, as is stated int he LICENSE document.

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
- **[iOS UI fixes (wip)](https://github.com/absol89/DramaticShapeVoxelMod/commit/71c800eb143ee3aee49126d675c488282972d3c9)**
  An attempt to fix the iOS UI issues, but not working yet.
- **Nintendo, Creatures Inc. and GAME FREAK Inc.**: for the game. It is
  theirs. This is only a coat of paint on a program that loads it.
