class_name VnmPackage
extends RefCounted

## Parsed VNM1 asset container holding validated metadata and runtime GPU textures.

var asset_id: String = ""
var profile: String = ""
var source_size: Vector2i = Vector2i.ZERO
var fine_size: Vector2i = Vector2i.ZERO
var coarse_size: Vector2i = Vector2i.ZERO
var tail_size: Vector2i = Vector2i.ZERO
var tail_first_mip: int = 0
var mip_max: float = 1.0
var has_explicit_mip_max: bool = false
var wrap_u: String = "repeat"
var wrap_v: String = "repeat"
var input_dim: int = 12
var hidden1: int = 24
var hidden2: int = 24
var output_dim: int = 8
var latent_channels: int = 4
var total_weights: int = 1112

var weights_texture: ImageTexture = null
var weights_tex_size: Vector2i = Vector2i(32, 16)
var fine_textures: Array[ImageTexture] = []
var coarse_textures: Array[ImageTexture] = []
var tail_textures: Array[ImageTexture] = []

var weights_bytes: PackedByteArray = PackedByteArray()
var fine_bytes: PackedByteArray = PackedByteArray()
var coarse_bytes: PackedByteArray = PackedByteArray()
var tail_bytes: PackedByteArray = PackedByteArray()

func get_resolved_mip_max() -> float:
	return mip_max if has_explicit_mip_max else float(maxi(1, tail_first_mip - 1))
