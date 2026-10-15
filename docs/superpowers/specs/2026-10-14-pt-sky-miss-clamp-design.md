# Sky miss clamp: clamp the sky a bounce ray reaches, with Cycles' bounce rule

**Date:** 2026-10-14. **Status:** spec approved by the owner on 2026-10-14. **Scope:** engine
only (one expression in the miss stage) plus one GPU gate and a comment in
`pipeline_references/image_glb_creation.gd`. Nothing under `C:\Zlendo2026` changes until the
owner decides to ship.

## Intent

**Owner's words / decisions (2026-10-14):**
- Add Cycles' clamp to the sky contribution in the miss stage. Every other contribution site already
  uses `clamp_contribution(..., clamp_limit)`.
- **Cycles' rule** (`bounce - 1`, below), chosen over the task's first wording `total_bounces == 0`
  once reading the counter showed that `total_bounces == 0` is not "the camera sees the sky".
- The emissive-hit clamp has the same off-by-one versus Cycles. That is a **follow-up**, not this
  change, so the job 209 A/B measures one thing.
- The camera's own view of the sky is unchanged when `clamp_direct` is 0.
- Measure before proposing to ship: job 209 still with `ZR_OIDN_DUMP`, raw dumps before and after.

**Why:** the miss stage adds `ps.throughput * sky_color * mis_w` unclamped
(`scene_raytracing_raygen.glsl:752-766`). The Filter Glossy work (spec
`2026-10-14-pt-filter-glossy-design.md`, Results) found single-pixel spikes on job 209 of 100-215
raw at 256 spp (one sample ~5e4) that `clamp_indirect` 10 never touched. Those spikes came from bounce rays
sent to the HDR sky at MIS weight 1 through a transmissive lobe (`RT_MIS_PDF_NONE`). The pipeline
has carried this as a "KNOWN OPEN ITEM" since the clamp was enabled
(`image_glb_creation.gd:1314`). Only the environment-NEE half of a sky hit is clamped, so the two
MIS strategies estimate different integrands.

## Cycles' rule (read from source, `intern/cycles/kernel`)

- `film/light_passes.h:630-638` `film_write_background`: `contribution = throughput * L`, then
  `film_clamp_light(kg, &contribution, INTEGRATOR_STATE(state, path, bounce) - 1)`. Surface
  emission (`:688`) and volume emission (`:668`) use the same `bounce - 1`.
- `film/light_passes.h:495` (direct light / NEE): `film_clamp_light(kg, &contribution,
  INTEGRATOR_STATE(state, shadow_path, bounce))`. That is the bounce of the vertex doing NEE.
- `film/light_passes.h:126-147` `film_clamp_light`: `limit = (bounce > 0) ?
  sample_clamp_indirect : sample_clamp_direct`. If `reduce_add(fabs(L)) > limit`, then
  `L *= limit / sum`.
- `integrator/path_state.h:116-143,238`: a transparent pass-through increments only
  `transparent_bounce` and returns early. Every other scatter, refraction included, does
  `bounce + 1`.

So Cycles classifies a background hit by **the vertex that cast the ray**. This is the same class as
that vertex's own NEE, so both MIS halves of a sky hit share one limit. Camera rays (`bounce` 0,
giving -1) and the first surface's bounce rays (`bounce` 1, giving 0) take `sample_clamp_direct`;
only later bounces take the indirect limit.

## Our counters (read from source)

- `raytracing_inc.glsl:276-322`: `total_bounces` is bits 0-7 of `packed_bounces_flags`.
  - `inc_diffuse_bounce` / `inc_glossy_bounce` add 1 to it.
  - `inc_transmission_bounce` adds 1 to it **and** to the 4-bit transmission counter. It is called
    for both the transparent pass-through (`raytracing_closest_hit_common_inc.glsl:1600`) and the
    transmissive lobe (`:2616`).
- `raytracing_closest_hit_common_inc.glsl:1545,1632-1634`: at a hit, `clamp_limit` is direct iff
  `total_bounces == 0`. That limit governs that vertex's NEE (`:1975`, `:2118`, `:2149`) and the
  emission it was reached by (`:1690`).
- At the miss, `total_bounces` includes the bounce that produced the ray. The vertex that cast it
  had `total_bounces - 1` (or is the camera, at 0).
- The flags word has no free bit (`raytracing_inc.glsl:94-98`). A new payload word cost the
  DLSS-RR one-shot path 2.9% per frame (`raytracing_inc.glsl:107-110`).

Consequences:
- `total_bounces == 0` at the miss means only "a camera ray that met nothing".
- Job 209's windows are solid refracting glass (`_apply_glb_transmissive_glass`, `thickness 0.05`).
  The camera's view of the sky through one reaches the miss at total 2: two refractions. Cycles
  also counts 2 there, so the view through solid glass takes the indirect limit in Cycles too.

## Design

### 1. Engine: clamp the miss-stage sky contribution (`scene_raytracing_raygen.glsl`)

Replace the unclamped assignment at line 752:

```glsl
	// <comment: see the bullet list below>
	const float sky_clamp = (get_total_bounces(ps.packed_bounces_flags) <= 1u)
			? get_rt_param(RT_PARAM_CLAMP_DIRECT)
			: get_rt_param(RT_PARAM_CLAMP_INDIRECT);
	vec3 sky_contribution = clamp_contribution(ps.throughput * sky_color * mis_w, sky_clamp);
```

- The value is used by both the release path (`:766`) and the `VIS_MODE == 0` debug path (`:760`).
  The other debug modes overwrite `ps.radiance` and are unaffected.
- **The comment at the site** must say:
  - Cycles' `film_write_background` clamps with `bounce - 1` (`kernel/film/light_passes.h:638`);
  - the limit belongs to the vertex that cast the ray, the same class as that vertex's own NEE
    clamp (`shade_and_bounce`'s `clamp_limit`);
  - the camera ray (0) and the first surface's bounce ray (1) are direct;
  - **the deviation:** our `total_bounces` also counts transparent pass-throughs. A pass-through
    between the casting vertex and the sky moves the hit to the indirect limit where Cycles keeps
    it direct. Exact parity needs a payload bit we do not have;
  - the emissive-hit site (`raytracing_closest_hit_common_inc.glsl:1632`) still uses
    `total_bounces == 0` and is a filed follow-up.
- `clamp_contribution` stays max-channel (`raytracing_inc.glsl:719-725`), as at every other site of
  ours. Cycles uses the channel sum. That is a pre-existing difference shared by all sites, and this
  change does not touch it.
- **Invariants:**
  - With `clamp_direct == clamp_indirect == 0`, `clamp_contribution` returns its argument, so the
    output is byte-identical to the pre-change binary. This covers DLSS-RR video and every gate,
    all of which default the clamps to 0 (`environment.h:234,237`).
  - With production's 0/10, every miss at total 0 or 1 is byte-identical.
- No payload, C++ or script change. A full SCons build regenerates the `.glsl.gen.h`.

### 2. Comment: `pipeline_references/image_glb_creation.gd` KNOWN OPEN ITEM

Rewrite the block at `:1314` to say the miss half is now clamped with Cycles' `bounce - 1` rule.
Name this spec, and keep the one remaining asymmetry: the alpha pass-through deviation. The live
copy under `C:\Zlendo2026` is updated only if the owner ships.

### 3. GPU gate: `pipeline_references/tests/pt_sky_clamp_gate.gd` (+ `_scene.tscn`)

- **Scaffolding** is copied from `pt_shadow_visibility_gate.gd`:
  - `extends "res://tests/pt_validation.gd"`, which pins `filter_glossy` to 0;
  - a 256x256 window, `_render_accum` (the linear accumulator, not the viewport, so no project AA);
  - `_measure_crop(0.35, 0.65)`;
  - `_new_env` with a uniform `FORMAT_RGBF` panorama, here of radiance **`SKY := 1000.0`**.
- **Each check** renders the same scene twice, with clamps 0/10 and 0/0, and asserts the ratio of
  crop means.

| Check | Scene | total at the miss | Assert | Pre-change binary |
|---|---|---|---|---|
| S1 camera sees sky | no geometry in view | 0 | 1.0 +- 0.001 | 1.0 (guard) |
| S3 sky through one alpha pane | BLEND pane, alpha 0, built as in `pt_transparent_alpha_gate.gd` | 1 | 1.0 +- 0.001 | 1.0 (guard) |
| F1 first-bounce sky | open grey floor, `max_bounces` 1 | 1 | 1.0 +- 0.01 | 1.0 (pins the rule) |
| S2 sky through solid glass | box slab, transmission 1, thickness 0.05, roughness 0, IOR 1.5, `metallic_specular` 0.5 (as `_apply_glb_transmissive_glass`), `max_bounces` 4 | 2 | <= 0.5 | ~1.0: **RED** |

- **S2's expected value.** A front-face reflection is total 1, so it stays unclamped: about 0.04 x
  1000. The transmitted share (~0.92) is cut to 10 per sample, so the ratio is about
  (40 + 9) / 1000 = 0.05. The bound 0.5 leaves a wide margin either way.
- **F1's counterfactual.** Each bounce-ray sample is about 0.214 (linear albedo of sRGB 0.5) x 1000
  x w (its MIS weight), far above 10. So under the rejected `total_bounces == 0` rule the floor
  loses most of that half, and the ratio falls well below 0.99.
- **The gate must be shown to fail on F1, not argued.**
  1. Build once with `== 0u` in place of `<= 1u` and run the gate: F1 must FAIL.
  2. Restore the rule, rebuild, and confirm GREEN.

  Record both readings in the gate's header comment.
- **S2 is RED on the pre-change binary.** Run the gate on the backed-up binary first to confirm.

### 4. Measurement on job 209, with the verdict rule fixed before measuring

**Run setup.**
- Recipe: `.superpowers/sdd/2026-10-08-video-parity/prodab/run_still.sh`, copied to
  `.superpowers/sdd/2026-10-14-sky-miss-clamp/`.
- It copies the production scripts and never touches the production folder.
- Job input: `j209_input.json`, at production settings (256 spp, `clamp_indirect` 10,
  `clamp_direct` 0).
- Before every run: `tasklist | grep -i godot` must be empty, and `query session` is recorded (the
  desktop session decides determinism).
- Runs go through the harness's own background runner, never a shell `&`.

| Run | Binary | Env | Purpose |
|---|---|---|---|
| R1 | pre-change (backup) | `ZR_OIDN_DUMP` | before |
| R2 | pre-change (backup) | `ZR_OIDN_DUMP` | same-binary repeat: the run-to-run spread |
| R3 | new | `ZR_OIDN_DUMP` | after |
| R4 | pre-change | `ZR_PT_CLAMP_INDIRECT=0 ZR_PT_ACCUM_TARGET=64 ZR_OIDN_DUMP` | off, before |
| R5 | new | same as R4 | off, after |

**Reported for each run**, on the luminance of the raw `oidn_color.pfm` (pre-exposure; the daylight
probe re-meters the PNG):
- the number of pixels above 50 and above 200, and the top 10 values with their positions, matched
  across runs to say which disappeared;
- the mean, and the median of 4x4 box averages;
- the `[Daylight]` probe's exposure line, the PNG mean luma, and the render time;
- the three window regions located on R1's PNG: raw crop means, plus before/after crop images
  (PNG) for the owner.

**Verdict** (fixed now, not rewritten after measuring):
- **V1, off is exact.** R4 and R5 are byte-identical, both the raw dump and the PNG. On failure,
  stop: something other than the clamp changed.
- **V2, spikes.** The counts above 50 and above 200 drop by more than the R1-R2 difference. If they
  do not, the report says so plainly: job 209's remaining spikes are not sky reached by a bounce
  ray. The 100-215 spikes in Intent were measured on the blurred-glass build; the shipped build had
  18 pixels above 50 and 1 above 200. Gate S2 is the proof of the mechanism either way.
- **V3, no bias.** The R3 raw mean and box-4 median are within 2% of R1, the `fg_energy_gate.py`
  band. A small drop is expected: the clamp removes energy from rare high samples, by design.
- **V4, windows.** Raw window-crop means are within 2% of R1, and the PNG crops look the same,
  unless the sun disc itself is in view.
- **The ship decision is the owner's**, made from these numbers.

### 5. Logistics

- Work in the main checkout (`C:\Users\aiadmin\Desktop\Engine_Build_test\Zreal_Engine`) on
  `vijay_PTEngine_v32_RenderQlty7`. The app's worktree sessions are stock Godot with no path tracer.
- Commit only this work's files, by path. The uncommitted `pipeline_references/video_glb_creation.gd`
  edit there is not part of this work and stays untouched. No push.
- Before the first build, back up `bin/godot.windows.editor.x86_64.exe` and `.console.exe` as
  `*.pre_skyclamp.exe`. Build with `python -m SCons platform=windows target=editor arch=x86_64
  d3d12=no`, plus `tests=yes` if the current binary was built with it. Check before building, since
  a config switch costs 20+ minutes.
- Nothing under `C:\Zlendo2026` changes. Shipping the binary and the comment is the owner's call
  after section 4.

## Out of scope / follow-ups

- **The emissive-hit clamp** (`raytracing_closest_hit_common_inc.glsl:1632`): the same
  `bounce - 1` fix, measured on a night job. It will be proposed as its own task.
- **The alpha pass-through deviation:** this would need a payload bit or a counter change. Not
  planned.
- **Max-channel versus channel-sum clamping**, at every site.
- **Fog in-scatter**, which is not routed through `clamp_contribution`.
