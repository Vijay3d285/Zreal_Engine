# GGX Multi-Scatter Energy Compensation (Gap #17) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the base specular lobe's fitted `1 + F0·Ems` multiple-scattering factor with Cycles' table-driven `1 + Fms·(1−E)/E`, so a white furnace returns 1.0 instead of 1.03–1.35.

**Architecture:** A new `evalMultiScatterEnergy()` in `brdf_inc.glsl` reads the `GGX_E_TABLE` / `GGX_EAVG_TABLE` already resident on the GPU for the coat, and a one-line dispatcher `evalMultiScatterFactor()` selects between it, the legacy approximation, and nothing, under a single `RT_MS_COMPENSATION` macro. Three call sites — the BSDF sampler and both NEE sites — switch together through that dispatcher.

**Tech Stack:** GLSL (Vulkan RD raytracing stages), C++ (doctest CPU mirror), GDScript (render gates), SCons.

**Spec:** `docs/superpowers/specs/2026-09-10-ggx-multiscatter-energy-design.md` (commit `4ea81486d3`).

## Global Constraints

- **The controller runs every build, render and gate. Implementers edit files only.** Subagents in this harness return as soon as they background a long build, and `SendMessage` is disabled, so an implementer that starts a build reports success it never observed.
- **`git add` takes explicit paths only.** Never `-A`, never `.`, never `git commit -a`.
- **Every `.gd` file directly under `pipeline_references/` is the user's own work.** Never stage, commit, revert, checkout over, or stash one. Files under `pipeline_references/tests/` are this workstream's gates and may be edited.
- **Build command:** `python -m SCons platform=windows target=editor tests=yes -j8`. Bare `scons` is not on PATH and exits 0 on failure under Bash.
- **A clean SCons exit proves nothing about GLSL.** `glsl_builders.py` runs no validation; only a gate run proves the shader compiled and behaves.
- **After any `.glsl` edit, run a full build** so `.glsl.gen.h` regenerates, then confirm the edit reached `servers/rendering/renderer_rd/shaders/raytracing/scene_raytracing_raygen.glsl.gen.h`. **Grep for code, not comments** — the generator strips comments.
- **All files touched by this plan are LF.** Verified: `brdf_inc.glsl`, `raytracing_emissive_inc.glsl`, `raytracing_closest_hit_common_inc.glsl`, `pt_anisotropy_gate.gd`, `test_pt_coat_albedo.cpp`. Preserve LF; do not let an editor convert to CRLF.
- **Renders and gate logs go to the scratchpad**, never into the repo.
- **Do not widen a tolerance to make a gate pass.** If a measured value lands outside its band, that is a finding to investigate and report, not a threshold to move.

## Refinement to the spec, stated so it is not a silent divergence

The spec writes the signature as `evalMultiScatterEnergy(float roughness, ...)`. This plan uses `evalMultiScatterEnergy(float alpha, ...)` and derives `rough = sqrt(alpha)` inside. Mathematically identical (`alpha = roughness²`), and it matches the existing `evalMultiScatterApproximation(alpha, NdV, F0)` signature exactly, so all three call sites become a one-word swap instead of an arithmetic edit at each. Fewer places to get wrong.

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `tests/servers/rendering/test_pt_ms_energy.cpp` | CPU mirror of the new factor + reference assertions | **Create** |
| `servers/rendering/renderer_rd/shaders/raytracing/brdf_inc.glsl` | table readers, the new function, the dispatcher, the sampler call site | Modify |
| `servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl` | env/analytic NEE call site + two stale comment references | Modify |
| `servers/rendering/renderer_rd/shaders/raytracing/raytracing_emissive_inc.glsl` | emissive NEE call site | Modify |
| `pipeline_references/tests/pt_anisotropy_gate.gd` | furnace baselines + promoting the absolute assertion | Modify |
| `pipeline_references/tests/pt_coat_gate.gd`, `pt_sheen_gate.gd`, `pt_energy_gate.gd` | regression baselines | Modify |
| `PATH_TRACER_QUALITY_ROADMAP.md` | Gap #17 closeout, new transmissive item | Modify |

---

### Task 1: CPU mirror and its reference values

Pure C++. No shader touched, so this task can be reviewed and merged on its own. It establishes the arithmetic the shader must reproduce.

**Files:**
- Create: `tests/servers/rendering/test_pt_ms_energy.cpp`

**Interfaces:**
- Consumes: `GGX_E_TABLE[1024]`, `GGX_EAVG_TABLE[32]` from `servers/rendering/renderer_rd/storage_rd/ggx_energy_tables.h`.
- Produces: the reference numbers Task 3's shader must match, and the mirror functions `ms_lut_read_1d`, `ms_lut_read_2d`, `ms_energy_factor` used by nothing else.

- [ ] **Step 1: Create the test file with the mirror and a failing expectation**

Create `tests/servers/rendering/test_pt_ms_energy.cpp`. Copy the 29-line Godot copyright header verbatim from `tests/servers/rendering/test_pt_coat_albedo.cpp` lines 1-29, then:

```cpp
#include "tests/test_macros.h"

TEST_FORCE_LINK(test_pt_ms_energy)

#include "core/math/math_funcs.h"
#include "servers/rendering/renderer_rd/storage_rd/ggx_energy_tables.h"

namespace TestPTMsEnergy {

// CPU mirror of evalMultiScatterEnergy / ggxE / ggxEavg in
// servers/rendering/renderer_rd/shaders/raytracing/brdf_inc.glsl, which mirror
// microfacet_ggx_preserve_energy
// (intern/cycles/kernel/closure/bsdf_microfacet.h:466-485).
//
// THIS FILE DOES NOT EXECUTE THE SHADER. The doctest binary never runs GLSL --
// every one of these assertions would still pass if the shader were reverted and
// this mirror left untouched. It guards the ARITHMETIC only. The evidence that
// the shader itself is right is pt_anisotropy_gate.gd's white furnace, and
// nothing here substitutes for it.
//
// THE INDEXING IS ENDPOINT-ALIGNED, NOT HALF-TEXEL-CENTERED, matching
// coatLutRead1D/2D. A hardware-filtered texture would be off by half a texel
// everywhere -- it would compile, render, and be silently wrong.

static float ms_lut_read_1d(const float *p_data, float p_x, int p_size) {
	p_x = CLAMP(p_x, 0.0f, 1.0f) * float(p_size - 1);
	const int index = MIN(int(p_x), p_size - 1);
	const int nindex = MIN(index + 1, p_size - 1);
	const float t = p_x - float(index);
	const float data0 = p_data[index];
	if (t == 0.0f) {
		return data0;
	}
	return (1.0f - t) * data0 + t * p_data[nindex];
}

static float ms_lut_read_2d(const float *p_data, float p_x, float p_y, int p_xsize, int p_ysize) {
	p_y = CLAMP(p_y, 0.0f, 1.0f) * float(p_ysize - 1);
	const int index = MIN(int(p_y), p_ysize - 1);
	const int nindex = MIN(index + 1, p_ysize - 1);
	const float t = p_y - float(index);
	const float data0 = ms_lut_read_1d(p_data + p_xsize * index, p_x, p_xsize);
	if (t == 0.0f) {
		return data0;
	}
	return (1.0f - t) * data0 + t * ms_lut_read_1d(p_data + p_xsize * nindex, p_x, p_xsize);
}

static const int MS_E_DIM = 32;

static float ms_ggx_e(float p_alpha, float p_cos_nv) {
	const float rough = Math::sqrt(p_alpha); // = sqrt(sqrt(ax*ay)); ax*ay == alpha^2.
	return ms_lut_read_2d(GGX_E_TABLE, rough, p_cos_nv, MS_E_DIM, MS_E_DIM);
}

static float ms_ggx_eavg(float p_alpha) {
	const float rough = Math::sqrt(p_alpha);
	return ms_lut_read_1d(GGX_EAVG_TABLE, rough, MS_E_DIM);
}

// Fss = mix(F0, F90, 1/21). See the spec's section 5.3 for why one constant
// covers both Cycles' F82 metallic branch and its generalized-Schlick
// dielectric branch.
static float ms_energy_factor(float p_alpha, float p_cos_nv, float p_f0, float p_f90) {
	const float e = ms_ggx_e(p_alpha, p_cos_nv);
	const float eavg = ms_ggx_eavg(p_alpha);
	const float missing = (1.0f - e) / e;
	const float fss = p_f0 + (p_f90 - p_f0) * (1.0f / 21.0f);
	const float fms = fss * eavg / (1.0f - fss * (1.0f - eavg));
	return 1.0f + fms * missing;
}

TEST_CASE("[PathTracer][MsEnergy] a white lobe is compensated to exactly unity") {
	// THE LOAD-BEARING CASE. For the furnace material (albedo 1, metallic 1)
	// F0 == F90 == 1, so Fss = mix(1, 1, 1/21) = 1 and
	// Fms = Eavg / (1 - (1 - Eavg)) = Eavg / Eavg = 1. The factor therefore
	// collapses to exactly 1/E, and a single-scattering lobe of directional
	// albedo E multiplied by 1/E returns exactly 1.
	//
	// This is why pt_anisotropy_gate.gd's white furnace must read 1.0 by
	// DERIVATION rather than by tuning. If this case ever fails, the furnace
	// cannot pass and no tolerance change will rescue it.
	const float alphas[] = { 0.0f, 0.04f, 0.16f, 0.5f, 0.81f, 1.0f };
	const float mus[] = { 0.05f, 0.3f, 0.5f, 0.7f, 1.0f };
	for (float alpha : alphas) {
		for (float mu : mus) {
			const float e = ms_ggx_e(alpha, mu);
			const float factor = ms_energy_factor(alpha, mu, 1.0f, 1.0f);
			CHECK(e * factor == doctest::Approx(1.0f).epsilon(1e-5));
		}
	}
}

TEST_CASE("[PathTracer][MsEnergy] E is read on the (rough, mu) axes, not transposed") {
	// A transposed read compiles, renders, and is wrong. These four anchors
	// pin the convention: E is 1 everywhere at zero roughness, and falls
	// monotonically as roughness rises at fixed mu.
	CHECK(ms_ggx_e(0.0f, 0.2f) == doctest::Approx(1.0f).epsilon(1e-6));
	CHECK(ms_ggx_e(0.0f, 1.0f) == doctest::Approx(1.0f).epsilon(1e-6));
	CHECK(ms_ggx_e(0.16f, 1.0f) > ms_ggx_e(0.81f, 1.0f));
	CHECK(ms_ggx_e(0.81f, 1.0f) > ms_ggx_e(1.0f, 1.0f));
}

TEST_CASE("[PathTracer][MsEnergy] reference values match the table by hand") {
	// Computed directly from GGX_E_TABLE / GGX_EAVG_TABLE with the same
	// endpoint-aligned reads. alpha = roughness^2, so alpha 0.16 is
	// roughness 0.4 and alpha 0.81 is roughness 0.9.
	CHECK(ms_ggx_e(0.16f, 0.7f) == doctest::Approx(0.950187f).epsilon(1e-5));
	CHECK(ms_ggx_eavg(0.16f) == doctest::Approx(0.940142f).epsilon(1e-5));
	CHECK(ms_energy_factor(0.16f, 0.7f, 0.04f, 1.0f) == doctest::Approx(1.004246f).epsilon(1e-5));
	CHECK(ms_energy_factor(0.16f, 0.7f, 1.0f, 1.0f) == doctest::Approx(1.052424f).epsilon(1e-5));

	CHECK(ms_ggx_e(0.81f, 0.5f) == doctest::Approx(0.535442f).epsilon(1e-5));
	CHECK(ms_ggx_eavg(0.81f) == doctest::Approx(0.502403f).epsilon(1e-5));
	CHECK(ms_energy_factor(0.81f, 0.5f, 0.04f, 1.0f) == doctest::Approx(1.039027f).epsilon(1e-5));
	CHECK(ms_energy_factor(0.81f, 0.5f, 1.0f, 1.0f) == doctest::Approx(1.867616f).epsilon(1e-5));
}

TEST_CASE("[PathTracer][MsEnergy] a mirror needs no compensation") {
	// At alpha 0 there is no multiple scattering to recover, so the factor is
	// exactly 1 for every F0. This is what keeps pt_energy_gate's roughness-0.02
	// `smooth` sphere essentially unmoved by this change.
	CHECK(ms_energy_factor(0.0f, 1.0f, 0.04f, 1.0f) == doctest::Approx(1.0f).epsilon(1e-6));
	CHECK(ms_energy_factor(0.0f, 0.3f, 1.0f, 1.0f) == doctest::Approx(1.0f).epsilon(1e-6));
}

TEST_CASE("[PathTracer][MsEnergy] the factor never darkens and rises with roughness") {
	// Energy compensation adds energy back; it can never remove any. A factor
	// below 1 would mean the table or the Fms algebra is inverted.
	const float mus[] = { 0.1f, 0.5f, 1.0f };
	for (float mu : mus) {
		CHECK(ms_energy_factor(0.16f, mu, 0.5f, 1.0f) >= 1.0f);
		CHECK(ms_energy_factor(0.81f, mu, 0.5f, 1.0f) >= ms_energy_factor(0.16f, mu, 0.5f, 1.0f));
	}
}

} // namespace TestPTMsEnergy
```

- [ ] **Step 2: Controller builds and runs the new tests, expecting them to pass**

The controller runs:

```bash
python -m SCons platform=windows target=editor tests=yes -j8
```

then:

```bash
./bin/godot.windows.editor.x86_64.console.exe --test --test-case="*MsEnergy*"
```

Expected: 5 test cases, all passing. This is a mirror of arithmetic already validated against the tables, so it should pass first time; a failure here means the table parse or the endpoint-aligned read is wrong and must be fixed before anything else.

- [ ] **Step 3: Verify the new file actually linked**

A new test file reaches the binary only if `tests/force_link.gen.h` regenerated from `tests/SCsub`'s glob. If it silently did not, the filtered run above reports zero cases and still exits 0.

```bash
grep -c "force_link_test_pt_ms_energy" tests/force_link.gen.h
```

Expected: `2` (declaration and call). If `0`, delete `tests/force_link.gen.h` and rebuild.

Then confirm the suite total rose:

```bash
./bin/godot.windows.editor.x86_64.console.exe --test 2>&1 | grep "test cases:"
```

Expected: `1555 | 1555 passed | 0 failed | 3 skipped` — 1550 before, plus this task's 5.

- [ ] **Step 4: Commit**

```bash
git add tests/servers/rendering/test_pt_ms_energy.cpp
git commit -m "test(pt): CPU mirror for Cycles GGX multi-scatter energy compensation"
```

---

### Task 2: Rename the table readers, no behaviour change

Pure rename. Its deliverable is proving that the coat and sheen paths are byte-identical afterwards, which is what makes Task 3's measurements attributable.

**Files:**
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/brdf_inc.glsl` (10 occurrences)
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl:1028`, `:1229` (comment text only)
- Modify: `servers/rendering/renderer_rd/forward_clustered/render_raytracing.cpp:174` (resource name)

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `ggxLutRead1D(int base, float x, int size)` and `ggxLutRead2D(int base, float x, float y, int xsize, int ysize)`, plus `float ggxE(float alpha, float NdotV)` and `float ggxEavg(float alpha)`, all in `brdf_inc.glsl`. Task 3 calls `ggxE` and `ggxEavg`.

- [ ] **Step 1: Rename the two readers**

In `brdf_inc.glsl`, rename `coatLutRead1D` → `ggxLutRead1D` and `coatLutRead2D` → `ggxLutRead2D` at all 10 occurrences: definitions at `:2006` and `:2018`; uses at `:2023`, `:2027`, `:2046`, `:2050`, `:2133`, `:2142`, `:2508`; and the comment text at `:2503`.

Add above `ggxLutRead1D`'s definition:

```glsl
// Renamed from coatLutRead1D/coatLutRead2D (Gap #17). These were never
// coat-specific -- they are generic endpoint-aligned reads into the shared LUT
// SSBO, and the base specular lobe's energy compensation now uses them too.
// coatLutRead3D keeps its name: it really does read only the coat albedo table.
```

- [ ] **Step 2: Add the two semantic readers**

Immediately after `coatGgxE` (which ends at `:2134`), add:

```glsl
// E(rough, mu) and E_avg(rough) for the BASE specular lobe.
//
// `rough` is sqrt(alpha), and that IS Cycles' sqrt(sqrt(ax*ay)): anisoAspect
// gives ax = alpha/aspect and ay = alpha*aspect, so ax*ay == alpha^2 exactly for
// every anisotropy, and sqrt(sqrt(alpha^2)) == sqrt(alpha). That cancellation is
// load-bearing -- two of the three call sites are NEE sites that have roughness
// but no ax/ay, and if the product did not cancel, compensating the sampler and
// the NEE sites on different roughnesses would make the two MIS strategies
// estimate different integrands (the B2 defect class).
float ggxE(float alpha, float NdotV) {
	return ggxLutRead2D(RT_COAT_SSBO_E_OFFSET, sqrt(alpha), NdotV, GGX_E_DIM, GGX_E_DIM);
}

float ggxEavg(float alpha) {
	return ggxLutRead1D(RT_COAT_SSBO_EAVG_OFFSET, sqrt(alpha), GGX_E_DIM);
}
```

- [ ] **Step 3: Update the two stale comment references and the resource name**

In `raytracing_closest_hit_common_inc.glsl`, replace `coatLutRead2D` with `ggxLutRead2D` in the comments at `:1028` and `:1229`.

In `render_raytracing.cpp:174`, change the resource name string from `"RT Coat+Sheen LUTs (Albedo+E+EAvg+SheenLTC)"` to `"RT GGX+Coat+Sheen LUTs (Albedo+E+EAvg+SheenLTC)"`.

- [ ] **Step 4: Controller builds and proves the rename changed nothing**

```bash
python -m SCons platform=windows target=editor tests=yes -j8
```

Then confirm the rename reached the generated shader and no call was missed:

```bash
grep -c "coatLutRead1D\|coatLutRead2D" servers/rendering/renderer_rd/shaders/raytracing/scene_raytracing_raygen.glsl.gen.h
grep -c "ggxLutRead1D\|ggxLutRead2D" servers/rendering/renderer_rd/shaders/raytracing/scene_raytracing_raygen.glsl.gen.h
```

Expected: `0` for the first, non-zero for the second.

- [ ] **Step 5: Controller runs the coat and sheen gates, which must be unchanged**

```bash
./bin/godot.windows.editor.x86_64.console.exe --path pipeline_references res://tests/pt_coat_gate_scene.tscn
./bin/godot.windows.editor.x86_64.console.exe --path pipeline_references res://tests/pt_sheen_gate_scene.tscn
```

Expected: both PASS with no reference updated. A rename that moved a number means a call site was missed or an argument order was swapped.

- [ ] **Step 6: Commit**

```bash
git add servers/rendering/renderer_rd/shaders/raytracing/brdf_inc.glsl servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl servers/rendering/renderer_rd/forward_clustered/render_raytracing.cpp
git commit -m "refactor(pt): rename coatLutRead1D/2D to ggxLutRead1D/2D, add ggxE/ggxEavg"
```

---

### Task 3: The new factor, the switch, and the three call sites

**Files:**
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/brdf_inc.glsl` (`:1215-1226` region, `:1331`, and after `ggxEavg`)
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl:1772`
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_emissive_inc.glsl:496`

**Interfaces:**
- Consumes: `ggxE(float alpha, float NdotV)` and `ggxEavg(float alpha)` from Task 2.
- Produces: `float3 evalMultiScatterFactor(float alpha, float NdotV, float3 F0)` — the single entry point all three call sites use. Task 4 flips `RT_MS_COMPENSATION` to drive it.

**Ordering constraint you must respect.** The SSBO `coat_albedo_table` is declared at `brdf_inc.glsl:1976` and the readers follow it, but the sampler call site is at `:1331`. So `evalMultiScatterFactor` must be **defined after the readers** and **forward-declared before `:1331`**. There are no forward declarations in this file today; Step 2 exists to prove the pattern compiles before anything depends on it.

- [ ] **Step 1: Add the macro and the forward declaration**

In `brdf_inc.glsl`, immediately after `evalMultiScatterApproximation`'s closing brace (`:1226`), insert:

```glsl
// A/B switch for roadmap Gap #17, kept permanently as measurement scaffolding
// rather than deleted after the phase -- the same standing precedent as
// COMBINE_BRDFS_WITH_FRESNEL (above), RT_LIGHT_SELECT_UNIFORM
// (raytracing_lights_inc.glsl) and RT_ENV_NEE_ENABLED (raytracing_inc.glsl).
//
//   1 = Cycles' table-driven 1 + Fms*(1-E)/E            (production)
//   0 = no compensation at all -- the raw single-scattering GGX lobe
//   2 = the legacy fitted 1 + F0*Ems (evalMultiScatterApproximation above)
//
// THREE states, not two, because a future residual needs "off" as well as
// "old" to be attributable, and because it gives the white-furnace gate three
// separated values it must reproduce. State 2 in particular must reproduce
// pt_anisotropy_gate.gd's committed BASELINE_INTACT_RATIO[2] = 1.059535, which
// is what proves the legacy path was preserved rather than merely believed to be.
//
// evalEmsApprox and evalMultiScatterApproximation above are deliberately NOT
// deleted; state 2 is what keeps them live.
#define RT_MS_COMPENSATION 1

// Forward declaration. The definition lives after the LUT readers, because it
// reads the coat_albedo_table SSBO which is not declared until much further
// down this file -- and this function is CALLED above that point, by
// sampleSpecularMicrofacet. This is the only forward declaration in this file;
// it is here rather than moving a 700-line block of E2d/E2e code.
float3 evalMultiScatterFactor(float alpha, float NdotV, float3 F0);
```

- [ ] **Step 2: Controller builds, purely to prove the forward-declaration pattern compiles**

At this point `evalMultiScatterFactor` is declared and never defined or called, which is legal GLSL.

```bash
python -m SCons platform=windows target=editor tests=yes -j8
./bin/godot.windows.editor.x86_64.console.exe --path pipeline_references res://tests/pt_coat_gate_scene.tscn
```

Expected: build succeeds and the coat gate still PASSes. A gate run is required because a clean SCons exit says nothing about GLSL — `glsl_builders.py` runs no validation, so the shader is only proven by execution. If the pipeline fails to compile, the gate will fail or render black; in that case, move the SSBO declaration and reader block above `:1300` instead and re-run this step.

- [ ] **Step 3: Define the new function and the dispatcher**

In `brdf_inc.glsl`, immediately after `ggxEavg` (added in Task 2), insert:

```glsl
// Cycles' real multiple-scattering energy compensation for the BASE specular
// lobe, replacing the fitted 1 + F0*Ems (Gap #17).
//
// Transcribed from microfacet_ggx_preserve_energy
// (intern/cycles/kernel/closure/bsdf_microfacet.h:466-485). Cycles scales the
// BSDF value by energy_scale = 1/E and the closure WEIGHT by
// darkening = (1 + Fms*missing)/energy_scale; an engine with no separate closure
// weight only ever sees the product, which is the 1 + Fms*missing below. That is
// the identical derivation E2d already made for the coat -- see coatEnergyScale.
//
// WHY ONE 1/21 COVERS BOTH METAL AND DIELECTRIC. Cycles uses two Fss models and
// this engine has one specular lobe with a metallic-lerped F0. They coincide:
// the metallic path is fresnel_f82_Fss(F0, B) = mix(F0, 1, 1/21) - B/126
// (bsdf_util.h:140-143), and at the default white specular tint
// fresnel_f82tint_B returns ...*(1 - tint) = 0, leaving mix(F0, 1, 1/21)
// EXACTLY; the dielectric path is generalized Schlick with
// s = 2/((exponent+3)*exponent + 2) = 1/21 at our Schlick exponent of 5
// (bsdf_microfacet.h:964-965). Cycles' dielectric branch actually takes an
// ior-derived s (:958-962) -- 0.0492 vs 0.0476 at ior 1.45, about 2% on Fss and
// ~0.1% of final radiance. Accepted and recorded so nobody later "discovers" it.
//
// shadowedF90(F0) stands where Cycles hardcodes f90 = 1. They agree: an F0
// derived from metalness is never below MIN_DIELECTRICS_F0, so shadowedF90
// returns 1 (see its own comment at :728-729). Using it keeps this consistent
// with the Fresnel the lobe actually evaluates if that ever changes.
//
// THE LOAD-BEARING PROPERTY: for a white lobe (F0 == F90 == 1) Fss = 1, so
// Fms = Eavg/(1 - (1 - Eavg)) = 1 and this collapses to exactly 1/E. A
// single-scattering lobe of directional albedo E times 1/E returns exactly 1 --
// which is why pt_anisotropy_gate.gd's white furnace must read 1.0 by
// derivation, not by tuning. A CPU mirror lives in
// tests/servers/rendering/test_pt_ms_energy.cpp; keep the two textually
// identical modulo type names, because the suite does NOT execute this shader.
float3 evalMultiScatterEnergy(float alpha, float NdotV, float3 F0) {
	float E = ggxE(alpha, NdotV);
	float Eavg = ggxEavg(alpha);
	float missing = (1.0f - E) / E;
	float3 Fss = mix(F0, float3(shadowedF90(F0)), 1.0f / 21.0f);
	float3 Fms = Fss * Eavg / (float3(1.0f, 1.0f, 1.0f) - Fss * (1.0f - Eavg));
	return float3(1.0f, 1.0f, 1.0f) + Fms * missing;
}

// The single entry point for all three base-specular call sites. They dispatch
// through this and only this, so the sampler and the two NEE sites cannot end up
// on different compensations -- that is the B2 defect class (two MIS strategies
// estimating different integrands), fixed on 2026-09-09 and not to be recreated.
// There is deliberately no per-site override.
float3 evalMultiScatterFactor(float alpha, float NdotV, float3 F0) {
#if RT_MS_COMPENSATION == 1
	return evalMultiScatterEnergy(alpha, NdotV, F0);
#elif RT_MS_COMPENSATION == 2
	return evalMultiScatterApproximation(alpha, NdotV, F0);
#else
	return float3(1.0f, 1.0f, 1.0f);
#endif
}
```

- [ ] **Step 4: Switch the sampler call site**

In `brdf_inc.glsl` at `:1331`, replace:

```glsl
	float3 ms = evalMultiScatterApproximation(alpha, NdotV, specularF0);
```

with:

```glsl
	float3 ms = evalMultiScatterFactor(alpha, NdotV, specularF0);
```

Leave the surrounding `#if MICROFACET_DISTRIBUTION == GGX` / `#else` / `#endif` exactly as it is.

- [ ] **Step 5: Switch the environment/analytic NEE call site**

In `raytracing_closest_hit_common_inc.glsl` at `:1772`, replace:

```glsl
					f_spec *= evalMultiScatterApproximation(ms_alpha, NdotV, specularF0);
```

with:

```glsl
					f_spec *= evalMultiScatterFactor(ms_alpha, NdotV, specularF0);
```

- [ ] **Step 6: Switch the emissive NEE call site**

In `raytracing_emissive_inc.glsl` at `:496`, replace:

```glsl
		f_spec *= evalMultiScatterApproximation(ms_alpha, NdotV, specular_f0);
```

with:

```glsl
		f_spec *= evalMultiScatterFactor(ms_alpha, NdotV, specular_f0);
```

- [ ] **Step 7: Annotate the deliberately-untouched transmissive site**

In `brdf_inc.glsl` at `:1484`, leave the call to `evalMultiScatterApproximation` as it is and add immediately above it:

```glsl
		// DELIBERATELY still the legacy approximation (Gap #17 scope decision).
		// This is the reflection branch of E1's transmissive closure, and Cycles
		// compensates glass from a DIFFERENT table set -- ggx_glass_E (16x16x16),
		// ggx_glass_Eavg (16x16), plus ggx_glass_inv_E / ggx_glass_inv_Eavg for
		// ior < 1 (bsdf_microfacet.h:450-457) -- which this project has never
		// transcribed. Pointing this at ggxE/ggxEavg would swap a MEASURED
		// divergence for an unmeasured one. Filed as its own roadmap item.
```

- [ ] **Step 8: Controller builds and proves the change reached the generated shader**

```bash
python -m SCons platform=windows target=editor tests=yes -j8
grep -c "evalMultiScatterFactor" servers/rendering/renderer_rd/shaders/raytracing/scene_raytracing_raygen.glsl.gen.h
```

Expected: build succeeds; the count is non-zero. Grep for the identifier, not the comment — the generator strips comments.

- [ ] **Step 9: Commit**

```bash
git add servers/rendering/renderer_rd/shaders/raytracing/brdf_inc.glsl servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl servers/rendering/renderer_rd/shaders/raytracing/raytracing_emissive_inc.glsl
git commit -m "fix(pt): Cycles table-driven multi-scatter compensation for the base specular lobe"
```

---

### Task 4: Measure, falsify, and re-baseline every affected gate

The controller performs every step here. This is the task that produces the evidence.

**Files:**
- Modify: `pipeline_references/tests/pt_anisotropy_gate.gd` (`BASELINE_INTACT_RATIO`, `BASELINE_INTACT_RATIO_NEE_DOM`, and promoting the absolute check)
- Modify: `pipeline_references/tests/pt_coat_gate.gd`, `pipeline_references/tests/pt_sheen_gate.gd`, `pipeline_references/tests/pt_energy_gate.gd` (references)

**Interfaces:**
- Consumes: `RT_MS_COMPENSATION` from Task 3.
- Produces: the measured before/after table Task 5 writes into the roadmap.

- [ ] **Step 1: Capture the three falsification states**

For each of `RT_MS_COMPENSATION` = `2`, `0`, `1`, set the macro in `brdf_inc.glsl`, run a full build, and run the anisotropy gate, saving each log to the scratchpad:

```bash
./bin/godot.windows.editor.x86_64.console.exe --path pipeline_references res://tests/pt_anisotropy_gate_scene.tscn
```

Record the isotropic (anisotropy 0.00) furnace ratio from each run.

Expected:

| `RT_MS_COMPENSATION` | isotropic furnace ratio |
|---|---|
| `2` (legacy) | **1.059535 ± 0.0002** — must reproduce the committed `BASELINE_INTACT_RATIO[2]` |
| `0` (none) | ≈ 0.966 — the known uncompensated single-scatter deficit |
| `1` (new) | ≈ 1.000 |

The `2` row is the strict one: it proves the legacy path survived Task 3 untouched. If it does not reproduce, Task 3 broke something and must be fixed before continuing. The band is that constant's own documented run-to-run spread of ~0.02pp.

- [ ] **Step 2: Leave the macro at 1 and record the full sweep**

With `RT_MS_COMPENSATION 1` built, record all 15 probe-1 ratios (5 anisotropies × 3 rotations) and probe 1b's ratio.

Acceptance, from the spec:
- every one of the 15 within `|ratio − 1.0| ≤ 0.02`
- probe 1b (roughness 0.9, anisotropy 0.9, previously 1.345900) also within 2% of 1.0

**If a value lands outside, do not widen `TOLERANCE`.** The pointwise arithmetic is proven exactly by Task 1 (`E × factor == 1` to 1e-5), so an integrated furnace miss means something else — an axis convention in the shader read, a call site not switched, or a second multiplier being applied somewhere the pointwise analysis did not cover. Report it and investigate.

> **Known open question, flagged so it is not mistaken for a surprise:** the legacy over-shoot does not decompose cleanly into the pointwise numbers. At alpha 0.16 / mu 0.7 / F0 1 the legacy factor is ≈1.080 against a correct 1.052, i.e. ≈2.6%, yet the measured integrated furnace ratio is 1.0595. The furnace averages over the whole visible disc, including grazing mu where the legacy factor *under*-shoots, so the two are not expected to match arithmetically — but nobody has reconciled them. Treat a post-fix ratio near 1.0 as success and a ratio far from it as a finding, and do not tune either way.

- [ ] **Step 3: Re-capture the anisotropy gate baselines**

In `pipeline_references/tests/pt_anisotropy_gate.gd`, replace:

```gdscript
const BASELINE_INTACT_RATIO := [1.0777727, 1.0809253, 1.059535, 1.0776337, 1.034110] # parallel to ANISOTROPY_VALUES
```

with the five ratios measured at `RT_MS_COMPENSATION 1` (use the rotation-0.0 value for each anisotropy, matching how the originals were taken), and replace `BASELINE_INTACT_RATIO_NEE_DOM := 1.345900` with probe 1b's new value.

Update `BASELINE_INTACT_RATIO`'s doc comment: state that the previous values carried the Gap #17 over-compensation, that they were re-captured on 2026-09-10 after it was removed, and keep the old numbers in the comment as the before-state.

- [ ] **Step 4: Promote probe 1's absolute check from diagnostic to asserted**

This is the primary deliverable of the testing work. In `_probe_furnace`, replace the diagnostic-only block:

```gdscript
			if absf(ratio - 1.0) > TOLERANCE:
				print(("  [diagnostic] %-34s ratio %.6f vs 1.0 exceeds %.1f%% -- known pre-existing " +
						"multi-scatter over-compensation (see BASELINE_INTACT_RATIO doc), not asserted")
						% [tag, ratio, TOLERANCE * 100.0])
```

with:

```gdscript
			# ASSERTED as of 2026-09-10 (Gap #17). This check existed and was
			# correct all along, but was demoted to diagnostic-only in fix round 2
			# because evalMultiScatterApproximation's over-compensation made every
			# entry in this sweep fail it on a CORRECT build -- which made the
			# gate structurally unable to fail. That defect is gone, so the check
			# is live again.
			#
			# A white furnace must return exactly the sky radiance for any
			# energy-conserving BRDF. With the Cycles compensation the lobe's
			# directional albedo E is multiplied by exactly 1/E for this material
			# (albedo 1, metallic 1 => Fss = 1 => Fms = 1), so 1.0 is a
			# DERIVATION, not a target. Do not widen TOLERANCE to make this pass.
			if absf(ratio - 1.0) > TOLERANCE:
				_failures.append(("probe1 furnace [%s]: ratio %.6f vs 1.0 exceeds %.1f%% -- a white " +
						"furnace must return the sky radiance exactly. See evalMultiScatterEnergy " +
						"in brdf_inc.glsl and RT_MS_COMPENSATION's three-state falsification.")
						% [tag, ratio, TOLERANCE * 100.0])
```

Also update the two header `print` lines in `_probe_furnace` so they no longer describe the absolute check as diagnostic-only:

```gdscript
	print("  [gate] absolute vs 1.0, tolerance %.1f%% -- ASSERTED since Gap #17 (2026-09-10)"
			% (TOLERANCE * 100.0))
	print("  [gate] vs measured-intact baseline, band +/-%.1fpp" % (BASELINE_BAND * 100.0))
```

Apply the same promotion to `_probe_furnace_nee_dominant`'s equivalent diagnostic block.

- [ ] **Step 5: Re-run the anisotropy gate and confirm it is green**

```bash
./bin/godot.windows.editor.x86_64.console.exe --path pipeline_references res://tests/pt_anisotropy_gate_scene.tscn
```

Expected: PASS, with both the absolute and the regression-band checks now live.

- [ ] **Step 6: Re-baseline the coat, sheen and energy gates**

Run each, record the new values, and update its reference constants:

```bash
./bin/godot.windows.editor.x86_64.console.exe --path pipeline_references res://tests/pt_coat_gate_scene.tscn
./bin/godot.windows.editor.x86_64.console.exe --path pipeline_references res://tests/pt_sheen_gate_scene.tscn
./bin/godot.windows.editor.x86_64.console.exe --path pipeline_references res://tests/pt_energy_gate_scene.tscn
```

Expected to move, and to be re-baselined with a comment naming Gap #17 and this date:
- `pt_coat_gate` and `pt_sheen_gate` — the base specular lobe sits under both layers.
- `pt_energy_gate`'s `rough` (roughness 0.6, metallic 1) and `bumpy` spheres, and their rim figures.

Expected to move only slightly: `pt_energy_gate`'s `smooth` sphere. At roughness 0.02, `E ≈ 1`, so the factor is ≈ 1 — Task 1's "a mirror needs no compensation" case is the same statement.

**Must NOT move — if either does, stop and investigate rather than re-baselining:**
- `pt_energy_gate`'s `diffuse` Lambertian plane. It sets `metallic_specular = 0`, so it has no specular lobe to compensate.
- `pt_energy_gate` Gate 1's absolute `rho * L_env = 0.50000`.

- [ ] **Step 7: Run the full suite**

```bash
./bin/godot.windows.editor.x86_64.console.exe --test 2>&1 | grep -E "test cases:|assertions:|Status:"
```

Expected: `1555 | 1555 passed | 0 failed | 3 skipped`.

- [ ] **Step 8: Commit**

```bash
git add pipeline_references/tests/pt_anisotropy_gate.gd pipeline_references/tests/pt_coat_gate.gd pipeline_references/tests/pt_sheen_gate.gd pipeline_references/tests/pt_energy_gate.gd
git commit -m "test(pt): re-baseline gates for Gap #17 and assert probe 1's absolute furnace check"
```

---

### Task 5: Documentation

**Files:**
- Modify: `PATH_TRACER_QUALITY_ROADMAP.md`

**Interfaces:**
- Consumes: Task 4's measured numbers.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Close the Gap #17 row in §2**

Rewrite the Gap #17 row to say it is fixed on 2026-09-10, with the before/after furnace table from Task 4, naming `evalMultiScatterEnergy` and `RT_MS_COMPENSATION`, and pointing at §7.8 for the original characterisation.

- [ ] **Step 2: Annotate §7.8's characterisation**

Mark the Gap #17 passage as resolved. Keep every original measurement as the before-state — do not delete them.

- [ ] **Step 3: Correct the pedestal-adjusted figures in §7.8, §7.10 and §7.11**

Add a note at each "raw vs pedestal-adjusted" pair: the pedestal is removed as of 2026-09-10, so the adjusted figure is what the engine now produces — **and state plainly that the raw comparison against Blender has not been re-taken.** The `.blend` scenes and scripts behind those comparisons were never checked into this repo; only `.superpowers/sdd/2026-08-21-environment-energy-fidelity/cycles-hypothesis-report.md` survives. Do not present the adjusted numbers as if they were freshly measured.

Also note that §7.11.2's unexplained −2.06% dielectric-base residual may have moved, and that no claim is made about it without a re-measurement.

- [ ] **Step 4: File the transmissive-lobe item**

Add a new open item for compensating E1's transmissive lobe: it needs `ggx_glass_E` (16×16×16), `ggx_glass_Eavg` (16×16) and the `ggx_glass_inv_*` variants transcribed from Cycles, an extended SSBO layout, and its own transmissive furnace study. Anchor it at `brdf_inc.glsl:1484` and `bsdf_microfacet.h:450-457`.

- [ ] **Step 5: Fix the stale ordering line in §6**

`Ordering summary: **A1 → A2/A3/A4 → D → E → F (Phases B, C and D are complete).**` contradicts §4, which marks Phase A implemented pending GPU verification. Correct it.

- [ ] **Step 6: Commit**

```bash
git add PATH_TRACER_QUALITY_ROADMAP.md
git commit -m "docs(pt): close Gap #17 and file the transmissive-lobe energy tables"
```

---

## Self-review notes

**Spec coverage.** §1 problem → Task 4 measures it. §2/§3 → Task 3 implements. §4 scope → Task 3 Steps 4-7, with the out-of-scope site annotated in Step 7. §5.1 function → Task 3 Step 3. §5.2 `rough == roughness` → Task 2 Step 2 comment and Task 1's `ms_ggx_e`. §5.3 the `1/21` derivation → Task 3 Step 3 comment. §5.4 readers → Task 2. §5.5 switch → Task 3 Step 1. §6.1 analytic guarantee → Task 1's first test case. §6.2 acceptance → Task 4 Steps 2-5. §6.3 falsification → Task 4 Step 1. §6.4 CPU mirror → Task 1. §6.5 regression controls → Task 4 Step 6. §6.6 build → Global Constraints. §7 what this does not fix → Task 5 Step 3. §8 docs → Task 5.

**Two deviations from the spec, stated so neither is silent.**

1. The function takes `alpha` rather than `roughness`, deriving `rough = sqrt(alpha)` internally. Mathematically identical, and it makes all three call sites a one-word swap.
2. The spec's §5.4 says "`coatGgxE` / `coatGgxEavg` become thin wrappers." **`coatGgxEavg` does not exist** — the coat reads `E_avg` inline inside `coatFms`. This plan therefore leaves the coat's helpers textually untouched beyond the rename, which is stronger anyway: it is what makes Task 2 Step 5's "the coat and sheen gates must not move" a real check on the rename rather than a check on a simultaneous refactor. The spec has been corrected to match.

**One thing this plan cannot promise.** Task 1 proves the arithmetic to 1e-5 and Task 4 measures the render, but nothing here executes the GLSL under test outside a rendered gate. If probe 1 lands near but not on 1.0, the CPU mirror will still pass — the mirror and the shader are separate texts. That asymmetry is inherent to this project (roadmap §6) and is the reason Task 4's acceptance is a render, not a unit test.
