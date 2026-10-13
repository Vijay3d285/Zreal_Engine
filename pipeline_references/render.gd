extends "res://image_glb_creation.gd"

# render.gd
# Main entry point for rendering. Handles arguments, camera, and rendering output.
var use_threejs = true
var convert_blender_camera = true
var _headless = OS.has_feature("headless") or OS.has_feature("server")
var _render_data = {}
var _has_fixture_lights_cache: bool = false
var _has_authored_lights_cache: bool = false

# zlib deflate level for the 16-bit still PNG. 0 = "store", which is what Blender's
# "Compression 0%" writes. 16-bit data barely compresses at any level anyway (the low
# byte of each channel is near-random), so the levels above cost time and save little.
const PNG16_COMPRESSION: int = 0
# Write the still as RGBA rather than RGB, matching Blender's default PNG layout
# (its output format defaults to RGBA planes, so format_png.cc always emits
# PNG_COLOR_TYPE_RGB_ALPHA). Three things to know before reading anything into it:
#   1. The alpha is 1.0 at every pixel. Blender's alpha is Cycles' film
#      transparency (film_write_transparent, PATH_RAY_TRANSPARENT_BACKGROUND),
#      which only runs with Film > Transparent on. A Blender still rendered with
#      it off -- blender_renders/blender_dining.png -- measures one distinct
#      alpha value across all 8.3 M pixels. Ours has no film-transparent mode,
#      so ours is the same constant channel.
#   2. It costs 16.6 MB per 4K file (66.4 MB vs 49.8 MB, both stored at level 0);
#      the entire size difference to Blender's file is this fourth channel.
#   3. It changes no RGB byte. The channel is added after shading, by
#      Image.convert(FORMAT_RGBAH), and the engine writer never sRGB-encodes it.
#      It has no effect on how glass or anything else renders.
# It exists for parity with Blender's file layout and for downstream tools that
# expect four channels. See docs/superpowers/specs/2026-09-13-png16-rgba-output-design.md.
const PNG16_WRITE_ALPHA: bool = true

func _ready():
	print("Godot Renderer Started (Split Architecture)")
	
	var args = OS.get_cmdline_args()
	if OS.has_method("get_cmdline_user_args"):
		args.append_array(OS.get_cmdline_user_args())
	
	var input_json_path = ""
	var output_path = ""
	
	for i in range(args.size()):
		var arg = args[i]
		if arg.ends_with(".json"):
			input_json_path = arg
		elif arg.ends_with(".png") or arg.ends_with(".jpg") or arg.ends_with(".mp4") or arg == "video_output":
			output_path = arg
			
	if (input_json_path == "" or output_path == "") and args.size() >= 2:
		input_json_path = args[args.size() - 2]
		output_path = args[args.size() - 1]
	
	if input_json_path == "" or output_path == "":
		print("Error: Missing arguments.")
		get_tree().quit(1)
		return

	print("Input JSON: ", input_json_path)
	print("Output Path: ", output_path)
	
	if not FileAccess.file_exists(input_json_path):
		print("Error: Input file does not exist.")
		get_tree().quit(1)
		return
		
	var json_text = FileAccess.get_file_as_string(input_json_path)
	var json = JSON.new()
	var error = json.parse(json_text)
	if error != OK:
		print("Error parsing JSON: ", json.get_error_message())
		get_tree().quit(1)
		return
		
	var data = json.data
	_render_data = data
	_image_render_only = not _should_render_video(data)
	_has_fixture_lights_cache = _has_fixture_lights(data)
	_has_authored_lights_cache = _has_authored_lights(data)
	
	set_resolution(data)
	build_scene(data) # From image_glb_creation.gd
	setup_camera(data)
	
	if _should_render_video(data):
		call_deferred("render_video", data, output_path)
	else:
		call_deferred("render_image", data, output_path)


func _should_render_video(data) -> bool:
	if not data.has("video_animation"):
		return false
	var anim_data = data["video_animation"]
	return typeof(anim_data) == TYPE_DICTIONARY and not anim_data.is_empty()

func set_resolution(data):
	var w = 1920
	var h = 1080
	
	if data.has("render_quality"):
		var quality = str(data["render_quality"]).to_upper().strip_edges()
		if quality == "12K":
			w = 12288
			h = 6642
		elif quality == "8K":
			w = 7680
			h = 4320
		elif quality == "6K":
			w = 6144
			h = 3321
		elif quality == "4K":
			w = 3840
			h = 2160
		elif quality == "2K":
			w = 2560
			h = 1440
		elif quality == "QUAD HD":
			w = 2048
			h = 1080
		elif quality == "1080P" or quality == "FHD" or quality == "FULL HD":
			w = 1920
			h = 1080
		elif quality == "HD":
			w = 1280
			h = 720

	if data.has("width"): w = int(data["width"])
	if data.has("height"): h = int(data["height"])

	var aspect_ratio_text = str(data.get("aspect_ratio", "16:9")).strip_edges()
	var aspect_ratio = _parse_aspect_ratio(aspect_ratio_text)
	if aspect_ratio > 0.0 and abs(aspect_ratio - (float(w) / float(max(h, 1)))) > 0.001:
		var base_long_side = max(w, h)
		if aspect_ratio >= 1.0:
			w = base_long_side
			h = int(round(float(base_long_side) / aspect_ratio))
		else:
			h = base_long_side
			w = int(round(float(base_long_side) * aspect_ratio))
		w = max(w, 1)
		h = max(h, 1)

	_apply_render_resolution(w, h)

	# MSAA must be DISABLED when Path Tracing is active.
	# With PT + MSAA_8X, transparent objects (glass, alpha materials) are rasterized
	# into RB_TEX_COLOR_MSAA, but the MSAA resolve is skipped by the engine because RT
	# already wrote the final color to internal_texture
	# (render_forward_clustered.cpp:2757 — `if (!scene_features.rt)`).
	# The MSAA buffer is never resolved → glass/transparency silently disappears.
	# PT fires rays per pixel at native resolution, so MSAA provides no quality benefit.
	# DLSS RR handles denoising + sub-pixel reconstruction instead.
	get_viewport().msaa_3d = Viewport.MSAA_DISABLED
	get_viewport().screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	get_viewport().use_taa = false # DLSS RR handles temporal stability; TAA auto-disabled anyway
	# ── 16-bit output requires an HDR framebuffer ─────────────────────────────
	# The engine's save_png16() writer is worthless on its own: without this the
	# render target stays RGBA8, get_image() returns FORMAT_RGB8, and the 16-bit
	# writer faithfully stores 256 distinct levels padded out to 16 bits — a 50 MB
	# file carrying 8 bits of information. The precision must exist BEFORE the save.
	#
	# use_hdr_2d makes the render target R16G16B16A16_SFLOAT
	# (texture_storage.cpp, render_target_get_color_format).
	#
	# Stills only: video frames are encoded to mp4 downstream, which throws the extra
	# precision away, so that path stays on the 8-bit pipeline it was tuned for.
	var want_hdr_output: bool = _image_render_only
	get_viewport().use_hdr_2d = want_hdr_output

	# Debanding is dither that exists ONLY to mask 8-bit quantisation banding. At 16
	# bits there is no banding to mask, so it would only inject noise — which also
	# inflates the PNG, making the file size look better while the image looks worse.
	get_viewport().use_debanding = not want_hdr_output
	print("[Render] HDR 2D framebuffer: %s (16-bit PNG output: %s, debanding: %s)" %
			[want_hdr_output, want_hdr_output, not want_hdr_output])
	get_viewport().mesh_lod_threshold = 0.0

	# ── DLSS scaling mode: required for Ray Reconstruction to execute ──────────
	# The DLSS-RR denoiser only runs inside the SCALE_DLSS code path in the
	# renderer (render_forward_clustered.cpp:2834). Without this, set_pathtracing_denoiser(1)
	# allocates the G-buffers but the slEvaluateFeature call is never reached.
	# scale = 1.0 → no resolution change, pure denoising pass only.
	get_viewport().scaling_3d_mode = Viewport.SCALING_3D_MODE_DLSS
	get_viewport().scaling_3d_scale = 1.0
	# NO SHARPENER ON A STILL. Godot's Viewport default fsr_sharpness is 0.2, and
	# the DLSS effect runs an NIS sharpen pass at fsr_sharpness / 2 on its output
	# (servers/rendering/renderer_rd/effects/dlss.cpp, "NIS support"). On job 217
	# it doubled the number of hard one-pixel steps along edges (270 vs 124 with
	# it off). Phase A never enters the DLSS branch, but the default would bite
	# the moment the realtime route is switched back on, so it is zeroed here.
	get_viewport().fsr_sharpness = 0.0
	print("[Render] DLSS viewport mode enabled for Ray Reconstruction denoising.")


func _apply_render_resolution(w: int, h: int) -> void:
	var size = Vector2i(max(w, 1), max(h, 1))
	print("Setting Resolution to: ", size.x, "x", size.y)
	get_viewport().size = size
	DisplayServer.window_set_size(size)
	var window = get_window()
	if window:
		window.size = size
		window.content_scale_size = size

func _parse_aspect_ratio(aspect_ratio_text: String) -> float:
	var cleaned = aspect_ratio_text.strip_edges()
	if cleaned == "":
		return -1.0
	if cleaned.find(":") != -1:
		var parts = cleaned.split(":")
		if parts.size() == 2:
			var numerator = float(str(parts[0]).strip_edges())
			var denominator = float(str(parts[1]).strip_edges())
			if numerator > 0.0 and denominator > 0.0:
				return numerator / denominator
		return -1.0
	if cleaned.find("/") != -1:
		var ratio_parts = cleaned.split("/")
		if ratio_parts.size() == 2:
			var numerator2 = float(str(ratio_parts[0]).strip_edges())
			var denominator2 = float(str(ratio_parts[1]).strip_edges())
			if numerator2 > 0.0 and denominator2 > 0.0:
				return numerator2 / denominator2
		return -1.0
	var numeric_ratio = float(cleaned)
	if numeric_ratio > 0.0:
		return numeric_ratio
	return -1.0

func setup_camera(data):
	var cam = Camera3D.new()
	cam.name = "MainCamera"
	var pos = Vector3(0, 1.5, 5)
	var target = Vector3(0, 1.0, 0)
	var need_look_at = false
	var has_view_target = false
	var use_plan_transform = abs(_scene_plan_rotation_radians) > 0.000001

	var prefer_threejs = data.get("use_threejs", use_threejs)

	var cam_data = {}
	if prefer_threejs and data.has("threejs_camera"):
		cam_data = data["threejs_camera"]
		if cam_data.has("position"):
			var p = cam_data["position"]
			pos = Vector3(float(p["x"]), float(p["y"]), float(p["z"]))
			if use_plan_transform:
				pos = _transform_plan_point_meters(pos)

		cam.position = pos

		if cam_data.has("target"):
			var t = cam_data["target"]
			target = Vector3(float(t["x"]), float(t["y"]), float(t["z"]))
			if use_plan_transform:
				target = _transform_plan_point_meters(target)
			has_view_target = true
			if not cam_data.has("rotation"):
				need_look_at = true
		if cam_data.has("rotation"):
			var r = cam_data["rotation"]
			var rot_v = Vector3(float(r["x"]), float(r["y"]), float(r["z"]))
			cam.basis = Basis.from_euler(rot_v, EULER_ORDER_XYZ)
		elif has_view_target:
			need_look_at = true

	elif data.has("blender_camera"):
		cam_data = data["blender_camera"]
		var should_convert = data.get("convert_blender_camera", convert_blender_camera)

		if cam_data.has("location"):
			var loc = cam_data["location"]
			if should_convert:
				pos = Vector3(loc[0], loc[2], -loc[1])
			else:
				pos = Vector3(loc[0], loc[1], loc[2])
			if use_plan_transform:
				pos = _transform_plan_point_meters(pos)

		cam.position = pos

		if data.has("blender_target") and data["blender_target"].has("location"):
			var t_loc = data["blender_target"]["location"]
			if should_convert:
				target = Vector3(t_loc[0], t_loc[2], -t_loc[1])
			else:
				target = Vector3(t_loc[0], t_loc[1], t_loc[2])
			if use_plan_transform:
				target = _transform_plan_point_meters(target)
			has_view_target = true
			if not cam_data.has("rotation_euler"):
				need_look_at = true
		elif cam_data.has("rotation_euler"):
			var r = cam_data["rotation_euler"]
			var rot_v = Vector3(float(r[0]), float(r[1]), float(r[2]))
			if should_convert:
				var b_basis = Basis.from_euler(rot_v, EULER_ORDER_XYZ)
				var godot_basis = Basis()
				godot_basis.x = Vector3(b_basis.x.x, b_basis.x.z, -b_basis.x.y)
				godot_basis.y = Vector3(b_basis.z.x, b_basis.z.z, -b_basis.z.y)
				godot_basis.z = Vector3(-b_basis.y.x, -b_basis.y.z, b_basis.y.y)
				cam.basis = godot_basis
			else:
				cam.basis = Basis.from_euler(rot_v, EULER_ORDER_XYZ)

	if cam_data.has("fov"):
		cam.fov = float(cam_data["fov"])

	add_child(cam)

	# ── UnrealPostFX Compositor Effect ────────────────────────────────────────
	# Attach after add_child() so the camera is already in the scene tree.
	# CompositorEffect requires Forward+ renderer (Godot 4.3+). We guard with
	# ClassDB so this script doesn't crash on compatibility renderer builds.
	# Day-render only: night renders keep their current (no post-fx) look untouched.
	if USE_POST_FX and day_render:
		# Compositor is a native C++ class (Godot 4.3+) — ClassDB check is correct here.
		# UnrealPostFX is a GDScript class: ClassDB never sees it, so we load by path instead.
		if ClassDB.class_exists("Compositor"):
			var post_fx_script = load("res://compositor_effect.gd")
			if post_fx_script:
				var comp := Compositor.new()
				var post_fx = post_fx_script.new()
				
				# Cinematic Tuning — Night and Warm Night Renders
				if not day_render:
					var is_warm_night = (str(_lighting_color_mood).to_lower() == "warm")
					post_fx.tonemap_mode = 1 # AgX — handles warm highlights gracefully
					post_fx.contrast = 1.20
					if is_warm_night:
						# Warm night: amber CDL push, softer shadows, richer saturation
						post_fx.exposure = 1.65 # brighter to reveal warm corners
						post_fx.saturation = 1.05 # richer warmth without oversaturation
						post_fx.lift = Color(0.06, 0.02, -0.01) # amber shadow lift
						post_fx.gain = Color(1.28, 1.08, 0.82) # warm highlight push
						post_fx.gamma_grade = Color(1.04, 0.98, 0.94) # amber midtone bias
						post_fx.vignette_strength = 0.52 # softer vignette: corners stay visible
						post_fx.chromatic_aberration = 0.0008 # subtle lens warmth
						print("  [PostFX] Applied Warm-Night CDL (amber lift, golden gain, AgX)")
					else:
						post_fx.exposure = 1.5
						post_fx.saturation = 0.85
						post_fx.lift = Color(0.02, 0.01, 0.05)
						post_fx.gain = Color(1.2, 1.1, 0.9)
						post_fx.vignette_strength = 0.6
						post_fx.chromatic_aberration = 0.001
						print("  [PostFX] Applied Night S-Curve tuning (AgX, Contrast 1.20)")
				# CHANGE 8: Day render warm golden CDL — this is the key to Render 2's look.
				# Lifts shadows to warm amber, pushes highlights to golden, subtle vignette.
				elif day_render:
					post_fx.tonemap_mode = 1 # AGX
					post_fx.exposure = 1.05
					post_fx.contrast = 1.12
					post_fx.saturation = 1.08 # slightly richer for warm interior
					post_fx.lift = Color(0.02, 0.01, -0.01) # warm shadow lift
					post_fx.gain = Color(1.10, 1.02, 0.88) # golden highlight push
					post_fx.gamma_grade = Color(1.02, 0.99, 0.96) # warm midtone bias
					post_fx.vignette_strength = 0.28 # subtle — Render 2 has mild vignette
					post_fx.chromatic_aberration = 0.0003 # barely perceptible lens depth
					print("  [PostFX] Applied Day-Sun CDL (ACES, warm golden gain)")
				elif str(_lighting_color_mood).to_lower() == "warm":
					# Day-warm: subtle amber grade without dramatic night look
					post_fx.tonemap_mode = 1 # AgX
					post_fx.exposure = 1.0
					post_fx.contrast = 1.15
					post_fx.saturation = 1.12
					post_fx.lift = Color(0.03, 0.01, -0.01)
					post_fx.gain = Color(1.12, 1.04, 0.90)
					post_fx.vignette_strength = 0.35
					post_fx.chromatic_aberration = 0.0005
					print("  [PostFX] Applied Day-Warm CDL tuning (AgX, amber grade)")

				comp.compositor_effects = [post_fx]
				cam.compositor = comp
				print("  [PostFX] UnrealPostFX compositor attached to MainCamera")
			else:
				print("  [PostFX] WARNING: compositor_effect.gd not found at res:// — post-fx skipped.")
		else:
			print("  [PostFX] WARNING: Compositor class unavailable — requires Forward+ renderer and Godot 4.3+.")

	if need_look_at:
		if cam.global_position.distance_to(target) > 0.001:
			cam.look_at(target, Vector3.UP)

func render_image(data, output_path):
	print("Rendering Single Image...")
	await _wait_frames(2)
	var cam = get_node_or_null("MainCamera")
	var env = _get_world_environment()
	var accumulate_enabled = env != null and env.environment != null and env.environment.pathtracing_accumulate
	var accum_target = env.environment.pathtracing_accumulation_target if accumulate_enabled else 0
	var oidn_enabled = env != null and env.environment != null and env.environment.pathtracing_oidn_denoise
	# DLSS-RR "reconstruct final" (Phase F2): a neural *reconstructive* final pass on the
	# converged accumulator (1:1 DLAA, warmed up over several frames). Mutually exclusive
	# with OIDN — the C++ render path prefers DLSS-RR-final when both are set.
	var dlss_rr_final_enabled = env != null and env.environment != null and env.environment.pathtracing_dlss_rr_final
	# DLSS-RR REALTIME STILL path (the intended high-quality still route): accumulate OFF +
	# denoiser=DLSS Ray Reconstruction (1) + Viewport.SCALING_3D_MODE_DLSS @ scale 1.0 (DLAA).
	# DLSS-RR is a NEURAL TEMPORAL denoiser — it cleans noise by accumulating info across frames
	# on the raw 1-SPP noisy input (per RenderingServer docs, "low sample count is sufficient
	# since the denoiser accumulates information across frames"). So we drive enough frames for
	# that temporal accumulation to converge to a clean, detail-reconstructed still, then capture.
	# Feeding DLSS-RR the converged image instead gives it nothing to accumulate (Phase F2 dead end).
	var dlss_rr_realtime = env != null and env.environment != null and not env.environment.pathtracing_accumulate and env.environment.pathtracing_denoiser == 1
	# Number of driver frames to let the realtime DLSS-RR temporal accumulator converge for a still.
	# 256 (~256 effective samples via temporal integration) gives a clean result; bump to 512 for hero.
	#
	# DO NOT REACH FOR THIS FIRST WHEN A RENDER IS TOO SLOW. The per-pixel budget
	# is SPP x this count, and of the two, SPP is the one to cut: frames are what
	# DLSS-RR's temporal history integrates, so trimming them starves the denoiser
	# and costs more quality per second saved than trimming samples-per-frame.
	# SPP lives in image_glb_creation.gd (PT_SPP_DAY / PT_SPP_NIGHT, overridable
	# with ZR_PT_SPP) and was 20 — twenty times what this route's own "raw 1-SPP
	# noisy input" design called for.
	# 256 since 2026-09-12: PT_SPP_DAY/NIGHT were halved (image_glb_creation.gd,
	# roadmap Gap #25 -- the 8 s GPU watchdog) and the frame count doubled so the
	# total samples per pixel are exactly what they were. Per the note above,
	# more frames of fewer samples is the direction DLSS-RR prefers anyway.
	const DLSS_RR_REALTIME_STILL_FRAMES = 256
	# Number of warmup frames to feed DLSS-RR after convergence so its temporal history
	# locks onto the converged image (reset=true frame 1, reset=false after). Cheap — each
	# warmup frame re-blends the same converged image, letting the reconstructor settle.
	const DLSS_RR_WARMUP_FRAMES = 16
	# A final-denoise pass only runs on the converged accumulator, so it implies accumulate-on.
	# If the user enabled a final pass without accumulate, force accumulate on so the
	# running-average accumulator converges and the final pass has something stable to work on.
	if (oidn_enabled or dlss_rr_final_enabled) and not accumulate_enabled:
		env.environment.pathtracing_accumulate = true
		accumulate_enabled = true
		accum_target = env.environment.pathtracing_accumulation_target

	# ── CRITICAL for Phase A: disable the temporal upscaler ────────────────────
	# SCALING_3D_MODE_DLSS is SCALING_3D_TYPE_TEMPORAL, so the viewport assigns a
	# jitter_phase_count (renderer_viewport.cpp) and the renderer bakes a per-frame
	# Halton jitter straight into the projection matrix
	# (render_scene_data_rd.cpp: correction.add_jitter_offset(taa_jitter)).
	#
	# The path tracer's raygen reads that SAME jittered projection and then applies
	# its own Blackman-Harris pixel filter on top. The two convolve, widening the
	# effective filter to roughly 1.5px and producing a soft image with ragged
	# edges — the offline route ends up blurrier than the realtime one it replaced.
	#
	# Phase A does its own anti-aliasing and its denoiser is 0, so nothing here
	# needs a temporal upscaler. Turn scaling off so our filter is the only one.
	# (DLSS-RR "reconstruct final" is the one exception: that pass genuinely runs
	# inside the SCALE_DLSS branch, so it keeps the DLSS viewport mode.)
	# BILINEAR is the non-scaling default on Viewport (there is no SCALING_3D_MODE_OFF
	# in the GDScript enum — that name belongs to the internal RenderingServer enum).
	# BILINEAR is a SPATIAL mode, so the viewport leaves jitter_phase_count at 0, and
	# at scale 1.0 render size equals target size, so no resampling happens either.
	# use_taa is already false above, which is the other thing that could add jitter.
	if accumulate_enabled and not dlss_rr_final_enabled:
		get_viewport().scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
		get_viewport().scaling_3d_scale = 1.0
		get_viewport().use_taa = false
		print("[PhaseA] Viewport scaling set to BILINEAR @1.0 (no temporal upscaler) — removes the projection jitter so it cannot double up with the path tracer's pixel filter.")

	if cam:
		if day_render:
			# Daylight design (spec 2026-09-19): no omni fill grid on day renders.
			# The room is sun + normalised sky + fixtures + portals; if the probe
			# below finds the darkest occupied quarter under the floor, ONE
			# measured DaylightFill is added. Night keeps its grid.
			print("[Daylight] fill grid skipped on day render (probe-exposed daylight).")
		else:
			setup_fixed_fill_lights()
		_apply_no_authored_light_boost()
		_apply_color_mood_to_scene()
		if day_render:
			if accumulate_enabled:
				await _daylight_probe_and_expose(env.environment)
				# Phase A: drive the path-tracer accumulator. Each process_frame
				# blends one 1-SPP sample into the running average, so waiting N
				# frames yields ~N effective samples (noise ~1/sqrt(N)). Give the
				# denoiser its warm-up too.
				# Phase F2: if DLSS-RR reconstruct-final is on, drive ~16 extra frames
				# past the target so the DLSS-RR one-shot dispatch (which fires in the C++
				# render path once accum_frame >= target) warms its temporal history and
				# produces the reconstructed frame before we grab the PNG. OIDN (Phase F)
				# only needs +1 (non-temporal, runs once).
				var final_frames = (DLSS_RR_WARMUP_FRAMES if dlss_rr_final_enabled else (1 if oidn_enabled else 0))
				var drive_frames = accum_target + final_frames
				var final_note = (" (+%d for DLSS-RR reconstruct warmup)" % DLSS_RR_WARMUP_FRAMES) if dlss_rr_final_enabled else (" (+1 for OIDN final-denoise)" if oidn_enabled else "")
				print("[Render] Accumulating %d frames for path-tracer convergence%s..." %
						[accum_target, final_note])
				await _wait_frames(drive_frames)
			else:
				# No Phase-A accumulator. If the realtime DLSS-RR denoiser is on it IS the
				# temporal accumulator — drive ~256 frames so its across-frame noise integration
				# converges to a clean reconstructed still, then capture. Otherwise just SDFGI warmup.
				printerr("[Daylight] the realtime route ships the normalised daylight at exposure 1.0 -- the probe only runs on the accumulate route")
				if dlss_rr_realtime:
					print("[Render] Driving %d frames of realtime DLSS Ray Reconstruction (1-SPP/frame temporal denoising) for still convergence..." % DLSS_RR_REALTIME_STILL_FRAMES)
					await _wait_frames(DLSS_RR_REALTIME_STILL_FRAMES)
				else:
					print("[Render] Waiting 80 frames for SDFGI and TAA warm-up...")
					await _wait_frames(80)
		else:
			# Night renders need more frames for SDFGI GI to converge and propagate
			# bounce light from spotlights up to the ceiling. 5 frames is too few.
			if accumulate_enabled:
				var final_frames_n = (DLSS_RR_WARMUP_FRAMES if dlss_rr_final_enabled else (1 if oidn_enabled else 0))
				var drive_frames_n = accum_target + final_frames_n
				var final_note_n = (" (+%d for DLSS-RR reconstruct warmup)" % DLSS_RR_WARMUP_FRAMES) if dlss_rr_final_enabled else (" (+1 for OIDN final-denoise)" if oidn_enabled else "")
				print("[Render] Accumulating %d frames for path-tracer convergence%s..." %
						[accum_target, final_note_n])
				await _wait_frames(drive_frames_n)
			else:
				# No Phase-A accumulator. Realtime DLSS-RR = temporal accumulator → drive still frames.
				if dlss_rr_realtime:
					print("[Render] Driving %d frames of realtime DLSS Ray Reconstruction (1-SPP/frame temporal denoising) for still convergence..." % DLSS_RR_REALTIME_STILL_FRAMES)
					await _wait_frames(DLSS_RR_REALTIME_STILL_FRAMES)
				else:
					await _wait_frames(40)

	var img = await _capture_viewport_image(6)

	# HARD FAIL if the image did not make it to disk.
	# Previously both failure paths below fell through to quit(0): the caller saw
	# a success exit code, then found no PNG, and the queue re-ran the entire 4K
	# trace up to MAX_RENDER_ATTEMPTS times — each attempt failing identically
	# with nothing in the log explaining why. An expensive silent loop.
	# The usual root cause is VRAM: the readback needs a full-resolution
	# allocation and a local LLM that was never unloaded is still holding the
	# card. Both zlendo_llm passes unload in a `finally`, so if this fires,
	# check for a stray `ollama ps` process first.
	if img == null:
		printerr("[Render] FATAL: viewport capture returned no image after 6 attempts.")
		printerr("[Render] FATAL: output would have been: %s" % output_path)
		printerr("[Render] FATAL: most likely out of VRAM for the full-resolution readback — ")
		printerr("[Render] FATAL: check that no LLM/Ollama model is still resident on the GPU.")
		save_logs(data, output_path)
		get_tree().quit(1)
		return

	# ── Write the still ───────────────────────────────────────────────────────
	# THE COLOUR-SPACE CONTRACT. renderer_scene_render_rd.cpp sets
	#     tonemap.convert_to_srgb = !using_hdr;
	# so with use_hdr_2d ON the RGBA16F buffer holds LINEAR values and the writer must
	# apply the sRGB OETF itself (srgb_encode = true). With it OFF the RGBA8 buffer is
	# already sRGB-encoded and plain save_png() is correct. Getting this backwards fails
	# silently: srgb_encode=false on the HDR path gives a very dark image, and
	# srgb_encode=true on an already-encoded buffer gives a washed-out double-encode.
	var _save_err: int = FAILED
	var _used_16bit: bool = false
	if get_viewport().use_hdr_2d and img.has_method("save_png16"):
		# The HDR readback is FORMAT_RGBH. Widening it to RGBAH makes the engine
		# writer emit PNG_COLOR_TYPE_RGB_ALPHA (it derives has_alpha from the
		# format); Godot's RGBH->RGBAH convert fills the new channel with 1.0.
		# Gated on == RGBH, not "lacks alpha": any other format here means the
		# readback changed upstream, and the writer should see it unmodified.
		if PNG16_WRITE_ALPHA and img.get_format() == Image.FORMAT_RGBH:
			img.convert(Image.FORMAT_RGBAH)
		var _png_layout := "RGBA" if img.get_format() == Image.FORMAT_RGBAH else "RGB"
		_save_err = img.call("save_png16", output_path, PNG16_COMPRESSION, true)
		_used_16bit = (_save_err == OK)
		if _used_16bit:
			print("[Render] Wrote 16-bit %s PNG (zlib level %d, sRGB-encoded from the linear HDR buffer)." % [_png_layout, PNG16_COMPRESSION])
		else:
			printerr("[Render] save_png16 failed with error %d — falling back to 8-bit." % _save_err)
	if not _used_16bit:
		# Either the binary predates save_png16, the HDR path is off, or the 16-bit
		# write failed. Either way the fallback must respect the same contract.
		var out_img: Image = img
		if get_viewport().use_hdr_2d:
			out_img = _linear_image_to_srgb8(out_img)
		_save_err = out_img.save_png(output_path)
	if _save_err != OK:
		printerr("[Render] FATAL: PNG save failed with error %d for: %s" % [_save_err, output_path])
		printerr("[Render] FATAL: check the directory exists and is writable, and that the disk is not full.")
		save_logs(data, output_path)
		get_tree().quit(1)
		return

	# save_png reported OK but the file is not there — rare, but it is the exact
	# symptom the caller sees, so name it here rather than letting the caller
	# rediscover it as a missing-file mystery.
	if not FileAccess.file_exists(output_path):
		printerr("[Render] FATAL: PNG save reported OK but no file exists at: %s" % output_path)
		save_logs(data, output_path)
		get_tree().quit(1)
		return

	print("Image saved to: ", output_path)
	_save_thumbnail_webp(img, output_path)
	if accumulate_enabled:
		# The .png above is the deliverable — it is the converged, anti-aliased,
		# tonemapped result, and it is lossless. It is now written 16-bit via
		# PNGDriverCommon::image_to_png16(), matching Blender's default still output;
		# the legacy image_to_png() path is 8-bit only.
		#
		# The linear EXR is an OPTIONAL extra for grading or for verifying that
		# highlights above 1.0 survived. It is off by default; set ZR_PT_EXR=1 to
		# emit it alongside the PNG.
		if OS.get_environment("ZR_PT_EXR") == "1":
			var exr_path: String = output_path.get_basename() + ".exr"
			var hdr: Image = RenderingServer.viewport_get_pathtracing_accum_image(
					get_viewport().get_viewport_rid())
			if hdr != null and not hdr.is_empty():
				var err: int = hdr.save_exr(exr_path, false)
				if err == OK:
					print("[Render] Linear HDR EXR saved to: ", exr_path)
				else:
					push_warning("[Render] EXR save failed (err %d): %s" % [err, exr_path])
			else:
				push_warning("[Render] Accumulator readback returned no image; EXR skipped.")
		var denoise_note := " with in-process OIDN final-denoise" if oidn_enabled else (" with DLSS-RR reconstruct-final" if dlss_rr_final_enabled else "")
		print("[Render] PHASE A accumulated still captured%s (PNG, tonemapped, converged)." % denoise_note)
	elif dlss_rr_realtime:
		print("[Render] Realtime DLSS-RR still captured (PNG, tonemapped) — %d-frame temporal accumulation." % DLSS_RR_REALTIME_STILL_FRAMES)

	save_logs(data, output_path)
	get_tree().quit(0)

func _get_world_environment():
	for child in get_children():
		if child is WorldEnvironment:
			return child
	return null

## Daylight design (spec 2026-09-19, sections 2-3). Measures the job's own
## frame and sets the exposure; adds one DaylightFill if the darkest occupied
## quarter is still under the floor. Leaves the accumulator reset so the
## still that follows starts from a cleared buffer.
func _daylight_probe_and_expose(p_env: Environment) -> void:
	var vp := get_viewport().get_viewport_rid()
	p_env.tonemap_exposure = 1.0
	var t0 := Time.get_ticks_msec()
	# ZR_DAYLIGHT_FLOOR: test-only override of Daylight.FLOOR so the fill
	# path (never exercised by any of the four measured jobs -- Measured
	# 2026-09-19, finding 8) can be forced on a real job without editing the
	# constant. solve_fill() compares against Daylight.FLOOR internally too,
	# so floor_v is threaded through to it below rather than only used here.
	var floor_v := Daylight.FLOOR
	var floor_override := OS.get_environment("ZR_DAYLIGHT_FLOOR")
	if floor_override != "":
		floor_v = float(floor_override)
		print("[Daylight] floor override ZR_DAYLIGHT_FLOOR=%s" % floor_override)
	var pr := await Daylight.probe(self, p_env, vp)
	if pr["samples"].is_empty():
		printerr("[Daylight] probe: accumulator readback returned nothing; exposure left at 1.0")
		await Daylight.reset_accumulator(self, p_env)
		return
	var st := Daylight.stats(pr["samples"])
	print("[Daylight] probe: median %.5f (occupied %.1f%%), exposure %.3f%s, p25 %.5f -> %.4f after exposure  [%d ms, %dx%d]" % [
			st["median"], 100.0 * st["occupied_fraction"], st["exposure"],
			" CLAMPED -- scene is not a lit interior" if st["clamped"] else "",
			st["p25"], st["p25"] * st["exposure"], Time.get_ticks_msec() - t0, pr["width"], pr["height"]])
	var exposure: float = st["exposure"]
	if st["p25"] * exposure < floor_v and not st["clamped"]:
		var fill := _place_daylight_fill(1.0)
		var pr1 := await Daylight.probe(self, p_env, vp)
		if pr1["samples"].is_empty() or pr1["samples"].size() != pr["samples"].size():
			printerr("[Daylight] fill probe: accumulator readback returned nothing; no fill")
			fill.queue_free()
		else:
			var sol := Daylight.solve_fill(pr["samples"], pr1["samples"], floor_v)
			if sol["needed"]:
				fill.light_energy = sol["energy"]
				exposure = sol["exposure"]
				print("[Daylight] fill: p25 %.4f < %.3f after exposure -> DaylightFill at %s size %s energy %.4f%s; exposure %.3f -> %.3f" % [
						st["p25"] * st["exposure"], floor_v, str(fill.global_position), str(fill.area_size),
						sol["energy"], " (CAPPED at share %.2f)" % Daylight.FILL_SHARE_CAP if sol["capped"] else "",
						st["exposure"], exposure])
			elif sol["exhausted"]:
				printerr("[Daylight] fill: solver exhausted (the fill moved neither the median nor the darkest quarter); no fill")
				fill.queue_free()
			else:
				fill.queue_free()
	# Exterior light levels: a small trim after the probe so exteriors sit a
	# little under the mid-grey target (softer, early-morning feel).
	if typeof(_render_data) == TYPE_DICTIONARY and typeof(_render_data.get("exterior_light", null)) == TYPE_DICTIONARY:
		var trim: float = clamp(float(_render_data["exterior_light"].get("exposure_scale", 1.0)), 0.3, 1.5)
		if abs(trim - 1.0) > 0.001:
			print("[Daylight] exterior exposure trim x%.2f: %.3f -> %.3f" % [trim, exposure, exposure * trim])
			exposure *= trim
	p_env.tonemap_exposure = exposure
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
	await Daylight.reset_accumulator(self, p_env)


## The fallback fill: centroid of the camera's room (or the lighting bounds'
## centre), 0.3 m below its ceiling, 0.6 x the room's extent, facing down,
## no shadows, normalised energy. Same rule as pt_daylight_gate.gd _add_fill().
func _place_daylight_fill(p_energy: float) -> AreaLight3D:
	# _extract_room_lighting_bounds() expects the parsed floor-plan geometry
	# dict (areas/vertices), not the raw job JSON. build_scene() resolves
	# that exact dict as `geom_data` and hands it to setup_lighting(data,
	# geom_data) -- see image_glb_creation.gd:458-488; it also stashes it
	# in the member `_floor_plan_root_data` at line 476, so that member IS
	# what setup_lighting receives. `_render_data.get("floor_plan_data", {})`
	# (the brief's suggestion) would instead be the RAW value, which per the
	# task brief can be a JSON string in some jobs -- a string fails the
	# Dictionary type check and silently falls back to the (0,0,0)/6x6/2.8
	# defaults. Reusing _floor_plan_root_data avoids that.
	var bounds := _extract_room_lighting_bounds(_floor_plan_root_data)
	var center: Vector3 = bounds["center"]
	var extent: Vector2 = bounds["extent"]
	var ceiling_y: float = bounds["ceiling_y"]
	var poly := _resolve_active_area_polygon()
	if poly.size() >= 3:
		var sum := Vector2.ZERO
		var mn := Vector2(1e9, 1e9)
		var mx := Vector2(-1e9, -1e9)
		for p in poly:
			sum += p
			mn = Vector2(minf(mn.x, p.x), minf(mn.y, p.y))
			mx = Vector2(maxf(mx.x, p.x), maxf(mx.y, p.y))
		var c := sum / float(poly.size())
		center = Vector3(c.x, center.y, c.y)
		extent = mx - mn
	var fill := AreaLight3D.new()
	fill.name = "DaylightFill"
	fill.area_size = extent * 0.6
	fill.area_normalize_energy = true
	fill.light_energy = p_energy
	fill.light_color = Color(1.0, 1.0, 1.0)
	fill.light_specular = 0.0
	fill.shadow_enabled = false
	fill.set_param(Light3D.PARAM_RANGE, 2.0 * extent.length() + 4.0)
	fill.set_param(Light3D.PARAM_ATTENUATION, 1.0)
	add_child(fill)
	fill.position = Vector3(center.x, ceiling_y - 0.3, center.z)
	fill.rotation_degrees = Vector3(-90.0, 0.0, 0.0) # -Z points down
	return fill

func _apply_color_mood_to_scene() -> void:
	var directional_tint = _get_color_mood_light_color("directional")
	var ambient_tint = _get_color_mood_light_color("ambient")
	var fill_tint = _get_color_mood_light_color("fill")
	var fixture_tint = _get_color_mood_light_color("fixture")

	for child in get_children():
		if child is WorldEnvironment:
			var world_env := child as WorldEnvironment
			if world_env.environment != null:
				world_env.environment.ambient_light_color = ambient_tint

	for node in _get_all_children_recursive(self):
		if node is DirectionalLight3D:
			# DAY RENDER: Do NOT override — sun color is hardcoded golden warm in setup_lighting().
			# Overriding here with day mood tint (near-white) was killing the golden sun color.
			if not day_render:
				(node as DirectionalLight3D).light_color = directional_tint
		elif node is SpotLight3D or node is OmniLight3D:
			if node.has_meta("authored_custom_light"):
				continue
			var n = node.name.to_lower()
			if "fixture" in n:
				(node as Light3D).light_color = fixture_tint
			else:
				(node as Light3D).light_color = fill_tint

func _get_all_children_recursive(node: Node) -> Array:
	var out: Array = []
	for child in node.get_children():
		out.append(child)
		out.append_array(_get_all_children_recursive(child))
	return out

func save_logs(input_data, output_image_path):
	print("Saving logs...")
	var project_root = ProjectSettings.globalize_path("res://")
	var parent_dir = project_root.get_base_dir()
	var logs_abs = parent_dir.path_join("logs")
	var input_abs = parent_dir.path_join("input_json")
	
	if not DirAccess.dir_exists_absolute(logs_abs):
		DirAccess.make_dir_recursive_absolute(logs_abs)
	if not DirAccess.dir_exists_absolute(input_abs):
		DirAccess.make_dir_recursive_absolute(input_abs)
		
	var timestamp = str(Time.get_unix_time_from_system())
	var output_basename = output_image_path.get_file().get_basename()
	
	var input_save_path = input_abs.path_join(output_basename + "_input.json")
	var json_string = JSON.stringify(input_data, "\t")
	var file_input = FileAccess.open(input_save_path, FileAccess.WRITE)
	if file_input:
		file_input.store_string(json_string)
		file_input.close()
		
	var log_data = {}
	log_data["timestamp"] = timestamp
	log_data["output_image"] = output_image_path
	
	var cam = get_node_or_null("MainCamera")
	if cam:
		log_data["camera_actual"] = {
			"position": {"x": cam.position.x, "y": cam.position.y, "z": cam.position.z},
			"fov": cam.fov
		}
	
	log_data["assets_used"] = _tracked_assets
	
	var log_path = logs_abs.path_join(output_basename + "_render_log.json")
	var log_json_str = JSON.stringify(log_data, "\t")
	var file_log = FileAccess.open(log_path, FileAccess.WRITE)
	if file_log:
		file_log.store_string(log_json_str)
		file_log.close()

func render_video(data, output_base_path):
	print("Rendering Video Sequence...")
	var anim_data = data["video_animation"]
	var fps = anim_data.get("fps", 30)
	var duration = anim_data.get("duration_seconds", 5.0)
	var total_frames = int(duration * fps)
	
	var cam = get_node_or_null("MainCamera")
	if not cam: return

	var start_pos = cam.position
	var end_pos = start_pos
	
	if anim_data.has("camera_position_start"):
		start_pos = parse_vec3(anim_data["camera_position_start"])
	if anim_data.has("camera_position_end"):
		end_pos = parse_vec3(anim_data["camera_position_end"])
		
	var base_filename = output_base_path.get_basename()
	var first_frame_saved = false
	
	setup_fixed_fill_lights() # Set up once for video
	_apply_no_authored_light_boost()
	_apply_color_mood_to_scene()
	
	for frame in range(total_frames):
		var t = float(frame) / float(total_frames - 1) if total_frames > 1 else 0.0
		cam.position = start_pos.lerp(end_pos, t)
		
		await _wait_frames(1)
		
		var img = await _capture_viewport_image(3)
		if img:
			var frame_filename = "%s_%04d.png" % [base_filename, frame]
			img.save_png(frame_filename)
			if not first_frame_saved:
				_save_thumbnail_webp(img, output_base_path)
				first_frame_saved = true
		
		if frame % 10 == 0:
			print("Rendered frame ", frame, "/", total_frames)
			
	get_tree().quit(0)

# Called ungated by render_video() and gated on night by render_image(): the video route keeps the day fill grid (spec 2026-09-19 section 4, "video route unchanged"); the still route has no fill grid on day renders.
func setup_fixed_fill_lights():
	# Unified room-based lighting logic (synced with video_render.gd)
	for l in get_tree().get_nodes_in_group("fill_lights"):
		l.queue_free()

	var illumination_scale = _lighting_illumination_scale
	if illumination_scale <= 0.0:
		illumination_scale = _resolve_illumination_scale(_render_data)

	# Dim automated room fills if manual light fixtures are already present
	var energy_multiplier = 1.0
	var fixture_count = get_tree().get_nodes_in_group("fixture_lights").size()
	if day_render:
		# Keep the room bright, but leave enough contrast for window-frame shadows to read.
		energy_multiplier = 1.25
		print("[Render] Day Render: Fill grid at 1.25x — preserving sunlight contrast and window shadows.")
	elif fixture_count > 0 or _has_fixture_lights_cache:
		energy_multiplier = 0.5
		if fixture_count > 0:
			print("[Render] %d fixture lights detected. Dimming automated room fill lights (0.5x)." % fixture_count)
		else:
			print("[Render] Fixture lights detected in cache. Dimming automated room fill lights (0.5x).")
	elif not _has_authored_lights_cache:
		energy_multiplier = 1.75
		print("[Render] No authored lights detected. Boosting automated room fill lights (1.75x).")

	var placed = 0
	# Declared at function scope: the summary print below sits outside the
	# `areas.size() > 0` block where the gating loop lives.
	var active_area_id := ""
	var skipped_areas := 0

	var areas = _get_floor_plan_areas()
	var verts = _get_floor_plan_vertices()
	
	var is_warm_fill = (str(_lighting_color_mood).to_lower() == "warm")
	var fill_color = Color(1.0, 0.87, 0.68) if is_warm_fill else Color(1.0, 0.92, 0.80)
	var floor_fill_color = Color(1.0, 0.82, 0.55) if is_warm_fill else Color(1.0, 0.88, 0.70)

	if areas.size() > 0 and verts.size() > 0:
		# For sunbeam detection
		var sun_dir_flat = Vector3.ZERO
		if day_render and _dir_light:
			sun_dir_flat = - _dir_light.global_transform.basis.z
			sun_dir_flat.y = 0
			if sun_dir_flat.length() > 0.001:
				sun_dir_flat = sun_dir_flat.normalized()
				
		# ── Active-room gating for area fill lights ───────────────────────────────
		# Every light placed in this loop has shadow_enabled = false, and in this
		# fork's path tracer a shadowless light traces NO occlusion ray at all
		# (raytracing_lights_inc.glsl: the shadow test is skipped entirely when
		# shadow_enabled == 0.0). So a fill light sitting in the Living Room does not
		# stop at the partition — it illuminates the bedroom through the wall at up to
		# its full 20 m range. With one light set per area, most of the fill landing in
		# any given frame was leaking in from rooms that are not even on camera.
		# Gating to the camera's room is what lets the surviving fills be tuned at a
		# sane energy instead of being crushed globally to suppress the leak.
		# Resolved via the same helper the portal gate uses, so the two can never
		# disagree about which room is active. Empty id (camera outside every area, i.e.
		# a facade/exterior view) leaves every area lit, exactly as before.
		active_area_id = str(_resolve_active_area().get("id", ""))

		for area_id in areas:
			if active_area_id != "" and str(area_id) != active_area_id:
				skipped_areas += 1
				continue
			var area = areas[area_id]
			var v_ids = area.get("vertices", [])
			if v_ids.size() < 3:
				continue

			# ── Area Polygon and Bounds ──
			var poly2d = PackedVector2Array()
			var min_x = 1e9; var max_x = -1e9
			var min_z = 1e9; var max_z = -1e9
			var sum_x = 0.0; var sum_z = 0.0
			var count = 0

			for v_id in v_ids:
				var vs = str(v_id)
				if not verts.has(vs):
					continue
				var v = verts[vs]
				var vx = float(v.get("x", 0)) * _scene_unit_scale
				var vz = float(v.get("y", 0)) * _scene_unit_scale
				poly2d.append(Vector2(vx, vz))
				min_x = min(min_x, vx); max_x = max(max_x, vx)
				min_z = min(min_z, vz); max_z = max(max_z, vz)
				sum_x += vx; sum_z += vz
				count += 1
			if count < 3:
				continue

			var cx = sum_x / float(count)
			var cz = sum_z / float(count)

			# ── Ceiling height for THIS room ──
			var ceil_h = 2.4 # default 240 cm → 2.4 m
			if area.has("ceiling_properties") and typeof(area["ceiling_properties"]) == TYPE_DICTIONARY:
				var cp = area["ceiling_properties"]
				if cp.has("height"):
					var ch = cp["height"]
					var hf = 0.0
					if typeof(ch) == TYPE_DICTIONARY and ch.has("length"):
						hf = float(ch["length"]) * _scene_unit_scale
					elif typeof(ch) == TYPE_INT or typeof(ch) == TYPE_FLOAT:
						hf = float(ch) * _scene_unit_scale
					elif typeof(ch) == TYPE_STRING and ch.is_valid_float():
						hf = float(ch) * _scene_unit_scale
					if hf > 0.5:
						ceil_h = hf
			elif area.has("properties") and typeof(area["properties"]) == TYPE_DICTIONARY:
				var h_prop = area["properties"].get("height", null)
				if h_prop != null:
					var hf = get_dimension_value(h_prop) * _scene_unit_scale
					if hf > 0.5: ceil_h = hf

			# Light hangs 30 cm below the ceiling — well inside the room
			var light_y = ceil_h - 0.30
			light_y = max(light_y, 1.4) # never lower than 1.4 m

			var room_w = max(max_x - min_x, 0.5)
			var room_d = max(max_z - min_z, 0.5)
			var diag = sqrt(room_w * room_w + room_d * room_d)

			if day_render:
				# ── Day Render: Dynamic Grid Fill Lighting ──
				var spacing = clamp(min(room_w, room_d) / 4.0, 1.2, 2.5)
				# Fill grid is the room's ambient fill — sun handles the primary drama.
				# Slightly softer fill keeps the daylight believable without flattening the sun patch.
				var grid_energy = clamp(0.28 + diag * 0.016, 0.28, 0.58) * energy_multiplier * illumination_scale
				
				var steps_x = int(ceil(room_w / spacing))
				var steps_z = int(ceil(room_d / spacing))
				
				for ix in range(steps_x + 1):
					for iz in range(steps_z + 1):
						var px = min_x + (ix * room_w / float(max(1, steps_x)))
						var pz = min_z + (iz * room_d / float(max(1, steps_z)))
						var p2d = Vector2(px, pz)
						
						if not Geometry2D.is_point_in_polygon(p2d, poly2d):
							continue
							
						# Check if in directional light passing area (sunbeam)
						var in_sunlight = false
						if sun_dir_flat.length() > 0.5:
							for win in _window_sunlight_data:
								var w_center = win["center"] as Vector3
								var vec_to_p = Vector3(px - w_center.x, 0, pz - w_center.z)
								var proj_len = vec_to_p.dot(sun_dir_flat)
								if proj_len > 0.0: # In front of window
									var proj_point = Vector3(w_center.x, 0, w_center.z) + sun_dir_flat * proj_len
									var lat_dist = Vector3(px, 0, pz).distance_to(proj_point)
									var win_width = 2.0
									if win.has("width"): win_width = win["width"]
									# Stricter culling: only cull if squarely inside the sunbeam
									if lat_dist < (win_width * 0.4) + (proj_len * 0.05):
										in_sunlight = true
										break
						
						if not in_sunlight:
							# SpotLight pointed DOWN — angle MUST be ≤60° or light bleeds back onto ceiling
							# 85° was nearly a hemisphere, creating bright hotspots on the ceiling surface
							# from each grid light directly above it.
							var light = SpotLight3D.new()
							light.name = "GridFill_%s_%d_%d" % [area_id, ix, iz]
							light.position = Vector3(px, ceil_h - 0.2, pz)
							light.rotation_degrees = Vector3(-90, 0, 0)
							light.spot_angle = 55.0 # Tight cone — only illuminates downward, no ceiling bleed
							light.spot_range = clamp(spacing * 3.5, 6.0, 12.0)
							light.light_energy = grid_energy
							light.shadow_enabled = false
							light.light_color = fill_color
							light.light_specular = 0.0
							light.add_to_group("fill_lights")
							add_child(light)
							placed += 1

				# GridFloorFill OmniLight: SKIP for day renders.
				# OmniLight at y=0.35 radiates in ALL directions including UP.
				# With omni_range up to 20m it creates a visible circular hotspot on the ceiling
				# which combined with adjacent grid SpotLights creates the wave/diamond pattern.
				# Day renders don't need this — the sun + grid SpotLights handle floor fill.
				if not day_render:
					var floor_fill = OmniLight3D.new()
					floor_fill.name = "GridFloorFill_" + str(area_id)
					floor_fill.position = Vector3(cx, 0.35, cz)
					floor_fill.light_energy = 0.35 * energy_multiplier * illumination_scale
					floor_fill.omni_range = clamp(diag + 3.0, 8.0, 20.0)
					floor_fill.shadow_enabled = false
					floor_fill.light_color = floor_fill_color
					floor_fill.light_specular = 0.1
					floor_fill.add_to_group("fill_lights")
					add_child(floor_fill)

			else:
				# ── Night / Legacy: Center SpotLight and OmniLight ──
				var omni_range = clamp(diag + 1.5, 6.0, 16.0)
				var energy = clamp(0.7 + diag * 0.10, 0.7, 1.6)

				var light = SpotLight3D.new()
				light.name = "RoomLight_" + str(area_id)
				light.position = Vector3(cx, light_y, cz) # ← fixed world position
				light.rotation_degrees = Vector3(-90, 0, 0)
				light.spot_angle = 85.0
				light.spot_range = omni_range
				light.light_energy = energy * energy_multiplier * illumination_scale
				light.shadow_enabled = false
				light.light_color = fill_color
				light.light_specular = 0.10 # small specular — points DOWN so hits floor, not ceiling
				light.add_to_group("fill_lights")
				add_child(light)
				placed += 1

				# ── Ceiling Ambient Fill (OmniLight at mid-room height) ──
				# Placed at mid-room height rather than near the ceiling so that
				# inverse-square falloff produces a smooth, even wash across the whole
				# ceiling surface instead of circular hotspot patches.
				# NOTE: deliberately ignores energy_multiplier so fixture-detection's
				# 0.5x halving does NOT starve the ceiling of light.
				var ceil_fill = OmniLight3D.new()
				ceil_fill.name = "CeilingCenterFill_" + str(area_id)
				# Mid-room height: far enough from the ceiling that the light fans out
				# evenly without creating a visible round hotspot.
				var ceil_fill_y = clamp(ceil_h * 0.55, 1.2, ceil_h - 0.6)
				ceil_fill.position = Vector3(cx, ceil_fill_y, cz)
				# Moderate energy — SDFGI + SSIL now carry most of the ceiling bounce,
				# this fill just ensures a clean base luminance floor on the ceiling.
				var ceil_energy_base = clamp(energy * 0.5 * illumination_scale, 0.72, 2.16)
				ceil_fill.light_energy = ceil_energy_base
				# Wide range to reach ceiling and corners uniformly
				ceil_fill.omni_range = clamp(diag * 1.6 + 3.0, 10.0, 25.0)
				ceil_fill.omni_attenuation = 1.5 # Gentler falloff for softer spread
				ceil_fill.shadow_enabled = false
				ceil_fill.light_color = fill_color
				ceil_fill.light_specular = 0.12 # soft floor gloss — mid-room height avoids ceiling hotspot
				ceil_fill.add_to_group("fill_lights")
				add_child(ceil_fill)
				
				# ── Corner fills at mid-room height — keep edges from going dark ──
				var corner_energy = ceil_energy_base * 0.45
				var corner_range = clamp(diag * 1.0 + 2.0, 6.0, 16.0)
				var corner_offsets = [
					Vector2(room_w * 0.35, room_d * 0.35),
					Vector2(-room_w * 0.35, room_d * 0.35),
					Vector2(room_w * 0.35, -room_d * 0.35),
					Vector2(-room_w * 0.35, -room_d * 0.35),
				]
				var ci = 0
				for co in corner_offsets:
					var cp2d = Vector2(cx + co.x, cz + co.y)
					if Geometry2D.is_point_in_polygon(cp2d, poly2d):
						var corner_fill = OmniLight3D.new()
						corner_fill.name = "CeilingCornerFill_%s_%d" % [area_id, ci]
						# Also at mid-room height — no hotspots on ceiling edges
						corner_fill.position = Vector3(cx + co.x, ceil_fill_y, cz + co.y)
						corner_fill.light_energy = corner_energy
						corner_fill.omni_range = corner_range
						corner_fill.omni_attenuation = 1.5
						corner_fill.shadow_enabled = false
						corner_fill.light_color = fill_color
						corner_fill.light_specular = 0.0
						corner_fill.add_to_group("fill_lights")
						add_child(corner_fill)
					ci += 1

				var floor_fill = OmniLight3D.new()
				floor_fill.name = "FloorFill_" + str(area_id)
				floor_fill.position = Vector3(cx, 0.35, cz) # near-floor height
				floor_fill.light_energy = energy * 0.25 * energy_multiplier * illumination_scale
				floor_fill.omni_range = clamp(omni_range * 0.7, 3.0, 10.0)
				floor_fill.shadow_enabled = false
				floor_fill.light_color = floor_fill_color
				floor_fill.light_specular = 0.35 # grazing-angle shimmer on polished marble/tile
				floor_fill.add_to_group("fill_lights")
				add_child(floor_fill)

	if placed == 0:
		print("[Render] No area data found — placing ceiling grid fallback lights.")
		var room_info = _extract_room_lighting_bounds(_render_data)
		var room_center: Vector3 = room_info.get("center", Vector3.ZERO)
		var room_extent: Vector2 = room_info.get("extent", Vector2(6.0, 6.0))
		var room_ceiling_y: float = float(room_info.get("ceiling_y", room_center.y + 2.8))
		_add_ceiling_fill_grid("RoomLight_FallbackCeiling", room_center, room_extent, room_ceiling_y, 2.35 * energy_multiplier, 24.0, fill_color)
		placed = 9
	
	if skipped_areas > 0:
		print("[Render] Room-gated fill: skipped %d area(s) the camera is not in (active='%s')." % [skipped_areas, active_area_id])
	print("[Render] Placed %d room light(s)." % placed)

func _apply_no_authored_light_boost() -> void:
	if day_render:
		# Day render is probe-exposed daylight with no fill grid (spec
		# 2026-09-19: setup_fixed_fill_lights() is not called on day renders
		# at all -- see the call site's day_render gate), so this legacy
		# no-authored-light boost, tuned for the fill grid, does not apply.
		print("[Render] Skipping legacy no-authored-light boost for Day Render.")
		return

	if _has_authored_lights_cache and not day_render:
		return

	var room_info = _extract_room_lighting_bounds(_render_data)
	var room_center: Vector3 = room_info.get("center", Vector3.ZERO)
	var room_extent: Vector2 = room_info.get("extent", Vector2(6.0, 6.0))
	var room_ceiling_y: float = float(room_info.get("ceiling_y", room_center.y + 2.8))
	var span = max(room_extent.x, room_extent.y)
	var fill_y = room_ceiling_y - 0.45
	var fill_tint = _get_color_mood_light_color("fill")
	var boost_energy = 3.2 if day_render else 2.2
	var side_energy = 2.0 if day_render else 1.2
	var floor_energy = 1.25 if day_render else 0.8

	var center_boost = SpotLight3D.new()
	center_boost.name = "RenderBoostCenterLight"
	center_boost.position = Vector3(room_center.x, fill_y, room_center.z)
	center_boost.rotation_degrees = Vector3(-90, 0, 0)
	center_boost.spot_angle = 85.0
	center_boost.spot_range = max(span * 2.6 + 8.0, 12.0)
	center_boost.light_energy = boost_energy * _lighting_illumination_scale
	center_boost.light_color = fill_tint
	center_boost.light_specular = 0.0
	center_boost.shadow_enabled = false
	center_boost.add_to_group("fill_lights")
	add_child(center_boost)

	var side_boost_left = SpotLight3D.new()
	side_boost_left.name = "RenderBoostLeftLight"
	side_boost_left.position = Vector3(room_center.x - span * 0.28, fill_y, room_center.z)
	side_boost_left.rotation_degrees = Vector3(-90, 0, 0)
	side_boost_left.spot_angle = 85.0
	side_boost_left.spot_range = max(span * 2.1 + 6.0, 10.0)
	side_boost_left.light_energy = side_energy * _lighting_illumination_scale
	side_boost_left.light_color = fill_tint
	side_boost_left.light_specular = 0.0
	side_boost_left.shadow_enabled = false
	side_boost_left.add_to_group("fill_lights")
	add_child(side_boost_left)

	var side_boost_right = SpotLight3D.new()
	side_boost_right.name = "RenderBoostRightLight"
	side_boost_right.position = Vector3(room_center.x + span * 0.28, fill_y, room_center.z)
	side_boost_right.rotation_degrees = Vector3(-90, 0, 0)
	side_boost_right.spot_angle = 85.0
	side_boost_right.spot_range = max(span * 2.1 + 6.0, 10.0)
	side_boost_right.light_energy = side_energy * _lighting_illumination_scale
	side_boost_right.light_color = fill_tint
	side_boost_right.light_specular = 0.0
	side_boost_right.shadow_enabled = false
	side_boost_right.add_to_group("fill_lights")
	add_child(side_boost_right)

	var floor_boost = OmniLight3D.new()
	floor_boost.name = "RenderBoostFloorLight"
	floor_boost.position = Vector3(room_center.x, max(room_center.y - 0.8, 0.35), room_center.z)
	floor_boost.light_energy = floor_energy * _lighting_illumination_scale
	floor_boost.omni_range = max(span * 1.9 + 5.0, 8.5)
	floor_boost.light_color = Color(
		fill_tint.r * 1.06,
		fill_tint.g * 0.99,
		fill_tint.b * 0.94
	)
	floor_boost.light_specular = 0.0
	floor_boost.shadow_enabled = false
	floor_boost.add_to_group("fill_lights")
	add_child(floor_boost)

	_add_ceiling_fill_grid("RenderBoostCeilingLight", room_center, room_extent, room_ceiling_y, 2.6 if day_render else 1.6, max(span * 2.0 + 9.0, 14.0), fill_tint)

	print("[Render] Applied additional no-authored-lights boost lighting.")

func _add_ceiling_fill_grid(prefix: String, room_center: Vector3, room_extent: Vector2, room_ceiling_y: float, energy: float, range: float, tint: Color) -> void:
	var ceiling_y = room_ceiling_y - 0.18
	var x_offsets = [-0.35, 0.0, 0.35]
	var z_offsets = [-0.32, 0.0, 0.32]
	var idx = 0
	for z_mul in z_offsets:
		for x_mul in x_offsets:
			var light = SpotLight3D.new()
			light.name = "%s_%d" % [prefix, idx]
			light.position = Vector3(
				room_center.x + room_extent.x * x_mul,
				ceiling_y,
				room_center.z + room_extent.y * z_mul
			)
			light.rotation_degrees = Vector3(-90, 0, 0)
			light.spot_angle = 85.0
			light.spot_range = range
			light.light_energy = energy * _lighting_illumination_scale
			light.light_color = tint
			light.light_specular = 0.0
			light.shadow_enabled = false
			light.add_to_group("fill_lights")
			add_child(light)
			idx += 1

func _get_floor_plan_areas() -> Dictionary:
	var src = _render_data
	if src.has("floor_plan_data"):
		var fp = src["floor_plan_data"]
		if typeof(fp) == TYPE_STRING:
			var j = JSON.new()
			if j.parse(fp) == OK: src = j.data
		elif typeof(fp) == TYPE_DICTIONARY:
			src = fp

	# Handle nested layers structure (from video_render.gd)
	if src.has("layers") and typeof(src["layers"]) == TYPE_DICTIONARY:
		var merged = {}
		for l_id in src["layers"]:
			var layer = src["layers"][l_id]
			if typeof(layer) == TYPE_DICTIONARY and layer.has("areas"):
				var raw_areas = layer["areas"]
				if typeof(raw_areas) == TYPE_DICTIONARY:
					for a_id in raw_areas:
						merged[str(a_id)] = raw_areas[a_id]
				elif typeof(raw_areas) == TYPE_ARRAY:
					for a in raw_areas:
						if typeof(a) == TYPE_DICTIONARY and a.has("id"):
							merged[str(a["id"])] = a
		return merged
	
	var raw = src.get("areas", null)
	if raw == null: return {}
	if typeof(raw) == TYPE_DICTIONARY: return raw
	# Array format fallback
	var d = {}
	for a in raw:
		if typeof(a) == TYPE_DICTIONARY and a.has("id"):
			d[str(a["id"])] = a
	return d

func _get_floor_plan_vertices() -> Dictionary:
	var src = _render_data
	if src.has("floor_plan_data"):
		var fp = src["floor_plan_data"]
		if typeof(fp) == TYPE_STRING:
			var j = JSON.new()
			if j.parse(fp) == OK: src = j.data
		elif typeof(fp) == TYPE_DICTIONARY:
			src = fp

	# Handle nested layers structure (from video_render.gd)
	if src.has("layers") and typeof(src["layers"]) == TYPE_DICTIONARY:
		var merged = {}
		for l_id in src["layers"]:
			var layer = src["layers"][l_id]
			if typeof(layer) == TYPE_DICTIONARY and layer.has("vertices"):
				var raw_verts = layer["vertices"]
				if typeof(raw_verts) == TYPE_DICTIONARY:
					for v_id in raw_verts:
						merged[str(v_id)] = raw_verts[v_id]
				elif typeof(raw_verts) == TYPE_ARRAY:
					for v in raw_verts:
						if typeof(v) == TYPE_DICTIONARY and v.has("id"):
							merged[str(v["id"])] = v
		return merged
	
	var raw = src.get("vertices", null)
	if raw == null: return {}
	if typeof(raw) == TYPE_DICTIONARY: return raw
	# Array format fallback
	var d = {}
	for v in raw:
		if typeof(v) == TYPE_DICTIONARY and v.has("id"):
			d[str(v["id"])] = v
	return d

func get_cardinal_direction(dir: Vector3) -> String:
	var flat_dir = Vector2(dir.x, dir.z).normalized()
	var deg = rad_to_deg(flat_dir.angle())
	if deg >= -22.5 and deg < 22.5: return "East"
	if deg >= 22.5 and deg < 67.5: return "South-East"
	if deg >= 67.5 and deg < 112.5: return "South"
	if deg >= 112.5 and deg < 157.5: return "South-West"
	if deg >= 157.5 or deg < -157.5: return "West"
	if deg >= -157.5 and deg < -112.5: return "North-West"
	if deg >= -112.5 and deg < -67.5: return "North"
	if deg >= -67.5 and deg < -22.5: return "North-East"
	return "Unknown"

# Convert a LINEAR image (an HDR use_hdr_2d viewport readback) to an sRGB-encoded
# RGB8 image. Returns non-linear inputs unchanged.
#
# Image.convert(FORMAT_RGB8) is a raw clamp with NO sRGB encode, so a linear buffer
# put through it comes out badly darkened. Image.linear_to_srgb() does apply the
# transfer function, but it requires RGB8/RGBA8 input and uses a 256-entry LUT — it
# has to quantise first and is badly wrong in the darks (the LUT jumps 0 -> 12).
#
# Preferred route: encode to a 16-bit PNG in memory, where the C++ writer applies the
# exact OETF to full-precision floats, then load it straight back. The PNG *loader*
# masks out PNG_FORMAT_FLAG_LINEAR, so libpng does the 16 -> 8 down-convert natively.
func _linear_image_to_srgb8(source: Image) -> Image:
	if source == null or source.is_empty():
		return source
	var fmt: int = source.get_format()
	var is_linear_float: bool = fmt in [
		Image.FORMAT_RF, Image.FORMAT_RGF, Image.FORMAT_RGBF, Image.FORMAT_RGBAF,
		Image.FORMAT_RH, Image.FORMAT_RGH, Image.FORMAT_RGBH, Image.FORMAT_RGBAH,
		Image.FORMAT_RGBE9995,
	]
	if not is_linear_float:
		return source

	if source.has_method("save_png16_to_buffer"):
		var buf: PackedByteArray = source.call("save_png16_to_buffer", PNG16_COMPRESSION, true)
		if buf.size() > 0:
			var decoded := Image.new()
			if decoded.load_png_from_buffer(buf) == OK and not decoded.is_empty():
				return decoded

	# Fallback for a binary without the 16-bit writer: quantise, then use the
	# engine's LUT-based conversion. Approximate, but not darkened.
	var work: Image = source.duplicate() as Image
	work.convert(Image.FORMAT_RGB8)
	work.linear_to_srgb()
	return work

func _save_thumbnail_webp(source_image: Image, output_path: String) -> void:
	if source_image == null or source_image.is_empty(): return
	var thumb_path = output_path.get_base_dir().path_join(output_path.get_file().get_basename() + "_thumb.webp")
	var thumb: Image = source_image.duplicate() as Image
	var max_dim = 480
	var w = thumb.get_width(); var h = thumb.get_height()
	if w > max_dim or h > max_dim:
		if w >= h: thumb.resize(max_dim, int(float(h) * max_dim / w), Image.INTERPOLATE_LANCZOS)
		else: thumb.resize(int(float(w) * max_dim / h), max_dim, Image.INTERPOLATE_LANCZOS)
	# Downsample BEFORE the colour conversion. The still path hands us a LINEAR RGBH
	# readback, which Image.resize() handles natively (only RGB565/RGBA4444/RGBE9995
	# need converting first), so the Lanczos filter runs in linear light — which is
	# where averaging is actually correct — and the sRGB encode then runs on 480px
	# instead of on 8.3 M. save_webp needs 8-bit anyway, and feeding it the linear
	# buffer directly would come out badly darkened. No-op on the 8-bit video path.
	thumb = _linear_image_to_srgb8(thumb)
	thumb.save_webp(thumb_path, true, 0.75)

func _wait_frames(count: int) -> void:
	for i in range(count): await get_tree().process_frame

func _capture_viewport_image(retries: int = 3):
	var vp = get_viewport()
	for i in range(max(1, retries)):
		RenderingServer.force_draw()
		await get_tree().process_frame
		var tex = vp.get_texture()
		if tex:
			var img = tex.get_image()
			if img and not img.is_empty(): return img
		await get_tree().process_frame
	return null
