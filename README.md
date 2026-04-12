<p align="center">
  <a href="https://rafahcf.com">
    <img src=".github/assets/banner.svg" alt="Radio" width="800">
  </a>
</p>

<h1 align="center">Radio</h1>

<p align="center">
  <strong>An interactive radio-frequency experience, built entirely in Dart.</strong>
</p>

<p align="center">
  <a href="#about">About</a> •
  <a href="#how-it-works">How it works</a> •
  <a href="#stack">Stack</a> •
  <a href="#signals">Signals</a> •
  <a href="#build">Build</a>
</p>

<p align="center">
  <a href="https://dart.dev"><img src="https://img.shields.io/badge/Dart-3.10+-0175C2?style=for-the-badge&logo=dart&logoColor=white" alt="Dart"/></a>
  <a href="https://docs.jaspr.site"><img src="https://img.shields.io/badge/Jaspr-0.22-02569B?style=for-the-badge&logoColor=white" alt="Jaspr"/></a>
  <img src="https://img.shields.io/badge/Web_Audio_API-Enabled-FF6B00?style=for-the-badge&logoColor=white" alt="Web Audio API"/>
  <img src="https://img.shields.io/badge/Deploy-GitHub_Pages-181717?style=for-the-badge&logo=github&logoColor=white" alt="GitHub Pages"/>
</p>

<p align="center">
  <a href="https://rafahcf.com"><strong>► Live at rafahcf.com</strong></a>
</p>

---

## About

**Radio** is a single-page interactive experience that simulates tuning an analog FM receiver. Audio is synthesised at runtime through the Web Audio API, every visual effect is pure CSS, and the project ships with zero JavaScript runtime dependencies.

The entire codebase is written in **Dart** and compiled to static HTML, CSS, and JavaScript via the [Jaspr](https://docs.jaspr.site) framework, then deployed as a static site on GitHub Pages. No server. No framework bundle. No tracking.

> *Tune carefully. Some stations only appear when you stop looking for them.*

---

## How it works

<table>
<tr>
<td width="50%">

### Rendering
- Server-side generated at build time
- Client-side hydrated for interactivity
- Compiled from Dart to optimised JS
- Zero runtime dependencies

</td>
<td width="50%">

### Audio
- Procedural synthesis via Web Audio API
- `dart:js_interop` for native browser calls
- White-noise static, detuned carriers
- No prerecorded audio assets

</td>
</tr>
<tr>
<td width="50%">

### Visual
- Pure CSS analog static and CRT scanlines
- LCD aging and dial illumination effects
- No canvas, no WebGL, no images
- Responsive across desktop and mobile

</td>
<td width="50%">

### Interaction
- Pointer capture with momentum
- Touch gestures and mouse wheel
- Keyboard navigation support
- Fine-grain frequency locking

</td>
</tr>
</table>

---

## Stack

| Layer          | Technology                                                   |
|----------------|--------------------------------------------------------------|
| **Language**   | Dart 3.10+                                                   |
| **Framework**  | Jaspr (static mode)                                          |
| **Audio**      | Web Audio API via `dart:js_interop`                          |
| **Styling**    | Pure CSS (no preprocessors, no frameworks)                   |
| **Build**      | `build_runner` + `build_web_compilers`                       |
| **Deploy**     | GitHub Pages (static)                                        |

### Why Jaspr?

| Reason | Detail |
|--------|--------|
| **Single language** | UI, logic, and interop all written in Dart |
| **Static output** | Fully prerendered HTML with optional hydration |
| **Type safety** | Strong typing extends from DOM to audio graph |
| **Small payload** | Tree-shaken output, no runtime framework shipped |

---

## Signals

<p align="center">
  <code>87.5 &nbsp;·&nbsp; 91.3 &nbsp;·&nbsp; 95.7 &nbsp;·&nbsp; 99.1 &nbsp;·&nbsp; 103.5</code>
</p>

<p align="center">
  <sub>Five frequencies. Each one carries a different signal.<br>Tune in to find them.</sub>
</p>

---

## Build

### Prerequisites

| Tool  | Version |
|-------|---------|
| Dart  | 3.10+   |

### Local development

```bash
# Install dependencies
dart pub get

# Serve with hot reload
dart run jaspr serve

# Build static output
dart run jaspr build
```

The build output is written to `build/jaspr/` and is deployed automatically via GitHub Pages.

---

## Project structure

```
radio/
├── lib/
│   ├── app.dart               # Root component
│   ├── main.client.dart       # Client-side hydration entry
│   ├── main.server.dart       # Server-side rendering entry
│   ├── components/            # Jaspr components
│   │   ├── radio_audio.dart       # Web Audio synthesis
│   │   ├── radio_dial.dart        # Tuning dial and pointer capture
│   │   ├── station_display.dart   # LCD frequency readout
│   │   ├── signal_bars.dart       # Reception indicator
│   │   ├── static_noise.dart      # CSS static layer
│   │   ├── scanlines.dart         # CRT scanline overlay
│   │   └── vignette.dart          # Ambient illumination
│   └── models/
│       └── station.dart       # Station data model
├── web/                       # Static assets (favicon, manifest, icons)
├── .github/
│   ├── assets/                # Banner and branding
│   └── workflows/             # GitHub Pages deployment
└── pubspec.yaml
```

---

## License

All rights reserved.

---

<p align="center">
  <sub>Built with Jaspr · Dart · CSS · Web Audio API</sub>
</p>

<p align="center">
  <a href="https://rafahcf.com"><sub>rafahcf.com</sub></a>
</p>
