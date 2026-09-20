"""Daylight design validation (spec 2026-09-19-daylight-design.md, "The four jobs").

    python tools/daylight_validation.py <job>.pfm <job>_godot.log <job>.png [--wall y0 y1 x0 x1]

The PFM is the LINEAR accumulation buffer (before exposure, AgX and OIDN --
it is the raw, pre-denoise pathtracing accumulator, converted from the
still route's EXR). The PNG is the shipped deliverable: tonemapped through
AgX and, when OIDN is enabled, denoised. The exposure is read from the
log's "[Daylight] probe:" / "[Daylight] fill:" lines, so the linear-buffer
numbers below are what the tone curve received:

  occupied median x e            must be in [0.15, 0.35]
  min over 4x4 tiles of the occupied tile-mean x e   must be >= 0.02
  wall grain, PRE-denoise (5x5 residual RMS / mean on the wall crop of the
  PFM, fractions of the frame, default the central 20% x 20%)   <= 10%

Window clipping is judged on the tonemapped PNG, not the linear buffer.
A physical window is 10-50x brighter than the wall it sits in, so once the
occupied median is exposed up to ~0.18 every window pixel is, by
construction, > 1.0 in the linear buffer -- compressing that back into
range is exactly AgX's job, not a defect. So the real gate is: after the
tone curve, are window pixels sitting at the sensor ceiling (>= 254/255)
rather than holding highlight detail?

  window pixels with PNG value (mean of R,G,B) >= 254/255   <= 2% of the window

The old linear-buffer figure (window pixels with L x e > 1.0) is kept as
an informational line only -- it is expected to run high and is not itself
a pass/fail signal. A post-denoise grain figure, computed the same way as
the wall-grain gate but on the 8-bit PNG's wall crop, is also printed
informationally; it is not gated because the PNG has already been through
AgX's non-linear response and (optionally) OIDN, so its noise floor is not
directly comparable to the linear buffer's.

"Occupied" and "window" use the probe's own rule: window = pixels above 8x
the raw median. When that mask catches less than 0.5% of the frame it is
almost certainly a stray specular highlight rather than an actual window,
and clipping is not a meaningful measurement on 1-2 dozen pixels -- the
clipping lines are skipped in that case rather than reporting a
degenerate 0% or 100%.
"""
import re
import sys

import numpy as np
from PIL import Image

MASK_RATIO = 8.0
TINY_WINDOW_FRACTION = 0.005


def read_pfm(path):
    with open(path, "rb") as f:
        assert f.readline().strip() == b"PF"
        w, h = map(int, f.readline().split())
        scale = float(f.readline())
        data = np.frombuffer(f.read(), dtype="<f4" if scale < 0 else ">f4").reshape(h, w, 3)
    return data[::-1].astype(np.float64)


def read_png_luma(path):
    im = Image.open(path).convert("RGB")
    return np.asarray(im, dtype=np.float64).mean(axis=2)


def exposure_from_log(path):
    text = open(path, encoding="utf-8", errors="replace").read()
    # Anchored on the literal punctuation next to the number, not a bare
    # "exposure" word -- both log lines use "exposure" more than once (the
    # fill line's "after exposure -> DaylightFill ..." has no digits after
    # it, so an unanchored match still fell through to the right group by
    # luck; anchoring removes the luck).
    fill = re.findall(r"\[Daylight\] fill:.*; exposure ([0-9.]+) -> ([0-9.]+)", text)
    if fill:
        return float(fill[-1][1]), True
    probe = re.findall(r"\[Daylight\] probe: .*, exposure ([0-9.]+)", text)
    if not probe:
        raise SystemExit("no [Daylight] probe line in %s" % path)
    return float(probe[-1]), False


def box(x, k):
    p = np.pad(x, k // 2, mode="edge")
    c = np.cumsum(np.cumsum(p, axis=0), axis=1)
    c = np.pad(c, ((1, 0), (1, 0)))
    H, W = x.shape
    return (c[k:k + H, k:k + W] - c[0:H, k:k + W] - c[k:k + H, 0:W] + c[0:H, 0:W]) / (k * k)


def grain(crop):
    return np.sqrt(((crop - box(crop, 5)) ** 2).mean()) / max(crop.mean(), 1e-9)


def main():
    args = sys.argv[1:]
    wall = [0.40, 0.60, 0.40, 0.60]
    if "--wall" in args:
        i = args.index("--wall")
        wall = [float(v) for v in args[i + 1:i + 5]]
        del args[i:i + 5]
    pfm, log, png = args[:3]
    img = read_pfm(pfm)
    lum = img.mean(axis=2)
    h, w = lum.shape
    png_lum = read_png_luma(png)
    ph, pw = png_lum.shape
    if (ph, pw) != (h, w):
        raise SystemExit("PFM/PNG size mismatch: %s is %dx%d but %s is %dx%d" % (pfm, w, h, png, pw, ph))
    e, had_fill = exposure_from_log(log)
    raw_median = np.median(lum)
    window = lum > MASK_RATIO * raw_median
    occupied = ~window
    med = np.median(lum[occupied]) * e
    tile_min = 1e9
    for j in range(4):
        for i in range(4):
            sl = (slice(j * h // 4, (j + 1) * h // 4), slice(i * w // 4, (i + 1) * w // 4))
            occ = occupied[sl]
            if occ.mean() < 0.5:
                continue  # a tile that is mostly window is not "occupied"
            tile_min = min(tile_min, lum[sl][occ].mean() * e)
    ys, ye, xs, xe = int(h * wall[0]), int(h * wall[1]), int(w * wall[2]), int(w * wall[3])
    crop = lum[ys:ye, xs:xe]
    wall_grain = grain(crop)
    png_crop = png_lum[ys:ye, xs:xe]
    png_grain = grain(png_crop)
    ok = lambda c: "ok " if c else "RED"
    print("%s  exposure %.3f%s  window %.1f%% of frame" % (pfm, e, " (with DaylightFill)" if had_fill else "", 100 * window.mean()))
    print("  %s occupied median x e   %.4f   [0.15, 0.35]" % (ok(0.15 <= med <= 0.35), med))
    print("  %s darkest occupied tile %.4f   >= 0.02" % (ok(tile_min >= 0.02), tile_min))
    if window.mean() < TINY_WINDOW_FRACTION:
        print("  window mask: %d pixels (%.4f%% of frame) -- no window above 8x the median; clipping not measured" % (int(window.sum()), 100 * window.mean()))
    else:
        linear_clipped = (lum[window] * e > 1.0).mean()
        png_clipped = (png_lum[window] >= 254.0).mean()
        print("  .   window > 1.0 linear before AgX: %.2f%%  (informational, expected high)" % (100 * linear_clipped))
        print("  %s window clipped (PNG >= 254/255)  %.2f%%  <= 2%%" % (ok(png_clipped <= 0.02), 100 * png_clipped))
    print("  %s wall grain, pre-denoise %.2f%%  <= 10%%  (crop rows %.2f-%.2f cols %.2f-%.2f)" % (ok(wall_grain <= 0.10), 100 * wall_grain, *wall))
    print("  .   wall grain, post-denoise (PNG) %.2f%%  (informational, same crop)" % (100 * png_grain))


if __name__ == "__main__":
    main()
