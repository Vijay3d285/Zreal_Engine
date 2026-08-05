/**************************************************************************/
/*  ies_profile.cpp                                                       */
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

#include "ies_profile.h"

#include "core/io/file_access.h"
#include "core/object/class_db.h"

// ---------------------------------------------------------------------------
// IESProfile::_bind_methods
// ---------------------------------------------------------------------------

void IESProfile::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_ies_text", "text"), &IESProfile::set_ies_text);
	ClassDB::bind_method(D_METHOD("get_ies_text"), &IESProfile::get_ies_text);
	ClassDB::bind_method(D_METHOD("load_from_file", "path"), &IESProfile::load_from_file);

	ADD_PROPERTY(PropertyInfo(Variant::STRING, "ies_text", PROPERTY_HINT_MULTILINE_TEXT), "set_ies_text", "get_ies_text");
}

// ---------------------------------------------------------------------------
// Setters / Getters
// ---------------------------------------------------------------------------

void IESProfile::set_ies_text(const String &p_text) {
	ies_text = p_text;
	emit_changed();
}

String IESProfile::get_ies_text() const {
	return ies_text;
}

// ---------------------------------------------------------------------------
// IESProfile::load_from_file
// ---------------------------------------------------------------------------

Error IESProfile::load_from_file(const String &p_path) {
	Ref<FileAccess> f = FileAccess::open(p_path, FileAccess::READ);
	ERR_FAIL_COND_V_MSG(f.is_null(), ERR_FILE_CANT_OPEN,
			vformat("IESProfile: Cannot open file '%s'.", p_path));

	ies_text = f->get_as_text();
	emit_changed();
	return OK;
}
