# Subsurface sphere against Cycles -- E3 (spec 2026-09-15-e3-subsurface-scattering).
#
# Solid sphere, Principled BSDF, Subsurface Weight 1.0, Random Walk, radius
# (1, 0.2, 0.1) * scale 0.05, IOR 1.4, albedo 0.8, under a uniform world of
# radiance 1.0. Framing matched to cycles_glass_furnace.py / the gate. Also
# renders the same sphere with Subsurface Weight 0 (plain diffuse) as the
# control the gate's fallback probe compares against, and a white lossless
# sphere for the energy probe.
#
# Specular IOR Level is 0 so the sphere is diffuse + subsurface only, matching
# the gate's metallic_specular = 0.0.

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
ALBEDO = 0.8
RADIUS = (1.0, 0.2, 0.1)
SCALE = 0.05
IOR = 1.4


def build(sss_weight, albedo, radius, scale):
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
    bsdf.inputs["Base Color"].default_value = (albedo, albedo, albedo, 1.0)
    bsdf.inputs["Metallic"].default_value = 0.0
    bsdf.inputs["Roughness"].default_value = 1.0
    bsdf.inputs["IOR"].default_value = IOR
    bsdf.inputs["Specular IOR Level"].default_value = 0.0
    bsdf.subsurface_method = "RANDOM_WALK"
    bsdf.inputs["Subsurface Weight"].default_value = sss_weight
    bsdf.inputs["Subsurface Radius"].default_value = radius
    bsdf.inputs["Subsurface Scale"].default_value = scale
    bsdf.inputs["Subsurface Anisotropy"].default_value = 0.0
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
print("@@@ SUBSURFACE SPHERE vs Cycles @@@")
print("@@@ blender: %s" % bpy.app.version_string)
for label, w, a, r, s in (
        ("diffuse_a0.8", 0.0, ALBEDO, RADIUS, SCALE),
        ("sss_a0.8", 1.0, ALBEDO, RADIUS, SCALE),
        ("sss_white", 1.0, 1.0, (1.0, 1.0, 1.0), SCALE),
        ("diffuse_white", 0.0, 1.0, (1.0, 1.0, 1.0), SCALE)):
    bsdf = build(w, a, r, s)
    if label == "diffuse_a0.8":
        print("@@@ subsurface_method: %s" % bsdf.subsurface_method)
    p = os.path.join(OUT, "%s.exr" % label)
    bpy.context.scene.render.filepath = p
    bpy.ops.render.render(write_still=True)
    m, ch, n = stats(p)
    print("@@@ %-14s mean=%.8f RGB=(%.8f,%.8f,%.8f) n=%d" % (label, m, ch[0], ch[1], ch[2], n))
print("@@@ DONE")
