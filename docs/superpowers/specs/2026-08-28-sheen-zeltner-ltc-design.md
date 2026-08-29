# Sheen — Zeltner LTC (E2e) — Design

**Branch:** `vijay_PTEngine_v13_PhaseE2`
**Status:** design, awaiting review
**Predecessor:** `2026-08-27-clearcoat-coat-layer-design.md` (E2d)
**Successor:** a named successor for `coat_normal` (§8), which E2d deferred *into* this phase's territory

---

## 1. Goal

Add Cycles' sheen as the **outermost layer** of the Principled BSDF, and in
doing so generalise E2d's single-layer attenuation into an N-layer stack.

Sheen is the last layer Cycles' Principled BSDF has. After this the layering
structure is closed, and E2's original acceptance target — "brushed metal, car
paint, and velvet respond comparably to Cycles" — is fully addressed.

## 2. Scope

**In:** the Zeltner LTC sheen lobe, its 3072-float table, the N-layer
transmittance stack, and a velvet Cycles comparison.

**Out:** `coat_normal` (§8), Gap #17's base-specular over-compensation, and any
change to E1's dielectric closure, E2b's anisotropy, or E2d's coat *math*.
E2d's coat **plumbing** is refactored into the stack — that is §3.1, and it is
the phase's main risk.

## 3. Decisions

### 3.1 The transmittance becomes an N-layer stack

Cycles applies layering **sequentially**: sheen withdraws from `weight`
(`svm/closure.h:141`), then coat withdraws from what remains (`:174`). Each
layer attenuates everything below it, in allocation order.

E2d built this for exactly one layer — `coatLayeringTransmittance` applied at
one site to the base lobes. Sheen sits *above* coat, so its withdrawal must
reach the coat as well.

**Generalise:** each layer's transmittance multiplies every lobe at a higher
registry index, walked in registry order. Sheen's scales coat, specular and
diffuse; coat's scales specular and diffuse. E2d's single site becomes one
entry in that walk rather than a special case.

**Why not hardcode two levels.** It would work and review faster, but the
ordering would live in two places, and a third layer would need the same
surgery — the shape E2c existed to retire. Sheen is the last layer, so this is
the only opportunity to close the structure with a real second layer to test it
against.

**The risk this creates, stated plainly.** E2d's coat is proven and gated:
36-configuration furnace flatness to 1.3e-4, and +0.381% raw / −0.098% adjusted
against Blender. This refactor touches all of it. **Phase invariant: at
`sheen_color == 0`, every E2d coat measurement must be unchanged.** Not
"within tolerance" — unchanged, because sheen contributes nothing there and the
stack must reduce to E2d's arithmetic exactly.

### 3.2 The withdrawal is per-channel, and that is new

`closure_layering_weight(a, w) = w · saturate(1 − reduce_max(a/w))`
(`bsdf_util.h:440`). For sheen, `bsdf_albedo` is `sc->weight` unmodified —
sheen is not `CLOSURE_IS_BSDF_MICROFACET`, so `bsdf_albedo`'s microfacet branch
(`bsdf.h:707`) does not apply. So:

```
a/w = sheen_color · ltc_albedo          (a float3)
withdrawal = saturate(1 − max_channel(sheen_color · ltc_albedo))
```

**`reduce_max` is the maximum channel, not the luminance and not per-channel
attenuation.** E2d's coat made this invisible: its albedo was
`make_spectrum(F)`, a scalar broadcast, so `reduce_max` was trivially `F` and a
scalar implementation was correct by accident. Sheen has a genuine per-channel
tint, so the max-channel reduction is load-bearing for the first time.

### 3.3 `sheen_color` is the whole input; no new material parameter

Cycles takes `sheen_weight` (scalar) and `sheen_tint` (float3) and immediately
forms `sheen_weight · sheen_tint` (`closure.h:124`). glTF's
`KHR_materials_sheen` and this engine's `sheen_color` carry that product
directly. Mathematically identical, so **E2e adds no material field.**

Phase D already landed the plumbing end to end and nothing consumes it:
`BaseMaterial3D::set_sheen_color` / `set_sheen_roughness`
(`scene/resources/material.cpp:2383`, `:2392`, both using the `_material_set_param`
queueing pattern), inspector properties (`:3913-3914`), upload
(`render_raytracing.cpp:1815`), `RT_MaterialData` (`render_raytracing.h:131-132`),
and the GLSL mirror (`raytracing_data_inc.glsl:153-154`). `brdf_inc.glsl`
mentions sheen **zero** times today.

**One consequence to reproduce deliberately.** Cycles gates the whole sheen
block on `sheen_weight > CLOSURE_WEIGHT_CUTOFF` (`1e-5f`, `svm/types.h:576`).
With the product as our only input, the equivalent gate is on `sheen_color`'s
magnitude. Use the **max channel**, matching §3.2's reduction — not the
luminance, which would let a saturated blue sheen fall below the cutoff.

### 3.4 Sheen appends at registry index 3

E2c made registry order a contract: a reordered registry inverts lobe choices
while leaving the image statistically identical, so no gate can see it.
Specular stays at 0, diffuse 1, coat 2, sheen **3**. Sheen is physically
outermost, but layering happens through the transmittance stack (§3.1), not
through registry position — the same argument E2d used for coat.

### 3.5 `coat_normal` stays deferred, and E2e is where the entanglement lands

Cycles bends the sheen normal toward the coat normal
(`closure.h:127-129`, `bsdf->N = safe_normalize(mix(N, coat_normal, saturatef(coat_weight)))`).
E2d deferred `coat_normal` partly *because* of this coupling.

E2e does not add it either. With no coat normal, Cycles' expression reduces to
`bsdf->N = N`, so sheen uses the shading normal and the two agree for every
material this engine supports. **Recorded so the deferral is a decision, not an
omission** — and so whoever adds `coat_normal` knows it must touch sheen too.

## 4. Design

### 4.1 The lobe

Read from `intern/cycles/kernel/closure/bsdf_sheen.h:27-110`.

**Setup.** `roughness = clamp(roughness, 1e-3, 1.0)`; build the frame (§4.2);
`cosNI = dot(N, wi)`; three 32×32 reads from one 3072-float table:

```
transformA = LUT2D(cosNI, roughness, offset + 0)
transformB = LUT2D(cosNI, roughness, offset + 1024)
ltc_albedo = LUT2D(cosNI, roughness, offset + 2048)
```

**The axis order is `(cosNI, roughness)` — transposed relative to the coat's
`(rough, mu)`** (`bsdf_microfacet.h:565`). Both are 2D reads through the same
helper into the same SSBO. Swapping them compiles, returns values in range, and
is wrong everywhere. This is the phase's most likely silent defect.

**Eval and sample are the same function.** With `localO` the outgoing direction
in the local frame:

```
lenSqr = (a·localO.x + b·localO.z)² + (a·localO.y)² + localO.z²
val    = (1/π) · max(localO.z, 0) · (a/lenSqr)²
pdf = val;  eval = val
```

**`pdf == eval` exactly** — the LTC is perfectly importance-sampled, so the
sample weight is 1. No Fresnel, no microfacet, no multi-scatter compensation.
After the coat this is the easy lobe, and §5 exploits the identity as a test.

Sampling draws a uniform disk, lifts it to the hemisphere, and applies the
inverse transform:

```
disk  = sample_uniform_disk(rand);  diskZ = sqrt(1 − dot(disk, disk))
localO = normalize(float3(disk.x − diskZ·b, disk.y, diskZ·a))
```
then rejects if `dot(Ng, wo) <= 0` — against the **geometric** normal, not the
shading normal.

### 4.2 The view-dependent tangent frame

Nothing else in this BRDF has one. `make_orthonormals_safe_tangent(N, wi, &T, &B)`
(`intern/cycles/kernel/sample/mapping.h:55-68`):

```c
*b = safe_normalize(cross(N, T));            // T here is sd->wi
if (len_squared(*b) < 0.99f) {
    make_orthonormals(N, a, b);              // degenerate fallback
} else {
    *a = cross(*b, N);
}
```

**The fallback is not exotic.** It fires when the view is parallel to the
normal — the centre of every sphere facing camera. `safe_normalize` returns
zero on failure and the `< 0.99f` test catches that; note it also catches
near-degenerate cases where normalisation succeeded but the cross product was
short. Reproduce the threshold, not an equivalent-looking `== 0` check.

### 4.3 The invalid-LTC skip

When `|transformA| < 1e-5` **or** `ltc_albedo < 1e-5`, Cycles sets
`CLOSURE_NONE_ID` and `sample_weight = 0` — the closure is dropped entirely
(`bsdf_sheen.h:44-49`). Our registry must give sheen a selection weight of
**exactly** 0 in that case, or the sampler divides by it.

This is the same shape as the coat's cutoff, with one difference worth naming:
the coat's gate is on an authored parameter, so it is knowable before any LUT
read. Sheen's depends on the **table's own output**, so it cannot be hoisted
above the lookup.

### 4.4 What does not change

`prepareBRDFData`, every existing BRDF function, E2b's anisotropy, E1's
dielectric closure, and the coat's *math*. The near-delta specular guard
(`RT_MIS_DELTA_ROUGHNESS`) and the `VplusL` degenerate check in `combinedPdf`
survive verbatim, as in E2c and E2d.

## 5. Verification

1. **doctest** — the LUT indexing including the axis order (§4.1), the frame
   construction and its degenerate fallback (§4.2), the invalid-LTC skip, and
   the N-layer reduction. **Plus the free one: `pdf == eval` asserted directly
   on the CPU mirror.** Any transcription slip that breaks the identity is
   caught without a GPU, which is unusual in this codebase and worth taking.
2. **GPU/CPU parity probe** on the three LUT reads. This is the transposition
   detector, and it must read at points where `(cosNI, roughness)` and
   `(roughness, cosNI)` give *different* answers — a probe on the diagonal
   cannot fail.
3. **Furnace sweep** over `sheen_color` × `sheen_roughness`, asserting the
   stack conserves energy. Measured-intact baselines with a tight band, never
   an absolute comparison against 1.0 — Gap #17 already lifts these surfaces,
   and a gate that cannot *newly* fail is not an instrument (E2b's Important #1).
4. **The `E[1/pdf]` self-normalising instrument** extended to four live lobes,
   using E2d's vis mode 40, which draws from the full production mixture.
   Mode 35 draws from `sampleSpecularMicrofacet` alone and will fail on correct
   code — that trap cost E2d a fix round.
5. **The E2d regression suite unchanged at `sheen_color == 0`** (§3.1). This is
   the phase invariant and the most important row in the table.
6. **Cycles comparison on velvet**, E2's stated acceptance target alongside car
   paint. Report raw and Gap #17-adjusted figures, as E2b and E2d did.

**The sRGB trap applies to `sheen_color`.** Every colour factor is
sRGB-decoded on upload — `albedo_color` (`render_raytracing.cpp:1585`),
`clearcoat_tint` (`:1855`), and `sheen_color` at `:1815`. Cycles' sockets are
linear, so any comparison material must author with `.linear_to_srgb()`. This
trap has been hit twice in this phase family and once inverted a published
verdict (roadmap §7.7).

## 6. Acceptance

1. At `sheen_color == 0`, every E2d gate reads unchanged — the furnace's 36
   configurations and `pt_coat_gate`'s probes alike.
2. A sheen furnace conserves energy across the sweep, and **reverting the
   sheen transmittance makes it fail** — proven by breaking it, not asserted.
3. The transposition probe fails when the LUT axes are swapped. Demonstrate it.
4. `pdf == eval` holds in the CPU mirror across the sampled domain.
5. Velvet lands within 5% of Cycles once Gap #17 is accounted for, raw reported
   alongside.
6. doctest green; all five existing GPU gates unchanged within tolerance.

## 7. Out of scope

- `coat_normal` (§3.5), which now blocks nothing but touches both coat and sheen.
- Gap #17, the base specular's multi-scatter over-compensation.
- The denoiser albedo AOVs, which do not know about coat (roadmap §7.10.7) and
  will not know about sheen either. Adding sheen makes that entry worse, not
  different; record the delta rather than fixing it here.
- The unexercised coat NEE paths recorded in §7.10.7 — E2e touches those call
  sites when it adds a fourth out-parameter, so it may *incidentally* execute
  them, but closing them deliberately is not this phase's job.

## 8. Verified facts

Every row read from the named file while writing this spec.

| Claim | Source |
|---|---|
| Sheen is Zeltner LTC; setup, eval and sample | `intern/cycles/kernel/closure/bsdf_sheen.h:27-110` |
| `pdf == eval` exactly | `bsdf_sheen.h:70-74` |
| Three 32×32 tables in one 3072-float block | `bsdf_sheen.h:37-42`; `intern/cycles/scene/shader.tables:636` |
| LUT axis order is `(cosNI, roughness)` | `bsdf_sheen.h:38-42` |
| The coat's axis order is `(rough, mu)` — transposed | `intern/cycles/kernel/closure/bsdf_microfacet.h:565` |
| Invalid-LTC skip drops the closure | `bsdf_sheen.h:44-49` |
| `weight *= albedo` and `sample_weight *= albedo` | `bsdf_sheen.h:51-52` |
| Sample rejects against the **geometric** normal | `bsdf_sheen.h:96` |
| View-dependent frame, with a `< 0.99f` fallback | `intern/cycles/kernel/sample/mapping.h:55-68` |
| Sheen is the FIRST layer, coat the second | `intern/cycles/kernel/svm/closure.h:115`, `:146` |
| Layering is sequential | `closure.h:141`, `:174` |
| `closure_layering_weight` uses `reduce_max` | `intern/cycles/kernel/closure/bsdf_util.h:440` |
| `bsdf_albedo` is `sc->weight` for non-microfacet closures | `intern/cycles/kernel/closure/bsdf.h:696`, `:707` |
| Cycles forms `sheen_weight · sheen_tint` immediately | `closure.h:124` |
| `CLOSURE_WEIGHT_CUTOFF` is `1e-5f` | `intern/cycles/kernel/svm/types.h:576` |
| Coat normal bends the sheen normal | `closure.h:127-129` |
| `sheen_color`/`sheen_roughness` already reach the GPU, unused | `render_raytracing.h:131-132`, `raytracing_data_inc.glsl:153-154`, upload `render_raytracing.cpp:1815` |
| `BaseMaterial3D` already exposes both | `scene/resources/material.cpp:2383`, `:2392`, `:3913-3914` |
| `brdf_inc.glsl` mentions sheen zero times | grep, this session |
| Colour factors are sRGB-decoded on upload | `render_raytracing.cpp:1585`, `:1815`, `:1855` |
