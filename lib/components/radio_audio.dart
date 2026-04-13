import 'dart:math' as math;
import 'dart:typed_data';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:universal_web/js_interop.dart';
import 'package:universal_web/web.dart' as web;

import '../models/station.dart';

/// Web-Audio engine that mimics a real FM radio mid-tuning.
///
/// The graph is two crackly noise paths summed into a master static
/// gain, plus a heterodyne whistle oscillator that mirrors the physical
/// "beat frequency" between the tuner and the nearest carrier:
///
///   sparseNoiseA(loop) ─► highpass(~4 kHz, Q≈0.7) ─► highGain ─┐
///                                                              ├─► staticGain ─► destination
///   sparseNoiseB(loop) ─► lowpass(~800 Hz, Q≈0.7) ──► lowGain ─┘
///
///   sineOsc ──► whistleGain ─► destination
///
/// Why this shape:
/// * The noise buffers are "sparse" (mostly zeros, occasional ±1 spikes)
///   which produces crackle/grit rather than smooth hiss.
/// * Splitting the noise into a high-pass "crisp" path and a low-pass
///   "body" path gives the static both bite and weight without
///   sounding like wind.
/// * The whistle frequency is `distanceToStation * 2000` Hz — exactly
///   on a station the beat is 0 Hz (silence), 1 MHz away it whines at
///   2 kHz. That IS the heterodyne effect on a real superhet receiver.
///
/// Initialisation runs inside a real user-gesture handler attached in
/// [initState] so the browser autoplay policy is satisfied. We listen
/// for `touchstart`, `pointerdown`, `click`, and `keydown` to cover
/// iOS Safari + Android Chrome + desktop + keyboard users.
///
/// iOS Safari needs three things, all inside the gesture:
///   1) the context created (webkit-prefixed on pre-14.5 Safari),
///   2) `resume()` called immediately,
///   3) a 1-sample silent buffer played to "unlock" the pipeline.
/// The actual crackle / whistle sources start on a short delay so the
/// context is fully running before we ask it to emit audible output.
///
/// NOTE: deliberately NOT marked `@client`. The parent App is already a
/// client island; nesting `@client` here generates a separate
/// hydration island whose markers break the outer island's hydration.
class RadioAudio extends StatefulComponent {
  const RadioAudio({
    required this.frequency,
    required this.noiseLevel,
    required this.isTuning,
    super.key,
  });

  final double frequency;
  final double noiseLevel;
  final bool isTuning;

  @override
  State<RadioAudio> createState() => _RadioAudioState();
}

class _RadioAudioState extends State<RadioAudio> {
  // Lazily-built nodes — null until the first user gesture.
  web.AudioContext? _ctx;
  web.AudioBufferSourceNode? _noiseA;
  web.AudioBufferSourceNode? _noiseB;
  web.BiquadFilterNode? _highpass;
  web.BiquadFilterNode? _lowpass;
  web.GainNode? _highGain;
  web.GainNode? _lowGain;
  web.GainNode? _staticGain;
  web.OscillatorNode? _whistle;
  web.GainNode? _whistleGain;

  // One-shot autoplay-unlock listener.
  JSFunction? _gestureListener;
  bool _gestureFired = false;
  bool _sourcesStarted = false;

  /// Event names we listen for to satisfy the first-gesture policy.
  /// `touchstart` is what iOS Safari reliably treats as a user gesture
  /// for audio unlock; `click` covers desktop; `pointerdown` and
  /// `keydown` are belt-and-braces.
  static const _unlockEvents = <String>[
    'touchstart',
    'pointerdown',
    'click',
    'keydown',
  ];

  // ── tuning constants ──

  /// Heterodyne whistle is audible within this many MHz of any station.
  /// Matches the visual content-visibility range so the whistle starts
  /// exactly when the distorted content begins fighting through.
  static const double _whistleRangeMhz = 1.0;
  /// Hz per MHz of detuning. 1 MHz off → 2000 Hz beat; 0 MHz → 0 Hz.
  static const double _whistleHzPerMhz = 2000.0;
  /// Whistle peak amplitude (very thin, never loud — top of spec range).
  static const double _whistleCeiling = 0.09;

  /// Static peak amplitude when the user is actively tuning. Cap on
  /// the sum of the high-pass + low-pass paths.
  static const double _staticCeiling = 0.12;
  /// Idle static volume, expressed as a fraction of [_staticCeiling].
  /// When the user releases the dial the static drops to this level
  /// instead of going silent — so the radio keeps hissing like a real
  /// receiver searching for a carrier. Grabbing the dial again lifts
  /// the volume back to the full ceiling.
  static const double _idleStaticFactor = 0.7;
  /// Below this noiseLevel we consider the user "tuned in" → silence.
  static const double _silenceThreshold = 0.1;

  /// Ramp times.
  static const double _paramRamp = 0.06; // filter / pitch sweeps
  static const double _gainRamp = 0.12; // gain transitions while tuning
  static const double _silenceRamp = 0.3; // fade to silence on release

  // Cached scheduled values to avoid re-ramping to identical targets.
  double _scheduledWhistleHz = 0;

  @override
  void initState() {
    super.initState();
    if (!kIsWeb) return;

    // One-shot autoplay-unlock. Capture phase + once: the handler runs
    // before any other listener and the browser auto-removes it after
    // it fires. We register on four event types so any first
    // interaction unlocks audio on every platform we care about.
    _gestureListener = _onFirstGesture.toJS;
    final opts = web.AddEventListenerOptions(capture: true, once: true);
    for (final ev in _unlockEvents) {
      web.document.addEventListener(ev, _gestureListener, opts);
    }
  }

  @override
  void didUpdateComponent(RadioAudio oldComponent) {
    super.didUpdateComponent(oldComponent);
    if (!kIsWeb || _ctx == null) return;
    _applyState();
  }

  @override
  void dispose() {
    if (kIsWeb) {
      if (!_gestureFired && _gestureListener != null) {
        for (final ev in _unlockEvents) {
          web.document.removeEventListener(ev, _gestureListener);
        }
      }
      if (_ctx != null) {
        try {
          if (_sourcesStarted) {
            _noiseA?.stop();
            _noiseB?.stop();
            _whistle?.stop();
          }
          _ctx?.close();
        } catch (_) {
          // Already-stopped or already-closed nodes throw; ignore.
        }
      }
    }
    super.dispose();
  }

  // ── one-shot autoplay unlock ──

  void _onFirstGesture(web.Event _) {
    if (_gestureFired || !mounted) return;
    _gestureFired = true;
    if (_gestureListener != null) {
      for (final ev in _unlockEvents) {
        web.document.removeEventListener(ev, _gestureListener);
      }
    }
    _initAudio();
  }

  // ── audio graph construction ──

  /// Creates an AudioContext, preferring the standard constructor and
  /// falling back to the webkit-prefixed one for legacy iOS Safari.
  /// Returns `null` if neither works.
  web.AudioContext? _createContext() {
    try {
      return web.AudioContext();
    } catch (_) {
      // Fall through to webkit fallback.
    }
    try {
      // `_WebkitAudioContext` is an extension type over JSObject bound
      // to `window.webkitAudioContext`. If that property is missing the
      // constructor call throws and we return null.
      final raw = _WebkitAudioContext() as JSObject;
      return raw as web.AudioContext;
    } catch (_) {
      return null;
    }
  }

  void _initAudio() {
    final ctx = _createContext();
    if (ctx == null) return;
    _ctx = ctx;

    // iOS Safari unlock sequence — must run inside the user gesture:
    //   1) resume() the (possibly suspended) context,
    //   2) play a 1-sample silent buffer through destination so iOS
    //      registers the pipeline as "user-initiated".
    try {
      ctx.resume();
    } catch (_) {/* best-effort */}
    _playSilentUnlockBuffer(ctx);

    _buildGraph(ctx);

    // Small delay before starting the real sources. Gives the context
    // time to finish transitioning to 'running' on platforms where
    // resume() is asynchronous (notably iOS Safari). The sources' first
    // samples then go out into a fully-unlocked pipeline.
    Future.delayed(const Duration(milliseconds: 80), () {
      if (!mounted || _ctx == null) return;
      try {
        _noiseA?.start();
        _noiseB?.start();
        _whistle?.start();
        _sourcesStarted = true;
      } catch (_) {/* already started */}
      // Defensive second resume — some Android Chrome builds re-suspend
      // between context construction and the first scheduled node event.
      try {
        _ctx?.resume();
      } catch (_) {}
      _applyState();
    });
  }

  /// Short silent buffer → destination. This is the canonical iOS
  /// Safari Web-Audio unlock: without it, the context can be `running`
  /// and still output nothing until a buffer source has played.
  void _playSilentUnlockBuffer(web.AudioContext ctx) {
    try {
      final buffer = ctx.createBuffer(1, 1, ctx.sampleRate);
      final source = ctx.createBufferSource()..buffer = buffer;
      source.connect(ctx.destination);
      source.start(0);
    } catch (_) {/* best-effort */}
  }

  /// Constructs the noise + whistle graph. Sources are NOT started
  /// here — see [_initAudio] for the delayed start.
  void _buildGraph(web.AudioContext ctx) {
    // Two independent sparse-noise buffers. Different seeds + different
    // sparsity densities so the crackles never line up (which would
    // sound mechanical).
    final bufA = _makeSparseBuffer(ctx, seedHash: 0xC0FFEE, density: 0.30);
    final bufB = _makeSparseBuffer(ctx, seedHash: 0xBADCAFE, density: 0.22);

    final srcA = ctx.createBufferSource()
      ..buffer = bufA
      ..loop = true;
    _noiseA = srcA;
    final srcB = ctx.createBufferSource()
      ..buffer = bufB
      ..loop = true;
    _noiseB = srcB;

    // High-pass: removes the smooth low-frequency hiss, keeps the bite.
    final hp = ctx.createBiquadFilter()..type = 'highpass';
    hp.frequency.value = 4000;
    hp.Q.value = 0.7;
    _highpass = hp;

    // Low-pass: gives the static some "body" so it doesn't sound thin.
    final lp = ctx.createBiquadFilter()..type = 'lowpass';
    lp.frequency.value = 800;
    lp.Q.value = 0.7;
    _lowpass = lp;

    // Per-path gains let us bias the mix (more crisp than body).
    final hg = ctx.createGain()..gain.value = 0.85;
    _highGain = hg;
    final lg = ctx.createGain()..gain.value = 0.45;
    _lowGain = lg;

    // Master static gain — modulated by isTuning + noiseLevel.
    final staticGain = ctx.createGain()..gain.value = 0;
    _staticGain = staticGain;

    // Heterodyne whistle path.
    final osc = ctx.createOscillator()..type = 'sine';
    osc.frequency.value = 0;
    _whistle = osc;
    final wg = ctx.createGain()..gain.value = 0;
    _whistleGain = wg;

    // Wire it all up.
    srcA.connect(hp);
    hp.connect(hg);
    hg.connect(staticGain);

    srcB.connect(lp);
    lp.connect(lg);
    lg.connect(staticGain);

    staticGain.connect(ctx.destination);

    osc.connect(wg);
    wg.connect(ctx.destination);
  }

  /// Build a "sparse-noise" buffer: mostly silence with occasional
  /// ±1 spikes. This is what gives the static crackle/grit instead of
  /// smooth hiss.
  ///
  /// [density] is the probability that any given sample is a spike
  /// (the rest are zero).
  web.AudioBuffer _makeSparseBuffer(
    web.AudioContext ctx, {
    required int seedHash,
    required double density,
  }) {
    final sampleRate = ctx.sampleRate;
    final length = (sampleRate * 2).round(); // 2 seconds, looped
    final buffer = ctx.createBuffer(1, length, sampleRate);
    final samples = Float32List(length);
    final rng = math.Random(seedHash);
    for (var i = 0; i < length; i++) {
      if (rng.nextDouble() < density) {
        // Random ±1 spike. Sign chosen separately so spikes are
        // bipolar around zero rather than DC-biased.
        samples[i] = rng.nextDouble() < 0.5 ? -1.0 : 1.0;
      } else {
        samples[i] = 0;
      }
    }
    buffer.copyToChannel(samples.toJS, 0);
    return buffer;
  }

  // ── per-frame parameter updates ──

  void _applyState() {
    final ctx = _ctx;
    if (ctx == null) return;

    // Some browsers (Android Chrome, in particular) can silently
    // re-suspend the context after construction. Poke it back awake
    // before scheduling any parameter changes.
    if (ctx.state == 'suspended') {
      try {
        ctx.resume();
      } catch (_) {}
    }

    final now = ctx.currentTime;
    final freq = component.frequency;
    final noise = component.noiseLevel;
    final tuning = component.isTuning;

    // ── 1) STATIC gain ──
    // The radio is "on" whenever we're between stations — static plays
    // continuously regardless of interaction, like a real FM receiver
    // that hisses until you land on a carrier.
    //
    // Idle volume is `_idleStaticFactor` of the tuning ceiling so
    // grabbing the dial still adds a small perceptible lift.
    double staticTarget;
    if (noise < _silenceThreshold) {
      // Signal locked — silence.
      staticTarget = 0;
    } else {
      // Linearise noise into (0..1) above the silence threshold so
      // crossing it doesn't pop.
      final t = ((noise - _silenceThreshold) / (1.0 - _silenceThreshold))
          .clamp(0.0, 1.0);
      final ceiling =
          tuning ? _staticCeiling : _staticCeiling * _idleStaticFactor;
      staticTarget = ceiling * t;
    }

    // ── 2) HETERODYNE whistle ──
    // Distance to nearest station, in MHz. Lower = closer = lower beat
    // frequency; exactly on a station = 0 Hz = silence.
    //
    // The frequency dial rounds to 0.1 MHz steps, so `distMhz` is always
    // a multiple of 0.1. The curve below is tuned so that the whistle
    // is:
    //   * clearly audible from ~1.5 MHz away (picks the user up early),
    //   * at near-full amplitude from ~0.4 MHz in,
    //   * muted only when the dial lands exactly on a station (distance
    //     0.0) so the user hears the lock as a sudden silence.
    final distMhz = _distanceToNearestStation(freq);
    double whistleHz = 0;
    double whistleTarget = 0;
    if (tuning && distMhz < _whistleRangeMhz) {
      whistleHz = distMhz * _whistleHzPerMhz;
      // Linear proximity, then a 0.6 exponent so the curve rises faster
      // at the far edge (more audible when approaching) and plateaus
      // near the station.
      final proximity = 1.0 - (distMhz / _whistleRangeMhz);
      final closeness = math.pow(proximity.clamp(0.0, 1.0), 0.6).toDouble();
      // Mute exactly on station. 0.02 < 0.1 step so this only triggers
      // at distMhz == 0.0.
      final lockMute = (distMhz < 0.02) ? 0.0 : 1.0;
      whistleTarget = _whistleCeiling * closeness * lockMute;
    }

    // ── 3) Schedule everything with smooth ramps ──
    final gainSec = tuning ? _gainRamp : _silenceRamp;

    _ramp(_staticGain!.gain, staticTarget, now, gainSec);
    _ramp(_whistleGain!.gain, whistleTarget, now, gainSec);

    if (whistleHz != _scheduledWhistleHz) {
      _ramp(_whistle!.frequency, whistleHz, now, _paramRamp);
      _scheduledWhistleHz = whistleHz;
    }
  }

  // ── helpers ──

  /// Distance in MHz from [freq] to the nearest station, regardless of
  /// the project-wide tolerance constant. Used to drive the whistle.
  double _distanceToNearestStation(double freq) {
    var best = double.infinity;
    for (final s in stations) {
      final d = (freq - s.frequency).abs();
      if (d < best) best = d;
    }
    return best;
  }

  /// Smooth parameter ramp. Anchors the current value at `now` first to
  /// avoid clicks when a previous ramp is still in flight, then linearly
  /// ramps to [target] over [seconds].
  void _ramp(web.AudioParam param, double target, double now, double seconds) {
    try {
      param.cancelScheduledValues(now);
      param.setValueAtTime(param.value, now);
      param.linearRampToValueAtTime(target, now + seconds);
    } catch (_) {
      param.value = target;
    }
  }

  // ── render ──
  // Invisible — exists only to participate in the component tree so
  // jaspr preserves its State across rebuilds.
  @override
  Component build(BuildContext context) {
    return span(
      classes: 'radio-audio',
      styles: Styles(display: Display.none),
      [],
    );
  }
}

/// Legacy iOS Safari (< 14.5) exposes the AudioContext constructor as
/// `window.webkitAudioContext`. Modern browsers leave it undefined, so
/// the factory call throws — handled by the caller's try/catch.
@JS('webkitAudioContext')
extension type _WebkitAudioContext._(JSObject _) implements JSObject {
  external factory _WebkitAudioContext();
}
