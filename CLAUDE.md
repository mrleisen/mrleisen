# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Single-page interactive radio-frequency simulator (rafahcf.com). Written entirely in Dart, compiled to static HTML/CSS/JS via [Jaspr](https://docs.jaspr.site) in `static` mode, deployed to GitHub Pages.

## Commands

```bash
dart pub get                                 # install deps
dart run jaspr serve                         # local dev with hot reload
dart run jaspr build                         # static output → build/jaspr/
dart run tool/generate_og_image.dart         # regenerate web/og-image.png
dart analyze                                 # lints (recommended + jaspr_lints)
dart format --line-length 120 .              # format (page_width 120, trailing_commas preserve)
```

There are no tests in this project.

Deployment is automatic via `.github/workflows/deploy.yml` on push to `main` (runs `jaspr build`, copies `CNAME` into `build/jaspr/`, publishes to Pages).

## Architecture

The whole app is one stateful client island (`AppState` in `lib/app.dart`) holding a single source of truth: the current `_frequency` (85.0–108.0 MHz). Every visual and audio component is a pure function of that value plus a few derived scalars.

**Data flow per tune event:**
1. `_tune()` clamps + rounds the new frequency to 0.1 MHz, calls `_markTuning()` (sets `_isTuning = true`, arms a 400 ms idle timer to flip it back).
2. `_recalc()` derives `_signalStrength`, `_activeStation`, `_nearestStation`, `_noiseLevel` from `lib/models/station.dart` helpers.
3. Components re-render with new props; CSS animations and the Web Audio graph respond.

### Power state
`_isPowered` in `AppState` gates the entire radio experience. The radio starts off; a rocker switch (ON/OFF) in `.panel-header` toggles it. All content layers (StaticNoise, StationDisplay, Vignette, Scanlines, hero text, SignalBars) are gated on this flag — when off, the screen is black and the panel is dimmed (`.panel-off` on `.radio-panel`).

### Audio unlock (mobile-safe)
`AudioContext` is created **synchronously inside the power switch's click handler** (`unlockAudioContext()` in `radio_audio.dart`) and stored on `window.__radioAudioCtx`. This is the only reliable way to satisfy mobile browser autoplay policy — the context must be created and `resume()`d in the direct callstack of a user gesture on an actual DOM element. Dart's `_waitForJsContext()` polls for the global context and then builds the audio graph. The context is created once and reused across power toggles (never destroyed on power-off; gains are just ramped to zero).

**Station model (`lib/models/station.dart`)** is the canonical source for the 5 stations and three proximity zones used everywhere:
- `stationTolerance = 1.0 MHz` — outer edge where content/whistle/static start crossfading.
- `stationLockRange = 0.15 MHz` — inner zone where content is rendered fully clean.
- `getSignalStrength` / `getActiveStation` / `getNearestStation` / `noiseFromSignal` — keep this file the single source for distance math; don't duplicate the constants in components.

**Audio (`lib/components/radio_audio.dart`)** is a Web Audio graph built via `dart:js_interop` (`package:universal_web`). Two sparse-noise paths (high-pass crisp + low-pass body) sum into a master static gain, plus a heterodyne whistle oscillator whose frequency is `distanceToStation * 2000 Hz`. Audio unlock is handled by the power switch — see "Audio unlock" above. The document-level gesture listeners from the original design have been removed. `_applyState` gates on `isPowered`: when off, all gains are ramped to zero; the graph and sources stay alive for instant resume. `RadioAudio` is **deliberately not** marked `@client` — the parent `App` is already the client island, and nesting `@client` would create a second hydration island whose markers break the outer one.

**Visual layers** are all pure CSS — no canvas, no WebGL, no images:
- Keyframes are defined globally in `lib/main.server.dart` (the SSR entrypoint).
- Distortion intensity is driven through CSS custom properties (e.g. `--distortion`, `--tv-flicker-amp`) so a single keyframe scales smoothly from clean to chaotic via `calc()` — at value `0` the animation is a no-op, so applying it always is safe.
- Paint order in `App.build` matters: `StaticNoise → Scanlines → Vignette → SignalBars → content → StationDisplay → RadioDial`.
- **CRT effect** (`crt-on` / `crt-off` keyframes in `main.server.dart`): On power-on, a white horizontal line expands from the center (clip-path inset animation). On power-off, it collapses back. Managed by `_crtPhase` state in `AppState` ('off' | 'turning-on' | 'on' | 'turning-off').
- **Signal scanning** (`signal-scan` keyframe): On power-on, `SignalBars` plays a 2-second Knight Rider sweep (bars light sequentially with staggered animation-delay) before showing actual signal strength. Controlled by `_isScanning` state.
- **LCD scramble**: On power-on and LCD tap, digits rapidly show random frequencies (~8-10 iterations over 500-600ms) before settling on the actual value. Runs concurrently with `lcd-tap-glitch` opacity animation. Controlled by `_scrambleValue` / `_scrambleTimer` in `RadioDial` state.
- **LCD off state**: When `!isPowered`, the LCD shows no digits, no glow, no animation — just a dark unlit panel color.
- **Rocker switch**: Hardware-style ON/OFF toggle in `.panel-header` next to the indicator pills. Split rectangular track with embossed ON/OFF labels, amber glow on the active side.

**Entrypoints (Jaspr SSR + hydration):**
- `lib/main.server.dart` — server-rendered `Document`: global CSS reset, all keyframes, `<head>` (meta/OG/Twitter, manifest, fonts.css, favicons), then mounts `App()`.
- `lib/main.client.dart` — client hydration entry; uses generated `main.client.options.dart`.
- `*.options.dart` files are generated by `jaspr_builder` — do not edit by hand; run `dart run jaspr serve` or `build_runner` to regenerate.

## Conventions

- Lints: `package:lints/recommended.yaml` plus `jaspr_lints` with `prefer_html_components`, `sort_children_last`, `styles_ordering` enabled (see `analysis_options.yaml`).
- Styling: prefer Jaspr's typed `Styles(...)` API; drop to `raw: {...}` only for CSS features the typed API doesn't cover (`backdrop-filter`, `clip-path`, `text-shadow` combos, `calc()` with custom properties, multi-value `animation`).
- Don't add JS dependencies or runtime frameworks — the project's identity is "zero JS runtime deps, no images". Web Audio + CSS only.
- **Power-on sequence order**: rocker switch click → `unlockAudioContext()` (synchronous) → `onPowerToggle()` → `_crtPhase = 'turning-on'` → CRT animation plays → content layers fade in → SignalBars scanning → LCD scramble → audio graph built via `_waitForJsContext`.
