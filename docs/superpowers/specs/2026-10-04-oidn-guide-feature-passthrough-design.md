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

`PathPayload` gains one field, `uint feat_state` = `packUnorm4x8(vec4(feat_throughput,
feat_pending ? 1.0 : 0.0))`; the struct grows 92 -> 96 bytes. `PathState` gains
`vec3 feat_throughput` and `bool feat_pending`, converted in `path_unpack` / `path_pack`.
The throughput is a product of albedos, so it lives in [0, 1] and 8 bits per channel is
ample for a guide; 1.0 round-trips exactly (255/255).

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
    1)`; if the result's largest channel is <= 1e-4, write a zero sample and clear
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

Inputs are the hit's `brdf_mat`, `m`, `NdotV` and `specularF0` at the write site.

```
alpha = brdf_mat.roughness * brdf_mat.roughness   // brdf_inc.glsl:2054 convention
if alpha > 0.075: write                           // every lobe is diffuse-like
w_diff = avg(baseColorToDiffuseReflectance(base, metalness, transmissivness))
spec   = DLSSRR_computeSpecularAlbedo(base, metalness, dielectricF0, roughness, NdotV)
if transmissivness > 0:
    dielectricFresnelSplit(NdotV, eta, specularF0, transmissivness, R, T, ct)
    spec += (1 - metalness) * T
w_spec = avg(spec)
write  if (w_diff + w_spec == 0) or (w_diff * 4 > w_diff + w_spec)
else   defer, with spec_albedo = spec
```

`avg` is `(r + g + b) / 3`. The reflection term reuses the DLSS-RR specular-albedo
helper (`brdf_inc.glsl:4255`), and the transmission term reuses the single source of
truth for the reflect/transmit split (`dielectricFresnelSplit`, colourless
`(1 - R) * transmission`). For clear glass, R + T is about 1, so the guide behind a
window carries what is outside at full strength.

Worked cases: smooth clear glass (w_diff 0) defers. A smooth metal (w_diff 0) defers.
A glossy white wall (roughness 0.2, alpha 0.04): w_diff 0.8 vs w_spec ~0.05, so it
writes, as today. The window pane's alpha share (base 0.7067, metallic 0, alpha 0.0084)
writes the pane. A rough anything writes.

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

## Gate: `pt_oidn_guide_passthrough_gate`

256x256, `use_hdr_2d`, the still route's viewport contract (as `pt_oidn_guide_gate`),
`ZR_OIDN_DUMP` pointed at a gate temp dir with `OS.set_environment` before the
accumulation, PFMs read back after. 6 accumulated samples (video's count), max bounces
6, OIDN on. Uniform sky (0.5, 0.6, 0.8). Top row: sky; bottom row: a 4-px checker card
(0.9 / 0.1). Three columns: **open**, **behind an alpha pane** (authored like
`Mat_A38_Window_Glass_001`: alpha 0.033, base 0.7067, roughness 0.0916, metallic 0,
cull disabled), **behind a smooth thin glass** (transmission 1, ior 1.5, roughness 0,
thickness 0, metallic 0, white; the material `_apply_glb_transmissive_glass`
produces). Each check measures an interior region with a margin from the region edges.

- **F1 premise (colour):** colour mean behind the alpha pane / open, per row, in
  [0.95, 1.01]. The pane is what we think it is. Invariance check: passes on both
  builds.
- **F2 written:** unwritten guide pixels (albedo 0 and the zero-length-normal
  fallback) behind each pane <= 1%, per row. Current build: about 80% behind the alpha
  pane.
- **F3 alpha-pane albedo:** guide albedo mean behind the alpha pane within 5% of
  `0.967 * open + 0.033 * 0.7067`, per row. Current build: about 0.09x.
- **F4 glass detail:** the checker's guide-albedo std behind the smooth glass / open
  >= 0.85. Current build: about 0 (flat white).
- **F5 open unchanged:** open-region guides equal today's, sky albedo == sky colour
  and checker albedo mean == the texture mean, within 1e-3. Invariance check.
- **F6 denoised result:** OIDN output behind each pane vs the open region, per row:
  mean within 3%, and the checker's output std ratio >= 0.85.

Thresholds are confirmed against three runs of the fixed build. F2-F4 must be shown
**red on the current binary** before the fix lands; F6 counts as a check only if it is
also red there, otherwise it is reported as informative.

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
  the diffuse weight omits Cycles' `(1 - F)` layering factor (it shifts the boundary by
  at most about 4%), and coat and sheen are not counted.
- The deferred throughput is stored at 8 bits per channel.
- A deferred miss writes our direction normal; Cycles writes no normal for a background.
