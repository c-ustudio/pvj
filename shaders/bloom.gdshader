shader_type canvas_item;
// BLOOM — bright areas bleed and halo out.
//
// THE MODULATED control is `intensity`, 0..1 — the contract every effect shares.
// pipeline.gd's _process drives it from the audio level (or the fader while it's
// grabbed). It scales how much glow is ADDED, and nothing else: at 0 the shader
// returns the base sample at UV untouched (the tap loop is skipped outright),
// which is exact passthrough, not nearly-clean.
//
// `threshold` and `radius` are CHARACTER controls: not modulated, set to taste.
// Neither can produce glow at intensity 0 — the added term is scaled by it.
//
// ⚠️ SINGLE PASS, so this is the expensive effect in the set. Real bloom
// downsamples and blurs over several passes; ShaderSlot gives one fragment
// shader over one material, so the blur is TAPS samples of the source per
// fragment instead — 17 texture fetches where Glitch takes 4. The disc is
// sampled on a golden-angle spiral (even coverage per tap, no visible ring
// structure) with a per-pixel rotation to break up what banding is left. If a
// venue's projector needs the headroom back, the shader-stage HALF/FAST quality
// setting cuts this cost quadratically — it is the intended escape hatch.

uniform float intensity : hint_range(0.0, 1.0) = 1.0;
// How bright a pixel must be before it blooms, on luma. Soft-kneed by KNEE so
// the glow fades in over a range instead of switching on at an edge and
// crawling as the footage moves.
uniform float threshold : hint_range(0.0, 1.0) = 0.6;
// How far the glow bleeds, as a percent of frame WIDTH (matching Glitch's
// block_size unit). Corrected for aspect below so the halo is round, not oval.
uniform float radius : hint_range(0.5, 10.0) = 2.5;

const int TAPS = 16;
const float GOLDEN = 2.39996323;   // golden angle, radians
const float KNEE = 0.18;           // soft-knee width above threshold
const float GAIN = 1.7;            // glow strength at intensity 1
const float FALLOFF = 0.75;        // how much the outer taps are weighted down

float h21(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

void fragment() {
	float g = clamp(intensity, 0.0, 1.0);
	vec4 base = texture(TEXTURE, UV);
	vec3 col = base.rgb;

	// Uniform-valued condition: every fragment takes the same branch, so this is
	// a real saving at intensity 0 rather than divergence.
	if (g > 0.002) {
		float r_uv = radius * 0.01;
		// UV is normalized, so a round halo needs the vertical offset scaled by
		// the frame aspect — without this the glow is a squashed ellipse.
		vec2 asp = vec2(1.0, 16.0 / 9.0);
		float rot = h21(UV) * 6.2831853;

		vec3 sum = vec3(0.0);
		float wsum = 0.0;
		for (int i = 0; i < TAPS; i++) {
			float fi = float(i) + 0.5;
			// sqrt() spaces the spiral evenly over the DISC; without it the taps
			// bunch at the centre and the outer halo goes ragged.
			float rr = sqrt(fi / float(TAPS));
			float a = fi * GOLDEN + rot;
			vec2 off = vec2(cos(a), sin(a)) * rr * r_uv * asp;
			// Clamped, not wrapped: a ViewportTexture can repeat, and a halo that
			// wraps pulls the opposite edge of the frame into shot.
			vec3 s = texture(TEXTURE, clamp(UV + off, vec2(0.0), vec2(1.0))).rgb;
			float lum = dot(s, vec3(0.2126, 0.7152, 0.0722));
			float fall = 1.0 - rr * FALLOFF;
			// Only the part ABOVE the threshold blooms; wsum takes the geometric
			// weight alone, so a frame with few bright pixels glows a little and
			// one that is all highlights glows a lot.
			sum += s * smoothstep(threshold, threshold + KNEE, lum) * fall;
			wsum += fall;
		}
		col += (sum / max(wsum, 0.0001)) * g * GAIN;
	}

	COLOR = vec4(col, base.a);
}
