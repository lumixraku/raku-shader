#version 120

/* Final pass: daytime color grade for a bright, golden-afternoon feel.
   Warm white balance + slight exposure lift + gentle S-curve contrast +
   saturation boost, all scaled by sun elevation so dusk/night keep their
   own palettes untouched. */

uniform sampler2D gcolor;
uniform vec3 sunPosition;
uniform vec3 upPosition;
varying vec2 texcoord; // from vsh

#define GRADE_WARMTH 1.0     // 0 = neutral, 1 = full golden white balance
#define GRADE_EXPOSURE 1.10  // daytime brightness lift
#define GRADE_CONTRAST 0.18  // S-curve strength (0..~0.4)
#define GRADE_SATURATION 1.15

void main() {
    vec3 col = texture2D(gcolor, texcoord).rgb;

    float day = clamp(dot(normalize(sunPosition), normalize(upPosition)), 0.0, 1.0);
    // Ramp the grade in with the sun well above the horizon, so the dusk
    // palette (already warm) isn't double-warmed.
    float gradeF = smoothstep(0.15, 0.40, day);

    // Golden white balance + exposure.
    col *= mix(vec3(1.0), vec3(1.05, 1.01, 0.94) * GRADE_EXPOSURE, gradeF * GRADE_WARMTH);

    // Gentle S-curve: darks a touch richer, mids lifted, no hard clip.
    col = clamp(col, 0.0, 1.0);
    col = mix(col, col * col * (3.0 - 2.0 * col), GRADE_CONTRAST * gradeF);

    // Saturation.
    float lum = dot(col, vec3(0.2126, 0.7152, 0.0722));
    col = mix(vec3(lum), col, mix(1.0, GRADE_SATURATION, gradeF));

    gl_FragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
