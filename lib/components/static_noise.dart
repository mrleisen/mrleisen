import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

/// Pure-CSS analog-TV static overlay (no SVG, no data URLs).
///
/// [noiseLevel] (0..1) drives the overall presence:
///   - 1.0 → loud detuned-TV snow + tracking band
///   - 0.5 → static breaking up, content ghosts through
///   - 0.1 → faint film grain only
///   - 0.0 → essentially invisible
///
/// Layer plan (kept to ≤3 painting layers + a flicker wrapper):
///   1. `.tv-grain`        — fine repeating-linear-gradient grain
///   2. `.tv-coarse`       — second gradient at a different angle/scale
///   3. `.tv-band`         — single horizontal VHS tracking strip
///   * Wrapped in `.tv-flicker-host` so a brief opacity dip can run
///     without colliding with the per-layer opacity values.
class StaticNoise extends StatelessComponent {
  const StaticNoise({
    this.noiseLevel = 0.5,
    this.isPowered = true,
    super.key,
  });

  /// 0.0 (clean) … 1.0 (heavy snow). The caller maps signal strength into
  /// this range; we treat anything ≥ 1.0 as "fully detuned".
  final double noiseLevel;

  /// When false every layer collapses to opacity 0 and the animations
  /// are disabled so the snow pattern doesn't silently burn CPU behind
  /// the CRT-off overlay.
  final bool isPowered;

  // Layer opacities derived from noiseLevel — zeroed when powered off.
  double get _grainOpacity =>
      isPowered ? (0.04 + noiseLevel * 0.85).clamp(0.0, 0.95) : 0.0;
  double get _coarseOpacity =>
      isPowered ? (noiseLevel * 0.7).clamp(0.0, 0.75) : 0.0;
  // Band only appears once we're well off-station.
  double get _bandOpacity => !isPowered
      ? 0.0
      : (noiseLevel < 0.35
          ? 0.0
          : ((noiseLevel - 0.35) * 1.4).clamp(0.0, 0.85));
  // Flicker amplitude — full strength when noisy, off when locked.
  double get _flickerStrength =>
      isPowered ? noiseLevel.clamp(0.0, 1.0) : 0.0;

  @override
  Component build(BuildContext context) {
    return div(
      classes: 'tv-flicker-host',
      styles: Styles(
        // The flicker keyframe multiplies into this base opacity by setting
        // `opacity` itself only at brief dip moments; setting the CSS var
        // lets us scale the dip by noise level.
        raw: {
          '--tv-flicker-amp': _flickerStrength.toStringAsFixed(3),
          'animation': isPowered
              ? 'tv-flicker 7.3s steps(1, end) infinite'
              : 'none',
        },
      ),
      [
        // Layer 1 — fine snow grain.
        div(
          classes: 'tv-grain',
          styles: Styles(
            opacity: _grainOpacity,
            raw: {
              'transition': 'opacity 0.3s ease',
              if (!isPowered) 'animation': 'none',
            },
          ),
          [],
        ),
        // Layer 2 — coarser cross-pattern at a different angle.
        div(
          classes: 'tv-coarse',
          styles: Styles(
            opacity: _coarseOpacity,
            raw: {
              'transition': 'opacity 0.3s ease',
              if (!isPowered) 'animation': 'none',
            },
          ),
          [],
        ),
        // Layer 3 — VHS tracking band.
        div(
          classes: 'tv-band',
          styles: Styles(
            opacity: _bandOpacity,
            raw: {
              'transition': 'opacity 0.4s ease',
              if (!isPowered) 'animation': 'none',
            },
          ),
          [],
        ),
      ],
    );
  }

  // ── styles ──

  @css
  static List<StyleRule> get styles => [
    // Flicker wrapper — fixed full-screen, holds the overall flicker animation.
    css('.tv-flicker-host').styles(
      position: Position.fixed(top: Unit.zero, left: Unit.zero),
      width: 100.percent,
      height: 100.percent,
      overflow: Overflow.hidden,
      pointerEvents: PointerEvents.none,
      zIndex: ZIndex(10),
    ),

    // ── Layer 1: fine grain ──
    // Two near-perpendicular hairline gradients at an unusual angle make a
    // tight cross-hatch that, when stepped translated, reads as snow.
    css('.tv-grain').styles(
      position: Position.absolute(top: (-25).percent, left: (-25).percent),
      width: 150.percent,
      height: 150.percent,
      raw: {
        'background-image':
            'repeating-linear-gradient(73deg, '
                'rgba(255,255,255,0.55) 0px, '
                'rgba(255,255,255,0.55) 1px, '
                'transparent 1px, '
                'transparent 3px),'
                'repeating-linear-gradient(163deg, '
                'rgba(255,255,255,0.45) 0px, '
                'rgba(255,255,255,0.45) 1px, '
                'transparent 1px, '
                'transparent 4px)',
        'background-size': '3px 3px, 4px 4px',
        'mix-blend-mode': 'screen',
        'will-change': 'transform',
        'animation':
            'tv-grain-shift 80ms steps(8, jump-end) infinite',
      },
    ),

    // ── Layer 2: coarser cross-pattern ──
    css('.tv-coarse').styles(
      position: Position.absolute(top: (-25).percent, left: (-25).percent),
      width: 150.percent,
      height: 150.percent,
      raw: {
        'background-image':
            'repeating-linear-gradient(17deg, '
                'rgba(255,255,255,0.4) 0px, '
                'rgba(255,255,255,0.4) 1px, '
                'transparent 1px, '
                'transparent 5px),'
                'repeating-linear-gradient(107deg, '
                'rgba(180,200,220,0.3) 0px, '
                'rgba(180,200,220,0.3) 1px, '
                'transparent 1px, '
                'transparent 6px)',
        'background-size': '6px 6px, 7px 7px',
        'mix-blend-mode': 'screen',
        'will-change': 'transform',
        'animation':
            'tv-coarse-shift 130ms steps(6, jump-end) infinite reverse',
      },
    ),

    // ── Layer 3: VHS tracking band ──
    // A single semi-transparent horizontal strip that sweeps top→bottom.
    css('.tv-band').styles(
      position: Position.absolute(left: Unit.zero),
      width: 100.percent,
      height: 5.px,
      raw: {
        'top': '0',
        'background':
            'linear-gradient(to bottom, '
                'rgba(255,255,255,0) 0%, '
                'rgba(255,255,255,0.55) 35%, '
                'rgba(255,255,255,0.7) 50%, '
                'rgba(255,255,255,0.55) 65%, '
                'rgba(255,255,255,0) 100%)',
        'box-shadow':
            '0 0 8px rgba(255,255,255,0.35), '
                '0 -1px 0 rgba(255,40,40,0.35), '
                '0 1px 0 rgba(40,200,255,0.35)',
        'mix-blend-mode': 'screen',
        'animation': 'tv-band-sweep 5.7s linear infinite',
      },
    ),
  ];
}
