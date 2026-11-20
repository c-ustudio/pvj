shader_type canvas_item;
// SOLARIZE — tone inversion, whole-frame or gated by brightness.
//
// A PURE FRAGMENT SHADER: one texture fetch, no history buffer, no extra pass.
// It costs what RGB Shift costs, unlike Trails (a feedback target) or Slit-Scan
// (a ping-ponged atlas). Nothing here needs ShaderSlot to allocate anything.
//
// THE MODULATED control is `intensity`, 0..1 — the contract every effect shares.
// `mode` and `threshold` are the CHARACTER controls.
//
// TWO MODES:
//
//   INVERT (0)   — 1.0 - rgb across the whole frame. intensity CROSS-FADES to
//     it, so partial values are a real look (a half-inverted wash), not just a
//     dimmer version of the full effect.
//   SOLARIZE (1) — the Sabattier flip: tones ABOVE `threshold` invert, tones
//     below stay. intensity scales how far the flip is taken.
//
// ⚠️ THE CROSSOVER IS SMOOTHSTEPPED, NOT A HARD STEP, AND THAT IS AN ARTEFACT
// FIX RATHER THAN A TASTE CALL. A binary luma gate makes neighbouring pixels
// either side of the threshold land a full inversion apart — on moving video
// that boundary crawls and shimmers along edges, and on a projector it reads as
// noise rather than as a tone break. A narrow band keeps the break hard enough
// to look like a print while giving the gradient somewhere to go, which is also
// where the metallic sheen actually lives: near threshold the inverted and
// original values are close together, so the two sides meet in compressed
// mid-tones instead of tearing.
//
// Note that around threshold 0.5 the effect is naturally at its gentlest — a
// pixel at luma 0.5 inverts to 0.5, i.e. to itself — and gets harsher as the
// threshold moves toward either end. That is the character of the control, not
// a dead zone: the slider does most of its visible work away from the middle.

uniform float intensity : hint_range(0.0, 1.0) = 1.0;
// 0 INVERT (whole frame) · 1 SOLARIZE (only above the threshold).
uniform int mode = 0;
// Luma at which the flip happens. Ignored in INVERT — the GDScript side hides
// the slider there rather than leaving a control that does nothing.
uniform float threshold : hint_range(0.0, 1.0) = 0.5;

// Rec.709, matching how the footage was graded. A flat average would make
// saturated reds and blues cross the threshold at the wrong point and the flip
// would land on the wrong parts of the picture.
const vec3 LUMA = vec3(0.2126, 0.7152, 0.0722);
// Half-width of the crossover band, in luma. Narrow enough to still read as a
// hard tone break; wide enough to stop the boundary crawling — see above.
const float CROSSOVER = 0.06;

void fragment() {
	// ⚠️ ONE EXIT, NO EARLY `return` — Godot REJECTS `return` in fragment() and
	// the whole shader then fails to compile SILENTLY, falling back to drawing
	// the texture unchanged. That looks exactly like a working deck with a dead
	// effect and it cost a full session on slit-scan. Keep the single exit.
	vec4 cur = texture(TEXTURE, UV);
	float g = clamp(intensity, 0.0, 1.0);
	vec3 inv = 1.0 - cur.rgb;

	// Uniform-valued branch — every fragment takes the same side.
	vec3 target = inv;
	if (mode == 1) {
		float l = dot(cur.rgb, LUMA);
		float k = smoothstep(threshold - CROSSOVER, threshold + CROSSOVER, l);
		target = mix(cur.rgb, inv, k);
	}

	// ⚠️ PASSTHROUGH AT 0 HOLDS BY CONSTRUCTION IN BOTH MODES, not by a guard
	// that could drift from the slider: mix(cur, anything, 0) == cur. Both modes
	// funnel through this one line for exactly that reason.
	COLOR = vec4(mix(cur.rgb, target, g), cur.a);
}
