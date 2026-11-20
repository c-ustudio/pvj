shader_type canvas_item;
// Camera YCbCr → RGB conversion (Stage 0 for the live-camera source).
//
// Android's CameraServer delivers the rear-camera frame as a SEPARATED YCbCr
// pair (CameraFeed datatype FEED_YCBCR_SEP): a full-res luma (Y) plane and a
// half-res chroma (CbCr) plane. CameraEngine wires the Y plane in as this
// TextureRect's own TEXTURE and the CbCr plane in via the `cbcr_tex` uniform,
// then renders the converted RGB into its SubViewport. Downstream the ShaderSlot
// sees a normal RGB frame, so every existing effect shader works unchanged.
//
// Conversion is BT.601 video-range-ish full-swing (matches the Android camera
// stack). Each plane is sampled with its own normalized UV, so the half-res
// chroma plane lines up with the full-res luma automatically.

uniform sampler2D cbcr_tex : source_color, hint_default_black;

void fragment() {
	float y = texture(TEXTURE, UV).r;
	vec2 cbcr = texture(cbcr_tex, UV).rg - vec2(0.5);

	vec3 rgb;
	rgb.r = y + 1.402 * cbcr.y;
	rgb.g = y - 0.344136 * cbcr.x - 0.714136 * cbcr.y;
	rgb.b = y + 1.772 * cbcr.x;

	COLOR = vec4(clamp(rgb, vec3(0.0), vec3(1.0)), 1.0);
}
