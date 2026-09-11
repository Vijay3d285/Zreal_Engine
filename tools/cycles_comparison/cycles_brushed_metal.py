# Brushed-metal comparison against Cycles -- roadmap §7.8, RE-TAKEN 2026-09-11.
#
# Reproduces §7.8's Task-5 configuration from its written parameters: metallic
# sphere, roughness 0.4, anisotropy 0.6, anisotropy_rotation 0 and PI/2, under a
# spatially uniform world. The original .blend and harness were never checked into
# the repo and the Blender it used (4.5.3) is no longer installed, so this is a NEW
# measurement, not a re-run.
#
# COLOUR SPACE. Godot's albedo_color is sRGB as an artist types it and
# render_raytracing.cpp decodes it with srgb_to_linear() on upload. Base Color here
# is therefore the DECODED value 0.60382730, printed live by
# pt_anisotropy_gate.gd's probe 1e rather than assumed. Setting 0.8 here instead is
# the E2a trap and produces a ~33% error in the right direction to look plausible.
#
# ROTATION UNITS. Blender's Anisotropic Rotation is in TURNS
# (anisotropic_rotation * M_2PI_F in svm/closure.h), ours is radians. PI/2 rad is
# 0.25 turns.
#
# FRAMING is matched to pt_anisotropy_gate.gd -- camera at distance 2.5 with a
# 20 deg vertical FOV, so the sphere overfills the frame and both engines integrate
# the same mu range. Mismatched framing silently compares different integrals; see
# roadmap §11.2's correction.

import bpy
import math
import os
import sys

OUT = sys.argv[sys.argv.index("--") + 1]
RES = 256
SAMPLES = 2048
CAM_DIST = 2.5
CAM_FOV_DEG = 20.0

BASE_COLOR_LINEAR = 0.60382730  # srgb_to_linear(0.8), printed by probe 1e
ROUGHNESS = 0.4
ANISOTROPY = 0.6
ROTATIONS_TURNS = [0.0, 0.25]  # 0 and PI/2 radians


def build(rotation_turns, base_color):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    scene.cycles.device = "CPU"
    scene.cycles.samples = SAMPLES
    scene.cycles.use_denoising = False
    scene.cycles.max_bounces = 8
    scene.cycles.sample_clamp_direct = 0.0
    scene.cycles.sample_clamp_indirect = 0.0
    scene.render.resolution_x = RES
    scene.render.resolution_y = RES
    scene.render.film_transparent = True
    scene.render.image_settings.file_format = "OPEN_EXR"
    scene.render.image_settings.color_mode = "RGBA"
    scene.render.image_settings.color_depth = "32"
    scene.view_settings.view_transform = "Standard"

    world = bpy.data.worlds.new("W")
    scene.world = world
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs["Color"].default_value = (1, 1, 1, 1)
    world.node_tree.nodes["Background"].inputs["Strength"].default_value = 1.0

    bpy.ops.mesh.primitive_uv_sphere_add(segments=128, ring_count=64, radius=1.0)
    sphere = bpy.context.object
    bpy.ops.object.shade_smooth()

    mat = bpy.data.materials.new("M")
    mat.use_nodes = True
    nt = mat.node_tree
    bsdf = nt.nodes["Principled BSDF"]
    # Default distribution (MULTI_GGX) -- compensation ON, matching production.
    bsdf.inputs["Base Color"].default_value = (base_color, base_color, base_color, 1.0)
    bsdf.inputs["Metallic"].default_value = 1.0
    bsdf.inputs["Roughness"].default_value = ROUGHNESS
    bsdf.inputs["Anisotropic"].default_value = ANISOTROPY
    bsdf.inputs["Anisotropic Rotation"].default_value = rotation_turns
    tan = nt.nodes.new("ShaderNodeTangent")
    tan.direction_type = "RADIAL"
    tan.axis = "Z"
    nt.links.new(tan.outputs["Tangent"], bsdf.inputs["Tangent"])
    sphere.data.materials.append(mat)

    cam_data = bpy.data.cameras.new("Cam")
    cam_data.sensor_fit = "VERTICAL"
    cam_data.angle_y = math.radians(CAM_FOV_DEG)
    cam = bpy.data.objects.new("Cam", cam_data)
    scene.collection.objects.link(cam)
    scene.camera = cam
    k = CAM_DIST / math.sqrt(3.0)
    cam.location = (k, -k, k)
    con = cam.constraints.new("TRACK_TO")
    con.target = sphere
    con.track_axis = "TRACK_NEGATIVE_Z"
    con.up_axis = "UP_Y"


def stats(path):
    img = bpy.data.images.load(path)
    px = list(img.pixels)
    n = 0
    acc = 0.0
    for i in range(0, len(px), 4):
        if px[i + 3] > 0.99:
            acc += (px[i] + px[i + 1] + px[i + 2]) / 3.0
            n += 1
    bpy.data.images.remove(img)
    return (acc / n if n else float("nan")), n


os.makedirs(OUT, exist_ok=True)
print("\n@@@ CYCLES BRUSHED METAL (roadmap 7.8, re-taken) @@@")
print("@@@ blender: %s" % bpy.app.version_string)
print("@@@ Base Color LINEAR %.8f  roughness %.2f  anisotropy %.2f" % (BASE_COLOR_LINEAR, ROUGHNESS, ANISOTROPY))
means = []
for rot in ROTATIONS_TURNS:
    build(rot, BASE_COLOR_LINEAR)
    p = os.path.join(OUT, "brushed_rot%03d.exr" % int(rot * 1000))
    bpy.context.scene.render.filepath = p
    bpy.ops.render.render(write_still=True)
    m, n = stats(p)
    means.append(m)
    print("@@@ rotation %.2f turns (%.4f rad)  mean=%.6f  (n=%d)"
          % (rot, rot * 2.0 * math.pi, m, n))
cyc = sum(means) / len(means)
print("@@@ CYCLES mean of both rotations: %.6f" % cyc)

# POSITIVE CONTROL for the colour-space trap, exactly as the original had.
# Rendering with the RAW 0.8 must come out ~33% brighter; if it does not, the
# Base Color is not being interpreted as linear and the whole comparison is void.
build(0.0, 0.8)
p = os.path.join(OUT, "brushed_raw08.exr")
bpy.context.scene.render.filepath = p
bpy.ops.render.render(write_still=True)
raw08, n = stats(p)
print("@@@ CONTROL raw 0.8 Base Color: %.6f  ratio vs decoded %.6f (naive predict %.6f)"
      % (raw08, raw08 / means[0], 0.8 / BASE_COLOR_LINEAR))
print("@@@ ours (probe 1e):              0.587634")
print("@@@ DONE")
