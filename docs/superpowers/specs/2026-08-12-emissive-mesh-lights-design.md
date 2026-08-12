# Emissive-Mesh Light Sampling (Roadmap C1) — Design

**Status:** approved, not yet implemented
**Roadmap item:** C1, *Gap #5* — the last item in Phase C (C2 and C3 are done).
**Branch context:** `vijay_PTEngine_v10_PhaseC`, on top of C2.

---

## 1. Problem

An emissive surface currently contributes only when a BSDF ray happens to land on
it. `shade_and_bounce` adds `ps.throughput * m.emissive` at the hit
(`raytracing_closest_hit_common_inc.glsl`) and nothing samples emissive geometry
directly. A room lit by a glowing panel therefore converges at the rate at which
random cosine-sampled bounces stumble into the panel — slowly, with hotspot
speckle, and worse the smaller the panel is.

C1 makes emissive geometry NEE-sampleable and MIS-combines it against those BSDF
hits.

**C1 is also the last gate on extending MIS beyond the environment.** Emissive
meshes are real TLAS geometry and are therefore reachable by *both* strategies —
the same double-counting situation the sky had before C3. (Analytic lights are
not in this category and never will be: omni, spot, directional and
`RT_LIGHT_TYPE_RECT` are pure buffer data with no TLAS presence, so no BSDF ray
can reach one. They correctly carry no MIS weight, permanently.)

## 2. Purpose and scope in THIS project

**Purpose: correctness for authored emissive content** — GLB-authored neon
signs, TVs, monitors, backlit panels and glowing decor currently light nothing.

### 2.1 The pipeline interaction, stated up front

`pipeline_references/image_glb_creation.gd` authors emissive materials in
`_apply_light_fixture_emission`, gated on the material or surface name containing
one of `bulb / filament / led / emiss / glow / neon`. Two facts about it govern
this design:

- **Day renders disable emission outright** (`new_mat.emission_enabled = false`),
  so C1 does nothing for them.
- **Night renders represent every fixture twice.** The function makes the bulb
  surface glow, and the caller then creates an `OmniLight3D` or `SpotLight3D` at
  the same fixture unconditionally — `emissive_surface_found` is captured but used
  only for a diagnostic `print`. Today that is harmless, because the emissive mesh
  contributes only via rare BSDF hits while the analytic light does the work.
  **C1 would turn each of those surfaces into a second, fully-sampled light**, and
  night renders would get materially brighter.

That is a content-level double-representation which C1 exposes rather than
causes — structurally identical to the `SKY_MODE_LIGHT_AND_SKY` sun-disc
double-count that forced `SKY_MODE_LIGHT_ONLY`. The engine cannot detect it: an
emissive mesh and an analytic light are independent objects with no relationship
the renderer can see.

### 2.2 The control

A project setting, following B4's `russian_roulette_min_bounce` precedent:

```cpp
GLOBAL_DEF(PropertyInfo(Variant::BOOL, "rendering/pathtracer/emissive_mesh_lights"), false);
```

**Default `false`.** On the day this lands, nothing about existing renders
changes: no buffers are allocated, no compute pass is dispatched, and the
closest-hit path is byte-identical to today. It is enabled per project when
authored emissive content should light the scene — at which point the fixture
double-representation is the enabling user's problem to check, and §7 records it.

**Accepted cost of this default:** the feature ships inert, so it is exercised
only when someone deliberately enables it. The gates in §6 run it explicitly for
that reason.

### 2.3 Out of scope

- **Not a light tree.** A flat CDF over emissive instances, as C2 did for
  analytic lights.
- **No per-triangle area weighting.** §4.2 explains the trade and records the
  upgrade path.
- **No pipeline change.** The fixture double-representation is documented, not
  fixed here.
- **No portal sampling, no volumetric emission, no emissive participating media.**
- **Analytic-light NEE is untouched**, including its correct absence of a MIS
  weight.

## 3. What gets built

One new storage unit, `servers/rendering/renderer_rd/storage_rd/emissive_lights.{h,cpp}`,
mirroring `env_cdf.{h,cpp}`'s shape and lifetime.

### 3.1 Instance selection (CPU)

Done next to `gather_lights` in `render_raytracing.cpp`, where the material and
transform data already sit. An instance qualifies when

```
(mat.flags & RT_MAT_FLAG_HAS_EMISSION_TEX) != 0
  || luminance(emission_color) * emission_strength > 1e-4
```

Capped at `RT_EMISSIVE_INSTANCES_MAX = 256`, keeping the highest-power entries —
the same overflow policy `gather_lights` uses for its 64 analytic lights, and
carrying the same known failure mode (a bright emitter ranked 257th is dropped
entirely).

**This is sound because geometry index ↔ TLAS instance is strictly 1:1.**
`geometry_data.push_back(surf_data->geometry)` runs once per instance, *including
inside the multimesh loop*, and `blas_transforms` holds the matching per-instance
world transform. No new indexing scheme is needed.

`RT_EmissiveInstance` (std430, C++/GLSL twins, `static_assert` on size as the
project requires) carries: geometry index, `prim_count`, object→world as a
transposed `mat3x4`, emission RGB, and — filled by the build pass — total world
area and power.

### 3.2 Area and CDF (GPU compute)

Vertex data lives behind BDA pointers, so only the GPU can reach it.
`shaders/raytracing/emissive_area_build.glsl`, two passes:

1. **Area reduction.** One workgroup per emissive instance, reducing
   `Σ ½‖e₁ × e₂‖` over its triangles **in world space** — the transform is
   applied per vertex. Scaling an object-space area by `s²` is wrong under
   non-uniform scale and is not done. Writes `total_area` and
   `power = luminance(emission) * total_area`.
2. **CDF.** A single workgroup builds the prefix sum over ≤256 entries and writes
   `total_power`, exactly the structure of `env_cdf_build.glsl`'s marginal pass.

### 3.3 The reverse-lookup table

`int emissive_slot[]`, indexed by geometry index, `-1` when that instance is not
emissive. Sized to the instance count. This is what lets a BSDF ray that lands on
a glowing surface recover `P(inst)` in O(1) for its MIS weight (§5).

### 3.4 Rebuild trigger

A token over **everything the distribution depends on** — the emissive instance
set, their transforms, and their emission values — not any single handle.

This is deliberate. The C3 phase lost a day to keying the environment CDF on a
RID that was stable while its contents were still empty: the first build baked an
all-zero distribution and the trigger never fired again, silently disabling sky
NEE for the rest of the run. `gather_lights` already walks all three inputs, so
computing the token is cheap.

## 4. Sampling

### 4.1 The draw

1. One 1D Sobol sample picks the instance from the CDF.
2. The remainder within the selected CDF bucket is **rescaled to `[0,1)`** and
   reused to pick a triangle uniformly. The remap must be exact; a truncated or
   biased remap correlates the triangle choice with the instance choice.
3. One 2D Sobol sample picks a point uniformly on that triangle
   (`√u₁` warp to barycentrics).

### 4.2 Why uniform over triangles

`pdf_A = P(inst) × (1/prim_count) × (1/area_tri)`.

No per-triangle buffer exists anywhere in this design: `area_tri` is recomputed
where it is needed, from vertices the shader already has. That is what keeps both
the build pass and the reverse lookup small.

**The cost, stated plainly:** uniform triangle selection is high-variance when one
triangle holds most of a mesh's emissive area — a surface with one large triangle
and many tiny ones gives the large one `1/prim_count` of the draws while it
carries most of the light, and the estimator divides by a correspondingly tiny
pdf. It is unbiased throughout; it is a variance failure, not a correctness one.
Even tessellation (a TV quad, a sphere bulb, a panel) is unaffected.

**Upgrade path if measurement shows this matters:** a per-instance area prefix sum
over triangles, making selection proportional to area. Because emission is
constant per instance, that is mathematically the exact flat power distribution
over all emissive triangles. It changes §4.1 step 2 and the `area_tri` term of
the reverse lookup, and nothing else.

### 4.3 Sampler dimensions

Slots 0–7 are fully occupied (`SURFACE_BSDF` 0-1, `LIGHT` 2-3, `LOBE` 4,
`TERMINATE` 5, `LIGHT_SELECT` 6, `ENV` 7). C1 needs 3 more, so
**`RT_PRNG_BOUNCE_NUM` widens from 8 to 16**, which is exactly what the note at
`raytracing_inc.glsl:260-262` says the next addition must do, and matches Cycles.

`rng_next_bounce` advances `offset` by `RT_PRNG_BOUNCE_NUM`, so widening the block
changes which Sobol dimension every later bounce draws from. **This re-stratifies
the whole integrator and gets its own neutrality gate (§6.1), not a constant
bump waved through.**

New: `RT_PRNG_EMISSIVE_SELECT` (1D), `RT_PRNG_EMISSIVE_POINT` (2D).

### 4.4 Contribution

Following the shape `lights_eval_rect_light` already uses:

```
cos_θ_light = dot(-L, tri_normal)          // FRONT FACE ONLY; <= 0 rejects
pdf_ω       = pdf_A × dist² / cos_θ_light
contribution = f_brdf × L_e × w_mis / pdf_ω
```

Front-face-only matches the existing rect-light behaviour in this codebase
(`cos_theta <= 1e-5` rejects there).

The shadow ray traces to exactly `dist`, so it does not hit the emitter it is
sampling — the same convention as the rect path.

`L_e` is `emission_color × emission_strength`, times the emission texture
sampled at the point's interpolated UV when `RT_MAT_FLAG_HAS_EMISSION_TEX` is
set. The **weight** treats a textured emitter as unit radiance (the C++ side
already forces `emission_color = (1,1,1)`, `emission_strength = 1.0` for that
case), while the **value** is exact. Texture variation therefore costs variance,
never bias.

### 4.5 `L_e` must be composed identically to `m.emissive` — including exposure

`m.emissive`, the value the BSDF side adds at an emissive hit, is **not** simply
`emission_color × emission_strength`. Both composition sites in
`scene_raytracing_raygen.glsl` multiply by
`scene_data_block.data.emissive_exposure_normalization` — the texture branch and
the colour-only branch alike, and the custom-shader path does the same.

The NEE-side `L_e` **must apply that identical factor.** If the two sides compose
emission differently, the two MIS strategies estimate different integrands while
sharing a weight that is required to sum to 1 — which is exactly the structural
defect behind B2's open +2.4% converged-mean shift
(`COMBINE_BRDFS_WITH_FRESNEL`), one level down. Gate 1 (§6.1) is the test that
would catch it, because a mismatched factor moves the converged mean.

The safest implementation is a single shared helper that both the emissive-hit
site and the NEE site call, rather than two expressions intended to be equal —
the same remedy C2 applied by sharing `lights_attenuation_from_dist` verbatim
between its weight and its shading path.

**The CPU-side power used for the instance CDF may ignore the factor.** It scales
every emissive instance identically, so it cancels in the normalised CDF and
affects neither the selection probabilities nor the pdf.

## 5. MIS

Today `ps.radiance += clamp_contribution(ps.throughput * m.emissive, clamp_limit)`
fires on **every** hit. With C1 enabled an emissive surface is reachable by two
strategies, so that line must carry a weight or every glowing surface counts
twice. This is the identical defect C3 had to fix for the sky.

**BSDF side** (at the emissive hit): weight by
`power_heuristic(ps.mis_ray_pdf, pdf_ω)`, where `pdf_ω` is what emissive NEE
*would* have used to sample this exact point from the previous shading point:
`emissive_slot[gl_InstanceCustomIndex]` → `P(inst)`, `area_tri` from the hit's own
vertices, `dist` from `gl_HitTEXT`, `cos_θ_light` from the geometric normal.

**NEE side**: weight by `power_heuristic(pdf_ω, combinedPdf(N, L, V, material))`,
reusing B2's mixture pdf over both BSDF lobes.

**Unweighted cases**, both already expressed by the existing `RT_MIS_PDF_NONE`
sentinel (`raytracing_inc.glsl:64`): a primary/camera ray, and a path segment
that left a near-delta specular lobe (`RT_MIS_DELTA_ROUGHNESS`). A directly
visible panel must read its true radiance, and a mirror reflection of it must not
be weighted down against a strategy that cannot reach it.

`power_heuristic(a,b) + power_heuristic(b,a) == 1` exactly
(`raytracing_inc.glsl:453-456`), which is what makes the partition sum to unity.

**When the setting is off**, the emissive line keeps its current unweighted form
verbatim.

## 6. Testing

### 6.1 Energy gates — the load-bearing evidence (real GLSL)

**Gate 1 — MIS invariance.** BSDF-only sampling and BSDF+NEE-with-MIS are both
unbiased estimators of the same integral, so **the converged mean with C1 on must
equal the converged mean with C1 off.** Only the noise may differ.

This single assertion catches double-counting (reads ≈2×), energy loss (reads
low), and a wrong measure conversion — and it needs no external reference. It is
the strongest gate in this design and the first one to build.

*Guard against a gate that cannot fail:* the C3 phase shipped a constant-sky gate
whose mean was also satisfied by an inert NEE block, and only a variance probe
distinguished them. So gate 1 additionally asserts that per-pixel spread at a
fixed low sample count is **strictly lower** with C1 on. Equal means plus lower
spread is the pair of facts that proves NEE is both firing and correctly weighted.

**Gate 2 — analytic.** One emissive quad of known radiance and area above a
Lambertian floor of known albedo, camera looking down: the converged value is
computable in closed form. Absolute, not relative to the renderer's own past.

**Gate 3 — sampler-widening neutrality.** `RT_PRNG_BOUNCE_NUM` 8 → 16 with
emissive lights **disabled** must not move the converged mean of an existing
scene. This isolates the re-stratification from C1 itself, so a shift in gate 1
cannot be misattributed.

### 6.2 Unit tests — `tests/servers/rendering/test_pt_emissive.cpp`

The standing caveat applies and must be restated in the file header: **the
doctest binary never executes GLSL**, so these mirror the shader and would pass
against a reverted one. §6.1 is the evidence that the shader is right.

- World-space triangle area under **non-uniform scale**, where the
  "object-space area × s²" shortcut is wrong. At least one case must use a
  transform with three distinct scale factors *and* a rotation.
- `pdf_A = P(inst) × (1/prim_count) × (1/area_tri)` composition, and that the
  pdf over all outcomes sums to 1.
- Area → solid-angle conversion, including that a grazing `cos_θ_light` inflates
  `pdf_ω` rather than deflating it (a sign/reciprocal slip here is invisible in a
  head-on test).
- Front-face rejection: a sample behind the emitter contributes zero.
- The reverse-lookup table: non-emissive instances read `-1`; every emissive
  instance round-trips to its own slot.
- **Zero power implies zero contribution**, the property that produced findings in
  both C2 tasks. An instance with zero emission must be unselectable *and*
  contribute nothing.
- The bucket-remainder remap: the rescaled value must span `[0,1)` across the
  bucket, and `u` at a bucket boundary must not land outside the intended
  triangle range.

Every input dimension must go non-extremal in at least one case. Three separate
Phase B/C blind spots had correct assertions and test data that failed to
exercise the thing under test.

### 6.3 Measurement

A room lit **only** by a glowing panel, in `pipeline_references/`. RMSE against a
converged reference, per-sample and equal-time, plus frame-time delta.

**Accept:** *"a room lit only by a glowing panel converges clean; no hotspot
speckle"* (`PATH_TRACER_QUALITY_ROADMAP.md`, C1). Read as: equal-time RMSE
materially lower with C1 on, and gate 1's converged means agreeing.

**Measurement-design requirement, carried from C2:** the scene's light rig must
match the shape it is meant to represent. C2's benchmark was blind to the
production regression because every light in it had `shadow_enabled` at its
default while the production rig was mostly shadowless. Here that means the panel
scene must include real occluders, and the measurement must be checked against a
scene containing a *small* emitter as well as a large one, since the BSDF-only
control degrades fastest as the emitter shrinks.

### 6.4 A/B mechanism

The project setting is the A/B switch — no separate compile-time macro is needed,
which is a simplification over C2's `RT_LIGHT_SELECT_UNIFORM`.

**Liveness requirement, carried from B4 and C2:** before any figure is recorded,
the on and off runs must be shown to produce *different* numbers on a
configuration where they must. In B4 a `git stash` on an already-committed path
silently no-opped and one measurement compared a build against itself. Note that
gate 1 asserts the *means are equal*, so the mean cannot serve as the liveness
probe here — the per-pixel spread must.

## 7. Global constraints

- **Script changes go in `pipeline_references/` only.** Do not edit
  `C:\Zlendo2026\ZlenderRender_stage_copy/`.
- After touching any `.glsl`, run a full `scons platform=windows` build so the
  `.glsl.gen.h` headers regenerate. Never hand-edit a `.gen.h`.
- Build tests with `scons platform=windows tests=yes target=editor`. `--test
  "<pattern>"` does **not** filter in this binary; use
  `--test --test-case="<pattern>"`.
- `Math::PI`, not `Math_PI`.
- Any struct crossing to GLSL needs a verbatim twin plus `static_assert` on size
  and offsets, per the project's std430 parity rule.
- New `RS` API surface must be updated in all of `rendering_server.h` (virtual),
  `rendering_server_default.h` (`FUNC*` forward), the RD implementation, and the
  dummy stub in `servers/rendering/dummy/storage/`, or the headless build breaks.

## 8. Risks

| Risk | Mitigation |
|---|---|
| Double-counting emissive surfaces | Gate 1 reads ≈2× and fails; it is built first |
| Sampler widening shifts every render | Gate 3 isolates it with C1 disabled |
| Uniform triangle pick is high-variance on uneven tessellation | Unbiased regardless; §4.2 records the contained upgrade |
| Rebuild trigger bakes an empty distribution | Token covers set, transforms and emission — the C3 failure, by name |
| NEE and BSDF compose `L_e` differently (exposure normalization) | §4.5; one shared helper, not two equal-looking expressions; gate 1 detects it |
| Night renders brighten when someone enables the setting | Default off; §2.1 documents the fixture double-representation |
| CPU mirror agrees with a wrong shader | Acknowledged; §6.1's three gates are the real evidence |
