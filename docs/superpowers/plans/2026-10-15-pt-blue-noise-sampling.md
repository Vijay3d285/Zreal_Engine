# Blue-Noise Sampling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On the accumulate route (stills and OIDN video), draw every pixel's samples from one shared Owen-scrambled Sobol sequence at a Morton-curve offset, exactly as Cycles' default for final renders (`BLUE_NOISE_PURE`). Each pixel's leftover error then lands as blue noise across the screen, at the same render time and brightness.

**Architecture:**
- **Helpers.** Four Cycles helpers (`sb_pcg_owen_base4`, `sb_nested_uniform_scramble_base4`, `sb_expand_bits`, `sb_morton2d`) join `sobol_burley_inc.glsl`, with CPU mirrors and doctests (block structure plus an error-spectrum test) in `test_pt_sobol.cpp`.
- **Global.** A module-level global `g_rt_blue_noise_length` in `raytracing_inc.glsl` is set once at the top of the raygen and closest-hit `main()` from `rt_params`. The sampler cannot call `get_rt_param()`, because `raytracing_common_inc.glsl` is included after it.
- **Sampler branches.** `rng_pixel_seed`, `rng_1d` and `rng_2d` take an early-return blue branch when the global is non-zero.
- **Setting.** One project setting goes in `rt_params` slot 43. DLSS-RR video and the path-tracer gates pin it to classic.

**Tech Stack:** Godot 4.7 fork (C++17, Vulkan RT, GLSL 460), doctest, GDScript headless unit scripts, Python 3 + numpy + Pillow for render checks (no scipy on this machine).

**Spec:** `docs/superpowers/specs/2026-10-15-pt-blue-noise-sampling-design.md`

## Global Constraints

- Cycles `BLUE_NOISE_PURE`:
  - pixel offset `nested_uniform_scramble_base4(morton2d(x, y), seed)`;
  - draw `sobol_burley_sample_1D/2D(sample + offset * N, dimension, 0, 0xffffffff)`;
  - `N` = the accumulation target = `rt_params[7]` (`PT_PARAM_ACCUM_TARGET`);
  - `uint` multiply wraps (spec, Design 2).
- Seed for the scramble: `RT_SAMPLER_SEED` (`0x5f356495`, `raytracing_inc.glsl`) (spec, Context).
- Setting `rendering/pathtracer/sampling_pattern`, INT enum `"Classic,Blue Noise"`, **default 1** (blue noise); `rt_params` **slot 43** = `1.0` blue / `0.0` classic (spec, Design 3).
- Accumulate variant (`RT_OIDN_FEATURES`) only; the one-shot / DLSS-RR variant never takes the blue path (spec, Design 2).
- Off (`sampling_pattern=0`) is byte-identical to the pre-change binary. Every new branch is an early return in front of the original line, which stays character-for-character unchanged (spec, Design 2; the DoF 20.8% lesson).
- DLSS-RR video jobs and every `pt_validation.gd` gate pin `sampling_pattern` to 0 (spec, Design 3).
- Build with `python -m SCons platform=windows target=editor tests=yes`, keeping that one configuration for the whole plan, since a config switch costs ~20 min and drops the doctest suite.
- Grep every render log for `Error compiling` (a clean build validates no GLSL). Check `tasklist | grep -i godot` before every render. Never touch Godot processes running from `C:\Zlendo2026\`. Stop a batch with a `STOP` file in the workspace.
- Work in place on the current phase branch (`vijay_PTEngine_v32_RenderQlty7`). `pipeline_references/video_glb_creation.gd` carries an UNSTAGED owner hunk (`USE_REFLECTION_PROBE_HOTSPOT_FIX`) that must never be committed by this plan; Task 3 Step 6 stages only its own hunk.

### Rulings recorded here (from the offline prototype, 2026-10-15)

The Python port of the CPU mirror (scratchpad `bn/proto.py`, `bn/broken.py`) predicts the spectrum test. Each figure is the blue / classic share of error power at DFT radius 1-8 on a 64x64 tile, dimension 16:

| Variant | N=16 step | N=16 disc | N=24 step | N=24 disc |
|---|---|---|---|---|
| Correct port | 0.396 | 0.417 | 0.381 | 0.508 |
| Without `* N` | 3.18 | 3.61 | 3.65 | 5.49 |
| Per-pixel seed kept | 1.05 | 0.93 | 0.88 | 1.00 |
| Row-major instead of Morton | 0.83 | 0.72 | 0.72 | 0.63 |

Classic reads 0.96-1.16x the white-noise expectation of 196/4095.

- **N=24 threshold tightened from the spec's 0.8 to 0.6.** At 0.8 the row-major mistake (0.63 / 0.72) would pass; at 0.6 every listed mistake fails, while the correct port (0.381 / 0.508) passes with 15% margin. Cost if wrong: if the C++ float mirror lands above 0.6 on the disc, stop and report rather than loosen.
- **Benefit-metric display is median-normalised, not probe-exposed.** Each comparison scales candidate and reference by `0.18 / box4-median(reference luminance)` before `x / (1 + x)`. The spec said "the classic 256 render's probe exposure", but the probe also targets a median, and this needs no log parsing and works for video. Cost if wrong: none for a relative blue-vs-classic comparison.
- **The video reference is cut from `seg204.json` itself** (`make_segment_job.py seg204.json ... --start 11 --count 1`), not from a job 216 source. No `input_json/*216*.json` contains seg204's keyframes verbatim. Cost if wrong: none; it is keyframe 215 of the exact segment.

## Review Focus

1. **Off drifting by compiler rounding.** Expected: `sampling_pattern=0` byte-identical. Pinned in Task 2 Step 7.
2. **The one-shot / DLSS-RR variant failing to compile.** Its new code is `rng_*`'s dead `g_rt_blue_noise_length > 0u` branch; `rt_init_blue_noise()` is empty there. No still or OIDN video compiles that variant. Expected: compiles, renders. Pinned in Task 2 Step 8 by a 1-keyframe `ZR_VIDEO_DENOISER=dlssrr` render with 0 `Error compiling`.
3. **N not equal to the samples actually accumulated.** A pixel past N draws its neighbour's range, which is unbiased but no longer blue. Expected: the probe sets its target (16) before its frames; stills stop at 256; video resets per delivered frame at 24. Pinned in Task 4 Step 2: the log's `[PhaseA] ... target=` line, and the video dump read at the last frame. Also by final-review inspection of `Daylight.probe` (`daylight.gd:285-299`).
4. **A brightness bias hidden by the daylight probe.** Expected: raw mean and box-4 median within max(2x the classic noise floor, 1%), no new >200 spikes. Pinned in Task 4 Step 2 (raw dumps).
5. **Video temporal look changing (shimmer).** The pattern stays fixed per frame, but blue noise moves where the error sits. Expected: mean frame-to-frame change within noise of classic; the owner judges the clip. Pinned in Task 4 Step 4.

---

## Workspace and harness (before Task 1)

Workspace (git-ignored): `.superpowers/sdd/2026-10-15-pt-blue-noise-sampling/`. Inputs and the FHD job:

```bash
W=/c/Users/aiadmin/Desktop/Engine_Build_test/Zreal_Engine/.superpowers/sdd/2026-10-15-pt-blue-noise-sampling
R=/c/Users/aiadmin/Desktop/Engine_Build_test/Zreal_Engine
mkdir -p $W
cp $R/.superpowers/sdd/2026-10-08-video-parity/prodab/j209_input.json $W/j209_input.json
cp $R/.superpowers/sdd/2026-10-14-video-fill-grid/seg204.json $W/seg204.json
python -I -c "import json; d=json.load(open(r'$(cygpath -w $W)\j209_input.json')); d['width']=1920; d['height']=1080; json.dump(d, open(r'$(cygpath -w $W)\j209_fhd.json','w'))"
python -I $R/pipeline_references/tests/video_oidn/make_segment_job.py "$(cygpath -w $W/seg204.json)" "$(cygpath -w $W/kf215.json)" --start 11 --count 1
```

Expected: the last command prints `wrote ...kf215.json: keyframes 11..11 (1 consecutive)`.

`$W/run_still.sh`: a job still with PRODUCTION's current scripts (copied; production untouched), optional `override.cfg` lines and extra env. The job file is the 4th argument (default `j209_input.json`).

```bash
#!/bin/bash
# usage: run_still.sh <tag> [override.cfg lines ';'-separated] [extra env] [job json in $W]
W=/c/Users/aiadmin/Desktop/Engine_Build_test/Zreal_Engine/.superpowers/sdd/2026-10-15-pt-blue-noise-sampling
R=/c/Users/aiadmin/Desktop/Engine_Build_test/Zreal_Engine
P=/c/Zlendo2026/ZlenderRender_stage_copy/godot_project
BIN=$R/bin/godot.windows.editor.x86_64.console.exe
TAG=$1; OVR=$2; EXTRA=$3; JOB=${4:-j209_input.json}; D=$W/$TAG
if [ -f "$W/STOP" ]; then echo "ABORT: $W/STOP exists" >&2; exit 1; fi
rm -rf "$D"; mkdir -p "$D/proj"
if tasklist | grep -qi godot; then echo "ABORT: a Godot process is running" > "$D/done"; exit 1; fi
cp $P/*.gd $P/*.tscn $P/project.godot "$D/proj/"; cp -r $P/shapes "$D/proj/"
ln $P/day.exr "$D/proj/day.exr" 2>/dev/null || cp $P/day.exr "$D/proj/"
ln $P/night.exr "$D/proj/night.exr" 2>/dev/null || cp $P/night.exr "$D/proj/"
if [ -n "$OVR" ]; then echo "$OVR" | tr ';' '\n' > "$D/proj/override.cfg"; fi
start=$(date +%s)
( cd "$D" && env $EXTRA $BIN --path "$D/proj" res://main.tscn -- "$W/$JOB" "$D/render.png" > "$D/run.log" 2>&1 )
echo "exit=$? secs=$(( $(date +%s) - start ))" > "$D/done"
rm -rf "$D/proj"
```

`$W/run_video.sh`: the same for a video segment (`video_main.tscn`, writes `frame*.png`). The job file is the 4th argument (default `seg204.json`).

```bash
#!/bin/bash
# usage: run_video.sh <tag> [override.cfg lines ';'-separated] [extra env] [job json in $W]
W=/c/Users/aiadmin/Desktop/Engine_Build_test/Zreal_Engine/.superpowers/sdd/2026-10-15-pt-blue-noise-sampling
R=/c/Users/aiadmin/Desktop/Engine_Build_test/Zreal_Engine
P=/c/Zlendo2026/ZlenderRender_stage_copy/godot_project
BIN=$R/bin/godot.windows.editor.x86_64.console.exe
TAG=$1; OVR=$2; EXTRA=$3; JOB=${4:-seg204.json}; D=$W/$TAG
if [ -f "$W/STOP" ]; then echo "ABORT: $W/STOP exists" >&2; exit 1; fi
rm -rf "$D"; mkdir -p "$D/proj"
if tasklist | grep -qi godot; then echo "ABORT: a Godot process is running" > "$D/done"; exit 1; fi
cp $P/*.gd $P/*.tscn $P/project.godot "$D/proj/"; cp -r $P/shapes "$D/proj/"
ln $P/day.exr "$D/proj/day.exr" 2>/dev/null || cp $P/day.exr "$D/proj/"
ln $P/night.exr "$D/proj/night.exr" 2>/dev/null || cp $P/night.exr "$D/proj/"
if [ -n "$OVR" ]; then echo "$OVR" | tr ';' '\n' > "$D/proj/override.cfg"; fi
start=$(date +%s)
( cd "$D" && env $EXTRA $BIN --path "$D/proj" --write-movie "$D/frame.png" --fixed-fps 60 res://video_main.tscn -- "$W/$JOB" "$D/out.mp4" "$D/thumb.png" > "$D/run.log" 2>&1 )
echo "exit=$? secs=$(( $(date +%s) - start ))" > "$D/done"
rm -rf "$D/proj"
```

`CLASSIC="[rendering];pathtracer/sampling_pattern=0"` is the override string that turns blue noise off. A render with no override runs the default.

**Baseline before ANY build (today's binary, `bin/` as built by the Filter Glossy work):**

```bash
W=/c/Users/aiadmin/Desktop/Engine_Build_test/Zreal_Engine/.superpowers/sdd/2026-10-15-pt-blue-noise-sampling
bash $W/run_still.sh base_a; cat $W/base_a/done
bash $W/run_still.sh base_b; cat $W/base_b/done
cmp -s $W/base_a/render.png $W/base_b/render.png && echo "REPEATABLE" || echo "NOT REPEATABLE"
```

Expected: `exit=0` twice and `REPEATABLE` (the 2026-10-14 build was md5-repeatable). If `NOT REPEATABLE`, stop: every byte-identity check below depends on it.

---

### Task 1: The base-4 scramble and Morton helpers, mirrored and tested

**Files:**
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/sobol_burley_inc.glsl` (append after `sobol_burley_sample_2D`, end of file)
- Modify: `tests/servers/rendering/test_pt_sobol.cpp` (new mirrors after `block_mask()`; new test cases before `} // namespace TestPTSobol`)
- Test: `tests/servers/rendering/test_pt_sobol.cpp`

**Interfaces:**
- Consumes: the existing mirrors `sb_bit_reverse`, `sobol_burley_sample_1D(uint32_t, uint32_t, uint32_t, uint32_t)`, `sobol_burley_sample_2D(uint32_t, uint32_t, uint32_t, uint32_t, float &, float &)`.
- Produces (GLSL, `sobol_burley_inc.glsl`): `uint sb_pcg_owen_base4(uint p_n, uint p_seed)`, `uint sb_nested_uniform_scramble_base4(uint p_i, uint p_seed)`, `uint sb_expand_bits(uint p_x)`, `uint sb_morton2d(uint p_x, uint p_y)`.

- [ ] **Step 1: Write the failing tests (with stub mirrors)**

In `tests/servers/rendering/test_pt_sobol.cpp`, after `block_mask()` (before the first `TEST_CASE`), add:

```cpp
// Blue-noise mirrors (spec 2026-10-15-pt-blue-noise-sampling-design.md). Keep in lockstep with
// sobol_burley_inc.glsl. Source of truth: Cycles kernel/sample/util.h:44-77.
static uint32_t sb_pcg_owen_base4(uint32_t p_n, uint32_t p_seed) {
	return p_n; // replaced in Step 3
}

static uint32_t sb_nested_uniform_scramble_base4(uint32_t p_i, uint32_t p_seed) {
	return p_i; // replaced in Step 3
}

static uint32_t sb_expand_bits(uint32_t p_x) {
	return 0; // replaced in Step 3
}

static uint32_t sb_morton2d(uint32_t p_x, uint32_t p_y) {
	return 0; // replaced in Step 3
}

// Cycles util/hash.h hash_iqnt2d, as sobol_burley_inc.glsl sb_hash_iqnt2d: the classic
// per-pixel seed the blue-noise pattern replaces.
static uint32_t sb_hash_iqnt2d(uint32_t p_x, uint32_t p_y) {
	const uint32_t qx = 1103515245u * ((p_x >> 1) ^ p_y);
	const uint32_t qy = 1103515245u * ((p_y >> 1) ^ p_x);
	return 1103515245u * (qx ^ (qy >> 3));
}

static const uint32_t BN_TILE = 64;
static const uint32_t BN_SEED = 0x5f356495u; // RT_SAMPLER_SEED (raytracing_inc.glsl)
static const uint32_t BN_DIM = 16u; // block 1, slot 0: the first shading draw (RT_PRNG_SURFACE_BSDF)

// Per-pixel error of an N-sample estimate over a 64x64 tile (spec, Testing 2). p_blue: Cycles
// BLUE_NOISE_PURE indexing (index = s + offset * N, seed 0); otherwise the classic per-pixel
// seed. p_disc: the 2D disc indicator |v - (0.5, 0.5)| < 0.4; otherwise the 1D step u < 0.37.
static void bn_error_map(uint32_t p_n, bool p_blue, bool p_disc, double *r_err) {
	for (uint32_t y = 0; y < BN_TILE; y++) {
		for (uint32_t x = 0; x < BN_TILE; x++) {
			const uint32_t offset = sb_nested_uniform_scramble_base4(sb_morton2d(x, y), BN_SEED);
			const uint32_t pixel_seed = sb_hash_iqnt2d(x, y) ^ BN_SEED;
			double hits = 0.0;
			for (uint32_t s = 0; s < p_n; s++) {
				const uint32_t index = p_blue ? s + offset * p_n : s;
				const uint32_t seed = p_blue ? 0u : pixel_seed;
				if (p_disc) {
					float u, v;
					sobol_burley_sample_2D(index, BN_DIM, seed, 0xffffffffu, u, v);
					hits += ((u - 0.5f) * (u - 0.5f) + (v - 0.5f) * (v - 0.5f) < 0.16f) ? 1.0 : 0.0;
				} else {
					hits += (sobol_burley_sample_1D(index, BN_DIM, seed, 0xffffffffu) < 0.37f) ? 1.0 : 0.0;
				}
			}
			const double truth = p_disc ? Math::PI * 0.16 : 0.37;
			r_err[y * BN_TILE + x] = hits / (double)p_n - truth;
		}
	}
}

// Integer DFT frequencies (u, v) with 1 <= u^2 + v^2 <= 64: the low-frequency ring, i.e. blotches.
static int bn_ring_bins() {
	int n = 0;
	for (int v = -8; v <= 8; v++) {
		for (int u = -8; u <= 8; u++) {
			const int r2 = u * u + v * v;
			n += (r2 >= 1 && r2 <= 64) ? 1 : 0;
		}
	}
	return n;
}

// Share of the error map's power in the ring, DC excluded. Total non-DC power comes from Parseval:
// sum |F|^2 = M * sum e^2 with M = 64 * 64, minus |F(0)|^2 = (sum e)^2.
static double bn_low_share(const double *p_err) {
	double sum = 0.0;
	double sum2 = 0.0;
	for (uint32_t i = 0; i < BN_TILE * BN_TILE; i++) {
		sum += p_err[i];
		sum2 += p_err[i] * p_err[i];
	}
	const double total = (double)(BN_TILE * BN_TILE) * sum2 - sum * sum;
	if (total <= 1e-9) {
		return 1.0; // a constant error map has no spatial spectrum at all: certainly not blue
	}
	double low = 0.0;
	for (int v = -8; v <= 8; v++) {
		for (int u = -8; u <= 8; u++) {
			const int r2 = u * u + v * v;
			if (r2 < 1 || r2 > 64) {
				continue;
			}
			double re = 0.0;
			double im = 0.0;
			for (uint32_t y = 0; y < BN_TILE; y++) {
				for (uint32_t x = 0; x < BN_TILE; x++) {
					const double a = -2.0 * Math::PI * ((double)u * x + (double)v * y) / (double)BN_TILE;
					re += p_err[y * BN_TILE + x] * Math::cos(a);
					im += p_err[y * BN_TILE + x] * Math::sin(a);
				}
			}
			low += re * re + im * im;
		}
	}
	return low / total;
}

static double bn_ratio(uint32_t p_n, bool p_disc) {
	static double blue[64 * 64];
	static double classic[64 * 64];
	bn_error_map(p_n, true, p_disc, blue);
	bn_error_map(p_n, false, p_disc, classic);
	const double r = bn_low_share(blue) / bn_low_share(classic);
	MESSAGE("N=", p_n, (p_disc ? " disc" : " step"), " blue/classic low-frequency share ", r);
	return r;
}
```

Before `} // namespace TestPTSobol`, add:

```cpp
TEST_CASE("[PathTracer][Sobol] morton2d puts x in the odd bits and y in the even bits") {
	CHECK(sb_morton2d(0, 0) == 0u);
	CHECK(sb_morton2d(1, 0) == 2u);
	CHECK(sb_morton2d(0, 1) == 1u);
	CHECK(sb_morton2d(3, 3) == 15u);
	CHECK(sb_morton2d(65535, 65535) == 0xffffffffu);
}

TEST_CASE("[PathTracer][Sobol] base-4 nested scramble keeps 64x64 tiles and 2x2 quads together") {
	const uint32_t seeds[2] = { BN_SEED, 0x12345678u };
	for (uint32_t seed : seeds) {
		static uint32_t v[64 * 64];
		for (uint32_t y = 0; y < BN_TILE; y++) {
			for (uint32_t x = 0; x < BN_TILE; x++) {
				v[y * BN_TILE + x] = sb_nested_uniform_scramble_base4(sb_morton2d(x, y), seed);
			}
		}
		static bool seen[4096];
		for (uint32_t i = 0; i < 4096; i++) {
			seen[i] = false;
		}
		bool high_ok = true;
		for (uint32_t i = 0; i < 4096; i++) {
			high_ok = high_ok && (v[i] >> 12) == (v[0] >> 12);
			seen[v[i] & 4095u] = true;
		}
		int distinct = 0;
		for (uint32_t i = 0; i < 4096; i++) {
			distinct += seen[i] ? 1 : 0;
		}
		CHECK(high_ok);
		CHECK(distinct == 4096);
		bool quads_ok = true;
		for (uint32_t y = 0; y < BN_TILE; y += 2) {
			for (uint32_t x = 0; x < BN_TILE; x += 2) {
				const uint32_t a = v[y * BN_TILE + x];
				const uint32_t b = v[y * BN_TILE + x + 1];
				const uint32_t c = v[(y + 1) * BN_TILE + x];
				const uint32_t d = v[(y + 1) * BN_TILE + x + 1];
				const bool same = (a >> 2) == (b >> 2) && (a >> 2) == (c >> 2) && (a >> 2) == (d >> 2);
				const uint32_t lows = (1u << (a & 3u)) | (1u << (b & 3u)) | (1u << (c & 3u)) | (1u << (d & 3u));
				quads_ok = quads_ok && same && lows == 15u;
			}
		}
		CHECK(quads_ok);
	}
}

TEST_CASE("[PathTracer][Sobol] two scramble seeds give different pixel offsets") {
	int differ = 0;
	for (uint32_t y = 0; y < BN_TILE; y++) {
		for (uint32_t x = 0; x < BN_TILE; x++) {
			const uint32_t m = sb_morton2d(x, y);
			differ += sb_nested_uniform_scramble_base4(m, BN_SEED) != sb_nested_uniform_scramble_base4(m, 0x12345678u) ? 1 : 0;
		}
	}
	CHECK(differ > 4000);
}

TEST_CASE("[PathTracer][Sobol] blue-noise indexing pushes N=16 error out of low frequencies") {
	CHECK(bn_ratio(16, false) < 0.5);
	CHECK(bn_ratio(16, true) < 0.5);
}

TEST_CASE("[PathTracer][Sobol] blue-noise indexing pushes N=24 error out of low frequencies") {
	// 0.6, not the spec's 0.8: at 0.8 a row-major offset (0.63 / 0.72) would pass (plan ruling).
	CHECK(bn_ratio(24, false) < 0.6);
	CHECK(bn_ratio(24, true) < 0.6);
}

TEST_CASE("[PathTracer][Sobol] the classic per-pixel scramble leaves white-noise error") {
	static double err[64 * 64];
	const double white = (double)bn_ring_bins() / (64.0 * 64.0 - 1.0);
	const uint32_t ns[2] = { 16, 24 };
	for (uint32_t n : ns) {
		for (int disc = 0; disc < 2; disc++) {
			bn_error_map(n, false, disc == 1, err);
			const double share = bn_low_share(err) / white;
			CHECK(share > 0.7);
			CHECK(share < 1.3);
		}
	}
}
```

- [ ] **Step 2: Build and run; watch them fail**

Run:
```bash
cd /c/Users/aiadmin/Desktop/Engine_Build_test/Zreal_Engine
W=.superpowers/sdd/2026-10-15-pt-blue-noise-sampling
python -m SCons platform=windows target=editor tests=yes > $W/build_t1_red.log 2>&1; tail -2 $W/build_t1_red.log
bin/godot.windows.editor.x86_64.console.exe --headless --test --test-case="*Sobol*" > $W/t1_red.log 2>&1; grep -a "test cases:" $W/t1_red.log
```
Expected: `scons: done building targets.`, then `[doctest] test cases: 15 | 10 passed | 5 failed`.
- Failing: the morton, scramble, seeds, N=16 and N=24 cases. With the stubs, every pixel gets offset 0: a constant error map, so `bn_low_share` returns 1.0.
- Passing: the 9 existing cases and the classic-white case, which uses only `sb_hash_iqnt2d`, a mirror of existing GLSL.

- [ ] **Step 3: Replace the stubs with the Cycles code, and add the GLSL**

In `test_pt_sobol.cpp`, replace the four stub bodies:

```cpp
static uint32_t sb_pcg_owen_base4(uint32_t p_n, uint32_t p_seed) {
	p_n ^= p_n * 0x3d20adeau;
	p_n ^= (p_n >> 1) & (p_n << 1) & 0x55555555u;
	p_n += p_seed;
	p_n *= (p_seed >> 16) | 1u;
	p_n ^= (p_n >> 1) & (p_n << 1) & 0x55555555u;
	p_n ^= p_n * 0x05526c56u;
	p_n ^= p_n * 0x53a22864u;
	return p_n;
}

static uint32_t sb_nested_uniform_scramble_base4(uint32_t p_i, uint32_t p_seed) {
	return sb_bit_reverse(sb_pcg_owen_base4(sb_bit_reverse(p_i), p_seed));
}

static uint32_t sb_expand_bits(uint32_t p_x) {
	p_x &= 0x0000ffffu;
	p_x = (p_x ^ (p_x << 8)) & 0x00ff00ffu;
	p_x = (p_x ^ (p_x << 4)) & 0x0f0f0f0fu;
	p_x = (p_x ^ (p_x << 2)) & 0x33333333u;
	p_x = (p_x ^ (p_x << 1)) & 0x55555555u;
	return p_x;
}

static uint32_t sb_morton2d(uint32_t p_x, uint32_t p_y) {
	return (sb_expand_bits(p_x) << 1) | sb_expand_bits(p_y);
}
```

Append to `servers/rendering/renderer_rd/shaders/raytracing/sobol_burley_inc.glsl`:

```glsl

// ---------------------------------------------------------------------------
// Blue-noise pixel offsets (spec 2026-10-15-pt-blue-noise-sampling-design.md), verbatim from
// Cycles kernel/sample/util.h:44-77. Mirrored in tests/servers/rendering/test_pt_sobol.cpp.
// ---------------------------------------------------------------------------

/// Base-4 Owen scramble of a bit-reversed integer (Cycles `reversed_bit_owen_base4`).
uint sb_pcg_owen_base4(uint p_n, uint p_seed) {
	p_n ^= p_n * 0x3d20adeau;
	p_n ^= (p_n >> 1u) & (p_n << 1u) & 0x55555555u;
	p_n += p_seed;
	p_n *= (p_seed >> 16u) | 1u;
	p_n ^= (p_n >> 1u) & (p_n << 1u) & 0x55555555u;
	p_n ^= p_n * 0x05526c56u;
	p_n ^= p_n * 0x53a22864u;
	return p_n;
}

/// Hierarchical base-4 shuffle: keeps every aligned 4^k block together (Cycles
/// `nested_uniform_scramble_base4`), so a Morton-ordered 2x2 quad stays a quad.
uint sb_nested_uniform_scramble_base4(uint p_i, uint p_seed) {
	return bitfieldReverse(sb_pcg_owen_base4(bitfieldReverse(p_i), p_seed));
}

/// Spread the low 16 bits to the even positions (Cycles `expand_bits`).
uint sb_expand_bits(uint p_x) {
	p_x &= 0x0000ffffu;
	p_x = (p_x ^ (p_x << 8u)) & 0x00ff00ffu;
	p_x = (p_x ^ (p_x << 4u)) & 0x0f0f0f0fu;
	p_x = (p_x ^ (p_x << 2u)) & 0x33333333u;
	p_x = (p_x ^ (p_x << 1u)) & 0x55555555u;
	return p_x;
}

/// Morton code: x in the odd bits, y in the even bits (Cycles `morton2d`).
uint sb_morton2d(uint p_x, uint p_y) {
	return (sb_expand_bits(p_x) << 1u) | sb_expand_bits(p_y);
}
```

- [ ] **Step 4: Build and run; watch them pass**

Run:
```bash
cd /c/Users/aiadmin/Desktop/Engine_Build_test/Zreal_Engine
W=.superpowers/sdd/2026-10-15-pt-blue-noise-sampling
python -m SCons platform=windows target=editor tests=yes > $W/build_t1.log 2>&1; tail -2 $W/build_t1.log
bin/godot.windows.editor.x86_64.console.exe --headless --test --test-case="*Sobol*" > $W/t1.log 2>&1; grep -a "test cases:\|blue/classic" $W/t1.log
```
Expected: `[doctest] test cases: 15 | 15 passed | 0 failed`. The four `MESSAGE` lines print ratios within about ±0.02 of the prototype (N=16: 0.396 / 0.417; N=24: 0.381 / 0.508).
- If the N=24 disc lands at or above 0.6, STOP and report the four ratios. Do not loosen the threshold.
- `MESSAGE` output shows only for failing cases unless doctest is told otherwise. If the ratios do not print, re-run with `--success` appended and grep again.

- [ ] **Step 5: Full suite, then commit**

```bash
cd /c/Users/aiadmin/Desktop/Engine_Build_test/Zreal_Engine
bin/godot.windows.editor.x86_64.console.exe --headless --test > .superpowers/sdd/2026-10-15-pt-blue-noise-sampling/suite_t1.log 2>&1; grep -a "test cases:" .superpowers/sdd/2026-10-15-pt-blue-noise-sampling/suite_t1.log
git add servers/rendering/renderer_rd/shaders/raytracing/sobol_burley_inc.glsl tests/servers/rendering/test_pt_sobol.cpp
git commit -m "feat(pt): blue-noise helpers -- Cycles' base-4 nested scramble and Morton code, with an error-spectrum test

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
Expected: `1610 | 1610 passed | 0 failed | 3 skipped` (1604 + 6 new).

---

### Task 2: Wire the pattern into the sampler and the setting

**Files:**
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_inc.glsl`:
  - the defines block (lines 22-27 and 52);
  - the RNG section (`rng_pixel_seed` ~487, `rng_1d` ~510, `rng_2d` ~521).
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_common_inc.glsl`: after `get_rt_param()` (~131), plus the `rt_params[11]` comment at 126.
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/scene_raytracing_raygen.glsl`: first line of the raygen `main()` (~417) and of the closest-hit `main()` (~884).
- Modify: `servers/rendering/renderer_rd/forward_clustered/scene_shader_raytracing.h:233`
- Modify: `servers/rendering/renderer_rd/forward_clustered/render_raytracing.cpp`: the `params[44]` comment (~4253) and after the Filter Glossy fill (~4437).
- Modify: `servers/rendering/rendering_server.cpp` (after the `filter_glossy` `GLOBAL_DEF`, ~3906)
- Test: render checks in the workspace (`check_t2.sh`)

**Interfaces:**
- Consumes (Task 1): `sb_nested_uniform_scramble_base4`, `sb_morton2d`.
- Produces:
  - GLSL global `uint g_rt_blue_noise_length` (raytracing_inc.glsl);
  - GLSL `void rt_init_blue_noise()` (raytracing_common_inc.glsl);
  - defines `RT_PARAM_ACCUM_TARGET 7`, `RT_PARAM_SAMPLING_PATTERN 43`;
  - C++ `SceneShaderRaytracing::RT_PARAM_SAMPLING_PATTERN = 43`;
  - project setting `rendering/pathtracer/sampling_pattern` (int, default 1).

- [ ] **Step 1: Write the failing render check**

Create `$W/check_t2.sh`:

```bash
#!/bin/bash
# Task 2 gate: classic must be byte-identical to today's binary, blue must differ, no GLSL errors.
W=/c/Users/aiadmin/Desktop/Engine_Build_test/Zreal_Engine/.superpowers/sdd/2026-10-15-pt-blue-noise-sampling
fail=0
cmp -s $W/base_a/render.png $W/t2_classic/render.png && echo "PASS: classic byte-identical to base" || { echo "FAIL: classic differs from base"; fail=1; }
cmp -s $W/base_a/render.png $W/t2_blue/render.png && { echo "FAIL: blue noise identical to base (pattern not applied)"; fail=1; } || echo "PASS: blue noise differs from base"
for t in t2_classic t2_blue; do
  n=$(grep -c "Error compiling" $W/$t/run.log)
  [ "$n" = "0" ] && echo "PASS: $t 0 compile errors" || { echo "FAIL: $t $n compile errors"; fail=1; }
done
exit $fail
```

Render with TODAY's binary (no code changes yet) and run it:

```bash
W=/c/Users/aiadmin/Desktop/Engine_Build_test/Zreal_Engine/.superpowers/sdd/2026-10-15-pt-blue-noise-sampling
mkdir -p $W/dump_classic $W/dump_blue
bash $W/run_still.sh t2_classic "[rendering];pathtracer/sampling_pattern=0" "ZR_OIDN_DUMP=$(cygpath -w $W/dump_classic)"
bash $W/run_still.sh t2_blue "" "ZR_OIDN_DUMP=$(cygpath -w $W/dump_blue)"
bash $W/check_t2.sh; echo "gate exit=$?"
```

- [ ] **Step 2: Watch it fail**

Expected:
- `PASS: classic byte-identical to base`;
- `FAIL: blue noise identical to base (pattern not applied)`;
- both `0 compile errors`;
- `gate exit=1`.

Today's binary does not know the setting, so both renders equal the base. The blue render is the falsifying case.

- [ ] **Step 3: GLSL: defines, the global, the sampler branches**

In `raytracing_inc.glsl`, replace lines 24-26:

```glsl
// Indices 6-8 are taken by PT_PARAM_OIDN_FLAG, PT_PARAM_ACCUM_TARGET, and
// PT_PARAM_DLSS_RR_FINAL_FLAG (defined C++-side in rendering_server_enums.h);
// they are not read by GLSL, so do not reuse them here.
```

with:

```glsl
// Indices 6-8 are taken by PT_PARAM_OIDN_FLAG, PT_PARAM_ACCUM_TARGET, and
// PT_PARAM_DLSS_RR_FINAL_FLAG (defined C++-side in rendering_server_enums.h); do not
// reuse them here. Only 7 is read by GLSL: the blue-noise sequence length N (spec
// 2026-10-15-pt-blue-noise-sampling-design.md).
#define RT_PARAM_ACCUM_TARGET 7 // rt_params[1].w - accumulation target (samples per pixel on the accumulate route)
```

After `#define RT_PARAM_FILTER_GLOSSY 42 ...` add:

```glsl
#define RT_PARAM_SAMPLING_PATTERN 43 // rt_params[10].w - 1 = Cycles BLUE_NOISE_PURE on the accumulate route, 0 = classic
```

Immediately before `/// Per-pixel scramble seed (Cycles \`path_rng_pixel_init\`, pattern.h:143).` add:

```glsl
/// Blue-noise sequence length N for this invocation (spec 2026-10-15-pt-blue-noise-sampling-design.md);
/// 0 = classic per-pixel Sobol-Burley. rt_params is declared after this file
/// (raytracing_common_inc.glsl), so rt_init_blue_noise() sets this once at the top of the raygen
/// and closest-hit main(); every other stage and shader leaves it 0.
uint g_rt_blue_noise_length = 0u;

```

Replace `rng_pixel_seed`:

```glsl
uint rng_pixel_seed(uvec2 p_pixel) {
	return sb_hash_iqnt2d(p_pixel.x, p_pixel.y) ^ RT_SAMPLER_SEED;
}
```

with (the original line unchanged, behind an early return):

```glsl
uint rng_pixel_seed(uvec2 p_pixel) {
	if (g_rt_blue_noise_length > 0u) {
		// Cycles path_rng_pixel_init (pattern.h:156): this pixel's offset along one shared sequence.
		return sb_nested_uniform_scramble_base4(sb_morton2d(p_pixel.x, p_pixel.y), RT_SAMPLER_SEED);
	}
	return sb_hash_iqnt2d(p_pixel.x, p_pixel.y) ^ RT_SAMPLER_SEED;
}
```

In `rng_1d`, insert as the FIRST statement (before the `// 0xffffffff = maximum sequence length.` comment, which stays):

```glsl
	if (g_rt_blue_noise_length > 0u) {
		// Cycles BLUE_NOISE_PURE (pattern.h:42-47, :79-80): one sequence, seed 0, this pixel's section.
		return sobol_burley_sample_1D(p_rng.sample_index + p_rng.pixel * g_rt_blue_noise_length, p_rng.offset + p_dim, 0u, 0xffffffffu);
	}
```

In `rng_2d`, insert as the FIRST statement:

```glsl
	if (g_rt_blue_noise_length > 0u) {
		return sobol_burley_sample_2D(p_rng.sample_index + p_rng.pixel * g_rt_blue_noise_length, p_rng.offset + p_dim, 0u, 0xffffffffu);
	}
```

In `raytracing_common_inc.glsl`, change the line-126 comment `// F2: 4 -> 10; DoF: 11 (slots 40-41).` to `// F2: 4 -> 10; DoF: 11 (slots 40-41); 42 Filter Glossy, 43 sampling pattern -- full.`, keeping the rest of that line. After the closing `}` of `get_rt_param()` add:

```glsl

/// Blue noise for this invocation (spec 2026-10-15-pt-blue-noise-sampling-design.md): Cycles
/// BLUE_NOISE_PURE with N = the accumulation target, accumulate route only. Called first in the
/// raygen and closest-hit main(); the one-shot variant keeps g_rt_blue_noise_length = 0.
void rt_init_blue_noise() {
#ifdef RT_OIDN_FEATURES
	g_rt_blue_noise_length = (get_rt_param(RT_PARAM_SAMPLING_PATTERN) > 0.5)
			? max(1u, uint(get_rt_param(RT_PARAM_ACCUM_TARGET)))
			: 0u;
#endif
}
```

In `scene_raytracing_raygen.glsl`:
- **Raygen `main()`:** insert `rt_init_blue_noise();` as the first statement, before `uvec2 pixel = gl_LaunchIDEXT.xy;`.
- **Closest-hit `main()`** (the one after `// MAIN`): insert `rt_init_blue_noise();` before `HitData h = compute_hit_data();`.

The custom-material hit groups are cut from this same closest-hit source (`scene_shader_raytracing.cpp:832`, `ch_template`), so they inherit the call.

- [ ] **Step 4: C++: slot, fill, setting**

`scene_shader_raytracing.h`, after line 233 (`RT_PARAM_FILTER_GLOSSY = 42`):

```cpp
	static constexpr int RT_PARAM_SAMPLING_PATTERN = 43; // rendering/pathtracer/sampling_pattern: 1 = blue noise, 0 = classic
```

`render_raytracing.cpp`:
- Change the comment on `float params[44];` to `// F2: 16 -> 40; DoF: 44 (vec4 rt_params[11] in the shader); 42-43 Filter Glossy, sampling pattern -- full`.
- After the Filter Glossy block's closing `}` (before `p_state->accum_enabled = accum_enabled;`) add:

```cpp
		// Blue-noise sampling (spec 2026-10-15-pt-blue-noise-sampling-design.md): Cycles' default for
		// final renders, BLUE_NOISE_PURE, on the accumulate route; 0 = classic per-pixel Sobol-Burley.
		rt_ubo.params[SceneShaderRaytracing::RT_PARAM_SAMPLING_PATTERN] = (int)GLOBAL_GET("rendering/pathtracer/sampling_pattern") == 1 ? 1.0f : 0.0f;
```

`rendering_server.cpp`, after the `filter_glossy` `GLOBAL_DEF`:

```cpp
	// Blue-noise sampling (spec 2026-10-15-pt-blue-noise-sampling-design.md): Cycles' default for
	// final renders (BLUE_NOISE_PURE). Every pixel draws from one shared Sobol sequence at a
	// Morton-curve offset, so its error lands as blue noise. Accumulate (still / video) route.
	GLOBAL_DEF(PropertyInfo(Variant::INT, "rendering/pathtracer/sampling_pattern", PROPERTY_HINT_ENUM, "Classic,Blue Noise"), 1);
```

- [ ] **Step 5: Build**

```bash
cd /c/Users/aiadmin/Desktop/Engine_Build_test/Zreal_Engine
W=.superpowers/sdd/2026-10-15-pt-blue-noise-sampling
python -m SCons platform=windows target=editor tests=yes > $W/build_t2.log 2>&1; tail -2 $W/build_t2.log
grep -c "g_rt_blue_noise_length > 0u" servers/rendering/renderer_rd/shaders/raytracing/scene_raytracing_raygen.glsl.gen.h
```
Expected: `scons: done building targets.` and a count >= 3. Each of the generated header's stage copies contains the three branches.

- [ ] **Step 6: Re-render the pair and watch the gate pass**

```bash
W=/c/Users/aiadmin/Desktop/Engine_Build_test/Zreal_Engine/.superpowers/sdd/2026-10-15-pt-blue-noise-sampling
bash $W/run_still.sh t2_classic "[rendering];pathtracer/sampling_pattern=0" "ZR_OIDN_DUMP=$(cygpath -w $W/dump_classic)"; cat $W/t2_classic/done
bash $W/run_still.sh t2_blue "" "ZR_OIDN_DUMP=$(cygpath -w $W/dump_blue)"; cat $W/t2_blue/done
bash $W/check_t2.sh; echo "gate exit=$?"
```
Expected: four `PASS` lines and `gate exit=0`. Times are in the `done` files; Task 4 compares them.

- [ ] **Step 7: Off is exact (Review Focus 1)**

This is covered by Step 6's first `PASS` (`t2_classic` vs `base_a`, `cmp`, byte-identical). If it says `FAIL`, the classic dataflow changed, so do not commit. Use superpowers:systematic-debugging. The likely cause is a merged expression: re-check that every original line is untouched and the blue code sits in its own early-return branch.

- [ ] **Step 8: The one-shot / DLSS-RR variant compiles (Review Focus 2)**

```bash
W=/c/Users/aiadmin/Desktop/Engine_Build_test/Zreal_Engine/.superpowers/sdd/2026-10-15-pt-blue-noise-sampling
bash $W/run_video.sh t2_dlss "" "ZR_VIDEO_DENOISER=dlssrr" kf215.json; cat $W/t2_dlss/done
grep -c "Error compiling" $W/t2_dlss/run.log; grep -a "\[VideoDenoiser\]" $W/t2_dlss/run.log | head -1; ls $W/t2_dlss | grep -c "frame.*png"
```
Expected: `exit=0`, `0`, `[VideoDenoiser] dlssrr`, and a frame count >= 1. If `nvngx_dlssd.dll` / `sl.*.dll` are missing from `bin/`, DLSS-RR no-ops but the one-shot variant still compiles, which is what this checks.

- [ ] **Step 9: Full suite, commit**

```bash
cd /c/Users/aiadmin/Desktop/Engine_Build_test/Zreal_Engine
bin/godot.windows.editor.x86_64.console.exe --headless --test > .superpowers/sdd/2026-10-15-pt-blue-noise-sampling/suite_t2.log 2>&1; grep -a "test cases:" .superpowers/sdd/2026-10-15-pt-blue-noise-sampling/suite_t2.log
git add servers/rendering/renderer_rd/shaders/raytracing/raytracing_inc.glsl servers/rendering/renderer_rd/shaders/raytracing/raytracing_common_inc.glsl servers/rendering/renderer_rd/shaders/raytracing/scene_raytracing_raygen.glsl servers/rendering/renderer_rd/forward_clustered/scene_shader_raytracing.h servers/rendering/renderer_rd/forward_clustered/render_raytracing.cpp servers/rendering/rendering_server.cpp
git commit -m "feat(pt): blue-noise sampling on the accumulate route -- Cycles BLUE_NOISE_PURE, on by default

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
Expected: `1610 | 1610 passed | 0 failed | 3 skipped`.

---

### Task 3: Keep it out of DLSS-RR video and the path-tracer gates

**Files:**
- Modify: `pipeline_references/video_glb_creation.gd` (`_resolve_video_denoiser`, the `if mode == "dlssrr":` block added by the Filter Glossy work, ~line 113)
- Modify: `pipeline_references/tests/pt_validation.gd` (`_notification`, ~line 22)
- Modify: `servers/rendering/renderer_rd/forward_clustered/scene_shader_raytracing.cpp` (the `RT_OIDN_FEATURES` invariant comment, ~line 806)
- Test: `pipeline_references/tests/filter_glossy_unit.gd` (rewritten to cover both settings)

**Interfaces:**
- Consumes (Task 2): the setting name `rendering/pathtracer/sampling_pattern` (int, 1 = blue, 0 = classic).
- Produces: nothing new for later tasks.

- [ ] **Step 1: Write the failing placement test**

Replace the whole of `pipeline_references/tests/filter_glossy_unit.gd` with:

```gdscript
extends SceneTree

# Preloaded, not global class names: the live pipeline has no class cache.
const VideoGlb = preload("res://video_glb_creation.gd")
const PtValidation = preload("res://tests/pt_validation.gd")

## Headless checks for where Filter Glossy and blue-noise sampling are turned off
## (specs 2026-10-14-pt-filter-glossy-design.md Results, 2026-10-15-pt-blue-noise-sampling-design.md):
##   - the DLSS-RR video route, whose daylight probe runs the accumulate variant while its
##     frames run the one-shot variant that has neither;
##   - the path-tracer gates, whose baselines were measured without them.
##
## Run it from a copy of pipeline_references WITHOUT .godot/ (the repo's class cache has a
## duplicate CustomShapeGenerator):
##   bin\godot.windows.editor.x86_64.console.exe --headless --path <copy> \
##       -s res://tests/filter_glossy_unit.gd

const FILTER_GLOSSY := "rendering/pathtracer/filter_glossy"
const SAMPLING_PATTERN := "rendering/pathtracer/sampling_pattern"

var _failures: Array[String] = []
var _checks := 0


func _check(p_name: String, p_value: float, p_expected: float) -> void:
	_checks += 1
	print("  %s: %s (expected %s)" % [p_name, str(p_value), str(p_expected)])
	if not is_equal_approx(p_value, p_expected):
		_failures.append("%s: %s, expected %s" % [p_name, str(p_value), str(p_expected)])


func _setting(p_name: String) -> float:
	return float(ProjectSettings.get_setting(p_name, -1.0))


func _set_both_on() -> void:
	ProjectSettings.set_setting(FILTER_GLOSSY, 1.0)
	ProjectSettings.set_setting(SAMPLING_PATTERN, 1)


func _video_mode(p_mode: String) -> void:
	_set_both_on()
	OS.set_environment("ZR_VIDEO_DENOISER", p_mode)
	var v = VideoGlb.new()
	v._resolve_video_denoiser()
	OS.unset_environment("ZR_VIDEO_DENOISER")


func _initialize() -> void:
	print("[filter_glossy_unit]")
	_video_mode("dlssrr")
	_check("dlssrr video turns Filter Glossy off", _setting(FILTER_GLOSSY), 0.0)
	_check("dlssrr video uses the classic sampling pattern", _setting(SAMPLING_PATTERN), 0.0)
	_video_mode("oidn")
	_check("oidn video leaves Filter Glossy on", _setting(FILTER_GLOSSY), 1.0)
	_check("oidn video keeps blue-noise sampling", _setting(SAMPLING_PATTERN), 1.0)

	# root joins the tree only after _initialize returns, so the gate's ENTER_TREE (and the
	# check) happen on the first idle frame.
	_set_both_on()
	root.add_child(PtValidation.new())
	_finish.call_deferred()


func _finish() -> void:
	_check("a gate entering the tree pins Filter Glossy off", _setting(FILTER_GLOSSY), 0.0)
	_check("a gate entering the tree pins the classic sampling pattern", _setting(SAMPLING_PATTERN), 0.0)
	if _failures.is_empty():
		print("PASS: all %d placement checks passed." % _checks)
		quit(0)
	else:
		for f in _failures:
			print("FAIL: " + f)
		quit(1)
```

Create `$W/run_unit.sh`. It copies `pipeline_references` scripts with no `.godot/` to the scratch dir and runs one unit script; with `red` as the 2nd argument it swaps in the HEAD versions of the two scripts under test:

```bash
#!/bin/bash
# usage: run_unit.sh <unit script under tests/> [red]
R=/c/Users/aiadmin/Desktop/Engine_Build_test/Zreal_Engine
W=$R/.superpowers/sdd/2026-10-15-pt-blue-noise-sampling
S=$W/unitcopy
rm -rf "$S"; mkdir -p "$S"
(cd $R/pipeline_references && find . -path ./.godot -prune -o \( -name "*.gd" -o -name "*.tscn" -o -name "project.godot" \) -print | while read f; do mkdir -p "$S/$(dirname "$f")"; cp "$f" "$S/$f"; done)
if [ "$2" = "red" ]; then
  git -C $R show HEAD:pipeline_references/tests/pt_validation.gd > "$S/tests/pt_validation.gd"
  git -C $R show HEAD:pipeline_references/video_glb_creation.gd > "$S/video_glb_creation.gd"
  echo "(RED run: HEAD scripts)"
fi
timeout 300 $R/bin/godot.windows.editor.x86_64.console.exe --headless --path "$S" -s res://tests/$1 > "$S/unit.log" 2>&1
code=$?
grep -a "^\[\|^  \|PASS\|FAIL\|SCRIPT ERROR\|Parse Error" "$S/unit.log" | head -30
echo "exit=$code"
```

- [ ] **Step 2: Watch it fail**

Run: `bash $W/run_unit.sh filter_glossy_unit.gd red`
Expected: `FAIL: dlssrr video uses the classic sampling pattern: 1.0, expected 0.0` and `FAIL: a gate entering the tree pins the classic sampling pattern: 1.0, expected 0.0`; the four Filter Glossy checks print as passing; `exit=1`; no `SCRIPT ERROR`.

- [ ] **Step 3: Implement the two pins**

`pipeline_references/video_glb_creation.gd`, replace:

```gdscript
	if mode == "dlssrr":
		ProjectSettings.set_setting("rendering/pathtracer/filter_glossy", 0.0)
```

with:

```gdscript
	if mode == "dlssrr":
		ProjectSettings.set_setting("rendering/pathtracer/filter_glossy", 0.0)
		# Blue-noise sampling (spec 2026-10-15-pt-blue-noise-sampling-design.md) is the same case:
		# accumulate variant only, so the classic pattern keeps the probe byte-identical.
		ProjectSettings.set_setting("rendering/pathtracer/sampling_pattern", 0)
```

`pipeline_references/tests/pt_validation.gd`, replace:

```gdscript
## Every gate's baseline was measured without Filter Glossy, a deliberate bias with its own
## gate (tests/filter_glossy/fg_energy_gate.py; spec 2026-10-14-pt-filter-glossy-design.md),
## so the gates pin it off. A notification, not _ready, so no gate has to call super().
func _notification(p_what: int) -> void:
	if p_what == NOTIFICATION_ENTER_TREE:
		ProjectSettings.set_setting("rendering/pathtracer/filter_glossy", 0.0)
```

with:

```gdscript
## Every gate's baseline was measured without Filter Glossy (a deliberate bias with its own
## gate, tests/filter_glossy/fg_energy_gate.py; spec 2026-10-14-pt-filter-glossy-design.md) and
## with the classic sampling pattern (spec 2026-10-15-pt-blue-noise-sampling-design.md), so the
## gates pin both. A notification, not _ready, so no gate has to call super().
func _notification(p_what: int) -> void:
	if p_what == NOTIFICATION_ENTER_TREE:
		ProjectSettings.set_setting("rendering/pathtracer/filter_glossy", 0.0)
		ProjectSettings.set_setting("rendering/pathtracer/sampling_pattern", 0)
```

`scene_shader_raytracing.cpp`, in the invariant comment, replace:

```cpp
	// The one deliberate exception is Filter Glossy (spec 2026-10-14-pt-filter-glossy-design.md),
	// which changes radiance here by design; video_glb_creation.gd sets filter_glossy to 0.0 for
	// DLSS-RR jobs, which is byte-identical to the variant without it, so the invariant still
	// holds for them.
```

with:

```cpp
	// The two deliberate exceptions are Filter Glossy (spec 2026-10-14-pt-filter-glossy-design.md),
	// which changes radiance here, and blue-noise sampling (spec 2026-10-15-pt-blue-noise-sampling-
	// design.md), which changes the RNG here; video_glb_creation.gd sets filter_glossy to 0.0 and
	// sampling_pattern to 0 for DLSS-RR jobs, which is byte-identical to the variant without them,
	// so the invariant still holds for them.
```

- [ ] **Step 4: Watch it pass, and keep the other unit scripts green**

```bash
bash $W/run_unit.sh filter_glossy_unit.gd
for t in daylight_unit.gd dof_unit.gd glb_autosmooth_unit.gd; do bash $W/run_unit.sh $t | tail -2; done
```
Expected:
- `PASS: all 6 placement checks passed.` and `exit=0`;
- `daylight_unit.gd`: `PASS: all 45 daylight unit checks passed.`;
- `dof_unit.gd`: `PASS: all 18 dof unit checks passed.`;
- `glb_autosmooth_unit.gd`: a `PASS` tail;
- every run `exit=0`, no `SCRIPT ERROR`.

- [ ] **Step 5: Full doctest suite**

```bash
cd /c/Users/aiadmin/Desktop/Engine_Build_test/Zreal_Engine
bin/godot.windows.editor.x86_64.console.exe --headless --test > .superpowers/sdd/2026-10-15-pt-blue-noise-sampling/suite_t3.log 2>&1; grep -a "test cases:" .superpowers/sdd/2026-10-15-pt-blue-noise-sampling/suite_t3.log
```
Expected: `1610 | 1610 passed | 0 failed | 3 skipped`. The C++ change in this task is comment-only, so no rebuild is needed.

- [ ] **Step 6: Commit, staging ONLY this task's hunk of `video_glb_creation.gd`**

The working tree's `video_glb_creation.gd` also carries the owner's unstaged `USE_REFLECTION_PROBE_HOTSPOT_FIX` hunk, which must stay out. Write HEAD's version plus this task's insertion straight to the index:

```bash
cd /c/Users/aiadmin/Desktop/Engine_Build_test/Zreal_Engine
python -I - <<'EOF'
import subprocess
path = "pipeline_references/video_glb_creation.gd"
head = subprocess.run(["git", "show", f"HEAD:{path}"], capture_output=True, check=True).stdout.decode("utf-8")
old = '\t\tProjectSettings.set_setting("rendering/pathtracer/filter_glossy", 0.0)\n\t# T4 test hook'
new = ('\t\tProjectSettings.set_setting("rendering/pathtracer/filter_glossy", 0.0)\n'
       '\t\t# Blue-noise sampling (spec 2026-10-15-pt-blue-noise-sampling-design.md) is the same case:\n'
       '\t\t# accumulate variant only, so the classic pattern keeps the probe byte-identical.\n'
       '\t\tProjectSettings.set_setting("rendering/pathtracer/sampling_pattern", 0)\n'
       '\t# T4 test hook')
assert head.count(old) == 1, "anchor not found in HEAD"
sha = subprocess.run(["git", "hash-object", "-w", "--stdin"], input=head.replace(old, new).encode("utf-8"),
                     capture_output=True, check=True).stdout.decode().strip()
subprocess.run(["git", "update-index", "--cacheinfo", f"100644,{sha},{path}"], check=True)
print("staged", sha)
EOF
git add pipeline_references/tests/pt_validation.gd pipeline_references/tests/filter_glossy_unit.gd servers/rendering/renderer_rd/forward_clustered/scene_shader_raytracing.cpp
git diff --cached pipeline_references/video_glb_creation.gd | grep "^[+-]" | grep -v "^+++\|^---"
git commit -m "fix(pt): keep blue-noise sampling out of DLSS-RR video and the path-tracer gates

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git diff --stat pipeline_references/video_glb_creation.gd
```
Expected:
- the cached diff shows exactly the three `+` lines (two comments plus the `sampling_pattern` call);
- the commit succeeds;
- the final `git diff --stat` still shows the owner's unstaged hunk (`8 +++++++-`).

---

### Task 4: Measure, show the owner, close

**Files:**
- Create: `$W/bn_measure.py` (workspace, not committed)
- Modify: `docs/superpowers/specs/2026-10-15-pt-blue-noise-sampling-design.md` (append "Results 2026-10-15")

**Interfaces:**
- Consumes: `t2_classic`, `t2_blue` (4K renders with dumps `dump_classic`, `dump_blue`) from Task 2; `kf215.json`, `j209_fhd.json` from the harness.
- Produces: the owner's decision, recorded in the spec.

- [ ] **Step 1: Render the measurement set (background, about 2 hours)**

```bash
W=/c/Users/aiadmin/Desktop/Engine_Build_test/Zreal_Engine/.superpowers/sdd/2026-10-15-pt-blue-noise-sampling
CLASSIC="[rendering];pathtracer/sampling_pattern=0"
mkdir -p $W/dump_floor $W/fdump_classic $W/fdump_blue $W/fdump_ref $W/vdump_classic $W/vdump_blue $W/vdump_ref
bash $W/run_still.sh floor_classic "$CLASSIC" "ZR_SEED_OFFSET=256 ZR_OIDN_DUMP=$(cygpath -w $W/dump_floor)"; echo "floor $(cat $W/floor_classic/done)"
bash $W/run_still.sh fhd_classic "$CLASSIC" "ZR_OIDN_DUMP=$(cygpath -w $W/fdump_classic)" j209_fhd.json; echo "fhd_classic $(cat $W/fhd_classic/done)"
bash $W/run_still.sh fhd_blue "" "ZR_OIDN_DUMP=$(cygpath -w $W/fdump_blue)" j209_fhd.json; echo "fhd_blue $(cat $W/fhd_blue/done)"
bash $W/run_still.sh fhd_ref "$CLASSIC" "ZR_PT_ACCUM_TARGET=2048 ZR_OIDN_DUMP=$(cygpath -w $W/fdump_ref)" j209_fhd.json; echo "fhd_ref $(cat $W/fhd_ref/done)"
bash $W/run_video.sh v_classic "$CLASSIC" "ZR_OIDN_DUMP=$(cygpath -w $W/vdump_classic)"; echo "v_classic $(cat $W/v_classic/done)"
bash $W/run_video.sh v_blue "" "ZR_OIDN_DUMP=$(cygpath -w $W/vdump_blue)"; echo "v_blue $(cat $W/v_blue/done)"
bash $W/run_video.sh v_ref "$CLASSIC" "ZR_VIDEO_ACCUM_TARGET=1024 ZR_OIDN_DUMP=$(cygpath -w $W/vdump_ref)" kf215.json; echo "v_ref $(cat $W/v_ref/done)"
for t in floor_classic fhd_classic fhd_blue fhd_ref v_classic v_blue v_ref; do echo "$t errors=$(grep -c 'Error compiling' $W/$t/run.log) $(grep -a -o 'target=[0-9]* frames' $W/$t/run.log | head -1)"; done
```
Expected:
- every `exit=0`, every `errors=0`;
- the stills' `[PhaseA]` lines read `target=256 frames`, except `fhd_ref`, which reads `target=2048 frames`;
- each `*dump*` dir holds `oidn_color.pfm` and `oidn_output.pfm`;
- `head -2` of `fdump_*/oidn_color.pfm` reads `PF` / `1920 1080` (FHD honoured).

- [ ] **Step 2: Pass/fail: brightness and time (Review Focus 3, 4)**

Create `$W/bn_measure.py`:

```python
"""Blue-noise measurement (spec 2026-10-15, Testing). usage: python bn_measure.py <workspace dir>"""
import glob, os, sys
import numpy as np
from PIL import Image
W = sys.argv[1]
K = np.array([0.2126, 0.7152, 0.0722], np.float32)
def pfm(p):
    with open(p, "rb") as f:
        assert f.readline().strip() in (b"PF", b"Pf")
        w, h = map(int, f.readline().split()); s = float(f.readline())
        a = np.fromfile(f, dtype="<f4" if s < 0 else ">f4").reshape(h, w, 3)
    return np.flipud(a)
def lum(d, name="oidn_color.pfm"): return pfm(os.path.join(W, d, name)) @ K
def box4(l):
    h, w = l.shape[0] // 4 * 4, l.shape[1] // 4 * 4
    return l[:h, :w].reshape(h // 4, 4, w // 4, 4).mean(axis=(1, 3))
def blur(img, sigma=3.0):  # Gaussian via FFT (no scipy on this machine)
    fy = np.fft.fftfreq(img.shape[0])[:, None]; fx = np.fft.rfftfreq(img.shape[1])[None, :]
    g = np.exp(-2.0 * np.pi ** 2 * sigma ** 2 * (fx ** 2 + fy ** 2))
    return np.fft.irfft2(np.fft.rfft2(img) * g, s=img.shape)
def disp(l, scale): x = l * scale; return x / (1.0 + x)
def errors(cand, ref):
    scale = 0.18 / np.median(box4(ref))  # plan ruling: median-normalised display
    d = disp(cand, scale) - disp(ref, scale)
    return float(np.sqrt(np.mean(blur(d) ** 2))), float(np.sqrt(np.mean(d ** 2)))
def secs(d): return int(open(os.path.join(W, d, "done")).read().split("secs=")[1])
mode = sys.argv[2] if len(sys.argv) > 2 else "all"
if mode in ("all", "pass"):
    c, b, f = lum("dump_classic"), lum("dump_blue"), lum("dump_floor")
    def rel(a, r): return 100.0 * (a / r - 1.0)
    fm, fmed = abs(rel(f.mean(), c.mean())), abs(rel(np.median(box4(f)), np.median(box4(c))))
    bm, bmed = rel(b.mean(), c.mean()), rel(np.median(box4(b)), np.median(box4(c)))
    lim_m, lim_med = max(2 * fm, 1.0), max(2 * fmed, 1.0)
    sc, sb = int((c > 200).sum()), int((b > 200).sum())
    tc, tb = secs("t2_classic"), secs("t2_blue")
    checks = [("mean", abs(bm) <= lim_m, f"{bm:+.2f}% (floor {fm:.2f}%, limit {lim_m:.2f}%)"),
              ("box4 median", abs(bmed) <= lim_med, f"{bmed:+.2f}% (floor {fmed:.2f}%, limit {lim_med:.2f}%)"),
              ("no new >200 spikes", sb <= sc + 2, f"classic {sc} blue {sb}"),
              ("time within +2%", tb <= tc * 1.02, f"classic {tc} s blue {tb} s")]
    for n, ok, v in checks: print(f"{'PASS' if ok else 'FAIL'}: {n}: {v}")
if mode in ("all", "benefit"):
    for tag, cdir, bdir, rdir in (("still FHD 256 spp", "fdump_classic", "fdump_blue", "fdump_ref"),
                                  ("video last frame 24 spp", "vdump_classic", "vdump_blue", "vdump_ref")):
        ref = lum(rdir)
        for kind, name in (("raw", "oidn_color.pfm"), ("denoised", "oidn_output.pfm")):
            ec, eb = errors(lum(cdir, name), ref), errors(lum(bdir, name), ref)
            print(f"{tag} {kind:8s}: blotch classic {ec[0]:.5f} blue {eb[0]:.5f} ({100*(eb[0]/ec[0]-1):+.1f}%)   "
                  f"full classic {ec[1]:.5f} blue {eb[1]:.5f} ({100*(eb[1]/ec[1]-1):+.1f}%)")
    for t in ("v_classic", "v_blue"):
        fr = [np.asarray(Image.open(p).convert("RGB")).astype(np.float32) @ K for p in sorted(glob.glob(os.path.join(W, t, "frame*.png")))[-12:]]
        print(f"{t}: mean frame-to-frame change {np.mean([np.abs(fr[i+1]-fr[i]).mean() for i in range(len(fr)-1)]):.3f} levels, {secs(t)} s")
```

Run: `python -I $W/bn_measure.py "$(cygpath -w $W)" pass`
Expected: four `PASS` lines.
- A `FAIL` on mean or median means blue noise changed brightness, which it must not. Stop and use superpowers:systematic-debugging. Suspects: wrong N, or samples past N.
- A `FAIL` on time: re-render both once (warm cache) before concluding.

- [ ] **Step 3: Benefit numbers**

Run: `python -I $W/bn_measure.py "$(cygpath -w $W)" benefit`
Expected: no fixed pass value. Record every line in the ledger.
- The raw blotch error should be clearly lower for blue on both still and video; that is where the pattern acts directly. If it is not, the pattern is not reaching the GPU even though the unit test passes. Stop and debug.
- The denoised lines are the decision numbers.

- [ ] **Step 4: Crops and the video clip**

```bash
W=/c/Users/aiadmin/Desktop/Engine_Build_test/Zreal_Engine/.superpowers/sdd/2026-10-15-pt-blue-noise-sampling
python -I - "$(cygpath -w $W)" <<'EOF'
import sys, os, numpy as np
from PIL import Image, ImageDraw
W = sys.argv[1]
sys.path.insert(0, W); sys.argv = [sys.argv[0], W, "none"]
from bn_measure import pfm, box4, K
R = {"table_vase": (1710, 1170, 2520, 1680), "floor_rug": (660, 1620, 1500, 2160), "window_glass": (1590, 615, 2490, 1215),
     "tv_glossy": (375, 570, 900, 1200), "chrome_balls": (420, 1380, 705, 1605)}
png = {t: Image.open(os.path.join(W, d, "render.png")).convert("RGB") for t, d in (("classic", "t2_classic"), ("blue", "t2_blue"))}
raw = {}
for t, d in (("classic", "dump_classic"), ("blue", "dump_blue")):
    a = pfm(os.path.join(W, d, "oidn_color.pfm")); s = 0.18 / np.median(box4(pfm(os.path.join(W, "dump_classic", "oidn_color.pfm")) @ K))
    a = a * s; a = a / (1 + a); raw[t] = Image.fromarray((np.clip(a, 0, 1) ** (1 / 2.2) * 255 + 0.5).astype(np.uint8))
for k, box in R.items():
    for src, kind in ((png, "final"), (raw, "raw")):
        a, b = src["classic"].crop(box), src["blue"].crop(box); w, h = a.size
        out = Image.new("RGB", (2 * w + 12, h + 34), (255, 255, 255)); out.paste(a, (0, 34)); out.paste(b, (w + 12, 34))
        dr = ImageDraw.Draw(out); dr.text((6, 8), f"{kind}  CLASSIC", fill=(0, 0, 0)); dr.text((w + 18, 8), f"{kind}  BLUE NOISE", fill=(0, 0, 0))
        out.save(os.path.join(W, f"bn_{kind}_{k}.png"))
off = sorted(f for f in os.listdir(os.path.join(W, "v_classic")) if f.startswith("frame") and f.endswith(".png"))[-12:]
os.makedirs(os.path.join(W, "sbs"), exist_ok=True)
for i, f in enumerate(off):
    A = Image.open(os.path.join(W, "v_classic", f)).convert("RGB").crop((1100, 1080, 2380, 2160))
    B = Image.open(os.path.join(W, "v_blue", f)).convert("RGB").crop((1100, 1080, 2380, 2160))
    out = Image.new("RGB", (2 * 1280 + 8, 1080 + 40), (255, 255, 255)); out.paste(A, (0, 40)); out.paste(B, (1288, 40))
    dr = ImageDraw.Draw(out); dr.text((10, 12), "CLASSIC (24 spp + OIDN, 1:1 pixels)", fill=(0, 0, 0)); dr.text((1298, 12), "BLUE NOISE", fill=(0, 0, 0))
    out.save(os.path.join(W, "sbs", f"f{i:03d}.png"))
EOF
/c/Zlendo2026/ZlenderRender_stage_copy/ffmpeg/bin/ffmpeg.exe -y -loglevel error -stream_loop 3 -framerate 12 -i $W/sbs/f%03d.png -c:v libx264 -pix_fmt yuv420p -crf 14 $W/bn_video_compare.mp4
python -I $W/bn_measure.py "$(cygpath -w $W)" benefit | grep "frame-to-frame"
ls $W/bn_*.png $W/bn_video_compare.mp4 | wc -l
```
Expected:
- the count `11`: 10 crops and the clip;
- the two frame-to-frame lines within about 1% of each other (Review Focus 5; classic measured 6.735 levels on 2026-10-14 with Filter Glossy off; with it on, expect about 6.72).

Look at the crops: blue should show finer, more even grain in the raw crops; the final crops should be near-identical or slightly cleaner. The window and TV must not change in brightness.

- [ ] **Step 5: Show the owner and ask**

`SendUserFile` the `bn_raw_table_vase.png`, `bn_final_table_vase.png`, `bn_final_floor_rug.png` crops and `bn_video_compare.mp4` (absolute paths). Then ask with `AskUserQuestion`, quoting the Step 2-3 numbers. Options:

- **Ship on (default 1)**
- **Ship off (default 0)**: keeps the code, renders byte-identical to today.
- **Try ROUND for video**: N rounded to 32; a follow-up spec.

If the denoised blotch error did not improve, recommend "Ship off" and say so plainly (spec, "Stated expectation").

- [ ] **Step 6: Record and commit**

Append "Results 2026-10-15" to the spec:
- the Task 1 ratios;
- the off byte-identity;
- the brightness and time results with the floor;
- the benefit table (raw and denoised, still and video, blotch and full);
- the frame-to-frame numbers;
- the DLSS-RR compile check;
- the owner's decision;
- the three plan rulings.

If the owner chose "Ship off":
- change the `GLOBAL_DEF` default to `0`;
- rebuild (`tests=yes`);
- render `bash $W/run_still.sh t4_default` and `cmp` it against `base_a` (byte-identical required);
- run the full suite.

Commit:
```bash
git add docs/superpowers/specs/2026-10-15-pt-blue-noise-sampling-design.md
git commit -m "docs(spec): blue-noise sampling -- measured results and the owner's ship decision

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
(plus `servers/rendering/rendering_server.cpp` if the default changed). The owner copies the binary to production (`godot/bin/`) themselves. Production's `video_glb_creation.gd` needs Task 3's three added lines only for DLSS-RR video; offer to copy them in, backing up first.
