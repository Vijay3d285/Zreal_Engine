extends Node

## 16-bit PNG encoding gate.
##
##   bin\godot.windows.editor.x86_64.console.exe --path pipeline_references \
##       res://tests/png16_encoding_gate_scene.tscn
##
## WHAT THIS PROVES, AND WHY NOTHING ELSE PROVES IT.
##
## The defect this feature exists to fix is INVISIBLE in the output of the thing
## that produced it. Godot's stock image_to_png() drives libpng's *simplified*
## API, whose `default:` branch converts any float or half image down to
## RGB8/RGBA8 before a single byte is written. The result is still a valid PNG,
## still opens everywhere, still looks right -- it has simply lost 8 bits per
## channel before the file existed. And the failure mode of the FIX has the same
## shape: a 16-bit writer fed an 8-bit source emits 256 distinct levels padded
## out to 16 bits, i.e. a 50 MB file carrying 8 bits of information.
##
## So "the render looks fine" and "the file is 40 MB" are both worthless as
## evidence. The only falsifiable measurement is to decode the bytes and COUNT
## THE DISTINCT LEVELS. That is what LEVELS below does, and it is the one check
## here that an 8-bit path cannot pass: a ramp encoded through RGB8 caps at 256
## distinct values no matter how many bits the container claims.
##
## Every check reads the actual file bytes -- IHDR fields, and samples recovered
## from the IDAT stream. Nothing here trusts Image.load_png_from_buffer(), which
## would down-convert to 8 bits on the way back in and destroy the very quantity
## under test.
##
## Every check but the last exercises the encoder alone -- no scene, no rays --
## so the gate finishes in about a second and cannot be perturbed by path-tracer
## noise (renders in this fork are not reproducible frame to frame).
##
## The last check, HDR_CONTRACT, covers the other half of the feature: the encoder
## is worthless if render.gd hands it an image that is already 8-bit, and every
## check above would still pass in that case. It needs a real rendering device, so
## run this gate WITHOUT --headless -- under the dummy driver the readback returns
## nothing and the check degrades to a SKIP, which proves nothing.

const TMP_DIR := "user://png16_gate"

var _failures: Array[String] = []
var _checks := 0


func _ready() -> void:
	print("")
	print("=== 16-bit PNG encoding gate ===")

	DirAccess.make_dir_recursive_absolute(TMP_DIR)

	if not Image.new().has_method("save_png16"):
		_fail("PRECONDITION",
				"Image.save_png16 is not bound in this binary. The engine was built " +
				"without the 16-bit writer, so every other check below would be " +
				"vacuous. Rebuild: python -m SCons platform=windows target=editor " +
				"arch=x86_64 d3d12=no")
		_report()
		return

	_check_ihdr_rgb()
	_check_ihdr_rgba()
	_check_levels()
	_check_srgb_oetf()
	_check_alpha_is_linear()
	_check_linear_mode()
	_check_clipping()
	_check_stored_compression()
	await _check_hdr_contract()

	_report()


# ── checks ────────────────────────────────────────────────────────────────────

func _check_ihdr_rgb() -> void:
	# FORMAT_RGBH is what an HDR (use_hdr_2d) viewport readback of a non-transparent
	# render target actually returns -- texture_storage.cpp picks RGBH vs RGBAH from
	# rt->is_transparent, not from the pixels. Alpha must therefore be decided by the
	# FORMAT, and a half-float source must survive to 16 bits.
	var png := _encode(_ramp_image(64, Image.FORMAT_RGBH), 0, true)
	var ihdr := _read_ihdr(png)
	_expect("IHDR/RGB depth", ihdr.get("bit_depth", -1), 16,
			"a float source was quantised before the write")
	_expect("IHDR/RGB colour type", ihdr.get("color_type", -1), 2,
			"expected PNG_COLOR_TYPE_RGB for an alpha-less source format")


func _check_ihdr_rgba() -> void:
	var png := _encode(_ramp_image(64, Image.FORMAT_RGBAF), 0, true)
	var ihdr := _read_ihdr(png)
	_expect("IHDR/RGBA depth", ihdr.get("bit_depth", -1), 16, "")
	_expect("IHDR/RGBA colour type", ihdr.get("color_type", -1), 6,
			"expected PNG_COLOR_TYPE_RGB_ALPHA for a source format with alpha")


func _check_levels() -> void:
	# THE CHECK THAT AN 8-BIT PATH CANNOT PASS.
	#
	# 4096 pixels carrying 4096 distinct linear values. Encoded at 8 bits the
	# recovered set caps at 256 by construction; at 16 bits it is bounded only by
	# how many of those values the sRGB curve keeps apart. Asserting > 256 is what
	# makes this falsifiable -- it fails, loudly, on exactly the regression that
	# reintroduces the simplified-API path, and cannot pass by accident.
	var w := 4096
	var png := _encode(_ramp_image(w, Image.FORMAT_RGBF), 0, true)
	var samples := _decode_samples(png)
	if samples.is_empty():
		_fail("LEVELS", "could not recover samples from the IDAT stream")
		return
	var seen := {}
	for x in range(w):
		seen[samples[x * 3]] = true
	var distinct: int = seen.size()
	_checks += 1
	if distinct > 256:
		print("  PASS  LEVELS               %d distinct levels across a %d-step ramp (8-bit caps at 256)" % [distinct, w])
	else:
		_fail("LEVELS",
				"%d distinct levels across a %d-step ramp. At or below 256 means the " % [distinct, w] +
				"image was quantised to 8 bits somewhere before the write -- the file " +
				"is 16-bit padding around 8-bit data.")


func _check_srgb_oetf() -> void:
	# The transfer function is the half of this feature that fails SILENTLY.
	# A wrong OETF still produces a well-formed 16-bit PNG; it just comes out dark
	# or washed out, and there is no error anywhere to attribute it to. So check the
	# curve numerically, at values chosen to straddle the linear/power-segment knee
	# at 0.0031308 rather than only in the comfortable midtones.
	var probes: Array[float] = [
		0.0, 0.0005, 0.0031308, 0.0032, 0.01, 0.05, 0.18, 0.5, 0.9, 1.0,
	]
	var img := Image.create_empty(probes.size(), 1, false, Image.FORMAT_RGBF)
	for i in range(probes.size()):
		img.set_pixel(i, 0, Color(probes[i], probes[i], probes[i], 1.0))
	var samples := _decode_samples(_encode(img, 0, true))
	if samples.is_empty():
		_fail("SRGB_OETF", "could not recover samples from the IDAT stream")
		return
	var worst := 0
	var worst_at := 0.0
	for i in range(probes.size()):
		var want: int = int(round(_srgb_oetf(probes[i]) * 65535.0))
		var got: int = samples[i * 3]
		var delta: int = abs(got - want)
		if delta > worst:
			worst = delta
			worst_at = probes[i]
	_checks += 1
	if worst <= 1:
		print("  PASS  SRGB_OETF            exact to +/-%d LSB over %d probes" % [worst, probes.size()])
	else:
		_fail("SRGB_OETF",
				"off by %d LSB at linear %f. Anything beyond 1 LSB means the encoder " % [worst, worst_at] +
				"is not applying the sRGB OETF that the linear HDR buffer requires.")


func _check_alpha_is_linear() -> void:
	# Alpha is coverage, not colour. sRGB-encoding it would make every partially
	# transparent pixel composite wrong, and would do so without any visible artefact
	# in the opaque majority of the frame that anyone would think to look at.
	var a := 0.25
	var img := Image.create_empty(1, 1, false, Image.FORMAT_RGBAF)
	img.set_pixel(0, 0, Color(0.5, 0.5, 0.5, a))
	var samples := _decode_samples(_encode(img, 0, true))
	if samples.is_empty():
		_fail("ALPHA_LINEAR", "could not recover samples from the IDAT stream")
		return
	var want_linear: int = int(round(a * 65535.0))
	var want_encoded: int = int(round(_srgb_oetf(a) * 65535.0))
	_checks += 1
	if abs(samples[3] - want_linear) <= 1:
		print("  PASS  ALPHA_LINEAR         alpha stored linear (%d, not the sRGB-encoded %d)" % [samples[3], want_encoded])
	else:
		_fail("ALPHA_LINEAR",
				"alpha stored as %d; expected %d (linear). %d would mean the OETF was " % [samples[3], want_linear, want_encoded] +
				"applied to the alpha channel too.")


func _check_linear_mode() -> void:
	# srgb_encode = false is the mode for a buffer that is ALREADY encoded. If it
	# quietly applied the curve anyway, the non-HDR fallback path would double-encode.
	var v := 0.25
	var img := Image.create_empty(1, 1, false, Image.FORMAT_RGBF)
	img.set_pixel(0, 0, Color(v, v, v, 1.0))
	var samples := _decode_samples(_encode(img, 0, false))
	if samples.is_empty():
		_fail("LINEAR_MODE", "could not recover samples from the IDAT stream")
		return
	_expect_near("LINEAR_MODE", samples[0], int(round(v * 65535.0)), 1,
			"srgb_encode = false must store the value unchanged")


func _check_clipping() -> void:
	# Above SDR white clips exactly as an 8-bit save would -- the gain from 16 bits
	# is precision BELOW white, not extra range. Negatives (and NaN) land on zero
	# rather than wrapping, which is what a raw cast would do.
	var img := Image.create_empty(2, 1, false, Image.FORMAT_RGBF)
	img.set_pixel(0, 0, Color(4.0, 4.0, 4.0, 1.0))
	img.set_pixel(1, 0, Color(-1.0, -1.0, -1.0, 1.0))
	var samples := _decode_samples(_encode(img, 0, true))
	if samples.is_empty():
		_fail("CLIPPING", "could not recover samples from the IDAT stream")
		return
	_expect("CLIPPING/over", samples[0], 65535, "values above 1.0 must clip to white, not wrap")
	_expect("CLIPPING/under", samples[3], 0, "negative values must clamp to 0, not wrap")


func _check_stored_compression() -> void:
	# "0% compression" is not a file-size preference, it is a specific encoder state:
	# zlib stored blocks and no per-row filtering. Checking the filter byte is the
	# cheap way to see that png_set_filter(PNG_FILTER_NONE) actually took effect --
	# with nothing being deflated, filtering would only scramble the bytes.
	var w := 128
	var png := _encode(_ramp_image(w, Image.FORMAT_RGBF), 0, true)
	var raw := _inflate_idat(png, 1, w, 3)
	if raw.is_empty():
		_fail("STORED", "could not inflate the IDAT stream")
		return
	_expect("STORED/filter byte", int(raw[0]), 0,
			"compression 0 should also select PNG_FILTER_NONE")

	# And the payload really is 16-bit-wide: one row is 1 filter byte + w * 3 * 2.
	_expect("STORED/row stride", raw.size(), 1 + w * 3 * 2,
			"a row of this width should be %d bytes at 16 bits per channel" % (1 + w * 3 * 2))


func _check_hdr_contract() -> void:
	# The encoder half of this feature is worthless without the framebuffer half.
	# render.gd sets use_hdr_2d for stills so that get_image() returns RGBH rather
	# than RGB8; without it the writer would faithfully store 8 bits of information
	# in a 16-bit container and every check above would still pass.
	#
	# This gate runs headless with its own viewport, so it asserts the mechanism
	# (turning the flag on changes the readback format), not render.gd's policy.
	var vp := get_viewport()
	if vp == null:
		_skip("HDR_CONTRACT", "no viewport in this context")
		return
	var was: bool = vp.use_hdr_2d
	vp.use_hdr_2d = true
	await RenderingServer.frame_post_draw
	var img: Image = vp.get_texture().get_image()
	vp.use_hdr_2d = was
	if img == null or img.is_empty():
		_skip("HDR_CONTRACT", "viewport readback returned nothing (headless driver)")
		return
	var fmt: int = img.get_format()
	_checks += 1
	if fmt == Image.FORMAT_RGBH or fmt == Image.FORMAT_RGBAH:
		print("  PASS  HDR_CONTRACT         use_hdr_2d readback is half-float (format %d)" % fmt)
	else:
		_fail("HDR_CONTRACT",
				"use_hdr_2d = true still reads back format %d, not RGBH/RGBAH. The " % fmt +
				"16-bit writer would then be storing 8 bits of information in a " +
				"16-bit file.")


# ── helpers ───────────────────────────────────────────────────────────────────

func _srgb_oetf(v: float) -> float:
	if v <= 0.0:
		return 0.0
	var e: float = v * 12.92 if v <= 0.0031308 else 1.055 * pow(v, 1.0 / 2.4) - 0.055
	return min(e, 1.0)


func _ramp_image(width: int, fmt: int) -> Image:
	var img := Image.create_empty(width, 1, false, fmt)
	for x in range(width):
		var v := float(x) / float(max(width - 1, 1))
		img.set_pixel(x, 0, Color(v, v, v, 1.0))
	return img


## Encodes through the real file path, then reads the file back. Going via disk
## rather than save_png16_to_buffer() means a broken ResourceSaverPNG wiring shows
## up here too, not just a broken PNGDriverCommon.
func _encode(img: Image, compression: int, srgb: bool) -> PackedByteArray:
	var path: String = TMP_DIR.path_join("gate_%d.png" % Time.get_ticks_usec())
	var err: int = img.call("save_png16", path, compression, srgb)
	if err != OK:
		_fail("ENCODE", "save_png16 returned error %d" % err)
		return PackedByteArray()
	var bytes := FileAccess.get_file_as_bytes(path)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	return bytes


func _read_ihdr(png: PackedByteArray) -> Dictionary:
	if png.size() < 33:
		return {}
	# 8-byte signature, then length(4) + "IHDR"(4) + 13 bytes of data.
	if png.slice(12, 16).get_string_from_ascii() != "IHDR":
		return {}
	return {
		"width": _be32(png, 16),
		"height": _be32(png, 20),
		"bit_depth": int(png[24]),
		"color_type": int(png[25]),
	}


## Concatenates every IDAT chunk and inflates it.
##
## Godot's COMPRESSION_DEFLATE is NOT raw deflate: Compression::decompress passes
## window_bits = 15 to inflateInit2 (core/io/compression.cpp), which expects the
## 2-byte zlib wrapper -- exactly what an IDAT stream carries. So hand it the bytes
## untouched. Stripping the header (the raw-deflate convention) makes inflate fail
## with a bare "Condition err != 1 is true" and no hint as to why.
func _inflate_idat(png: PackedByteArray, height: int, width: int, channels: int) -> PackedByteArray:
	var idat := PackedByteArray()
	var pos := 8
	while pos + 8 <= png.size():
		var length: int = _be32(png, pos)
		var kind: String = png.slice(pos + 4, pos + 8).get_string_from_ascii()
		if kind == "IDAT":
			idat.append_array(png.slice(pos + 8, pos + 8 + length))
		elif kind == "IEND":
			break
		pos += 12 + length
	if idat.size() < 3:
		return PackedByteArray()
	var expected: int = height * (1 + width * channels * 2)
	var out: PackedByteArray = idat.decompress(expected, FileAccess.COMPRESSION_DEFLATE)
	if out.size() != expected:
		return PackedByteArray()
	return out


## Returns big-endian 16-bit samples for a single-row image, filter bytes removed.
func _decode_samples(png: PackedByteArray) -> PackedInt32Array:
	var ihdr := _read_ihdr(png)
	if ihdr.is_empty():
		return PackedInt32Array()
	var width: int = ihdr["width"]
	var height: int = ihdr["height"]
	var channels: int = 4 if ihdr["color_type"] == 6 else 3
	var raw := _inflate_idat(png, height, width, channels)
	if raw.is_empty():
		return PackedInt32Array()
	# Only PNG_FILTER_NONE rows are handled -- which is exactly what compression 0
	# emits, and every caller here encodes at 0. A filtered row would decode to
	# garbage rather than to a wrong-but-plausible number, so bail loudly instead.
	var out := PackedInt32Array()
	var stride: int = 1 + width * channels * 2
	for y in range(height):
		var base: int = y * stride
		if raw[base] != 0:
			return PackedInt32Array()
		for i in range(width * channels):
			var o: int = base + 1 + i * 2
			out.append((int(raw[o]) << 8) | int(raw[o + 1]))
	return out


func _be32(b: PackedByteArray, at: int) -> int:
	return (int(b[at]) << 24) | (int(b[at + 1]) << 16) | (int(b[at + 2]) << 8) | int(b[at + 3])


# ── reporting ─────────────────────────────────────────────────────────────────

func _expect(label: String, got, want, why: String) -> void:
	_checks += 1
	if got == want:
		print("  PASS  %-20s %s" % [label, str(got)])
	else:
		_fail(label, "got %s, expected %s%s" % [str(got), str(want), ("" if why.is_empty() else " -- " + why)])


func _expect_near(label: String, got: int, want: int, tol: int, why: String) -> void:
	_checks += 1
	if abs(got - want) <= tol:
		print("  PASS  %-20s %d (want %d +/-%d)" % [label, got, want, tol])
	else:
		_fail(label, "got %d, expected %d +/-%d -- %s" % [got, want, tol, why])


func _skip(label: String, why: String) -> void:
	print("  SKIP  %-20s %s" % [label, why])


func _fail(label: String, why: String) -> void:
	_failures.append("%s: %s" % [label, why])
	printerr("  FAIL  %-20s %s" % [label, why])


func _report() -> void:
	print("")
	if _failures.is_empty():
		print("=== png16 encoding gate PASSED (%d checks) ===" % _checks)
		get_tree().quit(0)
	else:
		printerr("=== png16 encoding gate FAILED: %d failure(s) over %d checks ===" % [_failures.size(), _checks])
		for f in _failures:
			printerr("    " + f)
		get_tree().quit(1)
