"""Daylight design validation (spec 2026-09-19-daylight-design.md, "The four jobs").

    python tools/daylight_validation.py <job>.pfm <job>_godot.log [--wall y0 y1 x0 x1]

The PFM is the LINEAR accumulation buffer (before exposure and tone curve),
converted from the still route's EXR. The exposure is read from the log's
"[Daylight] probe:" / "[Daylight] fill:" lines, so the numbers below are
what the tone curve received:

  occupied median x e            must be in [0.15, 0.35]
  min over 4x4 tiles of the occupied tile-mean x e   must be >= 0.02
  window pixels with L x e > 1.0                     <= 2% of the window
  wall grain (5x5 residual RMS / mean on the wall crop, fractions of the
  frame, default the central 20% x 20%)               <= 10%

"Occupied" and "window" use the probe's own rule: window = pixels above 8x
the raw median.
"""
import re
import sys

import numpy as np

MASK_RATIO = 8.0


def read_pfm(path):
    with open(path, "rb") as f:
        assert f.readline().strip() == b"PF"
        w, h = map(int, f.readline().split())
        scale = float(f.readline())
        data = np.frombuffer(f.read(), dtype="<f4" if scale < 0 else ">f4").reshape(h, w, 3)
    return data[::-1].astype(np.float64)


def exposure_from_log(path):
    text = open(path, encoding="utf-8", errors="replace").read()
    fill = re.findall(r"\[Daylight\] fill:.*exposure ([0-9.]+) -> ([0-9.]+)", text)
    if fill:
        return float(fill[-1][1]), True
    probe = re.findall(r"\[Daylight\] probe: .*exposure ([0-9.]+)", text)
    if not probe:
        raise SystemExit("no [Daylight] probe line in %s" % path)
    return float(probe[-1]), False


def box(x, k):
    p = np.pad(x, k // 2, mode="edge")
    c = np.cumsum(np.cumsum(p, axis=0), axis=1)
    c = np.pad(c, ((1, 0), (1, 0)))
    H, W = x.shape
    return (c[k:k + H, k:k + W] - c[0:H, k:k + W] - c[k:k + H, 0:W] + c[0:H, 0:W]) / (k * k)


def main():
    args = sys.argv[1:]
    wall = [0.40, 0.60, 0.40, 0.60]
    if "--wall" in args:
        i = args.index("--wall")
        wall = [float(v) for v in args[i + 1:i + 5]]
        del args[i:i + 5]
    pfm, log = args[:2]
    img = read_pfm(pfm)
    lum = img.mean(axis=2)
    e, had_fill = exposure_from_log(log)
    raw_median = np.median(lum)
    window = lum > MASK_RATIO * raw_median
    occupied = ~window
    med = np.median(lum[occupied]) * e
    h, w = lum.shape
    tile_min = 1e9
    for j in range(4):
        for i in range(4):
            sl = (slice(j * h // 4, (j + 1) * h // 4), slice(i * w // 4, (i + 1) * w // 4))
            occ = occupied[sl]
            if occ.mean() < 0.5:
                continue  # a tile that is mostly window is not "occupied"
            tile_min = min(tile_min, lum[sl][occ].mean() * e)
    clipped = (lum[window] * e > 1.0).mean() if window.any() else 0.0
    ys, ye, xs, xe = int(h * wall[0]), int(h * wall[1]), int(w * wall[2]), int(w * wall[3])
    crop = lum[ys:ye, xs:xe]
    grain = np.sqrt(((crop - box(crop, 5)) ** 2).mean()) / max(crop.mean(), 1e-9)
    ok = lambda c: "ok " if c else "RED"
    print("%s  exposure %.3f%s  window %.1f%% of frame" % (pfm, e, " (with DaylightFill)" if had_fill else "", 100 * window.mean()))
    print("  %s occupied median x e   %.4f   [0.15, 0.35]" % (ok(0.15 <= med <= 0.35), med))
    print("  %s darkest occupied tile %.4f   >= 0.02" % (ok(tile_min >= 0.02), tile_min))
    print("  %s window clipped        %.2f%%  <= 2%%" % (ok(clipped <= 0.02), 100 * clipped))
    print("  %s wall grain            %.2f%%  <= 10%%  (crop rows %.2f-%.2f cols %.2f-%.2f)" % (ok(grain <= 0.10), 100 * grain, *wall))


if __name__ == "__main__":
    main()
