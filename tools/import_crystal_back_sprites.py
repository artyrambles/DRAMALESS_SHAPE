"""Import the first 151 ordinary Pokemon Crystal back sprites.

The Crystal category deliberately mixes `Spr b 2c`, `Spr b 2g`, and possibly
`Spr b 2s` filenames. The category is queried as the source of truth rather
than guessing a prefix per species. Shiny and Japanese variants do not match
the strict ordinary-filename pattern.
"""

from __future__ import annotations

import argparse
import json
import re
import urllib.parse
from collections import Counter
from io import BytesIO
from pathlib import Path

from PIL import Image

from import_animated_sprites import download, species


API = "https://archives.bulbagarden.net/w/api.php"
FILES = "https://archives.bulbagarden.net/wiki/Special:Redirect/file"
CATEGORY = "Category:Crystal back sprites"
ORDINARY = re.compile(r"^File:(Spr b (2[cgs]) (\d{3})\.png)$")


def category_files(api: str) -> dict[int, tuple[str, str]]:
    result: dict[int, tuple[str, str]] = {}
    continuation = None
    while True:
        query = {
            "action": "query",
            "list": "categorymembers",
            "cmtitle": CATEGORY,
            "cmtype": "file",
            "cmlimit": "500",
            "format": "json",
        }
        if continuation:
            query["cmcontinue"] = continuation
        url = f"{api}?{urllib.parse.urlencode(query)}"
        payload = json.loads(download(url).decode("utf-8"))
        for member in payload["query"]["categorymembers"]:
            match = ORDINARY.match(member["title"])
            if not match:
                continue
            number = int(match.group(3))
            if not 1 <= number <= 151:
                continue
            if number in result:
                raise ValueError(
                    f"multiple ordinary Crystal backs for #{number:03d}: "
                    f"{result[number][0]} and {match.group(1)}"
                )
            result[number] = (match.group(1), match.group(2))
        continuation = payload.get("continue", {}).get("cmcontinue")
        if not continuation:
            break
    missing = sorted(set(range(1, 152)) - set(result))
    if missing:
        raise ValueError(f"missing ordinary Crystal backs: {missing}")
    return result


def validate_png(raw: bytes, filename: str) -> tuple[int, int, str, bool]:
    if not raw.startswith(b"\x89PNG\r\n\x1a\n"):
        raise ValueError(f"{filename}: response is not a PNG")
    with Image.open(BytesIO(raw)) as image:
        if getattr(image, "n_frames", 1) != 1:
            raise ValueError(f"{filename}: expected one static frame")
        details = (
            image.width,
            image.height,
            image.mode,
            image.info.get("transparency") is not None or "A" in image.mode,
        )
        image.verify()
    return details


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--api-url", default=API)
    parser.add_argument("--file-base-url", default=FILES)
    args = parser.parse_args()

    root = args.root.resolve()
    roster = species(root)
    source_files = category_files(args.api_url)
    prefixes = Counter(prefix for _, prefix in source_files.values())
    destination = root / "assets" / "battle" / "back-static" / "gen2"
    destination.mkdir(parents=True, exist_ok=True)

    for number, (_, slug) in enumerate(roster, 1):
        filename, prefix = source_files[number]
        url = f"{args.file_base_url.rstrip('/')}/{urllib.parse.quote(filename)}"
        raw = download(url)
        width, height, mode, transparent = validate_png(raw, filename)
        (destination / f"{slug}.png").write_bytes(raw)
        print(
            f"[{number:03d}/151] {slug:<12s} {prefix} "
            f"{width}x{height} {mode} alpha={transparent}",
            flush=True,
        )

    summary = ", ".join(f"{key}={prefixes[key]}" for key in sorted(prefixes))
    print(f"wrote 151 unmodified PNGs to {destination} ({summary})")


if __name__ == "__main__":
    main()
