/*
--------------------------------------------------------------------------------

  Photon Shaders by SixthSurge

  program/post/grading.fsh:
  Apply bloom, color grading and tone mapping then convert to rec. 709

--------------------------------------------------------------------------------
*/

#include "/include/global.glsl"

/* DRAWBUFFERS:0 */
layout (location = 0) out vec3 fragColor;

in vec2 uv;

uniform sampler2D colortex0; // Bloom tiles
uniform sampler2D colortex3; // Fog transmittance
uniform sampler2D colortex5; // Scene color

uniform float aspectRatio;
uniform float blindness;
uniform float biomeCave;
uniform float timeNoon;
uniform float eyeSkylight;

uniform vec2 texelSize;

#include "/include/aces/aces.glsl"

#include "/include/utility/bicubic.glsl"
#include "/include/utility/color.glsl"

// Bloom

vec3 getBloom(out vec3 fogBloom) {
	const int tileCount = 6;
	const float radius  = 1.0;

	vec3 tileSum = vec3(0.0);

	float weight = 1.0;
	float weightSum = 0.0;

#if defined BLOOMY_FOG || defined BLOOMY_RAIN
	const float fogBloomRadius = 1.5;

	fogBloom = vec3(0.0); // large-scale bloom for bloomy fog
	float fogBloomWeight = 1.0;
	float fogBloomWeightSum = 0.0;
#endif

	for (int i = 0; i < tileCount; ++i) {
		float a = exp2(float(-i));

		float tileScale = 0.5 * a;
		vec2 tileOffset = vec2(1.0 - a, float(i & 1) * (1.0 - 0.5 * a));

		vec2 tileCoord = uv * tileScale + tileOffset;

		vec3 tile = textureBicubic(colortex0, tileCoord).rgb;

		tileSum += tile * weight;
		weightSum += weight;

		weight *= radius;

#if defined BLOOMY_FOG || defined BLOOMY_RAIN
		fogBloom += tile * fogBloomWeight;

		fogBloomWeightSum += fogBloomWeight;
		fogBloomWeight *= fogBloomRadius;
#endif
	}

#if defined BLOOMY_FOG || defined BLOOMY_RAIN
	fogBloom /= fogBloomWeightSum;
#endif

	return tileSum / weightSum;
}

// Color grading

vec3 gain(vec3 x, float k) {
    vec3 a = 0.5 * pow(2.0 * mix(x, 1.0 - x, step(0.5, x)), vec3(k));
    return mix(a, 1.0 - a, step(0.5, x));
}

// Color grading applied before tone mapping
// rgb := color in acescg [0, inf]
vec3 gradeInput(vec3 rgb) {
	const float brightness = 1.08 * GRADE_BRIGHTNESS;
	const float contrast   = 1.05 * GRADE_CONTRAST;
	const float saturation = 1.02 * GRADE_SATURATION;

	// Brightness
	rgb *= brightness;

	// Contrast
	const float logMidpoint = 0.18;
	rgb = log2(rgb + eps);
	rgb = contrast * (rgb - logMidpoint) + logMidpoint;
	rgb = max0(exp2(rgb) - eps);

	// Saturation
	float lum = getLuminance(rgb, luminanceWeightsRec2020);
	rgb = max0(mix(vec3(lum), rgb, saturation));

#if GRADE_WHITE_BALANCE != 6500
	// White balance (slow)
	vec3 srcXyz = blackbody(float(GRADE_WHITE_BALANCE)) * rec2020_to_xyz;
	vec3 dstXyz = blackbody(                    6500.0) * rec2020_to_xyz;
	mat3 cat = getChromaticAdaptationMatrix(srcXyz, dstXyz);

	rgb = rgb * rec2020_to_xyz;
	rgb = rgb * cat;
	rgb = rgb * xyz_to_rec2020;
#endif

	return rgb;
}

// Color grading applied after tone mapping
// rgb := color in linear rec.709 [0, 1]
vec3 gradeOutput(vec3 rgb) {
	// Convert to roughly perceptual RGB for color grading
	rgb = sqrt(rgb);

	// HSL color grading inspired by Tech's color grading setup in Lux Shaders

	const float orangeSatBoost = GRADE_ORANGE_SAT_BOOST;
	const float tealSatBoost   = GRADE_TEAL_SAT_BOOST;
	const float greenSatBoost  = GRADE_GREEN_SAT_BOOST;
	const float greenHueShift  = GRADE_GREEN_HUE_SHIFT / 360.0;

	vec3 hsl = rgbToHsl(rgb);

	// Oranges
	float orange = isolateHue(hsl, 30.0, 20.0);
	hsl.y *= 1.0 + orangeSatBoost * orange;

	// Teals
	float teal = isolateHue(hsl, 210.0, 20.0);
	hsl.y *= 1.0 + tealSatBoost * teal;

	// Greens
	float green = isolateHue(hsl, 90.0, 44.0);
	hsl.x += greenHueShift * green;
	hsl.y *= 1.0 + greenSatBoost * green;

	rgb = hslToRgb(hsl);

	rgb = gain(rgb, 1.05);

	return sqr(rgb);
}

// Tonemapping operators

// ACES RRT and ODT
vec3 academyRrt(vec3 rgb) {
	rgb *= 1.6; // Match the exposure to the RRT

	rgb = rgb * rec2020_to_ap0;

	rgb = acesRrt(rgb);
	rgb = acesOdt(rgb);

	return rgb * ap1_to_rec2020;
}

// ACES RRT and ODT approximation
vec3 academyFit(vec3 rgb) {
	rgb *= 1.6; // Match the exposure to the RRT

	rgb = rgb * rec2020_to_ap0;

	rgb = rrtSweeteners(rgb);
	rgb = rrtAndOdtFit(rgb);

	// Global desaturation
	vec3 grayscale = vec3(getLuminance(rgb));
	rgb = mix(grayscale, rgb, odtSatFactor);

	return rgb * ap1_to_rec2020;
}

// Timothy Lottes 2016, "Advanced Techniques and Optimization of HDR Color Pipelines"
// https://gpuopen.com/wp-content/uploads/2016/03/GdcVdrLottes.pdf
vec3 tonemapLottes(vec3 rgb) {
	//*
	const vec3 a = vec3(1.33);      // Contrast
	const vec3 d = vec3(0.97);      // Shoulder contrast
	const vec3 hdrMax = vec3(8.0);  // White point
	const vec3 midIn = vec3(0.26);  // Fixed midpoint x
	const vec3 midOut = vec3(0.33); // Fixed midput y
	/*/
	const vec3 a = vec3(1.5);       // Contrast
	const vec3 d = vec3(0.94);      // Shoulder contrast
	const vec3 hdrMax = vec3(8.0);  // White point
	const vec3 midIn = vec3(0.26);  // Fixed midpoint x
	const vec3 midOut = vec3(0.33); // Fixed midput y
	//*/

	const vec3 b =
		(-pow(midIn, a) + pow(hdrMax, a) * midOut) /
		((pow(hdrMax, a * d) - pow(midIn, a * d)) * midOut);
	const vec3 c =
		(pow(hdrMax, a * d) * pow(midIn, a) - pow(hdrMax, a) * pow(midIn, a * d) * midOut) /
		((pow(hdrMax, a * d) - pow(midIn, a * d)) * midOut);

	return pow(rgb, a) / (pow(rgb, a * d) * b + c);
}

// Filmic tonemapping operator made by Jim Hejl and Richard Burgess
// Modified by Tech to not lose color information below 0.004
vec3 tonemapHejlBurgess(vec3 rgb) {
	rgb = rgb * min(vec3(1.0), 1.0 - 0.8 * exp(rcp(-0.004) * rgb));
	rgb = (rgb * (6.2 * rgb + 0.5)) / (rgb * (6.2 * rgb + 1.7) + 0.06);
	return srgbToLinear(rgb); // Revert built-in sRGB conversion
}

// Filmic tonemapping operator made by John Hable for Uncharted 2
vec3 tonemapUncharted2(vec3 rgb) {
	const float a = 0.15;
	const float b = 0.50;
	const float c = 0.10;
	const float d = 0.20;
	const float e = 0.02;
	const float f = 0.30;
	const float w = 11.2;

	return ((rgb * (a * rgb + (c * b)) + (d * e)) / (rgb * (a * rgb + b) + d * f)) - e / f;
}

// Tone mapping operator made by Tech for his shader pack Lux
vec3 tonemapTech(vec3 rgb) {
	vec3 a = rgb * min(vec3(1.0), 1.0 - exp(-1.0 / 0.038 * rgb));
	a = mix(a, rgb, rgb * rgb);
	return a / (a + 0.6);
}

// Tonemapping operator made by Zombye for his old shader pack Ozius
// It was given to me by Jessie
vec3 tonemapOzius(vec3 rgb) {
    const vec3 a = vec3(0.46, 0.46, 0.46);
    const vec3 b = vec3(0.60, 0.60, 0.60);

	rgb *= 1.6;

    vec3 cr = mix(vec3(dot(rgb, luminanceWeightsAp1)), rgb, 0.5) + 1.0;

    rgb = pow(rgb / (1.0 + rgb), a);
    return pow(rgb * rgb * (-2.0 * rgb + 3.0), cr / b);
}

vec3 tonemapReinhard(vec3 rgb) {
	return rgb / (rgb + 1.0);
}

vec3 tonemapReinhardJodie(vec3 rgb) {
	vec3 reinhard = rgb / (rgb + 1.0);
	return mix(rgb / (getLuminance(rgb) + 1.0), reinhard, reinhard);
}

float vignette(vec2 uv) {
    const float vignetteSize = 16.0;
    const float vignetteIntensity = 0.08 * VIGNETTE_INTENSITY;

    float vignette = vignetteSize * (uv.x * uv.y - uv.x) * (uv.x * uv.y - uv.y);
          vignette = pow(vignette, vignetteIntensity + 0.1 * biomeCave + 0.3 * blindness);

    return vignette;
}

void main() {
	ivec2 texel = ivec2(gl_FragCoord.xy);

	fragColor = texelFetch(colortex5, texel, 0).rgb;

	float exposure = texelFetch(colortex5, ivec2(0), 0).a;

#ifdef BLOOM
	vec3 fogBloom;
	vec3 bloom = getBloom(fogBloom);
	float bloomIntensity = 0.1 * BLOOM_INTENSITY;

	fragColor = mix(fragColor, bloom, bloomIntensity);

#ifdef BLOOMY_FOG
	float fogTransmittance = texture(colortex3, uv * taauRenderScale).x;
	fragColor = mix(fogBloom, fragColor, pow(fogTransmittance, BLOOMY_FOG_INTENSITY));
#endif
#endif

	fragColor *= exposure;

#ifdef VIGNETTE
	fragColor *= vignette(uv);
#endif

	fragColor = gradeInput(fragColor);

#ifdef TONEMAP_COMPARISON
	fragColor = uv.x < 0.5 ? tonemapLeft(fragColor) : tonemapRight(fragColor);
#else
	fragColor = tonemap(fragColor);
#endif

	fragColor = clamp01(fragColor * rec2020_to_rec709);
	fragColor = gradeOutput(fragColor);

#if 0 // Tonemap plot
	const float scale = 2.0;
	vec2 uvScaled = uv * scale * vec2(1.0, 1.0 / aspectRatio);
	float x = uvScaled.x;
	float y = tonemap(vec3(x)).x;

	if (abs(uvScaled.x - 1.0) < 0.001 * scale) fragColor = vec3(1.0, 0.0, 0.0);
	if (abs(uvScaled.y - 1.0) < 0.001 * scale) fragColor = vec3(1.0, 0.0, 0.0);
	if (abs(uvScaled.y - y) < 0.001 * scale) fragColor = vec3(1.0);
#endif
}
