shader_type canvas_item;
// Radial kaleidoscope: mirrors the image into N wedges and slowly rotates.
// `intensity` scales the rotation speed (audio-drivable later).

uniform float intensity = 1.0;
uniform float segments : hint_range(2.0, 24.0) = 6.0;

void fragment() {
	vec2 p = UV - vec2(0.5);
	float radius = length(p);
	float angle = atan(p.y, p.x);

	float seg = TAU / segments;
	angle = abs(mod(angle, seg) - seg * 0.5);   // mirror within each wedge
	angle += TIME * 0.15 * intensity;            // slow rotation

	vec2 uv = vec2(cos(angle), sin(angle)) * radius + vec2(0.5);
	uv = clamp(uv, vec2(0.0), vec2(1.0));

	COLOR = texture(TEXTURE, uv);
}
