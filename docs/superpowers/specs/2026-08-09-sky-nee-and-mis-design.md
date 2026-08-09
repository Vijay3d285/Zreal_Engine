# Sky NEE + Multiple Importance Sampling — Design

**Date:** 2026-08-09
**Roadmap items:** C3 (environment importance sampling), B1 (payload widening), B2 (MIS)
**Branch lineage:** follows Phase B (B5 Sobol sampler, B3 per-lobe bounce limits) on `vijay_PTEngine_v8_Quality`

---

## 1. Why this, and why not MIS alone

The roadmap orders Phase B (B1/B2 MIS) before Phase C (C1 emissive meshes, C3 environment sampling). **That ordering is wrong for this codebase**, and the reason should be recorded before anything is built.

MIS weights two strategies that can each sample *the same emitter*, so that one covers the other's high-variance cases. An audit of what our two strategies can currently reach:

| Emitter | Sampled by NEE? | Reachable by a BSDF ray? |
|---|---|---|
| Omni / spot / directional / rect `Light3D` | Yes | **No** — `gather_lights` (`render_raytracing.cpp`) collects analytic light instances only; lights are never added to the TLAS as geometry |
| Emissive mesh (`m.emissive` at a hit) | **No** — nothing gathers emissive triangles | Yes |
| Sky / environment | **No** — no environment NEE exists | Yes — the miss shader reads `radiance_octmap` (binding 7) |

Every emitter is reachable by exactly one strategy. **There is nothing for MIS to combine.**

Applying MIS in this state would be worse than a no-op. The MIS weight `power_heuristic(light_pdf, bsdf_pdf)` is strictly less than 1; for analytic lights there is no BSDF-side contribution to restore the remainder, so weighting NEE would **lose energy and darken the render** — a bias bug presented as a quality feature.

The fix is to give one emitter a second sampling strategy first. We choose the **sky**, because the target scenes are daylight interiors seen through large windows: today the only path for daylight to enter is a bounce ray that happens to escape the window aperture and hit the octmap, which is the textbook worst case for interior path tracing.

## 2. Goals

1. Environment light can be sampled directly (NEE) from any shading point, importance-sampled by sky radiance.
2. Environment NEE and BSDF sky hits are combined with MIS, unbiased.
3. The payload carries a BSDF pdf so MIS weights can be formed.
4. No regression to the existing analytic-light lighting path.

## 3. Non-goals (deliberately excluded)

- **Portal sampling** (sampling the window aperture directly). This is the larger interior win, and a much larger feature. Named as a known limitation, not built.
- **Emissive-mesh lights (C1).** Separate roadmap item.
- **MIS for analytic lights.** They remain reachable by one strategy only; MIS stays off for them. See §8.
- **Any change to the light reservoir** or its selection pdf. See §8 for the pre-existing bias noted there.

## 4. Decisions and rationale

**Payload grows 32 → 48 bytes**, with fp32 radiance and throughput plus `mis_ray_pdf`. My recommendation was the minimal +4 bytes (`mis_ray_pdf` only, keeping fp16 radiance/throughput), on the grounds that the fp16 clip at 65504 is far above the scene's dynamic range and ray-payload size costs RT-core occupancy. The project owner chose the full widening, which additionally removes the fp16 clip and any banding in deep specular tails. **Consequence:** frame time must be measured before and after, because the roadmap's own B1 text says to profile and fall back if occupancy regresses. A regression must surface as a number, not a surprise.

**Sky NEE is a separate strategy, not a reservoir candidate.** Folding the sky into the existing reservoir would cost no extra shadow ray, but the reservoir's `light_select_pdf = 1 / valid_count_estimate` is a *stochastic estimate*, and MIS weights are only unbiased when fed exact pdfs. A separate strategy has an exact pdf from the CDF, and leaves the path that currently lights the scenes untouched. Cost: one extra shadow ray per shading point.

**The sampling distribution is built in lat-long, not in the octmap's own layout.** `oct_inc.glsl` implements the standard octahedral map (`n /= |x| + |y| + |z|`), which is **not** equal-area — solid angle per texel varies. A CDF over those texels needs a Jacobian correction that is easy to get subtly wrong and silently biasing. Resampling to a lat-long grid makes the weighting the textbook `sin θ`. The octmap remains purely a radiance lookup. Storage parameterization and sampling parameterization stay decoupled.

**The distribution is built on the GPU.** The octmap lives in VRAM; a CPU build needs a readback stall on every sky change. Two small dispatches over a 256×128 grid cost microseconds and no synchronization.

## 5. Components

| File | Status | Responsibility |
|---|---|---|
| `servers/rendering/renderer_rd/storage_rd/env_cdf.{h,cpp}` | Create | Owns the distribution SSBO, its dirty flag, and dispatches the build |
| `servers/rendering/renderer_rd/shaders/raytracing/env_cdf_build.glsl` | Create | Compute shader: resample octmap → weighted luminance → prefix sums |
| `servers/rendering/renderer_rd/shaders/raytracing/raytracing_env_sampling_inc.glsl` | Create | `env_sample()` and `env_pdf()` — one shared pdf formula, used by both |
| `raytracing_inc.glsl` | Modify | Payload widening to 48 B, `mis_ray_pdf`, `power_heuristic()` |
| `raytracing_closest_hit_common_inc.glsl` | Modify | Env NEE call, MIS weight on the NEE side, record the BSDF pdf |
| `scene_raytracing_raygen.glsl` (miss stage) | Modify | MIS weight on the BSDF-sky-hit side |
| `brdf_inc.glsl` | Modify | Return the sampled direction's pdf (see §7) |
| `render_raytracing.cpp` | Modify | Bind the distribution SSBO; trigger rebuild on sky change |

## 6. Data flow and math

Engine is **Y-up** (Cycles is Z-up). Following the convention already used by `ies_lookup_inc.glsl`:

```
θ = acos(clamp(dir.y, -1, 1))        // polar, from +Y
φ = atan(dir.x, dir.z), wrapped to [0, 2π)
u = φ / 2π,  v = θ / π
```

### Build (on sky change)

For a grid of `N_u = 256`, `N_v = 128`:

```
f[y][x] = luminance(octmap sampled at direction(u_x, v_y)) * sin(θ_y) + FLOOR
```

`FLOOR` is a small positive constant, fixed at **1e-4 relative to the grid's mean weighted luminance** (i.e. `FLOOR = 1e-4 × mean(f_unfloored)`, computed in the same pass) so it scales with scene exposure rather than assuming absolute units. **This is not cosmetic:** the pdf must be strictly positive wherever radiance is nonzero, or directions with zero pdf but nonzero radiance produce unbounded variance and a biased estimate. A relative floor also keeps a fully black sky from producing a degenerate all-zero distribution.

Then per-row conditional CDFs over `x`, and a marginal CDF over `y` from the row sums. Store `f`, the conditionals, the marginal, and `funcInt` in one SSBO (~132 KB).

### Sample (per shading point)

Draw a Sobol 2D from a dedicated dimension. Phase B5's sampler allocates a block of `RT_PRNG_BOUNCE_NUM = 8` dimensions per bounce, of which 0-1 (`SURFACE_BSDF`, 2D), 2-3 (`LIGHT`, 2D), 4 (`LOBE`), 5 (`TERMINATE`, reserved for B4) and 6 (`RESERVOIR`) are taken. **Slot 7 is the last free one and this work claims it** as `RT_PRNG_ENV`. Anything added after this must widen the block — Cycles itself uses 16.

Invert the marginal for `v`, then the row's conditional for `u`, interpolating within the cell for continuity. Convert `(u, v)` to a direction and trace a shadow ray with `t_max = 10000.0`, matching the ray extent already used elsewhere in this integrator — the environment is at infinity, so any hit occludes. On no occlusion, read radiance from the existing octmap.

```
funcInt = (Σ f) / (N_u · N_v)
pdf_uv  = f[y][x] / funcInt                    // integrates to 1 over [0,1]²
pdf_ω   = pdf_uv / (2π² · max(sin θ, ε))       // dω = 2π² sin θ du dv
```

### Evaluate (a BSDF ray that misses)

The miss shader maps its direction to `(u, v)` and applies **the same `pdf_ω` formula via the same function**. If sampling and evaluation ever diverge, MIS biases silently and no test that only checks convergence will notice.

### MIS weights

Power heuristic, matching Cycles (`light/sample.h`):

```
w(a, b) = a² / (a² + b²)

env NEE contribution   *= w(pdf_env,  pdf_bsdf(dir))
BSDF sky-hit radiance  *= w(pdf_bsdf, pdf_env(dir))
```

## 7. Edge cases

**Two cases must bypass MIS entirely and use weight 1**, or energy is lost:

- **Primary camera rays.** Sky seen directly through a window has no preceding BSDF pdf.
- **Near-delta specular lobes.** A mirror bounce has an effectively infinite pdf and env NEE can never sample that direction.

Both are handled by a sentinel: `mis_ray_pdf < 0` means "no MIS, weight 1". Raygen initialises it to `-1`. This mirrors Cycles' `PATH_RAY_MIS_SKIP`.

**Other cases:**

| Case | Handling |
|---|---|
| Poles (`sin θ → 0`) | `max(sin θ, ε)` in the pdf denominator |
| Occluded env sample | Contribution 0; the sample still counts — this is the correct estimator, and it is why interiors gain less than open scenes |
| No environment / sky disabled | `env_sample()` no-ops; MIS weight 1 on the BSDF side |
| Constant sky | Distribution is uniform; sampling degenerates to uniform sphere sampling. This is the §9 acceptance test |

**Known dependency, the highest-risk part of this work.** `evalIndirectCombinedBRDF` returns only the throughput weight (`f·cos/pdf`), not the pdf. MIS needs the pdf separately, with the lobe-selection probability folded in (`P(lobe) × pdf_lobe`). This requires an out-parameter on shared BRDF code in `brdf_inc.glsl`. The implementation must verify that the returned pdf is genuinely the pdf of the *sampled* direction under the *selected* lobe, including the lobe-choice probability — an error here is invisible in any single image and shows up only as slow or biased convergence.

## 8. Interaction with existing code

**Analytic lights are untouched.** They keep their current non-MIS NEE path. Their contribution is unchanged, so no existing lighting can regress.

**Pre-existing issue, recorded but not fixed here.** The reservoir divides by `light_select_pdf = 1 / valid_count_estimate`, where `valid_count_estimate = light_count × (valid_found / k)`. Dividing by a stochastic estimate is biased (`E[1/X] ≠ 1/E[X]`). This predates this work and is not on its critical path; roadmap item **C2** (power-weighted light selection) replaces this machinery and should fix it there.

## 9. Testing and acceptance

Two of Phase B's acceptance criteria were wrong when written — one stated backwards, one a tautology that could never fail. This phase's primary bar is therefore a **conservation law**, not a judgement call.

**Unit tests** (C++ mirrors of shader math, the pattern established by `test_pt_sobol.cpp`):

- CDF inversion round-trips: sampling `u` then evaluating its pdf returns the same cell.
- `pdf_ω` integrates to 1 over the sphere within tolerance (numeric quadrature over the grid).
- `power_heuristic` is symmetric and the two strategies' weights sum to 1 for any pdf pair.

**Primary acceptance — constant-sky energy conservation.** With a constant sky of radiance `L` and an unoccluded diffuse surface of albedo `ρ`, outgoing radiance must equal `ρL`. Env NEE and BSDF sky hits must **sum** to that value. This is the direct test for the specific failure mode of MIS: a botched weight loses or double-counts energy while still producing a plausible-looking image, which an eyeball test cannot catch.

**Secondary acceptance — variance reduction.** On a daylight interior, with env NEE + MIS ON versus OFF at matched sample counts, RMSE against a high-sample reference must be **lower at every sample count in the sweep**. Do not specify a required direction for how the improvement ratio scales with sample count; the Phase B correction to that reasoning applies here too.

**Regression guard — the converged mean must not move.** MIS redistributes variance, not energy. Mean luminance of a fully converged render must match the pre-change build within noise. A shifted mean means an energy bug.

**Performance.** Frame time before and after the payload widening, on the same scene, reported as a number. Required by §4.

## 10. Known limitations, stated up front

- **Indoors, a large fraction of env samples will be occluded by walls.** The improvement is real but smaller than in an open scene. Portal sampling is the technique that fixes this properly and is out of scope.
- The pdf is built from a 256×128 resampling, so it is a slightly blurred proxy for the true sky radiance. This is valid (a pdf need only be positive and roughly proportional) but means a very small, very bright feature — a sun disc a few pixels across — is importance-sampled less sharply than a higher-resolution grid would manage.
- A sky animated every frame pays a distribution rebuild every frame. Cheap on the GPU, but not free.
