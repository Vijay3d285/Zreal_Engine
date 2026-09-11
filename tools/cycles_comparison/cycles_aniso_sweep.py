# Cycles anisotropy sweep at roughness 0.4, RAW GGX (no multiscatter), framing
# matched to pt_anisotropy_gate.gd. Finds which Cycles anisotropy value
# reproduces our engine's 0.942444, which measures whether the parameter means
# the same thing on both sides.

import bpy
import math
import os
import sys

OUT = sys.argv[sys.argv.index("--") + 1]
RES = 256
SAMPLES = 1024
CAM_DIST = 2.5
CAM_FOV_DEG = 20.0
ROUGH = 0.4


def build(aniso):
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
    bsdf.distribution = "GGX"
    bsdf.inputs["Base Color"].default_value = (1, 1, 1, 1)
    bsdf.inputs["Metallic"].default_value = 1.0
    bsdf.inputs["Roughness"].default_value = ROUGH
    bsdf.inputs["Anisotropic"].default_value = aniso
    bsdf.inputs["Anisotropic Rotation"].default_value = 0.0
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
print("\n@@@ CYCLES ANISOTROPY SWEEP, roughness 0.4, RAW GGX @@@")
print("@@@ %8s %12s %14s" % ("aniso", "ratio", "ax (=a^2/asp)"))
for a in [0.0, 0.3, 0.5, 0.6, 0.7, 0.8, 0.9]:
    build(a)
    p = os.path.join(OUT, "sweep_%03d.exr" % int(a * 100))
    bpy.context.scene.render.filepath = p
    bpy.ops.render.render(write_still=True)
    r, n = stats(p)
    aspect = math.sqrt(1.0 - a * 0.9)
    print("@@@ %8.2f %12.6f %14.6f" % (a, r, (ROUGH * ROUGH) / aspect))
print("@@@ ours at anisotropy 0.90:  0.942444")
print("@@@ SWEEP DONE")
