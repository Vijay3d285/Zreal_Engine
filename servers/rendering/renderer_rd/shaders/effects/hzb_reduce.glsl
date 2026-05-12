#[compute]

#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D source_depth;
layout(r32f, set = 0, binding = 1) uniform restrict writeonly image2D dest_mip;

layout(push_constant, std430) uniform Params {
	vec2 source_size;
	vec2 dest_size;
	int source_mip;
}
params;

void main() {
	ivec2 dst_px = ivec2(gl_GlobalInvocationID.xy);
	if (dst_px.x >= int(params.dest_size.x) || dst_px.y >= int(params.dest_size.y)) {
		return;
	}

	// 2x2 gather from the source mip — keep the MAXIMUM depth (farthest).
	// Maximum = most conservative — nothing gets falsely culled.
	vec2 uv = (vec2(dst_px) + 0.5) / params.dest_size;
	vec2 off = 0.5 / params.source_size;

	float d0 = textureLod(source_depth, uv + vec2(-off.x, -off.y), params.source_mip).r;
	float d1 = textureLod(source_depth, uv + vec2(off.x, -off.y), params.source_mip).r;
	float d2 = textureLod(source_depth, uv + vec2(-off.x, off.y), params.source_mip).r;
	float d3 = textureLod(source_depth, uv + vec2(off.x, off.y), params.source_mip).r;

	imageStore(dest_mip, dst_px, vec4(max(max(d0, d1), max(d2, d3))));
}
