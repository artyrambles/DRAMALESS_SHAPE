# KFP Companion Integration Report

## Result

DRAMALESS_SHAPE has a Voxel Companion API v1 host integration on branch
`kfp-companion-api-v1`. The proposed integration is public for review in
[pull request 47](https://github.com/artyrambles/DRAMALESS_SHAPE/pull/47).

- Origin: `https://github.com/artyrambles/DRAMALESS_SHAPE.git`
- Pinned base: `f14795b17e85d5d5baedcad63944065e446a4b0b`
- Host version: `2.0.3`
- Manifest change: none
- Review branch: `BoLayerDev/DRAMALESS_SHAPE:kfp-companion-api-v1`
- Frozen dispatcher hash:
  `6FDED9C804298AB064DB61B908382BE7C9A74AD29D611444C33E1BCC53A33D26`

The official `voxel` pipeline still owns `drawWorld`. The integration adds
callbacks inside that pass and exports `mod.exports.voxel_companion` only after
the read-only legacy check succeeds.

## Changed files

| File | Change |
| --- | --- |
| `main.lua` | Creates the host, exports the provider, sends update and invalidation events, and isolates bridge calls. |
| `lib/VoxelScene.lua` | Adds the three certified render seams and exact camera-frame cleanup. |
| `lib/VoxelCompanionApi.lua` | Vendors the frozen pure-Lua v1 dispatcher. |
| `lib/VoxelCompanionHost.lua` | Implements capability negotiation, snapshots, facades, lifecycle, canonical dispatch, camera deltas, command validation, strict backend results, limits, and legacy refusal. |
| `lib/VoxelCompanionRenderer.lua` | Implements bounded mesh, instance, and billboard rendering, player-relative KFP ceiling, wall, and canopy cutaways, one-wrap panorama presentation, collision-safe keyed caching, byte-budget LRU, and ownership. |
| `docs/voxel-companion-api-v1.md` | Vendors the central normative v1 contract and portable draw schema. |
| `README.md` | Adds user-facing integration and legacy-refusal notes. |
| `CHANGELOG.md` | Adds an unreleased integration record without a version bump. |
| `tools/package_mod.ps1` | Includes the public API document in release ZIP files. |
| `tools/run_tests.lua` | Adds the shared zero-dependency test runner. |
| `tools/test_bootstrap.lua` | Adds shared LuaJIT test assertions and discovery support. |
| `tests/companion/test_api_v1.lua` | Vendors the current central dispatcher conformance suite. |
| `tests/companion/test_host_adapter.lua` | Tests canonical callbacks, dot-call facades, packet validation, opaque texture borrowing, exact backend results, snapshots, camera restore, bounds, and faults. |
| `tests/companion/test_host_renderer.lua` | Tests batching, collision refusal, weak ownership, byte-budget LRU, exactly-once release, limits, materials, and draw-state restore. |
| `tests/companion/test_host_wiring.lua` | Proves pipeline ownership, seam order, version pin, legacy policy, and package scope. |
| `tests/fixtures/*.lua` | Provides clean and legacy-marker source fixtures plus the shared ROM-free baseline draw fixture. |

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
- Draw facade methods use the normative `draw.kind(command, context)` form.
- Every packet passes the central baseline validator before backend execution.
- Asset and path strings fail before they reach the backend.
- A backend draw succeeds only when it returns exact Boolean `true`.
- World data and renderer work have hard limits.
- Derived meshes release exactly once. Borrowed and extension-owned resources
  are not released.
- Callback commands and opaque texture handles are not retained after a draw.
  `Voxel3D.draw` temporarily binds a borrowed texture to a host-owned mesh;
  the renderer detaches it immediately on both success and fault paths before
  that mesh can remain in the cache. If detachment fails, the host evicts and
  releases the cached mesh. A direct extension-owned mesh or resource cannot
  be combined with a borrowed texture and is rejected before mutation.
- Declarative meshes use safe 64-byte cache keys, reject content or context
  collisions, and use a byte-bounded LRU. The default byte budget is 48 MiB
  and the hard maximum is 256 MiB.
- KFP ceiling cutaways open a four-cell square around
  `context.world.player`. Wall cutaways retain the far shell and melt the
  player's row southward, which matches the intended Sims cross-section and
  does not erase every wall in a small room. Player movement selects a bounded
  cache variant. A missing player or item cell keeps geometry visible.
- A cutaway canopy opens the same four-cell square only in first-person mode.
  Other camera modes keep the complete canopy.
- A textured panorama is unlit, does not use voxel seams, tests depth without
  writing it, and maps its texture once around a fixed 900-unit ring centred
  on the current public player pose. `sourceWidth` and `targetWidth` remain
  texture-quality metadata and never change the physical ring scale.
- A `cloud_layer` requires a borrowed binary-coverage texture. The renderer
  maps it over a high, curved, player-centred deck with depth writes, scene
  lighting, and voxel seams all disabled. An untextured packet fails before mesh
  allocation, and the renderer never retains or releases the borrowed image.
  High, Balanced, and Low densities keep the same continuous topology, so no
  300-by-300-unit grid hole can appear. Density changes only bounded deck
  height, curvature, and opaque RGB tint; material alpha stays 1. `seed`
  supplies a bounded deterministic whole-deck offset, and `parallax` supplies
  a clamped player-relative offset. Zero density is an allocation-free
  accepted no-op.
- The shared ROM-free baseline fixture executes all six mesh primitives, all
  15 instance primitives, explicit billboards, and deterministic procedural
  stars through both the adapter and real renderer. A second pass proves cache
  reuse.
- A disposed renderer rejects all draw kinds without allocation or cache state.
- The legacy marker check reads only. It does not clean or migrate a file.
- The release package contains the API, adapter, renderer, and public contract.
  It does not contain tests.

## Normalized scenery-tag contract

All scenery tags below are Boolean fields in a normalized snapshot cell's
existing `tags` table. They describe host-approved object identity. They do not
transfer terrain or render-resource ownership.

| Tag | Exact Dramaless meaning |
| --- | --- |
| `tree_support` | A real, solid, outdoor tree cell that can support KFP's legacy-style raised-tree treatment. The authored OVERWORLD tree drawing is tiles 64, 65, 80, and 81. An explicit `tree` shape class is also eligible. |
| `boulder_tree` | A real, solid, outdoor boulder from an authored boulder set. The OVERWORLD set is 42, 43, 58, and 59. The GYM profile also records its exact boulder set, but the outdoor gate prevents normal indoor Gym snapshots from exporting the density tag. |
| `mountain_support` | A member of a verified outdoor rock cluster. The cluster starts only from authored OVERWORLD rock seeds 2 or 36 and can include at most two cardinal cells of solid `wall`, `cliff`, or `rock` shape. |
| `mountain_seed` | An exact authored rock seed that survived the same collision, connection, and roof checks as `mountain_support`. |

Every density tag requires an explicit blocked collision result, `solid=true`,
`walkable=false`, a non-water cell, and an outdoor map. Missing or failed
collision data fails closed. A walkable path that reuses a tree tile receives
no tree or boulder density tag.

The mountain classifier also applies these bounded safety rules:

- A connected-map border band is not a mountain candidate.
- Any roof within two cells rejects a candidate, including an authored seed.
- Any door within two cells rejects a non-seed flood candidate.

The host exports verified eligibility, including an isolated valid seed. KFP
owns the common minimum-cluster, quality, and density policy across all hosts.

Broad `tree` and `mountain` tags are exported only with verified
`tree_support` and `mountain_support`. The truthful raw shape tags `cylinder`,
`canopy`, `stump`, `planter`, `cliff`, and `roof` remain descriptive only.
Generic cylinders never imply a tree or boulder. Canopies, stumps, and planters
never imply tree support. Roofs and generic cliffs never imply a mountain.

The exact tile meanings live in `data/voxel_heights.lua`, beside the host's
authored tile-shape profile. `TileShape` carries only approved facts into the
adapter. The adapter then applies collision and map checks and copies plain
Boolean tags into the snapshot. This keeps KFP independent from Dramaless tile
IDs and render classes.

## Test evidence

From the repository root:

```text
luajit tools/run_tests.lua
89 passed, 0 failed, 89 selected (4 files)

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
6. The 48 MiB default derived-mesh cache needs measured peak-memory and churn
   evidence on mobile-class hardware before publication.
7. The known legacy refusal checks the exact historical `Ceiling.draw` marker.
   A different unknown splice marker cannot be detected without a new audited
   signature.
8. The current official event set has no certified host-unload callback. The
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
