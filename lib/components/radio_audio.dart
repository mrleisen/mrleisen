import 'dart:math' as math;
import 'dart:typed_data';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:universal_web/js_interop.dart';
import 'package:universal_web/web.dart' as web;

import '../models/station.dart';

/// `window.__radioAudioCtx` — the AudioContext created synchronously
/// inside the power-button's click/touchend handler. Mobile browsers
/// (iOS Safari, Android Chrome) only accept `resume()` as a user-
/// initiated unlock when it's called in the direct DOM-handler
/// callstack of a clicked element; document-level listeners do not
/// qualify. We stash the context on `window` so the async audio-graph
/// builder in [_RadioAudioState._waitForJsContext] can pick it up
/// after the power-on state propagates through Jaspr without having
/// to thread a reference through Dart closures.
@JS('__radioAudioCtx')
external JSAny? get _jsRadioCtx;
@JS('__radioAudioCtx')
external set _jsRadioCtx(JSAny? value);

/// Synchronously creates the AudioContext and kicks `resume()`. Must
/// be called from inside a real user-gesture handler attached to a
/// UI element (e.g. the power button's click/touchend) — mobile
/// browsers refuse to transition the context to `running` otherwise.
/// Publishes the context on `window.__radioAudioCtx` so RadioAudio's
/// [_RadioAudioState._waitForJsContext] can pick it up after power-on
/// propagates through the component tree.
void unlockAudioContext() {
  if (_jsRadioCtx != null) return;
  try {
    final ctx = web.AudioContext();
    ctx.resume();
    _jsRadioCtx = ctx as JSAny;
  } catch (e) {
    print('AudioContext create/resume failed: $e');
  }
}

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
/// Audio unlock is gated behind a fullscreen "TAP TO TUNE IN" overlay
/// installed in [initState]. A direct Dart-attached click/touchend
/// handler on that overlay synchronously constructs an AudioContext
/// and calls `resume()`, then publishes it to `window.__radioAudioCtx`
/// for [_waitForJsContext] to pick up. Going through any document-
/// level or Jaspr-synthesised event path causes mobile browsers to
/// refuse the unlock.
///
/// NOTE: deliberately NOT marked `@client`. The parent App is already a
/// client island; nesting `@client` here generates a separate
/// hydration island whose markers break the outer island's hydration.
class RadioAudio extends StatefulComponent {
  const RadioAudio({
    required this.frequency,
    required this.noiseLevel,
    required this.isTuning,
    required this.isPowered,
    this.volume = 0.0,
    super.key,
  });

  final double frequency;
  final double noiseLevel;
  final bool isTuning;

  /// Whether the radio is powered on. The audio graph is only built
  /// once this flips to true — [unlockAudioContext] must have run in
  /// the same user gesture that raised the flag.
  final bool isPowered;

  /// Master volume [0.0 – 1.0]. Applied as a scalar multiplier to the
  /// final static + whistle gains. `0.0` fades everything to silence
  /// over `_silenceRamp` without tearing down the audio graph —
  /// flipping volume back up restores instantly.
  final double volume;

  @override
  State<RadioAudio> createState() => _RadioAudioState();
}

class _RadioAudioState extends State<RadioAudio> {
  // Lazily-built nodes — null until the user taps the start overlay.
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

  bool _sourcesStarted = false;

  // Guards _resumeAndApply against concurrent re-entry while an
  // in-flight resume() is still being polled.
  bool _isResuming = false;

  // visibilitychange listener — mobile browsers suspend the
  // AudioContext when the tab/app backgrounds; we resume on return.
  JSFunction? _visibilityListener;

  // Tracks whether _waitForJsContext has been kicked off so we don't
  // start a second poll loop if isPowered flips multiple times.
  bool _initStarted = false;

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

    // If the parent somehow mounted us already-powered (e.g. state
    // persistence), kick off init immediately. Normally power-on
    // arrives later via didUpdateComponent.
    if (component.isPowered) {
      _initStarted = true;
      _waitForJsContext();
    }

    _visibilityListener = _onVisibilityChange.toJS;
    web.document.addEventListener('visibilitychange', _visibilityListener);
  }

  @override
  void didUpdateComponent(RadioAudio oldComponent) {
    super.didUpdateComponent(oldComponent);
    if (!kIsWeb) return;
    if (component.isPowered && !_initStarted) {
      _initStarted = true;
      _waitForJsContext();
      return;
    }
    if (_ctx != null) _applyState();
  }

  @override
  void dispose() {
    if (kIsWeb) {
      if (_visibilityListener != null) {
        web.document
            .removeEventListener('visibilitychange', _visibilityListener);
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

  // ── audio graph construction ──

  /// Polls `window.__radioAudioCtx` every 50 ms waiting for the tap
  /// overlay to publish a context. Once found, builds the Dart-side
  /// graph, starts the sources, and hands off to [_applyState]. The
  /// poll limit is deliberately generous — the overlay blocks all
  /// interaction until the user taps, so a long wait is normal.
  Future<void> _waitForJsContext() async {
    web.AudioContext? ctx;
    // 600 × 50 ms = 30 s. Past that the session is effectively dead.
    for (var i = 0; i < 600; i++) {
      if (!mounted) return;
      final raw = _jsRadioCtx;
      if (raw != null) {
        ctx = raw as web.AudioContext;
        break;
      }
      await Future.delayed(const Duration(milliseconds: 50));
    }
    if (!mounted || ctx == null) return;
    _ctx = ctx;

    // Belt-and-suspenders: if the context got re-suspended between the
    // tap handler and our pickup, ask politely to resume again.
    if (ctx.state == 'suspended') {
      try {
        ctx.resume();
      } catch (e) {
        print('AudioContext resume failed: $e');
      }
    }

    _playSilentUnlockBuffer(ctx);
    _buildGraph(ctx);

    // Poll for running state before starting sources — up to 30 ×
    // 50 ms = 1.5 s.
    for (var i = 0; i < 30; i++) {
      if (!mounted || _ctx == null) return;
      if (ctx.state == 'running') break;
      await Future.delayed(const Duration(milliseconds: 50));
    }
    if (!mounted || _ctx == null) return;

    try {
      _noiseA?.start();
      _noiseB?.start();
      _whistle?.start();
      _sourcesStarted = true;
    } catch (e) {
      print('AudioContext source start failed: $e');
    }
    _applyState();
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
    } catch (e) {
      print('AudioContext silent-unlock buffer failed: $e');
    }
  }

  /// Constructs the noise + whistle graph. Sources are NOT started
  /// here — see [_waitForJsContext] for the delayed start.
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

  /// Fire-and-forget resume + re-apply. Used by [_applyState] when the
  /// context is detected as suspended, and by the visibilitychange
  /// listener when the tab returns to the foreground. [_isResuming]
  /// prevents concurrent callers from stacking resume() promises.
  Future<void> _resumeAndApply() async {
    if (_isResuming) return;
    final ctx = _ctx;
    if (ctx == null) return;
    _isResuming = true;
    try {
      ctx.resume();
    } catch (e) {
      print('AudioContext resume failed: $e');
    }

    // Poll for running state — up to 10 × 50 ms = 500 ms.
    for (var i = 0; i < 10; i++) {
      if (!mounted || _ctx == null) {
        _isResuming = false;
        return;
      }
      if (ctx.state == 'running') break;
      await Future.delayed(const Duration(milliseconds: 50));
    }
    _isResuming = false;
    if (!mounted || _ctx == null) return;
    // If the context is still suspended (resume rejected, or the
    // browser is waiting for a fresh user gesture) don't retry in a
    // tight loop — wait for the next visibility / interaction event.
    if (_ctx!.state == 'suspended') return;
    _applyState();
  }

  void _onVisibilityChange(web.Event _) {
    if (_ctx == null) return;
    if (!web.document.hidden) {
      _resumeAndApply();
    }
  }

  void _applyState() {
    final ctx = _ctx;
    if (ctx == null) return;

    // Some browsers (Android Chrome, iOS Safari on return from
    // background) silently re-suspend the context. Hand off to the
    // async resume path and bail — _resumeAndApply will re-enter this
    // method once the context is actually 'running' again. Scheduling
    // ramps against a suspended context reliably produces silence on
    // mobile, which is exactly the bug we're fixing.
    if (ctx.state == 'suspended') {
      _resumeAndApply();
      return;
    }

    final now = ctx.currentTime;
    final freq = component.frequency;
    final noise = component.noiseLevel;
    final tuning = component.isTuning;
    final volume = component.volume.clamp(0.0, 1.0);

    // Powered off — fade everything to silence. The graph stays wired
    // so power-on restores smoothly without rebuilding nodes.
    if (!component.isPowered) {
      _ramp(_staticGain!.gain, 0, now, _silenceRamp);
      _ramp(_whistleGain!.gain, 0, now, _silenceRamp);
      return;
    }

    // Volume 0 → fade everything to silence over _silenceRamp and
    // short-circuit the rest of the scheduling. The audio graph is
    // kept alive so turning volume back up restores instantly.
    if (volume <= 0.0) {
      _ramp(_staticGain!.gain, 0, now, _silenceRamp);
      _ramp(_whistleGain!.gain, 0, now, _silenceRamp);
      return;
    }

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
    // Master volume scales both gain paths linearly. We already
    // short-circuited on volume == 0 above, so here volume ∈ (0, 1].
    final gainSec = tuning ? _gainRamp : _silenceRamp;

    _ramp(_staticGain!.gain, staticTarget * volume, now, gainSec);
    _ramp(_whistleGain!.gain, whistleTarget * volume, now, gainSec);

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
