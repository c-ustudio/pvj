shader_type canvas_item;
// ASCII-art filter with selectable glyph modes.
//  mode 0 Brightness : an 8-step density ramp of PVJ's own 5x5 glyphs
//                      ( . : - = + x @ and a dense block ), darkest to brightest.
//  mode 1 Binary 0/1 : each cell shows 0 or 1 by brightness (matrix look).
//  mode 2 Random     : a random A-Z/0-9 glyph per cell (gated by brightness).
//  mode 3 Custom text: the cells spell out `text_chars` (e.g. "LOVE"), gated by
//                      brightness so the image shows through the letters.
// Alphabet (A-Z 0..25, 0-9 26..35, space 36) is authored in GDScript and passed
// in as a fixed int array. `intensity` (audio-reactive) pushes toward full ASCII.
//
// COST NOTE (profiled on a Pixel 9a, 2026-07-22): this shader is cheap — one
// texture fetch, no loops, and a per-fragment instruction count that does NOT
// depend on `columns`. Measured ~2 fps of the frame budget at 1080p. Effect
// fill-rate is governed by the ShaderSlot SubViewport size (see the QUALITY
// setting in pipeline.gd), not by anything in here.

uniform float intensity = 1.0;
uniform float columns : hint_range(40.0, 240.0) = 120.0;
// Glyph size within its cell, about the cell centre. 1.0 = the original tight
// grid. >1.0 shrinks each glyph inside its cell, leaving black gaps between
// characters. <1.0 magnifies them so they crowd together.
uniform float spacing : hint_range(0.0, 2.0) = 1.0;
uniform int mode = 0;
uniform int text_len = 4;
uniform int text_chars[64];
uniform int alphabet[37];

// Brightness ramp for mode 0, in the same 5x5 encoding as the alphabet
// (bit = col + row * 5, row 0 at the top). Ink grows with each step:
//   .  :  -  =  +  x  @  dense block   (1, 2, 3, 6, 9, 9, 15, 21 pixels)
const int RAMP[8] = int[8](4194304, 131200, 14336, 459200, 4357252,
	18157905, 15136302, 33226431);

// Glyph sampler for every mode. `luv` in [0,1] within the cell (y down = row 0 top).
float glyph_px(int g, vec2 luv) {
	// Outside the (spacing-scaled) cell = background. This test is what makes
	// spacing > 1 leave black gaps instead of smearing the edge row/column.
	if (luv.x < 0.0 || luv.x > 1.0 || luv.y < 0.0 || luv.y > 1.0) {
		return 0.0;
	}
	int col = clamp(int(floor(luv.x * 5.0)), 0, 4);
	int row = clamp(int(floor(luv.y * 5.0)), 0, 4);
	int b = col + row * 5;
	return float((g >> b) & 1);
}

float rand(vec2 co) {
	return fract(sin(dot(co, vec2(12.9898, 78.233))) * 43758.5453);
}

void fragment() {
	float cols = floor(columns);
	float rows = max(1.0, floor(cols * 9.0 / 16.0));
	vec2 grid = vec2(cols, rows);

	vec2 cell = floor(UV * grid);
	vec2 cell_uv = (cell + 0.5) / grid;
	// textureLod(level 0) instead of texture(): cell_uv is a STEP function of UV,
	// so its screen-space derivatives spike at every cell boundary. Plain
	// texture() makes the GPU compute those derivatives per 2x2 quad and pick a
	// mip from them — wasted work on a tiler, and a garbage LOD on the seams.
	// We always want the base level, so ask for it explicitly.
	vec3 col3 = textureLod(TEXTURE, cell_uv, 0.0).rgb;
	float gray = dot(col3, vec3(0.3, 0.59, 0.11));

	// SPACING scales the glyph's UV about the cell centre (the sample point stays
	// centred, only the cell's effective size changes).
	float sp = max(spacing, 0.001);

	// Larger sp pushes luv further out, so the glyph covers less of the cell.
	vec2 luv = (fract(UV * grid) - 0.5) * sp + 0.5;
	float ch = 0.0;
	if (mode == 0) {
		// Step 0 up to gray 0.2, then one step per 0.1 up to the last at 0.8.
		int step_i = clamp(int(floor((gray - 0.1) * 10.0)), 0, 7);
		ch = glyph_px(RAMP[step_i], luv);
	} else {
		int g = 0;
		if (mode == 1) {
			g = alphabet[(gray > 0.5) ? 27 : 26];      // '1' or '0'
		} else if (mode == 2) {
			g = alphabet[clamp(int(rand(cell) * 36.0), 0, 35)];
			if (gray < 0.2) { g = 0; }
		} else {
			// Cells read like a page: row after row. When the row width is a
			// multiple of the text length every row would start on the same
			// letter and the text would stack into vertical columns ("HELLO
			// LOGOS " at 120 columns, the default "LOVE"; seen on the Pixel 8,
			// SESSION_45). Then shift each row by one cell so the text flows.
			int row_w = int(grid.x);
			int idx = int(cell.x) + int(cell.y) * row_w;
			if (text_len > 1 && row_w % text_len == 0) { idx += int(cell.y); }
			int ci = (text_len > 0) ? (idx % text_len) : 0;
			g = alphabet[clamp(text_chars[clamp(ci, 0, 63)], 0, 36)];
			if (gray < 0.25) { g = 0; }
		}
		ch = glyph_px(g, luv);
	}

	vec3 ascii = col3 * ch;
	float amt = clamp(0.7 + 0.3 * intensity, 0.0, 1.0);
	COLOR = vec4(mix(col3, ascii, amt), 1.0);
}
