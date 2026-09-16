// E3 subsurface: Cycles' random-walk BSSRDF, transcribed from
// intern/cycles/kernel/integrator/subsurface_random_walk.h (5.3.0-alpha) with
// anisotropy fixed at 0. Every constant and formula is Cycles'; only the
// intersection call (a same-instance ray query) and the RNG are ours.
//
// Included from the closest-hit stage after the buffers (tlas, geometries,
// materials) and before raytracing_closest_hit_common_inc.glsl, which calls
// sss_random_walk() from its SUBSURFACE_TYPE arm.
#ifdef RT_SSS_ENABLED

#define SSS_MAX_BOUNCES 256u // BSSRDF_MAX_BOUNCES (kernel/types.h)
#define SSS_THROUGHPUT_EPSILON 1e-6 // VOLUME_THROUGHPUT_EPSILON
#define SSS_MIN_ALPHA 0.2 // subsurface_random_walk_coefficients min_alpha

// Walk-local PCG. Cycles scrambles its path RNG with 0xdeadbeef for the walk;
// ours must not consume the path's Sobol dimensions (up to 256 steps x 5
// draws), so the walk owns an independent 32-bit stream seeded from the path.
uint sss_pcg(inout uint state) {
	state = state * 747796405u + 2891336453u;
	uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
	return (word >> 22u) ^ word;
}
float sss_rand(inout uint state) {
	return float(sss_pcg(state) >> 8u) * (1.0 / 16777216.0);
}

// subsurface_random_walk_remap (van de Hulst, d'Eon "Hitchhiker's Guide"
// eq. 53.7), at g = 0 where (1 - s^2) / (1 - g s^2) is just (1 - s^2).
void sss_remap(vec3 color, vec3 radius, out vec3 sigma_t, out vec3 alpha) {
	vec3 s = 4.20863 * color - sqrt(9.59217 + 41.6808 * color + 17.7126 * color * color) + 4.09712;
	vec3 s_sq = s * s;
	alpha = clamp(1.0 - s_sq, vec3(0.0), vec3(0.999999));
	sigma_t = 1.0 / max(radius, vec3(1e-16));
}

// diffusion_length_dwivedi, Eq. 67 of d'Eon & Krivanek 2020.
float sss_diffusion_length(float alpha) {
	return 1.0 / sqrt(1.0 - pow(alpha, 2.44294 - 0.0215813 * alpha + 0.578637 / alpha));
}
float sss_eval_phase_dwivedi(float v, float phase_log, float cos_theta) {
	return 1.0 / ((v - cos_theta) * phase_log);
}
float sss_sample_phase_dwivedi(float v, float phase_log, float r) {
	return v - (v + 1.0) * exp(-r * phase_log);
}
// direction_from_cosine: a direction at cos_theta about D, azimuth from randv.
vec3 sss_direction_from_cosine(vec3 D, float cos_theta, float randv) {
	float phi = 2.0 * PI * randv;
	float sin_theta = sqrt(max(0.0, 1.0 - cos_theta * cos_theta));
	vec3 T = (abs(D.x) > abs(D.y)) ? normalize(vec3(-D.z, 0.0, D.x)) : normalize(vec3(0.0, D.z, -D.y));
	vec3 B = cross(D, T);
	return T * (sin_theta * cos(phi)) + B * (sin_theta * sin(phi)) + D * cos_theta;
}
// volume_sample_channel: MIS over colour channels by |throughput * albedo|.
int sss_sample_channel(vec3 alpha, vec3 throughput, inout float r, out vec3 pdf) {
	vec3 w = abs(throughput * alpha);
	float sum_w = w.x + w.y + w.z;
	pdf = (sum_w > 0.0) ? (w / sum_w) : vec3(1.0 / 3.0);
	if (r < pdf.x) {
		r /= pdf.x;
		return 0;
	}
	if (r < pdf.x + pdf.y) {
		r = (r - pdf.x) / pdf.y;
		return 1;
	}
	r = (r - pdf.x - pdf.y) / max(pdf.z, 1e-8);
	return 2;
}
float sss_channel(vec3 v, int c) {
	return (c == 0) ? v.x : ((c == 1) ? v.y : v.z);
}
// subsurface_random_walk_pdf: T = exp(-sigma_t t); hit ? T : sigma_t T.
vec3 sss_walk_pdf(vec3 sigma_t, float t, bool hit, out vec3 transmittance) {
	transmittance = exp(-sigma_t * t);
	return hit ? transmittance : sigma_t * transmittance;
}

// Nearest intersection with THIS instance only, in [0, t_max]. step_zero skips
// the entry triangle (Cycles ray.self.prim on the first step). Every triangle
// is forced to be a candidate (NoOpaque) so the instance test runs on all.
bool sss_intersect_self(vec3 origin, vec3 dir, float t_max, uint self_instance, uint self_prim, bool step_zero, out float hit_t) {
	rayQueryEXT rq;
	rayQueryInitializeEXT(rq, tlas, gl_RayFlagsNoOpaqueEXT, 0xFF, origin, 0.0, dir, t_max);
	while (rayQueryProceedEXT(rq)) {
		if (rayQueryGetIntersectionInstanceIdEXT(rq, false) != self_instance) {
			continue;
		}
		if (step_zero && rayQueryGetIntersectionPrimitiveIndexEXT(rq, false) == self_prim) {
			continue;
		}
		rayQueryConfirmIntersectionEXT(rq);
	}
	if (rayQueryGetIntersectionTypeEXT(rq, true) == gl_RayQueryCommittedIntersectionNoneEXT) {
		return false;
	}
	hit_t = rayQueryGetIntersectionTEXT(rq, true);
	return true;
}

// The walk. P: entry point (on the surface). D: entry direction (into the
// surface). N: shading normal at entry. Returns true with exit_pos/exit_dir on
// success; throughput is updated in place. False = the path ends (Cycles).
bool sss_random_walk(vec3 P, vec3 D, vec3 N, vec3 albedo_in, vec3 radius, inout vec3 throughput,
		uint seed, uint self_instance, uint self_prim, out vec3 exit_pos, out vec3 exit_dir) {
	vec3 albedo = max(albedo_in, vec3(0.0));
	vec3 sigma_t;
	vec3 alpha;
	sss_remap(albedo, radius, sigma_t, alpha);
	// Throughput already carries the closure weight including the albedo;
	// divide it out, the scattering re-adds it
	// (subsurface_random_walk_coefficients, safe_divide_color).
	throughput = vec3(
			albedo.r > 0.0 ? throughput.r / albedo.r : 0.0,
			albedo.g > 0.0 ? throughput.g / albedo.g : 0.0,
			albedo.b > 0.0 ? throughput.b / albedo.b : 0.0);
	// Low single-scatter albedo gives diffusion length 1 and an infinite phase;
	// raise alpha to 0.2 and pay the difference in throughput (Cycles).
	for (int i = 0; i < 3; i++) {
		if (alpha[i] < SSS_MIN_ALPHA) {
			throughput[i] *= alpha[i] / SSS_MIN_ALPHA;
			alpha[i] = SSS_MIN_ALPHA;
		}
	}
	vec3 sigma_s = sigma_t * alpha;
	float diffusion_length = sss_diffusion_length(max(max(alpha.r, alpha.g), alpha.b));
	if (diffusion_length == 1.0) {
		return false;
	}
	float phase_log = log((diffusion_length + 1.0) / (diffusion_length - 1.0));
	uint rng = seed ^ 0xdeadbeefu;
	// g = 0: guided_fraction = 1 - max(0.5, 0) = 0.5 (Cycles' heuristic).
	const float guided_fraction = 0.5;
	const float hg_pdf = 1.0 / (4.0 * PI); // isotropic phase at g = 0

	vec3 ray_p = P;
	vec3 ray_d = D;
	bool hit = false;
	bool have_opposite = false;
	float opposite_distance = 0.0;

	for (uint bounce = 0u; bounce < SSS_MAX_BOUNCES; bounce++) {
		float rchannel = sss_rand(rng);
		vec3 channel_pdf;
		int channel = sss_sample_channel(alpha, throughput, rchannel, channel_pdf);
		float sample_sigma_t = sss_channel(sigma_t, channel);
		float randt = sss_rand(rng);

		float backward_fraction = 0.0;
		float forward_pdf_factor = 0.0;
		float forward_stretching = 1.0;
		float backward_pdf_factor = 0.0;
		float backward_stretching = 1.0;

		// The entry direction is given; direction sampling starts at step 1.
		if (bounce > 0u) {
			bool guided = sss_rand(rng) < guided_fraction;
			bool guide_backward = false;
			if (have_opposite) {
				// Distance of the walk between the tangent plane at the entry and
				// the assumed opposite interface; the closer to the far side, the
				// likelier we aim back at it (d'Eon & Krivanek 2020).
				float x = clamp(dot(ray_p - P, -N), 0.0, opposite_distance);
				backward_fraction = 1.0 / (1.0 + exp((opposite_distance - 2.0 * x) / diffusion_length));
				guide_backward = sss_rand(rng) < backward_fraction;
			}
			float rs_x = sss_rand(rng);
			float rs_y = sss_rand(rng);
			float cos_theta;
			if (guided) {
				cos_theta = sss_sample_phase_dwivedi(diffusion_length, phase_log, rs_x);
				if (guide_backward) {
					cos_theta = -cos_theta;
				}
				ray_d = sss_direction_from_cosine(N, cos_theta, rs_y);
			} else {
				// phase_henyey_greenstein_sample at g = 0: uniform sphere.
				float ct = 1.0 - 2.0 * rs_x;
				ray_d = sss_direction_from_cosine(ray_d, ct, rs_y);
				cos_theta = dot(ray_d, N);
			}
			// Guided / classic pdf ratio for the direction (phase sampling is
			// channel-independent, so it factors out of the classic term).
			forward_pdf_factor = (1.0 / (2.0 * PI)) * sss_eval_phase_dwivedi(diffusion_length, phase_log, cos_theta) / hg_pdf;
			backward_pdf_factor = (1.0 / (2.0 * PI)) * sss_eval_phase_dwivedi(diffusion_length, phase_log, -cos_theta) / hg_pdf;
			forward_stretching = 1.0 - cos_theta / diffusion_length;
			backward_stretching = 1.0 + cos_theta / diffusion_length;
			if (guided) {
				sample_sigma_t *= guide_backward ? backward_stretching : forward_stretching;
			}
		}

		float t = -log(1.0 - randt) / sample_sigma_t;
		// Step 0 also probes far enough to find the opposite interface.
		float t_max = (bounce == 0u) ? max(t, 10.0 / min(min(sigma_t.r, sigma_t.g), sigma_t.b)) : t;
		float ht;
		bool h = sss_intersect_self(ray_p, ray_d, t_max, self_instance, self_prim, bounce == 0u, ht);
		if (h) {
			t_max = ht;
		}
		if (bounce == 0u) {
			if (h) {
				have_opposite = true;
				opposite_distance = dot(ray_p + t_max * ray_d - P, -N);
			}
			// Only a hit inside the sampled distance counts as an exit.
			h = t_max < t;
		}
		if (h) {
			t = t_max;
		}
		ray_p += t * ray_d;

		vec3 transmittance;
		vec3 pdf = sss_walk_pdf(sigma_t, t, h, transmittance);
		if (bounce > 0u) {
			vec3 unused;
			vec3 guided_pdf = sss_walk_pdf(forward_stretching * sigma_t, t, h, unused);
			if (have_opposite) {
				vec3 back_pdf = sss_walk_pdf(backward_stretching * sigma_t, t, h, unused);
				guided_pdf = mix(guided_pdf * forward_pdf_factor, back_pdf * backward_pdf_factor, backward_fraction);
			} else {
				guided_pdf *= forward_pdf_factor;
			}
			// Balance heuristic between classic and guided sampling.
			pdf = mix(pdf, guided_pdf, guided_fraction);
		}
		// MIS over the three colour channels: {classic, guided, backward} x {r,g,b}.
		throughput *= (h ? transmittance : sigma_s * transmittance) / max(dot(channel_pdf, pdf), 1e-20);

		if (h) {
			hit = true;
			break;
		}
		if (max(max(throughput.r, throughput.g), throughput.b) < SSS_THROUGHPUT_EPSILON) {
			break;
		}
	}
	if (!hit) {
		return false;
	}
	exit_pos = ray_p;
	exit_dir = ray_d;
	return true;
}
#endif // RT_SSS_ENABLED
