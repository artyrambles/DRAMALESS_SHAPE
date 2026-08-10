"""Import the first 151 ordinary Pokemon Platinum back sprites.

The Platinum category mixes `Spr b 4p` files with unchanged `Spr b 4d`
sprites and provides male/female pairs for dimorphic species. Gen 1 has no
Pokemon gender, so this importer chooses the male member of a pair, matching
the Gen 4 animated-front importer, and otherwise uses the sole ordinary file.
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
CATEGORY = "Category:Platinum back sprites"
ORDINARY = re.compile(r"^File:(Spr b (4[dp]) (\d{3})(?: ([fm]))?\.png)$")


def category_files(api: str) -> dict[int, tuple[str, str, str | None]]:
    candidates: dict[int, list[tuple[str, str, str | None]]] = {}
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
            if 1 <= number <= 151:
                candidates.setdefault(number, []).append(
                    (match.group(1), match.group(2), match.group(4))
                )
        continuation = payload.get("continue", {}).get("cmcontinue")
        if not continuation:
            break

    selected = {}
    for number in range(1, 152):
        choices = candidates.get(number, [])
        bare = [choice for choice in choices if choice[2] is None]
        male = [choice for choice in choices if choice[2] == "m"]
        preferred = bare if bare else male
        if len(preferred) != 1:
            raise ValueError(
                f"expected one bare or male Platinum back for #{number:03d}, "
                f"got {choices}"
            )
        selected[number] = preferred[0]
    return selected


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
    prefixes = Counter(prefix for _, prefix, _ in source_files.values())
    sexes = Counter(sex or "bare" for _, _, sex in source_files.values())
    destination = root / "assets" / "battle" / "back-static" / "gen4"
    destination.mkdir(parents=True, exist_ok=True)

    for number, (_, slug) in enumerate(roster, 1):
        filename, prefix, sex = source_files[number]
        url = f"{args.file_base_url.rstrip('/')}/{urllib.parse.quote(filename)}"
        raw = download(url)
        width, height, mode, transparent = validate_png(raw, filename)
        (destination / f"{slug}.png").write_bytes(raw)
        print(
            f"[{number:03d}/151] {slug:<12s} {prefix} {sex or '-'} "
            f"{width}x{height} {mode} alpha={transparent}",
            flush=True,
        )

    prefix_summary = ", ".join(
        f"{key}={prefixes[key]}" for key in sorted(prefixes)
    )
    sex_summary = ", ".join(f"{key}={sexes[key]}" for key in sorted(sexes))
    print(
        f"wrote 151 unmodified PNGs to {destination} "
        f"({prefix_summary}; {sex_summary})"
    )


if __name__ == "__main__":
    main()
