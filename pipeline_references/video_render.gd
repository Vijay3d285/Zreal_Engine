extends "res://video_glb_creation.gd"

# video_render.gd
# Fast video renderer using Godot's built-in MovieWriter (--write-movie).
# Instead of manually saving PNGs, this script advances the camera each frame
# in _process() and MovieWriter captures every frame automatically.

var use_threejs = true
var convert_blender_camera = true

# Video state
var _keyframes = []
var _current_frame: int = 0
var _total_frames: int = 0
var _fps: int = 30
var _base_filename: String = ""
var _rendering: bool = false
var _scene_ready: bool = false
var _warmup_frames: int = 0
var _use_movie_writer: bool = false
var _use_png_fallback: bool = false
var _needs_auto_pan: bool = false
# DLSS priming: extra frames at frame-0 position so DLSS RR builds temporal
# history before the real timeline starts. These get trimmed by ffmpeg.
const DLSS_PRIME_FRAMES: int = 5
var _dlss_prime_remaining: int = 0
# Wall clock at the first DELIVERED frame, for the budget projection in _process().
var _sequence_t0: int = 0
# Wall clock at the end of the budget warm-up window (see BUDGET_WARMUP_FRAMES).
var _budget_t_warm: int = 0

# Daylight exposure (spec 2026-09-19, ported from render.gd :: _daylight_probe_and_expose).
# Physical daylight is dim in absolute terms (a real still needed 24.7x), so the sky-normalised,
# physical-sun scene is unusable without a MEASURED exposure. A per-frame probe would make the
# exposure move from frame to frame, which is flicker -- far worse than a slightly-off exposure --
# so the probe runs ONCE, before DLSS priming, at DAYLIGHT_PROBE_POSITIONS camera positions spread
# along the path (first / middle / last keyframe), the raw luminance samples are POOLED, and
# Daylight.stats() is called once on the pooled array. That single exposure is then held for the
# whole sequence.
# The probe runs in an offscreen SubViewport (see _run_daylight_probe), so none of its frames reach
# the viewport MovieWriter records.
const DAYLIGHT_PROBE_POSITIONS: int = 3
# The probe's SubViewport is at most this wide (its height follows the recorded viewport's aspect).
# The probe reads 4x4 box averages (Daylight.PROBE_STEP), so it does not need the output's pixel
# count; the exposure it measures is compared against a full-size probe in
# .superpowers/sdd/2026-09-28-local-highlight-relief/video-port-3.md.
const DAYLIGHT_PROBE_MAX_WIDTH: int = 960
# Delivered frames to time before projecting the total. Large enough that DLSS and the driver
# have settled, small enough that the warning arrives while the job could still be acted on:
# at ~7 s/frame this fires about a minute into the sequence.
const BUDGET_WARMUP_FRAMES: int = 10
# ...then TIME the next BUDGET_WINDOW_FRAMES and project from THAT. Measuring from frame 0
# over-predicts: the first delivered frames run while DLSS and the driver are still settling.
# Measured 2026-09-30 on urbanvideotest1: 8.10 s/frame over frames 0-10 against a true long-run
# average of 7.07, which would have projected 3694 s for a 421-frame job that takes 3260 and
# fits -- a false 'WILL BE KILLED' on a healthy render. A warning that cries wolf gets ignored.
const BUDGET_WINDOW_FRAMES: int = 20
# Mirrors main.py's int(os.getenv("VIDEO_RENDER_TIMEOUT_SECONDS", "1800")). Not authoritative --
# the env var is read first and wins whenever production sets one.
const BUDGET_DEFAULT_SECONDS: int = 1800
var _daylight_probing: bool = false
var _daylight_exposure: float = 1.0 # what the probe set; logged again at the end to prove it held
var _render_data = {} # Full parsed JSON — used by setup_fixed_fill_lights()
var _has_fixture_lights_cache: bool = false
var _has_authored_lights_cache: bool = false
var _console_log_lines: Array = []
var _output_path: String = "" # Stored for save_logs / thumbnail naming
var _fallback_path: String = "" # Stored for PNG fallback frame output
var _first_frame_saved: bool = false # Track whether first-frame thumbnail has been saved

func _log_console(message) -> void:
	var text = str(message)
	print(text)
	_console_log_lines.append(text)

func _ready():
	_console_log_lines.clear()
	_log_console("Godot VIDEO Renderer Started")
	
	var args = OS.get_cmdline_args()
	if OS.has_method("get_cmdline_user_args"):
		args.append_array(OS.get_cmdline_user_args())
	
	var input_json_path = ""
	var output_path = ""
	var fallback_path = ""
	
	for i in range(args.size()):
		var arg = args[i]
		if arg.ends_with(".json"):
			input_json_path = arg
		elif arg.ends_with(".mp4") or arg.ends_with(".avi"):
			output_path = arg
		elif arg.ends_with(".png") or arg.ends_with(".jpg"):
			fallback_path = arg
		elif arg == "video_output" and output_path == "":
			output_path = arg
			
	if input_json_path == "" and args.size() >= 1:
		input_json_path = args[0]
	if output_path == "" and fallback_path != "":
		output_path = fallback_path
	
	if input_json_path == "":
		_log_console("Error: Missing input JSON argument.")
		get_tree().quit(1)
		return

	_log_console("Input JSON: " + input_json_path)
	_log_console("Output Path: " + output_path)
	
	# Detect if MovieWriter is active
	_use_movie_writer = Engine.get_write_movie_path() != ""
	if _use_movie_writer:
		_log_console("MovieWriter ACTIVE - recording to: " + Engine.get_write_movie_path())
	else:
		_log_console("MovieWriter NOT active - using PNG fallback")
		_use_png_fallback = true
		if fallback_path != "":
			_base_filename = fallback_path.get_basename()
		elif output_path != "":
			_base_filename = output_path.get_basename()
	
	if not FileAccess.file_exists(input_json_path):
		_log_console("Error: Input file does not exist: " + input_json_path)
		get_tree().quit(1)
		return
		
	var json_text = FileAccess.get_file_as_string(input_json_path)
	var json = JSON.new()
	var error = json.parse(json_text)
	if error != OK:
		_log_console("Error parsing JSON: " + json.get_error_message())
		get_tree().quit(1)
		return
		
	var data = json.data
	_setup_render(data, output_path, fallback_path)

func _setup_render(data, output_path, fallback_path):
	_render_data = data # Cache for later use by setup_fixed_fill_lights()
	_has_fixture_lights_cache = _has_fixture_lights(data)
	_has_authored_lights_cache = _has_authored_lights(data)
	_output_path = output_path # Store for save_logs at completion
	_fallback_path = fallback_path
	_log_console("Video render setup starting...")
	set_resolution(data)
	build_scene(data)
	
	if _dir_light != null and not _directional_light_authoring_locked:
		var cam_pose = _frozen_camera_pose if _frozen_camera_pose != null else _extract_camera_pose(data)
		_orient_directional_light_from_windows(_dir_light, cam_pose)
		

	_apply_color_mood_to_scene()
	setup_camera(data)
	
	# Extract keyframes
	if data.has("video_animation") and data["video_animation"] != null:
		var anim_data = data["video_animation"]
		_fps = int(anim_data.get("fps", 30))
		_keyframes = anim_data.get("keyframes", [])
		_total_frames = _keyframes.size()
		
		if _total_frames == 0:
			# Lerp fallback - generate keyframes from start/end
			var duration = anim_data.get("duration_seconds", 5.0)
			_total_frames = int(duration * _fps)
			_generate_lerp_keyframes(anim_data, _total_frames)
		
		# Log keyframe format detection
		if _total_frames > 0 and _keyframes.size() > 0:
			var first_kf = _keyframes[0]
			if first_kf.has("threejs_camera_data"):
				_log_console("Keyframe format: threejs_camera_data (position, lookAt, quaternion, euler, fov)")
			else:
				_log_console("Keyframe format: legacy (position, target, rotation)")
		
		_log_console("Video: %d frames at %d fps" % [_total_frames, _fps])
		_log_console("Expected duration: %.3f seconds" % (float(_total_frames) / float(_fps)))
	else:
		# No video_animation — auto-generate horizontal pan (deferred to warmup phase)
		_log_console("No video_animation found — will generate 5-second horizontal pan from camera position")
		_fps = 30
		var duration = 5.0
		_total_frames = int(duration * _fps)
		_needs_auto_pan = true # Generate pan after scene settles
	
	# Set camera to first frame immediately (only if we have keyframes already)
	if _total_frames > 0 and _keyframes.size() > 0:
		_apply_keyframe(0)
		
	# Set up fill lights NOW, because the sun has just been oriented to the camera's true starting frame
	setup_fixed_fill_lights()
	
	# Warmup: give Godot's renderer (shadow maps, ambient cache, GI) time to settle
	# before the first frame is captured. 10 frames is safe even at 4K.
	_warmup_frames = 20
	_current_frame = 0
	_rendering = false

func _process(_delta):
	# The daylight probe owns the camera and the accumulate flag until it finishes;
	# it calls _begin_dlss_priming() itself when it is done.
	if _daylight_probing:
		return

	# Warmup phase - let the scene settle
	if _warmup_frames > 0:
		_warmup_frames -= 1
		if _warmup_frames == 0:
			# Generate auto-pan AFTER scene has settled (global_transform is now reliable)
			if _needs_auto_pan:
				_generate_horizontal_pan(_total_frames)
				_needs_auto_pan = false
				if _keyframes.size() > 0:
					_apply_keyframe(0)

			# Day renders: measure ONE exposure from the whole camera path BEFORE the DLSS
			# priming phase, so priming and the render proceed untouched with the exposure
			# already set. Night renders are not probe-exposed.
			if day_render:
				_daylight_probing = true
				_run_daylight_probe() # coroutine; ends in _begin_dlss_priming()
				return
			_begin_dlss_priming()
		return
	
	# DLSS priming phase: hold at frame 0 while DLSS builds temporal buffer
	if _dlss_prime_remaining > 0:
		_dlss_prime_remaining -= 1
		# Keep camera at frame 0 — MovieWriter records these frames
		if _keyframes.size() > 0:
			_apply_keyframe(0)
		if _dlss_prime_remaining == 0:
			_rendering = true
			_sequence_t0 = Time.get_ticks_msec()
			_log_console("DLSS priming complete. Starting video render...")
		return
	
	if not _rendering:
		return
	
	# Check if done
	if _current_frame >= _total_frames:
		_log_console("============================================================")
		_log_console("VIDEO RENDER COMPLETE - %d frames rendered." % _total_frames)
		if day_render:
			var env_end := _get_scene_environment()
			if env_end != null:
				_log_console("[Daylight] exposure at end of sequence: %.4f (set once to %.4f before priming; held for all %d frames)" % [
						env_end.tonemap_exposure, _daylight_exposure, _total_frames])
		_log_console("============================================================")
		save_logs(_render_data, _output_path)
		get_tree().quit(0)
		return
	
	# Apply current keyframe
	_apply_keyframe(_current_frame)
	if _video_phase_a():
		_render_phase_a_frame()
	
	# PNG fallback: manually save frame
	if _use_png_fallback and _base_filename != "":
		var img = get_viewport().get_texture().get_image()
		if img and not img.is_empty():
			var frame_filename = "%s_%04d.png" % [_base_filename, _current_frame]
			img.save_png(frame_filename)
	
	# Progress logging
	if _current_frame % 10 == 0 or _current_frame == _total_frames - 1:
		var pct = int(float(_current_frame) / float(_total_frames) * 100.0)
		_log_console("Frame %d/%d (%d%%)" % [_current_frame, _total_frames, pct])

	# Budget projection, logged ONCE, early enough to still be actionable.
	# MEASURED, not estimated: per-frame cost is a property of the SCENE, not of the pipeline
	# (2026-09-30: ~7.1 s/frame on urbanvideotest1 at 3840x2160 vs ~1.7 s/frame on the lighter
	# job 301), so a hardcoded constant would be wrong on the next job.
	#
	# Why it exists: main.py waits VIDEO_RENDER_TIMEOUT_SECONDS and then KILLS Godot.
	# urbanvideotest1 (421 frames at 4K) takes 3260 s -- over the 1800 s default and 91% of the
	# 3600 s it was raised to. Without this the first sign of trouble is a killed process, no
	# partial output, and nothing in the log saying why.
	if _current_frame == BUDGET_WARMUP_FRAMES:
		_budget_t_warm = Time.get_ticks_msec()
	elif _current_frame == BUDGET_WARMUP_FRAMES + BUDGET_WINDOW_FRAMES and _budget_t_warm > 0 \
			and _total_frames > BUDGET_WARMUP_FRAMES + BUDGET_WINDOW_FRAMES:
		var now := float(Time.get_ticks_msec()) / 1000.0
		var per_frame := (now - float(_budget_t_warm) / 1000.0) / float(BUDGET_WINDOW_FRAMES)
		var remaining := float(_total_frames - _current_frame)
		var projected := now + per_frame * remaining
		var budget := float(BUDGET_DEFAULT_SECONDS)
		var budget_env := OS.get_environment("VIDEO_RENDER_TIMEOUT_SECONDS")
		if budget_env != "":
			budget = float(budget_env)
		var verdict := "fits"
		if projected > budget:
			verdict = "WILL BE KILLED -- raise VIDEO_RENDER_TIMEOUT_SECONDS, halve the fps, or shorten the clip"
		elif projected > 0.9 * budget:
			verdict = "fits, under 10% margin"
		_log_console("[Budget] %.2f s/frame measured over delivered frames %d-%d -> about %.0f s for all %d (%.0f s spent so far); VIDEO_RENDER_TIMEOUT_SECONDS %.0f: %s" % [
				per_frame, BUDGET_WARMUP_FRAMES, _current_frame, projected, _total_frames, now, budget, verdict])

	_current_frame += 1

# Start DLSS priming phase: hold camera at frame 0 for a few extra rendered frames so DLSS
# Ray Reconstruction builds temporal history. These frames are captured by MovieWriter.
# (Split out of _process so the daylight probe can run first; the priming itself is unchanged.)
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

func _get_scene_environment() -> Environment:
	for child in get_children():
		if child is WorldEnvironment and (child as WorldEnvironment).environment != null:
			return (child as WorldEnvironment).environment
	return null

# Keyframe indices to probe: p_count positions spread evenly over the path, first and last
# included, duplicates removed (a 2-keyframe path probes 2 positions, a 1-keyframe path 1).
func _daylight_probe_indices(p_count: int) -> Array:
	var out: Array = []
	var n: int = _keyframes.size() # _keyframes is an untyped Array, so := cannot infer here
	if n <= 0 or p_count <= 0:
		return out
	for i in range(p_count):
		var idx := 0
		if p_count > 1:
			idx = roundi(float(i) * float(n - 1) / float(p_count - 1))
		if not out.has(idx):
			out.append(idx)
	return out

func _finish_daylight_probe() -> void:
	_daylight_probing = false
	_begin_dlss_priming()

# Size of the probe's SubViewport: DAYLIGHT_PROBE_MAX_WIDTH wide (or the recorded viewport's
# width, if that is smaller) at the recorded viewport's aspect ratio. Same aspect means the same
# frustum, so the probe sees the same instances the recorded viewport does.
func _daylight_probe_size() -> Vector2i:
	var rec: Vector2 = get_viewport().get_visible_rect().size
	if rec.x < 2.0 or rec.y < 2.0:
		return Vector2i(DAYLIGHT_PROBE_MAX_WIDTH, DAYLIGHT_PROBE_MAX_WIDTH * 9 / 16)
	var w: int = mini(DAYLIGHT_PROBE_MAX_WIDTH, int(rec.x))
	return Vector2i(w, maxi(2, roundi(float(w) * rec.y / rec.x)))

# Puts the probe camera exactly where MainCamera is. _apply_keyframe() has just moved MainCamera
# and re-oriented the sun (it does so for frame index % 5 == 0, and _current_frame is 0 here);
# Godot defers the resulting transform notifications to the end of the frame, and the probe
# renders inside this one, so they are flushed by hand.
func _sync_daylight_probe_camera(p_probe: Camera3D, p_main: Camera3D) -> void:
	if _dir_light != null:
		_dir_light.force_update_transform()
	p_main.force_update_transform()
	p_probe.global_transform = p_main.global_transform
	p_probe.fov = p_main.fov
	p_probe.force_update_transform()

# Probes the day scene at several camera positions along the path, pools the raw luminance
# samples, calls Daylight.stats() ONCE on the pooled array, and sets tonemap_exposure once.
#
# Pooled samples rather than an average of per-position exposures: stats() masks windows as
# samples above 8x the median of the array it is GIVEN, and that mask only means something on
# the whole path's population (a position that is mostly window has a raw median that is itself
# sky, so its own mask would keep the sky and drop the room). The pooled median is also the
# median of every occupied pixel the camera will see, which is what the exposure is for.
#
# OFFSCREEN, and in ZERO main-loop iterations. MovieWriter records one frame per main-loop
# iteration (Main::iteration -> movie_writer->add_frame) and always reads the MAIN viewport's
# texture, so it does not matter which viewport does the tracing: a probe paced on process_frame
# (Daylight.probe) puts one movie frame in the video per probe frame, 69 of them. Two things
# remove them:
#  * the tracing runs in a private SubViewport that shares the main World3D (same geometry,
#    lights and sun) and has its own Camera3D, whose `environment` is a DUPLICATE of the scene's
#    Environment. The accumulate flag is an Environment property, so a shared Environment would
#    switch accumulation on for the recorded viewport too; the duplicate leaves the recorded
#    viewport's Environment, its DLSS-RR history and its accumulation state untouched;
#  * Daylight.probe_offscreen() paces the SubViewport with RenderingServer.force_draw() and
#    returns in the same call, so the whole probe happens inside one _process() call. The
#    recorded viewport is deactivated for that call so force_draw() draws only the probe; it is
#    reactivated below, before this function returns and long before the iteration's own draw.
# The recorded viewport never renders a probe frame and MovieWriter never sees one.
#
# State contract with the DLSS path: nothing is left toggled. The recorded viewport's Environment
# is only read (duplicated), MainCamera finishes on the frame-0 pose that the warmup and the
# priming both use, and the rig is freed before priming starts.
# Positions are probed LAST, MIDDLE, FIRST (the order the on-screen version used).
func _run_daylight_probe() -> void:
	var env := _get_scene_environment()
	var indices := _daylight_probe_indices(DAYLIGHT_PROBE_POSITIONS)
	if env == null or indices.is_empty():
		_log_console("[Daylight] probe skipped: %s; exposure left at 1.0" % ("no Environment" if env == null else "no keyframes"))
		_finish_daylight_probe()
		return

	# Test hook (like render.gd's ZR_DAYLIGHT_FLOOR): force an exposure and skip the probe, so a
	# control render has the same scene and exposure but none of the probe's work.
	var forced := OS.get_environment("ZR_DAYLIGHT_VIDEO_EXPOSURE")
	if forced != "":
		env.tonemap_exposure = float(forced)
		_daylight_exposure = env.tonemap_exposure
		_log_console("[Daylight] ZR_DAYLIGHT_VIDEO_EXPOSURE=%s: probe skipped, exposure forced to %.4f (test hook)" % [forced, _daylight_exposure])
		_finish_daylight_probe()
		return

	var main_cam := get_node_or_null("MainCamera") as Camera3D
	if main_cam == null:
		_log_console("[Daylight] probe skipped: no MainCamera; exposure left at 1.0")
		_finish_daylight_probe()
		return

	# ZR_DAYLIGHT_VIDEO_FLOOR: test-only override of Daylight.FLOOR, i.e. the still route's
	# ZR_DAYLIGHT_FLOOR under a video-specific name so one variable cannot silently arm both
	# routes in a batch. The fill branch below is unreachable on every job measured so far
	# (job 301 reads p25 0.0956 after exposure against the 0.02 floor), so without this hook the
	# ported code could not be exercised on a real job at all.
	var floor_v := Daylight.FLOOR
	var floor_override := OS.get_environment("ZR_DAYLIGHT_VIDEO_FLOOR")
	if floor_override != "":
		floor_v = float(floor_override)
		_log_console("[Daylight] floor override ZR_DAYLIGHT_VIDEO_FLOOR=%s" % floor_override)

	var t0 := Time.get_ticks_msec()
	var iterations0 := Engine.get_frames_drawn()
	env.tonemap_exposure = 1.0

	# The offscreen rig: SubViewport + Camera3D + a private copy of the Environment.
	var probe_env: Environment = env.duplicate()
	# Phase A video sets oidn_denoise on the scene Environment, and duplicate() copies it. The
	# probe reads only the raw accumulator (viewport_get_pathtracing_accum_image), so a denoise in
	# here is wasted -- and at 960x540 it would make the CUDA buffers reallocate against 4K.
	probe_env.pathtracing_oidn_denoise = false
	var probe_size := _daylight_probe_size()
	var probe_vp := SubViewport.new()
	probe_vp.name = "DaylightProbeViewport"
	probe_vp.size = probe_size
	probe_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS # the default only draws when something samples its texture
	probe_vp.world_3d = get_viewport().find_world_3d() # the SAME world: same instances, lights and sun
	probe_vp.mesh_lod_threshold = get_viewport().mesh_lod_threshold # the recorded viewport sets 0.0; a SubViewport defaults to 1.0
	var probe_cam := Camera3D.new()
	probe_cam.name = "DaylightProbeCamera"
	probe_cam.environment = probe_env
	probe_cam.near = main_cam.near
	probe_cam.far = main_cam.far
	probe_cam.keep_aspect = main_cam.keep_aspect
	probe_vp.add_child(probe_cam)
	add_child(probe_vp)
	probe_cam.make_current()
	var probe_rid := probe_vp.get_viewport_rid()
	var recorded_rid := get_viewport().get_viewport_rid()

	var order := indices.duplicate()
	order.reverse() # last, middle, first
	# force_draw() renders every viewport in the active list, so the recorded one is skipped for
	# the duration -- but it must stay ACTIVE. _sort_active_viewports() (renderer_viewport.cpp)
	# seeds its list with ROOT viewports only and then walks down to THEIR children, so
	# deactivating the recorded viewport takes this SubViewport out of the draw list with it: the
	# probe viewport is then never drawn, never gets render buffers, and the accumulator readback
	# returns nothing at every position (measured 2026-09-29, exposure fell back to 1.0).
	# VIEWPORT_UPDATE_DISABLED is checked per viewport INSIDE draw_viewports' own loop, so the
	# recorded viewport stays a seed, the child still draws, and only the parent's draw is skipped.
	var prev_update_mode := RenderingServer.viewport_get_update_mode(recorded_rid)
	RenderingServer.viewport_set_update_mode(recorded_rid, RenderingServer.VIEWPORT_UPDATE_DISABLED)
	var pass1 := _probe_path_pooled(probe_env, probe_rid, probe_cam, main_cam, order)
	var pooled: PackedFloat32Array = pass1["pooled"]
	var per_pos: Dictionary = pass1["per_pos"]

	# The fallback fill, ported from render.gd:652. Decided HERE, while the probe rig is still
	# alive, because the solve needs a SECOND pooled pass with the fill present and
	# Daylight.solve_fill requires both sample arrays to be the same length.
	#
	# Same trigger as the still route, including `not clamped`: a scene whose exposure already hit
	# EXPOSURE_MAX gets no fill on either route. (Port-2 concern #4 read this as a video-only gap;
	# it is not -- the clamped case is unhandled in both.) Only the UNCLAMPED
	# darkest-quarter-under-floor case is what video was missing.
	#
	# Cost: nothing on the normal path -- the second pass runs only inside this branch, which no
	# job measured so far reaches. Affordable at all only because port 3 moved the probe offscreen;
	# before that it would have added another 69 frames to the movie.
	var st := {}
	var exposure: float = 1.0
	var fill_line := ""
	if not pooled.is_empty():
		st = Daylight.stats(pooled)
		exposure = float(st["exposure"])
		if float(st["p25"]) * exposure < floor_v and not bool(st["clamped"]):
			var fill := _place_daylight_path_fill(1.0)
			var pass2 := _probe_path_pooled(probe_env, probe_rid, probe_cam, main_cam, order)
			var pooled1: PackedFloat32Array = pass2["pooled"]
			if pooled1.size() != pooled.size():
				fill_line = "[Daylight] fill probe: pooled %d samples with the fill vs %d without; no fill" % [
						pooled1.size(), pooled.size()]
				fill.queue_free()
			else:
				var sol := Daylight.solve_fill(pooled, pooled1, floor_v)
				# What the fill would ACHIEVE, not what it was asked for: sol["p25"] and
				# sol["exposure"] are the solver's own post-fill stats, so this is the darkest
				# quarter the frames would actually get.
				var before := float(st["p25"]) * float(st["exposure"])
				var achieved := float(sol["p25"]) * float(sol["exposure"])
				if sol["needed"] and achieved <= before:
					# MEASURED 2026-09-30, job 301 fixtures-off: the solver stopped at
					# FILL_SHARE_CAP with energy 393.18 and the darkest quarter went
					# 0.0772 -> 0.0764 -- very slightly WORSE. The mechanism is in solve_fill's
					# own definition: exposure is TARGET_MEDIAN / median(f), so a fill that lifts
					# the median faster than it lifts the dark corners buys nothing. p25 * e stays
					# flat while the exposure halves, the frames' median is driven to target
					# either way, and all the fill has done is flatten contrast and add a
					# 393-energy light. solve_fill's `capped` branch returns needed = true without
					# checking this, so the guard lives here.
					#
					# The still route has the SAME branch (render.gd:659 applies sol["energy"]
					# whenever needed is true) and therefore the same hole; its fill has never
					# fired on a production job, so nobody has seen it. Not fixed there from here:
					# changing Daylight.solve_fill would change still-route behaviour, and that
					# belongs in its own change with its own gate. Recorded in video-port-4.md.
					fill_line = "[Daylight] fill: solver stopped at share cap %.2f with energy %.4f and the darkest quarter would go %.4f -> %.4f (no better, floor %.3f); fill DISCARDED, exposure left at %.3f" % [
							Daylight.FILL_SHARE_CAP, sol["energy"], before, achieved, floor_v,
							float(st["exposure"])]
					fill.queue_free()
				elif sol["needed"]:
					fill.light_energy = sol["energy"]
					exposure = float(sol["exposure"])
					fill_line = "[Daylight] fill: p25 %.4f < %.3f after exposure -> DaylightFill at %s size %s energy %.4f%s; exposure %.3f -> %.3f, darkest quarter %.4f -> %.4f (floor %.3f%s); one fill, held for all frames" % [
							before, floor_v,
							str(fill.global_position), str(fill.area_size), sol["energy"],
							" (CAPPED at share %.2f)" % Daylight.FILL_SHARE_CAP if sol["capped"] else "",
							float(st["exposure"]), exposure,
							before, achieved, floor_v,
							" NOT REACHED" if achieved < floor_v else " reached"]
				elif sol["exhausted"]:
					fill_line = "[Daylight] fill: solver exhausted (the fill moved neither the median nor the darkest quarter); no fill"
					fill.queue_free()
				else:
					fill_line = "[Daylight] fill: solver found no energy under the share cap %.2f; no fill" % Daylight.FILL_SHARE_CAP
					fill.queue_free()

	RenderingServer.viewport_set_update_mode(recorded_rid, prev_update_mode)

	# Hand the scene back as the DLSS path expects it: camera and sun on the frame-0 pose, the rig gone.
	_apply_keyframe(0)
	if _dir_light != null:
		_dir_light.force_update_transform()
	main_cam.force_update_transform()
	remove_child(probe_vp)
	probe_vp.free() # immediately, not queue_free(): nothing of the rig may outlive this call
	var iterations: int = Engine.get_frames_drawn() - iterations0

	if pooled.is_empty():
		_log_console("[Daylight] probe: every accumulator readback returned nothing; exposure left at 1.0 (the frames will be dark)")
		_finish_daylight_probe()
		return
	var lo := INF
	var hi := 0.0
	var ascending := indices.duplicate()
	ascending.sort()
	var names := ["first", "middle", "last"]
	for k in range(ascending.size()):
		var idx: int = ascending[k]
		var pr: Dictionary = per_pos[idx]
		if pr["samples"].is_empty():
			continue
		var own := Daylight.stats(pr["samples"])
		lo = minf(lo, own["exposure"])
		hi = maxf(hi, own["exposure"])
		var label: String = names[k] if ascending.size() == 3 else "pos%d" % k
		_log_console("[Daylight] probe %s (keyframe %d/%d): median %.5f (occupied %.1f%%), own exposure %.3f%s, p25 %.5f; at the pooled exposure median -> %.4f  [%dx%d]" % [
				label, idx, _keyframes.size() - 1, own["median"], 100.0 * own["occupied_fraction"], own["exposure"],
				" CLAMPED" if own["clamped"] else "", own["p25"], own["median"] * exposure, pr["width"], pr["height"]])
	env.tonemap_exposure = exposure
	_daylight_exposure = exposure
	# This line describes the PROBE, so it reports the probe's own exposure, not the one a fill may
	# have replaced it with. Mixing them produced a genuinely meaningless number in the first
	# forced-fill run -- pre-fill p25 times post-fill exposure, "p25 0.00226 -> 0.0374", which
	# described neither state. The fill line below owns the before/after of the change; when no
	# fill is placed the two exposures are equal and this line reads exactly as it always has.
	_log_console("[Daylight] probe: POOLED %d positions, %d samples: median %.5f (occupied %.1f%%), exposure %.3f%s, p25 %.5f -> %.4f after exposure  [%d ms, %d main-loop frames]" % [
			ascending.size(), pooled.size(), st["median"], 100.0 * st["occupied_fraction"], float(st["exposure"]),
			" CLAMPED -- scene is not a lit interior" if st["clamped"] else "",
			st["p25"], float(st["p25"]) * float(st["exposure"]),
			Time.get_ticks_msec() - t0, iterations])
	if hi > 0.0 and lo < INF:
		_log_console("[Daylight] path spread: per-position own exposures %.3f .. %.3f (ratio %.2f); ONE exposure %.3f is held for all %d frames" % [
				lo, hi, hi / maxf(lo, 1e-9), exposure, _total_frames])
	if fill_line != "":
		_log_console(fill_line)
	elif float(st["p25"]) * float(st["exposure"]) < floor_v:
		# Reachable ONLY when the exposure clamped. The trigger above excludes clamped scenes, and
		# every non-clamped frame that reaches the floor sets fill_line, so repeating the trigger's
		# full condition here would be a branch that can never run. A clamped scene getting no fill
		# is the still route's rule too, not a video shortcoming -- see video-port-4.md Finding 2.
		_log_console("[Daylight] note: the darkest occupied quarter reads %.4f after exposure, under the fill floor %.3f, but the exposure is CLAMPED so no fill is placed (same rule as the still route)." % [
				float(st["p25"]) * float(st["exposure"]), floor_v])
	var rec_size: Vector2 = get_viewport().get_visible_rect().size
	_log_console("[Daylight] probe ran offscreen: SubViewport %dx%d (recorded viewport %dx%d), %d positions, %d force_draw calls, none of them main-loop frames" % [
			probe_size.x, probe_size.y, int(rec_size.x), int(rec_size.y),
			ascending.size(), ascending.size() * (Daylight.RESET_SETTLE_FRAMES * 2 + Daylight.PROBE_FRAMES)])
	_log_console("[Daylight] pre-roll frames recorded by MovieWriter before the sequence: warmup %d + probe %d + priming %d (production trims by frame count)" % [
			20, iterations, DLSS_PRIME_FRAMES])
	_finish_daylight_probe()


# One pooled pass over the probe positions: for each keyframe it moves MainCamera and the sun,
# copies the pose to the offscreen camera, accumulates, and concatenates the raw samples.
# Factored out of _run_daylight_probe because the fill solve needs a SECOND pass over the SAME
# positions with the fill present, and Daylight.solve_fill requires both sample arrays to be the
# same length -- which holds only if both passes visit the same positions and each one returns.
func _probe_path_pooled(p_env: Environment, p_rid: RID, p_probe_cam: Camera3D, p_main_cam: Camera3D,
		p_order: Array) -> Dictionary:
	var per_pos := {} # keyframe index -> probe result
	var pooled := PackedFloat32Array()
	for idx in p_order:
		_apply_keyframe(idx)
		_sync_daylight_probe_camera(p_probe_cam, p_main_cam)
		var pr: Dictionary = Daylight.probe_offscreen(p_env, p_rid)
		per_pos[idx] = pr
		if pr["samples"].is_empty():
			_log_console("[Daylight] probe: keyframe %d accumulator readback returned nothing; position dropped from the pool" % idx)
		else:
			pooled.append_array(pr["samples"])
	return {"pooled": pooled, "per_pos": per_pos}


## The video route's fallback fill. The same light the still route builds in
## render.gd :: _place_daylight_fill -- AreaLight3D, normalised energy, no shadows, facing down,
## 0.3 m under the ceiling, 0.6x the extent -- with ONE deliberate difference: it is placed and
## sized from the WHOLE lighting bounds, not from _resolve_active_area_polygon().
##
## The still route narrows to the polygon of the area the camera stands in, which is correct for a
## single fixed camera. A video path crosses rooms, and the probe already pools three positions
## into one held exposure. A fill sized to one room's extent and placed at its centroid would
## under-light the rest of the path, and the solver -- which scans against the POOLED p25 -- would
## then over-drive it to compensate, over-lighting the room it sits in. One plan-wide fill matches
## the one held exposure: the same trade as the pooled probe, made the same way.
func _place_daylight_path_fill(p_energy: float) -> AreaLight3D:
	# _extract_room_lighting_bounds() wants the parsed floor-plan geometry dict, which
	# build_scene() stashes in _floor_plan_root_data (video_glb_creation.gd:256) -- NOT the raw
	# job JSON, whose floor_plan_data can be a STRING in some jobs and would silently fall back
	# to the (0,0,0)/6x6/2.8 defaults. Same reasoning as render.gd's copy.
	var bounds := _extract_room_lighting_bounds(_floor_plan_root_data)
	var center: Vector3 = bounds["center"]
	var extent: Vector2 = bounds["extent"]
	var ceiling_y: float = bounds["ceiling_y"]
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

func _capture_thumbnail_async():
	await RenderingServer.frame_post_draw
	var img = get_viewport().get_texture().get_image()
	if img and not img.is_empty():
		_save_thumbnail_webp(img, _output_path)

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

func _apply_keyframe(frame_idx: int):
	var cam = get_node_or_null("MainCamera")
	if not cam:
		return
	
	var kf = _keyframes[frame_idx]
	
	# Coordinate scale: JSON positions are in centimetres; Godot uses metres
	# Check if this keyframe has threejs_camera_data (preferred format)
	if kf.has("threejs_camera_data") and kf["threejs_camera_data"] != null:
		var tjs = kf["threejs_camera_data"]

		# Position (cm → metres)
		if tjs.has("position") and tjs["position"] != null:
			var p = tjs["position"]
			cam.position = _camera_cm_to_m(Vector3(float(p["x"]), float(p["y"]), float(p["z"])))

		var orientation_set = false

		# lookAt (cm → metres) — guard against straight-down look
		if tjs.has("lookAt") and tjs["lookAt"] != null:
			var la = tjs["lookAt"]
			var look_target = _camera_cm_to_m(Vector3(float(la["x"]), float(la["y"]), float(la["z"])))
			if cam.position.distance_to(look_target) > 0.001:
				var diff_v = (look_target - cam.position).normalized()
				var up_vec = Vector3.UP
				if abs(diff_v.dot(Vector3.UP)) > 0.999:
					up_vec = Vector3.BACK # Use -Z as up when camera points straight down/up
				cam.look_at(look_target, up_vec)
				orientation_set = true

		# Quaternion fallback (skip identity)
		if not orientation_set and tjs.has("quaternion") and tjs["quaternion"] != null:
			var q = tjs["quaternion"]
			var qx = float(q["x"])
			var qy = float(q["y"])
			var qz = float(q["z"])
			var qw = float(q["w"])
			if abs(qx) > 0.0001 or abs(qy) > 0.0001 or abs(qz) > 0.0001 or abs(qw - 1.0) > 0.0001:
				cam.basis = Basis(Quaternion(qx, qy, qz, qw).normalized())
				orientation_set = true

		# Euler fallback
		if not orientation_set and tjs.has("euler") and tjs["euler"] != null:
			var e = tjs["euler"]
			var ex = float(e["x"])
			var ey = float(e["y"])
			var ez = float(e["z"])
			if abs(ex) > 0.0001 or abs(ey) > 0.0001 or abs(ez) > 0.0001:
				cam.basis = Basis.from_euler(Vector3(ex, ey, ez), EULER_ORDER_XYZ)
				orientation_set = true

		# Per-frame FOV
		if tjs.has("fov") and tjs["fov"] != null:
			cam.fov = float(tjs["fov"])
	else:
		# Legacy format (positions are in centimetres)
		if kf.has("position") and kf["position"] != null:
			var p = kf["position"]
			cam.position = _camera_cm_to_m(Vector3(float(p["x"]), float(p["y"]), float(p["z"])))

		if kf.has("target") and kf["target"] != null:
			var t = kf["target"]
			var tgt = _camera_cm_to_m(Vector3(float(t["x"]), float(t["y"]), float(t["z"])))
			if cam.position.distance_to(tgt) > 0.001:
				var diff_v = (tgt - cam.position).normalized()
				var up_vec = Vector3.UP
				if abs(diff_v.dot(Vector3.UP)) > 0.999:
					up_vec = Vector3.BACK
				cam.look_at(tgt, up_vec)
		elif kf.has("rotation") and kf["rotation"] != null:
			var r = kf["rotation"]
			cam.basis = Basis.from_euler(Vector3(float(r["x"]), float(r["y"]), float(r["z"])), EULER_ORDER_XYZ)

	# Top-level FOV (legacy)
	if kf.has("fov") and kf["fov"] != null:
		cam.fov = float(kf["fov"])

	# ── Smooth interpolation toward this frame's target ──────────────────
	# After hard-setting position/rotation above, we blend the camera
	# gently toward the NEXT keyframe so movement is fluid (no snap/jitter).
	if frame_idx < _keyframes.size() - 1:
		var next_kf = _keyframes[frame_idx + 1]
		var smooth_t = _smooth_step(0.15) # blend 15% toward next frame each tick
		# Smooth position
		var next_pos = _extract_kf_position(next_kf)
		if next_pos != null:
			cam.position = cam.position.lerp(next_pos, smooth_t)
		# Smooth rotation (slerp quaternion so gimbal-lock cannot occur)
		var next_quat = _extract_kf_quaternion(next_kf, cam)
		if next_quat != null:
			var cur_q = cam.basis.get_rotation_quaternion().normalized()
			var blended = cur_q.slerp(next_quat.normalized(), smooth_t)
			cam.basis = Basis(blended)

	# Dynamic sunlight: update sun orientation to favor windows in this frame's view
	if _dir_light != null and not _directional_light_authoring_locked:
		if _window_sunlight_data.size() > 0 and _current_frame % 5 == 0:
			var cam_pose = {
				"position": cam.position,
				"target": cam.position - cam.basis.z * 5.0
			}
			_orient_directional_light_from_windows(_dir_light, cam_pose)

# ─────────────────────────────────────────────────────────────────
# Smooth Camera Helpers
# ─────────────────────────────────────────────────────────────────

# Cubic ease-in-out smoothstep for the given blend factor
func _smooth_step(t: float) -> float:
	return t * t * (3.0 - 2.0 * t)

# Extract world position (metres) from any keyframe format, or return null
func _extract_kf_position(kf: Dictionary):
	if kf.has("threejs_camera_data") and kf["threejs_camera_data"] != null:
		var tjs = kf["threejs_camera_data"]
		if tjs.has("position") and tjs["position"] != null:
			var p = tjs["position"]
			return _camera_cm_to_m(Vector3(float(p["x"]), float(p["y"]), float(p["z"])))
	elif kf.has("position") and kf["position"] != null:
		var p = kf["position"]
		return _camera_cm_to_m(Vector3(float(p["x"]), float(p["y"]), float(p["z"])))
	return null

# Extract rotation as Quaternion from any keyframe format.
# If only a lookAt / target is provided, compute it from cam's current position.
func _extract_kf_quaternion(kf: Dictionary, cam: Camera3D):
	if kf.has("threejs_camera_data") and kf["threejs_camera_data"] != null:
		var tjs = kf["threejs_camera_data"]
		# Quaternion field
		if tjs.has("quaternion") and tjs["quaternion"] != null:
			var q = tjs["quaternion"]
			return Quaternion(float(q["x"]), float(q["y"]), float(q["z"]), float(q["w"]))
		# lookAt → derive quaternion from direction
		if tjs.has("lookAt") and tjs["lookAt"] != null:
			var la = tjs["lookAt"]
			var look_target = _camera_cm_to_m(Vector3(float(la["x"]), float(la["y"]), float(la["z"])))
			var next_pos = _extract_kf_position(kf)
			var origin = next_pos if next_pos != null else cam.global_position
			if origin.distance_to(look_target) > 0.001:
				var dir = (look_target - origin).normalized()
				var up = Vector3.UP
				if abs(dir.dot(Vector3.UP)) > 0.999: up = Vector3.BACK
				var tmp = Camera3D.new() # temp node to use look_at math
				tmp.look_at_from_position(origin, look_target, up)
				var q = tmp.basis.get_rotation_quaternion()
				tmp.free()
				return q
		# Euler fallback
		if tjs.has("euler") and tjs["euler"] != null:
			var e = tjs["euler"]
			return Basis.from_euler(Vector3(float(e["x"]), float(e["y"]), float(e["z"])), EULER_ORDER_XYZ).get_rotation_quaternion()
	elif kf.has("target") and kf["target"] != null:
		var t = kf["target"]
		var tgt = _camera_cm_to_m(Vector3(float(t["x"]), float(t["y"]), float(t["z"])))
		var next_pos = _extract_kf_position(kf)
		var origin = next_pos if next_pos != null else cam.global_position
		if origin.distance_to(tgt) > 0.001:
			var dir = (tgt - origin).normalized()
			var up = Vector3.UP
			if abs(dir.dot(Vector3.UP)) > 0.999: up = Vector3.BACK
			var tmp = Camera3D.new()
			tmp.look_at_from_position(origin, tgt, up)
			var q = tmp.basis.get_rotation_quaternion()
			tmp.free()
			return q
	return null

func _generate_lerp_keyframes(anim_data, total_frames: int):
	var cam = get_node_or_null("MainCamera")
	if not cam:
		return
	
	var start_pos = cam.position
	var end_pos = start_pos

	if anim_data.has("camera_position_start") and anim_data["camera_position_start"] != null:
		start_pos = _camera_cm_to_m(parse_vec3(anim_data["camera_position_start"]))
	if anim_data.has("camera_position_end") and anim_data["camera_position_end"] != null:
		end_pos = _camera_cm_to_m(parse_vec3(anim_data["camera_position_end"]))
	
	var start_target = null
	var end_target = null
	if anim_data.has("camera_target_start") and anim_data["camera_target_start"] != null:
		start_target = _camera_cm_to_m(parse_vec3(anim_data["camera_target_start"]))
	if anim_data.has("camera_target_end") and anim_data["camera_target_end"] != null:
		end_target = _camera_cm_to_m(parse_vec3(anim_data["camera_target_end"]))
	
	_keyframes = []
	for frame in range(total_frames):
		var t = float(frame) / float(total_frames - 1) if total_frames > 1 else 0.0
		var pos = start_pos.lerp(end_pos, t)
		var kf = {"position": {"x": pos.x, "y": pos.y, "z": pos.z}}
		
		if start_target != null and end_target != null:
			var tgt = start_target.lerp(end_target, t)
			kf["target"] = {"x": tgt.x, "y": tgt.y, "z": tgt.z}
		
		_keyframes.append(kf)
	
	print("Generated ", _keyframes.size(), " lerp keyframes")

func _generate_horizontal_pan(total_frames: int):
	# Generate a horizontal pan from the camera's initial position
	# Camera moves sideways (along its local right axis) while looking at a fixed target
	var cam = get_node_or_null("MainCamera")
	if not cam:
		return
	
	var start_pos = cam.global_position
	var forward = - cam.global_transform.basis.z.normalized()
	var right = cam.global_transform.basis.x.normalized()
	
	# Target point: where the camera is currently looking (5 meters ahead)
	var look_distance = 5.0
	var target_point = start_pos + forward * look_distance
	
	# Pan distance: move camera 3 meters to the right over 5 seconds
	var pan_distance = 3.0
	
	_keyframes = []
	for frame in range(total_frames):
		var t = float(frame) / float(total_frames - 1) if total_frames > 1 else 0.0
		# Move camera horizontally along the right axis
		var offset = right * (t * pan_distance - pan_distance * 0.5) # Center the pan
		var pos = start_pos + offset
		
		var kf = {
			"position": {"x": pos.x, "y": pos.y, "z": pos.z},
			"target": {"x": target_point.x, "y": target_point.y, "z": target_point.z}
		}
		_keyframes.append(kf)
	
	print("Generated ", _keyframes.size(), " horizontal pan keyframes")
	print("  Start: ", start_pos, " Target: ", target_point, " Pan: ", pan_distance, "m")

func _apply_no_authored_light_boost() -> void:
	if _has_authored_lights_cache:
		return

	if day_render:
		_log_console("[VideoRender] Day render active — skipping fallback center blast (handled by dynamic grid fill).")
		return

	var room_info = _extract_room_lighting_bounds(_render_data)
	var room_center: Vector3 = room_info.get("center", Vector3.ZERO)
	var room_extent: Vector2 = room_info.get("extent", Vector2(6.0, 6.0))
	var room_ceiling_y: float = float(room_info.get("ceiling_y", room_center.y + 2.8))
	var span = max(room_extent.x, room_extent.y)
	var fill_y = room_ceiling_y - 0.45
	var fill_tint = _get_color_mood_light_color("fill")
	var boost_energy = 3.2 if day_render else 1.35
	var side_energy = 2.0 if day_render else 0.82
	var floor_energy = 1.25 if day_render else 0.45

	var center_boost = OmniLight3D.new()
	center_boost.name = "RenderBoostCenterLight"
	center_boost.position = Vector3(room_center.x, fill_y, room_center.z)
	center_boost.light_energy = boost_energy * _lighting_illumination_scale
	center_boost.omni_range = max(span * 2.6 + 8.0, 12.0)
	center_boost.light_color = fill_tint
	center_boost.light_specular = 0.10
	center_boost.shadow_enabled = false
	center_boost.add_to_group("fill_lights")
	add_child(center_boost)

	var side_boost_left = OmniLight3D.new()
	side_boost_left.name = "RenderBoostLeftLight"
	side_boost_left.position = Vector3(room_center.x - span * 0.28, fill_y, room_center.z)
	side_boost_left.light_energy = side_energy * _lighting_illumination_scale
	side_boost_left.omni_range = max(span * 2.1 + 6.0, 10.0)
	side_boost_left.light_color = fill_tint
	side_boost_left.light_specular = 0.05
	side_boost_left.shadow_enabled = false
	side_boost_left.add_to_group("fill_lights")
	add_child(side_boost_left)

	var side_boost_right = OmniLight3D.new()
	side_boost_right.name = "RenderBoostRightLight"
	side_boost_right.position = Vector3(room_center.x + span * 0.28, fill_y, room_center.z)
	side_boost_right.light_energy = side_energy * _lighting_illumination_scale
	side_boost_right.omni_range = max(span * 2.1 + 6.0, 10.0)
	side_boost_right.light_color = fill_tint
	side_boost_right.light_specular = 0.05
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

	_log_console("[VideoRender] Applied additional no-authored-lights boost lighting.")

# ─────────────────────────────────────────────────────────────────
# Resolution
# ─────────────────────────────────────────────────────────────────
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
			
	# ── Resolution ────────────────────────────────────────────────────────────
	# With Path Tracing enabled, 2× super-sampling is not needed:
	#   - PT fires rays per pixel at native resolution (not rasterized).
	#   - DLSS Ray Reconstruction handles denoising + sub-pixel reconstruction.
	#   - The 2× doubling also causes sl::eErrorDuplicatedConstants because
	#     DLSS's internal resolution management conflicts with the already-doubled viewport.
	# Render at native resolution; PT + DLSS RR produces clean output directly.
	print("Video Resolution: ", w, "x", h)
	get_viewport().size = Vector2i(w, h)

	# Anti-aliasing for video with Path Tracing + DLSS Ray Reconstruction:
	# DLSS RR provides denoising + temporal AA + sub-pixel reconstruction.
	# TAA is disabled to avoid double-temporal-accumulation artifacts (ghosting).
	get_viewport().msaa_3d = Viewport.MSAA_DISABLED
	get_viewport().screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	get_viewport().use_taa = false # DLSS RR handles temporal stability
	get_viewport().use_debanding = true
	get_viewport().mesh_lod_threshold = 0.0
	# DLSS scaling mode: required for Ray Reconstruction to execute.
	# The DLSS-RR denoiser only runs inside the SCALE_DLSS code path in
	# render_forward_clustered.cpp. scale = 1.0 → no resolution change,
	# pure denoising pass only.
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

	# 16x Anisotropic Filtering (value 4 = 16x in Godot 4)
	ProjectSettings.set_setting("rendering/textures/default_filters/anisotropic_filter_level", 16)

# ─────────────────────────────────────────────────────────────────
# Camera Setup (Initial)
# ─────────────────────────────────────────────────────────────────
func setup_camera(data):
	var cam = Camera3D.new()
	cam.name = "MainCamera"
	cam.far = 1000.0 # Far enough to render the procedural sky without clipping

	var pos = Vector3(0, 1.5, 5)
	var target = Vector3(0, 1.0, 0)

	var cam_data = {}

	# 1) ThreeJS initial camera (from video_animation first keyframe or top-level)
	if data.has("video_animation") and data["video_animation"] != null:
		var anim = data["video_animation"]
		var keyframes = anim.get("keyframes", [])
		if keyframes.size() > 0:
			var kf0 = keyframes[0]
			var tjs = kf0.get("threejs_camera_data", null)
			if tjs != null and typeof(tjs) == TYPE_DICTIONARY:
				if tjs.has("position"):
					var p = tjs["position"]
					pos = _camera_cm_to_m(Vector3(float(p["x"]), float(p["y"]), float(p["z"])))
					cam.position = pos
				if tjs.has("lookAt"):
					var la = tjs["lookAt"]
					target = _camera_cm_to_m(Vector3(float(la["x"]), float(la["y"]), float(la["z"])))
					if cam.position.distance_to(target) > 0.001:
						var diff_v = (target - cam.position).normalized()
						var up_vec = Vector3.UP
						if abs(diff_v.dot(Vector3.UP)) > 0.999:
							up_vec = Vector3.BACK
						cam.look_at(target, up_vec)
				if tjs.has("fov") and tjs["fov"] != null:
					cam.fov = float(tjs["fov"])
				print("Camera Setup (Video KF0 ThreeJS): Pos=", pos, " Target=", target)
				add_child(cam)
				return

	# 2) Explicit threejs_camera block
	var prefer_threejs = data.get("use_threejs", use_threejs)
	if prefer_threejs and data.has("threejs_camera"):
		cam_data = data["threejs_camera"]
		if cam_data.has("position"):
			var p = cam_data["position"]
			pos = _camera_cm_to_m(Vector3(float(p["x"]), float(p["y"]), float(p["z"])))
		cam.position = pos
		if cam_data.has("rotation"):
			var r = cam_data["rotation"]
			cam.basis = Basis.from_euler(Vector3(float(r["x"]), float(r["y"]), float(r["z"])), EULER_ORDER_XYZ)
			print("Camera Setup (ThreeJS): Pos=", pos, " Rotation=", cam.rotation)
		elif cam_data.has("target"):
			var t = cam_data["target"]
			target = _camera_cm_to_m(Vector3(float(t["x"]), float(t["y"]), float(t["z"])))
			cam.look_at(target)
			print("Camera Setup (ThreeJS): Pos=", pos, " Target=", target)

	# 3) Blender camera
	elif data.has("blender_camera"):
		cam_data = data["blender_camera"]
		var should_convert = data.get("convert_blender_camera", convert_blender_camera)
		if cam_data.has("location"):
			var loc = cam_data["location"]
			if should_convert:
				pos = Vector3(loc[0], loc[2], -loc[1])
			else:
				pos = Vector3(loc[0], loc[1], loc[2])
		cam.position = pos
		if data.has("blender_target") and data["blender_target"].has("location"):
			var t_loc = data["blender_target"]["location"]
			if should_convert:
				target = Vector3(t_loc[0], t_loc[2], -t_loc[1])
			else:
				target = Vector3(t_loc[0], t_loc[1], t_loc[2])
			cam.look_at(target)
			print("Camera Setup (Blender): Pos=", pos, " Target=", target)
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
			print("Camera Setup (Blender): Pos=", pos, " Rotation=", cam.rotation)

	if cam_data.has("fov"): cam.fov = float(cam_data["fov"])
	add_child(cam)

# ─────────────────────────────────────────────────────────────────
# Fixed World-Space Room Lights
# One OmniLight3D per room, placed at the polygon centroid, just
# below that room's ceiling. Created ONCE — never repositioned.
# ─────────────────────────────────────────────────────────────────
func setup_fixed_fill_lights():
	# Safety: clear any lights from a previous call
	for l in get_tree().get_nodes_in_group("fill_lights"):
		l.queue_free()

	var placed = 0
	var lighting_scale = _resolve_illumination_scale(_render_data)
	var mood_fill_color = _get_color_mood_light_color("fill")

	# ── Automation colour-aware fill boost ──────────────────────────────────
	# The fills built here are video-only — image_glb_creation.gd has no
	# equivalent of this grid/ceiling/corner system. But the image path DOES
	# scale its own fills by _automationAmbientBoost, so without this the video
	# fills would be the one light group in the pipeline that ignores the
	# automation pass, and a boosted scene would come out darker as video than
	# as a still. Same key and same clamp as both *_glb_creation.gd builders.
	# _render_data is the root input JSON, which is where the pass writes.
	var _auto_ambient_boost: float = 1.0
	if typeof(_render_data) == TYPE_DICTIONARY and _render_data.has("_automationAmbientBoost"):
		_auto_ambient_boost = clampf(float(_render_data["_automationAmbientBoost"]), 0.5, 2.5)
		if _auto_ambient_boost != 1.0:
			_log_console("[AUTO-LIGHTING] Fill lights scaled by ambientBoost=%.2f" % _auto_ambient_boost)

	var energy_multiplier = 1.0
	var fixture_count = get_tree().get_nodes_in_group("fixture_lights").size()
	if day_render:
		# Keep the room bright, but leave enough contrast for window-frame shadows to read.
		energy_multiplier = 1.25
		_log_console("[VideoRender] Day Render: Fill grid at 1.25x — preserving sunlight contrast and window shadows.")
	elif fixture_count > 0 or _has_fixture_lights_cache:
		energy_multiplier = 0.5
		if fixture_count > 0:
			_log_console("[VideoRender] %d fixture lights detected. Dimming automated room fill lights (0.5x)." % fixture_count)
		else:
			_log_console("[VideoRender] Fixture lights detected in cache (but disabled in day render). Dimming automated room fill lights (0.5x).")
	elif not _has_authored_lights_cache:
		energy_multiplier = 1.75
		_log_console("[VideoRender] No authored lights detected. Boosting automated room fill lights (1.75x).")

	# Fold the automation boost into the fill multiplier. Applied here rather
	# than at each light so the grid, floor and room fills all pick it up from
	# one place; ceil_energy_base is the one exception and applies it directly,
	# because it does not read energy_multiplier.
	energy_multiplier *= _auto_ambient_boost

	# ── 1. Try floor-plan area data (preferred — one light per room) ──
	var areas = _get_floor_plan_areas()
	var verts = _get_floor_plan_vertices()

	if areas.size() > 0 and verts.size() > 0:
		for area_id in areas:
			var area = areas[area_id]
			var v_ids = area.get("vertices", [])
			if v_ids.size() < 3:
				continue

			# ── Centroid: average of all polygon vertex positions (cm → m) ──
			var sum_x = 0.0
			var sum_z = 0.0
			var count = 0
			for v_id in v_ids:
				var vs = str(v_id)
				if not verts.has(vs):
					continue
				var v = verts[vs]
				sum_x += float(v.get("x", 0)) * _scene_unit_scale
				sum_z += float(v.get("y", 0)) * _scene_unit_scale # floor-plan Y → Godot Z
				count += 1
			if count == 0:
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

			# ── Emit radius scaled to room size ──
			#    Estimate room footprint from bounding box of polygon
			var min_x = 1e9; var max_x = -1e9
			var min_z = 1e9; var max_z = -1e9
			var poly2d = PackedVector2Array()
			for v_id in v_ids:
				var vs = str(v_id)
				if not verts.has(vs): continue
				var v = verts[vs]
				var vx = float(v.get("x", 0)) * _scene_unit_scale
				var vz = float(v.get("y", 0)) * _scene_unit_scale
				min_x = min(min_x, vx); max_x = max(max_x, vx)
				min_z = min(min_z, vz); max_z = max(max_z, vz)
				poly2d.append(Vector2(vx, vz))
				
			var room_w = max(max_x - min_x, 0.5)
			var room_d = max(max_z - min_z, 0.5)
			var diag = sqrt(room_w * room_w + room_d * room_d)
			
			var fill_color = Color(1.0 * mood_fill_color.r, 0.97 * mood_fill_color.g, 0.90 * mood_fill_color.b)
			var sun_dir_flat = Vector3.ZERO
			if day_render and _dir_light:
				sun_dir_flat = - _dir_light.global_transform.basis.z
				sun_dir_flat.y = 0
				if sun_dir_flat.length() > 0.001:
					sun_dir_flat = sun_dir_flat.normalized()

			if day_render:
				# ── Day Render: Dynamic Grid Fill Lighting ──
				var spacing = clamp(min(room_w, room_d) / 4.0, 1.2, 2.5)
				# Fill grid is the room's ambient fill — sun handles the primary drama.
				# Slightly softer fill keeps the daylight believable without flattening the sun patch.
				# Drastically reduced: portal SpotLights (window + door) and ambient_light_energy=6.0
				# now handle day fill. Grid lights are kept trace-level only to prevent
				# pitch-black patches in windowless areas, not as primary fill sources.
				var grid_energy = clamp(0.28 + diag * 0.016, 0.28, 0.58) * energy_multiplier * lighting_scale * 0.1
				
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
							#add_child(light)
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
					floor_fill.light_energy = 0.35 * energy_multiplier * lighting_scale
					floor_fill.omni_range = clamp(diag + 3.0, 8.0, 20.0)
					floor_fill.shadow_enabled = false
					floor_fill.light_color = fill_color
					floor_fill.light_specular = 0.1
					floor_fill.add_to_group("fill_lights")
					add_child(floor_fill)
				_log_console("[VideoRender] Area '%s': placed %d grid fill lights." % [area_id, placed])
			else:
				# ── Night / Legacy: Center SpotLight and OmniLight ──
				var omni_range = clamp(diag + 1.5, 6.0, 16.0)
				var energy = clamp(0.8 + diag * 0.12, 0.8, 2.0)

				var light = OmniLight3D.new()
				light.name = "RoomLight_" + str(area_id)
				light.position = Vector3(cx, light_y, cz) # ← fixed world position
				light.light_energy = energy * lighting_scale * energy_multiplier
				light.omni_range = omni_range
				light.shadow_enabled = false # sun handles primary shadows; fills add brightness
				light.light_color = fill_color
				light.add_to_group("fill_lights")
				add_child(light)
				placed += 1

				# ── Ceiling Ambient Fill (OmniLight at mid-room height) ──
				# Placed at mid-room height rather than near the ceiling so that
				# inverse-square falloff gives a smooth even wash — not circular hotspot patches.
				# Deliberately ignores energy_multiplier so fixture-detection's 0.5x
				# halving does NOT starve the ceiling of light.
				var ceil_fill = OmniLight3D.new()
				ceil_fill.name = "CeilingCenterFill_" + str(area_id)
				# Mid-room height: far enough from the ceiling that the light fans out evenly.
				var ceil_fill_y = clamp(ceil_h * 0.55, 1.2, ceil_h - 0.6)
				ceil_fill.position = Vector3(cx, ceil_fill_y, cz)
				# Moderate energy — SSIL carries most ceiling bounce; this ensures base luminance.
				# Automation boost applied inside the clamp so it can lift a dark
				# room without pushing the ceiling fill past its tuned ceiling.
				var ceil_energy_base = clamp(energy * 1.26 * lighting_scale * _auto_ambient_boost, 0.72, 2.16)
				ceil_fill.light_energy = ceil_energy_base
				ceil_fill.omni_range = clamp(omni_range * 1.8 + 3.0, 12.0, 26.0)
				ceil_fill.omni_attenuation = 1.5 # Gentler falloff for softer spread
				ceil_fill.shadow_enabled = false
				ceil_fill.light_color = fill_color
				ceil_fill.light_specular = 0.12 # soft floor gloss — mid-room height avoids ceiling hotspot
				ceil_fill.add_to_group("fill_lights")
				add_child(ceil_fill)

				# ── Corner fills at mid-room height — keep ceiling edges from going dark ──
				var corner_energy = ceil_energy_base * 0.45
				var corner_range = clamp(omni_range * 1.1 + 2.0, 6.0, 16.0)
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

				_log_console("[VideoRender] Room light '%s' at (%.2f, %.2f, %.2f)  range=%.1f  energy=%.2f (multiplier=%.2f)" \
					% [area_id, cx, light_y, cz, omni_range, energy * lighting_scale * energy_multiplier, energy_multiplier])

	# ── 2. Fallback: single centre light derived from mesh AABB ──
	if placed == 0:
		print("[VideoRender] No area data found — placing single fallback fill light at scene centre.")
		var scene_center = Vector3.ZERO
		var light_y = 2.1
		var all_meshes = _get_all_meshes(self)
		if all_meshes.size() > 0:
			var combined = AABB()
			var first_m = true
			for m in all_meshes:
				var world_aabb = m.global_transform * m.get_aabb()
				if first_m: combined = world_aabb; first_m = false
				else: combined = combined.merge(world_aabb)
			scene_center = combined.get_center()
			light_y = combined.position.y + combined.size.y - 0.15
			light_y = max(light_y, scene_center.y + 1.8)

		var light = OmniLight3D.new()
		light.name = "RoomLight_Fallback"
		light.position = Vector3(scene_center.x, light_y, scene_center.z)
		light.light_energy = 1.5 * lighting_scale * energy_multiplier
		light.omni_range = 18.0
		light.shadow_enabled = false
		light.light_color = Color(1.0 * mood_fill_color.r, 0.97 * mood_fill_color.g, 0.90 * mood_fill_color.b)
		light.add_to_group("fill_lights")
		add_child(light)
		placed = 1

	_log_console("[VideoRender] %d room light(s) placed — all fixed, shadows will NOT travel with camera." % placed)

# ── Helpers: extract areas / vertices from cached floor-plan data ──
func _get_floor_plan_areas() -> Dictionary:
	var src = _render_data
	if src.has("floor_plan_data"):
		var fp = src["floor_plan_data"]
		if typeof(fp) == TYPE_STRING:
			var j = JSON.new()
			if j.parse(fp) == OK: src = j.data
		elif typeof(fp) == TYPE_DICTIONARY:
			src = fp

	var layer_map = _get_floor_plan_layer_map(src)
	if layer_map.size() > 0:
		if bool(src.get("showAllFloors", true)):
			var merged = {}
			for layer_id in layer_map:
				var layer = layer_map[layer_id]
				if typeof(layer) != TYPE_DICTIONARY:
					continue
				var raw_layer = layer.get("areas", null)
				if raw_layer == null:
					continue
				if typeof(raw_layer) == TYPE_DICTIONARY:
					for area_id in raw_layer:
						merged[str(area_id)] = raw_layer[area_id]
				elif typeof(raw_layer) == TYPE_ARRAY:
					for a in raw_layer:
						if typeof(a) == TYPE_DICTIONARY and a.has("id"):
							merged[str(a["id"])] = a
			return merged
		var primary_id = _get_primary_layer_id(src, layer_map)
		if primary_id != "" and layer_map.has(primary_id):
			src = layer_map[primary_id]

	var raw = src.get("areas", null)
	if raw == null: return {}
	if typeof(raw) == TYPE_DICTIONARY: return raw
	# Array format — convert to id-keyed dict
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

	var layer_map = _get_floor_plan_layer_map(src)
	if layer_map.size() > 0:
		if bool(src.get("showAllFloors", true)):
			var merged = {}
			for layer_id in layer_map:
				var layer = layer_map[layer_id]
				if typeof(layer) != TYPE_DICTIONARY:
					continue
				var raw_layer = layer.get("vertices", null)
				if raw_layer == null:
					continue
				if typeof(raw_layer) == TYPE_DICTIONARY:
					for vertex_id in raw_layer:
						merged[str(vertex_id)] = raw_layer[vertex_id]
				elif typeof(raw_layer) == TYPE_ARRAY:
					for v in raw_layer:
						if typeof(v) == TYPE_DICTIONARY and v.has("id"):
							merged[str(v["id"])] = v
			return merged
		var primary_id = _get_primary_layer_id(src, layer_map)
		if primary_id != "" and layer_map.has(primary_id):
			src = layer_map[primary_id]

	var raw = src.get("vertices", null)
	if raw == null: return {}
	if typeof(raw) == TYPE_DICTIONARY: return raw
	var d = {}
	for v in raw:
		if typeof(v) == TYPE_DICTIONARY and v.has("id"):
			d[str(v["id"])] = v
	return d

# ─────────────────────────────────────────────────────────────────
# Logging — save input JSON copy & render log to sibling directories
# ─────────────────────────────────────────────────────────────────
func save_logs(input_data, output_video_path):
	_log_console("Saving video render logs...")
	
	# Save logs and input_json to sibling directories (one level above godot_project)
	var project_root = ProjectSettings.globalize_path("res://")
	var parent_dir = project_root.get_base_dir() # Go up from godot_project/
	var logs_abs = parent_dir.path_join("logs")
	var input_abs = parent_dir.path_join("input_json")
	
	# Use absolute paths for both DirAccess and FileAccess
	var logs_dir = logs_abs
	var input_save_dir = input_abs
	
	if not DirAccess.dir_exists_absolute(logs_abs):
		DirAccess.make_dir_recursive_absolute(logs_abs)
	if not DirAccess.dir_exists_absolute(input_abs):
		DirAccess.make_dir_recursive_absolute(input_abs)
	
	var timestamp = str(Time.get_unix_time_from_system())
	
	# Use the output render filename as the base for log/input filenames
	var output_basename = output_video_path.get_file().get_basename()
	
	# 1. Save Input JSON copy
	var input_filename = output_basename + "_input.json"
	var input_save_path = input_save_dir.path_join(input_filename)
	
	var json_string = JSON.stringify(input_data, "\t")
	var file_input = FileAccess.open(input_save_path, FileAccess.WRITE)
	if file_input:
		file_input.store_string(json_string)
		file_input.close()
		_log_console("Saved copy of input JSON to: " + input_save_path)
	else:
		_log_console("Error saving input JSON copy to " + input_save_path)
	
	# 2. Detailed Log JSON
	var log_data = {}
	log_data["timestamp"] = timestamp
	log_data["input_file_saved"] = input_save_path
	log_data["output_video"] = output_video_path
	log_data["total_frames"] = _total_frames
	log_data["fps"] = _fps
	log_data["duration_seconds"] = float(_total_frames) / float(_fps) if _fps > 0 else 0.0
	
	# Camera Info (final frame position)
	var cam = get_node_or_null("MainCamera")
	var cam_info = {}
	if cam:
		cam_info["position"] = {"x": cam.position.x, "y": cam.position.y, "z": cam.position.z}
		cam_info["rotation_degrees"] = {"x": cam.rotation_degrees.x, "y": cam.rotation_degrees.y, "z": cam.rotation_degrees.z}
		cam_info["fov"] = cam.fov
		var forward = - cam.global_transform.basis.z.normalized()
		cam_info["look_direction_vector"] = {"x": forward.x, "y": forward.y, "z": forward.z}
	log_data["camera_final"] = cam_info
	
	log_data["camera_input_threejs"] = input_data.get("threejs_camera", {})
	log_data["camera_input_blender"] = input_data.get("blender_camera", {})
	log_data["console_log_lines"] = _console_log_lines.duplicate()
	
	var log_filename = output_basename + "_render_log.json"
	var log_path = logs_dir.path_join(log_filename)
	var console_log_path = logs_dir.path_join(output_basename + "_console.log")
	log_data["console_log_file"] = console_log_path
	
	var log_json_str = JSON.stringify(log_data, "\t")
	var file_log = FileAccess.open(log_path, FileAccess.WRITE)
	if file_log:
		file_log.store_string(log_json_str)
		file_log.close()
		_log_console("Saved video render log to: " + log_path)
	else:
		_log_console("Error saving video render log to " + log_path)

	var console_log_text := ""
	for line in _console_log_lines:
		console_log_text += str(line) + "\n"
	var file_console = FileAccess.open(console_log_path, FileAccess.WRITE)
	if file_console:
		file_console.store_string(console_log_text)
		file_console.close()
		_log_console("Saved video console log to: " + console_log_path)
	else:
		_log_console("Error saving video console log to " + console_log_path)

# ─────────────────────────────────────────────────────────────────
# Thumbnail Generation
# ─────────────────────────────────────────────────────────────────
func _save_thumbnail_webp(source_image: Image, output_path: String) -> void:
	"""Saves a small WebP thumbnail next to the render output.
	The thumbnail is saved with a '_thumb.webp' suffix in the same directory.
	Max dimension is 480px, WebP quality 75% to keep file size low."""
	if source_image == null or source_image.is_empty():
		print("Warning: Cannot create thumbnail — source image is empty.")
		return
	
	# We handle both single file paths and nested paths correctly:
	# If the output_path is .../output_renders/<uuid>/frame.avi,
	# We want the thumbnail at:  .../output_renders/<uuid>_thumb.webp
	# If the output_path is just .../video.avi, we want: .../video_thumb.webp
	var thumb_path = ""
	var inner_dir = output_path.get_base_dir()
	var folder_name = inner_dir.get_file()
	
	# Simple heuristic: if the containing folder looks like an ID (or we are in a subfolder structure)
	# and output_path ends with 'frame.avi' or similar generic name from Python
	if output_path.get_file().get_basename().begins_with("frame") and inner_dir.get_base_dir().get_file() == "output_renders":
		var parent_dir = inner_dir.get_base_dir()
		thumb_path = parent_dir.path_join(folder_name + "_thumb.webp")
	else:
		# Default fallback
		var dir = output_path.get_base_dir()
		var basename = output_path.get_file().get_basename()
		
		# Prevent doubling the _render extension if the UUID folder is used
		if basename.ends_with("_render"):
			thumb_path = dir.path_join(basename + "_thumb.webp")
		elif folder_name.length() > 20: # UUID length approx check
			thumb_path = dir.get_base_dir().path_join(folder_name + "_thumb.webp")
		else:
			thumb_path = dir.path_join(basename + "_thumb.webp")
	
	# Create a copy to avoid mutating the original image
	var thumb = source_image.duplicate()
	
	# Resize to max 480px on the longest side, preserving aspect ratio
	var max_dim = 480
	var w = thumb.get_width()
	var h = thumb.get_height()
	if w > max_dim or h > max_dim:
		if w >= h:
			var new_w = max_dim
			var new_h = int(float(h) * float(max_dim) / float(w))
			thumb.resize(new_w, max(new_h, 1), Image.INTERPOLATE_LANCZOS)
		else:
			var new_h = max_dim
			var new_w = int(float(w) * float(max_dim) / float(h))
			thumb.resize(max(new_w, 1), new_h, Image.INTERPOLATE_LANCZOS)
	
	# Save as WebP with lossy compression (quality 0.75 = 75%)
	var err = thumb.save_webp(thumb_path, true, 0.75)
	if err == OK:
		print("Thumbnail saved to: ", thumb_path)
	else:
		print("Warning: Failed to save thumbnail. Error code: ", err)
