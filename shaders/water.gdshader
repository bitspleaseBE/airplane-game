shader_type canvas_item;
render_mode blend_mix, unshaded;

/// Open ocean with optional single-island foam LUT (legacy).
/// When open_ocean is true, only depth/variation — shores are baked into island sprites.
///
/// water_quality:
///   0 = web/mobile cheap path (few noise taps, radial shore only)
///   1 = full desktop look (warped coasts, multi-octave chop)

uniform bool open_ocean = true;
uniform vec2 island_center = vec2(360.0, 640.0);
uniform float island_radius = 300.0;
uniform sampler2D radius_lut : filter_linear, repeat_enable;

// Campaign islands: water shades from bright shallows near any coast to deep
// open sea between islands. Callers should feed only the nearest few.
uniform int island_count = 0;
uniform vec2 island_centers[40];
uniform float island_radii[40];
uniform int water_quality = 1;

uniform vec4 deep_color : source_color = vec4(0.12, 0.40, 0.68, 1.0);
uniform vec4 ocean_color : source_color = vec4(0.22, 0.56, 0.80, 1.0);
uniform vec4 lagoon_color : source_color = vec4(0.34, 0.72, 0.80, 1.0);
uniform vec4 shallows_color : source_color = vec4(0.50, 0.80, 0.76, 1.0);
uniform vec4 foam_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);

varying vec2 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(
		mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x),
		mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x),
		u.y
	);
}

float fbm(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	mat2 rot = mat2(vec2(0.8, -0.6), vec2(0.6, 0.8));
	for (int i = 0; i < 3; i++) {
		v += a * value_noise(p);
		p = rot * p * 2.1;
		a *= 0.5;
	}
	return v;
}

float fbm1(vec2 p) {
	return value_noise(p);
}

float lut_radius(float theta) {
	float u = fract(theta / TAU);
	return max(texture(radius_lut, vec2(u, 0.5)).r, 0.45) * island_radius;
}

void fragment() {
	vec3 base;

	if (open_ocean) {
		float shore_d = 1e6;
		if (water_quality <= 0) {
			// Cheap: pure radial distance — no per-island fbm in the hot loop.
			for (int i = 0; i < island_count; i++) {
				vec2 delta = world_pos - island_centers[i];
				shore_d = min(shore_d, length(delta) - island_radii[i]);
			}
		} else {
			for (int i = 0; i < island_count; i++) {
				vec2 delta = world_pos - island_centers[i];
				float radial = length(delta) - island_radii[i];
				float warp = (fbm(delta * 0.012 + vec2(float(i) * 17.0, 3.1)) - 0.5) * 90.0;
				float bars = max(fbm(delta * 0.018 + vec2(9.0, float(i) * 5.0)) - 0.55, 0.0) * 110.0;
				shore_d = min(shore_d, radial + warp - bars);
			}
		}
		shore_d = max(shore_d, 0.0);
		float prox = 1.0 - smoothstep(0.0, 520.0, shore_d);

		float d = mix(240.0, 48.0, prox);
		if (water_quality <= 0) {
			d += (fbm1(world_pos * 0.005) - 0.5) * 10.0;
		} else {
			d += (fbm(world_pos * 0.005) - 0.5) * 12.0;
		}

		base = shallows_color.rgb;
		base = mix(base, lagoon_color.rgb, smoothstep(18.0, 65.0, d));
		base = mix(base, ocean_color.rgb, smoothstep(55.0, 130.0, d));
		base = mix(base, deep_color.rgb, smoothstep(120.0, 250.0, d));

		if (water_quality <= 0) {
			// One cheap ripple tap + light foam — keeps motion without Retina melt.
			float r1 = fbm1(world_pos * 0.018 + vec2(TIME * 0.22, TIME * 0.11));
			base *= 1.0 + (r1 - 0.5) * 0.06;
			float foam_band = (1.0 - smoothstep(1.0, 14.0, shore_d)) * smoothstep(0.4, 3.0, shore_d);
			base = mix(base, foam_color.rgb, clamp(foam_band * 0.28, 0.0, 1.0));
		} else {
			vec2 uv = world_pos * 0.018;
			vec2 flow_a = vec2(TIME * 0.22, TIME * 0.11);
			vec2 flow_b = vec2(TIME * -0.14, TIME * 0.19);
			vec2 warp2 = vec2(
				fbm(uv * 0.7 + flow_a * 0.5),
				fbm(uv * 0.7 + flow_b * 0.5 + vec2(3.1, 1.7))
			);
			float r1 = fbm(uv + warp2 * 1.4 + flow_a);
			float r2 = fbm(uv * 1.7 - warp2 * 1.1 + flow_b + vec2(5.2, 9.4));
			float chop = (r1 - 0.5) * 0.7 + (r2 - 0.5) * 0.45;
			base *= 1.0 + chop * 0.07;

			float glint = pow(max(r1 * r2, 0.0), 10.0);
			base += glint * 0.18;

			float foam_band = (1.0 - smoothstep(1.0, 14.0, shore_d)) * smoothstep(0.4, 3.0, shore_d);
			float foam_break = smoothstep(0.4, 0.75, fbm(world_pos * 0.05 + flow_a * 2.0));
			float foam = foam_band * foam_break * (0.55 + 0.45 * sin(TIME * 1.6 + shore_d * 0.2));
			base = mix(base, foam_color.rgb, clamp(foam * 0.42, 0.0, 1.0));
		}
	} else {
		vec2 delta = world_pos - island_center;
		float dist = length(delta);
		float theta = atan(delta.y, delta.x);
		float shore_r = lut_radius(theta);
		float d = dist - shore_r;

		base = shallows_color.rgb;
		base = mix(base, lagoon_color.rgb, smoothstep(4.0, 26.0, d));
		base = mix(base, ocean_color.rgb, smoothstep(28.0, 105.0, d));
		base = mix(base, deep_color.rgb, smoothstep(115.0, 340.0, d));

		float over_sand = (1.0 - smoothstep(0.0, 14.0, d)) * step(0.0, d);
		base = mix(base, vec3(0.58, 0.68, 0.48), over_sand * 0.35);

		float blot = fbm(world_pos * 0.0035 + TIME * 0.008) - 0.5;
		base *= 1.0 + blot * 0.045 * smoothstep(50.0, 100.0, d);

		float cn = fbm(vec2(theta * 2.0, TIME * 0.15)) * 6.0;
		float swell = sin((d + cn) * 0.04 - TIME * 1.0);
		base += swell * 0.02 * smoothstep(20.0, 50.0, d) * (1.0 - smoothstep(120.0, 180.0, d));

		float pulse = 0.5 + 0.5 * sin(TIME * 2.2 + theta * 3.0);
		float foam = (1.0 - smoothstep(1.5, 10.0 + pulse * 3.5, d)) * smoothstep(0.5, 2.5, d);
		float patches = smoothstep(0.25, 0.7, fbm(vec2(theta * 6.0, TIME * 0.4)));
		foam *= mix(0.3, 1.0, patches) * (0.55 + 0.45 * pulse);
		base = mix(base, foam_color.rgb, clamp(foam, 0.0, 1.0));

		float under = 1.0 - smoothstep(-2.0, 1.0, d);
		base = mix(base, shallows_color.rgb * 0.9, under);
	}

	float ign = fract(52.9829189 * fract(dot(floor(world_pos), vec2(0.06711056, 0.00583715))));
	base += (ign - 0.5) * (1.5 / 255.0);

	COLOR = vec4(clamp(base, vec3(0.0), vec3(1.0)), 1.0);
}
