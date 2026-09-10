# GGX multiple-scattering energy compensation for the base specular lobe

**Roadmap item:** Gap #17 — `evalMultiScatterApproximation` / `evalEmsApprox` over-shoot.
**Date:** 2026-09-10
**Status:** design approved, not yet planned.

---

## 1. The problem

Every rough surface in the path tracer is multiplied by a multiple-scattering
energy-compensation factor that over-corrects the true single-scattering GGX
energy deficit. Measured on the intact tree by `pipeline_references/tests/pt_anisotropy_gate.gd`:

| configuration | white-furnace ratio | over-shoot |
|---|---|---|
| roughness 0.4, anisotropy 0.0 | 1.059535 | +5.95% |
| roughness 0.4, anisotropy −0.9 | 1.0777727 | +7.78% |
| roughness 0.4, anisotropy −0.5 | 1.0809253 | +8.09% |
| roughness 0.4, anisotropy +0.5 | 1.0776337 | +7.76% |
| roughness 0.4, anisotropy +0.9 | 1.034110 | +3.41% |
| roughness 0.9, anisotropy 0.9 (probe 1b) | 1.345900 | **+34.59%** |

A white furnace must return exactly the sky radiance for any energy-conserving
BRDF, so every one of those figures is an absolute error, not a comparison. The
error scales steeply with roughness: +5.95% at roughness 0.4, +34.6% at 0.9.

The consequences reach past the furnace. This factor is the "pedestal" that
forces every Cycles comparison in `PATH_TRACER_QUALITY_ROADMAP.md` to be stated
twice — brushed metal +6.52% raw / 0.67% adjusted (§7.8), car paint +0.381% raw
/ −0.098% adjusted (§7.10), velvet −1.710% raw / −2.137% adjusted (§7.11). Until
it is removed, no parity number in that document means what it says.

It also **structurally disables the furnace gate's absolute check.** Probe 1
computes `|ratio − 1.0|` against a 2% tolerance and then deliberately does not
assert it (`pt_anisotropy_gate.gd`, fix round 2, Important #1), because every
combination in the sweep fails that comparison for this pre-existing reason. The
gate today asserts only a regression band around the measured-intact ratios. The
absolute check is present, correct, and switched off.

## 2. What Cycles does

`microfacet_ggx_preserve_energy` (`intern/cycles/kernel/closure/bsdf_microfacet.h:432-485`):

```c
E     = lookup_table_read_2D(rough, mu, ggx_E, 32, 32);
E_avg = lookup_table_read(rough, ggx_Eavg, 32);
missing_factor = (1 - E) / E;
bsdf->energy_scale = 1 + missing_factor;
if (Fss != 1) {
    Fms = Fss * E_avg / (1 - Fss * (1 - E_avg));
    darkening = (1 + Fms * missing_factor) / energy_scale;
    bsdf->weight *= darkening;
}
```

`rough = sqrtf(sqrtf(bsdf->alpha_x * bsdf->alpha_y))`, `mu = dot(wi, bsdf->N)`.

An engine with no separate closure weight only ever sees the product:

```
energy_scale * darkening  =  1 + Fms * (1 - E) / E
```

That is the identical derivation this codebase already carried out once, for the
coat, in E2d — see `coatEnergyScale` and its doc comment in `brdf_inc.glsl`
(around `:2075-2120`). This work applies the same result to the base lobe.

**This is the default path, not an opt-in.** Cycles gates it on
`preserve_energy = is_multiggx` at all three Principled microfacet lobes
(`intern/cycles/kernel/svm/closure.h:346`, `:414`, `:463`), which reads at first
glance as "Cycles does not compensate the base lobe." It does:
`node_shader_init_principled` sets `node->custom1 = SHD_GLOSSY_MULTI_GGX`
(`source/blender/nodes/shader/nodes/node_shader_bsdf_principled.cc:330`), so
every Principled node ever created — including every one Blender's glTF importer
builds — defaults to Multiscatter GGX, which maps to
`CLOSURE_BSDF_MICROFACET_MULTI_GGX_GLASS_ID` (`intern/cycles/blender/shader.cpp:732-733`)
and makes `is_multiggx` true.

## 3. What we do instead

`evalMultiScatterApproximation` (`brdf_inc.glsl:1222`) returns `1 + F0 * Ems`,
with `Ems = evalEmsApprox(alpha, NdV) = lerp(0.2·r², 0.32·r² + 1.94·r⁴, NdV)`
(`:1215`).

It is wrong in two independent ways:

1. **A fitted polynomial instead of the true missing energy.** `Ems` stands where
   Cycles uses `(1 − E)/E` read from a table built by numerical integration of
   the actual GGX lobe.
2. **Raw `F0` instead of multi-bounce `Fms`.** Cycles' `Fms` accounts for the
   Fresnel a ray picks up on *each* of its multiple bounces inside the
   microsurface; `F0` is the single-bounce normal-incidence value.

Either error alone would bias the result. Together they produce the table above.

## 4. Scope

**In scope — the three opaque base-specular call sites:**

| file | line | site |
|---|---|---|
| `servers/rendering/renderer_rd/shaders/raytracing/brdf_inc.glsl` | 1331 | `sampleSpecularMicrofacet` — the BSDF sampler |
| `servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl` | 1772 | environment / analytic-light NEE |
| `servers/rendering/renderer_rd/shaders/raytracing/raytracing_emissive_inc.glsl` | 496 | emissive-mesh NEE |

All three must switch **together**. A compensation applied by the sampler but
not by NEE makes the two MIS strategies estimate different integrands — the B2
defect class fixed on 2026-09-09 (see the C3 entry in the roadmap). This is a
hard constraint on the implementation, not a preference.

**Out of scope — the transmissive lobe.** `brdf_inc.glsl:1484`, the reflection
branch of E1's dielectric closure, keeps `evalMultiScatterApproximation`. Cycles
compensates glass from a different table set — `ggx_glass_E` (16×16×16),
`ggx_glass_Eavg` (16×16), plus `ggx_glass_inv_E` / `ggx_glass_inv_Eavg` for
`ior < 1` (`bsdf_microfacet.h:450-457`) — which this project has never
transcribed. Reusing `ggx_E`/`ggx_Eavg` there would swap a measured divergence
for an unmeasured one. The transmit branch of that closure applies no
compensation at all today and is likewise untouched.

*Deliverable:* a new roadmap item for the transmissive glass tables, and an
in-code comment at `:1484` saying why it was left.

## 5. Design

### 5.1 The function

Added to `brdf_inc.glsl` beside the existing one:

```glsl
// Cycles' real multiple-scattering compensation for the BASE specular lobe.
// Returns energy_scale * darkening, the product an engine with no separate
// closure weight sees. Transcribed from microfacet_ggx_preserve_energy
// (intern/cycles/kernel/closure/bsdf_microfacet.h:466-485).
float3 evalMultiScatterEnergy(float roughness, float NdotV, float3 F0) {
    float  E       = ggxE(roughness, NdotV);
    float  Eavg    = ggxEavg(roughness);
    float  missing = (1.0f - E) / E;
    float3 Fss     = mix(F0, float3(shadowedF90(F0)), 1.0f / 21.0f);
    float3 Fms     = Fss * Eavg / (float3(1.0f) - Fss * (1.0f - Eavg));
    return float3(1.0f) + Fms * missing;
}
```

`E` is read at `mu = NdotV`, a per-shading-point quantity, which is why this
cannot be precomputed per material on the CPU.

### 5.2 Why `rough` is just `roughness`

Cycles uses `rough = sqrt(sqrt(alpha_x · alpha_y))`. In this engine
`anisoAspect(a) = sqrt(1 − 0.9a)` (`brdf_inc.glsl:1051`), and `prepareBRDFData`
sets `ax = alpha / aspect`, `ay = alpha · aspect`. Therefore `ax · ay = alpha²`
**exactly, for every anisotropy**, and

```
sqrt(sqrt(ax · ay)) = sqrt(sqrt(alpha²)) = sqrt(alpha) = roughness
```

This is load-bearing, not a convenience. Two of the three call sites are NEE
sites that have `roughness` but not `ax`/`ay`. Had the product not cancelled,
plumbing anisotropy to only some sites would have reintroduced exactly the
sampler-vs-NEE integrand desync described in §4.

### 5.3 Why one `1/21` covers both metal and dielectric

Cycles uses two different `Fss` models, and this engine has one specular lobe
with a metallic-lerped `F0`. They coincide:

- **Metallic** (`svm/closure.h:339-347`) → `bsdf_microfacet_setup_fresnel_f82_tint`
  → `Fss = fresnel_f82_Fss(F0, B) = mix(F0, 1, 1/21) − B/126`
  (`bsdf_util.h:140-143`). At the default white specular tint,
  `fresnel_f82tint_B` returns `F_schlick · (7/(f5·f)) · (1 − tint) = 0`
  (`bsdf_util.h:146-158`), so `Fss = mix(F0, 1, 1/21)` **exactly**.
- **Dielectric** (`svm/closure.h:463-465`) → generalized Schlick. For our Schlick
  exponent of 5, `s = 2/((exponent+3)·exponent + 2) = 2/42 = 1/21`
  (`bsdf_microfacet.h:964-965`) — the same constant.

Cycles' dielectric branch actually takes an ior-derived `s`
(`saturate(inverse_lerp(F0_from_ior(ior), 1, fresnel_dielectric_Fss(ior)))`,
`bsdf_microfacet.h:958-962`) rather than the exponent form. At ior 1.45 that is
0.0492 against 1/21 = 0.0476 — about 2% on `Fss`, which after
`Fms ≈ Fss·E_avg` and multiplication by a `(1−E)/E` of a few percent lands near
0.1% of final radiance. Accepted, and recorded here so nobody later "discovers"
it as a bug.

`shadowedF90(F0)` is used for `F90` where Cycles hardcodes `f90 = 1`. These agree
in practice: `shadowedF90` returns `min(1, luminance(F0)/0.04)`, and the file's
own comment at `:728-729` states that an F0 derived from metalness is never below
`MIN_DIELECTRICS_F0`, so the term is 1. Using `shadowedF90` rather than a literal
1 keeps the compensation consistent with the Fresnel the lobe actually evaluates
if that invariant ever changes.

### 5.4 Readers

No plumbing is required. `GGX_E_TABLE` and `GGX_EAVG_TABLE` are already uploaded
to the GPU unconditionally by `RenderRaytracing::_get_coat_albedo_buffer()`
(`render_raytracing.cpp:168-170`), and the GLSL readers are guarded only by
`#ifndef BRDF_HLSLI`, **not** by `RT_COAT_ENABLED` — verified by walking the
preprocessor nesting at `brdf_inc.glsl:2018`, `:2040`, `:2133`, `:2142`.

Changes are naming only:

- Rename `coatLutRead1D` / `coatLutRead2D` → `ggxLutRead1D` / `ggxLutRead2D`
  — 10 occurrences in `brdf_inc.glsl`, plus two prose references in comments at
  `raytracing_closest_hit_common_inc.glsl:1028` and `:1229` that name the function
  and must be updated with it. They were never coat-specific.
- Leave `coatLutRead3D` named as it is — it reads the coat albedo table and is
  genuinely coat-specific.
- Add `ggxE(alpha, mu)` and `ggxEavg(alpha)` as the shared semantic readers.
  The coat's own helpers are left textually untouched beyond the rename:
  `coatGgxE` keeps reading through the renamed reader directly, and there is no
  `coatGgxEavg` to wrap — the coat reads `E_avg` inline inside `coatFms`.
  (An earlier draft of this section asserted a `coatGgxEavg` that does not
  exist. Leaving the coat path unchanged is also what makes "the coat and sheen
  gates must not move" a real check on the rename.)
- Update the SSBO resource name at `render_raytracing.cpp:174` accordingly.

### 5.5 The A/B switch

`RT_MS_COMPENSATION` in `brdf_inc.glsl`, default `1`:

| value | behaviour |
|---|---|
| `1` | Cycles table (production) |
| `0` | no compensation — the true single-scattering GGX lobe |
| `2` | legacy `1 + F0·Ems` (`evalEmsApprox` and `evalMultiScatterApproximation` kept, not deleted) |

Three states rather than two, because attributing a future residual needs "off"
as well as "old", and because three states give the furnace gate three separated
values it must reproduce (§6). Kept permanently as measurement scaffolding on the
standing precedent of `COMBINE_BRDFS_WITH_FRESNEL`, `RT_LIGHT_SELECT_UNIFORM`
and `RT_ENV_NEE_ENABLED`.

The switch governs all three call sites from one definition. There is no
per-site override, deliberately: the sampler and the two NEE sites disagreeing is
the failure mode of §4.

## 6. Testing and acceptance

### 6.1 The furnace gate is analytically guaranteed, not merely expected

`pt_anisotropy_gate.gd` probe 1 renders a sphere with `albedo_color = 1.0`,
`metallic = 1` under a uniform sky. For that material `F0 = (1,1,1)` and
`shadowedF90(F0) = 1`, so:

```
Fss = mix(1, 1, 1/21) = 1
Fms = 1 · Eavg / (1 − 1·(1 − Eavg)) = Eavg / Eavg = 1
factor = 1 + 1 · (1 − E)/E = 1/E
```

A single-scattering GGX lobe whose directional albedo is `E`, multiplied by
`1/E`, returns exactly 1. **The white furnace must read 1.0 by derivation**, and
any residual is a transcription error, a table-indexing error, or an axis
convention error — each of which this gate will localise.

### 6.2 Acceptance

1. **Promote probe 1's absolute check from diagnostic to asserted.** The
   documented reason it was demoted (fix round 2, Important #1) is precisely the
   defect being removed. Accept: `|ratio − 1.0| ≤ TOLERANCE` (0.02) for all 15
   sweep entries — 5 anisotropies × 3 rotations. This is the gate getting
   *stronger*, not merely re-baselined, and it is the primary deliverable of the
   testing work.
2. **Re-capture `BASELINE_INTACT_RATIO`** (all five entries) and
   `BASELINE_INTACT_RATIO_NEE_DOM`. Every one moves; leaving them stale would
   fail the regression band on a correct build.
3. **Probe 1b** (roughness 0.9, anisotropy 0.9), where the over-shoot is +34.6%,
   must also land within 2% of 1.0. This is the strongest single number in the
   change.

### 6.3 Falsification

The gate must produce three separated values, or it is not measuring what it
claims:

| `RT_MS_COMPENSATION` | expected isotropic furnace ratio |
|---|---|
| `1` (new) | ≈ 1.000 |
| `0` (none) | ≈ 0.966 — the known uncompensated single-scatter deficit |
| `2` (legacy) | **1.059535 ± 0.0002** |

The `2` row is an exact self-check against a number already committed in
`BASELINE_INTACT_RATIO[2]`, with the band taken from that constant's own
documented run-to-run spread of ~0.02pp. It proves the legacy path was preserved
rather than merely believed to be.

### 6.4 C++ mirror

Extend the doctest suite with a CPU mirror of `evalMultiScatterEnergy`, asserting
against hand-computed Cycles values at a small set of `(roughness, mu, F0)`
points, following the existing pattern in
`tests/servers/rendering/test_pt_coat_albedo.cpp`.

**This guards the arithmetic only.** The doctest binary does not execute GLSL —
every CPU mirror in this project would still pass if the shader were reverted and
the mirror left untouched (roadmap §6). Stated here so the suite's green is not
mistaken for shader coverage.

### 6.5 Regression controls

**Expected to move — re-baseline:**

- `pt_coat_gate.gd` and `pt_sheen_gate.gd` — the base specular lobe sits under
  both layers, so their references shift even though neither layer changed.
- `pt_energy_gate.gd`'s `rough` (roughness 0.6, metallic 1) and `bumpy` spheres.
- `pt_energy_gate.gd`'s `smooth` sphere should move only slightly: at roughness
  0.02, `E ≈ 1` and the factor is ≈ 1.

**Must NOT move — assert unchanged:**

- `pt_energy_gate.gd`'s `diffuse` Lambertian plane. It sets
  `metallic_specular = 0`, so it has no specular lobe to compensate.
- `pt_energy_gate.gd` Gate 1's absolute `rho · L_env = 0.5`.
- The full doctest suite: 1550 passed / 0 failed / 3 skipped.

### 6.6 Build

GLSL changes require a full `python -m SCons platform=windows target=editor
tests=yes -j8` so the `.glsl.gen.h` headers regenerate. A clean SCons exit proves
nothing about GLSL validity — `glsl_builders.py` runs no validation — so the gate
runs are the only evidence the shader compiled and behaves.

## 7. What this does not fix

Stated explicitly so the closeout cannot overclaim:

- **The transmissive lobe** keeps the old approximation (§4).
- **The Cycles scene comparisons are not re-taken.** §7.8/§7.10/§7.11's
  pedestal-adjusted figures become correct going forward, but the raw
  comparisons against Blender have not been re-measured in this work. The
  `.blend` scenes and scripts behind them were never checked in — only
  `.superpowers/sdd/2026-08-21-environment-energy-fidelity/cycles-hypothesis-report.md`.
  The roadmap must say this rather than quietly presenting the adjusted numbers
  as raw.
- **§7.11.2's unexplained −2.06% dielectric-base residual** against Cycles may
  move, but no claim is made about it without a re-measurement.
- **Blender parity on the diffuse-under-specular layer** is a separate open item
  filed on 2026-09-09 (base specular directional albedo through
  `layerTransmittanceAbove`).

## 8. Documentation changes

- Gap #17 row in §2 → fixed, with the before/after furnace table.
- §7.8's Gap-#17 characterisation → annotated as resolved, keeping the original
  measurements as the before-state.
- The "raw vs pedestal-adjusted" pairs in §7.8/§7.10/§7.11 → a note that the
  pedestal is removed and the raw comparison is not re-taken (§7).
- New roadmap item: transmissive-lobe glass tables (`ggx_glass_E`,
  `ggx_glass_Eavg`, inverse-IOR variants).
- §6's stale ordering line `A1 → A2/A3/A4 → D → E → F` corrected, since §4 marks
  Phase A implemented.
