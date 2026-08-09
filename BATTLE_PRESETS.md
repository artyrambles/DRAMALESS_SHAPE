# Composing Dramaless battles

Dramaless exposes a public battle-presentation API for companion mods. The
four built-in **3D-BTL** choices remain the baseline, while every battle asset
can be selected independently. A player can therefore use an arena from mod A,
Pokemon models from mod B, animations from mod C, an announcer from mod D and
a HUD from mod E. No mod has implicit priority; each provider is an equal
alphabetical option and the player's saved selection is authoritative.

| baseline id | existing stored value | arena | battlers |
| --- | --- | --- | --- |
| `dramaless:2d-a` | `true` | map | Game Boy cards |
| `dramaless:2d-b` | `"flatB"` | discs | Game Boy cards |
| `dramaless:stadium-a` | `"stadium"` | map | Stadium models |
| `dramaless:stadium-b` | `"stadiumB"` | discs | Stadium models |

Those legacy values are unchanged. Each new asset row stores either
`dramaless:default` or a namespaced `MOD_ID:local_id`, so installing or
removing a different mod cannot change what an existing save means.

## Register one selectable asset

Declare Dramaless as a dependency so it loads before your entry point:

```json
"dependencies": ["DRAMALESS_SHAPE@>=1.6.4 <2.0.0"]
```

Then register each component your mod supplies:

```lua
local mod = ...
local ds = assert(mod.find("DRAMALESS_SHAPE"), "Dramaless is required")
local battles = assert(ds.exports.battles, "Battle API is unavailable")

battles:registerComponent(mod.id, "battlers", "hd-models", {
  label = "HD MODELS",
  description = "My models for both battle sides",
  provider = myModelProvider,
})

battles:registerComponent(mod.id, "animations", "cinematic-moves", {
  label = "CINEMATIC MOVES",
  provider = myAnimationProvider,
  available = function(ctx, registration)
    return myAssetsWereImported()
  end,
})
```

The options menu adds a row for every slot with installed choices: **BTL
ARENA**, **BTL MODELS**, **BTL ANIM**, **BTL CAMERA**, **BTL EFFECTS**, **BTL
AUDIO**, **BTL VOICE**, **BTL HUD**, **BTL OVERLAY**, **BTL SCREEN**, **BTL
TRANS** and **BTL PRESENT**. `DEFAULT` inherits that component from 3D-BTL.

`priority` is rejected. Choices sort by label and then namespaced id, never by
manifest priority or load order. If a selected provider is unavailable or
returns `battles.FALLBACK`, only its own slot falls back to the 3D-BTL baseline.
No unselected mod is silently tried next.

## Component contracts

Every provider method receives a stable `ctx` first. It contains `preset`,
`value`, `state`, `battle`, `arena`, `overworld`, and temporarily `event` while
an event is being dispatched. Missing methods are optional no-ops.

All runtime providers may implement:

```lua
function provider:available(ctx) return true end
function provider:begin(ctx, arena) return true end
function provider:event(ctx, name, payload) end
function provider:update(ctx, dt, battle, groundY) end
function provider:cast(ctx, shadowMap, arena, groundY) end
function provider:drawWorld(ctx, cameraPull, arena, groundY) end
function provider:worldPresent(ctx, canvas, arena, groundY, viewport)
  return canvas -- or nil to keep the current canvas
end
function provider:beforeScreen(ctx, battleState, shot) end
function provider:afterScreen(ctx, battleState, shot, screenWasClaimed) end
function provider:invalidate(ctx) end
function provider:finish(ctx) end
```

Returning `false` or `battles.FALLBACK` from `begin` declines the provider.
Returning `battles.FALLBACK` from a later callback retires just that slot,
starts its baseline fallback, and retries the callback. A thrown error follows
the same contained path. `nil` is a normal result and does not request fallback.

### Arena provider (`stage`)

```lua
local arenaProvider = {
  id = "MY_MOD:arena",
  portable = true,      -- no map-space search is required
  replacesMap = true,   -- omit Dramaless terrain/water/grass
  discs = false,        -- compatibility hint
}

function arenaProvider:arena(ctx, overworldState)
  return arena -- Dramaless BattleArena shape, nil/FALLBACK to decline
end
function arenaProvider:cast(ctx, shadowMap, arena, groundY) end
function arenaProvider:draw(ctx, arena, groundY) end
function arenaProvider:update(ctx, dt, battle, groundY) end
function arenaProvider:invalidate(ctx) end
function arenaProvider:finish(ctx) end
```

### Pokemon model provider (`battlers`)

```lua
function models:begin(ctx, arena) return true end
function models:update(ctx, dt, battle, groundY) end
function models:covers(ctx, battle, side) return true end
function models:standing(ctx) return true end
function models:cast(ctx, shadowMap) end
function models:draw(ctx, cameraPull) end
function models:attachment(ctx, side, tag) return x, y, z end
function models:invalidate(ctx) end
function models:finish(ctx) end
```

`covers` decides whether a side's Game Boy billboard is replaced. A provider
can cover one side and inherit the other. Model files, textures and skeletons
remain owned and loaded by the companion mod; Dramaless supplies the lifecycle,
camera/shadow pass and safe fallback boundary.

### Camera, animation, announcer and complete screen

```lua
function camera:camera(ctx, inheritedCamera, inheritedPitch, groundY, viewport)
  return myCamera, myPitch, myWorldFrameHeight
end

function animations:event(ctx, name, payload)
  if name == "battle.move_used" then queueMove(payload) end
end
function animations:update(ctx, dt, battle, groundY) updateQueue(dt) end
function animations:cast(ctx, shadowMap, arena, groundY) castAnimatedMeshes() end
function animations:drawWorld(ctx, pull, arena, groundY) drawAnimatedMeshes() end
function animations:drawAnimation(ctx, battleState, colorized, shot)
  drawMyReplacementEffectLayer()
  return true -- suppress the stock Game Boy move-animation layer
end

function announcer:event(ctx, name, payload)
  if name == "battle.fainted" then playMyImportedVoiceLine(payload) end
end

function hud:drawHud(ctx, battleState, shot)
  drawMyNamesHpAndStatus()
  return true -- suppress only the stock HUD blocks, not menus or text
end

function screen:drawScreen(ctx, battleState, shot)
  drawMyCompleteBattleScreen(battleState, shot)
  return true -- suppress the engine battle screen for this frame
end
```

Semantic events include `battle.started`, `battle.turn_started`,
`battle.battler_switched`, `battle.turn_ended`, `battle.move_used`,
`battle.fainted`, `battle.exp_gained`, `battle.ball_thrown`,
`battle.damage_dealt`, `battle.status_inflicted`, and `battle.ended`.

This API controls presentation, not battle mechanics. Providers may import and
render their own models, animation data, textures, shaders, sound, music, voice,
HUD and complete screen composition, but move resolution, damage, capture,
turn order and networking remain engine-owned.

## Optional one-click bundles

`battles:register(owner, localId, definition)` still adds a named 3D-BTL preset
that supplies several baseline components together. Independent asset rows
override it one component at a time. Omitted bundle components inherit its
`fallback`; `false` explicitly disables a component.

```lua
battles:register(mod.id, "cinematic", {
  label = "MY CINEMATIC BASELINE",
  fallback = "dramaless:stadium-b",
  components = { stage = myArena, battlers = myModels },
})
```

## Public API

`ds.exports.battles` has API version `1` and provides:

- `register(owner, localId, definition)` for optional bundles
- `registerComponent(owner, slot, localId, definition)`
- `list()` and `componentList(slot)`
- `resolve(baselineValue, slot, context)`
- `current()`, `componentSelection(slot)` and `componentProvider(slot)`
- `runtimeSlots()` and `selectableSlots()`
- `provider(method, ...)` for the active battler provider
- `component(slot, method, ...)` for any active runtime provider
- `FALLBACK`

Companion mods should use this export instead of requiring or patching files
under `DRAMALESS_SHAPE/lib`.
