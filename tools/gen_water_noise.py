#!/usr/bin/env python3
"""Bake the seamless fBm noise texture the water shader samples.

The water shader used to build noise from `fract(sin(dot(p, k)) * big)` — four
sine calls per lattice corner, twelve per fBm, ~800 per pixel once the
per-island loop was included. That is both slow and precision-dependent: at
campaign-scale world coordinates the sine argument overflows float32 mantissa
precision, so the "random" field differs between GPUs and shimmers on mobile.

So we bake the fBm once, offline, and let the GPU sample it.

This deliberately reproduces the *statistics* of the old shader fBm rather than
baking prettier noise: same value-noise basis, same smoothstep interpolation,
same three octaves at amplitude 1/2, 1/4, 1/8, and the same unnormalised
[0, 0.875] output range. Downstream constants are tuned against that
distribution — `pow(r1 * r2, 9)` for the sun glitter, for one, explodes if the
field is rescaled to reach 1.0 — so matching it is what lets the existing look
carry over unchanged while new terms layer on top.

Two deliberate differences from the old fBm, neither visible:
  - Octaves step by 2x, not the old rotate-and-scale-by-2.1. A rotation cannot
    tile, and the rotation only existed to hide axis alignment, which three
    octaves of value noise barely show.
  - The lattice wraps modulo its own size, so the tile is seamless by
    construction (no blend-skirt seam like NoiseTexture2D's). One tile spans 16
    lattice units; the shader keeps every sampling constant it already had.

Regenerate with:
    python3 tools/gen_water_noise.py
Deterministic for a given SEED, so the committed PNG is reproducible.
"""

from __future__ import annotations

import pathlib

import numpy as np
from PIL import Image

SIZE = 1024
# Lattice cells across the tile per octave. Each must divide SIZE so the lattice
# wraps seamlessly. 16 cells = 64 px per base cell, so one lattice unit is 64 px
# and the tile is 16 lattice units. The finest octave still gets 16 px per cell,
# well above the ~4 px floor where bilinear minification starts to alias.
OCTAVES = (16, 32, 64)
AMPLITUDES = (0.5, 0.25, 0.125)
# The old fBm summed to at most 0.875 and the shader is tuned to that ceiling.
# Store the field scaled into the full 8-bit range and undo it in the shader, so
# quantisation costs us nothing.
PEAK = sum(AMPLITUDES)
SEED = 20260801
OUT = pathlib.Path(__file__).resolve().parent.parent / "assets/textures/water_noise.png"


def periodic_value_noise(size: int, cells: int, rng: np.random.Generator) -> np.ndarray:
    """Value noise in [0, 1], periodic over `size` px, matching the old shader's
    `value_noise`: uniform lattice values, smoothstep-interpolated."""
    lattice = rng.random((cells, cells))

    step = size // cells
    lin = np.arange(size)
    cell = lin // step
    frac = (lin % step) / step
    # u = f * f * (3 - 2f) — the exact smoothstep the old shader used.
    smooth = frac * frac * (3.0 - 2.0 * frac)

    ci, cj = np.meshgrid(cell, cell, indexing="ij")
    ui, uj = np.meshgrid(smooth, smooth, indexing="ij")

    # Wrapping the corner index is what makes the tile seamless.
    c00 = lattice[ci % cells, cj % cells]
    c10 = lattice[(ci + 1) % cells, cj % cells]
    c01 = lattice[ci % cells, (cj + 1) % cells]
    c11 = lattice[(ci + 1) % cells, (cj + 1) % cells]

    top = c00 + (c10 - c00) * ui
    bot = c01 + (c11 - c01) * ui
    return top + (bot - top) * uj


def main() -> None:
    rng = np.random.default_rng(SEED)
    field = np.zeros((SIZE, SIZE), dtype=np.float64)
    for cells, amp in zip(OCTAVES, AMPLITUDES):
        field += amp * periodic_value_noise(SIZE, cells, rng)

    img = np.clip(field / PEAK * 255.0 + 0.5, 0, 255).astype(np.uint8)

    OUT.parent.mkdir(parents=True, exist_ok=True)
    Image.fromarray(img, mode="L").save(OUT, optimize=True)
    scaled = img / 255.0 * PEAK
    print(
        f"wrote {OUT} {SIZE}x{SIZE} octaves={OCTAVES}\n"
        f"  fbm range [{scaled.min():.4f}, {scaled.max():.4f}] "
        f"mean={scaled.mean():.4f} std={scaled.std():.4f} (old fBm peak {PEAK})"
    )


if __name__ == "__main__":
    main()
