shader_type canvas_item;
// BEAT FLIP — the OUTPUT-stage mirror, driven by a beat/onset trigger.
//
// Lives on QuadWarp's material, i.e. AFTER the effect slot and after the mask
// compositor, so it composes with whatever the deck is already doing instead of
// competing for the one effect slot. QuadWarp's mesh UVs are NORMALIZED (see
// quad_warp.gd), so the mirror axis is in IMAGE space: it stays put through a
// corner-pin warp, a mesh warp, and every QUALITY resize.
//
// ⚠️ THIS SHADER IS ALWAYS ATTACHED, including while the feature is off. That is
// deliberate — attaching the material on enable would compile it mid-set, and a
// projector is the worst place to discover a shader stall. With `flip_on` false
// the fragment is the same texture fetch Godot's default canvas material does
// (QuadWarp's modulate is white and nothing sets self_modulate), so "off" costs
// one uniform branch and looks identical.

uniform bool flip_on = false;
// 0 = horizontal — the mirror line is vertical, halves are LEFT/RIGHT.
// 1 = vertical   — the mirror line is horizontal, halves are TOP/BOTTOM.
uniform int axis = 0;
// WHICH HALF SURVIVES: 0 = the left/top half drives, 1 = the right/bottom half.
// The pipeline owns the ping-pong (SOURCE = ALTERNATE); this uniform only ever
// describes the state of one frame. Default 0 reproduces the original
// left-drives-right behaviour exactly — min() IS `uv.x > 0.5 ? 1.0 - uv.x : uv.x`.
uniform int src_half = 0;
// HOW the affected half is drawn from the source half.
//   0 MIRROR — a reflection. The seam is a mirror line and the frame is
//              symmetric about it (the butterfly).
//   1 FLIP   — the source half turned 180 degrees: reflected AND flipped on the
//              cross axis. Rotationally symmetric about the CENTRE instead of
//              mirrored about the seam, so the seam stops reading as a fold.
//   3 REPEAT — the source half TRANSLATED, not reflected: the same half twice at
//              true scale. No mirror line at all, so motion carries straight
//              across the seam instead of bouncing off it — the one treatment
//              where a pan still reads as a pan.
// Only the AFFECTED half is touched in every case — the source half is always
// untouched original pixels, which is what keeps `src_half` meaningful.
//
// ⚠️ REPEAT IS 3, NOT 2, AND THE GAP IS DELIBERATE. The pipeline's
// FlipTreatment enum carries an ALTERNATE at 2 which is resolved to MIRROR or
// FLIP before it ever reaches this uniform. Numbering REPEAT 3 keeps every enum
// value equal to its shader value — the property the pipeline comment calls
// deliberate — AND leaves the meaning of every integer already written to
// settings.cfg untouched, so no config migration is needed.
uniform int treatment = 0;

void fragment() {
	vec2 uv = UV;
	if (flip_on) {
		if (axis == 0) {
			// Which side is being overwritten has to be decided BEFORE uv is
			// folded, because after the fold both sides look alike.
			bool affected = src_half == 0 ? uv.x > 0.5 : uv.x < 0.5;
			if (treatment == 3) {
				// REPEAT: translate by half a frame instead of folding. The
				// affected half samples the SAME span the source half shows, so
				// the two read as one image repeated rather than reflected.
				if (affected) {
					uv.x += src_half == 0 ? -0.5 : 0.5;
				}
			} else {
				uv.x = src_half == 0 ? min(uv.x, 1.0 - uv.x) : max(uv.x, 1.0 - uv.x);
				if (affected && treatment == 1) {
					uv.y = 1.0 - uv.y;
				}
			}
		} else {
			bool affected = src_half == 0 ? uv.y > 0.5 : uv.y < 0.5;
			if (treatment == 3) {
				if (affected) {
					uv.y += src_half == 0 ? -0.5 : 0.5;
				}
			} else {
				uv.y = src_half == 0 ? min(uv.y, 1.0 - uv.y) : max(uv.y, 1.0 - uv.y);
				if (affected && treatment == 1) {
					uv.x = 1.0 - uv.x;
				}
			}
		}
	}
	COLOR = texture(TEXTURE, uv);
}
