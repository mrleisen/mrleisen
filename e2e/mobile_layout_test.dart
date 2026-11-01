// Layout regression tests for phones: no station panel, and no printout,
// may ever run underneath the faceplate.
//
// They drive the *built* site in a real Chrome, because the bug they guard
// against only exists in a browser's layout engine: on a phone the station
// panels used to be positioned in one frame and the faceplate in another,
// and the bottom of every long panel ended up under the dial - partly
// reachable by scrolling, or not at all.
//
//   jaspr build
//   dart test e2e
//
// Chrome is found through `CHROME_PATH`; without it puppeteer downloads its
// own Chromium on first run.
@Timeout(Duration(minutes: 6))
library;

import 'dart:convert';
import 'dart:io';

import 'package:puppeteer/puppeteer.dart';
import 'package:test/test.dart';

/// Every station, saved as a preset, so the preset rack is showing and the
/// faceplate is at its tallest - the worst case for the room above it.
/// Keys match `AppState._stationKey` as compiled to JS, where `540.0`
/// prints as `540`.
const _allPresets = [
  'fm:88.9', 'fm:91.9', 'fm:94.9', 'fm:97.9', 'fm:100.9', 'fm:103.9', 'fm:106.9', //
  'am:540', 'am:660', 'am:820', 'am:1000', 'am:1120', 'am:1280', 'am:1440', 'am:1600',
];

/// CSS-pixel viewports of real phones *with their browser chrome showing*,
/// which is the state a visitor actually sees and the one that broke.
const _phones = <String, (int, int)>{
  'iPhone SE, Safari toolbars': (375, 548),
  'iPhone 13, Safari bottom bar': (390, 664),
  'Pixel 7, Chrome URL bar': (412, 780),
  'small Android, Chrome URL bar': (360, 560),
  'phone landscape': (667, 340),
};

/// How far a box may poke past an edge before it counts, for sub-pixel
/// rounding and nothing else.
const _epsilon = 1.0;

late HttpServer _server;
late Browser _browser;

String get _url => 'http://127.0.0.1:${_server.port}/';

void main() {
  setUpAll(() async {
    final root = Directory('build/jaspr');
    if (!File('${root.path}/index.html').existsSync()) {
      fail('build/jaspr/index.html is missing. Run `jaspr build` before `dart test e2e`.');
    }
    _server = await _serve(root);
    _browser = await puppeteer.launch(
      executablePath: Platform.environment['CHROME_PATH'],
      noSandboxFlag: true,
    );
  });

  tearDownAll(() async {
    await _browser.close();
    await _server.close(force: true);
  });

  for (final MapEntry(key: name, value: (w, h)) in _phones.entries) {
    test('$name ($w×$h): every station panel stays above the faceplate', () async {
      final page = await _openPoweredOn(w, h);
      try {
        final failures = <String>[];
        final count = await page.evaluate<int>('() => document.querySelectorAll(".collected-pill").length');
        expect(count, _allPresets.length, reason: 'every preset should be in the rack');
        for (var i = 0; i < count; i++) {
          final report = await _recallAndMeasure(page, i);
          failures.addAll(report);
        }
        expect(failures, isEmpty, reason: failures.join('\n'));
      } finally {
        await page.close();
      }
    });
  }

  // The reproduction of the reported bug. A phone's browser toolbar puts
  // the document's frame and the viewport's frame (the one `position:
  // fixed` uses) out of step, and desktop Chrome has no toolbar to do
  // that with, so the offset is applied directly: the document is pushed
  // 56 px - one toolbar - away from the viewport. With the content laid
  // out in one frame and the faceplate in the other, every long panel
  // ran 56 px under the dial. Sharing one frame, nothing moves.
  for (final MapEntry(key: name, value: (w, h)) in _phones.entries.take(4)) {
    test('$name ($w×$h), document offset by a toolbar: panels stay above the faceplate', () async {
      final page = await _openPoweredOn(w, h, documentOffset: 56);
      try {
        final failures = <String>[];
        for (var i = 0; i < _allPresets.length; i++) {
          failures.addAll(await _recallAndMeasure(page, i));
        }
        expect(failures, isEmpty, reason: failures.join('\n'));
      } finally {
        await page.close();
      }
    });
  }

  test('the panel follows the browser toolbar sliding in and out', () async {
    // A mobile URL bar showing or hiding changes the viewport height after
    // load without changing the faceplate. The panel has to keep up.
    final page = await _openPoweredOn(390, 750);
    try {
      final dtu = _allPresets.indexOf('fm:97.9'); // the longest panel
      final failures = <String>[];
      failures.addAll(await _recallAndMeasure(page, dtu));
      for (final h in [664, 750, 600, 664]) {
        await page.setViewport(
          DeviceViewport(width: 390, height: h, deviceScaleFactor: 2, isMobile: true, hasTouch: true),
        );
        await Future<void>.delayed(const Duration(milliseconds: 400));
        failures.addAll((await _measureVisible(page)).map((f) => '[height $h] $f'));
      }
      expect(failures, isEmpty, reason: failures.join('\n'));
    } finally {
      await page.close();
    }
  });

  for (final MapEntry(key: name, value: (w, h)) in _phones.entries.take(2)) {
    test('$name: the WHO printout ends above the faceplate', () async {
      final page = await _openPoweredOn(w, h);
      try {
        await _recallAndMeasure(page, _allPresets.indexOf('fm:94.9'));
        await page.evaluate('() => document.getElementById("tech-trigger").click()');
        await page.waitForSelector('.rx-panel', timeout: const Duration(seconds: 5));
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final r = await page.evaluate<Map<dynamic, dynamic>>('''() => {
          const p = document.querySelector('.rx-panel');
          p.scrollTop = p.scrollHeight;
          const b = p.getBoundingClientRect();
          return {
            top: b.top,
            bottom: b.bottom,
            dial: document.querySelector('.radio-panel').getBoundingClientRect().top,
            reachedEnd: Math.abs(p.scrollTop + p.clientHeight - p.scrollHeight) <= 1,
          };
        }''');
        expect(r['top'] as num, greaterThanOrEqualTo(-_epsilon), reason: 'printout starts above the screen');
        expect(
          r['bottom'] as num,
          lessThanOrEqualTo((r['dial'] as num) + _epsilon),
          reason: 'printout bottom ${r['bottom']} runs under the faceplate at ${r['dial']}',
        );
        expect(r['reachedEnd'], isTrue, reason: 'printout cannot be scrolled to its end');
      } finally {
        await page.close();
      }
    });
  }
}

/// A fresh page at a phone viewport, every station saved, radio on.
///
/// [documentOffset] pushes the document's frame that many pixels away from
/// the viewport's, the way a mobile browser's toolbar does.
Future<Page> _openPoweredOn(int width, int height, {int documentOffset = 0}) async {
  final page = await _browser.newPage();
  final viewport = DeviceViewport(width: width, height: height, deviceScaleFactor: 2, isMobile: true, hasTouch: true);
  await page.setViewport(viewport);
  await page.goto(_url, wait: Until.networkIdle);
  await page.evaluate(
    '(v) => localStorage.setItem("rchf:collected_stations", v)',
    args: [_allPresets.join(',')],
  );
  await page.reload(wait: Until.networkIdle);
  if (documentOffset != 0) {
    await page.addStyleTag(content: 'body { margin-top: ${documentOffset}px !important; }');
  }
  await page.click('.power-rocker');
  // CRT warm-up, signal scan and the first faceplate measurement.
  await page.waitForSelector('.crt-on-done', timeout: const Duration(seconds: 10));
  await Future<void>.delayed(const Duration(milliseconds: 600));
  return page;
}

/// Recalls preset [index] the way a keyboard user would, waits for the
/// panel to lock and settle, and returns every way it is unreadable.
Future<List<String>> _recallAndMeasure(Page page, int index) async {
  await page.evaluate(
    '''(i) => {
      const pill = document.querySelectorAll('.collected-pill')[i];
      pill.focus();
      pill.dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter', bubbles: true}));
    }''',
    args: [index],
  );
  // 700 ms dial tween, then the panel fade and the staggered reveal.
  await Future<void>.delayed(const Duration(milliseconds: 1700));
  return _measureVisible(page, label: _allPresets[index]);
}

/// Checks the locked panel against the faceplate:
///
///  1. the panel's box starts on screen and ends above the faceplate, so
///     nothing it shows is ever behind the radio;
///  2. scrolled to its end, the scroll actually gets there;
///  3. the very bottom of its content, at that point, is the topmost thing
///     on screen - the check a thumb does.
Future<List<String>> _measureVisible(Page page, {String? label}) async {
  final raw = await page.evaluate<String>('''() => {
    const p = document.querySelector('.station-panel.is-visible');
    if (!p) return JSON.stringify({missing: true});
    p.scrollTop = p.scrollHeight;
    const b = p.getBoundingClientRect();
    const dial = document.querySelector('.radio-panel').getBoundingClientRect().top;
    // Lowest rendered element inside the panel, after scrolling to the end.
    let lowest = null;
    for (const el of p.querySelectorAll('*')) {
      const r = el.getBoundingClientRect();
      if (r.width === 0 || r.height === 0) continue;
      if (!lowest || r.bottom > lowest.r.bottom) lowest = {el, r};
    }
    let hit = true, hitWhat = '';
    if (lowest) {
      const r = lowest.r;
      const x = Math.min(Math.max(r.left + r.width / 2, 1), innerWidth - 1);
      const y = Math.min(r.bottom - 2, innerHeight - 1);
      const top = document.elementFromPoint(x, y);
      hit = !!top && (p.contains(top) || top === p);
      hitWhat = top ? (top.className || top.tagName) + '' : 'nothing';
    }
    return JSON.stringify({
      station: p.className.split(' ').find(c => c.startsWith('station-') && c !== 'station-panel'),
      top: b.top, bottom: b.bottom, dial,
      reachedEnd: Math.abs(p.scrollTop + p.clientHeight - p.scrollHeight) <= 1,
      lowestBottom: lowest ? lowest.r.bottom : null,
      hit, hitWhat,
    });
  }''');
  final r = jsonDecode(raw) as Map<String, dynamic>;
  final tag = '${label ?? ''} ${r['station'] ?? ''}'.trim();
  if (r['missing'] == true) return ['$tag: no station panel locked'];
  final out = <String>[];
  final top = r['top'] as num, bottom = r['bottom'] as num, dial = r['dial'] as num;
  if (top < -_epsilon) out.add('$tag: panel starts off screen (top $top)');
  if (bottom > dial + _epsilon) out.add('$tag: panel bottom $bottom runs under the faceplate at $dial');
  if (r['reachedEnd'] != true) out.add('$tag: panel cannot be scrolled to its end');
  if (r['hit'] != true) {
    out.add('$tag: bottom of the content (y ${r['lowestBottom']}) is covered by "${r['hitWhat']}"');
  }
  return out;
}

/// Serves the static build. Nothing beyond the content types Chrome needs
/// to run the scripts and load the fonts.
Future<HttpServer> _serve(Directory root) async {
  const types = {
    'html': 'text/html; charset=utf-8',
    'js': 'application/javascript',
    'css': 'text/css',
    'json': 'application/json',
    'svg': 'image/svg+xml',
    'png': 'image/png',
    'webmanifest': 'application/manifest+json',
    'woff2': 'font/woff2',
    'ogg': 'audio/ogg',
    'mp3': 'audio/mpeg',
  };
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    var path = Uri.decodeComponent(req.uri.path);
    if (path.endsWith('/')) path += 'index.html';
    final file = File('${root.path}$path');
    if (!path.contains('..') && await file.exists()) {
      final type = types[path.split('.').last];
      if (type != null) req.response.headers.set(HttpHeaders.contentTypeHeader, type);
      await req.response.addStream(file.openRead());
    } else {
      req.response.statusCode = HttpStatus.notFound;
    }
    await req.response.close();
  });
  return server;
}
