extends Node

const _VnmMat = preload("res://addons/voivent_neural_material/vnm_material.gd")
const _VnmPkg = preload("res://addons/voivent_neural_material/vnm_package.gd")
const _VnmGen = preload("res://addons/voivent_neural_material/vnm_shader_generator.gd")

## P2-aligned Godot GPU/Frame Cost Benchmark (1280x720, 60 warmup + 300 measured frames,
## coverage 25% / 50% / 100%, StandardMaterial3D 3x1024px PBR baseline vs 4 real VNM1 assets).
## Requires VNM_DEMO_ASSETS_DIR=/path/to/vnm-demo-assets or assets placed at res://demo-assets.

const DEMO_ASSETS := [
	{"id": "marble", "subpath": "marble/marble.vnm"},
	{"id": "cloth", "subpath": "cloth/cloth.vnm"},
	{"id": "fabric030", "subpath": "fabric030/ambientcg-fabric030-1k.vnm"},
	{"id": "sand", "subpath": "sand/sand.vnm"},
]
const COVERAGES := [25, 50, 100]
const DEFAULT_WARMUP_FRAMES := 60
const DEFAULT_MEASURED_FRAMES := 300
const VP_W := 1280
const VP_H := 720

var _warmup_frames := DEFAULT_WARMUP_FRAMES
var _measured_frames := DEFAULT_MEASURED_FRAMES

static func _percentile_sorted(sorted: Array[float], p: float) -> float:
	if sorted.is_empty():
		return 0.0
	var idx := clampi(int(floor(float(sorted.size() - 1) * p)), 0, sorted.size() - 1)
	return sorted[idx]

func _make_baseline_material() -> Dictionary:
	var w := 1024
	var h := 1024
	var make_tex := func(seed_val: int, r0: int, g0: int, b0: int) -> ImageTexture:
		var buf := PackedByteArray()
		buf.resize(w * h * 4)
		for i in range(w * h):
			var j := ((i * 1103515245 + seed_val) >> 24) & 0x0f
			var o := i * 4
			buf[o] = mini(255, r0 + j)
			buf[o + 1] = mini(255, g0 + j)
			buf[o + 2] = mini(255, b0 + j)
			buf[o + 3] = 255
		var img := Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, buf)
		return ImageTexture.create_from_image(img)

	var base_tex: ImageTexture = make_tex.call(1, 140, 120, 100)
	var norm_tex: ImageTexture = make_tex.call(2, 128, 128, 255)
	var orm_tex: ImageTexture = make_tex.call(3, 255, 160, 20)

	var mat := StandardMaterial3D.new()
	mat.albedo_texture = base_tex
	mat.normal_enabled = true
	mat.normal_texture = norm_tex
	mat.ao_enabled = true
	mat.ao_texture = orm_tex
	mat.ao_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
	mat.roughness_texture = orm_tex
	mat.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GREEN
	mat.metallic_texture = orm_tex
	mat.metallic_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_BLUE
	return {"material": mat, "textures": [base_tex, norm_tex, orm_tex]}

func _measure_pass(
	sv: SubViewport,
	vp_rid: RID,
	quad: MeshInstance3D,
	mat: Material,
	coverage_pct: int,
) -> Dictionary:
	var s := sqrt(float(coverage_pct) / 100.0)
	quad.scale = Vector3(s, s, 1.0)
	quad.material_override = mat

	# First frame render for shader compilation timing
	var tc0 := Time.get_ticks_usec()
	await get_tree().process_frame
	var compile_ms := float(Time.get_ticks_usec() - tc0) / 1000.0

	for _w in range(_warmup_frames):
		await get_tree().process_frame

	var frame_times: Array[float] = []
	var gpu_times: Array[float] = []
	var cpu_times: Array[float] = []
	var prev_us := Time.get_ticks_usec()
	for _i in range(_measured_frames):
		await get_tree().process_frame
		var now_us := Time.get_ticks_usec()
		frame_times.append(float(now_us - prev_us) / 1000.0)
		prev_us = now_us
		gpu_times.append(RenderingServer.viewport_get_measured_render_time_gpu(vp_rid))
		cpu_times.append(RenderingServer.viewport_get_measured_render_time_cpu(vp_rid))

	frame_times.sort()
	gpu_times.sort()
	cpu_times.sort()
	var sv_img := sv.get_texture().get_image()
	var center_px := sv_img.get_pixel(VP_W / 2, VP_H / 2)
	return {
		"coverage_pct": coverage_pct,
		"compile_ms": compile_ms,
		"frame_ms_median": _percentile_sorted(frame_times, 0.5),
		"frame_ms_p95": _percentile_sorted(frame_times, 0.95),
		"gpu_ms_median": _percentile_sorted(gpu_times, 0.5),
		"gpu_ms_p95": _percentile_sorted(gpu_times, 0.95),
		"cpu_ms_median": _percentile_sorted(cpu_times, 0.5),
		"center_pixel_ok": not (is_nan(center_px.r) or is_nan(center_px.g) or is_nan(center_px.b)),
	}

func _ready() -> void:
	var w_env := OS.get_environment("VNM_BENCH_WARMUP")
	if not w_env.is_empty():
		_warmup_frames = maxi(1, int(w_env))
	var m_env := OS.get_environment("VNM_BENCH_FRAMES")
	if not m_env.is_empty():
		_measured_frames = maxi(5, int(m_env))

	var assets_root := OS.get_environment("VNM_DEMO_ASSETS_DIR")
	if assets_root.is_empty():
		var local_assets := ProjectSettings.globalize_path("res://demo-assets")
		if DirAccess.dir_exists_absolute(local_assets):
			assets_root = local_assets
	if assets_root.is_empty() or not DirAccess.dir_exists_absolute(assets_root):
		push_error("[P2-BENCH ERROR] Demo assets directory not found. Set VNM_DEMO_ASSETS_DIR=/path/to/vnm-demo-assets or place assets in res://demo-assets.")
		get_tree().quit(1)
		return

	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0

	var root_vp := get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(root_vp, true)

	var sv := SubViewport.new()
	sv.size = Vector2i(VP_W, VP_H)
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	sv.msaa_3d = Viewport.MSAA_DISABLED
	add_child(sv)
	var vp_rid := sv.get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(vp_rid, true)

	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 2.0
	cam.keep_aspect = Camera3D.KEEP_HEIGHT
	cam.position = Vector3(0.0, 0.0, 2.0)
	cam.near = 0.05
	cam.far = 10.0
	sv.add_child(cam)
	cam.make_current()

	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.05, 0.06, 0.08)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.3, 0.32, 0.36)
	env_node.environment = env
	sv.add_child(env_node)

	var light := DirectionalLight3D.new()
	light.position = Vector3(1.5, 2.0, 3.0)
	sv.add_child(light)
	light.look_at(Vector3.ZERO, Vector3.UP)

	var quad := MeshInstance3D.new()
	var qmesh := QuadMesh.new()
	qmesh.size = Vector2(2.0 * float(VP_W) / float(VP_H), 2.0)
	quad.mesh = qmesh
	sv.add_child(quad)

	var method := RenderingServer.get_current_rendering_method()
	var adapter := RenderingServer.get_video_adapter_name()
	print("[P2-BENCH] Starting 1280x720 benchmark on ", adapter, " method=", method, " warmup=", _warmup_frames, " measured=", _measured_frames)

	var base_pack := _make_baseline_material()
	var base_mat: StandardMaterial3D = base_pack["material"]
	var baseline_by_cov := {}
	for cov in COVERAGES:
		var r := await _measure_pass(sv, vp_rid, quad, base_mat, cov)
		baseline_by_cov[cov] = r
		print("[P2-BENCH Baseline cov=%d%%] gpu_ms=%.4f (p95=%.4f) cpu_ms=%.4f frame_ms=%.3f (p95=%.3f)" % [
			cov, float(r["gpu_ms_median"]), float(r["gpu_ms_p95"]), float(r["cpu_ms_median"]), float(r["frame_ms_median"]), float(r["frame_ms_p95"]),
		])

	var asset_results := []
	for item in DEMO_ASSETS:
		var aid: String = item["id"]
		var path := "%s/%s" % [assets_root, item["subpath"]]
		var loaded := _VnmMat.load_from_path(path, _VnmGen.SamplingPath.HARDWARE_BILINEAR)
		if not loaded.get("ok", false):
			push_error("[P2-BENCH ERROR] Failed to load %s: %s" % [path, str(loaded.get("error", ""))])
			get_tree().quit(1)
			return
		var vnm_mat: _VnmMat = loaded["vnm_material"]
		var pkg: _VnmPkg = loaded["package"]
		var timings := []
		for cov in COVERAGES:
			var base_r: Dictionary = baseline_by_cov[cov]
			var r := await _measure_pass(sv, vp_rid, quad, vnm_mat.material, cov)
			var delta_gpu := float(r["gpu_ms_median"]) - float(base_r["gpu_ms_median"])
			var delta_frame := float(r["frame_ms_median"]) - float(base_r["frame_ms_median"])
			r["baseline_gpu_ms_median"] = base_r["gpu_ms_median"]
			r["baseline_frame_ms_median"] = base_r["frame_ms_median"]
			r["delta_gpu_ms_median"] = delta_gpu
			r["delta_frame_ms_median"] = delta_frame
			timings.append(r)
			print("[P2-BENCH %s (%s) cov=%d%%] gpu_ms=%.4f (delta=%+.4f) | frame_ms=%.3f (delta=%+.3f, p95=%.3f)" % [
				aid, pkg.profile, cov, float(r["gpu_ms_median"]), delta_gpu, float(r["frame_ms_median"]), delta_frame, float(r["frame_ms_p95"]),
			])
		asset_results.append({
			"asset_label": aid,
			"asset_id": pkg.asset_id,
			"profile": pkg.profile,
			"fine_size": [pkg.fine_size.x, pkg.fine_size.y],
			"coarse_size": [pkg.coarse_size.x, pkg.coarse_size.y],
			"timings": timings,
		})

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tests/reports"))
	var report := {
		"suite": "VNM1-Godot-P2-Aligned-Cost",
		"godot_version": Engine.get_version_info()["string"],
		"adapter": adapter,
		"rendering_method": method,
		"resolution": [VP_W, VP_H],
		"warmup_frames": _warmup_frames,
		"measured_frames": _measured_frames,
		"vsync_mode": DisplayServer.window_get_vsync_mode(),
		"baseline": baseline_by_cov,
		"assets": asset_results,
	}
	var out_path := ProjectSettings.globalize_path("res://tests/reports/godot_p2_cost_%s.json" % method)
	var fa := FileAccess.open(out_path, FileAccess.WRITE)
	fa.store_string(JSON.stringify(report, "  "))
	fa.close()
	print("[P2-BENCH DONE] report=", out_path)
	get_tree().quit(0)
