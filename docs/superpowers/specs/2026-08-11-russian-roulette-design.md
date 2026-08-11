# Russian Roulette Path Termination — Design

**Roadmap item:** B4 (*Gap #8*), the last remaining Phase B item.
**Branch:** `vijay_PTEngine_v9_PhaseB`, on top of the sky NEE + MIS work (`700d6bf361`).
**Date:** 2026-08-11

---

## 1. Problem

The path tracer terminates paths only when a bounce cap is hit
(`raytracing_closest_hit_common_inc.glsl:519-521`): total, diffuse, or glossy. Every
path therefore runs to its full depth regardless of how little energy it still
carries. A path whose throughput has fallen to 0.001 costs exactly as much to trace
as one at 1.0 and contributes a thousandth as much.

Russian Roulette terminates low-throughput paths stochastically and compensates the
survivors, so the estimator stays unbiased while the average path gets shorter. It
is the standard fix and Cycles has had it since forever
(`kernel/integrator/path_state.h:296-305`).

## 2. Goals

1. Terminate low-throughput paths probabilistically, unbiased.
2. Never terminate the energy-carrying head of a path — the first `min_bounce`
   bounces are exempt.
3. Expose `min_bounce` so a scene can tune or disable RR.
4. Measure the result honestly: **equal-time RMSE**, not frame time alone.

### Non-goals

- Adaptive sampling changes. `PT_PARAM_NOISE_THRESHOLD` already exists and is
  orthogonal; RR raises per-sample variance, which adaptive sampling will observe
  through its own convergence test without any coupling code.
- `max_transmission_bounce`. Still no transmission path until E1.
- Any change to the MIS work from the previous phase. See §5.

## 3. Decisions

### 3.1 `min_bounce` lives in the specialization-constant flags word

`pathtracing_params` is `float[16]` and **slots 0-15 are fully allocated**
(`rendering_server_enums.h:776-806`; 14 = `LIGHT_COUNT`, 15 = `FRAME_INDEX`). B3
deferred `min_bounce` for exactly this reason.

Three homes were considered:

| Option | Verdict |
|---|---|
| Free `RT_FLAGS` bits 4-8 | **Chosen.** Bits 0-3 are feature flags, 20-27 sample count, 28-31 max bounces — 4-19 are free. Same pattern `max_bounces` already uses. |
| Resize params UBO 16 → 32 | Rejected for this task. Touches the C++/GLSL struct parity guarded by `static_assert`, and every consumer must agree on the new size. Worth doing when a second param needs a slot. |
| Hardcoded GLSL constant | Rejected. Not tunable; a wrong value needs a rebuild to discover. |

`min_bounce` changes recompile the pipeline, which is correct — it is a per-render
setting, not a per-frame one, exactly like `max_bounces` and SPP.

#### 3.1a Transport: a project setting, not an `Environment` property

**Correction made while writing the implementation plan.** Packing into the flags
word solves shader-side *storage* and nothing else. The value still has to travel
from configuration into `SceneShaderRaytracing::compute_rt_flags`
(`scene_shader_raytracing.cpp:641-669`), and that function reads **only**
`p_env_params` — the `pathtracing_params` float array, which is full.

This is why `PT_PARAM_SAMPLE_COUNT` and `PT_PARAM_MAX_BOUNCES` occupy param slots
even though the shader reads their specialization constants rather than those
slots: the array does double duty as a GPU UBO *and* as the CPU-side transport for
spec-constant values. A `grep` for `RT_PARAM_MAX_BOUNCES` across the shaders returns
only the `#define`, never a `get_rt_param` read.

**Chosen: a project setting**, `rendering/pathtracer/russian_roulette_min_bounce`,
read with `GLOBAL_GET` inside `compute_rt_flags`. There is direct precedent five
lines away — `RT_FLAG_SER_ENABLED` comes from
`GLOBAL_GET("rendering/pathtracer/use_shader_execution_reordering")`
(`scene_shader_raytracing.cpp:664`).

| Rejected alternative | Why |
|---|---|
| Resize `pathtracing_params` 16 → 32 | Changes the GPU UBO layout (4 vec4s → 8) with matching C++/GLSL edits and every consumer agreeing on the size. Worth doing when a *second* param needs a slot — E1's `max_transmission_bounce` is the likely trigger. |
| Dedicated storage field + `environment_get_pathtracing_min_bounce(RID)` | Per-scene, no parity risk, but full 5-layer Godot plumbing for one integer *and* a second transport mechanism alongside the params array. |
| Hardcoded GLSL constant | No transport at all, but not tunable without a rebuild. |

**Accepted trade-off:** the setting is **global, not per-`Environment`**. Two
environments in one project cannot use different `min_bounce` values. For a
single-script capture pipeline this is not a practical limit, and it is recorded
here so a future per-scene requirement is recognised as a change of decision rather
than a bug.

**Free off-switch.** `min_bounce >= max_bounces` means the RR branch is never
reached, so no separate enable flag is needed.

**Biased encoding, because 0 is a legitimate value.** B3 used "0 means unset, fall
back to the total cap" for `max_diffuse_bounce`/`max_glossy_bounce`
(`rendering_server_enums.h:816-823`). That sentinel cannot be reused here: `0` is a
*meaningful* `min_bounce` (RR from the first bounce), so a raw `RenderingServer`
environment that never writes the field would silently get the most aggressive
setting rather than the default.

Store `min_bounce + 1` in **5 bits at shift 4** (mask `0x1F`):

| stored | meaning |
|---|---|
| 0 | unset — falls back to the default, 3 |
| 1-17 | `min_bounce` = stored − 1, i.e. 0-16 |

Five bits rather than four so the range reaches 16 and covers the full
`max_bounces` ceiling — otherwise RR could not be fully disabled at `max_bounces
= 16`. Bits 4-19 are free, so the extra bit costs nothing.

### 3.2 Default `min_bounce = 3`, RR on by default

Matches Cycles' historical Min Bounces. Direct lighting and the first two indirect
bounces are never terminated, so the part of the path carrying the most energy is
untouched.

**This is a silent behavior change** for every existing project: renders get faster
and marginally noisier at equal sample count, with nobody opting in. The roadmap
records `pathtracing_max_bounces` going 3 → 8 in B3 as exactly this class of
change, and it gets the same treatment here — an explicit compatibility note in
`PATH_TRACER_QUALITY_ROADMAP.md`, and the project setting registered with a
`PROPERTY_HINT_RANGE` and a description stating the effect.

No `doc/classes/Environment.xml` change: per §3.1a this is a project setting, not an
`Environment` property.

### 3.3 `sqrt(max_component(throughput))`, not luminance

```
p = min(sqrt(max(max(throughput.r, throughput.g), throughput.b)), 1.0)
```

There is **no `max_component` helper in this codebase** — every call site writes the
nested `max` inline (e.g. `effects/smaa_edge_detection.glsl:86`). Write it inline
rather than adding a helper for one use.

Cycles deliberately terminates *later* than naive luminance-based RR, to better
match the view transform. **The roadmap explicitly records that an earlier revision
of this document specified `clamp(luminance, 0.05, 0.95)` and that it was wrong**
(§3.5). Match the reference: `max_component`, and keep the `sqrt`.

## 4. Placement and control flow

Single block in `shade_and_bounce`, after `ps.throughput *= brdf_weight`
(`raytracing_closest_hit_common_inc.glsl:743`) and after the diffuse/glossy counter
increments, before `path_pack`.

```glsl
// Russian Roulette (roadmap B4). Terminates low-throughput paths and scales the
// survivors by 1/p so the estimator stays unbiased.
//
// sqrt() is deliberate and matches Cycles (kernel/integrator/path_state.h:296-305):
// it terminates later than naive luminance-based RR, which better matches the view
// transform. max_component, NOT luminance -- an earlier revision of the roadmap
// specified clamp(luminance, 0.05, 0.95) and that was wrong.
uint depth = get_total_bounces(ps.packed_bounces_flags);
if (depth > RT_GET_MIN_BOUNCE()) {
    float p = min(sqrt(max(max(ps.throughput.r, ps.throughput.g), ps.throughput.b)), 1.0);
    // p == 0 is reachable (fully absorbed path). rng_1d can return exactly 0.0,
    // which would pass a naive `>= p` test and then divide by zero.
    if (p <= 0.0 || rng_1d(rng, RT_PRNG_TERMINATE) >= p) {
        ps.packed_bounces_flags = set_path_terminated(ps.packed_bounces_flags);
        path_pack(payload, ps);
        return;
    }
    ps.throughput /= p;
}
```

The bounce counters are incremented *before* this test, so `min_bounce = 3` means
"the first three bounces are never terminated." The implementer must verify this
off-by-one against the test in §7 rather than assuming it.

`RT_PRNG_TERMINATE 5u` is **already reserved** for this purpose
(`raytracing_inc.glsl:258`) — B5 anticipated B4. No dimension-block widening, and
no collision with `RT_PRNG_ENV 7u`.

Termination uses the same `set_path_terminated` → `path_pack` → `return` pattern as
the existing bounce-cap block at `:519-521`.

## 5. Interaction with the MIS work — none

RR scales `throughput`. `mis_ray_pdf` is a *directional density*, unaffected by
throughput scaling. The two are independent and no MIS weight changes.

Environment NEE at this vertex is evaluated at `:607-690`, **before** the RR block.
That ordering is correct: the NEE contribution from this vertex is valid whether or
not the path continues past it. RR governs only the continuation.

This matters because the previous phase's recurring failure was two code paths
silently disagreeing about the same integrand. RR does not create such a pair.

## 6. Plumbing

Five layers, the pattern this codebase requires:

| Layer | Change |
|---|---|
| Project setting | `rendering/pathtracer/russian_roulette_min_bounce`, `int`, default 3, `PROPERTY_HINT_RANGE "0,16,1"`, registered beside the existing `rendering/pathtracer/*` settings |
| Spec constant | `RT_MIN_BOUNCE_SHIFT = 4`, `RT_MIN_BOUNCE_MASK = 0x1F` in `scene_shader_raytracing.h`, packed by `rt_flags_pack` alongside sample count and max bounces, storing `min_bounce + 1` per §3.1 |
| Transport | `compute_rt_flags` reads the setting with `GLOBAL_GET` and passes it to `rt_flags_pack`, mirroring how `RT_FLAG_SER_ENABLED` is read at `scene_shader_raytracing.cpp:664` |
| GLSL twin | `RT_GET_MIN_BOUNCE()` in `raytracing_common_inc.glsl:14-20` alongside the existing shift defines, mirroring `RT_GET_MAX_BOUNCES()`'s biased form and resolving stored `0` to the default 3 |

**No `Environment` property, no ClassDB binding, no `Environment.xml` change, no
params-UBO change, no new descriptor binding, no struct-parity risk.** The
`RendererEnvironmentStorage` and `RenderingServer` layers are untouched.

## 7. Testing

**`tests/servers/rendering/test_pt_russian_roulette.cpp`** — CPU mirror, following
the project convention:

1. **Unbiasedness.** Over many trials at fixed throughput `t`, the mean of
   (terminate → 0, survive → `t/p`) equals `t`. This is the property RR exists to
   preserve and the one a wrong `1/p` breaks.
2. **`min_bounce` respected.** `depth <= min_bounce` never terminates, for every
   depth in range.
3. **`p = 0` guard.** A zero-throughput path terminates and never divides.
4. **`p` clamped to 1.** Throughput ≥ 1 is never terminated.
5. **Bit packing.** `RT_MIN_BOUNCE_SHIFT/MASK` round-trips `min_bounce` 0-16
   through the biased encoding, resolves stored `0` to the default 3, and does not
   collide with the sample-count (20-27) or max-bounce (28-31) fields — a C++-side
   check of the same word the GLSL reads. This is the one test that would catch a
   twin drift between `scene_shader_raytracing.h` and `raytracing_common_inc.glsl`.

**Known limitation, stated because this project has been bitten by it:** the test
binary never executes the GLSL. These tests verify the design math; the shader is
verified only by the image-level acceptance below. Reverting the shader block while
leaving the mirror intact would keep every unit test green.

## 8. Acceptance

The roadmap's bar, and it can fail:

> render time per frame drops in deep-bounce scenes with no measurable bias (mean of
> 2000 accumulated frames matches the pre-RR mean within noise)

Two numbers required, both on `pipeline_references/tests/pt_sky_rmse_scene.tscn`
(built in the previous phase; courtyard, slatted canopy, spheres — it has the
occluder depth that makes deep paths exist to terminate):

1. **Bias:** converged mean over 2000+ accumulated frames, RR on vs off, matching
   within run-to-run noise. Noise must be established by repeated runs, not assumed.
2. **Equal-time RMSE:** RR trades variance for speed. Frame time alone is not the
   metric — if noise rises more than proportionally, that is a loss disguised as a
   win. Report both frame time and equal-time RMSE, as in the previous phase.

The A/B baseline is produced with `git checkout <rev> -- <path>`, never `git stash`
on a committed path (a silent no-op that made one measurement in the previous phase
measure itself).

## 9. Limitations

- RR raises per-sample variance by construction. It is an equal-time win only when
  the time saved exceeds the variance added; §8 measures exactly that.
- The `sqrt` heuristic is tuned to Cycles' view transform. This fork's tonemapping
  is not identical, so the constant is inherited rather than derived.
- `min_bounce` is a spec constant, so changing it triggers a pipeline recompile.
  Correct for a per-render setting, but it is not something to animate.
- RR interacts with `PT_PARAM_NOISE_THRESHOLD` adaptive sampling: higher per-sample
  variance means converged pixels take longer to converge. Not coupled in code, but
  the equal-time measurement in §8 does **not** capture the net effect — it ran with
  adaptive sampling off (`PATH_TRACER_QUALITY_ROADMAP.md`, B4 measurement scope).
  The interaction is a Phase C item, not measured here.
