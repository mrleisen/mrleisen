<p align="center">
  <a href="https://rafahcf.com">
    <img src=".github/assets/banner.svg" alt="Rafael Camargo - rafahcf.com" width="800">
  </a>
</p>

<h1 align="center">Rafael Camargo</h1>

<p align="center">
  <strong>Software engineer with 10+ years of experience. I build things - like this.</strong><br>
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
  <img src="https://img.shields.io/badge/JS_packages-none-F2EFE6?style=for-the-badge&labelColor=000" alt="No JavaScript package dependencies"/>
  <img src="https://img.shields.io/badge/Deploy-GitHub_Pages-181717?style=for-the-badge&logo=github&logoColor=white" alt="GitHub Pages"/>
</p>

<p align="center">
  <a href="https://rafahcf.com"><strong>► rafahcf.com</strong></a>
</p>

---

## About

This site is a single-page interactive radio-frequency simulator and personal portfolio. The receiver's static and whistle are synthesised at runtime through the Web Audio API, and its visual effects are pure CSS. The recorded audio is what you tune into: each of the fourteen stations broadcasts its own A Wired Spine track.

The application is written in **Dart** and compiled to static HTML, CSS, and JavaScript via the [Jaspr](https://docs.jaspr.site) framework, then deployed on GitHub Pages. Jaspr's client code is compiled with the app for hydration; there are no separately installed JavaScript packages or production application server.

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
- One stateful client island, with Jaspr compiled into the client output
- Pixel-art sprite data loaded on demand near the PIX station

</td>
<td width="50%">

### Audio
- Procedural synthesis via Web Audio API
- `dart:js_interop` for native browser calls
- Sparse-noise static + heterodyne whistle
- Mobile-safe unlock on power-switch gesture
- One A Wired Spine track per station, band-limited to sound like a radio, crossfaded under the static
- Ogg playback with MP3 fallback, remembered playback positions, and a master volume knob
- Now-playing song title on the faceplate, linked to the release when published

</td>
</tr>
<tr>
<td width="50%">

### Visual
- Pure CSS static, scanlines, vignette, phosphor mask
- CRT power-on/off animation (expanding scanline)
- LCD scramble and signal-scan sweep
- No canvas or WebGL; images are project logos and Pixel Art rewards
- Project logos distort with their station's transmission
- CSS pixel-art rails and tile-swapping puzzles on AM 1440

</td>
<td width="50%">

### Interaction
- Hardware-style rocker power switch
- FM / AM band toggle
- Pointer, touch, wheel, and keyboard tuning
- English / Spanish interface
- Fine-grain frequency locking
- MEM presets - save while locked, tap to recall, hold to clear
- Explicitly saved presets and solved pixel-art puzzles persist to `localStorage`
- Focus-trapped dialogs and reduced-motion support

</td>
</tr>
</table>

---

## Stack

| Layer          | Technology                                                   |
|----------------|--------------------------------------------------------------|
| **Language**   | Dart 3.10+                                                   |
| **Framework**  | Jaspr (static mode)                                          |
| **Browser interop** | `universal_web` + `dart:js_interop`                    |
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
| **Compiled client** | Tree-shaken Dart-to-JavaScript output, with deferred pixel-art sprite data |

---

## Signals

<p align="center">
  <strong>FM</strong> - featured long-form content<br>
  <code>88.9 &nbsp;·&nbsp; 91.9 &nbsp;·&nbsp; 94.9 &nbsp;·&nbsp; 97.9 &nbsp;·&nbsp; 100.9 &nbsp;·&nbsp; 103.9 &nbsp;·&nbsp; 106.9</code>
</p>

<p align="center">
  <strong>AM</strong> - idea-stage project cards and the Pixel Art gallery<br>
  <code>660 &nbsp;·&nbsp; 820 &nbsp;·&nbsp; 1000 &nbsp;·&nbsp; 1120 &nbsp;·&nbsp; 1280 &nbsp;·&nbsp; 1440 &nbsp;·&nbsp; 1600</code>
</p>

<p align="center">
  <sub>Fourteen stations across two bands. Each one carries a different signal and its own song.<br>Flip the power switch and tune in.</sub>
</p>

<p align="center">
  <sub>Lock on, hit <strong>MEM</strong> to save it to the rack. Tap a preset to recall, press and hold to wipe it.</sub>
</p>

The band plan lives in [`lib/models/station.dart`](lib/models/station.dart). FM spans 87.5–108.0 MHz in 0.1 MHz steps; AM spans 540–1700 kHz in 10 kHz steps. DMTFY is on FM 106.9; the pixel-art gallery and its puzzles are on AM 1440. The full station-to-song mapping and audio preparation notes are in [`web/audio/README.md`](web/audio/README.md).

### Controls

Switch the receiver on to unlock audio, then drag the tuning strip or use the mouse wheel. Each band remembers its tuned frequency during the session. The volume knob controls both the procedural receiver sound and the music.

| Key | Action while powered on |
|-----|-------------------------|
| Left / Right | Tune one step |
| Shift + Left / Right | Tune ten steps |
| B | Switch FM / AM |
| M | Save the locked station |
| 1–9 | Recall a saved preset in rack order |
| Escape | Close an open dialog |

Dialogs keep keyboard focus inside them while open. At PIX, select an artwork and swap tiles to solve its 3×3 puzzle and reveal the original PNG or animated GIF.

---

## Build

### Prerequisites

| Tool  | Version |
|-------|---------|
| Dart  | 3.10+   |

### Local development

```bash
# One-time: the Jaspr CLI is a global activation, not a dev dependency
dart pub global activate jaspr_cli 0.23.3

# Install dependencies
dart pub get

# Serve with hot reload
jaspr serve

# Build static output
jaspr build

# Regenerate the OG image
dart run tool/generate_og_image.dart

# Audit text contrast (WCAG AA)
dart run tool/check_contrast.dart

# Regenerate pixel-art metadata, deferred CSS sprites, and reward assets
dart run tool/generate_pixel_css.dart --dart

# Lint and format
dart analyze
dart format --line-length 120 .
```

The CLI version above matches [the deployment workflow](.github/workflows/deploy.yml) and Jaspr 0.23.3 in `pubspec.lock`. Keep the lockfile committed for reproducible dependency resolution. Generated `lib/main.*.options.dart` files are managed by Jaspr; do not edit them by hand.

The build output is written to `build/jaspr/` and is deployed automatically on push to `main` via `.github/workflows/deploy.yml` (GitHub Pages), or through a manual workflow run. The workflow copies `CNAME` (→ `rafahcf.com`) into the build output before publishing.

There is no automated test suite. The analyzer, contrast audit, and static build are the available code checks; browser interaction and audio playback need manual verification. The contrast audit checks the colour pairs declared in its script, not the entire rendered interface.

---

## Project structure

```
mrleisen/
├── lib/
│   ├── app.dart               # Root client island, single source of truth
│   ├── main.client.dart       # Client-side hydration entry
│   ├── main.server.dart       # SSR entry - document, head, global keyframes
│   ├── components/            # Jaspr components
│   │   ├── radio_audio.dart        # Web Audio graph and mobile-safe unlock
│   │   ├── radio_dial.dart         # Tuning dial, pointer capture, LCD scramble, MEM button
│   │   ├── station_display.dart    # Active-station content panels
│   │   ├── case_study.dart         # Long-form case-study printout dialog
│   │   ├── pixel_gallery.dart      # Artwork rails, 3×3 puzzles, original-image rewards
│   │   ├── rx_chrome.dart          # Shared dialog chrome + carrier-lost degradation
│   │   ├── signal_bars.dart        # Reception bars with power-on scan sweep
│   │   ├── collected_stations.dart # Preset rack: tap-to-recall, hold-to-delete
│   │   ├── static_noise.dart       # CSS static layer
│   │   ├── scanlines.dart          # CRT scanline overlay
│   │   ├── phosphor_mask.dart      # RGB phosphor subpixel mask
│   │   └── vignette.dart           # Ambient illumination
│   ├── models/
│   │   ├── station.dart       # Bands, stations, songs, logos, proximity math
│   │   ├── pixel_art.dart     # Generated sprite metadata
│   │   └── pixel_art_shadows.dart # Generated CSS box-shadows, loaded on demand
│   └── utils/
│       ├── keyboard.dart      # Enter/Space activation for role=button controls
│       └── motion.dart        # prefers-reduced-motion detection
├── tool/
│   ├── check_contrast.dart    # WCAG AA contrast audit (exits non-zero on failure)
│   ├── generate_og_image.dart # Regenerates web/og-image.png
│   └── generate_pixel_css.dart # Pixel Art station sprites from assets/pixel-art
├── assets/                    # Pixel-art sources and project-logo originals/provenance
├── web/                       # Static assets (favicon, manifest, icons, OG)
│   ├── audio/                 # Station programme, one .ogg + .mp3 per station (see its README)
│   ├── fonts/                 # Self-hosted fonts, declared in fonts.css
│   ├── logos/                 # Project marks displayed on station panels
│   └── pixel/                 # Original PNG/GIF puzzle rewards
├── .github/
│   ├── assets/                # Banner and branding
│   └── workflows/             # GitHub Pages deployment
├── pubspec.yaml
└── pubspec.lock               # Pinned application dependencies
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
