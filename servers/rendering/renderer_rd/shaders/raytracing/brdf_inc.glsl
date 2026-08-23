#ifndef BRDF_HLSLI
#define BRDF_HLSLI

/* Creative Commons CC0 Public Domain. To the extent possible under law,
Jakub Boksansky has waived all copyright and related or neighboring rights
to Crash Course in BRDF Implementation Code Sample.
This work is published from: Germany. */

// This is a code sample accompanying the "Crash Course in BRDF Implementation" article
// v1.1, February 2021

// -------------------------------------------------------------------------
//    C++ / GLSL / HLSL compatibility
// -------------------------------------------------------------------------

#if defined(__cplusplus) && !defined(GLSL)

#pragma once

// Include additional things when compiling HLSL as C++
// Here we use the GLM library to support HLSL types and functions
// Modification: Godot preprocessor doesn't understand #include in #if blocks.. If you need to use C++, make sure to include these yourself.
//#include "glm/glm/glm.hpp"
//#include "glm/glm/gtc/constants.hpp"
//#include "glm/glm/gtx/compatibility.hpp"

#define OUT_PARAMETER(X) X &

using namespace glm;

inline float rsqrt(float x) {
	return inversesqrt(x);
}
inline float saturate(float x) {
	return clamp(x, 0.0f, 1.0f);
}
inline float rcp(float x) {
	return 1.0f / x;
}
template <typename T>
T mad(T a, T b, T c) {
	return a * b + c;
}
template <typename M, typename V>
V mul(const M &m, const V &v) {
	return m * v;
}
// GLM is column-major like GLSL - transpose constructor args
#define MAKE_FLOAT2x2(r0c0, r0c1, r1c0, r1c1) mat2(r0c0, r1c0, r0c1, r1c1)
#define MAKE_FLOAT3x3(r0c0, r0c1, r0c2, r1c0, r1c1, r1c2, r2c0, r2c1, r2c2) \
	mat3(r0c0, r1c0, r2c0, r0c1, r1c1, r2c1, r0c2, r1c2, r2c2)

#elif defined(GLSL)
// GLSL detected - define HLSL-compatible types and functions

#define float2 vec2
#define float3 vec3
#define float4 vec4
#define float2x2 mat2
#define float3x3 mat3
#define float4x4 mat4

#define lerp mix
#define saturate(x) clamp(x, 0.0, 1.0)
#define rsqrt inversesqrt
#define rcp(x) (1.0 / (x))
#define mad(a, b, c) ((a) * (b) + (c))
#define mul(M, v) ((M) * (v))

// HLSL is row-major, GLSL is column-major - transpose constructor args for GLSL
#define MAKE_FLOAT2x2(r0c0, r0c1, r1c0, r1c1) mat2(r0c0, r1c0, r0c1, r1c1)
#define MAKE_FLOAT3x3(r0c0, r0c1, r0c2, r1c0, r1c1, r1c2, r2c0, r2c1, r2c2) \
	mat3(r0c0, r1c0, r2c0, r0c1, r1c1, r2c1, r0c2, r1c2, r2c2)

#define OUT_PARAMETER(X) out X

#else
// HLSL
#define OUT_PARAMETER(X) out X
#define MAKE_FLOAT2x2(r0c0, r0c1, r1c0, r1c1) float2x2(r0c0, r0c1, r1c0, r1c1)
#define MAKE_FLOAT3x3(r0c0, r0c1, r0c2, r1c0, r1c1, r1c2, r2c0, r2c1, r2c2) \
	float3x3(r0c0, r0c1, r0c2, r1c0, r1c1, r1c2, r2c0, r2c1, r2c2)
#endif

// -------------------------------------------------------------------------
//    Constant Definitions
// -------------------------------------------------------------------------

#define NONE 0

// NDF definitions
#define GGX 1
#define BECKMANN 2

// Specular BRDFs
#define MICROFACET 1
#define PHONG 2

// Diffuse BRDFs
#define LAMBERTIAN 1
#define OREN_NAYAR 2
#define DISNEY 3
#define FROSTBITE 4

// BRDF types
#define DIFFUSE_TYPE 1
#define SPECULAR_TYPE 2

// PIs
#ifndef PI
#define PI 3.141592653589f
#endif

#ifndef TWO_PI
#define TWO_PI (2.0f * PI)
#endif

#ifndef ONE_OVER_PI
#define ONE_OVER_PI (1.0f / PI)
#endif

#ifndef ONE_OVER_TWO_PI
#define ONE_OVER_TWO_PI (1.0f / TWO_PI)
#endif

// -------------------------------------------------------------------------
//    Configuration macros (user editable - set your preferences here)
// -------------------------------------------------------------------------

// Specify what NDF (GGX or BECKMANN you want to use)
#ifndef MICROFACET_DISTRIBUTION
#define MICROFACET_DISTRIBUTION GGX
//#define MICROFACET_DISTRIBUTION BECKMANN
#endif

// Specify default specular and diffuse BRDFs
#ifndef SPECULAR_BRDF
#define SPECULAR_BRDF MICROFACET
//#define SPECULAR_BRDF PHONG
//#define SPECULAR_BRDF NONE
#endif

#ifndef DIFFUSE_BRDF
#define DIFFUSE_BRDF LAMBERTIAN
//#define DIFFUSE_BRDF OREN_NAYAR
//#define DIFFUSE_BRDF DISNEY
//#define DIFFUSE_BRDF FROSTBITE
//#define DIFFUSE_BRDF NONE
#endif

// Specifies minimal reflectance for dielectrics (when metalness is zero)
// Nothing has lower reflectance than 2%, but we use 4% to have consistent results with UE4, Frostbite, et al.
#define MIN_DIELECTRICS_F0 0.04f

// Enable this to weigh diffuse by Fresnel too, otherwise specular and diffuse will be simply added together
// (this is disabled by default for Frostbite diffuse which is normalized to combine well with GGX Specular BRDF)
#if DIFFUSE_BRDF != FROSTBITE
#define COMBINE_BRDFS_WITH_FRESNEL 1
#endif

// Uncomment this to use "general" version of G1 which is not optimized and uses NDF-specific G_Lambda (can be useful for experimenting and debugging)
//#define Smith_G1 Smith_G1_General

// Enable optimized G2 implementation which includes division by specular BRDF denominator (not available for all NDFs, check macro G2_DIVIDED_BY_DENOMINATOR if it was actually used)
#define USE_OPTIMIZED_G2 1

// Enable height correlated version of G2 term. Separable version will be used otherwise
#define USE_HEIGHT_CORRELATED_G2 1

// Master toggle for the shading-normal clamp at grazing angles.
// 0 -> clampShadingNormal becomes a passthrough; only the mirror fallback in
//      shade_and_bounce remains active.
// 1 -> clamp + mirror two-layer fallback (default).
#ifndef RT_SHADING_NORMAL_CLAMP_ENABLED
#define RT_SHADING_NORMAL_CLAMP_ENABLED 1
#endif

// Geometry NdotV below which clampShadingNormal starts pulling the shading
// normal toward the geometry normal. Higher values flatten normal-mapped
// detail at grazing angles but reduce BRDF below-hemisphere rejections.
// Used by both the production indirect-bounce path and the matching debug
// visualization so they remain in sync.
#ifndef RT_SHADING_NORMAL_CLAMP_THRESHOLD
#define RT_SHADING_NORMAL_CLAMP_THRESHOLD 0.4f
#endif

// Enable below-hemisphere sample recovery.
// 0 -> disable recovery and terminate the path on rejection instead.
// 1 -> enable recovery and reuse the original BRDF weight.
#ifndef RT_BELOW_HEMISPHERE_RECOVERY_ENABLED
#define RT_BELOW_HEMISPHERE_RECOVERY_ENABLED 1
#endif

// -------------------------------------------------------------------------
//    Automatically resolved macros based on preferences (don't edit these)
// -------------------------------------------------------------------------

// Select distribution function
#if MICROFACET_DISTRIBUTION == GGX
#define Microfacet_D GGX_D
#elif MICROFACET_DISTRIBUTION == BECKMANN
#define Microfacet_D Beckmann_D
#endif

// Select G functions (masking/shadowing) depending on selected distribution
#if MICROFACET_DISTRIBUTION == GGX
#define Smith_G_Lambda Smith_G_Lambda_GGX
#elif MICROFACET_DISTRIBUTION == BECKMANN
#define Smith_G_Lambda Smith_G_Lambda_Beckmann_Walter
#endif

#ifndef Smith_G1
// Define version of G1 optimized specifically for selected NDF
#if MICROFACET_DISTRIBUTION == GGX
#define Smith_G1 Smith_G1_GGX
#elif MICROFACET_DISTRIBUTION == BECKMANN
#define Smith_G1 Smith_G1_Beckmann_Walter
#endif
#endif

// Select default specular and diffuse BRDF functions
#if SPECULAR_BRDF == MICROFACET
#define evalSpecular evalMicrofacet
#define sampleSpecular sampleSpecularMicrofacet
#if MICROFACET_DISTRIBUTION == GGX
#define sampleSpecularHalfVector sampleGGXVNDF
#else
#define sampleSpecularHalfVector sampleBeckmannWalter
#endif
#elif SPECULAR_BRDF == PHONG
#define evalSpecular evalPhong
#define sampleSpecular sampleSpecularPhong
#define sampleSpecularHalfVector samplePhong
#else
#define evalSpecular evalVoid
#define sampleSpecular sampleSpecularVoid
#define sampleSpecularHalfVector sampleSpecularHalfVectorVoid
#endif

#if MICROFACET_DISTRIBUTION == GGX
#define specularSampleWeight specularSampleWeightGGXVNDF
#define specularPdf sampleGGXVNDFReflectionPdf
#else
#define specularSampleWeight specularSampleWeightBeckmannWalter
#define specularPdf sampleBeckmannWalterReflectionPdf
#endif

#if DIFFUSE_BRDF == LAMBERTIAN
#define evalDiffuse evalLambertian
#define diffuseTerm lambertian
#elif DIFFUSE_BRDF == OREN_NAYAR
#define evalDiffuse evalOrenNayar
#define diffuseTerm orenNayar
#elif DIFFUSE_BRDF == DISNEY
#define evalDiffuse evalDisneyDiffuse
#define diffuseTerm disneyDiffuse
#elif DIFFUSE_BRDF == FROSTBITE
#define evalDiffuse evalFrostbiteDisneyDiffuse
#define diffuseTerm frostbiteDisneyDiffuse
#else
#define evalDiffuse evalVoid
#define evalIndirectDiffuse evalIndirectVoid
#define diffuseTerm none
#endif

// -------------------------------------------------------------------------
//    Structures
// -------------------------------------------------------------------------

struct MaterialProperties {
	float3 baseColor;
	float metalness;

	float3 emissive;
	float roughness;
	// Base reflectance for dielectrics (e.g. 0.04 for the default 4%). PER-CHANNEL
	// since roadmap E1: glTF's KHR_materials_specular specularColorFactor tints the
	// dielectric F0 only, never the metallic F0 (which is baseColor). Was a scalar
	// float before E1; widening is a no-op at the default white tint.
	float3 dielectricF0;
	float transmissivness;
	// RELATIVE index of refraction (eta), NOT the absolute material IOR --
	// dielectricFresnelSplit's eta parameter and combinedPdf's transmitScale
	// both consume this directly. On an interior hit (ray already inside the
	// medium) this must already be the FLIPPED ratio (1/ior), matching
	// whatever sampleDielectricMicrofacet used to sample the direction being
	// evaluated -- combinedPdf and the closure disagreeing about absolute vs.
	// relative IOR here would silently partition a different integrand on
	// every interior bounce, the same defect class as B2. Only consulted when
	// transmissivness > 0 -- see combinedPdf's transmitScale. Defaulted to 1.5
	// (glass, exterior) at every call site until Task 6 sets it from
	// resolved_eta / its interior-hit flip.
	float eta;
	float opacity;

	// E2b anisotropy. `anisotropy` is SIGNED [-1,1] (see anisoAspect).
	// `anisotropyRotation` is RADIANS, NOT turns -- Godot's property hint is
	// "0,6.2831853,0.001,radians_as_degrees" (scene/resources/material.cpp:3811)
	// and render_raytracing.cpp uploads it unmodified. Cycles stores turns and
	// multiplies by 2*PI (closure.h:316); doing that here would be a 6.28x error.
	float anisotropy;
	float anisotropyRotation;
	// World-space surface tangent. Zero-length means "no usable tangent", which
	// forces the isotropic fallback -- Cycles gates the same way on
	// stack_valid(data.tangent_offset) (closure.h:309).
	float3 tangent;
};

// Data needed to evaluate BRDF (surface and material properties at given point + configuration of light and normal vectors)
struct BrdfData {
	// Material properties
	float3 specularF0;
	float3 diffuseReflectance;

	// Roughnesses
	float roughness; //< perceptively linear roughness (artist's input)
	float alpha; //< linear roughness - often 'alpha' in specular BRDF equations
	float alphaSquared; //< alpha squared - pre-calculated value commonly used in BRDF equations

	// Commonly used terms for BRDF evaluation
	float3 F; //< Fresnel term

	// Vectors
	float3 V; //< Direction to viewer (or opposite direction of incident ray)
	float3 N; //< Shading normal
	float3 H; //< Half vector (microfacet normal)
	float3 L; //< Direction to light (or direction of reflecting ray)

	float NdotL;
	float NdotV;

	float LdotH;
	float NdotH;
	float VdotH;

	// True when V/L is backfacing wrt. shading normal N
	bool Vbackfacing;
	bool Lbackfacing;

	// E2b. ax/ay are the elliptical roughnesses; anisoPhi is the azimuth, in the
	// local (N -> +Z) frame, of the axis ax runs along. Consumers rotate about Z
	// by -anisoPhi before evaluating and by +anisoPhi after sampling. Storing ONE
	// angle here, computed once in prepareBRDFData, is what stops the sampler and
	// the pdf deriving the frame differently -- that desync is mean-preserving
	// and no rendered image can catch it (spec section 4.4).
	float ax;
	float ay;
	float anisoPhi;
	// True only when anisotropy is actually in play. When false EVERY consumer
	// must take the existing isotropic path unchanged -- the anisotropic form is
	// strictly MORE accurate (see Task 3 Step 4), and taking it unconditionally
	// would silently shift every polished material and break the no-pixel-change
	// guarantee.
	bool anisoActive;
};

// -------------------------------------------------------------------------
//    Utilities
// -------------------------------------------------------------------------

// Converts Phong's exponent (shininess) to Beckmann roughness (alpha)
// Source: "Microfacet Models for Refraction through Rough Surfaces" by Walter et al.
float shininessToBeckmannAlpha(float shininess) {
	return sqrt(2.0f / (shininess + 2.0f));
}

// Converts Beckmann roughness (alpha) to Phong's exponent (shininess)
// Source: "Microfacet Models for Refraction through Rough Surfaces" by Walter et al.
float beckmannAlphaToShininess(float alpha) {
	return 2.0f / min(0.9999f, max(0.0002f, (alpha * alpha))) - 2.0f;
}

// Converts Beckmann roughness (alpha) to Oren-Nayar roughness (sigma)
// Source: "Moving Frostbite to Physically Based Rendering" by Lagarde & de Rousiers
float beckmannAlphaToOrenNayarRoughness(float alpha) {
	return 0.7071067f * atan(alpha);
}

float luminance(float3 rgb) {
	return dot(rgb, float3(0.2126f, 0.7152f, 0.0722f));
}

// -------------------------------------------------------------------------
//    Dielectric Fresnel and refraction (roadmap E1)
//
//    Ported from Blender Cycles, intern/cycles/kernel/closure/bsdf_util.h:47-108.
//    A C++ MIRROR of these four functions lives in
//    tests/servers/rendering/test_pt_transmission.cpp and is what the doctest
//    suite asserts against -- the suite does NOT execute this shader. Keep the
//    two textually identical modulo type names; a drift makes the tests pass
//    while this code is wrong.
//
//    Why not reuse the Schlick evalFresnel above: Schlick is parameterised on
//    F0 and has no eta, so it cannot express total internal reflection at all.
//    TIR here falls out of the SAME test that produces cos_theta_t, so the two
//    cannot drift out of sync.
// -------------------------------------------------------------------------

float sqr(float x) {
	return x * x;
}

float F0_from_ior(float ior) {
	return sqr((ior - 1.0f) / (ior + 1.0f));
}

float ior_from_F0(float f0) {
	float sqrt_f0 = sqrt(clamp(f0, 0.0f, 0.99f));
	return (1.0f + sqrt_f0) / (1.0f - sqrt_f0);
}

// Returns reflectance for unpolarized light. Writes the cosine of the
// transmitted angle (NEGATIVE, relative to the surface normal).
//
// Returns exactly 1.0 on total internal reflection, leaving r_cos_theta_t
// untouched -- no transmitted direction exists in that case. The `<= 0.0`
// test is deliberate and load-bearing: AT the critical angle the discriminant
// is exactly zero, and a `< 0.0` test would leak a degenerate zero-length
// transmitted direction through.
//
// CALLER CONTRACT: do not compute 1.0 / eta before this returns. ior == 0.0 is
// legal glTF (KHR_materials_ior permits it as a signal value) and Phase D
// imports it without complaint; the TIR branch handles it correctly, but an
// eagerly-evaluated reciprocal would already be an infinity.
float fresnel_dielectric(float cos_theta_i, float eta, OUT_PARAMETER(float) r_cos_theta_t) {
	float eta_cos_theta_t_sq = sqr(eta) - (1.0f - sqr(cos_theta_i));
	if (eta_cos_theta_t_sq <= 0.0f) {
		return 1.0f; // Total internal reflection.
	}
	cos_theta_i = abs(cos_theta_i);
	float cos_theta_t = -sqrt(eta_cos_theta_t_sq) / eta;
	r_cos_theta_t = cos_theta_t;

	// Amplitudes of the reflected s- and p-polarised waves.
	float r_s = (cos_theta_i + eta * cos_theta_t) / (cos_theta_i - eta * cos_theta_t);
	float r_p = (cos_theta_t + eta * cos_theta_i) / (eta * cos_theta_i - cos_theta_t);

	// Squared amplitude gives the fraction of reflected energy.
	return (sqr(r_s) + sqr(r_p)) * 0.5f;
}

// `incident` points AWAY from the surface (toward the viewer), matching V.
// `cos_theta_t` is the negative cosine returned by fresnel_dielectric.
// `inv_eta` is 1.0 / eta.
float3 refract_angle(float3 incident, float3 normal, float cos_theta_t, float inv_eta) {
	return (inv_eta * dot(normal, incident) + cos_theta_t) * normal - inv_eta * incident;
}

// F0 / IOR arbitration (roadmap E1, spec section 3.2; corrected in the E1
// final fix wave -- F1/F2/F3 below). Phase D left F0 double-specified
// between Godot's `specular` and the glTF ior / specular_factor /
// specular_tint triple; this resolves it.
//
// Structure is Cycles' (kernel/svm/closure.h:425-435), verified against that
// source directly rather than against the design spec's transcription of it,
// which dropped one statement and conflated two others:
//
//   F1. Cycles' block ends with `if (ior < 1.0f) eta = 1.0f / eta;` after
//       re-deriving eta from F0 (closure.h:432-434). ior_from_F0 always
//       returns >= 1, so for ior < 1 (authorable: material.cpp's ior hint is
//       "0,3,0.001,or_greater") the un-flipped eta lands on the wrong side
//       of 1. Restored below.
//   F2. Cycles keeps f0/eta derivation and the specular_tint completely
//       separate: `eta = ior_from_F0(f0)` uses the UNTINTED scalar `f0`
//       (closure.h:429-431), and `specular_tint` is multiplied in only
//       afterward, at closure.h:453 (`fresnel->f0 = f0 * specular_tint`),
//       where it can no longer affect eta. eta is therefore derived below
//       from the untinted scalar `f0_untinted`, never from luminance() of a
//       tinted F0.
//   F3. Cycles re-derives whenever its single `specular_ior_level` knob
//       leaves 0.5. Our engine splits that one knob into two independent
//       parameters -- Godot's native `specular` and glTF's
//       `specular_factor` -- and per spec section 3.2 (also recorded in
//       PATH_TRACER_QUALITY_ROADMAP.md's Phase E1 closeout, `specular_factor
//       -> specular_ior_level = 0.5 * specular_factor`), a non-default
//       `specular_factor` maps to a non-0.5 `specular_ior_level` exactly as
//       much as a non-default `specular` does. The gate below therefore
//       triggers on EITHER parameter leaving its default, not `specular`
//       alone -- otherwise glTF glass that varies only `specular_factor`
//       (the common case for Blender-authored/imported content) gets a
//       correct F0 and a silently un-re-derived eta, shifting its TIR/
//       refraction angle away from Cycles'. Measured magnitude at ior 1.33,
//       specular_factor 0.6 (specular left at its 0.5 default): Cycles/
//       corrected eta 1.246451 vs the previous 1.33 -- critical angle 53.4°
//       vs 48.8°, a 4.6° shift.
//
// The RESPONSE CURVE is Godot's, not Blender's: 4*specular^2 is
// specular_to_f0 (0.16*s^2) normalised against the 0.04 reference, so it is
// EXACTLY 1.0 at 0.5 and preserves Godot's shape away from it. Blender uses
// 2*level; the two agree only at 0.5 (0.08 vs 0.16 at specular = 1.0).
// specular_factor multiplies f0 directly, matching Cycles' `f0 *= 2.0f *
// specular_ior_level` under the `specular_ior_level = 0.5 * specular_factor`
// mapping (2 * 0.5 * specular_factor == specular_factor).
//
// At every default -- ior 1.5, specular 0.5, specular_factor 1.0, white tint
// -- this yields exactly float3(0.04) and eta 1.5, identical to the
// specular_to_f0(0.5) it replaces: with both knobs at default the gate below
// is false, f0_untinted == f0_scalar == F0_from_ior(1.5) == 0.04, and F0 ==
// 0.04 * float3(1,1,1) == float3(0.04). That is arithmetic, not a
// measurement, and it is why untouched materials cannot shift.
//
// SINGLE SOURCE OF TRUTH. shade_and_bounce and debug_visualize's vis modes 30
// and 31 both call this. Do not inline a second copy -- a gate that validates
// a divergent copy of the formula proves nothing about the renderer.
void resolveDielectricF0(float ior, float specular, float specular_factor, float3 specular_tint, OUT_PARAMETER(float3) F0, OUT_PARAMETER(float) eta) {
	float f0_scalar = F0_from_ior(ior);
	// UNTINTED scalar F0 (F2): specular_tint is applied only below, to F0,
	// and must never reach eta.
	float f0_untinted = f0_scalar * specular_factor;
	f0_untinted *= 4.0f * specular * specular;

	eta = ior;
	if (specular != 0.5f || specular_factor != 1.0f) { // F3: gate widened to specular_factor.
		eta = ior_from_F0(f0_untinted);
		if (ior < 1.0f) { // F1: restored ior<1 flip (closure.h:432-434).
			eta = 1.0f / eta;
		}
	}

	F0 = float3(f0_untinted, f0_untinted, f0_untinted) * specular_tint;
}

float3 baseColorToSpecularF0(float3 baseColor, float metalness, float3 dielectricF0) {
	return lerp(dielectricF0, baseColor, metalness);
}

// SINGLE SOURCE OF TRUTH for the diffuse-layer weight (fix round 1, I2/C1).
// The `transmissivness` factor mixes the diffuse layer against the base layer,
// matching Blender routing transmissionFactor into the Principled BSDF's
// transmission weight (io_scene_gltf2 .../pbrMetallicRoughness.py:281-310) --
// required for energy conservation, since that energy now goes into the
// transmitted lobe instead. Every caller (prepareBRDFData, so NEE and
// evalIndirectCombinedBRDF's diffuse sample weight; combinedPdf's lobe
// selection; shade_and_bounce's lobe selection) MUST go through this one
// function with the SAME material.transmissivness, or the estimator (what
// evalIndirectCombinedBRDF/NEE actually deliver) and the density
// (combinedPdf's pSpec, shade_and_bounce's brdfProbability) desync -- exactly
// the defect a locally-scaled copy at one call site produced originally: a
// full-strength diffuse lobe on top of the full dielectric closure, AND
// (independently) a diffuse/specular lobe-selection probability that no
// longer matches what combinedPdf reports for the same direction. Exactly
// 1.0 - metalness when transmissivness is 0.0, i.e. every non-glass material
// -- bit-identical to the pre-E1 formula.
float3 baseColorToDiffuseReflectance(float3 baseColor, float metalness, float transmissivness) {
	return baseColor * (1.0f - metalness) * (1.0f - transmissivness);
}

float none(const BrdfData data) {
	return 0.0f;
}

float3 evalVoid(const BrdfData data) {
	return float3(0.0f, 0.0f, 0.0f);
}

void evalIndirectVoid(const BrdfData data, float2 u, OUT_PARAMETER(float3) rayDirection, OUT_PARAMETER(float3) weight) {
	rayDirection = float3(0.0f, 0.0f, 1.0f);
	weight = float3(0.0f, 0.0f, 0.0f);
}

float3 sampleSpecularVoid(float3 Vlocal, float alpha, float alphaSquared, float3 specularF0, float2 u, OUT_PARAMETER(float3) weight) {
	weight = float3(0.0f, 0.0f, 0.0f);
	return float3(0.0f, 0.0f, 0.0f);
}

float3 sampleSpecularHalfVectorVoid(float3 Vlocal, float2 alpha2D, float2 u) {
	return float3(0.0f, 0.0f, 0.0f);
}

// -------------------------------------------------------------------------
//    Quaternion rotations
// -------------------------------------------------------------------------

// Calculates rotation quaternion from input vector to the vector (0, 0, 1)
// Input vector must be normalized!
float4 getRotationToZAxis(float3 v) {
	// Handle special case when v is exact or near opposite of (0, 0, 1)
	if (v.z < -0.99999f) {
		return float4(1.0f, 0.0f, 0.0f, 0.0f);
	}

	return normalize(float4(v.y, -v.x, 0.0f, 1.0f + v.z));
}

// Calculates rotation quaternion from vector (0, 0, 1) to the input vector
// Input vector must be normalized!
float4 getRotationFromZAxis(float3 v) {
	// Handle special case when v is exact or near opposite of (0, 0, 1)
	if (v.z < -0.99999f) {
		return float4(1.0f, 0.0f, 0.0f, 0.0f);
	}

	return normalize(float4(-v.y, v.x, 0.0f, 1.0f + v.z));
}

// Returns the quaternion with inverted rotation
float4 invertRotation(float4 q) {
	return float4(-q.x, -q.y, -q.z, q.w);
}

// Optimized point rotation using quaternion
// Source: https://gamedev.stackexchange.com/questions/28395/rotating-vector3-by-a-quaternion
float3 rotatePoint(float4 q, float3 v) {
	const float3 qAxis = float3(q.x, q.y, q.z);
	return 2.0f * dot(qAxis, v) * qAxis + (q.w * q.w - dot(qAxis, qAxis)) * v + 2.0f * q.w * cross(qAxis, v);
}

// -------------------------------------------------------------------------
//    Sampling
// -------------------------------------------------------------------------

// Samples a direction within a hemisphere oriented along +Z axis with a cosine-weighted distribution
// Source: "Sampling Transformations Zoo" in Ray Tracing Gems by Shirley et al.
float3 sampleHemisphere(float2 u, OUT_PARAMETER(float) pdf) {
	float a = sqrt(u.x);
	float b = TWO_PI * u.y;

	float3 result = float3(
			a * cos(b),
			a * sin(b),
			sqrt(1.0f - u.x));

	pdf = result.z * ONE_OVER_PI;

	return result;
}

float3 sampleHemisphere(float2 u) {
	float pdf;
	return sampleHemisphere(u, pdf);
}

// For sampling of all our diffuse BRDFs we use cosine-weighted hemisphere sampling, with PDF equal to (NdotL/PI)
float diffusePdf(float NdotL) {
	return NdotL * ONE_OVER_PI;
}

// -------------------------------------------------------------------------
//    Fresnel
// -------------------------------------------------------------------------

// Schlick's approximation to Fresnel term
// f90 should be 1.0, except for the trick used by Schuler (see 'shadowedF90' function)
float3 evalFresnelSchlick(float3 f0, float f90, float NdotS) {
	return f0 + (f90 - f0) * pow(1.0f - NdotS, 5.0f);
}

// Schlick's approximation to Fresnel term calculated using spherical gaussian approximation
// Source: https://seblagarde.wordpress.com/2012/06/03/spherical-gaussien-approximation-for-blinn-phong-phong-and-fresnel/ by Lagarde
float3 evalFresnelSchlickSphericalGaussian(float3 f0, float f90, float NdotV) {
	return f0 + (f90 - f0) * exp2((-5.55473f * NdotV - 6.983146f) * NdotV);
}

// Schlick's approximation to Fresnel term with Hoffman's improvement using the Lazanyi's error term
// Source: "Fresnel Equations Considered Harmful" by Hoffman
// Also see slides http://renderwonk.com/publications/mam2019/naty_mam2019.pdf for examples and explanation of f82 term
float3 evalFresnelHoffman(float3 f0, float f82, float f90, float NdotS) {
	const float alpha = 6.0f; //< Fixed to 6 in order to put peak angle for Lazanyi's error term at 82 degrees (f82)
	float3 a = 17.6513846f * (f0 - f82) + 8.166666f * (float3(1.0f, 1.0f, 1.0f) - f0);
	return saturate(f0 + (f90 - f0) * pow(1.0f - NdotS, 5.0f) - a * NdotS * pow(1.0f - NdotS, alpha));
}

float3 evalFresnel(float3 f0, float f90, float NdotS) {
	// Default is Schlick's approximation
	return evalFresnelSchlick(f0, f90, NdotS);
}

// Attenuates F90 for very low F0 values
// Source: "An efficient and Physically Plausible Real-Time Shading Model" in ShaderX7 by Schuler
// Also see section "Overbright highlights" in Hoffman's 2010 "Crafting Physically Motivated Shading Models for Game Development" for discussion
// IMPORTANT: Note that when F0 is calculated using metalness, it's value is never less than MIN_DIELECTRICS_F0, and therefore,
// this adjustment has no effect. To be effective, F0 must be authored separately, or calculated in different way. See main text for discussion.
float shadowedF90(float3 F0) {
	// This scaler value is somewhat arbitrary, Schuler used 60 in his article. In here, we derive it from MIN_DIELECTRICS_F0 so
	// that it takes effect for any reflectance lower than least reflective dielectrics
	//const float t = 60.0f;
	const float t = (1.0f / MIN_DIELECTRICS_F0);
	return min(1.0f, t * luminance(F0));
}

// -------------------------------------------------------------------------
//    Lambert
// -------------------------------------------------------------------------

float lambertian(const BrdfData data) {
	return 1.0f;
}

float3 evalLambertian(const BrdfData data) {
	return data.diffuseReflectance * (ONE_OVER_PI * data.NdotL);
}

// -------------------------------------------------------------------------
//    Phong
// -------------------------------------------------------------------------

// For derivation see "Phong Normalization Factor derivation" by Giesen
float phongNormalizationTerm(float shininess) {
	return (1.0f + shininess) * ONE_OVER_TWO_PI;
}

float3 evalPhong(const BrdfData data) {
	// First convert roughness to shininess (Phong exponent)
	float shininess = beckmannAlphaToShininess(data.alpha);

	float3 R = reflect(-data.L, data.N);
	return data.specularF0 * (phongNormalizationTerm(shininess) * pow(max(0.0f, dot(R, data.V)), shininess) * data.NdotL);
}

// Samples a Phong distribution lobe oriented along +Z axis
// Source: "Sampling Transformations Zoo" in Ray Tracing Gems by Shirley et al.
float3 samplePhong(float3 Vlocal, float shininess, float2 u, OUT_PARAMETER(float) pdf) {
	float cosTheta = pow(1.0f - u.x, 1.0f / (1.0f + shininess));
	float sinTheta = sqrt(1.0f - cosTheta * cosTheta);

	float phi = TWO_PI * u.y;

	pdf = phongNormalizationTerm(shininess) * pow(cosTheta, shininess);

	return float3(
			cos(phi) * sinTheta,
			sin(phi) * sinTheta,
			cosTheta);
}

float3 samplePhong(float3 Vlocal, float2 alpha2D, float2 u) {
	float shininess = beckmannAlphaToShininess(dot(alpha2D, float2(0.5f, 0.5f)));
	float pdf;
	return samplePhong(Vlocal, shininess, u, pdf);
}

// Sampling the specular BRDF based on Phong, includes normalization term
float3 sampleSpecularPhong(float3 Vlocal, float alpha, float alphaSquared, float3 specularF0, float2 u, OUT_PARAMETER(float3) weight) {
	// First convert roughness to shininess (Phong exponent)
	float shininess = beckmannAlphaToShininess(alpha);

	float pdf;
	float3 LPhong = samplePhong(Vlocal, shininess, u, pdf);

	// Sampled LPhong is in "lobe space" - where Phong lobe is centered around +Z axis
	// We need to rotate it in direction of perfect reflection
	float3 Nlocal = float3(0.0f, 0.0f, 1.0f);
	float3 lobeDirection = reflect(-Vlocal, Nlocal);
	float3 Llocal = rotatePoint(getRotationFromZAxis(lobeDirection), LPhong);

	// Calculate the weight of the sample
	float3 Rlocal = reflect(-Llocal, Nlocal);
	float NdotL = max(0.00001f, dot(Nlocal, Llocal));
	weight = max(float3(0.0f, 0.0f, 0.0f), specularF0 * NdotL);

	// Unoptimized formula was:
	//weight = specularF0 * (phongNormalizationTerm(shininess) * pow(max(0.0f, dot(Rlocal, Vlocal)), shininess) * NdotL) / pdf;

	return Llocal;
}

// -------------------------------------------------------------------------
//    Oren-Nayar
// -------------------------------------------------------------------------

// Based on Oren-Nayar's qualitative model
// Source: "Generalization of Lambert's Reflectance Model" by Oren & Nayar
float orenNayar(BrdfData data) {
	// Oren-Nayar roughness (sigma) is in radians - use conversion from Beckmann roughness here
	float sigma = beckmannAlphaToOrenNayarRoughness(data.alpha);

	float thetaV = acos(data.NdotV);
	float thetaL = acos(data.NdotL);

	float alpha = max(thetaV, thetaL);
	float beta = min(thetaV, thetaL);

	// Calculate cosine of azimuth angles difference - by projecting L and V onto plane defined by N. Assume L, V, N are normalized.
	float3 l = data.L - data.NdotL * data.N;
	float3 v = data.V - data.NdotV * data.N;
	float cosPhiDifference = dot(normalize(v), normalize(l));

	float sigma2 = sigma * sigma;
	float A = 1.0f - 0.5f * (sigma2 / (sigma2 + 0.33f));
	float B = 0.45f * (sigma2 / (sigma2 + 0.09f));

	return (A + B * max(0.0f, cosPhiDifference) * sin(alpha) * tan(beta));
}

float3 evalOrenNayar(const BrdfData data) {
	return data.diffuseReflectance * (orenNayar(data) * ONE_OVER_PI * data.NdotL);
}

// -------------------------------------------------------------------------
//    Disney
// -------------------------------------------------------------------------

// Disney's diffuse term
// Source "Physically-Based Shading at Disney" by Burley
float disneyDiffuse(const BrdfData data) {
	float FD90MinusOne = 2.0f * data.roughness * data.LdotH * data.LdotH - 0.5f;

	float FDL = 1.0f + (FD90MinusOne * pow(1.0f - data.NdotL, 5.0f));
	float FDV = 1.0F + (FD90MinusOne * pow(1.0f - data.NdotV, 5.0f));

	return FDL * FDV;
}

float3 evalDisneyDiffuse(const BrdfData data) {
	return data.diffuseReflectance * (disneyDiffuse(data) * ONE_OVER_PI * data.NdotL);
}

// Frostbite's version of Disney diffuse with energy normalization.
// Source: "Moving Frostbite to Physically Based Rendering" by Lagarde & de Rousiers
float frostbiteDisneyDiffuse(const BrdfData data) {
	float energyBias = 0.5f * data.roughness;
	float energyFactor = lerp(1.0f, 1.0f / 1.51f, data.roughness);

	float FD90MinusOne = energyBias + 2.0 * data.LdotH * data.LdotH * data.roughness - 1.0f;

	float FDL = 1.0f + (FD90MinusOne * pow(1.0f - data.NdotL, 5.0f));
	float FDV = 1.0f + (FD90MinusOne * pow(1.0f - data.NdotV, 5.0f));

	return FDL * FDV * energyFactor;
}

float3 evalFrostbiteDisneyDiffuse(const BrdfData data) {
	return data.diffuseReflectance * (frostbiteDisneyDiffuse(data) * ONE_OVER_PI * data.NdotL);
}

// -------------------------------------------------------------------------
//    Smith G term
// -------------------------------------------------------------------------

// Function to calculate 'a' parameter for lambda functions needed in Smith G term
// This is a version for shape invariant (isotropic) NDFs
// Note: make sure NdotS is not negative
float Smith_G_a(float alpha, float NdotS) {
	return NdotS / (max(0.00001f, alpha) * sqrt(1.0f - min(0.99999f, NdotS * NdotS)));
}

// Lambda function for Smith G term derived for GGX distribution
float Smith_G_Lambda_GGX(float a) {
	return (-1.0f + sqrt(1.0f + (1.0f / (a * a)))) * 0.5f;
}

// Lambda function for Smith G term derived for Beckmann distribution
// This is Walter's rational approximation (avoids evaluating of error function)
// Source: "Real-time Rendering", 4th edition, p.339 by Akenine-Moller et al.
// Note that this formulation is slightly optimized and different from Walter's
float Smith_G_Lambda_Beckmann_Walter(float a) {
	if (a < 1.6f) {
		return (1.0f - (1.259f - 0.396f * a) * a) / ((3.535f + 2.181f * a) * a);
		//return ((1.0f + (2.276f + 2.577f * a) * a) / ((3.535f + 2.181f * a) * a)) - 1.0f; //< Walter's original
	} else {
		return 0.0f;
	}
}

// Smith G1 term (masking function)
// This non-optimized version uses NDF specific lambda function (G_Lambda) resolved bia macro based on selected NDF
float Smith_G1_General(float a) {
	return 1.0f / (1.0f + Smith_G_Lambda(a));
}

// Smith G1 term (masking function) optimized for GGX distribution (by substituting G_Lambda_GGX into G1)
float Smith_G1_GGX(float a) {
	float a2 = a * a;
	return 2.0f / (sqrt((a2 + 1.0f) / a2) + 1.0f);
}

// Smith G1 term (masking function) further optimized for GGX distribution (by substituting G_a into G1_GGX)
float Smith_G1_GGX(float alpha, float NdotS, float alphaSquared, float NdotSSquared) {
	return 2.0f / (sqrt(((alphaSquared * (1.0f - NdotSSquared)) + NdotSSquared) / NdotSSquared) + 1.0f);
}

// Smith G1 term (masking function) optimized for Beckmann distribution (by substituting G_Lambda_Beckmann_Walter into G1)
// Source: "Microfacet Models for Refraction through Rough Surfaces" by Walter et al.
float Smith_G1_Beckmann_Walter(float a) {
	if (a < 1.6f) {
		return ((3.535f + 2.181f * a) * a) / (1.0f + (2.276f + 2.577f * a) * a);
	} else {
		return 1.0f;
	}
}

float Smith_G1_Beckmann_Walter(float alpha, float NdotS, float alphaSquared, float NdotSSquared) {
	return Smith_G1_Beckmann_Walter(Smith_G_a(alpha, NdotS));
}

// Smith G2 term (masking-shadowing function)
// Separable version assuming independent (uncorrelated) masking and shadowing, uses G1 functions for selected NDF
float Smith_G2_Separable(float alpha, float NdotL, float NdotV) {
	float aL = Smith_G_a(alpha, NdotL);
	float aV = Smith_G_a(alpha, NdotV);
	return Smith_G1(aL) * Smith_G1(aV);
}

// Smith G2 term (masking-shadowing function)
// Height correlated version - non-optimized, uses G_Lambda functions for selected NDF
float Smith_G2_Height_Correlated(float alpha, float NdotL, float NdotV) {
	float aL = Smith_G_a(alpha, NdotL);
	float aV = Smith_G_a(alpha, NdotV);
	return 1.0f / (1.0f + Smith_G_Lambda(aL) + Smith_G_Lambda(aV));
}

// Smith G2 term (masking-shadowing function) for GGX distribution
// Separable version assuming independent (uncorrelated) masking and shadowing - optimized by substituting G_Lambda for G_Lambda_GGX and
// dividing by (4 * NdotL * NdotV) to cancel out these terms in specular BRDF denominator
// Source: "Moving Frostbite to Physically Based Rendering" by Lagarde & de Rousiers
// Note that returned value is G2 / (4 * NdotL * NdotV) and therefore includes division by specular BRDF denominator
float Smith_G2_Separable_GGX_Lagarde(float alphaSquared, float NdotL, float NdotV) {
	float a = NdotV + sqrt(alphaSquared + NdotV * (NdotV - alphaSquared * NdotV));
	float b = NdotL + sqrt(alphaSquared + NdotL * (NdotL - alphaSquared * NdotL));
	return 1.0f / (a * b);
}

// Smith G2 term (masking-shadowing function) for GGX distribution
// Height correlated version - optimized by substituting G_Lambda for G_Lambda_GGX and dividing by (4 * NdotL * NdotV) to cancel out
// the terms in specular BRDF denominator
// Source: "Moving Frostbite to Physically Based Rendering" by Lagarde & de Rousiers
// Note that returned value is G2 / (4 * NdotL * NdotV) and therefore includes division by specular BRDF denominator
float Smith_G2_Height_Correlated_GGX_Lagarde(float alphaSquared, float NdotL, float NdotV) {
	float a = NdotV * sqrt(alphaSquared + NdotL * (NdotL - alphaSquared * NdotL));
	float b = NdotL * sqrt(alphaSquared + NdotV * (NdotV - alphaSquared * NdotV));
	return 0.5f / (a + b);
}

// Smith G2 term (masking-shadowing function) for GGX distribution
// Height correlated version - approximation by Hammon
// Source: "PBR Diffuse Lighting for GGX + Smith Microsurfaces", slide 84 by Hammon
// Note that returned value is G2 / (4 * NdotL * NdotV) and therefore includes division by specular BRDF denominator
float Smith_G2_Height_Correlated_GGX_Hammon(float alpha, float NdotL, float NdotV) {
	return 0.5f / (lerp(2.0f * NdotL * NdotV, NdotL + NdotV, alpha));
}

// A fraction G2/G1 where G2 is height correlated can be expressed using only G1 terms
// Source: "Implementing a Simple Anisotropic Rough Diffuse Material with Stochastic Evaluation", Appendix A by Heitz & Dupuy
float Smith_G2_Over_G1_Height_Correlated(float alpha, float alphaSquared, float NdotL, float NdotV) {
	float G1V = Smith_G1(alpha, NdotV, alphaSquared, NdotV * NdotV);
	float G1L = Smith_G1(alpha, NdotL, alphaSquared, NdotL * NdotL);
	return G1L / (G1V + G1L - G1V * G1L);
}

// Evaluates G2 for selected configuration (GGX/Beckmann, optimized/non-optimized, separable/height-correlated)
// Note that some paths aren't optimized too much...
// Also note that when USE_OPTIMIZED_G2 is specified, returned value will be: G2 / (4 * NdotL * NdotV) if GG-X is selected
float Smith_G2(float alpha, float alphaSquared, float NdotL, float NdotV) {
#if USE_OPTIMIZED_G2 && (MICROFACET_DISTRIBUTION == GGX)
#if USE_HEIGHT_CORRELATED_G2
#define G2_DIVIDED_BY_DENOMINATOR 1
	return Smith_G2_Height_Correlated_GGX_Lagarde(alphaSquared, NdotL, NdotV);
#else
#define G2_DIVIDED_BY_DENOMINATOR 1
	return Smith_G2_Separable_GGX_Lagarde(alphaSquared, NdotL, NdotV);
#endif
#else
#if USE_HEIGHT_CORRELATED_G2
	return Smith_G2_Height_Correlated(alpha, NdotL, NdotV);
#else
	return Smith_G2_Separable(alpha, NdotL, NdotV);
#endif
#endif
}

// -------------------------------------------------------------------------
//    Normal distribution functions
// -------------------------------------------------------------------------

float Beckmann_D(float alphaSquared, float NdotH) {
	float cos2Theta = NdotH * NdotH;
	float numerator = exp((cos2Theta - 1.0f) / (alphaSquared * cos2Theta));
	float denominator = PI * alphaSquared * cos2Theta * cos2Theta;
	return numerator / denominator;
}

float GGX_D(float alphaSquared, float NdotH) {
	float b = ((alphaSquared - 1.0f) * NdotH * NdotH + 1.0f);
	return alphaSquared / (PI * b * b);
}

// -------------------------------------------------------------------------
//    Anisotropic GGX (roadmap E2b)
//
// The aspect/ax/ay mapping below is shared VERBATIM with two independent
// sources, verified by reading both:
//   Blender Cycles      intern/cycles/kernel/svm/closure.h:311-313
//   this engine's raster shaders/scene_forward_lights_inc.glsl:272-274
// Adopting it therefore buys Cycles parity AND raster/RT parity from one
// formula. Unlike E1's Fresnel split, no divergence is purchased here.
// -------------------------------------------------------------------------

// SIGNED anisotropy, matching Godot's raster. Cycles saturatefs to [0,1] and
// carries the other orientation in its rotation, which is NOT equivalent: at
// anisotropy = -0.5 this gives an axis ratio of 1.450, Cycles' |a| = 0.5 plus
// 90 degrees gives 1.818. Different eccentricity, not a different orientation.
// Nothing is lost -- KHR_materials_anisotropy has no sign, so every glTF or
// Blender-imported material lands in a >= 0 where the two agree exactly.
float anisoAspect(float anisotropy) {
	// Exactly 1.0 at anisotropy 0, which is what makes ax == ay == alpha and
	// keeps untouched materials bit-identical to pre-E2b.
	return sqrt(1.0f - anisotropy * 0.9f);
}

float3 rotateAboutZ(float3 v, float phi) {
	float s = sin(phi);
	float c = cos(phi);
	return float3(c * v.x - s * v.y, s * v.x + c * v.y, v.z);
}

// Anisotropic GGX NDF. H must already be in the anisotropy-aligned frame
// (z along N, x along the rotated tangent).
float GGX_D_Aniso(float3 H, float ax, float ay) {
	float d = sqr(H.x / ax) + sqr(H.y / ay) + sqr(H.z);
	return 1.0f / (PI * ax * ay * sqr(d));
}

// Anisotropic Smith lambda, the height-correlated partner of GGX_D_Aniso.
float Smith_Lambda_Aniso(float3 V, float ax, float ay) {
	// Minor #4 hardening: clamp ax/ay the same way evalMicrofacet's own
	// anisoActive branch already does at its call sites (max(0.00001f, ...)).
	// Currently unreachable -- anisoAspect() keeps ax/ay bounded away from 0
	// for every anisotropy in [-1,1] this engine can produce -- so this is
	// hardening against a future/out-of-range caller, not a fix for a live bug.
	float axc = max(0.00001f, ax);
	float ayc = max(0.00001f, ay);
	float num = sqr(axc * V.x) + sqr(ayc * V.y);
	return (-1.0f + sqrt(1.0f + num / sqr(V.z))) * 0.5f;
}

float Smith_G2_Aniso(float3 V, float3 L, float ax, float ay) {
	return 1.0f / (1.0f + Smith_Lambda_Aniso(V, ax, ay) + Smith_Lambda_Aniso(L, ax, ay));
}

// -------------------------------------------------------------------------
//    Microfacet model
// -------------------------------------------------------------------------

// Samples a microfacet normal for the GGX distribution using VNDF method.
// Source: "Sampling the GGX Distribution of Visible Normals" by Heitz
// See also https://hal.inria.fr/hal-00996995v1/document and http://jcgt.org/published/0007/04/01/
// Random variables 'u' must be in <0;1) interval
// PDF is 'G1(NdotV) * D'
float3 sampleGGXVNDF(float3 Ve, float2 alpha2D, float2 u) {
	// Section 3.2: transforming the view direction to the hemisphere configuration
	float3 Vh = normalize(float3(alpha2D.x * Ve.x, alpha2D.y * Ve.y, Ve.z));

	// Section 4.1: orthonormal basis (with special case if cross product is zero)
	float lensq = Vh.x * Vh.x + Vh.y * Vh.y;
	float3 T1 = lensq > 0.0f ? float3(-Vh.y, Vh.x, 0.0f) * rsqrt(lensq) : float3(1.0f, 0.0f, 0.0f);
	float3 T2 = cross(Vh, T1);

	// Section 4.2: parameterization of the projected area
	float r = sqrt(u.x);
	float phi = TWO_PI * u.y;
	float t1 = r * cos(phi);
	float t2 = r * sin(phi);
	float s = 0.5f * (1.0f + Vh.z);
	t2 = lerp(sqrt(1.0f - t1 * t1), t2, s);

	// Section 4.3: reprojection onto hemisphere
	float3 Nh = t1 * T1 + t2 * T2 + sqrt(max(0.0f, 1.0f - t1 * t1 - t2 * t2)) * Vh;

	// Section 3.4: transforming the normal back to the ellipsoid configuration
	return normalize(float3(alpha2D.x * Nh.x, alpha2D.y * Nh.y, max(0.0f, Nh.z)));
}

// PDF of sampling a reflection vector L using 'sampleGGXVNDF'.
// Note that PDF of sampling given microfacet normal is (G1 * D) when vectors are in local space (in the hemisphere around shading normal).
// Remaining terms (1.0f / (4.0f * NdotV)) are specific for reflection case, and come from multiplying PDF by jacobian of reflection operator
float sampleGGXVNDFReflectionPdf(float alpha, float alphaSquared, float NdotH, float NdotV, float LdotH) {
	NdotH = max(0.00001f, NdotH);
	NdotV = max(0.00001f, NdotV);
	return (GGX_D(max(0.00001f, alphaSquared), NdotH) * Smith_G1_GGX(alpha, NdotV, alphaSquared, NdotV * NdotV)) / (4.0f * NdotV);
}

// Anisotropic partner of sampleGGXVNDFReflectionPdf. MUST stay in lockstep with
// the sampler: V, L and H are rotated by -anisoPhi by the CALLER, so this
// function sees them already in the anisotropy frame.
//
// A pdf that disagrees with the sampler is the B2 defect class -- two
// strategies estimating different integrands, which MIS cannot repair and
// which is MEAN-PRESERVING, so no rendered image at any sample count reveals
// it. Vis mode 35 exists to catch exactly this.
float sampleGGXVNDFReflectionPdfAniso(float3 Vaniso, float3 Haniso, float ax, float ay, float VdotH) {
	// Minor #4 hardening: same rationale as Smith_Lambda_Aniso's own clamp --
	// GGX_D_Aniso divides by ax/ay directly and is otherwise unguarded here.
	float axc = max(0.00001f, ax);
	float ayc = max(0.00001f, ay);
	float G1 = 1.0f / (1.0f + Smith_Lambda_Aniso(Vaniso, axc, ayc));
	float D = GGX_D_Aniso(Haniso, axc, ayc);
	return D * G1 * max(0.0f, VdotH) / max(0.00001f, Vaniso.z) / (4.0f * max(0.00001f, VdotH));
}

// "Walter's trick" is an adjustment of alpha value for Walter's sampling to reduce maximal weight of sample to about 4
// Source: "Microfacet Models for Refraction through Rough Surfaces" by Walter et al., page 8
float waltersTrick(float alpha, float NdotV) {
	return (1.2f - 0.2f * sqrt(abs(NdotV))) * alpha;
}

// PDF of sampling a reflection vector L using 'sampleBeckmannWalter'.
// Note that PDF of sampling given microfacet normal is (D * NdotH). Remaining terms (1.0f / (4.0f * LdotH)) are specific for
// reflection case, and come from multiplying PDF by jacobian of reflection operator
float sampleBeckmannWalterReflectionPdf(float alpha, float alphaSquared, float NdotH, float NdotV, float LdotH) {
	NdotH = max(0.00001f, NdotH);
	LdotH = max(0.00001f, LdotH);
	return Beckmann_D(max(0.00001f, alphaSquared), NdotH) * NdotH / (4.0f * LdotH);
}

// Samples a microfacet normal for the Beckmann distribution using walter's method.
// Source: "Microfacet Models for Refraction through Rough Surfaces" by Walter et al.
// PDF is 'D * NdotH'
float3 sampleBeckmannWalter(float3 Vlocal, float2 alpha2D, float2 u) {
	float alpha = dot(alpha2D, float2(0.5f, 0.5f));

	// Equations (28) and (29) from Walter's paper for Beckmann distribution
	float tanThetaSquared = -(alpha * alpha) * log(1.0f - u.x);
	float phi = TWO_PI * u.y;

	// Calculate cosTheta and sinTheta needed for conversion to H vector
	float cosTheta = rsqrt(1.0f + tanThetaSquared);
	float sinTheta = sqrt(1.0f - cosTheta * cosTheta);

	// Convert sampled spherical coordinates to H vector
	return normalize(float3(sinTheta * cos(phi), sinTheta * sin(phi), cosTheta));
}

// Weight for the reflection ray sampled from GGX distribution using VNDF method
float specularSampleWeightGGXVNDF(float alpha, float alphaSquared, float NdotL, float NdotV, float HdotL, float NdotH) {
#if USE_HEIGHT_CORRELATED_G2
	return Smith_G2_Over_G1_Height_Correlated(alpha, alphaSquared, NdotL, NdotV);
#else
	return Smith_G1_GGX(alpha, NdotL, alphaSquared, NdotL * NdotL);
#endif
}

// I1 fix (Task 3 review, Important). Anisotropic partner of
// specularSampleWeightGGXVNDF, computed the same way sampleGGXVNDFReflectionPdfAniso
// is: Vaniso/Laniso are already rotated by -anisoPhi by the CALLER, into the
// SAME frame the direction was drawn in by sampleSpecularHalfVector(Vaniso,
// (ax,ay), u). Before this fix, every anisotropic-sampled direction was
// weighted by the ISOTROPIC ratio (Smith_G2_Over_G1_Height_Correlated) even
// though the direction itself came from the anisotropic VNDF -- a visible bias
// that (combined with C1) made the BSDF-sampled and light-sampled estimators
// of the same surface disagree, biasing the MIS partition rather than merely
// approximating it.
float specularSampleWeightGGXVNDFAniso(float3 Vaniso, float3 Laniso, float ax, float ay) {
	// Minor #4 hardening: same rationale as Smith_Lambda_Aniso's own clamp.
	float axc = max(0.00001f, ax);
	float ayc = max(0.00001f, ay);
	float G1 = 1.0f / (1.0f + Smith_Lambda_Aniso(Vaniso, axc, ayc));
	float G2 = Smith_G2_Aniso(Vaniso, Laniso, axc, ayc);
	return G2 / G1;
}

// Weight for the reflection ray sampled from Beckmann distribution using Walter's method
float specularSampleWeightBeckmannWalter(float alpha, float alphaSquared, float NdotL, float NdotV, float HdotL, float NdotH) {
	return (HdotL * Smith_G2(alpha, alphaSquared, NdotL, NdotV)) / (NdotV * NdotH);
}

// Multiple scattering compensation approximations for GGX
// Ems = (1-Ess) / Ess
float evalEmsApprox(float r2, float NdV) {
	float r4 = r2 * r2;
	float nv0 = 0.2 * r2;
	float nv1 = 0.32 * r2 + 1.94 * r4;
	return lerp(nv0, nv1, NdV);
}

float3 evalMultiScatterApproximation(float alpha, float NdV, float3 F0) {
	float Ems = evalEmsApprox(alpha, NdV);
	return 1.0 + F0 * Ems;
}

// Samples a reflection ray from the rough surface using selected microfacet distribution and sampling method
// Resulting weight includes multiplication by cosine (NdotL) term
//
// E2b: ax/ay/anisoPhi come straight from BrdfData (prepareBRDFData). At
// anisotropy == 0 (or no usable tangent) ax == ay == alpha and anisoPhi == 0,
// so rotateAboutZ is the identity and the SAMPLING half of this call reduces
// EXACTLY to the pre-E2b isotropic one -- see brdf_inc.glsl Task 3 Step 2. The
// WEIGHT half, below, DOES need an anisoActive branch (I1 fix, Task 3 review) --
// see specularSampleWeightGGXVNDFAniso's doc comment.
float3 sampleSpecularMicrofacet(float3 Vlocal, float alpha, float alphaSquared, float3 specularF0, float ax, float ay, float anisoPhi, bool anisoActive, float2 u, OUT_PARAMETER(float3) weight) {
	// Sample a microfacet normal (H) in local space
	float3 Hlocal;
	if (alpha == 0.0f) {
		// Fast path for zero roughness (perfect reflection), also prevents NaNs appearing due to divisions by zeroes
		Hlocal = float3(0.0f, 0.0f, 1.0f);
	} else if (anisoActive) {
		// Rotate into the anisotropy frame, sample with the elliptical
		// roughnesses, rotate the result back out.
		float3 Vaniso = rotateAboutZ(Vlocal, -anisoPhi);
		float3 Haniso = sampleSpecularHalfVector(Vaniso, float2(ax, ay), u);
		Hlocal = rotateAboutZ(Haniso, anisoPhi);
	} else {
		// Fix round (Minor #2): previously this branch always ran the
		// rotate -> sample -> rotate-back path and relied on ax==ay==alpha
		// and sin(-0)/cos(-0) algebra to reduce to the pre-E2b call. GLSL
		// only guarantees 2^-11 absolute error on sin/cos, so that was
		// bit-identity by algebra, not by construction. Calling the sampler
		// directly with no rotation makes the isotropic path structurally
		// identical to pre-E2b again.
		Hlocal = sampleSpecularHalfVector(Vlocal, float2(alpha, alpha), u);
	}

	// Reflect view direction to obtain light vector
	float3 Llocal = reflect(-Vlocal, Hlocal);

	// Note: HdotL is same as HdotV here
	// Clamp dot products here to small value to prevent numerical instability. Assume that rays incident from below the hemisphere have been filtered
	float HdotL = max(0.00001f, min(1.0f, dot(Hlocal, Llocal)));
	const float3 Nlocal = float3(0.0f, 0.0f, 1.0f);
	float NdotL = max(0.00001f, min(1.0f, dot(Nlocal, Llocal)));
	float NdotV = max(0.00001f, min(1.0f, dot(Nlocal, Vlocal)));
	float NdotH = max(0.00001f, min(1.0f, dot(Nlocal, Hlocal)));
	float3 F = evalFresnel(specularF0, shadowedF90(specularF0), HdotL);

#if MICROFACET_DISTRIBUTION == GGX
	float3 ms = evalMultiScatterApproximation(alpha, NdotV, specularF0);
#else
	float3 ms = vec3(1.0f, 1.0f, 1.0f);
#endif

	// Calculate weight of the sample specific for selected sampling method
	// (this is microfacet BRDF divided by PDF of sampling method - notice how most terms cancel out)
	//
	// I1 fix (Task 3 review, Important): this used to call the SCALAR
	// isotropic G2/G1 ratio unconditionally, even when Hlocal above was drawn
	// from the ANISOTROPIC VNDF (ax != ay). Gated on anisoActive so the
	// isotropic path (ax == ay == alpha, anisoPhi == 0) stays bit-identical to
	// pre-E2b -- exactly the same shape as evalMicrofacet's D/G2 branch.
	float weightRatio;
	if (anisoActive) {
		float3 Vaniso = rotateAboutZ(Vlocal, -anisoPhi);
		float3 Laniso = rotateAboutZ(Llocal, -anisoPhi);
		weightRatio = specularSampleWeightGGXVNDFAniso(Vaniso, Laniso, ax, ay);
	} else {
		weightRatio = specularSampleWeight(alpha, alphaSquared, NdotL, NdotV, HdotL, NdotH);
	}
	weight = ms * F * weightRatio;

	return Llocal;
}

// Fresnel-weighted reflect-vs-transmit split for a dielectric microfacet.
// Ported from Cycles bsdf_microfacet.h:844-851 and :299-305.
//
// SINGLE SOURCE OF TRUTH for the split. sampleDielectricMicrofacet uses it to
// CHOOSE a lobe; combinedPdf uses it to report that choice's DENSITY. Two
// copies that disagree would make every MIS weight on a transmissive surface
// describe a different integrand than the estimator evaluates. Do not inline
// a second copy.
//
// Returns pdf_reflect. Writes the remapped per-channel reflectance, the
// per-channel transmittance (Cycles bsdf_microfacet.h:329: 1 - remapped F,
// tinted, NOT the raw Fresnel -- so a tinted dielectric conserves energy and
// the transmitted lobe can carry colour), and the cosine of the transmitted
// angle (only meaningful when the return value is below 1.0 -- under TIR no
// transmitted direction exists and cos_theta_t is left untouched).
float dielectricFresnelSplit(float HdotV, float eta, float3 F0, float transmission, OUT_PARAMETER(float3) reflectance, OUT_PARAMETER(float3) transmittance, OUT_PARAMETER(float) cos_theta_t) {
	float F_real = fresnel_dielectric(HdotV, eta, cos_theta_t);

	// Remap the real Fresnel curve onto the tinted [F0, 1] range -- Cycles'
	// generalized-Schlick "exponent < 0" branch (bsdf_microfacet.h:299-305).
	// This is how a tinted F0 (from specular_tint) coexists with a real Fresnel
	// term that TIR depends on: plain Schlick cannot express TIR, and plain
	// real Fresnel cannot carry the tint.
	float F0_real = F0_from_ior(eta);
	float s = saturate((F_real - F0_real) / max(1.0f - F0_real, 0.00001f));
	reflectance = lerp(F0, float3(1.0f, 1.0f, 1.0f), s);
	// Per-channel and derived from the REMAPPED (tinted) reflectance, not the
	// raw Fresnel -- bsdf_microfacet.h:329. reflectance + transmittance == 1
	// per channel this way, which is what makes tinted glass energy-conserving
	// and lets the transmitted lobe carry the tint through the surface, not
	// just reflect it.
	transmittance = (float3(1.0f, 1.0f, 1.0f) - reflectance) * transmission;

	float avg_reflectance = dot(reflectance, float3(1.0f, 1.0f, 1.0f)) / 3.0f;
	float avg_transmittance = dot(transmittance, float3(1.0f, 1.0f, 1.0f)) / 3.0f;
	float denom = avg_reflectance + avg_transmittance;

	// The guard is LOAD-BEARING, not defensive. At eta == 1.0 with
	// transmission == 0, F_real is 0, reflectance is F0 == 0, transmittance is
	// 0, and the unguarded ratio is 0/0. sanitize_payload_value would silently
	// zero the resulting NaN and poison the pixel with no failing test. Falling
	// back to 1.0 routes the degenerate case down the reflective branch with a
	// zero weight, terminating the path cleanly.
	return (denom > 0.0f) ? (avg_reflectance / denom) : 1.0f;
}

// Dielectric microfacet closure: reflection AND transmission as one closure
// that splits internally on a Fresnel-weighted probability. Structure ported
// from Cycles bsdf_microfacet_sample (bsdf_microfacet.h:844-914).
//
// CALLED ONLY WHEN transmission > 0. An opaque material takes
// sampleSpecularMicrofacet above, unchanged. That dispatch is deliberate and
// load-bearing: the Fresnel remap below is NOT equal to that function's Schlick
// evalFresnel, so routing everything through here would change the reflectance
// of every specular surface in every existing scene. See spec section 4.2.
//
// Returns false when no usable direction was produced (TIR with no reflective
// energy, or a degenerate half-vector). Resulting weight includes the cosine
// term, matching sampleSpecularMicrofacet's convention.
// E2b: ax/ay/anisoPhi thread through to the half-vector sample exactly as in
// sampleSpecularMicrofacet above -- same identity-at-default reasoning, no
// anisoActive branch needed for the SAMPLING step itself. The WEIGHT
// computations below DO need one (I1 fix, Task 3 review) -- same reasoning as
// sampleSpecularMicrofacet's own weight branch.
bool sampleDielectricMicrofacet(float3 Vlocal, float alpha, float alphaSquared, float3 F0, float eta, float transmission, float ax, float ay, float anisoPhi, bool anisoActive, float3 u, OUT_PARAMETER(float3) Llocal, OUT_PARAMETER(float3) weight, OUT_PARAMETER(bool) isTransmit) {
	const float3 Nlocal = float3(0.0f, 0.0f, 1.0f);

	float3 Hlocal;
	if (alpha == 0.0f) {
		// Fast path for zero roughness, and it also prevents the NaNs a
		// division by zero would produce inside VNDF sampling.
		Hlocal = float3(0.0f, 0.0f, 1.0f);
	} else if (anisoActive) {
		float3 Vaniso = rotateAboutZ(Vlocal, -anisoPhi);
		float3 Haniso = sampleSpecularHalfVector(Vaniso, float2(ax, ay), u.xy);
		Hlocal = rotateAboutZ(Haniso, anisoPhi);
	} else {
		// Fix round (Minor #2): same structural fix as sampleSpecularMicrofacet
		// above -- no rotation on the isotropic path, not an algebraic no-op.
		Hlocal = sampleSpecularHalfVector(Vlocal, float2(alpha, alpha), u.xy);
	}

	float HdotV = dot(Hlocal, Vlocal);

	// cos_theta_t is only written when a transmitted direction exists; under
	// TIR the helper returns 1.0 and leaves it alone.
	float cos_theta_t = 0.0f;
	float3 reflectance;
	float3 transmittance;
	float pdf_reflect = dielectricFresnelSplit(HdotV, eta, F0, transmission,
			reflectance, transmittance, cos_theta_t);

	isTransmit = (u.z >= pdf_reflect);

	if (isTransmit) {
		// TIR returned F_real == 1.0, so transmittance is 0 and pdf_reflect is 1;
		// u.z < 1.0 always (rng_1d's divisor is 2^32 + 512), so this branch is
		// unreachable under TIR and cos_theta_t is guaranteed to have been written.
		Llocal = refract_angle(Vlocal, Hlocal, cos_theta_t, 1.0f / eta);
		float denom_t = 1.0f - pdf_reflect;
		if (denom_t <= 0.0f) {
			return false;
		}
		float NdotL = min(-0.00001f, dot(Nlocal, Llocal));
		float NdotV = max(0.00001f, min(1.0f, dot(Nlocal, Vlocal)));
		float NdotH = max(0.00001f, min(1.0f, dot(Nlocal, Hlocal)));
		float HdotL = max(0.00001f, min(1.0f, abs(dot(Hlocal, Llocal))));
		// NOTE: no evalMultiScatterApproximation here. It is derived for
		// reflection-only GGX and applying it to the transmitted lobe would add
		// energy its derivation does not cover, so this lobe is single-scatter
		// and slightly dark at high roughness. Cycles has the same limitation.
		// transmittance is per-channel (bsdf_microfacet.h:329), so a tinted
		// dielectric's transmitted lobe carries colour, not just its reflection.
		// I1 fix: anisoActive branch mirrors sampleSpecularMicrofacet's own
		// weight fix. Laniso.z is negative here (transmitted, below-hemisphere
		// local direction) but Smith_Lambda_Aniso only ever consumes V.z
		// squared, so it naturally matches the abs(NdotL) the isotropic branch
		// takes explicitly -- no extra sign-handling needed.
		float weightRatioT;
		if (anisoActive) {
			float3 VanisoT = rotateAboutZ(Vlocal, -anisoPhi);
			float3 LanisoT = rotateAboutZ(Llocal, -anisoPhi);
			weightRatioT = specularSampleWeightGGXVNDFAniso(VanisoT, LanisoT, ax, ay);
		} else {
			weightRatioT = specularSampleWeight(alpha, alphaSquared, abs(NdotL), NdotV, HdotL, NdotH);
		}
		weight = transmittance / denom_t * weightRatioT;
	} else {
		Llocal = reflect(-Vlocal, Hlocal);
		float HdotL = max(0.00001f, min(1.0f, dot(Hlocal, Llocal)));
		float NdotL = max(0.00001f, min(1.0f, dot(Nlocal, Llocal)));
		float NdotV = max(0.00001f, min(1.0f, dot(Nlocal, Vlocal)));
		float NdotH = max(0.00001f, min(1.0f, dot(Nlocal, Hlocal)));
#if MICROFACET_DISTRIBUTION == GGX
		float3 ms = evalMultiScatterApproximation(alpha, NdotV, F0);
#else
		float3 ms = float3(1.0f, 1.0f, 1.0f);
#endif
		// I1 fix: same anisoActive branch as the transmit case above.
		float weightRatioR;
		if (anisoActive) {
			float3 VanisoR = rotateAboutZ(Vlocal, -anisoPhi);
			float3 LanisoR = rotateAboutZ(Llocal, -anisoPhi);
			weightRatioR = specularSampleWeightGGXVNDFAniso(VanisoR, LanisoR, ax, ay);
		} else {
			weightRatioR = specularSampleWeight(alpha, alphaSquared, NdotL, NdotV, HdotL, NdotH);
		}
		weight = ms * (reflectance / pdf_reflect) * weightRatioR;
	}

	return true;
}

// World-space wrapper around sampleDielectricMicrofacet that ALSO applies
// Cycles' hemisphere-consistency rejection (bsdf_microfacet.h:864) and the
// thin-walled straight-through override, IN THAT ORDER. Extracted (fix round
// 2) so a debug vis mode can exercise the EXACT production ordering instead
// of a re-inlined copy that could silently drift from it -- see
// RT_DEBUG_GUARD_FIRING_RATE (raytracing_closest_hit_common_inc.glsl).
//
// Order is load-bearing (fix round 1, I1): geometry_normal is always flipped
// toward V (compute_hit_data), so dot(-V, geometry_normal) < 0 and
// dot(-V, N) < 0 are unconditionally true -- computing the hemisphere check
// AFTER the thin-walled override replaces next_dir with -V makes both
// comparisons vacuously equal to `isTransmit == true` every time, silently
// disabling the guard in thin-walled mode, exactly where VNDF can produce a
// wrong-side sample at high roughness. This function computes the check
// against the RAW sampled direction first, then applies the override.
//
// Returns false only if sampleDielectricMicrofacet itself failed (e.g. TIR
// with no reflective energy) -- r_next_dir/r_weight/r_is_transmit are
// undefined in that case, matching the underlying function's contract.
// r_wrong_hemisphere reports whether the hemisphere-consistency guard
// rejected the RAW (pre-override) sample; the caller must treat that as
// "this sample must be discarded" the same way the guard's callers always
// have. Does NOT report false through the boolean return for a
// wrong-hemisphere sample -- the caller decides how to treat r_wrong_hemisphere,
// matching shade_and_bounce's own `transmissive_sample_ok = false` handling.
// E2b: ax/ay/anisoPhi (from prepareBRDFData, same tangent-projection formula
// every other consumer uses) pass straight through to sampleDielectricMicrofacet.
// anisoActive (I1 fix, Task 3 review) passes through the same way, gating that
// function's sample-weight computation.
bool sampleTransmissiveLobe(float3 V, float3 N, float3 geometry_normal, float alpha, float alphaSquared,
		float3 specularF0, float eta, float transmissivness, bool thin_walled, float ax, float ay, float anisoPhi, bool anisoActive, float3 u3,
		OUT_PARAMETER(float3) r_next_dir, OUT_PARAMETER(float3) r_weight, OUT_PARAMETER(bool) r_is_transmit,
		OUT_PARAMETER(bool) r_wrong_hemisphere) {
	float4 qRotationToZ = getRotationToZAxis(N);
	float3 Vlocal = rotatePoint(qRotationToZ, V);
	float3 Llocal;
	r_wrong_hemisphere = false;
	// r_weight and r_is_transmit are written DIRECTLY from
	// sampleDielectricMicrofacet's own out-parameters into this function's
	// out-parameters, rather than through an intermediate local. An earlier
	// version of this extraction routed them through locals first and
	// produced a live regression on the transmissive path (fix round 2
	// self-review: the tree was 42/42 green before this extraction and
	// failed only on the real transmission gate, nothing else); switching to
	// the direct-write form here made the regression go away.
	//
	// Fix round 3 correction: an earlier draft of this comment stated the
	// two-level out-parameter chain itself AS THE CAUSE. That claim does not
	// hold up -- this same function still routes r_next_dir through an
	// intermediate local (Llocal, right below) because it needs the
	// rotate-back transform applied first, and that path works correctly.
	// The direct-write pattern used here is also not a new invention: it is
	// the same shape evalIndirectCombinedBRDF already uses when it passes
	// its own out-parameter `sampleWeight` straight into sampleSpecular(...)
	// with no intermediate local (see this file, SPECULAR_TYPE branch). So
	// "avoid chained out-parameters" is not a general rule this codebase
	// follows, and this comment should not be read as prescribing one --
	// only r_weight/r_is_transmit needed the direct-write change to fix the
	// regression; r_next_dir did not. What actually broke is not fully
	// pinned down: an equally plausible alternative hypothesis is that the
	// pre-fix local-routed version lost the isTransmit boolean's propagation
	// along the way (isTransmit gates the thin-walled override just below,
	// so a stale or wrong value there would misfire exactly this path). The
	// durable lesson is the one worth keeping: doctest, every existing gate,
	// and the validation mean all passed through this regression untouched
	// -- only this gate's probe 6 caught it, because it was the only check
	// exercising the transmissive lobe's rendered output directly.
	if (!sampleDielectricMicrofacet(Vlocal, alpha, alphaSquared, specularF0, eta, transmissivness, ax, ay, anisoPhi, anisoActive, u3, Llocal, r_weight, r_is_transmit)) {
		return false;
	}

	float3 next_dir = normalize(rotatePoint(invertRotation(qRotationToZ), Llocal));

	bool wrongNg = (dot(next_dir, geometry_normal) < 0.0f) != r_is_transmit;
	bool wrongN = (dot(next_dir, N) < 0.0f) != r_is_transmit;
	r_wrong_hemisphere = wrongNg || wrongN;

	if (r_is_transmit && thin_walled) {
		// Thin-walled: glTF says thicknessFactor == 0 is an infinitesimally
		// thin surface and no refraction bend applies. The ray continues
		// straight and no medium is entered, so single-sided window panes
		// and foliage cards work without any back-face hit.
		next_dir = -V;
	}
	r_next_dir = next_dir;
	return true;
}

// Evaluates microfacet specular BRDF
//
// E2b, Task 3 Step 4. The anisotropic branch below deviates from the plan's
// literal snippet, which rotates data.H/V/L by -data.anisoPhi directly. That
// is only correct if data.H/V/L are already expressed in the LOCAL frame
// (N -> +Z) that anisoPhi was measured in (prepareBRDFData derives anisoPhi
// from rotatePoint(getRotationToZAxis(N), tangent)). evalMicrofacet's only
// real caller is evalCombinedBRDFSeparate, invoked with WORLD-SPACE N/L/V from
// raytracing_lights_inc.glsl (analytic NEE), raytracing_emissive_inc.glsl
// (emissive NEE) and the env-NEE site in raytracing_closest_hit_common_inc.glsl
// -- so data.H/V/L here are world-space vectors, and rotateAboutZ'ing them
// directly would spin around the WORLD Z axis, unrelated to the surface's
// local tangent frame: the anisotropy axis would come out wrong for every
// normal not already aligned with world Z. Transforming through
// getRotationToZAxis(data.N) first (the SAME rotation prepareBRDFData applied
// to the tangent) is what makes Ha/Va/La comparable to anisoPhi at all.
float3 evalMicrofacet(const BrdfData data) {
	float D, G2;
	if (data.anisoActive) {
		float4 qToZ = getRotationToZAxis(data.N);
		float3 Hlocal = rotatePoint(qToZ, data.H);
		float3 Vlocal = rotatePoint(qToZ, data.V);
		float3 Llocal = rotatePoint(qToZ, data.L);
		float3 Ha = rotateAboutZ(Hlocal, -data.anisoPhi);
		float3 Va = rotateAboutZ(Vlocal, -data.anisoPhi);
		float3 La = rotateAboutZ(Llocal, -data.anisoPhi);
		D = GGX_D_Aniso(Ha, max(0.00001f, data.ax), max(0.00001f, data.ay));
		G2 = Smith_G2_Aniso(Va, La, max(0.00001f, data.ax), max(0.00001f, data.ay));
		// C1 fix (Task 3 review, Critical): Smith_G2_Aniso returns PLAIN G2, but
		// this function's isotropic branch below returns G2 / (4*NdotL*NdotV) --
		// see Smith_G2_Height_Correlated_GGX_Lagarde's own doc comment at :917
		// ("returned value is G2 / (4 * NdotL * NdotV)") and the resulting
		// #define G2_DIVIDED_BY_DENOMINATOR 1 at :946, which is why the return
		// statement below performs NO further division. Left undivided, the
		// anisotropic branch was up to 4x too bright at normal incidence and
		// ~0.36x too dim at grazing (NdotL == NdotV == 0.3), and the BSDF-sampled
		// estimator (specularSampleWeight, unaffected) would disagree with this
		// evaluation -- a biased MIS partition, not merely an approximation.
		// Clamped NdotL/NdotV mirror how the isotropic path protects itself.
#if G2_DIVIDED_BY_DENOMINATOR
		G2 /= 4.0f * max(0.00001f, data.NdotL) * max(0.00001f, data.NdotV);
#endif
	} else {
		D = Microfacet_D(max(0.00001f, data.alphaSquared), data.NdotH);
		G2 = Smith_G2(data.alpha, data.alphaSquared, data.NdotL, data.NdotV);
	}
	//float3 F = evalFresnel(data.specularF0, shadowedF90(data.specularF0), data.VdotH); //< Unused, F is precomputed already

#if G2_DIVIDED_BY_DENOMINATOR
	return data.F * (G2 * D * data.NdotL);
#else
	return ((data.F * G2 * D) / (4.0f * data.NdotL * data.NdotV)) * data.NdotL;
#endif
}

// -------------------------------------------------------------------------
//    Shading normal clamping
// -------------------------------------------------------------------------

// Clamps a shading normal toward the geometry normal at grazing view angles.
// This addresses a Monte-Carlo path tracing failure mode: when a strong normal
// map perturbs the shading normal far from the geometry normal and the view
// direction grazes the surface, importance-sampled reflection directions
// frequently land below the geometry hemisphere. Such samples must be
// discarded (they would self-intersect the surface), terminating the path
// before it can collect any environment contribution and producing speckled
// black pixels. The classic example is water with high-frequency wave normals
// viewed at distance.
//
// The clamp is a smooth lerp between the shading and geometry normals based
// on the geometry NdotV. Above 'threshold' the shading normal is unchanged.
// Below it, the lerp factor falls linearly to 0 at NdotV == 0 (full geometry
// normal). 'threshold' should be small (e.g. 0.10..0.20); higher values flatten
// detail at glancing angles unnecessarily, lower values still allow rejection
// black pixels for very aggressive normal maps.
//
// The same clamped normal must be used for *all* BRDF math (sampling, eval,
// direct light NEE, denoiser G-buffers) so the indirect lobe and direct
// lighting agree.
float3 clampShadingNormal(float3 shading_n, float3 geometry_n, float3 V, float threshold) {
#if RT_SHADING_NORMAL_CLAMP_ENABLED
	float NdotV_geo = dot(geometry_n, V);
	if (NdotV_geo >= threshold) {
		return shading_n;
	}
	float t = max(0.0f, NdotV_geo) * rcp(max(0.0001f, threshold));
	return normalize(lerp(geometry_n, shading_n, t));
#else
	return shading_n;
#endif
}

// -------------------------------------------------------------------------
//    Below-hemisphere sample recovery
// -------------------------------------------------------------------------
//
// When BRDF importance sampling against a strongly perturbed shading normal
// produces a direction that lands below the geometry plane, the direction
// would self-intersect the surface and cannot be traced as-is.
//
// Recovery strategy: mirror the rejected direction across the geometry plane
// and reuse the original BRDF weight. Cheap, never produces black pixels,
// but is energy-non-conserving (over-bright at grazing angles) -- a
// deliberate trade-off vs. terminating the path.
//
// Set RT_BELOW_HEMISPHERE_RECOVERY_ENABLED to 0 to disable recovery and
// terminate the path on rejection instead. Useful for A/B comparison or
// when investigating energy conservation.

// Mirrors a direction across the geometry plane. No-op if already above.
float3 mirrorDirectionAcrossPlane(float3 dir, float3 geometry_n) {
	float c = dot(dir, geometry_n);
	if (c >= 0.0f) {
		return dir;
	}
	return normalize(dir - 2.0f * c * geometry_n);
}

// Recover a BRDF sample that landed below the geometry plane.
// Returns true and writes the recovered (above-plane) direction to
// 'recovered_dir' when recovery is enabled. Returns false when recovery is
// disabled at compile time (RT_BELOW_HEMISPHERE_RECOVERY_ENABLED == 0); the
// caller should then terminate the path.
bool recoverBelowHemisphereSample(
		float3 rejected_dir,
		float3 geometry_n,
		OUT_PARAMETER(float3) recovered_dir) {
#if RT_BELOW_HEMISPHERE_RECOVERY_ENABLED
	recovered_dir = mirrorDirectionAcrossPlane(rejected_dir, geometry_n);
	return true;
#else
	recovered_dir = rejected_dir;
	return false;
#endif
}

// -------------------------------------------------------------------------
//    Combined BRDF
// -------------------------------------------------------------------------

// Precalculates commonly used terms in BRDF evaluation
// Clamps around dot products prevent NaNs and ensure numerical stability, but make sure to
// correctly ignore rays outside of the sampling hemisphere, by using 'Vbackfacing' and 'Lbackfacing' flags
BrdfData prepareBRDFData(float3 N, float3 L, float3 V, MaterialProperties material) {
	BrdfData data;

	// Evaluate VNHL vectors
	data.V = V;
	data.N = N;
	data.H = normalize(L + V);
	data.L = L;

	float NdotL = dot(N, L);
	float NdotV = dot(N, V);
	data.Vbackfacing = (NdotV <= 0.0f);
	data.Lbackfacing = (NdotL <= 0.0f);

	// Clamp NdotS to prevent numerical instability. Assume vectors below the hemisphere will be filtered using 'Vbackfacing' and 'Lbackfacing' flags
	data.NdotL = min(max(0.00001f, NdotL), 1.0f);
	data.NdotV = min(max(0.00001f, NdotV), 1.0f);

	data.LdotH = saturate(dot(L, data.H));
	data.NdotH = saturate(dot(N, data.H));
	data.VdotH = saturate(dot(V, data.H));

	// Unpack material properties
	data.specularF0 = baseColorToSpecularF0(material.baseColor, material.metalness, material.dielectricF0);
	data.diffuseReflectance = baseColorToDiffuseReflectance(material.baseColor, material.metalness, material.transmissivness);

	// Unpack 'perceptively linear' -> 'linear' -> 'squared' roughness
	data.roughness = material.roughness;
	data.alpha = material.roughness * material.roughness;
	data.alphaSquared = data.alpha * data.alpha;

	// E2b: elliptical roughness and the anisotropy azimuth.
	//
	// Defaults are the exact isotropic values, so a material with anisotropy 0
	// or no usable tangent is bit-identical to pre-E2b: anisoAspect(0) is
	// exactly 1.0, so ax == ay == alpha.
	data.ax = data.alpha;
	data.ay = data.alpha;
	data.anisoPhi = 0.0f;
	data.anisoActive = false;

	float tangentLen = length(material.tangent);
	if (material.anisotropy != 0.0f && tangentLen > 1e-6f) {
		// Project the tangent into the local frame and take its azimuth there.
		// getRotationToZAxis(N) sends N to +Z but leaves X arbitrary, so the
		// azimuth must be measured, not assumed. Computed BEFORE deciding
		// anisoActive (Minor #3 fix, below) because the activation guard now
		// depends on it.
		float4 qToZ = getRotationToZAxis(N);
		float3 Tlocal = rotatePoint(qToZ, material.tangent / tangentLen);

		// Minor #3 fix: tangentLen > 1e-6f only rules out a zero-length
		// tangent. A unit-length tangent that is NORMAL-COLLINEAR (parallel to
		// N) passes that guard but rotates to Tlocal.xy ~= (0,0) -- all of its
		// length lands on Tlocal.z -- making atan(Tlocal.y, Tlocal.x) ==
		// atan(0,0), which is undefined in GLSL and propagates NaN into
		// anisoPhi and every specular sample on that surface. Guard on the
		// LOCAL projected length instead, falling back to isotropic when it
		// is degenerate. The original zero-length world-space guard above is
		// kept as-is (it is still needed: it is what makes `tangentLen`, and
		// therefore the normalize a few lines up, safe to divide by).
		if (dot(Tlocal.xy, Tlocal.xy) > 1e-12f) {
			data.anisoActive = true;
			float aspect = anisoAspect(material.anisotropy);
			data.ax = data.alpha / aspect;
			data.ay = data.alpha * aspect;
			data.anisoPhi = atan(Tlocal.y, Tlocal.x) + material.anisotropyRotation;
		}
	}

	// Pre-calculate some more BRDF terms
	data.F = evalFresnel(data.specularF0, shadowedF90(data.specularF0), data.LdotH);

	return data;
}

// This is an entry point for evaluation of all other BRDFs based on selected configuration (for direct light)
float3 evalCombinedBRDF(float3 N, float3 L, float3 V, MaterialProperties material) {
	// Prepare data needed for BRDF evaluation - unpack material properties and evaluate commonly used terms (e.g. Fresnel, NdotL, ...)
	const BrdfData data = prepareBRDFData(N, L, V, material);

	// Ignore V and L rays "below" the hemisphere
	if (data.Vbackfacing || data.Lbackfacing) {
		return float3(0.0f, 0.0f, 0.0f);
	}

	// Eval specular and diffuse BRDFs
	float3 specular = evalSpecular(data);
	float3 diffuse = evalDiffuse(data);

	// Combine specular and diffuse layers
#if COMBINE_BRDFS_WITH_FRESNEL
	// Specular is already multiplied by F, just attenuate diffuse
	return (float3(1.0f, 1.0f, 1.0f) - data.F) * diffuse + specular;
#else
	return diffuse + specular;
#endif
}

// combinedPdf's own lobe-selection probability (pSpec), extracted to its own
// function (fix round 2) so a debug vis mode can call the EXACT code
// combinedPdf uses instead of re-inlining a copy that could silently drift
// from it. See samplerLobeProbability below for its sibling: the two are
// INTENTIONALLY separate functions rather than one shared helper, computing
// the identical formula from the identical inputs -- that is what makes a
// future divergence between them representable and catchable at all, the
// same failure mode Task 5/6's original combinedPdf desync was (pSpec here
// measured 0.0476 against the sampler's 0.0909 on a representative
// transmissive material before that fix). Fully unifying them into one
// function would make such a divergence structurally impossible to
// reintroduce, which sounds better until you need a regression test for
// exactly that class of bug -- see fix round 2's pdf-parity detector
// (RT_DEBUG_PDF_PARITY, raytracing_closest_hit_common_inc.glsl).
float combinedPdfLobeProbability(MaterialProperties material) {
	float3 specularF0 = baseColorToSpecularF0(material.baseColor, material.metalness, material.dielectricF0);
	float3 diffuseReflectance = baseColorToDiffuseReflectance(material.baseColor, material.metalness, material.transmissivness);
	float specularLum = luminance(specularF0);
	float diffuseLum = luminance(diffuseReflectance);

	if (diffuseLum < 0.0001f) {
		return 1.0f;
	} else if (specularLum < 0.0001f) {
		return 0.0f;
	}
	return clamp(specularLum / (specularLum + diffuseLum), 0.01f, 0.99f);
}

// The SAMPLER's own lobe-selection probability (brdfProbability) -- what
// shade_and_bounce's BRDF-importance-sampling block (raytracing_closest_hit_
// common_inc.glsl) actually uses to pick a lobe and scale throughput.
// Deliberately a SEPARATE function from combinedPdfLobeProbability above, not
// a shared call from both sites, even though the formula is currently
// identical -- see that function's doc comment for why. shade_and_bounce
// calls this one; combinedPdf calls the other. A future edit to either site
// without the other is exactly the historical failure mode this pair exists
// to make representable.
float samplerLobeProbability(MaterialProperties material) {
	float3 specularF0 = baseColorToSpecularF0(material.baseColor, material.metalness, material.dielectricF0);
	float3 diffuseReflectance = baseColorToDiffuseReflectance(material.baseColor, material.metalness, material.transmissivness);
	float specularLum = luminance(specularF0);
	float diffuseLum = luminance(diffuseReflectance);

	if (diffuseLum < 0.0001f) {
		return 1.0f;
	} else if (specularLum < 0.0001f) {
		return 0.0f;
	}
	return clamp(specularLum / (specularLum + diffuseLum), 0.01f, 0.99f);
}

// PDF that the combined diffuse+specular sampler in evalIndirectCombinedBRDF
// would assign to an arbitrary direction L.
//
// The sampler picks ONE lobe stochastically, so the effective density of any
// direction it returns is the mixture of both lobes weighted by their selection
// probabilities. Using only the selected lobe's term underestimates the density
// and loses energy through the MIS weight -- see the plan's Task 1 preamble.
//
// The lobe split here MUST stay identical to the one in shade_and_bounce
// (raytracing_closest_hit_common_inc.glsl). If they drift, MIS weights become
// inconsistent with how directions are actually generated.
float combinedPdf(float3 N, float3 L, float3 V, MaterialProperties material) {
	float NdotL = dot(N, L);
	if (NdotL <= 0.0f) {
		return 0.0f;
	}

	// Lobe selection probability, mirroring shade_and_bounce. Fix round 1, C1:
	// this MUST go through the same baseColorToDiffuseReflectance(...,
	// transmissivness) as shade_and_bounce's own lobe-selection diffuseLum
	// (raytracing_closest_hit_common_inc.glsl) and prepareBRDFData's
	// data.diffuseReflectance below -- one function, one set of inputs, so
	// pSpec here and brdfProbability there cannot desync. Before this fix,
	// this line called the 2-arg (pre-I2) form directly, independent of
	// prepareBRDFData's, and pSpec was measured desynced from the sampler's
	// brdfProbability by roughly 2x on a representative transmissive material
	// (albedo 0.8, metalness 0, transmission 0.5: sampler 0.0909, this
	// function 0.0476) -- live on every transmissive surface, through
	// mis_ray_pdf, env NEE and emissive NEE.
	float pSpec = combinedPdfLobeProbability(material);

	// Diffuse lobe: cosine-weighted hemisphere.
	float pdfDiffuse = diffusePdf(NdotL);

	// Specular lobe: VNDF reflection pdf. Built in the local frame where N = +Z,
	// matching how sampleSpecular generates directions.
	float4 qRotationToZ = getRotationToZAxis(N);
	float3 Llocal = rotatePoint(qRotationToZ, L);
	float3 Vlocal = rotatePoint(qRotationToZ, V);
	// E2b: prepareBRDFData derives anisoPhi from rotatePoint(getRotationToZAxis(N),
	// material.tangent) -- with N == (0,0,1) below (the local placeholder every
	// call site in this function already uses), that rotation is the identity,
	// so an UNROTATED material.tangent would be read as if it were already in
	// this local frame. material.tangent is WORLD-space (h.tangent), so it must
	// be rotated by the SAME qRotationToZ applied to L/V just above, or anisoPhi
	// comes out measuring the wrong axis entirely -- consistently wrong between
	// this function and evalIndirectCombinedBRDF's identical pattern (both would
	// derive the same incorrect anisoPhi from the same unrotated tangent), so it
	// would NOT show up as a sampler/pdf MIS desync, but the indirect specular
	// highlight's orientation would disagree with the direct-light NEE one
	// (evalMicrofacet correctly rotates by the REAL N, not this dummy one).
	MaterialProperties materialLocal = material;
	materialLocal.tangent = rotatePoint(qRotationToZ, material.tangent);
	const BrdfData data = prepareBRDFData(float3(0.0f, 0.0f, 1.0f), Llocal, Vlocal, materialLocal);

	// V ~= -L (near-mirror-degenerate incident/outgoing pair) leaves no stable
	// half-vector to normalize. clampShadingNormal only REDUCES backfacing V,
	// it does not eliminate it, so this is reachable in production, not just a
	// theoretical edge case. Treat it the same as the NdotL <= 0 early-out
	// above: return 0.0f rather than a NaN that would poison mis_ray_pdf --
	// the caller (shade_and_bounce) falls back to RT_MIS_PDF_NONE whenever this
	// function returns a non-positive value (Task 1 review round 1, findings
	// 1/2/9). That fallback is load-bearing and must stay: storing the 0.0 as a
	// live pdf makes the miss stage weight the ray by power_heuristic(0, e_pdf)
	// = 0 and delete its sky contribution outright.
	//
	// The OTHER consumer, environment NEE (raytracing_closest_hit_common_inc.glsl),
	// uses the 0.0 directly rather than through that fallback, and is safe doing so
	// because its own BRDF value is zero at every direction for which this function
	// returns zero: NdotL <= 0 is exactly evalCombinedBRDFSeparate's Lbackfacing
	// rejection, and the V ~= -L case below is caught by that block's dot(N,V)
	// guard. So it multiplies a weight of 1 by an estimator of 0. Any future
	// consumer must check that property for itself before trusting a zero here.
	float3 VplusL = Vlocal + Llocal;
	if (length(VplusL) < 0.000001f) {
		return 0.0f;
	}
	float3 Hlocal = normalize(VplusL);
	float NdotH = max(0.00001f, Hlocal.z);
	float NdotV = max(0.00001f, Vlocal.z);
	float LdotH = max(0.00001f, dot(Llocal, Hlocal));

	// Near-delta specular lobes (see RT_MIS_DELTA_ROUGHNESS) have no meaningful
	// continuous density. specularPdf's GGX_D call floors alphaSquared to
	// ~1e-5 (sampleGGXVNDFReflectionPdf), which turns what should be a true
	// Dirac delta into a razor-narrow but FINITE spike of order
	// 1/(pi*alphaSquared) ~ 3e4. A direction sampled from the DIFFUSE lobe
	// that happens to land inside that spike's tiny cone would otherwise make
	// this function return a wildly inflated mixture pdf for a strategy that
	// was never actually near-delta at the direction that matters here (Task
	// 1 review round 1, finding 3). Zeroing the specular contribution --
	// rather than skipping the setup above -- is the deliberately
	// conservative, minimal fix; an optimization to also skip the unused
	// quaternion/prepareBRDFData work in this regime is deferred, not part of
	// this fix.
	// E2b: route through the anisotropic pdf ONLY when data.anisoActive, exactly
	// mirroring evalMicrofacet's D/G2 branch below (Task 3 Step 4) and for the
	// identical reason -- GGX_D_Aniso is NOT bit-identical to GGX_D even when
	// ax == ay == alpha (Task 1's float32-cancellation finding at NdotH == 1
	// applies here too, since sampleGGXVNDFReflectionPdfAniso calls
	// GGX_D_Aniso internally). Taking the anisotropic pdf unconditionally would
	// shift combinedPdf's MIS weights on every existing scene, exactly the
	// bit-identity break the user's ruling forbids. Rotating Vlocal/Llocal/
	// Hlocal by -data.anisoPhi here MUST match the rotation sampleSpecular
	// applies when it actually draws the direction -- that agreement is the
	// entire point of this task.
	float specularContribution;
	if (material.roughness < RT_MIS_DELTA_ROUGHNESS) {
		specularContribution = 0.0f;
	} else if (data.anisoActive) {
		float3 Vaniso = rotateAboutZ(Vlocal, -data.anisoPhi);
		float3 Haniso = rotateAboutZ(Hlocal, -data.anisoPhi);
		float VdotH = max(0.00001f, dot(Vlocal, Hlocal));
		specularContribution = sampleGGXVNDFReflectionPdfAniso(Vaniso, Haniso, data.ax, data.ay, VdotH);
	} else {
		specularContribution = specularPdf(data.alpha, data.alphaSquared, NdotH, NdotV, LdotH);
	}

	// Roadmap E1: when the surface transmits, the dielectric closure only
	// REFLECTS with probability pdf_reflect, so the density it assigns to an
	// upper-hemisphere direction is scaled by that factor. Without this, every
	// MIS weight on a transmissive surface describes a different integrand than
	// the estimator evaluates -- exactly the class of bug B2 shipped and C3
	// measured.
	//
	// Gated on transmissivness > 0 so an opaque material's density is unchanged
	// INSTRUCTION-FOR-INSTRUCTION, matching the sampling dispatch. The two must
	// agree about which formulation generated the sample.
	// Same function sampleDielectricMicrofacet calls to CHOOSE the lobe. It must
	// be the same function, not a copy: the density reported here and the density
	// actually sampled there are the two halves of every MIS weight on a
	// transmissive surface.
	float transmitScale = 1.0f;
	if (material.transmissivness > 0.0f) {
		float3 reflectance_unused;
		float3 transmittance_unused;
		float cos_theta_t_unused = 0.0f;
		transmitScale = dielectricFresnelSplit(max(0.00001f, LdotH), material.eta,
				data.specularF0, material.transmissivness,
				reflectance_unused, transmittance_unused, cos_theta_t_unused);
	}

	return pSpec * specularContribution * transmitScale + (1.0f - pSpec) * pdfDiffuse;
}

// Version that returns diffuse and specular separately.
void evalCombinedBRDFSeparate(float3 N, float3 L, float3 V, MaterialProperties material, OUT_PARAMETER(float3) outDiffuse, OUT_PARAMETER(float3) outSpecular) {
	outDiffuse = float3(0.0f, 0.0f, 0.0f);
	outSpecular = float3(0.0f, 0.0f, 0.0f);
	// Prepare data needed for BRDF evaluation (uses shading normal N for all BRDF math).
	const BrdfData data = prepareBRDFData(N, L, V, material);
	// Ignore L rays "below" the hemisphere
	if (data.Lbackfacing) {
		return;
	}

	// Eval specular and diffuse BRDFs
	outSpecular = evalSpecular(data);
	outDiffuse = evalDiffuse(data);

#if COMBINE_BRDFS_WITH_FRESNEL
	// Specular is already multiplied by F, just attenuate diffuse
	outDiffuse = (float3(1.0f, 1.0f, 1.0f) - data.F) * outDiffuse;
#endif
}

// This is an entry point for evaluation of all other BRDFs based on selected configuration (for indirect light)
bool evalIndirectCombinedBRDF(float2 u, float3 shadingNormal, float3 geometryNormal, float3 V, MaterialProperties material, const int brdfType, OUT_PARAMETER(float3) rayDirection, OUT_PARAMETER(float3) sampleWeight, float4 debug) {
	// Ignore incident ray coming from "below" the hemisphere
	//if (dot(shadingNormal, V) <= 0.0f) return false;

	// Transform view direction into local space of our sampling routines
	// (local space is oriented so that its positive Z axis points along the shading normal)
	float4 qRotationToZ = getRotationToZAxis(shadingNormal);
	float3 Vlocal = rotatePoint(qRotationToZ, V);
	const float3 Nlocal = float3(0.0f, 0.0f, 1.0f);

	// E2b: prepareBRDFData derives anisoPhi via rotatePoint(getRotationToZAxis(N),
	// material.tangent); with N == Nlocal == (0,0,1) below, that inner rotation
	// is the identity, so passing the raw WORLD-space material.tangent straight
	// through would be read as already-local, i.e. the wrong axis. Rotate the
	// tangent by the SAME qRotationToZ applied to V/L above first, so it lands
	// in the identical local frame -- matching evalMicrofacet's world-to-local
	// transform (which uses the real shadingNormal directly instead).
	MaterialProperties materialLocal = material;
	materialLocal.tangent = rotatePoint(qRotationToZ, material.tangent);

	float3 rayDirectionLocal = float3(0.0f, 0.0f, 0.0f);

	if (brdfType == DIFFUSE_TYPE) {
		// Sample diffuse ray using cosine-weighted hemisphere sampling
		rayDirectionLocal = sampleHemisphere(u);
		const BrdfData data = prepareBRDFData(Nlocal, rayDirectionLocal, Vlocal, materialLocal);

		// Function 'diffuseTerm' is predivided by PDF of sampling the cosine weighted hemisphere
		sampleWeight = data.diffuseReflectance * diffuseTerm(data);

#if COMBINE_BRDFS_WITH_FRESNEL
		// Sample a half-vector of specular BRDF. Note that we're reusing random variable 'u' here, but correctly it should be an new independent random number
		// E2b: rotate into the anisotropy frame, sample with ax/ay, rotate back.
		// At anisotropy == 0 (or no usable tangent) data.anisoPhi is 0 and
		// data.ax == data.ay == data.alpha, so both rotations are the identity
		// and this reduces exactly to the pre-E2b call -- Vlocal/Nlocal are
		// already in the local frame here, so unlike evalMicrofacet no extra
		// world-to-local transform is needed.
		float3 Hspecular;
		if (data.anisoActive) {
			float3 Vaniso = rotateAboutZ(Vlocal, -data.anisoPhi);
			float3 Haniso = sampleSpecularHalfVector(Vaniso, float2(data.ax, data.ay), u);
			Hspecular = rotateAboutZ(Haniso, data.anisoPhi);
		} else {
			// Fix round (Minor #2): same structural fix as sampleSpecularMicrofacet
			// -- no rotation on the isotropic path.
			Hspecular = sampleSpecularHalfVector(Vlocal, float2(data.alpha, data.alpha), u);
		}

		// Clamp HdotL to small value to prevent numerical instability. Assume that rays incident from below the hemisphere have been filtered
		float VdotH = max(0.00001f, min(1.0f, dot(Vlocal, Hspecular)));
		sampleWeight *= (float3(1.0f, 1.0f, 1.0f) - evalFresnel(data.specularF0, shadowedF90(data.specularF0), VdotH));
#endif

	} else if (brdfType == SPECULAR_TYPE) {
		const BrdfData data = prepareBRDFData(Nlocal, float3(0.0f, 0.0f, 1.0f) /* unused L vector */, Vlocal, materialLocal);
		rayDirectionLocal = sampleSpecular(Vlocal, data.alpha, data.alphaSquared, data.specularF0, data.ax, data.ay, data.anisoPhi, data.anisoActive, u, sampleWeight);
	}

	// Transform sampled direction Llocal back to V vector space.
	// Done before the early-out checks so the caller always receives a valid
	// direction in 'rayDirection' (e.g. for below-hemisphere mirroring).
	rayDirection = normalize(rotatePoint(invertRotation(qRotationToZ), rayDirectionLocal));

	// Prevent tracing direction with no contribution
	if (luminance(sampleWeight) == 0.0f) {
		return false;
	}

	// Prevent tracing direction "under" the hemisphere (behind the triangle).
	// The caller is expected to handle this case: either terminate the path,
	// or mirror the direction across the geometry plane to keep it above.
	if (dot(geometryNormal, rayDirection) <= 0.0f) {
		return false;
	}

	return true;
}

// -------------------------------------------------------------------------
//    DLSS-RR G-buffer helpers (Environment BRDF approximation)
// -------------------------------------------------------------------------

// Environment BRDF approximation from https://www.unrealengine.com/fr/blog/physically-based-shading-on-mobile
// Author: Brian Karis, License: 'Epic Games, Inc. gives you permission to use, copy, modify, and distribute the code samples in this article as you see fit with no attribution required.'
// Returns specular albedo directly (F0 * scale + bias).
float3 DLSSRR_envBRDFApprox(float3 specularColor, float roughness, float NdotV) {
	const float4 c0 = { -1, -0.0275, -0.572, 0.022 };
	const float4 c1 = { 1, 0.0425, 1.04, -0.04 };
	float4 r = roughness * c0 + c1;
	float a004 = min(r.x * r.x, exp2(-9.28 * NdotV)) * r.x + r.y;
	float2 AB = float2(-1.04, 1.04) * a004 + r.zw;
	return (specularColor * AB.x + AB.y) * 2.0f;
}

float3 DLSSRR_computeDiffuseAlbedo(float3 baseColor, float metalness) {
	return baseColor * (1.0f - metalness);
}

float3 DLSSRR_computeSpecularAlbedo(float3 baseColor, float metalness, float3 dielectricF0, float roughness, float NdotV) {
	float3 F0 = baseColorToSpecularF0(baseColor, metalness, dielectricF0);
	return DLSSRR_envBRDFApprox(F0, roughness, NdotV);
}

#endif // BRDF_HLSLI
