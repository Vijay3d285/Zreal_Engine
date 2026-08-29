# Sheen (Zeltner LTC) and the N-Layer Stack — E2e Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Cycles' sheen as the outermost layer, and generalise E2d's single-layer attenuation into an N-layer stack — closing the Principled BSDF's layering structure.

**Architecture:** Sheen is a Zeltner LTC lobe appended at registry index 3, driven by three 32×32 tables copied verbatim from Cycles. Its `pdf == eval` exactly, so the sample weight is 1. E2d's single-site `coatLayeringTransmittance` becomes one entry in a stack walk where each layer's transmittance multiplies every lobe at a higher index.

**Tech Stack:** GLSL (Vulkan RD raytracing pipeline), C++ (Godot 4.7 fork), doctest, GDScript GPU gates.

## Global Constraints

Copied from `docs/superpowers/specs/2026-08-28-sheen-zeltner-ltc-design.md`. Every task's requirements implicitly include this section.

- **PHASE INVARIANT: at `sheen_color == 0`, every E2d measurement reads unchanged** — not within tolerance, *unchanged*. Sheen contributes nothing there, so the stack must reduce to E2d's arithmetic exactly. E2d's coat is proven and gated (36-config furnace flat to 1.3e-4; +0.381% raw / −0.098% adjusted vs Blender) and this phase refactors it.
- **Registry order is contract.** Specular 0, diffuse 1, coat 2, sheen **3**. A reordered registry inverts lobe choices while leaving the image statistically identical — no gate can see it.
- **Exactly one `rng_1d(rng, RT_PRNG_LOBE)` draw**, consumed once, unremapped.
- **The sheen LUT axes are `(cosNI, roughness)`** — transposed relative to the coat's `(rough, mu)` (`bsdf_microfacet.h:565`). Both read the same SSBO through the same helper. Swapping them compiles and returns values in range.
- **The withdrawal is a max-channel reduction**: `saturate(1 − max_channel(sheen_color · ltc_albedo))`, from `closure_layering_weight`'s `reduce_max` (`bsdf_util.h:440`). Not luminance, not per-channel. E2d's scalar coat albedo made this invisible.
- **The invalid-LTC skip:** `|transformA| < 1e-5` **or** `ltc_albedo < 1e-5` → sheen's selection weight is exactly 0 (`bsdf_sheen.h:44-49`). It depends on the table's output, so it cannot be hoisted above the lookup.
- **Sheen's sample rejects against the GEOMETRIC normal**, not the shading normal (`bsdf_sheen.h:96`).
- **`sheen_roughness` is clamped to `[1e-3, 1.0]`** (`bsdf_sheen.h:33`); the cutoff on `sheen_color` uses its **max channel**, matching the reduction above.
- **No new material field.** Phase D landed `sheen_color`/`sheen_roughness` end to end; `brdf_inc.glsl` mentions sheen zero times.
- **sRGB:** every colour factor is decoded on upload — `albedo_color` (`render_raytracing.cpp:1585`), `sheen_color` (`:1815`), `clearcoat_tint` (`:1855`). Comparison materials author with `.linear_to_srgb()`.
- **The near-delta specular guard (`RT_MIS_DELTA_ROUGHNESS`) and `combinedPdf`'s `VplusL` check survive verbatim.**
- **NEVER touch, stage, revert, checkout over, or stash these six files** — the user's uncommitted work: `pipeline_references/compositor_effect.gd`, `image_glb_creation.gd`, `render.gd`, `structure.gd`, `video_glb_creation.gd`, `custom_shape.gd`. `git add` with **explicit paths only** — never `-A`, never `.`.
- **Build:** `python -m SCons platform=windows target=editor tests=yes -j8` — bare `scons` is **NOT** on PATH. Foreground, long timeout (600000 ms); re-issue if you hit the ceiling, SCons resumes. Full build after any `.glsl` edit.
- **Test:** `bin/godot.windows.editor.x86_64.console.exe --headless --test`. A bare positional after `--test` is silently ignored.
- **GPU gates need a real Vulkan device — no `--headless`:** `--path pipeline_references res://tests/<name>_scene.tscn`. Five exist: `pt_coat_gate`, `pt_energy_gate`, `pt_anisotropy_gate`, `pt_transmission_gate`, plus this phase's new one. `pt_transmission_gate` probe 6 is a known bimodal flake (~4.069 or ~5.042), documented in roadmap §7.9.
- **Baseline entering this plan:** doctest **1542 passed / 0 failed / 3 skipped**.
- **Commit incrementally.** Four agents on the E2d plan hit session limits mid-task; one lost work the controller had to recover from the tree.

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `servers/rendering/renderer_rd/storage_rd/sheen_ltc_table.h` | **Create.** The 3072-float Zeltner table copied from Cycles, plus its dimension. Data only. | 1 |
| `tests/servers/rendering/test_pt_sheen.cpp` | **Create.** CPU mirrors of the LTC eval/sample/frame; the axis-order, `pdf == eval`, degenerate-frame and invalid-LTC doctests. | 1 |
| `servers/rendering/renderer_rd/shaders/raytracing/brdf_inc.glsl` | The stack walk; the sheen lobe; registry widening. | 2, 3, 4 |
| `servers/rendering/renderer_rd/forward_clustered/render_raytracing.cpp` / `.h` | Append the sheen table to the binding-38 SSBO. | 3 |
| `servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl` | The sampler's stack walk; sheen's arm; a parity vis mode. | 2, 3, 4 |
| `servers/rendering/renderer_rd/shaders/raytracing/raytracing_lights_inc.glsl`, `raytracing_emissive_inc.glsl` | The fourth out-parameter at the NEE sites. | 4 |
| `pipeline_references/tests/pt_sheen_gate.gd` + `_scene.tscn` | **Create.** Furnace, parity, four-lobe pdf, break-the-guard. | 5 |
| `PATH_TRACER_QUALITY_ROADMAP.md` | §7.11 closeout. | 6 |

---

## Task 1: The sheen table, its CPU mirror, and the axis order

**Files:**
- Create: `servers/rendering/renderer_rd/storage_rd/sheen_ltc_table.h`
- Create: `tests/servers/rendering/test_pt_sheen.cpp`

**Interfaces:**
- Consumes: nothing.
- Produces: `SHEEN_LTC_TABLE[3072]`, `SHEEN_LTC_DIM = 32` (3 blocks x 32 x 32 = 3072; `bsdf_sheen.h:38-42` passes `32, 32`). CPU mirrors `sheen_ltc_read(kind, cos_ni, roughness)`, `sheen_make_frame(N, V, T, B)`, `sheen_eval(...)`, `sheen_sample(...)`, all `static` inside `namespace TestPTSheen`.

**Why first.** Everything rests on three table reads whose axes are transposed relative to the coat's. A probe on the diagonal cannot tell them apart, so the tests must read where the two orders genuinely differ.

- [ ] **Step 1: Extract the table and confirm its shape**

The spec says three 32×32 blocks in 3072 floats. **3 × 32 × 32 = 3072 only if the blocks are 32×32; but 3 × 1024 = 3072 also equals 3 × 32 × 32.** Confirm by reading `bsdf_sheen.h:38-42` — the reads pass `32, 32` — and by checking the literal count. Report what you found.

```bash
python - <<'PYEOF'
import io, re
src = r"C:\Users\aiadmin\Desktop\blender_build\blender\intern\cycles\scene\shader.tables"
s = io.open(src, encoding="utf-8", errors="replace").read()
m = re.search(r"static const float table_sheen_ltc\[3072\] = \{(.*?)\};", s, re.S)
assert m, "table_sheen_ltc not found"
vals = re.findall(r"(-?[0-9.]+(?:e[-+]?\d+)?)f", m.group(1))
assert len(vals) == 3072, len(vals)
out = ['/**************************************************************************/',
       '/*  sheen_ltc_table.h                                                     */',
       '/**************************************************************************/',
       '', '#pragma once', '',
       '// Zeltner sheen LTC coefficients, three 32x32 blocks in one flat array:',
       '//   [0    .. 1023] transformA',
       '//   [1024 .. 2047] transformB',
       '//   [2048 .. 3071] directional albedo',
       '//',
       '// Each block is indexed [x = cos_NI][y = roughness] -- NOTE THE ORDER.',
       '// The coat tables next door are indexed [x = roughness][y = mu]. The axes',
       '// are TRANSPOSED between the two, both are read through the same helper,',
       '// and swapping them compiles and returns values in range. See',
       '// intern/cycles/kernel/closure/bsdf_sheen.h:38-42 against',
       '// intern/cycles/kernel/closure/bsdf_microfacet.h:565.',
       '//',
       '// COPIED VERBATIM from Blender Cycles, intern/cycles/scene/shader.tables.',
       '// Do not regenerate these numbers -- matching Cycles is the whole point.',
       '',
       'inline constexpr int SHEEN_LTC_DIM = 32;',
       'inline constexpr int SHEEN_LTC_BLOCK = SHEEN_LTC_DIM * SHEEN_LTC_DIM;',
       'inline constexpr int SHEEN_LTC_A_OFFSET = 0;',
       'inline constexpr int SHEEN_LTC_B_OFFSET = SHEEN_LTC_BLOCK;',
       'inline constexpr int SHEEN_LTC_ALBEDO_OFFSET = 2 * SHEEN_LTC_BLOCK;',
       'inline constexpr float SHEEN_LTC_TABLE[3072] = {']
for i in range(0, 3072, 8):
    out.append('\t' + ' '.join(f'{v}f,' for v in vals[i:i+8]))
out.append('};')
io.open("servers/rendering/renderer_rd/storage_rd/sheen_ltc_table.h", "w",
        encoding="utf-8", newline="\n").write("\n".join(out) + "\n")
print("wrote 3072 values; first", vals[0], "last", vals[-1])
print("A[0]", vals[0], "B[0]", vals[1024], "albedo[0]", vals[2048])
PYEOF
```

- [ ] **Step 2: Write the failing test**

Create `tests/servers/rendering/test_pt_sheen.cpp`. Copy the Godot copyright header verbatim from `tests/servers/rendering/test_pt_coat_albedo.cpp`, then:

```cpp
#include "tests/test_macros.h"

TEST_FORCE_LINK(test_pt_sheen)

#include "core/math/math_funcs.h"
#include "core/math/vector3.h"
#include "servers/rendering/renderer_rd/storage_rd/sheen_ltc_table.h"

namespace TestPTSheen {

// CPU mirrors of Cycles' Zeltner sheen
// (intern/cycles/kernel/closure/bsdf_sheen.h:27-110) and its view-dependent
// frame (intern/cycles/kernel/sample/mapping.h:55-68).
//
// THE LUT AXES ARE (cos_NI, roughness). The coat tables in the same SSBO are
// (roughness, mu). Transposed. Both go through a 2D reader with the same
// signature, so a swap is a compile-clean, in-range, wrong-everywhere defect.

// Endpoint-aligned 2D read, identical in shape to the coat's
// (intern/cycles/kernel/util/lookup_table.h:32-46).
static float sheen_lut_read_2d(int p_base, float p_x, float p_y) {
	const int d = SHEEN_LTC_DIM;
	p_y = CLAMP(p_y, 0.0f, 1.0f) * float(d - 1);
	const int yi = MIN(int(p_y), d - 1);
	const int yn = MIN(yi + 1, d - 1);
	const float ty = p_y - float(yi);

	p_x = CLAMP(p_x, 0.0f, 1.0f) * float(d - 1);
	const int xi = MIN(int(p_x), d - 1);
	const int xn = MIN(xi + 1, d - 1);
	const float tx = p_x - float(xi);

	const float r0 = (1.0f - tx) * SHEEN_LTC_TABLE[p_base + d * yi + xi] +
			tx * SHEEN_LTC_TABLE[p_base + d * yi + xn];
	if (ty == 0.0f) {
		return r0;
	}
	const float r1 = (1.0f - tx) * SHEEN_LTC_TABLE[p_base + d * yn + xi] +
			tx * SHEEN_LTC_TABLE[p_base + d * yn + xn];
	return (1.0f - ty) * r0 + ty * r1;
}

struct SheenData {
	Vector3 T, B, N;
	float a = 0.0f, b = 0.0f, albedo = 0.0f;
	bool valid = false;
};

// mapping.h:55-68. The frame is VIEW-DEPENDENT -- nothing else in this BRDF is.
// The fallback fires when V is parallel to N, i.e. the centre of every sphere
// facing camera. Not an exotic corner.
static void sheen_make_frame(const Vector3 &p_n, const Vector3 &p_v, Vector3 &r_t, Vector3 &r_b) {
	Vector3 b = p_n.cross(p_v);
	const real_t len_sq = b.length_squared();
	if (len_sq < 0.99f) {
		// Cycles falls back to make_orthonormals, which ignores V entirely.
		const Vector3 axis = Math::abs(p_n.x) > Math::abs(p_n.z) ? Vector3(-p_n.y, p_n.x, 0.0f)
																 : Vector3(0.0f, -p_n.z, p_n.y);
		r_b = axis.normalized();
		r_t = r_b.cross(p_n);
		return;
	}
	r_b = b / Math::sqrt(len_sq);
	r_t = r_b.cross(p_n);
}

static SheenData sheen_setup(const Vector3 &p_n, const Vector3 &p_v, float p_roughness) {
	SheenData d;
	d.N = p_n;
	sheen_make_frame(p_n, p_v, d.T, d.B);
	const float rough = CLAMP(p_roughness, 1e-3f, 1.0f);
	const float cos_ni = p_n.dot(p_v);
	d.a = sheen_lut_read_2d(SHEEN_LTC_A_OFFSET, cos_ni, rough);
	d.b = sheen_lut_read_2d(SHEEN_LTC_B_OFFSET, cos_ni, rough);
	d.albedo = sheen_lut_read_2d(SHEEN_LTC_ALBEDO_OFFSET, cos_ni, rough);
	// bsdf_sheen.h:44-49 -- the closure is dropped, not merely dimmed.
	d.valid = !(Math::abs(d.a) < 1e-5f || d.albedo < 1e-5f);
	return d;
}

// bsdf_sheen.h:70-74. pdf and eval are THE SAME VALUE -- the LTC is perfectly
// importance-sampled, so the sample weight is exactly 1.
static float sheen_eval(const SheenData &p_d, const Vector3 &p_l) {
	const Vector3 lo(p_l.dot(p_d.T), p_l.dot(p_d.B), p_l.dot(p_d.N));
	const float len_sqr = (p_d.a * lo.x + p_d.b * lo.z) * (p_d.a * lo.x + p_d.b * lo.z) +
			(p_d.a * lo.y) * (p_d.a * lo.y) + lo.z * lo.z;
	const float q = p_d.a / len_sqr;
	return (1.0f / Math_PI) * MAX(lo.z, 0.0f) * q * q;
}

// bsdf_sheen.h:83-99. Returns the direction AND the pdf, because Cycles does
// (`*pdf = val; *eval = make_spectrum(val);` at :97-99) and because a sampler
// that returns only a direction cannot be checked against the evaluator.
static Vector3 sheen_sample(const SheenData &p_d, float p_u1, float p_u2, float &r_pdf) {
	const float r = Math::sqrt(p_u1);
	const float phi = Math_TAU * p_u2;
	const float dx = r * Math::cos(phi);
	const float dy = r * Math::sin(phi);
	const float dz = Math::sqrt(MAX(0.0f, 1.0f - (dx * dx + dy * dy)));
	Vector3 lo(dx - dz * p_d.b, dy, dz * p_d.a);
	lo.normalize();
	// The sampler's OWN pdf expression, from its own localO -- not a call into
	// sheen_eval. Keeping them separate is what makes the identity testable.
	const float len_sqr = (p_d.a * lo.x + p_d.b * lo.z) * (p_d.a * lo.x + p_d.b * lo.z) +
			(p_d.a * lo.y) * (p_d.a * lo.y) + lo.z * lo.z;
	const float q = p_d.a / len_sqr;
	r_pdf = (1.0f / Math_PI) * lo.z * q * q;
	return p_d.T * lo.x + p_d.B * lo.y + p_d.N * lo.z;
}

TEST_CASE("[PathTracer][Sheen] the table is the one Cycles ships") {
	// Guards a re-extraction silently pulling a different or truncated table.
	// Values read directly out of shader.tables at these indices.
	CHECK(SHEEN_LTC_DIM == 32);
	CHECK(SHEEN_LTC_A_OFFSET == 0);
	CHECK(SHEEN_LTC_B_OFFSET == 1024);
	CHECK(SHEEN_LTC_ALBEDO_OFFSET == 2048);
	// The albedo block must be a plausible albedo everywhere: in [0, 1].
	// A transposed or mis-offset block would put transformA values here, which
	// are not bounded by 1.
	for (int i = 0; i < 1024; i++) {
		CAPTURE(i);
		CHECK(SHEEN_LTC_TABLE[SHEEN_LTC_ALBEDO_OFFSET + i] >= 0.0f);
		CHECK(SHEEN_LTC_TABLE[SHEEN_LTC_ALBEDO_OFFSET + i] <= 1.0f);
	}
}

TEST_CASE("[PathTracer][Sheen] the LUT axes are (cos_NI, roughness), not the transpose") {
	// THE case this file exists for. Read at a point where the two orders give
	// different answers, and assert they differ -- a probe on the diagonal
	// (cos_ni == roughness) cannot tell them apart and would pass either way.
	const float cos_ni = 0.2f;
	const float rough = 0.8f;
	const float correct = sheen_lut_read_2d(SHEEN_LTC_A_OFFSET, cos_ni, rough);
	const float transposed = sheen_lut_read_2d(SHEEN_LTC_A_OFFSET, rough, cos_ni);
	CHECK(correct != transposed);
	// And pin the magnitude of the confusion, so this cannot pass on two values
	// that merely differ in the last bit.
	CHECK(Math::abs(correct - transposed) > 0.01f);

	// The diagonal is where the two agree. Recorded so nobody "simplifies" the
	// case above onto it.
	const float diag_a = sheen_lut_read_2d(SHEEN_LTC_A_OFFSET, 0.5f, 0.5f);
	const float diag_b = sheen_lut_read_2d(SHEEN_LTC_A_OFFSET, 0.5f, 0.5f);
	CHECK(diag_a == diag_b);
}

TEST_CASE("[PathTracer][Sheen] pdf equals eval, exactly") {
	// The LTC is perfectly importance-sampled. This is a free instrument: any
	// transcription slip that breaks the identity is caught with no GPU.
	// Asserted with == because they are literally the same expression in
	// Cycles (bsdf_sheen.h:73-74), not two computations that happen to agree.
	const Vector3 n(0.0f, 0.0f, 1.0f);
	const Vector3 v = Vector3(0.4f, 0.1f, 0.9f).normalized();
	const SheenData d = sheen_setup(n, v, 0.5f);
	REQUIRE(d.valid);

	for (int i = 1; i <= 8; i++) {
		for (int j = 1; j <= 8; j++) {
			const float u1 = float(i) / 9.0f;
			const float u2 = float(j) / 9.0f;
			CAPTURE(u1);
			CAPTURE(u2);
			float sample_pdf = 0.0f;
			const Vector3 l = sheen_sample(d, u1, u2, sample_pdf);
			const float eval_val = sheen_eval(d, l);

			// The real property: the SAMPLER's pdf, computed from its own
			// local-frame direction, equals the EVALUATOR's value for the same
			// world direction. Two independent code paths, one number.
			//
			// Approx, not ==, and the reason is specific: the sampler builds
			// localO directly, while the evaluator receives the world-space
			// direction and projects it back onto the frame. That round trip
			// costs a few ulp. The tolerance measures the round trip, it does
			// not hide a discrepancy -- 1e-5 is far tighter than any real
			// transcription error would be.
			CHECK(eval_val > 0.0f);
			CHECK(sample_pdf == doctest::Approx(eval_val).epsilon(1e-5));
		}
	}

	// Prove the case can fail: two different draws must give different pdfs,
	// so the assertion above is not trivially satisfied by a constant.
	float pdf_a = 0.0f;
	float pdf_b = 0.0f;
	const Vector3 la = sheen_sample(d, 0.2f, 0.3f, pdf_a);
	const Vector3 lb = sheen_sample(d, 0.8f, 0.7f, pdf_b);
	CHECK(la != lb);
	CHECK(Math::abs(pdf_a - pdf_b) > 1e-6f);
}

TEST_CASE("[PathTracer][Sheen] the view-dependent frame is orthonormal and V-aligned") {
	const Vector3 n(0.0f, 0.0f, 1.0f);
	const Vector3 v = Vector3(0.6f, 0.0f, 0.8f).normalized();
	Vector3 t, b;
	sheen_make_frame(n, v, t, b);
	CHECK(t.length() == doctest::Approx(1.0f).epsilon(1e-5));
	CHECK(b.length() == doctest::Approx(1.0f).epsilon(1e-5));
	CHECK(t.dot(b) == doctest::Approx(0.0f).epsilon(1e-5));
	CHECK(t.dot(n) == doctest::Approx(0.0f).epsilon(1e-5));
	CHECK(b.dot(n) == doctest::Approx(0.0f).epsilon(1e-5));
	// B is perpendicular to the view plane, so V has no B component. This is
	// what makes the frame view-dependent rather than arbitrary -- a frame that
	// ignored V would fail here.
	CHECK(Math::abs(v.dot(b)) < 1e-5f);
}

TEST_CASE("[PathTracer][Sheen] the degenerate frame fallback fires at normal incidence") {
	// V parallel to N is the centre of every sphere facing camera, not an
	// exotic corner. cross(N, V) is zero there, and the frame must still come
	// out orthonormal rather than NaN.
	const Vector3 n(0.0f, 0.0f, 1.0f);
	Vector3 t, b;
	sheen_make_frame(n, n, t, b);
	CHECK(t.length() == doctest::Approx(1.0f).epsilon(1e-5));
	CHECK(b.length() == doctest::Approx(1.0f).epsilon(1e-5));
	CHECK(t.dot(b) == doctest::Approx(0.0f).epsilon(1e-5));
	CHECK(t.dot(n) == doctest::Approx(0.0f).epsilon(1e-5));
	CHECK(!Math::is_nan(t.x));
	CHECK(!Math::is_nan(b.x));

	// And the sheen still evaluates finitely through that frame.
	const SheenData d = sheen_setup(n, n, 0.5f);
	if (d.valid) {
		float pdf = 0.0f;
		const Vector3 l = sheen_sample(d, 0.5f, 0.5f, pdf);
		CHECK(!Math::is_nan(sheen_eval(d, l)));
		CHECK(!Math::is_nan(pdf));
	}
}

TEST_CASE("[PathTracer][Sheen] the invalid-LTC skip is reachable and drops the closure") {
	// Cycles sets CLOSURE_NONE_ID and sample_weight = 0 when |a| < 1e-5 or
	// albedo < 1e-5 (bsdf_sheen.h:44-49). If no input in the legal domain can
	// trigger it, the branch is dead and this test says so instead of pretending
	// to cover it.
	int invalid_count = 0;
	for (int i = 0; i <= 32; i++) {
		for (int j = 0; j <= 32; j++) {
			const float cos_ni = float(i) / 32.0f;
			const float rough = float(j) / 32.0f;
			const Vector3 n(0.0f, 0.0f, 1.0f);
			const Vector3 v = Vector3(Math::sqrt(MAX(0.0f, 1.0f - cos_ni * cos_ni)), 0.0f, cos_ni).normalized();
			if (!sheen_setup(n, v, rough).valid) {
				invalid_count++;
			}
		}
	}
	// Report the count rather than asserting a specific number: what matters is
	// that the guard is not decorative. Grazing incidence is where it fires.
	CAPTURE(invalid_count);
	CHECK(invalid_count > 0);
}

} // namespace TestPTSheen
```

- [ ] **Step 3: Build and run**

```bash
python -m SCons platform=windows target=editor tests=yes -j8
bin/godot.windows.editor.x86_64.console.exe --headless --test --test-case="*Sheen*"
```

Expected: 6 cases passing.

**If the invalid-LTC case reports `invalid_count == 0`, stop and report it** — that means the guard cannot fire in the legal domain, and either the mirror or my reading of Cycles is wrong. Do not delete the case to make it green.

- [ ] **Step 4: Prove the axis-order case can fail**

Temporarily swap the arguments in `sheen_setup`'s three reads to `(rough, cos_ni)`. Rebuild. **Expected: the `pdf == eval` case still passes** (it is self-consistent under any table values) **while the axis-order case's `correct != transposed` still passes too** — because it compares two reads directly rather than reading through `sheen_setup`.

That is the point: **the axis-order case guards the mirror's reader, not `sheen_setup`'s call site.** Record that limitation in your report. The GPU parity probe in Task 5 is what guards the call site, and Task 3 must expose the values it needs.

Revert the swap, rebuild, confirm green.

- [ ] **Step 5: Full suite and commit**

```bash
bin/godot.windows.editor.x86_64.console.exe --headless --test
```
Expected: 1548 passed / 0 failed / 3 skipped (1542 + 6).

```bash
git add servers/rendering/renderer_rd/storage_rd/sheen_ltc_table.h tests/servers/rendering/test_pt_sheen.cpp
git commit -m "test(pt): E2e Zeltner sheen table and its CPU mirror"
```

---

## Task 2: Generalise the layering into an N-layer stack — no behaviour change

**Files:**
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/brdf_inc.glsl` (around `coatLayeringTransmittance:2333` and `evalCombinedBRDFSeparate:2610`)
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl` (the sampler's transmittance site)

**Interfaces:**
- Consumes: `coatLayeringTransmittance(material, cosNI, coatAlbedo)`, `coatLayerAlbedo(material, cosNI)`, `LOBE_COUNT` = 3.
- Produces: `float3 layerTransmittanceAbove(MaterialProperties material, float cosNI, int lobeIndex)` — the product of every layer strictly *above* `lobeIndex` in the registry. `LOBE_COUNT` stays **3**.

**This task adds no lobe and changes no pixel.** It restructures E2d's single-site attenuation into a walk that a fourth layer can join, exactly as E2c added the registry before anything consumed it. That sequencing is deliberate: if a number moves here, it is this refactor, not sheen.

- [ ] **Step 1: Write the stack walk**

In `brdf_inc.glsl`, beside `coatLayeringTransmittance`:

```glsl
// The N-layer stack. Cycles layers SEQUENTIALLY -- sheen withdraws from the
// running weight (svm/closure.h:141), then coat withdraws from what is left
// (:174). Each layer attenuates everything allocated after it.
//
// Here that becomes: the transmittance applied to lobe i is the product of
// every LAYER strictly above i in registry order. A layer is a lobe that
// withdraws; specular and diffuse are not layers and contribute nothing to
// this product.
//
// At LOBE_COUNT == 3 the only layer is coat, so this returns exactly what
// E2d's single call site returned, for exactly the same lobes. That is the
// phase invariant and it is why this landed before sheen existed.
float3 layerTransmittanceAbove(MaterialProperties material, float cosNI, int lobeIndex) {
	float3 t = float3(1.0f, 1.0f, 1.0f);
	if (lobeIndex > LOBE_COAT) {
		t *= coatLayeringTransmittance(material, cosNI, coatLayerAlbedo(material, cosNI));
	}
	return t;
}
```

**Note `lobeIndex > LOBE_COAT`, not `>=`.** The coat does not attenuate itself. Getting that wrong squares the coat's withdrawal and is a plausible-looking off-by-one.

- [ ] **Step 2: Route both consumers through it**

In `evalCombinedBRDFSeparate`, replace the direct `coatLayeringTransmittance` call with `layerTransmittanceAbove(material, cosNI, LOBE_SPECULAR)` for the base terms. In the sampler, replace the equivalent site with `layerTransmittanceAbove(brdf_mat, cosNI, lobe)` — where `lobe` is the index actually selected, so a selected coat correctly receives no self-attenuation.

**Read both sites before editing.** E2d's transmittance is applied once, to `ps.throughput`, after the lobe is chosen; the evaluator applies it to `outDiffuse` and `outSpecular` but not `outCoat`. The walk must reproduce both behaviours exactly, and the second one is what `lobeIndex > LOBE_COAT` encodes.

- [ ] **Step 3: Full build and prove nothing moved**

```bash
python -m SCons platform=windows target=editor tests=yes -j8
bin/godot.windows.editor.x86_64.console.exe --headless --test
bin/godot.windows.editor.x86_64.console.exe --path pipeline_references res://tests/pt_coat_gate_scene.tscn
bin/godot.windows.editor.x86_64.console.exe --path pipeline_references res://tests/pt_energy_gate_scene.tscn
bin/godot.windows.editor.x86_64.console.exe --path pipeline_references res://tests/pt_anisotropy_gate_scene.tscn
bin/godot.windows.editor.x86_64.console.exe --path pipeline_references res://tests/pt_transmission_gate_scene.tscn
```

Expected: doctest 1548/0/3; **all four gates PASS with numbers unchanged**, including `pt_coat_gate`'s 36-configuration furnace.

**If any coat number moves, stop and report it.** This task is a no-op by construction; a moved number means the walk does not reproduce E2d's behaviour, and that is the whole thing being tested here.

- [ ] **Step 4: Commit**

```bash
git add servers/rendering/renderer_rd/shaders/raytracing/brdf_inc.glsl servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl
git commit -m "refactor(pt): E2e generalise coat layering into an N-layer stack"
```

---

## Task 3: The sheen table on the GPU, and the lobe's GLSL

**Files:**
- Modify: `servers/rendering/renderer_rd/storage_rd/` consumers in `render_raytracing.cpp` / `.h` (the binding-38 SSBO)
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/brdf_inc.glsl`
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl` (a parity vis mode)

**Interfaces:**
- Consumes: `SHEEN_LTC_TABLE`, `SHEEN_LTC_DIM`, and the offsets from Task 1; the existing SSBO offset scheme (`RT_COAT_SSBO_ALBEDO_OFFSET 0`, `_E_OFFSET 4096`, `_EAVG_OFFSET 5120`, `_FLOAT_COUNT 5152`).
- Produces: GLSL `SheenData sheenSetup(float3 N, float3 V, float sheenRoughness)`, `float sheenEval(SheenData d, float3 L)`, `float3 sheenSample(SheenData d, float2 u)`, and a new vis mode emitting `(transformA, transformB, ltcAlbedo)`.

**Nothing consumes the lobe yet** — Task 4 wires it in. This task gets it onto the GPU and makes it *measurable*, which is what Task 1 Step 4 established the CPU tests cannot do.

- [ ] **Step 1: Extend the SSBO**

Append the sheen table after the existing three, following the offset pattern already in `brdf_inc.glsl:1874-1877` and its C++ twin. New constants: `RT_SHEEN_SSBO_A_OFFSET 5152`, `_B_OFFSET 6176`, `_ALBEDO_OFFSET 7200`, and `RT_COAT_SSBO_FLOAT_COUNT` becomes `8224`.

**Mirror `GGX_E_DIM`'s treatment, not the coat's earlier one.** E2d shipped bare `32` literals here and it was the final review's only merge-blocking finding: the C++ side used its constant while GLSL used a literal, so a re-extraction at a different size would corrupt silently through a green suite. Define `SHEEN_LTC_DIM` in GLSL, use it at every read, and add the dimension to the offset doctest in `test_pt_coat_albedo.cpp` beside the existing pins.

- [ ] **Step 2: Write the GLSL**

Transcribe the CPU mirror from Task 1. Structure it the same way, with `sheenSetup` returning a struct carrying `T`, `B`, `N`, `a`, `b`, `albedo`, `valid`.

**Three things the transcription must preserve, each of which compiles either way:**
- The read order is `(cosNI, roughness)`. The coat's reader next door takes `(rough, mu)`.
- The frame fallback tests `len_squared(b) < 0.99f`, not `== 0`.
- `sheenEval` returns the value that is *both* the eval and the pdf. Do not write two functions that compute it twice — one function, used for both, so they cannot drift.

- [ ] **Step 3: Add the parity vis mode**

Follow the pattern at `raytracing_closest_hit_common_inc.glsl:945-947` (mode 38 for `coatAlbedoEstimate`) and E2d's mode 39. Emit `vec3(d.a, d.b, d.albedo)` from `sheenSetup` at the hit's material and view.

**This is the instrument for the axis order**, which Task 1 Step 4 showed the CPU tests structurally cannot guard at the call site. Task 5's probe reads it at a point where the transposed order gives a different answer.

- [ ] **Step 4: Full build and verify no render change**

```bash
python -m SCons platform=windows target=editor tests=yes -j8
bin/godot.windows.editor.x86_64.console.exe --headless --test
bin/godot.windows.editor.x86_64.console.exe --path pipeline_references res://tests/pt_coat_gate_scene.tscn
bin/godot.windows.editor.x86_64.console.exe --path pipeline_references res://tests/pt_energy_gate_scene.tscn
```

Expected: doctest 1548/0/3 plus your new offset/dimension assertions; both gates PASS unchanged. Nothing consumes the lobe yet.

- [ ] **Step 5: Commit**

```bash
git add servers/rendering/renderer_rd/forward_clustered/render_raytracing.h servers/rendering/renderer_rd/forward_clustered/render_raytracing.cpp servers/rendering/renderer_rd/shaders/raytracing/brdf_inc.glsl servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl tests/servers/rendering/test_pt_coat_albedo.cpp
git commit -m "feat(pt): E2e sheen LTC table on the GPU with its own dimension constant"
```

---

## Task 4: Sheen joins the registry as lobe 3, and the stack

**Files:**
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/brdf_inc.glsl`
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl`
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_lights_inc.glsl`, `raytracing_emissive_inc.glsl`

**Interfaces:**
- Consumes: everything from Tasks 1-3.
- Produces: `LOBE_SHEEN = 3`, `LOBE_COUNT = 4`, `SHEEN_TYPE`, `float sheenLobeWeight(MaterialProperties material, float cosNI)`, `float3 evalSheen(...)`, and a fourth out-parameter on `evalCombinedBRDFSeparate`.

**These land together**, as E2d's coat did: a sheen lobe without its withdrawal is an additive sheen, and a withdrawal without the lobe loses energy. Every intermediate state is a wrong render.

- [ ] **Step 1: Extend `MaterialProperties` and the registry**

Add `float3 sheenColor; float sheenRoughness;` to `MaterialProperties`, populated at **every** site that builds it — E2d found five, and one of them (vis mode 35's) was load-bearing. Grep for the existing `coatWeight` assignments and match them one for one.

Apply Cycles' clamps: `sheenRoughness = clamp(material.sheen_roughness, 0.0, 1.0)` on upload-side semantics then `[1e-3, 1.0]` inside setup (`bsdf_sheen.h:33`); `sheenColor = max(material.sheen_color, 0)`.

```glsl
#define LOBE_SHEEN 3
#define LOBE_COUNT 4
```

- [ ] **Step 2: The selection weight, with the invalid-LTC skip**

```glsl
// Cycles gates the whole sheen block on sheen_weight > CLOSURE_WEIGHT_CUTOFF
// (1e-5, svm/types.h:576) and then drops the closure entirely if the LTC is
// invalid (bsdf_sheen.h:44-49). Our single sheen_color carries Cycles'
// sheen_weight * sheen_tint product, so the cutoff is on its MAX CHANNEL --
// matching closure_layering_weight's reduce_max, not a luminance, which would
// let a saturated blue sheen fall below the threshold.
//
// The LTC half CANNOT be hoisted above the table read: it depends on the
// table's own output, unlike the coat's gate on an authored parameter.
float sheenLobeWeight(MaterialProperties material, float cosNI) {
	float maxChannel = max(material.sheenColor.r, max(material.sheenColor.g, material.sheenColor.b));
	if (maxChannel <= 0.00001f) {
		return 0.0f;
	}
	SheenData d = sheenSetup(/* N, V from the caller */);
	if (!d.valid) {
		return 0.0f;
	}
	// Cycles: sample_weight *= albedo (bsdf_sheen.h:52). Clamped for the same
	// reason every other lobe's weight is: the sampler divides throughput by
	// it, so an unclamped weight is an unbounded variance source.
	return clamp(maxChannel * d.albedo, 0.01f, 0.99f);
}
```

The `/* N, V from the caller */` marker is deliberate — **thread the actual `N` and `V` through rather than guessing a signature.** `sheenSetup` needs both, and `coatLobeWeight` takes only `cosNI`, so the signatures differ. Report the one you chose.

- [ ] **Step 3: Four-lobe selection, sheen appended**

Extend the weights array to four entries. The base share is now scaled by *both* layers above it. Sheen takes its mass first, then coat from what remains, then specular/diffuse split the rest — matching the withdrawal order.

**Still exactly one `rng_1d(rng, RT_PRNG_LOBE)` draw, consumed once, unremapped.**

- [ ] **Step 4: Add sheen to the stack**

Extend `layerTransmittanceAbove` so a lobe above sheen's index receives sheen's transmittance too:

```glsl
	if (lobeIndex > LOBE_SHEEN) {
		t *= sheenLayeringTransmittance(material, cosNI);
	}
```

with

```glsl
// closure_layering_weight(a, w) = w * saturate(1 - reduce_max(a/w))
// (bsdf_util.h:440). For sheen, bsdf_albedo is sc->weight unmodified -- sheen
// is not CLOSURE_IS_BSDF_MICROFACET, so bsdf_albedo's microfacet branch
// (bsdf.h:707) does not apply. So a/w is sheenColor * ltcAlbedo, a float3, and
// the reduction is over its MAX CHANNEL.
//
// E2d's coat made this invisible: its albedo was make_spectrum(F), a scalar
// broadcast, so reduce_max was trivially F. Sheen has a real per-channel tint,
// so the max-channel reduction is load-bearing for the first time.
```

**Sheen has index 3 and coat index 2, so `lobeIndex > LOBE_SHEEN` is true for nothing.** That is wrong, and it is the trap this step contains: registry index order (specular 0 … sheen 3) is the *opposite* of physical layer order (sheen outermost). Decide explicitly how the walk expresses "above" — a `LAYER_DEPTH` mapping, an explicit ordered list, or reversing the comparison — and say which you chose and why. Do not paper over it with a `<`.

- [ ] **Step 5: The fourth out-parameter**

`evalCombinedBRDFSeparate` gains `OUT_PARAMETER(float3) outSheen`. Update all five call sites: `raytracing_lights_inc.glsl:394`, `:568`, `:617`, `raytracing_closest_hit_common_inc.glsl:1513`, `raytracing_emissive_inc.glsl:489`.

**Do not add a four-argument overload.** E2d's review confirmed the absence of a shorter overload is what forced every call site to decide rather than silently inherit. Keep that property.

- [ ] **Step 6: Extend `combinedPdf`**

Add sheen's term. Its pdf is `sheenEval` — the same function, since `pdf == eval`. Preserve ascending summation order: specular, diffuse, coat, sheen.

- [ ] **Step 7: Full build and the phase invariant**

```bash
python -m SCons platform=windows target=editor tests=yes -j8
bin/godot.windows.editor.x86_64.console.exe --headless --test
```
plus all four existing GPU gates.

Expected: doctest green; **all four gates PASS with numbers unchanged.** Every existing scene has `sheen_color = 0`, so `sheenLobeWeight` returns literal `0.0f` and the arithmetic must reduce to Task 2's exactly.

**If any number moves, stop and report.** Do not re-baseline.

- [ ] **Step 8: Commit**

```bash
git add servers/rendering/renderer_rd/shaders/raytracing/brdf_inc.glsl servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl servers/rendering/renderer_rd/shaders/raytracing/raytracing_lights_inc.glsl servers/rendering/renderer_rd/shaders/raytracing/raytracing_emissive_inc.glsl
git commit -m "feat(pt): E2e the sheen lobe and its place in the layer stack"
```

---

## Task 5: The gate, and proving it can fail

**Files:**
- Create: `pipeline_references/tests/pt_sheen_gate.gd`, `pipeline_references/tests/pt_sheen_gate_scene.tscn`

**Interfaces:**
- Consumes: Task 3's parity vis mode; E2d's vis mode 40 (full-mixture pdf); the sheen lobe.
- Produces: a gate exiting 0 on pass, 1 on fail.

**Model it on `pipeline_references/tests/pt_coat_gate.gd`** — read it first. It carries the measured-baseline pattern, the sRGB pre-encode, and the scene-building traps (`Sky.PROCESS_MODE_QUALITY`, `BG_SKY`) that have each silently broken a sibling gate.

**This is the first execution of any sheen code.** Treat every probe as a discovery. If a probe disagrees with expectation, the likely cause is a real defect, not a bad expectation — report it rather than tuning.

- [ ] **Step 1: Probe A — GPU/CPU parity on the three LUT reads**

Read Task 3's vis mode. Assert `transformA`, `transformB`, `ltcAlbedo` against Task 1's CPU mirror at **at least one point where `(cosNI, roughness)` and `(roughness, cosNI)` differ by more than 0.01** — Task 1's axis test establishes such a point exists at `(0.2, 0.8)`. A probe at `cosNI == roughness` cannot fail.

- [ ] **Step 2: Probe B — the furnace, and the stack**

A white Lambertian under a constant-radiance-1 environment, sheened. Sweep `sheen_color` ∈ {black, 0.25 grey, white, saturated red} × `sheen_roughness` ∈ {0.05, 0.5, 0.9}. **The sweep must be flat** — energy sheen takes is energy the layers below lose.

Include a **coated** arm: sheen over coat over base, which is the only configuration that exercises two live layers in the stack. Measured-intact baselines, ±0.5pp.

The saturated-red arm is what tests §3.2's max-channel reduction: a luminance-based reduction would withdraw visibly less there.

- [ ] **Step 3: Probe C — four live lobes in the pdf**

Point E2d's **vis mode 40** (full production mixture) at a sheened, coated material and require `E[1/combinedPdf]` → `2π = 6.283185`, tolerance 3%.

**Not vis mode 35** — it draws from `sampleSpecularMicrofacet` alone and fails on correct code once the mixture has more than that one density. That cost E2d a fix round.

Check the lever before trusting the result: report sheen's share of the mixture, and if it is at or below the 3% tolerance, raise it by choosing a stronger sheen rather than tightening the tolerance.

- [ ] **Step 4: Probe D — the degenerate frame at normal incidence**

Render a sheened sphere and read the pixel where the surface normal faces the camera — where `cross(N, V)` is zero and the frame falls back. Assert the value is finite and continuous with its neighbours. A NaN or a seam there is the fallback being wrong.

- [ ] **Step 5: PROVE THE GATE CAN FAIL**

Delete sheen's entry from `layerTransmittanceAbove` — making sheen additive. Rebuild. Run the gate.

**Expected: probe B's sweep is no longer flat and the gate exits 1.** Record the numbers with and without. Restore, rebuild, confirm baseline.

If the gate passes with sheen additive, **it is not an instrument** — fix it and say so plainly rather than proceeding.

- [ ] **Step 6: Commit**

```bash
git add pipeline_references/tests/pt_sheen_gate.gd pipeline_references/tests/pt_sheen_gate_scene.tscn
git commit -m "test(pt): E2e sheen gate, proven by breaking the stack"
```

---

## Task 6: Cycles velvet comparison and closeout

**Files:**
- Modify: `PATH_TRACER_QUALITY_ROADMAP.md`

- [ ] **Step 1: Measure velvet against Cycles**

Velvet is E2's stated acceptance target alongside car paint (roadmap §4). Drive Blender headlessly as E2d's Task 7 did — that run used 4.5.3 LTS on OptiX at 1024 spp and it worked.

**Author every colour with `.linear_to_srgb()`.** Include a colour-space **positive control** that deliberately skips the encode and confirm it reproduces the trap loudly — E2d's read +129.0%, which is what proves the harness would catch the error that inverted E2a's verdict.

Report **raw** and **Gap #17-adjusted** figures. Isolate sheen's own delta by subtracting each engine's uncoated, unsheened control. Do not tune to close a gap.

- [ ] **Step 2: Write §7.11**

Add `### 7.11 E2e - sheen (Zeltner LTC) and the N-layer stack` after §7.10. Record:

- Sheen as an LTC lobe with `pdf == eval`, and what that bought (sample weight 1, a CPU-testable identity).
- **The N-layer stack**, and that Task 2 landed it with no behaviour change before sheen existed — with the coat gates unchanged as the evidence.
- The max-channel reduction, and that E2d's scalar coat albedo hid it.
- The transposed LUT axes, and which probe guards them.
- The degenerate view-frame fallback and where it fires.
- Task 5 Step 5's break-the-guard numbers.
- The Cycles velvet figures, raw and adjusted.
- **What E2e does not deliver**: `coat_normal`, still deferred and now touching both coat and sheen (`closure.h:127-129`); the denoiser AOVs, which know about neither layer and are now one entry worse (§7.10.7); and any coat NEE path E2e's fourth out-parameter touched but no scene exercised.

Mark sheen complete in §4's phase table. **E2's original acceptance line — brushed metal, car paint, velvet — is now fully addressed; say so, with the qualifier that `coat_normal` remains outstanding for car paint.**

- [ ] **Step 3: Commit**

```bash
git add PATH_TRACER_QUALITY_ROADMAP.md
git commit -m "docs(pt): E2e closeout - sheen and the N-layer stack"
```

---

## Self-review notes

**Spec coverage.** §3.1 stack → Task 2, Task 4 Step 4. §3.2 max-channel → Global Constraints, Task 4 Step 4, Task 5 Step 2's red arm. §3.3 no new field → Task 4 Step 1; the max-channel cutoff → Task 4 Step 2. §3.4 index 3 → Task 4 Step 1. §3.5 `coat_normal` → Task 6 Step 2. §4.1 the lobe → Tasks 1 and 3. §4.2 the frame → Task 1's two frame cases, Task 5 Step 4. §4.3 invalid-LTC → Task 1's reachability case, Task 4 Step 2. §5 verification → Tasks 1, 5, 6. §6 acceptance 1 → Tasks 2/3/4 Step 7; 2 → Task 5 Step 5; 3 → Task 5 Step 1; 4 → Task 1; 5 → Task 6; 6 → every task's verify step.

**Type consistency.** `sheenSetup` / `sheenEval` / `sheenSample` / `sheenLobeWeight` / `sheenLayeringTransmittance` / `layerTransmittanceAbove` are used identically across Tasks 2-5. CPU mirrors use snake_case per the house style of `test_pt_coat_albedo.cpp`; GLSL uses camelCase per `brdf_inc.glsl`.

**Two things this plan deliberately leaves open, because guessing would be worse.**

1. **`sheenLobeWeight`'s signature.** `coatLobeWeight` takes `(material, cosNI)`, but `sheenSetup` needs `N` and `V` for the frame. The plan marks the spot and asks the implementer to thread the real values and report the signature. Inventing one here risks the E2d Task 5 failure, where my snippet named a function that did not exist.

2. **How the stack walk expresses "above".** Registry index order runs specular 0 → sheen 3, which is the *reverse* of physical layer order. Task 4 Step 4 names the trap explicitly and requires a stated choice rather than a silent `<`. This is the single most likely place for a plausible-looking inversion, and it is exactly the class of defect that renders statistically-similar images no gate can distinguish.

**Known risk this plan cannot remove.** The GLSL sheen transcription has no automated test — doctest cannot execute GLSL, and Task 1's mirrors only guard the CPU side. Task 3's parity vis mode plus Task 5's probe A are the mitigation, and they compare a handful of points rather than the domain. This is the same structural limit recorded in §7.9 and §7.10; the reviewer should be told to read the two implementations side by side rather than trusting the gate.
