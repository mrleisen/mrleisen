/// The entrypoint for the **server** environment.
library;

import 'package:jaspr/dom.dart';
import 'package:jaspr/server.dart';

import 'app.dart';
import 'main.server.options.dart';

void main() {
  Jaspr.initializeApp(
    options: defaultServerOptions,
  );

  runApp(Document(
    title: 'Radio · rafahcf',
    styles: [
      // Global reset
      css('*, *::before, *::after').styles(
        margin: .zero,
        padding: .zero,
        boxSizing: .borderBox,
      ),
      // Base styles
      css('html, body').styles(
        width: 100.percent,
        height: 100.vh,
        overflow: Overflow.hidden,
        backgroundColor: const Color('#050507'),
        fontFamily: const FontFamily.list([FontFamilies.monospace]),
        color: const Color('#e0e0e0'),
      ),
      // Keyframe: fine-grain layer translation (very rapid step jumps).
      css.keyframes('tv-grain-shift', {
        '0%':   Styles(transform: Transform.translate(x: 0.px,    y: 0.px)),
        '12%':  Styles(transform: Transform.translate(x: (-3).px, y: 2.px)),
        '25%':  Styles(transform: Transform.translate(x: 4.px,    y: (-3).px)),
        '37%':  Styles(transform: Transform.translate(x: (-2).px, y: 4.px)),
        '50%':  Styles(transform: Transform.translate(x: 3.px,    y: 1.px)),
        '62%':  Styles(transform: Transform.translate(x: (-4).px, y: (-2).px)),
        '75%':  Styles(transform: Transform.translate(x: 2.px,    y: 3.px)),
        '87%':  Styles(transform: Transform.translate(x: (-3).px, y: (-4).px)),
        '100%': Styles(transform: Transform.translate(x: 1.px,    y: 0.px)),
      }),
      // Keyframe: coarse-pattern translation — slower & opposite tendency.
      css.keyframes('tv-coarse-shift', {
        '0%':   Styles(transform: Transform.translate(x: 0.px,    y: 0.px)),
        '16%':  Styles(transform: Transform.translate(x: 5.px,    y: (-4).px)),
        '33%':  Styles(transform: Transform.translate(x: (-6).px, y: 5.px)),
        '50%':  Styles(transform: Transform.translate(x: 4.px,    y: 6.px)),
        '66%':  Styles(transform: Transform.translate(x: (-5).px, y: (-3).px)),
        '83%':  Styles(transform: Transform.translate(x: 6.px,    y: 4.px)),
        '100%': Styles(transform: Transform.translate(x: (-2).px, y: 1.px)),
      }),
      // Keyframe: VHS tracking band sweep (slow top→bottom, with idle gap).
      css.keyframes('tv-band-sweep', {
        '0%':   Styles(raw: {'top': '-6px'}),
        '15%':  Styles(raw: {'top': '12%'}),
        '40%':  Styles(raw: {'top': '38%'}),
        '70%':  Styles(raw: {'top': '72%'}),
        '92%':  Styles(raw: {'top': '102%'}),
        '100%': Styles(raw: {'top': '102%'}),
      }),
      // Keyframe: whole-overlay flicker.
      // Sits at opacity 1 most of the time, dipping briefly. The dip depth
      // scales with `--tv-flicker-amp` (set per-instance), so a tuned-in
      // signal (`--tv-flicker-amp: 0`) yields no visible flicker at all.
      css.keyframes('tv-flicker', {
        '0%':   Styles(raw: {'opacity': '1'}),
        '8%':   Styles(raw: {'opacity': '1'}),
        '9%':   Styles(raw: {'opacity': 'calc(1 - 0.18 * var(--tv-flicker-amp, 0))'}),
        '10%':  Styles(raw: {'opacity': '1'}),
        '34%':  Styles(raw: {'opacity': '1'}),
        '35%':  Styles(raw: {'opacity': 'calc(1 - 0.32 * var(--tv-flicker-amp, 0))'}),
        '36%':  Styles(raw: {'opacity': '1'}),
        '63%':  Styles(raw: {'opacity': '1'}),
        '64%':  Styles(raw: {'opacity': 'calc(1 - 0.45 * var(--tv-flicker-amp, 0))'}),
        '66%':  Styles(raw: {'opacity': '1'}),
        '88%':  Styles(raw: {'opacity': '1'}),
        '89%':  Styles(raw: {'opacity': 'calc(1 - 0.22 * var(--tv-flicker-amp, 0))'}),
        '90%':  Styles(raw: {'opacity': '1'}),
        '100%': Styles(raw: {'opacity': '1'}),
      }),
      // Keyframe: bad-connection LCD glitch. 38 s cycle with two
      // bursts of rapid flickers separated by long stable periods.
      // Each flicker is 80–150 ms. Step-end timing makes the value
      // transitions snap rather than tween, which reads as an
      // actual electrical fault.
      //
      // Disabled when the panel carries `.lcd-locked` so a tuned-in
      // station stays clean.
      css.keyframes('lcd-glitch', {
        '0%':    Styles(raw: {'opacity': '1', 'transform': 'translateX(0)'}),
        // ─ BURST 1 (~1.5 s): 6 rapid flickers + 2 dim moments.
        '0.3%':  Styles(raw: {'opacity': '0.08'}),
        '0.5%':  Styles(raw: {'opacity': '1'}),
        '0.9%':  Styles(raw: {'opacity': '0.08'}),
        '1.1%':  Styles(raw: {'opacity': '1'}),
        '1.5%':  Styles(raw: {'opacity': '0.45'}),
        '1.7%':  Styles(raw: {'opacity': '1'}),
        '2.0%':  Styles(raw: {'opacity': '0.08', 'transform': 'translateX(-1px)'}),
        '2.2%':  Styles(raw: {'opacity': '1', 'transform': 'translateX(0)'}),
        '2.6%':  Styles(raw: {'opacity': '0.08'}),
        '2.8%':  Styles(raw: {'opacity': '1'}),
        '3.1%':  Styles(raw: {'opacity': '0.55'}),
        '3.3%':  Styles(raw: {'opacity': '1'}),
        '3.7%':  Styles(raw: {'opacity': '0.12'}),
        '3.9%':  Styles(raw: {'opacity': '1'}),
        // ─ long stable ~27 s ─
        // ─ BURST 2 (~0.85 s): 3 flickers + 1 dim moment.
        '75%':   Styles(raw: {'opacity': '0.08'}),
        '75.4%': Styles(raw: {'opacity': '1'}),
        '75.9%': Styles(raw: {'opacity': '0.08'}),
        '76.3%': Styles(raw: {'opacity': '0.4'}),
        '76.5%': Styles(raw: {'opacity': '1'}),
        '77%':   Styles(raw: {'opacity': '0.1'}),
        '77.2%': Styles(raw: {'opacity': '1'}),
        '100%':  Styles(raw: {'opacity': '1', 'transform': 'translateX(0)'}),
      }),
      // Keyframe: one-shot tap glitch. Fires on user click/tap on the
      // LCD — 5 rapid flickers + 2 dim moments across 0.8 s, like
      // physically tapping a loose connection. Runs even when
      // `.lcd-locked` is present (a tap is physical, not a signal
      // issue), via an inline `animation` override on the element.
      css.keyframes('lcd-tap-glitch', {
        '0%':   Styles(raw: {'opacity': '1'}),
        '6%':   Styles(raw: {'opacity': '0.08'}),
        '14%':  Styles(raw: {'opacity': '1'}),
        '22%':  Styles(raw: {'opacity': '0.08'}),
        '30%':  Styles(raw: {'opacity': '1'}),
        '38%':  Styles(raw: {'opacity': '0.4'}),
        '45%':  Styles(raw: {'opacity': '1'}),
        '52%':  Styles(raw: {'opacity': '0.08'}),
        '60%':  Styles(raw: {'opacity': '1'}),
        '68%':  Styles(raw: {'opacity': '0.08'}),
        '76%':  Styles(raw: {'opacity': '1'}),
        '84%':  Styles(raw: {'opacity': '0.3'}),
        '92%':  Styles(raw: {'opacity': '0.08'}),
        '96%':  Styles(raw: {'opacity': '1'}),
        '100%': Styles(raw: {'opacity': '1'}),
      }),
      // Keyframe: subtle horizontal jitter for content between stations.
      css.keyframes('content-jitter', {
        '0%':   Styles(transform: Transform.translate(x: 0.px)),
        '10%':  Styles(transform: Transform.translate(x: (-1).px)),
        '20%':  Styles(transform: Transform.translate(x: 2.px)),
        '30%':  Styles(transform: Transform.translate(x: (-2).px)),
        '40%':  Styles(transform: Transform.translate(x: 1.px)),
        '50%':  Styles(transform: Transform.translate(x: 0.px)),
        '60%':  Styles(transform: Transform.translate(x: 2.px)),
        '70%':  Styles(transform: Transform.translate(x: (-1).px)),
        '80%':  Styles(transform: Transform.translate(x: 1.px)),
        '90%':  Styles(transform: Transform.translate(x: (-2).px)),
        '100%': Styles(transform: Transform.translate(x: 0.px)),
      }),
      // ── Glitch / signal-distortion keyframes for station content ──
      // All three scale their amplitude through `calc(var(--distortion)
      // * …)` so running them with --distortion=0 is a no-op (clean
      // content), and running them with --distortion=1 is maximum
      // chaos. The animations themselves are only attached when the
      // panel is in the distortion zone (see station_display.dart).
      //
      // Horizontal VHS tracking jitter.
      css.keyframes('content-jitter-x', {
        '0%':   Styles(raw: {'transform': 'translateX(0)'}),
        '12%':  Styles(raw: {
          'transform': 'translateX(calc(var(--distortion, 0) * -3px))'
        }),
        '25%':  Styles(raw: {
          'transform': 'translateX(calc(var(--distortion, 0) * 2px))'
        }),
        '37%':  Styles(raw: {
          'transform': 'translateX(calc(var(--distortion, 0) * -1px))'
        }),
        '50%':  Styles(raw: {
          'transform': 'translateX(calc(var(--distortion, 0) * 3px))'
        }),
        '62%':  Styles(raw: {'transform': 'translateX(0)'}),
        '75%':  Styles(raw: {
          'transform': 'translateX(calc(var(--distortion, 0) * -2px))'
        }),
        '87%':  Styles(raw: {
          'transform': 'translateX(calc(var(--distortion, 0) * 1px))'
        }),
        '100%': Styles(raw: {'transform': 'translateX(0)'}),
      }),
      // Horizontal "tear" — chops the content into brief horizontal
      // bands. At distortion=0 every clip resolves to `inset(0)` and
      // nothing is cut.
      css.keyframes('content-tear', {
        '0%':   Styles(raw: {'clip-path': 'inset(0 0 0 0)'}),
        '6%':   Styles(raw: {
          'clip-path':
              'inset(calc(var(--distortion, 0) * 18%) 0 calc(var(--distortion, 0) * 68%) 0)',
        }),
        '10%':  Styles(raw: {'clip-path': 'inset(0 0 0 0)'}),
        '28%':  Styles(raw: {'clip-path': 'inset(0 0 0 0)'}),
        '31%':  Styles(raw: {
          'clip-path':
              'inset(calc(var(--distortion, 0) * 52%) 0 calc(var(--distortion, 0) * 24%) 0)',
        }),
        '34%':  Styles(raw: {'clip-path': 'inset(0 0 0 0)'}),
        '55%':  Styles(raw: {'clip-path': 'inset(0 0 0 0)'}),
        '58%':  Styles(raw: {
          'clip-path':
              'inset(calc(var(--distortion, 0) * 8%) 0 calc(var(--distortion, 0) * 82%) 0)',
        }),
        '61%':  Styles(raw: {'clip-path': 'inset(0 0 0 0)'}),
        '79%':  Styles(raw: {
          'clip-path':
              'inset(calc(var(--distortion, 0) * 72%) 0 calc(var(--distortion, 0) * 10%) 0)',
        }),
        '82%':  Styles(raw: {'clip-path': 'inset(0 0 0 0)'}),
        '100%': Styles(raw: {'clip-path': 'inset(0 0 0 0)'}),
      }),
      // Opacity flicker. Dips are scaled by --distortion so at 0 they
      // stay at 1 (no flicker) and at 1 they drop to ~0.4.
      css.keyframes('content-flicker', {
        '0%':   Styles(raw: {'opacity': '1'}),
        '18%':  Styles(raw: {'opacity': '1'}),
        '20%':  Styles(raw: {
          'opacity': 'calc(1 - var(--distortion, 0) * 0.55)'
        }),
        '23%':  Styles(raw: {'opacity': '1'}),
        '52%':  Styles(raw: {'opacity': '1'}),
        '55%':  Styles(raw: {
          'opacity': 'calc(1 - var(--distortion, 0) * 0.4)'
        }),
        '58%':  Styles(raw: {'opacity': '1'}),
        '81%':  Styles(raw: {'opacity': '1'}),
        '84%':  Styles(raw: {
          'opacity': 'calc(1 - var(--distortion, 0) * 0.5)'
        }),
        '87%':  Styles(raw: {'opacity': '1'}),
        '100%': Styles(raw: {'opacity': '1'}),
      }),
      // Keyframe: glitch effect
      css.keyframes('glitch', {
        '0%, 89%, 100%': Styles(
          opacity: 0.9,
          transform: Transform.translate(x: 0.px, y: 0.px),
          textShadow: TextShadow.none,
        ),
        '90%': Styles(
          textShadow: TextShadow.combine([
            TextShadow(offsetX: 2.px, offsetY: 0.px, color: const Color('#0ff')),
            TextShadow(offsetX: (-2).px, offsetY: 0.px, color: const Color('#f00')),
          ]),
          transform: Transform.translate(x: (-2).px, y: 1.px),
        ),
        '92%': Styles(
          textShadow: TextShadow.combine([
            TextShadow(offsetX: (-2).px, offsetY: 0.px, color: const Color('#0ff')),
            TextShadow(offsetX: 2.px, offsetY: 0.px, color: const Color('#f00')),
          ]),
          transform: Transform.translate(x: 2.px, y: (-1).px),
        ),
        '94%': Styles(
          opacity: 0.7,
          textShadow: TextShadow.combine([
            TextShadow(offsetX: 3.px, offsetY: 0.px, blur: 2.px, color: const Color('#0ff')),
            TextShadow(offsetX: (-3).px, offsetY: 0.px, blur: 2.px, color: const Color('#f00')),
          ]),
          transform: Transform.translate(x: (-1).px, y: 2.px),
        ),
        '96%': Styles(
          textShadow: TextShadow.combine([
            TextShadow(offsetX: (-1).px, offsetY: 0.px, color: const Color('#0ff')),
            TextShadow(offsetX: 1.px, offsetY: 0.px, color: const Color('#f00')),
          ]),
          transform: Transform.translate(x: 1.px, y: (-2).px),
        ),
        '98%': Styles(
          opacity: 0.85,
          textShadow: TextShadow.combine([
            TextShadow(offsetX: 1.px, offsetY: 0.px, color: const Color('#0ff')),
            TextShadow(offsetX: (-1).px, offsetY: 0.px, color: const Color('#f00')),
          ]),
          transform: Transform.translate(x: (-1).px, y: 0.px),
        ),
      }),
      // Keyframe: glitch alternate (second layer, offset timing)
      css.keyframes('glitch-alt', {
        '0%, 85%, 100%': Styles(
          transform: Transform.translate(x: 0.px, y: 0.px),
          raw: {'clip-path': 'inset(0 0 0 0)'},
        ),
        '86%': Styles(
          transform: Transform.translate(x: 3.px, y: 0.px),
          raw: {'clip-path': 'inset(20% 0 60% 0)'},
        ),
        '88%': Styles(
          transform: Transform.translate(x: (-3).px, y: 0.px),
          raw: {'clip-path': 'inset(50% 0 10% 0)'},
        ),
        '90%': Styles(
          transform: Transform.translate(x: 2.px, y: 0.px),
          raw: {'clip-path': 'inset(10% 0 70% 0)'},
        ),
        '92%': Styles(
          transform: Transform.translate(x: (-2).px, y: 0.px),
          raw: {'clip-path': 'inset(40% 0 30% 0)'},
        ),
      }),
      // Keyframe: pulse
      css.keyframes('pulse', {
        '0%, 100%': Styles(opacity: 0.25),
        '50%': Styles(opacity: 0.55),
      }),
    ],
    head: [
      link(rel: 'manifest', href: 'manifest.json'),
      // SVG favicon (modern browsers) + .ico fallback for legacy clients.
      link(rel: 'icon', type: 'image/svg+xml', href: '/favicon.svg'),
      link(rel: 'icon', type: 'image/x-icon', href: '/favicon.ico'),
      // Orbitron — geometric/digital display face used for the LCD.
      link(rel: 'preconnect', href: 'https://fonts.googleapis.com'),
      link(
        rel: 'preconnect',
        href: 'https://fonts.gstatic.com',
        attributes: {'crossorigin': ''},
      ),
      link(
        rel: 'stylesheet',
        href:
            'https://fonts.googleapis.com/css2?family=Orbitron:wght@700;900&family=IBM+Plex+Mono:wght@400;500;600&display=swap',
      ),
    ],
    body: App(),
  ));
}
