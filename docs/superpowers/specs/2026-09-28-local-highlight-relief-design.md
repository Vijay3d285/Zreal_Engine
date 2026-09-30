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

## Measured (2026-09-29)

Gate `pt_highlight_relief_gate`, fixture at strength 0.50, knee 3.00, 9 checks,
all green:

- **H0 inert** — relief off vs a PFM captured on the pre-feature binary
  (`0318a2b7fe`): max abs diff **0.0000000000**.
- **H1 relief** — patch MEDIAN linear luminance **17.7500 -> 5.1289**, reduction
  **0.711** (bar 0.40, never moved).
- **H2 midtones** — far-wall mean **1.467576 -> 1.467576**, **+0.00%** (tol 1%).
- **H3 halo** — 1-8 px ring **1.259452 -> 0.972679**, darkening **0.2277**
  (bar 0.25, set from this measurement + 0.02). 8-24, 24-48 and 48-96 px all
  read exactly 0.0000.
- **H4 gate** — an unlit fixture: clipped fraction 0.0000 -> strength **0.000**,
  `needed == false`.

**Suite 25/25**, every gate `exit=0` (run 2026-09-29 on the shipped binary).

`daylight_unit.gd` R1-R6: **45/45**, re-run 2026-09-29 against the shipped
`RELIEF_KNEE` of 3.0 rather than carried over from Task 1's knee-4.0 run, since
`highlight_relief` reads that constant internally. R2 strength 0.8333, R3 grows
to 0.9583, R4 caps at 0.9998 under the 1.0 ceiling, R5/R6 return exactly 0.0.
Re-run with `--headless --path pipeline_references -s res://tests/daylight_unit.gd`.

**Two bars in this gate were measuring the wrong quantity and were corrected in
round 3 (`a7367c2068`); neither bar was relaxed.** H1 counted patch pixels at or
above the knee, which cannot detect this operator at all: for a uniform region
at luminance L relief returns `L / (1 + s (L/knee - 1))`, which stays above the
knee for every L above it, so a pixel that starts over the knee ends over it
whatever the strength. H1 now reads the patch's median linear luminance. H3
watched the 8-48 px ring, which reads 0.0000 *structurally* — with a hard patch
edge the blurred luminance falls under the knee within ~8 px, so the gain is
exactly 1.0 out there by construction — and a bar over a band that cannot move
cannot newly fail. H3 now gates 1-8 px, where the halo is. H3's bar is anchored
to the FIXTURE, not to production: the fixture is ~3x pessimistic (small patch
against the shader's 32 px reach), so a production-anchored bar would fail this
gate for fixture geometry rather than for a regression.

### Production

| job | route | sun-patch clip >=254 | mid-wall mean | halo 1-8 / 8-48 px | `[Relief]` |
|---|---|---|---|---|---|
| 201 | 1080p, OIDN | **23.25% -> 0.68%** (-97.1%, bar 40%) | **168.2244 -> 168.2244** (0.0000%, bar 1%) | 7.49% / 2.83% | clipped 5.09% past knee 3.0 -> strength **0.753** (ON) |
| 226 | 1080p, OIDN | n/a (gate off) | **byte-identical** to the pre-relief binary, md5 `f5dd18d6f9908be013e8b69e404fab6e` | n/a | clipped 0.25% past knee 3.0 -> strength **0.000** (off) |

Job 201 on the shipped binary is byte-identical to the knee-sweep's
`knee_3.0.png` (md5 `2a17e6571e9bd26619591415cfaf0e08`), so the whole knee-3.0
measurement set transfers to the shipped build without re-measuring. Job 226 was
rendered twice — once on the shipped binary, once on a build with the five
engine files that reference the pass reverted to `0318a2b7fe` — and the two PNGs
are byte-identical. That is the claim the gating design rests on: a day job that
does not need relief renders exactly as it did before the feature existed.

### Findings

1. **The headline is partly a threshold artefact, and the operator has a
   structural ceiling.** Clipping at 254+ falls 97%, but the lit set's MEDIAN
   only moves 255.00 -> 248.21: most of those pixels merely crossed into the
   250-254 band. The operator asymptotes to `knee / strength` (3.0 / 0.753 =
   3.98 post-exposure linear), which AgX still renders near-white. **At no knee
   does the patch stop reading as white** (median 240 even at knee 2.0). This
   softens the blowout; it does not restore the rug to normally-lit. Full
   recovery needs the named fallbacks (edge-aware filter, exposure fusion), not
   a different constant.
2. **Nothing gets brighter and nothing far away moves.** On job 201, `dY > +2`
   is 0.000% of the frame and far-from-lit `|dY| > 0` is 0.0000% over 470,585
   pixels. The operator is strictly a local darkening of bright regions.
3. **The knee is the halo lever, and 3.0 was chosen by sweep, not by taste.**
   knee 4.0 / 3.0 / 2.0 give 1-8 px halo 4.09% / 7.49% / 14.42% and patch median
   252.07 / 248.21 / 240.28. At 2.0 the weave is clear but the patch goes pearly
   and collateral appears elsewhere (dark smudges under each downlight, dimmed
   LED strips). 3.0 is the point where the weave and medallion read as pale
   linework, the patch still reads as direct sun, and the halo is not visible at
   normal viewing size.
4. **The gate fixture is not the production case** and was nearly mistaken for
   a design failure. Its hard-edged patch puts the entire halo inside 8 px and
   about 3x deeper than job 201's soft, textured patch, which spreads 7.49% /
   4.68% / 1.59% across 1-8 / 8-24 / 24-48 px. The first fixture (256 px, 1 m
   patch) was small enough against the 32 px blur reach that it diluted the gain
   and failed H1/H3 outright; enlarging it to 512 px / 2 m was forced by that
   ratio, before the result was known.

### Known-open

- The OIDN-off route was measured only on the instrumented binary; one clean
  OIDN-off render against `r3` would close it.
- The DLSS-RR-final route's per-frame copy has no freeze, so relief runs before
  its blit and would be overwritten on frames it also writes. Out of scope here.
- Per-job wall crops: the daylight spec's job 201 crop is job 227's and lands on
  a window sash. Job 201's measurements above use its own verified regions.
- **Not ported to the video route.** The video route does not call
  `highlight_relief` and is unchanged, as "Not changed" above states.
