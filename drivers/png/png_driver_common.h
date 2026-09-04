/**************************************************************************/
/*  png_driver_common.h                                                   */
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

#pragma once

#include "core/io/image.h"

namespace PNGDriverCommon {

// Attempt to load png from buffer (p_source, p_size) into p_image
Error png_to_image(const uint8_t *p_source, size_t p_size, bool p_force_linear, Ref<Image> p_image);

// Append p_image, as a png, to p_buffer.
// Contents of p_buffer is unspecified if error returned.
Error image_to_png(const Ref<Image> &p_image, Vector<uint8_t> &p_buffer);

// Append p_image, as a 16-bit-per-channel png, to p_buffer.
// Unlike image_to_png() this uses the full libpng API, so float/half images keep
// their precision instead of being quantised to 8 bits before the write.
// p_compression_level is the zlib level, 0 (store) to 9. p_srgb_encode applies the
// sRGB OETF to RGB (never to alpha) and must be true for LINEAR sources such as an
// HDR (use_hdr_2d) viewport readback -- see the colour-space contract in
// PNG16_ENCODING_IMPLEMENTATION.md.
// Contents of p_buffer is unspecified if error returned.
Error image_to_png16(const Ref<Image> &p_image, Vector<uint8_t> &p_buffer, int p_compression_level = 6, bool p_srgb_encode = true);
} // namespace PNGDriverCommon
