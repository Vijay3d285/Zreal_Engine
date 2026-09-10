# Anisotropic white-furnace test in Cycles, to decide roadmap Gap #19.
#
# QUESTION: our engine's white furnace reads ~1.0005 at anisotropy 0 but 0.9764
# at anisotropy +0.9 (roughness 0.4), and the offset is present even with
# multi-scatter compensation disabled entirely. Is that our E2b anisotropic
# branch, or does Cycles -- which feeds the same isotropic GGX_E table the same
# geometric-mean roughness -- share it?
#
# A white furnace must return exactly the world radiance for ANY
# energy-conserving BRDF: roughness and anisotropy redistribute where energy
# goes, never how much comes back.
#
# TWO TRAPS THIS SCRIPT GUARDS AGAINST:
#  1. svm/closure.h gates anisotropy on `stack_valid(data.tangent_offset)`, so
#     with nothing plugged into the Tangent socket the render is silently
#     ISOTROPIC and would "prove" Cycles has no residual. A ShaderNodeTangent is
#     connected explicitly, and the LIGHT control below verifies it took effect.
#  2. `saturatef` clamps Principled anisotropy to [0,1], so negative anisotropy
#     has no Cycles counterpart. Only 0.0 / +0.5 / +0.9 are swept.

import bpy
import os
import sys

OUT = sys.argv[sys.argv.index("--") + 1]
RES = 256
SAMPLES = 1024

# roughness, anisotropy, tag
FURNACE = [
    (0.4, 0.0, "r040_a000"),
    (0.4, 0.5, "r040_a050"),
    (0.4, 0.9, "r040_a090"),
    (0.9, 0.0, "r090_a000"),
    (0.9, 0.9, "r090_a090"),
]


def clear():
    bpy.ops.wm.read_factory_settings(use_empty=True)


def build(roughness, anisotropy, with_tangent=True, world_strength=1.0, add_light=False):
    clear()
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    scene.cycles.device = "CPU"
    scene.cycles.samples = SAMPLES
    scene.cycles.use_denoising = False
    scene.cycles.max_bounces = 8
    scene.cycles.diffuse_bounces = 8
    scene.cycles.glossy_bounces = 8
    # Clamping deletes energy; a furnace must run with it off.
    scene.cycles.sample_clamp_direct = 0.0
    scene.cycles.sample_clamp_indirect = 0.0
    scene.render.resolution_x = RES
    scene.render.resolution_y = RES
    scene.render.resolution_percentage = 100
    scene.render.film_transparent = True  # gives us an alpha mask for the sphere
    scene.render.image_settings.file_format = "OPEN_EXR"
    scene.render.image_settings.color_mode = "RGBA"
    scene.render.image_settings.color_depth = "32"
    scene.view_settings.view_transform = "Standard"
    scene.view_settings.look = "None"

    # Uniform world of radiance `world_strength`.
    world = bpy.data.worlds.new("W")
    scene.world = world
    world.use_nodes = True
    bg = world.node_tree.nodes["Background"]
    bg.inputs["Color"].default_value = (1.0, 1.0, 1.0, 1.0)
    bg.inputs["Strength"].default_value = world_strength

    bpy.ops.mesh.primitive_uv_sphere_add(segments=128, ring_count=64, radius=1.0)
    sphere = bpy.context.object
    bpy.ops.object.shade_smooth()

    mat = bpy.data.materials.new("Furnace")
    mat.use_nodes = True
    nt = mat.node_tree
    bsdf = nt.nodes["Principled BSDF"]

    def setin(name, value):
        assert name in bsdf.inputs, "missing input %r; have %s" % (
            name, [i.name for i in bsdf.inputs])
        bsdf.inputs[name].default_value = value

    setin("Base Color", (1.0, 1.0, 1.0, 1.0))
    setin("Metallic", 1.0)
    setin("Roughness", roughness)
    setin("Anisotropic", anisotropy)
    setin("Anisotropic Rotation", 0.0)

    if with_tangent:
        tan = nt.nodes.new("ShaderNodeTangent")
        tan.direction_type = "RADIAL"
        tan.axis = "Z"
        nt.links.new(tan.outputs["Tangent"], bsdf.inputs["Tangent"])

    sphere.data.materials.append(mat)

    cam_data = bpy.data.cameras.new("Cam")
    cam = bpy.data.objects.new("Cam", cam_data)
    scene.collection.objects.link(cam)
    scene.camera = cam
    # Off-axis, matching our own gate's deliberate off-world-Z view.
    cam.location = (2.6, -2.6, 1.6)
    cam_data.lens = 85.0
    cam.rotation_euler = (0.0, 0.0, 0.0)
    con = cam.constraints.new("TRACK_TO")
    con.target = sphere
    con.track_axis = "TRACK_NEGATIVE_Z"
    con.up_axis = "UP_Y"

    if add_light:
        lamp_data = bpy.data.lights.new("L", type="POINT")
        lamp_data.energy = 3000.0
        lamp_data.shadow_soft_size = 0.05
        lamp = bpy.data.objects.new("L", lamp_data)
        lamp.location = (3.0, -1.0, 3.0)
        scene.collection.objects.link(lamp)
    return scene


def render_to(path):
    bpy.context.scene.render.filepath = path
    bpy.ops.render.render(write_still=True)


def stats(path):
    """Mean RGB over pixels the sphere actually covers (alpha > 0.99)."""
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
    if n == 0:
        return None, 0
    return [a / n for a in acc], n


def rmse(path_a, path_b):
    a = bpy.data.images.load(path_a)
    b = bpy.data.images.load(path_b)
    pa, pb = list(a.pixels), list(b.pixels)
    tot = 0.0
    n = 0
    for i in range(0, len(pa), 4):
        if pa[i + 3] > 0.99 and pb[i + 3] > 0.99:
            for c in range(3):
                d = pa[i + c] - pb[i + c]
                tot += d * d
            n += 3
    bpy.data.images.remove(a)
    bpy.data.images.remove(b)
    return (tot / n) ** 0.5 if n else float("nan")


os.makedirs(OUT, exist_ok=True)
print("\n@@@ CYCLES ANISOTROPIC FURNACE @@@")
print("@@@ blender:", bpy.app.version_string)

# ---------------------------------------------------------------- control ----
# Proves the Tangent link actually activates anisotropy. Lit by a point light
# with the world dark, where an anisotropic highlight is unmistakably different
# from an isotropic one. If these two renders are identical, anisotropy is INERT
# and every furnace number below would be meaningless.
for tag, aniso in (("ctrl_a000", 0.0), ("ctrl_a090", 0.9)):
    build(0.4, aniso, with_tangent=True, world_strength=0.0, add_light=True)
    render_to(os.path.join(OUT, tag + ".exr"))
ctrl = rmse(os.path.join(OUT, "ctrl_a000.exr"), os.path.join(OUT, "ctrl_a090.exr"))
print("@@@ CONTROL rmse(aniso 0.0 vs 0.9, point-lit) = %.6f" % ctrl)

# Second control: anisotropy 0.9 with the Tangent socket LEFT UNCONNECTED must
# match anisotropy 0.0, confirming the socket is what gates it.
build(0.4, 0.9, with_tangent=False, world_strength=0.0, add_light=True)
render_to(os.path.join(OUT, "ctrl_a090_notan.exr"))
notan = rmse(os.path.join(OUT, "ctrl_a000.exr"), os.path.join(OUT, "ctrl_a090_notan.exr"))
print("@@@ CONTROL rmse(aniso 0.0 vs 0.9 WITHOUT tangent) = %.6f" % notan)

# ---------------------------------------------------------------- furnace ----
print("@@@ %-12s %10s %10s %10s %10s %8s" % ("tag", "R", "G", "B", "ratio", "px"))
for rough, aniso, tag in FURNACE:
    build(rough, aniso, with_tangent=True, world_strength=1.0, add_light=False)
    p = os.path.join(OUT, tag + ".exr")
    render_to(p)
    mean, n = stats(p)
    if mean is None:
        print("@@@ %-12s NO SPHERE PIXELS" % tag)
        continue
    ratio = sum(mean) / 3.0
    print("@@@ %-12s %10.6f %10.6f %10.6f %10.6f %8d"
          % (tag, mean[0], mean[1], mean[2], ratio, n))
print("@@@ DONE")
