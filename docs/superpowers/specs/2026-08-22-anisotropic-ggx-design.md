# Anisotropic GGX (E2b) — Design

**Branch:** `vijay_PTEngine_v12_PhaseE`
**Status:** design, awaiting review
**Predecessor:** `2026-08-21-environment-energy-fidelity-design.md` (E2a)
**Successors:** E2c (N-way lobe rewrite + clearcoat), E2d (sheen)

---

## 1. Goal

Make the path tracer's specular lobe **elliptical**, driven by the
`anisotropy` and `anisotropy_rotation` values Phase D already delivers to the
GPU. Brushed metal, hairline-finished steel and satin fabric currently render
as if isotropic.

## 2. Scope

**In:** anisotropic GGX `D`, anisotropic Smith `Λ`/`G2`, a matching
anisotropic VNDF pdf, the tangent-frame rotation, and the plumbing that feeds
`ax`/`ay` into the existing specular lobe.

**Out, deferred to E2c/E2d:** clearcoat, sheen, and the two-way → N-way lobe
selection rewrite. Anisotropy adds **no new lobe** — it reshapes the one that
already exists — which is the entire reason it can ship before the
architectural change.

**Out, unchanged:** the diffuse lobe, the E1 dielectric/transmissive closure,
NEE, the environment path.

## 3. Decisions

### 3.1 The anisotropy → alpha mapping

```
alpha  = roughness * roughness
aspect = sqrt(1.0 - anisotropy * 0.9)
ax     = alpha / aspect
ay     = alpha * aspect
```

This formula is **already present in this engine and in Cycles, identically**.

Godot's Forward+ raster, `servers/rendering/renderer_rd/shaders/scene_forward_lights_inc.glsl:272-274`:

```glsl
half aspect = sqrt(half(1.0) - anisotropy * half(0.9));
half ax = alpha_ggx / aspect;
half ay = alpha_ggx * aspect;
```

Cycles, `intern/cycles/kernel/svm/closure.h:311-313`:

```c
const float aspect = sqrtf(1.0f - anisotropic * 0.9f);
alpha_x /= aspect;
alpha_y *= aspect;
```

**Adopting it therefore buys raster/RT parity and Cycles parity from a single
formula.** E1 had to purchase a deliberate Fresnel divergence between opaque
and transmissive materials; here parity is free, and that is worth stating
because it is unusual for this project.

### 3.2 `anisotropy` stays SIGNED

Godot's `anisotropy` is signed `[-1, 1]`; Cycles `saturatef`s to `[0, 1]`
(`closure.h:296`) and carries the other orientation in `anisotropic_rotation`.

**These are not equivalent.** At `a = -0.5`, Godot's formula gives
`aspect = sqrt(1.45) = 1.2042`, an axis ratio of **1.450**. Cycles' `|a| = 0.5`
plus a 90° rotation gives `aspect = sqrt(0.55) = 0.7416`, ratio **1.818**.
Different eccentricity, not merely a different orientation.

The signed value is fed straight into the formula, matching Godot's raster.
Rationale:

- For `a >= 0` the two are **bit-identical**, and `KHR_materials_anisotropy`
  has no sign (strength `[0,1]` + rotation), so **every glTF/Blender-imported
  material lands in that range**. Blender fidelity is unaffected.
- Negative values are reachable only from hand-authored Godot materials, where
  matching Godot's own raster is the correct behaviour.
- Nothing is lost: Cycles cannot express that state at all.

### 3.3 `anisotropy_rotation` is RADIANS — do NOT multiply by 2π

Cycles stores rotation in **turns** and multiplies:
`T = rotate_around_axis(T, N, anisotropic_rotation * M_2PI_F)`
(`closure.h:316`).

Godot stores **radians**. `scene/resources/material.cpp:3811`:

```cpp
ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "anisotropy_rotation",
        PROPERTY_HINT_RANGE, "0,6.2831853,0.001,radians_as_degrees"), ...);
```

The range ends at `6.2831853` — that is 2π, displayed as degrees in the
inspector. `render_raytracing.cpp:1787` uploads the value unmodified, and
`raytracing_data_inc.glsl:155` comments the field "Radians", correctly.

**Multiplying by 2π here would be a 6.28× error.** It is called out as a
decision rather than left implicit because transcribing a Cycles line without
checking the receiving engine's units is precisely the failure that produced
E1's F1, F2 and F3 (see that spec's §3.2 erratum) and E2a's own sRGB defect.

### 3.4 The BRDF becomes anisotropic; the sampler already is

`sampleGGXVNDF(float3 Ve, float2 alpha2D, float2 u)`
(`brdf_inc.glsl:958`) already accepts elliptical alpha correctly. Every caller
simply passes `float2(data.alpha, data.alpha)` (`:1664`).

Evaluation and pdf are structurally scalar and must be extended:

- `GGX_D(float alphaSquared, float NdotH)` (`:944-947`)
- `Smith_G2_Height_Correlated(float alpha, float NdotL, float NdotV)` (`:868-872`)
- `sampleGGXVNDFReflectionPdf(float alpha, float alphaSquared, ...)` (`:985`)

New anisotropic counterparts are added **alongside** these, not in place of
them; the isotropic functions stay, because the diffuse and transmissive paths
still call them.

## 4. Design

### 4.1 The shading frame

Anisotropy is defined in the surface tangent frame. The hit already supplies
world-space `tangent` and `bitangent` with `bitangent_sign`
(`raytracing_closest_hit_common_inc.glsl:19-20`, `:54-70`), so **no new
geometry plumbing is required**.

The tangent is rotated about the shading normal by `anisotropy_rotation`
radians. `ax` runs along the rotated tangent, `ay` along the rotated
bitangent.

### 4.2 Anisotropic D

```
D(H) = 1 / (PI * ax * ay * sqr( sqr(Hx/ax) + sqr(Hy/ay) + sqr(Hz) ))
```

with `H` in the rotated tangent frame (`Hz` along the normal).

### 4.3 Anisotropic Smith Λ and G2

```
Lambda(V) = (-1 + sqrt(1 + (sqr(ax*Vx) + sqr(ay*Vy)) / sqr(Vz))) * 0.5
G2        = 1 / (1 + Lambda(V) + Lambda(L))
```

Height-correlated, matching the form the isotropic path already uses at
`:868-872`.

### 4.4 The pdf must match the sampler exactly

```
pdf(H) = D(H) * G1(V) * max(0, dot(V,H)) / dot(V,N)
pdf(L) = pdf(H) / (4 * dot(V,H))
```

**This is the highest-risk item in the phase.** A pdf that disagrees with the
sampler is the B2 defect class: two strategies estimating different
integrands, which MIS cannot repair, and which is **mean-preserving** — no
rendered image at any sample count reliably reveals it. That is why §7 gates
it with a dedicated detector rather than a render.

Every consumer of the specular pdf must be updated together —
`combinedPdf`/`combinedPdfLobeProbability` and the MIS weight at the shading
point — or the pair silently desyncs. The implementer must enumerate the
call sites by grep rather than trusting this list.

### 4.5 `BrdfData` and call sites

`BrdfData` gains `ax` and `ay` alongside the existing `alpha`/`alphaSquared`,
which remain for the unchanged isotropic consumers. `prepareBRDFData` computes
them via §3.1. Call sites pass `float2(data.ax, data.ay)`.

### 4.6 The no-pixel-change guarantee is ARITHMETIC

At `anisotropy = 0`, `aspect = sqrt(1.0) = 1.0` exactly, so `ax = ay = alpha`,
and §4.2 reduces algebraically to the shipped `GGX_D`:

```
D = 1 / (PI * a^2 * ( (Hx^2 + Hy^2)/a^2 + Hz^2 )^2 )
  = a^2 / (PI * ( (a^2 - 1) * NdotH^2 + 1 )^2 )
  == GGX_D(alphaSquared, NdotH)                      (brdf_inc.glsl:944-947)
```

using `Hz = NdotH` and `Hx^2 + Hy^2 = 1 - NdotH^2`. Likewise §4.3 reduces to
`Smith_G2_Height_Correlated`.

**Amended during execution (2026-08-22).** The identity holds algebraically but
NOT in float32 at `NdotH == 1`. The shipped `GGX_D` forms
`b = (alphaSquared - 1) * NdotH^2 + 1`, which at `NdotH == 1` subtracts 1 from a
number near 1 and adds it back — catastrophic cancellation. At roughness 0.05
the shipped value carries **0.27% error**; the anisotropic form, which never
forms that difference, is the accurate one.

That is not an obscure corner: `NdotH` near 1 at low roughness is where a sharp
specular highlight lives. So the anisotropic path is a real, if small, accuracy
improvement — and taking it unconditionally would change every polished material
in every existing scene.

**Ruling: bit-identity governs.** `BrdfData.anisoActive` gates the anisotropic
path; at `anisotropy == 0` every consumer takes the existing isotropic code
unchanged. The accuracy improvement applies only where anisotropy is in use. A
doctest case records the cancellation and pins the shipped reference's error, so
that if `GGX_D` is ever made numerically stable the test fails and tells the
reader this branch can be revisited.

**The identity is asserted numerically in doctest at several roughness and
NdotH values, not assumed** — at `NdotH` values away from the cancellation
corner. E1's "no pixel changes" claim was only credible
because it was arithmetic; the same standard applies here.

## 5. Error handling and degenerate inputs

**No usable tangent.** Cycles gates anisotropy on `stack_valid(data.tangent_offset)`
(`closure.h:309`) — no tangent, no anisotropy. Meshes without tangent data, or
with degenerate UVs, yield a garbage or zero-length frame. When the tangent is
not finite or is near-zero after normalization, fall back to isotropic
(`ax = ay = alpha`). Silent isotropic fallback is correct here; a garbage
frame produces streaked highlights in an arbitrary direction, which is worse
than no anisotropy.

**`anisotropy` outside [-1, 1].** `aspect` is `sqrt(1 - a*0.9)`; at `a > 1.111`
the radicand goes negative and `aspect` is NaN. Clamp `anisotropy` to
`[-1, 1]` at the RT upload site, matching where E1 clamped
`attenuation_color`.

**`roughness = 0`.** `alpha = 0` makes both `ax` and `ay` zero and `D`
singular. The existing isotropic path already guards this
(`max(0.00001f, ...)` at `:1298`); the anisotropic path must guard `ax` and
`ay` the same way, independently.

## 6. Consequences accepted

**RT and raster now agree on anisotropic direct light**, because they compute
`ax`/`ay` identically (§3.1). They will still differ on **image-based**
lighting: raster uses Filament's bent-normal approximation
(`scene_forward_clustered.glsl:1666-1670`, `:2028-2032`), while the path
tracer integrates the real lobe. That is the path tracer being more correct,
not a regression, and it is not a divergence from Cycles.

**Negative anisotropy has no Cycles equivalent** (§3.2). A material using it
cannot be validated against Blender; only against Godot's raster.

**Anisotropic highlights are noisier than isotropic ones** at equal sample
count. A stretched lobe spreads the same energy over a longer, thinner
region, so variance rises along the stretch axis. This is a convergence-rate
property, not a bias.

## 7. Testing

Three instruments, because E1 established that a green suite plus a plausible
image is not a bar. Each targets a defect class the others cannot see.

### 7.1 doctest — the isotropic reduction identity

CPU mirrors of §4.2 and §4.3 asserted equal to the shipped isotropic
`GGX_D` and `Smith_G2_Height_Correlated` at `anisotropy = 0`, across several
roughness and `NdotH` values. Also asserts the §3.1 mapping, including that
`aspect == 1.0` exactly at `anisotropy = 0`, and the signed behaviour of §3.2
with the 1.450-vs-1.818 counterfactual **pinned numerically** so the test can
distinguish the two conventions rather than merely agreeing with one.

Per the standing rule, the CPU mirror must stay textually identical to the
GLSL modulo type names.

### 7.2 GPU gate — white furnace across the anisotropy range

Uniform environment, `albedo = 1`, metallic, no absorption: an
energy-conserving BRDF must return **1.0 regardless of `ax`/`ay`**. Swept
across `anisotropy` and `anisotropy_rotation`.

This directly catches a wrong `D` normalization or a wrong `Λ`, which is the
most likely implementation error and which a beauty render would show only as
"a bit bright/dark".

### 7.3 GPU gate — pdf/sampler parity (vis mode)

A vis-mode probe reading the anisotropic pdf against the sampler's own
density for the same direction, in the shipped functions — not re-inlined
copies. §4.4's desync is mean-preserving and **cannot** be caught by 7.2 or
7.4.

This mirrors E1's vis mode 32, which was built for exactly this reason after
a `combinedPdf` desync shipped through a green suite and four gates.

### 7.4 Cycles reference image

A brushed-metal sphere at matched settings, `anisotropy > 0` so the
comparison is in the range where the two engines agree by construction (§3.2).

**The E2a lesson applies directly and is a hard requirement:** the Blender
material must be built with `Base Color` in **linear**, pre-decoded from the
Godot sRGB value — `srgb_to_linear()` is applied on RT upload at
`render_raytracing.cpp:1540-1542`. Copying the authored number field-for-field
is what produced E1 Task 8's phantom 23% dimming (roadmap §7.7). The harness
must also carry a **positive control** proving it can reproduce a known
discrepancy.

## 8. Acceptance

1. `anisotropy = 0` renders **bit-identical** to the current build on an
   existing gate scene, and §4.6's identity passes in doctest.
2. The furnace gate returns 1.0 within 2% at every swept `anisotropy` and
   `anisotropy_rotation`.
3. The pdf/sampler parity probe agrees within 1e-4.
4. doctest remains green with the new cases added.
5. All existing GPU gates and `pt_validation` still pass.
6. A brushed-metal sphere matches Cycles within 5% mean, with the highlight
   stretched along the expected axis and rotating correctly with
   `anisotropy_rotation`.

## 9. Out of scope

- Clearcoat, sheen, the N-way lobe rewrite (E2c/E2d).
- Anisotropy on the **transmissive** lobe. Cycles applies `alpha_x`/`alpha_y`
  to its glass closure too (`closure.h:450-451`); this phase covers the
  reflective lobe only. Recorded as an E2c/E2d item.
- The NEE-vs-BSDF Fresnel mismatch on glass (E1 §6.4), still inherited.
- E2a's open item: the +8.5% aliasing overshoot at `RADIANCE_SIZE_256`
  (roadmap §7.6).

## 10. File inventory

**Modify:**
- `servers/rendering/renderer_rd/shaders/raytracing/brdf_inc.glsl` — anisotropic `D`, `Λ`/`G2`, pdf; `BrdfData.ax`/`.ay`; `prepareBRDFData`; call sites.
- `servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl` — rotated tangent frame; new vis mode for §7.3.
- `servers/rendering/renderer_rd/forward_clustered/render_raytracing.cpp` — clamp `anisotropy` to `[-1, 1]`.
- `scene/resources/environment.h` / `.cpp` — the new debug-mode enumerator and its inspector hint, kept in lockstep (E2a found mode 34 had been added to GLSL only, leaving `RT_DEBUG_MAX` aliasing a live mode).

**Create:**
- `tests/servers/rendering/test_pt_anisotropy.cpp`
- `pipeline_references/tests/pt_anisotropy_gate.gd` + `_scene.tscn`

**Never touched:** the six user-owned files in `pipeline_references/`
(`compositor_effect.gd`, `image_glb_creation.gd`, `render.gd`,
`structure.gd`, `video_glb_creation.gd`, `custom_shape.gd`).

## 11. Verified facts

Every row read from the named file while writing this spec.

| Claim | Source |
|---|---|
| Godot raster uses `aspect = sqrt(1 - anisotropy*0.9)`, `ax = alpha/aspect`, `ay = alpha*aspect` | `scene_forward_lights_inc.glsl:272-274` |
| Cycles uses the identical formula | `intern/cycles/kernel/svm/closure.h:311-313` |
| Cycles `saturatef`s anisotropic to [0,1] | `closure.h:296` |
| Cycles gates anisotropy on a valid tangent | `closure.h:309` |
| Cycles rotation is in TURNS, `* M_2PI_F` | `closure.h:314-317` |
| Godot rotation is in RADIANS, hint range 0..6.2831853 | `scene/resources/material.cpp:3811` |
| RT upload passes rotation through unmodified | `render_raytracing.cpp:1785-1787` |
| Godot's anisotropy shader param is `anisotropy_ratio`, not `anisotropy` | `material.cpp:574`; already handled at `render_raytracing.cpp:1800-1805` |
| `sampleGGXVNDF` already takes `float2 alpha2D` | `brdf_inc.glsl:958` |
| Callers currently pass `(alpha, alpha)` | `brdf_inc.glsl:1664` |
| Isotropic `GGX_D = alphaSquared / (PI * b * b)` | `brdf_inc.glsl:944-947` |
| Isotropic `Smith_G2_Height_Correlated` form | `brdf_inc.glsl:868-872` |
| World tangent/bitangent with sign available at the hit | `raytracing_closest_hit_common_inc.glsl:19-20`, `:54-70` |
| Phase D's six material fields are on the GPU with zero BRDF consumers | `raytracing_data_inc.glsl:153-158`; grep of `brdf_inc.glsl` returns 0 |
| Raster IBL anisotropy uses Filament's bent normal | `scene_forward_clustered.glsl:1666-1670`, `:2028-2032` |
| Albedo is sRGB-decoded on RT upload | `render_raytracing.cpp:1540-1542` |
