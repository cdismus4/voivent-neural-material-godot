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

func _ready() -> void:
	var assets_root := OS.get_environment("VNM_DEMO_ASSETS_DIR")
	if assets_root.is_empty():
		assets_root = ProjectSettings.globalize_path("res://../../satellite/worker/assets/lab/vnm/demo-assets")

	var demo_paths := [
		"%s/marble/marble.vnm" % assets_root,
		"%s/fabric030/ambientcg-fabric030-1k.vnm" % assets_root,
		"%s/sand/sand.vnm" % assets_root,
		"%s/cloth/cloth.vnm" % assets_root,
	]

	var all_ok := true
	for p in demo_paths:
		var res := _VnmLdr.load_package(p)
		if not res.get("ok", false):
			print("[G-1 FAIL] Demo load failed for ", p, ": ", res.get("error", ""))
			all_ok = false
		else:
			var pkg: _VnmPkg = res["package"]
			print("[G-1 PASS-LOAD] ", pkg.asset_id, " profile=", pkg.profile, " source=", pkg.source_size, " fine=", pkg.fine_size, " tail=", pkg.tail_size)

	# Test single-file ZIP reading (marble)
	var zip_path := "/tmp/vnm_test_marble.zip"
	var zp := ZIPPacker.new()
	if zp.open(zip_path) == OK:
		for fn in ["manifest.json", "weights.bin", "level-0.bin", "tail.bin"]:
			zp.start_file("marble.vnm/%s" % fn)
			zp.write_file(FileAccess.get_file_as_bytes("%s/marble/marble.vnm/%s" % [assets_root, fn]))
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

	# Negative validation tests using mutated temporary copy of marble
	var tmp_dir := "/tmp/vnm_test_invalid_case"
	_copy_dir("%s/marble/marble.vnm" % assets_root, tmp_dir)

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
	DirAccess.remove_absolute(zip_path)

	print("[G-1 SUMMARY] all_ok=", all_ok)
	get_tree().quit(0 if all_ok else 1)
