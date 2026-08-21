# DRAMALESS_SHAPE Voxel Companion API v1

## Certification scope

This adapter is based on:

- Repository: `artyrambles/DRAMALESS_SHAPE`
- Base commit: `f14795b17e85d5d5baedcad63944065e446a4b0b`
- Integration branch: `kfp-companion-api-v1`
- Manifest and runtime version: `2.0.3` (not changed)
- API dispatcher SHA-256:
  `7ACB41E52757898038454D2EA673AAE5AC1ED66768DBA38E4FD8104702FD569B`

The adapter exports `mod.exports.voxel_companion`. It does not register a new
render pipeline. The existing `voxel` pipeline still owns `drawWorld`, terrain,
actors, the camera base, and the final scene canvas.

## Advertised capabilities

| Capability | Version | Behavior |
| --- | ---: | --- |
| `world_snapshot` | 1 | Bounded plain-data map, cell, actor, and neighbor snapshots. |
| `camera_delta` | 1 | Strictly additive position, rotation, and FOV deltas. |
| `render_phases` | 1 | Three certified world-render seams. |
| `quality_tier` | 1 | `HIGH`, `BALANCED`, or `LOW` host policy. |
| `integrity_status` | 1 | Host identity, clean state, limits, and phase support. |

The host does not advertise `terrain_patch`, `shadow_pass`, or `battle_pass`.
It also does not advertise the optional `materials` or `draw` facade names as
wire capabilities. The facades are still present in attach and render contexts.

Registration fails when a descriptor requests `shadow_casters`,
`battle_opaque`, or terrain patches. This prevents an extension from starting
with a callback that the host cannot call.

## Canonical callbacks

The host uses the frozen flat v1 descriptor:

```lua
{
  api = 1,
  id = "example.extension",
  requires = {
    "world_snapshot", "camera_delta", "render_phases", "quality_tier",
  },
  optional = {
    "terrain_patch", "shadow_pass", "battle_pass", "integrity_status",
  },
  attach = function(services) end,
  worldChanged = function(snapshot) end,
  update = function(frame) end,
  render = {
    background = function(context) end,
    opaque_after_terrain = function(context) end,
    translucent_after_actors = function(context) end,
  },
  modifyCamera = function(camera) return nil end,
  invalidate = function(reason) end,
  dispose = function() end,
}
```

The host calls the dispatcher through `world_changed(snapshot)`,
`update(frame)`, `render(phase, context)`, and `modifyCamera(camera)`.
Registration after host start joins the running lifecycle immediately.

## Render order

The adapter calls only these seams:

```text
host computes its base camera
  -> additive camera callbacks
host shadow-map pass
host begins the official world scene
  -> background
host terrain and water
  -> opaque_after_terrain
host actors, grass, and flowers
  -> translucent_after_actors
host ends the official world scene
  -> restore the exact host camera references and values
```

The shadow-map pass has no safe extension insertion point at the pinned host
commit. Native voxel battle rendering also uses a different path. Therefore,
`shadow_casters` and `battle_opaque` are not certified.

## Attach and render facades

Attach services expose these normalized facades:

- `world`: `snapshot()` and `revision()`.
- `materials`: `resolve(id, context)` and `atlas()` during render work.
- `draw`: `mesh(command, context)`, `instances(command, context)`, and
  `billboards(command, context)`.
- `quality`: `current()`, `tier()`, and `getTier()`.
- `integrity`: `host()`, `status()`, `supportsPhase(name)`, `limits()`, and
  `features()`.

A render context contains borrowed `world`, `camera`, `frame`, `materials`,
and `draw` values. It also contains adapter fields `quality`, `integrity`, and
`phase`. The top-level lease expires after its callback. An extension must not
store it, change borrowed values, release host resources, or use a context from
another callback.

The dispatcher detects ordinary top-level changes, `rawset` changes, expired
leases, reentrant dispatch, invalid return values, and extension faults. A
fault disables only its extension. Later extensions still run in priority and
identifier order.

## World snapshot

The snapshot uses world-pixel units and a cell size of 16. It contains:

- map identity, game, revision, mode, dimensions, and revision keys;
- cells with coordinates, base ground (`y` and `worldY`), height, material,
  walkability, solidity, tags, and plain metadata;
- player and actor poses;
- up to eight connected-map summaries;
- inferred indoor, outdoor, cave, forest, town, city, route, water, grass, and
  shore tags where the host data supports them.

Hard bounds are 262,144 cells, 2,048 actors, and 8 neighbors. Static cells are
cached by map object and world revision. Each snapshot view refreshes actor,
player, neighbor, mode, and time data without rescanning the cells. Map reload,
block replacement, object toggle, and active-map identity changes invalidate
the static cache.

Atlas material identifiers use `atlas:<tileset>:<tile>`. The renderer borrows
the current terrain atlas and calculates the tile UV rectangle. It does not
own or release the atlas.

## Camera contract

Camera results can contain only finite numeric deltas:

```lua
{
  positionDelta = { x = 0, y = 0, z = 0 },
  rotationDelta = { yaw = 0, pitch = 0, roll = 0 },
  fovDelta = 0,
}
```

Yaw, pitch, roll, and FOV use radians. Results merge in deterministic extension
order. Position adds to both eye and focus. Rotation changes the resulting
view axes. FOV adds to the host base and is clamped to 15 through 120 degrees.
The adapter restores the original camera object fields after each world frame.
It does not transfer camera ownership.

## Supported draw commands

The adapter accepts immutable KFP command packets. It does not change them.

| Draw method | Supported packet data |
| --- | --- |
| `mesh` | Extension-owned `mesh` or `resource`; declarative `box`, `plane`, `world_apron`, `panorama`, `cloud_layer`, and `rainbow`. |
| `instances` | Dense `items` plus `box`, `plane`, `door_frame`, `window`, `poster`, `rail`, `fixture`, `sconce`, `grass_clump`, `canopy`, `vine`, `cave_roof`, `mountain`, `hood`, or `umbrella`. |
| `billboards` | Dense items or deterministic procedural stars, batched as camera-independent crossed quads. |

`raised_structure` needs `terrain_patch` and is rejected. `shadow_caster` is
also rejected. The adapter does not expose `lights` or `postprocess` methods.
KFP must omit features that need an unavailable capability or draw method.

## Performance and ownership

- Declarative items are batched into one mesh and one draw call per command.
- A command-identity cache reuses derived meshes across frames.
- The default cache is 128 entries. The hard maximum is 512.
- The default item limit is 2,048 per command. The hard maximum is 8,192.
- The default vertex limit is 196,608 per command. The hard maximum is
  786,432.
- The full host frame allows at most 4,096 extension draw commands.
- Least-recently-used eviction releases one host-owned mesh before replacement.
- Invalidation and disposal release every derived mesh exactly once.
- Extension-owned meshes and host-owned atlases are never released by the
  adapter.
- No GPU resource is allocated until a draw command first needs it.

The translucent seam disables depth writes only for that seam, then restores
the host depth and color state.

## Legacy marker refusal

Before it exports the provider, the adapter reads `lib/VoxelScene.lua` and
looks for the historical `Ceiling.draw` splice marker. If the read fails or the
marker exists, the adapter refuses the provider. DRAMALESS_SHAPE continues
without KFP.

This check is read-only. It does not delete, move, rewrite, or migrate a legacy
file. The user must reinstall a clean host before use.

## Verification

Run from the repository root:

```powershell
luajit tools/run_tests.lua
luajit -e "assert(loadfile('main.lua')); assert(loadfile('lib/VoxelScene.lua')); assert(loadfile('lib/VoxelCompanionApi.lua')); assert(loadfile('lib/VoxelCompanionHost.lua')); assert(loadfile('lib/VoxelCompanionRenderer.lua'))"
git diff --check
```

The suite contains the frozen dispatcher conformance tests, canonical host
callback tests, phase and camera tests, legacy fixtures, error-isolation tests,
resource ownership tests, renderer bounds, and static pipeline-ownership tests.

Source and headless tests cannot prove real GPU driver behavior. Before a
release, run an in-game smoke test on a clean install and at least one desktop
and one mobile-class renderer. Check first-person camera restore, map changes,
atlas colors, all three phase seams, resize invalidation, and mod shutdown.
