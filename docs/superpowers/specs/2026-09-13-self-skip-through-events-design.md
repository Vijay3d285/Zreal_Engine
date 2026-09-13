# Gap #26 — self-intersection skip by primitive after a through-event

**Date:** 2026-09-13
**Scope:** engine (raytracing shaders + TLAS instance flags) and one new gate.
**Approach:** A — skip-by-id on through-events only (chosen over Cycles-verbatim
any-hit-everywhere; see "Rejected").

## Problem

After a ray continues *through* a surface — the Transparent BSDF pass-through
or a transmissive-lobe sample — the next ray restarts with two safety margins
that exist to stop it re-hitting the surface it just left:

| margin | where | size at room-scale world coordinates |
|---|---|---|
| `t_min = 0.001` | `scene_raytracing_raygen.glsl:105` (both trace sites) | 1 mm |
| `offset_ray_origin` (Wächter–Binder, `int_scale = 256`) | `raytracing_inc.glsl:560`, applied at `raygen:114` | 0.24 mm at 10 m, 0.49 mm at 20 m |

Any real surface inside the larger of the two is never hit. The measured
casualty: the MarineDecorativeGlassAquarium's water box has its front face
**0.14 mm** behind the glass pane's inner face (`z = 14.040` vs `14.050`
model units × 0.014031 m/unit). The face is intact — with the glass removed
it renders as the solid teal mirror the asset authored — but with the glass
present the ray restarts past it. Production result: the tank water is clear
(no teal tint, no reflections) where Blender's is teal; the tank reads as a
"ghost". The pattern generalises to every layered thin geometry: water behind
glass, decals on panes, double glazing, curtains touching a window.

Each margin alone is sufficient to skip 0.14 mm, which is why the two
single-variable experiments (offset 256 → 8 ulps; `t_min` 1 mm → 0) each
changed nothing in the tank. Setting `t_min = 0` also turned the window
black: the pane was re-hit repeatedly until the transmission-bounce cap
terminated the path. The margins cannot simply be shrunk.

## What Cycles does

Cycles starts the next segment at the hit point with `t_min = 0` and
refuses to intersect the primitive it just left by identity
(`ray->self.object / self.prim`, `intersection_skip_self` in
`intern/cycles/kernel/bvh/util.h`). Distance plays no part, so a face 0.14 mm
behind a pane is found normally.

## Design

### Payload

`PathPayload` (`raytracing_inc.glsl`) gains two fields, 48 → 56 bytes:

```glsl
uint skip_geom; // gl_InstanceCustomIndexEXT of the surface just passed through, RT_SKIP_NONE if none
uint skip_prim; // gl_PrimitiveID of that triangle
```

`PathState` mirrors them; `path_pack` / `path_unpack` copy them verbatim.
`const uint RT_SKIP_NONE = 0xFFFFFFFFu;`. `trace_one_sample` initialises
both to `RT_SKIP_NONE`.

### Hit shader — where the skip is set

In `shade_and_bounce` (`raytracing_closest_hit_common_inc.glsl`) exactly two
sites produce a ray that continues through the surface, and both set the skip:

1. **Transparent BSDF pass-through** (the `m.blends && m.alpha < 1.0` branch,
   `~:1391`): `ps.skip_geom = gl_InstanceCustomIndexEXT; ps.skip_prim = gl_PrimitiveID;`
2. **Transmissive lobe taken** (`took_transmissive_lobe`, `~:2274`): same
   assignment, for both thin-walled (`thickness == 0`) and thick media.

Every other outcome (reflection, diffuse, sheen, internal reflection,
termination) sets both to `RT_SKIP_NONE`. The two assignments are made at the
single `ps.hit_t = gl_HitTEXT` write-back site so a future third through-event
cannot forget them: `ps.skip_geom = took_through ? gl_InstanceCustomIndexEXT : RT_SKIP_NONE`
where `took_through` is true for the pass-through branch and for
`took_transmissive_lobe`. (The pass-through branch returns early, so it
carries its own copy of the two lines.)

### Raygen — where the restart differs

`trace_one_sample` (`scene_raytracing_raygen.glsl:113-115`):

```glsl
vec3 hit_pos = ray_origin + ray_dir * ps.hit_t;
const bool skip_active = (ps.skip_geom != RT_SKIP_NONE);
ray_origin = skip_active ? hit_pos : offset_ray_origin(hit_pos, ps.offset_normal);
float t_min = skip_active ? 0.0 : 0.001;
```

and both `traceRayEXT` / `hitObjectTraceRayEXT` calls take `t_min` instead of
the literal `0.001`. A ray with no skip (every opaque bounce, every camera
ray) is byte-identical to today — the engine's standing rule that opaque
scenes do not move.

### Any-hit — where the skip is honoured

First statement of `main()` in the `#[any_hit]` stage, before the
`RT_CUSTOM_HIT_GROUP` split so both standard and custom hit groups get it:

```glsl
if (payload.skip_geom == gl_InstanceCustomIndexEXT && payload.skip_prim == gl_PrimitiveID) {
	ignoreIntersectionEXT;
}
```

`payload` is already declared `rayPayloadInEXT` in that stage.

### TLAS flags — which instances run any-hit

Blend instances already run any-hit (`is_alpha`). Transmissive instances
(converted glass, `mat_data->feature_bits & RT_FLAG_TRANSMISSIVE_GEOMETRY`)
are currently `FORCE_OPAQUE` and would never see the guard. At the four
`FORCE_OPAQUE` decision sites in `render_raytracing.cpp` (mesh `~:3096`,
multimesh `~:2911/2917`, and the custom-shader branches beside them), an
instance whose material carries `RT_FLAG_TRANSMISSIVE_GEOMETRY` keeps any-hit
enabled. Procedural instances (`~:2821`) stay `FORCE_OPAQUE`: they have no
any-hit stage and never produce a through-event.

A transmissive instance that now runs any-hit passes through the HG0 alpha
test; its `mat.flags` has no `RT_MAT_FLAG_BLEND` and its albedo alpha is 1.0
(the pipeline clears the texture), so `alpha < 0.5` is false and nothing is
discarded. The shadow-ray march (`raytracing_lights_inc.glsl` pass B) already
targets these instances by mask and is unchanged.

### Known property, inherited from Cycles

With `t_min = 0` a restart exactly on a shared triangle edge can hit the
*neighbouring* triangle of the same flat face at `t ≈ 0`, which is not the
skipped id and counts as a second pass-through. Cycles has the same property.
The gate's flat-pane probe bounds it: a single pane's transmitted mean must
not move by more than 0.5% relative to the current engine.

## Gate — `pipeline_references/tests/pt_thin_layer_gate.gd` + `_scene.tscn`

Built on `pt_transparent_alpha_gate.gd`'s fixture (camera at +5 looking down
−z, emissive backdrop at z = −5, 128 frames, its `_measure_crop` /
`_settle` helpers copied verbatim as that file itself does from its sibling).

| probe | fixture | expected (fixed) | reads today |
|---|---|---|---|
| T1 thin layer behind pane | white BLEND pane alpha 0.5 at z = −2; opaque unlit teal `(0.06, 0.50, 0.71)` emissive plate of the pane's size **0.1 mm** behind it (z = −2.0001); backdrop | `0.5·teal + 0.5·0` = teal/2 per channel, ±3% | backdrop through the pane (plate skipped) |
| T2 same, gap 5 mm | plate at z = −2.005 | identical to T1 within 0.5% | equals T1's *expected* (gap larger than both margins) |
| T3 single pane, no plate | pane alpha 0.5 over backdrop | 0.5 × backdrop, must equal the current engine's reading within 0.5% | (control for the edge double-pass property) |
| T4a converted-glass reference | opaque `transmission = 1.0`, `thickness = 0`, IOR 1.2 pane at z = −2; teal plate **5 mm** behind | plate through the pane (reads correctly today; this is the reference) | same as fixed |
| T4b converted-glass thin layer | same pane; plate **0.1 mm** behind | equal to T4a within 0.5% | plate skipped (reads backdrop) |

T1 and T4b are the falsifiable ones: red on the current engine by
construction, green only if the skip works. T2/T3 hold the fix to zero
collateral. T4 covers the transmissive-instance flag change.

### Whole-suite and asset checks

- The full `pipeline_references/tests` suite green with **no re-baselining**.
- `replay192_fishtank` at FHD: tank water gains teal (B−R in the water region
  moves positive from today's −1.3) and the window region does **not** darken
  (mean within 1% of today).
- `urbantestdark217` at FHD: frame mean outside the tanks within 1% of today.
- Doctest suite unchanged (no C++ struct mirrors are touched; `PathPayload`
  has no C++ twin).

## Rejected

- **B, Cycles verbatim** — any-hit on every instance and skip on every
  event. Costs any-hit traversal on all opaque geometry and moves every
  opaque bounce, invalidating every gate baseline for no visible gain here.
- **C, smaller margins** — measured: `t_min = 0` with the offset kept turned
  the window black (self re-hits until the bounce cap); offset 8 ulps with
  `t_min` kept changed nothing. Both together would still leave a margin,
  and the black-window failure shows distance-based skipping is fragile.

## Delivery

Engine files under `servers/rendering/renderer_rd/`, the new gate under
`pipeline_references/tests/`, a roadmap row for Gap #26 with a §11.20
write-up. Committed on the current branch with explicit `git add` paths.
