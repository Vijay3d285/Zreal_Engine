# Emissive-Mesh Light Sampling (C1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make emissive geometry directly sampleable by Next Event Estimation and MIS-combine it against the BSDF rays that already reach it, so a room lit only by a glowing panel converges without hotspot speckle.

**Architecture:** A power-weighted CDF over emissive *instances* (built by a GPU compute pass because vertex data lives behind buffer-device-address pointers), then a uniform triangle within the instance, then a uniform point on that triangle. No per-triangle storage anywhere — triangle area is recomputed from the vertex buffer wherever it is needed. The whole feature sits behind a project setting defaulting to **off**.

**Tech Stack:** GLSL (Vulkan RD raytracing + compute stages), C++ (RD storage unit, `render_raytracing.cpp` integration), C++ doctest unit tests, GDScript gates under `pipeline_references/`.

**Spec:** `docs/superpowers/specs/2026-08-12-emissive-mesh-lights-design.md` — read it before starting. Where they disagree, the spec is authoritative on *intent*, this plan on *code*.

## Global Constraints

- **Script changes go in `pipeline_references/` ONLY.** Never edit anything under `C:\Zlendo2026\ZlenderRender_stage_copy/`.
- **Run builds in the FOREGROUND** with `timeout: 600000`. Backgrounding a build ends your turn and stalls the pipeline. Full builds take 2-25 minutes; that is expected.
- Build command is `python -m SCons platform=windows tests=yes target=editor` — plain `scons` is **not** on PATH in this environment.
- After touching any `.glsl`, run a full build so `.glsl.gen.h` regenerates. Never hand-edit a `.gen.h`.
- New test files need `TEST_FORCE_LINK(<basename>)`; `tests/force_link.gen.h` is generated.
- **`--test "<pattern>"` does NOT filter in this binary.** Use `--test --test-case="<pattern>"`.
- `Math::PI`, not `Math_PI` (`core/math/math_defs.h:44`).
- Any struct crossing to GLSL needs a verbatim twin plus `static_assert` on size and offsets (std430 parity rule).
- New `RS` API surface must be updated in `rendering_server.h` (virtual), `rendering_server_default.h` (`FUNC*`), the RD impl, **and** the dummy stub in `servers/rendering/dummy/storage/`, or the headless build breaks.
- Godot 29-line file header on every new `.cpp`/`.h` — copy from `tests/servers/rendering/test_pt_russian_roulette.cpp`.
- `RT_EMISSIVE_INSTANCES_MAX = 256`.
- Suite baseline entering this plan: **1448 passed, 0 failed, 3 skipped.**

---

## File Structure

| File | Responsibility |
|---|---|
| `servers/rendering/renderer_rd/shaders/raytracing/raytracing_vertex_inc.glsl` | **Create.** `rt_fetch_vertex_position` only — the compressed/uncompressed decode, shared by three call sites. |
| `servers/rendering/renderer_rd/storage_rd/emissive_lights.{h,cpp}` | **Create.** Owns the instance buffer, CDF buffer, slot table, the compute pipeline, and the rebuild token. Mirrors `env_cdf.{h,cpp}`. |
| `servers/rendering/renderer_rd/shaders/raytracing/emissive_area_build.glsl` | **Create.** Two-mode compute pass: per-instance world-area reduction, then the CDF. |
| `servers/rendering/renderer_rd/shaders/raytracing/raytracing_emissive_inc.glsl` | **Create.** `emissive_sample`, `emissive_pdf_for_hit`, and the shared `emissive_radiance` helper. |
| `servers/rendering/rendering_server.cpp` | **Modify.** `GLOBAL_DEF` for the project setting. |
| `doc/classes/ProjectSettings.xml` | **Modify.** Document the setting. |
| `servers/rendering/renderer_rd/forward_clustered/render_raytracing.{h,cpp}` | **Modify.** Gather emissive instances, drive the update, bind the buffers. |
| `servers/rendering/renderer_rd/shaders/raytracing/raytracing_inc.glsl` | **Modify.** Widen `RT_PRNG_BOUNCE_NUM` to 16; add two dimension constants. |
| `servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl` | **Modify.** MIS-weight the emissive hit; add the emissive NEE block. |
| `tests/servers/rendering/test_pt_emissive.cpp` | **Create.** CPU mirrors: area, pdf composition, measure conversion, slot table, remap. |
| `pipeline_references/tests/pt_emissive_gate.gd` + `.tscn` | **Create.** Gates 1-3. |
| `pipeline_references/tests/pt_emissive_rmse.gd` + `.tscn` | **Create.** The measurement. |
| `PATH_TRACER_QUALITY_ROADMAP.md` | **Modify.** C1 closeout, Phase C complete. |

**Six tasks.** Task 1 is the sampler widening *alone* (isolated so its neutrality is provable before anything else moves). Tasks 2-3 build the distribution. Task 4 adds NEE. Task 5 adds MIS. Task 6 measures and closes out. A reviewer can reject any one while approving its neighbours.

---

### Task 1: Widen the sampler dimension block

Isolated deliberately. Widening `RT_PRNG_BOUNCE_NUM` changes which Sobol dimension **every** bounce draws from, so it re-stratifies the entire integrator. Doing it alone means a converged-mean shift here cannot be misattributed to C1's lighting changes later.

**Files:**
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_inc.glsl:253-262`

**Interfaces:**
- Produces: `RT_PRNG_BOUNCE_NUM 16u`, `RT_PRNG_EMISSIVE_SELECT 8u`, `RT_PRNG_EMISSIVE_POINT 9u`.

- [ ] **Step 1: Widen the block and claim two slots**

Replace lines 253-262 of `raytracing_inc.glsl` with:

```glsl
// Cycles uses a block of 16 (kernel/types.h PathTraceDimension); we were at 8
// with every slot taken, and C1's emissive NEE needs three more dimensions.
// WIDENING THIS RE-STRATIFIES EVERY BOUNCE: rng_next_bounce advances `offset` by
// RT_PRNG_BOUNCE_NUM, so each bounce after the first now draws from a different
// Sobol dimension than it did at 8. The estimator stays unbiased -- every
// dimension of the sequence is equidistributed -- but the image changes at any
// finite sample count, and the converged mean must not. That is gated
// separately (pt_emissive_gate.gd, gate 3) before any lighting change lands.
#define RT_PRNG_BOUNCE_NUM 16u
#define RT_PRNG_FILTER 0u // 2D, init block only: sub-pixel reconstruction filter.
#define RT_PRNG_SURFACE_BSDF 0u // 2D: BSDF direction sample.
#define RT_PRNG_LIGHT 2u // 2D: position on the selected light.
#define RT_PRNG_LOBE 4u // 1D: diffuse-vs-specular lobe choice.
#define RT_PRNG_TERMINATE 5u // 1D: Russian Roulette survival (B4).
#define RT_PRNG_LIGHT_SELECT 6u // 1D: which analytic light to sample (C2).
#define RT_PRNG_ENV 7u // 2D: direction sample on the environment (C3).
#define RT_PRNG_EMISSIVE_SELECT 8u // 1D: emissive instance + triangle (C1).
#define RT_PRNG_EMISSIVE_POINT 9u // 2D: barycentric point on that triangle (C1).
// Slots 10-15 are free. Earlier dimensions are better stratified, so the
// highest-variance decision (the BSDF direction) keeps 0.
```

- [ ] **Step 2: Full build**

```bash
python -m SCons platform=windows tests=yes target=editor
```

Expected: clean. `scene_raytracing_raygen.glsl.gen.h` regenerates.

- [ ] **Step 3: Confirm the widening reached the shader**

```bash
grep -c "define RT_PRNG_BOUNCE_NUM 16u" servers/rendering/renderer_rd/shaders/raytracing/scene_raytracing_raygen.glsl.gen.h
```

Expected: non-zero. A `0` means a stale `.gen.h` and everything measured after it is worthless.

- [ ] **Step 4: Run the suite**

```bash
bin/godot.windows.editor.x86_64.exe --test
```

Expected: **1448 passed, 0 failed, 3 skipped.** The Sobol tests assert stratification properties that hold at any block size, so none should move.

- [ ] **Step 5: Commit**

```bash
git add servers/rendering/renderer_rd/shaders/raytracing/raytracing_inc.glsl
git commit -m "refactor(pt): widen the sampler dimension block to 16 for C1"
```

Gate 3 in Task 6 proves the converged mean did not move. Do not skip it.

---

### Task 2: Shared vertex-position fetch

**Files:**
- Create: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_vertex_inc.glsl`
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_hit_inc.glsl` (add the include near the top, after `raytracing_data_inc.glsl` is available)
- Test: `tests/servers/rendering/test_pt_emissive.cpp`

**Interfaces:**
- Consumes: `GeometryData` (`raytracing_data_inc.glsl:17`), `get_aabb_compression_xforms` (`:54`), `FLAG_COMPRESSED` (`raytracing_inc.glsl:202`), `FloatBuffer`/`Uint32Buffer`.
- Produces: `vec3 rt_fetch_vertex_position(GeometryData p_geom, uint p_index)` — **object space**.

- [ ] **Step 1: Write the failing tests**

Create `tests/servers/rendering/test_pt_emissive.cpp` with the Godot 29-line header (copy from `test_pt_russian_roulette.cpp`, change the filename on line 2), then:

```cpp
#include "tests/test_macros.h"

TEST_FORCE_LINK(test_pt_emissive)

#include "core/math/math_funcs.h"
#include "core/math/transform_3d.h"
#include "core/math/vector3.h"

#include <algorithm>
#include <vector>

namespace TestPTEmissive {

// CPU mirrors of the emissive-light sampling maths in
// servers/rendering/renderer_rd/shaders/raytracing/raytracing_vertex_inc.glsl and
// raytracing_emissive_inc.glsl.
//
// STANDING CAVEAT: the doctest binary never executes GLSL. Every case here would
// still pass if the shaders were reverted and these mirrors left untouched. The
// evidence that the SHADERS are right is pipeline_references/tests/pt_emissive_gate.gd,
// which renders real frames and asserts that enabling emissive NEE does not move
// the converged mean.

// Mirror of the COMPRESSED branch of rt_fetch_vertex_position(). Compressed
// vertices are four uint16 across two words: x | (y << 16) in word 0, z in the
// low half of word 1 (the high half is the tangent angle -- see
// fetch_tbn_compressed_vertex, which reads exactly that). Normalised to [0,1]
// and mapped through the mesh AABB.
static Vector3 mirror_decode_compressed_position(uint32_t p_word0, uint32_t p_word1,
		const Vector3 &p_aabb_pos, const Vector3 &p_aabb_size) {
	const Vector3 n(
			float(p_word0 & 0xFFFFu) / 65535.0f,
			float(p_word0 >> 16) / 65535.0f,
			float(p_word1 & 0xFFFFu) / 65535.0f);
	return Vector3(
			p_aabb_pos.x + n.x * p_aabb_size.x,
			p_aabb_pos.y + n.y * p_aabb_size.y,
			p_aabb_pos.z + n.z * p_aabb_size.z);
}

// Mirror of the world-space triangle area used by the area-reduction pass.
static float mirror_triangle_area_world(const Transform3D &p_xform,
		const Vector3 &p0, const Vector3 &p1, const Vector3 &p2) {
	const Vector3 w0 = p_xform.xform(p0);
	const Vector3 w1 = p_xform.xform(p1);
	const Vector3 w2 = p_xform.xform(p2);
	return 0.5f * (w1 - w0).cross(w2 - w0).length();
}

TEST_CASE("[PathTracer][Emissive] compressed position decode spans the AABB") {
	const Vector3 aabb_pos(-2.0f, 5.0f, 0.25f);
	const Vector3 aabb_size(4.0f, 1.0f, 8.0f);

	// All-zero words -> the AABB minimum corner.
	CHECK(mirror_decode_compressed_position(0u, 0u, aabb_pos, aabb_size)
					.is_equal_approx(aabb_pos));
	// Saturated words -> the maximum corner.
	const Vector3 hi = mirror_decode_compressed_position(0xFFFFFFFFu, 0x0000FFFFu, aabb_pos, aabb_size);
	CHECK(hi.is_equal_approx(aabb_pos + aabb_size));

	// The tangent angle lives in the HIGH half of word 1 and must not leak into z.
	// Without the & 0xFFFF mask, z would read ~65535/65535 instead of 0.
	const Vector3 z_zero = mirror_decode_compressed_position(0u, 0xFFFF0000u, aabb_pos, aabb_size);
	CHECK(z_zero.z == doctest::Approx(aabb_pos.z));
}

TEST_CASE("[PathTracer][Emissive] world area is correct under NON-UNIFORM scale") {
	// The "object-space area x s^2" shortcut is only valid under uniform scale.
	// This case has three distinct scale factors AND a rotation, so a shortcut
	// implementation cannot pass it.
	const Vector3 p0(0, 0, 0), p1(1, 0, 0), p2(0, 1, 0);
	CHECK(mirror_triangle_area_world(Transform3D(), p0, p1, p2) == doctest::Approx(0.5f));

	Transform3D scaled;
	scaled.basis.scale(Vector3(2.0f, 3.0f, 5.0f));
	// The triangle lies in the XY plane, so only x and y scaling affect its area.
	CHECK(mirror_triangle_area_world(scaled, p0, p1, p2) == doctest::Approx(0.5f * 2.0f * 3.0f));

	// With a rotation the z scale now participates and no per-axis shortcut works.
	Transform3D rotated = scaled;
	rotated.basis = Basis(Vector3(1, 0, 0), Math::PI / 4.0f) * rotated.basis;
	const float a = mirror_triangle_area_world(rotated, p0, p1, p2);
	CHECK(a > 0.0f);
	CHECK(a != doctest::Approx(0.5f * 2.0f * 3.0f));
}

TEST_CASE("[PathTracer][Emissive] a degenerate triangle has zero area") {
	const Vector3 p(1.0f, 2.0f, 3.0f);
	CHECK(mirror_triangle_area_world(Transform3D(), p, p, p) == doctest::Approx(0.0f));
	// Collinear, not coincident -- the cross product must still vanish.
	CHECK(mirror_triangle_area_world(Transform3D(), Vector3(0, 0, 0), Vector3(1, 1, 1), Vector3(2, 2, 2))
					== doctest::Approx(0.0f));
}

} // namespace TestPTEmissive
```

- [ ] **Step 2: Run to verify they compile and pass**

```bash
python -m SCons platform=windows tests=yes target=editor && bin/godot.windows.editor.x86_64.exe --test --test-case="*Emissive*"
```

Expected: 3 cases pass. They test the mirror; the GLSL in Step 3 is then written to match it line by line.

- [ ] **Step 3: Write the GLSL helper**

Create `servers/rendering/renderer_rd/shaders/raytracing/raytracing_vertex_inc.glsl`:

```glsl
// Vertex POSITION fetch, in object space.
//
// Requires: raytracing_data_inc.glsl (GeometryData, get_aabb_compression_xforms,
// FloatBuffer, Uint32Buffer) and raytracing_inc.glsl (FLAG_COMPRESSED).
//
// This exists because the closest-hit shader does NOT read vertex positions --
// it derives h.hit_pos from gl_WorldRayOriginEXT + dir * gl_HitTEXT and fetches
// only normals and UVs. Emissive light sampling needs real positions in three
// places (the area reduction, the NEE sample point, and the MIS reverse lookup),
// so the decode lives here once rather than three times.
//
// A CPU mirror of the compressed branch lives in
// tests/servers/rendering/test_pt_emissive.cpp; change both together.

/// Object-space position of vertex `p_index`.
vec3 rt_fetch_vertex_position(GeometryData p_geom, uint p_index) {
	if ((p_geom.flags & FLAG_COMPRESSED) != 0u) {
		// Four uint16 across two words: x | (y << 16), then z in the LOW half of
		// word 1. The high half of word 1 is the tangent angle
		// (fetch_tbn_compressed_vertex reads exactly that word for it), so the
		// mask on z is load-bearing, not defensive.
		Uint32Buffer vb = Uint32Buffer(p_geom.vertex_address);
		uint w0 = vb.v[p_index * 2u + 0u];
		uint w1 = vb.v[p_index * 2u + 1u];

		vec3 n = vec3(
				float(w0 & 0xFFFFu),
				float(w0 >> 16),
				float(w1 & 0xFFFFu)) / 65535.0;

		mat4 aabb_xform, inv_aabb_xform;
		get_aabb_compression_xforms(p_geom, aabb_xform, inv_aabb_xform);
		return (aabb_xform * vec4(n, 1.0)).xyz;
	}

	FloatBuffer vb = FloatBuffer(p_geom.vertex_address);
	uint stride_floats = p_geom.position_stride >> 2;
	return vec3(
			vb.v[p_index * stride_floats + 0u],
			vb.v[p_index * stride_floats + 1u],
			vb.v[p_index * stride_floats + 2u]);
}
```

- [ ] **Step 4: Include it**

In `raytracing_hit_inc.glsl`, immediately after its existing includes at the top of the file, add:

```glsl
#include "raytracing_vertex_inc.glsl"
```

- [ ] **Step 5: Build and compare mirror against GLSL**

```bash
python -m SCons platform=windows tests=yes target=editor
```

Then read `mirror_decode_compressed_position` beside `rt_fetch_vertex_position`'s compressed branch and confirm the word layout, the shifts, the masks and the `/ 65535.0` all match. This manual diff is the only thing keeping the mirror honest.

- [ ] **Step 6: Suite and commit**

```bash
bin/godot.windows.editor.x86_64.exe --test
git add servers/rendering/renderer_rd/shaders/raytracing/raytracing_vertex_inc.glsl servers/rendering/renderer_rd/shaders/raytracing/raytracing_hit_inc.glsl tests/servers/rendering/test_pt_emissive.cpp
git commit -m "feat(pt): shared vertex-position fetch for emissive sampling (C1)"
```

Expected: 1451 passed (1448 + 3).

---

### Task 3: The emissive-instance distribution

**Files:**
- Create: `servers/rendering/renderer_rd/storage_rd/emissive_lights.{h,cpp}`
- Create: `servers/rendering/renderer_rd/shaders/raytracing/emissive_area_build.glsl`
- Modify: `servers/rendering/renderer_rd/forward_clustered/render_raytracing.{h,cpp}`
- Modify: `servers/rendering/rendering_server.cpp`, `doc/classes/ProjectSettings.xml`
- Test: `tests/servers/rendering/test_pt_emissive.cpp` (append)

**Interfaces:**
- Consumes: `rt_fetch_vertex_position` (Task 2); `RT_GeometryData`, `RT_MaterialData` and `blas_transforms` in `render_raytracing.cpp`; `RT_MAT_FLAG_HAS_EMISSION_TEX = 2u` (`render_raytracing.h:185`).
- Produces:
  - C++ `RendererRD::EmissiveLights` with `void update(...)`, `RID get_instance_buffer() const`, `RID get_cdf_buffer() const`, `RID get_slot_buffer() const`, `bool is_valid() const`, `uint32_t get_count() const`, `void mark_dirty_if_token_changed(uint64_t p_token)`.
  - GLSL `EmissiveInstance` struct + `emissive_instances[]`, `emissive_cdf[]`, `emissive_slot[]` SSBOs.
  - `RT_EMISSIVE_INSTANCES_MAX = 256`.

- [ ] **Step 1: Register the project setting**

In `servers/rendering/rendering_server.cpp`, beside the existing pathtracer settings (the `russian_roulette_min_bounce` `GLOBAL_DEF` added in B4):

```cpp
GLOBAL_DEF(PropertyInfo(Variant::BOOL, "rendering/pathtracer/emissive_mesh_lights"), false);
```

In `doc/classes/ProjectSettings.xml`, beside the other `rendering/pathtracer/*` members:

```xml
<member name="rendering/pathtracer/emissive_mesh_lights" type="bool" setter="" getter="" default="false">
    If [code]true[/code], meshes with emissive materials are sampled directly as light sources by the path tracer's next-event estimation, and multiple importance sampling combines that against BSDF rays that reach them. Defaults to [code]false[/code] because a scene that already places an analytic light at the same position as an emissive fixture mesh would then be lit twice.
</member>
```

- [ ] **Step 2: Write the failing tests for selection and CDF**

Append inside `namespace TestPTEmissive` in `tests/servers/rendering/test_pt_emissive.cpp`:

```cpp
static const uint32_t MAT_FLAG_HAS_EMISSION_TEX = 2u;
static const uint32_t EMISSIVE_INSTANCES_MAX = 256;

static float mirror_luminance(const Vector3 &p_c) {
	return p_c.x * 0.2126f + p_c.y * 0.7152f + p_c.z * 0.0722f;
}

// Mirror of the CPU-side qualification test in gather_emissive_instances().
static bool mirror_is_emissive(uint32_t p_flags, const Vector3 &p_emission_color, float p_strength) {
	if ((p_flags & MAT_FLAG_HAS_EMISSION_TEX) != 0u) {
		return true;
	}
	return mirror_luminance(p_emission_color) * p_strength > 1e-4f;
}

// Mirror of the CDF walk in emissive_select_instance(). Returns the selected
// slot and rescales the remainder within its bucket to [0,1) for the triangle
// draw. r_remap MUST span the full unit interval across a bucket or the
// triangle choice becomes correlated with the instance choice.
static bool mirror_select_instance(const std::vector<float> &p_cdf, float p_total,
		float p_u, uint32_t &r_slot, float &r_prob, float &r_remap) {
	r_slot = 0;
	r_prob = 0.0f;
	r_remap = 0.0f;
	if (!(p_total > 0.0f) || p_cdf.empty()) {
		return false;
	}
	const float target = p_u * p_total;
	float lo = 0.0f;
	for (uint32_t i = 0; i < (uint32_t)p_cdf.size(); i++) {
		const float hi = p_cdf[i];
		const float w = hi - lo;
		if (w > 0.0f && target < hi) {
			r_slot = i;
			r_prob = w / p_total;
			r_remap = CLAMP((target - lo) / w, 0.0f, 0.99999994f);
			return true;
		}
		lo = hi;
	}
	// Drift guard: fall back to the last positive-weight bucket.
	lo = 0.0f;
	for (uint32_t i = 0; i < (uint32_t)p_cdf.size(); i++) {
		const float w = p_cdf[i] - lo;
		if (w > 0.0f) {
			r_slot = i;
			r_prob = w / p_total;
			r_remap = 0.0f;
		}
		lo = p_cdf[i];
	}
	return r_prob > 0.0f;
}

TEST_CASE("[PathTracer][Emissive] qualification covers textured and coloured emitters") {
	// A texture-only emitter has emission_color forced to (1,1,1) and strength 1
	// by the C++ material fill, but qualification must not depend on that -- an
	// emitter whose colour is black and whose light comes entirely from a texture
	// must still qualify, or its energy is silently lost.
	CHECK(mirror_is_emissive(MAT_FLAG_HAS_EMISSION_TEX, Vector3(0, 0, 0), 0.0f));
	CHECK(mirror_is_emissive(0u, Vector3(1, 1, 1), 1.0f));
	CHECK_FALSE(mirror_is_emissive(0u, Vector3(1, 1, 1), 0.0f));
	CHECK_FALSE(mirror_is_emissive(0u, Vector3(0, 0, 0), 100.0f));
	// Just under and just over the 1e-4 threshold on luminance x strength.
	CHECK_FALSE(mirror_is_emissive(0u, Vector3(1, 1, 1), 5e-5f));
	CHECK(mirror_is_emissive(0u, Vector3(1, 1, 1), 5e-4f));
}

TEST_CASE("[PathTracer][Emissive] instance selection frequency matches power") {
	// Prefix sums of powers {1, 7, 0, 2}: a zero-power instance must never be
	// selected, and the rest in proportion.
	std::vector<float> cdf = { 1.0f, 8.0f, 8.0f, 10.0f };
	const float total = 10.0f;

	const int N = 100000;
	int counts[4] = { 0, 0, 0, 0 };
	for (int i = 0; i < N; i++) {
		const float u = (float(i) + 0.5f) / float(N);
		uint32_t slot = 0;
		float prob = 0.0f, remap = 0.0f;
		REQUIRE(mirror_select_instance(cdf, total, u, slot, prob, remap));
		REQUIRE(slot < 4);
		counts[slot]++;
		CHECK(prob > 0.0f);
		CHECK(remap >= 0.0f);
		CHECK(remap < 1.0f);
	}
	CHECK(counts[2] == 0);
	CHECK(float(counts[0]) / float(N) == doctest::Approx(0.1f).epsilon(0.005));
	CHECK(float(counts[1]) / float(N) == doctest::Approx(0.7f).epsilon(0.005));
	CHECK(float(counts[3]) / float(N) == doctest::Approx(0.2f).epsilon(0.005));
}

TEST_CASE("[PathTracer][Emissive] the bucket remainder spans the unit interval") {
    // If the remap does not cover [0,1), the triangle drawn from it is correlated
    // with WHICH instance was picked -- a whole region of triangles becomes
    // unreachable on some instances. Sweep one bucket and check coverage.
	std::vector<float> cdf = { 1.0f, 8.0f, 10.0f };
	const float total = 10.0f;

	float lo_seen = 1.0f, hi_seen = 0.0f;
	int in_bucket = 0;
	for (int i = 0; i < 20000; i++) {
		const float u = (float(i) + 0.5f) / 20000.0f;
		uint32_t slot = 0;
		float prob = 0.0f, remap = 0.0f;
		REQUIRE(mirror_select_instance(cdf, total, u, slot, prob, remap));
		if (slot == 1) { // the wide middle bucket
			in_bucket++;
			lo_seen = MIN(lo_seen, remap);
			hi_seen = MAX(hi_seen, remap);
		}
	}
	REQUIRE(in_bucket > 1000);
	CHECK(lo_seen < 0.01f);
	CHECK(hi_seen > 0.99f);
}

TEST_CASE("[PathTracer][Emissive] the slot table round-trips and is sized by INSTANCE count") {
	// emissive_slot[] is indexed by gl_InstanceCustomIndex, so it must be sized to
	// the FULL instance count -- not to INSTANCES_MAX. Sizing it to the emissive
	// count would read out of bounds for any scene with more instances than
	// emitters, which is every scene, and the read would not fault reliably.
	const uint32_t instance_count = 9;
	const std::vector<uint32_t> emissive_instances = { 2, 5, 8 };

	std::vector<int32_t> slots(instance_count, -1);
	for (uint32_t s = 0; s < (uint32_t)emissive_instances.size(); s++) {
		slots[emissive_instances[s]] = (int32_t)s;
	}

	CHECK(slots.size() == instance_count);
	for (uint32_t i = 0; i < instance_count; i++) {
		const bool is_emissive =
				std::find(emissive_instances.begin(), emissive_instances.end(), i) != emissive_instances.end();
		if (is_emissive) {
			REQUIRE(slots[i] >= 0);
			CHECK(emissive_instances[slots[i]] == i); // round-trips to its own slot
		} else {
			CHECK(slots[i] == -1);
		}
	}
}

TEST_CASE("[PathTracer][Emissive] an all-zero distribution selects nothing") {
	std::vector<float> cdf = { 0.0f, 0.0f };
	uint32_t slot = 99;
	float prob = -1.0f, remap = -1.0f;
	CHECK_FALSE(mirror_select_instance(cdf, 0.0f, 0.5f, slot, prob, remap));
	CHECK(prob == 0.0f);

	std::vector<float> empty;
	CHECK_FALSE(mirror_select_instance(empty, 1.0f, 0.5f, slot, prob, remap));
}
```

- [ ] **Step 3: Run to verify**

```bash
python -m SCons platform=windows tests=yes target=editor && bin/godot.windows.editor.x86_64.exe --test --test-case="*Emissive*"
```

Expected: 7 cases pass (3 from Task 2 + 4 here).

- [ ] **Step 4: Write the compute shader**

Create `servers/rendering/renderer_rd/shaders/raytracing/emissive_area_build.glsl`:

```glsl
#[compute]

#version 450

#VERSION_DEFINES

#include "raytracing_data_inc.glsl"
#include "raytracing_vertex_inc.glsl"

// Builds the emissive-instance sampling distribution for C1.
//
// Two dispatches, mirroring env_cdf_build.glsl's rows/marginal split:
//   MODE_AREA one workgroup per emissive instance; reduces the summed
//             WORLD-SPACE triangle area and writes power = luminance * area.
//   MODE_CDF  one workgroup total; prefix-sums power over <= 256 instances.
//
// World space, not object space: scaling an object-space area by s^2 is only
// valid under uniform scale, and instances routinely carry non-uniform scale.
// The transform is therefore applied per vertex, before the cross product.

#define MODE_AREA 0u
#define MODE_CDF 1u
#define EMISSIVE_MAX 256u

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

struct EmissiveInstance {
	uint geometry_index;
	uint prim_count;
	float total_area; // written by MODE_AREA
	float power; // written by MODE_AREA
	float xform[12]; // object->world, transposed 3x4
	vec3 emission;
	float _pad;
};

layout(set = 0, binding = 0, std430) restrict buffer EmissiveInstances {
	EmissiveInstance inst[];
}
emissive;

layout(set = 0, binding = 1, std430) restrict buffer EmissiveCDF {
	float total_power;
	float _pad0;
	float _pad1;
	float _pad2;
	float prefix[]; // EMISSIVE_MAX entries
}
cdf;

layout(set = 0, binding = 2, std430) readonly buffer Geometries {
	GeometryData geometries[];
};

layout(push_constant, std430) uniform Params {
	uint mode;
	uint count;
	uint pad0;
	uint pad1;
}
params;

shared float s_area[64];

mat4 unpack_xform(EmissiveInstance e) {
	// Transposed 3x4 -> column-major mat4, matching
	// MaterialStorage::store_transform_transposed_3x4 on the C++ side.
	return mat4(
			vec4(e.xform[0], e.xform[4], e.xform[8], 0.0),
			vec4(e.xform[1], e.xform[5], e.xform[9], 0.0),
			vec4(e.xform[2], e.xform[6], e.xform[10], 0.0),
			vec4(e.xform[3], e.xform[7], e.xform[11], 1.0));
}

void main() {
	if (params.mode == MODE_AREA) {
		uint slot = gl_WorkGroupID.x;
		if (slot >= params.count) {
			return;
		}
		EmissiveInstance e = emissive.inst[slot];
		GeometryData geom = geometries[e.geometry_index];
		mat4 xf = unpack_xform(e);

		float local_sum = 0.0;
		for (uint prim = gl_LocalInvocationID.x; prim < e.prim_count; prim += 64u) {
			uint i0, i1, i2;
			get_triangle_indices_ex(geom, prim, i0, i1, i2);
			vec3 p0 = (xf * vec4(rt_fetch_vertex_position(geom, i0), 1.0)).xyz;
			vec3 p1 = (xf * vec4(rt_fetch_vertex_position(geom, i1), 1.0)).xyz;
			vec3 p2 = (xf * vec4(rt_fetch_vertex_position(geom, i2), 1.0)).xyz;
			local_sum += 0.5 * length(cross(p1 - p0, p2 - p0));
		}

		s_area[gl_LocalInvocationID.x] = local_sum;
		barrier();
		for (uint s = 32u; s > 0u; s >>= 1u) {
			if (gl_LocalInvocationID.x < s) {
				s_area[gl_LocalInvocationID.x] += s_area[gl_LocalInvocationID.x + s];
			}
			barrier();
		}

		if (gl_LocalInvocationID.x == 0u) {
			float area = s_area[0];
			float lum = dot(e.emission, vec3(0.2126, 0.7152, 0.0722));
			emissive.inst[slot].total_area = area;
			emissive.inst[slot].power = max(lum, 0.0) * area;
		}
		return;
	}

	// MODE_CDF: one workgroup, serial prefix sum over <= 256 entries.
	if (gl_LocalInvocationID.x != 0u || gl_WorkGroupID.x != 0u) {
		return;
	}
	float running = 0.0;
	for (uint i = 0u; i < params.count; i++) {
		running += emissive.inst[i].power;
		cdf.prefix[i] = running;
	}
	for (uint i = params.count; i < EMISSIVE_MAX; i++) {
		cdf.prefix[i] = running;
	}
	cdf.total_power = running;
}
```

- [ ] **Step 5: Write the storage unit**

Create `servers/rendering/renderer_rd/storage_rd/emissive_lights.h` and `.cpp`, both with the Godot 29-line header. Model the class on `env_cdf.h` — same private `RID buffer/shader/pipeline`, same `dirty` flag, same `RID version` shader-version handling, same `_ensure_shader()` lazy init.

`emissive_lights.h` public surface:

```cpp
class EmissiveLights {
public:
	static constexpr uint32_t INSTANCES_MAX = 256;

	struct InstanceInput {
		uint32_t geometry_index = 0;
		uint32_t prim_count = 0;
		Transform3D xform;
		Color emission;
	};

	// Rebuilds when the token differs from the last build. The token must cover
	// the instance SET, their TRANSFORMS and their EMISSION -- see the comment in
	// the .cpp for why a single handle is not enough.
	void mark_dirty_if_token_changed(uint64_t p_token);
	void mark_dirty() { dirty = true; }

	// p_geometry_buffer is the existing RT geometry SSBO; the compute pass reads
	// vertex data through the BDA pointers inside it.
	void update(const LocalVector<InstanceInput> &p_instances, RID p_geometry_buffer,
			const LocalVector<int32_t> &p_slot_table, uint64_t p_token);

	RID get_instance_buffer() const { return instance_buffer; }
	RID get_cdf_buffer() const { return cdf_buffer; }
	RID get_slot_buffer() const { return slot_buffer; }
	uint32_t get_count() const { return count; }
	bool is_valid() const { return instance_buffer.is_valid(); }

	void free_resources();
	~EmissiveLights();
};
```

The `.cpp` carries this comment above the token check, because the failure it prevents already cost this project a day:

```cpp
// The trigger is a TOKEN over the instance set, their transforms and their
// emission -- never a single RID or handle. The environment CDF (env_cdf.cpp)
// was originally keyed on the radiance texture's RID, which is stable while its
// CONTENTS are still empty: the first build baked an all-zero distribution and
// the trigger never fired again, silently disabling sky NEE for the whole run.
```

The GPU-side twin is `alignas(16) struct EmissiveInstanceGPU`, matching the GLSL
`EmissiveInstance` field-for-field. Its std430 layout is:

| offset | member | size |
|---|---|---|
| 0 | `geometry_index` | 4 |
| 4 | `prim_count` | 4 |
| 8 | `total_area` | 4 |
| 12 | `power` | 4 |
| 16 | `xform[12]` | 48 (array stride 4) |
| 64 | `emission` (vec3, 16-byte aligned) | 12 |
| 76 | `_pad` | 4 |

Total **80 bytes**, already a multiple of the struct's 16-byte alignment:

```cpp
static_assert(sizeof(EmissiveInstanceGPU) == 80, "EmissiveInstance must be 80 bytes for std430");
static_assert(offsetof(EmissiveInstanceGPU, xform) == 16, "xform must sit at offset 16");
static_assert(offsetof(EmissiveInstanceGPU, emission) == 64, "emission is a vec3 and must be 16-byte aligned");
```

The `emission` offset assert is the load-bearing one: a `vec3` in std430 aligns to
16 bytes, so inserting any member before it that leaves the offset unaligned
shifts the GPU's view of every following field without changing `sizeof`.

- [ ] **Step 6: Gather and drive it from render_raytracing.cpp**

Add `uint32_t gather_emissive_instances(LocalVector<EmissiveLights::InstanceInput> &r_out, LocalVector<int32_t> &r_slots, uint64_t &r_token);` to `render_raytracing.h` beside `gather_lights`, and implement it next to `gather_lights` in the `.cpp`. It walks the same per-instance arrays the TLAS build produced (`geometry_data`, `material_data`, `blas_transforms` — all 1:1 per instance, *including inside the multimesh loop*), qualifies each with

```cpp
const bool textured = (mat.flags & RT_MAT_FLAG_HAS_EMISSION_TEX) != 0;
const float lum = mat.emission_color[0] * 0.2126f + mat.emission_color[1] * 0.7152f + mat.emission_color[2] * 0.0722f;
if (!textured && lum * mat.emission_strength <= 1e-4f) { continue; }
```

sorts by descending `lum * strength * <approx scale>` and keeps the top `INSTANCES_MAX`, fills `r_slots` (sized to the instance count, `-1` for non-emissive), and hashes the set, transforms and emission into `r_token`.

Gate the whole thing on `GLOBAL_GET("rendering/pathtracer/emissive_mesh_lights")` read once per frame — when false, skip the gather, skip `update()`, and bind the existing dummy buffers exactly as the `env_cdf`-invalid path already does.

- [ ] **Step 7: Bind the three buffers**

Add three bindings to the raytracing uniform set beside the existing `env_cdf` binding, following its pattern verbatim including the fallback when the feature is off.

- [ ] **Step 8: Full build, suite, commit**

```bash
python -m SCons platform=windows tests=yes target=editor
bin/godot.windows.editor.x86_64.exe --test
```

Expected: clean build, **1456 passed** (1448 baseline + 3 from Task 2 + 5 here). Report the actual number.

```bash
git add servers/rendering/renderer_rd/storage_rd/emissive_lights.h servers/rendering/renderer_rd/storage_rd/emissive_lights.cpp servers/rendering/renderer_rd/shaders/raytracing/emissive_area_build.glsl servers/rendering/renderer_rd/forward_clustered/render_raytracing.h servers/rendering/renderer_rd/forward_clustered/render_raytracing.cpp servers/rendering/rendering_server.cpp doc/classes/ProjectSettings.xml tests/servers/rendering/test_pt_emissive.cpp
git commit -m "feat(pt): emissive-instance power distribution and its GPU build (C1)"
```

---

### Task 4: Emissive NEE

**Files:**
- Create: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_emissive_inc.glsl`
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl`
- Test: `tests/servers/rendering/test_pt_emissive.cpp` (append)

**Interfaces:**
- Consumes: `rt_fetch_vertex_position` (Task 2); the three SSBOs and `RT_EMISSIVE_INSTANCES_MAX` (Task 3); `RT_PRNG_EMISSIVE_SELECT`, `RT_PRNG_EMISSIVE_POINT` (Task 1); `lights_trace_shadow_ray` (`raytracing_lights_inc.glsl`); `evalCombinedBRDFSeparate`, `combinedPdf` (`brdf_inc.glsl`); `power_heuristic` (`raytracing_inc.glsl:456`).
- Produces: `vec3 emissive_radiance(MaterialData p_mat, vec2 p_uv)`; `bool emissive_sample(vec3 p_hit_pos, vec3 p_N, vec3 p_V, MaterialProperties p_mat, RNGState p_rng, out vec3 r_contribution)`; `float emissive_pdf_solid_angle(float p_prob_inst, uint p_prim_count, float p_area_tri, float p_dist, float p_cos_light)`; and `float emissive_pdf_solid_angle_for_hit(uint p_slot, uint p_geometry_index, uint p_primitive_id, float p_dist, float p_cos_light)`, which recovers `P(inst)` from the CDF bucket at `p_slot`, computes `area_tri` from three `rt_fetch_vertex_position` calls transformed to world space, and forwards to the base form. Task 5 calls the `_for_hit` variant.

- [ ] **Step 1: Write the failing tests for the pdf and the measure conversion**

Append inside `namespace TestPTEmissive`:

```cpp
// Mirror of emissive_pdf_solid_angle(). pdf_A = P(inst) * (1/prim_count) * (1/area_tri),
// then converted to the solid-angle measure the BSDF pdf lives in.
static float mirror_pdf_solid_angle(float p_prob_inst, uint32_t p_prim_count,
		float p_area_tri, float p_dist, float p_cos_light) {
	if (p_prim_count == 0 || p_area_tri <= 0.0f || p_cos_light <= 0.0f) {
		return 0.0f;
	}
	const float pdf_a = p_prob_inst * (1.0f / float(p_prim_count)) * (1.0f / p_area_tri);
	return pdf_a * (p_dist * p_dist) / p_cos_light;
}

TEST_CASE("[PathTracer][Emissive] the area pdf composes and normalises") {
	// Two instances, 4 and 1 triangles, all of unit area. Summing
	// P(inst) * P(tri|inst) * area over every triangle must give exactly 1.
	const float probs[2] = { 0.3f, 0.7f };
	const uint32_t prims[2] = { 4, 1 };
	float total = 0.0f;
	for (int i = 0; i < 2; i++) {
		for (uint32_t t = 0; t < prims[i]; t++) {
			const float pdf_a = probs[i] * (1.0f / float(prims[i])) * (1.0f / 1.0f);
			total += pdf_a * 1.0f; // integrate the density over the triangle's area
		}
	}
	CHECK(total == doctest::Approx(1.0f));
}

TEST_CASE("[PathTracer][Emissive] grazing angles INFLATE the solid-angle pdf") {
	// pdf_omega = pdf_A * d^2 / cos. A sign or reciprocal slip here is invisible
	// head-on (cos == 1) and only shows at grazing angles, so test there.
	const float head_on = mirror_pdf_solid_angle(1.0f, 1, 1.0f, 2.0f, 1.0f);
	const float grazing = mirror_pdf_solid_angle(1.0f, 1, 1.0f, 2.0f, 0.05f);
	CHECK(head_on == doctest::Approx(4.0f));
	CHECK(grazing > head_on);
	CHECK(grazing == doctest::Approx(4.0f / 0.05f));
}

TEST_CASE("[PathTracer][Emissive] distance enters the pdf quadratically") {
	const float near_pdf = mirror_pdf_solid_angle(1.0f, 1, 1.0f, 1.0f, 1.0f);
	const float far_pdf = mirror_pdf_solid_angle(1.0f, 1, 1.0f, 3.0f, 1.0f);
	CHECK(far_pdf == doctest::Approx(near_pdf * 9.0f));
}

TEST_CASE("[PathTracer][Emissive] a back-facing sample contributes nothing") {
	// Front-face-only, matching lights_eval_rect_light's cos_theta <= 1e-5 reject.
	CHECK(mirror_pdf_solid_angle(1.0f, 1, 1.0f, 2.0f, 0.0f) == 0.0f);
	CHECK(mirror_pdf_solid_angle(1.0f, 1, 1.0f, 2.0f, -0.5f) == 0.0f);
}

TEST_CASE("[PathTracer][Emissive] a degenerate or empty instance yields no pdf") {
	CHECK(mirror_pdf_solid_angle(1.0f, 0, 1.0f, 2.0f, 1.0f) == 0.0f);
	CHECK(mirror_pdf_solid_angle(1.0f, 4, 0.0f, 2.0f, 1.0f) == 0.0f);
}
```

- [ ] **Step 2: Run to verify**

```bash
python -m SCons platform=windows tests=yes target=editor && bin/godot.windows.editor.x86_64.exe --test --test-case="*Emissive*"
```

Expected: 12 cases pass.

- [ ] **Step 3: Write the emissive sampling header**

Create `servers/rendering/renderer_rd/shaders/raytracing/raytracing_emissive_inc.glsl` containing:

`emissive_radiance(mat, uv)` — the **single shared** composition of emitted radiance:

```glsl
/// THE one place emitted radiance is composed. Both the NEE site and the
/// emissive-hit site call this.
///
/// It is shared rather than duplicated because m.emissive is NOT just
/// emission_color * emission_strength -- every composition site in
/// scene_raytracing_raygen.glsl also multiplies by
/// scene_data_block.data.emissive_exposure_normalization. If NEE and the BSDF
/// hit composed emission differently, the two MIS strategies would estimate
/// different integrands while sharing a weight required to sum to 1 -- which is
/// structurally the defect behind B2's open +2.4% converged-mean shift.
vec3 emissive_radiance(MaterialData p_mat, vec2 p_uv) {
	vec3 e;
	if ((p_mat.flags & 2u) != 0u) { // RT_MAT_FLAG_HAS_EMISSION_TEX
		e = sample_material_texture(p_mat.emission_texture_idx, p_uv, p_mat.flags).rgb * p_mat.emission_color * p_mat.emission_strength;
	} else {
		e = p_mat.emission_color * p_mat.emission_strength;
	}
	return e * scene_data_block.data.emissive_exposure_normalization;
}
```

`emissive_pdf_solid_angle(...)` — mirroring `mirror_pdf_solid_angle` exactly, including both zero guards.

`emissive_sample(...)` — draws `u = rng_1d(p_rng, RT_PRNG_EMISSIVE_SELECT)`, selects the instance and remaps the remainder (mirroring `mirror_select_instance`), picks `tri = min(uint(remap * prim_count), prim_count - 1u)`, draws `rng_2d(p_rng, RT_PRNG_EMISSIVE_POINT)` and warps it to barycentrics with `su = sqrt(u.x); b = vec3(1 - su, su * (1 - u.y), su * u.y)`, builds the world point and geometric normal from `rt_fetch_vertex_position`, rejects on `cos_light <= 1e-5` and on `dot(p_N, L) <= 0.0`, traces the shadow ray to exactly `dist` via `lights_trace_shadow_ray`, and returns

```
contribution = brdf * emissive_radiance(...) * power_heuristic(pdf_omega, combinedPdf(N, L, V, mat)) / pdf_omega
```

**Order matters:** both cheap rejections come *before* the shadow ray, matching the ordering fix already applied to the positional analytic-light branch.

- [ ] **Step 4: Wire the NEE block in**

**The enable is a new specialization-constant flag bit.** Environment NEE has no
enable to copy — it is unconditional, guarded only by `env_sample()` returning
false — so this is new. Bits 0-3 are feature flags, bits 4-8 are B4's
`min_bounce`, and bits 9-19 are free, so in
`forward_clustered/scene_shader_raytracing.h`:

```cpp
RT_FLAG_EMISSIVE_LIGHTS_ENABLED = (1 << 9),
```

**Add it to the existing `static_assert` at `scene_shader_raytracing.h:107`** —
that assert exists to prove no feature flag has encroached on the `min_bounce`
field, and a new flag left out of its list is exactly what it cannot catch:

```cpp
static_assert(((RT_FLAG_DEBUG_VIS_ENABLED | RT_FLAG_DLSS_RR_ENABLED | RT_FLAG_FOG_ENABLED | RT_FLAG_SER_ENABLED | RT_FLAG_EMISSIVE_LIGHTS_ENABLED) & (RT_MIN_BOUNCE_MASK << RT_MIN_BOUNCE_SHIFT)) == 0,
        "RT_FLAG_* bit overlaps the Russian Roulette min_bounce field (bits 4-8)");
```

Set it in `compute_rt_flags` from the once-per-frame `GLOBAL_GET` read, and add
the GLSL accessor beside `RT_GET_MIN_BOUNCE()` in `raytracing_common_inc.glsl`:

```glsl
#define RT_FLAG_EMISSIVE_LIGHTS_ENABLED 512u // 1 << 9
#define RT_GET_EMISSIVE_ENABLED() ((RT_FLAGS & RT_FLAG_EMISSIVE_LIGHTS_ENABLED) != 0u)
```

Then in `raytracing_closest_hit_common_inc.glsl`, after the environment-NEE
block, add an emissive-NEE block guarded by `RT_GET_EMISSIVE_ENABLED()`,
accumulating with `clamp_contribution(ps.throughput * emissive_direct, clamp_limit)`
to match the neighbouring blocks.

- [ ] **Step 5: Build, suite, commit**

```bash
python -m SCons platform=windows tests=yes target=editor && bin/godot.windows.editor.x86_64.exe --test
```

Expected: clean, no regressions. **The image should now be brighter with the setting on — that is the double-count Task 5 removes.** Note the value; it is evidence for Task 5.

```bash
git add servers/rendering/renderer_rd/shaders/raytracing/raytracing_emissive_inc.glsl servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl tests/servers/rendering/test_pt_emissive.cpp
git commit -m "feat(pt): next-event estimation for emissive meshes (C1)"
```

---

### Task 5: MIS against the BSDF hit

**Files:**
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl`
- Test: `tests/servers/rendering/test_pt_emissive.cpp` (append)

**Interfaces:**
- Consumes: `emissive_pdf_solid_angle`, `emissive_radiance` (Task 4); `emissive_slot[]` (Task 3); `power_heuristic`, `RT_MIS_PDF_NONE` (`raytracing_inc.glsl:64,456`); `ps.mis_ray_pdf` (`raytracing_inc.glsl:57`).

- [ ] **Step 1: Write the failing tests for the partition**

Append inside `namespace TestPTEmissive`:

```cpp
// Mirror of power_heuristic (raytracing_inc.glsl).
static float mirror_power_heuristic(float p_a, float p_b) {
	const float a2 = p_a * p_a;
	const float b2 = p_b * p_b;
	const float d = a2 + b2;
	return (d > 0.0f) ? (a2 / d) : 0.0f;
}

TEST_CASE("[PathTracer][Emissive] the MIS partition sums to exactly one") {
	// Both halves must be formed from the SAME two pdfs in the SAME measure, or
	// the emissive surface is counted twice (sum > 1) or dimmed (sum < 1).
	const float pairs[6][2] = {
		{ 1.0f, 1.0f }, { 0.001f, 5.0f }, { 5.0f, 0.001f },
		{ 1e-6f, 1e6f }, { 3.7f, 0.42f }, { 100.0f, 100.0f }
	};
	for (const auto &p : pairs) {
		const float w_nee = mirror_power_heuristic(p[0], p[1]);
		const float w_bsdf = mirror_power_heuristic(p[1], p[0]);
		CHECK(w_nee + w_bsdf == doctest::Approx(1.0f));
	}
}

TEST_CASE("[PathTracer][Emissive] an unreachable strategy takes the whole weight") {
	// A near-delta specular bounce carries RT_MIS_PDF_NONE and must not be
	// weighted down against a strategy that could not have produced it. Modelled
	// here as the sentinel path: weight 1, unconditionally.
	const float light_pdf = 12.5f;
	const float bsdf_pdf_sentinel = -1.0f; // RT_MIS_PDF_NONE
	const float w = (bsdf_pdf_sentinel < 0.0f) ? 1.0f : mirror_power_heuristic(bsdf_pdf_sentinel, light_pdf);
	CHECK(w == doctest::Approx(1.0f));
}

TEST_CASE("[PathTracer][Emissive] a zero light pdf hands the BSDF full weight") {
	// Where emissive NEE cannot reach (back face, degenerate triangle), its pdf
	// is 0 and the BSDF half must collect the whole contribution -- otherwise the
	// energy is deleted rather than redistributed.
	CHECK(mirror_power_heuristic(4.2f, 0.0f) == doctest::Approx(1.0f));
	CHECK(mirror_power_heuristic(0.0f, 4.2f) == doctest::Approx(0.0f));
}
```

- [ ] **Step 2: Run to verify**

```bash
python -m SCons platform=windows tests=yes target=editor && bin/godot.windows.editor.x86_64.exe --test --test-case="*Emissive*"
```

Expected: 15 cases pass.

- [ ] **Step 3: Weight the emissive hit**

In `raytracing_closest_hit_common_inc.glsl`, replace the unconditional emissive accumulation:

```glsl
	ps.radiance += clamp_contribution(ps.throughput * m.emissive, clamp_limit);
```

with a weighted form. When the feature is off, or `ps.mis_ray_pdf` is `RT_MIS_PDF_NONE`, or this instance is not emissive (`emissive_slot[gl_InstanceCustomIndex] < 0`), the weight is `1.0` and the line behaves exactly as before. Otherwise:

```glsl
	// This surface is reachable by BOTH strategies, so its contribution must be
	// split by a weight that sums to 1 with emissive NEE's. Without this every
	// glowing surface is counted twice -- the identical defect C3 fixed for the
	// sky. The sentinel cases above take weight 1 on purpose: a camera ray and a
	// near-delta specular bounce are unreachable by NEE, so there is no second
	// strategy to share with and weighting them down would delete energy.
	float w_mis = 1.0;
	int slot = emissive_slot[gl_InstanceCustomIndex];
	if (RT_GET_EMISSIVE_ENABLED() && slot >= 0 && ps.mis_ray_pdf > 0.0) {
		float cos_light = max(dot(-gl_WorldRayDirectionEXT, h.geometry_normal), 0.0);
		float light_pdf = emissive_pdf_solid_angle_for_hit(uint(slot), gl_InstanceCustomIndex,
				gl_PrimitiveID, gl_HitTEXT, cos_light);
		w_mis = power_heuristic(ps.mis_ray_pdf, light_pdf);
	}
	ps.radiance += clamp_contribution(ps.throughput * m.emissive * w_mis, clamp_limit);
```

`emissive_pdf_solid_angle_for_hit` recovers `P(inst)` from the CDF bucket at `slot`, computes `area_tri` from three `rt_fetch_vertex_position` calls transformed to world space, and calls `emissive_pdf_solid_angle`.

- [ ] **Step 4: Build, suite, commit**

```bash
python -m SCons platform=windows tests=yes target=editor && bin/godot.windows.editor.x86_64.exe --test
```

Expected: clean, no regressions.

```bash
git add servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl tests/servers/rendering/test_pt_emissive.cpp
git commit -m "feat(pt): MIS-combine emissive NEE against BSDF hits (C1)"
```

---

### Task 6: Gates, measurement, closeout

**Files:**
- Create: `pipeline_references/tests/pt_emissive_gate.gd` + `pt_emissive_gate_scene.tscn`
- Create: `pipeline_references/tests/pt_emissive_rmse.gd` + `pt_emissive_rmse_scene.tscn`
- Modify: `PATH_TRACER_QUALITY_ROADMAP.md`

**Read first:** `pipeline_references/tests/pt_light_gate.gd` and `pt_light_rmse.gd`. Both extend `res://tests/pt_validation.gd`. Follow their structure for accumulation, EXR readback, env-var config and reporting. Do not invent a new harness shape.

**Never invent a number.** If a render will not run, report what you observed and return `DONE_WITH_CONCERNS`. Numbers that were not measured are worse than no numbers, because nobody can tell them apart later.

- [ ] **Step 1: Build the gate scenes**

`pt_emissive_gate.gd`, driven by `ZR_EMIS_GATE_MODE` (`invariance` | `analytic` | `sampler` | `all`, default `all`) and `ZR_EMIS_FRAMES` (default 2048).

Scene: a Lambertian room with real occluders, lit **only** by an emissive quad. No sky (`BG_COLOR` black), no analytic lights — so every photon in the image came through emissive sampling or a BSDF ray that found the panel.

```gdscript
func _build_emitter(root: Node3D) -> void:
	# One emissive quad, front face pointing down into the room. Front-face-only
	# emission is deliberate and matches lights_eval_rect_light, so the quad's
	# orientation is load-bearing: flipped, the room goes black.
	var panel := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(2.0, 2.0)
	panel.mesh = quad
	panel.position = Vector3(0.0, 3.5, 0.0)
	panel.rotation_degrees = Vector3(90.0, 0.0, 0.0)
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0, 0, 0)
	m.emission_enabled = true
	m.emission = Color(1.0, 1.0, 1.0)
	m.emission_energy_multiplier = 40.0
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	panel.material_override = m
	root.add_child(panel)
```

- [ ] **Step 2: Gate 1 — MIS invariance**

Render the scene twice, `rendering/pathtracer/emissive_mesh_lights` off then on, at `ZR_EMIS_FRAMES`.

**Assert the converged means agree within 1%.** Both are unbiased estimators of the same integral, so this must hold. `~2x` means the emissive hit is not being MIS-weighted (Task 5 failed); materially low means energy is being deleted.

**Also assert per-pixel std-dev is strictly LOWER with the feature on.** Equal means alone are also satisfied by an NEE block that never fires — exactly the hole C3's constant-sky gate shipped with, where only a variance probe distinguished a working implementation from an inert one. Report both numbers either way.

- [ ] **Step 3: Gate 2 — analytic**

An emissive quad of area `A` and radiance `L` directly above an unoccluded Lambertian patch of albedo `ρ`, both facing each other, camera looking straight down. For a patch small relative to its distance `d`, the irradiance is `E ≈ L · A · cosθ₁ · cosθ₂ / d²` and the reflected radiance is `L_o = ρ · E / π`.

Print the measured value beside the closed-form one and assert agreement within 2% (the small-patch approximation is not exact; the tolerance covers it). Record the exact geometry used so the number is reproducible.

- [ ] **Step 4: Gate 3 — sampler-widening neutrality**

With `rendering/pathtracer/emissive_mesh_lights` **off**, the converged mean of an existing scene must not have moved when `RT_PRNG_BOUNCE_NUM` went 8 → 16 (Task 1).

Run `pt_light_gate_scene.tscn`'s `in_range` mode and compare against the reference values recorded in that file. A shift here is Task 1's problem, not C1's — which is exactly why it is measured separately.

- [ ] **Step 5: Liveness probe**

Before recording any figure, confirm the off and on runs produce *different* numbers on a configuration where they must.

**Gate 1 asserts the means are equal, so the mean cannot be the probe.** Use the per-pixel spread from Step 2. If both runs read identical spread, the setting never reached the shader — most likely a stale `.glsl.gen.h`. Re-run a full build and re-check before proceeding. In B4 a `git stash` on an already-committed path silently no-opped and one measurement compared a build against itself.

- [ ] **Step 6: Measurement**

`pt_emissive_rmse.gd` + scene: RMSE against a converged reference, per-sample and equal-time, plus frame-time delta, following `pt_light_rmse.gd`'s sweep structure.

**Two emitter sizes**, because the BSDF-only control degrades fastest as the emitter shrinks and a large-panel-only measurement would understate the win: `ZR_EMIS_SIZE=large` (2.0 m quad) and `ZR_EMIS_SIZE=small` (0.25 m quad). Report both.

Report equal-time as a **range across the whole sweep**, floor taken from the sweep's own minimum. A previous phase quoted an equal-time headline from a favourable subset and had to correct it afterwards.

**Accept:** *"a room lit only by a glowing panel converges clean; no hotspot speckle"* — read as equal-time RMSE materially lower with the feature on, and gate 1's means agreeing.

- [ ] **Step 7: Write the report**

`.superpowers/sdd/2026-08-12-emissive-mesh-lights/task-6-report.md`: full method, every number, the liveness evidence, all three gate results, both emitter sizes, frame-time delta, and an explicit limits section (single scene, quad emitters only, no textured-emissive rendered coverage, uniform-triangle selection untested against a deliberately uneven tessellation).

- [ ] **Step 8: Update the roadmap**

1. Rewrite the **C1** entry as done, with measured figures and a pointer to the report, following the C2 and C3 entries' shape.
2. **Mark Phase C complete** (C1, C2, C3 all landed) and update the ordering summary — the next item is Phase D.
3. Record the open items: the fixture double-representation in `image_glb_creation.gd` (documented in the spec §2.1, still unaddressed in the pipeline); no per-triangle area weighting; no rendered coverage of textured emissives; and that the setting ships default-off so the feature is only exercised when deliberately enabled.

- [ ] **Step 9: Full suite and commit**

```bash
bin/godot.windows.editor.x86_64.exe --test
git add pipeline_references/tests/ PATH_TRACER_QUALITY_ROADMAP.md .superpowers/sdd/2026-08-12-emissive-mesh-lights/
git commit -m "test(pt): gates and measurement for emissive-mesh lights, close out C1"
```

---

## Notes for reviewers

Four things to check hard, drawn from what actually went wrong in B2, B4, C2 and C3:

1. **Is `emissive_radiance` genuinely the only place emitted radiance is composed?** If the NEE site and the emissive-hit site each build it, they will drift, and the two MIS strategies will estimate different integrands while sharing a weight required to sum to 1. That is the mechanism behind B2's still-open +2.4% shift.
2. **Does gate 1 assert BOTH equal means and lower spread?** Equal means alone are satisfied by an NEE block that never fires. C3 shipped exactly that gate and only a variance probe caught it.
3. **Does every test input dimension go non-extremal somewhere?** The pdf is a product of four factors; a suite where `cos_light` is always 1 or `area_tri` always 1 pins only the others. Three separate blind spots of this shape got through earlier phases with correct assertions and inadequate data.
4. **Is the `emissive_slot` lookup bounds-safe?** It is indexed by `gl_InstanceCustomIndex` and must be sized to the full instance count, not to `INSTANCES_MAX`. Reading past it is undefined behaviour that will not reproduce reliably.
