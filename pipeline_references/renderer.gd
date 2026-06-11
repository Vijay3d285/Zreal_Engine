extends "res://render.gd"

# renderer.gd
# Wrapper to maintain compatibility with existing execution scripts.
# The real logic is now split into:
# - image_glb_creation.gd (Scene Building)
# - render.gd (Camera & Rendering)

func _init():
	use_threejs = true # Set to false to default to Blender camera
	convert_blender_camera = true # Set to false to use Blender coordinates directly without (x, z, -y) conversion
	day_render = true # Set to false for night render with dark sky and moonlight
