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

  runApp(
    Document(
      // Crawlers and the browser tab both read this before any hydration
      // happens, so it carries the real identity rather than the model
      // number. `AppState` layers the tuned station on top once the
      // client takes over.
      title: 'Rafael Camargo - Software Engineer',
      // Base document language. The ES/EN toggle overrides this at
      // runtime via `Document.html`, but the served HTML has to declare
      // something or a screen reader picks its voice by guesswork.
      lang: 'en',
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
          raw: {
            // Mobile browsers bounce the page on an over-scroll and some
            // fire pull-to-refresh, both of which read as the receiver
            // coming loose from the screen while you drag the dial.
            'overscroll-behavior': 'none',
          },
        ),
        // Separate rule so `100vh` above stays as the fallback: browsers
        // that don't know `dvh` drop this declaration and keep it.
        //
        // `vh` is the *largest* viewport height on mobile, i.e. it
        // assumes the URL bar is hidden. The faceplate is pinned to the
        // bottom, so with the bar visible the panel's lower edge - the
        // power switch, the knobs - sits underneath it.
        css('html, body').styles(raw: {'height': '100dvh'}),
        // Keyframe: fine-grain layer translation (very rapid step jumps).
        css.keyframes('tv-grain-shift', {
          '0%': Styles(
            transform: Transform.translate(x: 0.px, y: 0.px),
          ),
          '12%': Styles(
            transform: Transform.translate(x: (-3).px, y: 2.px),
          ),
          '25%': Styles(
            transform: Transform.translate(x: 4.px, y: (-3).px),
          ),
          '37%': Styles(
            transform: Transform.translate(x: (-2).px, y: 4.px),
          ),
          '50%': Styles(
            transform: Transform.translate(x: 3.px, y: 1.px),
          ),
          '62%': Styles(
            transform: Transform.translate(x: (-4).px, y: (-2).px),
          ),
          '75%': Styles(
            transform: Transform.translate(x: 2.px, y: 3.px),
          ),
          '87%': Styles(
            transform: Transform.translate(x: (-3).px, y: (-4).px),
          ),
          '100%': Styles(
            transform: Transform.translate(x: 1.px, y: 0.px),
          ),
        }),
        // Keyframe: coarse-pattern translation - slower & opposite tendency.
        css.keyframes('tv-coarse-shift', {
          '0%': Styles(
            transform: Transform.translate(x: 0.px, y: 0.px),
          ),
          '16%': Styles(
            transform: Transform.translate(x: 5.px, y: (-4).px),
          ),
          '33%': Styles(
            transform: Transform.translate(x: (-6).px, y: 5.px),
          ),
          '50%': Styles(
            transform: Transform.translate(x: 4.px, y: 6.px),
          ),
          '66%': Styles(
            transform: Transform.translate(x: (-5).px, y: (-3).px),
          ),
          '83%': Styles(
            transform: Transform.translate(x: 6.px, y: 4.px),
          ),
          '100%': Styles(
            transform: Transform.translate(x: (-2).px, y: 1.px),
          ),
        }),
        // Keyframe: VHS tracking band sweep (slow top→bottom, with idle gap).
        css.keyframes('tv-band-sweep', {
          '0%': Styles(raw: {'top': '-6px'}),
          '15%': Styles(raw: {'top': '12%'}),
          '40%': Styles(raw: {'top': '38%'}),
          '70%': Styles(raw: {'top': '72%'}),
          '92%': Styles(raw: {'top': '102%'}),
          '100%': Styles(raw: {'top': '102%'}),
        }),
        // Keyframe: whole-overlay flicker.
        // Sits at opacity 1 most of the time, dipping briefly. The dip depth
        // scales with `--tv-flicker-amp` (set per-instance), so a tuned-in
        // signal (`--tv-flicker-amp: 0`) yields no visible flicker at all.
        css.keyframes('tv-flicker', {
          '0%': Styles(raw: {'opacity': '1'}),
          '8%': Styles(raw: {'opacity': '1'}),
          '9%': Styles(raw: {'opacity': 'calc(1 - 0.18 * var(--tv-flicker-amp, 0))'}),
          '10%': Styles(raw: {'opacity': '1'}),
          '34%': Styles(raw: {'opacity': '1'}),
          '35%': Styles(raw: {'opacity': 'calc(1 - 0.32 * var(--tv-flicker-amp, 0))'}),
          '36%': Styles(raw: {'opacity': '1'}),
          '63%': Styles(raw: {'opacity': '1'}),
          '64%': Styles(raw: {'opacity': 'calc(1 - 0.45 * var(--tv-flicker-amp, 0))'}),
          '66%': Styles(raw: {'opacity': '1'}),
          '88%': Styles(raw: {'opacity': '1'}),
          '89%': Styles(raw: {'opacity': 'calc(1 - 0.22 * var(--tv-flicker-amp, 0))'}),
          '90%': Styles(raw: {'opacity': '1'}),
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
          '0%': Styles(raw: {'opacity': '1', 'transform': 'translateX(0)'}),
          // ─ BURST 1 (~1.5 s): 6 rapid flickers + 2 dim moments.
          '0.3%': Styles(raw: {'opacity': '0.08'}),
          '0.5%': Styles(raw: {'opacity': '1'}),
          '0.9%': Styles(raw: {'opacity': '0.08'}),
          '1.1%': Styles(raw: {'opacity': '1'}),
          '1.5%': Styles(raw: {'opacity': '0.45'}),
          '1.7%': Styles(raw: {'opacity': '1'}),
          '2.0%': Styles(raw: {'opacity': '0.08', 'transform': 'translateX(-1px)'}),
          '2.2%': Styles(raw: {'opacity': '1', 'transform': 'translateX(0)'}),
          '2.6%': Styles(raw: {'opacity': '0.08'}),
          '2.8%': Styles(raw: {'opacity': '1'}),
          '3.1%': Styles(raw: {'opacity': '0.55'}),
          '3.3%': Styles(raw: {'opacity': '1'}),
          '3.7%': Styles(raw: {'opacity': '0.12'}),
          '3.9%': Styles(raw: {'opacity': '1'}),
          // ─ long stable ~27 s ─
          // ─ BURST 2 (~0.85 s): 3 flickers + 1 dim moment.
          '75%': Styles(raw: {'opacity': '0.08'}),
          '75.4%': Styles(raw: {'opacity': '1'}),
          '75.9%': Styles(raw: {'opacity': '0.08'}),
          '76.3%': Styles(raw: {'opacity': '0.4'}),
          '76.5%': Styles(raw: {'opacity': '1'}),
          '77%': Styles(raw: {'opacity': '0.1'}),
          '77.2%': Styles(raw: {'opacity': '1'}),
          '100%': Styles(raw: {'opacity': '1', 'transform': 'translateX(0)'}),
        }),
        // Keyframe: one-shot tap glitch. Fires on user click/tap on the
        // LCD - 5 rapid flickers + 2 dim moments across 0.8 s, like
        // physically tapping a loose connection. Runs even when
        // `.lcd-locked` is present (a tap is physical, not a signal
        // issue), via an inline `animation` override on the element.
        css.keyframes('lcd-tap-glitch', {
          '0%': Styles(raw: {'opacity': '1'}),
          '6%': Styles(raw: {'opacity': '0.08'}),
          '14%': Styles(raw: {'opacity': '1'}),
          '22%': Styles(raw: {'opacity': '0.08'}),
          '30%': Styles(raw: {'opacity': '1'}),
          '38%': Styles(raw: {'opacity': '0.4'}),
          '45%': Styles(raw: {'opacity': '1'}),
          '52%': Styles(raw: {'opacity': '0.08'}),
          '60%': Styles(raw: {'opacity': '1'}),
          '68%': Styles(raw: {'opacity': '0.08'}),
          '76%': Styles(raw: {'opacity': '1'}),
          '84%': Styles(raw: {'opacity': '0.3'}),
          '92%': Styles(raw: {'opacity': '0.08'}),
          '96%': Styles(raw: {'opacity': '1'}),
          '100%': Styles(raw: {'opacity': '1'}),
        }),
        // Keyframe: subtle horizontal jitter for content between stations.
        css.keyframes('content-jitter', {
          '0%': Styles(transform: Transform.translate(x: 0.px)),
          '10%': Styles(transform: Transform.translate(x: (-1).px)),
          '20%': Styles(transform: Transform.translate(x: 2.px)),
          '30%': Styles(transform: Transform.translate(x: (-2).px)),
          '40%': Styles(transform: Transform.translate(x: 1.px)),
          '50%': Styles(transform: Transform.translate(x: 0.px)),
          '60%': Styles(transform: Transform.translate(x: 2.px)),
          '70%': Styles(transform: Transform.translate(x: (-1).px)),
          '80%': Styles(transform: Transform.translate(x: 1.px)),
          '90%': Styles(transform: Transform.translate(x: (-2).px)),
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
          '0%': Styles(raw: {'transform': 'translateX(0)'}),
          '12%': Styles(raw: {'transform': 'translateX(calc(var(--distortion, 0) * -3px))'}),
          '25%': Styles(raw: {'transform': 'translateX(calc(var(--distortion, 0) * 2px))'}),
          '37%': Styles(raw: {'transform': 'translateX(calc(var(--distortion, 0) * -1px))'}),
          '50%': Styles(raw: {'transform': 'translateX(calc(var(--distortion, 0) * 3px))'}),
          '62%': Styles(raw: {'transform': 'translateX(0)'}),
          '75%': Styles(raw: {'transform': 'translateX(calc(var(--distortion, 0) * -2px))'}),
          '87%': Styles(raw: {'transform': 'translateX(calc(var(--distortion, 0) * 1px))'}),
          '100%': Styles(raw: {'transform': 'translateX(0)'}),
        }),
        // Horizontal "tear" - chops the content into brief horizontal
        // bands. At distortion=0 every clip resolves to `inset(0)` and
        // nothing is cut.
        css.keyframes('content-tear', {
          '0%': Styles(raw: {'clip-path': 'inset(0 0 0 0)'}),
          '6%': Styles(
            raw: {
              'clip-path': 'inset(calc(var(--distortion, 0) * 18%) 0 calc(var(--distortion, 0) * 68%) 0)',
            },
          ),
          '10%': Styles(raw: {'clip-path': 'inset(0 0 0 0)'}),
          '28%': Styles(raw: {'clip-path': 'inset(0 0 0 0)'}),
          '31%': Styles(
            raw: {
              'clip-path': 'inset(calc(var(--distortion, 0) * 52%) 0 calc(var(--distortion, 0) * 24%) 0)',
            },
          ),
          '34%': Styles(raw: {'clip-path': 'inset(0 0 0 0)'}),
          '55%': Styles(raw: {'clip-path': 'inset(0 0 0 0)'}),
          '58%': Styles(
            raw: {
              'clip-path': 'inset(calc(var(--distortion, 0) * 8%) 0 calc(var(--distortion, 0) * 82%) 0)',
            },
          ),
          '61%': Styles(raw: {'clip-path': 'inset(0 0 0 0)'}),
          '79%': Styles(
            raw: {
              'clip-path': 'inset(calc(var(--distortion, 0) * 72%) 0 calc(var(--distortion, 0) * 10%) 0)',
            },
          ),
          '82%': Styles(raw: {'clip-path': 'inset(0 0 0 0)'}),
          '100%': Styles(raw: {'clip-path': 'inset(0 0 0 0)'}),
        }),
        // Opacity flicker. Dips are scaled by --distortion so at 0 they
        // stay at 1 (no flicker) and at 1 they drop to ~0.4.
        css.keyframes('content-flicker', {
          '0%': Styles(raw: {'opacity': '1'}),
          '18%': Styles(raw: {'opacity': '1'}),
          '20%': Styles(raw: {'opacity': 'calc(1 - var(--distortion, 0) * 0.55)'}),
          '23%': Styles(raw: {'opacity': '1'}),
          '52%': Styles(raw: {'opacity': '1'}),
          '55%': Styles(raw: {'opacity': 'calc(1 - var(--distortion, 0) * 0.4)'}),
          '58%': Styles(raw: {'opacity': '1'}),
          '81%': Styles(raw: {'opacity': '1'}),
          '84%': Styles(raw: {'opacity': 'calc(1 - var(--distortion, 0) * 0.5)'}),
          '87%': Styles(raw: {'opacity': '1'}),
          '100%': Styles(raw: {'opacity': '1'}),
        }),
        // Keyframe: mem-flash
        // One-shot pulse on the MEM button after a successful save -
        // amber bloom that fades back to the armed/disabled style. Pure
        // box-shadow ramp so the underlying background stays steady.
        css.keyframes('mem-flash', {
          '0%': Styles(
            raw: {
              'box-shadow':
                  '0 0 0 0 rgba(232,160,53,0.0), '
                  'inset 0 1px 1px rgba(0,0,0,0.6)',
            },
          ),
          '20%': Styles(
            raw: {
              'box-shadow':
                  '0 0 8px 2px rgba(232,160,53,0.65), '
                  'inset 0 1px 1px rgba(0,0,0,0.6)',
            },
          ),
          '60%': Styles(
            raw: {
              'box-shadow':
                  '0 0 14px 4px rgba(232,160,53,0.35), '
                  'inset 0 1px 1px rgba(0,0,0,0.6)',
            },
          ),
          '100%': Styles(
            raw: {
              'box-shadow':
                  '0 0 0 0 rgba(232,160,53,0.0), '
                  'inset 0 1px 1px rgba(0,0,0,0.6)',
            },
          ),
        }),
        // Keyframe: signal-scan
        // Per-bar pulse used for the "searching for signal" animation on
        // the signal-strength meter. Each bar gets a staggered delay so
        // the group reads as a left→right sweep.
        css.keyframes('signal-scan', {
          '0%': Styles(opacity: 0.2),
          '50%': Styles(opacity: 1),
          '100%': Styles(opacity: 0.2),
        }),
        // Keyframe: carrier-sweep
        // Drives the idle-state band ribbon - a thin tracer moves across
        // the range marker suggesting automated search. 100% offscreen
        // right loops back to -10% for the next pass.
        css.keyframes('carrier-sweep', {
          '0%': Styles(raw: {'left': '-10%', 'opacity': '0'}),
          '8%': Styles(raw: {'opacity': '0.9'}),
          '92%': Styles(raw: {'opacity': '0.9'}),
          '100%': Styles(raw: {'left': '110%', 'opacity': '0'}),
        }),
        // Keyframe: carrier-breathe
        // Slow ±opacity wobble on the idle readout so the state doesn't
        // sit completely static. Reads as a receiver hum, not a blink.
        //
        // The amplitude used to be 0.55↔0.85, but the trough is what
        // decides the contrast of any text carrying this animation, and
        // 0.55 dragged `.carrier-sub` down to 1.64:1 - text that is
        // legible for only part of each cycle is not legible text. The
        // floor is now 0.85, which holds the dimmest carrier line at
        // 5.50:1 through the whole loop.
        css.keyframes('carrier-breathe', {
          '0%, 100%': Styles(opacity: 0.85),
          '50%': Styles(opacity: 1),
        }),
        // Keyframe: power-attract
        // Slow amber swell on the power rocker while the radio has never
        // been switched on. Everything on this page lives behind that one
        // 52x22 control, so if a first-time visitor doesn't find it they
        // see a black screen and leave. The pulse is deliberately slow
        // (2.4 s) and warm rather than a blink - it should read as a
        // standby lamp on the hardware, not as a notification badge.
        //
        // Retired for good the first time the radio is powered on, so a
        // returning visitor never sees it.
        css.keyframes('power-attract', {
          '0%, 100%': Styles(
            raw: {
              'box-shadow':
                  'inset 0 1px 3px rgba(0,0,0,0.75), '
                  '0 1px 0 rgba(255,255,255,0.05), '
                  '0 0 0 0 rgba(232,160,53,0.0)',
              'border-color': 'rgba(255,255,255,0.12)',
            },
          ),
          '50%': Styles(
            raw: {
              'box-shadow':
                  'inset 0 1px 3px rgba(0,0,0,0.75), '
                  '0 1px 0 rgba(255,255,255,0.05), '
                  '0 0 9px 2px rgba(232,160,53,0.42)',
              'border-color': 'rgba(232,160,53,0.55)',
            },
          ),
        }),
        // Keyframe: lock-flash
        // The capture beat. Snaps on hard - a lock is instantaneous, not
        // a fade - holds long enough to read, then clears. The brief
        // scale nudge at the start is the only movement; it reads as the
        // panel being driven rather than as an element animating in.
        css.keyframes('lock-flash', {
          '0%': Styles(raw: {'opacity': '0', 'transform': 'scaleY(0.72)'}),
          '6%': Styles(raw: {'opacity': '1', 'transform': 'scaleY(1)'}),
          '62%': Styles(raw: {'opacity': '1', 'transform': 'scaleY(1)'}),
          '100%': Styles(raw: {'opacity': '0', 'transform': 'scaleY(1)'}),
        }),
        // Keyframe: hint-fade-in
        // Brings the onboarding microcopy up gently once the receiver is
        // warm, so it reads as part of the boot sequence rather than as
        // something that popped in.
        css.keyframes('hint-fade-in', {
          '0%': Styles(raw: {'opacity': '0'}),
          '100%': Styles(raw: {'opacity': '1'}),
        }),
        // Keyframe: dash-drift
        // Slowly drifts the large dash array horizontally so the block
        // of dashes subtly moves like it's trying to track a phantom
        // carrier. Paired with a letter-opacity wave below.
        css.keyframes('dash-drift', {
          '0%, 100%': Styles(raw: {'transform': 'translateX(0)'}),
          '25%': Styles(raw: {'transform': 'translateX(-2px)'}),
          '50%': Styles(raw: {'transform': 'translateX(3px)'}),
          '75%': Styles(raw: {'transform': 'translateX(-1px)'}),
        }),
        // Keyframe: CRT turn-on
        // The first ~18% of the timeline is a chromatic convergence
        // stutter - the electron guns fire out of phase (red, green,
        // blue) before locking to white. The line then expands full
        // height, holds, and fades through a warm amber afterglow
        // (phosphor cooling) back to transparent.
        css.keyframes('crt-on', {
          '0%': Styles(
            opacity: 1,
            raw: {
              'background': '#ff3838',
              'clip-path': 'inset(50% 0 50% 0)',
            },
          ),
          '5%': Styles(
            opacity: 1,
            raw: {
              'background': '#ff3838',
              'clip-path': 'inset(49% 0 49% 0)',
            },
          ),
          '10%': Styles(
            opacity: 1,
            raw: {
              'background': '#38ff6a',
              'clip-path': 'inset(49% 0 49% 0)',
            },
          ),
          '14%': Styles(
            opacity: 1,
            raw: {
              'background': '#3860ff',
              'clip-path': 'inset(48% 0 48% 0)',
            },
          ),
          '18%': Styles(
            opacity: 1,
            raw: {
              'background': '#ffffff',
              'clip-path': 'inset(47% 0 47% 0)',
            },
          ),
          '40%': Styles(
            opacity: 1,
            raw: {
              'background': '#ffffff',
              'clip-path': 'inset(0% 0 0% 0)',
            },
          ),
          '62%': Styles(
            opacity: 0.8,
            raw: {
              'background':
                  'linear-gradient(180deg, rgba(255,255,255,0.95) 0%, rgba(255,210,130,0.85) 50%, rgba(255,255,255,0.95) 100%)',
              'clip-path': 'inset(0% 0 0% 0)',
            },
          ),
          '82%': Styles(
            opacity: 0.35,
            raw: {
              'background':
                  'radial-gradient(ellipse at center, rgba(255,200,110,0.55) 0%, rgba(60,30,5,0.3) 75%, transparent 100%)',
              'clip-path': 'inset(0% 0 0% 0)',
            },
          ),
          '100%': Styles(
            opacity: 0,
            raw: {
              'background': 'transparent',
              'clip-path': 'inset(0% 0 0% 0)',
              'pointer-events': 'none',
            },
          ),
        }),
        // Keyframe: CRT turn-off
        // Inverse of crt-on: flash white, collapse toward a horizontal
        // seam, then expand back to solid black as the "screen" goes dark.
        css.keyframes('crt-off', {
          '0%': Styles(
            opacity: 0,
            raw: {
              'background': 'transparent',
              'clip-path': 'inset(0% 0 0% 0)',
            },
          ),
          '15%': Styles(
            opacity: 1,
            raw: {
              'background': '#ffffff',
              'clip-path': 'inset(0% 0 0% 0)',
            },
          ),
          '45%': Styles(
            opacity: 1,
            raw: {
              'background': '#ffffff',
              'clip-path': 'inset(0% 0 0% 0)',
            },
          ),
          '75%': Styles(
            opacity: 1,
            raw: {
              'background': '#000000',
              'clip-path': 'inset(48% 0 48% 0)',
            },
          ),
          '100%': Styles(
            opacity: 1,
            raw: {
              'background': '#000000',
              'clip-path': 'inset(0% 0 0% 0)',
            },
          ),
        }),

        // ── Focus ──
        // One ring for every custom control on the faceplate, so keyboard
        // focus is never ambiguous and never inherits the user-agent blue
        // outline, which would look like a browser error on top of the
        // hardware.
        //
        // Amber to match the receiver's own indicator language, and drawn
        // with outline + offset rather than box-shadow so it survives on
        // controls that already spend their box-shadow budget on bevels
        // (the rocker, the knobs, the LCD).
        //
        // `:focus-visible` rather than `:focus`: a pointer user pressing
        // the power switch should not be left with a ring sitting on it.
        css(
          '.power-rocker:focus-visible, '
          '.lang-toggle:focus-visible, '
          '.dial-window:focus-visible, '
          '.vol-knob:focus-visible, '
          '.ind:focus-visible, '
          '.collected-pill:focus-visible, '
          '.pill:focus-visible, '
          '.tech-close:focus-visible',
        ).styles(
          raw: {
            'outline': '2px solid rgba(232,160,53,0.9)',
            'outline-offset': '3px',
            'border-radius': '4px',
          },
        ),
        // Suppress the default ring only where a replacement is drawn
        // above, never globally - a blanket `outline: none` is how sites
        // end up with invisible focus.
        css(
          '.power-rocker:focus:not(:focus-visible), '
          '.lang-toggle:focus:not(:focus-visible), '
          '.dial-window:focus:not(:focus-visible), '
          '.vol-knob:focus:not(:focus-visible), '
          '.ind:focus:not(:focus-visible), '
          '.collected-pill:focus:not(:focus-visible), '
          '.pill:focus:not(:focus-visible), '
          '.tech-close:focus:not(:focus-visible)',
        ).styles(raw: {'outline': 'none'}),

        // ── Reduced motion ──
        // The whole piece is built out of flicker, tearing and jitter, so
        // an unguarded visit is genuinely hostile to anyone sensitive to
        // motion. This block strips every running animation while leaving
        // the receiver fully operable: tuning, locking, saving, recalling
        // and every link all keep working, they just stop twitching.
        //
        // Jaspr 0.23 has no typed helper for this feature (it covers
        // prefers-color-scheme and prefers-contrast only), so the query is
        // written raw.
        //
        // The blanket `animation: none` is the backstop. Ahead of it we
        // also zero the two custom properties that scale distortion, since
        // several effects are driven through `calc()` on those rather than
        // through a keyframe: at 0 they collapse to a no-op, which kills
        // the chromatic split on titles and the blur on incoming panels
        // without needing to know every selector that reads them.
        css.media(const MediaQuery.raw('(prefers-reduced-motion: reduce)'), [
          css('*, *::before, *::after').styles(
            raw: {
              'animation': 'none !important',
              'transition-duration': '0.01ms !important',
            },
          ),
          // Kill the distortion maths, not just the keyframes.
          css(':root').styles(
            raw: {'--distortion': '0', '--tv-flicker-amp': '0'},
          ),
          // The CRT overlay animates via clip-path with fill-forwards, so
          // `animation: none` alone would strand it mid-wipe. Force the
          // two resting states explicitly instead.
          css('.crt-screen.crt-animate-on, .crt-screen.crt-on-done').styles(
            raw: {
              'opacity': '0',
              'background': 'transparent',
              'clip-path': 'none',
              'pointer-events': 'none',
            },
          ),
          css('.crt-screen.crt-animate-off, .crt-screen').styles(
            raw: {'clip-path': 'none'},
          ),
          // Panels cross-fade instead of tearing into focus.
          css('.panel-fx').styles(raw: {'filter': 'none'}),
          // The power rocker still has to be findable. With the pulse
          // gone it holds the lit end of that pulse permanently, so the
          // cue survives as contrast instead of as movement.
          css('.power-rocker.power-attract').styles(
            raw: {
              'box-shadow':
                  'inset 0 1px 3px rgba(0,0,0,0.75), '
                  '0 1px 0 rgba(255,255,255,0.05), '
                  '0 0 9px 2px rgba(232,160,53,0.42)',
              'border-color': 'rgba(232,160,53,0.55)',
            },
          ),
          // Hints appear at full strength rather than fading up.
          css('.power-hint, .tune-hint').styles(raw: {'opacity': '1'}),
          // Grain, scanlines and the phosphor mask stay as static texture:
          // they carry the CRT look but none of them need to move to do it.
          // The noise layer is the one exception - held still it reads as a
          // dirty screen, so it drops out entirely.
          css('.static-noise').styles(raw: {'opacity': '0'}),
        ]),
      ],
      head: [
        // Single canonical URL. GitHub Pages also answers on
        // mrleisen.github.io, so without this the two hostnames compete
        // as duplicates.
        link(rel: 'canonical', href: 'https://rafahcf.com/'),
        link(rel: 'manifest', href: 'manifest.json'),
        // SVG favicon (modern browsers) + .ico fallback for legacy clients.
        link(rel: 'icon', type: 'image/svg+xml', href: '/favicon.svg'),
        link(rel: 'icon', type: 'image/x-icon', href: '/favicon.ico'),
        // Orbitron - geometric/digital display face used for the LCD.
        // Self-hosted: no runtime dependency on Google Fonts.
        link(rel: 'stylesheet', href: 'fonts.css'),
        // Primary meta tags
        meta(name: 'title', content: 'Rafael Camargo - Software Engineer'),
        meta(
          name: 'description',
          content:
              'Software engineer with 10+ years of experience. I build things - like this. An interactive radio-frequency experience, built entirely in Dart using the Jaspr framework. No JavaScript. No external libraries.',
        ),
        // Open Graph / Facebook / LinkedIn
        meta(attributes: {'property': 'og:type', 'content': 'website'}),
        meta(attributes: {'property': 'og:url', 'content': 'https://rafahcf.com/'}),
        meta(
          attributes: {
            'property': 'og:title',
            'content': 'Rafael Camargo - Software Engineer',
          },
        ),
        meta(
          attributes: {
            'property': 'og:description',
            'content':
                'Software engineer with 10+ years of experience. I build things - like this. An interactive radio-frequency experience, built entirely in Dart using the Jaspr framework. No JavaScript. No external libraries.',
          },
        ),
        meta(
          attributes: {
            'property': 'og:image',
            'content': 'https://rafahcf.com/og-image.png',
          },
        ),
        // Twitter
        meta(name: 'twitter:card', content: 'summary_large_image'),
        meta(name: 'twitter:url', content: 'https://rafahcf.com/'),
        meta(name: 'twitter:title', content: 'Rafael Camargo - Software Engineer'),
        meta(
          name: 'twitter:description',
          content:
              'Software engineer with 10+ years of experience. I build things - like this. An interactive radio-frequency experience, built entirely in Dart using the Jaspr framework. No JavaScript. No external libraries.',
        ),
        meta(name: 'twitter:image', content: 'https://rafahcf.com/og-image.png'),
        // Structured data. The page is one interactive canvas with no
        // crawlable prose beyond the station panels, so an explicit
        // Person graph is the only way search engines learn who this is
        // and which profiles belong to the same person.
        script(
          attributes: {'type': 'application/ld+json'},
          content:
              '{'
              '"@context":"https://schema.org",'
              '"@type":"Person",'
              '"name":"Rafael Camargo",'
              '"jobTitle":"Software Engineer",'
              '"url":"https://rafahcf.com/",'
              '"sameAs":['
              '"https://github.com/mrleisen",'
              '"https://www.linkedin.com/in/rafael-c-a6132982/",'
              '"https://www.youtube.com/@InThisNewWorld",'
              '"https://www.instagram.com/tropelorio"'
              ']}',
        ),
      ],
      body: App(),
    ),
  );
}
