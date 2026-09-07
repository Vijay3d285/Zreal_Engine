# Transparent BSDF Closure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep alpha-blended surfaces inside the path tracer with a Cycles-style Transparent BSDF, instead of ejecting them to the raster overlay.

**Architecture:** A stochastic transparent branch in `shade_and_bounce`: draw `u < (1 - alpha)` and the ray continues unchanged, consuming no diffuse/glossy/total bounce; otherwise shade as today. Alpha-blended surfaces stop being dropped from the TLAS and stop being drawn by the raster overlay, in one commit. Shadow rays gain an alpha term so those surfaces attenuate rather than block.

**Tech Stack:** C++ (Godot RD renderer), GLSL (Vulkan ray tracing), SCons, GDScript gate scenes.

**Spec:** `docs/superpowers/specs/2026-09-07-transparent-bsdf-closure-design.md`

## Global Constraints

- **`git add` uses explicit paths only.** Never `-A`, never `.`, never `git commit -a`.
- **Every `.gd` file directly under `pipeline_references/` is the user's own work.** Never stage, commit, revert, checkout over, or stash any of them. **NEW** files under `pipeline_references/tests/` may be created and staged — that subdirectory is the only writable area there.
- **Build:** `python -m SCons platform=windows target=editor tests=yes -j8`. Bare `scons` is not on PATH and its failure exits 0 under Bash.
- **`glsl_builders.py` performs no GLSL validation.** A clean `scons` exit is near-zero evidence about shader correctness — only a render proves a shader compiles and runs. Every GLSL task ends in a render, not a build.
- **Renders on this build are bit-reproducible** — measured rmse `0.000000`, `0.00%` of pixels across two runs of the same project and binary. Exact comparison is a valid acceptance criterion. Compare within the SAME project directory; a cross-project comparison previously produced a 20.39% delta that was entirely the project difference.
- **C++/GLSL struct and constant parity is enforced by hand.** Anything mirrored between `render_raytracing.h`/`scene_shader_raytracing.h` and the GLSL headers must change in both, in the same commit. `MaterialData` is 192 bytes with a `static_assert`; do not change its size.
- **Bit-field errors here corrupt a neighbouring field's readback and leave the render plausible rather than visibly wrong.** Treat every packed-word change as load-bearing.
- **`gl_ObjectToWorldEXT` does not exist inside a ray query.** Use `rayQueryGetIntersectionObjectToWorldEXT(rq, true)`.
- **Non-goal:** retiring the raster transparent pass, caustics, or any change to the E1 dielectric closure.

## File Structure

| File | Responsibility | Tasks |
|---|---|---|
| `servers/rendering/renderer_rd/forward_clustered/render_raytracing.h` | `RT_MAT_FLAG_BLEND` bit on the material flags word | 1 |
| `servers/rendering/renderer_rd/forward_clustered/render_raytracing.cpp` | Set that flag from `uses_blend_alpha`; stop dropping `FLAG_PASS_ALPHA` from the TLAS; widen the instance-mask predicate | 1, 3 |
| `servers/rendering/renderer_rd/shaders/raytracing/raytracing_data_inc.glsl` | GLSL mirror of the flag bit | 1 |
| `servers/rendering/renderer_rd/shaders/raytracing/raytracing_inc.glsl` | `RT_PRNG_TRANSPARENT` dimension slot | 3 |
| `servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl` | The transparent branch | 3 |
| `servers/rendering/renderer_rd/shaders/raytracing/scene_raytracing_raygen.glsl` | Widened loop bound; pass the blend flag into `MaterialResult` | 3 |
| `servers/rendering/renderer_rd/forward_clustered/render_forward_clustered.cpp` | Stop the raster overlay drawing what is now traced | 3 |
| `servers/rendering/renderer_rd/shaders/raytracing/raytracing_lights_inc.glsl` | Shadow-ray alpha mix | 4 |
| `pipeline_references/tests/pt_transparent_alpha_gate.gd` (new) | GPU gate | 2 |
| `pipeline_references/tests/pt_transparent_alpha_gate_scene.tscn` (new) | Gate scene entry point | 2 |
| `PATH_TRACER_QUALITY_ROADMAP.md` | Closeout | 5 |

---

### Task 1: Material blend flag

Alpha-scissor materials are already in the TLAS and their base-colour alpha can sit above the scissor threshold but below 1.0. A branch keyed on `alpha < 1` alone would silently turn those translucent. This task adds the precise gate: a per-material bit meaning "this material blends", set only from `uses_blend_alpha`.

**Files:**
- Modify: `servers/rendering/renderer_rd/forward_clustered/render_raytracing.h` (the `flags` field's bit documentation and constants)
- Modify: `servers/rendering/renderer_rd/forward_clustered/render_raytracing.cpp` (`process_material`)
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_data_inc.glsl:136`

**Interfaces:**
- Consumes: nothing.
- Produces: `RT_MAT_FLAG_BLEND` = `8u` (bit 3) on the material flags word, mirrored in GLSL as `RT_MAT_FLAG_BLEND 8u`.

- [ ] **Step 1: Read the existing flag constants — do not trust the GLSL comment**

The authority for this bit layout is the C++ enum at `render_raytracing.h:213-218`:

```cpp
// Material flags for RT (matches GLSL mat_flags bit layout).
enum {
	RT_MAT_FLAG_HAS_NORMAL_MAP = 1u,
	RT_MAT_FLAG_HAS_EMISSION_TEX = 2u,
	RT_MAT_FLAG_POINT_FILTER = 4u,
};
```

**Bits 0, 1 and 2 are all taken. Bit 3 (`8u`) is the first free one** — verified
unreferenced in both languages. The comment at `raytracing_data_inc.glsl:136` says only
`// Bit 0: has_normal_map, Bit 1: has_emission`; it is **stale** and omits bit 2, which is
read at `raytracing_closest_hit_common_inc.glsl:98` (`if ((mat_flags & 4u) != 0u)`) to
select nearest-neighbour texture sampling. An earlier draft of this plan trusted that
comment and assigned bit 2; shipping it would have made every blended material sample its
textures unfiltered and every pixel-art material partially transparent, with no error and
two plausible-looking renders.

- [ ] **Step 2: Add the flag on both sides, and correct the stale comment**

C++ — extend the existing enum, following its naming convention (`RT_MAT_FLAG_*`, values
written as literals, not shifts):

```cpp
// Material flags for RT (matches GLSL mat_flags bit layout).
enum {
	RT_MAT_FLAG_HAS_NORMAL_MAP = 1u,
	RT_MAT_FLAG_HAS_EMISSION_TEX = 2u,
	RT_MAT_FLAG_POINT_FILTER = 4u,
	// Bit 3: the material BLENDS (glTF alphaMode BLEND -> uses_blend_alpha).
	// Keyed on the shader flag, NOT on albedo alpha < 1: alpha-SCISSOR materials
	// are already in the TLAS and their base-colour alpha can sit above the
	// scissor threshold but below 1.0, so an alpha-value test would silently turn
	// every cutout translucent. MIRRORED IN raytracing_data_inc.glsl.
	RT_MAT_FLAG_BLEND = 8u,
};
```

GLSL — `raytracing_data_inc.glsl` has no named mirrors today (bits are tested as bare
literals, e.g. `& 4u`). Add the one named define for the new bit, beside the struct, and
fix the stale field comment at `:136` to list all four bits:

```glsl
#define RT_MAT_FLAG_BLEND 8u // Bit 3. MIRRORS RT_MAT_FLAG_BLEND in render_raytracing.h.
```

```glsl
	uint flags; // Bit 0: has_normal_map, Bit 1: has_emission, Bit 2: point_filter, Bit 3: blend
```

Do not renumber or rename the existing three bits — they are read as bare literals at
`raytracing_closest_hit_common_inc.glsl:98`, `raytracing_emissive_inc.glsl:110` and
`scene_raytracing_raygen.glsl:535`, and those literals are outside this task's scope.

- [ ] **Step 3: Set it in `build_tlas`, from the RT-side signal**

The surface's shader flags are not available inside `process_material`, which takes a material RID. Set the bit where the surface is known — in `build_tlas`, alongside the existing per-surface work.

**Do not write the bit into `mat_data->data`.** `mat_data` is the `process_material()` cache, keyed by material RID and shared across every surface that uses it; mutating it leaks the flag to unrelated surfaces. OR the bit into a local copy of `RT_MaterialData` at each `material_data.push_back` site instead.

**`uses_blend_alpha` is NOT the signal. It does not mean what its name suggests.**
`blend_mode_uses_blend_alpha` (`material_storage.cpp:718`) returns **false for
`BLEND_MODE_MIX`** and true only for ADD / SUB / MUL / PREMULTIPLIED. It means "this
blend mode reads the destination", not "this material is alpha-blended". glTF
`alphaMode: BLEND` produces MIX. An earlier draft of this plan keyed on it and measured
**zero of 55 materials** on the aquarium scene — a gate that can never fire for the
surfaces this whole feature is about.

The signal is the `has_alpha` term inside `rt_uses_alpha_pass()`
(`scene_shader_forward_clustered.h:316-327`). Add an accessor beside it, mirroring its
`rt ? rt->… : …` fallback exactly — the RT classification exists only when a shader has
`#if defined(RT)` divergence, and reading the raster fields directly is wrong for those:

```cpp
		// The "this material is genuinely translucent" half of rt_uses_alpha_pass().
		// Deliberately EXCLUDES that function's no_depth_draw / no_depth_test terms:
		// a material with depth writes disabled but alpha 1.0 is opaque and must not
		// receive the Transparent BSDF.
		//
		// Alpha-SCISSOR is already excluded by the !uses_alpha_clip term -- a pure
		// cutout never enters the alpha pass -- so this needs no separate guard.
		_FORCE_INLINE_ bool rt_uses_alpha_blending() const {
			if (!rt) {
				bool has_read_screen_alpha = uses_screen_texture || uses_depth_texture || uses_normal_texture;
				bool has_base_alpha = (uses_alpha && (!uses_alpha_clip || uses_alpha_antialiasing)) || has_read_screen_alpha;
				return has_base_alpha || uses_blend_alpha;
			}
			bool has_read_screen_alpha = rt->uses_screen_texture || rt->uses_depth_texture || rt->uses_normal_texture;
			bool has_base_alpha = (rt->uses_alpha && (!rt->uses_alpha_clip || rt->uses_alpha_antialiasing)) || has_read_screen_alpha;
			return has_base_alpha || rt->uses_blend_alpha;
		}
```

Call it at every site where you derive the bit. Getting this wrong is invisible in a render — the flag is simply absent, and every alpha surface silently keeps the old behaviour.

- [ ] **Step 4: Build**

Run: `python -m SCons platform=windows target=editor tests=yes -j8`
Expected: `SCONS_EXIT=0`.

- [ ] **Step 5: Verify the signal discriminates, and can report absence**

**Read this before instrumenting — the obvious check cannot work in this task.** The first draft of this step asked for a non-zero count of materials pushed carrying `RT_MAT_FLAG_BLEND`, and that count is *structurally* pinned at zero until Task 3. The skip at `render_raytracing.cpp:2880-2884` `continue`s every `FLAG_PASS_ALPHA` surface **before** the `material_data.push_back` site where the bit is OR'd in, so no blended surface reaches the push at all. Measured: the aquarium scene reported `0 / 55`. That zero is correct behaviour for this task, not a bug — do not "fix" it by removing the skip, which belongs to Task 3 and is atomic with the branch there.

So instrument the signal at the point it is *available*, which is the skip site. Add two temporary counters in `build_tlas`:

- `blend_skipped` — incremented inside the `FLAG_PASS_ALPHA` skip block when `rt_uses_alpha_blending()` returns true for that surface.
- `blend_pushed` — how many entries in `material_data` carry `RT_MAT_FLAG_BLEND`.

Print both. Then render two scenes:

```bash
# Positive: the aquarium. Write the PNG to your scratchpad, never into the read-only tree.
./bin/godot.windows.editor.x86_64.console.exe --verbose     --path "C:/Zlendo2026/ZlenderRender_stage_copy/godot_project" res://main.tscn --     "C:/Zlendo2026/ZlenderRender_stage_copy/godot_project/input_json/urbantestdark180_fishtank_render_input.json"     <scratchpad>/t1_positive.png
```

```bash
# Negative control: an all-opaque gate scene, same binary.
./bin/godot.windows.editor.x86_64.console.exe --verbose     --path pipeline_references res://tests/pt_energy_gate_scene.tscn
```

Expected:

| scene | `blend_skipped` | `blend_pushed` |
|---|---|---|
| aquarium | **> 0** — `003_lionfish`, `cgaxis_..._04`, `cgaxis_..._06` are `alphaMode: BLEND` | `0` (they are skipped before the push) |
| energy gate | `0` | `0` |

**Both directions are required — a detector that cannot report absence is not a detector.** The negative control must also show a non-zero *denominator* (materials were pushed, and none of them blended); a zero-out-of-zero reading proves only that the counter never ran. The measured denominator for that scene is 1.

If `blend_skipped` is zero on the aquarium, the signal is wrong — stop and report it rather than proceeding. This has already happened once, with `uses_blend_alpha` as the signal; that is why Step 3 now specifies `rt_uses_alpha_blending()`. Remove both temporary counters before committing.

The end-to-end claim — that the flag actually arrives in `MaterialData` on the GPU — is not observable until the skip is gone, and is Task 3 Step 10a's acceptance.

- [ ] **Step 6: Commit**

```bash
git add servers/rendering/renderer_rd/forward_clustered/render_raytracing.h servers/rendering/renderer_rd/forward_clustered/render_raytracing.cpp servers/rendering/renderer_rd/shaders/raytracing/raytracing_data_inc.glsl
git commit -m "feat(pt): per-material BLEND flag for the transparent closure"
```

---

### Task 2: The failing gate

Written before the closure exists, so it is proven capable of failing.

**Files:**
- Create: `pipeline_references/tests/pt_transparent_alpha_gate.gd`
- Create: `pipeline_references/tests/pt_transparent_alpha_gate_scene.tscn`

**Interfaces:**
- Consumes: the engine as built after Task 1.
- Produces: a gate printing measured-vs-theory ratios and exiting 0/1.

- [ ] **Step 1: Read the sibling gate first**

`pipeline_references/tests/pt_transparent_shadow_gate.gd` is your template. The harness API is NOT what you might assume — an earlier plan in this project invented five function names that do not exist. Use only:
- entry point `func _ready() -> void:`, NOT `_run_checks()`
- `await _render_accum(env, get_viewport().get_viewport_rid(), FRAMES)` returning an `Image` (defined in `pipeline_references/tests/pt_validation.gd:88`, which your script extends)
- `_measure_crop(p_img, p_lo, p_hi)` returning a Dictionary with keys `mean`, `r`, `g`, `b`
- `_new_env(p_bg: Color) -> Environment`, `await _settle()`, `await _settle_sky()`
- `var _failures: Array[String] = []`, `var _checks: int = 0`, `get_tree().quit(0/1)`

`_new_env`, `_settle`, `_settle_sky` and `_measure_crop` live in `pt_transparent_shadow_gate.gd`, not on the base class — copy them into the new gate, do not edit the original.

**Also copy the camera idiom exactly:** `cam.look_at_from_position(pos, target, Vector3.UP)` BEFORE `add_child`. `Node3D.look_at()` requires the node to be in the tree; calling it before `add_child` errors and silently leaves the camera unaimed, which has already produced two black renders in this project.

- [ ] **Step 2: Create the scene file**

```
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://tests/pt_transparent_alpha_gate.gd" id="1_gate"]

[node name="PTTransparentAlphaGate" type="Node"]
script = ExtResource("1_gate")
```

Root type is `Node`, matching the real sibling scene — not `Node3D`.

- [ ] **Step 3: Write the gate**

Structure, with the harness helpers copied in:

```gdscript
extends "res://tests/pt_validation.gd"

## Transparent BSDF closure GPU gate.
##
##   bin\godot.windows.editor.x86_64.console.exe --path pipeline_references \
##       res://tests/pt_transparent_alpha_gate_scene.tscn
##
## WHAT THIS PROVES. alphaMode BLEND surfaces used to be dropped from the TLAS
## and drawn by a second, rasterized renderer. This measures that a blended pane
## is now TRACED: the radiance behind it must read (1 - alpha) of the control,
## and two stacked panes must read (1 - alpha)^2. The squared case is the one
## that proves layers compose -- a single-pane probe cannot distinguish "one
## layer applied" from "one layer applied twice".

const FRAMES := 128
const P_ALPHA := 0.5

# One pane at alpha 0.5: half the background survives.
const P1_MIN := 0.47
const P1_MAX := 0.53
# Two stacked panes: 0.5^2 = 0.25.
const P2_MIN := 0.22
const P2_MAX := 0.28
# alpha = 1.0 must be indistinguishable from an opaque pane.
const P3_MAX_DELTA := 0.005

var _failures: Array[String] = []
var _checks: int = 0

func _ready() -> void:
	print("\n=== PROBE 1: one blended pane at alpha 0.5 ===")
	await _probe1_single_pane()
	print("\n=== PROBE 2: two stacked panes compose ===")
	await _probe2_two_panes()
	print("\n=== PROBE 3: alpha 1.0 is opaque ===")
	await _probe3_opaque_control()
	print("")
	if _failures.is_empty():
		print("PASS: all %d transparent-alpha checks passed." % _checks)
		get_tree().quit(0)
	else:
		for f in _failures:
			print("FAIL - %s" % f)
		print("FAIL: %d of %d checks failed." % [_failures.size(), _checks])
		get_tree().quit(1)
```

`_measure_ratio(p_alpha: float, p_pane_count: int) -> float` builds an emissive backdrop, `p_pane_count` blended panes between it and the camera, and a camera aimed with `look_at_from_position`. It renders once with the panes hidden (control) and once visible, and returns the ratio, following probe 3 of `pt_transmission_gate.gd` — the `visible`-toggle technique makes every other term cancel.

The panes use `StandardMaterial3D` with `transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS` (what the glTF importer produces for `alphaMode: BLEND`) and `albedo_color = Color(1, 1, 1, p_alpha)`.

Keep a control-is-black guard: if the control mean is below `1e-6`, fail with a message saying the ratio proves nothing. That guard is what caught a degenerate 0/0 in this project before.

**Geometry constraint, and show the arithmetic in your report:** every pane must lie between the camera and the backdrop for the whole measured crop, and no pane may be edge-on. A prior gate in this project proved one geometric axis rigorously and never re-checked the axis it had just changed, shipping a gate that measured nothing. Verify both: pane-vs-camera and pane-vs-backdrop.

- [ ] **Step 4: Run the gate and confirm it FAILS**

```bash
./bin/godot.windows.editor.x86_64.console.exe --path pipeline_references res://tests/pt_transparent_alpha_gate_scene.tscn
```

Expected: **FAIL** on probes 1 and 2. The panes are still dropped from the TLAS, so the traced image does not contain them; whatever the raster overlay contributes will not land on `0.5` and `0.25`.

Confirm the printed control mean is comfortably above zero. If the control is black, the gate is measuring nothing and must be fixed before proceeding.

- [ ] **Step 5: Commit the failing gate**

```bash
git add pipeline_references/tests/pt_transparent_alpha_gate.gd pipeline_references/tests/pt_transparent_alpha_gate_scene.tscn
git commit -m "test(pt): transparent alpha gate - fails before the closure exists"
```

---

### Task 3: The closure — routing, branch, loop bound and overlay, in ONE commit

These four changes are atomic. Routing alpha surfaces into the TLAS without the branch makes them render **fully opaque** — a visible regression. The branch without the routing is inert. And leaving the raster overlay drawing them causes a **double-draw**, traced and rasterized on top of each other. This project has already shipped one bug by splitting exactly this kind of pair across tasks; do not split it.

**Files:**
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_inc.glsl` (PRNG slot)
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl` (the branch)
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/scene_raytracing_raygen.glsl:65` (loop bound), and the material-eval sites at `:473`/`:570` to carry the blend flag
- Modify: `servers/rendering/renderer_rd/forward_clustered/render_raytracing.cpp:2871-2875` (drop the skip), and `rt_instance_mask_from_features`
- Modify: `servers/rendering/renderer_rd/forward_clustered/render_forward_clustered.cpp:1330` (overlay gating)

**Interfaces:**
- Consumes: `RT_MAT_FLAG_BLEND` from Task 1.
- Produces: alpha-blended surfaces traced; `RT_PRNG_TRANSPARENT = 10u`.

- [ ] **Step 1: Claim the PRNG slot**

In `raytracing_inc.glsl`, beside the existing `RT_PRNG_*` defines (the block ending at `:322` which states "Slots 10, 12-15 are free"):

```glsl
#define RT_PRNG_TRANSPARENT 10u // 1D: transparent-vs-shade choice (alpha closure).
```

Update that "Slots 10, 12-15 are free" comment to "Slots 12-15 are free" — a stale free-list comment is exactly the drift that caused a finding earlier in this project.

- [ ] **Step 2: Hoist the transmission cap above the branch point**

In `shade_and_bounce`, `max_transmission` and `transmission_bounces` are currently computed inside the per-lobe cap block at `raytracing_closest_hit_common_inc.glsl:1425-1427`. The transparent branch needs both, and must sit BEFORE that block — a transparent hit must not be terminated by the glossy or diffuse cap, which do not apply to it.

Move those two lines (and the `max_total` they depend on) above the branch point, leaving the existing cap block to reuse them. Do not duplicate the computation: the `min(..., 15u)` clamp is load-bearing and must exist exactly once.

- [ ] **Step 3: Add the transparent branch**

Immediately after `apply_segment_fog(gl_HitTEXT, ps.radiance, ps.throughput);` (around `:1342`) and BEFORE the emissive contribution — a transparent hit contributes no emission and does no NEE:

```glsl
	// Transparent BSDF closure. A material that BLENDS passes the ray straight
	// through with probability (1 - alpha); the complementary alpha share is
	// shaded normally below. Stochastic rather than accumulative so the choice is
	// order independent and stacked layers each contribute at their own weight.
	//
	// Gated on the BLEND flag, not on alpha < 1: alpha-SCISSOR materials are
	// already in the TLAS and their base-colour alpha can exceed the scissor
	// threshold while remaining below 1.0, so an alpha-value test would turn
	// every cutout translucent.
	if ((mat.flags & RT_MAT_FLAG_BLEND) != 0u && m.alpha < 1.0) {
		if (transmission_bounces >= max_transmission) {
			ps.packed_bounces_flags = set_path_terminated(ps.packed_bounces_flags);
			path_pack(payload, ps);
			return;
		}
		if (rng_1d(rng, RT_PRNG_TRANSPARENT) < (1.0 - m.alpha)) {
			// Straight through. Throughput is unchanged: the stochastic draw
			// already carries the (1 - alpha) weight, so the branch weight is 1.
			ps.packed_bounces_flags = inc_transmission_bounce(ps.packed_bounces_flags);
			ps.hit_t = gl_HitTEXT;
			// Raygen offsets the next origin ALONG this normal, so it must be
			// negated to land past the surface rather than in front of it --
			// the same reason the transmissive lobe negates at :2182.
			ps.offset_normal = -h.geometry_normal;
			ps.next_ray_dir = gl_WorldRayDirectionEXT;
			ps.rng_packed = rng_pack(rng_next_bounce(rng));
			// mis_ray_pdf is untouched: no scattering event occurred, so the
			// next vertex's MIS weight must still describe the lobe that
			// produced this ray.
			path_pack(payload, ps);
			return;
		}
	}
```

Name the `MaterialData` variable to match whatever the surrounding code calls it — read the function rather than assuming `mat`.

- [ ] **Step 4: Widen the raygen loop bound**

`scene_raytracing_raygen.glsl:65` currently reads:

```glsl
	[[dont_unroll]] for (uint bounce = 0u; bounce <= p_max_bounces; bounce++) {
```

A transparent pass-through consumes a loop iteration while consuming no payload bounce. Left as-is the loop counter becomes the new exhaustion budget and a surface behind two alpha layers goes dark — the exact failure already diagnosed in this project, where a camera ray spent its whole budget crossing a pane and the floor was terminated before NEE ran.

```glsl
	// Transparent hits consume an ITERATION but no payload bounce, so the loop
	// must have room for both budgets or the iteration count silently becomes
	// the bounce cap.
	const uint iteration_limit = p_max_bounces + RT_GET_MAX_TRANSMISSION_BOUNCE();
	[[dont_unroll]] for (uint bounce = 0u; bounce <= iteration_limit; bounce++) {
```

- [ ] **Step 5: Carry the blend flag into the shading path**

The branch reads `MaterialData.flags`. Confirm that struct is already in scope at the branch point in `shade_and_bounce`; if the function only receives `MaterialResult`, add a `bool blends` field to `MaterialResult` (`raytracing_material_eval_inc.glsl`), default it to `false` in `default_material_result`, and set it at both eval sites (`scene_raytracing_raygen.glsl:473` and `:570`). Defaulting to `false` keeps every custom ShaderMaterial on the existing path.

- [ ] **Step 6: Stop dropping alpha surfaces from the TLAS**

Remove the skip at `render_raytracing.cpp:2871-2875`.

- [ ] **Step 7: Widen the instance-mask predicate**

`rt_instance_mask_from_features` currently routes on the transmissive feature bit alone. It must also route blend materials to `RT_INSTANCE_MASK_TRANSMISSIVE`, so Task 4's shadow mix can attenuate through them instead of treating them as walls. Apply this at all four `instance_masks.push_back` sites and confirm the required signal is in scope at each — they hold three different variables (`proc_mat_data`, `mat_data`, `pending.mat_data`) and a prior phase shipped a bug by assuming they were interchangeable.

- [ ] **Step 8: Stop the raster overlay double-drawing**

In `render_forward_clustered.cpp`, the RT (`p_alpha_only`) path adds surfaces to `RENDER_LIST_ALPHA` at `:1330` from `rt_pass_flags & FLAG_PASS_ALPHA`. Those surfaces are now traced, so under RT they must no longer be added — otherwise every alpha surface is drawn twice, once traced and once rasterized over the top.

- [ ] **Step 9: Build**

Run: `python -m SCons platform=windows target=editor tests=yes -j8`
Expected: `SCONS_EXIT=0`. This proves nothing about the shader — Step 10 is the real check.

- [ ] **Step 10: Run the gate and confirm it now PASSES**

```bash
./bin/godot.windows.editor.x86_64.console.exe --path pipeline_references res://tests/pt_transparent_alpha_gate_scene.tscn
```

Expected: **PASS**. Probe 1 in `[0.47, 0.53]`, probe 2 in `[0.22, 0.28]`, probe 3 within `0.005` of opaque. This is the same gate that failed in Task 2.

- [ ] **Step 10a: Confirm Task 1's flag now reaches the GPU**

This is the end-to-end check Task 1 could not perform, deferred here because the skip removed in Step 6 was what made it unobservable. Temporarily re-add the `blend_pushed` counter from Task 1 Step 5 (how many entries in `material_data` carry `RT_MAT_FLAG_BLEND`) and render the aquarium scene.

Expected: **non-zero**, and matching the `blend_skipped` count Task 1 recorded on the same scene — the surfaces that used to be skipped are exactly the ones now pushed. Task 1's report holds that number; read it from `.superpowers/sdd/2026-09-07-transparent-bsdf-closure/task-1-report.md` and state both figures in your report. A mismatch means surfaces are being routed somewhere unintended.

Remove the counter again before committing.

- [ ] **Step 11: Prove the gate can still fail**

Temporarily force the branch never to be taken (change the draw to `if (false && ...)`), rebuild, re-run.
Expected: probes 1 and 2 FAIL. If they still pass, the gate is not testing the branch. Restore and re-run to confirm green.

- [ ] **Step 12: Confirm the missing fish return**

Render `urbantestdark180_fishtank` from the live project into a scratch path and inspect the marine tank interior. `003_lionfish` must be visible. A before/after on this exact scene already exists in the roadmap's transparent-shadows closeout.

- [ ] **Step 13: Full test suite**

Run: `./bin/godot.windows.editor.x86_64.console.exe --test`
Expected: no new failures against the pre-task baseline (1550 passed, 0 failed, 3 skipped).

- [ ] **Step 14: Commit**

```bash
git add servers/rendering/renderer_rd/shaders/raytracing/raytracing_inc.glsl servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl servers/rendering/renderer_rd/shaders/raytracing/scene_raytracing_raygen.glsl servers/rendering/renderer_rd/shaders/raytracing/raytracing_material_eval_inc.glsl servers/rendering/renderer_rd/forward_clustered/render_raytracing.cpp servers/rendering/renderer_rd/forward_clustered/render_forward_clustered.cpp
git commit -m "feat(pt): transparent BSDF closure - alpha surfaces stay in the tracer"
```

---

### Task 4: Shadow rays attenuate by alpha

**Files:**
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_lights_inc.glsl:465`

**Interfaces:**
- Consumes: alpha-blended surfaces now on the transmissive mask (Task 3).
- Produces: shadow attenuation that accounts for alpha.

- [ ] **Step 1: Replace the per-crossing factor**

Pass B currently reads:

```glsl
		atten *= RT_GET_TRANSMISSION_ENABLED() ? (mat.transmission * (1.0 - F)) : 0.0;
```

It never consults alpha. With Task 3 admitting blend surfaces to the transmissive mask, a 90%-transparent fish would otherwise cast a solid shadow. Replace with the mix:

```glsl
		// A surface passes light two ways: the Transparent BSDF share (1 - alpha)
		// goes straight through, and the remaining alpha share is filtered by the
		// dielectric closure. Reduces exactly to the previous behaviour at
		// alpha == 1.0, and to ~0.90 per pane for alphaMode BLEND glass at
		// alpha == 0.098 -- the same fraction Cycles passes.
		float surface_share = RT_GET_TRANSMISSION_ENABLED() ? (mat.transmission * (1.0 - F)) : 0.0;
		// The (1 - alpha) pass-through share is taken ONLY for blending materials,
		// for the same reason the closure's branch is: an alpha-scissor material's
		// base-colour alpha can sit below 1.0 while the texel is meant to be solid.
		float pass_through = ((mat.flags & RT_MAT_FLAG_BLEND) != 0u) ? (1.0 - m_alpha) : 0.0;
		atten *= pass_through + (1.0 - pass_through) * surface_share;
```

`m_alpha` is the material's alpha at this hit. `ray_query_alpha_test` in the same file computes `alpha *= mat.albedo_color.a` after sampling the base-colour texture — follow that fetch pattern.

Note the second term is `(1 - pass_through)`, not `m_alpha`: for a non-blending material `pass_through` is 0 and the line must reduce to **exactly** `atten *= surface_share`, the pre-task behaviour, whatever that material's alpha happens to be. Writing `m_alpha` there would scale every alpha-scissor material's shadow by its own alpha and silently move the four existing probes.

- [ ] **Step 2: Build and confirm the transparent-shadow gate still passes**

Run: `python -m SCons platform=windows target=editor tests=yes -j8`, then:

```bash
./bin/godot.windows.editor.x86_64.console.exe --path pipeline_references res://tests/pt_transparent_shadow_gate_scene.tscn
```

Expected: **PASS**, all four probes unchanged — `0.921600`, `0.374911`, `0.849346`, `0.230400`. Every one of those uses `alpha = 1.0`, so the new term must reduce to exactly the old behaviour. Any movement in those numbers means the mix is wrong at the `alpha == 1` end.

- [ ] **Step 3: Add a blended-shadow probe to that gate**

Add a fifth probe using a pane with `transparency = TRANSPARENCY_ALPHA_DEPTH_PRE_PASS` and `albedo_color.a = 0.5`, `transmission = 0.0`. Expected ratio `0.5` per crossing; state the arithmetic and band in your report. Without it, nothing measures the new term.

- [ ] **Step 4: Run the gate**

Expected: **PASS**, five probes.

- [ ] **Step 5: Commit**

```bash
git add servers/rendering/renderer_rd/shaders/raytracing/raytracing_lights_inc.glsl pipeline_references/tests/pt_transparent_shadow_gate.gd
git commit -m "feat(pt): shadow rays attenuate by alpha, not block"
```

---

### Task 5: Measure and document

**Files:**
- Modify: `PATH_TRACER_QUALITY_ROADMAP.md`

- [ ] **Step 1: Re-render the reported scenes**

Render `urbantestdark180_fishtank`, `urbantestdark190_glass` and `urbantestdark191_glass` from the live project into scratch paths. Measure the marine tank interior in each and compare against the recorded baselines in the transparent-shadows closeout (section 8.4).

- [ ] **Step 2: Confirm no double-draw**

Inspect the alpha-blended fish. They must appear once, at the correct depth among the traced geometry — not ghosted or doubled. A double-draw shows as an over-bright silhouette.

- [ ] **Step 3: Measure the cost**

Time the render loop before and after by timestamping the `Driving 128 frames` log line. Alpha surfaces now generate traced hits and extra loop iterations where they previously generated none; foliage-heavy scenes are the worst case. Record the delta, and record it as inconclusive if asset loading dominates the wall time — it did for the previous phase, at roughly 916s of a 921s total.

- [ ] **Step 4: Write the closeout**

Add a section following the E1 / E3 / transparent-shadows pattern: the defect with code anchors; the stochastic-branch design and why stochastic rather than accumulative; the gate table; the falsification result; the fish before/after; the timing; and the honest limits — the shared transmission bounce budget, the added any-hit invocations, and that shadow behaviour changed for every alpha-blended surface in every scene, not only aquariums.

- [ ] **Step 5: Commit**

```bash
git add PATH_TRACER_QUALITY_ROADMAP.md
git commit -m "docs(pt): transparent BSDF closure closeout"
```
