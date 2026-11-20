shader_type canvas_item;
// ShaderSlot pass-through. Identity by default (tint = white).
// Replace/extend this with real effects — the ShaderSlot stage feeds whatever
// this outputs into the QuadWarp. Audio-reactive uniforms will hook in here.

uniform vec3 tint : source_color = vec3(1.0);

void fragment() {
	vec4 c = texture(TEXTURE, UV);
	COLOR = vec4(c.rgb * tint, c.a);
}
