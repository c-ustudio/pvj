shader_type canvas_item;
// Animated chromatic aberration. Splits R/B radially from center and pulses.
// `intensity` is meant to be driven externally (audio) later; 1.0 = full.

uniform float intensity = 1.0;
uniform float amount : hint_range(0.0, 0.05) = 0.02;

void fragment() {
	vec2 dir = UV - vec2(0.5);
	float pulse = 0.5 + 0.5 * sin(TIME * 2.0);
	float off = amount * intensity * pulse;

	float r = texture(TEXTURE, UV + dir * off).r;
	vec4 g = texture(TEXTURE, UV);
	float b = texture(TEXTURE, UV - dir * off).b;

	COLOR = vec4(r, g.g, b, g.a);
}
