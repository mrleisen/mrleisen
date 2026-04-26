<p align="center">
  <a href="https://rafahcf.com">
    <img src=".github/assets/banner.svg" alt="Rafael Camargo — rafahcf.com" width="800">
  </a>
</p>

<h1 align="center">Rafael Camargo</h1>

<p align="center">
  <strong>Software engineer with 8+ years of experience. I build things — like this.</strong><br>
  <sub>Built entirely in Dart.</sub>
</p>

<p align="center">
  <a href="#about">About</a> •
  <a href="#how-it-was-built">How it was built</a> •
  <a href="#stack">Stack</a> •
  <a href="#signals">Signals</a> •
  <a href="#build">Build</a>
</p>

<p align="center">
  <a href="https://dart.dev"><img src="https://img.shields.io/badge/Dart-3.10+-0175C2?style=for-the-badge&logo=dart&logoColor=white" alt="Dart"/></a>
  <a href="https://docs.jaspr.site"><img src="https://img.shields.io/badge/Jaspr-0.23-02569B?style=for-the-badge&logoColor=white" alt="Jaspr"/></a>
  <img src="https://img.shields.io/badge/Web_Audio_API-Enabled-FF6B00?style=for-the-badge&logoColor=white" alt="Web Audio API"/>
  <img src="https://img.shields.io/badge/Runtime_deps-zero-F2EFE6?style=for-the-badge&labelColor=000" alt="No runtime deps"/>
  <img src="https://img.shields.io/badge/Deploy-GitHub_Pages-181717?style=for-the-badge&logo=github&logoColor=white" alt="GitHub Pages"/>
</p>

<p align="center">
  <a href="https://rafahcf.com"><strong>► rafahcf.com</strong></a>
</p>

---

## About

This site is a single-page interactive radio-frequency simulator. Audio is synthesised at runtime through the Web Audio API, every visual effect is pure CSS, and it ships with zero JavaScript runtime dependencies.

The entire codebase is written in **Dart** and compiled to static HTML, CSS, and JavaScript via the [Jaspr](https://docs.jaspr.site) framework, then deployed on GitHub Pages. No server. No framework bundle. No tracking.

It's a small demonstration of what I build: procedural audio, CSS-only visuals, type-safe browser interop, and a static build pipeline end-to-end.

---

## How it was built

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
- Sparse-noise static + heterodyne whistle
- Mobile-safe unlock on power-switch gesture
- No prerecorded audio assets

</td>
</tr>
<tr>
<td width="50%">

### Visual
- Pure CSS static, scanlines, vignette, phosphor mask
- CRT power-on/off animation (expanding scanline)
- LCD scramble and signal-scan sweep
- No canvas, no WebGL, no images

</td>
<td width="50%">

### Interaction
- Hardware-style rocker power switch
- FM / AM band toggle
- Pointer, touch, and wheel tuning
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
  <strong>FM</strong> — featured long-form content<br>
  <code>89.5 &nbsp;·&nbsp; 93.6 &nbsp;·&nbsp; 97.7 &nbsp;·&nbsp; 101.8 &nbsp;·&nbsp; 105.9</code>
</p>

<p align="center">
  <strong>AM</strong> — idea-stage project cards<br>
  <code>640 &nbsp;·&nbsp; 960 &nbsp;·&nbsp; 1280 &nbsp;·&nbsp; 1600</code>
</p>

<p align="center">
  <sub>Nine stations across two bands. Each one carries a different signal.<br>Flip the power switch and tune in.</sub>
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

# Regenerate the OG image
dart run tool/generate_og_image.dart

# Lint and format
dart analyze
dart format --line-length 120 .
```

The build output is written to `build/jaspr/` and is deployed automatically on push to `main` via `.github/workflows/deploy.yml` (GitHub Pages). The workflow copies `CNAME` (→ `rafahcf.com`) into the build output before publishing.

---

## Project structure

```
radio/
├── lib/
│   ├── app.dart               # Root client island, single source of truth
│   ├── main.client.dart       # Client-side hydration entry
│   ├── main.server.dart       # SSR entry — document, head, global keyframes
│   ├── components/            # Jaspr components
│   │   ├── radio_audio.dart       # Web Audio graph and mobile-safe unlock
│   │   ├── radio_dial.dart        # Tuning dial, pointer capture, LCD scramble
│   │   ├── station_display.dart   # Active-station content panels
│   │   ├── signal_bars.dart       # Reception bars with power-on scan sweep
│   │   ├── static_noise.dart      # CSS static layer
│   │   ├── scanlines.dart         # CRT scanline overlay
│   │   ├── phosphor_mask.dart     # RGB phosphor subpixel mask
│   │   └── vignette.dart          # Ambient illumination
│   └── models/
│       └── station.dart       # Stations, bands, proximity math
├── tool/
│   └── generate_og_image.dart # Regenerates web/og-image.png
├── web/                       # Static assets (favicon, manifest, icons, OG)
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
