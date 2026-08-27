# N-Way Lobe Rewrite (E2c) — Design

**Branch:** `vijay_PTEngine_v13_PhaseE2`
**Status:** design, awaiting review
**Predecessor:** `2026-08-22-anisotropic-ggx-design.md` (E2b)
**Successors:** E2d (clearcoat), E2e (sheen)

---

## 1. Goal

Replace the hardcoded two-way `DIFFUSE_TYPE`/`SPECULAR_TYPE` lobe selection
with an N-way structure that renders **identically to today**, so that
clearcoat and sheen — each of which adds a layer — can be built on a
foundation already proven correct.

**This phase ships no feature.** If it succeeds, no render changes and the
only evidence of it is that the next phase becomes tractable.

## 2. Scope

**In:** the lobe registry, the CDF selection, the `Σ pᵢ·pdfᵢ` combination,
and unifying the two duplicated lobe-probability functions.

**Out:** clearcoat, sheen, any new material field, any new vis mode, any
change to the anisotropy work E2b landed, and any change to the layering
*semantics* (Cycles attenuates lower layers via `closure_layering_weight`;
that arrives with the first real layer in E2d, not here).

## 3. Decisions

### 3.1 The two lobe-probability functions are unified

`combinedPdfLobeProbability` and `samplerLobeProbability`
(`brdf_inc.glsl:1738` and `:1761`) currently compute the identical formula
from identical inputs, deliberately duplicated. The comment at `:1727-1737`
argues the duplication is what makes a divergence "representable and
catchable at all", and cites the historical defect it was created for
(pSpec 0.0476 against the sampler's 0.0909).

**That reasoning has been overtaken by E2b.** The detector it names —
comparing the two values side by side — is a comparison of two evaluations of
one formula. E2b's final review established that exact construction is a
tautology in vis mode 35 and cannot fail. E2b replaced it with a
self-normalizing instrument: draw from the real sampler, accumulate
`1/pdf`, and compare the mean against the domain's measure. A pdf wrong by a
constant factor `k` reads `1/k`, whether or not a second copy of the formula
exists.

So unification now makes the desync **structurally impossible** *and* leaves
it **detectable**. The duplication is retired for the reason it was created.
The new single function must carry a comment recording this, so a future
reader does not restore the duplication on the strength of the old comment.

### 3.2 Specular is lobe index 0

Non-negotiable, and the single most likely way to break this phase silently.

`raytracing_closest_hit_common_inc.glsl:1332-1335` reads:

```glsl
float brdfProbability = samplerLobeProbability(brdf_mat);
if (rng_1d(rng, RT_PRNG_LOBE) < brdfProbability) {
    brdfType = SPECULAR_TYPE;
    ps.throughput /= brdfProbability;
```

A CDF draw picks lobe 0 when `u < cdf[0]`. If the registry orders diffuse
first, `u < cdf[0]` selects **diffuse** exactly where today it selects
**specular** — inverting every pixel's lobe choice. The image stays
statistically identical, so every gate passes, and the output is bitwise
unrecognisable.

**Specular occupies index 0. The registry order is part of the contract, not
an implementation detail.**

### 3.3 The RNG draw is preserved exactly

One call, `rng_1d(rng, RT_PRNG_LOBE)`, on that named stream, consumed once.
An N-way selection that consumes a second value, remaps `u`, or rescales it
into a sub-interval shifts every subsequent sample in the path. The result
would be a statistically valid render that is bitwise different everywhere —
and, again, invisible to every gate.

Consuming the draw identically is a hard requirement. Reusing the *same*
`u` for both the lobe pick and a downstream sample is also forbidden unless
today's code already does so; the implementer must check rather than assume.

### 3.4 Float evaluation order is preserved

`Σ pᵢ·pdfᵢ` over an array may associate differently from today's explicit
two-term expression, changing the last bits. At N=2 the sum must produce the
same operations in the same order as the code it replaces.

**Amended during execution (2026-08-23).** One reassociation is unavoidable
and is accepted. C parses `a * b * c` as `(a * b) * c`, so the shader computes
`(pSpec * specularContribution) * transmitScale`. The registry folds
`transmitScale` into the specular lobe's pdf entry, computing
`pSpec * (specularContribution * transmitScale)`. **1 ULP apart in float32** at
the inputs the doctest pins — `6.2e-8` relative on the specular term, `1.06e-7`
on the full combined expression there. A measurement at one triple, not a bound.
Mathematically equal on every reachable input; see roadmap §7.9 for the
`pSpec == 0.0` × non-finite corner the phrase does not cover.

Found by Task 1's own test before any shader was touched.

**Ruling: accept it.** Contorting the registry to preserve one grouping would
make it something other than a uniform sum, which is precisely what E2d and
E2e are meant to build on, and every future lobe would reintroduce the same
question. The difference is two orders of magnitude below `mean_luma`'s ~1e-5
run-to-run floor on an identical binary, so no instrument in this project can
resolve it.

**The claim is therefore weakened, not the code**: this phase is identical to
today except for one documented reassociation on the specular term. A doctest
case pins the 1-ULP gap so it is a recorded fact rather than a puzzle for
whoever next compares the two expressions.

## 4. Design

### 4.1 The registry

A fixed-size array of lobe descriptors, sized by a compile-time constant that
is **2 in this phase**. Each entry carries its selection weight and the
identity of its sample/eval/pdf routines. GLSL has no function pointers, so
dispatch is a `switch` on a lobe index — the same shape the existing
`brdfType` branch already has, widened.

Selection: normalise the weights, walk the CDF, return the index. At N=2 this
reduces to today's single comparison, in the order §3.2 fixes.

Combination: `Σ pᵢ · pdfᵢ` over the same array, in registry order.

### 4.2 What does NOT change

`prepareBRDFData`, every BRDF function, the anisotropy path from E2b, the
E1 dielectric/transmissive closure, NEE, the environment path, and every
`MaterialProperties`/`BrdfData` field. The rewrite is confined to selection
and combination.

The near-delta specular guard (`RT_MIS_DELTA_ROUGHNESS`) and the
`VplusL` degenerate check in `combinedPdf` are behaviour and must survive
verbatim; they are not selection logic and must not be folded into the
registry.

## 5. Verification, and an honest limit

**Rendered means cannot verify bit-identity.** `pt_validation`'s `mean_luma`
has a documented ~1e-5 run-to-run noise floor on an *identical binary*, from
GPU float non-associativity in the accumulation reduction. A gate matching to
five decimal places proves the refactor did not change behaviour meaningfully.
It does not prove bit-identity, and this spec does not claim it does.

Three layers, in increasing strength for what they actually cover:

1. **doctest** — a CPU mirror asserting the N-way reduction collapses to the
   two-term form at N=2, including that specular is index 0 and that the CDF
   comparison reproduces `u < brdfProbability` rather than its complement.
   Cheap, and it pins §3.2 numerically.
2. **The five existing GPU gates**, unchanged within their tolerances.
   E2b's `pt_anisotropy_gate` is the tightest at ±0.5pp around measured
   baselines and is therefore the most informative of them.
3. **Structural review** — confirming the RNG draw is consumed identically,
   the registry order is specular-first, and the summation order matches.
   **This layer carries the bit-identity claim.** The other two cannot.

That ordering is deliberate. This project's recurring defect is a green
suite that cannot see the thing that is wrong; here the suite genuinely
cannot see the primary risk, so the review is named as the instrument rather
than treated as a formality.

## 6. Acceptance

1. All five GPU gates unchanged within tolerance; `pt_anisotropy_gate` still
   passes its ±0.5pp bands.
2. doctest green, with the new reduction cases added.
3. A reviewer confirms in writing: one `rng_1d(rng, RT_PRNG_LOBE)` call,
   consumed once; specular at index 0; summation order preserved.
4. `N` is a named constant and adding a third lobe requires no change to the
   selection or combination code — the phase's actual deliverable.
5. The unified lobe-probability function carries the comment explaining why
   the duplication was retired.

## 7. Out of scope

- Clearcoat (E2d), sheen (E2e), and Cycles' `closure_layering_weight`
  attenuation semantics, which arrive with the first real layer.
- Gap #17, the multi-scatter over-compensation.
- The raster/RT orientation divergence recorded in roadmap §7.8.
- Minor #5 from E2b: non-default `SPECULAR_BRDF`/`MICROFACET_DISTRIBUTION`
  configurations no longer compile.

## 8. Verified facts

Every row read from the named file while writing this spec.

| Claim | Source |
|---|---|
| Lobe types are `DIFFUSE_TYPE 1` / `SPECULAR_TYPE 2` | `brdf_inc.glsl:106-107` |
| The sampler picks specular on the `<` side of one RNG draw | `raytracing_closest_hit_common_inc.glsl:1332-1335` |
| The draw is `rng_1d(rng, RT_PRNG_LOBE)` | same |
| Two lobe-probability functions, identical bodies | `brdf_inc.glsl:1738-1751`, `:1761-1774` |
| Their duplication is deliberate, and why | `brdf_inc.glsl:1727-1737` |
| `combinedPdf` carries a `VplusL` degenerate guard | `brdf_inc.glsl:1848-1852` |
| `combinedPdf` carries a near-delta specular guard | `brdf_inc.glsl:1857-1882` |
| Cycles attenuates lower layers rather than adding lobes | `intern/cycles/kernel/svm/closure.h:141` (sheen) and `:174` (coat), both `closure_layering_weight` |
| `mean_luma` has a ~1e-5 run-to-run floor on one binary | `PATH_TRACER_QUALITY_ROADMAP.md`, E1 measurement notes |
