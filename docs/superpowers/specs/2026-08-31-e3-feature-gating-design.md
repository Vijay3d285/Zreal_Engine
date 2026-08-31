# E3: gate anisotropy, coat and sheen on scene content

**Goal:** recover the measured +273s (+42.7%) path-tracer render-loop regression
introduced by E2b-E2e, on scenes that do not use the features responsible, with
**bit-identical output**.

## 1. Why

Production job `urbantestdark168` (HEAD) took 1050.8s against `urbantestdark167`
(`28bb89cad`) 762.6s on a visually indistinguishable render. Roadmap §7.12 has
the full investigation. The measured decomposition, six renders of the same
input JSON on one machine:

| Build | render loop | delta |
|---|---|---|
| BASE `28bb89cad` | 639s | — |
| E2b end `fcc482b0a2` | 747s | **+108s** anisotropy |
| HEAD − coat/sheen − registry | 826s | +0s registry |
| HEAD − coat/sheen | 825s | +78s E2d/E2e scaffolding |
| HEAD | 912s | **+87s** coat/sheen lobes |

Startup is 79s vs 78s — the entire regression is in the 128-frame loop.

**The cost is not executed work.** Every material in the measured scene has
`anisotropy == 0`, so `anisoActive` is already false and E2b's branches never
run — yet E2b costs 108s. The charge is register pressure from the widened
`BrdfData` and the occupancy that follows. The same applies to the 78s of
coat/sheen scaffolding. Two of three buckets, 186 of 273 seconds, are paid by a
scene that uses none of the features they belong to.

## 2. Scope

**In:** compile out anisotropy, coat and sheen when the scene provably does not
use them, driven by three new `RT_FLAGS` specialization bits.

**Out — explicitly:**

- **No quality/perf tradeoff.** A feature the scene uses stays enabled. The
  measured scene *does* use coat and sheen (removing them changes 6.03% of
  pixels), so this phase recovers anisotropy's 108s there and nothing more.
  Recovering the other 165s would mean disabling features in use; that was
  considered and rejected.
- **No operator override and no contribution threshold.** Both were considered;
  both can silently change a render.
- No change to any BSDF's maths. Enabled behaviour must be bit-identical.

## 3. Architecture

### 3.1 Flag bits

Three bits after `RT_FLAG_TRANSMISSION_ENABLED` (`1<<10`), declared in
`raytracing_common_inc.glsl` and mirrored in `scene_shader_raytracing.h`:

```
#define RT_FLAG_ANISOTROPY_ENABLED 2048u  // 1 << 11
#define RT_FLAG_COAT_ENABLED       4096u  // 1 << 12
#define RT_FLAG_SHEEN_ENABLED      8192u  // 1 << 13
```

**These bits drive the preprocessor, not the spec constant.** There are two
mechanisms in this file and they are not interchangeable:

- `RT_FLAGS` is a specialization constant (`raytracing_common_inc.glsl:12`).
  `RT_GET_*_ENABLED()` reads it at pipeline-compile time. It can fold a branch.
  It **cannot** remove a struct field or size an array.
- `RAYGEN_SHADER_OPTIONS` (`scene_shader_raytracing.cpp:63`) injects real
  `#define` snippets into the GLSL preamble per variant — the mechanism
  `DLSS_RR_ENABLED` and `USE_SER` already use.

E3 needs struct-field removal (`BrdfData`'s anisotropy state) and array sizing
(`LOBE_COUNT`), so all three features go through `RAYGEN_SHADER_OPTIONS` as
three new entries:

```
{ RT_FLAG_ANISOTROPY_ENABLED, "#define RT_ANISOTROPY_ENABLED
" },
{ RT_FLAG_COAT_ENABLED,       "#define RT_COAT_ENABLED
" },
{ RT_FLAG_SHEEN_ENABLED,      "#define RT_SHEEN_ENABLED
" },
```

and the GLSL guards are `#ifdef`, not `RT_GET_*()` calls.

The C++ and GLSL flag values must agree; they are two hand-maintained copies
today and this phase adds three more pairs.

### 3.2 Detection

`RTMaterialData` gains `uint32_t feature_bits`, populated in the existing
parameter-read block (`render_raytracing.cpp:1820-1885`) which already reads
`sheen_color`, `anisotropy_ratio` and the clearcoat params.

The thresholds must be **the same predicates the shader uses**, so detection and
consumption cannot disagree:

- anisotropy: `mat.anisotropy != 0.0f` — matches `prepareBRDFData`
  (`brdf_inc.glsl:1728`).
- coat: `mat.coatWeight > 0.00001f` — matches the layer guard
  (`raytracing_closest_hit_common_inc.glsl:1912`, `brdf_inc.glsl:3119`).
- sheen: `sheenMaxTint > 0.00001f`, i.e. max of the three `sheen_color`
  channels — matches `sheenMaxTint` (`brdf_inc.glsl:2545`).

These predicates are duplicated CPU-side. That duplication is the phase's main
correctness hazard and is called out in §5.

### 3.3 Ordering — the substantive change

`rt_flags` is computed in `render_forward_clustered.cpp:2441`, **before**
`build_tlas`, but material features are only known once instances are walked.
`build_tlas` itself needs the flags for `ensure_pipeline_bundle` and
`is_hg_ready_in_bundle`. That circularity is the problem.

`build_tlas` splits into two passes:

1. **Detect.** Walk instances calling `process_material` (already idempotent and
   cached), OR each material's `feature_bits` into a scene mask. No pipeline or
   SBT work.
2. **Build.** `final_flags = base_flags | scene_mask`, then all existing
   pipeline-bundle, SBT and instance-emission work, unchanged, using
   `final_flags`.

Cost: one extra traversal of ~144 instances against a ~7s frame.

**Why not defer detection by one frame** (start all-features-on, narrow from
frame 1 — a far smaller diff): when an instance's hit group is not ready in the
bundle for a given `rt_flags`, it is `continue`d, i.e. **dropped from the TLAS**
(`render_raytracing.cpp:2618`, `:2735`). A new flags value gets a sync HG0-only
bootstrap while the full build queues on a single serialized compile lane. So
switching variants mid-render drops most scene geometry for however many frames
the rebuild takes, and in a 128-frame DLSS-RR accumulation those frames are
accumulated rather than discarded. It would silently corrupt output. Rejected on
correctness, not cost.

Approach A introduces no second variant, so it inherits today's single-variant
warmup behaviour unchanged.

### 3.4 GLSL gating

- **Anisotropy:** under `#ifndef RT_ANISOTROPY_ENABLED`, drop `ax`, `ay`,
  `anisoPhi`, `anisoActive` from `BrdfData` and from the sampling/pdf
  signatures that thread them (`brdf_inc.glsl:1226`, `:1283`, `:1366`, `:1485`).
  The isotropic path already exists at all six consumption sites (`:1232`,
  `:1269`, `:1374`, `:1421`, `:2913`, `:3198`); this removes the *state*, which
  is what the 108s is charged to.
- **Coat and sheen:** size `LOBE_COUNT` from the spec constant and guard the
  weight, pdf, lobe-branch and layer-walk sites. Structurally the same edit the
  §7.12 probes (P1/P2) already proved compiles and runs; they are the reference
  for what the guarded form must look like.

## 4. Acceptance — measured, not asserted

Every criterion is a rendered measurement. No doctest can execute GLSL, and this
project has repeatedly shipped assertions that could not fail.

1. **Feature-free scene:** loop ≈639s (BASE) **and image bit-identical to
   BASE's**. Time alone is not sufficient — identity is what proves the gate
   changed no maths.
2. **The measured production scene:** coat and sheen detected ON, anisotropy
   OFF; loop ≈804s (912 − 108); image **bit-identical to HEAD's**. This is the
   zero-quality-change criterion, and it fails loudly if detection is wrong.
3. **Detection must be provably able to fail:** force `clearcoat` on one
   material in a scene that otherwise has none and confirm `RT_FLAG_COAT_ENABLED`
   flips on and the image changes. A gate that cannot newly fail is not an
   instrument.

Reference artefacts (BASE, HEAD, E2b-end images and timings) already exist from
the §7.12 investigation and are the comparison set.

## 5. Risks

- **Spec-constant folding may not recover what `#if` removal did.** P1 measured
  87s by hard-removing coat/sheen; the flag version could land short of it. P1
  and BASE are the ceilings, and criterion 1 measures the gap rather than
  assuming there is none.
- **Duplicated predicates (§3.2).** CPU detection and GLSL consumption are two
  copies of three thresholds. If they drift, a feature is silently compiled out
  of a scene that uses it — which criterion 2's bit-identity check is what
  catches.
- **Flag-bit values are hand-mirrored** between GLSL and C++, as the existing
  five already are.
- **The raygen permutation set grows from 4 to 32.** `RAYGEN_SHADER_OPTIONS`
  is 2^N in its entry count (`scene_shader_raytracing.cpp:61`), today 2 entries
  / 4 variants; three more makes 32. Variants are compiled lazily and a single
  render still requests one, so the cost is latent rather than paid per render
  — but it is an 8x growth in the reachable permutation space, and each new
  combination pays a first-use compile.
- **Pipeline bundles are likewise keyed per flags value**, so a session
  rendering scenes with differing feature sets builds a bundle per distinct
  combination.
