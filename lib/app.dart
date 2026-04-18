import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:universal_web/js_interop.dart';
import 'package:universal_web/web.dart' as web;

import 'components/radio_audio.dart';
import 'components/radio_dial.dart';
import 'components/scanlines.dart';
import 'components/signal_bars.dart';
import 'components/station_display.dart';
import 'components/static_noise.dart';
import 'components/vignette.dart';
import 'models/station.dart';

@client
class App extends StatefulComponent {
  const App({super.key});

  @override
  State<App> createState() => AppState();
}

class AppState extends State<App> {
  // Active band + per-band tuned frequency. Switching bands restores
  // whatever frequency the user last parked on in that band.
  Band _band = Band.fm;
  double _fmFreq = 96.5;
  double _amFreq = 1100.0;

  double get _frequency => _band == Band.fm ? _fmFreq : _amFreq;

  // Cached computations updated on every frequency change.
  double _signalStrength = 0.0;
  Station? _activeStation;
  Station? _nearestStation;
  double _noiseLevel = 0.5;

  // True while the user is actively interacting with the dial. Drops back
  // to false ~400ms after the last input — the audio engine uses this to
  // fade in/out so we don't drone constantly.
  bool _isTuning = false;
  Timer? _tuningIdleTimer;
  static const Duration _tuningIdleDelay = Duration(milliseconds: 400);

  // Active UI language. Defaults to English.
  Lang _lang = Lang.en;

  // Master volume [0.0 – 1.0]. Controlled by the small volume knob
  // on the left of the faceplate. Starts at 0.36 so the receiver is
  // already on (LED green, gentle static) when the page loads.
  double _volume = 0.36;

  // Radio power state. Starts off — the faceplate is dimmed and the
  // audio graph is gated on this until the user taps the power button.
  // The power-on gesture is where AudioContext gets created.
  bool _isPowered = false;

  // CRT animation phase for the screen overlay:
  //   'off'         → solid-black overlay covering the content (initial
  //                   load; no animation plays)
  //   'turning-on'  → crt-on keyframe is running
  //   'on'          → overlay transparent, content visible
  //   'turning-off' → crt-off keyframe is running
  // Separate from _isPowered so the overlay can linger on the screen
  // until the animation completes.
  String _crtPhase = 'off';
  Timer? _crtTimer;
  static const Duration _crtOnDuration = Duration(milliseconds: 800);
  static const Duration _crtOffDuration = Duration(milliseconds: 500);

  // Window-level event listeners (stored for cleanup).
  JSFunction? _keyDownListener;
  JSFunction? _wheelListener;

  @override
  void initState() {
    super.initState();
    _recalc();

    if (kIsWeb) {
      _keyDownListener = _onKeyDown.toJS;
      web.document.addEventListener('keydown', _keyDownListener);

      _wheelListener = _onWheel.toJS;
      // Must be non-passive to allow preventDefault.
      web.document.addEventListener(
        'wheel',
        _wheelListener,
        web.AddEventListenerOptions(passive: false),
      );
    }
  }

  @override
  void dispose() {
    _tuningIdleTimer?.cancel();
    _crtTimer?.cancel();
    if (kIsWeb) {
      web.document.removeEventListener('keydown', _keyDownListener);
      web.document.removeEventListener('wheel', _wheelListener);
    }
    super.dispose();
  }

  // --- event handlers ---

  void _onKeyDown(web.Event event) {
    final ke = event as web.KeyboardEvent;
    final step = configFor(_band).step;
    if (ke.key == 'ArrowRight') {
      ke.preventDefault();
      _tune(_frequency + step);
    } else if (ke.key == 'ArrowLeft') {
      ke.preventDefault();
      _tune(_frequency - step);
    }
  }

  void _onWheel(web.Event event) {
    // Only handle wheel at document level when NOT over the radio panel
    // (the panel has its own wheel handler that calls preventDefault).
    final we = event as web.WheelEvent;
    // Check if the event target is inside .radio-panel.
    final target = we.target;
    if (target is web.Element) {
      if (target.closest('.radio-panel') != null) return; // handled by panel
    }
    we.preventDefault();
    final step = configFor(_band).step;
    final delta = we.deltaY > 0 ? step * 2 : -step * 2;
    _tune(_frequency + delta);
  }

  // --- frequency management ---

  void _tune(double newFreq) {
    final cfg = configFor(_band);
    // FM's step (0.1) isn't exactly representable in IEEE-754, so scale
    // up before rounding to avoid drift; AM's integer step rounds
    // cleanly via division.
    if (cfg.step < 1.0) {
      final scale = (1.0 / cfg.step).roundToDouble();
      newFreq = (newFreq * scale).roundToDouble() / scale;
    } else {
      newFreq = (newFreq / cfg.step).roundToDouble() * cfg.step;
    }
    newFreq = newFreq.clamp(cfg.minFreq, cfg.maxFreq);

    // Mark the user as actively tuning regardless of whether the value
    // changed — clicking the dial without moving still counts as
    // interaction and should wake the audio engine.
    _markTuning();

    if (newFreq == _frequency) return;
    setState(() {
      if (_band == Band.fm) {
        _fmFreq = newFreq;
      } else {
        _amFreq = newFreq;
      }
      _recalc();
    });
  }

  /// Flips `_isTuning` to true and (re)arms a timer to drop it back to
  /// false after [_tuningIdleDelay] of silence. setState only fires when
  /// the boolean actually changes, so we don't churn renders.
  void _markTuning() {
    _tuningIdleTimer?.cancel();
    if (!_isTuning) {
      setState(() => _isTuning = true);
    }
    _tuningIdleTimer = Timer(_tuningIdleDelay, () {
      if (mounted) {
        setState(() => _isTuning = false);
      }
    });
  }

  void _recalc() {
    _signalStrength = getSignalStrength(_frequency, _band);
    _activeStation = getActiveStation(_frequency, _band);
    _nearestStation = getNearestStation(_frequency, _band);
    _noiseLevel = noiseFromSignal(_signalStrength);
  }

  void _toggleBand() {
    if (!_isPowered) return;
    setState(() {
      _band = _band == Band.fm ? Band.am : Band.fm;
      _recalc();
    });
    // Mark as tuning so the audio engine produces a short static burst
    // while the dial rearranges.
    _markTuning();
  }

  // --- build ---

  @override
  Component build(BuildContext context) {
    // Idle title fades out as any station comes into content range.
    // Distance ≥ tolerance → fully visible; below that it fades in
    // step with the rising station panel. The 30% hand-off buffer keeps
    // the idle text from fighting the distorted station content in the
    // overlap zone.
    final cfg = configFor(_band);
    final nearestDist = _nearestStation != null
        ? (_frequency - _nearestStation!.frequency).abs()
        : double.infinity;
    final handoff = cfg.tolerance * 0.7;
    final distanceOpacity = nearestDist >= cfg.tolerance
        ? 1.0
        : ((nearestDist - handoff) / (cfg.tolerance - handoff))
            .clamp(0.0, 1.0);
    // Power gates every upper layer — when off, the CRT overlay is
    // opaque black anyway, but we also zero out content opacity so
    // nothing animates or allocates behind the overlay.
    final contentOpacity = _isPowered ? distanceOpacity : 0.0;

    final idleHint = _lang == Lang.es ? 'sintoniza' : 'tune in';

    final rootClass =
        'signal-app ${_isPowered ? 'powered-on' : 'powered-off'}';
    final crtClass = switch (_crtPhase) {
      'turning-on' => 'crt-screen crt-animate-on',
      'on' => 'crt-screen crt-on-done',
      'turning-off' => 'crt-screen crt-animate-off',
      _ => 'crt-screen',
    };

    return div(classes: rootClass, [
      // Audio engine (renders no visible DOM).
      RadioAudio(
        frequency: _frequency,
        band: _band,
        noiseLevel: _noiseLevel,
        isTuning: _isTuning,
        volume: _volume,
        isPowered: _isPowered,
      ),

      // CRT power-on/off overlay — fills the viewport under all
      // content layers but above the root background. Opaque black
      // when off, transparent when on, plays clip-path flash on
      // transitions.
      div(classes: crtClass, []),

      // Effect overlays (order = paint order).
      StaticNoise(noiseLevel: _noiseLevel, isPowered: _isPowered),
      const Scanlines(),
      const Vignette(),

      // Signal-strength meter (top-left).
      SignalBars(
        signalStrength: _signalStrength,
        activeStation: _activeStation,
        nearestStation: _nearestStation,
        isPowered: _isPowered,
      ),

      // Language toggle (top-right).
      div(
        classes: 'lang-toggle',
        events: {'click': (_) => _toggleLang()},
        attributes: {'role': 'button', 'aria-label': 'Toggle language'},
        [text(_lang == Lang.es ? 'ES' : 'EN')],
      ),

      // Centered idle content (jitters subtly while between stations).
      div(
        classes: 'content',
        styles: Styles(
          opacity: contentOpacity,
          raw: {
            'transition': 'opacity 0.4s ease',
            // Jitter only kicks in when noise is meaningfully present.
            // When tuned in (noiseLevel ≤ 0.3) the animation is removed
            // entirely so the title sits perfectly still.
            'animation': (_isPowered && _noiseLevel > 0.3)
                ? 'content-jitter 0.22s steps(2, end) infinite'
                : 'none',
          },
        ),
        [
          div(classes: 'title-wrapper', [
            h1(classes: 'title', [text('rafahcf')]),
            h1(
              classes: 'title title-glitch',
              attributes: {'aria-hidden': 'true'},
              [text('rafahcf')],
            ),
          ]),
          p(classes: 'subtitle', [text(idleHint)]),
        ],
      ),

      // Decoded station content — fades in with distortion across the
      // band's tolerance window, then locks cleanly inside its lockRange.
      StationDisplay(
        frequency: _frequency,
        band: _band,
        lang: _lang,
        isPowered: _isPowered,
      ),

      // Radio dial
      RadioDial(
        frequency: _frequency,
        band: _band,
        onFrequencyChanged: _tune,
        onBandToggle: _toggleBand,
        signalStrength: _signalStrength,
        activeStation: _activeStation,
        volume: _volume,
        onVolumeChanged: _setVolume,
        isPowered: _isPowered,
        onPowerToggle: _togglePower,
      ),
    ]);
  }

  void _toggleLang() {
    setState(() {
      _lang = _lang == Lang.es ? Lang.en : Lang.es;
    });
  }

  void _setVolume(double v) {
    final clamped = v.clamp(0.0, 1.0);
    if (clamped == _volume) return;
    setState(() => _volume = clamped);
  }

  void _togglePower() {
    _crtTimer?.cancel();
    final powering = !_isPowered;
    setState(() {
      _isPowered = powering;
      _crtPhase = powering ? 'turning-on' : 'turning-off';
    });
    final dur = powering ? _crtOnDuration : _crtOffDuration;
    _crtTimer = Timer(dur, () {
      if (!mounted) return;
      setState(() => _crtPhase = _isPowered ? 'on' : 'off');
    });
  }

  @css
  static List<StyleRule> get styles => [
    css('.signal-app').styles(
      position: Position.relative(),
      width: 100.percent,
      height: 100.vh,
      overflow: Overflow.hidden,
      backgroundColor: const Color('#050507'),
    ),
    // ── CRT power overlay ──
    // Fills the viewport above the root background (#050507) but
    // below the noise layer (z:10). When the radio is off the
    // overlay is opaque black; tapping the power switch runs the
    // crt-on / crt-off keyframes with fill-forwards so the final
    // keyframe value holds until the phase class rotates to the
    // matching steady state (`crt-on-done` or the default `.crt-screen`).
    css('.crt-screen', [
      css('&').styles(
        position: Position.fixed(
          top: Unit.zero,
          left: Unit.zero,
          right: Unit.zero,
          bottom: Unit.zero,
        ),
        zIndex: ZIndex(5),
        pointerEvents: PointerEvents.auto,
        backgroundColor: const Color('#000000'),
        opacity: 1,
      ),
      css('&.crt-animate-on').styles(raw: {
        'animation': 'crt-on 0.8s ease-out forwards',
      }),
      css('&.crt-animate-off').styles(raw: {
        'animation': 'crt-off 0.5s ease-in forwards',
      }),
      css('&.crt-on-done').styles(
        pointerEvents: PointerEvents.none,
        opacity: 0,
        raw: {'background': 'transparent'},
      ),
    ]),
    // Scanlines + vignette opacity gated on the root power class.
    // They have no opacity prop so we drive them purely from CSS.
    css('.signal-app .scanlines, .signal-app .vignette').styles(raw: {
      'transition': 'opacity 0.3s ease',
    }),
    css('.signal-app.powered-off .scanlines, '
            '.signal-app.powered-off .vignette')
        .styles(raw: {
      'opacity': '0',
    }),
    // Language toggle pill — fixed top-right.
    css('.lang-toggle', [
      css('&').styles(
        position: Position.fixed(top: 16.px, right: 16.px),
        zIndex: ZIndex(20),
        fontFamily: const FontFamily.list([FontFamilies.monospace]),
        fontSize: Unit.pixels(11),
        fontWeight: FontWeight.w500,
        letterSpacing: 0.2.em,
        color: const Color('#c8c8cc'),
        cursor: Cursor.pointer,
        padding: Padding.symmetric(horizontal: 10.px, vertical: 5.px),
        radius: BorderRadius.all(Radius.circular(99.px)),
        raw: {
          'border': '1px solid rgba(255,255,255,0.12)',
          'background': 'rgba(0,0,0,0.35)',
          'backdrop-filter': 'blur(4px)',
          '-webkit-backdrop-filter': 'blur(4px)',
          'transition': 'border-color 0.2s ease, color 0.2s ease',
          'user-select': 'none',
          '-webkit-user-select': 'none',
        },
      ),
      css('&:hover').styles(
        color: const Color('#ffffff'),
        raw: {'border-color': 'rgba(255,255,255,0.32)'},
      ),
    ]),
    // Centered content — shifted up to avoid dial overlap
    css('.content').styles(
      position: Position.absolute(top: Unit.expression('calc(50% - 100px)'), left: 50.percent),
      transform: Transform.translate(x: (-50).percent, y: (-50).percent),
      textAlign: TextAlign.center,
      zIndex: ZIndex(30),
      pointerEvents: PointerEvents.none,
    ),
    css('.title-wrapper').styles(
      position: Position.relative(),
      display: Display.inlineBlock,
    ),
    css('.title', [
      css('&').styles(
        fontFamily: const FontFamily.list([FontFamilies.monospace]),
        fontSize: 4.rem,
        fontWeight: FontWeight.w300,
        letterSpacing: 0.3.em,
        textTransform: TextTransform.lowerCase,
        color: const Color('#c8c8cc'),
        raw: {
          'animation': 'glitch 4s infinite',
          // Constant subtle chromatic fringe beneath the animated
          // spikes — keeps the glitch ever-present without being loud.
          'text-shadow':
              '1px 0 0 rgba(255,64,64,0.28), -1px 0 0 rgba(64,220,255,0.28)',
        },
      ),
    ]),
    css('.title-glitch').styles(
      position: Position.absolute(top: Unit.zero, left: Unit.zero),
      width: 100.percent,
      opacity: 0.8,
      color: const Color('#c8c8cc'),
      raw: {
        'animation': 'glitch-alt 4s infinite 200ms',
        // Slight vertical offset so the two layers are always just
        // barely misaligned — the eye reads it as a broken signal.
        'transform': 'translate(0, 1px)',
      },
    ),
    css('.subtitle').styles(
      fontSize: 0.9.rem,
      fontWeight: FontWeight.w300,
      letterSpacing: 0.5.em,
      textTransform: TextTransform.lowerCase,
      color: const Color('#555560'),
      raw: {
        'animation': 'pulse 4s ease-in-out infinite',
        'margin-top': '1.5rem',
      },
    ),
    css.media(MediaQuery.screen(maxWidth: 600.px), [
      css('.title').styles(fontSize: 2.2.rem, letterSpacing: 0.15.em),
      css('.subtitle').styles(fontSize: 0.7.rem, letterSpacing: 0.3.em),
      // Compact lang toggle so it doesn't crowd the top edge.
      css('.lang-toggle').styles(
        fontSize: Unit.pixels(10),
        padding: Padding.symmetric(horizontal: 8.px, vertical: 4.px),
        position: Position.fixed(top: 10.px, right: 10.px),
      ),
      // Idle content sits a touch higher so it can't overlap the
      // mobile radio panel (height 180 px).
      css('.content').styles(
        position: Position.absolute(
          top: Unit.expression('calc(50% - 90px)'),
          left: 50.percent,
        ),
      ),
    ]),
  ];
}
