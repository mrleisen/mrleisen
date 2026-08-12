import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:universal_web/js_interop.dart';
import 'package:universal_web/web.dart' as web;

import '../models/station.dart';

/// `window.__radioAudioCtx` - the AudioContext created synchronously
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
/// UI element (e.g. the power button's click/touchend) - mobile
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
/// gain, a heterodyne whistle oscillator that mirrors the physical
/// "beat frequency" between the tuner and the nearest carrier, and the
/// station's own programme:
///
///   sparseNoiseA(loop) ─► highpass(~4 kHz, Q≈0.7) ─► highGain ─┐
///                                                              ├─► staticGain ─► destination
///   sparseNoiseB(loop) ─► lowpass(~800 Hz, Q≈0.7) ──► lowGain ─┘
///
///   sineOsc ──► whistleGain ─► destination
///
///   <audio loop> ──► mediaSource ──► musicGain ─► destination
///
/// Why this shape:
/// * The noise buffers are "sparse" (mostly zeros, occasional ±1 spikes)
///   which produces crackle/grit rather than smooth hiss.
/// * Splitting the noise into a high-pass "crisp" path and a low-pass
///   "body" path gives the static both bite and weight without
///   sounding like wind.
/// * The whistle frequency is `distanceToStation * 2000` Hz - exactly
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
    required this.band,
    required this.noiseLevel,
    required this.isTuning,
    required this.isPowered,
    this.signalStrength = 0.0,
    this.musicSrc,
    this.volume = 0.0,
    super.key,
  });

  final double frequency;
  final Band band;
  final double noiseLevel;
  final bool isTuning;

  /// Proximity to the nearest station, 0 at the tolerance edge and 1 on
  /// the carrier. Drives the music up as [noiseLevel] takes the static
  /// down, so the two cross rather than swap.
  final double signalStrength;

  /// What the nearest in-range station is broadcasting, or null when the
  /// dial is in dead air. Changing this swaps the stream.
  final String? musicSrc;

  /// Whether the radio is powered on. The audio graph is only built
  /// once this flips to true - [unlockAudioContext] must have run in
  /// the same user gesture that raised the flag.
  final bool isPowered;

  /// Master volume [0.0 – 1.0]. Applied as a scalar multiplier to the
  /// final static + whistle gains. `0.0` fades everything to silence
  /// over `_silenceRamp` without tearing down the audio graph -
  /// flipping volume back up restores instantly.
  final double volume;

  @override
  State<RadioAudio> createState() => _RadioAudioState();
}

class _RadioAudioState extends State<RadioAudio> {
  // Lazily-built nodes - null until the user taps the start overlay.
  web.AudioContext? _ctx;
  web.AudioBufferSourceNode? _noiseA;
  web.AudioBufferSourceNode? _noiseB;
  // The two filters and their per-path gains are deliberately *not* held
  // as fields. Nothing ever reads them back - they are configured once at
  // build time and never touched again - and a node that is connected
  // into a graph reaching `destination` is kept alive by the audio system
  // itself, not by a Dart reference. Holding them was four write-only
  // fields pretending to be state. If a filter ever needs modulating at
  // runtime, that is when it earns a field.
  web.GainNode? _staticGain;
  web.OscillatorNode? _whistle;
  web.GainNode? _whistleGain;

  // ── the programme ──
  // One element and one MediaElementAudioSourceNode for all twelve
  // stations, with `src` swapped as the dial moves, rather than twelve of
  // each. A source node is permanently bound to the element it was
  // created from, but the element is free to change what it is playing,
  // so one pair covers the whole band plan - and only one track is ever
  // in flight, which is the difference between streaming 3 MB and
  // streaming 36.
  web.HTMLAudioElement? _musicEl;
  web.GainNode? _musicGain;

  /// The `src` currently loaded, so a re-render that changes nothing
  /// doesn't restart the track. Compared before every assignment.
  String? _loadedMusicSrc;

  /// Where each station was when the dial left it, keyed by `src`.
  ///
  /// Tuning away and back resumes the track rather than restarting it,
  /// which is the closer lie: a real station does not begin again because
  /// you came back. It is a lie either way - the recording is paused, not
  /// still playing - but the wrong half of a song is a better wrong than
  /// the same eight bars every time the dial passes.
  final Map<String, double> _musicPos = <String, double>{};

  /// Tracks that failed to load, and are not to be asked for again.
  ///
  /// Without this a station whose file is missing is retried on every
  /// tune event - and every tune event is a dial step, so easing past a
  /// 404 fires a burst of identical failing requests. One attempt per
  /// track per session is enough to establish that it is not there.
  final Set<String> _deadMusicSrc = <String>{};

  /// Whether this browser decodes Ogg Vorbis. Probed once, on the first
  /// station the dial comes near; null until then.
  bool? _canPlayOgg;

  /// Pending pause, armed when the music fades out so the element is not
  /// stopped mid-fade. Cancelled if the dial comes back into range.
  Timer? _musicPauseTimer;

  /// The element's `error` handler, which is what marks a track dead.
  JSFunction? _musicErrorListener;

  /// One-shot `loadedmetadata` handler for the seek-on-swap, held so it
  /// can be detached if another swap happens before it fires.
  JSFunction? _musicSeekListener;

  bool _sourcesStarted = false;

  // Guards _resumeAndApply against concurrent re-entry while an
  // in-flight resume() is still being polled.
  bool _isResuming = false;

  // visibilitychange listener - mobile browsers suspend the
  // AudioContext when the tab/app backgrounds; we resume on return.
  JSFunction? _visibilityListener;

  // Tracks whether _waitForJsContext has been kicked off so we don't
  // start a second poll loop if isPowered flips multiple times.
  bool _initStarted = false;

  // ── tuning constants ──

  // Heterodyne whistle range/scale comes from the active band's
  // BandConfig at runtime (FM: MHz × 2000, AM: kHz × 25) so the beat
  // frequency tops out around 2 kHz for either band regardless of unit.

  /// Whistle peak amplitude (very thin, never loud - top of spec range).
  static const double _whistleCeiling = 0.09;

  /// Static peak amplitude when the user is actively tuning. Cap on
  /// the sum of the high-pass + low-pass paths.
  static const double _staticCeiling = 0.12;

  /// Programme peak amplitude, reached on the carrier.
  ///
  /// Deliberately low. This is a station playing under a piece of
  /// hardware, not a player - the reference is the music in a lobby,
  /// which you notice second. It still sits above [_staticCeiling]
  /// (0.12) because a mastered track has to win against the noise it is
  /// replacing, but only just: at the crossover the two are audible at
  /// once, which is the entire point of the crossfade.
  ///
  /// Everything here is scaled by the user's volume control on top, so
  /// this is the ceiling of the ceiling.
  static const double _musicCeiling = 0.18;

  /// Fade applied to the programme as the dial moves. Slower than
  /// [_gainRamp]: static reacts instantly because it is noise, music
  /// swells because it is a signal arriving.
  static const double _musicRamp = 0.45;

  /// How long the element keeps running after the music has faded to
  /// nothing before it is actually paused. Covers the fade, plus enough
  /// slack that flicking across a station and back does not stutter.
  static const Duration _musicPauseDelay = Duration(milliseconds: 900);

  /// Idle static volume, expressed as a fraction of [_staticCeiling].
  /// When the user releases the dial the static drops to this level
  /// instead of going silent - so the radio keeps hissing like a real
  /// receiver searching for a carrier. Grabbing the dial again lifts
  /// the volume back to the full ceiling.
  static const double _idleStaticFactor = 0.7;

  /// Below this noiseLevel we consider the user "tuned in" → silence.
  static const double _silenceThreshold = 0.1;

  /// Ramp times.
  static const double _paramRamp = 0.06; // filter / pitch sweeps
  static const double _gainRamp = 0.12; // gain transitions while tuning
  static const double _silenceRamp = 0.3; // fade to silence on release
  static const double _lockSettleRamp = 0.34; // carrier taking over on lock

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
        web.document.removeEventListener('visibilitychange', _visibilityListener);
      }
      _musicPauseTimer?.cancel();
      _detachMusicSeekListener();
      final musicEl = _musicEl;
      if (musicEl != null) {
        try {
          if (_musicErrorListener != null) {
            musicEl.removeEventListener('error', _musicErrorListener);
            _musicErrorListener = null;
          }
          musicEl.pause();
          // Emptying the src aborts an in-flight fetch. Removing the
          // node alone does not: a media element that is still loading
          // keeps its request alive after it leaves the document.
          musicEl.removeAttribute('src');
          musicEl.load();
          musicEl.remove();
        } catch (_) {}
        _musicEl = null;
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
  /// poll limit is deliberately generous - the overlay blocks all
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

    // Poll for running state before starting sources - up to 30 ×
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
  /// here - see [_waitForJsContext] for the delayed start.
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

    // Low-pass: gives the static some "body" so it doesn't sound thin.
    final lp = ctx.createBiquadFilter()..type = 'lowpass';
    lp.frequency.value = 800;
    lp.Q.value = 0.7;

    // Per-path gains let us bias the mix (more crisp than body).
    final hg = ctx.createGain()..gain.value = 0.85;
    final lg = ctx.createGain()..gain.value = 0.45;

    // Master static gain - modulated by isTuning + noiseLevel.
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

    _buildMusicPath(ctx);
  }

  /// The programme path: a detached looping `<audio>` element routed
  /// into the same context as everything else.
  ///
  /// An element rather than a decoded AudioBuffer because these are full
  /// tracks: `decodeAudioData` would pull each one into memory whole and
  /// hold it there, for twelve stations, to play one at a time. The
  /// element streams and the browser handles the buffering.
  ///
  /// Routed through the context rather than driven by `element.volume`
  /// so the crossfade can use the same `linearRampToValueAtTime` the
  /// static and whistle use. `element.volume` has no automation, so
  /// fading it means stepping it on a timer - a hand-rolled second
  /// implementation of what the graph already does, and one that would
  /// drift out of step with the fade it is supposed to be crossing.
  void _buildMusicPath(web.AudioContext ctx) {
    try {
      final el = web.HTMLAudioElement()
        ..loop = true
        // Nothing is fetched until the dial first comes near a station.
        // The site opens on dead air by design, and a visitor who never
        // tunes anywhere should never pay for a track.
        ..preload = 'none'
        ..crossOrigin = 'anonymous';
      // The element is in the document but never rendered. Detached
      // media elements are legal per spec and work in Chrome and
      // Firefox; Safari has historically been unreliable about playing
      // them, and appending costs one hidden node.
      el.style.display = 'none';
      web.document.body?.append(el);
      _musicEl = el;

      // A station whose file is missing or unplayable becomes a station
      // that broadcasts a carrier and nothing else. That is a state the
      // receiver already has a name for, so it needs no handling beyond
      // not asking again.
      final onError = ((web.Event _) {
        final src = _loadedMusicSrc;
        if (src == null) return;
        _deadMusicSrc.add(src);
        final gain = _musicGain;
        final ctx = _ctx;
        if (gain != null && ctx != null) {
          _ramp(gain.gain, 0, ctx.currentTime, _musicRamp);
        }
      }).toJS;
      _musicErrorListener = onError;
      el.addEventListener('error', onError);

      final source = ctx.createMediaElementSource(el);
      final mg = ctx.createGain()..gain.value = 0;
      _musicGain = mg;

      source.connect(mg);
      mg.connect(ctx.destination);
    } catch (e) {
      // A browser that refuses the media-element source leaves the rest
      // of the radio intact - the station simply broadcasts nothing.
      print('Music path build failed: $e');
      _musicEl = null;
      _musicGain = null;
    }
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

    // Poll for running state - up to 10 × 50 ms = 500 ms.
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
    // tight loop - wait for the next visibility / interaction event.
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
    // async resume path and bail - _resumeAndApply will re-enter this
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

    // Ahead of the power and volume short-circuits below, not after
    // them: the programme has to be faded out and paused on power-off
    // and at volume zero, and both of those branches return early. It
    // re-checks the same two conditions itself.
    _applyMusic(now, volume);

    // Powered off - fade everything to silence. The graph stays wired
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
    // The radio is "on" whenever we're between stations - static plays
    // continuously regardless of interaction, like a real FM receiver
    // that hisses until you land on a carrier.
    //
    // Idle volume is `_idleStaticFactor` of the tuning ceiling so
    // grabbing the dial still adds a small perceptible lift.
    double staticTarget;
    if (noise < _silenceThreshold) {
      // Signal locked - silence.
      staticTarget = 0;
    } else {
      // Linearise noise into (0..1) above the silence threshold so
      // crossing it doesn't pop.
      final t = ((noise - _silenceThreshold) / (1.0 - _silenceThreshold)).clamp(0.0, 1.0);
      final ceiling = tuning ? _staticCeiling : _staticCeiling * _idleStaticFactor;
      staticTarget = ceiling * t;
    }

    // ── 2) HETERODYNE whistle ──
    // Distance to nearest station in the band's native unit (MHz on
    // FM, kHz on AM). Lower = closer = lower beat frequency; exactly
    // on a station = 0 Hz = silence.
    //
    // The curve is tuned so the whistle is:
    //   * clearly audible from the far edge of the tolerance window,
    //   * at near-full amplitude from roughly 40% in,
    //   * muted only when the dial lands exactly on a station so the
    //     user hears the lock as a sudden silence.
    final cfg = configFor(component.band);
    final dist = _distanceToNearestStation(freq, component.band);
    double whistleHz = 0;
    double whistleTarget = 0;
    if (tuning && dist < cfg.tolerance) {
      whistleHz = dist * cfg.whistleScale;
      // Linear proximity, then a 0.6 exponent so the curve rises faster
      // at the far edge (more audible when approaching) and plateaus
      // near the station.
      final proximity = 1.0 - (dist / cfg.tolerance);
      final closeness = math.pow(proximity.clamp(0.0, 1.0), 0.6).toDouble();
      // Mute exactly on station. half-a-step threshold so only
      // distance == 0 triggers (dial values are always multiples of
      // cfg.step).
      final lockMute = (dist < cfg.step / 2) ? 0.0 : 1.0;
      whistleTarget = _whistleCeiling * closeness * lockMute;
    }

    // ── 3) Schedule everything with smooth ramps ──
    // Master volume scales both gain paths linearly. We already
    // short-circuited on volume == 0 above, so here volume ∈ (0, 1].
    final gainSec = tuning ? _gainRamp : _silenceRamp;

    // The moment of lock gets its own, longer decay. At _gainRamp the
    // whistle and static stopped in 120 ms, which lands as a cut - the
    // audio equivalent of a jump cut, and it made capturing a station
    // feel like a bug rather than an event. Letting it fall over
    // _lockSettleRamp instead reads as the carrier taking over: the beat
    // note slides away and the hiss drains under it.
    final locked = staticTarget == 0 && whistleTarget == 0;
    final settleSec = locked ? _lockSettleRamp : gainSec;

    _ramp(_staticGain!.gain, staticTarget * volume, now, settleSec);
    _ramp(_whistleGain!.gain, whistleTarget * volume, now, settleSec);

    if (whistleHz != _scheduledWhistleHz) {
      _ramp(_whistle!.frequency, whistleHz, now, _paramRamp);
      _scheduledWhistleHz = whistleHz;
    }
  }

  // ── the programme ──

  /// Rides the station's track against the static.
  ///
  /// The gain is `signalStrength` straight through, which is the whole
  /// reason the two cross cleanly: static is driven by `noiseLevel`,
  /// `noiseLevel` is derived from the same signal, so as one falls the
  /// other rises on the identical curve. Nothing here re-derives the
  /// crossover point - there isn't one to get wrong.
  ///
  /// That curve already has the knee ([_signalKnee] in `station.dart`),
  /// so the music stays almost inaudible across the outer band and
  /// arrives in the last third, the same way the carrier does. Coming in
  /// linearly instead would announce the station long before the dial is
  /// anywhere near it.
  void _applyMusic(double now, double volume) {
    final gain = _musicGain;
    final el = _musicEl;
    if (gain == null || el == null) return;

    // Resolved here rather than at the prop, so the dead set, the
    // position map and the swap all key on the file actually loaded.
    final declared = component.musicSrc;
    final src = declared == null ? null : _resolveMusicSrc(declared);
    // Dead air, powered off, muted, or a track that already failed to
    // load - all the same thing to the programme. Fade it out and let
    // the pause follow the fade.
    if (src == null || _deadMusicSrc.contains(src) || !component.isPowered || volume <= 0.0) {
      _ramp(gain.gain, 0, now, _musicRamp);
      _armMusicPause();
      return;
    }

    _swapMusicSrc(src);

    final target = _musicCeiling * component.signalStrength.clamp(0.0, 1.0) * volume;
    _ramp(gain.gain, target, now, _musicRamp);

    if (target <= 0.0) {
      _armMusicPause();
      return;
    }

    _musicPauseTimer?.cancel();
    _musicPauseTimer = null;
    _ensureMusicPlaying(el);
  }

  /// The file this browser can actually play, for a station that
  /// declares [declared].
  ///
  /// Which container decodes is a fact about the browser, not about the
  /// station, so the band plan stays in one format and the substitution
  /// happens down here where the codec knowledge already lives. Ogg
  /// Vorbis is what the tracks are mastered to and is a third of the
  /// size; Safari only learned it in 17, and every version before that
  /// answers `canPlayType` with an empty string - which is the whole
  /// signal, available before a single byte is requested.
  ///
  /// The MP3 is a sibling of the same name. A station that has no MP3
  /// sibling 404s on a Safari old enough to need one and lands on the
  /// missing-file path, which is the same carrier-only state the
  /// receiver already handles - see [_deadMusicSrc].
  String _resolveMusicSrc(String declared) {
    if (!declared.endsWith('.ogg')) return declared;
    if (_canPlayOgg ??= _probeOggSupport()) return declared;
    return '${declared.substring(0, declared.length - '.ogg'.length)}.mp3';
  }

  /// Asks the browser once whether Ogg Vorbis is worth attempting.
  bool _probeOggSupport() {
    try {
      // '' is the spec's "no". Both 'maybe' and 'probably' mean try it,
      // and the error handler covers a 'maybe' that turns out to be a no.
      final probe = _musicEl ?? web.HTMLAudioElement();
      return probe.canPlayType('audio/ogg; codecs=vorbis').isNotEmpty;
    } catch (_) {
      // A browser that won't answer the question gets the format that
      // has never needed asking.
      return false;
    }
  }

  /// Points the element at [src], remembering where the outgoing station
  /// was and restoring where the incoming one was left.
  ///
  /// The seek has to wait for `loadedmetadata` - `currentTime` on an
  /// element that has not loaded its header yet is either ignored or
  /// throws, depending on the browser.
  void _swapMusicSrc(String src) {
    if (_loadedMusicSrc == src) return;
    final el = _musicEl;
    if (el == null) return;

    _rememberMusicPosition();
    _detachMusicSeekListener();
    _loadedMusicSrc = src;
    el.src = src;

    final resumeAt = _musicPos[src] ?? 0.0;
    if (resumeAt <= 0.0) return;

    late final JSFunction handler;
    handler = ((web.Event _) {
      try {
        final dur = el.duration;
        // A resume point past the end means the file was replaced by a
        // shorter one since the position was taken. Start over rather
        // than seeking into nothing.
        if (dur.isFinite && resumeAt < dur) el.currentTime = resumeAt;
      } catch (_) {
        // Seeking is a nicety; a track that starts from the top is not
        // a failure worth propagating.
      }
      el.removeEventListener('loadedmetadata', handler);
      if (identical(_musicSeekListener, handler)) _musicSeekListener = null;
    }).toJS;
    _musicSeekListener = handler;
    el.addEventListener('loadedmetadata', handler);
  }

  /// Starts playback, tolerating a browser that refuses.
  ///
  /// The power switch is a real gesture and unlocks the context, which
  /// is normally enough for the document to be allowed to play media.
  /// Where it is not, the rejection is swallowed: every tune event calls
  /// [_applyState] again and every tune event is itself a gesture, so
  /// the retry is the next thing the user does rather than a loop.
  void _ensureMusicPlaying(web.HTMLAudioElement el) {
    if (!el.paused) return;
    try {
      el.play().toDart.catchError((Object _) => null);
    } catch (_) {
      // Synchronous throw on a browser that has no play() promise.
    }
  }

  /// Pauses the element once the fade has finished.
  ///
  /// Pausing on the same frame as the fade starts would cut the music
  /// dead at full level; the delay covers the ramp with slack to spare,
  /// so sweeping across a station and back never stutters.
  void _armMusicPause() {
    final el = _musicEl;
    if (el == null || el.paused) return;
    _musicPauseTimer?.cancel();
    _musicPauseTimer = Timer(_musicPauseDelay, () {
      if (!mounted) return;
      final target = _musicEl;
      if (target == null || target.paused) return;
      _rememberMusicPosition();
      try {
        target.pause();
      } catch (_) {}
    });
  }

  /// Files the current playhead under the track that is loaded.
  void _rememberMusicPosition() {
    final el = _musicEl;
    final src = _loadedMusicSrc;
    if (el == null || src == null) return;
    final t = el.currentTime;
    if (t.isFinite && t > 0) _musicPos[src] = t;
  }

  void _detachMusicSeekListener() {
    final handler = _musicSeekListener;
    if (handler == null) return;
    _musicEl?.removeEventListener('loadedmetadata', handler);
    _musicSeekListener = null;
  }

  // ── helpers ──

  /// Distance from [freq] to the nearest station on [band], in the
  /// band's native unit (MHz for FM, kHz for AM). Used to drive the
  /// heterodyne whistle's frequency + amplitude.
  double _distanceToNearestStation(double freq, Band band) {
    var best = double.infinity;
    for (final s in stationsFor(band)) {
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
  // Invisible - exists only to participate in the component tree so
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
