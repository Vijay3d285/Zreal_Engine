# Anisotropic GGX (E2b) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the path tracer's specular lobe elliptical, driven by the `anisotropy` and `anisotropy_rotation` values Phase D already delivers to the GPU but nothing reads.

**Architecture:** Add anisotropic `D`, Smith `Λ`/`G2` and a matching VNDF pdf alongside the existing isotropic ones. Shading already happens in a local frame with `N = (0,0,1)`, but that frame's X axis is arbitrary, so anisotropy is expressed as a single azimuth angle `anisoPhi` stored on `BrdfData`; every consumer rotates about Z by `±anisoPhi` and uses the same stored value, which is what keeps the sampler and the pdf from desyncing.

**Tech Stack:** Godot 4.7-beta fork, SCons/MSVC, GLSL (Vulkan RD raytracing pipeline), doctest, GDScript GPU gates, Blender 4.5/Cycles for the reference image.

## Global Constraints

- **Never stage, commit, revert, check out over, or stash these six files.** They are the user's own uncommitted work: `pipeline_references/compositor_effect.gd`, `pipeline_references/image_glb_creation.gd`, `pipeline_references/render.gd`, `pipeline_references/structure.gd`, `pipeline_references/video_glb_creation.gd`, `pipeline_references/custom_shape.gd`. Use explicit paths with `git add`; never `git add -A` or `git add .`.
- New files under `pipeline_references/tests/` and `tests/servers/rendering/` ARE in scope.
- `scons` is not on PATH. Prepend `C:\Users\aiadmin\AppData\Roaming\Python\Python310\Scripts`. Always pass `platform=windows`.
- **After touching any `.glsl`, run a full scons build** so `.glsl.gen.h` regenerates. Never hand-edit a `.gen.h`.
- **`anisotropy` stays SIGNED.** Feed the raw value into `aspect = sqrt(1 - anisotropy * 0.9)`. Do NOT saturate it. (Spec §3.2.)
- **`anisotropy_rotation` is RADIANS. Do NOT multiply by 2π.** Cycles stores turns and multiplies; Godot does not. (Spec §3.3.)
- At `anisotropy == 0` the output must be **bit-identical** to the current build. `aspect` is exactly `1.0` there.
- Debug vis modes 0-34 are allocated. **35 is the next free.** A new GLSL vis mode REQUIRES a matching `RTDebugMode` enumerator in `scene/resources/environment.h` before `RT_DEBUG_MAX`, plus its inspector hint entry in `environment.cpp` — E2a found mode 34 had been added to GLSL only, leaving `RT_DEBUG_MAX` aliasing a live mode.
- Verify every claim about Cycles or this codebase by **reading the file at implementation time**. Line numbers in this plan may have shifted.
- Doctest baseline before this plan: **1513 passed, 0 failed, 3 skipped.**

---

## File Structure

**Create:**
- `tests/servers/rendering/test_pt_anisotropy.cpp` — CPU mirrors of the mapping, `D`, and `Λ`, plus the isotropic-reduction identity. Mirrors must stay textually identical to the GLSL modulo type names.
- `pipeline_references/tests/pt_anisotropy_gate.gd` + `pt_anisotropy_gate_scene.tscn` — the furnace sweep and the pdf-parity probe.

**Modify:**
- `servers/rendering/renderer_rd/shaders/raytracing/brdf_inc.glsl` — the math, `MaterialProperties`/`BrdfData` fields, `prepareBRDFData`, sampler and pdf call sites.
- `servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl` — populate the new `MaterialProperties` fields from `MaterialData`; vis mode 35.
- `servers/rendering/renderer_rd/forward_clustered/render_raytracing.cpp` — clamp `anisotropy` to `[-1, 1]` on upload.
- `scene/resources/environment.h` / `environment.cpp` — vis mode 35 enumerator and hint.
- `PATH_TRACER_QUALITY_ROADMAP.md` — closeout.

---

## Task 1: The mapping and the reduction identity, in C++ first

Proving the math on the CPU before touching the shader. A wrong `D` normalization here would otherwise only surface as "the render looks a bit off".

**Files:**
- Create: `tests/servers/rendering/test_pt_anisotropy.cpp`

**Interfaces:**
- Consumes: nothing.
- Produces: CPU reference functions `aniso_aspect(float)`, `aniso_alphas(float roughness, float anisotropy, float *r_ax, float *r_ay)`, `ggx_d_aniso(const Vector3 &H, float ax, float ay)`, `smith_lambda_aniso(const Vector3 &V, float ax, float ay)`. Task 2 mirrors these into GLSL textually.

- [ ] **Step 1: Read the existing isotropic functions you must reduce to**

```bash
sed -n '944,947p;868,872p;805,816p' servers/rendering/renderer_rd/shaders/raytracing/brdf_inc.glsl
```

You need `GGX_D`, `Smith_G2_Height_Correlated`, `Smith_G_a` and `Smith_G_Lambda_GGX`. Task 2 requires the anisotropic forms to reduce to these exactly, so read them now and record their exact bodies in your report.

- [ ] **Step 2: Read a sibling test file for the house style**

```bash
sed -n '1,60p' tests/servers/rendering/test_pt_transmission.cpp
```

Copy its licence header verbatim, its `TEST_FORCE_LINK` line pattern, and its namespace convention. Note the comment block explaining that CPU mirrors must stay textually identical to the GLSL — yours needs the same.

- [ ] **Step 3: Write the failing test**

Create `tests/servers/rendering/test_pt_anisotropy.cpp` with the licence header copied from `test_pt_transmission.cpp`, then:

```cpp
#include "tests/test_macros.h"

TEST_FORCE_LINK(test_pt_anisotropy)

#include "core/math/math_funcs.h"

namespace TestPTAnisotropy {

// CPU mirrors of the anisotropy math in
// servers/rendering/renderer_rd/shaders/raytracing/brdf_inc.glsl.
// The aspect/ax/ay mapping is shared verbatim with Blender Cycles
// (intern/cycles/kernel/svm/closure.h:311-313) AND with this engine's own
// Forward+ raster (shaders/scene_forward_lights_inc.glsl:272-274).
// These must stay textually identical to the GLSL modulo type names -- a
// drift makes this suite pass while the shader is wrong.

static float sqr(float x) {
	return x * x;
}

// SIGNED anisotropy on purpose. Cycles saturatefs to [0,1] and carries the
// other orientation in its rotation; Godot's raster does not, and the two are
// NOT equivalent (see the eccentricity test below). glTF has no sign, so every
// imported material lands in a >= 0 where they agree exactly.
static float aniso_aspect(float p_anisotropy) {
	return Math::sqrt(1.0f - p_anisotropy * 0.9f);
}

static void aniso_alphas(float p_roughness, float p_anisotropy, float *r_ax, float *r_ay) {
	const float alpha = p_roughness * p_roughness;
	const float aspect = aniso_aspect(p_anisotropy);
	*r_ax = alpha / aspect;
	*r_ay = alpha * aspect;
}

// Anisotropic GGX NDF. H is in the anisotropy-aligned tangent frame, z along N.
static float ggx_d_aniso(const Vector3 &p_h, float p_ax, float p_ay) {
	const float d = sqr(p_h.x / p_ax) + sqr(p_h.y / p_ay) + sqr(p_h.z);
	return 1.0f / (Math::PI * p_ax * p_ay * sqr(d));
}

// Anisotropic Smith lambda, height-correlated partner of ggx_d_aniso.
static float smith_lambda_aniso(const Vector3 &p_v, float p_ax, float p_ay) {
	const float num = sqr(p_ax * p_v.x) + sqr(p_ay * p_v.y);
	return (-1.0f + Math::sqrt(1.0f + num / sqr(p_v.z))) * 0.5f;
}

// The shipped ISOTROPIC forms, copied from brdf_inc.glsl so the reduction is
// checked against the real thing rather than against a restatement.
static float ggx_d_iso(float p_alpha_squared, float p_ndoth) {
	const float b = ((p_alpha_squared - 1.0f) * p_ndoth * p_ndoth + 1.0f);
	return p_alpha_squared / (Math::PI * b * b);
}

TEST_CASE("[PathTracer][Anisotropy] aspect is exactly 1 at anisotropy 0") {
	// This exactness is the whole no-pixel-change guarantee. sqrt(1.0) must be
	// bit-exact, not approximately 1.
	CHECK(aniso_aspect(0.0f) == 1.0f);

	float ax = 0.0f, ay = 0.0f;
	aniso_alphas(0.35f, 0.0f, &ax, &ay);
	CHECK(ax == ay);
	CHECK(ax == doctest::Approx(0.35f * 0.35f).epsilon(1e-9));
}

TEST_CASE("[PathTracer][Anisotropy] anisotropic D reduces to the shipped isotropic D") {
	// At ax == ay the algebra collapses:
	//   1/(PI*a^2*((Hx^2+Hy^2)/a^2 + Hz^2)^2) == a^2/(PI*((a^2-1)*NdotH^2+1)^2)
	// using Hz = NdotH and Hx^2+Hy^2 = 1-NdotH^2. Asserted numerically across
	// roughness and angle rather than trusted.
	const float roughnesses[] = { 0.05f, 0.2f, 0.5f, 0.9f };
	const float ndoths[] = { 0.15f, 0.5f, 0.8f, 1.0f };

	for (float r : roughnesses) {
		float ax = 0.0f, ay = 0.0f;
		aniso_alphas(r, 0.0f, &ax, &ay);
		const float alpha = r * r;
		const float alpha_sq = alpha * alpha;

		for (float ndoth : ndoths) {
			// Build an H with this NdotH, split arbitrarily between x and y so
			// both anisotropic axes are exercised.
			const float s = Math::sqrt(MAX(0.0f, 1.0f - ndoth * ndoth));
			const Vector3 h(s * 0.6f, s * 0.8f, ndoth);

			CHECK(ggx_d_aniso(h, ax, ay) == doctest::Approx(ggx_d_iso(alpha_sq, ndoth)).epsilon(1e-5));
		}
	}
}

TEST_CASE("[PathTracer][Anisotropy] SIGNED convention, with the Cycles alternative pinned") {
	// The design decision, made falsifiable. Godot feeds the signed value
	// straight in; Cycles saturates and adds 90 degrees of rotation. Those give
	// DIFFERENT eccentricities, so this test pins BOTH numbers -- asserting only
	// the one we chose could not distinguish the conventions.
	float ax = 0.0f, ay = 0.0f;
	aniso_alphas(1.0f, -0.5f, &ax, &ay); // roughness 1 so alpha == 1
	const float ours = ay / ax;

	float cax = 0.0f, cay = 0.0f;
	aniso_alphas(1.0f, 0.5f, &cax, &cay); // Cycles: |a|, orientation via rotation
	const float cycles = cax / cay;

	CHECK(ours == doctest::Approx(1.450f).epsilon(1e-3));
	CHECK(cycles == doctest::Approx(1.818f).epsilon(1e-3));
	// They must NOT coincide -- if they ever do, the two conventions have been
	// conflated somewhere and this test has stopped discriminating.
	CHECK(Math::abs(ours - cycles) > 0.3f);
}

TEST_CASE("[PathTracer][Anisotropy] positive and negative anisotropy swap the stretched axis") {
	float px = 0.0f, py = 0.0f, nx = 0.0f, ny = 0.0f;
	aniso_alphas(0.4f, 0.6f, &px, &py);
	aniso_alphas(0.4f, -0.6f, &nx, &ny);

	CHECK(px > py); // positive: x is the stretched axis
	CHECK(nx < ny); // negative: y is
}

} // namespace TestPTAnisotropy
```

- [ ] **Step 4: Build with tests and run only this suite**

```bash
scons platform=windows target=editor tests=yes -j8
```

Then:

```bash
bin/godot.windows.editor.x86_64.console.exe --headless --test --test-case="*Anisotropy*"
```

Expected: all cases PASS. A bare positional after `--test` is silently ignored — `--test-case=` is required.

If the reduction test FAILS, the anisotropic `D` in Step 3 is wrong; fix the formula, not the test.

- [ ] **Step 5: Confirm the whole suite still passes**

```bash
bin/godot.windows.editor.x86_64.console.exe --headless --test
```

Expected: `1517 passed | 0 failed | 3 skipped` (1513 + the 4 new cases).

- [ ] **Step 6: Commit**

```bash
git add tests/servers/rendering/test_pt_anisotropy.cpp
git commit -m "test(pt): E2b CPU mirrors - aniso mapping and isotropic reduction"
```

---

## Task 2: The GLSL math and the anisotropy frame

**Files:**
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/brdf_inc.glsl`

**Interfaces:**
- Consumes: the formulas proven in Task 1. Transcribe them so the GLSL and the C++ stay textually identical modulo type names.
- Produces: `float anisoAspect(float anisotropy)`; `float3 rotateAboutZ(float3 v, float phi)`; `float GGX_D_Aniso(float3 H, float ax, float ay)`; `float Smith_Lambda_Aniso(float3 V, float ax, float ay)`; `float Smith_G2_Aniso(float3 V, float3 L, float ax, float ay)`; new `MaterialProperties` fields `anisotropy`, `anisotropyRotation`, `tangent`; new `BrdfData` fields `ax`, `ay`, `anisoPhi`.

**Why an azimuth angle rather than a new frame.** Shading already runs in a local frame built by `getRotationToZAxis(N)` (`brdf_inc.glsl:548`, used at `:1241`, `:1544` and inside `evalIndirectCombinedBRDF`). That frame sends `N` to `+Z` but its X axis is arbitrary. Rebuilding it three ways would be the surest route to a sampler/pdf desync. Instead `prepareBRDFData` computes ONE angle, `anisoPhi`, and every consumer rotates about Z by `±anisoPhi`.

- [ ] **Step 1: Read the structs and the frame builder you are extending**

```bash
grep -n "struct MaterialProperties" -A 30 servers/rendering/renderer_rd/shaders/raytracing/brdf_inc.glsl
grep -n "struct BrdfData" -A 30 servers/rendering/renderer_rd/shaders/raytracing/brdf_inc.glsl
sed -n '544,560p' servers/rendering/renderer_rd/shaders/raytracing/brdf_inc.glsl
```

Record the exact field order of both structs in your report — you are appending, not reordering.

- [ ] **Step 2: Add the helper functions**

Place these immediately after the existing `GGX_D` (find it with `grep -n "float GGX_D" brdf_inc.glsl`):

```glsl
// -------------------------------------------------------------------------
//    Anisotropic GGX (roadmap E2b)
//
// The aspect/ax/ay mapping below is shared VERBATIM with two independent
// sources, verified by reading both:
//   Blender Cycles      intern/cycles/kernel/svm/closure.h:311-313
//   this engine's raster shaders/scene_forward_lights_inc.glsl:272-274
// Adopting it therefore buys Cycles parity AND raster/RT parity from one
// formula. Unlike E1's Fresnel split, no divergence is purchased here.
// -------------------------------------------------------------------------

// SIGNED anisotropy, matching Godot's raster. Cycles saturatefs to [0,1] and
// carries the other orientation in its rotation, which is NOT equivalent: at
// anisotropy = -0.5 this gives an axis ratio of 1.450, Cycles' |a| = 0.5 plus
// 90 degrees gives 1.818. Different eccentricity, not a different orientation.
// Nothing is lost -- KHR_materials_anisotropy has no sign, so every glTF or
// Blender-imported material lands in a >= 0 where the two agree exactly.
float anisoAspect(float anisotropy) {
	// Exactly 1.0 at anisotropy 0, which is what makes ax == ay == alpha and
	// keeps untouched materials bit-identical to pre-E2b.
	return sqrt(1.0f - anisotropy * 0.9f);
}

float3 rotateAboutZ(float3 v, float phi) {
	float s = sin(phi);
	float c = cos(phi);
	return float3(c * v.x - s * v.y, s * v.x + c * v.y, v.z);
}

// Anisotropic GGX NDF. H must already be in the anisotropy-aligned frame
// (z along N, x along the rotated tangent).
float GGX_D_Aniso(float3 H, float ax, float ay) {
	float d = sqr(H.x / ax) + sqr(H.y / ay) + sqr(H.z);
	return 1.0f / (PI * ax * ay * sqr(d));
}

// Anisotropic Smith lambda, the height-correlated partner of GGX_D_Aniso.
float Smith_Lambda_Aniso(float3 V, float ax, float ay) {
	float num = sqr(ax * V.x) + sqr(ay * V.y);
	return (-1.0f + sqrt(1.0f + num / sqr(V.z))) * 0.5f;
}

float Smith_G2_Aniso(float3 V, float3 L, float ax, float ay) {
	return 1.0f / (1.0f + Smith_Lambda_Aniso(V, ax, ay) + Smith_Lambda_Aniso(L, ax, ay));
}
```

If `sqr` is not already defined in this file, use `grep -n "float sqr(" brdf_inc.glsl` to confirm — E1 added it. If it is missing, add it rather than inlining multiplications, so the GLSL stays textually identical to Task 1's C++.

- [ ] **Step 3: Extend `MaterialProperties`**

Append these three fields to the END of the struct (do not reorder existing ones):

```glsl
	// E2b anisotropy. `anisotropy` is SIGNED [-1,1] (see anisoAspect).
	// `anisotropyRotation` is RADIANS, NOT turns -- Godot's property hint is
	// "0,6.2831853,0.001,radians_as_degrees" (scene/resources/material.cpp:3811)
	// and render_raytracing.cpp uploads it unmodified. Cycles stores turns and
	// multiplies by 2*PI (closure.h:316); doing that here would be a 6.28x error.
	float anisotropy;
	float anisotropyRotation;
	// World-space surface tangent. Zero-length means "no usable tangent", which
	// forces the isotropic fallback -- Cycles gates the same way on
	// stack_valid(data.tangent_offset) (closure.h:309).
	float3 tangent;
```

- [ ] **Step 4: Extend `BrdfData`**

Append to the END of the struct:

```glsl
	// E2b. ax/ay are the elliptical roughnesses; anisoPhi is the azimuth, in the
	// local (N -> +Z) frame, of the axis ax runs along. Consumers rotate about Z
	// by -anisoPhi before evaluating and by +anisoPhi after sampling. Storing ONE
	// angle here, computed once in prepareBRDFData, is what stops the sampler and
	// the pdf deriving the frame differently -- that desync is mean-preserving
	// and no rendered image can catch it (spec section 4.4).
	float ax;
	float ay;
	float anisoPhi;
```

- [ ] **Step 5: Compute them in `prepareBRDFData`**

Find the alpha block (`grep -n "data.alphaSquared = data.alpha" brdf_inc.glsl`) and insert immediately after it:

```glsl
	// E2b: elliptical roughness and the anisotropy azimuth.
	//
	// Defaults are the exact isotropic values, so a material with anisotropy 0
	// or no usable tangent is bit-identical to pre-E2b: anisoAspect(0) is
	// exactly 1.0, so ax == ay == alpha.
	data.ax = data.alpha;
	data.ay = data.alpha;
	data.anisoPhi = 0.0f;

	float tangentLen = length(material.tangent);
	if (material.anisotropy != 0.0f && tangentLen > 1e-6f) {
		float aspect = anisoAspect(material.anisotropy);
		data.ax = data.alpha / aspect;
		data.ay = data.alpha * aspect;

		// Project the tangent into the local frame and take its azimuth there.
		// getRotationToZAxis(N) sends N to +Z but leaves X arbitrary, so the
		// azimuth must be measured, not assumed.
		float4 qToZ = getRotationToZAxis(N);
		float3 Tlocal = rotatePoint(qToZ, material.tangent / tangentLen);
		data.anisoPhi = atan(Tlocal.y, Tlocal.x) + material.anisotropyRotation;
	}
```

Note: GLSL's two-argument `atan(y, x)` is the `atan2` equivalent. Confirm the argument order by reading another call in this file before relying on it.

- [ ] **Step 6: Full build**

```bash
scons platform=windows target=editor tests=yes -j8
```

Expected: exit 0. A GLSL error appears here as a shader-header generation failure.

- [ ] **Step 7: Confirm nothing regressed yet**

Nothing consumes `ax`/`ay` yet, so behaviour must be unchanged:

```bash
bin/godot.windows.editor.x86_64.console.exe --headless --test
bin/godot.windows.editor.x86_64.console.exe --path pipeline_references res://tests/pt_energy_gate_scene.tscn
```

Expected: `1517 passed | 0 failed | 3 skipped`, and `PASS - all energy gates green.`

- [ ] **Step 8: Commit**

```bash
git add servers/rendering/renderer_rd/shaders/raytracing/brdf_inc.glsl
git commit -m "feat(pt): E2b anisotropic D, Smith lambda, and the anisotropy frame"
```

---

## Task 3: Wire the sampler and the pdf together

Both in ONE task on purpose. They must agree exactly; splitting them would let a reviewer approve half of a desync.

**Files:**
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/brdf_inc.glsl`
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl`
- Modify: `servers/rendering/renderer_rd/forward_clustered/render_raytracing.cpp`

**Interfaces:**
- Consumes: `data.ax`, `data.ay`, `data.anisoPhi`, `rotateAboutZ`, `GGX_D_Aniso`, `Smith_G2_Aniso` from Task 2.
- Produces: an anisotropic specular sample and a matching pdf. `MaterialProperties.anisotropy/anisotropyRotation/tangent` populated at every construction site.

- [ ] **Step 1: Enumerate every site by grep — do not trust a list**

```bash
grep -n "sampleSpecularHalfVector\|sampleGGXVNDF\|specularPdf\|sampleGGXVNDFReflectionPdf\|sampleSpecular(" servers/rendering/renderer_rd/shaders/raytracing/brdf_inc.glsl
grep -n "MaterialProperties " servers/rendering/renderer_rd/shaders/raytracing/*.glsl
```

Record every hit in your report. Any site you miss is a silent desync.

- [ ] **Step 2: Rotate into the anisotropy frame at the sampling sites**

Wherever a specular half-vector is sampled, rotate `V` in, sample, and rotate `H` back. The existing call passes `float2(data.alpha, data.alpha)`; replace that pattern with:

```glsl
	float3 Vaniso = rotateAboutZ(Vlocal, -data.anisoPhi);
	float3 Haniso = sampleSpecularHalfVector(Vaniso, float2(data.ax, data.ay), u);
	float3 Hspecular = rotateAboutZ(Haniso, data.anisoPhi);
```

At `anisotropy == 0`, `anisoPhi` is 0 so both rotations are identity and `ax == ay == alpha` — the call reduces exactly to today's.

- [ ] **Step 3: Make the pdf use the same frame and the same ax/ay**

The existing `sampleGGXVNDFReflectionPdf(alpha, alphaSquared, NdotH, NdotV, LdotH)` is scalar. Add its anisotropic partner next to it:

```glsl
// Anisotropic partner of sampleGGXVNDFReflectionPdf. MUST stay in lockstep with
// the sampler: V, L and H are rotated by -anisoPhi by the CALLER, so this
// function sees them already in the anisotropy frame.
//
// A pdf that disagrees with the sampler is the B2 defect class -- two
// strategies estimating different integrands, which MIS cannot repair and
// which is MEAN-PRESERVING, so no rendered image at any sample count reveals
// it. Vis mode 35 exists to catch exactly this.
float sampleGGXVNDFReflectionPdfAniso(float3 Vaniso, float3 Haniso, float ax, float ay, float VdotH) {
	float G1 = 1.0f / (1.0f + Smith_Lambda_Aniso(Vaniso, ax, ay));
	float D = GGX_D_Aniso(Haniso, ax, ay);
	return D * G1 * max(0.0f, VdotH) / max(0.00001f, Vaniso.z) / (4.0f * max(0.00001f, VdotH));
}
```

Then route every specular-pdf call site found in Step 1 through it, rotating its inputs by `-data.anisoPhi` first.

- [ ] **Step 4: Use the anisotropic D and G2 in the BRDF evaluation**

Find the evaluation (`grep -n "Microfacet_D(max(0.00001f, data.alphaSquared)" brdf_inc.glsl`). Replace the isotropic `D`/`G2` pair with the anisotropic ones, rotating `V`, `L` and `H` into the anisotropy frame first. Guard `ax` and `ay` independently with `max(0.00001f, ...)` — at `roughness = 0` both go to zero and `D` is singular.

- [ ] **Step 5: Populate the new MaterialProperties fields**

In `raytracing_closest_hit_common_inc.glsl`, at every site that fills a `MaterialProperties` (from Step 1's grep), set:

```glsl
	mat.anisotropy = material.anisotropy;
	mat.anisotropyRotation = material.anisotropy_rotation; // already RADIANS
	mat.tangent = h.tangent;
```

`h.tangent` is world-space and already available (`raytracing_closest_hit_common_inc.glsl:19`). Confirm the `MaterialData` field names by reading `raytracing_data_inc.glsl:153-158`.

- [ ] **Step 6: Clamp anisotropy on upload**

In `render_raytracing.cpp`, find where `mat.anisotropy` is assigned (`grep -n "mat.anisotropy = " render_raytracing.cpp`) and clamp:

```cpp
		mat.anisotropy = CLAMP((float)anisotropy_var, -1.0f, 1.0f);
```

Rationale to put in a comment: `aspect = sqrt(1 - a*0.9)` has a negative radicand above `a = 1.111`, giving NaN. This mirrors where E1 clamped `attenuation_color`.

- [ ] **Step 7: Full build**

```bash
scons platform=windows target=editor tests=yes -j8
```

- [ ] **Step 8: Prove the isotropic path is untouched**

```bash
bin/godot.windows.editor.x86_64.console.exe --headless --test
bin/godot.windows.editor.x86_64.console.exe --path pipeline_references res://tests/pt_energy_gate_scene.tscn
bin/godot.windows.editor.x86_64.console.exe --path pipeline_references res://tests/pt_transmission_gate_scene.tscn
bin/godot.windows.editor.x86_64.console.exe --path pipeline_references res://tests/pt_sky_energy_gate_scene.tscn
```

Expected: doctest `1517 passed | 0 failed`; `pt_energy_gate` PASS; `pt_transmission_gate` PASS. `pt_sky_energy_gate` is EXPECTED to exit non-zero (it reports a known aliasing overshoot) — what matters is that its probe A reads `1.00000` and probe B @2048 reads about `0.98`, unchanged from before this task. Report those numbers.

None of these scenes use anisotropy, so **any change in these numbers means the isotropic path was disturbed** — investigate rather than proceed.

- [ ] **Step 9: Commit**

```bash
git add servers/rendering/renderer_rd/shaders/raytracing/brdf_inc.glsl servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl servers/rendering/renderer_rd/forward_clustered/render_raytracing.cpp
git commit -m "feat(pt): E2b wire anisotropic sampling, pdf and evaluation"
```

---

## Task 4: Vis mode 35 and the GPU gate

**Files:**
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl`
- Modify: `scene/resources/environment.h`, `scene/resources/environment.cpp`
- Create: `pipeline_references/tests/pt_anisotropy_gate.gd`, `pipeline_references/tests/pt_anisotropy_gate_scene.tscn`

**Interfaces:**
- Consumes: everything from Tasks 2 and 3.
- Produces: debug vis mode `35`, reporting the sampler's own density in R and the pdf function's value in G, raw and unscaled. A gate selects it with `env.set_pathtracing_debug_mode(35)`.

- [ ] **Step 1: Add the vis mode, in GLSL *and* C++ together**

In `raytracing_closest_hit_common_inc.glsl`, after the `vis_mode == 34` branch:

```glsl
	} else if (vis_mode == 35) {
		// E2b pdf/sampler parity. R = the density the SAMPLER actually realises,
		// G = what sampleGGXVNDFReflectionPdfAniso reports for the same
		// direction. They must agree.
		//
		// This calls the SAME functions the integrator calls, not re-inlined
		// copies -- a second copy here would validate the probe's own arithmetic
		// rather than the shipped code. Same reason vis mode 32 exists (E1).
		// Raw and unscaled, matching mode 23's convention.
		ps.radiance = vec3(dbg_sampler_pdf, dbg_reported_pdf, 0.0);
```

You must construct `dbg_sampler_pdf` and `dbg_reported_pdf` above this from the shipped functions. Read how vis mode 32 does the equivalent for transmission (`grep -n "vis_mode == 32" -A 30`) and follow that structure.

Then, in the SAME commit, add to `scene/resources/environment.h` immediately before `RT_DEBUG_MAX`:

```cpp
		RT_DEBUG_ANISO_PDF_PARITY,
```

and append `,Aniso PDF Parity` to the `PROPERTY_HINT_ENUM` string in `environment.cpp` (find it with `grep -n "IBL Exposure Normalization" scene/resources/environment.cpp`), plus the matching `BIND_ENUM_CONSTANT`. Walk both lists in lockstep and confirm every entry lines up 1:1 — an off-by-one silently mislabels every mode after it.

- [ ] **Step 2: Full build**

```bash
scons platform=windows target=editor tests=yes -j8
```

- [ ] **Step 3: Write the gate**

Create `pipeline_references/tests/pt_anisotropy_gate_scene.tscn`:

```
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://tests/pt_anisotropy_gate.gd" id="1_anisogate"]

[node name="PTAnisotropyGate" type="Node"]
script = ExtResource("1_anisogate")
```

Create `pipeline_references/tests/pt_anisotropy_gate.gd` modelled on `pipeline_references/tests/pt_sky_energy_gate.gd` — READ THAT FILE FIRST and reuse its `_build_scene`/`_measure_crop`/`_render_accum` patterns. Two probes:

**Probe 1 — white furnace sweep.** Uniform-radiance sky, a metallic sphere with `albedo_color = Color(1,1,1).linear_to_srgb()`, `metallic = 1.0`, `roughness = 0.4`. An energy-conserving BRDF returns the sky's radiance regardless of `ax`/`ay`. Sweep `anisotropy` over `[-0.9, -0.5, 0.0, 0.5, 0.9]` and `anisotropy_rotation` over `[0.0, PI/4, PI/2]`, asserting each within 2%.

**LOAD-BEARING, do not omit:** `albedo_color` must be `.linear_to_srgb()`-pre-encoded. `render_raytracing.cpp:1540-1542` runs it through `srgb_to_linear()` on upload, so a raw `Color(1,1,1)` is fine but any other value is not — and `Color(1,1,1)` round-trips to 1.0 either way, so use the explicit pre-encode anyway to keep the pattern correct if the value is ever changed. This trap produced a phantom 53% energy loss in E2a.

**Probe 2 — pdf parity.** `env.set_pathtracing_debug_mode(35)`, render, and assert `abs(R - G) < 1e-4` per pixel across the sphere, at several anisotropy values. Clear the mode afterwards with `set_pathtracing_debug_mode(0)`.

- [ ] **Step 4: Run the gate**

```bash
bin/godot.windows.editor.x86_64.console.exe --path pipeline_references res://tests/pt_anisotropy_gate_scene.tscn
```

Run in the FOREGROUND, redirect to a log file and read the file; do not pipe through PowerShell `Select-Object`. Allow 600000 ms.

**A failure here is a real finding — report it, do not tune the gate to pass.** If the furnace reads consistently high or low, the `D` or `Λ` normalization is wrong. If probe 2 disagrees, the sampler and pdf have desynced. Both are exactly what these probes exist to detect.

- [ ] **Step 5: Confirm nothing else moved**

```bash
bin/godot.windows.editor.x86_64.console.exe --headless --test
bin/godot.windows.editor.x86_64.console.exe --path pipeline_references res://tests/pt_energy_gate_scene.tscn
```

Expected: `1517 passed | 0 failed | 3 skipped`, and `PASS - all energy gates green.`

- [ ] **Step 6: Commit**

```bash
git add servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl scene/resources/environment.h scene/resources/environment.cpp pipeline_references/tests/pt_anisotropy_gate.gd pipeline_references/tests/pt_anisotropy_gate_scene.tscn
git commit -m "test(pt): E2b vis mode 35 pdf parity and the anisotropy furnace gate"
```

---

## Task 5: Cycles reference and closeout

**Files:**
- Modify: `PATH_TRACER_QUALITY_ROADMAP.md`

**Interfaces:**
- Consumes: the working feature from Tasks 2-4.
- Produces: the closeout record. Nothing downstream.

- [ ] **Step 1: Build the Cycles reference**

Blender is at `C:\Program Files\Blender Foundation\Blender 4.5\blender.exe`, run headless as `blender.exe -b -P <script.py>`. Put all scratch in the scratchpad directory, NOT the repo. A working harness from E2a is reproduced in `.superpowers/sdd/2026-08-21-environment-energy-fidelity/cycles-hypothesis-report.md` — read it for the Blender API patterns and the colorspace handling.

Scene: one metallic sphere, `roughness = 0.4`, `anisotropic = 0.6`, `anisotropic_rotation = 0.0`, under a uniform-radiance world, matched to a Godot scene with the same values.

**Use `anisotropic > 0`.** That is the range where the two conventions agree by construction (spec §3.2); a negative value cannot be expressed in Cycles at the same eccentricity and would make the comparison meaningless.

**HARD REQUIREMENT — the E2a lesson.** Blender's Principled `Base Color` is LINEAR; Godot's `albedo_color` is sRGB and is decoded by `srgb_to_linear()` at `render_raytracing.cpp:1540-1542`. Copying the authored number field-for-field into both is what produced E1's phantom 23% dimming (roadmap §7.7). Set the Blender value to the LINEAR decode of the Godot value, and state in your report which number you put where.

Also required: a **positive control**. Render a second Blender arm with the un-decoded value and confirm the ratio between the two arms matches `srgb_to_linear(v)/v` for your chosen `v`. Without it, an agreeing comparison proves nothing.

- [ ] **Step 2: Compare and report**

Report per-channel means for both renderers, their ratio, and whether the highlight is stretched along the expected axis. Acceptance is within 5% mean (spec §8.6).

Also render `anisotropy_rotation = PI/2` in both and confirm the highlight rotates the same way in each.

- [ ] **Step 3: Write the closeout**

Add `### 7.8 E2b - anisotropic GGX` to `PATH_TRACER_QUALITY_ROADMAP.md` after §7.7. Record: the furnace sweep numbers, the pdf-parity result, the Cycles comparison with its positive control, and the fact that the isotropic path is bit-identical. State plainly that the `ax`/`ay` mapping is shared verbatim with both Cycles and this engine's own raster, so parity was free here.

Mark E2's anisotropy line in the phase table as complete, and record what remains: clearcoat, sheen, the N-way rewrite, and anisotropy on the transmissive lobe (spec §9).

- [ ] **Step 4: Commit**

```bash
git add PATH_TRACER_QUALITY_ROADMAP.md
git commit -m "docs(pt): E2b closeout - anisotropic GGX measured against Cycles"
```

---

## Self-review notes

**Spec coverage.** §3.1 mapping → Tasks 1, 2. §3.2 signed → Task 1 Step 3's pinned-counterfactual test, Task 2 Step 2. §3.3 radians → Task 2 Step 3's comment, Task 3 Step 5. §3.4/§4.5 → Tasks 2, 3. §4.1 frame → Task 2 Step 5. §4.2/§4.3 → Task 2 Step 2. §4.4 pdf → Task 3 Steps 3-4, Task 4 probe 2. §4.6 reduction → Task 1 Step 3. §5 degenerates → Task 2 Step 5 (tangent), Task 3 Step 6 (clamp), Task 3 Step 4 (roughness 0). §7.1 → Task 1. §7.2 → Task 4 probe 1. §7.3 → Task 4 probe 2. §7.4 → Task 5. §8 acceptance → Task 3 Step 8, Task 4 Steps 4-5, Task 5 Step 2.

**Type consistency.** `ax`/`ay`/`anisoPhi` on `BrdfData`; `anisotropy`/`anisotropyRotation`/`tangent` on `MaterialProperties`; `anisoAspect`, `rotateAboutZ`, `GGX_D_Aniso`, `Smith_Lambda_Aniso`, `Smith_G2_Aniso`, `sampleGGXVNDFReflectionPdfAniso` — used identically in Tasks 2, 3 and 4.

**Known risk the plan cannot remove.** Task 3 Step 1 asks the implementer to enumerate call sites by grep rather than following a list, because a list written here could be stale. If a specular-pdf site is missed, the gate in Task 4 probe 2 is the net.
