# Bump-map correction at grazing angles against Cycles -- the pt_bump_correction_gate
# stimulus (spec 2026-09-17-bump-correction-and-bg-color-design.md, roadmap F1).
#
# A 200 x 200 plane (normal +Z) tilted about X by acos(mu), seen by a 4-degree
# perspective camera at (0, 0, 150), under a uniform world. Tangent-space normal
# map: the pt_energy_gate sine pattern (0.85 sin u, 0.85 sin v, 0.45), 128 px,
# 8 periods per tile, 10 tiles across the plane, no mipmaps, strength 1.
# Cycles' Bump Map Correction is left at its default (on).
#
#   B0  mu = cos 10deg, dielectric albedo 1.0 roughness 0.4, world 0.5
#   B1  mu = cos 80deg, same material
#   B2  mu = cos 80deg, metal (Metallic 1) roughness 0.4, world 0.5
#   A   mu = cos 80deg, dielectric, world 1.0   (furnace; printed for reference)
#
#   "C:\Program Files\Blender Foundation\Blender 5.2\blender.exe" -b -P
#       tools/cycles_comparison/cycles_bump_grazing.py -- <out_dir>

import bpy
import math
import os
import sys

OUT = sys.argv[sys.argv.index("--") + 1]
RES = 256
SAMPLES = int(os.environ.get("SAMPLES", "256"))
NMAP = 128
TILES = 10.0
QUAD = 200.0
CAM_DIST = 150.0
CAM_FOV_DEG = 4.0


def make_normal_map():
    img = bpy.data.images.new("bump", NMAP, NMAP, alpha=False, float_buffer=True)
    # Colourspace first: changing it after the pixels are set regenerates the
    # buffer (cycles_oidn_checker.py learned this the hard way).
    img.colorspace_settings.name = "Non-Color"
    px = [0.0] * (NMAP * NMAP * 4)
    for y in range(NMAP):
        for x in range(NMAP):
            u = x / NMAP * 2.0 * math.pi * 8.0
            v = y / NMAP * 2.0 * math.pi * 8.0
            nx, ny, nz = 0.85 * math.sin(u), 0.85 * math.sin(v), 0.45
            ln = math.sqrt(nx * nx + ny * ny + nz * nz)
            nx, ny, nz = nx / ln, ny / ln, nz / ln
            i = (y * NMAP + x) * 4
            px[i:i + 4] = [nx * 0.5 + 0.5, ny * 0.5 + 0.5, nz * 0.5 + 0.5, 1.0]
    img.pixels.foreach_set(px)
    img.update()
    img.pack()
    return img


def build(mu, metallic, world_strength):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    scene.cycles.device = "CPU"
    scene.cycles.samples = SAMPLES
    scene.cycles.use_adaptive_sampling = False
    scene.cycles.use_denoising = False
    scene.cycles.max_bounces = 4
    scene.cycles.diffuse_bounces = 4
    scene.cycles.glossy_bounces = 4
    scene.cycles.sample_clamp_direct = 0.0
    scene.cycles.sample_clamp_indirect = 0.0
    scene.render.resolution_x = RES
    scene.render.resolution_y = RES
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "OPEN_EXR"
    scene.render.image_settings.color_mode = "RGB"
    scene.render.image_settings.color_depth = "32"
    scene.view_settings.view_transform = "Standard"

    world = bpy.data.worlds.new("W")
    scene.world = world
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs["Color"].default_value = (1, 1, 1, 1)
    world.node_tree.nodes["Background"].inputs["Strength"].default_value = world_strength

    bpy.ops.mesh.primitive_plane_add(size=QUAD)
    plane = bpy.context.object
    plane.rotation_euler = (math.acos(mu), 0.0, 0.0)

    mat = bpy.data.materials.new("M")
    mat.use_nodes = True
    nt = mat.node_tree
    bsdf = nt.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (1.0, 1.0, 1.0, 1.0)
    bsdf.inputs["Metallic"].default_value = metallic
    bsdf.inputs["Roughness"].default_value = 0.4
    bsdf.inputs["IOR"].default_value = 1.5
    bsdf.inputs["Specular IOR Level"].default_value = 0.5  # F0 0.04, Godot's metallic_specular default
    bsdf.inputs["Sheen Weight"].default_value = 0.0
    bsdf.inputs["Coat Weight"].default_value = 0.0
    uv = nt.nodes.new("ShaderNodeTexCoord")
    mapping = nt.nodes.new("ShaderNodeMapping")
    mapping.inputs["Scale"].default_value = (TILES, TILES, 1.0)
    tex = nt.nodes.new("ShaderNodeTexImage")
    tex.image = make_normal_map()
    tex.interpolation = "Linear"
    tex.extension = "REPEAT"
    nmap = nt.nodes.new("ShaderNodeNormalMap")
    nmap.space = "TANGENT"
    nmap.inputs["Strength"].default_value = 1.0
    nt.links.new(uv.outputs["UV"], mapping.inputs["Vector"])
    nt.links.new(mapping.outputs["Vector"], tex.inputs["Vector"])
    nt.links.new(tex.outputs["Color"], nmap.inputs["Color"])
    nt.links.new(nmap.outputs["Normal"], bsdf.inputs["Normal"])
    plane.data.materials.append(mat)

    cam_data = bpy.data.cameras.new("Cam")
    cam_data.sensor_fit = "VERTICAL"
    cam_data.angle_y = math.radians(CAM_FOV_DEG)
    cam_data.clip_end = 4000.0
    cam = bpy.data.objects.new("Cam", cam_data)
    scene.collection.objects.link(cam)
    scene.camera = cam
    cam.location = (0.0, 0.0, CAM_DIST)
    cam.rotation_euler = (0.0, 0.0, 0.0)  # looks down -Z at the plane


def patch_mean(path):
    img = bpy.data.images.load(path)
    px = list(img.pixels)
    w, h = img.size
    acc, n = 0.0, 0
    for y in range(int(0.3 * h), int(0.7 * h)):
        for x in range(int(0.3 * w), int(0.7 * w)):
            i = (y * w + x) * 4
            acc += (px[i] + px[i + 1] + px[i + 2]) / 3.0
            n += 1
    bpy.data.images.remove(img)
    return acc / n


os.makedirs(OUT, exist_ok=True)
print("")
print("@@@ BUMP GRAZING vs Cycles @@@")
print("@@@ blender: %s  samples %d" % (bpy.app.version_string, SAMPLES))
for tag, mu, metallic, strength in (
        ("B0", math.cos(math.radians(10.0)), 0.0, 0.5),
        ("B1", math.cos(math.radians(80.0)), 0.0, 0.5),
        ("B2", math.cos(math.radians(80.0)), 1.0, 0.5),
        ("A", math.cos(math.radians(80.0)), 0.0, 1.0)):
    build(mu, metallic, strength)
    p = os.path.join(OUT, "bump_%s.exr" % tag)
    bpy.context.scene.render.filepath = p
    bpy.ops.render.render(write_still=True)
    print("@@@ %-3s mu %.4f metallic %.0f world %.1f  patch mean %.6f" % (tag, mu, metallic, strength, patch_mean(p)))
print("@@@ DONE")
