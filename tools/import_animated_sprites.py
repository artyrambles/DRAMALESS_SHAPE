"""Build one bring-your-own animated battle-art collection.

Generated PNG atlases live in ignored generation folders. Generated Lua
contains only the atlas geometry and frame timing needed by the runtime.

Default sources:
  gen2  https://bluemoonfalls.com/images/sprites/crystal/normal/
  gen3  https://pkmn.net/sprites/emerald/
  gen4  https://archives.bulbagarden.net/wiki/Category:Diamond_and_Pearl_sprites
  gen5  https://img.pokemondb.net/sprites/black-white/anim/
"""

from __future__ import annotations

import argparse
import math
import re
import time
import urllib.request
import urllib.error
import urllib.parse
from io import BytesIO
from pathlib import Path

from PIL import Image, ImageSequence


COLLECTIONS = {
    "gen2": {
        "base": "https://bluemoonfalls.com/images/sprites/crystal/normal",
        "title": "Pokemon Crystal animated fronts, National Dex #001-#151.",
        "numbered": True,
        "sides": (("front", None),),
    },
    "gen3": {
        "base": "https://pkmn.net/sprites/emerald",
        "title": "Pokemon Emerald animated fronts, National Dex #001-#151.",
        "numbered": True,
        "sides": (("front", None),),
    },
    "gen4": {
        "base": "https://archives.bulbagarden.net/wiki/Special:Redirect/file",
        "title": "Pokemon Diamond/Pearl animated fronts, National Dex #001-#151.",
        "numbered": "bulbagarden-gen4",
        "sides": (("front", None),),
    },
    "gen5": {
        "base": "https://img.pokemondb.net/sprites/black-white/anim",
        "title": "Pokemon Black/White animated fronts and backs, #001-#151.",
        "numbered": False,
        "sides": (("front", "normal"), ("back", "back-normal")),
    },
}
ENTRY = re.compile(
    r'^  ([A-Z0-9_]+) = \{\n'
    r'    front = \{ image = "assets/battle/front-animated/gen5/([^/]+)\.png"',
    re.MULTILINE,
)


def species(root: Path) -> list[tuple[str, str]]:
    source = (root / "data" / "animated_battle_sprites_gen5.lua").read_text(
        encoding="utf-8"
    )
    entries = ENTRY.findall(source)
    if len(entries) != 151:
        raise ValueError(f"expected 151 Kanto species definitions, got {len(entries)}")
    return entries


def download(url: str, retries: int = 4) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    for attempt in range(retries):
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return response.read()
        except Exception:
            if attempt + 1 == retries:
                raise
            time.sleep(1.5 * (attempt + 1))
    raise AssertionError("unreachable")


def download_gen4(base: str, number: int) -> bytes:
    """Fetch the ordinary Gen 4 front APNG, preferring the male variant.

    Diamond/Pearl stores sexually dimorphic species as `NNN m` and `NNN f`
    while species without a visual variant use bare `NNN`. The engine has one
    default front per species, so male is the predictable default; bare and
    female are fallbacks for archive records that provide no male title.
    """
    errors = []
    # Most species use the bare title. Archive redirects for a dimorphic
    # species may already resolve that to its default; otherwise prefer male,
    # then female, without making 151 guaranteed-failing male probes first.
    for suffix in ("", " m", " f"):
        filename = f"Spr 4d {number:03d}{suffix}.png"
        url = f"{base}/{urllib.parse.quote(filename)}"
        try:
            raw = download(url, retries=1)
            # A missing Special:Redirect title can return an HTML error page.
            if not raw.startswith(b"\x89PNG\r\n\x1a\n"):
                raise ValueError("response is not a PNG")
            return raw
        except (urllib.error.URLError, ValueError) as exc:
            errors.append(f"{filename}: {exc}")
    raise RuntimeError("; ".join(errors))


def convert(raw: bytes, destination: Path, columns: int = 16,
            max_dimension: int = 2048, *, coalesce: bool = False,
            minimum_duration: int = 0) -> dict:
    with Image.open(BytesIO(raw)) as gif:
        frames, durations = [], []
        for frame in ImageSequence.Iterator(gif):
            duration = max(1, round(float(
                frame.info.get("duration", gif.info.get("duration", 100))
            )))
            rgba = frame.convert("RGBA")
            # APNGs may carry arbitrary RGB values behind fully transparent
            # pixels. Normalize them before equality checks and atlas packing:
            # those hidden bytes have no visual meaning and LÖVE never sees
            # them after alpha compositing.
            normalized = Image.new("RGBA", rgba.size)
            normalized.alpha_composite(rgba)
            if coalesce and frames and normalized.tobytes() == frames[-1].tobytes():
                durations[-1] += duration
            else:
                frames.append(normalized)
                durations.append(duration)
    if minimum_duration > 0:
        durations = [max(minimum_duration, duration) for duration in durations]
    if not frames:
        raise ValueError("GIF contains no frames")
    width, height = frames[0].size
    if any(frame.size != (width, height) for frame in frames):
        raise ValueError("GIF frames do not share one logical canvas")
    max_columns = max_dimension // width
    if max_columns < 1:
        raise ValueError(f"frame width {width} exceeds {max_dimension}")
    columns = max(1, min(columns, max_columns, len(frames)))
    while math.ceil(len(frames) / columns) * height > max_dimension:
        columns += 1
        if columns > max_columns or columns > len(frames):
            raise ValueError("animation does not fit within one 2048px atlas")
    rows = math.ceil(len(frames) / columns)
    sheet = Image.new("RGBA", (columns * width, rows * height))
    for index, frame in enumerate(frames):
        sheet.alpha_composite(
            frame, ((index % columns) * width, (index // columns) * height)
        )
    destination.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(destination, optimize=True)
    return {
        "width": width, "height": height, "columns": columns,
        "frames": len(frames), "durations": durations,
    }


def lua_definition(path: str, info: dict, *, stable_anchor: bool = False) -> str:
    durations = ",".join(map(str, info["durations"]))
    anchor = ", stableAnchor = true" if stable_anchor else ""
    return (
        f'{{ image = "{path}", width = {info["width"]}, '
        f'height = {info["height"]}, columns = {info["columns"]}, '
        f'frames = {info["frames"]}, durations = {{{durations}}}{anchor} }}'
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--set", required=True, choices=COLLECTIONS)
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--base-url")
    args = parser.parse_args()
    root = args.root.resolve()
    config = COLLECTIONS[args.set]
    base = (args.base_url or config["base"]).rstrip("/")
    records = []
    for number, (engine_name, slug) in enumerate(species(root), 1):
        sides = {}
        for side, remote in config["sides"]:
            if config["numbered"] == "bulbagarden-gen4":
                raw = download_gen4(base, number)
            else:
                url = (f"{base}/{number}.gif" if config["numbered"]
                       else f"{base}/{remote}/{slug}.gif")
                raw = download(url)
            relative = f"assets/battle/{side}-animated/{args.set}/{slug}.png"
            print(f"[{number:03d}/151] {side:5s} {slug}", flush=True)
            sides[side] = (relative, convert(raw, root / relative))
        records.append((engine_name, sides))

    lines = [
        f"-- Generated by tools/import_animated_sprites.py --set {args.set}.",
        f"-- {config['title']}",
        "return {",
    ]
    for engine_name, sides in records:
        lines.append(f"  {engine_name} = {{")
        for side, _ in config["sides"]:
            path, info = sides[side]
            lines.append(f"    {side} = {lua_definition(path, info)},")
        lines.append("  },")
    lines.append("}")
    destination = root / "data" / f"animated_battle_sprites_{args.set}.lua"
    destination.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"wrote {destination} with {len(records)} species")


if __name__ == "__main__":
    main()
