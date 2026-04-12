import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

/// Fixed full-screen radial-gradient vignette. Lighter at centre,
/// darker at the edges — gives the CRT / TV-screen feeling without
/// affecting layout or input. Sits above the content but below the
/// signal-bars / language toggle.
class Vignette extends StatelessComponent {
  const Vignette({super.key});

  @override
  Component build(BuildContext context) {
    return div(classes: 'vignette', []);
  }

  @css
  static List<StyleRule> get styles => [
    css('.vignette').styles(
      position: Position.fixed(top: Unit.zero, left: Unit.zero),
      width: 100.percent,
      height: 100.percent,
      pointerEvents: PointerEvents.none,
      zIndex: ZIndex(15),
      raw: {
        'background':
            'radial-gradient(ellipse at center, '
                'transparent 0%, '
                'transparent 45%, '
                'rgba(0,0,0,0.35) 85%, '
                'rgba(0,0,0,0.6) 100%)',
      },
    ),
  ];
}
