# Cycles white furnace with the camera framing MATCHED to pt_anisotropy_gate.gd.
#
# WHY THIS SCRIPT EXISTS: the first version framed the sphere so its whole limb
# was visible (distance 4.01, 85mm), sampling mu in [0, 1]. Our gate puts the
# camera at distance 2.5 with a 20 deg FOV, so the sphere OVERFILLS the frame and
# only mu in [0.796, 1.0] is sampled -- a near-normal cap. A white furnace returns
# exactly 1.0 at every mu when energy-conserving, so the ISOTROPIC comparison was
# unaffected; but the anisotropic deviation is mu-dependent, so comparing the two
# framings for anisotropic materials compared different integrals.
#
# Gate geometry being matched (pt_anisotropy_gate.gd):
#   sphere radius 1.0 at the origin
#   camera at normalize(1,1,1) * 2.5, looking at the origin
#   Camera3D.fov = 20.0  (Godot KEEP_HEIGHT -> vertical FOV on a square viewport)
#   256x256, so horizontal FOV == vertical FOV == 20 deg

import bpy
import math
import os
import sys

OUT = sys.argv[sys.argv.index("--") + 1]
RES = 256
SAMPLES = 1024
CAM_DIST = 2.5
CAM_FOV_DEG = 20.0

# roughness, anisotropy, distribution, tag
CONFIGS = [
    (0.4, 0.0, "MULTI_GGX", "m_r040_a000"),
    (0.4, 0.5, "MULTI_GGX", "m_r040_a050"),
    (0.4, 0.9, "MULTI_GGX", "m_r040_a090"),
    (0.9, 0.0, "MULTI_GGX", "m_r090_a000"),
    (0.9, 0.9, "MULTI_GGX", "m_r090_a090"),
    (0.4, 0.0, "GGX", "raw_r040_a000"),
    (0.4, 0.9, "GGX", "raw_r040_a090"),
    (0.9, 0.0, "GGX", "raw_r090_a000"),
    (0.9, 0.9, "GGX", "raw_r090_a090"),
]


def build(roughness, anisotropy, distribution):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    scene.cycles.device = "CPU"
    scene.cycles.samples = SAMPLES
    scene.cycles.use_denoising = False
    scene.cycles.max_bounces = 8
    scene.cycles.diffuse_bounces = 8
    scene.cycles.glossy_bounces = 8
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
    bsdf.distribution = distribution
    bsdf.inputs["Base Color"].default_value = (1, 1, 1, 1)
    bsdf.inputs["Metallic"].default_value = 1.0
    bsdf.inputs["Roughness"].default_value = roughness
    bsdf.inputs["Anisotropic"].default_value = anisotropy
    bsdf.inputs["Anisotropic Rotation"].default_value = 0.0
    tan = nt.nodes.new("ShaderNodeTangent")
    tan.direction_type = "RADIAL"
    tan.axis = "Z"
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
    return scene


def stats(path):
    img = bpy.data.images.load(path)
    px = list(img.pixels)
    n = 0
    acc = 0.0
    for i in range(0, len(px), 4):
        if px[i + 3] > 0.99:
            acc += (px[i] + px[i + 1] + px[i + 2]) / 3.0
            n += 1
    total = len(px) // 4
    bpy.data.images.remove(img)
    return (acc / n if n else float("nan")), n, total


os.makedirs(OUT, exist_ok=True)
print("\n@@@ CYCLES FURNACE, FRAMING MATCHED TO pt_anisotropy_gate.gd @@@")
print("@@@ blender:", bpy.app.version_string)
ang = math.degrees(math.asin(1.0 / CAM_DIST))
diag = math.degrees(math.atan(math.tan(math.radians(CAM_FOV_DEG / 2.0)) * math.sqrt(2.0)))
print("@@@ sphere angular radius %.2f deg vs diagonal half-FOV %.2f deg -- %s"
      % (ang, diag, "sphere OVERFILLS (every pixel is a hit)" if diag < ang else "LIMB VISIBLE (mismatch!)"))
b = CAM_DIST * math.sin(math.radians(diag))
print("@@@ mu range sampled: [%.4f, 1.0]" % math.sqrt(max(0.0, 1.0 - b * b)))
print("@@@ %-16s %10s %10s %8s %8s" % ("tag", "dist", "ratio", "px", "of"))
for rough, aniso, dist, tag in CONFIGS:
    build(rough, aniso, dist)
    p = os.path.join(OUT, tag + "_matched.exr")
    bpy.context.scene.render.filepath = p
    bpy.ops.render.render(write_still=True)
    ratio, n, total = stats(p)
    print("@@@ %-16s %10s %10.6f %8d %8d" % (tag, dist, ratio, n, total))
print("@@@ DONE")
