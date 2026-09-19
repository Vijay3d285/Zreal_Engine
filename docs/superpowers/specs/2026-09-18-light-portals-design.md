# Light portals — sky sampling through the windows, Cycles' way

**Date:** 2026-09-18
**Status:** for review
**Branch:** `vijay_PTEngine_v26_RenderQuality`
**Roadmap:** `Full_Architectural_Gap_Roadmap.md` §3 Lights ("Light portals"), §4 priority #1
(first half; the daylight design, Gap #31 / §11.27, is the second half and a separate spec)

## What the source says (re-read 2026-09-18, Cycles 5.3.0-alpha)

`kernel/light/background.h`, `kernel/light/area.h`, `scene/light.cpp`,
`util/math_intersect.h`, `blender/light.cpp`:

1. **A portal is not a light. It is a sampling hint for the world.**
   `Light::has_contribution()` returns false for a portal (`scene/light.cpp:389`);
   `copy_to_kernel` fills the area fields and returns before the spread /
   emission fields (`:254`). Portals are stored *after* the real lights in the
   same kernel light array — `portal_offset = num_lights`,
   `num_portals` (`:1415-1416`, `:1438`) — and never enter the light tree or
   the light distribution.
2. **It changes how the sky is sampled, not what the sky is.** At a shading
   point `P`, `background_light_sample` (`background.h:333-433`) mixes three
   strategies with weights `portal_weight`, `sun_weight`, `map_weight`
   (`light.cpp:1224-1226`): portal 1 when any portal exists, map 1 when the
   world uses MIS, sun 4 only for a Nishita sky with a sun disc. The portal
   weight is zeroed at points where **no portal faces `P`**
   (`background_num_possible_portals`, `:247`), so an exterior view or a room
   with no window renders exactly as without portals. Strategy choice consumes
   `rand.x`, which is then rescaled and reused inside the chosen strategy
   (`:374-376`). The reported pdf is the weighted sum of every strategy's pdf
   for the chosen direction (`:425-432`), and `background_light_pdf`
   (`:436-470`) reports the same mixture for a BSDF-sampled ray that reaches
   the sky — called from `kernel/light/sample.h:591` with the ray's **origin**
   `ray_P`, since the mixture depends on which portals face the origin.
3. **Facing test** (`:153-170`): `dot(portal_dir, P − portal_pos) > 1e-4`,
   `portal_dir` the light's `−Z` (`safe_normalize(-column 2)`, `light.cpp:251`).
4. **Choosing and sampling a portal** (`background_portal_sample`, `:260-313`):
   `rand.y *= n_facing; index = int(rand.y); rand.y -= index` picks one facing
   portal uniformly, then samples a point on its rectangle with
   `area_light_rect_sample(..., sample_coord = true)` and divides the pdf by
   `n_facing`. When more than one portal faces `P`, the pdfs of the *other*
   facing portals the direction crosses are added (`background_portal_pdf`
   with `ignore_portal`, `:173-245`, which counts the ignored one in
   `num_possible` so the division stays `1/n_facing`): the pdf is the mean of
   the per-portal solid-angle pdfs over all facing portals, zero for a portal
   whose quad the direction misses (`ray_quad_intersect`,
   `util/math_intersect.h:288`, half-extent test `|u|, |v| ≤ 0.5`).
5. **The rectangle sampler is Ureña's spherical rectangle**
   (`area_light_rect_sample`, `area.h:19-102`): uniform in solid angle, with
   the `asin` reformulation for small rectangles and a planar-pdf fallback
   when the solid angle `S < 1e-5` or the rectangle is seen edge-on
   (`:89-100`). `sample_coord = false` evaluates only the pdf (`1/S`).
6. **Blender side:** the checkbox is the area light's `is_portal`
   (`blender/light.cpp:75`); rectangles and ellipses both work
   (`invarea < 0` marks an ellipse).

## What we have

- The sky enters the tracer through exactly two functions,
  `env_sample(rand, out dir, out pdf)` and `env_pdf(dir)`
  (`raytracing_env_sampling_inc.glsl:129,153`), a 256×128 map CDF in sky
  space with the world↔sky rotation applied inside. Three call sites: env NEE
  in `shade_and_bounce` (`raytracing_closest_hit_common_inc.glsl:1868`), the
  F2 scatter site in raygen (`scene_raytracing_raygen.glsl:130`), and the miss
  stage's MIS (`:557`). This is Cycles' `map` strategy alone; indoors most of
  its samples end in a wall, and the window's sky reaches the room mainly
  through BSDF rays that happen to escape — the noise the pipeline's "portal
  spots" were invented to hide (Gap #31).
- Godot 4.7 ships `AreaLight3D` (`scene/3d/light_3d.h:275`; `RSE::LIGHT_AREA`),
  a rectangle of `area_size` facing its `−Z`, axes `+X`/`+Y`
  (`light_storage.cpp:1118-1141`). **The tracer does not know the type**:
  `gather_lights()` (`render_raytracing.cpp:3646`) maps everything that is not
  a spot to `RT_LIGHT_TYPE_OMNI`, so an `AreaLight3D` renders as a point light
  in traced frames. Rect lights today are the 179.9° `SpotLight3D` convention
  (`size` = half-width, `spot_attenuation` = half-height, `:3645`).
- `RT_LightData` already carries a rectangle: `position`, `spot_direction`
  (half-width vector), `rect_axis_v` (half-height vector), `rect_half_height`
  (`render_raytracing.h:180-207`); the light buffer holds `RT_LIGHTS_MAX = 64`
  entries at binding 13, `RT_PARAM_LIGHT_COUNT` (slot 14) says how many are
  live. `rt_params` slots 18 and 19 (`[4].z`, `[4].w`) are free.
- The pipeline already knows every window: `_window_sunlight_data`
  (`image_glb_creation.gd:4038`) records `center`, `width`, `height`,
  `inner_dir` (into the room) per opening, in the wall plane. It feeds
  `_create_window_portal_lights()` (`:2822`), the spot-light fake.

## Approaches considered

- **1. A second strategy inside the sky sampler (chosen).** Cycles' structure:
  `env_sample`/`env_pdf` take `P`, mix portal and map 1:1 when a portal faces
  `P`, report the mixture pdf; the miss stage passes the ray origin. No other
  integrator site changes; with no portal in the buffer the code path is the
  one that exists today.
- 2. A portal as an entry in the light list returning sky radiance — a third
  strategy to MIS against at every site, and the reservoir selection would
  weight it by an energy it does not have.
- 3. Portal-only when a portal faces `P` — loses the sky a point also sees
  around a corner (terrace, a room open on one side); Cycles keeps both.

Authoring: **`AreaLight3D.portal`** (Blender's own model, visible in the
inspector) over an `Environment` list or a name convention.

## Design

### 1. Authoring and the raster (engine, C++)

- `AreaLight3D`: `set_portal(bool)` / `is_portal()`, property `portal`
  (default false) in the area group. Plumbed exactly like `light_negative`:
  `RenderingServer::light_set_portal(RID, bool)` (`rendering_server.h`),
  `FUNC2` in `rendering_server_default.h`, `RendererLightStorage` virtual
  (`servers/rendering/storage/light_storage.h`), RD `LightStorage::Light::portal`
  + setter + `light_is_portal()` getter, dummy stub.
- `LightStorage::update_light_buffers()`, `case RSE::LIGHT_AREA`
  (`light_storage.cpp:958`): `if (light->portal) continue;` — the raster never
  draws a portal (Cycles' `has_contribution` false). The pipeline also sets
  `shadow_enabled = false` and `light_energy = 0` on portals so no shadow map
  is rendered for them.

### 2. The light buffer, Cycles' layout (engine, C++)

`gather_lights(p_render_data, r_light_data, p_max_lights)`:

- New enum values: `RT_LIGHT_TYPE_PORTAL = 4` (C++ and GLSL, mirrored),
  `RT_PORTALS_MAX = 16`.
- First pass over `rt_lights`: collect `LIGHT_AREA` instances with
  `light_is_portal()` into a portal list (up to `RT_PORTALS_MAX`, extra ones
  dropped with a once-per-session warning). `portal_count` = its size.
- Analytic gather runs unchanged with capacity `p_max_lights − portal_count`;
  portals are **skipped** by the positional scorer (they must never enter the
  reservoir selection).
- Portals are written at `[light_count, light_count + portal_count)`:
  `position` = light origin; `spot_direction` = `basis.x.normalized() ×
  area_size.x / 2`; `rect_axis_v` = `basis.y.normalized() × area_size.y / 2`;
  `rect_half_height = area_size.y / 2`; `type = RT_LIGHT_TYPE_PORTAL`;
  `emission = 0`, `shadow_enabled = 0`, `ies_slot = −1`, everything else zero.
  The facing direction is `cross(axisV, axisU)` = the light's `−Z`, the same
  identity `lights_eval_rect_light` uses (`raytracing_lights_inc.glsl:520`).
- `gather_lights` returns the analytic count as before; a new out-parameter
  (or member) carries `portal_count`. Upload: `RT_PARAM_PORTAL_OFFSET = 18`
  (`[4].z`) = `light_count`, `RT_PARAM_PORTAL_COUNT = 19` (`[4].w`).
  `RT_PARAM_LIGHT_COUNT` stays the analytic count, so light selection, the
  emissive gather and every existing loop see nothing new.
- **Incidental fix in the same function:** a `LIGHT_AREA` that is *not* a
  portal becomes `RT_LIGHT_TYPE_RECT`: half-width `area_size.x / 2`,
  half-height `area_size.y / 2`, axes from the basis' `+X`/`+Y`, energy through
  `compute_light_energy(base, RSE::LIGHT_SPOT)` (the conversion the spot-rect
  convention uses, so the two rect paths agree), divided by
  `area_size.x × area_size.y` when `light_area_get_normalize_energy()` is on
  (the raster's rule, `light_storage.cpp:1144`). Colour, range, attenuation,
  specular, indirect energy, shadow flag: the same reads as the spot branch.

### 3. Portal sampling (engine, GLSL) — new `raytracing_portal_inc.glsl`

Included from every stage block of `scene_raytracing_raygen.glsl` after
`raytracing_lights_inc.glsl` (it reads `rt_lights`) and before
`raytracing_env_sampling_inc.glsl` (which calls it). Transcriptions, with the
Cycles line cited above each function:

- `int portal_offset()`, `int portal_count()` — `get_rt_param` reads.
- `bool portal_fetch_and_check_side(int i, vec3 P, out vec3 pos, out vec3 dir)`
  — `background.h:153`; `dir = normalize(cross(axisV, axisU))`;
  `dot(dir, P − pos) > 1e-4`.
- `float portal_rect_sample(vec3 P, inout vec3 light_p, vec3 axis_u, float len_u,
  vec3 axis_v, float len_v, vec2 rand, bool sample_coord)` — `area.h:19-102`,
  Ureña; `len_u = 2·|axisU|`, `len_v = 2·|axisV|`, `axis_u/v` the unit axes;
  returns the solid-angle pdf, writes the sampled point when `sample_coord`.
  Includes the `S < 1e-5 || min(nz²) > 0.99999` planar fallback and
  `safe_asin` (clamped to `[−1, 1]`).
- `bool portal_ray_quad_intersect(vec3 P, vec3 D, vec3 quad_P, vec3 inv_u,
  vec3 inv_v, vec3 n)` — `math_intersect.h:288`, `t > 1e-4`, `|u|,|v| ≤ 0.5`,
  no ellipse branch.
- `int portal_num_possible(vec3 P)` — `background.h:247`.
- `float portal_pdf(vec3 P, vec3 D, int ignore, out bool possible)` —
  `background.h:173-245`.
- `vec3 portal_sample(vec3 P, vec2 rand, int n_possible, out int chosen,
  out float pdf)` — `background.h:260-313`.

### 4. The mixture (engine, GLSL) — `raytracing_env_sampling_inc.glsl`

- `env_sample(vec3 P, vec2 rand, out vec3 dir, out float pdf)` —
  `background_light_sample` (`background.h:333-433`) minus the sun strategy:
  `w_portal = portal_count() > 0 && n_possible > 0 ? 1 : 0`,
  `w_map = marginal_total > 0 ? 1 : 0`; both zero → return false (today's
  behaviour with no sky). Normalise, choose on `rand.x`, rescale `rand.x`
  inside the chosen strategy, sample; the reported pdf is
  `w_chosen · pdf_chosen(dir) + w_other · pdf_other(P, dir)` — the sampler's own
  pdf for its term (for a portal sample that already includes the other facing
  portals, `:381-383`), the evaluator for the other (Cycles' "skip MIS if this
  is the only method" shortcuts included, `:386-388`).
  The existing map sampler moves into `env_map_sample(rand, out dir, out pdf)`
  unchanged; `env_pdf_from_uv` and the sky-space contract are untouched.
- `env_pdf(vec3 P, vec3 dir)` — `background_light_pdf` (`:436-470`):
  portal term only when `possible`, same normalisation, same NaN scrub as
  today.
- Call sites: `shade_and_bounce` passes `h.hit_pos`; the raygen scatter site
  passes the scatter position `p_pos`; the miss stage passes
  `gl_WorldRayOriginEXT` (Cycles' `ray_P`, `sample.h:591`). The direction
  tests, shadow ray, sky lookup, `RT_ENV_NEE_ENABLED` guard and MIS weights
  around them do not change.
- With `portal_count() == 0` the mixture collapses to `w_map` only; the
  chosen-strategy shortcut returns the map sample and pdf exactly as today —
  the no-portal render must be bit-identical (checked in the gate's P4 and by
  the whole suite).

### 5. Pipeline hookup (`pipeline_references/image_glb_creation.gd`, uncommitted)

`_create_window_portals()`, called next to `_create_window_portal_lights()`
for day renders: per `_window_sunlight_data` record one `AreaLight3D` named
`WindowPortal_<i>`, `position = center`, `area_size = Vector2(width, height)`,
`look_at(center + inner_dir, Vector3.UP)` (so `−Z` points into the room),
`portal = true`, `light_energy = 0.0`, `shadow_enabled = false`,
`area_normalize_energy = false`. Prints one line per portal. Nothing else in
the rig changes — the portal spots, fills and exposure are sub-project B's.

### 6. Not changed

- Sun sampling (`DirectionalLight3D` is an analytic light, not the sky's
  Nishita sun disc; `sun_weight` stays absent).
- Ordinary rect lights keep uniform-area sampling; Ureña is available for a
  later variance pass.
- Ellipse portals, area-light spread, the light tree.

## Gate: `pt_portal_gate` (new; suite goes to 22)

`pipeline_references/tests/pt_portal_gate.gd` + `pt_portal_gate_scene.tscn`,
run headless the usual way. Fixture: a closed 4 (x) × 3 (y) × 3 (z) m room,
six planes facing inward, albedo linear 0.8 authored via `linear_to_srgb()`;
one 1.2 × 1.0 m opening cut in the left wall (the wall is four quads around
the hole, sill at y = 0.9); no lamps; a flat white world of 1.0 (F3's
`BG_COLOR` path — the same uniform world Cycles gets); camera at
(0.0, 1.5, 1.2) looking at the back wall (0, 1.5, −1.5); msaa/FXAA/TAA/
debanding off (memory: gates inherit project AA). Crops are stated in
fractions of the frame; the back-wall crop avoids the window's direct patch.

| probe | fixture | reads | bar |
|---|---|---|---|
| P1 unbiased | portal on vs portal off, 1024 spp each | back-wall crop and floor crop, on ÷ off | 1 ± 1% both |
| P2 variance | 16 spp, on and off | per-pixel RMS over the back-wall crop against the 1024-spp render of the same crop, on ÷ off | captured from the first measurement on this build and written into the gate with margin; must be < 1 (bar is the *point* of the feature — it goes red if the portal quietly does nothing); expected ≤ 0.5 |
| P3 Cycles | portal on, 1024 spp | back-wall and floor crop means | ± 3% vs `tools/cycles_comparison/cycles_portal_room.py` (same room, one area light `is_portal`, world strength 1, 1024 spp, no denoise) |
| P4 side test | the same portal flipped (`−Z` pointing outdoors), so no surface in the room faces it | flipped vs portal off, 16 spp | pixel-identical (max abs diff 0 over the frame) — the facing test must zero the strategy everywhere, and the RNG stream must not shift |
| P5 area light | a 1 × 1 m `AreaLight3D`, normalize off, energy 1, 1 m over a floor, vs the 179.9° spot-rect of the same size/energy | floor crop, area ÷ spot-rect | 1 ± 1% |

Whole suite on the new binary green (22/22); old hand-over binary green
except the new gate (P2, P3 and P5 red by design; P1 and P4 pass trivially there); doctest
count unchanged; frame time on a no-portal gate scene within noise; job 226
rendered through the still route with the pipeline's portals, once with
`ZR_LIGHTS_SKIP=pos` (sun + sky + portals only) for a look at what the window
does on its own, and a timing.

## Out of scope (recorded)

- The daylight design (Gap #31, §11.27): physical sun/sky ratio, exposure
  probe, AgX, one fill, removal of the portal spots — sub-project B.
- Ellipse portals; Nishita sun guiding (`sun_weight`); area-light spread.
- Ureña sampling for ordinary rect lights (function will exist).
- Light tree / many-light sampling.
