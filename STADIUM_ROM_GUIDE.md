# Stadium ROM Guide

**First of all, you need your own ROM. I cannot provide a ROM file to you, and there will never be a**
**ROM file included in this repo or even any instructions on where to find one. This for LEGAL reasons**
**because distributing ROMs via the internet is not legal in many countries.**

> This project expects a 1.0 version of the US Pokemon Stadium ROM. It is often also labeled as Revision 0.
> Any other ROM version will most likely not work.
> The expected md5 is `ed1378bc12115f71209a77844965ba50`, and the file needs to be 32MB in size (though my own was 32.5MB
> and seems to work just fine, but when in doubt please stick to the specs).

### Note for Android and iOS players:
- `STADIUM ROM WHERE?` in Options does not update until **after** the sprite import is triggered. You must 
  **load your save and enter the overworld** to trigger the import.
- If starting a new save, you must finish the full Oak intro, name your character and rival, and enter the overworld 
  before the sprite import will trigger.

## Installation on PC
- Have your ROM file ready. The location doesn't matter on PC, as long as the folder isn't protected or in some other
  way inaccessible.
- Install the DRAMALESS_SHAPE mod and confirm that it's working.
- Back out into the title screen of your game (the one where Red is standing and the sprite slide behind him).
- Go to the OPTIONS menu, make sure the game isn't in fullscreen or borderless fullscreen as this might hide
  the filepicker window and cause the game to appear softlocked.
- Find the option that says Stadium Import and select it.
- (wip, please stay tuned)

## Installation on Android
- Create a new folder named `baseroms` in `/storage/emulated/0/android/data/com.theboisclub.pokemonred/files/save/pokemon-love2d/`
- Move Stadium.z64 rom to your newly created `baseroms` folder, rename rom to exactly `baserom.z64`
- Open Gen1Recomp, launch Red, Blue, or Yellow.
- **Load your save and finish the Oak intro on a new save to trigger the model extraction**
- After extraction screen is complete, go to Options and change `3D-BTL` to `Stadium A/B`

## Installation on iOS
- Extract the `DRAMALESS_SHAPE-1.x.x.zip` so you have a working folder named `DRAMALESS_SHAPE-1.x.x`.
- Rename your Stadium 1.z64 rom to `baserom.z64` and move into existing folder `DRAMALESS_SHAPE-1.x.x/model_extract/baseroms/`.
- Open `DRAMALESS_SHAPE-1.x.x/lib/StadiumInstall.lua` in a text editor.
- In `StadiumInstall.lua`:
  - Go to Line 51 (or search for) and change `StadiumInstall.ROM_DIR = "baseroms"` to `StadiumInstall.ROM_DIR = "mods/DRAMALESS_SHAPE/model_extract/baseroms"`
  - Save `StadiumInstall.lua`.
- Compress/zip your `DRAMALESS_SHAPE-1.x.x` folder into a new .zip named `Modified-DRAMALESS_SHAPE-1.x.x.zip`
- Open Gen1Recomp and import your modified `DRAMALESS_SHAPE-1.x.x.zip` as normal.
- Launch Red, Blue, or Yellow.
- **Load your save / finish the Oak intro on a new save to trigger the model extraction**
- After extraction screen is complete, go to Options and change `3D-BTL` to `Stadium A/B`