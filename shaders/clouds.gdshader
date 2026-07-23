shader_type canvas_item;
render_mode blend_mix, unshaded;

/// Sparse drifting cloud wisps (or soft shadows when shadow_mode is on).

uniform bool shadow_mode = false;
uniform float coverage = 0.52;
uniform float softness = 0.16;
uniform float opacity = 0.5;
uniform float scroll_speed = 0.016;
uniform vec2 scroll_dir = vec2(1.0, 0.35);
uniform float scale = 0.0022;
uniform float noise_offset = 0.0;

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
	float a = hash(i);
	float b = hash(i + vec2(1.0, 0.0));
	float c = hash(i + vec2(0.0, 1.0));
	float d = hash(i + vec2(1.0, 1.0));
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float fbm(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 5; i++) {
		v += a * value_noise(p);
		p *= 2.1;
		a *= 0.5;
	}
	return v;
}

void fragment() {
	vec2 uv = world_pos * scale + scroll_dir * TIME * scroll_speed + vec2(noise_offset);
	float n = fbm(uv);
	float cloud = smoothstep(coverage, coverage + softness, n);
	cloud = max(cloud, smoothstep(coverage + 0.05, coverage + softness + 0.1, fbm(uv * 1.55 + 9.0)) * 0.7);

	if (shadow_mode) {
		COLOR = vec4(0.03, 0.05, 0.09, cloud * opacity * 0.85);
	} else {
		COLOR = vec4(0.98, 0.99, 1.0, cloud * opacity);
	}
}
