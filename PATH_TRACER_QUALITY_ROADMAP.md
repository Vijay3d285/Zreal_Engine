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

### Phase A — Finish the offline still path — ✅ **IMPLEMENTED** *(pending GPU verification)*

**Status:** all six tasks implemented, reviewed, and merged to `vijay_PTEngine_v8_Quality` (commits `a16a38b950`..`6d6efa87ad`, 10 commits / 24 files). Unit tests green: `[PathTracer][Accumulator]` 2/2, `[PathTracer][Clamp]` 3/3, full suite 1385/1385.

**Detailed task-by-task plan: [`docs/superpowers/plans/2026-08-06-phase-a-offline-still-path.md`](docs/superpowers/plans/2026-08-06-phase-a-offline-still-path.md)**

#### ⚠️ Remaining GPU verification (must run before trusting Phase A or starting Phase B)

Only 1 of 6 exit criteria is provable from code alone; the rest need a real render. Attach `pipeline_references/tests/pt_validation.gd` to a node in a test scene and run:

| # | Check | How | Pass condition |
|---|-------|-----|----------------|
| 1 | Unit tests | `bin\godot.windows.editor.x86_64.exe --test --test-case="*PathTracer*"` | all pass *(already confirmed)* |
| 2 | **Convergence, no stall** | `convergence_curve([16,64,256,1024])` → `report_convergence(...)` | RMSE falls ~1/√N with **no flat tail** (this is what proves the fp32 fix) |
| 3 | **Anti-aliasing** | `edge_gradient_steps(img, h/2)` on a high-contrast diagonal edge at 256 frames | `>= 3` (was 0-1 before jitter) |
| 4 | **HDR EXR** | render an accumulated still; open the `.exr` in Blender | values **> 1.0** survive; highlights recoverable on exposure pull-down |
| 5 | **Firefly clamp** | set `pathtracing_clamp_indirect = 10.0`, render a small bright specular source at 256 frames | no permanent white pixels; image does not visibly dim |
| 6 | **Adaptive sampling** | run check 2 with `pathtracing_noise_threshold` at `0.0` vs `0.01` | RMSE curves within ~10%; wall-clock drops; **no convergence-boundary seams** on smooth gradients |

**Defaults chosen:** firefly clamping is **opt-in** (`pathtracing_clamp_direct` / `pathtracing_clamp_indirect` both default `0.0`) so the realtime one-shot path used by the video pipeline is unchanged — Blender's comparable indirect default is `10.0` if you want parity. Adaptive sampling defaults **on** (`pathtracing_noise_threshold = 0.01`) but only affects accumulated stills.

#### 🐞 Known defect found in production testing: the OIDN final pass

Verified on a real interior render (256 vs 1024 samples, OIDN on/off, same scene):

1. **It destroys alpha-blended geometry.** A glass coffee table renders correctly transparent with `final=none` and fully opaque black with `final=oidn`. Cause: `_oidn_final_denoise_accumulator` (`render_forward_clustered.cpp:~1956`) reads `RB_TEX_RAYTRACING_ACCUM` — which holds only path-traced *opaque* radiance — and writes the denoised result straight back over `internal_texture`, clobbering whatever the raster transparent pass had already composited there.
2. **It posterizes glossy surfaces.** A metal lamp shade loses its gradients and breaks into flat patches with hard boundaries — the "pixel breaks" a user reported.

**Workaround:** keep the Phase A final pass at `none` and buy cleanliness with samples instead.
**Proper fixes, in order of preference:** (a) Phase E1 — once transmission is handled *inside* the path tracer there is no separate raster transparent pass to clobber, which is also how Cycles works; (b) make the OIDN pass write back into the accumulator and let the normal pipeline composite, rather than overwriting `internal_texture`; (c) feed OIDN the transparency-composited buffer plus correct AOVs.

**Known deferrals:** adaptive-sampling mask dilation is not implemented (Cycles `adaptive_sampling.h:95-138`) — if check 6 shows seams, add it rather than lowering the threshold. `MIN_ADAPTIVE_SAMPLES = 16` may be low for a white-noise sampler; consider 32 pending check 6's result. Both become moot-ish once Phase B5 replaces the sampler.

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

**B1. Widen the payload: fp32 + `mis_ray_pdf`** — *Gaps #14, prerequisite for B2* — **DONE**
`PathPayload` went from three fp16-packed `uint`s to fp32 radiance/throughput plus
a `mis_ray_pdf` float: **32 → 48 bytes nominal**. `maxPipelineRayPayloadSize` is
unset in `drivers/vulkan/`, so no host-side constant tracks the size.
**Measured cost of the widening alone: +3.4%** wall clock (98.99 s → 102.38 s on a
1872-frame validation render), a single A/B pair — a real,
reproducible-direction increase that one pair cannot statistically separate from
run noise. It is a small fraction of the B2 shadow-ray cost below.
`mis_ray_pdf` carries a negative sentinel `RT_MIS_PDF_NONE` for directions the
BSDF strategy must own outright (camera ray, delta specular lobes, `combinedPdf`
zero, backfacing V). **The sentinel has no test coverage** and stands on an
argument, not a number: the specular sample weight (`G2/G1`) vanishes on the same
`NdotL → 0` limit that zeroes the pdf, so the affected rays carry almost no
throughput. Attempts to make it measurable on the rough-metal and normal-mapped
gate surfaces moved them by 0.002% and 0.01% — noise.

**B2. Multiple Importance Sampling** — *Gap #2* — **DONE for the environment only**
Power heuristic on both sides: environment NEE is weighted by
`power_heuristic(env_pdf, combinedPdf)` at the shading point, and the miss stage
weights BSDF sky hits by `power_heuristic(mis_ray_pdf, env_pdf)`.

**MIS weights must stay OFF for analytic lights and emissive meshes until C1
lands.** MIS is only valid where two strategies can both reach the same
direction. Analytic lights are unreachable by BSDF rays (they are delta or
implicit geometry the ray never hits), and emissive meshes are unreachable by
NEE (nothing samples them yet). Weighting either one down would multiply a real
contribution by `w < 1` with no second strategy to supply the complement, i.e.
delete energy. The analytic-light NEE path is therefore byte-for-byte untouched
and carries no MIS weight; its reservoir selection pdf is a stochastic estimate
rather than the exact density MIS requires, which is a second reason.

*Measured (sky-lit courtyard, sky-only lighting, `pipeline_references/tests/pt_sky_rmse_scene.tscn`):*
RMSE against a high-sample reference, environment NEE off vs on, at matched
sample counts — **6.6× to 9.5× lower with NEE at every sample count from 16 to
16384**, and 8.9× on a control build that isolates the Fresnel defect below.
Frame time cost is real: **+90% at 256×256, +144% at 512×512** (2.96× per-pixel
shading cost, 3.63 → 10.75 ns/px) because every shading vertex now fires one
extra shadow ray, and this scene's baseline fired none. **Equal-time, the
advantage is 4.8× to 6.9×** across the sweep (each sample-count ratio divided by
`sqrt(1.8966)`; the floor is the 4096-frame row) — still far above the ≥2× C3 bar.

*Open, and the reason this is not an unqualified success:* **the converged mean
moved +2.4% on dielectric specular surfaces.** MIS must redistribute variance,
not energy. The cause is isolated and confirmed by controlled experiment, not
suspected — see the C3 entry below.

**B3. Per-type bounce controls** — *Gap #4* — **DONE**
`MAX_DIFFUSE_BOUNCES 2u` is gone. Diffuse and glossy counters now live in
`packed_bounces_flags` bits 8-15 and 16-23, capped by `PT_PARAM_MAX_DIFFUSE_BOUNCE`
(12) and `PT_PARAM_MAX_GLOSSY_BOUNCE` (13) and exposed as
`Environment.pathtracing_max_diffuse_bounce` / `_max_glossy_bounce` (default 4/4,
Blender's shipped values). The total ceiling rose 8 -> 16.
**Deferred on purpose:** `min_bounce` (no consumer until B4 Russian Roulette) and
`max_transmission_bounce` (no transmission path until E1). Both would be dead
params, and **slots 0-15 are now fully allocated** -- either one needs the params
UBO resized first.

**Compatibility note:** `Environment.pathtracing_max_bounces`'s field default also
changed, from `3` to `8` (`scene/resources/environment.h`), as part of this work.
This is a silent behavior change for any existing scene that never explicitly calls
`set_pathtracing_max_bounces()` and relied on the old default -- it now gets
noticeably more indirect bounces (and a proportionally higher per-frame render cost)
than before. `doc/classes/Environment.xml` previously still documented `default="3"`
and did not mention it; both are corrected as of this fix wave.

**B4. Russian Roulette** — *Gap #8*
After the throughput update at `closest_hit_common:578`, once `total_bounces > min_bounce`: `p = min(sqrt(max_component(throughput)), 1.0)`; terminate on `rand() > p`, else `throughput /= p`. Match the `sqrt` — see §3.5.
*Accept:* render time per frame drops in deep-bounce scenes with no measurable bias (mean of 2000 accumulated frames matches the pre-RR mean within noise).

**B5. Owen-scrambled Sobol / blue-noise sampler** — *Gap #6* — **DONE**
Sobol-Burley with per-pixel Owen scrambling, dimension-indexed draws
(`sobol_burley_inc.glsl`, `RNGState` in `raytracing_inc.glsl`). Two deliberate
divergences from Cycles, both documented in the shader: the light reservoir keeps a
seeded PCG side stream (fixed by C2), and the sequence-length mask is omitted
(performance only).
**Scope of the measurement below:** it was captured at `cffb9a50a8`, before the B3
per-lobe bounce work landed, so the integrator both baselines ran against still had
the hardcoded `MAX_DIFFUSE_BOUNCES 2u` ceiling (uncapped glossy, total capped by
`max_bounces=6` from `run_pt_validation.gd`). Today the same harness instead applies
`pathtracing_max_diffuse_bounce`/`_max_glossy_bounce` at their `Environment` class
defaults of 4/4 (the harness never calls their setters, but `Environment::new()`
still carries the 4/4 field defaults into `_update_pathtracing()`), so
`resolve_bounce_cap` now resolves the diffuse cap to 4 rather than 2 -- a materially
different integrator, allowing diffuse light two more bounces of travel within the
same `max_bounces=6` budget. Re-running the harness unmodified will therefore not
reproduce the absolute RMSE figures below; only a config pinned to the historical
diffuse-2/glossy-uncapped behavior would. Separately, this sweep is accumulate-mode
only (`_render_accum` in `pt_validation.gd`), which is the aligned Sobol-prefix best
case -- see the one-shot stride note in `raytracing_inc.glsl`/`scene_raytracing_raygen.glsl`
for why the one-shot path does not inherit this figure as-is.

*Measured:* `pt_validation_scene.tscn` convergence sweep, PCG baseline (pre-Task-2,
shaders reverted to `94ba4a9792`) vs current Sobol build (`cffb9a50a8`), RMSE against
a 1024-frame reference, 2 runs per config:

| N frames | PCG RMSE (mean of 2 runs) | Sobol RMSE | improvement |
|---|---|---|---|
| 16  | 0.095787 | 0.072854 | 1.31x (23.9% lower) |
| 64  | 0.052144 | 0.032126 | 1.62x (38.4% lower) |
| 256 | 0.028699 | 0.012839 | 2.24x (55.3% lower) |
| 512 | 0.022269 | 0.007418 | 3.00x (66.7% lower) |

Sweep-wide reduction (16→512 frames, harness's own metric): PCG 4.30x, Sobol 9.82x
(consistent with the 9.80x/9.77x measured in earlier Task-2-fix sessions).

**Passes.** RMSE is lower with Sobol than PCG at every point in the sweep, and the
fitted convergence exponent is clearly steeper for Sobol than for PCG. These two
facts (no regression anywhere; a steeper exponent) are what justify "Passes" — no
further corroboration is claimed beyond them.

Fitting `p = log(RMSE_16 / RMSE_512) / log(512 / 16)` — a **two-point secant slope
over N=16..512 only**, not a regression across all four sampled points:

- PCG:   `log(4.301) / log(32)` = `1.4589 / 3.4657` = **p ≈ 0.421**
- Sobol: `log(9.821) / log(32)` = `2.2845 / 3.4657` = **p ≈ 0.659**

Because the fit uses only the two endpoints, it can be validated against the two
middle points it does *not* use — predicting `RMSE(N) = RMSE_16 * (N/16)^-p` and
comparing to what was actually measured at N=64 and N=256:

- PCG: N=64 predicts 0.05344 vs measured 0.052144 (-2.4%); N=256 predicts 0.02981
  vs measured 0.028699 (-3.7%). PCG tracks a single power law closely across the
  whole sweep.
- Sobol: N=64 predicts 0.02921 vs measured 0.032126 (+10.0%); N=256 predicts
  0.01171 vs measured 0.012839 (+9.6%). Sobol's measured RMSE sits consistently
  ~10% *above* its own two-point fit at both middle points — its curve is concave
  in log-log space, meaning its local convergence rate keeps improving as N rises.
  This is legitimate QMC behavior, but it means the single fitted exponent is a
  crude two-point summary of the curve, not a law the data obeys exactly.

Caveats:
- The harness itself warns on every run: *"reference (1024) is less than 4x the
  longest run (512); the measured reduction will read low."* The 1024-frame
  reference carries its own residual noise, which puts a floor under how low RMSE
  can read and compresses the measured curve — most severely at the N=512
  endpoint, which is one of the two points both exponents are anchored to. The
  true asymptotic exponents for both samplers are plausibly higher than measured
  here.
- Adaptive sampling (noise-threshold early-termination) was explicitly disabled
  for every run — `_render_accum` in `pt_validation.gd` unconditionally sets
  `pathtracing_noise_threshold = 0.0` before each accumulation — so the harness
  measures the un-accelerated estimator by design. This is an experimental
  control, not a source of distortion in these figures.
- Single-scene measurement (a diffuse three-wall room, one omni light, no
  occlusion complexity); it has not been repeated on a higher-variance scene.

### Phase C — Light & environment fidelity *(~2 weeks)*

**C1. Emissive-mesh light sampling** — *Gap #5*
Build an emissive-triangle buffer alongside `gather_lights` in `render_raytracing.cpp` (area, emission, power). Sample by power, MIS-combine against the BSDF (B2 must be in first). Reuse the existing TLAS for shadow rays.
*Accept:* a room lit only by a glowing panel converges clean; no hotspot speckle; matches a Cycles reference of the same scene.

**C2. Power-weighted light selection** — *Gap #7*
Replace uniform reservoir candidate selection with importance proportional to `energy / distance²` × angular falloff, following `light_tree_node_importance` (`tree.h:304`). A flat power-weighted CDF captures most of the benefit; the full tree is optional.
*Accept:* one bright key among 40 dim fills converges at several× the current rate.

**C3. Environment importance sampling** — *Gap #11* — **DONE, with one open defect**
Marginal + conditional CDFs are built over the sky octmap by a compute pass
(`shaders/raytracing/env_cdf_build.glsl`, `storage_rd/env_cdf.h`), rebuilt on a
(radiance RID, sky-state version) token rather than the RID alone — the RID is
stable and the octmap is still empty the first frame the raytracer resolves it,
so an RID trigger builds one all-zero distribution and never revisits.
`env_sample` / `env_pdf` live in `raytracing_env_sampling_inc.glsl`; the sampler
remaps continuously *within* a cell (pbrt/Cycles style), because returning cell
centres makes the estimator a fixed 256×128 Riemann quadrature whose error does
not shrink with more samples. MIS-combined against the BSDF sky bounce as in B2.

*Accept criterion (≥2× on a sunset-HDRI-style reflection): **met, by 6.6-9.5×
on samples and 4.8-6.9× equal-time.*** Full numbers and method in
`.superpowers/sdd/2026-08-09-sky-nee-and-mis/task-5-report.md`.

> **MEASUREMENT CAVEAT — do not reuse `pt_validation_scene.tscn` for this.**
> `run_pt_validation.gd:186` sets `BG_COLOR` and assigns no `Sky`, so the
> radiance texture falls back to black, every CDF cell has luminance 0,
> `marginal_total == 0`, and `env_sample()` returns false on its first branch.
> Environment NEE is **inert** in that scene by construction and any before/after
> figure taken there means nothing. Use `pt_sky_rmse_scene.tscn`.

**OPEN: +2.4% converged-mean shift on dielectric specular surfaces.**
A fully converged render (65536 frames) is 2.38% brighter with environment NEE
than without it. Pinned to `COMBINE_BRDFS_WITH_FRESNEL` (`brdf_inc.glsl:158`,
value 1): the sampler attenuates the diffuse lobe by `1 - F(V·H_random)` with
`H_random` drawn from VNDF **independently of L** (`:1211-1215`), while
`evalCombinedBRDFSeparate` attenuates by `1 - F(L·H(L,V))` with the deterministic
half-vector (`:1182-1185`). Different functions of L, so the two MIS strategies
estimate different integrands — structurally the same defect as the multi-scatter
asymmetry already fixed during this phase, one level down. Confirmed by building
with the macro at 0: the shift collapses from **+2.38% to -0.007%** on the scene
and from +0.90%/+2.30% to -0.06%/-0.002% on the gate's rough-dielectric sphere.
A pure-Lambertian control (specular lobe killed) agrees to 0.003% either way.
Pre-existing — invisible with a single strategy, because `f/p` cancels whatever
the attenuation is — but MIS is what puts the two on opposite sides of a weight
that must sum to 1. **The repair is not local to the env-NEE site:** the two
attenuations must be made the same function of L, and `evalCombinedBRDFSeparate`
is shared with analytic-light NEE, so it changes analytic-light shading engine-wide.

*Other known-open items carried out of this phase:*
- **Residual +0.42% double count on recovered (normal-mapped) samples**,
  deliberately accepted: the measured alternative remedy cost −33.1%. Note the
  recovery-off control revised this — only about a third of the residual is the
  recovery double count; **+0.28% survives with recovery compiled out**, so
  something else on normal-mapped geometry also fails to partition exactly. The
  real repair belongs to the recovery mechanism (F1), not to MIS.
- **Firefly clamping is asymmetric across the MIS partition**: environment NEE
  passes through `clamp_contribution`
  (`raytracing_closest_hit_common_inc.glsl:690`), the miss half is not clamped
  there. Invisible today only because clamping defaults to disabled.
- **Analytic-light NEE uses uncompensated `f_spec`** while indirect bounces get
  `ms·f_spec`, so one surface is shaded by two different specular integrands
  depending on light type. Pre-existing, not an MIS bug.
- **Indoors, many environment samples are occluded by walls.** The distribution
  is over the sky, not over what is visible from the shading point, so a large
  fraction of NEE rays are traced and thrown away. **Portal sampling** is the
  technique that addresses this; it is not implemented.
- Half of every environment sample is discarded by `dot(env_dir, N) > 0` because
  the distribution covers the whole sphere (Cycles does the same), and the shadow
  ray is traced *before* `bsdf_val` is known, so shading points with a
  provably-zero BRDF value still pay for one. Both are frame-time recoveries, not
  correctness issues.
- **The test binary never executes the GLSL.** Every "CPU mirror" test in this
  project would still pass if the shader were reverted and the mirror left
  untouched. All shader-level evidence for this phase is from rendered images.
- The energy gates (`pipeline_references/tests/pt_energy_gate.gd`) assert
  energy-neutrality **against the current renderer**, never physical correctness.
  There is still no Cycles reference EXR in this project.

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

**Phase B** makes the converged image *correct* rather than merely stable: MIS and real bounce counts are what separate "a path tracer" from "a reference path tracer." **With one live exception as of B2:** environment MIS shipped a **+2.4% converged-mean error on dielectric specular surfaces** — i.e. most ordinary materials — traced to the `COMBINE_BRDFS_WITH_FRESNEL` integrand mismatch and left open. Variance is where it should be; the mean is not yet. See the B2 and C3 entries before treating Phase B as a ship verdict.

**Phase D before E** is deliberate and non-negotiable. Material data must survive import before BSDF math is worth writing.

Ordering summary: **A1 → A2/A3/A4 → B4 (B1, B2, B3, B5 done) → C1 → C2 (C3 done) → D → E → F.**

Remaining in **Phase B: B4** (Russian Roulette) only.
Remaining in **Phase C: C1** (emissive-mesh light sampling) and **C2**
(power-weighted light selection). **C1 is the gate on extending MIS weights
beyond the environment** — until emissive meshes are NEE-sampleable and analytic
lights are BSDF-reachable, weighting either one is energy deletion, not variance
reduction.
