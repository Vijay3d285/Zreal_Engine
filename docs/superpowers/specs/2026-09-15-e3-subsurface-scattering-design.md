# E3 — Subsurface scattering (Cycles random walk + thin-wall) — design

**Date:** 2026-09-15
**Scope:** engine (material data, hit shader, raygen flag), one gate with a
Cycles reference script, and one pipeline rule in `pipeline_references/
image_glb_creation.gd`. Closes the remainder of roadmap Gap #13 / Phase E3.
**Decision (user, 2026-09-15):** engine + pipeline rule, so real renders change.

## Why, and the fact that shapes the scope

Subsurface scattering is light entering a surface, scattering inside, and
leaving nearby: candle wax glowing at its edges, marble reading deep rather
than painted, a lampshade lighting up, a leaf going translucent against the
sun. It is the last BSDF the roadmap lists as missing.

No asset in the library carries it: all 465 GLBs were scanned, none has any
subsurface or volume data — glTF has no subsurface extension and Blender's
exporter drops Principled's Subsurface. A Cycles render of these GLBs has no
SSS either. So the engine feature alone changes nothing; it becomes visible
only through a pipeline rule that assigns it by material name, exactly as the
glass rule does. Candidate material names in the library: marble ×64,
leaf ×46, paper ×23, shade ×3, candle ×1.

## What Cycles does (read from source, 5.3.0-alpha)

Files: `intern/cycles/kernel/integrator/subsurface.h`,
`subsurface_random_walk.h`, `kernel/closure/bssrdf.h`,
`kernel/svm/closure.h:474-520`, `kernel/closure/bsdf_oren_nayar.h:160-215`.

1. **Allocation** (`svm/closure.h`). Principled splits the base diffuse
   share: `bssrdf weight = base_color × subsurface_weight × layering weight`,
   `diffuse weight = base_color × (1 − subsurface_weight) × layering weight`.
   `bssrdf->radius = max(subsurface_radius × subsurface_scale, 0)`,
   `albedo = base_color`, `alpha = roughness²`, `ior = eta`
   (skin method: `subsurface_ior`), `anisotropy` (clamped ±0.99 in
   `bssrdf_setup`; skin ±0.9), ior clamped `[1.01, 3.8]`. If
   `thin_wall`, `bsdf_thin_subsurface_setup` is used instead (below).
2. **Small-radius fallback** (`bssrdf_setup`): any channel with radius
   `< BSSRDF_MIN_RADIUS = 1e-8` has its weight moved to a plain diffuse
   closure; if all three, no BSSRDF at all.
3. **Entry** (`subsurface_entry_bounce`): sample a GGX VNDF microfacet
   normal at `alpha`, refract `wi` through it at `1/ior`, take the direction
   without a BSDF/pdf factor ("we only really care about the directional
   distribution"). Skin method: 50% chance of a cosine-weighted direction
   into the surface instead, and `alpha = 1`. If the sampled direction is not
   below the geometric surface (`dot(Ng, wo) >= 0`) the bounce fails
   (`LABEL_NONE`, path ends).
4. **Coefficients** (`subsurface_random_walk_coefficients`, van de Hulst):
   `s² = (4.20863·c − sqrt(9.59217 + 41.6808·c + 17.7126·c²) + 4.09712)²`,
   `alpha = (1 − s²) / (1 − g·s²)` clamped `[0, 0.999999]`,
   `sigma_t = 1 / max(radius, 1e-16)`, `throughput /= albedo` (the walk's
   scattering re-adds it), and channels with `alpha < 0.2` are raised to 0.2
   with the throughput scaled by `alpha / 0.2`.
5. **Walk** (`subsurface_random_walk`), up to `BSSRDF_MAX_BOUNCES = 256`:
   per step, MIS-choose a colour channel by `alpha × throughput`
   (`volume_sample_channel`), sample `t = −ln(1 − u) / sigma_t[channel]`
   (stretched by the Dwivedi factor when guided), intersect against the
   **object's own geometry only** (`scene_intersect_local`, `ray.self.prim`
   excluded on step 0), accumulate `throughput *= (hit ? T : sigma_s·T) /
   dot(channel_pdf, pdf)` where `pdf` is the MIS mix of classic and guided
   (forward/backward) distance pdfs, break on a hit or when
   `max(throughput) < VOLUME_THROUGHPUT_EPSILON`. Step 0 additionally probes
   up to `10 / min(sigma_t)` to find an opposite interface for backward
   guiding. Guided fraction `1 − max(0.5, |g|^0.125)`; diffusion length
   `1 / sqrt(1 − alpha^(2.44294 − 0.0215813·alpha + 0.578637/alpha))` on the
   max channel; the walk returns false (path ends) if that length is exactly 1.
   After `SUBSURFACE_RANDOM_WALK_SIMILARITY_LEVEL = 9` steps the phase becomes
   isotropic with `sigma_s* = sigma_s(1 − g)`.
6. **Exit** (`subsurface_scatter`): the ray is re-aimed from beyond the exit
   point back toward it (`P += D·tmax·2; D = −D`) and the exit surface is
   shaded as a **pure diffuse closure of weight 1** with the bump-mapped normal
   (`subsurface_shader_data_setup`); NEE and the next bounce proceed normally.
   A second SSS can occur at a later diffuse hit (only the Burley method
   converts after a diffuse ancestor).
7. **Thin wall** (`bsdf_thin_subsurface_setup`, OpenPBR): the SSS weight
   splits into a diffuse lobe `0.5·(1 − g)·w` and a translucent lobe
   (`bsdf_translucent`, normal `−N`) `0.5·(1 + g)·w` (Oren-Nayar variants when
   diffuse roughness > 0; ours has no diffuse roughness, so Lambertian).

## Design

### Material inputs — existing Godot properties, no new ones

`BaseMaterial3D` already carries subsurface properties for the raster path;
the RT upload (`render_raytracing.cpp` `process_material`, which reads
parameters by shader-uniform name via `material_get_param`) maps them:

| Godot uniform | RT field | Cycles meaning |
|---|---|---|
| `subsurface_scattering_strength` (0 when the feature is off / uniform absent) | `sss_weight` | Subsurface Weight |
| `transmittance_color` (default when absent: `(1, 0.2, 0.1)`, Cycles' default radius) | `sss_radius[3]` | Subsurface Radius |
| `transmittance_depth` (default when absent: `0.05`) | `sss_scale` | Subsurface Scale, metres; **`<= 0` selects thin-wall mode** |
| `ior` (already uploaded) | — | subsurface IOR, clamped `[1.01, 3.8]` at use |

Anisotropy is fixed at 0 (Cycles' default). The pipeline is the only author
of these values, so a "depth 0 = thin sheet" convention is documented at the
pipeline table and at the upload site.

### Material struct (C++ and GLSL, both sides)

`RT_MaterialData` grows 192 → 208 bytes: `float sss_radius[3]; float
sss_weight;` at offset 192 (a 16-aligned vec3 row), `sss_scale` takes the
existing `_pad0` at 188. New flag: `RT_MAT_FLAG_SSS_THIN = 32u` (thin-wall
decided at upload from `sss_scale <= 0`, so the shader tests one bit). `static_assert`s on size and on the new
offsets; the GLSL `MaterialData` mirror and `raytracing_data_inc.glsl`
defines updated in the same commit; `tests/servers/rendering/
test_pt_material_data.cpp` (the layout mirror) extended.

### Per-scene feature gate

`RT_FLAG_SSS_ENABLED` (next free bit in `SceneShaderRaytracing`), set by
`process_material` when `sss_weight > CLOSURE_WEIGHT_CUTOFF`, OR'd into the
scene mask like anisotropy/coat/sheen (roadmap §7.13), injecting
`#define RT_SSS_ENABLED`. Scenes without an SSS material compile without any
of this and stay byte-identical.

### Lobe registry

`LOBE_SUBSURFACE` is a fifth registry index, present only under
`RT_SSS_ENABLED`. Weights in the selection block
(`raytracing_closest_hit_common_inc.glsl:~2005`):

```
diffuseShare              = baseShare * (1 - pSpec)
weights[LOBE_DIFFUSE]     = diffuseShare * (1 - w)
weights[LOBE_SUBSURFACE]  = diffuseShare * w
```

with `w = sss_weight` after the small-radius fallback (a channel with
`radius < 1e-8` is treated as diffuse for that channel; if all three, `w = 0`
for selection and the material is plain diffuse — Cycles' rule 2). NEE at the
entry point weights its diffuse term by `(1 − w)` — the SSS share is lit at
the exit, never at the entry (Cycles: the bssrdf closure has no `eval`).

`layerTransmittanceAbove` treats `LOBE_SUBSURFACE` exactly as
`LOBE_DIFFUSE` (same layer depth: it is the diffuse share).

### Random walk — thin-wall branch

If `RT_MAT_FLAG_SSS_THIN`: the subsurface lobe is itself split by one draw:
with probability `0.5·(1 − g) = 0.5` a cosine sample about `+N` (diffuse,
weight `baseColor`), else a cosine sample about `−N` (translucent, weight
`baseColor`), throughput divided by the selection probability; the next ray
restarts on the far side for the translucent case (offset along `−N`,
`INSIDE_MEDIUM` untouched, transmission counter incremented so the B3 cap
holds). NEE at a thin-wall hit lights both the front diffuse share and — for
lights on the far side — the translucent share, evaluated as a Lambertian
about `−N` (Cycles' `bsdf_translucent_eval`).

### Random walk — solid branch

Runs inline in the hit shader when `LOBE_SUBSURFACE` is selected and the
material is not thin-wall:

1. **Entry direction** as Cycles' `subsurface_entry_bounce`, using the
   existing `sampleGGXVNDF` at `alpha = roughness²` (skin: `alpha = 1`, and a
   50% cosine-into-surface branch), refracted at `1/ior`. Fails → path
   terminated (Cycles `LABEL_NONE`).
2. **Throughput** `*= baseColor·w·layering / weights[LOBE_SUBSURFACE]`, then
   `/= baseColor` per the coefficients step, and the `alpha < 0.2`
   compensation applied.
3. **Walk** as Cycles' loop, transcribed: channel MIS, Dwivedi guided
   sampling with forward/backward MIS, similarity level 9, 256-step cap,
   `VOLUME_THROUGHPUT_EPSILON = 1e-6` exit. Randomness comes from a
   walk-local PCG stream seeded from the path's RNG state (Cycles scrambles
   with `0xdeadbeef` for the same reason); the path's own Sobol dimensions
   are untouched.
4. **Self-only intersection**: a `rayQueryEXT` with
   `gl_RayFlagsNoOpaqueEXT` (every triangle a candidate), committing only
   candidates whose `rayQueryGetIntersectionInstanceIdEXT` equals the current
   `gl_InstanceID`; step 0 also skips the entry triangle
   (`gl_PrimitiveID`), mirroring `ray.self.prim`. Mask `0xFF`.
5. **Exit**: on a hit, the exit point `X`, walk direction `D` and the exit
   triangle's interpolated shading normal are known. The payload is set so
   the next ray starts at `X + D·δ` with direction `−D` (`δ = 2 mm`, above
   the 1 mm `t_min`; Gap #26's exact-restart path is not used here), with
   `SSS_EXIT_FLAG = (1u << 27)` set and the diffuse bounce counter
   incremented. The hit shader, seeing that flag on its next invocation,
   shades the hit as a **diffuse-only closure of weight 1** with the
   material's bump-mapped normal (no specular, coat, sheen, transmission or
   subsurface at that hit; NEE runs normally), clears the flag, and continues
   the path with a cosine sample. No hit / throughput underflow /
   `diffusion_length == 1` → path terminated (Cycles returns false).

### DLSS-RR / OIDN guides

Unchanged: the primary-hit albedo of an SSS material is its base colour,
which is what the guides already receive.

### Pipeline rule (`pipeline_references/image_glb_creation.gd`, user's file)

A keyword table, keyed on the **material** name only, applied after the
existing glass/water classification (a material that matched glass or water
is never SSS):

| keyword | mode | strength | transmittance_color (radius) | transmittance_depth (scale, m) |
|---|---|---|---|---|
| `marble` | random walk | 1.0 | (1.0, 0.95, 0.9) | 0.03 |
| `candle`, `wax` | random walk | 1.0 | (1.0, 0.8, 0.6) | 0.05 |
| `shade`, `lampshade`, `paper` | thin-wall | 0.7 | (1, 1, 1) | 0.0 |
| `leaf` | thin-wall | 0.3 | (1, 1, 1) | 0.0 |

Applied by setting `subsurf_scatter_enabled = true`, `subsurf_scatter_strength`,
`subsurf_scatter_transmittance_enabled = true`, `transmittance_color`,
`transmittance_depth` on the surface override material. Presets are
starting points and are documented as such at the table. Skin mode is not
assigned by rule (no skin materials in the library).

Ambiguity rule: keywords are matched as substrings of the lower-cased
material name, after `GLB_KEEP_ALPHA_KEYWORDS`, water and glass have had
their turn; the first matching row wins, in table order.

## Gates

`pipeline_references/tests/pt_subsurface_gate.gd` + `_scene.tscn`, on the
`pt_validation.gd` harness, plus `tools/cycles_comparison/cycles_sss_sphere.py`
(Blender 5.2.1, 2048 samples, 12 bounces) whose readings are pasted into the
gate as `CYCLES_REF`.

| probe | fixture | expected |
|---|---|---|
| S1 energy | white (albedo 1) SSS sphere, radius (1,1,1)×0.05, weight 1, under a uniform sky, 12 bounces, 256 frames | crop mean ≤ 1.0 and within 2% of the same sphere rendered plain diffuse (a lossless walk conserves energy) |
| S2 Cycles | sphere albedo 0.8, radius (1, 0.2, 0.1)×0.05, weight 1, ior 1.4, same framing as `cycles_glass_furnace.py` | within 5% of `CYCLES_REF` per channel |
| S3 thin-wall | a thin-wall sheet (weight 1) between the camera and an emissive backdrop, camera side black | reads `0.5 × albedo × backdrop` within 2% (the translucent share) |
| S4 fallback | S2's material with radius 0 | equals the plain diffuse reference to 0.5% |

S1, S2 and S3 are red before the feature exists (an SSS material renders
as plain diffuse today, which reads ≈ 1.0 on S1 — so S1 alone would pass;
S2/S3 carry the falsifiability). S4 holds the fallback rule.

Whole-suite: every other gate unchanged with no re-baselining; doctest
green (the material-layout mirror test extended). Assets: job 217 at FHD
**unchanged** with the pipeline rule off (feature gate proves isolation);
with it on, the marble table and the candles measurably change and are
inspected by eye against the Blender render of the same scene.

## Not in scope

- Skin mode (Cycles `RANDOM_WALK_SKIN`): Godot's `sss_mode_skin` is a shader
  `render_mode`, not a uniform, so `process_material` cannot read it;
  deferred with probe S5. No library material needs it. (Task 1, 2026-09-15.)
- Debug modes 41/42 follow the precedent of modes 36–40: shader-side only,
  set by integer from the gates, no `PathtracingDebugMode` enum entry.

- Subsurface anisotropy as a material input (fixed 0).
- Path-guiding records, light passes, volume-stack interaction.
- Christensen-Burley (disk) method — Cycles' legacy path; not ported.
- `coat_normal` / bump on the SSS entry normal beyond what the base normal
  map already gives.

## Delivery

Engine files under `servers/rendering/renderer_rd/` and the C++ mirror test;
the gate under `pipeline_references/tests/`; the Cycles script under
`tools/cycles_comparison/`; a roadmap row for Gap #13 marked complete with a
§11.23 write-up. The pipeline rule goes to `pipeline_references/
image_glb_creation.gd`, left uncommitted for the user to carry over.
Commits with explicit `git add` paths.
