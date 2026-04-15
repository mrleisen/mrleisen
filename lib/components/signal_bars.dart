import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../models/station.dart';

/// Five-segment signal-strength meter in the top-left corner.
///
/// Bars light up progressively in the nearest station's colour as the
/// user approaches it. Off-station the bars are dim grey. On-station
/// (full signal) all five bars glow.
///
/// When the radio powers on, the meter first runs a brief "searching
/// for signal" sweep — each bar pulses amber with a staggered delay,
/// giving a Knight Rider-style scanner. After [_scanDuration] the
/// animation hands off to the normal signal-strength display.
class SignalBars extends StatefulComponent {
  const SignalBars({
    required this.signalStrength,
    required this.activeStation,
    required this.isPowered,
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

  /// Whole meter is hidden when false; flipping true kicks off the
  /// scan animation.
  final bool isPowered;

  @override
  State<SignalBars> createState() => _SignalBarsState();

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
      opacity: 1,
      raw: {
        'background': 'rgba(0,0,0,0.35)',
        'border': '1px solid rgba(255,255,255,0.08)',
        'backdrop-filter': 'blur(4px)',
        '-webkit-backdrop-filter': 'blur(4px)',
        'transition': 'opacity 0.3s ease',
      },
    ),
    // Powered-off — the whole meter fades out so the dim bars don't
    // leak through the black CRT overlay during initial load.
    css('.signal-bars.signal-bars-off').styles(
      opacity: 0,
    ),
    css('.signal-bar').styles(
      width: 3.px,
      backgroundColor: const Color('#2a2a32'),
      radius: BorderRadius.all(Radius.circular(1.px)),
      raw: {
        'transition':
            'background 0.25s ease, box-shadow 0.25s ease, opacity 0.25s ease',
      },
    ),
    // Scanning state — amber pulse with staggered per-bar delay
    // applied inline in [_SignalBarsState].
    css('.signal-bar.signal-scanning').styles(
      raw: {
        'background': '#E8A035',
        'box-shadow': '0 0 4px rgba(232,160,53,0.6)',
        'animation': 'signal-scan 0.8s ease-in-out infinite',
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

class _SignalBarsState extends State<SignalBars> {
  bool _isScanning = false;
  Timer? _scanTimer;

  /// How long the "searching for signal" sweep runs after power-on.
  static const Duration _scanDuration = Duration(seconds: 2);

  @override
  void initState() {
    super.initState();
    // If the parent mounted us already-powered (e.g. state rehydration),
    // still run the sweep so the visual is consistent.
    if (component.isPowered) {
      _startScanning();
    }
  }

  @override
  void didUpdateComponent(SignalBars oldComponent) {
    super.didUpdateComponent(oldComponent);
    final wasPowered = oldComponent.isPowered;
    final isPowered = component.isPowered;
    if (isPowered && !wasPowered) {
      _startScanning();
    } else if (!isPowered && wasPowered) {
      _scanTimer?.cancel();
      if (_isScanning) {
        setState(() => _isScanning = false);
      }
    }
  }

  @override
  void dispose() {
    _scanTimer?.cancel();
    super.dispose();
  }

  void _startScanning() {
    _scanTimer?.cancel();
    setState(() => _isScanning = true);
    _scanTimer = Timer(_scanDuration, () {
      if (mounted) setState(() => _isScanning = false);
    });
  }

  @override
  Component build(BuildContext context) {
    final isPowered = component.isPowered;
    final signalStrength = component.signalStrength;
    final activeStation = component.activeStation;
    final nearestStation = component.nearestStation;

    // Pick the colour: prefer the locked-on station, then the nearest,
    // then a neutral dim grey.
    final color =
        activeStation?.color ?? nearestStation?.color ?? '#5a5a66';
    // How many bars (0..5) are lit.
    final lit = (signalStrength * 5.0).clamp(0.0, 5.0);

    return div(
      classes: 'signal-bars${isPowered ? '' : ' signal-bars-off'}',
      attributes: {'aria-label': 'Signal strength'},
      [
        for (var i = 0; i < 5; i++)
          _buildBar(
            index: i,
            isPowered: isPowered,
            lit: lit,
            signalStrength: signalStrength,
            color: color,
          ),
      ],
    );
  }

  Component _buildBar({
    required int index,
    required bool isPowered,
    required double lit,
    required double signalStrength,
    required String color,
  }) {
    final height = (6 + index * 3).px;

    if (_isScanning && isPowered) {
      return div(
        classes: 'signal-bar signal-scanning',
        styles: Styles(
          height: height,
          raw: {
            'animation-delay': '${(index * 0.15).toStringAsFixed(2)}s',
          },
        ),
        [],
      );
    }

    final isBarLit =
        isPowered && index < lit.ceil() && signalStrength > 0.02;
    return div(
      classes: 'signal-bar${isBarLit ? ' is-lit' : ''}',
      styles: Styles(
        height: height,
        raw: isBarLit
            ? {
                'background': color,
                'box-shadow': '0 0 4px ${color}aa',
              }
            : null,
      ),
      [],
    );
  }
}
