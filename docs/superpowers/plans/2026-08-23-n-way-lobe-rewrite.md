# N-Way Lobe Rewrite (E2c) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the hardcoded two-way `DIFFUSE_TYPE`/`SPECULAR_TYPE` lobe selection with an N-way registry that renders identically to today, so clearcoat (E2d) and sheen (E2e) can be added without touching selection logic again.

**Architecture:** A fixed-size lobe array sized by a named constant, currently 2. Selection is a CDF walk that at N=2 reduces to today's single comparison; combination is `Σ pᵢ·pdfᵢ` in registry order, which at N=2 must produce the same float operations in the same order as the expression it replaces. The two duplicated lobe-probability functions collapse into one.

**Tech Stack:** Godot 4.7-beta fork, SCons/MSVC, GLSL (Vulkan RD raytracing pipeline), doctest, GDScript GPU gates.

## Global Constraints

- **Never stage, commit, revert, check out over, or stash these six files.** They are the user's own uncommitted work: `pipeline_references/compositor_effect.gd`, `pipeline_references/image_glb_creation.gd`, `pipeline_references/render.gd`, `pipeline_references/structure.gd`, `pipeline_references/video_glb_creation.gd`, `pipeline_references/custom_shape.gd`. Use explicit paths with `git add`; never `git add -A` or `git add .`.
- `scons` is not on PATH. Prepend `C:\Users\aiadmin\AppData\Roaming\Python\Python310\Scripts`. Always pass `platform=windows`.
- **After touching any `.glsl`, run a full scons build** so `.glsl.gen.h` regenerates. Never hand-edit a `.gen.h`.
- **This phase ships NO feature.** Any rendered difference is a bug, not an improvement. If a gate number moves, investigate — never rationalise it.
- **SPECULAR IS LOBE INDEX 0.** Registry order is contract. A diffuse-first registry inverts every pixel's lobe choice while leaving the image statistically identical and every gate green.
- **One `rng_1d(rng, RT_PRNG_LOBE)` call, consumed once.** No second draw, no remap, no rescale into a sub-interval.
- **Summation order is preserved**: specular term first, then diffuse, matching `pSpec * specularContribution * transmitScale + (1.0f - pSpec) * pdfDiffuse`.
- `transmitScale` belongs to the **specular lobe's pdf**, not to the combination. It multiplies only the specular term today and must continue to.
- Verify every claim about this codebase by **reading the file at implementation time**. Line numbers here may have shifted.
- Doctest baseline: **1521 passed, 0 failed, 3 skipped.**

---

## File Structure

**Create:**
- `tests/servers/rendering/test_pt_lobe_registry.cpp` — CPU mirrors asserting the N-way reduction collapses to the two-term form, that specular is index 0, and that the CDF comparison has the same orientation as today's.

**Modify:**
- `servers/rendering/renderer_rd/shaders/raytracing/brdf_inc.glsl` — the registry, the unified lobe-probability function, `combinedPdf`'s combination.
- `servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl` — the sampler-side selection; the `RT_DEBUG_PDF_PARITY` vis mode, whose two-value comparison becomes degenerate once the functions unify.
- `PATH_TRACER_QUALITY_ROADMAP.md` — closeout.

---

## Task 1: The reduction identity, in C++ first

**Files:**
- Create: `tests/servers/rendering/test_pt_lobe_registry.cpp`

**Interfaces:**
- Consumes: nothing.
- Produces: `lobe_weight(float spec_lum, float diffuse_lum)`, `select_lobe(float u, const float *weights, int n)`, `combine_pdf(const float *weights, const float *pdfs, int n)`. Task 2 mirrors these into GLSL textually.

- [ ] **Step 1: Read the three sites you are mirroring**

```bash
sed -n '1738,1751p' servers/rendering/renderer_rd/shaders/raytracing/brdf_inc.glsl
sed -n '1321,1342p' servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl
grep -n "return pSpec \* specularContribution" servers/rendering/renderer_rd/shaders/raytracing/brdf_inc.glsl
```

Record all three exact bodies in your report — Tasks 2 and 3 must reproduce them.

- [ ] **Step 2: Write the test**

Create the file with the licence header copied verbatim from `tests/servers/rendering/test_pt_transmission.cpp`, then:

```cpp
#include "tests/test_macros.h"

TEST_FORCE_LINK(test_pt_lobe_registry)

#include "core/math/math_funcs.h"

namespace TestPTLobeRegistry {

// CPU mirrors of the N-way lobe selection in
// servers/rendering/renderer_rd/shaders/raytracing/brdf_inc.glsl.
// Must stay textually identical to the GLSL modulo type names.
//
// This phase is a pure refactor: at N == 2 every function here must reduce to
// the two-way code it replaces, EXACTLY. These tests pin the two properties a
// rendered image cannot see -- lobe ORDER and CDF ORIENTATION -- because
// getting either wrong produces a statistically identical picture that is
// bitwise unrecognisable, and every GPU gate would still pass.

#define LOBE_SPECULAR 0
#define LOBE_DIFFUSE 1
#define LOBE_COUNT 2

// The single lobe-probability function replacing combinedPdfLobeProbability
// and samplerLobeProbability. Copied from brdf_inc.glsl's shared body.
static float lobe_weight(float p_specular_lum, float p_diffuse_lum) {
	if (p_diffuse_lum < 0.0001f) {
		return 1.0f;
	} else if (p_specular_lum < 0.0001f) {
		return 0.0f;
	}
	return CLAMP(p_specular_lum / (p_specular_lum + p_diffuse_lum), 0.01f, 0.99f);
}

// CDF walk. At N == 2 this must pick LOBE_SPECULAR on exactly the inputs for
// which today's `u < brdfProbability` picks SPECULAR_TYPE.
static int select_lobe(float p_u, const float *p_weights, int p_n) {
	float acc = 0.0f;
	for (int i = 0; i < p_n - 1; i++) {
		acc += p_weights[i];
		if (p_u < acc) {
			return i;
		}
	}
	return p_n - 1;
}

// Sum in registry order: specular term first, then diffuse.
static float combine_pdf(const float *p_weights, const float *p_pdfs, int p_n) {
	float acc = 0.0f;
	for (int i = 0; i < p_n; i++) {
		acc += p_weights[i] * p_pdfs[i];
	}
	return acc;
}

TEST_CASE("[PathTracer][LobeRegistry] specular is index 0") {
	// Not cosmetic. A diffuse-first registry makes `u < cdf[0]` select DIFFUSE
	// exactly where today's `u < brdfProbability` selects SPECULAR, inverting
	// every pixel's lobe choice. The image stays statistically identical, so no
	// gate can see it. This is the phase's likeliest silent failure.
	CHECK(LOBE_SPECULAR == 0);
	CHECK(LOBE_DIFFUSE == 1);
	CHECK(LOBE_COUNT == 2);
}

TEST_CASE("[PathTracer][LobeRegistry] CDF orientation matches the two-way comparison") {
	// Today: `if (rng < brdfProbability) SPECULAR else DIFFUSE`.
	// The CDF must agree at every u, including both boundaries.
	const float p_spec = 0.37f;
	const float weights[LOBE_COUNT] = { p_spec, 1.0f - p_spec };

	const float us[] = { 0.0f, 0.1f, 0.36999f, 0.37001f, 0.5f, 0.9f, 0.999f };
	for (float u : us) {
		const int expected = (u < p_spec) ? LOBE_SPECULAR : LOBE_DIFFUSE;
		CHECK(select_lobe(u, weights, LOBE_COUNT) == expected);
	}
}

TEST_CASE("[PathTracer][LobeRegistry] the inverted registry is measurably different") {
	// Guards the guard: if select_lobe ever became order-insensitive, the test
	// above would pass on a broken implementation. Pin that a diffuse-first
	// ordering genuinely disagrees, so the property being tested is real.
	const float p_spec = 0.37f;
	const float correct[LOBE_COUNT] = { p_spec, 1.0f - p_spec };
	const float inverted[LOBE_COUNT] = { 1.0f - p_spec, p_spec };

	int disagreements = 0;
	for (int i = 0; i < 100; i++) {
		const float u = (float(i) + 0.5f) / 100.0f;
		if (select_lobe(u, correct, LOBE_COUNT) != select_lobe(u, inverted, LOBE_COUNT)) {
			disagreements++;
		}
	}
	CHECK(disagreements > 20);
}

TEST_CASE("[PathTracer][LobeRegistry] combine_pdf reduces to the two-term form") {
	// Today: pSpec * specularContribution * transmitScale + (1 - pSpec) * pdfDiffuse
	// transmitScale belongs to the SPECULAR lobe's pdf, not to the combination,
	// so it is folded into pdfs[LOBE_SPECULAR] by the caller.
	const float p_spec = 0.42f;
	const float spec_contribution = 3.75f;
	const float transmit_scale = 0.61f;
	const float pdf_diffuse = 0.28f;

	const float weights[LOBE_COUNT] = { p_spec, 1.0f - p_spec };
	const float pdfs[LOBE_COUNT] = { spec_contribution * transmit_scale, pdf_diffuse };

	const float expected = p_spec * spec_contribution * transmit_scale + (1.0f - p_spec) * pdf_diffuse;
	CHECK(combine_pdf(weights, pdfs, LOBE_COUNT) == doctest::Approx(expected).epsilon(1e-9));
}

TEST_CASE("[PathTracer][LobeRegistry] lobe_weight preserves the degenerate branches") {
	// The early returns are behaviour, not optimisation: they are what makes a
	// pure-metal or pure-diffuse surface pick one lobe with certainty.
	CHECK(lobe_weight(0.5f, 0.00001f) == 1.0f);
	CHECK(lobe_weight(0.00001f, 0.5f) == 0.0f);
	// And the clamp bounds hold in between.
	CHECK(lobe_weight(1000.0f, 0.001f) == doctest::Approx(0.99f).epsilon(1e-6));
	CHECK(lobe_weight(0.001f, 1000.0f) == doctest::Approx(0.01f).epsilon(1e-6));
}

} // namespace TestPTLobeRegistry
```

- [ ] **Step 3: Build and run**

```bash
scons platform=windows target=editor tests=yes -j8
```

Foreground, 600000 ms timeout, redirect to a log file and read it. Do NOT background it — a backgrounded build here detaches from its wrapper and reports completion early. Do NOT pipe through PowerShell's `Select-Object`.

```bash
bin/godot.windows.editor.x86_64.console.exe --headless --test --test-case="*LobeRegistry*"
bin/godot.windows.editor.x86_64.console.exe --headless --test
```

Expected: 5 new cases pass; full suite 1526 passed, 0 failed, 3 skipped. Report ACTUAL numbers. If a CHECK fails, fix the mirror, never the assertion.

- [ ] **Step 4: Commit**

```bash
git add tests/servers/rendering/test_pt_lobe_registry.cpp
git commit -m "test(pt): E2c CPU mirrors - lobe registry reduction identity"
```

---

## Task 2: The registry in GLSL, added alongside

Nothing calls it yet, so behaviour cannot change. That is the point: it isolates the transcription from the switchover.

**Files:**
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/brdf_inc.glsl`

**Interfaces:**
- Consumes: Task 1's CPU mirrors — the GLSL must stay textually identical to them modulo type names.
- Produces: `LOBE_SPECULAR 0`, `LOBE_DIFFUSE 1`, `LOBE_COUNT 2`; `float lobeWeight(MaterialProperties material)`; `int selectLobe(float u, float weights[LOBE_COUNT])`; `float combineLobePdf(float weights[LOBE_COUNT], float pdfs[LOBE_COUNT])`.

- [ ] **Step 1: Add the constants and the three functions**

Place them immediately before `combinedPdfLobeProbability`. Transcribe Task 1's bodies verbatim, with GLSL types.

`lobeWeight` takes `MaterialProperties` and computes `specularF0`/`diffuseReflectance` exactly as both existing functions do — read `combinedPdfLobeProbability` and copy its first four lines rather than paraphrasing.

Its doc comment must record why the duplication is being retired:

```glsl
// THE single lobe-selection probability. Replaces combinedPdfLobeProbability
// and samplerLobeProbability, which were deliberately duplicated so that a
// divergence between the sampler's value and combinedPdf's stayed
// representable -- see the comment those functions carried, and the historical
// defect it cites (pSpec 0.0476 against the sampler's 0.0909).
//
// That duplication is retired for the reason it was created. The detector it
// existed to enable compared the two values side by side, which is a
// comparison of two evaluations of ONE formula -- E2b's final review
// established that exact construction is a tautology that cannot fail, and
// replaced it with a self-normalizing instrument that draws from the real
// sampler and checks E[1/pdf] against the domain's measure. That instrument
// catches a pdf wrong by a factor k as a reading of 1/k whether or not a
// second copy of this formula exists.
//
// So unifying now makes the desync structurally IMPOSSIBLE and still
// DETECTABLE. Do not restore the duplication on the strength of the old
// comment.
```

- [ ] **Step 2: Full build**

```bash
scons platform=windows target=editor tests=yes -j8
```

- [ ] **Step 3: Prove nothing changed**

Nothing calls the new functions yet, so every number must be untouched:

```bash
bin/godot.windows.editor.x86_64.console.exe --headless --test
bin/godot.windows.editor.x86_64.console.exe --path pipeline_references res://tests/pt_energy_gate_scene.tscn
bin/godot.windows.editor.x86_64.console.exe --path pipeline_references res://tests/pt_anisotropy_gate_scene.tscn
```

GPU gates need a real Vulkan device — no `--headless` on those two. Expected: doctest 1526/0/3; `pt_energy_gate` "PASS - all energy gates green."; `pt_anisotropy_gate` "PASS - anisotropic GGX gate green." Report actual numbers.

- [ ] **Step 4: Commit**

```bash
git add servers/rendering/renderer_rd/shaders/raytracing/brdf_inc.glsl
git commit -m "feat(pt): E2c lobe registry and unified lobe probability"
```

---

## Task 3: Switch both consumers together

The sampler and `combinedPdf` move in ONE task on purpose. Splitting them would let a reviewer approve half of a desync, and this phase's whole claim is that the two still agree.

**Files:**
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/brdf_inc.glsl`
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl`

**Interfaces:**
- Consumes: `LOBE_SPECULAR`, `LOBE_DIFFUSE`, `LOBE_COUNT`, `lobeWeight`, `selectLobe`, `combineLobePdf` from Task 2.
- Produces: `combinedPdfLobeProbability` and `samplerLobeProbability` deleted; both call sites routed through the registry.

- [ ] **Step 1: Switch the sampler**

In `raytracing_closest_hit_common_inc.glsl`, the `else` branch of the `brdfType` decision. Today:

```glsl
		float brdfProbability = samplerLobeProbability(brdf_mat);
		if (rng_1d(rng, RT_PRNG_LOBE) < brdfProbability) {
			brdfType = SPECULAR_TYPE;
			ps.throughput /= brdfProbability;
		} else {
			brdfType = DIFFUSE_TYPE;
			ps.throughput /= (1.0 - brdfProbability);
		}
```

Route it through `selectLobe`, keeping **exactly one** `rng_1d(rng, RT_PRNG_LOBE)` call, consumed once, and keeping the throughput division by the chosen lobe's own weight. Preserve the two degenerate early branches above it (`diffuseLum < 0.0001` and `specularLum < 0.0001`) unchanged — they are behaviour.

- [ ] **Step 2: Switch `combinedPdf`'s combination**

Replace:

```glsl
	return pSpec * specularContribution * transmitScale + (1.0f - pSpec) * pdfDiffuse;
```

with a `combineLobePdf` call, folding `transmitScale` into the specular lobe's pdf entry so the multiplication happens in the same place it does now. The weights array is `{ pSpec, 1.0f - pSpec }` in that order.

The `VplusL` degenerate guard and the `RT_MIS_DELTA_ROUGHNESS` near-delta guard above must survive **verbatim**. They are behaviour, not selection logic.

- [ ] **Step 3: Delete the two old functions and fix the vis mode**

Delete `combinedPdfLobeProbability` and `samplerLobeProbability`.

`RT_DEBUG_PDF_PARITY` in `raytracing_closest_hit_common_inc.glsl` calls both and reports their ratio. With one function that ratio is `1.0` by construction — a tautology. Find it (`grep -n "RT_DEBUG_PDF_PARITY\|samplerLobeProbability" raytracing_closest_hit_common_inc.glsl`) and make it honest: report the single value, and amend its comment to say the ratio check is retired because the divergence it detected is now structurally impossible, pointing at the self-normalizing instrument as the live detector. Do NOT leave a probe that prints `1.0` and means nothing.

- [ ] **Step 4: Full build**

```bash
scons platform=windows target=editor tests=yes -j8
```

- [ ] **Step 5: Verify nothing moved**

```bash
bin/godot.windows.editor.x86_64.console.exe --headless --test
bin/godot.windows.editor.x86_64.console.exe --path pipeline_references res://tests/pt_energy_gate_scene.tscn
bin/godot.windows.editor.x86_64.console.exe --path pipeline_references res://tests/pt_anisotropy_gate_scene.tscn
bin/godot.windows.editor.x86_64.console.exe --path pipeline_references res://tests/pt_sky_energy_gate_scene.tscn
```

Expected: doctest 1526/0/3; `pt_energy_gate` PASS; `pt_anisotropy_gate` PASS within its ±0.5pp bands; `pt_sky_energy_gate` exits 1 as always with probe A 1.00000 and probe B@2048 ~0.98355.

`pt_anisotropy_gate` is the tightest instrument in the suite and the most likely to notice a real change. **If any number moves, investigate — do not rationalise it.** This phase changes no behaviour, so a moved number means the refactor is wrong.

Check the binary's mtime is newer than the build start before each run; a stale exe produced misleading numbers earlier in this project.

- [ ] **Step 6: Commit**

```bash
git add servers/rendering/renderer_rd/shaders/raytracing/brdf_inc.glsl servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl
git commit -m "refactor(pt): E2c route sampler and combinedPdf through the lobe registry"
```

---

## Task 4: Prove extensibility, then close out

**Files:**
- Modify: `PATH_TRACER_QUALITY_ROADMAP.md`

**Interfaces:**
- Consumes: the working registry.
- Produces: the closeout record. Nothing downstream.

- [ ] **Step 1: Demonstrate the deliverable**

The phase's actual product is that adding a lobe requires no selection-logic change. Prove it, then revert.

Temporarily set `LOBE_COUNT` to 3 with a third entry of weight `0.0` and a pdf of `0.0`, rebuild, and confirm `pt_anisotropy_gate` and `pt_energy_gate` still pass — a zero-weight lobe must be inert. Then revert to 2 and rebuild.

Record both results. If a zero-weight third lobe changes anything, the CDF or the combination has a normalisation bug that N=2 happened to hide, and that is a finding worth more than the closeout.

- [ ] **Step 2: Write the closeout**

Add `### 7.9 E2c - N-way lobe rewrite` to `PATH_TRACER_QUALITY_ROADMAP.md` after §7.8. Record:
- that this phase shipped no feature by design, and what that bought
- the two duplicated functions unified, and why the old comment's reasoning no longer holds
- specular-index-0 and the single-RNG-draw constraints, as constraints future work must honour
- the Step 1 three-lobe result
- **explicitly**: that bit-identity was verified structurally rather than by pixels, because `mean_luma` has a ~1e-5 run-to-run floor on an identical binary and therefore cannot resolve it. Do not claim the gates proved bit-identity.

Mark the N-way rewrite complete in the phase table; record clearcoat and sheen as remaining.

- [ ] **Step 3: Commit**

```bash
git add PATH_TRACER_QUALITY_ROADMAP.md
git commit -m "docs(pt): E2c closeout - N-way lobe rewrite"
```

---

## Self-review notes

**Spec coverage.** §3.1 unification → Task 2 Step 1, Task 3 Step 3. §3.2 specular-index-0 → Task 1's first and third test cases, Global Constraints, Task 3 Step 1. §3.3 RNG draw → Global Constraints, Task 3 Step 1. §3.4 evaluation order → Task 1's `combine_pdf` test, Task 3 Step 2. §4.1 registry → Task 2. §4.2 what does not change → Task 3 Steps 1-2's preservation instructions. §5 three verification layers → Task 1 (doctest), Task 3 Step 5 (gates), and the review dispatch (structural). §6.4 extensibility → Task 4 Step 1.

**Type consistency.** `LOBE_SPECULAR`/`LOBE_DIFFUSE`/`LOBE_COUNT`, `lobeWeight`, `selectLobe`, `combineLobePdf` used identically in Tasks 2, 3 and 4. The CPU mirrors in Task 1 use the same names in snake_case per the file's house style.

**Known risk the plan cannot remove.** The primary failure mode — a bitwise change invisible to every gate — is not detectable by any step in this plan. Spec §5 names the structural review as the instrument that carries that claim, and Task 3's dispatch must ask for it explicitly. A reviewer confirming "one RNG draw, specular at index 0, summation order preserved" is the only evidence that exists for the phase's central assertion.
