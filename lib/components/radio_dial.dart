import 'dart:async';

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

// Amber-LED palette — warm Pioneer/Kenwood segment colour. Matches the
// text-shadow values below; change both together or the glow goes off.
const String _lcdAmber = '#E8A035';
const String _lcdAmberDim = '#6d4a0e';

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
    this.volume = 0.0,
    this.onVolumeChanged,
    super.key,
  });

  final double frequency;
  final ValueChanged<double> onFrequencyChanged;
  final double signalStrength;
  final Station? activeStation;

  /// Current master volume [0.0 – 1.0]. Drives both the small volume
  /// knob's notch rotation and the colour of the power LED embedded
  /// in its cap (amber when 0, green otherwise).
  final double volume;

  /// Reports volume changes from the volume-knob drag gesture.
  final ValueChanged<double>? onVolumeChanged;

  @override
  State<RadioDial> createState() => RadioDialState();
}

class RadioDialState extends State<RadioDial> {
  // --- drag state ---
  bool _draggingStrip = false;
  bool _draggingKnob = false;
  bool _draggingVol = false;
  double _dragStartFreq = 0;
  double _dragStartX = 0;
  double _dragStartY = 0;

  // Volume-knob drag start: cache the initial volume + Y so every
  // move event computes from the anchor rather than accumulating
  // floating-point error.
  double _volDragStartVolume = 0;
  double _volDragStartY = 0;

  /// Pixels of vertical drag that equal a full 0→1 volume sweep.
  static const double _volPxPerFull = 120.0;

  // --- LCD tap glitch ---
  // Incrementing counter used to force the tap animation to restart on
  // consecutive taps — the value is embedded in the inline `animation`
  // shorthand (via a varying `animation-delay`), which makes the
  // browser treat each tap as a fresh animation run. `_lcdTapTimer`
  // clears the counter back to 0 once the animation finishes, which
  // removes the inline override and lets the base LCD animation
  // resume.
  int _lcdTapNonce = 0;
  Timer? _lcdTapTimer;
  static const Duration _lcdTapDuration = Duration(milliseconds: 850);

  // --- helpers ---

  double get _freq => component.frequency;

  double get _stripOffset {
    final freqX = (_freq - minFrequency) * _pxPerMhz;
    return -(freqX - _windowWidth / 2);
  }

  double get _knobAngle {
    return ((_freq - minFrequency) / (maxFrequency - minFrequency)) * 270 - 135;
  }

  /// Notch rotation for the volume knob: -135° at volume 0 (fully
  /// counter-clockwise, "off" position) → +135° at volume 1.
  double get _volAngle => component.volume * 270.0 - 135.0;

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

  // --- volume knob drag ---

  void _onVolDown(web.Event event) {
    final pe = event as web.PointerEvent;
    (pe.currentTarget as web.Element).setPointerCapture(pe.pointerId);
    _draggingVol = true;
    _volDragStartVolume = component.volume;
    _volDragStartY = _clientY(pe);
  }

  void _onVolMove(web.Event event) {
    if (!_draggingVol) return;
    final pe = event as web.PointerEvent;
    // Drag up (negative dy) raises volume, drag down lowers it.
    final dy = _clientY(pe) - _volDragStartY;
    final next =
        (_volDragStartVolume - dy / _volPxPerFull).clamp(0.0, 1.0);
    component.onVolumeChanged?.call(next);
  }

  void _onVolUp(web.Event event) {
    if (!_draggingVol) return;
    _draggingVol = false;
    final pe = event as web.PointerEvent;
    (pe.currentTarget as web.Element).releasePointerCapture(pe.pointerId);
  }

  // --- wheel on panel ---

  // --- LCD tap ---

  void _onLcdTap(web.Event _) {
    _lcdTapTimer?.cancel();
    setState(() => _lcdTapNonce++);
    _lcdTapTimer = Timer(_lcdTapDuration, () {
      if (mounted) {
        setState(() => _lcdTapNonce = 0);
      }
    });
  }

  @override
  void dispose() {
    _lcdTapTimer?.cancel();
    super.dispose();
  }

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
          span(classes: 'brand', [text('RADIO')]),
          div(classes: 'indicator-row', [
            _indicator('FM', active: true),
            _indicator('AM'),
            _indicator('ST', active: tuned),
            _indicator('MONO'),
          ]),
        ]),

        // Main row: volume knob + LCD + dial window + tuning knob.
        div(classes: 'panel-main', [
          // Volume knob (small, doubles as power switch — volume 0
          // is "off"). Drag up to raise, down to lower. Embedded LED
          // turns green once any audio is audible.
          div(classes: 'vol-knob-wrap', [
            div(
              classes: 'vol-knob',
              events: {
                'pointerdown': _onVolDown,
                'pointermove': _onVolMove,
                'pointerup': _onVolUp,
                'pointercancel': _onVolUp,
              },
              [
                div(classes: 'vol-knob-cap', [
                  div(
                    classes: 'vol-knob-notch',
                    styles: Styles(
                      transform:
                          Transform.rotate(Angle.deg(_volAngle)),
                    ),
                    [],
                  ),
                  div(
                    classes: 'knob-led'
                        '${component.volume > 0 ? ' knob-led-on' : ''}',
                    [],
                  ),
                ]),
              ],
            ),
            div(classes: 'vol-knob-label', [text('VOL')]),
          ]),

          // LCD frequency readout. Clicking/tapping runs the tap-
          // glitch animation via an inline override; the nonce in the
          // animation-delay forces a restart on each consecutive tap.
          div(
            classes: 'lcd${tuned ? ' lcd-locked' : ''}',
            events: {'click': _onLcdTap},
            styles: _lcdTapNonce > 0
                ? Styles(raw: {
                    'animation':
                        'lcd-tap-glitch 0.8s step-end ${(_lcdTapNonce * 0.0001).toStringAsFixed(4)}s',
                  })
                : null,
            [
            // Faded "ghost" segments behind the live digits, like the
            // unlit cells on a real 7-segment LED panel. Uses `188.8`
            // which lights every segment (once our font matches).
            span(classes: 'lcd-ghost', [text('188.8')]),
            span(classes: 'lcd-value', [text(_freq.toStringAsFixed(1))]),
            // Right-side badges: always-on "FM" + station-lock "ST".
            div(classes: 'lcd-badges', [
              span(classes: 'lcd-fm', [text('FM')]),
              span(
                classes: 'lcd-st${tuned ? ' is-lit' : ''}',
                [text('ST')],
              ),
            ]),
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

          // Tuning knob (ribbed metallic). Drag up/down to tune.
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
    // Three-column grid: LCD on the left, dial-strip in the middle,
    // and a stacked knob column on the right (VOL on top, TUNE below).
    // Both LCD and dial span the two knob rows and centre themselves
    // vertically against the knob stack.
    //
    //   ┌──────┬─────────────┬──────┐
    //   │      │             │ VOL  │
    //   │ LCD  │    dial     ├──────┤
    //   │      │             │ TUNE │
    //   └──────┴─────────────┴──────┘
    css('.panel-main').styles(
      raw: {
        'display': 'grid',
        'grid-template-columns': 'auto 1fr auto',
        'grid-template-rows': 'auto auto',
        'grid-template-areas': '"lcd dial vol" "lcd dial tune"',
        'column-gap': '16px',
        'row-gap': '6px',
        'align-items': 'center',
        'align-content': 'center',
        'justify-items': 'stretch',
        'flex': '1',
      },
    ),
    // Fixed grid placements — the same media-query breakpoints just
    // change the grid *template*, never the per-item `grid-area`.
    css('.lcd').styles(raw: {'grid-area': 'lcd'}),
    css('.dial-frame').styles(raw: {'grid-area': 'dial'}),
    css('.vol-knob-wrap').styles(raw: {'grid-area': 'vol'}),
    css('.knob').styles(raw: {'grid-area': 'tune'}),

    // ── LCD readout (aged backlit-LCD look) ──
    // The layered backgrounds, top to bottom, are:
    //   1. A tight diagonal noise pattern (micro-scratches on the
    //      plastic lens, low opacity).
    //   2. A dark radial patch in the upper-right corner — the one
    //      zone where the backlight has faded more than the rest.
    //   3. An off-centre main amber gradient, muted and
    //      desaturated, like a 90s LCD that's been running for 20
    //      years.
    css('.lcd', [
      css('&').styles(
        position: Position.relative(),
        display: Display.flex,
        flexDirection: FlexDirection.row,
        alignItems: AlignItems.center,
        justifyContent: JustifyContent.end,
        gap: Gap(column: 6.px),
        width: 140.px,
        height: 56.px,
        padding: Padding.symmetric(horizontal: 12.px, vertical: 6.px),
        radius: BorderRadius.all(Radius.circular(3.px)),
        overflow: Overflow.hidden,
        raw: {
          'background':
              // 1) Wear / micro-scratch noise.
              'repeating-linear-gradient(47deg, '
                  'rgba(0,0,0,0.055) 0px, '
                  'rgba(0,0,0,0.055) 1px, '
                  'transparent 1px, '
                  'transparent 3px),'
                  // 2) Dead-corner shadow (top-right).
                  'radial-gradient(circle at 82% 18%, '
                  'rgba(0,0,0,0.28) 0%, '
                  'transparent 48%),'
                  // 3) Main backlight — off-centre, muted amber.
                  'radial-gradient(ellipse at 42% 55%, '
                  '#A67820 0%, '
                  '#8B6418 55%, '
                  '#6E4C10 100%)',
          'border': '1px solid #000',
          // Bevel preserved; outer bleed dialed back ~60% — old
          // backlight barely leaks light anymore.
          'box-shadow':
              'inset 0 2px 4px rgba(0,0,0,0.5), '
                  'inset 0 -1px 2px rgba(0,0,0,0.3), '
                  'inset 0 0 0 1px rgba(0,0,0,0.55), '
                  '0 0 8px rgba(166,120,32,0.22), '
                  '0 0 18px rgba(166,120,32,0.1), '
                  '0 1px 0 rgba(255,255,255,0.04)',
          'transition': 'box-shadow 0.3s ease, background 0.3s ease',
          // Rare worn-LCD glitches — step-end so value changes jump
          // rather than interpolate (reads like a fault, not a tween).
          // Disabled by `.lcd-locked` below.
          'animation': 'lcd-glitch 25s step-end infinite',
        },
      ),
      // "Glass" overlay — yellowed with age, diffused reflection.
      // Warm faded highlight up top, brownish mid-cast from oxidised
      // plastic, darker lower edge.
      css('&::after').styles(
        position: Position.absolute(top: Unit.zero, left: Unit.zero),
        width: 100.percent,
        height: 100.percent,
        pointerEvents: PointerEvents.none,
        raw: {
          'content': '""',
          'background':
              'linear-gradient(to bottom, '
                  'rgba(255,225,160,0.1) 0%, '
                  'rgba(210,170,100,0.05) 35%, '
                  'rgba(140,100,50,0.05) 55%, '
                  'transparent 75%, '
                  'rgba(40,25,10,0.18) 100%)',
        },
      ),
    ]),

    // Locked state — the backlight comes up a bit (like the amplifier
    // drawing slightly more current once a carrier is found), but it
    // never approaches "brand new" brightness.
    css('.lcd-locked').styles(
      raw: {
        'background':
            'repeating-linear-gradient(47deg, '
                'rgba(0,0,0,0.055) 0px, '
                'rgba(0,0,0,0.055) 1px, '
                'transparent 1px, '
                'transparent 3px),'
                'radial-gradient(circle at 82% 18%, '
                'rgba(0,0,0,0.22) 0%, '
                'transparent 48%),'
                'radial-gradient(ellipse at 42% 55%, '
                '#C28A26 0%, '
                '#9C711C 55%, '
                '#78530F 100%)',
        'box-shadow':
            'inset 0 2px 4px rgba(0,0,0,0.5), '
                'inset 0 -1px 2px rgba(0,0,0,0.3), '
                'inset 0 0 0 1px rgba(0,0,0,0.55), '
                '0 0 12px rgba(198,140,48,0.32), '
                '0 0 22px rgba(166,120,32,0.14), '
                '0 1px 0 rgba(255,255,255,0.04)',
        // A locked station is the "clean signal" moment — no glitches.
        'animation': 'none',
      },
    ),

    // "Off" ghost segments — slightly more visible than before
    // (polariser degradation leaking more light through unused
    // segments).
    css('.lcd-ghost').styles(
      position: Position.absolute(),
      fontFamily: const FontFamily.list([
        FontFamily('Orbitron'),
        FontFamilies.monospace,
      ]),
      fontSize: 1.55.rem,
      fontWeight: FontWeight.w700,
      color: const Color('#000000'),
      letterSpacing: 0.08.em,
      raw: {
        'right': '42px',
        'top': '50%',
        'transform': 'translateY(-50%)',
        'opacity': '0.10',
        'pointer-events': 'none',
      },
    ),

    // Live digits — dark segments, no longer pure black. A faded
    // brown-black reads as aged LCD ink rather than crisp new print.
    css('.lcd-value').styles(
      position: Position.relative(),
      fontFamily: const FontFamily.list([
        FontFamily('Orbitron'),
        FontFamilies.monospace,
      ]),
      fontSize: 1.55.rem,
      fontWeight: FontWeight.w700,
      color: const Color('#2a1f10'),
      letterSpacing: 0.08.em,
      raw: {
        'text-shadow': '0 1px 0 rgba(0,0,0,0.12)',
        'transition': 'color 0.3s ease, text-shadow 0.3s ease',
      },
    ),
    css('.lcd-locked .lcd-value').styles(
      color: const Color('#1f1608'),
      raw: {'text-shadow': '0 1px 0 rgba(0,0,0,0.18)'},
    ),

    // Right-side badges — aged ink dark, ST still flips to a tiny
    // green LED on lock (with a softer glow to match the tired
    // panel).
    css('.lcd-badges').styles(
      position: Position.relative(),
      display: Display.flex,
      flexDirection: FlexDirection.column,
      alignItems: AlignItems.start,
      raw: {'gap': '2px'},
    ),
    css('.lcd-fm').styles(
      fontFamily: const FontFamily.list([
        FontFamily('Orbitron'),
        FontFamilies.monospace,
      ]),
      fontSize: Unit.pixels(10),
      fontWeight: FontWeight.w700,
      letterSpacing: 0.2.em,
      color: const Color('#2a1f10'),
      raw: {'opacity': '0.5'},
    ),
    css('.lcd-st', [
      css('&').styles(
        fontFamily: const FontFamily.list([
          FontFamily('Orbitron'),
          FontFamilies.monospace,
        ]),
        fontSize: Unit.pixels(9),
        fontWeight: FontWeight.w700,
        letterSpacing: 0.2.em,
        color: const Color('#2a1f10'),
        raw: {
          'opacity': '0.22',
          'transition':
              'color 0.25s ease, opacity 0.25s ease, text-shadow 0.25s ease',
        },
      ),
      css('&.is-lit').styles(
        color: const Color('#0f3a0b'),
        raw: {
          'opacity': '0.95',
          'text-shadow':
              '0 0 2px rgba(100,200,80,0.7), '
                  '0 0 6px rgba(100,200,80,0.35)',
        },
      ),
    ]),

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

    // ── volume knob (smaller sibling of the tuning knob) ──
    // Geometry mirrors `.knob` at 36 px (52% of the tuner's 68 px).
    // The LED inside doubles as the power indicator — amber at
    // volume 0, green for any non-zero volume.
    css('.vol-knob-wrap').styles(
      display: Display.flex,
      flexDirection: FlexDirection.column,
      alignItems: AlignItems.center,
      gap: Gap(row: 3.px),
      raw: {'flex-shrink': '0'},
    ),
    css('.vol-knob', [
      css('&').styles(
        width: 36.px,
        height: 36.px,
        radius: BorderRadius.all(Radius.circular(18.px)),
        cursor: Cursor.grab,
        position: Position.relative(),
        raw: {
          'background':
              'repeating-conic-gradient(from 0deg, #555560 0deg 4deg, #1a1a24 4deg 8deg)',
          'box-shadow':
              '0 2px 6px rgba(0,0,0,0.65), 0 1px 0 rgba(255,255,255,0.08), inset 0 0 0 1px rgba(0,0,0,0.6)',
          'touch-action': 'none',
          'flex-shrink': '0',
        },
      ),
      css('&:active').styles(cursor: Cursor.grabbing),
    ]),
    css('.vol-knob-cap').styles(
      position: Position.absolute(),
      pointerEvents: PointerEvents.none,
      raw: {
        'inset': '4px',
        'border-radius': '50%',
        'background':
            'radial-gradient(circle at 38% 32%, #6a6a78 0%, #3a3a45 45%, #1a1a22 100%)',
        'box-shadow':
            'inset 0 1px 1.5px rgba(255,255,255,0.18), inset 0 -1.5px 3px rgba(0,0,0,0.6), 0 1px 2px rgba(0,0,0,0.4)',
      },
    ),
    css('.vol-knob-notch').styles(
      position: Position.absolute(top: 3.px, left: 50.percent),
      width: 2.px,
      height: 8.px,
      radius: BorderRadius.all(Radius.circular(1.px)),
      pointerEvents: PointerEvents.none,
      raw: {
        'background':
            'linear-gradient(to bottom, #f5f5f8 0%, #c8c8d0 60%, #888894 100%)',
        'box-shadow':
            '0 0 3px rgba(255,255,255,0.55), 0 0 1px rgba(0,0,0,0.6)',
        'transform-origin': '50% 11px',
        'margin-left': '-1px',
      },
    ),
    // Smaller LED inside the smaller knob.
    css('.vol-knob-cap .knob-led').styles(
      width: 5.px,
      height: 5.px,
      radius: BorderRadius.all(Radius.circular(2.5.px)),
    ),
    css('.vol-knob-label').styles(
      fontFamily: const FontFamily.list([FontFamilies.monospace]),
      fontSize: Unit.pixels(8),
      fontWeight: FontWeight.w500,
      letterSpacing: 0.2.em,
      color: const Color(_lcdAmberDim),
      raw: {
        'text-transform': 'uppercase',
        'text-shadow': '0 1px 0 rgba(0,0,0,0.6)',
        'user-select': 'none',
        '-webkit-user-select': 'none',
      },
    ),

    // ── embedded power LED ──
    // A 6 px dot recessed into the top of the knob cap, roughly 22%
    // from the top edge. Amber/dim by default; turns green with a
    // soft glow when volume > 0. Sits on the non-rotating cap so
    // it doesn't spin with the notch.
    css('.knob-led', [
      css('&').styles(
        position: Position.absolute(top: 22.percent, left: 50.percent),
        width: 6.px,
        height: 6.px,
        radius: BorderRadius.all(Radius.circular(3.px)),
        pointerEvents: PointerEvents.none,
        backgroundColor: const Color('#4a3418'),
        raw: {
          'transform': 'translate(-50%, -50%)',
          // Outer ring = recessed socket; inner inset = dark well.
          'box-shadow':
              'inset 0 1px 1.5px rgba(0,0,0,0.75), 0 0 0 1px rgba(0,0,0,0.55), 0 1px 0 rgba(255,255,255,0.06)',
          'transition':
              'background-color 0.2s ease, box-shadow 0.2s ease',
        },
      ),
      css('&.knob-led-on').styles(
        backgroundColor: const Color('#3fc46a'),
        raw: {
          'box-shadow':
              'inset 0 1px 1.5px rgba(0,0,0,0.45), 0 0 0 1px rgba(0,0,0,0.55), 0 0 5px rgba(63,196,106,0.7), 0 0 10px rgba(63,196,106,0.35)',
        },
      ),
    ]),

    // ── responsive ──
    // ≤600 px: 3-column grid so we get a
    // Row[ VOL, Column[LCD, dial], TUNE ] layout without a DOM wrapper.
    //
    //   ┌──────┬──────────────┬────────┐
    //   │ VOL  │     LCD      │        │
    //   │      ├──────────────┤  TUNE  │
    //   ┌──────────────┬────────┐
    //   │     LCD      │        │  row 1
    //   ├──────────────┤  VOL   │  row 2
    //   │              ├────────┤
    //   │  dial strip  │  TUNE  │  row 3
    //   └──────────────┴────────┘
    //
    // LCD spans the full top row; the dial occupies rows 2–3 on the
    // left; VOL (row 2) and TUNE (row 3) share the right column,
    // stacking the two knobs vertically like a real car stereo.
    css.media(MediaQuery.screen(maxWidth: 600.px), [
      css('.radio-panel').styles(
        height: 180.px,
        padding: Padding.symmetric(horizontal: 12.px, vertical: 8.px),
      ),
      css('.brand').styles(display: Display.none),
      css('.panel-header').styles(
        raw: {'margin-bottom': '6px', 'justify-content': 'flex-end'},
      ),
      css('.indicator-row .ind:nth-child(2), .indicator-row .ind:nth-child(4)')
          .styles(display: Display.none),
      css('.indicator-row').styles(gap: Gap(column: 4.px)),
      css('.ind').styles(
        fontSize: Unit.pixels(7),
        padding: Padding.symmetric(horizontal: 4.px, vertical: 1.px),
        raw: {'letter-spacing': '0.12em'},
      ),
      css('.panel-main').styles(
        raw: {
          'grid-template-columns': '1fr auto',
          'grid-template-rows': 'auto 1fr 1fr',
          'grid-template-areas': '"lcd lcd" "dial vol" "dial tune"',
          'column-gap': '10px',
          'row-gap': '6px',
        },
      ),
      css('.vol-knob').styles(width: 32.px, height: 32.px),
      css('.vol-knob-cap').styles(raw: {'inset': '3px'}),
      css('.vol-knob-notch').styles(
        height: 7.px,
        raw: {'top': '2px', 'transform-origin': '50% 10px'},
      ),
      css('.vol-knob-label').styles(fontSize: Unit.pixels(7)),
      css('.lcd').styles(
        height: 34.px,
        padding: Padding.symmetric(horizontal: 10.px, vertical: 4.px),
        raw: {
          'width': '100%',
          'max-width': 'none',
          'margin': '0',
          'flex': 'initial',
        },
      ),
      css('.lcd-value').styles(fontSize: 1.15.rem),
      css('.lcd-ghost').styles(
        fontSize: 1.15.rem,
        raw: {'right': '32px'},
      ),
      css('.lcd-fm').styles(fontSize: Unit.pixels(9)),
      css('.lcd-st').styles(fontSize: Unit.pixels(8)),
      css('.dial-frame').styles(raw: {'width': '100%'}),
      css('.dial-window').styles(
        height: 44.px,
        raw: {'width': '100%', 'max-width': 'none', 'flex': 'initial'},
      ),
      css('.knob').styles(
        width: 46.px,
        height: 46.px,
        raw: {'flex': 'initial'},
      ),
      css('.knob-cap').styles(raw: {'inset': '5px'}),
      css('.knob-notch').styles(
        height: 10.px,
        raw: {'transform-origin': '50% 14px'},
      ),
    ]),
    // ≤380 px: very narrow phones — just tighten the LCD + pill type.
    // Knob sizes already shrunk in the ≤600 block.
    css.media(MediaQuery.screen(maxWidth: 380.px), [
      css('.lcd').styles(height: 30.px),
      css('.lcd-value').styles(fontSize: 1.0.rem),
      css('.lcd-ghost').styles(
        fontSize: 1.0.rem,
        raw: {'right': '26px'},
      ),
      css('.lcd-fm').styles(fontSize: Unit.pixels(8)),
      css('.lcd-st').styles(fontSize: Unit.pixels(7)),
    ]),
  ];
}
