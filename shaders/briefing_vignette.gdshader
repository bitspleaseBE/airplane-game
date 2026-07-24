shader_type canvas_item;
render_mode unshaded;

/// Warm dusk vignette — amber rim, soft open center so the island stays readable.
uniform vec4 center_color : source_color = vec4(0.16, 0.10, 0.05, 0.08);
uniform vec4 edge_color : source_color = vec4(0.07, 0.04, 0.02, 0.78);
uniform vec4 glow_color : source_color = vec4(0.95, 0.72, 0.28, 0.18);
uniform float radius : hint_range(0.2, 1.2) = 0.55;
uniform float softness : hint_range(0.1, 1.0) = 0.55;
uniform float glow_band : hint_range(0.0, 0.4) = 0.14;
uniform float pulse : hint_range(0.0, 1.0) = 0.0;

void fragment() {
	vec2 uv = UV - vec2(0.5);
	uv.y *= 1.12;
	float d = length(uv);
	float veil = smoothstep(radius - softness, radius + softness * 0.35, d);
	vec4 base = mix(center_color, edge_color, veil);

	float glow = 1.0 - smoothstep(radius - glow_band, radius + glow_band * 0.6, abs(d - radius * 0.92));
	glow *= 0.55 + 0.45 * pulse;
	base.rgb = mix(base.rgb, glow_color.rgb, glow * glow_color.a);
	base.a = max(base.a, glow * glow_color.a * 0.65);

	COLOR = base;
}
