# Grazing-view dielectric comparison against Cycles -- roadmap section 11.13.
#
# The real-asset render of 2026-09-11 put Gap #21 cause (b)'s largest DIELECTRIC
# effect on the marble floor: -6.6% to -8.6%, at the grazing view a standing
# camera has of a floor. Cycles' closure_layering_weight keys on the VIEW angle
# (bsdf_microfacet_estimate_albedo's cos_NI = dot(wi, N)), so a smooth dielectric
# withdraws far more from its diffuse at a grazing view than face-on -- and the
# overfilled sphere every Cycles comparison used (mu >= 0.9) never samples that
# band. This measures it directly.
#
# An ORTHOGRAPHIC camera looks at a large plane whose normal is tilted acos(mu)
# from the view axis, under a uniform world of radiance 1.0. A plane never sees
# itself, so the plane's mean radiance IS the Principled BSDF's directional
# albedo at exactly mu -- no framing to match, no bounce count to worry about
# (set to 3 anyway, for uniformity with the other scripts). The Godot side is
# pt_sheen_gate.gd's probe G on its near-orthographic tilted quad (4 deg FOV at
# distance 150, exact per-pixel cos map), which is why the two agree pixel-set
# to pixel-set rather than at a nominal angle.
#
# Material: cream LINEAR (0.50, 0.42, 0.30), metallic 0, roughness 0.20,
# Specular IOR Level 0.5 (= Godot's metallic_specular default, F0 0.04).

import bpy
import math
import os
import sys

OUT = sys.argv[sys.argv.index("--") + 1]
RES = 256
SAMPLES = 2048

BASE_LINEAR = (0.50, 0.42, 0.30)
ROUGHNESS = 0.20
MUS = [0.30, 0.50, 0.90]


def build(mu, base):
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

    # Plane in XY with normal +Z, then rotated about X by acos(mu) so that the
    # angle between its normal and the camera's view axis (-Z toward the plane,
    # i.e. the plane sees the camera along +Z) is acos(mu).
    bpy.ops.mesh.primitive_plane_add(size=1000.0)
    plane = bpy.context.object
    plane.rotation_euler = (math.acos(mu), 0.0, 0.0)

    mat = bpy.data.materials.new("M")
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (base[0], base[1], base[2], 1.0)
    bsdf.inputs["Metallic"].default_value = 0.0
    bsdf.inputs["Roughness"].default_value = ROUGHNESS
    bsdf.inputs["Specular IOR Level"].default_value = 0.5
    bsdf.inputs["Sheen Weight"].default_value = 0.0
    plane.data.materials.append(mat)

    cam_data = bpy.data.cameras.new("Cam")
    cam_data.type = "ORTHO"
    cam_data.ortho_scale = 2.0
    cam = bpy.data.objects.new("Cam", cam_data)
    scene.collection.objects.link(cam)
    scene.camera = cam
    cam.location = (0.0, 0.0, 10.0)
    cam.rotation_euler = (0.0, 0.0, 0.0)  # looks down -Z at the plane


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
print("@@@ GRAZING DIELECTRIC vs Cycles @@@")
print("@@@ blender: %s" % bpy.app.version_string)
print("@@@ Base LINEAR %s  roughness %.2f  metallic 0  Specular IOR Level 0.5" % (BASE_LINEAR, ROUGHNESS))
# Two arms per angle: the full material, and the same material on a BLACK base,
# which is the specular lobe alone (no diffuse, so nothing to withdraw from).
# The diffuse lobe is Lambert and needs no render: (0.50+0.42+0.30)/3 = 0.40667
# at every angle. The layering withdrawal is then Lambert + black - full.
LAMBERT = sum(BASE_LINEAR) / 3.0
for mu in MUS:
    res = {}
    for tag, base in (("full", BASE_LINEAR), ("black", (0.0, 0.0, 0.0))):
        build(mu, base)
        p = os.path.join(OUT, "gd_%s_mu%.2f.exr" % (tag, mu))
        bpy.context.scene.render.filepath = p
        bpy.ops.render.render(write_still=True)
        m, ch, n = stats(p)
        res[tag] = m
        print("@@@ %-5s mu=%.2f  mean=%.8f RGB=(%.8f,%.8f,%.8f) n=%d" % (tag, mu, m, ch[0], ch[1], ch[2], n))
    print("@@@ withdrawal at mu=%.2f = Lambert %.8f + black %.8f - full %.8f = %.8f (%.2f%% of diffuse)"
          % (mu, LAMBERT, res["black"], res["full"], LAMBERT + res["black"] - res["full"],
             (LAMBERT + res["black"] - res["full"]) / LAMBERT * 100.0))
print("@@@ DONE")
