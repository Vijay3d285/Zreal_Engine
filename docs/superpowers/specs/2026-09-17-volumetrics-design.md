# Phase F2 — Volumetrics: a bounded homogeneous medium, Cycles' way

**Date:** 2026-09-17
**Status:** for review
**Branch:** `vijay_PTEngine_v24_PhaseAs`
**Roadmap:** Phase F — F2 (Gap #16); §4 of `PATH_TRACER_QUALITY_ROADMAP.md`

## What the source says (re-read 2026-09-17, Cycles 5.3.0-alpha)

`kernel/integrator/shade_volume.h`, `volume_stack.h`, `path_state.h`,
`closure/volume_util.h`, `light/sun.h`, `light/light.h`, `blender/addon/properties.py`:

1. **Cycles' default is single scattering.** `volume_bounces` defaults to 0
   (`properties.py:779`); the kernel stores `max_volume_bounce = volume_bounces + 1`
   (`scene/integrator.cpp:227`) and after the first scatter event flags the path
   `PATH_RAY_TERMINATE_AFTER_TRANSPARENT` (`path_state.h:162-166`). A scatter point
   gets direct light — every light class, through the phase function — and the
   path ends. Multiple scattering is opt-in and off in every default Blender scene.
2. **A World volume extinguishes the sun and the sky.** Shadow rays to a sun or
   to the background have `tmax = FLT_MAX` (`sun.h:44`, `light.h:115,131`;
   `light/sample.h:275-278` copies it into the ray), and the medium's shadow
   transmittance is `exp(-σt·(tmax − tmin))` (`shade_volume.h:680`) — zero for
   any non-zero density. A ray that misses inside the world volume also gets
   `tmax = FLT_MAX` (`shade_volume.h:2937`). This is why Blender archviz never
   puts haze in the World: the haze goes in a **cube with a Volume Scatter
   shader** around the room, so a shadow ray pays only for the metres of fog
   inside the cube.
3. **The homogeneous integrator** (`volume_integrate_homogeneous`,
   `shade_volume.h:1716-1830`): transmittance `T = exp(-σt·L)` over the
   segment; scatter with probability `1 − T`, transmit otherwise; the scatter
   distance is drawn from the truncated exponential; direct light at the scatter
   point by distance sampling, or by equiangular sampling toward the chosen light
   with MIS (`volume_equiangular_sample`, `:727`; `volume_direct_scatter_mis`,
   `:1567`) — **distance sampling only for a distant light** (`:1943`, "Sample
   the scatter position with distance sampling for distant light"). Emission over
   a segment is `E·(1 − T)/σt` (`volume_emission_integrate`, `:808`).
4. **The phase function** is Henyey-Greenstein (`volume_util.h:27`):
   `p(cosθ) = (1 − g²) / (4π · (1 + g² − 2g·cosθ)^{3/2})`, isotropic `1/4π` for
   `|g| < 1e-3`, with `cosθ = dot(ray_dir, L)` (`volume_henyey_greenstein_eval`:
   `dot(-sd->wi, wo)`, `wi` pointing back at the viewer) and `g` clamped to
   `±(1 − 1e-3)`.
5. A Volume Scatter node with density `d`, colour `c`, anisotropy `g` is
   `σt = d`, `σs = d·c` (`svm/closure.h` volume branch) — the same mapping
   Godot's raster fog uses: `volumetric_fog_process.glsl:848` applies
   `exp(-density·depth)`, and scattering is `albedo × density` (`:385`).

## What we have

- `Environment.volumetric_fog_*` carries exactly the Volume Scatter inputs:
  `density` (σt per metre), `albedo` (scatter colour), `anisotropy` (g),
  `emission × emission_energy` (per metre, scaled by density in the raster). The
  pipeline already sets them for day renders (`image_glb_creation.gd:1077`:
  density 0.001, albedo 0.97, g 0.8) and **the tracer ignores them** — the
  raster froxel fog is computed every frame (`_update_volumetric_fog`) and never
  reaches the traced colour. The tracer's `apply_segment_fog`
  (`raytracing_closest_hit_common_inc.glsl:289`) is the raster's *analytic depth
  fog* (`Environment.fog_*`), a different property set; untouched here.
- `FogVolume` nodes run arbitrary fog shaders; not portable to the RT pipeline.
  The froxel-only knobs (`length`, `detail_spread`, `gi_inject`,
  `ambient_inject`, `sky_affect`, temporal) have no physical meaning and are
  ignored by the tracer.
- The raygen loop (`scene_raytracing_raygen.glsl:70-125`) traces every segment
  with `tmax = 10000.0`; the miss stage (`:266`) handles the sky and the
  BSDF-hit MIS weight; shadow rays are ray queries in
  `lights_trace_shadow_ray` (`raytracing_lights_inc.glsl:291`). The params UBO
  `vec4 rt_params[4]` (`raytracing_common_inc.glsl:114`) is full (16 of 16).

## Approaches considered

**A — a bounded homogeneous medium, Cycles' default behaviour (recommended,
chosen).** The Environment fog fills a box; every ray segment pays transmittance
for its length inside the box; a camera/bounce ray scatters or transmits by
Cycles' rule; a scatter point does NEE through the phase function and the path
ends (volume bounces 0). Faithful to what Blender users actually build.

**B — an infinite World volume, literally Cycles' World.** Rejected: finding 2
— it extinguishes the sun and the sky in every day render.

**C — `FogVolume` nodes as object volumes with a volume stack.** Cycles'
object volumes proper; roughly twice A's work; the pipeline places none.
Deferred until A's look is judged.

**The box (decided: automatic).** The union of every instance AABB the TLAS
build already walks (`RenderGeometryInstanceBase::transformed_aabb`), rebuilt
per frame with the TLAS. An interior's box is the building; rays through
windows leave the fog at the wall. A scene with a kilometre-scale mesh (a ground
plane, a sky dome) gets a kilometre-scale box, and the sun then pays
`exp(-σt·km)` — stated, not guarded; the pipeline's scenes are glTF buildings.

## Design

### 1. Free-flight sampling in raygen (engine, GLSL)

Cycles decides scatter-vs-transmit *after* the intersection, with the segment
length known. Our closest-hit shader shades on the spot, so the decision must be
made *before* the trace. The two are the same estimator for a homogeneous
grey-extinction medium, written the other way round: draw the free-flight
distance first, then bound the trace by it.

In `trace_one_sample`, before every `traceRayEXT` (both the SER and non-SER
paths), when `RT_FLAG_VOLUME_ENABLED`:

```
float t_in, t_out;                                   // slab test of the ray against the box
bool in_box = volume_box_clip(ray_origin, ray_dir, t_min, RT_RAY_TMAX, t_in, t_out);
float t_scatter = RT_RAY_TMAX;
if (in_box) {
    float u = rng_1d(rng, RT_PRNG_VOLUME);
    float t_free = t_in - log(1.0 - u) / VOLUME_SIGMA_T;   // exponential free flight from the box entry
    if (t_free < t_out) t_scatter = t_free;                // scatter inside the box; else it flies out
}
traceRayEXT(..., ray_origin, t_min, ray_dir, t_scatter, 0);
```

`RT_RAY_TMAX = 10000.0` replaces the literal at the three sites that use it
(the two traces and the miss stage's `far_world`). A hit at `t < t_scatter` is a
**transmit** event: the surface is shaded as today with throughput unchanged
(`P(t_free > t) = exp(-σt·t)` is exactly the transmittance — analog tracking).
A miss with `gl_RayTmaxEXT < RT_RAY_TMAX` is a **scatter** event at
`t_scatter`, weight `σs/σt = albedo`. A miss with `gl_RayTmaxEXT == RT_RAY_TMAX`
is the sky, as today.

**Divergence from Cycles, stated:** Cycles samples the scatter channel-wise
and re-weights; with Godot's scalar `density` the extinction is grey, so the
analog estimator's weights (`albedo` on scatter, 1 on transmit) are exact and
no channel selection exists to reproduce. Same expectation, different variance
only for chromatic albedo.

### 2. The scatter event (engine, GLSL) — new `raytracing_volume_inc.glsl`

The miss stage, on `gl_RayTmaxEXT < RT_RAY_TMAX`: writes the scatter position
and marks the payload `volume_scatter` (no sky contribution, no MIS), and for a
primary sample-zero ray writes the guides as a miss does but with the fog albedo
as the OIDN albedo and `-ray_dir` as the normal (depth stays 0: the denoisers
see haze as "far", as OIDN's own volume handling does). Raygen, on return,
calls `volume_scatter_shade(pos, ray_dir, ps)`:

- `ps.throughput *= VOLUME_ALBEDO;`
- **Analytic lights:** `lights_evaluate_direct_lighting(pos, N, V, material,
  rng, is_indirect, count)` gains one parameter, `float p_phase_g`, with a
  sentinel `RT_PHASE_NONE = -2.0` meaning "surface". In volume mode the three
  evaluation sites replace `evalCombinedBRDFSeparate` by
  `vec3(phaseHenyeyGreenstein(dot(V_ray, L), g))` (with `V_ray = ray_dir`, so
  `cosθ = dot(ray_dir, L)` as Cycles), skip every `dot(N, L)` test, and keep
  everything else — reservoir selection, cone sampling, IES, shadow rays, clamp.
  The one existing caller passes `RT_PHASE_NONE`.
- **Sky:** `env_sample` → shadow ray → `env_sky_radiance(dir) × p(cosθ) / pdf`,
  MIS weight 1 (there is no second strategy at a scatter point: the path ends).
- **Emissive meshes:** deferred (recorded). Cycles lights haze from mesh lights;
  the pipeline's beams come from the sun and lamps.
- Then `set_path_terminated` — `volume_bounces = 0`.

Raygen needs the light/geometry/material declarations and
`raytracing_lights_inc.glsl` for this (the closest-hit stage's lines 12-33 in
`scene_raytracing_raygen.glsl`); `GL_EXT_ray_query` is enabled there.
`phaseHenyeyGreenstein(cosθ, g)` is a transcription of `volume_util.h:27-34`,
with `g` clamped to `±(1 − 1e-3)` as `volume_henyey_greenstein_setup` does.

### 3. Shadow rays and segments pay transmittance (engine, GLSL)

- `lights_trace_shadow_ray(origin, dir, max_dist)`: when the volume is on,
  multiply the returned attenuation by `exp(-σt · overlap([0, max_dist], box))`
  — for surface NEE and for scatter-point NEE alike, and for the env shadow ray
  (`10000.0`). This is Cycles' `volume_shadow_*` on a bounded medium: the sun
  reaching a floor through 8 m of `density 0.001` haze pays 0.8%.
- **Emission:** after every trace, raygen adds
  `throughput × E × (1 − exp(-σt·L)) / σt` for the in-box length `L` of the
  segment up to `min(hit_t, t_scatter, t_out)` (`volume_emission_integrate`),
  with `E = emission × emission_energy × density` — the raster's own scaling
  (`volumetric_fog_process.glsl:393`). Guarded on `E != 0`; the pipeline sets 0.

### 4. Parameters (engine, C++ ↔ GLSL)

- `RaytracingParams.rt_params` grows from `vec4[4]` to `vec4[10]`
  (`float params[40]` in the C++ mirror; the two `mat4` follow, std140 keeps
  them at the same alignment). New indices: `RT_PARAM_VOLUME_SIGMA_T 16`,
  `RT_PARAM_VOLUME_G 17`, `RT_PARAM_VOLUME_ALBEDO_R/G/B 20-22`,
  `RT_PARAM_VOLUME_EMISSION_R/G/B 24-26`, `RT_PARAM_VOLUME_BOX_MIN_X/Y/Z 28-30`,
  `RT_PARAM_VOLUME_BOX_MAX_X/Y/Z 32-34`. The `static_assert(sizeof == N)`
  guard on the C++ side is updated with the new size.
- `RT_FLAG_VOLUME_ENABLED = (1 << 20)`, a specialisation constant like
  `RT_FLAG_SSS_ENABLED`, set when `environment_get_volumetric_fog_enabled(env)`
  and `density > 0`. **Compiled out otherwise**: every existing render is
  bit-identical, and the gate suite proves it.
- The box: `render_raytracing.cpp` unions `inst->transformed_aabb` over the
  instances it adds to the TLAS (all four `rt_instance_mask` sites; the
  deferred multimesh path unions the multimesh instance's AABB at gather time),
  padded by 1 cm, uploaded with the params each frame.
- `RT_PRNG_VOLUME`: one new PRNG dimension for the free-flight draw, next to
  the existing `RT_PRNG_*` list; the scatter-point NEE reuses `RT_PRNG_LIGHT`
  / `RT_PRNG_ENV` at the scatter vertex exactly as a surface vertex does.

### 5. Not changed

- The raster froxel fog keeps running (transparent raster surfaces still read
  it); it never touched the traced colour before and does not now.
- Godot's `fog_*` depth fog (`apply_segment_fog`) is untouched.
- DLSS-RR video route: the scatter event feeds it like a miss.

## Gate: `pt_volume_gate` (new; suite goes to 21)

256 × 256, 256 accumulated samples, no denoiser, no clamp, AA off. The fog box
is the scene's own bounds, so every fixture is built to *be* the box: eight
1 cm black posts at the corners of `[-1,1] × [0,2] × [-1,1]` pin the union AABB
to that 2 m cube without blocking anything; every other surface in a probe
lies on a face of that cube (the floor at y = 0, the back wall at z = -1), so
it is inside the fog in both engines. The camera sits outside, in front.
Cycles half: `tools/cycles_comparison/cycles_volume_box.py` — the same posts
and surfaces, plus a 2 m cube object with a Volume Scatter shader (density
σt, colour albedo, anisotropy g) on exactly that AABB, `volume_bounces = 0`,
volume sampling "Distance", 1024 spp.

| probe | fixture | reads | bar |
|---|---|---|---|
| **V1 absorption** | fog albedo 0, σt 0.5, a white emissive quad behind 2 m of box, black world | quad mean with fog / without | `exp(-1.0) = 0.3679 ± 1%` (analytic). **Red today**: reads 1.0. |
| **V2 emission** | albedo 0, σt 0.5, emission (1,1,1) energy 1, black world, nothing behind | crop mean | `E(1−e^{-1})/σt = 1.264 ± 1%` (analytic). Red today: 0. |
| **V3 sun beam vs Cycles** | albedo 1, σt 0.3, g 0.8, a sun straight down through the cube, black world; the floor a white Lambertian control (inside the fog, attenuated identically in both engines) | fog crop mean (upper half of the frame, haze against black) ÷ floor crop mean, per engine | within 3% of Cycles' ratio (the Gap #23 ratio-to-control method: the two engines' sun units cancel). |
| **V4 sky haze vs Cycles** | albedo 1, σt 0.3, g 0.0, uniform world 1.0, black surfaces | fog crop mean | within 3% of Cycles (world units agree, established since E2a). |
| **V5 surface shadowing** | the sun straight down, the white floor, albedo 0 fog σt 0.5 | floor mean with fog / without | `exp(-σt·2 m) = 0.3679 ± 1%` (analytic: every shadow ray climbs 2 m of box). |
| **V6 no-change control** | fog disabled | | the energy gate and the light-energy gate unchanged to the digit (flag compiled out). |

**Cost.** Frame time with the fog on and off on the opaque timing scene, and
the 226 scene with the pipeline's density 0.001 — three runs each.

## Asset check

Job 225/226's scene through the still route: the pipeline's `day` fog
(0.001, g 0.8) now reaches the traced frame for the first time. Deliver old vs
new; what to look for: soft beams where the sun enters, a faint haze gradient
with depth, no milkiness on the walls (0.001 over 6 m is 0.6%), and the
sky through the windows barely changed.

## Out of scope (recorded)

- Equiangular sampling + MIS for point/spot lights in haze (Cycles'
  `VOLUME_SAMPLE_MIS`): a variance improvement, not a bias; needed if lamp-lit
  haze proves noisy at the pipeline's sample count.
- Multiple scattering (`volume_bounces > 0`): a payload counter has no free
  bits today; Cycles' default is 0.
- Emissive-mesh NEE at scatter points.
- `FogVolume` nodes / a volume stack (approach C).
- Heterogeneous media (density textures, height falloff).
