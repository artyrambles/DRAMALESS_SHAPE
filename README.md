# THIS BRANCH IS OUTDATED AND HAS BEEN MERGED INTO MAIN.
IT WILL BE DELETED IN THE FUTURE.

# Dramaless Shape 2.0

Dramaless Shape renders the Gen1Recomp overworld as a depth-buffered voxel
diorama. 
Version 2.0 strictly only provices voxel environments plus one legacy feature:
native Gen 1 2D battle cards staged on the voxel map.

This is an experimental split release based on the Dramaless development line.
Keep Dramaless 1.6.4 LTS archived if you want the former combined feature set.

## Features That Were Split From Dramaless Starting at v2.0

Dramaless now only handles voxel terrain, buildings, overworld figures, lighting, water,
shadows, camera modes, tilt shift, performance settings, voxel-map arena
rendering, and its native-2D card renderer. It does not handle Stadium Pokemon
models, replacement sprite packs, move animations, HUDs, disc stages, battle
transitions, or VR.

[StadiumBattleFX](https://github.com/anxiousintrovert/StadiumBattleFX) 2.x
now includes all the Stadium-related features that were removed from Dramaless. 
When both mods are installed, Dramaless registers `DRAMALESS_SHAPE:voxel-map` 
in the arena selector and `DRAMALESS_SHAPE:voxel-cards` in the model selector. 
The selectors are independent, so players can pair voxel cards with a Stadium 
arena or pair Stadium models with the voxel map.

Without StadiumBattleFX, Dramaless uses its own small standalone host for the
`VOXEL ARENA + 2D CARDS` option. The arena remains a fully depth-buffered 3D
voxel environment; only the Pokemon and trainer cards are 2D. It automatically
yields when StadiumBattleFX is installed so the two don't clash.

Mixed legacy/2.0 installs are blocked by manifest ranges. Use legacy with
legacy, or 2.x with 2.x.

## Installation

Install the release ZIP through Gen1Recomp's mod manager or extract it as
`mods/DRAMALESS_SHAPE`. This experimental build targets mod API 2 and declares
its required engine range in `manifest.json`.

## Main controls

- `V`: cycle voxel camera modes (FULL remains an options-menu preset).
- `G`: toggle voxel grid lines.
- `T`: cycle tilt shift.
- `C`: cycle world curvature.
- `9`: cycle water rendering.

First- and third-person modes retain camera-relative movement and input. The
quality, shadow, antialiasing, water, day/night, grid, and curvature settings
remain available. `VOXEL ARENA + 2D CARDS` is shown when StadiumBattleFX is
absent. `BACK SPRITES` is available by default. It keeps the player's original 
back sprite in the UI while the enemy remains staged in the arena. 
The old multi-mode `3D-BTL` selector and all VR settings are gone.

## Performance And Optimization
Compared to the original DramaticShape, this mod strives to perform well
on most devices. For this reason, options were added (and more are being
worked on) that allow the player to lower the render resolution or render
distance.
These features are still being worked on and will improve in the future.

## Diagnostics

The Logging options is currently disabled to conform with changes to the
modding API. It will be restored later.

## License and attribution

Code is distributed under the MIT License beginning with 2.0. See
`LICENSE`. This fork contains fixes and additions by Stahltier (artyrambles)
based on DramaticShapeVoxelMod 1.6.2, and incorporates MIT-licensed work from
Terrarium as well as Battle Art. The removed OpenXR loader is not distributed in 2.0.

Pokemon and Nintendo trademarks belong to their respective owners. This is an
unofficial fan-made mod and includes no ROM data.

> ### This is a standalone fork, not the original or main version of the Dramatic Shape Voxel mod!

> **The original and main version of the mod was here, but may currently be defunct:**
> https://github.com/DramaticShape/DramaticShapeVoxelMod
>
> `DRAMALESS SHAPE` is not associated with or endorsed by the original DramaticShape mod
> and its creator. I made this because I was a fan of the original mod's vision and
> wanted to help improve it according to my own ideas and suggestions from the community.

> DramaticShapeVoxelMod's v1.6.1, which this mod is based on, was released under the MIT License and allows anyone to modify and redistribute it. No part of this mod was stolen
> or created with malicious intentions. 
>All contributions from other creators besides myself have been credited to the
> best of my knowledge.

>I have nothing but respect for my fellow modders. This mod wouldn't have been possible
>without the help and contributions from others.

# AI Usage Disclosure
## What is NOT made with AI or AI assistance

***Any additions and edits that I (Stahltier) made to the Dramaless Shape fork myself***
***were NOT created or in any way touched by AI.***
**My code is all 100% organic home-grown human-made spaghetti, baby!**

However I acknowledge that many passionate people do not have the skills
yet that would be needed to tackle a project of this size, and I am grateful
for anyone who is helping contribute to it in any way they can.

I am not rejecting or disparaging creators who use AI in some way to
contribute to this project. But as everyone should be acutely aware,
AI can make mistakes that are very hard to catch if the person using it
cannot verify themselves what their AI is doing.

That is why I am making extra sure as the current maintainer of this mod that
any code that is contributed is at least looked over once and I test new releases
before publishing them to make sure nothing slipped by. It is very likely that
the entire foundation the code stands on was built by AI, which makes it extra
difficult to work with.

There can be hundreds of files with thousands of lines to review especially when
it comes to extensive changes for an update. That is why I will always prefer
human-written and human-documented code.

## Made with AI assistance (Terrarium, Battle Arts, StadiumBattleFX)

**Large parts of the mod's current code were written with the help of AI coding
assistants** (Anthropic's Claude, among others).

What that means in practice:

- The code was **directed, tested and accepted by humans**. Features
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

### Contributions of and containing AI-generated Code
I will approve contributions by creators who use AI, but it may take longer
because of the quality and responsibilty standards I hold the mods I release
to the public to.
I am only human, and it is very easy to miss problems with AI-generated code
as it tends to be very convoluted and hard to read for a human.

If I become aware of faulty AI-contributed code, I reserve the right to roll
back the mod version, remove contributions, or even refuse further contributions 
from the same creator (if it's really severe).