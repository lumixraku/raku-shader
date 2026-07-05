#version 120

// Water pass — turquoise water with a Fresnel sky reflection and animated
// waves: transparent looking straight down (near water), mirror-like at
// grazing angles (distant water). The reflection samples the same procedural
// sky as gbuffers_skybasic, so the water tracks the day/night/sunset sky.
// Waves only perturb the NORMAL fed into the Fresnel/reflection math, so the
// near-transparent / far-mirror behavior is preserved.

varying vec2 texcoord;
varying vec4 color;
varying vec3 vNormal; // eye-space
varying vec3 vEyePos; // eye-space
varying float vBlockId;

uniform sampler2D texture;
uniform int isEyeInWater; // 0 = air, 1 = water
uniform vec3 sunPosition; // eye-space
uniform vec3 upPosition;  // eye-space
uniform mat4 gbufferModelView;
uniform mat4 gbufferModelViewInverse;
uniform vec3 cameraPosition;
uniform float frameTimeCounter;

#define WAVE_STRENGTH 0.60   // normal tilt; 0 = calm flat mirror
#define WAVE_SPEED 0.8
#define WAVE_FADE_DIST 40.0  // waves flatten with distance (anti-shimmer)

float whash2(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

// Bilinear 2D value noise with smoothstep fade (C1-continuous gradient).
float wnoise2(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = whash2(i);
    float b = whash2(i + vec2(1.0, 0.0));
    float c = whash2(i + vec2(0.0, 1.0));
    float d = whash2(i + vec2(1.0, 1.0));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

// Animated wave height: three octaves of value noise, each drifting in a
// DIFFERENT direction. Sums of a few directional sines were tried first and
// interfere into a plaid/lattice pattern — noise octaves never tile.
float waveHeight(vec2 p, float t) {
    float h = 0.0;
    h += wnoise2(p * 0.22 + vec2( t * 0.50,  t * 0.28)) * 0.55;
    h += wnoise2(p * 0.55 + vec2(-t * 0.35,  t * 0.60)) * 0.30;
    h += wnoise2(p * 1.30 + vec2( t * 0.90, -t * 0.70)) * 0.15;
    return h;
}

// Gradient (d/dx, d/dz) by central differences.
// COPIED in composite2.fsh — keep in sync.
vec2 waveGradient(vec2 p, float t) {
    const float e = 0.35;
    return vec2(waveHeight(p + vec2(e, 0.0), t) - waveHeight(p - vec2(e, 0.0), t),
                waveHeight(p + vec2(0.0, e), t) - waveHeight(p - vec2(0.0, e), t))
           / (2.0 * e);
}

// Procedural sky color for an eye-space view direction. Mirrors
// gbuffers_skybasic.fsh (day/night gradient + multi-band sunset wash) so the
// reflection matches the sky. Keep the two in sync.
vec3 skyColor(vec3 dir, vec3 upDir, vec3 sunDir, float sunUp) {
    float h = dot(dir, upDir);
    float dayF = smoothstep(-0.06, 0.16, sunUp);
    float t = clamp((h + 0.05) / 1.05, 0.0, 1.0);
    vec3 day   = mix(vec3(0.835, 0.910, 0.970), vec3(0.247, 0.561, 0.851), pow(t, 0.7));
    vec3 night = mix(vec3(0.050, 0.070, 0.140), vec3(0.012, 0.027, 0.078), pow(t, 0.6));
    vec3 col = mix(night, day, dayF);

    float duskF = clamp(1.0 - abs(sunUp) / 0.30, 0.0, 1.0);
    float sunFacing = max(dot(dir, sunDir), 0.0);
    vec3 sunset = vec3(0.55, 0.16, 0.08);
    sunset = mix(sunset, vec3(1.00, 0.55, 0.18), smoothstep(-0.25, 0.02, h));
    sunset = mix(sunset, vec3(0.95, 0.42, 0.30), smoothstep(0.00, 0.35, h));
    sunset = mix(sunset, vec3(0.62, 0.22, 0.42), smoothstep(0.25, 0.70, h));
    sunset = mix(sunset, vec3(0.24, 0.10, 0.32), smoothstep(0.55, 1.05, h));
    float fill = duskF * (0.72 + 0.28 * pow(sunFacing, 2.0));
    col = mix(col, sunset, clamp(fill, 0.0, 1.0) * 0.92);
    col += vec3(1.00, 0.42, 0.12) * duskF * pow(sunFacing, 3.0)
         * pow(max(1.0 - abs(h), 0.0), 5.0) * 0.45;
    return col;
}

void main() {
    vec4 albedo = texture2D(texture, texcoord) * color;

    // Only shade actual water blocks; pass anything else through untouched.
    const int BLOCK_WATER = 1000;
    int blockId = int(vBlockId + 0.5);
    bool isClassicWater = (blockId == 8 || blockId == 9);
    if (!(blockId == BLOCK_WATER || isClassicWater)) {
        gl_FragData[0] = albedo;
        return;
    }

    // Stable turquoise "see-through" color. Biased toward a fixed tint (not
    // the animated vanilla texture's luma) so the surface stays clean.
    const vec3 limeTurquoise = vec3(0.28, 0.67, 0.52);
    vec3 tinted = mix(albedo.rgb, limeTurquoise, 0.85);
    float lum = dot(tinted, vec3(0.2126, 0.7152, 0.0722));
    tinted = mix(vec3(lum), tinted, 0.75) * 0.90;
    vec3 waterCol = clamp(tinted, 0.0, 1.0);

    if (isEyeInWater == 0) {
        vec3 upDir  = normalize(upPosition);
        vec3 sunDir = normalize(sunPosition);
        float sunUp = dot(sunDir, upDir);

        // Animated wave normal: world-anchored gradient of the wave height
        // field, tilted less with distance so far water stays a clean mirror
        // and doesn't shimmer. Only up-facing surfaces wave — waterfall sides
        // keep their vertex normal (upF ~ 0 there).
        vec3 wpos = (gbufferModelViewInverse * vec4(vEyePos, 1.0)).xyz + cameraPosition;
        float fade = exp(-length(vEyePos) / WAVE_FADE_DIST);
        vec2 g = waveGradient(wpos.xz, frameTimeCounter * WAVE_SPEED) * (WAVE_STRENGTH * fade);
        vec3 waveN = normalize(mat3(gbufferModelView) * normalize(vec3(-g.x, 1.0, -g.y)));
        float upF = clamp(dot(normalize(vNormal), upDir), 0.0, 1.0);
        vec3 N = normalize(mix(normalize(vNormal), waveN, upF));

        vec3 I = normalize(vEyePos); // eye -> surface
        vec3 V = -I;                 // surface -> eye
        float cosNV = clamp(dot(N, V), 0.0, 1.0);

        // Schlick Fresnel with water's F0 (~0.02): ~0 looking straight down
        // (near / transparent), rising to ~1 at grazing angles (far / mirror).
        const float F0 = 0.02;
        float fres = F0 + (1.0 - F0) * pow(1.0 - cosNV, 5.0);

        // Reflect the procedural sky off the waved surface.
        vec3 R = normalize(reflect(I, N));
        vec3 reflSky = skyColor(R, upDir, sunDir, sunUp);

        vec3 col = mix(waterCol, reflSky, fres);

        // Restrained mirrored sun glint (strongest at grazing / sunset).
        float rd = max(dot(R, sunDir), 0.0);
        float day = clamp(sunUp, 0.0, 1.0);
        col += vec3(1.0, 0.96, 0.86) * pow(rd, 200.0) * (0.4 + 0.6 * day) * (0.3 + 0.7 * fres);

        albedo.rgb = clamp(col, 0.0, 1.0);
        // Transparent up close (bottom shows through), opaque at grazing.
        albedo.a = clamp(mix(0.55, 0.93, fres), 0.0, 0.95);
    } else {
        // Underwater, looking up at the surface: same wave normal (flipped
        // toward the viewer), water->air Fresnel with total internal
        // reflection — past the critical angle (~48.6 deg) the surface is a
        // mirror, straight up is the bright Snell window — plus a sun
        // sparkle refracted through the waves.
        vec3 upDir  = normalize(upPosition);
        vec3 sunDir = normalize(sunPosition);
        vec3 wpos = (gbufferModelViewInverse * vec4(vEyePos, 1.0)).xyz + cameraPosition;
        float fade = exp(-length(vEyePos) / WAVE_FADE_DIST);
        vec2 g = waveGradient(wpos.xz, frameTimeCounter * WAVE_SPEED) * (WAVE_STRENGTH * fade);
        vec3 waveUp = normalize(mat3(gbufferModelView) * normalize(vec3(-g.x, 1.0, -g.y)));

        vec3 I = normalize(vEyePos); // eye -> surface
        vec3 N = -waveUp;            // surface side facing the underwater eye
        float cosNV = clamp(dot(N, -I), 0.0, 1.0);

        // Snell: sin(air) = 1.33 * sin(water). sinT >= 1 means TIR.
        float sinT = 1.33 * sqrt(max(1.0 - cosNV * cosNV, 0.0));
        float fres = 1.0;
        if (sinT < 1.0) {
            float cosT = sqrt(1.0 - sinT * sinT);
            fres = 0.02 + 0.98 * pow(1.0 - cosT, 5.0);
        }

        // Snell window: daylight pouring in; TIR mirror: slightly deeper
        // water tint (kept gentle — too dark reads as scary, not deep).
        float day = clamp(dot(sunDir, upDir), 0.0, 1.0);
        vec3 windowCol = mix(waterCol, vec3(0.78, 0.96, 1.00), 0.65 * (0.30 + 0.70 * day));
        vec3 mirrorCol = waterCol * vec3(0.62, 0.78, 0.82);
        albedo.rgb = mix(windowCol, mirrorCol, fres);

        // Sparkle: refract the view ray out of the water and see how well it
        // lines up with the sun — waves wobble the alignment per pixel.
        // refract() returns vec3(0) under TIR, killing the term on its own.
        vec3 T = refract(I, N, 1.33);
        if (dot(T, T) > 0.0) {
            float spark = pow(max(dot(normalize(T), sunDir), 0.0), 48.0);
            albedo.rgb += vec3(1.0, 0.95, 0.80) * spark * (0.2 + 1.1 * day);
        }

        // Window fairly clear (the above-water world shows through), the
        // TIR mirror mostly opaque but not a solid wall.
        albedo.a = clamp(mix(0.30, 0.85, fres), 0.0, 0.90);
    }

    gl_FragData[0] = albedo;
}

/* DRAWBUFFERS:0 */
