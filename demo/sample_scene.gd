extends Node3D

const _VnmMat = preload("res://addons/voivent_neural_material/vnm_material.gd")
const _VnmPkg = preload("res://addons/voivent_neural_material/vnm_package.gd")

## Sample scene demonstrating G-3 Public API (`VnmMaterial`) cleanly.
## Pass `--vnm-dir=<path>` on CLI or set `VNM_SAMPLE_PATH` env var to load a .vnm directory or .zip.

var _mesh_node: MeshInstance3D

func _ready() -> void:
	var cam := Camera3D.new()
	cam.position = Vector3(0.0, 0.3, 2.8)
	add_child(cam)
	cam.look_at(Vector3.ZERO, Vector3.UP)

	var light := DirectionalLight3D.new()
	light.position = Vector3(2.0, 3.0, 2.5)
	add_child(light)
	light.look_at(Vector3.ZERO, Vector3.UP)

	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.07, 0.08, 0.1)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.25, 0.27, 0.32)
	e.ambient_light_energy = 1.0
	env.environment = e
	add_child(env)

	_mesh_node = MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.85
	sphere.height = 1.7
	_mesh_node.mesh = sphere
	add_child(_mesh_node)

	var vnm_path := OS.get_environment("VNM_SAMPLE_PATH")
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--vnm="):
			vnm_path = arg.substr("--vnm=".length())

	if not vnm_path.is_empty():
		var res := _VnmMat.apply_to_mesh(_mesh_node, vnm_path)
		if not res.get("ok", false):
			push_error("VnmMaterial load failed: %s" % str(res.get("error", "")))
		else:
			print("[Sample] Applied VNM1 asset: ", (res["package"] as _VnmPkg).asset_id)

func _process(delta: float) -> void:
	if _mesh_node != null:
		_mesh_node.rotate_y(delta * 0.4)
