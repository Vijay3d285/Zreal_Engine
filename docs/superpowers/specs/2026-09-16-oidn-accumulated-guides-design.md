# OIDN guides accumulated like the colour — no more blur with distance

**Date:** 2026-09-16
**Status:** for review
**Branch:** `vijay_PTEngine_v23_PhaseE3`

## The complaint

Job 224 (first 4K still on the Phase A route, OIDN final) is sharp near the
camera and increasingly blurred with distance: the far picture frame's print is
smeared into a painting while the near sideboard's wood grain survives. Job
223 (DLSS-RR route) and Blender's OIDN-denoised stills do not do this.

## Root cause

`_oidn_final_denoise_accumulator` (`render_forward_clustered.cpp:1928`) gives
OIDN:

- **colour** = `rt_accum`, the 256-frame running mean, every sample at its own
  Blackman-Harris pixel-filter jitter (float);
- **albedo, normal** = `RB_TEX_DLSS_RR_DIFFUSE_ALBEDO` / `_NORMAL_ROUGHNESS` —
  the DLSS-RR G-buffers: **the last frame's single primary sample**, at that
  frame's jitter, quantised to R8G8B8A8.

A denoiser guided by albedo keeps colour detail the albedo explains and
removes what it does not. Where a texture is coarse per pixel (near), a point
sample and a filtered mean agree. Where it is fine per pixel (far), they
disagree at every pixel, and OIDN removes the "unexplained" detail. That is
blur proportional to texture frequency per pixel, i.e. to distance. The DLSS
route is immune because DLSS-RR is designed for point-sampled guides.

`modules/raycaster_oidn/oidn_denoiser.cpp:99-113` already records the symptom
("aliased guide … OIDN over-smoothed the colour, flattening the TV panel
fabric") and mitigates it with `cleanAux = false`, OIDN's quick joint
prefilter; that softens the effect and cannot remove it. The comment also
still says the primary ray is un-jittered, which stopped being true when Phase
A got its pixel filter.

## What Cycles does (the reference)

`intern/cycles/kernel/film/denoising_passes.h:150-163`: the denoising normal
and albedo are written with `film_write_pass_float3` / `_spectrum` — an
**atomic accumulation over every sample**, each at its pixel-filter jitter,
divided by the sample count at output. The guides are therefore the same
filtered average as the colour, in float.

`intern/cycles/integrator/denoiser_oidn_gpu.cpp:302-376` and
`blender/addon/properties.py:426`: default prefilter **ACCURATE** — the albedo
and normal are each run through OIDN's own RT filter (albedo-only / normal-only
inputs) before the colour pass, and the colour pass then runs with
`cleanAux = true`.

## Design

### 1. Accumulate the guides (engine, raygen + buffers)

Two new per-viewport textures beside `rt_accum` / `rt_variance`
(`render_forward_clustered.cpp:127-150`, `render_raytracing.h`):

- `RB_TEX_RAYTRACING_ACCUM_ALBEDO` (`"rt_accum_albedo"`, R16G16B16A16_SFLOAT)
- `RB_TEX_RAYTRACING_ACCUM_NORMAL` (`"rt_accum_normal"`, R16G16B16A16_SFLOAT)

Bound in the RT uniform set at the next free bindings (34, 35 — `rt_variance`
is 33), declared in `scene_raytracing_raygen.glsl` beside `rt_accum`. Cleared
to zero wherever `rt_accum` is cleared on an accumulation reset
(`render_forward_clustered.cpp:2877`).

In the raygen accumulate branch, after `trace_one_sample` (which, with
`p_is_sample_zero = true`, has just made the hit/miss shader write this frame's
primary albedo and normal into `dlss_rr_diffuse_albedo` /
`dlss_rr_normal_roughness` at this pixel), read those two texels back and blend
them into the new textures with the **same running weight `w`** the colour
uses. Guides and colour then share every sample and every jitter, exactly as
Cycles' passes do. Cost: two `imageLoad` + two `imageStore` per accumulated
sample.

The G-buffer writes are under `#ifdef DLSS_RR_ENABLED`; the C++ already forces
`RT_FLAG_DLSS_RR_ENABLED` when OIDN is active (`render_forward_clustered.cpp:
~2458`, "under forced RT_FLAG_DLSS_RR_ENABLED"). The plan verifies that gate
and the accumulate branch's `#ifdef` guard match.

### 2. Feed OIDN the accumulated guides, Cycles' ACCURATE way (engine, C++)

`_oidn_final_denoise_accumulator`:

- albedo ← `rt_accum_albedo` (RGB, float), normal ← `rt_accum_normal` (RGB,
  re-normalised per pixel; an averaged normal is shorter than 1, and OIDN wants
  unit normals — Cycles' pass is also renormalised on read). The R8 DLSS-RR
  G-buffers are no longer read here; they stay what DLSS-RR needs.
- `OIDNDenoiser` gains the ACCURATE prefilter: before the colour filter, run an
  RT filter with **only** `albedo` as input and output (in place), and another
  with only `normal`, then the colour filter with `cleanAux = true`. This is
  `denoiser_oidn_gpu.cpp`'s sequence.
- The `oidn_denoiser.cpp` comment block is rewritten to say what the guides now
  are and why `cleanAux` is true.

Video and the realtime DLSS-RR route: unchanged (they never call this).

### 3. Gate: `pt_oidn_guide_gate`

One quad fills the 256×256 frame, textured 1:1 with a checker: **period 4 px
on the left half, period 32 px on the right**; uniform white sky, one bounce
(a furnace, so the raw 256-frame accumulation is the pixel-filtered checker
with no noise), OIDN final on, `use_hdr_2d` so the viewport image is linear.
Detail retention = std-dev of OIDN's output over a region ÷ std-dev of the raw
accumulation over it. The mechanism is texture frequency *per pixel*, not
distance, so fine-vs-coarse on one quad is the near/far difference of job 224
without a second quad.

- **G1 fine**: retention on the period-4 half ≥ **0.85**.
- **G2 coarse**: retention on the period-32 half ≥ **0.85**.
- **G3 parity**: |G1 − G2| ≤ **0.10** — "no blur that grows with texture
  frequency", which is what blur with distance is.

On the build before this change: G1 **0.0836**, G2 0.9877 — red on G1 and G3.
The thresholds are confirmed against three runs of the fixed build.

### 4. Asset check

Job 217 at FHD, Phase A route, before/after; then job 224's scene at 4K by the
user. Measure: variance of Laplacian on the far picture's print and on the near
sideboard's grain, before/after, and the same on the Blender still for the
like-for-like line. Whole-frame mean within 0.5% (a guide change must not shift
exposure).

## Out of scope

- OIDN's `quality` (Cycles default BALANCED for final) — our wrapper uses the
  library default; not changed here.
- Cycles' `denoising_depth` guide and "follow reflections" feature deferral —
  OIDN's RT filter does not take depth; deferral is a later refinement.
- DLSS-RR guides: unchanged, by design.

## Deviations from Cycles, on record

- Cycles accumulates guides in float32 passes; ours are RGBA16F running means
  (the colour accumulator is 32F). Albedo in [0,1] and a unit normal are well
  inside half precision; the running-mean update at n = 256 has a weight of
  1/257, which half precision represents (2⁻¹¹ resolution near 1.0 → error
  ≤ 0.05% per step, non-accumulating because each step rewrites from the
  stored mean). If the gate's G1 shows it, the format goes to 32F.
- Cycles' albedo pass is the *diffuse closure* albedo with feature deferral
  through specular surfaces; ours is the DLSS-RR diffuse-albedo output at the
  primary hit. Same quantity on the diffuse surfaces this defect is about.
