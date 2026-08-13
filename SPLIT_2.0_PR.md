# Dramaless 2.0 voxel split PR ledger

Base: `origin/battle-art-merge` at `249ff2a` (planned 1.6.5 line).

Branch/worktree: `agent/2.0-voxel-only` in
`DRAMALESS_SHAPE-2.0-voxel-only`.

## Result

Dramaless 2.0 owns voxel environments and retains one narrow standalone battle
mode: native Gen 1 2D cards on its voxel map. StadiumBattleFX 2.0 owns modular
battle presentation, Stadium models, and the provider selectors. Dramaless
registers two optional API 1 components: arena
`DRAMALESS_SHAPE:voxel-map` and models
`DRAMALESS_SHAPE:voxel-cards`.

## Implemented changes

- The voxel arena consumes StadiumBattleFX's resolved
  `context.services.camera` pose. Camera compatibility remains host-owned and
  does not require Battle Cinematics to detect Dramaless 2.0.

- Replaced the intertwined 1.x entry point with a voxel-only pipeline entry.
- Added `VoxelBattleArenaProvider`, `VoxelBattleScene`, a native-2D card
  provider, a Stadium-absent standalone host, and the optional API-1
  registration bridge.
- The provider searches authored locations, then generic safe same-map
  locations, and returns `FALLBACK` when no ready environment is available.
- The provider owns its canvas, depth buffer, terrain shader, palette, water,
  foliage, and camera, and calls `drawActors` once as the final shared-depth
  draw.
- When StadiumBattleFX is present, the standalone host yields and the arena
  and card providers appear in Stadium's independent selectors. When Stadium
  is absent, `VOXEL ARENA + 2D CARDS` runs the same two providers locally; the
  voxel environment remains fully 3D and only its staged cards are 2D.
- Preserved voxel overworld rendering, free camera/movement, lighting,
  day/night, water, shadows, tilt shift, AA, quality controls, mesh refresh,
  and precaching.
- Added bounded structured logging and export on Windows, macOS, Linux, and
  SteamOS (Zenity/KDialog, Downloads, then LOVE save fallback).
- Set 2.0.0 experimental metadata, optional Stadium 2.x ordering, and a hard
  conflict with Stadium versions below 2.0.
- Rewrote README, mod card, changelog, MIT attribution, and packaging around
  the new ownership boundary.

## Removed from Dramaless

- Stadium model runtime, extraction pipeline, ROM picker/guide, cache builder,
  model tests, and base-ROM placeholder.
- BattleArt code, animation metadata, sprite imports, and all bundled battle
  artwork.
- The old staged-battle compositor, HUD/transitions, the multi-rung `3D-BTL`
  selector, and portable disc stages. Native engine 2D cards survive only in
  the extracted provider/standalone path.
- Horde spillover modules.
- OpenXR/VR modules, loader binary, Apache notice payload, options, and hooks.

The deletion is intentionally large (roughly 2,000 tracked files), mostly
BattleArt PNGs. Git retains the complete 1.6.x history and 1.6.4 remains the
legacy LTS release.

## Validation completed

- All 45 runtime Lua files compile under Lua 5.1.
- Boundary test confirms retired modules/assets are absent and the retained
  card path is narrowly scoped.
- Optional bridge test passes with both arena and model registrations.
- Cross-mod test loads StadiumBattleFX's real API-1 registry and resolves the
  Dramaless providers selected as `DRAMALESS_SHAPE:voxel-map` and
  `DRAMALESS_SHAPE:voxel-cards`.
- Card-provider unit test covers native side capture, projection, visibility,
  and native-sprite coverage.
- Real Gen1Recomp framebuffer probes pass for native cards on the voxel arena
  through StadiumBattleFX, native cards on Stadium's built-in arena, and the
  standalone voxel-card mode with StadiumBattleFX absent. The standalone run
  also kept Battle Cinematics 0.7.96 and the Gen 3 UI enabled.
- Literal dependency audit finds no missing `V.require` targets.
- Gen1Recomp's real manifest validator accepts both manifests and the test
  proves 1.6.4 matches both mixed-version blocks while 2.0.0 does not.
- Package build succeeds with 89 entries and rejects legacy battle/VR paths.
- `git diff --check` passes (line-ending conversion warnings only).

## Validation still requiring the game runtime

- Visually test one generic (non-authored) arena with Stadium models; the
  authored Pewter Gym arena and all three native-card ownership combinations
  are verified.
- Confirm an unsuitable/cold map uses Stadium's built-in fallback without
  hiding engine battle sprites.
- Exercise graphics invalidation and log export in SteamOS Game Mode.
- Use the actual Gen1Recomp manager to demonstrate both mixed-version blocks;
  the ranges follow the official manifest grammar but loader UI behavior is an
  integration test.

## Related StadiumBattleFX changes

StadiumBattleFX contains the transferred 1.6.4 model/build stack, standalone
renderer/host, independent component selectors, API documentation, structured
logging, SteamOS export, MIT/third-party notices, and the reciprocal conflict
with Dramaless below 2.0. Its full ledger is
`StadiumBattleFX/docs/DRAMALESS_2_0_PR_LEDGER.md`.
