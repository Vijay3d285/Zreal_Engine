# RTX Path Tracer — Quality Gap Analysis & Roadmap to Blender-Cycles Parity

**Scope:** Code-level diagnosis of why this Godot 4.7 fork's path-traced output does not match Blender Cycles, with a prioritized, code-anchored roadmap.

**Engine branch:** `vijay_PTEngine_v8_Quality` *(where this document was started; it has since been carried across many branches — currently `vijay_PTEngine_V19_GAP19`. Use git, not this line, for lineage.)*
**Reference:** Blender Cycles at `C:\Users\aiadmin\Desktop\blender_build\blender\intern\cycles`

Every "Cycles does X" claim below is anchored to a real file:line in that tree. Every "we do Y" claim is anchored to this branch. **This document was re-verified against both source trees; it supersedes the earlier `vijay_pt2_shadows`-era revision, which described several already-solved problems as open.**

### Reference provenance — read this before trusting a Cycles line number

**Three different Blenders appear in this document, and they are not the same version.**

| what | version | where | used for |
|---|---|---|---|
| **Source tree** | **5.3.0-alpha** — git `d20578850b` on `main`, 2026-08-01 | `C:\Users\aiadmin\Desktop\blender_build\blender` | **every** `intern/cycles/…:NNN` citation in this document |
| **Runnable binary** | **5.2.1 LTS**, build date 2026-08-25 | `C:\Program Files\Blender Foundation\Blender 5.2\blender.exe` | §11's anisotropic furnace (2026-09-11) |
| **Historic binary** | **4.5.3 LTS** (one run records hash `67807e1800cc`) | **no longer installed on this machine** | the parity measurements in §7.6, §7.8, §7.10, §7.11 |

Four consequences, each of which has already cost something:

1. **Line numbers are 5.3-alpha's.** Function names have been stable across these
   releases; line numbers have not. Anchor on the function name and re-grep
   before trusting any `:NNN` here — several in this document are already stale
   even on OUR side of the comparison: `COMBINE_BRDFS_WITH_FRESNEL` is cited
   throughout as `brdf_inc.glsl:158` and the define sits at `:170` today.
2. **Reading the source is not the same as running the binary.** §11.4 records a
   control built on `svm/closure.h:309`'s tangent gate, read in 5.3-alpha, which
   5.2.1 does not exhibit — the control came back uninformative and the real
   activation evidence had to come from elsewhere. If a conclusion depends on
   behaviour rather than on structure, **measure it in the binary you will run.**
3. **The §7.x parity numbers cannot be reproduced on this machine.** They came
   from 4.5.3 binaries that are gone; `Blender 4.2`, `4.4` and `4.5` under
   `C:\Program Files\Blender Foundation\` are leftover `python/` and `scripts/`
   folders with **no `blender.exe`**. Re-taking any of them means reinstalling
   4.5.3 first — see §10.5, which is why those figures are flagged as not
   re-measured after Gap #17.
4. **New comparison scripts get checked in.** `tools/cycles_comparison/` holds
   §11's furnace script. The earlier comparison tooling never was, which is the
   direct reason point 3 is a problem rather than an afternoon's work.

*Do not silently substitute one of these versions for another when citing or
re-running. Say which one, as §11 does.*

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
| 13 | **Missing BSDFs** — transmission (E1, §7.5), anisotropy (E2b, §7.8), clearcoat (E2d, §7.10) and sheen (E2e, §7.11) now all ship; **SSS is what remains** | `closest_hit_common:474-475` | `subsurface_random_walk.h`, Principled | Medium |
| 14 | **fp16 radiance/throughput payload** | `raytracing_inc.glsl:75-87` | fp32 throughout | Medium |
| 15 | **Biased bump-map mirror recovery** | `brdf_inc.glsl:998-1009` | offset/position normals, no bias | Low-Med |
| 16 | **No volumetrics** | absent | `integrator/shade_volume.h` | Low |
| 17 | **Multi-scatter energy compensation over-shoot** — **FIXED 2026-09-10, see §10.** `evalEmsApprox`/`evalMultiScatterApproximation` over-corrected the true single-scatter GGX energy loss by 3.4–8.1pp. Replaced by `evalMultiScatterEnergy`, a transcription of Cycles' `microfacet_ggx_preserve_energy` reading the `GGX_E`/`GGX_EAVG` tables E2d already ships. The white furnace's isotropic control went **1.059535 → 1.000549**. Two things this did *not* fix are now separate rows: #19 and #20. | `brdf_inc.glsl` (`evalMultiScatterEnergy`, `evalMultiScatterFactor`, `RT_MS_COMPENSATION`), call sites in `brdf_inc.glsl` (sampler), `raytracing_closest_hit_common_inc.glsl` and `raytracing_emissive_inc.glsl` (NEE) | `intern/cycles/kernel/closure/bsdf_microfacet.h:466-485` | **Fixed** |
| 18 | **Clear glass reads flat through the Transparent BSDF closure, cause unknown** — a pane's whole shading is weighted by its authored alpha, so a clear pane at `alpha = 0.098` keeps ~10% of its reflection. **That weighting is NOT the defect: Cycles does the identical thing** (`weight *= alpha` before any shader component). So the cause lies elsewhere and is unidentified. Currently masked by a pipeline substitution that converts such panes to opaque transmission; whether that substitution is a divergence to delete or an improvement to keep is itself unanswered. See §9.10. | `raytracing_closest_hit_common_inc.glsl:1383` (closure branch), `pipeline_references/image_glb_creation.gd` (`_glb_alpha_convert_is_lossless`) | `intern/cycles/kernel/svm/closure.h:108-113` — same alpha weighting, verified | Medium |
| 19 | **Anisotropic GGX loses energy — and so does Cycles, in the opposite direction, so this is a PARITY gap rather than a correctness one** — the white furnace reads 0.976442 at roughness 0.4 / anisotropy 0.9 where it must read 1.0. **Cycles 5.2.1 measured on the identical furnace reads 0.927854** (§11), so the failure is shared, not ours — but the two engines fail *differently*: we over-recover, Cycles under-recovers, and the divergence between them reaches **+5.24% at roughness 0.4 / anisotropy 0.9 and +47.83% at roughness 0.9 / anisotropy 0.9**. `GGX_E_TABLE` has no anisotropy axis in either engine. Isotropically the two agree to ~1e-5 at **both** roughness 0.4 (1.000549 vs 1.000499) and roughness 0.9 (0.999631 vs 0.999645), so **the entire divergence is anisotropy** and Gap #17's fix is complete across the roughness range — independently confirmed from outside this project. **Brushed metal will not match Blender until this is closed.** | `brdf_inc.glsl` (`evalMicrofacet` anisotropic branch, `anisoAspect`, `evalMultiScatterEnergy`), `pipeline_references/tests/pt_anisotropy_gate.gd` probes 1 and 1b | `intern/cycles/kernel/closure/bsdf_microfacet.h:437-447` — single `rough = sqrt(sqrt(ax*ay))` for both axes, same isotropic table | **High** |
| 20 | **The transmissive lobe still uses the fitted multi-scatter approximation** — Gap #17 deliberately left `brdf_inc.glsl`'s transmissive reflection branch on `evalMultiScatterApproximation`, because Cycles compensates glass from a different table set — `ggx_glass_E` (16×16×16), `ggx_glass_Eavg` (16×16) and the `ggx_glass_inv_*` variants for `ior < 1` — none of which this project has transcribed. Pointing it at `ggxE`/`ggxEavg` would swap a measured divergence for an unmeasured one. Needs the four tables, an extended SSBO layout, and its own transmissive furnace study. The transmit branch applies no compensation at all. | `brdf_inc.glsl` (transmissive closure, reflection branch — annotated in place) | `intern/cycles/kernel/closure/bsdf_microfacet.h:450-457` | Medium |

**Not gaps — verified correct, leave alone:**
- BRDF library (VNDF GGX, height-correlated Smith G2) — Cycles-class. Multi-scatter compensation over-corrected until 2026-09-10 and now uses Cycles' own tables (Gap #17, §10). Still not an unqualified "leave alone": the **anisotropic** branch carries a separate energy error (Gap #19) and the **transmissive** lobe still uses the old approximation (Gap #20).
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

*Was open, now **CLOSED** (2026-09-09):* **the converged mean moved +2.4% on
dielectric specular surfaces.** MIS must redistribute variance, not energy. The
cause was isolated and confirmed by controlled experiment, and the fix is
measured — see the C3 entry below.

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
different integrands — the structural defect behind B2's +2.4% shift, since fixed.
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

**CLOSED (2026-09-09): +2.4% converged-mean shift on dielectric specular
surfaces.**
*(B2's defect, measured here — see the attribution note in §6. The mechanism was
B2's `COMBINE_BRDFS_WITH_FRESNEL` integrand mismatch; C3 is where the numbers
were taken, not where the bug was.)*
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

> **That last sentence was wrong, and it is left standing above so the error is
> legible rather than quietly edited out.** It assumed the repair had to move
> `evalCombinedBRDFSeparate`. It does not. The evaluator defines what the
> material *is*; the sampler's only job is to deliver `f·cos/pdf` for that same
> `f`. So the **sampler** moved, and the analytic-light path is untouched — the
> generated shader is character-identical there before and after. This is the
> same failure mode as the §9.10 erratum: a claim about what code would have to
> change, asserted from plausibility instead of read off the two call sites.

**THE FIX.** `evalIndirectCombinedBRDF`'s `DIFFUSE_TYPE` branch now attenuates by
`(1 - data.F)` — the same `data.F` that `prepareBRDFData` built from `data.LdotH`
and that `evalCombinedBRDF` and `evalCombinedBRDFSeparate` already applied. The
second VNDF draw is deleted, along with the reused random number its own comment
conceded was wrong ("correctly it should be an new independent random number").
Net −24 lines of shader. `COMBINE_BRDFS_WITH_FRESNEL` stays as the A/B switch it
has always been.

**MEASURED, on `pt_energy_gate.gd`'s rough dielectric (roughness 0.4, metallic 0,
256 frames at 256×256):**

|                       | disc    | rim     | MIS − BSDF-only     |
|-----------------------|---------|---------|---------------------|
| before, BSDF-only     | 0.46667 | 0.41831 |                     |
| before, with MIS      | 0.47089 | 0.42792 | **+0.91% / +2.30%** |
| after, BSDF-only      | 0.47112 | 0.42776 |                     |
| after, with MIS       | 0.47107 | 0.42821 | **−0.01% / +0.11%** |

**It is the BSDF-only path that moved**, up ~0.95% to meet where MIS-on already
sat. MIS-on itself shifted +0.04%, i.e. inside this surface's ~0.03% run-to-run
spread. That is the signature of the *sampler* having carried the wrong
integrand while the evaluator carried the right one, and it means **no rendered
image gets materially brighter or darker from this fix** — what changed is that
the two strategies now estimate the same function. Every other gate surface is
unmoved: `smooth` 0.01%, `rough` 0.03%, `bumpy` 0.46%, `diffuse` 0.06%, Gate 1
absolute 0.001% — as required, since metallic surfaces have
`diffuseReflectance == 0` and the gate's Lambertian plane sets
`metallic_specular = 0`, so neither can see a change to the diffuse Fresnel term.

**NEW INSTRUMENT: `RT_ENV_NEE_ENABLED` (`raytracing_inc.glsl`, default 1).** The
defect is defined as (MIS on) − (BSDF only), so *neither figure alone can say
whether it is present* — and before this switch the only way to take the second
figure was to check the raytracing shaders out at pre-MIS commit `de2ce2c248`,
which also reverts every unrelated change since and therefore cannot measure
anything on a current tree. The switch moves **both halves** of the partition
together: the env-NEE block in `shade_and_bounce` *and* the miss stage's
`power_heuristic` weight on BSDF sky hits. Gating only the first would leave
every sky hit scaled below 1 with nothing to restore it, and the "control" would
read as a brightening that was really just the missing half of a partition.
Kept permanently as scaffolding, on the standing precedent of
`COMBINE_BRDFS_WITH_FRESNEL` and `RT_LIGHT_SELECT_UNIFORM`.

*The instrument was validated before its results were believed, in three ways.*
At `RT_ENV_NEE_ENABLED 0` the constant-sky gate's per-pixel std-dev reads
**exactly 0.000000** — BSDF sampling under a constant sky is a zero-variance
estimator, so this is the control proving it really is BSDF-only rather than
merely dimmer. The old sampler with the switch at 0 reproduces the pre-MIS build
swap it replaces: **0.46636 / 0.41767** against the **0.46667 / 0.41831**
captured at `de2ce2c248` — 0.07% and 0.15%. And at `RT_ENV_NEE_ENABLED 1` the
generated shader body is character-for-character identical to the pre-switch
build, so the switch is provably inert in production.

**WHAT THIS DELIBERATELY DOES NOT DO — and the follow-up it leaves.** Cycles uses
*neither* of our two forms. It attenuates the base layer by
`1 - albedo(layer above)`: L-**independent**, derived once at closure setup from
`sd->wi`, and applied as a closure *weight* rather than inside a BRDF function,
so its eval and sample paths cannot desync at all (`closure_layering_weight`,
`intern/cycles/kernel/closure/bsdf_util.h:440-444`, called for exactly this
specular-over-diffuse layer at `intern/cycles/kernel/svm/closure.h:468-470`).
Our `1 - F(L·H)` is a different model, not a worse-implemented copy of that one.
Matching Cycles' shape means giving the **base** specular lobe a
directional-albedo estimate and routing both sides through
`layerTransmittanceAbove` — precisely what E2d already did for the coat and E2e
for sheen, so the machinery exists and only the base lobe was left out. *That*
change would move analytic-light shading engine-wide and needs its own energy
study against Cycles; it is a real parity item, filed here rather than smuggled
into a bias fix. **This fix closes the MIS bias. It does not close Blender
parity on the diffuse-under-specular layer.**

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

**E2. Anisotropy, clearcoat, sheen** — anisotropy **COMPLETE (E2b)**, clearcoat **COMPLETE (E2d)**, sheen **COMPLETE (E2e, §7.11)**. All three acceptance targets measured against Blender/Cycles; `coat_normal` and transmissive-lobe anisotropy are the named remainders.
`sampleGGXVNDF` already takes `alpha2D` and callers pass `(alpha, alpha)` (`brdf_inc.glsl:837`) — thread real anisotropy through instead. Add a clearcoat GGX lobe and a sheen lobe. **Not Charlie** — Cycles replaced the Charlie/velvet sheen with Zeltner's linearly-transformed-cosine lobe (`bsdf_sheen.h`), and E2e ports that; see §7.11.3.
*Accept:* brushed metal, car paint, and velvet respond comparably to Cycles. **Brushed metal: met, see §7.8** — anisotropic GGX now threads real `ax`/`ay` through distribution, Smith G2, VNDF sampling and pdf, sharing its `ax`/`ay` formula verbatim with Cycles and this engine's own raster; measured at **+6.52% raw** against Cycles (5% bar), narrowing to within **0.67%** once the pre-existing, anisotropy-orthogonal `evalMultiScatterApproximation` pedestal (§7.8) is accounted for. **That pedestal was removed on 2026-09-10 (Gap #17, §10), so the adjusted figure is what the engine now produces — but the raw comparison against Blender has NOT been re-taken**, and the `.blend` scene behind it was never checked into this repo. See §10.5. **Car paint: met (radiometrically) — see §7.10** — the clearcoat ships as a Cycles *coat layer*, not merely a fourth lobe: a GGX lobe at registry index 2 that also withdraws energy from everything beneath it (`closure_layering_weight`), with Cycles' `ggx_gen_schlick_ior_s` albedo LUT, its `table_ggx_E`/`table_ggx_Eavg` energy compensation, exact dielectric Fresnel, and Beer's-law `clearcoat_tint`. Measured against Blender 4.5.3/Cycles on a car-paint sphere at **+0.381% raw**, **−0.098%** with Gap #17's `evalMultiScatterApproximation` pedestal neutralised (that pedestal is gone as of 2026-09-10, §10; the raw comparison has not been re-taken — §10.5); the coat layer's own contribution, isolated by subtracting each engine's uncoated control, agrees to **0.066%**, and the tint to **0.016%**. Geometrically incomplete, though: `coat_normal` — the coat's own bump/orange-peel normal — is not shipped (§7.10.7 calls it "the one piece of Blender coat parity E2d does not ship"); a reader who only sees this table's "met" would not know a coat-normal texture on a car-paint material still renders identically to a base-normal one. **Velvet: met — see §7.11** — sheen ships as Cycles' Zeltner LTC lobe (`pdf == eval`, so its sample weight is exactly 1), against a byte-exact copy of Cycles' 32×32×3 table, and as a *layer* on the same general N-layer stack the coat uses: sheen at registry index 3 withdraws from coat, specular and diffuse via `closure_layering_weight`, and Cycles' allocation order (`svm/closure.h:115` sheen first, `:146` coat second) makes registry index order and physical layer order agree. Measured against Blender 4.5.3/Cycles on a velvet sphere at **−1.710% raw**, **−2.137%** with Gap #17's pedestal neutralised (gone as of 2026-09-10, §10; raw not re-taken — §10.5) — *worse* adjusted, because here the pedestal partially masks a base deficit rather than causing an excess (§7.11.2). **The sheen layer's own contribution, isolated by subtracting each engine's un-sheened control, agrees to +0.324%**, and to +0.269% / +0.257% at sheen roughness 0.30 / 0.80; the 0.30:0.50:0.80 roughness ladder reproduces a 169× dynamic range to 1.1e-4. **The raw residual is the dielectric base, not the sheen** — the un-sheened control is the worst arm at −2.062% — which is a new open item (§7.11.2), not a sheen one. Geometrically incomplete for the same reason car paint is: `coat_normal` is still not shipped, and Cycles couples it to the *sheen* normal too (`svm/closure.h:127-129`), so it now blocks both. **This closes E2's original acceptance line: all three of brushed metal, car paint and velvet are measured against Cycles and all three clear the 5% bar raw.** The two-way→N-way lobe-selection rewrite they depend on is done (E2c, §7.9), E2d is its first real N=3 (§7.10.5) and E2e its first N=4 (§7.11.4); anisotropy on the transmissive lobe remains. **The path tracer's coat deliberately diverges from this engine's own raster** (`alpha = r²` vs `mix(0.001, 0.1, r)`, and layered vs purely additive) — see §7.10.3 before filing that as a bug.

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

**Phase B** makes the converged image *correct* rather than merely stable: MIS and real bounce counts are what separate "a path tracer" from "a reference path tracer." **The one live exception is now closed:** environment MIS shipped a **+2.4% converged-mean error on dielectric specular surfaces** — i.e. most ordinary materials — traced to the `COMBINE_BRDFS_WITH_FRESNEL` integrand mismatch. Fixed 2026-09-09 by moving the sampler onto the evaluator's Fresnel term; the MIS-vs-BSDF-only delta on the gate's rough dielectric fell from +0.91%/+2.30% to −0.01%/+0.11%. Variance and mean are both where they should be. See the C3 entry for the measurements, and for the Cycles-parity follow-up it does *not* close.

**Phase D before E** is deliberate and non-negotiable. Material data must survive import before BSDF math is worth writing.

Ordering summary: **E → F (Phases A, B, C and D are complete).** *(Corrected 2026-09-10: this line still read `A1 → A2/A3/A4 → D → E → F` long after §4 marked Phase A implemented pending GPU verification.)*

**Phase B is complete** — B1, B2, B3, B4 and B5 have all landed. "Complete" here
means every listed item is implemented and measured; it does **not** mean Phase B
is free of known defects. The open items recorded in this document stand
unchanged and none of them was resolved by B4. The largest of them — the **+2.4%
converged-mean shift on dielectric specular surfaces** from B2's
`COMBINE_BRDFS_WITH_FRESNEL` integrand mismatch — **is now fixed** (2026-09-09,
see the C3 entry). Still open from this phase: the **asymmetric firefly
clamping** across the MIS partition, the
**untested zero-pdf sentinel**, and the fact that **the doctest binary never
executes the GLSL** — the shader-side tests mirror the shader in C++ rather than
running it.

**Phase C is complete** — C1, C2 and C3 have all landed. As with Phase B,
"complete" means every listed item is implemented and measured; it does **not**
mean the phase is free of known defects. The **+2.4% converged-mean shift on
dielectric specular surfaces** measured here **is now fixed** (2026-09-09); the
`SKY_MODE_LIGHT_AND_SKY` double count is still open, and C1's open items — chief among them the **fixture
double-representation in `image_glb_creation.gd`**, which would materially
brighten night renders if the setting were enabled without a pipeline change —
are recorded in the C1 entry. **C1 ships default off.**

**One attribution, stated once so the rest of this document can point at it.** The
+2.4% dielectric-specular shift was **B2's defect, recorded under C3**: the
mechanism was the `COMBINE_BRDFS_WITH_FRESNEL` integrand mismatch that B2's
environment MIS introduced (`brdf_inc.glsl:158`), and it was *measured* during C3,
which is why the numbers live in the C3 entry. It was not a C3 defect and it was
not two separate items. Earlier revisions of this section called it "C3's", which
would send someone to the wrong code. **It was fixed on 2026-09-09** — in B2's
code, from C3's measurements, exactly as this attribution said it would have to
be.

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
- **C3**: environment importance sampling, 4.8-6.9× equal-time. B2's +2.4%
  dielectric-specular shift was measured here and is now **fixed** (2026-09-09),
  leaving a Cycles-parity follow-up on the diffuse-under-specular layer that the
  C3 entry states in full.

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
  NEE. Same structural class as B2's +2.4% converged-mean defect, which was
  fixed on 2026-09-09 by moving the SAMPLER onto the evaluator's term rather than
  the reverse — worth reading before assuming this one needs NEE to move. **The
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
- Shadow rays passed through glass as of the transparent-shadows work (section 8):
  a transmissive surface now attenuates a shadow ray by `transmission * (1 - F)`
  per crossing instead of blocking it. Caustics remain absent and unscheduled --
  light crosses the pane without bending. The previous revision of this line
  claimed being blocked "matches Cycles"; that is true only of Cycles' Glass BSDF.
  Cycles' transparent-shadow path (`shade_shadow.h:183`) fires for Transparent BSDF
  closures, which is what alpha-authored glass assets actually produce, so the
  reference renders were never taking the path this line described.
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

**RESOLVED 2026-09-10 (Gap #17, see §10). Everything below is kept verbatim as the
before-state — the measurements are what the fix was verified against, and the
`ms=1.0` experiment recorded here is what became `RT_MS_COMPENSATION 0`.** One
claim below did not survive: the isotropic control was correctly diagnosed, but the
**anisotropic** spread around it turned out to be a second, independent defect that
removing this one does not touch — now Gap #19.

*Original entry:* **Open item — pre-existing, NOT caused or fixed by E2b, anisotropy-orthogonal.**
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
**E2d landed after this closeout was written — see §7.10, which is also this
registry's first real N=3 and answers both carried constraints above from
shipped code (§7.10.5).**

### 7.10 E2d - clearcoat / coat layer

**Status: landed and measured against Cycles.** Full task-by-task record:
`.superpowers/sdd/2026-08-27-clearcoat-coat-layer/task-{1..7}-report.md`.

*(This section was committed in two parts: the Cycles measurement first, so it
could not be lost, then the closeout narrative. See §7.10.1 onward.)*

#### 7.10.1 The Cycles comparison — car paint

**Blender ran headlessly here.** `Blender 4.5.3 LTS`, `blender.exe -b -P`,
Cycles on **OptiX / NVIDIA RTX A4000** (device selected by the E2a/E2b
fallback chain and printed, not assumed), 1024 samples, denoising and adaptive
sampling off, `view_transform = Standard`, exposure 0, gamma 1. The harness
also printed Blender's live Principled BSDF socket list before touching it, so
`Coat Weight` / `Coat Roughness` / `Coat IOR` / `Coat Tint` are confirmed to
exist under those names in this version rather than assumed from the manual.

**Scene** — a **car-paint sphere**, E2's own stated acceptance target (§4,
"car paint and velvet"): metallic base `roughness = 0.25`, base colour linear
`(0.30, 0.05, 0.05)`, `clearcoat = 1.0`, `clearcoat_roughness = 0.1`,
`clearcoat_ior = 1.5` (the default), under a spatially uniform environment of
radiance 1.0. Sphere radius 1.0 at origin, 64×32 segments; camera at Godot
`(0,0,2.5)` / Blender `(0,-2.5,0)` under `blender(x,y,z) = godot(x,-z,y)`; 20°
vertical FOV on 256×256. Radius 1.0 at distance 2.5 subtends 23.58° against a
14.0° diagonal half-angle, so **every pixel in every render is a sphere hit**
and the whole-image mean is a surface-only statistic. Godot: `max_bounces=3`,
`SPP=1`, 256 accumulated frames. Cycles: bounces matched at 3. **Bounce depth
is not a free variable here** — a lone convex sphere cannot re-hit itself.

**Colour space, the trap this phase family has hit twice.**
`render_raytracing.cpp:1585` sRGB-decodes `albedo_color` on upload and `:1855`
does the same to `clearcoat_tint`; Cycles' sockets are linear. So both colours
were authored `Color(<linear>).linear_to_srgb()` on the Godot side and Blender
was given the same `<linear>` number — each renderer compared against the same
authored *linear* value, never field-for-field against the other. The harness
printed the round trip through the engine's own `Color` methods:

```
ALBEDO linear=(0.30000001,0.05,0.05) -> authored srgb=(0.58383155,0.24780053,0.24780053)
                                     -> engine decode=(0.30000004,0.05,0.05)
```

**Raw comparison** (production code, HEAD `df779c6b65`, nothing tuned):

| arm | Godot mean | Cycles mean | ratio | % off |
|---|---|---|---|---|
| car paint (`clearcoat=1.0`) | 0.16867638 | 0.16803674 | 1.003807 | **+0.381%** |
| uncoated control (`clearcoat=0`) | 0.13358590 | 0.13292308 | 1.004986 | +0.499% |
| amber-tinted coat | 0.14654985 | 0.14598414 | 1.003875 | +0.388% |

Per channel, car paint: R `1.005603`, G `1.000476`, B `1.000476`.

**The raw figure passes the 5% bar with an order of magnitude to spare, with
no adjustment at all** — a materially better starting point than E2b, which
needed the `ms` attribution to get from +6.52% to +0.67%. The per-channel
split says why: the gap sits almost entirely in R, the channel with the bright
base colour (linear 0.30), and is near zero in G/B where the base is dark
(0.05). That is Gap #17's `F0`-dependent pedestal, small here because the base
roughness is 0.25 rather than E2b's 0.4-plus-anisotropy.

**The coat-only delta — the layer isolated by subtraction.** Subtracting the
uncoated arm from the coated arm *inside each engine* cancels every
base-specular term, Gap #17 included, without touching any code. What remains
is exactly what the layer contributes: its own reflection minus the withdrawal
it takes from the base.

| | R | G | B | mean |
|---|---|---|---|---|
| Godot delta | 0.02829920 | 0.03848612 | 0.03848612 | 0.03509048 |
| Cycles delta | 0.02836713 | 0.03848692 | 0.03848692 | 0.03511366 |
| ratio | 0.997605 | 0.999979 | 0.999979 | **0.999340 (-0.066%)** |

**The layer itself agrees with Cycles to 0.066% in the mean and 0.002% on the
dark channels.** The residual −0.24% on R is in the channel Gap #17 lives in,
in the direction subtraction leaves when the pedestal is not perfectly linear
in the base's contribution.

**Beer's-law coat tint** — `tinted / carpaint` within each engine isolates the
optical-depth attenuation from everything else:

| | Godot | Cycles | ratio of ratios |
|---|---|---|---|
| R | 0.909826 | 0.909898 | 0.999921 (−0.0079%) |
| G | 0.861141 | 0.861197 | 0.999934 (−0.0066%) |
| B | 0.723697 | 0.723813 | 0.999840 (−0.0160%) |

Better than 0.02% on all three channels, with `clearcoat_tint` authored
linear `(0.90, 0.75, 0.50)` on both sides. This is a genuine formula match:
`brdf_inc.glsl:2324-2327` mirrors `svm/closure.h:196-203` term for term,
including refracting into the coat before measuring path length
(`cosNT = sqrt(1 - (1/ior)^2 (1 - cosNI^2))`, `optical_depth = 1/cosNT`) and
including the `mix` against `coat_weight` rather than a bare multiply.

**Positive control — the colour-space trap, reproduced.** A Cycles-only arm
with `Base Color` set to the sRGB-encoded number an artist reads off the Godot
Inspector, fed to Blender as if it were linear — the exact field-for-field
error that inverted §7.7's verdict — measured `0.38487698` against the
reconciled arm's `0.16803674`: **ratio 2.290434, +129.0%**, i.e. 340× the size
of the gap being measured. The control is internally consistent too: if the
render were exactly linear in base colour, `srgbcontrol/carpaint` would equal
the base-colour ratio, but measured `1.831147` (R) and `3.141887` (G) sit
*below* predictions of `1.946105` and `4.956011`, by more on the channel with
the larger base ratio — exactly what a base-colour-independent additive term
does, and the coat's own reflection is precisely such a term. The control
therefore confirms both the trap's direction and the coat's presence.

**Adjusted comparison — Gap #17's pedestal neutralised.** The rest of the
+0.381% is Gap #17, and this is the measurement that says so. Using the same
technique E2b's Task 4 and Task 5 used — temporary shader edit, rebuild,
measure, revert, rebuild, `git diff` confirmed empty on both files before and
after — `ms` was forced to `vec3(1.0)` at the base-specular
`evalMultiScatterApproximation` call sites, which the coat does not use:

| arm | Godot `ms=1` | Cycles | ratio | **adjusted % off** | raw % off | points moved |
|---|---|---|---|---|---|---|
| car paint | 0.16787156 | 0.16803674 | 0.999017 | **−0.098%** | +0.381% | 0.479 |
| uncoated control | 0.13274812 | 0.13292308 | 0.998684 | −0.132% | +0.499% | 0.630 |
| amber-tinted coat | 0.14584120 | 0.14598414 | 0.999021 | −0.098% | +0.388% | 0.485 |

**Raw +0.381%, adjusted −0.098%.** Both are reported; neither is the
flattering one alone. The pedestal is worth 0.479 points on the coated arm and
0.630 on the uncoated one, i.e. removing it slightly *overshoots* and flips the
sign — consistent with §7.8's finding that `evalMultiScatterApproximation`
over-corrects a real single-scatter deficit rather than inventing energy from
nothing. E2b's precedent on this same technique was +6.52% → +0.67%; E2d's is
+0.381% → −0.098%, a far smaller pedestal because the base here is roughness
0.25 and isotropic.

**The `ms` edit did not touch the coat, and the numbers prove it, not the
diff.** The coat-only delta under `ms = 1.0` is `0.03512344` against the
production build's `0.03509048` — a ratio of `1.000939`, i.e. within
Monte-Carlo run-to-run noise. Task 5b routed the coat's compensation through
`coatEnergyScale` specifically so Gap #17 and the coat's own energy accounting
would be separable, and this is that separation measured end to end. It is the
same conclusion Task 6's probe C2 reached from the other side: the pedestal on
a metal reads +6.0%, **unchanged by the coat**.

**Correction to the brief this section was written from — four call sites,
not three, and the line numbers had moved.** The brief named
`brdf_inc.glsl:1192`, `:1348` and
`raytracing_closest_hit_common_inc.glsl:1270`, inherited from §7.8. After Task
5b split `sampleSpecularMicrofacet` the real sites are `brdf_inc.glsl:1274`,
`:1418` and `raytracing_closest_hit_common_inc.glsl:1525` — **and a fourth,
`raytracing_emissive_inc.glsl:495`, which predates E2b entirely** (added by C1,
commit `72c45f163b`) and which §7.8's "all three reachable call sites"
therefore already undercounted. It is unreachable in this scene (no emissive
geometry, as is `:1418`'s dielectric path on a metallic base), so it does not
affect the figures above, but the count is wrong wherever it appears.

#### 7.10.2 The coat is a layer, not a lobe

This is the distinction that makes it Blender's coat rather than a fourth
highlight. The coat is a GGX lobe at registry index 2 — but it also
**withdraws energy from everything beneath it**, and the withdrawal is what
the feature is. Cycles does this with `closure_layering_weight`
(`svm/closure.h:174`); E2d ports it.

**The layer conserves energy, measured.** Task 6's probe B reads **1.0 to
within 1.3e-4, flat across all 36 configurations** of clearcoat x coat
roughness x ior. That is the first time any coat code in this phase had
executed at all: every pre-existing gate scene is `clearcoat == 0`, so Tasks
1-5b compiled and shipped a feature that had never run.

**Task 5b closed a real energy gap, and spec §3.5 was wrong.** The spec
claimed `evalMultiScatterApproximation` was the equivalent of Cycles'
`microfacet_ggx_preserve_energy`. **It is not.** Ours is `1 + F0*Ems`, which
at the coat's `F0 = 0.04` evaluates to about 1.002 and recovers almost none of
the GGX single-scattering deficit, while Cycles is table-driven full
compensation. Because the withdrawal uses Cycles' average Fresnel as an
albedo — valid only *because* Cycles compensates — the base lost
`coatWeight * <F>` while the coat paid back only `coatWeight * <F> * E_ss`. The
difference vanished. Measured payout/withdrawal at the default
`clearcoat_roughness` 0.5: **0.911 at normal incidence, 0.736 at cosNI 0.3** —
a coated white sphere darkening toward its silhouette with no physical source.
Fixed by porting Cycles' `table_ggx_E` (32x32) and `table_ggx_Eavg` (32).
**Gap #17 remains untouched for the base specular**, deliberately: 5b's scope
was the coat only, and probe C2 confirms the base pedestal is still +6.0% on a
metal and unmoved by the coat.

**Spec §4.1's withdrawal formula was incomplete too, and the proof is an
ordering across three Cycles files.** The spec compensated only the payout.
Cycles darkens the **withdrawal** as well:
`bsdf_microfacet_setup_fresnel_dielectric` (`svm/closure.h:169`) runs
`microfacet_ggx_preserve_energy`, which does `bsdf->weight *= darkening`
(`bsdf_microfacet.h:482`); *then* `bsdf_albedo` (`closure.h:172-173`) starts
from `sc->weight` (`bsdf.h:696`), which now carries that darkening; *then*
`closure_layering_weight` consumes it (`closure.h:174`). So the withdrawal is
`coat_weight * darkening * estimate`, not `coat_weight * estimate`.
Payout-only compensation moves the ratio from `E = 0.915` to `E*C = 0.922` —
it does **not** close the gap. The shipped fix puts
`coatDarkening = E + Fms*(1-E)` on `coatLayerAlbedo` so both sides are equal by
construction.

**Exact dielectric Fresnel replaced Schlick-with-`shadowedF90`.**
`shadowedF90(F0) = min(1, F0/0.04)` caps the coat's grazing reflectance below 1
for *every* `clearcoat_ior < 1.5`, while the withdrawal's table assumes a
Fresnel that reaches 1 — pure energy loss, and `clearcoat_ior`'s Inspector
range is `1,3,0.01`, so this is an ordinary artist setting, not a corner. Task
6's probe E measures the fix: all 15 readings land within 0.7% of exact
Fresnel, **including ior 1.1 at cos 0.15, where the old path read 5.4x low.**

#### 7.10.3 The raster divergence — read this before filing a bug

**The same authored material does not look the same in the viewport and in the
path tracer, and this is known, not a defect report waiting to be written.**
Two independent divergences, both in `scene_forward_lights_inc.glsl`:

1. **Roughness-to-alpha mapping.** The path tracer uses `alpha = r^2`,
   matching Cycles (`svm/closure.h:165`,
   `bsdf->alpha_x = bsdf->alpha_y = sqr(coat_roughness)`). The raster uses
   `mix(0.001, 0.1, r)` (`scene_forward_lights_inc.glsl:212`) — a completely
   different curve with a hard 0.1 ceiling, so the raster's coat can never get
   rougher than `alpha = 0.1` no matter what the artist types.
2. **The raster coat is purely additive.** It adds a clearcoat highlight on top
   and **withdraws nothing** from the layers below. The path tracer's coat is a
   layer that attenuates the base, per Cycles. A `clearcoat = 1.0` metal
   therefore reads brighter in the viewport than in the path tracer *and* has a
   differently-shaped highlight.

Anyone comparing viewport and path-traced screenshots of a coated material will
see a difference. It is the raster that diverges from Cycles here, not the path
tracer, and closing it means changing every existing Forward+ scene's
appearance — which is why E2d did not.

#### 7.10.4 The albedo LUT, and why it is an SSBO

`ggx_gen_schlick_ior_s` (16x16x16), `table_ggx_E` (32x32) and `table_ggx_Eavg`
(32) are copied **verbatim** out of Cycles' `shader.tables` -- the 16x16x16
albedo table into `ggx_coat_albedo_table.h`, the two energy tables into
`ggx_energy_tables.h` -- and uploaded as one flat, concatenated SSBO at
binding 38 (`RenderRaytracing::_get_coat_albedo_buffer`). The Task 1
reviewer re-extracted the first table from `shader.tables` independently and
diffed **all 4096 entries** — zero mismatches, not five spot checks — and Task
5b's reviewer did the same for 1024/1024 and 32/32.

**It is deliberately an SSBO with hand-written trilinear interpolation, not a
filtered 3D texture,** and the shipped comment at `brdf_inc.glsl:1883` says
why:

> Hardware filtering is half-texel-centered; it would compile, render
> plausibly, and be wrong by half a texel at every lookup — a small, uniform,
> entirely silent energy error.

Cycles' `lookup_table_read*` is **endpoint-aligned**: `[0,1]` maps onto
`[0, size-1]` and lerps between integer entries. A `sampler3D` maps `[0,1]`
onto texel *centres*. The two disagree everywhere. Task 1 proved the property
rather than asserting it: the half-texel form was temporarily substituted and
the grid-point and midpoint doctest cases failed with distinctly different
values (midpoint x: `0.987179` observed against `0.849810` expected), then
reverted clean.

**The known limit, stated plainly.** The GLSL `coatLutRead3D` has **no
automated test** — doctest cannot execute GLSL, and Task 1's cases guard only
the CPU mirror. Vis mode 38 compares three sampled points; a transcription slip
that happens to agree at those three would survive. The mitigation is the same
one §7.9 recorded for lobe order: **read the two implementations side by side**,
which the Task 4 reviewer did, line by line, against Cycles'
`lookup_table.h:14-71`, `bsdf_microfacet.h:504-568` and `bsdf_util.h:290-292`.

#### 7.10.5 The first real N=3

§7.9's extensibility proof was inert by construction: a third lobe of weight
`0.0` and pdf `0.0`, which `acc + 0.0f` makes bit-exact. **E2d is the first
real third lobe**, and Task 5 answered §7.9's two carried constraints from
shipped code rather than from the plan:

1. **Summation order.** `combineLobePdf` still ascends specular -> diffuse ->
   coat, so the grouping is pinned as `((s + d) + c)` and both consumers index
   by name. Specular remains index 0, which §7.9 named as contract.
2. **The trailing fallback is unreachable, and no guard was added.** §7.9
   warned "a zero-weight lobe must not be placed last"; the coat is a real
   lobe, so the fallback is correct for it. Beyond that, `selectLobe`'s
   `return LOBE_COUNT-1` cannot fire on a zero-weight coat: at `coatMass == 0`
   the base weights are `fl(pSpec)` and `fl(1-pSpec)`, which sum to **exactly**
   `1.0f` for every float32 `pSpec` (Sterbenz above 0.5; half-ulp rounding back
   below it — 10M random samples, zero exceptions), and `rng_1d` bottoms out in
   `sb_uint_to_float_excl` (`sobol_burley_inc.glsl:118`, dividing by
   `4294967808.0`) so `u < 1.0` strictly. `/fp:strict` is forced on this
   platform (`platform/windows/detect.py:408`), closing the reassociation
   escape hatch. **The proof is recorded so the guard is not added later out of
   caution.**

One real defect surfaced from the wrong analysis that produced this proof:
`coatLobeWeight` originally returned `coatWeight * estimate` **unclamped**,
while `lobeWeight` ends in `clamp(..., 0.01f, 0.99f)` for exactly this reason.
The sampler divides throughput by the selected weight, so a coat just above the
`1e-5` cutoff with estimate about 0.04 gives about 4e-7 and a 2.5-million-fold
firefly, reachable on any faintly coated material. The clamp is mirrored.

**Where the coat sits in the mixture is not where the plan said it was.** The
weights block is inside the `else` of a **three-way** branch whose first arm is
`diffuseLum < 0.0001` — i.e. **pure metal**, which is exactly what car paint
is. Placing the coat there without gating that fast path would have left the
feature silently inert on this phase's own stated acceptance target. Both fast
paths are now gated on `coatMass <= 0.0`, exact at `clearcoat == 0`.

#### 7.10.6 The gate, proven by breaking it

Deleting `* coatDarkening` at `brdf_inc.glsl:2081` — one factor, the Task 5b
fix — turns **7 of probe B's 17 rows red, worst −0.0591**, and takes probes C2
and F with them. Restored, rebuilt, green. The magnitude follows from the code
rather than from the observation: the deficit is
`cw * estimate * (1 - darkening)`, which at (roughness 0.90, ior 2.00, `cw` 1)
predicts about 0.060 against 0.0591 measured, with 1:2:4 linearity in `cw`
because neither `estimate` nor `darkening` depends on it. The gate is an
instrument, not a rubber stamp.

**Two probes were red before the code was, and both times it was the probe.**
Probe E's first two failures were (a) evaluating analytic `F` at the bin's
*mean* cos — a Jensen error worth 11 percentage points — and (b) reading a
1.3-pixel grazing annulus on a *tessellated* sphere through an *analytic* cos
map, leaking sky at a fitted 0.060/0.067/0.064 across three IORs. Replaced with
a tilted quad, where the ray-plane intersection **is** the ray-mesh
intersection. Probe G was red because **the RNG seed is a free-running frame
counter**: no two accumulations in this engine are bit-identical (7.6e-4 rmse
between two renders of the *same* material). "Identical inputs produce
identical pixels" is false here, and any future gate that assumes it will be
red on correct code.

#### 7.10.7 What E2d does not deliver

**`coat_normal` is the one piece of Blender coat parity E2d does not ship.**
Cycles exposes a separate normal for the coat layer, and it needs a texture
slot on `BaseMaterial3D` plus the plumbing Phase D established. It is deferred
not merely for cost but because it is **entangled with sheen**: in Cycles the
coat normal also bends the *sheen* normal —
`bsdf->N = safe_normalize(mix(N, coat_normal, saturatef(coat_weight)))` at
`svm/closure.h:127-129`, inside the sheen block, before the coat block even
runs. Implementing `coat_normal` without sheen would ship half of a coupled
pair. **It belongs to E2e.**

Also carried, unfixed:

- **Self-emission is not attenuated by the coat.** Cycles multiplies emission
  by the post-layering, post-tint weight (`svm/closure.h:204-210`, "attenuated
  by sheen and coat"). An emissive panel with `clearcoat = 1` and a red tint
  renders full-strength white here and red at about 78% in Cycles.
- **Two different "is there a coat" predicates.** `evalCoat` gates on
  `coatWeight <= 1e-5`; `coatLobeWeight` gates on `coatLayerAlbedo <= 0.0`.
  They disagree at exactly `clearcoat_ior == 1.0` (a legal value), where the
  coat would have a *value* in NEE but zero *density* in `combinedPdf`.
  Harmless today only by two independent coincidences in two files — the
  table's whole `z == 0` slice is zero **and** `F0 = F90 = 0` there. Make both
  gates the same predicate.
- **No near-delta guard on the coat at the three analytic-light sites.** At
  `clearcoat_roughness 0` the `Microfacet_D` floor returns about
  `F*7950/NdotV` (evalMicrofacet's optimized G2 already carries the
  `4*NdotL*NdotV` denominator, so the returned `G2*D*NdotL` term cancels
  `NdotL`, leaving only `NdotV`). Pre-existing convention — the base specular
  behaves the same — but a mirror-coated car body under a point light is
  E2d's own acceptance target.
- ~~`GGX_E_DIM` is hardcoded as a literal `32` at `brdf_inc.glsl:2007` and
  `:2016`~~ **Fixed in the E2d final fix wave.** `brdf_inc.glsl` now defines
  `#define GGX_E_DIM 32` beside `GGX_COAT_TABLE_DIM` and both call sites read
  through it; `test_pt_coat_albedo.cpp`'s SSBO-offset doctest additionally
  pins `GGX_E_DIM == 32` and `GGX_COAT_TABLE_DIM == 16` as literals, the same
  way it already pinned the four byte offsets. A re-extraction that resizes
  the energy tables now has to touch the shader's own dimension constant and
  its doctest pin, not just the offsets, to stay green.
- **The coat reads `materials[h.geometry_idx]`, not `MaterialResult`**, so a
  custom `ShaderMaterial` fragment cannot drive the coat per-pixel — identical
  to how E2b's anisotropy behaves. Recorded, not changed.
- **The denoiser albedo AOVs do not know the coat exists.**
  `raytracing_closest_hit_common_inc.glsl`'s DLSS-RR G-buffer block calls
  `DLSSRR_computeDiffuseAlbedo(m.albedo, m.metalness)` and
  `DLSSRR_computeSpecularAlbedo(m.albedo, m.metalness, brdf_mat.dielectricF0,
  m.roughness, NdotV)` — all base-material inputs, feeding `sl::kBufferTypeAlbedo`
  / `kBufferTypeSpecularAlbedo` and OIDN's `cleanAux`. The diffuse albedo AOV
  now **overstates**: it reports the base's pre-withdrawal reflectance, but the
  coat's `darkening` factor (Task 5b) actually removes energy from the base
  before it reaches the camera (roughly 4% at `ior 1.5` / `roughness 0.5`, up
  to ~11% at grazing). The specular albedo AOV **omits the coat lobe entirely**
  — a car-paint highlight the coat contributes is invisible to the denoiser's
  specular-albedo guide. The normal/roughness AOV (`imageStore(...,
  vec4(N, m.roughness))`) reports the **base's** roughness, but on a
  clearcoated surface the visible highlight sharpness is the coat's, not the
  base's. Transmission (E1) and anisotropy (E2b) already share the general
  "AOVs are base-material-only" gap, but E2d is the **first** phase where the
  base's own radiometry is actually reduced by something above it — which is
  what turns the diffuse AOV from merely incomplete into actively wrong.
  Recorded here as an open item; not fixed by this fix wave, which is
  comment-and-constant-only.
- **`evalCombinedBRDF` (`brdf_inc.glsl:1745`) is dead code and, since E2d,
  silently coat-free.** Grepped every call site in the raytracing shader
  tree: none — the only occurrence outside its own definition is the
  definition itself. Confirmed **pre-existing, not an E2d regression**: it
  was equally dead at `b30502af56` (the pre-E2d baseline), which has the same
  single occurrence. Its risk is not that it runs, but that it is cited as
  the authority for the `Vbackfacing` early-out by four comments in two other
  files — `raytracing_closest_hit_common_inc.glsl:1488`, `:1503`, `:1890`,
  and `raytracing_emissive_inc.glsl:470` (not the "five comments in three
  files" a draft of this note claimed; only `evalCombinedBRDFSeparate`, not
  the bare `evalCombinedBRDF`, appears in `brdf_inc.glsl` outside its own
  definition). Those four comments are correct today, but a future caller
  who trusts them and calls `evalCombinedBRDF` for its `Vbackfacing`
  behaviour would get an **unlayered, coat-free** base BRDF that compiles
  cleanly and silently omits the coat lobe entirely — `evalCombinedBRDF` was
  never updated to call `evalCoat` the way `evalCombinedBRDFSeparate` was.
  Recorded as an open item: either delete the dead function or teach it
  about the coat so it cannot silently regress if resurrected.

**One open item found here that is orthogonal to E2d and belongs to a later
phase: 2.7% of production BSDF draws on a roughness-0.4 sphere are rejected
and mirrored back into the hemisphere with MIS weight 1.** Measured by Task
6's vis mode 40, not fixed, not caused by the coat. It is a candidate roadmap
item in its own right — a rejection-and-mirror with an unadjusted MIS weight is
the F1 `recoverBelowHemisphereSample` family of problem, not a coat problem.

**Unexercised paths.** "Read the code and found no defect" is not the same
claim as "measured, and it works" — recorded here rather than left implicit,
since the whole point of this gate suite is to not rely on the former:

- **The three analytic-light coat NEE sites, and the emissive-mesh site, have
  never executed under any gate or measurement in this repository.**
  `raytracing_lights_inc.glsl:394/568/617` (the coat's contribution for
  omni/spot/directional lights) and `raytracing_emissive_inc.glsl:489`/`:503`
  (emissive-mesh NEE) are four of the five call sites Task 5's fix round
  created for `evalCombinedBRDFSeparate`'s coat term. `pt_coat_gate.gd` has
  no `Light3D` node and no emissive material anywhere in it (grepped) — it is
  sky/furnace-only, same as `pt_energy_gate.gd`, `pt_anisotropy_gate.gd`, and
  `pt_transmission_gate.gd`, none of which ever sets `clearcoat` at all
  (grepped, zero matches in all three). §7.10.1's Cycles comparison is also
  sky-only (a "spatially uniform environment"). A coated material lit by a
  point light, a spot, a directional light, or standing next to an emissive
  mesh has never been rendered by anything in this tree.
- **The Beer's-law tint has no gate.** Every probe in `pt_coat_gate.gd`
  builds its material through `_apply_coat`, which hardcodes
  `p_mat.clearcoat_tint = Color(1.0, 1.0, 1.0).linear_to_srgb()` — white,
  i.e. the identity transmittance. Task 7's single Cycles car-paint
  measurement (tint agreement to 0.016%, §4) is the tint's **entire**
  coverage; there is no automated regression check on `clearcoat_tint` at
  any non-white value.
- **Coat-on-glass has never rendered.** `pt_transmission_gate.gd` never sets
  `clearcoat` (it stays at `BaseMaterial3D`'s default, 0), so the interaction
  between the coat layer and the dielectric transmissive lobe — both drawing
  from the same three-lobe registry — is unmeasured.

#### 7.10.8 Verification

doctest **1542 passed / 0 failed / 3 skipped** (2,066,790 assertions), on the
restored production binary after the `ms` diagnostic was reverted and rebuilt.
All four GPU gates PASS on that same binary: `pt_coat_gate` (all seven probes),
`pt_energy_gate`, `pt_anisotropy_gate`, `pt_transmission_gate` (44 checks;
probe 6 on the good mode of the bimodality §7.9 records). No engine source file
is modified by this closeout — `git diff` on `servers/` is empty.

**Phase table.** Under §4's "E2. Anisotropy, clearcoat, sheen": anisotropic GGX
is complete (§7.8), the two-way to N-way lobe rewrite is complete (§7.9), and
**clearcoat is now complete (E2d, this section)** — the acceptance target "car
paint ... responds comparably to Cycles" is **met**, at +0.381% raw / −0.098%
adjusted against a 5% bar, with the layer's own contribution matching to 0.066%
and its Beer's-law tint to 0.016%. What remains under that heading:

- **Sheen (E2e)** — not started.
- **`coat_normal`** — deferred into E2e, since Cycles couples it to the sheen
  normal (`svm/closure.h:127-129`).
- **Anisotropy on the transmissive lobe** — still needs the refracted-direction
  eval/pdf machinery described at the end of §7.8.

### 7.11 E2e — sheen (Zeltner LTC) and the N-layer stack

**Status: landed and measured against Cycles.** Full task-by-task record:
`.superpowers/sdd/2026-08-28-sheen-zeltner-ltc/task-{1..6}-report.md`, with the
dispatch ledger in that directory's `progress.md`.

*(Committed in two parts, as §7.10 was: the Cycles measurement first so it
cannot be lost, then the closeout narrative. §7.11.1 is the measurement.)*

#### 7.11.1 The Cycles comparison — velvet

**Blender ran headlessly here.** `Blender 4.5.3 LTS` (hash `67807e1800cc`),
`blender.exe -b -P`, Cycles on **OptiX / NVIDIA RTX A4000** (selected by the
E2a/E2b/E2d fallback chain and *printed*, not assumed), 1024 samples, denoising
and adaptive sampling off, `view_transform = Standard`, exposure 0, gamma 1.
The harness printed Blender's live Principled BSDF socket list before touching
it, so **`Sheen Weight` / `Sheen Tint` / `Sheen Roughness` are confirmed to
exist under those names in this version** rather than assumed from the manual.

**Scene** — a **velvet sphere**, E2's own second stated acceptance target (§4,
"car paint and velvet"): dielectric base `metallic = 0`, `roughness = 0.60`,
base colour linear `(0.12, 0.02, 0.03)` (a deep red velvet), sheen colour linear
`(0.75, 0.70, 0.55)`, under a spatially uniform environment of radiance 1.0.
Sphere radius 1.0 at origin, 64×32 segments; camera at Godot `(0,0,2.5)` /
Blender `(0,-2.5,0)` under `blender(x,y,z) = godot(x,-z,y)`; 20° vertical FOV on
256×256. Radius 1.0 at distance 2.5 subtends 23.58° against a 14.00° diagonal
half-angle, so **every pixel in every render is a sphere hit** and the
whole-image mean is a surface-only statistic — the same geometry §7.10.1 used,
reused deliberately so the two comparisons sit on one footing. Godot:
`max_bounces = 3`, `SPP = 1`, 256 accumulated frames. Cycles: bounces matched at
3; a lone convex sphere cannot re-hit itself, so bounce depth is not a free
variable either way. **Coat is off on both sides** — `coat_normal` is not
shipped (§7.11.10), and at `coat_weight = 0` Cycles' sheen normal
`mix(N, coat_normal, coat_weight)` (`svm/closure.h:127-129`) collapses to `N`,
holding the one known geometric divergence at zero rather than leaving it free.

Harness: `pipeline_references/tests/pt_sheen_reference.gd`, **committed**. E2d's
equivalent was kept outside the repo and is now unrecoverable, which is why this
one is not.

**`sheen_color` is Cycles' `sheen_weight * sheen_tint`, not its tint.**
`brdf_inc.glsl:334-338` folds the weight into the colour; `svm/closure.h:123-124`
forms the closure weight as `sheen_weight * rgb_to_spectrum(sheen_tint) *
weight`. The Blender arms therefore set `Sheen Weight = 1.0` and `Sheen Tint` to
the same linear triple, reproducing an identical closure weight rather than an
approximately equal one.

**`sheen_roughness` had to be set explicitly, and that is a trap, not a detail.**
Godot defaults it to `0` (`scene/resources/material.h:579`) while Cycles'
Principled defaults it to `0.5`, and **90 of the 1024 LTC cells fail the
invalid-LTC test, all of them in the lowest roughness rows**. A velvet scene
that sets `sheen_color` and leaves roughness alone renders *no sheen at all*,
measures a zero delta against its own control, and **reads as a suspiciously
good match**. Every arm below sets it.

**Colour space, the trap this phase family has now had to defuse three times.**
`render_raytracing.cpp:1827` sRGB-**decodes** `sheen_color` on upload, exactly as
`:1595` does to `albedo`; Cycles' sockets are linear. Both colours were authored
`Color(<linear>).linear_to_srgb()` on the Godot side and Blender was handed the
same `<linear>` number — each renderer compared against the same authored
*linear* value, never field-for-field against the other. The harness printed the
round trip through the engine's own `Color` methods:

```
BASE  linear=(0.12000000,0.02000000,0.03000000) -> authored srgb=(0.38109186,0.15170372,0.18974829) -> engine decode=(0.12000000,0.02000000,0.03000000)
SHEEN linear=(0.75000000,0.69999999,0.55000001) -> authored srgb=(0.88082504,0.85430586,0.76737565) -> engine decode=(0.75000000,0.70000005,0.54999995)
```

**One reader, two sides.** The Blender script measures the Godot EXRs with the
*same* numpy / `foreach_get` path it measures its own with. Godot's in-engine
GDScript mean and Blender's reading of the same EXR agree to 1e-8
(`0.10321895` vs `0.10321895`), so the whole-image means come from one code path
rather than two that could quietly disagree.

**Raw comparison** (production code, HEAD `90dee99fd9`, nothing tuned):

| arm | sheen rough | Godot mean | Cycles mean | ratio | % off |
|---|---|---|---|---|---|
| velvet | 0.50 | 0.10321895 | 0.10501504 | 0.982897 | **−1.710%** |
| velvetsharp | 0.30 | 0.08839816 | 0.09024246 | 0.979563 | −2.044% |
| velvetrough | 0.80 | 0.20540086 | 0.20694485 | 0.992539 | −0.746% |
| nosheen (control) | — | 0.08770339 | 0.08954956 | 0.979384 | −2.062% |

Per channel, velvet: R `0.986766`, G `0.978182`, B `0.978850`.

**Every arm passes the 5% bar with no adjustment at all**, but the *shape* of
the table is the finding: the un-sheened control is the **worst** arm at
−2.062%, and the more sheen an arm carries the closer it gets (−2.06% → −2.04%
→ −1.71% → −0.75% as the sheen's share of the image rises). The residual is the
**base**, not the sheen — and it is a *deficit*, the opposite sign to §7.10.1's,
on a `metallic = 0, roughness = 0.60` dielectric base rather than E2d's polished
metal. §7.11.2 is the measurement that tests whether Gap #17 explains it.

**The sheen-only delta — the layer isolated by subtraction.** Subtracting the
`nosheen` arm from each sheen arm *inside each engine* cancels every base
diffuse and base-specular term, Gap #17 included, without touching any code.
What remains is exactly what the layer contributes: its own reflection minus the
withdrawal it takes from the base.

| arm | Godot delta (mean) | Cycles delta (mean) | ratio | % off |
|---|---|---|---|---|
| velvetsharp (0.30) | 0.00069477 | 0.00069290 | 1.002689 | **+0.269%** |
| velvet (0.50) | 0.01551556 | 0.01546548 | 1.003238 | **+0.324%** |
| velvetrough (0.80) | 0.11769747 | 0.11739529 | 1.002574 | **+0.257%** |

Per channel on the headline arm: R `1.003567`, G `1.002802`, B `1.003394` — a
**flat** offset across channels, i.e. a scale, not a tint error.

**The sheen layer itself agrees with Cycles to better than 0.33% at every
roughness, and its sign is opposite to the raw figure's.** The layer is slightly
*brighter* while the whole image is *darker*, which is only visible because the
control arm exists. A comparison without one would have reported −1.71% and
attributed it to sheen.

**The roughness ladder — the cross-engine test of the transposed LUT axes.** The
sheen table is indexed `(cosNI, roughness)`, transposed relative to the coat's
`(roughness, mu)` (`bsdf_sheen.h:38-42` against `brdf_inc.glsl:2038`). A
transposition does not merely rescale the response; it changes its *shape* along
roughness, which no single arm can see. The three deltas' ratios to each other:

| | 0.30 | 0.50 | 0.80 |
|---|---|---|---|
| Godot | 1 | 22.332 | 169.406 |
| Cycles | 1 | 22.320 | 169.425 |

**A 169× dynamic range reproduced to 1.1e-4 relative.** This is the strongest
evidence in the phase that the axis order is right, and it is evidence Task 1's
CPU mirror structurally could not give: the mirror's axis-order case guards its
own *reader*, not the call site (ledger, Task 1 Step 4), and Task 5's probe A
compares a handful of table points against a parser of the same header. The
ladder compares the engine's *rendered response* against an independent
implementation across the whole roughness axis.

**Where the sheen's own colour goes.** Normalised to R, the delta's hue is
`1 : 1.0344 : 0.7881` in Godot and `1 : 1.0352 : 0.7883` in Cycles — agreeing to
0.08%, and both *differing* from the authored tint's `1 : 0.9333 : 0.7333`,
because the delta is the sheen's reflection *minus its withdrawal from a red
base* and the two mix per channel. Both engines mix them the same way. That is
`closure_layering_weight`'s arithmetic showing up in a measurement rather than
in a comment.

**Positive control — the colour-space trap, reproduced.** A Cycles-only arm with
`Base Color` *and* `Sheen Tint` set to the sRGB-encoded numbers an artist reads
off the Godot Inspector, fed to Blender as if they were linear — the exact
field-for-field error that inverted §7.7's verdict — measured `0.28263608`
against the reconciled arm's `0.10501504`: **ratio 2.691387, +169.1%**, i.e.
**99× the size of the gap being measured**. The harness would not miss this
error. E2d's equivalent control read +129.0%; the trap is larger here because
both the base and the sheen colour carry it.

**Run-to-run noise floor, measured rather than assumed.** The identical binary
was run twice: `velvet` `0.10321895` vs `0.10321940`, `nosheen` `0.08770339` vs
`0.08770337`, `velvetrough` `0.20540086` vs `0.20539667` — relative spreads of
4.4e-6, 2.3e-7 and 2.0e-5. Every figure quoted above sits two to four orders of
magnitude above that floor, **including the 0.00069 `velvetsharp` delta**, which
is the only one small enough to be worth checking.

#### 7.11.2 The Gap #17 adjustment — and the result it did not give

Same technique §7.8's Task 4/5 and §7.10.1 used: temporary shader edit, full
rebuild, measure, revert, rebuild, `git status` on `servers/` confirmed clean
before and after. `ms` was forced to `float3(1.0)` at **all four**
`evalMultiScatterApproximation` call sites.

**The four sites, and their line numbers have moved again.** §7.10.1 named
`brdf_inc.glsl:1274`, `:1418`, `raytracing_closest_hit_common_inc.glsl:1525` and
`raytracing_emissive_inc.glsl:495`. At this HEAD they are **`brdf_inc.glsl:1292`,
`:1436`, `raytracing_closest_hit_common_inc.glsl:1639`,
`raytracing_emissive_inc.glsl:495`**. Three of the four have drifted between two
consecutive phases; quote them with a commit or not at all. The reachable one
here is `:1436`, the **dielectric** path — the opposite of §7.10.1, whose
metallic base reached `:1292`.

| arm | Godot `ms=1` | Cycles | ratio | **adjusted % off** | raw % off | points moved |
|---|---|---|---|---|---|---|
| velvet | 0.10277130 | 0.10501504 | 0.978634 | **−2.137%** | −1.710% | −0.426 |
| velvetsharp | 0.08794067 | 0.09024246 | 0.974493 | −2.551% | −2.044% | −0.507 |
| velvetrough | 0.20501054 | 0.20694485 | 0.990653 | −0.935% | −0.746% | −0.189 |
| nosheen | 0.08724560 | 0.08954956 | 0.974272 | −2.573% | −2.062% | −0.511 |

**Raw −1.710%, adjusted −2.137%. Both are reported; the flattering one is the
raw one, and it is not the adjusted one this time.**

**Gap #17 does not explain this scene's residual — it partially masks it.** In
§7.8 and §7.10.1 Godot ran *above* Cycles and removing `ms` moved it down
towards agreement (+6.52% → +0.67%; +0.381% → −0.098%). Here Godot already runs
*below* Cycles, `ms` is still adding energy, and removing it moves the gap the
wrong way by 0.43 points. The **direction is consistent with §7.8's reading**
that `evalMultiScatterApproximation` over-corrects a real single-scatter
deficit; what is new is a base configuration — `metallic = 0`, `roughness =
0.60`, dielectric — where the deficit it is over-correcting is *larger than the
over-correction*, so the compensated result still lands 2% short. **That is a
base-BRDF finding, not a sheen finding, and it is recorded rather than closed.**

**The `ms` edit did not touch the sheen layer, and the numbers say so, not the
diff.** The sheen-only delta under `ms = 1.0` against the production build:

| arm | production delta | `ms=1` delta | ratio |
|---|---|---|---|
| velvetsharp | 0.00069477 | 0.00069507 | 1.000432 |
| velvet | 0.01551556 | 0.01552570 | 1.000654 |
| velvetrough | 0.11769747 | 0.11776494 | 1.000573 |

Three arms spanning a 169× range move by 0.04–0.07%, all in the same direction
and all an order of magnitude below the raw shift the edit produced (−0.43% to
−0.52%). The sheen layer's agreement with Cycles is **+0.324% raw / +0.389%
adjusted** on the headline arm — the conclusion does not depend on which build
it is measured in. This is the same separability §7.10.1 established for the
coat, re-established for sheen without relying on it.

**The production binary was restored and re-measured, not assumed restored.**
After `git checkout` of the three shader files and a full rebuild, the velvet
arm reads `0.10321904` against the original `0.10321895` — 8.7e-7 relative,
inside the same-binary noise floor. `git status -- servers/` is empty.

#### 7.11.3 Sheen is an LTC lobe, and `pdf == eval` is the whole design

Cycles' sheen is Zeltner's *Practical Multiple-Scattering Sheen Using Linearly
Transformed Cosines*: a cosine hemisphere pushed through a 2×2 linear transform
`[[a, 0], [b, 1]]` whose two coefficients, plus the lobe's directional albedo,
are read from a 32×32×3 precomputed table. E2e ports it as
`sheenSetup` / `sheenEval` / `sheenSample` (`brdf_inc.glsl:2453`, `:2471`,
`:2506`) against a byte-exact copy of Cycles' table
(`storage_rd/sheen_ltc_table.h`, 3072 floats, re-extracted and diffed by the
reviewer with zero mismatches).

**The LTC is a normalised density, so `pdf` and `eval` are literally the same
number**, and `sheenEval` is the only place it is computed — `sheenSample` does
not recompute it, so the two cannot drift (`brdf_inc.glsl:2469-2471`). What that
bought:

- **A sample weight of exactly 1.** `f / pdf` is 1 by construction, so the
  sheen arm of the sampler carries no ratio that could be subtly wrong.
- **A CPU-testable identity that is not a tautology.** `test_pt_sheen.cpp`
  asserts the *sampler's* pdf — computed from its own local direction as Cycles
  does (`bsdf_sheen.h:97-99`) — against the *evaluator's* value for the same
  world direction. Two independent paths, one number, `Approx(1e-5)` for the
  round trip through the frame projection, plus a falsifiability check that two
  different draws give different pdfs. The version this replaced compared
  `sheen_eval(d,l)` to a deterministic recomputation of itself and could not
  fail for any implementation; that pattern was caught in pre-flight, which is
  the third phase running to catch one.

**The invalid-LTC guard is reachable, not decorative.** `bsdf_sheen.h:44-49`
drops the closure when `|transformA| < 1e-5` or `albedo < 1e-5`. Across the
sampled domain the CPU mirror counts **104 invalid points**, and **90 of the
1024 table cells** fail it outright — all in the lowest roughness rows. That
number is why §7.11.1's arms set `sheen_roughness` explicitly and why the
reader should treat a "sheen renders nothing" report as a roughness default
before anything else.

**Table block ranges, measured** (they matter for what a bounds test can catch):
`transformA` `[0, 0.87958]`, `transformB` `[−0.18133, 0.00196]`, `albedo`
`[0, 0.74973]`. `transformA` sits entirely inside `[0,1]`, so an
albedo↔transformA offset mix-up passes a `[0,1]` bounds check undetected; only
`transformB`, which has negatives, is caught by one. The comment claiming
otherwise was corrected.

#### 7.11.4 The N-layer stack — landed before sheen existed, with no behaviour change

The single most useful structural decision in the phase. Task 2 replaced E2d's
hardcoded `tookCoatLobe` bookkeeping with a general walk,
`layerTransmittanceAbove(material, N, V, lobeIndex)` (`brdf_inc.glsl:2690`),
**and shipped it while `LOBE_COUNT` was still 3 and no sheen code existed**. The
evidence that it changed nothing is that the four then-existing GPU gates stayed
green, `pt_anisotropy_gate`'s output was **byte-identical**, and every moved
number on the other three sat inside a **same-binary** floor — the implementer
built the pre-task binary, ran all four, then ran the after binary twice, so the
drift was compared against re-running the identical build rather than against
nothing. That is the E2c lesson applied without being asked.

**Registry index order runs innermost → outermost, and it MATCHES layer order.**
The plan asserted the opposite and the implementer corrected it from the source:
Cycles allocates **sheen first** (`svm/closure.h:115`, withdrawal at `:141`) and
**coat second** (`:146`, withdrawal at `:170`), so the coat closure at `:157` is
built from an already-sheen-attenuated weight. Sheen (index 3) attenuates coat
(2), specular (0) and diffuse (1); coat (2) attenuates 0 and 1. **Both are
`lobeIndex < LAYER_INDEX`.** The "trap" the plan warned about was the plan's own
error.

It did not stop the plan from committing the same inversion for real: Task 2's
brief wrote `lobeIndex > LOBE_COAT`, which with specular 0 / diffuse 1 / coat 2
is true for **no lobe at all**, returns identity always, and silently deletes
E2d's entire coat attenuation. The implementer caught it by reading. The phase
invariant would have caught it a step later — probe B's furnace would have gone
non-flat — which is the invariant working as designed, but the reading came
first.

#### 7.11.5 The max-channel reduction, and one real divergence from Cycles

Two different quantities, easy to conflate, and the brief did conflate them:

- **The withdrawal** is `reduce_max` in Cycles (`bsdf_util.h:439-443`,
  `closure_layering_weight`), and E2e ships `reduce_max`. Correct, and the
  reviewer verified the weight really cancels, leaving
  `a/w = sheenColor * ltcAlbedo` exactly. Because `ltcAlbedo` is scalar,
  `reduce_max(sheenColor * ltcAlbedo)` is `reduce_max(sheenColor) * ltcAlbedo`,
  which is why `sheenMaxTint` (`brdf_inc.glsl:2545`) can be one number in two
  roles.
- **The lobe-selection weight** is `fabsf(average(weight))` in Cycles
  (`closure_sample_weight`, `alloc.h:55-62`), and E2e ships **max-channel**.
  **This is a genuine divergence and it is deliberate.** It is *unbiased and
  variance-only*: the four weights sum to exactly 1 and the estimator is
  `sheenColor * ltcAlbedo / sheenMass`, precisely the throughput factor applied,
  so the mean is untouched and only the sampling density moves. On a saturated
  tint the max is arguably the **lower-variance** choice, since it keeps the
  per-channel MC factor `sheenColor / max(sheenColor)` at or below 1 in every
  channel. It also keeps sheen symmetric with the coat, which uses max-channel
  for the same reason. Recorded in-code and here so a future reader does not
  "fix" it into a bias.

**Why E2d did not have to face this.** The coat's albedo is a *scalar*; sheen's
is a tinted `float3`. Every reduction question that a scalar makes vacuous
becomes live the moment the layer carries a colour.

#### 7.11.6 The transposed LUT axes, and what actually guards them

The sheen table is read `(cosNI, roughness)` — `bsdf_sheen.h:38-42` passes them
in that order — while this engine's coat energy table is read
`(rough, cosNI)` (`brdf_inc.glsl:2038`). Both go through the same
`coatLutRead2D` primitive, so **the transposition lives entirely in the argument
order at the call site** and the compiler cannot see it. `sheenLutRead2D`
(`:2408-2409`) exists to name it rather than leave it implicit, and the
reviewer separately confirmed the reader's internal row/column arithmetic
matches `lookup_table.h:31-47` (y drives the row, x the column) so the call
lands in the same slots Cycles uses.

**What guards it, in ascending order of what it can actually catch:**

1. `test_pt_sheen.cpp`'s axis-order case — guards the **mirror's reader**, not
   the call site. Task 1 Step 4 proved this by swapping the arguments inside
   `sheen_setup`'s three reads and watching **all six cases stay green**,
   including this one. The limitation was reported rather than papered over.
2. `pt_sheen_gate`'s **probe A** — compares twelve GPU-rendered points against
   an independent parse of `sheen_ltc_table.h`, to 1e-7. Catches a transposition
   at those twelve points.
3. **§7.11.1's roughness ladder** — the only guard that is cross-engine and
   covers the whole axis: three arms at sheen roughness 0.30 / 0.50 / 0.80,
   whose deltas stand in the ratio `1 : 22.332 : 169.406` against Cycles'
   `1 : 22.320 : 169.425`. A transposition changes the *shape* of the roughness
   response, which is exactly what that ladder measures.

#### 7.11.7 The `selectLobe` repair, which nothing asked for and the arithmetic demanded

Appending a fourth, always-zero weight to the lobe registry made a float-residue
window **reachable**. `selectLobe` (`brdf_inc.glsl:2751`) accumulates weights and
returns the first whose running sum exceeds `u`; the old body's trailing
fallthrough was the last index. E2c had proved that fallthrough unreachable —
but **only for the exact two-weight case**, where `fl(p) + fl(1-p) == 1.0f`
holds. With three non-zero weights plus a zero there are three roundings and the
sum need not be exactly 1, so `u` near 1 on a **coated** material falls through
to the zero-weight sheen lobe and divides by zero.

**Quantified by brute force over 3M float32 `(pSpec, coatMass)` pairs:**
`acc < 1.0f` for **2.6%**, and `acc < 0.99999994f` — the largest `u` the RNG can
return — for **0.13%**. Roughly **one coated material in 800** carried a live
divide-by-zero window. The repair skips zero weights and falls through to the
last non-zero one, and is bit-identical on every prior input.

**The CPU mirror had to follow, and the case that "covered" it could not fail.**
`test_pt_lobe_registry.cpp` states in its own header that it must stay textually
identical to the GLSL; after the repair it was the pre-repair body. The one case
pinning it built only `{w0, 1-w0, 0}`, whose sum is exactly `1.0f`, so it could
not distinguish either body. The failure scenario is specific: a contributor
obeys the header, ports the mirror *back* into the shader, and reintroduces the
divide-by-zero with nothing going red. Fix round 1 resynced the mirror and
**proved the new cases can fail** — with the pre-repair body restored they go
red at 1412 zero-weight selections, while the old "never returns a zero-weight
lobe" case stays green, demonstrating empirically that it was never an
instrument for this.

**Two arithmetic corrections worth keeping.** The reviewer's named residue pair
`(0.3118, 0.2078)` does **not** reproduce — in float32 those weights sum to
exactly `1.0f`. The window sits at *small* `pSpec`. The implementer swept for a
real one that runs through the production `lobe_weight`:
`lobe_weight(0.04, 0.5) = 0.0740740672f` with `coatMass = 0.0397f` sums to
`0.999999881f`, a 5.96e-08 gap below the largest `u`. Separately, `acc` collapses
to just three float32 values across the sweep — `1.0`, `1.0 − 1 ULP` and
`1.0 − 2 ULP` — and since the test is `u < acc`, the `u == acc` boundary *also*
falls through; so the strict `residue_pairs` counter measures a subset of what
the `zero_weight_selections == 0` assertion covers, making it conservative
rather than vacuous. A third party reimplemented both bodies and the sweep in
numpy float32 and reproduced 1412 and 169 exactly.

**The residue analysis above is per-shape, not general.** The 2.6%/0.13%
figures, the `lobe_weight(0.04, 0.5)`/`coatMass = 0.0397f` case, and the
`{1.0, 1.0 - 1ULP, 1.0 - 2ULP}` collapse are all properties of the specific
four-weight (three-non-zero-plus-one-zero) distribution E2e produced. Nothing
in the suite parameterises the sweep over `LOBE_COUNT`:
`test_pt_lobe_registry.cpp` pins `LOBE_COUNT` at exactly 2 (`:51`) for the
baseline cases and calls `select_lobe` with the literal arguments `3` (`:299`)
and `4` (`:374`, `:418`) for the three- and four-lobe cases — each shape is its
own hard-coded test, not a swept parameter. The repair itself (skip zero
weights, fall through to the last non-zero one) is general, but the *evidence*
that it is safe is not: it is a brute-force sweep over the four-lobe case's
specific weight distribution. **A fifth-lobe phase must redo the sweep against
its own weight distribution rather than assume this one's numbers, or even its
qualitative shape, carries over.**

#### 7.11.8 The gate, proven by breaking it

`pipeline_references/tests/pt_sheen_gate.gd` — the phase's sixth GPU gate and,
in the reviewer's words, the strongest instrument in it. Every a-priori
reference was reproduced from an **independent parse** of `sheen_ltc_table.h`
rather than accepted from the report.

**Break-the-guard.** Deleting sheen's entry from `layerTransmittanceAbove` turns
**10 assertions red across probes C1/C2/C3**, with the furnace reading
**`1.413032`** against control **`0.999919`** and lever **`0.413156`** — i.e.
exactly `1 + ltcAlbedo`, the signature of a layer that reflects without
withdrawing. Probes A/B/D/E correctly stay green (black base or pdf-only, so
layering never enters), which is what distinguishes a targeted instrument from
one that fails at everything. Restored and re-confirmed.

**Probe E2, and why probe E1 alone could not be an orientation instrument.**
E1 integrates the sheen density over a **constant environment**. For any
rotation of `(T, B)` about `N` by θ, `f(L; T', B') = f(R_θ⁻¹L; T, B)`, and
rotation preserves the sphere's measure — so **the integral is identical for any
orthonormal frame about `N`, at every value of `transformB`, not merely near
zero**. Rotating the frame only reparametrises the domain. E1's failure text
named a mechanism the same sentence proves cannot occur; it now says plainly
that it guards finiteness and orthonormality and is **blind to orientation**.
Both the original finding and the proposed remedy (retilt E1 to a point of large
`|transformB|`) were wrong for the same reason, and the implementer refuted both.

Orientation is observable only where the density is evaluated at a **single
direction**, which needs a delta light. Probe **E2** is that: two delta
directional lights 45° from `N`, one in the T–N plane and one in the B–N plane,
at `cosNI ≈ 0.21` / roughness 0.80 where `transformB = −0.094278`. The assertion
is the **ratio** of the two responses against a per-pixel CPU mirror, so all
light plumbing cancels, and the sky pedestal is *subtracted* rather than assumed.
Predicted `1.199338`, measured `1.199354` — 1.3e-5 relative; lever `0.1993`;
pedestal `m0 = 0.567556` independently reproducing probe B's `0.567553`.

**It fails when it should.** Swapping `rT`/`rB` drove E2 to `0.833806` against
the a-priori swap prediction `0.833759`, **while E1 read `1.0000` and passed**.
The swap is algebraically a 90° rotation about `N`, so E1 *must* stay at 1.0000
and E2's ratio *must* become its own reciprocal, `1/1.199338 = 0.833793`. The
falsification reconciles from the code rather than by coincidence.

#### 7.11.9 Three findings that outlive this phase

**1. NO DEBUG VIS MODE IN THIS ENGINE CAN REPORT A NEGATIVE NUMBER.**
`sanitize_payload_value` clamps radiance to `[0, 1e6]`
(`raytracing_inc.glsl:88-91`) and `path_unpack` re-applies `max(…, 0)` at `:109`;
`debug_visualize` ends at `path_pack`, so **every vis mode goes through both**.
Task 3's vis mode 41 read `transformB` as exactly `0.000000` against a mirror
value of `−0.094282` — and `transformB` is negative in **909 of 1024 cells**
(32 positive, 83 zero), so **that instrument was inert over 89% of its domain**
from the day it shipped. Fixed for mode 41 by sign-encoding that one channel
(`0.5 + 0.5*b`).

**A second live instance, not fixed here, recorded deliberately:** **vis mode
25** (`raytracing_closest_hit_common_inc.glsl:520`) emits
`dbg_material.anisotropy` **raw** in blue, and `BaseMaterial3D::anisotropy` has
range `−1,1` (`scene/resources/material.cpp:3848`). `pt_material_data_gate` is
not holed **today** only because its test value happens to be positive
(`V_ANISOTROPY = 0.83`) — the instrument is **latently blind**, and a negative
anisotropy would read as zero and pass. The normal-carrying modes already
sign-encode (`:356-367`, `:412`), so the convention existed and two modes missed
it. **Any past or future vis mode carrying a signed quantity has this defect;
prior phases' instruments should be audited against it.**

**2. A pre-existing E2d coat defect: 0.705pp of energy lost at grazing
incidence.** Found by E2e's gate, at `cos ≈ 0.21` with `clearcoat = 1.0`, and
scaling with clearcoat (0.359 at `clearcoat = 0.5`) — the coat's own signature.
**`pt_coat_gate` structurally cannot see it**: its sphere crop never leaves
`cos ≥ 0.79`. **Confirmed not sheen's**, line by line: at `sheen_color == 0`
`sheenLayerAlbedo` returns literal `0.0f` *above* the LUT read,
`sheenLayeringTransmittance` is exactly `float3(1)`, `sheenLobeWeight` is 0 so
`selectLobe` cannot reach it, and `hasSheen` is false so `evalSheen` is never
called. **Open against E2d, not against E2e.**

**3. `sheenMakeFrame`'s `make_orthonormals` fallback is unreachable from any
render.** The raygen is **pinhole-only** — `camera_ray`
(`scene_raytracing_raygen.glsl:107-120`) sets the origin unconditionally with no
orthographic branch — and it jitters every primary ray, so `cross(N, V)` is
never exactly zero. It has a **CPU test only** (`test_pt_sheen.cpp`'s degenerate
case, against Cycles' exact `(1,1,1)×N` / `(−1,1,1)×N` construction from
`math_float3.h:741-750`), and no GPU probe can be built for it.

**The bigger finding is the premise:** `PROJECTION_ORTHOGONAL` **is not honoured
by the path tracer at all.** An orthographic `Camera3D` renders as a pinhole
one. That is a defect in its own right, unrelated to sheen, and it is what makes
the fallback unreachable — so fixing the camera would make this code path live
and the CPU test load-bearing.

#### 7.11.10 What E2e does not deliver

- **Below-hemisphere recovery is applied to sheen, where Cycles hard-rejects
  the sample instead.** `bsdf_sheen_sample` sets `*eval = zero, *pdf = 0`
  (`bsdf_sheen.h:96-101`) when the sampled direction misses — the sample is
  meant to be dead. This engine's `recoverBelowHemisphereSample`
  (`brdf_inc.glsl:1666`) is lobe-agnostic: for ANY rejected sample it mirrors
  the direction across the geometry plane and reuses the ORIGINAL BRDF
  weight, with MIS weight 1 because no density exists for a mirrored
  direction. For sheen that means the rejected sample keeps its full closure
  weight, `sheenColor * ltcAlbedo`. Sheen makes this a worse instance of the
  general below-hemisphere-recovery family than the lobes the guard was
  designed around (the family itself is F1's, `recoverBelowHemisphereSample`
  is deliberately kept for the energy-vs-black-pixel trade-off it documents at
  its own definition): the Zeltner LTC is grazing-concentrated — the CPU
  mirror gives albedo `0.021623 -> 0.380802` between roughness 0.30 and 0.80
  at `cosNI 0.5`, an 18x swing — and its sampling frame (`sheenMakeFrame`) is
  view-dependent, so on tessellated geometry it fires more often for sheen
  than for a cosine or GGX lobe. **Nothing in the suite can see it**: vis mode
  33's `RT_DEBUG_GUARD_FIRING_RATE` instruments the TRANSMISSIVE
  hemisphere-consistency guard inside `sampleTransmissiveLobe`
  (`raytracing_closest_hit_common_inc.glsl:1945-1960`), a different guard
  entirely; and `pt_sheen_gate`'s probe B crop stays away from the silhouette
  where this would fire. Open, unmeasured.
- **`coat_normal`** — still deferred, and now touching **both** layers. Cycles
  couples the sheen normal to it: `bsdf->N = safe_normalize(mix(N, coat_normal,
  coat_weight))` (`svm/closure.h:127-129`). This engine has **no coat-normal
  input at all**: there is no `coat_normal` / `clearcoat_normal` field anywhere
  in `scene/resources/material.{h,cpp}` or `RT_MaterialData`
  (`render_raytracing.h`), and the glTF importer explicitly drops it on import
  — `modules/gltf/gltf_document.cpp:3293` calls
  `note_dropped_texture(ext, "clearcoatNormalTexture")`, which surfaces as an
  import-time diagnostic (`:3335-3339`) rather than silently discarding the
  texture. So a car-paint-plus-sheen material authored with a coat-normal
  texture in glTF is diagnosed and dropped at import, not carried through and
  silently ignored at render time. §7.11.1's arms deliberately held
  `coat_weight = 0` so the comparison would not depend on this gap.
- **The denoiser AOVs know about neither layer**, and are now one entry worse
  than §7.10.7 recorded: `RB_TEX_DLSS_RR_*` diffuse/specular albedo and
  normal/roughness are computed from the base material with no coat *or* sheen
  term, so DLSS-RR is guided by a G-buffer that does not describe what was
  rendered.
- **Any coat NEE path the fourth out-parameter touched but no scene exercised.**
  The layer walk is general over `LOBE_COUNT`; the gates drive sheen-over-base
  and sheen-over-coat-over-base, but no gate scene combines sheen with a
  transmissive or emissive base.
- **The frame's degenerate fallback is untested on GPU**, per §7.11.9 item 3.
- **`sheen_color` is uploaded unclamped above 1** (`render_raytracing.cpp:1824-1829`)
  while the sibling `attenuation_color` clamps to `[0,1]` (`:1806-1809`). The
  corrected reason this is not the same bug: Cycles is *also* unbounded here
  (`svm/closure.h:116,120`), so the upload is faithful to the reference — but
  the failure modes are not symmetric with `attenuation_color`, where a
  component above 1 flips `sigma_a` negative and `exp(-sigma_a * d)` grows
  without bound. Sheen has no such runaway: the withdrawal
  (`sheenLayeringTransmittance`) saturates to 0 while the payout
  (`sheenColor * ltcAlbedo`) grows linearly with `sheenColor`, and **this
  engine's `[0.01, 0.99]` selection-weight clamp (`sheenLobeWeight`) is what
  makes the `sheen_color > 1` regime noisier than Cycles'**, whose
  `fabsf(average(weight))` selection weight (`alloc.h:62`) is self-normalising
  with no cap. Verified: at `sheenColor = 5, ltcAlbedo = 0.4` (a uniform tint,
  sheen the only active lobe) the selection weight clamps at its 0.99 ceiling
  while the sample weight is `5 * 0.4 = 2.0`, so the per-bounce multiplier is
  `2.0 / 0.99 = 2.02`. Bounded by `max_bounces`, unbiased in expectation, and
  reachable only by authoring `sheen_color > 1` from GDScript (Godot's `Color`
  is unbounded; Blender's socket is not). Parked minor.

**The standing structural limit, unchanged since §7.9 and §7.10 and restated
because it now covers more code.** The GLSL has **no automated execution**.
doctest cannot run it; the CPU mirrors guard only the CPU side. Worse for
honesty: `pt_sheen_gate`'s `_sheen_frame` / `_sheen_eval` are **verbatim
transcriptions of the production shader**, not an independently-sourced
reference the way probe A's LUT parser is. They test that the GPU faithfully
executes the agreed formula — which the fault injection demonstrates they do —
but they **do not validate the formula's physics against Cycles**. §7.11.1's
velvet comparison is the only measurement in the phase that does, and it does so
at three points on one axis. A reviewer should read the two implementations side
by side rather than trust the gate.

Parked minors carried forward: the `test_pt_sheen.cpp` "diagonal" sub-check is
still a tautology (two identical literal arguments compared for equality) and
the commit that renamed it **claims in its message that it was deleted**, which
is false and now outlives the code; `sheen_ltc_table.h`'s include sits out of
alphabetical order at `render_raytracing.cpp:39`; probes C2/C3 have no lever
floor; C2/C3 run at roughness 0.80 rather than the briefed `{0.05, 0.5, 0.9}`;
and `sheenSetup` is walked 2–4× per hit plus 2× per NEE light and discards
`a`/`b` in four of six.

Fixed in the merge fix wave: `PROBE_B_MIN_ABSOLUTE = 0.05` mis-diagnosed the
"closure weight applied twice" bug (reads 0.0359 at tint 0.25) as "sheen
renders nothing" — the floor is now `0.1 * expected`, verified against the
arm's own three numbers (`pipeline_references/tests/pt_sheen_gate.gd`); the
five debug `MaterialProperties` sites' comment on the `[0,1]` roughness clamp
no longer contradicts production's — both now state the settled math,
`clamp(x, 1e-3, 1) == clamp(clamp(x, 0, 1), 1e-3, 1)` for every finite `x`,
which is why the debug sites' omission of the `[0,1]` step is provably
harmless (`raytracing_closest_hit_common_inc.glsl`); and the local-frame
sampling comment's justification — `transformB` is not 0 at `cosNI == 1`
except in the four lowest roughness rows, reaching ±0.00394 — is corrected to
cite §7.11.9 item 3 (the raygen is pinhole-only, so the fallback this comment
guards is unreachable regardless) instead of the false claim that the lobe is
rotationally symmetric there.

#### 7.11.11 Verification

doctest **1550 passed / 0 failed / 3 skipped** (2,067,991 assertions), on the
restored production binary after the `ms` diagnostic was reverted and rebuilt.
**All six GPU gates PASS on that same binary**: `pt_sheen_gate`, `pt_coat_gate`,
`pt_energy_gate`, `pt_anisotropy_gate`, `pt_transmission_gate` (44 checks; probe
6 on the good mode of the bimodality §7.9 records), `pt_material_data_gate` (25
fields). `git status -- servers/` is empty; the only files this closeout adds
are the roadmap text and the committed velvet harness.

**Phase table.** Under §4's "E2. Anisotropy, clearcoat, sheen": anisotropic GGX
is complete (§7.8), the two-way→N-way lobe rewrite is complete (§7.9), clearcoat
is complete (§7.10), and **sheen is now complete (E2e, this section)**.

**E2's original acceptance line — "brushed metal, car paint, and velvet respond
comparably to Cycles" — is now fully addressed, all three targets measured
against Blender 4.5.3/Cycles:** brushed metal +6.52% raw / +0.67% adjusted
(§7.8), car paint +0.381% raw / −0.098% adjusted with the coat layer isolated to
0.066% (§7.10.1), velvet −1.710% raw / −2.137% adjusted with the sheen layer
isolated to **+0.324%** (§7.11.1). All three clear the 5% bar raw.

Two qualifiers a reader must carry away with that:

- **`coat_normal` remains outstanding, and it is no longer only car paint's
  problem** — Cycles couples it to the sheen normal (`svm/closure.h:127-129`),
  so it is now geometrically incomplete for *both* velvet and car paint.
- **Velvet's raw residual is the dielectric base, not the sheen layer**, and the
  Gap #17 adjustment makes it *worse* rather than better (§7.11.2). "Velvet
  responds comparably" is true of the sheen lobe to 0.33%; the −2% sits under it
  in a `metallic = 0 / roughness = 0.60` base configuration no prior phase had
  measured against Cycles.

What remains under the E2 heading:

- **`coat_normal`** — deferred again, now blocking full geometric parity for
  both the coat and the sheen.
- **Anisotropy on the transmissive lobe** — still needs the refracted-direction
  eval/pdf machinery described at the end of §7.8.
- **The dielectric base's −2% deficit** (§7.11.2) — new, opened by this
  measurement, and orthogonal to every layer E2 added.
- **The coat's 0.705pp grazing-incidence loss** (§7.11.9 item 2) — open against
  E2d, invisible to `pt_coat_gate` by construction.

### 7.12 E2 render-time regression — measured, and mostly NOT where it looked

Reported symptom: production job `urbantestdark168` (HEAD `3baa902b4`) took
1050.8s against `urbantestdark167`'s 762.6s (`28bb89cad`) on what the operator
correctly identified as a visually indistinguishable render.

**The comparison is clean.** The two Godot logs are identical except three
lines — engine version and the input/output paths. Same 144 assets (141 unique
names, zero difference either way), same `[PT] spp=6, max_bounces=12`, same
128-frame DLSS-RR drive. The uncommitted `USE_TRANSMISSIVE_GLASS` bounce change
in `image_glb_creation.gd` was already present in *both* runs. Run 166, which
looks like same-scene variance at 437s, is a different view (906 differing log
lines, different plan pivot) and is not evidence about variance.

#### What was measured

Five renders of the same input JSON, same machine, `tests=yes` on every arm
except P0. Startup is separated from the 128-frame loop by timestamping the
`Driving 128 frames` log line.

| Arm | Engine | startup | **loop** | total |
|---|---|---|---|---|
| BASE | `28bb89cad` worktree build | 79s | **639s** | 718s |
| E2B | `fcc482b0a2` (E2b end) worktree build | 85s | **747s** | 832s |
| P2 | HEAD, coat+sheen **and** registry arrays out | 82s | **826s** | 908s |
| P1 | HEAD, coat+sheen compiled out | 83s | **825s** | 908s |
| P0c | HEAD, control | 78s | **912s** | 990s |
| P0 | HEAD, no `tests=yes`, warm cache | — | — | 993s |

**Startup is 79s vs 78s — the regression is entirely in the render loop:
639s → 912s, +273s, +42.7%.**

#### Attribution

| Component | Cost | How established |
|---|---|---|
| E2b anisotropic GGX | **108s (40%)** | E2B − BASE, both worktree builds |
| E2d/E2e residual infrastructure | **78s (29%)** | P1 − E2B |
| Coat + sheen lobes | **87s (32%)** | P0c − P1, clean same-flags pair |
| E2c registry arrays | **0s** | P2 − P1 = 1s, inside noise |

108 + 78 + 0 + 87 = 273s. The decomposition closes on the measured total; no
term is a residual.

**E2b's 108s is not its arithmetic.** Every material in this scene has
`anisotropy == 0`, so `anisoActive` is already false at runtime and the
anisotropic branches never execute. A variant forcing `anisoActive = false`
would therefore have recovered 0s *by construction* — an experiment that cannot
fail, and it was not run for that reason. What is left to charge the 108s to is
the widened `BrdfData` (ax, ay, anisoPhi, anisoActive) threaded through every
sampling and pdf signature, i.e. register pressure and the occupancy that
follows.

The 78s bucket is what P1's `#if` guards did *not* remove: the coat/sheen SSBO
bindings, the widened material struct, and the `coatMass`/`sheenMass` setup that
still runs before the guarded lobes.

#### Three hypotheses that were wrong

Recorded because each looked convincing before it was tested:

1. **Cold driver shader cache.** Run 168 ran 8 minutes after a fresh build and
   the NVIDIA GLCache took a 559 MB write two minutes into it. Refuted: P0
   re-ran that binary warm and still took 993s. Worth at most ~58s, and P1
   later ran cold with a *faster* startup than P0, so even that is variance.
2. **The coat and sheen lobes dominate.** They are a third of it. A
   specialization constant on layer presence — the fix this diagnosis first
   pointed at — would have recovered 87s of 273s.
3. **The registry's dynamically-indexed local arrays force scratch memory.**
   Exactly zero. P2 is pixel-identical to P1 (rmse 0.000000), so the scalar
   rewrite is equivalent, and it bought one second.

#### The shape of the result

The cost is **diffuse**: 108s / 87s / 78s across three separate mechanisms, with
no dominant term, and 0s from the one structure (the registry) that looked most
suspicious. Two of the three buckets — E2b's 108s and the 78s of scaffolding —
are paid by a scene that uses none of the features they belong to, which is the
signature of register pressure rather than executed work.

Consequence for any fix: **targeting one feature underdelivers.** Compiling out
coat and sheen bought 87s of 273s. Getting back to 639s means gating all three
groups — anisotropy, coat, sheen — on what the scene actually contains.

#### What the time bought, on this scene

> **SUPERSEDED by §7.13 — the second paragraph of this subsection is wrong.**
> The conclusion "the coat and sheen paths are reached" was inferred from a
> pixel delta that is **entirely inside this render's own noise floor**. Two
> runs of the *same binary* differ at rmse 0.1406 / 5.58% of pixels. The 6.03%
> / rmse 0.1464 below is that floor, not an effect. E3's detector settles the
> question directly: this scene reports `aniso=0 coat=0 sheen=0` — it uses
> **none** of the three features. The timing numbers in this section are
> unaffected; only the pixel-difference inference is retracted.

BASE vs HEAD: **6.03% of pixels differ**, rmse 0.1464, max 31/255, means equal
to four decimals. The operator's "no visible difference" is accurate. ~~The coat
and sheen paths are reached — via glTF-imported materials, not the scene
scripts, whose `ReflectionAssist` and `Photorealism` passes never fire in this
job — but at an amplitude no viewer would call worth +42.7%.~~ (Retracted; see
the note above.)

#### Open

- **No fix is implemented.** The full 273s is attributed; the recoverable
  target is all of it, via feature gating. The specialization-constant
  mechanism already exists
  (`RT_FLAGS`, `raytracing_common_inc.glsl:12`, used this way at
  `scene_shader_raytracing.cpp:680` to compile out the NEE block).
- **`anisoActive` gates E2b's math at all six hot sites** (`brdf_inc.glsl:1232`,
  `:1269`, `:1374`, `:1421`, `:2913`, `:3198`), and `prepareBRDFData:1725-1748`
  only sets it when `anisotropy != 0`. If the 186s is E2b, the cost is
  therefore *not* the gated arithmetic — it is the widened `BrdfData` and the
  occupancy that follows, which is a different fix.
- `pipeline_references/` was never modified by this investigation; renders were
  driven directly against the stage-copy project with outputs to scratch.

### 7.13 E3 — per-scene feature gating, and the recovery it measured

E3 is the fix §7.12 asked for and did not implement: compile anisotropy, coat
and sheen out of the raygen pipeline when the scene does not contain them.

**Headline: on a scene that uses none of the three gated features, the render
loop went 912s → 643s against a 639s pre-regression baseline (`28bb89cad`) —
269 of the 273s regression recovered, 98.5%.** Totals 724s vs 990s. Same
production scene, same machine, same 128-frame DLSS-RR drive; image mean
159.3341, matching the reference exactly.

**Re-measured after the final-review fix wave (`6d5ec7a489`), which added the
accumulation reset on a variant change: loop 639s, total 720s — landing exactly
on the pre-regression baseline, i.e. the full 273s.** The 643s above and this
639s differ by less than the run-to-run noise on timing; both are reported
rather than picking the better one. Mask still `aniso=0 coat=0 sheen=0`, zero
shader/pipeline errors, image mean 159.3341.

**That condition is the result, not a footnote on it.** E3 removes cost a scene
does not use; it removes nothing from a scene that does. 98.5% is this
mechanism's *ceiling*, reached at the all-features-absent end of the range, and
the floor at the other end is 0% — a scene using all three compiles the same
pipeline HEAD did and pays the full 273s. The production scene sits at the
ceiling only because it reports `aniso=0 coat=0 sheen=0`.

**Only those two endpoints are measured.** Nothing in between has been: no
render was timed on a scene using exactly one or two of the features. §7.12's
per-component attribution (anisotropy 108s, coat+sheen 87s, 78s of shared
scaffolding) makes it plausible that a one-feature scene recovers roughly the
other two's share, but that is an inference from a different experiment on a
different set of builds — it is not a measurement of E3, and it should not be
quoted as one. Do not carry "98.5%" into any context that does not carry the
feature condition with it.

#### The mechanism

Three flag bits — `RT_FLAG_ANISOTROPY_ENABLED` (1<<15),
`RT_FLAG_COAT_ENABLED` (1<<16), `RT_FLAG_SHEEN_ENABLED` (1<<17),
`scene_shader_raytracing.h:96-98` — are appended to `RAYGEN_SHADER_OPTIONS`
(`scene_shader_raytracing.cpp:70-72`), where each set bit injects a `#define`
into the raygen preamble: `RT_ANISOTROPY_ENABLED`, `RT_COAT_ENABLED`,
`RT_SHEEN_ENABLED`. Under those `#ifdef`s the anisotropy state (`ax`, `ay`,
`anisoPhi`, `anisoActive`) leaves `BrdfData` and every sampling/pdf signature
that threaded it, and `LOBE_COUNT` collapses 4 → 3 → 2 with `LOBE_SHEEN`
sliding 3 → 2 when coat is absent (`brdf_inc.glsl:1872-1883`). That is the
occupancy fix §7.12's attribution pointed at, not a gate on arithmetic that
was already runtime-disabled.

Detection is per material — `RTMaterialData::feature_bits`, set in
`process_material()` (`render_raytracing.cpp:1885-1898`) from the same
predicates the shader guards use. `build_tlas` runs a **two-pass** structure:
pass 1a registers procedural hit-group shaders, pass 1b walks every material
and ORs the mask, and only then does `final_flags = p_rt_flags | scene_mask`
settle — before any pipeline build, SBT write, or instance record. Nothing
downstream reads `p_rt_flags` again. The ordering is load-bearing: the detect
walk must see procedural materials, which is why 1a exists at all.

#### Acceptance — the feature-PRESENT path

The all-off path was measured first, and it is the production scene: the
detector reports `aniso=0 coat=0 sheen=0` there, and that variant's first real
GLSL compile produced **zero shader or pipeline errors**. What that cannot
prove is the opposite case — that a scene which *does* use a feature still
gets it, and still renders it correctly. E2b/E2d/E2e already left the right
instrument for that: three gate scenes in `pipeline_references/tests/`, each
driving its feature far above the noise floor and carrying its own assertions
and baselines.

| Gate | `[E3] scene feature mask` | Result | Exit |
|---|---|---|---|
| `pt_anisotropy_gate_scene.tscn` | `aniso=1 coat=0 sheen=0` | **PASS** — anisotropic GGX gate green | 0 |
| `pt_coat_gate_scene.tscn` | `aniso=0 coat=1 sheen=0` | **PASS** — coat gate green | 0 |
| `pt_sheen_gate_scene.tscn` | `aniso=0 coat=0 sheen=1` | **PASS** — sheen gate green | 0 |

Every probe held to its pre-E3 baseline. Anisotropy: probe 1 white furnace
max|R−G| = 9.5e-7, probe 2 self-normalisation E[1/G] = 6.284324, ratio vs 2π =
1.000181 over n=53361. Coat: probe E's directional reflectance tracked analytic
Fresnel to ratio 0.9995–1.0073 across five cosines × three IORs, probe D's
three-lobe pdf self-normalised to 1.0010–1.0013 at clearcoat 0/0.5/1.0, probe G
found `clearcoat_ior == 1.0` inert at rmse 0.000793 against a 0.000862 floor.
Sheen: probe B measured 0.567553 against the predicted `tint*ltcAlbedo`
0.567582 (ratio 0.9999), probe D's four-lobe pdf gave E[1/G] = 6.278383 (ratio
0.999236), and probe E2's frame-orientation ratio came in at 1.199353 against a
CPU-mirror prediction of 1.199338 — a quantity that reads 0.8338 with rT/rB
swapped. The only error in any of the three logs is `res://icon.svg` missing at
startup, which is pre-existing and unrelated.

**Five distinct pipeline variants compiled and ran clean across these four
renders**, because the gates flip materials mid-run and the detector follows:
`000` (production and every gate's control arm), `100`, `010`, `001` and `011`.
That exercises `LOBE_COUNT` at 2, 3 and 4, and `LOBE_SHEEN` at both 2 (sheen
without coat — the slide) and 3.

**Four of those five had never been compiled before these three runs.** The
production scene selects `000` and only `000`, so every hour of building and
every production render up to this point had exercised exactly one variant of
the five E3 creates. The gate scenes are what covered the other four, and
given the `glsl_builders.py` finding below they are the only thing that could
have.

Detection is falsifiable, and was shown so twice. During implementation,
temporarily forcing `mat.clearcoat`, `mat.sheen_color[0]` and `mat.anisotropy`
nonzero made the detector print `aniso=1 coat=1 sheen=1` on the production
scene; the probe was reverted. The gate scenes are the natural second
demonstration — each turns on exactly its own bit and no other.

#### The correction to §7.12

§7.12 concluded, from a 6.03% pixel delta between BASE and HEAD, that "the coat
and sheen paths are reached" on the production scene. **That inference is
withdrawn.** The scene reports `aniso=0 coat=0 sheen=0`; it uses none of the
three. The 6.03% was noise — see below. §7.12's *timing* numbers and its
attribution table are unaffected, and E3's 98.5% recovery is in fact the
strongest confirmation of that attribution: the 273s really was diffuse
register-pressure cost paid by a scene that executes none of the features.

#### Open: the render is nondeterministic

**Two runs of the same binary on the same scene differ at rmse 0.1406, with
5.58% of pixels differing.** This was discovered while trying to pixel-diff
E3, and it invalidates that whole class of measurement on this scene: removing
coat and sheen *entirely* produced rmse 0.1455. The effect and the floor are
the same size.

Characterised: **uniform low-amplitude dither.** 4–8% of pixels differ in
*every* cell of a 6×8 grid — no spatial locality, no hot region. Mean magnitude
1.04/255. Mean luminance where pixels differ is 160.4 against 159.3 where they
agree, i.e. the differing pixels are not systematically brighter or darker.

Two candidate causes were **refuted by measurement**, not by argument:

1. **The free-running `frame_counter` RNG seed.** Instrumented directly; the
   sequence is identical across runs.
2. **Float atomics in the RT GLSL.** There are none.

Remaining candidates, untested: DLSS-RR's own execution, and the async
pipeline-build race that drops instances via `is_hg_ready_in_bundle`. The
second is the more troubling of the two, because it would mean frames
occasionally render with a different instance set.

Until this is closed, **any acceptance argument on this scene that rests on
pixel equality is invalid.** Use the gate scenes, which assert on converged
statistics with declared tolerances, or use image mean.

#### Open: `scons` exit 0 says almost nothing about shaders

`glsl_builders.py` performs **no GLSL validation whatsoever** — it embeds the
shader text into a `.gen.h` and nothing more. A syntactically broken or
semantically invalid `#ifdef` branch builds cleanly and fails at pipeline
creation, at runtime, in whichever variant happens to select it. This is
exactly the trap E3's `#ifdef` restructuring could have fallen into: the
production scene only ever compiles the `000` variant, so four of the five
variants above were unexercised by any amount of building or production
rendering. **Running a scene that selects the variant is the only evidence.**

#### Housekeeping

The `[E3] scene feature mask` line fires once per `build_tlas` — ~128 times per
capture. It is now behind `OS::get_singleton()->is_stdout_verbose()` rather
than deleted, since it is the only external read of what the detect pass
concluded and is how the acceptance above was measured. Re-arm it with
`--verbose`.

## 8. Transparent shadows closeout — glass no longer blocks direct light

**Complete.** Shadow rays now attenuate through transmissive surfaces instead
of stopping at them. Before this work, a light source occluded by any glass
pane — a fish tank, a vitrine, a window — received zero direct light behind
it, full stop, regardless of the glass's `transmission`/`alpha` authoring;
`:1412` above used to (wrongly) call that behaviour a match for Cycles. It
never was, for the alpha-authored `alphaMode: BLEND` GLBs this engine
actually renders (base-colour alpha 0.098) — Cycles' own transparent-shadow
path (`shade_shadow.h:183`, gated on `SR_TRANSPARENT` via
`surface_shader_transparency`, `surface_shader.h:1053`) passes ~90% of the
light through exactly that closure. This phase closes that gap for direct
lighting only; it does not touch caustics, which stay out of scope (§6.2), and
it does not touch indirect/multi-bounce light, which is unaffected by shadow
rays entirely.

### 8.1 The defect and its code anchors

The shadow-ray function is `lights_trace_shadow_ray()`,
`servers/rendering/renderer_rd/shaders/raytracing/raytracing_lights_inc.glsl:289-478`.
Before this work it was a single opaque-occlusion trace: any hit, transmissive
or not, returned `vec3(0.0)`. Transmissive instances are identified by a
per-material flag bit set from `mat.transmission > 0.0f`
(`RT_FLAG_TRANSMISSIVE_GEOMETRY = 1 << 18`,
`scene_shader_raytracing.h:106`), OR'd into a per-scene mask the same way E3's
feature bits are, and turned into a per-instance TLAS cull mask
(`rt_instance_mask_from_features`, `render_raytracing.cpp:2461`) split across
two disjoint bits: `RT_INSTANCE_MASK_OPAQUE = 0x01`,
`RT_INSTANCE_MASK_TRANSMISSIVE = 0x02`, `RT_INSTANCE_MASK_ALL = 0xFF`
(`scene_shader_raytracing.h:138-141`).

### 8.2 The two-pass design, and why pass B is a re-trace loop, not any-hit accumulation

**Pass A** (`raytracing_lights_inc.glsl:289-331`) is byte-for-byte the old hot
path, narrowed to `RT_INSTANCE_MASK_OPAQUE`: `TerminateOnFirstHit` +
`SkipClosestHitShader`, answering the binary occlusion question against
opaque geometry only. **Pass B** (`:333-478`) runs only if A found no opaque
occluder, and only when the scene actually contains transmissive geometry —
`RT_GET_TRANSMISSIVE_GEOMETRY()` is a specialization constant, so the whole
block folds away in a glassless scene, which is what makes Step 3's
no-regression claim structural rather than measured-and-hoped. It walks an
inline `rayQueryEXT` forward from the origin, at each iteration finding the
nearest transmissive hit in `[t_min, t_max]`, multiplying an accumulator by
`transmission * (1 - F)` for that crossing, advancing `t_min` past it, and
repeating up to `RT_GET_MAX_TRANSMISSION_BOUNCE()` (default 12) times or until
the accumulator underflows an epsilon and the ray is called fully occluded.

The two halves are one unit, not two independent features: narrowing pass A's
mask without pass B culls glass out of the shadow test entirely (every pane
casts no shadow at all — this was measured and caught mid-implementation, see
§8.6); pass B without the narrowing double-counts every pane, since pass A
would already occlude on the same hit pass B is attenuating through.

**Why pass B is a re-trace loop and not any-hit accumulation on the primary
ray.** The cheaper-looking design is to give transmissive instances an
any-hit shader and let a single trace accumulate attenuation as it goes. That
requires clearing `FORCE_OPAQUE` on transmissive instances
(`render_raytracing.cpp:2991`) — and that bit is not scoped to shadow rays. It
is a per-instance property shared by every ray that can hit that instance:
primary rays and indirect bounce rays as well as shadow rays. Clearing it to
fix the shadow path would force every primary and indirect ray in the scene
to start invoking any-hit on all glass, paying a cost proportional to total
ray traffic to fix a cost that is actually proportional to shadow-ray traffic
against transmissive geometry specifically. The re-trace loop keeps the fix
scoped to the rays that need it, at the cost described in §8.5.3.

### 8.3 Gate results, default config (`pipeline_references/tests/pt_transparent_shadow_gate.gd`)

All four probes PASS, each matching closed-form Fresnel theory to at least
five significant figures:

| Probe | Configuration | Measured | Theory | Band |
|---|---|---|---|---|
| 1 | One pane, normal incidence | 0.921600 | 0.921600 (= 0.96², ior 1.5, F0 = 0.04) | admits ceiling 1.0 |
| 2 | One pane, 80° incidence | 0.374911 | 0.374905 | [0.365, 0.385] |
| 3 | Two panes / four crossings | 0.849346 | 0.849346 (= 0.96⁴) | crossing-count probe |
| 4 | One pane, `transmission = 0.5` | 0.230400 | 0.230400 (= (0.5·0.96)²) | closes the untested-factor hole |

Probe 3 is the evidence the re-trace ordering is right, not just the
per-crossing arithmetic: one pane and two panes are indistinguishable to
probe 1 alone (0.9216 and 0.96 both sit inside a loose band), so without
probe 3 a shader that silently skipped a crossing could still read green.
Probe 4 closes a hole found during review: with `mat.transmission` held at
1.0 in probes 1-3, deleting that factor from the accumulation entirely still
passed all three to the last digit — probe 4 varies it and would catch that
regression.

**Falsification, run against this same gate:** removing the `(1.0 - F)` term
from the accumulation made probes 1, 2 and 3 all read exactly `1.000000`, and
all three FAILED. The fix was restored byte-exact and the gate returned to
green at the numbers above. The gate can fail; this is not a tautology that
only ever reports success.

**Disabled-configuration check** (`rendering/pathtracer/transmission_enabled =
false`): all four probes read through-glass `0.000000` against their lit
controls and all four FAILED — i.e. with the Environment toggle off, glass is
a full occluder, matching what the BSDF itself draws for the same pane
(`raytracing_closest_hit_common_inc.glsl:1468` forces `transmissivness` to
0.0 in that config). The toggle is honoured inside the accumulation loop
rather than as an early return before it — an earlier revision that gated the
early return on the toggle made glass cast no shadow at all in the *default*
(enabled) config, because the TLAS cull mask is derived from the material
alone and does not vary with the toggle; see the inline comment at
`raytracing_lights_inc.glsl:348-362` for the full argument.

**Full doctest suite:** 1550 passed, 0 failed, 3 skipped, 2,068,020 assertions.

### 8.4 Production scenes — the two originally reported

Both scenes re-rendered end to end (not gate probes) against the reported
baselines, with an unrelated region of each image carried as a control to
show the change is localized rather than a global exposure shift:

| Scene | Region | Before | After | Delta |
|---|---|---|---|---|
| `urbantestdark191_glass` (front) | tank interior | 40.5, 47.4, 10.7 | 47.0, 55.4, 14.3 | mean luminance 32.9 → 38.9, **+18%** |
| `urbantestdark191_glass` (front) | room-wall control | 193.9, 180.2, 170.6 | 193.9, 180.2, 170.6 | **bit-identical** |
| `urbantestdark190_glass` (side) | tank | 84.4, 79.1, 74.8 | 86.7, 83.5, 79.5 | **+5%** |
| `urbantestdark190_glass` (side) | room-wall control | 146.8, 126.9, 114.9 | 147.1, 127.3, 115.2 | +0.3 (noise) |

The bit-identical control on 191 is the load-bearing number here, more than
either tank delta: it is direct evidence that the change is localized to
glass-occluded geometry rather than a shift in overall scene exposure that
happens to correlate with the tank getting brighter.

**Timing: INCONCLUSIVE, and reported as such rather than as "no cost."** Wall
times were 920s (191) vs. 921s originally, and 997s (190) vs. 960s originally.
Asset loading dominates the total — roughly 916s of the original 921s on
scene 191 — so at one sample per scene the render-loop cost cannot be
separated from ordinary load-time variance. This is the same shape of gap
§7.2 hit with frame-timing noise bands: a real single-digit-percent loop cost
would be invisible at this sample size, and nothing here rules it out. See
§8.5.3 for why a real cost is in fact expected on this feature specifically.

### 8.5 What this does not fix — four honest limits

**8.5.1 The side-view blackout is not fixed, and was never a shadow
problem.** `urbantestdark190`'s tank still reads as a grey mirror. The cause
is grazing-angle Fresnel/TIR dominating the panel's reflectance — at a steep
viewing angle the glass itself becomes near-total-reflective, so the camera
sees mostly the environment mirrored off the front face regardless of how
well the interior is lit. Fixing the shadow path cannot help when a
near-mirror sits in front of the thing being lit; this needs reflectance work
on the panel BSDF, a different problem than this phase addressed.

**8.5.2 The +18% is scene-bounded, not a general expectation.** The 191 tank
sits against an interior wall. Its *direct* light budget — the portion a
shadow ray carries — is small to begin with; most of its illumination is
multi-bounce indirect light, which shadow rays do not touch at all. Scene
lighting here is sun through two window openings, SKY ambient from an EXR
panorama, and three custom lights (one IES profile at energy 0.004). A tank
placed near a window, or a vitrine lit by a direct spot, would show a
substantially larger recovery than +18% — and a scene with no direct light on
the enclosed geometry at all would show none. Do not carry "+18%" into a
context that does not carry this scene's lighting layout with it.

**8.5.3 An unmeasured performance cost.** §8.2 explains why pass B is a
re-trace rather than an any-hit accumulation; the corollary is that pass B
dropped `gl_RayFlagsTerminateOnFirstHitEXT`, which pass A still uses. That
flag commits whichever hit *traversal* reaches first, not the nearest one —
fine for a boolean occlusion question, wrong for a march that needs the
genuine nearest crossing at each step (committing a far hit first would
silently discard every closer crossing, undercounting attenuation; see the
inline comment at `raytracing_lights_inc.glsl:389-398`). Dropping the flag
was the correct fix — probe 3's four-crossing result depends on it — but the
consequence is that pass B is now up to `max_transmission_bounce` (default
12) **full TLAS traversals per shadow ray**, in a scene doing NEE over
several lights. §8.4's timing measurement could not resolve this against
load-time noise. Correctness-first was the right call to make once the two
were in tension, but this cost is real, unmeasured, and recorded here as an
open item for whoever next touches shadow-ray performance.

**8.5.4 Alpha-cutout + transmissive is routed to the transmissive mask and
pass B never alpha-tests it.** `rt_instance_mask_from_features`
(`render_raytracing.cpp:2461`) chooses the TLAS cull mask purely from
`p_feature_bits & RT_FLAG_TRANSMISSIVE_GEOMETRY`, which is set at
`render_raytracing.cpp:1900` (`mat.transmission > 0.0f`) with no regard to
whether the material also uses alpha (`uses_alpha_clip` / `uses_blend_alpha` /
`uses_alpha`). Pass B's ray query then runs with `gl_RayFlagsOpaqueEXT`
(`raytracing_lights_inc.glsl:400`), which commits transmissive hits directly
and never invokes `ray_query_alpha_test` (`raytracing_lights_inc.glsl:243`).
A material authored with BOTH alpha-cutout AND `transmission > 0` — frosted
glazing cut to a grille shape, or cutout foliage with a transmissive
closure — therefore has its shadow attenuation computed over the full
triangle silhouette rather than the cutout shape, over-occluding through the
cut-away regions.

Unreachable by any content in this phase's gate or in the two production
scenes measured (§8.3/§8.4): the pipeline's own glass conversion sets
`transparency = TRANSPARENCY_DISABLED` alongside `transmission = 1.0`
(`pipeline_references/image_glb_creation.gd:1973`, `:5989`), so converted
glass never carries a cutout in current content. Not fixed here because both
candidate fixes have real cost that nothing has measured, and measurement-first
says do not pay it for content that does not exist yet:

- Drop `gl_RayFlagsOpaqueEXT` and alpha-test every transmissive candidate hit
  in pass B, the way pass A already does. Cost: every transmissive crossing
  now runs a candidate loop plus a material/alpha fetch, stacked on top of
  the pass-B traversal cost that §8.5.3 already records as unmeasured — two
  unmeasured costs compounding on the same hot path.
- Route cutout+transmissive materials back onto the opaque mask (so they keep
  using the existing any-hit alpha test) and give pass B a second, separate
  path for that combination. Cost: `rt_instance_mask_from_features` does not
  currently receive per-surface alpha-usage information — only
  `p_feature_bits` — so this needs new feature-bit plumbing through the same
  four TLAS push sites the function's own header comment enumerates, for a
  combination with no known instance in this codebase's content.

Correctness-first would fix this now; measurement-first defers it. Recorded
as an open item for whoever next touches the instance-mask helper or adds
cutout+transmissive content. **This was found by the final whole-branch
review, not by any per-task review** — no single task in this phase's plan
had "alpha-cutout" and "transmission" both in scope at once, so no task-level
review checklist ever put the two side by side.

### 8.6 Four defects that originated in the plan, not the implementation

Four separate defects in this phase traced back to the plan/spec rather than
to an implementer's execution of it — the same pattern §7's E1 closeout
flagged as the headline finding worth carrying forward, repeating here on a
smaller feature:

1. **Premature cull-mask narrowing.** The plan originally placed the
   `RT_INSTANCE_MASK_OPAQUE` narrowing in an earlier task than the pass B
   accumulation that depends on it. Measured effect: with the mask narrowed
   and no pass B yet, glass stopped blocking shadow rays at all (ratio
   1.000000, no attenuation) — worse than either the pre-fix or post-fix
   behaviour. The plan was amended to require both halves land in the same
   commit.
2. **A `USE_SER` branch that would have skipped pass B entirely in that build
   config.** The plan's own snippet converted only the non-SER branch's early
   `return` into a fallthrough into pass B; the SER branch had its own
   `return` and was left untouched. A build compiled with `USE_SER` would
   have taken the old opaque-only path and glass would still have blocked
   every shadow ray, silently, only in that configuration. Caught and fixed
   in the same commit as the main pass B implementation, not by the plan.
3. **The `TerminateOnFirstHit` ordering flaw** described in §8.5.3 — the
   plan's own code for pass B specified the flag pass A uses, which is
   correctness-incompatible with a march that must find genuine nearest hits.
   No gate probe with a single pane could have caught it (one crossing and
   two crossings both look plausible against a loose band); it took adding
   probe 3's two-pane/four-crossing case to expose it.
4. **An exit-face `eta` flip that caused spurious total internal reflection
   at grazing angles**, turning glass fully black past some incidence angle
   while a normal-incidence probe read a perfect `0.921600`. The plan
   mandated mirroring the BSDF's own eta flip (`raytracing_closest_hit_common_inc.glsl:1504`)
   at the shadow-ray exit face. That flip is correct for the BSDF, which
   bends the ray and evaluates the exit interface at the internal refraction
   angle — but pass B deliberately does not bend the ray (the no-caustics
   decision), so at the exit face it still holds the *external* angle. Using
   the internal eta against an external 80° incidence drove
   `fresnel_dielectric`'s TIR test negative, reporting total internal
   reflection where none should occur. Removed; by Fresnel reciprocity
   `R(θ_internal, 1/n) == R(θ_external, n)`, using the same `ior` at both
   crossings is exact, not an approximation — see the inline derivation at
   `raytracing_lights_inc.glsl:426-451`.

**The eta flip is the most reusable lesson of the four.** It is invisible to
any single-angle probe: normal incidence gives the same Fresnel factor either
way, so probe 1 read a perfect 0.9216 with the bug present and in place. Only
probe 2, at a different angle, could distinguish a correct implementation
from a wrong one — a general argument for why an angle-dependent physical
quantity needs more than one incidence angle in its test coverage, not
specific to glass or to this codebase.

## 9. Transparent BSDF closure closeout — alpha-blended surfaces stay in the tracer

**Complete.** `alphaMode: BLEND` surfaces are now traced, not rasterized.
Before this work, every alpha-blended surface — fish, sheer curtains, a glass
partition with books behind it — was dropped from the TLAS entirely and drawn
by a second, rasterized transparent pass composited on top of the finished
frame. The offline accumulation capture reads the accumulator, which the
raster pass never touches, so those surfaces were simply absent from
path-traced output: not dim, not wrong-shaded, not shadowed incorrectly —
absent. §8 fixed shadow-ray attenuation through transmissive glass; it did not
touch this, which is a separate defect on a separate code path. Cycles has no
such split — a `TRANSPARENT` closure is evaluated in the same integrator as
everything else — and this closeout brings this engine to the same shape.

### 9.1 The defect and its code anchors

Three `FLAG_PASS_ALPHA` skips in `build_tlas()`
(`servers/rendering/renderer_rd/forward_clustered/render_raytracing.cpp`)
excluded any surface carrying that pass flag from ever reaching a TLAS push:
the `scene_mask` feature-detection walk, the MultiMesh Phase 1 walk, and the
triangle-mesh surface walk. All three had to go, not just the one the plan
named — the first two are upstream of the TLAS push sites and left routing
plumbing dead even after the third was removed. Excluded surfaces were then
drawn by `RenderForwardClustered::_fill_render_list`
(`servers/rendering/renderer_rd/forward_clustered/render_forward_clustered.cpp:1082`),
whose `FLAG_PASS_ALPHA` branch (`:1330-1344`, pre-fix) rasterizes them as a
transparent overlay on the finished raster frame. That overlay is invisible
to the path-traced accumulator by construction: the accumulation buffers
(`RT_TEX_RAYTRACING_ACCUM` / `RT_TEX_RAYTRACING_ACCUM_N`,
`render_raytracing.h:48-49`) are written only by the raygen pipeline, and the
raster overlay runs on a wholly separate pipeline that composites after
accumulation has already been read out for capture.

### 9.2 The stochastic branch, and why stochastic rather than accumulative

The closure lives in `shade_and_bounce`, gated `if (m.blends && m.alpha <
1.0)` at `raytracing_closest_hit_common_inc.glsl:1383`. On that branch, a
single uniform draw —
`rng_1d(rng, RT_PRNG_TRANSPARENT) < (1.0 - m.alpha)`
(`RT_PRNG_TRANSPARENT`, slot 10u, `raytracing_inc.glsl:321`) — decides,
per-sample, whether this hit is skipped (the ray continues unbent, unshaded,
straight through the surface) or shaded normally as an opaque hit. Throughput
is left at 1.0 on both branches; the probability of taking each branch already
carries the weight. In expectation this is unbiased:
`E[contribution] = (1 - alpha)·behind + alpha·shaded`, and stacked layers
compose multiplicatively, `(1 - alpha)^n`, exactly like independent Fresnel
crossings.

The alternative is accumulative: blend the surface's own radiance with
whatever is behind it in a single deterministic evaluation, the way a raster
alpha-over does. That was rejected for two reasons, both load-bearing for a
path tracer with an accumulation buffer rather than a single raster
composite:

- **Order independence.** An accumulative blend has to know, at the point it
  shades the surface, what is behind it — which means either a second trace
  (a re-trace loop, as §8.2's shadow-ray pass B is) or deferred compositing
  after the fact. The stochastic branch needs neither: it is resolved with
  the ray already in flight, using the same trace that would have continued
  anyway. Stacked panes at different depths compose correctly with zero extra
  traces, because each one runs the identical branch independently when the
  ray reaches it.
- **Each layer contributes at its own weight, across samples, not within
  one.** An accumulative blend produces one image per frame in which every
  layer's contribution is baked into a single evaluation with a fixed
  formula. The stochastic branch instead lets convergence do the compositing:
  across `SPP` samples, roughly `alpha` of them shade the surface and roughly
  `(1 - alpha)` of them pass through, and the accumulator sums both
  populations. This is the same convergence machinery every other stochastic
  choice in this integrator already relies on (light selection, lobe
  selection, Russian Roulette) — the transparent branch is one more sampled
  decision, not a new kind of machinery bolted on beside it.

### 9.3 Gate results

Both gates PASS at `ec9489e113`:

| Gate | Result | Measured | Theory |
|---|---|---|---|
| `pt_transparent_alpha_gate` probe 1 (one pane, alpha 0.5) | PASS | 0.500002 | 0.5 |
| `pt_transparent_alpha_gate` probe 2 (two stacked panes, alpha 0.5 each) | PASS | 0.250027 | 0.25 (= 0.5²) |
| `pt_transparent_alpha_gate` probe 3 (alpha 1.0 vs. truly opaque) | PASS | delta 0 | indistinguishable |
| `pt_transparent_shadow_gate` probe 1 (one pane, normal incidence) | PASS | 0.921600 | 0.921600 |
| `pt_transparent_shadow_gate` probe 2 (one pane, 80° incidence) | PASS | 0.374911 | 0.374905 |
| `pt_transparent_shadow_gate` probe 3 (two panes / four crossings) | PASS | 0.849346 | 0.849346 |
| `pt_transparent_shadow_gate` probe 4 (one pane, transmission = 0.5) | PASS | 0.230400 | 0.230400 |
| `pt_transparent_shadow_gate` probe 5 (BLEND pane, alpha 0.5, two crossings) | PASS | 0.250000 | 0.25 |

Probe 2 is the one that matters most here, for the same reason
`pt_transparent_shadow_gate` probe 3 mattered in §8.3: a single-pane probe
cannot distinguish "one layer applied" from "one layer applied twice," so
without it a branch that silently double-counted or dropped a layer could
still read green on probe 1 alone. `pt_transparent_shadow_gate` probe 5 is
this closeout's, not §8's — it was added in Task 4 specifically to catch the
scene-level `RT_FLAG_TRANSMISSIVE_GEOMETRY` desync described in §9.7's third
erratum, and it is what actually caught it (§9.4).

Full doctest suite: **1550 passed, 0 failed, 3 skipped.**

### 9.4 The falsification result — a three-state separation, not a pass/fail

The strongest evidence for this closure is not that the gate is green — it is
that the gate reads three distinguishable values across three distinguishable
states of the code, each an opposite failure mode of the correct answer:

| State | probe 1 | probe 2 | Reading |
|---|---|---|---|
| Before the closure (surfaces excluded from TLAS) | 1.000000 | 1.000000 | Surface absent — ray never interacts with it at all |
| Closure branch forcibly disabled, TLAS routing left in place | 0.000000 | 0.000000 | Surface present but fully opaque — every hit shades, none pass through |
| Closure enabled (shipped state) | 0.500002 | 0.250027 | Surface present and stochastically transparent |

1.0 and 0.0 are not two flavors of "broken" that happen to bracket the
correct value — they are the two ways this specific mechanism can fail, and
they fail in opposite directions. A surface missing from the TLAS reads as if
it were not there (background passes through unattenuated, ratio 1.0); a
surface present in the TLAS with no stochastic branch reads as if it were
fully opaque (ratio 0.0, the pre-§8/§9 default for anything the tracer hits
and does not explicitly pass through). Landing at 0.500002 and 0.250027 —
between the two failure states, at the values Fresnel-free alpha compositing
actually predicts — is evidence the mechanism is doing what it claims, not
merely evidence that some code ran without crashing.

### 9.5 The fish, before and after

`urbantestdark180_fishtank` (front view): previously-missing fish restored.
The left tank now shows two lionfish and multiple blue tetras that were
absent before — they were `alphaMode: BLEND` materials, dropped from the TLAS
under the pre-closure code path, and simply did not exist in the traced
image. The right tank is unchanged, because its fish were already opaque
materials and were never subject to the defect. No ghosting, no doubled
silhouettes, no over-bright outlines — a double-draw (traced once, then
rasterized again on top) would show as an over-bright silhouette, and none
was observed, confirming §9.1's fix (removing the TLAS skips) and §9.1's
raster-overlay gate (`render_forward_clustered.cpp:1343`,
`rt_traces_alpha = p_alpha_only`) are landing together correctly rather than
one without the other.

`urbantestdark191_glass` (**side angle** — the specific case the user
reported as "side-angle blackout, the tank reads as a grey mirror reflecting
a dim room"): the angled tank now reads as glass. The interior is clearly
visible through the oblique pane, with two lionfish, several blue tetras,
plants, rocks, and a starfish all legible. This is the scene §8.5.1 explained
was *not* fixable by shadow-ray work alone — the grazing-angle Fresnel/TIR
diagnosis in that section was about reflectance dominating the view, not
about the fish being missing, and both were true simultaneously. This
closure fixes the second one.

`urbantestdark190_glass`: the glass partition now shows books through it, and
the sheer curtains read as translucent rather than as a solid wall.

**Quantified, aquarium scene, Task 1 build vs. Task 3 build, same project and
input:**

| region | pixels changed >8/255 | rmse |
|---|---|---|
| left tank interior (860×500 crop) | 8.02% | 16.32 |
| wall, contains no alpha geometry | 0.0000% | 0.199 |

The change is localized to where alpha geometry actually is. The wall is
*not* bit-identical — rmse 0.199, though no pixel there exceeds the 8/255
threshold — because the widened raygen loop bound (Task 3, §2 of the Task 3
report) lets some paths take a bounce they were previously cut off at,
everywhere in the scene, not only through alpha surfaces.

**Not fixed (out of scope, pipeline-side):** the water still lacks its
authored blue tint. See §9.7.

### 9.6 The cost

Phase split measured externally by timestamping the `Driving 128 frames` log
line (the log itself carries no timestamps):

| build | load + bake | render loop + save | total |
|---|---|---|---|
| pre-closure (`8f5ee320a3`) | 44s | 581s | 625s |
| with closure (`ec9489e113`) | 41s | 620s | 661s |

**Render-loop delta: +39s, +6.7%.**

This result is notable for what it contradicts, not just for its magnitude.
§8.4's timing was recorded INCONCLUSIVE because asset loading dominated wall
time — roughly 916s of a 921s total on that phase's scene. Here the opposite
holds: load is only ~6% of wall time and the **render loop is 94% of wall
time**, which is the regime in which a loop-cost delta is actually
measurable rather than lost in load-time noise. This is not a contradiction
in the engine's behavior — it reflects warm vs. cold file caching (below) —
but it means this measurement, unlike §8.4's, is not inconclusive.

Caveats, all load-bearing, none dropped:

- The load figures are warm-file-cache: four renders of this scene preceded
  these two. A cold first load is much slower and would shrink the render
  loop's share of the total — the 94%-of-wall-time framing above is a
  property of this measurement's cache state, not a universal claim about
  this scene.
- The aquarium carries only 3 alpha-blend surfaces out of 55 materials. A
  foliage-heavy scene is the real worst case for this change — alpha
  surfaces now generate traced hits and any-hit invocations where they
  previously generated none — and it was **not measured**.
- The delta includes both the added cost (tracing alpha surfaces, invoking
  any-hit on them) and the removed cost (no longer rasterizing them as an
  overlay). It is the honest net total of the change, not the isolated cost
  of either half.
- The shadow-march inner loop (`raytracing_lights_inc.glsl:479-482`) fetches
  `m_alpha` unconditionally on every crossing, including for non-blend
  materials where the value is computed and then discarded — a known,
  un-taken optimization, deferred from Task 4's review. This timing was
  measured with that inefficiency in place; a leaner inner loop would likely
  show a smaller delta.

### 9.7 The honest limits

- **The transmission bounce budget is shared, not separate.** Both the E1
  dielectric transmissive closure and this alpha pass-through spend from the
  same `transmission_bounces` counter (4 bits, max 15, default cap 12) — the
  packed bounce word (`raytracing_inc.glsl`, bits 0-7 total, 8-15 diffuse,
  16-23 glossy, 24 SAMPLE_ZERO, 25 SHADOW_RAY, 26 PATH_TERMINATED, 27-30
  transmission, 31 INSIDE_MEDIUM) has no free bit for a second counter.
  Cycles keeps `transparent_bounce` fully separate from `bounce`; this engine
  cannot, without a payload layout change. A scene combining dielectric glass
  with dense alpha-blend stacking — a glass display case full of
  alpha-blended foliage, say — exhausts the shared budget faster than either
  mechanism alone would, and there is currently no way to give one priority
  over the other.
- **Shadow behavior changed for every alpha-blended surface in every scene,
  not only aquariums.** §8/Task 4's shadow mix (`raytracing_lights_inc.glsl`)
  keys on `RT_MAT_FLAG_BLEND`, which this closure's TLAS routing is what
  makes reachable at all for a given surface. Any scene with alpha-blended
  geometry — curtains, foliage, decals, glass with an alpha channel — now
  casts `(1 - alpha)` shadows instead of the previous behavior (no shadow at
  all, because the surface was not in the TLAS). This is correct, but it is
  a behavior change everywhere such geometry exists, not a fish-tank-specific
  fix.
- **Any-hit invocations increased.** Blend surfaces do not carry
  `FORCE_OPAQUE_BIT` (§1.5 of the Task 3 report), so they now invoke any-hit
  where previously — excluded from the TLAS — they invoked nothing at all.
  This is necessary for the stochastic branch to work, and it is real added
  cost on every ray that can reach a blend surface, not only shadow rays.
- **The shadow-march inner loop fetches `m_alpha` unconditionally**, on every
  crossing, including for non-blend materials where the value is discarded
  (`raytracing_lights_inc.glsl:479-482`, deferred minor from Task 4's
  review). §9.6's timing was measured with this in place.
- **The water's blue tint is still missing, and this is pipeline-side, not
  engine-side.** `_apply_glb_transmissive_glass` in
  `pipeline_references/image_glb_creation.gd` sets `albedo_texture = null`,
  discarding the authored teal. This is a two-line revert in the user's own
  pipeline file, not this engine, and out of scope for this closure —
  `pipeline_references/*.gd` is the user's own work and was not touched here.
- **A foliage-heavy scene is the real worst case for cost and was not
  measured.** The aquarium's 3-of-55 alpha-blend surface ratio is a light
  load for this feature; nothing in this closeout's measurements bounds the
  cost on a scene where alpha-blended geometry dominates the surface count.

### 9.8 Erratum — this plan's own spec was wrong twice, both caught by measurement

Consistent with §8.6's finding on the previous phase: in this phase too, the
defects that shipped in the *plan* rather than in its execution were caught
by running a probe, not by reading the plan more carefully.

1. **The material flag was specified for bit 2, which was already
   `RT_MAT_FLAG_POINT_FILTER`.** The claim traced to a stale comment at
   `raytracing_data_inc.glsl:136` (`uint flags; // Bit 0: has_normal_map, Bit
   1: has_emission`) that documented only bits 0 and 1 and said nothing about
   bit 2 already being spoken for. Shipping the plan's bit assignment would
   have collided two unrelated flags into one bit: every blended material
   would have sampled its textures unfiltered, and every pixel-art material
   using point filtering would have become partially transparent. Neither
   failure throws an error or looks obviously wrong in isolation — two
   plausible-looking renders, both silently incorrect. Corrected to bit 3
   (`RT_MAT_FLAG_BLEND = 8u`) before any code shipped against the wrong bit.
2. **The blend gate was keyed on `uses_blend_alpha`, which is false for
   `BLEND_MODE_MIX`** (`material_storage.cpp:718`,
   `ShaderData::blend_mode_uses_blend_alpha`). glTF's `alphaMode: BLEND`
   produces `BLEND_MODE_MIX` on import, not the mode this predicate actually
   tests true for — measured directly: **0 of 55 materials** on the aquarium
   scene satisfied `uses_blend_alpha`. The real signal is the `has_alpha`
   term of `rt_uses_alpha_pass()`, exposed as `rt_uses_alpha_blending()`
   (`scene_shader_forward_clustered.h:345`). Had this shipped as specified,
   the entire closure would have been correctly implemented and structurally
   inert — every gate probe and every production scene would have shown
   zero surfaces routed, and nothing about the code itself would have looked
   wrong.
3. **Task 3 broke the invariant stated at `render_raytracing.cpp:1902`** —
   that the scene-level `RT_FLAG_TRANSMISSIVE_GEOMETRY` bit and the
   per-instance TLAS mask predicate must agree on which surfaces are
   transmissive — by widening the instance-mask predicate
   (`rt_instance_mask_from_features`) to route blend surfaces onto
   `RT_INSTANCE_MASK_TRANSMISSIVE` without widening the scene-level bit to
   match. A blend-only scene (alpha-blended, no material with
   `transmission > 0`) then had every blend surface's shadow ray culled to
   pass A (opaque mask, which cannot see it) while pass B never ran at all
   (`RT_GET_TRANSMISSIVE_GEOMETRY()` false) — neither shadow pass touched it.
   `pt_transparent_shadow_gate` probe 5, added in Task 4 specifically for
   this scenario, was the first probe in either gate capable of catching it:
   it read `1.000000` (no attenuation at all) instead of the expected
   `0.250000` until the scene-level bit was widened to match, at
   `render_raytracing.cpp:2629-2647`.

The lesson, stated plainly and without flattery: in all three cases, a
comment or a flag name was trusted over the code it actually described — a
stale bit-layout comment, a plausibly-named boolean that didn't mean what its
name implied, and an invariant comment that had gone stale the moment an
earlier task widened one side of it without the other. None of the three was
caught by reading the plan again. All three were caught by a probe reading a
number that didn't match the number the plan predicted.

### 9.9 Deferred items from the final whole-branch review

The final review approved the branch for merge with no Critical and no Important
findings. It triaged the items below as acceptable to defer; they are recorded
here rather than lost, and none of them blocks the feature.

1. **Unconditional `m_alpha` fetch in the shadow march.**
   `raytracing_lights_inc.glsl:479-482` samples the albedo texture on every
   pass-B crossing, including for non-BLEND materials where `pass_through` is
   forced to 0 and the fetched value is provably discarded. A wasted texture
   sample in a hot loop. Gating the fetch behind `RT_MAT_FLAG_BLEND` is a pure
   optimisation with no behavioural change. Note that the `+6.7%` render-loop
   cost recorded in §9.6 was measured **with this waste in place**.

2. **`rt_uses_alpha_blending()` includes `has_read_screen_alpha`.** A material
   reading SCREEN, DEPTH or NORMAL texture receives `RT_MAT_FLAG_BLEND`. The
   review verified the mitigation holds on *both* consumers rather than just
   the shading branch: such a material with base alpha 1.0 has `m.alpha == 1.0`
   (closure branch inert) and `m_alpha == 1.0` (shadow `pass_through == 0`), so
   both are neutralised identically.

3. **Custom ShaderMaterial can bypass the any-hit scissor.** A hand-written
   shader setting *both* `uses_alpha_clip` and `uses_blend_alpha` gets
   `RT_MAT_FLAG_BLEND`, which makes the any-hit test at
   `scene_raytracing_raygen.glsl` never fire for it — the cutout is silently
   replaced by stochastic blending. Unreachable from `BaseMaterial3D`, whose
   transparency modes are mutually exclusive. A real gap for custom shaders only.

4. **Stranded raster-setup work under RT.** `render_forward_clustered.cpp:1172-1188`
   still performs GI/lightmap setup for any instance carrying an alpha surface,
   but under RT that surface's `RENDER_LIST_ALPHA` membership is now suppressed.
   CPU-side waste mirroring item 1's GPU-side waste — newly stranded by the
   overlay gating rather than newly introduced. Not confirmed to affect
   correctness; a second consumer of those flags was not fully ruled out.

5. **Gate hygiene, `pt_transparent_alpha_gate.gd`.** The control-is-black guard
   double-counts: `_measure_ratio` appends a failure and increments `_checks`,
   then the caller does the same again with the returned `0.0`. Cosmetic — the
   guard still correctly fails the gate, so no false pass is possible. Inherited
   verbatim from the sibling gate. Separately, `BACKDROP_EMISSION*` is reused as
   a standalone pane's emission in a probe that has no backdrop; name only.

**Open and genuinely unverified**, requiring runs this branch did not make:

- A DLSS-RR-enabled render of an alpha-dense scene, checking for haloing at the
  transmission-budget-exhaustion edge. The review established that primary-hit
  depth and velocity writes are gated on `total_bounces == 0` — which the
  transparent branch never increments — so a later real hit overwrites them, and
  that the DLSS-RR AOVs proper are written inside `shade_and_bounce` strictly
  after the transparent branch's early return and are never reached on a
  pass-through sample. The one case that does **not** self-correct is a ray
  exhausting the shared transmission budget mid-stack, where depth and velocity
  then describe the last alpha layer rather than the surface behind it.
- OIDN `cleanAux` behaviour on blend surfaces, which likely shares the same
  primary-hit gating but was not traced against OIDN's own path.
- A foliage-heavy scene's cost. The aquarium carries 3 blend surfaces of 55
  materials; the worst case remains unmeasured.


### 9.10 Open gap — low-alpha panes lose their specular, and a pipeline substitution is masking it

**Status: open. Not fixed by this phase, and carried forward deliberately.**

The closure weighs a blended surface's shading by its authored alpha: draw
`u < (1 - alpha)` and the ray passes straight through, otherwise shade normally.
That is correct for the transmitted share and it is what §9.3's gate measures.
But it means **everything** the surface would contribute — its specular lobe and
Fresnel response along with its albedo — is scaled by `alpha`. For a clear glass
pane, which is exactly the case where the reflection is the whole visual, that
scaling is severe:

| asset | authored base colour | effective alpha | shaded share |
|---|---|---|---|
| MarineDecorativeGlassAquarium `Glass` | white `255,255,255` | 0.098 | ~10% |
| ModernCurvedGlassCoffeeTable `Glass` | dark `106,106,106` | 0.804 | ~80% |

At `alpha = 0.098` the pane keeps roughly a tenth of its reflection and reads
flat — an open box rather than a glass tank. Measured directly: routing the
aquarium panes through the closure instead of the transmissive conversion moved
**10.75% of the fish-tank render by more than 8/255, rmse 14.61**, and the
visible result was the tank glass losing its presence entirely. The smoked table
top at `alpha = 0.804` has no such problem, because 80% of its shading survives.

**What is masking it.** The GLB pipeline converts alpha-blended panes to opaque
transmissive materials (`transparency = DISABLED`, `transmission = 1.0`,
`ior = 1.2`), which gives them real Fresnel and makes clear glass look right.
That conversion is a leftover workaround from before this phase, when alpha
surfaces were dropped from the TLAS entirely and converting them was the only
way to see them at all. It is now scoped by `_glb_alpha_convert_is_lossless()`
to fire only where it throws nothing away — essentially colourless
(`min RGB >= 0.90`) and mostly transparent (`alpha <= 0.35`) — because it had
been keyed on the material's *name* and was flattening an 80%-covering dark
smoked table top into clear colourless glass.

**What Cycles actually does — checked, and it disproves the obvious hypothesis.**
The natural reading is that our closure dims the reflection where Blender does
not. That is wrong. `intern/cycles/kernel/svm/closure.h:108-113`:

```c
/* Before any actual shader components, apply transparency. */
const float alpha = saturatef(stack_load(stack, data.alpha));
if (alpha < 1.0f) {
  bsdf_transparent_setup(sd, weight * (1.0f - alpha), path_flag);
  weight *= alpha;
}
```

`weight *= alpha` scales the entire Principled closure — sheen, coat, specular,
metallic and diffuse alike — exactly as our branch does, and the comment says so
in as many words. **Cycles' alpha weighting and ours agree.** Any explanation
that starts "our closure weights alpha differently from Cycles" is already
refuted; do not spend time there.

**So the cause is unidentified, and the first task is to find out whether there
is one.** Two possibilities remain open, and they lead to opposite conclusions:

- Our specular response for the surviving share is genuinely weaker than
  Cycles' — plausible candidates are the uniform `metallic = 1.0` these panes
  author, the `KHR_materials_specular` `specularColorFactor` of `[2.0, 2.0, 2.0]`
  they carry (which Blender maps to Specular IOR Level as `0.5 * specularFactor`
  and we may not read at all), or our Fresnel term on a metallic surface. If so,
  this is a real parity gap and fixing it lets the substitution go.
- **Or Cycles renders this aquarium's glass just as flat as our closure does**,
  and the transmissive conversion is not restoring parity at all — it is a
  deliberate divergence that happens to look better. If so the substitution
  should be kept and documented as an intentional deviation, not deleted.

Nothing in this phase distinguishes those. The measurement that does is cheap
and must come first.

**What to investigate, in order.**

1. **Render the aquarium GLB in Cycles and look at the glass.** This single
   observation decides which of the two branches above is true, and therefore
   whether there is anything to fix. Everything else is premature until it is
   done.
2. If Cycles' glass is solid where ours is flat, diff the specular path: what we
   read from `KHR_materials_specular` (if anything), how metallic 1.0 at 10%
   alpha resolves in each, and the Fresnel term. A change here alters every
   alpha-blended surface in every scene, so it needs its own gate with a
   falsifiable band in the style of §9.3.
3. If Cycles' glass is equally flat, keep the conversion, and rewrite this
   section to record it as an intentional divergence with that evidence — the
   substitution then stops being a debt and becomes a decision.
4. Only if step 2 lands does deleting `_apply_glb_transmissive_glass`, its
   keyword lists, and `GLB_CONVERT_MAX_TINT` / `GLB_CONVERT_MAX_ALPHA` from both
   pipeline scripts become possible.

**Do not close this gap by widening the thresholds.** Tuning
`GLB_CONVERT_MAX_TINT` or `GLB_CONVERT_MAX_ALPHA` to capture more panes moves
the mis-classification boundary rather than removing it, and each widening
silently discards more authored appearance. The threshold pair exists to be
deleted or deliberately justified, not tuned.

**Erratum for this section.** Its first draft asserted that the alpha weighting
was the defect and told a future reader to reweight the reflective lobe. That
was a hypothesis stated as a finding, and checking `closure.h` — a two-minute
read of source that was already on disk — refuted it. Recorded because it is the
third time in this phase that something was asserted from plausibility rather
than read from the code (see §9.8).


---

## 10. Gap #17 closeout — Cycles' multi-scatter energy compensation for the base specular lobe

**Landed 2026-09-10** on `vijay_PTEngine_V18_GAP17`.
Spec: `docs/superpowers/specs/2026-09-10-ggx-multiscatter-energy-design.md`.
Plan: `docs/superpowers/plans/2026-09-10-ggx-multiscatter-energy.md`.

### 10.1 What was wrong

`evalMultiScatterApproximation` returned `1 + F0 * Ems`, with
`Ems = lerp(0.2·r², 0.32·r² + 1.94·r⁴, N·V)` — wrong in two independent ways
against `microfacet_ggx_preserve_energy`
(`intern/cycles/kernel/closure/bsdf_microfacet.h:466-485`):

1. a **fitted polynomial** where Cycles uses the true `(1 − E)/E` from a table
   built by numerical integration of the actual GGX lobe;
2. **raw `F0`** where Cycles uses the multi-bounce
   `Fms = Fss·E_avg / (1 − Fss(1 − E_avg))`.

It now returns `1 + Fms·(1 − E)/E`, which is the product `energy_scale × darkening`
that an engine with no separate closure weight sees — the identical derivation
E2d already made for the coat (`coatEnergyScale`).

### 10.2 The finding that nearly sent this the wrong way

Cycles gates base-lobe compensation on `preserve_energy = is_multiggx` at all
three Principled microfacet lobes (`svm/closure.h:346`, `:414`, `:463`), which
reads as *"Cycles does not compensate the base lobe at all"* — under which the
correct fix would have been **deletion**. It is not:
`node_shader_init_principled` sets `node->custom1 = SHD_GLOSSY_MULTI_GGX`
(`source/blender/nodes/shader/nodes/node_shader_bsdf_principled.cc:330`), so every
Principled node ever created — including every one Blender's glTF importer builds
— defaults to Multiscatter GGX, which maps to
`CLOSURE_BSDF_MICROFACET_MULTI_GGX_GLASS_ID` (`intern/cycles/blender/shader.cpp:732-733`).
Compensation is the default path. Reading only the gate, and not the node's
initialiser, would have produced a confident and exactly wrong change.

### 10.3 Measured — the three-state falsification

White furnace, roughness 0.4, `pt_anisotropy_gate.gd` probe 1:

| `RT_MS_COMPENSATION` | a = −0.9 | **a = 0.0** | a = +0.9 |
|---|---|---|---|
| `2` legacy `1 + F0·Ems` | 1.077787 | **1.059535** | 1.034011 |
| `0` no compensation | 0.982335 | **0.965699** | 0.942440 |
| `1` Cycles table | 1.017784 | **1.000549** | 0.976442 |

State `2` reproduces the committed `BASELINE_INTACT_RATIO` to 0.01pp and the
isotropic entry **exactly**, so the legacy path is bit-preserved. State `0`
reproduces the 0.9657 this document had already recorded independently. **The
isotropic furnace goes +5.95% → +0.05%**, and that is Gap #17 closed.

The acceptance was analytic rather than empirical: the furnace sphere is albedo 1
/ metallic 1, so `Fss = mix(1,1,1/21) = 1`, hence `Fms = E_avg/E_avg = 1`, hence
the factor is exactly `1/E` — and a single-scattering lobe of directional albedo
`E` times `1/E` returns exactly 1. A CPU mirror asserts `E × factor == 1` to 1e-5
across the roughness/`mu` grid (`tests/servers/rendering/test_pt_ms_energy.cpp`).

**The gate got stronger, not merely re-baselined.** Probe 1's absolute check
existed and was correct all along, but fix round 2 demoted it to diagnostic-only
because the over-compensation made every sweep entry fail it *on a correct build*
— leaving the gate structurally unable to fail on an absolute energy error, which
is the condition that let this defect stand through two phases. It is asserted
again, at anisotropy 0.

### 10.4 What the sweep uncovered — now Gap #19

The anisotropic entries still do not read 1.0, and the three-state table above is
what identifies why. The offset from each state's **own** isotropic control is
+1.66 to +1.83pp at anisotropy −0.9 and −2.33 to −2.55pp at +0.9 — essentially
identical in all three states **including state `0`, where no compensation is
applied at all.** It cannot be caused by the factor this work replaced.

`TOLERANCE` was deliberately **not** widened to absorb it. Probe 1's absolute
check is asserted where the `1/E` derivation applies (isotropic) and left
diagnostic where it does not, and the residual is filed as Gap #19 with this
measurement as its evidence.

### 10.5 What this does NOT fix — stated so the closeout cannot overclaim

- **The transmissive lobe** keeps the fitted approximation — Gap #20.
- **The anisotropic residual** — Gap #19.
- **The Cycles scene comparisons in §7.8, §7.10 and §7.11 have NOT been
  re-taken.** Their pedestal-adjusted figures are now what the engine produces,
  but the raw comparisons against Blender were not re-measured in this work: the
  `.blend` scenes and scripts behind them were never checked into this repo, only
  `.superpowers/sdd/2026-08-21-environment-energy-fidelity/cycles-hypothesis-report.md`.
  Do not read those adjusted numbers as freshly measured.
- **§7.11.2's unexplained −2.06% dielectric-base residual** may have moved. No
  claim is made about it without a re-measurement.
- **Blender parity on the diffuse-under-specular layer** remains open (filed
  2026-09-09; base specular directional albedo through `layerTransmittanceAbove`).

### 10.6 Regression evidence

`pt_energy_gate.gd`'s five pre-MIS references were **re-captured, not
overwritten with current renders.** They were taken at `de2ce2c248`, which
predates environment NEE *and* carries the old factor, so comparing against them
would have conflated a deliberate BRDF change with the MIS neutrality the gate
exists to assert. The new values come from a BSDF-only build
(`RT_ENV_NEE_ENABLED 0`) that also carries the new compensation — with gate 1's
pass-C std-dev reading exactly **0.000000**, which is what proves it really was
BSDF-only and not merely dimmer.

Measured neutrality on the MIS-on build: smooth −0.003%, rough +0.03%, rim
−0.12%, bumpy −0.01%, diffuse +0.02%. Only `rough` moved materially from the old
reference (1.70870 → 1.63024, −4.6%) — metallic 1 at roughness 0.6, where `F0 = 1`
made the legacy factor over-shoot hardest. Unmoved as required: gate 1's absolute
0.49999, the Lambertian plane, and the roughness-0.02 mirror (`E ≈ 1`, so the
factor is ≈ 1).

Suite 1555 passed / 0 failed / 3 skipped. Anisotropy, coat, sheen and energy
gates all green.


---

## 11. Gap #19 decided — Cycles fails the anisotropic furnace too, and by more than we do

**Measured 2026-09-11.** Blender **5.2.1 LTS** (the only runnable install on this
machine; 4.2/4.4/4.5 are leftover script folders with no executable, so this is
*not* the 4.5.3 the §7.8/§7.10/§7.11 comparisons used — stated because it is a
real difference, not a footnote). Script:
`scratchpad/cycles_aniso_furnace.py`.

### 11.1 The question

§10.4 isolated an anisotropy-dependent furnace error that is present with our
multi-scatter compensation set to legacy, to Cycles' table, or **disabled
entirely** — so it could not be caused by the factor Gap #17 replaced. Two
possibilities remained, leading to opposite conclusions: either our E2b
anisotropic branch is wrong, or Cycles shares the approximation (both feed a
`(rough, mu)` table with no anisotropy axis the geometric-mean roughness).

### 11.2 The measurement

White furnace: uniform world radiance 1.0, sphere of base colour 1 / metallic 1,
`film_transparent` so the sphere can be isolated by alpha, 1024 samples, no
denoising, clamping off. Our own gate's framing was verified to be sphere-only
too (its comment: "EVERY pixel in the render is a sphere hit and none is
background sky"), so the two sets of numbers are directly comparable with no
dilution correction.

The two isotropic rows are the control, and their agreement is the result.

| configuration | Cycles 5.2.1 | ours | ours vs 1.0 | **ours vs Cycles** |
|---|---|---|---|---|
| roughness 0.4, anisotropy 0.0 | 1.000499 | 1.000549 | +0.05% | **+0.00%** |
| roughness 0.4, anisotropy 0.5 | 0.990723 | 1.017584 | +1.76% | **+2.71%** |
| roughness 0.4, anisotropy 0.9 | 0.927854 | 0.976442 | −2.36% | **+5.24%** |
| roughness 0.9, anisotropy 0.9 | 0.864730 | 1.278307 | +27.83% | **+47.83%** |
| roughness 0.9, anisotropy 0.0 | 0.999645 | **0.999631** | −0.04% | **−0.00%** |

### 11.3 The verdict

**Gap #19 is not ours to have caused, and it is not fixed by matching Cycles.**

- **Cycles fails the anisotropic white furnace, worse than we do.** At roughness
  0.4 / anisotropy 0.9 it loses 7.2% of the energy a perfectly reflective surface
  must return; at roughness 0.9 / anisotropy 0.9 it loses 13.5%. So "port what
  Cycles does" is not a fix here — Cycles has the same blind spot, for the same
  structural reason.
- **Isotropically the two engines agree to ~1e-5, at both roughnesses tested**
  (1.000549 against 1.000499 at roughness 0.4; 0.999631 against 0.999645 at
  roughness 0.9). That is an independent confirmation, from a source outside
  this project, that the Gap #17 fix landed correctly — and it holds across the
  roughness range, not only at the 0.4 the anisotropy sweep happened to use.
- **But the two engines fail in opposite directions**, so this is a live parity
  gap: we over-recover the missing energy, Cycles under-recovers it, and the
  divergence between the two reaches **+5.24%** at roughness 0.4 and **+47.83%**
  at roughness 0.9 with strong anisotropy. **A brushed-metal material will not
  match Blender**, and the §7.8 brushed-metal comparison — taken at anisotropy
  0.9 — is sitting on top of this.

Reframed accordingly in the §2 table: severity raised to **High**, and the item
is now about *reconciling with Blender*, not about restoring energy conservation.
Making our furnace read 1.000 would move us **further** from Blender, so the two
goals genuinely conflict here and the choice has to be made deliberately.

### 11.4 How the measurement was validated, including the control that failed

Three internal checks, none of which had to be taken on trust:

1. **Cycles' compensation is demonstrably on.** Its isotropic roughness-0.4
   furnace reads 1.000499; uncompensated it would read ≈0.966 (our own
   `RT_MS_COMPENSATION 0` measured 0.965699). This also rules out a stray view
   transform, which would have moved the number far from 1.0.
2. **Anisotropy is demonstrably active.** The furnace result moves 1.000499 →
   0.927854 as anisotropy goes 0.0 → 0.9. An inert parameter cannot do that.
3. Channels read R = G = B exactly, and the alpha mask kept 62567 of 65536
   pixels, so the material and the mask behaved as intended.

**The control designed for job 2 did not work, and is recorded rather than
quietly dropped.** Reading `svm/closure.h:309` in the 5.3-alpha source
(`if (anisotropic > 0.0f && stack_valid(data.tangent_offset))`) suggested
anisotropy would be inert unless a Tangent node were connected, so the script
rendered a point-lit pair with and without one. Both pairs returned an *identical*
RMSE of 5.008440 against the isotropic render — meaning the explicit Tangent node
changed nothing, because 5.2.1 already supplies a default tangent. The control was
therefore uninformative, and the activation evidence is check 2 above instead. The
source read was of a different version than the binary, which is exactly the kind
of gap this document keeps logging errata about.

### 11.5 The isotropic high-roughness control — measured, and it settles the split

**Measured 2026-09-11**, added as **probe 1c** in `pt_anisotropy_gate.gd` so it
stays reproducible rather than living in a scratch scene.

**Our engine at roughness 0.9, anisotropy 0.0 reads 0.999631. Cycles reads
0.999645. They agree to 1.4e-5.**

That was the cell separating the two candidate explanations, and it comes down
firmly on one side:

- **The entire divergence from Blender is anisotropy.** Both isotropic
  configurations — roughness 0.4 *and* roughness 0.9 — agree with Cycles to about
  1e-5. Every anisotropic configuration diverges, and the divergence grows with
  both roughness and eccentricity.
- **Gap #17's fix is complete across the roughness range**, not merely at the 0.4
  the sweep happened to use. The `1/E` derivation holds at 0.9 too, in both
  engines independently. Whatever Gap #19 is, it is not unfinished business from
  Gap #17.
- **The search narrows to the anisotropic branch itself** — `evalMicrofacet`'s
  `anisoActive` path, `anisoAspect`, and the anisotropic VNDF sampler — plus the
  decision both engines share, to feed an isotropic `(rough, mu)` table the
  geometric-mean roughness.

The magnitudes are worth stating together, because they show the two engines
departing in opposite directions from the same isotropic starting point. Going
from anisotropy 0.0 to 0.9 at roughness 0.9: **ours swings 0.999631 → 1.278307
(+27.9%), Cycles swings 0.999645 → 0.864730 (−13.5%).** Same material, same
parameter, same aspect formula, opposite sign.

Probe 1c asserts its absolute check against 1.0. Unlike probe 1's anisotropic
entries and probe 1b, it is isotropic, so the `1/E` derivation applies exactly and
the assertion is sound rather than aspirational. It passes at 0.04%.
