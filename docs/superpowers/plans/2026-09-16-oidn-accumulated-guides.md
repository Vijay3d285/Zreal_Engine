# OIDN Accumulated Guides Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** OIDN's albedo and normal guides become the same filtered 256-sample average as the colour (Cycles' denoising passes), prefiltered Cycles' ACCURATE way, so the Phase A still no longer blurs with distance.

**Architecture:** Two new RGBA16F accumulation textures (`rt_accum_albedo`, `rt_accum_normal`, bindings 39/40) are blended in the hit and miss shaders at the primary sample with the colour's running weight `1/(n+1)`; `_oidn_final_denoise_accumulator` reads them instead of the 8-bit DLSS-RR G-buffers; `OIDNDenoiser::denoise_rt` prefilters each guide with its own RT filter and runs the colour with `cleanAux = true`. A gate with a fine and a coarse checker measures detail retention through OIDN and is red today.

**Tech Stack:** GLSL (RT stages), C++ (RD render buffers, OIDN C API), GDScript gate.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-09-16-oidn-accumulated-guides-design.md`.
- Engine-only. `pipeline_references/*.gd` directly under that directory are the user's files: not touched. `pipeline_references/tests/` may be committed.
- `git add` with explicit paths only. Commits end with `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.
- Build: `python -m SCons platform=windows target=editor tests=yes -j8`; a clean build proves nothing about GLSL — run the gate.
- Gate paths carry `.tscn`. Renders go to the scratchpad.
- New textures: `RB_TEX_RAYTRACING_ACCUM_ALBEDO = "rt_accum_albedo"`, `RB_TEX_RAYTRACING_ACCUM_NORMAL = "rt_accum_normal"`, `DATA_FORMAT_R16G16B16A16_SFLOAT`, bindings **39** and **40** (38 is the coat-albedo table, the last in use).
- DLSS-RR G-buffers (`RB_TEX_DLSS_RR_*`) are unchanged; the realtime route never reads the new textures.

---

### Task 1: The guide gate (red on today's build)

**Files:**
- Create: `pipeline_references/tests/pt_oidn_guide_gate.gd`
- Create: `pipeline_references/tests/pt_oidn_guide_gate_scene.tscn`
- Modify: `docs/superpowers/specs/2026-09-16-oidn-accumulated-guides-design.md` (gate section: fine/coarse instead of near/far)

**Interfaces:**
- Consumes: `pt_validation.gd::_render_accum(env, vp_rid, frames) -> Image` (raw accumulator, pre-OIDN); OIDN's result reaches the viewport texture one frame after the accumulator hits its target (`_oidn_final_denoise_accumulator` uploads into the RT colour image, which is blitted to the viewport).
- Produces: constants `RETAIN_MIN := 0.85`, `PARITY_MAX := 0.10`; printed `G1 fine`, `G2 coarse`, `G3 parity`.

Design change against the spec, recorded in Step 3: the mechanism is texture frequency *per pixel*, not distance, so the stimulus is one quad filling the frame with a **fine checker (period 4 px) on its left half and a coarse checker (period 32 px) on its right half**. Detail retention = std-dev of the OIDN result over a region ÷ std-dev of the raw accumulation over the same region. A point-sampled guide is a noisy binary pattern on the fine checker and a clean one on the coarse checker — which is the near/far difference in job 224, on one quad.

- [ ] **Step 1: Write the gate**

`pipeline_references/tests/pt_oidn_guide_gate.gd`:

```gdscript
extends "res://tests/pt_validation.gd"

## OIDN guide gate (spec 2026-09-16-oidn-accumulated-guides-design.md).
##
##   bin\godot.windows.editor.x86_64.console.exe --rendering-driver vulkan \
##       --path pipeline_references res://tests/pt_oidn_guide_gate_scene.tscn
##
## One quad fills the 256x256 frame, textured 1:1 with a checker: period 4 px
## on the left half, period 32 px on the right. Uniform white sky, one bounce,
## so every sample's radiance is the albedo itself (a furnace) and the raw
## 256-frame accumulation is the pixel-filtered checker with no noise. OIDN
## then runs as the still route's final pass. Detail retention = std-dev of
## OIDN's output over a region / std-dev of the raw accumulation over it.
##
##   G1 fine   : retention on the period-4 half   >= RETAIN_MIN
##   G2 coarse : retention on the period-32 half  >= RETAIN_MIN
##   G3 parity : |G1 - G2| <= PARITY_MAX -- "no blur that grows with texture
##               frequency per pixel", which is what blur with distance is.
##
## With the guides being one point sample per pixel (the DLSS-RR G-buffers),
## the fine half's guide is a noisy binary pattern that disagrees with the
## filtered colour and OIDN erases the checker; with the guides accumulated
## like the colour (Cycles' denoising passes) it keeps it.

const FRAMES := 256
const RETAIN_MIN := 0.85
const PARITY_MAX := 0.10
const CAM_DIST := 10.0
const CAM_FOV := 10.0
const FINE_PERIOD := 4
const COARSE_PERIOD := 32

var _failures: Array[String] = []
var _checks: int = 0


func _ready() -> void:
	get_window().content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	get_window().size = Vector2i(256, 256)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	# Same viewport contract as render.gd's still route: no TAA / temporal
	# jitter on top of the pixel filter, and an HDR 2D target so the viewport
	# image comes back linear (FORMAT_RGBH) for a like-for-like std-dev.
	get_viewport().use_taa = false
	get_viewport().scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	get_viewport().scaling_3d_scale = 1.0
	get_viewport().use_hdr_2d = true
	await get_tree().process_frame
	await get_tree().process_frame

	var env := _new_env(Color(1, 1, 1))
	env.set_pathtracing_max_bounces(1)
	env.set_pathtracing_oidn_denoise(true)

	# 256x256 checker, no mipmaps (a mipmapped texture would be prefiltered by
	# the sampler and there would be nothing for the denoiser to lose).
	var img := Image.create(256, 256, false, Image.FORMAT_RGB8)
	for y in range(256):
		for x in range(256):
			var period := FINE_PERIOD if x < 128 else COARSE_PERIOD
			var half := period / 2
			var on := ((x / half) + (y / half)) % 2 == 0
			img.set_pixel(x, y, Color(0.9, 0.9, 0.9) if on else Color(0.1, 0.1, 0.1))
	var tex := ImageTexture.create_from_image(img)

	# Quad exactly filling the view at CAM_DIST: side = 2 * CAM_DIST * tan(fov/2).
	var side := 2.0 * CAM_DIST * tan(deg_to_rad(CAM_FOV) * 0.5)
	var quad := MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = Vector2(side, side)
	quad.mesh = qm
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = tex
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	mat.metallic = 0.0
	mat.metallic_specular = 0.0
	mat.roughness = 1.0
	quad.material_override = mat
	add_child(quad)

	var cam := Camera3D.new()
	cam.fov = CAM_FOV
	cam.near = 0.1
	cam.far = 100.0
	cam.position = Vector3(0, 0, CAM_DIST)
	add_child(cam)
	cam.make_current()
	await get_tree().create_timer(1.0).timeout

	var raw: Image = await _render_accum(env, get_viewport().get_viewport_rid(), FRAMES)
	# OIDN fires on the frame the accumulator reaches its target and lands in
	# the viewport texture on the next blit; give it two frames.
	await get_tree().process_frame
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var out: Image = get_viewport().get_texture().get_image()
	if out.get_format() != Image.FORMAT_RGBH:
		_failures.append("viewport image is %d, not FORMAT_RGBH -- use_hdr_2d did not take" % out.get_format())
		_finish()
		return

	var fine_raw := _std(raw, 24, 40, 104, 216)
	var fine_out := _std(out, 24, 40, 104, 216)
	var coarse_raw := _std(raw, 152, 40, 232, 216)
	var coarse_out := _std(out, 152, 40, 232, 216)
	var g1 := fine_out / maxf(fine_raw, 1e-6)
	var g2 := coarse_out / maxf(coarse_raw, 1e-6)

	print("\n=== G1: fine checker (period %d px) retention ===" % FINE_PERIOD)
	print("  raw std %.5f  oidn std %.5f  retention %.4f (min %.2f)" % [fine_raw, fine_out, g1, RETAIN_MIN])
	_checks += 1
	if g1 < RETAIN_MIN:
		_failures.append("G1 fine retention %.4f < %.2f" % [g1, RETAIN_MIN])

	print("\n=== G2: coarse checker (period %d px) retention ===" % COARSE_PERIOD)
	print("  raw std %.5f  oidn std %.5f  retention %.4f (min %.2f)" % [coarse_raw, coarse_out, g2, RETAIN_MIN])
	_checks += 1
	if g2 < RETAIN_MIN:
		_failures.append("G2 coarse retention %.4f < %.2f" % [g2, RETAIN_MIN])

	print("\n=== G3: fine/coarse parity ===")
	print("  |G1 - G2| = %.4f (max %.2f)" % [absf(g1 - g2), PARITY_MAX])
	_checks += 1
	if absf(g1 - g2) > PARITY_MAX:
		_failures.append("G3 parity |%.4f - %.4f| > %.2f" % [g1, g2, PARITY_MAX])
	_finish()


## Population std-dev of the mean-of-RGB over [x0,x1) x [y0,y1).
func _std(p_img: Image, p_x0: int, p_y0: int, p_x1: int, p_y1: int) -> float:
	var n := 0
	var s := 0.0
	var s2 := 0.0
	for y in range(p_y0, p_y1):
		for x in range(p_x0, p_x1):
			var c := p_img.get_pixel(x, y)
			var v := (c.r + c.g + c.b) / 3.0
			s += v
			s2 += v * v
			n += 1
	var m := s / float(maxi(n, 1))
	return sqrt(maxf(s2 / float(maxi(n, 1)) - m * m, 0.0))


func _finish() -> void:
	print("")
	if _failures.is_empty():
		print("PASS: all %d OIDN-guide checks passed." % _checks)
		get_tree().quit(0)
	else:
		for f in _failures:
			print("FAIL - %s" % f)
		print("FAIL: %d of %d checks failed." % [_failures.size(), _checks])
		get_tree().quit(1)


func _new_env(p_bg: Color) -> Environment:
	var pano := Image.create(8, 4, false, Image.FORMAT_RGBF)
	pano.fill(p_bg)
	var sky_mat := PanoramaSkyMaterial.new()
	sky_mat.panorama = ImageTexture.create_from_image(pano)
	var sky := Sky.new()
	sky.sky_material = sky_mat
	sky.process_mode = Sky.PROCESS_MODE_QUALITY
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
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
	return env
```

`pipeline_references/tests/pt_oidn_guide_gate_scene.tscn`:

```
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://tests/pt_oidn_guide_gate.gd" id="1_gate"]

[node name="PTOidnGuideGate" type="Node"]
script = ExtResource("1_gate")
```

- [ ] **Step 2: Run on the current build — G1 (and therefore G3) must be red**

```bash
bin/godot.windows.editor.x86_64.console.exe --rendering-driver vulkan --path pipeline_references res://tests/pt_oidn_guide_gate_scene.tscn
```

Expected: the log carries `[OIDN-DIAG] FIRE:` (OIDN ran — if absent, `set_pathtracing_oidn_denoise(true)` did not reach the environment before accumulation began; move it before `_new_env`'s `add_child`), G2 ≥ 0.85, **G1 well below** (the fine checker is what job 224's far picture is), G3 red. Record both numbers; they go in the roadmap.

If G1 is *also* ≥ 0.85 on the current build, the stimulus is not aliasing-prone enough for a single point sample to disagree with the mean: drop `FINE_PERIOD` to 2 (1-px cells) and re-run — but at period 2 the filtered raw contrast is small, so check `fine_raw` is still > 0.02 or the ratio is noise. If `out` reads identical to `raw` everywhere (retention 1.000 on both), the viewport image was taken before OIDN landed — add two more `process_frame` awaits.

- [ ] **Step 3: Amend the spec's gate section**

Replace the spec's "### 3. Gate" bullets G1–G3 with the fine/coarse design above (one quad, period 4 and 32, retention ≥ 0.85 each, parity ≤ 0.10), keeping the sentence that thresholds are set from the red/green pair.

- [ ] **Step 4: Commit**

```bash
git add pipeline_references/tests/pt_oidn_guide_gate.gd pipeline_references/tests/pt_oidn_guide_gate_scene.tscn docs/superpowers/specs/2026-09-16-oidn-accumulated-guides-design.md
git commit -m "test(pt): OIDN guide gate -- detail retention on a fine vs coarse checker (red: point-sampled guides)

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: Accumulate the guides (engine: buffers, bindings, shaders)

**Files:**
- Modify: `servers/rendering/renderer_rd/forward_clustered/render_raytracing.h:50-52` (defines)
- Modify: `servers/rendering/renderer_rd/forward_clustered/render_forward_clustered.h:174-180` (accessors)
- Modify: `servers/rendering/renderer_rd/forward_clustered/render_forward_clustered.cpp:143-150` (create), `:2877-2881` (reset clear)
- Modify: `servers/rendering/renderer_rd/forward_clustered/render_raytracing.cpp:4440-4446` (bindings, after 33)
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_common_inc.glsl:139-140` (declarations + helper)
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/scene_raytracing_raygen.glsl:32` (move `rt_accum_n`), `:360-366` (miss write)
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl:1737-1745` (hit write)

**Interfaces:**
- Produces: `rt_get_accum_albedo_texture()`, `rt_get_accum_normal_texture()` on `RenderBufferDataForwardClustered` (both RGBA16F, cleared with the accumulator); GLSL `rt_accum_guide_sample(ivec2 px, vec3 albedo, vec3 normal)` in `raytracing_common_inc.glsl` under `#ifdef DLSS_RR_ENABLED`.

The blend lives in the **hit and miss shaders**, right where the DLSS-RR G-buffer is written for the primary sample, not in raygen: the hit shader already has the sample's albedo and normal in registers, and reading `rt_accum_n` there gives the same `n` raygen uses this frame (raygen writes `n + 1` only after the trace returns). No cross-stage image read-after-write is needed.

- [ ] **Step 1: Defines and accessors**

`render_raytracing.h`, after the `RB_TEX_RAYTRACING_VARIANCE` line:

```cpp
// OIDN guides accumulated like the colour (spec 2026-09-16-oidn-accumulated-guides):
// running-average primary albedo and world normal, one sample per frame at the
// pixel filter's jitter -- Cycles' denoising_albedo / denoising_normal passes.
#define RB_TEX_RAYTRACING_ACCUM_ALBEDO SNAME("rt_accum_albedo") // R16G16B16A16_SFLOAT
#define RB_TEX_RAYTRACING_ACCUM_NORMAL SNAME("rt_accum_normal") // R16G16B16A16_SFLOAT
```

`render_forward_clustered.h`, after the `rt_get_variance_texture()` line:

```cpp
		bool rt_has_accum_albedo_texture() const { return render_buffers->has_texture(RB_SCOPE_FORWARD_CLUSTERED, RB_TEX_RAYTRACING_ACCUM_ALBEDO); }
		RID rt_get_accum_albedo_texture() const { return render_buffers->get_texture(RB_SCOPE_FORWARD_CLUSTERED, RB_TEX_RAYTRACING_ACCUM_ALBEDO); }
		bool rt_has_accum_normal_texture() const { return render_buffers->has_texture(RB_SCOPE_FORWARD_CLUSTERED, RB_TEX_RAYTRACING_ACCUM_NORMAL); }
		RID rt_get_accum_normal_texture() const { return render_buffers->get_texture(RB_SCOPE_FORWARD_CLUSTERED, RB_TEX_RAYTRACING_ACCUM_NORMAL); }
```

- [ ] **Step 2: Create and clear**

`render_forward_clustered.cpp`, after the `RB_TEX_RAYTRACING_VARIANCE` creation block (ends `RD::TEXTURE_SAMPLES_1);\n\t}` before `}` of `rt_ensure_textures`):

```cpp
	// OIDN guides, accumulated with the colour. RGBA16F: albedo in [0,1] and a
	// unit normal sit well inside half precision, and the running mean is
	// rewritten from the stored value each step, so the 1/257 weight at the
	// last frame does not accumulate error. Cleared with rt_accum on reset.
	if (!render_buffers->has_texture(RB_SCOPE_FORWARD_CLUSTERED, RB_TEX_RAYTRACING_ACCUM_ALBEDO)) {
		render_buffers->create_texture(
				RB_SCOPE_FORWARD_CLUSTERED,
				RB_TEX_RAYTRACING_ACCUM_ALBEDO,
				RD::DATA_FORMAT_R16G16B16A16_SFLOAT,
				usage_bits_oidn,
				RD::TEXTURE_SAMPLES_1);
	}
	if (!render_buffers->has_texture(RB_SCOPE_FORWARD_CLUSTERED, RB_TEX_RAYTRACING_ACCUM_NORMAL)) {
		render_buffers->create_texture(
				RB_SCOPE_FORWARD_CLUSTERED,
				RB_TEX_RAYTRACING_ACCUM_NORMAL,
				RD::DATA_FORMAT_R16G16B16A16_SFLOAT,
				usage_bits_oidn,
				RD::TEXTURE_SAMPLES_1);
	}
```

In the reset block, after the `rt_get_variance_texture()` clear:

```cpp
			RD::get_singleton()->texture_clear(rb_data->rt_get_accum_albedo_texture(), Color(0, 0, 0, 0), 0, 1, 0, 1);
			RD::get_singleton()->texture_clear(rb_data->rt_get_accum_normal_texture(), Color(0, 0, 0, 0), 0, 1, 0, 1);
```

- [ ] **Step 3: Bind at 39 and 40**

`render_raytracing.cpp`, directly after the binding-33 block:

```cpp
	// Bindings 39 & 40: OIDN guide accumulators (running-average primary albedo /
	// world normal), blended in the hit and miss shaders at the primary sample.
	// 34-38 are the env-NEE, emissive and coat-albedo buffers. Bound
	// unconditionally like 29/30/33.
	{
		RD::Uniform u;
		u.binding = 39;
		u.uniform_type = RD::UNIFORM_TYPE_IMAGE;
		u.append_id(rb_data->rt_get_accum_albedo_texture());
		uniforms.push_back(u);
	}
	{
		RD::Uniform u;
		u.binding = 40;
		u.uniform_type = RD::UNIFORM_TYPE_IMAGE;
		u.append_id(rb_data->rt_get_accum_normal_texture());
		uniforms.push_back(u);
	}
```

- [ ] **Step 4: Declarations and helper (GLSL)**

In `scene_raytracing_raygen.glsl`, delete the line `layout(set = 0, binding = 30, r32f) uniform image2D rt_accum_n;` and change the comment above it to say `rt_accum_n` is declared in `raytracing_common_inc.glsl` (every stage reads it). In `raytracing_common_inc.glsl`, after the `rt_depth_image` declaration (line ~140):

```glsl
// Phase A per-pixel sample count (R32_SFLOAT). Declared here, not in raygen,
// because the hit and miss shaders read it for the guide accumulators below.
layout(set = 0, binding = 30, r32f) uniform image2D rt_accum_n;

#ifdef DLSS_RR_ENABLED
// OIDN guides accumulated like the colour (spec 2026-09-16-oidn-accumulated-
// guides): Cycles writes its denoising_albedo / denoising_normal passes with
// film_write_pass_* -- an accumulation over every sample at its pixel-filter
// jitter. The DLSS-RR G-buffers are the opposite: one point sample per frame,
// which is what DLSS-RR wants and what made OIDN blur every surface whose
// texture is fine per pixel (the far half of a 4K still).
layout(set = 0, binding = 39, rgba16f) uniform image2D rt_accum_albedo;
layout(set = 0, binding = 40, rgba16f) uniform image2D rt_accum_normal;

// Blend this frame's primary-sample albedo / normal into the running means
// with the colour's weight. n is the count BEFORE this frame (raygen writes
// n + 1 after the trace), so w matches the colour blend exactly. A pixel the
// adaptive sampler froze never traces, so it never reaches here -- consistent.
void rt_accum_guide_sample(ivec2 px, vec3 albedo, vec3 normal) {
	if (get_rt_param(RT_PARAM_ACCUM_FLAG) <= 0.5) {
		return;
	}
	float n = max(imageLoad(rt_accum_n, px).x, 0.0);
	float w = 1.0 / (n + 1.0);
	vec3 a = mix(imageLoad(rt_accum_albedo, px).rgb, albedo, w);
	vec3 nr = mix(imageLoad(rt_accum_normal, px).rgb, normal, w);
	imageStore(rt_accum_albedo, px, vec4(a, 1.0));
	imageStore(rt_accum_normal, px, vec4(nr, 1.0));
}
#endif
```

- [ ] **Step 5: Call it at both primary-sample write sites**

`raytracing_closest_hit_common_inc.glsl`, inside the `#ifdef DLSS_RR_ENABLED` / `total_bounces == 0u && is_sample_zero` block, directly after `imageStore(dlss_rr_normal_roughness, pixel, vec4(N, m.roughness));`:

```glsl
		rt_accum_guide_sample(pixel, diffuse_albedo, N);
```

`scene_raytracing_raygen.glsl` miss section, after `imageStore(dlss_rr_specular_hit_dist, pixel, vec4(-1.0));`:

```glsl
			rt_accum_guide_sample(pixel, sky_color, -gl_WorldRayDirectionEXT);
```

- [ ] **Step 6: Build and run the guide gate — still red, for the right reason**

Build. Run the Task 1 gate. Expected: no shader error in the log, `[OIDN-DIAG] FIRE:` present, G1 unchanged (OIDN still reads the old G-buffers — Task 3 switches it). Any `SHADER ERROR`/`Vulkan` validation line means a binding collision or a declaration in the wrong stage: check `rt_accum_n` is declared exactly once per stage (grep `binding = 30` in the raytracing shaders → only `raytracing_common_inc.glsl`).

- [ ] **Step 7: Commit**

```bash
git add servers/rendering/renderer_rd/forward_clustered/render_raytracing.h servers/rendering/renderer_rd/forward_clustered/render_forward_clustered.h servers/rendering/renderer_rd/forward_clustered/render_forward_clustered.cpp servers/rendering/renderer_rd/forward_clustered/render_raytracing.cpp servers/rendering/renderer_rd/shaders/raytracing/raytracing_common_inc.glsl servers/rendering/renderer_rd/shaders/raytracing/scene_raytracing_raygen.glsl servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl
git commit -m "feat(pt): accumulate the OIDN albedo/normal guides with the colour (Cycles denoising passes)

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: OIDN reads the accumulated guides, ACCURATE prefilter

**Files:**
- Modify: `servers/rendering/renderer_rd/forward_clustered/render_forward_clustered.cpp:1986-2050` (`_oidn_final_denoise_accumulator` guide readback)
- Modify: `servers/rendering/renderer_rd/pathtrace_oidn_denoiser.h` (signature: mutable guides)
- Modify: `modules/raycaster_oidn/oidn_denoiser.h:58-62`, `modules/raycaster_oidn/oidn_denoiser.cpp:66-135`

**Interfaces:**
- Consumes: `rt_get_accum_albedo_texture()` / `rt_get_accum_normal_texture()` from Task 2.
- Produces: `denoise_rt(int w, int h, float *color, float *albedo, float *normal, int spp)` — guides are now non-const (prefiltered in place).

- [ ] **Step 1: Read the accumulated guides**

In `_oidn_final_denoise_accumulator`, replace the two readback blocks (`// --- diffuse albedo AOV: R8G8B8A8_UNORM ...` through the end of the normal block) with:

```cpp
		// --- guides: the accumulated primary albedo / normal, R16G16B16A16_SFLOAT (8 bytes/pixel).
		// These are the running means of every accumulated sample at its pixel-filter jitter
		// (rt_accum_guide_sample, raytracing_common_inc.glsl) -- Cycles' denoising passes --
		// NOT the DLSS-RR G-buffers, which are one point sample per frame and made OIDN erase
		// every texture that is fine per pixel (job 224: blur growing with distance).
		Vector<uint8_t> albedo_bytes;
		bool has_albedo = p_rb_data->rt_has_accum_albedo_texture();
		if (has_albedo) {
			const RID rid = p_rb_data->rt_get_accum_albedo_texture();
			if (RD::get_singleton()->texture_is_valid(rid)) {
				albedo_bytes = RD::get_singleton()->texture_get_data(rid, v);
			}
			has_albedo = albedo_bytes.size() == (int64_t)width * height * 8;
		}
		Vector<uint8_t> normal_bytes;
		bool has_normal = p_rb_data->rt_has_accum_normal_texture();
		if (has_normal) {
			const RID rid = p_rb_data->rt_get_accum_normal_texture();
			if (RD::get_singleton()->texture_is_valid(rid)) {
				normal_bytes = RD::get_singleton()->texture_get_data(rid, v);
			}
			has_normal = normal_bytes.size() == (int64_t)width * height * 8;
		}
```

and the two conversion loops with:

```cpp
		// Convert albedo RGBA16F -> RGB float3.
		if (has_albedo) {
			const uint16_t *s = reinterpret_cast<const uint16_t *>(albedo_bytes.ptr());
			float *d = albedo_f.ptrw();
			for (size_t i = 0; i < pixel_count; i++) {
				d[i * 3 + 0] = CLAMP(Math::half_to_float(s[i * 4 + 0]), 0.0f, 1.0f);
				d[i * 3 + 1] = CLAMP(Math::half_to_float(s[i * 4 + 1]), 0.0f, 1.0f);
				d[i * 3 + 2] = CLAMP(Math::half_to_float(s[i * 4 + 2]), 0.0f, 1.0f);
			}
		}
		// Convert normal RGBA16F -> RGB float3, re-normalised: an averaged normal is shorter
		// than 1 wherever the samples disagreed (silhouettes, bump maps); OIDN wants unit length.
		if (has_normal) {
			const uint16_t *s = reinterpret_cast<const uint16_t *>(normal_bytes.ptr());
			float *d = normal_f.ptrw();
			for (size_t i = 0; i < pixel_count; i++) {
				Vector3 nrm(Math::half_to_float(s[i * 4 + 0]), Math::half_to_float(s[i * 4 + 1]), Math::half_to_float(s[i * 4 + 2]));
				const float len = nrm.length();
				if (len > 1e-6f) {
					nrm /= len;
				} else {
					nrm = Vector3(0, 0, 1);
				}
				d[i * 3 + 0] = nrm.x;
				d[i * 3 + 1] = nrm.y;
				d[i * 3 + 2] = nrm.z;
			}
		}
```

Update the `denoise_rt` call to pass `albedo_f.ptrw()` / `normal_f.ptrw()`. `Math::half_to_float` is in `core/math/math_funcs.h` (already included through the RD headers; add the include if the build says otherwise).

- [ ] **Step 2: Signature**

`pathtrace_oidn_denoiser.h` and `oidn_denoiser.h`: `const float *p_albedo, const float *p_normal` → `float *p_albedo, float *p_normal` (both declaration and override).

- [ ] **Step 3: ACCURATE prefilter and cleanAux = true**

`oidn_denoiser.cpp`: add above `denoise_rt`:

```cpp
// Cycles' DENOISER_PREFILTER_ACCURATE (intern/cycles/integrator/denoiser_oidn_gpu.cpp):
// each guide is run through its own RT filter -- the guide image as the only input,
// output in place -- before the colour pass, which then trusts them (cleanAux = true).
static bool oidn_prefilter_guide(OIDNDevice p_device, const char *p_name, float *p_buf, int p_width, int p_height) {
	OIDNFilter filter = oidnNewFilter(p_device, "RT");
	ERR_FAIL_COND_V_MSG(!filter, false, "oidnNewFilter(\"RT\") for guide prefilter returned null.");
	oidnSetSharedFilterImage(filter, p_name, p_buf, OIDN_FORMAT_FLOAT3, (size_t)p_width, (size_t)p_height, 0, 0, 0);
	oidnSetSharedFilterImage(filter, "output", p_buf, OIDN_FORMAT_FLOAT3, (size_t)p_width, (size_t)p_height, 0, 0, 0);
	oidnCommitFilter(filter);
	oidnExecuteFilter(filter);
	const OIDNError err = oidnGetDeviceError(p_device, nullptr);
	oidnReleaseFilter(filter);
	ERR_FAIL_COND_V_MSG(err != OIDN_ERROR_NONE, false, vformat("OIDN %s prefilter failed (error %d).", p_name, (int)err));
	return true;
}
```

In `denoise_rt`, after `ensure_device()` succeeds and before `oidnNewFilter(device, "RT")` for the colour:

```cpp
	if (p_albedo && !oidn_prefilter_guide(device, "albedo", p_albedo, p_width, p_height)) {
		return false;
	}
	if (p_normal && !oidn_prefilter_guide(device, "normal", p_normal, p_width, p_height)) {
		return false;
	}
```

Replace the `cleanAux` comment block and line with:

```cpp
	// cleanAux = true: the guides are the accumulated primary albedo / normal -- every sample
	// at its pixel-filter jitter, the same average as the colour (Cycles' denoising passes) --
	// and were just prefiltered by OIDN's own albedo / normal filters above. That is Cycles'
	// DENOISER_PREFILTER_ACCURATE, its default. The earlier cleanAux = false was a mitigation
	// for guides that were one point sample per pixel (the DLSS-RR G-buffers); those made
	// OIDN erase any texture finer than a pixel -- the far half of a 4K still (job 224).
	oidnSetFilterBool(filter, "cleanAux", true);
```

- [ ] **Step 4: Build, gate green three times**

Build; run the guide gate three times. Expected: G1 ≥ 0.85, G2 ≥ 0.85, |G1 − G2| ≤ 0.10, `PASS: all 3`. Record the three G1/G2 readings; if the spread is above 0.02 the thresholds stay, if G1 sits below 0.85 with G2 above, the guide is still not matching the colour — check that the gate log's `[OIDN-DIAG] ... albedo_bytes=` is `width*height*8` (the accumulated texture), not `*4` (the old G-buffer).

- [ ] **Step 5: Suite and doctest**

Run every `pt_*_gate_scene.tscn` (17 now) and `--test`. Expected all green, 1558/1558. The pixel-filter and subsurface gates are the ones that touch the accumulate path; a red there means the `rt_accum_n` move broke raygen's read — the declaration must be visible before `trace_one_sample`.

- [ ] **Step 6: Commit**

```bash
git add servers/rendering/renderer_rd/forward_clustered/render_forward_clustered.cpp servers/rendering/renderer_rd/pathtrace_oidn_denoiser.h modules/raycaster_oidn/oidn_denoiser.h modules/raycaster_oidn/oidn_denoiser.cpp
git commit -m "fix(pt): OIDN takes the accumulated guides, Cycles' ACCURATE prefilter, cleanAux on

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: Asset check, roadmap, memory

**Files:**
- Modify: `PATH_TRACER_QUALITY_ROADMAP.md` (row 29, §11.25)
- Modify: `docs/superpowers/plans/2026-09-16-oidn-accumulated-guides.md` (ticks, notes)
- Modify: memory `pt-oidn-cleanaux-worldspace-normal.md` (the cleanAux advice is now wrong)

- [ ] **Step 1: Job 217 at FHD, Phase A, before/after**

`<scratchpad>/aa/proj_pa` already carries the Phase A pipeline. "Before" is `<scratchpad>/aa/d217_pa_w15.png` (rendered on the 1.5 px build with the old guides — same shaders except this plan's). Render "after" to `<scratchpad>/aa/d217_pa_guides.png`. Measure with variance of the Laplacian (a sharpness statistic) on the far picture (crop `1530,690 → 1770,850` in the 217 FHD framing — verify by eye on the half-size preview first) and on a near region (`1200,760 → 1500,1000`), before/after; whole-frame mean within 0.5%.

```python
import numpy as np
from PIL import Image
def ld(p):
    a=np.asarray(Image.open(p)); a=a.astype(float)/257.0 if a.dtype!=np.uint8 else a.astype(float); return a[:,:,:3]@[0.2126,0.7152,0.0722]
def lapvar(L,x0,y0,x1,y1):
    c=L[y0:y1,x0:x1]; lap=-4*c[1:-1,1:-1]+c[:-2,1:-1]+c[2:,1:-1]+c[1:-1,:-2]+c[1:-1,2:]; return lap.var()
for p in ("d217_pa_w15.png","d217_pa_guides.png"):
    L=ld(p); print(p, "far %.2f near %.2f mean %.3f" % (lapvar(L,1530,690,1770,850), lapvar(L,1200,760,1500,1000), L.mean()))
```

Expected: far Laplacian variance rises markedly, near barely; mean within 0.5%.

- [ ] **Step 2: Roadmap**

Row 29 after row 28:

```
| 29 | **OIDN guides were one 8-bit point sample per pixel** — the Phase A still blurred more with distance. **Closed 2026-09-16 (§11.25)**: albedo/normal accumulated with the colour (Cycles' denoising passes), ACCURATE prefilter, `cleanAux` on. `pt_oidn_guide_gate` fine-checker retention <red> → <green>. | `raytracing_common_inc.glsl rt_accum_guide_sample`, `render_forward_clustered.cpp _oidn_final_denoise_accumulator`, `oidn_denoiser.cpp` | `kernel/film/denoising_passes.h`, `integrator/denoiser_oidn_gpu.cpp` | High |
```

§11.25 "Gap #29 — the denoiser's map of the scene was one sample wide": the mechanism in two paragraphs, the Cycles citations, the gate's red/green readings (three green runs), the 217 numbers from Step 1, and "open": job 224's scene at 4K by the user (like-for-like far picture against the Blender still); `denoising_depth` and feature deferral through specular not ported.

- [ ] **Step 3: Memory**

Rewrite `C:\Users\aiadmin\.claude\projects\...\memory\pt-oidn-cleanaux-worldspace-normal.md` so it says: guides must be accumulated with the colour; with accumulated guides `cleanAux = true` + ACCURATE prefilter (Cycles); `cleanAux = false` was a mitigation for point-sampled guides and is wrong once they are accumulated; normals stay world-space. Update its `MEMORY.md` hook line.

- [ ] **Step 4: Tick and commit**

```bash
sed -i 's/^- \[ \] /- [x] /' docs/superpowers/plans/2026-09-16-oidn-accumulated-guides.md
git add PATH_TRACER_QUALITY_ROADMAP.md docs/superpowers/plans/2026-09-16-oidn-accumulated-guides.md
git commit -m "docs(pt): Gap #29 -- OIDN guides accumulated like the colour (roadmap 11.25)

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Self-review

- **Spec coverage:** accumulate textures + bindings + blend at the primary sample (T2); OIDN reads them, renormalised normal, ACCURATE prefilter, cleanAux true, comment rewrite (T3); gate red/green with thresholds from the pair (T1, T3 S4); asset check + roadmap (T4); DLSS-RR untouched (no task touches `RB_TEX_DLSS_RR_*` reads on the realtime path). Spec's near/far G3 replaced by fine/coarse parity — amended in T1 S3.
- **Placeholders:** row 29's `<red>`/`<green>` are filled from T1 S2 / T3 S4 readings. None else.
- **Type consistency:** `rt_get_accum_albedo_texture()` / `rt_get_accum_normal_texture()` (T2 S1) used in T2 S2–3 and T3 S1; `rt_accum_guide_sample(ivec2, vec3, vec3)` (T2 S4) called in T2 S5 with `pixel` (ivec2) at both sites; `denoise_rt` non-const guides (T3 S2) match the `ptrw()` call (T3 S1) and the in-place prefilter (T3 S3).
