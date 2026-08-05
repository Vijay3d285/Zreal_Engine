# IES Light Implementation in Blender

> **Author**: Lead Software Engineering Analysis  
> **Scope**: Full pipeline from UI → DNA/RNA → Cycles shader graph → kernel evaluation  
> **Codebase version**: Blender `main` branch (as of 2026-08-01)

---

## Table of Contents

1. [Overview](#overview)
2. [Architecture Summary](#architecture-summary)
3. [Layer 1 — Data Model (DNA)](#layer-1--data-model-dna)
4. [Layer 2 — API & UI (RNA + Node Definition)](#layer-2--api--ui-rna--node-definition)
5. [Layer 3 — External vs. Internal Mode Handling](#layer-3--external-vs-internal-mode-handling)
6. [Layer 4 — Cycles Bridge (Blender → Cycles)](#layer-4--cycles-bridge-blender--cycles)
7. [Layer 5 — Cycles Scene Graph (IESLightNode)](#layer-5--cycles-scene-graph-ieslightnode)
8. [Layer 6 — IES File Parser](#layer-6--ies-file-parser)
9. [Layer 7 — LightManager Slot Table](#layer-7--lightmanager-slot-table)
10. [Layer 8 — GPU Upload & Device Scene](#layer-8--gpu-upload--device-scene)
11. [Layer 9 — Kernel Evaluation (SVM)](#layer-9--kernel-evaluation-svm)
12. [Layer 10 — Kernel Evaluation (OSL)](#layer-10--kernel-evaluation-osl)
13. [EEVEE Support](#eevee-support)
14. [File Path Remapping & Portability](#file-path-remapping--portability)
15. [Complete File Reference](#complete-file-reference)
16. [Data Flow Diagram](#data-flow-diagram)

---

## Overview

IES (Illuminating Engineering Society) files describe the real-world directional intensity distribution of a light source using a standardized photometric data format. Blender exposes this functionality through the **IES Texture** shader node (`ShaderNodeTexIES`), which is supported exclusively by the **Cycles** render engine.

The node offers two modes for sourcing the `.ies` file data:

| Mode | Description | Portability |
|------|-------------|-------------|
| **External** | Loads the `.ies` file directly from a filesystem path | Breaks if file moves; requires packing |
| **Internal** | Stores the `.ies` text content inside a Blender `Text` data-block | Fully portable — data is saved inside the `.blend` file |

---

## Architecture Summary

The IES implementation spans eight conceptual layers across both the Blender core and the Cycles renderer:

```
┌──────────────────────────────────────────────────────────────────┐
│  USER INTERFACE                                                  │
│  node_shader_buts_ies()   →   mode toggle + filepath/text picker │
├──────────────────────────────────────────────────────────────────┤
│  DNA (Serialized Data)     →   NodeShaderTexIES struct            │
│  RNA (Python/UI API)       →   Properties: mode, filepath, ies   │
├──────────────────────────────────────────────────────────────────┤
│  CYCLES BRIDGE             →   shader.cpp: ShaderNodeTexIES      │
│                                 reads mode, resolves filepath     │
│                                 or reads Text data-block content  │
├──────────────────────────────────────────────────────────────────┤
│  CYCLES SCENE GRAPH        →   IESLightNode (TextureNode)        │
│                                 get_slot() → LightManager        │
├──────────────────────────────────────────────────────────────────┤
│  IES PARSER                →   IESFile::load/parse/process       │
│                                 Candela → Watts conversion        │
│                                 Type A/B/C normalization          │
├──────────────────────────────────────────────────────────────────┤
│  LIGHT MANAGER             →   Slot table with hash dedup        │
│                                 Reference counting                │
├──────────────────────────────────────────────────────────────────┤
│  GPU DEVICE UPLOAD         →   ies_lights float buffer            │
│                                 Offset table + packed data        │
├──────────────────────────────────────────────────────────────────┤
│  KERNEL (SVM/OSL)          →   Bicubic interpolation in          │
│                                 spherical coordinates             │
└──────────────────────────────────────────────────────────────────┘
```

---

## Layer 1 — Data Model (DNA)

### Struct: `NodeShaderTexIES`

**File**: [`source/blender/makesdna/DNA_node_types.h`](file:///c:/Users/aiadmin/Desktop/blender_build/blender/source/blender/makesdna/DNA_node_types.h#L2926-L2932)

```cpp
struct NodeShaderTexIES {
  DNA_DEFINE_CXX_METHODS(NodeShaderTexIES)

  int mode = 0;                              // NODE_IES_INTERNAL (0) or NODE_IES_EXTERNAL (1)
  char filepath[/*FILE_MAX*/ 1024] = "";     // External .ies file path
};
```

This struct is stored as the `node->storage` pointer in the `bNode`. Note that the **internal** Text data-block pointer is stored separately in `node->id` (a generic `ID*` field on the base `bNode` struct), not in this storage struct.

### Mode Enum: `eNodeIES_Mode`

**File**: [`source/blender/makesdna/DNA_node_types.h`](file:///c:/Users/aiadmin/Desktop/blender_build/blender/source/blender/makesdna/DNA_node_types.h#L444-L448)

```cpp
/* IES node mode. */
enum eNodeIES_Mode : char {
  NODE_IES_INTERNAL = 0,   // Use internal Text data-block
  NODE_IES_EXTERNAL = 1,   // Use external .ies file path
};
```

### Key Design Decisions

- The `filepath` field (1024 chars) supports Blender-relative paths (prefixed with `//`).
- The internal Text pointer uses `node->id` — the same generic ID pointer mechanism used by other nodes (e.g., `ShaderNodeScript`). This means the IES node can only reference **one** text block at a time.
- `mode` is stored as `int` in the DNA struct (not the `char`-sized enum) for alignment/portability.

---

## Layer 2 — API & UI (RNA + Node Definition)

### Node Registration

**File**: [`source/blender/nodes/shader/nodes/node_shader_ies_light.cc`](file:///c:/Users/aiadmin/Desktop/blender_build/blender/source/blender/nodes/shader/nodes/node_shader_ies_light.cc)

The node is registered as:

| Property | Value |
|----------|-------|
| Type string | `"ShaderNodeTexIES"` |
| Legacy ID | `SH_NODE_TEX_IES` (194) |
| UI name | `"IES Texture"` |
| Class | `NODE_CLASS_TEXTURE` |
| Storage | `NodeShaderTexIES` |

#### Sockets

| Direction | Type | Name | Default | Notes |
|-----------|------|------|---------|-------|
| Input | `Vector` | `"Vector"` | — | Hidden; auto-connected to incoming direction |
| Input | `Float` | `"Strength"` | 1.0 | Range [0, 1000000] |
| Output | `Float` | `"Fac"` | — | Intensity multiplied by Strength |

#### UI Draw Function

```cpp
static void node_shader_buts_ies(ui::Layout &layout, bContext *, PointerRNA *ptr)
{
  // Row 1: Mode toggle (Internal / External)
  layout.row(false).prop(ptr, "mode", ...);

  // Row 2: Conditional widget
  if (RNA_enum_get(ptr, "mode") == NODE_IES_INTERNAL) {
    row.prop(ptr, "ies", ...);       // Text data-block picker
  } else {
    row.prop(ptr, "filepath", ...);  // File path browser
  }
}
```

### RNA Property Definitions

**File**: [`source/blender/makesrna/intern/rna_nodetree.cc`](file:///c:/Users/aiadmin/Desktop/blender_build/blender/source/blender/makesrna/intern/rna_nodetree.cc#L6641-L6668)

Three RNA properties are defined in `def_sh_tex_ies()`:

| Property | RNA Type | SDNA Source | Description |
|----------|----------|-------------|-------------|
| `ies` | `PROP_POINTER` → `Text` | `node->id` | Internal Text data-block |
| `filepath` | `PROP_STRING` / `PROP_FILEPATH` | `storage->filepath` | External `.ies` path (supports `//` relative) |
| `mode` | `PROP_ENUM` | `storage->mode` | `NODE_IES_INTERNAL` or `NODE_IES_EXTERNAL` |

The `mode` property has a custom setter: `rna_ShaderNodeTexIES_mode_set`.

---

## Layer 3 — External vs. Internal Mode Handling

### Mode Switch Logic

**File**: [`source/blender/makesrna/intern/rna_nodetree.cc`](file:///c:/Users/aiadmin/Desktop/blender_build/blender/source/blender/makesrna/intern/rna_nodetree.cc#L4057-L4080)

When the user toggles between Internal and External mode, the RNA setter performs a **data migration**:

```cpp
static void rna_ShaderNodeTexIES_mode_set(PointerRNA *ptr, int value)
{
  bNode *node = ptr->data_as<bNode>();
  NodeShaderTexIES *nss = static_cast<NodeShaderTexIES *>(node->storage);

  if (nss->mode != value) {
    nss->mode = value;
    nss->filepath[0] = '\0';   // Clear filepath

    // If switching TO External AND a Text data-block is loaded,
    // copy the Text's on-disk filepath into storage->filepath
    if (node->id) {
      Text *text = reinterpret_cast<Text *>(node->id);
      if (value == NODE_IES_EXTERNAL && text->filepath) {
        STRNCPY(nss->filepath, text->filepath);
        BLI_path_abs(nss->filepath, ...);   // Make absolute
        BLI_path_rel(nss->filepath, ...);   // Then make relative to .blend
      }
      id_us_min(node->id);     // Decrement user count
      node->id = nullptr;      // Detach the Text data-block
    }
  }
}
```

**Key behavior**: When switching from Internal → External, if the `Text` data-block was originally loaded from a file, Blender automatically populates the `filepath` with that file's path (converting to blend-relative format). This provides a smooth transition without data loss.

### Internal Mode — How Text Data-Blocks Work

In Internal mode:
1. The user loads a `.ies` file into Blender's **Text Editor** (or creates a text data-block).
2. The `ies` property on the node points to this `Text` data-block via `node->id`.
3. The text content is stored line-by-line inside the `Text` struct's `lines` linked list.
4. When saved, the `.blend` file serializes the entire text content — making the file **fully portable**.

### External Mode — File Path Handling

In External mode:
1. The user specifies a path to a `.ies` file on disk via `storage->filepath`.
2. The path supports Blender relative paths (`//relative/path.ies`).
3. The path is resolved to absolute at render time by the Cycles bridge.

---

## Layer 4 — Cycles Bridge (Blender → Cycles)

**File**: [`intern/cycles/blender/shader.cpp`](file:///c:/Users/aiadmin/Desktop/blender_build/blender/intern/cycles/blender/shader.cpp#L1115-L1128)

The Blender-to-Cycles shader synchronization code translates the Blender node into a Cycles `IESLightNode`:

```cpp
else if (b_node.is_type("ShaderNodeTexIES"_ustr)) {
  const auto &storage = *static_cast<blender::NodeShaderTexIES *>(b_node.storage);
  IESLightNode *ies = graph->create_node<IESLightNode>();

  switch (storage.mode) {
    case blender::NODE_IES_EXTERNAL:
      // Resolve relative path and set filename
      ies->set_filename(ustring(blender_absolute_path(b_data, &b_ntree.id, storage.filepath)));
      break;

    case blender::NODE_IES_INTERNAL:
      // Extract text content from the Text data-block
      ustring ies_content = ustring(get_text_datablock_content(b_node.id));
      ies->set_ies(ies_content);
      break;
  }
  node = ies;
}
```

### Text Data-Block Content Extraction

**File**: [`intern/cycles/blender/util.h`](file:///c:/Users/aiadmin/Desktop/blender_build/blender/intern/cycles/blender/util.h#L511-L528)

```cpp
static inline string get_text_datablock_content(const blender::ID *id)
{
  if (id == nullptr) return "";
  if (blender::GS(id->name) != blender::ID_TXT) return "";

  const auto &text = *blender::id_cast<const blender::Text *>(id);
  string content;
  for (blender::TextLine &line : text.lines) {
    content += line.line ? line.line : "";
    content += "\n";
  }
  return content;
}
```

This iterates over every `TextLine` in the Text data-block's linked list, concatenating them with newlines to reconstruct the full `.ies` file content as a single string.

---

## Layer 5 — Cycles Scene Graph (IESLightNode)

### Class Declaration

**File**: [`intern/cycles/scene/shader_nodes.h`](file:///c:/Users/aiadmin/Desktop/blender_build/blender/intern/cycles/scene/shader_nodes.h#L384-L402)

```cpp
class IESLightNode : public TextureNode {
 public:
  SHADER_NODE_NO_CLONE_CLASS(IESLightNode)
  ~IESLightNode() override;
  ShaderNode *clone(ShaderGraph *graph) const override;

  NODE_SOCKET_API(ustring, filename)   // External: absolute file path
  NODE_SOCKET_API(ustring, ies)        // Internal: raw IES text content

  NODE_SOCKET_API(float, strength)
  NODE_SOCKET_API(float3, vector)

 private:
  LightManager *light_manager;
  int slot;         // Index into the LightManager's IES slot table

  void get_slot();  // Lazily acquires a slot from LightManager
};
```

### Slot Acquisition

**File**: [`intern/cycles/scene/shader_nodes.cpp`](file:///c:/Users/aiadmin/Desktop/blender_build/blender/intern/cycles/scene/shader_nodes.cpp#L1446-L1458)

```cpp
void IESLightNode::get_slot()
{
  assert(light_manager);
  if (slot == -1) {
    if (ies.empty()) {
      // External mode: load from file
      slot = light_manager->add_ies_from_file(filename.string());
    } else {
      // Internal mode: use raw text content
      slot = light_manager->add_ies(ies.string(), true);
    }
  }
}
```

The distinction between the two modes at this level is simple:
- If `ies` (the raw text content) is set → use it directly.
- Otherwise, use `filename` to load from disk.

### SVM Compilation

**File**: [`intern/cycles/scene/shader_nodes.cpp`](file:///c:/Users/aiadmin/Desktop/blender_build/blender/intern/cycles/scene/shader_nodes.cpp#L1460-L1477)

```cpp
void IESLightNode::compile(SVMCompiler &compiler)
{
  light_manager = compiler.scene->light_manager.get();
  get_slot();

  ShaderInput *vector_in = input("Vector");
  const SVMStackOffset vector_offset = tex_mapping.compile_begin(compiler, vector_in, nullptr);

  compiler.add_node(this, NODE_IES, SVMNodeIES{
    .strength = compiler.input_float("Strength"),
    .slot = uint(slot),
    .vector_offset = vector_offset,
    .fac_offset = compiler.output("Fac"),
  });

  tex_mapping.compile_end(compiler, vector_in, vector_offset);
}
```

### Resource Cleanup

```cpp
IESLightNode::~IESLightNode()
{
  if (light_manager) {
    light_manager->remove_ies(slot);   // Decrement reference count
  }
}
```

---

## Layer 6 — IES File Parser

### Class: `IESFile`

**Files**:
- Header: [`intern/cycles/util/ies.h`](file:///c:/Users/aiadmin/Desktop/blender_build/blender/intern/cycles/util/ies.h)
- Implementation: [`intern/cycles/util/ies.cpp`](file:///c:/Users/aiadmin/Desktop/blender_build/blender/intern/cycles/util/ies.cpp)

### Parse Pipeline

```
IESFile::load(content)
  ├── IESFile::parse(content)    — Parse raw text into angles + intensity grid
  └── IESFile::process()         — Normalize to Type C, convert to radians
        ├── process_type_a()
        ├── process_type_b()
        └── process_type_c()
```

### Parsing (`IESFile::parse`)

The parser (lines 118–201) performs these steps:

1. **Find the `TILT=` marker** — the start of photometric data in the IES standard.
2. **Handle tilt data** — if `TILT=INCLUDE`, skip the tilt angle/factor table.
3. **Read header values**:
   - Number of lamps, lumens per lamp
   - **Candela multiplier** (the scaling factor for all intensity values)
   - Number of vertical angles, number of horizontal angles
   - **Photometric type** (TYPE_A=3, TYPE_B=2, TYPE_C=1)
   - Geometry dimensions (width, length, height) — ignored
   - **Ballast factor** and **Ballast-Lamp factor** — multiplied into the scaling factor
   - Input watts — ignored

4. **Candela → Watts conversion**:

```cpp
/* Factor: 4*pi / 177.83 ≈ 0.0706650768394
 *
 * 177.83 is the luminous efficacy of the D65 standard illuminant (lm/W).
 * 4*pi converts from Watt/sr to total Watts (as Cycles expects).
 */
factor *= 0.0706650768394;
```

5. **Read vertical angles** (v_angles) and **horizontal angles** (h_angles).
6. **Read intensity grid** — `h_angles_num × v_angles_num` values, each multiplied by the computed factor.

### Processing — Type Normalization

All three IES photometric types (A, B, C) are normalized to a **Type C** representation in spherical coordinates:

| Type | Original Coordinate System | Processing |
|------|---------------------------|------------|
| **Type C** (most common) | Vertical 0°–180°, Horizontal 0°–360° | Symmetry expansion (90°→180°→360°), rotation fixes |
| **Type B** | Polar axis is horizontal | Transpose H↔V, then shift/mirror to match Type C |
| **Type A** | Automotive (road lighting) | V offset +90°, H inversion and mirroring |

After type normalization:
- All angles are converted from **degrees to radians**.
- Horizontal angles span 0 to 2π.
- Vertical angles span 0 to π.

### Packing (`IESFile::pack`)

The parsed data is serialized into a flat `float` array for GPU upload:

```
[ h_num (as int-in-float) ]
[ v_num (as int-in-float) ]
[ h_angle_0, h_angle_1, ..., h_angle_{h_num-1} ]
[ v_angle_0, v_angle_1, ..., v_angle_{v_num-1} ]
[ intensity[0][0..v_num-1], intensity[1][0..v_num-1], ... ]
```

Total packed size: `2 + h_num + v_num + h_num * v_num` floats.

---

## Layer 7 — LightManager Slot Table

**File**: [`intern/cycles/scene/light.h`](file:///c:/Users/aiadmin/Desktop/blender_build/blender/intern/cycles/scene/light.h#L209-L252) and [`intern/cycles/scene/light.cpp`](file:///c:/Users/aiadmin/Desktop/blender_build/blender/intern/cycles/scene/light.cpp#L1533-L1657)

The `LightManager` maintains a **slot table** of parsed IES profiles, with:
- **Hash-based deduplication** — identical IES content shares a single slot.
- **Reference counting** — slots are freed only when all users release them.
- **Thread safety** — all slot operations are protected by `ies_mutex`.

### Slot Structure

```cpp
struct IESSlot {
  IESFile ies;    // Parsed IES data
  uint hash;      // Hash of the raw content string
  int users;      // Reference count
};

vector<unique_ptr<IESSlot>> ies_slots;
thread_mutex ies_mutex;
```

### `add_ies()` — Core Slot Allocation

```cpp
int LightManager::add_ies(const string &content, const bool log_parsing_error)
{
  const uint hash = hash_string(content.c_str());
  const thread_scoped_lock ies_lock(ies_mutex);

  // 1. Check for existing slot with same hash (dedup)
  for (slot = 0; slot < ies_slots.size(); slot++) {
    if (ies_slots[slot]->hash == hash) {
      ies_slots[slot]->users++;
      return slot;   // Reuse existing parsed data
    }
  }

  // 2. Find an empty slot (users==0 && hash==0)
  // 3. If none found, append a new slot
  // 4. Parse the IES content: ies_slots[slot]->ies.load(content)
  // 5. Set users=1, hash, mark UPDATE_ALL

  return slot;
}
```

### `add_ies_from_file()` — External Mode Entry Point

Reads the file content from disk via `path_read_text()`, then calls `add_ies()`.

### `remove_ies()` — Reference Count Decrement

Decrements `users`; when reaching 0, marks the scene for update so the slot can be reclaimed.

---

## Layer 8 — GPU Upload & Device Scene

### Device Scene Buffer

**File**: [`intern/cycles/scene/devicescene.h`](file:///c:/Users/aiadmin/Desktop/blender_build/blender/intern/cycles/scene/devicescene.h#L87)

```cpp
device_vector<float> ies_lights;   // All IES profiles packed into one buffer
```

### Upload Logic (`device_update_ies`)

**File**: [`intern/cycles/scene/light.cpp`](file:///c:/Users/aiadmin/Desktop/blender_build/blender/intern/cycles/scene/light.cpp#L1611-L1657)

The buffer layout is:

```
┌──────────────────────────────────────────────────────────┐
│  OFFSET TABLE (one entry per slot)                       │
│  [slot_0_offset, slot_1_offset, ..., slot_N_offset]      │
│  (value = -1 if slot is invalid/empty)                   │
├──────────────────────────────────────────────────────────┤
│  PACKED IES DATA (contiguous)                            │
│  [slot_0_packed_data][slot_1_packed_data]...              │
└──────────────────────────────────────────────────────────┘
```

The offset table at the start allows O(1) lookup: given a slot index, read the offset, jump to the packed data.

```cpp
void LightManager::device_update_ies(DeviceScene *dscene)
{
  // 1. Clear unused slots (users==0 → hash=0, ies.clear())
  // 2. Shrink slot table (remove trailing empty slots)
  // 3. Calculate total packed_size
  // 4. Allocate: float *data = dscene->ies_lights.alloc(ies_slots.size() + packed_size)
  // 5. Write offset table:
  //      data[i] = __int_as_float(offset)  for valid slots
  //      data[i] = __int_as_float(-1)      for invalid slots
  // 6. Pack each slot: ies_slots[i]->ies.pack(data + offset)
  // 7. Upload: dscene->ies_lights.copy_to_device()
}
```

---

## Layer 9 — Kernel Evaluation (SVM)

### SVM Node Type

**File**: [`intern/cycles/kernel/svm/node_types.h`](file:///c:/Users/aiadmin/Desktop/blender_build/blender/intern/cycles/kernel/svm/node_types.h#L873-L882)

```cpp
struct SVMNodeIES {
  SVMInputFloat strength;
  uint slot;
  SVMStackOffset vector_offset;
  SVMStackOffset fac_offset;
  uint8_t _pad[2];
};
```

### SVM Evaluation

**File**: [`intern/cycles/kernel/svm/ies.h`](file:///c:/Users/aiadmin/Desktop/blender_build/blender/intern/cycles/kernel/svm/ies.h)

```cpp
ccl_device_noinline void svm_node_ies(KernelGlobals kg,
                                       ccl_private ShaderData *sd,
                                       ccl_private float *stack,
                                       const ccl_global SVMNodeIES &node)
{
  float3 vector = stack_load_float3(stack, node.vector_offset);
  const float strength = stack_load(stack, node.strength);

  vector = normalize(vector);
  const float v_angle = safe_acosf(-vector.z);           // Vertical: 0 at top (north pole)
  const float h_angle = atan2f(vector.x, vector.y) + M_PI_F;  // Horizontal: 0–2π

  const float fac = strength * kernel_ies_interp(kg, node.slot, h_angle, v_angle);

  if (stack_valid(node.fac_offset)) {
    stack_store_float(stack, node.fac_offset, fac);
  }
}
```

### Bicubic Interpolation

**File**: [`intern/cycles/kernel/util/ies.h`](file:///c:/Users/aiadmin/Desktop/blender_build/blender/intern/cycles/kernel/util/ies.h)

The `kernel_ies_interp()` function performs **bicubic interpolation** in the spherical coordinate space:

1. **Offset lookup**: `ofs = __float_as_int(kernel_data_fetch(ies, slot))` — reads from the offset table.
2. **Bounds check**: Returns 0.0 if angles are out of range, or 100.0 if the slot is invalid (-1 offset).
3. **Wrap detection**: Checks if H spans full 360° (for wraparound) and if V reaches the poles.
4. **Linear scan** to find the surrounding grid cell for the query angle.
5. **Vertical interpolation** (`interpolate_ies_vertical`): Cubic interpolation along the V axis using 4 points.
6. **Horizontal interpolation**: Cubic interpolation along the H axis using 4 vertically-interpolated values.
7. **Clamp**: `max(result, 0.0f)` — cubic interpolation can produce negative values.

The **pole wrapping** logic is notable: at the north pole (v=0), the function "mirrors" the lookup to the opposite side rather than clamping, avoiding visible artifacts.

---

## Layer 10 — Kernel Evaluation (OSL)

**File**: [`intern/cycles/kernel/osl/shaders/node_ies_light.osl`](file:///c:/Users/aiadmin/Desktop/blender_build/blender/intern/cycles/kernel/osl/shaders/node_ies_light.osl)

```osl
shader node_ies_light(
    int use_mapping = 0,
    matrix mapping = matrix(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0),
    string filename = "",
    float Strength = 1.0,
    point Vector = I,
    output float Fac = 0.0)
{
  point p = Vector;
  if (use_mapping) p = transform(mapping, p);

  p = normalize((vector)p);
  float v_angle = acos(-p[2]);
  float h_angle = atan2(p[0], p[1]) + M_PI;

  Fac = Strength * texture(filename, h_angle, v_angle);
}
```

The OSL path uses the standard `texture()` call with the IES filename. The `filename` parameter is set via `compiler.parameter_texture_ies("filename", slot)` during compilation, which maps the slot index to a texture handle.

---

## EEVEE Support

> **IES Texture nodes are NOT supported by EEVEE.**

There is no `gpu_shader_material_tex_ies.glsl` file, and no `SH_NODE_TEX_IES` handling anywhere in the `source/blender/gpu/` or `source/blender/draw/` directories. The IES node is silently ignored (outputs 0.0) when rendering with EEVEE/EEVEE Next.

---

## File Path Remapping & Portability

### Path Traversal for External Mode

**File**: [`source/blender/blenkernel/intern/node.cc`](file:///c:/Users/aiadmin/Desktop/blender_build/blender/source/blender/blenkernel/intern/node.cc#L460-L464)

The IES node participates in Blender's **path remapping** system via `node_foreach_path()`:

```cpp
else if (node->type_legacy == SH_NODE_TEX_IES) {
  NodeShaderTexIES *ies = static_cast<NodeShaderTexIES *>(node->storage);
  if (ies->mode == NODE_IES_EXTERNAL && ies->filepath[0]) {
    BKE_bpath_foreach_path_fixed_process(bpath_data, ies->filepath, sizeof(ies->filepath));
  }
}
```

This enables the following Blender features for external IES paths:
- **File → External Data → Find Missing Files**
- **File → External Data → Make All Paths Absolute**
- **File → External Data → Make All Paths Relative**
- **File → External Data → Report Missing Files**

Internal mode paths don't need remapping since the data is embedded.

---

## Complete File Reference

### Blender Core (source/blender/)

| File | Role |
|------|------|
| [`makesdna/DNA_node_types.h`](file:///c:/Users/aiadmin/Desktop/blender_build/blender/source/blender/makesdna/DNA_node_types.h#L2926-L2932) | `NodeShaderTexIES` struct and `eNodeIES_Mode` enum |
| [`makesrna/intern/rna_nodetree.cc`](file:///c:/Users/aiadmin/Desktop/blender_build/blender/source/blender/makesrna/intern/rna_nodetree.cc#L6641-L6668) | RNA property definitions (`def_sh_tex_ies`) |
| [`makesrna/intern/rna_nodetree.cc`](file:///c:/Users/aiadmin/Desktop/blender_build/blender/source/blender/makesrna/intern/rna_nodetree.cc#L4057-L4080) | Mode-switch setter (`rna_ShaderNodeTexIES_mode_set`) |
| [`nodes/shader/nodes/node_shader_ies_light.cc`](file:///c:/Users/aiadmin/Desktop/blender_build/blender/source/blender/nodes/shader/nodes/node_shader_ies_light.cc) | Node type registration, UI draw, init |
| [`blenkernel/intern/node.cc`](file:///c:/Users/aiadmin/Desktop/blender_build/blender/source/blender/blenkernel/intern/node.cc#L460-L464) | Path traversal / remapping |
| [`blenkernel/BKE_node_legacy_types.hh`](file:///c:/Users/aiadmin/Desktop/blender_build/blender/source/blender/blenkernel/BKE_node_legacy_types.hh#L113) | `SH_NODE_TEX_IES = 194` |

### Cycles Bridge (intern/cycles/blender/)

| File | Role |
|------|------|
| [`blender/shader.cpp`](file:///c:/Users/aiadmin/Desktop/blender_build/blender/intern/cycles/blender/shader.cpp#L1115-L1128) | Blender→Cycles node translation |
| [`blender/util.h`](file:///c:/Users/aiadmin/Desktop/blender_build/blender/intern/cycles/blender/util.h#L511-L528) | `get_text_datablock_content()` helper |

### Cycles Scene (intern/cycles/scene/)

| File | Role |
|------|------|
| [`scene/shader_nodes.h`](file:///c:/Users/aiadmin/Desktop/blender_build/blender/intern/cycles/scene/shader_nodes.h#L384-L402) | `IESLightNode` class declaration |
| [`scene/shader_nodes.cpp`](file:///c:/Users/aiadmin/Desktop/blender_build/blender/intern/cycles/scene/shader_nodes.cpp#L1404-L1488) | `IESLightNode` implementation (slot, SVM/OSL compile) |
| [`scene/light.h`](file:///c:/Users/aiadmin/Desktop/blender_build/blender/intern/cycles/scene/light.h#L209-L252) | `LightManager` IES API + `IESSlot` struct |
| [`scene/light.cpp`](file:///c:/Users/aiadmin/Desktop/blender_build/blender/intern/cycles/scene/light.cpp#L1533-L1657) | `LightManager` IES implementation |
| [`scene/devicescene.h`](file:///c:/Users/aiadmin/Desktop/blender_build/blender/intern/cycles/scene/devicescene.h#L87) | `device_vector<float> ies_lights` |

### Cycles Util (intern/cycles/util/)

| File | Role |
|------|------|
| [`util/ies.h`](file:///c:/Users/aiadmin/Desktop/blender_build/blender/intern/cycles/util/ies.h) | `IESFile` class (parser) |
| [`util/ies.cpp`](file:///c:/Users/aiadmin/Desktop/blender_build/blender/intern/cycles/util/ies.cpp) | IES parsing + type conversion + packing |

### Cycles Kernel (intern/cycles/kernel/)

| File | Role |
|------|------|
| [`kernel/svm/ies.h`](file:///c:/Users/aiadmin/Desktop/blender_build/blender/intern/cycles/kernel/svm/ies.h) | `svm_node_ies()` — SVM evaluation entry point |
| [`kernel/svm/node_types.h`](file:///c:/Users/aiadmin/Desktop/blender_build/blender/intern/cycles/kernel/svm/node_types.h#L873-L882) | `SVMNodeIES` struct |
| [`kernel/util/ies.h`](file:///c:/Users/aiadmin/Desktop/blender_build/blender/intern/cycles/kernel/util/ies.h) | `kernel_ies_interp()` — bicubic interpolation |
| [`kernel/osl/shaders/node_ies_light.osl`](file:///c:/Users/aiadmin/Desktop/blender_build/blender/intern/cycles/kernel/osl/shaders/node_ies_light.osl) | OSL shader |

### Tests

| File | Role |
|------|------|
| [`intern/cycles/test/util_ies_test.cpp`](file:///c:/Users/aiadmin/Desktop/blender_build/blender/intern/cycles/test/util_ies_test.cpp) | Unit tests for `IESFile` parser |

---

## Data Flow Diagram

```
                          USER
                           │
                     ┌─────┴──────┐
                     │  IES Mode  │
                     │  Toggle UI │
                     └─────┬──────┘
                           │
              ┌────────────┴────────────┐
              │                         │
         INTERNAL                  EXTERNAL
              │                         │
    ┌─────────┴─────────┐    ┌─────────┴──────────┐
    │  Text data-block  │    │  Filesystem path    │
    │  (node->id)       │    │  (storage->filepath)│
    └─────────┬─────────┘    └─────────┬───────────┘
              │                        │
              │   get_text_datablock_   │   blender_absolute_path()
              │   content()            │
              │                        │
              └──────────┬─────────────┘
                         │
                         ▼
               ┌─────────────────┐
               │  IESLightNode   │
               │  (Cycles Scene  │
               │   Graph)        │
               │                 │
               │  ies: ustring   │   ← Internal: raw content
               │  filename:      │   ← External: absolute path
               │    ustring      │
               └────────┬────────┘
                        │
                        ▼
               ┌─────────────────┐
               │  LightManager   │
               │  .add_ies()     │
               │  .add_ies_      │
               │   from_file()   │
               └────────┬────────┘
                        │
                        ▼
               ┌─────────────────┐
               │  IESFile        │
               │  .load()        │
               │  .parse()       │──→ Candela → Watts (×0.0707)
               │  .process()     │──→ Type A/B/C → Type C
               │  .pack()        │──→ Flat float array
               └────────┬────────┘
                        │
                        ▼
               ┌─────────────────┐
               │  IESSlot        │
               │  (hash dedup,   │
               │   ref counting) │
               └────────┬────────┘
                        │
                        ▼
               ┌─────────────────┐
               │  DeviceScene    │
               │  .ies_lights    │
               │  (device_vector │
               │   <float>)      │
               │                 │
               │  [offset_table] │
               │  [packed_data]  │
               └────────┬────────┘
                        │  copy_to_device()
                        ▼
               ┌─────────────────┐
               │  GPU / CPU      │
               │  Kernel         │
               │                 │
               │  svm_node_ies() │──→ Spherical coords
               │  kernel_ies_    │──→ Bicubic interp
               │   interp()      │──→ fac output
               └─────────────────┘
```

---

*This document was generated by analyzing the Blender source tree. All file references and line numbers correspond to the `main` branch as of 2026-08-01.*
