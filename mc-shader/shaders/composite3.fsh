#version 120

/* Atmosphere pass: aerial perspective fog + screen-space god rays.

   Aerial perspective: every non-sky pixel fades toward the procedural sky
   color evaluated along its own view direction, so distant terrain picks up
   blue haze at midday and the sunset palette at dusk, and chunk edges melt
   into the sky instead of popping. The sky function is a COPY of the gradient
   in gbuffers_skybasic.fsh (OptiFine has no #include — keep the two in sync;
   below the horizon it clamps to the horizon band, which is exactly the fog
   color we want).

   God rays: radial march from each pixel toward the sun's screen position,
   accumulating sky visibility with decay. Purely screen-space — no shadow
   map needed. Start offset is dithered with interleaved gradient noise to
   hide banding at 24 taps.

   Marshmallow cloud silhouette: cloud pixels (translucent with only sky
   behind — the same depth test the SSR pass uses to EXCLUDE clouds — gated
   to cloud altitudes so glass/particles against sky are untouched) sample
   the cloud-coverage of a distance-scaled disk around them. Coverage is ~1
   inside, ~0.5 on a straight silhouette edge, ~0.25 at an outer corner, so
   eroding low-coverage pixels toward the analytic sky rounds the blocky
   outline; world-anchored noise on the threshold grows fur. This lives here
   rather than in gbuffers_clouds because Sodium's cloud geometry carries no
   usable cloud-texture UV to locate cell boundaries. Cloud pixels are also
   exempt from aerial fog, which otherwise washes out their shading at cloud
   distances. */

varying vec2 texcoord;

uniform sampler2D colortex0;
uniform sampler2D depthtex0;
uniform sampler2D depthtex1;
uniform vec3 sunPosition;
uniform vec3 upPosition;
uniform vec3 cameraPosition;
uniform mat4 gbufferProjection;
uniform mat4 gbufferProjectionInverse;
uniform mat4 gbufferModelViewInverse;
uniform int isEyeInWater;
uniform float far;

// Debug: 1 = fog amount, 2 = god-ray term, 3 = cloud coverage, 0 = normal.
#define ATMO_DEBUG 0
#define FOG_DENSITY 1.4      // higher = haze starts closer
#define GODRAY_SAMPLES 24
#define GODRAY_STRENGTH 0.30
#define GODRAY_LENGTH 0.35   // max march distance in UV space
#define CLOUD_ROUND_RADIUS 5.5  // silhouette corner radius in blocks
#define CLOUD_FUZZ 0.5          // raggedness of the furry edge (0..1)
#define CLOUD_TAPS 24
#define CLOUD_Y_MIN 100.0       // altitude window that counts as clouds
#define CLOUD_Y_MAX 260.0

vec3 viewFromDepth(vec2 uv, float depth) {
    vec4 ndc = vec4(uv * 2.0 - 1.0, depth * 2.0 - 1.0, 1.0);
    vec4 v = gbufferProjectionInverse * ndc;
    return v.xyz / v.w;
}

float hash3(vec3 p) {
    return fract(sin(dot(p, vec3(127.1, 311.7, 74.7))) * 43758.5453);
}

// Trilinear 3D value noise (same as gbuffers_clouds).
float vnoise(vec3 p) {
    vec3 i = floor(p);
    vec3 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float n000 = hash3(i);
    float n100 = hash3(i + vec3(1.0, 0.0, 0.0));
    float n010 = hash3(i + vec3(0.0, 1.0, 0.0));
    float n110 = hash3(i + vec3(1.0, 1.0, 0.0));
    float n001 = hash3(i + vec3(0.0, 0.0, 1.0));
    float n101 = hash3(i + vec3(1.0, 0.0, 1.0));
    float n011 = hash3(i + vec3(0.0, 1.0, 1.0));
    float n111 = hash3(i + vec3(1.0, 1.0, 1.0));
    return mix(mix(mix(n000, n100, f.x), mix(n010, n110, f.x), f.y),
               mix(mix(n001, n101, f.x), mix(n011, n111, f.x), f.y), f.z);
}

/* --- procedural sky, copied from gbuffers_skybasic.fsh (keep in sync) --- */
vec3 skyColor(vec3 viewDir, vec3 sunDir, vec3 upDir) {
    float sunUp = dot(sunDir, upDir);
    float h = dot(viewDir, upDir);

    float dayF = smoothstep(-0.06, 0.16, sunUp);
    vec3 dayTop   = vec3(0.247, 0.561, 0.851);
    vec3 dayHor   = vec3(0.835, 0.910, 0.970);
    vec3 nightTop = vec3(0.012, 0.027, 0.078);
    vec3 nightHor = vec3(0.050, 0.070, 0.140);
    float t = clamp((h + 0.05) / 1.05, 0.0, 1.0);
    vec3 day   = mix(dayHor, dayTop, pow(t, 0.7));
    vec3 night = mix(nightHor, nightTop, pow(t, 0.6));
    vec3 col = mix(night, day, dayF);

    float duskF = clamp(1.0 - abs(sunUp) / 0.30, 0.0, 1.0);
    float sunFacing = max(dot(viewDir, sunDir), 0.0);

    vec3 duskGlow  = vec3(1.00, 0.42, 0.12);
    vec3 duskEmber = vec3(0.55, 0.16, 0.08);
    vec3 duskAmb   = vec3(1.00, 0.55, 0.18);
    vec3 duskCoral = vec3(0.95, 0.42, 0.30);
    vec3 duskMag   = vec3(0.62, 0.22, 0.42);
    vec3 duskZen   = vec3(0.24, 0.10, 0.32);
    vec3 sunset = duskEmber;
    sunset = mix(sunset, duskAmb,   smoothstep(-0.25, 0.02, h));
    sunset = mix(sunset, duskCoral, smoothstep(0.00, 0.35, h));
    sunset = mix(sunset, duskMag,   smoothstep(0.25, 0.70, h));
    sunset = mix(sunset, duskZen,   smoothstep(0.55, 1.05, h));

    float fill = duskF * (0.72 + 0.28 * pow(sunFacing, 2.0));
    col = mix(col, sunset, clamp(fill, 0.0, 1.0) * 0.92);
    col += duskGlow * duskF * pow(sunFacing, 3.0) * pow(max(1.0 - abs(h), 0.0), 5.0) * 0.45;
    return col;
}
/* --- end copy --- */

void main() {
    vec3 col = texture2D(colortex0, texcoord).rgb;
    float depth = texture2D(depthtex0, texcoord).r;

    vec3 sunDir = normalize(sunPosition);
    vec3 upDir  = normalize(upPosition);
    float sunUp = dot(sunDir, upDir);

    // --- marshmallow cloud silhouette: rounded corners + furry edges ---
    bool cloudPix = false;
    if (depth < 0.9999 && texture2D(depthtex1, texcoord).r >= 0.9999) {
        vec3 vp = viewFromDepth(texcoord, depth);
        vec3 wp = (gbufferModelViewInverse * vec4(vp, 1.0)).xyz + cameraPosition;
        if (wp.y > CLOUD_Y_MIN && wp.y < CLOUD_Y_MAX) {
            cloudPix = true;

            // Screen-space footprint of the world-space rounding radius,
            // capped for when the player flies right next to a cloud.
            vec2 rUV = CLOUD_ROUND_RADIUS * 0.5 / max(-vp.z, 1.0)
                     * vec2(gbufferProjection[0][0], gbufferProjection[1][1]);
            rUV = min(rUV, vec2(0.05));

            float jitter = 6.2831853 * fract(52.9829189
                * fract(dot(gl_FragCoord.xy, vec2(0.06711056, 0.00583715))));

            float cov = 0.0;
            for (int i = 0; i < CLOUD_TAPS; i++) {
                float fi = float(i) + 0.5;
                float ang = fi * 2.39996 + jitter;    // golden-angle spiral
                vec2 uv = texcoord
                    + vec2(cos(ang), sin(ang)) * sqrt(fi / float(CLOUD_TAPS)) * rUV;
                if (texture2D(depthtex0, uv).r < 0.9999
                    && texture2D(depthtex1, uv).r >= 0.9999) cov += 1.0;
            }
            cov /= float(CLOUD_TAPS);

#if ATMO_DEBUG == 3
            gl_FragData[0] = vec4(vec3(cov), 1.0);
            return;
#endif
            // Interior ~1, straight edge ~0.5, outer corner ~0.25. The lower
            // threshold sits close to the straight-edge value so corners are
            // cut hard while flat edges only feather — that contrast is what
            // reads as "rounded". Noise on the threshold grows the fur.
            float n = vnoise(wp * 0.7) * 0.6 + vnoise(wp * 2.1) * 0.4;
            float keep = smoothstep(0.36, 0.62, cov + (n - 0.5) * CLOUD_FUZZ);
            col = mix(skyColor(normalize(vp), sunDir, upDir), col, keep);
        }
    }

    // --- aerial perspective (skip sky pixels, clouds and underwater) ---
    if (depth < 0.9999 && isEyeInWater == 0 && !cloudPix) {
        vec3 viewPos = viewFromDepth(texcoord, depth);
        vec3 viewDir = normalize(viewPos);
        float dist = length(viewPos);

        float fogAmount = 1.0 - exp(-pow(dist / far, 2.0) * FOG_DENSITY);
        vec3 fogColor = skyColor(viewDir, sunDir, upDir);

#if ATMO_DEBUG == 1
        gl_FragData[0] = vec4(vec3(fogAmount), 1.0);
        return;
#endif
        col = mix(col, fogColor, fogAmount);
    }

    // --- screen-space god rays ---
    // Only when the light is meaningfully above the horizon and in front of
    // the camera. Uses the sun by day; skips night (moon rays look wrong
    // with this palette).
    float rayF = smoothstep(-0.05, 0.10, sunUp);
    vec4 sunClip = gbufferProjection * vec4(sunPosition, 1.0);
    if (rayF > 0.0 && sunClip.w > 0.0) {
        vec2 sunUV = sunClip.xy / sunClip.w * 0.5 + 0.5;

        vec2 toSun = sunUV - texcoord;
        float len = length(toSun);
        // focus is zero at len>=1, so skip the march entirely there.
        if (len > 1e-4 && len < 1.0) {
            toSun *= min(GODRAY_LENGTH / len, 1.0);   // cap march distance
            vec2 stepUV = toSun / float(GODRAY_SAMPLES);

            float jitter = fract(52.9829189
                * fract(dot(gl_FragCoord.xy, vec2(0.06711056, 0.00583715))));

            float illum = 0.0;
            float decay = 1.0;
            vec2 uv = texcoord + stepUV * jitter;
            for (int i = 0; i < GODRAY_SAMPLES; i++) {
                uv += stepUV;
                if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) break;
                if (texture2D(depthtex0, uv).r >= 0.9999) illum += decay;
                decay *= 0.94;
            }
            illum /= float(GODRAY_SAMPLES);

            // Tighter falloff away from the sun on screen.
            float focus = pow(clamp(1.0 - len, 0.0, 1.0), 2.0);
            float duskF = clamp(1.0 - abs(sunUp) / 0.30, 0.0, 1.0);
            vec3 rayColor = mix(vec3(1.00, 0.92, 0.75), vec3(1.00, 0.45, 0.15), duskF);

            float ray = illum * focus * rayF * GODRAY_STRENGTH;
#if ATMO_DEBUG == 2
            gl_FragData[0] = vec4(vec3(ray), 1.0);
            return;
#endif
            col += rayColor * ray;
        }
    }

    gl_FragData[0] = vec4(col, 1.0);
}

/* DRAWBUFFERS:0 */
