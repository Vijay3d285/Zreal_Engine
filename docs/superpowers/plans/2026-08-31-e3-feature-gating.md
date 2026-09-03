# E3 Feature Gating Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** compile out anisotropy, coat and sheen when the scene provably does not use them, recovering the measured +273s (+42.7%) path-tracer regression with bit-identical output.

**Architecture:** three new `RT_FLAGS` bits drive `#define` injection through `RAYGEN_SHADER_OPTIONS`, so the GLSL guards are real preprocessor `#ifdef`s that remove struct fields and shrink `LOBE_COUNT`. `build_tlas` splits into a detect pass (walk instances, OR each material's feature bits) and a build pass (everything else, with settled flags), because flags are needed before materials are known.

**Tech Stack:** C++17, GLSL (Vulkan RD raytracing), SCons, doctest.

## Global Constraints

- **NEVER stage, commit, revert, checkout over, or stash anything under `pipeline_references/`.** Six `.gd` files there are the user's uncommitted work, plus untracked `custom_shape.gd`. Every `git add` uses **explicit paths only** — never `-A`, never `.`.
- Build: `python -m SCons platform=windows target=editor tests=yes -j8`. Bare `scons` is NOT on PATH. A `.glsl` edit requires a full scons run so the `.glsl.gen.h` files regenerate.
- Never hand-edit any `*.glsl.gen.h`.
- C++ `RT_FLAG_*` values and their GLSL `#define` twins are hand-mirrored and must agree.
- Enabled behaviour must be **bit-identical** to today. Every acceptance criterion is a rendered image comparison, not an assertion.
- Commit incrementally — at minimum at each task's final step.

## Reference artefacts

The roadmap §7.12 investigation produced the comparison set:

| Artefact | What it is | Loop time |
|---|---|---|
| `BASE.png` | `28bb89cad` render of the production scene | 639s |
| `P0c.png` | HEAD render, same input, `tests=yes` | 912s |

`P0c.png` was verified byte-identical to the production output at
`C:\Zlendo2026\ZlenderRender_stage_copy\output_renders\urbantestdark168_llm_render.png`,
so **the HEAD reference can always be recovered from there** even if the session
scratchpad holding `P0c.png` is gone. `BASE.png` needs the worktree (Task 5 Step 4).

**Render harness** — used for every measurement in this plan:

```bash
IN="C:/Users/aiadmin/AppData/Local/Temp/2/zrealty_backend_runtime/urbantestdark168_llm_godot_input.json"
PROJ="C:/Zlendo2026/ZlenderRender_stage_copy/godot_project"
./bin/godot.windows.editor.x86_64.console.exe --path "$PROJ" res://main.tscn -- "$IN" /tmp/out.png
```

Never write outputs into `C:\Zlendo2026\ZlenderRender_stage_copy\` — that tree is
read-only for this work. A full render is ~15 minutes; run it in the background.

**Image comparison** — the acceptance instrument:

```bash
python -c "
from PIL import Image
import numpy as np
a=np.asarray(Image.open(r'REF.png').convert('RGB'),dtype=float)
b=np.asarray(Image.open(r'NEW.png').convert('RGB'),dtype=float)
d=a-b
print('rmse=%.6f maxabs=%.1f pct=%.4f%%'%((d**2).mean()**0.5,abs(d).max(),100.0*(abs(d).sum(axis=2)>0).mean()))
"
```

**Loop timing** — startup and the 128-frame loop must be separated, because the
regression lives entirely in the loop (79s vs 78s startup across all six §7.12
renders). Timestamp the `Driving 128 frames` line in the log and subtract.

---

### Task 1: Flag bits, defines and variant entries — all three forced ON

**Files:**
- Modify: `servers/rendering/renderer_rd/forward_clustered/scene_shader_raytracing.h:76-133`
- Modify: `servers/rendering/renderer_rd/forward_clustered/scene_shader_raytracing.cpp:63-66`, `:641`
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_common_inc.glsl:45`

**Interfaces:**
- Consumes: nothing.
- Produces: `SceneShaderRaytracing::RT_FLAG_ANISOTROPY_ENABLED` / `RT_FLAG_COAT_ENABLED` / `RT_FLAG_SHEEN_ENABLED` (C++ enum members, `uint32_t` values 1<<15, 1<<16, 1<<17), and the GLSL preprocessor symbols `RT_ANISOTROPY_ENABLED` / `RT_COAT_ENABLED` / `RT_SHEEN_ENABLED`, injected into the raygen preamble whenever the matching flag is set.

**Read this first.** Bits 11-14 are **taken** by `RT_MAX_TRANSMISSION_BOUNCE` (E1,
`scene_shader_raytracing.h:115`). The documented free range is bits 15-19. An
earlier spec draft placed these flags at 11-13; that was wrong and was corrected.
Use 15, 16, 17 and do not re-derive them.

This task must render **bit-identical to HEAD**: all three flags are forced on and
no GLSL consumes the defines yet.

- [ ] **Step 1: Add the three enum members**

In `scene_shader_raytracing.h`, in `enum RaytracingFlags` after `RT_FLAG_TRANSMISSION_ENABLED`:

```cpp
		// E3. Bits 15-17, from the free range documented above. NOT 11-14 --
		// those are RT_MAX_TRANSMISSION_BOUNCE (E1), and the collision would
		// corrupt that field's readback while leaving the render merely
		// plausible instead of visibly wrong.
		RT_FLAG_ANISOTROPY_ENABLED = (1 << 15),
		RT_FLAG_COAT_ENABLED = (1 << 16),
		RT_FLAG_SHEEN_ENABLED = (1 << 17),
```

- [ ] **Step 2: Update the bit-layout comment**

At `scene_shader_raytracing.h:76`, replace `// Bits 15-19: Free` with:

```
	// Bits 15-17: Material feature gating (roadmap E3: anisotropy, coat, sheen)
	// Bits 18-19: Free
```

- [ ] **Step 3: Extend both static_asserts**

Add the three names to the first assert's OR-chain:

```cpp
	static_assert(((RT_FLAG_DEBUG_VIS_ENABLED | RT_FLAG_DLSS_RR_ENABLED | RT_FLAG_FOG_ENABLED | RT_FLAG_SER_ENABLED | RT_FLAG_EMISSIVE_LIGHTS_ENABLED | RT_FLAG_TRANSMISSION_ENABLED | RT_FLAG_ANISOTROPY_ENABLED | RT_FLAG_COAT_ENABLED | RT_FLAG_SHEEN_ENABLED) & (RT_MIN_BOUNCE_MASK << RT_MIN_BOUNCE_SHIFT)) == 0,
			"RT_FLAG_* bit overlaps the Russian Roulette min_bounce field (bits 4-8)");
```

and to the second, so any future bit colliding with the transmission cap is caught:

```cpp
	static_assert(((RT_MAX_TRANSMISSION_BOUNCE_MASK << RT_MAX_TRANSMISSION_BOUNCE_SHIFT) &
						  ((RT_MIN_BOUNCE_MASK << RT_MIN_BOUNCE_SHIFT) |
								  (RT_SAMPLE_COUNT_MASK << RT_SAMPLE_COUNT_SHIFT) |
								  (RT_MAX_BOUNCES_MASK << RT_MAX_BOUNCES_SHIFT) |
								  RT_FLAG_EMISSIVE_LIGHTS_ENABLED |
								  RT_FLAG_TRANSMISSION_ENABLED |
								  RT_FLAG_ANISOTROPY_ENABLED |
								  RT_FLAG_COAT_ENABLED |
								  RT_FLAG_SHEEN_ENABLED)) == 0,
			"RT_MAX_TRANSMISSION_BOUNCE field (bits 11-14) overlaps another RT_FLAGS field");
```

- [ ] **Step 4: PROVE THE ASSERT IS LIVE**

Not optional. Temporarily set `RT_FLAG_ANISOTROPY_ENABLED = (1 << 11)` and build.

Expected: **the second static_assert fires**, naming the transmission field.

Then restore `(1 << 15)` and rebuild clean. If it does not fire, the assert is not
guarding what it claims — fix the assert and say so plainly rather than proceeding.

- [ ] **Step 5: Add the GLSL flag twins**

In `raytracing_common_inc.glsl`, after the transmission block at `:45`:

```glsl
// E3. Bits 15-17. MUST match RT_FLAG_ANISOTROPY_ENABLED / RT_FLAG_COAT_ENABLED /
// RT_FLAG_SHEEN_ENABLED in scene_shader_raytracing.h. These bits ALSO drive
// #define injection via RAYGEN_SHADER_OPTIONS, and that is what the gating
// actually uses: the accessors below are diagnostics only. A specialization
// constant can fold a branch but cannot remove a struct field or size an array,
// which is what this phase needs -- see the spec's section 3.1.
#define RT_FLAG_ANISOTROPY_ENABLED 32768u // 1 << 15
#define RT_FLAG_COAT_ENABLED 65536u // 1 << 16
#define RT_FLAG_SHEEN_ENABLED 131072u // 1 << 17
#define RT_GET_ANISOTROPY_ENABLED() ((RT_FLAGS & RT_FLAG_ANISOTROPY_ENABLED) != 0u)
#define RT_GET_COAT_ENABLED() ((RT_FLAGS & RT_FLAG_COAT_ENABLED) != 0u)
#define RT_GET_SHEEN_ENABLED() ((RT_FLAGS & RT_FLAG_SHEEN_ENABLED) != 0u)
```

- [ ] **Step 6: Register the define-injection entries**

In `scene_shader_raytracing.cpp`, extend `RAYGEN_SHADER_OPTIONS`:

```cpp
static constexpr RaygenShaderOption RAYGEN_SHADER_OPTIONS[] = {
	{ SceneShaderRaytracing::RT_FLAG_DLSS_RR_ENABLED, "#define DLSS_RR_ENABLED\n" },
	{ SceneShaderRaytracing::RT_FLAG_SER_ENABLED, "#define USE_SER\n" },
	// E3. This array is 2^N in its entry count (see the comment above it): five
	// entries is 32 reachable raygen permutations, up from four. Variants compile
	// lazily and one render requests one, so the growth is latent -- but each new
	// combination pays a first-use compile.
	{ SceneShaderRaytracing::RT_FLAG_ANISOTROPY_ENABLED, "#define RT_ANISOTROPY_ENABLED\n" },
	{ SceneShaderRaytracing::RT_FLAG_COAT_ENABLED, "#define RT_COAT_ENABLED\n" },
	{ SceneShaderRaytracing::RT_FLAG_SHEEN_ENABLED, "#define RT_SHEEN_ENABLED\n" },
};
```

- [ ] **Step 7: Force all three ON in compute_rt_flags**

At the end of `compute_rt_flags` (`scene_shader_raytracing.cpp:641`), before its return:

```cpp
	// E3 Task 1: unconditionally ON. Detection lands in Task 3 and starts driving
	// these in Task 4. Until then this is a no-op that must render bit-identically
	// -- which is exactly what makes Tasks 1 and 2 independently verifiable.
	flags |= RT_FLAG_ANISOTROPY_ENABLED | RT_FLAG_COAT_ENABLED | RT_FLAG_SHEEN_ENABLED;
```

- [ ] **Step 8: Build**

Run: `python -m SCons platform=windows target=editor tests=yes -j8`
Expected: exit 0.

- [ ] **Step 9: Render and prove bit-identity**

Render with the harness to `e3_task1.png`; compare against the HEAD reference.

Expected: `rmse=0.000000 maxabs=0.0 pct=0.0000%`.

Any nonzero difference means the flags changed behaviour, which they must not.
Stop and find out why.

- [ ] **Step 10: Commit**

```bash
git add servers/rendering/renderer_rd/forward_clustered/scene_shader_raytracing.h servers/rendering/renderer_rd/forward_clustered/scene_shader_raytracing.cpp servers/rendering/renderer_rd/shaders/raytracing/raytracing_common_inc.glsl
git commit -m "feat(pt): E3 flag bits 15-17 and define injection, forced on"
```

---

### Task 2: GLSL gating under #ifdef — still forced ON

**Files:**
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/brdf_inc.glsl` — `BrdfData` (`:380-390`), `LOBE_COUNT` (`:1791-1802`), signatures (`:1226`, `:1283`, `:1366`, `:1485`), `prepareBRDFData` (`:1721-1750`), aniso consumers (`:1232`, `:1269`, `:1374`, `:1421`, `:1442`, `:1561`, `:2913`, `:3198`), `layerTransmittanceAbove` (`:2691`), `combinedPdf` (`:2995-3016`), `evalCombinedBRDFSeparate` (`:3119-3132`), sampler arms (`:3192-3262`)
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl` — vis mode 40 (`:1130-1145`), lobe weights and branches (`:1844-1886`), layer block (`:1912`)

**Interfaces:**
- Consumes: `RT_ANISOTROPY_ENABLED`, `RT_COAT_ENABLED`, `RT_SHEEN_ENABLED` from Task 1.
- Produces: GLSL that compiles and renders correctly in all four coat/sheen combinations and both anisotropy states.

**Read this first.** The roadmap §7.12 perf probes performed this exact edit and
proved it works: `RT_PERF_NO_LAYERS` guarded these coat/sheen sites and rendered
correctly (825s loop), and `RT_PERF_NO_REGISTRY` proved a scalar 2-lobe form is
**pixel-identical** to the array form (rmse 0.000000). Those probes were reverted
and never committed, so work from the site list above rather than looking for them
in history.

**The polarity is inverted from those probes.** They were `#if RT_PERF_NO_LAYERS`
(remove when set); these are `#ifndef RT_COAT_ENABLED` (remove when NOT set).
Getting this backwards compiles cleanly and disables each feature in exactly the
scenes that need it.

- [ ] **Step 1: Gate the anisotropy state out of BrdfData**

```glsl
#ifdef RT_ANISOTROPY_ENABLED
	float ax;
	float ay;
	float anisoPhi;
	bool anisoActive;
#endif
```

Then guard the producer (`prepareBRDFData:1721-1750`) and every consumer. At each
consumer the `#ifndef` arm takes **the existing isotropic path unchanged** — that
path already exists at all eight sites, which is why this is a removal, not a
rewrite.

The four signatures that thread the state drop those parameters under `#ifndef`:

```glsl
float3 sampleMicrofacetDirection(float3 Vlocal, float alpha, float alphaSquared,
#ifdef RT_ANISOTROPY_ENABLED
		float ax, float ay, float anisoPhi, bool anisoActive,
#endif
		float2 u, OUT_PARAMETER(float) outHdotL, OUT_PARAMETER(float) outNdotV, OUT_PARAMETER(float) outWeightRatio) {
```

and their call sites drop the matching arguments the same way.

**This is the change the 108s is charged to.** §7.12 established that every
material in the production scene has `anisotropy == 0`, so `anisoActive` is
already false and the anisotropic branches already never execute — yet E2b still
costs 108s. The cost is the widened struct and the occupancy that follows.
Skipping the maths while leaving the parameters in place will recover nothing.

- [ ] **Step 2: Gate LOBE_COUNT and the lobe indices**

```glsl
#if defined(RT_COAT_ENABLED) && defined(RT_SHEEN_ENABLED)
#define LOBE_COUNT 4
#elif defined(RT_COAT_ENABLED) || defined(RT_SHEEN_ENABLED)
#define LOBE_COUNT 3
#else
#define LOBE_COUNT 2
#endif

#ifdef RT_COAT_ENABLED
#define LOBE_COAT 2
#endif
#ifdef RT_SHEEN_ENABLED
#ifdef RT_COAT_ENABLED
#define LOBE_SHEEN 3
#else
#define LOBE_SHEEN 2
#endif
#endif
```

`LOBE_SPECULAR 0` and `LOBE_DIFFUSE 1` stay fixed. Sheen must slide to index 2
when coat is absent, or the array is over-indexed.

**This disturbs E2e's index-order coincidence.** `layerTransmittanceAbove` relies
on registry index order matching Cycles' layer order, via `lobeIndex < LOBE_SHEEN`
and `lobeIndex < LOBE_COAT`. Read that function and confirm each surviving
comparison still selects the right lobes in all four combinations. Do not assume
it — E2e's own comment calls the ordering a coincidence, and this change is
exactly what can break a coincidence.

- [ ] **Step 3: Guard the remaining coat/sheen sites**

Under `#ifdef RT_COAT_ENABLED` / `#ifdef RT_SHEEN_ENABLED` as appropriate: the
`weights[]` and `pdfs[]` assignments in `combinedPdf` and in `shade_and_bounce`;
the `sheenSetup` pdf block; the `evalCoat`/`evalSheen` block in
`evalCombinedBRDFSeparate`; the `COAT_TYPE` and `SHEEN_TYPE` sampler arms; the
lobe branches in `shade_and_bounce`; the `layerTransmittanceAbove` body; and the
vis-mode-40 debug block, which must still compile at `LOBE_COUNT` 2.

- [ ] **Step 4: Build and render all four coat/sheen combinations**

The force in Task 1 Step 7 builds only the all-on variant. To exercise the others,
temporarily edit that line to force each combination in turn — all-on, coat-only,
sheen-only, neither — rebuilding each time.

Expected: all four build with exit 0.

**A GLSL compile error surfaces at pipeline creation, not at scons time**, so run a
render for each combination too: a variant that fails to compile renders black or
crashes. Record all four outcomes.

Restore the unconditional all-on force before the next step.

- [ ] **Step 5: Render and prove bit-identity**

With all three forced on, render `e3_task2.png` and compare against the HEAD reference.

Expected: `rmse=0.000000 maxabs=0.0`.

This is the load-bearing check of the whole plan — it proves the `#ifdef`
restructuring changed no maths on the enabled path.

- [ ] **Step 6: Commit**

```bash
git add servers/rendering/renderer_rd/shaders/raytracing/brdf_inc.glsl servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl
git commit -m "feat(pt): E3 GLSL gating under ifdef, features still forced on"
```

---

### Task 3: CPU-side feature detection — computed and logged, not yet driving

**Files:**
- Modify: `servers/rendering/renderer_rd/forward_clustered/render_raytracing.h:265-276` (`RTMaterialData`)
- Modify: `servers/rendering/renderer_rd/forward_clustered/render_raytracing.cpp:1820-1890`

**Interfaces:**
- Consumes: the `RT_FLAG_*` enum members from Task 1.
- Produces: `RTMaterialData::feature_bits` — a `uint32_t` OR of the three `RT_FLAG_*` values, populated for every material `process_material()` returns.

**Read this first.** Each predicate must match its GLSL twin exactly. If they
drift, a feature is silently compiled out of a scene that uses it, and only the
bit-identity acceptance render catches it. In particular, **verify how
`mat.clearcoat` maps to the shader's `material.coatWeight`** before writing the
coat predicate — if any scaling sits between them, the threshold must be applied
on the same side of it.

- [ ] **Step 1: Add the field**

In `render_raytracing.h`, in `RTMaterialData`:

```cpp
	// E3. OR of RT_FLAG_ANISOTROPY_ENABLED / _COAT_ / _SHEEN_ for this material.
	// The predicates that set it mirror the shader's own guards -- see the fill
	// site in render_raytracing.cpp. Drift between the two silently compiles a
	// feature out of a scene that uses it.
	uint32_t feature_bits = 0;
```

- [ ] **Step 2: Populate it**

After `mat.anisotropy` is read (`render_raytracing.cpp:1875-1885`):

```cpp
	// E3 detection. Each predicate mirrors the shader guard cited beside it.
	mat_data->feature_bits = 0;
	if (mat.anisotropy != 0.0f) {
		// brdf_inc.glsl:1728, prepareBRDFData's anisoActive gate.
		mat_data->feature_bits |= SceneShaderRaytracing::RT_FLAG_ANISOTROPY_ENABLED;
	}
	if (mat.clearcoat > 0.00001f) {
		// brdf_inc.glsl:3119 hasCoat, raytracing_closest_hit_common_inc.glsl:1912.
		mat_data->feature_bits |= SceneShaderRaytracing::RT_FLAG_COAT_ENABLED;
	}
	if (MAX(mat.sheen_color[0], MAX(mat.sheen_color[1], mat.sheen_color[2])) > 0.00001f) {
		// brdf_inc.glsl:2545 sheenMaxTint.
		mat_data->feature_bits |= SceneShaderRaytracing::RT_FLAG_SHEEN_ENABLED;
	}
```

- [ ] **Step 3: Log the accumulated mask once per render**

There is no scene-wide traversal to hang this on yet — the detect pass is Task 4's
deliverable. So accumulate into a member and log it when it changes, which needs
no new traversal and still answers "what does this scene contain".

In `render_raytracing.h`, beside the other `RenderRaytracing` members:

```cpp
	// E3 Task 3 diagnostic, retired in Task 5 Step 6. Monotonic OR across every
	// material processed so far, logged on change.
	uint32_t e3_debug_seen_mask = 0;
```

At the end of the `feature_bits` assignment in Step 2:

```cpp
	if ((e3_debug_seen_mask | mat_data->feature_bits) != e3_debug_seen_mask) {
		e3_debug_seen_mask |= mat_data->feature_bits;
		print_line(vformat("[E3] features seen so far: aniso=%d coat=%d sheen=%d",
				(int)((e3_debug_seen_mask & SceneShaderRaytracing::RT_FLAG_ANISOTROPY_ENABLED) != 0),
				(int)((e3_debug_seen_mask & SceneShaderRaytracing::RT_FLAG_COAT_ENABLED) != 0),
				(int)((e3_debug_seen_mask & SceneShaderRaytracing::RT_FLAG_SHEEN_ENABLED) != 0)));
	}
```

The last `[E3]` line printed is the scene's full mask. Task 4 replaces this with
the real per-frame `scene_mask` from the detect pass.

- [ ] **Step 4: Build, render, read the log**

**Expected for the production scene: `aniso=0 coat=1 sheen=1`.**

§7.12 established that removing coat and sheen changes 6.03% of pixels, so both
are demonstrably present — via glTF-imported materials, not the scene scripts,
whose `ReflectionAssist` and `Photorealism` passes never fire in this job.
Anisotropy is expected absent.

If coat or sheen reports 0, **detection is wrong** — the §7.12 pixel measurement
is ground truth here, not the detector.

- [ ] **Step 5: PROVE DETECTION CAN REPORT THE OTHER ANSWER**

A detector that always returns 1 is not an instrument. Temporarily force
`mat.clearcoat = 0.0f` and all three `mat.sheen_color` channels to 0 immediately
after they are read, rebuild, and re-render.

Expected: the log flips to `coat=0 sheen=0`.

Then restore and confirm it returns to `coat=1 sheen=1`. Record both readings.
If the log cannot be made to say 0, the detector is not reading what you think.

- [ ] **Step 6: Commit**

```bash
git add servers/rendering/renderer_rd/forward_clustered/render_raytracing.h servers/rendering/renderer_rd/forward_clustered/render_raytracing.cpp
git commit -m "feat(pt): E3 per-material feature detection, logged not yet driving"
```

---

### Task 4: Two-pass build_tlas — detection drives the flags

**Files:**
- Modify: `servers/rendering/renderer_rd/forward_clustered/render_raytracing.cpp:2425` (`build_tlas`), `render_raytracing.h` (`RTViewportState` or the `build_tlas` signature)
- Modify: `servers/rendering/renderer_rd/forward_clustered/render_forward_clustered.cpp:2472-2474`, `:2861`, `:2886`
- Modify: `servers/rendering/renderer_rd/forward_clustered/scene_shader_raytracing.cpp:641` (remove the Task 1 force)

**Interfaces:**
- Consumes: `RTMaterialData::feature_bits` from Task 3.
- Produces: `build_tlas` using `final_flags = p_rt_flags | scene_mask` everywhere, and the same value reaching `update_uniform_set`, `get_raytracing_pipeline` and `get_hit_sbt`.

**Read this first — this is the task that can silently corrupt renders.**

`build_tlas` uses `p_rt_flags` for `ensure_pipeline_bundle` (`:2448`) and
`is_hg_ready_in_bundle` (`:2518`, `:2619`, `:2736`). When an instance's hit group
is not ready in the bundle for the flags in hand, the instance is **`continue`d —
dropped from the TLAS entirely** (`:2620`, `:2737`). So every one of those sites
must see the SAME settled flags. If pass 1 registers materials under one value and
pass 2 builds under another, geometry silently vanishes and the 128-frame
accumulation bakes the loss in. It will not look like a crash; it looks like
missing objects.

The one-frame-deferred design was rejected in the spec for precisely this reason.
Do not reintroduce it.

- [ ] **Step 1: Split the traversal**

Before any call to `ensure_pipeline_bundle` or `is_hg_ready_in_bundle`:

```cpp
	// E3 pass 1: detect only. process_material() is idempotent and cached, so
	// calling it here and again in pass 2 costs one hash lookup the second time.
	// NO pipeline, SBT or instance work may happen in this pass -- all of it
	// depends on flags that are not settled until the pass ends.
	uint32_t scene_mask = 0;
	for (/* the same instance/surface walk pass 2 performs */) {
		uint16_t material_counter = material_storage->material_get_rt_invalidation_counter(material_rid);
		RTMaterialData *mat_data = process_material(material_rid, material_counter);
		scene_mask |= mat_data->feature_bits;
	}
	const uint32_t final_flags = p_rt_flags | scene_mask;

	// Replaces Task 3's monotonic e3_debug_seen_mask diagnostic, which should be
	// deleted along with its member in this step. This one is per-frame and is
	// what the Task 5 acceptance steps read.
	print_line(vformat("[E3] scene feature mask: aniso=%d coat=%d sheen=%d",
			(int)((scene_mask & SceneShaderRaytracing::RT_FLAG_ANISOTROPY_ENABLED) != 0),
			(int)((scene_mask & SceneShaderRaytracing::RT_FLAG_COAT_ENABLED) != 0),
			(int)((scene_mask & SceneShaderRaytracing::RT_FLAG_SHEEN_ENABLED) != 0)));
```

Then replace **every** remaining use of `p_rt_flags` in the function with
`final_flags`, and verify:

```bash
grep -n "p_rt_flags" servers/rendering/renderer_rd/forward_clustered/render_raytracing.cpp
```

Expected after the edit: only the parameter declaration and the pass-1 line
mention `p_rt_flags`.

- [ ] **Step 2: Propagate the settled flags to the caller**

`render_forward_clustered.cpp` fetches the pipeline at `:2861` and the hit SBT at
`:2886` using the `rt_flags` it computed, and calls `update_uniform_set` at
`:2474` with it. All three must use the settled value, or the dispatch binds a
different variant than the TLAS was built for.

Return the settled flags from `build_tlas` — or store them on `RTViewportState`
and read them back — and use that at all three sites.

**A mismatch here is the single most dangerous outcome of this task.** Verify by
rendering, not by reading.

- [ ] **Step 3: Remove the Task 1 force**

Delete the `flags |= RT_FLAG_ANISOTROPY_ENABLED | RT_FLAG_COAT_ENABLED | RT_FLAG_SHEEN_ENABLED;`
line from `compute_rt_flags`. Detection now supplies these bits.

- [ ] **Step 4: Build and render the production scene**

Expected log: `[E3] scene feature mask: aniso=0 coat=1 sheen=1`.

Compare `e3_task4.png` against the HEAD reference.

**Expected: `rmse=0.000000 maxabs=0.0`.** Coat and sheen stayed on; anisotropy was
compiled out and the scene does not use it, so the image must not move at all.

A nonzero difference means either detection is wrong or Task 2's anisotropy gating
was not behaviour-neutral. **Do not accept a small rmse as "close enough"** — the
criterion is identity, and this project has previously shipped a mean-preserving
error that every rendered gate passed.

- [ ] **Step 5: Record the loop time**

Time the render; separate startup from the loop using the `Driving 128 frames` line.

Expected: **loop ≈804s**, i.e. 912s − 108s, against HEAD's 912s.

If the loop is still ≈912s, the `#ifdef` did not remove what a hard removal
removes — most likely the parameters were left in the signatures (Task 2 Step 1).
Report the number either way: this is the measurement the phase exists to produce,
and §7.12 warns that spec-constant-style folding may fall short of the P1 ceiling.

- [ ] **Step 6: Commit**

```bash
git add servers/rendering/renderer_rd/forward_clustered/render_raytracing.cpp servers/rendering/renderer_rd/forward_clustered/render_raytracing.h servers/rendering/renderer_rd/forward_clustered/render_forward_clustered.cpp servers/rendering/renderer_rd/forward_clustered/scene_shader_raytracing.cpp
git commit -m "feat(pt): E3 two-pass build_tlas, detection drives the feature flags"
```

---

### Task 5: Acceptance, the feature-free measurement, and closeout

**Files:**
- Create: `pipeline_references/tests/pt_e3_featurefree_scene.tscn`, `pipeline_references/tests/pt_e3_gate.gd`
- Modify: `PATH_TRACER_QUALITY_ROADMAP.md` (new §7.13)
- Modify: `servers/rendering/renderer_rd/forward_clustered/render_raytracing.cpp` (retire the Task 3 diagnostic)

**Interfaces:**
- Consumes: everything above.

- [ ] **Step 1: Restate acceptance criterion 2**

Already measured in Task 4: production scene, `aniso=0 coat=1 sheen=1`, image
bit-identical to HEAD, loop time recorded. Carry the numbers forward.

- [ ] **Step 2: Acceptance criterion 1 — a feature-free scene**

The production scene uses coat and sheen, so it **cannot** exercise the all-off
path — the one this whole phase exists for. Build a scene that uses none.

Model it on `pipeline_references/tests/pt_coat_gate_scene.tscn`, with
`clearcoat = 0`, no `sheen_color`, `anisotropy = 0`. Carry over the traps that
have silently broken sibling gates:

```gdscript
sky.process_mode = Sky.PROCESS_MODE_QUALITY   # REALTIME force-clamps to 256
env.background_mode = Environment.BG_SKY      # BG_COLOR renders pure black to the PT
mat.albedo_color = Color(A, A, A).linear_to_srgb()   # render_raytracing.cpp:1542 decodes it back
```

Render it on this branch and on HEAD (use the worktree — `git stash` is NOT
available, the working tree carries the user's files).

Expected: images bit-identical, log reports `aniso=0 coat=0 sheen=0`, and the E3
build is measurably faster.

**Do not skip this because criterion 2 passed.** Criterion 2 only exercises
`coat=1 sheen=1`.

- [ ] **Step 3: Acceptance criterion 3 — prove the gate can fail**

On the feature-free scene, set `clearcoat = 0.5` on one material.

Expected: the log flips to `coat=1`, **the image changes**, and the loop time rises.

If the image does not change, the coat was never actually compiled out and
criterion 1 was passing for the wrong reason.

- [ ] **Step 4: Regenerate the BASE comparison if needed**

To state recovery against `28bb89cad`, the worktree at
`C:/Users/aiadmin/Desktop/Engine_Build_test/zreal_baseline_wt` holds that commit
(BASE loop 639s). It needs `thirdparty/oidn/lib/*.lib` and `thirdparty/streamline/`
copied in from the main repo — both are gitignored, and without them the link
fails with `LNK1181: cannot open input file 'OpenImageDenoise.lib'`.

- [ ] **Step 5: Write §7.13**

In §7.12's style: the three acceptance results with their rmse figures, the loop
times, and what fraction of the 273s was recovered. If the anisotropy gating fell
short of the 108s, **say so with the number** rather than rounding it away.

State plainly what this phase did **not** recover: the 165s of coat/sheen on
scenes that use them. That was a deliberate scope decision — auto-detect only,
zero quality change — not an oversight.

- [ ] **Step 6: Retire the temporary diagnostic**

Delete the per-frame `[E3]` `print_line` added in Task 4 Step 1, or put it behind
`if (OS::get_singleton()->is_stdout_verbose())`. Confirm Task 3's
`e3_debug_seen_mask` member and its `print_line` are already gone — Task 4 Step 1
removes them; if they survived, delete them here.

- [ ] **Step 7: Commit**

```bash
git status --porcelain
git add PATH_TRACER_QUALITY_ROADMAP.md servers/rendering/renderer_rd/forward_clustered/render_raytracing.cpp pipeline_references/tests/pt_e3_featurefree_scene.tscn pipeline_references/tests/pt_e3_gate.gd
git commit -m "docs(pt): E3 closeout - measured recovery and acceptance"
```

**On that `git add`:** `pipeline_references/tests/` holds the only paths under
`pipeline_references/` this plan may stage, and only the two new files it creates.
The six modified `pipeline_references/*.gd` files and untracked `custom_shape.gd`
must never be staged. Run `git status --porcelain` first and confirm.
