# Transparent Shadows for Transmissive Surfaces — Design

**Date:** 2026-09-05
**Branch:** `vijay_PTEngine_V15_Glass`
**Status:** Design approved, ready for implementation planning

## Goal

Let shadow rays pass through transmissive surfaces, attenuated by Fresnel, so that
geometry enclosed in glass receives direct light. Today an aquarium interior, a
vitrine, or anything behind a pane is fully shadowed from every light in the scene.

## Non-goals

**This does not add caustics.** Light crosses each pane without bending, so a lit
tank interior is the outcome; focused light patterns on the substrate are not. This
is the treatment V-Ray calls "Affect Shadows" and Arnold gets from non-opaque
refractives. Caustics remain out of scope and unscheduled.

This also does not change BSDF sampling, the primary or indirect ray path, MIS
weights, or the raster path. Only the shadow query changes.

## Background: the defect

`raytracing_lights_inc.glsl:266`, `lights_trace_shadow_ray()`, traces with
`gl_RayFlagsTerminateOnFirstHitEXT | gl_RayFlagsSkipClosestHitShaderEXT` and returns
a boolean. The any-hit stage (`scene_raytracing_raygen.glsl`, `#[any_hit]`) lets a
ray through for exactly one reason: alpha cutout
(`alpha < 0.5 -> ignoreIntersectionEXT`). Transmission is never consulted, so any
transmissive surface is a full occluder.

Every light path funnels through that one function:

| Caller | Site |
|---|---|
| Analytic lights (3 call sites) | `raytracing_lights_inc.glsl:357`, `:566`, `:618` |
| Emissive mesh lights | `raytracing_emissive_inc.glsl:460` |
| Environment / sky NEE | `raytracing_closest_hit_common_inc.glsl:1643` |

Measured on `urbantestdark191_glass_render.png`: tank interior averages
`40, 47, 11` against a room wall at `147, 127, 115` — roughly 3.5x under-lit. On
`urbantestdark190_glass_render.png` the tank reads as blacked out but is not black
(mean `84, 79, 75`, only 5.4% of pixels below 16); it is a grey mirror, because
grazing reflectance dominates a panel with an unlit interior behind it.

Path termination on a bounce cap (`raytracing_closest_hit_common_inc.glsl:1428`,
which returns before NEE and therefore contributes nothing) was investigated as an
alternative cause and rejected: the near-zero pixel fraction is too low for it to be
the driver.

### Why this appeared now

Before the GLB alpha-glass conversion (`image_glb_creation.gd`,
`_convert_glb_alpha_glass`), glass carried `TRANSPARENCY_ALPHA*` and was dropped from
the TLAS at `render_raytracing.cpp:2853`. Shadow rays passed through because the
geometry was not there. Converting it to a real dielectric put a solid occluder in
front of every light. The darkness is the cost of that trade, and it is why the fix
belongs in the engine rather than in the pipeline.

## Background: what Cycles does

Cycles does not terminate on first hit. `shade_shadow.h:183`
(`integrate_transparent_shadow`) collects all hits along the shadow ray and walks
them accumulating throughput, returning `TRANSPARENT_SHADOW_EVAL_OPAQUE` only when
throughput reaches zero. Per surface it calls `surface_shader_transparency`
(`surface_shader.h:1053`):

```cpp
if (sd->shader_flag & SD_HAS_ONLY_VOLUME) { return one_spectrum(); }
if (sd->runtime_flag & (SR_TRANSPARENT | SR_RAY_PORTAL)) {
  return sd->closure_transparent_extinction;
}
return zero_spectrum();
```

Non-zero **only** for a Transparent BSDF closure. A Cycles Glass BSDF returns
`zero_spectrum()` and blocks shadow rays exactly as we do.

This matters for expectations. The aquarium GLBs author glass as `alphaMode: BLEND`
with base-colour alpha 0.098, which Blender's importer wires into Principled's
`Alpha` socket (`pbrMetallicRoughness.py:111`), producing a Transparent BSDF mix.
Cycles therefore passes about 90% of the light per pane and lights the interior.
**There is no Cycles code to port for dielectric shadow transmission** — we are
choosing a model Cycles does not have, not inheriting one.

Consequently `PATH_TRACER_QUALITY_ROADMAP.md:1412` is mis-scoped:

> "Shadow rays are still blocked by glass, so there are no caustics (section 6.2) —
> matches Cycles without its caustics path."

The "no caustics" half stays true. The "matches Cycles" half does not hold for the
content this engine actually renders, and the stated cost (a missing highlight)
understates the real one (no direct light inside any enclosed glass volume). This
line is rewritten as part of the work, not deleted.

## Architecture

`lights_trace_shadow_ray` changes signature from `bool` to `vec3`:

- `vec3(0.0)` — occluded
- `vec3(1.0)` — fully visible
- between — glass-filtered light

It splits into two phases against disjoint TLAS instance masks.

### Pass A — opaque occlusion

Unchanged logic, `TerminateOnFirstHitEXT` retained, cull mask narrowed from `0xFF`
to `RT_INSTANCE_MASK_OPAQUE`. Any hit returns `vec3(0.0)` immediately. This
preserves today's hot path and today's cost, including the `USE_SER`
`hitObjectTraceRayEXT` branch, which needs only its cull mask changed.

### Pass B — transmissive accumulation

Runs only if A cleared. An iterative inline `rayQuery` against
`RT_INSTANCE_MASK_TRANSMISSIVE`, advancing `tmin` past each hit:

```
atten = vec3(1.0)
tmin  = 0.001
for i in 0 .. RT_GET_MAX_TRANSMISSION_BOUNCE() - 1:
    rayQuery(tlas, TerminateOnFirstHit, RT_INSTANCE_MASK_TRANSMISSIVE,
             origin, tmin, direction, max_dist - 0.001)
    if no committed hit: break
    geometry_idx = rayQueryGetIntersectionInstanceCustomIndexEXT(rq, true)
    prim_id      = rayQueryGetIntersectionPrimitiveIndexEXT(rq, true)
    bary         = rayQueryGetIntersectionBarycentricsEXT(rq, true)
    hit_t        = rayQueryGetIntersectionTEXT(rq, true)
    geom = geometries[geometry_idx]; mat = materials[geometry_idx]
    get_triangle_indices_ex(geom, prim_id, i0, i1, i2)
    -- object-space normal via the existing helper, then to world space
    N_obj = fetch_tbn(geom, i0, i1, i2, bary).normal
    M     = mat3(rayQueryGetIntersectionObjectToWorldEXT(rq, true))
    N     = normalize(mat3(normalize(M[0]), normalize(M[1]), normalize(M[2])) * N_obj)
    -- eta must flip on the exit face, exactly as the BSDF does
    front = rayQueryGetIntersectionFrontFaceEXT(rq, true)
    eta   = front ? mat.ior : ((mat.ior > 0.0) ? (1.0 / mat.ior) : mat.ior)
    F     = fresnel_dielectric(dot(direction, N), eta, cos_t)
    atten *= mat.transmission * (1.0 - F)
    if max_component(atten) < RT_SHADOW_ATTEN_EPSILON: return vec3(0.0)
    tmin = hit_t * (1.0 + 1e-4) + 1e-4
return atten
```

`RT_SHADOW_ATTEN_EPSILON = 1e-4`. It must stay small: the value multiplies a light
contribution that may be thousands of nits for a sun, so an aggressive epsilon would
clip real light rather than prune a dead ray.

**`gl_ObjectToWorldEXT` is not available inside a ray query.** Every existing use in
this codebase (`raytracing_closest_hit_common_inc.glsl:44`, `:177`,
`raytracing_custom_fragment_inc.glsl:30`, `scene_raytracing_raygen.glsl:680`, `:834`)
is in a hit shader, where it is valid. Copying that idiom into pass B will not
compile — the ray-query form is
`rayQueryGetIntersectionObjectToWorldEXT(rq, true)`. This is the most likely
copy-paste error in the whole change.

The `tmin` advance is written out above because there is no existing helper for it.
`offset_ray_origin` (`raytracing_inc.glsl:536`) offsets a *position along a normal*
and does not apply here; the scale-relative form shown avoids re-hitting the same
surface at large `t` where a fixed epsilon would be swallowed by float precision.

Pass B is shared by both the SER and non-SER branches; it uses ray queries, not the
ray-tracing pipeline, so SER does not apply to it.

### Why a re-trace loop and not any-hit accumulation

The any-hit formulation (accumulate into the payload, `ignoreIntersectionEXT` to
continue) is the textbook approach and its order-independence is sound — the
accumulation is a product, multiplication commutes, and undefined any-hit invocation
order is therefore harmless.

It is rejected here for a specific reason: it requires clearing
`ACCELERATION_STRUCTURE_INSTANCE_FORCE_OPAQUE_BIT` on transmissive instances
(`render_raytracing.cpp:2991` sets it for any standard material with no alpha usage,
which converted glass is). That bit is per-instance and shared with the primary and
indirect rays, so clearing it would make **every** ray invoke any-hit on all glass —
paying for a shadow-path fix across the whole renderer. The loop confines the change
to the shadow path.

The cost is N traversals for N transmissive surfaces along the ray instead of one.
The mask rejects every non-transmissive instance, and N is small in practice (2-4
for a tank) and capped.

## Components

### 1. Instance mask constants and plumbing

`instance_masks` already exists and is plumbed to `inst.mask`
(`render_raytracing.cpp:1994`), but **every** instance is currently pushed as `0xFF`
— all eight bits are free.

Define in `scene_shader_raytracing.h`:

```cpp
RT_INSTANCE_MASK_OPAQUE       = 0x01,
RT_INSTANCE_MASK_TRANSMISSIVE = 0x02,
```

Replace the four `instance_masks.push_back(0xFF)` sites
(`render_raytracing.cpp:2739`, `:2996`, `:3040`, `:3112`) with the mask chosen from
the surface's resolved material: `RT_INSTANCE_MASK_TRANSMISSIVE` when
`transmission > 0.0`, otherwise `RT_INSTANCE_MASK_OPAQUE`.

These push sites sit inside the per-surface loop, so each surface is its own TLAS
instance and the mask is per-material. This was verified, not assumed — the design
depends on it.

Primary and indirect rays continue to trace with `0xFF`
(`scene_raytracing_raygen.glsl:89`) and are unaffected. The DLSS-RR specular probe
query (`raytracing_closest_hit_common_inc.glsl:1585`) likewise keeps `0xFF`.

### 2. Scene-level skip

Add `RT_FLAG_TRANSMISSIVE_GEOMETRY = (1 << 18)` to `scene_shader_raytracing.h`,
taking bit 18 from the free range (E3 took 15-17; 18-19 remain).

**This is an `RT_FLAGS` specialization-constant bit, not a `RAYGEN_SHADER_OPTIONS`
entry.** `RT_FLAGS` folds branches at pipeline specialization without adding shader
variants; `RAYGEN_SHADER_OPTIONS` injects `#define`s and is 2^N in its entry count.
E3 needed the latter because it had to remove struct fields and size arrays. Pass B
is a self-contained branch, so the spec constant suffices and the variant count does
not change. Getting this backwards would double the variant count for no reason.

Set it in `process_material` (`render_raytracing.cpp:1885-1898`) alongside the
existing E3 feature bits, from `transmission > 0.0`. It then reaches the shader
through the existing `scene_mask` accumulation and
`final_flags = p_rt_flags | scene_mask` (`:2607`). A scene with no transmissive
geometry compiles pass B away entirely.

Both `static_assert`s at `scene_shader_raytracing.h:130` and `:142` must gain the new
bit, and the comment at `render_raytracing.cpp:2604` stating that `feature_bits`
"only ever carries bits 15-17" becomes 15-18.

### 3. The shadow function and its callers

`raytracing_lights_inc.glsl:266` gets the new signature and both passes. The helpers
it needs are already in scope: `fresnel_dielectric` (`brdf_inc.glsl:482`) and
`fetch_tbn` (`raytracing_hit_inc.glsl:172`), because the closest-hit stage includes
`brdf_inc` (397), `raytracing_hit_inc` (404), then `raytracing_lights_inc` (427). No
include changes are required.

`ray_query_alpha_test` (`raytracing_lights_inc.glsl:243`) is the sibling pattern for
the material fetch — same file, same buffers (`geometries[]`, `materials[]`), same
`get_triangle_indices_ex` entry point. Pass B follows it.

The five call sites change from a boolean test to a throughput multiply. The
attenuation scales radiance only; it is not a directional density, so `mis_ray_pdf`
and all MIS weights are unaffected — the same argument the Russian Roulette block
already makes at `raytracing_closest_hit_common_inc.glsl:2124`.

## Edge cases

| Case | Handling |
|---|---|
| Total internal reflection | `fresnel_dielectric` returns `1.0`, so `atten *= 0` and the ray is occluded. Correct: a grazing pane blocks. |
| `ior == 0.0` | Legal glTF (`KHR_materials_ior` signal value). `fresnel_dielectric`'s caller contract (`brdf_inc.glsl:478-481`) forbids computing `1.0 / eta` before it returns, since an eager reciprocal is already an infinity. The exit-face flip above is guarded on `mat.ior > 0.0` for exactly this reason. |
| Exit face | A shadow ray crossing a pane hits the front face (air to glass, `eta = ior`) and then the back face (glass to air, `eta = 1/ior`). Both crossings must use the correct `eta` or the accumulated product is wrong on every pane. This mirrors what the BSDF already does at `raytracing_closest_hit_common_inc.glsl:1504`. |
| Self-intersection on `tmin` advance | `tmin = hit_t * (1.0 + 1e-4) + 1e-4`. Scale-relative, because a fixed epsilon is swallowed by float precision at large `t` and the loop would re-hit the same pane until the cap. No existing helper covers this. |
| More panes than the cap | Loop bounded by `RT_GET_MAX_TRANSMISSION_BOUNCE()`; on exhaustion return the accumulated attenuation rather than zero, so deep glass dims instead of going black. |
| Alpha-cutout surfaces | Unchanged. They stay on the opaque mask and the existing any-hit test. |
| Emissive glass | Unchanged; emission is not routed through the shadow query. |

## Testing

A gate scene at `pipeline_references/tests/pt_transparent_shadow_gate.gd`, following
`pt_transmission_gate.gd`. New files under `pipeline_references/tests/` are
permitted; the six existing `pipeline_references/*.gd` files are not to be staged or
committed.

**Primary gate.** A closed glass box, a light outside it, a probe surface inside.
Measure interior illuminance as a ratio against an identical control scene with the
glass removed.

- Current build: ratio is **0.00** — the interior receives no direct light at all.
- After the fix: a two-pane crossing at near-normal incidence should pass roughly
  96-98%, so the acceptance band is 0.90-1.00.

This gate can fail before the change and pass after, which is the property that makes
it worth having. A gate that cannot newly fail is not a gate.

**Grazing check.** The same box viewed so the shadow ray crosses a pane near grazing
must show attenuation heading toward zero, confirming Fresnel is actually being
applied rather than a flat factor.

**No-regression check.** A scene with no transmissive geometry must produce output
identical to the pre-change build, confirming the mask split and the scene-level skip
are inert. Note that renders are not bit-reproducible; use the established noise
floor, not equality.

**Timing.** Measure the production scene loop time before and after. E3's 273s
regression was caught this way and nothing cheaper would have caught it.

## Performance

Pass A is unchanged. Pass B runs only when the scene contains transmissive geometry,
and only for shadow rays that clear pass A. Each transmissive hit costs one traversal
against a mask that rejects all other instances, plus a `fetch_tbn` and one
`fresnel_dielectric`.

The `fetch_tbn` is the honest per-hit cost. An earlier draft of this design claimed
pass B could use a geometric face normal and skip it; there is no vertex-position
fetch helper in `raytracing_hit_inc.glsl`, so that would mean inventing one. Using
the existing helper is the smaller risk.

Roadmap section 152 notes light sampling is already the cost centre, so this
measurement is not optional.

## Documentation

Rewrite `PATH_TRACER_QUALITY_ROADMAP.md:1412` to scope the limitation correctly and
record that it is now fixed for direct lighting while caustics remain out of scope.
Add a closeout section following the E1/E3 pattern with the measured before/after
gate ratio and the timing delta.
