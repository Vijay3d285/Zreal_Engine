# RTX Path Tracer — Quality Gap Analysis & Roadmap to Blender-Cycles Parity

**Scope:** Code-level diagnosis of why this Godot 4.7 fork's path-traced output does not match Blender Cycles, with a prioritized, code-anchored roadmap.

**Engine branch:** `vijay_PTEngine_v8_Quality`
**Reference:** Blender Cycles at `C:\Users\aiadmin\Desktop\blender_build\blender\intern\cycles`

Every "Cycles does X" claim below is anchored to a real file:line in that tree. Every "we do Y" claim is anchored to this branch. **This document was re-verified against both source trees; it supersedes the earlier `vijay_pt2_shadows`-era revision, which described several already-solved problems as open.**

**North star:** offline-first. Converged, reference-grade stills are the primary bar; the realtime DLSS-RR path stays working but is secondary.

---

## 0. Status reconciliation — what already landed

The previous roadmap revision listed these as open. They are implemented on this branch. Do not re-plan them.

| Item | Status | Evidence |
|------|--------|----------|
| **Accumulation buffer / offline convergence** | ✅ Landed | `rt_accum` + `rt_accum_n` running average, `scene_raytracing_raygen.glsl:110-140`; `RT_PARAM_ACCUM_FLAG/FRAMES/TARGET`, `scene_shader_raytracing.h:99-102`; `Environment::set_pathtracing_accumulate` / `set_pathtracing_accumulation_target`, `environment.cpp:653-668` |
| **OIDN denoiser fallback** | ✅ Landed | `modules/raycaster_oidn/` (in-process), driven as the accumulate→denoise final pass in `render.gd` |
| **DLSS-RR realtime-still path** | ✅ Landed | `render.gd:350-440`; correctly feeds DLSS-RR *per-frame noisy* samples rather than a converged image |
| **Rect / area analytic light** | ✅ Landed | `RT_LIGHT_TYPE_RECT` + `lights_eval_rect_light`, `raytracing_lights_inc.glsl:257-325` (correct area→solid-angle pdf conversion) |
| **IES photometric profiles** | ✅ Landed | `ies_lookup_inc.glsl`, `core/io/ies_file.cpp`, `ies_manager.cpp`; applied at `raytracing_lights_inc.glsl:447-451` |
| **Below-hemisphere recovery gating** | ✅ Landed | now behind `RT_BELOW_HEMISPHERE_RECOVERY_ENABLED`, with debug vis mode 22 |

**Consequence for planning:** the bottleneck has moved. Convergence machinery exists; what it converges *toward* is still biased and under-sampled. The remaining gaps are integrator correctness, sampling quality, light/material data richness — not buffer plumbing.

---

## 1. The headline finding

> **Accumulation shipped without camera jitter. The primary ray is identical on every accumulated sample.**

`scene_raytracing_raygen.glsl:89`

```glsl
const vec2 pixel_center = vec2(pixel) + vec2(0.5);   // never jittered
```

`trace_one_sample()` is called once per accumulation frame with `origin.xyz, direction.xyz` computed **outside** the loop from that fixed pixel center. So accumulating 1000 frames averages 1000 samples that all enter the scene through the exact same point in the exact same direction.

What that costs:
- **Zero anti-aliasing gain from accumulation.** Geometric edges stay hard-aliased no matter how long you render. This is the most visible "not Cycles" tell in a still.
- Accumulation only reduces *shading* noise (RNG diverges after the first hit), not *geometric* noise.
- No sub-pixel information for DLSS-RR to reconstruct from.

Cycles jitters the filter dimension on every sample except sample 0, which it centers deliberately (`init_from_camera.h:28-29`):

```cpp
const float2 rand_filter = (sample == 0) ? make_float2(0.5f, 0.5f)
                                         : path_rng_2D(kg, rng_pixel, sample, PRNG_FILTER);
```

This is a ~20-line fix against machinery that is already built and already running. It is the highest value-per-line change on this document.

---

## 2. Gap table (re-verified)

Ranked by impact on offline still quality.

| # | Gap | Our code | Cycles reference | Severity |
|---|-----|----------|------------------|----------|
| 0 | **Accumulator stored at fp16** — running average stalls; shader declares `rgba32f` but the texture is `R16G16B16A16_SFLOAT` | `render_forward_clustered.cpp:131` vs `raygen.glsl:31` | Cycles accumulates to fp32 | **Critical** |
| 1 | **No camera jitter / reconstruction filter** — accumulation cannot anti-alias | `raygen.glsl:89` | `init_from_camera.h:28-29` (`PRNG_FILTER`) | **Critical** |
| 2 | **No MIS** between NEE and BSDF sampling | `closest_hit_common:531,561` | `mis.h:26`, `light/sample.h:344,469` | **Critical** |
| 3 | **No HDR/EXR output** — accumulator holds linear radiance, capture is 8-bit PNG | `render.gd:428,561` | Cycles writes 32-bit linear EXR | High |
| 4 | **`MAX_DIFFUSE_BOUNCES` hardcoded to 2** | `raytracing_inc.glsl:136` | `data_template.h:181` (`max_diffuse_bounce`, user-set) | High |
| 5 | **Emissive geometry is never sampled as a light** | `closest_hit_common:458` | `light/triangle.h`, `triangle_light_pdf` | High |
| 6 | **White-noise PCG; no Sobol / Owen / blue noise** | `raytracing_inc.glsl:153-175` | `sample/pattern.h`, `sobol_burley.h` | High |
| 7 | **Uniform light selection** — reservoir ignores power & distance | `lights_inc.glsl:350-377` | `light/tree.h:304` (energy-weighted importance) | High |
| 8 | **No Russian Roulette** | absent | `path_state.h:277-305` | Medium |
| 9 | **No adaptive sampling / noise threshold** | absent | `film/adaptive_sampling.h:29` | Medium |
| 10 | **No firefly clamp** | absent | `data_template.h:202-203` (`sample_clamp_direct/indirect`) | Medium |
| 11 | **Sky/IBL sampled uniformly** — no env importance sampling | `raygen.glsl:232` | `light/background.h:29,118` (marginal/conditional CDF) | Medium |
| 12 | **glTF PBR extensions dropped at import** | only `_pbr`, `_unlit`, `_emissive_strength` | Cycles Principled BSDF carries all | High (blocks #13) |
| 13 | **Missing BSDFs** — transmission hardcoded off, no SSS/aniso/clearcoat/sheen | `closest_hit_common:474-475` | `subsurface_random_walk.h`, Principled | Medium |
| 14 | **fp16 radiance/throughput payload** | `raytracing_inc.glsl:75-87` | fp32 throughout | Medium |
| 15 | **Biased bump-map mirror recovery** | `brdf_inc.glsl:998-1009` | offset/position normals, no bias | Low-Med |
| 16 | **No volumetrics** | absent | `integrator/shade_volume.h` | Low |

**Not gaps — verified correct, leave alone:**
- BRDF library (VNDF GGX, height-correlated Smith G2, multi-scatter compensation) — Cycles-class.
- `alpha = roughness²` (`brdf_inc.glsl:1046`) — matches Cycles/glTF convention exactly.
- Rect-light area→solid-angle pdf conversion (`lights_inc.glsl:294-297`) — correct.
- Wächter-Binder ray-origin offset (`raytracing_inc.glsl:182-197`) — correct.
- TLAS/BLAS build, SER reorder, motion vectors, DLSS-RR G-buffers, AgX/ACES/Filmic tone operators.

---

## 3. Detailed analysis

### 3.1 [CRITICAL] MIS is entirely absent

Cycles runs a **two-sided** MIS scheme. Both sides are missing here.

**Side A — NEE sample weighted against the BSDF pdf** (`shade_surface.h:414`):
```cpp
const float mis_weight = light_sample_mis_weight_nee(kg, ls.pdf, bsdf_pdf);
bsdf_eval_mul(&bsdf_eval, light_shader_eval * ls.eval_fac / ls.pdf * mis_weight);
```

**Side B — BSDF ray that lands on emissive geometry, weighted against the light pdf** (`shade_surface.h:150`):
```cpp
const float mis_weight = light_sample_mis_weight_forward_surface(kg, state, path_visibility, path_flag, sd);
```
which reads the pdf stashed from the previous bounce (`light/sample.h:488`):
```cpp
const float bsdf_pdf = INTEGRATOR_STATE(state, path, mis_ray_pdf);
float pdf = triangle_light_pdf(kg, sd, t);
```

Both reduce to `power_heuristic(a,b) = a²/(a²+b²)` (`mis.h:26`).

Ours: `lights_evaluate_direct_lighting` divides only by `light_select_pdf` (`lights_inc.glsl:455`) with no BSDF-pdf term, and the BSDF bounce at `closest_hit_common:561-578` multiplies throughput by `brdf_weight` with no complementary weight. Emissive surfaces hit by a BSDF ray add `throughput * m.emissive` **unweighted** (`:458`).

Because we don't yet sample emissive meshes via NEE, the two estimators don't currently double-count *mesh* emission — but they will the moment Gap #5 lands, and analytic lights already suffer the variance MIS exists to kill. **MIS must land before or with emissive-mesh sampling**, never after.

Implementation requires a `mis_ray_pdf` field on the payload. The payload is a tight 32 bytes (`raytracing_inc.glsl:40-47`) and full — this is the structural reason to schedule the payload widening (Gap #14) in the same phase.

### 3.2 [HIGH] Bounce controls are a single hardcoded constant

`raytracing_inc.glsl:136` → `#define MAX_DIFFUSE_BOUNCES 2u`, enforced at `closest_hit_common:461`.

Cycles exposes six independent user-controlled caps (`data_template.h:179-184`): `min_bounce`, `max_bounce`, `max_diffuse_bounce`, `max_glossy_bounce`, `max_transmission_bounce`, `max_volume_bounce`. `min_bounce` additionally guarantees RR does not fire early.

Interior daylight needs ≥3–4 diffuse hops for color bleeding and corner fill. Capped at 2, `set_pathtracing_max_bounces(12)` is misleading: GI dies at hop 2 regardless. Note the bounce counters are already packed per-type (`:89-104`), so the data model supports this — only the constant and the plumbing are missing.

### 3.3 [HIGH] Sampling is white noise

`raytracing_inc.glsl:160-164`:
```glsl
uint seed = pixel.x + pixel.y * 65536u + frame * 1000000u + sample_idx * 100000000u;
return pcg_hash(seed);
```
Then `rand()`/`rand2()` draw sequentially — no dimension tracking, no stratification, no scrambling.

Cycles offers Tabulated Sobol, Sobol-Burley, and two blue-noise modes (`pattern.h:38-61`), with **dimension-indexed** draws (`path_rng_2D(..., dimension)`) so each decision gets its own well-stratified dimension, and Owen-scrambled per-pixel offsets via `nested_uniform_scramble_base4(morton2d(x, y), seed)` (`pattern.h:156`).

Cycles' own guidance (`pattern.h:20-32`) — earlier dimensions are better stratified, so assign them to what matters most (filter, lens, first-bounce BSDF, light selection).

At equal sample count, white noise produces clumpy splotches; Sobol/blue-noise produces fine even grain that denoises far more cleanly. This is the largest *perceptual* gap per unit of sample budget.

### 3.4 [HIGH] Light selection ignores light power

`lights_inc.glsl:350-377` picks `k=16` candidates **uniformly at random**, keeps one by reservoir, and estimates `light_select_pdf` from the valid-count ratio. Selection probability is unrelated to a light's contribution.

Cycles builds an importance-weighted light tree (`light/tree.h:304` `light_tree_node_importance`, weighting by `energy` × angular/distance bounds, `tree.h:215,452`) with a flat power-based distribution as fallback.

In a scene with one 10000W key and forty 5W fills, we spend ~97.5% of shadow rays on lights contributing almost nothing. This scales badly precisely in the archviz scenes this engine targets.

### 3.5 [MEDIUM] No Russian Roulette, no clamp, no adaptive sampling

Three independent efficiency mechanisms, all absent.

- **RR** (`path_state.h:296-305`): `min(sqrtf(reduce_max(fabs(throughput))), 1.0f)`, applied only after `min_bounce`. *Note the `sqrt`* — Cycles deliberately terminates later than naive luminance-based RR to better match the view transform. The earlier revision of this document specified `clamp(luminance, 0.05, 0.95)`; that was wrong. Match the reference.
- **Clamping** (`data_template.h:202-203`): separate `sample_clamp_direct` / `sample_clamp_indirect`. Without indirect clamp, a single unlucky specular-caustic path leaves a permanent white pixel that the running average never washes out — fireflies are *more* damaging with accumulation than without it, because they persist.
- **Adaptive sampling** (`adaptive_sampling.h:29`): per-pixel convergence check against a noise threshold, plus a two-pass box filter (`filter_x`/`filter_y`) so converged pixels near noisy ones keep sampling. Cycles stops sampling converged pixels entirely and spends the budget where variance remains.

### 3.6 [HIGH] glTF material extensions are dropped at import

Verified — the importer supports exactly three material extensions:
```
KHR_materials_emissive_strength, KHR_materials_pbr, KHR_materials_unlit
```

Absent: `KHR_materials_transmission`, `_volume`, `_ior`, `_clearcoat`, `_sheen`, `_specular`, `_anisotropy`, `_iridescence`.

And the GPU-side struct has nowhere to put them anyway (`raytracing_data_inc.glsl:87-105`) — `MaterialData` carries albedo/normal/orm/emission indices, metallic, roughness, ao, specular, uv1 scale/offset, normal depth. No transmission, IOR, clearcoat, sheen, or anisotropy fields.

**This is why the material phase must precede the BSDF phase.** A physically perfect rough-glass BSDF is untestable while `KHR_materials_transmission` is discarded at import and has no slot in the struct. Any GLB authored in Blender with a glass or car-paint Principled setup arrives at our path tracer as opaque diffuse — the data is gone before the shader ever runs.

### 3.7 [MEDIUM] Payload precision and MIS state

`path_pack` clamps to `FP16_MAX = 65504` (`raytracing_inc.glsl:76-78`). Throughput multiplied across many bounces accumulates fp16 rounding; bright direct hits clamp and lose energy. Cycles is fp32 end-to-end.

The payload is exactly 32 bytes and fully packed. MIS needs a `mis_ray_pdf` float. Both changes touch the same struct → do them together, once, and re-measure occupancy.

---

## 4. Roadmap

Phases are ordered so each one de-risks the next. **A → B → C → D → E → F.**

### Phase A — Finish the offline still path *(highest ROI; ~1 week)*

Accumulation exists but is half-wired. Close it out.
**Detailed task-by-task plan: [`docs/superpowers/plans/2026-08-06-phase-a-offline-still-path.md`](docs/superpowers/plans/2026-08-06-phase-a-offline-still-path.md)**

**A0. fp32 accumulator** — *Gap #0*
`RB_TEX_RAYTRACING_ACCUM` is allocated `R16G16B16A16_SFLOAT` while the raygen shader declares `rgba32f`. Beyond the format mismatch, fp16's relative epsilon near 1.0 (~9.8e-4) exceeds the `1/(n+1)` blend weight past a few hundred samples, so the increment rounds away and **the image stops converging** long before the configured target — which can be set as high as 8192. Also fixes highlight clipping at 65504. Update the OIDN readback (`render_forward_clustered.cpp:1962,2002-2012,2060-2074`) for the 16-byte stride.
*Accept:* RMSE against a high-sample reference keeps falling from 256→1024 frames instead of flattening.

**A1. Camera jitter + reconstruction filter** — *Gap #1*
Jitter `pixel_center` per accumulated sample; keep sample 0 centered (Cycles convention, `init_from_camera.h:28`). Move ray setup **inside** `trace_one_sample` so each sample gets its own primary ray. Start with a box filter; add Blackman-Harris/Gaussian reconstruction after A3. Feed unjittered VPs to the DLSS-RR motion path — `curr_vp_unjittered` plumbing already exists at `render_raytracing.cpp:3012-3022`.
*Accept:* a 45° edge at 256 accumulated frames shows smooth gradation, not stairsteps. Diff against the current build to prove the change is doing the work.

**A2. HDR / EXR output** — *Gap #3*
`RB_TEX_RAYTRACING_ACCUM` already holds scene-linear radiance. Read it back and `Image.save_exr()` alongside the tonemapped PNG.
*Accept:* EXR opens in Blender's compositor with highlights above 1.0 intact and recoverable.

**A3. Firefly clamp** — *Gap #10*
`pathtracing_clamp_direct` / `pathtracing_clamp_indirect` in the params block. **Free `PT_PARAM` slots are 9-13 only** — 0-8 are taken (`VIS_MODE, SAMPLE_COUNT, MAX_BOUNCES, DENOISER, ACCUM_FLAG, ACCUM_FRAMES, OIDN_FLAG, ACCUM_TARGET, DLSS_RR_FINAL_FLAG`), 14-15 are `LIGHT_COUNT`/`FRAME_INDEX`. Clamp contributions by bounce depth at the shading site.
*Accept:* a small bright specular caustic no longer leaves permanent white pixels at 500 frames.

**A4. Adaptive sampling + noise threshold** — *Gap #9*
Per-pixel variance in the spare `rt_accum_n` channels; stop sampling converged pixels; box-filter the convergence mask so noisy neighbors keep their neighbors alive (`adaptive_sampling.h:95-138`).
*Accept:* an interior scene reaches a target noise floor in measurably fewer total samples, with no visible convergence-boundary seams.

### Phase B — Integrator correctness *(~2 weeks)*

**B1. Widen the payload: fp32 + `mis_ray_pdf`** — *Gaps #14, prerequisite for B2*
One struct change: fp32 radiance/throughput plus a `mis_ray_pdf` float. Profile RT-core occupancy; if it regresses badly, keep radiance fp16 but carry throughput and pdf at fp32.
*Accept:* a sun-at-1000× test no longer bands in specular tails; frame time regression stays within budget.

**B2. Multiple Importance Sampling** — *Gap #2*
Both sides, power heuristic, mirroring `light/sample.h:344` and `:469`. Weight the NEE estimate by `power_heuristic(light_pdf, bsdf_pdf)`; store the BSDF pdf on the payload and weight emissive hits by `power_heuristic(bsdf_pdf, light_pdf)`.
*Accept:* a small bright area light reflected in a glossy floor — specular highlight variance drops sharply, no over-bright ring near the light. Compare to a Cycles EXR of the same setup.

**B3. Per-type bounce controls** — *Gap #4*
Replace the `MAX_DIFFUSE_BOUNCES` constant with params-block slots. Expose `min_bounce`, `max_diffuse_bounce`, `max_glossy_bounce`, `max_transmission_bounce` on `Environment` following the existing `set_pathtracing_max_bounces` pattern. Default diffuse ≥4.
*Accept:* sun→floor→wall→ceiling color bleeding is visible; diffuse cap at 2 vs 4 produces a clearly different, warmer interior.

**B4. Russian Roulette** — *Gap #8*
After the throughput update at `closest_hit_common:578`, once `total_bounces > min_bounce`: `p = min(sqrt(max_component(throughput)), 1.0)`; terminate on `rand() > p`, else `throughput /= p`. Match the `sqrt` — see §3.5.
*Accept:* render time per frame drops in deep-bounce scenes with no measurable bias (mean of 2000 accumulated frames matches the pre-RR mean within noise).

**B5. Owen-scrambled Sobol / blue-noise sampler** — *Gap #6*
Replace bare PCG with a dimension-indexed Sobol-Burley sampler; per-pixel Owen scramble seeded via `nested_uniform_scramble_base4(morton2d(x,y), seed)`. Thread an explicit `dimension` through `rand()`/`rand2()` call sites and assign the earliest dimensions to filter, then first-bounce BSDF, then light selection (`pattern.h:20-32`).
*Accept:* at 16 spp the residual error is fine even grain, not clumps; OIDN output at 1/4 the sample count matches today's quality.

### Phase C — Light & environment fidelity *(~2 weeks)*

**C1. Emissive-mesh light sampling** — *Gap #5*
Build an emissive-triangle buffer alongside `gather_lights` in `render_raytracing.cpp` (area, emission, power). Sample by power, MIS-combine against the BSDF (B2 must be in first). Reuse the existing TLAS for shadow rays.
*Accept:* a room lit only by a glowing panel converges clean; no hotspot speckle; matches a Cycles reference of the same scene.

**C2. Power-weighted light selection** — *Gap #7*
Replace uniform reservoir candidate selection with importance proportional to `energy / distance²` × angular falloff, following `light_tree_node_importance` (`tree.h:304`). A flat power-weighted CDF captures most of the benefit; the full tree is optional.
*Accept:* one bright key among 40 dim fills converges at several× the current rate.

**C3. Environment importance sampling** — *Gap #11*
Build marginal + conditional CDFs over the sky octmap on environment update (`background.h:29` `background_map_sample`, `:118` `background_map_pdf`). Sample the env for NEE; MIS against the BSDF sky bounce.
*Accept:* a sunset-HDRI window reflection converges at ≥2× the uniform-sampling rate.

### Phase D — Material data pipeline *(NEW, first-class; ~2 weeks)*

**Nothing in Phase E is testable until this lands.** See §3.6.

**D1. glTF extension import** — *Gap #12*
Add `KHR_materials_transmission`, `_ior`, `_volume`, `_specular`, `_clearcoat`, `_sheen`, `_anisotropy` to `modules/gltf/`.

**D2. Material representation**
Extend `StandardMaterial3D` (or introduce a `PrincipledMaterial3D`) to carry the new parameters, so imported data survives into the scene tree and the Inspector.

**D3. Widen RT `MaterialData`**
Add transmission, IOR, clearcoat (+roughness), sheen (+tint), anisotropy (+rotation) to `raytracing_data_inc.glsl:87-105` and its C++ twin. **Respect the std430 / `static_assert(sizeof == N)` / `alignas(16)` parity rules** — the struct has a verbatim GLSL counterpart and both must agree byte-for-byte.

*Accept:* a Blender-authored GLB with glass, car paint, and fabric round-trips with every parameter intact and inspectable, *before* any new BSDF math exists to consume it.

### Phase E — BSDF completeness *(~3 weeks, parallelizable after D)*

**E1. Transmission / rough glass** — *Gap #13*
GGX refraction sampling; remove the `transmissivness = 0.0` hardcode (`closest_hit_common:474`). Handle front/back faces, IOR sides, total internal reflection. Wire `max_transmission_bounce` from B3.
*Accept:* a glass vase refracts correctly; rough glass blurs plausibly; retire the "glass vanishing" workaround.

**E2. Anisotropy, clearcoat, sheen**
`sampleGGXVNDF` already takes `alpha2D` and callers pass `(alpha, alpha)` (`brdf_inc.glsl:837`) — thread real anisotropy through instead. Add a clearcoat GGX lobe and a Charlie/sheen lobe.
*Accept:* brushed metal, car paint, and velvet respond comparably to Cycles.

**E3. Subsurface scattering**
Random-walk BSSRDF following `subsurface_random_walk.h`.
*Accept:* skin and wax read correctly under existing NEE.

### Phase F — Precision & robustness *(rolling)*

**F1. Offset normals replacing the biased bump mirror** — *Gap #15*
Remove `recoverBelowHemisphereSample` (`brdf_inc.glsl:998-1009`); its own comment concedes it is energy-non-conserving. Keep debug vis mode 22 for comparison.
*Accept:* grazing angles on a high-frequency normal-mapped surface stay energy-flat; no over-bright, no speckle.

**F2. Volumetrics** — *Gap #16*
Homogeneous fog/god-rays via a volume integrator (`shade_volume.h`), with `max_volume_bounce` from B3.

---

## 5. Validation harness

Build this **during Phase A**, not later — every subsequent acceptance test depends on it.

Fixed scene set: Cornell box, area-light-on-glossy-floor, glass vase, interior daylight room, emissive-panel-only room, sunset-HDRI window.

For each: a Cycles reference EXR at matched exposure, camera, and light units. Compare our EXR per phase via MSE + SSIM (and FLIP if convenient). Track error-vs-sample-count curves, not just final images — most of these phases are variance-reduction work, and a curve shows that where a single frame does not.

Unit-testable pieces (`tests=yes`, doctest) worth covering: Sobol dimension stratification, power-heuristic math, light-selection pdf normalization, glTF extension round-trip.

---

## 6. Bottom line

**Phase A alone** — jitter, EXR, clamp, adaptive — converts the already-built accumulator from "converges shading noise at fixed aliasing" into a genuine offline renderer. A1 in particular is a handful of lines against machinery that already works, and it is currently the most visible defect in any still.

**Phase B** makes the converged image *correct* rather than merely stable: MIS and real bounce counts are what separate "a path tracer" from "a reference path tracer."

**Phase D before E** is deliberate and non-negotiable. Material data must survive import before BSDF math is worth writing.

Ordering summary: **A1 → A2/A3/A4 → B1/B2 → B3/B4/B5 → C → D → E → F.**
