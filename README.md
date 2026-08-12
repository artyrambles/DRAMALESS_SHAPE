# Dramaless Shape 2.0

Dramaless Shape renders the Gen1Recomp overworld as a depth-buffered voxel
diorama. Version 2.0 owns voxel environments plus one narrow legacy mode:
native Gen 1 2D battle cards staged on the voxel map.

This is an experimental split release based on the Dramaless development line.
Keep Dramaless 1.6.4 LTS archived if you want the former combined feature set.

## Ownership boundary

Dramaless owns voxel terrain, buildings, overworld figures, lighting, water,
shadows, camera modes, tilt shift, performance settings, voxel-map arena
rendering, and its native-2D card renderer. It does not own Stadium Pokemon
models, replacement sprite packs, move animations, HUDs, disc stages, battle
transitions, or VR.

[StadiumBattleFX](https://github.com/anxiousintrovert/StadiumBattleFX) 2.x is
the modular battle-presentation host. When both mods are installed, Dramaless
registers `DRAMALESS_SHAPE:voxel-map` in the arena selector and
`DRAMALESS_SHAPE:voxel-cards` in the model selector. The selectors are
independent, so players can pair voxel cards with a Stadium arena or pair
Stadium models with the voxel map.

Without StadiumBattleFX, Dramaless uses its own small standalone host for the
`VOXEL ARENA + 2D CARDS` option. The arena remains a fully depth-buffered 3D
voxel environment; only the Pokemon and trainer cards are 2D. It automatically
yields when StadiumBattleFX is installed, avoiding two battle compositors or
two sets of selectors.

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
absent. `BACK SPRITES` is available whenever Dramaless's native-card provider
is selected; it keeps the player's original back picture in the menu slot
while the enemy remains staged in the arena. The old multi-mode `3D-BTL`
selector and all VR settings are gone.

## StadiumBattleFX integration

The optional providers use only StadiumBattleFX Battle Presentation API 1. The
arena provider
searches the current map's authored location first, then a generic safe
location on the same map. If neither is suitable, it returns the API fallback
sentinel and StadiumBattleFX uses its own arena.

Dramaless owns the voxel canvas, depth buffer, and terrain shader. It consumes
the host-resolved camera pose and
invokes the host's actor callback exactly once inside that depth pass; it never
calls or imports a model provider.

The card provider preserves Dramaless's original one-to-one native-picture
capture, front-art mirroring, world scale, and depth-tested voxel billboards,
including trainer/send-out and ordinary battle-picture state. On a non-voxel
arena it uses the host projection seam instead. StadiumBattleFX supplies the
lifecycle, camera, arena selection, and a scoped native-picture capture
service. The card provider does not replace the HUD, transitions, or
move-animation player.

## Diagnostics

The mod records bounded, structured event logs at
`dramaless_shape/dramaless_shape.log` in the LOVE save directory. Use
`EXPORT DIAGNOSTIC LOG` in Options to save a copy. Windows and macOS use a
save dialog. Linux uses Zenity or KDialog when available; SteamOS Game Mode
falls back to Downloads and then the LOVE save directory.

Logs contain lifecycle, option, mesh/cache, integration, and error events.
They do not contain ROM bytes, save contents, tokens, or full source paths.

## Development

The stable cross-mod contract is StadiumBattleFX's
`docs/BATTLE_PRESENTATION_API.md`. Dramaless exports its provider as
`mod.exports.voxelArenaProvider` and `mod.exports.voxelCardProvider` for
diagnostics, but other mods should
register directly with StadiumBattleFX rather than depending on Dramaless
internals.

The Battle Cinematics 0.7.96 transition adapter is Stadium-owned and does not
require Battle Cinematics to detect Dramaless. This arena simply consumes the
host-resolved pose like any other camera selection.

Build an installable archive with:

```powershell
./tools/package_mod.ps1
```

## License and attribution

Code is distributed under the MIT License beginning with 2.0. See
`LICENSE`. This fork contains fixes and additions by Stahltier (artyrambles)
based on DramaticShapeVoxelMod 1.6.2, and incorporates MIT-licensed work from
Terrarium. The removed OpenXR loader is not distributed in 2.0.

Pokemon and Nintendo trademarks belong to their respective owners. This is an
unofficial fan-made mod and includes no ROM data.
