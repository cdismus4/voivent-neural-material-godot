extends Node

const _VnmLdr = preload("res://addons/voivent_neural_material/vnm_loader.gd")
const _VnmMat = preload("res://addons/voivent_neural_material/vnm_material.gd")
const _VnmPkg = preload("res://addons/voivent_neural_material/vnm_package.gd")
const _VnmGen = preload("res://addons/voivent_neural_material/vnm_shader_generator.gd")

## O8 Regression Verification:
## 1) Non-square 2048x1024 (fine=1024x256, coarse=512x128) G-4/G-5 bit-exact & HW parity + Y-axis LOD filtering
## 2) sample_hw() clamp half-texel margin scaling by 2^lod at high LOD (no opposite-edge bleed or clamp UB)

func _sha256_bytes(data: PackedByteArray) -> String:
	var hc := HashingContext.new()
	hc.start(HashingContext.HASH_SHA256)
	hc.update(data)
	return hc.finish().hex_encode().to_lower()

func _make_header(kind: int, payload_len: int) -> PackedByteArray:
	var hdr := PackedByteArray()
	hdr.resize(16)
	hdr.fill(0)
	hdr.encode_u32(0, _VnmLdr.VNM_MAGIC)
	hdr.encode_u16(4, _VnmLdr.VNM_VERSION)
	hdr.encode_u16(6, kind)
	hdr.encode_u32(8, payload_len)
	hdr.encode_u32(12, 0)
	return hdr

func _build_identity_weights_standard() -> PackedByteArray:
	# standard profile: input_dim=12, h1=24, h2=24, out_dim=8, total_weights=1112
	# Map x[0..2] (fine_tex0.rgb) through identity ReLU bias (+1 shift then -1) into y[0..2].
	var total := int(_VnmLdr.PROFILE_SPECS["standard"]["total_weights"])
	var wf := PackedFloat32Array()
	wf.resize(total)
	wf.fill(0.0)
	var b1_off := 24 * 12
	var w2_off := b1_off + 24
	var b2_off := w2_off + 24 * 24
	var w3_off := b2_off + 24
	var b3_off := w3_off + 8 * 24

	for ch in range(3):
		wf[ch * 12 + ch] = 1.0
		wf[b1_off + ch] = 1.0 # shift [-1, 1] -> [0, 2] so ReLU preserves negative values
		wf[w2_off + ch * 24 + ch] = 1.0
		wf[b2_off + ch] = 0.0
		wf[w3_off + ch * 24 + ch] = 0.5 # map [0, 2] -> [0, 1] directly for ALBEDO
		wf[b3_off + ch] = 0.0
	return wf.to_byte_array()

func _write_synthetic_vnm(
	dst_dir: String,
	src_sz: Vector2i,
	fine_sz: Vector2i,
	coarse_sz: Vector2i,
	fine_bytes: PackedByteArray,
	coarse_bytes: PackedByteArray,
	wrap_u: String,
	wrap_v: String,
) -> void:
	DirAccess.make_dir_recursive_absolute(dst_dir)
	var w_payload := _build_identity_weights_standard()
	var w_bytes := _make_header(_VnmLdr.CHUNK_WEIGHTS, w_payload.size()) + w_payload

	var l_sub := PackedByteArray()
	l_sub.resize(16)
	l_sub.fill(0)
	l_sub.encode_u16(0, fine_sz.x)
	l_sub.encode_u16(2, fine_sz.y)
	l_sub.encode_u16(4, coarse_sz.x)
	l_sub.encode_u16(6, coarse_sz.y)
	l_sub.encode_u8(8, 1)
	l_sub.encode_u8(9, 1)
	var l_payload := l_sub + fine_bytes + coarse_bytes
	var l_bytes := _make_header(_VnmLdr.CHUNK_LATENTS, l_payload.size()) + l_payload

	var tw := 16
	var th := 16
	var t_sub := PackedByteArray()
	t_sub.resize(16)
	t_sub.fill(0)
	t_sub.encode_u16(0, tw)
	t_sub.encode_u16(2, th)
	t_sub.encode_u8(4, 7)
	t_sub.encode_u8(5, 8)
	t_sub.encode_u8(6, 1)
	var t_data := PackedByteArray()
	t_data.resize(tw * th * 8)
	t_data.fill(128)
	var t_payload := t_sub + t_data
	var t_bytes := _make_header(_VnmLdr.CHUNK_TAIL, t_payload.size()) + t_payload

	var manifest := {
		"format": "VNM1",
		"version": 1,
		"assetId": "vnm1-o8-synthetic",
		"sourceSize": [src_sz.x, src_sz.y],
		"profile": "standard",
		"quantization": "u8",
		"weightStoragePrecision": "f32",
		"computePrecision": "f32",
		"channels": "base3-normal2-rough-metal-ao",
		"baseColorSpace": "linear-srgb",
		"normalConvention": "tangent-positive-y-positive-z",
		"wrapU": wrap_u,
		"wrapV": wrap_v,
		"weights": {"url": "weights.bin", "sha256": _sha256_bytes(w_bytes), "byteLength": w_bytes.size()},
		"levels": [
			{
				"sourceMip": 0,
				"sourceSize": [src_sz.x, src_sz.y],
				"fineSize": [fine_sz.x, fine_sz.y],
				"coarseSize": [coarse_sz.x, coarse_sz.y],
				"chunk": {"url": "level-0.bin", "sha256": _sha256_bytes(l_bytes), "byteLength": l_bytes.size()},
			}
		],
		"tailFirstMip": 7,
		"tail": {"url": "tail.bin", "sha256": _sha256_bytes(t_bytes), "byteLength": t_bytes.size()},
		"mipMax": 6,
	}
	var files := {
		"manifest.json": JSON.stringify(manifest).to_utf8_buffer(),
		"weights.bin": w_bytes,
		"level-0.bin": l_bytes,
		"tail.bin": t_bytes,
	}
	for fn in files.keys():
		var fa := FileAccess.open("%s/%s" % [dst_dir, fn], FileAccess.WRITE)
		fa.store_buffer(files[fn])
		fa.close()

func _decode_cpu_identity_r(bytes: PackedByteArray, w: int, h: int, u: float, v: float, rep_u: bool, rep_v: bool) -> float:
	var u_eff: float = (u - floor(u)) if rep_u else clampf(u, 0.0, 1.0)
	var v_eff: float = (v - floor(v)) if rep_v else clampf(v, 0.0, 1.0)
	var p := u_eff * float(w) - 0.5
	var q := v_eff * float(h) - 0.5
	var x0 := int(floor(p))
	var y0 := int(floor(q))
	var fx := p - float(x0)
	var fy := q - float(y0)
	var wrap := func(i: int, sz: int, r: bool) -> int:
		if r:
			var m := i % sz
			return m + sz if m < 0 else m
		return clampi(i, 0, sz - 1)
	var ix0: int = wrap.call(x0, w, rep_u)
	var ix1: int = wrap.call(x0 + 1, w, rep_u)
	var iy0: int = wrap.call(y0, h, rep_v)
	var iy1: int = wrap.call(y0 + 1, h, rep_v)
	var samp := func(ix: int, iy: int) -> float:
		var qv := float(bytes[(iy * w + ix) * 4])
		return (2.0 * qv / 255.0) - 1.0
	var f00: float = samp.call(ix0, iy0)
	var f10: float = samp.call(ix1, iy0)
	var f01: float = samp.call(ix0, iy1)
	var f11: float = samp.call(ix1, iy1)
	return (f00 * (1.0 - fx) + f10 * fx) * (1.0 - fy) + (f01 * (1.0 - fx) + f11 * fx) * fy

func _run_verify_pass(pkg: _VnmPkg, path: _VnmGen.SamplingPath, uvs: Array[Vector2], rep_u: bool, rep_v: bool) -> Array[float]:
	var count := uvs.size()
	var cbuf := PackedFloat32Array()
	cbuf.resize(count * 4)
	var wf := (1 if rep_u else 0) | (2 if rep_v else 0)
	for i in range(count):
		cbuf[i * 4 + 0] = uvs[i].x
		cbuf[i * 4 + 1] = uvs[i].y
		cbuf[i * 4 + 2] = 0.0
		cbuf[i * 4 + 3] = float(wf)
	var cases_tex := ImageTexture.create_from_image(Image.create_from_data(count, 1, false, Image.FORMAT_RGBAF, cbuf.to_byte_array()))

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

	var sh := Shader.new()
	sh.code = _VnmGen.generate_verification_shader_code(pkg.profile, path, pkg.wrap_u, pkg.wrap_v, count)
	var mat := ShaderMaterial.new()
	mat.shader = sh
	_VnmMat.bind_package_parameters(mat, pkg)
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

	var out: Array[float] = []
	for ci in range(count):
		var c_lo := img.get_pixel(ci, 0)
		var c_hi := img.get_pixel(ci, 1)
		var pbytes := PackedByteArray([
			int(round(c_lo.r * 255.0)) & 0xFF,
			int(round(c_lo.g * 255.0)) & 0xFF,
			int(round(c_hi.r * 255.0)) & 0xFF,
			int(round(c_hi.g * 255.0)) & 0xFF,
		])
		out.append(pbytes.decode_float(0))
	return out

func _render_spatial_strip(pkg: _VnmPkg, norm_mip: float, test_uvs: Array[Vector2], rep_u: bool, rep_v: bool) -> Array[float]:
	# Renders raw spatial PBR unshaded readout using a modified spatial shader where ALBEDO = vec3(y[0])
	# via ShaderMaterial directly on a SubViewport quad at a single UV per column.
	var sv := SubViewport.new()
	sv.size = Vector2i(test_uvs.size(), 4)
	sv.own_world_3d = true
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(sv)

	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 2.0
	cam.position = Vector3(0.0, 0.0, 2.0)
	sv.add_child(cam)

	# Build a custom unshaded spatial wrapper around the generated core to inspect exact eval_vnm1_raw at lat_mip = norm_mip * mip_max
	var core := _VnmGen._build_common_core(pkg.profile, _VnmGen.SamplingPath.HARDWARE_BILINEAR, pkg.wrap_u, pkg.wrap_v)
	var frag := """
uniform sampler2D uvs_tex : filter_nearest, repeat_disable;
void fragment() {
	vec4 uvd = texelFetch(uvs_tex, ivec2(clamp(int(floor(UV.x * float(%d))), 0, %d), 0), 0);
	float y[8];
	float active_mip = normalized_mip_override * mip_max;
	eval_vnm1_raw(uvd.xy, normalized_mip_override, wrap_u_repeat, wrap_v_repeat, y, active_mip);
	ALBEDO = vec3(clamp(y[0], 0.0, 1.0), clamp(y[1], 0.0, 1.0), clamp(y[2], 0.0, 1.0));
}
""" % [test_uvs.size(), test_uvs.size() - 1]
	var sh := Shader.new()
	sh.code = "shader_type spatial;\nrender_mode unshaded;\n" + core + frag

	var ubuf := PackedFloat32Array()
	ubuf.resize(test_uvs.size() * 4)
	for i in range(test_uvs.size()):
		ubuf[i * 4 + 0] = test_uvs[i].x
		ubuf[i * 4 + 1] = test_uvs[i].y
		ubuf[i * 4 + 2] = 0.0
		ubuf[i * 4 + 3] = 1.0
	var uvs_tex := ImageTexture.create_from_image(Image.create_from_data(test_uvs.size(), 1, false, Image.FORMAT_RGBAF, ubuf.to_byte_array()))

	var mat := ShaderMaterial.new()
	mat.shader = sh
	_VnmMat.bind_package_parameters(mat, pkg)
	mat.set_shader_parameter("uvs_tex", uvs_tex)
	mat.set_shader_parameter("wrap_u_repeat", rep_u)
	mat.set_shader_parameter("wrap_v_repeat", rep_v)
	mat.set_shader_parameter("use_normalized_mip_override", true)
	mat.set_shader_parameter("normalized_mip_override", norm_mip)

	var quad := MeshInstance3D.new()
	var pm := QuadMesh.new()
	pm.size = Vector2(2.0 * float(test_uvs.size()) / 4.0, 2.0)
	quad.mesh = pm
	quad.material_override = mat
	sv.add_child(quad)

	await get_tree().process_frame
	RenderingServer.force_draw(false)
	await get_tree().process_frame
	RenderingServer.force_draw(false)
	var img := sv.get_texture().get_image()
	sv.queue_free()

	var vals: Array[float] = []
	for i in range(test_uvs.size()):
		vals.append(img.get_pixel(i, 2).r)
	return vals

func _ready() -> void:
	var all_ok := true

	# 0. Verify shader text contains both axis ratio max and LOD-scaled clamp margin
	var sh_code := _VnmGen.generate_spatial_pbr_shader_code("standard", _VnmGen.SamplingPath.HARDWARE_BILINEAR, "clamp", "clamp")
	if sh_code.find("source_size.y / max(float(fine_size.y), 1.0)") == -1:
		print("[O8 FAIL] Non-square fine Y-axis ratio check missing in shader")
		all_ok = false
	if sh_code.find("exp2(max(lod, 0.0))") == -1:
		print("[O8 FAIL] LOD-scaled clamp margin missing in sample_hw")
		all_ok = false

	# 1. Non-square 2048x1024 (fine=1024x256 -> rx=2, ry=4; coarse=512x128 -> rx=4, ry=8)
	var ns_dir := "/tmp/vnm_o8_nonsquare"
	var fine_sz := Vector2i(1024, 256)
	var coarse_sz := Vector2i(512, 128)
	var fine_bytes := PackedByteArray()
	fine_bytes.resize(fine_sz.x * fine_sz.y * 4)
	for y in range(fine_sz.y):
		var vbyte := 255 if (y % 2 == 0) else 0 # Y-axis alternating stripe
		for x in range(fine_sz.x):
			var o := (y * fine_sz.x + x) * 4
			fine_bytes[o] = vbyte
			fine_bytes[o + 1] = 128
			fine_bytes[o + 2] = 128
			fine_bytes[o + 3] = 255
	var coarse_bytes := PackedByteArray()
	coarse_bytes.resize(coarse_sz.x * coarse_sz.y * 4)
	coarse_bytes.fill(128)
	_write_synthetic_vnm(ns_dir, Vector2i(2048, 1024), fine_sz, coarse_sz, fine_bytes, coarse_bytes, "repeat", "repeat")

	var ns_load := _VnmMat.load_from_path(ns_dir, _VnmGen.SamplingPath.HARDWARE_BILINEAR)
	if not ns_load.get("ok", false):
		print("[O8 FAIL] Non-square load failed: ", ns_load.get("error", ""))
		all_ok = false
	else:
		var ns_pkg: _VnmPkg = ns_load["package"]
		var uvs: Array[Vector2] = [
			Vector2(0.00048828125, 0.001953125), # lattice texel center
			Vector2(0.00048828125, 0.005859375), # row 1 lattice
			Vector2(0.25, 0.375),
			Vector2(0.613, 0.817),
		]
		var ex_vals := await _run_verify_pass(ns_pkg, _VnmGen.SamplingPath.EXACT_BILINEAR, uvs, true, true)
		var hw_vals := await _run_verify_pass(ns_pkg, _VnmGen.SamplingPath.HARDWARE_BILINEAR, uvs, true, true)
		var max_ex := 0.0
		var max_hw := 0.0
		for i in range(uvs.size()):
			var cpu := _decode_cpu_identity_r(fine_bytes, fine_sz.x, fine_sz.y, uvs[i].x, uvs[i].y, true, true) * 0.5 + 0.5
			max_ex = maxf(max_ex, absf(ex_vals[i] - cpu))
			max_hw = maxf(max_hw, absf(hw_vals[i] - cpu))
		print("[O8 PASS/CHECK] Non-square 2048x1024 (fine 1024x256): exact_err=%.6f hw_err=%.6f" % [max_ex, max_hw])
		if max_ex > 1.0e-4 or max_hw > 2.0e-2:
			print("[O8 FAIL] Non-square verification error exceeded gate")
			all_ok = false

		# Y-axis LOD test: ratio_f = max(2048/1024, 1024/256) = 4.0 -> log2 = 2.0.
		# At active_mip = 2.0 (norm=2/6): lod_f = 0.0 (stripes preserved, high Y contrast).
		# At active_mip = 3.0 (norm=3/6): lod_f = 1.0 (stripes averaged cleanly, low Y contrast).
		var row_uvs: Array[Vector2] = [
			Vector2(0.25, 0.5 / 256.0),
			Vector2(0.25, 1.5 / 256.0),
		]
		var strip_m2 := await _render_spatial_strip(ns_pkg, 2.0 / 6.0, row_uvs, true, true)
		var strip_m3 := await _render_spatial_strip(ns_pkg, 3.0 / 6.0, row_uvs, true, true)
		var diff_m2 := absf(strip_m2[0] - strip_m2[1])
		var diff_m3 := absf(strip_m3[0] - strip_m3[1])
		print("[O8 Y-LOD] active_mip=2.0 stripe_diff=%.4f | active_mip=3.0 stripe_diff=%.4f" % [diff_m2, diff_m3])
		if diff_m2 < 0.7 or diff_m3 > 0.15:
			print("[O8 FAIL] Y-axis LOD transition did not happen at expected mip 2->3")
			all_ok = false

	# 2. Clamp margin high-LOD test (64x64, fine=32x32, wrapU/V=clamp)
	var cl_dir := "/tmp/vnm_o8_clamp"
	var c_fine_sz := Vector2i(32, 32)
	var c_coarse_sz := Vector2i(16, 16)
	var c_fine := PackedByteArray()
	c_fine.resize(32 * 32 * 4)
	for y in range(32):
		for x in range(32):
			var o := (y * 32 + x) * 4
			var r_val := 0
			if x == 0:
				r_val = 255
			elif x == 31:
				r_val = 0
			else:
				r_val = 128
			c_fine[o] = r_val
			c_fine[o + 1] = 128
			c_fine[o + 2] = 128
			c_fine[o + 3] = 255
	var c_coarse := PackedByteArray()
	c_coarse.resize(16 * 16 * 4)
	c_coarse.fill(128)
	_write_synthetic_vnm(cl_dir, Vector2i(64, 64), c_fine_sz, c_coarse_sz, c_fine, c_coarse, "clamp", "clamp")

	var cl_load := _VnmMat.load_from_path(cl_dir, _VnmGen.SamplingPath.HARDWARE_BILINEAR)
	if not cl_load.get("ok", false):
		print("[O8 FAIL] Clamp test asset load failed")
		all_ok = false
	else:
		var cl_pkg: _VnmPkg = cl_load["package"]
		# ratio_f = 64/32 = 2 -> log2 = 1. At active_mip=3.0 (norm=0.5), lod_f = 2.0.
		# At lod_f=2.0 on 32x32, mu = 0.5 * 4 / 32 = 0.0625.
		# So UV=(0.0, 0.5) must equal UV=(0.0625, 0.5) cleanly, and UV=(1.0, 0.5) must equal UV=(1.0 - 0.0625, 0.5).
		var clamp_uvs: Array[Vector2] = [
			Vector2(0.0, 0.5),
			Vector2(0.0625, 0.5),
			Vector2(1.0, 0.5),
			Vector2(1.0 - 0.0625, 0.5),
		]
		var cl_m3 := await _render_spatial_strip(cl_pkg, 3.0 / 6.0, clamp_uvs, false, false)
		var cl_m10 := await _render_spatial_strip(cl_pkg, 1.0, clamp_uvs, false, false) # extreme mip clamp safety check (mu -> 0.5)
		var left_eq := absf(cl_m3[0] - cl_m3[1])
		var right_eq := absf(cl_m3[2] - cl_m3[3])
		var extreme_ok := not (is_nan(cl_m10[0]) or is_nan(cl_m10[2])) and absf(cl_m10[0] - cl_m10[2]) < 0.02
		print("[O8 CLAMP-LOD] left_edge_diff=%.5f right_edge_diff=%.5f extreme_lod_ok=%s (v_l=%.3f v_r=%.3f)" % [
			left_eq, right_eq, str(extreme_ok), cl_m3[0], cl_m3[2]
		])
		if left_eq > 0.01 or right_eq > 0.01 or not extreme_ok:
			print("[O8 FAIL] Clamp high-LOD margin alignment check failed")
			all_ok = false

	print("[O8 SUMMARY] all_passed=%s" % str(all_ok))
	get_tree().quit(0 if all_ok else 1)
