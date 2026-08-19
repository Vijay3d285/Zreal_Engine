/**************************************************************************/
/*  test_standard_material_3d.cpp                                         */
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

#include "tests/test_macros.h"

TEST_FORCE_LINK(test_standard_material_3d)

#include "tests/test_utils.h"

#include "core/io/resource_loader.h"
#include "core/io/resource_saver.h"
#include "scene/resources/material.h"

// NOTE ON COVERAGE: the headless test renderer discards material parameters
// (servers/rendering/dummy/storage/material_storage.h:123-124 are both no-ops),
// so nothing here can verify that a property reaches the material parameter map
// under the right name. That wiring is verified for the first time by the GPU
// arrival gate, pipeline_references/tests/pt_material_data_gate.gd.

namespace TestStandardMaterial3D {

TEST_CASE("[SceneTree][StandardMaterial3D] Path tracing parameters round-trip") {
	Ref<StandardMaterial3D> mat;
	mat.instantiate();

	// Defaults, per the glTF specification.
	CHECK(mat->get_transmission() == doctest::Approx(0.0f));
	CHECK(mat->get_ior() == doctest::Approx(1.5f));
	CHECK(mat->get_thickness() == doctest::Approx(0.0f));
	CHECK(mat->get_attenuation_distance() == doctest::Approx(0.0f));
	CHECK(mat->get_attenuation_color() == Color(1, 1, 1));
	CHECK(mat->get_specular_factor() == doctest::Approx(1.0f));
	CHECK(mat->get_specular_tint() == Color(1, 1, 1));
	CHECK(mat->get_sheen_color() == Color(0, 0, 0));
	CHECK(mat->get_sheen_roughness() == doctest::Approx(0.0f));
	CHECK(mat->get_anisotropy_rotation() == doctest::Approx(0.0f));

	// Every value below is distinct from every other and from its own default,
	// so a copy-paste error between two setters cannot pass this test.
	mat->set_transmission(0.35f);
	mat->set_ior(1.72f);
	mat->set_thickness(2.4f);
	mat->set_attenuation_distance(5.0f);
	mat->set_attenuation_color(Color(0.9f, 0.4f, 0.15f));
	mat->set_specular_factor(0.62f);
	mat->set_specular_tint(Color(0.8f, 0.7f, 0.55f));
	mat->set_sheen_color(Color(0.25f, 0.5f, 0.75f));
	mat->set_sheen_roughness(0.45f);
	mat->set_anisotropy_rotation(1.1f);

	CHECK(mat->get_transmission() == doctest::Approx(0.35f));
	CHECK(mat->get_ior() == doctest::Approx(1.72f));
	CHECK(mat->get_thickness() == doctest::Approx(2.4f));
	CHECK(mat->get_attenuation_distance() == doctest::Approx(5.0f));
	CHECK(mat->get_attenuation_color() == Color(0.9f, 0.4f, 0.15f));
	CHECK(mat->get_specular_factor() == doctest::Approx(0.62f));
	CHECK(mat->get_specular_tint() == Color(0.8f, 0.7f, 0.55f));
	CHECK(mat->get_sheen_color() == Color(0.25f, 0.5f, 0.75f));
	CHECK(mat->get_sheen_roughness() == doctest::Approx(0.45f));
	CHECK(mat->get_anisotropy_rotation() == doctest::Approx(1.1f));
}

TEST_CASE("[SceneTree][StandardMaterial3D] Path tracing parameters are registered properties") {
	Ref<StandardMaterial3D> mat;
	mat.instantiate();

	// Exercises the ClassDB registration rather than the C++ accessors: a
	// missing ADD_PROPERTY fails here and nowhere else.
	const char *names[] = { "transmission", "ior", "thickness",
		"attenuation_distance", "specular_factor", "sheen_roughness",
		"anisotropy_rotation" };
	const float values[] = { 0.35f, 1.72f, 2.4f, 5.0f, 0.62f, 0.45f, 1.1f };
	for (int i = 0; i < 7; i++) {
		bool valid = false;
		mat->set(names[i], values[i]);
		const Variant read = mat->get(names[i], &valid);
		CHECK_MESSAGE(valid, "Property \"", names[i], "\" is not registered.");
		CHECK_MESSAGE((float)read == doctest::Approx(values[i]), "Property \"", names[i], "\" did not round-trip.");
	}

	const char *color_names[] = { "attenuation_color", "specular_tint", "sheen_color" };
	const Color color_values[] = { Color(0.9f, 0.4f, 0.15f), Color(0.8f, 0.7f, 0.55f), Color(0.25f, 0.5f, 0.75f) };
	for (int i = 0; i < 3; i++) {
		bool valid = false;
		mat->set(color_names[i], color_values[i]);
		const Variant read = mat->get(color_names[i], &valid);
		CHECK_MESSAGE(valid, "Property \"", color_names[i], "\" is not registered.");
		CHECK_MESSAGE((Color)read == color_values[i], "Property \"", color_names[i], "\" did not round-trip.");
	}
}

TEST_CASE("[SceneTree][StandardMaterial3D] Path tracing parameters survive .tres serialisation") {
	// These are the first BaseMaterial3D properties that exist SOLELY to be
	// persisted and re-read: nothing in the editor renders them, so a
	// serialisation defect would stay invisible until someone opened a saved
	// scene in the path tracer. Hence an explicit save/load round-trip.
	Ref<StandardMaterial3D> mat;
	mat.instantiate();

	// Distinct from each other and from their own defaults, so a property that
	// silently failed to serialise reads back as its default and fails here.
	mat->set_transmission(0.35f);
	mat->set_ior(1.72f);
	mat->set_thickness(2.4f);
	mat->set_attenuation_distance(5.0f);
	mat->set_attenuation_color(Color(0.9f, 0.4f, 0.15f));
	mat->set_specular_factor(0.62f);
	mat->set_specular_tint(Color(0.8f, 0.7f, 0.55f));
	mat->set_sheen_color(Color(0.25f, 0.5f, 0.75f));
	mat->set_sheen_roughness(0.45f);
	mat->set_anisotropy_rotation(1.1f);

	const String path = TestUtils::get_temp_path("pt_material_params.tres");
	REQUIRE(ResourceSaver::save(mat, path) == OK);

	Ref<StandardMaterial3D> loaded = ResourceLoader::load(path, "", ResourceFormatLoader::CACHE_MODE_IGNORE);
	REQUIRE(loaded.is_valid());

	CHECK(loaded->get_transmission() == doctest::Approx(0.35f));
	CHECK(loaded->get_ior() == doctest::Approx(1.72f));
	CHECK(loaded->get_thickness() == doctest::Approx(2.4f));
	CHECK(loaded->get_attenuation_distance() == doctest::Approx(5.0f));
	CHECK(loaded->get_attenuation_color().is_equal_approx(Color(0.9f, 0.4f, 0.15f)));
	CHECK(loaded->get_specular_factor() == doctest::Approx(0.62f));
	CHECK(loaded->get_specular_tint().is_equal_approx(Color(0.8f, 0.7f, 0.55f)));
	CHECK(loaded->get_sheen_color().is_equal_approx(Color(0.25f, 0.5f, 0.75f)));
	CHECK(loaded->get_sheen_roughness() == doctest::Approx(0.45f));
	CHECK(loaded->get_anisotropy_rotation() == doctest::Approx(1.1f));
}

TEST_CASE("[SceneTree][StandardMaterial3D] Clearcoat and anisotropy defaults") {
	// The design assumed clearcoat/clearcoat_roughness defaulted to 0.0. They do
	// not -- BaseMaterial3D's constructor sets 1.0 and 0.5 (matching the
	// documented defaults in doc/classes/BaseMaterial3D.xml). This pins the real
	// values so the next phase reads them from a test rather than from prose.
	Ref<StandardMaterial3D> mat;
	mat.instantiate();

	CHECK(mat->get_clearcoat() == doctest::Approx(1.0f));
	CHECK(mat->get_clearcoat_roughness() == doctest::Approx(0.5f));
	CHECK(mat->get_anisotropy() == doctest::Approx(0.0f));

	// The features are off by default. What the path tracer reads is therefore
	// 0 for all three regardless of the member values above -- see the
	// feature-gating block comment above BaseMaterial3D::set_clearcoat(). That
	// gating is only observable on a real rendering backend (the headless test
	// renderer discards material parameters), so it is proven by the GPU gate,
	// pipeline_references/tests/pt_material_data_gate.gd.
	CHECK_FALSE(mat->get_feature(BaseMaterial3D::FEATURE_CLEARCOAT));
	CHECK_FALSE(mat->get_feature(BaseMaterial3D::FEATURE_ANISOTROPY));

	// Toggling the feature must not disturb the member values themselves.
	mat->set_feature(BaseMaterial3D::FEATURE_CLEARCOAT, true);
	CHECK(mat->get_clearcoat() == doctest::Approx(1.0f));
	CHECK(mat->get_clearcoat_roughness() == doctest::Approx(0.5f));
	mat->set_feature(BaseMaterial3D::FEATURE_CLEARCOAT, false);
	CHECK(mat->get_clearcoat() == doctest::Approx(1.0f));
	CHECK(mat->get_clearcoat_roughness() == doctest::Approx(0.5f));
}

} // namespace TestStandardMaterial3D
