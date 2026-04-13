/// Generates `web/og-image.png` — a 1200x630 social preview card.
///
/// LinkedIn, Facebook and some other platforms don't reliably render SVG
/// og:images, so this produces a rasterized PNG alongside the SVG.
///
/// Run from the project root:
///   dart run tool/generate_og_image.dart
library;

import 'dart:io';

import 'package:image/image.dart';

void main() {
  const width = 1200;
  const height = 630;

  final panel = ColorRgb8(0x0a, 0x0a, 0x0c);
  final border = ColorRgb8(0x1d, 0x17, 0x12);
  final strip = ColorRgb8(0xa8, 0x7a, 0x3a);
  final stripDim = ColorRgb8(0x5a, 0x40, 0x18);
  final amber = ColorRgb8(0xe8, 0xa0, 0x35);
  final amberMuted = ColorRgb8(0x8a, 0x62, 0x20);
  final amberDeep = ColorRgb8(0x7a, 0x55, 0x10);
  final red = ColorRgb8(0xff, 0x44, 0x44);
  final redGlow = ColorRgb8(0x60, 0x18, 0x18);
  final knobBody = ColorRgb8(0x1e, 0x19, 0x16);
  final knobRim = ColorRgb8(0x2a, 0x21, 0x1c);
  final knobRing = ColorRgb8(0x4a, 0x38, 0x28);

  final img = Image(width: width, height: height);

  fill(img, color: panel);

  // Approximate radial backlight darkening toward the edges.
  for (var i = 0; i < 40; i++) {
    final t = i / 40.0;
    final alpha = (t * t * 90).round();
    final c = ColorRgba8(0, 0, 0, alpha);
    drawRect(
      img,
      x1: i * 8,
      y1: i * 5,
      x2: width - 1 - i * 8,
      y2: height - 1 - i * 5,
      color: c,
    );
  }

  // Outer border.
  drawRect(
    img,
    x1: 0,
    y1: 0,
    x2: width - 1,
    y2: height - 1,
    color: border,
    thickness: 2,
  );

  // ─ Frequency strip ───────────────────────────────────────────────────
  const stripY = 290;
  const stripX1 = 240;
  const stripX2 = 960;

  drawLine(
    img,
    x1: stripX1,
    y1: stripY,
    x2: stripX2,
    y2: stripY,
    color: strip,
    thickness: 2,
  );

  const tickCount = 6;
  const stripWidth = stripX2 - stripX1;
  const tickStep = stripWidth ~/ (tickCount - 1);
  for (var i = 0; i < tickCount; i++) {
    final x = stripX1 + i * tickStep;
    drawLine(
      img,
      x1: x,
      y1: stripY - 14,
      x2: x,
      y2: stripY,
      color: strip,
      thickness: 2,
    );
  }

  for (var i = 0; i < tickCount - 1; i++) {
    final x0 = stripX1 + i * tickStep;
    for (var j = 1; j <= 2; j++) {
      final x = x0 + (tickStep * j) ~/ 3;
      drawLine(
        img,
        x1: x,
        y1: stripY - 7,
        x2: x,
        y2: stripY,
        color: stripDim,
        thickness: 1,
      );
    }
  }

  const labels = ['88', '92', '96', '100', '104', '108'];
  final labelFont = arial14;
  for (var i = 0; i < tickCount; i++) {
    final x = stripX1 + i * tickStep;
    final label = labels[i];
    final tw = label.length * 7;
    drawString(
      img,
      label,
      font: labelFont,
      x: x - tw ~/ 2,
      y: stripY + 10,
      color: strip,
    );
  }

  // ─ RADIO wordmark: R A D (text) + I (needle) + O (knob) ─────────────
  final big = arial48;
  const radY = stripY - 36;
  const letterStep = 90;
  final centerX = (stripX1 + stripX2) ~/ 2;
  final slotXs = [
    centerX - 2 * letterStep,
    centerX - 1 * letterStep,
    centerX,
    centerX + 1 * letterStep,
    centerX + 2 * letterStep,
  ];

  const rad = ['R', 'A', 'D'];
  for (var i = 0; i < 3; i++) {
    final ch = rad[i];
    final x = slotXs[i] - 14;
    drawString(img, ch, font: big, x: x, y: radY, color: amber);
  }

  // Knob in place of "O".
  final knobX = slotXs[4];
  const knobY = stripY;
  fillCircle(img, x: knobX, y: knobY, radius: 38, color: knobBody);
  drawCircle(img, x: knobX, y: knobY, radius: 38, color: knobRim);
  drawCircle(img, x: knobX, y: knobY, radius: 37, color: knobRim);
  drawCircle(img, x: knobX, y: knobY, radius: 36, color: knobRing);
  drawLine(
    img,
    x1: knobX,
    y1: knobY - 30,
    x2: knobX,
    y2: knobY - 16,
    color: amber,
    thickness: 4,
  );

  // Needle in place of "I" with a soft red glow halo.
  final needleX = slotXs[3];
  fillRect(
    img,
    x1: needleX - 6,
    y1: stripY - 48,
    x2: needleX + 6,
    y2: stripY + 28,
    color: redGlow,
  );
  fillRect(
    img,
    x1: needleX - 3,
    y1: stripY - 50,
    x2: needleX + 3,
    y2: stripY + 30,
    color: red,
  );

  // ─ Tagline ───────────────────────────────────────────────────────────
  final medium = arial24;
  const tagline = 'RAFAEL CAMARGO  —  SOFTWARE ENGINEER';
  final taglineWidth = tagline.length * 13;
  drawString(
    img,
    tagline,
    font: medium,
    x: (width - taglineWidth) ~/ 2,
    y: 470,
    color: amberMuted,
  );

  const domain = 'rafahcf.com';
  final domainWidth = domain.length * 13;
  drawString(
    img,
    domain,
    font: medium,
    x: (width - domainWidth) ~/ 2,
    y: 540,
    color: amberDeep,
  );

  final out = File('web/og-image.png');
  out.writeAsBytesSync(encodePng(img));
  stdout.writeln('Wrote ${out.path} (${out.lengthSync()} bytes)');
}
