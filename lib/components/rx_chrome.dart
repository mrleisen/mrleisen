/// Shared chrome for the receiver's long-form printouts: the technical
/// transmission and the extended one.
///
/// Both panels sit above the content layers but below the faceplate, so
/// the dial stays reachable while one is open - which is the point, and
/// also the problem this file exists to solve. Tuning away used to leave
/// the printout sitting there in perfect condition while the carrier that
/// produced it was long gone: the receiver was claiming to be decoding
/// something it had lost.
///
/// So the panel is now wired to the same distance maths as the station
/// content behind it. Off lock it degrades; past the edge of the band it
/// declares the carrier gone and offers the dial back.
library;

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../utils/keyboard.dart';
import 'station_display.dart' show Lang;

/// How the station that produced an open printout is currently doing.
class RxSignalState {
  const RxSignalState({
    required this.signal,
    required this.powered,
    required this.frequencyLabel,
    this.onRetune,
  });

  /// 1.0 dead on the carrier, 0.0 nothing left.
  final double signal;

  /// The receiver itself. A printout left open across a power-off has not
  /// so much lost its signal as lost its radio, and says so.
  final bool powered;

  /// Spoken form of where the transmission came from: "FM 97.7 MHz".
  final String frequencyLabel;

  /// Sweeps the dial back to that station. Null when there is nothing
  /// sensible to sweep (the receiver is off).
  final VoidCallback? onRetune;

  /// Nothing at all is coming through.
  bool get lost => signal <= 0.0;

  /// Off the carrier but still within reach.
  bool get weak => !lost && signal < 0.995;

  /// 0 clean, 1 at the outer edge. Drives every scaled effect, exactly as
  /// it does on the station panels.
  double get distortion => (1.0 - signal).clamp(0.0, 1.0);

  /// Class suffix for the panel.
  String get panelClass => lost
      ? ' is-lost'
      : weak
      ? ' is-weak'
      : '';
}

/// Head of a printout: what it is on the left, how well it is coming in
/// on the right, and the way out.
///
/// The meter only appears once the signal has actually started to go. A
/// permanent "SIGNAL 100%" would be noise, and its arrival is the event
/// worth noticing.
Component rxHead({
  required String label,
  required Lang lang,
  required RxSignalState state,
  required VoidCallback onClose,
}) {
  final es = lang == Lang.es;
  final pct = (state.signal * 100).round();
  final lit = (state.signal * 4).ceil().clamp(0, 4);
  return div(classes: 'rx-head', [
    div(classes: 'rx-label', [Component.text(label)]),
    if (state.weak || state.lost)
      div(
        classes: 'rx-sig${state.lost ? ' rx-sig-lost' : ''}',
        [
          div(
            classes: 'rx-sig-bars',
            attributes: const {'aria-hidden': 'true'},
            [
              for (var i = 0; i < 4; i++) span(classes: 'rx-sig-bar${i < lit ? ' is-lit' : ''}', []),
            ],
          ),
          span(classes: 'rx-sig-text', [
            Component.text(
              state.lost ? (es ? 'SEÑAL PERDIDA' : 'SIGNAL LOST') : (es ? 'SEÑAL $pct%' : 'SIGNAL $pct%'),
            ),
          ]),
        ],
      ),
    div(
      classes: 'rx-close',
      events: {
        'click': (_) => onClose(),
        'keydown': onActivateKey((_) => onClose()),
      },
      attributes: {
        'role': 'button',
        'tabindex': '0',
        'aria-label': es ? 'Cerrar' : 'Close',
      },
      [Component.text('×')],
    ),
  ]);
}

/// The plate that takes over the panel once the carrier is gone.
///
/// Rendered directly under the head, and the panel stops scrolling while
/// it is up, so it cannot be scrolled past: a reader half way down a long
/// transmission when the dial moves gets the notice in front of them
/// rather than somewhere above.
Component rxLostPlate({
  required Lang lang,
  required RxSignalState state,
}) {
  final es = lang == Lang.es;
  final reason = !state.powered
      ? (es ? 'RECEPTOR APAGADO' : 'RECEIVER OFF')
      : '${state.frequencyLabel} · ${es ? 'sin portadora' : 'no carrier'}';
  return div(
    classes: 'rx-lost',
    attributes: const {'role': 'status'},
    [
      div(classes: 'rx-lost-title', [
        Component.text(es ? 'SEÑAL PERDIDA' : 'SIGNAL LOST'),
      ]),
      div(classes: 'rx-lost-reason', [Component.text(reason)]),
      p(classes: 'rx-lost-body', [
        Component.text(
          es
              ? 'Esta transmisión sigue en pantalla, pero el receptor ya no '
                    'la está recibiendo.'
              : 'This transmission is still on screen, but the receiver is '
                    'no longer picking it up.',
        ),
      ]),
      if (state.onRetune != null)
        div(
          classes: 'rx-lost-action',
          events: {
            'click': (_) => state.onRetune!(),
            'keydown': onActivateKey((_) => state.onRetune!()),
          },
          attributes: const {'role': 'button', 'tabindex': '0'},
          [Component.text(es ? 'Volver a sintonizar' : 'Retune')],
        ),
    ],
  );
}

/// How to get out of here, phrased for the input you actually have.
///
/// "ESC to close" is a keyboard instruction printed on a device with no
/// keyboard, which reads as boilerplate copied from somewhere else - the
/// one impression this piece cannot afford.
///
/// Both phrasings are rendered and CSS picks one on `(hover: hover) and
/// (pointer: fine)`, the same way the tuning hint does it. Resolving it
/// in CSS rather than sniffing the pointer in Dart keeps the server
/// output and the hydrated output identical. The touch wording is the
/// default, so a device that reports no capabilities at all still gets an
/// instruction it can follow: tapping the backdrop works everywhere,
/// including on the desktop where the keyboard hint shows instead.
Component rxHint(Lang lang) {
  final es = lang == Lang.es;
  return div(classes: 'rx-hint', [
    span(classes: 'rx-hint-fine', [
      Component.text(es ? 'ESC para cerrar' : 'ESC to close'),
    ]),
    span(classes: 'rx-hint-coarse', [
      Component.text(es ? 'Toca fuera para cerrar' : 'Tap outside to close'),
    ]),
  ]);
}

// ── styles ──
//
// Only the loss-of-signal chrome lives here. The rest of the `.rx-*`
// panel (overlay, panel body, head, title, data rows) is defined in
// `app.dart` alongside the technical transmission that first needed it.

@css
List<StyleRule> get rxChromeStyles => [
  // ── degradation ──
  // The same vocabulary the station panels use, at a fraction of the
  // amplitude. A printout is paper the receiver already produced, so it
  // should waver and wash out rather than tear itself apart; the tear
  // keyframe in particular is deliberately not used here, because
  // clipping a scroll container mid-read is disorienting rather than
  // atmospheric.
  css('.rx-panel').styles(
    raw: {
      'transition': 'filter 0.25s ease, border-color 0.25s ease, opacity 0.25s ease',
    },
  ),
  css('.rx-panel.is-weak').styles(
    raw: {
      'filter': 'blur(calc(var(--distortion, 0) * 1.4px)) saturate(calc(1 - var(--distortion, 0) * 0.45))',
      'border-color': 'color-mix(in srgb, #E05050 calc(var(--distortion, 0) * 45%), rgba(255,255,255,0.10))',
      'animation':
          'content-jitter-x 0.5s steps(8, end) infinite, '
          'content-flicker 1.1s steps(8, end) infinite',
    },
  ),
  css('.rx-panel.is-lost').styles(
    raw: {
      'border-color': 'rgba(224,80,80,0.45)',
      // Scrolling stops with the carrier. There is nothing readable left
      // to scroll to, and letting the panel keep scrolling would carry
      // the head - and with it the close button - off the top of the
      // screen, leaving the way out to Escape and a backdrop press on a
      // panel that just announced something went wrong.
      'overflow': 'hidden',
    },
  ),
  // Everything except the head and the plate goes out of focus. Not
  // hidden: the transmission is still there, it is simply no longer
  // being received, and blanking it would read as a bug rather than as
  // a lost carrier.
  css('.rx-panel.is-lost > *:not(.rx-head):not(.rx-lost)').styles(
    raw: {
      'filter': 'blur(4px) saturate(0.25)',
      'opacity': '0.28',
      'pointer-events': 'none',
      'transition': 'filter 0.3s ease, opacity 0.3s ease',
    },
  ),

  // ── signal meter in the head ──
  css('.rx-sig').styles(
    display: Display.flex,
    margin: Margin.only(left: Unit.auto, right: 12.px),
    flexDirection: FlexDirection.row,
    alignItems: AlignItems.center,
    gap: Gap(column: 8.px),
    raw: {'flex-shrink': '0'},
  ),
  css('.rx-sig-bars').styles(
    display: Display.flex,
    height: 12.px,
    flexDirection: FlexDirection.row,
    alignItems: AlignItems.end,
    gap: Gap(column: 2.px),
  ),
  css('.rx-sig-bar').styles(
    width: 3.px,
    height: 100.percent,
    radius: BorderRadius.all(Radius.circular(1.px)),
    backgroundColor: const Color('#2a2a32'),
    raw: {
      'transition': 'background 0.45s cubic-bezier(0.05, 0.8, 0.2, 1)',
    },
  ),
  css('.rx-sig-bar.is-lit').styles(
    backgroundColor: const Color('#E8A035'),
    raw: {
      'box-shadow': '0 0 4px rgba(232,160,53,0.6)',
      'transition': 'background 0.09s cubic-bezier(0.05, 0.8, 0.2, 1)',
    },
  ),
  css('.rx-sig-text').styles(
    // 5.9:1 on the panel. This is a status readout, not a decoration.
    color: const Color('#c99a4e'),
    fontFamily: const FontFamily.list([
      FontFamily('IBM Plex Mono'),
      FontFamilies.monospace,
    ]),
    fontSize: Unit.pixels(11),
    fontWeight: FontWeight.w600,
    textTransform: TextTransform.upperCase,
    letterSpacing: 0.16.em,
    raw: {'white-space': 'nowrap'},
  ),
  // Red, and slowly pulsing. The pulse is the only animated part of the
  // lost state, and it is the one that has to survive being glanced at.
  css('.rx-sig-lost .rx-sig-text').styles(
    color: const Color('#e87a7a'),
    raw: {
      'text-shadow': '0 0 6px rgba(224,80,80,0.4)',
      'animation': 'carrier-breathe 1.6s ease-in-out infinite',
    },
  ),

  // ── lost plate ──
  css('.rx-lost').styles(
    display: Display.flex,
    position: Position.relative(),
    zIndex: ZIndex(2),
    padding: Padding.symmetric(horizontal: 16.px, vertical: 16.px),
    margin: Margin.only(bottom: 16.px),
    radius: BorderRadius.all(Radius.circular(3.px)),
    flexDirection: FlexDirection.column,
    alignItems: AlignItems.start,
    gap: Gap(row: 8.px),
    raw: {
      'background': 'linear-gradient(160deg, rgba(38,12,12,0.96) 0%, rgba(20,8,8,0.96) 100%)',
      'border': '1px solid rgba(224,80,80,0.35)',
      'box-shadow':
          'inset 1px 1px 0 rgba(255,255,255,0.05), '
          'inset -1px -1px 0 rgba(0,0,0,0.5), '
          '2px 6px 18px rgba(0,0,0,0.55)',
    },
  ),
  css('.rx-lost-title').styles(
    color: const Color('#f0a0a0'),
    fontFamily: const FontFamily.list([
      FontFamily('Chakra Petch'),
      FontFamilies.sansSerif,
    ]),
    fontSize: Unit.pixels(16),
    fontWeight: FontWeight.w700,
    letterSpacing: 0.22.em,
    raw: {'text-shadow': '0 0 10px rgba(224,80,80,0.35)'},
  ),
  css('.rx-lost-reason').styles(
    color: const Color('#c99a9a'),
    fontFamily: const FontFamily.list([
      FontFamily('IBM Plex Mono'),
      FontFamilies.monospace,
    ]),
    fontSize: Unit.pixels(11),
    fontWeight: FontWeight.w500,
    textTransform: TextTransform.upperCase,
    letterSpacing: 0.16.em,
  ),
  css('.rx-lost-body').styles(
    color: const Color('#a89a94'),
    fontFamily: const FontFamily.list([
      FontFamily('IBM Plex Mono'),
      FontFamilies.monospace,
    ]),
    fontSize: Unit.pixels(13),
    raw: {'line-height': '1.55', 'margin': '0', 'max-width': '46ch'},
  ),
  // Same physical pill as everywhere else, in the fault colour.
  css('.rx-lost-action', [
    css('&').styles(
      display: Display.inlineFlex,
      minHeight: 44.px,
      padding: Padding.symmetric(horizontal: 16.px, vertical: 10.px),
      radius: BorderRadius.all(Radius.circular(99.px)),
      cursor: Cursor.pointer,
      alignItems: AlignItems.center,
      color: const Color('#f0c0a0'),
      fontFamily: const FontFamily.list([
        FontFamily('IBM Plex Mono'),
        FontFamilies.monospace,
      ]),
      fontSize: Unit.pixels(11),
      fontWeight: FontWeight.w600,
      textTransform: TextTransform.upperCase,
      letterSpacing: 0.15.em,
      raw: {
        'border': '1px solid rgba(232,160,53,0.35)',
        'background': 'linear-gradient(160deg, #1c1616 0%, #110d0d 100%)',
        'box-shadow':
            'inset 1px 1px 0 rgba(255,255,255,0.06), '
            'inset -1px -1px 0 rgba(0,0,0,0.5), '
            '1px 2px 6px rgba(0,0,0,0.4)',
        'transition':
            'border-color var(--dur-plastic) var(--ease-plastic), '
            'background var(--dur-plastic) var(--ease-plastic), '
            'box-shadow var(--dur-plastic) var(--ease-plastic)',
        'user-select': 'none',
        '-webkit-user-select': 'none',
        'touch-action': 'manipulation',
        '-webkit-tap-highlight-color': 'transparent',
      },
    ),
    css('&:active').styles(
      raw: {'box-shadow': 'inset 3px 3px 4px rgba(0,0,0,0.85)'},
    ),
  ]),

  // Hover only where hovering exists - see the note in
  // `station_display.dart`. On WebKit these rules are what made the first
  // tap a hover reveal instead of a press.
  css.media(const MediaQuery.raw('(hover: hover)'), [
    css('.rx-lost-action:hover').styles(
      raw: {
        'border-color': 'rgba(232,160,53,0.6)',
        'box-shadow': 'inset 2px 2px 3px rgba(0,0,0,0.7)',
      },
    ),
  ]),

  // Pointer-dependent phrasing for the way out. Default to touch and let
  // a real hover-capable pointer opt into the keyboard version.
  css('.rx-hint-fine').styles(display: Display.none),
  css.media(const MediaQuery.raw('(hover: hover) and (pointer: fine)'), [
    css('.rx-hint-fine').styles(display: Display.inline),
    css('.rx-hint-coarse').styles(display: Display.none),
  ]),

  css.media(MediaQuery.screen(maxWidth: 600.px), [
    // The head has three things in it on a phone and the middle one is
    // the newcomer, so it gives up its bars first.
    css('.rx-sig-bars').styles(display: Display.none),
    css('.rx-sig').styles(
      margin: Margin.only(left: Unit.auto, right: 8.px),
    ),
    css('.rx-sig-text').styles(letterSpacing: 0.08.em),
    css('.rx-lost').styles(
      padding: Padding.symmetric(horizontal: 12.px, vertical: 12.px),
    ),
    css('.rx-lost-title').styles(fontSize: Unit.pixels(14), letterSpacing: 0.16.em),
    // The touch wording is twice the length of "ESC to close", so the
    // tracking comes in to keep it on one line at 360px.
    css('.rx-hint').styles(letterSpacing: 0.12.em),
  ]),

  // Reduced motion: the meaning has to survive, the movement does not.
  // The blanket rule in `main.server.dart` already stops every animation;
  // the scaled blur is a filter rather than an animation, so it needs
  // saying here. The plate, the red border and the meter are all static
  // and carry the whole message on their own.
  css.media(const MediaQuery.raw('(prefers-reduced-motion: reduce)'), [
    css('.rx-panel.is-weak').styles(raw: {'filter': 'none'}),
    css('.rx-panel.is-lost > *:not(.rx-head):not(.rx-lost)').styles(
      raw: {'filter': 'none', 'opacity': '0.4'},
    ),
  ]),
];
