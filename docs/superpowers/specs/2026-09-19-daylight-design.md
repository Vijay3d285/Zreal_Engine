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

- `render.gd` fill builder: the `day_render` branch (`energy_multiplier =
  1.25`, "Fill grid at 1.25x") and the day grid loop. Night grid untouched.
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
| D5 fill when dark | window bricked (a sixth quad), no fixtures | `DaylightFill` present; p25 · e | 0.02 ± 10%, median 0.18 ± 5% |
| D6 mask | windowed room, camera facing the window | excluded fraction vs the window's projected pixel area | ± 20% |

D1 and D2 are red if the multiplier or the sun energy is ignored; D3–D5 are
red if the probe reads the wrong buffer (exposure-baked values make D3 read
0.18 for any `e`); D6 is red if the 8 × mask swallows a bright wall.

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

## Out of scope (recorded)

- Video route daylight (`video_glb_creation.gd`).
- Overcast / time-of-day presets; a sun disc in the panorama.
- Real HDRI skies per job.
- Variance reduction for bounce-lit surfaces (Gap #32).
