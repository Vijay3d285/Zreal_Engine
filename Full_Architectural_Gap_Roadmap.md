# Full architectural gap roadmap — Blender/Cycles vs our RTX tracer

**Written 2026-09-18, re-verified against the code 2026-09-18.** Every line below was
checked by reading our shaders (`servers/rendering/renderer_rd/shaders/raytracing/`),
the tracer's C++ (`forward_clustered/render_raytracing.cpp`, `scene_shader_raytracing.cpp`)
and the Cycles source (`intern/cycles/`, 5.3.0-alpha) — not the roadmap tables. Each stage
has a **Verified in code** block naming the evidence. Three lines of the first draft were
wrong or incomplete and are corrected here: the fp16 payload (closed since 2026-08-09),
"no node graphs" (custom shaders are supported for the base PBR inputs), and lens shift
(supported through Godot's frustum offset).

Companion documents: `PATH_TRACER_QUALITY_ROADMAP.md` (the gap table and per-phase
closeouts, §11.27–11.30 for the parked gaps and the F2 follow-ups).

---

## 1. The two pipelines side by side

| Stage | Blender → Cycles | Ours (Godot fork → RTX tracer) |
|---|---|---|
| **Geometry in** | Blender scene: meshes, **subdivision surfaces (adaptive dicing), true displacement, hair/curves, point clouds, OpenVDB volumes**, instances, per-object motion steps | glTF → Godot `MeshInstance3D` (triangles only), MultiMesh merged into one BLAS, procedural shapes via intersection shaders, compressed vertex formats. No subdivision, displacement, hair or volume objects. |
| **Scene assembly** | Per-object: ray-visibility flags for *every* ray type (camera / diffuse / glossy / transmission / volume / shadow), **light linking & shadow linking**, holdout, **shadow catcher**, shadow-terminator offsets, pass IDs / cryptomatte. BVH built by Embree/OptiX. | Per-instance: `cast_shadow` (→ shadow visibility, Gap #30), opaque/transmissive masks, two-pass transparent shadows. TLAS/BLAS by Vulkan RT. No light linking, holdout, catcher. |
| **Lights** | Point (sphere), spot (with radius, blend, spread), area (rect/ellipse, **spread angle**, **portal**), sun (angular size), world background (HDRI / **Nishita sky**) with importance sampling, emissive meshes, **light tree** for many lights, IES, MNEE caustics | Omni (sphere), spot (cone, IES), rect, sun (angular size), sky via radiance octmap + CDF, emissive meshes via CDF, IES. Power-weighted reservoir selection instead of a light tree. No spread, no portals, no caustics. |
| **Camera** | Perspective / orthographic / panoramic (equirect, fisheye, mirror-ball), **depth of field** (aperture, blades), **motion blur** (shutter curve, rolling shutter), sensor fit, lens shift, stereo | Pinhole perspective (`camera_ray`, one origin per frame) **with lens shift** (Godot `PROJECTION_FRUSTUM` + `frustum_offset` flows through the inverse projection). No DoF in the tracer, no motion blur, no panoramic; orthographic renders wrong (origin never moves per pixel). |
| **Integrator** | Unidirectional PT with MIS, NEE, RR, per-type bounce caps, clamp, adaptive sampling, Sobol-Burley / tabulated Sobol / **blue-noise** patterns, **path guiding** (Open PGL), **Filter Glossy**, random-walk SSS, volumes (homogeneous + heterogeneous, equiangular + MIS), transparent shadows | Same skeleton: MIS, NEE (3 light classes), RR, caps, clamp, adaptive, Sobol-Burley Owen. SSS random walk ✓. Volumes: homogeneous, single-scatter, bounded box (F2). No guiding, no filter-glossy, no blue noise. |
| **Shading** | Full **node graph** (any texture math, procedural noise/voronoi/wave, color ramps, mix, layer weights, OSL); Principled v2 with **thin-film iridescence**, sheen, coat, anisotropy, SSS incl. skin mode; hair/toon/translucent/ray-portal BSDFs; **bump AND true displacement** | Two material paths: (a) glTF / `StandardMaterial3D` → the full fixed model (base/metal/rough/normal/ORM/emission, transmission+IOR+thickness+attenuation, specular tint, anisotropy, coat, sheen, SSS); (b) **custom `ShaderMaterial` / VisualShader code compiled into per-material RT hit groups** — honoured for ALBEDO, ALPHA, ROUGHNESS, METALLIC, SPECULAR, EMISSION, NORMAL, NORMAL_MAP; forced opaque, no coat/anisotropy/sheen/SSS on that path. Energy-compensated GGX on Cycles' tables (Gaps #17/#19/#20/#23). Normal maps only. No thin-film, no displacement. |
| **Film / output** | Pixel filter BH 1.5 ✓, exposure, transparent film, **many passes** (diffuse/glossy direct+indirect, emission, AO, mist, normal, depth, cryptomatte, shadow catcher), EXR multilayer | BH 1.5 ✓, EXR 32f / PNG16 ✓, beauty + OIDN guides + depth/velocity. No light-component passes, no cryptomatte. |
| **Denoise / colour** | OIDN (albedo+normal prefilter) or OptiX; AgX / Filmic / Standard, exposure, look, white balance | OIDN with accumulated guides ✓ (Gap #29), Linear/Reinhard/Filmic/ACES/AgX ✓. DLSS-RR for video. No white balance / looks. |
| **Precision** | fp32 throughout | fp32 accumulator (Gap #0) **and fp32 payload radiance/throughput (Gap #14, closed 2026-08-09, Phase B1)**. |

---

## 2. What we now match (and measured)

The integrator core is at parity where it counts for stills: MIS, three-class NEE, bounce
controls, RR, clamp, Sobol-Burley, Cycles' multi-scatter GGX tables, exact dielectric
Fresnel + layering, anisotropy, coat, sheen, transmission with glass energy tables,
thin-wall rule, random-walk SSS, bump-map correction (F1), bounded volumes (F2), pixel
filter, OIDN guides, shadow visibility. Every one has a Cycles-side comparison in the gate
suite (21 gates).

**Verified in code (2026-09-18)** — one anchor each, all present in
`servers/rendering/renderer_rd/shaders/raytracing/`: `power_heuristic` (MIS, 21 sites),
`lights_evaluate_direct_lighting` / `env_sample` / `emissive_sample` (the three NEE
classes), `RT_PRNG_TERMINATE` (RR), `RT_GET_MAX_TRANSMISSION_BOUNCE` + the
diffuse/glossy caps, `clamp_contribution`, `sobol_burley_sample`,
`evalMultiScatterEnergy` (GGX tables), `evalFresnelBase` (exact dielectric Fresnel),
`ggxAnisoAlphas`, `evalCoat`, `evalSheen`, `sampleDielectricMicrofacet` +
`ggxGlassEnergyScale`, the thin-wall branch, the SSS random walk,
`ensureValidSpecularReflection` + `bumpShadowingTerm` (F1), `volume_box_clip` (F2),
`bh_inv_cdf_half` (BH 1.5), `rt_accum_guide_sample` (OIDN guides),
`RT_INSTANCE_MASK_NO_SHADOW` (shadow visibility), `rgba32f` accumulator
(`render_forward_clustered.cpp:133`, `R32G32B32A32_SFLOAT`), `RT_PARAM_NOISE_THRESHOLD`
(adaptive sampling in raygen).

---

## 3. What's missing — by stage, with what each would change

### Geometry
| Gap | Cycles | Us | If we built it |
|---|---|---|---|
| **Subdivision + true displacement** | Adaptive dicing to sub-pixel micropolygons, displacement moves vertices | Triangles as imported; displacement approximated by normal maps | Real relief on stone, brick, fabric, terrain — silhouettes and shadows that a normal map can't produce. Big lever for close-ups; heavy (needs a tessellation pass before BLAS build). |
| **Hair / curves** | Curve primitives with a hair BSDF | None | Rugs, plants with fine strands, fur. Medium-large. |
| **Motion blur** | Per-object motion steps + shutter | Motion transforms exist but feed only the DLSS velocity image | Only matters for video / moving objects. Medium. |

**Verified in code:** `grep subdiv|tessellat|displace|curve|hair|strand` over the RT shaders and
`render_raytracing.cpp` returns nothing but comments; `motion_transforms` (binding 32) is read
only to write `rt_velocity_image` (`raytracing_closest_hit_common_inc.glsl:254`,
`scene_raytracing_raygen.glsl` primary miss) — no shutter sampling anywhere. Cycles side:
`scene/mesh_subdivision.cpp`, `mesh_displace.cpp`, `hair.cpp`, `curves.cpp`, `pointcloud.cpp`,
`volume.cpp`.

### Scene assembly
| Gap | Cycles | Us | If we built it |
|---|---|---|---|
| **Light linking / shadow linking** | Any light can be told which objects it lights or shadows | None in the tracer — Godot already has the authoring control (`light_cull_mask` / layers) but the RT light gather never reads it | The archviz cheat everyone uses: a fill light that only touches the sofa, a pendant that doesn't cast the hard shadow of its cable. **Small** (a mask on `RTLightData` + a compare in the three NEE sites and the shadow query). |
| **Per-ray-type visibility** | Camera / diffuse / glossy / transmission / volume separately | Only shadow (`cast_shadow`). Camera layers remove an object from the TLAS entirely (all-or-nothing), not per ray type | Hide a light-blocking card from the camera but keep its bounce; keep glass out of reflections. Small. |
| **Shadow catcher / holdout** | Objects that catch shadows onto a transparent film | None | Compositing renders onto photos. Medium. |
| **Shadow-terminator offsets** | Per-object smoothing of the terminator on low-poly smooth meshes | None | Removes the faceted shadow line on cheap curved geometry (sofas, vases). Small. |

**Verified in code:** `RTLightData` (`raytracing_lights_inc.glsl:40-62`) has position, type,
emission, radius, attenuation, range, specular_amount, indirect_energy, spot cone, shadow_enabled,
rect axes, IES — no mask field; `grep cull_mask|layer` in `render_raytracing.cpp` and the lights
include: nothing. Instance masks come only from `rt_instance_mask()` (`render_raytracing.cpp:2588`,
`cast_shadows_setting`) and the opaque/transmissive feature bits. `grep holdout|catcher|
terminator_offset|shading_offset`: nothing. Cycles side: `scene/object.h:55-57`
(`is_shadow_catcher`, the two terminator offsets), `:73-76` (light/shadow linking sets).

### Lights
| Gap | Cycles | Us | If we built it |
|---|---|---|---|
| **Light portals** | An area light marked *Portal* guides sky sampling through a window | Pipeline fakes it with spot lights (the "portal spots" that paint stripes, Gap #31) | **The single biggest daylight-interior win**: the real sky through the real windows, with a fraction of the noise, and no fake spots. Medium. |
| **Light tree** | Hierarchical, energy + orientation aware selection over thousands of lights | Power-weighted reservoir (good to ~50 lights) | Cleaner results with many small fixtures; our reservoir ties Cycles in the 16-light box test, so this is a scaling item, not a look item today. Medium-large. |
| **Area-light spread** | Rect lights with a cone of emission | Lambertian rects only | Softbox / recessed-panel look. Small. |
| **Nishita physical sky** | Full atmospheric sun+sky model | HDRI or Godot's `PhysicalSkyMaterial` (Rayleigh/Mie analytic model; reaches the tracer through the radiance octmap) | A more accurate sun colour/haze at low sun angles. Small-medium; low priority while HDRIs are used. |
| **Caustics (MNEE)** | Opt-in shadow caustics through glass | None | Light patterns under a glass table/vase. Large; niche. |

**Verified in code:** selection is `lights_select_weight` / `lights_select`
(`raytracing_light_select_inc.glsl:35,150`), a reservoir with no hierarchy; `grep spread|portal|
manifold|mnee` in the lights code and `render_raytracing.cpp`: nothing; sun angular size **is**
supported (`ld.radius = deg_to_rad(LIGHT_PARAM_SIZE * 0.5)`, `render_raytracing.cpp:3600`,
`cos_theta_dir = cos(light.radius)` in the lights include). `sky_material.h:164-175` is
`PhysicalSkyMaterial` with `rayleigh`/`mie` terms. Cycles side: `scene/light.h:145-146`
(`spread`, `is_portal`), `kernel/light/tree.h`, `kernel/light/area.h:104`.

### Camera
| Gap | Cycles | Us | If we built it |
|---|---|---|---|
| **Depth of field** | Thin-lens aperture, bokeh blades, in the tracer | None (Godot's post blur is not on the traced route) | Real photographic focus falloff, proper bokeh on pendants and highlights — a standard archviz look. **Small** (a lens sample in `camera_ray` + one RNG dimension). |
| **Orthographic** | Yes | **Wrong today**: the origin never varies per pixel, so an ortho camera renders every pixel from one point | Plan/elevation renders. Small. |
| **Panoramic (equirect / fisheye)** | Yes | None | 360° panoramas for VR/web viewers. Small. |
| ~~Lens shift~~ | Yes | **Supported** — Godot `PROJECTION_FRUSTUM` + `frustum_offset` flows through `inv_projection_matrix`, which `camera_ray` uses for every direction | (no gap) |

**Verified in code:** `camera_ray` (`scene_raytracing_raygen.glsl`) builds `r_origin` from
`inv_view * (0,0,0,1)` — fixed — and `r_dir` from `inv_projection_matrix * (d.x, d.y, 1, 1)`, so an
asymmetric (shifted) frustum works and an orthographic one does not; `grep aperture|focus|shutter|
panoram|fisheye|equirect` over the tracer: nothing. `camera_3d.h:46-47,70` has
`PROJECTION_ORTHOGONAL`, `PROJECTION_FRUSTUM`, `frustum_offset`. Cycles side:
`kernel/camera/camera.h:75-79` (aperture), `:103-123` (stereo), panoramic in the same file.

### Integrator & sampling
| Gap | Cycles | Us | If we built it |
|---|---|---|---|
| **Path guiding** (Gap #32) | Open PGL, CPU only, opt-in | None | Less grain on bounce-lit ceilings and corners — the pendant-cable case. Large; GPU port. |
| **Blue-noise dithering** | Newer sampling pattern (4.3+) | Sobol-Burley only | Noise looks smoother at low sample counts; same average. Small-medium. |
| **Filter Glossy** | Blurs sharp glossy on rough-bounce paths to kill fireflies | Indirect clamp only | Fewer fireflies without dimming. Small. |
| **Equiangular volume sampling** (F2 follow-up) | For lamps inside haze | Distance sampling only | Clean lamp-lit fog. Medium. |
| **Multiple scattering in volumes** | `volume_bounces` > 0 | Single scatter | Thick steam/clouds. Medium (needs a payload bit). |
| **Emissive-mesh light at scatter points** (F2 follow-up) | Yes | Lamps and sky only | Glowing panels lighting the haze around them. Small-medium. |
| ~~fp16 payload (Gap #14)~~ | fp32 | **fp32 since 2026-08-09** (`PathPayload.radiance/throughput` are `vec3`; the old fp16 packing clamped at 65504) | (closed — Phase B1, commit e0f5521d9b) |

**Verified in code:** `grep guiding|openpgl|blue_noise|dither|filter_glossy|glossy_filter` over the
RT shaders and `render_raytracing.cpp`: nothing; the sampler is `sobol_burley_inc.glsl` with PCG
only on the `RT_LIGHT_SELECT_UNIFORM` control path (`raytracing_inc.glsl:338`). F2's
`volume_scatter_shade` (raygen) does lamps + one `env_sample`, then terminates; the free-flight
draw is distance-only. `PathPayload` (`raytracing_inc.glsl:61-63`) is fp32. Cycles side:
`kernel/types.h:122-128` (sampling patterns), `scene/integrator.cpp:100-121` (guiding, caustics,
Filter Glossy), `kernel/integrator/shade_volume.h:727` (equiangular).

### Materials
| Gap | Cycles | Us | If we built it |
|---|---|---|---|
| **Shader node graphs — extended lobes** | Unlimited node graphs drive every Principled input | **Custom `ShaderMaterial` / VisualShader graphs are compiled into per-material RT hit groups** and drive ALBEDO, ALPHA, ROUGHNESS, METALLIC, SPECULAR, EMISSION, NORMAL, NORMAL_MAP; that path is forced opaque and ignores coat / anisotropy / sheen / SSS (those exist only on the glTF / `StandardMaterial3D` path) | Procedural base materials already work. What's missing is node-driven glass, coat, anisotropy, sheen and SSS. Medium (route the extra outputs through the custom hit group's `MaterialResult`). |
| **Thin-film iridescence** | Principled v2 | None | Soap-bubble / coated-glass tints. Small-medium; niche. |
| **Translucent leaves (two-sided thin)** | Translucent BSDF | SSS thin-wall mode covers part | Backlit foliage glow. Small. |
| **Texture sampling** | Cubic filtering, no mips | Linear, base level only in RT stages (no implicit derivatives) | Comparable; both rely on pixel-filter jitter. No action. |

**Verified in code:** `RT_CUSTOM_HIT_GROUP` + `raytracing_custom_fragment_inc.glsl`
(`scene_raytracing_raygen.glsl:665-700`): the compiled `fragment` code
(`scene_shader_raytracing.cpp:593`) fills `MaterialResult` from `albedo/alpha/roughness/metallic/
specular/emission/normal/normal_map`, then `m.transmission = 0.0`, `m.thickness = 0.0`; the coat /
anisotropy / sheen / SSS flags are "deliberately NOT set" for custom hit groups
(`scene_shader_raytracing.cpp:729`). `grep thin_film|iridesc`: nothing; `sssThin`
(`brdf_inc.glsl:369`) is the thin-wall SSS split. Texture reads go through `texture()` with a
mipmapped sampler in a ray-tracing stage (`raytracing_closest_hit_common_inc.glsl:123`) — no
implicit derivatives, so the base level. Cycles side: `kernel/svm/closure.h:301-402` (thin film).

### Output & colour
| Gap | Cycles | Us | If we built it |
|---|---|---|---|
| **Render passes / cryptomatte** | Diffuse/glossy/emission direct+indirect, AO, mist, cryptomatte | Beauty + guides + depth/velocity | Post-production control (relight, fog, per-object masks in Photoshop/Nuke). Medium; many are near-free once the accumulator is split. |
| **White balance / looks** | 5.x colour management | Tone mapper only (Linear / Reinhard / Filmic / ACES / AgX) | Small colour-pipeline polish. |

**Verified in code:** the images the tracer binds are `image`, `rt_accum`, `rt_accum_n`,
`rt_accum_albedo`, `rt_accum_normal`, `rt_depth_image`, `rt_velocity_image` and the four DLSS
guides (`raytracing_common_inc.glsl`, `scene_raytracing_raygen.glsl`); `grep cryptomatte|
diffuse_direct|PASS_`: nothing. Tone mappers: `rendering_server_enums.h:693-697`; `grep
white_balance|temperature` in the environment: nothing. Cycles side: `kernel/types.h:362-411`
(the pass list).

---

## 4. Non-technically: what would move the picture most, in order

1. **Light portals + a daylight design** (Gap #31 + portals) — the daylight interiors are currently lit by 17 fake lamps because the sky couldn't come in. Now it can; a portal makes it come in *cleanly*. This changes the look of every day render more than anything else on the list.
2. **Depth of field in the tracer** — cheap, and it's the difference between "a render" and "a photograph" in most archviz stills.
3. **Light linking** — the everyday artistic control archviz lighting depends on; Godot already exposes the mask, the tracer just has to honour it. Removes a whole class of "why is that light hitting the ceiling" fixes.
4. **Passes + cryptomatte** — lets an artist finish the image in post rather than re-rendering.
5. **Blue-noise + Filter Glossy** — same images, visibly calmer grain at the pipeline's sample counts.
6. **Subdivision/displacement, and node-driven glass/coat/sheen/SSS** — the two remaining authoring gaps; worth it only when assets start relying on them (procedural base materials already work through custom hit groups).
7. **Path guiding, MNEE caustics, hair** — the research-grade items; large effort, narrow benefit for interiors.
