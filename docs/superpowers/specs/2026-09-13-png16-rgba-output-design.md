# 16-bit RGBA PNG output — design

**Date:** 2026-09-13
**Scope:** pipeline only (`pipeline_references/render.gd`). No engine change.

## Goal

The production still is written as a 16-bit **RGBA** PNG with the same
channel layout as Blender's default still output, instead of the 16-bit RGB
PNG written today.

## What Blender actually does (read from source, not remembered)

- The output image format defaults to RGBA planes, so `format_png.cc`
  writes `PNG_COLOR_TYPE_RGB_ALPHA` regardless of scene content.
- The alpha value comes from Cycles' film transparency
  (`kernel/film/light_passes.h::film_write_transparent`, driven by
  `PATH_RAY_TRANSPARENT_BACKGROUND`), and that machinery runs **only when
  Film → Transparent is on**. With it off — how `blender_renders/
  blender_dining.png` was rendered — alpha is never written and the channel
  is 1.0 at every pixel (measured: one distinct value, 255, across all
  8,294,400 pixels).
- Compression is `int(compress% / 11.1111)` → level 0 for that file. Ours is
  level 0 too (`PNG16_COMPRESSION = 0`). The size difference (63.3 vs
  47.5 MB) is exactly the fourth channel: 66,357,360 / 49,768,560 = 4/3.

The alpha channel is a post-shading coverage mask for compositing. It has
no effect on how glass or anything else is rendered; the user chose this
scope with that stated.

## Design

### Constant

Next to `PNG16_COMPRESSION` in `render.gd`:

```gdscript
const PNG16_WRITE_ALPHA: bool = true
```

with a comment that records the three facts above (Blender's default
layout; alpha is 1.0 because film transparency is off; +16.6 MB per 4K
file and no effect on shading).

### Save path

In the still-image save block, immediately before the `save_png16` call:

```gdscript
if PNG16_WRITE_ALPHA and img.get_format() == Image.FORMAT_RGBH:
    img.convert(Image.FORMAT_RGBAH)
```

`Image::convert` RGBH → RGBAH takes the fast path
(`core/io/image.cpp:738`) and fills the new channel with half-float 1.0
(`0x3C00`). The engine writer (`drivers/png/png_driver_common.cpp:277`)
derives `has_alpha` from the format and emits `PNG_COLOR_TYPE_RGB_ALPHA`
at bit depth 16; alpha is never sRGB-encoded there (`c < 3` guard). No
engine edit is needed.

The gate is `== FORMAT_RGBH` rather than "has no alpha" on purpose: the
production readback is always RGBH, and any other format reaching this
line means something upstream changed and the writer should see it as-is
rather than be silently widened.

### Log line

`"[Render] Wrote 16-bit RGB PNG ..."` becomes
`"[Render] Wrote 16-bit %s PNG ..." % ("RGBA" if <image has alpha> else "RGB")`,
so the job log states the file layout.

### Unchanged

- The 8-bit fallback (`_linear_image_to_srgb8` → `save_png`) is untouched;
  it does not run on the production route.
- `PNG16_COMPRESSION` stays 0.
- No `tEXt`/`eXIf`/`pHYs` chunks (Blender writes render-time metadata;
  possible follow-up, not part of this).
- No Film-Transparent behaviour (explicitly not chosen).

## Verification

From a scratch copy of the live project on the current `bin/` build,
render `replay192_fishtank` at FHD twice: flag off, flag on.

1. Flag-on PNG: IHDR `bitdepth=16 colortype=6`; IDAT total equals
   `1080 × (1 + 1920 × 4 × 2)` bytes within libpng's per-block overhead
   (stored, level 0); alpha channel has one distinct value, 65535.
2. Flag-off PNG: `colortype=2`, as today.
3. RGB planes of the two files are **byte-identical**. The 2026-09-11+
   build is bit-deterministic for stills (memory
   `pt-render-is-nondeterministic`), so any RGB difference means the
   change touched more than the fourth channel and is a failure.
4. Expected 4K production size after the change: 66,357,360 raw pixel
   bytes → ≈ 63.3 MiB file, matching Blender's.

## Delivery

`pipeline_references/render.gd` only — the user's file; edited in the
reference copy, left uncommitted, carried to the live project by the user.
The spec and plan are committed.
