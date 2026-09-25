# Path guiding for bounce-lit surfaces (Gap #32, §11.28)

**Date:** 2026-09-22. **Scope:** engine (`servers/rendering/renderer_rd/`),
one pipeline switch. **Predecessors:** the daylight design (Gap #31,
`2026-09-19-daylight-design.md`), whose measurement is this gap's complaint;
light portals (`2026-09-18-light-portals-design.md`), whose `mis_origin`
plumbing this design reuses; the still route
(`2026-09-16-still-route-pixel-filter-design.md`).

## The complaint

Gap #31 removed the shadowless fill grid and the portal spots from day
renders. Those were zero-variance light. What replaced them is physical:
sky through the openings and a sun patch on the floor, reaching the walls by
one to three diffuse bounces. Measured on the four daylight jobs
(daylight spec, "Measured"): pre-denoise wall grain **12.82% (226), 16.39%
(227), 14.29% (157)** against the ≤ 10% bar and against **7.8%** for the
prior rig on the same plan as 227 (§11.26). Job 176, a deep room lit mostly
by fixtures, reads 5.48%. The post-OIDN PNG reads 0.1–3.8% on the same
crops; the grain is real and OIDN is hiding it, at the cost of detail
(§11.28: a pendant cable's shadow on a ceiling at 12% grain is smoothed
away).

The noise source is the **indirect diffuse term**: a wall vertex
cosine-samples a hemisphere in which the light lives in a few degrees (the
sun patch, the window). Direct light is not the problem on these jobs — the
sun is a single delta light with NEE and the sky already has portal-aware
NEE — so the roadmap's ReSTIR item (direct, many-light) does not apply here.

## Decisions (brainstorm 2026-09-22)

1. **Measured against the daylight production jobs** (226/227/157), not
   the roadmap's night many-light fixture.
2. **Unbiased only.** Path guiding with MIS against BSDF sampling; no
   radiance cache, no irradiance interpolation.
3. **Equal frames, with a time ceiling**: 256 accumulation frames as today,
   render time ≤ +25% on the 4K job.
4. **Hashed directional histogram**, not a parametric (vMF / Open PGL)
   fit. Coarse but simple, entirely on the GPU, deterministic.

## What the code offers (read 2026-09-22)

- The raygen owns the bounce loop (`scene_raytracing_raygen.glsl:184`,
  `trace_one_sample`); closest-hit returns the next ray in the payload. A
  per-path record of visited vertices can live in raygen registers with no
  payload growth (the payload is 92 bytes, `PathPayload`).
- The BSDF strategy's density is written at ONE site,
  `raytracing_closest_hit_common_inc.glsl:2588`
  (`ps.mis_ray_pdf = combinedPdf(N, next_dir, V, brdf_mat)`), and read
  against a light density at TWO: env NEE (`:1981`,
  `combinedPdf(N, env_dir, V, brdf_mat)`) and emissive NEE
  (`raytracing_emissive_inc.glsl:525`). Analytic lights are delta and do not
  MIS. The miss stage and emissive hits consume `mis_ray_pdf` as a number.
  So a change to the diffuse lobe's density inside `combinedPdf`
  (`brdf_inc.glsl:3517`) reaches every consumer.
- The lobe choice happens before the direction sample (`selectLobe`,
  `brdf_inc.glsl:2231`); `evalIndirectCombinedBRDF` draws the chosen lobe's
  direction. The diffuse draw is `sampleHemisphere` (cosine,
  `brdf_inc.glsl:698`).
- RNG: each bounce owns a 16-dimension block (`RT_PRNG_BOUNCE_NUM`,
  `raytracing_inc.glsl:401`); dimensions 13–15 are free.
  `RT_PRNG_SURFACE_BSDF` (0, 2-D) is the direction sample.
- `rt_ubo.params[40]` (`render_raytracing.cpp:4234`); slots 0–34 used, 35–39
  free. The TLAS AABB is `p_state->volume_box` (valid flag
  `volume_box_valid`). `Environment.pathtracing_params[16]` is FULL (0–15,
  `rendering_server_enums.h:776-822`), so a new Environment property would
  mean widening the RS API; `rendering/pathtracer/*` project settings are
  read per frame instead (`render_raytracing.cpp:2619`, `emissive_active`).
- Descriptor set 0 bindings used: 0–8, 29, 30, 32–41. 42 and 43 are free.
- Accumulation: `accum_frame` (0-based, `RT_PARAM_ACCUM_FRAMES`) per
  frame; the reset path is the Phase A block at `render_raytracing.cpp:4283`.
- `ZR_SEED_OFFSET` (`render_raytracing.cpp:2583`) gives independent-seed
  renders for noise measurement.

## Design

### 1. The cache

Two SSBOs, flat `uint` arrays, `rt_guide_train` (binding 42) and
`rt_guide_read` (binding 43). Each holds `GUIDE_CELLS = 2^18` cells of
`GUIDE_BINS + 1 = 65` words: 64 fixed-point radiance bins and a sample
count. 68 MB each.

**Cell key.** `(ivec3 voxel, uint nkey)` where `voxel = floor((P −
origin) / cell)` and `nkey ∈ 0..5` is the normal's dominant signed axis.
`origin` and `cell` come from the UBO (`RT_PARAM_GUIDE_ORIGIN_X..Z` = slots
36–38, `RT_PARAM_GUIDE_CELL` = slot 39): `cell = max(longest AABB edge / 64,
0.15 m)`. The normal key keeps the two faces of a wall, and the floor and
the ceiling where they meet, in different cells (the SHaRC keying); a plain
voxel grid leaks light across walls. The key is hashed (PCG-style integer
mix of the four ints) modulo `GUIDE_CELLS`; collisions are NOT resolved. A
collision makes two surfaces share one distribution — a loss of guiding
efficiency, never of correctness: whatever the cell says is the density
that is both sampled and reported, and any positive density is unbiased.

**Bins.** An 8×8 grid over the full sphere in `(cos θ, φ)` with world +Y
as the polar axis: row = `floor((d.y + 1)/2 · 8)`, column = `floor((atan(d.z,
d.x) + π)/2π · 8)`. This is exactly equal-area (`4π/64` sr per bin) and a
uniform point in a bin's `(cos θ, φ)` rectangle is uniform in solid angle,
so `p_guide(ω) = w[bin(ω)] / (W_hemi · 4π/64)` is exact, where `W_hemi` is
the cell's total over the bins whose CENTRE lies in the hemisphere of the
current normal. (Not the octahedral map: `oct_inc.glsl`'s L1 projection is
not equal-area, and a pdf that assumes it is would be biased — plan
deviation, 2026-09-22.)

**Fixed point.** Bins are `uint`, added with `atomicAdd`, value ×
`GUIDE_FIXED = 1024`, saturating (an add that would overflow is skipped;
the cell has learnt what it needs by then). Well-trained bins receive
`L/p ≈ constant` adds, which is what keeps the sums bounded; see Risks. Integer
adds are associative, so the trained table — and the render — is
repeat-identical run to run, which the suite's md5 floors depend on.

**Snapshot.** At the start of every accumulation frame `rt_guide_train` is
copied to `rt_guide_read` (`RD::buffer_copy`, no shader). The frame samples
and evaluates pdfs from `rt_guide_read` only; the sampling density and the
MIS density are therefore the same frozen data. Both buffers are zeroed
(`RD::buffer_clear`) when accumulation is switched ON — the new-cycle edge
at `render_raytracing.cpp:4293` — and NOT on the camera-move / resize /
rt-flags resets: the table is world-space and scene-bound, a camera move
does not invalidate it, and a gate that switches to the vis mode to inspect
the table (an rt-flags change) must find it intact. Guiding is inert on
non-accumulating frames (`RT_PARAM_GUIDE_PROB` is written as 0 there).

### 2. Training

The raygen keeps a record of the first `GUIDE_RECORD = 4` diffuse vertices
of the path: `pos`, `nkey`, `dir` (the direction taken), `pdf` (the density
it was drawn with, i.e. the mixture at that vertex), `throughput_after`
(after the BSDF weight and roulette), `radiance_before` (the pixel's
radiance accumulated through that vertex's NEE). A vertex is recorded when
the closest-hit reports a diffuse or sheen lobe draw (`brdfType == DIFFUSE_TYPE` only). Sheen, glossy, transmissive and SSS
vertices are neither recorded nor guided: the diffuse counter also counts
sheen and SSS exits, so the closest-hit marks a diffuse-lobe draw with a
second bit in the payload's `sss_restart.w` (0/1 today for `sss_exit`;
bit 1 = guide record) — no payload growth, and raygen reads exactly the
predicate it needs.

When the path ends (terminated, missed, rouletted, capped), for each recorded
vertex `k`, in any order:

```
L_in  = (radiance_final - radiance_before_k) / throughput_after_k   // per channel
v     = min(luminance(L_in), clamp_indirect)                         // RT_PARAM_CLAMP_INDIRECT, 0 = no clamp
w     = v * min(1 / pdf_k, GUIDE_MAX_INV_PDF = 64)
atomicAdd(train[cell_k].bin[bin(dir_k)], uint(w * GUIDE_FIXED))
atomicAdd(train[cell_k].count, 1)
```

`L_in` is the path's own unbiased estimate of the radiance arriving at
vertex `k` along `dir_k` (everything after `k` is proportional to
`throughput_after_k`); the division removes that factor. Dividing by the
draw density is what makes the bin converge to `∫_bin L_in dω` whether the
sample came from the cosine lobe or the guide, so tables trained under
either agree. The two clamps act on the TRAINING signal only, never on the
image: they bound how much a firefly or a low-pdf draw can distort the
guide, and the guide's shape affects variance, not the expectation.

Training runs on every accumulation frame, sample zero included. Cycles'
`guiding_training_samples` cutoff exists because Open PGL's fit is
expensive; an atomic add is not, and later frames keep sharpening the
table.

A `throughput_after_k` of zero (a rouletted or absorbed continuation)
records nothing for `k`: its continuation carried no estimate.

### 3. Sampling and MIS

At a diffuse-lobe draw (`brdfType == DIFFUSE_TYPE`), the vertex's cell in `rt_guide_read` is
looked up once. Guiding is **active** at the vertex iff `guide_prob > 0`,
`count ≥ GUIDE_MIN_COUNT = 32` and `W_hemi > 0`; otherwise the draw is
exactly today's (`α = 0`, the pdf hook returns the cosine density, no code
path changes).

With `α = guide_prob` (0.5 in production, Cycles' `surface_guiding_probability`):

- coin `c = rng_1d(RT_PRNG_GUIDE = 13)`. `c ≥ α` → cosine sample as
  today. `c < α` → guided: build the 64-entry CDF over `w[b] ·
  max(dot(bin_dir_b, N), 0)` (hemisphere restriction and the diffuse
  target's cosine), select the bin with `u.x` of the 2-D
  `RT_PRNG_SURFACE_BSDF` draw, reuse the residual `(u.x − cdf_lo) /
  (cdf_hi − cdf_lo)` and `u.y` as the uniform point inside the bin,
  `oct_decode` it. The same two dimensions the cosine draw would have used.
- The **diffuse lobe's density** at any direction becomes
  `p_diff(ω) = (1 − α)·max(dot(N, ω), 0)/π + α·p_guide_cos(ω)` where
  `p_guide_cos` is the density of the cosine-weighted bin selection above.
  This is implemented inside `combinedPdf`'s diffuse branch, gated on the
  per-vertex guiding state passed in (`GuideState {active, α, cell,
  W_hemi_cos}`), so its three call sites are unchanged text and the miss /
  emissive-hit consumers of `mis_ray_pdf` see a consistent number.
- The sample weight. The integrator's estimator is one-sample-per-lobe:
  `shade_and_bounce` divides the throughput by the lobe's selection
  probability and `evalIndirectCombinedBRDF`'s diffuse branch returns
  `f_diff·cos / p_cos` (`diffuseReflectance · diffuseTerm`, the cosine
  density cancelled analytically). That estimator stays; only the diffuse
  density changes. So for BOTH coin outcomes, when guiding is active, the
  returned weight is multiplied by `p_cos(ω) / p_diff(ω)` — the cosine
  density the branch assumed over the mixture density the direction was
  actually drawn with. For a guided draw the direction is injected into the
  same diffuse branch (a `evalIndirectCombinedBRDF` overload taking a
  world-space direction instead of drawing one), so the weight, the
  `bumpShadowingTerm` and the geometry-horizon rejection are the existing
  code's. When guiding is inactive nothing is multiplied. (Plan deviation
  from the first draft's "full BSDF evaluation": that would have changed the
  estimator, not just its density.)

`W_hemi_cos` (the cosine-weighted hemisphere total for the vertex's N) is
computed once per vertex from 64 reads and passed to both the CDF build and
the pdf. Per guided vertex the cost is two 64-word reads of the snapshot;
no traversal, no extra rays.

### 4. Plumbing and control

- **Switch:** project setting `rendering/pathtracer/guiding_probability`
  (float, default **0.0**, range 0–0.9), read per frame like
  `emissive_mesh_lights`, written to `RT_PARAM_GUIDE_PROB` (slot 35). The
  still route (`render.gd :: render_image`) sets it to 0.5 before the
  render via `ProjectSettings.set_setting`; `render_video()` and the DLSS-RR
  real-time route leave it 0 — there is no training window at one sample
  per frame. Not an Environment property: `pathtracing_params[16]` is full
  and widening it is an RS API change this gap does not need.
- **Grid:** origin and cell from `p_state->volume_box` when
  `volume_box_valid`; otherwise cell = 0, and the shader treats `cell <= 0`
  as guiding off.
- **Buffers:** created on first use with guiding > 0 (68 MB × 2), freed
  with the other RT buffers. Copy train→read before each raygen dispatch of
  an accumulating frame; clear both on accumulation reset.
- **Instrument:** vis mode `RT_VIS_GUIDE_CELL` — each primary hit's cell:
  R = `count / 256`, G = `W_hemi / (W_hemi + 1)`, B = `nkey / 5`. A flat
  black image means the key/hash/lookup path is broken; that is the
  diagnosis a grain number cannot give. (Instrument note: the vis payload
  clamps to [0, 1e6] — every channel here is non-negative by construction.)
- **Files:** new `raytracing_guiding_inc.glsl` (key, hash, oct mapping,
  `guide_lookup`, `guide_cdf_sample`, `guide_pdf`, `guide_train_vertex`) —
  pure functions over the two SSBOs, included by raygen (training) and
  closest-hit (sampling, pdf). `brdf_inc.glsl`: `combinedPdf` gains the
  diffuse-density hook and a `GuideState` parameter with an inert default.
  `raytracing_closest_hit_common_inc.glsl`: the guided branch in the diffuse
  sampling path only. The vertex record lives in raygen, not in the payload:
  after each closest-hit returns, raygen recognises a diffuse draw by the
  diffuse-counter delta with `sss_exit` false (SSS exits also increment
  that counter and are excluded), takes the density from `mis_ray_pdf`
  (skipping the vertex when it is `RT_MIS_PDF_NONE`), `pos` from the next
  ray origin, `dir` from `next_ray_dir`, `nkey` from `offset_normal`, and
  `throughput_after` / `radiance_before` from the payload as returned.
  `render_raytracing.cpp`: buffers, copy, clear, UBO slots, setting read.
  `scene_shader_raytracing.h`: the four `RT_PARAM_GUIDE_*` constants.

### 5. Not changed

Lobe selection, NEE (light selection, portal split, env CDF), the miss
stage, emissive MIS, roulette, clamps on the image, the video and real-time
routes, the fixture emission follow-up, OIDN.

## Gate: `pt_guiding_gate` (new; suite goes to 24)

`pipeline_references/tests/pt_guiding_gate.gd` + `_scene.tscn`, the pt_*_gate
pattern (`PTValidation._render_accum`, PFM readback, constants for
tolerances). Scene: a closed Lambertian box (albedo linear 0.5, authored
`linear_to_srgb`), one window opening in a wall, no pane, a
`DirectionalLight3D` at 45° elevation aimed through the opening so its patch
lands on the floor, a `WorldEnvironment` with a uniform sky, camera on the
opposite wall looking at a wall the patch lights only by bounce. Project AA
off (the gates-inherit-project-AA memory). `guiding_probability` is set by
the gate through `ProjectSettings` before each render.

| # | check | fixture | bar |
|---|---|---|---|
| G0 unbiased | wall-crop mean, 1024 frames, guiding 0 vs 0.5 | above | equal within 1%, after measuring the 1024-frame repeat floor on this build with `ZR_SEED_OFFSET` |
| G1 variance | wall grain (5×5 residual RMS / mean), 256 frames | above | guided ≤ 0.5 × unguided; unguided printed as control |
| G2 repeatable | two guided 256-frame renders | above | md5-identical PFMs |
| G3 instrument | `RT_VIS_GUIDE_CELL` on the wall crop after 16 frames | above | mean R ≥ 32/256, mean G > 0 |
| G4 inert | `pt_energy_gate` scene, guiding 0, this binary vs pre-change | existing | md5-identical (`combinedPdf`'s hook must be exactly inert when off) |
| G5 cost | wall time per frame, guiding 0.5 vs 0, 256 frames, FHD | above | ≤ +25% |

G0 is the gate that can newly fail: a wrong density (a hemisphere mismatch
between the CDF and the pdf, a stale snapshot, a lobe-weight shortcut)
shows as bias here, not as grain. G1 is the reason the work exists. G4 is
the guard for every other gate in the suite.

## Production acceptance

Jobs **226, 227, 157** re-rendered on the live pipeline at 4K / 256 frames
with `guiding_probability` 0.5, measured with the daylight spec's own
instrument (`tools/daylight_validation.py`) on its hand-verified wall crops:

- pre-denoise wall grain **≤ 10%** on all three (from 12.82 / 16.39 /
  14.29);
- render time ≤ 1.25 × the job's logged `total_duration_seconds`;
- the post-OIDN PNG inspected by eye on the pendant/ceiling crop of 226 and
  the wall crops, before/after side by side;
- **control:** adaptive sampling (`pathtracing_noise_threshold` 0.01,
  guiding 0) on job 227 once, its grain and time recorded next to
  guiding's in the closeout — the roadmap's step 2, measured rather than
  argued.

## Risks, recorded

- **Bin coarseness** (11°): a sun patch is one bin among 64; the win is
  bounded by how much of the bin the patch fills. If G1 passes but
  production misses 10%, the next lever is 16×16 bins (4× memory, same
  code), before any parametric fit.
- **Table saturation**: a bin whose fixed-point sum would exceed 2^32 stops
  learning (the add is skipped). With `L/p` adds that is ~4 M adds at
  `L/p = 1`; a cell in front of a window at 4K sees ~1e5 samples per bin.
  Watch `RT_VIS_GUIDE_CELL`'s count channel on the four jobs; if it
  saturates, the fallback is a halving pass in a compute snapshot shader.
- **Hash collisions** at 2^18 cells: a 10 m room at 16 cm cells × 6 normal
  keys is ~1.5 M possible keys but only surfaces occupy cells; measured
  occupancy goes in the closeout. If collisions matter, the fix is a
  larger table, not chaining.
- **Snapshot copy** 68 MB per frame: ~0.1 ms on PCIe-resident device
  memory; counted in G5.
- **Register pressure** in raygen from the 4-vertex record (48 floats):
  watched via G5; if it spills, the record shrinks to 2 vertices (the first
  two diffuse bounces carry most of the energy on these rooms).

## Out of scope (recorded)

Glossy guiding (Cycles guides roughness above a threshold), NEE/light
guiding, guiding on the video and real-time routes, Open PGL parity, the
night many-light fixture and ReSTIR (§11.28 steps 1 and 3 — a second spec
if the night rig's ceiling grain is still a complaint after this).


## Measured (2026-09-24) — built, correct, and aimed at the wrong term

The guide was implemented through Task 4 of
`docs/superpowers/plans/2026-09-22-path-guiding.md` and is **shipped
default-off** (`rendering/pathtracer/guiding_probability` defaults to 0.0).
Working notes for every number below are in
`.superpowers/sdd/2026-09-22-path-guiding/`.

### The gate

| check | result |
|---|---|
| G0 unbiased, 1024 frames, guiding 0 vs 0.5 | **PASS, +0.13%** — the sampled density and the reported density are one function |
| G2 repeatable | PASS |
| G3 instrument (vis 45) | PASS, cell count 2101.9 against a bar of 32 |
| G1 variance, guided ≤ 0.5× unguided | **FAIL, 1.098×** |
| G5 cost ≤ 1.25× | **FAIL, 1.305×** (1.59× excluding a fixed settle) |
| G4 inert at probability 0 | FAIL at 3.7e-9 — making `g_guide` runtime-variable stops constant folding and changes FMA contraction, 2 ULP on 1.3% of pixels; frame mean unchanged to 8 dp |

An α sweep at 0.2 / 0.5 / 0.8 gave 0.1346 / 0.1288 / 0.1244 against 0.1173
unguided: worse at every setting, so no knob rescues G1. The bar was not
touched.

### Why G1 failed: the premise was reasoned, not measured

"The complaint" above asserts the noise source is the indirect diffuse term
and that ReSTIR "does not apply here". Both claims were derived from the
roadmap rather than measured. Decomposed on job 227 (FHD, 256 frames,
guiding off, wall crop):

| variant | grain | wall mean |
|---|---|---|
| full, 12 bounces | 16.47% | 0.1592 |
| direct only | 19.92% | 0.1224 |
| direct + 1 bounce | 17.75% | 0.1435 |

**Direct lighting carries 86.4% of the variance.** All indirect is 13.6%, of
which the first bounce alone is 7.9 — so bounces 2+, the only region a path
guide touches, are worth **5.75% of total variance**. A *perfect* guide
therefore multiplies noise by √(1 − 0.0575) = 0.971: 16.47% → 15.99%. The
≤10% target was never reachable through guiding, and guiding's measured ~1%
improvement on the real job is a correct implementation skimming a nearly
empty pool, not a weak one.

Narrowing further, on the same job: **sky only (sun off) reads 9.33%**
(variance ratio 0.304, passing the bar); **sun only (sky off) reads 16.52%**
(ratio 0.999). Light portals fire correctly — two reach the shader with
correct pose, verified with a temporary print at the line setting
`RT_PARAM_PORTAL_COUNT` — and are worth nothing on this crop (16.4733% vs
16.4779% on/off). So the direct variance is the sun's shadow sampling at the
partially-occluded window. Setting the sun's `light_angular_distance` to the
physical 0.53° instead of the rig's 0.8° changes nothing measurable: 8.2049%
vs 8.2070% on the corrected crop, ratio 1.0007, within run-to-run noise.

### What the crops were actually measuring

Job 227's noise converges cleanly (16.47% → 9.55% → 6.96% at 256 → 1024 →
4096 frames), so it is genuine Monte Carlo noise, not a converged gradient.
But the falloff decelerates (1.726×, then 1.371×, against 2.0× for pure
noise), and the reason is that **12% of its "hand-verified flat wall" crop is
ceiling containing a recessed IES downlight**, whose edge barely converges
(49.0% → 45.3% across a 16× sample increase) and pins the whole crop's floor
near 5.7%. On a clean crop of the same wall the same renders read 8.20% /
3.98% / 2.00%, falling 2.062× then 1.993× with a fitted floor of **0.00%**.

Job 227 passes the bar at production settings and always did. Audited the
other two RED jobs: 226 is mildly contaminated (a ceiling-corner shadow
gradient) and still fails at 11.47%; 157 is contaminated (a picture frame's
dark wood edge) and still fails at 14.93% — slightly worse once cleaned,
because that wall is dim and genuinely noisy. Corrections are recorded in
`2026-09-19-daylight-design.md` Findings (6).

**Tally: of the three RED readings that justified this gap, one was a
measurement artifact and two hold up.** The gap is partly justified, not void.

### Then measured on the jobs that actually fail — and 227 was the outlier

Everything above was measured on job 227. Decomposing the two jobs whose RED
readings survived the crop audit reversed the picture:

| job | Var_direct | Var_indirect | bounce-2+ (guiding's reach) |
|---|---|---|---|
| 227 | **86.4%** | 13.6% | 5.75% |
| 226 | 37.4% | **62.6%** | **35.9%** |
| 157 | (see note) | majority | **≥51.9%** |

Job 157's direct-only variant failed its own sanity check — the log reads
`exposure 50.000 CLAMPED — scene is not a lit interior` and the
occupied-median gate went RED, so a windowless room cannot be exposed under a
1-bounce cap; its figure comes from the full-vs-(direct+1) comparison, which
does not use that variant.

So **227 is the outlier, and it is the one job that was not actually
failing.** On the two that do fail, indirect carries the majority of the
variance and guiding's addressable pool is 6–9× larger than what the earlier
sections measured it against.

### What the guide actually buys (A/B, same resolution, frame count and bounce settings)

| job | grain off → on | variance | time | vs spending the same time on samples |
|---|---|---|---|---|
| 226 | 11.61% → **10.77%** | −13.9% | +4.0% | **1.12× more efficient** |
| 157 | 16.02% → **14.00%** | −23.6% | +25.1% | 1.05× — break-even |
| 227 | 16.47% → 16.33% | −1.7% | +18.4% | **0.86× — a net loss** |

Crop means move by under 0.1% in every case, consistent with G0. Determinism
was verified rather than assumed: a repeat of 226-off came back
byte-for-byte identical, so these deltas are switch effects, not run-to-run
noise (single seed per configuration, not an ensemble). Capture efficiency
was 38% and 43% of the addressable bounce-2+ pool, against ~30% on 227.

**Neither failing job reaches the bar**: 226 goes from 1.61 points over to
0.77 over, 157 from 6.02 over to 4.00 over. Even a perfect guide would only
just clear 226 (9.3%) and would not clear 157 (11.1%).

### Conclusion, and why the default stays 0.0

The guide is correct and does what it was designed to do. It is not a fix for
this gate on its own, and its value **flips sign with the scene's
direct/indirect balance** — a blanket enable would make direct-dominated
jobs like 227 measurably worse for an 18% time cost. So
`rendering/pathtracer/guiding_probability` stays at 0.0 and the plan's Task 5
(turn it on for every still) is deliberately not executed.

Turning it on is defensible per-scene, or behind a cheap classifier of the
direct/indirect balance — but that classifier does not exist, and inventing
one from three data points would repeat this gap's original mistake.

### Still not measured

- The convergence check (does grain fall 2× per 4× samples, or hit a floor)
  has been run only on 227. Neither 226 nor 157 has a second frame-count
  render, so neither has been shown to be noise-limited rather than
  structure-limited on its corrected crop.
- Whether the remaining gap on 226/157 is reachable at all: closing 157 needs
  a further ~2× variance reduction beyond guiding, and nothing measured here
  says where that would come from.
