# 16-bit PNG Encoding — Implementation Record

**Date:** 2026-08-29
**Engine:** Godot v4.7.beta custom_build (`vijay_PTEngine_v8_Quality` fork), Forward+, Vulkan
**Scope:** PNG output encoding only — engine writer + still-render pipeline

---

## 1. Problem

Blender's default still output is a **16-bit RGB PNG** at "Compression 15%".
Godot's was an **8-bit RGB PNG**. At 3840×2160 that is:

| Encoding | Raw bytes | |
|---|---|---|
| RGB **8**-bit | 24,883,200 | 24.9 MB |
| RGB **16**-bit | 49,766,400 | 49.8 MB |

Two independent factors stacked to produce the observed ~5× file-size gap:

1. **Bit depth — 2.0×.** Godot wrote 8 bits per channel, always.
2. **Compression ratio — ~2.5×.** Blender at zlib level 1; and 16-bit data barely
   compresses at *any* level because the low byte of each channel is near-random
   (ratio ≈ 1.0 vs ≈ 0.40 for 8-bit).

The blocking defect was not the encoder setting but that **`image_to_png()` uses
libpng's *simplified* API**, whose `default:` branch converts any float or half
image down to `RGB8`/`RGBA8` before writing. The quantisation happened before the
file was ever created, so no encoder option could recover it.

---

## 2. Engine changes

All paths relative to the engine repo root (`C:\Zlendo2026\godot`).

### 2.1 `drivers/png/png_driver_common.h`

Declared a second writer alongside the existing one:

```cpp
Error image_to_png16(const Ref<Image> &p_image, Vector<uint8_t> &p_buffer,
        int p_compression_level = 6, bool p_srgb_encode = true);
```

### 2.2 `drivers/png/png_driver_common.cpp`

Added `#include "core/math/math_funcs.h"` and `<string.h>`, plus:

- **`image_to_png16()`** — uses the **full libpng API** (`png_create_write_struct`
  / `png_set_IHDR` / `png_write_row`), so it can emit `PNG_COLOR_TYPE_RGB` or
  `PNG_COLOR_TYPE_RGB_ALPHA` at bit depth 16.
- **`PNG16Sink` + `_png16_write()`** — a growing memory sink in an anonymous
  namespace.

Implementation details that matter:

| Decision | Reason |
|---|---|
| Alpha determined from the **format**, not `detect_alpha()` | An HDR readback is `FORMAT_RGBH`, which has no alpha channel; `detect_alpha()` would walk every pixel to conclude the same |
| Converts to `FORMAT_RGBF` / `FORMAT_RGBAF` before quantising | Converting to an 8-bit format first would discard the precision the function exists to preserve. Crosses `_are_formats_compatible()` group boundaries, so `convert()` takes its generic per-pixel path — slower, but **unclamped** |
| Samples written **big-endian by hand** (no `png_set_swap`) | Result does not depend on host endianness |
| Sink **doubles capacity**, buffer trimmed once at the end | libpng emits in ~8 KiB chunks; a naive `Vector::resize` per chunk is O(n²) — thousands of full-buffer copies on a 50 MB file |
| Every non-trivial local declared **before `setjmp`** | Values written after `setjmp` are indeterminate on `longjmp`; nothing written after it is read in the error path |
| Values clamped to `[0,1]` after encoding | Anything above SDR white clips exactly as an 8-bit save would. The gain is precision *below* white, not extra range |

### 2.3 `drivers/png/resource_saver_png.h` / `.cpp`

```cpp
static Error save_image_16(const String &p_path, const Ref<Image> &p_img, int p_compression, bool p_srgb);
static Vector<uint8_t> save_image_16_to_buffer(const Ref<Image> &p_img, int p_compression, bool p_srgb);
```

Wired into the constructor beside the existing assignments:

```cpp
Image::save_png16_func        = &save_image_16;
Image::save_png16_buffer_func = &save_image_16_to_buffer;
```

### 2.4 `core/io/image.h` / `.cpp`

Mirrors the existing `save_png` pattern exactly:

```cpp
// image.h — typedefs
typedef Error (*SavePNG16Func)(const String &p_path, const Ref<Image> &p_img, int p_compression, bool p_srgb);
typedef Vector<uint8_t> (*SavePNG16BufferFunc)(const Ref<Image> &p_img, int p_compression, bool p_srgb);

// image.h — statics
static inline SavePNG16Func       save_png16_func        = nullptr;
static inline SavePNG16BufferFunc save_png16_buffer_func = nullptr;

// image.h — methods
Error save_png16(const String &p_path, int p_compression = 6, bool p_srgb_encode = true) const;
Vector<uint8_t> save_png16_to_buffer(int p_compression = 6, bool p_srgb_encode = true) const;
```

Bound to GDScript in `_bind_methods()`:

```cpp
ClassDB::bind_method(D_METHOD("save_png16", "path", "compression", "srgb_encode"),
        &Image::save_png16, DEFVAL(6), DEFVAL(true));
ClassDB::bind_method(D_METHOD("save_png16_to_buffer", "compression", "srgb_encode"),
        &Image::save_png16_to_buffer, DEFVAL(6), DEFVAL(true));
```

---

## 3. Pipeline changes — `godot_project/render.gd`

> **The engine writer alone is worthless.** Without the framebuffer change below,
> the render target stays `RGBA8`, `get_image()` returns `FORMAT_RGB8`, and the
> 16-bit writer faithfully stores **256 distinct levels padded out to 16 bits** —
> a 50 MB file carrying 8 bits of information. The precision must exist *before*
> the save.

### 3.1 `set_resolution()` — enable the HDR framebuffer

```gdscript
var want_hdr_output: bool = _image_render_only
get_viewport().use_hdr_2d = want_hdr_output
get_viewport().use_debanding = not want_hdr_output
```

- `use_hdr_2d` makes the render target `R16G16B16A16_SFLOAT`
  (`texture_storage.cpp:5259`, `render_target_get_color_format`).
- Debanding is dither that exists **only** to mask 8-bit quantisation banding. At
  16 bits there is no banding to mask, so it only injects noise — which also
  inflates the PNG, making file size look better while the image looks worse.
- Gated on `_image_render_only`: **video stays on the 8-bit path**, since it is
  encoded to mp4 downstream and the extra precision is discarded anyway.

### 3.2 `render_image()` — write 16-bit

```gdscript
var used_16bit := false
if img.has_method("save_png16") and get_viewport().use_hdr_2d:
    var err16: int = img.save_png16(output_path, 1, true)
    ...
```

`compression = 1` matches Blender's "Compression 15%". `srgb_encode = true` — see
the contract below.

### 3.3 New helper `_linear_image_to_srgb8()`

Needed for the thumbnail and the 8-bit fallback. Preferred route encodes to a
16-bit PNG in memory (applying the exact sRGB OETF in C++ on full-precision float
data) and loads it straight back — the PNG **loader** masks out
`PNG_FORMAT_FLAG_LINEAR`, so libpng performs the 16→8 down-convert natively.

---

## 4. THE COLOUR-SPACE CONTRACT

**This is the part that breaks silently if you get it wrong.**

`renderer_scene_render_rd.cpp:722` sets:

```cpp
tonemap.convert_to_srgb = !using_hdr;
```

| `use_hdr_2d` | Render target | Buffer contents | `get_image()` returns | Correct save |
|---|---|---|---|---|
| `true` | `RGBA16F` | **LINEAR** | `FORMAT_RGBH` (half-float, alpha dropped unless RT is transparent) | `save_png16(path, 1, **true**)` |
| `false` | `RGBA8` | **already sRGB-encoded** | `FORMAT_RGB8` | plain `save_png()` |

With HDR on, `FLAG_CONVERT_TO_SRGB` is not set and `linear_to_srgb()` is never
applied to the stored value — in the BCS branch it is applied at `tonemap.glsl:918`
and explicitly **undone** at `:940`. There is no hardware sRGB encode either,
because the framebuffer attaches the plain `RGBA16F` `rt->color`, never
`color_format_srgb`.

### Traps

- **`Image.convert(FORMAT_RGB8)` on a linear image is a raw clamp with no sRGB
  encode** (`image.cpp:3589`) → badly darkened image. Use
  `_linear_image_to_srgb8()`.
- Passing `srgb_encode = false` on the HDR path → very dark image.
- Passing `srgb_encode = true` on a non-HDR (already-encoded) buffer → washed out,
  double-encoded.
- `Image.linear_to_srgb()` **is** bound (`image.cpp:3905`) but requires
  `RGB8`/`RGBA8` and uses a 256-entry LUT — it must quantise first and is
  therefore approximate, badly so in darks (the LUT jumps 0 → 12). Fallback only.

---

## 5. GDScript typing fixes required by the pipeline change

These fail at **parse** time, not run time — and a parse error in a parent script
surfaces as *"Could not resolve super class inheritance"* pointing at the child.

| Was | Problem | Fix |
|---|---|---|
| `var out_img := img` | `img` comes from `await _capture_viewport_image(6)`, which has no declared return type → Variant → `:=` cannot infer | `var out_img: Image = img` |
| `var work := source.duplicate()` | `Image` does not declare its own `duplicate()`; GDScript sees `Resource.duplicate() -> Resource`, so every `work.get_width()` / `.convert()` after it fails to parse | `var work: Image = source.duplicate() as Image` |
| `source.save_png16_to_buffer(...)` | `source` is statically typed `Image`; on a binary lacking the method this is a **parse** error, defeating the `has_method()` guard entirely | `source.call("save_png16_to_buffer", 1, true)` |

---

## 6. Verification

### 6.1 Standalone libpng harness (pre-build)

The libpng call sequence and pixel loop were extracted verbatim into a standalone
program, compiled with `-Wall -Wextra` (clean), and checked against a hand-written
16-bit PNG decoder:

- IHDR bit depth 16, colour types 2 (RGB) and 6 (RGBA) ✔
- sRGB OETF exact to **±1 LSB** at every sampled point ✔
- alpha **not** sRGB-encoded ✔
- `srgb_encode = false` stays linear ✔
- values clip correctly at 1.0 ✔
- a 512-wide ramp holds **512 distinct levels** (8-bit caps at 256) ✔

### 6.2 Real render (`quality_test_3_render.png`, 39.8 MB)

| Measurement | Result |
|---|---|
| Dimensions | 3840 × 2160 — genuine 4K, **not** window-clamped |
| Bit depth / colour type | 16 / RGB |
| Compression ratio | 0.800 of raw |
| Distinct levels per channel | **10,256** (8-bit caps at 256) |
| Low-byte entropy | **7.93 / 8 bits** → real data, not padding |
| Flat 128×128 patch | 1,232 levels at 16-bit vs **72** at 8-bit |
| Frame area that is near-flat gradient | 48.7% |

### 6.3 The result that defines the scope

Taking the 16-bit render and truncating to 8 bits, then measuring detail in both:

```
laplacian variance, 16-bit : 3.998303e-03
laplacian variance,  8-bit : 4.023241e-03
ratio                      : 0.9938
```

**Bit depth cannot change sharpness.** The gain is *levels*, not *detail* —
banding elimination across the ~49% of the frame that is smooth gradient (walls,
floor falloff, soft shadows).

---

## 7. Scope — what this does NOT do

This is **encoding parity**. It is not image parity. The following remain
outstanding and are what actually change how the picture looks:

- `glow_enabled = true` (`image_glb_creation.gd:737`) — Blender 4.x has no bloom
  outside the compositor
- Day tonemap is **ACES at `tonemap_exposure = 1.5`** (lines 595, 610), not
  Blender's AgX
- Invented fill lights — ceiling ambient, four corner fills, floor fill
- DLSS-RR softness at SPP 6 × 128 frames
- Camera defects: FOV convention (vertical vs horizontal), `current` never set,
  Blender `rotation_euler` basis conversion

**Do not measure render quality by PNG file size.** It measures entropy, not
fidelity: debanding dither *inflates* it while adding no detail, and denoiser
smoothing *shrinks* it while removing detail. Use `compare_render_encoding.py`,
which re-encodes both files to a common baseline and separates the pixel-count,
encoding and content factors.

---

## 8. Build & rollback

```
scons platform=windows target=editor
```

→ `bin/godot.windows.editor.x86_64.exe`. Touching `core/io/image.h` rebuilds most
of the engine; budget a long compile. The `render.gd` changes are GDScript and
need no rebuild.

**Rollback:** the engine repo is under git — `git diff` shows the five changed
files, `git checkout` reverts them. Note the live project at
`C:\Zlendo2026\4k_PT_Engine_dev\godot_project` is **not** a git repo, so
`render.gd` there has no such safety net.

### Reverting behaviour without reverting code

Set `get_viewport().use_hdr_2d = false` in `set_resolution()`. The `save_png16`
guard requires it, so the pipeline falls back to the original 8-bit `save_png()`
path with debanding restored — no rebuild needed.

---

## 9. Files changed

**Engine** (`C:\Zlendo2026\godot`, rebuild required)

```
drivers/png/png_driver_common.h
drivers/png/png_driver_common.cpp
drivers/png/resource_saver_png.h
drivers/png/resource_saver_png.cpp
core/io/image.h
core/io/image.cpp
```

**Pipeline** (`C:\Zlendo2026\4k_PT_Engine_dev\godot_project`, no rebuild)

```
render.gd
```

**Tooling**

```
pipeline_references/compare_render_encoding.py
```
