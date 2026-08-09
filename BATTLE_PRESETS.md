# Extending Dramaless battles

Dramaless exposes a public battle-preset API for companion mods. A preset is
an equal-standing choice on the **3D-BTL** row. It inherits one existing preset
and replaces only the named components it owns.

The four Dramaless choices always remain the defaults:

| id | existing stored value | stage | battlers |
| --- | --- | --- | --- |
| `dramaless:2d-a` | `true` | map | Game Boy cards |
| `dramaless:2d-b` | `"flatB"` | discs | Game Boy cards |
| `dramaless:stadium-a` | `"stadium"` | map | Stadium models |
| `dramaless:stadium-b` | `"stadiumB"` | discs | Stadium models |

Those stored values were not changed, so existing options files remain valid.
Custom presets store their namespaced `MOD_ID:local_id` instead of a numeric
position; adding or removing another mod cannot change what a saved value means.

## Registering a preset

Declare Dramaless as a dependency so it loads before your entry point:

```json
"dependencies": ["DRAMALESS_SHAPE@>=1.6.4 <2.0.0"]
```

Then register during normal mod initialization:

```lua
local mod = ...
local ds = assert(mod.find("DRAMALESS_SHAPE"), "Dramaless is required")
local battles = assert(ds.exports.battles, "Dramaless battle API is unavailable")

battles:register(mod.id, "cinematic", {
  label = "CINEMATIC",
  fallback = "dramaless:stadium-b",
  description = "My models on Dramaless's disc stage",
  components = {
    battlers = myBattlerProvider,
    camera = myCameraProvider,
  },
})
```

All custom presets have equal priority. They appear alphabetically by label,
then by their namespaced id, regardless of manifest priority or load order. The
player chooses the active preset. A `priority` field is rejected so a companion
mod cannot silently outrank another one.

## Components and fallback

Each component resolves independently through the declared `fallback` chain:

- An omitted component inherits from the fallback.
- A provider value replaces that component.
- `false` explicitly disables it and stops fallback for that component.
- `{ provider = value, available = function(ctx, preset) ... end }` replaces it
  only while the availability function returns true.

Component names are open strings. Dramaless currently consumes `stage` and
`battlers`; mods may also compose shared slots such as `camera`, `animations`,
`effects`, `lighting`, or `hud` through `battles:resolve(...)`. This keeps one
composition model as new backend seams are added.

```lua
local provider, sourcePreset = battles:resolve(
  "MY_MOD:cinematic", "camera", context)
```

Fallback cycles and provider errors are contained and logged rather than
hanging or taking down the battle renderer.

## Custom stages

A stage provider is a table with:

```lua
local stage = {
  id = "MY_MOD:arena",
  portable = true, -- true when no map-space search is needed
  replacesMap = true, -- omit Dramaless terrain/water/grass from the scene
  discs = false,   -- compatibility hint for existing integrations
}

function stage:arena(ctx, overworldState)
  -- Return an arena in Dramaless BattleArena shape.
  -- Return battles.FALLBACK when this map is unsupported.
  return arena
end

function stage:cast(ctx, shadowMap, arena, groundY)
  -- Optional shadow-pass geometry for a stage which replaces the map.
end

function stage:draw(ctx, arena, groundY)
  -- Optional visible geometry for a stage which replaces the map.
end
```

At runtime, return `battles.FALLBACK` to try the next stage in the preset's
fallback chain. Returning `nil` from `arena` also declines that stage.

## Custom battlers

A battler provider may implement this lifecycle:

```lua
function provider:available(ctx) return true end
function provider:begin(ctx, arena) return true end
function provider:update(ctx, dt, battle, groundY) end
function provider:covers(ctx, battle, side) return true end
function provider:standing(ctx) return true end
function provider:cast(ctx, shadowMap) end
function provider:draw(ctx, cameraPull) end
function provider:invalidate(ctx) end
function provider:finish(ctx) end
```

`ctx` contains `preset`, `value`, `state`, `battle`, `arena`, and `overworld`.
`covers` says whether the provider replaces that side's Game Boy billboard;
`standing` says whether any geometry remains visible when both billboards are
absent. Missing methods are optional no-ops.

Returning `false` or `battles.FALLBACK` from `begin` declines the provider.
Returning `battles.FALLBACK` from a later method retires it, initializes the
next battler provider in the fallback chain, and retries that operation.
Thrown errors follow the same safe fallback path.

## Public API

`ds.exports.battles` has API version `1` and provides:

- `register(owner, localId, definition)`
- `list()`
- `resolve(value, component, context)`
- `current()`
- `provider(method, ...)` for the active battler provider
- `FALLBACK`

Mods should use this export instead of requiring or patching files under
`DRAMALESS_SHAPE/lib`.
