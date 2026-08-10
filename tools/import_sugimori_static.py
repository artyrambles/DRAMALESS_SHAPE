"""Build normalized 96x96 static fronts from archived Red/Green artwork.

The high-resolution inputs and generated battle PNGs are local authoring
assets ignored by Git. This tool does not use or alter watermarked artwork.
"""

from __future__ import annotations

import argparse
import json
import re
import urllib.parse
import urllib.request
from pathlib import Path

from PIL import Image, ImageEnhance


API = "https://archives.bulbagarden.net/w/api.php"
CATEGORY = "Category:Art_from_Pokémon_Red_and_Green"
CANVAS = 96
ART_LIMIT = 88
BOTTOM = 94
ENTRY = re.compile(
    r'^  ([A-Z0-9_]+) = \{\n'
    r'    front = \{ image = "assets/battle/front-animated/gen5/([^/]+)\.png"',
    re.MULTILINE,
)

# Filled after reviewing labelled contact sheets. Symmetric/front-on poses do
# not need an entry; only art whose subject actually faces right is mirrored.
FLIP_DEX: set[int] = set()


def species(root: Path) -> list[tuple[str, str]]:
    source = (root / "data" / "animated_battle_sprites_gen5.lua").read_text(
        encoding="utf-8"
    )
    entries = ENTRY.findall(source)
    if len(entries) != 151:
        raise ValueError(f"expected 151 Kanto species definitions, got {len(entries)}")
    return entries


def get_json(url: str) -> dict:
    request = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def archive_manifest(cache: Path) -> dict[int, dict]:
    saved = cache / "manifest.json"
    if saved.exists():
        records = json.loads(saved.read_text(encoding="utf-8"))
        return {int(key): value for key, value in records.items()}
    query = urllib.parse.urlencode({
        "action": "query",
        "generator": "categorymembers",
        "gcmtitle": CATEGORY,
        "gcmtype": "file",
        "gcmlimit": "500",
        "prop": "imageinfo",
        "iiprop": "url|size",
        "format": "json",
    })
    data = get_json(f"{API}?{query}")
    records = {}
    pattern = re.compile(r"^File:(\d{3}).+ RG(?: 2)?\.png$")
    for page in data["query"]["pages"].values():
        match = pattern.match(page["title"])
        if not match:
            continue
        number = int(match.group(1))
        info = page["imageinfo"][0]
        records[number] = {
            "title": page["title"], "url": info["url"],
            "width": info["width"], "height": info["height"],
        }
    if set(records) != set(range(1, 152)):
        missing = sorted(set(range(1, 152)) - set(records))
        raise ValueError(f"archive set is incomplete; missing {missing}")
    cache.mkdir(parents=True, exist_ok=True)
    saved.write_text(json.dumps(records, indent=2), encoding="utf-8")
    return records


def download(url: str, destination: Path) -> None:
    if destination.exists():
        return
    request = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(request, timeout=30) as response:
        content = response.read()
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(content)


def normalize(source: Path, destination: Path, flip: bool) -> None:
    with Image.open(source) as opened:
        image = opened.convert("RGBA")
    alpha = image.getchannel("A")
    box = alpha.getbbox()
    if not box:
        raise ValueError(f"{source} contains no visible artwork")
    image = image.crop(box)
    if flip:
        image = image.transpose(Image.Transpose.FLIP_LEFT_RIGHT)

    # One restrained recipe across the entire set. It restores a little of
    # the line/color separation lost at 96px without changing palettes.
    r, g, b, a = image.split()
    rgb = Image.merge("RGB", (r, g, b))
    rgb = ImageEnhance.Contrast(rgb).enhance(1.08)
    rgb = ImageEnhance.Color(rgb).enhance(1.04)
    rgb = ImageEnhance.Sharpness(rgb).enhance(1.05)
    image = rgb.convert("RGBA")
    image.putalpha(a)

    width, height = image.size
    scale = min(ART_LIMIT / width, ART_LIMIT / height)
    size = (max(1, round(width * scale)), max(1, round(height * scale)))
    image = image.resize(size, Image.Resampling.LANCZOS)
    canvas = Image.new("RGBA", (CANVAS, CANVAS))
    x = (CANVAS - size[0]) // 2
    y = BOTTOM - size[1]
    canvas.alpha_composite(image, (x, y))
    destination.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(destination, optimize=True)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--cache", type=Path)
    args = parser.parse_args()
    root = args.root.resolve()
    cache = (args.cache or root.parent.parent / ".codex-temp" / "sugimori-rg")
    cache = cache.resolve()
    manifest = archive_manifest(cache)
    for number, (_, slug) in enumerate(species(root), 1):
        record = manifest[number]
        source = cache / f"{number:03d}-{slug}.png"
        print(f"[{number:03d}/151] {slug}", flush=True)
        download(record["url"], source)
        normalize(source, root / "assets" / "battle" / "front-static"
                  / f"{slug}.png", number in FLIP_DEX)


if __name__ == "__main__":
    main()
