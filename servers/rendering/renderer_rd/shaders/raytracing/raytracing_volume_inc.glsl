// F2 volumetrics (roadmap Gap #16): one bounded homogeneous medium -- the
// Environment's volumetric fog on the scene's bounding box -- shaded the way
// Cycles shades a cube with a Volume Scatter shader at its default
// volume_bounces = 0 (single scattering). See
// docs/superpowers/specs/2026-09-17-volumetrics-design.md.
//
// Requires raytracing_inc.glsl and raytracing_common_inc.glsl (rt_params).
// Everything here is gated on RT_FLAG_VOLUME_ENABLED, a specialisation
// constant: with the fog off every call folds to its no-op branch and the
// render is bit-identical to a build without this file.

bool volume_active() {
	return (RT_FLAGS & RT_FLAG_VOLUME_ENABLED) != 0u;
}

float volume_sigma_t() {
	return get_rt_param(RT_PARAM_VOLUME_SIGMA_T);
}

float volume_g() {
	return get_rt_param(RT_PARAM_VOLUME_G);
}

vec3 volume_albedo() {
	return vec3(get_rt_param(RT_PARAM_VOLUME_ALBEDO_R), get_rt_param(RT_PARAM_VOLUME_ALBEDO_R + 1u), get_rt_param(RT_PARAM_VOLUME_ALBEDO_R + 2u));
}

vec3 volume_emission() {
	return vec3(get_rt_param(RT_PARAM_VOLUME_EMISSION_R), get_rt_param(RT_PARAM_VOLUME_EMISSION_R + 1u), get_rt_param(RT_PARAM_VOLUME_EMISSION_R + 2u));
}

/// Slab test of the ray o + t d against the fog box, clipped to [t0, t1].
/// Returns false when the clipped interval is empty.
bool volume_box_clip(vec3 o, vec3 d, float t0, float t1, out float t_in, out float t_out) {
	vec3 bmin = vec3(get_rt_param(RT_PARAM_VOLUME_BOX_MIN_X), get_rt_param(RT_PARAM_VOLUME_BOX_MIN_X + 1u), get_rt_param(RT_PARAM_VOLUME_BOX_MIN_X + 2u));
	vec3 bmax = vec3(get_rt_param(RT_PARAM_VOLUME_BOX_MAX_X), get_rt_param(RT_PARAM_VOLUME_BOX_MAX_X + 1u), get_rt_param(RT_PARAM_VOLUME_BOX_MAX_X + 2u));
	// 1/d with the sign kept on zero components: a ray parallel to a slab is
	// inside it iff the origin is, which the +-inf arithmetic below yields.
	vec3 inv_d = 1.0 / d;
	vec3 ta = (bmin - o) * inv_d;
	vec3 tb = (bmax - o) * inv_d;
	vec3 tn = min(ta, tb);
	vec3 tf = max(ta, tb);
	t_in = max(max(max(tn.x, tn.y), tn.z), t0);
	t_out = min(min(min(tf.x, tf.y), tf.z), t1);
	return t_out > t_in;
}

/// Length of [t0, t1] that lies inside the box.
float volume_segment_length(vec3 o, vec3 d, float t0, float t1) {
	float t_in, t_out;
	return volume_box_clip(o, d, t0, t1, t_in, t_out) ? (t_out - t_in) : 0.0;
}

/// exp(-sigma_t * L) over the in-box part of [t0, t1]: Cycles'
/// volume_color_transmittance on a bounded homogeneous medium
/// (shade_volume.h:680), grey because Godot's density is a scalar.
vec3 volume_transmittance_along(vec3 o, vec3 d, float t0, float t1) {
	if (!volume_active()) {
		return vec3(1.0);
	}
	return vec3(exp(-volume_sigma_t() * volume_segment_length(o, d, t0, t1)));
}

/// Cycles' phase_henyey_greenstein (closure/volume_util.h:27-34): cos_theta is
/// dot(ray_dir, L) -- the angle between the direction the light travels on
/// toward the camera and the direction to the light -- so g > 0 peaks when
/// the light is ahead of the ray (forward scattering). g is clamped as
/// volume_henyey_greenstein_setup does.
float phaseHenyeyGreenstein(float cos_theta, float g) {
	g = sign(g) * min(abs(g), 1.0 - 1e-3);
	if (abs(g) < 1e-3) {
		return 1.0 / (4.0 * PI);
	}
	float fac = 1.0 + g * (g - 2.0 * cos_theta);
	return (1.0 - g * g) / (4.0 * PI * fac * sqrt(max(fac, 1e-12)));
}
