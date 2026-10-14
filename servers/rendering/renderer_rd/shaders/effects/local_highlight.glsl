#[compute]

#version 450

#VERSION_DEFINES

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// Mode DOWNSAMPLE: read the colour buffer, write mean luminance at 1/16.
// Mode APPLY: read the blurred luminance, multiply the colour buffer by the gain.

layout(push_constant, std430) uniform Params {
	ivec2 src_size;
	ivec2 dst_size;
	float strength;
	float exposure;
	float knee;
	uint debug;
}
params;

#ifdef MODE_DOWNSAMPLE
layout(set = 0, binding = 0) uniform sampler2D source_color;
layout(rgba16f, set = 0, binding = 1) uniform restrict writeonly image2D dest_luma;
#endif

#ifdef MODE_APPLY
layout(set = 0, binding = 0) uniform sampler2D source_luma;
layout(rgba16f, set = 0, binding = 1) uniform restrict image2D dest_color;
#endif

float luminance(vec3 c) {
	return dot(c, vec3(0.2126, 0.7152, 0.0722));
}

// Range of the edge-aware upsample, in stops of luminance: cells more than ~2 stops
// away from a pixel's own brightness barely count toward its gain.
const float RELIEF_RANGE_SIGMA_STOPS = 1.0;

void main() {
	ivec2 pos = ivec2(gl_GlobalInvocationID.xy);

#ifdef MODE_DOWNSAMPLE
	if (any(greaterThanEqual(pos, params.dst_size))) {
		return;
	}
	// One bilinear tap per source texel covered, averaged. The destination is
	// 1/16 the source, so a 4x4 grid of bilinear taps averages the 16x16 source
	// footprint -- a wide box, which is what suppresses halos. Sampling in
	// normalised coordinates keeps this correct for any non-multiple size.
	vec2 dst_texel = (vec2(pos) + 0.5) / vec2(params.dst_size);
	vec2 src_step = 1.0 / vec2(params.src_size);
	float acc = 0.0;
	for (int y = -2; y <= 1; y++) {
		for (int x = -2; x <= 1; x++) {
			vec2 uv = dst_texel + vec2(float(x) + 0.5, float(y) + 0.5) * 4.0 * src_step;
			acc += luminance(textureLod(source_color, uv, 0.0).rgb);
		}
	}
	imageStore(dest_luma, pos, vec4(acc / 16.0, 0.0, 0.0, 1.0));
#endif

#ifdef MODE_APPLY
	if (any(greaterThanEqual(pos, params.src_size))) {
		return;
	}
	// The 1/16 map is upsampled EDGE-AWARE (joint bilateral): the 4x4 nearest
	// cells, each weighted by a tent of radius 2 cells and by how close its log
	// luminance is to this pixel's own. A plain bilinear read gave every pixel
	// within ~32 px of a sun patch the patch's gain, so the darker objects beside
	// it went dark too (2026-10-14: job 211's coffee-table rim, 143 -> 35 levels).
	// Inside a patch all cells are alike, so the divisor stays smooth there --
	// THE DIVISOR MUST STAY SMOOTH: that is what preserves the patch's own
	// texture while moving the patch as a whole down the curve.
	// Mirrored in tests/servers/rendering/test_pt_relief.cpp.
	vec4 c = imageLoad(dest_color, pos);
	vec2 t = (vec2(pos) + 0.5) / vec2(params.src_size) * vec2(params.dst_size) - 0.5;
	ivec2 base = ivec2(floor(t)) - 1;
	float own_log = log2(max(luminance(c.rgb), 1e-6));
	float acc = 0.0;
	float wsum = 0.0;
	for (int y = 0; y < 4; y++) {
		for (int x = 0; x < 4; x++) {
			ivec2 cell = base + ivec2(x, y);
			vec2 ws2 = max(vec2(0.0), 1.0 - abs(vec2(cell) - t) * 0.5);
			float l = texelFetch(source_luma, clamp(cell, ivec2(0), params.dst_size - 1), 0).r;
			float dl = log2(max(l, 1e-6)) - own_log;
			float w = ws2.x * ws2.y * (exp(-0.5 * dl * dl / (RELIEF_RANGE_SIGMA_STOPS * RELIEF_RANGE_SIGMA_STOPS)) + 1e-6);
			acc += w * l;
			wsum += w;
		}
	}
	float lb = acc / max(wsum, 1e-12) * params.exposure;
	float excess = max(0.0, lb / params.knee - 1.0);
	float gain = 1.0 / (1.0 + params.strength * excess);

	if (params.debug != 0u) {
		imageStore(dest_color, pos, vec4(vec3(gain), 1.0));
		return;
	}
	imageStore(dest_color, pos, vec4(c.rgb * gain, c.a));
#endif
}
