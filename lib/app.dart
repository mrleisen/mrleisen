import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:universal_web/js_interop.dart';
import 'package:universal_web/web.dart' as web;

import 'components/phosphor_mask.dart';
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

    // Idle readout copy. The receiver is "searching" when between
    // stations; the dash pattern and band range both key off the
    // active band so AM and FM show different ranges/units.
    final bandLabel = _band == Band.fm ? 'FM' : 'AM';
    final unitLabel = _band == Band.fm ? 'MHZ' : 'KHZ';
    final minLabel = _band == Band.fm
        ? cfg.minFreq.toStringAsFixed(1)
        : cfg.minFreq.toInt().toString();
    final maxLabel = _band == Band.fm
        ? cfg.maxFreq.toStringAsFixed(1)
        : cfg.maxFreq.toInt().toString();
    final idleTop = _lang == Lang.es ? 'SIN PORTADORA' : 'NO CARRIER';
    final idleSub = _lang == Lang.es ? 'BARRIENDO BANDA' : 'SCANNING BAND';

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

      // Effect overlays (order = paint order; z-index is the real
      // stacking order — noise → vignette → phosphor → scanlines).
      StaticNoise(noiseLevel: _noiseLevel, isPowered: _isPowered),
      const Vignette(),
      PhosphorMask(
        intensity: (1.0 - _signalStrength).clamp(0.0, 1.0),
        isPowered: _isPowered,
      ),
      const Scanlines(),

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

      // Idle readout — what a real receiver shows when the dial is
      // parked on dead air. The old "rafahcf / tune in" hero is gone;
      // the personal identity lives inside the WHO station panel
      // instead. Keeping the idle state as a proper no-carrier
      // display makes the whole piece feel like hardware.
      div(
        classes: 'carrier-monitor',
        styles: Styles(
          opacity: contentOpacity,
          raw: {
            'transition': 'opacity 0.4s ease',
            // Only add the horizontal content-jitter when there's real
            // noise present — a calm, locked-in dial keeps the frame
            // perfectly still.
            'animation': (_isPowered && _noiseLevel > 0.3)
                ? 'content-jitter 0.22s steps(2, end) infinite'
                : 'none',
          },
        ),
        [
          // Large dash array — the "missing call-sign" glyph. Five
          // en-dashes with thin-space separators drift slightly so
          // the readout feels alive rather than printed.
          div(
            classes: 'carrier-dashes',
            attributes: {'aria-hidden': 'true'},
            [
              for (var i = 0; i < 5; i++)
                span(
                  classes: 'carrier-dash',
                  styles: Styles(raw: {
                    'animation-delay': '${(i * 0.18).toStringAsFixed(2)}s',
                  }),
                  [text('–')],
                ),
            ],
          ),
          // Primary state line — tracked uppercase, station-style
          // teletype aesthetic.
          div(classes: 'carrier-state', [
            span(classes: 'carrier-dot', []),
            span(classes: 'carrier-state-text', [text(idleTop)]),
            span(classes: 'carrier-dot', []),
          ]),
          // Band + range. The tick-bracket on either side is just
          // text ("[") but the centered ribbon below carries the
          // live search sweep.
          div(classes: 'carrier-band', [
            span(classes: 'carrier-band-band', [text(bandLabel)]),
            span(classes: 'carrier-band-sep', [text('·')]),
            span(classes: 'carrier-band-range',
                [text('$minLabel – $maxLabel')]),
            span(classes: 'carrier-band-sep', [text('·')]),
            span(classes: 'carrier-band-unit', [text(unitLabel)]),
          ]),
          // Sweep ribbon — a thin horizontal bar under the range
          // with a single brighter tracer that runs left→right.
          div(classes: 'carrier-sweep', [
            div(classes: 'carrier-sweep-track', []),
            div(classes: 'carrier-sweep-head', []),
          ]),
          // Sub-caption — small, tracked, breathing opacity.
          div(classes: 'carrier-sub', [text(idleSub)]),
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
    // ── idle "carrier monitor" readout ──
    // Sits in the same vertical slot as the old hero title, but
    // structured as a receiver's between-stations display. The five
    // layers — dashes, CARRIER state line, band/range, sweep ribbon,
    // sub-caption — all share a single vertical flow so the block
    // reads top-down like a real monitoring panel.
    css('.carrier-monitor').styles(
      position: Position.absolute(
        top: Unit.expression('calc(50% - 100px)'),
        left: 50.percent,
      ),
      transform: Transform.translate(x: (-50).percent, y: (-50).percent),
      textAlign: TextAlign.center,
      zIndex: ZIndex(30),
      pointerEvents: PointerEvents.none,
      width: 100.percent,
      maxWidth: 480.px,
      display: Display.flex,
      flexDirection: FlexDirection.column,
      alignItems: AlignItems.center,
      gap: Gap(row: 18.px),
    ),

    // ── dash array ──
    // Row of five en-dashes. Each dash drifts its opacity on its own
    // delay so the array reads as animated silence rather than a
    // frozen placeholder. The row itself drifts horizontally a few
    // pixels via `dash-drift` — a slow, unconscious wobble.
    css('.carrier-dashes').styles(
      display: Display.flex,
      flexDirection: FlexDirection.row,
      alignItems: AlignItems.center,
      justifyContent: JustifyContent.center,
      gap: Gap(column: 18.px),
      raw: {
        'animation': 'dash-drift 6s ease-in-out infinite',
        'color': '#b0b0ba',
        // Constant chromatic fringe on the dashes themselves —
        // mirrors the CRT edge fringe, reads as an unconverged
        // signal.
        'text-shadow':
            '1px 0 0 rgba(255,60,90,0.28), -1px 0 0 rgba(60,200,255,0.28)',
      },
    ),
    css('.carrier-dash').styles(
      fontFamily: const FontFamily.list([
        FontFamily('Orbitron'),
        FontFamilies.monospace,
      ]),
      fontSize: 3.rem,
      fontWeight: FontWeight.w700,
      raw: {
        'line-height': '1',
        'animation': 'carrier-breathe 2.4s ease-in-out infinite',
      },
    ),

    // ── state line: • NO CARRIER • ──
    // Tracked uppercase teletype. The bookend dots are tiny filled
    // circles that pulse amber — the hardware's "signal present"
    // tell-tales, here unlit-grey because nothing is locked.
    css('.carrier-state').styles(
      display: Display.flex,
      flexDirection: FlexDirection.row,
      alignItems: AlignItems.center,
      justifyContent: JustifyContent.center,
      gap: Gap(column: 14.px),
    ),
    css('.carrier-dot').styles(
      width: 5.px,
      height: 5.px,
      radius: BorderRadius.all(Radius.circular(2.5.px)),
      backgroundColor: const Color('#4a3a22'),
      raw: {
        'box-shadow': 'inset 0 1px 1px rgba(0,0,0,0.6), '
            '0 0 3px rgba(232,160,53,0.25)',
      },
    ),
    css('.carrier-state-text').styles(
      fontFamily: const FontFamily.list([
        FontFamily('IBM Plex Mono'),
        FontFamilies.monospace,
      ]),
      fontSize: Unit.pixels(13),
      fontWeight: FontWeight.w500,
      letterSpacing: 0.5.em,
      textTransform: TextTransform.upperCase,
      color: const Color('#d4d4dc'),
      raw: {
        'text-shadow': '0 0 6px rgba(212,212,220,0.35), '
            '0 0 14px rgba(212,212,220,0.12)',
        'animation': 'carrier-breathe 3.2s ease-in-out infinite',
      },
    ),

    // ── band / range line ──
    // `FM · 87.5 – 108.0 · MHZ` — the same layout AM and FM share,
    // just different values. The band marker on the left is the
    // brightest element (identifies which side of the dial the
    // user is on); the range itself is a calmer mid-grey; the
    // unit is the dimmest, like a legend.
    css('.carrier-band').styles(
      display: Display.flex,
      flexDirection: FlexDirection.row,
      alignItems: AlignItems.baseline,
      justifyContent: JustifyContent.center,
      gap: Gap(column: 10.px),
      fontFamily: const FontFamily.list([
        FontFamily('IBM Plex Mono'),
        FontFamilies.monospace,
      ]),
      fontSize: Unit.pixels(11),
      letterSpacing: 0.25.em,
      textTransform: TextTransform.upperCase,
    ),
    css('.carrier-band-band').styles(
      fontWeight: FontWeight.w600,
      color: const Color('#E8A035'),
      raw: {
        'text-shadow':
            '0 0 4px rgba(232,160,53,0.6), 0 0 10px rgba(232,160,53,0.25)',
      },
    ),
    css('.carrier-band-range').styles(
      fontWeight: FontWeight.w500,
      color: const Color('#a6a6b0'),
      raw: {'letter-spacing': '0.15em'},
    ),
    css('.carrier-band-sep').styles(
      color: const Color('#44444a'),
      raw: {'font-weight': '700', 'transform': 'translateY(-1px)'},
    ),
    css('.carrier-band-unit').styles(
      fontWeight: FontWeight.w500,
      color: const Color('#66666f'),
    ),

    // ── sweep ribbon ──
    // A 200 px-wide horizontal strip with a thin baseline. A
    // 20 px-wide "tracer" blob travels left→right on a 3.6 s
    // loop, suggesting the receiver is sweeping the band.
    css('.carrier-sweep').styles(
      position: Position.relative(),
      width: 220.px,
      height: 8.px,
      raw: {'margin-top': '-6px'},
    ),
    css('.carrier-sweep-track').styles(
      position: Position.absolute(
        top: Unit.expression('calc(50% - 0.5px)'),
        left: Unit.zero,
        right: Unit.zero,
      ),
      height: 1.px,
      raw: {
        'background':
            'linear-gradient(90deg, transparent 0%, rgba(180,180,195,0.25) 15%, rgba(180,180,195,0.35) 50%, rgba(180,180,195,0.25) 85%, transparent 100%)',
      },
    ),
    css('.carrier-sweep-head').styles(
      position: Position.absolute(top: Unit.zero),
      width: 24.px,
      height: 8.px,
      raw: {
        'background':
            'radial-gradient(ellipse at center, rgba(232,160,53,0.9) 0%, rgba(232,160,53,0.5) 40%, transparent 75%)',
        'box-shadow':
            '0 0 6px rgba(232,160,53,0.7), 0 0 14px rgba(232,160,53,0.3)',
        'animation': 'carrier-sweep 3.6s ease-in-out infinite',
        'transform': 'translateX(-50%)',
      },
    ),

    // ── sub-caption ──
    // Whispered second line. Dim, small, heavily tracked — the
    // kind of runtime-status text you'd find printed just above
    // a signal-presence indicator on a rack-mounted receiver.
    css('.carrier-sub').styles(
      fontFamily: const FontFamily.list([
        FontFamily('IBM Plex Mono'),
        FontFamilies.monospace,
      ]),
      fontSize: Unit.pixels(9),
      fontWeight: FontWeight.w500,
      letterSpacing: 0.55.em,
      textTransform: TextTransform.upperCase,
      color: const Color('#5a5a62'),
      raw: {
        'animation': 'carrier-breathe 4s ease-in-out infinite',
        'text-indent': '0.55em', // compensate trailing letter-spacing
      },
    ),

    css.media(MediaQuery.screen(maxWidth: 600.px), [
      // Compact lang toggle so it doesn't crowd the top edge.
      css('.lang-toggle').styles(
        fontSize: Unit.pixels(10),
        padding: Padding.symmetric(horizontal: 8.px, vertical: 4.px),
        position: Position.fixed(top: 10.px, right: 10.px),
      ),
      // Idle readout sits a touch higher so it can't overlap the
      // mobile radio panel (height 180 px).
      css('.carrier-monitor').styles(
        position: Position.absolute(
          top: Unit.expression('calc(50% - 90px)'),
          left: 50.percent,
        ),
        gap: Gap(row: 12.px),
      ),
      css('.carrier-dashes').styles(gap: Gap(column: 12.px)),
      css('.carrier-dash').styles(fontSize: 1.9.rem),
      css('.carrier-state-text').styles(
        fontSize: Unit.pixels(10),
        letterSpacing: 0.35.em,
      ),
      css('.carrier-band').styles(
        fontSize: Unit.pixels(9),
        letterSpacing: 0.18.em,
        gap: Gap(column: 6.px),
      ),
      css('.carrier-sweep').styles(width: 180.px),
      css('.carrier-sub').styles(
        fontSize: Unit.pixels(8),
        letterSpacing: 0.35.em,
      ),
    ]),
  ];
}
