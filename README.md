### Radio

An interactive radio-frequency experience.

Live at [rafahcf.com](https://rafahcf.com).


### About

A single-page interactive experience modelled as an analog FM radio — tune the dial, sweep through the band, find stations hidden in the noise.

Audio is fully synthesised at runtime via the Web Audio API: sparse-noise static, bandpass filtering, and a heterodyne beat oscillator that tracks the distance to each station. The UI is built entirely in Dart with [Jaspr](https://docs.jaspr.site) and compiled to static HTML, CSS, and JavaScript — no runtime frameworks, no external UI libraries. Deployed as a static site on GitHub Pages.


### Technical highlights

- Server-side rendered to static HTML at build time via Jaspr; hydrated client-side for interactivity.
- All visual effects pure CSS: analog TV static, CRT scanlines, signal distortion, aged LCD panel with backlight unevenness and occasional glitches.
- Procedural audio via `dart:js_interop` over the Web Audio API — sparse-noise buffer sources, layered biquad filters, and a heterodyne oscillator whose frequency maps to detuning distance.
- Cross-platform dial interaction using pointer capture — drag, wheel, touch, and keyboard all drive the same tuning path.
- Bilingual content (ES/EN) resolved at render time with zero runtime dependencies.


### Stack

Jaspr · Dart · CSS · Web Audio API · GitHub Pages
