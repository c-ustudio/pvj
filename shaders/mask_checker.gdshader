shader_type canvas_item;
// The mask editor's CHECKER: a black/white board drawn in a region's WARP
// PARAMETER space (UV 0..1 across the warp domain — RegionCompositor feeds an
// identity UV transform while it is on). The squares therefore bend exactly as
// the region's warp bends content: on the object, square cells with straight
// rows mean the warp's perspective is right; trapezoids or bowed rows mean it
// is not.
//
// No texture is sampled — the region's clip is ignored while the board shows.

uniform vec2 cells = vec2(8.0, 8.0);   // cells across x / y of the warp domain

void fragment() {
	vec2 c = floor(UV * cells);
	float k = mod(c.x + c.y, 2.0);
	// A green centre cross: where the warp's middle lands on the object, and
	// the two lines a keystone error bends first.
	vec2 d = abs(UV - vec2(0.5)) * cells;
	float cross = step(min(d.x, d.y), 0.06);
	vec3 col = mix(vec3(k * 0.92), vec3(0.0, 1.0, 0.255), cross);
	COLOR = vec4(col, 1.0);
}
