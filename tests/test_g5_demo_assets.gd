extends Node

const _VnmMat = preload("res://addons/voivent_neural_material/vnm_material.gd")
const _VnmPkg = preload("res://addons/voivent_neural_material/vnm_package.gd")
const _VnmGen = preload("res://addons/voivent_neural_material/vnm_shader_generator.gd")

const DEMO_ASSET_SUBPATHS := [
	{"id": "marble", "subpath": "marble/marble.vnm"},
	{"id": "fabric030", "subpath": "fabric030/ambientcg-fabric030-1k.vnm"},
	{"id": "sand", "subpath": "sand/sand.vnm"},
	{"id": "cloth", "subpath": "cloth/cloth.vnm"},
]

# Canonical SPEC §6 CPU reference decoder in GDScript for G-5 real-asset verification
static func _wrap_index_cpu(idx: int, size: int, is_repeat: bool) -> int:
	if is_repeat:
		var m := idx % size
		return m + size if m < 0 else m
	return clampi(idx, 0, size - 1)

static func _sample_u8_grid_cpu(bytes: PackedByteArray, w: int, h: int, ch: int, u_eff: float, v_eff: float, rep_u: bool, rep_v: bool) -> PackedFloat32Array:
	var p := u_eff * float(w) - 0.5
	var q := v_eff * float(h) - 0.5
	var x0 := int(floor(p))
	var y0 := int(floor(q))
	var fx := p - float(x0)
	var fy := q - float(y0)
	var ix0 := _wrap_index_cpu(x0, w, rep_u)
	var ix1 := _wrap_index_cpu(x0 + 1, w, rep_u)
	var iy0 := _wrap_index_cpu(y0, h, rep_v)
	var iy1 := _wrap_index_cpu(y0 + 1, h, rep_v)

	var out := PackedFloat32Array()
	out.resize(ch)
	var i00 := (iy0 * w + ix0) * ch
	var i10 := (iy0 * w + ix1) * ch
	var i01 := (iy1 * w + ix0) * ch
	var i11 := (iy1 * w + ix1) * ch
	for c in range(ch):
		var f00 := (2.0 * float(bytes[i00 + c]) / 255.0) - 1.0
		var f10 := (2.0 * float(bytes[i10 + c]) / 255.0) - 1.0
		var f01 := (2.0 * float(bytes[i01 + c]) / 255.0) - 1.0
		var f11 := (2.0 * float(bytes[i11 + c]) / 255.0) - 1.0
		var top := f00 * (1.0 - fx) + f10 * fx
		var bot := f01 * (1.0 - fx) + f11 * fx
		out[c] = top * (1.0 - fy) + bot * fy
	return out

static func _decode_raw_cpu(pkg: _VnmPkg, u: float, v: float, norm_mip: float) -> PackedFloat32Array:
	var rep_u := pkg.wrap_u == "repeat"
	var rep_v := pkg.wrap_v == "repeat"
	var u_eff: float = (u - floor(u)) if rep_u else clampf(u, 0.0, 1.0)
	var v_eff: float = (v - floor(v)) if rep_v else clampf(v, 0.0, 1.0)
	var ch := pkg.latent_channels
	var fine_v := _sample_u8_grid_cpu(pkg.fine_bytes, pkg.fine_size.x, pkg.fine_size.y, ch, u_eff, v_eff, rep_u, rep_v)
	var coarse_v := _sample_u8_grid_cpu(pkg.coarse_bytes, pkg.coarse_size.x, pkg.coarse_size.y, ch, u_eff, v_eff, rep_u, rep_v)

	var p_fine: float = u_eff * float(pkg.fine_size.x) - 0.5
	var q_fine: float = v_eff * float(pkg.fine_size.y) - 0.5
	var rx: float = 2.0 * (p_fine - floor(p_fine)) - 1.0
	var ry: float = 2.0 * (q_fine - floor(q_fine)) - 1.0

	var x := PackedFloat32Array()
	x.resize(pkg.input_dim)
	for c in range(ch):
		x[c] = fine_v[c]
		x[ch + c] = coarse_v[c]
	x[2 * ch + 0] = rx
	x[2 * ch + 1] = ry
	x[2 * ch + 2] = norm_mip
	x[2 * ch + 3] = 1.0

	var wf := pkg.weights_bytes.to_float32_array()
	var off := 0
	var w1_sz := pkg.hidden1 * pkg.input_dim
	var b1_off := off + w1_sz
	var w2_off := b1_off + pkg.hidden1
	var w2_sz := pkg.hidden2 * pkg.hidden1
	var b2_off := w2_off + w2_sz
	var w3_off := b2_off + pkg.hidden2
	var w3_sz := pkg.output_dim * pkg.hidden2
	var b3_off := w3_off + w3_sz

	var h1 := PackedFloat32Array()
	h1.resize(pkg.hidden1)
	for o in range(pkg.hidden1):
		var acc := wf[b1_off + o]
		var row := off + o * pkg.input_dim
		for k in range(pkg.input_dim):
			acc += wf[row + k] * x[k]
		h1[o] = maxf(0.0, acc)

	var h2 := PackedFloat32Array()
	h2.resize(pkg.hidden2)
	for o in range(pkg.hidden2):
		var acc := wf[b2_off + o]
		var row := w2_off + o * pkg.hidden1
		for k in range(pkg.hidden1):
			acc += wf[row + k] * h1[k]
		h2[o] = maxf(0.0, acc)

	var out := PackedFloat32Array()
	out.resize(8)
	for o in range(8):
		var acc := wf[b3_off + o]
		var row := w3_off + o * pkg.hidden2
		for k in range(pkg.hidden2):
			acc += wf[row + k] * h2[k]
		out[o] = acc
	return out

func _readback_64x64(pkg: _VnmPkg, path: _VnmGen.SamplingPath, uvs: Array[Vector2]) -> Array:
	var count := uvs.size()
	var sv := SubViewport.new()
	sv.size = Vector2i(count, 18)
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
	shader.code = _VnmGen.generate_verification_shader_code(pkg.profile, path, pkg.wrap_u, pkg.wrap_v, count)
	var mat := ShaderMaterial.new()
	mat.shader = shader
	_VnmMat.bind_package_parameters(mat, pkg)

	var c_f32 := PackedFloat32Array()
	c_f32.resize(count * 4)
	var wflags := (1 if pkg.wrap_u == "repeat" else 0) | (2 if pkg.wrap_v == "repeat" else 0)
	for i in range(count):
		c_f32[i * 4 + 0] = uvs[i].x
		c_f32[i * 4 + 1] = uvs[i].y
		c_f32[i * 4 + 2] = 0.0
		c_f32[i * 4 + 3] = float(wflags)
	var cases_tex := ImageTexture.create_from_image(Image.create_from_data(count, 1, false, Image.FORMAT_RGBAF, c_f32.to_byte_array()))
	mat.set_shader_parameter("cases_tex", cases_tex)
	mat.set_shader_parameter("latent_is_float", false)
	mat.set_shader_parameter("output_pbr_post", false)

	var quad := MeshInstance3D.new()
	var pm := QuadMesh.new()
	pm.size = Vector2(2.0 * float(count) / 18.0, 2.0)
	quad.mesh = pm
	quad.material_override = mat
	sv.add_child(quad)

	await get_tree().process_frame
	RenderingServer.force_draw(false)
	await get_tree().process_frame
	RenderingServer.force_draw(false)
	var img := sv.get_texture().get_image()
	sv.queue_free()

	var out := []
	out.resize(count)
	for i in range(count):
		var vals: Array[float] = []
		vals.resize(8)
		for ch in range(8):
			var c_lo := img.get_pixel(i, ch * 2)
			var c_hi := img.get_pixel(i, ch * 2 + 1)
			var bytes := PackedByteArray([
				int(round(c_lo.r * 255.0)) & 0xFF,
				int(round(c_lo.g * 255.0)) & 0xFF,
				int(round(c_hi.r * 255.0)) & 0xFF,
				int(round(c_hi.g * 255.0)) & 0xFF,
			])
			vals[ch] = bytes.decode_float(0)
		out[i] = vals
	return out

func _spot_render_lit_scene(mat: Material, frames: int) -> Dictionary:
	var sv := SubViewport.new()
	sv.size = Vector2i(512, 512)
	sv.own_world_3d = true
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(sv)

	var cam := Camera3D.new()
	cam.position = Vector3(0.0, 0.0, 1.8)
	sv.add_child(cam)

	var light := DirectionalLight3D.new()
	light.position = Vector3(1.5, 2.0, 2.0)
	light.look_at_from_position(light.position, Vector3.ZERO, Vector3.UP)
	sv.add_child(light)

	var sphere := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.85
	sm.height = 1.7
	sphere.mesh = sm
	sphere.material_override = mat
	sv.add_child(sphere)

	# Warmup
	for _w in range(10):
		await get_tree().process_frame
		RenderingServer.force_draw(false)

	var t0 := Time.get_ticks_usec()
	for _f in range(frames):
		sphere.rotate_y(0.01)
		await get_tree().process_frame
		RenderingServer.force_draw(false)
	var elapsed_ms := float(Time.get_ticks_usec() - t0) / 1000.0
	var sample_img := sv.get_texture().get_image()
	var px := sample_img.get_pixel(256, 256)
	var has_nan := is_nan(px.r) or is_nan(px.g) or is_nan(px.b)
	sv.queue_free()
	return {"avg_frame_ms": elapsed_ms / float(frames), "center_pixel": [px.r, px.g, px.b], "has_nan": has_nan}

func _ready() -> void:
	var assets_root := OS.get_environment("VNM_DEMO_ASSETS_DIR")
	if assets_root.is_empty():
		assets_root = ProjectSettings.globalize_path("res://../../satellite/worker/assets/lab/vnm/demo-assets")

	var renderer_driver := OS.get_cmdline_args()
	var is_compat := RenderingServer.get_current_rendering_method() == "gl_compatibility"
	print("[G-5] Testing 4 real demo assets on: ", RenderingServer.get_video_adapter_name(), " method=", RenderingServer.get_current_rendering_method(), " is_compat=", is_compat)

	# StandardMaterial3D spot baseline (512x512 dummy texture)
	var base_img := Image.create(512, 512, false, Image.FORMAT_RGBA8)
	base_img.fill(Color(0.5, 0.5, 0.5, 1.0))
	var base_tex := ImageTexture.create_from_image(base_img)
	var baseline_mat := StandardMaterial3D.new()
	baseline_mat.albedo_texture = base_tex
	baseline_mat.normal_enabled = true
	baseline_mat.normal_texture = base_tex
	baseline_mat.roughness_texture = base_tex
	var baseline_perf := await _spot_render_lit_scene(baseline_mat, 60)
	print("[G-5 Baseline] StandardMaterial3D avg_frame_ms=", "%.3f" % float(baseline_perf["avg_frame_ms"]))

	var asset_reports := {}
	var all_ok := true

	for item in DEMO_ASSET_SUBPATHS:
		var aid: String = item["id"]
		var path := "%s/%s" % [assets_root, item["subpath"]]
		var res_hw := _VnmMat.load_from_path(path, _VnmGen.SamplingPath.HARDWARE_BILINEAR)
		var res_ex := _VnmMat.load_from_path(path, _VnmGen.SamplingPath.EXACT_BILINEAR)
		if not res_hw.get("ok", false) or not res_ex.get("ok", false):
			print("[G-5 FAIL] Could not load ", path)
			all_ok = false
			continue

		var mat_hw: _VnmMat = res_hw["vnm_material"]
		var mat_ex: _VnmMat = res_ex["vnm_material"]
		var pkg: _VnmPkg = res_hw["package"]

		# 1. Lit PBR render verification (Level 0 + Tail switch) on ALL renderers including Compatibility
		var lit_hw := await _spot_render_lit_scene(mat_hw.material, 60)
		var lit_ex := await _spot_render_lit_scene(mat_ex.material, 60)
		mat_hw.set_normalized_mip_override(true, 1.0) # Forces tail_first_mip check
		var lit_tail := await _spot_render_lit_scene(mat_hw.material, 10)
		mat_hw.set_normalized_mip_override(false, 0.0)

		var pb_max_err := 0.0
		var pa_max_err := 0.0
		if not is_compat:
			# 2. 64x64 lattice & sample verification (4096 points in 256-point chunks to fit SubViewport width nicely)
			var uvs: Array[Vector2] = []
			for y in range(64):
				for x in range(64):
					uvs.append(Vector2((float(x) + 0.5) / 64.0, (float(y) + 0.5) / 64.0))

			for chunk_start in range(0, uvs.size(), 512):
				var chunk_uvs := uvs.slice(chunk_start, chunk_start + 512)
				var gpu_ex := await _readback_64x64(pkg, _VnmGen.SamplingPath.EXACT_BILINEAR, chunk_uvs)
				var gpu_hw := await _readback_64x64(pkg, _VnmGen.SamplingPath.HARDWARE_BILINEAR, chunk_uvs)
				for i in range(chunk_uvs.size()):
					var cpu := _decode_raw_cpu(pkg, chunk_uvs[i].x, chunk_uvs[i].y, 0.0)
					var gex: Array = gpu_ex[i]
					var ghw: Array = gpu_hw[i]
					for k in range(8):
						pb_max_err = maxf(pb_max_err, absf(float(gex[k]) - float(cpu[k])))
						pa_max_err = maxf(pa_max_err, absf(float(ghw[k]) - float(cpu[k])))

		var ok: bool = (not bool(lit_hw["has_nan"])) and (not bool(lit_ex["has_nan"])) and (not bool(lit_tail["has_nan"]))
		if not is_compat:
			ok = ok and pb_max_err <= 1.0e-4 and pa_max_err <= 1.0e-4
		all_ok = all_ok and ok

		asset_reports[aid] = {
			"asset_id": pkg.asset_id,
			"profile": pkg.profile,
			"passed": ok,
			"path_b_64x64_max_abs_err": pb_max_err,
			"path_a_64x64_max_abs_err": pa_max_err,
			"lit_hw_avg_ms": lit_hw["avg_frame_ms"],
			"lit_ex_avg_ms": lit_ex["avg_frame_ms"],
			"tail_switch_center_pixel": lit_tail["center_pixel"],
		}
		print("[G-5] ", aid, " (", pkg.profile, ") PASS=", ok,
			" | 64x64 PathB=", String.num_scientific(pb_max_err),
			" | PathA=", String.num_scientific(pa_max_err),
			" | frame_ms(HW/EX)=", "%.3f / %.3f" % [float(lit_hw["avg_frame_ms"]), float(lit_ex["avg_frame_ms"])])

	var report := {
		"suite": "VNM1-Godot-G5-DemoAssets",
		"adapter": RenderingServer.get_video_adapter_name(),
		"rendering_method": RenderingServer.get_current_rendering_method(),
		"baseline_standard_mat_ms": baseline_perf["avg_frame_ms"],
		"all_passed": all_ok,
		"assets": asset_reports,
	}
	var report_name := "godot_g5_report_%s.json" % RenderingServer.get_current_rendering_method()
	var out_path := ProjectSettings.globalize_path("res://tests/reports/%s" % report_name)
	var fa := FileAccess.open(out_path, FileAccess.WRITE)
	fa.store_string(JSON.stringify(report, "  "))
	fa.close()
	print("[G-5 SUMMARY] all_passed=", all_ok, " report=", out_path)
	get_tree().quit(0 if all_ok else 1)
