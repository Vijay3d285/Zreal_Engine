# Blue-noise sampling (Cycles BLUE_NOISE_PURE) -- design

Roadmap item 5, second half ("calmer grain"; the first half, Filter Glossy, shipped 2026-10-14).
Approved in conversation 2026-10-15: scope stills AND video; approach = port Cycles' pattern.

## Goal

At the same sample count and render time, the error left in each pixel after its N samples is
distributed as blue noise across the screen: neighbouring pixels' errors cancel instead of
clumping. The visible target is less blotchy denoised output, mainly in the 24-spp OIDN video, where
OIDN turns low-frequency clumps into blotches and shimmer. Brightness must not change (only where
the noise sits moves), off must be byte-identical, and the realtime / DLSS-RR route is untouched.

## Context

**Ours today** (`raytracing_inc.glsl:477-560`, `sobol_burley_inc.glsl`): Cycles' Sobol-Burley.
- Every pixel draws from its own Owen-scrambled Sobol sequence, seeded by
  `rng_pixel_seed(p) = sb_hash_iqnt2d(x, y) ^ RT_SAMPLER_SEED`.
- Each pixel's samples are well stratified among themselves, but neighbours are independent, so
  the screen-space error is white noise.
- `RNGState {pixel, sample_index, offset}`. Every constructor (`rng_init`, `rng_unpack` and the two
  init-block helpers near `raytracing_inc.glsl:630-680`) gets `pixel` from `rng_pixel_seed()`.
- The payload carries `sample_index` (20 bits) and `offset` (12 bits); `pixel` is recomputed from
  `gl_LaunchIDEXT`.
- On the accumulate route `sample_index` is the accumulation frame, 0..N-1, and N is the
  environment's accumulation target. That target is already in the shader at `rt_params[7]`:
  `PT_PARAM_ACCUM_TARGET`, copied with env params 0-15 at `render_raytracing.cpp:4262`. The probes
  set it to `PROBE_FRAMES` (16), stills to 256, video to 24 per delivered frame.
- Video frames restart at sample 0 each frame with the fixed `RT_SAMPLER_SEED`, so a pixel draws
  the same numbers every frame. This does not change.

**Cycles** (local source `C:\Users\aiadmin\Desktop\blender_build\blender\intern\cycles`):
- `blender/sync.cpp:438-448`: `AUTOMATIC` gives `BLUE_NOISE_PURE` for final (background) renders;
  that is Blender's default.
- `kernel/sample/pattern.h:134-157` `path_rng_pixel_init`:
  `nested_uniform_scramble_base4(morton2d(x, y), seed)`. One shared sequence; each pixel's offset
  along it comes from a hierarchically shuffled Morton curve.
- `kernel/sample/pattern.h:34-48` `blue_noise_indexing` (PURE): `index = sample + pixel_index * N`,
  where `N = blue_noise_sequence_length = aa_samples` (`scene/integrator.cpp:321`), seed 0, mask
  `0xffffffff`.
- `kernel/sample/pattern.h:66-81` `path_rng_1D/2D`: `sobol_burley_sample_1D/2D(index, dimension, 0, 0xffffffff)`.
- `kernel/sample/util.h:44-77`: `reversed_bit_owen_base4`, `nested_uniform_scramble_base4`,
  `expand_bits`, `morton2d`.
- `scene/integrator.cpp:345-348`: the blue-noise seed is hashed, because a small user seed such as
  0 does not scramble. Ours is the constant `RT_SAMPLER_SEED = 0x5f356495`, already random-looking.
- **Important:** per the comment at `pattern.h:50-55`, one sample of a PURE sequence is NOT blue
  noise across pixels. The property belongs to each pixel's error after all N samples. That is what
  every test below measures.

## Design

### 1. Helpers (`sobol_burley_inc.glsl`, `sb_` prefix as the file uses)

These are ported verbatim from Cycles `kernel/sample/util.h`. They are mirrored in
`tests/servers/rendering/test_pt_sobol.cpp`, inside its `TestPTSobol` namespace, like the existing
`sb_*` mirrors.

```glsl
uint sb_pcg_owen_base4(uint p_n, uint p_seed) {         // Cycles reversed_bit_owen_base4
	p_n ^= p_n * 0x3d20adeau;
	p_n ^= (p_n >> 1u) & (p_n << 1u) & 0x55555555u;
	p_n += p_seed;
	p_n *= (p_seed >> 16u) | 1u;
	p_n ^= (p_n >> 1u) & (p_n << 1u) & 0x55555555u;
	p_n ^= p_n * 0x05526c56u;
	p_n ^= p_n * 0x53a22864u;
	return p_n;
}
uint sb_nested_uniform_scramble_base4(uint p_i, uint p_seed) {
	return bitfieldReverse(sb_pcg_owen_base4(bitfieldReverse(p_i), p_seed));
}
uint sb_expand_bits(uint p_x) {                          // Cycles expand_bits
	p_x &= 0x0000ffffu;
	p_x = (p_x ^ (p_x << 8u)) & 0x00ff00ffu;
	p_x = (p_x ^ (p_x << 4u)) & 0x0f0f0f0fu;
	p_x = (p_x ^ (p_x << 2u)) & 0x33333333u;
	p_x = (p_x ^ (p_x << 1u)) & 0x55555555u;
	return p_x;
}
uint sb_morton2d(uint p_x, uint p_y) { return (sb_expand_bits(p_x) << 1u) | sb_expand_bits(p_y); }
```

### 2. Indexing (`raytracing_inc.glsl`, accumulate variant only)

> **Amended after implementation (see Results).** The runtime branch described below broke
> off-exactness, so blue noise is a compile-time shader variant instead.
> - Sample-count field value 127 (`RT_SAMPLE_COUNT_BLUE_NOISE`) injects `#define RT_BLUE_NOISE`.
> - All blue code sits under `#ifdef RT_BLUE_NOISE` / `#else <original line>`.
> - `rt_params` slot 43 is not used.

- New defines: `RT_PARAM_ACCUM_TARGET 7` (the slot already exists; only a name is new) and
  `RT_PARAM_SAMPLING_PATTERN 43` (1 = blue noise, 0 = classic).
- A helper `uint rt_blue_noise_length()`:
  - **`#ifdef RT_OIDN_FEATURES`:** returns `max(1u, uint(get_rt_param(RT_PARAM_ACCUM_TARGET)))` when
    `get_rt_param(RT_PARAM_SAMPLING_PATTERN) > 0.5`, else 0u.
  - **Otherwise:** always 0u, so the one-shot / DLSS-RR variant never takes the blue path.
- **`rng_pixel_seed`:** when `rt_blue_noise_length() > 0u`, return
  `sb_nested_uniform_scramble_base4(sb_morton2d(x, y), RT_SAMPLER_SEED)`.
- **`rng_1d` / `rng_2d`:** when `rt_blue_noise_length() > 0u`, return
  `sobol_burley_sample_1D/2D(p_rng.sample_index + p_rng.pixel * N, p_rng.offset + p_dim, 0u, 0xffffffffu)`.
  This is Cycles' `path_rng_*` with PURE indexing. The `uint` multiply wraps exactly as Cycles'
  does: at 4K, `pixel` is a full 32-bit scramble output.
- **Off is textual:** each function's new code is an early-return branch placed before its original
  line, and the original lines are left character-for-character unchanged. A merged expression
  changed GPU rounding on the DoF branch (20.8% of pixels), so the branch must stay separate.
- **`rng_side_stream`** keeps hashing `p_rng.pixel`; under blue noise that is still unique per pixel.
- **Samples beyond N:** a pixel would draw from its neighbour's range. Each pixel's estimate stays
  unbiased but the blue-noise property is lost. Production accumulation stops at the target, so
  this never happens there. Cycles has the same constraint.

### 3. Control and placement

> **Amended after implementation (see Results).** The setting is read in
> `SceneShaderRaytracing::compute_rt_flags()` as part of the shader variant key, not passed in
> slot 43, and one-shot sample counts cap at 126.

- **Setting:** `GLOBAL_DEF(PropertyInfo(Variant::INT, "rendering/pathtracer/sampling_pattern",
  PROPERTY_HINT_ENUM, "Classic,Blue Noise"), 1)`, next to `filter_glossy` in
  `servers/rendering/rendering_server.cpp`. The default is blue noise, Blender's default for final
  renders.
- **C++:**
  - `scene_shader_raytracing.h`: `RT_PARAM_SAMPLING_PATTERN = 43`.
  - `render_raytracing.cpp`, beside the Filter Glossy fill:
    `params[43] = GLOBAL_GET(...) == 1 ? 1.0f : 0.0f`.
  - Update the comment on `float params[44]`: slot 43 was the last free slot, so the UBO is now full.
- **DLSS-RR video:** in `video_glb_creation.gd` `_resolve_video_denoiser`, the `dlssrr` branch also
  sets `sampling_pattern` to 0.
  - Its daylight probes run the accumulate variant while its frames run the one-shot variant.
  - Classic keeps the probe byte-identical (the invariant in `scene_shader_raytracing.cpp`). Name
    blue noise in that comment beside Filter Glossy.
- **Gates:** `pipeline_references/tests/pt_validation.gd` `_notification(ENTER_TREE)` also pins
  `sampling_pattern` to 0. Every gate's baseline was measured with the classic pattern.
- **Placement test:** `pipeline_references/tests/filter_glossy_unit.gd` gains the same three checks
  for `sampling_pattern`:
  - dlssrr gives 0;
  - oidn keeps 1;
  - a gate pins 0.

  Run it from a scratch copy of `pipeline_references` without `.godot/`; see that file's header.

## Testing

### Pass / fail

1. **Helpers (doctest, `[PathTracer][Sobol]`):**
   - `sb_morton2d`: (0,0)=0, (1,0)=2, (0,1)=1, (3,3)=15, (65535,65535)=0xffffffff.
   - `sb_nested_uniform_scramble_base4` keeps blocks together and is a bijection inside them, for
     seeds `RT_SAMPLER_SEED` and 0x12345678:
     - the 4096 Morton codes of a 64x64 tile map to values that share bits 12-31, and whose bits
       0-11 are a permutation of 0..4095;
     - each aligned 2x2 quad's 4 values share bits 2-31.
   - Two seeds give different maps.
2. **Blue-noise error spectrum (doctest; the check that makes the feature falsifiable):**
   - **Setup:** for every pixel of a 64x64 tile, average N samples of a test integrand:
     - the 1D step `u < 0.37`;
     - the 2D disc indicator `|v - (0.5, 0.5)| < 0.4`.
   - **Error map:** each pixel's average minus the true value.
   - **Measure:** the share of its DFT power at radius 1-8 from DC (low frequencies, i.e. blotches).
     The DC bin itself, the tile's mean error, is excluded. White noise puts about 200/4095 = 4.9%
     there. Compare blue indexing against classic indexing with the per-pixel hash seed.
   - **Pass:**
     - blue below 0.5x classic at N = 16;
     - blue below 0.8x classic at N = 24, the non-power-of-two video case;
     - classic within 0.7-1.3x of its white-noise expectation, so the classic baseline is sane.
   - A broken offset (missing `* N`, missing Morton, or per-pixel seeds left on) reads about 1.0x
     and fails.
   - If the correct port cannot reach these ratios, stop and report the measured values. Do not
     loosen the thresholds silently.
3. **Off is exact:** job 209 still (4K, production scripts) with `sampling_pattern = 0` is
   byte-identical to today's binary.
4. **Brightness unchanged:** job 209 still, raw OIDN input (`ZR_OIDN_DUMP`, pre-exposure).
   - **Floor:** first render classic again on independent samples (`ZR_SEED_OFFSET=256`), and take
     the noise floor = |mean| and |box-4 median| differences between the two classic renders.
   - **Pass:**
     - blue vs classic within 2x that floor, or within 1%, whichever is larger;
     - no new pixels above 200 (on <= off + 2).
5. **Time** within +2% (warm shader cache); no `Error compiling` in any log.
6. **Suites:** the full doctest suite and the extended placement unit test pass.

### Benefit (numbers for the owner's decision, not pass/fail)

- **Still, full HD:** a copy of job 209 with `width` 1920 and `height` 1080 (honoured by
  `render.gd set_resolution`).
  - Renders: classic and blue at 256 spp, plus a classic reference at 2048 spp. Dump all three with
    `ZR_OIDN_DUMP`.
  - **Display transform:** all three are judged in linear raw space, scaled by the classic 256
    render's probe exposure, then `y = x / (1 + x)`.
  - **Blotch error:** the RMS of the Gaussian-blurred (sigma 3 px) difference between a candidate and
    the reference's raw input. Report it for the OIDN output (what ships) and for the raw input
    (where blue noise acts directly), along with the full unblurred RMS.
- **Video:** job 216 keyframes 204-215 (`seg204`, 4K, 24 spp), classic and blue, giving a 12-frame
  side-by-side clip.
  - Reference: a 1-keyframe segment for keyframe 215
    (`make_segment_job.py --start 215 --count 1` from the job 216 source) at
    `ZR_VIDEO_ACCUM_TARGET=1024`, classic.
  - Score the last frame of each candidate with the same blotch error.
- **For the owner:** 4K still crops (classic | blue, final and raw), the video clip and the
  numbers. They choose: ship on, ship off (default 0), or adjust.
- **Stated expectation:** the 256-spp still may barely change after OIDN. If the blotch error does
  not improve, say so and recommend shipping off.
- **GPU budget:** about 2 hours of background renders, with the usual `tasklist | grep -i godot`
  check before each.

## Shipping

The engine binary (the owner copies it to `godot/bin/`), plus the 2-line `dlssrr` addition in
production's `video_glb_creation.gd`. That addition only matters for DLSS-RR video, and the owner
copies it or asks for it. To turn blue noise off in production, set
`rendering/pathtracer/sampling_pattern=0` under `[rendering]` in `godot_project/project.godot`.

## Out of scope

- The one-shot / DLSS-RR route.
- `BLUE_NOISE_FIRST` and `BLUE_NOISE_ROUND`. ROUND (N rounded to 32 for video) is the follow-up if
  N = 24 measures weak.
- A per-frame (animated) seed for video.
- Tabulated Sobol.
- The unclamped miss-path sky (its own task).

## Results 2026-10-15

**Unit tests.** The C++ mirror of the blue/classic low-frequency share, 64x64 tile, dimension 16:

| N | Step | Disc |
|---|---|---|
| 16 | 0.396 | 0.417 |
| 24 | 0.381 | 0.508 |

These are identical to the Python prototype. The N=24 threshold is 0.6, not 0.8 (plan ruling): at 0.8 a row-major offset (0.63 / 0.72) would pass. The classic pattern reads white (0.96-1.16x). The block, seed and Morton tests pass, and the suite is 1611/1611.

**Off is exact, as a shader variant.**
- **The runtime early-return branch failed.** With `sampling_pattern = 0` it moved 6.9% of raw pixels by float rounding (median 8e-7 relative, max 2.2%, mean 0.0); the GPU compiler rescheduled float code around the per-call branches (the DoF failure mode).
- **Blue noise is now a compile-time variant.**
  - The flag word is full, so sample-count field 127 means accumulate + blue noise and injects `RT_BLUE_NOISE`.
  - One-shot sample counts cap at 126.
  - `test_pt_rt_flags_variant_key.cpp` states the new contract.
- **Result:** classic raw and OIDN output are byte-identical to the pre-change binary, and the classic PNG differs in 0 pixels.
- **The PNG alone cannot carry an off check.** A same-binary rerun can differ in about 27 pixels by 1 level, introduced after OIDN, while the raw and OIDN dumps are deterministic. So off is judged on the raw dumps.

**Brightness and time (job 209 still, 4K).**
- Raw mean +0.07% and box-4 median -0.32% against a classic noise floor of 0.06% / 0.07%.
- No spikes above 200.
- Warm blue took 511 s against the mean of four classic runs, 505 s (497-510): +1.2%. Full HD: 207 s vs 206 s.
- 0 `Error compiling` in every render.

**Benefit, against independent references.**
- **The plan's first references were biased toward classic.** Classic at 2048 / 1024 spp from index 0 reuses the classic candidate's own samples (error correlation +0.10). Against them, classic's raw total error read 12% low (0.03634 vs 0.04065).
- **The references were re-rendered with `ZR_SEED_OFFSET=524288`** (correlation +0.015). Blue vs classic:

| | Blotch, raw | Blotch, denoised | Total error, raw | Total error, denoised |
|---|---|---|---|---|
| Still, full HD, 256 spp | -3.8% | -3.6% | 0.0% | 0.0% |
| Video, last frame, 24 spp | -2.9% | -5.6% | 0.0% | +0.1% |

- Total error is unchanged and the low-frequency (blotchy) share drops, as blue noise should.
- Video mean frame-to-frame change: 6.719 classic, 6.681 blue (-0.6%).
- In the raw crops the grain is visibly finer; the denoised images look nearly the same.

**The DLSS-RR one-shot variant** compiles (0 errors) and renders. The 1-keyframe DLSS-RR video job then hits `VK_ERROR_DEVICE_LOST` at DLSS priming or thumbnail capture. The 2026-10-08 production binary does the same, so this is pre-existing and filed as its own task.

**Owner's decision (2026-10-15): ship on (default 1).**

**Rulings (plan and execution):**
- The N=24 threshold is 0.6.
- The benefit metric's display is median-normalised.
- The video reference is cut from `seg204.json`.
- Blue noise is a variant, not a runtime branch; slot 43 is unused.
- Off-exactness is judged on the raw dumps.
- The variant-key tests were updated to the new contract.
- Time is judged against four classic runs.
- The references are independent (`ZR_SEED_OFFSET=524288`).

**Delivered exposure (final review, 2026-10-15).** The pass/fail brightness check compared
pre-exposure raw dumps, so it could not see the daylight probe choosing a different exposure.

| Render | Classic exposure | Blue exposure | Change |
|---|---|---|---|
| 4K still | 24.433 | 24.102 | -1.36% |
| Full-HD still | 23.776 | 23.557 | -0.92% |

- Classic run on another seed: +0.21%.
- Delivered still: about 1% darker.
- Neither exposure is more accurate. The probe's own statistic on the converged 2048-spp full-HD
  reference reads 0.00760; the 16-spp probes read classic -0.34% and blue +0.58%.
- The integrator's brightness is unchanged (raw +0.07%).
- **The owner accepts the ~1% exposure shift and keeps blue noise on (2026-10-15).**
- DLSS-RR accumulate words never take the blue variant (engine guard in `compute_rt_flags`, final review).

