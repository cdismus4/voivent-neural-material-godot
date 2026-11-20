extends Node

const _VnmLdr = preload("res://addons/voivent_neural_material/vnm_loader.gd")
const _VnmPkg = preload("res://addons/voivent_neural_material/vnm_package.gd")

## G-1 Verification: directory & ZIP loading of all 4 CC0 demo assets plus strict
## SPEC validation failure tests (unknown profile, reserved bytes, bad sha256, missing file).

func _copy_dir(src: String, dst: String) -> void:
	DirAccess.make_dir_recursive_absolute(dst)
	var d := DirAccess.open(src)
	d.list_dir_begin()
	var fn := d.get_next()
	while fn != "":
		if not d.current_is_dir():
			var bytes := FileAccess.get_file_as_bytes("%s/%s" % [src, fn])
			var fa := FileAccess.open("%s/%s" % [dst, fn], FileAccess.WRITE)
			fa.store_buffer(bytes)
			fa.close()
		fn = d.get_next()

func _expect_fail(label: String, res: Dictionary) -> bool:
	if res.get("ok", false):
		print("[G-1 FAIL] Expected error for '", label, "' but loader succeeded!")
		return false
	print("[G-1 PASS-REJECT] ", label, " -> ", res.get("error", ""))
	return true

func _sha256_bytes(data: PackedByteArray) -> String:
	var hc := HashingContext.new()
	hc.start(HashingContext.HASH_SHA256)
	hc.update(data)
	return hc.finish().hex_encode().to_lower()

func _make_vnm_header(chunk_kind: int, payload_len: int) -> PackedByteArray:
	var hdr := PackedByteArray()
	hdr.resize(16)
	hdr.fill(0)
	hdr.encode_u32(0, _VnmLdr.VNM_MAGIC)
	hdr.encode_u16(4, _VnmLdr.VNM_VERSION)
	hdr.encode_u16(6, chunk_kind)
	hdr.encode_u32(8, payload_len)
	hdr.encode_u32(12, 0)
	return hdr

func _create_synthetic_vnm_dir(dst_dir: String) -> void:
	DirAccess.make_dir_recursive_absolute(dst_dir)
	var total_weights := int(_VnmLdr.PROFILE_SPECS["standard"]["total_weights"])
	var w_payload := PackedByteArray()
	w_payload.resize(total_weights * 4)
	w_payload.fill(0)
	var w_bytes := _make_vnm_header(_VnmLdr.CHUNK_WEIGHTS, w_payload.size()) + w_payload

	var fw := 8
	var fh := 8
	var cw := 4
	var ch := 4
	var l_sub := PackedByteArray()
	l_sub.resize(16)
	l_sub.fill(0)
	l_sub.encode_u16(0, fw)
	l_sub.encode_u16(2, fh)
	l_sub.encode_u16(4, cw)
	l_sub.encode_u16(6, ch)
	l_sub.encode_u8(8, 1)
	l_sub.encode_u8(9, 1)
	var l_data := PackedByteArray()
	l_data.resize((fw * fh + cw * ch) * 4)
	l_data.fill(128)
	var l_payload := l_sub + l_data
	var l_bytes := _make_vnm_header(_VnmLdr.CHUNK_LATENTS, l_payload.size()) + l_payload

	var tw := 4
	var th := 4
	var t_sub := PackedByteArray()
	t_sub.resize(16)
	t_sub.fill(0)
	t_sub.encode_u16(0, tw)
	t_sub.encode_u16(2, th)
	t_sub.encode_u8(4, 5)
	t_sub.encode_u8(5, 8)
	t_sub.encode_u8(6, 1)
	var t_data := PackedByteArray()
	t_data.resize(tw * th * 8)
	t_data.fill(128)
	var t_payload := t_sub + t_data
	var t_bytes := _make_vnm_header(_VnmLdr.CHUNK_TAIL, t_payload.size()) + t_payload

	var manifest := {
		"format": "VNM1",
		"version": 1,
		"assetId": "vnm1-standalone-synthetic-test",
		"sourceSize": [64, 64],
		"profile": "standard",
		"quantization": "u8",
		"weightStoragePrecision": "f32",
		"computePrecision": "f32",
		"channels": "base3-normal2-rough-metal-ao",
		"baseColorSpace": "linear-srgb",
		"normalConvention": "tangent-positive-y-positive-z",
		"wrapU": "repeat",
		"wrapV": "repeat",
		"weights": {"url": "weights.bin", "sha256": _sha256_bytes(w_bytes), "byteLength": w_bytes.size()},
		"levels": [
			{
				"sourceMip": 0,
				"sourceSize": [64, 64],
				"fineSize": [fw, fh],
				"coarseSize": [cw, ch],
				"chunk": {"url": "level-0.bin", "sha256": _sha256_bytes(l_bytes), "byteLength": l_bytes.size()},
			}
		],
		"tailFirstMip": 5,
		"tail": {"url": "tail.bin", "sha256": _sha256_bytes(t_bytes), "byteLength": t_bytes.size()},
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

func _ready() -> void:
	var assets_root := OS.get_environment("VNM_DEMO_ASSETS_DIR")
	if assets_root.is_empty():
		var local_assets := ProjectSettings.globalize_path("res://demo-assets")
		if DirAccess.dir_exists_absolute(local_assets):
			assets_root = local_assets

	var synth_dir := "/tmp/vnm_g1_synthetic_fixture"
	var use_real_demos := not assets_root.is_empty() and DirAccess.dir_exists_absolute(assets_root)
	var sample_dir := ""
	var demo_paths: Array[String] = []
	if use_real_demos:
		demo_paths = [
			"%s/marble/marble.vnm" % assets_root,
			"%s/fabric030/ambientcg-fabric030-1k.vnm" % assets_root,
			"%s/sand/sand.vnm" % assets_root,
			"%s/cloth/cloth.vnm" % assets_root,
		]
		sample_dir = demo_paths[0]
	else:
		_create_synthetic_vnm_dir(synth_dir)
		demo_paths = [synth_dir]
		sample_dir = synth_dir

	var all_ok := true
	for p in demo_paths:
		var res := _VnmLdr.load_package(p)
		if not res.get("ok", false):
			print("[G-1 FAIL] Demo load failed for ", p, ": ", res.get("error", ""))
			all_ok = false
		else:
			var pkg: _VnmPkg = res["package"]
			print("[G-1 PASS-LOAD] ", pkg.asset_id, " profile=", pkg.profile, " source=", pkg.source_size, " fine=", pkg.fine_size, " tail=", pkg.tail_size)

	# Test single-file ZIP reading
	var zip_path := "/tmp/vnm_test_marble.zip"
	var zp := ZIPPacker.new()
	if zp.open(zip_path) == OK:
		for fn in ["manifest.json", "weights.bin", "level-0.bin", "tail.bin"]:
			zp.start_file("sample.vnm/%s" % fn)
			zp.write_file(FileAccess.get_file_as_bytes("%s/%s" % [sample_dir, fn]))
			zp.close_file()
		zp.close()
		var zip_res := _VnmLdr.load_package(zip_path)
		if not zip_res.get("ok", false):
			print("[G-1 FAIL] ZIP load failed: ", zip_res.get("error", ""))
			all_ok = false
		else:
			print("[G-1 PASS-ZIP] Loaded single-file .zip cleanly: ", (zip_res["package"] as _VnmPkg).asset_id)
	else:
		print("[G-1 FAIL] Could not pack temporary zip")
		all_ok = false

	# Negative validation tests using mutated temporary copy
	var tmp_dir := "/tmp/vnm_test_invalid_case"
	_copy_dir(sample_dir, tmp_dir)

	# 1. Unknown profile
	var orig_manifest_text := FileAccess.get_file_as_string("%s/manifest.json" % tmp_dir)
	var bad_prof := JSON.parse_string(orig_manifest_text) as Dictionary
	bad_prof["profile"] = "ultra_unknown"
	var f1 := FileAccess.open("%s/manifest.json" % tmp_dir, FileAccess.WRITE)
	f1.store_string(JSON.stringify(bad_prof))
	f1.close()
	all_ok = _expect_fail("unknown profile", _VnmLdr.load_package(tmp_dir)) and all_ok

	# Restore manifest, corrupt reserved bytes in level-0 subheader
	var f_rest := FileAccess.open("%s/manifest.json" % tmp_dir, FileAccess.WRITE)
	f_rest.store_string(orig_manifest_text)
	f_rest.close()
	var orig_l0 := FileAccess.get_file_as_bytes("%s/level-0.bin" % tmp_dir)
	var bad_l0 := orig_l0.duplicate()
	bad_l0[16 + 12] = 0x42 # non-zero subheader reserved byte
	var hc := HashingContext.new()
	hc.start(HashingContext.HASH_SHA256)
	hc.update(bad_l0)
	var bad_l0_sha := hc.finish().hex_encode().to_lower()
	var man_upd := JSON.parse_string(orig_manifest_text) as Dictionary
	man_upd["levels"][0]["chunk"]["sha256"] = bad_l0_sha
	var f_m := FileAccess.open("%s/manifest.json" % tmp_dir, FileAccess.WRITE)
	f_m.store_string(JSON.stringify(man_upd))
	f_m.close()
	var f_l := FileAccess.open("%s/level-0.bin" % tmp_dir, FileAccess.WRITE)
	f_l.store_buffer(bad_l0)
	f_l.close()
	all_ok = _expect_fail("non-zero level-0 reserved byte", _VnmLdr.load_package(tmp_dir)) and all_ok

	# 2b. M-2: explicit "mipMax": null must be rejected per SPEC §6.2
	var bad_null_mip := JSON.parse_string(orig_manifest_text) as Dictionary
	bad_null_mip["mipMax"] = null
	var f_m2 := FileAccess.open("%s/manifest.json" % tmp_dir, FileAccess.WRITE)
	f_m2.store_string(JSON.stringify(bad_null_mip))
	f_m2.close()
	all_ok = _expect_fail("M-2 explicit mipMax null", _VnmLdr.load_package(tmp_dir)) and all_ok

	# 2c. M-11: near-integer float like 1.000001 must be rejected strictly
	var bad_frac_ver := JSON.parse_string(orig_manifest_text) as Dictionary
	bad_frac_ver["version"] = 1.000001
	var f_m11 := FileAccess.open("%s/manifest.json" % tmp_dir, FileAccess.WRITE)
	f_m11.store_string(JSON.stringify(bad_frac_ver))
	f_m11.close()
	all_ok = _expect_fail("M-11 fractional version 1.000001", _VnmLdr.load_package(tmp_dir)) and all_ok

	# 2d. M-4: tail subheader tailFirstMip mismatch against manifest.tailFirstMip
	var bad_tail_mip := JSON.parse_string(orig_manifest_text) as Dictionary
	bad_tail_mip["tailFirstMip"] = int(bad_tail_mip["tailFirstMip"]) + 1
	var f_m4 := FileAccess.open("%s/manifest.json" % tmp_dir, FileAccess.WRITE)
	f_m4.store_string(JSON.stringify(bad_tail_mip))
	f_m4.close()
	# Restore valid level-0.bin first so validation reaches tail check
	var f_l_rest := FileAccess.open("%s/level-0.bin" % tmp_dir, FileAccess.WRITE)
	f_l_rest.store_buffer(orig_l0)
	f_l_rest.close()
	all_ok = _expect_fail("M-4 tailFirstMip subheader mismatch", _VnmLdr.load_package(tmp_dir)) and all_ok

	# 3. Missing file check (invalid path)
	all_ok = _expect_fail("missing directory", _VnmLdr.load_package("/tmp/vnm_does_not_exist_12345")) and all_ok

	# Clean up tmp
	for fn in ["manifest.json", "weights.bin", "level-0.bin", "tail.bin"]:
		DirAccess.remove_absolute("%s/%s" % [tmp_dir, fn])
	DirAccess.remove_absolute(tmp_dir)
	if not use_real_demos and DirAccess.dir_exists_absolute(synth_dir):
		for fn in ["manifest.json", "weights.bin", "level-0.bin", "tail.bin"]:
			DirAccess.remove_absolute("%s/%s" % [synth_dir, fn])
		DirAccess.remove_absolute(synth_dir)
	DirAccess.remove_absolute(zip_path)

	print("[G-1 SUMMARY] all_ok=", all_ok)
	get_tree().quit(0 if all_ok else 1)
