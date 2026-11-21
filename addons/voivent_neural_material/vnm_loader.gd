class_name VnmLoader
extends RefCounted

const _VnmPkg = preload("res://addons/voivent_neural_material/vnm_package.gd")

## VNM1 Runtime Loader (v1): reads 4-file .vnm directories or single-file .zip bundles,
## enforces SPEC §§2-5 structural, checksum, header, and reserved-byte validation,
## and produces runtime GPU ImageTextures without passing through editor image import.

const VNM_MAGIC := 0x314D4E56 # "VNM1" little-endian
const VNM_VERSION := 1
const CHUNK_WEIGHTS := 1
const CHUNK_LATENTS := 2
const CHUNK_TAIL := 3

const PROFILE_SPECS := {
	"small": {"input_dim": 12, "h1": 16, "h2": 16, "output_dim": 8, "latent_ch": 4, "total_weights": 616},
	"standard": {"input_dim": 12, "h1": 24, "h2": 24, "output_dim": 8, "latent_ch": 4, "total_weights": 1112},
	"quality": {"input_dim": 12, "h1": 32, "h2": 32, "output_dim": 8, "latent_ch": 4, "total_weights": 1736},
	"standard8": {"input_dim": 20, "h1": 24, "h2": 24, "output_dim": 8, "latent_ch": 8, "total_weights": 1304},
	"quality8": {"input_dim": 20, "h1": 32, "h2": 32, "output_dim": 8, "latent_ch": 8, "total_weights": 1992},
}

static func _err(msg: String) -> Dictionary:
	return {"ok": false, "error": msg, "package": null}

static func _sha256_hex(data: PackedByteArray) -> String:
	var hc := HashingContext.new()
	hc.start(HashingContext.HASH_SHA256)
	hc.update(data)
	return hc.finish().hex_encode().to_lower()

static func _is_exact_int(v: Variant) -> bool:
	if v is int:
		return true
	if v is float:
		var f := v as float
		return is_finite(f) and f == floor(f) and absf(f) <= 9007199254740991.0
	return false

static func _is_pos_int(v: Variant) -> bool:
	return _is_exact_int(v) and int(v) > 0

static func _is_nonneg_int(v: Variant) -> bool:
	return _is_exact_int(v) and int(v) >= 0

static func _validate_dim_pair(v: Variant, label: String, out_err: Array[String]) -> Vector2i:
	if not (v is Array) or v.size() != 2 or not _is_pos_int(v[0]) or not _is_pos_int(v[1]):
		out_err.append("Invalid %s: expected [w, h] positive integers" % label)
		return Vector2i.ZERO
	return Vector2i(int(v[0]), int(v[1]))

static func _validate_chunk_ref(ref: Variant, label: String, out_err: Array[String]) -> Dictionary:
	if not (ref is Dictionary):
		out_err.append("Missing chunk reference '%s'" % label)
		return {}
	var url_v: Variant = ref.get("url", "")
	var sha_v: Variant = ref.get("sha256", "")
	var len_v: Variant = ref.get("byteLength", -1)
	if not (url_v is String) or String(url_v).strip_edges().is_empty():
		out_err.append("Invalid url in chunk '%s'" % label)
		return {}
	if not (sha_v is String) or String(sha_v).length() != 64:
		out_err.append("Invalid sha256 in chunk '%s'" % label)
		return {}
	var sha_lower := String(sha_v).to_lower()
	for i in range(64):
		var c := sha_lower.unicode_at(i)
		var is_hex := (c >= 48 and c <= 57) or (c >= 97 and c <= 102)
		if not is_hex:
			out_err.append("Non-hex sha256 in chunk '%s'" % label)
			return {}
	if not _is_pos_int(len_v):
		out_err.append("Invalid byteLength in chunk '%s'" % label)
		return {}
	return {"url": String(url_v), "sha256": sha_lower, "byteLength": int(len_v)}

static func _validate_common_header(bytes: PackedByteArray, expected_kind: int, label: String) -> Dictionary:
	if bytes.size() < 16:
		return {"ok": false, "error": "%s: chunk shorter than 16-byte header" % label}
	var magic := bytes.decode_u32(0)
	if magic != VNM_MAGIC:
		return {"ok": false, "error": "%s: invalid VNM1 magic 0x%08x" % [label, magic]}
	var ver := bytes.decode_u16(4)
	if ver != VNM_VERSION:
		return {"ok": false, "error": "%s: unsupported header version %d" % [label, ver]}
	var kind := bytes.decode_u16(6)
	if kind != expected_kind:
		return {"ok": false, "error": "%s: expected chunk kind %d, got %d" % [label, expected_kind, kind]}
	var payload_len := bytes.decode_u32(8)
	var reserved := bytes.decode_u32(12)
	if reserved != 0:
		return {"ok": false, "error": "%s: non-zero header reserved field (%d)" % [label, reserved]}
	if bytes.size() != 16 + payload_len:
		return {"ok": false, "error": "%s: byte size %d != 16 + payload_len (%d)" % [label, bytes.size(), 16 + payload_len]}
	return {"ok": true, "payload_len": payload_len}

static func _read_source_files(path: String) -> Dictionary:
	if DirAccess.dir_exists_absolute(path):
		var dir := DirAccess.open(path)
		if dir == null:
			return _err("Unable to open VNM1 directory: %s" % path)
		var base := path.rstrip("/")
		var read_fn := func(rel: String) -> Variant:
			var full := "%s/%s" % [base, rel.lstrip("./")]
			if not FileAccess.file_exists(full):
				return null
			return FileAccess.get_file_as_bytes(full)
		return {"ok": true, "reader": read_fn}

	if FileAccess.file_exists(path):
		var zr := ZIPReader.new()
		var open_err := zr.open(path)
		if open_err != OK:
			return _err("Unable to open VNM1 zip archive '%s' (err %d)" % [path, open_err])
		var files := zr.get_files()
		var prefix := ""
		var found_manifest := false
		for f in files:
			if f == "manifest.json":
				prefix = ""
				found_manifest = true
				break
			if f.ends_with("/manifest.json"):
				prefix = f.substr(0, f.length() - "manifest.json".length())
				found_manifest = true
				break
		if not found_manifest:
			zr.close()
			return _err("ZIP archive missing manifest.json: %s" % path)

		var cache := {}
		for f in files:
			if f.begins_with(prefix) and not f.ends_with("/"):
				var rel := f.substr(prefix.length())
				cache[rel] = zr.read_file(f)
		zr.close()

		var read_zip := func(rel: String) -> Variant:
			var clean := rel.lstrip("./")
			return cache.get(clean, null)
		return {"ok": true, "reader": read_zip}

	return _err("VNM1 path not found (neither directory nor zip): %s" % path)

static func load_package(path: String) -> Dictionary:
	var src := _read_source_files(path)
	if not src.get("ok", false):
		return src
	var read_file: Callable = src["reader"]

	var manifest_raw: Variant = read_file.call("manifest.json")
	if manifest_raw == null or not (manifest_raw is PackedByteArray):
		return _err("Missing manifest.json at '%s'" % path)

	var json_text := (manifest_raw as PackedByteArray).get_string_from_utf8()
	var parsed: Variant = JSON.parse_string(json_text)
	if not (parsed is Dictionary):
		return _err("Invalid JSON in manifest.json")
	var m: Dictionary = parsed

	if str(m.get("format", "")) != "VNM1":
		return _err("Invalid manifest format: expected 'VNM1', got '%s'" % str(m.get("format", "")))
	if not _is_pos_int(m.get("version", 0)) or int(m.get("version", 0)) != 1:
		return _err("Unsupported manifest version: %s" % str(m.get("version", "")))

	var asset_id := str(m.get("assetId", "")).strip_edges()
	if asset_id.is_empty():
		return _err("Manifest missing non-empty assetId")

	var errs: Array[String] = []
	var source_size := _validate_dim_pair(m.get("sourceSize", null), "sourceSize", errs)
	if not errs.is_empty():
		return _err(errs[0])

	var profile := str(m.get("profile", ""))
	if not PROFILE_SPECS.has(profile):
		return _err("Unsupported VNM1 profile: '%s'" % profile)
	var spec: Dictionary = PROFILE_SPECS[profile]

	if str(m.get("quantization", "")) != "u8":
		return _err("Unsupported quantization: '%s'" % str(m.get("quantization", "")))
	if str(m.get("weightStoragePrecision", "")) != "f32":
		return _err("Unsupported weightStoragePrecision: '%s'" % str(m.get("weightStoragePrecision", "")))
	if str(m.get("computePrecision", "")) != "f32":
		return _err("Unsupported computePrecision: '%s'" % str(m.get("computePrecision", "")))
	if str(m.get("channels", "")) != "base3-normal2-rough-metal-ao":
		return _err("Unsupported channels: '%s'" % str(m.get("channels", "")))
	if str(m.get("baseColorSpace", "")) != "linear-srgb":
		return _err("Unsupported baseColorSpace: '%s'" % str(m.get("baseColorSpace", "")))
	if str(m.get("normalConvention", "")) != "tangent-positive-y-positive-z":
		return _err("Unsupported normalConvention: '%s'" % str(m.get("normalConvention", "")))

	var wrap_u := str(m.get("wrapU", ""))
	var wrap_v := str(m.get("wrapV", ""))
	if wrap_u != "repeat" and wrap_u != "clamp":
		return _err("Invalid wrapU: '%s'" % wrap_u)
	if wrap_v != "repeat" and wrap_v != "clamp":
		return _err("Invalid wrapV: '%s'" % wrap_v)

	var tail_first_mip_v: Variant = m.get("tailFirstMip", -1)
	if not _is_nonneg_int(tail_first_mip_v):
		return _err("Invalid tailFirstMip: %s" % str(tail_first_mip_v))
	var tail_first_mip := int(tail_first_mip_v)

	var has_explicit_mip_max := false
	var mip_max := float(maxi(1, tail_first_mip - 1))
	if m.has("mipMax"):
		var mm_v: Variant = m["mipMax"]
		if not (mm_v is int or mm_v is float) or not is_finite(float(mm_v)) or float(mm_v) <= 0.0:
			return _err("Invalid mipMax: %s" % str(mm_v))
		mip_max = float(mm_v)
		has_explicit_mip_max = true

	var w_ref := _validate_chunk_ref(m.get("weights", null), "weights", errs)
	var t_ref := _validate_chunk_ref(m.get("tail", null), "tail", errs)
	if not errs.is_empty():
		return _err(errs[0])

	var levels_v: Variant = m.get("levels", null)
	if not (levels_v is Array) or (levels_v as Array).is_empty():
		return _err("Manifest levels must be a non-empty array")
	var levels_arr := levels_v as Array
	var prev_mip := -1
	var level0_fine := Vector2i.ZERO
	var level0_coarse := Vector2i.ZERO
	var level0_ref := {}
	for i in range(levels_arr.size()):
		var lvl_v: Variant = levels_arr[i]
		if not (lvl_v is Dictionary):
			return _err("Invalid level entry at %d" % i)
		var lvl := lvl_v as Dictionary
		var sm_v: Variant = lvl.get("sourceMip", -1)
		if not _is_nonneg_int(sm_v):
			return _err("Invalid sourceMip at level %d" % i)
		var sm := int(sm_v)
		if i == 0 and sm != 0:
			return _err("levels[0].sourceMip must equal 0, got %d" % sm)
		if sm <= prev_mip:
			return _err("levels must be sorted in ascending sourceMip order")
		prev_mip = sm
		var _ls := _validate_dim_pair(lvl.get("sourceSize", null), "levels[%d].sourceSize" % i, errs)
		var fs := _validate_dim_pair(lvl.get("fineSize", null), "levels[%d].fineSize" % i, errs)
		var cs := _validate_dim_pair(lvl.get("coarseSize", null), "levels[%d].coarseSize" % i, errs)
		var c_ref := _validate_chunk_ref(lvl.get("chunk", null), "levels[%d].chunk" % i, errs)
		if not errs.is_empty():
			return _err(errs[0])
		if fs.x > 65535 or fs.y > 65535 or cs.x > 65535 or cs.y > 65535:
			return _err("Latent dimensions exceed uint16 limit")
		if fs.x < cs.x or fs.y < cs.y:
			return _err("fineSize must be >= coarseSize per axis")
		if i == 0:
			level0_fine = fs
			level0_coarse = cs
			level0_ref = c_ref

	# Fetch and validate weights.bin
	var w_raw: Variant = read_file.call(w_ref["url"])
	if w_raw == null or not (w_raw is PackedByteArray):
		return _err("Missing weights chunk '%s'" % w_ref["url"])
	var w_bytes := w_raw as PackedByteArray
	if w_bytes.size() != int(w_ref["byteLength"]):
		return _err("weights byteLength mismatch: expected %d, got %d" % [int(w_ref["byteLength"]), w_bytes.size()])
	if _sha256_hex(w_bytes) != String(w_ref["sha256"]):
		return _err("weights sha256 mismatch")
	var wh := _validate_common_header(w_bytes, CHUNK_WEIGHTS, "weights")
	if not wh.get("ok", false):
		return _err(str(wh.get("error", "")))
	var expected_weights_payload := int(spec["total_weights"]) * 4
	if int(wh["payload_len"]) != expected_weights_payload:
		return _err("weights payload length mismatch for profile '%s': expected %d, got %d" % [profile, expected_weights_payload, int(wh["payload_len"])])

	# Verify finite weights & pad into 32 x ceil(vec4s / 32) RGBA32F texture
	var w_payload := w_bytes.slice(16)
	var total_weights := int(spec["total_weights"])
	var f32_weights := w_payload.to_float32_array()
	for wi in range(total_weights):
		if not is_finite(f32_weights[wi]):
			return _err("Non-finite float in weights chunk at index %d" % wi)

	var vec4_count := (total_weights + 3) / 4
	var w_tex_w := 32
	var w_tex_h := maxi(1, (vec4_count + w_tex_w - 1) / w_tex_w)
	var padded_f32 := PackedFloat32Array()
	padded_f32.resize(w_tex_w * w_tex_h * 4)
	padded_f32.fill(0.0)
	for wi in range(total_weights):
		padded_f32[wi] = f32_weights[wi]
	var weights_vec4 := PackedVector4Array()
	weights_vec4.resize(vec4_count)
	for vi in range(vec4_count):
		var bi := vi * 4
		weights_vec4[vi] = Vector4(padded_f32[bi], padded_f32[bi + 1], padded_f32[bi + 2], padded_f32[bi + 3])
	var weights_img := Image.create_from_data(w_tex_w, w_tex_h, false, Image.FORMAT_RGBAF, padded_f32.to_byte_array())
	var weights_tex := ImageTexture.create_from_image(weights_img)

	# Fetch and validate level-0.bin
	var l_raw: Variant = read_file.call(level0_ref["url"])
	if l_raw == null or not (l_raw is PackedByteArray):
		return _err("Missing latents chunk '%s'" % level0_ref["url"])
	var l_bytes := l_raw as PackedByteArray
	if l_bytes.size() != int(level0_ref["byteLength"]):
		return _err("latents byteLength mismatch: expected %d, got %d" % [int(level0_ref["byteLength"]), l_bytes.size()])
	if _sha256_hex(l_bytes) != String(level0_ref["sha256"]):
		return _err("latents sha256 mismatch")
	var lh := _validate_common_header(l_bytes, CHUNK_LATENTS, "level-0")
	if not lh.get("ok", false):
		return _err(str(lh.get("error", "")))

	var l_payload := l_bytes.slice(16)
	if l_payload.size() < 16:
		return _err("level-0 chunk missing 16-byte subheader")
	var sub_fw := l_payload.decode_u16(0)
	var sub_fh := l_payload.decode_u16(2)
	var sub_cw := l_payload.decode_u16(4)
	var sub_ch := l_payload.decode_u16(6)
	var sub_f_flag := l_payload.decode_u8(8)
	var sub_c_flag := l_payload.decode_u8(9)
	for ri in range(10, 16):
		if l_payload.decode_u8(ri) != 0:
			return _err("level-0 subheader reserved byte %d is non-zero (SPEC §5.2 violation)" % ri)
	if sub_fw != level0_fine.x or sub_fh != level0_fine.y or sub_cw != level0_coarse.x or sub_ch != level0_coarse.y:
		return _err("level-0 subheader dimensions mismatch manifest")
	if sub_f_flag != 1 or sub_c_flag != 1:
		return _err("level-0 quantization flags must equal 1")

	var latent_ch := int(spec["latent_ch"])
	var fine_bytes_len := sub_fw * sub_fh * latent_ch
	var coarse_bytes_len := sub_cw * sub_ch * latent_ch
	if l_payload.size() != 16 + fine_bytes_len + coarse_bytes_len:
		return _err("level-0 payload size mismatch: expected %d, got %d" % [16 + fine_bytes_len + coarse_bytes_len, l_payload.size()])

	var fine_data := l_payload.slice(16, 16 + fine_bytes_len)
	var coarse_data := l_payload.slice(16 + fine_bytes_len, 16 + fine_bytes_len + coarse_bytes_len)

	var fine_textures := _build_latent_textures(fine_data, sub_fw, sub_fh, latent_ch)
	var coarse_textures := _build_latent_textures(coarse_data, sub_cw, sub_ch, latent_ch)

	# Fetch and validate tail.bin
	var t_raw: Variant = read_file.call(t_ref["url"])
	if t_raw == null or not (t_raw is PackedByteArray):
		return _err("Missing tail chunk '%s'" % t_ref["url"])
	var t_bytes := t_raw as PackedByteArray
	if t_bytes.size() != int(t_ref["byteLength"]):
		return _err("tail byteLength mismatch: expected %d, got %d" % [int(t_ref["byteLength"]), t_bytes.size()])
	if _sha256_hex(t_bytes) != String(t_ref["sha256"]):
		return _err("tail sha256 mismatch")
	var th := _validate_common_header(t_bytes, CHUNK_TAIL, "tail")
	if not th.get("ok", false):
		return _err(str(th.get("error", "")))

	var t_payload := t_bytes.slice(16)
	if t_payload.size() < 16:
		return _err("tail chunk missing 16-byte subheader")
	var tail_w := t_payload.decode_u16(0)
	var tail_h := t_payload.decode_u16(2)
	var tail_sub_mip := t_payload.decode_u8(4)
	var tail_ch := t_payload.decode_u8(5)
	var tail_fmt := t_payload.decode_u8(6)
	for ri in range(7, 16):
		if t_payload.decode_u8(ri) != 0:
			return _err("tail subheader reserved byte %d is non-zero" % ri)
	if tail_ch != 8 or tail_fmt != 1:
		return _err("tail must have 8 channels and format=1 (u8 unorm)")
	if tail_sub_mip != tail_first_mip:
		return _err("tail subheader tailFirstMip mismatch: expected %d, got %d" % [tail_first_mip, tail_sub_mip])
	if tail_w <= 0 or tail_h <= 0:
		return _err("Invalid tail dimensions")
	if t_payload.size() != 16 + tail_w * tail_h * 8:
		return _err("tail payload size mismatch")

	var tail_pixels := t_payload.slice(16)
	var tail_textures := _build_latent_textures(tail_pixels, tail_w, tail_h, 8)

	var pkg := _VnmPkg.new()
	pkg.asset_id = asset_id
	pkg.profile = profile
	pkg.source_size = source_size
	pkg.fine_size = level0_fine
	pkg.coarse_size = level0_coarse
	pkg.tail_size = Vector2i(tail_w, tail_h)
	pkg.tail_first_mip = tail_first_mip
	pkg.mip_max = mip_max
	pkg.has_explicit_mip_max = has_explicit_mip_max
	pkg.wrap_u = wrap_u
	pkg.wrap_v = wrap_v
	pkg.input_dim = int(spec["input_dim"])
	pkg.hidden1 = int(spec["h1"])
	pkg.hidden2 = int(spec["h2"])
	pkg.output_dim = int(spec["output_dim"])
	pkg.latent_channels = latent_ch
	pkg.total_weights = total_weights
	pkg.weights_texture = weights_tex
	pkg.weights_tex_size = Vector2i(w_tex_w, w_tex_h)
	pkg.weights_vec4 = weights_vec4
	pkg.fine_textures = fine_textures
	pkg.coarse_textures = coarse_textures
	pkg.tail_textures = tail_textures
	pkg.weights_bytes = w_payload
	pkg.fine_bytes = fine_data
	pkg.coarse_bytes = coarse_data
	pkg.tail_bytes = tail_pixels
	return {"ok": true, "error": "", "package": pkg}

static func _build_latent_textures(interleaved: PackedByteArray, width: int, height: int, channels: int) -> Array[ImageTexture]:
	var result: Array[ImageTexture] = []
	var texel_count := width * height
	if channels == 4:
		var img := Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, interleaved)
		img.generate_mipmaps()
		result.append(ImageTexture.create_from_image(img))
		return result

	# 8ch: split cleanly into 2 RGBA8 textures (ch 0..3, ch 4..7) with linear mip chain for LOD prefiltering
	var part0 := PackedByteArray()
	var part1 := PackedByteArray()
	part0.resize(texel_count * 4)
	part1.resize(texel_count * 4)
	for i in range(texel_count):
		var s := i * 8
		var d := i * 4
		part0[d] = interleaved[s]
		part0[d + 1] = interleaved[s + 1]
		part0[d + 2] = interleaved[s + 2]
		part0[d + 3] = interleaved[s + 3]
		part1[d] = interleaved[s + 4]
		part1[d + 1] = interleaved[s + 5]
		part1[d + 2] = interleaved[s + 6]
		part1[d + 3] = interleaved[s + 7]

	var img0 := Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, part0)
	img0.generate_mipmaps()
	var img1 := Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, part1)
	img1.generate_mipmaps()
	result.append(ImageTexture.create_from_image(img0))
	result.append(ImageTexture.create_from_image(img1))
	return result
