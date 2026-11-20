shader_type canvas_item;
// Chromatic aberration — horizontal RGB split with a little vertical jitter for
// a glitchy lens look. Distinct from rgb_shift.gdshader (which is radial + a
// time pulse); this one is directional and driven straight by `intensity`
// (audio-drivable) so it snaps harder on transients.

uniform float intensity = 1.0;
uniform float amount : hint_range(0.0, 0.08) = 0.025;
uniform float jitter : hint_range(0.0, 0.02) = 0.004;

void fragment() {
	float d = amount * intensity;
	vec2 jx = vec2(0.0, jitter * intensity * sin(UV.y * 140.0 + TIME * 6.0));

	float r = texture(TEXTURE, UV + vec2(d, 0.0) + jx).r;
	float g = texture(TEXTURE, UV).g;
	float b = texture(TEXTURE, UV - vec2(d, 0.0) - jx).b;
	float a = texture(TEXTURE, UV).a;

	COLOR = vec4(r, g, b, a);
}
