# Video OIDN Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Denoise the video route with OpenImageDenoise per delivered frame, as Blender Cycles does, inside today's one-hour budget at 4K/60fps.

**Architecture:** Two independently testable parts. (1) The engine's OIDN module gains a persistent CUDA path behind a new `rendering/pathtracer/oidn_device` setting whose default (CPU) runs today's code unchanged. (2) The video pipeline gains an `oidn` mode that runs the still route's Phase A per delivered frame — 2 sub-frames × 3 spp, then OIDN — inside one `_process()` call via `force_draw`, so MovieWriter only ever captures the denoised frame.

**Tech Stack:** Godot 4.7-beta fork (C++, SCons, Vulkan RD path tracer), OpenImageDenoise 2.5.0 C API (CPU + CUDA devices), GDScript pipeline (`pipeline_references/`), Python 3 + numpy + Pillow for measurement, ffmpeg/ffprobe from `C:/Zlendo2026/ZlenderRender_stage_copy/ffmpeg/bin/`.

**Spec:** `docs/superpowers/specs/2026-10-01-video-oidn-design.md`. **Research notes (every raw number):** `.superpowers/sdd/2026-10-01-video-oidn/research.md`.

## Global Constraints

- **Stills must not change.** With `rendering/pathtracer/oidn_device` at its default `0` (CPU), the still route runs today's OIDN code. Job 201 at 1080p must stay byte-identical to `.superpowers/sdd/2026-09-28-local-highlight-relief/knee-sweep/knee_3.0.png`, md5 `2a17e6571e9bd26619591415cfaf0e08`.
- **The video default must not change.** `VIDEO_DENOISER = "dlssrr"` is the default; on it, video output is frame-for-frame identical (`ffmpeg -f framemd5`) to the pre-change build.
- **The DLSS-RR code path is not modified** — owner's instruction.
- **OIDN quality is `OIDN_QUALITY_HIGH`, set explicitly** on every CUDA filter (Cycles, `denoiser_oidn_base.cpp:33-45`).
- **Budget:** about one hour for the 421-frame `urbanvideotest1` job; `VIDEO_RENDER_TIMEOUT_SECONDS = 3600`.
- **Build:** `python -m SCons platform=windows target=editor` from the repo root. Bare `scons` is not on PATH, and a failing build can still exit 0 under Bash — always `tail` the build log and look for `scons: done building targets.`
- **Never run two Godot renders at once** — two 4K path tracers on one GPU lose the device. Launch long runs with the harness's own background mechanism, never a shell `&` or `nohup` (a `&` launch has survived its tool call before and rendered concurrently into the same log). After any `VK_ERROR_DEVICE_LOST`, first check the log for two `Godot Engine v4.7` banners.
- **Scope:** repo only (engine + `pipeline_references/`). Nothing is copied to `C:\Zlendo2026\ZlenderRender_stage_copy` — the owner ships.
- **Test project copies:** video jobs without an `environment_url` (urbanvideotest1) need `day.exr`, which is NOT in the repo (201 MB, lives in `C:/Zlendo2026/ZlenderRender_stage_copy/godot_project/day.exr`). Run every render from a scratch copy of `pipeline_references/` without `.godot/` (production has none), made by the helper in Task 1 Step 1.
- **Disk is 98% full (15 GB free on 2026-10-02).** `make_test_project.sh` hardlinks `day.exr` rather than copying it. Once a run's numbers are recorded, delete that run's `proj/` copy; delete 4K PNG sequences once their metric, crops and side-by-sides are written (keep logs, `done` files, metrics and composites). Check `df -h /c` before each long run; stop and report if under 5 GB.
- **Exact environment-variable names:** `ZR_VIDEO_DENOISER` (`dlssrr`|`oidn`|`none`), `ZR_VIDEO_ACCUM_TARGET` (int), `ZR_VIDEO_FLICKER_TEST` (`1`), `ZR_OIDN_DIAG` (`1`), `ZR_OIDN_DUMP` (dir, existing).
- **Commit attribution:** every commit message ends with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Corrections to the spec found while reading the code

Each is applied to the spec text in the task named.

1. **`[OIDN-DIAG]` limits (Task 1).** The spec says "the first 3 denoises … a still performs one denoise, so its log does not change." Measured: a still performs **2** denoises (the exposure probe's at `target=16`, then the final one) and prints **15–18** skip lines (job 201, targets 2 and 256). A limit of 3 would change still logs. Limits become **8 denoises and 64 skip lines** — above a still's count.
2. **T4's method (Task 3).** The spec alternates the camera between P and P + 0.1 mm. `_apply_keyframe` re-orients the sun on every 5th frame from `cam.position` **and** `cam.basis.z` (`video_render.gd`, `_window_sunlight_data` block), so P' frames landing on multiples of 5 re-orient the sun, and later P frames inherit it — the P frames would not be bit-identical content. Replaced by a static camera plus a test hook (`ZR_VIDEO_FLICKER_TEST=1`) that forces an accumulator reset every delivered frame: all 30 frames are independent renders of identical content.
3. **`biquadraticFilter` (Task 1, no spec change needed).** The CPU path calls `oidnSetDeviceBool(device, "biquadraticFilter", true)`. That string appears in none of the OIDN 2.5.0 DLLs or headers; OIDN ignores unknown parameters, so it is a no-op. The CUDA path does not copy it; the CPU path keeps it (stills unchanged).
4. **`ZR_OIDN_DUMP` gains `oidn_output.pfm` (Task 1).** T1 needs the engine's own denoised output in linear, before tone mapping, to compare devices on real content. The existing debug dump writes only the inputs.

## Calibrations already measured (do not repeat; cite them)

On job 201's real 6-spp OIDN inputs (`oidnDenoise`, identical inputs per device; display = exposure 24.171, neutral curve, 8-bit):

| comparison | pixels ≥2 levels apart | max | PSNR | floats differing |
|---|---|---|---|---|
| CUDA high vs CPU high | **0.0000%** | 1 | 61.8 dB | **99.97%** |
| CUDA **balanced** vs CPU high (negative control) | **80.41%** | 173 | 33.3 dB | — |

So T1's bar (no pixel ≥2 levels) catches a real quality drop, and "output bitwise-identical to CPU" reliably means CUDA never ran.

## File map

| file | change | responsibility |
|---|---|---|
| `servers/rendering/rendering_server.cpp` | modify (~:3866) | register `rendering/pathtracer/oidn_device` |
| `modules/raycaster_oidn/oidn_denoiser.h` | modify | declare the CUDA path and `release_shared_cuda()` |
| `modules/raycaster_oidn/oidn_denoiser.cpp` | modify | the CUDA path; rename the CPU body to `denoise_rt_cpu` untouched |
| `modules/raycaster_oidn/register_types.cpp` | modify | release the process-lifetime CUDA device at module uninit |
| `servers/rendering/renderer_rd/forward_clustered/render_forward_clustered.cpp` | modify | `[OIDN-DIAG]` rate limit; `oidn_output.pfm` dump |
| `pipeline_references/tests/pt_oidn_device_gate.gd` + `_scene.tscn` | create | T1 gate (CPU vs CUDA, vacuity guard) |
| `pipeline_references/video_glb_creation.gd` | modify | `VIDEO_DENOISER` switch and Phase A environment |
| `pipeline_references/video_render.gd` | modify | viewport mode, per-frame sub-frames, priming skip, sequence reset, probe env, flicker hook |
| `pipeline_references/tests/video_oidn/make_static_job.py` | create | builds T4's static-camera job |
| `pipeline_references/tests/video_oidn/flicker_metric.py` | create | T4's per-pixel temporal std over a PNG sequence |
| `docs/superpowers/specs/2026-10-01-video-oidn-design.md` | modify | corrections 1, 2, 4; measured results |

Shared paths used below (bash):

```bash
R=/c/Users/aiadmin/Desktop/Engine_Build_test/Zreal_Engine
W=$R/.superpowers/sdd/2026-10-01-video-oidn          # persistent working notes (gitignored)
IN=$W/inputs                                          # job201_1080p.json, job301_12kf.json, job301_dense30.json, urbanvideotest1.json
BIN=$R/bin/godot.windows.editor.x86_64.console.exe
FF=/c/Zlendo2026/ZlenderRender_stage_copy/ffmpeg/bin/ffmpeg.exe
FP=/c/Zlendo2026/ZlenderRender_stage_copy/ffmpeg/bin/ffprobe.exe
```

---

### Task 1: Engine — persistent CUDA OIDN path, device setting, diag rate limit, output dump

**Files:**
- Modify: `servers/rendering/rendering_server.cpp` (after the `highlight_relief_knee` `GLOBAL_DEF`, ~line 3866)
- Modify: `modules/raycaster_oidn/oidn_denoiser.h`
- Modify: `modules/raycaster_oidn/oidn_denoiser.cpp`
- Modify: `modules/raycaster_oidn/register_types.cpp:47-55`
- Modify: `servers/rendering/renderer_rd/forward_clustered/render_forward_clustered.cpp` (`_oidn_final_denoise_accumulator`, ~:1950-2178)
- Create: `pipeline_references/tests/pt_oidn_device_gate.gd`, `pipeline_references/tests/pt_oidn_device_gate_scene.tscn`
- Modify: `docs/superpowers/specs/2026-10-01-video-oidn-design.md` (correction 1, correction 4)

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: project setting `rendering/pathtracer/oidn_device` (int: `0` CPU default, `1` CUDA), read per denoise; log line `[OIDN] denoising on CUDA (quality HIGH, <W>x<H>)` printed once per process on the first successful CUDA denoise; log line `[OIDN] CUDA unavailable/failed (<reason>); using CPU for the rest of this process.` on fallback; env `ZR_OIDN_DIAG=1` restores every `[OIDN-DIAG]` line; `ZR_OIDN_DUMP=<dir>` additionally writes `<dir>/oidn_output.pfm` (linear RGB float, the denoised colour). Task 2 sets the setting to `1` and relies on both log lines.

- [ ] **Step 1: Create the test-project helper**

Create `$W/make_test_project.sh`:

```bash
#!/bin/bash
# usage: make_test_project.sh <dest_dir>
# A copy of pipeline_references/ WITHOUT .godot/ (production has no import cache) plus the
# 201 MB day.exr that the repo does not carry (jobs with no environment_url fall back to it).
set -e
R=/c/Users/aiadmin/Desktop/Engine_Build_test/Zreal_Engine
D="$1"
rm -rf "$D"; mkdir -p "$D"
cp -r "$R/pipeline_references" "$D/"
rm -rf "$D/pipeline_references/.godot"
# HARDLINK, not copy: C: is 98% full (15 GB free on 2026-10-02) and this helper runs about a
# dozen times. Same NTFS volume, so the link costs no space; deleting the copy later leaves
# the original untouched. Falls back to a real copy only if linking fails.
ln /c/Zlendo2026/ZlenderRender_stage_copy/godot_project/day.exr "$D/pipeline_references/day.exr" 2>/dev/null \
  || cp /c/Zlendo2026/ZlenderRender_stage_copy/godot_project/day.exr "$D/pipeline_references/day.exr"
echo "test project ready: $D/pipeline_references"
```

Run: `chmod +x $W/make_test_project.sh`

- [ ] **Step 2: Write the T1 gate (it must fail first)**

Create `pipeline_references/tests/pt_oidn_device_gate_scene.tscn`:

```
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://tests/pt_oidn_device_gate.gd" id="1_gate"]

[node name="PTOIDNDeviceGate" type="Node"]
script = ExtResource("1_gate")
```

Create `pipeline_references/tests/pt_oidn_device_gate.gd`:

```gdscript
extends "res://tests/pt_validation.gd"

## OIDN device gate -- T1 of docs/superpowers/specs/2026-10-01-video-oidn-design.md.
##
## Same fixture as pt_oidn_guide_gate (a 256x256 checker quad under a white sky) but only
## FRAMES accumulation frames, so OIDN has real noise to remove -- the video route's regime.
##
## Two invocations. They compare across PROCESSES because renders are bit-deterministic
## across runs on this build, while a second accumulation inside one process would draw
## different noise (the RNG frame counter keeps advancing):
##
##   1) CPU reference:
##      ZR_OIDN_GATE_DEVICE=cpu ZR_GATE_DUMP=<dir> godot ... pt_oidn_device_gate_scene.tscn
##      -> writes <dir>/oidn_device_cpu.pfm
##   2) CUDA vs reference:
##      ZR_OIDN_GATE_DEVICE=cuda ZR_OIDN_DEVICE_REF=<dir>/oidn_device_cpu.pfm godot ...
##
## Without ZR_OIDN_DEVICE_REF (the gate suite) only D1/D2 run: the denoise executes on the
## requested device and actually removes noise.
##
##   D1 premise : the raw accumulation is noisy (else OIDN has nothing to do and D4 is vacuous)
##   D2 denoise : OIDN reduces the noise in a flat region by more than half
##   D3 device  : the CUDA output differs from the CPU reference in more than 1% of floats.
##                Identical output means CUDA never ran (silent CPU fallback); measured on
##                job 201, CUDA vs CPU differ in 99.97% of floats.
##   D4 quality : no pixel 2+ display levels from the CPU reference. Measured on job 201:
##                CUDA high 0.0000%; CUDA BALANCED 80.41% -- the bar catches a real drop.

const FRAMES := 2
const CAM_DIST := 10.0
const CAM_FOV := 10.0
const FINE_PERIOD := 4
const COARSE_PERIOD := 32
const NOISY_MIN := 0.01          # D1: flat-region std of the raw accumulation must exceed this
const DENOISE_RATIO_MAX := 0.5   # D2: denoised std / raw std in the same region
const DIFFER_MIN := 0.01         # D3: fraction of floats that must differ from the CPU reference
const SETTING := "rendering/pathtracer/oidn_device"

var _failures: Array[String] = []
var _checks: int = 0


func _ready() -> void:
	var device := OS.get_environment("ZR_OIDN_GATE_DEVICE").strip_edges().to_lower()
	if device == "":
		device = "cuda"
	ProjectSettings.set_setting(SETTING, 1 if device == "cuda" else 0)
	print("\n=== OIDN device gate: device=%s, %d accumulation frames ===" % [device, FRAMES])

	get_window().content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	get_window().size = Vector2i(256, 256)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	# The still route's viewport contract (see pt_oidn_guide_gate.gd for why each line).
	get_viewport().msaa_3d = Viewport.MSAA_DISABLED
	get_viewport().screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	get_viewport().use_taa = false
	get_viewport().use_debanding = false
	get_viewport().scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	get_viewport().scaling_3d_scale = 1.0
	get_viewport().use_hdr_2d = true
	await get_tree().process_frame
	await get_tree().process_frame

	var env := _new_env(Color(1, 1, 1))
	env.set_pathtracing_max_bounces(1)
	env.set_pathtracing_oidn_denoise(true)

	var img := Image.create(256, 256, false, Image.FORMAT_RGB8)
	for y in range(256):
		for x in range(256):
			var period := FINE_PERIOD if x < 128 else COARSE_PERIOD
			var half := period / 2
			var on := ((x / half) + (y / half)) % 2 == 0
			img.set_pixel(x, y, Color(0.9, 0.9, 0.9) if on else Color(0.1, 0.1, 0.1))
	var tex := ImageTexture.create_from_image(img)
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
	# OIDN fires on the frame the accumulator reaches its target and lands in the viewport
	# texture on the next blit; give it two frames (as pt_oidn_guide_gate does).
	await get_tree().process_frame
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var out: Image = get_viewport().get_texture().get_image()
	if out.get_format() != Image.FORMAT_RGBH:
		_failures.append("viewport image is %d, not FORMAT_RGBH -- use_hdr_2d did not take" % out.get_format())
		_finish()
		return

	var dump_dir := OS.get_environment("ZR_GATE_DUMP")
	if dump_dir != "":
		_save_pfm(out, dump_dir.path_join("oidn_device_%s.pfm" % device))

	# A flat dark square of the coarse checker (period 32 px, so 16 px squares): x 128-143 is
	# one square column; y 8-15 sits inside one square. Away from the edges, only noise varies.
	var raw_std := _std(raw, 132, 8, 140, 15)
	var out_std := _std(out, 132, 8, 140, 15)
	print("  flat-region std: raw %.5f  denoised %.5f  (ratio %.3f)" % [raw_std, out_std, out_std / maxf(raw_std, 1e-9)])
	_check_true("D1 premise: the raw accumulation is noisy", raw_std > NOISY_MIN, "(%.5f)" % raw_std)
	_check_true("D2 OIDN removed more than half the noise", out_std < DENOISE_RATIO_MAX * raw_std,
			"(%.5f vs %.5f)" % [out_std, raw_std])

	var ref_path := OS.get_environment("ZR_OIDN_DEVICE_REF")
	if ref_path == "":
		print("  D3/D4 SKIP: set ZR_OIDN_DEVICE_REF to the CPU run's oidn_device_cpu.pfm")
	else:
		var ref := _load_pfm(ref_path)
		if ref == null:
			_check_true("D3/D4 reference readable", false, ref_path)
		else:
			var differ := 0
			var total := 0
			var two_plus := 0
			var max_levels := 0
			for y in range(out.get_height()):
				for x in range(out.get_width()):
					var a := out.get_pixel(x, y)
					var b := ref.get_pixel(x, y)
					for c in range(3):
						total += 1
						if a[c] != b[c]:
							differ += 1
					var d := maxi(absi(_level(a.r) - _level(b.r)), maxi(absi(_level(a.g) - _level(b.g)), absi(_level(a.b) - _level(b.b))))
					max_levels = maxi(max_levels, d)
					if d >= 2:
						two_plus += 1
			var frac := float(differ) / float(maxi(total, 1))
			print("  vs CPU reference: floats differing %.2f%%, pixels 2+ levels %d, max %d levels" % [100.0 * frac, two_plus, max_levels])
			_check_true("D3 the CUDA output is not the CPU output (CUDA actually ran)", frac > DIFFER_MIN, "(%.4f)" % frac)
			_check_true("D4 no pixel 2+ display levels from the CPU reference", two_plus == 0,
					"(%d pixels, max %d levels)" % [two_plus, max_levels])
	_finish()


## Linear -> 8-bit sRGB display level. The fixture renders with TONE_MAPPER_LINEAR, so the
## viewport's linear value is what the display would encode.
func _level(p_linear: float) -> int:
	var v := clampf(p_linear, 0.0, 1.0)
	var s := 12.92 * v if v <= 0.0031308 else 1.055 * pow(v, 1.0 / 2.4) - 0.055
	return int(round(s * 255.0))


func _check_true(p_name: String, p_ok: bool, p_detail: String = "") -> void:
	_checks += 1
	if p_ok:
		print("  PASS %s %s" % [p_name, p_detail])
	else:
		print("  FAIL %s %s" % [p_name, p_detail])
		_failures.append("%s %s" % [p_name, p_detail])


func _std(p_img: Image, p_x0: int, p_y0: int, p_x1: int, p_y1: int) -> float:
	var vals := PackedFloat32Array()
	for y in range(p_y0, p_y1):
		for x in range(p_x0, p_x1):
			var c := p_img.get_pixel(x, y)
			vals.append((c.r + c.g + c.b) / 3.0)
	var mean := 0.0
	for v in vals:
		mean += v
	mean /= float(maxi(vals.size(), 1))
	var acc := 0.0
	for v in vals:
		acc += (v - mean) * (v - mean)
	return sqrt(acc / float(maxi(vals.size(), 1)))


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
	if f.get_line().strip_edges() != "PF":
		return null
	var dims := f.get_line().strip_edges().split(" ")
	var w := int(dims[0])
	var h := int(dims[1])
	f.get_line() # scale (-1.0: little-endian)
	var img := Image.create(w, h, false, Image.FORMAT_RGBF)
	var data := StreamPeerBuffer.new()
	data.data_array = f.get_buffer(w * h * 12)
	data.big_endian = false
	for y in range(h - 1, -1, -1):
		for x in range(w):
			var r := data.get_float()
			var g := data.get_float()
			var b := data.get_float()
			img.set_pixel(x, y, Color(r, g, b))
	return img


func _finish() -> void:
	print("")
	if _failures.is_empty():
		print("PASS: all %d OIDN-device checks passed." % _checks)
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

- [ ] **Step 3: Run the gate on the CURRENT binary — it must fail D3**

The current engine has no `oidn_device` setting, so `set_setting(...)` creates an unread key and both "devices" run on CPU.

```bash
mkdir -p $W/t1 && cd $R
ZR_OIDN_GATE_DEVICE=cpu ZR_GATE_DUMP=$W/t1 $BIN --rendering-driver vulkan --path pipeline_references res://tests/pt_oidn_device_gate_scene.tscn 2>&1 | grep -a "PASS\|FAIL\|std\|vs CPU"
ZR_OIDN_GATE_DEVICE=cuda ZR_OIDN_DEVICE_REF=$W/t1/oidn_device_cpu.pfm $BIN --rendering-driver vulkan --path pipeline_references res://tests/pt_oidn_device_gate_scene.tscn 2>&1 | grep -a "PASS\|FAIL\|std\|vs CPU"
```

Expected: the CPU run passes D1/D2. The "cuda" run **FAILS D3** with `floats differing 0.00%` — the gate correctly detects that CUDA never ran. Record both outputs in `$W/task1.md`. If D3 passes here, the vacuity guard is broken: stop and fix the gate before going on. D1 and D2 must pass here too -- the fixture's noise does not depend on the engine change. If D1 fails (the flat-region std is at or under 0.01), the fixture is too clean for OIDN to have work: set `const FRAMES := 1` and re-run this step before going on.

- [ ] **Step 4: Register the setting**

In `servers/rendering/rendering_server.cpp`, immediately after the line
`GLOBAL_DEF(PropertyInfo(Variant::FLOAT, "rendering/pathtracer/highlight_relief_knee", PROPERTY_HINT_RANGE, "0.5,32.0,0.1"), 3.0);`
insert:

```cpp
	// OIDN device for the path tracer's final denoise (spec
	// docs/superpowers/specs/2026-10-01-video-oidn-design.md). 0 = CPU: the original path,
	// which the still route uses unchanged. 1 = CUDA: one device, buffer set and filter set for
	// the whole process -- 157 ms vs 5270 ms per 4K frame, and on a real frame no pixel 2 or more
	// display levels from the CPU result. The video route's OIDN mode sets 1; nothing else does.
	GLOBAL_DEF(PropertyInfo(Variant::INT, "rendering/pathtracer/oidn_device", PROPERTY_HINT_ENUM, "CPU,CUDA"), 0);
```

- [ ] **Step 5: Declare the CUDA path in the header**

Replace the class declaration in `modules/raycaster_oidn/oidn_denoiser.h` (from the comment block above `class OIDNDenoiser` to the closing `};`) with:

```cpp
// Concrete OIDN-backed implementation of PathtraceOIDNDenoiser. Uses the in-process OIDN
// C API (link-time against OpenImageDenoise.lib, runtime against the OpenImageDenoise*.dll
// plugin set in thirdparty/oidn/bin).
//
// Two device paths, chosen per denoise by the project setting rendering/pathtracer/oidn_device:
//  * CPU (0, the default): the original path, unchanged -- a device per denoiser object and host
//    buffers shared with OIDN. The still route uses it.
//  * CUDA (1): spec docs/superpowers/specs/2026-10-01-video-oidn-design.md. ONE device, buffer
//    set and filter set for the whole process, mirroring Cycles
//    (intern/cycles/integrator/denoiser_oidn_gpu.cpp, which keeps them until the passes or the
//    quality change). The caller creates a denoiser object per denoise, so per-object CUDA
//    state would mean a CUDA context per video frame. Any CUDA failure falls back to the CPU
//    path for that denoise and every later one in the process.
class OIDNDenoiser : public PathtraceOIDNDenoiser {
	GDCLASS(OIDNDenoiser, PathtraceOIDNDenoiser)

	OIDNDevice device = nullptr;
	bool committed_available = false;

	// Lazy device creation. Returns true if a usable CPU device exists.
	bool ensure_device();
	static void device_error_callback(void *user_ptr, OIDNError code, const char *message);

	// The original CPU denoise, unchanged.
	bool denoise_rt_cpu(int p_width, int p_height,
			float *p_color,
			float *p_albedo,
			float *p_normal,
			int p_input_spp);

	// ---- CUDA path: process-lifetime state shared by every OIDNDenoiser object. ----
	struct CUDAState {
		OIDNDevice device = nullptr;
		OIDNBuffer color = nullptr;
		OIDNBuffer albedo = nullptr;
		OIDNBuffer normal = nullptr;
		OIDNFilter albedo_filter = nullptr;
		OIDNFilter normal_filter = nullptr;
		OIDNFilter rt_filter = nullptr;
		int width = 0;
		int height = 0;
		bool has_albedo = false;
		bool has_normal = false;
		bool failed = false; // sticky for the process
		bool announced = false; // the first successful CUDA denoise is logged once
		Vector<float> readback; // host scratch: the output lands here first, p_color only on success
	};
	static CUDAState cuda;
	static void cuda_fail(const String &p_reason);
	static bool cuda_check(const char *p_where);
	static void cuda_release_filters_and_buffers();
	static bool cuda_ensure_device();
	static bool cuda_configure(int p_width, int p_height, bool p_albedo, bool p_normal);
	static bool cuda_denoise(int p_width, int p_height, float *p_color, float *p_albedo, float *p_normal);

protected:
	static Ref<PathtraceOIDNDenoiser> create_oidn_denoiser();

public:
	// Values of rendering/pathtracer/oidn_device.
	enum {
		DEVICE_SETTING_CPU = 0,
		DEVICE_SETTING_CUDA = 1,
	};

	~OIDNDenoiser();

	bool denoise_rt(int p_width, int p_height,
			float *p_color,
			float *p_albedo,
			float *p_normal,
			int p_input_spp) override;
	bool is_available() const override;

	// Called from the module register_types to wire this implementation into the
	// renderer-side PathtraceOIDNDenoiser factory (see pathtrace_oidn_denoiser.h).
	static void make_default_denoiser();
	// Releases the process-lifetime CUDA device, buffers and filters. Called from
	// uninitialize_raycaster_oidn_module.
	static void release_shared_cuda();
};
```

Add `#include "core/templates/vector.h"` below the existing `#include "servers/rendering/renderer_rd/pathtrace_oidn_denoiser.h"` line.

- [ ] **Step 6: Rename the CPU body — name only**

In `modules/raycaster_oidn/oidn_denoiser.cpp`, change exactly one line. Before:

```cpp
bool OIDNDenoiser::denoise_rt(int p_width, int p_height,
```

After:

```cpp
bool OIDNDenoiser::denoise_rt_cpu(int p_width, int p_height,
```

Do **not** change anything else in that function — its body is the still route's denoise, and T2 proves it byte-identical. Leave the `biquadraticFilter` line in `ensure_device()` as it is (correction 3: a no-op, kept so the CPU path is untouched).

- [ ] **Step 7: Add the dispatch and the CUDA path**

In `modules/raycaster_oidn/oidn_denoiser.cpp`, add `#include "core/config/project_settings.h"` after `#include "core/string/print_string.h"`, and `#include <cstring>` (for `memcpy`) after it. Then insert the following immediately **before** `bool OIDNDenoiser::is_available() const {`:

```cpp
// ---------------------------------------------------------------------------------------------
// Device dispatch (spec 2026-10-01-video-oidn-design.md). CPU, the default, runs the original
// code above unchanged. CUDA runs the persistent path below and falls back to CPU on any
// failure, so a frame is never left undenoised because the GPU path broke.
// ---------------------------------------------------------------------------------------------
bool OIDNDenoiser::denoise_rt(int p_width, int p_height,
		float *p_color,
		float *p_albedo,
		float *p_normal,
		int p_input_spp) {
	const int requested = (int)GLOBAL_GET("rendering/pathtracer/oidn_device");
	if (requested == DEVICE_SETTING_CUDA && !cuda.failed) {
		if (cuda_denoise(p_width, p_height, p_color, p_albedo, p_normal)) {
			return true;
		}
		// cuda_denoise() logged the reason and marked CUDA failed. p_color still holds the raw
		// input (the CUDA output is only copied into it on success), so the CPU path below
		// denoises the right image.
	}
	return denoise_rt_cpu(p_width, p_height, p_color, p_albedo, p_normal, p_input_spp);
}

OIDNDenoiser::CUDAState OIDNDenoiser::cuda;

void OIDNDenoiser::cuda_fail(const String &p_reason) {
	if (!cuda.failed) {
		ERR_PRINT(vformat("[OIDN] CUDA unavailable/failed (%s); using CPU for the rest of this process.", p_reason));
	}
	cuda.failed = true;
	cuda_release_filters_and_buffers();
	if (cuda.device) {
		oidnReleaseDevice(cuda.device);
		cuda.device = nullptr;
	}
}

// Reads and clears the CUDA device's error state. No error callback is installed for this
// device, so polling here is the single place errors surface.
bool OIDNDenoiser::cuda_check(const char *p_where) {
	const char *message = nullptr;
	const OIDNError err = oidnGetDeviceError(cuda.device, &message);
	if (err == OIDN_ERROR_NONE) {
		return true;
	}
	cuda_fail(vformat("%s: error %d, %s", p_where, (int)err, message ? message : "<no message>"));
	return false;
}

void OIDNDenoiser::cuda_release_filters_and_buffers() {
	OIDNFilter *filters[] = { &cuda.albedo_filter, &cuda.normal_filter, &cuda.rt_filter };
	for (OIDNFilter *f : filters) {
		if (*f) {
			oidnReleaseFilter(*f);
			*f = nullptr;
		}
	}
	OIDNBuffer *buffers[] = { &cuda.color, &cuda.albedo, &cuda.normal };
	for (OIDNBuffer *b : buffers) {
		if (*b) {
			oidnReleaseBuffer(*b);
			*b = nullptr;
		}
	}
	cuda.width = 0;
	cuda.height = 0;
	cuda.has_albedo = false;
	cuda.has_normal = false;
}

bool OIDNDenoiser::cuda_ensure_device() {
	if (cuda.device) {
		return true;
	}
	if (!oidnIsCUDADeviceSupported(0)) {
		cuda_fail("oidnIsCUDADeviceSupported(0) is false");
		return false;
	}
	// Cycles' exact call (integrator/denoiser_oidn_gpu.cpp:234): an explicit device id and a
	// NULL stream -- "directly using the stream from the DeviceQueue returns 'invalid resource
	// handle'". cudaStream_t is typedef'd by oidn.h itself; no CUDA headers are needed.
	const int device_id = 0;
	const cudaStream_t stream = nullptr;
	cuda.device = oidnNewCUDADevice(&device_id, &stream, 1);
	if (!cuda.device) {
		cuda_fail("oidnNewCUDADevice returned null");
		return false;
	}
	oidnCommitDevice(cuda.device);
	return cuda_check("oidnCommitDevice");
}

// Buffers and filters for one frame size and pass set. Committing a filter loads the network
// weights, so they are committed once here and only EXECUTED per frame.
bool OIDNDenoiser::cuda_configure(int p_width, int p_height, bool p_albedo, bool p_normal) {
	if (cuda.rt_filter && cuda.width == p_width && cuda.height == p_height &&
			cuda.has_albedo == p_albedo && cuda.has_normal == p_normal) {
		return true;
	}
	cuda_release_filters_and_buffers();
	const size_t w = (size_t)p_width;
	const size_t h = (size_t)p_height;
	const size_t bytes = w * h * 3 * sizeof(float);

	auto new_buffer = [&](OIDNBuffer &r_buf, const char *p_name) -> bool {
		r_buf = oidnNewBuffer(cuda.device, bytes);
		if (!r_buf) {
			cuda_fail(vformat("oidnNewBuffer(%s) returned null", p_name));
			return false;
		}
		return cuda_check(p_name);
	};
	auto new_rt_filter = [&](OIDNFilter &r_filter, const char *p_name) -> bool {
		r_filter = oidnNewFilter(cuda.device, "RT");
		if (!r_filter) {
			cuda_fail(vformat("oidnNewFilter(RT) for %s returned null", p_name));
			return false;
		}
		// Quality pinned to HIGH on every filter, as Cycles does (denoiser_oidn_base.cpp:33-45).
		// It is OIDN 2.5.0's default today (measured: 156.57 vs 156.63 ms; BALANCED 76.74 ms and
		// 80.4% of pixels 2+ levels off) -- pinned so an OIDN upgrade cannot lower it silently.
		oidnSetFilterInt(r_filter, "quality", OIDN_QUALITY_HIGH);
		return true;
	};

	if (!new_buffer(cuda.color, "color")) {
		return false;
	}
	if (p_albedo && !new_buffer(cuda.albedo, "albedo")) {
		return false;
	}
	if (p_normal && !new_buffer(cuda.normal, "normal")) {
		return false;
	}

	// Guide prefilters -- Cycles' DENOISER_PREFILTER_ACCURATE, as the CPU path does: each guide
	// through its own RT filter, in place, before the colour pass trusts it (cleanAux).
	if (p_albedo) {
		if (!new_rt_filter(cuda.albedo_filter, "albedo prefilter")) {
			return false;
		}
		oidnSetFilterImage(cuda.albedo_filter, "albedo", cuda.albedo, OIDN_FORMAT_FLOAT3, w, h, 0, 0, 0);
		oidnSetFilterImage(cuda.albedo_filter, "output", cuda.albedo, OIDN_FORMAT_FLOAT3, w, h, 0, 0, 0);
		oidnCommitFilter(cuda.albedo_filter);
		if (!cuda_check("commit albedo prefilter")) {
			return false;
		}
	}
	if (p_normal) {
		if (!new_rt_filter(cuda.normal_filter, "normal prefilter")) {
			return false;
		}
		oidnSetFilterImage(cuda.normal_filter, "normal", cuda.normal, OIDN_FORMAT_FLOAT3, w, h, 0, 0, 0);
		oidnSetFilterImage(cuda.normal_filter, "output", cuda.normal, OIDN_FORMAT_FLOAT3, w, h, 0, 0, 0);
		oidnCommitFilter(cuda.normal_filter);
		if (!cuda_check("commit normal prefilter")) {
			return false;
		}
	}

	if (!new_rt_filter(cuda.rt_filter, "colour")) {
		return false;
	}
	// In place, as Cycles does (denoise_run sets "color" and "output" to the same device memory).
	oidnSetFilterImage(cuda.rt_filter, "color", cuda.color, OIDN_FORMAT_FLOAT3, w, h, 0, 0, 0);
	oidnSetFilterImage(cuda.rt_filter, "output", cuda.color, OIDN_FORMAT_FLOAT3, w, h, 0, 0, 0);
	if (p_albedo) {
		oidnSetFilterImage(cuda.rt_filter, "albedo", cuda.albedo, OIDN_FORMAT_FLOAT3, w, h, 0, 0, 0);
	}
	if (p_normal) {
		oidnSetFilterImage(cuda.rt_filter, "normal", cuda.normal, OIDN_FORMAT_FLOAT3, w, h, 0, 0, 0);
	}
	// Same two flags as the CPU path: scene-linear HDR, and guides already prefiltered.
	oidnSetFilterBool(cuda.rt_filter, "hdr", true);
	oidnSetFilterBool(cuda.rt_filter, "cleanAux", true);
	oidnCommitFilter(cuda.rt_filter);
	if (!cuda_check("commit colour filter")) {
		return false;
	}

	cuda.width = p_width;
	cuda.height = p_height;
	cuda.has_albedo = p_albedo;
	cuda.has_normal = p_normal;
	cuda.readback.resize((int)(w * h * 3));
	return true;
}

bool OIDNDenoiser::cuda_denoise(int p_width, int p_height, float *p_color, float *p_albedo, float *p_normal) {
	if (!cuda_ensure_device()) {
		return false;
	}
	if (!cuda_configure(p_width, p_height, p_albedo != nullptr, p_normal != nullptr)) {
		return false;
	}
	const size_t bytes = (size_t)p_width * (size_t)p_height * 3 * sizeof(float);

	// oidnWriteBuffer / oidnExecuteFilter / oidnReadBuffer are the SYNCHRONOUS variants (each has
	// a separate *Async twin in oidn.h), so no explicit oidnSyncDevice is needed.
	oidnWriteBuffer(cuda.color, 0, bytes, p_color);
	if (p_albedo) {
		oidnWriteBuffer(cuda.albedo, 0, bytes, p_albedo);
	}
	if (p_normal) {
		oidnWriteBuffer(cuda.normal, 0, bytes, p_normal);
	}
	if (!cuda_check("oidnWriteBuffer")) {
		return false;
	}
	if (cuda.albedo_filter) {
		oidnExecuteFilter(cuda.albedo_filter);
		if (!cuda_check("execute albedo prefilter")) {
			return false;
		}
	}
	if (cuda.normal_filter) {
		oidnExecuteFilter(cuda.normal_filter);
		if (!cuda_check("execute normal prefilter")) {
			return false;
		}
	}
	oidnExecuteFilter(cuda.rt_filter);
	if (!cuda_check("execute colour filter")) {
		return false;
	}
	// Into the scratch first: a failed read must not leave p_color half-overwritten, because the
	// CPU fallback denoises p_color next.
	oidnReadBuffer(cuda.color, 0, bytes, cuda.readback.ptrw());
	if (!cuda_check("oidnReadBuffer")) {
		return false;
	}
	memcpy(p_color, cuda.readback.ptr(), bytes);

	if (!cuda.announced) {
		cuda.announced = true;
		print_line(vformat("[OIDN] denoising on CUDA (quality HIGH, %dx%d)", p_width, p_height));
	}
	return true;
}

void OIDNDenoiser::release_shared_cuda() {
	cuda_release_filters_and_buffers();
	if (cuda.device) {
		oidnReleaseDevice(cuda.device);
		cuda.device = nullptr;
	}
	cuda.readback.clear();
	cuda.failed = false;
	cuda.announced = false;
}
```

- [ ] **Step 8: Release the CUDA device at module uninit**

In `modules/raycaster_oidn/register_types.cpp`, inside `uninitialize_raycaster_oidn_module`, insert before `PathtraceOIDNDenoiser::create_function = nullptr;`:

```cpp
	// The CUDA path's device, buffers and filters live for the process (spec
	// 2026-10-01-video-oidn-design.md); this is where they end.
	OIDNDenoiser::release_shared_cuda();
```

- [ ] **Step 9: Rate-limit `[OIDN-DIAG]` and dump the denoised output**

In `servers/rendering/renderer_rd/forward_clustered/render_forward_clustered.cpp`, insert immediately **above** `static void _oidn_final_denoise_accumulator(`:

```cpp
// [OIDN-DIAG] rate limit (spec 2026-10-01-video-oidn-design.md). Measured: a still prints 2
// denoises (the exposure probe's and the final one) and 15-18 skip lines (job 201, targets 2
// and 256); a 421-frame video would print about 2,100. The first OIDN_DIAG_MAX_FIRES denoises
// and OIDN_DIAG_MAX_SKIPS skip lines of a process print in full -- above a still's count, so a
// still's log is unchanged -- and then stop. ZR_OIDN_DIAG=1 restores every line. Failures
// still print: they go through the ERR_* macros, not these lines.
static constexpr int OIDN_DIAG_MAX_FIRES = 8;
static constexpr int OIDN_DIAG_MAX_SKIPS = 64;
static int s_oidn_diag_fires = 0;
static int s_oidn_diag_skips = 0;

static bool _oidn_diag_take(int &r_count, int p_max) {
	static const bool unlimited = !OS::get_singleton()->get_environment("ZR_OIDN_DIAG").is_empty();
	if (unlimited) {
		return true;
	}
	if (r_count >= p_max) {
		return false;
	}
	r_count++;
	return true;
}

```

Inside `_oidn_final_denoise_accumulator`, change the skip print's condition. Before:

```cpp
		if (p_rt_state->accum_frame < 5 || p_rt_state->accum_frame == p_accum_target) {
```

After:

```cpp
		if ((p_rt_state->accum_frame < 5 || p_rt_state->accum_frame == p_accum_target) &&
				_oidn_diag_take(s_oidn_diag_skips, OIDN_DIAG_MAX_SKIPS)) {
```

Gate the FIRE line. Before:

```cpp
	print_line(vformat("[OIDN-DIAG] FIRE: accum_frame=%d target=%d dims=%dx%d",
```

After (the `if` wraps that existing `print_line(...)` statement, whose arguments continue unchanged on the next two lines; close the brace after its `);`):

```cpp
	const bool oidn_diag = _oidn_diag_take(s_oidn_diag_fires, OIDN_DIAG_MAX_FIRES);
	if (oidn_diag) {
		print_line(vformat("[OIDN-DIAG] FIRE: accum_frame=%d target=%d dims=%dx%d",
```

Wrap the two per-view prints the same way: put `if (oidn_diag) {` before `print_line(vformat("[OIDN-DIAG] view=%d albedo=%d normal=%d | ...` and before `print_line(vformat("[OIDN-DIAG] view=%d ok=%d | center in=...`, closing each brace after the statement's `);`. Leave `ERR_CONTINUE_MSG(!ok, ...)` alone so failures always print.

Then, immediately after the line `ERR_CONTINUE_MSG(!ok, "OIDN final-denoise failed; keeping raw converged image for this view.");`, insert:

```cpp
		// ZR_OIDN_DUMP also writes the DENOISED colour (spec 2026-10-01-video-oidn-design.md,
		// T1): comparing devices on real content needs the engine's own OIDN output in linear,
		// before tone mapping. Same PFM layout as the input dump above. Production never sets it.
		{
			const String out_dump_dir = OS::get_singleton()->get_environment("ZR_OIDN_DUMP");
			if (!out_dump_dir.is_empty()) {
				Ref<FileAccess> f = FileAccess::open(out_dump_dir.path_join("oidn_output.pfm"), FileAccess::WRITE);
				if (f.is_valid()) {
					f->store_string(vformat("PF%c%d %d%c-1.0%c", 10, width, height, 10, 10));
					for (int y = height - 1; y >= 0; y--) {
						f->store_buffer((const uint8_t *)(color_f.ptr() + (size_t)y * width * 3), (size_t)width * 3 * sizeof(float));
					}
				}
			}
		}
```

- [ ] **Step 10: Build**

```bash
cd $R && python -m SCons platform=windows target=editor > $W/build_task1.log 2>&1; tail -4 $W/build_task1.log
```

Expected: `scons: done building targets.` If not, read `$W/build_task1.log` for the first `error` and fix it.

- [ ] **Step 11: Run T1 on the fixture — it must now pass**

```bash
cd $R
ZR_OIDN_GATE_DEVICE=cpu ZR_GATE_DUMP=$W/t1 $BIN --rendering-driver vulkan --path pipeline_references res://tests/pt_oidn_device_gate_scene.tscn 2>&1 | grep -a "PASS\|FAIL\|std\|vs CPU\|\[OIDN\]"
ZR_OIDN_GATE_DEVICE=cuda ZR_OIDN_DEVICE_REF=$W/t1/oidn_device_cpu.pfm $BIN --rendering-driver vulkan --path pipeline_references res://tests/pt_oidn_device_gate_scene.tscn 2>&1 | grep -a "PASS\|FAIL\|std\|vs CPU\|\[OIDN\]"
```

Expected: both runs `PASS`. The CUDA run prints `[OIDN] denoising on CUDA (quality HIGH, 256x256)`, D3 shows floats differing well above 1%, D4 shows 0 pixels at 2+ levels. Record the numbers in `$W/task1.md`.

- [ ] **Step 12: Run T1 on real content (job 201, the engine's own CUDA path)**

The still route always uses CPU, so the CUDA run sets the setting in a scratch project's `project.godot`:

```bash
$W/make_test_project.sh $W/t1real_cpu
$W/make_test_project.sh $W/t1real_cuda
# project.godot already has a [rendering] section (line 15): insert the key under it rather than
# appending a second header.
sed -i 's|^\[rendering\]$|[rendering]\n\npathtracer/oidn_device=1|' $W/t1real_cuda/pipeline_references/project.godot
grep -n -A2 '^\[rendering\]' $W/t1real_cuda/pipeline_references/project.godot
mkdir -p $W/t1real_cpu/dump $W/t1real_cuda/dump
for v in cpu cuda; do
  ( cd $R && env ZR_DUMMY=1 ZR_PT_ACCUM_TARGET=2 ZR_OIDN_DUMP=$W/t1real_$v/dump $BIN --rendering-driver vulkan \
      --path $W/t1real_$v/pipeline_references res://main.tscn -- $IN/job201_1080p.json $W/t1real_$v/still.png \
      > $W/t1real_$v/run.log 2>&1 )
  grep -a "\[OIDN\]\|OIDN-DIAG\] FIRE" $W/t1real_$v/run.log
done
md5sum $W/t1real_cpu/dump/oidn_color.pfm $W/t1real_cuda/dump/oidn_color.pfm   # the INPUTS: must be identical
python $W/compare_pfm.py $W/t1real_cpu/dump/oidn_output.pfm $W/t1real_cuda/dump/oidn_output.pfm 24.171
python -c "import numpy as np;r=lambda p:(lambda f:(f.readline(),f.readline(),f.readline(),np.fromfile(f,dtype='<f4'))[3])(open(p,'rb'));a=r(r'$W/t1real_cpu/dump/oidn_output.pfm');b=r(r'$W/t1real_cuda/dump/oidn_output.pfm');print('floats differing %.2f%%'%(100*(a!=b).mean()))"
```

Run the two renders one after the other, never together. Expected: the two `oidn_color.pfm` md5s are **identical** (the same raw input reached both devices -- if they differ the comparison is invalid; find out why before reading it); the CUDA log shows `[OIDN] denoising on CUDA (quality HIGH, 1920x1080)` and no `CUDA unavailable/failed`; `compare_pfm.py` reports **0.0000% of pixels ≥2 levels, max 1 level**; floats differing far above 1%. If `oidn_output.pfm` is missing from a dump directory, the Step 9 dump code did not run -- check the build. Record everything in `$W/task1.md`.

- [ ] **Step 13: T2 — the still route is byte-identical**

```bash
# From pipeline_references ITSELF, exactly as the archived knee_3.0.png was rendered (the knee
# sweep ran --path pipeline_references). Job 201 has its own environment_url, so day.exr is not needed.
mkdir -p $W/t2
( cd $R && env ZR_DUMMY=1 $BIN --rendering-driver vulkan --path pipeline_references res://main.tscn -- $IN/job201_1080p.json $W/t2/still.png > $W/t2/run.log 2>&1 )
md5sum $W/t2/still.png
grep -ac "OIDN-DIAG" $W/t2/run.log
```

Expected md5: **`2a17e6571e9bd26619591415cfaf0e08`** (the archived `knee_3.0.png`). Any other value is a defect in this task — find it before going on. The `OIDN-DIAG` count should match a still's pre-change count (about 21–24 lines: 2 FIRE + 2 view + 2 ok + 15–18 skip).

- [ ] **Step 14: The gate suite**

Create `$W/run_suite.sh`:

```bash
#!/bin/bash
cd /c/Users/aiadmin/Desktop/Engine_Build_test/Zreal_Engine
OUT=/c/Users/aiadmin/Desktop/Engine_Build_test/Zreal_Engine/.superpowers/sdd/2026-10-01-video-oidn/suite
mkdir -p "$OUT"; : > "$OUT/summary.txt"
for t in pipeline_references/tests/*_gate_scene.tscn; do
  n=$(basename "$t" _scene.tscn); start=$(date +%s)
  bin/godot.windows.editor.x86_64.console.exe --rendering-driver vulkan --path pipeline_references "res://tests/${n}_scene.tscn" > "$OUT/$n.log" 2>&1
  code=$?; dur=$(( $(date +%s) - start ))
  line=$(grep -aE '^PASS|^FAIL:|gate PASSED|gate FAILED|checks passed|checks failed' "$OUT/$n.log" | tail -1)
  printf '%-32s exit=%-3s %4ss :: %s\n' "$n" "$code" "$dur" "$line" >> "$OUT/summary.txt"
done
echo DONE >> "$OUT/summary.txt"
```

Run it in the background (about 13 minutes): `bash $W/run_suite.sh` then `cat $W/suite/summary.txt`.

Expected: **26 lines, all `exit=0`** — the 25 existing gates plus `pt_oidn_device_gate` (in the suite it runs device `cuda` with no reference, so D1/D2 only).

- [ ] **Step 15: Correct the spec**

In `docs/superpowers/specs/2026-10-01-video-oidn-design.md`, under "**Log rate-limit.**", replace the paragraph with:

```markdown
**Log rate-limit.** In `_oidn_final_denoise_accumulator`, the `[OIDN-DIAG]` FIRE, view and ok
lines print for the first 8 denoises of a process, and the skip lines for the first 64.
Measured before choosing: a still performs 2 denoises (the exposure probe's at `target=16`,
then the final one) and prints 15-18 skip lines, so these limits leave a still's log
unchanged; a 421-frame video would otherwise print about 2,100 lines. `ZR_OIDN_DIAG=1`
restores every line. Failures always print.
```

and append to the "Design §1" section, after the log rate-limit paragraph:

```markdown
**Debug dump of the denoised output.** `ZR_OIDN_DUMP=<dir>`, which already writes the OIDN
inputs, also writes `oidn_output.pfm` -- the engine's own denoised colour in linear. T1 compares
devices on real content with it. Production never sets the variable.
```

- [ ] **Step 16: Commit**

```bash
cd $R && git add servers/rendering/rendering_server.cpp modules/raycaster_oidn/oidn_denoiser.h modules/raycaster_oidn/oidn_denoiser.cpp modules/raycaster_oidn/register_types.cpp servers/rendering/renderer_rd/forward_clustered/render_forward_clustered.cpp pipeline_references/tests/pt_oidn_device_gate.gd pipeline_references/tests/pt_oidn_device_gate_scene.tscn docs/superpowers/specs/2026-10-01-video-oidn-design.md
git commit -F - <<'EOF'
feat(oidn): a persistent CUDA denoise path behind rendering/pathtracer/oidn_device

<one paragraph each: what the CUDA path does and how it mirrors Cycles; that the CPU path is
the original code, renamed only; the measured T1 numbers from Steps 11-12 (fixture and job
201: pixels 2+ levels, max, floats differing); T2's md5; the suite result; the diag limits
and why 8/64.>

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

Fill the angle-bracketed paragraph from the numbers recorded in `$W/task1.md` before committing — it describes measurements, so it can only be written after Steps 11–14.

---

### Task 2: Pipeline — the video OIDN mode

**Files:**
- Modify: `pipeline_references/video_glb_creation.gd` (constants block near :36-40; path-tracing block at :1413-1425)
- Modify: `pipeline_references/video_render.gd` (`_begin_dlss_priming` :306-313; `_process` after `_apply_keyframe(_current_frame)` ~:261; `_run_daylight_probe` `probe_env` ~:431; `set_resolution` viewport block :1056-1062; new helpers)

**Interfaces:**
- Consumes (Task 1): project setting `rendering/pathtracer/oidn_device` (`1` = CUDA); log line `[OIDN] denoising on CUDA (quality HIGH, WxH)`; env `ZR_OIDN_DIAG=1`.
- Produces (for Tasks 3-4): `_resolve_video_denoiser() -> String` (`"dlssrr"`|`"oidn"`|`"none"`, resolved once, logged as `[VideoDenoiser] <mode>`), `_video_phase_a() -> bool`, `_video_accum_target() -> int`, `_render_phase_a_frame()`, `_reset_video_accumulator()`, member `_flicker_test: bool` (from `ZR_VIDEO_FLICKER_TEST=1`); log line `Phase A (<mode>): no DLSS priming; accumulator reset. Starting video render...`.

- [ ] **Step 1: Record the pre-change baseline for T3 (on the Task 1 binary, current scripts)**

```bash
$W/make_test_project.sh $W/t3_before
( cd $W && $BIN --path $W/t3_before/pipeline_references --write-movie $W/t3_before/movie.avi --fixed-fps 30 res://video_main.tscn -- $IN/job301_12kf.json $W/t3_before/out.mp4 $W/t3_before/frame.png > $W/t3_before/run.log 2>&1 )
$FF -y -loglevel error -i $W/t3_before/movie.avi -map 0:v -f framemd5 $W/t3_before/movie.framemd5
grep -vc '^#' $W/t3_before/movie.framemd5
```

Expected: `38` frames (1 + 20 warmup + 0 probe + 5 priming + 12). Run in the background (about 6 minutes).

- [ ] **Step 2: The switch and its helpers (`video_glb_creation.gd`)**

Insert immediately after the line `const USE_REFLECTION_PROBE_HOTSPOT_FIX = true`:

```gdscript
# Video denoiser (spec docs/superpowers/specs/2026-10-01-video-oidn-design.md).
#   "dlssrr" -- DLSS Ray Reconstruction, the realtime temporal denoiser. The default; unchanged.
#   "oidn"   -- the still route's Phase A for every delivered frame: VIDEO_OIDN_ACCUM_TARGET
#               sub-frames of VIDEO_OIDN_SPP samples through the Blackman-Harris pixel filter,
#               then OpenImageDenoise on CUDA. Cycles' own architecture for an OIDN animation.
#   "none"   -- Phase A without OIDN. A test control only (T4's negative control); without the
#               OIDN latch the main loop's own draw adds one more sub-frame, so it captures
#               (target + 1) x spp raw samples.
# ZR_VIDEO_DENOISER overrides it for one process; ZR_VIDEO_ACCUM_TARGET overrides the target
# (T4 measures 16, i.e. 48 spp).
const VIDEO_DENOISER := "dlssrr"
const VIDEO_OIDN_SPP := 3 # the still route's day value (PT_SPP_DAY), kept under the 8 s TDR watchdog
const VIDEO_OIDN_ACCUM_TARGET := 2 # 2 x 3 = 6 spp: the owner's 1-hour, 4K/60fps budget
const VIDEO_OIDN_CLAMP_INDIRECT := 10.0 # Cycles' sample_clamp_indirect; fireflies are what OIDN smears into blotches
var _video_denoiser := ""
var _flicker_test := false


# Resolved ONCE, by whichever caller runs first: set_resolution() (viewport mode) runs before
# build_scene() (the Environment), so both must see the same answer.
func _resolve_video_denoiser() -> String:
	if _video_denoiser != "":
		return _video_denoiser
	var mode := VIDEO_DENOISER
	var env_mode := OS.get_environment("ZR_VIDEO_DENOISER").strip_edges().to_lower()
	if env_mode != "":
		mode = env_mode
	if not (mode in ["dlssrr", "oidn", "none"]):
		print("[VideoDenoiser] unknown mode '%s'; using dlssrr" % mode)
		mode = "dlssrr"
	_video_denoiser = mode
	# T4 test hook: force an accumulator reset every delivered frame, so a static camera yields
	# independent renders of identical content. Phase A modes only; production never sets it.
	_flicker_test = mode != "dlssrr" and OS.get_environment("ZR_VIDEO_FLICKER_TEST") == "1"
	print("[VideoDenoiser] %s%s" % [mode, " (FLICKER TEST: reset every frame)" if _flicker_test else ""])
	return mode


func _video_phase_a() -> bool:
	return _resolve_video_denoiser() != "dlssrr"


func _video_accum_target() -> int:
	var t := VIDEO_OIDN_ACCUM_TARGET
	var e := OS.get_environment("ZR_VIDEO_ACCUM_TARGET")
	if e.is_valid_int():
		t = maxi(1, e.to_int())
	return t
```

- [ ] **Step 3: The Phase A environment (`video_glb_creation.gd`)**

Replace this exact block:

```gdscript
	env.set_pathtracing_enabled(true)
	env.set_pathtracing_max_bounces(6) # 6 bounces — DLSS RR denoises so fewer bounces suffice
	env.set_pathtracing_samples_per_pixel(6) # 4 SPP — DLSS RR handles the rest (denoising + AA)
	env.set_pathtracing_denoiser(1) # 1 = PT_DENOISER_DLSS_RAY_RECONSTRUCTION
	env.set("raytracing_params", PackedFloat32Array([0.0, 0.0, 0.0, 1.0]))
	print("[VideoGLB] NVIDIA PT enabled: bounces=6, spp=4, denoiser=DLSS_RR")
```

with:

```gdscript
	env.set_pathtracing_enabled(true)
	env.set_pathtracing_max_bounces(6) # 6 bounces — DLSS RR denoises so fewer bounces suffice
	if _video_phase_a():
		# Phase A per delivered frame (spec 2026-10-01-video-oidn-design.md): a mirror of the still
		# route's settings (image_glb_creation.gd, PHASE_A_*), keeping video's 6 bounces so the A/B
		# against DLSS-RR is equal-cost and isolates the denoiser.
		var target := _video_accum_target()
		env.set_pathtracing_samples_per_pixel(VIDEO_OIDN_SPP)
		env.set_pathtracing_denoiser(0) # PT_DENOISER_NONE: DLSS-RR is not the integrator here
		env.set_pathtracing_accumulate(true)
		env.set_pathtracing_accumulation_target(target)
		env.set_pathtracing_oidn_denoise(_video_denoiser == "oidn")
		env.set_pathtracing_dlss_rr_final(false)
		env.set_pathtracing_clamp_direct(0.0)
		env.set_pathtracing_clamp_indirect(VIDEO_OIDN_CLAMP_INDIRECT)
		env.set_pathtracing_noise_threshold(0.0)
		ProjectSettings.set_setting("rendering/pathtracer/oidn_device", 1) # CUDA (Task 1)
		print("[VideoGLB] NVIDIA PT enabled: bounces=6, Phase A %d x %d spp, final=%s, oidn_device=CUDA" % [
				target, VIDEO_OIDN_SPP, _video_denoiser])
	else:
		env.set_pathtracing_samples_per_pixel(6) # 4 SPP — DLSS RR handles the rest (denoising + AA)
		env.set_pathtracing_denoiser(1) # 1 = PT_DENOISER_DLSS_RAY_RECONSTRUCTION
		env.set("raytracing_params", PackedFloat32Array([0.0, 0.0, 0.0, 1.0]))
		print("[VideoGLB] NVIDIA PT enabled: bounces=6, spp=4, denoiser=DLSS_RR")
```

The `else` branch is the original four lines in their original order — the default path is unchanged.

- [ ] **Step 4: The viewport (`video_render.gd :: set_resolution`)**

Replace this exact block:

```gdscript
	get_viewport().scaling_3d_mode = Viewport.SCALING_3D_MODE_DLSS
	get_viewport().scaling_3d_scale = 1.0
	print("[VideoRender] PT + DLSS Ray Reconstruction denoising")
```

with:

```gdscript
	if _video_phase_a():
		# Phase A: the path tracer's Blackman-Harris pixel filter is the only anti-aliasing. Under
		# DLSS scaling the renderer bakes a per-frame Halton jitter into the projection and the
		# filter jitters again on top -- "a soft image with ragged edges" (render.gd, the still
		# route's identical fix). BILINEAR is spatial, so jitter_phase_count stays 0; at 1.0 there
		# is no resampling. use_taa is already false above.
		get_viewport().scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
		get_viewport().scaling_3d_scale = 1.0
		print("[VideoRender] PT + Phase A (%s): viewport BILINEAR @1.0, no projection jitter" % _video_denoiser)
	else:
		get_viewport().scaling_3d_mode = Viewport.SCALING_3D_MODE_DLSS
		get_viewport().scaling_3d_scale = 1.0
		print("[VideoRender] PT + DLSS Ray Reconstruction denoising")
```

- [ ] **Step 5: Skip priming, reset at sequence start (`video_render.gd`)**

Replace the whole of `_begin_dlss_priming`:

```gdscript
func _begin_dlss_priming() -> void:
	_dlss_prime_remaining = DLSS_PRIME_FRAMES
	_log_console("Scene settled. Starting DLSS priming (%d frames at frame-0 position)..." % DLSS_PRIME_FRAMES)
	# Capture thumbnail safely asynchronously without blocking _process
	if not _first_frame_saved:
		_first_frame_saved = true
		call_deferred("_capture_thumbnail_async")
```

with:

```gdscript
func _begin_dlss_priming() -> void:
	if _video_phase_a():
		# Phase A has no temporal denoiser to prime. It starts from a CLEARED accumulator instead,
		# so delivered frame 0 renders the final scene -- exposure, sun and any DaylightFill the
		# probe placed. Without this, frame 0 would reuse the warmup's frozen denoise: the camera
		# is already on pose 0, so nothing resets, and the warmup ran before the probe.
		_reset_video_accumulator()
		_rendering = true
		_sequence_t0 = Time.get_ticks_msec()
		_log_console("Phase A (%s): no DLSS priming; accumulator reset. Starting video render..." % _video_denoiser)
		if not _first_frame_saved:
			_first_frame_saved = true
			call_deferred("_capture_thumbnail_async")
		return
	_dlss_prime_remaining = DLSS_PRIME_FRAMES
	_log_console("Scene settled. Starting DLSS priming (%d frames at frame-0 position)..." % DLSS_PRIME_FRAMES)
	# Capture thumbnail safely asynchronously without blocking _process
	if not _first_frame_saved:
		_first_frame_saved = true
		call_deferred("_capture_thumbnail_async")


# Clears the recorded viewport's accumulator WITHOUT spending a main-loop iteration: the same
# off/on protocol and settle count as Daylight.probe_offscreen, paced by force_draw, which never
# reaches movie_writer->add_frame. Switching accumulate on starts a new convergence cycle and
# clears the OIDN latch with it (render_raytracing.cpp, accum_enabled edge).
func _reset_video_accumulator() -> void:
	var env := _get_scene_environment()
	if env == null:
		return
	env.pathtracing_accumulate = false
	for _i in range(Daylight.RESET_SETTLE_FRAMES):
		RenderingServer.force_draw(false)
	env.pathtracing_accumulate = true


# One delivered frame in Phase A. _apply_keyframe() has just moved the camera and (every 5th
# frame) the sun; Godot defers those transform notifications to the end of the frame, and the
# draws below happen inside this one, so they are flushed by hand (video port 3 met exactly
# this). The camera moved, so the first draw resets the accumulator and clears the OIDN latch;
# the last reaches the target and OIDN fires. force_draw never reaches movie_writer->add_frame,
# so no sub-frame is recorded. The main loop's own draw then finds an unchanged camera and a set
# latch, skips the trace (render_forward_clustered.cpp, oidn_denoise_done), and re-shows the
# denoised image -- that draw is the frame MovieWriter captures. On a held shot the camera does
# not move, so the frame freezes: no flicker, at the cost of ignoring a sun re-orientation.
func _render_phase_a_frame() -> void:
	var cam := get_node_or_null("MainCamera") as Camera3D
	if cam != null:
		cam.force_update_transform()
	if _dir_light != null:
		_dir_light.force_update_transform()
	if _flicker_test:
		_reset_video_accumulator()
	for _i in range(_video_accum_target()):
		RenderingServer.force_draw(false)
```

- [ ] **Step 6: Draw the sub-frames each delivered frame (`video_render.gd :: _process`)**

Replace:

```gdscript
	# Apply current keyframe
	_apply_keyframe(_current_frame)
```

with:

```gdscript
	# Apply current keyframe
	_apply_keyframe(_current_frame)
	if _video_phase_a():
		_render_phase_a_frame()
```

- [ ] **Step 7: No denoise inside the exposure probe (`video_render.gd :: _run_daylight_probe`)**

Replace:

```gdscript
	var probe_env: Environment = env.duplicate()
```

with:

```gdscript
	var probe_env: Environment = env.duplicate()
	# Phase A video sets oidn_denoise on the scene Environment, and duplicate() copies it. The
	# probe reads only the raw accumulator (viewport_get_pathtracing_accum_image), so a denoise in
	# here is wasted -- and at 960x540 it would make the CUDA buffers reallocate against 4K.
	probe_env.pathtracing_oidn_denoise = false
```

- [ ] **Step 8: Parse-check**

```bash
cd $R && $BIN --headless --path pipeline_references --check-only -s res://video_render.gd 2>&1 | grep -aiE "error|parse" ; echo "exit=$?"
```

Expected: no `error`/`parse` lines.

- [ ] **Step 9: T3 — the default is frame-for-frame unchanged**

```bash
$W/make_test_project.sh $W/t3_after
( cd $W && $BIN --path $W/t3_after/pipeline_references --write-movie $W/t3_after/movie.avi --fixed-fps 30 res://video_main.tscn -- $IN/job301_12kf.json $W/t3_after/out.mp4 $W/t3_after/frame.png > $W/t3_after/run.log 2>&1 )
$FF -y -loglevel error -i $W/t3_after/movie.avi -map 0:v -f framemd5 $W/t3_after/movie.framemd5
diff <(grep -v '^#' $W/t3_before/movie.framemd5) <(grep -v '^#' $W/t3_after/movie.framemd5) && echo "T3 PASS: identical"
grep -a "\[VideoDenoiser\]" $W/t3_after/run.log
```

Expected: `T3 PASS: identical` (38 of 38 frames) and `[VideoDenoiser] dlssrr`.

- [ ] **Step 10: Smoke-test OIDN mode**

```bash
$W/make_test_project.sh $W/t2_oidn
( cd $W && env ZR_VIDEO_DENOISER=oidn ZR_OIDN_DIAG=1 $BIN --path $W/t2_oidn/pipeline_references --write-movie $W/t2_oidn/movie.avi --fixed-fps 30 res://video_main.tscn -- $IN/job301_12kf.json $W/t2_oidn/out.mp4 $W/t2_oidn/frame.png > $W/t2_oidn/run.log 2>&1 )
L=$W/t2_oidn/run.log
grep -a "\[VideoDenoiser\]\|Phase A\|\[OIDN\]\|BILINEAR" $L
M=$(grep -an "Starting video render" $L | cut -d: -f1)
echo "FIRE after sequence start: $(tail -n +$M $L | grep -ac 'OIDN-DIAG\] FIRE: accum_frame=2 target=2')"
echo "frozen re-shows (main-loop draw skipped the trace): $(tail -n +$M $L | grep -ac 'skip: done=1 accum_frame=2 target=2')"
echo "frames in movie: $($FP -v error -select_streams v:0 -count_frames -show_entries stream=nb_read_frames -of csv=p=0 $W/t2_oidn/movie.avi)"
grep -ac "CUDA unavailable/failed" $L
```

Expected:
- `[VideoDenoiser] oidn`, the `Phase A (oidn): no DLSS priming` line, `[OIDN] denoising on CUDA (quality HIGH, 3840x2160)`, the BILINEAR line.
- **12 FIRE lines after the sequence start** — one per delivered frame.
- **≥12 frozen re-shows** — the main loop never adds a third sub-frame.
- **33 frames** in the movie (1 + 20 warmup + 12; no probe frames, no priming).
- `0` CUDA failures.

Extract one delivered frame and look at it: `$FF -y -loglevel error -i $W/t2_oidn/movie.avi -vf "select=eq(n\,30)" -vsync 0 -frames:v 1 $W/t2_oidn/frame30.png`. It should be noise-free. Record all results in `$W/task2.md`.

- [ ] **Step 11: Commit**

```bash
cd $R && git add pipeline_references/video_glb_creation.gd pipeline_references/video_render.gd
git commit -F - <<'EOF'
feat(video): an OIDN mode -- the still route's Phase A for every delivered frame

<what the mode does; the per-frame sub-frame / latch mechanism; the BILINEAR viewport and
why; skipped priming and the sequence-start reset and why; the probe's OIDN off; T3 result
(38 of 38 frames identical on dlssrr); the smoke-test numbers from Step 10.>

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

Fill the angle-bracketed paragraph from `$W/task2.md`.

---

### Task 3: T4 — the flicker measurement that decides A vs B (REVISED 2026-10-03)

**Why revised.** The first T4 design (one camera pose held for 30 frames, the accumulator force-reset every frame) is blind, and its negative control proved it: raw 9-spp frames passed with mean 0.033 levels, and all 30 delivered frames of both the raw and the OIDN runs were md5-identical. The accumulate route seeds its samples from `accum_frame`, which resets with the accumulator (`scene_raytracing_raygen.glsl:417-421`: "makes a given accum_frame draw the same point every time it recurs"), so every accumulation cycle replays the same Sobol sequence. Cycles does the same by default: `use_animated_seed` defaults to `False` (`blender/addon/properties.py:905-908`), and `blender/sync.cpp:408` then gives every frame the same seed. Consequence for production: on static content OIDN video cannot flicker at all. The risk is under MOTION — denoiser residue tied to a screen-fixed sample pattern while the scene slides past. The owner chose (2026-10-03) to measure exactly that: 30 consecutive production frames, OIDN against today's DLSS-RR on the same frames.

**Files:**
- Create: `pipeline_references/tests/video_oidn/make_segment_job.py`
- Create: `pipeline_references/tests/video_oidn/flicker_metric.py` (replaces the untracked first version)
- Delete (untracked, never committed): `pipeline_references/tests/video_oidn/make_static_job.py`
- Modify: `docs/superpowers/specs/2026-10-01-video-oidn-design.md` (T4 row and a Measured paragraph)

**Interfaces:**
- Consumes (Task 2): `ZR_VIDEO_DENOISER` (`oidn` | `none` | `dlssrr`), `ZR_VIDEO_ACCUM_TARGET`. **Not** `ZR_VIDEO_FLICKER_TEST` — this design measures production behaviour.
- Facts measured in Task 2 that this task relies on: every movie ends with ONE trailing frame after the delivered frames; the pre-roll is 20 frames in `oidn`/`none` and 25 in `dlssrr`. So 30 delivered frames give **51** PNGs (`oidn`/`none`) or **56** (`dlssrr`), and the delivered frames are `files[-31:-1]`. `none` mode captures 3 sub-frames per delivered frame (9 spp raw).
- Produces: the verdict. **PASS → Task 4. FAIL → commit, stop and report; the owner decides between proceeding and approach B.**

- [ ] **Step 1: Clean up the blind first attempt**

```bash
rm -f $R/pipeline_references/tests/video_oidn/make_static_job.py $R/pipeline_references/tests/video_oidn/flicker_metric.py
rm -rf $W/t4/raw/png $W/t4/oidn6/png
```

(The evidence that the first design was blind — one distinct md5 across delivered frames in both runs — is recorded in the ledger. The PNGs are ~1.8 GB on a nearly full disk.)

- [ ] **Step 2: Write the segment-job builder**

Create `pipeline_references/tests/video_oidn/make_segment_job.py`:

```python
"""T4 input: N CONSECUTIVE keyframes of a production video job, at their real speed.

Spec docs/superpowers/specs/2026-10-01-video-oidn-design.md, T4 (revised 2026-10-03). The
camera moves as it does in production, so the measurement sees what a viewer sees.

usage: python make_segment_job.py <source_job.json> <out.json> [--start S] [--count N]
"""
import argparse
import json

ap = argparse.ArgumentParser()
ap.add_argument("source")
ap.add_argument("out")
ap.add_argument("--start", type=int, default=0, help="first keyframe index of the segment")
ap.add_argument("--count", type=int, default=30, help="consecutive keyframes (= delivered frames)")
a = ap.parse_args()

with open(a.source, encoding="utf-8") as f:
    job = json.load(f)
anim = job["video_animation"]
frames = anim["keyframes"][a.start:a.start + a.count]
if len(frames) != a.count:
    raise SystemExit("source has only %d keyframes from %d" % (len(frames), a.start))
for i, kf in enumerate(frames):
    kf["frame"] = i
anim["keyframes"] = frames
anim["duration_seconds"] = a.count / float(anim.get("fps", 60.0))
with open(a.out, "w", encoding="utf-8") as f:
    json.dump(job, f)
print("wrote %s: keyframes %d..%d (%d consecutive)" % (a.out, a.start, a.start + a.count - 1, a.count))
```

- [ ] **Step 3: Write the metric, and prove it with its selftest first**

Create `pipeline_references/tests/video_oidn/flicker_metric.py`:

```python
"""T4 metric (revised 2026-10-03): temporal second difference on a MOVING camera, flat regions.

Spec docs/superpowers/specs/2026-10-01-video-oidn-design.md, T4. Video OIDN replays the same
sample sequence every frame (the accumulate route seeds from accum_frame, which resets with each
delivered frame -- as Cycles' default, use_animated_seed = False, gives every frame one seed), so
identical content renders identically and a static-camera test measures nothing. What can go
wrong happens under motion, so this reads 30 consecutive production frames.

Per pixel, d2[t] = L[t+1] - 2 L[t] + L[t-1] cancels any change that is linear in time -- smooth
camera motion over a few frames -- and keeps erratic frame-to-frame change: boiling, or denoiser
residue tied to the screen while the scene slides past.

FLAT REGIONS ONLY. A per-frame denoiser (OIDN) keeps moving edges sharp; a temporal one
(DLSS-RR) softens them, which lowers d2 at edges without being any more stable. So the mask is
the flattest half of the frame -- lowest spatial gradient of the REFERENCE run's temporal mean,
box-blurred 5x5 -- excluding near-black (<= 5) and near-white (>= 250) pixels, and the SAME mask
is applied to every run.

Verdicts (fixed before measuring, owner decision 2026-10-03):
  negative control  rms(raw) >= 3 x rms(dlssrr), else the instrument cannot see noise
  gate              rms(oidn6) <= rms(dlssrr): OIDN no less stable than today's DLSS-RR

Every movie ends with ONE trailing frame after the delivered frames (measured in Task 2), so the
delivered frames are files[-(N+1):-1].

usage: python flicker_metric.py --ref oidn48 raw=<png_dir> oidn6=<png_dir> oidn48=<png_dir> dlssrr=<png_dir>
       python flicker_metric.py --selftest
"""
import argparse
import glob
import os
import sys

import numpy as np
from PIL import Image

FRAMES = 30
FLAT_FRACTION = 0.5
NEG_CONTROL_RATIO = 3.0


def luma8(path):
    a = np.asarray(Image.open(path).convert("RGB"), dtype=np.float32)
    return 0.2126 * a[..., 0] + 0.7152 * a[..., 1] + 0.0722 * a[..., 2]


def delivered(png_dir, n):
    files = sorted(glob.glob(os.path.join(png_dir, "*.png")))
    if len(files) < n + 1:
        sys.exit("only %d PNGs in %s, need %d delivered + 1 trailing" % (len(files), png_dir, n))
    return np.stack([luma8(p) for p in files[-(n + 1):-1]])


def flat_mask(stack, frac=FLAT_FRACTION):
    m = stack.mean(axis=0)
    k = 5
    pad = np.pad(m, k // 2, mode="edge")
    c = np.pad(pad.cumsum(0).cumsum(1), ((1, 0), (1, 0)))
    blur = (c[k:, k:] - c[:-k, k:] - c[k:, :-k] + c[:-k, :-k]) / (k * k)
    gy, gx = np.gradient(blur)
    g = np.hypot(gx, gy)
    valid = (m > 5) & (m < 250)
    return valid & (g <= np.percentile(g[valid], 100 * frac))


def d2_stats(stack, mask):
    d2 = stack[2:] - 2.0 * stack[1:-1] + stack[:-2]
    sq = d2 * d2
    per_px = np.sqrt(sq.mean(axis=0))
    return {
        "rms": float(np.sqrt(sq[:, mask].mean())),
        "p99": float(np.percentile(per_px[mask], 99)),
        "rms_all": float(np.sqrt(sq.mean())),
    }


def selftest():
    rng = np.random.default_rng(1)
    yy, xx = np.mgrid[0:64, 0:64]
    base = 60.0 + 0.5 * xx + 0.3 * yy
    lin = np.stack([np.round(base + 0.7 * t) for t in range(FRAMES)]).astype(np.float32)
    noisy = np.stack([np.clip(np.round(base + rng.normal(0, 8, base.shape)), 0, 255)
                      for _ in range(FRAMES)]).astype(np.float32)
    every = np.ones(base.shape, bool)
    a, b = d2_stats(lin, every), d2_stats(noisy, every)
    assert a["rms"] < 1.0, ("linear drift must cancel", a)
    assert b["rms"] > 10.0, ("sigma-8 noise must be seen", b)
    edge = np.stack([np.where(xx < 32, 50.0, 200.0) for _ in range(FRAMES)]).astype(np.float32)
    assert not flat_mask(edge)[:, 30:34].any(), "edge pixels must be excluded from the flat mask"
    print("selftest OK: linear drift rms %.3f (cancels), sigma-8 noise rms %.2f (seen), edge excluded"
          % (a["rms"], b["rms"]))


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--ref", default="oidn48", help="run whose temporal mean defines the flat mask")
    ap.add_argument("--frames", type=int, default=FRAMES)
    ap.add_argument("runs", nargs="*", help="label=png_dir")
    a = ap.parse_args()
    if a.selftest:
        selftest()
        sys.exit(0)
    runs = dict(r.split("=", 1) for r in a.runs)
    mask = flat_mask(delivered(runs[a.ref], a.frames))
    print("flat mask from %s: %.1f%% of pixels" % (a.ref, 100.0 * mask.mean()))
    res = {}
    for label, d in runs.items():
        res[label] = d2_stats(delivered(d, a.frames), mask)
        r = res[label]
        print("%-8s d2 rms (flat) %.3f   p99 per-pixel (flat) %.3f   rms (all pixels) %.3f"
              % (label, r["rms"], r["p99"], r["rms_all"]))
    ok = True
    if "raw" in res and "dlssrr" in res:
        ratio = res["raw"]["rms"] / max(res["dlssrr"]["rms"], 1e-9)
        nc = ratio >= NEG_CONTROL_RATIO
        print("NEGATIVE CONTROL raw / dlssrr = %.2f (must be >= %.1f) -> %s"
              % (ratio, NEG_CONTROL_RATIO, "OK" if nc else "FAIL: the instrument cannot see noise"))
        ok = ok and nc
    if "oidn6" in res and "dlssrr" in res:
        ratio = res["oidn6"]["rms"] / max(res["dlssrr"]["rms"], 1e-9)
        gate = res["oidn6"]["rms"] <= res["dlssrr"]["rms"]
        print("GATE oidn6 / dlssrr = %.3f (must be <= 1.000) -> %s" % (ratio, "PASS" if gate else "FAIL"))
        ok = ok and gate
    sys.exit(0 if ok else 1)
```

Run: `python $R/pipeline_references/tests/video_oidn/flicker_metric.py --selftest`

Expected: `selftest OK: linear drift rms <1 (cancels), sigma-8 noise rms ~19.6 (seen), edge excluded`. If it does not print that, fix the script before rendering anything.

- [ ] **Step 4: Build the segment job**

```bash
python $R/pipeline_references/tests/video_oidn/make_segment_job.py $IN/urbanvideotest1.json $IN/uvt1_seg30.json --start 0 --count 30
```

Expected: `wrote ...: keyframes 0..29 (30 consecutive)`.

- [ ] **Step 5: Render the four configurations, one at a time**

Create `$W/run_t4m.sh`:

```bash
#!/bin/bash
# usage: run_t4m.sh <label> <env assignments...>
R=/c/Users/aiadmin/Desktop/Engine_Build_test/Zreal_Engine
W=$R/.superpowers/sdd/2026-10-01-video-oidn
BIN=$R/bin/godot.windows.editor.x86_64.console.exe
L="$1"; shift
D=$W/t4m/$L; rm -rf "$D"; mkdir -p "$D/png"
$W/make_test_project.sh "$D/proj" > /dev/null
powershell -NoProfile -Command "query session" 2>&1 | grep -i aiadmin > "$D/session_before.txt"
start=$(date +%s)
( cd "$D" && env "$@" $BIN --path "$D/proj/pipeline_references" --write-movie "$D/png/f.png" --fixed-fps 60 \
    res://video_main.tscn -- $W/inputs/uvt1_seg30.json "$D/out.mp4" "$D/frame.png" > "$D/run.log" 2>&1 )
echo "exit=$? secs=$(( $(date +%s) - start ))" > "$D/done"
powershell -NoProfile -Command "query session" 2>&1 | grep -i aiadmin > "$D/session_after.txt"
rm -rf "$D/proj"
echo "PNGs: $(ls $D/png/*.png | wc -l)"; cat "$D/done" "$D/session_before.txt" "$D/session_after.txt"
grep -a "\[VideoDenoiser\]\|\[OIDN\] \|Godot Engine v4.7" "$D/run.log"
```

Run each in the background, **waiting for one to finish before starting the next**:

```bash
bash $W/run_t4m.sh oidn6   ZR_VIDEO_DENOISER=oidn
bash $W/run_t4m.sh raw     ZR_VIDEO_DENOISER=none
bash $W/run_t4m.sh oidn48  ZR_VIDEO_DENOISER=oidn ZR_VIDEO_ACCUM_TARGET=16
bash $W/run_t4m.sh dlssrr  ZR_VIDEO_DENOISER=dlssrr
```

After each: `exit=0`; **51** PNGs (`oidn6`, `raw`, `oidn48`) or **56** (`dlssrr`) — stop if different; exactly one `Godot Engine v4.7` banner; the expected `[VideoDenoiser]` line (`oidn`, `none`, `oidn`, `dlssrr`, with NO "FLICKER TEST" suffix). If the session state differs between `session_before.txt` and `session_after.txt`, re-run that configuration and keep both. Approximate times at 4K: oidn6, raw and dlssrr ~6-8 min each, oidn48 ~30 min.

- [ ] **Step 6: Measure**

```bash
cd $W/t4m && python $R/pipeline_references/tests/video_oidn/flicker_metric.py --ref oidn48 \
    raw=$W/t4m/raw/png oidn6=$W/t4m/oidn6/png oidn48=$W/t4m/oidn48/png dlssrr=$W/t4m/dlssrr/png | tee $W/t4m/results.txt
```

Expected:
- `NEGATIVE CONTROL ... -> OK`. If it prints FAIL, the instrument is blind again: STOP and report before judging anything else.
- `GATE oidn6 / dlssrr ... -> PASS` or `FAIL` — the verdict for approach A.
- `oidn48` and the `rms (all pixels)` and `p99` columns are context, not gated.

Build the owner's crops — the same 600x400 region of the LAST DELIVERED frame (`files[-2]`) of each run. Write `$W/t4m/crops.py`:

```python
import glob
from PIL import Image, ImageDraw

W = r"C:/Users/aiadmin/Desktop/Engine_Build_test/Zreal_Engine/.superpowers/sdd/2026-10-01-video-oidn/t4m"
# (x0, y0, x1, y1) at 3840x2160. Look at oidn6's last delivered frame first and move the box onto a
# flat wall if it lands elsewhere -- flat walls are what the metric measures.
box = (1600, 900, 2200, 1300)
tiles = []
for m in ("oidn6", "oidn48", "dlssrr", "raw"):
    im = Image.open(sorted(glob.glob(W + "/" + m + "/png/*.png"))[-2]).convert("RGB").crop(box)
    t = Image.new("RGB", (600, 424), (30, 30, 30))
    t.paste(im, (0, 24))
    ImageDraw.Draw(t).text((6, 6), m, fill=(255, 255, 255))
    tiles.append(t)
out = Image.new("RGB", (600 * len(tiles) + 10 * (len(tiles) - 1), 424), (30, 30, 30))
for i, t in enumerate(tiles):
    out.paste(t, (i * 610, 0))
out.save(W + "/compare_crops.png")
print("wrote compare_crops.png")
```

Run `python $W/t4m/crops.py`. Then delete the four `png/` directories (keep `results.txt`, `compare_crops.png`, logs, `done` and session files).

- [ ] **Step 7: Record and update the spec**

Write `$W/t4m/verdict.md` with the result lines, PNG counts, session states, run times and the verdict. In the spec, replace the T4 row's description with:

```markdown
| T4 | **Flicker under motion -- decides A vs B** (revised 2026-10-03). urbanvideotest1 keyframes 0-29, consecutive, at production speed (`tests/video_oidn/make_segment_job.py`). Metric (`tests/video_oidn/flicker_metric.py`): per-pixel temporal second difference of 8-bit display luma, which cancels change linear in time (smooth camera motion) and keeps erratic frame-to-frame change; measured on the flattest half of the frame (one mask, from the oidn48 run, for every run), because a per-frame denoiser keeps moving edges sharp where a temporal one softens them. The first, static-camera design was blind: the accumulate route replays the same Sobol sequence each cycle (`scene_raytracing_raygen.glsl:417-421`), as Cycles gives every frame one seed by default (`use_animated_seed = False`), so identical content renders identically. | **rms(oidn6) <= rms(dlssrr)** on the flat mask: OIDN no less stable than today's DLSS-RR on the same frames. **Negative control:** rms(raw) >= 3 x rms(dlssrr). Context, not gated: oidn48, p99, all-pixel rms. |
```

and add a `**Measured (T4):**` paragraph under the testing table with the result lines from `results.txt`.

- **If the GATE PASSES:** continue to Task 4.
- **If it FAILS:** stop after committing. Report the numbers and `compare_crops.png`; the owner decides between proceeding to Task 4 and approach B. Tasks 1-2 are kept either way — B reuses the CUDA path and the Phase A loop.

- [ ] **Step 8: Commit**

```bash
cd $R && git add pipeline_references/tests/video_oidn/make_segment_job.py pipeline_references/tests/video_oidn/flicker_metric.py docs/superpowers/specs/2026-10-01-video-oidn-design.md
git commit -F - <<'EOF'
test(video): T4 flicker under motion for video OIDN -- <PASS|FAIL> at 6 spp

<the result lines verbatim from results.txt; that the negative control held; why the static
design was replaced (accum_frame seeding, Cycles' default fixed seed); the decision.>

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

Fill the angle-bracketed parts from `results.txt` before committing.

---

### Task 4: Production acceptance — budget, VRAM, the owner's review, closeout (REVISED 2026-10-04)

**PAUSED at Step 3 (2026-10-04) for Task 5.** The owner's review found the window view blotchy in OIDN; Task 5 fixes the cause. When Task 5 is complete, re-run Steps 1-2 on the fixed build, then Step 3 again.

**Runs by owner decision (2026-10-04).** T4's two numeric instruments could not be validated (see the facts in Step 4); the owner chose to decide A vs B by eye on the T7 material this task builds.

**Movie layout (measured in Task 2 — use it, do not re-derive it):** every movie is the pre-roll, then the delivered frames, then ONE trailing frame. Pre-roll is **20** frames in OIDN mode and **25** in DLSS-RR mode (20 warmup + 5 priming). So the full 421-frame job is **442** frames in OIDN mode (20 + 421 + 1, delivered = indices 20..440) and **447** in DLSS-RR mode (25 + 421 + 1, delivered = indices 25..445).

**Files:**
- Modify: `docs/superpowers/specs/2026-10-01-video-oidn-design.md` (T4 row, Measured section, frame-layout corrections)
- Modify: `PATH_TRACER_QUALITY_ROADMAP.md` (new section after the last one)

**Interfaces:**
- Consumes (Tasks 1-2): `ZR_VIDEO_DENOISER=oidn`; the `[Budget]` line; `[OIDN] denoising on CUDA`; `$IN/uvt1_dlssrr_full_20260930.avi` and its `.log` — the full urbanvideotest1 job rendered on the DLSS-RR path on 2026-09-30. T3 proved that path frame-identical after Tasks 1-2, so it is today's DLSS-RR output for this job.
- Produces: T5/T6 numbers, the T7 review material (Step 2), then — **after the owner's decision is relayed to you** — the closeout (Steps 4-5).

- [ ] **Step 1: T5 + T6 — the full job in OIDN mode, VRAM sampled**

Create `$W/run_t5.sh`:

```bash
#!/bin/bash
R=/c/Users/aiadmin/Desktop/Engine_Build_test/Zreal_Engine
W=$R/.superpowers/sdd/2026-10-01-video-oidn
BIN=$R/bin/godot.windows.editor.x86_64.console.exe
D=$W/t5; rm -rf "$D"; mkdir -p "$D"
$W/make_test_project.sh "$D/proj" > /dev/null
powershell -NoProfile -Command "query session" 2>&1 | grep -i aiadmin > "$D/session_before.txt"
nvidia-smi --query-gpu=timestamp,memory.used,memory.total --format=csv,noheader,nounits -l 5 > "$D/vram.csv" &
SMI=$!
start=$(date +%s)
( cd "$D" && env ZR_VIDEO_DENOISER=oidn VIDEO_RENDER_TIMEOUT_SECONDS=3600 $BIN --path "$D/proj/pipeline_references" \
    --write-movie "$D/movie.avi" --fixed-fps 60 res://video_main.tscn -- $W/inputs/urbanvideotest1.json "$D/out.mp4" "$D/frame.png" > "$D/run.log" 2>&1 )
echo "exit=$? secs=$(( $(date +%s) - start ))" > "$D/done"
kill $SMI
powershell -NoProfile -Command "query session" 2>&1 | grep -i aiadmin > "$D/session_after.txt"
rm -rf "$D/proj"
```

(The `nvidia-smi` sampler is the only process started with `&` — it is not a renderer.) Run `bash $W/run_t5.sh` in the background; it takes about an hour. Then:

```bash
cat $W/t5/done $W/t5/session_before.txt $W/t5/session_after.txt
grep -a "\[Budget\]\|\[OIDN\] \|VIDEO RENDER COMPLETE\|Godot Engine v4.7\|CUDA unavailable\|DEVICE_LOST\|Couldn't wait for Vulkan fence\|exposure at end of sequence" $W/t5/run.log
python -c "import csv;r=[float(x[1]) for x in csv.reader(open(r'$W/t5/vram.csv'))];print('VRAM peak %.0f MiB of %s' % (max(r), open(r'$W/t5/vram.csv').readline().split(',')[2].strip()))"
$FP -v error -select_streams v:0 -count_frames -show_entries stream=nb_read_frames -of csv=p=0 $W/t5/movie.avi
```

Expected:
- **T5:** `secs` under **3600**; the `[Budget]` projection within a few percent of it; `VIDEO RENDER COMPLETE - 421 frames`; **442** frames in the movie.
- **T6:** no `DEVICE_LOST` / fence errors, one banner, no `CUDA unavailable/failed`; VRAM peak with clear margin under 16376 MiB.

If `secs` ≥ 3600: **stop**. Record the per-frame time from the `[Budget]` line and the total, and report — the spec's named remedy (multithreading the conversion loops in `_oidn_final_denoise_accumulator`) becomes a separate Task 5 with its own code and its own T1/T2 re-run. Do not improvise it.

- [ ] **Step 2: T7 — build the owner's review material**

First confirm the two movies are like-for-like:

```bash
$FP -v error -select_streams v:0 -count_frames -show_entries stream=nb_read_frames -of csv=p=0 $IN/uvt1_dlssrr_full_20260930.avi
grep -a "exposure at end of sequence" $W/t5/run.log $IN/uvt1_dlssrr_full_20260930.log
```

Expected: **447** frames in the DLSS-RR movie; the same held exposure in both logs (the probe is independent of the denoiser). If either differs, stop and report — the comparison would not be like-for-like.

Look at one delivered frame of each first, to place the 1:1 crop on a region holding a flat wall AND an edge:

```bash
mkdir -p $W/t7
$FF -y -loglevel error -i $W/t5/movie.avi -vf "select=eq(n\,230)" -vsync 0 -frames:v 1 $W/t7/oidn_kf210.png
$FF -y -loglevel error -i $IN/uvt1_dlssrr_full_20260930.avi -vf "select=eq(n\,235)" -vsync 0 -frames:v 1 $W/t7/dlssrr_kf210.png
```

(Index 230 = OIDN pre-roll 20 + keyframe 210; index 235 = DLSS-RR pre-roll 25 + keyframe 210: the same pose.) Read both PNGs, choose `CX,CY` (top-left of a 1280x720 region at 3840x2160) on a flat wall with an edge, and record the choice and why. Defaults if nothing better: `CX=1280 CY=540`.

Then build, with OIDN on the LEFT and DLSS-RR on the RIGHT, the 421 delivered frames aligned:

```bash
CX=1280; CY=540   # replace with the chosen region
$FF -y -loglevel error -i $W/t5/movie.avi -i $IN/uvt1_dlssrr_full_20260930.avi -filter_complex \
  "[0:v]trim=start_frame=20:end_frame=441,setpts=PTS-STARTPTS,scale=1920:1080[a];[1:v]trim=start_frame=25:end_frame=446,setpts=PTS-STARTPTS,scale=1920:1080[b];[a][b]hstack" \
  -r 60 -c:v libx264 -crf 14 -pix_fmt yuv420p $W/t7/side_by_side_full.mp4
$FF -y -loglevel error -i $W/t5/movie.avi -i $IN/uvt1_dlssrr_full_20260930.avi -filter_complex \
  "[0:v]trim=start_frame=20:end_frame=441,setpts=PTS-STARTPTS,crop=1280:720:$CX:$CY[a];[1:v]trim=start_frame=25:end_frame=446,setpts=PTS-STARTPTS,crop=1280:720:$CX:$CY[b];[a][b]hstack" \
  -r 60 -c:v libx264 -crf 12 -pix_fmt yuv420p $W/t7/side_by_side_crop_1to1.mp4
$FP -v error -select_streams v:0 -count_frames -show_entries stream=nb_read_frames,width,height -of csv=p=0 $W/t7/side_by_side_full.mp4
$FP -v error -select_streams v:0 -count_frames -show_entries stream=nb_read_frames,width,height -of csv=p=0 $W/t7/side_by_side_crop_1to1.mp4
```

Expected: `3840,1080,421` and `2560,720,421`.

Write `$W/t7/crops.py` for the still crops (staircase / checkerboard check at keyframe 210):

```python
from PIL import Image, ImageDraw

W = r"C:/Users/aiadmin/Desktop/Engine_Build_test/Zreal_Engine/.superpowers/sdd/2026-10-01-video-oidn/t7"
# (x0, y0, x1, y1) at 3840x2160: an edge-heavy region and a plain wall. Move them onto a furniture
# outline and a flat wall if they land elsewhere (look at oidn_kf210.png first).
boxes = {"edges": (1500, 1000, 1800, 1200), "flat wall": (400, 300, 700, 500)}
rows = []
for name, box in boxes.items():
    pair = []
    for m in ("oidn", "dlssrr"):
        im = Image.open(W + "/" + m + "_kf210.png").convert("RGB").crop(box)
        im = im.resize((im.width * 2, im.height * 2), Image.NEAREST)  # 2x, nearest: staircase stays visible
        t = Image.new("RGB", (im.width, im.height + 24), (30, 30, 30))
        t.paste(im, (0, 24))
        ImageDraw.Draw(t).text((6, 6), "%s: %s" % (m, name), fill=(255, 255, 255))
        pair.append(t)
    row = Image.new("RGB", (pair[0].width * 2 + 10, pair[0].height), (30, 30, 30))
    row.paste(pair[0], (0, 0))
    row.paste(pair[1], (pair[0].width + 10, 0))
    rows.append(row)
out = Image.new("RGB", (rows[0].width, sum(r.height for r in rows) + 10), (30, 30, 30))
y = 0
for r in rows:
    out.paste(r, (0, y))
    y += r.height + 10
out.save(W + "/crops.png")
print("wrote crops.png")
```

Run `python $W/t7/crops.py`.

- [ ] **Step 3: STOP — report for the owner's review**

Do not write the closeout yet. Reply with status DONE_WITH_CONCERNS and the first line `AWAITING OWNER REVIEW`, then the T5/T6 numbers and the paths of `side_by_side_full.mp4`, `side_by_side_crop_1to1.mp4` and `crops.png` (OIDN left, DLSS-RR right in all three). The controller shows them to the owner and resumes you with the decision.

- [ ] **Step 4: Close out the spec and the roadmap (after the owner's decision)**

In the spec:

1. **Frame layout.** Correct every frame decomposition to "pre-roll, delivered, 1 trailing": 33 = 20 + 12 + 1 (OIDN, 12 keyframes), 38 = 20 + 5 + 12 + 1 (DLSS-RR), 442 = 20 + 421 + 1 (OIDN, full job).
2. **T4 row.** Replace its description and bar with: "**Not validated.** Two instruments were built; each failed its own pre-registered negative control, so no numeric gate decided A vs B. The owner decided by eye at T7 (2026-10-04)." Then add a `**T4, measured (2026-10-03):**` paragraph under the testing table with exactly these facts:
   - *Design 1* (one pose held 30 frames, accumulator force-reset each frame): blind. Raw 9-spp frames read mean 0.033 levels; all 30 delivered frames were md5-identical in both the raw and the OIDN runs. Cause: the accumulate route seeds from `accum_frame`, which resets with the accumulator (`scene_raytracing_raygen.glsl:417-421`), so every cycle replays the same Sobol sequence — as Cycles gives every frame one seed by default (`use_animated_seed = False`, `blender/addon/properties.py:905-908`; `blender/sync.cpp:408`). Consequence for production: on static content OIDN video cannot flicker.
   - *Design 2* (urbanvideotest1 keyframes 0-29 at production speed; per-pixel temporal second difference on the flattest half of the frame, one mask from the 48-spp run): d2 rms raw 28.717, oidn6 14.033, oidn48 13.801, dlssrr 13.215. Negative control raw/dlssrr = 2.17 against a pre-registered 3.0: FAILED. A content floor of about 13.8 levels (texture sliding past at constant speed; the motion-smeared mean made the "flat" mask permissive) swamps the noise. The gate's 1.062 is therefore not a verdict, and is biased besides: DLSS-RR reads 4.2% *below* the near-noise-free 48-spp reference because its temporal smoothing also damps moving texture.
   - *Descriptive, post-hoc, not a gate:* in quadrature against the 48-spp run, raw adds 25.18 levels of temporal noise and 6-spp OIDN 2.54; 6 spp reads 1.7% above 48 spp (same denoiser, same frames, only the samples differ) — 8x the samples barely moved stability.
   - *Defect found in the plan's metric code:* the flat-mask box blur summed in float32 over a 4K frame (sums ~2e9, float32 spacing 128-256), wrong on 43.8% of pixels in a synthetic check; fixed to float64. The plan-verbatim version gave control 1.92 and gate 1.047 — the same outcomes.
3. **Measured section.** Append `## Measured (<the run date>)` with: T1 (fixture: 83.61% of floats differing, 0 pixels at 2+ levels, max 1; job 201: 100.00% differing, 0.0000% at 2+ levels, max 1, 61.46 dB, input md5s identical); T2 (still route unchanged: the new and the pre-change binaries both give `befe659d…` with the session connected — the archived `2a17e657…` is no longer reproducible on unchanged code, so "stills unchanged" is an A/B of binaries in one session state); T3 (38 of 38 frames identical); T4 (see above); T5 (seconds, per-frame, budget projection); T6 (VRAM peak); T7 (the owner's decision and its date, verbatim as relayed).

Add to `PATH_TRACER_QUALITY_ROADMAP.md`, after the last section, `## 11.32 Video OIDN -- per-frame OpenImageDenoise, as Cycles animates`: why video left DLSS-RR (the still route's staircase / checkerboard finding); that Cycles has no temporal OIDN and gives every frame one seed by default, and that this route does both the same way; the CUDA path (157 vs 5270 ms per 4K frame, visually identical to CPU); T4's outcome as recorded above; T5-T7; the follow-ups — approach B only if more detail is wanted, moving stills to CUDA, the still route's wasted denoise inside its exposure probe.

- [ ] **Step 5: Commit**

```bash
cd $R && git add docs/superpowers/specs/2026-10-01-video-oidn-design.md PATH_TRACER_QUALITY_ROADMAP.md
git commit -F - <<'EOF'
docs(video): video OIDN closeout -- budget, VRAM, T4's outcome and the owner's review

<T5 seconds and per-frame; T6 VRAM peak; T4 recorded as not validated with the two designs'
numbers; T7 decision; anything that surprised.>

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

Ship manifest for the owner: the engine binary (Task 1 changed C++) **plus** `pipeline_references/video_glb_creation.gd` and `pipeline_references/video_render.gd`. Unlike the earlier GDScript-only video ports, this one needs the rebuilt engine in `C:\Zlendo2026\ZlenderRender_stage_copy\godot\bin\`.

---

### Task 5: Engine — OIDN guides follow Cycles' denoising features through transparency and smooth specular (INSERTED 2026-10-04)

**Why this task exists.** Task 4's review material showed the window view blotchy in OIDN and clean in DLSS-RR. The owner decided (2026-10-04): "fix the glass the Blender way first". **Spec:** `docs/superpowers/specs/2026-10-04-oidn-guide-feature-passthrough-design.md` — read it first; it holds the measurements, the root cause and the Cycles references. **Task 4 is paused at its Step 3 and resumes after this task** (its Steps 1-2 are re-run on the fixed build).

**Global-constraint exception (owner, 2026-10-04).** "Stills must not change" does not hold for this task: still guides change wherever a window, glass or mirror is in view, which is the point. Everything else stands. In particular, DLSS-RR output must stay frame-identical (Step 6), because the DLSS-RR G-buffer writes are not touched.

**Files:**
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_inc.glsl` (payload field, PathState fields, pack/unpack)
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/scene_raytracing_raygen.glsl` (init, path-end write, two miss sites)
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl` (rule + surface write)
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_lights_inc.glsl` (shadow-ray init)
- Create: `pipeline_references/tests/pt_oidn_guide_passthrough_gate.gd` + `pt_oidn_guide_passthrough_gate_scene.tscn`
- Modify: `docs/superpowers/specs/2026-10-04-oidn-guide-feature-passthrough-design.md` (append "Measured")

**Evidence already on disk (cite, do not repeat):** `$W/dump_base/` (keyframe-210 OIDN inputs, current build: 92.7% of the pane region unwritten), `$W/probe/` (the 256x256 reproduction: 80% unwritten), `$W/t7/` (Task 4's review material), `$W/run_dump.sh` (re-dumps keyframe 210 into `$W/dump_<tag>/`).

- [ ] **Step 1: Keep the pre-change binary for A/B**

```bash
cd $R && cp bin/godot.windows.editor.x86_64.exe bin/godot_pre5.windows.editor.x86_64.exe && cp bin/godot.windows.editor.x86_64.console.exe bin/godot_pre5.windows.editor.x86_64.console.exe
OLD=$R/bin/godot_pre5.windows.editor.x86_64.console.exe
```

It sits in `bin/` so it finds the same DLLs. The console wrapper launches its sibling by name, so check that `$OLD --version` prints a version and that a process listing during a run shows `godot_pre5...exe`. Delete both files at the end of the task (Step 9).

- [ ] **Step 2: Write the gate**

Create `pipeline_references/tests/pt_oidn_guide_passthrough_gate_scene.tscn`:

```
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://tests/pt_oidn_guide_passthrough_gate.gd" id="1_gate"]

[node name="PTOidnGuidePassthroughGate" type="Node"]
script = ExtResource("1_gate")
```

Create `pipeline_references/tests/pt_oidn_guide_passthrough_gate.gd`:

```gdscript
extends "res://tests/pt_validation.gd"

## OIDN guide pass-through gate (spec 2026-10-04-oidn-guide-feature-passthrough-design.md).
##
##   bin\godot.windows.editor.x86_64.console.exe --rendering-driver vulkan \
##       --path pipeline_references res://tests/pt_oidn_guide_passthrough_gate_scene.tscn
##
## 256x256. Top half: a uniform sky. Bottom half: a 4-px checker card. Three columns,
## seen through a plane 5 m from the camera: OPEN | an ALPHA pane authored like the
## production window (Mat_A38_Window_Glass_001) | a smooth thin GLASS pane (the material
## _apply_glb_transmissive_glass produces). 6 accumulated samples -- the video route's
## count -- then OIDN, with ZR_OIDN_DUMP pointed at a temp dir so the gate reads the
## guides OIDN actually received.
##
##   F0 dumps  : the four OIDN dumps exist at 256x256 and OIDN changed the image
##   F1 premise: colour behind the alpha pane / open, per row, in [F1_MIN, F1_MAX]
##   F2 written: unwritten guide pixels behind each pane <= UNWRITTEN_MAX, per row
##   F3 alpha  : guide albedo behind the alpha pane within ALPHA_TOL of the authored mix
##   F4 glass  : checker guide-albedo std behind the glass / open >= GLASS_DETAIL_MIN
##   F5 open   : open guides as authored -- sky albedo == sky colour, checker mean ==
##               the texture's linear mean
##   F6 result : OIDN output checker std behind each pane / open >= OUT_DETAIL_MIN
##
## On the build before the fix, a surface seen through an alpha pane is bounce 1
## (inc_transmission_bounce adds to the total) and writes no guide: F2 reads about 80%
## unwritten, and F3 about 0.09x. The glass's guide is the pane's own flat white: F4
## about 0.

const FRAMES := 6
const SKY := Color(0.5, 0.6, 0.8)
const PANE_ALPHA := 0.033
const PANE_BASE_LINEAR := 0.7067
const PANE_ROUGHNESS := 0.0916
const CAM_DIST := 10.0
const CAM_FOV := 10.0
const PANE_Z := 5.0

const F1_MIN := 0.95
const F1_MAX := 1.05
const UNWRITTEN_MAX := 0.01
const ALPHA_TOL := 0.05
const GLASS_DETAIL_MIN := 0.85
const F5_SKY_TOL := 1e-3
const F5_CHECK_TOL := 0.02
const OUT_DETAIL_MIN := 0.80

# Regions [x0, x1) x [y0, y1) in pixels, image y down. Column edges are 85.3 and 170.7;
# every region keeps a margin and spans whole 8-px checker periods.
const COLS := {"open": [8, 72], "alpha": [96, 160], "glass": [184, 248]}
const ROWS := {"sky": [8, 120], "checker": [136, 248]}

var _failures: Array[String] = []
var _checks: int = 0


func _ready() -> void:
	get_window().content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	get_window().size = Vector2i(256, 256)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	# The still route's viewport contract, as pt_oidn_guide_gate.gd.
	get_viewport().msaa_3d = Viewport.MSAA_DISABLED
	get_viewport().screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	get_viewport().use_taa = false
	get_viewport().use_debanding = false
	get_viewport().scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	get_viewport().scaling_3d_scale = 1.0
	get_viewport().use_hdr_2d = true
	await get_tree().process_frame
	await get_tree().process_frame

	var dump_dir := ProjectSettings.globalize_path("user://pt_oidn_guide_passthrough_gate")
	DirAccess.make_dir_recursive_absolute(dump_dir)
	for n in ["oidn_color.pfm", "oidn_albedo.pfm", "oidn_normal.pfm", "oidn_output.pfm"]:
		DirAccess.remove_absolute(dump_dir.path_join(n))
	OS.set_environment("ZR_OIDN_DUMP", dump_dir)

	var env := _new_env(SKY)
	env.set_pathtracing_max_bounces(6)
	env.set_pathtracing_oidn_denoise(true)

	var side := 2.0 * CAM_DIST * tan(deg_to_rad(CAM_FOV) * 0.5)

	# Checker card, bottom half, 1:1 with the pixels (256 x 128 texels), 4-px cells.
	var img := Image.create(256, 128, false, Image.FORMAT_RGB8)
	for y in range(128):
		for x in range(256):
			var on := ((x / 4) + (y / 4)) % 2 == 0
			img.set_pixel(x, y, Color(0.9, 0.9, 0.9) if on else Color(0.1, 0.1, 0.1))
	var card := MeshInstance3D.new()
	var cq := QuadMesh.new()
	cq.size = Vector2(side, side * 0.5)
	card.mesh = cq
	card.position = Vector3(0, -side * 0.25, 0)
	var cm := StandardMaterial3D.new()
	cm.albedo_texture = ImageTexture.create_from_image(img)
	cm.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	cm.metallic = 0.0
	cm.metallic_specular = 0.0
	cm.roughness = 1.0
	card.material_override = cm
	add_child(card)

	# The two panes, each one column wide and the full frame tall at PANE_Z.
	var w := 2.0 * (CAM_DIST - PANE_Z) * tan(deg_to_rad(CAM_FOV) * 0.5)

	# Authored like Mat_A38_Window_Glass_001. albedo_color is sRGB-encoded; glTF's
	# baseColorFactor is linear, so author the linear 0.7067 through linear_to_srgb().
	var am := StandardMaterial3D.new()
	var pane_srgb := Color(PANE_BASE_LINEAR, PANE_BASE_LINEAR, PANE_BASE_LINEAR).linear_to_srgb()
	am.albedo_color = Color(pane_srgb.r, pane_srgb.g, pane_srgb.b, PANE_ALPHA)
	am.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	am.cull_mode = BaseMaterial3D.CULL_DISABLED
	am.metallic = 0.0
	am.roughness = PANE_ROUGHNESS
	_add_pane(Vector3(0.0, 0.0, PANE_Z), w, am)

	# The material _apply_glb_transmissive_glass produces (video_glb_creation.gd).
	var gm := StandardMaterial3D.new()
	gm.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	gm.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_OPAQUE_ONLY
	gm.no_depth_test = false
	gm.metallic = 0.0
	gm.transmission = 1.0
	gm.ior = 1.5
	gm.metallic_specular = 0.5
	gm.thickness = 0.0
	gm.albedo_color = Color(1.0, 1.0, 1.0, 1.0)
	gm.roughness = 0.0
	_add_pane(Vector3(w / 3.0, 0.0, PANE_Z), w, gm)

	var cam := Camera3D.new()
	cam.fov = CAM_FOV
	cam.near = 0.1
	cam.far = 100.0
	cam.position = Vector3(0, 0, CAM_DIST)
	add_child(cam)
	cam.make_current()
	await get_tree().create_timer(1.0).timeout

	await _render_accum(env, get_viewport().get_viewport_rid(), FRAMES)
	# OIDN fires on the frame the accumulator reaches its target; give it two frames.
	await get_tree().process_frame
	await get_tree().process_frame
	await RenderingServer.frame_post_draw

	var col := _read_pfm(dump_dir.path_join("oidn_color.pfm"))
	var alb := _read_pfm(dump_dir.path_join("oidn_albedo.pfm"))
	var nrm := _read_pfm(dump_dir.path_join("oidn_normal.pfm"))
	var out := _read_pfm(dump_dir.path_join("oidn_output.pfm"))

	print("\n=== F0: OIDN dumps ===")
	_checks += 1
	var have := not col.is_empty() and not alb.is_empty() and not nrm.is_empty() and not out.is_empty()
	if not have or col.w != 256 or col.h != 256:
		_failures.append("F0 dumps missing or not 256x256 under %s" % dump_dir)
		_finish()
		return
	var changed := absf(_luma_std(out, COLS.open, ROWS.checker) - _luma_std(col, COLS.open, ROWS.checker)) > 1e-6
	print("  four dumps present; OIDN changed the image: %s" % changed)
	if not changed:
		_failures.append("F0 OIDN output equals its input -- OIDN did not run")

	print("\n=== F1: premise (colour behind the alpha pane / open) ===")
	for row in ["sky", "checker"]:
		_checks += 1
		var r := _luma_mean(col, COLS.alpha, ROWS[row]) / maxf(_luma_mean(col, COLS.open, ROWS[row]), 1e-6)
		print("  %-8s %.4f  (want [%.2f, %.2f])" % [row, r, F1_MIN, F1_MAX])
		if r < F1_MIN or r > F1_MAX:
			_failures.append("F1 %s colour ratio %.4f outside [%.2f, %.2f]" % [row, r, F1_MIN, F1_MAX])

	print("\n=== F2: guides written behind each pane ===")
	for pane in ["alpha", "glass"]:
		for row in ["sky", "checker"]:
			_checks += 1
			var u := _unwritten(alb, nrm, COLS[pane], ROWS[row])
			print("  %-6s %-8s unwritten %.2f%%  (max %.0f%%)" % [pane, row, u * 100.0, UNWRITTEN_MAX * 100.0])
			if u > UNWRITTEN_MAX:
				_failures.append("F2 %s/%s unwritten %.2f%% > %.0f%%" % [pane, row, u * 100.0, UNWRITTEN_MAX * 100.0])

	print("\n=== F3: guide albedo behind the alpha pane ===")
	for row in ["sky", "checker"]:
		_checks += 1
		var open_m := _luma_mean(alb, COLS.open, ROWS[row])
		var want := (1.0 - PANE_ALPHA) * open_m + PANE_ALPHA * PANE_BASE_LINEAR
		var got := _luma_mean(alb, COLS.alpha, ROWS[row])
		var rel := got / maxf(want, 1e-6)
		print("  %-8s got %.4f want %.4f  ratio %.4f  (tol %.0f%%)" % [row, got, want, rel, ALPHA_TOL * 100.0])
		if absf(rel - 1.0) > ALPHA_TOL:
			_failures.append("F3 %s alpha-pane albedo %.4f vs %.4f (ratio %.4f)" % [row, got, want, rel])

	print("\n=== F4: checker detail in the guide behind the glass ===")
	_checks += 1
	var g4 := _luma_std(alb, COLS.glass, ROWS.checker) / maxf(_luma_std(alb, COLS.open, ROWS.checker), 1e-6)
	print("  std ratio %.4f  (min %.2f)" % [g4, GLASS_DETAIL_MIN])
	if g4 < GLASS_DETAIL_MIN:
		_failures.append("F4 glass guide detail %.4f < %.2f" % [g4, GLASS_DETAIL_MIN])

	print("\n=== F5: open guides as authored ===")
	_checks += 1
	var sky_l := 0.2126 * SKY.r + 0.7152 * SKY.g + 0.0722 * SKY.b
	var sky_got := _luma_mean(alb, COLS.open, ROWS.sky)
	print("  sky albedo %.5f want %.5f" % [sky_got, sky_l])
	if absf(sky_got - sky_l) > F5_SKY_TOL:
		_failures.append("F5 open sky albedo %.5f != %.5f" % [sky_got, sky_l])
	_checks += 1
	var tex_mean := 0.5 * (Color(0.9, 0.9, 0.9).srgb_to_linear().r + Color(0.1, 0.1, 0.1).srgb_to_linear().r)
	var chk_got := _luma_mean(alb, COLS.open, ROWS.checker)
	print("  checker albedo mean %.5f want %.5f" % [chk_got, tex_mean])
	if absf(chk_got / tex_mean - 1.0) > F5_CHECK_TOL:
		_failures.append("F5 open checker albedo %.5f vs %.5f" % [chk_got, tex_mean])

	print("\n=== F6: denoised checker detail behind each pane ===")
	var open_out := _luma_std(out, COLS.open, ROWS.checker)
	for pane in ["alpha", "glass"]:
		_checks += 1
		var r6 := _luma_std(out, COLS[pane], ROWS.checker) / maxf(open_out, 1e-6)
		var r6raw := _luma_std(col, COLS[pane], ROWS.checker) / maxf(_luma_std(col, COLS.open, ROWS.checker), 1e-6)
		print("  %-6s output std ratio %.4f (raw colour ratio %.4f)  (min %.2f)" % [pane, r6, r6raw, OUT_DETAIL_MIN])
		if r6 < OUT_DETAIL_MIN:
			_failures.append("F6 %s denoised detail %.4f < %.2f" % [pane, r6, OUT_DETAIL_MIN])

	_finish()


func _add_pane(p_pos: Vector3, p_w: float, p_mat: StandardMaterial3D) -> void:
	var mi := MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = Vector2(p_w / 3.0, p_w)
	mi.mesh = q
	mi.position = p_pos
	mi.material_override = p_mat
	add_child(mi)


# Little-endian PFM as _oidn_write_pfm writes it: "PF\n<w> <h>\n-1.0\n", rows bottom-up.
func _read_pfm(p_path: String) -> Dictionary:
	var f := FileAccess.open(p_path, FileAccess.READ)
	if f == null:
		return {}
	var magic := f.get_line().strip_edges()
	var dims := f.get_line().strip_edges().split(" ", false)
	var scale := float(f.get_line().strip_edges())
	if magic != "PF" or dims.size() != 2 or scale >= 0.0:
		return {}
	var w := int(dims[0])
	var h := int(dims[1])
	var buf := f.get_buffer(w * h * 12)
	if buf.size() != w * h * 12:
		return {}
	return {"w": w, "h": h, "data": buf}


func _px(p_img: Dictionary, p_x: int, p_y: int) -> Vector3:
	var o: int = (((p_img.h - 1 - p_y) * p_img.w) + p_x) * 12
	var d: PackedByteArray = p_img.data
	return Vector3(d.decode_float(o), d.decode_float(o + 4), d.decode_float(o + 8))


func _luma(p_c: Vector3) -> float:
	return 0.2126 * p_c.x + 0.7152 * p_c.y + 0.0722 * p_c.z


func _luma_mean(p_img: Dictionary, p_cols: Array, p_rows: Array) -> float:
	var acc := 0.0
	var n := 0
	for y in range(p_rows[0], p_rows[1]):
		for x in range(p_cols[0], p_cols[1]):
			acc += _luma(_px(p_img, x, y))
			n += 1
	return acc / float(n)


func _luma_std(p_img: Dictionary, p_cols: Array, p_rows: Array) -> float:
	var m := _luma_mean(p_img, p_cols, p_rows)
	var acc := 0.0
	var n := 0
	for y in range(p_rows[0], p_rows[1]):
		for x in range(p_cols[0], p_cols[1]):
			var dl := _luma(_px(p_img, x, y)) - m
			acc += dl * dl
			n += 1
	return sqrt(acc / float(n))


# A guide pixel nothing wrote: albedo exactly 0 and the readback's (0, 0, 1) fallback
# for a zero-length normal (render_forward_clustered.cpp, the normal conversion).
func _unwritten(p_alb: Dictionary, p_nrm: Dictionary, p_cols: Array, p_rows: Array) -> float:
	var bad := 0
	var n := 0
	for y in range(p_rows[0], p_rows[1]):
		for x in range(p_cols[0], p_cols[1]):
			var a := _px(p_alb, x, y)
			var nn := _px(p_nrm, x, y)
			if a.x + a.y + a.z == 0.0 and nn.distance_to(Vector3(0, 0, 1)) < 1e-4:
				bad += 1
			n += 1
	return float(bad) / float(n)


func _finish() -> void:
	print("")
	if _failures.is_empty():
		print("PASS: all %d OIDN guide pass-through checks passed." % _checks)
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

Two facts the code relies on, already verified: the sky pano `FORMAT_RGBF` reaches the guide as exactly `SKY` (the probe read (0.50, 0.60, 0.80)), and an `RGB8` checker texture is sRGB, so its linear mean is the `srgb_to_linear` mean (the probe read 0.397 for 0.3987). If either is wrong, F5 says so on the CURRENT build. Fix the gate then, not the threshold.

- [ ] **Step 3: Run the gate on the CURRENT build. It must fail the right checks.**

```bash
cd $R && $BIN --rendering-driver vulkan --path pipeline_references res://tests/pt_oidn_guide_passthrough_gate_scene.tscn > $W/t5g_pre.log 2>&1; echo exit=$?; grep -aE "^  |FAIL|PASS" $W/t5g_pre.log
```

Expected on the current build: F0, F1 and F5 pass. F2 alpha (both rows) fails at about 80%, F3 fails at about 0.09x, and F4 fails near 0. F2 glass passes on this build, since that pane's guide is written, just wrong; it guards the glass path against regressing into "unwritten". F6: record both values. **F6 counts as a check only if it fails here.** If it passes on the current build, demote it to an informative print in Step 5 (no `_checks += 1`, no failure) and say so in the report. If F2-alpha, F3 or F4 does not fail, STOP and report: the gate is not measuring the defect.

- [ ] **Step 4: The shader changes**

All four files are in `servers/rendering/renderer_rd/shaders/raytracing/`. Make each edit exactly. Apply edits with the Edit tool, never a shell heredoc (heredocs eat trailing backslashes).

**4a. `raytracing_inc.glsl`, `struct PathPayload`.** After the `vec3 mis_origin;` member (and its comment block), add:

```glsl
	// OIDN guides (spec 2026-10-04-oidn-guide-feature-passthrough-design.md): Cycles'
	// PATH_RAY_DENOISING_FEATURES and denoising_feature_throughput. packUnorm4x8 of
	// (throughput.rgb, pending ? 1 : 0). The throughput is a product of albedos, in
	// [0, 1]; 1.0 round-trips exactly. 4 bytes; struct is 96.
	uint feat_state;
```

**4b. `raytracing_inc.glsl`, `struct PathState`.** After `vec3 mis_origin;` add:

```glsl
	vec3 feat_throughput; // OIDN guide: product of the specular albedos deferred through
	bool feat_pending; // OIDN guide: this sample has not written its guide yet
```

**4c. `path_unpack`.** Before `return s;` add:

```glsl
	vec4 feat = unpackUnorm4x8(p.feat_state);
	s.feat_throughput = feat.rgb;
	s.feat_pending = feat.a > 0.5;
```

**4d. `path_pack`.** After `p.mis_origin = s.mis_origin;` add:

```glsl
	p.feat_state = packUnorm4x8(vec4(s.feat_throughput, s.feat_pending ? 1.0 : 0.0));
```

**4e. `raytracing_lights_inc.glsl`, the shadow-ray state (`PathState shadow_ps;`, about :308).** After `shadow_ps.guide_record = false;` add:

```glsl
	shadow_ps.feat_throughput = vec3(1.0);
	shadow_ps.feat_pending = false;
```

Then search all four files for any other `PathState` built field by field (`grep -n "PathState [a-z_]*;"`). The known sites are raygen `trace_one_sample` (4f) and the shadow ray (4e). Any other site gets the same two lines, and you list it in the report.

**4f. `scene_raytracing_raygen.glsl`, `trace_one_sample`.** After `ps.guide_record = false;` (about :164) add:

```glsl
	// OIDN guides: one guide sample per Phase A sample. One-shot mode (DLSS-RR,
	// realtime) never sets it, so that path does no extra work.
	ps.feat_throughput = vec3(1.0);
	ps.feat_pending = p_is_sample_zero && get_rt_param(RT_PARAM_ACCUM_FLAG) > 0.5;
```

At the end of the same function, immediately after the bounce loop's closing brace and BEFORE the `// Gap #32: train from the finished path.` comment, add:

```glsl
#ifdef DLSS_RR_ENABLED
	// A path that ended with its guide still pending (it was deferring through a smooth
	// surface when a cap, roulette or absorption stopped it) contributes a zero sample,
	// as in Cycles, where it contributes nothing to the summed pass. Runs before main()
	// stores n + 1, so rt_accum_guide_sample's weight is this sample's.
	if (ps.feat_pending) {
		rt_accum_guide_sample(ivec2(p_pixel), vec3(0.0), vec3(0.0));
	}
#endif
```

**4g. Miss stage, fog scatter (about :518-527).** In the block

```glsl
		if (get_total_bounces(ps.packed_bounces_flags) == 0u && is_sample_zero(ps.packed_bounces_flags)) {
			ivec2 pixel = ivec2(gl_LaunchIDEXT.xy);
			imageStore(rt_depth_image, pixel, vec4(0.0));
#ifdef DLSS_RR_ENABLED
			...four imageStore lines...
			rt_accum_guide_sample(pixel, volume_albedo(), -gl_WorldRayDirectionEXT);
#endif
		}
```

delete the `rt_accum_guide_sample(...)` line. Then, after that `if` block's closing brace and before `path_pack(payload, ps);`, add:

```glsl
#ifdef DLSS_RR_ENABLED
		if (ps.feat_pending) {
			float t_avg = (ps.feat_throughput.r + ps.feat_throughput.g + ps.feat_throughput.b) / 3.0;
			rt_accum_guide_sample(ivec2(gl_LaunchIDEXT.xy), volume_albedo() * ps.feat_throughput,
					-gl_WorldRayDirectionEXT * t_avg);
			ps.feat_pending = false;
		}
#endif
```

**4h. Miss stage, sky (about :589-602).** In the `#ifdef DLSS_RR_ENABLED` block, delete `rt_accum_guide_sample(pixel, sky_color, -gl_WorldRayDirectionEXT);`. Then, after the inner `if (total_bounces == 0u && ...) { ... }` closes, still inside the `#ifdef`'s braces, add:

```glsl
		if (ps.feat_pending) {
			float t_avg = (ps.feat_throughput.r + ps.feat_throughput.g + ps.feat_throughput.b) / 3.0;
			rt_accum_guide_sample(ivec2(gl_LaunchIDEXT.xy), sky_color * ps.feat_throughput,
					-gl_WorldRayDirectionEXT * t_avg);
			ps.feat_pending = false;
		}
```

The miss stage packs `ps` at its end (`path_pack(payload, ps);`, about :659), so the cleared flag reaches raygen.

**4i. `raytracing_closest_hit_common_inc.glsl`, the rule and the surface write.** Immediately above `void shade_and_bounce(HitData h, MaterialResult m) {` (about :1368) add:

```glsl
#ifdef DLSS_RR_ENABLED
// Cycles' denoising-feature rule as shipped through 2026-03-03 (film/denoising_passes.h at
// the parent of 44be56fd493): a closure whose GGX alpha exceeds 0.075 is diffuse-like, and
// a surface writes its features when diffuse-like closures hold more than a quarter of the
// weight; otherwise the features wait for the next bounce, carried by the specular albedo.
// Spec 2026-10-04-oidn-guide-feature-passthrough-design.md, section 3. Estimated from our
// one-material model: no coat or sheen, and no (1 - F) layering factor on the diffuse.
bool rt_guide_defers(MaterialProperties p_mat, float p_NdotV, vec3 p_specularF0, out vec3 r_spec_albedo) {
	r_spec_albedo = vec3(0.0);
	if (p_mat.roughness * p_mat.roughness > 0.075) {
		return false;
	}
	vec3 d = baseColorToDiffuseReflectance(p_mat.baseColor, p_mat.metalness, p_mat.transmissivness);
	vec3 spec = DLSSRR_computeSpecularAlbedo(p_mat.baseColor, p_mat.metalness, p_mat.dielectricF0, p_mat.roughness, p_NdotV);
	if (p_mat.transmissivness > 0.0) {
		vec3 refl;
		vec3 trans;
		float cos_theta_t = 0.0;
		dielectricFresnelSplit(p_NdotV, p_mat.eta, p_specularF0, p_mat.transmissivness, refl, trans, cos_theta_t);
		spec += (1.0 - p_mat.metalness) * trans;
	}
	r_spec_albedo = spec;
	float w_diff = (d.r + d.g + d.b) / 3.0;
	float w_spec = (spec.r + spec.g + spec.b) / 3.0;
	return (w_diff + w_spec > 0.0) && !(w_diff * 4.0 > w_diff + w_spec);
}

// One guide sample per path (spec section 2): runs at every surface while the sample's
// guide is pending, and writes at the first surface that does not defer. With
// feat_throughput == 1 it writes exactly what the bounce-0 write always wrote.
void rt_guide_features_surface(inout PathState p_ps, MaterialProperties p_mat, vec3 p_diffuse_albedo,
		vec3 p_N, float p_NdotV, vec3 p_specularF0) {
	if (!p_ps.feat_pending) {
		return;
	}
	ivec2 pixel = ivec2(gl_LaunchIDEXT.xy);
	vec3 spec_albedo;
	if (rt_guide_defers(p_mat, p_NdotV, p_specularF0, spec_albedo)) {
		p_ps.feat_throughput *= clamp(spec_albedo, vec3(0.0), vec3(1.0));
		if (max(max(p_ps.feat_throughput.r, p_ps.feat_throughput.g), p_ps.feat_throughput.b) <= 1e-4) {
			// Cycles clears the flag and the path contributes nothing; the running mean
			// still needs this sample's one write.
			rt_accum_guide_sample(pixel, vec3(0.0), vec3(0.0));
			p_ps.feat_pending = false;
		}
		return;
	}
	float t_avg = (p_ps.feat_throughput.r + p_ps.feat_throughput.g + p_ps.feat_throughput.b) / 3.0;
	rt_accum_guide_sample(pixel, p_diffuse_albedo * p_ps.feat_throughput, p_N * t_avg);
	p_ps.feat_pending = false;
}
#endif
```

Then at the DLSS-RR output block (about :1823-1866): delete the line `rt_accum_guide_sample(pixel, diffuse_albedo, N);` (about :1834). After that block's closing `}` and BEFORE its `#endif` (the one just above the `// NEE: Next Event Estimation` banner and its `path_pack(payload, ps);`), add:

```glsl
	rt_guide_features_surface(ps, brdf_mat, DLSSRR_computeDiffuseAlbedo(m.albedo, m.metalness), N, NdotV, specularF0);
```

`brdf_mat`, `NdotV` (about :1467) and `specularF0` (about :1786) are all in scope there; check each. The DLSS-RR `imageStore`s, the depth and velocity writes, and the spec-hit-distance query are not changed by any of this.

- [ ] **Step 5: Build, then run the gate three times**

```bash
cd $R && python -m SCons platform=windows target=editor > $W/build_task5.log 2>&1; tail -3 $W/build_task5.log
for i in 1 2 3; do $BIN --rendering-driver vulkan --path pipeline_references res://tests/pt_oidn_guide_passthrough_gate_scene.tscn > $W/t5g_post_$i.log 2>&1; echo "run $i exit=$?"; grep -aE "^PASS|^FAIL" $W/t5g_post_$i.log; done
```

The build must end with `scons: done building targets.` A clean build proves nothing about the GLSL (no glslang runs at build time). The first render compiles the shaders, so read the gate log for `SHADER` / `ERROR` lines before reading any number. All checks must pass in all three runs. If a check fails while the guides plainly look right, or a value sits within 10% of its threshold, STOP and report the numbers; do not move a threshold.

- [ ] **Step 6: Regressions: the gate suite, and DLSS-RR frame-identity**

(a) The full suite on the new build: `bash $W/run_suite.sh` (it overwrites `$W/suite/`; copy the old `$W/suite/summary.txt` to `$W/suite_pre5_summary.txt` first). Every gate that passed before must pass. `pt_oidn_guide_gate` G1-G3 must keep their values, because no pass-through or smooth surface is in its scene. If `pt_transmission_gate` probe 6 moves, run it on `$OLD` in the same session before suspecting the change (memory: probe 6 moves with the desktop session on every binary).

(b) DLSS-RR output unchanged: render `$IN/job301_12kf.json` in the default mode (no `ZR_VIDEO_DENOISER`), once with `$OLD` and once with `$BIN`, each into its own scratch project (`make_test_project.sh`), `--write-movie <dir>/movie.avi --fixed-fps 60 res://video_main.tscn -- <job> <out.mp4> <frame.png>`, one at a time. Compare `$FF -i movie.avi -f framemd5 -`, which must be identical. If not, run `$OLD` twice to measure the floor (memory: some builds are not run-to-run deterministic) before concluding anything, and report.

- [ ] **Step 7: Asset checks**

(a) The window, re-dumped on the new build: `bash $W/run_dump.sh post5`. In `$W/dump_post5/pfm`, measure the pane region x 1620-1820, y 720-880 (image y down; PFM rows are bottom-up). Unwritten fraction: `dump_base` 92.7% -> must be <= 1%. Write `$W/t5g/window_guides.png`: for each dump (`dump_base` on top, `dump_post5` below), the same 2x2 crop layout as `$W/dump_base/window_guides.png` (box (1560, 700)-(2160, 1100); colour and output as `clip(x * 2, 0, 1) ** (1 / 2.2)`, albedo as `clip(x, 0, 1) ** (1 / 2.2)`, normal as `x * 0.5 + 0.5`).

(b) The 1:1 window crop: box (1560, 700)-(2160, 1100) of `oidn_output.pfm`, through `dump_post5` and `dump_base` at the same display transform (`clip(x * 2, 0, 1) ** (1 / 2.2)`), side by side, plus `$W/t7/dlssrr_kf210.png`'s same crop. Save as `$W/t5g/window_crop_before_after_dlssrr.png`, labelled.

(c) Job 201 still at 1080p, old vs new, same command as `$W/step13d.sh`, once per binary: md5s; whole-frame linear-ish mean (8-bit PNG mean) ratio, which must be within 0.5%; and a diff heat-map `$W/t5g/job201_diff.png` (|new - old| x 8, clipped). The md5 is expected to change: job 201 has three windows.

- [ ] **Step 8: Spec "Measured", then commit**

Append a `## Measured (2026-10-04)` section to the spec: the gate's pre and post numbers (all three post runs), F6's status (check or informative), suite result, the DLSS-RR framemd5 result, the window unwritten fraction before/after, and the job 201 mean ratio, each with its file path. Then two commits, gate first:

```bash
git add pipeline_references/tests/pt_oidn_guide_passthrough_gate.gd pipeline_references/tests/pt_oidn_guide_passthrough_gate_scene.tscn
git commit -m "test(pt): OIDN guide pass-through gate -- red on the current build

Surfaces seen through an alpha pane write no OIDN guide (about 80% unwritten
behind an alpha-0.033 pane at 6 samples), and smooth glass writes its own flat
albedo. Spec 2026-10-04-oidn-guide-feature-passthrough-design.md.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git add servers/rendering/renderer_rd/shaders/raytracing/raytracing_inc.glsl servers/rendering/renderer_rd/shaders/raytracing/scene_raytracing_raygen.glsl servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl servers/rendering/renderer_rd/shaders/raytracing/raytracing_lights_inc.glsl docs/superpowers/specs/2026-10-04-oidn-guide-feature-passthrough-design.md
git commit -m "fix(pt): OIDN guides follow Cycles' denoising features through transparency and smooth specular

The guide write was gated on total_bounces == 0, and an alpha pass-through
counts as a bounce (inc_transmission_bounce), so the view through a window
pane reached OIDN as black and featureless. Each Phase A sample now carries
Cycles' pending-features flag and feature throughput: transparency passes them
through, a surface whose GGX alpha <= 0.075 and whose diffuse share is a
quarter or less defers them by its specular albedo, and the first other
surface or the sky writes them. DLSS-RR's G-buffers are unchanged.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

`git add` only the paths named. Never `-A`: `pipeline_references/.godot/` and the `.uid` files are untracked and stay that way.

- [ ] **Step 9: Clean up**

Delete `bin/godot_pre5.windows.editor.x86_64.exe` and `bin/godot_pre5.windows.editor.x86_64.console.exe`, the scratch projects, and the job-201 PNGs once their numbers are written. Keep logs, the `t5g/` images, and `dump_post5/` until Task 4's re-run has used it.
