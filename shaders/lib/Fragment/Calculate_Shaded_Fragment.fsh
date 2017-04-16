struct Shading { // Scalar light levels
	float sunlight;
	float skylight;
	float caustics;
	float torchlight;
	float ambient;
};

struct Lightmap { // Vector light levels with color
	vec3 sunlight;
	vec3 skylight;
	vec3 torchlight;
	vec3 ambient;
	vec3 GI;
};


#include "/lib/Misc/Bias_Functions.glsl"
#include "/lib/Fragment/Sunlight_Shading.fsh"


float GetHeldLight(vec3 viewSpacePosition, vec3 normal, float handMask) {
	const mat2x3 lightPos = mat2x3(
	     0.16, -0.05, -0.1,
	    -0.16, -0.05, -0.1);
	
	mat2x3 lightRay = mat2x3(
	    viewSpacePosition - lightPos[0],
	    viewSpacePosition - lightPos[1]);
	
	vec2 falloff = vec2(inversesqrt(length2(lightRay[0])), inversesqrt(length2(lightRay[1])));
	
	falloff *= clamp01(vec2(dot(normal, lightPos[0] * falloff[0]), dot(normal, lightPos[1] * falloff[1]))) * 0.35 + 0.65;
	
	vec2 hand  = max0(falloff - 0.0625);
	     hand  = mix(hand, vec2(2.0), handMask * vec2(greaterThan(viewSpacePosition.x * vec2(1.0, -1.0), vec2(0.0))));
	     hand *= vec2(heldBlockLightValue, heldBlockLightValue2) / 16.0;
	
	return hand.x + hand.y;
}

#if defined composite1
#include "/lib/Fragment/Water_Waves.fsh"

float CalculateWaterCaustics(vec3 worldPos, float waterMask) {
#ifndef WATER_CAUSTICS
	return 1.0;
#endif
	
	if (abs(isEyeInWater - waterMask) < 0.5) return 1.0;
	
	SetupWaveFBM();
	
	worldPos += cameraPosition + gbufferModelViewInverse[3].xyz - vec3(0.0, 1.62, 0.0);
	
	cfloat waterPlaneHeight = 63.0;
	
	float verticalDist = min(abs(worldPos.y - waterPlaneHeight), 2.0);
	
	vec3 flatRefractVector  = refract(-worldLightVector, vec3(0.0, 1.0, 0.0), 1.0 / 1.3333);
	     flatRefractVector *= verticalDist / flatRefractVector.y;
	
	vec3 lookupCenter = worldPos + flatRefractVector;
	
	vec2 coord = lookupCenter.xz + lookupCenter.y;
	
	cfloat distanceThreshold = 0.15;
	
	float caustics = 0.0;
	
	vec3 r; // RIGHT height sample to rollover between columns
	vec3 a; // .x = center      .y = top      .z = right
	mat4x3[4] p;
	
	for (int x = -1; x <= 1; x++) {
		for (int y = -1; y <= 1; y++) { // 3x3 sample matrix. Starts bottom-left and immediately goes UP
			vec2 offset = vec2(x, y) * 0.1;
			
			// Generate heights for wave normal differentials. Lots of math & sample reuse happening
			if (x == -1 && y == -1) a.x = GetWaves(coord + offset, p[0]); // If bottom-left-position, generate the height & save FBM coords
			else if (x == -1)       a.x = a.y;                            // If left-column, reuse TOP sample from previous iteration
			else                    a.x = r[y + 1];                       // If not left-column, reuse RIGHT sample from previous column
			
			if (x != -1 && y != 1) a.y = r[y + 2]; // If not left-column and not top-row, reuse RIGHT sample from previous column 1 row up
			else a.y = GetWaves(p[x + 1], vec2(0.0, offset.y + 0.2)); // If left-column or top-row, reuse previously computed FBM coords
			
			if (y == -1) a.z = GetWaves(coord + offset + vec2(0.1, 0.0), p[x + 2]); // If bottom-row, generate the height & save FBM coords
			else a.z = GetWaves(p[x + 2], vec2(0.0, offset.y + 0.1)); // If not bottom-row, reuse FBM coords
			
			r[y + 1] = a.z; // Save RIGHT height sample for later
			
			
			vec2 diff = a.x - a.yz;
			
			vec3 wavesNormal = vec3(diff, sqrt(1.0 - length2(diff))).yzx;
			
			vec3 refractVector = refract(-worldLightVector, wavesNormal, 1.0 / 1.3333);
			vec2 dist = refractVector.xz * (-verticalDist / refractVector.y) + (flatRefractVector.xz + offset);
			
			caustics += clamp01(length(dist) / distanceThreshold);
		}
	}
	
	caustics = 1.0 - caustics / 9.0;
	caustics *= 0.05 / pow2(distanceThreshold);
	
	return pow2(caustics);
}


#else
#define CalculateWaterCaustics(a, b) 1.0
#endif

vec3 CalculateShadedFragment(Mask mask, float torchLightmap, float skyLightmap, vec3 GI, vec3 normal, float smoothness, mat2x3 position) {
	Shading shading;
	skyLightmap = 1.0;
	shading.sunlight  = GetLambertianShading(normal, lightVector, mask) * skyLightmap;
	shading.sunlight  = ComputeSunlight(position[1], shading.sunlight);
	
	
	shading.torchlight  = 1.0 - pow(clamp01(torchLightmap - 0.075), 4.0);
	shading.torchlight  = 1.0 / pow(shading.torchlight, 2.0) - 1.0;
	shading.torchlight += GetHeldLight(position[0], normal, mask.hand);
	
	shading.skylight = pow2(skyLightmap);
	
#ifndef GI_ENABLED
	shading.skylight *= 1.5;
#endif
	
	shading.caustics = CalculateWaterCaustics(position[1], mask.water);
	
	shading.ambient  = 1.0 + (1.0 - eyeBrightnessSmooth.g / 240.0) * 1.7;
	shading.ambient += mask.nightVision * 50.0;
	
	
	Lightmap lightmap;
	
	lightmap.sunlight = shading.sunlight * shading.caustics * sunlightColor;
	
	lightmap.skylight = shading.skylight * pow(skylightColor, vec3(0.5));
	
	
	lightmap.GI = GI * sunlightColor;
	
	lightmap.ambient = vec3(shading.ambient);
	
	lightmap.torchlight = shading.torchlight * vec3(0.7, 0.3, 0.1);
	
	lightmap.skylight *= clamp01(1.0 - dot(lightmap.GI, vec3(1.0 / 3.0)) * 0.5);
	
	return vec3(
	    lightmap.sunlight   * 16.0  * SUN_LIGHT_LEVEL
	+   lightmap.skylight   * 1.8   * SKY_LIGHT_LEVEL * SKY_BRIGHTNESS
	+   lightmap.GI         * 1.0
	+   lightmap.ambient    * 0.015 * AMBIENT_LIGHT_LEVEL
	+   lightmap.torchlight * 6.0   * TORCH_LIGHT_LEVEL
	    );
}
