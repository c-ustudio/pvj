shader_type canvas_item;
// Raster (image) alpha mask over the composited output.
//
// Drawn as the TOPMOST full-rect item in OutputWorld. Everything behind it sits
// on the viewport's black clear color, so multiplying the frame by the mask is
// exactly the same as blending BLACK over it with alpha = (1 - mask):
//   result = frame * (1 - a) + black * a  =  frame * mask
// That means no backbuffer read, no routing changes, and it composes with the
// polygon masks (they shape the content below; this multiplies over the result).
// ⚠️ Valid ONLY while the frame below sits on a black clear — dual-deck
// compositing (B over A) invalidates it; see MaskOverlay's docstring.
//
// The mask is greyscale: white = keep, black = masked out. A PNG alpha channel
// is honoured too (transparent = masked out), so Photoshop/AE mattes work as
// authored either way. Feathered edges in the image become soft edges on the
// wall — the whole point.

uniform sampler2D mask_tex : filter_linear_mipmap, repeat_disable;
uniform bool invert = false;
uniform float opacity : hint_range(0.0, 1.0) = 1.0;
// 0 = STRETCH (ignore aspect), 1 = FIT (whole mask visible, letterbox bands are
// masked out), 2 = FILL (cover the output, crop the mask overflow).
uniform int fit_mode = 0;

void fragment() {
	// Output px from the viewport we render into; mask px from the texture —
	// no size uniforms to keep in sync when HDMI renegotiates the output res.
	vec2 out_px = 1.0 / SCREEN_PIXEL_SIZE;
	vec2 mask_px = vec2(textureSize(mask_tex, 0));

	vec2 uv = UV;
	bool inside = true;
	if (fit_mode != 0) {
		vec2 ratio = out_px / mask_px;
		float s = (fit_mode == 1) ? min(ratio.x, ratio.y) : max(ratio.x, ratio.y);
		vec2 disp = mask_px * s;                       // mask's displayed size, output px
		uv = (UV * out_px - 0.5 * (out_px - disp)) / disp;
		inside = all(greaterThanEqual(uv, vec2(0.0))) && all(lessThanEqual(uv, vec2(1.0)));
	}

	float m = 0.0;                                     // outside the mask image = masked out
	if (inside) {
		vec4 c = texture(mask_tex, uv);
		m = dot(c.rgb, vec3(0.299, 0.587, 0.114)) * c.a;
	}
	if (invert) {
		m = 1.0 - m;
	}
	COLOR = vec4(0.0, 0.0, 0.0, (1.0 - m) * opacity);
}
