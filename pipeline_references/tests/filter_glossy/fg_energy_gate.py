"""Filter Glossy energy gate (spec docs/superpowers/specs/2026-10-14-pt-filter-glossy-design.md).

Filter Glossy may trade noise for blur; it must not add light or fireflies. Compares the raw
OIDN input (pre-exposure, so the daylight probe's re-metering cannot hide a bias) of a Filter
Glossy OFF render against an ON render of the same job on the same binary.

Make the two dumps with the live pipeline scripts (day still, sun off isolates the sky/glass
path that failed first; 64 spp is enough):
    off: override.cfg "[rendering]\\npathtracer/filter_glossy=0.0", env
         ZR_PT_ACCUM_TARGET=64 ZR_PT_CLAMP_INDIRECT=0 ZR_OIDN_DUMP=<off_dir>
    on:  no override, same env with ZR_OIDN_DUMP=<on_dir>

usage: python fg_energy_gate.py <off_dump_dir> <on_dump_dir>     exit 0 = PASS, 1 = FAIL

History: RED on dd87243e38, which blurred glass (mean +29.55%, median +12.18%, >200 spikes
1 -> 10, job 209 sun off); GREEN once transmissive materials are skipped (-1.03%, +0.68%, 1 -> 1).
"""
import os
import sys

import numpy as np

LUMA = np.array([0.2126, 0.7152, 0.0722], np.float32)


def read_pfm(path):
    with open(path, "rb") as f:
        assert f.readline().strip() in (b"PF", b"Pf")
        w, h = map(int, f.readline().split())
        scale = float(f.readline())
        a = np.fromfile(f, dtype="<f4" if scale < 0 else ">f4").reshape(h, w, 3)
    return np.flipud(a)


def box4(l):
    # Medians of single noisy pixels are biased low; take them on 4x4 box averages.
    h, w = l.shape[0] // 4 * 4, l.shape[1] // 4 * 4
    return l[:h, :w].reshape(h // 4, 4, w // 4, 4).mean(axis=(1, 3))


def main():
    off = read_pfm(os.path.join(sys.argv[1], "oidn_color.pfm")) @ LUMA
    on = read_pfm(os.path.join(sys.argv[2], "oidn_color.pfm")) @ LUMA
    mean = 100.0 * (on.mean() / off.mean() - 1.0)
    median = 100.0 * (np.median(box4(on)) / np.median(box4(off)) - 1.0)
    spikes_off, spikes_on = int((off > 200.0).sum()), int((on > 200.0).sum())
    checks = [
        ("mean within 2%", abs(mean) <= 2.0, f"{mean:+.2f}%"),
        ("box4 median within 2%", abs(median) <= 2.0, f"{median:+.2f}%"),
        ("no new >200 spikes (on <= off + 2)", spikes_on <= spikes_off + 2, f"off {spikes_off} on {spikes_on}"),
    ]
    for name, ok, value in checks:
        print(f"{'PASS' if ok else 'FAIL'}: {name}: {value}")
    return 0 if all(ok for _, ok, _ in checks) else 1


if __name__ == "__main__":
    sys.exit(main())
