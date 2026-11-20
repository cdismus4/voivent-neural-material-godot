extends Node

const _VnmLdr = preload("res://addons/voivent_neural_material/vnm_loader.gd")
const _VnmGen = preload("res://addons/voivent_neural_material/vnm_shader_generator.gd")

const GATE_STRICT := 1.0e-4
const GATE_HW_ARBITRARY := 2.0e-4
const PROFILES := ["standard", "standard8", "quality", "quality8"]

func _pack_weights_tex(profile: String, w: Dictionary) -> ImageTexture:
	var f := PackedFloat32Array()
	for key in ["w1", "b1", "w2", "b2", "w3", "b3"]:
		var arr: Array = w[key]
		for x in arr:
			f.append(float(x))
	var expected := int(_VnmLdr.PROFILE_SPECS[profile]["total_weights"])
	assert(f.size() == expected)
	var vec4_count := (expected + 3) / 4
	var tex_w := 32
	var tex_h := maxi(1, (vec4_count + tex_w - 1) / tex_w)
	var padded := PackedFloat32Array()
	padded.resize(tex_w * tex_h * 4)
	padded.fill(0.0)
	for i in range(expected):
		padded[i] = f[i]
	var img := Image.create_from_data(tex_w, tex_h, false, Image.FORMAT_RGBAF, padded.to_byte_array())
	return ImageTexture.create_from_image(img)

func _build_float_latent_textures(vals: Array, w: int, h: int, ch: int) -> Array[ImageTexture]:
	var out: Array[ImageTexture] = []
	var count := w * h
	if ch == 4:
		var f := PackedFloat32Array()
		f.resize(count * 4)
		for i in range(count * 4):
			f[i] = float(vals[i])
		out.append(ImageTexture.create_from_image(Image.create_from_data(w, h, false, Image.FORMAT_RGBAF, f.to_byte_array())))
		return out
	var f0 := PackedFloat32Array()
	var f1 := PackedFloat32Array()
	f0.resize(count * 4)
	f1.resize(count * 4)
	for i in range(count):
		var s := i * 8
		var d := i * 4
		for k in range(4):
			f0[d + k] = float(vals[s + k])
			f1[d + k] = float(vals[s + 4 + k])
	out.append(ImageTexture.create_from_image(Image.create_from_data(w, h, false, Image.FORMAT_RGBAF, f0.to_byte_array())))
	out.append(ImageTexture.create_from_image(Image.create_from_data(w, h, false, Image.FORMAT_RGBAF, f1.to_byte_array())))
	return out

func _build_u8_latent_textures(vals: PackedByteArray, w: int, h: int, ch: int) -> Array[ImageTexture]:
	return _VnmLdr._build_latent_textures(vals, w, h, ch)

func _to_packed_bytes(arr: Array) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(arr.size())
	for i in range(arr.size()):
		b[i] = int(arr[i]) & 0xFF
	return b

func _is_lattice_coord(coord: float, size: int) -> bool:
	var texel := coord * float(size) - 0.5
	return absf(texel - round(texel)) < 1.0e-5

func _is_case_lattice(c: Dictionary, fine_sz: Vector2i, coarse_sz: Vector2i) -> bool:
	var uv_arr: Array = c["uv"]
	var u := float(uv_arr[0])
	var v := float(uv_arr[1])
	return _is_lattice_coord(u, fine_sz.x) and _is_lattice_coord(v, fine_sz.y) and _is_lattice_coord(u, coarse_sz.x) and _is_lattice_coord(v, coarse_sz.y)

func _run_shader_pass(
	profile: String,
	path: _VnmGen.SamplingPath,
	weights_tex: ImageTexture,
	fine_textures: Array[ImageTexture],
	coarse_textures: Array[ImageTexture],
	fine_sz: Vector2i,
	coarse_sz: Vector2i,
	cases_tex: ImageTexture,
	case_count: int,
	latent_is_float: bool,
	output_pbr_post: bool,
) -> Array:
	var sv := SubViewport.new()
	sv.size = Vector2i(case_count, 18)
	sv.own_world_3d = true
	sv.use_hdr_2d = true
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(sv)

	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 2.0
	cam.position = Vector3(0.0, 0.0, 2.0)
	sv.add_child(cam)

	var shader := Shader.new()
	shader.code = _VnmGen.generate_verification_shader_code(profile, path, "repeat", "repeat", case_count)
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("weights_tex", weights_tex)
	mat.set_shader_parameter("fine_tex0", fine_textures[0])
	mat.set_shader_parameter("coarse_tex0", coarse_textures[0])
	if fine_textures.size() > 1:
		mat.set_shader_parameter("fine_tex1", fine_textures[1])
		mat.set_shader_parameter("coarse_tex1", coarse_textures[1])
	mat.set_shader_parameter("fine_size", fine_sz)
	mat.set_shader_parameter("coarse_size", coarse_sz)
	mat.set_shader_parameter("cases_tex", cases_tex)
	mat.set_shader_parameter("latent_is_float", latent_is_float)
	mat.set_shader_parameter("output_pbr_post", output_pbr_post)

	var quad := MeshInstance3D.new()
	var pm := QuadMesh.new()
	pm.size = Vector2(2.0 * float(case_count) / 18.0, 2.0)
	quad.mesh = pm
	quad.material_override = mat
	sv.add_child(quad)

	await get_tree().process_frame
	RenderingServer.force_draw(false)
	await get_tree().process_frame
	RenderingServer.force_draw(false)
	var img := sv.get_texture().get_image()
	sv.queue_free()

	var ch_count := 9 if output_pbr_post else 8
	var decoded := []
	decoded.resize(case_count)
	for ci in range(case_count):
		var vals: Array[float] = []
		vals.resize(ch_count)
		for ch in range(ch_count):
			var c_lo := img.get_pixel(ci, ch * 2)
			var c_hi := img.get_pixel(ci, ch * 2 + 1)
			var b0 := int(round(c_lo.r * 255.0)) & 0xFF
			var b1 := int(round(c_lo.g * 255.0)) & 0xFF
			var b2 := int(round(c_hi.r * 255.0)) & 0xFF
			var b3 := int(round(c_hi.g * 255.0)) & 0xFF
			var pbytes := PackedByteArray([b0, b1, b2, b3])
			vals[ch] = pbytes.decode_float(0)
		decoded[ci] = vals
	return decoded

func _eval_raw_errors(actual_cases: Array, golden_cases: Array, expect_key: String, fine_sz: Vector2i, coarse_sz: Vector2i) -> Dictionary:
	var max_all := 0.0
	var max_lattice := 0.0
	var max_arbitrary := 0.0
	var lattice_count := 0
	var arbitrary_count := 0
	var sq_sum := 0.0
	var elem_count := 0
	for i in range(golden_cases.size()):
		var gc: Dictionary = golden_cases[i]
		var exp_arr: Array = gc[expect_key]
		var act_arr: Array = actual_cases[i]
		var is_lat := _is_case_lattice(gc, fine_sz, coarse_sz)
		if is_lat:
			lattice_count += 1
		else:
			arbitrary_count += 1
		for k in range(8):
			var d := absf(float(act_arr[k]) - float(exp_arr[k]))
			if is_nan(d) or is_inf(d):
				d = 999.0
			sq_sum += d * d
			elem_count += 1
			if d > max_all: max_all = d
			if is_lat and d > max_lattice: max_lattice = d
			if (not is_lat) and d > max_arbitrary: max_arbitrary = d
	return {
		"max_abs_err": max_all,
		"rmse": sqrt(sq_sum / maxf(1.0, float(elem_count))),
		"lattice_count": lattice_count,
		"arbitrary_count": arbitrary_count,
		"max_lattice_err": max_lattice,
		"max_arbitrary_err": max_arbitrary,
	}

func _eval_pbr_errors(actual_cases: Array, golden_cases: Array, expect_key: String) -> float:
	var max_err := 0.0
	for i in range(golden_cases.size()):
		var pbr: Dictionary = golden_cases[i][expect_key]
		var act: Array = actual_cases[i]
		var exp_vals := [
			float(pbr["baseColor"][0]), float(pbr["baseColor"][1]), float(pbr["baseColor"][2]),
			float(pbr["normal"][0]), float(pbr["normal"][1]), float(pbr["normal"][2]),
			float(pbr["roughness"]), float(pbr["metalness"]), float(pbr["ao"]),
		]
		for k in range(9):
			var d := absf(float(act[k]) - float(exp_vals[k]))
			if is_nan(d) or d > max_err:
				max_err = d
	return max_err

func _ready() -> void:
	var golden_dir := OS.get_environment("VNM_GOLDEN_DIR")
	if golden_dir.is_empty():
		golden_dir = ProjectSettings.globalize_path("res://../voivent-neural-material/src/__tests__/fixtures")

	var device_name := "%s (%s)" % [RenderingServer.get_video_adapter_name(), RenderingServer.get_video_adapter_api_version()]
	print("[G-4] Running 4-profile x 286-case SPEC §7 harness on: ", device_name)

	var all_passed := true
	var profile_reports := {}

	for profile in PROFILES:
		var json_path := "%s/golden_vectors_%s.json" % [golden_dir, profile]
		var parsed: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(json_path))
		var meta: Dictionary = parsed["meta"]
		var ch := int(meta.get("latent_channels_per_grid", 4))
		var fine_sz := Vector2i(int(meta["fine_size"][0]), int(meta["fine_size"][1]))
		var coarse_sz := Vector2i(int(meta["coarse_size"][0]), int(meta["coarse_size"][1]))
		var cases: Array = parsed["cases"]
		var case_count := cases.size()

		var weights_tex := _pack_weights_tex(profile, parsed["weights"])
		var fine_float_tex := _build_float_latent_textures(parsed["fine_float"], fine_sz.x, fine_sz.y, ch)
		var coarse_float_tex := _build_float_latent_textures(parsed["coarse_float"], coarse_sz.x, coarse_sz.y, ch)

		var fine_u8_bytes := _to_packed_bytes(parsed["fine_u8"])
		var coarse_u8_bytes := _to_packed_bytes(parsed["coarse_u8"])
		var fine_u8_tex := _build_u8_latent_textures(fine_u8_bytes, fine_sz.x, fine_sz.y, ch)
		var coarse_u8_tex := _build_u8_latent_textures(coarse_u8_bytes, coarse_sz.x, coarse_sz.y, ch)

		# Pack cases_tex (u, v, normalizedMip, wrapFlags)
		var c_f32 := PackedFloat32Array()
		c_f32.resize(case_count * 4)
		for ci in range(case_count):
			var c: Dictionary = cases[ci]
			var wflags := (1 if str(c["wrapU"]) == "repeat" else 0) | (2 if str(c["wrapV"]) == "repeat" else 0)
			c_f32[ci * 4 + 0] = float(c["uv"][0])
			c_f32[ci * 4 + 1] = float(c["uv"][1])
			c_f32[ci * 4 + 2] = float(c["normalizedMip"])
			c_f32[ci * 4 + 3] = float(wflags)
		var cases_tex := ImageTexture.create_from_image(Image.create_from_data(case_count, 1, false, Image.FORMAT_RGBAF, c_f32.to_byte_array()))

		# 1. Path B (EXACT_BILINEAR) - float grids (SPEC §7.1 gate <= 1e-4)
		var pb_float_raw := await _run_shader_pass(profile, _VnmGen.SamplingPath.EXACT_BILINEAR, weights_tex, fine_float_tex, coarse_float_tex, fine_sz, coarse_sz, cases_tex, case_count, true, false)
		var pb_float_pbr := await _run_shader_pass(profile, _VnmGen.SamplingPath.EXACT_BILINEAR, weights_tex, fine_float_tex, coarse_float_tex, fine_sz, coarse_sz, cases_tex, case_count, true, true)
		var pb_float_stats := _eval_raw_errors(pb_float_raw, cases, "expected_raw_float", fine_sz, coarse_sz)
		var pb_float_pbr_err := _eval_pbr_errors(pb_float_pbr, cases, "expected_pbr_float")
		var pb_float_ok := float(pb_float_stats["max_abs_err"]) <= GATE_STRICT and pb_float_pbr_err <= GATE_STRICT

		# 2. Path B (EXACT_BILINEAR) - u8 grids (SPEC §7.1 gate <= 1e-4)
		var pb_u8_raw := await _run_shader_pass(profile, _VnmGen.SamplingPath.EXACT_BILINEAR, weights_tex, fine_u8_tex, coarse_u8_tex, fine_sz, coarse_sz, cases_tex, case_count, false, false)
		var pb_u8_stats := _eval_raw_errors(pb_u8_raw, cases, "expected_raw_u8", fine_sz, coarse_sz)
		var pb_u8_ok := float(pb_u8_stats["max_abs_err"]) <= GATE_STRICT

		# 3. Path A (HARDWARE_BILINEAR) - u8 grids (SPEC §7.2 lattice <= 1e-4, arbitrary <= 2.0e-4)
		var pa_u8_raw := await _run_shader_pass(profile, _VnmGen.SamplingPath.HARDWARE_BILINEAR, weights_tex, fine_u8_tex, coarse_u8_tex, fine_sz, coarse_sz, cases_tex, case_count, false, false)
		var pa_u8_stats := _eval_raw_errors(pa_u8_raw, cases, "expected_raw_u8", fine_sz, coarse_sz)
		var pa_ok := float(pa_u8_stats["max_lattice_err"]) <= GATE_STRICT and float(pa_u8_stats["max_arbitrary_err"]) <= GATE_HW_ARBITRARY

		# 4. Negative Control: Shuffle fine_u8 deterministically -> MUST FAIL gate (> 1e-4)
		var shuf := fine_u8_bytes.duplicate()
		var n_bytes := shuf.size()
		for bi in range(n_bytes):
			var j := (bi * 97 + 13) % n_bytes
			var tmp := shuf[bi]
			shuf[bi] = shuf[j]
			shuf[j] = tmp
		var shuf_fine_tex := _build_u8_latent_textures(shuf, fine_sz.x, fine_sz.y, ch)
		var neg_raw := await _run_shader_pass(profile, _VnmGen.SamplingPath.EXACT_BILINEAR, weights_tex, shuf_fine_tex, coarse_u8_tex, fine_sz, coarse_sz, cases_tex, case_count, false, false)
		var neg_stats := _eval_raw_errors(neg_raw, cases, "expected_raw_u8", fine_sz, coarse_sz)
		var neg_rejected := float(neg_stats["max_abs_err"]) > GATE_STRICT

		var prof_passed := pb_float_ok and pb_u8_ok and pa_ok and neg_rejected
		all_passed = all_passed and prof_passed

		profile_reports[profile] = {
			"case_count": case_count,
			"passed": prof_passed,
			"path_b_float": {"raw_max_abs_err": pb_float_stats["max_abs_err"], "pbr_max_abs_err": pb_float_pbr_err, "rmse": pb_float_stats["rmse"], "passed": pb_float_ok},
			"path_b_u8": {"raw_max_abs_err": pb_u8_stats["max_abs_err"], "rmse": pb_u8_stats["rmse"], "passed": pb_u8_ok},
			"path_a_hw_u8": {
				"lattice_count": pa_u8_stats["lattice_count"],
				"arbitrary_count": pa_u8_stats["arbitrary_count"],
				"max_lattice_err": pa_u8_stats["max_lattice_err"],
				"max_arbitrary_err": pa_u8_stats["max_arbitrary_err"],
				"rmse": pa_u8_stats["rmse"],
				"passed": pa_ok,
			},
			"negative_control_shuffled_latents": {
				"max_abs_err": neg_stats["max_abs_err"],
				"rejected_as_expected": neg_rejected,
			},
		}

		print("[G-4] ", profile, " PASS=", prof_passed,
			" | PathB(float)=", String.num_scientific(float(pb_float_stats["max_abs_err"])),
			" | PathB(u8)=", String.num_scientific(float(pb_u8_stats["max_abs_err"])),
			" | PathA(lat/arb)=", String.num_scientific(float(pa_u8_stats["max_lattice_err"])), " / ", String.num_scientific(float(pa_u8_stats["max_arbitrary_err"])),
			" | NegCtrl=", String.num_scientific(float(neg_stats["max_abs_err"])), " (rejected=", neg_rejected, ")")

	var report := {
		"suite": "VNM1-Godot-G4-SPEC7",
		"godot_version": Engine.get_version_info().get("string", ""),
		"adapter": device_name,
		"all_passed": all_passed,
		"profiles": profile_reports,
	}
	var out_path := ProjectSettings.globalize_path("res://tests/reports/godot_g4_report.json")
	var fa := FileAccess.open(out_path, FileAccess.WRITE)
	fa.store_string(JSON.stringify(report, "  "))
	fa.close()
	print("[G-4 SUMMARY] all_passed=", all_passed, " report=", out_path)
	get_tree().quit(0 if all_passed else 1)
