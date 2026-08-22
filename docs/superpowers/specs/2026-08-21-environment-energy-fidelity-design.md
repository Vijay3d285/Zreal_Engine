# Environment Energy Fidelity (E2a) — Design

**Branch:** `vijay_PTEngine_v12_PhaseE` (continues from E1's closeout at `4dfb1b00b1`)
**Status:** design, awaiting review
**Predecessor:** `2026-08-19-transmission-rough-glass-design.md` (E1)
**Successor:** E2 proper (anisotropy, clearcoat, sheen, N-way lobe rewrite)

---

## 1. Goal

Close the **~23% uniform dimming of environment-lit response versus Cycles**
found while building E1 Task 8's measurement harness, recorded in
`PATH_TRACER_QUALITY_ROADMAP.md` §7.4, and reproduced on a control scene
containing **zero** transmissive geometry.

It is the largest known fidelity gap in this project and it affects every
environment-lit render, not only scenes that use a particular material
feature. That is why it is scheduled ahead of E2's own scope.

## 2. The measurement being explained

From the no-glass control render (roadmap §7.1), ours over Cycles:

| Channel | ours | Cycles | ratio |
|---|---|---|---|
| R | 0.181181 | 0.234934 | 0.7712 |
| G | 0.182560 | 0.236366 | 0.7724 |
| B | 0.192737 | 0.248631 | 0.7752 |

**The spread across RGB is 0.5%.** That is the single most informative
feature of this data and the roadmap did not draw it out. It says the defect
is a **scalar gain**, not a spectral or filtering artefact. The roadmap's own
leading candidate — "HDRI resolution/filtering loss ... a small bright source
averaged away by a coarse box filter" — predicts a *chromatic* loss, because
a sun is warm: R would be dimmed several percent more than B. In that form it
is weakly contradicted by its own data. §4.2 restates it in a form that
survives.

The correction factor to recover is `1 / 0.772 = 1.295`.

## 3. What the existing gates already prove, and what they cannot

### 3.1 The integrator is exonerated

`pipeline_references/tests/pt_energy_gate.gd` Gate 1 is already an analytic
energy test: constant-radiance environment, one unoccluded Lambertian plane
of albedo `rho = 0.5`, no analytic lights, asserting

```
L_o = integral over hemisphere of (rho / PI) * L * cos(theta) dw  =  rho * L
```

to a 1% tolerance (`pt_energy_gate.gd:91-93`). It passes. Given whatever
radiance the renderer sees, the surface response is analytically correct.

**A white-furnace test was the obvious next instrument and would have been
wasted.** It is this gate, and this gate is green. Recorded here so the next
person does not build it a second time.

### 3.2 ...and the gate is blind to this defect by construction

Gate 1's own header states it (`pt_energy_gate.gd:196-200`):

> Pass A: plane hidden, so every camera ray misses and lands on the sky [...]
> Measures L_env as the renderer actually sees it, absorbing
> `IBL_exposure_normalization`, the sky shader's own scaling and the octmap
> round trip. **The gate is a RATIO against this, so no global sky scale can
> fake a pass or a failure.**

`expected = ALBEDO * l_sky`, where `l_sky` is measured *from the render*
(`:206`, `:222`). Any energy loss upstream of both the sky pass and the
surface pass cancels exactly.

That is the correct design for testing the integrator, and it is precisely
the wrong instrument for this defect: **a 23% uniform dimming IS a global sky
scale.** This is the same shape as E1's four escapes — an assertion that is
correct but cannot fail in the direction that matters.

**A constant sky is additionally invariant to resolution.** Gate 1's header
notes that invariance for rotation, border and cell lookup, but not for
resolution. That omission is the specific hole this phase fills.

### 3.3 Where the defect therefore lives

Upstream of shading: the chain `source panorama -> sky render -> radiance
octmap -> env_sky_radiance()`, or the scalar applied at the end of it.

## 4. Two candidate mechanisms, both read-verified

Both were verified by reading the named files at design time, not
transcribed from memory or from another document. E1's F1/F2/F3 all
originated as transcription errors in a design spec and were then faithfully
implemented; see that spec's §3.2 erratum.

### 4.1 Mechanism A — `IBL_exposure_normalization`

`servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl:306`
multiplies sky radiance by a scalar:

```glsl
sky_color *= scene_data_block.data.IBL_exposure_normalization;
```

Set at `servers/rendering/renderer_rd/storage_rd/render_scene_data_rd.cpp:246-252`:

```cpp
ubo.IBL_exposure_normalization = 1.0;
if (p_env.is_valid()) {
    RID sky_rid = render_scene_render->environment_get_sky(p_env);
    if (sky_rid.is_valid()) {
        float current_exposure = RSG::camera_attributes->camera_attributes_get_exposure_normalization_factor(p_camera_attributes)
                * render_scene_render->environment_get_bg_intensity(p_env) / p_luminance_multiplier;
        ubo.IBL_exposure_normalization = current_exposure
                / MAX(0.001, render_scene_render->get_sky()->sky_get_baked_exposure(sky_rid));
    }
}
```

`sky_get_baked_exposure` returns `sky->baked_exposure`
(`servers/rendering/renderer_rd/environment/sky.cpp:1618-1622`), which is
assigned `p_luminance_multiplier` at `:1354`.

This is a scalar, achromatic multiply on sky radiance with no counterpart in
Cycles. **If it is not 1.0 in the measured scene, it is the whole defect.**
Note the enclosing branch is entered only when `p_camera_attributes` is
valid, so whether it fires at all is scene-dependent — which is itself worth
establishing.

**Predicts:** the same factor at every sky peakedness, including a constant
sky.

### 4.2 Mechanism B — the radiance map is a point subsample

The path tracer does not sample the panorama. It binds Godot's
roughness-prefiltered raster IBL map:
`servers/rendering/renderer_rd/forward_clustered/render_raytracing.cpp:3782`
calls `sky_get_radiance_texture_rd(sky_rid)`, and `env_sky_radiance()` reads
it through `vec3_to_oct_with_border` at mip 0.

That map is **256x256**, force-clamped for realtime skies:
`servers/rendering/renderer_rd/environment/sky.h:248` declares
`static inline const int REAL_TIME_SIZE = 256;`, and `sky.cpp:593-595`
overrides any other requested size with a warning.

The panorama reaches that map through `PanoramaSkyMaterial`'s generated
shader (`scene/resources/3d/sky_material.cpp:502-509`):

```glsl
uniform sampler2D source_panorama : %s, source_color, hint_default_black;
uniform float exposure : hint_range(0, 128) = 1.0;

void sky() {
	COLOR = texture(source_panorama, SKY_COORDS).rgb * exposure;
}
```

where `%s` is `filter_linear` or `filter_nearest` (`:509`). **No mipmaps, no
LOD, no area averaging.** `texture()` here is a bilinear — or, on the
`filter_nearest` path, a nearest — point sample. Rendering a high-resolution
panorama into a 256x256 map through a point sampler is a **subsample, not an
average**, and a subsample does not preserve the integral of a peaked
function.

This is the sharpened, correct form of the roadmap's "filtering loss"
candidate, and the distinction is load-bearing: **a box filter preserves the
mean and would NOT dim diffuse GI at all**, since diffuse response is
essentially a hemispherical mean. A point subsample does lose energy. The
roadmap named the right suspect for the wrong reason, which is why §2 finds
its stated form contradicted by the data while this form is not.

**Predicts:** loss grows with the angular peakedness of the sky and vanishes
for a constant sky — which is exactly why Gate 1 passes.

### 4.3 Why the discrimination is clean

The two mechanisms make *opposite* predictions as peakedness varies at fixed
total energy. One experiment separates them.

## 5. Design

### 5.1 Task 1 — the absolute sky-energy gate

New `pipeline_references/tests/pt_sky_energy_gate.gd` +
`pt_sky_energy_gate_scene.tscn`, following the conventions of the five
existing gates (`extends "res://tests/pt_validation.gd"`, headless-runnable,
prints per-probe numbers, accumulates `_failures`).

It measures the one quantity Gate 1 computes and then divides away: **the sky
as the renderer sees it, against the sky as authored.**

Procedure, repeated at three peakedness levels:

1. Generate a panorama `Image` procedurally in GDScript, so its mean radiance
   over the sphere is known in closed form rather than measured.
2. Build a `PanoramaSkyMaterial` -> `Sky` -> `Environment`. **Not
   `BG_COLOR`** — roadmap F3: `BG_COLOR` renders pure black to the path
   tracer, because `env_sky_radiance()` reads `radiance_octmap`, which the
   sky pass only populates for `BG_SKY` with a real `Sky` resource.
3. Render sky-only, with no geometry, and accumulate.
4. Assert the measured mean equals the analytic mean.

The three levels hold **total radiant energy constant** and vary only its
angular concentration:

| Level | Panorama | Purpose |
|---|---|---|
| C | Constant radiance | Invariant to resolution. Isolates Mechanism A. |
| B | Broad lobe, roughly 1 steradian | Intermediate point; makes the trend readable rather than binary. |
| N | Narrow patch, under 0.01 steradian, same total energy | Maximally exposed to point subsampling. Isolates Mechanism B. |

**Reading the result:**

- All three off by the same factor -> **Mechanism A**. The factor is
  `IBL_exposure_normalization`; read it directly to confirm.
- C clean, B slightly off, N badly off -> **Mechanism B**. The loss is
  resolution-dependent.
- All three clean -> both mechanisms are wrong, and the defect is in
  Cycles-side setup: colour management, or `gen_panorama.py`'s own scaling.
  This outcome is explicitly in scope. It would mean the 23% is a
  measurement artefact rather than an engine defect — a legitimate and
  valuable finding, not a failed phase.

A fourth probe reads `IBL_exposure_normalization` directly through a new
debug vis mode (**34** — modes 0-33 are allocated) so its value is observed
rather than inferred, whichever way the sweep lands.

### 5.2 Task 2 — the fix

Determined by Task 1, and deliberately not pre-committed here. E1 shipped
three defects that originated in a spec asserting an implementation before
the evidence justified it.

**If Mechanism A:** a bounded change at the sky-radiance site. Cycles applies
no such normalization; the path tracer should either not apply it, or apply
its exact inverse elsewhere. Small, and directly testable by the new gate.

**If Mechanism B:** the honest fix is that **the path tracer should stop
borrowing the raster IBL map and sample the panorama directly**, which is
what Cycles does. That is the larger change and the right one: it removes a
256x256 resolution ceiling from every path-traced sky, not merely a scale
error. A cheaper variant — generating the radiance map with a proper
area-averaging downsample, or raising its resolution — narrows the gap
without closing it, and should be chosen only if direct sampling proves
disproportionate.

Either way the environment CDF (`env_cdf_build.glsl`) is built from the same
bound texture and **must move with it**, or NEE and the miss shader will
disagree about what the sky is. That is the B2 defect class: two strategies
estimating different integrands, which MIS cannot repair.

### 5.3 Task 3 — re-baseline and confirm

Per the scope decision, the fix lands unflagged and everything downstream is
re-baselined in the same phase.

1. Re-run all five GPU gates plus `pt_validation`. Record every old and new
   number side by side. **The changes are expected**, and a gate that does
   *not* move is evidence the fix did not reach it.
2. `pt_energy_gate` Gate 1 must **still pass** — it is a ratio and is
   invariant to a global sky scale, so a fix that breaks it has changed
   something it should not have.
3. Only then reproduce E1 Task 8's Cycles comparison, as **confirmation**
   rather than as the instrument.
4. Update `PATH_TRACER_QUALITY_ROADMAP.md` §7.4 and the E1 spec's forward
   reference.

## 6. Consequences accepted

**Every render this engine produces gets roughly 1.295x brighter.** This is
the point of the change, not a side effect, and it was accepted explicitly
when the phase was scoped.

**The pipeline scripts will need re-tuning.**
`pipeline_references/image_glb_creation.gd` and `video_glb_creation.gd` carry
hand-tuned `light_energy` and `emission_energy_multiplier` values (the latter
in the 5.5-18.0 range) balanced against environment light that was 23% too
dim. Analytic lights are unaffected by this fix, so the *balance* between
analytic and environment lighting shifts even where absolute levels are
corrected. Night scenes, dominated by analytic and emissive sources, shift
least; daylight exteriors shift most.

**Those scripts are the user's own uncommitted work and are not touched by
this phase.** Re-tuning is a separate, manual pass on their side.

**Task 8's ~4.0-4.2% post-calibration residual on the slab and vase regions
is expected to move, and its interpretation to change.** Roadmap §7.1's
attribution paragraph already argues that dividing specular and refractive
regions by a diffuse-measured 0.772 over-corrects them. Once the underlying
gap is fixed there is no calibration division at all, and that residual must
be re-derived from raw numbers rather than carried forward.

## 7. Testing

**New:** `pt_sky_energy_gate.gd` — four probes (three peakedness levels plus
the direct `IBL_exposure_normalization` read), headless, following the
existing gates' interface.

**Regression:** the full doctest suite (currently 1513/1513, 0 failed, 3
skipped), all five existing GPU gates, and `pt_validation`.

**No doctest is added for the fix itself.** The defect lives in GPU-side sky
plumbing and in C++ scene-data setup that the headless dummy storage stubs
out. A CPU mirror would restate the formula without executing the path —
the exact failure mode that let E1's Task 5/6 defects through a green
1511-case suite. The gate is the instrument.

## 8. Acceptance

1. `pt_sky_energy_gate` exists, runs headless, and its three-level sweep
   yields an unambiguous reading of Mechanism A vs B vs neither.
2. If a defect is found: it is fixed, and the gate's absolute assertions pass
   at all three peakedness levels within 2%.
3. `pt_energy_gate` Gate 1 still passes.
4. doctest remains at 1513/1513, 0 failed.
5. All five gates and `pt_validation` re-baselined, with old and new recorded.
6. A Cycles comparison on the no-glass control scene reads within 5% rather
   than 23%.
7. If Task 1 shows all three levels clean, acceptance is instead: the
   measurement artefact is identified and documented, roadmap §7.4 is
   corrected, and **no engine change is made**.

## 9. Out of scope

- E2 proper: anisotropy, clearcoat, sheen, the N-way lobe rewrite.
- The NEE-vs-BSDF Fresnel mismatch on glass (E1 spec §6.4).
- The opaque/transmissive Fresnel dispatch split (E1 spec §4.2).
- Re-tuning the pipeline scripts' light energies.
- glTF export's unclamped colour factors (still parked from Phase D).

## 10. File inventory

**Create:**
- `pipeline_references/tests/pt_sky_energy_gate.gd`
- `pipeline_references/tests/pt_sky_energy_gate_scene.tscn`

**Modify (Task 1):**
- `servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl` — vis mode 34.

**Modify (Task 2, mechanism-dependent):**
- Mechanism A: `raytracing_closest_hit_common_inc.glsl` and/or
  `servers/rendering/renderer_rd/storage_rd/render_scene_data_rd.cpp`
- Mechanism B: `servers/rendering/renderer_rd/forward_clustered/render_raytracing.cpp`,
  `raytracing_env_sampling_inc.glsl`, `env_cdf_build.glsl`

**Modify (Task 3):**
- `PATH_TRACER_QUALITY_ROADMAP.md`
- `docs/superpowers/specs/2026-08-19-transmission-rough-glass-design.md`

**Never touched:** the six user-owned files in `pipeline_references/`
(`compositor_effect.gd`, `image_glb_creation.gd`, `render.gd`,
`structure.gd`, `video_glb_creation.gd`, `custom_shape.gd`).

## 11. Verified facts

Every row read from the named file at design time.

| Claim | Source |
|---|---|
| Sky radiance is scaled by a scalar `IBL_exposure_normalization` | `raytracing_closest_hit_common_inc.glsl:306` |
| That scalar folds in `bg_intensity` and `sky_get_baked_exposure` | `render_scene_data_rd.cpp:246-252` |
| `baked_exposure` is assigned `p_luminance_multiplier` | `sky.cpp:1354`, read via `:1618-1622` |
| The path tracer binds `sky_get_radiance_texture_rd` | `render_raytracing.cpp:3782` |
| Realtime skies are force-clamped to a 256px radiance map | `sky.h:248`, `sky.cpp:593-595` |
| The panorama is point/bilinear sampled, no mip, no LOD | `sky_material.cpp:502-509` |
| Gate 1 asserts `rho * L` analytically, 1% tolerance | `pt_energy_gate.gd:91-93`, `:222-229` |
| Gate 1's `l_sky` is measured from the render, making it a ratio | `pt_energy_gate.gd:196-206` |
| `env_pdf_from_uv` uses the correct equirect Jacobian `2*PI^2*sin(theta)` | `raytracing_env_sampling_inc.glsl:102-113` |
| Vis modes 0-33 are allocated; 34 is the next free | grep over `shaders/raytracing/*.glsl` |
| `BG_COLOR` renders black to the path tracer | roadmap F3; `pt_transmission_gate.gd` `_new_env` header |
