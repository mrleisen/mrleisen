import 'dart:async';
import 'dart:math' as math;

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:universal_web/js_interop.dart';
import 'package:universal_web/web.dart' as web;

import '../models/station.dart';
import '../utils/keyboard.dart';
import '../utils/motion.dart';
import 'collected_stations.dart';
import 'radio_audio.dart' show unlockAudioContext;
import 'station_display.dart' show Lang;

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

// Amber-LED palette - warm Pioneer/Kenwood segment colour. Matches the
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
    required this.band,
    required this.onFrequencyChanged,
    required this.isPowered,
    this.signalStrength = 0.0,
    this.activeStation,
    this.volume = 0.0,
    this.onVolumeChanged,
    this.onPowerToggle,
    this.onBandSelect,
    this.collectedStations = const [],
    this.onRecallStation,
    this.onDeleteStation,
    this.canSaveCurrent = false,
    this.onSaveStation,
    this.lang = Lang.en,
    this.showPowerHint = false,
    this.showPowerAttract = false,
    this.showTuneHint = false,
    super.key,
  });

  final double frequency;
  final Band band;
  final ValueChanged<double> onFrequencyChanged;
  final double signalStrength;
  final Station? activeStation;

  /// Current master volume [0.0 – 1.0]. Drives both the small volume
  /// knob's notch rotation and the colour of the power LED embedded
  /// in its cap (amber when 0, green otherwise).
  final double volume;

  /// Reports volume changes from the volume-knob drag gesture.
  final ValueChanged<double>? onVolumeChanged;

  /// Whether the radio is powered on. When false the panel dims and
  /// every control except the power button is non-interactive.
  final bool isPowered;

  /// Fires when the user taps the power toggle. Runs inside the raw
  /// user gesture - on the first power-on, [unlockAudioContext] is
  /// called synchronously just before this to satisfy mobile autoplay
  /// policy.
  final VoidCallback? onPowerToggle;

  /// Fires when the user taps an FM/AM indicator pill to switch
  /// bands. No-op when the radio is powered off or the requested
  /// band is already active.
  final void Function(Band)? onBandSelect;

  /// Stations the user has locked onto at least once this session.
  /// Rendered as a row of LCD-styled pills between the header and the
  /// main row, so they read as a built-in preset rack on the faceplate.
  final List<Station> collectedStations;

  /// Tap handler for a pill in [collectedStations]. Receives the
  /// station to jump to; parent handles band switching + tuning.
  final void Function(Station)? onRecallStation;

  /// Press-and-hold handler - fires when the user holds a pill long
  /// enough to wipe it from the rack. Same hardware metaphor as
  /// holding a preset button on a 90s car stereo.
  final void Function(Station)? onDeleteStation;

  /// True when the dial is locked onto a station that hasn't been
  /// saved yet - drives the MEM button's armed/disabled visual state.
  final bool canSaveCurrent;

  /// Fires when the user presses MEM. Parent commits the current
  /// active station into its collected set.
  final VoidCallback? onSaveStation;

  /// UI language, used only for the onboarding microcopy.
  final Lang lang;

  /// Radio is off: print the etched instruction beside the rocker.
  /// Shown every time the receiver is off, not only on a first visit.
  final bool showPowerHint;

  /// Radio is off *and* has never been switched on: also pulse the
  /// rocker. Retired permanently after the first power-on.
  final bool showPowerAttract;

  /// Radio is warm but the dial has never been moved. Prints the tuning
  /// instruction across the dial window.
  final bool showTuneHint;

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
  // consecutive taps - the value is embedded in the inline `animation`
  // shorthand (via a varying `animation-delay`), which makes the
  // browser treat each tap as a fresh animation run. `_lcdTapTimer`
  // clears the counter back to 0 once the animation finishes, which
  // removes the inline override and lets the base LCD animation
  // resume.
  int _lcdTapNonce = 0;
  Timer? _lcdTapTimer;
  static const Duration _lcdTapDuration = Duration(milliseconds: 850);

  // --- MEM button flash ---
  // Brief amber pulse on press, just to confirm the save happened
  // (the new pill in the collected row is the real confirmation;
  // this is tactile feedback on the button itself).
  bool _memFlash = false;
  Timer? _memFlashTimer;
  static const Duration _memFlashDuration = Duration(milliseconds: 550);

  // --- band change ---
  // Drives the dial's re-rack animation. Held as a nonce rather than a
  // bool so two band flips in quick succession restart the keyframe
  // instead of the second one being swallowed.
  int _bandSweepNonce = 0;
  Timer? _bandSweepTimer;
  static const Duration _bandSweepDuration = Duration(milliseconds: 620);

  // --- lock acknowledgement ---
  // Brief "SIGNAL LOCKED" takeover of the LCD the instant a station is
  // captured. See [_flashLocked].
  bool _lockFlash = false;
  Timer? _lockFlashTimer;
  static const Duration _lockFlashDuration = Duration(milliseconds: 900);

  // --- LCD digit scramble ---
  // While [_scrambleValue] is non-null it replaces the live frequency
  // in the LCD. A periodic timer swaps it for fresh random values every
  // [_scrambleTickDuration] until [_scrambleTotalTicks] iterations have
  // run, producing a brief "display rebooting" readout. Triggered on
  // power-on (after a short delay) and on any LCD tap.
  bool _isScrambling = false;
  int _scrambleCount = 0;
  String? _scrambleValue;
  Timer? _scrambleTimer;
  Timer? _scramblePowerOnTimer;
  static final math.Random _scrambleRng = math.Random();
  static const Duration _scrambleTickDuration = Duration(milliseconds: 60);
  static const int _scrambleTotalTicks = 9;
  static const Duration _scramblePowerOnDelay = Duration(milliseconds: 300);

  // --- helpers ---

  double get _freq => component.frequency;
  BandConfig get _cfg => configFor(component.band);

  /// Total width of the scrollable strip in pixels for the active band.
  double get _stripWidth => ((_cfg.maxFreq - _cfg.minFreq) / _cfg.step) * _cfg.pxPerStep;

  /// Horizontal translation applied to `.dial-strip`.
  ///
  /// The strip is CSS-anchored at `left: 50%` of `.dial-window` (i.e.
  /// its left edge sits on the needle, which is also at `left: 50%`).
  /// Shifting it by `-freqX` drops the strip-local tick for the current
  /// frequency exactly on the needle, independent of the actual window
  /// width. This is what lets the dial stretch to fill whatever grid
  /// cell it lands in without the needle drifting off-tick.
  double get _stripOffset => -((_freq - _cfg.minFreq) / _cfg.step) * _cfg.pxPerStep;

  double get _knobAngle {
    return ((_freq - _cfg.minFreq) / (_cfg.maxFreq - _cfg.minFreq)) * 270 - 135;
  }

  /// Notch rotation for the volume knob: -135° at volume 0 (fully
  /// counter-clockwise, "off" position) → +135° at volume 1.
  double get _volAngle => component.volume * 270.0 - 135.0;

  /// The tuned frequency as it should be spoken: "FM 97.7 MHz".
  String _spokenFrequency() {
    final isFm = component.band == Band.fm;
    final value = isFm ? _freq.toStringAsFixed(1) : _freq.toInt().toString();
    return '${component.band.name.toUpperCase()} $value ${isFm ? 'MHz' : 'kHz'}';
  }

  /// Volume as a spoken percentage.
  String _spokenVolume() => '${(component.volume * 100).round()}%';

  /// Arrow-key handling for the volume knob.
  ///
  /// The knob is drag-only by pointer, which made master volume the one
  /// control with no keyboard path at all. Up/Right raise, Down/Left
  /// lower, Home/End jump to the extremes - the conventions a native
  /// range input would give for free.
  void _onVolKeyDown(web.Event e) {
    final ke = e as web.KeyboardEvent;
    if (!component.isPowered) return;
    const stepSize = 0.05;
    double? next;
    switch (ke.key) {
      case 'ArrowUp':
      case 'ArrowRight':
        next = component.volume + stepSize;
      case 'ArrowDown':
      case 'ArrowLeft':
        next = component.volume - stepSize;
      case 'Home':
        next = 0.0;
      case 'End':
        next = 1.0;
    }
    if (next == null) return;
    // Stop the document-level handler from also treating Left/Right as
    // a tuning gesture while focus is on the volume knob.
    ke.preventDefault();
    ke.stopPropagation();
    component.onVolumeChanged?.call(next.clamp(0.0, 1.0));
  }

  /// Fraction of the remaining gap a drag gives up to a nearby station.
  ///
  /// Low on purpose. This is meant to feel like the dial finding its
  /// detent, not like the control being taken away: at 0.28 the pull is
  /// noticeable but a steady hand still lands wherever it wants, and
  /// sweeping straight past a station is unaffected because the pull
  /// only ever moves you a fraction of the way in.
  static const double _magnetStrength = 0.28;

  /// Applies a gentle pull toward a station once the drag is inside its
  /// lock range.
  ///
  /// Only while dragging: keyboard tuning and preset recalls address
  /// exact frequencies, and bending those would be a bug, not a feel.
  double _magnetise(double v) {
    if (!(_draggingStrip || _draggingKnob)) return v;
    final cfg = _cfg;
    for (final s in stationsFor(component.band)) {
      final d = (v - s.frequency).abs();
      if (d > 0 && d < cfg.lockRange) {
        return v + (s.frequency - v) * _magnetStrength;
      }
    }
    return v;
  }

  void _setFrequency(double v) {
    final cfg = _cfg;
    v = _magnetise(v);
    if (cfg.step < 1.0) {
      final scale = (1.0 / cfg.step).roundToDouble();
      v = (v * scale).roundToDouble() / scale;
    } else {
      v = (v / cfg.step).roundToDouble() * cfg.step;
    }
    v = v.clamp(cfg.minFreq, cfg.maxFreq);
    component.onFrequencyChanged(v);
  }

  // --- strip drag ---

  void _onStripDown(web.Event event) {
    if (!component.isPowered) return;
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
    // Strip pixels → frequency via pxPerStep: each step is
    // `pxPerStep` pixels wide, so dx / pxPerStep = steps of drag.
    final cfg = _cfg;
    _setFrequency(_dragStartFreq - (dx / cfg.pxPerStep) * cfg.step);
  }

  void _onStripUp(web.Event event) {
    if (!_draggingStrip) return;
    _draggingStrip = false;
    final pe = event as web.PointerEvent;
    (pe.currentTarget as web.Element).releasePointerCapture(pe.pointerId);
  }

  // --- knob drag ---

  void _onKnobDown(web.Event event) {
    if (!component.isPowered) return;
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
    // 1.5 steps per pixel keeps FM at the original 0.15 MHz/px feel
    // and scales AM to 15 kHz/px.
    _setFrequency(_dragStartFreq - dy * (_cfg.step * 1.5));
  }

  void _onKnobUp(web.Event event) {
    if (!_draggingKnob) return;
    _draggingKnob = false;
    final pe = event as web.PointerEvent;
    (pe.currentTarget as web.Element).releasePointerCapture(pe.pointerId);
  }

  // --- volume knob drag ---

  void _onVolDown(web.Event event) {
    if (!component.isPowered) return;
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
    final next = (_volDragStartVolume - dy / _volPxPerFull).clamp(0.0, 1.0);
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
    if (!component.isPowered) return;
    _triggerLcdGlitch();
    _startScramble();
  }

  /// Runs the one-shot opacity-flicker keyframe on the LCD. Used by
  /// [_onLcdTap] and by the power-on sequence in [didUpdateComponent].
  void _triggerLcdGlitch() {
    // The glitch itself is a CSS keyframe that reduced-motion already
    // suppresses; bailing here just avoids the pointless render churn.
    if (prefersReducedMotion) return;
    _lcdTapTimer?.cancel();
    setState(() => _lcdTapNonce++);
    _lcdTapTimer = Timer(_lcdTapDuration, () {
      if (mounted) {
        setState(() => _lcdTapNonce = 0);
      }
    });
  }

  /// Kicks off the digit scramble: ~9 random FM readouts at 60 ms
  /// intervals, then clears [_scrambleValue] so the live frequency
  /// text returns. Safe to call while a previous scramble is still
  /// running - the in-flight timer is cancelled and restarted.
  ///
  /// Under reduced motion the LCD skips straight to the settled value.
  /// This one can't be handled in CSS: the scramble swaps the rendered
  /// digits rather than animating a property, so a stylesheet has
  /// nothing to switch off.
  void _startScramble() {
    if (prefersReducedMotion) {
      _scrambleTimer?.cancel();
      if (_isScrambling || _scrambleValue != null) {
        setState(() {
          _isScrambling = false;
          _scrambleValue = null;
        });
      }
      return;
    }
    _scrambleTimer?.cancel();
    _scrambleCount = 0;
    setState(() {
      _isScrambling = true;
      _scrambleValue = _randomFreqString();
    });
    _scrambleTimer = Timer.periodic(_scrambleTickDuration, (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      _scrambleCount++;
      if (_scrambleCount >= _scrambleTotalTicks) {
        timer.cancel();
        setState(() {
          _isScrambling = false;
          _scrambleValue = null;
        });
        return;
      }
      setState(() => _scrambleValue = _randomFreqString());
    });
  }

  String _randomFreqString() {
    final cfg = _cfg;
    final range = cfg.maxFreq - cfg.minFreq;
    var v = cfg.minFreq + _scrambleRng.nextDouble() * range;
    // Round to the band's native step so the digit count stays stable
    // during the scramble.
    if (cfg.step < 1.0) {
      final scale = (1.0 / cfg.step).roundToDouble();
      v = (v * scale).roundToDouble() / scale;
      return v.toStringAsFixed(1);
    } else {
      v = (v / cfg.step).roundToDouble() * cfg.step;
      return v.toInt().toString();
    }
  }

  void _onPowerTap(web.Event event) {
    event.preventDefault();
    // Only unlock AudioContext on the first power-on. Subsequent
    // toggles just flip state - the context stays alive across off/on
    // cycles so re-creating it would leak graphs (and unlockAudioContext
    // itself guards against that, but skipping the call is clearer).
    //
    // AudioContext creation MUST be synchronous inside this gesture
    // handler - deferring it until onPowerToggle propagates through
    // Jaspr loses user-gesture attribution on mobile and resume() never
    // transitions the context to 'running'.
    if (!component.isPowered) {
      unlockAudioContext();
    }
    component.onPowerToggle?.call();
  }

  void _onMemTap(web.Event event) {
    if (!component.canSaveCurrent) return;
    event.preventDefault();
    component.onSaveStation?.call();
    _memFlashTimer?.cancel();
    setState(() => _memFlash = true);
    _memFlashTimer = Timer(_memFlashDuration, () {
      if (mounted) setState(() => _memFlash = false);
    });
  }

  /// Runs the dial's band-change re-rack.
  ///
  /// Skipped under reduced motion: the whole point is a violent sideways
  /// lurch, and there is no gentler version of it that still means
  /// anything. The LCD still reports the new band, so nothing is lost
  /// but the theatre.
  void _sweepBand() {
    if (prefersReducedMotion) return;
    _bandSweepTimer?.cancel();
    setState(() => _bandSweepNonce++);
    _bandSweepTimer = Timer(_bandSweepDuration, () {
      if (mounted) setState(() => _bandSweepNonce = 0);
    });
  }

  /// Flashes `SIGNAL LOCKED` across the LCD for [_lockFlashDuration].
  ///
  /// The moment a station is captured had no acknowledgement of its own:
  /// the panel faded in and the ST badge lit, both gradual. Tuning is
  /// the best idea in this piece, so catching something should land as
  /// a distinct beat rather than as the absence of noise.
  void _flashLocked() {
    if (prefersReducedMotion) return;
    _lockFlashTimer?.cancel();
    setState(() => _lockFlash = true);
    _lockFlashTimer = Timer(_lockFlashDuration, () {
      if (mounted) setState(() => _lockFlash = false);
    });
  }

  @override
  void didUpdateComponent(RadioDial oldComponent) {
    super.didUpdateComponent(oldComponent);
    final wasPowered = oldComponent.isPowered;
    final isPowered = component.isPowered;

    // Fire only on the null -> station edge, so sweeping *within* a
    // locked station's range doesn't retrigger it.
    final was = oldComponent.activeStation;
    final now = component.activeStation;
    if (isPowered && now != null && was?.callSign != now.callSign) {
      _flashLocked();
    } else if (now == null && _lockFlash) {
      _lockFlashTimer?.cancel();
      setState(() => _lockFlash = false);
    }
    if (isPowered && !wasPowered) {
      // Defer so the CRT turn-on animation gets to start before the
      // scramble + glitch kick in.
      _scramblePowerOnTimer?.cancel();
      _scramblePowerOnTimer = Timer(_scramblePowerOnDelay, () {
        if (!mounted || !component.isPowered) return;
        _triggerLcdGlitch();
        _startScramble();
      });
    } else if (!isPowered && wasPowered) {
      // Cancel any in-flight scramble - it shouldn't outlive the
      // powered state it started in.
      _scramblePowerOnTimer?.cancel();
      _scrambleTimer?.cancel();
      if (_isScrambling || _scrambleValue != null) {
        setState(() {
          _isScrambling = false;
          _scrambleValue = null;
        });
      }
    } else if (isPowered && oldComponent.band != component.band) {
      // Band flip: scramble the LCD with the new band's values and
      // re-rack the dial to sell the hand-off.
      _triggerLcdGlitch();
      _startScramble();
      _sweepBand();
    }
  }

  @override
  void dispose() {
    _lcdTapTimer?.cancel();
    _scrambleTimer?.cancel();
    _scramblePowerOnTimer?.cancel();
    _memFlashTimer?.cancel();
    _lockFlashTimer?.cancel();
    _bandSweepTimer?.cancel();
    super.dispose();
  }

  void _onPanelWheel(web.Event event) {
    if (!component.isPowered) return;
    final we = event as web.WheelEvent;
    we.preventDefault();
    final step = _cfg.step;
    final delta = we.deltaY > 0 ? step * 2 : -step * 2;
    _setFrequency(_freq + delta);
  }

  // --- build ---

  @override
  Component build(BuildContext context) {
    final tuned = component.activeStation != null;
    final powered = component.isPowered;
    final band = component.band;
    final isFm = band == Band.fm;

    return div(
      classes: 'radio-panel${powered ? '' : ' panel-off'}',
      events: {'wheel': _onPanelWheel},
      [
        // Top bevel highlight (purely cosmetic).
        div(classes: 'panel-bevel-top', []),

        // Header row: brand on the left, power rocker + band rocker +
        // indicators on the right. Both rockers sit inside
        // `.indicator-row` so they share the same baseline as the
        // FM/AM/ST/MONO pills.
        div(classes: 'panel-header', [
          // Hardware model-plate. Two-line etched wordmark: the top
          // line is the model designation (brighter, tracked), the
          // bottom is the spec caption (dim microtype). Reads as a
          // real piece of 90s receiver signage rather than a
          // placeholder "RADIO" label.
          div(classes: 'brand-plate', [
            span(classes: 'brand', [Component.text('RCHF · 2600')]),
            span(classes: 'brand-sub', [Component.text('AM/FM STEREO RECEIVER')]),
          ]),
          div(classes: 'indicator-row', [
            // Etched instruction sitting immediately left of the rocker.
            // Kept in normal flow rather than absolutely positioned: the
            // header is `space-between`, so this just widens the
            // right-hand group leftward into empty space. It cannot
            // overlap anything or shift anything vertically, and when it
            // retires the row simply closes up - during the CRT turn-on
            // animation, so the reflow is never seen.
            //
            // aria-hidden because the rocker already carries
            // role="switch" with its own label. This is a visual
            // affordance, not new information.
            if (component.showPowerHint)
              span(
                classes: 'power-hint',
                attributes: {'aria-hidden': 'true'},
                [
                  Component.text(
                    component.lang == Lang.es ? 'ENCIENDE' : 'PRESS ON',
                  ),
                  span(classes: 'power-hint-arrow', [Component.text('▸')]),
                ],
              ),
            div(
              classes:
                  'power-rocker${powered ? ' power-on' : ''}'
                  '${component.showPowerAttract ? ' power-attract' : ''}',
              events: {
                'click': _onPowerTap,
                'touchend': _onPowerTap,
                // A keydown is a user gesture too, so unlockAudioContext
                // still runs inside a real gesture callstack and mobile
                // autoplay policy is satisfied on this path as well.
                'keydown': onActivateKey(_onPowerTap),
              },
              attributes: {
                'role': 'switch',
                'aria-label': 'Power',
                'aria-checked': powered ? 'true' : 'false',
                // The way into the entire experience. It was reachable
                // by pointer only, so a keyboard-only visitor could not
                // switch the radio on at all.
                'tabindex': '0',
              },
              [
                // The ON/OFF legend is painted on via CSS `content`
                // rather than being DOM text.
                //
                // It is moulded switch marking, not a label: the control
                // is named "Power" and its state rides on aria-checked.
                // As text nodes the two words counted as the element's
                // visible text and collided with that name under WCAG
                // 2.5.3 - the switch read as being called "ON OFF".
                // `aria-hidden` alone does not fix it, because hiding
                // something from assistive tech does not stop it being
                // visible text. Moving it into the stylesheet does, and
                // it is where the rest of the faceplate silkscreen
                // already lives.
                span(
                  classes: 'rocker-half rocker-on',
                  attributes: const {'aria-hidden': 'true'},
                  [],
                ),
                span(
                  classes: 'rocker-half rocker-off',
                  attributes: const {'aria-hidden': 'true'},
                  [],
                ),
              ],
            ),
            _memButton(),
            _bandPill(Band.fm, active: powered && isFm, powered: powered),
            _bandPill(Band.am, active: powered && !isFm, powered: powered),
          ]),
        ]),

        // Collected-stations row - preset rack between the header and
        // the dial. Hidden when empty / powered off so the panel layout
        // is unaffected before the user discovers anything.
        CollectedStations(
          stations: component.collectedStations,
          activeStation: component.activeStation,
          activeBand: component.band,
          isPowered: component.isPowered,
          onRecall: component.onRecallStation ?? (_) {},
          onDelete: component.onDeleteStation,
        ),

        // Main row: volume knob + LCD + dial window + tuning knob.
        div(classes: 'panel-main', [
          // Volume knob (small, doubles as power switch - volume 0
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
                'keydown': _onVolKeyDown,
              },
              attributes: {
                'role': 'slider',
                'tabindex': powered ? '0' : '-1',
                'aria-label': 'Volume',
                'aria-valuemin': '0',
                'aria-valuemax': '100',
                'aria-valuenow': (component.volume * 100).round().toString(),
                'aria-valuetext': _spokenVolume(),
                if (!powered) 'aria-disabled': 'true',
              },
              [
                div(classes: 'vol-knob-cap', [
                  div(
                    classes: 'vol-knob-notch',
                    styles: Styles(
                      transform: Transform.rotate(Angle.deg(_volAngle)),
                    ),
                    [],
                  ),
                  div(
                    classes:
                        'knob-led'
                        '${(powered && component.volume > 0) ? ' knob-led-on' : ''}',
                    [],
                  ),
                ]),
              ],
            ),
            div(classes: 'vol-knob-label', [Component.text('VOL')]),
          ]),

          // LCD frequency readout. Clicking/tapping runs the tap-
          // glitch animation via an inline override; the nonce in the
          // animation-delay forces a restart on each consecutive tap.
          div(
            classes: 'lcd${tuned ? ' lcd-locked' : ''}',
            events: {'click': _onLcdTap},
            styles: _lcdTapNonce > 0
                ? Styles(
                    raw: {
                      'animation': 'lcd-tap-glitch 0.8s step-end ${(_lcdTapNonce * 0.0001).toStringAsFixed(4)}s',
                    },
                  )
                : null,
            [
              // Faded "ghost" segments behind the live digits, like the
              // unlit cells on a real 7-segment LED panel. The ghost
              // width matches the live value's digit count (3-digit AM
              // needs an extra segment).
              span(classes: 'lcd-ghost', [Component.text(isFm ? '188.8' : '1888')]),
              span(
                classes: 'lcd-value',
                [
                  Component.text(
                    _scrambleValue ?? (isFm ? _freq.toStringAsFixed(1) : _freq.toInt().toString()),
                  ),
                ],
              ),
              // Right-side badges: band indicator + station-lock "ST".
              div(classes: 'lcd-badges', [
                span(classes: 'lcd-fm', [Component.text(isFm ? 'FM' : 'AM')]),
                span(
                  classes: 'lcd-st${tuned ? ' is-lit' : ''}',
                  [Component.text('ST')],
                ),
              ]),
              // The lock beat. Overlays the digits for a moment rather
              // than displacing them, so the readout never jumps.
              if (_lockFlash)
                div(classes: 'lcd-lock-flash', [
                  Component.text('SIGNAL LOCKED'),
                ]),
            ],
          ),

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
              attributes: {
                // The dial is a continuous value control, so it gets
                // slider semantics rather than being an unlabelled div
                // that only responds to dragging. aria-valuetext carries
                // the spoken form ("FM 97.7 MHz"), because aria-valuenow
                // alone would be read as a bare number with no unit and
                // no band.
                'role': 'slider',
                'tabindex': powered ? '0' : '-1',
                'aria-label': 'Tuning dial',
                'aria-valuemin': _cfg.minFreq.toString(),
                'aria-valuemax': _cfg.maxFreq.toString(),
                'aria-valuenow': _freq.toString(),
                'aria-valuetext': _spokenFrequency(),
                // Points at the shortcut list rendered by `AppState`, so
                // landing on the dial explains how to drive it.
                'aria-describedby': 'dial-instructions',
                if (!powered) 'aria-disabled': 'true',
              },
              [
                div(
                  classes: 'dial-strip',
                  styles: Styles(
                    width: _stripWidth.px,
                    raw: {
                      // The tuning offset lives in `translate`, not in
                      // `transform`, so the band-change keyframe can
                      // compose with it instead of replacing it.
                      //
                      // `band-sweep` animates `transform`, and an
                      // animation owns that property outright. While it
                      // ran, the strip's own offset simply stopped
                      // existing: the dial snapped to the bottom of the
                      // band, lurched there, and snapped back to the
                      // tuned frequency when the animation ended. The
                      // lurch was the intended part; the two snaps
                      // around it were not.
                      //
                      // Individual `translate` is applied before
                      // `transform`, so the strip now stays parked on the
                      // tuned frequency and the keyframe slams and
                      // decompresses *from there* - the same movement the
                      // effect was written for, minus the jump either
                      // side of it.
                      'translate': '${_stripOffset.toStringAsFixed(1)}px',
                      // The nonce lands in the delay so a second flip
                      // restarts the keyframe rather than being ignored
                      // as an identical value.
                      if (_bandSweepNonce > 0)
                        'animation':
                            'band-sweep 0.62s cubic-bezier(0.2, 0, 0.1, 1) '
                            '${(_bandSweepNonce * 0.0001).toStringAsFixed(4)}s',
                    },
                  ),
                  _buildStripChildren(),
                ),
                if (_bandSweepNonce > 0)
                  div(
                    classes: 'band-flash',
                    attributes: {'aria-hidden': 'true'},
                    styles: Styles(
                      raw: {
                        'animation':
                            'band-flash 0.45s ease-out '
                            '${(_bandSweepNonce * 0.0001).toStringAsFixed(4)}s both',
                      },
                    ),
                    [],
                  ),
                div(classes: 'needle', []),
                div(classes: 'dial-glass', []),
                // Tuning instruction, laid over the dial slit itself -
                // on the control we want touched, not off in a corner.
                // Absolutely positioned inside the already-relative
                // `.dial-window`, and `pointer-events: none` so it can
                // never intercept the drag it is asking for.
                //
                // Both phrasings are always rendered and CSS picks one
                // on `(hover: hover)`. Doing it in CSS rather than by
                // sniffing the pointer in Dart keeps the SSR output and
                // the hydrated output identical.
                if (component.showTuneHint)
                  div(
                    classes: 'tune-hint',
                    attributes: {'aria-hidden': 'true'},
                    [
                      span(classes: 'tune-hint-fine', [
                        Component.text(
                          component.lang == Lang.es ? 'ARRASTRA O USA ← →' : 'DRAG OR USE ← →',
                        ),
                      ]),
                      span(classes: 'tune-hint-coarse', [
                        Component.text(
                          component.lang == Lang.es ? 'DESLIZA PARA SINTONIZAR' : 'SWIPE TO TUNE',
                        ),
                      ]),
                    ],
                  ),
              ],
            ),
          ]),

          // Tuning knob (ribbed metallic). Drag up/down to tune. The
          // embedded LED mirrors the LCD's "ST" badge - it lights
          // green whenever a station is actively locked.
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
                div(
                  classes: 'knob-led${tuned ? ' knob-led-on' : ''}',
                  [],
                ),
              ]),
            ],
          ),
        ]),
      ],
    );
  }

  /// FM/AM indicator pill that doubles as the band selector. Same
  /// `.ind` chip styling as the other pills; the inactive band's
  /// pill is wired to switch bands when tapped, the active band stays
  /// inert (already on it). Replaces the old FM/AM rocker switch by
  /// upgrading the readout chips into the band selector itself.
  Component _bandPill(
    Band band, {
    required bool active,
    required bool powered,
  }) {
    final clickable = powered && !active;
    final classes = StringBuffer('ind ind-band');
    if (active) classes.write(' ind-on');
    if (clickable) classes.write(' ind-band-clickable');
    return span(
      classes: classes.toString(),
      events: clickable
          ? {
              'click': (web.Event e) {
                e.preventDefault();
                component.onBandSelect?.call(band);
              },
              'keydown': (web.Event e) {
                final ke = e as web.KeyboardEvent;
                if (ke.key == 'Enter' || ke.key == ' ') {
                  ke.preventDefault();
                  component.onBandSelect?.call(band);
                }
              },
            }
          : const {},
      attributes: {
        'role': 'button',
        'aria-label': 'Switch to ${band.name.toUpperCase()} band',
        'aria-pressed': active ? 'true' : 'false',
        if (clickable) 'tabindex': '0',
      },
      [Component.text(band.name.toUpperCase())],
    );
  }

  /// MEM button - saves the currently-locked station to the rack.
  /// Disabled (dim, no pointer) when the dial isn't on a station OR
  /// when the active station is already saved. Briefly flashes amber
  /// after a successful press.
  Component _memButton() {
    final armed = component.canSaveCurrent;
    final classes = StringBuffer('ind ind-mem');
    if (armed) classes.write(' ind-mem-armed');
    if (_memFlash) classes.write(' ind-mem-flash');
    return span(
      classes: classes.toString(),
      events: armed ? {'click': _onMemTap, 'keydown': onActivateKey(_onMemTap)} : const {},
      attributes: {
        'role': 'button',
        // Leads with the visible "MEM" so voice control can reach it by
        // the word on the button (WCAG 2.5.3).
        'aria-label': armed ? 'MEM - save current station' : 'MEM - no station available to save',
        'aria-disabled': armed ? 'false' : 'true',
        if (armed) 'tabindex': '0',
      },
      [Component.text('MEM')],
    );
  }

  // --- strip tick / marker generation ---

  List<Component> _buildStripChildren() {
    final cfg = _cfg;
    final children = <Component>[];

    // Unified step-based iteration. Majors land at whole frequency
    // boundaries (FM: integer MHz, AM: multiples of 100 kHz), not at
    // fixed strides from minFreq - minFreq itself rarely falls on one.
    // FM thins minors to every 2nd step; AM draws every step.
    final totalSteps = ((cfg.maxFreq - cfg.minFreq) / cfg.step).round();
    final majorStep = cfg.step * 10;
    final minorStride = component.band == Band.fm ? 2 : 1;

    for (var i = 0; i <= totalSteps; i++) {
      final freq = cfg.minFreq + i * cfg.step;
      final majorMultiple = freq / majorStep;
      final isMajor = (majorMultiple - majorMultiple.round()).abs() < 0.001;
      if (!isMajor && i % minorStride != 0) continue;
      final x = i * cfg.pxPerStep;

      if (isMajor) {
        // FM labels show integer MHz (88, 89, …). AM labels are the
        // frequency divided by 10 (600 kHz → "60", 1400 → "140"), the
        // standard compact form on physical car-stereo AM dials.
        final rawLabel = component.band == Band.fm ? freq.round().toString() : (freq / 10).round().toString();
        children.add(
          div(
            classes: 'tick tick-major',
            styles: Styles(
              position: Position.absolute(left: x.px, top: Unit.zero),
            ),
            [
              span(classes: 'tick-label', [Component.text(rawLabel)]),
            ],
          ),
        );
      } else {
        // Minor ticks vary slightly in strength. A band of a hundred
        // identical hairlines is the most obviously machine-made surface
        // on the panel; screen-printed engraving never lands with the
        // same weight twice, and the ink wears unevenly on top of that.
        //
        // Deterministic on the tick index rather than random: the server
        // and the hydrated client have to agree, and a dial whose ticks
        // shimmered on every re-render would be a bug, not a texture.
        //
        // The spread is deliberately narrow (0.82 to 1.0). These ticks
        // are already only #3a3a48 on a near-black slit and get dimmed
        // again when the radio is off, so a wide range would cross from
        // "unevenly printed" into "missing".
        final wear = 0.82 + ((i * 2654435761) & 0x7fff) % 19 / 100.0;
        children.add(
          div(
            classes: 'tick tick-minor',
            styles: Styles(
              position: Position.absolute(left: x.px, top: Unit.zero),
              opacity: wear,
            ),
            [],
          ),
        );
      }
    }

    // Still no map of the band: unfound stations are never marked, so
    // the user has to sweep, watch the noise clear and listen, like on
    // a real radio.
    //
    // The one exception is the station currently locked. Marking where
    // you already are gives the lock somewhere to land on the dial and
    // reveals nothing - you are looking straight at it.
    final active = component.activeStation;
    if (active != null && active.band == component.band) {
      final x = ((active.frequency - cfg.minFreq) / cfg.step) * cfg.pxPerStep;
      children.add(
        div(
          classes: 'tick-lock',
          styles: Styles(
            position: Position.absolute(left: x.px, top: Unit.zero),
            raw: {'--sc': active.color},
          ),
          [],
        ),
      );
    }

    return children;
  }

  // --- styles ---

  @css
  static List<StyleRule> get styles => [
    // ── faceplate ──
    // `min-height` (not `height`) so the optional preset rack pushes
    // the panel taller only when the user has discovered a station.
    // Empty / powered-off → row collapses to zero, panel matches the
    // pre-feature 210 px exactly.
    css('.radio-panel').styles(
      position: Position.fixed(
        bottom: Unit.zero,
        left: Unit.zero,
        right: Unit.zero,
      ),
      minHeight: 210.px,
      zIndex: ZIndex(50),
      display: Display.flex,
      flexDirection: FlexDirection.column,
      alignItems: AlignItems.stretch,
      padding: Padding.symmetric(horizontal: 16.px, vertical: 12.px),
      raw: {
        // Brushed dark plastic, now lit rather than evenly shaded. Layers,
        // top to bottom:
        //   1. A single long scuff running across the plastic at a shallow
        //      angle. One scratch, not a pattern - a repeating scratch is
        //      a texture, and textures read as manufactured. This is the
        //      cheapest possible "this object has been handled".
        //   2. Light falloff from the upper left, anchored off the panel
        //      so the gradient never resolves into a visible blob. This
        //      is what makes the faceplate read as a surface catching a
        //      lamp instead of a flat swatch.
        //   3-4. The existing brushed hairlines and moulding lines.
        //   5. The base plastic gradient, top edge lifted a little so the
        //      housing sits on a clearly different plane from the near
        //      black screen above it.
        'background':
            'linear-gradient(114deg, transparent 0%, transparent 28.4%, rgba(255,255,255,0.05) 28.7%, rgba(255,255,255,0.05) 28.9%, transparent 29.2%, transparent 100%),'
            'radial-gradient(120% 180% at 12% -40%, rgba(255,255,255,0.055) 0%, rgba(255,255,255,0.018) 38%, transparent 72%),'
            'repeating-linear-gradient(90deg, rgba(255,255,255,0.018) 0px, rgba(255,255,255,0.018) 1px, transparent 1px, transparent 3px),'
            'repeating-linear-gradient(0deg, rgba(0,0,0,0.18) 0px, rgba(0,0,0,0.18) 1px, transparent 1px, transparent 2px),'
            'linear-gradient(to bottom, #22222b 0%, #14141a 45%, #0a0a10 100%)',
        'border-top': '1px solid #2c2c38',
        // Top-left inner edge lit, bottom-right inner edge shaded, and the
        // large upward shadow left centred: it is the occlusion between
        // the housing and the screen behind it, not a cast shadow, so it
        // has no direction to answer to.
        'box-shadow':
            'inset 1px 1px 0 rgba(255,255,255,0.06), '
            'inset -1px -2px 6px rgba(0,0,0,0.6), '
            '0 -8px 28px rgba(0,0,0,0.6)',
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
        // The lit edge of the housing. Its brightest point sits left of
        // centre rather than dead centre, because the lamp is up and to
        // the left; a symmetric highlight here was quietly contradicting
        // every bevel below it.
        'background':
            'linear-gradient(to right, transparent 0%, rgba(255,255,255,0.24) 26%, '
            'rgba(255,255,255,0.13) 58%, rgba(255,255,255,0.05) 82%, transparent 100%)',
        'pointer-events': 'none',
      },
    ),

    // ── header ──
    css('.panel-header').styles(
      display: Display.flex,
      flexDirection: FlexDirection.row,
      alignItems: AlignItems.center,
      justifyContent: JustifyContent.spaceBetween,
      gap: Gap(column: 12.px),
      raw: {'margin-bottom': '12px'},
    ),
    // ── power rocker ──
    // Two-half molded-plastic rocker: the lit side reads as "pressed
    // down" (inset shadow, amber glyph), the other side as "raised"
    // (subtle highlight, grey). A faint divider separates the halves.
    // Deliberately not an iOS pill - this is the chunky rocker you'd
    // find on a 90s amp or power strip. Sole physical control left on
    // the faceplate now that band switching moved into the FM/AM
    // indicator pills.
    css('.power-rocker', [
      css('&').styles(
        position: Position.relative(),
        width: 52.px,
        height: 22.px,
        radius: BorderRadius.all(Radius.circular(4.px)),
        cursor: Cursor.pointer,
        display: Display.flex,
        flexDirection: FlexDirection.row,
        alignItems: AlignItems.stretch,
        // Deliberately NOT `overflow: hidden`. It used to clip the two
        // halves to the rounded corners, but it would equally clip the
        // ::after that enlarges the touch target, silently undoing it.
        // The halves round their own outer corners instead (below).
        raw: {
          'box-sizing': 'border-box',
          'background': '#1a1a1a',
          'border': '1px solid rgba(255,255,255,0.12)',
          // Recessed housing: the rim nearest the lamp (top-left) casts
          // into the well, and the far wall (bottom-right) catches the
          // light that gets past it.
          'box-shadow':
              'inset 2px 2px 3px rgba(0,0,0,0.75), '
              'inset -1px -1px 0 rgba(255,255,255,0.05), '
              '1px 1px 0 rgba(255,255,255,0.04)',
          'user-select': 'none',
          '-webkit-user-select': 'none',
          '-webkit-tap-highlight-color': 'transparent',
          'flex-shrink': '0',
          'touch-action': 'manipulation',
        },
      ),
    ]),
    // Power rocker stays interactive even when the panel is dimmed
    // (powered off) - it's the only way back on.
    css('.power-rocker').styles(raw: {'pointer-events': 'auto'}),
    // Slow amber swell while the radio has never been switched on.
    css('.power-rocker.power-attract').styles(
      raw: {'animation': 'power-attract 2.4s ease-in-out infinite'},
    ),
    // The rocker physically travels. A switch that does not move under
    // the finger is the one control most likely to read as fake, and
    // this is the first thing anyone touches.
    // Plastic timing: quick, with the settle in the curve rather than in
    // the duration. A rocker that eases over a quarter second reads as a
    // rubber membrane.
    css('.power-rocker:active').styles(
      raw: {
        'transform': 'translateY(1px)',
        'box-shadow': 'inset 3px 3px 5px rgba(0,0,0,0.88)',
        'transition':
            'transform var(--dur-plastic) var(--ease-plastic), box-shadow var(--dur-plastic) var(--ease-plastic)',
      },
    ),
    // The rocker draws at 52x22 because that is what the hardware wants
    // to look like, but 22px tall is well under a comfortable touch
    // target. This pseudo-element grows the *hit area* to 44px tall
    // without touching a single visible pixel, so the control still
    // reads as a small moulded switch while behaving like a big one.
    //
    // Vertical only: 52px is already a wide enough target, and the MEM
    // button sits just 4px to the right, so widening here would quietly
    // steal presses from its left edge.
    css('.power-rocker::after').styles(
      position: Position.absolute(
        top: Unit.expression('calc(50% - 22px)'),
        left: Unit.zero,
      ),
      width: 100.percent,
      height: 44.px,
      raw: {'content': '""'},
    ),
    // ── onboarding: power ──
    // Faceplate silkscreen, matched to `.brand-sub` so it reads as
    // printed on the plastic rather than drawn by a web page.
    css('.power-hint', [
      css('&').styles(
        display: Display.flex,
        flexDirection: FlexDirection.row,
        alignItems: AlignItems.center,
        gap: Gap(column: 4.px),
        fontFamily: const FontFamily.list([
          FontFamily('IBM Plex Mono'),
          FontFamilies.monospace,
        ]),
        // 11px, not the 6-8px of the surrounding silkscreen. This is the
        // single most important instruction on the page for a first-time
        // visitor, so it gets the same floor as any other informative
        // text - shrinking it to match the decoration would undercut the
        // one job it has. Tracking is pulled in to keep the width down.
        fontSize: Unit.pixels(11),
        fontWeight: FontWeight.w600,
        letterSpacing: 0.16.em,
        color: const Color('#c99a4e'),
        pointerEvents: PointerEvents.none,
        raw: {
          'text-transform': 'uppercase',
          'white-space': 'nowrap',
          'flex-shrink': '0',
          'text-shadow': '0 0 5px rgba(232,160,53,0.35), 0 -1px 0 rgba(0,0,0,0.7)',
          'animation': 'hint-fade-in 0.5s ease-out both',
        },
      ),
      css('& .power-hint-arrow').styles(
        raw: {
          'font-size': '10px',
          'line-height': '1',
          'opacity': '0.8',
          'letter-spacing': '0',
        },
      ),
    ]),
    css('.rocker-half', [
      css('&').styles(
        display: Display.flex,
        alignItems: AlignItems.center,
        justifyContent: JustifyContent.center,
        fontFamily: const FontFamily.list([FontFamilies.monospace]),
        fontSize: Unit.pixels(7),
        fontWeight: FontWeight.bold,
        color: const Color('#444'),
        raw: {
          'flex': '1',
          'letter-spacing': '0.5px',
          'text-transform': 'uppercase',
          // Raised plastic: lit on the top-left inner edge, shaded on the
          // bottom-right.
          'background': 'linear-gradient(160deg, #2e2e2e 0%, #262626 45%, #1c1c1c 100%)',
          'box-shadow':
              'inset 1px 1px 0 rgba(255,255,255,0.09), '
              'inset -1px -1px 0 rgba(0,0,0,0.35)',
          'transition':
              'background var(--dur-plastic) var(--ease-plastic), '
              'box-shadow var(--dur-plastic) var(--ease-plastic), '
              'color var(--dur-glow-off) var(--ease-phosphor), '
              'text-shadow var(--dur-glow-off) var(--ease-phosphor)',
        },
      ),
    ]),
    // Switch legend, painted rather than written. See the note at the
    // rocker's markup for why this is not DOM text.
    css('.rocker-half.rocker-on::after').styles(raw: {'content': "'ON'"}),
    css('.rocker-half.rocker-off::after').styles(raw: {'content': "'OFF'"}),

    // Outer corners, previously handled by the parent's `overflow`.
    // 3px against the parent's 4px so the halves sit just inside the
    // moulding rather than fighting its edge.
    css('.rocker-half.rocker-on').styles(
      raw: {'border-radius': '3px 0 0 3px'},
    ),
    css('.rocker-half.rocker-off').styles(
      raw: {'border-radius': '0 3px 3px 0'},
    ),
    // Faint moulded seam between the two halves. The seam's own left wall
    // is in shadow and its right wall catches light, same as every other
    // edge on the panel.
    css('.rocker-half + .rocker-half').styles(
      raw: {
        'border-left': '1px solid rgba(0,0,0,0.55)',
        'box-shadow':
            'inset 1px 1px 0 rgba(255,255,255,0.07), '
            'inset -1px -1px 0 rgba(0,0,0,0.35)',
      },
    ),
    // The OFF legend is worn a shade further than the ON legend. Nobody
    // will consciously notice; what they notice is that the two words
    // were not printed by the same vector operation.
    css('.rocker-half.rocker-off').styles(color: const Color('#3d3d3d')),
    // Visually separate the rockers from each other and from the
    // FM/AM/ST/MONO pills in the indicator row.
    css('.indicator-row .power-rocker').styles(raw: {'margin-right': '4px'}),
    // Pressed (lit) half styling - applied to the active half of the
    // power rocker.
    css(
      '.power-rocker:not(.power-on) .rocker-off, '
      '.power-rocker.power-on .rocker-on',
    ).styles(
      raw: {
        'background': 'linear-gradient(160deg, #0d0d0d 0%, #050505 100%)',
        // Pressed in: the top-left rim now shades the recess.
        'box-shadow':
            'inset 2px 2px 4px rgba(0,0,0,0.9), '
            'inset -1px -1px 1px rgba(255,255,255,0.035)',
        'color': _lcdAmber,
        'text-shadow': '0 0 3px rgba(232,160,53,0.75), 0 0 6px rgba(232,160,53,0.35)',
        // Attack, not decay: the legend lights the instant the switch
        // travels. The slow side lives on the base rule above, so
        // switching off leaves the glyph cooling for nearly half a
        // second, the way a filament does.
        'transition':
            'background var(--dur-plastic) var(--ease-plastic), '
            'box-shadow var(--dur-plastic) var(--ease-plastic), '
            'color var(--dur-glow-on) var(--ease-phosphor), '
            'text-shadow var(--dur-glow-on) var(--ease-phosphor)',
      },
    ),
    // ── powered-off faceplate ──
    // The header (brand + power button + indicators) keeps full
    // brightness so the power button stays clearly tappable. The main
    // row (LCD, dial, knobs) gets dimmed + desaturated + non-
    // interactive until the user taps the power button.
    css('.radio-panel', [
      css('&').styles(
        raw: {
          'transition': 'filter 0.6s ease',
        },
      ),
    ]),
    // Powered-off dimming.
    //
    // This used to be `brightness(0.3)`, which crushed the dial's tick
    // marks - already only #3a3a48 on a near-black window - into the
    // background entirely. The frequency band effectively vanished while
    // the radio was off, which reads as a broken or unfinished panel
    // rather than as an unlit one, and it is the first thing a visitor
    // sees. Unlit hardware still catches light; it does not disappear.
    //
    // 0.55 keeps the off state clearly darker than the on state while
    // leaving the band, the numbers and the knobs legible as objects.
    css('.panel-off .panel-main').styles(
      raw: {
        'filter': 'brightness(0.55) saturate(0.55)',
        'transition': 'filter 0.6s ease, opacity 0.6s ease',
        'pointer-events': 'none',
        'opacity': '0.9',
      },
    ),
    css('.panel-off .indicator-row').styles(
      raw: {
        'opacity': '0.35',
        'transition': 'opacity 0.6s ease',
        'pointer-events': 'none',
      },
    ),
    // ── LCD off-state ──
    // When powered off the backlit LCD should read as fully dead:
    // no amber gradient, no glow, no glitch animation, and all the
    // digits/badges hidden. The dark brown-grey tone evokes an
    // unpowered liquid-crystal panel under ambient light.
    css('.panel-off .lcd').styles(
      raw: {
        'background': '#1a1510',
        'box-shadow':
            'inset 2px 2px 4px rgba(0,0,0,0.6), '
            'inset -1px -1px 2px rgba(255,255,255,0.02), '
            'inset 0 0 0 1px rgba(0,0,0,0.6)',
        'animation': 'none',
        'transition':
            'background var(--dur-lamp) ease-in-out, '
            'box-shadow var(--dur-lamp) ease-in-out',
      },
    ),
    css('.panel-off .lcd::after').styles(
      raw: {
        'opacity': '0',
        'transition': 'opacity 0.4s ease',
      },
    ),
    css(
      '.panel-off .lcd-value, .panel-off .lcd-ghost, '
      '.panel-off .lcd-fm, .panel-off .lcd-st',
    ).styles(
      raw: {
        'opacity': '0',
        'transition': 'opacity 0.4s ease',
      },
    ),
    // Base transitions so on→off AND off→on both animate. Must be
    // written AFTER the base element rules to merge transitions with
    // their original declarations (CSS `transition` is not additive -
    // the last declaration wins wholesale, so we repeat existing
    // animated properties here where needed).
    css('.lcd-value').styles(
      raw: {
        'transition': 'color 0.3s ease, text-shadow 0.3s ease, opacity 0.4s ease',
      },
    ),
    css('.lcd-ghost').styles(
      raw: {
        'transition': 'opacity 0.4s ease',
      },
    ),
    css('.lcd-fm').styles(
      raw: {
        'transition': 'opacity 0.4s ease',
      },
    ),
    css('.panel-main').styles(
      raw: {
        'transition': 'filter 0.6s ease, opacity 0.6s ease',
      },
    ),
    css('.indicator-row').styles(
      raw: {
        'transition': 'opacity 0.6s ease',
      },
    ),
    // ── hardware model-plate ──
    // Two stacked etched labels. The plate uses a tiny outer stroke
    // (inset gradient border) so it reads as a separate metal tag
    // riveted to the faceplate, not just loose text. The top line
    // is the brighter model designation; the bottom line is the
    // spec microtype - half the size, half the brightness.
    css('.brand-plate').styles(
      display: Display.flex,
      flexDirection: FlexDirection.column,
      alignItems: AlignItems.start,
      raw: {
        'gap': '1px',
        'padding': '3px 8px 2px',
        'border-radius': '2px',
        'background': 'linear-gradient(160deg, #0d0d15 0%, #07070c 100%)',
        'border': '1px solid rgba(255,255,255,0.05)',
        // A riveted tag standing off the faceplate: lit top-left edge,
        // shaded bottom-right edge, and a short crisp shadow cast down
        // and to the right onto the plastic.
        'box-shadow':
            'inset 1px 1px 0 rgba(255,255,255,0.06), '
            'inset -1px -1px 0 rgba(0,0,0,0.6), '
            '1px 2px 3px rgba(0,0,0,0.45)',
        // Fitted by hand, forty years ago, by someone having an average
        // day. A quarter of a degree is far too little to read as a
        // mistake and just enough that the plate stops looking like it
        // was placed by a layout engine.
        'transform': 'rotate(-0.25deg)',
      },
    ),
    css('.brand').styles(
      fontFamily: const FontFamily.list([
        FontFamily('Chakra Petch'),
        FontFamilies.monospace,
      ]),
      fontSize: Unit.pixels(10),
      fontWeight: FontWeight.w700,
      letterSpacing: 0.28.em,
      color: const Color('#9a9aa8'),
      raw: {
        // Engraved, lit from the upper left: the wall the lamp cannot
        // reach (up and left of each stroke) goes dark, and the opposite
        // wall catches the light. Previously this was a purely vertical
        // pair, which reads as engraved by a lamp directly overhead -
        // a different lamp from the one lighting everything else.
        'text-shadow': '-1px -1px 0 rgba(0,0,0,0.75), 1px 1px 0 rgba(255,255,255,0.12)',
      },
    ),
    css('.brand-sub').styles(
      fontFamily: const FontFamily.list([
        FontFamily('IBM Plex Mono'),
        FontFamilies.monospace,
      ]),
      fontSize: Unit.pixels(6),
      fontWeight: FontWeight.w500,
      letterSpacing: 0.45.em,
      color: const Color('#4a4a55'),
      raw: {
        'text-transform': 'uppercase',
        'text-shadow': '-1px -1px 0 rgba(0,0,0,0.5), 1px 1px 0 rgba(255,255,255,0.04)',
      },
    ),
    css('.indicator-row').styles(
      display: Display.flex,
      flexDirection: FlexDirection.row,
      gap: Gap(column: 8.px),
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
          'background': 'linear-gradient(160deg, #0a0a10, #050508)',
          'border': '1px solid #1c1c26',
          // Small recessed window in the faceplate.
          'box-shadow':
              'inset 1px 1px 1px rgba(0,0,0,0.6), '
              'inset -1px -1px 0 rgba(255,255,255,0.025)',
        },
      ),
      css('&.ind-on').styles(
        color: const Color(_lcdAmber),
        raw: {
          'text-shadow': '0 0 4px rgba(255,177,58,0.85), 0 0 8px rgba(255,177,58,0.4)',
          'background': 'linear-gradient(160deg, #100904, #050202)',
          'border': '1px solid #2a1a08',
        },
      ),
    ]),
    // ── band-selector pill (FM/AM) ──
    // Same chip as `.ind`, but the inactive band's pill carries
    // `.ind-band-clickable` and acts as a button. Pointer cursor +
    // soft amber-tinted hover preview signal it's interactive before
    // the user clicks.
    css('.ind-band', [
      // Two materials in one control: the chip itself is plastic (fast,
      // settled) while the legend behind it is a lamp (instant on, slow
      // to die). Splitting the transition per property is what stops a
      // band change from feeling like a colour swap.
      css('&').styles(
        raw: {
          'transition':
              'background var(--dur-plastic) var(--ease-plastic), '
              'border-color var(--dur-plastic) var(--ease-plastic), '
              'color var(--dur-glow-off) var(--ease-phosphor), '
              'text-shadow var(--dur-glow-off) var(--ease-phosphor)',
        },
      ),
      css('&.ind-on').styles(
        raw: {
          'transition':
              'background var(--dur-plastic) var(--ease-plastic), '
              'border-color var(--dur-plastic) var(--ease-plastic), '
              'color var(--dur-glow-on) var(--ease-phosphor), '
              'text-shadow var(--dur-glow-on) var(--ease-phosphor)',
        },
      ),
      css('&.ind-band-clickable').styles(raw: {'cursor': 'pointer'}),
      css('&.ind-band-clickable:hover').styles(
        color: const Color('#a87a30'),
        raw: {
          'background': 'linear-gradient(160deg, #0d0a06, #060403)',
          'border': '1px solid #241a0d',
          'text-shadow': '0 0 3px rgba(232,160,53,0.5), 0 1px 0 rgba(0,0,0,0.55)',
        },
      ),
      // Focus ring deliberately not defined here. It used to be a 1px
      // outline local to this one control, which outranked the shared
      // rule in `main.server.dart` on specificity and left the band
      // pills with a thinner ring than every other control. Focus is now
      // owned in exactly one place.
    ]),
    // ── MEM button ──
    // Lives in the indicator row next to the FM/AM/ST/MONO pills,
    // but is interactive: armed (lit + clickable) only when the dial
    // is locked on a station that hasn't been saved yet. The base
    // `.ind` style already gives the disabled-dim look - these rules
    // layer the armed/hover/flash states on top.
    css('.ind-mem', [
      css('&').styles(
        raw: {
          'cursor': 'default',
          'transition':
              'background var(--dur-plastic) var(--ease-plastic), '
              'border-color var(--dur-plastic) var(--ease-plastic), '
              'box-shadow var(--dur-plastic) var(--ease-plastic), '
              'color var(--dur-glow-off) var(--ease-phosphor), '
              'text-shadow var(--dur-glow-off) var(--ease-phosphor)',
        },
      ),
      css('&.ind-mem-armed').styles(
        color: const Color(_lcdAmber),
        raw: {
          'cursor': 'pointer',
          'background': 'linear-gradient(160deg, #100904, #050202)',
          'border': '1px solid #2a1a08',
          'text-shadow': '0 0 4px rgba(255,177,58,0.85), 0 0 8px rgba(255,177,58,0.4)',
          'transition':
              'background var(--dur-plastic) var(--ease-plastic), '
              'border-color var(--dur-plastic) var(--ease-plastic), '
              'box-shadow var(--dur-plastic) var(--ease-plastic), '
              'color var(--dur-glow-on) var(--ease-phosphor), '
              'text-shadow var(--dur-glow-on) var(--ease-phosphor)',
        },
      ),
      css('&.ind-mem-armed:hover').styles(
        raw: {
          'background': 'linear-gradient(160deg, #1a1006, #0a0504)',
          'border-color': '#3a2410',
          'box-shadow':
              'inset 1px 1px 1px rgba(0,0,0,0.6), '
              '0 0 6px rgba(232,160,53,0.35)',
        },
      ),
      css('&.ind-mem-armed:active').styles(
        raw: {
          'transform': 'translateY(1px)',
          'box-shadow': 'inset 2px 2px 3px rgba(0,0,0,0.72)',
        },
      ),
      css('&.ind-mem-flash').styles(
        raw: {
          'animation': 'mem-flash 0.55s ease-out',
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
        'row-gap': '8px',
        'align-items': 'center',
        'align-content': 'center',
        'justify-items': 'stretch',
        'flex': '1',
      },
    ),
    // Fixed grid placements - the same media-query breakpoints just
    // change the grid *template*, never the per-item `grid-area`.
    css('.lcd').styles(raw: {'grid-area': 'lcd'}),
    css('.dial-frame').styles(raw: {'grid-area': 'dial'}),
    css('.vol-knob-wrap').styles(raw: {'grid-area': 'vol'}),
    css('.knob').styles(raw: {'grid-area': 'tune'}),

    // ── LCD readout (aged backlit-LCD look) ──
    // The layered backgrounds, top to bottom, are:
    //   1. A tight diagonal noise pattern (micro-scratches on the
    //      plastic lens, low opacity).
    //   2. A dark radial patch in the upper-right corner - the one
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
        gap: Gap(column: 8.px),
        width: 140.px,
        height: 56.px,
        padding: Padding.symmetric(horizontal: 12.px, vertical: 4.px),
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
              // 3) Main backlight - off-centre, muted amber.
              'radial-gradient(ellipse at 42% 55%, '
              '#A67820 0%, '
              '#8B6418 55%, '
              '#6E4C10 100%)',
          'border': '1px solid #000',
          // Recessed behind its lens: the top-left rim casts into the
          // well, the bottom-right wall picks up what gets through. The
          // two glow rings are the backlight leaking outward - emitted,
          // not reflected, so they stay centred whatever the lamp does.
          'box-shadow':
              'inset 2px 2px 4px rgba(0,0,0,0.5), '
              'inset -1px -1px 2px rgba(255,255,255,0.03), '
              'inset 0 0 0 1px rgba(0,0,0,0.55), '
              '0 0 8px rgba(166,120,32,0.22), '
              '0 0 18px rgba(166,120,32,0.1), '
              '1px 1px 0 rgba(255,255,255,0.04)',
          // A backlight coming up, not a colour changing: slower than
          // any plastic on the panel, and eased at both ends.
          'transition':
              'box-shadow var(--dur-lamp) ease-in-out, '
              'background var(--dur-lamp) ease-in-out',
          // Rare worn-LCD glitches - step-end so value changes jump
          // rather than interpolate (reads like a fault, not a tween).
          // Disabled by `.lcd-locked` below.
          'animation': 'lcd-glitch 25s step-end infinite',
        },
      ),
      // "Glass" overlay - yellowed with age, diffused reflection.
      // Warm faded highlight up top, brownish mid-cast from oxidised
      // plastic, darker lower edge.
      css('&::after').styles(
        position: Position.absolute(top: Unit.zero, left: Unit.zero),
        width: 100.percent,
        height: 100.percent,
        pointerEvents: PointerEvents.none,
        raw: {
          'content': '""',
          // The lens reflection now runs on the diagonal the lamp is
          // actually on, so the sheen enters at the top-left corner and
          // the far edge of the plastic stays in shade. A perfectly
          // horizontal reflection is the single most common tell that a
          // "screen" was drawn rather than lit.
          'background':
              'linear-gradient(138deg, '
              'rgba(255,232,180,0.14) 0%, '
              'rgba(210,170,100,0.06) 26%, '
              'rgba(140,100,50,0.03) 48%, '
              'transparent 72%, '
              'rgba(40,25,10,0.20) 100%)',
        },
      ),
    ]),

    // Locked state - the backlight comes up a bit (like the amplifier
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
            'inset 2px 2px 4px rgba(0,0,0,0.5), '
            'inset -1px -1px 2px rgba(255,255,255,0.03), '
            'inset 0 0 0 1px rgba(0,0,0,0.55), '
            '0 0 12px rgba(198,140,48,0.32), '
            '0 0 22px rgba(166,120,32,0.14), '
            '1px 1px 0 rgba(255,255,255,0.04)',
        // A locked station is the "clean signal" moment - no glitches.
        'animation': 'none',
      },
    ),

    // "Off" ghost segments - slightly more visible than before
    // (polariser degradation leaking more light through unused
    // segments).
    css('.lcd-ghost').styles(
      position: Position.absolute(),
      fontFamily: const FontFamily.list([
        FontFamily('DSEG7 Classic'),
        FontFamily('Chakra Petch'),
        FontFamilies.monospace,
      ]),
      fontSize: 1.38.rem,
      fontWeight: FontWeight.w700,
      color: const Color('#000000'),
      letterSpacing: 0.04.em,
      raw: {
        'right': '42px',
        'top': '50%',
        'transform': 'translateY(-50%)',
        'opacity': '0.10',
        'pointer-events': 'none',
      },
    ),

    // Live digits - dark segments, no longer pure black. A faded
    // brown-black reads as aged LCD ink rather than crisp new print.
    //
    // Set in an actual seven-segment face rather than in one that alludes
    // to segments. This is the readout the whole faceplate is built
    // around, and it is the one element where the literal answer beats
    // the tasteful one: the ghost digits behind the live value stop being
    // a trick of opacity and become the cells that simply are not driven.
    //
    // The size looks like a big drop from Chakra Petch's 1.65rem and is
    // not: DSEG7's glyphs fill the entire em box (cap height 1.0 against
    // 0.70), so at 1.38rem the digits stand 22 px tall where they stood
    // 18.5 px before. Width is what forced the number down - 0.816 em per
    // digit is the widest of every face measured - and 1.38rem lands
    // "101.8" at 77 px, inside the 84 px the LCD leaves beside the
    // badges.
    //
    // Tracking drops to 0.04em with it. A segment face already carries
    // its own cell spacing, and the 0.08em tuned for Orbitron pushed the
    // digits apart into separate objects.
    css('.lcd-value').styles(
      position: Position.relative(),
      fontFamily: const FontFamily.list([
        FontFamily('DSEG7 Classic'),
        FontFamily('Chakra Petch'),
        FontFamilies.monospace,
      ]),
      fontSize: 1.38.rem,
      fontWeight: FontWeight.w700,
      color: const Color('#2a1f10'),
      letterSpacing: 0.04.em,
      raw: {
        'text-shadow': '0 1px 0 rgba(0,0,0,0.12)',
        'transition': 'color 0.3s ease, text-shadow 0.3s ease',
      },
    ),
    css('.lcd-locked .lcd-value').styles(
      color: const Color('#1f1608'),
      raw: {'text-shadow': '0 1px 0 rgba(0,0,0,0.18)'},
    ),

    // Right-side badges - aged ink dark, ST still flips to a tiny
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
        FontFamily('Chakra Petch'),
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
          FontFamily('Chakra Petch'),
          FontFamilies.monospace,
        ]),
        fontSize: Unit.pixels(9),
        fontWeight: FontWeight.w700,
        letterSpacing: 0.2.em,
        color: const Color('#2a1f10'),
        raw: {
          'opacity': '0.22',
          'transition':
              'color var(--dur-glow-off) var(--ease-phosphor), '
              'opacity var(--dur-glow-off) var(--ease-phosphor), '
              'text-shadow var(--dur-glow-off) var(--ease-phosphor)',
        },
      ),
      css('&.is-lit').styles(
        color: const Color('#0f3a0b'),
        raw: {
          'opacity': '0.95',
          'text-shadow':
              '0 0 2px rgba(100,200,80,0.7), '
              '0 0 6px rgba(100,200,80,0.35)',
          // Lights the instant the carrier is caught; the base rule above
          // keeps the slow fade for losing it.
          'transition':
              'color var(--dur-glow-on) var(--ease-phosphor), '
              'opacity var(--dur-glow-on) var(--ease-phosphor), '
              'text-shadow var(--dur-glow-on) var(--ease-phosphor)',
        },
      ),
    ]),

    // ── dial frame (etched slit on the faceplate) ──
    css('.dial-frame').styles(
      padding: Padding.all(4.px),
      radius: BorderRadius.all(Radius.circular(5.px)),
      raw: {
        'background': 'linear-gradient(160deg, #050508, #0d0d14)',
        'border': '1px solid #2a2a36',
        'box-shadow':
            'inset 2px 2px 2px rgba(0,0,0,0.85), '
            'inset -1px -1px 0 rgba(255,255,255,0.04), '
            '1px 1px 0 rgba(255,255,255,0.05)',
      },
    ),
    css('.dial-window').styles(
      position: Position.relative(),
      width: 100.percent,
      height: 56.px,
      overflow: Overflow.hidden,
      cursor: Cursor.grab,
      radius: BorderRadius.all(Radius.circular(3.px)),
      raw: {
        'background': 'linear-gradient(to bottom, #02020a 0%, #050512 50%, #02020a 100%)',
        'border-top': '1px solid #000',
        'border-left': '1px solid #000',
        'border-bottom': '1px solid #1a1a26',
        'border-right': '1px solid #1a1a26',
        // The slit's borders were already the right way round for a lamp
        // up and to the left (black on the near rim, grey on the far
        // wall). The inner shadow now agrees with them instead of
        // dropping straight down.
        'box-shadow':
            'inset 2px 2px 5px rgba(0,0,0,0.95), '
            'inset -1px -1px 1px rgba(255,255,255,0.035)',
      },
    ),
    // ── onboarding: tuning ──
    // Sits across the dial slit, centred, with a soft dark scrim so the
    // copy stays readable over the tick marks without hiding them.
    css('.tune-hint', [
      css('&').styles(
        position: Position.absolute(
          top: Unit.zero,
          left: Unit.zero,
          right: Unit.zero,
          bottom: Unit.zero,
        ),
        display: Display.flex,
        alignItems: AlignItems.center,
        justifyContent: JustifyContent.center,
        fontFamily: const FontFamily.list([
          FontFamily('IBM Plex Mono'),
          FontFamilies.monospace,
        ]),
        fontSize: Unit.pixels(11),
        fontWeight: FontWeight.w600,
        letterSpacing: 0.22.em,
        color: const Color('#d9c9a4'),
        // Must never swallow the drag it is asking the user to perform.
        pointerEvents: PointerEvents.none,
        zIndex: ZIndex(4),
        raw: {
          'text-transform': 'uppercase',
          'white-space': 'nowrap',
          // No backdrop on the overlay itself. It used to carry a
          // near-opaque radial scrim across the whole dial window, which
          // buried the tick marks and the frequency numbers under it -
          // the hint telling you to drag the dial was hiding the dial.
          // Only the words get a backing now (below), so the band stays
          // readable around them.
          'background': 'none',
          'animation': 'hint-fade-in 0.6s ease-out both',
        },
      ),
      // Local backing behind the text only, sized to the words.
      css('& > span').styles(
        padding: Padding.symmetric(horizontal: 12.px, vertical: 4.px),
        radius: BorderRadius.all(Radius.circular(3.px)),
        raw: {
          'background': 'rgba(3,3,8,0.72)',
          'box-shadow': '0 0 10px 6px rgba(3,3,8,0.55)',
          'text-shadow': '0 0 5px rgba(0,0,0,0.9)',
        },
      ),
      // Pointer-dependent phrasing. Default to the touch wording and let
      // a real hover-capable pointer opt into the keyboard variant, so
      // devices that report neither still get workable instructions.
      css('& .tune-hint-fine').styles(display: Display.none),
    ]),
    css.media(const MediaQuery.raw('(hover: hover) and (pointer: fine)'), [
      css('.tune-hint .tune-hint-fine').styles(display: Display.inline),
      css('.tune-hint .tune-hint-coarse').styles(display: Display.none),
    ]),

    // Glass over the slit. Three layers: two specks of dust caught under
    // the pane, and the reflection itself, angled to the lamp.
    //
    // The dust is the imperfection that costs the least and sells the
    // most: perfectly clean glass is the one thing no forty-year-old
    // receiver has, and two soft specks at coordinates nobody would
    // choose deliberately are enough to break the vector.
    css('.dial-glass').styles(
      position: Position.absolute(top: Unit.zero, left: Unit.zero),
      width: 100.percent,
      height: 100.percent,
      pointerEvents: PointerEvents.none,
      raw: {
        'background':
            'radial-gradient(circle 1.5px at 23% 71%, rgba(255,255,255,0.16), transparent 100%),'
            'radial-gradient(circle 1px at 68.5% 24%, rgba(255,255,255,0.12), transparent 100%),'
            'linear-gradient(118deg, rgba(255,255,255,0.085) 0%, rgba(255,255,255,0.02) 16%, '
            'transparent 34%, transparent 68%, rgba(0,0,0,0.38) 100%)',
      },
    ),

    css('.dial-strip').styles(
      // Anchored at `left: 50%` so a translateX(-freqX) inline style
      // (see `_stripOffset`) lands the current-frequency tick on top
      // of the needle regardless of how wide `.dial-window` is.
      position: Position.absolute(top: Unit.zero, left: 50.percent),
      height: 100.percent,
      // The strip and its children (ticks, labels, markers) MUST NOT
      // capture pointer events - every press should land on `.dial-window`
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
          'background': 'linear-gradient(to bottom, rgba(255,177,58,0.55), rgba(255,177,58,0.15))',
          'box-shadow': '0 0 1px rgba(255,177,58,0.3)',
        },
      ),
      css('&.tick-minor').styles(
        height: 12.px,
        backgroundColor: const Color('#3a3a48'),
      ),
    ]),
    // Dial engravings. Bumped from 9px and given a touch more weight:
    // these are the only thing telling you *where* on the band you are
    // while sweeping, and at 9px in a dim amber they were the hardest
    // working type on the panel and the least legible.
    css('.tick-label').styles(
      position: Position.absolute(top: 26.px),
      fontSize: Unit.pixels(10),
      fontWeight: FontWeight.w500,
      fontFamily: const FontFamily.list([FontFamilies.monospace]),
      color: const Color('#d6a355'),
      letterSpacing: 0.04.em,
      raw: {
        'transform': 'translateX(-50%)',
        'white-space': 'nowrap',
        'text-shadow': '0 0 3px rgba(255,177,58,0.4)',
      },
    ),

    // Pressed state for the FM / AM pills.
    //
    // Written as a top-level selector rather than nested under `.ind`:
    // grouping it with MEM's `&.ind-mem-armed:active` in one
    // comma-separated rule resolved the `&` against `.ind-mem`, emitting
    // `.ind-mem.ind-band-clickable:active` - a selector no element can
    // ever match, so the band pills silently stayed dead under the
    // finger while MEM moved.
    css('.ind.ind-band-clickable:active').styles(
      raw: {
        'transform': 'translateY(1px)',
        'box-shadow': 'inset 2px 2px 3px rgba(0,0,0,0.72)',
      },
    ),

    // The white bar that rips across the slit on a band change.
    css('.band-flash').styles(
      position: Position.absolute(top: Unit.zero, left: Unit.zero),
      width: 100.percent,
      height: 100.percent,
      pointerEvents: PointerEvents.none,
      zIndex: ZIndex(6),
      raw: {
        'background':
            'linear-gradient(90deg, transparent 0%, rgba(255,246,230,0.75) 35%, '
            'rgba(255,255,255,0.95) 50%, rgba(255,246,230,0.75) 65%, transparent 100%)',
        'mix-blend-mode': 'screen',
      },
    ),

    // ── locked-station marker ──
    // A soft column of the station's own colour behind the needle,
    // marking where the carrier sits. Only ever drawn for a station
    // already locked, so it confirms rather than reveals.
    css('.tick-lock').styles(
      width: 3.px,
      height: 100.percent,
      pointerEvents: PointerEvents.none,
      raw: {
        'transform': 'translateX(-50%)',
        'background':
            'linear-gradient(to bottom, transparent 0%, '
            'color-mix(in srgb, var(--sc, #E8A035) 70%, transparent) 35%, '
            'color-mix(in srgb, var(--sc, #E8A035) 70%, transparent) 65%, '
            'transparent 100%)',
        'box-shadow': '0 0 8px color-mix(in srgb, var(--sc, #E8A035) 45%, transparent)',
      },
    ),

    // ── lock acknowledgement ──
    // Takes over the LCD face briefly on capture. Absolutely positioned
    // so the digits underneath never shift.
    css('.lcd-lock-flash').styles(
      position: Position.absolute(
        top: Unit.zero,
        left: Unit.zero,
        right: Unit.zero,
        bottom: Unit.zero,
      ),
      display: Display.flex,
      alignItems: AlignItems.center,
      justifyContent: JustifyContent.center,
      fontFamily: const FontFamily.list([
        FontFamily('IBM Plex Mono'),
        FontFamilies.monospace,
      ]),
      fontSize: Unit.pixels(11),
      fontWeight: FontWeight.w600,
      letterSpacing: 0.22.em,
      color: const Color('#1a1206'),
      pointerEvents: PointerEvents.none,
      zIndex: ZIndex(6),
      raw: {
        // Inverted: dark type on a lit amber face, the way a segment
        // display reads when every cell behind the text is driven.
        'background': 'rgba(232,160,53,0.88)',
        'animation': 'lock-flash 0.9s ease-out both',
        'white-space': 'nowrap',
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
        'box-shadow': '0 0 6px rgba(255,40,40,0.8), 0 0 14px rgba(255,40,40,0.35), inset 0 0 1px rgba(255,255,255,0.6)',
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
          // Outer ribbed rim via repeating-conic-gradient, with a wash of
          // light over it so the ribs on the far side of the knob fall
          // away instead of every rib being equally bright. A ribbed
          // cylinder lit evenly all the way round reads as a pattern, not
          // as a turned metal part.
          'background':
              'radial-gradient(circle at 30% 26%, rgba(255,255,255,0.16) 0%, rgba(255,255,255,0.04) 34%, transparent 62%),'
              'radial-gradient(circle at 74% 80%, rgba(0,0,0,0.45) 0%, transparent 55%),'
              'repeating-conic-gradient(from 0deg, #555560 0deg 4deg, #1a1a24 4deg 8deg)',
          // Cast shadow falls down and to the right; the crisp contact
          // shadow underneath it keeps the knob sitting on the plastic
          // rather than floating over it.
          'box-shadow':
              '2px 4px 10px rgba(0,0,0,0.7), '
              '1px 1px 2px rgba(0,0,0,0.5), '
              'inset 0 0 0 1px rgba(0,0,0,0.6)',
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
        // Specular first, diffuse underneath. A tight bright spot where
        // the lamp is genuinely reflected is what separates metal from
        // matte clay; the broad radial alone only ever gets you clay.
        //
        // Layered into the background rather than drawn as a pseudo
        // element on purpose: an ::after here would paint over the notch
        // and the LED, both of which are children of this cap.
        'background':
            'radial-gradient(ellipse 34% 22% at 33% 24%, rgba(255,255,255,0.26) 0%, rgba(255,255,255,0.06) 46%, transparent 74%),'
            'radial-gradient(circle at 38% 32%, #6a6a78 0%, #3a3a45 45%, #1a1a22 100%)',
        'box-shadow':
            'inset 1px 1px 2px rgba(255,255,255,0.2), '
            'inset -2px -2px 4px rgba(0,0,0,0.6), '
            '1px 1px 2px rgba(0,0,0,0.4)',
      },
    ),
    css('.knob-notch').styles(
      position: Position.absolute(top: 5.px, left: 50.percent),
      width: 3.px,
      height: 14.px,
      radius: BorderRadius.all(Radius.circular(1.5.px)),
      pointerEvents: PointerEvents.none,
      raw: {
        'background': 'linear-gradient(to bottom, #f5f5f8 0%, #c8c8d0 60%, #888894 100%)',
        'box-shadow': '0 0 4px rgba(255,255,255,0.55), 0 0 1px rgba(0,0,0,0.6)',
        'transform-origin': '50% 22px',
        'margin-left': '-1.5px',
      },
    ),

    // ── volume knob (smaller sibling of the tuning knob) ──
    // Geometry mirrors `.knob` at 36 px (52% of the tuner's 68 px).
    // The LED inside doubles as the power indicator - amber at
    // volume 0, green for any non-zero volume.
    css('.vol-knob-wrap').styles(
      display: Display.flex,
      flexDirection: FlexDirection.column,
      alignItems: AlignItems.center,
      gap: Gap(row: 4.px),
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
              'radial-gradient(circle at 30% 26%, rgba(255,255,255,0.16) 0%, rgba(255,255,255,0.04) 34%, transparent 62%),'
              'radial-gradient(circle at 74% 80%, rgba(0,0,0,0.45) 0%, transparent 55%),'
              'repeating-conic-gradient(from 0deg, #555560 0deg 4deg, #1a1a24 4deg 8deg)',
          'box-shadow':
              '1px 3px 6px rgba(0,0,0,0.65), '
              '1px 1px 2px rgba(0,0,0,0.45), '
              'inset 0 0 0 1px rgba(0,0,0,0.6)',
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
            'radial-gradient(ellipse 34% 22% at 33% 24%, rgba(255,255,255,0.26) 0%, rgba(255,255,255,0.06) 46%, transparent 74%),'
            'radial-gradient(circle at 38% 32%, #6a6a78 0%, #3a3a45 45%, #1a1a22 100%)',
        'box-shadow':
            'inset 1px 1px 1.5px rgba(255,255,255,0.2), '
            'inset -1.5px -1.5px 3px rgba(0,0,0,0.6), '
            '1px 1px 2px rgba(0,0,0,0.4)',
      },
    ),
    css('.vol-knob-notch').styles(
      position: Position.absolute(top: 3.px, left: 50.percent),
      width: 2.px,
      height: 8.px,
      radius: BorderRadius.all(Radius.circular(1.px)),
      pointerEvents: PointerEvents.none,
      raw: {
        'background': 'linear-gradient(to bottom, #f5f5f8 0%, #c8c8d0 60%, #888894 100%)',
        'box-shadow': '0 0 3px rgba(255,255,255,0.55), 0 0 1px rgba(0,0,0,0.6)',
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
        // Silkscreen pressed into the plastic, same two-stroke rule as
        // the model plate.
        'text-shadow': '-1px -1px 0 rgba(0,0,0,0.6), 1px 1px 0 rgba(255,255,255,0.05)',
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
          // Recessed socket: the near rim casts into the well, the far
          // rim catches the light coming past it.
          'box-shadow':
              'inset 1px 1px 1.5px rgba(0,0,0,0.75), '
              '0 0 0 1px rgba(0,0,0,0.55), '
              '1px 1px 0 rgba(255,255,255,0.06)',
          // Decay. An LED that fades out over 0.45s and lights in 0.09s
          // is doing what a real one does; symmetric timing is what makes
          // an indicator feel like a div changing colour.
          'transition':
              'background-color var(--dur-glow-off) var(--ease-phosphor), '
              'box-shadow var(--dur-glow-off) var(--ease-phosphor)',
        },
      ),
      css('&.knob-led-on').styles(
        backgroundColor: const Color('#3fc46a'),
        raw: {
          'box-shadow':
              'inset 1px 1px 1.5px rgba(0,0,0,0.45), '
              '0 0 0 1px rgba(0,0,0,0.55), '
              '0 0 5px rgba(63,196,106,0.7), '
              '0 0 10px rgba(63,196,106,0.35)',
          'transition':
              'background-color var(--dur-glow-on) var(--ease-phosphor), '
              'box-shadow var(--dur-glow-on) var(--ease-phosphor)',
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
    //   │     LCD      │  VOL   │  row 1
    //   ├──────────────┼────────┤
    //   │  dial strip  │  TUNE  │  row 2
    //   └──────────────┴────────┘
    //
    // Two columns × two rows: left column (1fr) stacks LCD above the
    // dial; right column (auto) stacks VOL above TUNE, vertically
    // centred in their cells.
    css.media(MediaQuery.screen(maxWidth: 600.px), [
      css('.radio-panel').styles(
        minHeight: 180.px,
        padding: Padding.symmetric(horizontal: 12.px, vertical: 8.px),
      ),
      css('.brand-plate').styles(display: Display.none),
      css('.panel-header').styles(
        raw: {'margin-bottom': '6px', 'justify-content': 'flex-end'},
      ),
      css('.indicator-row').styles(gap: Gap(column: 4.px)),
      // FM / AM / MEM are real controls, not decoration, so they get a
      // little more room to breathe and a 40px hit area. 40 rather than
      // 44 because they sit 4px apart in a row: a 44px box on each would
      // overlap its neighbour and start eating the wrong presses.
      css('.ind').styles(
        fontSize: Unit.pixels(8),
        padding: Padding.symmetric(horizontal: 7.px, vertical: 3.px),
        raw: {'letter-spacing': '0.1em', 'position': 'relative'},
      ),
      css('.ind-band-clickable::after, .ind-mem-armed::after').styles(
        position: Position.absolute(
          top: Unit.expression('calc(50% - 20px)'),
          left: Unit.zero,
        ),
        width: 100.percent,
        height: 40.px,
        raw: {'content': '""'},
      ),
      css('.panel-main').styles(
        raw: {
          'grid-template-columns': '1fr auto',
          'grid-template-rows': 'auto auto',
          'grid-template-areas': '"lcd vol" "dial tune"',
          'column-gap': '10px',
          'row-gap': '6px',
        },
      ),
      // Drawn at 32px so it stays a small trim knob next to the big
      // tuning one, but 32px is under any sane touch minimum. Same
      // trick as the power rocker: grow the hit area, not the artwork.
      css('.vol-knob').styles(width: 32.px, height: 32.px),
      css('.vol-knob::after').styles(
        position: Position.absolute(
          top: Unit.expression('calc(50% - 22px)'),
          left: Unit.expression('calc(50% - 22px)'),
        ),
        width: 44.px,
        height: 44.px,
        raw: {'content': '""', 'border-radius': '50%'},
      ),
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
      // The LCD is 34 px tall here and the digits now stand as tall as
      // their type size, so height binds instead of width.
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
    // ≤380 px: very narrow phones - just tighten the LCD + pill type.
    // Knob sizes already shrunk in the ≤600 block.
    // ── landscape phones ──
    // A phone on its side leaves ~390px of height. The faceplate alone
    // claimed 180 of that, so the screen above it collapsed to a sliver
    // and the station panels ran straight into the panel. There were no
    // rules for this case at all.
    //
    // Keyed on height rather than orientation so a short desktop window
    // gets the same treatment - the problem is vertical room, not which
    // way a phone is held.
    css.media(const MediaQuery.raw('(max-height: 500px)'), [
      css('.radio-panel').styles(
        minHeight: Unit.zero,
        padding: Padding.symmetric(horizontal: 14.px, vertical: 6.px),
      ),
      css('.panel-header').styles(raw: {'margin-bottom': '4px'}),
      // Brand plate is the first thing to go: pure decoration, and the
      // room is needed by the controls.
      css('.brand-plate').styles(display: Display.none),
      css('.panel-main').styles(
        raw: {
          'grid-template-columns': 'auto 1fr auto auto',
          'grid-template-rows': 'auto',
          'grid-template-areas': '"lcd dial vol tune"',
          'column-gap': '12px',
          'row-gap': '0',
        },
      ),
      css('.lcd').styles(height: 32.px),
      css('.dial-window').styles(height: 40.px),
      css('.knob').styles(width: 40.px, height: 40.px),
      css('.knob-cap').styles(raw: {'inset': '4px'}),
      css('.knob-notch').styles(
        height: 9.px,
        raw: {'transform-origin': '50% 12px'},
      ),
      css('.vol-knob').styles(width: 30.px, height: 30.px),
      // No rack override here any more. It used to be pinned to 34px,
      // which clipped the second band in landscape exactly as it did on
      // phones; the cap is now derived from how many rows there are, and
      // a landscape phone is wider than 600px so it uses the compact
      // desktop row slot already.
    ]),

    // ── very wide viewports ──
    // The panel is pinned edge to edge, so on an ultrawide monitor the
    // dial stretched into a runway and the controls drifted to opposite
    // ends of the desk. Capping the inner rows keeps the receiver
    // reading as one object; the plastic still spans the full width, the
    // way a rack unit would.
    css.media(MediaQuery.screen(minWidth: 1400.px), [
      // `width: 100%` is load-bearing here, not decoration.
      //
      // `.radio-panel` is a column flex container with `align-items:
      // stretch`, and per spec stretch stops applying the moment a
      // cross-axis margin is `auto`. So these auto margins alone would
      // drop each row to fit-content. For `.panel-main` - a grid of
      // `auto 1fr auto` - that resolves the dial's `1fr` track to its
      // min-content, which is zero, because `.dial-window` is
      // `width: 100%` with `overflow: hidden`. The column collapsed, the
      // 1230px strip was clipped away entirely, and the frequency band
      // vanished at >=1400px while the LCD and knobs - which have
      // intrinsic width - carried on looking fine.
      //
      // Giving every capped row a definite width restores the stretch
      // the auto margins removed, and the margins then only distribute
      // what is left over.
      css('.panel-header, .panel-main, .collected-rack').styles(
        raw: {
          'width': '100%',
          'max-width': '1180px',
          'margin-left': 'auto',
          'margin-right': 'auto',
        },
      ),
    ]),

    css.media(MediaQuery.screen(maxWidth: 380.px), [
      css('.lcd').styles(height: 30.px),
      css('.lcd-value').styles(fontSize: 1.rem),
      css('.lcd-ghost').styles(
        fontSize: 1.rem,
        raw: {'right': '26px'},
      ),
      css('.lcd-fm').styles(fontSize: Unit.pixels(8)),
      css('.lcd-st').styles(fontSize: Unit.pixels(7)),
    ]),
  ];
}
