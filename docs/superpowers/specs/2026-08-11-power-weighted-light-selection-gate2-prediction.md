# Gate 2 (`culled`) direction prediction

Written and committed **before gate 2 was measured**. If the measurement
contradicts it, the contradiction is recorded and investigated — this file is
not revised to match the result.

The pre-C2 estimator sets

    light_select_pdf = 1 / (light_count * valid_found / k)

With 8 of 16 lights out of range, `E[valid_found] = k/2`, so the estimate
centres on `light_count/2 = 8` and the pdf on `1/8` — which is correct *on
average*. The bias is in the **reciprocal**: `E[1/X̂] >= 1/E[X̂]` by Jensen,
since `1/x` is convex. So the pre-C2 divisor is on average **too large**, and
the pre-C2 image is therefore **too bright**.

**Prediction: the C2 mean is LOWER than the pre-C2 mean on gate 2.**

Magnitude expected to be small — a few percent at `k = 16`, since the relative
variance of `valid_found` goes as `1/k`.

## Gate 1, by contrast

Gate 1 (`in_range`) has every light within range, so `valid_found == k`
deterministically, `valid_count_estimate == light_count` with zero variance, and
`1/estimate` is the true density. Both estimators are unbiased for the same
integral there. **Gate 1 predicts NO shift**, and the harness asserts it at 1%.
A shift on gate 1 would be a defect in the C2 selector, not a finding.

## Secondary use

Gate 2 is also the liveness probe for the A/B: it is a configuration where the
two builds must read *differently*. Two identical readings would mean the
`RT_LIGHT_SELECT_UNIFORM` edit never reached the shader (stale `.glsl.gen.h`),
not that the change is neutral.
