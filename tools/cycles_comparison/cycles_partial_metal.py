# Partial-metallic comparison against Cycles -- the case the real-asset render of
# 2026-09-11 (roadmap section 11.13) showed to be the largest visible effect of
# Gap #21 cause (b), and the one no furnace had ever measured.
#
# The two biggest movers in job urbantestdark212 were an art-frame set with
# metallic 0.45 / roughness 0.16-0.23 and a wall frame with metallic 0.61 /
# roughness 0.18 -- glTF materials that sit BETWEEN the metallic 0 and metallic 1
# endpoints every gate had covered. Cycles splits such a material into a
# metallic closure (weight = metallic, F82 Fresnel) and a dielectric stack
# (weight = 1 - metallic) whose diffuse is layered under the DIELECTRIC specular
# only (svm/closure.h:351, :468-470). Our single-lobe engine used to withdraw
# 1 - F(L.H) with the metalness-LERPED F0 from the diffuse, which for a
# half-metal is a 25-45% withdrawal Cycles never makes.
#
# Arms use a cream, painting-like base, LINEAR (0.50, 0.42, 0.30), with the two
# assets' parameters, plus a metallic-0 control at the same roughness so the
# dielectric endpoint is measured on the same base.
#
# BOUNCES MATCHED at 3. FRAMING matched: distance 2.5, 20 deg vertical FOV,
# 256x256, sphere overfills.

import bpy
import math
import os
import sys

OUT = sys.argv[sys.argv.index("--") + 1]
RES = 256
SAMPLES = 2048
CAM_DIST = 2.5
CAM_FOV_DEG = 20.0

BASE_LINEAR = (0.50, 0.42, 0.30)

# tag, metallic, roughness
ARMS = [
    ("metal45", 0.45, 0.20),
    ("metal61", 0.61, 0.18),
    ("metal0ctl", 0.00, 0.20),
]


def build(metallic, roughness):
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
    bsdf.inputs["Base Color"].default_value = (BASE_LINEAR[0], BASE_LINEAR[1], BASE_LINEAR[2], 1.0)
    bsdf.inputs["Metallic"].default_value = metallic
    bsdf.inputs["Roughness"].default_value = roughness
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
print("@@@ PARTIAL METAL vs Cycles @@@")
print("@@@ blender: %s" % bpy.app.version_string)
print("@@@ Base LINEAR %s" % (BASE_LINEAR,))
for tag, metallic, roughness in ARMS:
    build(metallic, roughness)
    p = os.path.join(OUT, "pm_%s.exr" % tag)
    bpy.context.scene.render.filepath = p
    bpy.ops.render.render(write_still=True)
    m, ch, n = stats(p)
    print("@@@ %-10s metallic=%.2f rough=%.2f mean=%.8f RGB=(%.8f,%.8f,%.8f) n=%d"
          % (tag, metallic, roughness, m, ch[0], ch[1], ch[2], n))
print("@@@ DONE")
