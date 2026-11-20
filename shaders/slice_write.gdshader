shader_type canvas_item;
// SLICE WRITER — rebuilds the whole slice-ring atlas each frame: ONE band taken
// from the live input, every other band copied forward from the previous atlas.
//
// ⚠️ THIS CARRIES THE OLD BANDS FORWARD EXPLICITLY BECAUSE RETENTION DID NOT
// WORK. The first version wrote only the head band and `discard`ed the rest,
// relying on a CLEAR_MODE_NEVER target to keep the others. On the Pixel 8
// (Mali G715, GL Compatibility) that atlas came back BLACK everywhere the effect
// sampled it — measured as 25-33% of the frame black against 0% for effect Off,
// including the band written that very frame. Tile-based renderers do not owe us
// a preserved target, and this one does not deliver it. Copying costs a
// full-frame read+write per frame — the same order as the feedback history that
// already runs here at 60 fps — and depends on nothing driver-specific.
//
// ⚠️ THE TWO ATLASES ARE PING-PONGED AND THAT IS WHAT KEEPS IT SAFE. This pass
// renders into one target while sampling the OTHER, so it never reads the
// surface it is writing — the hazard that is undefined on these GPUs. ShaderSlot
// alternates them and points the effect at whichever was just written.
//
// Samples the slot's INPUT (the live clip), never the slot's own output, so the
// atlas is a history of real frames rather than a feedback loop.

// How many strips the frame is cut into. Also the DEPTH in frames, because the
// head advances exactly one band per frame — see slit_scan.gdshader.
uniform int bands = 32;
// Which strip the head is on this frame; this one is taken from the live input.
uniform int band_index = 0;
// 0 horizontal strips (banded down UV.y) · 1 vertical strips (across UV.x).
uniform int axis = 0;
// The other atlas — last frame's version of this one. hint_default_black so an
// unbound first frame reads black rather than white.
uniform sampler2D prev_atlas : hint_default_black, filter_nearest;
// One-shot full-frame fill from the live input, so the atlas starts as a real
// picture instead of whatever the freshly-allocated target contains. Set on
// enable and on any `bands` change, which repartitions every strip boundary.
uniform bool prime = false;

void fragment() {
	float c = (axis == 1) ? UV.x : UV.y;
	// clamp below 1.0 so the last texel cannot round up to an out-of-range band.
	int b = int(clamp(c, 0.0, 0.999) * float(bands));
	// Single exit, no early `return` — Godot rejects it in fragment() and the
	// whole shader then fails to compile silently.
	vec4 outc = texture(prev_atlas, UV);
	if (prime || b == band_index) {
		outc = texture(TEXTURE, UV);
	}
	COLOR = outc;
}
