# Power-Weighted Light Selection (Roadmap C2) — Design

**Status:** approved, not yet implemented
**Roadmap item:** C2, *Gap #7* (`PATH_TRACER_QUALITY_ROADMAP.md:521-523`)
**Branch context:** follows Phase B (complete) and C3 (environment importance sampling, done).

---

## 1. Problem

`lights_evaluate_direct_lighting` (`servers/rendering/renderer_rd/shaders/raytracing/raytracing_lights_inc.glsl:333-497`)
selects which analytic light to sample with a uniform mini-batch reservoir:
draw `k = min(16, light_count)` light indices uniformly, keep the ones that pass
a range test, and reservoir-select uniformly among those.

Two defects follow from this.

**Coverage.** With 41 lights and `k = 16`, roughly 60% of shading points never
draw the scene's brightest light at all. The estimator is still unbiased in the
limit, but the variance is dominated by how rarely the one light that matters is
even considered. This is the roadmap's accept scenario verbatim — one bright key
among 40 dim fills — and coverage, not weighting, is the larger term in it.

**A biased pdf.** The selection density is not known exactly; it is estimated:

```glsl
float valid_count_estimate = float(light_count) * (float(valid_found) / float(k));
float light_select_pdf = 1.0 / max(valid_count_estimate, 1.0);
```

`valid_found` is a random variable, and `E[1/X̂] ≠ 1/E[X]`. The reciprocal of an
unbiased count estimate is a biased density. This is exact only when every light
passes the range test (`valid_found == k` deterministically); it is wrong
whenever range culling rejects anything. C2 removes it by construction rather
than by improving it: out-of-range lights receive weight zero and drop out of an
exact normalization.

## 2. Scope

**In:** replacing the selection mechanism inside `lights_evaluate_direct_lighting`
with an importance-weighted CDF over the ≤64 lights already in the light buffer,
yielding an exact selection pdf.

**Out, deliberately:**

- **This is not a light tree.** `RT_LIGHTS_MAX = 64`
  (`render_raytracing.h:170`) bounds the problem, so a flat O(N) scan per shading
  point is affordable and a spatial hierarchy buys nothing at this N. Cycles'
  `light_tree_node_importance` is the reference for the *importance function*,
  not for the data structure.
- **MIS is untouched.** Analytic lights carry no MIS weight before or after this
  change, and that remains correct: omni, spot, directional, and
  `RT_LIGHT_TYPE_RECT` are pure buffer data, absent from the TLAS, so no BSDF ray
  can reach one. There is no second strategy to combine against. (The roadmap's
  claim at `:681-685` that C1 gates MIS weights for analytic lights is wrong on
  this point and is corrected as part of this work. What C1 actually unlocks is
  MIS for *emissive meshes*, which are real TLAS geometry.)
- **Emissive-mesh lights (C1) are a separate spec.** Emissive triangles get their
  own distribution, their own NEE block, and their own MIS weight — the structure
  C3 used for the environment. They are not merged into this distribution.
- **The `gather_lights` culling score is not touched.** The camera-distance score
  at `render_raytracing.cpp:2796-2810` decides which 64 lights reach the buffer
  at all. It has its own failure mode — a bright light ranked 65th is dropped
  entirely, and no selection quality recovers it — but it is a separate
  mechanism and separate work.

## 3. The importance weight

For light *i* evaluated at shading point *p*:

```
in_range = expanded range test (§3.2)
spatial  = in_range ? max(attenuation_factor × spot_factor, RT_LIGHT_WEIGHT_FLOOR) : 0.0

w_i = abs(luminance(emission_i)) × spatial × indirect_factor
```

Every factor is non-negative, so `w_i ≥ 0` and the sum is a valid normalizer.

The structure matters: the **only** way a weight reaches zero is failing the
expanded range test, failing the widened spot cone test, having zero emission
magnitude, or having zero `indirect_energy` on an indirect bounce. Each of those
four is a condition under which the contribution is provably zero as well. The
continuous factors — windowed falloff and spot falloff — can shrink a weight but
never zero it, because the floor sits under their product. §3.2 and §3.3 explain
why that separation is load-bearing.

`attenuation_factor` is evaluated at the light's **center** distance for every
type. Directional lights pass `dist_sq = 0`, which returns `1.0` (matching
`lights_get_attenuation`'s existing early-out at `:155-157`), and are exempt from
the range test.

### 3.1 Magnitude, not signed luminance

`compute_light_energy` (`render_raytracing.cpp:2754-2771`) applies
`sign = -1.0f` when `light_is_negative(base)`, so `RT_LightData::emission` can be
negative in every channel. A signed luminance weight would go negative and
corrupt the CDF walk.

The weight uses `abs(luminance(emission))`. The sign is uniform across channels
(`sign` scales all three equally and `linear_col` components are non-negative),
so `abs(luminance(e)) == luminance(abs(e))` and the magnitude is unambiguous. A
negative light is then selected in proportion to its magnitude and contributes
its negative radiance divided by that positive pdf — correct.

`luminance(float3)` already exists at `brdf_inc.glsl:335` and is in scope.

### 3.2 Zero weight must imply zero contribution

A light with `w_i = 0` is never selected. That is only sound if such a light
contributes exactly zero; otherwise the estimator loses energy, which is bias,
not variance. Each factor is specified to satisfy this, and the three cases
where the naive form does **not** are called out here because they are the whole
correctness risk of this change.

**Attenuation — omni and spot: safe as written.** Shading rejects on the center
distance against `max_range_squared` (`raytracing_lights_inc.glsl:393`), and the
weight uses the same center distance. The two reach zero on the same condition.

**Attenuation — rect: NOT safe as written.** Shading range-checks the *sampled
point* on the quad (`:300`), while the weight knows only the center. A rect
straddling the range boundary would take weight 0 while parts of it still
contribute. The weight's range test for `RT_LIGHT_TYPE_RECT` is therefore
expanded by the quad's half-diagonal bound:

```
rect_extent = length(axisU) + length(axisV)     // conservative; ≥ true half-diagonal
in_range    = (max_range_squared == 0.0) || (max(0, dist_center - rect_extent)^2 <= max_range_squared)
```

The windowed falloff is still evaluated at the center distance. On its own that
would reintroduce the same hazard one level down — the window reaches zero at
`dist == range`, so a rect whose center sits past the range while its near edge
is inside would take weight 0 with a positive contribution. The §3.3 floor,
which sits under the whole spatial product rather than under the spot term
alone, is what closes that.

**Spot cone — NOT safe as written.** `spot_atten` decays to zero at the cone rim,
and for a sphere light of radius `r` the *sampled* direction can fall inside the
cone when the *center* direction lies outside it. The cone test is widened by the
light's angular radius, computed without an `acos`/`cos` round trip:

```
sin_b   = clamp(radius / max(dist, 1e-4), 0.0, 1.0)   // sin of angular radius
cos_b   = sqrt(max(0.0, 1.0 - sin_b * sin_b))
cos_a   = cos_spot_angle
sin_a   = sqrt(max(0.0, 1.0 - cos_a * cos_a))
cos_widened = cos_a * cos_b - sin_a * sin_b            // = cos(spot_half + angular_radius)
```

and the light is excluded only when `dot(-L_center, spot_direction) <= cos_widened`.

**`spot_direction` is aliased.** For `RT_LIGHT_TYPE_RECT` that field holds the
quad's axisU half-width vector, not a cone axis (`:269`). The spot factor must
therefore be gated on `type == RT_LIGHT_TYPE_SPOT` explicitly, never inferred
from the falloff fields being populated.

### 3.3 The spatial floor

`RT_LIGHT_WEIGHT_FLOOR = 1e-3`, applied to the **product** of the attenuation
and spot factors once the expanded range test has passed — not to either factor
individually:

```
spatial = in_range ? max(attenuation_factor × spot_factor, RT_LIGHT_WEIGHT_FLOOR) : 0.0
```

Both continuous factors decay smoothly to zero at a boundary that the light's
own extent straddles, and in both cases the sampled point can lie on the lit
side while the center lies on the dark side:

- a sphere light whose center sits exactly on the spot rim evaluates
  `spot_atten == 0` while directions inside the cone carry real radiance;
- a rect whose center sits at `dist == range` evaluates a zero window while its
  near edge is still within range.

The floor keeps both selectable at low probability. The estimator divides by that
small pdf and stays unbiased, paying variance on a rare configuration. Trading
variance to remove a bias is the correct direction; the reverse is not.

Applying the floor to the product rather than to each factor also keeps it from
inflating the weight of a light that is merely distant — a light at 10× its
useful range and outside the cone gets `1e-3`, not `1e-3 × 1e-3`, but it is only
reached at all when both tests pass.

### 3.4 Indirect energy

`indirect_energy` multiplies the contribution for every light type on indirect
bounces (`:321`, `:447`, `:490`), gated on `is_indirect_bounce`, which is
`diffuse_bounces > 0` (`raytracing_closest_hit_common_inc.glsl:587`).

```
indirect_factor = is_indirect_bounce ? indirect_energy : 1.0
```

A fill light with `indirect_energy == 0` contributes exactly zero past the first
diffuse bounce, so weight and contribution reach zero together — matched, no
bias — and a common "no-GI fill" setup stops consuming samples.

### 3.5 Deliberately excluded from the weight

- **The surface-normal cosine.** Lights behind the shading point keep positive
  weight and are discarded later by the existing `NdotL <= 0` tests. Including a
  conservative `max(0, cos(angle_to_light − angular_radius))` bound would remove
  roughly half the wasted draws in a multi-directional interior, but it is the
  factor most likely to silently zero a contributing light, and a zero weight on
  a contributing light is energy loss. Revisit with its own bound-validity test.
- **IES profiles.** Requires a profile lookup per light per shading point, and
  the profile can legitimately read zero at the center direction while sampled
  directions within the light's extent are lit — the same hazard as the spot rim
  but without a cheap conservative bound.
- **`specular_amount` and `shadow_enabled`.** Neither can zero a contribution.

### 3.6 Attenuation refactor

`lights_get_attenuation` (`:154`) currently takes a `LightSample`. The weight
function needs it from a bare squared distance, so the body is extracted:

```glsl
float lights_attenuation_from_dist_sq(float dist_sq, float inv_max_range, float decay);
```

and `lights_get_attenuation(LightSample, ...)` becomes a one-line forward. This
guarantees the weight and the shading path use the identical falloff function
rather than two copies that can drift — the failure mode that produced the +2.4%
shift in B2 was exactly two expressions intended to be the same function.

## 4. The draw

New include: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_light_select_inc.glsl`,
holding the weight function and the two-pass draw. It is included by
`raytracing_lights_inc.glsl` after the `RTLightData` declaration and the
attenuation helpers it depends on.

```glsl
bool lights_select(vec3 hit_pos, uint light_count, bool is_indirect_bounce,
                   float u, out uint r_index, out float r_pdf);
```

**Pass 1** accumulates `W = Σ w_i` over `i ∈ [0, light_count)`.

**If `W <= 0.0`,** return `false`. Every light contributes zero, so black is the
correct answer, not a degenerate case needing a uniform fallback. Adding one
would reintroduce sampling of lights that provably contribute nothing.

**Pass 2** draws a single `u` and walks the same range accumulating until the
running sum crosses `u * W`, returning that index. The index is clamped to
`light_count - 1` so floating-point drift at the top of the range cannot index
past the array, and the walk skips zero-weight entries so a clamp landing on one
is impossible.

```
r_pdf = w_selected / W
```

exactly — no estimate.

**Cost.** Worst case 2 × 64 weight evaluations against the current 16 uniform
draws plus 16 light-struct fetches. The 64-entry light array is 10 KB and is read
twice; the second pass recomputes rather than caching, because a 64-float local
array in a raytracing stage will very likely spill to scratch and cost more
occupancy than the recomputation costs arithmetic. This is the main frame-time
risk and §6 measures it directly.

### 4.1 Sampler

Selection consumes one 1D Sobol-Burley sample. `RT_PRNG_ENV 7u` is annotated as
the last free slot with `RT_PRNG_BOUNCE_NUM = 8` (`raytracing_inc.glsl:253-262`),
but this change **deletes** `RT_PRNG_RESERVOIR` (slot 6, 1D, which seeded the
reservoir's PCG side stream). Slot 6 is therefore reused for light selection and
the dimension block does not grow. Nothing downstream re-stratifies.

The comment at `raytracing_inc.glsl:259` and the note at
`raytracing_lights_inc.glsl:350-353` — which predicts this exact migration — are
updated to match.

`RT_LIGHT_RESERVOIR_SIZE` (`:19-21`) and the `rng_side_stream` call at `:354` are
removed.

## 5. Integration

`lights_evaluate_direct_lighting` loses its reservoir block (`:345-382`) and
calls `lights_select`. On `false` it returns `vec3(0.0)`. On `true` it proceeds
into the existing four per-type branches unchanged — each already divides by
`light_select_pdf` and continues to, now with an exact value.

No C++ change is required. `RT_LightData` is untouched, the light buffer is
untouched, `gather_lights` is untouched, and no specialization constant or
project setting is added. The entire change is shader-side plus tests.

## 6. Testing

Three layers. The CPU-mirror-only pattern is what allowed two Criticals through
in the sky phase, so the mirror is the weakest layer here, not the primary one.

### 6.1 Unit — `tests/servers/rendering/test_pt_light_select.cpp`

A C++ mirror of the weight function and the CDF walk. The standing caveat
applies and must be restated in the file header: **the doctest binary never
executes GLSL**, so every case here would still pass against a reverted shader.

The highest-value case is the §3.2 hazard stated as a property: over randomized
light configurations spanning all four types, assert

> `weight == 0` ⟹ the shading contribution for that light is `0`.

Plus:

- `Σ_i P(select i) == 1` and `P(select i) == w_i / W`.
- The CDF walk against exact interval endpoints: `u` just below and just above
  each boundary selects the expected neighbouring indices.
- `u = nextafterf(1.0f, 0.0f)` selects the last positive-weight light, never
  `light_count` or beyond.
- A negative-emission light receives positive weight and is selectable.
- A rect straddling its range boundary retains nonzero weight (§3.2).
- A sphere light whose *center* direction is outside the spot cone but whose
  extent reaches inside retains nonzero weight (§3.2).
- `W == 0` returns `false` rather than selecting index 0 with pdf 0.
- The floor is under the *product*, not per-factor: a light that fails the
  expanded range test weighs exactly `0.0`, while an in-range light whose
  attenuation and spot factors both underflow weighs exactly
  `abs(luminance) × RT_LIGHT_WEIGHT_FLOOR × indirect_factor`. A per-factor floor
  passes the straddle cases above but leaks weight to out-of-range lights, so
  this case is what distinguishes the two implementations.
- Every weight input dimension is non-extremal in at least one case — the weight
  is a product of four factors, and a test suite in which some factor is always
  1.0 pins only the others. This rule is carried forward from three separate
  Phase B test blind spots where the assertions were correct and the *data*
  failed to exercise the thing under test.

### 6.2 Energy gate — `pipeline_references/tests/` (executes real GLSL)

Two scenes, because "the converged mean must not move" is the right assertion in
only one of them.

- **All lights in range.** The old `valid_count_estimate` was exact here
  (`valid_found == k` deterministically), so the converged mean must not move.
  Assert neutrality within the gate's established tolerance.
- **Range-culled.** The old pdf was biased here, so the mean *should* move, and
  asserting neutrality would be asserting the bug. The direction of the shift is
  **predicted in writing before it is measured**, and the prediction is recorded
  in the results either way, including if it is wrong.

### 6.3 Measurement

A new scene under `pipeline_references/`: one bright key among 40 dim fills, per
the roadmap's accept criterion. RMSE against a converged reference, reported
**both** per-sample and equal-time. Equal-time is the criterion that decides
this change, because selection went from 16 iterations to as many as 128.

**Accept:** *"one bright key among 40 dim fills converges at several× the current
rate"* (`PATH_TRACER_QUALITY_ROADMAP.md:523`), read as equal-time RMSE.

### 6.4 A/B mechanism

A compile-time `RT_LIGHT_SELECT_UNIFORM` macro (default `0`) preserving the
reservoir path, kept permanently as measurement scaffolding rather than deleted
after the phase. Precedent: `COMBINE_BRDFS_WITH_FRESNEL` (`brdf_inc.glsl:158`) is
the only reason B2's +2.4% shift could be pinned to a specific line instead of
guessed at.

**Liveness requirement, carried from B4:** the control and treatment builds must
be demonstrated to produce *different* numbers on the measurement scene before
any figure is recorded. In B4 a `git stash` on an already-committed path silently
no-opped and one measurement compared a build against itself; it was caught only
because a probe read a value that a genuine control build could not produce.

## 7. Global constraints

- **Script changes go in `pipeline_references/` only.** Do not edit
  `C:\Zlendo2026\ZlenderRender_stage_copy/` — the user replaces and verifies
  those manually.
- After touching any `.glsl`, run a full `scons platform=windows` build so the
  `.glsl.gen.h` reflection headers regenerate. Never hand-edit a `.gen.h`.
- Tests are doctest, registered via `register_test_command`, built with
  `tests=yes` and run through the editor binary's `--test` flag.
- `Math::PI`, not `Math_PI` (`core/math/math_defs.h:44`).

## 8. Risks

| Risk | Mitigation |
|---|---|
| A weight factor zeroes a contributing light → energy loss | §3.2 handles the three known cases; §6.1's property test is written to catch a fourth |
| Frame-time regression from 2×N vs 16 iterations | §6.3 reports equal-time, which prices the loop honestly; a regression here is a finding to record, not a blocker to hide |
| The range-culled gate scene shifts and the shift is mistaken for a new bug | §6.2 requires the direction be predicted before measurement |
| CPU mirror agrees with a wrong shader | Acknowledged and unresolved; §6.2 and §6.3 run real GLSL and are the load-bearing evidence. A shader-execution harness remains open work for the project as a whole |
