shader_type canvas_item;
// CROWD — the tracker, made visible (docs/MEDIAPIPE_MODULE.md §13.5, M8c).
//
// A PURE FRAGMENT SHADER: one texture fetch per person plus the source, no
// history buffer, no extra pass. Nothing here asks ShaderSlot to allocate.
//
// This exists for two reasons at once, and that is deliberate:
//
//   1. IT IS THE DEBUG VIEW. Until now the only way to know the tracker was
//      working was to read logcat over adb — the operator spent a whole
//      session unable to tell whether crowd mode was even running. MARKERS
//      mode draws a ring per SLOT, in a per-slot colour, so slot identity is
//      visible: if a ring changes colour when two people cross, the tracker
//      swapped them and the §13.3 matcher is wrong.
//   2. IT IS THE PAYOFF. SPOTLIGHT and WARP are what crowd tracking is FOR —
//      the room's own occupants driving the visual, with no network in the
//      path (§1's local-first law: if the Wi-Fi dies, this keeps moving).
//
// THE MODULATED control is `intensity`, 0..1 — the contract every effect
// shares. `mode` and the character controls sit beside it.
//
// ⚠️ PER-SLOT DATA ARRIVES AS ONE ARRAY UNIFORM, NOT N UNIFORMS. §13.5 keeps
// the mod matrix to the six scalar AGGREGATES precisely so this surface can be
// one binding: 8 slots x 8 channels would be 64 ModSources and an unusable
// picker. Here, `crowd[i]` is (x, y, size, present) with x ALREADY in
// audience-view space — the §4.2 mirror happens on the way out of the tracker,
// never in its matching maths.

uniform float intensity : hint_range(0.0, 1.0) = 1.0;
// 0 SPOTLIGHT (light the people, sink the rest) · 1 MARKERS (debug rings)
// · 2 WARP (radial push around each person) · 3 BLOB (the classic tracker
// look: corner-bracket boxes, slot-ID labels, connecting lines)
uniform int mode = 0;

// (x, y, size, present) per slot. present is 0 or 1 — a slot in its §13.3
// grace window still reads 1 and holds its last position, which is the point:
// an occluded performer must not make the visual blink.
uniform vec4 crowd[8];
uniform int crowd_n = 0;

// Frame aspect (width/height). Without it every radius is an ellipse on a
// 16:9 deck, and the "circle" around a person reads as a squashed smear.
uniform float aspect = 1.777;
// How far a person's influence reaches, as a fraction of frame height, scaled
// by their box size so a NEAR person owns more of the picture than a far one.
uniform float reach : hint_range(0.05, 1.5) = 0.45;
// SPOTLIGHT: how far the un-lit rest of the frame is sunk.
uniform float sink : hint_range(0.0, 1.0) = 0.75;
// WARP: displacement in UV at the centre of a person.
uniform float push : hint_range(0.0, 0.3) = 0.06;

// --- BLOB mode ------------------------------------------------------------
// 3x5 bitmap digits, bit i = row*3 + col, bit 0 top-left. A whole glyph atlas
// would be a texture and an upload; ten digits fit in ten ints, and slot IDs
// are all this look needs to say.
const int DIGITS[10] = {31599, 29850, 29671, 31207, 18925,
                        31183, 31695, 18727, 31727, 31215};
// ⚠️ A person box's WIDTH is not tracked — §13.3 keeps `size` (height over
// frame) as the distance proxy and nothing else, because height is what a
// standing body reports reliably while width swings with arms and turning.
// So the rectangle uses a fixed body aspect. It is an APPROXIMATION and looks
// it if someone spreads their arms; carrying real width would mean a fifth
// float through the Kotlin pack, the tracker and its 45 checks.
const float BODY_ASPECT = 0.42;

// 1 where the glyph is inked. p is 0..1 inside the digit cell.
float digit_ink(vec2 p, int d) {
	float ink = 0.0;
	if (p.x >= 0.0 && p.x <= 1.0 && p.y >= 0.0 && p.y <= 1.0) {
		int col = int(clamp(floor(p.x * 3.0), 0.0, 2.0));
		int row = int(clamp(floor(p.y * 5.0), 0.0, 4.0));
		int bits = DIGITS[int(clamp(float(d), 0.0, 9.0))];
		ink = float((bits >> (row * 3 + col)) & 1);
	}
	return ink;
}

// Distance from p to segment ab — the connecting lines.
float seg_dist(vec2 p, vec2 a, vec2 b) {
	vec2 ab = b - a;
	float t = clamp(dot(p - a, ab) / max(dot(ab, ab), 0.00001), 0.0, 1.0);
	return length(p - (a + ab * t));
}

// Per-slot hue so identity is READABLE, not merely present. Eight distinct
// steps around the wheel; slot 0 is always the same colour, which is what
// makes a swap visible at a glance.
vec3 slot_colour(int i) {
	float h = float(i) / 8.0;
	vec3 k = vec3(1.0, 2.0 / 3.0, 1.0 / 3.0);
	vec3 p = abs(fract(vec3(h) + k) * 6.0 - 3.0);
	return clamp(p - 1.0, 0.0, 1.0);
}

void fragment() {
	// ⚠️ ONE EXIT, NO EARLY `return` — Godot REJECTS `return` in fragment() and
	// the shader then fails to compile SILENTLY, falling back to drawing the
	// texture unchanged. That looks exactly like a working deck with a dead
	// effect, and it has already cost this project a session (slit-scan).
	vec2 uv = UV;
	float g = clamp(intensity, 0.0, 1.0);
	// ⚠️ MARKERS and BLOB are READOUTS, not looks, so they IGNORE intensity.
	// Every effect's `intensity` is audio-driven by contract
	// (audio_base + level * audio_amount), which is right for SPOTLIGHT and
	// WARP — and useless for a debug view: the boxes pulsed with room sound
	// and read as flicker rather than as tracking. Legibility beats the
	// contract here, and only here.
	if (mode == 1 || mode == 3) {
		g = 1.0;
	}

	// --- gather the crowd's influence at this pixel -----------------------
	float lit = 0.0;            // 0..1 nearness to ANY tracked person
	vec3 tint = vec3(0.0);      // slot colour, weighted
	vec2 shove = vec2(0.0);     // WARP displacement
	float ring = 0.0;           // MARKERS ring mask

	for (int i = 0; i < 8; i++) {
		// Uniform-valued branch: every fragment takes the same side, so this
		// is a loop bound rather than divergence.
		if (i < crowd_n && crowd[i].w > 0.5) {
			vec2 c = crowd[i].xy;
			// aspect-correct the delta so radii are CIRCLES on the wall
			vec2 d = vec2((uv.x - c.x) * aspect, uv.y - c.y);
			float r = length(d);
			// a nearer person (bigger box) reaches further
			float rad = max(reach * (0.35 + crowd[i].z), 0.02);
			float f = 1.0 - smoothstep(0.0, rad, r);
			if (f > lit) {
				lit = f;
			}
			tint += slot_colour(i) * f;
			// push AWAY from the person, falling off with the same radius
			shove += (r > 0.0001 ? d / r : vec2(0.0)) * f * push;
			// a ring ON the radius: thin, and thickened slightly by size so a
			// close subject is not a hairline
			float w = 0.006 + crowd[i].z * 0.01;
			ring = max(ring, 1.0 - smoothstep(0.0, w, abs(r - rad * 0.5)));
		}
	}

	// --- BLOB overlay: boxes, labels, links ------------------------------
	// Built in a second pass over the slots because it needs the box RECT
	// rather than the radial falloff the modes above share.
	float blob = 0.0;          // box edges + glyphs
	vec3 blob_tint = vec3(0.0);
	float link = 0.0;          // connecting lines
	if (mode == 3) {
		vec2 prev = vec2(-1.0);
		for (int i = 0; i < 8; i++) {
			if (i < crowd_n && crowd[i].w > 0.5) {
				vec2 c = crowd[i].xy;
				float hh = max(crowd[i].z, 0.02) * 0.5;          // half height
				float hw = max(crowd[i].w > 1.5 ? 0.0 : 0.0, 0.0)
						 + hh * BODY_ASPECT / max(aspect, 0.001); // half width, UV
				// The box arrives ALREADY clamped into the frame — GDScript owns
				// that (see _push_crowd_uniforms) so the numbers are loggable.
				// Clamping here was invisible from a screenshot and got guessed
				// at twice; one source of truth, and it prints.
				float top = c.y - hh;
				float bot = c.y + hh;
				float lft = c.x - hw;
				float rgt = c.x + hw;
				// ⚠️ THE SDF MUST BE ASPECT-CORRECTED OR THE STROKE IS NOT.
				// Computed in raw UV, a 0.0015 stroke is 3.6 px across a 2400-wide
				// deck but only 1.6 px down a 1080-tall one — so the VERTICAL
				// edges drew and the HORIZONTAL ones fell under visibility, and
				// the box read as two vertical lines however the geometry was
				// clamped. Working in y-normalised units (x scaled by aspect)
				// makes one stroke width mean one thickness on both axes.
				vec2 d = vec2((abs(uv.x - c.x) - hw) * aspect, abs(uv.y - c.y) - hh);
				float sd = length(max(d, vec2(0.0))) + min(max(d.x, d.y), 0.0);
				float t = 0.0035;
				float edge = 1.0 - smoothstep(0.0, t * 2.0, abs(sd));
				// CORNER BRACKETS, not a full rectangle: the classic CV look,
				// and it keeps the subject's face unobscured.
				vec2 q = abs(uv - c);
				float corner = step(hw * 0.55, q.x) + step(hh * 0.55, q.y);
				edge *= clamp(corner, 0.0, 1.0);
				// slot-ID glyph, sitting just above the box's top-left
				vec2 gsz = vec2(0.012 / max(aspect, 0.001) * 3.0, 0.030);
				// label ABOVE the box, but tucked INSIDE when the box is already
				// against the top of the frame — otherwise a near subject loses
				// its slot ID exactly when identity matters most.
				float ly = (top - gsz.y * 1.25 < 0.01) ? top + gsz.y * 0.35
														: top - gsz.y * 1.25;
				vec2 gorg = vec2(lft, ly);
				float ink = digit_ink((uv - gorg) / gsz, i);
				float mark = max(edge, ink);
				if (mark > blob) {
					blob = mark;
				}
				blob_tint += slot_colour(i) * mark;
				if (prev.x >= 0.0) {
					// chain, not all-pairs: n-1 segments instead of 28, and the
					// constellation reads the same
					link = max(link, 1.0 - smoothstep(0.0, 0.0016, seg_dist(uv, prev, c)));
				}
				prev = c;
			}
		}
	}

	// WARP samples displaced; the others sample straight. Doing the fetch ONCE
	// off a conditionally-built coordinate keeps this to a single tap.
	vec2 suv = uv;
	if (mode == 2) {
		suv = clamp(uv + vec2(shove.x / aspect, shove.y), vec2(0.0), vec2(1.0));
	}
	vec4 cur = texture(TEXTURE, suv);

	vec3 target = cur.rgb;
	if (mode == 0) {
		// SPOTLIGHT — sink the room, keep the people. `lit` is already the
		// nearest person's falloff, so overlapping subjects do not stack into
		// a blown highlight.
		target = cur.rgb * mix(1.0 - sink, 1.0, lit);
	} else if (mode == 1) {
		// MARKERS — the honest debug view. Rings in SLOT colour over a sunk
		// frame: watch a ring's colour across a crossing to see whether slot
		// identity survived it.
		vec3 t = clamp(tint, 0.0, 1.0);
		target = mix(cur.rgb * 0.35, t, clamp(ring, 0.0, 1.0));
	} else if (mode == 3) {
		// BLOB — the classic tracker overlay ON the picture rather than over a
		// sunk one: this is a look as much as a debug view, and a dimmed frame
		// would make it useless as the former.
		vec3 t = clamp(blob_tint, 0.0, 1.0);
		vec3 lines = mix(cur.rgb, vec3(0.6, 1.0, 0.7), clamp(link, 0.0, 1.0) * 0.8);
		target = mix(lines, t, clamp(blob, 0.0, 1.0));
	}
	// mode 2 leaves `target` as the displaced fetch — the warp IS the effect.

	// ⚠️ PASSTHROUGH AT 0 HOLDS BY CONSTRUCTION, not by a guard that could
	// drift from the slider: mix(cur, anything, 0) == cur. Every mode funnels
	// through this one line for exactly that reason — including WARP, whose
	// displaced sample fades back to the straight one as g goes to zero.
	COLOR = vec4(mix(cur.rgb, target, g), cur.a);
}
