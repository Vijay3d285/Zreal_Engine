# Phase F1 + F3 — Cycles' bump-map correction, and a flat-colour world

**Date:** 2026-09-17
**Status:** for review
**Branch:** `vijay_PTEngine_v24_PhaseAs`
**Roadmap:** Phase F — F1 (Gap #15), F3; §4 of `PATH_TRACER_QUALITY_ROADMAP.md`

## What the roadmap said, and what the source says

Roadmap F1 reads: *"Offset normals replacing the biased bump mirror … Cycles
uses offset/position normals, no bias."* Re-read on 2026-09-17 against
`intern/cycles/kernel/closure/bsdf_util.h`, `bsdf.h`, `bsdf_microfacet.h` and
`svm/closure.h` (5.3.0-alpha): **Cycles has no "offset normals".** It handles a
normal-mapped surface at grazing angles with three separate rules, and our
tracer implements none of them. It has two rules of its own instead, and both
are divergences.

| | Cycles | Ours today |
|---|---|---|
| Shading normal at grazing | `ensure_valid_specular_reflection` (`bsdf_util.h:322`): rotate N toward the **true face normal** Ng *only as far as needed* for the mirror direction to clear the surface; **glossy/coat/SSS closures only**; gated by the material's *Bump Map Correction* (default on) and by N ≠ Ng | `clampShadingNormal` (`brdf_inc.glsl:1884`): lerp N toward the **smooth vertex normal** for *every* lobe once geometry NdotV < 0.4 — normal-map detail flattens over the outer 66° of view angle whether or not anything would have gone wrong |
| BSDF sample below the surface | rejected — zero weight, path ends (`bsdf_microfacet.h:863`, `bsdf_diffuse.h:65`); the test is against Ng, the true face | `recoverBelowHemisphereSample` (`brdf_inc.glsl:1928`): mirror the direction across the plane and **keep the rejected sample's weight** — its own comment says "energy-non-conserving (over-bright at grazing angles)"; the test is against the smooth normal |
| Light leaking through a bump | `bump_shadowing_term` (`bsdf.h:86`): reject any direction on the far side of the *smooth* normal from the bump normal (all closures, eval only for glossy; eval+sample for diffuse), and soften the diffuse lobe with a GGX-G1 term keyed to how far the bump normal tilts from the smooth one | none |

Also from the source: Cycles keeps two normals per hit — `sd->Ng` (the
triangle's plane) and `sd->N` (smooth, vertex-interpolated), and the bump
normal is a third. Our `HitData.geometry_normal` is the **smooth** normal
(`raytracing_closest_hit_common_inc.glsl:68`, `normal_matrix * attrs.normal`);
the tracer never computes the true face normal, so every "geometry" test in
the integrator is really a smooth-normal test.

Roadmap F3 is not a Cycles gap; it is a Godot-side trap. A Cycles world with a
flat colour is a constant background. Ours renders **black** for any ray that
misses geometry: `render_raytracing.cpp:4303` fetches a radiance map only when
the Environment has a `Sky` RID, and `BG_COLOR` / `BG_CLEAR_COLOR` set none,
so binding 7 falls back to `DEFAULT_RD_TEXTURE_BLACK`. The rasteriser meanwhile
clears to `bg_color × bg_energy_multiplier × bg_intensity`
(`render_forward_clustered.cpp:2692`).

## Approaches considered

**A — port Cycles' three rules, with a true face normal (recommended).**
Delete the clamp and the mirror; add Ng to `HitData`; transcribe
`ensure_valid_specular_reflection` and `bump_shadowing_term`; reject below-Ng
samples. One divergence remains, stated below. Cost: three vertex-position
reads per hit (Cycles gets Ng free from its intersector).

**B — delete the mirror only.** Terminate on rejection, keep the 0.4 clamp.
Removes the over-brightness but keeps the visible divergence — the flattened
normal-map detail at grazing angles — which is the quality the user sees.
Rejected.

**C — per-lobe normals.** Cycles gives the glossy closure the corrected N and
the diffuse closure the raw bump N. Our BRDF library evaluates all lobes from
one `N` (`prepareBRDFData`); splitting it means plumbing a second normal
through every eval/sample/pdf entry point and the three-lobe MIS. Deferred:
A applies the rotated N to every lobe, the rotation fires only when the
mirror direction would enter the surface (grazing, high-frequency bumps),
and the gate below measures what that costs against Cycles. If the diffuse
arm reads outside the bar, C is the follow-up.

## Design

### 1. A true face normal in `HitData` (engine, GLSL)

`HitData` gains `vec3 face_normal` — Cycles' `Ng`. For a triangle hit it is
the cross product of the two world-space edges built from
`rt_fetch_vertex_position` (`raytracing_vertex_inc.glsl:16`, already used by
the emissive light sampler) transformed by `mat3(gl_ObjectToWorldEXT)`,
normalised, and flipped with the same `is_front_face` rule as
`geometry_normal`. For procedural (intersection-shader) geometry it equals
`geometry_normal`. `geometry_normal` keeps its meaning (smooth normal,
Cycles' `sd->N`) and its name — renaming it touches ~40 sites for no
behavioural gain; a comment at the struct states the mapping.

Three uses move from `geometry_normal` to `face_normal`, each one a place
where Cycles tests `Ng`:

- `evalIndirectCombinedBRDF`'s "under the hemisphere" test (`brdf_inc.glsl:4097`);
- `sampleTransmissiveLobe`'s `wrongNg` guard (`brdf_inc.glsl:1787`);
- the SSS entry test `entry_ok` (`raytracing_closest_hit_common_inc.glsl:2315`).

Ray-origin offsets (`offset_ray_origin(h.hit_pos, h.geometry_normal)`) stay on
the smooth normal. Gap #26 was about exactly those margins; they are not
touched here.

### 2. `ensure_valid_specular_reflection` replaces `clampShadingNormal`

`brdf_inc.glsl` gains `ensureValidSpecularReflection(Ng, V, N)`: a line-for-
line transcription of `bsdf_util.h:322-395` (threshold
`min(0.9·dot(V,Ng), 0.01)`, the quartic in `N'.z`, the `Ix < 0` root choice,
`safe_sqrt` guards). `shade_and_bounce` computes

```
vec3 N = (m has normal map && N != Ng) ? ensureValidSpecularReflection(h.face_normal, V, m.normal) : m.normal;
```

and that `N` feeds everything the clamped normal fed before: sampling, NEE,
env NEE, emissive NEE, the MIS pdf, the SSS entry normal, the DLSS-RR and
OIDN guide normals. (Divergence, from approach C: Cycles' diffuse closure
keeps the raw bump normal; ours takes the corrected one.)

`clampShadingNormal`, `RT_SHADING_NORMAL_CLAMP_ENABLED` and
`RT_SHADING_NORMAL_CLAMP_THRESHOLD` are deleted. The debug vis modes that
reconstruct "the sampler's N" (22, 32, 35, 40, 41 and the mode at
`raytracing_closest_hit_common_inc.glsl:761`) call the new function with the
same arguments `shade_and_bounce` uses, so they keep reporting the production
normal. Vis mode 22 keeps its four colours; "clamped" now means "corrected".

### 3. Below-surface samples are rejected, not mirrored

`recoverBelowHemisphereSample`, `mirrorDirectionAcrossPlane`,
`RT_BELOW_HEMISPHERE_RECOVERY_ENABLED` and the `recovered_sample` MIS-weight
policy in `shade_and_bounce` are deleted. A sample that
`evalIndirectCombinedBRDF` rejects terminates the path — Cycles'
`LABEL_NONE`. The shading-hemisphere zero-weight test from Gap #19 is
unchanged.

### 4. `bump_shadowing_term` in the BRDF library

`MaterialProperties` gains `float3 smoothNormal` (world space, flipped like
`geometry_normal`; zero-length disables the term, the same convention as
`tangent`). Every construction site sets it from `h.geometry_normal` (the
`brdf_mat` at `:1660` and the four `dbg_mat` blocks). `brdf_inc.glsl` gains

```
float bumpShadowingTerm(float3 Ns, float3 N, float3 I, bool isDiffuse, bool isEval)
```

transcribed from `bsdf.h:86-140`: returns 1 when `Ns == N` or `Ns` is
zero; returns 0 when `dot(Ns,I)·dot(Ns,N)·dot(N,I) < 0` and
(`isEval || isDiffuse`); for a diffuse lobe returns
`G1_GGX(saturate(0.125·tan²θd), |dot(Ns,I)|)` with `cosθd = |dot(Ns,N)|`
(`bsdf_G<GGX>` = `1 / (1 + Λ)`, `Λ = ½(√(1 + α²tan²θ) − 1)`), else 1.

Applied in exactly the two places Cycles applies it:

- `evalCombinedBRDFSeparate(N, L, V, material, …)` — the one eval every NEE
  site and the BSDF-hit MIS eval already go through (rect / omni-spot /
  directional in `raytracing_lights_inc.glsl`, env at `:1855`, emissive at
  `raytracing_emissive_inc.glsl:490`): all four lobe outputs are zeroed on
  the sign test; the diffuse output is multiplied by the G1 term.
- `evalIndirectCombinedBRDF`'s diffuse branch: `sampleWeight` multiplied by
  the term with `isEval = false`, after `rayDirection` is back in world space.

The pdf is not touched — Cycles multiplies `eval` only. No NEE signature
changes; no new plumbing outside the two BRDF entry points.

### 5. A flat-colour world for the tracer (engine, C++)

In `render_raytracing.cpp`'s binding-7 block: when the Environment has no
`Sky` and its background is `BG_COLOR` or `BG_CLEAR_COLOR`, bind a 1×1
`R16G16B16A16_SFLOAT` texture owned by `RenderRaytracing` holding the linear
colour the rasteriser would clear to — `bg_color.srgb_to_linear()` (or the
viewport's default clear colour for `BG_CLEAR_COLOR`) `× bg_energy_multiplier
× bg_intensity` — scaled by whatever the `BG_SKY` radiance map carries that the
shader's `IBL_exposure_normalization` does not (the plan pins this by
measurement: probe C below demands equality with the `BG_SKY` workaround, so
a wrong factor cannot pass). The texture is re-uploaded when the colour
changes and its version token feeds `env_cdf` exactly as the sky's does, so
env NEE builds a (uniform) distribution over it. `radiance_border_size` is 0
for it. Every other background mode keeps today's black fallback.

Nothing changes in the shaders: `env_sky_radiance`, the miss shader and
`env_sample` all read binding 7. The gate `_new_env` workaround (a
`PanoramaSkyMaterial` over a flat image) keeps working and is no longer
required.

## Gate: `pt_bump_correction_gate` (new; suite goes to 20)

512 × 288, 256 accumulated samples, no denoiser, no clamp, MSAA / FXAA / TAA /
debanding off (memory: gates reading the viewport inherit the project's AA).
Cycles half: `tools/cycles_comparison/cycles_bump_grazing.py`, the same scene
under Blender 5.2.1 (CPU, 256 samples, no denoise, clamp 0, Bump Map
Correction on — its default). The normal map is the energy gate's
`_bump_normal_map` sine pattern (symmetric in x and y, so a tangent-sign
difference between the engines cannot move a patch mean), written once to a
PNG that both engines load at strength / `normal_scale` 1.

| probe | scene | reads | bar |
|---|---|---|---|
| **A — energy** | white furnace (uniform world 1.0), normal-mapped plane, dielectric albedo 1.0 roughness 0.4, camera 80° off the normal | patch mean | ≤ 1.0 + 0.5%. **Expected red today**: the mirror hands rejected samples their weight, so the plane should exceed 1 — the plan captures the old-binary reading first, and if it does not exceed 1 the probe is redesigned before anything is built (memory: gates must be falsifiable). |
| **B — Cycles, grazing** | same plane, world 0.5, metallic 0 (B1) and metallic 1 roughness 0.4 (B2), camera 80° | patch mean vs Cycles | within a bar set from the first measurement and written into the gate as a number (target ≤ 3%; if B1 — the diffuse arm — needs more than 3%, that is approach C's evidence and is recorded, not hidden). |
| **B0 — Cycles, normal incidence** | B1 at 10° off the normal | patch mean vs Cycles | ≤ 1%. The correction must not fire away from grazing. |
| **C — flat world (F3)** | Lambertian sphere, `BG_COLOR` (0.3, 0.5, 0.7) energy 1.5, env NEE on | ratio to the same scene under `BG_SKY` + flat `PanoramaSkyMaterial` of the same colour | 1.00 ± 1%. **Red today**: 0.0. |
| **D — no-normal-map control** | the energy gate's `rough` and `diffuse` spheres, unchanged | | recorded, not barred here — see below. |

**Existing gates that will move, and why that is allowed.**
`pt_energy_gate`'s `bumpy` reference (1.41124) is the recovery probe by its
own description; it must move and is re-captured with this section cited,
the same way Gap #17 and Gap #21 re-captured it. `rough` (smooth-shaded
metal sphere) may move slightly: the sampler's below-surface test is now
against the true face, which on a smooth-shaded sphere rejects a band of
samples at the terminator that the smooth-normal test let through — Cycles'
behaviour. Any other gate moving is a defect. The whole suite is run on the
old binary first (memory: run an old binary first), in a connected desktop
session.

**Cost.** Three extra `rt_fetch_vertex_position` reads per closest hit,
always. Measured as E1 §7.2 measured its flag: frame time on job 217's scene,
before and after, at 1080p.

## Asset check

Job 226's scene (the fish / pendant interior) re-rendered through the still
route on the new binary, set beside the 226 output. What to look for: the
wall and floor normal maps at the edge of the frame (grazing) keep their
relief instead of going flat; no new bright rims on bumpy surfaces at
silhouettes.

## Out of scope

- Approach C (per-lobe normals) — follow-up only if probe B1 says so.
- A per-material "Bump Map Correction" switch. Cycles' is on by default and
  glTF has no such flag; the tracer applies it whenever a normal map is
  present.
- Cycles' `shadow_terminator_shading_offset` (`shift_cos_in`) and the
  geometry-offset terminator fix — separate object-level settings, not part
  of bump correction.
- F2 volumetrics (Gap #16) — its own spec.
- `BG_CANVAS`, `BG_KEEP`, `BG_CAMERA_FEED` — stay black in the tracer.
