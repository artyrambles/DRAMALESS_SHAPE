"""Import static Black/White back sprites for the first 151 Pokemon.

Source PNG bytes are copied unchanged. The runtime's STATIC mode reads these
ordinary files, while ANIMATED + GEN 5 continues to use the separate animated
atlas collection in `back-animated/gen5`.
"""

from __future__ import annotations

import argparse
from io import BytesIO
from pathlib import Path

from PIL import Image

from import_animated_sprites import download, species


SOURCE = "https://img.pokemondb.net/sprites/black-white/back-normal"


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
    parser.add_argument("--base-url", default=SOURCE)
    args = parser.parse_args()

    root = args.root.resolve()
    destination = root / "assets" / "battle" / "back-static" / "gen5"
    destination.mkdir(parents=True, exist_ok=True)
    roster = species(root)

    for number, (_, slug) in enumerate(roster, 1):
        filename = f"{slug}.png"
        raw = download(f"{args.base_url.rstrip('/')}/{filename}")
        width, height, mode, transparent = validate_png(raw, filename)
        (destination / filename).write_bytes(raw)
        print(
            f"[{number:03d}/151] {slug:<12s} "
            f"{width}x{height} {mode} alpha={transparent}",
            flush=True,
        )

    print(f"wrote 151 unmodified PNGs to {destination}")


if __name__ == "__main__":
    main()
