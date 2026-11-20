shader_type canvas_item;
// Feedback / echo tunnel — accumulates several rotated + zoomed copies of the
// frame for an infinite-mirror "video feedback" look. Single-pass (no extra
// buffers), so it's a safe drop-in for the ShaderSlot effect cycle.
// `intensity` (audio-drivable) scales how far the echoes rotate + zoom in.

uniform float intensity = 1.0;
uniform int taps : hint_range(2, 12) = 8;
uniform float zoom : hint_range(0.0, 0.2) = 0.07;
uniform float rotation : hint_range(0.0, 0.4) = 0.06;
uniform float decay : hint_range(0.5, 0.98) = 0.82;

void fragment() {
	vec2 c = UV - vec2(0.5);
	vec4 acc = vec4(0.0);
	float wsum = 0.0;
	float w = 1.0;
	float ang = 0.0;
	float scl = 1.0;

	for (int i = 0; i < 12; i++) {
		if (i >= taps) break;
		float ca = cos(ang);
		float sa = sin(ang);
		vec2 p = mat2(vec2(ca, -sa), vec2(sa, ca)) * c * scl + vec2(0.5);
		acc += texture(TEXTURE, clamp(p, vec2(0.0), vec2(1.0))) * w;
		wsum += w;

		w *= decay;
		ang += rotation * intensity;
		scl *= (1.0 - zoom * intensity);
	}

	COLOR = acc / max(wsum, 0.001);
}
