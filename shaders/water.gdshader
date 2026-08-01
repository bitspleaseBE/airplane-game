shader_type canvas_item;
render_mode blend_mix, unshaded;

/// Open ocean with optional single-island foam LUT (legacy).
/// When open_ocean is true, only depth/variation — shores are baked into island sprites.
///
/// Noise comes from one baked seamless 4-octave fBm tile
/// (assets/textures/water_noise.png, see tools/gen_water_noise.py) rather than
/// `fract(sin(dot(...)))`. The old hash cost 4 sines per lattice corner — 12 per
/// fBm, ~800 per pixel with the island loop — and lost precision at campaign-scale
/// world coordinates, so the field differed per GPU and shimmered on mobile.
/// One filtered fetch replaces each fBm call, which buys the headroom for the
/// refracted swell and surge-driven surf below.
///
/// The island arrays are view-culled by Main._apply_open_ocean: only coasts whose
/// influence reaches the screen are uploaded, so this loop runs a couple of times
/// instead of once per island in the campaign.

uniform bool open_ocean = true;
uniform vec2 island_center = vec2(360.0, 640.0);
uniform float island_radius = 300.0;
uniform sampler2D radius_lut : filter_linear, repeat_enable;

/// Coasts near the view. Water lightens toward any shore and deepens offshore.
/// Sized for the worst realistic on-screen count — Main caps the upload to match.
const int MAX_ISLANDS = 12;
uniform int island_count = 0;
uniform vec2 island_centers[MAX_ISLANDS];
uniform float island_radii[MAX_ISLANDS];

uniform vec4 deep_color : source_color = vec4(0.12, 0.40, 0.68, 1.0);
uniform vec4 ocean_color : source_color = vec4(0.22, 0.56, 0.80, 1.0);
uniform vec4 lagoon_color : source_color = vec4(0.34, 0.72, 0.80, 1.0);
uniform vec4 shallows_color : source_color = vec4(0.50, 0.80, 0.76, 1.0);
uniform vec4 foam_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);

/// Baked fBm. Linear-filtered and repeating; one tile is 16 lattice units.
uniform sampler2D noise_tex : filter_linear, repeat_enable;

/// Master gain on the wave-crest shading. 0 = flat depth ramp only.
uniform float swell_strength = 1.0;

/// One base-octave cell per unit of the sampling coordinate — matches the old
/// integer-lattice value noise, so every tuning constant below carries over.
const float NOISE_BASE_UV = 0.0625;
/// The old fBm summed three octaves at 1/2 + 1/4 + 1/8, so it topped out here
/// rather than at 1.0. The bake stores the field rescaled into the full 8-bit
/// range; undoing that restores the distribution the constants are tuned to.
const float NOISE_PEAK = 0.875;

varying vec2 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

/// Normalised 0..1 fBm — one fetch. Prefer this for new terms; it is easier to
/// reason about than the old skewed range.
float fbmn(vec2 p) {
	return texture(noise_tex, p * NOISE_BASE_UV).r;
}

/// Drop-in for the old 3-octave fBm: same input scale, same 0..0.875 range.
float fbm(vec2 p) {
	return fbmn(p) * NOISE_PEAK;
}

/// fBm with features stretched along `aniso` — used for glitter paths, which run
/// with the sun azimuth rather than sitting as round dots.
float fbmn_aniso(vec2 p, vec2 aniso) {
	return texture(noise_tex, p * aniso * NOISE_BASE_UV).r;
}

float lut_radius(float theta) {
	float u = fract(theta / TAU);
	return max(texture(radius_lut, vec2(u, 0.5)).r, 0.45) * island_radius;
}

void fragment() {
	vec3 base;

	if (open_ocean) {
		// Top-down sea: depth from the nearest shore, drifting surface chop, and
		// swell that shoals into the coast.
		float shore_d = 1e6;
		for (int i = 0; i < island_count; i++) {
			vec2 delta = world_pos - island_centers[i];
			float radial = length(delta) - island_radii[i];
			float warp = (fbm(delta * 0.012 + vec2(float(i) * 17.0, 3.1)) - 0.5) * 90.0;
			float bars = max(fbm(delta * 0.018 + vec2(9.0, float(i) * 5.0)) - 0.55, 0.0) * 110.0;
			shore_d = min(shore_d, radial + warp - bars);
		}
		shore_d = max(shore_d, 0.0);
		float prox = 1.0 - smoothstep(0.0, 520.0, shore_d);

		float depth = mix(240.0, 48.0, prox);
		depth += (fbm(world_pos * 0.005) - 0.5) * 12.0;

		base = shallows_color.rgb;
		base = mix(base, lagoon_color.rgb, smoothstep(18.0, 65.0, depth));
		base = mix(base, ocean_color.rgb, smoothstep(55.0, 130.0, depth));
		base = mix(base, deep_color.rgb, smoothstep(120.0, 250.0, depth));

		// Domain-warped ripple chop — soft surface texture from above. Two
		// counter-drifting layers warp each other so crests merge and split
		// instead of sliding past as a rigid pattern.
		vec2 uv = world_pos * 0.011;
		vec2 flow_a = vec2(TIME * 0.16, TIME * 0.08);
		vec2 flow_b = vec2(TIME * -0.10, TIME * 0.14);
		vec2 warp2 = vec2(
			fbmn(uv * 0.7 + flow_a * 0.5),
			fbmn(uv * 0.7 + flow_b * 0.5 + vec2(3.1, 1.7))
		);
		float r1n = fbmn(uv + warp2 * 1.4 + flow_a);
		float r2n = fbmn(uv * 1.7 - warp2 * 1.1 + flow_b + vec2(5.2, 9.4));
		float chop = (r1n * NOISE_PEAK - 0.5) * 0.7 + (r2n * NOISE_PEAK - 0.5) * 0.45;

		// Swell steepens as it shoals, so crest shading rises toward the coast and
		// dies out entirely in deep water — where the drifting chop above is the
		// whole surface, exactly as before. Phasing the crests on shore distance
		// is what refraction does physically, and from above it reads as swell
		// wrapping the island. Deliberately no travelling open-water component:
		// straight crest trains across open sea look like smoke bands top-down.
		float shoal = 1.0 - smoothstep(0.0, 470.0, shore_d);
		float swell = sin(shore_d * -0.055 + TIME * 1.15 + chop * 2.6);
		// Round the crests and sharpen the troughs — real swell isn't a sine.
		swell = swell * 0.62 + 0.38 * swell * abs(swell);
		base *= 1.0 + swell * (shoal * shoal * 0.115 * swell_strength) + chop * 0.075;

		// Sun glitter on the crest faces. Sampled anisotropically so highlights
		// read as glitter paths along the sun azimuth instead of round dots, and
		// gated on the crest so the sparkle rides in with the waves.
		float crest = smoothstep(0.1, 0.9, swell);
		float paths = fbmn_aniso(uv * 2.4 + flow_a * 3.0, vec2(1.0, 0.3));
		float glint = smoothstep(0.55, 0.95, r1n * r2n * 2.0) * smoothstep(0.42, 0.88, paths);
		base += glint * (0.10 + 0.14 * crest);

		// Caustic shimmer: light bouncing off a bed close enough to see. Reuses
		// the ripple layers, so it costs no extra samples.
		base += smoothstep(0.86, 1.3, r1n + r2n) * shoal * 0.03;

		// Nearshore wash. Deliberately soft and edgeless: island_radii is the
		// island's *circumscribing* radius, so shore_d only marks the true coast
		// on near-round islands — on an arm or crescent the contour can sit
		// hundreds of units out to sea. Anything with a hard edge here (the old
		// foam lace, or a surf line) therefore reads as a white halo detached
		// from the beach. Real coastal foam is baked into the island sprite
		// against the actual coastline; this only brightens the shallows so the
		// sprite's shelf blends out into open water.
		if (shore_d < 90.0) {
			float breakup = smoothstep(0.30, 0.70, fbmn(world_pos * 0.05 + flow_a * 2.0));
			float wash = 1.0 - smoothstep(0.0, 62.0 + swell * 18.0, shore_d);
			base = mix(base, foam_color.rgb, wash * wash * mix(0.06, 0.17, breakup));
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
