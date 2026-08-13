/**************************************************************************/
/*  render_raytracing.h                                                   */
/**************************************************************************/
/*                         This file is part of:                          */
/*                             GODOT ENGINE                               */
/*                        https://godotengine.org                         */
/**************************************************************************/
/* Copyright (c) 2014-present Godot Engine contributors (see AUTHORS.md). */
/* Copyright (c) 2007-2014 Juan Linietsky, Ariel Manzur.                  */
/*                                                                        */
/* Permission is hereby granted, free of charge, to any person obtaining  */
/* a copy of this software and associated documentation files (the        */
/* "Software"), to deal in the Software without restriction, including    */
/* without limitation the rights to use, copy, modify, merge, publish,    */
/* distribute, sublicense, and/or sell copies of the Software, and to     */
/* permit persons to whom the Software is furnished to do so, subject to  */
/* the following conditions:                                              */
/*                                                                        */
/* The above copyright notice and this permission notice shall be         */
/* included in all copies or substantial portions of the Software.        */
/*                                                                        */
/* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,        */
/* EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF     */
/* MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. */
/* IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY   */
/* CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,   */
/* TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE      */
/* SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.                 */
/**************************************************************************/

#pragma once

#include "core/math/transform_3d.h"
#include "core/math/vector2i.h"
#include "core/string/string_name.h"
#include "core/templates/hash_map.h"
#include "core/templates/local_vector.h"
#include "core/templates/rid_owner.h"
#include "core/templates/vector.h"
#include "servers/rendering/renderer_rd/bindless_block.h"
#include "servers/rendering/renderer_rd/shaders/raytracing/multimesh_merge.glsl.gen.h"
#include "servers/rendering/renderer_rd/storage_rd/emissive_lights.h"
#include "servers/rendering/renderer_rd/storage_rd/env_cdf.h"
#include "servers/rendering/renderer_rd/storage_rd/ies_manager.h"
#include "servers/rendering/rendering_device.h"

#define RB_TEX_RAYTRACING SNAME("raytracing")
#define RB_TEX_RT_DEPTH SNAME("rt_depth")
// Phase A: persistent accumulation buffers for still-image convergence.
#define RB_TEX_RAYTRACING_ACCUM SNAME("rt_accum")       // running-average radiance (R32G32B32A32_SFLOAT)
#define RB_TEX_RAYTRACING_ACCUM_N SNAME("rt_accum_n") // sample count per pixel (R32_SFLOAT)
#define RB_TEX_RAYTRACING_VARIANCE SNAME("rt_variance") // Welford (mean_luma, M2) per pixel (R32G32_SFLOAT)

#define RB_SCOPE_DLSS_RR SNAME("dlss_rr")
#define RB_TEX_DLSS_RR_DIFFUSE_ALBEDO SNAME("diffuse_albedo")
#define RB_TEX_DLSS_RR_SPECULAR_ALBEDO SNAME("specular_albedo")
#define RB_TEX_DLSS_RR_NORMAL_ROUGHNESS SNAME("normal_roughness")
#define RB_TEX_DLSS_RR_SPECULAR_HIT_DIST SNAME("specular_hit_dist")

class RenderDataRD;
class RenderSceneBuffersRD;

namespace RendererSceneRenderImplementation {

class RenderForwardClustered;
class SceneShaderRaytracing;

// Must match GLSL GeometryData (std430, 128 bytes).
struct alignas(16) RT_GeometryData {
	uint64_t vertex_buffer_address;
	uint64_t attribute_buffer_address;
	uint64_t index_buffer_address;
	uint32_t vertex_count;
	uint32_t position_stride;
	uint32_t normal_byte_offset;
	uint32_t normal_stride;
	uint32_t tangent_byte_offset;
	uint32_t tangent_stride;
	uint32_t attribute_stride;
	uint32_t uv_byte_offset;
	uint32_t uv_scale_packed;
	uint32_t index_format;
	uint32_t primitive_count;
	uint32_t flags;
	float aabb_size_x;
	float aabb_size_y;
	float aabb_size_z;
	uint32_t color_byte_offset;
	float aabb_pos_x;
	float aabb_pos_y;
	float aabb_pos_z;
	// For deformed geometry: previous-frame position buffer used for motion vectors.
	uint32_t prev_vertex_buffer_address_lo;
	uint32_t prev_vertex_buffer_address_hi;
	uint32_t _pad[5];
};
static_assert(sizeof(RT_GeometryData) == 128, "RT_GeometryData must be 128 bytes for std430");

/// Per-instance motion data for velocity computation (matches GLSL InstanceMotionData, 48 bytes).
struct RT_InstanceMotionData {
	float prev_object_to_world[12]; // Previous object-to-world (mat3x4, transposed 3x4).
};
static_assert(sizeof(RT_InstanceMotionData) == 48, "RT_InstanceMotionData must be 48 bytes");

// Must match GLSL MaterialData (std430, 96 bytes).
struct alignas(16) RT_MaterialData {
	uint32_t albedo_texture_idx;
	uint32_t normal_texture_idx;
	uint32_t orm_texture_idx;
	uint32_t emission_texture_idx;
	float albedo_color[4];
	float emission_color[3];
	float emission_strength;
	float metallic;
	float roughness;
	float ao_strength;
	uint32_t flags;
	float uv1_scale[2];
	float uv1_offset[2];
	float normal_map_depth; // Strength [0..N], default 1.0 (not Z-depth).
	float specular; // Dielectric specular [0..1], default 0.5 -> F0 = 0.04.
	uint64_t uniform_address; // BDA for custom shader uniform buffer (0 = none).
};
static_assert(sizeof(RT_MaterialData) == 96, "RT_MaterialData must be 96 bytes for std430");

// Light types for raytracing (matches GLSL RT_LIGHT_TYPE_* defines).
enum RTLightType : uint32_t {
	RT_LIGHT_TYPE_OMNI = 0,
	RT_LIGHT_TYPE_DIRECTIONAL = 1,
	RT_LIGHT_TYPE_RECT = 2,
	RT_LIGHT_TYPE_SPOT = 3,
};

// Must match GLSL RTLightData (std430, 160 bytes).
struct alignas(16) RT_LightData {
	float position[3]; // World position (omni/spot) or direction (directional, normalized).
	uint32_t type;
	float emission[3];
	float radius;
	float attenuation;
	float inv_max_range; // 1.0/range, or -1.0 for infinite.
	float max_range_squared; // range*range, or 0.0 for infinite.
	float specular_amount;
	float indirect_energy;
	float inv_spot_attenuation;
	float cos_spot_angle;
	float shadow_enabled; // 1.0 = trace shadow rays normally. 0.0 = skip shadow ray (shadowless fill light).
	float spot_direction[3];
	float rect_half_height; // rect: half-height scalar (0 for non-rect)
	float rect_axis_v[3]; // rect: axisV half-height world vector
	float _pad2;
	int32_t ies_slot; // IES photometric profile slot index, -1 = none.
	float ies_strength; // IES intensity multiplier.
	// Light basis columns in world space: [0..2] = local X axis, [3..5] = local Y,
	// [6..8] = local Z. IES profiles are evaluated in the light's own frame (where
	// the fixture aims along local -Z, Godot's light convention and the same as
	// Blender/Cycles), so the shader needs the world->local rotation. The basis is
	// orthonormalized on upload, so that rotation is the transpose: three dot
	// products against these columns. Only read when ies_slot >= 0.
	float ies_basis[9];
	float _ies_pad[2]; // Pad to 128 bytes.
};
static_assert(sizeof(RT_LightData) == 160, "RT_LightData must be 160 bytes for std430");
static_assert(offsetof(RT_LightData, ies_basis) == 104, "RT_LightData::ies_basis must sit at offset 104 to match std430");
static_assert(offsetof(RT_LightData, rect_half_height) == 76, "RT_LightData::rect_half_height must sit at offset 76 to match std430");
static_assert(offsetof(RT_LightData, rect_axis_v) == 80, "RT_LightData::rect_axis_v must sit at offset 80 to match std430");
static_assert(offsetof(RT_LightData, ies_slot) == 96, "RT_LightData::ies_slot must sit at offset 96 to match std430");


enum {
	RT_LIGHTS_MAX = 64,
	RT_LIGHTS_FRUSTUM_BUDGET = 48,
	RT_LIGHTS_INDIRECT_BUDGET = RT_LIGHTS_MAX - RT_LIGHTS_FRUSTUM_BUDGET,
};

enum {
	RT_OFFSET_NONE = 0xFFFFFFFFu,
	RT_CACHE_CHUNK_SIZE = 256,
	RT_CACHE_CHUNK_SHIFT = 8,
	RT_CACHE_CHUNK_MASK = 255,
};

// Material flags for RT (matches GLSL mat_flags bit layout).
enum {
	RT_MAT_FLAG_HAS_NORMAL_MAP = 1u,
	RT_MAT_FLAG_HAS_EMISSION_TEX = 2u,
	RT_MAT_FLAG_POINT_FILTER = 4u,
};

// Index format for RT geometry (matches GLSL fetch_indices).
enum {
	RT_INDEX_FORMAT_UINT16 = 0,
	RT_INDEX_FORMAT_UINT32 = 1,
	RT_INDEX_FORMAT_NONE = 2,
};

enum {
	RT_GEOM_FLAG_COMPRESSED = 1u,
	RT_GEOM_FLAG_PROCEDURAL = 2u,
	// Set when the BLAS uses a per-frame-deformed vertex buffer.
	RT_GEOM_FLAG_DEFORMED = 4u,
};

/// Per-instance state for procedural RT geometry. Heap-allocated, only exists for procedural instances.
struct RTProceduralState {
	AABB culling_aabb;
	PackedFloat32Array aabb_data; // N * 6 floats (min/max per AABB). Empty = single AABB.
	bool expose_bounds = false;
	bool dirty = true;
	RID blas;
	RID gpu_buffer;
	uint32_t gpu_buffer_capacity = 0; // Bytes, grow-only.
	uint64_t gpu_buffer_address = 0; // BDA (0 = not exposed).
	uint32_t aabb_count = 0;
};

struct RTSurfaceData {
	RID blas;
	RT_GeometryData geometry = {};
	Transform3D aabb_transform;
	bool is_compressed = false;
	uint64_t blas_size = 0;
};

/// Inputs for a surface backed by a per-frame-deformed vertex buffer.
struct RTDeformedGeometrySource {
	RID current_vb; ///< Vertex buffer (object-space positions) the BLAS is built / refit against.
	RID prev_vb; ///< Previous-frame positions for motion vectors. Optional.
	uint64_t change_stamp = 0; ///< Changes when `current_vb` contents change.
	uint64_t cache_key = 0; ///< Caller-defined cache identity.
	uint32_t cache_version = 0; ///< Changes when the resource behind `cache_key` is recycled.
	uint32_t surface_counter = 0; ///< Changes when the underlying mesh surface changes.
};

struct RTMaterialData {
	alignas(16) RT_MaterialData data = {};
	uint32_t global_buffer_index = UINT32_MAX;
	uint32_t rt_sbt_offset = 0;
	bool is_custom_shader = false;
	RID uniform_buffer; // Buffer pointer for mats > 512 bytes.
	uint32_t uniform_pool_slot = UINT32_MAX; // Index into the material UBO pool, or UINT32_MAX (unused)
	RID albedo_texture_rd;
	RID normal_texture_rd;
	RID orm_texture_rd;
	RID emission_texture_rd;
};

struct RTCacheEntry {
	RTSurfaceData *ptr = nullptr;
	uint32_t last_used_frame = 0;
	uint32_t cached_counter = 0;
	uint32_t cached_rid_version = 0;
	uint8_t failed_attempts = 0;
	uint64_t size_bytes = 0;
};

/// BLAS cache entry for a surface driven by a per-frame-deformed vertex buffer.
///
/// The skinned vertex buffer is owned by the engine's MeshInstance system and may
/// be freed/reallocated outside our control. To decouple BLAS lifetime from that
/// (and keep last-frame positions alive for motion vectors) we copy the skinned VB
/// into our own buffers each frame:
///   * owned_vb_full mirrors the skinned VB layout (positions + N + T) and is what
///     the BLAS and the hit shader read from this frame.
///   * prev_pos_vb stores the previous-frame positions only (float3 packed) for the
///     motion-vector path. Updated from owned_vb_full's position section each frame
///     before owned_vb_full is overwritten with the new skinned data.
struct RTDeformedCacheEntry {
	RTSurfaceData *ptr = nullptr;
	uint32_t last_used_frame = 0;
	uint64_t cached_change_stamp = 0;
	uint32_t cached_key_version = 0;
	uint32_t cached_surface_counter = 0;
	uint64_t cached_buffer_id = 0; // RID id of the deformed vertex buffer at the time of build.
	bool blas_built_once = false; // True once the BLAS has been fully built; subsequent ticks can refit.

	RID owned_vb_full;
	uint32_t owned_vb_full_capacity = 0; // Bytes; grow-only.
	RID prev_pos_vb;
	uint32_t prev_pos_vb_capacity = 0; // Bytes; grow-only.
	uint32_t cached_vertex_count = 0;
	uint32_t cached_full_size = 0;
	bool prev_pos_seeded = false; // False until the first owned->prev copy has run.
};

/// Cache entry for a per-(MultiMesh, surface) merged BLAS.
/// All vertex data (positions, normals, tangents, UVs, colors) is fully baked per-instance
/// so the hit shader uses the standard code path — no special per-instance lookups.
struct RTMergedMMEntry {
	// Merged vertex buffer: [float3 pos × N*V] + [packed TBN × N*V] (if mesh has normals).
	// The BLAS reads only the position section; the hit shader reads TBN via normal_byte_offset.
	RID merged_vtx_buffer;
	uint32_t vtx_capacity_bytes = 0;

	// Merged attribute buffer: [UV + color × N*V] replicated per instance.
	RID merged_attr_buffer;
	uint32_t attr_capacity_bytes = 0;

	// Replicated index buffer: uint32 N*I entries (invalid if non-indexed).
	RID replicated_idx_buffer;
	uint32_t idx_capacity = 0;

	RID blas;
	uint32_t last_mm_count = 0;
	uint32_t last_surface_counter = 0;
	uint32_t last_used_frame = 0;
	uint64_t cached_mm_last_change = 0;
	bool blas_built_once = false;
	bool indexed = false; // selects MODE_INDEXED vs MODE_NON_INDEXED variant
};

struct RTMaterialCacheEntry {
	RTMaterialData *ptr = nullptr;
	uint32_t last_used_frame = 0;
	uint16_t cached_counter = 0;
	uint32_t cached_rid_version = 0;
};

/// Per-viewport raytracing state.
///
/// Each viewport has its own visibility set (frustum/LOD/visibility ranges), so
/// the TLAS instance composition and per-instance SSBO contents differ across
/// viewports. Sharing them caused the wrong `gl_InstanceCustomIndexEXT` to
/// resolve to the wrong `geometries[]` / `materials[]` entries, dereferencing
/// stale BDAs and faulting the GPU.
///
/// Lifetime is tied to a `RenderSceneBuffersRD`: created lazily on first
/// `build_tlas` for that viewport, freed via `RenderRaytracing::free_viewport_state`
/// from `RenderBufferDataForwardClustered::free_data()`.
struct RTViewportState {
	RID tlas;
	uint32_t tlas_max_instances = 0;

	RID geometry_buffer;
	uint32_t geometry_buffer_capacity = 0;
	RID material_buffer;
	uint32_t material_buffer_capacity = 0;
	RID motion_index_buffer;
	uint32_t motion_index_buffer_capacity = 0;
	RID motion_transform_buffer;
	uint32_t motion_transform_buffer_capacity = 0;

	RID light_buffer;
	RID ies_buffer; // GPU SSBO for packed IES photometric profile data.
	uint32_t ies_buffer_bytes = 0; // Tracks allocated size to detect resize need.
	RID params_buffer;

	uint32_t frame_counter = 0;

	// Phase A accumulation state (per-viewport). The accumulator blends 1-SPP
	// renders across frames for still-image convergence. It must reset (clear
	// the accum buffer + sample count) when the camera moves or the viewport
	// is resized; otherwise the running average would smear the old view.
	bool accum_enabled = false;          // mirrors env PT_PARAM_ACCUM_FLAG this viewport.
	uint32_t accum_frame = 0;            // 0-based accumulation frame for the current view.
	Transform3D accum_last_cam_transform; // last camera transform seen; mismatch => reset.
	Size2i accum_last_size;              // last internal render size; mismatch => reset (resize).
	bool accum_reset_pending = true;     // clear accum/accum_n to 0 before the next trace.
	// Phase F: one-shot OIDN final-denoise bookkeeping. Set true once a converged OIDN
	// denoise has been applied this accumulation cycle so it does not re-fire every frame
	// (OIDN is non-temporal; it must run once after convergence, not per frame). Reset to
	// false on the same events that clear the accumulator (camera move / resize / accumulate
	// toggle) so the next convergence cycle denoises again.
	bool oidn_denoise_done = false;
	// Phase F2: DLSS-RR "reconstruct final" warmup bookkeeping. DLSS-RR is temporal, so to
	// capture a high-quality still we feed it the SAME converged accumulator image over N
	// warmup frames: reset=true on the first warmup frame (flushes history), then reset=false
	// for the rest so the neural reconstructor's history accumulates converged (noise-free)
	// frames. `dlss_rr_warmup_left` counts down to 0; once 0, `dlss_rr_final_done` stops the
	// per-frame dispatch so tonemap/capture freeze at the warmed result. Reset to {0, false}
	// on the same events that clear the accumulator so each convergence cycle re-warms.
	int dlss_rr_warmup_left = 0;
	bool dlss_rr_final_done = false;
};

class RenderRaytracing {
	friend class RenderForwardClustered;

	RenderForwardClustered *owner = nullptr;
	SceneShaderRaytracing *shader = nullptr;
	BindlessBlock *bindless_block = nullptr;

	RID bindless_uniform_set;

	// Caching (chunked sparse caches indexed by RID low bits / 256).
	Vector<RTCacheEntry *> surface_chunks;
	Vector<RTMaterialCacheEntry *> material_chunks;

	// Merged MultiMesh BLAS cache and compute shader.
	struct MergeShader {
		enum Mode {
			MODE_NON_INDEXED = 0,
			MODE_INDEXED = 1,
			MODE_MAX,
		};
		MultimeshMergeShaderRD shader;
		RID version;
		RID version_shader[MODE_MAX];
		RID pipeline[MODE_MAX];
	} mm_merge_shader;

	// Environment sampling distribution over the sky (sky NEE / MIS). Owned here
	// rather than per-viewport: the distribution depends only on the sky's
	// radiance octmap, not on viewport visibility, and the shader + pipeline are
	// worth sharing. Rebuilt when the bound radiance texture changes.
	EnvCDF env_cdf;

	// Stand-in bound at set 0 binding 34 when `env_cdf` has no buffer yet.
	// MeshStorage's shared default storage buffer is created WITHOUT initial data
	// (mesh_storage.cpp), so its bytes are undefined -- and the GLSL EnvDistRO
	// block's second float is `marginal_total`, the single value both env_sample()
	// and env_pdf_from_uv() gate on. A garbage-positive pattern there would let the
	// shader binary-search `data[]` past the end of a 16-byte buffer. This one is
	// zero-filled at creation, so `marginal_total == 0.0` and both entry points
	// return before touching `data[]`. 16 bytes is deliberately the minimum the RD
	// backend will allocate, not FLOAT_COUNT floats: the shader never reads past
	// the two scalars when the gate fails.
	RID env_dist_fallback_buffer;
	RID _get_env_dist_fallback_buffer();

	// Power-weighted sampling distribution over emissive mesh instances (C1).
	//
	// Owned here alongside `env_cdf` so the shader and pipeline are shared. Note
	// the asymmetry with `env_cdf` though: the sky is viewport-independent, but
	// the emissive INSTANCE SET is not -- each viewport has its own visibility
	// set, so each produces a different set and therefore a different rebuild
	// token. With more than one path-traced viewport live, the token alternates
	// every frame and the build re-runs once per viewport per frame. That stays
	// CORRECT (the token is over the data, so whatever is built matches what was
	// gathered); it is only wasted work. The build is a <= 256-workgroup area
	// reduction plus a 256-entry serial scan, so the waste is small -- but if a
	// scene with many path-traced viewports ever makes it measurable, the fix is
	// to move this (and its per-frame scratch below) into RTViewportState, the
	// way `geometry_buffer` / `light_buffer` already are.
	RendererRD::EmissiveLights emissive_lights;
	// Result of this frame's `rendering/pathtracer/emissive_mesh_lights` read.
	// The feature ships default-OFF, so the false path is the one that runs in
	// every existing scene: it skips the gather and the build entirely and binds
	// the zero-filled fallback below.
	bool emissive_active = false;
	LocalVector<RendererRD::EmissiveLights::InstanceInput> emissive_inputs;
	LocalVector<int32_t> emissive_slots;
	/// Per-frame-baked vertex buffers the emissive build reads via BDA, handed to
	/// EmissiveLights::update() so it can manufacture a render-graph edge against
	/// whatever rebaked them. These are the merged MultiMesh vertex buffers; the
	/// graph cannot see a BDA read, so without this the area pass has no declared
	/// ordering against multimesh_merge.glsl. Not read by us.
	LocalVector<RID> emissive_ordering_srcs;

	// Stand-in bound at set 0 bindings 35-37 when emissive-mesh lights are off (or
	// the distribution has not been built yet). Same reasoning as
	// `env_dist_fallback_buffer` above: MeshStorage's shared default storage
	// buffer is created WITHOUT initial data, so its bytes are undefined -- and
	// the first float of the CDF block is `total_power`, the single value every
	// consumer gates on. A garbage-positive pattern there would let the shader
	// walk `prefix[]` and index `emissive_slot[]` past the end of a 16-byte
	// buffer. This one is zero-filled at creation, so `total_power == 0.0` and
	// consumers return before touching either array.
	RID emissive_fallback_buffer;
	RID _get_emissive_fallback_buffer();

	struct MMSurfaceHandles {
		LocalVector<RID> per_surface; // Grown on demand; entry per touched surface index.
		uint32_t mm_validator = 0; // High 32 bits of MM RID id at last access.

		// Resolve / grow storage for `p_surface_index`.
		RID &surface_handle(uint32_t p_surface_index) {
			if (p_surface_index >= per_surface.size()) {
				per_surface.resize(p_surface_index + 1);
			}
			return per_surface[p_surface_index];
		}
	};
	LocalVector<MMSurfaceHandles> mm_handles;

	RID_Owner<RTDeformedCacheEntry> deformed_pool;
	LocalVector<RID> deformed_active_this_frame;

	RID_Owner<RTMergedMMEntry> merged_mm_pool;
	LocalVector<RID> merged_mm_active_this_frame;

	RTDeformedCacheEntry *_access_deformed_slot(RID &r_handle);
	RTMergedMMEntry *_access_merged_mm_slot(RID &r_handle);

	LocalVector<uint32_t> material_free_slots;
	uint32_t next_material_slot = 0;
	uint64_t vram_used = 0;
	uint32_t cache_hits = 0;
	uint32_t cache_misses = 0;

	// Per-frame scratch arrays.
	LocalVector<RT_GeometryData> geometry_data;
	LocalVector<RT_MaterialData> material_data;
	LocalVector<int32_t> motion_indices; ///< Per-instance: index into motion_transforms[], or -1.
	LocalVector<RT_InstanceMotionData> motion_transforms; ///< Compact: only moving instances.
	LocalVector<RID> blass;
	LocalVector<Transform3D> blas_transforms;
	LocalVector<uint32_t> instance_flags;
	LocalVector<uint8_t> instance_masks; // Per-instance ray mask (0x00 = invisible to rays, 0xFF = normal)
	LocalVector<uint32_t> sbt_offsets; // 0 = default material hit group
	/// TLAS instance index -> merged-MultiMesh rebake stamp, for instances that
	/// came from the merged-MM path. Sparse on purpose: a merged MultiMesh
	/// contributes one TLAS instance per surface, so this holds a handful of
	/// entries at most, and every other instance carries no stamp. Consumed by
	/// gather_emissive_instances(), which folds it into the emissive rebuild
	/// token -- a merged MM bakes its transforms into vertices, so nothing else
	/// the token sees changes when its instances move.
	HashMap<uint32_t, uint64_t> merged_mm_instance_stamps;

	HashMap<RenderSceneBuffersRD *, RTViewportState *> viewport_states;

	RTViewportState *_get_or_create_viewport_state(const RenderDataRD *p_render_data);
	RTViewportState *_get_viewport_state(const RenderDataRD *p_render_data) const;
	void _free_viewport_state_internal(RTViewportState *p_state);

	// Material UBO sub-allocation pool. One large device-address buffer divided
	// into fixed-size slots for performance reasons, and easier to debug.
	RID mat_ubo_pool_buffer;
	uint64_t mat_ubo_pool_bda = 0;
	LocalVector<uint32_t> mat_ubo_pool_free_slots;
	uint32_t mat_ubo_pool_free_count = 0;
	uint32_t mat_ubo_pool_next_slot = 0;

	void mat_ubo_pool_ensure_initialized();
	uint32_t mat_ubo_pool_allocate(); // Returns slot index or UINT32_MAX if pool is exhausted.
	void mat_ubo_pool_release(uint32_t p_slot);
	void mat_ubo_pool_update(uint32_t p_slot, const void *p_data, uint32_t p_size);
	uint64_t mat_ubo_pool_get_address(uint32_t p_slot) const;

	// Cache helpers.
	static uint32_t get_rid_index(RID p_rid);
	static uint32_t get_rid_version(RID p_rid);
	RTCacheEntry *get_surface_cache_entry(uint32_t p_index);
	RTMaterialCacheEntry *get_material_cache_entry(uint32_t p_index);
	uint32_t allocate_material_slot();

	// Internal methods.
	RTSurfaceData *process_surface(
			const void *p_surf,
			void *p_mesh_surface,
			uint32_t p_surface_invalidation_counter,
			const Transform3D &p_transform,
			LocalVector<RID> &r_dirty_blas_list);
	RTSurfaceData *process_deformed_surface(
			const void *p_surf,
			void *p_mesh_surface,
			const struct RTDeformedGeometrySource &p_source,
			LocalVector<RID> &r_dirty_blas_list,
			LocalVector<RID> &r_dirty_blas_update_list);
	void _populate_surface_blas(
			void *p_mesh_surface,
			RID p_vertex_buffer_override,
			bool p_force_uncompressed,
			bool p_prefer_fast_build,
			bool p_allow_update,
			uint32_t p_cache_key,
			RTSurfaceData *r_surf_data,
			LocalVector<RID> &r_dirty_blas_list);
	RTMaterialData *process_material(RID p_material_rid, uint16_t p_material_invalidation_counter);
	bool _build_merged_mm_blas(
			RID p_mm_rid,
			RID p_mm_gpu_buffer,
			void *p_mesh_surface,
			uint32_t p_mm_count,
			uint32_t p_surface_index,
			uint32_t p_surface_counter,
			RD::ComputeListID p_compute_list,
			LocalVector<RID> &r_dirty_blas_list,
			LocalVector<RID> &r_dirty_blas_update_list,
			RTSurfaceData *r_surf_data);
	void update_procedural_blas(RTProceduralState *p_state, LocalVector<RID> &r_dirty_blas_list);
	void build_acceleration_structures(RTViewportState *p_state, const LocalVector<RID> &p_dirty_blas_list, const LocalVector<RID> &p_dirty_blas_update_list);
	void finalize_buffers(RTViewportState *p_state);
	void prepare_frame();

public:
	void initialize(RenderForwardClustered *p_owner);

	void cleanup_caches();

	RTViewportState *build_tlas(const RenderDataRD *p_render_data, uint32_t p_rt_flags);
	uint32_t gather_lights(const RenderDataRD *p_render_data, RT_LightData *r_light_data, uint32_t p_max_lights);
	/// Walks this frame's per-instance arrays and collects the emissive ones.
	/// Returns the number kept (<= EmissiveLights::INSTANCES_MAX). `r_slots` is
	/// sized to the FULL instance count, -1 where the instance is not emissive.
	/// `r_token` is the rebuild trigger; see the comment on the implementation.
	uint32_t gather_emissive_instances(LocalVector<RendererRD::EmissiveLights::InstanceInput> &r_out,
			LocalVector<int32_t> &r_slots, uint64_t &r_token);
	RID update_uniform_set(RTViewportState *p_state, const RenderDataRD *p_render_data, uint32_t p_rt_flags);

	void copy_output_texture(const RenderDataRD *p_render_data);
	void free_viewport_state(RenderSceneBuffersRD *p_render_buffers);

	void register_raytracing_buffer_dependencies(RD::RaytracingListID p_list);

	SceneShaderRaytracing *get_shader() const { return shader; }

	RID get_bindless_uniform_set() const { return bindless_uniform_set; }
	RID get_mat_ubo_pool_buffer() const { return mat_ubo_pool_buffer; }

	~RenderRaytracing();
};

} // namespace RendererSceneRenderImplementation
