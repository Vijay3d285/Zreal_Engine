# Rough surfaces under a single DELTA light against Cycles -- roadmap Gap #23.
#
# Every Cycles comparison before this one was environment-lit, and the
# environment-NEE site got Cycles' multi-scatter compensation in Gap #17. The
# three ANALYTIC-light NEE sites (raytracing_lights_inc.glsl :604, :782, :835)
# never did, and for a delta light NEE is the only estimator there is -- so
# every rough specular surface lit by the sun or a lamp is short of energy by
# 1/E(rough, mu). This is the first measurement of that path against Cycles.
#
# A sphere at the origin, a sun (angle 0 = delta) shining from the camera's
# direction, a BLACK world. Arms: a white Lambertian CONTROL, three white
# metals at roughness 0.3 / 0.6 / 0.9, and a mid-grey dielectric at 0.6.
# The two engines define light units differently, so what is compared is each
# arm's mean DIVIDED BY the Lambertian control's mean in the same engine: the
# light's strength, the NdotL distribution and the framing all cancel, and
# only the BRDF is left.
#
# FRAMING matched: distance 2.5 along (1,-1,1) (Blender Z-up for Godot's
# (1,1,1) Y-up), 20 deg vertical FOV, 256x256, sphere overfills. Bounces 3;
# with a black world only the first hit contributes.

import bpy
import math
import os
import sys

OUT = sys.argv[sys.argv.index("--") + 1]
RES = 256
SAMPLES = 1024
CAM_DIST = 2.5
CAM_FOV_DEG = 20.0
SUN_STRENGTH = 3.0

# tag, base, metallic, roughness, specular_ior_level
ARMS = [
    ("lambert", (1.0, 1.0, 1.0), 0.0, 1.0, 0.0),   # Specular IOR Level 0 -> no specular lobe at all
    ("metal03", (1.0, 1.0, 1.0), 1.0, 0.3, 0.5),
    ("metal06", (1.0, 1.0, 1.0), 1.0, 0.6, 0.5),
    ("metal09", (1.0, 1.0, 1.0), 1.0, 0.9, 0.5),
    ("plastic06", (0.5, 0.5, 0.5), 0.0, 0.6, 0.5),
]


def build(base, metallic, roughness, spec_level):
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
    world.node_tree.nodes["Background"].inputs["Color"].default_value = (0, 0, 0, 1)
    world.node_tree.nodes["Background"].inputs["Strength"].default_value = 0.0

    bpy.ops.mesh.primitive_uv_sphere_add(segments=64, ring_count=32, radius=1.0)
    sphere = bpy.context.object
    bpy.ops.object.shade_smooth()

    mat = bpy.data.materials.new("M")
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (base[0], base[1], base[2], 1.0)
    bsdf.inputs["Metallic"].default_value = metallic
    bsdf.inputs["Roughness"].default_value = roughness
    bsdf.inputs["Specular IOR Level"].default_value = spec_level
    bsdf.inputs["Sheen Weight"].default_value = 0.0
    sphere.data.materials.append(mat)

    k = CAM_DIST / math.sqrt(3.0)
    cam_data = bpy.data.cameras.new("Cam")
    cam_data.sensor_fit = "VERTICAL"
    cam_data.angle_y = math.radians(CAM_FOV_DEG)
    cam = bpy.data.objects.new("Cam", cam_data)
    scene.collection.objects.link(cam)
    scene.camera = cam
    cam.location = (k, -k, k)
    con = cam.constraints.new("TRACK_TO")
    con.target = sphere
    con.track_axis = "TRACK_NEGATIVE_Z"
    con.up_axis = "UP_Y"

    # Sun from the camera's direction: its -Z (the light's travel direction)
    # tracks the sphere from the camera's position.
    sun_data = bpy.data.lights.new("Sun", "SUN")
    sun_data.energy = SUN_STRENGTH
    sun_data.angle = 0.0
    sun = bpy.data.objects.new("Sun", sun_data)
    scene.collection.objects.link(sun)
    sun.location = (k, -k, k)
    scon = sun.constraints.new("TRACK_TO")
    scon.target = sphere
    scon.track_axis = "TRACK_NEGATIVE_Z"
    scon.up_axis = "UP_Y"
    return bsdf


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
    return acc / max(n, 1), n


os.makedirs(OUT, exist_ok=True)
print("")
print("@@@ DELTA LIGHT vs Cycles @@@")
print("@@@ blender: %s" % bpy.app.version_string)
means = {}
for tag, base, metallic, roughness, spec in ARMS:
    bsdf = build(base, metallic, roughness, spec)
    if tag == "lambert":
        print("@@@ distribution: %s" % bsdf.distribution)
    p = os.path.join(OUT, "le_%s.exr" % tag)
    bpy.context.scene.render.filepath = p
    bpy.ops.render.render(write_still=True)
    m, n = stats(p)
    means[tag] = m
    print("@@@ %-10s base=%s metallic=%.1f rough=%.1f  mean=%.8f  n=%d" % (tag, base, metallic, roughness, m, n))
print("@@@ ratios to the Lambertian control:")
for tag, _, _, _, _ in ARMS:
    print("@@@   %-10s %.8f" % (tag, means[tag] / means["lambert"]))
print("@@@ DONE")
