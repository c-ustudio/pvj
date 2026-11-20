shader_type canvas_item;
// SLIT-SCAN — TRUE multi-frame time-shear. The frame is cut into strips and each
// strip shows a DIFFERENT, GENUINELY OLDER FRAME, frozen: not a decayed echo of
// the present, an actual moment from the past held intact.
//
// THE MODULATED control is `intensity`, 0..1 — the contract every effect shares.
// `direction` and `span` are the CHARACTER controls.
//
// ── WHERE THE MULTI-FRAME HISTORY COMES FROM ─────────────────────────────
//
// A ring of band-slices — ONE frame-sized texture, written 1/bands of a frame
// per frame by slice_write.gdshader into a CLEAR_MODE_NEVER target. Strip b was
// last written (write_index - b) mod bands frames ago and holds strip b's OWN
// rows, at strip b's own position, so the atlas can be read straight out.
//
// ⚠️ THIS REPLACES THE FEEDBACK APPROXIMATION IN f7495b0 / 0cf23bd, WHICH WAS
// THE WRONG SHAPE FOR THE LOOK. That one re-emitted its own output per band at
// different refresh RATES; the ages sawtoothed, were never more than loosely
// related to each other, and it read as blocky glitch rather than a scan. Here
// the ages are exact, ordered, and span the full range at every instant.
//
// The earlier claim that a true time-shear costs span/2 WHOLE FRAMES of storage
// was wrong, and it is what wrongly killed this approach the first time. That
// figure only holds if every strip must sit at a FIXED age on every frame. The
// ring lets each strip's age cycle while the SET of ages on screen is always a
// full ordered ramp — which is what the look actually needs — for exactly one
// frame of storage.
//
// ⚠️ SPAN IS THE BAND COUNT AND THAT COUPLING IS DELIBERATE. The head advances
// one strip per frame, so the oldest strip is `bands` frames old: depth in
// frames and strip count are the same number. Deeper reach therefore means
// THINNER strips (1080/8 = 135 px at span 8, 1080/90 = 12 px at span 90), which
// is a real character change and not a defect. Decoupling them needs a
// fractional write stride and a writer that can fill several strips in one pass;
// deliberately not in v1.

uniform float intensity : hint_range(0.0, 1.0) = 1.0;
// 0 HORIZONTAL — strips across, time deepens DOWN the frame.
// 1 VERTICAL   — strips down, time deepens ACROSS the frame.
uniform int direction = 0;
// The slice-ring atlas. NEAREST so a strip boundary stays a hard edge: the two
// sides are different MOMENTS, and filtering across them would blend two times
// together into a seam. At 1:1 this costs nothing in image quality.
uniform sampler2D slices : hint_default_black, filter_nearest;
// Strip count == depth in frames. Pushed by ShaderSlot, which owns the ring.
uniform int bands = 32;
// Which strip the write head is on. Pushed by ShaderSlot every frame; this is
// what makes the age ramp rotate instead of sitting still.
uniform int write_index = 0;
// ⚠️ FALSE BY DEFAULT AND THAT DEFAULT IS THE GUARD. RegionCompositor builds its
// materials from the same effect array, has NO slice ring, and pushes ONLY
// `intensity` — every other uniform here sits at its shader default. With the
// flag false no strip can reach the atlas, so a masked region degrades to clean
// live passthrough instead of sampling an unbound (black) sampler and going
// dark. ShaderSlot sets it true where it binds `slices`.
uniform bool slices_bound = false;

void fragment() {
	// ⚠️ ONE EXIT, NO EARLY `return` — Godot rejects `return` in fragment() and
	// the WHOLE shader then fails to compile, silently, falling back to drawing
	// the texture unchanged. That cost a full session; the guard is an
	// else-branch and must stay one.
	vec4 cur = texture(TEXTURE, UV);
	vec4 outc = cur;

	if (slices_bound) {
		float c = (direction == 1) ? UV.x : UV.y;
		int b = int(clamp(c, 0.0, 0.999) * float(bands));

		// How many frames ago this strip was written. `+ bands` before the modulo
		// because GLSL's % is implementation-defined for negative operands.
		int age = (write_index - b + bands) % bands;
		float age_frac = float(age) / float(bands);      // 0 .. (bands-1)/bands

		// ⚠️ STRICTLY LESS THAN, AND THAT IS WHAT MAKES 0 EXACT PASSTHROUGH. At
		// intensity 0 no strip qualifies, so nothing samples the atlas and the
		// output is the live frame texel for texel — by construction, not by a
		// guard that could drift from the slider. At 1 every strip qualifies,
		// since the deepest age_frac is (bands-1)/bands < 1.
		//
		// Reaching deeper as intensity rises, rather than cross-fading between
		// live and sheared: a dissolve would read as ghosting, which is the
		// opposite of frozen bands. Here the strips behind the write head join
		// the shear one at a time and the picture stays crisp throughout.
		if (age_frac < clamp(intensity, 0.0, 1.0)) {
			outc = texture(slices, UV);
		}
	}

	COLOR = outc;
}
