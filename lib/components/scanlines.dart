import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

/// CSS scanlines overlay that simulates a CRT monitor effect.
///
/// Uses a repeating linear gradient to create thin semi-transparent
/// horizontal lines across the entire viewport.
class Scanlines extends StatelessComponent {
  const Scanlines({super.key});

  @override
  Component build(BuildContext context) {
    return div(
      classes: 'scanlines',
      attributes: const {'aria-hidden': 'true'},
      [],
    );
  }

  @css
  static List<StyleRule> get styles => [
    css('.scanlines').styles(
      position: Position.fixed(
        top: Unit.zero,
        left: Unit.zero,
      ),
      zIndex: ZIndex(20),
      width: 100.percent,
      height: 100.percent,
      opacity: 0.12,
      pointerEvents: PointerEvents.none,
      raw: {
        'background':
            'repeating-linear-gradient('
            'to bottom, '
            'transparent 0px, '
            'transparent 1px, '
            'rgba(0,0,0,0.4) 1px, '
            'rgba(0,0,0,0.4) 2px'
            ')',
      },
    ),
  ];
}
