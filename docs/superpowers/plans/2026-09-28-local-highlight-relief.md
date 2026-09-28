# Local Highlight Relief Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Recover texture in blown sun patches on daylight stills by compressing highlights *locally* — gently, and only on frames that measurably need it — without moving midtones or touching the tone curve.

**Architecture:** The decision is a pure GDScript function over samples the exposure probe already collects (no extra render, unit-testable with no GPU). It writes one float to a project setting. The engine reads that float and, only when it is non-zero, dispatches a new compute pass between the OIDN denoise and the tone curve: it blurs luminance at 1/16 resolution and divides the colour by a smooth gain derived from it. Because the divisor is smooth, high-frequency detail survives while the whole patch slides down AgX's curve.

**Tech Stack:** GDScript (Godot 4.7 fork), C++ + GLSL compute (RendererRD effects), doctest for nothing here (the decision is tested in GDScript), the `pt_*_gate` harness for rendered checks, Python + PIL for crops.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-09-28-local-highlight-relief-design.md`. Every constant and bar below is copied from it. If a measurement contradicts the spec, stop and record it — do not "fix" the constant.
- Build: `python -m SCons platform=windows target=editor arch=x86_64 d3d12=no tests=yes -j8` from the repo root. Bare `scons` is NOT on PATH and its failure exits 0 under Bash. A `.glsl` or new `.cpp` in `servers/` needs this full build.
- **The build performs NO GLSL validation** — no glslang runs. A clean build proves nothing about a shader; only a render does.
- Gates: `bin/godot.windows.editor.x86_64.console.exe --rendering-driver vulkan --path pipeline_references res://tests/<gate>_scene.tscn`. Exit 0 = PASS, 1 = FAIL. Never `--headless` (it disables rendering). Render gates at 256×256 — an FHD frame is one ~8 s GPU submission and Windows' TdrDelay is 8 s.
- Gates must disable project AA explicitly (`msaa_3d`, `screen_space_aa`, `use_taa`, `use_debanding` are all on by default in `pipeline_references`), or they measure the AA instead of the engine.
- Colour properties are sRGB-encoded: a LINEAR albedo of 0.5 must be authored `Color(0.5,0.5,0.5).linear_to_srgb()`.
- The live pipeline is `C:\Zlendo2026\ZlenderRender_stage_copy\`; its project is `godot_project\`, its exes `godot\bin\`. `pipeline_references/*.gd` and `godot_project/*.gd` are mirrored copies — a change to one must be copied to the other, verified with `diff -q`.
- Scratchpad `S` = `C:/Users/aiadmin/AppData/Local/Temp/claude/C--Users-aiadmin-Desktop-Engine-Build-test-Zreal-Engine/b37a70cf-2a76-48f2-b7de-63b1ab2399c1/scratchpad`; use `$S/relief/`. The Blender EXR→PFM converter is `$S/portal/exr2pfm.py`.
- Commits: one per task, trailer `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`. Never `--no-verify`. `git add` by explicit file name — NEVER `git add -A`.
- **Bars are measurements plus a stated margin, never design targets.** H1's 40% is the exception and is not negotiable downward: if the first measurement cannot reach it, that is a design failure to report, not a bar to lower.

---

## File structure

| File | Responsibility |
|---|---|
| `pipeline_references/daylight.gd` (modify) | `highlight_relief()` + its three constants. The whole decision; pure, no GPU. |
| `pipeline_references/tests/daylight_unit.gd` (modify) | Unit checks for that function. |
| `pipeline_references/render.gd` (modify) | Calls it after the probe, writes the project setting. Still route only. |
| `servers/rendering/rendering_server.cpp` (modify) | Two `GLOBAL_DEF`s. |
| `servers/rendering/renderer_rd/shaders/effects/local_highlight.glsl` (create) | Two compute modes: luminance downsample, and apply-gain. |
| `servers/rendering/renderer_rd/effects/local_highlight.{h,cpp}` (create) | The pass. Owns its shader, pipelines and scratch texture. Knows nothing about daylight. |
| `servers/rendering/renderer_rd/forward_clustered/render_forward_clustered.{h,cpp}` (modify) | Owns one instance; one gated dispatch after `copy_output_texture`. |
| `pipeline_references/tests/pt_highlight_relief_gate.gd` + `_scene.tscn` (create) | H0–H4. |

---

### Task 1: The decision, in GDScript

**Files:**
- Modify: `pipeline_references/daylight.gd`
- Modify: `pipeline_references/tests/daylight_unit.gd`

**Interfaces:**
- Consumes: `Daylight._percentile` (already in the file).
- Produces: `Daylight.highlight_relief(p_samples: PackedFloat32Array, p_exposure: float) -> Dictionary` returning keys `needed` (bool), `strength` (float), `clipped_fraction` (float); constants `RELIEF_KNEE`, `RELIEF_MIN_FRACTION`, `RELIEF_MAX_STRENGTH`.

- [ ] **Step 1: Write the failing unit checks**

Append to `pipeline_references/tests/daylight_unit.gd`, inside `_init()` before the final summary print:

```gdscript
	print("\n=== daylight_unit: highlight_relief ===")
	# R1: nothing above the knee -> no relief, and strength EXACTLY 0.0.
	var flat := PackedFloat32Array()
	for i in range(1000):
		flat.append(0.01)
	var r_flat := Daylight.highlight_relief(flat, 18.0) # 0.01 * 18 = 0.18, middle grey
	_check_true("R1 flat frame needs no relief", not r_flat["needed"])
	_check("R1 flat strength is exactly zero", r_flat["strength"], 0.0, 1e-9)
	_check("R1 flat clipped fraction", r_flat["clipped_fraction"], 0.0, 1e-9)

	# R2: a 10% blown patch far above the knee -> relief, strength > 0.
	var patch := PackedFloat32Array()
	for i in range(900):
		patch.append(0.01)
	for i in range(100):
		patch.append(1.0) # 1.0 * 18 = 18, well past the knee
	var r_patch := Daylight.highlight_relief(patch, 18.0)
	_check_true("R2 blown frame needs relief", r_patch["needed"])
	_check_true("R2 strength positive", r_patch["strength"] > 0.0, "(%.4f)" % r_patch["strength"])
	_check("R2 clipped fraction 0.10", r_patch["clipped_fraction"], 0.10, 1e-6)

	# R3: strength grows with how far past the knee the highlights sit.
	var hotter := PackedFloat32Array()
	for i in range(900):
		hotter.append(0.01)
	for i in range(100):
		hotter.append(4.0)
	var r_hot := Daylight.highlight_relief(hotter, 18.0)
	_check_true("R3 strength grows with excess", r_hot["strength"] > r_patch["strength"],
			"(%.4f vs %.4f)" % [r_hot["strength"], r_patch["strength"]])

	# R4: strength is capped.
	var extreme := PackedFloat32Array()
	for i in range(500):
		extreme.append(0.01)
	for i in range(500):
		extreme.append(1000.0)
	var r_ext := Daylight.highlight_relief(extreme, 18.0)
	_check_true("R4 strength capped at RELIEF_MAX_STRENGTH",
			r_ext["strength"] <= Daylight.RELIEF_MAX_STRENGTH + 1e-6,
			"(%.4f, cap %.4f)" % [r_ext["strength"], Daylight.RELIEF_MAX_STRENGTH])

	# R5: the gate boundary does not step -- just under the threshold is off,
	# just over is on with a SMALL strength, not a jump to full.
	var n_just_under: int = int(floor(Daylight.RELIEF_MIN_FRACTION * 1000.0)) - 1
	var under := PackedFloat32Array()
	for i in range(1000 - n_just_under):
		under.append(0.01)
	for i in range(n_just_under):
		under.append(1.0)
	var r_under := Daylight.highlight_relief(under, 18.0)
	_check_true("R5 just under the gate is off", not r_under["needed"])
	_check("R5 just under has zero strength", r_under["strength"], 0.0, 1e-9)

	# R6: degenerate inputs never crash and never ask for relief.
	var r_empty := Daylight.highlight_relief(PackedFloat32Array(), 18.0)
	_check_true("R6 empty samples -> no relief", not r_empty["needed"] and r_empty["strength"] == 0.0)
	var r_zero_exp := Daylight.highlight_relief(patch, 0.0)
	_check_true("R6 zero exposure -> no relief", not r_zero_exp["needed"] and r_zero_exp["strength"] == 0.0)
```

- [ ] **Step 2: Run them and watch them fail**

```bash
cd "C:/Users/aiadmin/Desktop/Engine_Build_test/Zreal_Engine" && bin/godot.windows.editor.x86_64.console.exe --headless --path pipeline_references -s res://tests/daylight_unit.gd 2>&1 | grep -v "signed by NVIDIA" | grep -E "R[1-6]|checks|SCRIPT|ERROR" | head -20
```

Expected: a parse or "invalid call" error naming `highlight_relief`. Note `--headless` IS correct here — this script renders nothing.

Warning from prior work on this file: a failed `assert()` inside `daylight.gd` stalls this invocation silently (no output, no exit). If it prints nothing for about a minute, it is stalled, not slow — kill it and check the asserts.

- [ ] **Step 3: Implement it**

In `pipeline_references/daylight.gd`, add beside the other constants:

```gdscript
## Local highlight relief (spec 2026-09-28-local-highlight-relief-design.md).
##
## RELIEF_KNEE is in POST-EXPOSURE linear units, the same units the tone curve
## sees. AgX's crossover is 0.18 (middle grey) and its white is 16.29, so a
## sample at 4.0 is already deep in the shoulder and heading for the ceiling
## while one at 1.0 still has room. 4.0 leaves normal bright surfaces --
## a white wall at 0.18, a lamp shade at 1-2 -- completely untouched.
const RELIEF_KNEE := 4.0
## Below this fraction of samples past the knee, do nothing at all: the pass is
## not dispatched and the render is byte-identical to a build without this
## feature. Job 201 measured 4.17% of the FRAME clipped, and its sun patch is
## the case this exists for; 0.01 is well under that and well over the stray
## specular highlight that should not trigger a whole-frame operation.
const RELIEF_MIN_FRACTION := 0.01
## Cap on the gain exponent. At strength s the gain at luminance L is
## 1/(1 + s*(L/knee - 1)), so s = 1.0 halves the gain one knee past the knee.
## Capped so a pathological frame cannot drive the image to black.
const RELIEF_MAX_STRENGTH := 1.0
```

and the function, next to `stats()`:

```gdscript
## How much local highlight relief this frame needs, from the SAME samples the
## exposure probe already collected -- no extra render.
##
## Returns {needed: bool, strength: float, clipped_fraction: float}.
## `needed` false always pairs with `strength` EXACTLY 0.0, which is the
## contract the engine's gate relies on: at 0.0 the pass is never dispatched.
##
## strength is driven by the MEDIAN excess of the over-knee samples, not their
## maximum: one runaway firefly must not set the strength for the whole frame.
static func highlight_relief(p_samples: PackedFloat32Array, p_exposure: float) -> Dictionary:
	var off := {"needed": false, "strength": 0.0, "clipped_fraction": 0.0}
	if p_samples.is_empty() or not (p_exposure > 0.0):
		return off
	var over := PackedFloat32Array()
	for v in p_samples:
		var e := v * p_exposure
		if e > RELIEF_KNEE:
			over.append(e)
	var fraction := float(over.size()) / float(p_samples.size())
	if fraction < RELIEF_MIN_FRACTION:
		return {"needed": false, "strength": 0.0, "clipped_fraction": fraction}
	over.sort()
	var median_excess: float = _percentile(over, 0.5) / RELIEF_KNEE - 1.0
	# A median excess of one knee (i.e. 2x the knee) asks for half strength;
	# it saturates smoothly rather than stepping at any particular value.
	var strength: float = RELIEF_MAX_STRENGTH * (median_excess / (median_excess + 1.0))
	return {
		"needed": true,
		"strength": clampf(strength, 0.0, RELIEF_MAX_STRENGTH),
		"clipped_fraction": fraction,
	}
```

- [ ] **Step 4: Run them and watch them pass**

Same command as Step 2. Expected: every `R1`–`R6` line PASS, and the suite's existing checks still pass (the file's summary line should report zero failures).

- [ ] **Step 5: Mirror and commit**

```bash
cd "C:/Users/aiadmin/Desktop/Engine_Build_test/Zreal_Engine" && cp pipeline_references/daylight.gd "C:/Zlendo2026/ZlenderRender_stage_copy/godot_project/daylight.gd" && diff -q pipeline_references/daylight.gd "C:/Zlendo2026/ZlenderRender_stage_copy/godot_project/daylight.gd" && git add pipeline_references/daylight.gd pipeline_references/tests/daylight_unit.gd && git commit -m "$(cat <<'EOF'
feat(pipeline): daylight.highlight_relief -- decide local highlight relief from the probe's own samples

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: The compute pass, with nothing calling it yet

**Files:**
- Create: `servers/rendering/renderer_rd/shaders/effects/local_highlight.glsl`
- Create: `servers/rendering/renderer_rd/effects/local_highlight.h`
- Create: `servers/rendering/renderer_rd/effects/local_highlight.cpp`

**Interfaces:**
- Produces: `RendererRD::LocalHighlight`, constructed with no arguments, with
  `void process(Ref<RenderSceneBuffersRD> p_render_buffers, float p_strength, float p_exposure, float p_knee, bool p_debug)`.
- Consumes: nothing from Task 1 (the engine side is independent of the GDScript side until Task 3).

Nothing dispatches this yet, so after this task the binary renders exactly as before. That is deliberate: it separates "does it build and is the maths right" from "does it change the image".

- [ ] **Step 1: Write the shader**

`servers/rendering/renderer_rd/shaders/effects/local_highlight.glsl`:

```glsl
#[compute]

#version 450

#VERSION_DEFINES

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// Mode DOWNSAMPLE: read the colour buffer, write mean luminance at 1/16.
// Mode APPLY: read the blurred luminance, multiply the colour buffer by the gain.

layout(push_constant, std430) uniform Params {
	ivec2 src_size;
	ivec2 dst_size;
	float strength;
	float exposure;
	float knee;
	uint debug;
}
params;

#ifdef MODE_DOWNSAMPLE
layout(set = 0, binding = 0) uniform sampler2D source_color;
layout(rgba16f, set = 0, binding = 1) uniform restrict writeonly image2D dest_luma;
#endif

#ifdef MODE_APPLY
layout(set = 0, binding = 0) uniform sampler2D source_luma;
layout(rgba16f, set = 0, binding = 1) uniform restrict image2D dest_color;
#endif

float luminance(vec3 c) {
	return dot(c, vec3(0.2126, 0.7152, 0.0722));
}

void main() {
	ivec2 pos = ivec2(gl_GlobalInvocationID.xy);

#ifdef MODE_DOWNSAMPLE
	if (any(greaterThanEqual(pos, params.dst_size))) {
		return;
	}
	// One bilinear tap per source texel covered, averaged. The destination is
	// 1/16 the source, so a 4x4 grid of bilinear taps averages the 16x16 source
	// footprint -- a wide box, which is what suppresses halos. Sampling in
	// normalised coordinates keeps this correct for any non-multiple size.
	vec2 dst_texel = (vec2(pos) + 0.5) / vec2(params.dst_size);
	vec2 src_step = 1.0 / vec2(params.src_size);
	float acc = 0.0;
	for (int y = -2; y <= 1; y++) {
		for (int x = -2; x <= 1; x++) {
			vec2 uv = dst_texel + vec2(float(x) + 0.5, float(y) + 0.5) * 4.0 * src_step;
			acc += luminance(textureLod(source_color, uv, 0.0).rgb);
		}
	}
	imageStore(dest_luma, pos, vec4(acc / 16.0, 0.0, 0.0, 1.0));
#endif

#ifdef MODE_APPLY
	if (any(greaterThanEqual(pos, params.src_size))) {
		return;
	}
	// The blurred luminance is read with a bilinear sampler at the pixel's own
	// normalised position, so the 1/16 map is smoothly upsampled -- no blocky
	// gain field. THE DIVISOR MUST STAY SMOOTH: that is what preserves the
	// patch's own texture while moving the patch as a whole down the curve.
	vec2 uv = (vec2(pos) + 0.5) / vec2(params.src_size);
	float lb = textureLod(source_luma, uv, 0.0).r * params.exposure;
	float excess = max(0.0, lb / params.knee - 1.0);
	float gain = 1.0 / (1.0 + params.strength * excess);

	if (params.debug != 0u) {
		imageStore(dest_color, pos, vec4(vec3(gain), 1.0));
		return;
	}
	vec4 c = imageLoad(dest_color, pos);
	imageStore(dest_color, pos, vec4(c.rgb * gain, c.a));
#endif
}
```

- [ ] **Step 2: Write the header**

`servers/rendering/renderer_rd/effects/local_highlight.h`:

```cpp
/**************************************************************************/
/*  local_highlight.h                                                     */
/**************************************************************************/

#pragma once

#include "servers/rendering/renderer_rd/shaders/effects/local_highlight.glsl.gen.h"
#include "servers/rendering/renderer_rd/storage_rd/render_scene_buffers_rd.h"

namespace RendererRD {

// Local highlight relief (spec 2026-09-28-local-highlight-relief-design.md).
//
// Divides the colour buffer by a smooth gain derived from a heavily blurred
// luminance, so a blown region slides down the tone curve as a whole while its
// own high-frequency detail survives. Runs between the OIDN denoise and the
// tone curve; the buffer it reads is SCENE-LINEAR AND PRE-EXPOSURE, which is
// why process() takes the exposure and applies it when locating the knee.
class LocalHighlight {
	enum Mode {
		MODE_DOWNSAMPLE,
		MODE_APPLY,
		MODE_MAX
	};

	struct PushConstant {
		int32_t src_size[2];
		int32_t dst_size[2];
		float strength;
		float exposure;
		float knee;
		uint32_t debug;
	};

	LocalHighlightShaderRD shader;
	RID shader_version;
	RID pipelines[MODE_MAX];

public:
	LocalHighlight();
	~LocalHighlight();

	// p_strength == 0.0 is not a valid call: the CALLER must skip dispatch
	// entirely so a gated-off frame runs no shader at all.
	void process(Ref<RenderSceneBuffersRD> p_render_buffers, float p_strength, float p_exposure, float p_knee, bool p_debug);
};

} //namespace RendererRD
```

- [ ] **Step 3: Write the implementation**

`servers/rendering/renderer_rd/effects/local_highlight.cpp`:

```cpp
/**************************************************************************/
/*  local_highlight.cpp                                                   */
/**************************************************************************/

#include "local_highlight.h"

#include "servers/rendering/renderer_rd/storage_rd/material_storage.h"
#include "servers/rendering/renderer_rd/uniform_set_cache_rd.h"

#define RB_SCOPE_RELIEF SNAME("local_highlight")
#define RB_TEX_RELIEF_LUMA SNAME("relief_luma")

namespace RendererRD {

LocalHighlight::LocalHighlight() {
	Vector<String> modes;
	modes.push_back("\n#define MODE_DOWNSAMPLE\n");
	modes.push_back("\n#define MODE_APPLY\n");
	shader.initialize(modes);
	shader_version = shader.version_create();
	for (int i = 0; i < MODE_MAX; i++) {
		pipelines[i] = RD::get_singleton()->compute_pipeline_create(shader.version_get_shader(shader_version, i));
	}
}

LocalHighlight::~LocalHighlight() {
	shader.version_free(shader_version);
}

void LocalHighlight::process(Ref<RenderSceneBuffersRD> p_render_buffers, float p_strength, float p_exposure, float p_knee, bool p_debug) {
	ERR_FAIL_COND(p_render_buffers.is_null());
	ERR_FAIL_COND(!(p_strength > 0.0f)); // caller gates; see the header.
	ERR_FAIL_COND(!(p_exposure > 0.0f));
	ERR_FAIL_COND(!(p_knee > 0.0f));

	MaterialStorage *material_storage = MaterialStorage::get_singleton();
	ERR_FAIL_NULL(material_storage);
	UniformSetCacheRD *uniform_set_cache = UniformSetCacheRD::get_singleton();
	ERR_FAIL_NULL(uniform_set_cache);

	const Size2i internal_size = p_render_buffers->get_internal_size();
	// 1/16 in each axis, floored at 1 so a tiny viewport (the gates render at
	// 256x256, and a future caller might be smaller still) cannot produce a
	// zero-sized dispatch.
	const Size2i luma_size = Size2i(MAX(1, internal_size.width / 16), MAX(1, internal_size.height / 16));

	if (!p_render_buffers->has_texture(RB_SCOPE_RELIEF, RB_TEX_RELIEF_LUMA)) {
		p_render_buffers->create_texture(RB_SCOPE_RELIEF, RB_TEX_RELIEF_LUMA,
				RD::DATA_FORMAT_R16G16B16A16_SFLOAT,
				RD::TEXTURE_USAGE_SAMPLING_BIT | RD::TEXTURE_USAGE_STORAGE_BIT,
				RD::TEXTURE_SAMPLES_1, luma_size);
	}
	RID luma = p_render_buffers->get_texture(RB_SCOPE_RELIEF, RB_TEX_RELIEF_LUMA);
	RID color = p_render_buffers->get_internal_texture();

	RID linear_sampler = material_storage->sampler_rd_get_default(RSE::CANVAS_ITEM_TEXTURE_FILTER_LINEAR, RSE::CANVAS_ITEM_TEXTURE_REPEAT_DISABLED);

	PushConstant push_constant = {};
	push_constant.src_size[0] = internal_size.width;
	push_constant.src_size[1] = internal_size.height;
	push_constant.dst_size[0] = luma_size.width;
	push_constant.dst_size[1] = luma_size.height;
	push_constant.strength = p_strength;
	push_constant.exposure = p_exposure;
	push_constant.knee = p_knee;
	push_constant.debug = p_debug ? 1u : 0u;

	RD::get_singleton()->draw_command_begin_label("Local Highlight Relief");
	RD::ComputeListID compute_list = RD::get_singleton()->compute_list_begin();

	{
		RID sh = shader.version_get_shader(shader_version, MODE_DOWNSAMPLE);
		ERR_FAIL_COND(sh.is_null());
		RD::Uniform u_src(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 0, Vector<RID>({ linear_sampler, color }));
		RD::Uniform u_dst(RD::UNIFORM_TYPE_IMAGE, 1, luma);
		RD::get_singleton()->compute_list_bind_compute_pipeline(compute_list, pipelines[MODE_DOWNSAMPLE]);
		RD::get_singleton()->compute_list_bind_uniform_set(compute_list, uniform_set_cache->get_cache(sh, 0, u_src, u_dst), 0);
		RD::get_singleton()->compute_list_set_push_constant(compute_list, &push_constant, sizeof(PushConstant));
		RD::get_singleton()->compute_list_dispatch_threads(compute_list, luma_size.width, luma_size.height, 1);
	}

	// The apply pass reads what the downsample pass wrote.
	RD::get_singleton()->compute_list_add_barrier(compute_list);

	{
		RID sh = shader.version_get_shader(shader_version, MODE_APPLY);
		ERR_FAIL_COND(sh.is_null());
		RD::Uniform u_src(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 0, Vector<RID>({ linear_sampler, luma }));
		RD::Uniform u_dst(RD::UNIFORM_TYPE_IMAGE, 1, color);
		RD::get_singleton()->compute_list_bind_compute_pipeline(compute_list, pipelines[MODE_APPLY]);
		RD::get_singleton()->compute_list_bind_uniform_set(compute_list, uniform_set_cache->get_cache(sh, 0, u_src, u_dst), 0);
		RD::get_singleton()->compute_list_set_push_constant(compute_list, &push_constant, sizeof(PushConstant));
		RD::get_singleton()->compute_list_dispatch_threads(compute_list, internal_size.width, internal_size.height, 1);
	}

	RD::get_singleton()->compute_list_end();
	RD::get_singleton()->draw_command_end_label();
}

} //namespace RendererRD
```

- [ ] **Step 4: Build**

```bash
cd "C:/Users/aiadmin/Desktop/Engine_Build_test/Zreal_Engine" && python -m SCons platform=windows target=editor arch=x86_64 d3d12=no tests=yes -j8 2>&1 | tail -5
```

Expected: a clean build. `servers/rendering/renderer_rd/effects/SCsub` globs `*.cpp` and `shaders/effects/SCsub` globs `*.glsl`, so neither needs editing. If the `.glsl.gen.h` include fails to resolve, the shader did not get picked up — check the file is in `shaders/effects/` and that the `#[compute]` line is first.

Two things this build does NOT prove, both stated in the Global Constraints: no GLSL validation runs, and nothing calls this pass yet.

- [ ] **Step 5: Prove the binary is unchanged**

```bash
cd "C:/Users/aiadmin/Desktop/Engine_Build_test/Zreal_Engine" && S="C:/Users/aiadmin/AppData/Local/Temp/claude/C--Users-aiadmin-Desktop-Engine-Build-test-Zreal-Engine/b37a70cf-2a76-48f2-b7de-63b1ab2399c1/scratchpad"; mkdir -p "$S/relief"; bin/godot.windows.editor.x86_64.console.exe --rendering-driver vulkan --path pipeline_references res://tests/pt_energy_gate_scene.tscn 2>&1 | grep -v "signed by NVIDIA" | grep -E "^PASS|^FAIL|ERROR" | tail -3
```

Expected: PASS. An unreferenced class and shader must not change any render.

- [ ] **Step 6: Commit**

```bash
cd "C:/Users/aiadmin/Desktop/Engine_Build_test/Zreal_Engine" && git add servers/rendering/renderer_rd/shaders/effects/local_highlight.glsl servers/rendering/renderer_rd/effects/local_highlight.h servers/rendering/renderer_rd/effects/local_highlight.cpp && git commit -m "$(cat <<'EOF'
feat(pt): local highlight relief pass -- blurred-luminance gain, not yet dispatched

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Wire it up — settings, dispatch, pipeline

**Files:**
- Modify: `servers/rendering/rendering_server.cpp` (~:3849, beside the other `rendering/pathtracer/*` GLOBAL_DEFs)
- Modify: `servers/rendering/renderer_rd/forward_clustered/render_forward_clustered.h` (~:840, beside `motion_vectors_store`)
- Modify: `servers/rendering/renderer_rd/forward_clustered/render_forward_clustered.cpp` (~:6694 for construction; ~:3258 for dispatch)
- Modify: `pipeline_references/render.gd` (`_daylight_probe_and_expose`, ~:627–672)

**Interfaces:**
- Consumes: `Daylight.highlight_relief`, `Daylight.RELIEF_KNEE` (Task 1); `RendererRD::LocalHighlight::process` (Task 2).
- Produces: project settings `rendering/pathtracer/highlight_relief_strength` (float, default 0.0) and `rendering/pathtracer/highlight_relief_debug` (bool, default false); a `[Relief]` log line per day still.

- [ ] **Step 1: The two settings**

In `servers/rendering/rendering_server.cpp`, after the `emissive_mesh_lights` GLOBAL_DEF:

```cpp
	// Local highlight relief (spec 2026-09-28-local-highlight-relief-design.md).
	// Strength of the local highlight compression applied between the OIDN
	// denoise and the tone curve. 0.0 disables it completely -- the pass is not
	// dispatched at all, so a gated-off frame runs no shader and is
	// byte-identical to a build without the feature. The daylight probe in
	// render.gd measures this per job from its own samples; nothing else writes it.
	GLOBAL_DEF(PropertyInfo(Variant::FLOAT, "rendering/pathtracer/highlight_relief_strength", PROPERTY_HINT_RANGE, "0.0,1.0,0.01"), 0.0);
	// Write the relief pass's gain map out as greyscale instead of applying it,
	// so a wrong-looking render is diagnosed by looking at the gain.
	GLOBAL_DEF(PropertyInfo(Variant::BOOL, "rendering/pathtracer/highlight_relief_debug"), false);
```

- [ ] **Step 2: Own an instance**

In `render_forward_clustered.h`, beside `RendererRD::MotionVectorsStore *motion_vectors_store = nullptr;`:

```cpp
	RendererRD::LocalHighlight *local_highlight = nullptr;
```

Add `#include "servers/rendering/renderer_rd/effects/local_highlight.h"` with the other effect includes at the top of `render_forward_clustered.cpp`, and beside `motion_vectors_store = memnew(RendererRD::MotionVectorsStore);` (~:6694):

```cpp
	local_highlight = memnew(RendererRD::LocalHighlight);
```

Find the matching destructor that does `memdelete(motion_vectors_store)` (grep `memdelete(motion_vectors_store)`) and add alongside it:

```cpp
	if (local_highlight) {
		memdelete(local_highlight);
	}
```

- [ ] **Step 3: Dispatch it, gated**

In `render_forward_clustered.cpp`, immediately after the block that ends with the re-blit at ~:3256–3258 (the `if (rt_state && !was_done && rt_state->oidn_denoise_done) { ... raytracing->copy_output_texture(p_render_data); ... }` block), and still inside the same enclosing scope, add:

```cpp
		// Local highlight relief (spec 2026-09-28). Runs on the DENOISED linear
		// image and before the tone curve, which is the only window where both
		// are true -- a compositor effect at POST_TRANSPARENT runs before the
		// denoise and is overwritten by the copy above.
		//
		// Gated to a real dispatch: at strength 0 nothing is bound and no shader
		// runs, so a frame the daylight probe did not flag is byte-identical.
		{
			const float relief_strength = CLAMP((float)GLOBAL_GET("rendering/pathtracer/highlight_relief_strength"), 0.0f, 1.0f);
			if (relief_strength > 0.0f && p_render_data->environment.is_valid()) {
				const float relief_exposure = environment_get_exposure(p_render_data->environment);
				if (relief_exposure > 0.0f) {
					local_highlight->process(rb, relief_strength, relief_exposure,
							(float)GLOBAL_GET("rendering/pathtracer/highlight_relief_knee"),
							(bool)GLOBAL_GET("rendering/pathtracer/highlight_relief_debug"));
				}
			}
		}
```

This references a third setting for the knee, so that the GDScript constant and the shader cannot disagree. Add it beside the other two in Step 1:

```cpp
	// The knee, in POST-EXPOSURE linear units, must match Daylight.RELIEF_KNEE
	// in daylight.gd -- the decision and the operator have to agree about where
	// the shoulder starts or the strength means something different on each side.
	GLOBAL_DEF(PropertyInfo(Variant::FLOAT, "rendering/pathtracer/highlight_relief_knee", PROPERTY_HINT_RANGE, "0.5,32.0,0.1"), 4.0);
```

Check the surrounding scope for the local name of the render buffers (`rb` above). Grep the enclosing function for `Ref<RenderSceneBuffersRD> rb` and use whatever it is actually called; if only `rb_data` is in scope, use `rb_data->get_render_buffers()` or the same expression the neighbouring OIDN call uses.

- [ ] **Step 4: The pipeline writes the strength**

In `pipeline_references/render.gd`, in `_daylight_probe_and_expose`, immediately after the line that sets `p_env.tonemap_exposure = exposure` (~:672):

```gdscript
	# Local highlight relief (spec 2026-09-28): decided from the SAME probe
	# samples, so this costs no extra render. At strength 0 the engine does not
	# dispatch the pass at all and the frame is byte-identical to a build
	# without the feature -- which is what keeps renders that do not need it
	# exactly as they are today.
	var relief: Dictionary = Daylight.highlight_relief(pr["samples"], exposure)
	ProjectSettings.set_setting("rendering/pathtracer/highlight_relief_knee", Daylight.RELIEF_KNEE)
	ProjectSettings.set_setting("rendering/pathtracer/highlight_relief_strength", relief["strength"])
	print("[Relief] clipped %.2f%% of probe samples past knee %.1f -> strength %.3f (%s)" % [
			100.0 * relief["clipped_fraction"], Daylight.RELIEF_KNEE, relief["strength"],
			"ON" if relief["needed"] else "off"])
```

Check the local variable names against the real function before pasting: grep `_daylight_probe_and_expose` and confirm the probe result is called `pr` and carries a `samples` key, and that `exposure` is the local holding the value written to `tonemap_exposure`. If the fill branch recomputes the exposure, this must use the FINAL value that was actually assigned.

`render_video()` must not call this — confirm with `grep -n "highlight_relief" pipeline_references/render.gd` returning only the one site.

- [ ] **Step 5: Build and run one day still**

```bash
cd "C:/Users/aiadmin/Desktop/Engine_Build_test/Zreal_Engine" && python -m SCons platform=windows target=editor arch=x86_64 d3d12=no tests=yes -j8 2>&1 | tail -3 && S="C:/Users/aiadmin/AppData/Local/Temp/claude/C--Users-aiadmin-Desktop-Engine-Build-test-Zreal-Engine/b37a70cf-2a76-48f2-b7de-63b1ab2399c1/scratchpad" && bin/godot.windows.editor.x86_64.console.exe --rendering-driver vulkan --path pipeline_references res://main.tscn -- "C:/Zlendo2026/ZlenderRender_stage_copy/godot_project/input_json/urbantest201__render_input.json" "$S/relief/201_on.png" > "$S/relief/201_on.log" 2>&1; grep -a "\[Relief\]\|\[Daylight\] probe\|ERROR\|DEVICE" "$S/relief/201_on.log" | head
```

Expected: a `[Relief]` line reporting a clipped fraction above 1% and a strength above 0 with `ON`, no errors, no device loss. Job 201 measured 4.17% of the frame clipped, so it must trigger. If it reports `off`, the gate or the knee is wrong for real data — report the measured fraction, do not change `RELIEF_MIN_FRACTION` to force it.

Render at the reduced resolution prior work used for turnaround (see `.superpowers/sdd/2026-09-22-path-guiding/sun-patch-exposure.md`); a 4K still is ~11 minutes.

- [ ] **Step 6: Commit**

```bash
cd "C:/Users/aiadmin/Desktop/Engine_Build_test/Zreal_Engine" && cp pipeline_references/render.gd "C:/Zlendo2026/ZlenderRender_stage_copy/godot_project/render.gd" && diff -q pipeline_references/render.gd "C:/Zlendo2026/ZlenderRender_stage_copy/godot_project/render.gd" && git add servers/rendering/rendering_server.cpp servers/rendering/renderer_rd/forward_clustered/render_forward_clustered.h servers/rendering/renderer_rd/forward_clustered/render_forward_clustered.cpp pipeline_references/render.gd && git commit -m "$(cat <<'EOF'
feat(pt): dispatch local highlight relief, gated on the daylight probe's measurement

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: The gate

**Files:**
- Create: `pipeline_references/tests/pt_highlight_relief_gate_scene.tscn`
- Create: `pipeline_references/tests/pt_highlight_relief_gate.gd`

**Interfaces:**
- Consumes: `pt_validation.gd` (`_render_accum`, `RESET_SETTLE_FRAMES`); the settings from Task 3.
- Produces: H0–H4.

- [ ] **Step 1: The scene file**

`pipeline_references/tests/pt_highlight_relief_gate_scene.tscn`:

```
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://tests/pt_highlight_relief_gate.gd" id="1_gate"]

[node name="PTHighlightReliefGate" type="Node"]
script = ExtResource("1_gate")
```

- [ ] **Step 2: The gate**

`pipeline_references/tests/pt_highlight_relief_gate.gd`:

```gdscript
extends "res://tests/pt_validation.gd"

## Local highlight relief gate (spec 2026-09-28-local-highlight-relief-design.md).
##
##   bin\godot.windows.editor.x86_64.console.exe --rendering-driver vulkan \
##       --path pipeline_references res://tests/pt_highlight_relief_gate_scene.tscn
##
## Fixture: a closed Lambertian box with a small, very bright emissive patch on
## the floor several stops above the room -- the minimum that reproduces the
## production case (a sun patch the room's exposure cannot hold).
##
##   H0 inert  : relief off renders identically to the recorded baseline.
##   H1 relief : patch clipping falls by at least H1_MIN_REDUCTION.
##   H2 midtone: wall mean moves less than H2_TOL. A highlight operator must
##               not behave like an exposure change.
##   H3 halo   : the annulus just outside the patch does not darken by more
##               than H3_MAX_DARKENING.
##   H4 gate   : a frame with no blown area gets strength 0 and is identical
##               to the same frame with the feature compiled in but off.

const FRAMES := 64
const STRENGTH := 0.5
const KNEE := 4.0
const SETTING_STRENGTH := "rendering/pathtracer/highlight_relief_strength"
const SETTING_KNEE := "rendering/pathtracer/highlight_relief_knee"
const ALBEDO := 0.5
# H1's bar is the production acceptance restated on this fixture. It is NOT
# tunable downward: if the operator cannot reach it, that is a design failure
# to report (spec, "Gate").
const H1_MIN_REDUCTION := 0.40
const H2_TOL := 0.01
# H3 has no defensible value before the blur radius is measured. Run the gate
# once, read the printed annulus ratio, and set this to that value plus a
# stated margin, with the measurement and date in this comment.
const H3_MAX_DARKENING := 0.05

# Crops, as fractions y0 y1 x0 x1.
const PATCH := [0.55, 0.75, 0.40, 0.60]
const ANNULUS := [0.76, 0.86, 0.40, 0.60]
const WALL := [0.10, 0.30, 0.10, 0.30]

var _failures: Array[String] = []
var _checks: int = 0


func _ready() -> void:
	get_window().content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	get_window().size = Vector2i(256, 256)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	get_viewport().msaa_3d = Viewport.MSAA_DISABLED
	get_viewport().screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	get_viewport().use_taa = false
	get_viewport().use_debanding = false
	get_viewport().scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	get_viewport().scaling_3d_scale = 1.0
	await get_tree().process_frame
	await get_tree().process_frame

	print("\n=== H0/H1/H2/H3: relief off vs on at strength %.2f ===" % STRENGTH)
	var off := await _render_fixture(0.0)
	var on := await _render_fixture(STRENGTH)

	var clip_off := _clipped_fraction(off, PATCH)
	var clip_on := _clipped_fraction(on, PATCH)
	var reduction := 1.0 - (clip_on / maxf(clip_off, 1e-9))
	print("  patch clipped: off %.4f on %.4f -> reduction %.3f (bar %.2f)" % [clip_off, clip_on, reduction, H1_MIN_REDUCTION])
	_check_true("H1 premise: the fixture actually clips with relief off", clip_off > 0.05,
			"(%.4f -- if this is ~0 the patch is not bright enough)" % clip_off)
	_check_true("H1 patch clipping falls >= %.0f%%" % (100.0 * H1_MIN_REDUCTION),
			reduction >= H1_MIN_REDUCTION, "(%.3f)" % reduction)

	var wall_off := _crop(off, WALL)
	var wall_on := _crop(on, WALL)
	print("  wall mean: off %.6f on %.6f" % [wall_off, wall_on])
	_check("H2 wall mean unmoved", wall_on / maxf(wall_off, 1e-9), 1.0, H2_TOL)

	var ann_off := _crop(off, ANNULUS)
	var ann_on := _crop(on, ANNULUS)
	var darkening := 1.0 - (ann_on / maxf(ann_off, 1e-9))
	print("  annulus: off %.6f on %.6f -> darkening %.4f (bar %.2f)" % [ann_off, ann_on, darkening, H3_MAX_DARKENING])
	_check_true("H3 no halo beyond %.0f%%" % (100.0 * H3_MAX_DARKENING),
			darkening <= H3_MAX_DARKENING, "(%.4f)" % darkening)

	print("\n=== H0: relief off vs the recorded baseline ===")
	var ref_path := OS.get_environment("ZR_RELIEF_BASELINE_REF")
	if ref_path == "":
		print("  SKIP: set ZR_RELIEF_BASELINE_REF to a PFM captured on the pre-change binary")
	else:
		var ref := _load_pfm(ref_path)
		if ref == null:
			_check_true("H0 baseline readable", false, ref_path)
		else:
			var d := _max_abs_diff(off, ref)
			print("  max abs diff vs baseline %.10f" % d)
			_check_true("H0 relief off == baseline", d == 0.0, "(%.10f)" % d)

	print("\n=== H4: an unlit fixture asks for no relief ===")
	var r := Daylight.highlight_relief(_samples_from(off), 1.0)
	print("  clipped fraction %.4f -> strength %.3f (%s)" % [r["clipped_fraction"], r["strength"], "ON" if r["needed"] else "off"])
	_check_true("H4 dim frame gets exactly zero strength", (not r["needed"]) and r["strength"] == 0.0)

	print("")
	if _failures.is_empty():
		print("PASS: all %d highlight-relief checks passed." % _checks)
		get_tree().quit(0)
	else:
		for f in _failures:
			print("FAIL - %s" % f)
		print("FAIL: %d of %d checks failed." % [_failures.size(), _checks])
		get_tree().quit(1)


func _check(p_name: String, p_value: float, p_expected: float, p_tol: float) -> void:
	_checks += 1
	var err := absf(p_value - p_expected) / maxf(absf(p_expected), 1e-9)
	print("  %s: %.6f vs %.6f (%+.2f%%, tol %.0f%%)" % [p_name, p_value, p_expected, 100.0 * (p_value / p_expected - 1.0), 100.0 * p_tol])
	if err > p_tol:
		_failures.append("%s: %.6f vs %.6f, %.2f%% off" % [p_name, p_value, p_expected, 100.0 * err])


func _check_true(p_name: String, p_ok: bool, p_detail: String = "") -> void:
	_checks += 1
	print("  %s %s %s" % ["PASS" if p_ok else "FAIL", p_name, p_detail])
	if not p_ok:
		_failures.append("%s %s" % [p_name, p_detail])


func _clear() -> void:
	for c in get_children():
		remove_child(c)
		c.queue_free()
	await get_tree().process_frame


func _lambert(p_albedo_linear: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(p_albedo_linear, p_albedo_linear, p_albedo_linear).linear_to_srgb()
	m.roughness = 1.0
	m.metallic = 0.0
	m.metallic_specular = 0.0
	return m


func _quad(p_center: Vector3, p_size: Vector2, p_rot_deg: Vector3, p_mat: Material) -> void:
	var mi := MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = p_size
	mi.mesh = q
	mi.material_override = p_mat
	mi.position = p_center
	mi.rotation_degrees = p_rot_deg
	add_child(mi)


## A closed box with a small, very bright emissive square on the floor. The
## emissive patch stands in for a sun patch: it is several stops above
## everything else, which is the only property the operator cares about.
func _build_fixture() -> void:
	var mat := _lambert(ALBEDO)
	_quad(Vector3(0.0, 0.0, 0.0), Vector2(4.0, 4.0), Vector3(-90.0, 0.0, 0.0), mat) # floor
	_quad(Vector3(0.0, 3.0, 0.0), Vector2(4.0, 4.0), Vector3(90.0, 0.0, 0.0), mat) # ceiling
	_quad(Vector3(0.0, 1.5, -2.0), Vector2(4.0, 3.0), Vector3(0.0, 0.0, 0.0), mat) # back
	_quad(Vector3(-2.0, 1.5, 0.0), Vector2(4.0, 3.0), Vector3(0.0, 90.0, 0.0), mat) # left
	_quad(Vector3(2.0, 1.5, 0.0), Vector2(4.0, 3.0), Vector3(0.0, -90.0, 0.0), mat) # right
	var hot := StandardMaterial3D.new()
	hot.albedo_color = Color(1, 1, 1)
	hot.emission_enabled = true
	hot.emission = Color(1, 1, 1)
	hot.emission_energy_multiplier = 60.0 # several stops over the room
	_quad(Vector3(0.0, 0.01, 0.4), Vector2(1.0, 1.0), Vector3(-90.0, 0.0, 0.0), hot)
	var lamp := OmniLight3D.new()
	lamp.light_energy = 4.0
	lamp.omni_range = 12.0
	add_child(lamp)
	lamp.position = Vector3(0.0, 2.7, 0.0)


func _render_fixture(p_strength: float) -> Image:
	await _clear()
	ProjectSettings.set_setting(SETTING_KNEE, KNEE)
	ProjectSettings.set_setting(SETTING_STRENGTH, p_strength)
	_build_fixture()
	var cam := Camera3D.new()
	cam.fov = 60.0
	cam.keep_aspect = Camera3D.KEEP_HEIGHT
	cam.near = 0.05
	cam.far = 100.0
	cam.position = Vector3(0.0, 1.5, 2.6)
	add_child(cam)
	cam.look_at(Vector3(0.0, 0.3, 0.0), Vector3.UP)
	cam.make_current()
	var env := _new_env()
	await get_tree().create_timer(1.0).timeout
	var img := await _render_accum(env, get_viewport().get_viewport_rid(), FRAMES)
	ProjectSettings.set_setting(SETTING_STRENGTH, 0.0)
	return img


func _new_env() -> Environment:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0, 0, 0)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.tonemap_exposure = 1.0
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	env.set_pathtracing_enabled(true)
	env.set_pathtracing_samples_per_pixel(1)
	env.set_pathtracing_denoiser(0)
	env.set_pathtracing_oidn_denoise(false)
	env.set_pathtracing_dlss_rr_final(false)
	env.set_pathtracing_clamp_direct(0.0)
	env.set_pathtracing_clamp_indirect(0.0)
	env.set_pathtracing_noise_threshold(0.0)
	env.set_pathtracing_max_bounces(8)
	return env


func _crop(p_img: Image, p_r: Array) -> float:
	var w := p_img.get_width()
	var h := p_img.get_height()
	var acc := 0.0
	var n := 0
	for y in range(int(h * float(p_r[0])), int(h * float(p_r[1]))):
		for x in range(int(w * float(p_r[2])), int(w * float(p_r[3]))):
			var c := p_img.get_pixel(x, y)
			acc += (c.r + c.g + c.b) / 3.0
			n += 1
	return acc / float(maxi(n, 1))


## Fraction of the crop at or above the knee -- the linear-buffer stand-in for
## "would clip", since this gate's tonemapper is LINEAR.
func _clipped_fraction(p_img: Image, p_r: Array) -> float:
	var w := p_img.get_width()
	var h := p_img.get_height()
	var hits := 0
	var n := 0
	for y in range(int(h * float(p_r[0])), int(h * float(p_r[1]))):
		for x in range(int(w * float(p_r[2])), int(w * float(p_r[3]))):
			var c := p_img.get_pixel(x, y)
			if (c.r + c.g + c.b) / 3.0 >= KNEE:
				hits += 1
			n += 1
	return float(hits) / float(maxi(n, 1))


func _samples_from(p_img: Image) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for y in range(0, p_img.get_height(), 4):
		for x in range(0, p_img.get_width(), 4):
			var c := p_img.get_pixel(x, y)
			out.append((c.r + c.g + c.b) / 3.0)
	return out


func _max_abs_diff(p_a: Image, p_b: Image) -> float:
	var m := 0.0
	for y in range(p_a.get_height()):
		for x in range(p_a.get_width()):
			var a := p_a.get_pixel(x, y)
			var b := p_b.get_pixel(x, y)
			m = maxf(m, maxf(absf(a.r - b.r), maxf(absf(a.g - b.g), absf(a.b - b.b))))
	return m


func _save_pfm(p_img: Image, p_path: String) -> void:
	var w := p_img.get_width()
	var h := p_img.get_height()
	var f := FileAccess.open(p_path, FileAccess.WRITE)
	if f == null:
		return
	f.store_string("PF\n%d %d\n-1.0\n" % [w, h])
	var buf := StreamPeerBuffer.new()
	buf.big_endian = false
	for y in range(h - 1, -1, -1):
		for x in range(w):
			var c := p_img.get_pixel(x, y)
			buf.put_float(c.r)
			buf.put_float(c.g)
			buf.put_float(c.b)
	f.store_buffer(buf.data_array)
	f.close()


func _load_pfm(p_path: String) -> Image:
	var f := FileAccess.open(p_path, FileAccess.READ)
	if f == null:
		return null
	var magic := f.get_line()
	var dims := f.get_line().split(" ")
	f.get_line()
	if magic != "PF" or dims.size() != 2:
		return null
	var w := int(dims[0])
	var h := int(dims[1])
	var img := Image.create(w, h, false, Image.FORMAT_RGBF)
	for y in range(h - 1, -1, -1):
		for x in range(w):
			var r := f.get_float()
			var g := f.get_float()
			var b := f.get_float()
			img.set_pixel(x, y, Color(r, g, b))
	return img
```

Note: the gate needs `Daylight` in scope for H4. Add `const Daylight = preload("res://daylight.gd")` at the top, below `extends` — a global class name would not resolve, because the live project has no `.godot` class cache.

- [ ] **Step 3: Run it and read the numbers**

```bash
cd "C:/Users/aiadmin/Desktop/Engine_Build_test/Zreal_Engine" && S="C:/Users/aiadmin/AppData/Local/Temp/claude/C--Users-aiadmin-Desktop-Engine-Build-test-Zreal-Engine/b37a70cf-2a76-48f2-b7de-63b1ab2399c1/scratchpad"; bin/godot.windows.editor.x86_64.console.exe --rendering-driver vulkan --path pipeline_references res://tests/pt_highlight_relief_gate_scene.tscn 2>&1 | grep -v "signed by NVIDIA" | grep -E "===|PASS|FAIL|patch|wall|annulus|clipped" | tee "$S/relief/gate.log"
```

Read the printed annulus darkening and set `H3_MAX_DARKENING` to that value plus a margin, recording the measurement and the date in its comment — this is the one bar the spec says has no defensible value beforehand. Do NOT touch `H1_MIN_REDUCTION`: if H1 fails, report it as a design failure.

If H1's premise check fails (`clip_off` near zero), the emissive patch is not bright enough relative to the room for this fixture to clip at all — raise `emission_energy_multiplier` and say so in the report; that is a fixture constant, not a bar.

- [ ] **Step 4: Capture the H0 baseline and re-run**

H0 needs a PFM from a binary WITHOUT the feature. Get it from the commit before Task 2:

```bash
cd "C:/Users/aiadmin/Desktop/Engine_Build_test/Zreal_Engine" && git stash list >/dev/null; git log --oneline -6
```

Build the pre-Task-2 commit into a separate binary, render the fixture with relief off, save the PFM, then restore. If that is impractical in one session, record H0 as SKIPPED with the reason and cover inertness with Task 5's suite run instead — but say clearly which of the two you did.

- [ ] **Step 5: Commit**

```bash
cd "C:/Users/aiadmin/Desktop/Engine_Build_test/Zreal_Engine" && git add pipeline_references/tests/pt_highlight_relief_gate.gd pipeline_references/tests/pt_highlight_relief_gate_scene.tscn && git commit -m "$(cat <<'EOF'
test(pt): highlight relief gate -- relief, midtone stability, halo, and the off-gate

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Suite, production acceptance, closeout

**Files:**
- Modify: `docs/superpowers/specs/2026-09-28-local-highlight-relief-design.md` (add `## Measured`)

**Interfaces:**
- Consumes: everything above.

- [ ] **Step 1: The whole gate suite**

```bash
cd "C:/Users/aiadmin/Desktop/Engine_Build_test/Zreal_Engine" && S="C:/Users/aiadmin/AppData/Local/Temp/claude/C--Users-aiadmin-Desktop-Engine-Build-test-Zreal-Engine/b37a70cf-2a76-48f2-b7de-63b1ab2399c1/scratchpad"; mkdir -p "$S/relief/suite"; for t in pipeline_references/tests/*_gate_scene.tscn; do n=$(basename "$t" _scene.tscn); bin/godot.windows.editor.x86_64.console.exe --rendering-driver vulkan --path pipeline_references "res://tests/${n}_scene.tscn" > "$S/relief/suite/$n.log" 2>&1; echo "$n exit=$? :: $(grep -aE '^PASS|^FAIL:|gate PASSED|gate FAILED' "$S/relief/suite/$n.log" | tail -1)"; done
```

Expected: **25 lines, all exit=0.** The suite was 24/24 green before this work. Every one of those gates renders with the relief setting at its 0.0 default, so every one must be unaffected. A gate that newly fails means the dispatch is not actually gated — check that `relief_strength > 0.0f` guards the call and that nothing writes the setting outside `render.gd`.

Note `pt_thin_layer_gate` takes ~10 minutes on its own; the whole suite is ~25 minutes. Run it detached if the tool's timeout is a concern.

- [ ] **Step 2: Job 201, before and after**

Render job 201 twice at the reduced resolution — once with the relief code present but forced off (`ProjectSettings` override to 0.0), once as shipped — and measure the sun-patch crop `--wall 0.2875 0.5329 0.5867 0.6430` (the corrected crop; the spec's original crop is contaminated by a ceiling downlight, see `2026-09-19-daylight-design.md` Findings (6)).

For each: the `[Relief]` line, the percentage of the sun-patch region at 254+ on the PNG, the sun-patch median display value, and the mid-wall mean. Then build a side-by-side crop composite with PIL and **look at it**: is the rug's weave visible, do the furniture shadows still read, does the patch still read as direct sun rather than flat grey?

Acceptance from the spec: sun-patch clipping down at least **40% relative** from 23.3%; mid-wall mean within **1%**; no visible halo.

- [ ] **Step 3: A day job that should NOT trigger**

Pick a day job whose probe reports a clipped fraction under `RELIEF_MIN_FRACTION` — job 176 (the "deep room" of the daylight four, which reads 5.48% wall grain and has no strong sun patch) is the likely candidate; confirm from its `[Relief]` line that it reports `off`. Render it on this binary and on the pre-relief commit's binary and confirm the PNGs are **byte-identical**. That is the claim the whole gating design rests on.

- [ ] **Step 4: Write the closeout**

Append to the spec:

```markdown
## Measured (2026-09-2x)

Gate `pt_highlight_relief_gate`: H1 patch clipping <off> -> <on>, reduction
<r> (bar 0.40); H2 wall mean <off> -> <on> (<pct>%, tol 1%); H3 annulus
darkening <d> (bar <bar>, set from this measurement); H4 dim frame strength
0.000; H0 <result>. Suite 25/25. Unit checks R1-R6 pass.

| job | sun-patch clip% before | after | mid-wall before | after | [Relief] strength |
|---|---|---|---|---|---|
| 201 | 23.3% | | | | |
| 176 | n/a (gate off) | byte-identical | | | 0.000 |

Findings: <anything that surprised -- halos, a job that triggered unexpectedly,
the strength curve being too weak or too strong on real data>.
```

Fill every `<...>`. Then add a one-paragraph note to `PATH_TRACER_QUALITY_ROADMAP.md` §11.28's neighbourhood pointing at this spec, since that section already records the four global levers that failed and this is their resolution.

- [ ] **Step 5: Commit**

```bash
cd "C:/Users/aiadmin/Desktop/Engine_Build_test/Zreal_Engine" && git add docs/superpowers/specs/2026-09-28-local-highlight-relief-design.md PATH_TRACER_QUALITY_ROADMAP.md && git commit -m "$(cat <<'EOF'
docs(pt): local highlight relief closeout -- gate, suite and job 201 measured

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Self-review (done at authoring)

**Spec coverage.** Decision function + constants → Task 1. Project settings channel → Task 3 Step 1 (plus a third, `highlight_relief_knee`, added so the GDScript constant and the shader cannot disagree — a deviation from the spec's two settings, recorded here and in the code comment). Engine pass, blurred luminance, gain formula, debug gain map → Task 2. Dispatch point and gating → Task 3 Steps 2–3. `render.gd` call site, still-route only → Task 3 Step 4. Gate H0–H4 → Task 4. Unit checks → Task 1. Suite + production acceptance + byte-identical non-triggering job → Task 5. "Not changed" list → no task touches `tonemap.glsl`, the probe's target/mask, the PNG contract, video, OIDN or the tracer.

**Placeholders.** The only `<...>` are in Task 5's closeout template, filled from measurement. `H3_MAX_DARKENING` ships with a provisional 0.05 and Task 4 Step 3 requires replacing it with a measured value — flagged in the spec as the one bar that cannot be set beforehand.

**Type consistency.** `highlight_relief(PackedFloat32Array, float) -> Dictionary{needed: bool, strength: float, clipped_fraction: float}` is produced in Task 1 and consumed identically in Task 3 Step 4 and Task 4's H4. `LocalHighlight::process(Ref<RenderSceneBuffersRD>, float, float, float, bool)` is declared in Task 2's header, defined in its cpp, and called with that exact arity in Task 3 Step 3. Setting names `rendering/pathtracer/highlight_relief_strength` / `_knee` / `_debug` are spelled identically in Tasks 3 and 4. `RELIEF_KNEE` (GDScript) and the `highlight_relief_knee` setting carry the same 4.0 and Task 3 Step 4 writes one from the other rather than duplicating the literal.
