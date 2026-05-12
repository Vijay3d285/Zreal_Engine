#[compute]

#version 450

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

// ── Input: per-instance data (read-only, written by CPU at scene build) ──

struct InstanceData {
	vec3 aabb_min;
	float lod_dist_0;
	vec3 aabb_max;
	float lod_dist_1;
	uint mesh_index;
	uint material_batch;
	uint flags;
	uint lod_level;
};

layout(std430, set = 0, binding = 0) readonly buffer InstanceBuffer {
	InstanceData instances[];
};

// ── Output: one draw command per surviving instance ──

struct DrawIndexedIndirectCommand {
	uint index_count;
	uint instance_count; // set to 1 by cull; 0 = culled
	uint first_index;
	int vertex_offset;
	uint first_instance; // encodes InstanceID for vertex shader lookup
};

layout(std430, set = 0, binding = 1) buffer DrawBuffer {
	DrawIndexedIndirectCommand draws[];
};

// ── Output: per-batch draw count (read by vkCmdDrawIndirectCount) ──

layout(std430, set = 0, binding = 2) buffer DrawCount {
	uint draw_counts[]; // one per material batch
};

// ── HZB for occlusion culling ──

layout(set = 0, binding = 3) uniform sampler2D hzb;

layout(push_constant, std430) uniform CullParams {
	mat4 view_proj; // VP matrix for frustum plane extraction
	vec4 frustum_planes[6]; // pre-extracted frustum planes (world space)
	vec3 camera_pos;
	float _pad0;
	vec2 hzb_size; // HZB texture size (mip 0)
	uint instance_count;
	uint _pad1;
}
params;

// ── Helpers ──────────────────────────────────────────────────────────────

// Returns true if AABB is outside the half-space of this plane.
bool outside_plane(vec4 plane, vec3 p_aabb_min, vec3 p_aabb_max) {
	vec3 positive = vec3(
			plane.x >= 0.0 ? p_aabb_max.x : p_aabb_min.x,
			plane.y >= 0.0 ? p_aabb_max.y : p_aabb_min.y,
			plane.z >= 0.0 ? p_aabb_max.z : p_aabb_min.z);
	return dot(plane.xyz, positive) + plane.w < 0.0;
}

bool frustum_cull(vec3 p_aabb_min, vec3 p_aabb_max) {
	for (int i = 0; i < 6; i++) {
		if (outside_plane(params.frustum_planes[i], p_aabb_min, p_aabb_max)) {
			return true; // culled
		}
	}
	return false;
}

// Project AABB into NDC, compute screen coverage, sample HZB.
bool occlusion_cull(vec3 p_aabb_min, vec3 p_aabb_max) {
	// Transform all 8 AABB corners into clip space.
	vec2 ndc_min = vec2(1e9);
	vec2 ndc_max = vec2(-1e9);
	float z_max = 0.0;
	for (int i = 0; i < 8; i++) {
		vec3 corner = vec3(
				(i & 1) != 0 ? p_aabb_max.x : p_aabb_min.x,
				(i & 2) != 0 ? p_aabb_max.y : p_aabb_min.y,
				(i & 4) != 0 ? p_aabb_max.z : p_aabb_min.z);
		vec4 clip = params.view_proj * vec4(corner, 1.0);
		if (clip.w <= 0.0) {
			return false; // behind camera — do NOT cull
		}
		vec3 ndc = clip.xyz / clip.w;
		ndc_min = min(ndc_min, ndc.xy);
		ndc_max = max(ndc_max, ndc.xy);
		z_max = max(z_max, ndc.z); // farthest depth of AABB
	}

	// UV of AABB in screen space.
	vec2 uv_min = ndc_min * 0.5 + 0.5;
	vec2 uv_max = ndc_max * 0.5 + 0.5;

	// Off-screen — skip occlusion test, do not cull (frustum handled above).
	if (uv_max.x < 0.0 || uv_min.x > 1.0 ||
			uv_max.y < 0.0 || uv_min.y > 1.0) {
		return false;
	}

	// Choose HZB mip: the mip where AABB footprint <= 2x2 texels.
	vec2 screen_size = (uv_max - uv_min) * params.hzb_size;
	float mip = ceil(log2(max(screen_size.x, screen_size.y)));
	mip = clamp(mip, 0.0, 10.0);

	// Sample HZB at the footprint centre — conservative max depth.
	vec2 uv_centre = (uv_min + uv_max) * 0.5;
	float hzb_depth = textureLod(hzb, uv_centre, mip).r;

	// If AABB's nearest depth is behind HZB sample -> occluded.
	return z_max > hzb_depth + 0.001;
}

uint select_lod(float dist_sq, InstanceData inst) {
	float d = sqrt(dist_sq);
	if (d > inst.lod_dist_1) {
		return 2u;
	}
	if (d > inst.lod_dist_0) {
		return 1u;
	}
	return 0u;
}

// ── Main ─────────────────────────────────────────────────────────────────

void main() {
	uint idx = gl_GlobalInvocationID.x;
	if (idx >= params.instance_count) {
		return;
	}

	InstanceData inst = instances[idx];

	// ── 1. Frustum cull ────────────────────────────────────────────────
	if (frustum_cull(inst.aabb_min, inst.aabb_max)) {
		return;
	}

	// ── 2. LOD selection ──────────────────────────────────────────────
	vec3 centre = (inst.aabb_min + inst.aabb_max) * 0.5;
	float dist_sq = dot(centre - params.camera_pos, centre - params.camera_pos);
	uint lod = select_lod(dist_sq, inst);

	// ── 3. Occlusion cull (uses previous frame HZB) ───────────────────
	if (occlusion_cull(inst.aabb_min, inst.aabb_max)) {
		return;
	}

	// ── 4. Write draw command ─────────────────────────────────────────
	// Draw index = instance index (one draw slot pre-allocated per instance).
	// The indirect draw buffer is pre-filled with vertex/index data for
	// each LOD level. We just need to set instance_count = 1 to activate.
	uint draw_idx = idx; // 1 slot per instance
	draws[draw_idx].instance_count = 1; // activate this draw
	draws[draw_idx].first_instance = idx; // vertex shader reads from here

	// Increment batch count (used by vkCmdDrawIndirectCount).
	atomicAdd(draw_counts[inst.material_batch], 1u);
}
