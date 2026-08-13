# Enabling emissive-mesh lights in the pipeline

**Status:** the feature is landed and gated. `rendering/pathtracer/emissive_mesh_lights`
defaults to `false`, and while it is false nothing about existing renders changes —
no buffers are allocated, no compute pass is dispatched, and the closest-hit path is
byte-identical to before C1.

**Short answer: do not flip this on for `image_glb_creation.gd` night renders without
first doing one of the fixes in §3.** Doing so will make night renders brighter, by an
amount nobody can predict analytically. Day renders are unaffected either way.

---

## 1. What the setting actually does

With it on, a mesh whose material is emissive becomes a *sampled light source*: the
path tracer picks points on it directly (next-event estimation) instead of waiting for
a bounce ray to stumble onto it, and combines the two strategies with multiple
importance sampling so the surface is counted exactly once.

The energy in a correctly-authored scene is unchanged — that is what gate 1 asserts,
and it measures −0.021% / +0.019% against a tolerance derived from the run's own
noise. What changes is **variance**: equal-time RMSE improves 3.16–3.86× for a 2.0 m
panel and 35.18–67.57× for a 0.25 m panel of the same total power. Small bright
emitters benefit most, because those are the ones a BSDF ray almost never hits.

Frame cost when enabled: **+9% to +15%** (three interleaved runs; the spread is
thermal, so treat "roughly +10%" as the honest figure).

To enable, in `project.godot`:

```
[rendering]
pathtracer/emissive_mesh_lights=true
```

---

## 2. Why the pipeline cannot simply turn it on

`pipeline_references/image_glb_creation.gd` represents every light fixture **twice** on
night renders. This is a content-level double-representation that C1 *exposes* rather
than causes — the engine cannot detect it, because an emissive mesh and an analytic
light are independent objects with no relationship the renderer can see.

Concretely:

| Where | What happens |
|---|---|
| `_apply_light_fixture_emission`, line 4281 | Makes the bulb surface glow. Gated on the material or surface name containing one of `bulb`, `filament`, `led`, `emiss`, `glow`, `neon` (line 4322). |
| Line 4607 | Its return value is captured as `emissive_surface_found`. |
| Lines 4621 onward | An `OmniLight3D` or `SpotLight3D` is created at the same fixture **unconditionally**. |
| Line 4731 | `emissive_surface_found` is used for a diagnostic `print` and nothing else. |

Today that is harmless: the emissive mesh contributes only through rare BSDF hits
while the analytic light does all the work. **C1 turns each of those bulb surfaces
into a second, fully-sampled light.**

This is structurally the same defect as the `SKY_MODE_LIGHT_AND_SKY` sun-disc
double-count that previously forced `SKY_MODE_LIGHT_ONLY`.

**Day renders are already safe.** `mat.emission_enabled = false` (around line 1112)
disables fixture emission outright for day, so C1 is a no-op there regardless.

### How much brighter?

Unknown, and not worth guessing. It is not "2× brighter" — the bulb surface is small,
its emission energy was authored for *appearance* rather than calibrated as a light
source, and the analytic lights carry tuned range and attenuation the mesh does not.
The only honest answer comes from measuring (§4).

---

## 3. Options

### Option A — leave it off for this pipeline (no work, zero risk)

The default. C1 remains available for other scenes and other projects. Night renders
keep the analytic fixture lighting that is already tuned.

Choose this unless you specifically want authored emissive content — neon signs, TVs,
monitors, backlit panels — to light the room. Note that **that content currently
lights nothing at all**, which is the gap C1 was built to close.

### Option B — suppress the analytic light where a bulb was found (recommended if you want the feature)

`emissive_surface_found` is already computed at line 4607 and currently thrown away.
Use it: when a fixture has a genuine emissive bulb surface, let the bulb *be* the
light and skip creating the `OmniLight3D` / `SpotLight3D`.

This is the physically correct arrangement and the one C1 exists to enable. Budget
real work for it:

- **Emission energy needs recalibrating.** It was authored to look right, not to
  deliver the fixture's luminous output. Expect to retune per fixture type.
- **You lose the tuned analytic behaviour** — `omni_range`, `omni_attenuation`, the
  ceiling-mount downward spot, and the `shadow_companion` shadow-caster. A bulb mesh
  radiates from its own geometry and obeys no range parameter.
- **Shadowing changes.** All fixture lights currently join the `fixture_lights` group
  and mostly set `shadow_enabled = false`; an emissive mesh always casts, because the
  shadow ray is part of the estimator. Expect night renders to get slower as well as
  different — this is the same mechanism that made power-weighted selection cost
  2.28× in production earlier this phase.

### Option C — keep both and scale the analytic energy down

Measure the brightness increase, then reduce `light_energy` on the fixture lights
until night renders match the pre-C1 reference. Fastest to try, and the least
principled: you are hand-tuning one light to cancel another, and the balance will
drift the moment fixture geometry or emission changes. Acceptable as a stopgap, not
as an end state.

### What is missing, and worth asking for

There is **no per-instance opt-out** — no way to say "this bulb should look emissive
but must not be sampled as a light". That is the feature that would make Option A and
Option B coexist cleanly, and it does not exist today. If the pipeline wants glow
without lighting, that is an engine change to request, not something to work around.

Do **not** try to get an opt-out by exploiting the exclusions in §5. They are
implementation consequences, not an API, and they will move.

---

## 4. How to verify, whichever option you take

Do not trust a visual comparison for this. The whole failure mode is a brightness
shift, and eyes are bad at absolute brightness.

**Step 1 — the engine gates still pass.** These prove the feature itself is sound and
live, independent of your scene:

```bash
ZR_EMIS_GATE_MODE=all bin/godot.windows.editor.x86_64.console.exe --path pipeline_references res://tests/pt_emissive_gate_scene.tscn
```

Run the full suite, not a single mode — gate 1 is the only one carrying the liveness
probe, and a partial run now reports `INCONCLUSIVE` rather than `PASS` for exactly
that reason.

**Step 2 — measure your own scene, off then on.** Render the same night scene with
the setting false and true, at the same frame count, and compare converged means.
A correct configuration gives the *same mean* with *lower per-pixel spread*. A
brighter mean means the double-representation is still present.

**Step 3 — check the pixel spread, not just the mean.** Equal means alone are also
satisfied by a feature that never activated. If the spread does not fall, the setting
did not reach the shader — most likely a stale `.glsl.gen.h`, which is fixed by a full
rebuild.

---

## 5. Emitters that will not benefit

Five classes are deliberately excluded from the light distribution. Exclusion is
**unbiased** — an excluded emitter keeps `emissive_slot == -1`, so MIS hands the BSDF
path full weight and the surface is still lit correctly, just at pre-C1 variance.
Nothing goes dark and no energy is lost.

| Excluded | Why |
|---|---|
| Deformed geometry (skinned, vertex-animated) | Its cached area would go stale against moving vertices, which would be a real bias. |
| Custom hit-group materials | Their radiance comes from user shader code with no material equivalent NEE could read. |
| Alpha-tested materials | `any_hit` discards below 0.5 alpha, so a BSDF ray sees cut-outs that uniform area sampling does not. |
| `CULL_MODE_FRONT` materials | Unreachable by BSDF rays on exactly the side that would emit. |
| Meshes with no normal attribute | The emitting side would be arbitrary. |

**There is currently no diagnostic when an emitter is dropped.** Author an
alpha-scissored neon sign and you get no NEE benefit and no warning. A skipped-emitter
counter is the obvious next improvement and is recorded as an open item.

Also note the cap: **at most 256 emissive instances** participate. Beyond that,
instances are ranked by a heuristic (luminance × strength × bounding scale) and the
remainder are excluded — again unbiased, just noisier. For a 144-asset scene this is
not close to binding, but a scene that makes every LED strip its own instance could
reach it.

---

## 6. Related

- `PATH_TRACER_QUALITY_ROADMAP.md` — the C1 entry, with measured figures and the full
  open-items list.
- `docs/superpowers/specs/2026-08-12-emissive-mesh-lights-design.md` — §2.1 is the
  original statement of the double-representation; §4 is the sampling design.
- `.superpowers/sdd/2026-08-12-emissive-mesh-lights/task-6-report.md` — the complete
  measurement method and every number behind §1.
