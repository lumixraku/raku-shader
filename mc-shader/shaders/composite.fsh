#version 120

/* SSAO — raw ambient-occlusion estimate, written to colortex3.
   This pack has no normal G-buffer, so the view-space normal is reconstructed
   from depthtex0 by comparing neighbor pixels (picking the smaller depth delta
   on each axis so normals stay clean at object silhouettes). Samples are a
   golden-angle spiral in the tangent plane, lifted along the normal into a
   hemisphere, rotated per pixel by interleaved gradient noise (no noise
   texture needed). The result here is NOISY by design — composite1 does a
   depth-aware blur before multiplying it into the scene color.
   Every pixel is written every frame, so no reliance on buffer clear values
   (Iris does not clear colortex reliably — see knowledge.md). */

varying vec2 texcoord;

uniform sampler2D depthtex0;
uniform mat4 gbufferProjection;
uniform mat4 gbufferProjectionInverse;
uniform float viewWidth;
uniform float viewHeight;

#define SSAO_SAMPLES 12
#define SSAO_RADIUS 0.8     // hemisphere radius in blocks
#define SSAO_BIAS 0.05      // view-space Z tolerance against self-occlusion
#define SSAO_MAX_DIST 64.0  // AO fully faded out at this view distance

vec3 viewFromDepth(vec2 uv, float depth) {
    vec4 ndc = vec4(uv * 2.0 - 1.0, depth * 2.0 - 1.0, 1.0);
    vec4 v = gbufferProjectionInverse * ndc;
    return v.xyz / v.w;
}

vec2 projectToUV(vec3 viewPos) {
    vec4 clip = gbufferProjection * vec4(viewPos, 1.0);
    return clip.xy / clip.w * 0.5 + 0.5;
}

vec3 viewAt(vec2 uv) {
    return viewFromDepth(uv, texture2D(depthtex0, uv).r);
}

// Normal from depth: on each axis take the neighbor whose depth is closer to
// the center, so silhouette edges don't produce garbage normals.
vec3 normalFromDepth(vec2 uv, vec3 c) {
    vec2 px = vec2(1.0 / viewWidth, 1.0 / viewHeight);
    vec3 r = viewAt(uv + vec2(px.x, 0.0));
    vec3 l = viewAt(uv - vec2(px.x, 0.0));
    vec3 u = viewAt(uv + vec2(0.0, px.y));
    vec3 d = viewAt(uv - vec2(0.0, px.y));
    vec3 dx = (abs(r.z - c.z) < abs(c.z - l.z)) ? (r - c) : (c - l);
    vec3 dy = (abs(u.z - c.z) < abs(c.z - d.z)) ? (u - c) : (c - d);
    vec3 N = normalize(cross(dx, dy));
    // A visible surface must face the eye.
    if (dot(N, -c) < 0.0) N = -N;
    return N;
}

void main() {
    float depth = texture2D(depthtex0, texcoord).r;
    if (depth >= 0.9999) {                    // sky: fully unoccluded
        gl_FragData[0] = vec4(1.0);
        return;
    }

    vec3 c = viewFromDepth(texcoord, depth);
    float dist = -c.z;
    if (dist > SSAO_MAX_DIST) {
        gl_FragData[0] = vec4(1.0);
        return;
    }

    vec3 N = normalFromDepth(texcoord, c);

    // Tangent frame around N.
    vec3 ref = (abs(N.z) < 0.99) ? vec3(0.0, 0.0, 1.0) : vec3(1.0, 0.0, 0.0);
    vec3 T = normalize(cross(ref, N));
    vec3 B = cross(N, T);

    // Interleaved gradient noise -> per-pixel spiral rotation.
    float noiseAng = 6.2831853
        * fract(52.9829189 * fract(dot(gl_FragCoord.xy, vec2(0.06711056, 0.00583715))));

    float occ = 0.0;
    for (int i = 0; i < SSAO_SAMPLES; i++) {
        float fi = float(i) + 0.5;
        float ang = fi * 2.39996 + noiseAng;             // golden angle
        float rad = SSAO_RADIUS * sqrt(fi / float(SSAO_SAMPLES));
        vec3 sp = c + (T * cos(ang) + B * sin(ang)) * rad
                    + N * (rad * 0.4 + SSAO_BIAS);       // lift into hemisphere

        if (sp.z >= 0.0) continue;                       // behind the camera
        vec2 suv = projectToUV(sp);
        if (suv.x < 0.0 || suv.x > 1.0 || suv.y < 0.0 || suv.y > 1.0) continue;

        float sd = texture2D(depthtex0, suv).r;
        if (sd >= 0.9999) continue;                      // sky never occludes
        float sz = viewFromDepth(suv, sd).z;

        // Occluded when scene geometry sits in front of the sample point;
        // range check kills halos from unrelated far-apart geometry.
        if (sz > sp.z + SSAO_BIAS) {
            float rangeCheck = smoothstep(0.0, 1.0, SSAO_RADIUS / abs(c.z - sz));
            occ += rangeCheck;
        }
    }

    float ao = 1.0 - occ / float(SSAO_SAMPLES);
    // Fade AO out with distance so far terrain isn't dirtied.
    float fade = 1.0 - smoothstep(SSAO_MAX_DIST * 0.6, SSAO_MAX_DIST, dist);
    ao = mix(1.0, ao, fade);

    gl_FragData[0] = vec4(vec3(ao), 1.0);
}

/* DRAWBUFFERS:3 */
