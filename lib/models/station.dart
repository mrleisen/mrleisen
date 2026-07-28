/// Station data model and frequency helpers for Radio.
library;

import 'dart:math' as math;

/// Broadcast band. FM carries the work worth stopping on - shipped, or
/// finished, or still being made; AM carries lightweight idea-stage
/// project cards.
///
/// The split is about whether there is something to show, not about
/// whether it is current: A Wired Spine closed in 2012 and broadcasts on
/// FM because three records exist, while a concept from last month sits
/// on AM because it is still a sentence.
enum Band { fm, am }

/// Per-band constants used by the dial, audio engine, and content panels.
/// Having everything on one value means band-aware code can simply do
/// `configFor(band).tolerance` instead of branching on the enum each time.
class BandConfig {
  const BandConfig({
    required this.minFreq,
    required this.maxFreq,
    required this.step,
    required this.tolerance,
    required this.lockRange,
    required this.whistleScale,
    required this.pxPerStep,
  });

  final double minFreq;
  final double maxFreq;

  /// Granularity of a single dial step (0.1 MHz on FM, 10 kHz on AM).
  final double step;

  /// Distance within which a station's signal/content is "in range" -
  /// content begins fading in, heterodyne whistle starts, static begins
  /// clearing. Expressed in the band's native unit (MHz / kHz).
  final double tolerance;

  /// Distance within which content renders completely clean.
  final double lockRange;

  /// Multiplier applied to distance-to-nearest-station when computing
  /// the heterodyne whistle frequency, so both bands peak near 2 kHz
  /// at the tolerance edge (FM: MHz × 2000, AM: kHz × 25).
  final double whistleScale;

  /// Pixels drawn per dial step on the tuning strip.
  final double pxPerStep;
}

const BandConfig fmConfig = BandConfig(
  minFreq: 87.5,
  maxFreq: 108.0,
  step: 0.1,
  tolerance: 1.0,
  lockRange: 0.15,
  whistleScale: 2000.0,
  pxPerStep: 6.0, // 60 px per MHz
);

const BandConfig amConfig = BandConfig(
  minFreq: 540.0,
  maxFreq: 1700.0,
  step: 10.0,
  tolerance: 80.0,
  lockRange: 15.0,
  whistleScale: 25.0,
  pxPerStep: 12.0, // 1.2 px per kHz
);

BandConfig configFor(Band band) => band == Band.fm ? fmConfig : amConfig;

class Station {
  final Band band;
  final double frequency;
  final String callSign;
  final String color;

  const Station({
    required this.band,
    required this.frequency,
    required this.callSign,
    required this.color,
  });
}

/// The band plan.
///
/// Spacing is load-bearing, not layout. Two stations closer than twice
/// their band's [BandConfig.tolerance] have overlapping catchment, so the
/// dead air between them never reaches true silence and the receiver
/// always sounds like it is near *something*. That floor is 2.0 MHz on FM
/// and 160 kHz on AM; check it before moving anything.
const stations = <Station>[
  // ── FM: featured content. ──
  Station(band: Band.fm, frequency: 89.5, callSign: 'ITNW', color: '#4EBFB0'),
  Station(band: Band.fm, frequency: 91.6, callSign: 'BBL', color: '#D4A843'),
  Station(band: Band.fm, frequency: 93.6, callSign: 'NET', color: '#B085E0'),
  Station(band: Band.fm, frequency: 97.7, callSign: 'WHO', color: '#5BA4D9'),
  // Exactly 2.0 from WHO and 2.1 from DTU - the tightest legal pair on
  // the plan, and the reason this sits here rather than a step lower.
  Station(band: Band.fm, frequency: 99.7, callSign: 'AWS', color: '#E05050'),
  Station(band: Band.fm, frequency: 101.8, callSign: 'DTU', color: '#E8944A'),
  Station(band: Band.fm, frequency: 105.9, callSign: 'TRP', color: '#E86A8A'),
  // ── AM: idea-stage projects, one per station. ──
  Station(band: Band.am, frequency: 660.0, callSign: 'NUM', color: '#5BC8A0'),
  Station(band: Band.am, frequency: 820.0, callSign: 'AYU', color: '#B07CD6'),
  // The one deliberate exception to the spacing floor: 1000 is the
  // number the station is *about* - Kiwo's universe is #10000 - and the
  // dial saying so is worth the 120 kHz to CSP instead of 160. The cost
  // is roughly 11% residual signal at the deadest point between them
  // rather than silence. 980 buys the silence back and loses the joke.
  Station(band: Band.am, frequency: 1000.0, callSign: 'KIW', color: '#E8C04A'),
  Station(band: Band.am, frequency: 1120.0, callSign: 'CSP', color: '#C77B4E'),
  Station(band: Band.am, frequency: 1280.0, callSign: 'NFT', color: '#8BBF55'),
  Station(band: Band.am, frequency: 1600.0, callSign: 'PNK', color: '#D05A8C'),
];

Iterable<Station> stationsFor(Band band) => stations.where((s) => s.band == band);

/// Shapes the raw 0-1 proximity ramp into the curve the receiver
/// actually behaves with.
///
/// A linear ramp gives every point in the tolerance window equal weight,
/// which reads as a uniform slide from noise to signal - you always know
/// exactly how far in you are, and nothing ever surprises you. Real
/// tuning is not like that: most of the gap between stations is dead,
/// and then the carrier arrives almost all at once.
///
/// The exponent puts a knee in the curve. At a quarter of the way in the
/// signal is still only ~11% rather than 25%, so the outer band stays
/// convincingly empty; the last third is where it surges. That is what
/// produces the "something is close" beat before the lock, instead of a
/// readout that merely counts upward.
const double _signalKnee = 1.6;

/// Returns 0.0 (no signal) to 1.0 (perfect tune) based on proximity to
/// the nearest station on [band] within [BandConfig.tolerance].
double getSignalStrength(double frequency, Band band) {
  final cfg = configFor(band);
  var minDist = double.infinity;
  for (final s in stationsFor(band)) {
    final d = (frequency - s.frequency).abs();
    if (d < minDist) minDist = d;
  }
  if (minDist >= cfg.tolerance) return 0.0;
  final linear = 1.0 - (minDist / cfg.tolerance);
  return math.pow(linear, _signalKnee).toDouble();
}

/// Returns the station the dial is locked onto (within ±lockRange),
/// or null when between stations.
Station? getActiveStation(double frequency, Band band) {
  final cfg = configFor(band);
  for (final s in stationsFor(band)) {
    if ((frequency - s.frequency).abs() < cfg.lockRange) return s;
  }
  return null;
}

/// Returns the nearest station on [band] within tolerance, or null.
Station? getNearestStation(double frequency, Band band) {
  final cfg = configFor(band);
  Station? nearest;
  var minDist = double.infinity;
  for (final s in stationsFor(band)) {
    final d = (frequency - s.frequency).abs();
    if (d < minDist && d < cfg.tolerance) {
      minDist = d;
      nearest = s;
    }
  }
  return nearest;
}

/// Maps signal strength (0–1) to noise overlay opacity.
/// 0 signal → 0.5 (heavy noise), 1.0 signal → 0.02 (almost invisible).
double noiseFromSignal(double signalStrength) {
  return 0.5 - (signalStrength * 0.48);
}
