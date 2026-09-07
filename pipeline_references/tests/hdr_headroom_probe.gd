extends SceneTree

## Scene HDR headroom probe.
##
##   bin\godot.windows.editor.x86_64.console.exe --headless --path pipeline_references \
##       -s res://tests/hdr_headroom_probe.gd -- <file.exr> [more.exr ...]
##
## Reports the LINEAR value range of an HDR panorama, using the engine's own
## loader -- the same one set_environment() feeds to PanoramaSkyMaterial.
##
## WHY THIS EXISTS. A tonemapper can only roll off dynamic range that is present.
## AgX maps linear 1.0 to about 0.80 sRGB and needs roughly linear 10 to reach
## 0.98; so if the brightest thing in a daylight interior -- the sky seen through
## the window -- tops out near 1.0 linear, the render is mathematically incapable
## of producing a highlight, no matter what the tonemapper, camera or sampler do.
## The image then occupies a narrow midtone band and reads flat and washed out.
##
## A panorama that is nominally "HDR" because of its .exr container but whose
## values were normalised to ~1.0 is exactly this failure, and it is invisible in
## every viewer that tonemaps on display.

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		printerr("usage: -s res://tests/hdr_headroom_probe.gd -- <file.exr> [...]")
		quit(2)
		return

	var failures := 0
	for path in args:
		if not _probe(str(path)):
			failures += 1
	quit(1 if failures > 0 else 0)


func _probe(path: String) -> bool:
	print("")
	print("=== HDR headroom: %s ===" % path)
	if not FileAccess.file_exists(path):
		printerr("  file not found")
		return false

	var img := Image.load_from_file(path)
	if img == null or img.is_empty():
		printerr("  loader returned nothing")
		return false

	print("  %dx%d  format=%d  mipmaps=%s" % [img.get_width(), img.get_height(), img.get_format(), img.has_mipmaps()])

	# Sample on a grid rather than every texel: a 4k panorama is 8 M pixels and
	# get_pixel() through the binding is slow. 400 x 200 is dense enough to land
	# on the sun disc if there is one, which is the value that matters.
	var w := img.get_width()
	var h := img.get_height()
	var sx: int = max(1, w / 400)
	var sy: int = max(1, h / 200)

	var vmax := 0.0
	var vsum := 0.0
	var n := 0
	var over_1 := 0
	var over_4 := 0
	var over_16 := 0
	var max_at := Vector2i.ZERO

	for y in range(0, h, sy):
		for x in range(0, w, sx):
			var c := img.get_pixel(x, y)
			# Luminance, not max channel: a single hot channel is a coloured light,
			# not headroom.
			var l: float = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
			vsum += l
			n += 1
			if l > 1.0: over_1 += 1
			if l > 4.0: over_4 += 1
			if l > 16.0: over_16 += 1
			if l > vmax:
				vmax = l
				max_at = Vector2i(x, y)

	var mean: float = vsum / float(max(n, 1))
	print("  samples          : %d" % n)
	print("  mean luminance   : %.4f" % mean)
	print("  MAX luminance    : %.4f  at (%d,%d)" % [vmax, max_at.x, max_at.y])
	print("  headroom (max/mean): %.1fx" % (vmax / max(mean, 1e-6)))
	print("  fraction > 1.0   : %.3f%%" % (100.0 * over_1 / max(n, 1)))
	print("  fraction > 4.0   : %.3f%%" % (100.0 * over_4 / max(n, 1)))
	print("  fraction > 16.0  : %.3f%%" % (100.0 * over_16 / max(n, 1)))

	# What AgX does with that peak. Constants mirror allenwp_curve() in
	# servers/rendering/renderer_rd/shaders/effects/tonemap.glsl and its parameter
	# derivation in servers/rendering/storage/environment_storage.cpp.
	print("  -> AgX(max) at exposure 1.0 = %.3f sRGB" % _agx_srgb(vmax))
	print("  -> AgX(max) at exposure 1.3 = %.3f sRGB" % _agx_srgb(vmax * 1.3))
	print("  (a real daylight sky wants max/mean in the hundreds and fraction>16 nonzero)")

	if vmax < 4.0:
		printerr("  VERDICT: no usable headroom. The brightest sky sample is %.2f linear;" % vmax)
		printerr("           AgX cannot produce a highlight from that, so a window lit by")
		printerr("           this panorama can never blow out and the frame will read flat.")
		return false
	print("  VERDICT: has headroom.")
	return true


## Scalar AgX + sRGB OETF, for reporting only. Skips the inset/outset matrices,
## which are chroma operations and near-identity on a neutral value.
func _agx_srgb(x: float) -> float:
	const CROSSOVER := 0.18
	const OUT_MAX := 1.0
	const SHOULDER_MAX := OUT_MAX - CROSSOVER
	var contrast := 1.25 # Environment::tonemap_agx_contrast default.
	var white := 16.29 # tonemap_agx_white used by the day profile.

	var toe_a: float = ((1.0 / CROSSOVER) - 1.0) * pow(CROSSOVER, contrast)
	var denom: float = pow(CROSSOVER, contrast) + toe_a
	var slope: float = (contrast * pow(CROSSOVER, contrast - 1.0) * toe_a) / (denom * denom)
	var wv: float = (white - CROSSOVER) * (white - CROSSOVER) / SHOULDER_MAX * slope

	var out := 0.0
	if x < CROSSOVER:
		var t: float = pow(max(x, 0.0), contrast)
		out = t / (t + toe_a)
	else:
		var s: float = x - CROSSOVER
		var ss: float = slope * s
		out = ss * (1.0 + s / wv) / (1.0 + ss / SHOULDER_MAX) + CROSSOVER
	out = clampf(out, 0.0, OUT_MAX)
	return out * 12.92 if out <= 0.0031308 else 1.055 * pow(out, 1.0 / 2.4) - 0.055
