/**************************************************************************/
/*  scene_shader_raytracing.h                                             */
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

#include "core/templates/local_vector.h"
#include "servers/rendering/renderer_rd/pipeline_hash_map_rd.h"
#include "servers/rendering/renderer_rd/renderer_scene_render_rd.h" // IWYU pragma: keep
#include "servers/rendering/renderer_rd/shaders/raytracing/scene_raytracing_raygen.glsl.gen.h"

namespace RendererSceneRenderImplementation {

class SceneShaderRaytracing {
private:
	static SceneShaderRaytracing *singleton;
	static Mutex singleton_mutex;

public:
	enum ShaderGroup {
		SHADER_GROUP_BASE, // Always compiled at the beginning.
		SHADER_GROUP_ADVANCED,
		SHADER_GROUP_MULTIVIEW,
		SHADER_GROUP_ADVANCED_MULTIVIEW,
	};

	enum ShaderVersion {
		SHADER_VERSION_OPAQUE, // Single simplified opaque pass
		SHADER_VERSION_MAX
	};

	enum ShaderColorPassFlags {
		SHADER_COLOR_PASS_FLAG_NONE = 0 // Simplified: no flags needed
	};

	enum PipelineVersion {
		PIPELINE_VERSION_OPAQUE, // Single simplified opaque pass
		PIPELINE_VERSION_MAX
	};

	enum PipelineColorPassFlags {
		PIPELINE_COLOR_PASS_FLAG_NONE = 0 // Simplified: no flags needed
	};

	// Raytracing specialization constant flags (must match shader RT_FLAG_* defines).
	// Bits 0-3:   Feature flags
	// Bits 4-8:   Russian Roulette min_bounce (roadmap B4, biased +1; see RT_MIN_BOUNCE_SHIFT)
	// Bit 9:      Emissive-mesh NEE (roadmap C1)
	// Bits 10-14: Transmission enable + bounce cap (roadmap E1)
	// Bits 15-17: Material feature gating (roadmap E3: anisotropy, coat, sheen)
	// Bit 18: Transmissive geometry; Bit 19: Free
	// Bits 20-27: Sample count
	// Bits 28-31: Max bounce count (offset by 1: 0=1 bounce, 15=16 bounces)
	// Bounces widened from 3 to 4 bits (Task 4, B3) to lift the ceiling from 8 to
	// 16; sample count's shift moved down by one to make room without touching
	// its own 8-bit width (the feature-flags region only ever used bits 0-3).
	enum RaytracingFlags {
		RT_FLAG_NONE = 0,
		RT_FLAG_DEBUG_VIS_ENABLED = (1 << 0),
		RT_FLAG_DLSS_RR_ENABLED = (1 << 1),
		RT_FLAG_FOG_ENABLED = (1 << 2),
		RT_FLAG_SER_ENABLED = (1 << 3),
		// Bits 4-8 belong to RT_MIN_BOUNCE (below), so the next feature flag is 9.
		RT_FLAG_EMISSIVE_LIGHTS_ENABLED = (1 << 9),
		RT_FLAG_TRANSMISSION_ENABLED = (1 << 10),
		// E3. Bits 15-17, from the free range documented above. NOT 11-14 --
		// those are RT_MAX_TRANSMISSION_BOUNCE (E1), and the collision would
		// corrupt that field's readback while leaving the render merely
		// plausible instead of visibly wrong.
		RT_FLAG_ANISOTROPY_ENABLED = (1 << 15),
		RT_FLAG_COAT_ENABLED = (1 << 16),
		RT_FLAG_SHEEN_ENABLED = (1 << 17),
		// Transparent shadows. Bit 18, next free after E3 took 15-17. NOT 11-14 --
		// those are RT_MAX_TRANSMISSION_BOUNCE and a collision would corrupt that
		// field's readback while leaving the render merely plausible.
		//
		// Unlike RT_FLAG_TRANSMISSION_ENABLED (an Environment toggle), this bit is
		// set from SCENE CONTENT: any material with transmission > 0. It exists so
		// a scene with no glass folds the pass-B loop away at specialization.
		RT_FLAG_TRANSMISSIVE_GEOMETRY = (1 << 18),
		// E3 subsurface. Bit 19. Scene content: any material with
		// sss_weight > 1e-5 (process_material). Folds the random walk, the
		// fifth registry lobe and the exit shading away for every other scene.
		RT_FLAG_SSS_ENABLED = (1 << 19),
		// F2 volumetrics: the Environment's volumetric fog is on with density > 0.
		// Bit 27 was the sample-count field's top bit; that field is 7 bits now
		// (max 127 samples per dispatch). MUST match raytracing_common_inc.glsl.
		RT_FLAG_VOLUME_ENABLED = (1 << 27),
	};

	constexpr static uint32_t RT_SAMPLE_COUNT_SHIFT = 20;
	constexpr static uint32_t RT_SAMPLE_COUNT_MASK = 0x7F; // 7 bits since F2; bit 27 is RT_FLAG_VOLUME_ENABLED

	constexpr static uint32_t RT_MAX_BOUNCES_SHIFT = 28;
	constexpr static uint32_t RT_MAX_BOUNCES_MASK = 0xF;

	// Russian Roulette minimum bounce (roadmap B4). Stored BIASED by +1 so that a
	// stored 0 means "unset" and resolves to the default: 0 is a legitimate
	// min_bounce (roulette from the first bounce), so it cannot double as the
	// sentinel the way PT_PARAM_MAX_DIFFUSE_BOUNCE's 0 does.
	// 5 bits so the range reaches 16 and Russian Roulette can be fully disabled at
	// max_bounces = 16. Bits 4-19 of the flags word were unused when this was
	// written; E1 took bits 11-14 for RT_MAX_TRANSMISSION_BOUNCE_SHIFT below --
	// updated here (E1 final fix wave, doc-fix list item 3) because its GLSL
	// twin (raytracing_common_inc.glsl) was updated correctly at the time and
	// this comment was the one left contradicting it.
	constexpr static uint32_t RT_MIN_BOUNCE_SHIFT = 4;
	constexpr static uint32_t RT_MIN_BOUNCE_MASK = 0x1F;

	// Transmission bounce cap (roadmap E1), bits 11-14. UNBIASED, 0 = unset --
	// unlike min_bounce, 0 is not a legitimate cap value. Range 1-15 rather than
	// 1-16 because the shader-side counter is 4 bits and saturates at 15.
	constexpr static uint32_t RT_MAX_TRANSMISSION_BOUNCE_SHIFT = 11;
	constexpr static uint32_t RT_MAX_TRANSMISSION_BOUNCE_MASK = 0xF;

	// TLAS instance cull masks. Every instance was pushed as 0xFF before
	// transparent shadows, so all eight bits were free; two are claimed here so the
	// shadow query can address opaque and transmissive geometry separately.
	// MIRRORED IN raytracing_common_inc.glsl -- change both together.
	constexpr static uint32_t RT_INSTANCE_MASK_OPAQUE = 0x01;
	constexpr static uint32_t RT_INSTANCE_MASK_TRANSMISSIVE = 0x02;
	// Cycles' per-object shadow visibility (Gap #30): an instance whose
	// cast_shadows is SHADOW_CASTING_SETTING_OFF gets ONLY this bit. Camera and
	// bounce rays trace with RT_INSTANCE_MASK_ALL and still hit it; shadow pass A
	// (OPAQUE) and pass B (TRANSMISSIVE) never do. Window glass with cast_shadow
	// off lets the sky and the sun in, as it does in Blender archviz.
	constexpr static uint32_t RT_INSTANCE_MASK_NO_SHADOW = 0x04;
	// Primary, indirect and DLSS-RR probe rays keep seeing everything.
	constexpr static uint32_t RT_INSTANCE_MASK_ALL = 0xFF;
	static_assert((RT_INSTANCE_MASK_NO_SHADOW & (RT_INSTANCE_MASK_OPAQUE | RT_INSTANCE_MASK_TRANSMISSIVE)) == 0,
			"NO_SHADOW must be invisible to both shadow passes");
	static_assert((RT_INSTANCE_MASK_OPAQUE & RT_INSTANCE_MASK_TRANSMISSIVE) == 0,
			"Opaque and transmissive instance masks must be disjoint, or pass A would "
			"see glass and occlude behind it while pass B attenuates it a second time");

	// Compile-time guard: a new RT_FLAG_* added at (1 << 4) or above would silently
	// alias the Russian Roulette min_bounce field, corrupt the readback, and leave
	// the rendered image merely plausible instead of visibly wrong. Keep this in
	// sync whenever RT_FLAG_* gains a member.
	static_assert(((RT_FLAG_DEBUG_VIS_ENABLED | RT_FLAG_DLSS_RR_ENABLED | RT_FLAG_FOG_ENABLED | RT_FLAG_SER_ENABLED | RT_FLAG_EMISSIVE_LIGHTS_ENABLED | RT_FLAG_TRANSMISSION_ENABLED | RT_FLAG_ANISOTROPY_ENABLED | RT_FLAG_COAT_ENABLED | RT_FLAG_SHEEN_ENABLED | RT_FLAG_TRANSMISSIVE_GEOMETRY | RT_FLAG_SSS_ENABLED) & (RT_MIN_BOUNCE_MASK << RT_MIN_BOUNCE_SHIFT)) == 0,
			"RT_FLAG_* bit overlaps the Russian Roulette min_bounce field (bits 4-8)");
	static_assert((RT_FLAG_VOLUME_ENABLED & ((RT_SAMPLE_COUNT_MASK << RT_SAMPLE_COUNT_SHIFT) | (RT_MAX_BOUNCES_MASK << RT_MAX_BOUNCES_SHIFT) | (RT_MAX_TRANSMISSION_BOUNCE_MASK << RT_MAX_TRANSMISSION_BOUNCE_SHIFT) | (RT_MIN_BOUNCE_MASK << RT_MIN_BOUNCE_SHIFT))) == 0,
			"RT_FLAG_VOLUME_ENABLED overlaps a packed field");

	// The transmission cap field must miss every neighbouring field. A collision
	// corrupts the neighbour's readback and leaves the render plausible rather
	// than visibly wrong.
	static_assert(((RT_MAX_TRANSMISSION_BOUNCE_MASK << RT_MAX_TRANSMISSION_BOUNCE_SHIFT) &
						  ((RT_MIN_BOUNCE_MASK << RT_MIN_BOUNCE_SHIFT) |
								  (RT_SAMPLE_COUNT_MASK << RT_SAMPLE_COUNT_SHIFT) |
								  (RT_MAX_BOUNCES_MASK << RT_MAX_BOUNCES_SHIFT) |
								  RT_FLAG_TRANSMISSIVE_GEOMETRY |
								  RT_FLAG_EMISSIVE_LIGHTS_ENABLED |
								  RT_FLAG_TRANSMISSION_ENABLED |
								  RT_FLAG_ANISOTROPY_ENABLED |
								  RT_FLAG_COAT_ENABLED |
								  RT_FLAG_SHEEN_ENABLED |
								  RT_FLAG_SSS_ENABLED)) == 0,
			"RT_MAX_TRANSMISSION_BOUNCE field (bits 11-14) overlaps another RT_FLAGS field");

	// RT pipeline limits (must match GLSL payload/hit attribute struct sizes).
	// 1: primary/bounce from raygen
	// 2: shadow ray from closest_hit (NEE)
	constexpr static uint32_t RT_MAX_RECURSION_DEPTH = 2;

	// Pathtracing parameter indices - aliased from the shared enum in rendering_server_enums.h.
	static constexpr int RT_PARAM_VIS_MODE = RSE::PT_PARAM_VIS_MODE;
	static constexpr int RT_PARAM_SAMPLE_COUNT = RSE::PT_PARAM_SAMPLE_COUNT;
	static constexpr int RT_PARAM_MAX_BOUNCES = RSE::PT_PARAM_MAX_BOUNCES;
	static constexpr int RT_PARAM_DENOISER = RSE::PT_PARAM_DENOISER;
	static constexpr int RT_PARAM_ACCUM_FLAG = RSE::PT_PARAM_ACCUM_FLAG;
	static constexpr int RT_PARAM_ACCUM_FRAMES = RSE::PT_PARAM_ACCUM_FRAMES;
	static constexpr int RT_PARAM_OIDN_FLAG = RSE::PT_PARAM_OIDN_FLAG;
	static constexpr int RT_PARAM_ACCUM_TARGET = RSE::PT_PARAM_ACCUM_TARGET;
	static constexpr int RT_PARAM_DLSS_RR_FINAL_FLAG = RSE::PT_PARAM_DLSS_RR_FINAL_FLAG;
	static constexpr int RT_PARAM_CLAMP_DIRECT = RSE::PT_PARAM_CLAMP_DIRECT;
	static constexpr int RT_PARAM_CLAMP_INDIRECT = RSE::PT_PARAM_CLAMP_INDIRECT;
	static constexpr int RT_PARAM_NOISE_THRESHOLD = RSE::PT_PARAM_NOISE_THRESHOLD;
	static constexpr int RT_PARAM_MAX_DIFFUSE_BOUNCE = RSE::PT_PARAM_MAX_DIFFUSE_BOUNCE;
	static constexpr int RT_PARAM_MAX_GLOSSY_BOUNCE = RSE::PT_PARAM_MAX_GLOSSY_BOUNCE;
	static constexpr int RT_PARAM_LIGHT_COUNT = RSE::PT_PARAM_LIGHT_COUNT;
	static constexpr int RT_PARAM_FRAME_INDEX = RSE::PT_PARAM_FRAME_INDEX;
	// F2 volumetrics: shader-side rt_params indices 16-34 (raytracing_inc.glsl).
	static constexpr int RT_PARAM_VOLUME_SIGMA_T = 16;
	static constexpr int RT_PARAM_VOLUME_G = 17;
	static constexpr int RT_PARAM_PORTAL_COUNT = 18; // live light portals (raytracing_portal_inc.glsl)
	static constexpr int RT_PARAM_VOLUME_ALBEDO_R = 20;
	static constexpr int RT_PARAM_VOLUME_EMISSION_R = 24;
	static constexpr int RT_PARAM_VOLUME_BOX_MIN_X = 28;
	static constexpr int RT_PARAM_VOLUME_BOX_MAX_X = 32;
	static constexpr int RT_PARAM_GUIDE_PROB = 35; // Gap #32: guiding mixture probability, 0 = off
	static constexpr int RT_PARAM_GUIDE_ORIGIN_X = 36; // ..38: guide grid origin (TLAS AABB min)
	static constexpr int RT_PARAM_GUIDE_CELL = 39; // guide voxel edge, metres; 0 = off

	static inline uint32_t rt_flags_pack(uint32_t p_flags, uint32_t p_sample_count, uint32_t p_max_bounces, uint32_t p_min_bounce, uint32_t p_max_transmission_bounce) {
		uint32_t result = p_flags;
		// Clamped, not masked: the field is 7 bits since F2 (bit 27 is
		// RT_FLAG_VOLUME_ENABLED), and a masked 128 would read as 0 -> 1 sample.
		result |= MIN(p_sample_count, RT_SAMPLE_COUNT_MASK) << RT_SAMPLE_COUNT_SHIFT;
		// Max bounces is offset by 1 (0=1 bounce, 15=16 bounces)
		result |= (MAX(1u, MIN(16u, p_max_bounces)) - 1u) << RT_MAX_BOUNCES_SHIFT;
		// Min bounce is offset by 1 so stored 0 can mean "unset" -- see above.
		result |= ((MIN(16u, p_min_bounce) + 1u) & RT_MIN_BOUNCE_MASK) << RT_MIN_BOUNCE_SHIFT;
		// Transmission cap is UNBIASED: 0 already means "unset" here.
		result |= (MIN(15u, p_max_transmission_bounce) & RT_MAX_TRANSMISSION_BOUNCE_MASK) << RT_MAX_TRANSMISSION_BOUNCE_SHIFT;
		return result;
	}

	// Build the full packed rt_flags from pathtracing environment params.
	// `p_env_params` may be null (RT active with no pathtracing environment).
	static uint32_t compute_rt_flags(const float *p_env_params, bool p_fog_enabled, bool p_volume_enabled);

	struct ShaderSpecialization {
		union {
			struct {
				uint32_t use_forward_gi : 1;
				uint32_t use_light_projector : 1;
				uint32_t use_light_soft_shadows : 1;
				uint32_t use_directional_soft_shadows : 1;
				uint32_t decal_use_mipmaps : 1;
				uint32_t projector_use_mipmaps : 1;
				uint32_t use_depth_fog : 1;
				uint32_t use_lightmap_bicubic_filter : 1;
				uint32_t soft_shadow_samples : 6;
				uint32_t penumbra_shadow_samples : 6;
				uint32_t directional_soft_shadow_samples : 6;
				uint32_t directional_penumbra_shadow_samples : 6;
			};

			uint32_t packed_0;
		};

		union {
			struct {
				uint32_t multimesh : 1;
				uint32_t multimesh_format_2d : 1;
				uint32_t multimesh_has_color : 1;
				uint32_t multimesh_has_custom_data : 1;
			};

			uint32_t packed_1;
		};

		uint32_t packed_2;
	};

	struct UbershaderConstants {
		union {
			struct {
				uint32_t cull_mode : 2;
			};

			uint32_t packed_0;
		};
	};

	struct ShaderData : public RendererRD::MaterialStorage::ShaderData {
		enum DepthDraw {
			DEPTH_DRAW_DISABLED,
			DEPTH_DRAW_OPAQUE,
			DEPTH_DRAW_ALWAYS
		};

		enum DepthTest {
			DEPTH_TEST_DISABLED,
			DEPTH_TEST_ENABLED
		};

		enum Cull {
			CULL_DISABLED,
			CULL_FRONT,
			CULL_BACK
		};

		enum CullVariant {
			CULL_VARIANT_NORMAL,
			CULL_VARIANT_REVERSED,
			CULL_VARIANT_DOUBLE_SIDED,
			CULL_VARIANT_MAX

		};

		enum AlphaAntiAliasing {
			ALPHA_ANTIALIASING_OFF,
			ALPHA_ANTIALIASING_ALPHA_TO_COVERAGE,
			ALPHA_ANTIALIASING_ALPHA_TO_COVERAGE_AND_TO_ONE
		};

		struct PipelineKey {
			RD::VertexFormatID vertex_format_id = 0;
			RD::FramebufferFormatID framebuffer_format_id = 0;
			RD::PolygonCullMode cull_mode = RD::POLYGON_CULL_MAX;
			RSE::PrimitiveType primitive_type = RSE::PRIMITIVE_MAX;
			PipelineVersion version = PipelineVersion::PIPELINE_VERSION_MAX;
			uint32_t color_pass_flags = 0;
			ShaderSpecialization shader_specialization = {};
			uint32_t wireframe = false;
			uint32_t ubershader = false;

			uint32_t hash() const {
				uint32_t h = hash_murmur3_one_64(vertex_format_id);
				h = hash_murmur3_one_32(framebuffer_format_id, h);
				h = hash_murmur3_one_32(cull_mode, h);
				h = hash_murmur3_one_32(primitive_type, h);
				h = hash_murmur3_one_32(version, h);
				h = hash_murmur3_one_32(color_pass_flags, h);
				h = hash_murmur3_one_32(shader_specialization.packed_0, h);
				h = hash_murmur3_one_32(shader_specialization.packed_1, h);
				h = hash_murmur3_one_32(shader_specialization.packed_2, h);
				h = hash_murmur3_one_32(wireframe, h);
				h = hash_murmur3_one_32(ubershader, h);
				return hash_fmix32(h);
			}
		};

		void _create_pipeline(PipelineKey p_pipeline_key);
		PipelineHashMapRD<PipelineKey, ShaderData, void (ShaderData::*)(PipelineKey)> pipeline_hash_map;

		RID version;
		RID raygen_version;

		static const uint32_t VERTEX_INPUT_MASKS_SIZE = SHADER_VERSION_MAX; // Simplified to just one shader version
		std::atomic<uint64_t> vertex_input_masks[VERTEX_INPUT_MASKS_SIZE] = {};

		Vector<ShaderCompiler::GeneratedCode::Texture> texture_uniforms;

		Vector<uint32_t> ubo_offsets;
		uint32_t ubo_size = 0;

		String code;

		DepthDraw depth_draw = DEPTH_DRAW_OPAQUE;
		DepthTest depth_test = DEPTH_TEST_ENABLED;

		int blend_mode = BLEND_MODE_MIX;
		int alpha_antialiasing_mode = ALPHA_ANTIALIASING_OFF;

		bool uses_point_size = false;
		bool uses_alpha = false;
		bool uses_blend_alpha = false;
		bool uses_alpha_clip = false;
		bool uses_alpha_antialiasing = false;
		bool uses_depth_prepass_alpha = false;
		bool uses_discard = false;
		bool uses_roughness = false;
		bool uses_normal = false;
		bool uses_tangent = false;
		bool uses_particle_trails = false;
		bool uses_normal_map = false;
		bool wireframe = false;

		bool unshaded = false;
		bool uses_vertex = false;
		bool uses_position = false;
		bool uses_sss = false;
		bool uses_transmittance = false;
		bool uses_screen_texture = false;
		bool uses_depth_texture = false;
		bool uses_normal_texture = false;
		bool uses_time = false;
		bool uses_vertex_time = false;
		bool uses_fragment_time = false;
		bool writes_modelview_or_projection = false;
		bool uses_world_coordinates = false;
		bool uses_screen_texture_mipmaps = false;
		Cull cull_mode = CULL_DISABLED;

		uint64_t last_pass = 0;
		uint32_t index = 0;

		_FORCE_INLINE_ bool uses_alpha_pass() const {
			bool has_read_screen_alpha = uses_screen_texture || uses_depth_texture || uses_normal_texture;
			bool has_base_alpha = (uses_alpha && (!uses_alpha_clip || uses_alpha_antialiasing)) || has_read_screen_alpha;
			bool has_blend_alpha = uses_blend_alpha;
			bool has_alpha = has_base_alpha || has_blend_alpha;
			bool no_depth_draw = depth_draw == DEPTH_DRAW_DISABLED;
			bool no_depth_test = depth_test == DEPTH_TEST_DISABLED;
			return has_alpha || has_read_screen_alpha || no_depth_draw || no_depth_test;
		}

		_FORCE_INLINE_ bool uses_depth_in_alpha_pass() const {
			bool no_depth_draw = depth_draw == DEPTH_DRAW_DISABLED;
			bool no_depth_test = depth_test == DEPTH_TEST_DISABLED;
			return (uses_depth_prepass_alpha || uses_alpha_antialiasing) && !(no_depth_draw || no_depth_test);
		}

		_FORCE_INLINE_ bool uses_shared_shadow_material() const {
			bool backface_culling = cull_mode == CULL_BACK;
			return !uses_particle_trails && !writes_modelview_or_projection && !uses_vertex && !uses_position && !uses_discard && !uses_depth_prepass_alpha && !uses_alpha_clip && !uses_alpha_antialiasing && backface_culling && !uses_point_size && !uses_world_coordinates && !wireframe;
		}

		virtual void set_code(const String &p_Code);

		virtual bool is_animated() const;
		virtual bool casts_shadows() const;
		virtual RenderingServerTypes::ShaderNativeSourceCode get_native_source_code() const;
		virtual Pair<ShaderRD *, RID> get_native_shader_and_version() const;
		ShaderVersion _get_shader_version(PipelineVersion p_pipeline_version, uint32_t p_color_pass_flags, bool p_ubershader) const;
		RID _get_shader_variant(ShaderVersion p_shader_version) const;
		void _clear_vertex_input_mask_cache();
		RID get_shader_variant(PipelineVersion p_pipeline_version, uint32_t p_color_pass_flags, bool p_ubershader) const;
		RID get_raygen_shader_variant() const;
		uint64_t get_vertex_input_mask(PipelineVersion p_pipeline_version, uint32_t p_color_pass_flags, bool p_ubershader);
		RD::PolygonCullMode get_cull_mode_from_cull_variant(CullVariant p_cull_variant);
		bool is_valid() const;

		SelfList<ShaderData> shader_list_element;
		ShaderData();
		virtual ~ShaderData();
	};

	SelfList<ShaderData>::List shader_list;

	RendererRD::MaterialStorage::ShaderData *_create_shader_func();
	static RendererRD::MaterialStorage::ShaderData *_create_shader_funcs() {
		return static_cast<SceneShaderRaytracing *>(singleton)->_create_shader_func();
	}

	static SceneShaderRaytracing *get_singleton();

	struct MaterialData : public RendererRD::MaterialStorage::MaterialData {
		ShaderData *shader_data = nullptr;
		RID uniform_set;
		uint64_t last_pass = 0;
		uint32_t index = 0;
		RID next_pass;
		uint8_t priority;
		virtual void set_render_priority(int p_priority);
		virtual void set_next_pass(RID p_pass);
		virtual bool update_parameters(const HashMap<StringName, Variant> &p_parameters, bool p_uniform_dirty, bool p_textures_dirty);
		virtual ~MaterialData();
	};

	RendererRD::MaterialStorage::MaterialData *_create_material_func(ShaderData *p_shader);
	static RendererRD::MaterialStorage::MaterialData *_create_material_funcs(RendererRD::MaterialStorage::ShaderData *p_shader) {
		return static_cast<SceneShaderRaytracing *>(singleton)->_create_material_func(static_cast<ShaderData *>(p_shader));
	}

	SceneRaytracingRaygenShaderRD raygen_shader;

	struct TextureUniformInfo {
		StringName name;
		ShaderLanguage::ShaderNode::Uniform::Hint hint = ShaderLanguage::ShaderNode::Uniform::HINT_NONE;
		bool use_color = false;
		bool is_global = false;
		uint32_t buffer_offset = 0; // Stored as bindless index in UBO
	};

	// Preprocessed custom HG GLSL (templates filled per compile). One entry per slot, all variants.
	struct CustomShaderEntry {
		String vertex_code;
		String fragment_code;
		String fragment_globals;
		String intersection_code;
		String intersection_globals;
		String uniform_members; // GLSL struct members for uniform buffer
		uint32_t uniform_total_size = 0;
		Vector<uint32_t> uniform_offsets;
		HashMap<StringName, ShaderLanguage::ShaderNode::Uniform> uniforms;
		Vector<TextureUniformInfo> texture_uniforms; // Sampler2D packed as bindless indices after UBO
		bool uses_alpha_clip = false; // Writes ALPHA_SCISSOR_THRESHOLD; needs per-HG any-hit
		bool is_procedural = false; // Uses intersection shader instead of triangle geometry
	};

	// 128-bit identity (dual hash64 with distinct salt). Treated as source equality.
	struct SourceHash128 {
		uint64_t a = 0;
		uint64_t b = 0;
		bool operator==(const SourceHash128 &p_o) const { return a == p_o.a && b == p_o.b; }
		bool is_zero() const { return a == 0 && b == 0; }
	};
	struct SourceHash128Hasher {
		static _FORCE_INLINE_ uint32_t hash(const SourceHash128 &p_h) {
			// Mix both halves so a-only collisions don't create bucket pile-ups.
			// Constant: integral part of the Golden Ratio's fractional part 0.61803398875… multiplied by 2^64
			return hash_one_uint64(p_h.a ^ (p_h.b * 0x9E3779B97F4A7C15ULL));
		}
	};

	enum class HGState : uint8_t {
		Empty,
		Pending, // Preprocessed; SPIR-V compile not done for this bundle yet.
		Ready, // Per-HG RID valid; next rebuild will publish.
		Failed, // Permanent compile failure for this slot in this bundle.
	};

	// Append-only by source hash. Index 0 = default HG.
	struct HitGroupSlot {
		SourceHash128 source_hash;
		HGState state = HGState::Empty;
		CustomShaderEntry entry;
	};

	LocalVector<HitGroupSlot> hit_group_slots;
	HashMap<SourceHash128, uint32_t, SourceHash128Hasher> source_hash_to_slot;

	// One RD RT pipeline variant (rt_flags key). Owns base + per-slot HG shaders (RG+miss baked in per HG).
	struct PipelineBundle {
		RID pipeline; // RD::free_rid on swap (deferred internally).
		RID hit_sbt; // RD::free_rid on swap.
		RID base_shader; // Immutable for variant lifetime; uniform_set is bound to this.

		// Parallel to hit_group_slots.
		LocalVector<RID> per_hg_shaders;
		LocalVector<HGState> per_hg_states;

		// Baked into current pipeline (TLAS skip / is_hg_ready_in_bundle).
		LocalVector<bool> live_ready_mask;
		uint32_t live_hg_count = 0;

		bool dirty = false;
		bool initial_pipeline_built = false;
	};

	HashMap<uint32_t, PipelineBundle> pipeline_bundles;

	// Single-lane async bundle rebuild (worker: SPIR-V + raytracing_pipeline_create; main: SBT + swap).
	struct PipelineBuildTask;
	struct CompileLane {
		Mutex mutex;
		PipelineBuildTask *current = nullptr;
		LocalVector<PipelineBuildTask *> queue;
	};

	uint32_t register_custom_shader(uint32_t p_shader_id, RID p_material);
	uint32_t register_procedural_shader(uint32_t p_shader_id, RID p_material);

	const CustomShaderEntry *get_custom_shader_entry(uint32_t p_slot_index) const;
	uint32_t get_hit_group_slot_count() const { return hit_group_slots.size(); }

	bool is_hg_ready_in_bundle(uint32_t p_slot_index, uint32_t p_rt_flags) const;
	void drain_completed_compiles();
	void finalize_custom_shaders();

	const PipelineBundle &ensure_pipeline_bundle(uint32_t p_rt_flags);

	RID get_raytracing_pipeline(uint32_t p_rt_flags) { return ensure_pipeline_bundle(p_rt_flags).pipeline; }
	RID get_hit_sbt(uint32_t p_rt_flags) { return ensure_pipeline_bundle(p_rt_flags).hit_sbt; }
	RID get_pipeline_base_shader(uint32_t p_rt_flags) { return ensure_pipeline_bundle(p_rt_flags).base_shader; }

	// Uniform set layout shader (same as base_shader).
	RID get_pipeline_shader_rd(uint32_t p_rt_flags) { return ensure_pipeline_bundle(p_rt_flags).base_shader; }

private:
	// Source-hash slot management.
	uint32_t _register_slot(uint32_t p_shader_id, RID p_material, bool p_is_procedural);
	bool _preprocess_shader(RID p_material, bool p_is_procedural, CustomShaderEntry &r_entry);
	void _strip_texture_globals(String &r_globals, const String &p_tex_name);
	void _finalize_uniforms_with_textures(CustomShaderEntry &r_entry, const ShaderCompiler::GeneratedCode &p_gen_code, const HashMap<StringName, ShaderLanguage::ShaderNode::Uniform> &p_uniforms, bool p_strip_intersection_globals);

	// Bundle build / rebuild.
	void _bundle_resize_for_slots(PipelineBundle &r_bundle);
	bool _build_initial_bundle(uint32_t p_rt_flags, PipelineBundle &r_bundle);
	void _kick_rebuild_if_idle();

	// Compile lane / worker.
	void _enqueue_build(PipelineBuildTask *p_task);
	void _dispatch_next_locked(); // CompileLane::mutex MUST be held.
	void _build_pipeline_worker(PipelineBuildTask *p_task);
	static void _build_pipeline_worker_static(void *p_userdata);
	void _finalize_pipeline_build(PipelineBuildTask *p_task);
	void _drain_lane_inline_main_thread();
	void _join_lane_for_shutdown();
	PipelineBuildTask *_make_pipeline_build_task(uint32_t p_rt_flags, PipelineBundle &p_bundle);

	// Eager/late stage assembly bits cached per variant for compile workers.
	struct VariantCompileContext {
		Vector<RD::ShaderStageSPIRVData> base_non_hit_stages; // RAYGEN + MISS spirv.
		RD::ShaderStageSPIRVData base_any_hit_stage; // Used when slot doesn't override AH.
		bool base_any_hit_valid = false;
		String ch_template; // Template GLSL with /* RT_CUSTOM_* */ markers.
		String ah_template;
		String is_template;
	};
	HashMap<uint32_t, VariantCompileContext> variant_compile_contexts;

	bool _ensure_variant_compile_context(uint32_t p_rt_flags);

	bool async_compilation_enabled = true;
	Mutex spirv_compile_mutex; // Serialize glslang calls (RD::shader_compile_spirv_from_source).
	CompileLane compile_lane;

public:
	void invalidate_pipeline_bundles();

	ShaderCompiler compiler;

	RID default_shader;
	RID default_material;
	RID overdraw_material_shader;
	RID overdraw_material;
	RID debug_shadow_splits_material_shader;
	RID debug_shadow_splits_material;
	RID default_shader_rd;
	RID raygen_shader_version;
	RID default_shader_sdfgi_rd;

	RID default_vec4_xform_buffer;
	RID default_vec4_xform_uniform_set;

	RID shadow_sampler;

	RID default_material_uniform_set;
	ShaderData *default_material_shader_ptr = nullptr;

	RID overdraw_material_uniform_set;
	ShaderData *overdraw_material_shader_ptr = nullptr;

	RID debug_shadow_splits_material_uniform_set;
	ShaderData *debug_shadow_splits_material_shader_ptr = nullptr;

	ShaderSpecialization default_specialization = {};

	uint32_t pipeline_compilations[RSE::PIPELINE_SOURCE_MAX] = {};

	~SceneShaderRaytracing();

	void init(const String p_defines);
	void set_default_specialization(const ShaderSpecialization &p_specialization);
	void enable_advanced_shader_group(bool p_needs_multiview = false);
	bool is_multiview_shader_group_enabled() const;
	bool is_advanced_shader_group_enabled(bool p_multiview) const;
	uint32_t get_pipeline_compilations(RSE::PipelineSource p_source);

protected:
	SceneShaderRaytracing();
};

} // namespace RendererSceneRenderImplementation
