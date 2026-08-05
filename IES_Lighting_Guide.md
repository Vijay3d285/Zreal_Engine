# IES Photometric Light Profiles — Usage Guide

> Companion to [`implementation_plan_IES`](implementation_plan_IES) (architecture/PRD) and
> [`Implementing IES Lighting Support.md`](Implementing%20IES%20Lighting%20Support.md) (build log).
> This file is the **how do I actually use it** guide.

## What it does

An IES file (IESNA LM-63 format) encodes the real angular intensity distribution of a physical
light fixture — a downlight, a wall-washer, a streetlamp — as measured by the manufacturer.
Assigning one to a light makes its emission direction-dependent instead of uniform, the same way
a real luminaire's beam pattern isn't a perfect sphere or cone.

**Where it's active:** the RTX path tracer only (`servers/rendering/renderer_rd/forward_clustered/render_raytracing.cpp`
→ `raytracing_lights_inc.glsl`). The forward/rasterizer clustered renderer has the shader code
written (`scene_forward_lights_inc.glsl`) but it's compiled out behind `USE_IES_PROFILES`, which
nothing currently defines — so **IES profiles only visibly affect the scene when path tracing is
enabled** (`Environment.pathtracing_enabled = true`). In the rasterizer, lights with an IES
profile assigned just render as normal isotropic lights.

**Which lights support it:** `OmniLight3D` and `SpotLight3D` only. `DirectionalLight3D` (no
physical meaning at infinite distance) and `AreaLight3D` (already has its own emission geometry)
silently ignore IES settings.

## Editor usage

1. Select an `OmniLight3D` or `SpotLight3D` node.
2. In the Inspector, find the **IES Profile** group.
3. Set **Ies Mode**:
   - `None` — default, isotropic emission (no change from stock behavior).
   - `External` — points at a `.ies` file on disk via **Ies Filepath** (a file picker filtered to `*.ies`).
   - `Internal` — embeds the IES text inside an `IESProfile` resource via **Ies Profile**, so it
     travels with the `.tscn`/`.res` instead of depending on an external file path.
4. Set **Ies Strength** — a multiplier on top of the profile's own candela data (default `1.0`).
   Use it as a fudge factor once you've matched brightness against the rest of the scene; it does
   not replace `Light Energy`, both apply.

Switching `Internal → External` auto-populates the filepath from the resource's source path if it
has one; switching a light's type to `DirectionalLight3D`-incompatible modes just hides the
irrelevant properties (mirrors Blender's `ShaderNodeTexIES` mode-switch UX).

### Orientation: the beam follows the node's aim

IES profiles are evaluated in the **light's local frame**. The light's orthonormalized basis is
uploaded per-frame in `RT_LightData::ies_basis`, and the shader rotates the world-space direction
into that frame before the lookup (`lights_world_to_light_local()` in
`raytracing_lights_inc.glsl`). So:

> **Rotating the `Light3D` node aims the photometric distribution**, exactly as physically pointing
> a real fixture would. The profile's 0° (nadir) axis follows the light's **local −Z**.

Local −Z is Godot's light convention — it is already the direction a `SpotLight3D`'s cone points —
and it matches Blender's, so profiles behave the same way they do in Cycles.

The one thing to watch: Godot is **Y-up**, so a node with *no* rotation aims along world −Z, i.e.
**horizontally**. Blender is Z-up, where an unrotated light aims straight down, which is why
downlight profiles "just work" there on a fresh lamp. In Godot a ceiling downlight needs the node
rotated to point down:

```gdscript
light.rotation.x = -PI / 2      # aim local -Z at world -Y (straight down)
```

`SpotLight3D` nodes you already aim for the cone need no extra work — the cone and the IES lobe
share the same axis. `OmniLight3D` has no visible aim, so its rotation matters *only* once a
profile is attached; set it explicitly.

You never pre-rotate the `.ies` file itself.

### Intensity: `light_energy` means something different once a profile is attached

Without a profile, `light_energy` is the whole story. With one, the profile supplies **absolute**
intensity in watts/sr (raw candela × `4π / 177.83`), and `light_energy` multiplies on top of it.
The sample `ies_cob_spotlight.ies` peaks at 262,637 cd → ~18,600 W/sr; multiplying that by a
rasterizer-tuned `light_energy` of several hundred blows the image out to pure white.

**Start IES lights at `light_energy = 1.0`** and tune from there. Use `ies_strength` for
per-fixture trim.

The engine is Y-up (Blender/Cycles, which most IES tooling assumes conventions from, is Z-up) —
this is already handled internally by the GPU lookup (`ies_lookup_inc.glsl`), you don't need to
pre-rotate `.ies` files.

## GDScript usage

### External file (simplest — point at a `.ies` on disk)

```gdscript
var downlight := OmniLight3D.new()
downlight.light_energy = 8.0
downlight.omni_range = 6.0
downlight.ies_mode = Light3D.IES_MODE_EXTERNAL
downlight.ies_filepath = "res://lighting/ies/manufacturer_downlight_60deg.ies"
downlight.ies_strength = 1.0
add_child(downlight)
```

`ies_filepath` accepts `res://` paths (Godot resolves them) or absolute filesystem paths.

### Internal / embedded (portable — no external file dependency)

```gdscript
var spot := SpotLight3D.new()
spot.light_energy = 12.0
spot.spot_range = 8.0

var profile := IESProfile.new()
profile.load_from_file("res://lighting/ies/wall_washer.ies")  # reads once, stores the text

spot.ies_mode = Light3D.IES_MODE_INTERNAL
spot.ies_profile = profile
spot.ies_strength = 1.0
add_child(spot)
```

Because `IESProfile` just stores raw text (`ies_text`), you can also build one from an
in-memory string (e.g. a profile fetched or generated at runtime) instead of a file:

```gdscript
var profile := IESProfile.new()
profile.set_ies_text(raw_ies_content_string)
spot.ies_mode = Light3D.IES_MODE_INTERNAL
spot.ies_profile = profile
```

### Clearing a profile

```gdscript
light.ies_mode = Light3D.IES_MODE_NONE
```

This releases the GPU-side IES slot reference (ref-counted; a profile only frees its slot once no
light references it anymore — assigning the same `.ies` file to many lights reuses one GPU slot).

### Full property/enum reference

| Property | Type | Notes |
|---|---|---|
| `ies_mode` | `Light3D.IESMode` (`IES_MODE_NONE` / `IES_MODE_EXTERNAL` / `IES_MODE_INTERNAL`) | Default `IES_MODE_NONE` |
| `ies_filepath` | `String` | Used when `ies_mode == IES_MODE_EXTERNAL` |
| `ies_profile` | `IESProfile` | Used when `ies_mode == IES_MODE_INTERNAL` |
| `ies_strength` | `float` (0..1,000,000, `or_greater`) | Multiplier on top of the profile's own candela scaling; default `1.0` |

`IESProfile` (`scene/resources/ies_profile.h`) API:

| Method | Notes |
|---|---|
| `set_ies_text(text: String)` | Set raw IES content directly |
| `get_ies_text() -> String` | Read back the stored content |
| `load_from_file(path: String) -> Error` | Reads a `.ies` file and stores its content internally |

## Using it in `pipeline_references/render.gd`

`render.gd`'s `setup_fixed_fill_lights()` (and the manual-fixture path around it) builds
`SpotLight3D`/`OmniLight3D` nodes procedurally with `light_energy` / `light_color` /
`light_specular` / `spot_range` / `omni_range`. To give an authored fixture light a real-world
beam pattern, set the IES properties the same way right after creating the node, e.g.:

```gdscript
var light = SpotLight3D.new()
light.spot_range = clamp(spacing * 3.5, 6.0, 12.0)
light.light_energy = grid_energy
light.light_color = fill_color
light.light_specular = 0.0
# --- IES profile ---
light.ies_mode = Light3D.IES_MODE_EXTERNAL
light.ies_filepath = "res://lighting/ies/recessed_downlight.ies"
light.ies_strength = 1.0
```

Because IES only affects the raytracing path, gate any IES-dependent visual comparisons on
`environment.pathtracing_enabled` — with the rasterizer active you'll see the light's normal
isotropic falloff regardless of the assigned profile.

If you tag fixture lights with `authored_custom_light` metadata (as `render.gd` already does for
color-mood tinting), IES assignment fits naturally into that same authoring step rather than the
automated fill-light grid, since fill lights are meant to be soft ambient bounce, not
fixture-accurate beams.

## Where to get `.ies` files

- Manufacturer product pages (search "`<fixture model> IES file`" or "`<fixture model>
  photometric data`") — most commercial fixture vendors publish them for architectural lighting
  design software (AGi32, Relux, DIALux).
- Free libraries exist online with a range of downlight/spot/floodlight profiles if you don't have
  a specific fixture to match.

Any standard LM-63 file (`TYPE_A`, `TYPE_B`, or `TYPE_C`, `TILT=NONE` or `TILT=INCLUDE`) is
supported — all three photometric types are normalized to Type C internally before packing.

## Troubleshooting

- **No visible effect** — confirm `Environment.pathtracing_enabled` is `true`. IES is currently
  raytracing-only.
- **Beam shoots sideways instead of down** — the node has no rotation, and Godot's unrotated light
  aims along world −Z (horizontal), not down. Set `rotation.x = -PI / 2`. See "Orientation" above.
- **Scene blows out to white after attaching a profile** — `light_energy` is multiplying the
  profile's absolute candela output. Drop it to `1.0` and re-tune. See "Intensity" above.
- **Light contributes nothing at all (render is identical with and without it)** — this was a
  parser bug with rotationally symmetric profiles (single horizontal angle), fixed 2026-08-04. If
  you see it again, the profile's horizontal angle table is the first thing to check.
- **Whole scene changed brightness after loading a profile** — the raw candela values are
  converted with the same `4π / 177.83` candela→watts factor Blender Cycles uses; profiles vary a
  lot in absolute output, so `ies_strength` and/or `light_energy` may need retuning per-profile —
  this isn't a bug, real fixtures vary by orders of magnitude in raw lumen output.
- **File doesn't load** (`ies_filepath` set but nothing happens) — check the editor/console for
  `IESManager: Failed to parse IES content.` or `Cannot open IES file '...'` errors; malformed or
  non-LM-63 files fail closed (light falls back to isotropic, `ies_slot == -1`).
- **Directional or Area light IES properties are greyed out / do nothing** — expected, see
  "Which lights support it" above.
