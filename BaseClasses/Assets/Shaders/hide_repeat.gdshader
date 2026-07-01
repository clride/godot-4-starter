/* 
	-------------------------------------------------------------
	STOCHASTIC HEX-TILING (Mikkelsen's Adaptation)
	------------------------------------------------------------- 
*/

/*
	MIT License

	Copyright (c) 2022 mmikk, noddingSloth

	Permission is hereby granted, free of charge, to any person obtaining a copy
	of this software and associated documentation files (the "Software"), to deal
	in the Software without restriction, including without limitation the rights
	to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
	copies of the Software, and to permit persons to whom the Software is
	furnished to do so, subject to the following conditions:

	The above copyright notice and this permission notice shall be included in all
	copies or substantial portions of the Software.

	THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
	IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
	FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
	AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
	LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
	OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
	SOFTWARE.
*/

shader_type spatial;

/* 
	The seamless texture you want to apply. 
	Works best with organic patterns like grass, dirt, sand, or gravel.
*/
uniform sampler2D source_texture : source_color, filter_linear_mipmap, repeat_enable;

/* 
	Scales the texture across the world coordinates. 
	Higher values make the texture repeat more times (appear smaller).
	Lower values stretch the texture over a larger area.
*/
uniform float tile_scale = 1.0; 

/* 
	Controls how much random rotation is applied to each virtual hex tile. 
	0.0 = No rotation (Use this if your texture has parallel lines, like bricks).
	1.0 = Full random rotation (Best for organic textures to destroy tiling patterns).
*/
uniform float rot_strength : hint_range(0.0, 1.0) = 0.5;

/* 
	Restores the contrast that naturally gets lost when blending 3 texture samples.
	0.50 = No contrast adjustment (will look blurry).
	0.75 = Recommended by the author. Restores crispness without revealing the grid.
	0.99 = Max contrast (Warning: May make the hexagonal grid borders visible).
*/
uniform float contrast_adjust : hint_range(0.01, 0.99) = 0.75;


/* 
	-------------------------------------------------------------
	TRANSLATED FROM MIKKELSEN'S PAPER (Appendix Listings 1, 2, 4, 5, 6, 8)
	-------------------------------------------------------------
*/

void TriangleGrid(out float w1, out float w2, out float w3,
	out ivec2 vertex1, out ivec2 vertex2, out ivec2 vertex3,
	vec2 st) {

	// Scaling of the input
	st *= 2.0 * sqrt(3.0);

	/* 
		Skew input space into simplex triangle grid.
		Note: GLSL mat2 is column-major, so this is transposed from HLSL.
	*/
	mat2 gridToSkewedGrid = mat2(vec2(1.0, 0.0), vec2(-0.57735027, 1.15470054));
	vec2 skewedCoord = gridToSkewedGrid * st;

	ivec2 baseId = ivec2(floor(skewedCoord));
	vec3 temp = vec3(fract(skewedCoord), 0.0);
	temp.z = 1.0 - temp.x - temp.y;

	float s = step(0.0, -temp.z);
	float s2 = 2.0 * s - 1.0;

	w1 = -temp.z * s2;
	w2 = s - temp.y * s2;
	w3 = s - temp.x * s2;

	vertex1 = baseId + ivec2(int(s), int(s));
	vertex2 = baseId + ivec2(int(s), int(1.0 - s));
	vertex3 = baseId + ivec2(int(1.0 - s), int(s));
}

vec2 hash(vec2 p) {
	mat2 m = mat2(vec2(127.1, 269.5), vec2(311.7, 183.3));
	vec2 r = m * p;
	return fract(sin(r) * 43758.5453);
}

vec2 MakeCenST(ivec2 Vertex) {
	mat2 invSkewMat = mat2(vec2(1.0, 0.0), vec2(0.5, 1.0 / 1.15470054));
	return (invSkewMat * vec2(Vertex)) / (2.0 * sqrt(3.0));
}

mat2 LoadRot2x2(ivec2 idx, float rotStrength) {
	float angle = abs(float(idx.x * idx.y)) + abs(float(idx.x + idx.y)) + PI;

	// Remap to +/-pi.
	angle = mod(angle, 2.0 * PI);
	if(angle < 0.0) angle += 2.0 * PI;
	if(angle > PI) angle -= 2.0 * PI;

	angle *= rotStrength;

	float cs = cos(angle);
	float si = sin(angle);

	return mat2(vec2(cs, si), vec2(-si, cs));
}

vec3 Gain3(vec3 x, float r) {
	// Increase contrast when r > 0.5 and reduce contrast if less.
	float k = log(1.0 - r) / log(0.5);
	vec3 s = 2.0 * step(vec3(0.5), x);
	vec3 m = 2.0 * (1.0 - s);

	vec3 res = 0.5 * s + 0.25 * m * pow(max(vec3(0.0), s + x * m), vec3(k));
	return res / (res.x + res.y + res.z);
}

vec4 hex2colTex(sampler2D tex, vec2 st, float rotStrength, float r) {
	// Calculate derivatives for mipmapping *before* manipulating UVs
	vec2 dSTdx = dFdx(st);
	vec2 dSTdy = dFdy(st);

	// Get triangle info.
	float w1, w2, w3;
	ivec2 vertex1, vertex2, vertex3;
	TriangleGrid(w1, w2, w3, vertex1, vertex2, vertex3, st);

	mat2 rot1 = LoadRot2x2(vertex1, rotStrength);
	mat2 rot2 = LoadRot2x2(vertex2, rotStrength);
	mat2 rot3 = LoadRot2x2(vertex3, rotStrength);

	vec2 cen1 = MakeCenST(vertex1);
	vec2 cen2 = MakeCenST(vertex2);
	vec2 cen3 = MakeCenST(vertex3);

	vec2 st1 = (rot1 * (st - cen1)) + cen1 + hash(vec2(vertex1));
	vec2 st2 = (rot2 * (st - cen2)) + cen2 + hash(vec2(vertex2));
	vec2 st3 = (rot3 * (st - cen3)) + cen3 + hash(vec2(vertex3));

	// Fetch input textures using explicit derivatives to prevent seam artifacts
	vec4 c1 = textureGrad(tex, st1, rot1 * dSTdx, rot1 * dSTdy);
	vec4 c2 = textureGrad(tex, st2, rot2 * dSTdx, rot2 * dSTdy);
	vec4 c3 = textureGrad(tex, st3, rot3 * dSTdx, rot3 * dSTdy);

	// Use luminance as weight.
	vec3 Lw = vec3(0.299, 0.587, 0.114);
	vec3 Dw = vec3(dot(c1.rgb, Lw), dot(c2.rgb, Lw), dot(c3.rgb, Lw));

	float g_fallOffContrast = 0.6; // Hardcoded from Mikkelsen's defaults
	float g_exp = 7.0;             // Hardcoded from Mikkelsen's defaults

	Dw = mix(vec3(1.0), Dw, g_fallOffContrast);
	vec3 W = Dw * pow(vec3(w1, w2, w3), vec3(g_exp));
	W /= (W.x + W.y + W.z);

	// Apply contrast curve
	if(r != 0.5) {
		W = Gain3(W, r);
	}

	// Blend the 3 samples together using calculated weights
	return W.x * c1 + W.y * c2 + W.z * c3;
}

/* 
	-------------------------------------------------------------
	GODOT SPATIAL IMPLEMENTATION
	------------------------------------------------------------- 
*/

void fragment() {
	/* 
		1. Get the world-space position of the pixel.
		2. Use the World X and Z axes instead of the mesh's UVs.
		(If your game is oriented upright instead of flat on the ground, use .xy instead of .xz)
	*/
	vec3 world_pos = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec2 uv = world_pos.xz * tile_scale;

	// Call the Hex-Tiling function
	vec4 hex_color = hex2colTex(source_texture, uv, rot_strength, contrast_adjust);

	// Apply to standard spatial material outputs
	ALBEDO = hex_color.rgb;
}