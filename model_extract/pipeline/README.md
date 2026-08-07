# Export pipeline

End-to-end: `baserom.z64` in, everything in `model_extract/` out. **Stdlib only** —
no `make init`, no splat, no crunch64, no build directory.

```bash
model_extract/pipeline/build.py                    # finds the ROM automatically
model_extract/pipeline/build.py --rom=/path/to.z64 --out=/tmp/out
```

The ROM is looked for in `model_extract/baseroms/` first, so this folder stands
on its own; the repo's own `baseroms/us/` is the fallback. Search order:

1. `model_extract/baseroms/baserom.z64`
2. `model_extract/baseroms/us/baserom.z64`
3. `baseroms/us/baserom.z64` at the repo root — where `make init` expects it
4. any `*.z64` / `*.n64` / `*.v64` sitting in `model_extract/baseroms/`

`.z64`, `.n64` and `.v64` all work — the byte order is detected from the magic
and normalised on load. See [../baseroms/README.md](../baseroms/README.md).

| flag | effect |
| --- | --- |
| `--only=3,91` | restrict to those model file numbers (fast iteration) |
| `--no-glb` | skip the glTF binaries and PNG dumps |
| `--no-js` | skip the viewer payloads and `viewer.html` |
| `--no-effects` | skip the generated fire/gas stand-ins |

## Modules

| file | does |
| --- | --- |
| `rom.py` | byte-order fixup (.z64/.v64/.n64), md5 check, archive unpacking, Yay0 and PERS-SZP decompression |
| `fragment.py` | FRAGMENT module → geo layout walk, F3DEX2 execution, textures, skeleton, animations |
| `battle.py` | per-species battle tables, move names, animation-context slot meanings |
| `glb.py` | glTF 2.0 binary writer |
| `effects.py` | **generated** fire/gas stand-ins (see below) |
| `build.py` | driver: ties it together, writes manifests |

## Getting from ROM to models without the build system

Three steps, all in `rom.py`:

1. **Byte order.** `.z64` is native; `.v64` swaps byte pairs; `.n64` reverses
   words. Detected from the magic and normalised on load.
2. **Archive.** The segment at `0x920000` starts with
   `u32 tag, u32 0, u32 totalSize, u32 fileCount`, then one
   `{u32 offset, u32 size, u32 pad[2]}` record per file. Only the top three
   bytes of the first word are reliably zero — the model archive puts a nonzero
   value in the low byte, which is the quirk `tools/unpack_asset.py` works
   around too.
3. **Decompression.** Each entry is `PERS-SZP` (an 8-byte magic plus a header
   size, wrapping a Yay0 stream). The Yay0 decoder is ~30 lines: a bitstream
   where a 1 copies a literal byte and a 0 pulls a (distance, length) pair.

Verified by decompressing all 215 entries and diffing against what
`make init` produces: **215/215 byte-identical**.

The battle tables need one more hop — `D_80075BD0[species - 1]` lives in the main
code segment, so `Rom.vram_to_rom` converts `0x80075BD0` using the segment's
`start`/`vram` from the splat yaml.

## Generated effects

`effects.py` produces **original, procedurally generated** fire and gas. It is
not extracted game data, and everything it emits is tagged `generated: true` in
the manifest, the viewer payloads and the PNG filenames (`*_fx.png`).

This exists because the real effects are not in the model files at all. Geo
command `0x08` attaches a callback (`func_80014A60` calls `node->unk_10`), and
the model supplies only two empty display lists and zeroed scratch buffers for
it to fill. The callback lives in another fragment and has not been ported, so
there is no flame mesh or flame texture to extract — Charmander's texture set is
eyes, claws, teeth and skin.

The stand-ins are anchored to the exact bone the callback hangs off, so they sit
where the real effect would and follow the animation:

| callback | species | stand-in |
| --- | --- | --- |
| `0x810000D8` | Charmander, Charmeleon, Charizard, Magmar, Moltres | tail/crest flame |
| `0x81000108` | Ponyta, Rapidash, Moltres wings | small flame |
| `0x810000E0` | Gastly (only) | gas cloud |

Both are looping flipbooks built from tileable value noise, drawn on a pair of
crossed quads — glTF cannot billboard, so crossed quads are the portable way to
make them read from any angle. Sizes are expressed as a fraction of the model's
**height** and divided by the anchor bone's accumulated scale, so an effect comes
out the intended size wherever in the skeleton it hangs. Seeds derive from the
species number, so a given Pokemon always generates the same effect.

In the viewer they draw in a second pass with depth writes off — additive for
fire, alpha for gas — and there is a *generated effects* toggle to hide them.
