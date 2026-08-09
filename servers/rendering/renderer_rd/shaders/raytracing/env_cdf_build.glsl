#[compute]

#version 450

#VERSION_DEFINES

#include "../oct_inc.glsl"

// Builds a 2D sampling distribution over the sky for environment NEE.
// A CPU mirror lives in tests/servers/rendering/test_pt_env_cdf.cpp; change both
// together or the tests stop meaning anything.
//
// Two dispatches:
//   MODE_ROWS     one workgroup per row: raw f, row prefix sums, row sum
//   MODE_MARGINAL one workgroup: floor from the grand total, then the marginal
//
// The floor is relative to the grid mean, which is not known until every cell is
// summed. Rather than rebuild every cell in a third pass, the rows pass stores
// prefix sums of the RAW f and the floor is folded in arithmetically at lookup:
//   adjusted_prefix(y, x) = prefix_raw[y][x] + (x + 1) * floor

#define N_U 256
#define N_V 128

layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform texture2D radiance_octmap;
layout(set = 0, binding = 1) uniform sampler radiance_sampler;

layout(set = 0, binding = 2, std430) restrict buffer EnvDist {
	float floor_value;
	float marginal_total;
	float data[]; // prefix_raw[N_V*N_U], rowsum_adj[N_V], marginal_prefix[N_V]
}
dist;

#define PREFIX_RAW_OFFSET 0
#define ROWSUM_ADJ_OFFSET (N_V * N_U)
#define MARGINAL_PREFIX_OFFSET (N_V * N_U + N_V)

layout(push_constant, std430) uniform Params {
	uint mode; // 0 = rows, 1 = marginal
	uint pad0;
	uint pad1;
	uint pad2;
}
params;

shared float row_vals[N_U];

/// Direction for grid cell centre (u, v). Engine is Y-up; matches the
/// convention in ies_lookup_inc.glsl.
vec3 dir_from_uv(float u, float v) {
	float phi = u * 2.0 * 3.141592653589;
	float theta = v * 3.141592653589;
	float st = sin(theta);
	return vec3(st * sin(phi), cos(theta), st * cos(phi));
}

float cell_raw(uint x, uint y) {
	float u = (float(x) + 0.5) / float(N_U);
	float v = (float(y) + 0.5) / float(N_V);
	vec3 d = dir_from_uv(u, v);
	vec3 rad = textureLod(sampler2D(radiance_octmap, radiance_sampler), vec3_to_oct(d), 0.0).rgb;
	float lum = dot(rad, vec3(0.2126, 0.7152, 0.0722));
	// sin(theta) converts the (u,v) density to a solid-angle density.
	return max(lum, 0.0) * sin(v * 3.141592653589);
}

void main() {
	if (params.mode == 0u) {
		// --- Rows pass: one workgroup per row, 256 threads. ---
		uint y = gl_WorkGroupID.x;
		uint x = gl_LocalInvocationID.x;

		row_vals[x] = cell_raw(x, y);
		barrier();

		// Serial inclusive scan by one thread. 256 elements is trivial next to the
		// texture fetches above, and it avoids a fiddly parallel-scan bug surface.
		if (x == 0u) {
			float running = 0.0;
			for (uint i = 0u; i < uint(N_U); i++) {
				running += row_vals[i];
				dist.data[PREFIX_RAW_OFFSET + y * uint(N_U) + i] = running;
			}
			// Row sum without the floor; the marginal pass adds it.
			dist.data[ROWSUM_ADJ_OFFSET + y] = running;
		}
	} else {
		// --- Marginal pass: one workgroup, first thread only. ---
		if (gl_GlobalInvocationID.x != 0u) {
			return;
		}
		float total_raw = 0.0;
		for (uint y = 0u; y < uint(N_V); y++) {
			total_raw += dist.data[ROWSUM_ADJ_OFFSET + y];
		}
		float mean = total_raw / float(N_U * N_V);
		float fl = 1e-4 * mean;
		dist.floor_value = fl;

		float running = 0.0;
		for (uint y = 0u; y < uint(N_V); y++) {
			float adj = dist.data[ROWSUM_ADJ_OFFSET + y] + float(N_U) * fl;
			dist.data[ROWSUM_ADJ_OFFSET + y] = adj;
			running += adj;
			dist.data[MARGINAL_PREFIX_OFFSET + y] = running;
		}
		dist.marginal_total = running;
	}
}
