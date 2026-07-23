shader_type canvas_item;
render_mode blend_mix, unshaded;

/// Clean beach ocean: depth + foam only. No surface stripe noise.

uniform vec2 island_center = vec2(360.0, 640.0);
uniform float island_radius = 300.0;
uniform sampler2D radius_lut : filter_linear, repeat_enable;

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

float lut_radius(float theta) {
	float u = fract(theta / TAU);
	return max(texture(radius_lut, vec2(u, 0.5)).r, 0.45) * island_radius;
}

void fragment() {
	vec2 delta = world_pos - island_center;
	float dist = length(delta);
	float theta = atan(delta.y, delta.x);
	float shore_r = lut_radius(theta);
	float d = dist - shore_r;

	vec3 base = shallows_color.rgb;
	base = mix(base, lagoon_color.rgb, smoothstep(4.0, 26.0, d));
	base = mix(base, ocean_color.rgb, smoothstep(28.0, 105.0, d));
	base = mix(base, deep_color.rgb, smoothstep(115.0, 340.0, d));

	float over_sand = (1.0 - smoothstep(0.0, 14.0, d)) * step(0.0, d);
	base = mix(base, vec3(0.58, 0.68, 0.48), over_sand * 0.35);

	// Very soft blotches — amplitude tiny, rotated fbm so no preferred axis.
	float blot = fbm(world_pos * 0.0035 + TIME * 0.008) - 0.5;
	base *= 1.0 + blot * 0.045 * smoothstep(50.0, 100.0, d);

	// Gentle shore swell (follows coast).
	float cn = fbm(vec2(theta * 2.0, TIME * 0.15)) * 6.0;
	float swell = sin((d + cn) * 0.04 - TIME * 1.0);
	base += swell * 0.02 * smoothstep(20.0, 50.0, d) * (1.0 - smoothstep(120.0, 180.0, d));

	// Surf foam.
	float pulse = 0.5 + 0.5 * sin(TIME * 2.2 + theta * 3.0);
	float foam = (1.0 - smoothstep(1.5, 10.0 + pulse * 3.5, d)) * smoothstep(0.5, 2.5, d);
	float patches = smoothstep(0.25, 0.7, fbm(vec2(theta * 6.0, TIME * 0.4)));
	foam *= mix(0.3, 1.0, patches) * (0.55 + 0.45 * pulse);
	base = mix(base, foam_color.rgb, clamp(foam, 0.0, 1.0));

	float under = 1.0 - smoothstep(-2.0, 1.0, d);
	base = mix(base, shallows_color.rgb * 0.9, under);

	// Tiny IGN to break flat gradient banding (invisible at normal viewing).
	float ign = fract(52.9829189 * fract(dot(floor(world_pos), vec2(0.06711056, 0.00583715))));
	base += (ign - 0.5) * (1.5 / 255.0);

	COLOR = vec4(clamp(base, vec3(0.0), vec3(1.0)), 1.0);
}
