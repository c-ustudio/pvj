shader_type canvas_item;
// Pixelate — quantizes UV to a block grid. `intensity` (audio-drivable) makes
// the blocks chunkier as it rises, so it pulses with the beat.

uniform float intensity = 1.0;
uniform float fine_blocks : hint_range(16.0, 320.0) = 200.0;   // at intensity 0
uniform float coarse_blocks : hint_range(4.0, 64.0) = 16.0;    // at intensity 1+

void fragment() {
	float t = clamp(intensity, 0.0, 1.0);
	float blocks = mix(fine_blocks, coarse_blocks, t);
	// Correct for aspect so blocks stay square-ish on a 16:9 frame.
	vec2 grid = vec2(blocks, blocks * 9.0 / 16.0);
	vec2 uv = (floor(UV * grid) + 0.5) / grid;
	COLOR = texture(TEXTURE, uv);
}
