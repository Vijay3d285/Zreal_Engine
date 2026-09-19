# Closed white room with one window opening, lit by a uniform world through a
# light portal -- the pt_portal_gate P3 stimulus
# (spec 2026-09-18-light-portals-design.md).
#
# Godot (x, y, z) -> Blender (x, -z, y). The room is Godot [-2,2] x [0,3] x
# [-1.5,1.5]; the opening is in the x = -2 wall, 1.2 wide (Godot z) x 1.0
# tall, sill at y = 0.9. Every quad is given by its four Godot corners and
# converted, so the two fixtures are the same numbers. One area light,
# is_portal, sits in the opening facing +X (into the room). World strength 1,
# albedo 0.8 everywhere, 16 bounces (the room is bounce-dominated; at 8 a
# one-segment difference in bounce counting is a 3% bias), 1024 spp, no denoise.
# Camera Godot (0, 1.5, 1.2) looking at (0, 1.2, -1.5), 60 deg vertical FOV.
#
#   "C:\Program Files\Blender Foundation\Blender 5.2\blender.exe" -b -P
#       tools/cycles_comparison/cycles_portal_room.py -- <out_dir>

import bpy
import math
import os
import sys

OUT = sys.argv[sys.argv.index("--") + 1]
RES = 256
SAMPLES = int(os.environ.get("SAMPLES", "1024"))
ALBEDO = 0.8


def g2b(p):
    return (p[0], -p[2], p[1])


def mat_surface(name, albedo):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = (albedo, albedo, albedo, 1.0)
    b.inputs["Roughness"].default_value = 1.0
    b.inputs["Specular IOR Level"].default_value = 0.0
    return m


def quad(name, corners_godot, mat):
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata([g2b(c) for c in corners_godot], [], [(0, 1, 2, 3)])
    mesh.update()
    obj = bpy.data.objects.new(name, mesh)
    obj.data.materials.append(mat)
    bpy.context.scene.collection.objects.link(obj)
    return obj


# The same quad list the gate builds (pt_portal_gate.gd, _build_room()).
def room_quads():
    X0, X1, Y0, Y1, Z0, Z1 = -2.0, 2.0, 0.0, 3.0, -1.5, 1.5
    WZ0, WZ1, WY0, WY1 = -0.6, 0.6, 0.9, 1.9  # the opening
    return [
        ("floor", [(X0, Y0, Z0), (X1, Y0, Z0), (X1, Y0, Z1), (X0, Y0, Z1)]),
        ("ceiling", [(X0, Y1, Z0), (X0, Y1, Z1), (X1, Y1, Z1), (X1, Y1, Z0)]),
        ("back", [(X0, Y0, Z0), (X0, Y1, Z0), (X1, Y1, Z0), (X1, Y0, Z0)]),
        ("front", [(X0, Y0, Z1), (X1, Y0, Z1), (X1, Y1, Z1), (X0, Y1, Z1)]),
        ("right", [(X1, Y0, Z0), (X1, Y1, Z0), (X1, Y1, Z1), (X1, Y0, Z1)]),
        ("left_below", [(X0, Y0, Z0), (X0, Y0, Z1), (X0, WY0, Z1), (X0, WY0, Z0)]),
        ("left_above", [(X0, WY1, Z0), (X0, WY1, Z1), (X0, Y1, Z1), (X0, Y1, Z0)]),
        ("left_neg", [(X0, WY0, Z0), (X0, WY0, WZ0), (X0, WY1, WZ0), (X0, WY1, Z0)]),
        ("left_pos", [(X0, WY0, WZ1), (X0, WY0, Z1), (X0, WY1, Z1), (X0, WY1, WZ1)]),
    ]


def build(portal):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    scene.cycles.device = "CPU"
    scene.cycles.samples = SAMPLES
    scene.cycles.use_adaptive_sampling = False
    scene.cycles.use_denoising = False
    scene.cycles.max_bounces = 16
    scene.cycles.diffuse_bounces = 16
    scene.cycles.glossy_bounces = 16
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
    world.node_tree.nodes["Background"].inputs["Strength"].default_value = 1.0
    world.cycles.sampling_method = "AUTOMATIC"  # map MIS on: Cycles' map_weight 1

    white = mat_surface("white", ALBEDO)
    for name, corners in room_quads():
        quad(name, corners, white)

    if portal:
        ld = bpy.data.lights.new("Portal", "AREA")
        ld.shape = "RECTANGLE"
        ld.size = 1.0    # local X -> Blender +Z (Godot +Y): the opening's height
        ld.size_y = 1.2  # local Y -> Blender -Y (Godot z): the opening's width
        ld.cycles.is_portal = True
        lo = bpy.data.objects.new("Portal", ld)
        scene.collection.objects.link(lo)
        lo.location = g2b((-2.0, 1.4, 0.0))
        lo.rotation_euler = (0.0, -math.pi / 2.0, 0.0)  # local -Z -> +X, into the room

    cam_data = bpy.data.cameras.new("Cam")
    cam_data.sensor_fit = "VERTICAL"
    cam_data.angle_y = math.radians(60.0)
    cam = bpy.data.objects.new("Cam", cam_data)
    scene.collection.objects.link(cam)
    scene.camera = cam
    cam.location = g2b((0.0, 1.5, 1.2))
    cam.rotation_euler = (math.radians(90.0) - math.atan2(0.3, 2.7), 0.0, 0.0)  # looks +Y, 6.34 deg down


def crop_mean(path, fy0, fy1, fx0, fx1):
    img = bpy.data.images.load(path)
    px = list(img.pixels)
    w, h = img.size
    acc, n = 0.0, 0
    # Blender rows are bottom-up; the gate's fractions are from the top.
    for y in range(int((1.0 - fy1) * h), int((1.0 - fy0) * h)):
        for x in range(int(fx0 * w), int(fx1 * w)):
            i = (y * w + x) * 4
            acc += (px[i] + px[i + 1] + px[i + 2]) / 3.0
            n += 1
    bpy.data.images.remove(img)
    return acc / n


os.makedirs(OUT, exist_ok=True)
print("")
print("@@@ PORTAL ROOM vs Cycles @@@")
print("@@@ blender: %s  samples %d  bounces 16" % (bpy.app.version_string, SAMPLES))

build(True)
p = os.path.join(OUT, "portal_on.exr")
bpy.context.scene.render.filepath = p
bpy.ops.render.render(write_still=True)
wall = crop_mean(p, 0.30, 0.60, 0.30, 0.70)
floor = crop_mean(p, 0.90, 0.98, 0.30, 0.70)
print("@@@ P3 portal wall %.6f floor %.6f" % (wall, floor))

build(False)
p = os.path.join(OUT, "portal_off.exr")
bpy.context.scene.render.filepath = p
bpy.ops.render.render(write_still=True)
wall_off = crop_mean(p, 0.30, 0.60, 0.30, 0.70)
floor_off = crop_mean(p, 0.90, 0.98, 0.30, 0.70)
print("@@@ CONTROL no portal wall %.6f floor %.6f (must equal P3 within noise: a portal changes variance, not the mean)" % (wall_off, floor_off))
print("@@@ DONE")
