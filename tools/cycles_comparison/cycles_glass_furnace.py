# White glass furnace against Cycles -- roadmap Gap #20 (section 11.14).
#
# A solid sphere of lossless dielectric (Transmission Weight 1.0, IOR 1.5, white
# base, no absorption) under a uniform world of radiance 1.0, at a roughness
# sweep. A lossless dielectric returns 1.0 once multi-scatter is compensated;
# Cycles' Multiscatter GGX glass compensates with 1/E_glass from ggx_glass_E /
# ggx_glass_Eavg (and the inverse-IOR pair on exit), applied to both lobes.
#
# BOUNCES MATTER for glass -- internal reflections -- so both engines run 12
# and the comparison is at matched depth, with the analytic 1.0 printed as a
# diagnostic. Godot side: pipeline_references/tests/pt_glass_energy_gate.gd.
# FRAMING matched: distance 2.5 along (1,1,1), 20 deg vertical FOV, 256x256.

import bpy
import math
import os
import sys

OUT = sys.argv[sys.argv.index("--") + 1]
RES = 256
SAMPLES = 2048
CAM_DIST = 2.5
CAM_FOV_DEG = 20.0
BOUNCES = 12
IOR = 1.5
ROUGHNESS = [0.0, 0.3, 0.6, 0.9]


def build(roughness):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    scene.cycles.device = "CPU"
    scene.cycles.samples = SAMPLES
    scene.cycles.use_denoising = False
    scene.cycles.use_adaptive_sampling = False
    scene.cycles.max_bounces = BOUNCES
    scene.cycles.diffuse_bounces = BOUNCES
    scene.cycles.glossy_bounces = BOUNCES
    scene.cycles.transmission_bounces = BOUNCES
    scene.cycles.transparent_max_bounces = BOUNCES
    scene.cycles.caustics_reflective = True
    scene.cycles.caustics_refractive = True
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

    bpy.ops.mesh.primitive_uv_sphere_add(segments=64, ring_count=32, radius=1.0)
    sphere = bpy.context.object
    bpy.ops.object.shade_smooth()

    mat = bpy.data.materials.new("M")
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (1.0, 1.0, 1.0, 1.0)
    bsdf.inputs["Metallic"].default_value = 0.0
    bsdf.inputs["Roughness"].default_value = roughness
    bsdf.inputs["IOR"].default_value = IOR
    bsdf.inputs["Transmission Weight"].default_value = 1.0
    bsdf.inputs["Sheen Weight"].default_value = 0.0
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
    return bsdf


def stats(path):
    img = bpy.data.images.load(path)
    px = list(img.pixels)
    n = 0
    acc = [0.0, 0.0, 0.0]
    for i in range(0, len(px), 4):
        if px[i + 3] > 0.99:
            acc[0] += px[i]
            acc[1] += px[i + 1]
            acc[2] += px[i + 2]
            n += 1
    bpy.data.images.remove(img)
    ch = [a / n for a in acc]
    return sum(ch) / 3.0, ch, n


os.makedirs(OUT, exist_ok=True)
print("")
print("@@@ WHITE GLASS FURNACE vs Cycles @@@")
print("@@@ blender: %s" % bpy.app.version_string)
for r in ROUGHNESS:
    bsdf = build(r)
    if r == ROUGHNESS[0]:
        print("@@@ distribution: %s  subsurface_method: %s" % (bsdf.distribution, bsdf.subsurface_method))
    p = os.path.join(OUT, "glass_r%.1f.exr" % r)
    bpy.context.scene.render.filepath = p
    bpy.ops.render.render(write_still=True)
    m, ch, n = stats(p)
    print("@@@ rough=%.2f  mean=%.8f RGB=(%.8f,%.8f,%.8f) n=%d  vs 1.0 %+.3f%%"
          % (r, m, ch[0], ch[1], ch[2], n, (m - 1.0) * 100.0))
print("@@@ DONE")
