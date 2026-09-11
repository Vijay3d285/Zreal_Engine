# Velvet comparison against Cycles -- roadmap section 7.11, RE-TAKEN 2026-09-11.
#
# Reproduces 7.11.1's four arms from its written parameters: dielectric base
# metallic 0 / roughness 0.60, base colour LINEAR (0.12, 0.02, 0.03), sheen colour
# LINEAR (0.75, 0.70, 0.55), uniform world of radiance 1.0, at sheen roughness
# 0.30 / 0.50 / 0.80 plus an un-sheened control. The original .blend and harness
# were never checked in and Blender 4.5.3 is gone, so this is a NEW measurement.
#
# sheen_color IS weight * tint. Godot's single sheen_color maps to Cycles'
# Sheen Weight * Sheen Tint (svm/closure.h forms the closure weight that way), so
# these arms set Weight = 1.0 and Tint to the colour.
#
# SHEEN ROUGHNESS IS LOAD-BEARING. Cycles' Zeltner LTC is invalid over most of its
# lowest roughness rows; an arm that leaves it at 0 renders no sheen at all and
# reads as a suspiciously perfect match. Every arm sets it explicitly.
#
# BOUNCES MATCHED at 3, to Godot's set_pathtracing_max_bounces(3).
# FRAMING matched: distance 2.5, 20 deg vertical FOV, 256x256, sphere overfills.

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
SHEEN_LINEAR = (0.75, 0.70, 0.55)
BASE_ROUGHNESS = 0.60

# tag, sheen roughness (None = un-sheened control)
ARMS = [
    ("velvetsharp", 0.30),
    ("velvet", 0.50),
    ("velvetrough", 0.80),
    ("nosheen", None),
]


def build(sheen_rough, base_rgb, sheen_rgb):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    scene.cycles.device = "CPU"
    scene.cycles.samples = SAMPLES
    scene.cycles.use_denoising = False
    scene.cycles.max_bounces = 3
    scene.cycles.diffuse_bounces = 3
    scene.cycles.glossy_bounces = 3
    scene.cycles.transmission_bounces = 3
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
    bsdf.inputs["Base Color"].default_value = (base_rgb[0], base_rgb[1], base_rgb[2], 1.0)
    bsdf.inputs["Metallic"].default_value = 0.0
    bsdf.inputs["Roughness"].default_value = BASE_ROUGHNESS
    if sheen_rough is None:
        bsdf.inputs["Sheen Weight"].default_value = 0.0
    else:
        bsdf.inputs["Sheen Weight"].default_value = 1.0
        bsdf.inputs["Sheen Tint"].default_value = (sheen_rgb[0], sheen_rgb[1], sheen_rgb[2], 1.0)
        bsdf.inputs["Sheen Roughness"].default_value = sheen_rough
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
print("\n@@@ CYCLES VELVET (roadmap 7.11, re-taken) @@@")
print("@@@ blender: %s" % bpy.app.version_string)
print("@@@ Base LINEAR %s  Sheen LINEAR %s  base roughness %.2f"
      % (BASE_LINEAR, SHEEN_LINEAR, BASE_ROUGHNESS))
# Confirm the sockets exist under these names in THIS version rather than
# assuming them from the manual -- 7.11 made a point of checking this.
bpy.ops.wm.read_factory_settings(use_empty=True)
_m = bpy.data.materials.new("probe")
_m.use_nodes = True
_names = [i.name for i in _m.node_tree.nodes["Principled BSDF"].inputs]
for want in ("Sheen Weight", "Sheen Tint", "Sheen Roughness"):
    print("@@@ socket %-16s present=%s" % (want, want in _names))

results = []
for tag, sr in ARMS:
    build(sr, BASE_LINEAR, SHEEN_LINEAR)
    p = os.path.join(OUT, "velvet_%s.exr" % tag)
    bpy.context.scene.render.filepath = p
    bpy.ops.render.render(write_still=True)
    m, n = stats(p)
    results.append(m)
    print("@@@ %-12s sheen_rough=%5s  mean=%.8f  (n=%d)"
          % (tag, ("--" if sr is None else "%.2f" % sr), m, n))

print("@@@ VELVET_CYCLES_REF := [%s]" % ", ".join("%.8f" % r for r in results))

# Colour-space positive control, as 7.11 had: feed Cycles the sRGB-ENCODED
# numbers an artist reads off the Godot inspector. Must come out much brighter.
srgb_base = (0.38109186, 0.15170372, 0.18974829)
srgb_sheen = (0.88082504, 0.85430586, 0.76737565)
build(0.50, srgb_base, srgb_sheen)
p = os.path.join(OUT, "velvet_srgbtrap.exr")
bpy.context.scene.render.filepath = p
bpy.ops.render.render(write_still=True)
trap, n = stats(p)
print("@@@ CONTROL srgb-encoded inputs: %.8f  ratio vs correct %.6f (+%.1f%%)"
      % (trap, trap / results[1], (trap / results[1] - 1.0) * 100.0))
print("@@@ DONE")
