#!/usr/bin/env python3
"""Build the phone's app icon from the owner's masters.

The two apps are one product, so they wear one icon. The macOS build puts the
same masters on Apple's 824-point tile; iOS is the other grid: the artwork is
**full-bleed and opaque**, and the system applies the rounded mask itself. An
iOS icon may not carry an alpha channel at all -- App Store Connect rejects it
even when every pixel is opaque -- so the sources are flattened and written as
RGB.

The mark used by the Live Activity is not the app icon: it is the glyph alone,
white on transparency, cropped to its own ink. That asset is a template image,
because the system tints it against the island's black background.

    python3 scripts/make-app-icon.py [--source PATH] [--dark-source PATH] [--check]

Default sources are the masters under the workspace's `icon-design/`. The two
committed AppIcon PNGs and the three Live Activity PNGs are the deliverables;
`--check` exits non-zero if any of them is stale.
"""

from __future__ import annotations

import argparse
import importlib.util
import sys
from pathlib import Path

from PIL import Image, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
WORKSPACE = ROOT.parent
MASTER_DIR = WORKSPACE / "icon-design" / "masters" / "mizar-icon"
DEFAULT_SOURCE = MASTER_DIR / "light.png"
DEFAULT_DARK_SOURCE = MASTER_DIR / "dark.png"
DEFAULT_MARK_SOURCE = MASTER_DIR / "light-transparent.png"

OUT_DIR = ROOT / "DSH-Mizar" / "Assets.xcassets" / "AppIcon.appiconset"
OUT = OUT_DIR / "AppIcon-1024.png"
OUT_DARK = OUT_DIR / "AppIcon-1024-dark.png"

WIDGET_SET = ROOT / "DSH-Mizar-LiveActivity" / "Assets.xcassets" / "MizarIcon.imageset"
WIDGET_OUT = {
    32: WIDGET_SET / "MizarIcon.png",
    64: WIDGET_SET / "MizarIcon@2x.png",
    96: WIDGET_SET / "MizarIcon@3x.png",
}

CANVAS = 1024


def build(source: Path) -> Image.Image:
    """One appearance: full-bleed, opaque, 1024 points.

    The source is already a square composition with its own background; the
    only job here is to put it on the 1024 grid and remove alpha. Resampling
    once with Lanczos is deliberately the whole edit -- cropping the macOS
    tile here would throw away the outer margin the icon was drawn with.
    """
    master = Image.open(source).convert("RGB")
    if master.width != master.height:
        raise SystemExit(f"{source} is {master.width}x{master.height}, expected a square")
    return master.resize((CANVAS, CANVAS), Image.LANCZOS)


def build_mark_from_raster(source: Path) -> Image.Image:
    """The glyph alone, white on transparency, cropped to its ink.

    Fallback for a checkout without the shared geometry module. The preferred
    path renders the five arcs from their numbers, because thresholding a
    raster leaves the caps visibly stepped at Live Activity sizes.
    """
    image = Image.open(source).convert("RGBA")
    alpha = image.getchannel("A")
    # The transparent masters carry a soft shadow around the glyph. A template
    # mark is a cut-out, so keep the ink and drop the shadow.
    alpha = alpha.point(lambda value: 0 if value < 96 else 255)
    alpha = alpha.filter(ImageFilter.GaussianBlur(0.6))
    bbox = alpha.getbbox()
    if bbox is None:
        raise SystemExit(f"{source} has no visible mark")
    alpha = alpha.crop(bbox)
    side = max(alpha.size)
    # A square canvas keeps the asset's aspect independent of which side the
    # glyph's bounding box happens to be longer.
    canvas = Image.new("L", (side, side), 0)
    canvas.paste(alpha, ((side - alpha.width) // 2, (side - alpha.height) // 2))
    white = Image.new("RGBA", (side, side), (255, 255, 255, 0))
    white.putalpha(canvas)
    return white


def build_marks(source: Path) -> dict[int, Image.Image]:
    """The template mark at each of the sizes the imageset ships."""
    geometry = MASTER_DIR / "ring_geometry.py"
    if geometry.exists():
        spec = importlib.util.spec_from_file_location("mizar_ring_geometry", geometry)
        if spec is None or spec.loader is None:
            raise SystemExit(f"could not load {geometry}")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return {
            pixels: module.render(pixels, padding=0.02, supersample=8)
            for pixels in WIDGET_OUT
        }
    raster = build_mark_from_raster(source)
    return {
        pixels: raster.resize((pixels, pixels), Image.LANCZOS)
        for pixels in WIDGET_OUT
    }


def matches(path: Path, image: Image.Image) -> bool:
    """Whether the committed file is already this image."""
    if not path.exists():
        return False
    mode = "RGB" if image.mode == "RGB" else "RGBA"
    current = Image.open(path).convert(mode)
    return current.size == image.size and current.tobytes() == image.tobytes()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    parser.add_argument("--dark-source", type=Path, default=DEFAULT_DARK_SOURCE)
    parser.add_argument("--mark-source", type=Path, default=DEFAULT_MARK_SOURCE)
    parser.add_argument("--check", action="store_true")
    arguments = parser.parse_args()

    for source in (arguments.source, arguments.dark_source, arguments.mark_source):
        if not source.exists():
            print(f"no icon source at {source}")
            return 1

    light = build(arguments.source)
    dark = build(arguments.dark_source)
    marks = build_marks(arguments.mark_source)

    if arguments.check:
        stale = [
            path
            for path, image in (
                (OUT, light),
                (OUT_DARK, dark),
                *[(WIDGET_OUT[pixels], marks[pixels]) for pixels in WIDGET_OUT],
            )
            if not matches(path, image)
        ]
        if stale:
            for path in stale:
                print(f"{path} is missing or stale; run scripts/make-app-icon.py")
            return 1
        print("app icons and the Live Activity mark are up to date")
        return 0

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    light.save(OUT, format="PNG", optimize=True)
    dark.save(OUT_DARK, format="PNG", optimize=True)
    WIDGET_SET.mkdir(parents=True, exist_ok=True)
    for pixels, path in WIDGET_OUT.items():
        marks[pixels].save(path, format="PNG", optimize=True)
    print(f"app icons: {OUT.name}, {OUT_DARK.name} ({CANVAS}x{CANVAS}, RGB)")
    print(f"Live Activity mark: {', '.join(path.name for path in WIDGET_OUT.values())}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
