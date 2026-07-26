# unreal_post_fx.gd
# ─────────────────────────────────────────────────────────────────────
# Attach as a CompositorEffect on your Camera3D's Compositor resource.
# Runs a compute shader every frame after the transparent pass.
# Implements: ACES / AgX tonemapping, CDL color grading, vignette,
# chromatic aberration, and film grain — like Unreal's post-process stack.
# Requires Godot 4.3+ with Forward+ or Mobile renderer.
# ─────────────────────────────────────────────────────────────────────
@tool
extends CompositorEffect
class_name UnrealPostFX

# ── Exposed settings ───────────────────────────────────────────────────
@export_group("Exposure & Tonemap")
@export var exposure: float = 0.72
@export_enum("ACES Filmic", "AgX", "Reinhard") var tonemap_mode: int = 0

@export_group("Color Grading (CDL)")
@export var lift: Color = Color(0.025, 0.0, -0.02)   # Warm shadows: +orange, -blue
@export var gamma_grade: Color = Color(1.0, 1.0, 1.0)
@export var gain: Color = Color(1.04, 1.0, 0.94)      # Warm highlights: +red, -blue
@export var saturation: float = 1.15
@export var contrast: float = 1.35

@export_group("Lens")
@export_range(0.0, 1.0) var vignette_strength: float = 0.45
@export_range(0.1, 1.0) var vignette_softness: float = 0.6
@export_range(0.0, 0.01) var chromatic_aberration: float = 0.002

@export_group("Film Grain")
@export_range(0.0, 0.1) var grain_strength: float = 0.025

# ── Private state ──────────────────────────────────────────────────────
var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID

# ── Embedded compute shader ────────────────────────────────────────────
# Push-constant layout (std430, 96 bytes total):
#   vec4[0]  screen_size.xy | time | exposure
#   vec4[1]  tonemap_mode   | saturation | contrast | _pad
#   vec4[2]  vignette_str   | vignette_soft | chromatic | grain_str
#   vec4[3]  lift.rgb       | 0
#   vec4[4]  gamma.rgb      | 0
#   vec4[5]  gain.rgb       | 0
const SHADER_SRC := """
#[compute]
#version 450
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform restrict image2D color_image;

layout(push_constant, std430) uniform Params {
    vec2  screen_size;
    float time;
    float exposure;
    float tonemap_mode;
    float saturation;
    float contrast;
    float _pad0;
    float vignette_str;
    float vignette_soft;
    float chromatic;
    float grain_str;
    vec4  lift;
    vec4  gamma_grade;
    vec4  gain;
} p;

// ── ACES Filmic (Hill 2016) ─────────────────────────────────────────
vec3 aces(vec3 x) {
    const float a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14;
    return clamp((x*(a*x+b)) / (x*(c*x+d)+e), 0.0, 1.0);
}

// ── AgX (Sobotka 2023, simplified) ─────────────────────────────────
vec3 agx(vec3 col) {
    const mat3 m = mat3(
        vec3(0.8425, 0.0423, 0.0424),
        vec3(0.0784, 0.8785, 0.0784),
        vec3(0.0792, 0.0792, 0.8791));
    col = m * col;
    col = clamp((log2(max(col, 1e-6)) + 12.47) / 16.50, 0.0, 1.0);
    return 0.5 + 0.5 * tanh(3.0 * (col - 0.5));
}

// ── Reinhard ────────────────────────────────────────────────────────
vec3 reinhard(vec3 x) { return x / (1.0 + x); }

// ── CDL colour grading (lift / gamma / gain) ────────────────────────
vec3 cdl(vec3 col) {
    col = col * p.gain.rgb + p.lift.rgb;
    col = pow(max(col, vec3(0.0)), 1.0 / max(p.gamma_grade.rgb, vec3(0.001)));
    return col;
}

// ── Fast hash for film grain ─────────────────────────────────────────
float hash21(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void main() {
    ivec2 px = ivec2(gl_GlobalInvocationID.xy);
    if (px.x >= int(p.screen_size.x) || px.y >= int(p.screen_size.y)) return;

    vec2 uv  = (vec2(px) + 0.5) / p.screen_size;
    vec2 uvc = uv - 0.5;

    // ── Chromatic aberration ─────────────────────────────────────────
    float ca  = p.chromatic * length(uvc);
    vec3 col;
    col.r = imageLoad(color_image, ivec2((uvc*(1.0+ca)+0.5)*p.screen_size)).r;
    col.g = imageLoad(color_image, px).g;
    col.b = imageLoad(color_image, ivec2((uvc*(1.0-ca)+0.5)*p.screen_size)).b;

    // ── Exposure ─────────────────────────────────────────────────────
    col *= p.exposure;

    // ── Tonemapping ──────────────────────────────────────────────────
    int mode = int(round(p.tonemap_mode));
    if      (mode == 0) col = aces(col);
    else if (mode == 1) col = agx(col);
    else                col = reinhard(col);

    // ── CDL colour grading ───────────────────────────────────────────
    col = cdl(col);

    // ── Saturation (luma-preserving) ─────────────────────────────────
    float luma = dot(col, vec3(0.2126, 0.7152, 0.0722));
    col = mix(vec3(luma), col, p.saturation);

    // ── Contrast (S-curve around 0.5) ───────────────────────────────
    col = (col - 0.5) * p.contrast + 0.5;
    col = clamp(col, 0.0, 1.0);

    // ── Vignette ─────────────────────────────────────────────────────
    float dist = length(uvc) * 1.41421;
    float vig  = smoothstep(p.vignette_str, p.vignette_str - p.vignette_soft, dist);
    col *= vig;

    // ── Film grain ───────────────────────────────────────────────────
    float grain = (hash21(uv + fract(p.time * 0.073)) - 0.5) * p.grain_str;
    col = clamp(col + grain, 0.0, 1.0);

    imageStore(color_image, px, vec4(col, 1.0));
}
"""

# ── Lifecycle ──────────────────────────────────────────────────────────
func _init() -> void:
    effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
    RenderingServer.call_on_render_thread(_initialize_compute.bind())

func _notification(what: int) -> void:
    if what == NOTIFICATION_PREDELETE:
        _free_gpu_resources()

func _initialize_compute() -> void:
    _rd = RenderingServer.get_rendering_device()
    if not _rd:
        push_error("UnrealPostFX: RenderingDevice unavailable (use Forward+ or Mobile).")
        return
    var src := RDShaderSource.new()
    src.source_compute = SHADER_SRC
    var spirv := _rd.shader_compile_spirv_from_source(src)
    if spirv.compile_error_compute != "":
        push_error("UnrealPostFX shader error: " + spirv.compile_error_compute)
        return
    _shader   = _rd.shader_create_from_spirv(spirv)
    _pipeline = _rd.compute_pipeline_create(_shader)

# ── Render callback (called by the engine every frame) ─────────────────
func _render_callback(_type: int, render_data: RenderData) -> void:
    if not _rd or not _pipeline.is_valid(): return
    var scene_buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
    if not scene_buffers: return
    var size: Vector2i = scene_buffers.get_internal_size()
    if size.x == 0 or size.y == 0: return

    # Build push-constant bytes (96 bytes = 24 floats)
    var t := float(Time.get_ticks_msec()) * 0.001
    var pc := PackedFloat32Array([
        size.x, size.y, t, exposure,
        float(tonemap_mode), saturation, contrast, 0.0,
        vignette_strength, vignette_softness, chromatic_aberration, grain_strength,
        lift.r, lift.g, lift.b, 0.0,
        gamma_grade.r, gamma_grade.g, gamma_grade.b, 0.0,
        gain.r, gain.g, gain.b, 0.0,
    ]).to_byte_array()

    for view in scene_buffers.get_view_count():
        var img := scene_buffers.get_color_layer(view)

        var uni := RDUniform.new()
        uni.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
        uni.binding = 0
        uni.add_id(img)
        var uni_set := UniformSetCacheRD.get_cache(_shader, 0, [uni])

        var cl := _rd.compute_list_begin()
        _rd.compute_list_bind_compute_pipeline(cl, _pipeline)
        _rd.compute_list_bind_uniform_set(cl, uni_set, 0)
        _rd.compute_list_set_push_constant(cl, pc, pc.size())
        _rd.compute_list_dispatch(cl,
            ceili(size.x / 8.0),
            ceili(size.y / 8.0), 1)
        _rd.compute_list_end()

func _free_gpu_resources() -> void:
    if _rd:
        if _pipeline.is_valid(): _rd.free_rid(_pipeline)
        if _shader.is_valid():   _rd.free_rid(_shader)
