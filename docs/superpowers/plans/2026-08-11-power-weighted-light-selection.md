# Power-Weighted Light Selection (C2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the uniform k=16 mini-batch reservoir in the path tracer's analytic-light NEE with an importance-weighted CDF over the ≤64 lights in the light buffer, producing an exact selection pdf.

**Architecture:** One new GLSL include holds a per-light importance weight (`|luminance| × attenuation × spot cone × indirect energy`) and a two-pass CDF draw consuming a single Sobol sample. `lights_evaluate_direct_lighting` loses its reservoir block and calls the new selector; its four per-type branches are untouched and keep dividing by `light_select_pdf`, now an exact value. No C++ changes — `RT_LightData`, the light buffer, and `gather_lights` are all untouched.

**Tech Stack:** GLSL (Vulkan RD raytracing stages), C++ doctest unit tests, GDScript measurement harnesses under `pipeline_references/`.

**Spec:** `docs/superpowers/specs/2026-08-11-power-weighted-light-selection-design.md` — read it before starting. This plan implements it; where they disagree, the spec is authoritative on *intent* and this plan is authoritative on *code*.

## Global Constraints

- **Script changes go in `pipeline_references/` ONLY.** Do not edit anything under `C:\Zlendo2026\ZlenderRender_stage_copy/` — the user replaces and verifies those files manually.
- After touching any `.glsl`, run a **full** `scons platform=windows` build so `.glsl.gen.h` reflection headers regenerate. Never hand-edit a `.gen.h`.
- New test files need `TEST_FORCE_LINK(<basename>)` and a full build to regenerate `tests/force_link.gen.h`. Do not hand-edit that file.
- Build tests with `scons platform=windows tests=yes target=editor`; run via `bin\godot.windows.editor.x86_64.exe --test`.
- `Math::PI`, not `Math_PI` (`core/math/math_defs.h:44`). There is no `Math_PI` in this codebase.
- `RT_LIGHTS_MAX = 64` (`servers/rendering/renderer_rd/forward_clustered/render_raytracing.h:170`).
- `RT_LIGHT_WEIGHT_FLOOR = 1e-3`.
- Follow the Godot file header (the 29-line comment block) on every new `.cpp` — copy it from `tests/servers/rendering/test_pt_russian_roulette.cpp`.

---

## File Structure

| File | Responsibility |
|---|---|
| `servers/rendering/renderer_rd/shaders/raytracing/raytracing_light_select_inc.glsl` | **Create.** The importance weight and the two-pass CDF draw. Nothing else. |
| `servers/rendering/renderer_rd/shaders/raytracing/raytracing_lights_inc.glsl` | **Modify.** Extract the attenuation helper; include the new file; replace the reservoir block with a call to it, behind the A/B macro. |
| `servers/rendering/renderer_rd/shaders/raytracing/raytracing_inc.glsl:259` | **Modify.** Rename `RT_PRNG_RESERVOIR` → `RT_PRNG_LIGHT_SELECT`, update the comment. |
| `tests/servers/rendering/test_pt_light_select.cpp` | **Create.** CPU mirror of the weight and the walk. |
| `pipeline_references/tests/pt_light_gate.gd` + `pt_light_gate_scene.tscn` | **Create.** Two energy-conservation gate scenes (all-in-range, range-culled). |
| `pipeline_references/tests/pt_light_rmse.gd` + `pt_light_rmse_scene.tscn` | **Create.** The bright-key-among-40-fills RMSE measurement. |
| `PATH_TRACER_QUALITY_ROADMAP.md` | **Modify.** C2 closeout; correct the C1-gates-MIS claim at `:681-685`. |

Three tasks. Task 1 delivers a tested weight function, Task 2 delivers working selection in the renderer, Task 3 delivers measured evidence. A reviewer can reject any one while approving its neighbours.

---

### Task 1: The importance weight

**Files:**
- Create: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_light_select_inc.glsl`
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_lights_inc.glsl:154-173` (extract helper), and add the `#include` after line 69
- Test: `tests/servers/rendering/test_pt_light_select.cpp`

**Interfaces:**
- Consumes: `RTLightData` (declared `raytracing_lights_inc.glsl:27-51`), `luminance(float3)` (`brdf_inc.glsl:335`), the `RT_LIGHT_TYPE_*` constants (`raytracing_lights_inc.glsl:13-16`).
- Produces:
  - `float lights_attenuation_from_dist_sq(float p_dist_sq, float p_inv_max_range, float p_decay)` in `raytracing_lights_inc.glsl`
  - `float lights_select_weight(vec3 p_hit_pos, RTLightData p_light, bool p_is_indirect_bounce)` in the new include
  - `#define RT_LIGHT_WEIGHT_FLOOR 1e-3` in the new include

---

- [ ] **Step 1: Extract the attenuation helper**

The weight needs the falloff from a bare squared distance, and it must be the *same function* the shading path uses — two copies that drift is exactly the failure that produced B2's +2.4% shift.

**Placement matters.** GLSL has no forward declarations, and Step 5 adds an `#include` right after the `rt_lights` SSBO (line 69) whose contents call this helper. So do not leave it at line 154 — **delete** the existing `lights_get_attenuation` block at lines 154-173 and put the replacement below **above** the include point, directly after `lights_local_to_world` (currently ending line 95):

```glsl
// Godot-style windowed distance attenuation, from a squared distance.
// window = (1 - (d/range)^4)^2, combined with pow(d, -decay).
// Shared verbatim by the shading path (via lights_get_attenuation) and by the
// light-selection weight (lights_select_weight). These MUST stay one function:
// if the weight's falloff drifts from the contribution's falloff, the estimator
// divides by a pdf that does not match the density it sampled from.
float lights_attenuation_from_dist_sq(float p_dist_sq, float p_inv_max_range, float p_decay) {
	if (p_dist_sq <= 0.0) {
		return 1.0; // Directional: no distance attenuation.
	}

	float distance = sqrt(p_dist_sq);
	float atten = min(pow(max(distance, 0.0001), -p_decay), 1.0);

	// Windowed falloff if range is finite (inv_max_range >= 0).
	if (p_inv_max_range >= 0.0) {
		float nd = distance * p_inv_max_range;
		nd *= nd;
		nd *= nd; // nd^4
		nd = max(1.0 - nd, 0.0);
		nd *= nd; // nd^2 window
		return atten * nd;
	}

	return atten;
}

float lights_get_attenuation(LightSample ls, float inv_max_range, float decay) {
	return lights_attenuation_from_dist_sq(ls.distance_sq, inv_max_range, decay);
}
```

- [ ] **Step 2: Write the failing test file**

Create `tests/servers/rendering/test_pt_light_select.cpp`. Start with the 29-line Godot header copied from `tests/servers/rendering/test_pt_russian_roulette.cpp` (change the filename on line 2), then:

```cpp
#include "tests/test_macros.h"

TEST_FORCE_LINK(test_pt_light_select)

#include "core/math/math_funcs.h"
#include "core/math/vector3.h"

#include <vector>

namespace TestPTLightSelect {

// CPU mirror of the light-selection weight and CDF walk in
// servers/rendering/renderer_rd/shaders/raytracing/raytracing_light_select_inc.glsl.
//
// STANDING CAVEAT, restated because it is load-bearing: the doctest binary never
// executes GLSL. Every case in this file would still pass if the shader were
// reverted and this mirror left untouched. The evidence that the SHADER is
// correct comes from pipeline_references/tests/pt_light_gate.gd (energy
// conservation) and pt_light_rmse.gd (variance), which render real frames.
//
// The property this file exists to protect is that ZERO WEIGHT IMPLIES ZERO
// CONTRIBUTION. A light with weight 0 is never selected, so if it could still
// contribute, the estimator silently loses that energy -- a converged image that
// is simply wrong, which no convergence or performance test detects.

static const float RT_LIGHT_WEIGHT_FLOOR = 1e-3f;

static const uint32_t LIGHT_TYPE_OMNI = 0;
static const uint32_t LIGHT_TYPE_DIRECTIONAL = 1;
static const uint32_t LIGHT_TYPE_RECT = 2;
static const uint32_t LIGHT_TYPE_SPOT = 3;

// Mirror of the fields of RTLightData that the weight reads. Deliberately NOT
// the full 160-byte struct: this file tests the weight function, not std430
// layout parity (that is covered by the static_asserts in render_raytracing.h).
struct MirrorLight {
	Vector3 position;
	uint32_t type = LIGHT_TYPE_OMNI;
	Vector3 emission = Vector3(1, 1, 1);
	float radius = 0.0f;
	float attenuation = 2.0f;
	float inv_max_range = -1.0f;
	float max_range_squared = 0.0f;
	float indirect_energy = 1.0f;
	float inv_spot_attenuation = 1.0f;
	float cos_spot_angle = 0.0f;
	Vector3 spot_direction = Vector3(0, 0, -1); // For RECT this is axisU.
	Vector3 rect_axis_v = Vector3(0, 0, 0);
};

static float mirror_luminance(const Vector3 &p_c) {
	return p_c.x * 0.2126f + p_c.y * 0.7152f + p_c.z * 0.0722f;
}

// Mirror of lights_attenuation_from_dist_sq().
static float mirror_attenuation(float p_dist_sq, float p_inv_max_range, float p_decay) {
	if (p_dist_sq <= 0.0f) {
		return 1.0f;
	}
	const float distance = Math::sqrt(p_dist_sq);
	float atten = MIN(Math::pow(MAX(distance, 0.0001f), -p_decay), 1.0f);
	if (p_inv_max_range >= 0.0f) {
		float nd = distance * p_inv_max_range;
		nd *= nd;
		nd *= nd;
		nd = MAX(1.0f - nd, 0.0f);
		nd *= nd;
		return atten * nd;
	}
	return atten;
}

// Mirror of lights_select_weight().
static float mirror_weight(const Vector3 &p_hit_pos, const MirrorLight &p_light, bool p_is_indirect) {
	const float mag = Math::abs(mirror_luminance(p_light.emission));
	if (mag <= 0.0f) {
		return 0.0f;
	}
	const float indirect_factor = p_is_indirect ? p_light.indirect_energy : 1.0f;
	if (indirect_factor <= 0.0f) {
		return 0.0f;
	}
	if (p_light.type == LIGHT_TYPE_DIRECTIONAL) {
		return mag * indirect_factor;
	}

	const Vector3 to_light = p_light.position - p_hit_pos;
	const float dist_sq = to_light.length_squared();
	const float dist = Math::sqrt(dist_sq);

	float near_dist = dist;
	if (p_light.type == LIGHT_TYPE_RECT) {
		const float rect_extent = p_light.spot_direction.length() + p_light.rect_axis_v.length();
		near_dist = MAX(0.0f, dist - rect_extent);
	}
	if (p_light.max_range_squared != 0.0f && near_dist * near_dist > p_light.max_range_squared) {
		return 0.0f;
	}

	const float atten = mirror_attenuation(dist_sq, p_light.inv_max_range, p_light.attenuation);

	float spot_factor = 1.0f;
	if (p_light.type == LIGHT_TYPE_SPOT) {
		const Vector3 L = to_light / MAX(dist, 1e-4f);
		const float scos = (-L).dot(p_light.spot_direction);
		const float sin_b = CLAMP(p_light.radius / MAX(dist, 1e-4f), 0.0f, 1.0f);
		const float cos_b = Math::sqrt(MAX(0.0f, 1.0f - sin_b * sin_b));
		const float cos_a = p_light.cos_spot_angle;
		const float sin_a = Math::sqrt(MAX(0.0f, 1.0f - cos_a * cos_a));
		const float cos_widened = cos_a * cos_b - sin_a * sin_b;
		if (scos <= cos_widened) {
			return 0.0f;
		}
		// CLAMPED TO 1.0. Directions between cos_widened and cos_spot_angle are
		// admitted on purpose (that is what widening the cone means), and for
		// exactly those the raw ratio exceeds 1, making 1 - pow(...) NEGATIVE.
		// A negative weight corrupts the CDF far worse than the zero this
		// widening exists to avoid.
		const float spot_rim = CLAMP((1.0f - scos) / (1.0f - p_light.cos_spot_angle), 1e-4f, 1.0f);
		spot_factor = 1.0f - Math::pow(spot_rim, p_light.inv_spot_attenuation);
	}

	const float spatial = MAX(atten * spot_factor, RT_LIGHT_WEIGHT_FLOOR);
	return mag * spatial * indirect_factor;
}
```

Now the cases. Note `light_can_contribute` below is derived from the **shading** code's zero-tests (`raytracing_lights_inc.glsl:284-303`, `:393`, `:421`), *not* from `mirror_weight` — deriving it from the weight would make the property test a tautology that passes no matter what either function does.

```cpp
// Conservative: true if ANY sample within the light's extent can produce a
// nonzero contribution. Mirrors the shader's CONTRIBUTION zero-tests, not the
// weight's. Keep it that way -- a version derived from mirror_weight() would
// assert only that mirror_weight equals itself.
static bool light_can_contribute(const Vector3 &p_hit_pos, const MirrorLight &p_light, bool p_is_indirect) {
	if (Math::abs(mirror_luminance(p_light.emission)) <= 0.0f) {
		return false;
	}
	if (p_is_indirect && p_light.indirect_energy <= 0.0f) {
		return false;
	}
	if (p_light.type == LIGHT_TYPE_DIRECTIONAL) {
		return true;
	}
	const Vector3 to_light = p_light.position - p_hit_pos;
	const float dist = to_light.length();

	if (p_light.max_range_squared != 0.0f) {
		// Shading range-tests the SAMPLED point: the centre for omni/spot
		// (raytracing_lights_inc.glsl:393), a point on the quad for rect (:300).
		float nearest = dist;
		if (p_light.type == LIGHT_TYPE_RECT) {
			nearest = MAX(0.0f, dist - (p_light.spot_direction.length() + p_light.rect_axis_v.length()));
		}
		if (nearest * nearest > p_light.max_range_squared) {
			return false;
		}
	}
	if (p_light.type == LIGHT_TYPE_SPOT) {
		// Shading rejects on scos <= cos_spot_angle (:421) using the SAMPLED
		// direction, which for a sphere light of radius r ranges over an
		// angular disc of half-angle asin(r/d) around the centre direction.
		const Vector3 L = to_light / MAX(dist, 1e-4f);
		const float scos = (-L).dot(p_light.spot_direction);
		const float sin_b = CLAMP(p_light.radius / MAX(dist, 1e-4f), 0.0f, 1.0f);
		const float cos_b = Math::sqrt(MAX(0.0f, 1.0f - sin_b * sin_b));
		const float cos_a = p_light.cos_spot_angle;
		const float sin_a = Math::sqrt(MAX(0.0f, 1.0f - cos_a * cos_a));
		if (scos <= cos_a * cos_b - sin_a * sin_b) {
			return false;
		}
	}
	return true;
}

TEST_CASE("[PathTracer][LightSelect] a light that can contribute always has positive weight") {
	// THE load-bearing case. Equivalent to "weight == 0 implies contribution == 0",
	// stated in the direction that fails loudly.
	uint32_t seed = 0x9E3779B9u;
	auto next = [&seed]() {
		seed = seed * 1664525u + 1013904223u;
		return float(seed >> 8) / float(1u << 24);
	};

	const uint32_t types[4] = { LIGHT_TYPE_OMNI, LIGHT_TYPE_DIRECTIONAL, LIGHT_TYPE_RECT, LIGHT_TYPE_SPOT };
	for (int trial = 0; trial < 20000; trial++) {
		MirrorLight l;
		l.type = types[trial & 3];
		l.position = Vector3(next() * 20.0f - 10.0f, next() * 20.0f - 10.0f, next() * 20.0f - 10.0f);
		// Emission spans zero, positive, and NEGATIVE (light_is_negative).
		const float e = next() * 4.0f - 1.0f;
		l.emission = Vector3(e, e * 0.5f, e * 2.0f);
		l.radius = next() * 2.0f;
		l.attenuation = next() * 3.0f;
		const bool finite_range = next() < 0.7f;
		const float range = 1.0f + next() * 15.0f;
		l.inv_max_range = finite_range ? 1.0f / range : -1.0f;
		l.max_range_squared = finite_range ? range * range : 0.0f;
		l.indirect_energy = (next() < 0.2f) ? 0.0f : next() * 2.0f;
		l.cos_spot_angle = next();
		l.inv_spot_attenuation = 0.1f + next() * 4.0f;
		const Vector3 d(next() * 2.0f - 1.0f, next() * 2.0f - 1.0f, next() * 2.0f - 1.0f);
		l.spot_direction = (d.length() > 1e-4f) ? d.normalized() : Vector3(0, 0, -1);
		if (l.type == LIGHT_TYPE_RECT) {
			l.spot_direction = d * 0.5f; // axisU, NOT normalized -- it is a half-extent vector.
			l.rect_axis_v = Vector3(next(), next(), next()) * 0.5f;
		}

		const Vector3 p(next() * 20.0f - 10.0f, next() * 20.0f - 10.0f, next() * 20.0f - 10.0f);
		const bool indirect = (trial & 4) != 0;

		if (light_can_contribute(p, l, indirect)) {
			const float w = mirror_weight(p, l, indirect);
			CHECK_MESSAGE(w > 0.0f, "trial ", trial, " type ", l.type, ": contributing light got weight 0");
		}
	}
}

TEST_CASE("[PathTracer][LightSelect] no weight is ever negative") {
	// The spot-rim clamp. Without it, a direction between the widened cone and
	// the true cone yields spot_rim > 1 and 1 - pow(spot_rim, k) < 0.
	MirrorLight l;
	l.type = LIGHT_TYPE_SPOT;
	l.cos_spot_angle = 0.8f;         // ~36.9 degree half-angle
	l.inv_spot_attenuation = 1.0f;
	l.spot_direction = Vector3(0, 0, -1);
	l.position = Vector3(0, 0, 0);
	l.radius = 2.0f;                 // wide enough to widen the cone substantially
	l.emission = Vector3(1, 1, 1);

	// Sweep the shading point around the cone edge, from inside to well outside.
	bool saw_widened_admission = false;
	for (int i = 0; i <= 200; i++) {
		const float angle = float(i) * 0.01f; // 0 .. 2 rad
		const Vector3 p(Math::sin(angle) * 5.0f, 0.0f, -Math::cos(angle) * 5.0f);
		const float w = mirror_weight(p, l, false);
		CHECK(w >= 0.0f);
		const Vector3 L = (l.position - p).normalized();
		const float scos = (-L).dot(l.spot_direction);
		if (w > 0.0f && scos <= l.cos_spot_angle) {
			saw_widened_admission = true; // outside the TRUE cone, still weighted
		}
	}
	// If this never fires the sweep missed the band the clamp protects, and the
	// non-negativity checks above proved nothing about it.
	CHECK(saw_widened_admission);
}

TEST_CASE("[PathTracer][LightSelect] a negative light gets positive weight") {
	// compute_light_energy() applies sign = -1 for light_is_negative
	// (render_raytracing.cpp:2755), so emission arrives negative in every channel.
	// A signed luminance weight would go negative and corrupt the CDF.
	MirrorLight neg;
	neg.type = LIGHT_TYPE_OMNI;
	neg.position = Vector3(0, 3, 0);
	neg.emission = Vector3(-2.0f, -2.0f, -2.0f);

	MirrorLight pos = neg;
	pos.emission = Vector3(2.0f, 2.0f, 2.0f);

	const Vector3 p(0, 0, 0);
	CHECK(mirror_weight(p, neg, false) > 0.0f);
	// Magnitude governs placement, so equal magnitudes weigh equally.
	CHECK(mirror_weight(p, neg, false) == doctest::Approx(mirror_weight(p, pos, false)));
}

TEST_CASE("[PathTracer][LightSelect] a rect straddling its range boundary keeps weight") {
	// Shading range-tests the sampled point on the quad (raytracing_lights_inc.glsl:300);
	// the weight knows only the centre. Without the half-diagonal expansion this
	// rect weighs 0 while half of it is still lit.
	MirrorLight l;
	l.type = LIGHT_TYPE_RECT;
	l.position = Vector3(0, 0, 10.5f);
	l.spot_direction = Vector3(2, 0, 0); // axisU half-width
	l.rect_axis_v = Vector3(0, 2, 0);    // axisV half-height
	l.inv_max_range = 1.0f / 10.0f;
	l.max_range_squared = 100.0f;        // centre at 10.5 is OUTSIDE, near edge is inside
	l.emission = Vector3(5, 5, 5);

	const Vector3 p(0, 0, 0);
	REQUIRE(light_can_contribute(p, l, false));
	CHECK(mirror_weight(p, l, false) > 0.0f);
}

TEST_CASE("[PathTracer][LightSelect] a sphere light reaching into the spot cone keeps weight") {
	// The centre direction lies outside the cone; part of the sphere does not.
	MirrorLight l;
	l.type = LIGHT_TYPE_SPOT;
	l.spot_direction = Vector3(0, 0, -1);
	l.cos_spot_angle = Math::cos(0.30f); // 0.30 rad half-angle
	l.inv_spot_attenuation = 1.0f;
	l.radius = 1.5f;
	l.emission = Vector3(3, 3, 3);
	// Shading point at 0.35 rad off axis at distance 5: outside 0.30, but
	// asin(1.5/5) = 0.304 rad of angular radius reaches in.
	const float a = 0.35f;
	l.position = Vector3(0, 0, 0);
	const Vector3 p(Math::sin(a) * 5.0f, 0.0f, -Math::cos(a) * 5.0f);

	const Vector3 L = (l.position - p).normalized();
	REQUIRE((-L).dot(l.spot_direction) <= l.cos_spot_angle); // genuinely outside the true cone
	CHECK(mirror_weight(p, l, false) > 0.0f);
}

TEST_CASE("[PathTracer][LightSelect] the floor is under the product, not each factor") {
	// Distinguishes a product-level floor from a per-factor one. A per-factor
	// floor passes every straddle case above while leaking weight to lights that
	// are genuinely out of range -- so without this case the two implementations
	// are indistinguishable.
	MirrorLight out_of_range;
	out_of_range.type = LIGHT_TYPE_OMNI;
	out_of_range.position = Vector3(0, 0, 50.0f);
	out_of_range.inv_max_range = 1.0f / 5.0f;
	out_of_range.max_range_squared = 25.0f;
	out_of_range.emission = Vector3(1000, 1000, 1000);
	CHECK(mirror_weight(Vector3(0, 0, 0), out_of_range, false) == 0.0f);

	// In range but with both spatial factors driven tiny: lands exactly on the floor.
	MirrorLight faint;
	faint.type = LIGHT_TYPE_OMNI;
	faint.position = Vector3(0, 0, 4.999f);
	faint.inv_max_range = 1.0f / 5.0f;
	faint.max_range_squared = 25.0f;
	faint.attenuation = 2.0f;
	faint.emission = Vector3(1, 1, 1);
	const float w = mirror_weight(Vector3(0, 0, 0), faint, false);
	CHECK(w == doctest::Approx(mirror_luminance(faint.emission) * RT_LIGHT_WEIGHT_FLOOR));
}

TEST_CASE("[PathTracer][LightSelect] zero indirect energy weighs zero only on indirect bounces") {
	MirrorLight l;
	l.type = LIGHT_TYPE_OMNI;
	l.position = Vector3(0, 2, 0);
	l.emission = Vector3(1, 1, 1);
	l.indirect_energy = 0.0f;

	const Vector3 p(0, 0, 0);
	CHECK(mirror_weight(p, l, false) > 0.0f);  // direct: contributes, must be weighted
	CHECK(mirror_weight(p, l, true) == 0.0f);  // indirect: contributes nothing, matched
}

} // namespace TestPTLightSelect
```

- [ ] **Step 3: Run the tests to verify they fail**

```bash
scons platform=windows tests=yes target=editor && bin/godot.windows.editor.x86_64.exe --test "*LightSelect*"
```

Expected: **FAIL**. `raytracing_light_select_inc.glsl` does not exist yet, so the mirror has nothing to mirror. The tests exercise the mirror only, so they may in fact pass at this step — if they do, that is expected and not a problem; the mirror is being written first deliberately so Step 4 can be checked against it line by line. What must NOT happen is a compile error. Record which cases pass and which fail.

- [ ] **Step 4: Write the GLSL weight function**

Create `servers/rendering/renderer_rd/shaders/raytracing/raytracing_light_select_inc.glsl`:

```glsl
// Importance-weighted light selection for analytic-light NEE (roadmap C2).
//
// Requires: raytracing_lights_inc.glsl (RTLightData, RT_LIGHT_TYPE_*,
// lights_attenuation_from_dist_sq, the rt_lights SSBO) and brdf_inc.glsl
// (luminance). Include it AFTER those.
//
// Replaces the uniform k=16 mini-batch reservoir, which had two defects: with
// 41 lights it never even considered the brightest one at ~60% of shading
// points, and its pdf was ESTIMATED (valid_count_estimate is a random variable,
// and E[1/X] != 1/E[X]), so the density was biased whenever range culling
// rejected anything.
//
// THE INVARIANT THIS FILE MUST PRESERVE: a light with weight 0 is never
// selected, so zero weight must imply zero contribution. Otherwise the
// estimator silently loses energy -- a converged image that is simply wrong.
// Three cases where the naive weight violates that are handled below and each
// is marked. See docs/superpowers/specs/2026-08-11-power-weighted-light-selection-design.md
// section 3.2, and tests/servers/rendering/test_pt_light_select.cpp.

#ifndef RT_LIGHT_WEIGHT_FLOOR
#define RT_LIGHT_WEIGHT_FLOOR 1e-3
#endif

/// Importance of `p_light` at `p_hit_pos`. Always >= 0.
float lights_select_weight(vec3 p_hit_pos, RTLightData p_light, bool p_is_indirect_bounce) {
	// Magnitude, not signed luminance: compute_light_energy() applies sign = -1
	// for a negative light (render_raytracing.cpp:2755), so emission arrives
	// negative in every channel. A signed weight would corrupt the CDF. The sign
	// is uniform across channels, so abs(luminance(e)) == luminance(abs(e)).
	float mag = abs(luminance(p_light.emission));
	if (mag <= 0.0) {
		return 0.0;
	}

	// indirect_energy multiplies the contribution for every type on indirect
	// bounces (raytracing_lights_inc.glsl:321, :447, :490), so zero here means
	// zero contribution there -- matched, no bias.
	float indirect_factor = p_is_indirect_bounce ? p_light.indirect_energy : 1.0;
	if (indirect_factor <= 0.0) {
		return 0.0;
	}

	// Directional: no distance falloff, no cone, no range.
	if (p_light.type == RT_LIGHT_TYPE_DIRECTIONAL) {
		return mag * indirect_factor;
	}

	vec3 to_light = p_light.position - p_hit_pos;
	float dist_sq = dot(to_light, to_light);
	float dist = sqrt(dist_sq);

	// HAZARD 1 -- rect range. Shading range-tests the SAMPLED point on the quad
	// (:300) while this knows only the centre, so a rect straddling the boundary
	// would weigh 0 with part of it still lit. Expand by a conservative bound on
	// the half-diagonal. (length(U) + length(V) >= |U +/- V| for any U, V.)
	float near_dist = dist;
	if (p_light.type == RT_LIGHT_TYPE_RECT) {
		// For RECT, spot_direction is aliased to axisU (:269) -- it is NOT a cone axis.
		vec3 axis_u = p_light.spot_direction;
		vec3 axis_v = vec3(p_light.rect_axis_v[0], p_light.rect_axis_v[1], p_light.rect_axis_v[2]);
		near_dist = max(0.0, dist - (length(axis_u) + length(axis_v)));
	}
	if (p_light.max_range_squared != 0.0 && near_dist * near_dist > p_light.max_range_squared) {
		return 0.0;
	}

	float atten = lights_attenuation_from_dist_sq(dist_sq, p_light.inv_max_range, p_light.attenuation);

	float spot_factor = 1.0;
	// Gated on type, NOT on the falloff fields being populated: RECT lights also
	// carry a cos_spot_angle (they are spots with angle >= 179.9, see
	// render_raytracing.cpp:2887) and reusing it here would cone-cull a quad.
	if (p_light.type == RT_LIGHT_TYPE_SPOT) {
		vec3 L = to_light / max(dist, 1e-4);
		float scos = dot(-L, p_light.spot_direction);

		// HAZARD 2 -- spot cone. For a sphere light of radius r the SAMPLED
		// direction can be inside the cone while the centre direction is outside,
		// so widen the test by the angular radius asin(r/d). Done with the cosine
		// addition formula to avoid an acos/cos round trip:
		// cos(a + b) = cos a cos b - sin a sin b.
		float sin_b = clamp(p_light.radius / max(dist, 1e-4), 0.0, 1.0);
		float cos_b = sqrt(max(0.0, 1.0 - sin_b * sin_b));
		float cos_a = p_light.cos_spot_angle;
		float sin_a = sqrt(max(0.0, 1.0 - cos_a * cos_a));
		if (scos <= cos_a * cos_b - sin_a * sin_b) {
			return 0.0;
		}

		// CLAMPED TO 1.0, unlike the shading path's max(1e-4, ...) at :424.
		// Widening the cone above admits directions between the widened and the
		// true cone on purpose, and for exactly those the raw ratio exceeds 1,
		// making 1 - pow(ratio, k) NEGATIVE. A negative weight corrupts the CDF
		// walk far worse than the zero the widening exists to prevent.
		float spot_rim = clamp((1.0 - scos) / (1.0 - p_light.cos_spot_angle), 1e-4, 1.0);
		spot_factor = 1.0 - pow(spot_rim, p_light.inv_spot_attenuation);
	}

	// HAZARD 3 -- both continuous factors decay smoothly to zero at a boundary
	// the light's own extent straddles. The floor sits under their PRODUCT, after
	// the discrete tests above have already returned 0 for lights that truly
	// contribute nothing. Under each factor separately it would leak weight to
	// out-of-range lights; over the product it cannot, because those already
	// returned. Cost is variance on a rare configuration, which is the correct
	// direction to trade against a bias.
	float spatial = max(atten * spot_factor, RT_LIGHT_WEIGHT_FLOOR);

	return mag * spatial * indirect_factor;
}
```

- [ ] **Step 5: Include it from the lights header**

In `raytracing_lights_inc.glsl`, immediately after the `LightBuffer` SSBO declaration (currently ending line 69), add:

```glsl
// Importance-weighted selection (roadmap C2). Included here, after RTLightData
// and the rt_lights SSBO, because it reads both.
#include "raytracing_light_select_inc.glsl"
```

Step 1 already placed `lights_attenuation_from_dist_sq` above this point, which is what makes the include resolvable — GLSL has no forward declarations. Verify that ordering before building: the helper's definition must appear earlier in the file than this `#include`, and `RTLightData` plus the `rt_lights` SSBO must appear earlier still.

- [ ] **Step 6: Build and verify the mirror matches**

```bash
scons platform=windows tests=yes target=editor
```

Expected: clean build, `raytracing_light_select_inc.glsl` picked up by `glsl_builders.py`, `scene_raytracing_raygen.glsl.gen.h` regenerated.

Then read `mirror_weight` in the test file side by side with `lights_select_weight` in the GLSL and confirm every branch, constant, and comparison operator matches. This is a manual diff and it is the only thing keeping the mirror honest.

```bash
bin/godot.windows.editor.x86_64.exe --test "*LightSelect*"
```

Expected: **all cases PASS**.

- [ ] **Step 7: Run the full suite**

```bash
bin/godot.windows.editor.x86_64.exe --test
```

Expected: no regressions. Baseline before this branch was **1433 passed, 0 failed, 3 skipped**; this task adds 7 cases.

- [ ] **Step 8: Commit**

```bash
git add servers/rendering/renderer_rd/shaders/raytracing/raytracing_light_select_inc.glsl servers/rendering/renderer_rd/shaders/raytracing/raytracing_lights_inc.glsl tests/servers/rendering/test_pt_light_select.cpp
git commit -m "feat(pt): importance weight for analytic light selection (C2)"
```

---

### Task 2: The CDF draw and integration

**Files:**
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_light_select_inc.glsl` (add the draw)
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_lights_inc.glsl:19-21` (macro), `:333-382` (replace selection)
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_inc.glsl:259`
- Test: `tests/servers/rendering/test_pt_light_select.cpp` (append)

**Interfaces:**
- Consumes: `lights_select_weight(vec3, RTLightData, bool)` and `RT_LIGHT_WEIGHT_FLOOR` from Task 1; the `rt_lights[]` SSBO; `rng_1d(RNGState, uint)` (`raytracing_inc.glsl:297`).
- Produces: `bool lights_select(vec3 p_hit_pos, uint p_light_count, bool p_is_indirect_bounce, float p_u, out uint r_index, out float r_pdf)`; `#define RT_PRNG_LIGHT_SELECT 6u`; `#define RT_LIGHT_SELECT_UNIFORM 0`.

---

- [ ] **Step 1: Write the failing tests for the walk**

Append to `tests/servers/rendering/test_pt_light_select.cpp`, inside the namespace, before the closing brace:

```cpp
// Mirror of lights_select(). Takes weights directly so the walk can be tested
// independently of how they were produced.
static bool mirror_select(const std::vector<float> &p_weights, float p_u, uint32_t &r_index, float &r_pdf) {
	r_index = 0;
	r_pdf = 0.0f;

	float total = 0.0f;
	for (uint32_t i = 0; i < (uint32_t)p_weights.size(); i++) {
		total += p_weights[i];
	}
	if (!(total > 0.0f)) {
		return false;
	}

	const float target = p_u * total;
	float running = 0.0f;
	uint32_t last_pos = 0;
	float last_w = 0.0f;
	for (uint32_t i = 0; i < (uint32_t)p_weights.size(); i++) {
		const float w = p_weights[i];
		if (w <= 0.0f) {
			continue;
		}
		last_pos = i;
		last_w = w;
		running += w;
		if (running > target) {
			r_index = i;
			r_pdf = w / total;
			return true;
		}
	}
	// Drift guard: u * total landed at or past the accumulated sum through
	// floating-point rounding. The last positive-weight light is the answer.
	if (last_w > 0.0f) {
		r_index = last_pos;
		r_pdf = last_w / total;
		return true;
	}
	return false;
}

TEST_CASE("[PathTracer][LightSelect] selection frequency matches the weights") {
	std::vector<float> w;
	w.push_back(1.0f);
	w.push_back(7.0f);
	w.push_back(0.0f); // a zero-weight light must never be selected
	w.push_back(2.0f);
	const float total = 10.0f;

	const int N = 100000;
	int counts[4] = { 0, 0, 0, 0 };
	for (int i = 0; i < N; i++) {
		const float u = (float(i) + 0.5f) / float(N); // stratified, mirrors Sobol's job
		uint32_t idx = 0;
		float pdf = 0.0f;
		REQUIRE(mirror_select(w, u, idx, pdf));
		REQUIRE(idx < 4);
		counts[idx]++;
		CHECK(pdf == doctest::Approx(w[idx] / total));
	}
	CHECK(counts[2] == 0);
	CHECK(float(counts[0]) / float(N) == doctest::Approx(0.1f).epsilon(0.005));
	CHECK(float(counts[1]) / float(N) == doctest::Approx(0.7f).epsilon(0.005));
	CHECK(float(counts[3]) / float(N) == doctest::Approx(0.2f).epsilon(0.005));
}

TEST_CASE("[PathTracer][LightSelect] the pdf sums to one over all outcomes") {
	std::vector<float> w;
	w.push_back(3.0f);
	w.push_back(0.0f);
	w.push_back(11.0f);
	w.push_back(0.5f);

	// Every reachable outcome's pdf, summed, must be exactly 1.
	float sum = 0.0f;
	for (uint32_t i = 0; i < (uint32_t)w.size(); i++) {
		if (w[i] <= 0.0f) {
			continue;
		}
		sum += w[i] / 14.5f;
	}
	CHECK(sum == doctest::Approx(1.0f));

	// And the walk must agree with that pdf at every index it can return.
	for (int i = 0; i < 1000; i++) {
		uint32_t idx = 0;
		float pdf = 0.0f;
		REQUIRE(mirror_select(w, float(i) / 1000.0f, idx, pdf));
		CHECK(pdf == doctest::Approx(w[idx] / 14.5f));
	}
}

TEST_CASE("[PathTracer][LightSelect] the walk lands on the right side of each boundary") {
	std::vector<float> w;
	w.push_back(2.0f); // [0.0, 0.2)
	w.push_back(3.0f); // [0.2, 0.5)
	w.push_back(5.0f); // [0.5, 1.0)
	const float total = 10.0f;

	struct Probe {
		float u;
		uint32_t expect;
	};
	const Probe probes[] = {
		{ 0.0f, 0 },
		{ 0.19999f, 0 },
		{ 0.20001f, 1 },
		{ 0.49999f, 1 },
		{ 0.50001f, 2 },
		{ 0.99999f, 2 },
	};
	for (const Probe &p : probes) {
		uint32_t idx = 0;
		float pdf = 0.0f;
		REQUIRE(mirror_select(w, p.u, idx, pdf));
		CHECK(idx == p.expect);
		CHECK(pdf == doctest::Approx(w[p.expect] / total));
	}
}

TEST_CASE("[PathTracer][LightSelect] u at the top of the range stays in bounds") {
	std::vector<float> w;
	w.push_back(1.0f);
	w.push_back(2.0f);
	w.push_back(0.0f); // trailing zero: the clamp must NOT land here

	uint32_t idx = 99;
	float pdf = 0.0f;
	// Largest float strictly below 1.0 (bit pattern 0x3F7FFFFF). Math::nextafter
	// does not exist in this codebase -- there is no nextafter in core/math/math_funcs.h.
	const float u_max = 0.99999994f;
	REQUIRE(mirror_select(w, u_max, idx, pdf));
	CHECK(idx == 1); // the last POSITIVE-weight light, not index 2 and not index 3
	CHECK(pdf == doctest::Approx(2.0f / 3.0f));
}

TEST_CASE("[PathTracer][LightSelect] all-zero weights returns false, not index 0") {
	std::vector<float> w;
	w.push_back(0.0f);
	w.push_back(0.0f);

	uint32_t idx = 99;
	float pdf = -1.0f;
	CHECK_FALSE(mirror_select(w, 0.5f, idx, pdf));
	CHECK(pdf == 0.0f); // never a pdf of 0 paired with a "valid" index

	// Empty is the same case.
	std::vector<float> empty;
	CHECK_FALSE(mirror_select(empty, 0.5f, idx, pdf));
}
```

- [ ] **Step 2: Run to verify they fail**

```bash
scons platform=windows tests=yes target=editor && bin/godot.windows.editor.x86_64.exe --test "*LightSelect*"
```

Expected: clean compile (`<vector>` is already included from Task 1 Step 2 — `std::vector` is the container used by `tests/servers/rendering/test_pt_env_cdf.cpp`, so it is the established precedent here). All five new cases must then pass against the mirror. Record the result.

Note that these five test the mirror, not the shader — the mirror is written first so Step 3's GLSL can be checked against it line by line. That is the deliberate weakness of CPU-mirror TDD in this project, and it is why Task 3's rendered gates are the load-bearing evidence rather than these.

- [ ] **Step 3: Write the GLSL draw**

Append to `raytracing_light_select_inc.glsl`:

```glsl
/// Draw one light proportional to lights_select_weight(). Returns false when
/// every light weighs zero, which means every light contributes zero -- black is
/// the correct answer there, NOT a uniform fallback. A fallback would resume
/// sampling lights that provably contribute nothing.
///
/// Two passes over the <=64-light array (RT_LIGHTS_MAX, render_raytracing.h:170).
/// The second pass recomputes the weights rather than caching them: a 64-float
/// local array in a raytracing stage will very likely spill to scratch memory,
/// and the occupancy loss costs more than the arithmetic it saves.
bool lights_select(vec3 p_hit_pos, uint p_light_count, bool p_is_indirect_bounce, float p_u,
		out uint r_index, out float r_pdf) {
	r_index = 0u;
	r_pdf = 0.0;

	// Pass 1: normalizer.
	float total = 0.0;
	for (uint i = 0u; i < p_light_count; i++) {
		total += lights_select_weight(p_hit_pos, rt_lights[i], p_is_indirect_bounce);
	}
	// Written as !(total > 0.0) so a NaN normalizer takes this branch too.
	if (!(total > 0.0)) {
		return false;
	}

	// Pass 2: walk to u * total.
	float target = p_u * total;
	float running = 0.0;
	uint last_pos = 0u;
	float last_w = 0.0;
	for (uint i = 0u; i < p_light_count; i++) {
		float w = lights_select_weight(p_hit_pos, rt_lights[i], p_is_indirect_bounce);
		if (w <= 0.0) {
			continue;
		}
		last_pos = i;
		last_w = w;
		running += w;
		if (running > target) {
			r_index = i;
			r_pdf = w / total;
			return true;
		}
	}

	// Drift guard. The two passes sum the same values in the same order, but
	// u * total can still land at or past the final running sum through rounding.
	// Answer with the last positive-weight light -- never an index past the array,
	// and never a zero-weight light (which would be a pdf of 0 on a taken path).
	if (last_w > 0.0) {
		r_index = last_pos;
		r_pdf = last_w / total;
		return true;
	}
	return false; // Unreachable while total > 0; kept so every path returns.
}
```

- [ ] **Step 4: Rename the sampler dimension**

In `raytracing_inc.glsl`, replace line 259 with:

```glsl
#define RT_PRNG_LIGHT_SELECT 6u // 1D: which analytic light to sample.
```

The comment at `:260-262` marking `RT_PRNG_ENV` as the last free slot stays correct and unchanged — this renames slot 6 in place rather than claiming a new one, so `RT_PRNG_BOUNCE_NUM` does not grow and nothing downstream re-stratifies. Under `RT_LIGHT_SELECT_UNIFORM` the same slot seeds the old PCG side stream; the slot's *purpose* is unchanged, only its mechanism.

- [ ] **Step 5: Replace the selection block**

In `raytracing_lights_inc.glsl`, replace lines 19-21 with:

```glsl
// A/B switch for roadmap C2, kept permanently as measurement scaffolding rather
// than deleted after the phase. Precedent: COMBINE_BRDFS_WITH_FRESNEL
// (brdf_inc.glsl:158) is the only reason B2's +2.4% converged-mean shift could
// be pinned to a specific line instead of guessed at.
//   0 = power-weighted CDF (production)
//   1 = the pre-C2 uniform k=16 mini-batch reservoir
#ifndef RT_LIGHT_SELECT_UNIFORM
#define RT_LIGHT_SELECT_UNIFORM 0
#endif

#if RT_LIGHT_SELECT_UNIFORM
// Reservoir sampling batch size for stochastic light selection.
#ifndef RT_LIGHT_RESERVOIR_SIZE
#define RT_LIGHT_RESERVOIR_SIZE 16
#endif
#endif
```

Then replace lines 345-384 (from the `// Mini-batch reservoir sampling:` comment through `RTLightData light = rt_lights[selected_idx];`) with:

```glsl
#if RT_LIGHT_SELECT_UNIFORM
	// PRE-C2 CONTROL PATH. Uniform mini-batch reservoir. Two defects, both fixed
	// by the production path below: with 41 lights and k=16 the brightest light
	// is never considered at ~60% of shading points, and light_select_pdf is
	// ESTIMATED rather than known -- valid_count_estimate is a random variable
	// and E[1/X] != 1/E[X], so the density is biased whenever range culling
	// rejects anything. Kept only to A/B the change.
	const uint k = uint(min(RT_LIGHT_RESERVOIR_SIZE, int(light_count)));
	uint valid_found = 0u;
	uint selected_idx = 0u;

	uint reservoir_stream = rng_side_stream(p_rng, RT_PRNG_LIGHT_SELECT);
	for (uint i = 0u; i < k; i++) {
		uint idx = min(uint(rand(reservoir_stream) * float(light_count)), light_count - 1u);
		RTLightData test_light = rt_lights[idx];

		bool is_positional = (test_light.type == RT_LIGHT_TYPE_OMNI || test_light.type == RT_LIGHT_TYPE_SPOT || test_light.type == RT_LIGHT_TYPE_RECT);
		bool is_valid = !is_positional;
		if (!is_valid) {
			vec3 to_l = test_light.position - hit_pos;
			float d2 = dot(to_l, to_l);
			is_valid = (test_light.max_range_squared == 0.0 || d2 <= test_light.max_range_squared);
		}

		if (is_valid) {
			valid_found++;
			if (rand(reservoir_stream) < 1.0 / float(valid_found)) {
				selected_idx = idx;
			}
		}
	}

	if (valid_found == 0u) {
		return vec3(0.0);
	}

	float valid_count_estimate = float(light_count) * (float(valid_found) / float(k));
	float light_select_pdf = 1.0 / max(valid_count_estimate, 1.0);
#else
	// Power-weighted CDF (roadmap C2). One Sobol draw, exact pdf.
	uint selected_idx;
	float light_select_pdf;
	if (!lights_select(hit_pos, light_count, is_indirect_bounce,
				rng_1d(p_rng, RT_PRNG_LIGHT_SELECT), selected_idx, light_select_pdf)) {
		// Every light weighs zero, so every light contributes zero.
		return vec3(0.0);
	}
#endif

	RTLightData light = rt_lights[selected_idx];
```

Delete the now-stale note at the old `:350-353` predicting this migration (it is superseded by the block above). Leave everything from `vec2 u = rng_2d(p_rng, RT_PRNG_LIGHT);` onward untouched — the four per-type branches already divide by `light_select_pdf` and continue to.

- [ ] **Step 6: Build and run**

```bash
scons platform=windows tests=yes target=editor && bin/godot.windows.editor.x86_64.exe --test
```

Expected: clean build, full suite green, all 12 `LightSelect` cases passing.

- [ ] **Step 7: Verify the control path still compiles**

The A/B macro is worthless if the branch nobody builds has rotted. Temporarily set `RT_LIGHT_SELECT_UNIFORM` to `1` in `raytracing_lights_inc.glsl`, run a full build, confirm it succeeds, then set it back to `0` and rebuild.

```bash
scons platform=windows target=editor
```

Expected: both settings build clean. Task 3 depends on this.

- [ ] **Step 8: Commit**

```bash
git add servers/rendering/renderer_rd/shaders/raytracing/raytracing_light_select_inc.glsl servers/rendering/renderer_rd/shaders/raytracing/raytracing_lights_inc.glsl servers/rendering/renderer_rd/shaders/raytracing/raytracing_inc.glsl tests/servers/rendering/test_pt_light_select.cpp
git commit -m "feat(pt): power-weighted CDF light selection with exact pdf (C2)"
```

---

### Task 3: Gates, measurement, and closeout

**Files:**
- Create: `pipeline_references/tests/pt_light_gate.gd`, `pipeline_references/tests/pt_light_gate_scene.tscn`
- Create: `pipeline_references/tests/pt_light_rmse.gd`, `pipeline_references/tests/pt_light_rmse_scene.tscn`
- Modify: `PATH_TRACER_QUALITY_ROADMAP.md`

**Interfaces:**
- Consumes: the shipped selector from Task 2 and the `RT_LIGHT_SELECT_UNIFORM` macro.
- Produces: recorded numbers in the roadmap and in `.superpowers/sdd/2026-08-11-power-weighted-light-selection/task-3-report.md`.

**Read first:** `pipeline_references/tests/pt_sky_rmse.gd` and `pipeline_references/tests/pt_energy_gate.gd`. Both new harnesses extend `res://tests/pt_validation.gd` and follow those files' structure for accumulation, EXR readback, and reporting. Do not invent a new harness shape.

---

- [ ] **Step 1: Build the two gate scenes**

Create `pipeline_references/tests/pt_light_gate.gd` extending `res://tests/pt_validation.gd`, driven by `ZR_GATE_MODE` (`"in_range"` | `"culled"` | `"both"`, default `"both"`) and `ZR_GATE_FRAMES` (default 256), matching `pt_energy_gate.gd`'s env-var convention.

Scene construction, both modes: a Lambertian floor plane of albedo 0.5, camera looking straight down, no sky (`BG_COLOR`, black), `SKY_MODE_LIGHT_ONLY` nowhere needed since there is no sky.

```gdscript
# GATE 1 - "in_range": every light within range.
#
# The pre-C2 estimator was EXACT here: with no light failing the range test,
# valid_found == k deterministically, so valid_count_estimate == light_count with
# zero variance and 1/estimate is the true density. The converged mean therefore
# must NOT move. This is the only configuration where neutrality is the correct
# assertion.
func _build_in_range(root: Node3D) -> void:
	for i in range(16):
		var l := OmniLight3D.new()
		var a := TAU * float(i) / 16.0
		l.position = Vector3(cos(a) * 3.0, 4.0, sin(a) * 3.0)
		l.omni_range = 100.0          # far beyond any surface distance
		l.light_energy = 1.0 + float(i) * 0.5   # deliberately unequal: equal
		                                        # energies make power weighting a
		                                        # no-op and the gate blind
		l.light_color = Color(1, 1, 1)
		root.add_child(l)

# GATE 2 - "culled": half the lights out of range at the sampled surface.
#
# The pre-C2 pdf was BIASED here, so the mean SHOULD move and asserting
# neutrality would be asserting the bug. Predict the direction before measuring.
func _build_culled(root: Node3D) -> void:
	for i in range(16):
		var l := OmniLight3D.new()
		var a := TAU * float(i) / 16.0
		l.position = Vector3(cos(a) * 3.0, 4.0, sin(a) * 3.0)
		# Odd-indexed lights cannot reach the floor at y = 0.
		l.omni_range = 100.0 if (i % 2 == 0) else 2.0
		l.light_energy = 1.0 + float(i) * 0.5
		l.light_color = Color(1, 1, 1)
		root.add_child(l)
```

- [ ] **Step 2: Record the prediction BEFORE measuring**

Write `.superpowers/sdd/2026-08-11-power-weighted-light-selection/gate2-prediction.md` and commit it **before running gate 2**:

> Gate 2 (`culled`) direction prediction. The pre-C2 estimator sets
> `light_select_pdf = 1 / (light_count × valid_found / k)`. With 8 of 16 lights
> out of range, `E[valid_found] = k/2`, so the estimate centres on
> `light_count/2 = 8` and the pdf on `1/8` — which is correct on average. The
> bias is in the *reciprocal*: `E[1/X̂] ≥ 1/E[X̂]` by Jensen, since `1/x` is
> convex. So the pre-C2 divisor is on average **too large**, and the pre-C2 image
> is therefore **too bright**. **Prediction: the C2 mean is LOWER than the
> pre-C2 mean on gate 2.** Magnitude expected to be small — a few percent at
> `k = 16`, since the relative variance of `valid_found` goes as `1/k`.

Commit it. If the measurement contradicts this, record that it did and investigate; do **not** quietly revise the prediction.

- [ ] **Step 3: Run gate 1 and assert neutrality**

Build the control, capture, rebuild the treatment, capture:

```bash
scons platform=windows target=editor
bin/godot.windows.editor.x86_64.exe --path pipeline_references res://tests/pt_light_gate_scene.tscn
```

with `ZR_GATE_MODE=in_range`, once at `RT_LIGHT_SELECT_UNIFORM 1` and once at `0`.

Expected: the two converged means agree within the tolerance `pt_energy_gate.gd` already uses. A shift here is a **bug**, not a finding — gate 1 is the configuration where the old estimator was exact.

- [ ] **Step 4: Liveness probe — prove the two builds actually differ**

Before recording any figure, confirm the control and treatment binaries produce **different** numbers on a configuration where they must. Gate 2 is that configuration.

In B4, a `git stash` on an already-committed path silently no-opped and one measurement compared a build against itself; it was caught only because a probe read a value the control could not produce. Two identical readings here mean the macro edit did not reach the shader — most likely a stale `.glsl.gen.h` from an incremental build. Re-run a **full** `scons platform=windows target=editor` and re-check before proceeding.

- [ ] **Step 5: Run gate 2 and compare against the prediction**

Run both builds with `ZR_GATE_MODE=culled`. Record both means, the signed difference, and whether the Step 2 prediction held. Record it either way.

- [ ] **Step 6: Build the RMSE measurement scene**

Create `pipeline_references/tests/pt_light_rmse.gd` + scene, modelled on `pt_sky_rmse.gd`. The scene is the roadmap's accept criterion made concrete (`PATH_TRACER_QUALITY_ROADMAP.md:523`):

```gdscript
# One bright key among 40 dim fills. The key carries ~97% of the scene's total
# power, so uniform selection spends ~97.6% of its draws (40/41) on lights that
# contribute ~3% of the light -- and with k = 16 it fails to CONSIDER the key at
# all at roughly (1 - 1/41)^16 = 67% of shading points.
func _build_lights(root: Node3D) -> void:
	var key := OmniLight3D.new()
	key.position = Vector3(0.0, 5.0, 0.0)
	key.light_energy = 200.0
	key.omni_range = 100.0
	key.light_color = Color(1, 1, 1)
	root.add_child(key)

	for i in range(40):
		var f := OmniLight3D.new()
		var a := TAU * float(i) / 40.0
		f.position = Vector3(cos(a) * 6.0, 2.0 + float(i % 4), sin(a) * 6.0)
		f.light_energy = 0.15
		f.omni_range = 100.0
		f.light_color = Color(1, 1, 1)
		root.add_child(f)
```

Geometry: the same Lambertian floor plus a few occluders so shadow rays do real work — a uniform selector and a weighted one converge identically on an unoccluded plane lit from directly above, which would make the measurement blind to the thing it is measuring.

- [ ] **Step 7: Measure RMSE, per-sample and equal-time**

Follow `pt_sky_rmse.gd`'s reference/sweep structure: a converged reference (matched between builds — generate it **once** with the treatment build and reuse it for both, so the reference is not itself a variable), then RMSE at a sweep of sample counts for each build, plus wall-clock frame time.

Report **both**:
- **per-sample RMSE ratio** at matched sample counts, and
- **equal-time RMSE ratio**, which is what decides this change — selection went from 16 iterations to as many as 128.

Report the equal-time figure as a **range across the whole sweep**, and take the floor from the sweep's own minimum. In the sky phase an equal-time headline was quoted from a subset of rows and had to be corrected from "5.3–6.9×" to "4.82–6.91×".

**Accept:** *"one bright key among 40 dim fills converges at several× the current rate"* — read as equal-time RMSE.

- [ ] **Step 8: Write the results report**

Create `.superpowers/sdd/2026-08-11-power-weighted-light-selection/task-3-report.md` with the full method and every number: gate 1 neutrality, gate 2 shift and whether the prediction held, per-sample and equal-time RMSE ranges, frame-time delta, and the liveness-probe evidence from Step 4. State the limits — single scene, one light configuration, omni lights only (spot and rect weighting paths are exercised by unit tests but by no rendered measurement).

- [ ] **Step 9: Update the roadmap**

In `PATH_TRACER_QUALITY_ROADMAP.md`:

1. Rewrite the **C2** entry (`:521-523`) as done, with the measured figures and a pointer to the task-3 report, following the shape of the C3 entry at `:525-538`.
2. **Correct the claim at `:681-685`.** It reads that C1 gates extending MIS weights beyond the environment "until emissive meshes are NEE-sampleable and analytic lights are BSDF-reachable". Analytic lights are never BSDF-reachable: omni, spot, directional and `RT_LIGHT_TYPE_RECT` are pure buffer data with no TLAS presence, so no BSDF ray can hit one, before or after C1. Replace with: C1 gates MIS for **emissive meshes**, which are real TLAS geometry and therefore reachable by both strategies. Analytic lights correctly carry no MIS weight permanently.
3. Update the ordering summary at `:669` — C2 is done, C1 remains.
4. Add to the open-items list: the surface-normal cosine is deliberately excluded from the weight (spec §3.5), so roughly half of all selection draws still go to lights facing away from the shading point and are discarded by the existing `NdotL <= 0` tests. Frame-time recovery, not a correctness issue.

- [ ] **Step 10: Full suite and commit**

```bash
bin/godot.windows.editor.x86_64.exe --test
```

Expected: **1433 + 12 = 1445 passed, 0 failed, 3 skipped.**

```bash
git add pipeline_references/tests/pt_light_gate.gd pipeline_references/tests/pt_light_gate_scene.tscn pipeline_references/tests/pt_light_rmse.gd pipeline_references/tests/pt_light_rmse_scene.tscn PATH_TRACER_QUALITY_ROADMAP.md .superpowers/sdd/2026-08-11-power-weighted-light-selection/
git commit -m "test(pt): energy gates and RMSE measurement for C2, close out"
```

---

## Notes for reviewers

Three specific things worth checking hard, from what went wrong in the previous two phases:

1. **Is `light_can_contribute` in the test file derived from the shading code, or from `mirror_weight`?** If from the latter, the load-bearing property test asserts that a function equals itself and proves nothing. This is the single highest-value review check in the plan.
2. **Does every weight input dimension go non-extremal in at least one case?** The weight is a product of four factors; a suite where some factor is always `1.0` pins only the others. Three separate Phase B blind spots had correct assertions and test data that failed to exercise the thing under test — the constant-sky gate that could not fail, the convergence test blind to the `u` axis, the RR reduction test where red was already the max.
3. **Was the liveness probe (Task 3 Step 4) actually run, and did it show a difference?** Any equal-time or gate figure recorded without it is unsupported.
