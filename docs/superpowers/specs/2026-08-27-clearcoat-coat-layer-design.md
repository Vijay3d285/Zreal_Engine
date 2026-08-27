# Clearcoat / Coat Layer (E2d) — Design

**Branch:** `vijay_PTEngine_v13_PhaseE2`
**Status:** design, awaiting review
**Predecessor:** `2026-08-23-n-way-lobe-rewrite-design.md` (E2c)
**Successor:** E2e (sheen), and a named successor for `coat_normal` (§8)

---

## 1. Goal

Add Cycles' coat as a **real layer**: a GGX lobe that also removes energy from
everything beneath it. Matching Blender means matching both halves — a coat
lobe that takes nothing from the base is not the same render.

This is the first phase to put a third lobe in E2c's registry, and the first
that genuinely exercises it (§6).

## 2. Scope

**In:** the coat lobe (GGX, isotropic, dielectric Fresnel), the layering
attenuation, `coat_ior` and `coat_tint` as new material parameters, the
`ggx_gen_schlick_ior_s` albedo LUT, and the registry's throughput/selection
split.

**Out:** `coat_normal` (§8), sheen (E2e), Gap #17's multi-scatter
over-compensation, and any change to E2b's anisotropy or E1's dielectric
closure.

## 3. Decisions

### 3.1 The registry gains a throughput scale, separate from selection weight

Cycles gives every closure both a `weight` (radiometric throughput) and a
`sample_weight` (selection probability). E2c's registry has one `weights[]`
array serving selection *and* pdf combination, which was correct at N=2
because the two lobes' weights summed to 1 and the distinction never surfaced.

**Coat is where it surfaces.** `closure_layering_weight` scales the base's
*energy*. It is not a selection probability, and folding it into one would
conflate the two.

So the registry gains a per-lobe throughput scale alongside its selection
weight. Selection and energy stay independently verifiable, and E2e needs the
same structure — the cost is paid once.

**Why the alternative was rejected.** Folding attenuation into the selection
weights and renormalising requires no registry change, but any error in it
surfaces as a subtly wrong MIS weight. MIS is unbiased for *any* weights
summing to 1 pointwise, so that error is **mean-preserving by construction** —
invisible to every rendered gate this project has. That is the exact defect
shape recorded in `pt-measurement-instruments-must-be-falsifiable`, and it
already cost this project a Phase E1 defect.

### 3.2 `alpha = coat_roughness²`, isotropic — diverging from this engine's raster

Cycles forces `alpha_x = alpha_y = sqr(coat_roughness)` (`closure.h:165`).

This engine's raster squashes the same slider into `mix(0.001, 0.1, r)`
(`scene_forward_lights_inc.glsl:212`), so Godot's clearcoat is always
near-mirror while Cycles maps it across the full range. **The same authored
material will show a visibly different coat in raster and in the path tracer.**

The goal is Blender, so Cycles' mapping wins. E2b set the precedent for
accepting and documenting exactly this kind of raster/PT divergence
(`anisotropy_rotation`, roadmap §7.8); this one is louder because it affects
every clearcoat material rather than an orientation-only control.

**This must be recorded in the roadmap closeout, not just here.** A future
reader comparing a raster screenshot against a PT render will otherwise file it
as a bug.

### 3.3 Specular stays at lobe index 0; coat appends at index 2

E2c made registry order a contract, not an implementation detail: a
diffuse-first registry inverts every pixel's lobe choice while leaving the
image statistically identical, so no gate can see it. Coat **appends**. It does
not displace specular, however physically outermost it is — the layering
happens through the throughput scale (§3.1), not through registry position.

### 3.4 Parameters: weight, roughness, ior, tint. `coat_normal` deferred

`clearcoat` and `clearcoat_roughness` already reach the GPU — Phase D landed
them in `RT_MaterialData` (`render_raytracing.h:134-135`), uploaded at
`render_raytracing.cpp:1790-1797`, with a debug vis at
`raytracing_closest_hit_common_inc.glsl:505`. Nothing consumes them.

- **`clearcoat_ior`** replaces the existing `_pad0` float. **Free** — no
  realignment, `sizeof` stays 176.
- **`clearcoat_tint`** is a `vec3`, so std430 aligns it to 16. It goes at
  offset 176 with a fresh `_pad0` at 188, taking the struct to **192 bytes**.
  Mechanical and precedented (Phase D did the 128→176 widening).

**`coat_normal` is deferred**, and this is the one piece of Blender parity E2d
will not have. It needs a texture slot, tangent-space decode, and glTF
plumbing; and in Cycles it also bends the *sheen* normal
(`closure.h:127-129`, `bsdf->N = safe_normalize(mix(N, coat_normal, saturatef(coat_weight)))`),
so it is genuinely entangled with E2e rather than separable from it.

### 3.5 Multi-scatter is left exactly as it is

Cycles runs `microfacet_ggx_preserve_energy` on the coat
(`bsdf_microfacet.h:1024`). This engine's equivalent is
`evalMultiScatterApproximation` (`brdf_inc.glsl:1165`), which roadmap Gap #17
records as over-correcting by roughly 3-8pp.

The coat uses the same term the existing specular lobe uses. **Gap #17
therefore applies to the coat too.** No fix is attempted here, and the Cycles
comparison in §5 must be read with that pedestal in mind — E2b's comparison
went from +6.52% to +0.67% once it was accounted for.

## 4. Design

### 4.1 The math

Attenuation reduces cleanly. `closure_layering_weight(a, w) = w · saturate(1 − max(a/w))`
(`bsdf_util.h:440`), and the coat's albedo is `a = coat_weight · w · estimate`,
so the `w` cancels:

```
base_throughput *= saturate(1.0 - coat_weight * estimate_albedo)
```

`estimate_albedo` follows `bsdf_microfacet_estimate_albedo`'s dielectric branch
(`bsdf_microfacet.h:556-579`) — reflection only, since the coat is neither a
glass closure nor `DIELECTRIC_TINT`:

```
rough    = sqrt(sqrt(ax * ay))                  // = sqrt(coat_roughness)
z        = sqrt(abs((ior - 1) / (ior + 1)))
s        = LUT3D(rough, cos_NI, z)              // table_ggx_gen_schlick_ior_s
estimate = mix(F0_from_ior(ior), 1.0, s)
```

with `F0_from_ior(ior) = sqr((ior - 1) / (ior + 1))` (`bsdf_util.h:290-293`).
Writing `q = (ior - 1) / (ior + 1)`: `F0 = q²` while `z = sqrt(|q|)`. Both are
built from `q`, in opposite directions — a plausible-looking implementation that
passes `F0` where `z` belongs is dimensionally fine and silently wrong, so the
doctest pins both against Cycles' own values.

Tint is Beer's law through the coat, and it scales the throughput of
everything below (`closure.h:178-202`):

```
cosNI         = dot(V, N)
cosNT         = sqrt(1 - sqr(1/ior) * (1 - sqr(cosNI)))
optical_depth = 1 / cosNT
throughput   *= mix(1.0, pow(tint, optical_depth), coat_weight)
```

**Cycles applies the tint whether or not the coat lobe was allocated.** The
lobe sits inside a `reflective_caustics` gate (`closure.h:155`); the tint block
at `:178` sits outside it. Our integrator has no caustics gate, so both always
run — but the two are separate steps and must not be fused into one branch.

Cycles skips the whole coat when `coat_weight <= CLOSURE_WEIGHT_CUTOFF`
(`1e-5f`, `svm/types.h:576`), and clamps `coat_roughness` with `saturatef`,
`coat_ior` with `fmaxf(·, 1.0f)`, and `coat_tint` with `max(·, 0)`
(`closure.h:148-150`). All four are reproduced.

**Which normal, and what happens behind it.** Every `N` above is the shading
normal, because `coat_normal` is deferred (§3.4); Cycles uses
`valid_coat_normal`, which defaults to `sd->N` when no coat normal is connected,
so the two agree for every material E2d supports. `cos_NI` is **not** clamped by
Cycles before the lookup (`bsdf_microfacet.h:504`) — the saturate inside
`lookup_table_read` absorbs a negative value, mapping it to the `cos_NI = 0`
row. Reproduce that rather than adding a clamp of our own, and let the coat lobe
itself contribute nothing when `cos_NI <= 0`.

### 4.2 The LUT, and the one way this silently goes wrong

`table_ggx_gen_schlick_ior_s[4096]` is a 16×16×16 table baked at 2²⁰ samples
per entry. It ships in Cycles **as source** — a plain float literal at
`intern/cycles/scene/shader.tables:737` — so it is copied verbatim rather than
approximated or re-derived. 16KB.

Cycles' interpolation is **endpoint-aligned**: `x = saturate(x) * (size - 1)`,
then trilinear, with the top index clamped (`lookup_table.h:14-29`, `:49-71`).

**Hardware 3D-texture filtering is half-texel-centered.** Uploading this as a
filtered 3D texture would compile, render plausibly, and be wrong by a fraction
of a texel at every lookup — a small, uniform, entirely silent energy error.
This is precisely the defect class this project keeps producing.

**Therefore: SSBO plus manual trilinear**, reproducing Cycles' arithmetic
exactly. A doctest pins specific interior *and* boundary reads against values
read directly out of `shader.tables`, including `t == 0` (the early-out at
`lookup_table.h:23`) and the top-edge clamp.

### 4.3 What does not change

`prepareBRDFData`, every existing BRDF function, E2b's anisotropy path, E1's
dielectric/transmissive closure, `lobeWeight`, and the environment path. The
near-delta specular guard (`RT_MIS_DELTA_ROUGHNESS`) and the `VplusL` degenerate
check in `combinedPdf` must survive verbatim, as in E2c.

## 5. Verification

Four layers, matching the E2 pattern:

1. **doctest** — the LUT indexing (§4.2), `F0_from_ior`/`z` consistency, the
   attenuation reduction, and the three-lobe registry arithmetic.
2. **White-furnace GPU gate** — coat plus attenuated base must never exceed 1.
   **This is the assertion an additive coat fails**, so it is the gate that
   distinguishes a layer from a lobe. Baselines are recorded as measured-intact
   constants with a tight band, per E2b's fix: an absolute comparison against
   1.0 would exit non-zero regardless, because Gap #17 already lifts these
   surfaces above it, and a gate that cannot *newly* fail is not an instrument.
3. **Self-normalizing pdf gate** — E2b's `E[1/pdf]` against the domain measure,
   extended to three lobes. A pdf wrong by factor `k` reads `1/k`.
4. **Cycles comparison** — a car-paint scene, which is E2's own stated
   acceptance target for this feature (roadmap §4, "car paint and velvet").
   Read against Gap #17's pedestal (§3.5).

**The sRGB trap applies, and it applies to `coat_tint` too.**
`render_raytracing.cpp:1542` runs `albedo_color` through `srgb_to_linear()` on
upload. This trap has already been hit twice in this phase family, one layer
apart, and once inverted an entire verdict (roadmap §7.7).

It is not left open for `coat_tint`: the established pattern in this file is
that **every colour factor is sRGB-decoded on upload** — `attenuation_color` at
`:1745` and `specular_tint` at `:1766` both do it. `clearcoat_tint` is the same
kind of quantity and follows the same path. Cycles' `coat_tint` socket is
already linear, so a Cycles-comparison material must author the Godot side with
`.linear_to_srgb()` to land on the same linear value — for `coat_tint` exactly
as for `albedo_color`.

## 6. Why E2d is the first real test of E2c

E2c's three-lobe extensibility proof was **inert by construction** — a
zero-weight, zero-pdf trailing entry cannot exercise anything, and roadmap §7.9
says so. Coat is the first genuine N=3, which makes two properties observable
for the first time:

- **Summation order now bites.** At N=2 it was unfalsifiable: IEEE addition is
  commutative bit-exactly, so reversing `combineLobePdf`'s loop was a no-op. At
  N=3 the question is *associativity*, and it is real.
- **The CDF's trailing fallback now carries a real lobe.** `selectLobe` falls
  through to `return LOBE_COUNT - 1`, which absorbs the weight-sum rounding
  residue. §7.9 flagged that a zero-weight lobe must not sit last; with coat at
  index 2, that residue lands on the coat, where it is correct.

Both are worth an explicit check during implementation rather than an
assumption that E2c settled them.

## 7. Acceptance

1. A white furnace with a coat conserves energy — coat plus attenuated base
   never exceeds 1, within the gate's measured band.
2. Reverting the attenuation (making the coat additive) makes that gate fail.
   **The guard is proven by breaking the thing it guards**, not asserted.
3. The LUT doctest matches `shader.tables` values at interior points, both
   boundaries, and the `t == 0` early-out.
4. Car paint lands within 5% of Cycles once Gap #17's pedestal is accounted
   for, with the raw figure reported alongside.
5. doctest green; the four existing GPU gates unchanged within tolerance.
6. `coat_ior` and `coat_tint` round-trip from BaseMaterial3D to the shader,
   verified by a vis mode rather than inferred.

## 8. Out of scope

- **`coat_normal`** — deferred, entangled with sheen (§3.4). This is the one
  piece of Blender coat parity E2d does not deliver, and it is a real gap for
  car paint's orange-peel detail.
- **Sheen** (E2e), which in Cycles is the layer *above* coat
  (`closure.h:115` "First layer: Sheen", `:146` "Second layer: Coat").
- **Gap #17**, the multi-scatter over-compensation (§3.5).
- **The raster/PT roughness divergence** (§3.2) is documented, not resolved.
- Anisotropy on the coat — Cycles forces the coat isotropic, so there is
  nothing to match.

## 9. Verified facts

Every row read from the named file while writing this spec.

| Claim | Source |
|---|---|
| Coat is a GGX `MicrofacetBsdf`, `alpha_x = alpha_y = sqr(coat_roughness)` | `intern/cycles/kernel/svm/closure.h:156-165` |
| Coat uses real dielectric Fresnel at `coat_ior` | `closure.h:163`, `:173` (`bsdf_microfacet_setup_fresnel_dielectric`) |
| Coat attenuates lower layers via `closure_layering_weight` | `closure.h:174` |
| `closure_layering_weight(a, w) = w · saturate(1 − reduce_max(a/w))` | `intern/cycles/kernel/closure/bsdf_util.h:440-444` |
| Coat albedo estimate is reflection-only, dielectric branch | `intern/cycles/kernel/closure/bsdf_microfacet.h:556-579` |
| `F0_from_ior(ior) = sqr((ior−1)/(ior+1))` | `bsdf_util.h:290-293` |
| The albedo LUT is 16³ and ships as source | `intern/cycles/scene/shader.tables:737` (`table_ggx_gen_schlick_ior_s[4096]`) |
| It is baked at 2²⁰ samples per entry | `intern/cycles/app/cycles_precompute.cpp:200-208` |
| LUT interpolation is endpoint-aligned, not half-texel-centered | `intern/cycles/kernel/util/lookup_table.h:14-29`, `:49-71` |
| Tint is Beer's law with `optical_depth = 1/cosNT` | `closure.h:178-202` |
| Tint is applied outside the `reflective_caustics` gate | `closure.h:155` vs `:178` |
| `CLOSURE_WEIGHT_CUTOFF` is `1e-5f` | `intern/cycles/kernel/svm/types.h:576` |
| Sheen is the layer above coat, not below | `closure.h:115`, `:146` |
| `coat_normal` also bends the sheen normal | `closure.h:127-129` |
| This engine's raster remaps clearcoat roughness to `[0.001, 0.1]` and is additive | `servers/rendering/renderer_rd/shaders/scene_forward_lights_inc.glsl:212-217` |
| `clearcoat`/`clearcoat_roughness` already reach the GPU, unused | `render_raytracing.h:134-135`, `render_raytracing.cpp:1790-1797` |
| `RT_MaterialData` is 176 bytes with one free float (`_pad0`) | `render_raytracing.h:105-139` |
| Its vec3 members are offset-asserted, because `sizeof` alone passes a broken layout | `render_raytracing.h:141-145` |
| `albedo_color` is sRGB-decoded on upload | `render_raytracing.cpp:1542` |
| So are the other colour factors — the pattern `coat_tint` must follow | `render_raytracing.cpp:1745` (`attenuation_color`), `:1766` (`specular_tint`) |
| A mean-preserving MIS-weight error is invisible to any rendered gate | memory `pt-measurement-instruments-must-be-falsifiable`; E1 closeout |
