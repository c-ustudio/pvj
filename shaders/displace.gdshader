shader_type canvas_item;
// DISPLACE — warps the image through a flowing field. Two patterns: NOISE, an
// organic fold-and-melt, and RADIAL, concentric rings radiating from centre like
// a drop in water. Origin is frame centre; a movable origin is a later job.
//
// THE MODULATED control is `intensity`, 0..1 — the contract every effect shares.
// It scales the displacement AMPLITUDE and nothing else, so at 0 the sample lands
// on UV exactly and this is exact passthrough.
//
// `scale` and `speed` are CHARACTER controls: not modulated, set to taste.
//
// CHEAP BY CONSTRUCTION — the opposite end of the set from Bloom. ONE texture
// fetch per fragment (Bloom takes 17, Glitch 4); the cost is six sin() calls in
// ALU, which mobile GPUs eat for breakfast and which does not touch memory
// bandwidth at all. Nothing here scales with `scale` or `speed` either: those
// change the field's shape, not the work done to evaluate it.

uniform float intensity : hint_range(0.0, 1.0) = 1.0;
// pattern 0 NOISE  : the two-stage domain warp — organic fold and melt.
// pattern 1 RADIAL : concentric rings radiating from frame centre, drop-in-water.
// Both read `scale` and `speed`, which is why they stay one effect rather than
// two: the controls mean the analogous thing in each.
uniform int pattern = 0;
// NOISE  — feature size: cycles of the field across the frame (low = broad
//          swells, high = fine ripple).
// RADIAL — ring spacing, in rings per half-frame-width. Same direction of
//          travel: higher is tighter.
uniform float scale : hint_range(0.5, 12.0) = 3.0;
// NOISE  — flow rate.
// RADIAL — radiation rate, how fast rings travel outward.
// 0.0 FREEZES either field: the image stays displaced but stops moving, which is
// a usable look rather than a disabled state.
uniform float speed : hint_range(0.0, 3.0) = 1.0;

// Peak displacement at intensity 1, as a fraction of frame width (~4%). Past
// this the warp stops reading as flow and starts reading as a broken lens.
const float MAX_AMP = 0.04;

void fragment() {
	float g = clamp(intensity, 0.0, 1.0);
	float t = TIME * speed;
	vec2 off;

	// Uniform-valued branch: every fragment takes the same side, so this costs
	// nothing in divergence and the unused mode's ALU is never issued.
	if (pattern == 1) {
		// RADIAL — displacement runs ALONG the radius, so crests move the image
		// toward and away from centre. Offsetting in a fixed direction instead
		// would slide the picture rather than ripple it.
		//
		// Distance is measured in WIDTH-normalized space (y scaled by 9/16), or
		// the "circles" come out as ellipses on a 16:9 frame; the offset is
		// converted back to UV on the way out (y by 16/9).
		vec2 d = UV - vec2(0.5);
		vec2 dw = vec2(d.x, d.y * (9.0 / 16.0));
		float r = length(dw);
		vec2 dir = dw / max(r, 1e-4);
		float wave = sin(r * scale * TAU - t * TAU);
		// Fade the innermost pixels out: at r=0 the radial direction is
		// undefined, and without this the centre pixel jitters on its own.
		wave *= smoothstep(0.0, 0.03, r);
		off = vec2(dir.x, dir.y * (16.0 / 9.0)) * wave * MAX_AMP * g;
	} else {
		// NOISE — unchanged.
		vec2 p = UV * scale;
		// Two-stage domain warp: the second pair of waves is BENT BY THE FIRST
		// (n1 feeds into n2's coordinates). That feedback is what turns a plain
		// sin ripple — which reads as a regular corrugation and gives the trick
		// away — into something that folds and melts.
		float n1 = sin(p.x * 1.7 + t) + sin(p.y * 1.3 - t * 0.8);
		float n2 = sin((p.x + n1) * 1.1 - t * 0.6) + sin((p.y - n1) * 0.9 + t * 0.7);

		// n1/n2 span +/-2, so the halved amplitude lands the peak on MAX_AMP.
		// The y term is aspect-corrected: UV is normalized, so without it the
		// same number moves a pixel further vertically and the flow comes out
		// anisotropic.
		off = vec2(n2, n1 * (16.0 / 9.0)) * (MAX_AMP * 0.5) * g;
	}

	// Clamped, not wrapped: a ViewportTexture can repeat, and at the frame edge
	// a wrap drags the opposite side of the picture into shot.
	COLOR = texture(TEXTURE, clamp(UV + off, vec2(0.0), vec2(1.0)));
}
