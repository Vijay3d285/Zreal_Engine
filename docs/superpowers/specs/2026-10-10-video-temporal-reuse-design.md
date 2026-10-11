# Video temporal reuse: blend each frame with the previous frames before OIDN

**Date:** 2026-10-10. **Status:** built and measured; CLOSED by the owner 2026-10-11 -- the pass
stays in the engine switched off (setting 0, byte-identical), the video route does not turn it on. See
"Outcome" at the end. **Scope:** engine
(one new compute pass in the path tracer's OIDN final-denoise step, history textures, two
project settings, a per-frame sample offset) and the video route (`video_glb_creation.gd`
turns it on). Stills unchanged. **Evidence and raw numbers:**
`.superpowers/sdd/2026-10-08-video-parity/results.md` ("Flicker root cause", "Fix candidates",
"Cycles adaptive sampling port").

## The goal

The video route now matches the still route's look (2026-10-08 changes: fixture model,
texture cap, active-room culling), but the owner sees slight flicker noise when the camera
moves. Remove it without adding render time.

## What causes the flicker (measured, job 210, keyframes 204-215, 4K, 24 spp)

- Not the seed: every delivered frame restarts the same per-pixel Sobol sequence, which is
  Cycles' default (`use_animated_seed` False). Not the debanding dither (static), not the
  encode (MP4 flicker 0.53 vs PNG 0.57 levels), not brightness (mean luma equal to 128 spp).
- Against a 128-spp render of the same frames, the 24-spp frames change by 0.97 levels mean
  (8-bit luma) more than the reference from frame to frame: 1.84 on edges and textured
  pixels, 1.25 dark, 0.80 flat, 0.71 bright; 86% of it finer than 9 px. Edges and fine detail
  (frame and furniture outlines, mullions, foliage, the bouquet, glossy vase and table,
  leather, rug) slide over a fixed 24-sample pattern as the camera moves; OIDN keeps it,
  because its albedo/normal guides say the detail is real.
- More samples work but cost linearly (~1.5 s per sample per 4K frame): 48 flat = 0.74 at
  77.2 s/frame, against 0.97 at 41.4 s. Cycles' adaptive sampling, ported and verified
  (commit 9743d7a527, off by default), gives no gain per unit time here: one raygen dispatch
  covers every pixel, so a few active pixels keep most of the GPU busy.

## Owner decisions (brainstorm 2026-10-10)

1. **Reuse previous frames** (over more samples or keeping 24 spp).
2. **Lean against trails:** reject reused samples aggressively; give up some flicker
   reduction on reflective surfaces rather than show trails.
3. **Less flicker at the same time:** stay at 24 spp; the reuse must not add render time.
4. **Approach A** (blend at the end of each frame, before OIDN) over B (seed the
   accumulator at the start of the frame; no current-frame neighbourhood to clamp against)
   and C (filter after OIDN; carries the denoiser's own blotches and needs exported depth).

## Design

### Where it runs

Once per delivered frame, in the OIDN final-denoise step of the accumulate route
(`render_forward_clustered.cpp`, where `[OIDN-DIAG] FIRE` is logged), after the frame's
samples are complete and before the denoiser reads the accumulator. A compute pass blends
the frame's accumulated radiance (`rt_accum`, the 24-sample mean) with the previous frame's
blended radiance (history), writes the blend back into `rt_accum` for OIDN, and stores it as
the next frame's history. The OIDN guides (accumulated albedo and normal) are not blended:
they are the current frame's own, nearly noise-free after 24 samples.

### Per pixel

1. **Reproject.** Rebuild the world position from the current frame's `rt_depth` (NDC depth
   of the primary hit) and its inverse view-projection; project it with the previous delivered
   frame's view-projection to a previous-frame UV. A pixel with no hit (depth 0: sky, the view
   through a window) reprojects by direction, as the path tracer's sky velocity does
   (`scene_raytracing_raygen.glsl`, miss branch), and accepts history only where the history
   is also a miss.
2. **Reject** the history when:
   - the previous UV is off-screen;
   - **depth:** the history's world position (rebuilt from the history depth at that UV with
     the previous inverse view-projection) is more than 2% of the camera distance away from
     the current one;
   - **normal:** the dot of the current and history normals (the accumulated normal guide,
     world space) is under 0.9.
   Depth and normal are read nearest-texel; the radiance is read with a 5-tap Catmull-Rom
   filter, so repeated resampling does not soften texture.
3. **Clamp** the surviving history to the current frame's 3x3 neighbourhood: mean +/- gamma *
   standard deviation, per channel. The box and the clip are computed in YCoCg of the
   exposure-scaled radiance compressed by x/(1+x), and the clipped history is mapped back to
   linear radiance. gamma is a project setting (default 1.0, tight). This stops trails from
   glossy reflections and glass, where the surface does not move but what it shows does.
4. **Blend** in linear radiance by sample count: h = min(history count, cap); out =
   (24 * current + h * history) / (24 + h). The count stored with the blend is min(24 + h,
   cap). A rejected pixel has h = 0 and is exactly today's frame. Counts run 0, 24, 48, 48...,
   so from the third frame on a pixel holds 24 + cap samples (72 at the default cap of 48)
   and the history carries cap / (24 + cap) = 2/3 of the weight: content the clamp lets
   through decays to under 10% in 6 frames (0.1 s at 60 fps). The clamp, not the decay, is
   what stops trails.

### New samples every frame

With the reuse on, each delivered frame continues the sample sequence instead of restarting
it: the accumulate route's sample index becomes accum_frame + (frames denoised so far) *
target (+ the existing ZR_SEED_OFFSET), so frame k traces Sobol points k*24 .. k*24+23 and its
pixel-filter jitter lands in new places. That is what lets an edge converge across frames
instead of crawling. The adaptive-sampling schedule (`RT_PARAM_ADAPTIVE_SAMPLE`) keeps the
unshifted index.

### Controls and lifecycle

- `rendering/pathtracer/temporal_history_samples` (int, default 0 = off): the cap. The video
  route sets 48 for Phase A with OIDN; stills never set it.
- `rendering/pathtracer/temporal_clamp_gamma` (float, default 1.0): the clamp width.
- History (radiance + count, depth, normal) and the previous delivered frame's view-projection
  live in the viewport's path-tracer state (`RTViewportState`), separate from the accumulator:
  the video route resets the accumulator every frame by toggling accumulation off and on, and
  that must not touch the history.
- The history is invalid on the first denoise, after a viewport resize, and whenever the
  setting is 0. Anything unexpected (missing texture, size mismatch) means "no history": the
  frame is today's frame.
- Camera cuts need no special case: a jump fails the depth/normal tests everywhere.
- The pass runs only where OIDN fires, so the daylight probe's offscreen viewport (raw
  accumulator, no OIDN) never uses it; confirmed from the logs during verification.

### Known limitation

Production splits clips longer than `VIDEO_RENDER_MAX_CHUNK_SECONDS` (10 s) into chunks, each
a fresh Godot process whose pre-roll shows the chunk's first pose. Each chunk therefore starts
with no history and ramps over two frames from 24 to 72 samples. A 7-s clip is one chunk.
Rendering two overlap frames per chunk in `main.py` would remove the ramp; out of scope here.

## Verification and success criteria

All on job 210 at 4K with the 2026-10-08 pipeline (new culling, fixture model, texture cap).

1. **Off changes nothing:** setting 0, new binary vs the current one: byte-identical frames on
   the static keyframe-210 job and on the moving segment 204-215.
2. **Reproducible:** two renders with the reuse on are byte-identical.
3. **Less flicker, same time** (segment 204-215, 24 spp, `noise_decomp.py` against the
   128-spp reference `seg_new128`): noise change <= 0.65 overall (today 0.97) and <= 1.1 on
   edges (today 1.84); seconds per delivered frame <= 43.5 (today 41.4, +5%).
4. **No trails:** per-frame error against the reference drops overall; no pixel class (edges,
   dark, flat, bright) gets worse; the worst 0.1% of per-pixel errors is no higher than
   today's. Repeated on the 12 consecutive keyframes of job 210 where the camera moves most,
   with their own 128-spp reference.
5. **By eye:** side-by-side clips (today vs reuse) of both segments, and close crops of the
   glossy table and vase, the window edges, and an edge the camera uncovers.

If 4 fails at cap 48 / gamma 1.0, lower the cap or tighten gamma, re-measure, and show the
owner the trade-off before anything ships.

## Out of scope

- Overlap frames at chunk boundaries (main.py).
- Blending the OIDN guides, motion of objects (the scenes are static), DLSS-RR.
- Stills.

## Amendment 2026-10-11 (owner): stabilise after OIDN, not before

**Why.** The design above (blend before OIDN) was built and measured on job 210 (Task 4 of
`docs/superpowers/plans/2026-10-10-video-temporal-reuse.md`; numbers in
`.superpowers/sdd/2026-10-10-video-temporal-reuse/progress.md`). With a static camera it now
delivers exactly the 48-sample result, but with the camera moving it lost to today's 24 spp on
every measure, in three variants: noise change 1.36-2.10 vs 1.08, error vs an independent
128-spp reference 2.69-3.18 vs 2.08. Causes found: (1) any clip or symmetric outlier test on
24-spp radiance is biased by the skewed Monte Carlo noise (darkened dark areas by 1-1.5 levels
and discarded the history); (2) today's fixed per-pixel sample pattern makes the 24-spp error
temporally coherent, and advancing the pattern per frame plus resampling noisy history broke that
(correlated noise that OIDN keeps). The owner chose to move the reuse after the denoiser.

**Design.** Same pass, same history bookkeeping, moved:
- Runs once per delivered frame right after OIDN has written the denoised colour into the RT
  colour texture (`RB_TEX_RAYTRACING`, RGBA16F), before `copy_output_texture` shows it. Input:
  the denoised frame, `rt_depth`, the accumulated normal and albedo guides. History: the previous
  stabilised frame (RGBA16F) with its depth, normal (+ sample count) and albedo.
- The sample pattern stays fixed (no per-frame Sobol offset): the coherence of today's error is
  kept.
- Rejections against the current 3x3 neighbourhood as built in Task 4: depth range (+/- 2%),
  best-matching normal (dot >= 0.9), albedo-guide range (+/- 0.05), miss-to-miss. Then a
  variance clip of the history to the current 3x3 in YCoCg of x/(1+x)-compressed exposure-scaled
  colour, `rendering/pathtracer/temporal_clamp_gamma` (default 1.25): on denoised input the
  neighbourhood is clean, which is the regime this clip is designed for.
- Blend by sample count as before (cap 48 -> history weight up to 2/3); the result is copied
  into the RT colour texture for display and kept as the next history.
- The debug mask goes to its own texture (copied for display instead of the blend); the history
  always holds the real blend.
- Off (cap 0): the pass does not run, and nothing else changes: byte-identical.

**Success criteria (replace criterion 3; 1, 2, 4, 5 stand).** Against the independent reference
`ref128_ind` (128 spp, ZR_SEED_OFFSET=1000000), segment 204-215, 24 spp: noise change <= 0.72
overall and <= 1.24 on edges (today 1.08 / 2.07: the same -33% / -40% as the original targets),
error per frame <= today's 2.08, brightness bias per band within today's +/- 0.3 levels, and
<= 43.5 s per delivered frame.

## Outcome 2026-10-11 (owner): closed, keep 24 spp

The post-OIDN pass was built as amended (19 doctest cases, mutation-checked) and measured on job 210,
keyframes 204-215, 24 spp, against `ref128_ind`. Off (setting 0): static 5/5 and moving 12/12 frames
byte-identical to the production binary, no `[PT-TEMPORAL]` lines, no shader errors. On (cap 48):

| run | noise / edges | error | s/frame | fine detail (HF) |
|---|---|---|---|---|
| today (24 spp) | 1.08 / 2.07 | 2.08 | 41.4 | 1.163 |
| reuse, gamma 1.25 | 1.08 / 2.18 | 2.34 | 41.3 | 1.046 (-10%) |
| reuse, gamma 3 | 1.07 / 2.21 | 2.50 | -- | -- |
| reuse, no clip | 1.10 / 2.33 | 2.94 | -- | 1.097 |
| flat 48 spp | 0.93 / 1.78 | 1.79 | 77.2 | -- |
| 128 spp | 0.80 / 1.51 | 1.55 | 197 | -- |

- **The amended criterion 3 was unreachable.** Its targets (<= 0.72 / <= 1.24) were set as -33% / -40%
  of today without measuring the instrument's floor; against an independent reference a 128-spp render
  scores 0.80 / 1.51 (the reference's own noise plus 8-bit rounding). Measure a high-spp run against
  the reference before setting any target on this instrument.
- **What the reuse does by scale** (frame-to-frame change beyond the reference, mean levels, block size
  1/2/4/8/16/64 px): today 1.075/0.894/0.716/0.550/0.402/0.182; reuse 1.082/0.858/0.659/0.476/0.319/
  0.131; flat 48 0.933/0.765/0.605/0.460/0.333/0.145; 128 spp 0.804/0.647/0.502/0.374/0.266/0.109. It
  calms the large scales (better than 48 spp at >= 16 px), but those carry <= 0.55 levels, about 0.5%
  of mean luma, below visibility. The visible flicker is the 1-4 px shimmer on edges and fine texture,
  where the reuse gives 0 / -4 / -8% and softens detail by ~10% (the variance clip on clean input pulls
  history toward the 3x3 mean on 69-75% of pixels; with the clip open, background leaks across edges
  because the depth-range test accepts both sides).
- A low-frequency-only variant was simulated offline (`sim_lowfreq.py`): no useful gain, and by the
  scale table it could at best match the reuse at >= 8 px while leaving 1-4 px unchanged. Not built.
- Alignment was verified (tile phase correlation, reuse vs today: -0.007 px; TAA is off on the video
  route; `rt_depth` is sample zero through the same depth-corrected projection), so the result is not
  a reprojection bug.

**Conclusion.** No method tried -- Cycles adaptive sampling, reuse before OIDN (three variants),
reuse after OIDN -- removes the fine shimmer at the same render time. Within this pipeline the lever
that works is more samples (48 spp: about -13% at every scale, +87% time). A multi-frame denoiser
trained for animation (e.g. OptiX temporal) is the larger option, not pursued. Raw numbers:
`.superpowers/sdd/2026-10-08-video-parity/results.md`.
