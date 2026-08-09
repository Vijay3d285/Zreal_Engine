# Sky NEE + Multiple Importance Sampling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the path tracer sample the sky directly (importance-sampled by sky radiance) and combine that with the BSDF sky hits it already has, using Multiple Importance Sampling.

**Architecture:** A GPU compute pass builds a 2D sampling distribution over a lat-long resampling of the existing sky octmap. A new shader include samples directions from it and evaluates their pdf. The ray payload widens to carry the BSDF pdf so MIS weights can be formed at the miss shader. The analytic-light path is untouched.

**Tech Stack:** C++17 (Godot 4.7 fork), GLSL 4.5 (Vulkan RD ray-tracing + compute), SCons, doctest.

**Spec:** `docs/superpowers/specs/2026-08-09-sky-nee-and-mis-design.md` — read §1 before starting; it explains why MIS alone would have *lost energy*.

## Global Constraints

- **Build command**, always FOREGROUND and BLOCKING, never backgrounded:
  `python -m SCons platform=windows target=editor arch=x86_64 d3d12=no tests=yes`
  The shell tool caps at 10 minutes and a cold build exceeds that — if cut off, **run the same command again**; object files persist and each run makes progress. Only stop if the build FAILS with errors.
- **`tests=yes` is mandatory** on every build.
- **Every new test `.cpp` under `tests/` MUST contain `TEST_FORCE_LINK(<file basename>)`** immediately after `#include "tests/test_macros.h"`, or the link fails with `unresolved external symbol force_link_test_<basename>`.
- **Editing any `.glsl` requires a full scons build** so `*.glsl.gen.h` regenerate. Never hand-edit a `.gen.h`.
- **Do not edit `C:\Zlendo2026\ZlenderRender_stage_copy\`.** Pipeline script changes go in `pipeline_references/` only.
- **Godot style:** tabs, `p_` prefix on parameters, `r_` on out-params, Godot copyright header on new files (canonical copy: `tests/servers/rendering/test_pt_accumulator.cpp` lines 1-29).
- **Do not `git add -A` or `git add .`.** Stage only files you deliberately changed.
- **Engine is Y-up** (Cycles is Z-up). Direction ↔ angle conversion follows the convention already in `ies_lookup_inc.glsl`: `θ = acos(clamp(dir.y, -1, 1))`, `φ = atan(dir.x, dir.z)`.
- **Sampling and pdf evaluation must share one function.** If they ever diverge, MIS biases silently and no convergence test will catch it.
- **The analytic-light NEE path must not change.** No MIS weight is applied to it — analytic lights are unreachable by BSDF rays, so weighting them would lose energy. This is the central finding of the spec.

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `servers/rendering/renderer_rd/shaders/raytracing/brdf_inc.glsl` | Modify | Add `combinedPdf()` — the mixture pdf of the diffuse+specular lobe split |
| `servers/rendering/renderer_rd/shaders/raytracing/raytracing_inc.glsl` | Modify | 48-byte payload, `mis_ray_pdf`, `power_heuristic()`, `RT_PRNG_ENV` |
| `servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl` | Modify | Record the BSDF pdf; call env NEE; apply the NEE-side MIS weight |
| `servers/rendering/renderer_rd/shaders/raytracing/scene_raytracing_raygen.glsl` | Modify | Init `mis_ray_pdf`; apply the BSDF-side MIS weight in the miss stage |
| `servers/rendering/renderer_rd/shaders/raytracing/env_cdf_build.glsl` | **Create** | Compute shader: build the sampling distribution over the sky |
| `servers/rendering/renderer_rd/shaders/raytracing/raytracing_env_sampling_inc.glsl` | **Create** | `env_sample()` / `env_pdf()` — the shared pdf lives here |
| `servers/rendering/renderer_rd/storage_rd/env_cdf.{h,cpp}` | **Create** | Owns the distribution SSBO, dirty flag, dispatch |
| `servers/rendering/renderer_rd/forward_clustered/render_raytracing.cpp` | Modify | Bind the SSBO; trigger rebuild on sky change |
| `tests/servers/rendering/test_pt_brdf_pdf.cpp` | **Create** | pdf normalization tests for both lobes |
| `tests/servers/rendering/test_pt_env_cdf.cpp` | **Create** | CDF inversion round-trip, pdf integrates to 1, power heuristic |

---

## Distribution layout (referenced by Tasks 2, 3, 4)

Grid is `N_U = 256` (azimuth) × `N_V = 128` (polar). All floats, one SSBO:

```
[0]                          floor          (relative epsilon, see below)
[1]                          marginal_total (= Σ rowsum_adj)
[2 .. 2+N_V*N_U-1]           prefix_raw     row-major inclusive prefix sums of raw f
[2+N_V*N_U .. +N_V-1]        rowsum_adj     rowsum_raw[y] + N_U * floor
[.. +N_V-1]                  marginal_prefix inclusive prefix of rowsum_adj
```

Total `2 + 128*256 + 128 + 128 = 32898` floats ≈ 132 KB.

**Why prefix sums of the *raw* f, with the floor applied arithmetically:** the floor is defined relative to the grid mean, which is not known until every cell has been summed. Storing raw prefixes lets the floor be folded in at lookup time — `adjusted_prefix(y,x) = prefix_raw[y][x] + (x+1)*floor` — so the build needs two dispatches instead of four, and no cell is ever rebuilt.

---

### Task 1: Carry the BSDF pdf on the payload (B1)

The BRDF library already has both lobe pdfs (`sampleHemisphere(u, pdf)` at `brdf_inc.glsl:413`, `sampleGGXVNDFReflectionPdf` at `:812`, aliased to `specularPdf` at `:242`) and already has `evalCombinedBRDF` at `:1056`. What is missing is the **mixture pdf**: the density this material's sampler assigns to an arbitrary direction. This task adds it and widens the payload.

**Why a mixture pdf and not the selected lobe's pdf.** The sampler picks one lobe stochastically with probability `P_spec` / `P_diff`, so the effective density of the direction it returns is `P_spec·pdf_spec(L) + P_diff·pdf_diff(L)` — *both* terms, because either lobe could have produced that direction. Using only the chosen lobe's term underestimates the density, which makes the BSDF-side MIS weight too small and **loses energy**. This is the standard one-sample-model treatment (PBRT does the same for multi-lobe BSDFs). Writing it as one function of `(N, L, V, material)` also means Task 4 can evaluate the BSDF pdf for a direction *it* chose, which a sampling-time out-parameter could never provide.

**Files:**
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/brdf_inc.glsl` (add `combinedPdf` next to `evalCombinedBRDF`, ~line 1056)
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_inc.glsl` (payload structs, `power_heuristic`, `RT_PRNG_ENV`)
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl` (`shade_and_bounce`)
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/scene_raytracing_raygen.glsl` (`trace_one_sample`)
- Create: `tests/servers/rendering/test_pt_brdf_pdf.cpp`

Note `evalIndirectCombinedBRDF` is **not** modified — no signature change, no call-site churn in `debug_visualize`.

**Interfaces:**
- Consumes: nothing from later tasks.
- Produces:
  - GLSL `float combinedPdf(float3 N, float3 L, float3 V, MaterialProperties material)`
  - GLSL `float power_heuristic(float p_a, float p_b)`
  - GLSL `PathPayload.mis_ray_pdf` (negative = "no MIS, weight 1")
  - GLSL `const float RT_MIS_PDF_NONE`, `const float RT_MIS_DELTA_ROUGHNESS`
  - GLSL `#define RT_PRNG_ENV 7u`

- [ ] **Step 1: Write the failing test**

Create `tests/servers/rendering/test_pt_brdf_pdf.cpp`. Copy the 30-line Godot copyright header verbatim from `tests/servers/rendering/test_pt_accumulator.cpp:1-29`, changing only the filename on line 2. Then:

```cpp
#include "tests/test_macros.h"

TEST_FORCE_LINK(test_pt_brdf_pdf)

#include "core/math/math_funcs.h"

namespace TestPTBrdfPdf {

// CPU mirrors of the pdf formulas in
// servers/rendering/renderer_rd/shaders/raytracing/brdf_inc.glsl.
// A pdf that is not normalized silently biases MIS: the image still looks
// plausible, it just converges to the wrong answer. These tests integrate each
// pdf numerically over the hemisphere and assert it comes to 1.

// brdf_inc.glsl: diffusePdf() — cosine-weighted hemisphere.
static double diffuse_pdf(double p_n_dot_l) {
	return p_n_dot_l / Math_PI;
}

// brdf_inc.glsl: sampleGGXVNDFReflectionPdf().
// PDF of the microfacet normal is (G1 * D); the 1/(4*NdotV) comes from the
// Jacobian of the reflection operator.
static double ggx_d(double p_alpha_sq, double p_n_dot_h) {
	const double b = (p_alpha_sq - 1.0) * p_n_dot_h * p_n_dot_h + 1.0;
	return p_alpha_sq / (Math_PI * b * b);
}

static double smith_g1_ggx(double p_alpha_sq, double p_n_dot_v) {
	const double n_dot_v_sq = p_n_dot_v * p_n_dot_v;
	return 2.0 / (Math::sqrt(((p_alpha_sq * (1.0 - n_dot_v_sq)) + n_dot_v_sq) / n_dot_v_sq) + 1.0);
}

static double vndf_reflection_pdf(double p_alpha_sq, double p_n_dot_h, double p_n_dot_v) {
	return ggx_d(p_alpha_sq, p_n_dot_h) * smith_g1_ggx(p_alpha_sq, p_n_dot_v) / (4.0 * p_n_dot_v);
}

// Integrate f(theta, phi) over the hemisphere with a regular grid.
// dOmega = sin(theta) dTheta dPhi.
static double integrate_hemisphere(double (*p_f)(double, double, double), double p_param, double p_n_dot_v) {
	const int N_THETA = 400;
	const int N_PHI = 400;
	double sum = 0.0;
	for (int i = 0; i < N_THETA; i++) {
		const double theta = (i + 0.5) * (Math_PI * 0.5) / N_THETA;
		for (int j = 0; j < N_PHI; j++) {
			const double phi = (j + 0.5) * (2.0 * Math_PI) / N_PHI;
			sum += p_f(theta, phi, p_param == 0.0 ? p_n_dot_v : p_param) * Math::sin(theta);
		}
	}
	return sum * (Math_PI * 0.5 / N_THETA) * (2.0 * Math_PI / N_PHI);
}

static double diffuse_integrand(double p_theta, double /*p_phi*/, double /*p_unused*/) {
	return diffuse_pdf(Math::cos(p_theta));
}

TEST_CASE("[PathTracer][BrdfPdf] cosine-weighted hemisphere pdf integrates to 1") {
	const double total = integrate_hemisphere(diffuse_integrand, 1.0, 1.0);
	CHECK(total == doctest::Approx(1.0).epsilon(0.005));
}

TEST_CASE("[PathTracer][BrdfPdf] cosine pdf is non-negative and zero at grazing") {
	CHECK(diffuse_pdf(0.0) == doctest::Approx(0.0));
	CHECK(diffuse_pdf(1.0) > 0.0);
	CHECK(diffuse_pdf(1.0) == doctest::Approx(1.0 / Math_PI));
}

TEST_CASE("[PathTracer][BrdfPdf] GGX VNDF reflection pdf integrates to ~1 over the hemisphere") {
	// VNDF sampling is exact for the visible-normal distribution, so integrating
	// the reflection pdf over outgoing directions returns 1 up to the small
	// amount of mass reflected below the horizon at high roughness.
	for (double alpha : { 0.1, 0.3, 0.6 }) {
		const double alpha_sq = alpha * alpha;
		const double n_dot_v = 0.8;
		const int N = 600;
		double sum = 0.0;
		for (int i = 0; i < N; i++) {
			const double theta = (i + 0.5) * (Math_PI * 0.5) / N;
			for (int j = 0; j < N; j++) {
				const double phi = (j + 0.5) * (2.0 * Math_PI) / N;
				// Outgoing direction L in a frame where N = +Z and V lies in the XZ plane.
				const double lx = Math::sin(theta) * Math::cos(phi);
				const double ly = Math::sin(theta) * Math::sin(phi);
				const double lz = Math::cos(theta);
				const double vx = Math::sqrt(1.0 - n_dot_v * n_dot_v);
				const double vz = n_dot_v;
				double hx = vx + lx, hy = ly, hz = vz + lz;
				const double hlen = Math::sqrt(hx * hx + hy * hy + hz * hz);
				if (hlen < 1e-9) {
					continue;
				}
				hx /= hlen;
				hy /= hlen;
				hz /= hlen;
				if (hz <= 0.0) {
					continue;
				}
				sum += vndf_reflection_pdf(alpha_sq, hz, n_dot_v) * Math::sin(theta) *
						(Math_PI * 0.5 / N) * (2.0 * Math_PI / N);
			}
		}
		CHECK(sum > 0.90);
		CHECK(sum < 1.02);
	}
}

TEST_CASE("[PathTracer][BrdfPdf] power heuristic is a partition of unity") {
	// Mirrors power_heuristic() in raytracing_inc.glsl. The two strategies'
	// weights must sum to exactly 1, or MIS gains or loses energy.
	auto ph = [](double a, double b) { return (a * a) / (a * a + b * b); };
	for (double a : { 0.01, 0.5, 3.0, 100.0 }) {
		for (double b : { 0.02, 0.7, 5.0, 250.0 }) {
			CHECK(ph(a, b) + ph(b, a) == doctest::Approx(1.0));
		}
	}
	CHECK(ph(1.0, 0.0) == doctest::Approx(1.0));
}

} // namespace TestPTBrdfPdf
```

- [ ] **Step 2: Build and run the new tests**

```bash
python -m SCons platform=windows target=editor arch=x86_64 d3d12=no tests=yes
```

```bash
bin/godot.windows.editor.x86_64.exe --test --test-case="*BrdfPdf*"
```

Expected: 4 cases pass. As in earlier phases of this project, the C++ mirror is both the specification and the code under test — the GLSL is brought into agreement in Step 3 and checked against the mirror by eye. If a case fails, the formula is wrong; fix it against `brdf_inc.glsl` before continuing.

- [ ] **Step 3: Add `combinedPdf` to the BRDF library**

In `brdf_inc.glsl`, immediately after `evalCombinedBRDF` (~line 1078), add:

```glsl
// PDF that the combined diffuse+specular sampler in evalIndirectCombinedBRDF
// would assign to an arbitrary direction L.
//
// The sampler picks ONE lobe stochastically, so the effective density of any
// direction it returns is the mixture of both lobes weighted by their selection
// probabilities. Using only the selected lobe's term underestimates the density
// and loses energy through the MIS weight -- see the plan's Task 1 preamble.
//
// The lobe split here MUST stay identical to the one in shade_and_bounce
// (raytracing_closest_hit_common_inc.glsl). If they drift, MIS weights become
// inconsistent with how directions are actually generated.
float combinedPdf(float3 N, float3 L, float3 V, MaterialProperties material) {
	float NdotL = dot(N, L);
	if (NdotL <= 0.0f) {
		return 0.0f;
	}

	// Lobe selection probability, mirroring shade_and_bounce.
	float3 specularF0 = baseColorToSpecularF0(material.baseColor, material.metalness, material.dielectricF0);
	float3 diffuseReflectance = baseColorToDiffuseReflectance(material.baseColor, material.metalness);
	float specularLum = luminance(specularF0);
	float diffuseLum = luminance(diffuseReflectance);

	float pSpec;
	if (diffuseLum < 0.0001f) {
		pSpec = 1.0f;
	} else if (specularLum < 0.0001f) {
		pSpec = 0.0f;
	} else {
		pSpec = clamp(specularLum / (specularLum + diffuseLum), 0.01f, 0.99f);
	}

	// Diffuse lobe: cosine-weighted hemisphere.
	float pdfDiffuse = diffusePdf(NdotL);

	// Specular lobe: VNDF reflection pdf. Built in the local frame where N = +Z,
	// matching how sampleSpecular generates directions.
	float4 qRotationToZ = getRotationToZAxis(N);
	float3 Llocal = rotatePoint(qRotationToZ, L);
	float3 Vlocal = rotatePoint(qRotationToZ, V);
	const BrdfData data = prepareBRDFData(float3(0.0f, 0.0f, 1.0f), Llocal, Vlocal, material);

	float3 Hlocal = normalize(Vlocal + Llocal);
	float NdotH = max(0.00001f, Hlocal.z);
	float NdotV = max(0.00001f, Vlocal.z);
	float LdotH = max(0.00001f, dot(Llocal, Hlocal));
	float pdfSpecular = specularPdf(data.alpha, data.alphaSquared, NdotH, NdotV, LdotH);

	return pSpec * pdfSpecular + (1.0f - pSpec) * pdfDiffuse;
}
```

Add the corresponding mixture case to the CPU mirror in `test_pt_brdf_pdf.cpp` and assert it integrates to 1 for a mixed-material case (`pSpec = 0.3`), by the same hemisphere quadrature the other two cases use. A mixture of two normalized pdfs with weights summing to 1 is itself normalized, so this test catches a wrong weight or a dropped term.

- [ ] **Step 4: Widen the payload and add the MIS helpers**

In `raytracing_inc.glsl`, replace the `PathPayload` and `PathState` structs and their pack/unpack with:

```glsl
// ============================================================================
// PATHTRACING PAYLOAD (48 bytes nominal, fp32 radiance/throughput)
// ============================================================================
// Radiance and throughput are fp32: the previous fp16 packing clamped radiance
// at 65504 and banded in deep specular tails. `mis_ray_pdf` carries the BSDF pdf
// of the ray that produced this segment, so the miss shader can form a MIS
// weight against the environment pdf. A NEGATIVE value means "no MIS, use
// weight 1" -- see RT_MIS_PDF_NONE below.
//
// NOTE ON SIZE: 48 bytes assumes vec3 packs at 12 bytes in the payload. Some
// drivers pad vec3 to 16, making the effective size 56. Either way both stages
// declare the identical struct so they agree; the frame-time measurement in
// Step 8 is what tells us whether the growth cost anything.

struct PathPayload {
	vec3 radiance; // 12 bytes
	vec3 throughput; // 12 bytes
	uint packed_bounces_flags; //  4 bytes - [flags:8][glossy:8][diffuse:8][total:8]
	uint rng_packed; //  4 bytes - packed [sample_index:20][dimension offset:12]
	float hit_t; //  4 bytes - ray distance, used by raygen to rebuild origin
	uint oct_offset_nrm; //  4 bytes - packUnorm2x16(vec3_to_oct(offset normal))
	uint oct_next_dir; //  4 bytes - packUnorm2x16(vec3_to_oct(next direction))
	float mis_ray_pdf; //  4 bytes - BSDF pdf of this segment, <0 = no MIS
};

/// Sentinel: this ray has no meaningful BSDF pdf, so anything it hits takes the
/// full contribution (MIS weight 1). Used for primary camera rays and for
/// near-delta specular lobes that environment sampling can never reach.
/// Mirrors Cycles' PATH_RAY_MIS_SKIP.
const float RT_MIS_PDF_NONE = -1.0;

/// Unpacked working copy of the payload.
struct PathState {
	vec3 radiance;
	vec3 throughput;
	uint packed_bounces_flags;
	uint rng_packed;
	float hit_t;
	vec3 offset_normal;
	vec3 next_ray_dir;
	float mis_ray_pdf;
};

PathState path_unpack(PathPayload p) {
	PathState s;
	s.radiance = max(p.radiance, vec3(0.0));
	s.throughput = max(p.throughput, vec3(0.0));
	s.packed_bounces_flags = p.packed_bounces_flags;
	s.rng_packed = p.rng_packed;
	s.hit_t = p.hit_t;
	s.offset_normal = oct_to_vec3(unpackUnorm2x16(p.oct_offset_nrm) * 2.0 - 1.0);
	s.next_ray_dir = oct_to_vec3(unpackUnorm2x16(p.oct_next_dir) * 2.0 - 1.0);
	s.mis_ray_pdf = p.mis_ray_pdf;
	return s;
}

void path_pack(inout PathPayload p, PathState s) {
	p.radiance = max(s.radiance, vec3(0.0));
	p.throughput = max(s.throughput, vec3(0.0));
	p.packed_bounces_flags = s.packed_bounces_flags;
	p.rng_packed = s.rng_packed;
	p.hit_t = s.hit_t;
	p.oct_offset_nrm = packUnorm2x16(vec3_to_oct(s.offset_normal));
	p.oct_next_dir = packUnorm2x16(vec3_to_oct(s.next_ray_dir));
	p.mis_ray_pdf = s.mis_ray_pdf;
}
```

Add the dimension slot next to the other `RT_PRNG_*` defines:

```glsl
#define RT_PRNG_ENV 7u // 2D: direction sample on the environment. LAST FREE SLOT
                       // in the 8-dimension per-bounce block; anything added
                       // after this must widen RT_PRNG_BOUNCE_NUM (Cycles uses 16).
```

Add the MIS weight helper near `clamp_contribution`:

```glsl
// ============================================================================
// MULTIPLE IMPORTANCE SAMPLING
// ============================================================================

/// Power heuristic with beta = 2, matching Cycles (intern/cycles/kernel/light/sample.h).
/// power_heuristic(a, b) + power_heuristic(b, a) == 1 exactly, which is what makes
/// the combined estimator unbiased: the two strategies' weights partition the
/// contribution rather than scaling it.
float power_heuristic(float p_a, float p_b) {
	float a2 = p_a * p_a;
	float b2 = p_b * p_b;
	float denom = a2 + b2;
	return (denom > 0.0) ? (a2 / denom) : 0.0;
}
```

- [ ] **Step 5: Record the pdf onto the payload**

No call-site changes are needed — `evalIndirectCombinedBRDF` keeps its signature. In `raytracing_closest_hit_common_inc.glsl`, in `shade_and_bounce`, just before the final `path_pack(payload, ps);`, add:

```glsl
	// Density the BSDF strategy assigned to the direction we just chose. This is
	// the mixture over both lobes, not just the one that was selected -- see
	// combinedPdf in brdf_inc.glsl.
	//
	// Near-delta specular lobes cannot be reached by environment sampling at all,
	// so anything this ray hits must take the FULL contribution rather than a MIS
	// share. Mirrors Cycles' PATH_RAY_MIS_SKIP.
	ps.mis_ray_pdf = (brdfType == SPECULAR_TYPE && brdf_mat.roughness < RT_MIS_DELTA_ROUGHNESS)
			? RT_MIS_PDF_NONE
			: combinedPdf(N, next_dir, V, brdf_mat);
```

Place it after `next_dir` has been finalized — i.e. after the below-hemisphere recovery block, not before, or the pdf will describe a direction the ray does not actually take.

Add the threshold constant next to `RT_MIS_PDF_NONE` in `raytracing_inc.glsl`:

```glsl
/// Below this roughness a specular lobe is treated as delta for MIS purposes.
/// Matches the existing MAX_DENOISER_SPECULAR_HIT_THRESHOLD family of cutoffs.
const float RT_MIS_DELTA_ROUGHNESS = 0.03;
```

- [ ] **Step 6: Initialize the sentinel in raygen**

In `scene_raytracing_raygen.glsl`, in `trace_one_sample`, next to the other `ps.*` initializers add:

```glsl
	// The camera ray has no preceding BSDF sample, so sky seen directly through a
	// window takes its full contribution.
	ps.mis_ray_pdf = RT_MIS_PDF_NONE;
```

- [ ] **Step 7: Build, test, and measure frame time**

```bash
python -m SCons platform=windows target=editor arch=x86_64 d3d12=no tests=yes
```

```bash
bin/godot.windows.editor.x86_64.exe --test
```

Expected: full suite passes with 4 more cases than the previous baseline.

Then run the validation scene and record its wall-clock time and convergence figure:

```bash
bin/godot.windows.editor.x86_64.exe --path pipeline_references res://tests/pt_validation_scene.tscn
```

**The spec requires this measurement** (§4): the payload grew from 32 to 48 bytes at the project owner's direction, against a recommendation of +4, and the roadmap says to profile and fall back if occupancy regresses. Report the before/after wall-clock. The convergence figure should be materially unchanged (~9.6x) since no sampling behaviour changed yet — if it moved, something else did too, and that must be reported rather than explained away.

- [ ] **Step 8: Commit**

```bash
git add servers/rendering/renderer_rd/shaders/raytracing/ tests/servers/rendering/test_pt_brdf_pdf.cpp
git commit -m "feat(pt): carry the BSDF mixture pdf on a widened fp32 ray payload"
```

---

### Task 2: Build the environment sampling distribution on the GPU

**Files:**
- Create: `servers/rendering/renderer_rd/shaders/raytracing/env_cdf_build.glsl`
- Create: `servers/rendering/renderer_rd/storage_rd/env_cdf.{h,cpp}`
- Modify: `servers/rendering/renderer_rd/forward_clustered/render_raytracing.cpp`
- Create: `tests/servers/rendering/test_pt_env_cdf.cpp`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces:
  - C++ `class EnvCDF` with `void mark_dirty()`, `void update(RID p_radiance_texture, RID p_sampler)`, `RID get_buffer() const`
  - The SSBO layout documented under "Distribution layout" above, bound at **set 0, binding 34** in the raytracing set (33 is the Phase A variance image; 34 is the next free one — verify with `git grep "binding = 3" servers/rendering/renderer_rd/shaders/raytracing/` before assuming).

- [ ] **Step 1: Write the failing test**

Create `tests/servers/rendering/test_pt_env_cdf.cpp` with the Godot copyright header copied verbatim from `test_pt_accumulator.cpp:1-29` (filename changed on line 2), then:

```cpp
#include "tests/test_macros.h"

TEST_FORCE_LINK(test_pt_env_cdf)

#include "core/math/math_funcs.h"
#include <vector>

namespace TestPTEnvCDF {

// CPU mirror of env_cdf_build.glsl + raytracing_env_sampling_inc.glsl.
// The invariant these tests protect: the pdf used to SAMPLE and the pdf used to
// EVALUATE must be the same function. If they drift apart, MIS produces a
// biased result that still looks like a plausible image.

static const int N_U = 256;
static const int N_V = 128;

struct Dist {
	float floor_value = 0.0f;
	float marginal_total = 0.0f;
	std::vector<float> prefix_raw; // N_V * N_U, row-major inclusive prefix
	std::vector<float> rowsum_adj; // N_V
	std::vector<float> marginal_prefix; // N_V
};

// Build from a luminance function of (u, v) in [0,1).
static Dist build(float (*p_lum)(float, float)) {
	Dist d;
	d.prefix_raw.assign(N_V * N_U, 0.0f);
	d.rowsum_adj.assign(N_V, 0.0f);
	d.marginal_prefix.assign(N_V, 0.0f);

	std::vector<float> raw(N_V * N_U, 0.0f);
	double total_raw = 0.0;
	for (int y = 0; y < N_V; y++) {
		const float v = (y + 0.5f) / float(N_V);
		const float sin_theta = Math::sin(v * Math_PI);
		for (int x = 0; x < N_U; x++) {
			const float u = (x + 0.5f) / float(N_U);
			const float f = p_lum(u, v) * sin_theta;
			raw[y * N_U + x] = f;
			total_raw += f;
		}
	}

	// Relative floor: keeps the pdf strictly positive everywhere without
	// assuming absolute radiance units.
	d.floor_value = float(1e-4 * (total_raw / double(N_U * N_V)));

	double running_marginal = 0.0;
	for (int y = 0; y < N_V; y++) {
		double running = 0.0;
		for (int x = 0; x < N_U; x++) {
			running += raw[y * N_U + x];
			d.prefix_raw[y * N_U + x] = float(running);
		}
		d.rowsum_adj[y] = float(running + double(N_U) * d.floor_value);
		running_marginal += d.rowsum_adj[y];
		d.marginal_prefix[y] = float(running_marginal);
	}
	d.marginal_total = float(running_marginal);
	return d;
}

// f with the floor folded in, reconstructed from the raw prefix sums.
static float cell_value(const Dist &p_d, int p_y, int p_x) {
	const float lo = (p_x == 0) ? 0.0f : p_d.prefix_raw[p_y * N_U + p_x - 1];
	return (p_d.prefix_raw[p_y * N_U + p_x] - lo) + p_d.floor_value;
}

// pdf over solid angle for the cell containing (u, v).
static double pdf_omega(const Dist &p_d, float p_u, float p_v) {
	const int x = CLAMP(int(p_u * N_U), 0, N_U - 1);
	const int y = CLAMP(int(p_v * N_V), 0, N_V - 1);
	const double func_int = double(p_d.marginal_total) / double(N_U * N_V);
	const double pdf_uv = double(cell_value(p_d, y, x)) / func_int;
	const double sin_theta = Math::sin(double(p_v) * Math_PI);
	return pdf_uv / (2.0 * Math_PI * Math_PI * MAX(sin_theta, 1e-6));
}

// Sample (u, v) by inverting the marginal then the row conditional.
static void sample_uv(const Dist &p_d, float p_r0, float p_r1, float &r_u, float &r_v) {
	const float target_v = p_r1 * p_d.marginal_total;
	int y = 0;
	while (y < N_V - 1 && p_d.marginal_prefix[y] < target_v) {
		y++;
	}
	const float target_u = p_r0 * p_d.rowsum_adj[y];
	int x = 0;
	while (x < N_U - 1) {
		const float adj = p_d.prefix_raw[y * N_U + x] + float(x + 1) * p_d.floor_value;
		if (adj >= target_u) {
			break;
		}
		x++;
	}
	r_u = (x + 0.5f) / float(N_U);
	r_v = (y + 0.5f) / float(N_V);
}

static float lum_constant(float, float) {
	return 1.0f;
}

static float lum_sun(float p_u, float p_v) {
	// A small bright spot plus a dim background.
	const float du = p_u - 0.25f;
	const float dv = p_v - 0.30f;
	return (du * du + dv * dv < 0.0016f) ? 500.0f : 0.05f;
}

TEST_CASE("[PathTracer][EnvCDF] pdf integrates to 1 over the sphere (constant sky)") {
	const Dist d = build(lum_constant);
	double total = 0.0;
	for (int y = 0; y < N_V; y++) {
		const double v = (y + 0.5) / double(N_V);
		const double theta = v * Math_PI;
		for (int x = 0; x < N_U; x++) {
			const double u = (x + 0.5) / double(N_U);
			// dOmega for this cell = sin(theta) * dTheta * dPhi.
			const double d_omega = Math::sin(theta) * (Math_PI / N_V) * (2.0 * Math_PI / N_U);
			total += pdf_omega(d, float(u), float(v)) * d_omega;
		}
	}
	CHECK(total == doctest::Approx(1.0).epsilon(0.01));
}

TEST_CASE("[PathTracer][EnvCDF] pdf integrates to 1 over the sphere (bright sun)") {
	const Dist d = build(lum_sun);
	double total = 0.0;
	for (int y = 0; y < N_V; y++) {
		const double v = (y + 0.5) / double(N_V);
		const double theta = v * Math_PI;
		for (int x = 0; x < N_U; x++) {
			const double u = (x + 0.5) / double(N_U);
			const double d_omega = Math::sin(theta) * (Math_PI / N_V) * (2.0 * Math_PI / N_U);
			total += pdf_omega(d, float(u), float(v)) * d_omega;
		}
	}
	CHECK(total == doctest::Approx(1.0).epsilon(0.01));
}

TEST_CASE("[PathTracer][EnvCDF] sampling concentrates on the bright region") {
	// The whole point of importance sampling: most samples should land on the sun.
	const Dist d = build(lum_sun);
	int hits = 0;
	const int N = 4096;
	for (int i = 0; i < N; i++) {
		const float r0 = (i % 64 + 0.5f) / 64.0f;
		const float r1 = (i / 64 + 0.5f) / 64.0f;
		float u, v;
		sample_uv(d, r0, r1, u, v);
		const float du = u - 0.25f;
		const float dv = v - 0.30f;
		if (du * du + dv * dv < 0.0016f) {
			hits++;
		}
	}
	// The sun covers ~0.5% of the (u,v) domain but carries most of the energy.
	CHECK(hits > N / 2);
}

TEST_CASE("[PathTracer][EnvCDF] every cell has strictly positive pdf") {
	// A zero-pdf direction with nonzero radiance gives unbounded variance and a
	// biased estimate. This is what the relative floor exists to prevent.
	const Dist d = build(lum_sun);
	for (int y = 0; y < N_V; y++) {
		for (int x = 0; x < N_U; x++) {
			CHECK(cell_value(d, y, x) > 0.0f);
		}
	}
}

TEST_CASE("[PathTracer][EnvCDF] sampled cells round-trip through the pdf lookup") {
	// Sampling returns a cell; evaluating the pdf at that cell's own (u,v) must
	// pick the same cell. This is the sample/evaluate agreement invariant.
	const Dist d = build(lum_sun);
	for (int i = 0; i < 256; i++) {
		const float r0 = (i % 16 + 0.5f) / 16.0f;
		const float r1 = (i / 16 + 0.5f) / 16.0f;
		float u, v;
		sample_uv(d, r0, r1, u, v);
		const int x = CLAMP(int(u * N_U), 0, N_U - 1);
		const int y = CLAMP(int(v * N_V), 0, N_V - 1);
		CHECK(pdf_omega(d, u, v) == doctest::Approx(
				double(cell_value(d, y, x)) /
				(double(d.marginal_total) / double(N_U * N_V)) /
				(2.0 * Math_PI * Math_PI * MAX(Math::sin(double(v) * Math_PI), 1e-6))));
	}
}

} // namespace TestPTEnvCDF
```

- [ ] **Step 2: Build and run**

```bash
python -m SCons platform=windows target=editor arch=x86_64 d3d12=no tests=yes
```

```bash
bin/godot.windows.editor.x86_64.exe --test --test-case="*EnvCDF*"
```

Expected: 5 cases pass.

- [ ] **Step 3: Write the compute shader**

Create `servers/rendering/renderer_rd/shaders/raytracing/env_cdf_build.glsl`:

```glsl
#[compute]

#version 450

#VERSION_DEFINES

#include "../oct_inc.glsl"

// Builds a 2D sampling distribution over the sky for environment NEE.
// A CPU mirror lives in tests/servers/rendering/test_pt_env_cdf.cpp; change both
// together or the tests stop meaning anything.
//
// Two dispatches:
//   MODE_ROWS     one workgroup per row: raw f, row prefix sums, row sum
//   MODE_MARGINAL one workgroup: floor from the grand total, then the marginal
//
// The floor is relative to the grid mean, which is not known until every cell is
// summed. Rather than rebuild every cell in a third pass, the rows pass stores
// prefix sums of the RAW f and the floor is folded in arithmetically at lookup:
//   adjusted_prefix(y, x) = prefix_raw[y][x] + (x + 1) * floor

#define N_U 256
#define N_V 128

layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform texture2D radiance_octmap;
layout(set = 0, binding = 1) uniform sampler radiance_sampler;

layout(set = 0, binding = 2, std430) restrict buffer EnvDist {
	float floor_value;
	float marginal_total;
	float data[]; // prefix_raw[N_V*N_U], rowsum_adj[N_V], marginal_prefix[N_V]
}
dist;

#define PREFIX_RAW_OFFSET 0
#define ROWSUM_ADJ_OFFSET (N_V * N_U)
#define MARGINAL_PREFIX_OFFSET (N_V * N_U + N_V)

layout(push_constant, std430) uniform Params {
	uint mode; // 0 = rows, 1 = marginal
	uint pad0;
	uint pad1;
	uint pad2;
}
params;

shared float row_vals[N_U];

/// Direction for grid cell centre (u, v). Engine is Y-up; matches the
/// convention in ies_lookup_inc.glsl.
vec3 dir_from_uv(float u, float v) {
	float phi = u * 2.0 * 3.141592653589;
	float theta = v * 3.141592653589;
	float st = sin(theta);
	return vec3(st * sin(phi), cos(theta), st * cos(phi));
}

float cell_raw(uint x, uint y) {
	float u = (float(x) + 0.5) / float(N_U);
	float v = (float(y) + 0.5) / float(N_V);
	vec3 d = dir_from_uv(u, v);
	vec3 rad = textureLod(sampler2D(radiance_octmap, radiance_sampler), vec3_to_oct(d), 0.0).rgb;
	float lum = dot(rad, vec3(0.2126, 0.7152, 0.0722));
	// sin(theta) converts the (u,v) density to a solid-angle density.
	return max(lum, 0.0) * sin(v * 3.141592653589);
}

void main() {
	if (params.mode == 0u) {
		// --- Rows pass: one workgroup per row, 256 threads. ---
		uint y = gl_WorkGroupID.x;
		uint x = gl_LocalInvocationID.x;

		row_vals[x] = cell_raw(x, y);
		barrier();

		// Serial inclusive scan by one thread. 256 elements is trivial next to the
		// texture fetches above, and it avoids a fiddly parallel-scan bug surface.
		if (x == 0u) {
			float running = 0.0;
			for (uint i = 0u; i < uint(N_U); i++) {
				running += row_vals[i];
				dist.data[PREFIX_RAW_OFFSET + y * uint(N_U) + i] = running;
			}
			// Row sum without the floor; the marginal pass adds it.
			dist.data[ROWSUM_ADJ_OFFSET + y] = running;
		}
	} else {
		// --- Marginal pass: one workgroup, first thread only. ---
		if (gl_GlobalInvocationID.x != 0u) {
			return;
		}
		float total_raw = 0.0;
		for (uint y = 0u; y < uint(N_V); y++) {
			total_raw += dist.data[ROWSUM_ADJ_OFFSET + y];
		}
		float mean = total_raw / float(N_U * N_V);
		float fl = 1e-4 * mean;
		dist.floor_value = fl;

		float running = 0.0;
		for (uint y = 0u; y < uint(N_V); y++) {
			float adj = dist.data[ROWSUM_ADJ_OFFSET + y] + float(N_U) * fl;
			dist.data[ROWSUM_ADJ_OFFSET + y] = adj;
			running += adj;
			dist.data[MARGINAL_PREFIX_OFFSET + y] = running;
		}
		dist.marginal_total = running;
	}
}
```

- [ ] **Step 4: Write the storage class**

Create `servers/rendering/renderer_rd/storage_rd/env_cdf.h` and `.cpp`. Follow the structure of `servers/rendering/renderer_rd/storage_rd/ies_manager.{h,cpp}` — same Godot header, same singleton-free member style, same `RenderingDevice` usage. The class owns:

```cpp
class EnvCDF {
	static constexpr uint32_t N_U = 256;
	static constexpr uint32_t N_V = 128;
	static constexpr uint32_t FLOAT_COUNT = 2 + N_V * N_U + N_V + N_V;

	RID buffer;
	RID shader;
	RID pipeline;
	bool dirty = true;

public:
	void mark_dirty() { dirty = true; }
	// No-ops when not dirty. p_radiance_texture may be invalid, in which case the
	// buffer is left as-is and callers must not sample the environment.
	void update(RID p_radiance_texture, RID p_sampler);
	RID get_buffer() const { return buffer; }
	bool is_valid() const { return buffer.is_valid(); }

	EnvCDF();
	~EnvCDF();
};
```

`update()` allocates the buffer on first use (`FLOAT_COUNT * sizeof(float)` bytes), then dispatches `env_cdf_build.glsl` twice — once with `mode = 0` and `N_V` workgroups, once with `mode = 1` and one workgroup — with a `RD::barrier()` between them. Set `dirty = false` at the end.

- [ ] **Step 5: Bind it and trigger rebuilds**

In `render_raytracing.cpp`, add an `EnvCDF` member to the raytracing state, call `update()` from the same place the radiance texture is resolved (~line 3218, where binding 7 is filled), and add a uniform for the SSBO:

```cpp
	// Binding 34: environment sampling distribution (env NEE).
	{
		RD::Uniform u;
		u.binding = 34;
		u.uniform_type = RD::UNIFORM_TYPE_STORAGE_BUFFER;
		if (env_cdf.is_valid()) {
			u.append_id(env_cdf.get_buffer());
		} else {
			u.append_id(RendererRD::MeshStorage::get_singleton()->get_default_rd_storage_buffer());
		}
		uniforms.push_back(u);
	}
```

Call `env_cdf.mark_dirty()` wherever the sky's radiance texture changes. If no single such site exists, marking dirty whenever `radiance_texture` differs from the previously-bound RID is sufficient and is what this plan assumes — record in the report which trigger was used.

- [ ] **Step 6: Build and run the full suite**

```bash
python -m SCons platform=windows target=editor arch=x86_64 d3d12=no tests=yes
```

```bash
bin/godot.windows.editor.x86_64.exe --test
```

Expected: full suite passes, 5 cases more than at the end of Task 1.

- [ ] **Step 7: Verify the distribution is actually built on the GPU**

```bash
bin/godot.windows.editor.x86_64.exe --path pipeline_references res://tests/pt_validation_scene.tscn
```

Expected: the scene still renders and passes. Nothing samples the distribution yet, so the image must be **byte-identical in behaviour** to Task 1 — the convergence figure should not move beyond run-to-run noise. If it moved, the SSBO binding disturbed something.

- [ ] **Step 8: Commit**

```bash
git add servers/rendering/renderer_rd/shaders/raytracing/env_cdf_build.glsl servers/rendering/renderer_rd/storage_rd/env_cdf.h servers/rendering/renderer_rd/storage_rd/env_cdf.cpp servers/rendering/renderer_rd/forward_clustered/render_raytracing.cpp tests/servers/rendering/test_pt_env_cdf.cpp
git commit -m "feat(pt): build a GPU sampling distribution over the sky"
```

---

### Task 3: Environment sampling and pdf evaluation in GLSL

**Files:**
- Create: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_env_sampling_inc.glsl`
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_inc.glsl` (include it)

**Interfaces:**
- Consumes: the SSBO layout from Task 2.
- Produces:
  - `vec3 env_direction_from_uv(vec2 p_uv)`
  - `vec2 env_uv_from_direction(vec3 p_dir)`
  - `float env_pdf_from_uv(vec2 p_uv)` — solid-angle pdf, the single shared formula
  - `bool env_sample(vec2 p_rand, out vec3 r_dir, out float r_pdf)`

- [ ] **Step 1: Write the shader**

Create `raytracing_env_sampling_inc.glsl`:

```glsl
// Environment (sky) importance sampling for NEE.
// Requires: the EnvDist SSBO at set 0 binding 34 and radiance_octmap/sampler.
//
// A CPU mirror of this math lives in tests/servers/rendering/test_pt_env_cdf.cpp.
//
// CRITICAL INVARIANT: env_sample() and env_pdf_from_uv() must agree exactly.
// A BSDF ray that hits the sky is weighted against the pdf this file reports for
// its direction; if sampling and evaluation use different formulas, MIS is biased
// and no convergence test will catch it.

#define ENV_N_U 256
#define ENV_N_V 128
#define ENV_PI 3.141592653589

layout(set = 0, binding = 34, std430) restrict readonly buffer EnvDistRO {
	float floor_value;
	float marginal_total;
	float data[];
}
env_dist;

#define ENV_PREFIX_RAW_OFFSET 0
#define ENV_ROWSUM_ADJ_OFFSET (ENV_N_V * ENV_N_U)
#define ENV_MARGINAL_PREFIX_OFFSET (ENV_N_V * ENV_N_U + ENV_N_V)

/// Y-up direction for a (u, v) in [0,1)^2. Matches ies_lookup_inc.glsl.
vec3 env_direction_from_uv(vec2 p_uv) {
	float phi = p_uv.x * 2.0 * ENV_PI;
	float theta = p_uv.y * ENV_PI;
	float st = sin(theta);
	return vec3(st * sin(phi), cos(theta), st * cos(phi));
}

/// Inverse of env_direction_from_uv.
vec2 env_uv_from_direction(vec3 p_dir) {
	float theta = acos(clamp(p_dir.y, -1.0, 1.0));
	float phi = atan(p_dir.x, p_dir.z);
	if (phi < 0.0) {
		phi += 2.0 * ENV_PI;
	}
	return vec2(phi / (2.0 * ENV_PI), theta / ENV_PI);
}

/// f for a cell, with the relative floor folded in.
float env_cell_value(int p_x, int p_y) {
	int idx = ENV_PREFIX_RAW_OFFSET + p_y * ENV_N_U + p_x;
	float lo = (p_x == 0) ? 0.0 : env_dist.data[idx - 1];
	return (env_dist.data[idx] - lo) + env_dist.floor_value;
}

/// Solid-angle pdf for the cell containing p_uv. THE shared formula.
float env_pdf_from_uv(vec2 p_uv) {
	if (env_dist.marginal_total <= 0.0) {
		return 0.0;
	}
	int x = clamp(int(p_uv.x * float(ENV_N_U)), 0, ENV_N_U - 1);
	int y = clamp(int(p_uv.y * float(ENV_N_V)), 0, ENV_N_V - 1);
	float func_int = env_dist.marginal_total / float(ENV_N_U * ENV_N_V);
	float pdf_uv = env_cell_value(x, y) / func_int;
	float sin_theta = sin(p_uv.y * ENV_PI);
	return pdf_uv / (2.0 * ENV_PI * ENV_PI * max(sin_theta, 1e-6));
}

/// Convenience: pdf for an arbitrary world direction.
float env_pdf(vec3 p_dir) {
	return env_pdf_from_uv(env_uv_from_direction(p_dir));
}

/// Sample a direction proportional to sky radiance. Returns false when no usable
/// distribution exists (no environment, or an all-black sky).
bool env_sample(vec2 p_rand, out vec3 r_dir, out float r_pdf) {
	r_dir = vec3(0.0, 1.0, 0.0);
	r_pdf = 0.0;
	if (env_dist.marginal_total <= 0.0) {
		return false;
	}

	// Invert the marginal (binary search over rows).
	float target_v = p_rand.y * env_dist.marginal_total;
	int lo = 0;
	int hi = ENV_N_V - 1;
	while (lo < hi) {
		int mid = (lo + hi) >> 1;
		if (env_dist.data[ENV_MARGINAL_PREFIX_OFFSET + mid] < target_v) {
			lo = mid + 1;
		} else {
			hi = mid;
		}
	}
	int y = lo;

	// Invert the row conditional. The stored prefixes are of the RAW f, so the
	// floor is added arithmetically here -- see the layout note in the plan.
	float target_u = p_rand.x * env_dist.data[ENV_ROWSUM_ADJ_OFFSET + y];
	lo = 0;
	hi = ENV_N_U - 1;
	while (lo < hi) {
		int mid = (lo + hi) >> 1;
		float adj = env_dist.data[ENV_PREFIX_RAW_OFFSET + y * ENV_N_U + mid] +
				float(mid + 1) * env_dist.floor_value;
		if (adj < target_u) {
			lo = mid + 1;
		} else {
			hi = mid;
		}
	}
	int x = lo;

	vec2 uv = vec2((float(x) + 0.5) / float(ENV_N_U), (float(y) + 0.5) / float(ENV_N_V));
	r_dir = env_direction_from_uv(uv);
	r_pdf = env_pdf_from_uv(uv);
	return r_pdf > 0.0;
}
```

Add the include in `raytracing_inc.glsl` after the `sobol_burley_inc.glsl` include:

```glsl
#include "raytracing_env_sampling_inc.glsl"
```

- [ ] **Step 2: Build**

```bash
python -m SCons platform=windows target=editor arch=x86_64 d3d12=no tests=yes
```

Expected: clean build. Nothing calls these functions yet, so behaviour is unchanged.

- [ ] **Step 3: Diff the GLSL against the CPU mirror**

Read `raytracing_env_sampling_inc.glsl` and the mirror in `test_pt_env_cdf.cpp` side by side. Confirm identical: the `sin θ` placement, the `2π²` divisor, the `1e-6` guard, the floor arithmetic `+ float(mid + 1) * floor_value`, and the cell-index clamping. **The mirror uses a linear scan and the shader uses a binary search — verify they select the same cell for the same input**, since that is the one place the two are allowed to differ in form but not in result.

- [ ] **Step 4: Run the full suite**

```bash
bin/godot.windows.editor.x86_64.exe --test
```

Expected: unchanged from Task 2.

- [ ] **Step 5: Commit**

```bash
git add servers/rendering/renderer_rd/shaders/raytracing/
git commit -m "feat(pt): add environment sampling and pdf evaluation"
```

---

### Task 4: Wire up environment NEE with MIS

The task that changes the image. Both MIS sides land together so energy is correct at the end of it.

**Files:**
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl`
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/scene_raytracing_raygen.glsl` (miss stage)
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_lights_inc.glsl` (reuse the shadow-ray helper)

**Interfaces:**
- Consumes: `env_sample`, `env_pdf` (Task 3); `power_heuristic`, `RT_MIS_PDF_NONE`, `RT_PRNG_ENV`, `PathState.mis_ray_pdf` (Task 1).
- Produces: nothing for later tasks.

- [ ] **Step 1: Add environment NEE at the shading site**

In `raytracing_closest_hit_common_inc.glsl`, inside `shade_and_bounce`, immediately after the existing analytic-light NEE block, add:

```glsl
	// =================================================================
	// Environment NEE (roadmap C3), MIS-combined with BSDF sky hits.
	// This is a SEPARATE strategy from the analytic-light reservoir: its pdf is
	// exact, which MIS requires, whereas the reservoir's selection pdf is a
	// stochastic estimate. The analytic-light path above is untouched.
	// =================================================================
	{
		vec3 env_dir;
		float env_pdf_val;
		if (env_sample(rng_2d(rng, RT_PRNG_ENV), env_dir, env_pdf_val) && dot(env_dir, N) > 0.0) {
			vec3 env_origin = offset_ray_origin(h.hit_pos, h.geometry_normal);
			if (lights_trace_shadow_ray(env_origin, env_dir, 10000.0)) {
				vec3 sky_rad = textureLod(sampler2D(radiance_octmap, radiance_sampler),
						vec3_to_oct(env_dir), 0.0).rgb;

				// BSDF value for this direction, and the pdf the BSDF strategy
				// would have used to generate it. evalCombinedBRDF returns
				// f * cos(theta).
				vec3 bsdf_val = evalCombinedBRDF(N, env_dir, V, brdf_mat);
				float bsdf_pdf_for_dir = combinedPdf(N, env_dir, V, brdf_mat);

				float w = power_heuristic(env_pdf_val, bsdf_pdf_for_dir);
				vec3 contrib = ps.throughput * bsdf_val * sky_rad * (w / env_pdf_val);
				ps.radiance += clamp_contribution(contrib, clamp_limit);
			}
		}
	}
```

Both BRDF helpers this uses already exist by the time you reach here: `evalCombinedBRDF` was already in `brdf_inc.glsl:1056` before this plan started, and `combinedPdf` was added in Task 1 Step 3. Nothing new to write in `brdf_inc.glsl` for this task.

`raytracing_env_sampling_inc.glsl` declares the SSBO but the `radiance_octmap` / `radiance_sampler` uniforms it samples for radiance are declared in the raygen and miss stages. Confirm the closest-hit stage also has them in scope; if not, add the same `layout(set = 0, binding = 7/8)` declarations there rather than duplicating the texture in another binding.

- [ ] **Step 2: Apply the BSDF-side MIS weight in the miss shader**

In `scene_raytracing_raygen.glsl`'s miss stage, where sky radiance is added to the path, weight it:

```glsl
	// MIS: this ray reached the sky by BSDF sampling. If environment NEE could
	// also have sampled this direction, take only this strategy's share.
	// A negative mis_ray_pdf means the ray was a primary camera ray or a
	// near-delta specular bounce that env NEE cannot reach -- full contribution.
	float mis_w = 1.0;
	if (ps.mis_ray_pdf >= 0.0) {
		float e_pdf = env_pdf(gl_WorldRayDirectionEXT);
		mis_w = power_heuristic(ps.mis_ray_pdf, e_pdf);
	}
	ps.radiance += ps.throughput * sky_radiance * mis_w;
```

Locate the existing line that adds sky radiance and replace it; do not add a second one.

- [ ] **Step 3: Build**

```bash
python -m SCons platform=windows target=editor arch=x86_64 d3d12=no tests=yes
```

- [ ] **Step 4: Run the constant-sky energy test — the primary acceptance gate**

Create a temporary test scene, or extend `pipeline_references/tests/run_pt_validation.gd`, with: a constant-radiance environment `L = 1.0`, a single unoccluded diffuse plane of albedo `ρ = 0.5`, no analytic lights, camera looking straight at the plane.

Expected: converged pixel radiance = `ρ · L = 0.5`, within 1%.

**This is the gate.** MIS's failure mode is losing or double-counting energy while still producing a plausible image. Report the measured value. If it reads ~1.0 the two strategies are double-counting (a weight is missing); if ~0.25 one side is being weighted twice. Do not proceed past this step with a failing energy check — report it instead.

Revert any temporary scene edits afterwards and prove it with `git status --short`.

- [ ] **Step 5: Run the full suite and the validation scene**

```bash
bin/godot.windows.editor.x86_64.exe --test
```

```bash
bin/godot.windows.editor.x86_64.exe --path pipeline_references res://tests/pt_validation_scene.tscn
```

Report the convergence figure and the wall-clock time. The extra shadow ray per shading point costs time; that cost is expected and should be reported as a number.

- [ ] **Step 6: Commit**

```bash
git add servers/rendering/renderer_rd/shaders/raytracing/
git commit -m "feat(pt): environment NEE combined with BSDF sky hits via MIS"
```

---

### Task 5: Measure, document, and close out

**Files:**
- Modify: `PATH_TRACER_QUALITY_ROADMAP.md`
- Modify: `pipeline_references/image_glb_creation.gd`

**Interfaces:**
- Consumes: everything above.
- Produces: nothing.

- [ ] **Step 1: Measure the variance reduction**

On a daylight interior, render at matched sample counts with environment NEE effectively on versus off. To get an "off" baseline without a code path for it, check out the shader directory at the commit before Task 4 into the working tree, rebuild, measure, then restore — the same technique used to measure the Sobol sampler:

```bash
git checkout <task-3-commit> -- servers/rendering/renderer_rd/shaders/raytracing/
python -m SCons platform=windows target=editor arch=x86_64 d3d12=no tests=yes
bin/godot.windows.editor.x86_64.exe --path pipeline_references res://tests/pt_validation_scene.tscn
git checkout HEAD -- servers/rendering/renderer_rd/shaders/raytracing/
python -m SCons platform=windows target=editor arch=x86_64 d3d12=no tests=yes
```

Verify with `git status --short` that the restore left nothing behind.

**Acceptance:** RMSE against a high-sample reference is lower with env NEE at every sample count in the sweep. Do **not** require any particular scaling of the improvement ratio with sample count — the Phase B correction applies: a sampler converging faster than N^-0.5 necessarily widens its lead as N grows, so a shrinking ratio would be the surprising result, not a reassuring one.

**Regression guard:** mean luminance of a fully converged render must match the pre-change build within noise. MIS redistributes variance, not energy — a shifted converged mean means an energy bug that the constant-sky test missed.

- [ ] **Step 2: Update the roadmap**

Mark **C3** done and **B1**/**B2** done. Record, factually:

- the measured RMSE comparison and the frame-time cost of the extra shadow ray;
- that MIS currently combines the environment only, because analytic lights are unreachable by BSDF rays and emissive meshes are unreachable by NEE — so **MIS weights must stay off for both** until C1 lands;
- that the payload grew 32 → 48 bytes and what that cost in frame time;
- the limitation that indoors many env samples are occluded by walls, and that portal sampling is the technique that addresses it.

Update the ordering summary: remaining Phase B is **B4**; Phase C remaining is **C1**, **C2**.

- [ ] **Step 3: Wire the pipeline script**

Environment NEE needs no new GDScript knob — it activates whenever an environment exists. Add a short comment to `pipeline_references/image_glb_creation.gd` near the pathtracing setup recording that sky lighting is now importance-sampled, so a future reader does not add a redundant fill light to compensate for noise that no longer exists.

Parse-check it with the flags verified earlier in this project:

```bash
bin/godot.windows.editor.x86_64.exe --path pipeline_references --headless --quit --check-only --script res://image_glb_creation.gd
```

- [ ] **Step 4: Commit**

```bash
git add PATH_TRACER_QUALITY_ROADMAP.md pipeline_references/image_glb_creation.gd
git commit -m "docs(pt): record sky NEE + MIS results and close out C3/B1/B2"
```

---

## Self-Review

**1. Spec coverage.** §2 goals 1-4 map to Tasks 2+3 (sampling), Task 4 (MIS), Task 1 (payload), and the "analytic path untouched" constraint threaded through Task 4. §4's three decisions are implemented: 48-byte payload (Task 1), separate strategy rather than reservoir candidate (Task 4 Step 1), lat-long distribution built on GPU (Task 2). §6's math appears verbatim in Tasks 2-3. §7's two MIS-bypass cases are Task 1 Steps 6-7. §9's unit tests are Tasks 1-2, the constant-sky gate is Task 4 Step 4, variance reduction and the converged-mean guard are Task 5 Step 1, and the frame-time measurement §4 demands is Task 1 Step 8. §10's limitations are recorded in Task 5 Step 2.

**2. Placeholder scan.** No TBD/TODO steps; every code step carries literal code and every command is runnable. One step deliberately requires the implementer to *verify then report* rather than assume: Task 2 Step 5, which rebuild trigger exists for the radiance texture. That is stated as a check with a required report, not an unresolved gap — the codebase is the only authority on it and guessing in the plan would be worse.

**3. Type consistency.** `combinedPdf(float3, float3, float3, MaterialProperties) -> float` is declared in Task 1's Interfaces, defined in Task 1 Step 3, and called in Task 1 Step 5 and Task 4 Step 1 with that signature. `PathPayload.mis_ray_pdf`, `RT_MIS_PDF_NONE` and `RT_MIS_DELTA_ROUGHNESS` are defined in Task 1 Step 4 and consumed in Task 1 Steps 5-6 and Task 4 Step 2. `env_sample(vec2, out vec3, out float)`, `env_pdf(vec3)` and `env_pdf_from_uv(vec2)` are declared in Task 3's Interfaces and called with those signatures in Task 4. The SSBO offsets `ENV_PREFIX_RAW_OFFSET` / `ENV_ROWSUM_ADJ_OFFSET` / `ENV_MARGINAL_PREFIX_OFFSET` match the `PREFIX_RAW_OFFSET` / `ROWSUM_ADJ_OFFSET` / `MARGINAL_PREFIX_OFFSET` written by the compute shader in Task 2, and both match the "Distribution layout" table. `RT_PRNG_ENV = 7u` is defined in Task 1 and used in Task 4. `evalIndirectCombinedBRDF` is unchanged throughout, so its existing five call sites stay valid.

**One correction made during self-review, recorded because it was a real defect.** The first draft of Task 1 added a pdf out-parameter to `evalIndirectCombinedBRDF` and set `mis_ray_pdf = sampled_lobe_pdf × lobe_probability`. That is wrong: the sampler chooses a lobe stochastically, so the density of the direction it returns is the *mixture* over both lobes, and using only the selected term underestimates it — which shrinks the BSDF-side MIS weight and loses energy, the exact failure this phase exists to prevent. Replacing it with a `combinedPdf(N, L, V, material)` function fixes the math, removes the signature change and all five call-site edits, and supplies the "pdf for a direction I did not sample" that Task 4 needs anyway. Two things follow: `evalCombinedBRDF` already existing at `brdf_inc.glsl:1056` means Task 4 has no BRDF work left, and the highest-risk item in this plan is now the **consistency between `combinedPdf`'s lobe split and `shade_and_bounce`'s** — they are hand-maintained twins, and a divergence produces a biased image with no failing test.
