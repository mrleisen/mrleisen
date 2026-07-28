import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:universal_web/js_interop.dart';
import 'package:universal_web/web.dart' as web;

import 'components/case_study.dart';
import 'components/phosphor_mask.dart';
import 'components/radio_audio.dart';
import 'components/rx_chrome.dart';
import 'components/radio_dial.dart';
import 'components/scanlines.dart';
import 'components/signal_bars.dart';
import 'components/station_display.dart';
import 'components/static_noise.dart';
import 'components/vignette.dart';
import 'models/station.dart';
import 'utils/keyboard.dart';

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
  // to false ~400ms after the last input - the audio engine uses this to
  // fade in/out so we don't drone constantly.
  bool _isTuning = false;
  Timer? _tuningIdleTimer;
  static const Duration _tuningIdleDelay = Duration(milliseconds: 400);

  // Drives the animated sweep when the user taps a saved preset. Held
  // on state so a second tap can cancel the in-flight tween.
  Timer? _recallAnimTimer;
  static const Duration _recallAnimDuration = Duration(milliseconds: 700);

  // Active UI language. Defaults to English.
  Lang _lang = Lang.en;

  // Master volume [0.0 – 1.0]. Controlled by the small volume knob
  // on the left of the faceplate. Starts at 0.36 so the receiver is
  // already on (LED green, gentle static) when the page loads.
  double _volume = 0.36;

  // Radio power state. Starts off - the faceplate is dimmed and the
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

  // Stations the user has explicitly saved via the MEM button, in
  // discovery order. Insertion order is preserved by `LinkedHashSet`
  // (the default `Set<>` factory in Dart), so the rack stays in
  // chronological save order without a second list. Keys are
  // `"<band>:<frequency>"` so FM 96.5 and AM 96.5 wouldn't collide.
  // Persisted to `localStorage` under [_storageKey] so the rack
  // survives page reloads.
  final Set<String> _collectedKeys = <String>{};

  static const String _storageKey = 'rchf:collected_stations';

  // Onboarding cues the visitor has already worked out for themselves.
  // Holds the literals 'power' and 'tune'; persisted comma-joined under
  // [_onboardKey], the same shape as the collected-stations rack.
  //
  // These are one-way and permanent. A hint that comes back on the
  // second visit stops being help and starts being nagging, so once a
  // gesture has been performed the corresponding cue is gone for good.
  final Set<String> _onboarded = <String>{};

  static const String _onboardKey = 'rchf:onboarded';

  // The tune hint waits for the CRT warm-up to finish before appearing,
  // so it lands as the last beat of the power-on sequence instead of
  // fighting the turn-on animation.
  bool _tuneHintArmed = false;
  Timer? _tuneHintTimer;
  static const Duration _tuneHintDelay = Duration(milliseconds: 1200);

  /// The animated pull stays a first-visit cue. Once
  /// you know where the switch is, a permanently pulsing control is just
  /// something twitching in the corner of your eye.
  bool get _showPowerAttract => !_isPowered && !_onboarded.contains('power');

  /// Powered up, warm, and the dial has never been moved.
  bool get _showTuneHint => _isPowered && _tuneHintArmed && !_onboarded.contains('tune');

  // Window-level event listeners (stored for cleanup).
  JSFunction? _keyDownListener;
  JSFunction? _wheelListener;

  // Measured faceplate geometry, in CSS pixels. `_panelH` is how tall the
  // faceplate actually is; `_freeH` is how much room is left above it.
  //
  // Both live in state rather than being written straight to the DOM, and
  // that is load-bearing: they used to be set imperatively with
  // `setAttribute('style', …)` on `.signal-app`, and Jaspr clears the
  // `style` attribute of every element whose component declares no styles
  // on **every** update (`dom_render_object.dart`, `clearOrSetAttribute
  // ('style', null)`). So the measurement survived exactly until the next
  // setState - powering on, tuning, anything - and then silently reverted
  // to the stylesheet fallback. On a phone with saved presets that is a
  // 70 px error, which is why the idle readout sat too low and the bottom
  // of the longest station panel disappeared under the faceplate.
  //
  // Held as state, they are re-emitted on every render, so nothing can
  // wipe them.
  int? _panelH;
  int? _freeH;

  /// Height of the viewport the browser is actually showing, which on a
  /// phone is not the same thing as `100dvh` at every moment. The
  /// long-form printouts size themselves against this: measured against
  /// the layout viewport instead, the bottom of the panel sits below the
  /// browser's own chrome, and the last of the content cannot be scrolled
  /// into view no matter how far you drag.
  int? _viewH;

  // Watches the faceplate so the measurements above stay true.
  web.ResizeObserver? _panelObserver;

  /// Fires on viewport changes. A `ResizeObserver` on the faceplate is not
  /// enough on its own: when a mobile browser shows or hides its URL bar
  /// the panel keeps exactly the same height and simply moves, so the
  /// observer never fires while the space above it changes underneath us.
  JSFunction? _viewportListener;

  // Long-form panels the receiver can print, or null when none is open.
  //
  //   'tech' → how this site was built, opened from WHO
  //   'case' → the DeTodoUIS extended transmission, opened from DTU
  //
  // Both are the same object with different contents, so they share one
  // piece of state, one id, one focus trap and one Escape handler. A
  // second parallel set of all of that is how the two would drift apart.
  String? _openDialog;

  /// Id of the control that opened the current dialog, so focus goes back
  /// to exactly where it came from on close.
  String? _dialogTriggerId;

  /// The station whose panel produced the open printout, so the dialog
  /// can keep reporting on the carrier it came from. The dial stays live
  /// behind these panels by design, which means the signal that produced
  /// one can be tuned away while it is still on screen.
  Station? _dialogStation;

  static const String _techTriggerId = 'tech-trigger';
  static const String _caseTriggerId = 'case-trigger';
  static const String _dialogId = 'rx-dialog';

  /// Which station each printout belongs to. Both pills live inside their
  /// station's panel, so this is the same fact stated where the dialog
  /// code can reach it.
  static const Map<String, String> _dialogOwner = {
    'tech': 'WHO',
    'case': 'DTU',
  };

  @override
  void initState() {
    super.initState();
    _recalc();

    if (kIsWeb) {
      _loadCollectedFromStorage();
      _loadOnboardedFromStorage();

      _keyDownListener = _onKeyDown.toJS;
      web.document.addEventListener('keydown', _keyDownListener);

      _wheelListener = _onWheel.toJS;
      // Must be non-passive to allow preventDefault.
      web.document.addEventListener(
        'wheel',
        _wheelListener,
        web.AddEventListenerOptions(passive: false),
      );

      // Deferred a frame so the faceplate has been laid out and measures
      // its real height rather than zero.
      Timer(Duration.zero, _watchPanelGeometry);
    }
  }

  /// Hydrates `_collectedKeys` from `localStorage`. Unknown keys (e.g.
  /// from a future build with a different station list) are dropped
  /// on read so a stale entry can't render a phantom pill.
  void _loadCollectedFromStorage() {
    try {
      final raw = web.window.localStorage.getItem(_storageKey);
      if (raw == null || raw.isEmpty) return;
      final valid = {
        for (final s in stations) _stationKey(s),
      };
      final loaded = raw.split(',').where(valid.contains);
      if (loaded.isEmpty) return;
      setState(() {
        _collectedKeys.addAll(loaded);
      });
    } catch (_) {
      // localStorage can throw (privacy mode, quota, etc.). A failed
      // read just means we start with an empty rack - not worth
      // surfacing.
    }
  }

  /// Keeps the faceplate measurements in step with reality.
  ///
  /// The content layers centre themselves in the space above the panel,
  /// so they need to know how much space that is. A per-breakpoint
  /// constant gets it wrong the moment anything changes the panel's
  /// height for reasons a media query can't see - the preset rack
  /// appearing when the first station is saved is the obvious one, and
  /// it is enough to push the idle readout underneath the faceplate.
  ///
  /// Measuring is also what makes landscape and rotation work without a
  /// dedicated breakpoint for every device.
  ///
  /// The stylesheet values stay as the pre-hydration fallback; this only
  /// ever refines them.
  void _watchPanelGeometry() {
    if (!kIsWeb) return;
    try {
      final panel = web.document.querySelector('.radio-panel');
      if (panel == null) return;

      _panelObserver = web.ResizeObserver(
        ((JSObject _, JSObject _) {
          _measurePanel();
        }).toJS,
      );
      _panelObserver!.observe(panel);

      _viewportListener = ((web.Event _) => _measurePanel()).toJS;
      web.window.addEventListener('resize', _viewportListener);
      try {
        // The one that actually fires when a mobile URL bar slides away.
        web.window.visualViewport?.addEventListener('resize', _viewportListener);
      } catch (_) {
        // Not everywhere has it; `resize` above is the floor.
      }

      _measurePanel();
    } catch (_) {
      // No ResizeObserver, or the query failed. The CSS fallback still
      // holds, so the layout is merely less precise, never broken.
    }
  }

  /// Reads the faceplate's real box and stores it.
  ///
  /// `rect.top` is the honest answer for the free space above it: the
  /// panel is `position: fixed`, so that number is measured against the
  /// viewport the browser is actually painting, rather than derived from
  /// `100dvh` minus a height, which is the arithmetic that goes wrong the
  /// moment a mobile browser's chrome disagrees with its own unit.
  void _measurePanel() {
    if (!mounted) return;
    final panel = web.document.querySelector('.radio-panel');
    if (panel == null) return;
    final rect = panel.getBoundingClientRect();
    final h = rect.height.round();
    if (h <= 0) return;
    final free = rect.top.round().clamp(0, 100000);
    // `visualViewport` is the only honest answer here: it excludes
    // browser chrome and shrinks for an on-screen keyboard, neither of
    // which `innerHeight` accounts for. It is the fallback, not the
    // preference.
    var view = 0;
    try {
      view = (web.window.visualViewport?.height ?? web.window.innerHeight.toDouble()).round();
    } catch (_) {
      view = web.window.innerHeight;
    }
    // Guarded so a resize that changes nothing can't spin the render loop.
    if (h == _panelH && free == _freeH && view == _viewH) return;
    setState(() {
      _panelH = h;
      _freeH = free;
      if (view > 0) _viewH = view;
    });
  }

  /// Reads which onboarding cues this visitor has already cleared.
  /// Unknown entries are ignored so a future rename can't resurrect a
  /// hint or suppress one that doesn't exist yet.
  void _loadOnboardedFromStorage() {
    try {
      final raw = web.window.localStorage.getItem(_onboardKey);
      if (raw == null || raw.isEmpty) return;
      const known = {'power', 'tune'};
      final loaded = raw.split(',').where(known.contains);
      if (loaded.isEmpty) return;
      setState(() => _onboarded.addAll(loaded));
    } catch (_) {
      // Same reasoning as the collected-stations read: a failed load
      // just means the visitor sees the hints again, which is the safe
      // direction to fail in.
    }
  }

  /// Permanently retires an onboarding cue.
  void _markOnboarded(String cue) {
    if (_onboarded.contains(cue)) return;
    setState(() => _onboarded.add(cue));
    if (!kIsWeb) return;
    try {
      web.window.localStorage.setItem(_onboardKey, _onboarded.join(','));
    } catch (_) {
      // Non-fatal: the hint reappears next visit, nothing breaks.
    }
  }

  void _persistCollected() {
    if (!kIsWeb) return;
    try {
      web.window.localStorage.setItem(_storageKey, _collectedKeys.join(','));
    } catch (_) {
      // Same rationale as the read path - silent failure is the
      // right call for a cosmetic persistence feature.
    }
  }

  @override
  void dispose() {
    _tuningIdleTimer?.cancel();
    _recallAnimTimer?.cancel();
    _crtTimer?.cancel();
    _tuneHintTimer?.cancel();
    if (kIsWeb) {
      web.document.removeEventListener('keydown', _keyDownListener);
      web.document.removeEventListener('wheel', _wheelListener);
      web.window.removeEventListener('resize', _viewportListener);
      try {
        web.window.visualViewport?.removeEventListener('resize', _viewportListener);
      } catch (_) {
        // Symmetry with the guarded add above.
      }
      _panelObserver?.disconnect();
    }
    super.dispose();
  }

  // --- event handlers ---

  /// Document-level shortcuts, so the receiver can be driven from the
  /// keyboard without first tabbing to a specific control.
  ///
  ///   ← / →          tune one step
  ///   Shift + ← / →  tune ten steps
  ///   B              swap band
  ///   M              save the locked station
  ///   1-9            recall the Nth saved preset
  ///
  /// Every shortcut does nothing while the radio is off: silently
  /// tuning, changing band or writing a preset behind a dark screen
  /// would be invisible, and the only meaningful action in that state is
  /// switching it on - which belongs to the focused power control, not
  /// to a global key.
  void _onKeyDown(web.Event event) {
    final ke = event as web.KeyboardEvent;

    // Never swallow a browser or OS shortcut. Ctrl+arrow, Cmd+B and
    // friends belong to the user agent, not to us.
    if (ke.ctrlKey || ke.metaKey || ke.altKey) return;

    // While a printout is up it owns the keyboard: Escape closes it, Tab
    // cycles inside it, and nothing reaches the dial behind it. A modal
    // you can tune through is not a modal.
    if (_openDialog != null) {
      if (ke.key == 'Escape') {
        ke.preventDefault();
        _closeDialog();
      } else if (ke.key == 'Tab') {
        _trapTabInDialog(ke);
      }
      return;
    }

    // Ahead of the arrow branch, not after it: an arrow press with the
    // panel dark used to retune behind the opaque CRT overlay and -
    // via `_tune` - retire the tune hint before it had ever been shown.
    if (!_isPowered) return;

    final step = configFor(_band).step;

    if (ke.key == 'ArrowRight' || ke.key == 'ArrowLeft') {
      ke.preventDefault();
      // Shift jumps a decade, which makes crossing an empty stretch of
      // band bearable: AM spans 116 steps end to end.
      final magnitude = step * (ke.shiftKey ? 10 : 1);
      _tune(_frequency + (ke.key == 'ArrowRight' ? magnitude : -magnitude));
      return;
    }

    switch (ke.key.toLowerCase()) {
      case 'b':
        ke.preventDefault();
        _selectBand(_band == Band.fm ? Band.am : Band.fm);
        return;
      case 'm':
        ke.preventDefault();
        _saveCurrentStation();
        return;
    }

    // Digit presets are 1-indexed over the rack in discovery order.
    final digit = int.tryParse(ke.key);
    if (digit != null && digit >= 1 && digit <= 9) {
      final rack = _collectedStations;
      if (digit <= rack.length) {
        ke.preventDefault();
        _recallStation(rack[digit - 1]);
      }
    }
  }

  void _onWheel(web.Event event) {
    // Same rule as the keyboard shortcuts: wheel-to-tune is a
    // powered-on affordance. Without this guard a scroll before the
    // power switch was found retuned invisibly and retired the tune
    // hint for good.
    if (!_isPowered) return;
    // Only handle wheel at document level when NOT over the radio panel
    // (the panel has its own wheel handler that calls preventDefault).
    final we = event as web.WheelEvent;
    // Check if the event target is inside .radio-panel.
    final target = we.target;
    if (target.isA<web.Element>()) {
      final el = target as web.Element;
      if (el.closest('.radio-panel') != null) return; // handled by panel
      // Anything the user can actually scroll keeps its wheel. This
      // handler calls preventDefault unconditionally, which meant a wheel
      // over the technical transmission or over a station panel taller
      // than the screen tuned the dial *and* swallowed the scroll, so the
      // long printouts could not be read with a mouse at all.
      if (_scrollableUnder(el) != null) return;
    }
    we.preventDefault();
    final step = configFor(_band).step;
    final delta = we.deltaY > 0 ? step * 2 : -step * 2;
    _tune(_frequency + delta);
  }

  /// The nearest ancestor of [el] that has content to scroll, or null.
  ///
  /// Checked live rather than by class alone: a station panel is only a
  /// scroll container when its content actually overflows, and on a
  /// desktop viewport most of them never do. Blanket-exempting the whole
  /// panel area would quietly kill wheel-to-tune across the middle of the
  /// screen, which is where people reach for it.
  web.Element? _scrollableUnder(web.Element el) {
    for (final sel in const ['.rx-panel', '.station-panel']) {
      final found = el.closest(sel);
      if (found != null && found.scrollHeight > found.clientHeight) return found;
    }
    return null;
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
    // changed - clicking the dial without moving still counts as
    // interaction and should wake the audio engine.
    _markTuning();

    if (newFreq == _frequency) return;

    // The dial actually moved, so the visitor has worked out the core
    // gesture. Retire the tune hint for good. Guarded on a real change
    // rather than on `_markTuning`, which also fires for a click that
    // goes nowhere - and on power, so a programmatic or stray tune with
    // the panel dark can never spend the hint unseen.
    if (_isPowered) _markOnboarded('tune');

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

  /// Adds the currently-locked station to the collected set. No-op
  /// when not locked or already saved. Auto-collection on lock was
  /// rejected as a design - sweeping the dial would silently scoop
  /// every station, robbing the act of "finding" anything; the user
  /// has to press the MEM button to commit a station to the rack.
  void _saveCurrentStation() {
    if (!_isPowered) return;
    final s = _activeStation;
    if (s == null) return;
    final key = _stationKey(s);
    if (_collectedKeys.contains(key)) return;
    setState(() => _collectedKeys.add(key));
    _persistCollected();
  }

  /// Removes a station from the collected rack - the press-and-hold
  /// gesture in [CollectedStations] commits this. Persists immediately
  /// so the deletion survives a refresh, mirroring the save path.
  void _deleteStation(Station s) {
    final key = _stationKey(s);
    if (!_collectedKeys.contains(key)) return;
    setState(() => _collectedKeys.remove(key));
    _persistCollected();
  }

  /// True when the dial is locked onto a station that has not yet
  /// been saved - the only state in which the MEM button is armed.
  bool get _canSaveCurrent {
    final s = _activeStation;
    return _isPowered && s != null && !_collectedKeys.contains(_stationKey(s));
  }

  String _stationKey(Station s) => '${s.band.name}:${s.frequency}';

  /// Stations the user has discovered, in the order they first locked
  /// onto each one. Built fresh every render - cheap given there are
  /// only a handful of stations total.
  List<Station> get _collectedStations => [
    for (final s in stations)
      if (_collectedKeys.contains(_stationKey(s))) s,
  ];

  /// Tap-to-recall: sweep the dial from the current frequency to a
  /// previously-found station. Switches bands first if needed, then
  /// tweens the active frequency over [_recallAnimDuration] with an
  /// ease-out cubic so the dial decelerates into the target. Each tick
  /// goes through `_tune`, so the audio engine reacts as the sweep
  /// passes adjacent stations - same heterodyne whistle and crossfade
  /// the user gets when sweeping by hand.
  void _recallStation(Station s) {
    if (!_isPowered) return;

    // Cancel any in-flight recall sweep so a fresh tap immediately
    // retargets instead of fighting the previous animation.
    _recallAnimTimer?.cancel();
    _recallAnimTimer = null;

    // Band switch happens up front so the sweep starts from whatever
    // frequency was last parked in the target band, not the current one.
    if (_band != s.band) {
      setState(() {
        _band = s.band;
        _recalc();
      });
    }

    if (_frequency == s.frequency) {
      _markTuning();
      return;
    }

    final startFreq = _frequency;
    final targetFreq = s.frequency;
    final startMs = DateTime.now().millisecondsSinceEpoch;
    final totalMs = _recallAnimDuration.inMilliseconds;

    _recallAnimTimer = Timer.periodic(const Duration(milliseconds: 16), (timer) {
      final elapsed = DateTime.now().millisecondsSinceEpoch - startMs;
      final t = (elapsed / totalMs).clamp(0.0, 1.0);
      // Ease-out cubic: 1 - (1 - t)^3
      final inv = 1.0 - t;
      final eased = 1.0 - inv * inv * inv;
      final freq = startFreq + (targetFreq - startFreq) * eased;

      if (t >= 1.0) {
        timer.cancel();
        _recallAnimTimer = null;
        _tune(targetFreq); // snap to clean clamped/rounded target
      } else {
        _tune(freq);
      }
    });
  }

  /// Switches the active band to [band]. No-op when the radio is off
  /// or already on that band. Cancels any in-flight recall sweep so a
  /// preset animation doesn't keep tweening into a band the user just
  /// left.
  void _selectBand(Band band) {
    if (!_isPowered) return;
    if (_band == band) return;
    _recallAnimTimer?.cancel();
    _recallAnimTimer = null;
    setState(() {
      _band = band;
      _recalc();
    });
    // Mark as tuning so the audio engine produces a short static burst
    // while the dial rearranges.
    _markTuning();
  }

  // --- document metadata ---

  /// The single `<h1>` for the document, translated with the UI.
  ///
  /// Deliberately not the station panel titles: six of those are in the
  /// DOM at once (hidden ones sit at `visibility: hidden` so switching
  /// stations never reflows), so promoting them would emit six competing
  /// headings. They stay `<h2>`, nested under this.
  String get _pageHeading =>
      _lang == Lang.es ? 'Rafael Camargo - Ingeniero de Software' : 'Rafael Camargo - Software Engineer';

  /// Tab title. Falls back to the identity line whenever the dial isn't
  /// sitting on a station, so a bookmark taken from dead air still says
  /// something useful.
  String get _documentTitle {
    final s = _activeStation;
    if (!_isPowered || s == null) return _pageHeading;
    final unit = s.band == Band.fm ? 'MHz' : 'kHz';
    final freq = s.band == Band.fm ? s.frequency.toStringAsFixed(1) : s.frequency.toInt().toString();
    return '${s.band.name.toUpperCase()} $freq $unit ${s.callSign} '
        '- Rafael Camargo';
  }

  /// Frequency formatted for reading aloud: "97.7 MHz" / "1120 kHz".
  String _spokenFrequency(double freq, Band band) {
    final unit = band == Band.fm ? 'MHz' : 'kHz';
    final value = band == Band.fm ? freq.toStringAsFixed(1) : freq.toInt().toString();
    return '${band.name.toUpperCase()} $value $unit';
  }

  /// Sentence pushed to the live region on every state change.
  ///
  /// Deliberately reports the same three things the visual design does -
  /// where the dial is, whether anything is locked, and whether a signal
  /// is nearby - so a screen-reader user is told what a sighted user can
  /// see, not a different and thinner story.
  String get _liveStatus {
    final es = _lang == Lang.es;
    if (!_isPowered) return es ? 'Radio apagada' : 'Radio off';

    final freq = _spokenFrequency(_frequency, _band);
    final active = _activeStation;
    if (active != null) {
      return es
          ? '$freq. Sintonizada: ${active.callSign}. Señal completa.'
          : '$freq. Locked on ${active.callSign}. Full signal.';
    }

    final near = _nearestStation;
    if (near != null) {
      final pct = (_signalStrength * 100).round();
      return es
          ? '$freq. Sin sintonizar. ${near.callSign} cerca, señal $pct por ciento.'
          : '$freq. Not locked. ${near.callSign} nearby, signal $pct percent.';
    }
    return es ? '$freq. Sin portadora.' : '$freq. No carrier.';
  }

  /// How the station that produced the open printout is currently coming
  /// in, on exactly the curve the station panels use.
  ///
  /// A printout is something the receiver decoded. Leaving one pristine
  /// while its carrier drifts away is the receiver claiming to still be
  /// decoding something it lost, which is the one thing this piece cannot
  /// afford to be caught doing.
  RxSignalState get _dialogSignalState {
    final st = _dialogStation;
    if (st == null) {
      return const RxSignalState(signal: 1.0, powered: true, frequencyLabel: '');
    }
    final label = _spokenFrequency(st.frequency, st.band);
    double signal;
    if (!_isPowered || st.band != _band) {
      // A different band is not a weak signal, it is a different aerial.
      signal = 0.0;
    } else {
      final cfg = configFor(st.band);
      final d = (_frequency - st.frequency).abs();
      if (d <= cfg.lockRange) {
        signal = 1.0;
      } else if (d >= cfg.tolerance) {
        signal = 0.0;
      } else {
        signal = 1.0 - (d - cfg.lockRange) / (cfg.tolerance - cfg.lockRange);
      }
    }
    return RxSignalState(
      signal: signal,
      powered: _isPowered,
      frequencyLabel: label,
      onRetune: _isPowered ? () => _recallStation(st) : null,
    );
  }

  /// The "how this was built" panel, in the receiver's own language.
  ///
  /// Everything stated here is measured from the actual build, not
  /// claimed from memory: the bundle figures come from `build/jaspr`,
  /// and the "no images, no canvas" line is verifiable by reading the
  /// compiled HTML.
  Component _techDialog() {
    final es = _lang == Lang.es;
    final rows = <(String, String)>[
      (es ? 'LENGUAJE' : 'LANGUAGE', 'Dart 3.10+'),
      (
        es ? 'FRAMEWORK' : 'FRAMEWORK',
        es ? 'Jaspr · SSR + hidratación' : 'Jaspr · SSR + hydration',
      ),
      (es ? 'AUDIO' : 'AUDIO', 'Web Audio API'),
      (
        es ? 'SÍNTESIS' : 'SYNTHESIS',
        es ? 'Ruido disperso x2 + oscilador heterodino' : 'Two sparse-noise paths + heterodyne oscillator',
      ),
      (
        es ? 'VISUALES' : 'VISUALS',
        es ? 'CSS puro · sin canvas, sin WebGL' : 'Pure CSS · no canvas, no WebGL',
      ),
      (
        es ? 'IMÁGENES' : 'IMAGES',
        es ? 'Ninguna en la interfaz' : 'None in the interface',
      ),
      (
        es ? 'DEPS JS' : 'JS DEPS',
        es ? 'Cero en runtime' : 'Zero at runtime',
      ),
      // Re-measure these against build/jaspr whenever the bundle moves;
      // they drifted once already when a font was added, and once more
      // when the figure quoted main.client.dart.js alone - dart2js also
      // emits a deferred `*.part.js` holding the whole app, and the
      // loader fetches it on every visit, so both files count.
      //   cat build/jaspr/*.js | wc -c        -> raw
      //   cat build/jaspr/*.js | gzip -9 | wc -c -> gzip
      //   du -ch build/jaspr/fonts/*.woff2    -> fonts
      (es ? 'JAVASCRIPT' : 'JAVASCRIPT', '231 KB · 77 KB gzip'),
      (
        es ? 'TIPOGRAFÍAS' : 'TYPEFACES',
        es ? '72 KB · 4 familias, subset latino' : '72 KB · 4 families, latin subset',
      ),
      (
        es ? 'DESPLIEGUE' : 'DEPLOY',
        es ? 'Estático · GitHub Pages' : 'Static · GitHub Pages',
      ),
    ];

    final intro = es
        ? 'Todo lo que oyes se sintetiza en el momento: no hay un solo '
              'archivo de audio. La estática son dos rutas de ruido disperso '
              'y el silbido al pasar cerca de una emisora es un oscilador '
              'cuya frecuencia es la distancia a la estación. Todo lo que '
              'ves es CSS: el fósforo, las líneas de barrido, el encendido '
              'del tubo. No hay imágenes ni canvas en la interfaz.'
        : 'Everything you hear is synthesised on the spot: there is not a '
              'single audio file. The static is two sparse-noise paths, and '
              'the whistle near a station is an oscillator whose frequency '
              'is the distance to it. Everything you see is CSS: the '
              'phosphor, the scanlines, the tube warming up. No images and '
              'no canvas anywhere in the interface.';

    final outro = es
        ? 'Escrito entero en Dart y compilado a HTML estático con Jaspr. '
              'El servidor prerenderiza, el cliente hidrata, y no se envía '
              'ningún framework al navegador.'
        : 'Written entirely in Dart and compiled to static HTML with '
              'Jaspr. The server prerenders, the client hydrates, and no '
              'framework ships to the browser.';

    final sig = _dialogSignalState;
    return div(
      classes: 'rx-overlay',
      events: {
        // Backdrop press closes. Guarded on the target being the
        // backdrop itself so a press inside the panel doesn't dismiss it.
        'click': (web.Event e) {
          final t = e.target;
          if (t.isA<web.Element>() && (t as web.Element).classList.contains('rx-overlay')) {
            _closeDialog();
          }
        },
      },
      [
        div(
          classes: 'rx-panel${sig.panelClass}',
          styles: Styles(raw: {'--distortion': sig.distortion.toStringAsFixed(3)}),
          attributes: {
            'id': _dialogId,
            'role': 'dialog',
            'aria-modal': 'true',
            'aria-labelledby': 'tech-title',
            'tabindex': '-1',
          },
          [
            rxHead(
              label: es ? 'TRANSMISIÓN TÉCNICA' : 'TECHNICAL TRANSMISSION',
              lang: _lang,
              state: sig,
              onClose: _closeDialog,
            ),
            if (sig.lost) rxLostPlate(lang: _lang, state: sig),
            h2(classes: 'rx-title', id: 'tech-title', [
              Component.text(es ? 'Cómo está hecho' : 'How this was built'),
            ]),
            p(classes: 'rx-body', [Component.text(intro)]),
            div(classes: 'rx-data', [
              for (final (k, v) in rows) ...[
                div(classes: 'rx-key', [Component.text(k)]),
                div(classes: 'rx-val', [Component.text(v)]),
              ],
            ]),
            p(classes: 'rx-body', [Component.text(outro)]),
            rxHint(_lang),
          ],
        ),
      ],
    );
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
    final nearestDist = _nearestStation != null ? (_frequency - _nearestStation!.frequency).abs() : double.infinity;
    final handoff = cfg.tolerance * 0.7;
    final distanceOpacity = nearestDist >= cfg.tolerance
        ? 1.0
        : ((nearestDist - handoff) / (cfg.tolerance - handoff)).clamp(0.0, 1.0);
    // Power gates every upper layer - when off, the CRT overlay is
    // opaque black anyway, but we also zero out content opacity so
    // nothing animates or allocates behind the overlay.
    final contentOpacity = _isPowered ? distanceOpacity : 0.0;

    // Idle readout copy. The receiver is "searching" when between
    // stations; the dash pattern and band range both key off the
    // active band so AM and FM show different ranges/units.
    final bandLabel = _band == Band.fm ? 'FM' : 'AM';
    final unitLabel = _band == Band.fm ? 'MHZ' : 'KHZ';
    final minLabel = _band == Band.fm ? cfg.minFreq.toStringAsFixed(1) : cfg.minFreq.toInt().toString();
    final maxLabel = _band == Band.fm ? cfg.maxFreq.toStringAsFixed(1) : cfg.maxFreq.toInt().toString();
    final idleTop = _lang == Lang.es ? 'SIN PORTADORA' : 'NO CARRIER';
    final idleSub = _lang == Lang.es ? 'BARRIENDO BANDA' : 'SCANNING BAND';

    // Standby poster. The lamp stands on the dial line at the frequency
    // the readout underneath it claims, so its position is a fact about
    // the receiver rather than a composition choice - park on 108.0 and
    // it sits at the right-hand end of the line.
    final sbPos = ((_frequency - cfg.minFreq) / (cfg.maxFreq - cfg.minFreq) * 100).clamp(0.0, 100.0);
    final sbFreq = _band == Band.fm ? _frequency.toStringAsFixed(1) : _frequency.toInt().toString();
    final sbState = _lang == Lang.es ? 'EN ESPERA' : 'STANDBY';
    final sbPress = _lang == Lang.es ? 'ENCIENDE' : 'PRESS ON';

    final rootClass = 'signal-app ${_isPowered ? 'powered-on' : 'powered-off'}';
    final crtClass = switch (_crtPhase) {
      'turning-on' => 'crt-screen crt-animate-on',
      'on' => 'crt-screen crt-on-done',
      'turning-off' => 'crt-screen crt-animate-off',
      _ => 'crt-screen',
    };

    return div(
      classes: rootClass,
      // Re-emitted every render on purpose. See the note on [_panelH].
      styles: Styles(
        raw: {
          if (_panelH != null) '--panel-h': '${_panelH}px',
          if (_freeH != null) '--free-h': '${_freeH}px',
          if (_viewH != null) '--vh': '${_viewH}px',
        },
      ),
      [
        // Keeps <html lang> honest as the user flips ES/EN. Without it a
        // screen reader keeps reading Spanish copy with an English voice,
        // which ranges from comic to unintelligible.
        Document.html(attributes: {'lang': _lang == Lang.es ? 'es' : 'en'}),

        // The tab title follows the dial. Idle it stays the identity line
        // that the server rendered; locked onto a station it reports what
        // the receiver is actually carrying, the way a tuner's display
        // would. Only the SSR title matters for crawlers, so this is pure
        // flourish and can't hurt indexing.
        Document.head(title: _documentTitle),

        // The document needs exactly one h1, and this page has no visible
        // prose to promote - the "hero" is a faceplate. So the heading is
        // real, translated and screen-reader visible, but clipped out of
        // the visual layout rather than styled to look like nothing.
        h1(classes: 'visually-hidden', [Component.text(_pageHeading)]),

        // Live readout of what the receiver is doing.
        //
        // Every signal this piece gives about the dial is visual or
        // audible: the LCD digits, the needle, the signal bars, the static
        // clearing. None of it reaches a screen reader, which left the
        // radio impossible to operate without sight - you could move the
        // dial and get no feedback that anything had changed.
        //
        // `polite` rather than `assertive`: tuning fires this constantly
        // while sweeping, and an assertive region would interrupt itself
        // into noise. `aria-atomic` so the whole sentence is re-read
        // rather than just the digits that changed.
        div(
          classes: 'visually-hidden',
          attributes: {
            'role': 'status',
            'aria-live': 'polite',
            'aria-atomic': 'true',
          },
          [Component.text(_liveStatus)],
        ),

        // Keyboard shortcuts, announced when focus lands on the dial via
        // `aria-describedby`. They exist as document-level handlers, so
        // without this they would be undiscoverable to exactly the people
        // who most need them.
        div(classes: 'visually-hidden', id: 'dial-instructions', [
          Component.text(
            _lang == Lang.es
                ? 'Usa las flechas izquierda y derecha para sintonizar. '
                      'Mayúsculas con las flechas salta diez pasos. '
                      'B cambia de banda. M guarda la estación sintonizada. '
                      'Las teclas 1 a 9 recuperan una emisora guardada.'
                : 'Use the left and right arrow keys to tune. '
                      'Hold shift with the arrows to jump ten steps. '
                      'Press B to switch band. Press M to save the locked '
                      'station. Press 1 to 9 to recall a saved station.',
          ),
        ]),

        // Audio engine (renders no visible DOM).
        RadioAudio(
          frequency: _frequency,
          band: _band,
          noiseLevel: _noiseLevel,
          isTuning: _isTuning,
          volume: _volume,
          isPowered: _isPowered,
        ),

        // CRT power-on/off overlay - fills the viewport under all
        // content layers but above the root background. Opaque black
        // when off, transparent when on, plays clip-path flash on
        // transitions.
        div(classes: crtClass, []),

        // ── standby poster ──
        // What the piece looks like before anyone has touched it, which
        // for most visitors is the only frame they will ever judge it on.
        // A dark screen with a faceplate parked at the bottom edge reads
        // as a page that hasn't finished loading; the same screen with
        // the receiver's housing rising out of that faceplate, one lamp
        // lit and a dial line holding the empty half of the frame, reads
        // as hardware in standby. Same amount of black, deliberate
        // instead of accidental.
        //
        // Gated on `_crtPhase`, not on `_isPowered`: powering off runs a
        // white flash across the whole screen at z-index 5, and this
        // layer sits above it at 8. Waiting for the tube to finish
        // collapsing is also simply the truth - the poster is what is
        // there once the screen is dark and settled, so it fades in as
        // the last beat of switching off rather than glowing through the
        // flash.
        //
        // Decorative throughout: the live region already announces "radio
        // off", and the power switch carries its own name and state, so
        // every string here is a second telling of something assistive
        // tech has been given properly.
        div(
          classes: 'standby${_crtPhase == 'off' ? '' : ' standby-out'}',
          attributes: {'aria-hidden': 'true'},
          [
            // The housing. Bottomless and anchored to the top of the
            // faceplate, so the panel reads as the front of an object
            // that continues upward rather than as a bar stuck to the
            // bottom of the window.
            div(classes: 'sb-body', []),
            // The dial, reduced to the one horizontal that organises the
            // empty space - the same line the real dial window draws,
            // seen unlit.
            div(classes: 'sb-rule', [
              span(classes: 'sb-ticks', []),
              span(
                classes: 'sb-led',
                styles: Styles(raw: {'left': '${sbPos.toStringAsFixed(1)}%'}),
                [],
              ),
            ]),
            // Model, state, frequency. Instrument microtype, set in the
            // face the hardware already prints its lettering in.
            div(classes: 'sb-data', [
              span(classes: 'sb-mark', [Component.text('RCHF')]),
              span(classes: 'sb-sep', []),
              span(classes: 'sb-state', [Component.text(sbState)]),
              span(classes: 'sb-sep', []),
              span(classes: 'sb-freq', [Component.text(sbFreq)]),
            ]),
            // The only instruction on the page. It used to be silkscreen
            // beside the rocker; it is now the closing line of the
            // composition, which is where the eye already is.
            div(classes: 'sb-press', [Component.text(sbPress)]),
          ],
        ),

        // Effect overlays (order = paint order; z-index is the real
        // stacking order - noise → vignette → phosphor → scanlines).
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
          events: {
            'click': (_) => _toggleLang(),
            'keydown': onActivateKey((_) => _toggleLang()),
          },
          attributes: {
            'role': 'button',
            'tabindex': '0',
            // Names the action *and opens with the visible glyph*. A bare
            // "ES"/"EN" says nothing about what pressing it does, but a
            // name that omits the visible text breaks WCAG 2.5.3: someone
            // driving by voice says what they can see, so "EN" has to be
            // in the name for "click EN" to reach this.
            'aria-label': _lang == Lang.es ? 'ES - cambiar idioma a inglés' : 'EN - switch language to Spanish',
          },
          [Component.text(_lang == Lang.es ? 'ES' : 'EN')],
        ),

        // Idle readout - what a real receiver shows when the dial is
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
              // noise present - a calm, locked-in dial keeps the frame
              // perfectly still.
              'animation': (_isPowered && _noiseLevel > 0.3) ? 'content-jitter 0.22s steps(2, end) infinite' : 'none',
            },
          ),
          [
            // Large dash array - the "missing call-sign" glyph. Five
            // en-dashes with thin-space separators drift slightly so
            // the readout feels alive rather than printed.
            div(
              classes: 'carrier-dashes',
              attributes: {'aria-hidden': 'true'},
              [
                for (var i = 0; i < 5; i++)
                  span(
                    classes: 'carrier-dash',
                    styles: Styles(
                      raw: {
                        'animation-delay': '${(i * 0.18).toStringAsFixed(2)}s',
                      },
                    ),
                    [Component.text('–')],
                  ),
              ],
            ),
            // Primary state line - tracked uppercase, station-style
            // teletype aesthetic.
            div(classes: 'carrier-state', [
              span(classes: 'carrier-dot', []),
              span(classes: 'carrier-state-text', [Component.text(idleTop)]),
              span(classes: 'carrier-dot', []),
            ]),
            // Band + range. The tick-bracket on either side is just
            // text ("[") but the centered ribbon below carries the
            // live search sweep.
            div(classes: 'carrier-band', [
              span(classes: 'carrier-band-band', [Component.text(bandLabel)]),
              span(classes: 'carrier-band-sep', [Component.text('·')]),
              span(classes: 'carrier-band-range', [Component.text('$minLabel – $maxLabel')]),
              span(classes: 'carrier-band-sep', [Component.text('·')]),
              span(classes: 'carrier-band-unit', [Component.text(unitLabel)]),
            ]),
            // Sweep ribbon - a thin horizontal bar under the range
            // with a single brighter tracer that runs left→right.
            div(classes: 'carrier-sweep', [
              div(classes: 'carrier-sweep-track', []),
              div(classes: 'carrier-sweep-head', []),
            ]),
            // Sub-caption - small, tracked, breathing opacity.
            div(classes: 'carrier-sub', [Component.text(idleSub)]),
          ],
        ),

        // Decoded station content - fades in with distortion across the
        // band's tolerance window, then locks cleanly inside its lockRange.
        StationDisplay(
          frequency: _frequency,
          band: _band,
          lang: _lang,
          isPowered: _isPowered,
          onOpenTech: () => _openDialogFor('tech', _techTriggerId),
          techTriggerId: _techTriggerId,
          onOpenCase: () => _openDialogFor('case', _caseTriggerId),
          caseTriggerId: _caseTriggerId,
        ),

        // Long-form printouts. They sit above every content layer but below
        // the faceplate, so the receiver stays visible around them - each
        // panel reads as something the radio decoded, not as a web modal
        // that took over the page.
        if (_openDialog == 'tech') _techDialog(),
        if (_openDialog == 'case')
          CaseStudyDialog(
            lang: _lang,
            dialogId: _dialogId,
            onClose: _closeDialog,
            signal: _dialogSignalState,
          ),

        // Radio dial. The collected-stations row is rendered inside
        // the faceplate (between header and main row), so its data is
        // threaded through here rather than mounted as a sibling.
        RadioDial(
          frequency: _frequency,
          band: _band,
          onFrequencyChanged: _tune,
          onBandSelect: _selectBand,
          signalStrength: _signalStrength,
          activeStation: _activeStation,
          volume: _volume,
          onVolumeChanged: _setVolume,
          isPowered: _isPowered,
          onPowerToggle: _togglePower,
          collectedStations: _collectedStations,
          onRecallStation: _recallStation,
          onDeleteStation: _deleteStation,
          canSaveCurrent: _canSaveCurrent,
          onSaveStation: _saveCurrentStation,
          lang: _lang,
          showPowerAttract: _showPowerAttract,
          showTuneHint: _showTuneHint,
        ),
      ],
    );
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

  // --- technical transmission dialog ---

  /// Keeps Tab inside the open dialog, wrapping at both ends.
  ///
  /// Without this, tabbing out of a dialog that visually covers the page
  /// lands focus on controls the user cannot see and did not mean to
  /// reach - which is worse than no keyboard support, because it looks
  /// like the page has broken.
  void _trapTabInDialog(web.KeyboardEvent ke) {
    final dialog = web.document.querySelector('#$_dialogId');
    if (dialog == null) return;
    final nodes = dialog.querySelectorAll(
      'a[href], button, [tabindex]:not([tabindex="-1"])',
    );
    final items = <web.HTMLElement>[
      for (var i = 0; i < nodes.length; i++)
        if (nodes.item(i) case final web.HTMLElement el) el,
    ];
    if (items.isEmpty) return;

    final first = items.first;
    final last = items.last;
    final active = web.document.activeElement;

    if (ke.shiftKey && (active == first || active == dialog)) {
      ke.preventDefault();
      last.focus();
    } else if (!ke.shiftKey && active == last) {
      ke.preventDefault();
      first.focus();
    }
  }

  /// Opens one of the long-form printouts and remembers which control
  /// asked for it.
  void _openDialogFor(String kind, String triggerId) {
    if (_openDialog != null) return;
    final owner = _dialogOwner[kind];
    setState(() {
      _openDialog = kind;
      _dialogTriggerId = triggerId;
      _dialogStation = owner == null ? null : stations.where((st) => st.callSign == owner).firstOrNull;
    });
    if (!kIsWeb) return;
    // Move focus into the dialog once it exists, otherwise a keyboard
    // user opens a panel and their focus stays behind it on the page.
    Timer(Duration.zero, () {
      if (!mounted) return;
      final el = web.document.querySelector('#$_dialogId');
      if (el.isA<web.HTMLElement>()) (el as web.HTMLElement).focus();
    });
  }

  void _closeDialog() {
    if (_openDialog == null) return;
    final trigger = _dialogTriggerId;
    setState(() {
      _openDialog = null;
      _dialogTriggerId = null;
      _dialogStation = null;
    });
    if (!kIsWeb || trigger == null) return;
    // Hand focus back to the control that opened it. Dropping focus to
    // the top of the document instead would make a keyboard user tab
    // all the way back to where they were.
    Timer(Duration.zero, () {
      if (!mounted) return;
      final el = web.document.querySelector('#$trigger');
      if (el.isA<web.HTMLElement>()) (el as web.HTMLElement).focus();
    });
  }

  void _togglePower() {
    _crtTimer?.cancel();
    _tuneHintTimer?.cancel();
    final powering = !_isPowered;

    if (powering) {
      // They found the switch. That cue has done its job.
      _markOnboarded('power');
    }

    setState(() {
      _isPowered = powering;
      _crtPhase = powering ? 'turning-on' : 'turning-off';
      // Any armed tune hint belongs to the session that is ending.
      if (!powering) _tuneHintArmed = false;
    });

    final dur = powering ? _crtOnDuration : _crtOffDuration;
    _crtTimer = Timer(dur, () {
      if (!mounted) return;
      setState(() => _crtPhase = _isPowered ? 'on' : 'off');
    });

    // Hold the tune hint back until the CRT has finished warming up, so
    // it arrives as the closing beat of the power-on sequence rather
    // than competing with it.
    if (powering && !_onboarded.contains('tune')) {
      _tuneHintTimer = Timer(_tuneHintDelay, () {
        if (!mounted || !_isPowered) return;
        setState(() => _tuneHintArmed = true);
      });
    }
  }

  @css
  static List<StyleRule> get styles => [
    // Removes an element from the visual layout while leaving it in the
    // accessibility tree. `display: none` and `visibility: hidden` would
    // both hide it from screen readers too, which defeats the point of
    // having a heading at all.
    css('.visually-hidden').styles(
      position: Position.absolute(),
      width: 1.px,
      height: 1.px,
      padding: Padding.all(Unit.zero),
      margin: Margin.all((-1).px),
      overflow: Overflow.hidden,
      raw: {
        'clip': 'rect(0, 0, 0, 0)',
        'clip-path': 'inset(50%)',
        'white-space': 'nowrap',
        'border': '0',
      },
    ),
    css('.signal-app').styles(
      position: Position.relative(),
      width: 100.percent,
      height: 100.vh,
      overflow: Overflow.hidden,
      backgroundColor: const Color('#050507'),
      raw: {
        // Height of the faceplate, published so the content layers can
        // centre themselves in whatever space is left above it.
        //
        // This used to be a hand-tuned magic number repeated in two
        // files (`calc(50% - 100px)` on desktop, `calc(50% - 90px)` on
        // mobile), which meant every change to the panel's height
        // silently drifted the content off-centre or pushed it under the
        // panel. One value, one place, and the arithmetic follows.
        '--panel-h': '210px',
        // Room left above the faceplate. This declaration and the `dvh`
        // one below are only the pre-hydration fallback: once `AppState`
        // has measured the panel it overrides both inline, with numbers
        // taken from the box the browser is really painting rather than
        // from a unit that disagrees with the browser's own chrome on
        // mobile.
        '--free-h': 'calc(100vh - var(--panel-h))',
      },
    ),
    css('.signal-app').styles(
      raw: {
        'height': '100dvh',
        '--free-h': 'calc(100dvh - var(--panel-h))',
      },
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
        opacity: 1,
        pointerEvents: PointerEvents.auto,
        backgroundColor: const Color('#000000'),
      ),
      css('&.crt-animate-on').styles(
        raw: {
          'animation': 'crt-on 0.8s ease-out forwards',
        },
      ),
      css('&.crt-animate-off').styles(
        raw: {
          'animation': 'crt-off 0.5s ease-in forwards',
        },
      ),
      css('&.crt-on-done').styles(
        opacity: 0,
        pointerEvents: PointerEvents.none,
        raw: {'background': 'transparent'},
      ),
    ]),
    // Scanlines + vignette opacity gated on the root power class.
    // They have no opacity prop so we drive them purely from CSS.
    css('.signal-app .scanlines, .signal-app .vignette').styles(
      raw: {
        'transition': 'opacity 0.3s ease',
      },
    ),
    css(
      '.signal-app.powered-off .scanlines, '
      '.signal-app.powered-off .vignette',
    ).styles(
      raw: {
        'opacity': '0',
      },
    ),
    // ── standby poster ──
    // Above the black CRT plate (z 5) and below the faceplate (z 50), so
    // the housing this draws meets the real panel's top edge instead of
    // covering it. Everything is measured off `--panel-h` and `--free-h`,
    // the same two numbers `AppState` measures for the content layers -
    // the composition follows the faceplate wherever it ends up rather
    // than being pinned to a viewport fraction.
    css('.standby').styles(
      position: Position.absolute(
        top: Unit.zero,
        left: Unit.zero,
        right: Unit.zero,
        bottom: Unit.zero,
      ),
      zIndex: ZIndex(8),
      pointerEvents: PointerEvents.none,
      raw: {'transition': 'opacity 0.45s ease'},
    ),
    css('.standby-out').styles(opacity: 0),

    // The housing. Deliberately bottomless and tucked 1px under the
    // panel's own top border, so there is no seam between the drawn
    // silhouette and the real hardware below it - they are one object.
    css('.sb-body').styles(
      position: Position.absolute(
        bottom: Unit.expression('calc(var(--panel-h) - 1px)'),
        left: 50.percent,
      ),
      width: Unit.expression('min(720px, 60%)'),
      height: Unit.expression('calc(var(--free-h) * 0.7)'),
      raw: {
        // Same lamp as the faceplate: up and to the left, falling off
        // fast. The hairline edge is what actually draws the silhouette;
        // the gradients only stop the inside from reading as a hole.
        'border': '1px solid rgba(255,255,255,0.05)',
        'border-bottom': '0',
        'border-radius': '5px 5px 0 0',
        'background':
            'radial-gradient(100% 120% at 16% -12%, rgba(255,255,255,0.032), transparent 62%),'
            'linear-gradient(180deg, rgba(255,255,255,0.012), rgba(255,255,255,0) 58%)',
        'translate': '-50% 0',
      },
    ),

    // ── the dial, unlit ──
    // One horizontal line through the empty half of the frame. It is the
    // same object as the dial window on the faceplate, drawn as the
    // receiver would show it with no power on the scale lamp.
    css('.sb-rule').styles(
      position: Position.absolute(
        bottom: Unit.expression('calc(var(--panel-h) + var(--free-h) * 0.26)'),
        left: 50.percent,
      ),
      width: Unit.expression('min(600px, 50%)'),
      height: 1.px,
      raw: {
        'background':
            'linear-gradient(90deg, transparent, rgba(178,178,195,0.16) 10%, '
            'rgba(178,178,195,0.30) 50%, rgba(178,178,195,0.16) 90%, transparent)',
        'translate': '-50% 0',
      },
    ),
    // Ticks are drawn, not placed: a repeating gradient masked to fade at
    // both ends. Twenty-odd absolutely-positioned divs would be the same
    // picture at the cost of twenty-odd elements that never move.
    css('.sb-ticks').styles(
      position: Position.absolute(
        top: (-5).px,
        left: Unit.zero,
        right: Unit.zero,
      ),
      height: 5.px,
      raw: {
        'background': 'repeating-linear-gradient(90deg, rgba(178,178,195,0.26) 0 1px, transparent 1px 26px)',
        '-webkit-mask-image': 'linear-gradient(90deg, transparent, #000 14%, #000 86%, transparent)',
        'mask-image': 'linear-gradient(90deg, transparent, #000 14%, #000 86%, transparent)',
      },
    ),
    // The one lit thing on a dark screen. `left` is set inline from the
    // tuned frequency - see the note at the markup.
    css('.sb-led').styles(
      position: Position.absolute(top: 50.percent),
      width: 5.px,
      height: 5.px,
      radius: BorderRadius.all(Radius.circular(2.5.px)),
      backgroundColor: const Color('#E8A035'),
      raw: {
        // The lit end of `sb-breathe`, so the blanket `animation: none`
        // under reduced motion leaves a steady lamp rather than a dot
        // frozen at the bottom of its cycle.
        'box-shadow': '0 0 5px rgba(232,160,53,0.9), 0 0 16px rgba(232,160,53,0.34)',
        'translate': '-50% -50%',
        'animation': 'sb-breathe 4.6s ease-in-out infinite',
      },
    ),

    // ── model / state / frequency ──
    // Set in Chakra Petch because this is the hardware talking about
    // itself, which is exactly the role that face holds everywhere else
    // on the panel.
    css('.sb-data').styles(
      display: Display.flex,
      position: Position.absolute(
        bottom: Unit.expression('calc(var(--panel-h) + var(--free-h) * 0.26 + 30px)'),
        left: 50.percent,
      ),
      flexDirection: FlexDirection.row,
      alignItems: AlignItems.center,
      gap: Gap(column: 14.px),
      fontFamily: const FontFamily.list([
        FontFamily('Chakra Petch'),
        FontFamilies.monospace,
      ]),
      fontSize: Unit.pixels(10),
      fontWeight: FontWeight.w700,
      textTransform: TextTransform.upperCase,
      letterSpacing: 0.34.em,
      raw: {'white-space': 'nowrap', 'translate': '-50% 0'},
    ),
    // The model number is the dimmest of the three - it is the only one
    // that never changes, so it is the only one that can afford to be
    // read last. Still 5.12:1: dim is not the same as illegible.
    css('.sb-mark').styles(color: const Color('#7d7d88')),
    // Brightest, because it is the answer to the question the black
    // screen raises.
    css('.sb-state').styles(color: const Color('#b4b4be')),
    // Amber, because it is a value the receiver is holding rather than a
    // word printed on it. Tracking is pulled in: digits at 0.34em read
    // as separate numbers.
    css('.sb-freq').styles(
      color: const Color('#a8823f'),
      raw: {'letter-spacing': '0.2em'},
    ),
    css('.sb-sep').styles(
      width: 3.px,
      height: 3.px,
      backgroundColor: const Color('#4a4a52'),
    ),

    // ── the instruction ──
    // Sits below the dial line, closing the composition. It is the only
    // thing on the page telling a first-time visitor what to do, so the
    // pulse bottoms out at 0.78 (5.09:1) rather than at something that
    // looks better and is readable half the time.
    //
    // It runs `power-attract`'s cycle rather than one of its own, so it
    // swells in step with the rocker it is naming - see the keyframe.
    css('.sb-press').styles(
      position: Position.absolute(
        bottom: Unit.expression('calc(var(--panel-h) + var(--free-h) * 0.26 - 42px)'),
        left: 50.percent,
      ),
      color: const Color('#c99a4e'),
      fontFamily: const FontFamily.list([
        FontFamily('IBM Plex Mono'),
        FontFamilies.monospace,
      ]),
      fontSize: Unit.pixels(11),
      fontWeight: FontWeight.w600,
      textTransform: TextTransform.upperCase,
      letterSpacing: 0.42.em,
      raw: {
        'text-indent': '0.42em', // compensate trailing letter-spacing
        // The lit end of `sb-press-attract`, same as `.sb-led` holds the
        // lit end of its own cycle: with the animation stripped the word
        // stays at the top of its swell instead of at the bottom.
        'text-shadow': '0 0 9px rgba(232,160,53,0.55), 0 0 20px rgba(232,160,53,0.28)',
        'white-space': 'nowrap',
        'translate': '-50% 0',
        'animation': 'sb-press-attract 2.4s ease-in-out infinite',
      },
    ),

    // ── technical transmission dialog ──
    // Deliberately not styled like a web modal. No rounded card floating
    // on a grey scrim: it is a printout the receiver produced, so it
    // gets the same dark plastic, hairline borders and instrument
    // microtype as the rest of the hardware.
    css('.rx-overlay').styles(
      display: Display.flex,
      position: Position.fixed(
        top: Unit.zero,
        left: Unit.zero,
        right: Unit.zero,
        bottom: Unit.zero,
      ),
      // Above the content layers, below the faceplate (z 50), so the
      // receiver stays framing the panel rather than being covered by it.
      zIndex: ZIndex(45),
      justifyContent: JustifyContent.center,
      alignItems: AlignItems.center,
      raw: {
        // Sized to the viewport the browser is really showing, not to the
        // one `inset: 0` implies. On a phone those differ by the height
        // of the URL bar, and the difference lands at the bottom of the
        // panel - which is where the end of a long transmission is, and
        // why it could not be scrolled into view.
        'height': 'var(--vh, 100dvh)',
        // The faceplate is z-index 50 and this overlay is 45, on purpose:
        // the receiver frames the printout rather than being covered by
        // it. Which also means the bottom of this box sits *behind* the
        // faceplate, and the taller the faceplate grows - the preset rack
        // appearing is the big one - the more of the transmission it
        // hides. The scroll did reach the end; the end was underneath the
        // radio.
        //
        // So the panel is centred in the room above the faceplate rather
        // than in the viewport. The scrim still covers the whole screen;
        // only the area the panel may occupy is inset, by the faceplate's
        // measured height.
        'padding': '20px 20px calc(20px + var(--panel-h, 210px))',
        'background': 'rgba(2,2,6,0.82)',
        'backdrop-filter': 'blur(3px)',
        '-webkit-backdrop-filter': 'blur(3px)',
        'animation': 'hint-fade-in 0.2s ease-out both',
      },
    ),
    css('.rx-panel').styles(
      position: Position.relative(),
      width: 100.percent,
      maxWidth: 560.px,
      // 100% of the overlay's content box, which already excludes its own
      // 20px of padding. The old `calc(100% - 40px)` subtracted that
      // padding a second time and gave away 40px of reading height for
      // nothing.
      maxHeight: 100.percent,
      padding: Padding.symmetric(horizontal: 24.px, vertical: 24.px),
      overflow: Overflow.auto,
      raw: {
        'background': 'linear-gradient(160deg, #111118 0%, #0a0a10 100%)',
        'border': '1px solid rgba(255,255,255,0.10)',
        'border-radius': '4px',
        // Lit top-left edge, shaded bottom-right, and a large mostly
        // ambient shadow with just enough offset to say which way it is
        // leaning.
        'box-shadow':
            'inset 1px 1px 0 rgba(255,255,255,0.07), '
            'inset -1px -1px 0 rgba(0,0,0,0.5), '
            '4px 20px 60px rgba(0,0,0,0.7)',
        'outline': 'none',
        // A swipe that runs past the end stays here rather than tugging
        // at the document behind the dialog.
        'overscroll-behavior': 'contain',
        'touch-action': 'pan-y',
      },
    ),
    css('.rx-head').styles(
      display: Display.flex,
      flexDirection: FlexDirection.row,
      justifyContent: JustifyContent.spaceBetween,
      alignItems: AlignItems.center,
      raw: {'margin-bottom': '10px'},
    ),
    css('.rx-label').styles(
      color: const Color('#d3a35a'),
      fontFamily: const FontFamily.list([
        FontFamily('IBM Plex Mono'),
        FontFamilies.monospace,
      ]),
      fontSize: Unit.pixels(11),
      fontWeight: FontWeight.w500,
      textTransform: TextTransform.upperCase,
      letterSpacing: 0.34.em,
    ),
    css('.rx-close', [
      css('&').styles(
        display: Display.flex,
        width: 32.px,
        height: 32.px,
        radius: BorderRadius.all(Radius.circular(3.px)),
        cursor: Cursor.pointer,
        justifyContent: JustifyContent.center,
        alignItems: AlignItems.center,
        color: const Color('#9a9aa6'),
        fontSize: Unit.pixels(20),
        raw: {
          'line-height': '1',
          'border': '1px solid rgba(255,255,255,0.10)',
          'background': 'rgba(255,255,255,0.03)',
          'transition':
              'color var(--dur-plastic) var(--ease-plastic), '
              'border-color var(--dur-plastic) var(--ease-plastic)',
          'flex-shrink': '0',
          'touch-action': 'manipulation',
          '-webkit-tap-highlight-color': 'transparent',
        },
      ),
    ]),
    css('.rx-title').styles(
      color: const Color('#E8A035'),
      fontFamily: const FontFamily.list([
        FontFamily('Space Grotesk'),
        FontFamilies.sansSerif,
      ]),
      fontWeight: FontWeight.w700,
      letterSpacing: 0.02.em,
      raw: {
        'font-size': 'clamp(1.35rem, 3.2vw, 2rem)',
        'margin': '0 0 14px',
        'line-height': '1.15',
        'text-shadow': '0 0 8px rgba(232,160,53,0.28)',
      },
    ),
    css('.rx-body').styles(
      color: const Color('#9c9174'),
      fontFamily: const FontFamily.list([
        FontFamily('IBM Plex Mono'),
        FontFamilies.monospace,
      ]),
      fontSize: Unit.pixels(13),
      raw: {'line-height': '1.6', 'margin': '0 0 16px'},
    ),
    css('.rx-data').styles(
      display: Display.grid,
      gap: Gap(row: 6.px, column: 16.px),
      raw: {
        'grid-template-columns': 'auto minmax(0, 1fr)',
        'padding': '14px 0',
        'margin-bottom': '16px',
        'border-top': '1px solid rgba(255,255,255,0.07)',
        'border-bottom': '1px solid rgba(255,255,255,0.07)',
      },
    ),
    css('.rx-key').styles(
      color: const Color('#938d81'),
      fontFamily: const FontFamily.list([
        FontFamily('IBM Plex Mono'),
        FontFamilies.monospace,
      ]),
      fontSize: Unit.pixels(11),
      fontWeight: FontWeight.w500,
      letterSpacing: 0.16.em,
      raw: {'line-height': '1.45', 'white-space': 'nowrap'},
    ),
    css('.rx-val').styles(
      color: const Color('#d8c9a4'),
      fontFamily: const FontFamily.list([
        FontFamily('IBM Plex Mono'),
        FontFamilies.monospace,
      ]),
      fontSize: Unit.pixels(11),
      fontWeight: FontWeight.w500,
      raw: {'line-height': '1.45'},
    ),
    css('.rx-hint').styles(
      // Was #7a7a84, which measured 4.46:1 against the old panel and 4.43
      // once the panel's top edge was lifted for the light source: under
      // AA either way, and it had simply never been measured. This is the
      // only place the keyboard affordance is stated, so it holds the
      // floor at 4.94:1.
      color: const Color('#82828c'),
      textAlign: TextAlign.right,
      fontFamily: const FontFamily.list([
        FontFamily('IBM Plex Mono'),
        FontFamilies.monospace,
      ]),
      fontSize: Unit.pixels(11),
      textTransform: TextTransform.upperCase,
      letterSpacing: 0.3.em,
    ),
    css.media(MediaQuery.screen(maxWidth: 600.px), [
      css('.rx-panel').styles(
        padding: Padding.symmetric(horizontal: 18.px, vertical: 18.px),
      ),
      css('.rx-label').styles(letterSpacing: 0.2.em),
    ]),

    // Language toggle pill - fixed top-right.
    css('.lang-toggle', [
      css('&').styles(
        position: Position.fixed(top: 16.px, right: 16.px),
        zIndex: ZIndex(20),
        padding: Padding.symmetric(horizontal: 10.px, vertical: 5.px),
        radius: BorderRadius.all(Radius.circular(99.px)),
        cursor: Cursor.pointer,
        color: const Color('#c8c8cc'),
        fontFamily: const FontFamily.list([FontFamilies.monospace]),
        fontSize: Unit.pixels(11),
        fontWeight: FontWeight.w500,
        letterSpacing: 0.2.em,
        raw: {
          'border': '1px solid rgba(255,255,255,0.12)',
          'background': 'rgba(0,0,0,0.35)',
          'backdrop-filter': 'blur(4px)',
          '-webkit-backdrop-filter': 'blur(4px)',
          'transition': 'border-color 0.2s ease, color 0.2s ease',
          'user-select': 'none',
          'touch-action': 'manipulation',
          '-webkit-tap-highlight-color': 'transparent',
          '-webkit-user-select': 'none',
        },
      ),
    ]),
    // ── hover, and only where hovering exists ──
    //
    // WebKit turns the first tap on a non-native control that has :hover
    // styles into a hover reveal, and only the second tap counts as a
    // click. Every control here is a span or div with role=button rather
    // than a real <button>, so all of them inherited that: on an iPhone
    // the faceplate had to be pressed twice. See the same block in
    // `station_display.dart`.
    css.media(const MediaQuery.raw('(hover: hover)'), [
      css('.rx-close:hover').styles(
        color: const Color('#ffffff'),
        raw: {'border-color': 'rgba(255,255,255,0.28)'},
      ),
      css('.lang-toggle:hover').styles(
        color: const Color('#ffffff'),
        raw: {'border-color': 'rgba(255,255,255,0.32)'},
      ),
    ]),

    // ── idle "carrier monitor" readout ──
    // Sits in the same vertical slot as the old hero title, but
    // structured as a receiver's between-stations display. The five
    // layers - dashes, CARRIER state line, band/range, sweep ribbon,
    // sub-caption - all share a single vertical flow so the block
    // reads top-down like a real monitoring panel.
    css('.carrier-monitor').styles(
      display: Display.flex,
      position: Position.absolute(
        // Centre of the free space above the faceplate, measured rather
        // than derived. `100% - var(--panel-h)` was the same idea done as
        // arithmetic, and it inherited every error in `--panel-h`.
        top: Unit.expression('calc(var(--free-h) / 2)'),
        left: 50.percent,
      ),
      zIndex: ZIndex(30),
      width: 100.percent,
      maxWidth: 480.px,
      pointerEvents: PointerEvents.none,
      flexDirection: FlexDirection.column,
      alignItems: AlignItems.center,
      gap: Gap(row: 16.px),
      textAlign: TextAlign.center,
      raw: {
        // Centring lives in `translate`, not in `transform`, and that is
        // the entire reason this block used to end up off the side of a
        // phone screen.
        //
        // `content-jitter` animates `transform`, and an animation owns
        // the whole property: the moment it ran it replaced
        // `translate(-50%, -50%)` with `translateX(2px)` and threw the
        // centring away, dropping the readout by half its height and
        // pushing it right by half its width - about 195 px on a 390 px
        // screen. It only ran when the noise level was high, which is
        // exactly the idle, between-stations state this readout exists
        // for, so it was broken in the only state anyone ever sees it in.
        //
        // The individual `translate` property is applied before
        // `transform`, so the two now compose instead of fighting: the
        // jitter shakes a block that stays centred. Same trap the station
        // panels avoid by keeping their animations on `.panel-fx`.
        'translate': '-50% -50%',
      },
    ),

    // ── dash array ──
    // Row of five en-dashes. Each dash drifts its opacity on its own
    // delay so the array reads as animated silence rather than a
    // frozen placeholder. The row itself drifts horizontally a few
    // pixels via `dash-drift` - a slow, unconscious wobble.
    css('.carrier-dashes').styles(
      display: Display.flex,
      flexDirection: FlexDirection.row,
      justifyContent: JustifyContent.center,
      alignItems: AlignItems.center,
      gap: Gap(column: 16.px),
      raw: {
        'animation': 'dash-drift 6s ease-in-out infinite',
        'color': '#b0b0ba',
        // Constant chromatic fringe on the dashes themselves -
        // mirrors the CRT edge fringe, reads as an unconverged
        // signal.
        'text-shadow': '1px 0 0 rgba(255,60,90,0.28), -1px 0 0 rgba(60,200,255,0.28)',
      },
    ),
    css('.carrier-dash').styles(
      fontFamily: const FontFamily.list([
        FontFamily('Space Grotesk'),
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
    // circles that pulse amber - the hardware's "signal present"
    // tell-tales, here unlit-grey because nothing is locked.
    css('.carrier-state').styles(
      display: Display.flex,
      flexDirection: FlexDirection.row,
      justifyContent: JustifyContent.center,
      alignItems: AlignItems.center,
      gap: Gap(column: 12.px),
    ),
    css('.carrier-dot').styles(
      width: 5.px,
      height: 5.px,
      radius: BorderRadius.all(Radius.circular(2.5.px)),
      backgroundColor: const Color('#4a3a22'),
      raw: {
        'box-shadow':
            'inset 0 1px 1px rgba(0,0,0,0.6), '
            '0 0 3px rgba(232,160,53,0.25)',
      },
    ),
    css('.carrier-state-text').styles(
      color: const Color('#d4d4dc'),
      fontFamily: const FontFamily.list([
        FontFamily('IBM Plex Mono'),
        FontFamilies.monospace,
      ]),
      fontSize: Unit.pixels(13),
      fontWeight: FontWeight.w500,
      textTransform: TextTransform.upperCase,
      letterSpacing: 0.5.em,
      raw: {
        'text-shadow':
            '0 0 6px rgba(212,212,220,0.35), '
            '0 0 14px rgba(212,212,220,0.12)',
        'animation': 'carrier-breathe 3.2s ease-in-out infinite',
      },
    ),

    // ── band / range line ──
    // `FM · 87.5 – 108.0 · MHZ` - the same layout AM and FM share,
    // just different values. The band marker on the left is the
    // brightest element (identifies which side of the dial the
    // user is on); the range itself is a calmer mid-grey; the
    // unit is the dimmest, like a legend.
    css('.carrier-band').styles(
      display: Display.flex,
      flexDirection: FlexDirection.row,
      justifyContent: JustifyContent.center,
      alignItems: AlignItems.baseline,
      gap: Gap(column: 10.px),
      fontFamily: const FontFamily.list([
        FontFamily('IBM Plex Mono'),
        FontFamilies.monospace,
      ]),
      fontSize: Unit.pixels(11),
      textTransform: TextTransform.upperCase,
      letterSpacing: 0.25.em,
    ),
    css('.carrier-band-band').styles(
      color: const Color('#E8A035'),
      fontWeight: FontWeight.w600,
      raw: {
        'text-shadow': '0 0 4px rgba(232,160,53,0.6), 0 0 10px rgba(232,160,53,0.25)',
      },
    ),
    css('.carrier-band-range').styles(
      color: const Color('#a6a6b0'),
      fontWeight: FontWeight.w500,
      raw: {'letter-spacing': '0.15em'},
    ),
    // Purely a visual divider between the band, range and unit, so it
    // stays below the text floor on purpose - it is punctuation, not
    // content, and is skipped by screen readers along with the rest of
    // the decorative row.
    css('.carrier-band-sep').styles(
      color: const Color('#5c5c64'),
      raw: {'font-weight': '700', 'transform': 'translateY(-1px)'},
    ),
    css('.carrier-band-unit').styles(
      // Was #66666f → 3.58:1. Now 6.36:1. The unit ("MHZ" / "KHZ") is
      // what tells you which band you are reading, so it has to survive
      // the noise layer.
      color: const Color('#8f8f99'),
      fontWeight: FontWeight.w500,
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
        'box-shadow': '0 0 6px rgba(232,160,53,0.7), 0 0 14px rgba(232,160,53,0.3)',
        'animation': 'carrier-sweep 3.6s ease-in-out infinite',
        'transform': 'translateX(-50%)',
      },
    ),

    // ── sub-caption ──
    // Whispered second line. Dim, small, heavily tracked - the
    // kind of runtime-status text you'd find printed just above
    // a signal-presence indicator on a rack-mounted receiver.
    css('.carrier-sub').styles(
      // Was #5a5a62 at 9 px, i.e. 2.98:1 before carrier-breathe even
      // touched it. This is real status copy ("SCANNING BAND"), not
      // ornament, so it gets a real contrast budget: 7.32:1 at the top
      // of the breathe cycle and 5.50:1 at the trough.
      color: const Color('#9a9aa6'),
      fontFamily: const FontFamily.list([
        FontFamily('IBM Plex Mono'),
        FontFamilies.monospace,
      ]),
      fontSize: Unit.pixels(11),
      fontWeight: FontWeight.w500,
      textTransform: TextTransform.upperCase,
      letterSpacing: 0.55.em,
      raw: {
        'animation': 'carrier-breathe 4s ease-in-out infinite',
        'text-indent': '0.55em', // compensate trailing letter-spacing
      },
    ),

    css.media(MediaQuery.screen(maxWidth: 600.px), [
      // Compact lang toggle so it doesn't crowd the top edge.
      css('.lang-toggle').styles(
        position: Position.fixed(top: 10.px, right: 10.px),
        padding: Padding.symmetric(horizontal: 10.px, vertical: 6.px),
        fontSize: Unit.pixels(11),
      ),
      // Matches the shorter mobile faceplate. The vertical position
      // follows automatically from here.
      css('.signal-app').styles(raw: {'--panel-h': '180px'}),
      // The standby poster keeps its proportions by widening rather than
      // by scaling: 60% of a phone is a 230 px housing, which reads as a
      // slab in the middle of the screen instead of as the front of the
      // radio underneath it. The vertical maths needs no adjustment - it
      // is all derived from the measured `--panel-h` / `--free-h`.
      css('.sb-body').styles(width: Unit.expression('min(720px, 86%)')),
      css('.sb-rule').styles(width: Unit.expression('min(600px, 74%)')),
      // Three tracked words plus two separators do not fit across a
      // phone at 0.34em. Tracking gives way before the type size does -
      // same rule the carrier readout follows.
      css('.sb-data').styles(
        gap: Gap(column: 8.px),
        letterSpacing: 0.16.em,
      ),
      css('.sb-press').styles(
        letterSpacing: 0.3.em,
        raw: {'text-indent': '0.3em'},
      ),
      css('.carrier-monitor').styles(gap: Gap(row: 12.px)),
      css('.carrier-dashes').styles(gap: Gap(column: 12.px)),
      css('.carrier-dash').styles(fontSize: 1.9.rem),
      // Phones keep the full 11 px floor. The old mobile ramp went down
      // to 8 px, which is below what most people can read at arm's
      // length even at full contrast. Tracking absorbs the extra width
      // instead of the type size.
      css('.carrier-state-text').styles(
        fontSize: Unit.pixels(11),
        letterSpacing: 0.28.em,
      ),
      css('.carrier-band').styles(
        gap: Gap(column: 6.px),
        fontSize: Unit.pixels(11),
        letterSpacing: 0.12.em,
      ),
      css('.carrier-sweep').styles(width: 180.px),
      css('.carrier-sub').styles(
        fontSize: Unit.pixels(11),
        letterSpacing: 0.28.em,
      ),
    ]),
  ];
}
