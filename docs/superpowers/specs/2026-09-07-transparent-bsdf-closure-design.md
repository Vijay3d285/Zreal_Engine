# Transparent BSDF Closure — Design

**Date:** 2026-09-07
**Branch:** `vijay_PTEngine_V15_Glass3`
**Status:** Design approved, ready for implementation planning

## Goal

Keep alpha-blended surfaces inside the path tracer. A material authored
`alphaMode: BLEND` currently leaves the TLAS entirely and is drawn by a second,
rasterized renderer; this makes it a first-class traced surface with a Cycles-style
Transparent BSDF.

## Non-goals

- **Not** retiring the raster transparent pass. It keeps running for anything still
  routed to it. This design only stops alpha-blended geometry from being ejected.
- **Not** caustics, refraction, or any change to the dielectric transmission closure
  (roadmap E1) or to transparent shadows (roadmap section 8).
- **Not** a change to opaque materials. `MaterialResult.alpha` defaults to `1.0`
  (`raytracing_material_eval_inc.glsl:26`), so an opaque material takes the existing
  code path by construction.

## Background: the defect

`gltf_document.cpp:3556` maps `alphaMode: BLEND` to
`TRANSPARENCY_ALPHA_DEPTH_PRE_PASS`. That produces a shader with
`uses_blend_alpha`, so `rt_uses_alpha_pass()`
(`scene_shader_forward_clustered.h:316`) is true, the surface gets
`FLAG_PASS_ALPHA` (`render_forward_clustered.cpp:5225`), and `build_tlas` drops it:

```cpp
// render_raytracing.cpp:2871
// Skip surfaces routed to the raster alpha overlay
if (surf->rt_pass_flags & ...FLAG_PASS_ALPHA) {
    surf = surf->next;
    continue;
}
```

It is then drawn by the raster transparent pass, which still runs unconditionally
(`render_forward_clustered.cpp:3083`, `// Skip transparent pass when raytracing
handles color.` followed by `if (true)`).

### Measured consequence

In `2b030deb_MarineDecorativeGlassAquarium_HP_high.glb`, nine materials split by
encoding alone:

| `alphaMode: OPAQUE` — in the TLAS, renders | `alphaMode: BLEND` — ejected, missing |
|---|---|
| `003/004/005_blueangelfish`, `003_starfish`, `cgaxis_..._01`, `cgaxis_..._03` | `003_lionfish`, `cgaxis_..._04`, `cgaxis_..._06` |

Before the GLB glass conversion both groups rendered, because the glass and the fish
shared the raster overlay. After it, the three `BLEND` materials disappear — verified
on the identical scene and camera (`urbantestdark180_fishtank`).

`003_lionfish`'s base-colour texture is **mean alpha 227 with only 9% of texels below
128** — an essentially opaque fish with a cut-out silhouette. Nothing about it needs
blending. It is on the second renderer purely because of how the asset was exported.

## Background: what Cycles does

Cycles has no second renderer. `alphaMode: BLEND` is wired to Principled's `Alpha`
socket by the importer (`pbrMetallicRoughness.py:111`), which in the kernel becomes a
mix against a Transparent BSDF. A `BLEND` lionfish is path-traced identically to an
opaque one.

Cycles bounds transparent chains with a **separate** `transparent_bounce` counter and
its own generous cap, precisely so passing through alpha layers does not consume the
diffuse/glossy/total budget. We cannot copy that directly — see Bounce accounting.

## Architecture: a stochastic transparent branch

At a hit, draw `u = rng_1d(rng, RT_PRNG_TRANSPARENT)`. If `u < (1.0 - m.alpha)`, take
the transparent branch:

- `ps.next_ray_dir` = the incoming direction, unchanged (`gl_WorldRayDirectionEXT`)
- `ps.offset_normal = -h.geometry_normal`, so `offset_ray_origin` in the raygen loop
  pushes the new origin *through* the surface rather than off it. This mirrors what
  the transmissive lobe already does at
  `raytracing_closest_hit_common_inc.glsl:2182`.
- throughput unchanged — the stochastic choice already carries the `(1 - alpha)`
  weight, so the branch weight is exactly 1
- **no diffuse, glossy or total bounce consumed**
- no NEE, no emission, no BSDF evaluation at this vertex

Otherwise, shade exactly as today.

Stochastic rather than accumulative is the load-bearing choice: it is order
independent, and it composites stacked alpha layers correctly. Three tinted decals in
a row each contribute their own shading at their own weight, which an
attenuate-and-continue formulation cannot reproduce.

`RT_PRNG_TRANSPARENT = 10u` (1D). Slot 10 is free — `raytracing_inc.glsl:322` states
"Slots 10, 12-15 are free."

## Components

### 1. TLAS routing (`render_raytracing.cpp`)

Remove the `FLAG_PASS_ALPHA` skip at `:2871-2875` so alpha-blended surfaces enter the
TLAS.

They take the **transmissive** instance mask, not the opaque one — see Component 6.
The mask predicate in `rt_instance_mask_from_features` therefore widens from
"transmission > 0" to "transmission > 0 **or** the material blends", so the shadow
query can attenuate through them instead of treating them as walls. The CPU-side
signal for the second half is `surf->shader->uses_blend_alpha`, available at the
triangle-surface site; the procedural (`:2756`) and multimesh (`:2837`, `:2843`)
sites need the equivalent and must be checked individually rather than assumed — a
prior phase in this project shipped a bug by assuming four such push sites were
interchangeable.

`ACCELERATION_STRUCTURE_INSTANCE_FORCE_OPAQUE_BIT` must NOT be set for them, so the
existing any-hit alpha-scissor test still runs. Verified: the standard-material branch
at `:3009-3011` sets that bit only when `!(uses_alpha_clip || uses_blend_alpha ||
uses_alpha)`, so blend materials already fall on the correct side and need no change.

### 2. Raygen loop bound (`scene_raytracing_raygen.glsl:65`)

This is the subtle part. The loop is:

```glsl
[[dont_unroll]] for (uint bounce = 0u; bounce <= p_max_bounces; bounce++) {
```

A transparent pass-through consumes a loop **iteration** even though it consumes no
payload bounce. Left as-is, the loop counter becomes the new exhaustion budget and a
surface behind two alpha layers goes dark — the identical failure mode already
diagnosed in this project, where a camera ray spent its whole budget crossing a pane
and the floor was terminated before NEE ever ran.

The bound becomes `p_max_bounces + RT_GET_MAX_TRANSMISSION_BOUNCE()`.

### 3. Bounce accounting

Transparent hits increment the existing transmission counter (bits 27-30) via
`inc_transmission_bounce`, reusing its cap, its `min(..., 15u)` clamp and the safety
contract documented at `raytracing_inc.glsl:155-168`.

The packed word has **no free bits**: `0-7` total, `8-15` diffuse, `16-23` glossy,
`24` sample-zero, `25` shadow-ray, `26` terminated, `27-30` transmission, `31`
inside-medium. Carving a dedicated counter would mean narrowing the diffuse or glossy
lane, and `inc_diffuse_bounce` is a raw `+ 0x101u` whose carry would spill into its
neighbour exactly as the transmission counter's own comment already warns. Sharing the
transmission budget avoids that surgery.

**Accepted cost:** glass crossings and alpha layers draw on one budget. A tank (four
glass crossings) plus alpha fish can exhaust it sooner than either alone. If that
bites, promote to a dedicated counter — the gate below will show it as a darkening.

### 4. Depth and DLSS-RR G-buffers — no change required

`write_primary_hit_depth` fires when `total_bounces == 0`
(`raytracing_closest_hit_common_inc.glsl:129`). Because a transparent hit does not
increment total, the next hit also sees `0` and overwrites. Depth, velocity and the
DLSS-RR G-buffers therefore end up describing the first **non**-transparent surface,
which is what they should describe. This falls out of the design; it is not an extra
mechanism.

### 5. The raster overlay must stop drawing what is now traced

**This must land in the same change or alpha surfaces render twice** — once traced,
once rasterized over the top. The raster transparent pass at
`render_forward_clustered.cpp:3083` runs unconditionally, and `_fill_render_list`
populates `RENDER_LIST_ALPHA` from `rt_pass_flags & FLAG_PASS_ALPHA` (`:1330`).

Since Component 1 makes those surfaces traced, the same predicate must stop putting
them in the raster alpha list under RT. The narrow form: in the RT (`p_alpha_only`)
path, skip surfaces now present in the TLAS.

### 6. Shadow rays must attenuate by alpha, not block

**Found in spec self-review, and it would otherwise have been a regression.** Pass B
of the transparent-shadows work attenuates a shadow ray by
`mat.transmission * (1.0 - F)` (`raytracing_lights_inc.glsl:465`) and never consults
alpha. Today an alpha-blended surface is not in the TLAS at all, so it casts **no**
shadow. If Component 1 admitted it on the opaque mask it would cast a **full** one —
a 90%-transparent fish casting a solid shadow. Both are wrong; the second is a
regression introduced by this change.

The per-crossing factor becomes a mix, matching the shading model:

```glsl
float pass_through = 1.0 - m_alpha;                       // Transparent BSDF share
float through_surface = m_alpha * transmission * (1.0 - F); // dielectric share
atten *= pass_through + through_surface;
```

This reduces correctly at both ends, which is what makes it safe to adopt wholesale:

- `alpha == 1.0` → `transmission * (1 - F)`, byte-identical to today's behaviour for
  every existing dielectric.
- `transmission == 0, alpha == 0.098` (the aquarium glass, and the fish) →
  `0.902`, which is the ~90% per pane Cycles passes.

Pass B already fetches the material's alpha in the same file:
`ray_query_alpha_test` computes `alpha *= mat.albedo_color.a` at `:254` after
sampling the base-colour texture, so the fetch pattern exists and needs no new
plumbing.

The transparent-shadow gate's four probes all use `transmission = 1.0, alpha = 1.0`
and therefore exercise only the first reduction. They must keep passing unchanged —
that is the regression check for this component — and the new gate below covers the
second.

## Edge cases

| Case | Handling |
|---|---|
| Opaque material | `m.alpha == 1.0`, `(1 - alpha) == 0`, branch never taken. Existing path, bit-identical. |
| Alpha-scissor (glTF `MASK`) | Unchanged. Still resolved by the any-hit test during traversal; it never reaches the shading branch. |
| `alpha == 0.0` | Fully transparent: branch always taken, ray continues, no shading. Correct. |
| Transmissive AND alpha-blended | The transparent draw happens first; if it loses, the dielectric closure runs as today. The two are independent mixes, as in Cycles. The shadow mix in Component 6 composes the same two terms in the same order. |
| Alpha-blended surface casting a shadow | Attenuates by `(1 - alpha) + alpha * transmission * (1 - F)` per crossing (Component 6). Today it casts no shadow at all, because it is not in the TLAS. |
| Emissive alpha surface | Emission is contributed only on the shading branch, so it is correctly weighted by `alpha`. |
| Chain longer than the cap | Bounded by the transmission cap and the widened loop bound; the path terminates rather than looping. |

## Testing

**Gate**, at `pipeline_references/tests/pt_transparent_alpha_gate.gd`, following
`pt_transparent_shadow_gate.gd`'s structure (`_ready`, `_new_env`, `_settle`,
`_render_accum`, `_measure_crop`, the control-is-black guard, and the
`visible`-toggle ratio technique).

- **Probe 1:** one pane at `alpha = 0.5` in front of a lit backdrop. Measured
  radiance must read `0.5` of the control, plus the pane's own contribution.
- **Probe 2:** two stacked panes at `alpha = 0.5`. Must read `0.25` — this is the
  probe that proves layers compose, and that a single-layer probe cannot catch a
  miscount.
- **Probe 3:** `alpha = 1.0` must be bit-identical to the same scene with the pane
  removed from the alpha family entirely — the opaque no-regression check.
- **Falsification:** forcing the branch never to be taken must make probes 1 and 2
  fail. A gate that cannot fail is not a gate.

**Scene check:** `003_lionfish` must reappear in `urbantestdark180_fishtank`. A
before/after on that exact scene already exists.

**No-regression:** a scene with no alpha-blended geometry must render identically.
Renders on this build are bit-reproducible (measured: rmse `0.000000`, `0.00%` of
pixels, two runs same project and binary), so this is an exact comparison — but
compare within the same project directory, as a cross-project comparison previously
produced a 20.39% delta that was entirely the project difference.

**Timing:** measure the production scene loop. Alpha surfaces now generate additional
traced hits where they previously generated none.

## Risks

1. **Double-draw** if Component 5 does not land with Component 1. Highest-severity
   sequencing risk in the change, and the reason those two are one task.
2. **Shared bounce budget** with glass crossings (Component 3), accepted above.
3. **Performance.** Every alpha surface now generates traced hits and an extra loop
   iteration. Foliage-heavy scenes are the worst case. Unmeasured until the timing
   check runs.
4. **Any-hit invocation cost.** Blend materials already do not carry `FORCE_OPAQUE`
   (verified at `render_raytracing.cpp:3009-3011`), but they were previously absent
   from the TLAS entirely — so this change adds any-hit invocations for them on every
   ray, not just shadow rays. Foliage-heavy scenes are the worst case.
5. **Shadow behaviour changes for every alpha-blended surface in every scene**, not
   only aquariums: they go from casting no shadow to casting an alpha-weighted one
   (Component 6). That is more correct, but it is a visible change to existing
   content and should be called out in the closeout rather than discovered.
