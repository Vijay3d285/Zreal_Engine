# Gap #21 investigation: split the -1.87% dielectric-base deficit into a DIFFUSE
# part and a SPECULAR part.
#
# Same base as section 7.11's un-sheened control -- metallic 0, roughness 0.60,
# base LINEAR (0.12, 0.02, 0.03), uniform world radiance 1.0, bounces 3, framing
# matched -- rendered twice:
#
#   full_dielectric  Specular IOR Level 0.5 (Godot's metallic_specular default)
#   diffuse_only     Specular IOR Level 0.0, which makes f0 = 0 hence eta = 1,
#                    and svm/closure.h skips the specular component entirely.
#
# Godot's equivalent of the second is metallic_specular = 0, which drives
# resolveDielectricF0's f0_untinted term (*= 4*specular*specular) to exactly 0.

import bpy
import math
import os
import sys

OUT = sys.argv[sys.argv.index("--") + 1]
RES = 256
SAMPLES = 2048
CAM_DIST = 2.5
CAM_FOV_DEG = 20.0
BASE_LINEAR = (0.12, 0.02, 0.03)
BASE_ROUGHNESS = 0.60


BASE_OVERRIDE = None


def build(spec_level):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    scene.cycles.device = "CPU"
    scene.cycles.samples = SAMPLES
    scene.cycles.use_denoising = False
    scene.cycles.use_adaptive_sampling = False
    scene.cycles.max_bounces = 3
    scene.cycles.diffuse_bounces = 3
    scene.cycles.glossy_bounces = 3
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
    _b = BASE_OVERRIDE if BASE_OVERRIDE is not None else BASE_LINEAR
    bsdf.inputs["Base Color"].default_value = (_b[0], _b[1], _b[2], 1.0)
    bsdf.inputs["Metallic"].default_value = 0.0
    bsdf.inputs["Roughness"].default_value = BASE_ROUGHNESS
    bsdf.inputs["Sheen Weight"].default_value = 0.0
    bsdf.inputs["Specular IOR Level"].default_value = spec_level
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
print("@@@ GAP 21 SPLIT: diffuse vs specular @@@")
print("@@@ blender: %s" % bpy.app.version_string)
res = {}
for lvl, tag in [(0.5, "full_dielectric"), (0.0, "diffuse_only")]:
    build(lvl)
    p = os.path.join(OUT, "g21_%s.exr" % tag)
    bpy.context.scene.render.filepath = p
    bpy.ops.render.render(write_still=True)
    m, ch, n = stats(p)
    res[tag] = m
    print("@@@ %-16s SpecIORLevel=%.2f mean=%.8f RGB=(%.8f,%.8f,%.8f) n=%d"
          % (tag, lvl, m, ch[0], ch[1], ch[2], n))
print("@@@ analytic Lambert mean for (0.12,0.02,0.03) = %.8f" % ((0.12 + 0.02 + 0.03) / 3.0))
print("@@@ Cycles full-minus-diffuse = %.8f" % (res["full_dielectric"] - res["diffuse_only"]))
print("@@@ ours: full 0.08786238  diffuse-only 0.05665236  full-minus-diffuse 0.03121002")
globals()["BASE_OVERRIDE"] = (0.0, 0.0, 0.0)
build(0.5)
p = os.path.join(OUT, "g21_specular_only.exr")
bpy.context.scene.render.filepath = p
bpy.ops.render.render(write_still=True)
m, ch, n = stats(p)
print("@@@ %-16s BLACK base, SpecIORLevel=0.50 mean=%.8f n=%d" % ("specular_only", m, n))
print("@@@ ours specular_only 0.03349182")
print("@@@ DONE")
