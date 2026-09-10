Here's the honest state of the board, read off the roadmap and verified against the code rather than recalled.

## My recommendation: Gap #17

**`evalMultiScatterApproximation` over-shoots by 3.4–8.1 percentage points on every rough surface.** It's the largest quantified parity gap left, and it's the one I'd do next for three reasons:

- **Breadth.** It sits under *every* rough metal and dielectric — four call sites: `brdf_inc.glsl:1331`, `:1484`, `raytracing_closest_hit_common_inc.glsl:1772`, `raytracing_emissive_inc.glsl:496`.
- **It's poisoning your other measurements.** Every Cycles comparison in the document has to state itself twice: brushed metal is +6.52% raw but 0.67% with the pedestal neutralised; velvet is −1.71% raw and −2.14% adjusted. Until this is gone, no parity number in the document means what it says. It blocks trustworthy measurement of everything downstream.
- **It isn't research — the machinery is already in the tree.** `servers/rendering/renderer_rd/storage_rd/ggx_energy_tables.h` already holds Cycles' `table_ggx_E[1024]` and `table_ggx_Eavg[32]`, transcribed from `microfacet_ggx_preserve_energy`, with a CPU mirror at `tests/servers/rendering/test_pt_coat_albedo.cpp`. E2d shipped all of it **for the coat**. The base specular lobe was left on a fitted polynomial (`evalEmsApprox`, `brdf_inc.glsl:1215`) that no Cycles line corresponds to. The work is pointing the base lobe at the table the coat already uses.

That pairs naturally with the follow-up I filed today — giving the base specular lobe a directional albedo and routing both sides through `layerTransmittanceAbove`, exactly as E2d did for the coat. Same lobe, same file, same machinery, same energy study. One phase: **"give the base specular lobe what E2d already gave the coat."**

## Cheapest decisive thing, and it's on your thread

**Gap #18 — render the aquarium GLB in Cycles and look at the glass.** One render. It decides whether clear glass reading flat is a real bug or whether the pipeline substitution you committed is an improvement to keep — and right now that question is blocking both answers. Everything else in §9.10 is premature until it's done. This is the glass-asset complaint you raised directly.

## Also open, lower leverage

| Item | Note |
|---|---|
| §7.11.2 — dielectric base is **−2.06%** vs Cycles | worst arm in the velvet comparison, unexplained |
| `coat_normal` not shipped | blocks geometric parity for car paint *and* velvet |
| Asymmetric firefly clamping across the MIS partition | invisible only because clamping defaults off |
| NEE vs BSDF Fresnel on transmissive surfaces | roadmap calls it "the highest-value correctness item E2 inherits" |
| `SKY_MODE_LIGHT_AND_SKY` double count | |
| E3 SSS, F2 volumetrics, transmissive-lobe anisotropy | unshipped features, not defects |

## Two bits of housekeeping

The branch-integration menu from the transparent-BSDF work was never answered, and the branch has moved twice since (`V15_Glass2` → `V16_Glass4` → `V17_Fabric`), so it's probably moot — but today's fix is sitting on `V17_Fabric` unpushed and you may want it somewhere else.

And §6's ordering line still reads `A1 → A2/A3/A4 → D → E → F`, though §4 marks Phase A implemented. A one-line correction whenever the roadmap is next touched — not worth a commit alone.
