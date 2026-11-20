shader_type canvas_item;
// TRAILS — motion leaves a phosphor echo. The first FRAME-BUFFER effect: it
// blends the live frame with the previous output, so the trail is genuinely
// recursive rather than several copies of the current frame (which is what the
// older Feedback effect does, and why that one cannot smear over time).
//
// THE MODULATED control is `intensity`, 0..1 — the contract every effect shares.
// It scales the history term, so at 0 the max() collapses to the live frame and
// this is exact passthrough with no trail at all.
//
// `decay` is the CHARACTER control: persistence, short smear → long ghosting.
//
// TWO BLENDS, and the default is MIX for a measured reason:
//
//   MIX (0, default) — mix(cur, prev, k). A leaky integrator: the WHOLE frame
//     ghosts, on any content, so the effect always visibly does something.
//     Softer, lower contrast.
//   MAX (1) — max(cur, prev * k). Light-trails: bright motion streaks and the
//     dark background stays clean and contrasty. The dramatic one.
//
// ⚠️ MAX IS INVISIBLE ON BRIGHT CONTENT, and that is not a subtlety — it is the
// dominant behaviour. A trail only appears where the current pixel is DARKER
// than the decayed history, so on a bright clip `cur` wins nearly everywhere and
// the effect reads as broken. It was mistaken for a wiring bug during
// development on exactly that footage. MIX is the default so selecting Trails
// always shows something; MAX is there when the content is dark enough to earn
// it.
//
// ⚠️ `prev_frame` is hint_default_black ON PURPOSE. RegionCompositor builds its
// materials from the same effect array and has NO history buffer, so this
// sampler is unbound on the per-region path. Godot's default sampler is WHITE,
// which would blow every masked region to solid white; with black the term is
// max(cur, 0) = cur and the region degrades to clean passthrough instead.

uniform float intensity : hint_range(0.0, 1.0) = 1.0;
// ⚠️ CAPPED BELOW 1.0 AND THE CAP IS LOAD-BEARING. The loop feeds its own
// output back in, so the history term must shrink every pass: decay * intensity
// < 1 always decays, and at 1.0 the frame would never fade — a permanent smear
// clearable only by leaving the effect. GDScript clamps to the same ceiling.
uniform float decay : hint_range(0.5, 0.97) = 0.90;
// 0 MIX (default, ghosts any content) · 1 MAX (light-trails on dark content).
uniform int blend = 0;
// Last frame's OUTPUT, fed by ShaderSlot's history viewport.
uniform sampler2D prev_frame : hint_default_black;

void fragment() {
	float g = clamp(intensity, 0.0, 1.0);
	vec4 cur = texture(TEXTURE, UV);
	// One extra full-frame fetch. The pass that FILLS prev_frame is the real
	// cost of this effect (see shader_slot.gd) — this line is nearly free.
	vec4 old = texture(prev_frame, UV);

	// k is the persistence for BOTH blends, and intensity is inside it, so k=0
	// gives cur either way: mix(cur, old, 0) == cur and max(cur, 0) == cur.
	// Passthrough at intensity 0 holds in both branches by construction.
	float k = clamp(decay, 0.0, 0.97) * g;

	// Uniform-valued branch — every fragment takes the same side.
	vec3 outc;
	if (blend == 1) {
		outc = max(cur.rgb, old.rgb * k);
	} else {
		// Leaky integrator. Stable for k < 1, which the 0.97 cap guarantees; at
		// k = 1 it would hold the first frame forever and never take new input.
		outc = mix(cur.rgb, old.rgb, k);
	}
	COLOR = vec4(outc, cur.a);
}
