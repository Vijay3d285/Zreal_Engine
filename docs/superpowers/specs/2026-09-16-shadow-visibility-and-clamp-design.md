# Gap #30 — daylight cannot enter, and fireflies are unclamped

**Date:** 2026-09-16
**Status:** for review
**Branch:** `vijay_PTEngine_v23_PhaseE3`

## The complaint

Job 225 (Phase A, accumulated OIDN guides): the ceiling around the pendant's
wire is painted in streaks and the wire breaks up. 223 (DLSS-RR) hides it.

## What the raw image says

The 256-sample accumulation of 225's scene at FHD, *before* OIDN (robust
relative noise = MAD/median; fireflies = pixels above 4× the median):

| surface | median | robust noise | fireflies | brightest / median |
|---|---|---|---|---|
| ceiling (bounce-lit) | 0.132 | 15.1% | 0.12% | 36× |
| back wall | 0.335 | 15.7% | 0.03% | 53× |
| floor | 0.052 | 22.4% | 0.21% | 35× |
| marble table | 0.128 | 100% | 0.23% | 46× |

Cycles at 256 samples on such an interior sits around 3–6% with no 50×
outliers. OIDN turns 15% grain into strokes and 40× fireflies into blotches;
a one-pixel wire in a stroke-painted ceiling is the "pixel breakage".

## Decomposition (one light class removed per run, same scene, raw)

| run | frame mean | ceiling noise | ceiling brightest/median |
|---|---|---|---|
| baseline | 0.388 | 15.1% | 36× |
| sun removed | 0.386 | 12.9% | 8× |
| emissive meshes removed | 0.388 | — | — |
| **omni/spot lights removed** | **0.013 (63% of pixels black)** | — | — |
| sun + sky only | 0.013 | 34% | 7× |
| **`clamp_indirect = 10`** (Cycles' default; ours 0) | 0.387 | 15.0% | **2×**, fireflies 0.00% |

Three facts:

1. **The sun and sky light almost nothing.** The "day" interior is lit by the
   pipeline's 17 artificial omni/spot lights (fills, window "portal" spots, an
   IES lamp) — the rig built for the rasteriser, when daylight through
   windows did not work. That is where the grain comes from (many small
   lights, one picked per shadow ray), and it is a different lighting
   architecture from Blender's, whose reference still is lit by the world
   through the openings.
2. **Daylight is blocked at the window pane.** The sun-and-sky-only frame is
   black, yet the mirror and the fish tank reflect a bright window behind the
   camera: sky reaches the glass and stops there. Gap #22 made every glass
   surface block shadow rays, as Cycles does — correct for a vase, wrong for a
   window. Cycles has the same rule, and Blender archviz answers it every time
   with **Ray Visibility → Shadow off** on window glass (or a light portal).
   Godot has the same switch — `GeometryInstance3D.cast_shadow = OFF` — and
   the pipeline already sets it on window-asset glass
   (`_disable_shadow_casting_recursive`, `image_glb_creation.gd:6773`). **The
   tracer ignores it.**
3. **Fireflies are the sun's caustic paths**, and Cycles' default indirect
   clamp of 10 removes them at no measurable cost to the image.

## Design

### 1. The tracer honours `cast_shadow` (engine) — Cycles' shadow ray visibility

Cycles: `object.visibility & PATH_RAY_SHADOW`; a shadow ray never intersects
an object without the bit. Ours: shadow rays already trace by TLAS instance
mask — pass A uses `RT_INSTANCE_MASK_OPAQUE` (0x01), pass B walks
`RT_INSTANCE_MASK_TRANSMISSIVE` (0x02), camera and bounce rays use 0xFF
(`scene_shader_raytracing.h:142-145`, `raytracing_common_inc.glsl:91-95`).

- New mask value `RT_INSTANCE_MASK_NO_SHADOW = 0x04`, both sides. An instance
  whose `cast_shadows == SHADOW_CASTING_SETTING_OFF` gets **only** this bit:
  camera and bounce rays (0xFF) still hit it — it is seen, refracts, reflects —
  but neither shadow pass can. Light passes through it at 100%, as through a
  Cycles object with shadow visibility off (no Fresnel loss; that is Cycles'
  behaviour too).
- Plumbing follows the storage pattern: `RenderGeometryInstance` gains
  `virtual void set_cast_shadows_setting(RSE::ShadowCastingSetting)`;
  `RenderGeometryInstanceBase` stores it (`cast_shadows_setting`, default
  ON); `RendererSceneCull::instance_geometry_set_cast_shadows_setting`
  (`renderer_scene_cull.cpp:1344`) calls it beside
  `set_cast_double_sided_shadows`; the dummy storage stub is added. The four
  `instance_masks.push_back(rt_instance_mask_from_features(...))` sites in
  `render_raytracing.cpp` OR-replace the mask with `NO_SHADOW` when the
  instance's setting is OFF (the mesh, multimesh and procedural sites; the
  predicate becomes one helper `rt_instance_mask(inst, feature_bits, blend)`).
- `SHADOW_CASTING_SETTING_SHADOWS_ONLY` (Cycles' camera visibility off) is
  **out of scope**: the pipeline's only user is the procedural window-grid
  caster, disabled (`ENABLE_PROCEDURAL_WINDOW_GRID_CASTER = false`). Recorded
  as a follow-up; today such an instance is simply visible.

### 2. Indirect clamp 10 (pipeline)

`image_glb_creation.gd`: `const PHASE_A_CLAMP_INDIRECT := 10.0` with a
comment: Cycles' `sample_clamp_indirect` default, measured on 225 — fireflies
0.12% → 0.00%, brightest/median 36× → 2×, medians unchanged to 4 digits. The
file's existing "KNOWN OPEN ITEM" about the clamp only covering the env-NEE
half of a sky hit stays; at 10 it is inert on the measured surfaces (the
medians did not move), and it is re-measured in the asset check.

### 3. The lighting rig — a decision for the user, with the render to decide on

With daylight entering, the 17 artificial lights double-light the room. That
is a look change the plan does not make on its own: it renders 225's scene
three ways — the current rig with the fix, daylight only (`ZR_LIGHTS_SKIP`
knob kept as an *engine debug env var* for exactly this), and the rig with the
window portal spots removed — and hands the user the three images with the
noise table. The pipeline change that follows is the user's call.

## Gate: `pt_shadow_visibility_gate`

Sky furnace (white panorama, radiance 1), a large diffuse grey floor
(albedo 0.5), an **opaque** black quad hovering 0.5 m above it and covering
the whole sky above a 64×64 px measurement crop, camera looking down at the
floor. Accumulate 256 frames, NEE on.

- **V1 control**: quad `cast_shadow = ON` → the crop reads near 0 (the only
  light is what leaks around the quad's edges): ≤ 0.15.
- **V2 fix**: quad `cast_shadow = OFF` → shadow rays ignore it: the crop reads
  the open-sky floor value (0.5 × 1.0 = 0.5) within 2%, while a second crop
  that includes the quad itself still shows it black (camera rays see it).
- **V3 unchanged**: a *transmissive* glass quad with `cast_shadow = ON` still
  blocks (Gap #22): ≤ 0.15. Guards against the mask change leaking into the
  pass-B path.

V2 reads ≤ 0.15 on today's build (red); V1/V3 are the two-sided guards.

## Asset check

225's scene at FHD, raw + OIDN, before/after, with the decomposition table
re-run: sun-and-sky-only must no longer be black; the full rig's ceiling
noise, fireflies and brightest/median recorded; the three lighting-rig renders
of §3 delivered to the user.

## Out of scope

- Light portals (Cycles' `is_portal`): the shadow-visibility switch plus env
  NEE already lets the sky in through a pane; a portal only improves sampling
  and can come later.
- Many-light sampling (a light tree) for the remaining grain from the
  artificial lights: separate gap, and moot if the rig goes.
- `SHADOWS_ONLY` camera invisibility: follow-up, noted above.
