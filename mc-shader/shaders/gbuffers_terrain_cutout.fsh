#version 120

varying vec2 texcoord;
varying vec4 color;
varying vec3 vNormal;
varying vec2 lmcoord;
varying float vBlockId;

uniform sampler2D texture;
uniform vec3 sunPosition;
uniform vec3 upPosition;

const int BLOCK_EMISSIVE_SOLID = 1200;

float envLightFactor(vec2 lm) {
    float sky = clamp(lm.t, 0.0, 1.0);
    float torch = clamp(lm.s, 0.0, 1.0);
    return clamp(max(sky, torch*torch), 0.0, 1.0);
}

vec3 shade(vec3 c, vec3 n, float envL){
    vec3 N = normalize(n);
    vec3 sunDir = normalize(sunPosition);
    vec3 upDir  = normalize(upPosition);
    float sunUp = dot(sunDir, upDir);
    float day  = clamp(sunUp, 0.0, 1.0);
    float moon = clamp(-sunUp, 0.0, 1.0);
    vec3 L = (sunUp >= 0.0) ? sunDir : -sunDir;
    float wrap = mix(0.05, 0.35, day);
    float ndl = max((dot(N,L)+wrap)/(1.0+wrap), 0.0);
    float duskF = clamp(1.0 - abs(sunUp) / 0.30, 0.0, 1.0);
    vec3 dirTint = (sunUp >= 0.0)
        ? mix(vec3(1.00, 0.98, 0.94), vec3(1.00, 0.62, 0.32), duskF)
        : vec3(0.65, 0.72, 1.00);
    vec3 ambTint = mix(mix(vec3(0.66, 0.74, 1.00), vec3(0.90, 0.95, 1.05), day),
                       vec3(1.00, 0.76, 0.78), duskF * 0.6);
    float ambient = mix(0.08, mix(0.15, 0.59, day), envL);
    vec3 lit = ambTint * ambient + dirTint * (ndl * 0.47 * (day*1.0 + moon*0.06)); // softer foliage
    return clamp(c * lit, 0.0, 1.0);
}

void main() {
    vec4 albedo = texture2D(texture, texcoord) * color;
    vec3 baseColor = albedo.rgb;
    if (albedo.a < 0.1) discard;
    albedo.rgb = shade(albedo.rgb, vNormal, envLightFactor(lmcoord));

    float torch = clamp(lmcoord.s, 0.0, 1.0);
    float torchBoost = pow(torch, 1.5);
    const float TORCH_STRENGTH = 1.10;
    vec3 warmTint = vec3(1.00, 0.90, 0.75);
    vec3 warmBase = clamp(baseColor * warmTint, 0.0, 1.0);
    albedo.rgb = mix(albedo.rgb, warmBase, clamp(torchBoost * TORCH_STRENGTH, 0.0, 1.0));

    int blockId = int(vBlockId + 0.5);
    if (blockId == BLOCK_EMISSIVE_SOLID) {
        const float EMISSIVE_STRENGTH = 0.8;
        albedo.rgb = mix(albedo.rgb, baseColor, EMISSIVE_STRENGTH);
    }

    gl_FragData[0] = albedo;
}

/* DRAWBUFFERS:0 */
