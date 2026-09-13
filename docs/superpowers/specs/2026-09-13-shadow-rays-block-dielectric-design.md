# Gap #22 — shadow rays block refractive glass, as Cycles does

**Date:** 2026-09-13
**Decision:** option A (user, 2026-09-13): the dielectric share of a surface
blocks a shadow ray; only the Transparent-BSDF (alpha) share passes it.
Reverses the pass-through half of `2026-09-05-transparent-shadows-design.md`.

## Problem

`lights_trace_shadow_ray` pass B (`raytracing_lights_inc.glsl:~490`) lets a
shadow ray through a transmissive interface at

```
atten *= pass_through + (1 - pass_through) * transmission * (1 - F)
```

so the sky (and any light) reached that way is ALSO reached by the refracted
BSDF path, and the two MIS strategies do not estimate the same integrand —
the pass-B attenuation is smooth Fresnel, the lobe's real transmittance is
the rough microfacet one. Measured on the white glass furnace as the
NEE-on/NEE-off excess: **+2.4% / +7.3% / +8.6%** at roughness 0.3 / 0.6 / 0.9
(roadmap §11.14). `pt_glass_energy_gate` carries a 10% bar to admit it.

## What Cycles does

`surface_shader_transparency()` (`intern/cycles/kernel/integrator/
surface_shader.h:1053`) returns the transparent closure's extinction when the
surface has one, and **zero** otherwise. A shadow ray passes a Transparent
BSDF and is stopped by everything else, including refractive glass. Light
inside or behind glass arrives only through refracted bounce paths; a delta
lamp (sun) cannot be reached that way at all. That is the standard "Cycles
glass casts a solid shadow" behaviour, and it is what the Blender references
were rendered with.

## Design

### Shader — one rule

In pass B the per-crossing factor becomes the Transparent share alone:

```glsl
float pass_through = ((mat.flags & RT_MAT_FLAG_BLEND) != 0u) ? (1.0 - m_alpha) : 0.0;
atten *= pass_through;
```

A non-blend transmissive instance therefore zeroes `atten` at its first
crossing and the march returns `vec3(0.0)` — a full occluder, exactly what
pass A does for opaque geometry. The Fresnel evaluation (`N`, `eta`, `F`,
`cos_t`, `fetch_tbn`) in pass B is removed with the term that used it. The
`RT_GET_TRANSMISSION_ENABLED()` toggle no longer has a role in pass B: with
it on or off the dielectric share blocks, which is also what the BSDF draws
with it off. Pass A's mask, the `RT_GET_TRANSMISSIVE_GEOMETRY()` early
return and the crossing march are unchanged (blend panes still stack).

### Gates

- `pt_transparent_shadow_gate`: probes 1–4 put a dielectric pane between a
  lit floor and the light; they asserted the old pass-through values
  (0.9216, 0.3749, 0.8493, 0.2304). Under Cycles' rule each reads **0.0**
  (the floor under the pane is in full shadow). They become one-sided
  `< 0.01` assertions with the header rewritten; probe 5 (BLEND alpha 0.5,
  two crossings → **0.25**) is the Cycles-matching Transparent share and is
  unchanged — it is what keeps the gate falsifiable against "glass blocks
  everything, including alpha".
- `pt_glass_energy_gate`: `BAR` 0.10 → 0.03. NEE-off readings on record are
  0.9925 / 0.9644 / 0.9745 against Cycles 0.9756 / 0.9640 / 0.9845; with the
  excess gone NEE-on must land there.
- `pt_thin_layer_gate` T4a/T4b (converted-glass pane over an emissive plate):
  the plate's emissive-NEE shadow ray through the pane is now blocked; the
  plate is reached by the refracted BSDF path (smooth → MIS weight 1). If the
  reading moves, the new value is recorded with this reasoning; T4b must
  still equal T4a.
- Everything else must not move; the suite runs in full.

### Assets

replay192 and 217 at FHD, production route: expected ±0% (job 217 has zero
traced-dielectric materials since the B rule; BLEND glass is the alpha
share in both engines).

## Not in scope

Caustics / shadow caustics (Cycles' opt-in path for lighting through glass
from lamps) — a separate feature.

## Plan

1. Shader change + comment rewrite; build.
2. Update the three gates' expectations with the derivations above; run
   them; record readings.
3. Full gate suite, doctest, the two asset renders.
4. Roadmap row 22 → CLOSED, §11.22; commit.
