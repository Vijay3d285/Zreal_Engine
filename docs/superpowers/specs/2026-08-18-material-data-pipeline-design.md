# Phase D — Material Data Pipeline

**Date:** 2026-08-18
**Roadmap item:** `PATH_TRACER_QUALITY_ROADMAP.md` § "Phase D — Material data pipeline"; gap analysis in §3.6.
**Status:** design approved, not yet implemented.

## 1. Goal

Make seven glTF material extensions survive the whole journey from a
Blender-authored GLB to the path tracer's GPU material struct, so that Phase E has
data to consume. Nothing in Phase E is testable until this lands.

Phase D adds **no shading**. No BSDF reads any of these values when it ships. The
deliverable is transport and inspectability, and the acceptance criterion is
correspondingly narrow (§7).

## 2. Scope

**In scope — seven extensions, factors only:**

`KHR_materials_transmission`, `KHR_materials_ior`, `KHR_materials_volume`,
`KHR_materials_specular`, `KHR_materials_clearcoat`, `KHR_materials_sheen`,
`KHR_materials_anisotropy`.

Both directions: import **and** export.

**Out of scope:**

- **Per-parameter extension textures** (`transmissionTexture`, `thicknessTexture`,
  `clearcoatTexture`, `sheenColorTexture`, `specularTexture`, `anisotropyTexture`,
  and the rest). Factors are imported; textures are dropped with a warning (§5.4).
  Glass, car paint and fabric are overwhelmingly uniform-parameter materials, and
  supporting the textures would require inventing channel-packing conventions
  before a BSDF exists to consume them.
- `KHR_materials_iridescence`. Nothing in Phase E or F consumes it.
- Any change to BSDF evaluation, sampling, or the forward+ renderer's shading.
- Subsurface scattering. It has no glTF extension; Phase E3 uses Godot's existing
  `subsurface_scattering_strength`.

## 3. Decisions

Four rulings that the roadmap leaves open. Each is load-bearing; changing one
changes the shape of the work.

### 3.1 Material representation: extend `BaseMaterial3D`, do not add a new class

New parameters become plain `BaseMaterial3D` properties whose setters push into
the material parameter map via the existing `_material_set_param` helper
(`scene/resources/material.cpp:2114`). **No new shader uniforms, no new
`FEATURE_*` flags, no forward+ codegen change.**

This works because the parameter map is independent of the shader's uniform list.
`material_get_param` reads a plain `HashMap`
(`servers/rendering/renderer_rd/storage_rd/material_storage.cpp:2644`), and the UBO
fill iterates *shader uniforms* and looks each one up in the parameter map
(`material_storage.cpp:745`) — parameters with no matching uniform are ignored
silently, with no warning and no cost.

Rejected alternatives:

- **A new `PrincipledMaterial3D : Material`.** `_parse_materials` instantiates
  `StandardMaterial3D` unconditionally (`modules/gltf/gltf_document.cpp:2955`), so
  adopting it would change what every glTF import produces, breaking pipeline
  scripts that set `albedo_color` or type-check the material. It would also need
  its own shader generator (~1000 lines mirrored from `material.cpp`) before
  anything rendered in the editor.
- **Side-channel metadata on the `Material` resource.** The RD storage layer holds
  RIDs, not scene-tree `Resource`s, so `render_raytracing.cpp` has no path from a
  material RID back to a `Material*`. The path tracer could never read it.

### 3.2 F0 parameterisation: carry verbatim, leave `specular` untouched

Godot parameterises dielectric reflectance as `specular` with
`F0 = 0.16 * specular^2`
(`servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl:274`).
glTF parameterises it as
`F0 = ((ior-1)/(ior+1))^2 * specularColorFactor * specularFactor`. These are two
curves over the same physical quantity, so importing both without a ruling
double-specifies F0.

**The importer never writes `specular`.** `ior`, `specular_factor` and
`specular_tint` are carried as new properties alongside it.

The reason is testability, not aesthetics. Because nothing existing is
overwritten, Phase D changes zero pixels for content carrying none of the seven
extensions (§7.2) — so during Phase D any rendered difference is a bug, full stop,
with no legitimate cause to rule out first. Phase E owns the decision of how F0 is
finally computed and which knob wins.

### 3.3 Reuse Godot's existing clearcoat and anisotropy properties

Three glTF factors have exact semantic twins already in `BaseMaterial3D`, both
linear 0..1 weights with identical meaning:

| glTF | Existing Godot property |
|---|---|
| `KHR_materials_clearcoat.clearcoatFactor` | `clearcoat` |
| `KHR_materials_clearcoat.clearcoatRoughnessFactor` | `clearcoat_roughness` |
| `KHR_materials_anisotropy.anisotropyStrength` | `anisotropy` |

Reusing them avoids two knobs for one quantity. This is not in tension with §3.2:
that ruling exists because `specular` and `ior` disagree about the *curve*, and
these three do not.

**Reusing an existing property obliges you to verify its default, its range, and
its constructor behaviour from source — not to assume them.** A property that was
chosen for a different purpose carries defaults chosen for that purpose, and they
need not match the ones the new purpose implies. This design originally asserted
that all three reused properties defaulted to 0.0; two of them do not (§4.1), and
that single unverified assumption produced both a round-trip data loss and a
wrong value uploaded for every material in every scene. The other eleven claims
in this document were checked against source (§10); these three were not,
precisely because this section framed them as "already existing" and therefore
not new surface. They were new surface.

**Consequence:** the importer must call `set_feature(FEATURE_CLEARCOAT, true)` /
`set_feature(FEATURE_ANISOTROPY, true)` when the corresponding factor is
non-default, for two reasons:

1. *Inspectability.* `clearcoat_enabled` and `anisotropy_enabled` carry
   `PROPERTY_HINT_GROUP_ENABLE`, so the Inspector greys out the whole group while
   the feature is off and the imported values are invisible — failing the
   acceptance criterion. (This is **not** done by `_validate_property`; an earlier
   revision of this section said so and was wrong. `BaseMaterial3D::_validate_property`
   has no feature-based hiding at all — it only hides clearcoat and anisotropy
   when `shading_mode` is not per-pixel.)
2. *Correctness of the uploaded value.* Per §4.1 these three parameters are
   published as 0 while their feature is off, so without the `set_feature` call
   the factors would sit on the object but reach the GPU as zero.

Enabling a feature *does* change forward+ codegen, which is
why the no-pixel-change invariant is scoped to content carrying none of the seven
extensions (§7.2). RT output is unchanged unconditionally, because the path tracer
reads none of these values in Phase D.

**Godot's `anisotropy` is signed [-1, 1]** where glTF's `anisotropyStrength` is
[0, 1]; the negative half is Godot's way of encoding a 90-degree rotation. Importing
strength into the positive half and carrying the true angle in the new
`anisotropy_rotation` preserves the full glTF information.

### 3.4 No clamping on import

Blender's importer passes `ior` straight through with no range check
(`scripts/addons_core/io_scene_gltf2/blender/imp/pbrMetallicRoughness.py:172-173`).
We match it, which makes the round-trip exact by construction.

This carries one obligation forward: `ior == 0.0` is legal glTF, meaning "no
refraction, F0 = 0". **Phase E must not assume `ior >= 1`.** Phase D cannot enforce
this; it is a handoff note (§8).

Non-finite values are the one exception and are rejected (§5.2).

## 4. Design

### 4.1 Parameter set

Thirteen values. Three reuse existing properties per §3.3; ten are new.

| Property | Type | Default | glTF source |
|---|---|---|---|
| `transmission` | float | 0.0 | `KHR_materials_transmission.transmissionFactor` |
| `ior` | float | 1.5 | `KHR_materials_ior.ior` |
| `thickness` | float | 0.0 | `KHR_materials_volume.thicknessFactor` |
| `attenuation_distance` | float | 0.0 (= infinite) | `KHR_materials_volume.attenuationDistance` |
| `attenuation_color` | Color | white | `KHR_materials_volume.attenuationColor` |
| `specular_factor` | float | 1.0 | `KHR_materials_specular.specularFactor` |
| `specular_tint` | Color | white | `KHR_materials_specular.specularColorFactor` |
| `sheen_color` | Color | black | `KHR_materials_sheen.sheenColorFactor` |
| `sheen_roughness` | float | 0.0 | `KHR_materials_sheen.sheenRoughnessFactor` |
| `anisotropy_rotation` | float (radians) | 0.0 | `KHR_materials_anisotropy.anisotropyRotation` |
| `clearcoat` *(existing)* | float | **1.0** | `KHR_materials_clearcoat.clearcoatFactor` |
| `clearcoat_roughness` *(existing)* | float | **0.5** | `KHR_materials_clearcoat.clearcoatRoughnessFactor` |
| `anisotropy` *(existing)* | float | 0.0 | `KHR_materials_anisotropy.anisotropyStrength` |

**The three reused defaults are Godot's, not glTF's.** `BaseMaterial3D`'s
constructor sets `clearcoat = 1.0` and `clearcoat_roughness = 0.5`
(`material.cpp`, `doc/classes/BaseMaterial3D.xml`), while glTF defaults both to
`0.0`. `anisotropy` is 0.0 on both sides. Two consequences, both implemented:

- **Export cannot omit either clearcoat key.** "Omit when equal to the glTF
  default" is lossless only where the class default and the glTF default agree,
  which for these two they do not: an authored `clearcoat_roughness` of exactly
  0.0 would be dropped and return as 0.5. Both keys are written unconditionally
  whenever `FEATURE_CLEARCOAT` is on (§4.4).
- **The parameter map is feature-gated.** `clearcoat`, `clearcoat_roughness` and
  `anisotropy` publish 0 into the material parameter map while their feature is
  off, and the member value when it is on. Otherwise every material in every
  scene uploads `clearcoat = 1.0`, `clearcoat_roughness = 0.5` to the path
  tracer. Forward+ is unaffected: with the feature off its generated shader
  declares no such uniform, and the UBO fill iterates uniforms, not parameters.
  See the §8 handoff note.

Defaults were confirmed against Blender's importer rather than read from Khronos
prose: `transmissionFactor` 0 (`pbrMetallicRoughness.py:283`), `attenuationColor`
`[1,1,1]` (`:340`), `attenuationDistance` infinity (`:343`), `thicknessFactor` 0
(`:366`), `ior` 1.5 (`:172`, `io/com/constants.py:155`).

**`attenuation_distance` is stored as distance and uploaded as density.** The GPU
carries `attenuation_density = (d > 0) ? 1/d : 0`, so density 0 means no
absorption with no shader branch and no division guard at the point of use. The
Godot-side property stays glTF-shaped, which keeps the round-trip exact. This is
also the form Blender authors in — its exporter writes
`attenuationDistance = 1.0/density`
(`blender/exp/material/extensions/volume.py:50`).

**Naming note:** Godot already uses "transmittance" (`transmittance_color`,
`transmittance_depth`) for *subsurface* transmittance. The new `transmission` is a
different quantity. The names are distinct; do not conflate them.

### 4.2 Godot representation (D2)

**Files:** `scene/resources/material.h`, `scene/resources/material.cpp`.

For each of the ten new properties, following the existing pattern exactly:

1. A member on `BaseMaterial3D`.
2. A `StringName` in the `ShaderNames` struct (`material.h:464`).
3. Its initialiser near `material.cpp:564-574`.
4. A setter calling `_material_set_param(shader_names->X, p_X)` and a getter.
5. `ClassDB::bind_method` for both.
6. An `ADD_PROPERTY` entry.

**Parameter names equal property names** for all ten. This is verified safe: none
of the ten appears as a uniform in the generated forward+ shader (checked by
grepping `uniform <type> <name>` in `material.cpp` — zero matches for all ten). A
name collision would silently route the value into the forward+ UBO and change
rendering, so re-run that check before landing.

**Watch the one existing name that is not its property name:** `anisotropy`'s
parameter is `"anisotropy_ratio"` (`material.cpp:574`), not `"anisotropy"`. The RT
read in §4.5 must use `"anisotropy_ratio"`.

**Inspector grouping:**

- `anisotropy_rotation` joins the existing `ADD_GROUP("Anisotropy", "anisotropy_")`
  block (`material.cpp:3633`), displaying as "Rotation". It inherits that group's
  `FEATURE_ANISOTROPY` gating, consistent with `anisotropy` itself.
- The other nine go in a new `ADD_GROUP("Path Tracing", "")` placed immediately
  before `ADD_GROUP("UV1", "uv1_")` (`:3688`). The empty-prefix form is used four times in
  this file (`:3558`, `:3570`, `:3706`, `:3723`). No feature flag gates them; they
  are always visible.

The group label is what tells an author these are ignored by the forward+
viewport. Document that in `doc/classes/BaseMaterial3D.xml` for each property.

`MaterialKey` is untouched: no property changes shader codegen, so materials
differing only in these values correctly share a shader while keeping separate
parameters.

### 4.3 glTF import (D1)

**File:** `modules/gltf/gltf_document.cpp`, in `_parse_materials` (`:2946`).

Seven `material_extensions.has(...)` blocks, placed immediately after the existing
`KHR_materials_emissive_strength` block (`:2971`) and **before** the
`KHR_materials_pbrSpecularGlossiness` branch (`:2979`), so a spec-gloss material
does not silently overwrite them.

All seven names are added to `get_supported_gltf_extensions_hashset` (`:6967`).
Without this, a GLB listing any of them in `extensionsRequired` is rejected at
load (`:7379-7382`).

**Colour space.** Godot `Color` properties are sRGB-encoded: the importer applies
`linear_to_srgb()` to `baseColorFactor` (`:3047`) and the RT upload applies
`srgb_to_linear()` to undo it (`render_raytracing.cpp:1514`). The three new
colours follow that convention exactly — `linear_to_srgb()` on import,
`srgb_to_linear()` on upload. See §6.1 for the test consequence.

**Feature enabling.** When `clearcoatFactor` or `clearcoatRoughnessFactor` is
present and non-default, call `set_feature(FEATURE_CLEARCOAT, true)`. Likewise
`FEATURE_ANISOTROPY` for `anisotropyStrength` or `anisotropyRotation`. Per §3.3,
without this the values import but stay hidden in the Inspector.

### 4.4 glTF export

**File:** `modules/gltf/gltf_document.cpp`, in the serialisation block at
`:2918-2929`, which already has the required shape: build a `Dictionary`, assign
into `extensions`, call `p_state->add_used_extension(name)` with `required` left
false (`gltf_state.cpp:158`).

Each extension is written **only when its factors differ from the glTF default**,
so ordinary materials produce no extension bloat — with one deliberate exception:
`clearcoatFactor` and `clearcoatRoughnessFactor` are written unconditionally
whenever `FEATURE_CLEARCOAT` is on, because their Godot class defaults (1.0, 0.5)
disagree with the glTF defaults (0.0, 0.0) and omission would therefore be lossy
(§4.1).

**Every value is clamped to its glTF-legal range on export.** Godot's property
hints do not clamp, so `transmission`, `specular_factor`, `sheen_roughness`,
`clearcoat`, `clearcoat_roughness` and `thickness` are all settable outside the
range glTF permits, and `anisotropy` is *by design* signed [-1, 1] where glTF's
`anisotropyStrength` is [0, 1]. Emitting those verbatim produces JSON that any
validator rejects. A negative `anisotropy` clamps to 0 and emits a
`WARN_PRINT_ONCE`; the 90-degree rotation its sign encodes is not exported,
because composing sign and rotation is a Phase E decision (§8).

Export exists for two reasons. It enables the hermetic round-trip test (§6.1)
without a binary fixture in the repo. And it keeps
`get_supported_gltf_extensions` honest: declaring support on import while
dropping on export would make Godot to GLB to Godot lose data silently.

### 4.5 RT material struct (D3)

**Files:** `servers/rendering/renderer_rd/forward_clustered/render_raytracing.h`
(`RT_MaterialData`, `:106`),
`servers/rendering/renderer_rd/shaders/raytracing/raytracing_data_inc.glsl`
(`MaterialData`, `:123`),
`servers/rendering/renderer_rd/forward_clustered/render_raytracing.cpp`.

`RT_MaterialData` grows 96 to 176 bytes. Five new 16-byte rows:

```
offset  field
    96  float transmission
   100  float ior
   104  float thickness
   108  float attenuation_density
   112  float attenuation_color[3]     <- 16-byte aligned
   124  float specular_factor
   128  float specular_tint[3]         <- 16-byte aligned
   140  float sheen_roughness
   144  float sheen_color[3]           <- 16-byte aligned
   156  float anisotropy_rotation
   160  float clearcoat
   164  float clearcoat_roughness
   168  float anisotropy
   172  float _pad0
   176  (end)
```

Each `vec3` lands on a 16-byte boundary with the following scalar filling its
tail — the same std430 packing `emission_color` / `emission_strength` already
uses at offsets 32 and 44.

**Required asserts:**

```cpp
static_assert(sizeof(RT_MaterialData) == 176, "RT_MaterialData must be 176 bytes for std430");
static_assert(offsetof(RT_MaterialData, attenuation_color) == 112, "attenuation_color must be 16-byte aligned for std430 vec3");
static_assert(offsetof(RT_MaterialData, specular_tint) == 128, "specular_tint must be 16-byte aligned for std430 vec3");
static_assert(offsetof(RT_MaterialData, sheen_color) == 144, "sheen_color must be 16-byte aligned for std430 vec3");
```

The three `offsetof` asserts are load-bearing and not redundant with the size
assert. A `vec3` aligns to 16 in std430, so reordering members around one shifts
the GPU's view of every subsequent field **without changing `sizeof`** — the size
assert alone passes on a broken layout. This is the C1 lesson applied.

**Three fill sites in `render_raytracing.cpp` must all be updated in lockstep:**

1. The static default material, near `:1371-1380`.
2. The per-material defaults block, `:1429-1450`.
3. The parameter reads, immediately after the `specular_var` block at
   `:1675-1678`.

Read the parameters by name with `material_get_param`, matching the existing
style. Use `"anisotropy_ratio"` for anisotropy strength (§4.2). Apply
`srgb_to_linear()` to the three colours, matching `albedo` at `:1514`. Convert
`attenuation_distance` to density at this point, not on the GLSL side.

The GLSL `MaterialData` twin must be edited to match field for field, in the same
order.

## 5. Error handling

### 5.1 Malformed extension values are skipped, never fatal

Core glTF fields use `ERR_FAIL_COND_V(arr.size() != 4, ERR_PARSE_ERROR)`
(`gltf_document.cpp:3046`), which aborts the whole import. That is correct for
core fields and wrong here. An extension is optional by definition, so a broken
optional block should cost you that parameter, not the model.

Skip the offending key, emit a warning naming the material and the key, and
continue parsing the rest of the material.

This includes an extension whose *value* is not a JSON object at all
(`"KHR_materials_ior": 5`). Converting that Variant to a `Dictionary` yields an
empty one, so every subsequent `has()` declines and the extension would vanish
with no diagnostic — the one malformed input in these blocks that would otherwise
be silent. The type is checked and warned on explicitly.

### 5.2 Non-finite scalars are rejected

A NaN reaching `attenuation_density` propagates through the shader and poisons
pixels far from its origin, where it is very hard to trace back. Reject any
non-finite scalar with a warning and keep the property's default.

### 5.3 `attenuationDistance <= 0` is treated as infinite

The glTF spec requires it strictly positive. Rather than leaving `1.0/0.0` to the
implementation, the density conversion is defined as
`density = (d > 0) ? 1/d : 0`, so a zero, negative, or absent distance all mean
"no absorption".

### 5.4 Dropped textures produce one warning per material

Accumulate every ignored extension texture for a material and emit a single
warning naming all of them:

```
glTF material 'GlassPanel': ignoring unsupported extension texture(s):
transmissionTexture, thicknessTexture. Factors were imported; per-parameter
extension textures are not yet supported.
```

Bounded by asset count rather than texture count, and actionable because it names
the material. Silent data loss is the failure mode this project keeps
rediscovering — the emissive-mesh work shipped with no diagnostic for skipped
emitters and recorded it as a defect. Phase D pays the small cost of not
repeating it.

## 6. Testing

### 6.1 T1 — closed-loop round-trip (doctest)

**File:** `tests/scene/test_gltf_document.cpp`, using the `append_from_scene`
pattern already at `:189`.

Author a `StandardMaterial3D` with all thirteen values set, serialise to a buffer,
parse it back, and compare. The ten scalars compare exactly; **the three colours
compare with a tolerance**, because the round-trip applies
`linear_to_srgb(srgb_to_linear(c))`, which is the identity only to float
precision. Comparing colours for equality would produce a flaky suite.

**Two requirements on the fixture, both mandatory:**

- Every one of the thirteen values must be **distinct from every other value and
  from its own default**. Otherwise a field swap or copy-paste error in the
  import or export block passes unnoticed.
- The implementer must **prove the test can fail**: deliberately swap two fields
  in the import block, observe red, revert. Report the observed failure.

This project has repeatedly shipped assertions that were correct but that no data
could exercise. The proof step is not ceremony.

### 6.2 T1b — hand-authored glTF fixture (doctest)

**File:** `tests/data/models/material_extensions.gltf`.

T1 tests our importer against our own exporter. **If we write and read
`sheenColor` where Khronos says `sheenColorFactor`, the loop still closes and T1
still passes.** A closed loop cannot catch a systematic naming error.

The fixture is hand-authored with the canonical Khronos key names, parsed only,
never written by us. It is JSON, so it is reviewable in a diff and regenerable
from the repo — unlike a binary GLB. It must carry all seven extensions with
distinct non-default values.

### 6.3 T2 — struct parity (compile-time)

The `static_assert`s of §4.5 are the test. No doctest wrapper adds anything.

**Stated limitation:** they check the C++ side only. Nothing automated compares
`RT_MaterialData` to its GLSL twin. T3 exists to close that.

### 6.4 T3 — GPU arrival gate

**Files:** `raytracing_closest_hit_common_inc.glsl` (debug vis modes),
`pipeline_references/tests/pt_material_data_gate.gd` and its `.tscn`.

Add debug visualisation modes 23-29 (the highest existing is 22), each emitting
three of the new fields as **raw, unscaled floats** into the EXR:

| Mode | Output |
|---|---|
| 23 | `transmission`, `ior`, `thickness` |
| 24 | `attenuation_density`, `specular_factor`, `sheen_roughness` |
| 25 | `clearcoat`, `clearcoat_roughness`, `anisotropy` |
| 26 | `anisotropy_rotation`, 0, 0 |
| 27 | `attenuation_color` |
| 28 | `specular_tint` |
| 29 | `sheen_color` |

The gate authors a material with known distinct values, renders each mode, and
asserts every field on readback. The EXR is float, so no scaling is needed and
values above 1.0 survive.

**This is the only test in Phase D that proves the GLSL struct agrees with the C++
one**, and the project's first test that executes the relevant GLSL rather than
mirroring it in C++ — an open item carried since Phase B.

### 6.5 T4 — no-pixel-change measurement

Render a gate scene carrying none of the seven extensions at a fixed seed, on the
pre-D commit and on the D branch, and diff the EXRs.

This is a measurement the implementer performs and records in the task report, not
a CI test, because it requires two builds. It is what makes the §3.2 ruling pay
off: with nothing existing overwritten, the expected result is bit-identical
output.

### 6.6 T5 — dropped-texture behaviour

Parse a fixture carrying `transmissionTexture`; assert the factor was imported
**and** that no `TextureParam` was set on the material. Behavioural, so it needs
no log capture. The warning text itself is verified by eye once.

## 7. Acceptance

### 7.1 Primary

A Blender-authored GLB containing glass, car paint, and fabric imports with every
one of the thirteen parameters intact, visible in the Inspector, and present in
the GPU material struct.

This is the roadmap's own criterion and the only check that validates our reading
of Blender's *exporter*. T1 and T1b are hermetic and cannot replace it.

### 7.2 The no-pixel-change invariant

**Phase D changes zero pixels for content that carries none of the seven
extensions.** RT output is unchanged unconditionally, since the path tracer reads
none of the new values in Phase D. Forward+ output can change only for materials
that carry clearcoat or anisotropy data, via the feature enabling of §3.3 — and
those materials previously lost that data entirely, so the change is strictly a
gain.

Verified by T4.

### 7.3 Suite

The doctest suite passes with no new failures, and the new tests are additive to
the current baseline.

## 8. Handoff notes to Phase E

- **`ior == 0.0` is legal glTF**, meaning no refraction, F0 = 0. Do not assume
  `ior >= 1` (§3.4).
- **F0 is double-specified on purpose.** Both `specular` (Godot's curve) and
  `ior` / `specular_factor` / `specular_tint` (glTF's) reach the shader. Phase E
  must decide which wins and document the deprecation of the other (§3.2).
- **`clearcoat`, `clearcoat_roughness` and `anisotropy` are feature-gated in the
  parameter map.** They publish 0 while `FEATURE_CLEARCOAT` / `FEATURE_ANISOTROPY`
  is off and the member value when it is on (§4.1). A Phase E clearcoat lobe can
  therefore read `mat.clearcoat` directly and get 0 for materials that do not want
  a coat — no separate enable bit is needed in `RT_MaterialData`. Do **not**
  "restore" the class defaults on the assumption they are the right zero point:
  they are 1.0 and 0.5, and un-gating them coats every surface in every scene at
  full strength.
- **`anisotropy` is signed [-1, 1]**; the negative half encodes a 90-degree
  rotation in Godot's convention, while `anisotropy_rotation` carries glTF's true
  angle in radians. Phase E must define how the two compose. **Until it does,
  glTF export clamps a negative `anisotropy` to 0 and warns**, because
  `anisotropyStrength` is [0, 1] and a negative value is invalid glTF. That is a
  deliberate placeholder, not a settled ruling: once Phase E defines the
  composition, export should encode the sign into `anisotropyRotation` (a
  90-degree offset) instead of discarding it, and this clamp should be revisited.
- **A `ShaderMaterial` declaring `uniform float ior` or `uniform float thickness`
  will have that value land in `RT_MaterialData`.** The path tracer reads the
  material parameter map by name and cannot tell a `BaseMaterial3D` property from
  a same-named custom shader uniform. This hazard already existed for `specular`,
  `metallic` and `roughness`, but Phase D grew the exposed name surface from three
  to thirteen and several of the new names (`ior`, `thickness`, `transmission`,
  `sheen_color`) are generic enough to collide by accident. If Phase E starts
  *shading* with these values, a `ShaderMaterial` that happens to use one of these
  names will change appearance. Consider namespacing the reads (a `pt_` prefix on
  the parameter names) before that becomes visible.
- **Godot 3.x `.tres` compatibility.** 3.x `SpatialMaterial` had a `transmission`
  property of type `Color` (subsurface transmission, unrelated to glTF's
  transmission). Before Phase D that name fell through the 3.x-to-4.x remap table
  and produced a "remapped parameter not found" message; now it matches the new
  `float transmission` and fails Variant conversion instead. Marginal — it affects
  only direct loads of unconverted 3.x resources — but the diagnostic changed
  shape, so a report of a `transmission` conversion error on an old file is
  expected rather than a new defect.
- **`attenuation_density` is already reciprocal.** Do not invert it again.
- **Per-parameter extension textures are absent by design** (§2). If Phase E needs
  them, that is a new phase, not a patch.

## 9. File inventory

**Modify:**

- `scene/resources/material.h` — 10 members, 10 `ShaderNames` entries.
- `scene/resources/material.cpp` — initialisers, setters/getters, bindings,
  `ADD_PROPERTY` entries, new `ADD_GROUP("Path Tracing", "")`.
- `doc/classes/BaseMaterial3D.xml` — documentation for 10 properties, each noting
  that the forward+ renderer ignores it.
- `modules/gltf/gltf_document.cpp` — 7 import blocks, 7 export blocks, 7 entries
  in `get_supported_gltf_extensions_hashset`.
- `servers/rendering/renderer_rd/forward_clustered/render_raytracing.h` —
  `RT_MaterialData` 96 to 176 bytes, 4 asserts.
- `servers/rendering/renderer_rd/forward_clustered/render_raytracing.cpp` — three
  fill sites in lockstep.
- `servers/rendering/renderer_rd/shaders/raytracing/raytracing_data_inc.glsl` —
  `MaterialData` twin.
- `servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl`
  — vis modes 23-29.
- `tests/scene/test_gltf_document.cpp` — T1, T1b, T5.
- `PATH_TRACER_QUALITY_ROADMAP.md` — Phase D closeout entry.

**Create:**

- `tests/data/models/material_extensions.gltf` — hand-authored fixture (T1b).
- `pipeline_references/tests/pt_material_data_gate.gd` and its `.tscn` (T3).

**Build note:** editing a `.glsl` requires a full `scons` build so the
`.glsl.gen.h` regenerates.

## 10. Verified facts

Every claim below was checked in source during design, not recalled.

| Claim | Evidence |
|---|---|
| `GLTFDocumentExtension` has no material hook, so import must go inline | `modules/gltf/extensions/gltf_document_extension.h:45-69` |
| The pipeline imports GLB at runtime, so this lands on the production path | `pipeline_references/image_glb_creation.gd:3139`, `:5031` |
| A material can carry parameters the shader never declares | `material_storage.cpp:2644` (read), `:745` (UBO fill iterates uniforms) |
| Only three material extensions are supported today | `gltf_document.cpp:6967-6977` |
| Godot's `specular` maps as `F0 = 0.16*s^2` | `raytracing_closest_hit_common_inc.glsl:274` |
| Godot's anisotropy parameter is named `anisotropy_ratio` | `material.cpp:574` |
| None of the ten new names collides with a forward+ uniform | grep of `uniform <type> <name>` in `material.cpp`, 0 matches for all ten |
| Colours are sRGB in Godot properties, linear in glTF | `gltf_document.cpp:3047`, `render_raytracing.cpp:1514` |
| Blender does not clamp `ior` on import | `blender/imp/pbrMetallicRoughness.py:172-173` |
| Blender exports `attenuationDistance = 1/density` | `blender/exp/material/extensions/volume.py:50` |
| Blender's anisotropy rotation is `blender_value * 2*pi` | `blender/com/conversion.py:208-210` |
| glTF defaults, as Blender's importer applies them | `blender/imp/pbrMetallicRoughness.py:283`, `:340`, `:343`, `:366`, `:172` |
| Highest existing debug vis mode is 22 | `raytracing_closest_hit_common_inc.glsl` |
| `ADD_GROUP` with an empty prefix is an established pattern | `material.cpp:3558`, `:3570`, `:3706`, `:3723` |
| `clearcoat` defaults to **1.0** and `clearcoat_roughness` to **0.5**, pushed by the constructor for every material regardless of `FEATURE_CLEARCOAT` | `material.cpp` constructor (`set_clearcoat(1); set_clearcoat_roughness(0.5);`), `doc/classes/BaseMaterial3D.xml` |
| `BaseMaterial3D::_validate_property` has **no** feature-based hiding; clearcoat/anisotropy visibility comes from `PROPERTY_HINT_GROUP_ENABLE` on the `*_enabled` properties | `material.cpp` `_validate_property` (only `shading_mode`-based), `ADD_PROPERTYI(... "clearcoat_enabled", PROPERTY_HINT_GROUP_ENABLE ...)` |
| A parameter with no matching shader uniform is never read into the UBO, so feature-gating a parameter's map value cannot change forward+ output | `material.cpp` (`if (features[FEATURE_CLEARCOAT])` guards the `uniform float clearcoat` emission), `material_storage.cpp` `update_uniform_buffer` iterates `p_uniforms` |

**Correction, recorded deliberately.** The first two rows above were added after
the fact. They are the defaults of the three *reused* properties (§3.3) — the only
values in the original design taken on assumption rather than read from source,
because §3.3 framed them as pre-existing surface. Both defects that followed
(round-trip loss of a 0.0 clearcoat roughness; a wrong clearcoat value uploaded
for every material in the scene) trace to that one gap. The rule this yields is
in §3.3.
