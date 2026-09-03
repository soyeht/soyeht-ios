#!/usr/bin/env python3
"""Measure whether a neo surface actually reads as one material.

The failure mode this catches is banding: a shadow that clips at a slot
boundary, or a gradient quantised into visible steps, turns a smooth canvas
into stripes. The eye notices it long before anyone can say why the screen
looks cheap, and a screenshot diff will not catch it — the image is "correct",
it is just made of steps.

MAX-STEP is the largest jump in lightness between two adjacent runs of equal
colour along a scanline. A canvas that is genuinely one material steps by 1–2
units as it shades; the three failed grid-lighting generations measured 15 and
26 (see the neomorphism-macos skill). The budget is 8.

    uv run QA/scripts/neo_measure.py shot.png
    uv run QA/scripts/neo_measure.py shot.png --region 40,40,640,420 --budget 8

Prints one line per axis and exits non-zero when a budget is exceeded, so it
can sit in a gate.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

try:
    from PIL import Image
except ImportError:  # pragma: no cover - the message is the whole point
    sys.exit("Pillow is required: uv run --with pillow QA/scripts/neo_measure.py …")


def lightness(pixel: tuple[int, int, int]) -> float:
    """Rec. 709 luma, 0–255. Close enough to L* for a step measurement and it
    does not need a colour profile the screenshot may not carry."""
    r, g, b = pixel[:3]
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def max_step(values: list[float]) -> tuple[float, int]:
    """Largest jump between adjacent *runs* of equal value, and where it is.

    Runs matter: a smooth ramp quantised to 8-bit steps by one unit at a time
    is fine, and comparing raw neighbours would report that same 1 as the
    answer. What is wrong is a plateau followed by a cliff.
    """
    worst, worst_at = 0.0, -1
    previous = values[0]
    for index, value in enumerate(values[1:], start=1):
        if value == values[index - 1]:
            continue
        step = abs(value - previous)
        if step > worst:
            worst, worst_at = step, index
        previous = value
    return worst, worst_at


def scan(image: Image.Image, budget: float) -> int:
    pixels = image.convert("RGB").load()
    width, height = image.size
    failures = 0

    for label, line in (
        ("horizontal (mid)", [lightness(pixels[x, height // 2]) for x in range(width)]),
        ("vertical (mid)", [lightness(pixels[width // 2, y]) for y in range(height)]),
        ("horizontal (upper third)", [lightness(pixels[x, height // 3]) for x in range(width)]),
        ("vertical (right third)", [lightness(pixels[(width * 2) // 3, y]) for y in range(height)]),
    ):
        step, at = max_step(line)
        verdict = "ok" if step <= budget else "OVER BUDGET"
        if step > budget:
            failures += 1
        print(f"{label:26} MAX-STEP {step:5.1f} at {at:5d}  {verdict}")

    return failures


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("image", type=Path)
    parser.add_argument(
        "--region",
        help="x,y,w,h — measure a crop instead of the whole image. Use it to "
             "exclude text and icons, which step legitimately.",
    )
    parser.add_argument("--budget", type=float, default=8.0)
    args = parser.parse_args()

    if not args.image.exists():
        return print(f"no such image: {args.image}") or 2

    image = Image.open(args.image)
    if args.region:
        x, y, w, h = (int(part) for part in args.region.split(","))
        image = image.crop((x, y, x + w, y + h))

    print(f"{args.image.name}  {image.size[0]}×{image.size[1]}  budget {args.budget:g}")
    failures = scan(image, args.budget)
    if failures:
        print(f"\n{failures} axis over budget — the surface is banding, not shading.")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
