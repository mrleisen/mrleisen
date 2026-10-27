/// Station data model and frequency helpers for Radio.
library;

import 'dart:math' as math;

/// Broadcast band. FM carries featured projects and stories; AM carries
/// lightweight cards for ideas and projects given less prominence.
///
/// Placement is editorial, not a release-status rule. A Wired Spine
/// remains featured after closing; ITNW moves to AM despite publishing
/// several videos because the channel did not find its audience.
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

  /// Root-relative path to what this station broadcasts, or null for a
  /// station that transmits nothing but a carrier.
  ///
  /// One A Wired Spine track per station, streamed and looped at low
  /// level under the panel - see [RadioAudio]. The path is declared here
  /// rather than in the audio engine because it is a fact about the
  /// station, the same as its frequency and its colour, and because a
  /// missing file has to be survivable: the engine treats a track that
  /// will not load as a station with nothing on it, so the dial keeps
  /// working and only the music is absent.
  ///
  /// Named by call sign rather than numbered. A numbered set silently
  /// misaligns the moment a station is moved or the plan is reordered,
  /// and the band plan above is reordered fairly often.
  ///
  /// Declared as Ogg Vorbis. Safari learned it in 17; anything older is
  /// served the MP3 sibling of the same name instead, chosen by the audio
  /// engine at load time - the band plan does not carry the browser's
  /// problems. See `web/audio/README.md` for the convention.
  final String? music;

  /// What [music] is, for the now-playing line under the faceplate.
  final Song? song;

  /// Root-relative path to the project's own mark, as its own app or site
  /// draws it, or null for a station whose project has none - today that
  /// is WHO and most AM ideas. Taken from each project's own repo, never
  /// redrawn here; sources and how each file was prepared are in
  /// `assets/logos/README.md`.
  final String? logo;

  const Station({
    required this.band,
    required this.frequency,
    required this.callSign,
    required this.color,
    this.music,
    this.song,
    this.logo,
  });
}

/// The A Wired Spine track a station broadcasts.
///
/// Titles are the ones the songs were written under. *Rutina* was
/// published on SoundCloud with its titles translated, so those carry an
/// [en] title as well and follow the page language; everything else has
/// one title in every language.
class Song {
  final String title;
  final String? en;

  /// The track's SoundCloud permalink, which awiredspine.com takes as
  /// `?play=` to open the record and cue it in its player. Null for a
  /// song that was never published, which is then named but not linked.
  final String? slug;

  const Song(this.title, {this.en, this.slug});

  String titleFor({required bool es}) => es ? title : (en ?? title);

  String? get href => slug == null ? null : 'https://awiredspine.com/?play=$slug#releases';
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
  // Seven stations on an even 3.0 MHz grid, every one of them on a .9:
  // FM in the Americas is allocated on odd tenths, so a real receiver
  // would find every one of these frequencies plausible. 3.0 is half
  // again the 2.0 floor, and the grid leaves 1.4 to the bottom of the
  // band and 1.1 to the top, so both ends of the dial reach true silence.
  Station(
    band: Band.fm,
    frequency: 88.9,
    callSign: 'CRM',
    color: '#4EBF90',
    music: 'audio/aws-itnw.ogg',
    song: Song('una preocupación', en: 'A Concern', slug: 'a-concern'),
    logo: 'logos/criptomano.png',
  ),
  Station(
    band: Band.fm,
    frequency: 91.9,
    callSign: 'BBL',
    color: '#D4A843',
    music: 'audio/aws-bbl.ogg',
    song: Song('una compra', en: 'A Purchase', slug: 'a-purchase'),
    logo: 'logos/bbl.png',
  ),
  // The gap below this one is where the receiver wakes up. `_fmFreq`
  // starts at 96.5, which has to sit at least a full tolerance from
  // everything or the site opens on a half-tuned panel instead of on the
  // empty carrier monitor it was designed to open on. 96.5 is 1.6 from
  // here and 1.4 from DTU, so the first frame is genuinely dead air.
  // Any grid that is moved has to be checked against this first.
  Station(
    band: Band.fm,
    frequency: 94.9,
    callSign: 'WHO',
    color: '#5BA4D9',
    music: 'audio/aws-who.ogg',
    song: Song('un dilema', en: 'A Dilemma', slug: 'a-dilemma'),
  ),
  Station(
    band: Band.fm,
    frequency: 97.9,
    callSign: 'DTU',
    color: '#E8944A',
    music: 'audio/aws-dtu.ogg',
    song: Song('un hola', en: 'A Hello', slug: 'a-hello'),
    logo: 'logos/dtu.png',
  ),
  Station(
    band: Band.fm,
    frequency: 100.9,
    callSign: 'TRP',
    color: '#E86A8A',
    music: 'audio/aws-trp.ogg',
    song: Song('una encerrona', en: 'A Trap', slug: 'a-trap'),
    logo: 'logos/trp.png',
  ),
  Station(
    band: Band.fm,
    frequency: 103.9,
    callSign: 'AWS',
    color: '#E05050',
    music: 'audio/aws-aws.ogg',
    song: Song('un adios', en: 'A Farewell', slug: 'a-farewell'),
    logo: 'logos/aws.svg',
  ),
  // The newest thing on the dial, and the reason the grid above was
  // re-cut: six stations had the band to themselves at uneven spacing,
  // and there was no gap wide enough for a seventh without moving all
  // of them. Plays the one A Wired Spine song nothing else was using.
  Station(
    band: Band.fm,
    frequency: 106.9,
    callSign: 'DMTFY',
    color: '#8FAE7C',
    music: 'audio/aws-dmtfy.ogg',
    song: Song('alguien tiene un arma'),
    logo: 'logos/dmtfy.svg',
  ),
  // ── AM: idea-stage projects, one per station. ──
  // ITNW occupies the lower edge without retuning existing AM presets.
  // Like KIW/CSP, its 120 kHz gap to NUM leaves a faint residual signal.
  Station(
    band: Band.am,
    frequency: 540.0,
    callSign: 'ITNW',
    color: '#4EBFB0',
    music: 'audio/aws-itnw.ogg',
    song: Song('una preocupación', en: 'A Concern', slug: 'a-concern'),
    logo: 'logos/itnw.png',
  ),
  Station(
    band: Band.am,
    frequency: 660.0,
    callSign: 'NUM',
    color: '#5BC8A0',
    music: 'audio/aws-num.ogg',
    song: Song('Remember the day we were happy, please!!', slug: 'remember-the-day-we-were-happy'),
  ),
  Station(
    band: Band.am,
    frequency: 820.0,
    callSign: 'AYU',
    color: '#B07CD6',
    music: 'audio/aws-ayu.ogg',
    song: Song('y tu'),
  ),
  // Another deliberate exception to the spacing floor: 1000 is the
  // number the station is *about* - Kiwo's universe is #10000 - and the
  // dial saying so is worth the 120 kHz to CSP instead of 160. The cost
  // is roughly 11% residual signal at the deadest point between them
  // rather than silence. 980 buys the silence back and loses the joke.
  Station(
    band: Band.am,
    frequency: 1000.0,
    callSign: 'KIW',
    color: '#E8C04A',
    music: 'audio/aws-kiw.ogg',
    song: Song('Vámonos Por La sombrita, Por Favor!!!', slug: 'v-monos-por-la-sombrita-por'),
  ),
  Station(
    band: Band.am,
    frequency: 1120.0,
    callSign: 'CSP',
    color: '#C77B4E',
    music: 'audio/aws-csp.ogg',
    song: Song('Beware Of The Sad Word', slug: 'beware-of-the-sad-word'),
  ),
  Station(
    band: Band.am,
    frequency: 1280.0,
    callSign: 'NFT',
    color: '#8BBF55',
    music: 'audio/aws-nft.ogg',
    song: Song('The Empty Space Between L VE', slug: 'the-empty-space-between-l-ve'),
  ),
  // 1440 sits exactly 160 kHz from both neighbours - the spacing floor
  // met to the digit on either side, in the one gap wide enough to take
  // a seventh station. The physics picked the frequency.
  Station(
    band: Band.am,
    frequency: 1440.0,
    callSign: 'PIX',
    color: '#7B8FE8',
    music: 'audio/aws-pix.ogg',
    song: Song('hielito'),
  ),
  Station(
    band: Band.am,
    frequency: 1600.0,
    callSign: 'PNK',
    color: '#D05A8C',
    music: 'audio/aws-pnk.ogg',
    song: Song('ITIHSTS', slug: 'itihsts'),
  ),
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
