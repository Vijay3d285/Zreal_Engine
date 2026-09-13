# Gap #26 Self-Skip After Through-Events Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** After a ray passes through a surface (Transparent BSDF pass-through or a transmissive-lobe sample), the next ray starts at the exact hit point with `t_min = 0` and skips only the triangle it just left, so a surface 0.1 mm behind a pane is hit — the way Cycles does it.

**Architecture:** The payload carries the (instance, primitive) id of the surface just passed through; the hit shader sets it at the two through-sites and clears it everywhere else; the raygen restarts a skip-carrying ray at the exact hit point with `t_min = 0` (all other rays byte-identical to today); the any-hit stage ignores the skipped triangle first thing. Transmissive (converted-glass) instances stop being `FORCE_OPAQUE` so their any-hit stage runs, with a new material flag telling the any-hit to do nothing but the skip test for them, and telling the emissive-light gather they are still opaque emitters.

**Tech Stack:** GLSL (Vulkan ray tracing, `GL_EXT_ray_tracing`), C++ (`render_raytracing.cpp`), GDScript gate on the `pt_validation.gd` harness, SCons build.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-09-13-self-skip-through-events-design.md`.
- Build: `python -m SCons platform=windows target=editor tests=yes -j8` (bare `scons` is not on PATH). A clean build proves nothing about GLSL: read Godot stderr for shader errors on the first render.
- Every ray with no skip set must be **byte-identical** to today: camera rays, opaque bounces, reflections. Do not touch `offset_ray_origin` or the 0.001 literal for those rays.
- `git add` with explicit paths only; never `-A`, `.`, or `commit -a`. `pipeline_references/*.gd` files directly under that folder are the user's — do not stage them. Files under `pipeline_references/tests/` are this workstream's gates and may be edited.
- Render outputs go to the scratchpad, never into `C:\Zlendo2026\ZlenderRender_stage_copy\` (read-only).
- Gates must be falsifiable: T1 and T4b must be **red on the current engine** before the fix lands (Task 1 proves it), green after.
- Commit messages end with `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.
- Paths below are relative to `C:\Users\aiadmin\Desktop\Engine_Build_test\Zreal_Engine`. `GODOT` = `bin/godot.windows.editor.x86_64.console.exe`. Run gates with `--rendering-driver vulkan`.

---

### Task 1: The gate, red on the current engine

**Files:**
- Create: `pipeline_references/tests/pt_thin_layer_gate.gd`
- Create: `pipeline_references/tests/pt_thin_layer_gate_scene.tscn`
- Modify: `docs/superpowers/specs/2026-09-13-self-skip-through-events-design.md` (gate fixture note)

**Interfaces:**
- Consumes: `res://tests/pt_validation.gd` (`_render_accum(env, vp_rid, frames) -> Image`), `Environment.set_pathtracing_*`.
- Produces: the five probe readings T1, T2, T3, T4a, T4b printed as `  T<n> ratio = %.6f`; two pre-fix reference constants `T3_REF_PREFIX`, `T4A_REF_PREFIX` filled in from the pre-fix run.

- [ ] **Step 1: Write the gate**

`pipeline_references/tests/pt_thin_layer_gate.gd` (LF line endings, tabs):

```gdscript
extends "res://tests/pt_validation.gd"

## Thin-layer gate (roadmap Gap #26).
##
##   bin\godot.windows.editor.x86_64.console.exe --rendering-driver vulkan \
##       --path pipeline_references res://tests/pt_thin_layer_gate_scene.tscn
##
## WHAT THIS PROVES. After a ray passes THROUGH a surface (Transparent BSDF
## pass-through, or a transmissive-lobe sample) the next ray must be able to hit
## anything at any distance except the triangle it just left. Before the fix
## the restart carried two margins -- t_min = 1 mm and a Wachter-Binder origin
## offset of 256 ulps (0.24 mm at |z| = 14) -- and a surface inside either
## margin was never hit. The measured casualty was the aquarium water whose
## front face sits 0.14 mm behind the glass (spec 2026-09-13-self-skip-...).
##
## FIXTURE. pt_transparent_alpha_gate.gd's layout (camera looking straight
## down -Z, 6x6 panes dead-on, 20x20 emissive backdrop), shifted by Z_OFF = +16
## so the origin-offset margin at the pane (|z| ~= 14 -> 0.24 mm) is ALSO larger
## than the 0.1 mm gap; at the sibling gate's z = -2 only the 1 mm t_min would
## be exercised. A teal emissive PLATE the size of the pane sits GAP behind
## the pane's back face. Every probe is a ratio: through-pane / plate-alone
## (pane hidden), so emission, exposure and tonemap cancel.
##
##   T1  blend pane alpha 0.5, plate 0.1 mm behind   -> 0.5 (half the plate)
##   T2  blend pane alpha 0.5, plate 5 mm behind     -> 0.5, equal to T1 +-0.5%
##   T3  blend pane alpha 0.5, no plate (backdrop)   -> 0.5, equal to the
##       pre-fix reading +-0.5% (bounds the shared-edge double-pass property)
##   T4a converted-glass pane, plate 5 mm behind     -> pre-fix reading +-0.5%
##   T4b converted-glass pane, plate 0.1 mm behind   -> equal to T4a +-0.5%
##
## T1 and T4b are RED on the engine before the fix by construction: the plate is
## inside both margins and the ray restarts past it, so they read the backdrop
## (different colour, different ratio). T2, T3, T4a hold the fix to zero
## collateral. T3_REF_PREFIX / T4A_REF_PREFIX are the readings of THIS gate on
## the pre-fix engine (build 9c2fe35ffe + spec commit), recorded before the
## fix so the post-fix assertion can newly fail.

const FRAMES := 128
const Z_OFF := 16.0

const CAM_POS := Vector3(0, 0, 5 + Z_OFF)
const CAM_TARGET := Vector3(0, 0, -5 + Z_OFF)
const CAM_FOV := 25.0
const PANE_SIZE := Vector3(6, 6, 0.05)
const PANE_Z := -2.0 + Z_OFF
const PLATE_SIZE := Vector3(6, 6, 0.05)
const BACKDROP_SIZE := Vector3(20, 20, 0.1)
const BACKDROP_Z := -5.0 + Z_OFF
const BACKDROP_EMISSION := Color(0.6, 0.5, 0.4)
const PLATE_EMISSION := Color(0.06, 0.50, 0.71)
const EMISSION_ENERGY := 3.0

const GAP_THIN := 0.0001 # 0.1 mm -- inside both pre-fix margins
const GAP_WIDE := 0.005 # 5 mm -- outside both

const BLEND_ALPHA := 0.5
const HALF_MIN := 0.47
const HALF_MAX := 0.53
const REL_TOL := 0.005

# Pre-fix readings of T3 and T4a on this gate. Filled in by Task 1 Step 3 from
# the red run; -1.0 means "not yet recorded" and fails the check on purpose.
const T3_REF_PREFIX := -1.0
const T4A_REF_PREFIX := -1.0

var _failures: Array[String] = []
var _checks: int = 0


func _ready() -> void:
	print("\n=== T1: blend pane, plate 0.1 mm behind ===")
	var t1 := await _measure_layer_ratio("blend", GAP_THIN)
	print("  T1 ratio = %.6f (theory 0.5)" % t1)
	_check_band("T1", t1, HALF_MIN, HALF_MAX)

	print("\n=== T2: blend pane, plate 5 mm behind ===")
	var t2 := await _measure_layer_ratio("blend", GAP_WIDE)
	print("  T2 ratio = %.6f (theory 0.5)" % t2)
	_check_band("T2", t2, HALF_MIN, HALF_MAX)
	_check_rel("T2 vs T1", t2, t1)

	print("\n=== T3: blend pane, no plate ===")
	var t3 := await _measure_layer_ratio("blend", -1.0)
	print("  T3 ratio = %.6f (theory 0.5, pre-fix ref %.6f)" % [t3, T3_REF_PREFIX])
	_check_band("T3", t3, HALF_MIN, HALF_MAX)
	_check_rel("T3 vs pre-fix", t3, T3_REF_PREFIX)

	print("\n=== T4a: converted-glass pane, plate 5 mm behind ===")
	var t4a := await _measure_layer_ratio("glass", GAP_WIDE)
	print("  T4a ratio = %.6f (pre-fix ref %.6f)" % [t4a, T4A_REF_PREFIX])
	_check_rel("T4a vs pre-fix", t4a, T4A_REF_PREFIX)

	print("\n=== T4b: converted-glass pane, plate 0.1 mm behind ===")
	var t4b := await _measure_layer_ratio("glass", GAP_THIN)
	print("  T4b ratio = %.6f" % t4b)
	_check_rel("T4b vs T4a", t4b, t4a)

	print("")
	if _failures.is_empty():
		print("PASS: all %d thin-layer checks passed." % _checks)
		get_tree().quit(0)
	else:
		for f in _failures:
			print("FAIL - %s" % f)
		print("FAIL: %d of %d checks failed." % [_failures.size(), _checks])
		get_tree().quit(1)


func _check_band(p_name: String, p_v: float, p_lo: float, p_hi: float) -> void:
	_checks += 1
	if p_v < p_lo or p_v > p_hi:
		_failures.append("%s: ratio %.6f outside [%.2f, %.2f]" % [p_name, p_v, p_lo, p_hi])


func _check_rel(p_name: String, p_v: float, p_ref: float) -> void:
	_checks += 1
	if p_ref <= 0.0:
		_failures.append("%s: reference %.6f is not a valid reading" % [p_name, p_ref])
		return
	var rel := absf(p_v - p_ref) / p_ref
	if rel > REL_TOL:
		_failures.append("%s: %.6f vs %.6f differ by %.2f%% (max %.1f%%)"
				% [p_name, p_v, p_ref, rel * 100.0, REL_TOL * 100.0])


## Builds backdrop + optional plate + pane + camera, renders with the pane
## hidden (control) and visible (through), returns through/control over the
## centre crop. `p_kind` is "blend" (alphaMode BLEND, alpha 0.5, what the
## glTF importer produces) or "glass" (what the pipeline's
## _apply_glb_transmissive_glass produces: opaque, transmission 1, thin-walled,
## IOR 1.2). `p_gap` < 0 means no plate; the pane then sits over the backdrop.
func _measure_layer_ratio(p_kind: String, p_gap: float) -> float:
	for c in get_children():
		c.queue_free()

	var backdrop := MeshInstance3D.new()
	var backdrop_mesh := BoxMesh.new()
	backdrop_mesh.size = BACKDROP_SIZE
	backdrop.mesh = backdrop_mesh
	backdrop.position = Vector3(0, 0, BACKDROP_Z)
	var backdrop_mat := StandardMaterial3D.new()
	backdrop_mat.emission_enabled = true
	backdrop_mat.emission = BACKDROP_EMISSION
	backdrop_mat.emission_energy_multiplier = EMISSION_ENERGY
	backdrop.material_override = backdrop_mat
	add_child(backdrop)

	if p_gap >= 0.0:
		# The pane's back face is at PANE_Z - PANE_SIZE.z/2; the plate's FRONT
		# face must be exactly p_gap behind it.
		var plate := MeshInstance3D.new()
		var plate_mesh := BoxMesh.new()
		plate_mesh.size = PLATE_SIZE
		plate.mesh = plate_mesh
		plate.position = Vector3(0, 0, PANE_Z - PANE_SIZE.z * 0.5 - p_gap - PLATE_SIZE.z * 0.5)
		var plate_mat := StandardMaterial3D.new()
		plate_mat.emission_enabled = true
		plate_mat.emission = PLATE_EMISSION
		plate_mat.emission_energy_multiplier = EMISSION_ENERGY
		plate.material_override = plate_mat
		add_child(plate)

	var pane := MeshInstance3D.new()
	var pane_mesh := BoxMesh.new()
	pane_mesh.size = PANE_SIZE
	pane.mesh = pane_mesh
	pane.position = Vector3(0, 0, PANE_Z)
	var pane_mat := StandardMaterial3D.new()
	if p_kind == "blend":
		pane_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS
		pane_mat.albedo_color = Color(1, 1, 1, BLEND_ALPHA)
	else:
		# Mirrors image_glb_creation.gd::_apply_glb_transmissive_glass.
		pane_mat.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
		pane_mat.albedo_color = Color(1, 1, 1, 1)
		pane_mat.metallic = 0.0
		pane_mat.metallic_specular = 0.5
		pane_mat.roughness = 0.0
		pane_mat.transmission = 1.0
		pane_mat.ior = 1.2
		pane_mat.thickness = 0.0
	pane_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	pane.material_override = pane_mat
	add_child(pane)

	var cam := Camera3D.new()
	# look_at_from_position() BEFORE add_child() -- see pt_transparent_alpha_gate.gd.
	cam.look_at_from_position(CAM_POS, CAM_TARGET, Vector3.UP)
	cam.fov = CAM_FOV
	add_child(cam)
	cam.make_current()

	var env := _new_env(Color(0, 0, 0))
	env.set_pathtracing_max_bounces(4)
	await _settle_sky()

	pane.visible = false
	var control_img: Image = await _render_accum(env, get_viewport().get_viewport_rid(), FRAMES)
	var control := _measure_crop(control_img, 0.35, 0.65)

	pane.visible = true
	await _settle()
	var through_img: Image = await _render_accum(env, get_viewport().get_viewport_rid(), FRAMES)
	var through := _measure_crop(through_img, 0.35, 0.65)

	print("  control mean %.6f (r %.4f g %.4f b %.4f), through mean %.6f (r %.4f g %.4f b %.4f)"
			% [control["mean"], control["r"], control["g"], control["b"],
				through["mean"], through["r"], through["g"], through["b"]])
	if control["mean"] < 1e-6:
		_checks += 1
		_failures.append("control render is black (%.8f) -- nothing behind the pane is visible"
				% control["mean"])
		return 0.0
	return float(through["mean"]) / float(control["mean"])


# ===========================================================================
# Helpers copied VERBATIM from pt_transparent_alpha_gate.gd (which copied them
# from pt_transparent_shadow_gate.gd; not on the shared base class).
# ===========================================================================

func _new_env(p_bg: Color) -> Environment:
	var pano := Image.create(8, 4, false, Image.FORMAT_RGBF)
	pano.fill(p_bg)
	var sky_mat := PanoramaSkyMaterial.new()
	sky_mat.panorama = ImageTexture.create_from_image(pano)
	sky_mat.energy_multiplier = 1.0
	var sky := Sky.new()
	sky.sky_material = sky_mat
	sky.process_mode = Sky.PROCESS_MODE_QUALITY

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.background_energy_multiplier = 1.0
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


func _measure_crop(p_img: Image, p_lo: float, p_hi: float) -> Dictionary:
	var w := p_img.get_width()
	var h := p_img.get_height()
	var r := 0.0
	var g := 0.0
	var b := 0.0
	var n := 0
	for y in range(int(h * p_lo), int(h * p_hi)):
		for x in range(int(w * p_lo), int(w * p_hi)):
			var c := p_img.get_pixel(x, y)
			r += c.r
			g += c.g
			b += c.b
			n += 1
	var inv := 1.0 / float(maxi(n, 1))
	r *= inv
	g *= inv
	b *= inv
	return {"r": r, "g": g, "b": b, "mean": (r + g + b) / 3.0, "n": n}


func _settle() -> void:
	for _i in range(3):
		await get_tree().process_frame


func _settle_sky() -> void:
	await get_tree().create_timer(1.0).timeout
```

`pipeline_references/tests/pt_thin_layer_gate_scene.tscn`:

```
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://tests/pt_thin_layer_gate.gd" id="1_gate"]

[node name="PTThinLayerGate" type="Node"]
script = ExtResource("1_gate")
```

- [ ] **Step 2: Run it on the current engine and confirm it is red for the right reasons**

```bash
./bin/godot.windows.editor.x86_64.console.exe --rendering-driver vulkan --path pipeline_references res://tests/pt_thin_layer_gate_scene.tscn 2>&1 | grep -E "^===|ratio =|control mean|FAIL|PASS|SCRIPT ERROR|Parse Error"
```

Expected on the current engine:
- No `SCRIPT ERROR` lines.
- `T1 ratio` is **not** in [0.47, 0.53] — the through-pane crop shows the backdrop's `(0.6, 0.5, 0.4)` blend, not half the teal plate. Its `through` r/g/b line has r > b (backdrop), while the `control` line has b > r (plate).
- `T2 ratio` ≈ 0.50 and `T3 ratio` ≈ 0.50.
- `T4a ratio` ≈ 0.98 (smooth thin IOR-1.2 pane; two Fresnel losses of ~0.8%).
- `T4b ratio` differs from T4a by more than 0.5% and its `through` line has r > b.
- `FAIL - T3 vs pre-fix: ... reference -1.000000` and `FAIL - T4a vs pre-fix: ...` — the placeholder references fail on purpose until Step 3.

If T1 passes on the current engine the gate is not measuring the defect — stop and check the plate position arithmetic (`PANE_Z - 0.025 - gap - 0.025`) before doing anything else.

- [ ] **Step 3: Record the pre-fix references**

Copy the printed `T3 ratio` and `T4a ratio` values (six decimals) into the two constants:

```gdscript
const T3_REF_PREFIX := 0.xxxxxx # pre-fix, engine 9c2fe35ffe, 2026-09-13
const T4A_REF_PREFIX := 0.xxxxxx # pre-fix, engine 9c2fe35ffe, 2026-09-13
```

Re-run the command from Step 2. Expected now: exactly two failures, `T1` (band) and `T4b vs T4a` (rel); T2, T3 and T4a checks pass. Save the full output to `<scratchpad>/g26/gate_prefix.log`.

- [ ] **Step 4: Note the Z_OFF deviation in the spec**

Append under the spec's `## Gate` heading:

```markdown
Implementation note (Task 1): the fixture is shifted by `Z_OFF = +16` on z so
that at the pane (|z| ≈ 14) the 256-ulp origin offset is 0.24 mm — larger than
the 0.1 mm gap — and both pre-fix margins are exercised, not only `t_min`.
Pre-fix readings on engine 9c2fe35ffe: T3 = <value>, T4a = <value>; T1 and T4b
read the backdrop through the pane, as predicted.
```

- [ ] **Step 5: Commit the red gate**

```bash
git add pipeline_references/tests/pt_thin_layer_gate.gd pipeline_references/tests/pt_thin_layer_gate_scene.tscn docs/superpowers/specs/2026-09-13-self-skip-through-events-design.md
git commit -m "test(pt): thin-layer gate for Gap #26 -- red on the current engine by construction

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: Payload, raygen restart, hit-shader skip, any-hit guard

**Files:**
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_inc.glsl:49-58` (`PathPayload`), `:117-126` (`PathState`), `:128-150` (`path_unpack` / `path_pack`)
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/scene_raytracing_raygen.glsl:52-60` (init), `:93` and `:105` (trace calls), `:113-115` (restart), any-hit `main()` (~`:735`)
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl:1274` (unpack), `:1391-1405` (pass-through), `:2268` (write-back)

**Interfaces:**
- Consumes: nothing new.
- Produces: `PathPayload.skip_geom`, `PathPayload.skip_prim` (`uint`), `PathState.skip_geom`, `PathState.skip_prim`, `const uint RT_SKIP_NONE`. Task 3 relies on the any-hit guard reading `payload.skip_geom` / `payload.skip_prim`.

- [ ] **Step 1: Payload fields**

In `raytracing_inc.glsl`, immediately before `struct PathPayload {`:

```glsl
/// "No triangle to skip." A restart with skip_geom == RT_SKIP_NONE uses the
/// pre-Gap-#26 margins (offset_ray_origin + t_min 0.001) and is byte-identical
/// to the engine before the fix.
const uint RT_SKIP_NONE = 0xFFFFFFFFu;
```

Extend `PathPayload` after `float mis_ray_pdf;`:

```glsl
	// Gap #26. The triangle a THROUGH-event (Transparent BSDF pass-through,
	// transmissive-lobe sample) just crossed. The raygen restarts such a ray at
	// the exact hit point with t_min = 0 and the any-hit stage refuses this one
	// triangle by identity -- Cycles' ray->self.prim -- so a surface 0.1 mm
	// behind a pane is hit instead of being skipped by a distance margin.
	uint skip_geom; //  4 bytes - gl_InstanceCustomIndexEXT, or RT_SKIP_NONE
	uint skip_prim; //  4 bytes - gl_PrimitiveID within that geometry
```

Update the byte-count comments if the struct header states a total (48 → 56).

Extend `PathState` after `float mis_ray_pdf;`:

```glsl
	uint skip_geom;
	uint skip_prim;
```

In `path_unpack`, after `s.mis_ray_pdf = p.mis_ray_pdf;`:

```glsl
	s.skip_geom = p.skip_geom;
	s.skip_prim = p.skip_prim;
```

In `path_pack`, after `p.mis_ray_pdf = s.mis_ray_pdf;`:

```glsl
	p.skip_geom = s.skip_geom;
	p.skip_prim = s.skip_prim;
```

- [ ] **Step 2: Raygen — initialise, per-ray t_min, exact restart**

In `trace_one_sample` (`scene_raytracing_raygen.glsl`), after `ps.mis_ray_pdf = RT_MIS_PDF_NONE;`:

```glsl
	ps.skip_geom = RT_SKIP_NONE;
	ps.skip_prim = RT_SKIP_NONE;
```

After `vec3 ray_dir = p_dir;`:

```glsl
	// Gap #26: a ray that carries a skip id restarts at the exact hit point
	// with no minimum distance; every other ray keeps the historical 0.001.
	float t_min = 0.001;
```

Replace the two trace calls' literal `0.001` with `t_min`:

```glsl
		hitObjectTraceRayEXT(hitObject, tlas, ray_flags, 0xFF, 0, 0, 0, ray_origin, t_min, ray_dir, 10000.0, 0);
```
```glsl
		traceRayEXT(tlas, ray_flags, 0xFF, 0, 0, 0, ray_origin, t_min, ray_dir, 10000.0, 0);
```

Replace the restart block:

```glsl
		// Reconstruct the next ray origin from the current ray + hit distance, apply bias
		vec3 hit_pos = ray_origin + ray_dir * ps.hit_t;
		ray_origin = offset_ray_origin(hit_pos, ps.offset_normal);
		ray_dir = ps.next_ray_dir;
```

with:

```glsl
		// Reconstruct the next ray origin from the current ray + hit distance.
		vec3 hit_pos = ray_origin + ray_dir * ps.hit_t;
		// Gap #26. After a THROUGH-event the hit shader left the crossed
		// triangle's id in skip_geom/skip_prim and the any-hit stage refuses
		// exactly that triangle, so the restart needs no distance margin at
		// all: exact hit point, t_min 0. That is what lets a face 0.1 mm
		// behind a pane be hit (the aquarium water, spec 2026-09-13). Both
		// margins were each individually enough to skip it -- t_min 0.001 is
		// 1 mm, the 256-ulp offset is 0.24-0.49 mm at room-scale coordinates
		// -- and zeroing t_min without the id skip re-hit the pane until the
		// bounce cap (the black window). Every ray WITHOUT a skip id takes the
		// historical path unchanged.
		const bool skip_active = (ps.skip_geom != RT_SKIP_NONE);
		ray_origin = skip_active ? hit_pos : offset_ray_origin(hit_pos, ps.offset_normal);
		t_min = skip_active ? 0.0 : 0.001;
		ray_dir = ps.next_ray_dir;
```

- [ ] **Step 3: Hit shader — clear at entry, set at the two through-sites**

In `shade_and_bounce`, immediately after `PathState ps = path_unpack(payload);` (`~:1274`):

```glsl
	// Gap #26: the skip id describes the segment that just ENDED. Cleared here
	// so every outcome of this hit defaults to "no skip"; only the two
	// through-events below set it again.
	ps.skip_geom = RT_SKIP_NONE;
	ps.skip_prim = RT_SKIP_NONE;
```

In the Transparent BSDF pass-through branch (`~:1391`), after `ps.next_ray_dir = gl_WorldRayDirectionEXT;` and before its `ps.rng_packed = ...`:

```glsl
			// Gap #26: through-event. The next ray may hit anything at any
			// distance except this triangle.
			ps.skip_geom = gl_InstanceCustomIndexEXT;
			ps.skip_prim = gl_PrimitiveID;
```

At the write-back (`~:2268`), after `ps.hit_t = gl_HitTEXT;`:

```glsl
	// Gap #26: a transmissive-lobe sample is a through-event (thin or thick).
	if (took_transmissive_lobe) {
		ps.skip_geom = gl_InstanceCustomIndexEXT;
		ps.skip_prim = gl_PrimitiveID;
	}
```

- [ ] **Step 4: Any-hit guard**

In the `#[any_hit]` stage's `main()`, as the first statements (before `uint geometry_idx = gl_InstanceCustomIndexEXT;`):

```glsl
	// Gap #26: refuse the one triangle the previous segment passed through.
	// Runs for every instance that has any-hit enabled (blend, alpha-scissor,
	// transmissive -- see build_tlas). Opaque instances are FORCE_OPAQUE and
	// never produce a through-event, so they need no guard.
	if (payload.skip_geom == gl_InstanceCustomIndexEXT && payload.skip_prim == gl_PrimitiveID) {
		ignoreIntersectionEXT;
	}
```

- [ ] **Step 5: Build, then read stderr on the first render**

```bash
python -m SCons platform=windows target=editor tests=yes -j8 2>&1 | tail -3
./bin/godot.windows.editor.x86_64.console.exe --rendering-driver vulkan --path pipeline_references res://tests/pt_thin_layer_gate_scene.tscn 2>&1 | grep -E "ERROR|error|^===|ratio =|FAIL|PASS" | head -40
```

Expected: no shader compile errors; `T1` now in band (≈0.50, `through` line with b > r); `T2`, `T3`, `T4a` pass; **`T4b vs T4a` still fails** — the converted-glass pane is `FORCE_OPAQUE`, its any-hit never runs, and the exact-origin restart with `t_min 0` then re-hits the pane's own triangle. (If T4b already passes here, note it: it would mean the pane is not FORCE_OPAQUE and Task 3's premise needs re-checking rather than assuming.)

- [ ] **Step 6: Commit**

```bash
git add servers/rendering/renderer_rd/shaders/raytracing/raytracing_inc.glsl servers/rendering/renderer_rd/shaders/raytracing/scene_raytracing_raygen.glsl servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl
git commit -m "fix(pt): Gap #26 -- a through-event restarts at the hit point and skips its own triangle by id

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: Transmissive instances run the any-hit stage (skip-only)

**Files:**
- Modify: `servers/rendering/renderer_rd/forward_clustered/render_raytracing.h:212-227` (flag enum)
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_data_inc.glsl:123` (flag mirror)
- Modify: `servers/rendering/renderer_rd/forward_clustered/render_raytracing.cpp` mesh site `~:3060-3102`, multimesh site `~:2905-2920`, emissive gather `~:3741`
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/scene_raytracing_raygen.glsl` any-hit `main()` (after the Task 2 guard)

**Interfaces:**
- Consumes: Task 2's any-hit guard.
- Produces: `RT_MAT_FLAG_ANYHIT_SKIP_ONLY = 16u` (C++ and GLSL).

- [ ] **Step 1: The flag, both sides**

`render_raytracing.h`, after `RT_MAT_FLAG_BLEND = 8u,`:

```cpp
	// Bit 4 (Gap #26): the instance runs the any-hit stage ONLY so the
	// self-skip guard can refuse the triangle a through-event just crossed. Set
	// on transmissive (converted-glass) materials that use no alpha at all. The
	// any-hit must not apply its alpha test to these, and the emissive-light
	// gather must keep treating them as opaque emitters. MIRRORED IN
	// raytracing_data_inc.glsl.
	RT_MAT_FLAG_ANYHIT_SKIP_ONLY = 16u,
```

`raytracing_data_inc.glsl`, after the `RT_MAT_FLAG_BLEND` define:

```glsl
#define RT_MAT_FLAG_ANYHIT_SKIP_ONLY 16u // Bit 4. MIRRORS render_raytracing.h (Gap #26).
```

- [ ] **Step 2: Mesh site — set the flag, keep any-hit on**

In `render_raytracing.cpp`, the mesh-path block that today reads:

```cpp
			{
				RT_MaterialData push_mat_data = mat_data->data;
				if (surf->shader && surf->shader->rt_uses_alpha_blending()) {
					push_mat_data.flags |= RT_MAT_FLAG_BLEND;
				}
				material_data.push_back(push_mat_data);
			}
```

becomes:

```cpp
			// Gap #26: a transmissive material with no alpha usage runs any-hit
			// for the self-skip guard only.
			const bool surf_uses_any_alpha = surf->shader && (surf->shader->uses_alpha_clip || surf->shader->uses_blend_alpha || surf->shader->uses_alpha);
			const bool surf_transmissive = (mat_data->feature_bits & SceneShaderRaytracing::RT_FLAG_TRANSMISSIVE_GEOMETRY) != 0;
			const bool surf_anyhit_skip_only = surf_transmissive && !surf_uses_any_alpha && mat_data->rt_sbt_offset == 0;
			{
				RT_MaterialData push_mat_data = mat_data->data;
				if (surf->shader && surf->shader->rt_uses_alpha_blending()) {
					push_mat_data.flags |= RT_MAT_FLAG_BLEND;
				}
				if (surf_anyhit_skip_only) {
					push_mat_data.flags |= RT_MAT_FLAG_ANYHIT_SKIP_ONLY;
				}
				material_data.push_back(push_mat_data);
			}
```

and the `FORCE_OPAQUE` decision a few lines below:

```cpp
			} else {
				// Standard material: FORCE_OPAQUE if no alpha usage.
				bool is_alpha = surf->shader && (surf->shader->uses_alpha_clip || surf->shader->uses_blend_alpha || surf->shader->uses_alpha);
				if (!is_alpha) {
					inst_flags |= RD::ACCELERATION_STRUCTURE_INSTANCE_FORCE_OPAQUE_BIT;
				}
			}
```

becomes:

```cpp
			} else {
				// Standard material: FORCE_OPAQUE if no alpha usage -- unless it
				// is transmissive, which needs any-hit for the Gap #26 skip.
				if (!surf_uses_any_alpha && !surf_anyhit_skip_only) {
					inst_flags |= RD::ACCELERATION_STRUCTURE_INSTANCE_FORCE_OPAQUE_BIT;
				}
			}
```

Custom-shader transmissive materials (`rt_sbt_offset > 0`) are out of scope and keep today's behaviour; `surf_anyhit_skip_only` is false for them by construction.

- [ ] **Step 3: Multimesh site — the same two edits**

Around `~:2905`, the block:

```cpp
				} else {
					bool is_alpha = mm_surf->shader &&
							(mm_surf->shader->uses_alpha_clip || mm_surf->shader->uses_blend_alpha || mm_surf->shader->uses_alpha);
					if (!is_alpha) {
						inst_flags |= RD::ACCELERATION_STRUCTURE_INSTANCE_FORCE_OPAQUE_BIT;
					}
				}
				bool mat_uses_blend = mm_surf->shader && mm_surf->shader->rt_uses_alpha_blending();
```

becomes:

```cpp
				} else {
					bool is_alpha = mm_surf->shader &&
							(mm_surf->shader->uses_alpha_clip || mm_surf->shader->uses_blend_alpha || mm_surf->shader->uses_alpha);
					// Gap #26: see the mesh site.
					const bool mm_anyhit_skip_only = !is_alpha &&
							(mat_data->feature_bits & SceneShaderRaytracing::RT_FLAG_TRANSMISSIVE_GEOMETRY) != 0;
					if (!is_alpha && !mm_anyhit_skip_only) {
						inst_flags |= RD::ACCELERATION_STRUCTURE_INSTANCE_FORCE_OPAQUE_BIT;
					}
					mat_anyhit_skip_only = mm_anyhit_skip_only;
				}
				bool mat_uses_blend = mm_surf->shader && mm_surf->shader->rt_uses_alpha_blending();
```

Declare `bool mat_anyhit_skip_only = false;` next to where `inst_flags` is declared for this multimesh surface (before the `switch` on cull mode), and where the multimesh path builds its `push_mat_data` (the two `material_data.push_back(push_mat_data)` sites at `~:3153` and `~:3225` both derive from `pending`), carry it through `PendingMMSurface`: add `bool anyhit_skip_only = false;` to the struct, set `pending.anyhit_skip_only = mat_anyhit_skip_only;` beside `pending.inst_flags = inst_flags;`, and at both push sites, after the existing `RT_MAT_FLAG_BLEND` handling:

```cpp
				if (pending.anyhit_skip_only) {
					push_mat_data.flags |= RT_MAT_FLAG_ANYHIT_SKIP_ONLY;
				}
```

(Read the `PendingMMSurface` struct definition and the two push sites first; match their existing field naming.)

- [ ] **Step 4: Emissive gather — skip-only instances are still opaque emitters**

At `~:3741`:

```cpp
		if ((instance_flags[i] & RD::ACCELERATION_STRUCTURE_INSTANCE_FORCE_OPAQUE_BIT) == 0) {
			continue;
		}
```

becomes:

```cpp
		// Gap #26: an instance that runs any-hit only for the self-skip guard
		// (RT_MAT_FLAG_ANYHIT_SKIP_ONLY) has no alpha cut-outs; it is an opaque
		// emitter for NEE purposes exactly as before.
		if ((instance_flags[i] & RD::ACCELERATION_STRUCTURE_INSTANCE_FORCE_OPAQUE_BIT) == 0 &&
				(material_data[i].flags & RT_MAT_FLAG_ANYHIT_SKIP_ONLY) == 0) {
			continue;
		}
```

`material_data[i]` is already read a few lines below (`const RT_MaterialData &mat = material_data[i];`), which confirms the two arrays are parallel.

- [ ] **Step 5: Any-hit — skip-only materials do nothing else**

In the any-hit `main()`, directly after the Task 2 guard and before `uint geometry_idx = gl_InstanceCustomIndexEXT;`... the guard already read `gl_InstanceCustomIndexEXT`; add, after the existing `GeometryData geom = geometries[geometry_idx];` line and before the `#ifdef RT_CUSTOM_HIT_GROUP`:

```glsl
	// Gap #26: this instance runs any-hit only for the guard above. No alpha
	// test -- its albedo alpha is meaningless (opaque material) and testing it
	// could cut holes that the raster path never had.
	if ((materials[geometry_idx].flags & RT_MAT_FLAG_ANYHIT_SKIP_ONLY) != 0u) {
		return;
	}
```

- [ ] **Step 6: Build, run the gate — all five green**

```bash
python -m SCons platform=windows target=editor tests=yes -j8 2>&1 | tail -3
./bin/godot.windows.editor.x86_64.console.exe --rendering-driver vulkan --path pipeline_references res://tests/pt_thin_layer_gate_scene.tscn 2>&1 | grep -E "ERROR|^===|ratio =|FAIL|PASS"
```

Expected: `PASS: all 8 thin-layer checks passed.` (T1 band, T2 band, T2 vs T1, T3 band, T3 vs pre-fix, T4a vs pre-fix, T4b vs T4a — plus none of the control-black checks). Save output to `<scratchpad>/g26/gate_fixed.log`.

- [ ] **Step 7: Doctest suite unchanged**

```bash
./bin/godot.windows.editor.x86_64.console.exe --test 2>&1 | tail -3
```

Expected: the same pass count as before this work (1558 test cases at last run), 0 failures.

- [ ] **Step 8: Commit**

```bash
git add servers/rendering/renderer_rd/forward_clustered/render_raytracing.h servers/rendering/renderer_rd/forward_clustered/render_raytracing.cpp servers/rendering/renderer_rd/shaders/raytracing/raytracing_data_inc.glsl servers/rendering/renderer_rd/shaders/raytracing/scene_raytracing_raygen.glsl
git commit -m "fix(pt): Gap #26 -- transmissive instances run any-hit for the self-skip only

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: Whole-suite, asset checks, roadmap

**Files:**
- Modify: `PATH_TRACER_QUALITY_ROADMAP.md` (gap table row 26, new §11.20)
- Create (scratch only): `<scratchpad>/g26/` renders and logs

**Interfaces:** none new.

- [ ] **Step 1: Every gate, no re-baselining**

```bash
for s in pipeline_references/tests/pt_*_gate_scene.tscn; do n=$(basename "$s" .tscn); ./bin/godot.windows.editor.x86_64.console.exe --rendering-driver vulkan --path pipeline_references "res://tests/$n.tscn" > "<scratchpad>/g26/$n.log" 2>&1; echo "$n exit=$?"; done
```

Expected: every gate exits 0 **except** `pt_sky_energy_gate`, whose pre-existing failure (probe B 1.085, probe C 9.3% drift) is documented in the roadmap and must read the **same values** as before — compare its log to the previous run's numbers; any movement there is a regression to investigate, not to re-baseline.

- [ ] **Step 2: replay192 — water gains teal, window unchanged**

Build a scratch copy of the live project as in earlier sessions (`*.gd`, `*.tscn`, `project.godot`, `day.exr`, `night.exr`, `tests/`; `input_json/replay192_fhd.json` with `render_quality = "FHD"`), render with the new `bin/` build to `<scratchpad>/g26/r192_fixed.png`, and measure against the pre-fix `tank_b.png` (this session's `scratchpad/tank2/tank_b.png`, same build lineage, 3 × 256):

```python
from PIL import Image; import numpy as np
a=np.asarray(Image.open("tank_b.png").convert("RGB")).astype(float)   # pre-fix
b=np.asarray(Image.open("r192_fixed.png").convert("RGB")).astype(float)
crop=lambda im,box: im[box[1]:box[3],box[0]:box[2]].reshape(-1,3).mean(0)
w0=crop(a,(420,645,780,700)); w1=crop(b,(420,645,780,700))   # water above the plants
print("water B-R pre %.1f post %.1f"%(w0[2]-w0[0], w1[2]-w1[0]))     # expected: post > pre (teal)
win0=crop(a,(540,190,720,380)); win1=crop(b,(540,190,720,380))       # the window
print("window mean pre %.1f post %.1f (must be within 1%%)"%(win0.mean(),win1.mean()))
```

Expected: water B−R moves positive from −1.3; window mean within 1%. Save the numbers.

- [ ] **Step 3: urbantestdark217 at FHD — frame outside the tank within 1%**

Same scratch route with `d217_fhd.json`, compared to this session's `scratchpad/glass/d217_rr.png` (pre-fix, same route). Mask out the tank (`x 1650-1920, y 225-675`) and report the mean of the rest: expected within 1%.

- [ ] **Step 4: Roadmap row and §11.20**

Add to the gap table:

```markdown
| 26 | **CLOSED 2026-09-13.** After a through-event (Transparent BSDF pass-through, transmissive-lobe sample) the next ray restarted with two distance margins -- `t_min` 1 mm and a 256-ulp origin offset (0.24-0.49 mm at room scale) -- and any surface inside either was never hit. The aquarium water's front face sits 0.14 mm behind the glass: clear tank where Cycles shows teal. Fixed Cycles' way: exact restart, `t_min` 0, skip the crossed triangle by id in any-hit; transmissive instances now run any-hit (skip-only). Opaque bounces byte-identical. Gate `pt_thin_layer_gate` (T1/T4b red before, green after). See §11.20. | `raytracing_inc.glsl` (payload), `scene_raytracing_raygen.glsl` (restart, any-hit), `raytracing_closest_hit_common_inc.glsl` (two through-sites), `render_raytracing.cpp` (FORCE_OPAQUE, emissive gather) | `intern/cycles/kernel/bvh/util.h` (`intersection_skip_self`) | **High** |
```

Add §11.20 at the end of §11 with: the symptom and the three eliminated suspects (denoiser, lamp specular, mirror share), the glass-removed proof, the two-margin arithmetic, the black-window result of the `t_min 0` shortcut, the gate readings before/after, and the replay192/217 numbers from Steps 2–3.

- [ ] **Step 5: Commit**

```bash
git add PATH_TRACER_QUALITY_ROADMAP.md docs/superpowers/plans/2026-09-13-self-skip-through-events.md
git commit -m "docs(pt): Gap #26 closed -- thin layers behind a pane are hit; roadmap 11.20

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Self-review

- **Spec coverage:** payload fields (T2 S1); hit-shader clear-at-entry + two through-sites (T2 S3 — the spec's "single write-back site" wording is implemented as clear-at-entry + set-at-site, which is strictly safer for early-return paths); raygen exact restart + per-ray t_min at both trace calls (T2 S2); any-hit guard before the custom split (T2 S4); TLAS flags at mesh and multimesh sites with procedural untouched (T3 S2–S3); the alpha-test concern for transmissive instances (T3 S5, via the new flag — the spec argued it was harmless, the flag makes it certain); emissive gather kept consistent (T3 S4 — not in the spec, found while reading the FORCE_OPAQUE consumer at `:3741`; without it a transmissive emitter would silently drop out of emissive NEE); gate T1–T4b (T1); suite / replay192 / 217 checks (T4 S1–S3); roadmap (T4 S4). No gaps.
- **Placeholders:** the two `0.xxxxxx` reference constants are filled in Task 1 Step 3 from a measured run, by design; no other placeholders.
- **Type consistency:** `RT_SKIP_NONE` (uint), `skip_geom` / `skip_prim` (uint) identical across payload, state, raygen, hit, any-hit; `RT_MAT_FLAG_ANYHIT_SKIP_ONLY = 16u` identical in C++ and GLSL; `surf_anyhit_skip_only` / `mm_anyhit_skip_only` / `pending.anyhit_skip_only` are the three names for the same predicate at the three sites, each defined where used.
