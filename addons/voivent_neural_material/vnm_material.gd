class_name VnmMaterial
extends RefCounted

## Public API for loading Voivent Neural Material (.vnm directory or .zip)
## and binding GPU shader materials to Godot MeshInstance3D nodes.

const _VnmPkg = preload("res://addons/voivent_neural_material/vnm_package.gd")
const _VnmLdr = preload("res://addons/voivent_neural_material/vnm_loader.gd")
const _VnmGen = preload("res://addons/voivent_neural_material/vnm_shader_generator.gd")

static var _shader_cache: Dictionary = {}

var package: _VnmPkg
var material: ShaderMaterial
var sampling_path: _VnmGen.SamplingPath

func _init(p_package: _VnmPkg, p_path: _VnmGen.SamplingPath = _VnmGen.SamplingPath.HARDWARE_BILINEAR) -> void:
	package = p_package
	sampling_path = p_path
	material = _build_material()

static func load_from_path(
	vnm_path: String,
	p_path: _VnmGen.SamplingPath = _VnmGen.SamplingPath.HARDWARE_BILINEAR,
) -> Dictionary:
	var loaded := _VnmLdr.load_package(vnm_path)
	if not loaded.get("ok", false):
		return loaded
	var pkg: _VnmPkg = loaded["package"]
	var vnm_mat := new(pkg, p_path)
	return {"ok": true, "error": "", "vnm_material": vnm_mat, "package": pkg}

static func apply_to_mesh(
	mesh_instance: MeshInstance3D,
	vnm_path: String,
	p_path: _VnmGen.SamplingPath = _VnmGen.SamplingPath.HARDWARE_BILINEAR,
	surface_index: int = -1,
) -> Dictionary:
	var res := load_from_path(vnm_path, p_path)
	if not res.get("ok", false):
		return res
	var vnm_mat: Variant = res["vnm_material"]
	vnm_mat.bind_to_mesh(mesh_instance, surface_index)
	return res

func bind_to_mesh(mesh_instance: MeshInstance3D, surface_index: int = -1) -> void:
	if surface_index >= 0:
		mesh_instance.set_surface_override_material(surface_index, material)
	else:
		mesh_instance.material_override = material

func set_normalized_mip_override(enabled: bool, value: float = 0.0) -> void:
	material.set_shader_parameter("use_normalized_mip_override", enabled)
	material.set_shader_parameter("normalized_mip_override", clampf(value, 0.0, 1.0))

func set_tail_switch_enabled(enabled: bool) -> void:
	material.set_shader_parameter("enable_tail_switch", enabled)

func set_tail_crossfade_enabled(enabled: bool) -> void:
	material.set_shader_parameter("enable_tail_crossfade", enabled)

func set_tail_blend_range(start_mip: float, end_mip: float) -> void:
	material.set_shader_parameter("tail_blend_start", start_mip)
	material.set_shader_parameter("tail_blend_end", maxf(start_mip, end_mip))

func set_latent_lod_enabled(enabled: bool) -> void:
	material.set_shader_parameter("enable_latent_lod", enabled)

func set_lod_mip_enabled(enabled: bool) -> void:
	material.set_shader_parameter("enable_lod_mip", enabled)

func _build_material() -> ShaderMaterial:
	var key := "%s:%d:%s:%s" % [package.profile, int(sampling_path), package.wrap_u, package.wrap_v]
	var shader: Shader = _shader_cache.get(key, null)
	if shader == null:
		shader = Shader.new()
		shader.code = _VnmGen.generate_spatial_pbr_shader_code(
			package.profile,
			sampling_path,
			package.wrap_u,
			package.wrap_v,
		)
		_shader_cache[key] = shader

	var mat := ShaderMaterial.new()
	mat.shader = shader
	bind_package_parameters(mat, package)
	return mat

static func bind_package_parameters(mat: ShaderMaterial, pkg: _VnmPkg) -> void:
	mat.set_shader_parameter("weights_tex", pkg.weights_texture)
	mat.set_shader_parameter("fine_tex0", pkg.fine_textures[0])
	mat.set_shader_parameter("coarse_tex0", pkg.coarse_textures[0])
	if pkg.latent_channels == 8:
		mat.set_shader_parameter("fine_tex1", pkg.fine_textures[1])
		mat.set_shader_parameter("coarse_tex1", pkg.coarse_textures[1])
	mat.set_shader_parameter("tail_tex0", pkg.tail_textures[0])
	mat.set_shader_parameter("tail_tex1", pkg.tail_textures[1])
	mat.set_shader_parameter("fine_size", pkg.fine_size)
	mat.set_shader_parameter("coarse_size", pkg.coarse_size)
	mat.set_shader_parameter("source_size", Vector2(pkg.source_size))
	mat.set_shader_parameter("mip_max", pkg.get_resolved_mip_max())
	mat.set_shader_parameter("tail_first_mip", float(pkg.tail_first_mip))
	mat.set_shader_parameter("wrap_u_repeat", pkg.wrap_u == "repeat")
	mat.set_shader_parameter("wrap_v_repeat", pkg.wrap_v == "repeat")
	mat.set_shader_parameter("enable_lod_mip", pkg.has_explicit_mip_max)
	mat.set_shader_parameter("enable_latent_lod", true)
	mat.set_shader_parameter("enable_tail_switch", true)
	mat.set_shader_parameter("enable_tail_crossfade", true)
	mat.set_shader_parameter("tail_blend_start", 3.0)
	mat.set_shader_parameter("tail_blend_end", 5.0)
	mat.set_shader_parameter("use_normalized_mip_override", false)
	mat.set_shader_parameter("normalized_mip_override", 0.0)
