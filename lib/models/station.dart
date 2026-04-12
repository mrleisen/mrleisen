/// Station data model and frequency helpers for The Signal.

const double minFrequency = 85.0;
const double maxFrequency = 108.0;

/// Distance (MHz) within which a station's signal/content is "in range".
/// Content begins appearing (heavily distorted) at this outer edge, and
/// locks in cleanly around ±[stationLockRange]. Static / whistle /
/// signal-bars all share this horizon.
const double stationTolerance = 1.0;

/// Distance within which content is rendered completely clean — no
/// glitch effects, full opacity, whistle silent.
const double stationLockRange = 0.15;

class Station {
  final double frequency;
  final String callSign;
  final String color;

  const Station({
    required this.frequency,
    required this.callSign,
    required this.color,
  });
}

const stations = <Station>[
  // Projects ↔ About were swapped: Projects (DEV, green) now lives at
  // 87.5 and About (WHO, blue) at 95.7. The call signs stay tied to
  // the content identity so routing in station_display / radio_audio
  // doesn't need to change.
  Station(frequency: 87.5, callSign: 'DEV', color: '#6DBF6A'),
  Station(frequency: 91.3, callSign: 'UIS', color: '#E8944A'),
  Station(frequency: 95.7, callSign: 'WHO', color: '#5BA4D9'),
  Station(frequency: 99.1, callSign: 'NET', color: '#B085E0'),
  Station(frequency: 103.5, callSign: '???', color: '#E05555'),
];

/// Returns 0.0 (no signal) to 1.0 (perfect tune) based on proximity to
/// the nearest station within [stationTolerance].
double getSignalStrength(double frequency) {
  var minDist = double.infinity;
  for (final s in stations) {
    final d = (frequency - s.frequency).abs();
    if (d < minDist) minDist = d;
  }
  if (minDist >= stationTolerance) return 0.0;
  return 1.0 - (minDist / stationTolerance);
}

/// Returns the station the dial is locked onto (within ±0.15 MHz),
/// or null when between stations.
Station? getActiveStation(double frequency) {
  for (final s in stations) {
    if ((frequency - s.frequency).abs() < 0.15) return s;
  }
  return null;
}

/// Returns the nearest station if within tolerance, or null.
Station? getNearestStation(double frequency) {
  Station? nearest;
  var minDist = double.infinity;
  for (final s in stations) {
    final d = (frequency - s.frequency).abs();
    if (d < minDist && d < stationTolerance) {
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
