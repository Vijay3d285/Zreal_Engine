# Daylight design for day renders (Gap #31, §11.27)

**Date:** 2026-09-19. **Scope:** pipeline (`pipeline_references/`), no engine
change. **Predecessors:** Gap #30 (shadow-invisible window glass, clamp 10),
light portals (`2026-09-18-light-portals-design.md`), the still route
(`2026-09-16-still-route-pixel-filter-design.md`).

## The complaint

A "day" interior gets ~3% of its light from sun and sky. Job 226 with only
the sun and sky reads 0.005 linear frame mean; with the rig, 0.141. The room
is lit by a grid of shadowless omni fills, two "portal spot" sky fakes and
the LLM-scaled fixtures, and the exposure (1.3 × an LLM trim) is tuned for
that rig. The portal spots paint hard stripes and double the wall grain
(15.3% vs 7.8% without them, §11.26). Blender's reference dining still is
exposed for daylight and lit through the openings in view. The two images
differ in light *design* before any shader is reached.

## What was measured before designing (2026-09-19)

1. **`day.exr` is not HDR.** 8192 × 4096, maximum value exactly 1.00, no sun
   disc; zenith band mean 0.74, upper sky 0.50, horizon 0.55, ground 0.26.
   Its upward-facing (cosine-weighted, equirect-weighted) irradiance is
   **E_sky = 1.62**. "The HDRI at real strength" cannot mean "as-is".
2. **The sun is `DirectionalLight3D.light_energy = 1.0`, white**
   (`image_glb_creation.gd` `setup_lighting`, day branch). The
   `[Sun] … energy=6.0` log line is stale. Today's sun-to-sky irradiance
   ratio in the tracer is ~1 : 1.6; a 10 AM clear sky is ~5 : 1.
3. **The tracer ignores `Environment.ambient_light_energy`.** Nothing in
   `render_raytracing.cpp` reads it. The `sky ambient energy=3.90` line,
   `_auto_ambient_boost`, `_illum_ambient_factor` and the JSON's
   `ambientBoost` / `illuminationLevel` all feed a number the path tracer
   never sees; on a day render they are already no-ops.
4. **The still route tonemaps once.** `USE_POST_FX = false` in
   `image_glb_creation.gd`, so the compositor's second AgX never runs on
   stills; the Environment's AgX is the only curve, applied after
   `tonemap_exposure`.
5. **The accumulation buffer is linear radiance before exposure and curve**
   (`viewport_get_pathtracing_accum_image`, the call that writes the linear
   EXR), and it resets only on a camera move, a resize, a shader-flag change
   or the accumulate toggle going off → on
   (`render_raytracing.cpp` "Phase A: accumulation reset detection").
   Changing exposure or adding a light does **not** reset it.
6. `PanoramaSkyMaterial.energy_multiplier` is the sky shader's `exposure`
   uniform (`sky_material.cpp:506`, `COLOR = texture(...) * exposure`), so
   it reaches the radiance map the tracer samples.

## Decisions (brainstorm 2026-09-19)

| question | decision |
|---|---|
| sky source | keep the panorama, scale it (not `PhysicalSkyMaterial`, not new HDRIs) |
| sun : sky | one fixed clear-day constant, 5 : 1; `sunEnergyMultiplier` dropped |
| exposure | a probe render in the same process, occupied median → 0.18 linear |
| the rig | fill grid and portal spots removed on day renders; one measured fallback fill; night renders untouched |
| JSON lighting fields | `ambientBoost`, `illuminationLevel`, `exposureScale`, `sunEnergyMultiplier` ignored on day renders, logged once; fixture adjustments kept |
| validation | four real jobs from the live folder + a synthetic gate |

## Design

All of it lives in a new `pipeline_references/daylight.gd` (a `RefCounted`
with static functions, no scene access) so that the gate and the pipeline
run the same code, plus the call sites below. Nothing in `servers/` changes.

### 1. Daylight, physical (Layer 1)

`Daylight.sky_irradiance(img: Image) -> float`

- Downsample the loaded panorama to 256 × 128 (`Image.resize`, cubic),
  integrate the upper hemisphere: for row `j` (θ = (j + 0.5)/H · π) and
  every column, `E += L · cos θ · sin θ · (2π/W) · (π/H)` over θ < π/2, with
  `L` the mean of RGB. A uniform sky of radiance 1 gives π; `day.exr` gives
  1.62 (the full-resolution value; the plan asserts the 256 × 128 estimate is
  within 1% of it).
- `PanoramaSkyMaterial.energy_multiplier = 1.0 / E_sky`. Every panorama
  then delivers irradiance exactly 1 to a horizontal surface.

Sun (day branch of `setup_lighting`):

- `DAYLIGHT_SUN_TO_SKY` = **5.0** — direct-normal over diffuse-horizontal
  irradiance for a 10 AM clear sky (~90 klux direct vs ~18 klux diffuse).
  One constant, with this measurement in its comment. The sun's
  `light_energy` is **`SUN_TO_SKY / π ≈ 1.59`**: in the tracer (as in
  Godot's raster) a `DirectionalLight3D` of energy E delivers irradiance
  π·E — a white Lambertian reads `E·cosθ`, not `E·cosθ/π`. Measured by the
  gate's D2 on 2026-09-19 (light_energy 5.0 read 1 + 5·cos45°·π to 0.02%);
  the spec's first draft assumed the /π convention.
- Colour white. Angular diameter, shadow blur, `sunAltitude` /
  `_orient_directional_light_from_windows` unchanged.
- Window glass `cast_shadow OFF` stays (Gap #30). `WindowPortal_*` area
  lights stay. `ambient_light_energy` is left at Godot's default and the
  line that printed it as "sky ambient energy" goes.

In the tracer's units (a white Lambertian surface under a uniform sky of
radiance L reads L, irradiance πL; under a sun of energy E at incidence θ it
reads E cos θ, irradiance πE cos θ), a horizontal white card outdoors under
the normalised sky and a sun of energy 5/π reads (1 + 5 cos θ_sun) / π.

### 2. The probe and exposure (Layer 3a)

`Daylight.probe(viewport, env, frames := 16) -> Dictionary`, called from
`render.gd`'s still route after the scene is built and before the 256-frame
accumulation:

1. `env.tonemap_exposure = 1.0`. Reset the accumulator by toggling
   `env.pathtracing_accumulate` off, waiting one frame, on (finding 5).
   Drive 16 frames; read `viewport_get_pathtracing_accum_image`.
2. **Occupancy mask.** Luminance (mean RGB) of **4 × 4 box averages**
   (`Image.shrink_x2()` twice, in C++; FHD → 480 × 270 samples). Pixels
   above **8 × the raw median** are the sky through windows (physical sky is
   50–100 × the wall); everything else is "occupied". No depth buffer, no
   engine change. Box averages, not point samples: measured 2026-09-19 on
   the gate's windowed room, the point-sampled median of a 16-frame probe
   sat 7.5% under the 256-frame still's (the mean only 2%) — path-tracing
   noise is right-skewed and the sample median of noisy pixels is biased
   low; a 4 × 4 average cuts the per-sample variance 16 × and the skew with
   it. At 64 frames the point-sampled median was within 0.5%.
3. `median`, `p25` of the occupied set. **Exposure**
   `e = 0.18 / median`, clamped to [0.05, 50]; outside that range the log
   says `[Daylight] probe: exposure clamped — scene is not a lit interior`
   rather than exposing a black room into range.
4. Return `{median, p25, occupied_fraction, exposure, samples}` where
   `samples` is the subsampled luminance array (needed by §3).

Then `env.tonemap_exposure = e`, reset the accumulator again, and the still
renders as today (256 frames, AgX once, OIDN). Log:

```
[Daylight] probe: median 0.0041 (occupied 94.2%), exposure 43.9, p25 0.0009 -> 0.040 after exposure
```

Cost ≈ 16 frames (≈ 5 s FHD, ≈ 20 s 4K) plus one readback. The probe uses
the same seed sequence the still does; the numbers are reproducible on a
build whose renders are (memory: measure the floor first).

### 3. The fallback fill (Layer 3b)

From the same probe:

- If `p25 · e ≥ DAYLIGHT_FLOOR` (**0.02**) → no fill.
- Otherwise one `AreaLight3D` named `DaylightFill`:
  position = centroid of `_resolve_active_area_polygon()` (the camera's
  room; if empty, `_extract_room_lighting_bounds().center`), `y` = that
  room's ceiling − 0.3 m; facing down (`look_at(pos + Vector3.DOWN, FORWARD)`);
  `area_size` = 0.6 × the room's bounding box; `shadow_enabled = false`;
  `area_normalize_energy = true`; white.
- Energy is **measured**: add the fill at `light_energy = 1.0`, reset the
  accumulator, probe again (16 frames) → `samples_1`. Per pixel
  `L(f) = L₀ + f · (L₁ − L₀)`. Scan `f` from 0 upward (geometric steps,
  ×1.1, from 0.01) on that model; at each step recompute `median(f)`,
  `e(f) = 0.18 / median(f)`, `p25(f)`; take the first `f` with
  `p25(f) · e(f) ≥ 0.02`. Cap: `f` where the fill's share of the occupied
  median (`f · (median₁ − median₀) / median(f)`) reaches 0.5; if the cap is
  hit the log says so and the cap is used.
- Set `light_energy = f`, `tonemap_exposure = e(f)`, reset, render.
- Never on night renders. Fixtures are already in the probe, so a room whose
  lamps light it gets no fill; a room whose lamps do not, does.

Two probes at most, ≈ 10 s at FHD. Log:

```
[Daylight] fill: p25 0.011 < 0.02 after exposure -> DaylightFill at (x, y, z) size (w, h) energy 0.83; exposure 43.9 -> 31.2
```

### 4. What goes, what stays

Removed on **day** renders:

- `render.gd`: `setup_fixed_fill_lights()` is no longer called on day
  stills (the call in `render_image()` is gated on night). The function
  itself, including its day branch, stays intact: `render_video()` calls it
  ungated and the video route is unchanged by this design.
- `_create_window_portal_lights()` and its call: its only caller is the day
  branch of `image_glb_creation.gd` (`video_glb_creation.gd` has its own
  copy, untouched), so the function is deleted with the call.
- `env.tonemap_exposure = 1.3`, the `_auto_ambient_boost > 1.0` exposure
  compensation, `_auto_exposure_scale` (`_tonemapExposureScale`),
  `_automationSunMultiplier`, `_illum_ambient_factor`, the
  `ambient_light_energy = 10.0 × …` line and the `[Sun] energy=6.0` print.
- The AgX `tonemap_exposure *= 1.08` / `tonemap_agx_contrast` multipliers on
  the day path (the probe sets the exposure; a multiplier after it would
  move the median off 0.18).

One log line on day renders:

```
[Daylight] JSON lighting fields ambientBoost/illuminationLevel/exposureScale/sunEnergyMultiplier are not used on day renders (probe-exposed daylight); fixture adjustments are.
```

Kept as today: fixtures and their daytime meta levels
(`_automationEmissionAdjustment`, "Daytime META light"), `sceneLights`, the
sun orientation rule, sky loading, `_create_window_portals()`, night renders
end to end, `USE_POST_FX = false`.

**Video route:** `video_glb_creation.gd` keeps its rig. The still and the
walkthrough of the same room will no longer match in exposure until the
video gets its own version of this. Recorded here, not hidden.

### 5. Not changed

- Sun colour (white; the "10 AM golden" tint stays commented out).
- Gap #30's sampler-dependence of sky through a shadow-invisible pane
  (memory `pt-no-shadow-glass-is-sampler-dependent`).
- The engine. If D1 shows `energy_multiplier` not reaching the radiance map,
  that becomes an engine fix in its own commit.

## Gate: `pt_daylight_gate` (new; suite goes to 23)

`pipeline_references/tests/pt_daylight_gate.gd` + `_scene.tscn`, run
headless the usual way; msaa/FXAA/TAA/debanding off; albedo authored through
`linear_to_srgb()`. Fixture: the portal gate's closed 4 × 3 × 3 m room with
its 1.2 × 1.0 m opening, plus an outdoor 2 × 2 m white horizontal card at
(0, 0, 8) seen by a second camera looking straight down. Sky: a
`PanoramaSkyMaterial` on a synthetic 512 × 256 equirect (`Image` built in
the gate: zenith 1.2 → horizon 0.6, ground 0.3) whose irradiance the gate
computes with the same `Daylight.sky_irradiance()` — E_sky ≈ 2.4, so a
forgotten multiplier reads 2.4 ×, not 1 ×.

| probe | fixture | reads | bar |
|---|---|---|---|
| D1 sky normalisation | card, sky only, `energy_multiplier = 1/E_sky` | card crop mean × π | 1.0 ± 3% |
| D2 sun ratio | D1 + sun at 45° elevation, energy 5/π | card crop mean × π | 1 + 5 cos 45° ± 3% |
| D3 exposure | windowed room, probe, then 64-frame still | occupied median × e | 0.18 ± 5% |
| D4 no fill when lit | windowed room | `DaylightFill` absent; p25 · e ≥ 0.02 | pass/fail |
| D5 fill model | the windowed room, probes without and with the fill at energy 1; then the fill rendered at energy 0.5 | rendered occupied median and p25 vs the per-pixel linear model `L₀ + 0.5·(L₁ − L₀)` | median ± 5%, p25 ± 10%; premise: the model's median at 0.5 ≥ 1.2 × without the fill (else the fixture cannot test linearity — red) |
| D6 mask | windowed room, camera facing the window | excluded fraction vs the window's projected pixel area | ± 20% |

D1 and D2 are red if the multiplier or the sun energy is ignored; D3–D5 are
red if the probe reads the wrong buffer (exposure-baked values make D3 read
0.18 for any `e`); D6 is red if the 8 × mask swallows a bright wall.

D5 tests the physics the fill solver relies on (per-pixel linearity in the
fill's energy, the placement rule, `area_normalize_energy`), not the
decision: the decision — trigger at `p25 · e < 0.02`, exposure recomputed
with the fill, the share cap — is exercised on synthetic samples by the
unit checks F1–F3 (`tests/daylight_unit.gd`). Measured 2026-09-19: no
closed diffuse box lit by one lamp reaches the trigger's `p25 / median <
0.11` — bounces homogenise it to ≈ 0.7–0.8 with or without a partition
(the first draft's "bricked room, no fixtures" is degenerate: 100% fill at
any energy). The trigger is a high-contrast condition by design; on the
four real jobs the log says whether it fired.

## The four jobs

From the live folder scan (1283 day interiors: 720 windowless, 297 window
in view, 203 window behind, 63 deep):

| class | job | note |
|---|---|---|
| window in view | `urbantestdark226_fish` | dining / aquarium, 2 windows at 5 m |
| window behind camera | `urbantestdark225_fish` | §11.26's reference, same plan |
| deep room | `urbantestdark176_llm` | one window 5.6 m from the camera, 13.3 × 7.4 m plan |
| windowless | `urbantestdark157_fillLight1.3` | 6.3 × 5.4 m, no window holes |

If a job's assets do not load, the next most recent in its class. Each is
rendered by the rule at FHD (256 frames, OIDN, `ZR_PT_EXR=1`) and measured
from the EXR by `tools/daylight_validation.py`:

- occupied median after exposure in **0.15–0.35**;
- no occupied 1/16-of-frame tile below **0.02**;
- window pixels above 1.0 after exposure (before AgX) ≤ **2%** of the window;
- wall grain (5 × 5 residual RMS / mean on a flat wall crop) ≤ **10%** at
  256 samples;
- job 226 side by side with the Blender reference dining still.

Plus: suite 22/22 unchanged; one night job rendered before and after,
byte-identical (memory: measure the repeat floor on the build first).
Numbers, red or green, go into a "Measured" section of this file.

## Measured (2026-09-19)

Gate `pt_daylight_gate` (256 frames): D0 2.820399 vs E_sky 2.827753 (-0.26%);
D1 0.997366 vs 1.000000 (-0.26%); D2 4.532951 vs 4.535534 (-0.06%, sun:sky
5.0, `light_energy` 1.5915 = 5/π); D3 still occupied median·e 0.175495 vs
0.180000 (-2.50%); D4 p25·e 0.1513 vs floor 0.020 (solver needed=false, ok);
D5 fill model at energy 0.50: model median 0.02458 / rendered 0.02477
(+0.76%), model p25 0.02189 / rendered 0.02203 (+0.60%), premise the fill
contributes ≥20% of the median: 1.839× (ok); D6 excluded fraction 0.070557
vs window area 0.073469 (-3.96%). All 11/11 gate checks PASS.
Unit checks: 27/27. Suite 23/23. Night job `urbantest164_render_input.json`:
repeat floor identical (md5 `92d4c1c92013bc521967bc21c9f662bc` on both
pre-plan renders), before/after identical (same md5 on the post-plan render).

| job | class | exposure | fill | occupied median·e | darkest tile | window clipped | wall grain (pre-denoise) | wall crop (y0 y1 x0 x1) |
|---|---|---|---|---|---|---|---|---|
| 226 | window in view | 5.812 | none | 0.1880 (ok) | 0.0732 (ok) | 0.00% (ok) | 12.82% → **11.47% (RED)** on a clean crop | ~~0.03 0.25 0.72 0.95~~ → 0.1389 0.3797 0.7292 0.95 |
| 227 (substituted for duplicate 225) | window in view | 3.764 | none | 0.1802 (ok) | 0.1097 (ok) | 0.00% (ok) | ~~16.39% (RED)~~ → **8.20% (ok)** on a clean crop, see Findings (6) | ~~0.12 0.44 0.59 0.64~~ → 0.2875 0.5329 0.5867 0.6430 |
| 176 | deep room | 0.747 | none | 0.1803 (ok) | 0.0976 (ok) | not measured (22-px mask, <0.5% of frame) | 5.48% (ok) | 0.40 0.60 0.40 0.60 (default) |
| 157 | windowless | 12.588 | none | 0.1784 (ok) | 0.0527 (ok) | 11.44% (RED) | 14.29% → **14.93% (RED)** on a clean crop | ~~0.30 0.50 0.67 0.71~~ → 0.2778 0.5370 0.6771 0.7042 |

Window clipping is measured on the tonemapped PNG (≥254/255), not the linear
buffer (see Findings (4)). Wall grain is the pre-denoise EXR/PFM number
against the spec's ≤10% bar; the post-denoise PNG grain on the same crops is
0.10–3.76% and is informational only (Findings (6)). The crops above are not
the script's `0.40 0.60 0.40 0.60` default except for 176: on 226 the default
crop lands on the pendant chandelier and reads 22.89% (a different, higher
number than the recorded 12.82%, for the same job, depending only on which
20%×20% square is sampled) and on 157 it lands on a blown-out backlit fixture
panel and reads 1012.58% — neither is a wall reading at all, which is why the
crop used for each job is recorded here rather than left implicit
(`task-8-report.md`, "Wall crop" notes per job).

Blender reference (job 226): not available — no reference file was supplied;
job 226 was not compared side by side against a Blender still.
Probe cost: 16.7–19.6 s at FHD (one probe; none of the four jobs triggered
the fill probe).

### Forced fill run (2026-09-20, F2 fix-wave)

None of the four measured jobs above triggered `DaylightFill` (finding 8), so
the fill path had never actually executed end to end. `render.gd`'s
`_daylight_probe_and_expose` gained a `ZR_DAYLIGHT_FLOOR` environment
override (read once, threaded through `solve_fill`'s new `p_floor` param, so
`Daylight.FLOOR` itself is unchanged for every other caller) purely to force
the trigger on a real job without editing the constant. Run: job 226's own
input (`f2_226_input.json`) with `ZR_DAYLIGHT_FLOOR=1.0 ZR_PT_EXR=1
ZR_PT_ACCUM_TARGET=64`, in a scratch copy of `pipeline_references/`. Log:

```
[Daylight] floor override ZR_DAYLIGHT_FLOOR=1.0
[Daylight] probe: median 0.03097 (occupied 97.7%), exposure 5.812, p25 0.01431 -> 0.0832 after exposure  [17311 ms, 1920x1080]
[Daylight] fill: p25 0.0832 < 1.000 after exposure -> DaylightFill at (12.58286, 2.5, 7.351805) size (8.076, 6.280209) energy 1121.7797 (CAPPED at share 0.50); exposure 5.812 -> 2.866
```

Exit code 0, `Image saved to: .../fill_226.png`, `[Render] Linear HDR EXR
saved to: .../fill_226.exr`. The scan hit the `FILL_SHARE_CAP` exit (0.50)
rather than clearing the forced floor of 1.0 outright — an artificial floor
that high was never going to be reachable by any physically-sized fill, so
the cap firing first is the expected outcome, not a defect; it is exactly
what F3 in `daylight_unit.gd` predicts for a fill whose share saturates
before the floor does. `tools/daylight_validation.py` on the resulting
PFM/PNG (`--wall 0.03 0.25 0.72 0.95`, job 226's own crop):

```
fill_226.pfm  exposure 2.866 (with DaylightFill)  window 1.2% of frame
  RED occupied median x e   0.1324   [0.15, 0.35]
  ok  darkest occupied tile 0.0607   >= 0.02
  ok  window clipped (PNG >= 254/255)  0.00%  <= 2%
  RED wall grain, pre-denoise 44.62%  <= 10%  (crop rows 0.03-0.25 cols 0.72-0.95)
  .   wall grain, post-denoise (PNG) 0.25%  (informational, same crop)
```

Both REDs are the expected consequence of the artificial floor, not a new
defect: an energy-1121.7797 fill capped at 50% share badly overpowers the
room relative to the sun/sky it was tuned against, dragging the occupied
median off target and adding its own noise on top of Gap #32's. The PNG
(post-OIDN) itself: the same dining room as the unforced job 226 (marble
table, dark chairs, gold pendant, aquarium credenza) but with visible
posterization/banding across the ceiling and the back-left wall — the
denoiser's guides could not fully absorb a synthetic fill three orders of
magnitude past any value the solver would choose under the real 0.02 floor.
This run exercises the fill-branch code path (`solve_fill`'s "needed" exit,
`_place_daylight_fill`, the fill log line, and `daylight_validation.py`'s
`fill:` regex with "(with DaylightFill)") for the first time against a real
render; it is not evidence about ordinary-floor behaviour.

### Findings during execution

1. The tracer's `DirectionalLight3D` energy E is irradiance π·E (a white
   Lambertian reads `E·cosθ`, not `E·cosθ/π`), so the sun's `light_energy`
   must be `SUN_TO_SKY/π` (5/π = 1.5915) to hold the intended 5:1 sun:sky
   ratio — found via gate D2 reading +166.89% high before the fix.
2. Probe statistics moved from point-sampling to 4×4 box averages, because
   the point-sampled median of a 16-frame probe read 7.5–8.1% low against a
   256-frame converged still (gate D3): right-skewed path-tracing noise
   makes the point-sampled median a slow-converging, low-biased statistic.
3. The fill trigger (p25/median < 0.11) is unreachable in any single-lamp
   closed box — p25/median measured 0.70–0.80 across four fixture variants,
   partitioned or not — because GI homogenizes a convex diffuse cavity; gate
   D5 therefore tests the fill's per-pixel linear model against a rendered
   still (premise 1.839× ≥ 1.2×, both green) rather than staging the
   trigger, and the trigger logic itself is covered only by unit tests F1–F3.
4. Window clipping is judged on the tonemapped PNG rather than the linear
   EXR, since every physical window pixel exceeds 1.0 linear by construction
   once the room is exposed to the 0.18 occupied-median target — the linear
   buffer reads 100% "clipped" in all four jobs, which is expected and
   informational, not a defect.
5. In a sun-lit room the visible sky can be only about 2× the wall's raw
   brightness rather than the assumed 8× (job 176), so the probe's
   >8×-median window mask can miss the window almost entirely (22 of
   2,073,600 pixels) without affecting exposure, since the occupied-median
   target does not depend on which pixels the window mask selects.
6. Wall grain (pre-denoise EXR) is RED on 3 of 4 jobs — 226 at 12.82%, 227
   at 16.39%, 157 at 14.29%, all against a ≤10% bar and on hand-verified
   flat-wall crops — while the post-denoise PNG grain on the same crops is
   only 0.10–3.76%, informational; against §11.26's 7.8% for the prior rig
   (fill grid + portals, no daylight design) on the same plan as job 227,
   this design's grain is roughly double, not merely over the ≤10% bar (see
   PATH_TRACER_QUALITY_ROADMAP.md §11.27 closeout and §11.28/Gap #32).

   **Corrected 2026-09-24 — one of those three readings was the crop, not
   the render.** Audited while investigating Gap #32; see
   `2026-09-22-path-guiding-design.md` "What the crops were actually
   measuring".

   - **227 was an artifact.** Its crop contained a recessed ceiling IES
     downlight whose sharp, barely-converging edge dominated the statistic.
     On a clean crop of the same wall (`0.2875 0.5329 0.5867 0.6430`, 86% of
     the old area) the SAME render reads **8.20%** — passing — and the noise
     falls at 2.062× then 1.993× per 4× samples with a fitted floor of
     0.00%, against the old crop's 1.726×/1.371× and a spurious 5.72% floor.
   - **226 mildly contaminated, still RED.** A soft ceiling/wall corner
     shadow gradient in the top rows; clean crop `0.1389 0.3797 0.7292 0.95`
     reads **11.47%**. Other clean regions of the same wall read 11–15%.
   - **157 contaminated, still RED, and slightly worse.** The crop contained
     a picture frame's dark wood edge plus a corner-highlight tail; clean
     crop `0.2778 0.5370 0.6771 0.7042` reads **14.93%**. That wall is dim
     (the highest exposure of the four jobs) and genuinely noisy at 256
     frames.

   So the bar is missed on 2 of 4 jobs, not 3, and "hand-verified flat-wall
   crop" above means hand-verified for GEOMETRY, not for uniform
   illumination — a flat wall carrying a fixture edge or a shadow boundary
   defeats this statistic, which is a 5×5 spatial residual and cannot tell
   noise from structure. 226 and 157 have not been re-rendered at a second
   frame count, so the convergence check that settled 227 has not been run
   on them.
7. Job 157's window-clipping RED (11.44% on the PNG) traces to a backlit
   fixture panel blown out at the job's exposure of 12.588×; the fixture's
   emission levels were tuned for the pipeline's old exposure regime
   (~1.3–1.9×) and were not revisited for the new probe-driven exposure —
   a follow-up, not fixed here.
8. None of the four measured jobs (226, 227, 176, 157) triggered a
   `DaylightFill` placement.

## Out of scope (recorded)

- Video route daylight (`video_glb_creation.gd`).
- Overcast / time-of-day presets; a sun disc in the panorama.
- Real HDRI skies per job.
- Variance reduction for bounce-lit surfaces (Gap #32).
