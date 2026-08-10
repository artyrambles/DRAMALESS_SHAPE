"""Import the 151 Pokemon Yellow Super Game Boy back sprites.

The downloaded PNGs are deliberately kept byte-for-byte as supplied by
Bulbagarden Archives. In particular, this tool does not resample the indexed
pixels or rewrite the source transparency.
"""

from __future__ import annotations

import argparse
import re
import time
import urllib.parse
import urllib.request
from io import BytesIO
from pathlib import Path

from PIL import Image


SOURCE = "https://archives.bulbagarden.net/wiki/Special:Redirect/file"
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
    request = urllib.request.Request(
        url,
        headers={"User-Agent": "DramaticShapeVoxelMod battle-art importer"},
    )
    for attempt in range(retries):
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return response.read()
        except Exception:
            if attempt + 1 == retries:
                raise
            time.sleep(1.5 * (attempt + 1))
    raise AssertionError("unreachable")


def validate_png(raw: bytes, number: int) -> tuple[int, int, str]:
    if not raw.startswith(b"\x89PNG\r\n\x1a\n"):
        raise ValueError(f"#{number:03d} response is not a PNG")
    with Image.open(BytesIO(raw)) as image:
        image.verify()
    with Image.open(BytesIO(raw)) as image:
        return image.width, image.height, image.mode


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--base-url", default=SOURCE)
    args = parser.parse_args()

    root = args.root.resolve()
    destination = root / "assets" / "battle" / "back-static" / "gen1"
    destination.mkdir(parents=True, exist_ok=True)
    seen = set()

    roster = species(root)
    for number, (_, slug) in enumerate(roster, 1):
        archive_name = f"Spr b 1y {number:03d} SGB.png"
        url = f"{args.base_url.rstrip('/')}/{urllib.parse.quote(archive_name)}"
        raw = download(url)
        width, height, mode = validate_png(raw, number)
        output = destination / f"{slug}.png"
        output.write_bytes(raw)
        seen.add(output.name)
        print(
            f"[{number:03d}/151] {slug:<12s} {width}x{height} {mode}",
            flush=True,
        )

    expected = {f"{slug}.png" for _, slug in roster}
    if seen != expected:
        raise RuntimeError("downloaded filename set does not match the Kanto roster")
    print(f"wrote {len(seen)} unmodified PNGs to {destination}")


if __name__ == "__main__":
    main()
