shader_type canvas_item;
// GLITCH — digital corruption: RGB channel tearing, horizontal band/scanline
// shifting, and occasional corruption blocks.
//
// THE MODULATED control is `intensity`, 0..1 — the contract every effect
// shares. pipeline.gd's _process drives it from the audio level (or the manual
// fader while it's grabbed), so nothing here reads TIME for its own envelope.
//
// `block_count`, `block_size` and `block_aspect` are CHARACTER controls: they
// define the flavour intensity acts on and are not modulated by anything. Every
// term they feed is still scaled by intensity, so none of them can produce
// corruption at intensity 0 — the master stays master however they are set.
//
// 0.0 is EXACT passthrough, not "nearly clean": every displacement, split and
// mix term below is multiplied by `g`, and the corruption gate is ramped in by
// smoothstep, so at zero this shader samples TEXTURE at UV and nothing else.
// The intensity source can overshoot 1.0 (audio_base + level * audio_amount
// reaches ~1.75, the fader goes to 3.0), hence the clamp — full glitch at 1.

// THE MASTER. Modulated (audio / fader); the two below are not.
uniform float intensity : hint_range(0.0, 1.0) = 1.0;

// --- Character controls: they shape WHAT intensity acts on ----------------
// Set to taste and left alone; intensity animates over the top of them.
//
// block_count is an EXPECTED BLOCK COUNT, not a probability — the per-layer
// hit chance is derived from it by dividing by that layer's cell count, so the
// number on the slider means the same thing at every block size. It is the
// count on a full-intensity burst frame; quieter frames show proportionally
// fewer. The default reproduces the pre-parameter look (a flat 0.40 chance over
// a 22x13 grid ~= 114 blocks).
uniform float block_count : hint_range(0.0, 250.0) = 110.0;
// Base block SIZE as a percent of frame width (4.5% ~= the old 22-cell grid).
// Percent rather than a fraction so the panel readout has usable resolution.
uniform float block_size : hint_range(1.0, 35.0) = 4.5;
// Block shape, in STOPS (powers of two) rather than a raw ratio: 0 = square,
// +1 = twice as wide as tall, -1 = twice as tall as wide, so the range is
// symmetric about square and a linear slider spends equal travel on each side.
// A raw 0.1..10 ratio would bury the whole tall half in 9% of the slider.
//
// It splits the size rather than stretching one edge: width scales by sqrt(ratio)
// and height by 1/sqrt(ratio), so block AREA is unchanged and block_count keeps
// predicting coverage as you stretch. That is also what makes the wide end read
// as classic datamosh banding — at +4 a block is 16x wider than tall AND four
// times wider than the square default (~18% of frame width), not merely a
// flattened version of the same small square.
uniform float block_aspect : hint_range(-4.0, 4.0) = 0.0;

// Cheap hash pair (Dave Hoskins' style) — no texture lookup, no sin() precision
// cliff on Mali/Adreno.
float h11(float p) {
	p = fract(p * 0.1031);
	p *= p + 33.33;
	p *= p + p;
	return fract(p);
}

float h21(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

// One corruption layer at one block scale.
//
// Blocks come in three sizes rather than one, because a single uniform grid
// reads as a regular pattern — the eye finds the grid immediately. `acc` is the
// running result (xy = sample UV, z = corrupt flag, w = the block's mangle
// hash) and a hit here OVERRIDES an earlier one, so layers are called
// fine-to-chunky and a big block swallows the speckle inside it instead of the
// two fighting over the same fragment.
//
// cell_uv is the UNDISPLACED UV so the block grid stays screen-aligned (blocks
// must not slide around with the tear); samp_uv is what actually gets sampled.
// `salt` decorrelates the layers, which would otherwise agree wherever their
// cell ids collide.
// `ar` is sqrt(the width:height ratio) — see block_aspect. Dividing the column
// count by it and multiplying the row count keeps cell area constant.
vec4 glitch_layer(vec2 cell_uv, vec2 samp_uv, float cells_x, float ar, float expect,
		float salt, float gf, float g, vec4 acc) {
	vec2 grid = vec2(
		max(1.0, cells_x / ar),
		max(1.0, cells_x * (9.0 / 16.0) * ar));
	float p = clamp(expect / (grid.x * grid.y), 0.0, 1.0);
	vec2 bid = floor(cell_uv * grid);
	float hit = step(1.0 - p, h21(bid * 1.7 + gf * 3.1 + salt));
	vec2 off = vec2(
		(h21(bid + salt + 7.0) - 0.5) * 0.45,
		(h21(bid + salt + 19.0) - 0.5) * 0.14) * g;
	return vec4(
		mix(acc.xy, fract(samp_uv + off), hit),
		max(acc.z, hit),
		mix(acc.w, h21(bid + salt + 31.0), hit));
}

void fragment() {
	float g = clamp(intensity, 0.0, 1.0);

	// The glitch clock. Quantized to ~14 Hz so a corruption pattern HOLDS for a
	// few display frames — per-frame randomness averages out into grey mush on
	// a projector; held frames read as digital stutter.
	float gf = floor(TIME * 14.0);

	// Not every held frame tears. `burst` picks the hard ones; more frames are
	// hit as intensity rises, which is what makes it punchy rather than a
	// constant wash — at low intensity you get infrequent hits at full contrast,
	// not continuous mild damage.
	float burst = step(1.0 - (0.25 + 0.70 * g), h11(gf * 1.7 + 0.5));

	vec2 uv = UV;

	// --- 1. Horizontal band tear -----------------------------------------
	// The frame splits into bands; a random subset slides sideways. fract()
	// wraps the sample instead of clamping, so a tear reads as the picture
	// rolling through itself rather than a smeared edge pixel.
	float bands = mix(10.0, 46.0, g);
	float row = floor(UV.y * bands);
	float row_amt = h21(vec2(row, gf)) - 0.5;
	float row_hit = step(0.60 - 0.45 * g, h21(vec2(row * 3.7 + 1.3, gf * 0.7)));
	uv.x = fract(uv.x + row_amt * (0.05 + 0.28 * burst) * g * row_hit);

	// --- 2. Scanline slip -------------------------------------------------
	// Sub-band jitter on fine rows: the texture that keeps the tears from
	// looking like clean rectangles.
	uv.x = fract(uv.x + (h21(vec2(floor(UV.y * 240.0), gf * 2.1)) - 0.5) * 0.008 * g);

	// --- 3. Corruption blocks (three sizes) -------------------------------
	// Cells that resample from somewhere else in the frame. How MANY is
	// block_count, how BIG is block_size, and how hard is still intensity:
	// dens is the expected block count for THIS frame, so at g=1 on a burst
	// frame it is exactly block_count. The (0.25 + 0.75 * g) ramp preserves the
	// old (0.10 + 0.30 * g) intensity curve as a fraction of its own maximum.
	float base_cells = clamp(100.0 / max(block_size, 0.5), 2.0, 400.0);
	float dens = block_count * (0.25 + 0.75 * g) * (0.35 + 0.65 * burst)
		* smoothstep(0.0, 0.12, g);
	// Weights split the count across half-size / base / double-size blocks.
	// They are area-balanced, not equal: a double-size block covers 4x the
	// pixels, so an even split would let the chunky layer dominate the frame
	// and the count would stop predicting what you see.
	// Half the stops each way, because it is applied to BOTH axes (once as a
	// divide, once as a multiply) — so exp2(stops * 0.5) is sqrt of the ratio.
	float ar = exp2(clamp(block_aspect, -4.0, 4.0) * 0.5);
	vec4 acc = vec4(uv, 0.0, 0.0);
	acc = glitch_layer(UV, uv, base_cells * 2.0, ar, dens * 0.45, 0.0, gf, g, acc);
	acc = glitch_layer(UV, uv, base_cells, ar, dens * 0.40, 13.0, gf, g, acc);
	acc = glitch_layer(UV, uv, base_cells * 0.5, ar, dens * 0.15, 47.0, gf, g, acc);
	vec2 suv = acc.xy;
	// Ramped so intensity 0 is exact passthrough even if a hash lands on 1.0.
	float corrupt = acc.z * smoothstep(0.0, 0.02, g);

	// --- 4. RGB channel tearing -------------------------------------------
	// Three taps total on the normal path (four inside a corrupt block, which
	// is the same count — suv already folded the displacement in).
	float split = (0.006 + 0.030 * burst) * g * (0.35 + 0.65 * h11(gf * 5.7));
	vec4 base = texture(TEXTURE, suv);
	float r = texture(TEXTURE, fract(suv + vec2(split, 0.0))).r;
	float b = texture(TEXTURE, fract(suv - vec2(split * 0.75, 0.0))).b;
	vec3 col = vec3(r, base.g, b);

	// --- 5. Channel mangling inside corrupt blocks ------------------------
	// Half the corrupt cells rotate channels, half invert — one hash decides,
	// so a given block is stable for as long as the glitch frame holds.
	vec3 mangled = mix(col.gbr, vec3(1.0) - col, step(0.5, acc.w));
	col = mix(col, mangled, corrupt * g * 0.85);

	// --- 6. Scanlines + dropout speckle -----------------------------------
	col *= 1.0 - (0.16 * g) * (0.5 + 0.5 * sin(UV.y * 1400.0));
	float speck = step(0.997, h21(UV * 900.0 + gf)) * g * burst;
	col = mix(col, vec3(1.0), speck * 0.7);

	COLOR = vec4(col, base.a);
}
