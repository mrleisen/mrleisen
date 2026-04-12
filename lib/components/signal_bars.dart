import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../models/station.dart';

/// Five-segment signal-strength meter in the top-left corner.
///
/// Bars light up progressively in the nearest station's colour as the
/// user approaches it. Off-station the bars are dim grey. On-station
/// (full signal) all five bars glow.
class SignalBars extends StatelessComponent {
  const SignalBars({
    required this.signalStrength,
    required this.activeStation,
    this.nearestStation,
    super.key,
  });

  /// 0.0 → dead air, 1.0 → perfect lock.
  final double signalStrength;

  /// Station currently locked onto (within ±0.15 MHz), or null.
  final Station? activeStation;

  /// Nearest station within [stationTolerance], or null. Used to pick
  /// the colour when close but not yet locked.
  final Station? nearestStation;

  @override
  Component build(BuildContext context) {
    // Pick the colour: prefer the locked-on station, then the nearest,
    // then a neutral dim grey.
    final color =
        activeStation?.color ?? nearestStation?.color ?? '#5a5a66';
    // How many bars (0..5) are lit.
    final lit = (signalStrength * 5.0).clamp(0.0, 5.0);

    return div(
      classes: 'signal-bars',
      attributes: {'aria-label': 'Signal strength'},
      [
        for (var i = 0; i < 5; i++)
          div(
            classes:
                'signal-bar${i < lit.ceil() && signalStrength > 0.02 ? ' is-lit' : ''}',
            styles: Styles(
              height: (6 + i * 3).px,
              raw: i < lit.ceil() && signalStrength > 0.02
                  ? {
                      'background': color,
                      'box-shadow': '0 0 4px ${color}aa',
                    }
                  : null,
            ),
            [],
          ),
      ],
    );
  }

  @css
  static List<StyleRule> get styles => [
    css('.signal-bars').styles(
      position: Position.fixed(top: 16.px, left: 16.px),
      zIndex: ZIndex(25),
      display: Display.flex,
      flexDirection: FlexDirection.row,
      alignItems: AlignItems.end,
      gap: Gap(column: 3.px),
      padding: Padding.symmetric(horizontal: 8.px, vertical: 6.px),
      radius: BorderRadius.all(Radius.circular(6.px)),
      pointerEvents: PointerEvents.none,
      raw: {
        'background': 'rgba(0,0,0,0.35)',
        'border': '1px solid rgba(255,255,255,0.08)',
        'backdrop-filter': 'blur(4px)',
        '-webkit-backdrop-filter': 'blur(4px)',
      },
    ),
    css('.signal-bar').styles(
      width: 3.px,
      backgroundColor: const Color('#2a2a32'),
      radius: BorderRadius.all(Radius.circular(1.px)),
      raw: {
        'transition':
            'background 0.25s ease, box-shadow 0.25s ease',
      },
    ),
    css.media(MediaQuery.screen(maxWidth: 600.px), [
      css('.signal-bars').styles(
        position: Position.fixed(top: 10.px, left: 10.px),
        padding: Padding.symmetric(horizontal: 6.px, vertical: 5.px),
      ),
    ]),
  ];
}
