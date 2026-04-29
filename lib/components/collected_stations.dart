import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:universal_web/web.dart' as web;

import '../models/station.dart';

// Amber-LED palette — kept in sync with radio_dial.dart so the row
// reads as the same hardware family as the LCD readout.
const String _lcdAmber = '#E8A035';
const String _lcdAmberDim = '#6d4a0e';

/// Horizontal row of stations the user has discovered. Sits just above
/// the radio panel and lets the user recall any past lock-on with a
/// single tap, so they don't have to sweep the band again every time
/// they want a station they already heard.
///
/// Each pill mimics the aged backlit-LCD aesthetic of the main readout:
/// muted amber gradient under a noise pattern, dark inset bevel, soft
/// outer glow that brightens on hover and on the currently active
/// station.
class CollectedStations extends StatefulComponent {
  const CollectedStations({
    required this.stations,
    required this.activeStation,
    required this.isPowered,
    required this.onRecall,
    this.onDelete,
    super.key,
  });

  /// Stations the user has tuned into at least once, in discovery order.
  final List<Station> stations;

  /// The station currently locked onto, if any. The matching pill in
  /// the row gets the brighter "lit" treatment.
  final Station? activeStation;

  /// Whole row fades out when the radio is off — collected stations
  /// don't make sense as a backlit readout when the panel is dark.
  final bool isPowered;

  /// Fired when the user taps a pill. Parent is responsible for band
  /// switching + tuning.
  final void Function(Station) onRecall;

  /// Fired when the user press-and-holds a pill long enough to clear
  /// it. Mirrors the way old car-stereo presets were wiped — hold the
  /// button until it confirms. Parent removes the station from its
  /// collected set + persists.
  final void Function(Station)? onDelete;

  @override
  State<CollectedStations> createState() => CollectedStationsState();
}

class CollectedStationsState extends State<CollectedStations> {
  /// Key (`band:freq`) of the pill currently being held down for
  /// deletion. Null when no hold is in progress.
  String? _holdingKey;
  Timer? _holdTimer;

  /// How long the user must hold a pill to confirm a delete. ~900 ms
  /// is the sweet spot — short enough not to feel tedious, long
  /// enough that an accidental brush against the screen recalls the
  /// station rather than clearing it.
  static const Duration _holdDuration = Duration(milliseconds: 900);

  String _stationKey(Station s) => '${s.band.name}:${s.frequency}';

  @override
  void dispose() {
    _holdTimer?.cancel();
    super.dispose();
  }

  void _startHold(Station s) {
    final key = _stationKey(s);
    _holdTimer?.cancel();
    setState(() => _holdingKey = key);
    _holdTimer = Timer(_holdDuration, () {
      if (!mounted) return;
      // Bail if the user moved on to a different pill (or released)
      // between starting the timer and firing it.
      if (_holdingKey != key) return;
      setState(() => _holdingKey = null);
      component.onDelete?.call(s);
    });
  }

  /// Releases the hold without committing a delete. Returns true when
  /// the release happened before the long-press timer fired — the
  /// caller treats that case as a tap (recall).
  bool _releaseHold(Station s) {
    final key = _stationKey(s);
    final wasHolding = _holdingKey == key;
    _holdTimer?.cancel();
    _holdTimer = null;
    if (wasHolding) {
      setState(() => _holdingKey = null);
    }
    return wasHolding;
  }

  void _cancelHold(Station s) {
    final key = _stationKey(s);
    if (_holdingKey != key) return;
    _holdTimer?.cancel();
    _holdTimer = null;
    setState(() => _holdingKey = null);
  }

  @override
  Component build(BuildContext context) {
    final fmStations = [
      for (final s in component.stations) if (s.band == Band.fm) s,
    ];
    final amStations = [
      for (final s in component.stations) if (s.band == Band.am) s,
    ];
    final visible = component.isPowered && component.stations.isNotEmpty;
    return div(
      classes:
          'collected-rack${visible ? '' : ' collected-rack-hidden'}',
      attributes: {'aria-label': 'Collected stations'},
      [
        if (fmStations.isNotEmpty) _buildBandRow(Band.fm, fmStations),
        if (amStations.isNotEmpty) _buildBandRow(Band.am, amStations),
      ],
    );
  }

  Component _buildBandRow(Band band, List<Station> bandStations) {
    return div(classes: 'collected-row collected-row-${band.name}', [
      span(
        classes: 'collected-row-label',
        attributes: {'aria-hidden': 'true'},
        [text(band.name.toUpperCase())],
      ),
      div(
        classes: 'collected-row-pills',
        [for (final s in bandStations) _buildPill(s)],
      ),
    ]);
  }

  Component _buildPill(Station s) {
    final isFm = s.band == Band.fm;
    final freqLabel = isFm
        ? s.frequency.toStringAsFixed(1)
        : s.frequency.toInt().toString();
    final unit = isFm ? 'MHz' : 'kHz';
    final activeStation = component.activeStation;
    final isActive = activeStation != null &&
        activeStation.band == s.band &&
        activeStation.frequency == s.frequency;
    final isHolding = _holdingKey == _stationKey(s);
    final classes = StringBuffer('collected-pill');
    if (isActive) classes.write(' collected-pill-active');
    if (isHolding) classes.write(' collected-pill-holding');
    return div(
      classes: classes.toString(),
      events: {
        'pointerdown': (web.Event e) {
          final pe = e as web.PointerEvent;
          // Mouse: only react to the primary button. Touch/pen: any
          // contact counts.
          if (pe.pointerType == 'mouse' && pe.button != 0) return;
          _startHold(s);
        },
        'pointerup': (web.Event e) {
          if (_releaseHold(s)) component.onRecall(s);
        },
        'pointerleave': (web.Event _) => _cancelHold(s),
        'pointercancel': (web.Event _) => _cancelHold(s),
        // Keyboard activation — Enter / Space recalls; long-press
        // delete is intentionally pointer-only since holding a key is
        // a less natural metaphor than holding a button.
        'keydown': (web.Event e) {
          final ke = e as web.KeyboardEvent;
          if (ke.key == 'Enter' || ke.key == ' ') {
            ke.preventDefault();
            component.onRecall(s);
          }
        },
      },
      attributes: {
        'role': 'button',
        'tabindex': '0',
        'aria-label':
            'Tune to ${s.callSign}, ${s.band.name.toUpperCase()} $freqLabel $unit. '
                'Press and hold to clear.',
      },
      [
        span(classes: 'collected-call', [text(s.callSign)]),
        span(classes: 'collected-freq', [text(freqLabel)]),
      ],
    );
  }

  @css
  static List<StyleRule> get styles => [
    // ── rack container ──
    // Holds up to two band rows (FM, AM). Each row only renders if
    // the user has collected at least one station on that band, so
    // the rack height grows from 0 → 1 row → 2 rows organically.
    // Collapses to zero when empty / powered off so the panel layout
    // matches the pre-feature 210 px exactly.
    css('.collected-rack').styles(
      position: Position.relative(),
      display: Display.flex,
      flexDirection: FlexDirection.column,
      alignItems: AlignItems.stretch,
      gap: Gap(row: 3.px),
      padding: Padding.symmetric(horizontal: Unit.zero, vertical: 3.px),
      opacity: 1,
      raw: {
        'max-height': '70px',
        'margin-bottom': '4px',
        'transition':
            'opacity 0.35s ease, max-height 0.35s ease, '
                'padding 0.35s ease, margin-bottom 0.35s ease',
      },
    ),
    css('.collected-rack-hidden').styles(
      opacity: 0,
      padding: Padding.zero,
      raw: {
        'max-height': '0',
        'margin-bottom': '0',
        'pointer-events': 'none',
      },
    ),

    // ── single band row ──
    // `[FM] [pill][pill][pill]…` — the band label is a fixed-width
    // gutter (so both rows' pills line up); pills sit in their own
    // horizontally-scrollable container so overflow scrolls per band
    // rather than stretching the whole rack.
    css('.collected-row').styles(
      display: Display.flex,
      flexDirection: FlexDirection.row,
      alignItems: AlignItems.center,
      gap: Gap(column: 7.px),
    ),
    // Pill scroller. Hidden scrollbar; pointer-events re-enabled on
    // pills themselves.
    css('.collected-row-pills', [
      css('&').styles(
        display: Display.flex,
        flexDirection: FlexDirection.row,
        alignItems: AlignItems.center,
        gap: Gap(column: 5.px),
        raw: {
          'flex': '1',
          'min-width': '0',
          'overflow-x': 'auto',
          'overflow-y': 'hidden',
          'scrollbar-width': 'none',
          '-ms-overflow-style': 'none',
          'padding': '1px 0',
        },
      ),
      css('&::-webkit-scrollbar').styles(raw: {'display': 'none'}),
    ]),

    // ── band label ──
    // Tracked uppercase microtype, same recipe as `.brand-sub` /
    // `.lcd-fm`. FM is the brighter amber (matches the active-band
    // tinting in the carrier readout), AM is dim grey since it isn't
    // the "primary" band visually.
    css('.collected-row-label').styles(
      fontFamily: const FontFamily.list([
        FontFamily('IBM Plex Mono'),
        FontFamilies.monospace,
      ]),
      fontSize: Unit.pixels(8),
      fontWeight: FontWeight.w700,
      letterSpacing: 0.25.em,
      color: const Color(_lcdAmberDim),
      raw: {
        'flex': '0 0 22px',
        'text-transform': 'uppercase',
        'text-align': 'right',
        'user-select': 'none',
        '-webkit-user-select': 'none',
        'text-shadow': '0 1px 0 rgba(0,0,0,0.55)',
      },
    ),
    css('.collected-row-fm .collected-row-label').styles(
      color: const Color(_lcdAmber),
      raw: {
        'text-shadow':
            '0 0 3px rgba(232,160,53,0.45), 0 1px 0 rgba(0,0,0,0.55)',
      },
    ),
    css('.collected-row-am .collected-row-label').styles(
      color: const Color('#7a7a86'),
    ),

    // ── pill ──
    // Styled as a dark inset preset button (same language as the
    // FM/AM/ST/MONO indicator pills above), not as its own LCD. Call
    // sign is amber type ON the dark substrate, so it doesn't compete
    // visually with the actual LCD readout.
    //
    // The `::after` overlay is the press-and-hold delete progress
    // bar — a red wash that fills left→right while the user is
    // holding the pill. At rest its width is 0 with a fast 0.15 s
    // snap so an early release reads as "cancelled". When the
    // `.collected-pill-holding` class is applied, the width animates
    // to 100% over the hold duration, matching the JS-side timer.
    css('.collected-pill', [
      css('&').styles(
        position: Position.relative(),
        display: Display.flex,
        flexDirection: FlexDirection.row,
        alignItems: AlignItems.baseline,
        justifyContent: JustifyContent.center,
        cursor: Cursor.pointer,
        padding: Padding.symmetric(horizontal: 7.px, vertical: 2.px),
        radius: BorderRadius.all(Radius.circular(2.px)),
        raw: {
          'gap': '6px',
          'flex-shrink': '0',
          'pointer-events': 'auto',
          'overflow': 'hidden',
          'background':
              'linear-gradient(to bottom, #0a0a10, #050508)',
          'border': '1px solid #1c1c26',
          'box-shadow': 'inset 0 1px 1px rgba(0,0,0,0.6)',
          'transition':
              'background 0.18s ease, border-color 0.18s ease, '
                  'box-shadow 0.18s ease, transform 0.12s ease',
          'user-select': 'none',
          '-webkit-user-select': 'none',
          '-webkit-tap-highlight-color': 'transparent',
          'touch-action': 'manipulation',
        },
      ),
      css('&::after').styles(
        position: Position.absolute(
          top: Unit.zero,
          bottom: Unit.zero,
          left: Unit.zero,
        ),
        width: Unit.zero,
        pointerEvents: PointerEvents.none,
        raw: {
          'content': '""',
          'background':
              'linear-gradient(to right, '
                  'rgba(220,70,70,0.0) 0%, '
                  'rgba(220,70,70,0.45) 80%, '
                  'rgba(220,70,70,0.65) 100%)',
          'transition': 'width 0.15s ease-out',
        },
      ),
      css('&:hover').styles(raw: {
        'border-color': '#2a1a08',
        'background': 'linear-gradient(to bottom, #100904, #050202)',
      }),
      css('&:active').styles(raw: {'transform': 'translateY(1px)'}),
      css('&:focus-visible').styles(raw: {
        'outline': 'none',
        'border-color': '#3a2a14',
        'box-shadow':
            'inset 0 1px 1px rgba(0,0,0,0.6), '
                '0 0 0 1px rgba(232,160,53,0.45)',
      }),
    ]),
    // ── press-and-hold delete state ──
    // Width transitions to 100% over the hold duration, matching the
    // 0.9 s timer in `CollectedStationsState`. Border tints red so
    // the action reads as destructive even before the fill arrives.
    css('.collected-pill-holding').styles(raw: {
      'border-color': 'rgba(200,70,70,0.55)',
      'box-shadow':
          'inset 0 1px 1px rgba(0,0,0,0.6), 0 0 6px rgba(200,70,70,0.25)',
    }),
    css('.collected-pill-holding::after').styles(
      width: 100.percent,
      raw: {'transition': 'width 0.9s linear'},
    ),
    // ── currently-tuned pill ──
    // Mirrors the lit `.ind-on` indicator: warmer dark substrate,
    // amber-tinted border, and (via descendant rules) brighter text
    // with a soft glow. No big outer halo — the pill stays calm so
    // it reads as part of the faceplate, not a separate light source.
    css('.collected-pill-active').styles(raw: {
      'background': 'linear-gradient(to bottom, #100904, #050202)',
      'border': '1px solid #2a1a08',
      'box-shadow':
          'inset 0 1px 1px rgba(0,0,0,0.6), '
              '0 0 6px rgba(232,160,53,0.18)',
    }),

    // ── call sign ──
    // Dim amber by default (so a long row of presets reads as a
    // calm rack), brighter on hover and on the active pill. Same
    // Orbitron/IBM-Plex pairing as the LCD readout.
    css('.collected-call').styles(
      fontFamily: const FontFamily.list([
        FontFamily('Orbitron'),
        FontFamilies.monospace,
      ]),
      fontSize: Unit.pixels(10),
      fontWeight: FontWeight.w700,
      letterSpacing: 0.16.em,
      color: const Color(_lcdAmberDim),
      raw: {
        'line-height': '1',
        'transition': 'color 0.18s ease, text-shadow 0.18s ease',
      },
    ),
    css('.collected-pill:hover .collected-call').styles(
      color: const Color(_lcdAmber),
      raw: {
        'text-shadow':
            '0 0 3px rgba(232,160,53,0.55), 0 0 6px rgba(232,160,53,0.22)',
      },
    ),
    css('.collected-pill-active .collected-call').styles(
      color: const Color(_lcdAmber),
      raw: {
        'text-shadow':
            '0 0 4px rgba(232,160,53,0.7), 0 0 8px rgba(232,160,53,0.32)',
      },
    ),

    // ── frequency, inline next to the call sign ──
    // Band is now communicated by the row label, so the pill only
    // needs the call sign and the frequency. The freq stays in a
    // dimmer tone so the call sign carries the visual weight.
    css('.collected-freq').styles(
      fontFamily: const FontFamily.list([
        FontFamily('IBM Plex Mono'),
        FontFamilies.monospace,
      ]),
      fontSize: Unit.pixels(8),
      fontWeight: FontWeight.w500,
      letterSpacing: 0.08.em,
      color: const Color('#5a4220'),
      raw: {
        'line-height': '1',
        'transition': 'color 0.18s ease',
      },
    ),
    css('.collected-pill:hover .collected-freq, '
            '.collected-pill-active .collected-freq')
        .styles(color: const Color('#9a6a2a')),

    // ── responsive ──
    css.media(MediaQuery.screen(maxWidth: 600.px), [
      css('.collected-rack').styles(
        gap: Gap(row: 2.px),
        padding: Padding.symmetric(horizontal: Unit.zero, vertical: 2.px),
        raw: {
          'max-height': '56px',
          'margin-bottom': '3px',
        },
      ),
      css('.collected-row').styles(gap: Gap(column: 5.px)),
      css('.collected-row-pills').styles(gap: Gap(column: 4.px)),
      css('.collected-row-label').styles(
        fontSize: Unit.pixels(7),
        letterSpacing: 0.18.em,
        raw: {'flex': '0 0 18px'},
      ),
      css('.collected-pill').styles(
        padding: Padding.symmetric(horizontal: 5.px, vertical: 1.px),
        raw: {'gap': '4px'},
      ),
      css('.collected-call').styles(
        fontSize: Unit.pixels(9),
        letterSpacing: 0.12.em,
      ),
      css('.collected-freq').styles(fontSize: Unit.pixels(7)),
    ]),
  ];
}
