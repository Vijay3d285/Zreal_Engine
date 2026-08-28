# Clearcoat / Coat Layer (E2d) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Cycles' coat as a real layer — a GGX lobe that also withdraws energy from every layer beneath it — so clearcoat materials render as Blender renders them.

**Architecture:** The coat becomes lobe index 2 in E2c's registry, which first gains a per-lobe *throughput scale* separate from its *selection weight* (Cycles' `weight` vs `sample_weight`). Its layering attenuation needs a directional albedo, which is Cycles' `table_ggx_gen_schlick_ior_s[4096]` — copied verbatim out of Blender's source, uploaded as an SSBO, and read with hand-written trilinear that reproduces Cycles' endpoint-aligned indexing exactly.

**Tech Stack:** GLSL (Vulkan RD raytracing pipeline), C++ (Godot 4.7 fork), doctest, GDScript GPU gates.

## Global Constraints

Copied verbatim from the spec (`docs/superpowers/specs/2026-08-27-clearcoat-coat-layer-design.md`). Every task's requirements implicitly include this section.

- **Specular stays at lobe index 0.** E2c made registry order a contract. A diffuse-first registry inverts every pixel's lobe choice while leaving the image statistically identical — no gate can see it. Coat **appends** at index 2.
- **Exactly one `rng_1d(rng, RT_PRNG_LOBE)` draw, consumed once**, unremapped and unrescaled. A second draw or a remap shifts every subsequent sample in the path: statistically valid, bitwise different everywhere, invisible to every gate.
- **`alpha = coat_roughness²`, isotropic** (`closure.h:165`). Do **not** use the raster's `mix(0.001, 0.1, r)` remap.
- **The LUT lookup is endpoint-aligned**, `x = saturate(x) * (size - 1)` then trilinear with the top index clamped (`lookup_table.h:14-29`). **Never** upload it as a hardware-filtered 3D texture — hardware filtering is half-texel-centered and would be silently wrong everywhere.
- **`F0 = q²` while `z = sqrt(|q|)`, where `q = (ior-1)/(ior+1)`.** Passing one where the other belongs type-checks and is silently wrong.
- **`cos_NI` is NOT clamped before the lookup** (`bsdf_microfacet.h:504`); the `saturate` inside the table read absorbs negatives onto the `cos_NI = 0` row. Reproduce that; do not add a clamp.
- **Cycles clamps:** `coat_weight` skipped below `CLOSURE_WEIGHT_CUTOFF` = `1e-5f` (`svm/types.h:576`); `coat_roughness` via `saturatef`; `coat_ior` via `fmaxf(·, 1.0f)`; `coat_tint` via `max(·, 0)` (`closure.h:148-150`).
- **Tint is applied outside the coat-lobe branch** (`closure.h:155` vs `:178`). Two separate steps; do not fuse them into one branch.
- **The near-delta specular guard (`RT_MIS_DELTA_ROUGHNESS`) and the `VplusL` degenerate check in `combinedPdf` must survive verbatim** and must not be folded into the registry.
- **Every lobe's selection weight is clamped to `[0.01, 0.99]` when that lobe is active.** The sampler divides throughput by the selected weight, so an unclamped weight is an unbounded variance source. `lobeWeight` already does this; `coatLobeWeight` must match it.
- **sRGB:** every colour factor is sRGB-decoded on upload — `albedo_color` (`render_raytracing.cpp:1542`), `attenuation_color` (`:1745`), `specular_tint` (`:1766`). `clearcoat_tint` follows the same path. Any Cycles-comparison material must author colours with `.linear_to_srgb()`.
- **Gap #17 applies to the coat.** The multi-scatter term over-corrects by 3-8pp. Do not attempt to fix it; report raw and adjusted figures side by side.
- **NEVER touch, stage, revert, checkout over, or stash these six files** — they are the user's uncommitted work: `pipeline_references/compositor_effect.gd`, `image_glb_creation.gd`, `render.gd`, `structure.gd`, `video_glb_creation.gd`, `custom_shape.gd`. Use `git add` with **explicit paths only**, never `-A` or `.`.
- **Build:** `python -m SCons platform=windows target=editor tests=yes -j8` — bare `scons` is **not** on PATH on this machine. Run it in the **foreground**. After touching any `.glsl`, a full build is required so the `.glsl.gen.h` regenerates.
- **Test:** `bin/godot.windows.editor.x86_64.console.exe --headless --test` (all), or `--test-case="*Filter*"`. A bare positional after `--test` is **silently ignored** and runs the whole suite.
- **GPU gates need a real Vulkan device — no `--headless`:** `bin/godot.windows.editor.x86_64.console.exe --path pipeline_references res://tests/<name>_scene.tscn`
- **Baseline before you start:** doctest 1527 passed / 0 failed / 3 skipped, 2,066,552 assertions. `pt_energy_gate` PASS, `pt_anisotropy_gate` PASS, `pt_transmission_gate` PASS (44 checks).

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `servers/rendering/renderer_rd/storage_rd/ggx_coat_albedo_table.h` | **Create.** The 4096-float LUT copied from Cycles, plus its 16/16/16 dimensions. Data only, no logic. | 1 |
| `tests/servers/rendering/test_pt_coat_albedo.cpp` | **Create.** CPU mirrors of the trilinear read and the albedo estimate; the doctest that pins endpoint-aligned indexing. | 1 |
| `servers/rendering/renderer_rd/shaders/raytracing/brdf_inc.glsl` | Registry throughput split; `coatAlbedoEstimate`; the coat lobe's eval/sample/pdf; `combinedPdf` extension. | 2, 4, 5 |
| `servers/rendering/renderer_rd/shaders/raytracing/raytracing_data_inc.glsl` | `MaterialData` gains `clearcoat_ior`, `clearcoat_tint`. | 3 |
| `servers/rendering/renderer_rd/forward_clustered/render_raytracing.h` | `RT_MaterialData` 176 → 192 bytes, with offset asserts. | 3 |
| `servers/rendering/renderer_rd/forward_clustered/render_raytracing.cpp` | Upload the two new fields; create and bind the LUT SSBO at binding 38. | 3, 4 |
| `scene/resources/material.h` / `.cpp` | `clearcoat_ior`, `clearcoat_tint` on `BaseMaterial3D`. | 3 |
| `servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl` | Vis modes 36/37; the sampler's three-lobe selection; attenuation and tint applied to `ps.throughput`. | 3, 4, 5 |
| `pipeline_references/tests/pt_coat_gate.gd` + `_scene.tscn` | **Create.** Furnace energy gate, three-lobe pdf self-normalization, vis-mode arrival checks. | 6 |
| `PATH_TRACER_QUALITY_ROADMAP.md` | §7.10 closeout. | 7 |

---

## Task 1: The LUT, its CPU mirror, and the indexing that must not drift

**Files:**
- Create: `servers/rendering/renderer_rd/storage_rd/ggx_coat_albedo_table.h`
- Create: `tests/servers/rendering/test_pt_coat_albedo.cpp`

**Interfaces:**
- Consumes: nothing.
- Produces: `GGX_COAT_ALBEDO_TABLE[4096]`, `GGX_COAT_TABLE_DIM = 16`. CPU mirrors `coat_lut_read_3d(x, y, z)`, `coat_f0_from_ior(ior)`, `coat_z_from_ior(ior)`, `coat_albedo_estimate(coat_roughness, cos_ni, ior)` — all `static` inside `namespace TestPTCoatAlbedo` in the test file, following the house style of `test_pt_lobe_registry.cpp`.

**Why this task exists first.** The whole layer rests on one table read. Cycles indexes it endpoint-aligned; the obvious GPU implementation (a filtered 3D texture) is half-texel-centered. Both render plausibly. Only a test that reads at a *known grid point* and at a *known midpoint* can tell them apart, and this table has steep enough gradients to make that decisive: adjacent entries go `0.996991 → 0.144157`.

- [ ] **Step 1: Extract the table**

Run this exactly. It reads Blender's source and writes the header.

```bash
python - <<'PYEOF'
import io, re
src = r"C:\Users\aiadmin\Desktop\blender_build\blender\intern\cycles\scene\shader.tables"
s = io.open(src, encoding="utf-8", errors="replace").read()
m = re.search(r"static const float table_ggx_gen_schlick_ior_s\[4096\] = \{(.*?)\};", s, re.S)
assert m, "table_ggx_gen_schlick_ior_s not found"
vals = re.findall(r"(-?[0-9.]+(?:e[-+]?\d+)?)f", m.group(1))
assert len(vals) == 4096, len(vals)
hdr = ['/**************************************************************************/',
       '/*  ggx_coat_albedo_table.h                                               */',
       '/**************************************************************************/',
       '',
       '#pragma once',
       '',
       '// Directional-albedo interpolation factor s for a dielectric-Fresnel GGX',
       '// microfacet, indexed [x = rough][y = cos_NI][z = ior-param], 16x16x16.',
       '//',
       '// COPIED VERBATIM from Blender Cycles:',
       '//   intern/cycles/scene/shader.tables :: table_ggx_gen_schlick_ior_s[4096]',
       '// baked there at 2^20 samples/entry (intern/cycles/app/cycles_precompute.cpp:200-208).',
       '// Do not regenerate or "improve" these numbers -- matching Cycles bit-for-bit is',
       '// the entire point. Consumed via coat_albedo_estimate; see the E2d spec section 4.2.',
       '',
       'inline constexpr int GGX_COAT_TABLE_DIM = 16;',
       'inline constexpr float GGX_COAT_ALBEDO_TABLE[4096] = {']
for i in range(0, 4096, 8):
    hdr.append('\t' + ' '.join(f'{v}f,' for v in vals[i:i+8]))
hdr.append('};')
io.open("servers/rendering/renderer_rd/storage_rd/ggx_coat_albedo_table.h", "w",
         encoding="utf-8", newline="\n").write("\n".join(hdr) + "\n")
print("wrote 4096 values")
PYEOF
```

Expected: `wrote 4096 values`.

- [ ] **Step 2: Write the failing test**

Create `tests/servers/rendering/test_pt_coat_albedo.cpp`. Copy the Godot copyright header from `tests/servers/rendering/test_pt_lobe_registry.cpp` verbatim, then:

```cpp
#include "tests/test_macros.h"

TEST_FORCE_LINK(test_pt_coat_albedo)

#include "core/math/math_funcs.h"
#include "servers/rendering/renderer_rd/storage_rd/ggx_coat_albedo_table.h"

namespace TestPTCoatAlbedo {

// CPU mirrors of Cycles' lookup_table_read* (intern/cycles/kernel/util/lookup_table.h)
// and bsdf_microfacet_estimate_albedo's dielectric branch
// (intern/cycles/kernel/closure/bsdf_microfacet.h:556-579).
//
// THE INDEXING IS ENDPOINT-ALIGNED, NOT HALF-TEXEL-CENTERED. Cycles maps
// [0,1] onto [0, size-1] and lerps between integer entries. A hardware 3D
// texture sampler maps [0,1] onto texel CENTERS instead, which is off by half
// a texel everywhere -- it compiles, it renders, and it is silently wrong.
// The midpoint cases below are what tell the two apart.

static float coat_lut_read_1d(const float *p_data, float p_x, int p_size) {
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

static float coat_lut_read_2d(const float *p_data, float p_x, float p_y, int p_xsize, int p_ysize) {
	p_y = CLAMP(p_y, 0.0f, 1.0f) * float(p_ysize - 1);
	const int index = MIN(int(p_y), p_ysize - 1);
	const int nindex = MIN(index + 1, p_ysize - 1);
	const float t = p_y - float(index);
	const float data0 = coat_lut_read_1d(p_data + p_xsize * index, p_x, p_xsize);
	if (t == 0.0f) {
		return data0;
	}
	return (1.0f - t) * data0 + t * coat_lut_read_1d(p_data + p_xsize * nindex, p_x, p_xsize);
}

static float coat_lut_read_3d(float p_x, float p_y, float p_z) {
	const int d = GGX_COAT_TABLE_DIM;
	p_z = CLAMP(p_z, 0.0f, 1.0f) * float(d - 1);
	const int index = MIN(int(p_z), d - 1);
	const int nindex = MIN(index + 1, d - 1);
	const float t = p_z - float(index);
	const float data0 = coat_lut_read_2d(GGX_COAT_ALBEDO_TABLE + d * d * index, p_x, p_y, d, d);
	if (t == 0.0f) {
		return data0;
	}
	const float data1 = coat_lut_read_2d(GGX_COAT_ALBEDO_TABLE + d * d * nindex, p_x, p_y, d, d);
	return (1.0f - t) * data0 + t * data1;
}

// q = (ior-1)/(ior+1). F0 SQUARES it; z takes its square ROOT. Opposite
// directions from the same quantity -- swapping them type-checks and is wrong.
static float coat_f0_from_ior(float p_ior) {
	const float q = (p_ior - 1.0f) / (p_ior + 1.0f);
	return q * q;
}

static float coat_z_from_ior(float p_ior) {
	return Math::sqrt(Math::abs((p_ior - 1.0f) / (p_ior + 1.0f)));
}

static float coat_albedo_estimate(float p_coat_roughness, float p_cos_ni, float p_ior) {
	const float alpha = p_coat_roughness * p_coat_roughness;
	const float rough = Math::sqrt(Math::sqrt(alpha * alpha)); // sqrt(sqrt(ax*ay)), ax == ay
	const float z = coat_z_from_ior(p_ior);
	const float s = coat_lut_read_3d(rough, p_cos_ni, z);
	return Math::lerp(coat_f0_from_ior(p_ior), 1.0f, s);
}

TEST_CASE("[PathTracer][CoatAlbedo] the table is the one Cycles ships") {
	// Guards against a re-extraction silently pulling a different table or a
	// truncated one. Values read directly out of shader.tables at these
	// indices; index = x + 16*y + 256*z.
	CHECK(GGX_COAT_ALBEDO_TABLE[256] == doctest::Approx(0.996991f).epsilon(1e-6));
	CHECK(GGX_COAT_ALBEDO_TABLE[257] == doctest::Approx(0.702628f).epsilon(1e-6));
	CHECK(GGX_COAT_ALBEDO_TABLE[272] == doctest::Approx(0.144157f).epsilon(1e-6));
	CHECK(GGX_COAT_ALBEDO_TABLE[2184] == doctest::Approx(0.037176f).epsilon(1e-6));
	CHECK(GGX_COAT_ALBEDO_TABLE[3840] == doctest::Approx(0.504788f).epsilon(1e-6));
}

TEST_CASE("[PathTracer][CoatAlbedo] reads at grid points return entries exactly") {
	// Endpoint-aligned: u = i/15 lands EXACTLY on entry i, t == 0, early-out.
	// A half-texel-centered sampler returns a blend here instead.
	const float u1 = 1.0f / 15.0f;
	CHECK(coat_lut_read_3d(0.0f, 0.0f, u1) == doctest::Approx(0.996991f).epsilon(1e-6));
	CHECK(coat_lut_read_3d(u1, 0.0f, u1) == doctest::Approx(0.702628f).epsilon(1e-6));
	CHECK(coat_lut_read_3d(0.0f, u1, u1) == doctest::Approx(0.144157f).epsilon(1e-6));
}

TEST_CASE("[PathTracer][CoatAlbedo] midpoints lerp between neighbours") {
	// THE case that separates endpoint-aligned from half-texel-centered.
	// Halfway between x=0 and x=1 at y=0, z=1 must be the mean of 0.996991
	// and 0.702628. A half-texel sampler reads somewhere else entirely, and
	// this table's gradient here is steep enough that it cannot coincide.
	const float u1 = 1.0f / 15.0f;
	const float expected_x = 0.5f * (0.996991f + 0.702628f);
	CHECK(coat_lut_read_3d(0.5f * u1, 0.0f, u1) == doctest::Approx(expected_x).epsilon(1e-5));

	const float expected_y = 0.5f * (0.996991f + 0.144157f);
	CHECK(coat_lut_read_3d(0.0f, 0.5f * u1, u1) == doctest::Approx(expected_y).epsilon(1e-5));
}

TEST_CASE("[PathTracer][CoatAlbedo] out-of-range inputs saturate, they do not wrap") {
	// cos_NI is NOT clamped by Cycles before the read (bsdf_microfacet.h:504);
	// the saturate inside the table read absorbs it onto the cos_NI = 0 row.
	const float u1 = 1.0f / 15.0f;
	CHECK(coat_lut_read_3d(0.0f, -0.5f, u1) == doctest::Approx(0.996991f).epsilon(1e-6));
	CHECK(coat_lut_read_3d(0.0f, 0.0f, u1) == doctest::Approx(0.996991f).epsilon(1e-6));
	// Top edge clamps rather than reading past the end.
	CHECK(coat_lut_read_3d(1.0f, 1.0f, 1.0f) == doctest::Approx(GGX_COAT_ALBEDO_TABLE[4095]).epsilon(1e-6));
	CHECK(coat_lut_read_3d(2.0f, 2.0f, 2.0f) == doctest::Approx(GGX_COAT_ALBEDO_TABLE[4095]).epsilon(1e-6));
}

TEST_CASE("[PathTracer][CoatAlbedo] F0 and z are built from q in opposite directions") {
	// ior 1.5 -> q = 0.2. F0 = 0.04 (the familiar dielectric value); z = sqrt(0.2).
	const float q = (1.5f - 1.0f) / (1.5f + 1.0f);
	CHECK(q == doctest::Approx(0.2f).epsilon(1e-6));
	CHECK(coat_f0_from_ior(1.5f) == doctest::Approx(0.04f).epsilon(1e-6));
	CHECK(coat_z_from_ior(1.5f) == doctest::Approx(0.4472136f).epsilon(1e-6));
	// Pin the counterfactual: swapping them is NOT a near miss, it is 10x off.
	CHECK(Math::abs(coat_f0_from_ior(1.5f) - coat_z_from_ior(1.5f)) > 0.4f);
}

TEST_CASE("[PathTracer][CoatAlbedo] the estimate is bounded and rises toward grazing") {
	// At normal incidence the estimate must approach F0; at grazing it must
	// approach 1. Both are physical facts about Fresnel, independent of the
	// table, so this fails if the y axis is inverted -- a mistake no rendered
	// image would make obvious.
	const float at_normal = coat_albedo_estimate(0.1f, 1.0f, 1.5f);
	const float at_grazing = coat_albedo_estimate(0.1f, 0.0f, 1.5f);
	CHECK(at_normal == doctest::Approx(0.04f).epsilon(0.02));
	CHECK(at_grazing > 0.5f);
	CHECK(at_grazing > at_normal);
	CHECK(at_normal >= 0.0f);
	CHECK(at_grazing <= 1.0f);
}

} // namespace TestPTCoatAlbedo
```

- [ ] **Step 3: Build and run — expect RED before the header exists, GREEN after Step 1**

Step 1 already wrote the header, so this should build. Run:

```bash
python -m SCons platform=windows target=editor tests=yes -j8
```

Then:

```bash
bin/godot.windows.editor.x86_64.console.exe --headless --test --test-case="*CoatAlbedo*"
```

Expected: 6 test cases, all passing.

**If the midpoint case fails**, the mirror is not endpoint-aligned — fix the mirror, do not loosen the epsilon. That case is the entire reason this task exists.

- [ ] **Step 4: Prove the guard by breaking the thing it guards**

Temporarily change `coat_lut_read_1d`'s first line to the half-texel-centered form:

```cpp
	p_x = CLAMP(p_x, 0.0f, 1.0f) * float(p_size) - 0.5f;
```

Rebuild and re-run the filter. **Expected: the grid-point and midpoint cases FAIL.** Record the observed values. Then revert the line, rebuild, and confirm green again.

Do not skip this. "The test covers this" is an assumption until the test has been seen to fail.

- [ ] **Step 5: Run the full suite**

```bash
bin/godot.windows.editor.x86_64.console.exe --headless --test
```

Expected: 1533 passed / 0 failed / 3 skipped (1527 + 6 new). Task 2 adds the seventh, taking later tasks to 1534.

- [ ] **Step 6: Commit**

```bash
git add servers/rendering/renderer_rd/storage_rd/ggx_coat_albedo_table.h tests/servers/rendering/test_pt_coat_albedo.cpp
git commit -m "test(pt): E2d coat albedo LUT and its endpoint-aligned indexing"
```

---

## Task 2: Registry gains a throughput scale — structure only, no consumers

**Files:**
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/brdf_inc.glsl:1730-1786`
- Modify: `tests/servers/rendering/test_pt_lobe_registry.cpp`

**Interfaces:**
- Consumes: the existing `LOBE_SPECULAR`/`LOBE_DIFFUSE`/`LOBE_COUNT`, `lobeWeight`, `selectLobe`, `combineLobePdf`.
- Produces: no new function and **no new constant** — only the documented convention below, plus a doctest that pins the fact the convention rests on. No signature changes. An earlier draft of this plan introduced a `LOBE_THROUGHPUT_IDENTITY 1.0f` that nothing would have referenced: dead code the reviewer would rightly flag, mandated by the plan. Removed.

**What this task actually does.** It introduces the *concept* and its documentation without changing any arithmetic, exactly as E2c's Task 2 added the registry with no consumers. `LOBE_COUNT` stays 2. Nothing renders differently.

The convention: a lobe has a **selection weight** (its probability of being drawn, normalised across lobes) and a **throughput scale** (a radiometric multiplier applied to what passes *beneath* it). At N=2 every throughput scale is 1.0, which is why the distinction has not existed until now.

- [ ] **Step 1: Add the convention comment and the identity constant**

In `brdf_inc.glsl`, immediately after the `#define LOBE_COUNT 2` block, insert:

```glsl
// ---------------------------------------------------------------------------
// SELECTION WEIGHT vs THROUGHPUT SCALE (E2d).
//
// Cycles gives every closure two independent numbers, and conflating them is
// the defect this separation exists to prevent:
//
//   weight        -- radiometric throughput. What the closure multiplies into
//                    the path, and what a LAYER withdraws from everything
//                    beneath it (closure_layering_weight, bsdf_util.h:440).
//   sample_weight -- selection probability. Which lobe the RNG picks.
//
// Through E2c these were the same array, and that was CORRECT at N == 2: the
// two lobes' weights summed to 1 and no layer existed to withdraw anything.
//
// Coat (E2d) breaks that. Its attenuation of the base is a throughput factor,
// NOT a selection probability. Folding it into the selection weights and
// renormalising would still integrate to the right mean -- MIS is unbiased for
// ANY weights summing to 1 pointwise -- so the error would be MEAN-PRESERVING
// and invisible to every rendered gate this project has. That exact shape
// already cost a Phase E1 defect.
//
// So: weights[] stays the selection array. Throughput scales are applied to
// ps.throughput at the call site, never mixed into weights[].
// ---------------------------------------------------------------------------
```

- [ ] **Step 2: Add the doctest that pins the convention at N=2**

Append to `tests/servers/rendering/test_pt_lobe_registry.cpp`, inside the existing namespace, before the closing brace:

```cpp
TEST_CASE("[PathTracer][LobeRegistry] the two-lobe weights sum to exactly 1.0f") {
	// LOAD-BEARING, and not obvious. E2d appends the coat at index 2, and
	// select_lobe falls through to `return LOBE_COUNT - 1` -- the coat -- for
	// any u at or above the running weight sum. On a material with no coat that
	// lobe has weight 0, and the sampler divides throughput by it.
	//
	// That fallback is unreachable ONLY because fl(p) + fl(1-p) is exactly 1.0f
	// for every float32 p, so the residue window is empty and u < 1.0f always
	// holds (rng_1d bottoms out in sb_uint_to_float_excl, so u lies in [0,1)
	// strictly). For p >= 0.5 that is Sterbenz's lemma; below it the rounding
	// error is at most a half-ulp of 1.0 and rounds back to 1.0.
	//
	// Pin it, because it is the reason no zero-division guard is needed. If a
	// later change computes the diffuse weight some other way -- say
	// 1.0f - clamp(p, ...) against a differently-clamped p -- this fails and
	// says why, instead of the render growing NaNs at a 1-in-10-million rate
	// that no mean-based gate would attribute correctly.
	const float ps[] = { 0.01f, 0.0700001f, 0.37f, 0.5f, 0.6180339f, 0.73f, 0.99f };
	for (float p : ps) {
		CAPTURE(p);
		const float weights[LOBE_COUNT] = { p, 1.0f - p };
		CHECK(weights[0] + weights[1] == 1.0f);
	}
}
```

- [ ] **Step 3: Build and run**

```bash
python -m SCons platform=windows target=editor tests=yes -j8
bin/godot.windows.editor.x86_64.console.exe --headless --test --test-case="*LobeRegistry*"
```

Expected: 7 cases (6 existing + 1 new), all passing.

**Do not weaken the new case to `doctest::Approx`.** Bit-exactness is the
property being asserted; a tolerance would pass on precisely the drift the
case exists to catch.

- [ ] **Step 4: Verify nothing renders differently**

```bash
bin/godot.windows.editor.x86_64.console.exe --path pipeline_references res://tests/pt_energy_gate_scene.tscn
bin/godot.windows.editor.x86_64.console.exe --path pipeline_references res://tests/pt_anisotropy_gate_scene.tscn
```

Expected: both PASS. This task is comment-and-constant only; a change here means something else moved.

- [ ] **Step 5: Commit**

```bash
git add servers/rendering/renderer_rd/shaders/raytracing/brdf_inc.glsl tests/servers/rendering/test_pt_lobe_registry.cpp
git commit -m "docs(pt): E2d separate selection weight from throughput scale"
```

---

## Task 3: `clearcoat_ior` and `clearcoat_tint` reach the GPU

**Files:**
- Modify: `servers/rendering/renderer_rd/forward_clustered/render_raytracing.h:105-145`
- Modify: `servers/rendering/renderer_rd/forward_clustered/render_raytracing.cpp` (defaults near `:1476`, upload near `:1790`)
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_data_inc.glsl:150-160`
- Modify: `scene/resources/material.h`, `scene/resources/material.cpp`
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl` (new vis mode 36)

**Interfaces:**
- Consumes: nothing from Tasks 1-2.
- Produces: GLSL `material.clearcoat_ior` (float) and `material.clearcoat_tint` (vec3), both readable in `raytracing_closest_hit_common_inc.glsl`. `BaseMaterial3D::set_clearcoat_ior(float)` / `get_clearcoat_ior()`, `set_clearcoat_tint(Color)` / `get_clearcoat_tint()`.

**The layout hazard, stated plainly.** `RT_MaterialData` is 176 bytes with one free trailing float (`_pad0`). `clearcoat_ior` takes that slot for free. `clearcoat_tint` is a `vec3`, and **std430 aligns a vec3 to 16 bytes** — it must land at offset 176, with a fresh `_pad0` at 188, taking the struct to 192. `sizeof` alone does not catch a misalignment: reordering members around a vec3 shifts the GPU's view of every later field without changing `sizeof`. That is why `render_raytracing.h:141-145` carries `offsetof` asserts, and why this task adds one more.

- [ ] **Step 1: Write the failing static asserts**

In `render_raytracing.h`, replace the trailing `float _pad0;` and the assert block:

```cpp
	float anisotropy;
	// E2d: coat IOR. Takes the slot the old _pad0 occupied, so the struct
	// stays 176 bytes up to here. Cycles clamps this with fmaxf(., 1.0f)
	// (svm/closure.h:149); the upload does the same.
	float clearcoat_ior;
	// E2d: coat tint, Beer's-law absorption through the coat. A vec3 aligns
	// to 16 in std430, so it starts at 176 and the struct grows to 192.
	float clearcoat_tint[3];
	float _pad0;
};
static_assert(sizeof(RT_MaterialData) == 192, "RT_MaterialData must be 192 bytes for std430");
// A vec3 aligns to 16 bytes in std430, so reordering members around one shifts
// the GPU's view of every subsequent field WITHOUT changing sizeof. The size
// assert alone passes on a broken layout; these four are what catch it.
static_assert(offsetof(RT_MaterialData, attenuation_color) == 112, "attenuation_color must be 16-byte aligned for std430 vec3");
static_assert(offsetof(RT_MaterialData, specular_tint) == 128, "specular_tint must be 16-byte aligned for std430 vec3");
static_assert(offsetof(RT_MaterialData, sheen_color) == 144, "sheen_color must be 16-byte aligned for std430 vec3");
static_assert(offsetof(RT_MaterialData, clearcoat_tint) == 176, "clearcoat_tint must be 16-byte aligned for std430 vec3");
static_assert(offsetof(RT_MaterialData, clearcoat_ior) == 172, "clearcoat_ior must occupy the slot the old _pad0 held");
```

- [ ] **Step 2: Build to confirm the asserts hold**

```bash
python -m SCons platform=windows target=editor tests=yes -j8
```

Expected: compiles. **If an assert fires, the layout is wrong — fix the member order, do not change the assert.** The assert is the instrument.

- [ ] **Step 3: Mirror the struct in GLSL**

In `raytracing_data_inc.glsl`, replace the tail of `MaterialData`:

```glsl
	float anisotropy;
	float clearcoat_ior; // E2d. Was _pad0.
	vec3 clearcoat_tint; // E2d. std430 aligns this to offset 176.
	float _pad0;
};
```

- [ ] **Step 4: Set defaults and upload**

In `render_raytracing.cpp`, beside the existing `mat.clearcoat = 0.0f;` / `mat.clearcoat_roughness = 0.0f;` (near `:1476`):

```cpp
	mat.clearcoat_ior = 1.5f;
	mat.clearcoat_tint[0] = 1.0f;
	mat.clearcoat_tint[1] = 1.0f;
	mat.clearcoat_tint[2] = 1.0f;
```

Beside the existing `clearcoat_roughness` read (near `:1797`):

```cpp
	Variant clearcoat_ior_var = material_storage->material_get_param(p_material_rid, "clearcoat_ior");
	if (clearcoat_ior_var.get_type() == Variant::FLOAT) {
		// Cycles: fmaxf(coat_ior, 1.0f) -- svm/closure.h:149.
		mat.clearcoat_ior = MAX((float)clearcoat_ior_var, 1.0f);
	}

	Variant clearcoat_tint_var = material_storage->material_get_param(p_material_rid, "clearcoat_tint");
	if (clearcoat_tint_var.get_type() == Variant::COLOR) {
		// sRGB-decoded like every other colour factor here -- albedo_color
		// (:1542), attenuation_color (:1745), specular_tint (:1766). Cycles'
		// coat_tint socket is already linear, so a Cycles-comparison material
		// must author this with .linear_to_srgb() to land on the same value.
		Color c = ((Color)clearcoat_tint_var).srgb_to_linear();
		// Cycles: max(coat_tint, zero) -- svm/closure.h:150.
		mat.clearcoat_tint[0] = MAX(c.r, 0.0f);
		mat.clearcoat_tint[1] = MAX(c.g, 0.0f);
		mat.clearcoat_tint[2] = MAX(c.b, 0.0f);
	}
```

- [ ] **Step 5: Add the two BaseMaterial3D properties**

In `scene/resources/material.h`, beside the existing `float clearcoat` / `float clearcoat_roughness` members, add `float clearcoat_ior;` and `Color clearcoat_tint;`, and declare the four accessors.

In `scene/resources/material.cpp`, beside `set_clearcoat_roughness` (near `:2274`):

```cpp
void BaseMaterial3D::set_clearcoat_ior(float p_clearcoat_ior) {
	clearcoat_ior = p_clearcoat_ior;
	RS::get_singleton()->material_set_param(_get_material(), "clearcoat_ior", p_clearcoat_ior);
}

float BaseMaterial3D::get_clearcoat_ior() const {
	return clearcoat_ior;
}

void BaseMaterial3D::set_clearcoat_tint(const Color &p_clearcoat_tint) {
	clearcoat_tint = p_clearcoat_tint;
	RS::get_singleton()->material_set_param(_get_material(), "clearcoat_tint", p_clearcoat_tint);
}

Color BaseMaterial3D::get_clearcoat_tint() const {
	return clearcoat_tint;
}
```

Bind them beside the existing clearcoat binds (near `:3517`):

```cpp
	ClassDB::bind_method(D_METHOD("set_clearcoat_ior", "clearcoat_ior"), &BaseMaterial3D::set_clearcoat_ior);
	ClassDB::bind_method(D_METHOD("get_clearcoat_ior"), &BaseMaterial3D::get_clearcoat_ior);
	ClassDB::bind_method(D_METHOD("set_clearcoat_tint", "clearcoat_tint"), &BaseMaterial3D::set_clearcoat_tint);
	ClassDB::bind_method(D_METHOD("get_clearcoat_tint"), &BaseMaterial3D::get_clearcoat_tint);
```

Expose them beside the existing clearcoat properties (near `:3805`):

```cpp
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "clearcoat_ior", PROPERTY_HINT_RANGE, "1,3,0.01"), "set_clearcoat_ior", "get_clearcoat_ior");
	ADD_PROPERTY(PropertyInfo(Variant::COLOR, "clearcoat_tint"), "set_clearcoat_tint", "get_clearcoat_tint");
```

And set the defaults beside `set_clearcoat_roughness(0.5)` (near `:4129`):

```cpp
	set_clearcoat_ior(1.5);
	set_clearcoat_tint(Color(1, 1, 1));
```

- [ ] **Step 6: Add vis mode 36 so arrival is verified, not inferred**

In `raytracing_closest_hit_common_inc.glsl`, after the `vis_mode == 35` block (near `:707`), before the `#endif`:

```glsl
	} else if (vis_mode == 36) {
		// E2d arrival gate: r = clearcoat, g = clearcoat_roughness,
		// b = (clearcoat_ior - 1.0) so the 1.5 default reads 0.5 rather than
		// saturating. Tint gets its own mode -- packing five numbers into
		// three channels is how a field silently reads as its neighbour.
		ps.radiance = vec3(dbg_material.clearcoat, dbg_material.clearcoat_roughness,
				dbg_material.clearcoat_ior - 1.0);
	} else if (vis_mode == 37) {
		// E2d arrival gate: the tint, straight through.
		ps.radiance = dbg_material.clearcoat_tint;
```

- [ ] **Step 7: Full build and verify**

```bash
python -m SCons platform=windows target=editor tests=yes -j8
bin/godot.windows.editor.x86_64.console.exe --headless --test
bin/godot.windows.editor.x86_64.console.exe --path pipeline_references res://tests/pt_energy_gate_scene.tscn
```

Expected: build clean, doctest 1534/0/3, energy gate PASS. Nothing consumes the new fields yet, so the render must be unchanged.

- [ ] **Step 8: Commit**

```bash
git add servers/rendering/renderer_rd/forward_clustered/render_raytracing.h servers/rendering/renderer_rd/forward_clustered/render_raytracing.cpp servers/rendering/renderer_rd/shaders/raytracing/raytracing_data_inc.glsl servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl scene/resources/material.h scene/resources/material.cpp
git commit -m "feat(pt): E2d clearcoat_ior and clearcoat_tint reach the shader"
```

---

## Task 4: The LUT on the GPU, and `coatAlbedoEstimate` in GLSL

**Files:**
- Modify: `servers/rendering/renderer_rd/forward_clustered/render_raytracing.cpp` (SSBO creation and binding 38)
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/scene_raytracing_raygen.glsl` (the SSBO declaration)
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/brdf_inc.glsl` (the read + estimate)
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl` (vis mode 38)

**Interfaces:**
- Consumes: `GGX_COAT_ALBEDO_TABLE` / `GGX_COAT_TABLE_DIM` from Task 1.
- Produces: GLSL `float coatAlbedoEstimate(float coatRoughness, float cosNI, float ior)`, and `float coatLutRead3D(float x, float y, float z)`.

**Binding 38 is free.** Set 0 currently uses 0-12, 14-30, 32-37. Do not reuse 13 or 31 — 31 is bound from C++ (`render_raytracing.cpp:3962`) without a matching GLSL declaration in the files grepped, and reusing an ambiguous slot to save a number is not worth the failure mode.

- [ ] **Step 1: Declare the SSBO in GLSL**

In `scene_raytracing_raygen.glsl`, beside the other `set = 0` storage buffers (near `:644`), in **every** stage block that needs it — the closest-hit stage is the consumer:

```glsl
layout(set = 0, binding = 38, std430) readonly buffer CoatAlbedoTable {
	float data[];
} coat_albedo_table;
```

- [ ] **Step 2: Write the GLSL read and estimate**

In `brdf_inc.glsl`, after `lobeWeight`:

```glsl
#define GGX_COAT_TABLE_DIM 16

// Cycles' lookup_table_read* (intern/cycles/kernel/util/lookup_table.h:14-71),
// transcribed. ENDPOINT-ALIGNED: [0,1] maps onto [0, size-1] and lerps between
// integer entries.
//
// DO NOT replace this with a hardware-filtered 3D texture. Hardware filtering
// is half-texel-centered; it would compile, render plausibly, and be wrong by
// half a texel at every lookup -- a small, uniform, entirely silent energy
// error. test_pt_coat_albedo.cpp's midpoint cases exist to catch exactly that,
// and they only guard the CPU mirror; this function is on its honour.
float coatLutRead1D(int base, float x, int size) {
	x = clamp(x, 0.0f, 1.0f) * float(size - 1);
	int index = min(int(x), size - 1);
	int nindex = min(index + 1, size - 1);
	float t = x - float(index);
	float data0 = coat_albedo_table.data[base + index];
	if (t == 0.0f) {
		return data0;
	}
	return (1.0f - t) * data0 + t * coat_albedo_table.data[base + nindex];
}

float coatLutRead2D(int base, float x, float y, int xsize, int ysize) {
	y = clamp(y, 0.0f, 1.0f) * float(ysize - 1);
	int index = min(int(y), ysize - 1);
	int nindex = min(index + 1, ysize - 1);
	float t = y - float(index);
	float data0 = coatLutRead1D(base + xsize * index, x, xsize);
	if (t == 0.0f) {
		return data0;
	}
	return (1.0f - t) * data0 + t * coatLutRead1D(base + xsize * nindex, x, xsize);
}

float coatLutRead3D(float x, float y, float z) {
	const int d = GGX_COAT_TABLE_DIM;
	z = clamp(z, 0.0f, 1.0f) * float(d - 1);
	int index = min(int(z), d - 1);
	int nindex = min(index + 1, d - 1);
	float t = z - float(index);
	float data0 = coatLutRead2D(d * d * index, x, y, d, d);
	if (t == 0.0f) {
		return data0;
	}
	float data1 = coatLutRead2D(d * d * nindex, x, y, d, d);
	return (1.0f - t) * data0 + t * data1;
}

// Directional albedo of the coat, following bsdf_microfacet_estimate_albedo's
// dielectric branch (bsdf_microfacet.h:556-579) -- reflection only, since the
// coat is neither a glass closure nor DIELECTRIC_TINT.
//
// Writing q = (ior-1)/(ior+1): F0 SQUARES q, z takes its square ROOT. Opposite
// directions from the same quantity. Swapping them type-checks.
//
// cosNI is deliberately NOT clamped here. Cycles does not clamp it either
// (bsdf_microfacet.h:504); the clamp inside coatLutRead3D absorbs a negative
// onto the cosNI = 0 row. Adding a clamp of our own would diverge.
float coatAlbedoEstimate(float coatRoughness, float cosNI, float ior) {
	float alpha = coatRoughness * coatRoughness;
	float rough = sqrt(sqrt(alpha * alpha)); // sqrt(sqrt(ax*ay)); ax == ay for the coat.
	float q = (ior - 1.0f) / (ior + 1.0f);
	float f0 = q * q;
	float z = sqrt(abs(q));
	float s = coatLutRead3D(rough, cosNI, z);
	return mix(f0, 1.0f, s);
}
```

- [ ] **Step 3: Upload the table from C++**

In `render_raytracing.cpp`, include the header and create the buffer once (beside the other persistent buffers), then bind it:

```cpp
#include "servers/rendering/renderer_rd/storage_rd/ggx_coat_albedo_table.h"
```

Creation (once, guarded so it is not rebuilt per frame):

```cpp
	if (coat_albedo_buffer.is_null()) {
		Vector<uint8_t> bytes;
		bytes.resize(sizeof(GGX_COAT_ALBEDO_TABLE));
		memcpy(bytes.ptrw(), GGX_COAT_ALBEDO_TABLE, sizeof(GGX_COAT_ALBEDO_TABLE));
		coat_albedo_buffer = RD::get_singleton()->storage_buffer_create(bytes.size(), bytes);
	}
```

Add `RID coat_albedo_buffer;` to the class in `render_raytracing.h`, and free it wherever the other buffers are freed.

Binding, beside the existing `u.binding = 37` block (near `:4045`):

```cpp
	{
		RD::Uniform u;
		u.uniform_type = RD::UNIFORM_TYPE_STORAGE_BUFFER;
		u.binding = 38;
		u.append_id(coat_albedo_buffer);
		uniforms.push_back(u);
	}
```

- [ ] **Step 4: Add vis mode 38, the CPU/GPU parity detector**

In `raytracing_closest_hit_common_inc.glsl`, after the vis mode 37 block:

```glsl
	} else if (vis_mode == 38) {
		// E2d: coatAlbedoEstimate evaluated on the GPU, so the gate can compare
		// it against test_pt_coat_albedo.cpp's CPU mirror. A transcription slip
		// between the two -- a swapped F0/z, a half-texel index -- produces a
		// plausible render and no failing test WITHOUT this readout, because
		// the estimate only ever appears multiplied into an attenuation.
		//
		// r = estimate at this hit's cos(N,V); g = estimate forced to cosNI 1.0
		// (normal incidence, must approach F0); b = forced to cosNI 0.0
		// (grazing, must approach 1).
		float cosNI = dot(N, V);
		ps.radiance = vec3(
				coatAlbedoEstimate(dbg_material.clearcoat_roughness, cosNI, dbg_material.clearcoat_ior),
				coatAlbedoEstimate(dbg_material.clearcoat_roughness, 1.0, dbg_material.clearcoat_ior),
				coatAlbedoEstimate(dbg_material.clearcoat_roughness, 0.0, dbg_material.clearcoat_ior));
```

- [ ] **Step 5: Full build and verify no render change**

```bash
python -m SCons platform=windows target=editor tests=yes -j8
bin/godot.windows.editor.x86_64.console.exe --headless --test
bin/godot.windows.editor.x86_64.console.exe --path pipeline_references res://tests/pt_energy_gate_scene.tscn
bin/godot.windows.editor.x86_64.console.exe --path pipeline_references res://tests/pt_anisotropy_gate_scene.tscn
```

Expected: build clean, doctest 1534/0/3, both gates PASS. `coatAlbedoEstimate` has no non-debug consumer yet.

- [ ] **Step 6: Commit**

```bash
git add servers/rendering/renderer_rd/forward_clustered/render_raytracing.h servers/rendering/renderer_rd/forward_clustered/render_raytracing.cpp servers/rendering/renderer_rd/shaders/raytracing/scene_raytracing_raygen.glsl servers/rendering/renderer_rd/shaders/raytracing/brdf_inc.glsl servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl
git commit -m "feat(pt): E2d coat albedo LUT on the GPU with endpoint-aligned reads"
```

---

## Task 5: The coat lobe and its attenuation, landed together

**Files:**
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/brdf_inc.glsl` (`MaterialProperties`, `LOBE_COUNT`, `combinedPdf`, coat eval/sample)
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl` (sampler, throughput)

**Interfaces:**
- Consumes: `coatAlbedoEstimate` (Task 4), the selection-vs-throughput convention (Task 2), `material.clearcoat_ior` / `clearcoat_tint` (Task 3).
- Produces: `LOBE_COAT = 2`, `LOBE_COUNT = 3`; `float coatLobeWeight(MaterialProperties material, float cosNI)`; `float3 evalCoat(...)`; `float coatPdf(...)`.

**These land in one commit on purpose.** A coat lobe without attenuation is an additive coat — the wrong render. Attenuation without the lobe loses energy with nothing to receive it. Every intermediate state is a wrong render, so there is no honest place to split. This mirrors E2c's Task 3, which switched both registry consumers together for the same reason.

- [ ] **Step 1: Extend `MaterialProperties`**

In `brdf_inc.glsl`, add to `struct MaterialProperties` (after `transmissivness`, keeping the existing members in place):

```glsl
	// E2d coat. coatWeight 0 disables the layer entirely.
	float coatWeight;
	float coatRoughness;
	float coatIor;
	float3 coatTint;
```

Set them wherever `MaterialProperties` is populated from `MaterialData`, applying Cycles' clamps (`svm/closure.h:148-150`):

```glsl
	brdf_mat.coatWeight = max(material.clearcoat, 0.0f);
	brdf_mat.coatRoughness = clamp(material.clearcoat_roughness, 0.0f, 1.0f);
	brdf_mat.coatIor = max(material.clearcoat_ior, 1.0f);
	brdf_mat.coatTint = max(material.clearcoat_tint, float3(0.0f, 0.0f, 0.0f));
```

- [ ] **Step 2: Widen the registry to three lobes**

```glsl
#define LOBE_SPECULAR 0
#define LOBE_DIFFUSE 1
// E2d. APPENDS -- it does not displace specular from index 0, which E2c made a
// contract. The coat is physically outermost, but layering happens through the
// throughput scale, not through registry position.
#define LOBE_COAT 2
#define LOBE_COUNT 3
```

Add the coat's selection weight:

```glsl
// Selection probability mass for the coat, BEFORE normalisation against the
// base lobes. Cycles sets a closure's sample_weight from its estimated albedo
// (bsdf_microfacet.h:1021), so sampling effort tracks how much light the coat
// actually returns.
//
// Below CLOSURE_WEIGHT_CUTOFF (1e-5, svm/types.h:576) Cycles skips the coat
// entirely; returning 0 here does the same.
//
// THE CLAMP IS NOT COSMETIC. The sampler divides throughput by the selected
// lobe's weight, so an unclamped mass is an unbounded variance source: a coat
// just above the cutoff with a typical estimate near 0.04 yields ~4e-7, and
// dividing by that is a 2.5-million-fold spike -- fireflies on any faintly
// coated material. Symmetrically, a mass near 1 drives baseShare toward 0 and
// does the same to the specular and diffuse divisors.
//
// lobeWeight (above) already ends in clamp(..., 0.01f, 0.99f) for exactly this
// reason. Mirror it rather than inventing a different bound. Cycles does not
// clamp its sample_weight, but Cycles carries variance machinery this
// integrator does not; matching its noise profile is not the goal, matching
// its IMAGE is, and an unbounded divisor changes the image through noise.
float coatLobeWeight(MaterialProperties material, float cosNI) {
	if (material.coatWeight <= 0.00001f) {
		return 0.0f;
	}
	float mass = material.coatWeight * coatAlbedoEstimate(material.coatRoughness, cosNI, material.coatIor);
	return clamp(mass, 0.01f, 0.99f);
}
```

- [ ] **Step 3: Three-lobe selection in the sampler**

In `raytracing_closest_hit_common_inc.glsl`, replace the weights block (currently at `:1346-1356`):

```glsl
		float cosNI = dot(N, V);
		float coatMass = coatLobeWeight(brdf_mat, cosNI);
		// The coat takes coatMass of the selection mass; the base lobes split
		// what is left, in their existing proportion. Specular stays at index 0.
		float baseShare = 1.0 - coatMass;
		float pSpec = lobeWeight(brdf_mat);

		float weights[LOBE_COUNT];
		weights[LOBE_SPECULAR] = baseShare * pSpec;
		weights[LOBE_DIFFUSE] = baseShare * (1.0 - pSpec);
		weights[LOBE_COAT] = coatMass;

		// STILL exactly one draw, consumed once, unremapped. See the Global
		// Constraints: a second draw or a remap here shifts every subsequent
		// sample in the path -- statistically valid, bitwise different
		// everywhere, and invisible to every gate.
		int lobe = selectLobe(rng_1d(rng, RT_PRNG_LOBE), weights);
		if (lobe == LOBE_COAT) {
			brdfType = COAT_TYPE;
			ps.throughput /= weights[LOBE_COAT];
		} else if (lobe == LOBE_SPECULAR) {
			brdfType = SPECULAR_TYPE;
			ps.throughput /= weights[LOBE_SPECULAR];
		} else {
			brdfType = DIFFUSE_TYPE;
			ps.throughput /= weights[LOBE_DIFFUSE];
		}
```

Define `COAT_TYPE` beside `DIFFUSE_TYPE 1` / `SPECULAR_TYPE 2` in `brdf_inc.glsl:106-107`:

```glsl
#define COAT_TYPE 3
```

- [ ] **Step 4: Apply the attenuation and the tint to the base**

Immediately **after** the selection block, and only when the chosen lobe is a base lobe:

```glsl
		if (lobe != LOBE_COAT && brdf_mat.coatWeight > 0.00001f) {
			// closure_layering_weight(a, w) = w * saturate(1 - max(a/w))
			// (bsdf_util.h:440). The coat's albedo is coatWeight*w*estimate, so
			// the w cancels and the whole thing reduces to this one line.
			//
			// THIS IS A THROUGHPUT FACTOR, NOT A SELECTION PROBABILITY. It must
			// not be folded into weights[] above -- see the selection-vs-throughput
			// block at the top of brdf_inc.glsl's registry section.
			ps.throughput *= clamp(1.0 - coatMass, 0.0, 1.0);

			// Beer's law through the coat. Cycles applies this OUTSIDE the coat
			// lobe's own branch (svm/closure.h:155 vs :178), so it is a separate
			// step and must not be fused with the attenuation above.
			if (brdf_mat.coatTint != float3(1.0, 1.0, 1.0)) {
				float cosNT = sqrt(1.0 - (1.0 / (brdf_mat.coatIor * brdf_mat.coatIor))
						* (1.0 - cosNI * cosNI));
				float opticalDepth = 1.0 / max(cosNT, 0.00001);
				ps.throughput *= mix(float3(1.0, 1.0, 1.0),
						pow(brdf_mat.coatTint, float3(opticalDepth)), brdf_mat.coatWeight);
			}
		}
```

- [ ] **Step 5: Sample and evaluate the coat lobe**

Where `brdfType` is dispatched to a sampler, add the `COAT_TYPE` branch. The coat is an isotropic GGX with `alpha = coatRoughness²` and dielectric F0 from `coatIor` — reuse the existing isotropic specular path rather than writing a second one, passing a `BrdfData` whose `specularF0` is `float3(coat_f0)` and whose `alpha` is the coat's:

```glsl
	} else if (brdfType == COAT_TYPE) {
		// Cycles forces the coat isotropic: alpha_x = alpha_y = sqr(coat_roughness)
		// (svm/closure.h:165). NOT the raster's mix(0.001, 0.1, r) remap -- see
		// the E2d spec section 3.2 for why the raster and the path tracer
		// deliberately disagree here.
		MaterialProperties coatMat = brdf_mat;
		coatMat.roughness = brdf_mat.coatRoughness;
		coatMat.metalness = 0.0f;
		coatMat.transmissivness = 0.0f;
		float q = (brdf_mat.coatIor - 1.0f) / (brdf_mat.coatIor + 1.0f);
		coatMat.dielectricF0 = float3(q * q);
		coatMat.baseColor = float3(0.0f, 0.0f, 0.0f); // No diffuse under a coat lobe.
		BrdfData coatData = prepareBRDFData(N, V, V, coatMat);
		// anisotropy is not carried: the coat has none to match.
		coatData.anisoActive = false;
		next_dir = sampleSpecular(V, N, coatData, u, brdf_weight);
	}
```

- [ ] **Step 6: Extend `combinedPdf` to three lobes**

In `brdf_inc.glsl`'s `combinedPdf`, replace the two-entry arrays with three, preserving specular-first summation order:

```glsl
	float cosNI = dot(N, V);
	float coatMass = coatLobeWeight(material, cosNI);
	float baseShare = 1.0f - coatMass;

	float weights[LOBE_COUNT];
	weights[LOBE_SPECULAR] = baseShare * pSpec;
	weights[LOBE_DIFFUSE] = baseShare * (1.0f - pSpec);
	weights[LOBE_COAT] = coatMass;

	float pdfs[LOBE_COUNT];
	pdfs[LOBE_SPECULAR] = specularContribution * transmitScale;
	pdfs[LOBE_DIFFUSE] = pdfDiffuse;
	pdfs[LOBE_COAT] = coatPdfValue;

	return combineLobePdf(weights, pdfs);
```

where `coatPdfValue` is the isotropic VNDF reflection pdf at the coat's alpha, computed the same way `specularContribution` is but with `coatRoughness²`. **The split here must stay identical to the sampler's in Step 3** — that is the invariant `combinedPdf`'s existing comment already names, now with three terms instead of two.

- [ ] **Step 7: Full build and run everything**

```bash
python -m SCons platform=windows target=editor tests=yes -j8
bin/godot.windows.editor.x86_64.console.exe --headless --test
bin/godot.windows.editor.x86_64.console.exe --path pipeline_references res://tests/pt_energy_gate_scene.tscn
bin/godot.windows.editor.x86_64.console.exe --path pipeline_references res://tests/pt_anisotropy_gate_scene.tscn
bin/godot.windows.editor.x86_64.console.exe --path pipeline_references res://tests/pt_transmission_gate_scene.tscn
```

Expected: doctest 1534/0/3, and **all three gates still PASS** — every existing gate scene has `clearcoat = 0`, so `coatMass` is 0, `baseShare` is 1, and the arithmetic must reduce to E2c's exactly.

**If any existing gate moves, stop.** At `clearcoat = 0` this task is a no-op by construction; a moved number means the reduction is not exact. Report it rather than re-baselining.

- [ ] **Step 8: Check the two properties E2c could not observe**

E2c's three-lobe proof was inert by construction. This is the first real N=3, so confirm by reading the code and report in writing:

1. **Summation order.** At N=2 order was unfalsifiable (IEEE addition is commutative bit-exactly). At N=3 it is *associativity*. Confirm `combineLobePdf` still accumulates specular, then diffuse, then coat, in registry order.
2. **The trailing fallback.** `selectLobe` falls through to `return LOBE_COUNT - 1`, which now returns **coat**. On an uncoated material `weights[LOBE_COAT]` is 0, and the sampler would divide throughput by it.

   **That path is unreachable, and Task 2's doctest is what pins why** — do **not** add a guard for it. With `coatMass == 0`, `baseShare` is exactly `1.0f`, so the base weights are `fl(pSpec)` and `fl(1.0f - pSpec)`, which sum to exactly `1.0f` for every float32 `pSpec` (Sterbenz above 0.5; a half-ulp that rounds back below it — verified over 10M samples). `rng_1d` bottoms out in `sb_uint_to_float_excl` (`sobol_burley_inc.glsl:118`), so `u` lies in `[0,1)` strictly and `u < 1.0f` always holds. The residue window is empty.

   Confirm both halves by reading the code — the exact sum, and the exclusive upper bound on `u`. If either stops holding, Task 2's doctest fails first and names the reason. Report what you found; do not assume this note is still true.

- [ ] **Step 9: Commit**

```bash
git add servers/rendering/renderer_rd/shaders/raytracing/brdf_inc.glsl servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl
git commit -m "feat(pt): E2d the coat lobe and its layering attenuation"
```

---

---

## Task 5b: Close the coat's energy gap — real multi-scatter compensation and exact dielectric Fresnel

**Files:**
- Create: `servers/rendering/renderer_rd/storage_rd/ggx_energy_tables.h`
- Modify: `tests/servers/rendering/test_pt_coat_albedo.cpp`
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/brdf_inc.glsl`
- Modify: `servers/rendering/renderer_rd/forward_clustered/render_raytracing.cpp`
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl`

**Interfaces:**
- Consumes: Task 4's `coatLutRead1D` / `coatLutRead2D` (already written and reviewed), `coatMaterial()`, `evalCoat`, `coatAlbedoEstimate`.
- Produces: `GGX_E_TABLE[1024]`, `GGX_EAVG_TABLE[32]`; GLSL `float coatEnergyScale(float coatRoughness, float cosNI, float ior)`.

**Why this task exists.** Task 5's review found the coat withdraws more energy than its lobe returns. The withdrawal, `saturate(1 − coat_weight · estimate)`, uses Cycles' **average Fresnel** as an albedo. That is only legitimate because Cycles' coat is fully energy-compensated — `bsdf_microfacet_setup_fresnel_dielectric` calls `microfacet_ggx_preserve_energy` (`bsdf_microfacet.h:1024`). This engine's `evalMultiScatterApproximation` is `1 + F0·Ems`, which at the coat's `F0 = 0.04` is **≈1.002** and recovers almost none of the GGX single-scattering deficit. Measured payout/withdrawal at the default `clearcoat_roughness = 0.5`: **0.911** at normal incidence, **0.736** at `cosNI = 0.3`. A coated white sphere darkens toward its silhouette with no physical source.

The design spec §3.5 asserted the two terms were equivalent. **They are not**, and that erratum belongs in the spec as part of this task.

**Scope discipline.** This fixes the **coat only**. Gap #17 — the *base* specular's multi-scatter over-compensation — stays untouched and out of scope, and is now cleanly separated from this.

### The math, read from Cycles

`microfacet_ggx_preserve_energy` (`intern/cycles/kernel/closure/bsdf_microfacet.h:432-485`):

```
mu    = dot(wi, N)
rough = sqrt(sqrt(alpha_x * alpha_y))
E     = lookup_table_read_2D(ggx_E, rough, mu, 32, 32)
E_avg = lookup_table_read(ggx_Eavg, rough, 32)

missing_factor = (1 - E) / E
energy_scale   = 1 + missing_factor            // == 1/E

if Fss != 1:
    Fms       = Fss * E_avg / (1 - Fss * (1 - E_avg))
    darkening = (1 + Fms * missing_factor) / energy_scale
    weight       *= darkening
    sample_weight *= average(darkening)
```

The BSDF value is multiplied by `energy_scale`, and the weight by `darkening`. Their product is the whole story:

```
energy_scale * darkening = (1/E) * (E + Fms*(1-E)) = 1 + Fms * (1 - E) / E
```

so the single multiplier the coat's BRDF needs is:

```
coatEnergyScale = 1 + Fms * (1 - E) / E,   Fms = Fss * E_avg / (1 - Fss * (1 - E_avg))
```

with `Fss = fresnel_dielectric_Fss(ior)` (`bsdf_util.h:131-137`), which for `eta >= 1` is `(eta - 1) / (4.08567 + 1.00071 * eta)`. At `ior = 1.5` that is `0.089487`.

**Derive this yourself from the Cycles source before implementing it** — if your algebra disagrees with the line above, trust your algebra and tell me.

### Exact dielectric Fresnel for the coat

The second half. `shadowedF90(F0) = min(1, F0 / 0.04)` (`brdf_inc.glsl:690-696`) caps the coat's grazing reflectance below 1 for every `clearcoat_ior < 1.5`. At ior 1.1 the coat's Fresnel can never exceed 5.67% at any angle, while the withdrawal table — built from *exact* dielectric Fresnel — reads 0.110 at grazing. `clearcoat_ior`'s inspector range is `"1,3,0.01"`, so this is an ordinary artist setting.

Cycles' coat uses `fresnel_type = DIELECTRIC`, i.e. exact `fresnel_dielectric_cos`, not Schlick. **Use this engine's exact dielectric Fresnel for the coat** — E1 landed that machinery; find it and use it. If it cannot be called from the coat's eval and sample paths, fall back to Schlick with `F90 = 1.0` for the coat and say why in your report.

**The sampler and the evaluator must change together.** They currently agree with each other, so this is a pure energy loss and not an MIS desync. Changing one without the other would *create* a desync — a strictly worse bug.

- [ ] **Step 1: Extract the two tables**

```bash
python - <<'PYEOF'
import io, re
src = r"C:\Users\aiadmin\Desktop\blender_build\blender\intern\cycles\scene\shader.tables"
s = io.open(src, encoding="utf-8", errors="replace").read()
out = ['/**************************************************************************/',
       '/*  ggx_energy_tables.h                                                   */',
       '/**************************************************************************/',
       '', '#pragma once', '',
       '// GGX directional albedo E(rough, mu) and its average E_avg(rough), used for',
       '// multiple-scattering energy compensation.',
       '//',
       '// COPIED VERBATIM from Blender Cycles, intern/cycles/scene/shader.tables:',
       '//   table_ggx_E[1024]  (32x32, indexed [x = rough][y = mu])',
       '//   table_ggx_Eavg[32] (indexed [rough])',
       '// Consumed by coatEnergyScale; see microfacet_ggx_preserve_energy',
       '// (intern/cycles/kernel/closure/bsdf_microfacet.h:432-485).',
       '//',
       '// COAT ONLY. The base specular lobe still uses evalMultiScatterApproximation',
       '// and roadmap Gap #17 still applies to it -- deliberately out of scope here.',
       '']
for name, count in (("ggx_E", 1024), ("ggx_Eavg", 32)):
    m = re.search(r"static const float table_%s\[%d\] = \{(.*?)\};" % (name, count), s, re.S)
    assert m, name
    vals = re.findall(r"(-?[0-9.]+(?:e[-+]?\d+)?)f", m.group(1))
    assert len(vals) == count, (name, len(vals))
    out.append('inline constexpr float GGX_%s_TABLE[%d] = {' % (name.upper().replace("GGX_",""), count))
    for i in range(0, count, 8):
        out.append('\t' + ' '.join(f'{v}f,' for v in vals[i:i+8]))
    out.append('};')
    out.append('')
    print(name, len(vals), "first", vals[0], "last", vals[-1])
out.insert(len(out), 'inline constexpr int GGX_E_DIM = 32;')
io.open("servers/rendering/renderer_rd/storage_rd/ggx_energy_tables.h", "w",
        encoding="utf-8", newline="\n").write("\n".join(out) + "\n")
print("wrote header")
PYEOF
```

The generated names are `GGX_E_TABLE[1024]`, `GGX_EAVG_TABLE[32]`, `GGX_E_DIM = 32`. If the script's name-mangling produces something different, fix the script rather than renaming by hand, and report what you changed.

- [ ] **Step 2: CPU mirror and doctest**

Add to `tests/servers/rendering/test_pt_coat_albedo.cpp`, inside the existing namespace. `coat_lut_read_1d` and `coat_lut_read_2d` already exist there — reuse them, do not write second copies.

```cpp
static float coat_fss_from_ior(float p_ior) {
	// fresnel_dielectric_Fss, bsdf_util.h:131-137. eta >= 1 branch only:
	// coat_ior is clamped to >= 1 on upload, so the eta < 1 polynomial is
	// unreachable here. Do not port it "for completeness" -- an unreachable
	// branch is an untested branch.
	return (p_ior - 1.0f) / (4.08567f + 1.00071f * p_ior);
}

static float coat_energy_scale(float p_coat_roughness, float p_cos_ni, float p_ior) {
	const float alpha = p_coat_roughness * p_coat_roughness;
	const float rough = Math::sqrt(Math::sqrt(alpha * alpha));
	const float E = coat_lut_read_2d(GGX_E_TABLE, rough, p_cos_ni, GGX_E_DIM, GGX_E_DIM);
	const float e_avg = coat_lut_read_1d(GGX_EAVG_TABLE, rough, GGX_E_DIM);
	const float fss = coat_fss_from_ior(p_ior);
	const float fms = fss * e_avg / (1.0f - fss * (1.0f - e_avg));
	return 1.0f + fms * (1.0f - E) / E;
}

TEST_CASE("[PathTracer][CoatAlbedo] Fss matches Cycles' dielectric fit") {
	// bsdf_util.h:136, (eta-1)/(4.08567 + 1.00071*eta).
	CHECK(coat_fss_from_ior(1.5f) == doctest::Approx(0.089487f).epsilon(1e-4));
	CHECK(coat_fss_from_ior(1.0f) == doctest::Approx(0.0f).epsilon(1e-6));
	CHECK(coat_fss_from_ior(1.5f) < coat_fss_from_ior(2.0f));
}

TEST_CASE("[PathTracer][CoatAlbedo] energy compensation exceeds 1 and grows with roughness") {
	// The whole point: a rough lobe loses more single-scattering energy, so it
	// needs a larger multiplier back. A stub returning 1.0 fails this.
	const float smooth = coat_energy_scale(0.05f, 0.8f, 1.5f);
	const float rough = coat_energy_scale(0.80f, 0.8f, 1.5f);
	CHECK(smooth >= 1.0f);
	CHECK(rough > smooth);
	// Pin the counterfactual: the old evalMultiScatterApproximation at the
	// coat's F0 = 0.04 is ~1.002 and CANNOT reach this.
	CHECK(rough > 1.01f);
}

TEST_CASE("[PathTracer][CoatAlbedo] compensation closes the withdrawal/payout gap") {
	// The defect this task exists to fix, stated as a test. The coat withdraws
	// coat_albedo_estimate from the base; its lobe must return the same energy
	// once compensated. Uncompensated, this ratio was measured at 0.911 at
	// normal incidence and 0.736 at cos_ni = 0.3 for roughness 0.5.
	//
	// This is a NECESSARY condition, not the full proof -- the real payout also
	// carries the Fresnel and the VNDF weight, which only the GPU gate can
	// measure. It fails loudly if the compensation is omitted or inverted.
	for (float rough : { 0.2f, 0.5f, 0.8f }) {
		for (float mu : { 1.0f, 0.7f, 0.3f }) {
			CAPTURE(rough);
			CAPTURE(mu);
			CHECK(coat_energy_scale(rough, mu, 1.5f) >= 1.0f);
		}
	}
	// Directionally: the compensation must be larger exactly where the measured
	// gap was worse -- rougher, and further from normal incidence.
	CHECK(coat_energy_scale(0.5f, 0.3f, 1.5f) > coat_energy_scale(0.5f, 1.0f, 1.5f));
}
```

- [ ] **Step 3: Run the new tests and prove they can fail**

```bash
python -m SCons platform=windows target=editor tests=yes -j8
bin/godot.windows.editor.x86_64.console.exe --headless --test --test-case="*CoatAlbedo*"
```

Then temporarily make `coat_energy_scale` `return 1.0f;`, rebuild, and confirm the second and third cases FAIL. Record the values. Revert, rebuild, confirm green. Do not skip this.

- [ ] **Step 4: Upload the tables and write the GLSL**

Append both tables to the existing coat SSBO rather than adding new bindings — this mirrors Cycles, which keeps one `lookup_table` and indexes it by offset. Define the offsets as named constants shared by C++ and GLSL, and state in your report how you guaranteed they agree.

Write `coatEnergyScale(coatRoughness, cosNI, ior)` in `brdf_inc.glsl`, transcribing the CPU mirror. Reuse Task 4's `coatLutRead1D` / `coatLutRead2D`.

- [ ] **Step 5: Apply it, and switch the coat to exact dielectric Fresnel**

Multiply the coat's BRDF by `coatEnergyScale` in **both** `evalCoat` and the `COAT_TYPE` sampler arm, replacing the `coatMultiScatter` / `evalMultiScatterApproximation` use on the coat path only. Switch the coat's Fresnel from `shadowedF90` to exact dielectric Fresnel in both places.

**Both changes must land in the eval and the sampler together.** They agree today; changing one alone creates an MIS desync, which is worse than the energy loss being fixed.

- [ ] **Step 6: Fix vis mode 32's false reading**

`raytracing_closest_hit_common_inc.glsl:591` emits `lobeWeight(dbg_mat)`, but the sampler's actual `weights[LOBE_SPECULAR]` is now `baseShare * pSpec`. They coincide only when `baseShare == 1`. Scale it by `baseShare` so it reports what its name says. **This must land before Task 6 captures any baseline through that probe.**

- [ ] **Step 7: Verify**

```bash
python -m SCons platform=windows target=editor tests=yes -j8
bin/godot.windows.editor.x86_64.console.exe --headless --test
bin/godot.windows.editor.x86_64.console.exe --path pipeline_references res://tests/pt_energy_gate_scene.tscn
bin/godot.windows.editor.x86_64.console.exe --path pipeline_references res://tests/pt_anisotropy_gate_scene.tscn
bin/godot.windows.editor.x86_64.console.exe --path pipeline_references res://tests/pt_transmission_gate_scene.tscn
```

All three gates must PASS **unchanged** — every gate scene has `clearcoat = 0`, so this task is a no-op there. `pt_transmission_gate`'s probe 9 reads through vis mode 32; if Step 6 moved it, that is expected and must be re-derived from material facts, not copied from the shader.

- [ ] **Step 8: Record the spec erratum**

Add to `docs/superpowers/specs/2026-08-27-clearcoat-coat-layer-design.md` §3.5 that its claim of equivalence between `evalMultiScatterApproximation` and `microfacet_ggx_preserve_energy` was **wrong**, with the measured 0.911 / 0.736 figures and what replaced it. Do not quietly amend the section — mark it as an erratum, the way E1's spec §3.2 was.

- [ ] **Step 9: Commit**

```bash
git add servers/rendering/renderer_rd/storage_rd/ggx_energy_tables.h tests/servers/rendering/test_pt_coat_albedo.cpp servers/rendering/renderer_rd/shaders/raytracing/brdf_inc.glsl servers/rendering/renderer_rd/forward_clustered/render_raytracing.cpp servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl docs/superpowers/specs/2026-08-27-clearcoat-coat-layer-design.md
git commit -m "fix(pt): E2d real multi-scatter compensation and exact Fresnel for the coat"
```

## Task 6: The gate, and proving it can fail

**Files:**
- Create: `pipeline_references/tests/pt_coat_gate.gd`, `pipeline_references/tests/pt_coat_gate_scene.tscn`

**Interfaces:**
- Consumes: vis modes 36, 37, 38 (Tasks 3-4); the coat lobe (Task 5).
- Produces: a gate script exiting 0 on pass, 1 on fail.

**Model it on `pipeline_references/tests/pt_anisotropy_gate.gd`.** Read that file first — it carries the measured-baseline pattern this gate must follow, and the sRGB pre-encode this gate must not "simplify" away.

**The verdict rule, fixed before measuring.** Baselines are recorded as measured-intact constants with a ±0.5pp band. An absolute comparison against 1.0 would exit non-zero regardless, because Gap #17 already lifts these surfaces above it — a gate that cannot *newly* fail is not an instrument. That is E2b's Important #1, and repeating it here would waste the phase.

- [ ] **Step 1: Build the scene**

Copy `pt_anisotropy_gate_scene.tscn` and repoint its script. In `_build_scene`, note these three, each of which has silently broken a sibling gate:

```gdscript
sky.process_mode = Sky.PROCESS_MODE_QUALITY   # REALTIME force-clamps to 256 (sky.cpp:593-595)
env.background_mode = Environment.BG_SKY      # BG_COLOR renders pure black to the PT
mat.albedo_color = Color(ALBEDO, ALBEDO, ALBEDO).linear_to_srgb()  # :1542 decodes it back
mat.clearcoat_tint = Color(1, 1, 1).linear_to_srgb()               # :1766-style decode; DO NOT simplify away
```

- [ ] **Step 2: Probe 1 — arrival**

Render vis modes 36 and 37 and assert the authored values arrive:

```gdscript
# clearcoat 0.8, clearcoat_roughness 0.25, clearcoat_ior 1.5 -> b reads 0.5.
_check("coat arrival r", px36.r, 0.8, 1e-3)
_check("coat arrival g", px36.g, 0.25, 1e-3)
_check("coat arrival b (ior-1)", px36.b, 0.5, 1e-3)
```

- [ ] **Step 3: Probe 2 — the albedo estimate matches the CPU mirror**

Render vis mode 38. Its g channel is the estimate at normal incidence and its b channel at grazing. Assert against values computed from Task 1's mirror at the same inputs — **compute them by running the doctest mirror, not by copying a number out of the shader**, or the check is comparing the implementation to itself:

```gdscript
# From test_pt_coat_albedo.cpp at coatRoughness 0.25, ior 1.5.
const P2_NORMAL_INCIDENCE := 0.04    # approaches F0
_check("estimate at normal incidence", px38.g, P2_NORMAL_INCIDENCE, 0.02)
_check_gt("estimate at grazing", px38.b, 0.5)
_check_gt("grazing exceeds normal", px38.b, px38.g)
```

- [ ] **Step 4: Probe 3 — the white furnace, which is the real instrument**

A white furnace with a coated white diffuse base under a uniform sky. **Coat plus attenuated base must not exceed 1.** This is the assertion an additive coat fails, so it is the probe that distinguishes a layer from a lobe.

Sweep `clearcoat` over `{0.0, 0.25, 0.5, 0.75, 1.0}` at `clearcoat_roughness = 0.3`. Record each measured mean as a named baseline constant with a ±0.5pp band. Report the absolute-vs-1.0 figure as an **unasserted diagnostic**, labelled as Gap #17's known pedestal.

The shape that matters: **the sweep must be flat.** At `clearcoat = 0` and `clearcoat = 1` the furnace mean should agree within the band, because energy the coat takes is energy the base loses. A mean that climbs with `clearcoat` is an additive coat.

- [ ] **Step 5: Probe 4 — three-lobe pdf self-normalization**

Extend E2b's instrument to three lobes: draw from the real sampler, accumulate `1/combinedPdf(L)`, and compare the mean against the domain measure `2π = 6.283185`, tolerance 3%. A pdf wrong by factor `k` reads exactly `1/k`.

Run it at `clearcoat` ∈ `{0.0, 0.5, 1.0}`. **The `clearcoat = 0` case must match E2b's existing readings**, since the coat contributes nothing there.

- [ ] **Step 6: PROVE THE GATE CAN FAIL**

Do not skip this and do not report the gate as working without it.

Temporarily revert the attenuation in `raytracing_closest_hit_common_inc.glsl` Step 4 — make the coat additive by deleting the `ps.throughput *= clamp(1.0 - coatMass, 0.0, 1.0);` line. Rebuild. Run the gate.

**Expected: probe 3's sweep is no longer flat and the gate exits 1.** Record the observed numbers at `clearcoat = 0` and `clearcoat = 1` both with and without the line.

Then restore the line, rebuild, and confirm the gate returns to its baselines.

If the gate passes with the line deleted, **the gate is not an instrument** — fix the gate before continuing, and say so plainly rather than proceeding.

- [ ] **Step 7: Commit**

```bash
git add pipeline_references/tests/pt_coat_gate.gd pipeline_references/tests/pt_coat_gate_scene.tscn
git commit -m "test(pt): E2d coat energy-conservation gate, proven by breaking it"
```

---

## Task 7: Cycles comparison and closeout

**Files:**
- Modify: `PATH_TRACER_QUALITY_ROADMAP.md`

**Interfaces:**
- Consumes: everything above.
- Produces: the closeout record.

- [ ] **Step 1: Build the Cycles comparison scene**

A car-paint sphere — E2's own stated acceptance target for this feature (roadmap §4, "car paint and velvet"). Metallic base, `clearcoat = 1.0`, `clearcoat_roughness = 0.1`, default `clearcoat_ior = 1.5`, under a uniform environment.

**Author every colour with `.linear_to_srgb()`** — `albedo_color` *and* `clearcoat_tint`. Cycles' sockets are linear; this engine decodes on upload. This trap has already been hit twice in this phase family, one layer apart, and once inverted an entire verdict (roadmap §7.7). Compare each renderer against the *same authored linear value*, not field-for-field against each other.

- [ ] **Step 2: Measure, twice**

Report both figures:

- **Raw** percentage difference against Cycles.
- **Adjusted**, with Gap #17's multi-scatter pedestal neutralised by forcing `ms = 1.0` at all three call sites (`brdf_inc.glsl:1192`, `:1348`, `raytracing_closest_hit_common_inc.glsl:1270`), the same way E2b's Task 4 isolated it.

E2b's precedent: +6.52% raw collapsing to +0.67% adjusted. Do not report only the flattering one, and do not tune anything to close the gap.

- [ ] **Step 3: Write §7.10**

Add `### 7.10 E2d - clearcoat / coat layer` after §7.9. Record:

- The coat as a **layer, not a lobe** — the attenuation is what makes it Blender's coat.
- **The raster divergence, loudly** (spec §3.2): `alpha = r²` here versus `mix(0.001, 0.1, r)` in `scene_forward_lights_inc.glsl:212`, plus the raster being additive. The same authored material looks different in the viewport and the path tracer. A reader comparing screenshots will otherwise file it as a bug.
- The LUT copied verbatim from `shader.tables`, and **why it is an SSBO with hand-written trilinear** rather than a filtered 3D texture.
- Task 5 Step 8's findings on summation order and the trailing-lobe fallback — **the first real N=3**, since E2c's proof was inert by construction (§7.9).
- Task 6 Step 6's break-the-guard result, with numbers.
- The Cycles figures, raw and adjusted, with Gap #17 named.
- **`coat_normal` as the one piece of Blender coat parity E2d does not deliver**, and why it is entangled with sheen (`closure.h:127-129`).

Mark clearcoat complete in the phase table; record sheen (E2e) and `coat_normal` as remaining.

- [ ] **Step 4: Commit**

```bash
git add PATH_TRACER_QUALITY_ROADMAP.md
git commit -m "docs(pt): E2d closeout - clearcoat as a Cycles coat layer"
```

---

## Self-review notes

**Spec coverage.** §3.1 throughput/selection split → Task 2, Task 5 Steps 3-4. §3.2 `alpha = r²` and the raster divergence → Global Constraints, Task 5 Step 5, Task 7 Step 3. §3.3 specular at index 0 → Global Constraints, Task 5 Step 2. §3.4 parameters → Task 3; `coat_normal` deferral → Task 7 Step 3. §3.5 Gap #17 → Task 7 Step 2. §4.1 the math → Task 5 Steps 4-6. §4.2 the LUT and its indexing → Tasks 1 and 4. §4.3 what does not change → Task 5 Step 7's "all three gates still PASS". §5 verification layers → Task 1 (doctest), Task 6 (furnace + pdf), Task 7 (Cycles). §6 the first real N=3 → Task 5 Step 8. §7 acceptance 1-2 → Task 6 Steps 4 and 6; 3 → Task 1; 4 → Task 7 Step 2; 5 → every task's verify step; 6 → Task 3 Step 6.

**Type consistency.** `coatAlbedoEstimate(coatRoughness, cosNI, ior)` is defined in Task 4 and called with that argument order in Tasks 4, 5 and 6. `coatLobeWeight(material, cosNI)` is defined in Task 5 Step 2 and used in Steps 3 and 6. `LOBE_COAT`/`LOBE_COUNT`/`COAT_TYPE` are introduced in Task 5 Step 2-3 and used consistently after. The CPU mirrors in Task 1 use snake_case per `test_pt_lobe_registry.cpp`'s house style; the GLSL uses camelCase per `brdf_inc.glsl`'s.

**Known risk this plan cannot remove.** The GLSL `coatLutRead3D` has no automated test — doctest cannot execute GLSL, and Task 1's cases only guard the CPU mirror. Task 4 Step 4's vis mode 38 and Task 6 Step 3 are the mitigation, and they are weaker than a unit test: they compare three sampled points, not the whole domain. A transcription slip in the GLSL that happens to agree at those three points would survive. This is the same structural limit §7.9 recorded for lobe order, and the reviewer should be told to read the two implementations side by side rather than trusting the gate.

**One thing Task 5 Step 6 leaves to the implementer.** `coatPdfValue` is described but not written out, because the exact expression depends on which of `brdf_inc.glsl`'s existing VNDF pdf helpers is in scope at that point — the file has both a raw and a `G2`-divided convention, and E2b's Critical finding was a snippet that used the wrong one. The implementer must read `specularContribution`'s construction directly above and mirror its convention, rather than assuming. Flag this to them explicitly in the dispatch.
