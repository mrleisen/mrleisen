import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

/// Aperture-grille phosphor overlay.
///
/// Three layered pure-CSS textures, screen-blended over the CRT:
///   1. A vertical RGB triad (the aperture grille itself) — subtle
///      when locked to a station, blooming when the signal is noisy.
///   2. A thin chromatic fringe at the left + right edges — red on
///      the left, cyan on the right — simulating convergence drift
///      near the tube edges.
///   3. A horizontal "carrier trace" line at the very top of the
///      viewport with a faint glow, the hardware's equivalent of a
///      "carrier present" tell-tale.
///
/// All layers react to the `--mask-i` custom property (0.0 clean →
/// 1.0 heavy noise) set on the root element; they dim toward 0 as
/// a station locks and bloom as the dial drifts into open air.
///
/// Sits at z-index 17 — above the vignette (15) and below the
/// scanlines (20) so the triad reads as a dot-mask UNDER the
/// horizontal scanline grid.
class PhosphorMask extends StatelessComponent {
  const PhosphorMask({
    required this.intensity,
    required this.isPowered,
    super.key,
  });

  /// 0.0 (clean lock) → 1.0 (dead air). Drives the mask opacity and
  /// the width of the chromatic edge fringe.
  final double intensity;

  /// Whole overlay fades to 0 when the radio is off so nothing
  /// leaks through the opaque CRT overlay during initial load.
  final bool isPowered;

  @override
  Component build(BuildContext context) {
    return div(
      classes: 'phosphor-mask${isPowered ? '' : ' phosphor-off'}',
      styles: Styles(raw: {
        '--mask-i': intensity.toStringAsFixed(3),
      }),
      [
        div(classes: 'phosphor-triad', []),
        div(classes: 'phosphor-fringe phosphor-fringe-l', []),
        div(classes: 'phosphor-fringe phosphor-fringe-r', []),
        div(classes: 'phosphor-carrier', []),
      ],
    );
  }

  @css
  static List<StyleRule> get styles => [
    css('.phosphor-mask').styles(
      position: Position.fixed(
        top: Unit.zero,
        left: Unit.zero,
        right: Unit.zero,
        bottom: Unit.zero,
      ),
      pointerEvents: PointerEvents.none,
      zIndex: ZIndex(17),
      raw: {
        'mix-blend-mode': 'screen',
        'transition': 'opacity 0.35s ease',
      },
    ),
    // Hidden when the radio is off — the CRT overlay is already
    // opaque black so the triad would just bloom invisibly against
    // it and waste composite bandwidth.
    css('.phosphor-mask.phosphor-off').styles(opacity: 0),

    // ── aperture-grille triad ──
    // Three 1px-wide vertical bars of primary-phosphor tints,
    // repeated every 3px across the viewport. Base opacity is
    // computed from --mask-i so noisy dead-air makes the mask
    // visible (the receiver is painting "nothing" through the
    // phosphor) and a locked station dims it back down toward
    // imperceptible.
    //
    // The lone `transparent 3px → 4px` gap per cycle adds a black
    // stripe that keeps the triad from washing out — without it the
    // whole image reads greenish.
    css('.phosphor-triad').styles(
      position: Position.absolute(
        top: Unit.zero,
        left: Unit.zero,
        right: Unit.zero,
        bottom: Unit.zero,
      ),
      raw: {
        'background': 'repeating-linear-gradient(90deg, '
            'rgba(255,40,64,0.11) 0px, rgba(255,40,64,0.11) 1px, '
            'rgba(40,255,110,0.09) 1px, rgba(40,255,110,0.09) 2px, '
            'rgba(60,90,255,0.11) 2px, rgba(60,90,255,0.11) 3px, '
            'transparent 3px, transparent 4px)',
        // Base 0.18, rising to 0.55 at full noise. Values over 0.6
        // start to feel like a filter, not a tube texture.
        'opacity': 'calc(0.18 + var(--mask-i, 0) * 0.37)',
        'transition': 'opacity 0.25s ease',
      },
    ),

    // ── chromatic edge fringe ──
    // Two thin vertical gradients hugging the left + right edges
    // of the viewport. Red bias on the left, cyan on the right —
    // the classic CRT convergence failure on the outer raster.
    // Width breathes with --mask-i so a clean signal stays tight,
    // a noisy one widens into visible colour bloom.
    css('.phosphor-fringe').styles(
      position: Position.absolute(top: Unit.zero, bottom: Unit.zero),
      raw: {
        'width': 'calc(24px + var(--mask-i, 0) * 36px)',
        'opacity': 'calc(0.15 + var(--mask-i, 0) * 0.35)',
        'transition': 'opacity 0.25s ease, width 0.25s ease',
      },
    ),
    css('.phosphor-fringe-l').styles(raw: {
      'left': '0',
      'background':
          'linear-gradient(90deg, rgba(255,40,80,0.55) 0%, transparent 100%)',
    }),
    css('.phosphor-fringe-r').styles(raw: {
      'right': '0',
      'background':
          'linear-gradient(-90deg, rgba(40,220,255,0.55) 0%, transparent 100%)',
    }),

    // ── top-edge carrier trace ──
    // A single 1px horizontal line at y=0 with a soft amber glow.
    // Always visible when the radio is on; the glow intensifies
    // with noise — the receiver is "seeing" the carrier band even
    // when no station is present.
    css('.phosphor-carrier').styles(
      position: Position.absolute(top: Unit.zero, left: Unit.zero),
      width: 100.percent,
      height: 1.px,
      raw: {
        'background':
            'linear-gradient(90deg, transparent 0%, rgba(255,180,70,0.35) 15%, rgba(255,210,140,0.55) 50%, rgba(255,180,70,0.35) 85%, transparent 100%)',
        'box-shadow':
            '0 0 calc(4px + var(--mask-i, 0) * 8px) rgba(255,180,70,0.45), '
                '0 1px calc(8px + var(--mask-i, 0) * 12px) rgba(255,150,50,0.3)',
        'opacity': 'calc(0.5 + var(--mask-i, 0) * 0.4)',
        'transition': 'opacity 0.25s ease, box-shadow 0.25s ease',
      },
    ),

    // ── mobile ──
    // Triad at 3px pitch is fine on hi-DPI but looks like a solid
    // haze on small screens. Widen the cycle so the pattern is
    // actually visible, and shrink the edge fringes so they don't
    // eat a phone's narrow viewport.
    css.media(MediaQuery.screen(maxWidth: 600.px), [
      css('.phosphor-triad').styles(raw: {
        'background': 'repeating-linear-gradient(90deg, '
            'rgba(255,40,64,0.11) 0px, rgba(255,40,64,0.11) 1px, '
            'rgba(40,255,110,0.09) 1px, rgba(40,255,110,0.09) 2px, '
            'rgba(60,90,255,0.11) 2px, rgba(60,90,255,0.11) 3px, '
            'transparent 3px, transparent 5px)',
      }),
      css('.phosphor-fringe').styles(raw: {
        'width': 'calc(14px + var(--mask-i, 0) * 20px)',
      }),
    ]),
  ];
}
