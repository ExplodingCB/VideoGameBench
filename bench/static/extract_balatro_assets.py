"""Extract Balatro UI assets into bench/static/balatro/.

The dashboard reuses Balatro's own font, sounds, shaders, and logo for its
theming. These assets are NOT checked into git (they're copyrighted content
from Balatro.exe), so each user runs this script once against their own
Steam install.

Balatro.exe is a LÖVE-bundled executable — effectively a ZIP with a header.
Python's `zipfile` module reads it directly without extra tools.

Usage:
    python -m bench.static.extract_balatro_assets
    python -m bench.static.extract_balatro_assets --balatro "D:/Games/Balatro/Balatro.exe"

Without --balatro, the script probes a handful of common Steam install paths
on Windows/macOS/Linux.
"""

from __future__ import annotations

import argparse
import os
import sys
import zipfile
from pathlib import Path


# (source_path_inside_exe, dest_relative_to_balatro_dir)
ASSETS: list[tuple[str, str]] = [
    # Font — powers the @font-face and all m6x11plus text on the dashboard
    ("resources/fonts/m6x11plus.ttf", "fonts/m6x11plus.ttf"),
    # Shaders — the animated swirl background is a WebGL port of background.fs
    ("resources/shaders/background.fs", "shaders/background.fs"),
    ("resources/shaders/CRT.fs", "shaders/CRT.fs"),
    # Logo — faded watermark inside run-card chart backgrounds
    ("resources/textures/2x/balatro.png", "textures/balatro.png"),
    ("resources/textures/2x/balatro_alt.png", "textures/balatro_alt.png"),
    # UI sounds — wired to button clicks & hovers
    ("resources/sounds/button.ogg", "sounds/button.ogg"),
    ("resources/sounds/cancel.ogg", "sounds/cancel.ogg"),
    ("resources/sounds/highlight1.ogg", "sounds/highlight1.ogg"),
    ("resources/sounds/highlight2.ogg", "sounds/highlight2.ogg"),
    ("resources/sounds/generic1.ogg", "sounds/generic1.ogg"),
    ("resources/sounds/card1.ogg", "sounds/card1.ogg"),
    ("resources/sounds/cardSlide1.ogg", "sounds/cardSlide1.ogg"),
    ("resources/sounds/coin3.ogg", "sounds/coin.ogg"),
    ("resources/sounds/chips1.ogg", "sounds/chips.ogg"),
    ("resources/sounds/whoosh.ogg", "sounds/whoosh.ogg"),
]

DEFAULT_STEAM_PATHS = [
    # Windows
    r"C:/Program Files (x86)/Steam/steamapps/common/Balatro/Balatro.exe",
    r"C:/Program Files/Steam/steamapps/common/Balatro/Balatro.exe",
    # macOS
    str(Path.home() / "Library/Application Support/Steam/steamapps/common/Balatro/Balatro.app/Contents/MacOS/love"),
    # Linux
    str(Path.home() / ".steam/steam/steamapps/common/Balatro/Balatro.exe"),
    str(Path.home() / ".local/share/Steam/steamapps/common/Balatro/Balatro.exe"),
]


def find_balatro() -> str | None:
    for p in DEFAULT_STEAM_PATHS:
        if os.path.exists(p):
            return p
    return None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--balatro", help="Path to Balatro.exe (auto-detected if omitted)")
    parser.add_argument("--out", help="Output directory (default: next to this script)")
    args = parser.parse_args()

    exe = args.balatro or find_balatro()
    if not exe:
        print("Could not find Balatro.exe. Pass --balatro /path/to/Balatro.exe.", file=sys.stderr)
        print("Probed paths:", file=sys.stderr)
        for p in DEFAULT_STEAM_PATHS:
            print(f"  {p}", file=sys.stderr)
        return 2

    out_base = Path(args.out) if args.out else Path(__file__).resolve().parent / "balatro"
    out_base.mkdir(parents=True, exist_ok=True)

    try:
        zf = zipfile.ZipFile(exe)
    except zipfile.BadZipFile:
        print(f"{exe} is not a LÖVE-bundled archive. Is this really Balatro.exe?", file=sys.stderr)
        return 3

    with zf:
        copied = skipped = 0
        for src, rel_dest in ASSETS:
            dest = out_base / rel_dest
            dest.parent.mkdir(parents=True, exist_ok=True)
            try:
                data = zf.read(src)
            except KeyError:
                print(f"  MISS  {src} (not found inside Balatro.exe)", file=sys.stderr)
                skipped += 1
                continue
            dest.write_bytes(data)
            print(f"  OK    {rel_dest} ({len(data):,} bytes)")
            copied += 1

    print(f"\nExtracted {copied} assets to {out_base}")
    if skipped:
        print(f"{skipped} asset(s) were missing — dashboard will fall back gracefully for those.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
