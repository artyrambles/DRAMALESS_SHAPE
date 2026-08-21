# KFP Companion Integration Report

## Result

DRAMALESS_SHAPE now has a local, uncommitted Voxel Companion API v1 host
integration on branch `kfp-companion-api-v1`.

- Origin: `https://github.com/artyrambles/DRAMALESS_SHAPE.git`
- Pinned base: `f14795b17e85d5d5baedcad63944065e446a4b0b`
- Host version: `2.0.3`
- Manifest change: none
- External push or pull request: none
- Frozen dispatcher hash:
  `7ACB41E52757898038454D2EA673AAE5AC1ED66768DBA38E4FD8104702FD569B`

The official `voxel` pipeline still owns `drawWorld`. The integration adds
callbacks inside that pass and exports `mod.exports.voxel_companion` only after
the read-only legacy check succeeds.

## Changed files

| File | Change |
| --- | --- |
| `main.lua` | Creates the host, exports the provider, sends update and invalidation events, and isolates bridge calls. |
| `lib/VoxelScene.lua` | Adds the three certified render seams and exact camera-frame cleanup. |
| `lib/VoxelCompanionApi.lua` | Vendors the frozen pure-Lua v1 dispatcher. |
| `lib/VoxelCompanionHost.lua` | Implements capability negotiation, snapshots, facades, lifecycle, canonical dispatch, camera deltas, limits, and legacy refusal. |
| `lib/VoxelCompanionRenderer.lua` | Implements bounded mesh, instance, and billboard command rendering and ownership. |
| `docs/voxel-companion-api-v1.md` | Defines the public host contract, limits, and certification scope. |
| `README.md` | Adds user-facing integration and legacy-refusal notes. |
| `CHANGELOG.md` | Adds an unreleased integration record without a version bump. |
| `tools/package_mod.ps1` | Includes the public API document in release ZIP files. |
| `tools/run_tests.lua` | Adds the shared zero-dependency test runner. |
| `tools/test_bootstrap.lua` | Adds shared LuaJIT test assertions and discovery support. |
| `tests/companion/test_api_v1.lua` | Vendors the frozen dispatcher conformance suite. |
| `tests/companion/test_host_adapter.lua` | Tests canonical callbacks, facades, snapshots, camera restore, bounds, and faults. |
| `tests/companion/test_host_renderer.lua` | Tests batching, cache ownership, limits, materials, and depth-state restore. |
| `tests/companion/test_host_wiring.lua` | Proves pipeline ownership, seam order, version pin, legacy policy, and package scope. |
| `tests/fixtures/*.lua` | Provides clean and legacy-marker source fixtures. |

`manifest.json` is unchanged.

## Verified behavior

- Exactly one existing `voxel` pipeline owns the world draw.
- Only `background`, `opaque_after_terrain`, and
  `translucent_after_actors` are dispatched.
- Shadow, battle, and terrain-patch descriptors fail registration.
- The canonical flat callbacks receive snapshot, frame, render context, and
  camera inputs of the required shapes.
- Same-map block, object, and reload invalidations publish a new world snapshot
  revision before the next update callback.
- Camera and FOV deltas are additive and use radians.
- The exact host camera references and values return after every frame.
- A failed extension does not stop a later extension.
- An internal camera bridge fault rolls back the partial frame.
- Expired and foreign draw contexts fail.
- World data and renderer work have hard limits.
- Derived meshes release exactly once. Borrowed and extension-owned resources
  are not released.
- The legacy marker check reads only. It does not clean or migrate a file.
- The release package contains the API, adapter, renderer, and public contract.
  It does not contain tests.

## Test evidence

From the repository root:

```text
luajit tools/run_tests.lua
45 passed, 0 failed, 45 selected (4 files)

luajit -e "assert(loadfile(...))"
syntax ok

git diff --check
exit 0
```

The final isolated package check found 96 entries. It contained all three
companion modules, both public integration documents, and no `tests/` content.

## Remaining release risks

1. No real Gen1Recomp GPU frame was run in this isolated lane. Run a clean
   in-game smoke test before publication.
2. This pinned host has no safe shadow-caster or voxel-battle insertion seam.
   Those capabilities stay absent by design.
3. This host cannot apply terrain suppression or lift patches. KFP must omit
   only features that need `terrain_patch`.
4. This host has no safe lights or postprocess facade. KFP must omit those
   commands for this provider.
5. A dirty snapshot can scan up to 262,144 cells. Static cells are reused while
   dynamic actor views refresh, but very large maps still need a measured
   invalidation test.
6. The known legacy refusal checks the exact historical `Ceiling.draw` marker.
   A different unknown splice marker cannot be detected without a new audited
   signature.
7. The current official event set has no certified host-unload callback. The
   adapter releases resources on handle disposal and host invalidation; a full
   runtime unload test remains required if Gen1Recomp adds that lifecycle.

## Release gate

Do not publish from this branch until all of these checks pass:

- Run KFP and DRAMALESS_SHAPE together from clean installs.
- Check one outdoor map, one interior, one cave, and one connected-map seam.
- Check first-person movement, FOV options, resize, palette reload, block
  replacement, and object toggles.
- Check all three extension render phases with GPU validation enabled.
- Check desktop and mobile-class performance and derived-mesh release.
- Confirm the final manifest still reads `2.0.3`, or authorize a version bump
  as a separate release action.
