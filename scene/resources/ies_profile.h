/**************************************************************************/
/*  ies_profile.h                                                         */
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

// IESProfile: a Godot Resource that embeds the raw IES text of a photometric
// profile. This is the "Internal" mode analogue of Blender's Text data-block
// used with ShaderNodeTexIES in NODE_IES_INTERNAL mode.
//
// Storing the raw text inside a Resource (rather than pointing to a file) makes
// .tres / .scn files fully portable — the profile data travels with the scene.

#include "core/io/resource.h"
#include "core/string/ustring.h"

class IESProfile : public Resource {
	GDCLASS(IESProfile, Resource);

	// Raw IES file content as a UTF-8 / ASCII string.
	String ies_text;

protected:
	static void _bind_methods();

public:
	// Set the raw IES text content directly.
	void set_ies_text(const String &p_text);
	String get_ies_text() const;

	// Load from a .ies file on disk and store the content internally.
	// Returns OK on success; the loaded text is accessible via get_ies_text().
	Error load_from_file(const String &p_path);

	IESProfile() {}
	~IESProfile() {}
};
