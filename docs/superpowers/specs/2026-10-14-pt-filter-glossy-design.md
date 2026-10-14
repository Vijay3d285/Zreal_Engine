# Filter Glossy: blur glossy lobes after blurry bounces, as Cycles does by default

**Date:** 2026-10-14. **Status:** design approved by the owner in conversation; spec awaiting
review. **Scope:** engine only (the integrator's hit shading on the accumulate route, one project
setting). No pipeline script changes. First of two "calmer grain" projects (roadmap section 4,
item 5); blue-noise sampling is the second, with its own spec.

## Intent

**Owner's words / decisions (2026-10-14):** calmer grain; Filter Glossy first, as its own project;
approach A (Cycles' rule with a compact running minimum); the engine default is **on at 1.0**,
Blender's default, so stills and video get it with the new binary and no script change.

**Assumptions (confirmed with the design):** fewer bright speckles in stills (256 spp + OIDN) and
video (24 spp + OIDN); no added render time; brightness and look unchanged apart from what Cycles
itself does; an off switch; measured before shipping.

**Why:** Blender's `Filter Glossy` defaults to 1.0 (`blender/addon/properties.py` `blur_glossy`),
so every Cycles render we are compared with has it, and we do not. Without it, a sharp reflection
of a lamp or a window reached through a diffuse bounce is a low-probability, high-energy path: a
speckle in the raw image that OIDN can smear into a blotch, and a flicker in video.

## Cycles' rule (read from source, `intern/cycles`)

- `scene/integrator.cpp:269`: `kintegrator->filter_glossy = (filter_glossy == 0) ? FLT_MAX : 1 /
  filter_glossy` (the UI value 0 disables).
- `kernel/integrator/path_state.h:62`: each path starts with `min_ray_pdf = FLT_MAX`.
- `kernel/integrator/shade_surface.h:609-612`: after a BSDF sample whose label is not transparent,
  `min_ray_pdf = fminf(unguided_bsdf_pdf, min_ray_pdf)`.
- `kernel/integrator/surface_shader.h:195-210`: at each hit, before light and BSDF sampling,
  `blur_pdf = filter_glossy * min_ray_pdf`; if `blur_pdf < 1`,
  `blur_roughness = sqrtf(1 - blur_pdf) * 0.5` and every BSDF closure gets `bsdf_blur`.
- `kernel/closure/bsdf.h:658` / `bsdf_microfacet.h:1076`: `bsdf_blur` applies to the microfacet
  closures (GGX / Beckmann reflection, refraction, glass, thin glass):
  `alpha_x = max(blur_roughness, alpha_x)`, `alpha_y = max(blur_roughness, alpha_y)`.
  Diffuse and sheen are not blurred.

## Design

### 1. The running minimum, stored compactly

On the accumulate route (`RT_OIDN_FEATURES`, the still and video pipelines), the path's minimum
pdf rides in **bits 3-7 of `PathPayload.sss_bits`** (unused today: bits 0-2 are sss_exit /
guide_record / feat_pending, 8-31 the OIDN feature throughput; `path_pack` / `path_unpack` in
`raytracing_inc.glsl`). `PathState` gains `uint glossy_min_code`.

- **Code 0** = no pdf-bearing bounce yet (Cycles' `FLT_MAX`): no blur.
- **Encode** a pdf `p > 0`: `encode(p) = (p >= 16) ? 0 : min(31, floor(3 * (4 - log2(p))) + 1)`.
- **Decode** a code `c > 0`: `decode(c) = 2^(4 - (c - 1) / 3)`, from 16 down to 2^-6 = 0.0156 in
  steps of 2^(1/3).
- `decode(encode(p)) >= p` and `< p * 2^(1/3)` for `2^-6 <= p < 16`: rounding can only make the
  stored minimum LARGER, i.e. the blur never stronger than Cycles' exact rule. Below 2^-6 the
  stored value is 2^-6 (alpha floor 0.496 vs 0.5 at most).
- **Update** after a bounce: `glossy_min_code = max(glossy_min_code, encode(p))` (a larger code is
  a smaller pdf, so `max` keeps the minimum).

### 2. Which bounces update it

At the end of `shade_and_bounce()` (`raytracing_closest_hit_common_inc.glsl`), where
`ps.mis_ray_pdf` is set:
- a bounce with a pdf (`combinedPdf(N, next_dir, V, brdf_mat)`, the material's own pdf, WITHOUT
  the guiding mixture, as Cycles uses `unguided_bsdf_pdf`) updates the code with that pdf;
- the branches that set `ps.mis_ray_pdf = RT_MIS_PDF_NONE` (transmissive lobe, thin SSS
  through-path, back-facing, near-delta specular and coat) do NOT update it: their pdf is
  effectively infinite, as in Cycles, where it cannot lower the minimum;
- an alpha pass-through (transparent) does not reach this code and does not update it (Cycles
  skips `LABEL_TRANSPARENT`);
- the SSS exit restart does not update it (rare; recorded as a deviation).

### 3. The blur at each hit

In `shade_and_bounce()`, after `brdf_mat` (the `MaterialProperties` every NEE and BSDF call in the
function reads) is fully populated and before the first NEE call:

```
if (glossy_min_code > 0 && fg > 0):        // fg = 1 / setting, 0 when the setting is 0
    blur_pdf = fg * decode(glossy_min_code)
    if blur_pdf < 1:
        alpha_floor = sqrt(1 - blur_pdf) * 0.5
        brdf_mat.roughness     = max(brdf_mat.roughness,     sqrt(alpha_floor))   // alpha = roughness^2
        brdf_mat.coatRoughness = max(brdf_mat.coatRoughness, sqrt(alpha_floor))
        g_glossy_alpha_floor   = alpha_floor   // read by ggxAnisoAlphas: ax, ay = max(ax/ay, floor)
```

- Our GGX uses `alpha = roughness * roughness` (`brdf_inc.glsl:2054`); Cycles floors alpha, so the
  roughness floor is `sqrt(alpha_floor)`. Transmission shares `roughness`.
- Anisotropy: `ggxAnisoAlphas` (`brdf_inc.glsl:1983`) is the only place ax/ay are derived; it
  clamps both to the module-level `g_glossy_alpha_floor` (the existing `g_guide` pattern), which is
  0.0 except at a blurred hit.
- A previously near-delta specular or coat that is floored above `RT_MIS_DELTA_ROUGHNESS` is no
  longer treated as a delta lobe: it is now rough, as in Cycles.
- The camera's own hit never blurs (code 0). After one diffuse bounce (pdf <= 1/pi), the next hit's
  glossy lobes get alpha >= ~0.39; mirror-to-mirror and through-glass chains stay sharp.

### 4. Control

`rendering/pathtracer/filter_glossy` (float, **default 1.0**, range 0-10, Blender's meaning;
0 = off), registered in `rendering_server.cpp` next to the other `rendering/pathtracer/*`
settings, read each frame into **rt_params slot 42** (`RT_PARAM_FILTER_GLOSSY`, after DoF's 40-41;
the UBO already has 44 floats) as `fg = setting > 0 ? 1 / setting : 0`. Without `RT_OIDN_FEATURES`
(the one-shot / DLSS-RR route, unused in production) it is a no-op.

## Verification

1. **Unit tests** (doctest `tests/servers/rendering/test_pt_filter_glossy.cpp`, mirroring the GLSL),
   each mutation-checked: code 0 means none; `decode(encode(p))` is `>= p` and `< p * 2^(1/3)`
   over `[2^-6, 16)`; `encode(p >= 16) == 0`; the running `max` keeps the smaller pdf; the floor
   formula gives alpha 0.4129 at blur_pdf 0.318 and no floor at blur_pdf >= 1; fg 0 is off.
2. **Off is exact:** job 209 still with `filter_glossy = 0` on the new binary vs today's binary:
   byte-identical (with the repeatability floor rendered first).
3. **On, job 209 still** (production scripts, `ZR_OIDN_DUMP` for the raw OIDN input):
   - **speckles:** pixels of the raw 256-spp accumulation brighter than 8x the median of their
     5x5 neighbourhood: count on vs off -- expected to drop;
   - **bias:** mean luminance change of the final PNG, reported (expected well under 1%);
   - **look:** crops of glossy surfaces seen in bounce light (table top, floor, vase) and of a
     mirror or glass seen directly (must stay sharp);
   - **time:** within +2% (warm shader cache);
   - no `Error compiling` in the log.
4. **Video:** job 216 keyframes 204-215 (24 spp) on vs off: raw speckle count per frame and a
   side-by-side clip for the owner.
5. Full doctest suite green.

## Shipping

The engine binary only (the owner copies it to production's `godot/bin/`); it is on by default.
To turn it off in production: `rendering/pathtracer/filter_glossy=0.0` under `[rendering]` in
`godot_project/project.godot`.

## Out of scope

Blue-noise sampling (the next spec); Filter Glossy on the one-shot / DLSS-RR route; volumes;
MNEE (we have none).
