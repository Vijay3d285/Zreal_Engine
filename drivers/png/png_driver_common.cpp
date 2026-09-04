/**************************************************************************/
/*  png_driver_common.cpp                                                 */
/**************************************************************************/
/*                         This file is part of:                          */
/*                             GODOT ENGINE                               */
/*                        https://godotengine.org                         */
/**************************************************************************/
/* Copyright (c) 2014-present Godot Engine contributors (see AUTHORS.md). */
/* Copyright (c) 2007-2014 Juan Linietsky, Ariel Manzur.                  */
/*                                                                        */
/* Permission is hereby granted, free of charge, to any person obtaining  */
/* a copy of this software and associated documentation files (the        */
/* "Software"), to deal in the Software without restriction, including    */
/* without limitation the rights to use, copy, modify, merge, publish,    */
/* distribute, sublicense, and/or sell copies of the Software, and to     */
/* permit persons to whom the Software is furnished to do so, subject to  */
/* the following conditions:                                              */
/*                                                                        */
/* The above copyright notice and this permission notice shall be         */
/* included in all copies or substantial portions of the Software.        */
/*                                                                        */
/* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,        */
/* EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF     */
/* MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. */
/* IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY   */
/* CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,   */
/* TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE      */
/* SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.                 */
/**************************************************************************/

#include "png_driver_common.h"

#include "core/math/math_funcs.h"

#ifdef TOOLS_ENABLED
#include "core/config/engine.h"
#endif

#include <png.h>

#include <string.h>

namespace PNGDriverCommon {

// Print any warnings.
// On error, set explain and return true.
// Call should be wrapped in ERR_FAIL_COND
static bool check_error(const png_image &image) {
	const png_uint_32 failed = PNG_IMAGE_FAILED(image);
	if (failed & PNG_IMAGE_ERROR) {
		return true;
	} else if (failed) {
#ifdef TOOLS_ENABLED
		// suppress this warning, to avoid log spam when opening assetlib
		const static char *const noisy = "iCCP: known incorrect sRGB profile";
		const Engine *const eng = Engine::get_singleton();
		if (eng && eng->is_editor_hint() && !strcmp(image.message, noisy)) {
			return false;
		}
#endif
		WARN_PRINT(image.message);
	}
	return false;
}

Error png_to_image(const uint8_t *p_source, size_t p_size, bool p_force_linear, Ref<Image> p_image) {
	png_image png_img;
	memset(&png_img, 0, sizeof(png_img));
	png_img.version = PNG_IMAGE_VERSION;

	// fetch image properties
	int success = png_image_begin_read_from_memory(&png_img, p_source, p_size);
	ERR_FAIL_COND_V_MSG(check_error(png_img), ERR_FILE_CORRUPT, png_img.message);
	ERR_FAIL_COND_V(!success, ERR_FILE_CORRUPT);

	// flags to be masked out of input format to give target format
	const png_uint_32 format_mask = ~(
			// convert component order to RGBA
			PNG_FORMAT_FLAG_BGR | PNG_FORMAT_FLAG_AFIRST
			// convert 16 bit components to 8 bit
			| PNG_FORMAT_FLAG_LINEAR
			// convert indexed image to direct color
			| PNG_FORMAT_FLAG_COLORMAP);

	png_img.format &= format_mask;

	Image::Format dest_format;
	switch (png_img.format) {
		case PNG_FORMAT_GRAY:
			dest_format = Image::FORMAT_L8;
			break;
		case PNG_FORMAT_GA:
			dest_format = Image::FORMAT_LA8;
			break;
		case PNG_FORMAT_RGB:
			dest_format = Image::FORMAT_RGB8;
			break;
		case PNG_FORMAT_RGBA:
			dest_format = Image::FORMAT_RGBA8;
			break;
		default:
			png_image_free(&png_img); // only required when we return before finish_read
			ERR_PRINT("Unsupported png format.");
			return ERR_UNAVAILABLE;
	}

	if (!p_force_linear) {
		// assume 16 bit pngs without sRGB or gAMA chunks are in sRGB format
		png_img.flags |= PNG_IMAGE_FLAG_16BIT_sRGB;
	}

	const png_uint_32 stride = PNG_IMAGE_ROW_STRIDE(png_img);
	Vector<uint8_t> buffer;
	Error err = buffer.resize(PNG_IMAGE_BUFFER_SIZE(png_img, stride));
	if (err) {
		png_image_free(&png_img); // only required when we return before finish_read
		return err;
	}
	uint8_t *writer = buffer.ptrw();

	// read image data to buffer and release libpng resources
	success = png_image_finish_read(&png_img, nullptr, writer, stride, nullptr);
	ERR_FAIL_COND_V_MSG(check_error(png_img), ERR_FILE_CORRUPT, png_img.message);
	ERR_FAIL_COND_V(!success, ERR_FILE_CORRUPT);

	//print_line("png width: "+itos(png_img.width)+" height: "+itos(png_img.height));
	p_image->set_data(png_img.width, png_img.height, false, dest_format, buffer);

	return OK;
}

Error image_to_png(const Ref<Image> &p_image, Vector<uint8_t> &p_buffer) {
	Ref<Image> source_image = p_image->duplicate();

	if (source_image->is_compressed()) {
		source_image->decompress();
	}

	ERR_FAIL_COND_V(source_image->is_compressed(), FAILED);

	png_image png_img;
	memset(&png_img, 0, sizeof(png_img));
	png_img.version = PNG_IMAGE_VERSION;
	png_img.width = source_image->get_width();
	png_img.height = source_image->get_height();

	switch (source_image->get_format()) {
		case Image::FORMAT_L8:
			png_img.format = PNG_FORMAT_GRAY;
			break;
		case Image::FORMAT_LA8:
			png_img.format = PNG_FORMAT_GA;
			break;
		case Image::FORMAT_RGB8:
			png_img.format = PNG_FORMAT_RGB;
			break;
		case Image::FORMAT_RGBA8:
			png_img.format = PNG_FORMAT_RGBA;
			break;
		default:
			if (source_image->detect_alpha() != Image::ALPHA_NONE) {
				source_image->convert(Image::FORMAT_RGBA8);
				png_img.format = PNG_FORMAT_RGBA;
			} else {
				source_image->convert(Image::FORMAT_RGB8);
				png_img.format = PNG_FORMAT_RGB;
			}
	}

	const Vector<uint8_t> image_data = source_image->get_data();
	const uint8_t *reader = image_data.ptr();

	// we may be passed a buffer with existing content we're expected to append to
	const int buffer_offset = p_buffer.size();

	const size_t png_size_estimate = PNG_IMAGE_PNG_SIZE_MAX(png_img);

	// try with estimated size
	size_t compressed_size = png_size_estimate;
	int success = 0;
	{ // scope writer lifetime
		Error err = p_buffer.resize(buffer_offset + png_size_estimate);
		ERR_FAIL_COND_V(err, err);

		uint8_t *writer = p_buffer.ptrw();
		success = png_image_write_to_memory(&png_img, &writer[buffer_offset],
				&compressed_size, 0, reader, 0, nullptr);
		ERR_FAIL_COND_V_MSG(check_error(png_img), FAILED, png_img.message);
	}
	if (!success) {
		// buffer was big enough, must be some other error
		ERR_FAIL_COND_V(compressed_size <= png_size_estimate, FAILED);

		// write failed due to buffer size, resize and retry
		Error err = p_buffer.resize(buffer_offset + compressed_size);
		ERR_FAIL_COND_V(err, err);

		uint8_t *writer = p_buffer.ptrw();
		success = png_image_write_to_memory(&png_img, &writer[buffer_offset],
				&compressed_size, 0, reader, 0, nullptr);
		ERR_FAIL_COND_V_MSG(check_error(png_img), FAILED, png_img.message);
		ERR_FAIL_COND_V(!success, FAILED);
	}

	// trim buffer size to content
	Error err = p_buffer.resize(buffer_offset + compressed_size);
	ERR_FAIL_COND_V(err, err);

	return OK;
}

// --- 16-bit PNG writer -------------------------------------------------------
//
// image_to_png() above goes through libpng's *simplified* API, whose `default:`
// branch converts any float or half image down to RGB8/RGBA8 before a single
// byte is written. The quantisation happens before the file exists, so no
// encoder option can recover it. This writer drives the full libpng API instead
// (png_create_write_struct / png_set_IHDR / png_write_row) so it can emit
// PNG_COLOR_TYPE_RGB or PNG_COLOR_TYPE_RGB_ALPHA at bit depth 16 — matching
// Blender's default still output.

namespace {

// Growing memory sink for png_set_write_fn(). libpng emits in ~8 KiB chunks, so
// a Vector::resize() per chunk would be O(n^2) — thousands of full-buffer copies
// on a 50 MB file. Capacity doubles instead, and the buffer is trimmed once at
// the end.
struct PNG16Sink {
	Vector<uint8_t> *buffer = nullptr;
	size_t base = 0; // Bytes already present in *buffer when we started appending.
	size_t size = 0; // Bytes written past `base`.
	size_t capacity = 0; // Bytes reserved past `base`.
	bool failed = false;
};

void PNGCBAPI _png16_write(png_structp p_png, png_bytep p_data, png_size_t p_length) {
	PNG16Sink *sink = static_cast<PNG16Sink *>(png_get_io_ptr(p_png));
	if (sink == nullptr || sink->failed) {
		return;
	}
	if (sink->size + p_length > sink->capacity) {
		size_t new_capacity = sink->capacity > 0 ? sink->capacity : (size_t)65536;
		while (new_capacity < sink->size + p_length) {
			new_capacity *= 2;
		}
		if (sink->buffer->resize(sink->base + new_capacity) != OK) {
			sink->failed = true;
			return;
		}
		sink->capacity = new_capacity;
	}
	memcpy(sink->buffer->ptrw() + sink->base + sink->size, p_data, p_length);
	sink->size += p_length;
}

void PNGCBAPI _png16_flush(png_structp p_png) {
	// Nothing to flush: the sink is memory.
	(void)p_png;
}

} // namespace

Error image_to_png16(const Ref<Image> &p_image, Vector<uint8_t> &p_buffer, int p_compression_level, bool p_srgb_encode) {
	ERR_FAIL_COND_V(p_image.is_null(), ERR_INVALID_PARAMETER);
	ERR_FAIL_COND_V(p_image->is_empty(), ERR_INVALID_PARAMETER);

	Ref<Image> source_image = p_image->duplicate();
	if (source_image->is_compressed()) {
		source_image->decompress();
	}
	ERR_FAIL_COND_V(source_image->is_compressed(), FAILED);

	// Alpha comes from the FORMAT, not detect_alpha(): an HDR viewport readback is
	// FORMAT_RGBH, which has no alpha channel at all, and detect_alpha() would walk
	// every one of 8.3 M pixels only to reach the same conclusion.
	const bool has_alpha = (Image::get_format_component_mask(source_image->get_format()) & 8) != 0;
	const Image::Format work_format = has_alpha ? Image::FORMAT_RGBAF : Image::FORMAT_RGBF;

	// Convert to full float first. Converting to an 8-bit format would discard
	// exactly the precision this function exists to preserve. RGBH -> RGBF crosses
	// _are_formats_compatible()'s group boundary, so convert() takes its generic
	// per-pixel path: slower, but unclamped.
	source_image->convert(work_format);
	ERR_FAIL_COND_V(source_image->get_format() != work_format, FAILED);

	const int width = source_image->get_width();
	const int height = source_image->get_height();
	const int components = has_alpha ? 4 : 3;
	ERR_FAIL_COND_V(width <= 0 || height <= 0, ERR_INVALID_PARAMETER);

	const Vector<uint8_t> src_data = source_image->get_data();
	ERR_FAIL_COND_V((int64_t)src_data.size() < (int64_t)width * height * components * 4, FAILED);
	const float *src = (const float *)src_data.ptr();

	// Everything non-trivial is declared BEFORE setjmp(): a local written between
	// setjmp() and longjmp() has an indeterminate value in the error path.
	const int buffer_offset = p_buffer.size();

	PNG16Sink sink;
	sink.buffer = &p_buffer;
	sink.base = (size_t)buffer_offset;

	Vector<uint8_t> row;
	{
		Error row_err = row.resize((int64_t)width * components * 2);
		ERR_FAIL_COND_V(row_err, row_err);
	}
	uint8_t *row_ptr = row.ptrw();

	png_structp png = png_create_write_struct(PNG_LIBPNG_VER_STRING, nullptr, nullptr, nullptr);
	ERR_FAIL_NULL_V(png, FAILED);

	png_infop info = png_create_info_struct(png);
	if (info == nullptr) {
		png_destroy_write_struct(&png, nullptr);
		ERR_FAIL_V(FAILED);
	}

	if (setjmp(png_jmpbuf(png))) {
		png_destroy_write_struct(&png, &info);
		p_buffer.resize(buffer_offset);
		ERR_FAIL_V_MSG(FAILED, "libpng failed while writing a 16-bit PNG.");
	}

	png_set_write_fn(png, &sink, _png16_write, _png16_flush);
	png_set_compression_level(png, CLAMP(p_compression_level, 0, 9));
	if (p_compression_level <= 0) {
		// Nothing is being deflated, so per-row filtering only scrambles the bytes
		// and costs an extra pass over ~50 MB. This is the "Compression 0%" case.
		png_set_filter(png, 0, PNG_FILTER_NONE);
	}

	png_set_IHDR(png, info, (png_uint_32)width, (png_uint_32)height, 16,
			has_alpha ? PNG_COLOR_TYPE_RGB_ALPHA : PNG_COLOR_TYPE_RGB,
			PNG_INTERLACE_NONE, PNG_COMPRESSION_TYPE_DEFAULT, PNG_FILTER_TYPE_DEFAULT);

	if (p_srgb_encode) {
		// Tag the colour space so viewers do not second-guess the transfer function.
		png_set_sRGB_gAMA_and_cHRM(png, info, PNG_sRGB_INTENT_PERCEPTUAL);
	}

	png_write_info(png, info);

	for (int y = 0; y < height; y++) {
		const float *src_row = src + (int64_t)y * width * components;
		uint8_t *dst = row_ptr;

		for (int x = 0; x < width; x++) {
			for (int c = 0; c < components; c++) {
				float v = src_row[x * components + c];

				// Written as "not greater than" so NaN lands on 0 too.
				if (!(v > 0.0f)) {
					v = 0.0f;
				}

				// Alpha is never sRGB-encoded — it is coverage, not colour.
				if (p_srgb_encode && c < 3) {
					v = v <= 0.0031308f ? v * 12.92f : 1.055f * Math::pow(v, 1.0f / 2.4f) - 0.055f;
				}

				// Anything above SDR white clips exactly as an 8-bit save would. The
				// gain here is precision *below* white, not extra range.
				if (v > 1.0f) {
					v = 1.0f;
				}

				const uint32_t q = (uint32_t)(v * 65535.0f + 0.5f);

				// Big-endian by hand, per the PNG spec. No png_set_swap(), so the
				// result does not depend on host endianness.
				*dst++ = (uint8_t)(q >> 8);
				*dst++ = (uint8_t)(q & 0xFF);
			}
		}

		png_write_row(png, (png_const_bytep)row_ptr);
	}

	png_write_end(png, info);
	png_destroy_write_struct(&png, &info);

	if (sink.failed) {
		p_buffer.resize(buffer_offset);
		ERR_FAIL_V_MSG(ERR_OUT_OF_MEMORY, "Out of memory while writing a 16-bit PNG.");
	}

	// Trim the doubled capacity down to what was actually written.
	Error err = p_buffer.resize(buffer_offset + (int)sink.size);
	ERR_FAIL_COND_V(err, err);

	return OK;
}
} // namespace PNGDriverCommon
