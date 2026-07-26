# RTX Path Tracer Quality Gap Analysis & Roadmap to Blender-Cycles / D5 Parity

**Scope:** Code-level diagnosis of why this Godot 4.7 fork's path-traced image/video renders do not match reference-grade renderers (Blender Cycles, D5 Render), with a prioritized, code-anchored roadmap of concrete modifications.

All file:line references are against the current branch `vijay_pt2_shadows`.

---

## 0. Executive Summary

The engine has a genuine, well-engineered GPU hardware-raytracing path tracer living inside the Forward+ renderer:
`servers/rendering/renderer_rd/forward_clustered/render_raytracing.cpp` + `scene_shader_raytracing.{cpp,h}`
shaders in `servers/rendering/renderer_rd/shaders/raytracing/`.

It uses a high-quality BRDF library (Boksansky "Crash Course in BRDFs" — VNDF GGX sampling, height-correlated Smith G2, **multi-scatter energy compensation already present**), does **Next Event Estimation (NEE)** with cone-sampled soft shadows for point/spot/sun lights, and outputs DLSS Ray Reconstruction G-buffers for denoising.

The reason quality trails Cycles/D5 is **not** the BRDF — it is a cluster of integrator and pipeline gaps. Ranked by impact:

| # | Gap | Cycles/D5 behavior | Severity |
|---|-----|--------------------|----------|
| 1 | **No accumulative offline render path.** Image "render" = wait 80 frames + grab one **LDR PNG**. No EXR/HDR, no convergence buffer, SPP fixed per-launch. | Cycles accumulates to a float buffer until noise threshold / sample target; outputs 32-bit EXR linear. | **Critical** |
| 2 | **No MIS** between NEE light sampling and BRDF indirect sampling. Direct + indirect both added, no balance/power heuristic → bias + extra noise. | Cycles uses MIS for every light/BSDF pair | High |
| 3 | **Emissive geometry is not sampled as a light** (only analytic `rt_lights[]`). | Cycles treats emissive meshes as area lights with MIS | High |
| 4 | **`MAX_DIFFUSE_BOUNCES` hardcoded to 2** regardless of user `max_bounces`. Global GI dies after 2 hops. | Cycles: separate diffuse/glossy/transmission bounce counts, all user-controlled and high | High |
| 5 | **White-noise PCG RNG, no blue-noise / stratification / Owen scrambling.** At low SPP this is the single biggest perceived-quality gap vs D5. | D5: blue-noise + path-space; Cycles: scrambled Sobol + PMJ | High |
| 6 | **No Russian Roulette.** Paths killed only by bounce caps → wasted work, biased path length. | Both: RR with throughput-based continuation probability | Medium |
| 7 | **Point-sampled camera** (no jitter, no pixel filter). Aliasing + jagged silhouettes at low SPP; DLSS-RR can't synthesize what was never sampled. | Cycles: EWA/mitchell pixel filter + jitter | Medium |
| 8 | **Path radiance/throughput stored in fp16** in the payload. Loses precision in high-dynamic-range scenes (sun, fire, bright area lights → banding/highlight energy loss). | Cycles: fp32 throughout | Medium |
| 9 | **Sky/IBL sampled uniformly** (octmap lookup on miss), no environment importance sampling. Noisy/flat sky reflections. | Cycles: MIS environment sampling (alias/portal/Latin-hypercube) | Medium |
| 10 | **No transmission/refraction in the BRDF path** (`transmissivness` hardcoded 0 in integrator), no **BSSRDF/subsurface**, no anisotropy, no clearcoat/sheen. | Cycles: full Principled BSDF incl. subsurface, glass, dispersion | Medium |
| 11 | **Biased bump-map workaround** (shading-normal clamp + plane mirror) instead of offset/position-normal sampling. | Cycles: proper offset normals, no clamp bias | Low-Med |
| 12 | **Denoiser dependency is binary-only (DLSS-RR).** No OIDN/CPU fallback; silently no-op if `sl.*.dll` missing (see `DLSS_Implementation.md`). | Cycles: bundled OIDN, optional OptiX | Low (ops) |

The roadmap below addresses these in priority order, each with concrete code anchors.

---

## 1. Architecture — what is actually here (reference map)

### Integrator location
- C++ driver: `servers/rendering/renderer_rd/forward_clustered/render_raytracing.cpp` (3271 lines). Builds the TLAS/BLAS, light buffer, `rt_params` UBO, dispatches the raygen pipeline.
- Shader reflection / pipeline: `scene_shader_raytracing.{cpp,h}`.
- GLSL shaders: `servers/rendering/renderer_rd/shaders/raytracing/`:
  - `scene_raytracing_raygen.glsl` — raygen/miss/closest_hit/any_hit/intersection stages.
  - `raytracing_inc.glsl` — payload packing, RNG, ray-origin offset, bounce flags, **`MAX_DIFFUSE_BOUNCES 2u`**.
  - `brdf_inc.glsl` — full BRDF library (Boksansky CC0).
  - `raytracing_lights_inc.glsl` — NEE + reservoir light selection + shadow rays.
  - `raytracing_closest_hit_common_inc.glsl` — `shade_and_bounce()` = the integrator kernel.
  - `raytracing_material_eval_inc.glsl`, `raytracing_hit_inc.glsl`, `raytracing_data_inc.glsl`, `raytracing_common_inc.glsl`, `raytracing_samplers_inc.glsl`, custom-hit `raytracing_custom_*.glsl`.

### How path tracing is turned on (from GDScript)
- Environment storage of 16-float packed params: `environment_storage.cpp:911` (`environment_set_pathtracing_params`), `environment_storage.h:177` (`float pathtracing_params[16]`).
- UBO plumbing into shader: `render_raytracing.cpp:3001` (`environment_get_pathtracing_params_ptr` → `memcpy` into `rt_ubo.params`).
- Exposed knobs (ClassDB-bound): `set_pathtracing_enabled`, `set_pathtracing_max_bounces`, `set_pathtracing_samples_per_pixel`, `set_pathtracing_denoiser`. Defaults actually used in pipeline: **image 12 bounces / 20 SPP; video 6 bounces / 6 SPP** (`pipeline_references/image_glb_creation.gd:788-794`, `pipeline_references/video_glb_creation.gd:1111-1113`).
- `SPP` is a **specialization constant** (`RT_GET_SAMPLE_COUNT()` in raygen, `scene_raytracing_raygen.glsl:45`); `max_bounces` likewise (`:51`). Changing them recompiles the pipeline.

### Per-frame state
Only `RT_PARAM_FRAME_INDEX = p_state->frame_counter++` varies per frame (`render_raytracing.cpp:3010`). It only reseeds the RNG. **Nothing accumulates across frames** for the image/video capture path (see §2.1).

### DLSS-RR denoiser
- `servers/rendering/renderer_rd/effects/dlss.{cpp,h}` + `drivers/streamline/streamline_context.cpp`. Requires `sl.interposer.dll`, `sl.common.dll`, `sl.dlss_d.dll`, `nvngx_dlssd.dll` in `bin/` (see root `DLSS_Implementation.md`). If absent, `slDLSSDSetOptions` stays null and DLSS-RR silently evaluates false (`dlss.cpp:340`-region). Only runs when `Viewport.SCALING_3D_MODE_DLSS` is set (`pipeline_references/render.gd:139-145` — scale 1.0 for denoise-only).

### Tone mapping
AgX/ACES/Filmic/Reinhard/Linear all present (`rendering_server_enums.h:683-687`, `effects/tone_mapper.cpp:262-266`). So the **operator** is not the gap — the gap is the HDR float pipeline *into* it (§2.1).

### Still-image and video capture (the actual output path)
`pipeline_references/render.gd`:
- `render_image()` (`:338`) → `await _wait_frames(80)` for warm-up → `_capture_viewport_image(6)` (`:358`) → `img.save_png()` (`:360`). Captured from `vp.get_texture().get_image()` — an **8-bit PNG of the tonemapped viewport**.
- `render_video()` (`:443`) / `video_render.gd` → `for frame in total_frames: cam.lerp(); await _wait_frames(1); _capture_viewport_image()` → PNG per frame.

Both paths are "fire the realtime viewport N times then grab a snapshot." There is no offline accumulation step.

---

## 2. Gap Analysis — code-level detail

### 2.1 [CRITICAL] No accumulative offline render path → no convergence, no HDR output

**Where:** `render.gd:338-365`, `_capture_viewport_image:957-967`.
The viewable image is the tonemapped, 8-bit viewport after 80 warm-up frames. The path tracer writes to `image` (rgba32f) **fresh every launch** (`scene_raytracing_raygen.glsl:101` `imageStore`), dividing by `samples_per_pixel` of *that launch*. There is no history buffer, no `accumulate(buffer += new / (frame+1))`. So the only way to raise effective SPP is to recompile the shader with a higher `RT_GET_SAMPLE_COUNT()` specialization constant — bounded by RT-core register pressure and single-frame time.

Cycles accumulates `pixel += throughput*rad; samples++` across thousands of independent samples into a persistent fp32 buffer, converging asymptotically, and outputs 32-bit linear EXR (open for grade).

**Consequence:** Even with the BRDF quality equal to Cycles, the still can never reach reference convergence quality; highlights/clipping, firefly persistence, and noise floor are all capped by per-launch SPP. 8-bit PNG loses the HDR headroom Cycles preserves for grading.

### 2.2 [HIGH] No Multiple Importance Sampling (MIS)

**Where:** integrator kernel `shade_and_bounce()` in `raytracing_closest_hit_common_inc.glsl:442-592`; NEE in `raytracing_lights_inc.glsl:237-378`.

The NEE loop (`:528-534`) adds `direct_light = lights_evaluate_direct_lighting(...)` scaled only by `1/light_select_pdf` and shadow/attenuation — **not** by an MIS weight. Meanwhile the BRDF-sampled bounce (`:561-591`) just multiplies throughput by `brdf_weight` with no compensating term. Consequences:
- **Direct bias/noise:** When a BRDF lobe is sharp (low-roughness metal) and the NEE point-sample misses the specular highlight, the estimator wastes samples; when the BRDF bounce *also* hits the light, both contributions partially count without MIS damping → slight over-bright + variance.
- For area lights this is exactly the case MIS fixes: Cycles weights `w = p_light / (p_light + p_brdf)` (balance or power heuristic) for the light sample and `1 - w` on the BSDF sample. Neither term exists here.

(Existing reservoir selection in `lights_evaluate_direct_lighting:250-281` only approximates the *light-picking* PDF; it does not introduce MIS against the BSDF.)

### 2.3 [HIGH] Emissive geometry is not a light

**Where:** `raytracing_closest_hit_common_inc.glsl:458` — emissive only contributes via throughput: `ps.radiance += ps.throughput * m.emissive;` when a path *happens* to hit it. The NEE function `lights_evaluate_direct_lighting` only iterates the analytic `rt_lights[]` buffer (`raytracing_lights_inc.glsl:255`). Emissive meshes/triangle lights are never sampled explicitly and never part of MIS → strongly emissive scenes (neon signs, screens, light panels) are noisy and biased exactly where they matter most.

### 2.4 [HIGH] Hardcoded diffuse bounce cap of 2

**Where:** `raytracing_inc.glsl:134` `#define MAX_DIFFUSE_BOUNCES 2u`, enforced in `raytracing_closest_hit_common_inc.glsl:461`:
`if (total_bounces >= RT_GET_MAX_BOUNCES() || diffuse_bounces >= MAX_DIFFUSE_BOUNCES) terminate;`

User `set_pathtracing_max_bounces(12)` raises the **total** ceiling, but diffuse (GI) is independently capped at 2. Interior daylight (sun → floor → wall → ceiling) needs ≥3-4 diffuse hops to look right; color-bleeding and corner-fill die early → flat, "no real GI" look even though the code *can* bounce 12 times. This single constant is the cheapest high-impact fix.

### 2.5 [HIGH] White-noise sampling — no blue noise / stratification

**Where:** `raytracing_inc.glsl:151-168` PCG with naive seed (`pixel.x + pixel.y*65536 + frame*1e6 + sample*1e8`), then `rand()`/`rand2()` drawn directly. No Owen scrambling, no Sobol/PMJ, no blue-noise tile.

At the configured **20 SPP still** / **6 SPP video**, the error is dominated by *structured* noise (splotches, banding) because samples are uncorrelated per pixel. D5 and modern Cycles use Owen-scrambled Sobol + blue-noise dithering so the rendered error looks like fine filmic grain, not clumps, and denoising removes it cleanly. This is the largest *perceptual* gap for the same sample budget.

### 2.6 [MEDIUM] No Russian Roulette

**Where:** integrator has no roulette; termination is only the bounce check at `:461`. Cycles/D5 terminate a path probabilistically based on throughput (e.g. `p = clamp(luminance(throughput), 0.05, 0.95)`; on termination scale surviving samples by `1/(1-p)`). Without RR, work is wasted on low-throughput tails and the *effective* path-length distribution is biased (truncated) not unbiased.

### 2.7 [MEDIUM] Point-sampled camera (no jitter / no AA filter)

**Where:** `scene_raytracing_raygen.glsl:31` `const vec2 pixel_center = vec2(pixel) + vec2(0.5);`. Every sample for a pixel uses the identical ray direction; `samples_per_pixel` internal loop multiplies SPP but all SPP rays share the origin direction → SPP above 1 only helps via the bounce RNG, not pixel coverage. No jitter = hard edges, shimmering silhouettes; the DLSS-RR input lacks sub-pixel info to reconstruct. Cycles uses jittered/poisson subpixel + EWA/Mitchell filtering.

### 2.8 [MEDIUM] fp16 radiance/throughput in payload

**Where:** `PathPayload.packed_rt[3]` fp16 packing, `raytracing_inc.glsl:38-85`; `path_pack` clamps to `FP16_MAX=65504`. Throughput multiplied over many bounces accumulates fp16 rounding; bright direct hits near 65504 clamp lose energy. Cycles runs fp32 end-to-end. For indoor/night scenes with huge sun/intralight dynamic range this shows as banding in highlights and slightly darker caustics.

### 2.9 [MEDIUM] Sky/IBL uniform sampling

**Where:** miss shader `scene_raytracing_raygen.glsl:128-225` — on miss, looks up `radiance_octmap` along the **exact** ray direction with no importance sampling. With high dynamic range skies (e.g. sunset window) tiny bright regions get hit by chance only → noisy sky reflections/specular. Cycles MIS-samples the environment (alias method over a marginals CDF + conditional, or portal lights). Adding env-MIS on top of existing NEE is the canonical upgrade.

### 2.10 [MEDIUM] Missing BSDFs

**Where:** `brdf_inc.glsl:270-279` `MaterialProperties` has `transmissivness` and `opacity` fields, but the integrator hardcodes `brdf_mat.transmissivness = 0.0; brdf_mat.opacity = 1.0;` (`raytracing_closest_hit_common_inc.glsl:474-475`). Rough glass (refraction) is unsupported in the PT BSDF path; recent "glass vanishing" commit workaround hints this is handled out-of-band. No BSSRDF (skin/wax/marble wrong), no anisotropic roughness (alpha2D is always `alpha,alpha` per `sampleGGXVNDF` callers), no clearcoat, no sheen — all present in Cycles Principled BSDF.

### 2.11 [LOW-MED] Biased bump-map recovery

**Where:** `clampShadingNormal` (`brdf_inc.glsl:954-965`) + `recoverBelowHemisphereSample` (`:998-1009`) — when a BRDF sample goes below the geometry plane (aggressive normal map + grazing angle), it mirrors the direction across the geometry plane and reuses the original BRDF weight. The comment itself admits "energy-non-conserving (over-bright at grazing angles)." Cycles uses offset/position-normal sampling that never goes below-plane, no bias. This is intentional duct tape; proper fix is offset normals.

### 2.12 [LOW] Denoiser robustness

`dlss.cpp` checks `slDLSSDSetOptions != nullptr && streamline_capabilities.dlss_rr_available`. If Streamline DLLs aren't deployed (documented in `DLSS_Implementation.md`), denoising silently no-ops. Cycles ships a fallback. Recommend an OIDN path option (or at least a loud warning + null-fallback) so CI/other machines don't silently regress.

---

## 3. Roadmap (prioritized, code-anchored)

Phases are ordered so earlier work *de-risks / magnifies* later work. Each item lists the file(s) to change and a concrete acceptance test.

### Phase A — "Make the still render actually converge" (highest ROI, ~1-2 weeks)

#### A1. Add a persistent accumulation buffer + offline still path  [addresses 2.1]
- In `render_raytracing.cpp`, allocate a persistent fp32 `history_color` image (per render target). Add `RT_PARAM_ACCUM_FRAMES` and `RT_PARAM_RESET_ACCUM` to the `rt_ubo.params` slot (indices 4-13 are reserved-free per `raytracing_inc.glsl:22`).
- Change `scene_raytracing_raygen.glsl` to, instead of `imageStore(image, px, total/SPP)`, do per-launch single-sample (SPP=1) accumulation: `float n = frame_index; imageStore(acc, px, mix(prev, new, 1/(n+1)))` and write the running average to the display `image`. Reset buffer when `RT_PARAM_RESET_ACCUM` flips (camera/scene change).
- Add a new RenderingServer entry point such as `set_pathtracing_accumulate(enabled, target_frames)` mirroring the existing `environment_set_pathtracing` plumbing (`rendering_server.h:690`, `environment_storage.cpp:911`).
- GDScript: in `render.gd:render_image`, replace "wait 80 frames, grab one PNG" with *drive N draw frames into the accumulator until convergence* then grab the 32-bit image.
- **A2. HDR output.** Capture the compositor input (linear fp buffer) and `img.save_exr(...)` (Godot 4.x `Image.save_exr` exists). Optionally export both `.png` (tonemapped) and `.exr` (linear).

**Acceptance:** Diffuse a Cornell-ish test scene at 64 vs 4096 frames → variance falls ~16× and output noise matches SPP-equivalent reference; EXR opens in Blender with intact highlights.

#### A2. Decouple SPP specialization from convergence  [enables A1]
- `RT_GET_SAMPLE_COUNT` is a specialization constant recompiling the pipeline. With A1, SPP-per-launch can stay 1 and accumulation provides the budget; remove the need to recompile to raise quality. Keep the variable for realtime.

### Phase B — Integrator correctness (1-2 weeks)

#### B1. Multiple Importance Sampling  [addresses 2.2]
- Add `mis_weight` computation in `lights_evaluate_direct_lighting`: compute the BSDF pdf for the sampled light direction (`diffusePdf(NdotL)` for diffuse; `specularPdf(...)` for specular) and weight the NEE estimate by `w = p_light² / (p_light² + p_brdf²)` (power heuristic).
- On the BRDF-sampled bounce in `shade_and_bounce` (`:561`), when the new ray would hit a light (detected next-bounce emissive), apply the complementary MIS term `1 - w` — implemented simplest via recording the chosen BSDF pdf on the payload and *also tracing* a shadow ray to lights on the BRDF sample (the dual of NEE). Easiest separation: keep two estimators but power-heuristic them; add a `bsdf_pdf` field to payload.
- **Acceptance:** Reflection of a small bright area light off a glossy floor → specular highlight variance drops, no double-bright near the light.

#### B2. Enable diffuse bounces from the user knob  [addresses 2.4]
- Replace `#define MAX_DIFFUSE_BOUNCES 2u` (`raytracing_inc.glsl:134`) with an `rt_params` slot (e.g. reuse reserved index 16-region; the packed-bounce byte already tracks diffuse count at `:91-95`). Bind `set_pathtracing_max_diffuse_bounces` analogously to `set_pathtracing_max_bounces`. Default ≥4.
- **Acceptance:** Sun-on-floor interior: warm bounce reaches the ceiling/wall, eliminating the "no GI above 2 hops" flatness without raising total bounces.

#### B3. Blue-noise / Owen-scrambled Sobol sampler  [addresses 2.5]
- Add a Sobol sequence table + per-pixel Owen scramble key seeded from pixel/frame (small LUT in the UBO, or a 1D 256-entry buffer). Provide `sample_sobol(dim, seed)` returning `[0,1)` and replace `rand2`/`rand` call-sites in `brdf_inc.glsl` and `raytracing_lights_inc.glsl` with dimension-advancing Sobol. Optionally XOR a blue-noise dither tile for the per-pixel offset.
- **Acceptance:** At equal low SPP the noise is fine grain, not clumps; after A1's denoiser, residual pattern disappears at 1/4 the sample count.

### Phase C — Light & environment fidelity (1-2 weeks)

#### C1. Emissive-geometry light sampling (mesh lights)  [addresses 2.3]
- Maintain an emissive-triangle light buffer built in `render_raytracing.cpp` alongside `gather_lights` (a list of emissive triangles with area, emission, sampled position). In `lights_evaluate_direct_lighting`, pick either an analytic light or an emissive triangle with pdf proportional to emitted power × area; sample a point on the triangle; MIS-combine with the BSDF.
- This reuses the existing TLAS for shadow rays.
- **Acceptance:** A scene lit only by a glowing panel renders clean at low SPP; no hotspot speckle.

#### C2. Environment importance sampling / MIS  [addresses 2.9]
- Build a 2D marginal/conditional CDF over the sky `radiance` cube (once per environment update); store as a 2D texture. In the miss shader, when *sampling* the sky for NEE, draw a (u,v) from the CDF, return `sky_color/0`. Apply the same power MIS between BRDF sky bounce and env-NEE.
- Optional portal lights via Godot's existing `DirectionalLight3D`-style API for windows.
- **Acceptance:** Sunset-window specular reflection converges at 2× the rate of uniform.

### Phase D — Sampling math & throughput correctness (1 week)

#### D1. Camera jitter + pixel filter  [addresses 2.7]
- In `scene_raytracing_raygen.glsl:31`, replace `+ vec2(0.5)` with a jittered sample drawn from the Sobol/blue-noise sampler (Phase B3), e.g. `vec2(p) + sample2d(dim_camera)`. When A1 accumulation is active, jitter each frame. Apply a box/triangle filter (triangle is cheap and crisp). Wire unjittered VPs into the DLSS-RR motion path so denoiser still works (the `curr_vp_unjittered` plumbing at `render_raytracing.cpp:3012-3022` already exists).
- **Acceptance:** Edges of foreground objects vs background are smooth at low SPP; DLSS-RR history reprojection improves (visible through frame-to-frame stability).

#### D2. Russian Roulette  [addresses 2.6]
- After throughput update in `shade_and_bounce` (`:578`), when `total_bounces > MIN_RR_BOUNCES` (e.g. 3) compute `p = clamp(maxComponent(throughput), 0.05, 0.95)`. If `rand > p`, terminate; else `throughput /= p`. Pack p-scaled throughput.
- **Acceptance:** Same image with RR on at throughput-clamped scenes; render time per frame drops in long-bounce heavy scenes with no visible bias.

#### D3. fp32 payload (optional)  [addresses 2.8]
- Widen `PathPayload` radiance/throughput to fp32 (costs 6 bytes/payload; revisit the 32-byte packing at `raytracing_inc.glsl:38`). Profile RT-core occupancy; if it hurts, keep fp16 for indirect but carry a secondary fp32 "active throughput" register via the raygen loop reconstruction (the raygen loop already rebuilds state per bounce — `:86-93`).
- **Acceptance:** A bright-area-light test (sun 1000×) no longer clamps/bands in specular tails.

### Phase E — BSDF completeness (2-3 weeks, parallelizable)

#### E1. Transmission / rough glass in the BRDF path  [addresses 2.10]
- Implement GGX refraction sampling (`sampleMicrofacet` half-vector then refract instead of reflect when entering a dielectric). Branch in `evalIndirectCombinedBRDF` on `material.transmissivness > 0`. Handle IOR side (front/back face, total internal reflection → reflect). Remove the `transmissivness=0` hardcode (`raytracing_closest_hit_common_inc.glsl:474`).
- Add `set_pathtracing_max_transmission_bounces`.
- **Acceptance:** A glass vase renders refractive, rough-glass blurs correctly; no more "glass vanishing" workaround.

#### E2. Subsurface scattering (BSSRDF)  [addresses 2.10]
- Either random-walk BSSRDF inside the volume (cost ~ moderate) or the burley dipole approximation for realtime. Add via a new `MaterialProperties` flag and an `evalBSSRDF` separable lobe sampled with the techniques in Heitz/"BSSRDF importance sampling".
- **Acceptance:** Skin/wax reads correctly under the existing NEE direct lighting.

#### E3. Anisotropy, clearcoat, sheen (Principled parity)  [addresses 2.10]
- `alpha2D` is already plumbed through `sampleGGXVNDF(Ve, alpha2D, u)`; callers pass `(alpha,alpha)`. Thread an anisotropy factor through `MaterialData` and remap to `alpha2D`. Add a clearcoat GGX lobe evaluated/sampled alongside the base. Add Charlie/sheen for fabric.
- **Acceptance:** Brushed-metal anisotropic reflections, clearcoat car paint, and fabric sheen render with Cycles-comparable response.

### Phase F — Robustness / polish (rolling)

#### F1. Optional OIDN denoiser fallback  [addresses 2.12]
- Add `PT_DENOISER_OIDN` enum value (currently only `NONE=0`, `DLSS_RR=1` per `rendering_server_enums.h` PT enum). Wire to Intel OIDN (it's already a common thirdparty option). Use when DLSS-RR unavailable.
- **Acceptance:** A machine without Streamline DLLs still denoises (slower, CPU), with a logged warning.

#### F2. Replace biased bump workaround with offset normals  [addresses 2.11]
- Use normal-mapping offset/`safe` normals so BRDF samples never fall below the geometry plane; remove `clampShadingNormal` mirror fallback (`recoverBelowHemisphereSample`). Preserve the debug vis at `raytracing_closest_hit_common_inc.glsl:22` for comparison.
- **Acceptance:** At grazing angles on a high-frequency normal-mapped water plane, energy stays flat (no over-bright), no more black speckle.

---

## 4. Validation harness recommendation
Build a fixed test scene set (Cornell box, mirror-on-floor area light, glass vase, interior daylight room) with reference Cycles EXRs at matching exposure; diff each phase's EXR output via mean-squared-error + structural (FLIP/LPIPS-style) and SSIM. Cheapest durable signal that the changes move toward parity rather than sideways.

---

## 5. Out of scope / already good
- BRDF library quality (GGX VNDF, height-correlated G2, multi-scatter comp) is **at** Cycles-class already.
- NEE and soft-shadow cone sampling for point/spot/sun lights is present and correct (only MIS against BSDF is missing).
- TLAS/BLAS building, SER reorder hint, motion-vector/depth output for DLSS-RR are solid.
- DLSS-RR G-buffer outputs (diffuse/specular albedo, normal/roughness, specular hit distance) are correctly fed to the denoiser.
- AgX/ACES/Filmic tone operators are available; that is not a gap.

---

*Bottom line:* the fastest path to "looks like Cycles" is Phase A (accumulation + HDR output) + A2 + B3 (blue-noise) + B2 (diffuse bounces) — those four changes alone will close most of the perceived gap for still images at modest cost and unblock everything else. MIS (B1) and emissive/env sampling (C1/C2) are the next visible wins. Phase E is where matched-per-feature parity (glass/skin/fabric) lives.
