# One glass interface at a time, in Cycles -- roadmap Gap #20 (section 11.14).
#
# An orthographic camera looks at a large plane of Principled glass
# (Transmission Weight 1, IOR 1.5, white) under a uniform world of radiance 1.0.
# A plane never sees itself, so whatever reflects or refracts off it reaches
# radiance 1.0 next, and the plane's mean IS the closure's directional albedo
# at the view angle mu times its energy compensation:
#
#   distribution GGX        -> the raw single-scatter E_ss(mu)   (no compensation)
#   distribution MULTI_GGX  -> E_ss(mu) * energy_scale           (should be ~1.0)
#
# The camera sees the plane's FRONT face (an ENTRY interface, ior 1.5) or, with
# the plane turned around, its BACK face (an EXIT interface -- Cycles flips ior
# to 1/1.5 and reads the ggx_glass_inv_* tables). Cycles renders back faces, so
# this reaches the exit interface directly, which the Godot raygen cannot do
# from outside a medium (it culls back faces until a path is inside one).
#
# The GGX rows are what the four transcribed tables were baked from and what
# pt_glass_energy_gate.gd's probe 2 measures on an uncompensated build; the
# MULTI_GGX rows are Cycles' own self-consistency, and the number every
# compensated engine should read.

import bpy
import math
import os
import sys

OUT = sys.argv[sys.argv.index("--") + 1]
RES = 256
SAMPLES = 2048
IOR = 1.5
ROUGHNESS = [0.3, 0.6, 0.9]
MUS = [1.0, 0.5, 0.2]


def build(roughness, mu, back, distribution):
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

    bpy.ops.mesh.primitive_plane_add(size=1000.0)
    plane = bpy.context.object
    # Normal +Z rotated about X: n = (0, -sin t, cos t); the camera's wi is +Z,
    # so dot(n, wi) = cos t = mu for the front face and -mu for the back face.
    plane.rotation_euler = ((math.pi - math.acos(mu)) if back else math.acos(mu), 0.0, 0.0)

    mat = bpy.data.materials.new("M")
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes["Principled BSDF"]
    bsdf.distribution = distribution
    bsdf.inputs["Base Color"].default_value = (1.0, 1.0, 1.0, 1.0)
    bsdf.inputs["Metallic"].default_value = 0.0
    bsdf.inputs["Roughness"].default_value = roughness
    bsdf.inputs["IOR"].default_value = IOR
    bsdf.inputs["Transmission Weight"].default_value = 1.0
    bsdf.inputs["Sheen Weight"].default_value = 0.0
    plane.data.materials.append(mat)

    cam_data = bpy.data.cameras.new("Cam")
    cam_data.type = "ORTHO"
    cam_data.ortho_scale = 2.0
    cam = bpy.data.objects.new("Cam", cam_data)
    scene.collection.objects.link(cam)
    scene.camera = cam
    cam.location = (0.0, 0.0, 10.0)
    cam.rotation_euler = (0.0, 0.0, 0.0)


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
print("@@@ GLASS INTERFACE vs Cycles @@@")
print("@@@ blender: %s" % bpy.app.version_string)
print("@@@ %-6s %-5s %-10s %-4s %12s" % ("rough", "side", "distrib", "mu", "mean"))
for r in ROUGHNESS:
    for side, back in (("entry", False), ("exit", True)):
        for distribution in ("GGX", "MULTI_GGX"):
            for mu in MUS:
                build(r, mu, back, distribution)
                p = os.path.join(OUT, "gi_%s_%s_r%.1f_mu%.1f.exr" % (side, distribution, r, mu))
                bpy.context.scene.render.filepath = p
                bpy.ops.render.render(write_still=True)
                m, n = stats(p)
                print("@@@ %-6.2f %-5s %-10s %-4.1f %12.8f  n=%d" % (r, side, distribution, mu, m, n))
print("@@@ DONE")
