# Voivent Neural Material (VNM1) for Godot 4.7+

Runtime loader and GPU fragment-shader decoder addon for **Voivent Neural Material (VNM1)** PBR materials in Godot `4.7.2` (4.7 series) across **Forward+**, **Mobile**, and **Compatibility** renderers.

## Features

- **Zero GDExtension required**: Pure GDScript + Godot spatial shading language (`addons/voivent_neural_material/`).
- **All 5 VNM1 profiles supported** from a single parameterized template: `small` (4ch), `standard` (4ch), `quality` (4ch), `standard8` (8ch), and `quality8` (8ch).
- **Weights as `RGBA32F` texture (`texelFetch`)**: Bypasses uniform vector size limits cleanly across Forward+, Mobile, and Compatibility.
- **Two sampling paths**:
  - `HARDWARE_BILINEAR` (Path A, default runtime): Hardware `textureLod` filtering, passing `SPEC §7.2` (`<= 1e-4` lattice, `<= 2.0e-4` arbitrary UV).
  - `EXACT_BILINEAR` (Path B, strict conformance): `texelFetch` x 4 manual `SPEC §6.1` bilinear interpolation with exact `repeat` / `clamp` wrapping (`<= 1e-4` gate).
- **Runtime `.vnm` folder and `.zip` loader**: Reads 4-file VNM1 bundles (`manifest.json`, `weights.bin`, `level-0.bin`, `tail.bin`) with strict SHA-256, header magic/version, subheader dimension, and reserved-byte validation without going through editor image import.
- **Progressive `tail` transition & `normalizedMip` override**: Includes `use_normalized_mip_override` / `normalized_mip_override` for golden verification and distance-based switching to split `tail` textures.

## Installation

1. Copy `addons/voivent_neural_material/` into your Godot 4.7+ project's `addons/` folder.
2. Enable **Voivent Neural Material (VNM1)** under **Project -> Project Settings -> Plugins**.

## Quickstart

```gdscript
extends Node3D

func _ready() -> void:
	var mesh_instance := $MeshInstance3D
	var result := VnmMaterial.apply_to_mesh(mesh_instance, "res://materials/marble.vnm")
	if not result.get("ok", false):
		push_error("Failed to load VNM1 material: %s" % result.get("error", ""))
```

For strict mathematical `EXACT_BILINEAR` sampling or verification `normalizedMip` overrides:

```gdscript
var res := VnmMaterial.load_from_path(
	"res://materials/marble.vnm",
	VnmShaderGenerator.SamplingPath.EXACT_BILINEAR
)
var vnm_mat: VnmMaterial = res["vnm_material"]
vnm_mat.bind_to_mesh($MeshInstance3D)
vnm_mat.set_normalized_mip_override(true, 0.5)
```

## Verification & Re-running SPEC §7 Conformance Tests

> **Important**: Godot's `--headless` flag uses the dummy renderer and returns empty pixels. Always run GPU verification against a real window/virtual display driver (e.g. `xvfb-run` + `--rendering-driver vulkan` on Linux CI, or `--rendering-driver metal` / `vulkan` on macOS).

### 1. Loader & Strict Rejection Suite (`G-1`)
```bash
godot --path . res://tests/test_g1_loader.tscn --rendering-driver metal --resolution 128x128 --quit-after 300
```

### 2. Golden Vector `SPEC §7` Two-Tier Conformance Suite (`G-4`)
Tests all 4 profiles (`standard`, `standard8`, `quality`, `quality8` x 286 cases) across Path B float, Path B u8, Path A hardware bilinear, plus a negative control (deterministically shuffled latent bytes that must fail the gate):
```bash
VNM_GOLDEN_DIR=../voivent-neural-material/src/__tests__/fixtures \
  godot --path . res://tests/test_g4_golden_harness.tscn --rendering-driver metal --resolution 128x128 --quit-after 600
```
Outputs JSON report to `tests/reports/godot_g4_report.json`.

### 3. Real CC0 Demo Assets End-to-End Suite (`G-5`)
Tests all 4 demo assets (`marble`, `fabric030`, `sand`, `cloth`) across Forward+, Mobile, and Compatibility renderers:
```bash
VNM_DEMO_ASSETS_DIR=../../satellite/worker/assets/lab/vnm/demo-assets \
  godot --path . res://tests/test_g5_demo_assets.tscn --rendering-driver metal --resolution 128x128 --quit-after 5000
```

## Sample Scene

Open `demo/sample_scene.tscn` or run from CLI:
```bash
godot --path . res://demo/sample_scene.tscn -- --vnm=../../satellite/worker/assets/lab/vnm/demo-assets/marble/marble.vnm
```

## License

Licensed under the [Apache License, Version 2.0](./LICENSE).
