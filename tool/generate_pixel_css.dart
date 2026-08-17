/// Converts pixel-art PNGs into pure-CSS `box-shadow` sprites.
///
///     dart run tool/generate_pixel_css.dart              # survey assets/pixel-art
///     dart run tool/generate_pixel_css.dart --dart       # regenerate lib/models/pixel_art.dart
///     dart run tool/generate_pixel_css.dart <png> [...]  # emit CSS for specific files
///
/// The site draws everything with CSS and Web Audio - no images - so a
/// piece of pixel art can only appear on screen the way the rest of the
/// receiver does: as painted CSS. A sprite here is one 1em × 1em element
/// whose box-shadow list places every opaque pixel at `(x+1)em (y+1)em`
/// (offset by one because a 0,0 shadow is clipped behind the element's
/// own border box). Set `font-size` to the desired on-screen pixel size
/// and shift the element up-left by 1em inside a `W×H em` frame.
///
/// Exported PNGs are upscaled; the logical grid is recovered by finding
/// the largest block size on which the bitmap is constant.
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart' as img;

/// Alpha below this is treated as a hole in the sprite.
const _alphaFloor = 128;

({int scale, int w, int h})? _logicalGrid(img.Image im) {
  for (var d = _gcd(im.width, im.height); d >= 1; d--) {
    if (im.width % d != 0 || im.height % d != 0) continue;
    if (_uniformOnBlocks(im, d)) return (scale: d, w: im.width ~/ d, h: im.height ~/ d);
  }
  return null;
}

/// Recovers the logical grid of an export whose upscale is *not* an
/// exact multiple - most editors resample to a fixed canvas (e.g. a
/// 16×16 piece exported at 415×413), leaving blocks of 25 and 26 px.
///
/// For each candidate logical width, the image is compared against its
/// own block centres, sampling only block *interiors* (a whole pixel
/// away from every estimated boundary) so the ±1 px jitter of a
/// resampled export can't fail an otherwise correct grid. The smallest
/// candidate whose interiors agree is the answer: a too-small grid
/// mixes several true blocks into one and disagrees loudly.
({int w, int h})? _approxGrid(img.Image im) {
  const maxGrid = 200;
  const margin = 1.2;
  for (var n = 8; n <= maxGrid && n * 2 <= im.width; n++) {
    final m = (im.height * n / im.width).round();
    if (m < 1 || m > maxGrid) continue;
    final bw = im.width / n, bh = im.height / m;
    if (bw < 2.5 || bh < 2.5) break;
    var mismatched = 0, sampled = 0;
    for (var sy = 0; sy < im.height; sy += 2) {
      final fy = sy / bh;
      if ((fy - fy.floor()) * bh < margin || (fy.ceil() - fy) * bh < margin) continue;
      final cy = ((fy.floor() + 0.5) * bh).floor();
      for (var sx = 0; sx < im.width; sx += 2) {
        final fx = sx / bw;
        if ((fx - fx.floor()) * bw < margin || (fx.ceil() - fx) * bw < margin) continue;
        sampled++;
        if (im.getPixel(sx, sy) != im.getPixel(((fx.floor() + 0.5) * bw).floor(), cy)) mismatched++;
      }
    }
    if (sampled > 500 && mismatched / sampled < 0.01) return (w: n, h: m);
  }
  return null;
}

/// A recovered logical grid plus how to sample it: logical pixel
/// (lx, ly) lives at source block `[ox + lx*bw, ox + (lx+1)*bw)` - the
/// offsets may be negative when the canvas isn't grid-aligned.
typedef Grid = ({int w, int h, double bw, double bh, double ox, double oy});

/// Recovers a grid whose upscale is an exact integer but whose canvas
/// is *not* a multiple of it - an art panel exported onto a padded or
/// cropped canvas (the clown: 6px blocks on a 770×763 sheet). The block
/// size is the GCD of same-colour run lengths; the phase is where the
/// colour boundaries actually fall.
Grid? _offsetGrid(img.Image im) {
  int runGcd(bool horizontal) {
    var g = 0;
    final lines = 24;
    for (var i = 1; i <= lines; i++) {
      final runs = <int>[];
      var run = 1;
      final limit = horizontal ? im.width : im.height;
      final fixed = (horizontal ? im.height : im.width) * i ~/ (lines + 1);
      img.Pixel at(int v) => horizontal ? im.getPixel(v, fixed) : im.getPixel(fixed, v);
      for (var v = 1; v < limit; v++) {
        if (at(v) == at(v - 1)) {
          run++;
        } else {
          runs.add(run);
          run = 1;
        }
      }
      // Drop the first and last run of every line: canvas-edge blocks
      // are partial and would drag the GCD to 1.
      for (final r in runs.skip(1).take(math.max(0, runs.length - 2))) {
        g = _gcd(g, r);
      }
    }
    return g;
  }

  int phase(bool horizontal, int s) {
    final votes = <int, int>{};
    final lines = 24;
    for (var i = 1; i <= lines; i++) {
      final limit = horizontal ? im.width : im.height;
      final fixed = (horizontal ? im.height : im.width) * i ~/ (lines + 1);
      img.Pixel at(int v) => horizontal ? im.getPixel(v, fixed) : im.getPixel(fixed, v);
      for (var v = 1; v < limit; v++) {
        if (at(v) != at(v - 1)) votes[v % s] = (votes[v % s] ?? 0) + 1;
      }
    }
    if (votes.isEmpty) return 0;
    return (votes.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).first.key;
  }

  final sx = runGcd(true), sy = runGcd(false);
  if (sx < 3 || sx != sy) return null;
  final s = sx;
  // Left edge of block 0, pulled non-positive so block indices start at 0.
  final ox = (phase(true, s) % s) - s;
  final oy = (phase(false, s) % s) - s;
  final w = ((im.width - ox) / s).ceil();
  final h = ((im.height - oy) / s).ceil();
  if (w < 8 || h < 8 || w > 400 || h > 400) return null;

  // Verify: sampled pixels must agree with their block centre.
  final g = (w: w, h: h, bw: s.toDouble(), bh: s.toDouble(), ox: ox.toDouble(), oy: oy.toDouble());
  var mismatched = 0, sampled = 0;
  for (var y = 0; y < im.height; y += 3) {
    for (var x = 0; x < im.width; x += 3) {
      sampled++;
      final lx = ((x - ox) / s).floor(), ly = ((y - oy) / s).floor();
      if (im.getPixel(x, y) != _sampleAt(im, g, lx, ly)) mismatched++;
    }
  }
  if (mismatched / sampled > 0.02) return null;
  return g;
}

/// Best-effort grid: exact when the export is a clean multiple,
/// recovered from block interiors when it is resampled, recovered from
/// run lengths and phase when the canvas is simply not grid-aligned.
Grid? _anyGrid(img.Image im) {
  final exact = _logicalGrid(im);
  // An "exact" grid at scale 1 just means no upscale was detected -
  // give the other detectors a chance to find the real one.
  if (exact != null && exact.scale > 1) {
    final s = exact.scale.toDouble();
    return (w: exact.w, h: exact.h, bw: s, bh: s, ox: 0, oy: 0);
  }
  final approx = _approxGrid(im);
  if (approx != null) {
    return (
      w: approx.w,
      h: approx.h,
      bw: im.width / approx.w,
      bh: im.height / approx.h,
      ox: 0,
      oy: 0,
    );
  }
  final offset = _offsetGrid(im);
  if (offset != null) return offset;
  if (exact == null) return null;
  return (w: exact.w, h: exact.h, bw: 1, bh: 1, ox: 0, oy: 0);
}

/// Centre crop, in logical pixels, to a square of the shorter side.
Grid _cropSquare(Grid g) {
  final side = math.min(g.w, g.h);
  final dx = (g.w - side) ~/ 2, dy = (g.h - side) ~/ 2;
  return (w: side, h: side, bw: g.bw, bh: g.bh, ox: g.ox + dx * g.bw, oy: g.oy + dy * g.bh);
}

/// Decimation by an integer factor, expressed on the same grid record:
/// the blocks just get [factor] times bigger.
Grid _decimate(Grid g, int factor) => (
  w: (g.w / factor).ceil(),
  h: (g.h / factor).ceil(),
  bw: g.bw * factor,
  bh: g.bh * factor,
  ox: g.ox,
  oy: g.oy,
);

/// Samples the colour of logical pixel ([lx], [ly]) at its block centre.
img.Pixel _sampleAt(img.Image im, Grid g, int lx, int ly) {
  final cx = (g.ox + (lx + 0.5) * g.bw).floor().clamp(0, im.width - 1);
  final cy = (g.oy + (ly + 0.5) * g.bh).floor().clamp(0, im.height - 1);
  return im.getPixel(cx, cy);
}

int _gcd(int a, int b) => b == 0 ? a : _gcd(b, a % b);

bool _uniformOnBlocks(img.Image im, int d) {
  for (var by = 0; by < im.height; by += d) {
    for (var bx = 0; bx < im.width; bx += d) {
      final first = im.getPixel(bx, by);
      for (var y = by; y < by + d; y++) {
        for (var x = bx; x < bx + d; x++) {
          if (im.getPixel(x, y) != first) return false;
        }
      }
    }
  }
  return true;
}

String _hex(img.Pixel p) =>
    '#${p.r.toInt().toRadixString(16).padLeft(2, '0')}'
    '${p.g.toInt().toRadixString(16).padLeft(2, '0')}'
    '${p.b.toInt().toRadixString(16).padLeft(2, '0')}';

void _survey(Directory dir) {
  final rows = <String>[];
  final files = dir.listSync().whereType<File>().where((f) => f.path.toLowerCase().endsWith('.png')).toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final f in files) {
    final im = img.decodePng(f.readAsBytesSync());
    if (im == null) {
      rows.add('${f.uri.pathSegments.last.padRight(44)} (not decodable)');
      continue;
    }
    final g = _anyGrid(im);
    if (g == null) {
      rows.add('${f.uri.pathSegments.last.padRight(44)} (no grid recovered)');
      continue;
    }
    var opaque = 0;
    final colors = <String>{};
    for (var y = 0; y < g.h; y++) {
      for (var x = 0; x < g.w; x++) {
        final p = _sampleAt(im, g, x, y);
        if (p.a >= _alphaFloor) {
          opaque++;
          colors.add(_hex(p));
        }
      }
    }
    final exact = g.ox == 0 && g.oy == 0 && g.bw == g.bw.roundToDouble() ? 'exact ' : 'approx';
    rows.add(
      '${f.uri.pathSegments.last.padRight(44)} '
      '${'${g.w}x${g.h}'.padRight(9)} $exact px=${'$opaque'.padRight(5)} colors=${colors.length}',
    );
  }
  rows.forEach(print);
}

void _emit(File f) {
  final im = img.decodePng(f.readAsBytesSync());
  if (im == null) {
    stderr.writeln('${f.path}: not decodable');
    exitCode = 1;
    return;
  }
  final g = _logicalGrid(im);
  if (g == null) {
    stderr.writeln('${f.path}: no uniform grid found');
    exitCode = 1;
    return;
  }
  final shadows = <String>[];
  for (var y = 0; y < g.h; y++) {
    for (var x = 0; x < g.w; x++) {
      final p = im.getPixel(x * g.scale, y * g.scale);
      if (p.a >= _alphaFloor) shadows.add('${x + 1}em ${y + 1}em ${_hex(p)}');
    }
  }
  final name = f.uri.pathSegments.last
      .replaceAll(RegExp(r'\.png$', caseSensitive: false), '')
      .replaceAll(RegExp(r'[^a-zA-Z0-9]+'), '-')
      .toLowerCase();
  print('/* ${f.uri.pathSegments.last}: ${g.w}x${g.h}, ${shadows.length} px */');
  print('.pix-$name {');
  print('  width: 1em; height: 1em;');
  print('  box-shadow: ${shadows.join(', ')};');
  print('}');
  print('');
}

/// The pieces PIX broadcasts, in rail order - the visible identifier
/// (`pixel-art-1`, `pixel-art-2`, ...) is this list's position, so the
/// order here is the order on the dial. The slug is the *stable* id:
/// it keys the solved-puzzle record in localStorage and the reward GIF
/// filename, so renumbering is free but renaming a slug orphans both.
///
/// A piece with a gif gets it copied to `web/pixel/<slug>.gif` by
/// `--dart`, renamed so no working filename ships.
///
/// Not listed, and why:
///   - clown octobit #1 wide(1).png: the desktop-wallpaper recut of the
///     clone; its centre square puts the clown off-centre, so the
///     clone - the square composition the artist actually made - is
///     the one shipped.
///   - theme park octobit.png: the same image as octobit2 at 2x.
const _manifest = <String, ({String png, String? gif})>{
  'krumm': (png: 'assets/pixel-art/ahh real monsters krumm octobit.png', gif: null),
  'arbol': (png: 'assets/pixel-art/arbol1.png', gif: null),
  'astronaut': (png: 'assets/pixel-art/astronaut octobit.png', gif: 'assets/pixel-art/astronaut octobit.gif'),
  'baby': (png: 'assets/pixel-art/baby octobit 16.png', gif: 'assets/pixel-art/babys octobit 16.gif'),
  'witch': (png: 'assets/pixel-art/bad witch octobit-2.png', gif: null),
  'brothers': (png: 'assets/pixel-art/band of broters1.png', gif: 'assets/pixel-art/band of brothers1.gif'),
  'brothers2': (png: 'assets/pixel-art/band of brothers 2.png', gif: null),
  'biberon': (png: 'assets/pixel-art/biberon.png', gif: null),
  'fort': (png: 'assets/pixel-art/blanket fort octobit.png', gif: null),
  'demon': (png: 'assets/pixel-art/boss demon.png', gif: null),
  'butterflies': (png: 'assets/pixel-art/butterflies octobit.png', gif: null),
  'cake': (png: 'assets/pixel-art/cake octobit3.png', gif: 'assets/pixel-art/cake octobit.gif'),
  'carro': (png: 'assets/pixel-art/carro1.png', gif: 'assets/pixel-art/carro1.gif'),
  'city': (png: 'assets/pixel-art/city.png', gif: null),
  'claustrofobia': (png: 'assets/pixel-art/claustrofobia1.png', gif: 'assets/pixel-art/claustrofobia.gif'),
  'cult': (png: 'assets/pixel-art/cult octobit 18.png', gif: 'assets/pixel-art/cult octobit 18.gif'),
  'haunted': (png: 'assets/pixel-art/haunted tree house octobit #7-2.png', gif: null),
  'doll': (
    png: 'assets/pixel-art/issues doll octobit clone clone.png',
    gif: 'assets/pixel-art/issues doll octobit clone clone.gif',
  ),
  'roadtrip': (
    png: 'assets/pixel-art/killing road trip octobit.png',
    gif: 'assets/pixel-art/killing road trip octobit.gif',
  ),
  'legs': (png: 'assets/pixel-art/legs octobit.png', gif: null),
  'mono': (png: 'assets/pixel-art/monocromatic clone clone.png', gif: null),
  'pizza': (png: 'assets/pixel-art/mushroom pizza octobit.png', gif: null),
  'munequita': (png: 'assets/pixel-art/muñequita.png', gif: null),
  'playground': (
    png: 'assets/pixel-art/playground isolation octobit.png',
    gif: 'assets/pixel-art/playground isolation octobit.gif',
  ),
  'soup': (png: 'assets/pixel-art/poison soup octobit.png', gif: 'assets/pixel-art/poison soup octobit.gif'),
  'predator': (png: 'assets/pixel-art/predator octobit.png', gif: 'assets/pixel-art/predator octobit.gif'),
  'retrato': (png: 'assets/pixel-art/retrato-00.png', gif: null),
  'rotten': (png: 'assets/pixel-art/rotten fresh octobit - 1.png', gif: 'assets/pixel-art/rotten fresh octobit.gif'),
  'sentado': (png: 'assets/pixel-art/sentado mirando clone clone(1).png', gif: null),
  'shark': (png: 'assets/pixel-art/shark1.png', gif: 'assets/pixel-art/shark.gif'),
  'sushi': (png: 'assets/pixel-art/sushi rice octobit.png', gif: null),
  'themepark': (png: 'assets/pixel-art/theme park octobit2.png', gif: null),
  'thorns': (png: 'assets/pixel-art/thorns octobit.png', gif: 'assets/pixel-art/thorns octobit.gif'),
  'clown': (png: 'assets/pixel-art/clown octobit #1 clone.png', gif: 'assets/pixel-art/clown octobit #1 clone.gif'),
};

/// Pieces cut to a centred square before shipping (the clown's canvas
/// is one logical column off square).
const _squareCrop = {'clown'};

/// Pieces exempt from [_maxShipGrid] decimation. The clown's scene
/// hangs on 1-logical-pixel lines - the floor grid, the bench curls -
/// and nearest-neighbour decimation shreds exactly those, so it ships
/// at its native grid and pays its own weight.
const _fullRes = {'clown'};

/// Largest sprite grid shipped. A bigger piece is decimated by an
/// integer factor - on screen the puzzle is ~300px and the thumbnails
/// 64px, so grid past this is bundle weight with nothing to show for
/// it, and the reward GIF carries the full-resolution art anyway.
const _maxShipGrid = 80;

/// Regenerates `lib/models/pixel_art.dart` (piece metadata, always
/// loaded) and `lib/models/pixel_art_shadows.dart` (the heavy shadow
/// strings, loaded *deferred* only when the dial approaches PIX), and
/// copies each piece's reward GIF to `web/pixel/<slug>.gif`.
void _emitDart() {
  final out = StringBuffer()
    ..writeln('// GENERATED by tool/generate_pixel_css.dart - do not edit by hand.')
    ..writeln('// Regenerate with: dart run tool/generate_pixel_css.dart --dart')
    ..writeln('//')
    ..writeln('// Metadata only - the shadow strings live in pixel_art_shadows.dart,')
    ..writeln('// which is imported *deferred* so dart2js splits it into its own')
    ..writeln('// part file, downloaded only when the dial approaches AM 1440.')
    ..writeln('library;')
    ..writeln()
    ..writeln('class PixelSprite {')
    ..writeln('  const PixelSprite({')
    ..writeln('    required this.id,')
    ..writeln('    required this.gridW,')
    ..writeln('    required this.gridH,')
    ..writeln('    required this.hasGif,')
    ..writeln('  });')
    ..writeln()
    ..writeln('  final String id;')
    ..writeln('  final int gridW;')
    ..writeln('  final int gridH;')
    ..writeln()
    ..writeln('  /// Every piece has a full-quality reward file under `web/pixel/`,')
    ..writeln('  /// revealed on completing its puzzle: `<id>.gif` (the animated')
    ..writeln('  /// original) when this is true, `<id>.png` otherwise.')
    ..writeln('  final bool hasGif;')
    ..writeln('}')
    ..writeln()
    ..writeln('/// Rail order. The visible identifier pixel-art-N is index + 1.')
    ..writeln('const pixelArtPieces = <PixelSprite>[');
  final shadowsOut = StringBuffer()
    ..writeln('// GENERATED by tool/generate_pixel_css.dart - do not edit by hand.')
    ..writeln('// Regenerate with: dart run tool/generate_pixel_css.dart --dart')
    ..writeln('//')
    ..writeln('// Each sprite is a 1em × 1em element whose box-shadow places every')
    ..writeln('// opaque pixel at (x+1)em (y+1)em - offset by one because a 0,0')
    ..writeln('// shadow is clipped behind the element\'s own border box. Set the')
    ..writeln('// font-size to the on-screen pixel size and shift the element up-left')
    ..writeln('// by 1em inside a gridW×gridH em frame.')
    ..writeln('//')
    ..writeln('// This library is imported ONLY with `deferred as` (see')
    ..writeln('// pixel_gallery.dart) - a plain import would pull the whole megabyte')
    ..writeln('// back into the initial bundle.')
    ..writeln('library;')
    ..writeln()
    ..writeln('/// Box-shadow string per piece id, applied as inline styles - never')
    ..writeln('/// as stylesheet rules, so the prerendered HTML stays small too.')
    ..writeln('const pixelShadows = <String, String>{');
  var totalShadows = 0;
  final gifDir = Directory('web/pixel');
  for (final MapEntry(key: id, value: piece) in _manifest.entries) {
    final im = img.decodePng(File(piece.png).readAsBytesSync());
    if (im == null) {
      stderr.writeln('${piece.png}: not decodable');
      exitCode = 1;
      return;
    }
    var g = _anyGrid(im);
    if (g == null) {
      stderr.writeln('${piece.png}: no grid recovered');
      exitCode = 1;
      return;
    }
    final cropped = _squareCrop.contains(id);
    if (cropped) g = _cropSquare(g);
    final factor = _fullRes.contains(id) ? 1 : ((math.max(g.w, g.h) - 1) ~/ _maxShipGrid) + 1;
    final src =
        '${g.w}x${g.h}'
        '${cropped ? ' square-cropped' : ''}'
        '${factor == 1 ? '' : ' decimated ${factor}x'}';
    if (factor > 1) g = _decimate(g, factor);
    final shadows = <String>[];
    for (var y = 0; y < g.h; y++) {
      for (var x = 0; x < g.w; x++) {
        final p = _sampleAt(im, g, x, y);
        if (p.a >= _alphaFloor) shadows.add('${x + 1}em ${y + 1}em ${_hex(p)}');
      }
    }
    totalShadows += shadows.length;
    // Every piece has a full-quality reward file, revealed only on
    // completion: the animated gif when one exists, the original png
    // otherwise. The shipped sprite may be decimated for weight, so
    // without this a gif-less piece would finish at reduced detail -
    // the one moment the art must look exactly right.
    if (!gifDir.existsSync()) gifDir.createSync(recursive: true);
    if (piece.gif != null) {
      File(piece.gif!).copySync('web/pixel/$id.gif');
    } else {
      File(piece.png).copySync('web/pixel/$id.png');
    }
    out
      ..writeln('  // ${piece.png} ($src, ${shadows.length} px)')
      ..writeln("  PixelSprite(id: '$id', gridW: ${g.w}, gridH: ${g.h}, hasGif: ${piece.gif != null}),");
    shadowsOut.writeln("  '$id': '${shadows.join(', ')}',");
  }
  out.writeln('];');
  shadowsOut.writeln('};');
  File('lib/models/pixel_art.dart').writeAsStringSync(out.toString());
  File('lib/models/pixel_art_shadows.dart').writeAsStringSync(shadowsOut.toString());
  final gifs = _manifest.values.where((p) => p.gif != null).length;
  stdout.writeln(
    'Wrote lib/models/pixel_art.dart + pixel_art_shadows.dart (${_manifest.length} sprites, $totalShadows shadows).',
  );
  stdout.writeln('Copied ${_manifest.length} reward files to web/pixel/ ($gifs gif, ${_manifest.length - gifs} png).');
}

void main(List<String> args) {
  if (args.isEmpty) {
    _survey(Directory('assets/pixel-art'));
    return;
  }
  if (args.length == 1 && args.first == '--dart') {
    _emitDart();
    return;
  }
  args.map(File.new).forEach(_emit);
}
