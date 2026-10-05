# OIDN guides: Cycles' denoising-feature pass-through

**Date:** 2026-10-04. **Scope:** engine shaders only (`raytracing_inc.glsl`,
`scene_raytracing_raygen.glsl`, `raytracing_closest_hit_common_inc.glsl`,
`raytracing_lights_inc.glsl`) plus one new gate. **Predecessors:** the accumulated OIDN
guides (`2026-09-16-oidn-accumulated-guides-design.md`, whose "Out of scope" deferred
exactly this: "feature deferral through specular surfaces"); video OIDN
(`2026-10-01-video-oidn-design.md`), whose Task 4 review material exposed it. Owner
decision 2026-10-04: "fix the glass the Blender way first", before the video OIDN
closeout.

## The complaint

In the urbanvideotest1 OIDN-vs-DLSS-RR side-by-side, the view through the window is
blotchy in OIDN and clean in DLSS-RR (`.superpowers/sdd/2026-10-01-video-oidn/t7/
window_glass_1to1.png`). Walls and edges are otherwise equivalent.

## What was measured

1. **The engine's own OIDN inputs at the window** (`ZR_OIDN_DUMP`, keyframe 210 held
   static, video Phase A 2 x 3 spp, `dump_base/`). Inside the upper-left pane
   (x 1620-1820, y 720-880 of 3840x2160): **92.7% of pixels have albedo exactly 0 and a
   zero-length normal** (the readback's `(0, 0, 1)` fallback,
   `render_forward_clustered.cpp:2111-2124`) -- the guide buffers were cleared at the
   accumulator reset and **never written**. The colour in the same pixels shows the lit
   exterior (luma median 0.45). The other 7.3% hold the pane's own albedo.
2. **The pane is nearly invisible.** `Mat_A38_Window_Glass_001` (GLB
   `6539d990_Minimalistic_Window_HP.glb`): alphaMode BLEND, alpha **0.033**, metallic 0,
   roughness 0.0916, base 0.7067. The pipeline keeps it as a traced alpha closure
   (`[GlassFix] ... traced alpha closure (keeps authored colour)`), so 96.7% of camera
   samples pass straight through it.
3. **Reproduced in 256x256** (`probe/`, `probe_guides.gd` in a scratch project copy):
   sky and a checker, open and behind an alpha-0.033 pane, 6 accumulated samples.

   | quadrant | guide unwritten | colour mean |
   |---|---|---|
   | sky, open | 0.0% | (0.50, 0.60, 0.80) |
   | sky, behind pane | **80.2%** | (0.49, 0.59, 0.79) |
   | checker, open | 0.0% | (0.20, 0.24, 0.32) |
   | checker, behind pane | **79.4%** | (0.20, 0.24, 0.32) |

   80% = 0.967^6: a pixel's guide is written only if one of its 6 samples happened to
   shade the pane, and then it holds the pane.

## Root cause

`inc_transmission_bounce()` (`raytracing_inc.glsl:269`) is `packed + 0x08000001u`, "+1
to both total and transmission", by design: the raygen loop's iteration budget relies on
it. The alpha pass-through (`raytracing_closest_hit_common_inc.glsl:1515-1553`) calls it.
Every OIDN guide write is gated on `total_bounces == 0u && is_sample_zero(...)`:

- closest hit, `raytracing_closest_hit_common_inc.glsl:1824` (`rt_accum_guide_sample`
  at :1834),
- miss, sky, `scene_raytracing_raygen.glsl:594` (:600),
- miss, fog scatter, `scene_raytracing_raygen.glsl:518` (:526).

So the surface or sky seen *through* an alpha pane is bounce 1 and writes no guide. OIDN
is then told "black, featureless" over a region whose colour is a lit exterior, and it
smears that region into blotches. The fewer the samples, the worse: at a still's 256+
samples the colour is nearly clean and OIDN leans on it; at video's 6 it cannot.

A second, related gap applies to the converted glass (`_apply_glb_transmissive_glass`:
transmission 1, metallic 0, white base, thickness 0): its guide is written at the pane
as albedo `base * (1 - metalness)` = **white** with the pane's flat normal. That is not a
missing write, but it describes the pane rather than what is seen through it.

## What Cycles does (the reference)

- Every camera path starts with `PATH_RAY_DENOISING_FEATURES` set and
  `denoising_feature_throughput = 1` (`integrator/path_state.h:96-101`).
- **Transparent bounces do not advance `bounce`**: `path_state_next` handles
  `LABEL_TRANSPARENT` with its own `transparent_bounce` counter and returns before
  `bounce + 1` (`integrator/path_state.h:120-140`). Transparency always passes the
  features through (`film/denoising_passes.h`, "Transparency always passes through").
- At a surface, `film_write_denoising_features_surface` decides write-or-defer from the
  closures. The rule **as shipped through 2026-03-03** (the parent of commit
  `44be56fd493`, "Smoothly blend denoising features"):
  - a closure whose GGX alpha (`sqrt(bsdf_get_specular_roughness_squared)`) is
    **> 0.075** is diffuse-like and adds its albedo to `diffuse_albedo`; otherwise it
    adds to `specular_albedo`;
  - **write** the features if `sum_weight == 0` or `sum_nonspecular_weight * 4 >
    sum_weight` -- normal, and `diffuse_albedo * denoising_feature_throughput` -- and
    clear the flag;
  - **otherwise defer**: `denoising_feature_throughput *= specular_albedo`, and the
    next surface or the background writes instead.
- A background reached with the flag set writes `denoising_feature_throughput * L` to the
  albedo pass (`film/light_passes.h:411-415`).
- Current main replaces the hard rule with a smoothstep blend (`44be56fd493`,
  2026-03-03) and adds `follow_reflections` / albedo-roughness options (`79f6f5c7939`,
  2026-05-12; both default on). The blend writes a *fraction* of the features at each
  vertex. Our guides are running means updated once per sample
  (`rt_accum_guide_sample`), so the one-write-per-sample hard rule is the faithful port;
  the blend is a later refinement (see Out of scope).

## Design

### 1. Feature state on the path (payload)

`PathState` gains `vec3 feat_throughput` and `bool feat_pending`, converted in
`path_unpack` / `path_pack`. In the payload they ride in the word that already carried the
SSS and guide-record flags (fix round 2; round 0/1 had a dedicated `uint feat_state`,
which grew the struct 92 -> 96 bytes): `PathPayload.sss_restart` is now `vec3` followed by
`uint sss_bits`, with bit 0 `sss_exit`, bit 1 `guide_record`, bit 2 `feat_pending` and bits
8-15 / 16-23 / 24-31 the throughput r / g / b as unorm8 (`packUnorm4x8` quantisation); the
struct stays 92 bytes. The throughput is a product of albedos, so it lives in [0, 1] and 8
bits per channel is ample for a guide; 1.0 round-trips exactly (255/255).

**Every construction site initialises both fields** -- an uninitialised payload field
has moved gate results before (`raytracing_lights_inc.glsl:317-321`, probe 6):

- raygen `trace_one_sample`: `feat_throughput = vec3(1.0)`, `feat_pending =
  p_is_sample_zero && get_rt_param(RT_PARAM_ACCUM_FLAG) > 0.5`. One-shot mode (DLSS-RR
  video, realtime) never sets it, so that path does no extra work.
- shadow rays, `raytracing_lights_inc.glsl:308`: `vec3(1.0)`, `false`.

### 2. The write sites

All under `#ifdef DLSS_RR_ENABLED`, where `rt_accum_guide_sample` lives. The DLSS-RR
G-buffer, depth and velocity writes are **not touched**: they stay at `total_bounces ==
0`. Only the `rt_accum_guide_sample` calls move.

- **Closest hit.** The call at :1834 leaves the DLSS-RR block. After that block, a new
  `rt_guide_features_surface(...)` runs when `ps.feat_pending`:
  - if the surface **defers** (rule below): `feat_throughput *= clamp(spec_albedo, 0,
    1)`; if the result's largest channel is <= 0.5 / 255 (the value `packUnorm4x8` rounds to
    zero), write a zero sample and clear
    `feat_pending` (Cycles clears the flag and contributes nothing; our running mean
    needs its one write);
  - otherwise write `rt_accum_guide_sample(pixel, diffuse_albedo * feat_throughput, N *
    t_avg)` and clear `feat_pending`, where `diffuse_albedo` is today's
    `DLSSRR_computeDiffuseAlbedo(m.albedo, m.metalness)` and `t_avg = (T.r + T.g + T.b)
    / 3.0` (exactly 1.0 for T = 1; not `dot(T, vec3(1.0 / 3.0))`, which is not).
- **Miss, sky:** when `ps.feat_pending`, write `sky_color * feat_throughput` and
  `-gl_WorldRayDirectionEXT * t_avg`; clear. The direction normal is our existing miss
  convention, kept so sky seen directly and sky seen through glass agree.
- **Miss, fog scatter:** the same with `volume_albedo()`.
- **Alpha pass-through:** unchanged. The state rides through untouched, which is
  Cycles' "transparency always passes through" for a stochastic closure: the pane's
  alpha share writes the pane, the rest writes what is behind, and the running mean
  averages them in the authored proportion.
- **Path end:** after the raygen bounce loop, if `ps.feat_pending` is still set (the
  path terminated mid-deferral: bounce cap, roulette, absorption), write
  `rt_accum_guide_sample(pixel, vec3(0.0), vec3(0.0))`. This runs before raygen stores
  `n + 1`, so the weight is right.

### 3. The rule: `rt_guide_defers`

Inputs are the hit's `brdf_mat`, `m` and `NdotV` at the write site.

```
alpha = brdf_mat.roughness * brdf_mat.roughness   // brdf_inc.glsl:2054 convention
if alpha > 0.075: write                           // every lobe is diffuse-like
(R, T) = dielectricFresnelSplit(NdotV, eta, dielectricF0, transmissivness)
metal  = evalFresnelSchlick(base, 1, NdotV)       // Cycles' F82 tint, at the default white tint
spec   = metalness * metal + (1 - metalness) * (R + T)
d      = baseColorToDiffuseReflectance(base, metalness, transmissivness) * (1 - R)
w_diff = avg(d)
w_spec = avg(spec)
write  if (w_diff + w_spec == 0) or (w_diff * 4 > w_diff + w_spec)
else   defer, with spec_albedo = spec
```

`avg` is `(r + g + b) / 3`. Cycles weights each closure by its `bsdf_albedo`, which for a
near-delta closure is its Fresnel at the view direction, so both shares come from the
engine's own Fresnel sources: the metal share is Schlick with `f90 = 1` (what Cycles'
F82 tint reduces to at the default white tint, see `evalFresnelBase`), and the dielectric
share is the exact remap `dielectricFresnelSplit` performs for the transmissive lobe
(`R` is the specular layer's albedo, `T = (1 - R) * transmission`, colourless; with
`transmissivness` 0 it gives `T = 0`, and under total internal reflection `R = 1`,
`T = 0`). Cycles layers the diffuse closure under the dielectric's specular layer, so
its weight carries `(1 - R)`. For clear glass R + T is 1 at every angle, so the guide
behind a window carries what is outside at full strength.

The DLSS-RR specular-albedo helper (`DLSSRR_computeSpecularAlbedo`, `brdf_inc.glsl:4255`)
is **not** used here: it returns Karis' EnvBRDFApprox multiplied by 2.0
(`DLSSRR_envBRDFApprox`, `brdf_inc.glsl:4247`), twice the Fresnel scale Cycles weighs by.
An earlier cut of this rule used it (round 0) and measured a smooth white metal passing
`clamp(2 * F0)` instead of `F0` and a dark glossy dielectric deferring instead of writing.

Worked cases (hand-computed from the formula, real Fresnel for ior 1.5 and
`dielectricF0` 0.04; not measured):

- Smooth clear thin glass (transmission 1, base white): `R + T = 1.0`, `w_diff = 0`, so it
  defers with throughput 1.0 at every angle. Thick glass seen from inside under total
  internal reflection: `R = 1`, `T = 0`, `spec = 1.0`, defers with 1.0.
- Smooth metal, base 0.5, normal incidence: `spec = 0.5`, `w_diff = 0`, so it defers with
  throughput 0.5 (the gate's F7). A gold-like `F0 = (1.0, 0.78, 0.34)` passes its own F0,
  tint kept (the 2x helper gave `(2.0, 1.56, 0.69)`, clamped to `(1.0, 1.0, 0.69)`).
- Dark glossy dielectric, base 0.02, normal incidence: `w_diff = 0.02 * 0.96 = 0.0192`,
  `w_spec = 0.04`, and `4 * 0.0192 = 0.0768 > 0.0592`, so it writes its diffuse albedo
  0.02 (F8). The boundary for an opaque smooth dielectric is `base > R / (3 * (1 - R))`:
  0.0139 at normal incidence (R 0.040), 0.0326 at NdotV 0.5 (R 0.089), 0.171 at NdotV 0.2
  (R 0.339). Round 0 put the same boundary at 0.030 / 0.056 / 0.213.
- Glossy white wall (roughness 0.2, alpha 0.04, base 0.8): `w_diff = 0.8 * 0.96 = 0.768`
  against `w_spec = 0.04`, so it writes, as today.
- The window pane's alpha share (base 0.7067, metallic 0, alpha 0.0084): `w_diff` 0.678
  against `w_spec` 0.04, so it writes the pane.
- A rough anything (alpha above 0.075, roughness above 0.274) writes.

### 4. Invariance

On a scene with no alpha pass-through and no near-specular surface, every path resolves
its features at bounce 0 with T = 1, through the same arguments as today: the guides
are **bit-identical**. In one-shot mode `feat_pending` is never set; the colour
arithmetic is untouched in both modes. So:

- the DLSS-RR video stays frame-identical (`ffmpeg -f framemd5`, the video-OIDN plan's
  standing check);
- the existing gates (`pt_oidn_guide_gate` G1-G3, `pt_transmission_gate`, the full
  `*_gate_scene.tscn` suite) pass unchanged.

Stills **do change** wherever a window, glass or mirror is in view; that is the point.
Job 201's still (three windows) is expected to leave its md5
`2a17e6571e9bd26619591415cfaf0e08`.

### 5. Compile-time gate (fix round 3)

All of the code above exists only in the **accumulate (Phase A) pipeline**. Measured
reason: the DLSS-RR one-shot path ran 2.9% slower per frame (6059 vs 5891 ms) with this
feature compiled in, although `feat_pending` is never set there; moving the feature state
into the SSS bitfield (payload back to 92 bytes) recovered only 0.8% of it, because the
code that never executes still costs registers and code size in the hit and miss stages.

- **Key.** The RT flags word's sample-count field (bits 20-26) means *0 = accumulate;
  one-shot always packs >= 1*. `compute_rt_flags` packs 0 when the environment's
  accumulate flag is set (`>= 0.5`, the test and params pointer `rt_accumulate_active`
  uses); the accumulate raygen branch never reads the sample count, and
  `RT_GET_SAMPLE_COUNT()` is `max(1u, field)`.
- **Define.** `_ensure_variant_compile_context` injects `#define RT_OIDN_FEATURES` into
  every stage source when the field is 0, before the custom hit-group templates are cut,
  so a pipeline's raygen, miss, closest-hit, any-hit and intersection stages (custom
  material hit groups included) agree. Contexts and bundles are keyed by the full word, so
  accumulate and one-shot are separate pipelines; accumulate already had its own word
  (DLSS_RR forced for OIDN / DLSS-RR-final), so the still and OIDN-video routes gain no
  variant, and DLSS-RR video never accumulates.
- **Source.** Every Task 5 shader line sits under `#ifdef RT_OIDN_FEATURES`, with the
  pre-Task-5 text in the `#else` (the payload keeps its `vec4 sss_restart`, the miss and
  closest-hit bounce-0 writes keep their original `rt_accum_guide_sample` calls). Without
  the define the raytracing shader sources are the pre-Task-5 source: stripping comments, the
  macro-off text equals `git show 429e896fdf:<file>` line for line.

## Gate: `pt_oidn_guide_passthrough_gate`

256x256, `use_hdr_2d`, the still route's viewport contract (as `pt_oidn_guide_gate`),
`ZR_OIDN_DUMP` pointed at a gate temp dir with `OS.set_environment` before the
accumulation, PFMs read back after. 6 accumulated samples (video's count), max bounces
6, OIDN on. Uniform sky (0.5, 0.6, 0.8). Top row: sky; bottom row: a 4-px checker card
(0.9 / 0.1). Five columns, each a pane of width w / 5 at 5 m (or open air): **open**,
**behind an alpha pane** (authored like `Mat_A38_Window_Glass_001`: alpha 0.033, base
0.7067, roughness 0.0916, metallic 0, cull disabled), **behind a smooth thin glass**
(transmission 1, ior 1.5, roughness 0, thickness 0, metallic 0, white; the material
`_apply_glb_transmissive_glass` produces), a **mirror** (metallic 1, roughness 0, linear
base 0.5; it faces the camera, so its reflection leaves past the camera into the sky) and
a **dark gloss** dielectric (metallic 0, roughness 0, `metallic_specular` 0.5, linear base
0.02). Each check measures an interior region with a margin from the column edges
(columns at multiples of 51.2 px; regions open [8, 48), alpha [58, 96), glass [110, 148),
mirror [162, 200), dark [212, 250), rows sky [8, 120) and checker [136, 248)).

- **F1 premise (colour):** colour mean behind the alpha pane / open, per row, in
  [0.95, 1.05]. The pane is what we think it is. Invariance check: passes on both
  builds.
- **F2 written:** unwritten guide pixels (albedo 0 and the zero-length-normal
  fallback) behind the alpha and the glass pane <= 1%, per row. Round-0 build: about
  80% behind the alpha pane.
- **F3 alpha-pane albedo:** guide albedo mean behind the alpha pane within 5% of
  `0.967 * open + 0.033 * 0.7067`, per row. Pre-fix build: 0.10x (sky), 0.14x (checker).
- **F4 glass detail:** the checker's guide-albedo std behind the smooth glass / open
  >= 0.85. Pre-fix build: about 0 (flat white).
- **F5 open unchanged:** open-region guides equal today's: sky albedo luma == the sky
  colour's luma within 1e-3 absolute, checker albedo mean == the texture's linear mean
  within 2% relative. Invariance check.
- **F6 denoised result: informative, not a check.** OIDN output behind each pane vs the
  open region, the checker's output std ratio. It passed on the build before the fix
  (0.979 alpha, 0.975 glass), because a 4-px high-contrast checker keeps its detail in the
  colour whatever the guides say, so it cannot tell the two builds apart. The visible
  effect is judged on the production window instead (Measured, below).
- **F7 mirror:** guide albedo luma behind the mirror within 5% (relative) of `0.5 *` the
  open sky's guide albedo luma, per row. A smooth metal defers with its Fresnel, 0.5 at
  normal incidence. Round-0 build: ratio 2.00 (the 2x helper saturated at 1).
- **F8 dark gloss:** guide albedo luma on the dark gloss within 5% (relative) of its
  diffuse albedo 0.02, per row. Cycles writes here (`w_diff` 0.0192 against `w_spec` 0.04,
  and `4 * 0.0192 > 0.0592`). Round-0 build: ratio 2.67 (it deferred).

Thresholds are confirmed against three runs of the fixed build. F2-F4 were shown **red on
the pre-fix binary**, F7 and F8 **red on the round-0 binary**, before each fix landed.

## Asset checks

1. **The window, re-dumped:** the keyframe-210 static job (`run_dump.sh`): unwritten
   fraction in the pane region 92.7% -> <= 1%; the window crop at 1:1, OIDN after vs
   OIDN before vs DLSS-RR.
2. **Still, job 201 at 1080p:** before/after, whole-frame mean within 0.5%, and a diff
   map. The owner judges the windows.
3. **Video:** the full urbanvideotest1 OIDN render and the T7 side-by-side material are
   regenerated on the fixed build for the owner's review (video-OIDN plan, Task 4
   resumes).
4. **DLSS-RR video unchanged:** framemd5-identical to the pre-change build on a short
   DLSS-RR job.

## Out of scope (recorded, not fixed here)

- **DLSS-RR's G-buffers have the same gate.** Through an alpha pane, DLSS-RR's albedo,
  normal, depth and velocity are not written either. The owner's standing rule is that
  DLSS-RR does not change; recorded for a later decision.
- **Clamp after a pass-through.** `clamp_limit` picks `CLAMP_DIRECT` only at
  `total_bounces == 0` (`raytracing_closest_hit_common_inc.glsl:1556-1558`), so a
  surface seen through an alpha pane is clamped as *indirect*; in Cycles it is still a
  camera-visible surface. This changes colour in both denoisers, so it is not part of a
  guide fix.
- **Cycles' current smooth blend and `follow_reflections` options.** They need partial
  writes per vertex.
- **Other feature-pass differences**, unchanged here: Cycles adds emission to the albedo
  pass at emissive hits; its rough-metal albedo goes into the guide (ours is `base * (1
  - metalness)` = 0); its rule counts coat and sheen closures; it has a depth pass.

## Deviations from Cycles, on record

- One write per sample with the hard rule, as above.
- The rule's weights are estimated from our one-material model rather than per closure:
  coat and sheen are not counted.
- The deferred throughput is stored at 8 bits per channel.
- A deferred miss writes our direction normal; Cycles writes no normal for a background.

## Measured (2026-10-04)

All paths are under `.superpowers/sdd/2026-10-01-video-oidn/` (untracked working notes).
Binary pair: `godot_pre5` (the build before the change) and the fixed build; desktop
session Active for every run.

This first part is **round 0** (commit `661d950aa7`, gate of 12 checks over three
columns); it measured the rule with the DLSS-RR specular helper, which round 1 (the last
subsection) replaced after review found the helper weighs smooth lobes at twice their
Fresnel.

**Gate as built** (`pipeline_references/tests/pt_oidn_guide_passthrough_gate.gd`): 12
checks. F1's band is [0.95, 1.05] (the pane's colour ratio reads 0.9911 sky / 1.0245
checker on both builds). F6 is **informative, not a check**: it passed on the build before
the fix (output std ratio 0.9790 alpha / 0.9745 glass, raw colour 0.9761 / 0.9753), so it
cannot tell the builds apart; the 4-px checker's contrast lives in the colour and OIDN keeps
it whatever the guides say. The visible effect is judged on the production window below.

| check | before the fix (`t5g_pre.log`) | after the fix, runs 1-3 identical (`t5g_post_{1,2,3}.log`) | threshold |
|---|---|---|---|
| F1 colour ratio sky / checker | 0.9911 / 1.0245 | 0.9911 / 1.0245 | [0.95, 1.05] |
| F2 alpha pane unwritten, sky / checker | 80.76% / 80.23% (red) | 0.00% / 0.00% | <= 1% |
| F2 glass unwritten, sky / checker | 0.00% / 0.00% | 0.00% / 0.00% | <= 1% |
| F3 alpha-pane albedo / authored mix, sky | 0.0577 / 0.5966 = 0.0967 (red) | 0.5964 / 0.5966 = 0.9996 | +-5% |
| F3 same, checker | 0.0587 / 0.4079 = 0.1440 (red) | 0.4065 / 0.4079 = 0.9967 | +-5% |
| F4 glass guide checker std / open | 0.0000 (red) | 0.9655 | >= 0.85 |
| F5 open sky albedo / authored | 0.59289 / 0.59318 | 0.59289 / 0.59318 (bit-identical) | 1e-3 |
| F5 open checker albedo mean / texture mean | 0.39768 / 0.39872 | 0.39768 / 0.39872 (bit-identical) | 2% |
| F6 output std ratio alpha / glass (informative) | 0.9790 / 0.9745 | 0.9520 / 0.9589 | none |

**Regression suite** (`suite/summary.txt`, pre-change copy `suite_pre5_summary.txt`): all
26 gate scenes pass, including the new one. `pt_oidn_guide_gate` G1-G3 print the same
lines on both binaries in the same session. `pt_transmission_gate` passes 45/45 on both
binaries in this session (the earlier 1-of-45 was the desktop-session effect); probe 6
reads 4.0695 (old) and 4.0694-4.0699 (new) against 4.069, inside the run-to-run floor of
both (`suite_old_control/`).

**DLSS-RR unchanged** (`t5_dlssrr_a/` pre-change binary, `t5_dlssrr_b/` fixed build,
`job301_12kf.json`, default mode, 60 fps movie): 38 frames each, `ffmpeg -f framemd5`
identical (38 of 38, file md5 `e1b3b26b38239faa590de8785860289a`); `t5_dlssrr_diff.txt`
is empty.

**The window, keyframe 210 static job** (`dump_base/` vs `dump_post5/`, region x 1620-1820,
y 720-880): guide pixels never written **92.69% -> 0.00%** (limit 1%). Region albedo mean
0.0400 -> 0.3482. The colour dump is bit-identical between the two runs (0.000% of pixels
differ), so only the guides moved. Away from glass, a wall at x 2400-2600, y 600-700,
albedo and normal are identical in both dumps. Images: `t5g/window_guides.png`,
`t5g/window_crop_before_after_dlssrr.png`; changed-guide map `t5g/albedo_changed_kf210.png`
(12.1% of the frame, all on glass, alpha, smooth metal and the like).

**Job 201 at 1080p** (`t5g/job201_old/`, `t5g/job201_new/`): md5 `befe659dbb23ebc332f144806f3dec38`
-> `21745d660e4046a0c4b3796c494cf78c`; whole-frame 8-bit PNG mean ratio new/old
**0.99980** (limit 0.5%); mean |diff| 0.35 levels, 1.03% of pixels differ by 8 or more
levels. Heat-map `t5g/job201_diff.png`. (The pre-change reference is `befe659d`, the
same-session baseline; the archived `2a17e657` quoted above appears about one run in six on
the pre-change binary.)

**Known consequence, as in Cycles:** a smooth metal surface (the window's metal frame)
defers, so its normal guide becomes the average of the surfaces it reflects and is noisy
before OIDN: the mullion at x 1838-1846, y 740-900 reads normal per-axis std 0.011 before
and 0.279 after, albedo mean 0.004 -> 0.125. OIDN's output there stays clean (std 0.0058 ->
0.0032). Cycles later added `follow_reflections` to control exactly this (see "What Cycles
does").

### Fix round 1 (2026-10-05): the deferral weights smooth lobes by their Fresnel

Review found that round 0's `rt_guide_defers` weighed the smooth lobes with
`DLSSRR_computeSpecularAlbedo`, whose `DLSSRR_envBRDFApprox` returns Karis' fit times 2.0
(`brdf_inc.glsl:4247`), twice the Fresnel scale Cycles' `bsdf_albedo` gives. Effects: a
smooth dielectric of F0 0.04 read 0.091 instead of 0.046 (0.0902 measured through the
gate), so the deferral band for dark glossy dielectrics doubled; a smooth white metal's
throughput was `clamp(2 * F0)`; and the reflection share was dropped under total internal
reflection. Section 3 now uses `dielectricFresnelSplit` and `evalFresnelSchlick` (formula
and worked cases there), and the zero-write threshold is `0.5 / 255`, the value
`packUnorm4x8` rounds to zero. The DLSS-RR helpers are untouched. Paths as above, under
`.superpowers/sdd/2026-10-01-video-oidn/`.

**Gate widened to five columns, 16 checks** (F7 mirror, F8 dark gloss added; regions in the
Gate section). Run FIRST on the round-0 binary (`t5g_r1_pre.log`): F0-F5 pass in the
narrower regions, **F7 red** (mirror guide 0.5929 against the wanted 0.2964, ratio 2.0000
on both rows: `clamp(2 * 0.5)` = 1, so the guide equals the sky) and **F8 red** (dark gloss
0.0535 against 0.0200, ratio 2.6732: it deferred, 0.0535 = 0.0902 x 0.593).

After the shader change (`t5g_r1_post_{1,2,3}.log`, three runs with byte-identical
numbers, 16 of 16 pass, no shader-compile errors in the first log):

| check | round-0 binary | round-1 binary | threshold |
|---|---|---|---|
| F1 colour ratio sky / checker | 0.9907 / 1.0237 | 0.9907 / 1.0237 | [0.95, 1.05] |
| F2 alpha and glass unwritten (4 values) | 0.00% | 0.00% | <= 1% |
| F3 alpha-pane albedo ratio sky / checker | 0.9996 / 0.9976 | 0.9996 / 0.9976 | +-5% |
| F4 glass guide std ratio | 0.9686 | 0.9686 | >= 0.85 |
| F5 open sky albedo / checker mean | 0.59289 vs 0.59318; 0.39764 vs 0.39872 | same | 1e-3 abs; 2% rel |
| F6 (informative) alpha / glass | 0.9559 / 0.9805 | 0.9554 / 0.9740 | none |
| F7 mirror, sky / checker (ratio to 0.5 x open sky) | 2.0000 / 2.0000 (red) | 1.0034 / 1.0034 | +-5% |
| F8 dark gloss, sky / checker (ratio to 0.02) | 2.6732 / 2.6732 (red) | 0.9995 / 0.9995 | +-5% |

**Regressions on the round-1 binary.** `suite/summary.txt`: all 26 gate scenes pass,
including the 16-check gate; `pt_oidn_guide_gate` G1-G3 print the same lines as the
pre-change binary; against `suite_pre5_summary.txt` the only change is
`pt_transmission_gate` (the pre-change run's 1-of-45 was the Disc-session effect; 45/45
now). DLSS-RR, `job301_12kf.json`, default mode: 38 frames, `framemd5` identical to the
preserved pre-change reference `t5_dlssrr_a/movie.framemd5` (md5
`e1b3b26b38239faa590de8785860289a`; `t5_dlssrr_diff_r1.txt` empty). Keyframe-210 re-dump
`dump_post5r1/`: pane region unwritten **92.69% -> 0.00%**; colour bit-identical to the
base dump; the wall control region is unchanged; the metal mullion's albedo mean is now
0.071 (round 0: 0.125; base 0.004) with its normal still noisy (per-axis std 0.278), OIDN
output there clean (std 0.0038). Images `t5g/window_crop_before_after_dlssrr.png` (after =
round 1; round 0 kept as `..._round0.png`) and `t5g/window_guides.png`.

**Job 201 at 1080p, round-1 binary, twice (warm):** 224 s then 205 s, both md5
`10c98486960c8bca460f63f8e146f75c`, so the 208 s -> 248 s of round 0 was a first-run
effect. Against the pre-change still `knee-sweep/knee_3.0.png` (md5 `2a17e657...`): whole-frame
8-bit mean ratio **0.99981** (limit 0.5%), mean |diff| 0.322 levels, 0.905% of pixels differ
by 8 or more levels; heat-map `t5g/job201_diff.png` (regenerated against `knee_3.0.png`).

### Fix round 2 (2026-10-05): the payload stays 92 bytes

Alternating A/B of the DLSS-RR one-shot path (`job301_12kf.json`, default mode, GPU render
time per frame, session Active) found the round-1 build 2.9% slower than the pre-Task-5
build (6059 vs 5891 ms) although the new code never runs there; the suspect was the payload
growing 92 -> 96 bytes, since every NEE shadow ray copies it and keeps it live across its
trace. Fix A moved the feature state into the SSS/guide-record bitfield (`sss_bits`, see
section 1), so the payload is 92 bytes again. Result: OIDN output unchanged (gate log
identical to round 1 apart from the banner; the four kf210 PFMs byte-identical to
`dump_post5r1`; suite 26/26), but the cost only fell to **+2.0%** (new 6009.9 ms, n = 4,
sd 6.7; old 5891.1 ms, n = 3, sd 15, plus two old outliers reported in the notes), outside
the 0.5% bar. The remainder is code that is present in the one-shot pipeline but never
executes; removing it took a compile-time variant for that pipeline (round 3, below).

### Fix round 3 (2026-10-05): the feature code compiles only into the accumulate variant

Section 5 of the Design: sample-count field 0 = accumulate, `#define RT_OIDN_FEATURES`
injected for it, pre-Task-5 source in the `#else`. Checks, on the round-3 binary:

- **Source identity.** With the macro off, `raytracing_inc.glsl`,
  `scene_raytracing_raygen.glsl`, `raytracing_closest_hit_common_inc.glsl`,
  `raytracing_lights_inc.glsl`, `raytracing_guiding_inc.glsl` and `raytracing_common_inc.glsl`
  equal `git show 429e896fdf:<file>` after stripping comments (293 / 709 / 1114 / 451 / 147 /
  93 code lines); the same check on the ungated round-2 files reports a difference.
- **DLSS-RR one-shot timing** (`job301_12kf.json`, default mode, GPU render time,
  ms/frame, 12 alternating runs, every framemd5 body `b55e6e77`): in the stable-session set
  (ab5, session Active throughout, new/old interleaved) old 5905.9 (sd 4.1, n = 3), new
  5916.4 (sd 10.1, n = 3): **+0.18%**. The earlier set (ab4) straddled RDP session switches:
  old 5856.5 / 5772.2 / 5885.6, new 5870.3 / 5887.7 / 5903.1; over every run that was Active
  throughout (old n = 4, new n = 5) the means are 5900.8 and 5908.0, **+0.12%**. Over all
  12 runs the ratio is +0.51%, pulled by the one old run (5772.2) that straddled a session
  switch. For comparison: pre-Task-5 steady 5891.1 (round 2), Fix A alone 6009.9 (+2.0%),
  round 1 6059.3 (+2.9%). Files `ab4_summary.txt`, `ab5_summary.txt`.
- **OIDN output unchanged.** The 16-check gate passes 3 of 3 with numeric lines identical to
  round 1's log; the four kf210 PFMs (`dump_post5r3`) have the same md5 as `dump_post5r1`
  (colour `fa1157d5ecbf`, albedo `4eb1d0a01fcd`, normal `b2a1d45126c7`, output
  `f47fb7de52b6`); job 201 at 1080p twice, md5 `10c98486960c8bca460f63f8e146f75c` both
  times, 231 s then 206 s (round 1: 205 s). Suite 26/26.
- **Pipeline count.** The engine prints no line when it builds a raytracing bundle (only
  failure warnings, none seen), so there is no log count; by construction the one-shot word
  is unchanged and the accumulate word differs only in its sample-count field.
