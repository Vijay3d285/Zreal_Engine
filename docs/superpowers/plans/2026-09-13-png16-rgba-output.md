# 16-bit RGBA PNG Output Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The production still is written as a 16-bit RGBA PNG (Blender's default channel layout) instead of 16-bit RGB, with the RGB bytes unchanged.

**Architecture:** Pipeline-only. `render.gd` widens the HDR viewport readback from `FORMAT_RGBH` to `FORMAT_RGBAH` before calling the engine's existing `save_png16`; Godot's converter fills the new channel with 1.0 and the engine writer already picks `PNG_COLOR_TYPE_RGB_ALPHA` from the image format. No engine code changes, no rebuild.

**Tech Stack:** GDScript (`pipeline_references/render.gd`), Godot `Image` API, existing libpng writer (`drivers/png/png_driver_common.cpp::image_to_png16`), Python + Pillow for verification.

## Global Constraints

- `pipeline_references/render.gd` is the user's file: edit it in the reference copy only, **do not commit it**, do not touch `C:\Zlendo2026\ZlenderRender_stage_copy\` (read-only). The user carries it to the live project.
- `git add` with explicit paths only — never `-A`, `.`, or `commit -a`.
- The reference `render.gd` is LF (0 CRLF, 1254 LF); keep it LF.
- `PNG16_COMPRESSION` stays `0`. The 8-bit fallback path is not modified.
- Render outputs go to the scratchpad, never into the live `output_renders`.
- Commit messages end with `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.

---

### Task 1: The pipeline change

**Files:**
- Modify: `pipeline_references/render.gd:12-15` (constant) and `:519-523` (save block)

**Interfaces:**
- Consumes: `Image.save_png16(path: String, compression: int, srgb_encode: bool) -> Error` (engine, `core/io/image.cpp:2800`); `Image.convert(Image.FORMAT_RGBAH)` (engine, fast path `core/io/image.cpp:738`, alpha = half 1.0).
- Produces: `const PNG16_WRITE_ALPHA: bool` in `render.gd`, read only by the save block.

- [ ] **Step 1: Add the constant after `PNG16_COMPRESSION`**

Replace lines 12–15 of `pipeline_references/render.gd`:

```gdscript
# zlib deflate level for the 16-bit still PNG. 0 = "store", which is what Blender's
# "Compression 0%" writes. 16-bit data barely compresses at any level anyway (the low
# byte of each channel is near-random), so the levels above cost time and save little.
const PNG16_COMPRESSION: int = 0
```

with:

```gdscript
# zlib deflate level for the 16-bit still PNG. 0 = "store", which is what Blender's
# "Compression 0%" writes. 16-bit data barely compresses at any level anyway (the low
# byte of each channel is near-random), so the levels above cost time and save little.
const PNG16_COMPRESSION: int = 0
# Write the still as RGBA rather than RGB, matching Blender's default PNG layout
# (its output format defaults to RGBA planes, so format_png.cc always emits
# PNG_COLOR_TYPE_RGB_ALPHA). Three things to know before reading anything into it:
#   1. The alpha is 1.0 at every pixel. Blender's alpha is Cycles' film
#      transparency (film_write_transparent, PATH_RAY_TRANSPARENT_BACKGROUND),
#      which only runs with Film > Transparent on. A Blender still rendered with
#      it off -- blender_renders/blender_dining.png -- measures one distinct
#      alpha value across all 8.3 M pixels. Ours has no film-transparent mode,
#      so ours is the same constant channel.
#   2. It costs 16.6 MB per 4K file (66.4 MB vs 49.8 MB, both stored at level 0);
#      the entire size difference to Blender's file is this fourth channel.
#   3. It changes no RGB byte. The channel is added after shading, by
#      Image.convert(FORMAT_RGBAH), and the engine writer never sRGB-encodes it.
#      It has no effect on how glass or anything else renders.
# It exists for parity with Blender's file layout and for downstream tools that
# expect four channels. See docs/superpowers/specs/2026-09-13-png16-rgba-output-design.md.
const PNG16_WRITE_ALPHA: bool = true
```

- [ ] **Step 2: Widen the image before `save_png16` and report the layout**

Replace lines 519–523 (now shifted by the 17 lines added above, so ~536–540):

```gdscript
	if get_viewport().use_hdr_2d and img.has_method("save_png16"):
		_save_err = img.call("save_png16", output_path, PNG16_COMPRESSION, true)
		_used_16bit = (_save_err == OK)
		if _used_16bit:
			print("[Render] Wrote 16-bit RGB PNG (zlib level %d, sRGB-encoded from the linear HDR buffer)." % PNG16_COMPRESSION)
```

with:

```gdscript
	if get_viewport().use_hdr_2d and img.has_method("save_png16"):
		# The HDR readback is FORMAT_RGBH. Widening it to RGBAH makes the engine
		# writer emit PNG_COLOR_TYPE_RGB_ALPHA (it derives has_alpha from the
		# format); Godot's RGBH->RGBAH convert fills the new channel with 1.0.
		# Gated on == RGBH, not "lacks alpha": any other format here means the
		# readback changed upstream, and the writer should see it unmodified.
		if PNG16_WRITE_ALPHA and img.get_format() == Image.FORMAT_RGBH:
			img.convert(Image.FORMAT_RGBAH)
		var _png_layout := "RGBA" if img.get_format() == Image.FORMAT_RGBAH else "RGB"
		_save_err = img.call("save_png16", output_path, PNG16_COMPRESSION, true)
		_used_16bit = (_save_err == OK)
		if _used_16bit:
			print("[Render] Wrote 16-bit %s PNG (zlib level %d, sRGB-encoded from the linear HDR buffer)." % [_png_layout, PNG16_COMPRESSION])
```

- [ ] **Step 3: Confirm the file is still LF and parses**

```bash
python -c "b=open('pipeline_references/render.gd','rb').read(); print('crlf', b.count(b'\r\n')); assert b.count(b'\r\n')==0"
```

Expected: `crlf 0`. Then a syntax check with the engine (headless, script-only):

```bash
./bin/godot.windows.editor.x86_64.console.exe --headless --path pipeline_references --check-only -s render.gd 2>&1 | tail -5
```

Expected: no `SCRIPT ERROR` / `Parse Error` lines. (If `--check-only` is unsupported by this build, Task 2's render is the parse check.)

- [ ] **Step 4: Do not commit**

`pipeline_references/render.gd` is the user's file. Leave it modified in the working tree.

---

### Task 2: Verification renders — flag on vs flag off

**Files:**
- Create (scratch): `<scratchpad>/rgba/proj_on/`, `<scratchpad>/rgba/proj_off/` — thin copies of the live project (`*.gd`, `*.tscn`, `project.godot`, `day.exr`, `night.exr`, `tests/`, and `input_json/replay192_fhd.json` with `render_quality` set to `"FHD"`).
- Create (scratch): `<scratchpad>/rgba/check_png.py`

**Interfaces:**
- Consumes: the `render.gd` from Task 1 (copied into both scratch projects, with `PNG16_WRITE_ALPHA` flipped to `false` in `proj_off`).

- [ ] **Step 1: Build the two scratch projects**

```bash
S="$CLAUDE_SCRATCHPAD/rgba"; L=/c/Zlendo2026/ZlenderRender_stage_copy/godot_project
REF=/c/Users/aiadmin/Desktop/Engine_Build_test/Zreal_Engine/pipeline_references
for v in on off; do
  D="$S/proj_$v"; rm -rf "$D"; mkdir -p "$D/input_json" "$D/logs"
  cp "$L"/*.gd "$L"/*.tscn "$L"/project.godot "$L"/day.exr "$L"/night.exr "$D"/
  cp -r "$L/tests" "$D"/ 2>/dev/null
  cp "$REF/render.gd" "$D/render.gd"            # Task 1's file
done
python - <<'EOF'
import json,os
S=os.environ["CLAUDE_SCRATCHPAD"]+"/rgba"
d=json.load(open("/c/Zlendo2026/ZlenderRender_stage_copy/godot_project/input_json/replay192_fishtank_input.json".replace("/c/","C:/")))
d["render_quality"]="FHD"
for v in ("on","off"):
    json.dump(d,open(S+"/proj_%s/input_json/replay192_fhd.json"%v,"w"))
p=S+"/proj_off/render.gd"; s=open(p,"rb").read()
old=b"const PNG16_WRITE_ALPHA: bool = true"; assert s.count(old)==1
open(p,"wb").write(s.replace(old,b"const PNG16_WRITE_ALPHA: bool = false"))
print("ok")
EOF
```

Note: the live `image_glb_creation.gd` currently has `PT_SPP_DAY := 4`; both scratch copies get the same file, so the two renders are comparable regardless.

- [ ] **Step 2: Render both, sequentially (single GPU)**

```bash
S="$CLAUDE_SCRATCHPAD/rgba"
EXE=/c/Users/aiadmin/Desktop/Engine_Build_test/Zreal_Engine/bin/godot.windows.editor.x86_64.console.exe
for v in on off; do
  "$EXE" --rendering-driver vulkan --path "$S/proj_$v" res://main.tscn -- "$S/proj_$v/input_json/replay192_fhd.json" "$S/out_$v.png" > "$S/out_${v}_godot.log" 2>&1
  echo "$v exit=$?"; sleep 5
done
grep -h "Wrote 16-bit" "$S"/out_on_godot.log "$S"/out_off_godot.log
```

Expected: both `exit=0`; log lines `Wrote 16-bit RGBA PNG` (on) and `Wrote 16-bit RGB PNG` (off).

- [ ] **Step 3: Write the checker**

`<scratchpad>/rgba/check_png.py`:

```python
import struct, sys
import numpy as np
from PIL import Image
Image.MAX_IMAGE_PIXELS = None

def header(p):
    b = open(p, "rb").read()
    assert b[:8] == b"\x89PNG\r\n\x1a\n"
    off = 8; idat = 0
    while off < len(b):
        ln, typ = struct.unpack(">I4s", b[off:off + 8])
        if typ == b"IHDR":
            w, h, bd, ct = struct.unpack(">IIBB", b[off + 8:off + 18])
        if typ == b"IDAT":
            idat += ln
        off += 12 + ln
    return w, h, bd, ct, idat, len(b)

on, off = sys.argv[1], sys.argv[2]
w, h, bd, ct, idat, size = header(on)
raw_rgba = h * (1 + w * 4 * 2)
print("on : %dx%d bitdepth=%d colortype=%d size=%d IDAT=%d raw=%d ratio=%.4f" % (w, h, bd, ct, size, idat, raw_rgba, idat / raw_rgba))
assert (bd, ct) == (16, 6), "flag-on file is not 16-bit RGBA"
assert 1.0 <= idat / raw_rgba < 1.001, "flag-on file is not stored (level 0) RGBA"

w2, h2, bd2, ct2, idat2, size2 = header(off)
print("off: %dx%d bitdepth=%d colortype=%d size=%d" % (w2, h2, bd2, ct2, size2))
assert (bd2, ct2) == (16, 2), "flag-off file is not 16-bit RGB"

a = np.asarray(Image.open(on))
b = np.asarray(Image.open(off))
alpha = a[..., 3]
print("alpha: distinct=%d min=%d max=%d" % (len(np.unique(alpha)), alpha.min(), alpha.max()))
assert alpha.min() == alpha.max() == np.iinfo(alpha.dtype).max, "alpha is not constant 1.0"
diff = int((a[..., :3] != b).sum())
print("RGB planes differing samples: %d" % diff)
assert diff == 0, "RGB changed between flag on and off"
print("PASS")
```

- [ ] **Step 4: Run the checker**

```bash
python "$CLAUDE_SCRATCHPAD/rgba/check_png.py" "$CLAUDE_SCRATCHPAD/rgba/out_on.png" "$CLAUDE_SCRATCHPAD/rgba/out_off.png"
```

Expected:
```
on : 1920x1080 bitdepth=16 colortype=6 size=~16.6M IDAT=... raw=16590960 ratio=1.000x
off: 1920x1080 bitdepth=16 colortype=2 size=12462849
alpha: distinct=1 min=65535 max=65535
RGB planes differing samples: 0
PASS
```

(Pillow may open 16-bit RGBA as `I;16` per channel or as 8-bit RGBA; if the alpha dtype is `uint8` the max is 255 — the `np.iinfo` assertion handles both.)

If `RGB planes differing samples` is non-zero: stop. The build is deterministic for stills (memory `pt-render-is-nondeterministic`, 2026-09-11 build), so a difference means Task 1 changed something other than the fourth channel. Diff the two `render.gd` files first (they must differ by the one constant only), then re-render the same variant twice to re-measure the determinism floor before touching the code.

- [ ] **Step 5: Record the result in the spec and commit the plan + spec**

Append to `docs/superpowers/specs/2026-09-13-png16-rgba-output-design.md` under a new `## Result` heading: the two file sizes, `alpha distinct=1`, `RGB differing samples: 0`, and the expected 4K size (66,357,360 raw → ≈63.3 MiB).

```bash
git add docs/superpowers/specs/2026-09-13-png16-rgba-output-design.md docs/superpowers/plans/2026-09-13-png16-rgba-output.md
git commit -m "docs(pipeline): 16-bit RGBA PNG output -- plan and measured result

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

`pipeline_references/render.gd` stays uncommitted (user's file).

- [ ] **Step 6: Clean up the scratch projects**

```bash
rm -rf "$CLAUDE_SCRATCHPAD/rgba/proj_on" "$CLAUDE_SCRATCHPAD/rgba/proj_off"
```

Keep `out_on.png` / `out_off.png` / logs until the user has seen the result.

---

## Self-review

- **Spec coverage:** constant (Task 1 Step 1), convert-before-save gated on `== FORMAT_RGBH` (Task 1 Step 2), log line reports layout (Task 1 Step 2), 8-bit fallback untouched (constraint), verification items 1–4 of the spec (Task 2 Steps 3–4), delivery rule (Task 1 Step 4, Task 2 Step 5). No gaps.
- **Placeholders:** none; every code step is complete.
- **Type consistency:** `PNG16_WRITE_ALPHA: bool` in Task 1 is the same symbol Task 2 flips; `_png_layout` is local to the save block.
