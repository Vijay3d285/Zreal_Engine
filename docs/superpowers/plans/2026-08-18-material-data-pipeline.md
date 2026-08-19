# Phase D — Material Data Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Carry seven glTF material extensions from a Blender-authored GLB all the way to the path tracer's GPU material struct, so Phase E has data to consume.

**Architecture:** Ten new `BaseMaterial3D` properties are pushed into the material parameter map without declaring any forward+ shader uniform, which is legal because the UBO fill iterates *shader uniforms* and looks each up in the parameter map — extras are ignored silently. `_parse_materials` and the material serialiser in `gltf_document.cpp` gain seven blocks each. `RT_MaterialData` grows 96 → 176 bytes and `render_raytracing.cpp` reads the new parameters by name alongside `metallic`/`roughness`/`specular`.

**Tech Stack:** C++ (Godot 4.7 fork), GLSL (Vulkan RD raytracing pipeline), GDScript (measurement gates), SCons, doctest.

**Spec:** `docs/superpowers/specs/2026-08-18-material-data-pipeline-design.md`. Read it before starting; this plan implements it and does not restate its reasoning.

## Global Constraints

- **Phase D adds no shading.** No BSDF reads any new value. Do not modify BSDF evaluation or sampling. Carrying data that nothing reads yet **is** the deliverable, not dead code — see spec §1.
- **The no-pixel-change invariant is scoped, not absolute.** Phase D changes zero pixels for content carrying none of the seven extensions. Forward+ output changes only for materials that carry clearcoat or anisotropy data, because Task 2 must enable `FEATURE_CLEARCOAT` / `FEATURE_ANISOTROPY` for those values to be inspectable (spec §3.3, §7.2). RT output is unchanged unconditionally.
- **Factors only.** Per-parameter extension textures are out of scope and must be dropped with a warning, never silently.
- **`RT_MaterialData` and its GLSL twin must agree byte-for-byte.** Sizes, member order, `alignas`/std430 layout, and `static_assert` must all agree on both sides.
- **After touching any `.glsl`, run a full `scons` build** so the `.glsl.gen.h` regenerates. Never hand-edit a `.gen.h`.
- **The importer never writes `specular`.** `ior`, `specular_factor` and `specular_tint` are carried alongside it.
- **No clamping on import**, matching Blender. `ior == 0.0` is legal glTF.
- **Script changes for the render pipeline go in `pipeline_references/` only** — never in `C:\Zlendo2026\ZlenderRender_stage_copy\`.
- Build: `scons platform=windows tests=yes target=editor`. Tests: `bin\godot.windows.editor.x86_64.console.exe --test "<filter>"`.

## The thirteen values, and the fixture values used throughout this plan

Every task below uses these same numbers. They are pairwise distinct and every one differs from its own default, so a field swap or copy-paste error cannot pass unnoticed.

| Property | Default | Fixture value | glTF key |
|---|---|---|---|
| `transmission` | 0.0 | **0.35** | `KHR_materials_transmission.transmissionFactor` |
| `ior` | 1.5 | **1.72** | `KHR_materials_ior.ior` |
| `thickness` | 0.0 | **2.4** | `KHR_materials_volume.thicknessFactor` |
| `attenuation_distance` | 0.0 (= infinite) | **5.0** (→ density 0.2) | `KHR_materials_volume.attenuationDistance` |
| `attenuation_color` | white | **(0.9, 0.4, 0.15)** linear | `KHR_materials_volume.attenuationColor` |
| `specular_factor` | 1.0 | **0.62** | `KHR_materials_specular.specularFactor` |
| `specular_tint` | white | **(0.8, 0.7, 0.55)** linear | `KHR_materials_specular.specularColorFactor` |
| `sheen_color` | black | **(0.25, 0.5, 0.75)** linear | `KHR_materials_sheen.sheenColorFactor` |
| `sheen_roughness` | 0.0 | **0.45** | `KHR_materials_sheen.sheenRoughnessFactor` |
| `anisotropy_rotation` | 0.0 | **1.1** rad | `KHR_materials_anisotropy.anisotropyRotation` |
| `clearcoat` *(existing)* | 0.0 | **0.55** | `KHR_materials_clearcoat.clearcoatFactor` |
| `clearcoat_roughness` *(existing)* | 0.0 | **0.28** | `KHR_materials_clearcoat.clearcoatRoughnessFactor` |
| `anisotropy` *(existing)* | 0.0 | **0.83** | `KHR_materials_anisotropy.anisotropyStrength` |

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `scene/resources/material.h` | 10 members + 10 `ShaderNames` entries + 20 method declarations | 1 |
| `scene/resources/material.cpp` | Parameter-name initialisers, setters/getters, bindings, `ADD_PROPERTY` | 1 |
| `doc/classes/BaseMaterial3D.xml` | Documents the 10 properties, each noting forward+ ignores it | 1 |
| `tests/scene/test_standard_material_3d.cpp` | **Create.** Property round-trip + `.tres` serialisation | 1 |
| `modules/gltf/gltf_document.cpp` | 7 import blocks, 7 export blocks, 7 supported-extension entries | 2, 3 |
| `tests/data/models/material_extensions.gltf` | **Create.** Hand-authored fixture with canonical Khronos keys | 2 |
| `tests/scene/test_gltf_document.cpp` | Fixture-parse test, dropped-texture test, closed-loop round-trip | 2, 3 |
| `servers/rendering/renderer_rd/forward_clustered/render_raytracing.h` | `RT_MaterialData` 96 → 176 bytes, 4 asserts | 4 |
| `servers/rendering/renderer_rd/forward_clustered/render_raytracing.cpp` | Three fill sites in lockstep | 4 |
| `.../shaders/raytracing/raytracing_data_inc.glsl` | `MaterialData` GLSL twin | 4 |
| `.../shaders/raytracing/raytracing_closest_hit_common_inc.glsl` | `debug_visualize` signature + vis modes 23–29 | 5 |
| `.../shaders/raytracing/scene_raytracing_raygen.glsl` | Two `debug_visualize` call sites | 5 |
| `scene/resources/environment.h` / `.cpp` | 7 `PathtracingDebugMode` enum constants + hint string | 5 |
| `doc/classes/Environment.xml` | Documents the 7 new enum constants | 5 |
| `pipeline_references/tests/pt_material_data_gate.gd` + `.tscn` | **Create.** GPU arrival gate | 5 |
| `PATH_TRACER_QUALITY_ROADMAP.md` | Phase D closeout entry | 6 |

---

## Task 1: `BaseMaterial3D` carries the ten new parameters

**Files:**
- Modify: `scene/resources/material.h` (members near `:548-550`, `ShaderNames` near `:474-476`, declarations near `:678-685`)
- Modify: `scene/resources/material.cpp` (`init_shaders` `:560-582`, setters near `:2245`, `_bind_methods` near `:3375`, `ADD_PROPERTY` near `:3633` and `:3688`)
- Modify: `doc/classes/BaseMaterial3D.xml`
- Create: `tests/scene/test_standard_material_3d.cpp`

**Interfaces:**
- Consumes: nothing.
- Produces: ten property names — `transmission`, `ior`, `thickness`, `attenuation_distance`, `attenuation_color`, `specular_factor`, `specular_tint`, `sheen_color`, `sheen_roughness`, `anisotropy_rotation` — each with `set_<name>` / `get_<name>` accessors. Floats are `float`; `attenuation_color`, `specular_tint`, `sheen_color` are `Color`. Task 2 sets them from glTF, Task 3 reads them for export, Task 4 reads them from the render thread via `material_get_param` under **exactly these names**.

### READ THIS BEFORE WRITING THE TEST

The headless test renderer **discards material parameters**. In `servers/rendering/dummy/storage/material_storage.h:123-124`:

```cpp
virtual void material_set_param(RID p_material, const StringName &p_param, const Variant &p_value) override {}
virtual Variant material_get_param(RID p_material, const StringName &p_param) const override { return Variant(); }
```

So **no doctest in this task can verify that a property reaches the material parameter map.** Do not write one that appears to — it would pass no matter what string you put in `shader_names->X`. The parameter-name wiring is verified for the first time by the GPU gate in Task 5. Say so in a comment at the top of the new test file so the next reader does not assume more coverage than exists.

What this task's test *can* verify, and does: that the properties exist, are bound, round-trip through their accessors, and survive `.tres` serialisation. That catches a missing binding, a wrong type, and a missing `ADD_PROPERTY`.

- [ ] **Step 1: Write the failing test**

Create `tests/scene/test_standard_material_3d.cpp`. Copy the 29-line Godot copyright header verbatim from `tests/scene/test_gltf_document.cpp:1-29`, changing only the filename on line 2.

```cpp
#include "tests/test_macros.h"

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

} // namespace TestStandardMaterial3D
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
scons platform=windows tests=yes target=editor
```

Then:

```bash
bin/godot.windows.editor.x86_64.console.exe --test "*StandardMaterial3D*"
```

Expected: the **build** fails first, with errors like `'class StandardMaterial3D' has no member named 'get_transmission'`. That is the failing state for this step. Do not proceed until you have seen it.

- [ ] **Step 3: Add the members and parameter names**

In `scene/resources/material.h`, immediately after `float anisotropy = 0.0f;` (`:550`):

```cpp
	// Path-tracer-only material parameters (glTF material extensions).
	// The forward+ generated shader declares no uniform for any of these; they
	// reach the RT path through the material parameter map. See
	// docs/superpowers/specs/2026-08-18-material-data-pipeline-design.md 3.1.
	float transmission = 0.0f;
	float ior = 1.5f;
	float thickness = 0.0f;
	float attenuation_distance = 0.0f; // 0 means infinite (no absorption).
	Color attenuation_color = Color(1, 1, 1);
	float specular_factor = 1.0f;
	Color specular_tint = Color(1, 1, 1);
	Color sheen_color = Color(0, 0, 0);
	float sheen_roughness = 0.0f;
	float anisotropy_rotation = 0.0f; // Radians.
```

In the `ShaderNames` struct, immediately after `StringName anisotropy;` (`:476`):

```cpp
		StringName transmission;
		StringName ior;
		StringName thickness;
		StringName attenuation_distance;
		StringName attenuation_color;
		StringName specular_factor;
		StringName specular_tint;
		StringName sheen_color;
		StringName sheen_roughness;
		StringName anisotropy_rotation;
```

In the public method declarations, immediately after `float get_anisotropy() const;` (`:685`):

```cpp
	void set_transmission(float p_transmission);
	float get_transmission() const;

	void set_ior(float p_ior);
	float get_ior() const;

	void set_thickness(float p_thickness);
	float get_thickness() const;

	void set_attenuation_distance(float p_attenuation_distance);
	float get_attenuation_distance() const;

	void set_attenuation_color(const Color &p_attenuation_color);
	Color get_attenuation_color() const;

	void set_specular_factor(float p_specular_factor);
	float get_specular_factor() const;

	void set_specular_tint(const Color &p_specular_tint);
	Color get_specular_tint() const;

	void set_sheen_color(const Color &p_sheen_color);
	Color get_sheen_color() const;

	void set_sheen_roughness(float p_sheen_roughness);
	float get_sheen_roughness() const;

	void set_anisotropy_rotation(float p_anisotropy_rotation);
	float get_anisotropy_rotation() const;
```

In `scene/resources/material.cpp`, inside `init_shaders()`, immediately after `shader_names->anisotropy = "anisotropy_ratio";` (`:574`):

```cpp
	// Parameter names equal property names for all ten. Verified collision-free
	// against the generated forward+ shader: grepping `uniform <type> <name>` in
	// this file returns zero matches for every one. A collision would route the
	// value into the forward+ UBO and change rendering.
	shader_names->transmission = "transmission";
	shader_names->ior = "ior";
	shader_names->thickness = "thickness";
	shader_names->attenuation_distance = "attenuation_distance";
	shader_names->attenuation_color = "attenuation_color";
	shader_names->specular_factor = "specular_factor";
	shader_names->specular_tint = "specular_tint";
	shader_names->sheen_color = "sheen_color";
	shader_names->sheen_roughness = "sheen_roughness";
	shader_names->anisotropy_rotation = "anisotropy_rotation";
```

- [ ] **Step 4: Add the setters and getters**

In `scene/resources/material.cpp`, immediately after `float BaseMaterial3D::get_anisotropy() const { return anisotropy; }` (ends near `:2251`):

```cpp
void BaseMaterial3D::set_transmission(float p_transmission) {
	transmission = p_transmission;
	_material_set_param(shader_names->transmission, p_transmission);
}

float BaseMaterial3D::get_transmission() const {
	return transmission;
}

void BaseMaterial3D::set_ior(float p_ior) {
	ior = p_ior;
	_material_set_param(shader_names->ior, p_ior);
}

float BaseMaterial3D::get_ior() const {
	return ior;
}

void BaseMaterial3D::set_thickness(float p_thickness) {
	thickness = p_thickness;
	_material_set_param(shader_names->thickness, p_thickness);
}

float BaseMaterial3D::get_thickness() const {
	return thickness;
}

void BaseMaterial3D::set_attenuation_distance(float p_attenuation_distance) {
	attenuation_distance = p_attenuation_distance;
	_material_set_param(shader_names->attenuation_distance, p_attenuation_distance);
}

float BaseMaterial3D::get_attenuation_distance() const {
	return attenuation_distance;
}

void BaseMaterial3D::set_attenuation_color(const Color &p_attenuation_color) {
	attenuation_color = p_attenuation_color;
	_material_set_param(shader_names->attenuation_color, p_attenuation_color);
}

Color BaseMaterial3D::get_attenuation_color() const {
	return attenuation_color;
}

void BaseMaterial3D::set_specular_factor(float p_specular_factor) {
	specular_factor = p_specular_factor;
	_material_set_param(shader_names->specular_factor, p_specular_factor);
}

float BaseMaterial3D::get_specular_factor() const {
	return specular_factor;
}

void BaseMaterial3D::set_specular_tint(const Color &p_specular_tint) {
	specular_tint = p_specular_tint;
	_material_set_param(shader_names->specular_tint, p_specular_tint);
}

Color BaseMaterial3D::get_specular_tint() const {
	return specular_tint;
}

void BaseMaterial3D::set_sheen_color(const Color &p_sheen_color) {
	sheen_color = p_sheen_color;
	_material_set_param(shader_names->sheen_color, p_sheen_color);
}

Color BaseMaterial3D::get_sheen_color() const {
	return sheen_color;
}

void BaseMaterial3D::set_sheen_roughness(float p_sheen_roughness) {
	sheen_roughness = p_sheen_roughness;
	_material_set_param(shader_names->sheen_roughness, p_sheen_roughness);
}

float BaseMaterial3D::get_sheen_roughness() const {
	return sheen_roughness;
}

void BaseMaterial3D::set_anisotropy_rotation(float p_anisotropy_rotation) {
	anisotropy_rotation = p_anisotropy_rotation;
	_material_set_param(shader_names->anisotropy_rotation, p_anisotropy_rotation);
}

float BaseMaterial3D::get_anisotropy_rotation() const {
	return anisotropy_rotation;
}
```

- [ ] **Step 5: Bind the methods**

In `_bind_methods()`, immediately after the `get_anisotropy` binding (`:3376`):

```cpp
	ClassDB::bind_method(D_METHOD("set_anisotropy_rotation", "anisotropy_rotation"), &BaseMaterial3D::set_anisotropy_rotation);
	ClassDB::bind_method(D_METHOD("get_anisotropy_rotation"), &BaseMaterial3D::get_anisotropy_rotation);

	ClassDB::bind_method(D_METHOD("set_transmission", "transmission"), &BaseMaterial3D::set_transmission);
	ClassDB::bind_method(D_METHOD("get_transmission"), &BaseMaterial3D::get_transmission);

	ClassDB::bind_method(D_METHOD("set_ior", "ior"), &BaseMaterial3D::set_ior);
	ClassDB::bind_method(D_METHOD("get_ior"), &BaseMaterial3D::get_ior);

	ClassDB::bind_method(D_METHOD("set_thickness", "thickness"), &BaseMaterial3D::set_thickness);
	ClassDB::bind_method(D_METHOD("get_thickness"), &BaseMaterial3D::get_thickness);

	ClassDB::bind_method(D_METHOD("set_attenuation_distance", "attenuation_distance"), &BaseMaterial3D::set_attenuation_distance);
	ClassDB::bind_method(D_METHOD("get_attenuation_distance"), &BaseMaterial3D::get_attenuation_distance);

	ClassDB::bind_method(D_METHOD("set_attenuation_color", "attenuation_color"), &BaseMaterial3D::set_attenuation_color);
	ClassDB::bind_method(D_METHOD("get_attenuation_color"), &BaseMaterial3D::get_attenuation_color);

	ClassDB::bind_method(D_METHOD("set_specular_factor", "specular_factor"), &BaseMaterial3D::set_specular_factor);
	ClassDB::bind_method(D_METHOD("get_specular_factor"), &BaseMaterial3D::get_specular_factor);

	ClassDB::bind_method(D_METHOD("set_specular_tint", "specular_tint"), &BaseMaterial3D::set_specular_tint);
	ClassDB::bind_method(D_METHOD("get_specular_tint"), &BaseMaterial3D::get_specular_tint);

	ClassDB::bind_method(D_METHOD("set_sheen_color", "sheen_color"), &BaseMaterial3D::set_sheen_color);
	ClassDB::bind_method(D_METHOD("get_sheen_color"), &BaseMaterial3D::get_sheen_color);

	ClassDB::bind_method(D_METHOD("set_sheen_roughness", "sheen_roughness"), &BaseMaterial3D::set_sheen_roughness);
	ClassDB::bind_method(D_METHOD("get_sheen_roughness"), &BaseMaterial3D::get_sheen_roughness);
```

- [ ] **Step 6: Register the properties**

In `_bind_methods()`, add `anisotropy_rotation` to the existing Anisotropy group. Immediately after the `anisotropy` property line (`:3635`), before the `anisotropy_flowmap` line:

```cpp
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "anisotropy_rotation", PROPERTY_HINT_RANGE, "0,6.2831853,0.001,radians_as_degrees"), "set_anisotropy_rotation", "get_anisotropy_rotation");
```

Then add the new group immediately **before** `ADD_GROUP("UV1", "uv1_");` (`:3688`):

```cpp
	// Path-tracer-only parameters. The forward+ renderer ignores every one of
	// these; they exist so glTF material extensions survive import and reach the
	// RT material struct.
	ADD_GROUP("Path Tracing", "");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "transmission", PROPERTY_HINT_RANGE, "0,1,0.01"), "set_transmission", "get_transmission");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "ior", PROPERTY_HINT_RANGE, "0,3,0.001,or_greater"), "set_ior", "get_ior");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "thickness", PROPERTY_HINT_RANGE, "0,10,0.001,or_greater"), "set_thickness", "get_thickness");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "attenuation_distance", PROPERTY_HINT_RANGE, "0,100,0.001,or_greater"), "set_attenuation_distance", "get_attenuation_distance");
	ADD_PROPERTY(PropertyInfo(Variant::COLOR, "attenuation_color", PROPERTY_HINT_COLOR_NO_ALPHA), "set_attenuation_color", "get_attenuation_color");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "specular_factor", PROPERTY_HINT_RANGE, "0,1,0.01"), "set_specular_factor", "get_specular_factor");
	ADD_PROPERTY(PropertyInfo(Variant::COLOR, "specular_tint", PROPERTY_HINT_COLOR_NO_ALPHA), "set_specular_tint", "get_specular_tint");
	ADD_PROPERTY(PropertyInfo(Variant::COLOR, "sheen_color", PROPERTY_HINT_COLOR_NO_ALPHA), "set_sheen_color", "get_sheen_color");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "sheen_roughness", PROPERTY_HINT_RANGE, "0,1,0.01"), "set_sheen_roughness", "get_sheen_roughness");
```

Note the `ior` range allows 0: `ior == 0.0` is legal glTF meaning "no refraction, F0 = 0".

- [ ] **Step 7: Run the test to verify it passes**

```bash
scons platform=windows tests=yes target=editor
```

```bash
bin/godot.windows.editor.x86_64.console.exe --test "*StandardMaterial3D*"
```

Expected: PASS, both test cases.

- [ ] **Step 8: Verify no forward+ uniform collision**

```bash
for n in transmission ior thickness attenuation_distance attenuation_color specular_factor specular_tint sheen_color sheen_roughness anisotropy_rotation; do echo "$n -> $(grep -c "uniform [a-z0-9]* $n\b" scene/resources/material.cpp)"; done
```

Expected: every one prints `-> 0`. A non-zero count means the parameter would be routed into the forward+ UBO and change rendering; stop and rename before continuing.

- [ ] **Step 9: Document the properties**

Add ten `<member>` entries to `doc/classes/BaseMaterial3D.xml`, in the alphabetical position the file already uses. Each follows this shape (shown for `ior`; write all ten):

```xml
		<member name="ior" type="float" setter="set_ior" getter="get_ior" default="1.5">
			Index of refraction, imported from the glTF [code]KHR_materials_ior[/code] extension. Used by the path tracer only; the Forward+ renderer ignores this property. A value of [code]0.0[/code] is valid and means no refraction.
		</member>
```

- [ ] **Step 10: Commit**

```bash
git add scene/resources/material.h scene/resources/material.cpp doc/classes/BaseMaterial3D.xml tests/scene/test_standard_material_3d.cpp
git commit -m "feat(pt): BaseMaterial3D carries ten path-tracer-only parameters"
```

---

## Task 2: glTF import of the seven extensions

**Files:**
- Modify: `modules/gltf/gltf_document.cpp` (`_parse_materials` `:2946`, supported extensions `:6967`)
- Create: `tests/data/models/material_extensions.gltf`
- Modify: `tests/scene/test_gltf_document.cpp`

**Interfaces:**
- Consumes: the ten setters from Task 1, plus the existing `set_clearcoat`, `set_clearcoat_roughness`, `set_anisotropy`, and `set_feature(BaseMaterial3D::FEATURE_CLEARCOAT | FEATURE_ANISOTROPY, true)`.
- Produces: `GLTFState::get_materials()` returns `StandardMaterial3D`s carrying all thirteen values. Task 3 serialises them back out.

### Why the fixture is hand-authored and not generated

The round-trip test in Task 3 exercises our importer against our own exporter. If both sides consistently use the wrong key — `sheenColor` where Khronos says `sheenColorFactor` — that loop still closes and still passes, while every real GLB silently loses sheen. This fixture is the only hermetic check that catches a systematic naming error, so **its key names must be typed from the Khronos specification, not copied from the importer you are about to write.**

- [ ] **Step 1: Write the fixture**

Create `tests/data/models/material_extensions.gltf`. Colour values here are **linear**, as glTF requires.

```json
{
  "asset": { "version": "2.0", "generator": "hand-authored for Godot Phase D tests" },
  "extensionsUsed": [
    "KHR_materials_transmission",
    "KHR_materials_ior",
    "KHR_materials_volume",
    "KHR_materials_specular",
    "KHR_materials_clearcoat",
    "KHR_materials_sheen",
    "KHR_materials_anisotropy"
  ],
  "scene": 0,
  "scenes": [ { "nodes": [] } ],
  "materials": [
    {
      "name": "AllExtensions",
      "pbrMetallicRoughness": { "baseColorFactor": [1.0, 1.0, 1.0, 1.0] },
      "extensions": {
        "KHR_materials_transmission": { "transmissionFactor": 0.35 },
        "KHR_materials_ior": { "ior": 1.72 },
        "KHR_materials_volume": {
          "thicknessFactor": 2.4,
          "attenuationDistance": 5.0,
          "attenuationColor": [0.9, 0.4, 0.15]
        },
        "KHR_materials_specular": {
          "specularFactor": 0.62,
          "specularColorFactor": [0.8, 0.7, 0.55]
        },
        "KHR_materials_clearcoat": {
          "clearcoatFactor": 0.55,
          "clearcoatRoughnessFactor": 0.28
        },
        "KHR_materials_sheen": {
          "sheenColorFactor": [0.25, 0.5, 0.75],
          "sheenRoughnessFactor": 0.45
        },
        "KHR_materials_anisotropy": {
          "anisotropyStrength": 0.83,
          "anisotropyRotation": 1.1
        }
      }
    },
    {
      "name": "TextureDropped",
      "pbrMetallicRoughness": { "baseColorFactor": [1.0, 1.0, 1.0, 1.0] },
      "extensions": {
        "KHR_materials_transmission": {
          "transmissionFactor": 0.35,
          "transmissionTexture": { "index": 0 }
        }
      }
    }
  ]
}
```

- [ ] **Step 2: Write the failing test**

Add to `tests/scene/test_gltf_document.cpp`, inside `namespace TestGLTFDocument`, after the existing `TEST_CASE`s. Add `#include "scene/resources/material.h"` to the include block near `:41` if it is not already present.

```cpp
TEST_CASE("[SceneTree][GLTFDocument] Import glTF material extensions") {
	register_gltf_extension();

	Ref<GLTFDocument> gltf_document;
	gltf_document.instantiate();
	Ref<GLTFState> gltf_state;
	gltf_state.instantiate();

	const Error err = gltf_document->append_from_file(
			TestUtils::get_data_path("material_extensions.gltf"), gltf_state);
	REQUIRE(err == OK);

	const Vector<Ref<Material>> &materials = gltf_state->get_materials();
	REQUIRE(materials.size() == 2);

	Ref<StandardMaterial3D> mat = materials[0];
	REQUIRE(mat.is_valid());

	// Scalars are compared exactly: no colour-space conversion touches them.
	CHECK(mat->get_transmission() == doctest::Approx(0.35f));
	CHECK(mat->get_ior() == doctest::Approx(1.72f));
	CHECK(mat->get_thickness() == doctest::Approx(2.4f));
	CHECK(mat->get_attenuation_distance() == doctest::Approx(5.0f));
	CHECK(mat->get_specular_factor() == doctest::Approx(0.62f));
	CHECK(mat->get_sheen_roughness() == doctest::Approx(0.45f));
	CHECK(mat->get_anisotropy_rotation() == doctest::Approx(1.1f));
	CHECK(mat->get_clearcoat() == doctest::Approx(0.55f));
	CHECK(mat->get_clearcoat_roughness() == doctest::Approx(0.28f));
	CHECK(mat->get_anisotropy() == doctest::Approx(0.83f));

	// Colours are linear in glTF and sRGB in Godot properties, so compare
	// against the converted value, with tolerance for the conversion.
	const Color expect_atten = Color(0.9f, 0.4f, 0.15f).linear_to_srgb();
	const Color expect_spec = Color(0.8f, 0.7f, 0.55f).linear_to_srgb();
	const Color expect_sheen = Color(0.25f, 0.5f, 0.75f).linear_to_srgb();
	CHECK(mat->get_attenuation_color().is_equal_approx(expect_atten));
	CHECK(mat->get_specular_tint().is_equal_approx(expect_spec));
	CHECK(mat->get_sheen_color().is_equal_approx(expect_sheen));

	// Reused properties are hidden in the Inspector unless their feature is on,
	// so importing the value without enabling the feature would fail the
	// spec's "inspectable" acceptance criterion.
	CHECK(mat->get_feature(BaseMaterial3D::FEATURE_CLEARCOAT));
	CHECK(mat->get_feature(BaseMaterial3D::FEATURE_ANISOTROPY));
}

TEST_CASE("[SceneTree][GLTFDocument] Unsupported extension textures are dropped, factors kept") {
	register_gltf_extension();

	Ref<GLTFDocument> gltf_document;
	gltf_document.instantiate();
	Ref<GLTFState> gltf_state;
	gltf_state.instantiate();

	const Error err = gltf_document->append_from_file(
			TestUtils::get_data_path("material_extensions.gltf"), gltf_state);
	REQUIRE(err == OK);

	const Vector<Ref<Material>> &materials = gltf_state->get_materials();
	REQUIRE(materials.size() == 2);

	Ref<StandardMaterial3D> mat = materials[1];
	REQUIRE(mat.is_valid());

	// The factor survives...
	CHECK(mat->get_transmission() == doctest::Approx(0.35f));
	// ...and the texture is dropped rather than silently mis-assigned to some
	// other channel. A warning naming the material is emitted; this asserts the
	// behaviour, not the log line.
	for (int i = 0; i < BaseMaterial3D::TEXTURE_MAX; i++) {
		CHECK(mat->get_texture((BaseMaterial3D::TextureParam)i).is_null());
	}
}
```

- [ ] **Step 3: Run the tests to verify they fail**

```bash
scons platform=windows tests=yes target=editor
```

```bash
bin/godot.windows.editor.x86_64.console.exe --test "*GLTFDocument*"
```

Expected: both new cases FAIL. The extension values come back at their defaults (`transmission` 0.0, `ior` 1.5) because nothing parses them yet.

- [ ] **Step 4: Add the import blocks**

In `modules/gltf/gltf_document.cpp`, inside `_parse_materials`, immediately after the closing brace of the `KHR_materials_emissive_strength` block (`:2977`) and **before** `int primary_texture_coord = -1;` (`:2978`). Placement matters: this must run before the `KHR_materials_pbrSpecularGlossiness` branch so a spec-gloss material does not overwrite it.

```cpp
		// glTF material extensions carried for the path tracer. Factors only;
		// per-parameter extension textures are dropped with a warning below.
		// A malformed extension costs its parameter, never the model: these
		// blocks skip and warn where core glTF fields ERR_FAIL.
		{
			Vector<String> dropped_textures;

			// Reads a finite float from a glTF extension dictionary. Returns
			// false (leaving r_value untouched) if the key is absent, the wrong
			// type, or non-finite. A NaN reaching the shader poisons pixels far
			// from its origin, so it is rejected here.
			auto read_ext_float = [&](const Dictionary &p_ext, const char *p_key, float &r_value) -> bool {
				if (!p_ext.has(p_key)) {
					return false;
				}
				const Variant v = p_ext[p_key];
				if (v.get_type() != Variant::FLOAT && v.get_type() != Variant::INT) {
					WARN_PRINT(vformat("glTF material '%s': ignoring non-numeric '%s'.", material->get_name(), p_key));
					return false;
				}
				const double d = v;
				if (!std::isfinite(d)) {
					WARN_PRINT(vformat("glTF material '%s': ignoring non-finite '%s'.", material->get_name(), p_key));
					return false;
				}
				r_value = (float)d;
				return true;
			};

			// Reads a linear RGB triple and converts it to Godot's sRGB-encoded
			// Color convention, matching baseColorFactor above.
			auto read_ext_color = [&](const Dictionary &p_ext, const char *p_key, Color &r_value) -> bool {
				if (!p_ext.has(p_key)) {
					return false;
				}
				const Variant v = p_ext[p_key];
				if (v.get_type() != Variant::ARRAY) {
					WARN_PRINT(vformat("glTF material '%s': ignoring malformed '%s'.", material->get_name(), p_key));
					return false;
				}
				const Array arr = v;
				if (arr.size() != 3) {
					WARN_PRINT(vformat("glTF material '%s': ignoring '%s' with %d components (expected 3).", material->get_name(), p_key, arr.size()));
					return false;
				}
				for (int c = 0; c < 3; c++) {
					const double d = arr[c];
					if (!std::isfinite(d)) {
						WARN_PRINT(vformat("glTF material '%s': ignoring non-finite component in '%s'.", material->get_name(), p_key));
						return false;
					}
				}
				r_value = Color(arr[0], arr[1], arr[2]).linear_to_srgb();
				return true;
			};

			auto note_dropped_texture = [&](const Dictionary &p_ext, const char *p_key) {
				if (p_ext.has(p_key)) {
					dropped_textures.push_back(p_key);
				}
			};

			if (material_extensions.has("KHR_materials_transmission")) {
				const Dictionary &ext = material_extensions["KHR_materials_transmission"];
				float v = 0.0f;
				if (read_ext_float(ext, "transmissionFactor", v)) {
					material->set_transmission(v);
				}
				note_dropped_texture(ext, "transmissionTexture");
			}

			if (material_extensions.has("KHR_materials_ior")) {
				const Dictionary &ext = material_extensions["KHR_materials_ior"];
				float v = 1.5f;
				if (read_ext_float(ext, "ior", v)) {
					// No clamping, matching Blender's importer. ior == 0.0 is
					// legal glTF and means "no refraction, F0 = 0".
					material->set_ior(v);
				}
			}

			if (material_extensions.has("KHR_materials_volume")) {
				const Dictionary &ext = material_extensions["KHR_materials_volume"];
				float v = 0.0f;
				if (read_ext_float(ext, "thicknessFactor", v)) {
					material->set_thickness(v);
				}
				// glTF default is infinity, which we represent as 0. A
				// non-positive authored value means the same thing.
				float dist = 0.0f;
				if (read_ext_float(ext, "attenuationDistance", dist)) {
					material->set_attenuation_distance(dist > 0.0f ? dist : 0.0f);
				}
				Color c;
				if (read_ext_color(ext, "attenuationColor", c)) {
					material->set_attenuation_color(c);
				}
				note_dropped_texture(ext, "thicknessTexture");
			}

			if (material_extensions.has("KHR_materials_specular")) {
				const Dictionary &ext = material_extensions["KHR_materials_specular"];
				float v = 1.0f;
				if (read_ext_float(ext, "specularFactor", v)) {
					material->set_specular_factor(v);
				}
				Color c;
				if (read_ext_color(ext, "specularColorFactor", c)) {
					material->set_specular_tint(c);
				}
				note_dropped_texture(ext, "specularTexture");
				note_dropped_texture(ext, "specularColorTexture");
			}

			if (material_extensions.has("KHR_materials_clearcoat")) {
				const Dictionary &ext = material_extensions["KHR_materials_clearcoat"];
				bool any = false;
				float v = 0.0f;
				if (read_ext_float(ext, "clearcoatFactor", v)) {
					material->set_clearcoat(v);
					any = true;
				}
				float r = 0.0f;
				if (read_ext_float(ext, "clearcoatRoughnessFactor", r)) {
					material->set_clearcoat_roughness(r);
					any = true;
				}
				if (any) {
					// _validate_property hides clearcoat while the feature is
					// off, so without this the data imports but is not
					// inspectable.
					material->set_feature(BaseMaterial3D::FEATURE_CLEARCOAT, true);
				}
				note_dropped_texture(ext, "clearcoatTexture");
				note_dropped_texture(ext, "clearcoatRoughnessTexture");
				note_dropped_texture(ext, "clearcoatNormalTexture");
			}

			if (material_extensions.has("KHR_materials_sheen")) {
				const Dictionary &ext = material_extensions["KHR_materials_sheen"];
				Color c;
				if (read_ext_color(ext, "sheenColorFactor", c)) {
					material->set_sheen_color(c);
				}
				float r = 0.0f;
				if (read_ext_float(ext, "sheenRoughnessFactor", r)) {
					material->set_sheen_roughness(r);
				}
				note_dropped_texture(ext, "sheenColorTexture");
				note_dropped_texture(ext, "sheenRoughnessTexture");
			}

			if (material_extensions.has("KHR_materials_anisotropy")) {
				const Dictionary &ext = material_extensions["KHR_materials_anisotropy"];
				bool any = false;
				float s = 0.0f;
				if (read_ext_float(ext, "anisotropyStrength", s)) {
					material->set_anisotropy(s);
					any = true;
				}
				float rot = 0.0f;
				if (read_ext_float(ext, "anisotropyRotation", rot)) {
					material->set_anisotropy_rotation(rot);
					any = true;
				}
				if (any) {
					material->set_feature(BaseMaterial3D::FEATURE_ANISOTROPY, true);
				}
				note_dropped_texture(ext, "anisotropyTexture");
			}

			if (!dropped_textures.is_empty()) {
				WARN_PRINT(vformat(
						"glTF material '%s': ignoring unsupported extension texture(s): %s. "
						"Factors were imported; per-parameter extension textures are not yet supported.",
						material->get_name(), String(", ").join(dropped_textures)));
			}
		}
```

Add `#include <cmath>` to the include block at the top of `gltf_document.cpp` if `std::isfinite` is not already available.

- [ ] **Step 5: Declare the extensions as supported**

In `get_supported_gltf_extensions_hashset` (`:6967`), alongside the existing inserts:

```cpp
	supported_extensions.insert("KHR_materials_anisotropy");
	supported_extensions.insert("KHR_materials_clearcoat");
	supported_extensions.insert("KHR_materials_ior");
	supported_extensions.insert("KHR_materials_sheen");
	supported_extensions.insert("KHR_materials_specular");
	supported_extensions.insert("KHR_materials_transmission");
	supported_extensions.insert("KHR_materials_volume");
```

Without these, a GLB listing any of them in `extensionsRequired` is rejected outright at `:7379-7382`.

- [ ] **Step 6: Run the tests to verify they pass**

```bash
scons platform=windows tests=yes target=editor
```

```bash
bin/godot.windows.editor.x86_64.console.exe --test "*GLTFDocument*"
```

Expected: PASS, including the two new cases and all pre-existing ones.

- [ ] **Step 7: Prove the fixture test can fail**

Temporarily swap two setters in the import block — change `material->set_sheen_roughness(r);` to `material->set_specular_factor(r);` — rebuild, and run the test.

Expected: FAIL on both `get_specular_factor` and `get_sheen_roughness`. Revert the swap, rebuild, confirm PASS. **Record the observed failure output in your task report.** A fixture whose values cannot distinguish two fields is worthless, and this is how you demonstrate these can.

- [ ] **Step 8: Commit**

```bash
git add modules/gltf/gltf_document.cpp tests/data/models/material_extensions.gltf tests/scene/test_gltf_document.cpp
git commit -m "feat(gltf): import seven material extensions as factors"
```

---

## Task 3: glTF export and closed-loop round-trip

**Files:**
- Modify: `modules/gltf/gltf_document.cpp` (material serialisation `:2918-2931`)
- Modify: `tests/scene/test_gltf_document.cpp`

**Interfaces:**
- Consumes: the ten getters from Task 1 and the import blocks from Task 2.
- Produces: a `.gltf`/`.glb` written by `write_to_filesystem` that carries all seven extensions. Nothing later depends on it.

- [ ] **Step 1: Write the failing test**

Add to `tests/scene/test_gltf_document.cpp`. Add `#include "scene/3d/mesh_instance_3d.h"` and `#include "scene/resources/3d/primitive_meshes.h"` to the include block if not present.

```cpp
TEST_CASE("[SceneTree][GLTFDocument] Material extensions survive a full round-trip") {
	register_gltf_extension();

	// Build a scene with one mesh carrying a fully-populated material. Every
	// value is distinct from every other and from its own default, so a field
	// swap anywhere in import or export shows up here.
	Ref<StandardMaterial3D> mat;
	mat.instantiate();
	mat->set_transmission(0.35f);
	mat->set_ior(1.72f);
	mat->set_thickness(2.4f);
	mat->set_attenuation_distance(5.0f);
	mat->set_attenuation_color(Color(0.9f, 0.4f, 0.15f).linear_to_srgb());
	mat->set_specular_factor(0.62f);
	mat->set_specular_tint(Color(0.8f, 0.7f, 0.55f).linear_to_srgb());
	mat->set_sheen_color(Color(0.25f, 0.5f, 0.75f).linear_to_srgb());
	mat->set_sheen_roughness(0.45f);
	mat->set_anisotropy_rotation(1.1f);
	mat->set_feature(BaseMaterial3D::FEATURE_CLEARCOAT, true);
	mat->set_clearcoat(0.55f);
	mat->set_clearcoat_roughness(0.28f);
	mat->set_feature(BaseMaterial3D::FEATURE_ANISOTROPY, true);
	mat->set_anisotropy(0.83f);

	Ref<BoxMesh> mesh;
	mesh.instantiate();
	mesh->surface_set_material(0, mat);

	MeshInstance3D *mesh_instance = memnew(MeshInstance3D);
	mesh_instance->set_mesh(mesh);
	SceneTree::get_singleton()->get_root()->add_child(mesh_instance);

	Ref<GLTFDocument> doc_save;
	doc_save.instantiate();
	Ref<GLTFState> state_save;
	state_save.instantiate();
	REQUIRE(doc_save->append_from_scene(mesh_instance, state_save) == OK);
	const String path = TestUtils::get_temp_path("material_extensions_roundtrip.gltf");
	REQUIRE(doc_save->write_to_filesystem(state_save, path) == OK);

	Ref<GLTFDocument> doc_load;
	doc_load.instantiate();
	Ref<GLTFState> state_load;
	state_load.instantiate();
	REQUIRE(doc_load->append_from_file(path, state_load) == OK);

	const Vector<Ref<Material>> &materials = state_load->get_materials();
	REQUIRE(materials.size() >= 1);
	Ref<StandardMaterial3D> out = materials[0];
	REQUIRE(out.is_valid());

	// Scalars survive exactly: nothing transforms them in either direction.
	CHECK(out->get_transmission() == doctest::Approx(0.35f));
	CHECK(out->get_ior() == doctest::Approx(1.72f));
	CHECK(out->get_thickness() == doctest::Approx(2.4f));
	CHECK(out->get_attenuation_distance() == doctest::Approx(5.0f));
	CHECK(out->get_specular_factor() == doctest::Approx(0.62f));
	CHECK(out->get_sheen_roughness() == doctest::Approx(0.45f));
	CHECK(out->get_anisotropy_rotation() == doctest::Approx(1.1f));
	CHECK(out->get_clearcoat() == doctest::Approx(0.55f));
	CHECK(out->get_clearcoat_roughness() == doctest::Approx(0.28f));
	CHECK(out->get_anisotropy() == doctest::Approx(0.83f));

	// Colours go sRGB -> linear on export and back on import. That is the
	// identity only to float precision, so this must be approximate. Comparing
	// for equality here would produce a flaky suite.
	CHECK(out->get_attenuation_color().is_equal_approx(mat->get_attenuation_color()));
	CHECK(out->get_specular_tint().is_equal_approx(mat->get_specular_tint()));
	CHECK(out->get_sheen_color().is_equal_approx(mat->get_sheen_color()));

	memdelete(mesh_instance);
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
scons platform=windows tests=yes target=editor
```

```bash
bin/godot.windows.editor.x86_64.console.exe --test "*round-trip*"
```

Expected: FAIL. Every value comes back at its default because nothing is written to the file yet.

- [ ] **Step 3: Add the export blocks**

In `modules/gltf/gltf_document.cpp`, immediately after the `KHR_materials_emissive_strength` export block (`:2929`) and before `if (!extensions.is_empty())` (`:2930`):

```cpp
		// Path-tracer material parameters. Each extension is written only when
		// it differs from the glTF default, so ordinary materials produce no
		// extension bloat. Colours convert sRGB -> linear, inverting import.
		if (!Math::is_zero_approx(base_material->get_transmission())) {
			Dictionary ext;
			ext["transmissionFactor"] = base_material->get_transmission();
			extensions["KHR_materials_transmission"] = ext;
			p_state->add_used_extension("KHR_materials_transmission");
		}

		if (!Math::is_equal_approx(base_material->get_ior(), 1.5f)) {
			Dictionary ext;
			ext["ior"] = base_material->get_ior();
			extensions["KHR_materials_ior"] = ext;
			p_state->add_used_extension("KHR_materials_ior");
		}

		{
			Dictionary ext;
			if (!Math::is_zero_approx(base_material->get_thickness())) {
				ext["thicknessFactor"] = base_material->get_thickness();
			}
			// 0 is our representation of glTF's infinite default, which is
			// expressed by omitting the key.
			if (base_material->get_attenuation_distance() > 0.0f) {
				ext["attenuationDistance"] = base_material->get_attenuation_distance();
			}
			const Color atten = base_material->get_attenuation_color().srgb_to_linear();
			if (!atten.is_equal_approx(Color(1, 1, 1))) {
				Array arr;
				arr.push_back(atten.r);
				arr.push_back(atten.g);
				arr.push_back(atten.b);
				ext["attenuationColor"] = arr;
			}
			if (!ext.is_empty()) {
				extensions["KHR_materials_volume"] = ext;
				p_state->add_used_extension("KHR_materials_volume");
			}
		}

		{
			Dictionary ext;
			if (!Math::is_equal_approx(base_material->get_specular_factor(), 1.0f)) {
				ext["specularFactor"] = base_material->get_specular_factor();
			}
			const Color tint = base_material->get_specular_tint().srgb_to_linear();
			if (!tint.is_equal_approx(Color(1, 1, 1))) {
				Array arr;
				arr.push_back(tint.r);
				arr.push_back(tint.g);
				arr.push_back(tint.b);
				ext["specularColorFactor"] = arr;
			}
			if (!ext.is_empty()) {
				extensions["KHR_materials_specular"] = ext;
				p_state->add_used_extension("KHR_materials_specular");
			}
		}

		if (base_material->get_feature(BaseMaterial3D::FEATURE_CLEARCOAT)) {
			Dictionary ext;
			if (!Math::is_zero_approx(base_material->get_clearcoat())) {
				ext["clearcoatFactor"] = base_material->get_clearcoat();
			}
			if (!Math::is_zero_approx(base_material->get_clearcoat_roughness())) {
				ext["clearcoatRoughnessFactor"] = base_material->get_clearcoat_roughness();
			}
			if (!ext.is_empty()) {
				extensions["KHR_materials_clearcoat"] = ext;
				p_state->add_used_extension("KHR_materials_clearcoat");
			}
		}

		{
			Dictionary ext;
			const Color sheen = base_material->get_sheen_color().srgb_to_linear();
			if (!sheen.is_equal_approx(Color(0, 0, 0))) {
				Array arr;
				arr.push_back(sheen.r);
				arr.push_back(sheen.g);
				arr.push_back(sheen.b);
				ext["sheenColorFactor"] = arr;
			}
			if (!Math::is_zero_approx(base_material->get_sheen_roughness())) {
				ext["sheenRoughnessFactor"] = base_material->get_sheen_roughness();
			}
			if (!ext.is_empty()) {
				extensions["KHR_materials_sheen"] = ext;
				p_state->add_used_extension("KHR_materials_sheen");
			}
		}

		if (base_material->get_feature(BaseMaterial3D::FEATURE_ANISOTROPY)) {
			Dictionary ext;
			if (!Math::is_zero_approx(base_material->get_anisotropy())) {
				ext["anisotropyStrength"] = base_material->get_anisotropy();
			}
			if (!Math::is_zero_approx(base_material->get_anisotropy_rotation())) {
				ext["anisotropyRotation"] = base_material->get_anisotropy_rotation();
			}
			if (!ext.is_empty()) {
				extensions["KHR_materials_anisotropy"] = ext;
				p_state->add_used_extension("KHR_materials_anisotropy");
			}
		}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
scons platform=windows tests=yes target=editor
```

```bash
bin/godot.windows.editor.x86_64.console.exe --test "*GLTFDocument*"
```

Expected: PASS, all cases including Task 2's.

- [ ] **Step 5: Confirm the fixture test still passes independently**

```bash
bin/godot.windows.editor.x86_64.console.exe --test "*Import glTF material extensions*"
```

Expected: PASS. This is the check that our key names match Khronos and not merely each other — the round-trip test cannot make that claim.

- [ ] **Step 6: Commit**

```bash
git add modules/gltf/gltf_document.cpp tests/scene/test_gltf_document.cpp
git commit -m "feat(gltf): export seven material extensions, closing the round-trip"
```

---

## Task 4: Widen `RT_MaterialData` to carry the new parameters

**Files:**
- Modify: `servers/rendering/renderer_rd/forward_clustered/render_raytracing.h:106-124`
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_data_inc.glsl:123-145`
- Modify: `servers/rendering/renderer_rd/forward_clustered/render_raytracing.cpp` (`:1371-1380`, `:1429-1450`, after `:1678`)

**Interfaces:**
- Consumes: the ten parameter names from Task 1, read via `material_get_param`. **Anisotropy strength is read under the name `"anisotropy_ratio"`, not `"anisotropy"`** — see `material.cpp:574`.
- Produces: GLSL `MaterialData` fields `transmission`, `ior`, `thickness`, `attenuation_density`, `attenuation_color`, `specular_factor`, `specular_tint`, `sheen_roughness`, `sheen_color`, `anisotropy_rotation`, `clearcoat`, `clearcoat_roughness`, `anisotropy`. Task 5 reads these in the debug visualiser.

- [ ] **Step 1: Widen the C++ struct and add the asserts**

In `render_raytracing.h`, replace the tail of `RT_MaterialData` — from `float normal_map_depth;` through the closing `static_assert` — with:

```cpp
	float normal_map_depth; // Strength [0..N], default 1.0 (not Z-depth).
	float specular; // Dielectric specular [0..1], default 0.5 -> F0 = 0.04.
	uint64_t uniform_address; // BDA for custom shader uniform buffer (0 = none).
	// --- Phase D: glTF material extension data. Nothing reads these yet. ---
	float transmission;
	float ior;
	float thickness;
	float attenuation_density; // Reciprocal of attenuation_distance; 0 = none.
	float attenuation_color[3];
	float specular_factor;
	float specular_tint[3];
	float sheen_roughness;
	float sheen_color[3];
	float anisotropy_rotation; // Radians.
	float clearcoat;
	float clearcoat_roughness;
	float anisotropy;
	float _pad0;
};
static_assert(sizeof(RT_MaterialData) == 176, "RT_MaterialData must be 176 bytes for std430");
// A vec3 aligns to 16 bytes in std430, so reordering members around one shifts
// the GPU's view of every subsequent field WITHOUT changing sizeof. The size
// assert alone passes on a broken layout; these three are what catch it.
static_assert(offsetof(RT_MaterialData, attenuation_color) == 112, "attenuation_color must be 16-byte aligned for std430 vec3");
static_assert(offsetof(RT_MaterialData, specular_tint) == 128, "specular_tint must be 16-byte aligned for std430 vec3");
static_assert(offsetof(RT_MaterialData, sheen_color) == 144, "sheen_color must be 16-byte aligned for std430 vec3");
```

- [ ] **Step 2: Build to verify the asserts hold**

```bash
scons platform=windows tests=yes target=editor
```

Expected: compiles clean. A `static_assert` failure here means the layout table in the spec was mis-transcribed — fix the member order, not the assert.

- [ ] **Step 3: Update the GLSL twin**

In `raytracing_data_inc.glsl`, change the header comment to `// MATERIAL DATA (matches C++ layout, 176 bytes)` and append to `struct MaterialData`, after `uint64_t uniform_address;`:

```glsl
	// --- Phase D: glTF material extension data. Nothing reads these yet. ---
	float transmission;
	float ior;
	float thickness;
	float attenuation_density; // Reciprocal of attenuation_distance; 0 = none.
	vec3 attenuation_color;
	float specular_factor;
	vec3 specular_tint;
	float sheen_roughness;
	vec3 sheen_color;
	float anisotropy_rotation; // Radians.
	float clearcoat;
	float clearcoat_roughness;
	float anisotropy;
	float _pad0;
```

- [ ] **Step 4: Initialise the defaults at both default sites**

In `render_raytracing.cpp`, in the `s_default_mat` initialiser block (`:1371-1380`), before `s_default_mat_initialized = true;`:

```cpp
		s_default_mat.data.ior = 1.5f;
		s_default_mat.data.specular_factor = 1.0f;
		s_default_mat.data.attenuation_color[0] = 1.0f;
		s_default_mat.data.attenuation_color[1] = 1.0f;
		s_default_mat.data.attenuation_color[2] = 1.0f;
		s_default_mat.data.specular_tint[0] = 1.0f;
		s_default_mat.data.specular_tint[1] = 1.0f;
		s_default_mat.data.specular_tint[2] = 1.0f;
```

And in the per-material defaults block, immediately after `mat.uniform_address = 0;` (`:1450`):

```cpp
	mat.transmission = 0.0f;
	mat.ior = 1.5f;
	mat.thickness = 0.0f;
	mat.attenuation_density = 0.0f;
	mat.attenuation_color[0] = 1.0f;
	mat.attenuation_color[1] = 1.0f;
	mat.attenuation_color[2] = 1.0f;
	mat.specular_factor = 1.0f;
	mat.specular_tint[0] = 1.0f;
	mat.specular_tint[1] = 1.0f;
	mat.specular_tint[2] = 1.0f;
	mat.sheen_roughness = 0.0f;
	mat.sheen_color[0] = 0.0f;
	mat.sheen_color[1] = 0.0f;
	mat.sheen_color[2] = 0.0f;
	mat.anisotropy_rotation = 0.0f;
	mat.clearcoat = 0.0f;
	mat.clearcoat_roughness = 0.0f;
	mat.anisotropy = 0.0f;
	mat._pad0 = 0.0f;
```

The two sites are not the same code path — `s_default_mat` serves invalid material RIDs, the other serves every real material — and both must be kept in lockstep with the struct.

- [ ] **Step 5: Read the parameters**

In `render_raytracing.cpp`, immediately after the `specular_var` block (`:1675-1678`):

```cpp
	// Phase D: glTF material extension parameters. Nothing in the shader reads
	// these yet; they are carried so Phase E has data to consume.
	Variant transmission_var = material_storage->material_get_param(p_material_rid, "transmission");
	if (transmission_var.get_type() == Variant::FLOAT) {
		mat.transmission = transmission_var;
	}

	Variant ior_var = material_storage->material_get_param(p_material_rid, "ior");
	if (ior_var.get_type() == Variant::FLOAT) {
		mat.ior = ior_var;
	}

	Variant thickness_var = material_storage->material_get_param(p_material_rid, "thickness");
	if (thickness_var.get_type() == Variant::FLOAT) {
		mat.thickness = thickness_var;
	}

	// The property is a distance; the GPU carries its reciprocal so density 0
	// means "no absorption" with no shader branch and no division at use.
	Variant attenuation_distance_var = material_storage->material_get_param(p_material_rid, "attenuation_distance");
	if (attenuation_distance_var.get_type() == Variant::FLOAT) {
		const float d = attenuation_distance_var;
		mat.attenuation_density = (d > 0.0f) ? (1.0f / d) : 0.0f;
	}

	Variant attenuation_color_var = material_storage->material_get_param(p_material_rid, "attenuation_color");
	if (attenuation_color_var.get_type() == Variant::COLOR) {
		Color c = ((Color)attenuation_color_var).srgb_to_linear();
		mat.attenuation_color[0] = c.r;
		mat.attenuation_color[1] = c.g;
		mat.attenuation_color[2] = c.b;
	}

	Variant specular_factor_var = material_storage->material_get_param(p_material_rid, "specular_factor");
	if (specular_factor_var.get_type() == Variant::FLOAT) {
		mat.specular_factor = specular_factor_var;
	}

	Variant specular_tint_var = material_storage->material_get_param(p_material_rid, "specular_tint");
	if (specular_tint_var.get_type() == Variant::COLOR) {
		Color c = ((Color)specular_tint_var).srgb_to_linear();
		mat.specular_tint[0] = c.r;
		mat.specular_tint[1] = c.g;
		mat.specular_tint[2] = c.b;
	}

	Variant sheen_color_var = material_storage->material_get_param(p_material_rid, "sheen_color");
	if (sheen_color_var.get_type() == Variant::COLOR) {
		Color c = ((Color)sheen_color_var).srgb_to_linear();
		mat.sheen_color[0] = c.r;
		mat.sheen_color[1] = c.g;
		mat.sheen_color[2] = c.b;
	}

	Variant sheen_roughness_var = material_storage->material_get_param(p_material_rid, "sheen_roughness");
	if (sheen_roughness_var.get_type() == Variant::FLOAT) {
		mat.sheen_roughness = sheen_roughness_var;
	}

	Variant anisotropy_rotation_var = material_storage->material_get_param(p_material_rid, "anisotropy_rotation");
	if (anisotropy_rotation_var.get_type() == Variant::FLOAT) {
		mat.anisotropy_rotation = anisotropy_rotation_var;
	}

	Variant clearcoat_var = material_storage->material_get_param(p_material_rid, "clearcoat");
	if (clearcoat_var.get_type() == Variant::FLOAT) {
		mat.clearcoat = clearcoat_var;
	}

	Variant clearcoat_roughness_var = material_storage->material_get_param(p_material_rid, "clearcoat_roughness");
	if (clearcoat_roughness_var.get_type() == Variant::FLOAT) {
		mat.clearcoat_roughness = clearcoat_roughness_var;
	}

	// BaseMaterial3D's anisotropy parameter is named "anisotropy_ratio", not
	// "anisotropy" (scene/resources/material.cpp:574). Reading "anisotropy"
	// here would silently return nothing.
	Variant anisotropy_var = material_storage->material_get_param(p_material_rid, "anisotropy_ratio");
	if (anisotropy_var.get_type() == Variant::FLOAT) {
		mat.anisotropy = anisotropy_var;
	}
```

- [ ] **Step 6: Full rebuild and suite run**

A `.glsl` changed, so the `.glsl.gen.h` must regenerate — a full build, not an incremental one.

```bash
scons platform=windows tests=yes target=editor
```

```bash
bin/godot.windows.editor.x86_64.console.exe --test
```

Expected: the suite passes with no new failures against the Phase C baseline of 1481 passed / 0 failed / 3 skipped.

- [ ] **Step 7: Commit**

```bash
git add servers/rendering/renderer_rd/forward_clustered/render_raytracing.h servers/rendering/renderer_rd/forward_clustered/render_raytracing.cpp servers/rendering/renderer_rd/shaders/raytracing/raytracing_data_inc.glsl
git commit -m "feat(pt): RT_MaterialData carries glTF extension parameters (96 -> 176 bytes)"
```

---

## Task 5: GPU arrival gate

**Files:**
- Modify: `scene/resources/environment.h` (`PathtracingDebugMode` enum), `scene/resources/environment.cpp` (`BIND_ENUM_CONSTANT`, property hint `:1616`)
- Modify: `doc/classes/Environment.xml`
- Modify: `.../shaders/raytracing/raytracing_closest_hit_common_inc.glsl` (`debug_visualize` signature `:327-342`, new branches after the `vis_mode == 22` block)
- Modify: `.../shaders/raytracing/scene_raytracing_raygen.glsl` (call sites near `:502` and `:565`)
- Create: `pipeline_references/tests/pt_material_data_gate.gd`, `pipeline_references/tests/pt_material_data_gate_scene.tscn`

**Interfaces:**
- Consumes: the GLSL `MaterialData` fields from Task 4, and the ten `BaseMaterial3D` setters from Task 1.
- Produces: nothing later depends on this.

### Why this task exists

Task 4's `static_assert`s check the C++ side of the struct twin only. **Nothing in the codebase compares `RT_MaterialData` to its GLSL counterpart**, and the headless test renderer discards material parameters entirely (Task 1), so the parameter-name wiring added in Task 4 is at this point completely unverified. This gate is the only thing in Phase D that proves a value authored in GDScript arrives in the shader under the right name at the right offset.

- [ ] **Step 1: Add the debug mode enum constants**

In `scene/resources/environment.h`, insert before `RT_DEBUG_MAX`:

```cpp
		RT_DEBUG_MAT_TRANSMISSION_IOR_THICKNESS,
		RT_DEBUG_MAT_DENSITY_SPECULAR_SHEENROUGH,
		RT_DEBUG_MAT_CLEARCOAT_ANISOTROPY,
		RT_DEBUG_MAT_ANISOTROPY_ROTATION,
		RT_DEBUG_MAT_ATTENUATION_COLOR,
		RT_DEBUG_MAT_SPECULAR_TINT,
		RT_DEBUG_MAT_SHEEN_COLOR,
```

These become values 23 through 29 respectively, since `RT_DEBUG_BRDF_REJECTION` is 22.

In `scene/resources/environment.cpp`, extend the property hint string at `:1616` by appending to the enum list, after `BRDF Rejection`:

```
,Mat: Transmission/IOR/Thickness,Mat: Density/Specular/SheenRough,Mat: Clearcoat/Anisotropy,Mat: Anisotropy Rotation,Mat: Attenuation Color,Mat: Specular Tint,Mat: Sheen Color
```

Add the matching `BIND_ENUM_CONSTANT` lines alongside the existing `PathtracingDebugMode` bindings:

```cpp
	BIND_ENUM_CONSTANT(RT_DEBUG_MAT_TRANSMISSION_IOR_THICKNESS);
	BIND_ENUM_CONSTANT(RT_DEBUG_MAT_DENSITY_SPECULAR_SHEENROUGH);
	BIND_ENUM_CONSTANT(RT_DEBUG_MAT_CLEARCOAT_ANISOTROPY);
	BIND_ENUM_CONSTANT(RT_DEBUG_MAT_ANISOTROPY_ROTATION);
	BIND_ENUM_CONSTANT(RT_DEBUG_MAT_ATTENUATION_COLOR);
	BIND_ENUM_CONSTANT(RT_DEBUG_MAT_SPECULAR_TINT);
	BIND_ENUM_CONSTANT(RT_DEBUG_MAT_SHEEN_COLOR);
```

Document the seven new constants in `doc/classes/Environment.xml` alongside the existing `RT_DEBUG_*` entries.

- [ ] **Step 2: Give `debug_visualize` access to the material**

`debug_visualize` currently receives unpacked scalars and no `MaterialData`, so it cannot read the new fields. In `raytracing_closest_hit_common_inc.glsl`, add a final parameter to the signature at `:327-342`:

```glsl
		vec3 V,
		float NdotV,
		MaterialData dbg_material) {
```

In `scene_raytracing_raygen.glsl`, update both call sites. At the custom-hit-group site near `:502`, which has no `MaterialData` in scope, fetch it from the same buffer the other branch uses:

```glsl
			debug_visualize(VIS_MODE, h.geometry_normal, m.normal, normal_map,
					h.tangent, h.bitangent, h.uv, m.albedo, orm, m.metalness, m.roughness, m.specular, m.emissive, V, NdotV,
					materials[h.geometry_idx]);
```

At the StandardMaterial3D site near `:565`, `mat` is already in scope:

```glsl
			debug_visualize(VIS_MODE, h.geometry_normal, final_normal, tangent_space_normal,
					h.tangent, h.bitangent, uv, albedo, orm, metalness, roughness, mat.specular, emissive, V, NdotV,
					mat);
```

- [ ] **Step 3: Add the seven visualisation branches**

In `raytracing_closest_hit_common_inc.glsl`, after the `vis_mode == 22` block closes and before the chain's final `}`:

```glsl
	} else if (vis_mode == 23) {
		// Phase D material-arrival probes. Raw, unscaled values: the
		// accumulation target is float, so nothing needs remapping and values
		// above 1.0 survive readback intact.
		ps.radiance = vec3(dbg_material.transmission, dbg_material.ior, dbg_material.thickness);
	} else if (vis_mode == 24) {
		ps.radiance = vec3(dbg_material.attenuation_density, dbg_material.specular_factor, dbg_material.sheen_roughness);
	} else if (vis_mode == 25) {
		ps.radiance = vec3(dbg_material.clearcoat, dbg_material.clearcoat_roughness, dbg_material.anisotropy);
	} else if (vis_mode == 26) {
		ps.radiance = vec3(dbg_material.anisotropy_rotation, 0.0, 0.0);
	} else if (vis_mode == 27) {
		ps.radiance = dbg_material.attenuation_color;
	} else if (vis_mode == 28) {
		ps.radiance = dbg_material.specular_tint;
	} else if (vis_mode == 29) {
		ps.radiance = dbg_material.sheen_color;
```

- [ ] **Step 4: Write the gate scene**

Create `pipeline_references/tests/pt_material_data_gate_scene.tscn`: a `Node3D` root with the `pt_material_data_gate.gd` script attached, a `Camera3D` at `(0, 0, 3)` looking down `-Z`, a `MeshInstance3D` with a `BoxMesh` of size `(4, 4, 0.1)` at the origin filling the view, and a `WorldEnvironment` with a new `Environment`. Set the environment's background to `BG_COLOR` with a black clear colour. No lights are needed: the debug modes short-circuit before any shading.

- [ ] **Step 5: Write the gate script**

Create `pipeline_references/tests/pt_material_data_gate.gd`:

```gdscript
extends "res://tests/pt_validation.gd"

## Phase D material-arrival gate.
##
##   bin\godot.windows.editor.x86_64.console.exe --path pipeline_references \
##       res://tests/pt_material_data_gate_scene.tscn
##
## WHAT THIS PROVES, AND WHY NOTHING ELSE IN PHASE D PROVES IT.
##
## Task 4 added static_asserts on RT_MaterialData. Those check the C++ side of
## the struct twin ONLY -- nothing in the codebase compares it to the GLSL
## MaterialData. And the headless doctest renderer discards material parameters
## outright (servers/rendering/dummy/storage/material_storage.h:123-124 are both
## no-ops), so no doctest can check that a property reaches the parameter map
## under the right name either.
##
## This gate closes both holes at once: it authors thirteen distinct values in
## GDScript and reads them back out of the shader. A wrong parameter name, a
## wrong struct offset, or a C++/GLSL layout disagreement all show up here as a
## specific field reading the wrong number.

const MODE_TRANSMISSION_IOR_THICKNESS := 23
const MODE_DENSITY_SPECULAR_SHEENROUGH := 24
const MODE_CLEARCOAT_ANISOTROPY := 25
const MODE_ANISOTROPY_ROTATION := 26
const MODE_ATTENUATION_COLOR := 27
const MODE_SPECULAR_TINT := 28
const MODE_SHEEN_COLOR := 29

## Values are pairwise distinct and every one differs from its own default, so a
## field swap between any two of them fails a specific assertion rather than
## cancelling out.
const V_TRANSMISSION := 0.35
const V_IOR := 1.72
const V_THICKNESS := 2.4
const V_ATTENUATION_DISTANCE := 5.0
const V_ATTENUATION_DENSITY := 0.2   # 1.0 / V_ATTENUATION_DISTANCE
const V_SPECULAR_FACTOR := 0.62
const V_SHEEN_ROUGHNESS := 0.45
const V_ANISOTROPY_ROTATION := 1.1
const V_CLEARCOAT := 0.55
const V_CLEARCOAT_ROUGHNESS := 0.28
const V_ANISOTROPY := 0.83
const V_ATTENUATION_COLOR := Color(0.9, 0.4, 0.15)   # linear
const V_SPECULAR_TINT := Color(0.8, 0.7, 0.55)       # linear
const V_SHEEN_COLOR := Color(0.25, 0.5, 0.75)        # linear

## Debug modes write the material value straight to radiance with no shading, so
## the only error is float storage. This is generous enough for that and far
## tighter than the smallest gap between any two fixture values (0.03).
const TOLERANCE := 1e-4

var _failures: int = 0
var _checks: int = 0

func _ready() -> void:
	var mesh_instance: MeshInstance3D = $MeshInstance3D
	var mat := StandardMaterial3D.new()
	mat.transmission = V_TRANSMISSION
	mat.ior = V_IOR
	mat.thickness = V_THICKNESS
	mat.attenuation_distance = V_ATTENUATION_DISTANCE
	mat.attenuation_color = V_ATTENUATION_COLOR.linear_to_srgb()
	mat.specular_factor = V_SPECULAR_FACTOR
	mat.specular_tint = V_SPECULAR_TINT.linear_to_srgb()
	mat.sheen_color = V_SHEEN_COLOR.linear_to_srgb()
	mat.sheen_roughness = V_SHEEN_ROUGHNESS
	mat.anisotropy_rotation = V_ANISOTROPY_ROTATION
	mat.clearcoat_enabled = true
	mat.clearcoat = V_CLEARCOAT
	mat.clearcoat_roughness = V_CLEARCOAT_ROUGHNESS
	mat.anisotropy_enabled = true
	mat.anisotropy = V_ANISOTROPY
	mesh_instance.material_override = mat

	var env: Environment = $WorldEnvironment.environment
	env.set_pathtracing_enabled(true)
	env.set_pathtracing_max_bounces(1)
	env.set_pathtracing_samples_per_pixel(1)
	env.set_pathtracing_denoiser(0)
	env.set_pathtracing_oidn_denoise(false)
	env.set_pathtracing_dlss_rr_final(false)

	await _check_mode(env, MODE_TRANSMISSION_IOR_THICKNESS,
			"transmission/ior/thickness",
			Vector3(V_TRANSMISSION, V_IOR, V_THICKNESS))
	await _check_mode(env, MODE_DENSITY_SPECULAR_SHEENROUGH,
			"attenuation_density/specular_factor/sheen_roughness",
			Vector3(V_ATTENUATION_DENSITY, V_SPECULAR_FACTOR, V_SHEEN_ROUGHNESS))
	await _check_mode(env, MODE_CLEARCOAT_ANISOTROPY,
			"clearcoat/clearcoat_roughness/anisotropy",
			Vector3(V_CLEARCOAT, V_CLEARCOAT_ROUGHNESS, V_ANISOTROPY))
	await _check_mode(env, MODE_ANISOTROPY_ROTATION,
			"anisotropy_rotation",
			Vector3(V_ANISOTROPY_ROTATION, 0.0, 0.0))
	await _check_mode(env, MODE_ATTENUATION_COLOR,
			"attenuation_color",
			Vector3(V_ATTENUATION_COLOR.r, V_ATTENUATION_COLOR.g, V_ATTENUATION_COLOR.b))
	await _check_mode(env, MODE_SPECULAR_TINT,
			"specular_tint",
			Vector3(V_SPECULAR_TINT.r, V_SPECULAR_TINT.g, V_SPECULAR_TINT.b))
	await _check_mode(env, MODE_SHEEN_COLOR,
			"sheen_color",
			Vector3(V_SHEEN_COLOR.r, V_SHEEN_COLOR.g, V_SHEEN_COLOR.b))

	print("")
	if _failures == 0:
		print("PASS: all %d material fields arrived in the shader intact." % _checks)
	else:
		print("FAIL: %d of %d material field checks did not match." % [_failures, _checks])
	get_tree().quit(1 if _failures > 0 else 0)

func _check_mode(p_env: Environment, p_mode: int, p_label: String, p_expected: Vector3) -> void:
	p_env.set_pathtracing_debug_mode(p_mode)
	var img: Image = await _render_accum(p_env, get_viewport().get_viewport_rid(), 1)
	# Sample the image centre, which the quad fills.
	var px: Color = img.get_pixel(img.get_width() / 2, img.get_height() / 2)
	var got := Vector3(px.r, px.g, px.b)
	for i in 3:
		if p_expected[i] == 0.0 and i > 0:
			continue # Unused channel in single-value modes.
		_checks += 1
		var delta: float = abs(got[i] - p_expected[i])
		if delta > TOLERANCE:
			_failures += 1
			print("  FAIL  %s[%d]: expected %.6f, got %.6f (delta %.6g)"
					% [p_label, i, p_expected[i], got[i], delta])
		else:
			print("  ok    %s[%d]: %.6f" % [p_label, i, got[i]])
```

- [ ] **Step 6: Full rebuild and run the gate**

```bash
scons platform=windows tests=yes target=editor
```

```bash
bin/godot.windows.editor.x86_64.console.exe --path pipeline_references res://tests/pt_material_data_gate_scene.tscn
```

Expected: `PASS: all N material fields arrived in the shader intact.`

If a *specific* field is wrong, the parameter name for that field is wrong in Task 4's read block. If *every* field from some offset onward is wrong, the C++ and GLSL structs disagree about layout — re-check the member order against Task 4 Step 1.

- [ ] **Step 7: Prove the gate can fail**

Temporarily swap two fields in the vis mode 23 branch — write `dbg_material.ior, dbg_material.transmission` instead of `dbg_material.transmission, dbg_material.ior` — rebuild, and run.

Expected: FAIL on both channel 0 and channel 1 of `transmission/ior/thickness`. Revert, rebuild, confirm PASS. **Record the observed failure output in your task report.**

- [ ] **Step 8: Commit**

```bash
git add scene/resources/environment.h scene/resources/environment.cpp doc/classes/Environment.xml servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl servers/rendering/renderer_rd/shaders/raytracing/scene_raytracing_raygen.glsl pipeline_references/tests/pt_material_data_gate.gd pipeline_references/tests/pt_material_data_gate_scene.tscn
git commit -m "test(pt): GPU gate proving material extension data reaches the shader"
```

---

## Task 6: Measurement and closeout

**Files:**
- Modify: `PATH_TRACER_QUALITY_ROADMAP.md`

**Interfaces:**
- Consumes: everything from Tasks 1–5.
- Produces: the Phase D closeout entry.

- [ ] **Step 1: Record the pre-D reference render**

Find the commit immediately before Task 1's and check it out into a separate worktree, so the Phase D branch stays intact:

```bash
git log --oneline --grep="BaseMaterial3D carries ten path-tracer-only parameters" -1
```

Take that commit's parent, and build it in a scratch worktree:

```bash
git worktree add ../zreal-pre-d <that-sha>^
```

Build there, then run:

```bash
ZR_GATE_MODE=in_range ZR_GATE_FRAMES=2048 ZR_GATE_RES=256 bin/godot.windows.editor.x86_64.console.exe --path pipeline_references res://tests/pt_light_gate_scene.tscn
```

Record every reported figure.

- [ ] **Step 2: Repeat on the Phase D branch and compare**

Return to the Phase D head, rebuild, and run the identical command. Compare against Step 1.

Expected: identical figures. The spec's no-pixel-change invariant (§7.2) predicts bit-identical output for content carrying none of the seven extensions, because the path tracer reads none of the new values and nothing existing was overwritten.

**If the figures differ, stop and investigate before closing out.** A difference means something in Tasks 1–5 changed behaviour that was supposed to be inert — most likely a parameter name colliding with a forward+ uniform (Task 1 Step 8) or a struct offset error changing what an existing field reads.

- [ ] **Step 3: Run the acceptance check on real Blender content**

Author a GLB in Blender containing three materials — glass (Transmission Weight > 0, IOR ≠ 1.5, volume density > 0), car paint (Coat Weight > 0, Coat Roughness > 0), and fabric (Sheen Weight > 0, Sheen Roughness > 0) — and export it with the glTF exporter's material extensions enabled.

Load it in the editor:

```bash
bin/godot.windows.editor.x86_64.exe --path pipeline_references -e
```

Inspect each imported material and confirm every authored parameter is present and correct in the Inspector.

This is the only check that validates our reading of Blender's *exporter*. Tasks 2 and 3 are hermetic and cannot replace it. Record which parameters round-tripped and any that did not.

- [ ] **Step 4: Run the full suite**

```bash
bin/godot.windows.editor.x86_64.console.exe --test
```

Expected: no new failures against the Phase C baseline of 1481 passed / 0 failed / 3 skipped.

- [ ] **Step 5: Write the closeout entry**

Add a Phase D entry to `PATH_TRACER_QUALITY_ROADMAP.md` recording: which extensions landed; the measured no-pixel-change result from Step 2; the Blender acceptance result from Step 3; the suite counts; and these open items, stated plainly:

- Per-parameter extension textures are dropped with a warning. Deliberate (spec §2), not an oversight.
- `KHR_materials_iridescence` is not imported.
- F0 is double-specified: both `specular` and `ior`/`specular_factor`/`specular_tint` reach the shader, and Phase E must decide which wins.
- `ior == 0.0` is legal glTF; Phase E must not assume `ior >= 1`.
- Nothing reads any of the new values yet, so no rendered output changed and no physical correctness is claimed.

Update the ordering summary from `A1 → A2/A3/A4 → D → E → F` to mark D complete, and change the closing line "The next item is Phase D" to name Phase E.

- [ ] **Step 6: Commit**

```bash
git add PATH_TRACER_QUALITY_ROADMAP.md
git commit -m "docs(pt): Phase D closeout - material data pipeline landed"
```

---

## Self-Review

**Spec coverage.** Every numbered section maps to a task: §3.1 and §4.2 → Task 1; §4.3 and §5 → Task 2; §4.4 → Task 3; §3.2, §3.3, §3.4, §4.1 and §4.5 → Tasks 1, 2 and 4; §6.1 → Task 3 Step 1; §6.2 → Task 2 Steps 1–2; §6.3 → Task 4 Step 1; §6.4 → Task 5; §6.5 → Task 6 Steps 1–2; §6.6 → Task 2 Step 2; §7.1 → Task 6 Step 3; §8 → Task 6 Step 5.

**Deviation from the spec, recorded here rather than hidden.** Spec §6.4 assumed `debug_visualize` could read the material directly. It cannot — the function takes unpacked scalars and no `MaterialData` (`raytracing_closest_hit_common_inc.glsl:327-342`), so Task 5 Step 2 adds a parameter and updates both call sites. This does not change what the gate proves.

**Type consistency.** Property names are identical across Tasks 1, 2, 3 and 4. Fixture values are identical across Tasks 1, 2, 3 and 5. Every GLSL field name in Task 5 matches the struct written in Task 4. Anisotropy strength is read as `"anisotropy_ratio"` in Task 4 and nowhere else, matching `material.cpp:574`.
