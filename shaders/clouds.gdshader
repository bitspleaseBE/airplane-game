shader_type canvas_item;
render_mode blend_mix, unshaded;

/// Soft high-altitude cloud banks (or cast shadows on the ocean).
/// Drift + slow morph so shapes evolve like real weather.

uniform bool shadow_mode = false;
uniform float coverage = 0.42;
uniform float softness = 0.22;
uniform float opacity = 0.4;
uniform float scroll_speed = 0.008;
uniform vec2 scroll_dir = vec2(1.0, 0.35);
uniform float scale = 0.0028;
uniform float noise_offset = 0.0;
/// How fast cloud shapes billow / reshape (independent of drift).
uniform float morph_speed = 0.045;
/// World-space cast offset for shadows — larger = higher sun / more altitude cue.
uniform vec2 shadow_offset = vec2(48.0, 36.0);

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
		p *= 2.05;
		a *= 0.5;
	}
	return v;
}

float cloud_field(vec2 base_uv, float t) {
	// Time-evolving warp — banks stretch and merge instead of rigid scrolling.
	vec2 morph = vec2(t * 0.31, -t * 0.23);
	vec2 warp = vec2(
		fbm(base_uv * 0.8 + morph + vec2(1.7, 0.0)),
		fbm(base_uv * 0.8 - morph * 0.7 + vec2(5.3, 2.1))
	) - 0.5;
	vec2 cuv = base_uv + warp * (0.45 + 0.12 * sin(t * 0.7));

	float mass = fbm(cuv * 0.85 + morph * 0.35);
	float detail = fbm(cuv * 1.55 + morph * 0.9 + vec2(3.5, 1.2));
	float shape = mass * 0.76 + detail * 0.24;

	float cloud = smoothstep(coverage, coverage + softness, shape);
	float bank2 = smoothstep(
		coverage + 0.05,
		coverage + softness + 0.1,
		fbm(cuv * 1.2 - morph * 0.5 + vec2(8.0, 0.0))
	);
	return max(cloud, bank2 * 0.5);
}

void fragment() {
	vec2 sample_pos = world_pos;
	if (shadow_mode) {
		sample_pos -= shadow_offset;
	}

	float t = TIME * morph_speed;
	vec2 uv = sample_pos * scale + scroll_dir * TIME * scroll_speed + vec2(noise_offset);
	float cloud = cloud_field(uv, t);

	if (shadow_mode) {
		// Faint blue-dark patch on the water, far displaced from its cloud —
		// the gap between puff and shadow is the altitude cue.
		float shade = smoothstep(0.1, 0.9, cloud);
		COLOR = vec4(0.05, 0.15, 0.3, shade * opacity);
	} else {
		// Pure sunlit white: near-opaque cores, feathered edges.
		float core = smoothstep(0.3, 0.85, cloud);
		float alpha = clamp(cloud * 0.6 + core * 0.75, 0.0, 1.0) * opacity;
		COLOR = vec4(vec3(1.0), alpha);
	}
}
