# Phase 3 test for Gap #19 divergence A.
#
# D and the Smith lambda are TEXTUALLY IDENTICAL between our engine and Cycles
# (bsdf_aniso_D / bsdf_aniso_lambda vs GGX_D_Aniso / Smith_Lambda_Aniso), so the
# +5.28% raw-lobe gap at roughness 0.4 / anisotropy 0.9 cannot come from the BRDF
# core. Hypothesis: it is the TANGENT FIELD. An anisotropic lobe's albedo depends
# on the angle between V and the tangent, and the furnace samples only a narrow
# cap (mu in [0.796, 1.0]), so two different tangent fields sample different parts
# of that dependence.
#
# This varies ONLY the tangent field. Everything else is held fixed.

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
ANISO = 0.9


def build(tangent_kind):
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
    bsdf.distribution = "GGX"  # raw lobe, no multiscatter compensation
    bsdf.inputs["Base Color"].default_value = (1, 1, 1, 1)
    bsdf.inputs["Metallic"].default_value = 1.0
    bsdf.inputs["Roughness"].default_value = ROUGH
    bsdf.inputs["Anisotropic"].default_value = ANISO
    bsdf.inputs["Anisotropic Rotation"].default_value = 0.0

    if tangent_kind != "none":
        tan = nt.nodes.new("ShaderNodeTangent")
        if tangent_kind.startswith("RADIAL_"):
            tan.direction_type = "RADIAL"
            tan.axis = tangent_kind.split("_")[1]
        else:
            tan.direction_type = "UV_MAP"
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
print("\n@@@ TANGENT-FIELD SENSITIVITY -- roughness %.1f / anisotropy %.1f, raw GGX @@@" % (ROUGH, ANISO))
print("@@@ %-18s %10s %8s" % ("tangent field", "ratio", "px"))
results = {}
for kind in ["RADIAL_Z", "RADIAL_X", "RADIAL_Y", "UV_MAP", "none"]:
    build(kind)
    p = os.path.join(OUT, "tan_%s.exr" % kind)
    bpy.context.scene.render.filepath = p
    bpy.ops.render.render(write_still=True)
    r, n = stats(p)
    results[kind] = r
    print("@@@ %-18s %10.6f %8d" % (kind, r, n))

# Isotropic control in the SAME scene, to confirm nothing else drifted.
ANISO_SAVE = ANISO
ANISO = 0.0
build("RADIAL_Z")
p = os.path.join(OUT, "tan_iso_control.exr")
bpy.context.scene.render.filepath = p
bpy.ops.render.render(write_still=True)
r, n = stats(p)
print("@@@ %-18s %10.6f %8d   (ours: 0.965696)" % ("ISO control", r, n))

lo = min(results.values())
hi = max(results.values())
print("@@@ spread across tangent fields: %.6f .. %.6f  = %.2f%%" % (lo, hi, (hi / lo - 1) * 100))
print("@@@ OURS at this config:          0.942444")
print("@@@ TANGENT DONE")
