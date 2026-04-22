/// Station data model and frequency helpers for Radio.

/// Broadcast band. FM carries featured long-form content; AM carries
/// lightweight idea-stage project cards.
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

  /// Distance within which a station's signal/content is "in range" —
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

const stations = <Station>[
  // ── FM: featured content. ──
  Station(band: Band.fm, frequency: 89.5, callSign: 'ITNW', color: '#4EBFB0'),
  Station(band: Band.fm, frequency: 93.6, callSign: 'NET', color: '#B085E0'),
  Station(band: Band.fm, frequency: 97.7, callSign: 'WHO', color: '#5BA4D9'),
  Station(band: Band.fm, frequency: 101.8, callSign: 'UIS', color: '#E8944A'),
  Station(band: Band.fm, frequency: 105.9, callSign: 'TRP', color: '#E86A8A'),
  // ── AM: idea-stage projects, one per station. ──
  Station(band: Band.am, frequency: 640.0, callSign: 'BBL', color: '#D4A843'),
  Station(band: Band.am, frequency: 960.0, callSign: 'AWS', color: '#E05050'),
  Station(band: Band.am, frequency: 1280.0, callSign: 'NFT', color: '#8BBF55'),
  Station(band: Band.am, frequency: 1600.0, callSign: 'PNK', color: '#D05A8C'),
];

Iterable<Station> stationsFor(Band band) =>
    stations.where((s) => s.band == band);

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
  return 1.0 - (minDist / cfg.tolerance);
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
