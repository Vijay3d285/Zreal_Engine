# Still route and pixel filter — matching Blender's edge quality

**Date:** 2026-09-16
**Status:** approved for planning
**Branch:** `vijay_PTEngine_v23_PhaseE3` (or its successor)

## The complaint

A Blender 4K still zoomed 400× keeps clean, ramped edges. Ours zoomed 200× shows
zig-zag borders on sharp edges and the pixel structure breaks up. Measured on
comparable chair-leg-over-floor edges (10–90% luminance ramp across the edge):

| | Blender 4K (`blender_renders/blender_dining.png`) | ours 4K (job 223, production route) |
|---|---|---|
| ramp width | 3.6 px | 1.0 px |
| checkerboard on flat walls (Nyquist share of a 128² patch) | 0.00% | 0.12% |

A one-pixel ramp is a staircase; that is the zig-zag.

## Root cause (investigated, not inferred)

The same job 217 rendered at FHD two ways from the same build:

| route | ramp (mean over ~950 edges) | hard-step edges (ramp 0) | wall checker |
|---|---|---|---|
| production: 3 spp/frame → DLSS Ray Reconstruction, 256 frames, NIS sharpen 0.1 | 1.35 px | 270 | yes |
| same, NIS sharpen off | 1.50 px | 124 | yes |
| same, jitter sign negated | ~same | ~same | yes |
| same, jitter reported as zero | ~same | ~same | worse (×2) |
| same, 64 jitter phases instead of 8 | 1.82 px (HD) | ~same | slightly less |
| Phase A: accumulate 256 × 1 spp through the Blackman-Harris pixel filter, OIDN final | 1.76 px | 109 | none |

Conclusions:

1. **The staircase and the checkerboard are produced inside DLSS-RR's
   reconstruction.** No input-side knob (sharpener, jitter convention, phase
   count) removes them. DLSS-RR is a real-time neural denoiser: it never
   converges to the pixel-filtered image, however many frames it is fed.
   Cycles' still pipeline is *accumulate N samples through a pixel filter,
   then OIDN* — which is our Phase A route, and Phase A already measures clean.
2. **Godot's default `fsr_sharpness = 0.2` runs an NIS sharpen (0.1) after
   DLSS** (`dlss.cpp:538`). It doubles the hard-step count on a still.
3. **Our pixel filter is half a pixel too narrow.** `camera_filter_jitter`
   (`raytracing_inc.glsl`) implements Cycles' Blackman-Harris importance
   sampling but its comment assumed "Cycles' default filter_width of 1.0".
   Cycles' default is **1.5** (`intern/cycles/blender/addon/properties.py`,
   `filter_width ... default=1.5`), widened ×2 in `film.cpp: filter_table()`,
   so samples land within ±1.5 px of the pixel centre; ours land within ±1.0.

   Analytic edge ramp of the filter alone (edge-spread = filter CDF):

   | width | 10–90% ramp | 5–95% | half the samples within |
   |---|---|---|---|
   | 1.0 (ours) | 0.721 px | 0.914 px | ±0.192 px |
   | 1.5 (Cycles) | 1.081 px | 1.372 px | ±0.288 px |

   Blender's measured 3.6 px is the filter *plus* OIDN's softening *plus* a
   shaded cylinder's own gradient; the like-for-like target after this change
   is "Phase A + 1.5 + OIDN reads the same as Blender on a hard, flat edge",
   measured on both renders, not the 3.6 number.

## Design

Three changes, independent, all small.

### 1. Phase A becomes the production still route (pipeline)

`pipeline_references/image_glb_creation.gd` (the user's file; edited as a
reference copy, carried to the live project by the user):

- `const PHASE_A_OFFLINE_STILL := true`
- `const PHASE_A_ACCUM_TARGET := 256` — Cycles' sample count on the Blender
  reference (`cycles.ViewLayer.samples = 256`). Noise ∝ 1/√N; 512 is the next
  stop if a dark scene is grainy, at double the time.
- `const PHASE_A_FINAL := "oidn"` — Blender's stills are OIDN-denoised by
  default; the Phase A measurement above used it.
- `PHASE_A_CLAMP_INDIRECT` and `PHASE_A_NOISE_THRESHOLD` stay 0 (pure
  estimator; the known clamp asymmetry in the file's comment stays inert).
- The route select becomes `PHASE_A_OFFLINE_STILL or ZR_PHASE_A == "1"`. Today
  it is `and`, so the constant alone does nothing, contradicting the "flip this
  one line" comment above it. The comment is corrected to match.
- Video (`video_glb_creation.gd`, `video_render.gd`) is untouched: DLSS-RR
  stays the realtime integrator there.

`render.gd` already handles the rest of the route: BILINEAR viewport (no
projection jitter to double up with the pixel filter), `_wait_frames(target +
1)` for the OIDN pass, 16-bit RGBA PNG from the linear HDR buffer.

Time: Phase A at FHD took 174 s against 379 s for the DLSS-RR route on the same
job (2026-09-13). 4K is 4× the pixels — ≈ 12 min against `main.py`'s
`TIMEOUT = 1500` s. Recorded in the plan as a measurement to take on the first
4K run; if it is above ~20 min the target drops, not the timeout.

### 2. Pixel filter width 1.5 (engine)

`servers/rendering/renderer_rd/shaders/raytracing/raytracing_inc.glsl`:

- `const float RT_PIXEL_FILTER_WIDTH = 1.5;` next to the table, with the
  Cycles citation (`properties.py` default, `film.cpp` ×2 widening).
- `bh_filter_1d(u)` returns `sign(s) * bh_inv_cdf_half(abs(s)) *
  RT_PIXEL_FILTER_WIDTH`. The table is the inverse CDF of the half-profile on a
  normalised radius, so the window scales linearly; the shape is unchanged.
- The block comment's "default filter_width of 1.0 … offsets span ±1 pixel" is
  rewritten to state 1.5 and ±1.5, and the sentence claiming a tent filter has
  "the same radius" is dropped (it no longer does).

Applies to every caller: the accumulate route and samples 1..N-1 of the
one-shot loop. Sample 0 stays centred (G-buffer alignment, Cycles parity).
The realtime DLSS-RR route sees a slightly wider intra-frame spread; it is a
denoiser input and is not gated on this.

### 3. No sharpener on stills (pipeline)

`render.gd`, in the viewport setup beside `scaling_3d_scale = 1.0`:
`get_viewport().fsr_sharpness = 0.0` with a comment naming `dlss.cpp`'s NIS
pass and the measurement (hard-step edges 270 → 124 on job 217). Belt and
braces: under Phase A the DLSS branch does not run, but the constant is a
Godot default that would bite the moment anyone flips the route back.

## Gate: `pt_pixel_filter_gate`

New gate, `pipeline_references/tests/pt_pixel_filter_gate.gd` + `_scene.tscn`,
extending `pt_validation.gd` like the others.

Scene: an orthographic camera, `size = 2.0` at 256×256 (1 px = 2/256 world
units), looking at a flat black quad (albedo 0, max bounces 1) whose right
edge sits **on a pixel centre** — half a pixel past a pixel boundary — against
a white sky of radiance 1.
Accumulate 256 frames (`_render_accum`). The gate reads the horizontal
luminance profile through the edge, averaged over 200 rows, and derives:

- **F1 ramp width**: 10–90% width in pixels. Expected `1.081 ± 0.08` (the
  analytic CDF of the 1.5-wide window, sampled at pixel centres, ±0.08 for the
  pixel-centre quantisation and 256-sample noise). The current build reads
  `0.72` — the gate is red before the change and green after (falsifiable).
- **F2 symmetry**: the profile's 25% and 75% crossings are equidistant from
  the 50% crossing within 0.05 px (the filter is symmetric; a sign or offset
  bug in `bh_filter_1d` shows here).
- **F3 mean preservation**: the mean of the whole image equals the black
  quad's area fraction within 0.2% — a wider filter must not lose or gain
  energy (every sample still lands in its own pixel).

The exact expected numbers are computed in the plan by the same Python that
produced the table above, and the tolerance justified by running the gate
three times on the fixed build.

## Asset check

Job 217 at FHD, Phase A route, before (width 1.0) and after (width 1.5): the
edge-ramp statistic used in the investigation, plus the chair-leg crop. Then
one 4K run of a current job through the new production route by the user, with
its wall time read from the Godot log against the 1500 s timeout, and a
like-for-like edge crop against the Blender still (picture-frame edge, both
images).

## Out of scope

- Blender's other filter types (Box, Gaussian): not exposed, not needed.
- Making DLSS-RR converge: it cannot; it remains the video integrator.
- The checkerboard's exact mechanism inside DLSS-RR: recorded in the roadmap
  as observed (jitter-zero doubles it, 64 phases reduce it), not pursued.
- Adaptive sampling / clamp defaults for Phase A: unchanged (0/0).

## Deviations from Cycles, on record

- Cycles' `filter_table` has `FILTER_TABLE_SIZE = 256` entries; ours has 33
  with linear interpolation. The sampled distribution differs at the 1e-3
  level; the ramp gate's tolerance covers it. Not changed here.
- OIDN's edge softening differs between Blender's OIDN version and ours; not
  modelled, measured like-for-like instead.
