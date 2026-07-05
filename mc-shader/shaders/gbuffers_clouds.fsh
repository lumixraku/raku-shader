#version 120

/* Marshmallow cloud SHADING (the rounded/fuzzy silhouette lives in
   composite3 — Sodium's cloud renderer gives this pass no usable
   cloud-texture UV, so cell boundaries cannot be located here):
   - face normals from screen-space derivatives (no trust in vertex data);
   - heavily wrapped diffuse with powder-blue shadows instead of vanilla's
     flat gray faces;
   - rim light so edges look sun-lit-through;
   - world-anchored value noise for a cottony surface.
   Palette follows sun elevation like the sky shader: milk white by day,
   cotton-candy pink/lavender at dusk, deep blue at night. */

varying vec2 texcoord;
varying vec3 viewPos;

uniform sampler2D texture;
uniform vec3 sunPosition;
uniform vec3 upPosition;
uniform mat4 gbufferModelViewInverse;
uniform vec3 cameraPosition;

#define CLOUD_ALPHA 0.85
#define FLUFF_SCALE 0.45   // world-space noise frequency
#define FLUFF_AMOUNT 0.18  // brightness wobble

float hash3(vec3 p) {
    return fract(sin(dot(p, vec3(127.1, 311.7, 74.7))) * 43758.5453);
}

// Trilinear 3D value noise.
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

void main() {
    vec4 tex = texture2D(texture, texcoord);
    if (tex.a < 0.1) discard;

    // Flat-quad face normal from derivatives, made to face the eye.
    vec3 N = normalize(cross(dFdx(viewPos), dFdy(viewPos)));
    if (dot(N, -viewPos) < 0.0) N = -N;
    vec3 V = normalize(-viewPos);

    vec3 sunDir = normalize(sunPosition);
    vec3 upDir  = normalize(upPosition);
    float sunUp = dot(sunDir, upDir);
    vec3 L = (sunUp >= 0.0) ? sunDir : -sunDir;

    // Palette by sun elevation (same drivers as the sky shader).
    float dayF  = smoothstep(-0.06, 0.16, sunUp);
    float duskF = clamp(1.0 - abs(sunUp) / 0.30, 0.0, 1.0);

    vec3 litDay   = vec3(1.00, 1.00, 1.00);
    vec3 shdDay   = vec3(0.78, 0.85, 0.96);  // powder blue, not gray
    vec3 litNight = vec3(0.28, 0.32, 0.45);
    vec3 shdNight = vec3(0.15, 0.17, 0.28);
    vec3 litDusk  = vec3(1.00, 0.62, 0.55);  // peachy pink
    vec3 shdDusk  = vec3(0.58, 0.42, 0.64);  // lavender

    vec3 lit = mix(mix(litNight, litDay, dayF), litDusk, duskF * 0.85);
    vec3 shd = mix(mix(shdNight, shdDay, dayF), shdDusk, duskF * 0.85);

    // Marshmallow diffuse: strong wrap kills the hard terminator, then the
    // curve is flattened further so faces differ only gently.
    float ndl = clamp((dot(N, L) + 0.6) / 1.6, 0.0, 1.0);
    ndl = pow(ndl, 0.8);
    vec3 col = mix(shd, lit, ndl);

    // Rim: edges glow as if light bleeds through the fluff.
    float rim = pow(1.0 - max(dot(N, V), 0.0), 3.0);
    col += lit * rim * 0.30;

    // Cottony brightness wobble; world-anchored so it is 3D-consistent.
    vec3 wpos = (gbufferModelViewInverse * vec4(viewPos, 1.0)).xyz + cameraPosition;
    float n = vnoise(wpos * FLUFF_SCALE) * 0.65 + vnoise(wpos * FLUFF_SCALE * 3.1) * 0.35;
    col *= 1.0 - FLUFF_AMOUNT * 0.5 + FLUFF_AMOUNT * n;

    float alpha = CLOUD_ALPHA + (n - 0.5) * 0.12;

    gl_FragData[0] = vec4(clamp(col, 0.0, 1.0), clamp(alpha, 0.0, 1.0));
}

/* DRAWBUFFERS:0 */
