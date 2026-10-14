# Depth of field for day stills: a thin lens in the path tracer, focused by measuring the frame

**Date:** 2026-10-13. **Status:** design approved by the owner in conversation; spec awaiting review.
**Scope:** engine (thin lens in the raygen camera ray, two project settings, a depth read-back API)
and the still route (`render.gd` autofocus, new `dof.gd`). Video unchanged. Roadmap item: "Depth of
field in the tracer" (`Full_Architectural_Gap_Roadmap.md`, section 4, item 2).

## Intent

**Owner's words / decisions (2026-10-13):**
1. Depth of field on **still renders only**, a **subtle** real-camera look (gentle falloff on near
   objects and far walls; the subject crisp). Video stays as it is.
2. Focus is chosen **automatically by measuring the frame** (centre-weighted, like a camera's
   autofocus), not from the editor's look-at point and not from floor-plan geometry.
3. **Day stills only** in this version; night stills unchanged (they have no probe to measure with).

**Assumptions (confirmed with the owner's design approval):** the exposure, daylight fill and
highlight relief just finalised must not change; no new job-JSON fields (the pipeline decides);
no extra render time; the strength is one fixed f-number picked from test renders.

**Why measure, not the look-at point:** the editor's look-at point is not a subject. On job 209 it
sits about 10 m from the camera, beyond the far wall of a 6.8 m room.

## Design

### 1. Thin lens in the engine

- `camera_ray()` in `servers/rendering/renderer_rd/shaders/raytracing/scene_raytracing_raygen.glsl`
  gains a thin lens, as Cycles' perspective camera does: for a pinhole direction `d` in camera
  space (Godot looks down -Z), the focal point is `P = d * (focus / -d.z)`; the ray starts at a lens
  point `L = (r * u, r * v, 0)` (concentric disc mapping of a 2D sample, `r` = aperture radius) and
  points along `normalize(P - L)`; both are taken to world space with `inv_view` as today.
  Everything on the focal plane stays sharp; the blur circle grows with distance from it.
- Round aperture only (Cycles' default `aperture_blades = 0`); no blades, rotation or ratio.
- The lens sample is a new 2D Sobol dimension in the init block:
  `#define RT_PRNG_LENS 2u` in `raytracing_inc.glsl` (block 0 uses only `RT_PRNG_FILTER = 0u`;
  Cycles draws its filter and lens samples from its init dimensions the same way).
- **Sample 0 stays a pinhole ray** (lens centre), exactly like `camera_filter_jitter()` keeps
  sample 0 at the pixel centre, so the primary-ray depth / G-buffer / velocity writes that fire on
  sample 0 stay aligned to the pinhole pixel centre. Both the accumulate path and the one-shot path
  pass the sample index through.
- **Controls**, project settings registered in `servers/rendering/rendering_server.cpp` next to the
  other `rendering/pathtracer/*` settings:
  - `rendering/pathtracer/dof_aperture_radius` (float, metres, default `0.0` = off)
  - `rendering/pathtracer/dof_focus_distance` (float, metres, default `3.0`)
  Read with `GLOBAL_GET` when the `rt_params` UBO is filled in `render_raytracing.cpp`, into new
  slots `RT_PARAM_DOF_APERTURE = 40` and `RT_PARAM_DOF_FOCUS = 41` (C++ constants in
  `scene_shader_raytracing.h`, GLSL defines in `raytracing_inc.glsl`). The UBO grows from
  `vec4 rt_params[10]` to `[11]` (`raytracing_common_inc.glsl`) with the C++ array in lockstep;
  slots 42-43 stay free.
- **Off is exact:** with radius `<= 0` the lens branch is not taken and the ray is computed by the
  same instructions as today: byte-identical frames. Nothing in the video route sets these
  settings, so video renders are unchanged.

### 2. Autofocus and strength (day stills)

- **Engine read-back:** `RenderingServer.viewport_get_pathtracing_depth_image(viewport) -> Image`,
  the primary-hit depth (`rt_depth`, `RB_TEX_RT_DEPTH`, reverse-Z NDC depth written on sample 0;
  `0.0` = miss), returned as a single-channel float image. It follows
  `viewport_get_pathtracing_accum_image` through the same files: `rendering_server.h` (virtual),
  `rendering_server_default.h` (`FUNC1RC`), `rendering_server.cpp` (ClassDB bind),
  `renderer_viewport.h/.cpp`, `rendering_method.h`, `renderer_scene_cull.h`,
  `renderer_scene_render.h`, `render_forward_clustered.h/.cpp` (the RD read, `texture_get_data` as
  the accumulator read does), and the dummy stub in `servers/rendering/dummy/rasterizer_scene_dummy.h`.
- **When:** in `render.gd`, right after `_daylight_probe_and_expose()` (day stills only). The probe
  has just rendered this exact view with no lens, so the depth is already there: no extra render.
  A new `_dof_autofocus(p_env)` runs there; depth of field is switched on only after the probe has
  measured exposure, so the exposure, the daylight fill and the highlight-relief decision are
  computed exactly as today.
- **Focus rule** (pure functions in a new `pipeline_references/dof.gd`, preloaded by `render.gd`;
  not a `class_name`: production runs with no `.godot/` class cache):
  - sample the central 50% x 50% of the depth image on a grid (stride 8 px at 4K);
  - drop misses (`depth <= 0`);
  - convert each depth to metres along the ray: unproject `(ndc_x, ndc_y, depth)` through the
    inverse of the camera's depth-corrected projection and take the length;
  - focus distance = the **median**, clamped to **[0.5, 25] m**;
  - if fewer than **10%** of the sampled pixels hit geometry (e.g. a shot straight out of a
    window), depth of field stays **off** for that still and the log says why.
- **Strength:** aperture radius = focal length / (2 x f-number), as Blender computes it; the focal
  length comes from the camera's vertical field of view on a full-frame 24 mm-high sensor:
  `f = 12 mm / tan(fov / 2)` (45 degrees -> 29.0 mm). The f-number is one constant,
  `DOF_F_STOP` in `dof.gd`, chosen by the owner from the test renders (section 3);
  `DOF_F_STOP := 0.0` turns the feature off (radius 0).
- **Log line**, one per still:
  `[DoF] focus 3.42 m (median of 4820 central pixels, 92% hit), f/8 at 29.0 mm -> aperture radius 1.81 mm`
  or `[DoF] off: only 6% of central pixels hit geometry`.
- Night stills, exterior stills without a probe, and video: no change.

### 3. Verification

1. **Engine unit tests** (doctest, `tests/servers/rendering/test_pt_dof.cpp`, mirroring the GLSL
   math as the other `test_pt_*.cpp` files do): the concentric mapping lands every sample in the
   unit disc and preserves area (uniform density); rays from any lens point through one pixel meet
   at the same focal-plane point; radius 0 returns exactly the pinhole origin and direction. Each
   test is mutation-checked (break the mirrored math, watch it fail).
2. **Script unit tests** (`pipeline_references/tests/dof_unit.gd`, like `daylight_unit.gd`): median
   over the central region only; misses excluded; the [0.5, 25] m clamp; the < 10% fallback;
   45 degrees at f/8 -> 1.81 mm.
3. **Render checks on job 209** (production scripts in a scratch copy, as for the relief check):
   - repeatability floor first: today's binary twice, byte compare;
   - **off is identical:** new binary with `DOF_F_STOP := 0.0` vs today: byte-identical;
   - no `Error compiling` in the log (a clean build does not validate GLSL);
   - the measured focus distance is plausible for the room (compared with the floor plan; reported);
   - still render time within **+2%** of today's 502 s;
   - **strength pick:** f/11, f/8 and f/5.6, with 1:1 crops of the near rug / bench, the focused
     sofa area and the far window wall; the owner picks; the constant is set to that value.
4. **Full doctest suite** green before commit.

### 4. Shipping

- Engine: rebuild; the new binary goes to production's `godot/bin/`.
- Scripts: `dof.gd` is new; the `render.gd` change is applied **in place to production's copy**
  (it now carries the teammate's exterior exposure trim) and mirrored into
  `pipeline_references/render.gd`; production's file is not overwritten by the repo's.
- Video scripts and the video route are not touched.

## Out of scope

Video depth of field; night stills; aperture blades / bokeh shape; per-job JSON control; focus on a
named object; DoF in the daylight probe itself.

## Amendment and results 2026-10-13 (implementation, `docs/superpowers/plans/2026-10-13-pt-depth-of-field.md`)

**Rulings made in implementation:**
- **`RT_PRNG_LENS = 1u`, not `2u`:** in this sampler a 2D draw occupies one slot, so the init
  block's next free slot after the filter is 1 -- Cycles' `PRNG_LENS_TIME` position.
- **The focus distance is axial** (`-z` in camera space), the same plane the lens focuses on, not
  the length along each ray.
- **The pinhole ray keeps its pre-lens code verbatim** after an early-return lens branch. A
  version that merged the lens and pinhole origin/direction changed the GPU compiler's rounding
  of every pinhole ray (20.8% of pixels moved by up to 64 levels, mean 0.1; probe exposure
  24.909 -> 24.890), which "off is exact" forbids.

**Measured on job 209** (4K, 256 spp + OIDN, production scripts, relief knee 2.0):

| check | result |
|---|---|
| baseline repeatability (two renders) | byte-identical |
| engine off (radius 0) / script off (`DOF_F_STOP := 0.0`) | byte-identical to the baseline |
| exposure and relief with DoF on | unchanged (24.909, strength 0.837) |
| centre pixel (window wall, 6.33-6.45 m by the floor plan) | 6.45 m |
| focus (median of 32,215 central pixels, 99% hit) | 6.27 m |
| 1 cm aperture at 6.4 m (lens smoke test) | foreground detail -87%, window wall -7% |
| render time, warm shader cache | 500 s (baseline 498-504 s) |
| shader compile errors | 0 |

The first render after a new binary pays a one-off ray-tracing pipeline compile (+13-15 s in the
probe); later renders are back to normal.

**Owner's pick:** f/8 (`DOF_F_STOP := 8.0`; 29.0 mm at 45 degrees -> aperture radius 1.81 mm). On
job 209 autofocus lands on the window wall, so everything from about 2.25 m back stays sharp and
the near bench and rug soften slightly.
