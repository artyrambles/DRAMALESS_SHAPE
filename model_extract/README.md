# Pokemon Stadium (US) — battle model export

> **Built on [pret/pokestadium](https://github.com/pret/pokestadium).** This
> pipeline is original code, but it could not have been written without that
> project's decompilation: the bone matrix chain and the fact that scale is
> kept out of it (`func_800143C0`), the rotation basis (`func_8000F730`), the
> animation and texture-animation samplers (`func_80016FBC`, `func_80017540`),
> the battle context slots, and the move-id constants all came from reading
> it. **No code or data from that project is vendored here or required to run
> this** — see the mod's [README](../README.md#acknowledgements--pretpokestadium),
> and get anything you want to reuse from upstream under its own terms.
>
> No ROM data is committed either: everything below is generated from a
> cartridge you supply.

All 151 battle Pokemon plus 64 other models from the same segment, in standard
formats. Regenerate straight from the ROM — stdlib only, no `make init`, no
splat, no crunch64:

```bash
model_extract/pipeline/build.py
```

Put a US 1.0 ROM in [baseroms/](baseroms/) (`.z64`, `.n64` or `.v64`), or pass
`--rom=PATH`. See [pipeline/README.md](pipeline/README.md) for the module layout,
how the ROM is unpacked, and the generated-effects notes.

```
viewer.html            browse everything in the browser — open it directly
manifest.json          every model + what each of its animations is used for
moves.json             all 165 moves + the animation each species plays for them
glb/025_pikachu.glb    glTF 2.0 binary: mesh, skeleton, skin, animations, textures
glb/x152_model.glb     non-Pokemon models from the same segment (props, trophies…)
textures/025_pikachu/  the same textures as loose PNGs, named <n>_<w>x<h>.png
js/                    viewer payloads, one per model, plus index.js and moves.js
```

`viewer.html` has a filterable picker for every model plus prev/next/random, a
**move picker** that jumps to whichever animation the current Pokemon plays for
that move, per-animation playback with a frame scrubber, an eye/texture-animation
selector, and texture/lighting/wireframe/skeleton toggles. It reads `js/`, not
`glb/`, because browsers block `fetch` of local files from `file://` — script
injection is what lets the page work when you just double-click it.

Sizes: 73 MB `glb/`, 54 MB `js/`, 7.4 MB `textures/`. Two flags if you want less:
`--no-js` skips the viewer payloads and `viewer.html` (leaving the glTF export
alone), and `--manifest-only` rebuilds just `manifest.json`.

`.glb` files are self-contained and open directly in Blender, Maya, Unity, Unreal,
three.js, Godot, Windows 3D Viewer, macOS Quick Look, and https://gltf-viewer.donmccurdy.com.
Source file `N.bin` holds species `N + 1`.

## Conventions

- Y up, +Z front, right-handed — glTF standard.
- Animations are authored at **30 fps**; keyframe times are `frame / 30`.
- Units are game units. Models are authored 10x and scaled down by the
  `model_root` node, matching the geo layout's scale command.
- Textures are `CLAMP_TO_EDGE`, materials are `alphaMode: MASK` with cutoff 0.5
  (N64 RGBA5551 has one bit of alpha). `doubleSided` follows the display list's
  cull mode.

## Skeleton

The game keeps bone scale *out* of the matrix chain (`func_800143C0` in
[src/12D80.c](../src/12D80.c)): scale accumulates in its own stack, a bone's local
translation is pre-multiplied by the parent's accumulated scale, and the
accumulated scale is applied to the rows of the finished world matrix only at
draw time. glTF node TRS instead propagates scale multiplicatively to children,
so a 1:1 node mapping would be wrong wherever a non-uniformly scaled bone has
descendants.

Each game bone is therefore exported as two nodes:

| node | role |
| --- | --- |
| `boneNN` | pivot: `translation = t * accScale(parent)`, `rotation = R`, scale 1 |
| `boneNN_scale` | leaf child holding `scale = accScale(bone)`, so it cannot propagate |

The skin binds to the `boneNN_scale` nodes, whose world matrices then equal the
game's draw matrices exactly. Vertices are already in bone-local space and each is
rigidly bound to one bone, so all inverse bind matrices are identity.

This was verified by parsing each exported `.glb` back and diffing every joint
matrix against a reference implementation of the game's own math, over the bind
pose and four sampled frames of every animation. Worst-case disagreement is
~1e-2 game units on models spanning 20–40 units, entirely from storing rotations
as spec-normalised `SHORT` quaternions.

## Animation semantics

Per-species battle data lives in `assets/us/70D3A0.bin`, 0xB90 bytes per species,
DMA'd into the battle system by `func_84302658` via the `D_80075BD0[species-1]`
pointer table. It is an array of 0x10-byte entries; byte 0 of each entry is an
index into that Pokemon's animation list and byte 1 indexes the auxiliary list:

- **entries 0–164** — one per move, in the move ID order of
  [oldnotes/stadium1/constants/move_constants.s](../oldnotes/stadium1/constants/move_constants.s).
  Entry *n* gives the animation played when the Pokemon uses move *n + 1*.
- **entries 165+** — fixed battle contexts (idle, hit, faint, …).

Every one of the 151 species' tables indexes only animations that exist in that
species' list, which is what confirms the layout.

`manifest.json` reports, for each animation, the exact list of moves that trigger
it plus which context slots reference it. `moves.json` inverts that: every move,
and the animation each of the 151 species plays for it.

One caveat when reading move data: the table is **dense**. Every species has a
row for every move, including moves it can never learn, and those unreachable
rows overwhelmingly point at the species' generic reaction animation — the same
one the `hit` slot uses. So "118 species play Thunderbolt" is an artifact, not a
fact about the game. `moves.json` marks each row with `differsFromDefault` and
gives a `speciesWithOwnAnimation` count per move; treat those as the signal. The `animationSlots` section carries an
`evidence` field per slot:

- `code` — the battle code in `src/fragments/62` names the slot outright.
- `data` — inferred from what the referenced animation actually does, measured
  across all 151 species. For example slot 167 is labelled `faint` because its
  animation always ends far from the standing pose (the model drops to
  0.03–0.84x idle height, or leaves the frame entirely for fliers), while slot
  168's animation always ends at exactly idle height.

`endBehavior` reports what the animation player does past the last frame
(`func_80016FBC`): every animation in the game wraps back to `loopStartFrame`, so
one-shots like `faint` are ended by the battle state machine switching animation,
not by the player clamping. glTF has no loop flag, so importers will loop clips by
default.

The common layout, consistent across nearly every species:

| animation | role |
| --- | --- |
| 0 | idle / standby loop (all 151 species) |
| 1 | second idle-length animation, rarely referenced by the context slots |
| 2 | hit / damage reaction (149–151 species across slots 166, 178–181) |
| 3 … n-3 | attack animations, selected per move |
| n-2 | faint (slots 167, 177) |
| n-1 | entrance / return-to-idle cycle (slots 168, 183) |

## Texture animations (blinking, dizzy eyes)

The second animation list in the model root is a *texture* animation, not a
skeletal one (`src/18140.c`). Geo command `0x23` carries a channel index at
offset `0x02`; when it is `>= 0`, `func_800176DC` replaces that material's
texture every frame from a per-frame stream of texture-table indices.

Charmander's eyes are the clearest example — texture 2 is the open eye, 3 and 4
are blink frames, and 5–7 are the dizzy swirl:

| aux animation | frames | texture stream |
| --- | --- | --- |
| 0 | 10 | `2 2 3 3 4 4 4 3 3 2` — a blink |
| 2 | 122 | cycles `5 6 7` — confusion swirl |
| 4 | 18 | a slower blink |

The viewer plays these. Each skeletal animation is paired with the texture
animation the battle table most often sets alongside it, and the `eyes` dropdown
overrides that. glTF 2.0 has no texture-swap animation channel, so this data
lives in `js/` and `moves.json` rather than the `.glb` — the `.glb` files carry
the first frame's texture on each material.

## Known gaps

- **Move effect visuals are not here.** Geo command `0x24` does not draw
  anything: `func_80014CB8` just records an attachment point (an id plus a world
  position) on the Pokemon, and the battle system spawns particles there. Ids
  1–14 are generic and used by nearly every species. So Charmander's tail flame,
  beams, explosions and the like are drawn by the effect system in the battle
  fragments and are not present in these model files — Charmander's texture set
  contains eyes, claws, teeth and skin, and no flame.
- **The Poke Ball throw/open model was not found.** It is not in this segment,
  no other `assets/us/**.bin` contains a model fragment, and scanning the ROM
  ranges of fragments 62–64 for embedded model headers found none. What does
  exist is Poke Ball *2D* artwork in fragment 29
  (`fragments/29/fragment29_unk_bin_*`, flagged in the splat yaml). The throw is
  most likely built from raw display lists rather than a geo-layout model.
- Files 151–214 are exported as `x<file>_model` with generic names. They are
  props, trophies, minigame pieces and similar; only Surfing Pikachu (file 152,
  the same 37-bone / 723-triangle rig as Pikachu) is named with confidence. They
  carry no battle table, so their animations are left unnamed.
