# raycaster_oidn — in-process OIDN final-denoise for path tracing

This optional module links the **NVIDIA Open Image Denoise (OIDN) 2.5.0** library
in-process and exposes it to the RTX path tracer as a one-shot, non-temporal
*final* denoise on the converged accumulator (the Cycles-style "accumulate raw,
denoise final" pipeline).

## Build

Only on **Windows x86_64 editor** builds. It is auto-detected by SCons (see
`config.py`); no build flag required — but `oidn=yes` is accepted implicitly
through the module being present.

The prebuilt OIDN distribution must live at `thirdparty/oidn/` with this layout
(sourced from the official `oidn-2.5.0.x64.windows` release zip):

```
thirdparty/oidn/
  include/OpenImageDenoise/oidn.h
  include/OpenImageDenoise/oidn.hpp
  include/OpenImageDenoise/config.h
  lib/OpenImageDenoise.lib
  lib/OpenImageDenoise_core.lib
  bin/OpenImageDenoise.dll
  bin/OpenImageDenoise_core.dll
  bin/OpenImageDenoise_device_cpu.dll
  bin/tbb12.dll
  bin/tbbbind.dll, tbbbind_2_0.dll, tbbbind_2_5.dll
  bin/sycl8.dll
  bin/ur_loader.dll, ur_win_proxy_loader.dll, ur_adapter_level_zero.dll
```

The `.lib` import libraries are used at link time (`SCsub` appends them to
`LIBS`/`LIBPATH`).

## Runtime — IMPORTANT

The OIDN **runtime DLLs** are a plugin set: `OpenImageDenoise.dll` is just a
loader; the actual denoiser lives in `_core.dll` plus `_device_cpu.dll`, and
the CPU device depends on TBB (`tbb12.dll`). At runtime **all** the `bin/`
DLLs above must be on the process DLL search path. The simplest reproducible
setup: copy every `thirdparty/oidn/bin/*.dll` next to the editor executable
(`bin/godot.windows.editor.x86_64.exe`).

If the DLLs are missing, `PathtraceOIDNDenoiser::create()` still returns a
non-null object, but the first `denoise_rt` call fails to create the device,
logs an `ERR_PRINT`, and the RT path keeps the **raw converged** image (no
denoise) — the render still completes, just grainier.

## Architecture

- `servers/rendering/renderer_rd/pathtrace_oidn_denoiser.{h,cpp}` — abstract
  base in the renderer layer with a `create_function` factory hook (mirrors
  `scene/3d/lightmapper.h`'s `LightmapDenoiser`). Compiled unconditionally in
  `renderer_rd`; if the module isn't linked, `create()` returns null.
- `modules/raycaster_oidn/oidn_denoiser.{h,cpp}` — concrete `OIDNDenoiser`
  wrapping the OIDN C API (`oidn.h`): lazily creates a CPU device, and per
  `denoise_rt` builds an `RT` filter with `hdr=true` over shared host
  float3 color/albedo/normal buffers (in-place denoise).
- `modules/raycaster_oidn/register_types.cpp` — module init sets
  `PathtraceOIDNDenoiser::create_function = OIDNDenoiser::create_oidn_denoiser`
  at `MODULE_INITIALIZATION_LEVEL_SERVERS`.
