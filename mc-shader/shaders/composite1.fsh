#version 120

/* AO blur + apply. Reads the noisy SSAO estimate from colortex3 (written by
   composite), runs a 5x5 depth-aware blur so the per-pixel noise pattern
   disappears, then multiplies the result into the scene color. The depth
   weight stops AO from bleeding across silhouettes (sky vs terrain, near vs
   far geometry). AO must be applied BEFORE the water SSR pass (composite2) so
   reflections sample an already-occluded scene. */

varying vec2 texcoord;

uniform sampler2D colortex0; // scene color
uniform sampler2D colortex3; // raw AO
uniform sampler2D depthtex0;
uniform mat4 gbufferProjectionInverse;
uniform float viewWidth;
uniform float viewHeight;

// Debug: 1 = show blurred AO as grayscale, 0 = normal output.
#define AO_DEBUG 0
// How dark full occlusion gets (0 = off, 1 = AO fully multiplied in).
#define AO_STRENGTH 0.75
// View-space Z difference (blocks) beyond which a neighbor stops contributing.
#define AO_BLUR_DEPTH_TOL 0.6

float viewZ(vec2 uv) {
    float d = texture2D(depthtex0, uv).r;
    vec4 ndc = vec4(uv * 2.0 - 1.0, d * 2.0 - 1.0, 1.0);
    vec4 v = gbufferProjectionInverse * ndc;
    return v.z / v.w;
}

void main() {
    vec3 sceneColor = texture2D(colortex0, texcoord).rgb;
    float depth = texture2D(depthtex0, texcoord).r;

    float ao = 1.0;
    if (depth < 0.9999) {
        float cz = viewZ(texcoord);
        vec2 px = vec2(1.0 / viewWidth, 1.0 / viewHeight);

        float sum = 0.0;
        float wsum = 0.0;
        for (int x = -2; x <= 2; x++) {
            for (int y = -2; y <= 2; y++) {
                vec2 uv = texcoord + vec2(float(x), float(y)) * px;
                float zdiff = abs(viewZ(uv) - cz);
                float w = max(1.0 - zdiff / AO_BLUR_DEPTH_TOL, 0.0);
                sum += texture2D(colortex3, uv).r * w;
                wsum += w;
            }
        }
        // Center tap always has w=1, so wsum > 0 is guaranteed.
        ao = sum / wsum;
    }

#if AO_DEBUG == 1
    gl_FragData[0] = vec4(vec3(ao), 1.0);
    return;
#endif

    sceneColor *= mix(1.0, ao, AO_STRENGTH);
    gl_FragData[0] = vec4(sceneColor, 1.0);
}

/* DRAWBUFFERS:0 */
