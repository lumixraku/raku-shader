#version 120

/* Screen-space reflections for water.
   Water is detected without any aux buffer: depthtex0 includes the
   translucent water surface, depthtex1 excludes it, so wherever the water
   surface sits in front of the opaque lakebed the two depths differ. The
   surface is a horizontal mirror whose normal is tilted by the same animated
   wave field as gbuffers_water (keep the two in sync), and we
   ray-march its reflection through the scene depth, blending the reflected
   scene color (trees, terrain, entities) over the base by Fresnel. On a miss
   we keep the base color, which already reflects the sky. */

varying vec2 texcoord;

uniform sampler2D colortex0; // scene color (incl. sky-reflected water)
uniform sampler2D depthtex0; // depth WITH translucents (water surface)
uniform sampler2D depthtex1; // depth WITHOUT translucents (lakebed)

uniform mat4 gbufferProjection;
uniform mat4 gbufferProjectionInverse;
uniform mat4 gbufferModelView;
uniform mat4 gbufferModelViewInverse;
uniform vec3 cameraPosition;
uniform float frameTimeCounter;
uniform int isEyeInWater;

// Debug: 1 = paint detected water magenta, 0 = normal SSR.
#define SSR_DEBUG 0

// March settings — many small steps with gentle growth; hit tolerance scales
// with the step so a large stride near the shore doesn't overshoot a surface.
#define SSR_STEPS 64
#define SSR_REFINE 6
#define SSR_STEP0 0.30
#define SSR_GROW 1.07
#define SSR_THICKNESS 0.50
#define WATER_EPS 0.05      // view-space surface/lakebed gap that means "water"

#define WAVE_STRENGTH 0.60   // normal tilt; 0 = calm flat mirror
#define WAVE_SPEED 0.8
#define WAVE_FADE_DIST 40.0  // waves flatten with distance (anti-shimmer)

// Animated wave height-field — COPY of gbuffers_water.fsh (OptiFine has no
// #include; keep the two in sync). Drifting noise octaves, not directional
// sines: sine sums interfere into a plaid/lattice pattern.
float whash2(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

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

float waveHeight(vec2 p, float t) {
    float h = 0.0;
    h += wnoise2(p * 0.22 + vec2( t * 0.50,  t * 0.28)) * 0.55;
    h += wnoise2(p * 0.55 + vec2(-t * 0.35,  t * 0.60)) * 0.30;
    h += wnoise2(p * 1.30 + vec2( t * 0.90, -t * 0.70)) * 0.15;
    return h;
}

vec2 waveGradient(vec2 p, float t) {
    const float e = 0.35;
    return vec2(waveHeight(p + vec2(e, 0.0), t) - waveHeight(p - vec2(e, 0.0), t),
                waveHeight(p + vec2(0.0, e), t) - waveHeight(p - vec2(0.0, e), t))
           / (2.0 * e);
}

vec3 viewFromDepth(vec2 uv, float depth) {
    vec4 ndc = vec4(uv * 2.0 - 1.0, depth * 2.0 - 1.0, 1.0);
    vec4 v = gbufferProjectionInverse * ndc;
    return v.xyz / v.w;
}

vec2 projectToUV(vec3 viewPos) {
    vec4 clip = gbufferProjection * vec4(viewPos, 1.0);
    return clip.xy / clip.w * 0.5 + 0.5;
}

// True where a translucent surface (water) sits in front of the opaque scene.
// Requires opaque geometry behind it (d1 < 1.0) so translucent clouds — which
// have only sky behind them — are not mistaken for water.
bool isWaterAt(vec2 uv, float d0) {
    if (d0 >= 0.9999) return false;
    float d1 = texture2D(depthtex1, uv).r;
    if (d1 >= 0.9999) return false;
    return viewFromDepth(uv, d0).z - viewFromDepth(uv, d1).z > WATER_EPS;
}

void main() {
    vec3 sceneColor = texture2D(colortex0, texcoord).rgb;
    float depth = texture2D(depthtex0, texcoord).r;

    bool water = isEyeInWater == 0 && isWaterAt(texcoord, depth);

#if SSR_DEBUG == 1
    if (water) { gl_FragColor = vec4(1.0, 0.0, 1.0, 1.0); return; }
#endif

    if (!water) {
        if (isEyeInWater == 1) {
            const vec3 limeTurquoise = vec3(0.30, 0.78, 0.55);
            sceneColor = mix(sceneColor, limeTurquoise, 0.12) * 0.96;
        }
        gl_FragColor = vec4(sceneColor, 1.0);
        return;
    }

    vec3 viewPos = viewFromDepth(texcoord, depth);  // water surface point
    vec3 V = normalize(-viewPos);                   // surface -> eye

    // Waved mirror: world up tilted by the animated wave gradient at this
    // surface point, fading with distance like gbuffers_water.
    vec3 wpos = (gbufferModelViewInverse * vec4(viewPos, 1.0)).xyz + cameraPosition;
    float fade = exp(-length(viewPos) / WAVE_FADE_DIST);
    vec2 g = waveGradient(wpos.xz, frameTimeCounter * WAVE_SPEED) * (WAVE_STRENGTH * fade);
    vec3 N = normalize(mat3(gbufferModelView) * normalize(vec3(-g.x, 1.0, -g.y)));
    vec3 rayDir = normalize(reflect(-V, N));        // reflected view ray
    // A wave tilt can send a grazing ray below the horizontal, marching down
    // into the lakebed; fall back to the flat mirror there.
    if ((mat3(gbufferModelViewInverse) * rayDir).y < 0.0) {
        N = normalize(mat3(gbufferModelView) * vec3(0.0, 1.0, 0.0));
        rayDir = normalize(reflect(-V, N));
    }

    float cosNV = clamp(dot(N, V), 0.0, 1.0);
    float fres = 0.02 + 0.98 * pow(1.0 - cosNV, 5.0);

    // --- ray-march in view space, hit refined by bisection ---
    vec3 p = viewPos, prev = p, hitView = p;
    float step = SSR_STEP0;
    bool hit = false;
    for (int i = 0; i < SSR_STEPS; i++) {
        prev = p;
        p += rayDir * step;
        float lastStep = step;
        step *= SSR_GROW;
        if (p.z >= 0.0) break;                       // behind the camera

        vec2 uv = projectToUV(p);
        if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) break;

        float sDepth = texture2D(depthtex0, uv).r;
        if (sDepth >= 0.9999) continue;              // sky: keep marching
        if (isWaterAt(uv, sDepth)) continue;         // don't reflect off water

        vec3 sView = viewFromDepth(uv, sDepth);
        float gap = sView.z - p.z;                   // >0 once behind a surface
        float thick = max(SSR_THICKNESS, lastStep * 1.6);
        if (gap > 0.0 && gap < thick) {
            vec3 a = prev, b = p;
            for (int j = 0; j < SSR_REFINE; j++) {
                vec3 m = (a + b) * 0.5;
                vec2 muv = projectToUV(m);
                if (viewFromDepth(muv, texture2D(depthtex0, muv).r).z - m.z > 0.0) b = m; else a = m;
            }
            hitView = b;
            hit = true;
            break;
        }
    }

    vec3 outColor = sceneColor;
    if (hit) {
        vec2 hitUV = projectToUV(hitView);
        vec3 reflCol = texture2D(colortex0, hitUV).rgb;
        vec2 e = smoothstep(0.0, 0.12, hitUV) * smoothstep(0.0, 0.12, 1.0 - hitUV);
        outColor = mix(sceneColor, reflCol, fres * e.x * e.y);
    }

    gl_FragColor = vec4(outColor, 1.0);
}
