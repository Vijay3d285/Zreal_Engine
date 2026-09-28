# Local highlight relief for sun patches

**Date:** 2026-09-28. **Scope:** engine (one new effect + one dispatch site),
one pure function in the daylight pipeline, one project setting.
**Predecessors:** the daylight design (Gap #31,
`2026-09-19-daylight-design.md`), which introduced the exposure probe this
reuses; path guiding (Gap #32, `2026-09-22-path-guiding-design.md`), whose
measurements established the method used below.

## The complaint

Job 201 is a daylit living room that reads well everywhere except where
direct sun lands on the floor and rug, which washes out to featureless
white. Measured on the shipped 4K PNG: **23.3%** of the sun-patch region sits
at 254+/255 and **4.17%** of the whole frame does.

## What was measured before designing (2026-09-28)

Working notes in `.superpowers/sdd/2026-09-22-path-guiding/`
(`sun-patch-exposure.md`, `agx-white-test.md`, `sun-strength-test.md`).

1. **The dynamic range is real.** The sun patch measures **6.2 stops** above
   the room's occupied median (linear 0.565 vs 0.0073) on the linear buffer.
2. **Exposure is not a lever.** At 0.5x exposure, whole-frame clipping falls
   4.13% -> 2.24%, but the blown core's median display value only moves
   255 -> 253.7 — still white — while the room darkens ~35%. Recovering the
   core needs ~10–15% of current exposure, which makes the image near-black.
3. **The AgX white point is not a lever.** Tested at 2.0 / 16.29 / 32.0:
   sun-patch clipping 25.75% / 23.60% / 23.21%, rug unrecoverable at every
   value, midtones unmoved. The knob saturates — 8x the white bought 2.1
   points, a further 2x bought 0.4.
4. **The sun's own strength is not a lever, and the reason generalises.**
   `SUN_TO_SKY` 5.0 / 3.5 / 2.5 gave sun-patch clipping 23.60% / 23.33% /
   22.92%. Halving the sun moves the patch **0.24 stops**, because the room
   is itself lit by sun bounce: the median falls (0.00745 -> 0.00441), the
   probe raises exposure to compensate (24.171 -> 40.797), and the ratio is
   restored. **The sun patch and the room brightness are coupled, so no
   global scalar can separate them.** Only a spatially selective operation
   can.
5. **The existing compositor hook cannot reach this image.** In
   `render_forward_clustered.cpp` the order is
   `_process_compositor_effects(POST_TRANSPARENT)` (:3226) ->
   `_oidn_final_denoise_accumulator` (:3247) -> `copy_output_texture`
   (:3256) -> `_render_buffers_post_process_and_tonemap` (:3596). A
   compositor effect runs before the denoise and its output is then
   overwritten by the copy. The only points downstream of OIDN are inside
   the tonemap pass or after the GDScript readback.
6. `RB_TEX_COLOR` at :3256 is **scene-linear and pre-exposure** — exposure is
   applied inside the tonemap pass.

## Decisions (brainstorm 2026-09-28)

1. **Gated on measured clipping**, not applied unconditionally and not gated
   on day/night: a frame with no meaningful blown area is untouched and
   renders byte-identically.
2. **A gentle rolloff**, not full recovery: the patch stays clearly the
   brightest thing in the room and still reads as direct sun. Strength is
   one constant, so it can be pushed further after seeing real jobs.
3. **A new compute pass between the denoise and the tone curve**, not an
   edit to `tonemap.glsl` and not a second tone curve in GDScript. A
   GDScript implementation would mean maintaining a second copy of AgX;
   this session has already been bitten twice by duplicated definitions
   drifting (the guide's GLSL/C++ twin, and `tonemap_white` silently not
   being the property AgX reads).
4. **Blurred-luminance local exposure**, not a bilateral filter or exposure
   fusion. Its entire behaviour is two constants; if it halos visibly on
   real jobs, an edge-aware filter is a drop-in replacement for the blur
   step and nothing else in the design changes.

## Design

### 1. The decision (`daylight.gd`, pure, unit-testable)

One new static function beside `stats()`:

```gdscript
static func highlight_relief(p_samples: PackedFloat32Array, p_exposure: float) -> Dictionary
```

It reuses the samples the exposure probe already collected (`Daylight.probe`,
called from `render.gd:641`) — **no extra render**. It counts the fraction of
samples whose post-exposure value exceeds `RELIEF_KNEE`, and returns
`{needed: bool, strength: float, clipped_fraction: float}`.

- `needed` is false when `clipped_fraction < RELIEF_MIN_FRACTION`, and then
  `strength` is exactly 0.0. This is the gate: those frames are byte-identical
  to today.
- `strength` grows with how far past the knee the bright samples sit, so a
  marginally hot frame gets a marginal correction rather than a step change.

Because it is a pure function over a float array, every branch is testable in
`tests/daylight_unit.gd` with no GPU and no render, exactly as `solve_fill`
is.

`render.gd :: _daylight_probe_and_expose` (:627) calls it after it sets
`p_env.tonemap_exposure` (:672) and writes the strength to the project
setting below. The video route does not call it and is unchanged.

### 2. The channel

Project setting `rendering/pathtracer/highlight_relief_strength` (float,
default **0.0**), read per frame the way `guiding_probability` and
`emissive_mesh_lights` are. Not an `Environment` property:
`Environment.pathtracing_params[16]` is full (0–15), and widening the
RenderingServer API for one float is not worth it — the same reasoning, and
the same precedent, as Gap #32.

A second setting `rendering/pathtracer/highlight_relief_debug` (bool,
default false) makes the pass write its gain map out as greyscale instead of
applying it, so a wrong-looking render is diagnosed by looking at the gain
rather than guessing.

### 3. The engine pass

New effect `servers/rendering/renderer_rd/effects/local_highlight.{cpp,h}`,
shaped like the small classes already in that directory (`bokeh_dof`,
`luminance`). Dispatched from exactly one place —
`render_forward_clustered.cpp` immediately after the
`copy_output_texture` at :3256 — and **only when strength > 0**. When the
gate is off nothing is dispatched: no shader runs, so there is no
float-contraction difference of the kind that moved 1.3% of pixels in Gap
#32's `combinedPdf` hook.

Input and output: `RB_TEX_COLOR`. Two steps:

1. **Blurred luminance.** Downsample luminance to ~1/16 resolution and blur
   there; a wide radius is then nearly free, and the width is what
   suppresses halos. Model on the existing glow downsample chain
   (`copy_effects.h :: gaussian_glow_downsample_raster`, `RB_TEX_BLUR_0`).
2. **Gain.** Per pixel, from the **blurred** luminance `Lb` in post-exposure
   terms (`Lb * environment_get_exposure(env)` — the buffer is pre-exposure,
   see Measured (6)):

   ```
   gain = 1.0 / (1.0 + strength * max(0.0, Lb_exposed / RELIEF_KNEE - 1.0))
   ```

   Exactly 1.0 below the knee, falling off smoothly above. `color *= gain`.

**Why this recovers texture where global exposure could not:** the divisor is
a *smooth* field, so the patch's high-frequency detail — the rug weave — is
untouched relative to its local mean. The whole patch slides down AgX's curve
into a region where that detail is visible, instead of each pixel being
crushed individually.

### 4. Not changed

`tonemap.glsl` and the AgX curve; the exposure probe's own target and mask;
the 16-bit PNG colour-space contract (this acts before tonemap); the video
and real-time routes; OIDN; the path tracer.

## Gate: `pt_highlight_relief_gate` (new; suite goes to 25)

Fixture: a box with a small, very bright patch on the floor several stops
above the room — the minimum that reproduces the production case.

| # | check | bar |
|---|---|---|
| H0 inert | a day scene below `RELIEF_MIN_FRACTION`, this binary vs pre-change | md5-identical |
| H1 relief | patch clipping, relief off vs on | falls by >= 40% relative |
| H2 midtones | mid-wall mean, off vs on | moves < 1% (a highlight operator, not an exposure change) |
| H3 halo | mean of an annulus just outside the patch, off vs on | bar set from the first measurement + margin |
| H4 gate | a frame with no blown area | `needed == false`, `strength == 0.0`, no dispatch |

H0, H2 and H4 are absolute: they encode what the design promises regardless
of tuning. H1's 40% is the production acceptance restated on the fixture — if
the first measurement cannot reach it, that is a failure of the DESIGN and
the answer is a stronger operator (the named fallbacks) or a revised goal,
**not** a lowered bar. H3 has no defensible value before the blur radius is
chosen, so its bar is set from the first measurement plus a stated margin,
with the measurement and date in the constant's comment.

Bars carry their measurement and date as comments, as `pt_guiding_gate`'s now
do — and are never moved to make a run green.

Unit checks in `tests/daylight_unit.gd`: nothing above the knee ->
`needed = false, strength = 0`; a large blown area -> strength growing with
excess; the threshold boundary behaves smoothly rather than stepping.

## Production acceptance

- **Job 201** before/after at production settings, with the sun-patch crops
  side by side for a human look. Sun-patch clipping down by at least 40%
  relative (from 23.3%); mid-wall mean within 1%; no visible halo.
- **One day job with no blown patch**, confirmed **byte-identical**.
- The full gate suite green (24 today, 25 with this one).

## Risks, recorded

- **The decision runs on the probe's samples**, not the final frame: 16
  frames at 4x4 box averages. A patch at ~4% of frame is several thousand
  samples, so the fraction is well estimated — but a *small* specular
  highlight may fall below the gate and get no relief. Acceptable for a
  gentle rolloff; that is what the threshold is for.
- **Halos** are the artefact a viewer would notice. H3 measures them; the
  blur radius is the control, and an edge-aware filter is the fallback.
- **A second tuning surface.** `RELIEF_KNEE`, `RELIEF_MIN_FRACTION` and the
  strength curve join `TARGET_MEDIAN` and `MASK_RATIO` as things that shape
  the look. All four belong in `daylight.gd` with measured comments, not
  spread between GDScript and C++.

## Out of scope (recorded)

Exposure fusion and edge-aware filtering (named fallbacks, not built); the
video and real-time routes; the sunset profile, which no live job can reach
(none of 1741 input JSONs sets `sunset_render` or a sunset time-of-day);
the two other routes' AgX white assignment, fixed separately in
`fa7261510a`.
