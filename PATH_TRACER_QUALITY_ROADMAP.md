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
| 17 | **Multi-scatter energy compensation over-shoot** — `evalEmsApprox`/`evalMultiScatterApproximation` over-corrects true single-scatter energy loss by roughly 3-8pp across the roughness/anisotropy range measured so far (E2b furnace: isotropic `anisotropy=0.0` control +5.95%, full sweep +3.4% to +8.1%; separate Cycles-comparison scene +6.52% raw, of which 5.85pp attributed to this bug). Pre-existing and anisotropy-orthogonal — reproduces with no anisotropic material involved at all, so it is not an E2b defect. Characterized in §7.8; **no fix is proposed here**, carried forward as-is for a future phase. | `brdf_inc.glsl:1156-1168` (`evalEmsApprox`/`evalMultiScatterApproximation`), call sites `:1215`, `:1375`, `raytracing_closest_hit_common_inc.glsl:1270` | approximation is engine-local; no Cycles line identified as its source or as exhibiting the same over-shoot | Low-Med |

**Not gaps — verified correct, leave alone:**
- BRDF library (VNDF GGX, height-correlated Smith G2) — Cycles-class. Multi-scatter compensation is present but **over-corrects** — see Gap #17 above; it is no longer an unqualified "leave alone."
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
**Status update (E1, 2026-08-21): retires *conditionally*, not unconditionally — see the Phase E1 closeout in §6 for the corrected claim.** The defect above is specifically the raster transparent pass clobbering the accumulator, and it fires for materials using `transparency = ALPHA`. E1 makes `transmission > 0` work *inside* the tracer — the fix option (a) above — but it does not migrate any existing content, and Forward+/raster was deliberately left untouched (E1 spec §2). A scene authored against this defect with `transparency = ALPHA` still hits it unchanged; only content that adopts `transmission > 0` sidesteps the raster pass entirely and stops needing the `final=none` workaround. Fix options (b) and (c) remain open for whoever needs the raster path fixed directly.

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

**MIS weights must stay OFF for analytic lights, permanently; emissive meshes
carry one as of C1.** MIS is only valid where two strategies can both reach the
same direction. Analytic lights are unreachable by BSDF rays (they are delta or
implicit geometry the ray never hits), so weighting them down would multiply a
real contribution by `w < 1` with no second strategy to supply the complement,
i.e. delete energy. The analytic-light NEE path is therefore byte-for-byte
untouched and carries no MIS weight — **this is not a gap to close**, see the
closing note in §6. Emissive meshes were in the same position only because
nothing sampled them; **C1 made them NEE-sampleable and added the weight on both
sides**, and both halves are measured in the C1 entry below.

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

**B4. Russian Roulette** — *Gap #8* — **DONE**
In `raytracing_closest_hit_common_inc.glsl`, immediately after the bounce
counters are incremented: once `get_total_bounces() > min_bounce`,
`p = min(sqrt(max(max(abs(t.r), abs(t.g)), abs(t.b))), 1.0)`; terminate on
`rng_1d(rng, RT_PRNG_TERMINATE) >= p`, else `throughput /= p`. The `sqrt` and the
max-component reduction match Cycles (`path_state.h:296-305`) — see §3.5. The
`>=` comparison sense is the correct one because `rng_1d`'s divisor is `2^32+512`,
so its result is strictly below 1.0; with a `2^32` divisor a `p == 1` path could
be killed uncompensated.

*Measured — `pipeline_references/tests/pt_sky_rmse_scene.tscn` (sky-lit
courtyard, slatted canopy, spheres), 256×256, `max_bounces = 6`, clamps and
adaptive sampling off, denoisers off.* Baseline is the **same build** with the
project setting raised to `16`, which disables the roulette without touching the
shader (`RT_GET_MAX_BOUNCES()` is structurally capped at 16 and the bounce-cap
early-out fires on the pre-increment count, so `rr_depth > 16` is unreachable).
Three invocations per configuration, interleaved.

**Bias — none detected.** Converged mean radiance over **2048 accumulated
frames** (full-image mean of R, G, B):

| roulette | run 1 | run 2 | run 3 | mean |
|---|---|---|---|---|
| off (`min_bounce=16`) | 0.124735 | 0.124733 | 0.124728 | **0.1247320** |
| on (`min_bounce=3`)   | 0.124736 | 0.124736 | 0.124728 | **0.1247333** |

Shift **+1.3e-6, i.e. +0.0011%**, judged against a **measured** radiance noise
band of **±0.0064%** (widest within-configuration spread over three repeats,
8e-6 on a 0.12473 mean; 1 sd ≈ 0.003%). The shift is 0.4 standard errors — below
the resolution of the measurement. The band was established by repeated runs
here, not inherited; it is ~5× tighter than the ~0.03% figure quoted earlier in
this phase because that one came from shorter runs and a stride-sampled probe.
A bias smaller than ~0.006% is not ruled out. Independent corroboration: the
separate 8192-frame roulette-off reference used for the RMSE cross-scoring below
gives 0.124740, inside the same band — so that single shared reference is not
itself carrying a bias into the equal-time comparison.

This bias claim holds **in the absence of contribution clamping** (`clamp_direct`/
`clamp_indirect`, both off in this measurement — see the firefly-clamping bias
note above). RR boosts a surviving vertex's throughput from `m` to `sqrt(m)` —
up to 2× at `m = 0.25` — so with clamping enabled, more post-roulette
contributions cross `clamp_contribution`'s cap than would without RR, and the
`1/p` compensation is partly clipped away on those. RR's compensation is subject
to the same clip as any other contribution; it does not get special treatment.
This is invisible in the measurement above because clamps default to disabled.

**Frame time — 16.1% faster, on means.** 512 accumulated frames per pass, 3
passes × 3 invocations = 9 passes per configuration:

| roulette | mean ± sd (n=9) | median | range |
|---|---|---|---|
| off | **1.2788 ± 0.0370 ms/frame** | 1.2658 | 1.2330 – 1.3433 |
| on  | **1.0733 ± 0.0210 ms/frame** | 1.0663 | 1.0413 – 1.1086 |

16.1% reduction on means (15.8% on medians). The groups are fully disjoint — the
slowest roulette-on pass beats the fastest roulette-off pass. **Mean/median with
spread is quoted deliberately: "best of N" is an extreme order statistic and is
not a defensible performance statistic.** Note also that the frame-time noise
floor on this harness is **~4–6% between invocations**, not the ~1.4%
within-invocation spread quoted mid-phase; the 16.1% delta clears it, but future
single-invocation timing comparisons should use the larger figure.

**Equal-time RMSE — nominally 6% to 8% better, though the underlying
matched-sample ratio is within run-to-run noise, so the headline number carries
that imprecision too — see below.** RMSE at matched sample counts, every run
cross-scored against one common 8192-frame roulette-off reference. A
roulette-*off* reference is a sound common yardstick precisely because the bias
check above shows the two configurations are statistically equivalent at
convergence: cross-scoring both arms against it is symmetric and favours
neither.

| frames | off (mean of 3) | on (mean of 3) | matched-sample ratio | equal-time ratio |
|---|---|---|---|---|
| 64  | 0.013428 | 0.013756 | 1.0244 | **0.9385** (6.1% lower) |
| 256 | 0.006111 | 0.006134 | 1.0038 | **0.9196** (8.0% lower) |

Equal-time ratio is the matched-sample ratio divided by `sqrt(time_ratio)`, with
`time_ratio = 1.1914` (means), as in the B2 measurement. The matched-sample
ratios are inside their own run-to-run noise (sd is 2–6% of the value), so the
honest reading is that the roulette adds **no measurable variance** at matched
sample count in this scene — an upper bound of roughly ±5%, not a demonstration
of exact equality. The equal-time figure is therefore a well-separated ~16% time
win multiplied by a *noisy* ratio near 1.0: the **direction** of the result is
solid, its **magnitude** inherits that ratio's uncertainty, and 6-8% should be
read as nominal rather than settled. Deeper transport, or a lower `min_bounce`, would be expected
to show a real variance increase; that regime is not covered here. Separately,
the `RMSE ∝ N^-0.5` law this conversion assumes does not hold exactly on this
scene (the measured exponent is 0.568, the error being partly tail-dominated);
using the empirical exponent would give 9.1% rather than 8.0% at 256 frames, so
the prescribed `sqrt` form is the conservative one.

**Exposure is a project setting, not an `Environment` property.**
`rendering/pathtracer/russian_roulette_min_bounce` (`PROPERTY_HINT_RANGE`
"0,16,1", default 3), read in `scene_shader_raytracing.cpp` and packed into the
raytracing specialization word at bits 4-8 with a `+1` bias so a stored 0 means
"unset". **It is therefore global rather than per-`Environment`.** The reason is
mechanical, not a design preference: `compute_rt_flags` reads only
`pathtracing_params[16]`, and B3 already allocated slots 0-15 in full (see the
B3 entry's "Deferred on purpose" note), so there was no transport channel from an
`Environment` property down to the shader without resizing the params UBO. The
project setting is the same mechanism already used five lines away in the same
function. See the design spec's §3.1a. Making this per-`Environment` requires the
UBO resize B3 flagged.

**Compatibility note — this is on by default for every existing project.** The
default is 3, so any project that never touches the setting now gets Russian
Roulette: renders get faster and marginally noisier at equal sample count with
nobody opting in. This is the same class of silent behavior change as
`pathtracing_max_bounces`'s default moving 3 → 8 in B3, documented in that entry.
Converged output is unaffected (see the bias figure above); what changes is the
speed/noise tradeoff at any fixed sample count.

**To disable it, set `min_bounce >= max_bounces`** — the guard is
`rr_depth > min_bounce` and `rr_depth` can never exceed the bounce cap, so the
roulette never fires. Setting it to 16 disables it unconditionally, which is
exactly how the baseline above was taken.

**Caveat on the performance figure: the two configurations ran separately
specialized pipelines.** `min_bounce` lives in `RT_FLAGS`, which is bound as
`constant_id = 0`, so changing it recompiles the raygen pipeline and different
register allocation is possible in principle, independent of any algorithmic
difference. A 16% delta dwarfs anything plausible from that source, but the
pipelines were not identical and the figure should not be read as if they were.

**Scope.** One scene, one resolution, one bounce budget, one GPU. The scene was
not tuned after any number was seen. All figures above are for
`noise_threshold = 0` (adaptive sampling off); RR makes the per-sample
distribution heavier-tailed by construction (most contributions vanish, rare
survivors are boosted by `1/p`), which increases the tail weight the adaptive
estimator would have to observe with adaptive sampling on — that interaction is
not measured here and was deferred to Phase C. **Phase C is now complete and did
not measure it either**; the RR × adaptive-sampling interaction is unowned and
still unmeasured.

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

### Phase C — Light & environment fidelity *(~2 weeks)* — **COMPLETE (C1, C2, C3 all landed)**

**C1. Emissive-mesh light sampling** — *Gap #5* — **DONE**
Emissive TLAS geometry is now directly sampleable by next-event estimation and
MIS-combined against the BSDF rays that already reached it. An
`EmissiveLights` slot manager (`storage_rd/emissive_lights.{h,cpp}`) gathers
emissive instances alongside `gather_lights` and a compute pass
(`shaders/raytracing/emissive_area_build.glsl`) integrates each instance's
world-space triangle area on the GPU, producing a power CDF
(`power = luminance(emission) * total_area`) plus a per-TLAS-instance slot table.
`emissive_sample()` / `emissive_pdf_solid_angle_for_hit()`
(`shaders/raytracing/raytracing_emissive_inc.glsl`) are the forward and reverse
densities; the two MIS halves are `power_heuristic()` over the *same* two
solid-angle densities with the arguments swapped, so they sum to exactly one.
Emitted radiance is composed in exactly one place (`emissive_radiance()`) and
called from both sites, so the two strategies cannot drift into estimating
different integrands — the structural defect behind B2's still-open +2.4% shift.
The whole feature is behind `rendering/pathtracer/emissive_mesh_lights`, which
**ships default off**.

*Accept criterion (a room lit only by a glowing panel converges clean, no hotspot
speckle): **met, by 3.4-4.1× on samples and 3.2-4.1× equal-time for a 2.0 m
panel, and 51-70× on samples / 35-68× equal-time for a 0.25 m panel of the same
total power**,* at a frame-time cost of **+9.0% to +15.2%** across three
interleaved runs (192×192, RTX A4000; the spread is thermal, see the report).
Energy is neutral where it must be: converged means agree to **−0.021%** against a
0.43% band derived from the run's own standard error, and the absolute brightness
matches **an exact numerical quadrature of the same irradiance integral** to
**−0.019%** (small distant emitter) and **−0.009%** (large near emitter). *Those
figures are against the quadrature, not against the small-patch closed form* —
against the closed form the same measurement reads −0.883%, and the −0.865%
difference is the approximation itself, not the renderer. Both are asserted at 2%
and both pass; conflating them would overstate the precision by 46×. The Cycles
half of the original accept criterion is **not** met — there is still no Cycles
reference EXR in this project, for C1 or for anything else.

**The BSDF half is measured, not assumed.** On a small distant emitter
`pdf_light/pdf_bsdf ≈ 34`, so `w_bsdf ≈ 0.001` and the image is NEE-only whether
or not the BSDF half works — a correct partition and one whose BSDF half is
silently zeroed produce the same mean *and* the same spread there. Gate 4 exists
for that reason: a 2.0 m panel at 0.6 m puts **`w_bsdf` at 0.5609**, so 56% of the
measured brightness flows through the BSDF half, and it lands **−0.009%** off an
exact quadrature of the same integral. Full numbers, `w_bsdf` per configuration,
liveness evidence and method in
`.superpowers/sdd/2026-08-12-emissive-mesh-lights/task-6-report.md`; gates are
`pipeline_references/tests/pt_emissive_gate_scene.tscn` and
`pt_emissive_rmse_scene.tscn`.

**Sampler-widening neutrality (C1 Task 1 widened `RT_PRNG_BOUNCE_NUM` 8 → 16,
which re-stratifies every bounce in every scene) is measured separately** against
`pt_light_gate_scene.tscn`'s recorded pre-C1 reference with the feature off:
**+0.004%** at 2048 frames against a 1% tolerance — the same figure C2 recorded,
i.e. no movement at all.

*Open items carried out of C1:*
- **OPEN (unexplained): a persistent −0.284% ON-vs-OFF residual on
  `pt_emissive_compile_scene.tscn`.** Three consecutive measurements on that scene
  have come back negative (−0.257% at 256 frames in Task 5, −0.284% at 2048 in
  Task 6), roughly 2.5σ and **below the 0.69% detection floor of that probe's own
  derived band**, so it passes. It is *not* reproduced on any of the three gate
  scenes (−0.021%, and −0.019% / −0.009% against an exact quadrature, which are
  absolute checks rather than A/B comparisons and so are the stronger constraint).
  The most likely reading is that the heavy-tailed OFF estimator lands low and its
  Gaussian standard error understates its own uncertainty — gate 2 shows the same
  sign pattern where the truth is known independently. **This is a hypothesis, not
  a diagnosis.** The one structural difference between that scene and the gates is
  that its emitter is a `BoxMesh` (12 triangles of very unequal area, most
  back-facing or self-occluded) where the gates use a `QuadMesh` with two equal
  triangles. Full argument in `task-6-report.md` §6.
  **Ruled out as candidate causes: the alpha-tested and front-culled emitter
  exclusions added in the C1 final fix wave.** Both defects made NEE emit light a
  BSDF ray could not reach, so both read **positive** on an ON-vs-OFF comparison —
  the wrong sign to explain a negative residual — and neither applies to this
  scene anyway (its `BoxMesh` emitter is opaque and back-culled). Do not re-derive
  this.
- **The fixture double-representation in `pipeline_references/image_glb_creation.gd`
  is documented and NOT fixed** (design spec §2.1). Night renders make each light
  fixture's bulb surface emissive *and* create an `OmniLight3D`/`SpotLight3D` at
  the same fixture unconditionally. Today that is harmless because the emissive
  mesh contributes only through rare BSDF hits; **enabling
  `rendering/pathtracer/emissive_mesh_lights` without a pipeline change would turn
  each of those surfaces into a second fully-sampled light and materially brighten
  night renders.** Structurally identical to the `SKY_MODE_LIGHT_AND_SKY` sun-disc
  double count that forced `SKY_MODE_LIGHT_ONLY`. The engine cannot detect it: an
  emissive mesh and an analytic light are independent objects with no relationship
  the renderer can see.
- **No per-triangle area weighting.** Triangle selection within an instance is
  uniform (`1/prim_count`), so a mesh whose emitting triangles differ wildly in
  area spends most draws on slivers. Unbiased — the pdf divides by the selected
  triangle's own area — but higher variance, and untested against a deliberately
  uneven tessellation.
- **No rendered coverage of textured emissives.** `emissive_radiance()` has a
  `RT_MAT_FLAG_HAS_EMISSION_TEX` branch; every rendered measurement uses a flat
  emission colour, so that branch is exercised only by CPU mirrors.
- **Deformed and custom-hit-group emitters are excluded from the distribution by
  design.** Their slot stays `-1`, so `emissive_slot_for_instance()` returns −1,
  the MIS weight stays 1.0 and the BSDF path carries them in full. Unbiased, but
  higher variance than a sampled emitter — they behave exactly as they did
  pre-C1.
- **The setting ships default off**, so the feature is exercised only when
  deliberately enabled. Nothing about existing renders changes on the day it
  lands; the cost is that it is inert until someone opts in.
- **The merged-MultiMesh ordering edge is maintained by a deliberately unread
  uniform binding and a 4-byte `buffer_copy` chain.** Both look like dead code and
  neither is: deleting either reintroduces a race where the area pass runs against
  a stale merged buffer.
- **`SKY_MODE_LIGHT_AND_SKY` is still unsupported alongside environment NEE.** C1
  did *not* reconcile emissive and analytic lights — see the corrected pointer in
  the C3 open-items list below.

**C2. Power-weighted light selection** — *Gap #7* — **DONE**
The uniform k=16 mini-batch reservoir is replaced by a flat power-weighted CDF
over the light array with an **exact** selection pdf
(`shaders/raytracing/raytracing_light_select_inc.glsl`). The weight is
`|luminance(emission)| × attenuation × spot_factor × indirect_energy`, sharing
`lights_attenuation_from_dist_sq` verbatim with the shading path so the density
sampled from and the density divided by cannot drift apart. Three cases where a
naive weight would zero a light that still contributes are handled and marked in
the file (rect half-diagonal expansion, spot cone widened by the sphere's
angular radius, and a floor under the *product* of the continuous factors). The
light tree is not built; the flat CDF is two O(light_count) passes per shading
point. `RT_LIGHT_SELECT_UNIFORM` (`raytracing_lights_inc.glsl:24`) is kept
permanently as A/B scaffolding — `1` restores the pre-C2 reservoir.

*Accept criterion (one bright key among 40 dim fills converging at several× the
current rate): **met, by 10.5-16.9× on samples and 9.8-16.5× equal-time**,* at a
frame-time cost of **+50.8%** at 41 lights (0.7487 → 1.1287 ms/frame, 256×256,
RTX A4000). Energy is neutral where it must be: the `in_range` gate, where the
old estimator was exact, moves by **+0.004%** against a 1% tolerance. Full
numbers, liveness evidence and method in
`.superpowers/sdd/2026-08-11-power-weighted-light-selection/task-3-report.md`;
gates are `pipeline_references/tests/pt_light_gate_scene.tscn` and
`pt_light_rmse_scene.tscn`.

> **CORRECTION — the pre-C2 estimator was NOT biased under range culling.**
> The design spec predicted that estimating `light_select_pdf` from the
> valid-count ratio biased the converged image whenever culling rejected
> anything (`E[1/X] ≠ 1/E[X]`), and the `culled` gate was built to measure that
> shift. It measured **−0.003%**, smaller than the same gate's own finite-sample
> residual, refuting a predicted "few percent". The premise was wrong, not the
> measurement: the estimator *multiplies* the contribution by
> `valid_count_estimate` (it divides by its reciprocal), and given
> `valid_found = m > 0` the reservoir's pick is uniform over the valid lights
> independently of `m`, so `E[f·N·m/k] = mean(f) · V` exactly. Jensen never
> enters. **The pre-C2 estimator is exactly unbiased, culling or not** — including
> the `valid_found == 0` early-out, which is not a defect either: the estimator's
> value is `f·N·m/k`, which is 0 when `m = 0`, so `m·1{m≥1} = m` identically and
> `E[N·m/k] = V` with no dropout term. (An earlier revision of this block claimed
> a residual `(1 − V/N)^k` energy loss; there is none.) **The justification for C2
> is variance, not bias**, and the variance result above stands on its own. Code
> comments corrected; the spec carries a dated correction marker over an
> unrevised body.

**OPEN (efficiency, not correctness): the surface-normal cosine is deliberately
excluded from the weight** (design spec §3.5). Roughly half of all selection
draws therefore still go to lights facing away from the shading point, and are
discarded by the existing `NdotL <= 0` tests after a draw has been paid for.
Including a `max(0, dot(N, L))`-style factor would recover frame time; it is not
a correctness issue, because the pdf is exact for whatever weight is used.

**OPEN (coverage): no rendered measurement covers spot, rect or directional
lights.** Every light in every measured scene is an `OmniLight3D`. The spot cone
factor, the rect half-diagonal expansion and the directional early-out are
covered by `tests/servers/rendering/test_pt_light_select.cpp` and by nothing
that renders.

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
*(B2's defect, measured here — see the attribution note in §6. The mechanism is
B2's `COMBINE_BRDFS_WITH_FRESNEL` integrand mismatch; C3 is where the numbers
were taken, not where the bug is.)*
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
  recovery-off control revised this — only **~23%** of the residual is the
  recovery double count (0.083 of the 0.36 percentage points); **+0.28% survives
  with recovery compiled out**, so
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
- **`SKY_MODE_LIGHT_AND_SKY` double-counts an analytic light against environment
  NEE.** Every measurement in this phase used a scene with zero analytic lights,
  so none of them exercised a light that is both NEE-sampled and drawn into the
  sky texture. Godot's default `sky_mode` is `SKY_MODE_LIGHT_AND_SKY`, which
  draws a `DirectionalLight3D`'s disc into the sky; that disc is then both
  NEE-sampled analytically and importance-sampled by `env_sample()` —
  double-counting the brightest emitter in the scene. Pre-existing in the
  converged mean (BSDF rays already hit that disc), but previously buried in
  noise; the environment CDF now concentrates samples on it, so it converges
  quickly to the doubled value. `SKY_MODE_LIGHT_AND_SKY` is therefore
  unsupported alongside environment NEE; `pipeline_references/image_glb_creation.gd`
  works around this by setting `SKY_MODE_LIGHT_ONLY` on its sun. **CORRECTION: an
  earlier revision said this would be resolved when C1 landed. C1 has landed and
  it is not.** C1 made emissive *meshes* NEE-sampleable; the sun disc drawn into
  the sky texture is not a mesh and is not in the emissive distribution, so the
  double count between analytic NEE and environment NEE is untouched. The
  workaround stands and the reconciliation is still unowned.

### Phase D — Material data pipeline *(NEW, first-class; ~2 weeks)* — **COMPLETE (D1, D2, D3 all landed)**

**Nothing in Phase E is testable until this lands.** See §3.6.

**D1. glTF extension import** — *Gap #12*
Add `KHR_materials_transmission`, `_ior`, `_volume`, `_specular`, `_clearcoat`, `_sheen`, `_anisotropy` to `modules/gltf/`.

**D2. Material representation**
Extend `StandardMaterial3D` (or introduce a `PrincipledMaterial3D`) to carry the new parameters, so imported data survives into the scene tree and the Inspector.

**D3. Widen RT `MaterialData`**
Add transmission, IOR, clearcoat (+roughness), sheen (+tint), anisotropy (+rotation) to `raytracing_data_inc.glsl:87-105` and its C++ twin. **Respect the std430 / `static_assert(sizeof == N)` / `alignas(16)` parity rules** — the struct has a verbatim GLSL counterpart and both must agree byte-for-byte.

*Accept:* a Blender-authored GLB with glass, car paint, and fabric round-trips with every parameter intact and inspectable, *before* any new BSDF math exists to consume it. **Met — see the Phase D closeout in §6.**

### Phase E — BSDF completeness *(~3 weeks, parallelizable after D)*

**E1. Transmission / rough glass** — *Gap #13* — **COMPLETE**
GGX refraction sampling; remove the `transmissivness = 0.0` hardcode (`closest_hit_common:474`). Handle front/back faces, IOR sides, total internal reflection. Wire `max_transmission_bounce` from B3.
*Accept:* a glass vase refracts correctly; rough glass blurs plausibly; retire the "glass vanishing" workaround **for content that adopts transmission** (see the corrected OIDN claim above and the full closeout in §6).

**E2. Anisotropy, clearcoat, sheen** — anisotropy portion **COMPLETE (E2b)**, clearcoat/sheen **NOT STARTED**
`sampleGGXVNDF` already takes `alpha2D` and callers pass `(alpha, alpha)` (`brdf_inc.glsl:837`) — thread real anisotropy through instead. Add a clearcoat GGX lobe and a Charlie/sheen lobe.
*Accept:* brushed metal, car paint, and velvet respond comparably to Cycles. **Brushed metal: met, see §7.8** — anisotropic GGX now threads real `ax`/`ay` through distribution, Smith G2, VNDF sampling and pdf, sharing its `ax`/`ay` formula verbatim with Cycles and this engine's own raster; measured at **+6.52% raw** against Cycles (5% bar), narrowing to within **0.67%** once the pre-existing, anisotropy-orthogonal `evalMultiScatterApproximation` pedestal (§7.8) is accounted for. **Car paint and velvet: not met** — clearcoat and sheen lobes do not exist yet; carried to E2d/E2e (§7.8, spec §9). The two-way→N-way lobe-selection rewrite they depend on is done (E2c, §7.9); anisotropy on the transmissive lobe remains.

**E3. Subsurface scattering**
Random-walk BSSRDF following `subsurface_random_walk.h`.
*Accept:* skin and wax read correctly under existing NEE.

### Phase F — Precision & robustness *(rolling)*

**F1. Offset normals replacing the biased bump mirror** — *Gap #15*
Remove `recoverBelowHemisphereSample` (`brdf_inc.glsl:998-1009`); its own comment concedes it is energy-non-conserving. Keep debug vis mode 22 for comparison.
*Accept:* grazing angles on a high-frequency normal-mapped surface stay energy-flat; no over-bright, no speckle.

**F2. Volumetrics** — *Gap #16*
Homogeneous fog/god-rays via a volume integrator (`shade_volume.h`), with `max_volume_bounce` from B3.

**F3. `Environment.BG_COLOR` silently produces a black world for the path
tracer.** *(Found authoring Phase E1 Task 7's transmission gate;
`pipeline_references/tests/pt_transmission_gate.gd`'s `_new_env` header
comment has the full writeup.)* `env_sky_radiance()` / `env_sample()`
(`raytracing_lights_inc.glsl` / the env-sampling headers) read
`radiance_octmap`, which the sky pass only populates for `BG_SKY` with an
actual `Sky` resource — `SkyRD::draw_sky`'s `BG_COLOR`/`BG_CLEAR_COLOR` branch
feeds the RASTER fog-sky material instead, a completely different consumer.
A scene authored with `background_mode = BG_COLOR` (the natural first choice
for "I just want a flat colour background," and Godot's raster viewport
renders it correctly) reads as **pure black** to every path-traced ray that
misses geometry, with no warning and no fallback. This is NOT the narrower
`pt_validation_scene.tscn` caveat noted above (§3, "MEASUREMENT CAVEAT") —
that one is about one specific scene's Environment sky assignment; this is
the general trap in the underlying mechanism, and it will bite the next
person who writes ANY path-traced scene with a flat-colour background,
Cornell-box-style test scenes very much included. Fix options: either make
the sky pass populate `radiance_octmap` from a flat colour when
`BG_COLOR`/`BG_CLEAR_COLOR` is set (matching what the raster path already
visually does), or fail loudly (editor warning) when path tracing is enabled
on an Environment whose background mode cannot contribute environment
lighting. Workaround in the meantime: use `BG_SKY` with a
`PanoramaSkyMaterial` over a flat-filled `Image` for any authored background
colour (`_new_env`, above, does exactly this).

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

Ordering summary: **A1 → A2/A3/A4 → D → E → F (Phases B, C and D are complete).**

**Phase B is complete** — B1, B2, B3, B4 and B5 have all landed. "Complete" here
means every listed item is implemented and measured; it does **not** mean Phase B
is free of known defects. The open items recorded in this document stand
unchanged and none of them is resolved by B4: the **+2.4% converged-mean shift on
dielectric specular surfaces** from B2's `COMBINE_BRDFS_WITH_FRESNEL` integrand
mismatch, the **asymmetric firefly clamping** across the MIS partition, the
**untested zero-pdf sentinel**, and the fact that **the doctest binary never
executes the GLSL** — the shader-side tests mirror the shader in C++ rather than
running it.

**Phase C is complete** — C1, C2 and C3 have all landed. As with Phase B,
"complete" means every listed item is implemented and measured; it does **not**
mean the phase is free of known defects. The **+2.4% converged-mean shift on
dielectric specular surfaces** and the `SKY_MODE_LIGHT_AND_SKY` double count are
both still open, and C1's open items — chief among them the **fixture
double-representation in `image_glb_creation.gd`**, which would materially
brighten night renders if the setting were enabled without a pipeline change —
are recorded in the C1 entry. **C1 ships default off.**

**One attribution, stated once so the rest of this document can point at it.** The
+2.4% dielectric-specular shift is **B2's defect, recorded under C3**: the
mechanism is the `COMBINE_BRDFS_WITH_FRESNEL` integrand mismatch that B2's
environment MIS introduced (`brdf_inc.glsl:158`), and it was *measured* during C3,
which is why the numbers live in the C3 entry. It is not a C3 defect and it is not
two separate items. Earlier revisions of this section called it "C3's", which
would send someone to the wrong code.

- **C1**: emissive-mesh NEE with MIS, 3.2-4.1× equal-time on a 2.0 m panel and
  35-68× on a 0.25 m panel of the same power, for +9-15% frame time; converged
  means neutral to −0.021% and absolute brightness within 0.02% of **an exact
  numerical quadrature** of the same irradiance integral (−0.883% against the
  small-patch closed form; the difference is the approximation, see the C1 entry),
  including a configuration where the BSDF half carries 56% of the energy. One
  unexplained open item: a persistent −0.284% residual on the Tasks 4/5 scene,
  below that probe's own detection floor and not reproduced on the gate scenes.
- **C2**: power-weighted CDF selection with an exact pdf, 9.8-16.5× equal-time on
  a power-concentrated scene for +50.8% frame time; see the C2 entry, including
  the correction to the spec's bias claim and two open items (the cosine is
  excluded from the weight; no rendered coverage of spot/rect/directional).
- **C3**: environment importance sampling, 4.8-6.9× equal-time, with B2's +2.4%
  dielectric-specular shift open and measured here.

**MIS weights now cover both strategies that can reach the same direction: the
environment (B2) and emissive meshes (C1). Analytic lights are a different case
and are finished, not pending:** omni, spot, directional and `RT_LIGHT_TYPE_RECT`
are pure buffer data with no TLAS presence, so no BSDF ray can ever hit one.
There is no second strategy to combine against, so analytic lights correctly
carry **no MIS weight, permanently** — this is not a gap to close. (An earlier
revision of this section said C1 was gating "until … analytic lights are
BSDF-reachable"; that is wrong and would have sent someone looking for a fix that
must not be written.)

**Phase D is complete** — D1, D2 and D3 have all landed (Tasks 1-5: ten new
`BaseMaterial3D` path-tracer-only parameters; glTF import of seven material
extensions; glTF export closing the round-trip; `RT_MaterialData` widened
96→176 bytes; a GPU gate proving the data reaches the shader intact). As with
Phases B and C, "complete" means every listed item is implemented and
measured; it does **not** mean the phase does anything to rendered output yet.
**Nothing reads any of the new values in the integrator. No pixel changed. No
physical correctness is claimed** — Phase D is data plumbing, full stop, and
that is the entire point: Phase E can now write BSDF math against material
data that demonstrably survives import, export, and the GPU upload path,
instead of against nothing.

**Measured no-pixel-change (§7.2).** The pre-D invariant — a scene carrying
none of the seven new extensions must render bit-for-bit identically before
and after Phase D, because the integrator reads none of the new struct fields
and nothing pre-existing was overwritten — was checked by reverting
`scene/`, `modules/gltf/`, `servers/rendering/` and `tests/` in place to
`27086b741e` (the commit immediately before Phase D), rebuilding, and
re-running `pt_light_gate_scene.tscn`'s gate 1 (`ZR_GATE_MODE=in_range
ZR_GATE_FRAMES=2048 ZR_GATE_RES=256`) against the Phase D HEAD build:

| | pre-D (`27086b741e`) | Phase D (HEAD) |
|---|---|---|
| MEAN | 6.067232 | 6.067232 |
| std-dev | 0.117619 | 0.117620 |
| delta vs. 2048-frame reference | +0.000240 (+0.004%) | +0.000240 (+0.004%) |

MEAN is identical to the sixth significant figure. The std-dev delta
(0.117619 vs. 0.117620) is ~8.5e-6 relative — the gate header's cited ~1e-6
figure describes MEAN reproducibility across repeat runs of the same build,
not std-dev, so it is not the right bound to cite here. The std-dev delta is
still two orders of magnitude below the gate's 1% tolerance and shows no
directional bias consistent with a real behavioral change. **No shift. The
invariant holds.**

**Measured Blender acceptance (§7.1).** This is the only check in Phase D
that validates our reading of Blender's *exporter* rather than our own
importer against our own hand-written fixtures — Tasks 2 and 3's tests are
hermetic and cannot substitute for it. A GLB was built headlessly with
Blender 4.5.3 LTS (`bpy`, `--background --python`) containing three
Principled-BSDF materials — glass (Transmission Weight, IOR, a Volume
Absorption node plus a `glTF Material Output` node group supplying
Thickness), car paint (Coat Weight/Roughness, Anisotropic/Anisotropic
Rotation), fabric (Sheen Weight/Roughness/Tint) — exercising all thirteen
imported parameters, then loaded through `GLTFDocument.append_from_file` under
`--path pipeline_references`, the same runtime import path the production
pipeline uses. **All thirteen of thirteen round-tripped correctly:**
`transmission`, `ior`, `thickness`, `attenuation_distance`,
`attenuation_color`, `specular_factor`, `specular_tint`, `clearcoat`,
`clearcoat_roughness`, `sheen_color`, `sheen_roughness`, `anisotropy`,
`anisotropy_rotation`.

Two things surfaced during this check that are **not** defects but are
easy to mistake for one, so they are recorded here:

- The three color-valued parameters (`attenuation_color`, `specular_tint`,
  `sheen_color`) come back from the Inspector visibly different from the raw
  linear floats Blender writes into the glTF JSON (e.g. JSON `0.2` reads back
  as Godot Color `0.4845`). This is **not** a bug: `read_ext_color`
  (`gltf_document.cpp:3118-3146`) applies `linear_to_srgb()` on import and the
  corresponding export path applies `srgb_to_linear()`, exactly mirroring the
  pre-existing `baseColorFactor` convention (`gltf_document.cpp:3340-3341` /
  `2680`) — Godot's `BaseMaterial3D` Color properties are stored
  sRGB-encoded. Un-converting the Inspector values with the standard sRGB
  transfer function reproduces Blender's linear inputs to four decimal
  places. Round-trip verified correct; noted because the raw-JSON-vs-Inspector
  diff looks alarming at a glance.
- Blender's own `KHR_materials_specular` exporter folds `specularFactor` into
  `specularColorFactor` whenever `Specular IOR Level > 0.5` (its internal
  `fac = level * 2.0` exceeds glTF's `specularFactor <= 1.0` ceiling), and
  `Anisotropic Rotation` is a 0-1 turn fraction in Blender's UI that the
  exporter converts to radians for glTF's `anisotropyRotation` (matching
  Godot's `anisotropy_rotation`, which is also radians). Both are exporter-side
  conventions, not import bugs, but worth knowing when hand-authoring test
  content in Blender.

**Suite:** `--test` → **1487 passed, 0 failed, 3 skipped** (Task 2's edge-case
coverage deliberately emits `WARN_PRINT` for non-numeric/malformed extension
fields; those warnings are expected, not failures). **GPU gate:**
`pt_material_data_gate_scene.tscn` → **PASS, all 19 material fields arrived in
the shader intact** (19, not 13, because the gate additionally exercises the
`attenuation_density` and `specular_factor`/`sheen_roughness` packing lanes
alongside the thirteen user-facing parameters).

**Open items, carried into Phase E, stated plainly rather than buried:**

- Per-parameter extension textures (`transmissionTexture`,
  `specularTexture`, `clearcoatTexture`, `sheenColorTexture`, …) are dropped
  with a `WARN_PRINT`. **Deliberate** (spec §2), not an oversight — only
  factors are imported.
- `KHR_materials_iridescence` is not imported at all; it is absent from
  `supported_extensions` and has no `BaseMaterial3D` parameter.
- **F0 is double-specified.** Both `specular` (Godot's pre-existing
  Fresnel-at-normal-incidence control) and the new `ior` /
  `specular_factor` / `specular_tint` triple reach the shader simultaneously.
  Nothing today resolves the conflict — **Phase E must decide which wins**
  before writing any BSDF math that reads F0.
- `ior == 0.0` is legal glTF (`KHR_materials_ior` permits it as a signal
  value) and imports without complaint. **Phase E must not assume `ior >=
  1`** anywhere in the refraction math it writes.
- **BACKLOG (deferred by the user, 2026-08-19) - glTF export does not clamp
  the three colour factors.** Task 3's fix wave clamped the scalar exports
  (`transmissionFactor`, `clearcoatFactor`, `anisotropyStrength`, ...) into
  their glTF-legal ranges but left `sheenColorFactor`, `specularColorFactor`
  and `attenuationColor` unclamped. Godot's `Color` is unbounded while glTF
  requires `[0,1]` per component, so an authored value outside that range
  writes spec-invalid JSON. Identical defect class to the scalars - closed
  for them, still open for these; an omission in the fix brief rather than a
  decision. Not a Phase E blocker: nothing in the integrator reads the
  export path.
- Nothing in the integrator reads any of the new struct fields yet. No
  rendered output changed as a result of Phase D, and no claim of physical
  correctness is made for the new parameters — that is Phase E's job.
- **The GPU material-data gate has two accepted residual risks, not fixed
  because fixing them costs more than the risk they leave open** (both
  written up in `pipeline_references/tests/pt_material_data_gate.gd`'s
  header):
  - **Fixture collision.** `V_CLEARCOAT` (0.55) and the blue channel of
    `V_SPECULAR_TINT` (0.55) are equal. `clearcoat` lives at `RT_MaterialData`
    offset 160 and `specular_tint.b` at offset 136; a struct-aliasing bug that
    mapped one onto the other would read 0.55 in both checks and both would
    pass. Accepted rather than re-cutting fixtures across four already-landed
    tasks, because the two offsets are 24 bytes apart with several fields
    between them, so any layout bug big enough to alias them would also shift
    the rest of the struct's tail and fail most of the gate's other 17 checks
    — but it means this one specific aliasing is, in principle, undetectable
    by this fixture set.
  - **The custom-hit-group path is compile-verified only, never executed.**
    `debug_visualize()`'s two call sites in `scene_raytracing_raygen.glsl`
    are mutually exclusive `#ifdef` branches; the gate's
    `StandardMaterial3D` scene can only take the non-custom-hit-group branch.
    The `materials[h.geometry_idx]` fetch in the `RT_CUSTOM_HIT_GROUP` branch
    has therefore never run with real data in any test in this repo — only
    built successfully. The gate's "data reaches the shader intact" claim
    covers the `StandardMaterial3D` path only; a custom-hit-group gate scene
    is out of scope for Phase D and remains open for whoever next touches
    that path.

**The next item is Phase E** (BSDF completeness), which is unblocked now that
Phase D's material data demonstrably survives import, export, and the GPU
upload path.

---

## 7. Phase E1 closeout — transmission and rough glass

**Phase E1 is complete.** The dielectric microfacet closure (reflection and
transmission as one closure, real Fresnel, TIR, thin-walled and volumetric
paths, Beer-Lambert absorption) lands on `vijay_PTEngine_v12_PhaseE`, 22
commits over `986ebc2ee1..83161b784f`. The `transmissivness = 0.0` hardcode
(previously at `raytracing_closest_hit_common_inc.glsl:617`, pre-E1 — a
coordinate in the file as it stood before this phase's edits, not a location
in the current file; corrected in the E1 final fix wave, doc-fix list item 8,
which had been presenting it as a current-file line number) is removed. As with Phases B–D,
this closeout measures rather than asserts; three divergences from Cycles were
already known and expected going in (§6.1, §6.3, §6.4 of the design spec),
and this phase's own review process found and fixed four Critical/Important
defects the standing test suite could not see at all (task-7-report.md) —
**that pattern, not a clean bill of health, is the headline finding worth
carrying forward.**

**Suite and gates, measured at `83161b784f`:**

| Check | Result |
|---|---|
| doctest | 1511 test cases, 1511 passed, 0 failed, 3 skipped; 2,066,447 assertions, 0 failed |
| `pt_transmission_gate` | **PASS**, all 46 checks across 10 probes (§7.2 of the design spec) |
| `pt_material_data_gate` | PASS, all 25 material fields |
| `pt_energy_gate` | PASS |
| `pt_light_gate` | PASS |
| `pt_emissive_gate` | PASS |
| `pt_validation_scene` mean_luma | 1.19322 / 1.19320 / 1.19321 (2e-5 band; ~1e-5 measured run-to-run noise floor) — **no pixel change** on opaque content |

### 7.1 Cycles reference comparison

Harness: `pipeline_references/tests/pt_transmission_reference.gd` /
`_scene.tscn`. A grey ground plane, a **white** glass slab (`transmission 1.0,
ior 1.5, roughness 0`) and a **deliberately tinted** glass vase
(`specular_tint (0.75, 0.55, 1.0)`, `attenuation_color (0.15, 0.85, 0.35)`,
`roughness 0.06` — non-white on both axes spec §7.3 requires), lit by one
shared procedurally-baked equirect HDRI (256×128, a dim gradient dome plus a
small bright warm patch) consumed identically by both renderers — not two
independently-authored approximations of "the same sky." Rendered here to a
linear EXR via `Image.save_exr()` (Phase A2 path) at 320×320, 1024 accumulated
frames; rendered in Blender 4.5.3 LTS/Cycles headless
(`blender.exe -b --python`) at 320×320, 1024 samples, `view_transform =
Standard`, `exposure/gamma` neutral, denoising off (this is a converged-mean
comparison, not a production-noise comparison), caustics off. Geometry and
camera are matched by explicit numeric transform under the mapping
`blender(x,y,z) = godot(x,-z,y)` — the same convention Blender's own glTF
importer applies — documented inline in `pt_transmission_reference.gd`'s
comments. Comparison (per-channel MSE, a box-filter SSIM on a Reinhard-
tonemapped copy of both images) runs in Blender's bundled Python/numpy,
because neither a plain Python install on this machine nor this engine has an
EXR reader with array access (checked: no `OpenEXR`/`imageio`/`skimage`/
`scipy` module available). The driver scripts (`gen_panorama.py`,
`render_cycles_ref.py`, `compare_exr.py`) are kept outside the repo per the
brief's file list and are reproduced in `task-8-report.md`.

**A pre-existing, glass-unrelated divergence was found and isolated before
trusting the raw numbers.** The first full comparison read ours ≈ 20–23%
dimmer than Cycles **uniformly across every region of the image, including
the ground plane far from either glass object.** A no-glass control render
(ground + sky only, both renderers, otherwise identical) confirmed the gap
persists with zero transmissive geometry in the scene:

| | ours | Cycles | ratio |
|---|---|---|---|
| R | 0.181181 | 0.234934 | 0.7712 |
| G | 0.182560 | 0.236366 | 0.7724 |
| B | 0.192737 | 0.248631 | 0.7752 |

This is **not an E1/transmission defect** — it reproduces on a scene with no
glass at all, and is therefore a pre-existing gap in this engine's
environment-lit diffuse response relative to Cycles, orthogonal to everything
this phase touched. It does not fit any of the design spec's three named
expected divergences (§6.1 no-NEE-through-glass noise, §6.3 single-scatter
dimming, §6.4 the Fresnel-formulation mismatch), so per the brief's own rule —
"a divergence fitting none of those is a defect" — **it is recorded here as a
new, standalone open item** (§7.4 below; resolved there — see §7.7 — as a
comparison-harness colour-space error in this section's own field-for-field
material transcription, not an engine defect), not folded into E1's own
account. Root cause was not chased (out of scope for a measurement task); candidates
include environment-map filtering/resolution loss of the HDRI's small bright
patch during octmap conversion, and pre-existing environment-NEE energy gaps
already catalogued elsewhere in this document. Both the raw and a
calibration-divided comparison are reported below so this gap does not swamp
the glass-specific signal E1 actually needs judged.

**Raw comparison** (uncorrected):

| Channel | MSE | SSIM (Reinhard-tonemapped) | mean ours | mean Cycles |
|---|---|---|---|---|
| R | 0.00437485 | 0.891681 | 0.171349 | 0.216344 |
| G | 0.00481927 | 0.877777 | 0.176044 | 0.220835 |
| B | 0.00480192 | 0.890914 | 0.182751 | 0.229962 |
| avg | MSE 0.00466535, RMSE 0.06830 | | | |

| Region | RMSE | mean ours | mean Cycles |
|---|---|---|---|
| left third (slab) | 0.06491 | 0.184060 | 0.228229 |
| right third (vase) | 0.06793 | 0.164820 | 0.204930 |
| middle third (floor/sky) | 0.07186 | 0.181334 | 0.234035 |

**Calibrated comparison** (ours divided by the per-channel no-glass control
ratio above, isolating glass-specific divergence from the pre-existing
environment gap):

| Channel | MSE | SSIM | mean ours (cal.) | mean Cycles |
|---|---|---|---|---|
| R | 0.00510231 | 0.925809 | 0.222185 | 0.216344 |
| G | 0.00567817 | 0.910673 | 0.227930 | 0.220835 |
| B | 0.00566272 | 0.924671 | 0.235750 | 0.229962 |
| avg | MSE 0.00548107, RMSE 0.07403 | | | |

| Region | RMSE (cal.) | mean ours (cal.) | mean Cycles |
|---|---|---|---|
| left third (slab) | 0.07204 | 0.238123 | 0.228229 |
| right third (vase) | 0.07511 | 0.213234 | 0.204930 |
| middle third (floor/sky) | 0.07489 | 0.234596 | 0.234035 |

**Attribution.** Corrected in the E1 final fix wave (doc-fix list item 6):
this section previously read the floor/sky region's post-calibration
agreement with Cycles (0.3%) as independent confirmation that "the
calibration correctly isolates the pre-existing gap." **That reasoning is
circular.** The per-channel calibration ratio (0.7712/0.7724/0.7752) was
*derived from* the no-glass floor/sky control render in the first place —
dividing that same region by a factor computed from itself and finding it
now agrees is arithmetic identity, not an independent measurement. It proves
the division was done correctly; it says nothing about whether a single
scalar gain, measured on diffuse environment-lit pixels, is the right
correction to apply to the slab and vase regions, which are dominated by
specular reflection and refraction, not diffuse response.

That question is exactly where the previously-"unattributed" ~4.0–4.2%
residual (slab and vase running brighter than Cycles after calibration) turns
out **not** to be a dead end. *(Note: §7.7 has since shown the underlying
~23% gap itself was a comparison-harness colour-space error, not either
candidate renderer-side cause named below — see §7.4/§7.7. This paragraph's
"candidate cause" framing predates that finding and was not revisited by this
correction pass; it is left as the historical reasoning for the ~4% residual
specifically, which is a separate, still-open question this correction does
not resolve.)* Both candidate root causes named above for the
underlying ~23% gap — HDRI resolution/filtering loss during octahedral-map
conversion, and pre-existing environment-NEE energy behavior — are
**path-type-dependent**: neither has any reason to apply the same gain to a
specular/refractive path that it applies to a diffuse one. Dividing the slab
and vase regions by the diffuse-measured 0.772 factor implicitly assumes it
does. If the true factor on glass is nearer 1.0 (plausible for either
candidate cause — a filtering loss specific to how *diffuse* GI samples the
environment map, or an NEE energy gap in the diffuse estimator, would not
touch a specular/refractive path the same way), then dividing by 0.772
over-corrects: in the fully-environment-lit limit that is a ~1/0.772 ≈
1.295× over-brightening. That is consistent in **direction** with the
observed residual (brighter, not darker) and of the right **order of
magnitude** to be the explanation, once the fraction of each glass pixel's
radiance that is actually direct environment light (as opposed to light
arriving via refraction/reflection off other, non-environment-gain-affected
geometry) is accounted for — which this measurement pass did not isolate.
This also resolves what was previously flagged as puzzling: the residual runs
*brighter* than Cycles, the opposite of §6.3's single-scatter dimming
prediction, which a mis-calibrated diffuse-derived gain explains and an
actual transmission-lobe defect would not.

**No divergence here is large enough, or in the right direction, to
confidently attribute to any single one of §6.1/§6.3/§6.4 individually** —
that conclusion still stands. What has changed is that the ~4% residual is no
longer "unattributed": it is now the SUSPECTED SIGNATURE of a diffuse-only
calibration applied uniformly to specular/refractive pixels, not evidence of
an E1 defect. **The cheap confirming experiment, not yet run:** one
mirror-sphere (dielectric, roughness 0, transmission 0 — pure specular
reflection, zero diffuse contribution) control render under the identical
HDRI, in both renderers. A pure mirror sphere isolates exactly the question
this section could not answer: does the diffuse-derived 0.772 calibration
factor also hold for a 100%-specular path, or does that region need its own,
different factor? That result would either confirm the calibration
generalizes (closing this item) or pin down its size precisely (replacing
"~4%, plausible" with a measured number) — either way it is a single
additional render, not the "longer, dedicated convergence run (thousands of
samples, per-source ablation)" still needed to separate §6.1/§6.3/§6.4's
individual contributions, which remains out of scope for this measurement
pass. What this comparison *does* establish, independent of the calibration
question above: geometry, camera and material transform all matched
correctly, the tinted vase renders recognizably glass-like and in the right
brightness neighborhood as Cycles, and no defect was found that isn't already
named in the design spec's accepted-consequences list or the new
environment-lighting item below.

### 7.2 Frame-time delta, `RT_FLAG_TRANSMISSION_ENABLED` on vs off

Measured on `pt_light_rmse_scene.tscn` (§7.3's mixed-light interior scene,
timing pass only, `ZR_LIGHT_SKIP_SWEEP=1`), 256×256, 512 accumulated frames,
vsync off, 3 passes per build taking the best — an **entirely opaque**
scene (every light-selection scene in this repo is opaque; no material in it
carries `transmission > 0`), so any difference measures pure register-pressure
/ code-size cost, not glass shading cost.

Build A (HEAD, `transmission_enabled` default true, flag live):
`compute_rt_flags` unmodified. Build B: the `GLOBAL_GET` read at
`scene_shader_raytracing.cpp:690` guarded with `false &&` so the flag can
never be set, forcing every RT pipeline to compile with the transmission
branch permanently spec-constant-folded false — then reverted afterward
(`git checkout` + rebuild back to HEAD; `git status --short` confirmed clean
of any source diff beyond the user's own six `pipeline_references` files,
both immediately after the revert and at the end of this task).

| Build | Run 1 | Run 2 | Run 3 | Run 4 |
|---|---|---|---|---|
| ON (HEAD) | 1.2031 | 1.0629 | 1.0976 | 1.0866 |
| OFF (forced) | 1.1617 | 1.0931 | 1.0753 | — |

ms/frame, BEST-of-3-internal-passes per run. Mean ON = 1.11255 ms/frame
(σ_ON ≈ 0.0538, n=4, ~4.8% of mean). Mean OFF = 1.11003 ms/frame (σ_OFF ≈
0.0373, n=3, ~3.4% of mean). **Delta = +0.0025 ms/frame (+0.23%).**

**+0.23% is a point estimate, not the finding.** Corrected in the E1 final
fix wave: this section previously stated the bound backwards, reading the
point estimate itself as if it were already the honest number. It understates
the actual uncertainty. Combining the two run-to-run standard deviations
(Welch-style, unequal n and unequal variance: SE = sqrt(σ_ON²/n_ON +
σ_OFF²/n_OFF) = sqrt(0.0538²/4 + 0.0373²/3) ≈ 0.0345 ms/frame) puts the 95%
confidence interval on the delta at **roughly ±6.8%** of the ON-build mean —
almost 30× wider than the +0.23% point estimate itself. **A real 3-4% frame-
time cost from this branch would be statistically invisible at this sample
size**: it sits well inside that ±6.8% band, indistinguishable from zero
given only n=4/n=3 runs. Reported as measured, not rounded up to a claim of
precision it cannot support: at this scene size and resolution, the register-
pressure cost of leaving the transmission closure compiled in (but disabled
via specialization constant) is **not distinguishable from run-to-run driver/
thermal noise** at this sample size — a real number, and the honest number,
even though it is not the precise percentage the brief's phrasing might
suggest one would find. A larger or more RT-hardware-bound scene, or simply
more runs (this measurement's n=3/n=4 is what makes the interval this wide),
could still show a resolvable delta; this measurement bounds it at "not
resolved by four ON and three OFF runs, could plausibly be a few percent,"
not "zero."

### 7.3 Blender cross-check: F0 arbitration

Headless: a `StandardMaterial3D` with `ior = 1.33` (non-default), `specular_factor
= 0.6` (non-default; default 1.0), `specular_tint = (0.8, 0.9, 1.0)` (non-white,
sRGB-authored), and Godot's native `metallic_specular` **left at its 0.5
default** (see the Task 7 trap note below), exported via
`GLTFDocument.append_from_scene` + `write_to_filesystem`, imported into Blender
4.5 headless (`bpy.ops.import_scene.gltf`), read back from the Principled
BSDF, and run through Cycles' own arbitration
(`kernel/svm/closure.h:426-434` -- note the range: the driver script
originally transcribed only `:426-431`, dropping the `if (ior < 1.0f) eta =
1.0f / eta;` tail, which is defect F1) to compute
`F0`/`eta`. Cross-checked a second way, independent of the Blender round trip:
this engine's own `resolveDielectricF0` (`brdf_inc.glsl:477-493`) read back
live via debug vis modes 30/31 on a `StandardMaterial3D` carrying the exact
same four values.

| Parameter | Godot source | glTF JSON | Blender import | Cycles/ours F0 | Verdict |
|---|---|---|---|---|---|
| `ior` | 1.330000 | `ior: 1.33` | IOR 1.330000 | eta re-derives to 1.246451 (Cycles only — see below) | round-trips exactly |
| `specular_factor` | 0.600000 | `specularFactor: 0.6` | Specular IOR Level 0.300000 | matches spec's documented `0.5 × specularFactor` mapping exactly | round-trips exactly |
| `specular_tint` | (0.8, 0.9, 1.0) sRGB | `specularColorFactor` (linear) | Specular Tint (0.603827, 0.787412, 1.0) | — | round-trips exactly (sRGB↔linear both ways) |
| resolved F0 | — | — | Cycles: (0.007267, 0.009477, 0.012036) | Ours (vis mode 30, GPU-read): **(0.007267, 0.009477, 0.012036)** | **exact match, all 6 decimals, both derivations** |
| resolved eta | — | — | Cycles: **1.246451** (re-derived, `specular_ior_level 0.3 ≠ 0.5`) | Ours (vis mode 31, GPU-read, AT THE TIME OF TASK 8): 1.330000 (unchanged — `ior`). **Fixed by the E1 final fix wave (F3, below): now re-derives to 1.246451, matching Cycles.** | **FIXED — was "diverges from Cycles, by design," now matches** |

**F0 matches Cycles exactly** — both by hand-computing `resolveDielectricF0`'s
formula and by reading it straight off the GPU via vis mode 30, confirming
Phase E1's F0 arbitration (design spec §3.2) is correctly implemented and
correctly round-trips through a real glTF export/Blender-import cycle, not
just against this repo's own fixtures.

**UPDATE, E1 final fix wave: `eta`'s divergence from Cycles here is fixed
(F3), not permanent by-design behavior as this section originally
concluded.** The paragraph below is preserved as the historical record of
Task 8's finding; it was accurate for `83161b784f` and is superseded by F3
in §7.5. `resolveDielectricF0`'s re-derivation gate now triggers on
`specular != 0.5 || specular_factor != 1.0`, not `specular` alone. For
exactly this fixture (`ior 1.33`, `specular_factor 0.6`, `specular` left at
its 0.5 default), the gate now fires on `specular_factor`, and by the same
hand computation Task 8 used against Cycles: `f0_untinted = F0_from_ior(1.33)
* 0.6 * 1.0 = 0.020059 * 0.6 = 0.012035`; `eta = ior_from_F0(0.012035) =
(1+sqrt(0.012035))/(1-sqrt(0.012035)) = 1.246451` — matching Cycles' figure
in this same table to the displayed precision. (This is the hand-derivation
that motivated the fix, not a re-run of the headless Blender/glTF round trip
above; re-running vis modes 30/31 on the identical fixture to confirm the
GPU read is part of this fix wave's own verification pass, recorded in
`.superpowers/sdd/2026-08-19-transmission-rough-glass/final-fix-report.md`.)

**`eta` did not match Cycles here at `83161b784f` — deliberately, per the
design at the time.** [Historical, superseded by F3 above.]
`resolveDielectricF0`'s eta re-derivation was gated on Godot's *native*
`specular` parameter only -- the line then read
`eta = (specular != 0.5f) ? ior_from_F0(luminance(F0)) : ior;` (no longer
present at any line; see `3ce2f822a8` for the removal, and
`brdf_inc.glsl:484-490` for what replaced it) -- and not on
`specular_factor`/`specular_tint`. This fixture varies only `specular_factor`
(the glTF-round-trippable knob) and leaves `metallic_specular` at its 0.5
no-op point, so `eta` stayed pinned to the raw `ior` — matching the design
spec's formula verbatim (§3.2) as it stood at the time, and independently
asserted by the gate's probe 2 as it stood at the time
(`pt_transmission_gate.gd`, since updated by this fix wave: *"eta must stay
at the untouched ior... the re-derivation... only fires when specular !=
0.5, and specular was not touched by this fixture"*). Cycles has no such
split: its single `specular_ior_level` knob absorbs what our engine keeps as
two independent parameters (`specular_factor` from glTF, `specular` native),
and re-derives eta whenever *that* knob leaves 0.5 — which the glTF round
trip does, at `specular_ior_level = 0.3`. **Consequence, as it stood before
this fix wave: for any glTF-imported glass material with a non-default
`specularFactor` (the normal case for Blender-authored content, since Phase
D's own worked example used exactly this), our F0 matched Cycles' at normal
incidence but our TIR/refraction angle (which depends on `eta`, not `F0`)
did not, because Cycles re-derives its IOR from the tinted F0 and we did
not.** That was not a defect Task 8 introduced or newly discovered — the
design spec itself specified the narrower gate — but it had not previously
been cross-checked against a *real* Blender round trip, only against this
repo's hand-written fixtures. §3.2 of the spec is the origin of the gap: it
already documented `specular_factor -> specular_ior_level = 0.5 *
specular_factor` (used in the table above) without drawing the conclusion
that this makes `specular_factor` a second, independent trigger for Cycles'
own `specular_ior_level != 0.5` re-derivation condition — a spec-vs-Cycles-
source gap, not an implementation bug, which is why the final review wave
that produced F1/F2/F3 re-read `kernel/svm/closure.h` directly rather than
trusting the spec's transcription of it.

**Trap avoided (found in Task 7, reused here):** `StandardMaterial3D.specular`
is not a real property — the GDScript-visible name is `metallic_specular`
(`scene/resources/material.cpp:3768`); writing `.specular` silently no-ops via
Godot's legacy 3.x-remap `_set()` path.

### 7.4 Open items carried to E2

**From the design spec (§9), verbatim intent, restated with this phase's
measurements attached where relevant:**

- **NEE and the BSDF strategy use different Fresnel formulations on
  transmissive surfaces** (spec §6.4). NEE evaluates Schlick with no
  `pdf_reflect` factor; the BSDF strategy realises the remapped real Fresnel
  scaled by `1/pdf_reflect`; `combinedPdf`'s density matches the closure, not
  NEE. Same structural class as B2's open +2.4% converged-mean defect. **The
  highest-value correctness item E2 inherits.** §7.1's Cycles comparison could
  not cleanly separate this contribution's magnitude from §6.1/§6.3 and the
  newly-found environment-lighting gap (§7.1's attribution paragraph) — a
  longer, source-ablated convergence run is needed to give this a number on
  its own, and is left for whoever picks this up next.
- **Opaque and transmissive materials use different Fresnel formulations at
  all** (spec §4.2's dispatch on `transmission > 0`) — deliberate, bought to
  protect existing renders from a reflectance change at every specular
  surface. Unifying it and re-baselining is E2's call, not a bug to fix
  reactively.
- The transmissive lobe is single-scatter (§6.3: `evalMultiScatterApproximation`
  is reflection-only) — slightly dark at high roughness, same limitation
  Cycles has.
- NEE through refractive lobes is unimplemented (§6.1) — rough glass is
  noisier than Cycles at equal sample count; this is a convergence-rate gap
  measured by §7.1, not a bias.
- Nested/overlapping media are unsupported (§5.4) — the absorption mechanism
  reads the exit hit's own material and `gl_HitTEXT` as path length, which is
  exact for one closed mesh and wrong for interpenetrating transmissive
  volumes.
- Shadow rays are still blocked by glass, so there are no caustics (§6.2) —
  matches Cycles without its caustics path.
- ~~`resolveDielectricF0`'s `eta` re-derivation is gated on Godot's native
  `specular` only, not `specular_factor`/`specular_tint`~~ **FIXED by the E1
  final fix wave (F3) — see §7.5.** This was not, on inspection, a legitimate
  design choice left for E2 to revisit: the design spec's own §3.2 already
  documented the `specular_factor -> specular_ior_level = 0.5 *
  specular_factor` mapping this fix relies on, and Cycles' source
  (`kernel/svm/closure.h:425-435`) re-derives whenever `specular_ior_level !=
  0.5` with no carve-out for which knob moved it there. `specular_tint` is
  correctly excluded from the gate in both the old and new code — that part
  of the original phrasing was accurate and remains true after the fix
  (§7.5's F2 below is the reason why: tint must not reach `eta` at all,
  gated or not).

**Two defect classes are undetectable by a rendered MEAN, at any sample count
or scene, which is why the gate carries dedicated vis-mode detectors (32 and
33) instead of relying on convergence alone:**

*(Heading corrected in the E1 final fix wave, doc-fix list item 7: this
previously said "undetectable by any rendered image," which overstates the
first bullet below and is not what its own body claims. The body's precise,
verified claim is "mean-preserving by construction" — that is a statement
about the MEAN, not about the image. A `combinedPdf` desync still changes the
MIS weights' relative VARIANCE, which is visible as a noise-level difference
in a rendered image at finite sample count, just not as a shift in what that
image converges to. The heading now says what the body actually proves.)*

- A `combinedPdf` lobe-probability desync (Task 5/6's defect a) is
  **mean-preserving by construction** — MIS is unbiased for any set of
  weights summing to 1 pointwise, and `combinedPdf` appears only inside such
  weights (never as an estimator divisor). No rendered mean, at any sample
  count or scene, can ever detect it; vis mode 32 reads `combinedPdf`'s and
  the sampler's own lobe probabilities side by side, calling the same
  production functions on both sides. (This does not extend to variance: a
  desync still shifts the noise level at finite samples. Vis mode 32 doesn't
  need that weaker, noisier signal because it reads the two densities
  directly.)
- The hemisphere-guard-ordering defect (Task 5/6's defect c) is
  **deterministically suppressed** rather than noise-buried: the transmit
  branch clamps `NdotL` to `-1e-5` (`brdf_inc.glsl:1137`) and
  `Smith_G2_Over_G1_Height_Correlated` goes to ~0 as `NdotL → 0`, so every
  sample the guard would reject already carries weight ~1e-5 regardless of
  whether the guard fires. Vis mode 33 accumulates the raw rejection rate
  before any weight is applied, sidestepping that clamp entirely.

**Vis mode 33's detector only exercises `eta > 1` (entering a medium), the
half of the guard that is provably unreachable by theorem** (`sampleGGXVNDF`
returns `H.z ≥ 0`, and for `eta > 1` that forces `L.z < 0` strictly — `wrongN`
cannot fire). Its whole nonzero signal in the gate comes from `wrongNg`
firing off normal-map divergence, not from the branch it was named for. **The
guard *is* live code for `eta < 1`** — exiting a dense medium, production's
back-face case (`raytracing_closest_hit_common_inc.glsl:854`) — where it was
shown to fire on ordinary flat geometry at roughness ≳ 0.5. Do not read
detector 2's narrow coverage as evidence the guard is dead code; it is dead
only on the half detector 2 happens to reach.

**An unexplained shader regression, found only by this phase's own gate.**
Mid-phase, an uncommitted production refactor (extracting
`combinedPdfLobeProbability`/`samplerLobeProbability` as shared helpers)
broke the transmissive path — doctest (1511/1511), all four opaque gates, and
the validation mean all passed through it clean; only `pt_transmission_gate`
caught it (probe 6 read 5.042604 against a 4.2 high bound, a correct-code
reference of 4.069). The implementer's working theory (chained GLSL
out-parameters mis-compiling) was **disproved by the shipped fix itself**,
which still contains a structurally identical two-level out-parameter chain
and works correctly — and the pattern the fix adopted (`evalIndirectCombinedBRDF`
passing its own out-parameter straight into `sampleSpecular`) has shipped
correctly for phases. A plain authoring error in `isTransmit` propagation is
at least as likely a cause. The broken version was never committed, so the
hypothesis is now untestable. **Recorded as unexplained; no cause is
asserted.** The finding that matters is structural, not the root cause: four
previously-clean checks (suite, three opaque gates, validation mean) all
passed through a real, live break in the transmissive path, and only the
gate purpose-built for this phase caught it.

**New, standalone (not E1-specific) open item found while building this
task's own measurement harness:** this engine's environment-lit diffuse
response reads **~23% dimmer than Cycles under a matched HDRI**, reproduced
on a scene with zero glass objects (§7.1's no-glass control). Root cause not
chased at the time this paragraph was first written. **A dedicated four-probe
gate has since measured the engine side of it — see §7.6.** That gate
eliminates a uniform exposure-scalar cause (probe A is bit-exact at 1.00000
and probe D reads `IBL_exposure_normalization` at exactly 1.000000), and it
demonstrates no energy loss at all at high radiance-map resolution (−1.6%
against an analytic hemispherical-irradiance ground truth).

**RESOLVED (2026-08-22) — see §7.7. This was a comparison-harness
colour-space error, not an engine defect.** §7.1's Cycles reference scene
copied `StandardMaterial3D.albedo_color` RGB triples straight into Blender's
Principled BSDF `Base Color` field-for-field. Godot's `albedo_color` is
sRGB-authored and is converted to linear on RT upload; Blender's `Base Color`
is already linear. The same numeric triple therefore fed the two BRDFs two
different reflectances, and §7.7's independently-confirmed three-arm Cycles
experiment shows that mismatch alone is large enough, and in the right
direction, to produce the observed whole-image gap once blended with
albedo-independent sky pixels. Neither renderer's physics is at fault. **No
engine change is proposed or needed for this item.**

*(Erratum history, itself now superseded. An earlier version of this
paragraph declared the two candidates below superseded on the strength of a
§7.6 result that was wrong — the gate's analytic ground truth omitted an
sRGB albedo pre-encode. A later revision then restored both candidates as
open on the strength of the corrected §7.6 data. §7.7's confirmed experiment
supersedes that revision in turn: the ~23% whole-image gap did not originate
in the engine at all, so neither candidate below is needed to explain it.
§7.6's own resolution-sensitivity finding is untouched by any of this — it is
a real, separately-measured, ground-only result on its own analytic ground
truth, unaffected by the comparison-harness question — and is restated below
as what it actually is: a minor, still-open aliasing item, not a cause of the
23%.)*

- **HDRI resolution/filtering loss during octahedral-map conversion — NOT
  NEEDED to explain the ~23% gap (§7.7).** What §7.6 measured under this name
  is still real and still worth tracking on its own terms: the low-resolution
  radiance map reads +8.5% **high** (not low) at `RADIANCE_SIZE_256` on a
  deliberately sub-texel bright-band stimulus — an aliasing overshoot, not an
  energy loss — resolving to −1.6% at `RADIANCE_SIZE_2048`. That is a genuine
  resolution-sensitive response; it was never the mechanism behind the 23%,
  and §7.6's own caveat already warns it is not shown to generalize beyond
  the adversarial probe that found it.
- **Pre-existing environment-NEE energy behaviour already catalogued
  elsewhere in this document — NOT NEEDED to explain the ~23% gap (§7.7),**
  for the same reason. Still untouched and unmeasured in its own right; §7.6
  measures the panorama→render chain end-to-end and cannot separate an NEE
  contribution from the BSDF-strategy one, so this remains an uncatalogued-
  magnitude observation, not evidence of anything contributing to the 23%.

This item no longer needs anyone to pick it up as an engine investigation —
see §7.7 for the closing evidence. The one piece of real follow-up work left
behind is §7.6's resolution-sensitivity finding (+8.5% at `RADIANCE_SIZE_256`
on a sub-texel stimulus); whoever picks *that* up should start from §7.6
directly and read its caveat about probe C's adversarial stimulus before
treating the number as a statement about behaviour under a real, broadband
HDRI.

**Parked backlog item, still open, untouched by this phase:** glTF **export**
still writes `sheenColorFactor`, `specularColorFactor`, `attenuationColor`
unclamped (Phase D open item, restated in the E1 spec §2). E1 clamped
`attenuation_color` at the *RT upload* site only (spec §5.2), closing the
rendering-side energy-creation risk; the export-side spec-invalidity risk is
unchanged.

**Phase D residuals, still open:** `anisotropy` is signed in Godot with the
sign encoding a 90° rotation that glTF export drops with a warning
(unresolved from Phase D); the custom-hit-group `debug_visualize` path
remains compile-verified only, never executed by any scene in this repo.

**Lobe selection is still two-way** (diffuse vs. dielectric-microfacet, spec
§3.5) — E2 owns the N-way rewrite for anisotropy/clearcoat/sheen.

**The next item is Phase E2** (anisotropy, clearcoat, sheen), which inherits
the Fresnel-formulation-mismatch item above as its highest-value correctness
target alongside its own scope.

### 7.5 E1 final fix wave — F0/eta arbitration corrections (F1, F2, F3)

**The single fix wave applied after §7.1–§7.4 were written, before the branch
was presented for integration.** The final whole-branch review found three
fidelity gaps in `resolveDielectricF0` (`brdf_inc.glsl`). **All three
originate in the design spec, not in any implementation** — the spec quotes
Cycles' `kernel/svm/closure.h:426-431` and diverges from the actual function
(`:425-435`) three ways. Fixed here; F0/eta at every default (`ior 1.5`,
`specular 0.5`, `specular_factor 1.0`, white tint) is confirmed unchanged —
still exactly `F0 = vec3(0.04)`, `eta = 1.5` — so this wave moves no pixel on
any pre-existing content, same guarantee E1 itself made.

- **F1 — dropped statement.** The spec's quoted block ends one statement
  early. Cycles' actual block ends `if (ior < 1.0f) { eta = 1.0f / eta; }`
  (`closure.h:432-434`) after re-deriving eta from F0. `ior_from_F0` always
  returns `>= 1`, so for `ior < 1` (authorable — `material.cpp`'s ior hint is
  `"0,3,0.001,or_greater"`) the un-flipped eta landed on the wrong side of 1.
  Restored.
- **F2 — tint was leaking into eta.** Cycles keeps `f0`/`eta` derivation and
  `specular_tint` completely separate: `eta = ior_from_F0(f0)` uses the
  UNTINTED scalar `f0` (`closure.h:429-431`); `specular_tint` multiplies in
  only afterward, at `closure.h:453`, where it can no longer reach `eta`. The
  previous code folded `specular_tint` into F0 first and took `luminance()`
  of the tinted result for eta, so the tint's luminance leaked into the
  refraction/TIR angle. Restructured so eta is derived from the untinted
  scalar and tint is applied to F0 only, after.
- **F3 — gate too narrow.** Cycles re-derives whenever its single
  `specular_ior_level` knob leaves 0.5. This engine splits that into two
  independent parameters — Godot's native `specular` and glTF's
  `specular_factor` — and the design spec's own §3.2 already documents
  `specular_factor -> specular_ior_level = 0.5 * specular_factor`, meaning a
  non-default `specular_factor` already implies a non-0.5
  `specular_ior_level` and Cycles re-derives. The previous gate checked
  `specular != 0.5` only, so glTF-imported glass that varies
  `specular_factor` and leaves `specular` at its native default (the normal
  case for Blender-authored content — §7.3's own cross-check fixture is
  exactly this) got a correct F0 and a silently un-re-derived eta. Gate
  widened to `specular != 0.5 || specular_factor != 1.0`.

**Measured magnitude, §7.3's own fixture** (`ior 1.33`, `specular_factor
0.6`, `specular` left at 0.5): eta now re-derives to **1.246451**, matching
Cycles exactly (§7.3's table, now marked FIXED) — against the pre-fix
**1.330000** (`ior`, unchanged). Critical angle for total internal
reflection moves from **48.8° to 53.4°**, a **4.6° shift** — the direct,
visible consequence of F3 alone (this fixture's `specular_tint` is non-white,
but `specular = 0.5` means F1's flip never engages either, since `ior > 1`
here; F1's own effect is visible only for `ior < 1` fixtures, covered by new
doctest coverage rather than this pre-existing real-material fixture).

**The gate.** `pt_transmission_gate.gd` probe 1/1b (default and non-default-
`specular` fixtures, both with `specular_factor` left at its 1.0 default)
are unaffected — the widened gate does not change their trigger condition.
**Probe 2 legitimately changes**, and does: it fixes `specular` at 0.5 while
varying `specular_factor` (0.62) and `specular_tint`, which is now exactly
the case F3 exists to catch. Its `F0` expectation is unchanged (F2 does not
change the numeric value of F0, only how eta is derived — tint was already
applied to F0 correctly before this fix, just also incorrectly leaking into
eta). Its `eta` expectation moves from the untouched `ior` (1.5) to the
re-derived value (1.373831 — arithmetic shown inline in the gate script and
in `tests/servers/rendering/test_pt_transmission.cpp`'s matching doctest
case). No other probe in this gate, and no fixture in any other gate in this
repo, uses a non-default `specular`/`specular_factor`/`ior < 1` combination,
so nothing else in the standing suite was capable of moving.

**Two related robustness fixes landed in the same wave, unrelated to the
arbitration formula itself:**

- `ior` was unclamped at upload (`render_raytracing.cpp`) while its siblings
  (`transmission`, `thickness`, `attenuation_color`) were already clamped.
  Combined with the back-face `1.0/eta` flip
  (`raytracing_closest_hit_common_inc.glsl`), a negative `ior` on a
  double-sided (`CULL_DISABLED`) transmissive material could reach
  `fresnel_dielectric` as an already-evaluated infinity, violating that
  function's own caller contract (`brdf_inc.glsl:392-395`). `ior` is now
  floored at 0.0 at upload (no upper clamp — the property hint's
  `or_greater` means there is no legitimate one). `ior == 0.0` itself
  remains legal (`KHR_materials_ior` permits it) and is now additionally
  guarded at the flip site itself, since the upload clamp cannot rule it
  out.
- Beer-Lambert absorption (§5, above) was applying to any back-face hit with
  `transmission > 0 && thickness > 0`, with no check that the ray had
  actually travelled through the medium to get there. A double-sided
  material's back face, hit directly by a camera ray, has no such travel —
  `gl_HitTEXT` is the camera-to-surface distance, not a path length through
  glass — and a short `attenuation_distance` read solid black. Now
  additionally gated on `is_inside_medium(ps.packed_bounces_flags)`, which
  is exactly the right signal here (unlike its documented unreliability at
  the eta-flip site above): `set_inside_medium`/`clear_inside_medium` are
  themselves gated on the identical `thickness > 0.0` condition already
  required to reach the absorption line, so there is no thin-walled gap to
  inherit.

**The structural lesson, worth carrying into E2 and beyond.** This phase ran
three separate fix rounds enforcing strict textual identity between the
doctest C++ mirrors and the GLSL — and never once checked either against the
Cycles source both claim to port, until this final wave did. Mirror
discipline caught every C++/GLSL drift it was built to catch; it cannot catch
a divergence both sides agree on, because agreement is exactly what it
measures. All three F1/F2/F3 gaps were invisible to that discipline for the
same reason: the design spec's transcription of Cycles was wrong, both
mirrors faithfully implemented the wrong transcription, and they matched
each other perfectly the entire time. **When a spec claims to port a
specific function from a named external source, the source is the ground
truth to verify against — not the spec's summary of it, and not internal
cross-consistency between a project's own C++ and GLSL copies, however
strictly that consistency is enforced.**

**Recorded, not fixed — carried forward as open items, not defects:**

- **TIR consumes the glossy bounce budget.** When `sampleDielectricMicrofacet`
  samples total internal reflection, `took_transmissive_lobe` comes back
  `false` and the bounce-accounting block (`raytracing_closest_hit_common_inc.glsl`)
  calls `inc_glossy_bounce`, not a transmission-specific counter. A glass
  sphere or gem at grazing angles, bouncing internally via TIR repeatedly
  before finding an exit angle, exhausts `max_glossy` on those internal
  reflections and can truncate the path before it ever gets back out —
  user-visible (a glass object going unexpectedly dark or noisy at its
  silhouette under a tight glossy-bounce budget), not merely academic. Not
  fixed in this wave; currently recorded only in the SDD ledger
  (`.superpowers/sdd/2026-08-19-transmission-rough-glass/progress.md`),
  which does not ship with the engine — recorded here so it does.
- **Metallic + transmissive is not zeroed at upload.** A material with both
  `metallic > 0` and `transmission > 0` is physically nonsensical (a metal
  does not transmit light), and this engine does not reject or clamp the
  combination the way Cycles zeroes it. Traced, not merely assumed: with
  `metalness > 0`, `baseColorToSpecularF0` collapses `dielectricF0` toward
  `baseColor` and the closure still normalises correctly — no NaN, no energy
  leak, just a physically meaningless (rather than broken) render for a
  material combination no sane content would author. Left unfixed
  deliberately; matching Cycles' explicit zeroing is a straightforward small
  follow-up if it turns out to matter for imported content.
- **The transmit branch's `NdotL` clamp to `-1e-5` (`brdf_inc.glsl:1137`) is
  load-bearing, intentional code — not a wart or a leftover to clean up.**
  §7.4's "deterministically suppressed" guarantee for the hemisphere-guard-
  ordering defect (Task 5/6's defect c) depends on this exact clamp: it is
  what keeps every sample the guard would have rejected at weight ~1e-5
  regardless of whether the ordering guard fires, which is why that defect
  class could never be caught by a rendered mean and needed vis mode 33
  instead. It is currently filed in the SDD ledger as a "deferred minor,"
  phrasing that invites a future pass to "fix" it as unfinished work. It is
  not unfinished; it is a deliberate numerical floor with a specific job.
  Recorded here, explicitly, as intentional.

**One correction to the SDD ledger, checked against this document and NOT
found here (so nothing in this file needed changing for it):** the ledger
records that its own "NEE shadow rays traverse in-medium segments" concern
(Task 6's M5) was overstated and self-corrected mid-phase — shadow rays never
had back-face culling (`raytracing_lights_inc.glsl` uses only
`gl_RayFlagsTerminateOnFirstHitEXT | gl_RayFlagsSkipClosestHitShaderEXT`), so
they are, and always were, blocked by the far wall of a closed transmissive
mesh, consistent with this document's own §7.4 note that shadow rays are
blocked by glass with no caustics path. That overstatement was never
transcribed into this roadmap in the first place — it exists only in the
ledger, where it has already been corrected — so there was nothing here to
fix.

### 7.6 E2a - environment energy: what was measured

**Follows up §7.4's ~23%-dimmer-than-Cycles item (since resolved as a
comparison-harness artefact, not an engine defect — see §7.7; this section's
own probe results below are unaffected by that resolution and stand on their
own).** `pt_sky_energy_gate.gd`
runs four probes against a scene built directly from the source panorama
image — never from another render — so nothing here can be faked by a global
sky scale.

**Read the erratum at the end of this section before citing any earlier
version of it.** This section's first draft concluded MECHANISM B and
reported roughly half the energy missing. That conclusion was **wrong**: the
gate's analytic ground truth omitted the sRGB albedo pre-encode the RT
material upload applies. The numbers below are the corrected measurement,
taken on `vijay_PTEngine_v12_PhaseE` after the fix.

| Probe | What it isolates | Result |
|---|---|---|
| A — constant sky, sky-only | Mechanism A: a scalar dimming the sky uniformly, independent of angular content | ratio **1.00000** (bit-exact) |
| B @ `Sky.RADIANCE_SIZE_256` | Peaked sky vs. an analytic irradiance integral computed from the panorama image | ratio **1.08484** — measured 0.34364 vs. analytic 0.31676 (**+8.5%**) |
| B @ `Sky.RADIANCE_SIZE_2048` | Same, at 8x the radiance-map linear resolution | ratio **0.98354** — measured 0.31155 vs. analytic 0.31676 (**−1.6%**, inside the 2% tolerance) |
| C — resolution shift (B moved between the two sizes above) | Whether the response depends on radiance-map resolution at all | **9.338%** (tolerance 2%) |
| D — `IBL_exposure_normalization`, read off the GPU via vis mode 34 | Names Mechanism A's scalar directly, rather than inferring it from a ratio | **1.000000** (exact) |

The realtime-clamp warning (`sky.cpp:593-595` force-clamping a `REALTIME`
sky's radiance map to 256 and logging it) did not appear at either size —
`sky.process_mode` was `QUALITY` throughout, so both radiance sizes genuinely
took effect and probe C's comparison is not confounded by a silently-clamped
second measurement.

**Finding 1 — `IBL_exposure_normalization` is eliminated as a cause.** Probe
A reads 1.00000 bit-exact under a constant sky: the sky pass, the radiance
octmap, the miss shader, MIS weighting and the accumulator are provably exact
together with zero angular detail in the source. Probe D corroborates it
directly — the one scalar Cycles has no counterpart for reads exactly
1.000000. Neither a uniform post-multiply nor the exposure normalization can
account for any part of the ~23% gap.

**Finding 2 — no energy loss is demonstrated anywhere in this measurement.**
At `RADIANCE_SIZE_2048` the engine reproduces the analytic hemispherical
irradiance to **−1.6%**, inside the gate's own 2% tolerance. There is no
missing energy to attribute at that resolution. The engine-side "the radiance
map loses energy" hypothesis is **not supported by this data**.

**Finding 3 — the low-resolution response is HIGH, not low, and raising the
resolution IMPROVED accuracy.** At `RADIANCE_SIZE_256` the response is
**+8.5%** above ground truth. Going to `RADIANCE_SIZE_2048` moves it to
−1.6% — from an 8.5% error to a 1.6% one. That is an aliasing **overshoot**
on a deliberately sub-texel stimulus being resolved away by a finer map, the
exact opposite of the "coarse map averages the band away, so it reads dim"
account. Raising the radiance-map resolution therefore **helps**; the
previous version of this section claimed this measurement ruled that option
out, and it does not.

**Finding 4 — the verdict rule fired, and its label does not survive the
corrected data.** `_print_verdict()`'s rule (`a_off = |A - 1| > TOLERANCE`,
`res_sensitive = C > TOLERANCE`) selects on resolution sensitivity alone, so
with C at 9.338% it printed **MECHANISM B — "energy is lost in the map."**
The rule fired correctly on its own terms; the *label* is wrong for what was
measured. C only shows the response *depends on* resolution. Its sign says
the low-resolution map reads too BRIGHT, and the high-resolution one is
accurate. "Lost energy" describes neither endpoint. Probe C's relative shift
survives the albedo fix essentially unchanged (9.475% before, 9.338% after)
because the albedo error cancelled in a ratio of two measured means — only
its interpretation changes.

**The ~23% gap versus Cycles is RESOLVED — see §7.7 — and nothing in this
gate turned out to be the explanation.** Nothing in this gate reproduces a
~23% uniform dimming, and §7.7's confirmed follow-up experiment shows nothing
here needed to: the whole-image gap was traced to a comparison-harness
colour-space error in the original Cycles reference scene, independent of
anything this gate measures. §7.4 carries the resolution. What this gate does
establish stands on its own regardless: the engine reproduces analytic
hemispherical irradiance to −1.6% at `RADIANCE_SIZE_2048`, and the
radiance-map response is resolution-sensitive, reading +8.5% high at
`RADIANCE_SIZE_256` on a deliberately sub-texel stimulus — a real, separate,
still-open aliasing item, not a cause of the 23%.

**Caveat — probe C's stimulus is adversarial and licenses no claim about a
real HDRI.** `_banded_panorama(1)` paints ONE texel row out of 1024, at
radiance 200 against a 0.02 base; that single row carries ~97% of the
hemispherical irradiance. Its angular width (PI/1024) is far below one
256px-octmap texel (PI/256 at best), so whether a point sampler lands on it
is close to a coin flip. This is a worst-case sub-texel aliasing probe,
chosen to make a filtering difference visible at all. **It does not
generalize**: a broadband HDRI has no such structure, and the +8.5%/−1.6%
figures must not be read as predicting the sign or magnitude of any error
under one, nor as explaining a uniform 23% gap — which §7.7 has since shown
originates outside the engine entirely and needs no probe here to account for
it.

**Erratum — why the first conclusion was wrong.** The gate authored
`mat.albedo_color = Color(0.5, 0.5, 0.5)` and its analytic model assumed the
BRDF saw a linear reflectance of 0.5. The RT material upload
(`render_raytracing.cpp:1540-1542`) reads `albedo` back and runs it through
`srgb_to_linear()`, so the BRDF actually saw `srgb_to_linear(0.5) =
0.214041` — 42.8% of the authored value. That single colour-space round trip
accounts for the whole "roughly half the energy" reading: `0.214041 / 0.5 =
0.428082` against a measured 0.42785 at `RADIANCE_SIZE_2048`, a 0.054%
match. **The sibling gate documented this exact trap by name**
(`pt_energy_gate.gd:562-568`, with the comment "This trap cost real debugging
time once; do not 'simplify' it away") and pre-encoded with
`.linear_to_srgb()`; this gate was written without that line. The fix wave
added the pre-encode, and also zeroed `metallic_specular` — the gate had set
`specular_mode = SPECULAR_DISABLED`, which is a **no-op on the path-tracing
path** (`BaseMaterial3D` emits it only as a spatial-shader `render_mode`
token), leaving a live F0 = 0.04 dielectric lobe the Lambertian analytic
model does not account for. The lesson is procedural, not numeric: a gate
whose ground truth is computed rather than measured must be validated against
the engine's *upload* path, not just its integrator, before its verdict is
recorded as a finding.

**Observation for a future phase (no fix proposed).** The environment NEE CDF
grid is hardcoded at `ENV_N_U 256` / `ENV_N_V 128`
(`raytracing_env_sampling_inc.glsl:39-40`, and independently as `N_U 256` /
`N_V 128` in `env_cdf_build.glsl:22-23`). Those constants do **not** scale
with `Sky.radiance_size`, so the importance-sampling distribution stays at a
fixed 256x128 resolution while the radiance map it samples can be eight times
finer. Recorded as an observation only; whether it contributes to anything
measured above has not been tested.

**`pt_energy_gate` Gate 1 remains green and is not evidence about any of the
above.** It is a RATIO test — `L_o` measured against `ALBEDO * l_sky` where
`l_sky` is itself measured from the same render (`pt_energy_gate.gd`:206,
:222) — so a uniform loss upstream of both measurements cancels exactly and
the gate is structurally blind to it, exactly as its own header already says.
Its green status covers integrator correctness given whatever radiance the
renderer sees; it does not, and was never designed to, cover whether that
radiance is right.

### 7.7 The 23% gap — CONFIRMED: comparison-harness colour-space error, not an engine defect

> **ERRATUM / CONFIRMATION (2026-08-22).** This section originally recorded
> the mechanism below as a hypothesis, explicitly untested, with an
> instruction not to treat it as a finding. It has since been tested with an
> independent three-arm Cycles experiment run against the same analytic
> ground truth §7.6 uses (full scripts, logs, and verification in
> `.superpowers/sdd/2026-08-21-environment-energy-fidelity/cycles-hypothesis-report.md`),
> and the hypothesis **holds**. The ~23% whole-image dimming this project has
> carried since Phase E1 as its largest known fidelity gap was a
> comparison-harness material-transcription error, not a defect in either
> renderer's physics. **No engine fix is proposed here — there is nothing to
> fix.** Read "What this experiment does NOT establish," below, before citing
> this section elsewhere: the confirmed result is narrower than the original
> 23% figure, and two supporting claims (the sky/ground split, the original
> scene's crop composition) remain unconfirmed.

**The mechanism (unchanged from the original hypothesis, now confirmed).**
E1 Task 8's Cycles comparison built its Blender scene by mirroring
`pipeline_references/tests/pt_transmission_reference.gd`'s `_build_scene()`
"field-for-field" (the phrase is that task's own report's). That includes
copying literal RGB triples into both engines' material colours. But the two
engines do not treat those triples the same way: `StandardMaterial3D`'s
`albedo_color` is authored sRGB, and the RT material upload converts it to
linear before the BRDF ever sees it —

```cpp
// render_raytracing.cpp:1538-1542
// Colors declared with source_color in Godot shaders are stored in sRGB;
// material_get_param returns the raw sRGB value, so we convert to linear here.
Variant albedo_var = material_storage->material_get_param(p_material_rid, "albedo");
if (albedo_var.get_type() == Variant::COLOR) {
    Color c = ((Color)albedo_var).srgb_to_linear();
```

Blender's Principled BSDF `Base Color` is LINEAR — no such conversion happens
on the Cycles side. Copying the same numeric triple into both `albedo_color`
and `Base Color` therefore gives the two renderers DIFFERENT reflectances,
not the same one.

The reference scene's ground plane is authored `Color(0.55, 0.55, 0.55)`
(`pt_transmission_reference.gd:118`, the `_add_box` call that builds the
ground). Under the conversion above:

| Side | Authored | BRDF sees (linear) |
|---|---|---|
| Godot (sRGB) | 0.55 | 0.263273 |
| Blender (linear) | 0.55 | 0.55 |

ground-only dimming ratio = 0.263273 / 0.55 = **0.478679**

To make the two agree, the Godot side would need the ground authored at
**0.767376 sRGB** — which decodes to linear 0.55, matching Blender's Base
Color directly.

**The confirming experiment.** Rather than rebuilding the deleted original
Task 8 harness (see below), the confirming test built a *new* Cycles scene
mirroring `pipeline_references/tests/pt_sky_energy_gate.gd`'s own geometry
and lighting — flat Lambertian plane with its specular lobe removed,
equirectangular environment, camera framing only ground-plane pixels — and
compared it against the SAME analytic ground truth that gate uses,
independently, on three arms:

| Arm | Base Color (linear) | Measured/Analytic — P1 (constant) | Measured/Analytic — P2 (banded) |
|---|---|---|---|
| ARM 1 "reconciled" — what Godot's BRDF actually sees for authored `Color(0.55, 0.55, 0.55)` sRGB | 0.263273 | 1.000000 | 0.999991 |
| ARM 2 "field-for-field" — what the original harness put into Blender directly | 0.55 | 1.000000 | 0.999989 |

**ARM 3, positive control:** the ARM1/ARM2 measured ratio (0.478678, both
panoramas) matches the predicted ground-only dimming ratio
(0.263273/0.55 = 0.478679) to **six significant figures**.

**What this establishes:**

- Cycles individually reproduces analytic ground truth on this quantity to
  within 0.011%.
- This engine individually reproduces the same analytic ground truth to
  −1.6% (already recorded in §7.6, `RADIANCE_SIZE_2048`).
- **Both renderers are therefore individually correct.** The 0.478679
  ground-only factor is real physics on both sides, not a harness artefact —
  ARM 3's positive control is what rules out the harness itself introducing a
  bias: if the harness's material linearity, panorama radiometry, or crop
  measurement carried their own bias, ARM1/ARM2 would not reproduce the
  predicted ratio to six figures.
- **Conclusion: the ~23% gap originated in the comparison harness's material
  transcription, not in either renderer's physics. It was never an engine
  defect.**

**What this experiment does NOT establish — read these limits before citing
this section elsewhere:**

- This experiment measured a **ground-only** quantity. The original 23%
  figure was a **whole-image** mean mixing ground pixels (albedo-dependent)
  with sky pixels (albedo-independent — §7.6's probes A and D separately
  confirm the sky-scalar path is clean, at 1.00000 and 1.000000
  respectively).
- A field-for-field transcription produces a **52.1% ground-only dimming**
  (`1 − 0.478679`), more than double the 23% whole-image figure. That is
  comfortably large enough, in magnitude, to produce a 23% whole-image gap
  once blended with unaffected sky pixels — but the actual sky/ground blend
  of the original scene's crop was **not independently measured** by this
  experiment.
- The 56% sky / 44% ground split below was solved from one equation in two
  unknowns and remains **NOT independently confirmed**. This experiment does
  not confirm it — it confirms only that a split of that required magnitude
  (44% ground) is achievable, not that it is what the original scene's crop
  actually had.
- The original scene's crop composition
  (`pt_transmission_reference.gd`'s actual camera framing) was **not
  re-measured**.

**State the evidential limit honestly.** The observed whole-image control
ratio (Godot / Cycles) was **0.7712**. Solving for a shared sky contribution
`S` and a Cycles-side ground contribution `G` from the two-equation system

```
S + 0.478679*G = 0.181181
S +          G = 0.234934
```

gives `S = 0.13182`, `G = 0.10311` — a 56% sky / 44% ground split — and
reproduces 0.7712 exactly. **That exact reproduction is NOT independent
evidence**: it is two unknowns solved from one equation (plus the definition
`S + G = 0.234934`), and a system with as many free parameters as data points
will always fit. What it does show is that the hypothesis requires a
sky/ground split that is plausible for the scene's camera framing, and it
explains why the three channel ratios (0.7712 / 0.7724 / 0.7752) are nearly
identical: a neutral-grey ground contributes the same fractional error to
every channel. The confirming experiment above adds independent evidence that
the 0.478679 ground-only factor itself is real and not a harness artefact; it
does **not** add independent evidence for this particular 56%/44% split (see
"What this experiment does NOT establish," above).

**A test that would still settle the split specifically.** Re-run the
original Task 8 comparison with the Godot ground authored at 0.767376 sRGB
(or, equivalently, with the Blender Base Color set to 0.263273 linear) and
check whether the whole-image gap closes. The original EXR reference and
driver scripts were deleted (Task 8's report, section 4), so this still
requires rebuilding that harness; the scripts needed to do so are reproduced
verbatim in
`.superpowers/sdd/2026-08-19-transmission-rough-glass/task-8-report.md`. This
re-run was **not** performed as part of confirming the hypothesis above — the
confirming experiment used a new, independent furnace-test scene instead
(built from `pt_sky_energy_gate.gd`'s geometry, not Task 8's), whose own
driver scripts and full log are in
`.superpowers/sdd/2026-08-21-environment-energy-fidelity/cycles-hypothesis-report.md`.

**Where this leaves the roadmap.** The ~23% gap — carried since Phase E1 as
this project's largest known fidelity gap — is confirmed as a
comparison-harness colour-space error, not an engine defect (§7.4 amended
accordingly). **No engine change is proposed or needed.** §7.6's own findings
are unaffected by this and stand on their own: the engine reproduces analytic
hemispherical irradiance to −1.6% at high radiance-map resolution, and its
response is resolution-sensitive, reading +8.5% high at `RADIANCE_SIZE_256`
on a deliberately sub-texel stimulus — a real, minor, separate aliasing item
this confirmation does not touch and does not explain.

### 7.8 E2b - anisotropic GGX

**Status: landed and measured.** Real anisotropic GGX (elliptical `ax`/`ay`
roughness, azimuth-aware `D`/`G2`/VNDF sampling/pdf) now threads through
`sampleGGXVNDF`'s existing `alpha2D` parameter, replacing the isotropic
`(alpha, alpha)` pair E2's original framing (§4) flagged as the entry point.
Full task-by-task record:
`.superpowers/sdd/2026-08-22-anisotropic-ggx/task-{1..5}-report.md`.

**The `ax`/`ay` mapping is shared verbatim with two independent sources —
parity was free here, unlike an earlier phase.** Both read and confirmed
line-for-line:

```
Blender Cycles          intern/cycles/kernel/svm/closure.h:311-313
this engine's raster     servers/rendering/renderer_rd/shaders/scene_forward_lights_inc.glsl:272-274
```

```glsl
// scene_forward_lights_inc.glsl:272-274, confirmed byte-for-byte during Task 5
half aspect = sqrt(half(1.0) - anisotropy * half(0.9));
half ax = alpha_ggx / aspect;
half ay = alpha_ggx * aspect;
```

The path tracer's `anisoAspect()` (`brdf_inc.glsl:994`) uses this exact
formula. So Cycles parity AND raster/RT parity come from a single shared
formula — for the `ax`/`ay` MAPPING only. **The orientation channel does NOT
share this parity.** The raster shader derives its highlight orientation from
`ANISOTROPY_FLOW`, driven by the flowmap texture's RG channels
(`ANISOTROPY_FLOW = anisotropy_tex.rg * 2.0 - 1.0;`,
`scene/resources/material.cpp:1919-1920`) and has no `anisotropy_rotation`
uniform at all — that parameter is listed explicitly among the ten
path-tracer-only parameters with "no shader uniform to agree with"
(`scene/resources/material.cpp:4104-4105`). The path tracer, by contrast,
derives its orientation from `material.anisotropyRotation` added directly to
the tangent's azimuth (`brdf_inc.glsl:1691`,
`data.anisoPhi = atan(Tlocal.y, Tlocal.x) + material.anisotropyRotation;`),
with no flowmap involved. So the same material, with the same
`anisotropy_rotation` and/or flowmap authored, orients its specular highlight
differently in Forward+ than in the path tracer — a real, unaddressed
divergence, distinct from the ax/ay mapping's genuine parity above. Contrast
E1, which had to *purchase* a deliberate divergence to ship correctly: the dielectric closure's Fresnel remap is intentionally NOT the
same function opaque materials use (`brdf_inc.glsl:1268-1272`'s own comment:
*"routing everything through here would change the reflectance of every
specular surface in every existing scene"*), a real, load-bearing difference
between this engine's opaque and transmissive Fresnel paths that Cycles does
not have. E2b needed no equivalent trade — parity was free here.

**Signed, not saturated — a deliberate, documented divergence from Cycles'
internal representation, with no material-authoring cost.** `anisotropy` here
is SIGNED `[-1,1]`, matching this engine's own raster convention.
Cycles instead `saturatefs`-clamps to `[0,1]` and carries the other
orientation in its rotation channel — **not equivalent**: at
`anisotropy=-0.5`, Godot's convention gives an axis ratio of 1.450 vs Cycles'
`|a|=0.5` + 90° gives 1.818 (different eccentricity, not just a different
orientation). Nothing is lost in practice: `KHR_materials_anisotropy` (glTF)
has no sign concept, so every glTF- or Blender-imported material lands in
`anisotropy >= 0`, exactly where the two conventions agree exactly by
construction (`brdf_inc.glsl:988-993`).

**`anisotropy_rotation` is RADIANS, not turns — the other real Cycles-API
divergence, verified twice.** Cycles stores rotation as a 0-1 turn fraction
and multiplies by `2*PI` internally; Godot's `anisotropy_rotation` is used
directly as radians (`brdf_inc.glsl:1691`,
`data.anisoPhi = atan(Tlocal.y, Tlocal.x) + material.anisotropyRotation;` — no
`2*PI` factor). This was already documented from Phase D
(`PATH_TRACER_QUALITY_ROADMAP.md:985-987`) and Task 5's Cycles comparison
independently re-confirmed it empirically, not just by citation: converting
Godot's `PI/2` radians to Blender's `0.25` turn reproduced a ~90° highlight
rotation in BOTH engines (89.6°→0.3° in Godot, 89.8°→−0.3° in Cycles — see
below).

**`anisotropy == 0` takes the isotropic path unchanged — a deliberate user
ruling, not an oversight.** `BrdfData.anisoActive` is `false` whenever
`material.anisotropy == 0.0` or no usable tangent exists
(`brdf_inc.glsl:1661-1667`), and every consumer is required to take the
pre-existing isotropic branch in that case (`brdf_inc.glsl:349-353`'s own
comment: *"the anisotropic form is strictly MORE accurate... and taking it
unconditionally would silently shift every polished material and break the
no-pixel-change guarantee"*). `anisoAspect(0) == 1.0` exactly, so
`ax == ay == alpha` bit-for-bit at anisotropy 0 — this is why the reduction
identity doctest (Task 1) and the furnace/pdf-parity `0.0` controls (Task 4)
are meaningful checks, not tautologies: correct pre-E2b behavior is required
to reproduce exactly at that one value, and does.

**Verification results, carried forward from Tasks 1-4 and re-confirmed by
Task 5's own regression run:**

- **doctest**: 1521 passed / 0 failed / 3 skipped, unchanged across every task
  from Task 1's baseline through Task 5's final restore.
- **CPU-mirror reduction identities** (Task 1): `ggx_d_aniso` reduces to the
  shipped `GGX_D` and `smith_lambda_aniso` reduces to the shipped
  `Smith_G_Lambda_GGX` at `anisotropy=0`, exactly, in real arithmetic. One
  real finding along the way: the *shipped* isotropic `GGX_D` loses ~0.27%
  precision at `NdotH=1`, small roughness, via float32 catastrophic
  cancellation in `(alphaSquared-1)*NdotH²+1` — a pre-existing shipped-code
  artifact, not an E2b defect, now pinned as a permanent regression guard
  (`test_pt_anisotropy.cpp`, "the shipped isotropic D loses precision at
  NdotH = 1").
- **pdf/sampler self-normalizing parity** (Task 4, fix round 1): the ORIGINAL
  construction (compare the sampler's realized pdf `R` against `combinedPdf`'s
  report `G` for the same direction) was found to be a **tautology** — both
  sides resolve to the identical expression through identical inputs, so a
  genuinely wrong pdf formula would still read `R==G`. Replaced with a real
  instrument: draw real samples from the production sampler, accumulate
  `E[1/combinedPdf(L)]`, and compare against the upper hemisphere's exact
  solid-angle measure `2*PI` — a check that cannot be gamed by evaluating the
  same formula twice. **Result: PASSES at every anisotropy value tested,
  including a fresh `0.0` control (ratio 1.001145/1.001152)**, worst case
  0.53% off `2*PI` at `anisotropy=0.9`. No evidence of a sampler/pdf desync in
  the anisotropic branch. (This supersedes the original spec's §8 acceptance
  item 3, "pdf/sampler parity probe agrees within 1e-4" — that construction
  could not have failed even if the formula were wrong, so its 1e-4 pass was
  not meaningful evidence; the self-normalizing instrument is the real check
  and is the one that matters.)
- **C1-revert experiment** (Task 4, fix round 1, I6): Task 3's C1 fix (a
  missing `1/(4·NdotL·NdotV)` factor inside `evalMicrofacet`'s
  `anisoActive` branch) was temporarily reverted, measured, and restored.
  Furnace probe 1 (`roughness=0.4`) shifted **+10.2 to +15.8 percentage
  points** across the anisotropy sweep; a second, NEE-dominant probe 1b
  (`roughness=0.9, anisotropy=0.9`, built specifically because the a priori
  MIS-weight estimate predicted probe 1 alone might not catch a reverted C1)
  shifted **+42.6 points**. Both probes are therefore confirmed, by direct
  experiment rather than assertion, to actually guard the fix they exist to
  guard — satisfying the project's standing "gates must be falsifiable"
  discipline.
- **Furnace sweep** (Task 4): FAILS as an absolute check, **+3.4% to +8.1%**
  over 1.0 across the full anisotropy/rotation sweep, including the isotropic
  `anisotropy=0.0` control at +5.95%. See the separate open item below — this
  is NOT an anisotropy defect.

**The Cycles comparison (Task 5), with its mandatory positive control.**
Scene: metallic sphere, `roughness=0.4`, `anisotropy=0.6` (`>0`, the range
where the two engines' conventions agree exactly), `anisotropy_rotation` `0`
and `PI/2`, under a spatially uniform-radiance world. Colour-space handling
followed the E2a-lesson hard requirement exactly: Godot's
`albedo_color=Color(0.8,0.8,0.8)` (sRGB, as an artist would type it) decodes
via the engine's own `Color::srgb_to_linear()` — printed live by the harness,
not assumed — to `0.60382730`; Blender's `Base Color` was set to that decoded
number, **not** to `0.8`.

```
                Godot mean   Cycles mean   ratio      % off
rotation=0      0.625747     0.587438      1.065214   +6.52%
rotation=PI/2   0.625796     0.587503      1.065179   +6.52%
```

**Positive control**: a second Blender arm with the RAW, un-decoded `0.8`
Base Color measured `0.783586` against the reconciled arm's `0.587438` — ratio
`1.333904`, against a naive `v/srgb_to_linear(v)` prediction of `1.324882`
(0.68% apart, attributed to Cycles' own `F0`-dependent multi-scatter
compensation term, which makes this specular scene's response mildly
nonlinear in base colour, unlike E2a's pure-Lambertian control). The control
clearly reproduces the ~33% brightness swing the colour-space trap predicts,
in the correct direction.

**Rotation check**: intensity-weighted principal-axis angle (image moments)
of each render's brightness distribution. Within each engine, the axis
rotates by the expected ~90° between the two settings (Godot: 89.59°→0.27°;
Cycles: 89.79°→−0.30°) — **the highlight rotates the same way in both
engines**. The two engines' absolute axis angles also agree with each other
to within half a degree at each setting, which is more than the check
requires and was not independently guaranteed by anything in this task (it
depends on both engines' UV-sphere tangent generators sharing a convention,
which was not separately verified).

**As measured, the raw comparison MISSES the spec's 5% acceptance bar
(§8.6): +6.52%.** This is reported as a plain finding, not adjusted or hidden.
A targeted attribution experiment — reusing Task 4's own forced-`ms=1.0`
technique (temporary shader edit, rebuilt, measured, reverted, rebuilt again;
`git diff` confirmed empty before and after) — found that **5.85 of the 6.52
percentage points (90%) are attributable to the pre-existing,
anisotropy-orthogonal `evalMultiScatterApproximation` over-compensation bug**
(below). With that known bug's contribution isolated, the residual gap is
**0.67%**, comfortably inside the 5% bar. Full numbers, scripts, and the
diagnostic rebuild log are in
`.superpowers/sdd/2026-08-22-anisotropic-ggx/task-5-report.md`. **No fix is
proposed here** — the diagnostic edit was reverted immediately after
measurement and the production binary was rebuilt and independently
re-verified (doctest 1521/0/3 unchanged; `pt_anisotropy_gate_scene.tscn`'s
`anisotropy=0.00` control reproduced Task 4's committed `1.059537` to 6
decimal places) before this closeout was written.

**Open item — pre-existing, NOT caused or fixed by E2b, anisotropy-orthogonal.**
`evalMultiScatterApproximation`/`evalEmsApprox` over-compensates
single-scattering energy loss by roughly 3-8 percentage points across the
roughness/anisotropy range exercised here. It reads high on the isotropic
`anisotropy=0.0` furnace control too (+5.95%), which is the direct proof it
is not an anisotropy defect — the anisotropic branch of the code this bug
lives near is not even reached at `anisotropy=0`. Task 4 confirmed the
mechanism directly by forcing `ms=1.0` at all three reachable call sites
(`brdf_inc.glsl:1192`, `:1348`, `raytracing_closest_hit_common_inc.glsl:1270`)
and watching the furnace ratio drop from 1.0595 to 0.9657 (a true
single-scatter energy deficit of ~3.4%, over-corrected to +5.95% by the `ms`
term). Task 5's Cycles-comparison scene (different `F0`, different geometry)
reproduced the same signature: gap collapses from +6.52% to +0.67% when `ms`
is forced off. **This item is carried forward, unfixed, exactly as Task 4 left
it.** E2b does not claim to have caused it and does not claim to have fixed
it — it is recorded here as a separate, pre-existing engine defect that
happens to be visible in both this feature's own furnace gate and its Cycles
comparison, because both exercise the same underlying rough-conductor code
path anisotropic GGX also uses. No fix is proposed for it in this closeout.

**Phase table.** E2's anisotropy line (§4, "E2. Anisotropy, clearcoat, sheen")
is now **complete for the anisotropic-GGX portion**: `sampleGGXVNDF` threads
real per-material `ax`/`ay` through the whole reflective specular path
(distribution, height-correlated Smith G2, VNDF sampling, and pdf), matching
Cycles' and this engine's own raster's shared formula, verified by doctest,
a GPU furnace/pdf-parity gate, and the Cycles comparison above. **What
remains under the original E2 heading, per spec §9, is explicitly out of
scope for this phase and carried to its named successors:**

- **Clearcoat** and **sheen** lobes — not started (E2d/E2e).
- **The two-way → N-way lobe-selection rewrite** — still two-way; adding
  clearcoat/sheen as real third/fourth lobes requires this first (E2c).
  **Landed after this closeout was written — see §7.9.**
- **Anisotropy on the transmissive lobe, as a real, evaluated feature — still
  out of scope, but not for the reason a quick read suggests.** Cycles
  applies `alpha_x`/`alpha_y` to its glass closure too
  (`closure.h:450-451`); the spec (§9) scoped this phase to the reflective
  lobe only. Reading `sampleDielectricMicrofacet` (`brdf_inc.glsl:1277-1339`)
  during this closeout found the SAMPLER already threads `ax`/`ay`/`anisoPhi`
  through both its shared half-vector draw and BOTH branches' importance
  weight (`weightRatioR` reflect, `weightRatioT` transmit) — a deliberate
  side effect of Task 3's "I1" weight-consistency fix, not a new claim of
  transmissive-anisotropy support. It does not make anisotropic glass a real
  feature: there is no BRDF **evaluation** or **pdf** for a transmitted
  direction anywhere in this file, anisotropic or not —
  `evalCombinedBRDFSeparate` returns zero whenever `data.Lbackfacing`
  (`brdf_inc.glsl:1886-1888`, true for every transmitted direction) and
  `combinedPdf` returns `0.0` whenever `NdotL <= 0`
  (`brdf_inc.glsl:1746-1749`, same condition) — so NEE/MIS can never combine
  a strategy against a refracted direction at all, matching the pre-existing,
  already-documented "NEE through refractive lobes is unimplemented" gap
  (E1 closeout). Genuine anisotropic glass needs that eval/pdf machinery
  built first; remains an E2d/E2e item (spec §9).

### 7.9 E2c - N-way lobe rewrite

**Status: landed. Ships no feature, by design.** The hardcoded two-way
`DIFFUSE_TYPE`/`SPECULAR_TYPE` selection is replaced by a registry — a
`LOBE_COUNT`-sized weight array, a CDF walk (`selectLobe`), and a
per-lobe weighted pdf sum (`combineLobePdf`) — all in
`brdf_inc.glsl:1730-1786`. `LOBE_COUNT` is **2**. Nothing renders
differently, and that is the whole acceptance criterion. Full task-by-task
record: `.superpowers/sdd/2026-08-23-n-way-lobe-rewrite/task-{1..4}-report.md`.

What it bought: clearcoat (E2d) and sheen (E2e) each add a lobe, and each
would otherwise have had to invent the selection and combination machinery
*while* also getting its own BRDF right. Those two risks are now separated,
and the machinery half was validated against a configuration whose correct
answer is already known — today's image.

**The two duplicated lobe-probability functions are unified.**
`combinedPdfLobeProbability` and `samplerLobeProbability` computed the
identical formula from identical inputs, deliberately, so that a desync
between the sampler's split and `combinedPdf`'s stayed representable. Both
are deleted; `lobeWeight` is the single source.

The old comment's reasoning no longer holds. The detector it named compared
the two values side by side — a comparison of two evaluations of *one*
formula. E2b's final review established that construction is a tautology in
vis mode 35 and cannot fail, and replaced it with a self-normalizing
instrument: draw from the real sampler, accumulate `1/pdf`, compare the mean
to the domain's measure. A pdf wrong by factor `k` reads `1/k` whether or not
a second copy of the formula exists. Unification therefore makes the desync
structurally **impossible** while leaving it **detectable**. `lobeWeight`
carries this in a comment so the duplication is not restored on the strength
of the old one.

**Two constraints future lobe work must honour.** Both are invisible to every
gate this project has, which is why they are recorded here rather than left
in the code:

1. **Specular is lobe index 0.** A CDF draw selects lobe 0 when `u < cdf[0]`.
   A diffuse-first registry would select *diffuse* on exactly the inputs where
   today's code selects *specular*, inverting every pixel's lobe choice. The
   image stays statistically identical, so every gate still passes and the
   output is bitwise unrecognisable. Registry order is contract, not detail.
2. **One RNG draw, on `RT_PRNG_LOBE`, consumed once.** A selection that draws
   a second value, remaps `u`, or rescales it into a sub-interval shifts every
   subsequent sample in the path — again a statistically valid render that is
   bitwise different everywhere, and again invisible to every gate.

**Step 1 result — a zero-weight third lobe is inert.** `LOBE_COUNT` was
temporarily raised to 3 with a third entry of weight `0.0` and pdf `0.0` added
at both consumer sites, rebuilt, and gated; then reverted to 2, rebuilt, and
gated again. **Neither `selectLobe` nor `combineLobePdf` was touched to do
it** — that is acceptance criterion 4, met as worded.

Both gates PASS at N=3 and at N=2. The measured figures differ between the two
builds, so a **same-binary control** was run — the N=2 build gated twice — to
establish what run-to-run noise looks like before attributing anything to the
third lobe:

| metric | N=3 | N=2 run A | N=2 run B | treatment delta (N=3 vs A) | control delta (A vs B) |
|---|---|---|---|---|---|
| energy, bumpy normal-mapped mean | 1.42073 | 1.42098 | 1.42006 | 2.5e-4 | 9.2e-4 |
| energy, smooth mirror mean | 1.48897 | 1.48915 | 1.48906 | 1.8e-4 | 9.0e-5 |
| energy, rough metal mean | 1.70837 | 1.70831 | 1.70822 | 6.0e-5 | 9.0e-5 |
| aniso, probe 1b NEE-dominant mean | 1.345898 | 1.345912 | 1.345915 | 1.4e-5 | 3.0e-6 |
| aniso, worst furnace deviation | 1.080978 | 1.080981 | 1.080982 | 3.0e-6 | 1.0e-6 |

**Read the table honestly: it does not show treatment uniformly below control.**
Control exceeds treatment on two rows (bumpy by 3.7x, rough metal marginally);
treatment exceeds control on three (smooth mirror 2.0x, probe 1b 4.7x, worst
furnace 3.0x). Recomputing treatment against run B instead of run A flips which
rows fall on which side without moving the picture. One control delta per metric
is a **one-sample** estimate of the noise, so it establishes an order of
magnitude and not a band, and no arrangement of these numbers supports a claim
that every treatment delta sits inside a measured band.

What the table does support: **treatment and control deltas occupy the same
range on every row** — both span ~1e-6 to ~1e-3, and neither column is
consistently the larger. That is what an inert third lobe looks like when both
columns are measuring the same GPU non-determinism, and it is what the mechanism
argument below independently predicts (weight 0.0, pdf 0.0, trailing position,
`acc + 0.0f` bit-exact — the N=3 build *should* be bit-identical, which means the
entire table is measuring run-to-run noise on both sides). A real normalisation
bug at N=2 would not hide inside 1e-3 on a furnace ratio; it would move the
selection split. **Verdict: the third lobe changed nothing these instruments can
resolve, and no normalisation bug was hiding at N=2 — but the evidence is
agreement in magnitude plus the mechanism, not a measured band.**

One mechanism is worth carrying forward, because it is why the test was inert
rather than merely lucky. `selectLobe`'s loop runs to `LOBE_COUNT - 1` and
falls through to `return LOBE_COUNT - 1`, so the last lobe absorbs the float
rounding residue of the weight sum — the standard CDF-walk idiom, and correct
when the last lobe is real. With a *trailing zero-weight* lobe, the handful of
draws in that residue window (at most ~1 ULP of 1.0) returned index 2, which
the sampler's `else` branch mapped onto the diffuse path with the same
throughput divisor they would have taken at N=2. Identical behaviour, not an
accident. **E2d and E2e add real lobes, so the fallback is correct for them;
the note is that a zero-weight lobe must not be placed last.**

**Bit-identity was verified structurally, not by pixels.** This is the phase's
central claim and the gates cannot carry it. `pt_validation`'s `mean_luma` has
a documented ~1e-5 run-to-run floor on an *identical binary*, from GPU float
non-associativity in the accumulation reduction — the control column above
measures that floor directly. A gate matching to five decimal places proves
the refactor did not change behaviour meaningfully. **It does not prove
bit-identity, and nothing in this closeout claims it does.** The evidence is a
reviewer tracing three properties through the shipped diff:

- **Lobe order.** `LOBE_SPECULAR` is 0; at `LOBE_COUNT == 2` the CDF loop runs
  once and `acc = 0.0f + weights[0]`, which is bit-exact under IEEE-754, so
  `selectLobe` returns specular on precisely `u < weights[0]` — the identical
  predicate to the old `rng_1d(...) < brdfProbability`. NaN behaviour is
  preserved too (a NaN weight compares false, giving diffuse, as before).
- **RNG draw.** Exactly one `rng_1d(rng, RT_PRNG_LOBE)` in the whole raytracing
  tree, passed straight into `selectLobe` with no remap, rescale, clamp, or
  second draw. `lobeWeight` is evaluated in a prior statement exactly as
  `samplerLobeProbability` was, so the RNG advances at the same point and every
  downstream draw sees identical state.
- **Summation order.** `combineLobePdf` seeds `acc = 0.0f` and accumulates
  specular then diffuse, matching the expression it replaces.

**The one documented exception.** C parses `a * b * c` as `(a * b) * c`, so the
old code computed `(pSpec * specularContribution) * transmitScale`. The
registry folds `transmitScale` into the specular pdf entry, computing
`pSpec * (specularContribution * transmitScale)`. **1 ULP apart in float32** at
the inputs the doctest pins — a measurement at one triple, not a bound, since
`(a*b)*c` vs `a*(b*c)` can differ by ~2 ULP in general. Two relative figures get
quoted and they measure different quantities: `6.2e-8` is the gap on the
**specular term** (what the test computes), `1.06e-7` the gap on the **full
combined expression** with those constants. Found by the phase's own doctest
before any shader was touched.

"Mathematically equal" holds on every reachable input but is not unconditional:
at `pSpec == 0.0f` the old form yielded `0.0` for any finite
`specularContribution`, while the new form evaluates
`specularContribution * transmitScale` first. Nothing reachable produces a
non-finite value there — `specularPdf`'s `alphaSquared`, `NdotV` and `LdotH` are
all floored at `1e-5`, bounding the contribution — but a future lobe with an
unfloored pdf would turn that corner into a `NaN`. Recorded by the E2c final
review; no reachable input was found.

It was accepted rather than engineered around: contorting the registry to
preserve one grouping would make it something other than a uniform sum, which
is precisely what E2d and E2e build on, and every future lobe would reintroduce
the question. At `6.2e-8` on the term and `1.06e-7` combined, both sit orders of
magnitude below the `mean_luma` floor, so no instrument in this project can
resolve either. **The claim was
weakened rather than the code**: this phase is identical to today except for
one documented reassociation on the specular term. A doctest case pins the gap
— both that the two groupings differ at all (a tripwire against the compiler
contracting them) and that the magnitude stays in `1e-8 < rel < 2e-7` — so it
is a recorded fact rather than a puzzle for whoever next compares the two
expressions.

**Verification summary.** doctest **1527 passed / 0 failed / 3 skipped**
(2,066,552 assertions); `pt_energy_gate` PASS; `pt_anisotropy_gate` PASS within
its +/-0.5pp measured-intact bands; `pt_transmission_gate` exit 0 with 44
checks.

**Open items carried out of E2c.**

- **`pt_transmission_gate` probe 6 is bimodal.** It has been observed at ~4.069
  (three times, including this phase) and ~5.04 (many times, across E2b), on
  binaries that differ in ways that cannot reach it — this phase's fix round
  has zero diff in `brdf_inc.glsl` while probe 6 exercises the real non-debug
  TIR path. E2b saw 4.069235 identical to six decimal places across two
  separate launches, then ~5.04 six times on the *same unchanged binary*, which
  is inconsistent with a deterministic regression. Flaky, not caused by this
  refactor, not chased here.
- ~~**Lobe-order test coverage.**~~ **Closed before the phase ended.** Both
  order tests had exercised only `p_spec = 0.37`, i.e. `< 0.5`, so a
  `selectLobe` keying off min/max weight rather than positional order would
  coincidentally agree there and pass both. Now swept over `{0.37, 0.5, 0.73}`
  (orientation) and `{0.37, 0.73}` (inverted-registry; `0.5` is excluded
  because at an even split the inverted array is the same array, making zero
  disagreements the correct answer). The guard was then **proven by breaking
  the thing it guards**: `select_lobe` was temporarily rewritten to accumulate
  `min(weights)` instead of `weights[i]`, and the orientation test failed at
  `p_spec = 0.73` and **only** there — the previous 0.37-only version would
  have passed that bug silently. Break reverted, suite green. This mattered
  more than a routine coverage gap because it is the only automated pin on the
  CDF's *orientation*, which no rendered image can see.
- **Lobe ORDER in the shader has no automated instrument at all, and the
  closeout above should not be read as saying otherwise.** The doctest case
  named "specular is index 0" checks the *test file's own* `#define`s against
  literals in the same translation unit; nothing links them to
  `brdf_inc.glsl`. Invert the shader's `LOBE_SPECULAR`/`LOBE_DIFFUSE` and all
  six cases still pass. A CPU mirror cannot see the shader, and a rendered
  image cannot see an inverted registry — the picture stays statistically
  identical and every GPU gate passes. **Structural review is the only
  instrument**, which is why design §6.3 names it. The case is kept because it
  pins the mirror the other five cases are built on; its comment now says so
  rather than claiming the property it is named for. Raised by the E2c final
  review; recorded rather than papered over.
- **Non-default `SPECULAR_BRDF` / `MICROFACET_DISTRIBUTION` configurations no
  longer compile** (inherited from E2b, unchanged here).

**Phase table.** Under section 4's "E2. Anisotropy, clearcoat, sheen":
anisotropic GGX is complete (section 7.8), and **the two-way to N-way
lobe-selection rewrite is now complete**. What remains under that heading is
**clearcoat (E2d)** and **sheen (E2e)** — neither started — plus anisotropy on
the transmissive lobe, which still needs the refracted-direction eval/pdf
machinery described at the end of section 7.8. Cycles'
`closure_layering_weight` attenuation semantics
(`intern/cycles/kernel/svm/closure.h:141` sheen, `:174` coat) arrive with the
first real layer in E2d; this phase deliberately changed no layering
semantics, only selection and combination.
