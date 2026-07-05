# Progress

## Sky / sunset (gbuffers_skybasic)

Goal: improve the weak dusk/sunset sky, referencing the procedural sky in
`web-minecraft/src/sky.js`.

- Ported a multi-band dusk wash: ember below horizon → bright amber at the
  horizon → coral → magenta → deep violet zenith, driven by sun elevation
  (`duskF = 1 - |sunUp| / 0.3`), filling the whole sky and stronger toward the
  sun, plus a warm horizon glow hugging the sun.
- Fixed a hard horizontal seam at the horizon: the old shader based its color
  on the vanilla per-vertex `gl_Color`, but Minecraft renders the sky as two
  separate meshes (upper dome + lower void/fog plane) with different vertex
  colors, leaving a sharp line. Now the base day/night vertical gradient is
  computed analytically from the view-ray altitude `h`, so the seam is gone.
- Removed the old `worldTime`-based azure window and the unused `vColor`
  varying (sky is now driven purely by sun elevation, like the reference).

### Tuning knobs
- Day base color: `dayTop` / `dayHor` (currently the reference azure palette).
- Sunset band colors: `duskEmber/Amb/Coral/Mag/Zen` and their `smoothstep`
  ranges (wider/overlapping = softer transitions).
- Dusk extent: the `/ 0.30` divisor in `duskF` (larger = lingers higher).

### Possible next steps
- Sync the dusk color into water reflection / fog tint so lakes and distant
  terrain pick up the sunset warmth (see `out.reflectCol` / `out.fogColor` in
  the reference `sky.js`).

## Water — Fresnel reflection (gbuffers_water + composite)

Goal: Fresnel water — transparent looking straight down (near), reflective at
grazing angles (far). Two stages:

1. **Analytic sky reflection** (`gbuffers_water.fsh`): reflect the procedural
   sky off the surface and blend water tint ↔ sky by a Schlick Fresnel term
   (F0 = 0.02). Near/steep → transparent turquoise; grazing/far → sky mirror.
   The sky color reuses the same gradient as `gbuffers_skybasic` so water
   tracks day/night/sunset. Plus a restrained mirrored sun glint.
2. **Screen-space reflection of geometry** (`composite2.fsh`): reflect on-screen
   trees / terrain / entities, which only exist after the whole scene is drawn.
   View-space ray-march through the depth buffer; on a hit, blend the reflected
   scene color over the base by Fresnel; on a miss, keep the sky reflection.

Water detection in composite uses `depthtex0` (with translucents) vs
`depthtex1` (without): water = surface sits in front of opaque geometry behind
it. No aux buffer / color heuristic needed. Surface treated as a flat mirror
(normal = world up).

### Tuning knobs
- Transparency range: `mix(0.55, 0.93, fres)` alpha in `gbuffers_water.fsh`.
- SSR reach/precision: `SSR_STEPS` / `SSR_STEP0` / `SSR_GROW` in `composite2.fsh`.
- Hit tolerance: `SSR_THICKNESS` floor + the `lastStep * 1.6` scaling.
- Edge fade & Fresnel strength of the geometry reflection.

### Known limits
- SSR only reflects what is currently on screen (off-screen / occluded objects
  don't appear; reflections fade near screen edges). Inherent to SSR.
- Deep water with no visible bottom (lakebed beyond render distance) is not
  detected as water (the `d1 < 1.0` clouds-exclusion test also drops it).
- Flat mirror only — no ripple distortion yet.

## SSAO (composite + composite1)

Screen-space ambient occlusion with no normal G-buffer: view-space normals are
reconstructed from `depthtex0` (per axis, the neighbor with the smaller depth
delta wins, keeping silhouettes clean). 12 hemisphere samples on a golden-angle
spiral, rotated per pixel by interleaved gradient noise (no noise texture).

Pass layout (the old single composite got split):
1. `composite.fsh` — raw noisy AO → `colortex3` (every pixel written every
   frame, so no reliance on buffer clear values).
2. `composite1.fsh` — 5x5 depth-aware bilateral blur, then multiply into the
   scene color. Runs BEFORE SSR so water reflections include AO.
3. `composite2.fsh` — the water SSR pass (moved verbatim).

### Tuning knobs
- `SSAO_RADIUS` / `SSAO_SAMPLES` / `SSAO_BIAS` in `composite.fsh`.
- Overall darkening: `AO_STRENGTH` in `composite1.fsh`.
- Distance fade-out: `SSAO_MAX_DIST` (AO gone beyond ~64 blocks).
- Debug: `AO_DEBUG 1` in `composite1.fsh` shows the blurred AO in grayscale.

### Known limits
- Depth-only AO can't see behind foreground objects — thin geometry (fences,
  flowers) casts slightly exaggerated occlusion at some angles.
- Vanilla smooth lighting already bakes a coarse AO into vertex colors, so
  `AO_STRENGTH` is deliberately moderate.

## Atmosphere — aerial perspective + god rays (composite3)

Aerial perspective: non-sky pixels fade toward the procedural sky color
evaluated along their own view direction (`1 - exp(-(dist/far)^2 * density)`),
so distant terrain hazes blue at midday and picks up the sunset palette at
dusk; chunk edges melt into the sky. The sky gradient is a copy of
`gbuffers_skybasic.fsh` (OptiFine has no `#include` — keep them in sync).
Skipped underwater (the underwater tint in composite2 handles that).

God rays: screen-space radial march (24 taps, IGN-dithered start) from each
pixel toward the sun's projected screen position, accumulating sky visibility
with decay. Day + dusk only; no shadow map required.

### Tuning knobs
- Haze onset: `FOG_DENSITY` in `composite3.fsh`.
- Ray look: `GODRAY_STRENGTH` / `GODRAY_LENGTH` / `GODRAY_SAMPLES`.
- Debug: `ATMO_DEBUG 1` = fog amount, `2` = god-ray term only.

### Known limits
- God rays are screen-space: they vanish when the sun leaves the frame.
- Fog reaches only ~75% opacity at the render-distance edge (tunable).

## Marshmallow clouds (gbuffers_clouds)

Split across two passes. `gbuffers_clouds` does the soft SHADING: derivative
face normals (no trust in vertex data), heavily wrapped diffuse with a
powder-blue shadow color, rim light, world-anchored value noise for a cottony
surface. Palette follows sun elevation: milk white day, cotton-candy
pink/lavender dusk, deep blue night.

The rounded/fuzzy SILHOUETTE lives in `composite3` (screen space): cloud
pixels — translucent with only sky behind, gated to cloud altitudes so
glass/particles against sky are untouched — sample the cloud coverage of a
distance-scaled disk (24 golden-spiral taps). Coverage is ~1 inside, ~0.5 on
a straight edge, ~0.25 at an outer corner, so eroding low-coverage pixels
toward the analytic sky color rounds the blocky outline, and world-anchored
noise on the threshold grows fur. A texture-based approach in gbuffers was
tried first and failed: Sodium's cloud geometry carries no usable clouds.png
UV (see knowledge.md). Cloud pixels are exempt from aerial fog, which
otherwise washes out their shading at cloud distances.

### Tuning knobs
- Corner radius / fur raggedness: `CLOUD_ROUND_RADIUS` / `CLOUD_FUZZ` in
  `composite3.fsh`; altitude gate `CLOUD_Y_MIN/MAX`.
- Fluff amount/frequency: `FLUFF_AMOUNT` / `FLUFF_SCALE` in
  `gbuffers_clouds.fsh`.
- Softness of face shading: the wrap constant `0.6` and `pow(ndl, 0.8)`.
- Translucency: `CLOUD_ALPHA` (noise wobbles it ±0.06).
- Dusk palette: `litDusk` / `shdDusk`.
- Debug: `ATMO_DEBUG 3` in `composite3.fsh` shows the cloud-coverage term.

### Known limits
- Silhouette rounding only works against the sky: a cloud edge in front of
  terrain or another cloud keeps its sharp corner (the depth mask can't
  separate them there).
- Eroded pixels are repainted with the analytic sky, so a cloud edge crossing
  the sun/moon sprite erases the sprite in the eroded fringe.
- Water SSR (composite2) runs before this pass, so reflections show the
  un-rounded clouds.
- Noise is world-anchored while clouds drift, so the fur pattern slowly swims
  along a cloud edge. Subtle; looks alive rather than wrong.

## Night darkness & block-light glow (gbuffers_* lighting)

Two linked fixes across the 7 gbuffers variants that duplicate the lighting
code (terrain / terrain_solid / terrain_cutout / terrain_cutout_mip / solid /
cutout / basic):

1. Outdoor ambient now follows sun elevation: `mix(caveMin, mix(night, day
   Max, day), envL)` — night surface sits at ~0.16 instead of inheriting the
   full daytime 0.55 (the old formula only looked at the sky lightmap, which
   stays maxed outdoors at midnight).
2. Block-light boost curve steepened from `pow(torch, 0.35)` (nearly flat —
   ~0.86 strength at half distance, no visible falloff) to `pow(torch, 1.5)`,
   giving a bright pool at the emitter that fades with distance. Against the
   darker nights, glowstone/lanterns/torches now read as actual light
   sources.

### Tuning knobs
- Night surface brightness: the night constants (0.16 / 0.15 / 0.11 / 0.10
  per variant) in each `ambient` line.
- Glow radius/steepness: the `pow(torch, 1.5)` exponent (lower = wider glow).
- Glow intensity: `TORCH_STRENGTH` (1.10).

### Known limits
- The lighting function is still copy-pasted across the 7 gbuffers files —
  any tweak must be applied to all of them (no #include under OptiFine).
