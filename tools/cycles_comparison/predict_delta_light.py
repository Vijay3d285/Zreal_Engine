# -*- coding: utf-8 -*-
# Delta light from the camera direction on a white metal sphere: L == V, so
# H == N and every pixel is an analytic BRDF value. Predict ours (no ms) and
# Cycles (energy_scale 1/E, darkening 1 for F == 1) as ratio to the Lambertian
# control, over the same per-pixel trace of the matched camera.
import math
import re
import numpy as np

ROOT = r"C:\Users\aiadmin\Desktop\Engine_Build_test\Zreal_Engine"


def load(path, name):
    s = open(path, encoding="utf-8").read()
    m = re.search(name + r"\[(\d+)\] = \{(.*?)\};", s, re.S)
    return [float(v) for v in re.findall(r"[-+]?\d*\.\d+(?:e[-+]?\d+)?", m.group(2))]


E_T = load(ROOT + r"\servers\rendering\renderer_rd\storage_rd\ggx_energy_tables.h", "GGX_E_TABLE")


def r1(tab, base, x, size):
    x = min(max(x, 0.0), 1.0) * (size - 1)
    i = min(int(x), size - 1); n = min(i + 1, size - 1); t = x - i
    d0 = tab[base + i]
    return d0 if t == 0.0 else (1 - t) * d0 + t * tab[base + n]


def r2(tab, base, x, y, xs, ys):
    y = min(max(y, 0.0), 1.0) * (ys - 1)
    i = min(int(y), ys - 1); n = min(i + 1, ys - 1); t = y - i
    d0 = r1(tab, base + xs * i, x, xs)
    return d0 if t == 0.0 else (1 - t) * d0 + t * r1(tab, base + xs * n, x, xs)


def ggxE(rough, mu):
    return r2(E_T, 0, rough, mu, 32, 32)


def D(alpha2, c):
    d = c * c * (alpha2 - 1) + 1
    return alpha2 / (math.pi * d * d)


def G1(alpha2, c):
    c2 = c * c
    return 2.0 / (math.sqrt((alpha2 * (1 - c2) + c2) / c2) + 1.0)


def G2_hc(alpha2, l, v):
    # height-correlated, Lagarde form used by the engine: G2 = 0.5/(a+b) * 4*NdotL*NdotV ... use lambda form
    lam = lambda c: (-1 + math.sqrt(1 + alpha2 * (1 - c * c) / (c * c))) / 2
    return 1.0 / (1 + lam(l) + lam(v))


# camera trace, matched to the gate: dist 2.5, fov 20 vertical, 256x256
RES, DIST, FOV = 256, 2.5, math.radians(20.0)
half = math.tan(FOV / 2)
mus = []
for py in range(RES):
    for px in range(RES):
        u = ((px + 0.5) / RES * 2 - 1) * half
        v = ((py + 0.5) / RES * 2 - 1) * half
        dx, dy, dz = u, v, -1.0
        L = math.sqrt(dx * dx + dy * dy + dz * dz)
        dx, dy, dz = dx / L, dy / L, dz / L
        b = 2 * DIST * dz; c = DIST * DIST - 1
        disc = b * b - 4 * c
        if disc <= 0:
            continue
        t = (-b - math.sqrt(disc)) / 2
        nx, ny, nz = dx * t, dy * t, DIST + dz * t
        mus.append(-(dx * nx + dy * ny + dz * nz))
mus = np.array(mus)
print("pixels %d, mu range %.4f..%.4f mean %.4f" % (len(mus), mus.min(), mus.max(), mus.mean()))

lambert = np.mean(mus / math.pi)  # albedo 1, irradiance 1
print("%-6s %10s %10s %10s %10s" % ("rough", "ours/ctl", "cycles/ctl", "ratio", "measured"))
meas = {0.3: (1.56432060, 1.58024949), 0.6: (0.98895320, 1.20756751), 0.9: (0.37276619, 0.86657359)}
for rough in (0.3, 0.6, 0.9):
    alpha = rough * rough; alpha2 = alpha * alpha
    ours = np.mean([D(alpha2, m) * G2_hc(alpha2, m, m) / (4 * m) for m in mus])
    cyc = np.mean([D(alpha2, m) * G2_hc(alpha2, m, m) / (4 * m) / ggxE(rough, m) for m in mus])
    print("%-6.1f %10.5f %10.5f %10.4f   gate: ours %.5f cycles %.5f" % (rough, ours / lambert, cyc / lambert, ours / cyc, meas[rough][0], meas[rough][1]))
