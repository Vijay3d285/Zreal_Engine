# Car-paint comparison against Cycles -- roadmap section 7.10.1, RE-TAKEN 2026-09-11.
#
# Reproduces 7.10.1's three arms from its written parameters: metallic base
# roughness 0.25, base colour LINEAR (0.30, 0.05, 0.05), coat weight 1.0 /
# roughness 0.1 / ior 1.5, uniform world of radiance 1.0; plus an uncoated control
# and an amber-tinted arm at Coat Tint LINEAR (0.90, 0.75, 0.50).
#
# The original .blend and harness were never checked in and Blender 4.5.3 is gone,
# so this is a NEW measurement on 5.2.1, not a re-run.
#
# BOUNCES MATCHED at 3 to Godot's set_pathtracing_max_bounces(3). Bounce depth is
# not a free variable here -- a lone convex sphere cannot re-hit itself.
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

BASE_LINEAR = (0.30, 0.05, 0.05)
BASE_ROUGHNESS = 0.25
COAT_ROUGHNESS = 0.1
COAT_IOR = 1.5
TINT_LINEAR = (0.90, 0.75, 0.50)

# tag, coat weight, tinted
ARMS = [
    ("carpaint", 1.0, False),
    ("uncoated", 0.0, False),
    ("amber", 1.0, True),
]


def build(coat_weight, tinted, base_rgb):
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
    scene.view_settings.exposure = 0.0
    scene.view_settings.gamma = 1.0

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
    bsdf.inputs["Metallic"].default_value = 1.0
    bsdf.inputs["Roughness"].default_value = BASE_ROUGHNESS
    bsdf.inputs["Coat Weight"].default_value = coat_weight
    bsdf.inputs["Coat Roughness"].default_value = COAT_ROUGHNESS
    bsdf.inputs["Coat IOR"].default_value = COAT_IOR
    if tinted:
        bsdf.inputs["Coat Tint"].default_value = (TINT_LINEAR[0], TINT_LINEAR[1], TINT_LINEAR[2], 1.0)
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
    if not n:
        return float("nan"), [float("nan")] * 3, 0
    ch = [a / n for a in acc]
    return sum(ch) / 3.0, ch, n


os.makedirs(OUT, exist_ok=True)
print("\n@@@ CYCLES CAR PAINT (roadmap 7.10.1, re-taken) @@@")
print("@@@ blender: %s" % bpy.app.version_string)
print("@@@ Base LINEAR %s  base roughness %.2f  coat rough %.2f ior %.1f"
      % (BASE_LINEAR, BASE_ROUGHNESS, COAT_ROUGHNESS, COAT_IOR))
# Confirm the sockets exist under these names in THIS version, as 7.10.1 did.
bpy.ops.wm.read_factory_settings(use_empty=True)
_m = bpy.data.materials.new("probe")
_m.use_nodes = True
_names = [i.name for i in _m.node_tree.nodes["Principled BSDF"].inputs]
for want in ("Coat Weight", "Coat Roughness", "Coat IOR", "Coat Tint"):
    print("@@@ socket %-16s present=%s" % (want, want in _names))

results = []
for tag, cw, tinted in ARMS:
    build(cw, tinted, BASE_LINEAR)
    p = os.path.join(OUT, "carpaint_%s.exr" % tag)
    bpy.context.scene.render.filepath = p
    bpy.ops.render.render(write_still=True)
    m, ch, n = stats(p)
    results.append(m)
    print("@@@ %-10s coat=%.1f tinted=%-5s mean=%.8f  RGB=(%.8f,%.8f,%.8f)  n=%d"
          % (tag, cw, tinted, m, ch[0], ch[1], ch[2], n))

print("@@@ CARPAINT_CYCLES_REF := [%s]" % ", ".join("%.8f" % r for r in results))

# Colour-space positive control, as 7.10.1 had: feed Cycles the sRGB-ENCODED
# Base Color as if it were linear. Recorded ratio was 2.290434, +129.0%.
srgb_base = (0.58383155, 0.24780053, 0.24780053)
build(1.0, False, srgb_base)
p = os.path.join(OUT, "carpaint_srgbtrap.exr")
bpy.context.scene.render.filepath = p
bpy.ops.render.render(write_still=True)
trap, _ch, _n = stats(p)
print("@@@ CONTROL srgb-encoded Base Color: %.8f  ratio vs correct %.6f (+%.1f%%)"
      % (trap, trap / results[0], (trap / results[0] - 1.0) * 100.0))
print("@@@ DONE")
