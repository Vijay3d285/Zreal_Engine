// Light portals (spec 2026-09-18-light-portals-design.md): a sampling hint for
// the sky, not a light. Transcribed from Cycles 5.3.0-alpha
// kernel/light/background.h (portal facing test, portal pdf, portal sample) and
// kernel/light/area.h (Urena spherical-rectangle sampling); the line cited
// above each function is the original.
//
// Included from raytracing_common_inc.glsl immediately before
// raytracing_env_sampling_inc.glsl, so every stage that has the sky sampler
// has the portals (the miss stage evaluates the portal pdf for MIS and does
// NOT include the light buffer -- hence a buffer of their own).
//
// Requires: get_rt_param (raytracing_common_inc.glsl), RT_PARAM_PORTAL_COUNT
// (raytracing_inc.glsl).

// MIRRORS C++ RT_PortalData (render_raytracing.h), 64 bytes, std430.
struct RTPortalData {
	vec3 position; // Rectangle centre, world space.
	float _pad0;
	vec3 axis_u; // Unit axis along the width (the light's local +X).
	float len_u; // Full width.
	vec3 axis_v; // Unit axis along the height (local +Y).
	float len_v; // Full height.
	vec3 dir; // Facing direction (local -Z); a point P is "in front" when dot(dir, P - position) > 0.
	float _pad1;
};

layout(set = 0, binding = 41, std430) readonly buffer PortalBuffer {
	RTPortalData rt_portals[];
};

#ifndef RT_STAGE_ANY_HIT
int portal_count() {
	return int(get_rt_param(RT_PARAM_PORTAL_COUNT));
}
#else
// The any-hit stage has no params UBO (raytracing_common_inc.glsl guards it
// out) and never samples the sky; the sky sampler still has to compile there.
int portal_count() {
	return 0;
}
#endif
