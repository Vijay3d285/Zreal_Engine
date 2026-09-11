# -*- coding: utf-8 -*-
# Offline predictor for Gap #21 cause (b) -- the base-layer withdrawal.
#
# A convex sphere under a uniform white world leaves after one hit, so the
# render of the DIFFUSE lobe is exactly base * mean_pixels(1 - withdrawal(mu)),
# and Cycles' closure_layering_weight is predictable from the LUTs alone: it
# withdraws darkening(mu) * estimate_albedo(mu), where darkening is what
# microfacet_ggx_preserve_energy multiplied sc->weight by before bsdf_albedo
# ever read it (bsdf_microfacet.h:481 -> svm/closure.h:468-470).
#
# This mirrors the engine's LUT readers EXACTLY (endpoint-aligned, not
# half-texel-centred) over the checked-in tables, traces the Cycles camera of
# cycles_velvet.py / cycles_gap21_split.py per pixel, and prints the predicted
# withdrawal against the measured numbers. Its own control is the first row: the
# bare-estimate model must reproduce the pre-fix engine's measured reading.
#
#   python tools/cycles_comparison/predict_gap21_layering.py
#
# Recorded run (2026-09-11), all three withdrawals as a fraction of the diffuse:
#   estimate only               0.042283  -> vs pre-fix engine measurement  -0.06%
#   darkening * estimate        0.035128  -> vs Cycles 5.2.1 measurement    -0.38%
#   (Schlick-Fss darkening)     0.035104  -> the shader's 1/21 Fss; 0.07% apart
# Measured after the fix: -0.376%.  Roadmap section 11.12.
import math
import os
import re

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))


def load(path, name):
    s = open(path, encoding="utf-8").read()
    m = re.search(name + r"\[(\d+)\] = \{(.*?)\};", s, re.S)
    vals = [float(v) for v in re.findall(r"[-+]?\d*\.\d+(?:e[-+]?\d+)?", m.group(2))]
    assert len(vals) == int(m.group(1)), (name, len(vals))
    return vals


COAT = load(ROOT + r"\servers\rendering\renderer_rd\storage_rd\ggx_coat_albedo_table.h", "GGX_COAT_ALBEDO_TABLE")
E_T = load(ROOT + r"\servers\rendering\renderer_rd\storage_rd\ggx_energy_tables.h", "GGX_E_TABLE")
EAVG = load(ROOT + r"\servers\rendering\renderer_rd\storage_rd\ggx_energy_tables.h", "GGX_EAVG_TABLE")


# ---- exact mirrors of the GLSL readers (ggxLutRead1D/2D, coatLutRead3D) ----
def r1(tab, base, x, size):
    x = min(max(x, 0.0), 1.0) * (size - 1)
    i = min(int(x), size - 1)
    n = min(i + 1, size - 1)
    t = x - i
    d0 = tab[base + i]
    return d0 if t == 0.0 else (1 - t) * d0 + t * tab[base + n]


def r2(tab, base, x, y, xs, ys):
    y = min(max(y, 0.0), 1.0) * (ys - 1)
    i = min(int(y), ys - 1)
    n = min(i + 1, ys - 1)
    t = y - i
    d0 = r1(tab, base + xs * i, x, xs)
    return d0 if t == 0.0 else (1 - t) * d0 + t * r1(tab, base + xs * n, x, xs)


def r3(tab, x, y, z, d=16):
    z = min(max(z, 0.0), 1.0) * (d - 1)
    i = min(int(z), d - 1)
    n = min(i + 1, d - 1)
    t = z - i
    d0 = r2(tab, d * d * i, x, y, d, d)
    return d0 if t == 0.0 else (1 - t) * d0 + t * r2(tab, d * d * n, x, y, d, d)


def ggxE(rough, mu):
    return r2(E_T, 0, rough, mu, 32, 32)


def ggxEavg(rough):
    return r1(EAVG, 0, rough, 32)


def F0_from_ior(ior):
    return ((ior - 1) / (ior + 1)) ** 2


def fresnel_dielectric_Fss(eta):
    return (eta - 1.0) / (4.08567 + 1.00071 * eta)


# ---- the two withdrawal models ----
ETA = 1.5
F0 = F0_from_ior(ETA)
ROUGH = 0.60  # roughness 0.6 -> alpha 0.36 -> sqrt(sqrt(alpha^2)) = 0.6
Z = math.sqrt(abs((ETA - 1) / (ETA + 1)))


def estimate(mu):
    s = r3(COAT, ROUGH, mu, Z)
    return F0 + (1.0 - F0) * s  # mix(f0, f90=1, s)


def darkening(mu, fss):
    E = ggxE(ROUGH, mu)
    Eavg = ggxEavg(ROUGH)
    missing = (1 - E) / E
    Fms = fss * Eavg / (1 - fss * (1 - Eavg))
    return (1 + Fms * missing) / (1 + missing)


# ---- Cycles camera, traced per pixel: 256x256, vertical FOV 20 deg, dist 2.5 ----
RES, DIST, FOV = 256, 2.5, math.radians(20.0)
half = math.tan(FOV / 2)
acc = {"est": 0.0, "dark_diel": 0.0, "dark_schl": 0.0, "n": 0}
FSS_DIEL = fresnel_dielectric_Fss(ETA)
FSS_SCHL = F0 + (1 - F0) / 21.0
for py in range(RES):
    for px in range(RES):
        u = ((px + 0.5) / RES * 2 - 1) * half
        v = ((py + 0.5) / RES * 2 - 1) * half
        # camera at (0,0,DIST) looking down -z at unit sphere at origin
        dx, dy, dz = u, v, -1.0
        L = math.sqrt(dx * dx + dy * dy + dz * dz)
        dx, dy, dz = dx / L, dy / L, dz / L
        # |o + t d|^2 = 1, o = (0,0,DIST)
        b = 2 * DIST * dz
        c = DIST * DIST - 1
        disc = b * b - 4 * c
        if disc <= 0:
            continue
        t = (-b - math.sqrt(disc)) / 2
        nx, ny, nz = dx * t, dy * t, DIST + dz * t
        mu = -(dx * nx + dy * ny + dz * nz)
        e = estimate(mu)
        acc["est"] += e
        acc["dark_diel"] += e * darkening(mu, FSS_DIEL)
        acc["dark_schl"] += e * darkening(mu, FSS_SCHL)
        acc["n"] += 1

n = acc["n"]
BASE = (0.12 + 0.02 + 0.03) / 3.0
meas_cycles_w = 0.00199747
meas_ours_b_w = 0.00239665
meas_ours_shipped_w = 0.00237028
diffuse_only_cycles = 0.05664716

print("pixels on sphere: %d  (Cycles n was reported by the script)" % n)
print("F0=%.4f eta=%.2f z=%.4f rough=%.2f Fss_diel=%.5f Fss_schlick=%.5f" % (F0, ETA, Z, ROUGH, FSS_DIEL, FSS_SCHL))
print()
for tag, k in [("estimate only (pre-fix engine)", "est"),
               ("darkening(dielectric Fss) * estimate  [Cycles]", "dark_diel"),
               ("darkening(Schlick Fss) * estimate  [our evalMultiScatterEnergy Fss]", "dark_schl")]:
    frac = acc[k] / n
    w = frac * diffuse_only_cycles
    print("%-70s frac=%.6f  withdrawal=%.8f  vs Cycles meas %.8f  (%+.2f%%)  vs ours(b) meas %.8f (%+.2f%%)"
          % (tag, frac, w, meas_cycles_w, (w / meas_cycles_w - 1) * 100, meas_ours_b_w, (w / meas_ours_b_w - 1) * 100))
print()
print("measured: Cycles withdrawal/diffuse = %.6f ; ours(b) = %.6f ; ours(shipped 1-F) = %.6f"
      % (meas_cycles_w / diffuse_only_cycles, meas_ours_b_w / diffuse_only_cycles, meas_ours_shipped_w / diffuse_only_cycles))
