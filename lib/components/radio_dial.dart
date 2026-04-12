import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:universal_web/js_interop.dart';
import 'package:universal_web/web.dart' as web;

import '../models/station.dart';

/// Re-typed view over `PointerEvent` whose `clientX`/`clientY` are
/// declared as `double` instead of `int`.
///
/// `package:web` types these as `int`, but JavaScript actually hands
/// fractional pixel values back on touch / hi-DPI devices, so reading
/// the typed `int` getter throws `TypeError: <double> is not a subtype
/// of int` at runtime. An extension-type wrapper with `external double`
/// getters dispatches to the same underlying JS property reads but
/// without the spurious int conversion check.
extension type _DoublePointer._(JSObject _) implements JSObject {
  _DoublePointer(web.PointerEvent pe) : _ = pe as JSObject;
  external double get clientX;
  external double get clientY;
}

double _clientX(web.PointerEvent pe) => _DoublePointer(pe).clientX;
double _clientY(web.PointerEvent pe) => _DoublePointer(pe).clientY;

/// Pixels drawn per 1 MHz on the dial strip.
const double _pxPerMhz = 60.0;

/// Total width of the scrollable strip in pixels.
const double _stripWidth = (maxFrequency - minFrequency) * _pxPerMhz;

/// Visible width of the dial window viewport.
const double _windowWidth = 320.0;

// Amber-LCD palette (Pioneer/Kenwood-style backlight).
const String _lcdAmber = '#ffb13a';
const String _lcdAmberDim = '#7a4f10';

/// The radio dial panel fixed to the bottom of the screen.
///
/// Styled to evoke a 90s in-dash car stereo: brushed plastic faceplate,
/// inset dial slit, amber LCD readout, ribbed metallic knob, plus the
/// usual non-functional FM/STEREO/MONO indicators and an embossed brand.
class RadioDial extends StatefulComponent {
  const RadioDial({
    required this.frequency,
    required this.onFrequencyChanged,
    this.signalStrength = 0.0,
    this.activeStation,
    super.key,
  });

  final double frequency;
  final ValueChanged<double> onFrequencyChanged;
  final double signalStrength;
  final Station? activeStation;

  @override
  State<RadioDial> createState() => RadioDialState();
}

class RadioDialState extends State<RadioDial> {
  // --- drag state ---
  bool _draggingStrip = false;
  bool _draggingKnob = false;
  double _dragStartFreq = 0;
  double _dragStartX = 0;
  double _dragStartY = 0;

  // --- helpers ---

  double get _freq => component.frequency;

  double get _stripOffset {
    final freqX = (_freq - minFrequency) * _pxPerMhz;
    return -(freqX - _windowWidth / 2);
  }

  double get _knobAngle {
    return ((_freq - minFrequency) / (maxFrequency - minFrequency)) * 270 - 135;
  }

  void _setFrequency(double v) {
    v = (v * 10).roundToDouble() / 10;
    v = v.clamp(minFrequency, maxFrequency);
    component.onFrequencyChanged(v);
  }

  // --- strip drag ---

  void _onStripDown(web.Event event) {
    final pe = event as web.PointerEvent;
    (pe.currentTarget as web.Element).setPointerCapture(pe.pointerId);
    _draggingStrip = true;
    _dragStartFreq = _freq;
    _dragStartX = _clientX(pe);
  }

  void _onStripMove(web.Event event) {
    if (!_draggingStrip) return;
    final pe = event as web.PointerEvent;
    final dx = _clientX(pe) - _dragStartX;
    _setFrequency(_dragStartFreq - dx / _pxPerMhz);
  }

  void _onStripUp(web.Event event) {
    if (!_draggingStrip) return;
    _draggingStrip = false;
    final pe = event as web.PointerEvent;
    (pe.currentTarget as web.Element).releasePointerCapture(pe.pointerId);
  }

  // --- knob drag ---

  void _onKnobDown(web.Event event) {
    final pe = event as web.PointerEvent;
    (pe.currentTarget as web.Element).setPointerCapture(pe.pointerId);
    _draggingKnob = true;
    _dragStartFreq = _freq;
    _dragStartY = _clientY(pe);
  }

  void _onKnobMove(web.Event event) {
    if (!_draggingKnob) return;
    final pe = event as web.PointerEvent;
    final dy = _clientY(pe) - _dragStartY;
    _setFrequency(_dragStartFreq - dy * 0.15);
  }

  void _onKnobUp(web.Event event) {
    if (!_draggingKnob) return;
    _draggingKnob = false;
    final pe = event as web.PointerEvent;
    (pe.currentTarget as web.Element).releasePointerCapture(pe.pointerId);
  }

  // --- wheel on panel ---

  void _onPanelWheel(web.Event event) {
    final we = event as web.WheelEvent;
    we.preventDefault();
    final delta = we.deltaY > 0 ? 0.2 : -0.2;
    _setFrequency(_freq + delta);
  }

  // --- build ---

  @override
  Component build(BuildContext context) {
    final tuned = component.activeStation != null;

    return div(
      classes: 'radio-panel',
      events: {'wheel': _onPanelWheel},
      [
        // Top bevel highlight (purely cosmetic).
        div(classes: 'panel-bevel-top', []),

        // Header row: brand + indicators.
        div(classes: 'panel-header', [
          span(classes: 'brand', [text('THE SIGNAL')]),
          div(classes: 'indicator-row', [
            _indicator('FM', active: true),
            _indicator('AM'),
            _indicator('ST', active: tuned),
            _indicator('MONO'),
          ]),
        ]),

        // Main row: LCD readout + dial window + knob.
        div(classes: 'panel-main', [
          // LCD frequency readout.
          div(classes: 'lcd', [
            div(classes: 'lcd-backlight', []),
            // Faded "ghost" 88.8 segments behind the live digits.
            span(classes: 'lcd-ghost', [text('188.8')]),
            span(classes: 'lcd-value', [text(_freq.toStringAsFixed(1))]),
            span(classes: 'lcd-unit', [text('MHz')]),
          ]),

          // Dial window (etched slit).
          div(classes: 'dial-frame', [
            div(
              classes: 'dial-window',
              events: {
                'pointerdown': _onStripDown,
                'pointermove': _onStripMove,
                'pointerup': _onStripUp,
                'pointercancel': _onStripUp,
              },
              [
                div(
                  classes: 'dial-strip',
                  styles: Styles(
                    width: _stripWidth.px,
                    transform: Transform.translate(x: _stripOffset.px),
                  ),
                  _buildStripChildren(),
                ),
                div(classes: 'needle', []),
                div(classes: 'dial-glass', []),
              ],
            ),
          ]),

          // Rotary knob (ribbed metallic).
          div(
            classes: 'knob',
            events: {
              'pointerdown': _onKnobDown,
              'pointermove': _onKnobMove,
              'pointerup': _onKnobUp,
              'pointercancel': _onKnobUp,
            },
            [
              div(classes: 'knob-cap', [
                div(
                  classes: 'knob-notch',
                  styles: Styles(
                    transform: Transform.rotate(Angle.deg(_knobAngle)),
                  ),
                  [],
                ),
              ]),
            ],
          ),
        ]),
      ],
    );
  }

  Component _indicator(String label, {bool active = false}) {
    return span(
      classes: active ? 'ind ind-on' : 'ind',
      [text(label)],
    );
  }

  // --- strip tick / marker generation ---

  List<Component> _buildStripChildren() {
    final children = <Component>[];

    final startTenth = (minFrequency * 10).round();
    final endTenth = (maxFrequency * 10).round();
    for (var t = startTenth; t <= endTenth; t += 2) {
      final x = (t - startTenth) / 10.0 * _pxPerMhz;
      final isMajor = t % 10 == 0;

      if (isMajor) {
        children.add(div(
          classes: 'tick tick-major',
          styles: Styles(
            position: Position.absolute(left: x.px, top: Unit.zero),
          ),
          [span(classes: 'tick-label', [text('${t ~/ 10}')])],
        ));
      } else {
        children.add(div(
          classes: 'tick tick-minor',
          styles: Styles(
            position: Position.absolute(left: x.px, top: Unit.zero),
          ),
          [],
        ));
      }
    }

    // No station markers — every station is undiscovered. The dial
    // shows only tick marks and frequency numbers; the user has to
    // sweep the band, watch the noise clear up, and listen for
    // signals, like on a real radio.
    return children;
  }

  // --- styles ---

  @css
  static List<StyleRule> get styles => [
    // ── faceplate ──
    css('.radio-panel').styles(
      position: Position.fixed(
        bottom: Unit.zero,
        left: Unit.zero,
        right: Unit.zero,
      ),
      height: 210.px,
      zIndex: ZIndex(50),
      display: Display.flex,
      flexDirection: FlexDirection.column,
      alignItems: AlignItems.stretch,
      padding: Padding.symmetric(horizontal: 18.px, vertical: 14.px),
      raw: {
        // Brushed dark plastic: vertical hairline texture + soft gradient.
        'background':
            'repeating-linear-gradient(90deg, rgba(255,255,255,0.018) 0px, rgba(255,255,255,0.018) 1px, transparent 1px, transparent 3px),'
                'repeating-linear-gradient(0deg, rgba(0,0,0,0.18) 0px, rgba(0,0,0,0.18) 1px, transparent 1px, transparent 2px),'
                'linear-gradient(to bottom, #1d1d24 0%, #14141a 45%, #0a0a10 100%)',
        'border-top': '1px solid #2c2c38',
        'box-shadow':
            'inset 0 1px 0 rgba(255,255,255,0.05), inset 0 -2px 6px rgba(0,0,0,0.6), 0 -8px 24px rgba(0,0,0,0.55)',
        'touch-action': 'none',
        'user-select': 'none',
        '-webkit-user-select': 'none',
      },
    ),
    css('.panel-bevel-top').styles(
      position: Position.absolute(top: Unit.zero, left: Unit.zero),
      width: 100.percent,
      height: 1.px,
      raw: {
        'background':
            'linear-gradient(to right, transparent, rgba(255,255,255,0.18), transparent)',
        'pointer-events': 'none',
      },
    ),

    // ── header ──
    css('.panel-header').styles(
      display: Display.flex,
      flexDirection: FlexDirection.row,
      alignItems: AlignItems.center,
      justifyContent: JustifyContent.spaceBetween,
      raw: {'margin-bottom': '10px'},
    ),
    css('.brand').styles(
      fontFamily: const FontFamily.list([FontFamilies.monospace]),
      fontSize: Unit.pixels(9),
      fontWeight: FontWeight.bold,
      letterSpacing: 0.35.em,
      color: const Color('#0a0a10'),
      raw: {
        'text-shadow':
            '0 1px 0 rgba(255,255,255,0.07), 0 -1px 0 rgba(0,0,0,0.6)',
      },
    ),
    css('.indicator-row').styles(
      display: Display.flex,
      flexDirection: FlexDirection.row,
      gap: Gap(column: 6.px),
    ),
    css('.ind', [
      css('&').styles(
        fontFamily: const FontFamily.list([FontFamilies.monospace]),
        fontSize: Unit.pixels(8),
        fontWeight: FontWeight.bold,
        letterSpacing: 0.15.em,
        padding: Padding.symmetric(horizontal: 5.px, vertical: 2.px),
        color: const Color(_lcdAmberDim),
        radius: BorderRadius.all(Radius.circular(2.px)),
        raw: {
          'background':
              'linear-gradient(to bottom, #0a0a10, #050508)',
          'border': '1px solid #1c1c26',
          'box-shadow': 'inset 0 1px 1px rgba(0,0,0,0.6)',
        },
      ),
      css('&.ind-on').styles(
        color: const Color(_lcdAmber),
        raw: {
          'text-shadow':
              '0 0 4px rgba(255,177,58,0.85), 0 0 8px rgba(255,177,58,0.4)',
          'background':
              'linear-gradient(to bottom, #100904, #050202)',
          'border': '1px solid #2a1a08',
        },
      ),
    ]),

    // ── main row ──
    css('.panel-main').styles(
      display: Display.flex,
      flexDirection: FlexDirection.row,
      alignItems: AlignItems.center,
      justifyContent: JustifyContent.center,
      gap: Gap(column: 16.px),
      raw: {'flex': '1'},
    ),

    // ── LCD readout ──
    css('.lcd').styles(
      position: Position.relative(),
      display: Display.flex,
      flexDirection: FlexDirection.row,
      alignItems: AlignItems.baseline,
      justifyContent: JustifyContent.end,
      gap: Gap(column: 4.px),
      width: 130.px,
      height: 56.px,
      padding: Padding.symmetric(horizontal: 10.px, vertical: 6.px),
      radius: BorderRadius.all(Radius.circular(3.px)),
      overflow: Overflow.hidden,
      raw: {
        'background':
            'linear-gradient(to bottom, #0a0703 0%, #1a0e04 100%)',
        'border': '1px solid #000',
        'box-shadow':
            'inset 0 2px 4px rgba(0,0,0,0.85), inset 0 -1px 1px rgba(255,177,58,0.08), 0 0 14px rgba(255,140,30,0.18), 0 1px 0 rgba(255,255,255,0.05)',
      },
    ),
    css('.lcd-backlight').styles(
      position: Position.absolute(top: Unit.zero, left: Unit.zero),
      width: 100.percent,
      height: 100.percent,
      pointerEvents: PointerEvents.none,
      raw: {
        'background':
            'radial-gradient(ellipse at 50% 50%, rgba(255,160,40,0.18) 0%, rgba(255,120,20,0.05) 60%, transparent 100%)',
      },
    ),
    css('.lcd-ghost').styles(
      position: Position.absolute(),
      fontFamily: const FontFamily.list([FontFamilies.monospace]),
      fontSize: 1.7.rem,
      fontWeight: FontWeight.bold,
      color: const Color('#3a1d05'),
      letterSpacing: 0.05.em,
      raw: {
        'right': '36px',
        'top': '50%',
        'transform': 'translateY(-50%)',
        'opacity': '0.45',
        'pointer-events': 'none',
      },
    ),
    css('.lcd-value').styles(
      position: Position.relative(),
      fontFamily: const FontFamily.list([FontFamilies.monospace]),
      fontSize: 1.7.rem,
      fontWeight: FontWeight.bold,
      color: const Color(_lcdAmber),
      letterSpacing: 0.05.em,
      raw: {
        'text-shadow':
            '0 0 4px rgba(255,177,58,0.95), 0 0 10px rgba(255,140,30,0.6), 0 0 20px rgba(255,100,10,0.35)',
      },
    ),
    css('.lcd-unit').styles(
      position: Position.relative(),
      fontFamily: const FontFamily.list([FontFamilies.monospace]),
      fontSize: Unit.pixels(9),
      fontWeight: FontWeight.bold,
      letterSpacing: 0.15.em,
      color: const Color(_lcdAmber),
      raw: {
        'text-shadow':
            '0 0 3px rgba(255,177,58,0.7), 0 0 6px rgba(255,140,30,0.4)',
      },
    ),

    // ── dial frame (etched slit on the faceplate) ──
    css('.dial-frame').styles(
      padding: Padding.all(3.px),
      radius: BorderRadius.all(Radius.circular(5.px)),
      raw: {
        'background':
            'linear-gradient(to bottom, #050508, #0d0d14)',
        'border': '1px solid #2a2a36',
        'box-shadow':
            'inset 0 1px 2px rgba(0,0,0,0.85), 0 1px 0 rgba(255,255,255,0.05)',
      },
    ),
    css('.dial-window').styles(
      position: Position.relative(),
      width: _windowWidth.px,
      height: 56.px,
      overflow: Overflow.hidden,
      cursor: Cursor.grab,
      radius: BorderRadius.all(Radius.circular(3.px)),
      raw: {
        'background':
            'linear-gradient(to bottom, #02020a 0%, #050512 50%, #02020a 100%)',
        'border-top': '1px solid #000',
        'border-left': '1px solid #000',
        'border-bottom': '1px solid #1a1a26',
        'border-right': '1px solid #1a1a26',
        'box-shadow':
            'inset 0 2px 5px rgba(0,0,0,0.95), inset 0 -1px 1px rgba(255,255,255,0.03)',
      },
    ),
    // Subtle glass reflection across the dial window.
    css('.dial-glass').styles(
      position: Position.absolute(top: Unit.zero, left: Unit.zero),
      width: 100.percent,
      height: 100.percent,
      pointerEvents: PointerEvents.none,
      raw: {
        'background':
            'linear-gradient(to bottom, rgba(255,255,255,0.06) 0%, transparent 30%, transparent 70%, rgba(0,0,0,0.35) 100%)',
      },
    ),

    css('.dial-strip').styles(
      position: Position.absolute(top: Unit.zero),
      height: 100.percent,
      // The strip and its children (ticks, labels, markers) MUST NOT
      // capture pointer events — every press should land on `.dial-window`
      // so its handler / pointer capture session stays attached to the
      // same DOM node across re-renders.
      pointerEvents: PointerEvents.none,
    ),

    // ── ticks (etched look) ──
    css('.tick', [
      css('&').styles(
        width: 1.px,
        raw: {'transform': 'translateX(-50%)'},
      ),
      css('&.tick-major').styles(
        height: 24.px,
        raw: {
          'background':
              'linear-gradient(to bottom, rgba(255,177,58,0.55), rgba(255,177,58,0.15))',
          'box-shadow': '0 0 1px rgba(255,177,58,0.3)',
        },
      ),
      css('&.tick-minor').styles(
        height: 12.px,
        backgroundColor: const Color('#3a3a48'),
      ),
    ]),
    css('.tick-label').styles(
      position: Position.absolute(top: 26.px),
      fontSize: Unit.pixels(9),
      fontFamily: const FontFamily.list([FontFamilies.monospace]),
      color: const Color('#c8964a'),
      letterSpacing: 0.05.em,
      raw: {
        'transform': 'translateX(-50%)',
        'white-space': 'nowrap',
        'text-shadow': '0 0 3px rgba(255,177,58,0.4)',
      },
    ),

    // ── needle ──
    css('.needle').styles(
      position: Position.absolute(top: Unit.zero, left: 50.percent),
      width: 2.px,
      height: 100.percent,
      backgroundColor: const Color('#ff2828'),
      zIndex: ZIndex(5),
      pointerEvents: PointerEvents.none,
      raw: {
        'transform': 'translateX(-50%)',
        'box-shadow':
            '0 0 6px rgba(255,40,40,0.8), 0 0 14px rgba(255,40,40,0.35), inset 0 0 1px rgba(255,255,255,0.6)',
      },
    ),

    // ── ribbed metallic knob ──
    // Children explicitly opt OUT of pointer events so every press lands
    // directly on `.knob` (no bubbling, no listener-swap edge cases).
    css('.knob', [
      css('&').styles(
        width: 68.px,
        height: 68.px,
        radius: BorderRadius.all(Radius.circular(34.px)),
        cursor: Cursor.grab,
        position: Position.relative(),
        raw: {
          // Outer ribbed rim via repeating-conic-gradient.
          'background':
              'repeating-conic-gradient(from 0deg, #555560 0deg 4deg, #1a1a24 4deg 8deg)',
          'box-shadow':
              '0 3px 10px rgba(0,0,0,0.7), 0 1px 0 rgba(255,255,255,0.08), inset 0 0 0 1px rgba(0,0,0,0.6)',
          'touch-action': 'none',
          'flex-shrink': '0',
        },
      ),
      css('&:active').styles(cursor: Cursor.grabbing),
    ]),
    css('.knob-cap').styles(
      position: Position.absolute(),
      pointerEvents: PointerEvents.none,
      raw: {
        'inset': '7px',
        'border-radius': '50%',
        'background':
            'radial-gradient(circle at 38% 32%, #6a6a78 0%, #3a3a45 45%, #1a1a22 100%)',
        'box-shadow':
            'inset 0 1px 2px rgba(255,255,255,0.18), inset 0 -2px 4px rgba(0,0,0,0.6), 0 1px 2px rgba(0,0,0,0.4)',
      },
    ),
    css('.knob-notch').styles(
      position: Position.absolute(top: 5.px, left: 50.percent),
      width: 3.px,
      height: 14.px,
      radius: BorderRadius.all(Radius.circular(1.5.px)),
      pointerEvents: PointerEvents.none,
      raw: {
        'background':
            'linear-gradient(to bottom, #f5f5f8 0%, #c8c8d0 60%, #888894 100%)',
        'box-shadow':
            '0 0 4px rgba(255,255,255,0.55), 0 0 1px rgba(0,0,0,0.6)',
        'transform-origin': '50% 22px',
        'margin-left': '-1.5px',
      },
    ),

    // ── responsive ──
    // ≤600 px: rearrange `.panel-main` into a wrapping flex container
    // so the LCD takes its own full-width row above the dial+knob row.
    // Compacts the LCD itself (smaller font/padding) and shrinks the
    // knob so the whole panel fits in ~150 px of vertical space.
    css.media(MediaQuery.screen(maxWidth: 600.px), [
      css('.radio-panel').styles(
        height: 150.px,
        padding: Padding.symmetric(horizontal: 12.px, vertical: 10.px),
      ),
      css('.panel-header').styles(raw: {'margin-bottom': '6px'}),
      css('.brand').styles(fontSize: Unit.pixels(8)),
      // LCD becomes a full-width banner at the top of the main row.
      css('.panel-main').styles(
        flexWrap: FlexWrap.wrap,
        gap: Gap(row: 8.px, column: 10.px),
        raw: {'align-content': 'center'},
      ),
      css('.lcd').styles(
        width: 100.percent,
        maxWidth: 240.px,
        height: 34.px,
        padding: Padding.symmetric(horizontal: 10.px, vertical: 4.px),
        raw: {'flex': '0 0 100%', 'margin': '0 auto'},
      ),
      css('.lcd-value').styles(fontSize: 1.15.rem),
      css('.lcd-ghost').styles(
        fontSize: 1.15.rem,
        raw: {'right': '32px'},
      ),
      css('.lcd-unit').styles(fontSize: Unit.pixels(8)),
      // Dial + knob sit side by side on the second row.
      css('.dial-window').styles(width: 220.px, height: 48.px),
      css('.knob').styles(width: 50.px, height: 50.px),
      css('.knob-cap').styles(raw: {'inset': '5px'}),
      css('.knob-notch').styles(
        height: 11.px,
        raw: {'transform-origin': '50% 16px'},
      ),
    ]),
    // ≤380 px: very narrow phones — squeeze the dial slightly more.
    css.media(MediaQuery.screen(maxWidth: 380.px), [
      css('.dial-window').styles(width: 188.px),
      css('.lcd').styles(maxWidth: 200.px, height: 30.px),
      css('.lcd-value').styles(fontSize: 1.0.rem),
      css('.lcd-ghost').styles(
        fontSize: 1.0.rem,
        raw: {'right': '28px'},
      ),
      css('.knob').styles(width: 46.px, height: 46.px),
      css('.knob-notch').styles(
        height: 10.px,
        raw: {'transform-origin': '50% 14px'},
      ),
    ]),
  ];
}
