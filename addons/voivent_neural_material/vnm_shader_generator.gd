class_name VnmShaderGenerator
extends RefCounted

const _VnmLdr = preload("res://addons/voivent_neural_material/vnm_loader.gd")

## Generates Godot 4.7 spatial shaders from a single unified VNM1 template across
## all registered profiles (small, standard, quality, standard8, quality8),
## Path A (hardware bilinear) and Path B (exact SPEC §6.1 bilinear), and
## verification bit-exact readback mode (G-4).

enum SamplingPath {
	EXACT_BILINEAR = 0,     # Path B: texelFetch + SPEC §6.1 exact interpolation (1e-4 gate)
	HARDWARE_BILINEAR = 1,  # Path A: textureLod linear filter (SPEC §7.2 two-tier gate)
}

static func _wrap_hint(wrap_u: String, wrap_v: String) -> String:
	return "repeat_disable" if (wrap_u == "clamp" and wrap_v == "clamp") else "repeat_enable"

static func _build_common_core(profile: String, path: SamplingPath, wrap_u: String, wrap_v: String) -> String:
	if not _VnmLdr.PROFILE_SPECS.has(profile):
		push_error("Unsupported VNM1 profile: %s" % profile)
		return ""
	var spec: Dictionary = _VnmLdr.PROFILE_SPECS[profile]
	var in_dim: int = int(spec["input_dim"])
	var h1: int = int(spec["h1"])
	var h2: int = int(spec["h2"])
	var out_dim: int = int(spec["output_dim"])
	var ch: int = int(spec["latent_ch"])

	var in_v4 := in_dim / 4
	var h1_v4 := h1 / 4
	var h2_v4 := h2 / 4

	var w1_start := 0
	var b1_start := w1_start + h1 * in_v4
	var w2_start := b1_start + h1_v4
	var b2_start := w2_start + h2 * h1_v4
	var w3_start := b2_start + h2_v4
	var b3_start := w3_start + out_dim * h2_v4

	var tex_hint := "filter_nearest, repeat_disable" if path == SamplingPath.EXACT_BILINEAR else ("filter_linear, %s" % _wrap_hint(wrap_u, wrap_v))

	var uniforms := """
uniform sampler2D weights_tex : filter_nearest, repeat_disable;
uniform sampler2D fine_tex0 : %s;
uniform sampler2D coarse_tex0 : %s;
""" % [tex_hint, tex_hint]

	if ch == 8:
		uniforms += """
uniform sampler2D fine_tex1 : %s;
uniform sampler2D coarse_tex1 : %s;
""" % [tex_hint, tex_hint]

	uniforms += """
uniform sampler2D tail_tex0 : filter_linear, %s;
uniform sampler2D tail_tex1 : filter_linear, %s;
uniform ivec2 fine_size = ivec2(512, 512);
uniform ivec2 coarse_size = ivec2(256, 256);
uniform vec2 source_size = vec2(2048.0, 2048.0);
uniform float mip_max = 6.0;
uniform float tail_first_mip = 7.0;
uniform bool wrap_u_repeat = true;
uniform bool wrap_v_repeat = true;
uniform bool latent_is_float = false;
uniform bool enable_lod_mip = false;
uniform bool enable_tail_switch = true;
uniform bool use_normalized_mip_override = false;
uniform float normalized_mip_override = 0.0;
""" % [_wrap_hint(wrap_u, wrap_v), _wrap_hint(wrap_u, wrap_v)]

	var helpers := """
vec4 fetch_w(int idx) {
	return texelFetch(weights_tex, ivec2(idx & 31, idx >> 5), 0);
}

int wrap_idx(int c, int sz, bool rep) {
	if (rep) {
		int m = c % sz;
		return (m < 0) ? (m + sz) : m;
	}
	return clamp(c, 0, sz - 1);
}

vec4 decode_latent_texel(vec4 raw) {
	return latent_is_float ? raw : (raw * 2.0 - 1.0);
}

vec4 sample_exact(sampler2D t, vec2 uv_eff, ivec2 sz, bool rep_u, bool rep_v) {
	float p = uv_eff.x * float(sz.x) - 0.5;
	float q = uv_eff.y * float(sz.y) - 0.5;
	int x0 = int(floor(p));
	int y0 = int(floor(q));
	float fx = p - float(x0);
	float fy = q - float(y0);
	int ix0 = wrap_idx(x0, sz.x, rep_u);
	int ix1 = wrap_idx(x0 + 1, sz.x, rep_u);
	int iy0 = wrap_idx(y0, sz.y, rep_v);
	int iy1 = wrap_idx(y0 + 1, sz.y, rep_v);
	vec4 f00 = decode_latent_texel(texelFetch(t, ivec2(ix0, iy0), 0));
	vec4 f10 = decode_latent_texel(texelFetch(t, ivec2(ix1, iy0), 0));
	vec4 f01 = decode_latent_texel(texelFetch(t, ivec2(ix0, iy1), 0));
	vec4 f11 = decode_latent_texel(texelFetch(t, ivec2(ix1, iy1), 0));
	return mix(mix(f00, f10, fx), mix(f01, f11, fx), fy);
}

vec4 sample_hw(sampler2D t, vec2 raw_uv, ivec2 sz, bool rep_u, bool rep_v) {
	float hu = rep_u ? raw_uv.x : clamp(raw_uv.x, 0.5 / float(sz.x), 1.0 - 0.5 / float(sz.x));
	float hv = rep_v ? raw_uv.y : clamp(raw_uv.y, 0.5 / float(sz.y), 1.0 - 0.5 / float(sz.y));
	return textureLod(t, vec2(hu, hv), 0.0) * 2.0 - 1.0;
}

vec3 reconstruct_normal(float raw_nx, float raw_ny) {
	float nx = clamp(raw_nx, -1.0, 1.0);
	float ny = clamp(raw_ny, -1.0, 1.0);
	float xy_sq = nx * nx + ny * ny;
	if (xy_sq > 1.0) {
		float inv_l = inversesqrt(xy_sq);
		nx *= inv_l;
		ny *= inv_l;
	}
	float nz = sqrt(max(0.0, 1.0 - (nx * nx + ny * ny)));
	return normalize(vec3(nx, ny, nz));
}
"""

	var eval_fn := """
void eval_vnm1_raw(vec2 in_uv, float norm_mip, bool rep_u, bool rep_v, out float raw_out[8]) {
	float u_eff = rep_u ? fract(in_uv.x) : clamp(in_uv.x, 0.0, 1.0);
	float v_eff = rep_v ? fract(in_uv.y) : clamp(in_uv.y, 0.0, 1.0);
	vec2 uv_eff = vec2(u_eff, v_eff);

	float p_fine = u_eff * float(fine_size.x) - 0.5;
	float q_fine = v_eff * float(fine_size.y) - 0.5;
	vec2 r = vec2(2.0 * fract(p_fine) - 1.0, 2.0 * fract(q_fine) - 1.0);

	vec4 x_v[%d];
""" % in_v4

	if path == SamplingPath.EXACT_BILINEAR:
		eval_fn += "	x_v[0] = sample_exact(fine_tex0, uv_eff, fine_size, rep_u, rep_v);\n"
		if ch == 8:
			eval_fn += """	x_v[1] = sample_exact(fine_tex1, uv_eff, fine_size, rep_u, rep_v);
	x_v[2] = sample_exact(coarse_tex0, uv_eff, coarse_size, rep_u, rep_v);
	x_v[3] = sample_exact(coarse_tex1, uv_eff, coarse_size, rep_u, rep_v);
	x_v[4] = vec4(r.x, r.y, norm_mip, 1.0);
"""
		else:
			eval_fn += """	x_v[1] = sample_exact(coarse_tex0, uv_eff, coarse_size, rep_u, rep_v);
	x_v[2] = vec4(r.x, r.y, norm_mip, 1.0);
"""
	else:
		eval_fn += "	x_v[0] = sample_hw(fine_tex0, in_uv, fine_size, rep_u, rep_v);\n"
		if ch == 8:
			eval_fn += """	x_v[1] = sample_hw(fine_tex1, in_uv, fine_size, rep_u, rep_v);
	x_v[2] = sample_hw(coarse_tex0, in_uv, coarse_size, rep_u, rep_v);
	x_v[3] = sample_hw(coarse_tex1, in_uv, coarse_size, rep_u, rep_v);
	x_v[4] = vec4(r.x, r.y, norm_mip, 1.0);
"""
		else:
			eval_fn += """	x_v[1] = sample_hw(coarse_tex0, in_uv, coarse_size, rep_u, rep_v);
	x_v[2] = vec4(r.x, r.y, norm_mip, 1.0);
"""

	eval_fn += """
	// Layer 1 (ReLU)
	vec4 h1_v[%d];
	for (int o = 0; o < %d; o += 4) {
		vec4 bias_v = fetch_w(%d + (o >> 2));
		float s0 = bias_v.x; float s1 = bias_v.y; float s2 = bias_v.z; float s3 = bias_v.w;
		for (int k = 0; k < %d; k++) {
			vec4 xv = x_v[k];
			s0 += dot(fetch_w(%d + (o + 0) * %d + k), xv);
			s1 += dot(fetch_w(%d + (o + 1) * %d + k), xv);
			s2 += dot(fetch_w(%d + (o + 2) * %d + k), xv);
			s3 += dot(fetch_w(%d + (o + 3) * %d + k), xv);
		}
		h1_v[o >> 2] = max(vec4(s0, s1, s2, s3), vec4(0.0));
	}

	// Layer 2 (ReLU)
	vec4 h2_v[%d];
	for (int o = 0; o < %d; o += 4) {
		vec4 bias_v = fetch_w(%d + (o >> 2));
		float s0 = bias_v.x; float s1 = bias_v.y; float s2 = bias_v.z; float s3 = bias_v.w;
		for (int k = 0; k < %d; k++) {
			vec4 hv = h1_v[k];
			s0 += dot(fetch_w(%d + (o + 0) * %d + k), hv);
			s1 += dot(fetch_w(%d + (o + 1) * %d + k), hv);
			s2 += dot(fetch_w(%d + (o + 2) * %d + k), hv);
			s3 += dot(fetch_w(%d + (o + 3) * %d + k), hv);
		}
		h2_v[o >> 2] = max(vec4(s0, s1, s2, s3), vec4(0.0));
	}

	// Layer 3 (Linear output)
	for (int o = 0; o < 8; o += 4) {
		vec4 bias_v = fetch_w(%d + (o >> 2));
		float s0 = bias_v.x; float s1 = bias_v.y; float s2 = bias_v.z; float s3 = bias_v.w;
		for (int k = 0; k < %d; k++) {
			vec4 hv = h2_v[k];
			s0 += dot(fetch_w(%d + (o + 0) * %d + k), hv);
			s1 += dot(fetch_w(%d + (o + 1) * %d + k), hv);
			s2 += dot(fetch_w(%d + (o + 2) * %d + k), hv);
			s3 += dot(fetch_w(%d + (o + 3) * %d + k), hv);
		}
		raw_out[o + 0] = s0;
		raw_out[o + 1] = s1;
		raw_out[o + 2] = s2;
		raw_out[o + 3] = s3;
	}
}
""" % [
		h1_v4, h1, b1_start, in_v4,
		w1_start, in_v4, w1_start, in_v4, w1_start, in_v4, w1_start, in_v4,
		h2_v4, h2, b2_start, h1_v4,
		w2_start, h1_v4, w2_start, h1_v4, w2_start, h1_v4, w2_start, h1_v4,
		b3_start, h2_v4,
		w3_start, h2_v4, w3_start, h2_v4, w3_start, h2_v4, w3_start, h2_v4,
	]

	return uniforms + helpers + eval_fn

static func generate_spatial_pbr_shader_code(
	profile: String,
	path: SamplingPath = SamplingPath.HARDWARE_BILINEAR,
	wrap_u: String = "repeat",
	wrap_v: String = "repeat",
) -> String:
	var core := _build_common_core(profile, path, wrap_u, wrap_v)
	var entry := """
void fragment() {
	vec2 d_uv_x = dFdx(UV) * source_size;
	vec2 d_uv_y = dFdy(UV) * source_size;
	float rho = max(length(d_uv_x), length(d_uv_y));
	float mip_est = log2(max(rho, 1.0));

	float n_mip = 0.0;
	if (use_normalized_mip_override) {
		n_mip = clamp(normalized_mip_override, 0.0, 1.0);
	} else if (enable_lod_mip) {
		n_mip = clamp(mip_est / mip_max, 0.0, 1.0);
	}

	float active_mip = use_normalized_mip_override ? (n_mip * mip_max) : mip_est;
	if (enable_tail_switch && active_mip >= tail_first_mip) {
		vec2 t_sz = vec2(textureSize(tail_tex0, 0));
		vec2 uv_tail = vec2(
			wrap_u_repeat ? UV.x : clamp(UV.x, 0.5 / t_sz.x, 1.0 - 0.5 / t_sz.x),
			wrap_v_repeat ? UV.y : clamp(UV.y, 0.5 / t_sz.y, 1.0 - 0.5 / t_sz.y)
		);
		vec4 t0 = textureLod(tail_tex0, uv_tail, 0.0);
		vec4 t1 = textureLod(tail_tex1, uv_tail, 0.0);
		ALBEDO = t0.rgb;
		NORMAL_MAP = reconstruct_normal(t0.a * 2.0 - 1.0, t1.r * 2.0 - 1.0) * 0.5 + 0.5;
		ROUGHNESS = t1.g;
		METALLIC = t1.b;
		AO = t1.a;
	} else {
		float y[8];
		eval_vnm1_raw(UV, n_mip, wrap_u_repeat, wrap_v_repeat, y);
		ALBEDO = clamp(vec3(y[0], y[1], y[2]), vec3(0.0), vec3(1.0));
		NORMAL_MAP = reconstruct_normal(y[3], y[4]) * 0.5 + 0.5;
		ROUGHNESS = clamp(y[5], 0.0, 1.0);
		METALLIC = clamp(y[6], 0.0, 1.0);
		AO = clamp(y[7], 0.0, 1.0);
	}
}
"""
	return "shader_type spatial;\n" + core + entry

static func generate_verification_shader_code(
	profile: String,
	path: SamplingPath,
	wrap_u: String = "repeat",
	wrap_v: String = "repeat",
	case_count: int = 286,
) -> String:
	var core := _build_common_core(profile, path, wrap_u, wrap_v)
	var verify_uniforms_and_frag := """
uniform sampler2D cases_tex : filter_nearest, repeat_disable;
uniform bool output_pbr_post = false;

void fragment() {
	ivec2 px = clamp(ivec2(floor(UV * vec2(float(%d), 18.0))), ivec2(0), ivec2(%d, 17));
	int case_idx = px.x;
	int row = px.y;
	int ch_idx = row / 2;
	int byte_slot = row %% 2;

	vec4 cdata = texelFetch(cases_tex, ivec2(case_idx, 0), 0);
	int wflags = int(round(cdata.w));
	bool rep_u = (wflags & 1) != 0;
	bool rep_v = (wflags & 2) != 0;

	float y[8];
	eval_vnm1_raw(cdata.xy, clamp(cdata.z, 0.0, 1.0), rep_u, rep_v, y);

	float out_val = 0.0;
	if (!output_pbr_post) {
		out_val = (ch_idx < 8) ? y[ch_idx] : 0.0;
	} else {
		if (ch_idx < 3) {
			out_val = clamp(y[ch_idx], 0.0, 1.0);
		} else if (ch_idx >= 3 && ch_idx <= 5) {
			vec3 n = reconstruct_normal(y[3], y[4]);
			if (ch_idx == 3) out_val = n.x;
			else if (ch_idx == 4) out_val = n.y;
			else out_val = n.z;
		} else if (ch_idx == 6) {
			out_val = clamp(y[5], 0.0, 1.0);
		} else if (ch_idx == 7) {
			out_val = clamp(y[6], 0.0, 1.0);
		} else {
			out_val = clamp(y[7], 0.0, 1.0);
		}
	}

	uint bits = floatBitsToUint(out_val);
	if (byte_slot == 0) {
		ALBEDO = vec3(float(bits & 255u) / 255.0, float((bits >> 8u) & 255u) / 255.0, 0.0);
	} else {
		ALBEDO = vec3(float((bits >> 16u) & 255u) / 255.0, float((bits >> 24u) & 255u) / 255.0, 0.0);
	}
}
""" % [case_count, case_count - 1]
	return "shader_type spatial;\nrender_mode unshaded;\n" + core + verify_uniforms_and_frag
