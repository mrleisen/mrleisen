/// WCAG 2.1 contrast audit for the radio's text colours.
///
///     dart run tool/check_contrast.dart
///
/// Exits non-zero if anything carrying real information falls under AA.
///
/// Why this exists: the panels are dim-on-near-black by design, several
/// of them tint with `opacity` rather than a flat colour, and the station
/// colour is injected per-panel through `--sc`. That combination makes
/// contrast very hard to eyeball - three of the values in this file were
/// wrong when estimated by hand and only surfaced once measured. Any
/// future change to the palette should be run through here first.
///
/// Decorative faceplate silkscreen (VOL, ON/OFF, the brand plate, dial
/// ticks) is deliberately absent: it is ornament on a physical object,
/// not content, and is exposed to assistive tech via aria-label instead.
library;

import 'dart:io';
import 'dart:math' as math;

/// Page background every layer ultimately composites onto.
const bg = '#050507';

/// Neutral that station colours are mixed toward so the darkest stations
/// clear AA without losing their hue.
const neutral = '#d8d2c4';

/// The 12 station colours from `lib/models/station.dart`.
const stationColors = {
  'ITNW': '#4EBFB0',
  'BBL': '#D4A843',
  'NET': '#B085E0',
  'WHO': '#5BA4D9',
  'UIS': '#E8944A',
  'TRP': '#E86A8A',
  'NUM': '#5BC8A0',
  'AYU': '#B07CD6',
  'AWS': '#E05050',
  'CSP': '#C77B4E',
  'NFT': '#8BBF55',
  'PNK': '#D05A8C',
};

const amStations = ['NUM', 'AYU', 'AWS', 'CSP', 'NFT', 'PNK'];
const fmStations = ['ITNW', 'BBL', 'NET', 'WHO', 'UIS', 'TRP'];

/// Only these three render `.panel-subtitle` (`_itnwPanel`, `_tropPanel`
/// and `_bblPanel`). The AM panels go through `_amPanel`, which uses
/// `.am-subtitle` instead - so pairing an AM colour with `.panel-subtitle`
/// tests a combination the app can never produce.
const subtitleStations = ['ITNW', 'TRP', 'BBL'];

double _lin(double c) => c <= 0.03928 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();

List<int> _hex(String h) {
  h = h.replaceAll('#', '');
  return [
    int.parse(h.substring(0, 2), radix: 16),
    int.parse(h.substring(2, 4), radix: 16),
    int.parse(h.substring(4, 6), radix: 16),
  ];
}

double _lum(List<int> rgb) => 0.2126 * _lin(rgb[0] / 255) + 0.7152 * _lin(rgb[1] / 255) + 0.0722 * _lin(rgb[2] / 255);

/// Alpha-composites [fg] over [bgc].
List<int> _over(String fg, String bgc, double alpha) {
  final f = _hex(fg), b = _hex(bgc);
  return [
    for (var i = 0; i < 3; i++) (f[i] * alpha + b[i] * (1 - alpha)).round(),
  ];
}

/// Mirrors CSS `color-mix(in srgb, <a> <pct>%, <b>)`.
String mix(String a, String b, double pct) {
  final x = _hex(a), y = _hex(b);
  return '#'
      '${[for (var i = 0; i < 3; i++) (x[i] * pct + y[i] * (1 - pct)).round()].map((c) => c.toRadixString(16).padLeft(2, '0')).join()}';
}

double ratio(String fg, {double alpha = 1.0}) {
  final f = _lum(_over(fg, bg, alpha));
  final b = _lum(_hex(bg));
  return (math.max(f, b) + 0.05) / (math.min(f, b) + 0.05);
}

var _failures = 0;

/// AA needs 4.5:1 for body text, 3:1 once type reaches 24px (or 18.66px
/// bold). [px] picks the right threshold.
void check(String label, String fg, {double alpha = 1.0, required double px}) {
  final r = ratio(fg, alpha: alpha);
  final need = px >= 24 ? 3.0 : 4.5;
  final ok = r >= need;
  if (!ok) _failures++;
  stdout.writeln(
    '${ok ? "  ok  " : "  FAIL"} ${label.padRight(30)}'
    '${fg.padRight(9)} '
    '${alpha == 1.0 ? "      " : "a=${alpha.toStringAsFixed(2)}"} '
    '${px.toStringAsFixed(0).padLeft(3)}px '
    '${r.toStringAsFixed(2).padLeft(6)}:1  (need $need)',
  );
}

void section(String title) => stdout.writeln('\n$title');

void main() {
  section('Station content panels (FM)');
  check('.panel-body', '#9c9174', px: 14);
  check('.panel-body @600px', '#9c9174', px: 13);

  section('Station content panels (AM)');
  check('.am-body', '#8f8770', px: 13);
  check('.am-body @600px', '#8f8770', px: 12);
  check('.am-subtitle', '#8f8468', px: 11);

  section('Idle carrier monitor');
  // .carrier-sub and .carrier-state-text carry `carrier-breathe`, whose
  // trough is the real worst case - check the floor, not just the peak.
  check('.carrier-sub @breathe floor', '#9a9aa6', alpha: 0.85, px: 11);
  check('.carrier-sub @breathe peak', '#9a9aa6', px: 11);
  check('.carrier-state-text @floor', '#d4d4dc', alpha: 0.85, px: 11);
  check('.carrier-band-range', '#a6a6b0', px: 11);
  check('.carrier-band-unit', '#8f8f99', px: 11);
  check('.carrier-band-band', '#E8A035', px: 11);

  section('.panel-label - color-mix(sc 70%, $neutral)');
  stationColors.forEach((k, v) {
    check('  $k', mix(v, neutral, 0.70), px: 11);
  });

  section('.am-label - color-mix(sc 60%, $neutral)');
  for (final k in amStations) {
    check('  $k', mix(stationColors[k]!, neutral, 0.60), px: 11);
  }

  section('.panel-title - raw station colour, 35px (FM only)');
  for (final k in fmStations) {
    check('  $k', stationColors[k]!, alpha: 0.92, px: 35);
  }

  section('.panel-subtitle - color-mix(sc 80%, #cfc9b8)');
  for (final k in subtitleStations) {
    check('  $k', mix(stationColors[k]!, '#cfc9b8', 0.80), alpha: 0.80, px: 11);
  }

  section('.am-title - color-mix(sc 85%, #cfc9b8), 22px');
  for (final k in amStations) {
    check('  $k', mix(stationColors[k]!, '#cfc9b8', 0.85), alpha: 0.90, px: 22);
  }

  stdout.writeln('');
  if (_failures > 0) {
    stdout.writeln('$_failures below AA.');
    exit(1);
  }
  stdout.writeln('All checked text meets WCAG AA against $bg.');
}
