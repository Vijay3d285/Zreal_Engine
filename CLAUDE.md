# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A **fork of Godot Engine 4.7-beta** (`version.py`) extended with a custom **RTX hardware path tracer** integrated into the Forward+ (Vulkan RD) renderer, plus **DLSS Ray Reconstruction** (via NVIDIA Streamline) and **OIDN** denoisers, and an offline still-image/video capture pipeline. The stock Godot README is still present and stock-modification-instructions apply; the project-specific work lives in `servers/rendering/renderer_rd/`, `drivers/streamline/`, `pipeline_references/`, and several root-level `*.md` design docs.

Branch lineage matters here. Feature work lives on branches prefixed `vijay_pt*` / `vijay_PTEngine*` (e.g. current `vijay_PTEngine5_ies`, prior `vijay_pt2_shadows`, `vijay_pt3_phaseA`, `nvidia-pt-dlss`); `master` is the upstream-tracking default. Each phase branch tends to layer on the previous one's work.

## Build

Godot uses **SCons** (`SConstruct`), Python >=3.9, SCons >=4.4, a Vulkan SDK, and (for this fork) **NVIDIA Streamline** for the DLSS path. Build artifacts land in `bin/` (e.g. `bin/godot.windows.editor.x86_64.exe`). The required Streamline/NVIDIA DLLs (`sl.common.dll`, `sl.dlss.dll`, `sl.interposer.dll`, `nvngx_dlssd.dll`) and OIDN (`OpenImageDenoise*.dll`) must be present in `bin/` or DLSS-RR/OIDN silently no-op at runtime.

```powershell
# Editor debug build (default target=editor). Always pass platform=windows on this machine.
scons platform=windows target=editor          # debug/dev-features
scons platform=windows target=template_debug  # export template, debuggable
scons platform=windows target=template_release

# Faster, no debug symbols / no tests — production defaults
scons platform=windows production=yes

# Faster incremental rebuilds on Windows (if you have ninja installed)
scons platform=windows ninja=yes
```

Fork-specific SCons options of note (defined in `SConstruct`, detected per-platform in `platform/<plat>/detect.py`):

- `use_streamline=yes` (default true) — builds the DLSS / NvLowLatency Streamline integration. Off → DLSS-RR unavailable.
- `use_aftermath` (default false) — NVIDIA Nsight Aftermath crash dumps.
- `tests=yes` — compile the doctest unit suite (see Tests).
- `precision=single|double` (default single), `vulkan=yes` (default), `d3d12=no|yes`, `opengl3=yes`.
- `dev_build=yes` — `DEV_ENABLED` debug-only code paths.
- `dev_mode=yes` — convenience alias for `verbose=yes warnings=extra werror=yes tests=yes strict_checks=yes`.
- `scu_build=yes` — single-compilation-unit build (lower RAM, faster full rebuilds).

Because the GLSL shaders and module list are code-generated at build time, **after touching a `.glsl` file or adding a module, run a full scons build** so the `.glsl.gen.h` files and `modules/modules_enabled.gen.h` regenerate.

## Run / capture

The Godot game project that drives the path tracer lives in `pipeline_references/` (`project.godot` → `config/name="4k_Unreal_Engine_v1 - godot"`). Run:

```powershell
# Editor on the pipeline_references project (chdir into it, run the editor exe)
bin\godot.windows.editor.x86_64.exe --path pipeline_references -e

# Headless still-image / video capture driven by pipeline_references/render.gd etc.
# See pipeline_references/render.gd :: render_image() / render_video().
```

Rendering driver / display driver are runtime CLI flags (`--rendering-driver`, `--display-driver`), parsed in `main/main.cpp`. Path tracing itself is toggled from GDScript via `Environment.set_pathtracing_enabled / set_pathtracing_max_bounces / set_pathtracing_samples_per_pixel / set_pathtracing_denoiser` (params packed as `float pathtracing_params[16]` in `environment_storage`).

## Tests

The unit-test suite is **doctest** (`thirdparty/doctest`, wrapped by `tests/test_macros.h`). Test registration uses `register_test_command(...)`; `tests/test_main.cpp` strips `--test` and forwards the rest to `doctest::Context`. You must build tests in, then run the editor binary:

```powershell
scons platform=windows tests=yes target=editor
bin\godot.windows.editor.x86_64.exe --test                         # all tests
bin\godot.windows.editor.x86_64.exe --test "ies_parser*"           # doctest filter (substring/wildcard)
bin\godot.windows.editor.x86_64.exe --test gdscript-parser          # run a named registered command
bin\godot.windows.editor.x86_64.exe --test --no-skip                # include TEST_CASE_PENDING
```

There is no separate lint/test runner script; conventions follow upstream Godot.

## High-level architecture

This fork keeps Godot's standard layering (`core/`, `scene/`, `servers/`, `editor/`, `modules/`, `platform/`, `drivers/`, `thirdparty/`). The custom work is concentrated in three subsystems:

### 1. Path tracer (the central feature)
Lives **inside the Forward+ RD renderer**, not as a separate renderer.

- C++ driver: `servers/rendering/renderer_rd/forward_clustered/render_raytracing.cpp` (~3000+ lines) + `render_raytracing.h`. Builds TLAS/BLAS, the light buffer, the `rt_params` UBO, and dispatches the raygen pipeline. Key structs are `RT_GeometryData` (128B, std430) and `RT_LightData` (grew 80→96B to add `ies_slot`/`ies_strength`); both **must stay byte-identical to their GLSL counterparts** and are guarded by `static_assert` + `alignas(16)`.
- Pipeline/reflection: `scene_shader_raytracing.{cpp,h}`.
- GLSL: `servers/rendering/renderer_rd/shaders/raytracing/`. Core files:
  - `scene_raytracing_raygen.glsl` (+ `.glsl.gen.h`) — raygen/miss/closest_hit/any_hit/intersection.
  - `raytracing_inc.glsl` — payload packing, RNG, ray-origin offset, bounce flags, **`MAX_DIFFUSE_BOUNCES` is hardcoded to 2** (a known quality gap — see `PATH_TRACER_QUALITY_ROADMAP.md`).
  - `brdf_inc.glsl` — Boksansky BRDF library (VNDF GGX, height-correlated Smith G2, multi-scatter comp already present).
  - `raytracing_lights_inc.glsl` — NEE + reservoir light selection + shadow rays; IES modulation applied here.
  - `raytracing_closest_hit_common_inc.glsl` — `shade_and_bounce()`, the integrator kernel.
- Exposure knobs are ClassDB-bound on `Environment` (see `environment_storage.cpp` `environment_set_pathtracing_params`). `SPP` and `max_bounces` are **shader specialization constants** (`RT_GET_SAMPLE_COUNT()`, `scene_raytracing_raygen.glsl:45/51`) — changing them recompiles the pipeline. Only `RT_PARAM_FRAME_INDEX` (RNG seed) varies per frame.

`PATH_TRACER_QUALITY_ROADMAP.md` is the canonical diagnosis of why this fork trails Blender Cycles/D5 and the prioritized fix list (offline accumulation, MIS, emissive-mesh lights, bounce-count control, blue-noise sampling, Russian Roulette, etc.). **Read it before touching the integrator.**

### 2. Accumulation + denoising pipeline (Phase A / F / F2)
- Accumulation buffers for still convergence: `RT_TEX_RAYTRACING_ACCUM` / `RT_TEX_RAYTRACING_ACCUM_N` (defined `render_raytracing.h:48-49`).
- **DLSS Ray Reconstruction**: `servers/rendering/renderer_rd/effects/dlss.{cpp,h}` over `drivers/streamline/`. Outputs G-buffers (`RB_TEX_DLSS_RR_*` diffuse/specular albedo, normal/roughness, hit-dist). **DLSS-RR needs per-frame NOISY samples, NOT a converged image** — see memory note `pt-dlss-rr-realtime-temporal-truth`. Requires the `sl.*.dll`s in `bin/`; otherwise `slDLSSDSetOptions` stays null and it silently evaluates false.
- **OIDN**: in-process link against the prebuilt `OpenImageDenoise*.dll` binaries (RT filter) used as the accumulate→denoise final pass for stills. `cleanAux` must be `true` for analytic G-buffer AOVs and normals are **world-space** — see memory notes `pt-oidn-inprocess-denoiser`, `pt-oidn-cleanaux-worldspace-normal`.

### 3. IES photometric light profiles (in-flight, current branch)
A 7-layer port of Blender Cycles' `IESFile` (`implementation_plan_IES` is the PRD; `Implementing IES Lighting Support.md` is the implementation chat log):

- Parser: `core/io/ies_file.h/.cpp` — LM-63 parse, Type A/B/C → Type C normalization, candela→watts (`* 0.0706650768394`), pack to flat `[2 + h_num + v_num + h_num*v_num]` floats matching Cycles.
- Resource: `scene/resources/ies_profile.h/.cpp` (`IESProfile : Resource`) — embedded/internal mode.
- Slot manager: `servers/rendering/renderer_rd/storage_rd/ies_manager.h/.cpp` (`IESManager`) — hash dedup + refcount + mutex, `device_update()` uploads the `[offset_table][packed…]` SSBO.
- GPU shader: `servers/rendering/renderer_rd/shaders/raytracing/ies_lookup_inc.glsl` — bicubic spherical interpolation. **Our engine is Y-up, Cycles is Z-up**: `v_angle = acos(-y)`, `h_angle = atan(x,z)` (not `acos(-z)`/`atan(x,y)`).
- Per-light data added to `RT_LightData` (RT) and `LightData`/`light_data_inc.glsl` (forward). Applied in both `raytracing_lights_inc.glsl` (NEE) and `scene_forward_lights_inc.glsl` (`light_process_omni`/`spot`).
- Plumbing follows Godot's storage pattern (see below): abstract API in `servers/rendering/rendering_server.h` + enums in `rendering_server_enums.h` (`LightIESMode`), auto-forwarded via `FUNC*` macros in `rendering_server_default.h` to `RendererLightStorage`, with dummy fallback stubs in `servers/rendering/dummy/storage/light_storage.h`. Scene node `Light3D` exposes the GDScript/Inspector surface.

## Godot conventions you must respect when extending this codebase

- **Storage abstraction**: interfaces live in `servers/rendering/storage/*.h`; the RD (Vulkan) implementations live in `servers/rendering/renderer_rd/storage_rd/*.h/.cpp`; headless/dummy fallbacks in `servers/rendering/dummy/storage/`. When you add an `RS` light/material/etc. API method, update all three (`rendering_server.h` virtual → `rendering_server_default.h` `FUNC*` forward → RD impl → dummy stub) or the headless build breaks.
- **Shaders**: GLSL lives in `servers/rendering/renderer_rd/shaders/`. At build time `glsl_builders.py` (`build_rd_header` for RD shaders incl. raytracing stages, `build_raw_header` for raw includes) emits `<name>.glsl.gen.h` reflection headers that C++ includes. Edit the `.glsl`; do not hand-edit `.gen.h`. Include fragments conventionally use `_inc.glsl` suffix.
- **Modules**: each `modules/<m>/` has `SCsub`, `config.py`, `register_types.{cpp,h}`. New `.cpp` files are auto-globbed by `SCsub` (`env.add_source_files(... "*.cpp")`); you only edit `register_types.cpp` to register classes and `modules_enabled.gen.h` is regenerated from `env.module_list`. Three custom modules here: **`lightmapper_rd`** (GPU lightmapper), **`raycast`** (Embree occlusion/static raycaster), **`raycaster_oidn`** (in-process OIDN).
- **Scene registration**: new `Resource`/`Node` classes get ClassDB-bound in `scene/register_scene_types.cpp` (e.g. `IESProfile` was added there).
- **C++ ↔ GLSL struct parity**: any struct uploaded to a UBO/SSBO (e.g. `RT_LightData`, `RT_GeometryData`, `LightData`) has a verbatim GLSL twin (`*_inc.glsl` / `light_data_inc.glsl`). Sizes, member order, `alignas`/`std430` layout, and `static_assert(sizeof == N)` must agree on both sides and with any binding indices you reference.
- **`SNAME`**: hot paths use `SNAME("literal")` for StringNames (see the `RB_TEX_*` defines in `render_raytracing.h`).

## Project-specific doc map (read before editing that area)

- `PATH_TRACER_QUALITY_ROADMAP.md` — gap analysis vs Cycles/D5; code anchors for the integrator.
- `DLSS_Implementation.md` — Streamline/DLSS-RR integration, required DLLs, failure modes.
- `implementation_plan_IES` — IES support PRD (architecture, file inventory, phases, open questions Q1–Q3).
- `Implementing IES Lighting Support.md` — session log of the IES layer-by-layer implementation.
- `ies_light_implementation.md` — the Blender Cycles reference analysis the IES work is ported from.
- `implementation_plan.md`, `nanite_geometry_performanceImplementation.txt` — Nanite-geometry / perf work.
