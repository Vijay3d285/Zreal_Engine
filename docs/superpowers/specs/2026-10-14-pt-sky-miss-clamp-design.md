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
  - **Superseded by the 2026-10-15 amendment (end of this spec):** measured, both hold only to
    within 1 ULP, not byte for byte; the owner accepted that.
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

## Results 2026-10-15

Measured in the main checkout, with session 2 Active for every run. Ledger:
`.superpowers/sdd/2026-10-14-pt-sky-miss-clamp/progress.md`; runs, `measure.txt` and crops:
`.superpowers/sdd/2026-10-14-sky-miss-clamp/` (both git-ignored).

**Gate** (`pipeline_references/tests/pt_sky_clamp_gate.gd`, ratio of crop means, clamps 0/10 over 0/0):

| Binary | S1 | S3 | F1 | S2 | Result |
|---|---|---|---|---|---|
| pre-change | 1.000000 | 1.000000 | 1.000001 | 1.000000 | FAIL (S2) |
| fault, `== 0u` | 1.000000 | 0.010000 | 0.234869 | 0.010000 | FAIL (S3, F1) |
| this rule, `<= 1u` | 1.000000 | 1.000000 | 1.000001 | 0.049615 | PASS |

The S1 guard (sky over limit) read 100 on all three.

**Job 209**, luminance of the raw `oidn_color.pfm` at 4K:

| Run | Binary | Env | > 50 | > 200 | Mean | Box-4 median | Exposure | PNG luma | Time |
|---|---|---|---|---|---|---|---|---|---|
| R1 | pre-change | production, 256 | 18 | 0 | 0.04309 | 0.00868 | 24.437 | 117.68 | 507 s |
| R2 | pre-change | production, 256 | 18 | 0 | 0.04309 | 0.00868 | 24.437 | 117.68 | 501 s |
| R3 | new | production, 256 | 15 | 0 | 0.04270 | 0.00867 | 24.433 | 117.59 | 537 s |
| R4 | pre-change | clamp 0, 64 | 34 | 2 | 0.04324 | 0.00876 | 24.452 | 117.81 | 262 s |
| R5 | new | clamp 0, 64 | 34 | 2 | 0.04324 | 0.00876 | 24.452 | 117.81 | 265 s |
| R6 (diagnostic) | pre-change source, this build's config | clamp 0, 64 | byte-identical to R4 | | | | 24.452 | | 322 s |

R1 and R2 are byte-identical, raw dump and PNG, so the run-to-run spread is 0. R3's extra time
is mostly in the daylight probe (69 s against 55 s), which was the new binary's first job.

**Verdict**, by the rules fixed in section 4:
- **V1 FAIL.** R4 and R5 differ in 9164 pixels (0.110%). Each differs by at most 1.19e-7 raw (3e-7
  relative, 1 ULP), the luminance sum is unchanged, and 615 PNG pixels differ by 1 level. R6,
  the pre-change shader built with this change's `d3d12=no` config, is byte-identical to R4, so
  the build config is not the cause. The new expression's code shape changes float rounding at
  0/0, although `clamp_contribution` returns its argument there; the most likely mechanism is
  multiply-add contraction. So section 1's invariant ("byte-identical to the pre-change binary"
  at 0/0) does not hold. DLSS-RR video and the gates, all at 0/0, will drift by 1 ULP on about
  0.1% of pixels. Per the rule, work stopped here and the owner decides.
- **V2 split.** Above 50: 18 -> 15, a drop of 3 against a spread of 0, so PASS. Above 200: 0 -> 0,
  FAIL as written, because R1 had no pixel above 200 to remove (the shipped Filter Glossy build
  had 1). Job 209's remaining bright spikes are not sky reached by a bounce ray: R1's ten
  brightest pixels (192, 184, 104, ...) are unchanged in R3. Gate S2 proves the mechanism.
- **V3 PASS.** Mean -0.90%, box-4 median -0.03%.
- **V4 PASS.** The three window panes' raw crop means are unchanged (+0.00%), and the PNG crops look
  the same (`crops/all_windows_R1_vs_R3.png`). No sun disc is in view.

**What the clamp removed.** No pixel rose. 244 pixels dropped by more than 1 raw, and 390 by
more than 0.1. They are isolated speckles, such as (2239, 605) 60.44 -> 0.06: single sky samples
of about 1.5e4 reached at total >= 2. They are spread over the room and densest on the right-hand
sofa. Their sum is the -0.90% in the mean.

**Not measured.**
- OIDN video jobs. Their windows are an alpha closure, so sky reached through a pane from a
  bounce vertex is now clamped there too.
- The DLSS-RR one-shot variant. Per V1, it is not byte-identical at 0/0 either.

**Build note.** The pre-change binary had been built with D3D12. This change was built with the
instructed `d3d12=no` (176 MB against 186 MB), and R6 shows that this does not change rendering.

## Amendment 2026-10-15, approved by the owner: the clamps-0/0 drift is accepted

**Owner's decision (2026-10-15):** accept the 1-ULP drift at clamps 0/0. Record it here as an
amendment. V1 stays FAIL in the record above, because the rule fixed in section 4 was not met; this
section changes what is accepted, not what was measured.

- **What replaces section 1's first invariant.** At clamps 0/0 the output is no longer
  byte-identical to the pre-change binary, but it is equal within 1 ULP. On job 209 that is 0.110%
  of pixels, at most 1.19e-7 raw, with the luminance sum unchanged and 615 PNG pixels off by one
  level. The second invariant (production 0/10, misses at total 0 or 1) was not measured
  separately; read it the same way, as equal within the same rounding.
- **Why it is accepted.** R6 rules out the build configuration, so the cause is how the new
  expression compiles. Restoring exactness would mean restructuring the shader in the hope that
  the compiler fuses it as before. That is not guaranteed, and it costs a build and a render.
- **Where it shows.** DLSS-RR video and every path-tracer gate run at 0/0. They inherit the drift.
  Any later "off is exact" A/B must use a post-change binary as its baseline, not one built before
  `5e92275328`.
- **Not attempted:** a uniform branch around the clamp to restore the old code shape at 0/0.

## OIDN video results 2026-10-15, and the ship

**Why measured:** the owner asked for it before shipping. "Not measured" above listed OIDN video:
there, windows are an alpha closure, so sky reached through a pane from a bounce is clamped too.

**Setup.** Job 216 keyframes 204-215 (`.superpowers/sdd/2026-10-14-video-fill-grid/seg204.json`:
12 frames, 4K, day, OIDN, 24 spp, `clamp_indirect` 10), production scripts copied, session 2
Active for every run, `tasklist` empty before each. `ZR_OIDN_DUMP` keeps fixed file names, so a
watcher copied every frame's `oidn_color.pfm` as it landed: 12 raw dumps per run. Runner and
comparison script: the session scratchpad's `v216/run_video.sh` and `v216/compare_video.py`.

| Run | Binary | Raw dumps | Frames | Exposure | Time |
|---|---|---|---|---|---|
| before | `pre_skyclamp` (dd87243e3) | 12 | 33 | 12.068 | 819 s |
| after | `skyclamp` (ad5497576) | 12 | 33 | 12.068 | 889 s |
| repeat | `pre_skyclamp` | 12 | 33 | 12.068 | 814 s |

**Results.**
- **The repeat is byte-identical** to "before", in all 12 raw dumps and all 33 PNG frames. The
  floor is 0.
- **Raw OIDN input, before -> after.** The mean is identical in all 12 keyframes (0.113149 to
  0.122758). Pixels above 50 and above 200 are unchanged (for example frame 9: 2363 and 97 in both).
  No pixel moved by more than 0.1 in either direction, and the largest relative change in any frame
  is 4.5e-7. **No sample was clamped.**
- **Delivered frames.** Means are identical. At most 15,617 pixels in a frame (0.19%) differ, by 1
  level at most. That is the accepted code-shape drift (amendment above), not the clamp.
- **Time.** "after" is +70 s. Its daylight probe took 40.8 s against 8.0 s, which is consistent with
  shader compilation on the binary's first video job; the frames themselves are not slower.

**Reading.** In video, windows are alpha panes, not transmissive glass. So no bounce ray reaches
the bright sky at MIS weight 1 through a refracting pane, which is the path behind the still's
spikes. Nothing that reaches the sky after two or more bounces exceeds 10 here.

**Shipped 2026-10-15, owner's decision.**
- `C:\Zlendo2026\ZlenderRender_stage_copy\godot\bin\godot.windows.editor.x86_64{,.console}.exe`
  were build `5df125252` and are now `ad5497576`; a byte comparison against `bin/*.skyclamp.exe`
  passed. The previous pair is kept beside them as `*.pre_skyclamp*.exe` for rollback.
- **This also ships, for the first time:** the highlight-relief edge-aware upsample (`f45a4e6bad`)
  and Filter Glossy with its glass skip (`c9a615a085`, `dd87243e38`, `027c4188e4`).
- **Scripts in the live `godot_project`:**
  - `video_glb_creation.gd` gained the DLSS-RR `filter_glossy = 0.0` block from `b5637d0c94`.
    Without it, a DLSS-RR video's probe would meter about 2% more light than its frames render.
  - `image_glb_creation.gd` gained the rewritten KNOWN OPEN ITEM comment and the corrected
    `ZR_PT_CLAMP_INDIRECT` default (10).
- **Both scripts parse** under the new binary (`--check-only`, on a copy without `.godot`, exit 0).
  The same check on a deliberately broken copy exits 1.
