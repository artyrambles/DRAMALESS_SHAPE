# Voxel Companion API v1

Status: normative v1 contract and pure-Lua reference dispatcher.

Reference implementation: `lib/VoxelCompanionApi.lua`.

## Purpose

Voxel Companion API v1 lets a presentation mod add features to a voxel host
without file patching, private-module access, or ownership of the host render
pipeline.

The host keeps ownership of its pipeline, GPU state, camera, terrain, atlases,
and material handles. An extension can:

- Run at fixed render phases.
- Add numeric camera deltas.
- Return a declarative terrain patch.
- Submit its own draw packets through a borrowed host facade.
- Receive attach, world-change, update, invalidate, and dispose events.

The API does not permit an extension to replace terrain or stop the host from
drawing its base terrain.

## Host export

A host can expose the reference dispatcher or a conforming implementation:

```lua
host.exports.voxel_companion = {
  api = 1,
  host = { id = "DRAMATIC_SHAPE", version = "1.9.0" },
  capabilities = { world_snapshot = 1, camera_delta = 1, ... },
  register = function(spec) ... end,
}
```

The reference module has this constructor:

```lua
local Companion = load_companion_api_v1()
local dispatcher = Companion.new({
  host_id = "DRAMATIC_SHAPE",
  host_version = "1.9.0",
  capabilities = {
    "render_phases",
    "camera_delta",
    "terrain_patch",
    "world_snapshot",
    "quality_tier",
    "shadow_pass",
    "battle_pass",
    "integrity_status",
  },
  logger = function(event) ... end,
})

host.exports.voxel_companion = dispatcher:provider()
```

`logger` is optional. A logger fault never stops the host.

## Standard capabilities

| Capability | Meaning |
| --- | --- |
| `render_phases` | The host dispatches the phase table in this document. |
| `camera_delta` | The host accepts additive camera results. |
| `terrain_patch` | The host accepts declarative terrain results. |
| `world_snapshot` | Attach services include the `world` facade. |
| `quality_tier` | Attach services include the `quality` facade. |
| `shadow_pass` | The host dispatches `shadow_casters` in its shadow pass. |
| `battle_pass` | The host dispatches `battle_opaque` in its battle renderer. |
| `integrity_status` | Attach services include the read-only `integrity` facade. |

These eight names are the complete API v1 capability set. `materials` and
`draw` are service-facade names. They are not capabilities and must not appear
in a provider capability table or an extension `requires` or `optional` list.
A conforming `render_phases` adapter always supplies the normalized render
context when it invokes a render phase.

An extension lists required and optional capabilities. A missing required
capability rejects only that extension. A missing optional capability disables
only its related callback or feature.

A host can omit `terrain_patch`. KFP must then disable only features that need
cell suppression, transforms, or added terrain instances. Camera and baseline
phase-based draw features can continue when their own capabilities are present.
API v1 does not define cross-mod audio transport.

## Attach services

Before host activation, the host calls:

```lua
dispatcher:attach({
  world = worldFacade,
  materials = materialFacade,
  draw = drawFacade,
  quality = qualityFacade,
  integrity = integrityFacade,
})
```

All five keys are normalized service names. `world`, `quality`, and `integrity`
are required when a registered extension requires `world_snapshot`,
`quality_tier`, or `integrity_status`, respectively. `materials` and `draw` are
required when an extension registers a render handler. They are never
negotiated as capabilities.

The `draw` facade has three required functions:

```lua
draw.mesh(command, context)
draw.instances(command, context)
draw.billboards(command, context)
```

`context` must be the current borrowed render context received by the calling
handler. The reference dispatcher checks the functions but does not perform GPU
drawing. Before execution, a host calls
`Companion.validate_draw_command(command, kind)` or applies an equivalent
validator.

Resource ownership is strict:

- KFP owns every mesh, texture, buffer, and audio resource that KFP creates.
- KFP releases each owned resource exactly once.
- The host owns atlas, material, camera, world, and renderer handles.
- KFP borrows host handles. It must not mutate, release, cache beyond their
  stated lifetime, or transfer them to another owner.
- `command.material` is a semantic identifier that the host resolves. A packet
  does not contain a borrowed host atlas or material handle.
- `command.texture`, `mesh`, `resource`, and `model` are optional opaque,
  extension-owned handles. They are not file names, paths, URIs, material
  names, or borrowed host handles.
- The host can use an extension-owned opaque handle only during that draw call.
  It must not retain, cache, mutate, release, or call ownership methods on the
  handle.
- The feature packet and its explicit KFP resource scope retain ownership of an
  opaque handle. The scope, not the host adapter, releases the handle.
- The host can copy `command.cacheKey` and retain resources that the host
  creates. It must not retain the command table or any nested command value.

`attach` is idempotent for the same service table. Attaching a different table
to the same dispatcher is an error. Every service is borrowed only for the
callback. An extension copies plain data and does not retain a facade.

## Baseline draw packet schema

The API v1 portable baseline has only `mesh`, `instances`, and `billboards`.
`lights`, `postprocess`, `raised_structure`, `shadow_caster`, and `battle_prop`
are not baseline packet kinds or primitives. A host-specific extension can
define them outside this portable contract.

Every baseline command is a plain table with these required fields:

| Field | Required value |
| --- | --- |
| `schemaVersion` | Integer `1`. |
| `cacheKey` | Non-empty cache identifier described below; at most 64 bytes. |
| `kind` | `mesh`, `instances`, or `billboards`. |
| `owner` | Non-empty semantic identifier; at most 128 bytes. |
| `phase` | One render phase from the phase table below. |
| `sequence` | Positive integer. |
| `sortKey` | Non-empty semantic identifier; at most 512 bytes. |
| `material` | Non-empty semantic material identifier; at most 512 bytes. |

`color` is optional. It is a dense array of three or four finite values from 0
through 1. `texture` is an optional opaque handle with the callback-only
lifetime above. A command cannot contain an unknown field.

An API v1 cache key contains only ASCII letters, digits, dot, underscore,
colon, and hyphen. Its grammar is `[A-Za-z0-9._:-]+`. A host-wide validator
must accept every key in that safe envelope. It must not require a producer
namespace or infer ownership from the key.

### KFP cache-key producer profile

KFP commands use this exact producer-specific form:

```text
kfp1:<scene8>:<generation>:<phase>:<sequence>:<content16>
```

For example:

```text
kfp1:0123abcd:4:2:37:0123456789abcdef
```

The KFP fields have these rules:

- `scene8` is exactly eight lowercase hexadecimal characters. It is the stable
  digest of the scene metadata key.
- `generation` is a canonical unsigned decimal integer. It has no leading zero
  unless its value is zero.
- `phase` is the decimal phase identifier: `background=1`,
  `opaque_after_terrain=2`, `translucent_after_actors=3`, `shadow_casters=4`,
  and `battle_opaque=5`.
- `sequence` is the canonical positive decimal form of `command.sequence`.
- `content16` is exactly 16 lowercase hexadecimal characters from
  `PacketHash.hashCommand(command)`.

The KFP content hash covers declarative command data. It excludes
`cacheKey`, `schemaVersion`, `sequence`, and the callback-only `texture`,
`mesh`, `resource`, and `model` handles. The phase identifier and sequence in
the KFP key match the command fields. A KFP golden test enforces this producer
profile. The shared host validator enforces only the safe API v1 envelope so
other extensions can use their own keys. A cache key never grants ownership of
an opaque handle.

Asset and path strings are prohibited in every command field and nested value.
This includes file names, directory paths, URLs, URIs, and fields named for an
asset, path, file, URI, or URL. The extension loads its own asset before render
dispatch and passes only an allowed opaque handle for the current draw call.

### `mesh`

A mesh command adds `geometry` or one of the opaque `mesh` and `resource`
handles. It cannot combine declarative `geometry` with either direct handle,
and it cannot contain both direct handles. An optional opaque `model` handle is
an adjunct resource. Portable geometry has one of these exact shapes:

| Primitive | Fields after `primitive` |
| --- | --- |
| `box` | Required positive `width`, `height`, `depth`; optional finite `x`, `y`, `z`. |
| `plane` | Required positive `width`, `depth`; optional finite `x`, `y`, `z`. |
| `world_apron` | Required positive `width`, `depth`, `skirtDepth`; optional plain `neighbors`. |
| `panorama` | Required positive `sourceWidth`, `targetWidth`; optional Boolean `deepSkirt`, `distanceHaze`; requires `command.texture`. |
| `cloud_layer` | Required positive-integer `layer`, finite `parallax` and `seed`, and `density` from 0 through 1. |
| `rainbow` | Required finite `seed`. |

### `instances`

An instances command adds optional semantic `key`, one plain `prototype`, and a
non-empty dense `items` array of at most 8,192 entries. A prototype is one of:

- `box`: optional positive `width`, `height`, `depth`; optional Boolean
  `cutaway`; optional semantic `role`.
- `plane`: optional positive `width`, `depth`; optional semantic `role`; optional
  `alphaCutoff` from 0 through 1.
- `door_frame`: optional semantic `role` and Boolean `double`.
- `window`, `rail`, `fixture`, or `sconce`: optional semantic `role`.
- `poster`: optional semantic `role`; requires `command.texture`.
- `grass_clump`: optional positive `width` and semantic `wind`.
- `canopy`: optional positive `width` and Boolean `cutaway`.
- `vine`: optional Boolean `animated`.
- `cave_roof`: optional positive `width`, `depth`, and semantic `role`.
- `mountain` or `hood`: optional semantic `role` and Boolean `shadow`.
- `umbrella`: no additional field.

Each item requires finite `x`, `y`, and `z`. It can also contain integer
`cellX` and `cellZ`; finite `seed` and `lift`; semantic `side`, `facing`, and
`kind`; Boolean `summit`; and finite-number or semantic `poster`.

### `billboards`

A billboards command adds optional semantic `key`, optional Boolean `animated`,
and exactly one of:

- A non-empty dense `items` array of at most 8,192 entries. Each item requires
  finite `x`, `y`, and `z`. It can contain positive `width` and `height`, finite
  `seed`, and bounded plain declarative `extra` data.
- `procedural = { kind = "stars", count = n, seed = s, ... }`, where `count` is
  an integer from 1 through 8,192 and `seed` is finite. `twinkle`, `nebula`, and
  `shootingStars` are optional Booleans.

Plain declarative data is finite and acyclic. It has no metatable, function,
thread, userdata, cdata, or opaque resource. The validator limits it to 16
levels, 32,768 nodes, and 256 KiB of keys and values.

## Extension descriptor

```lua
local spec = {
  api = 1,
  id = "kfp.environment",
  name = "KFP Environment",
  version = "2.0.0",
  priority = 0,
  requires = {
    "world_snapshot", "camera_delta", "render_phases", "quality_tier",
  },
  optional = {
    "terrain_patch", "shadow_pass", "battle_pass", "integrity_status",
  },

  attach = function(services) ... end,
  worldChanged = function(snapshot) ... end,
  update = function(frame) ... end,
  modifyCamera = function(camera) return cameraDelta end,
  terrainPatch = function(buildContext) return terrainPatch end,
  render = {
    background = function(context) ... end,
    opaque_after_terrain = function(context) ... end,
    translucent_after_actors = function(context) ... end,
    shadow_casters = function(context) ... end,
    battle_opaque = function(context) ... end,
  },
  invalidate = function(reason) ... end,
  dispose = function() ... end,
}

local handle, err = dispatcher:register(spec)
```

`api` and `id` are required. The identifier is stable and contains only ASCII
letters, digits, dot, underscore, and hyphen. `modifyCamera` automatically
requires `camera_delta`. `terrainPatch` automatically requires
`terrain_patch`. A render callback automatically requires `render_phases`.
`shadow_casters` and `battle_opaque` also require `shadow_pass` and
`battle_pass`, respectively.

The reference module accepts the older nested `lifecycle`, `phases`, `camera`,
and `terrain` spellings for source migration. New adapters and extensions use
the flat descriptor above. A flat and nested spelling cannot define the same
callback in one descriptor.

The dispatcher copies descriptor metadata and function references. It does not
use descriptor fields after registration. Registering the same live descriptor
table twice returns the same handle. A different descriptor with the same live
identifier is an error.

The reference dispatcher accepts at most 64 live extension identifiers by
default. A host can lower or raise this bound with `max_extensions`, up to the
hard limit of 1,024.

Ordering is deterministic:

1. Lower numeric priority runs first.
2. Equal priority sorts by extension identifier.

Registration order does not change execution order.

## Lifecycle

The lifecycle sequence is:

```text
register
  -> attach
  -> host activation
  -> worldChanged
  -> zero or more update, render, camera, terrain, and invalidate calls
  -> dispose
```

The host attaches services before it activates dispatch. Registering after host
activation is allowed. The provider supplies its retained activation context
internally; a consumer still calls only `register(spec)`.

The reference dispatcher's host-side `start` and `dispose` methods are
idempotent. A handle `dispose` is also idempotent. Host disposal runs
extensions in reverse deterministic order.

Attach, world-change, update, render, invalidate, and dispose handlers return no
value. A returned value is a contract fault.

## Phase dispatch

The phase order within a world render is:

```text
background
[host base terrain]
opaque_after_terrain
[host actors]
translucent_after_actors
shadow_casters (when the host runs its shadow pass)
battle_opaque (instead of world phases during a battle)
```

The host also calls:

- `dispatcher:update(frame)` outside render work.
- `dispatcher:world_changed(snapshot)` after the active world identity changes
  and before rendering the new map.

Backdrop and sky features use `background`. Interior geometry uses
`opaque_after_terrain`, and blended flora and weather use
`translucent_after_actors`. A feature must use `draw.mesh`,
`draw.instances`, or `draw.billboards` for its own packets. It must not call a
private host draw function.

For each render phase, the context has:

```lua
{
  world = borrowedWorld,
  camera = borrowedCamera,
  frame = borrowedFrame,
  materials = borrowedMaterials,
  draw = borrowedDrawFacade,
}
```

The host can add documented adapter fields. It must not remove these normalized
fields when a render handler runs. `modifyCamera` receives only the normalized
borrowed camera view. `terrainPatch` receives a normalized borrowed build
context and never receives base-terrain ownership.

## Borrowed context rules

A callback context is valid only for that callback. An extension must not store
the context table.

The reference dispatcher provides a read-only top-level lease. It rejects an
ordinary assignment, detects top-level `rawset` use after the callback, and
rejects access through a stored lease after return.

Lua 5.1 cannot fully protect nested tables or stop deliberate raw operations.
The following rules therefore remain contractual:

- Do not use `pairs`, `rawget`, or `rawset` on the top-level lease.
- Do not change nested host facades or borrowed handles.
- Copy only plain numeric, Boolean, and string data needed after return.
- Do not store per-frame camera, frame, atlas, material, or draw handles.
- Do not retain a facade received during `attach` after that callback returns.

## Camera result

Camera handlers return nil or one table. All values are finite numeric deltas:

```lua
{
  positionDelta = { x = 0, y = 3.5, z = 0 },
  rotationDelta = { yaw = 0, pitch = -0.02, roll = 0 },
  fovDelta = 0.04,
}
```

Every field is optional. Missing values are zero. Absolute position, absolute
rotation, and absolute field-of-view values are not valid v1 results.
Position deltas use host world units. Rotation and field-of-view deltas use
radians.

The dispatcher adds successful results in deterministic extension order. Each
addition is transactional. If one contribution would make any aggregate field
non-finite, that extension faults, the prior aggregate stays unchanged, and
later contributions continue. The dispatcher returns:

```lua
local delta, report = dispatcher:modifyCamera(camera)
```

The host applies the final delta to its own base camera. An invalid result
faults only its extension. Valid deltas from other extensions remain.

## Terrain result

Terrain handlers return nil or this declarative patch:

```lua
{
  cacheKey = "map-state:42",
  suppressCells = {
    "map:cell:1",
    { key = "map:cell:2", x = 2, y = 4 },
  },
  transforms = {
    { key = "tree:2:4", dy = 8 },
  },
  instances = {
    { kind = "tree-trunk", x = 32, y = 0, z = 64 },
  },
  tags = {
    biome = "forest",
  },
  invalidate = false,
}
```

Rules:

- `cacheKey` is an optional non-empty string of at most 512 bytes.
- `suppressCells` is a dense array. An entry is a non-empty string or a plain
  data table with a non-empty `key`.
- `transforms` is a dense array of plain data tables. Each item has a non-empty
  `key` that identifies its exclusive transform target.
- `instances` is a dense array of plain declarative data tables.
- `tags` uses non-empty string keys and plain declarative values.
- `invalidate` is an optional Boolean.
- Patch data is finite, acyclic, has no metatables, and contains no functions,
  threads, or userdata.
- One contribution is limited to 8,192 items per array, 32,768 plain-data
  nodes, 16 levels, and 256 KiB of plain-data keys and values.
- One merged result is limited to 32,768 array items.

The dispatcher merges accepted patches in deterministic extension order:

- Arrays append in order.
- Later tag values replace earlier values with the same tag key.
- `invalidate` is a Boolean OR.
- Contributor cache keys become one deterministic length-prefixed cache key.
- If a meaningful or invalidating contribution has no cache key, the merged
  cache key is nil. The host must treat that patch as uncacheable.

A suppression key can have only one owner. A transform key can have only one
owner. A conflict faults the later extension and rejects its complete patch for
that dispatch. A suppression key and a transform key use separate namespaces.

The result cannot contain `terrain`, `atlas`, `drawDefault`, `replace`,
`consume`, or any other base-control field. The host always owns and draws its
base terrain.

```lua
local patch, report = dispatcher:terrainPatch(buildContext)
```

## Fault isolation

One callback error, context violation, invalid return count, or invalid result
faults one extension for the rest of the dispatcher session.

On a fault, the reference dispatcher:

1. Marks the extension inactive.
2. Stores one bounded structured diagnostic.
3. Calls that extension's `dispose` once.
4. Continues later extensions.
5. Leaves the voxel host active.

Diagnostics are bounded by `max_errors`, which defaults to 64. Public copies
are available through `dispatcher:errors()` and `dispatcher:status()`.

The dispatcher keeps its reentrancy guard active through fault cleanup. No
callback, including a fault-triggered `dispose`, can reenter dispatch,
registration, or dispatcher disposal. This prevents unstable order, recursive
host rendering, and one failed extension from disposing other extensions.

## Handle contract

`register` returns a handle with:

```lua
handle:id()
handle:is_active()
handle:status()
handle:invalidate(context, reason)
handle:dispose(context, reason)
```

`dispose` is idempotent. After explicit handle disposal, the host can register
a new descriptor with the same identifier. A faulted handle remains reserved
until it is explicitly disposed or the dispatcher ends.

## Reports

Dispatch methods return a report with stable counters:

```lua
{
  kind = "phase" | "result" | "lifecycle",
  name = "background" | "camera" | "terrain" | ...,
  called = 0,
  succeeded = 0,
  failed = 0,
  skipped = 0,
  contributors = { "extension.id", ... },
}
```

Reports contain plain data and transfer ownership to the caller.

## Conformance

A conforming implementation must pass `tests/companion/test_api_v1.lua` under
LuaJIT with Lua 5.1 semantics. The test command is:

```text
luajit tools/run_tests.lua companion
```
