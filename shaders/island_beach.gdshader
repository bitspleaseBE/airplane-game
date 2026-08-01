shader_type canvas_item;
render_mode blend_mix, unshaded;

/// One island's beach: coastal shelf, surf foam, wet/dry sand and the grass pad.
///
/// This is a port of what Island.render_island_image() used to do — the identical
/// shading maths, but evaluated per pixel on the GPU instead of as a per-pixel
/// GDScript loop writing Image.set_pixel(). That loop cost 1.3 s for a level-1
/// island and 4.3 s at level 20 (a 1114x1114 texture), on the main thread, and
/// the web export sets thread_support=false so it could not be moved off it. It
/// ran on every level activation, which is what made "next bastion" and
/// "restart" hitch.
///
/// The coast silhouette is unchanged: it still comes from the CPU-built sand and
/// grass LUTs, handed over as `coast_lut`. Anything keyed off
/// Island.get_shore_radius() — plane spawn validation, camera framing — reads the
/// same LUTs it always did.
///
/// Noise: the CPU version sampled FastNoiseLite (simplex_smooth, 2 octaves,
/// frequency 0.14). Here we re-centre and rescale the baked fBm tile shared with
/// the water shader to reproduce that distribution — see grain() below.

/// Coast radii per angle, 256 samples. Row 0 = sand, row 1 = grass, each packed
/// big-endian across the R and G bytes because 8 bits over a ~780-unit range
/// would quantise the coastline into visible 3-unit steps.
uniform sampler2D coast_lut : filter_nearest, repeat_enable;
/// World-unit range the 16-bit LUT values are normalised against.
uniform float lut_range = 1024.0;

/// Baked fBm, shared with shaders/water.gdshader.
uniform sampler2D noise_tex : filter_linear, repeat_enable;

/// Detached sand fragments off the coast: xy = centre (island-relative), z = radius.
const int MAX_ISLETS = 4;
uniform int islet_count = 0;
uniform vec3 islets[MAX_ISLETS];

/// Turquoise sandbar blobs that connect to the shelf. Same packing.
const int MAX_LOBES = 8;
uniform int lobe_count = 0;
uniform vec3 lobes[MAX_LOBES];

const float LUT_SIZE = 256.0;
/// Furthest the shelf can reach past the sand — shelf_w is clamped to 85 below,
/// and the foam band lies inside that. Used for the early reject in fragment().
const float BEACH_REACH = 86.0;
const float NOISE_BASE_UV = 0.0625;
/// FastNoiseLite at frequency 0.14 put features 1/0.14 input units apart, and its
/// 2-octave fBm measured ~0 mean, ~0.305 std, ~[-0.9, 0.9] range. Re-centring the
/// baked tile (mean 0.5037, std 0.1466 normalised) and scaling by 0.305/0.1466
/// reproduces all three, so every constant below keeps its calibration.
const float GRAIN_FEATURE = 7.1428571;
const float GRAIN_MEAN = 0.5037;
const float GRAIN_GAIN = 2.08;
/// Input-space period of the baked tile: 16 lattice units x GRAIN_FEATURE.
const float GRAIN_TILE = 114.28571;

/// Per-island slide through the shared tile. The CPU bake seeded FastNoiseLite
/// with hash("grain_<level>"), so each bastion got its own field; one shared
/// texture sampled at island-relative coordinates would otherwise give all 20
/// islands identical shelf bulges and wet-sand banding.
uniform vec2 grain_offset = vec2(0.0);

/// Decorrelation offsets, spread inside the tile period (16 * GRAIN_FEATURE, so
/// ~114.3 input units). The CPU offsets — 120, 880, 300, ... — were chosen for an
/// unbounded noise field; modulo a tiling one, several of them collapse onto the
/// same patch and the lookups they were meant to separate become correlated.
const vec2 OFF_SHELF_LO = vec2(5.7, 61.3);
const vec2 OFF_SHELF_MID = vec2(79.9, 14.2);
const vec2 OFF_SHELF_BAR = vec2(40.1, 92.6);
const vec2 OFF_FOAM_W = vec2(96.4, 37.8);
const vec2 OFF_FOAM_PATCH = vec2(22.5, 78.1);
const vec2 OFF_WET_WAVE = vec2(61.8, 4.9);
const vec2 OFF_WET_MOD = vec2(12.7, 105.2);
const vec2 OFF_GRASS_PATCH = vec2(88.3, 52.4);
const vec2 OFF_LOBE = vec2(47.6, 25.0);
const vec2 OFF_SURGE = vec2(33.9, 68.7);

/// How far the surf line travels up and down the beach, as a multiplier on the
/// surge amplitude. 0 freezes the shoreline (what the CPU bake did, since a baked
/// texture cannot move).
uniform float surf_motion = 1.0;

varying vec2 local_pos;

void vertex() {
	// The beach quad sits at the island origin inside an unscaled Land node, so
	// local space is island-relative space — the same `p` the CPU bake shaded in.
	local_pos = VERTEX;
}

/// Stand-in for FastNoiseLite.get_noise_2d: ~0 mean, ~0.305 std, ~[-0.9, 0.9].
float grain(vec2 p) {
	float raw = texture(noise_tex, (p + grain_offset) * (NOISE_BASE_UV / GRAIN_FEATURE)).r;
	return (raw - GRAIN_MEAN) * GRAIN_GAIN;
}

/// Decode one big-endian 16-bit value from an (R, G) byte pair.
float decode16(vec2 pair) {
	float hi = floor(pair.x * 255.0 + 0.5);
	float lo = floor(pair.y * 255.0 + 0.5);
	return (hi * 256.0 + lo) / 65535.0 * lut_range;
}

/// Sand and grass radius at `theta`, wrapping and lerping exactly as the old
/// _lut_at_static did.
vec2 coast_at(float theta) {
	float t = fract(theta / TAU) * LUT_SIZE;
	float i = floor(t);
	float f = t - i;
	float u0 = (i + 0.5) / LUT_SIZE;
	float u1 = (i + 1.5) / LUT_SIZE;
	float sand = mix(
		decode16(texture(coast_lut, vec2(u0, 0.25)).rg),
		decode16(texture(coast_lut, vec2(u1, 0.25)).rg),
		f
	);
	float grass = mix(
		decode16(texture(coast_lut, vec2(u0, 0.75)).rg),
		decode16(texture(coast_lut, vec2(u1, 0.75)).rg),
		f
	);
	return vec2(sand, grass);
}

/// Shade one landmass. Called for the island proper and again per islet, which is
/// why it takes `dist` and the radii rather than deriving them — an islet reuses
/// the whole profile around its own centre, while `p` stays island-relative so
/// the noise field is continuous across both.
vec4 shade_land(vec2 p, float dist, float sand_r, float grass_r) {
	// Irregular turquoise shelf — width varies, with connected bulges, so it
	// doesn't read as a uniform coast-hugging ring.
	float n_lo = grain(p * 0.038 + OFF_SHELF_LO);
	float n_mid = grain(p * 0.078 + OFF_SHELF_MID);
	float n_bar = grain(p * 0.05 + OFF_SHELF_BAR);
	// Always a readable base shelf; noise only warps how far it reaches.
	float shelf_w = mix(16.0, 44.0, 0.5 + 0.5 * n_lo);
	shelf_w += max(0.0, n_mid - 0.1) * 38.0;
	float bar = max(0.0, n_bar - 0.1);
	shelf_w += bar * 55.0;
	shelf_w = clamp(shelf_w, 14.0, 85.0);

	float shallow_a = (1.0 - smoothstep(sand_r, sand_r + shelf_w, dist)) * 0.7;
	// Mild mottling — never erase the shelf.
	shallow_a *= mix(0.72, 1.0, clamp(0.5 + n_mid * 0.55 + bar * 0.3, 0.0, 1.0));
	float land_a = 1.0 - smoothstep(sand_r - 2.0, sand_r + 2.0, dist);
	if (shallow_a <= 0.004 && land_a <= 0.004) {
		return vec4(0.0);
	}

	float near = 1.0 - smoothstep(sand_r, sand_r + max(12.0, shelf_w * 0.5), dist);
	vec3 rgb = mix(vec3(0.62, 0.90, 0.88), vec3(0.82, 0.97, 0.95), near * 0.85);
	float alpha = shallow_a;

	// Surf runs up the beach and drains back. The crest travels shoreward at the
	// same wavelength and speed as the water shader's swell (2*PI/0.055 world units
	// at 1.15/0.055 units per second), so the two read as one wave system even
	// though they measure shore distance from different references. The noise term
	// desynchronises the phase around the coast, so stretches of beach surge at
	// slightly different moments instead of pulsing as one ring.
	float surge = sin(
		(dist - sand_r) * -0.055 + TIME * 1.15 + grain(p * 0.02 + OFF_SURGE) * 2.6
	) * surf_motion;

	// Foam: undulating surf, always present but uneven.
	float foam_w = 11.0 + grain(p * 0.22 + OFF_FOAM_W) * 6.0;
	float foam_line = sand_r + 1.0 + surge * 7.0;
	float foam = (1.0 - smoothstep(0.0, foam_w, abs(dist - foam_line))) * 0.75;
	foam *= clamp(0.5 + grain(p * 0.11 + OFF_FOAM_PATCH) * 0.7, 0.35, 1.0);
	if (foam > 0.01) {
		rgb = mix(rgb, vec3(0.98, 0.99, 0.96), foam);
		alpha = max(alpha, foam * 0.85);
	}

	if (land_a > 0.004) {
		// Wave-washed wet band, patchy around the coast: some stretches soaked,
		// others nearly dry, so the dark edge never reads as a uniform ring. Its
		// upper edge rides the same surge, so sand darkens as the wash covers it
		// and pales again as the water drains off.
		float wave = grain(p * 0.18 + OFF_WET_WAVE) * 9.0;
		float wet_mod = clamp(0.5 + grain(p * 0.04 + OFF_WET_MOD) * 1.1, 0.12, 1.0);
		float wet = smoothstep(sand_r - 46.0 + wave, sand_r - 4.0 + surge * 5.0, dist);
		vec3 col = mix(vec3(0.94, 0.85, 0.60), vec3(0.66, 0.56, 0.40), wet * wet * wet_mod);
		float g = grain(p) * 0.035;
		col += vec3(g, g * 0.85, g * 0.65);
		if (grass_r > 0.0) {
			float gm = 1.0 - smoothstep(grass_r - 10.0, grass_r + 10.0, dist);
			float glow = clamp(1.0 - dist / max(grass_r * 0.9, 1.0), 0.0, 1.0) * 0.55;
			vec3 grass_col = mix(vec3(0.34, 0.60, 0.26), vec3(0.55, 0.72, 0.38), glow);
			float patch = grain(p * 0.3 + OFF_GRASS_PATCH) * 0.03;
			grass_col += vec3(patch, patch, patch * 0.6);
			float rim = (1.0 - smoothstep(0.0, 12.0, abs(dist - (grass_r - 6.0)))) * 0.1;
			// Matches Color.darkened(rim), which scales RGB by (1 - rim).
			col = mix(col, grass_col * (1.0 - rim), gm);
		}
		rgb = mix(rgb, col, land_a);
		alpha = land_a + alpha * (1.0 - land_a);
	}
	return vec4(rgb, alpha);
}

void fragment() {
	vec2 p = local_pos;
	float dist = length(p);
	vec2 coast = coast_at(atan(p.y, p.x));
	float sand_r = coast.x;

	// Reject before sampling any noise. shade_land() clamps shelf_w to 85 and the
	// foam band sits inside that, so past sand_r + 85 it can only return alpha 0 —
	// this is the same test it would reach anyway, just before the nine grain()
	// fetches rather than after. The quad is a square around the island's furthest
	// lobe, so on an arm or hook coast most of it is exactly this dead area.
	bool live = dist < sand_r + BEACH_REACH;
	for (int i = 0; i < islet_count; i++) {
		if (distance(p, islets[i].xy) < islets[i].z + 78.0) {
			live = true;
		}
	}
	for (int i = 0; i < lobe_count; i++) {
		if (distance(p, lobes[i].xy) < lobes[i].z) {
			live = true;
		}
	}

	// Everything below stays inside this branch rather than early-returning: Godot
	// rejects `return` in the fragment processor.
	vec4 col = vec4(0.0);
	if (live) {
		col = shade_land(p, dist, sand_r, coast.y);

		// Islets win wherever they are more opaque than the main coast.
		for (int i = 0; i < islet_count; i++) {
			float idist = distance(p, islets[i].xy);
			float ir = islets[i].z;
			if (idist > ir + 78.0) {
				continue;
			}
			vec4 icol = shade_land(p, idist, ir, ir > 15.0 ? ir * 0.55 : 0.0);
			if (icol.a > col.a) {
				col = icol;
			}
		}

		// Sandbars only over water, so they never tint the beach itself.
		if (dist >= sand_r - 1.0) {
			for (int i = 0; i < lobe_count; i++) {
				float ld = distance(p, lobes[i].xy);
				float lr = lobes[i].z;
				if (ld > lr) {
					continue;
				}
				float la = (1.0 - smoothstep(lr * 0.15, lr, ld)) * 0.72;
				la *= 0.65 + 0.35 * grain(p * 0.1 + OFF_LOBE);
				if (la <= 0.004) {
					continue;
				}
				vec3 sc = mix(vec3(0.60, 0.90, 0.88), vec3(0.80, 0.97, 0.95), 1.0 - ld / lr);
				float a = max(col.a, la);
				col = vec4(mix(col.rgb, sc, la / max(a, 0.001)), a);
			}
		}
	}

	COLOR = col;
}
