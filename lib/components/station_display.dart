import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../models/station.dart';

/// Currently-supported UI languages.
enum Lang { es, en }

/// "Decoded" content panel that fades in when the dial locks onto a
/// station. All five panels live in the same absolute slot; hidden ones
/// sit at `visibility: hidden; opacity: 0`, so switching stations never
/// causes a reflow.
///
/// Transitions are intentionally staggered: the outgoing panel fades
/// quickly (0.3 s, no delay) while the incoming panel waits 0.25 s
/// before starting its 0.5 s fade-in. That tiny gap keeps two panels
/// from reading simultaneously and matches the "catching a signal"
/// feel of the rest of the experience.
///
/// NOTE: deliberately NOT marked `@client`. The parent App is already a
/// client island; nesting another `@client` here would create a second
/// hydration island whose markers break the outer island's hydration.
class StationDisplay extends StatelessComponent {
  const StationDisplay({
    required this.frequency,
    required this.band,
    required this.lang,
    this.isPowered = true,
    super.key,
  });

  final double frequency;
  final Band band;
  final Lang lang;

  /// When false every panel collapses to opacity 0 and skips the
  /// distortion animations so nothing runs behind the CRT-off overlay.
  final bool isPowered;

  /// Identify which (if any) station's panel should be active on the
  /// active band. Stations within a band sit far enough apart that at
  /// most one is ever inside [BandConfig.tolerance] of the dial.
  Station? _pickVisible() {
    final cfg = configFor(band);
    Station? best;
    var bestDist = double.infinity;
    for (final s in stationsFor(band)) {
      final d = (frequency - s.frequency).abs();
      if (d < bestDist && d < cfg.tolerance) {
        bestDist = d;
        best = s;
      }
    }
    return best;
  }

  @override
  Component build(BuildContext context) {
    final visible = _pickVisible();
    return div(classes: 'station-display', [
      // Only render panels for stations on the active band — switching
      // bands mounts a fresh set of panels, keeping the visibility
      // transition logic per-panel simple.
      for (final s in stationsFor(band))
        _stationPanel(
          station: s,
          isVisible: isPowered && visible?.callSign == s.callSign,
          distance: (frequency - s.frequency).abs(),
          lang: lang,
        ),
    ]);
  }

  Component _stationPanel({
    required Station station,
    required bool isVisible,
    required double distance,
    required Lang lang,
  }) {
    // Opacity + distortion curves:
    //   d ≤ lockRange   → opacity 1.0, distortion 0 (clean lock)
    //   d  <  tolerance → opacity 1.0→0.3, distortion 0→1 (glitch zone)
    //   d ≥ tolerance   → panel hidden
    final cfg = configFor(station.band);
    double opacity;
    double distortion;
    if (!isPowered) {
      opacity = 0.0;
      distortion = 0.0;
    } else if (distance <= cfg.lockRange) {
      opacity = 1.0;
      distortion = 0.0;
    } else if (distance < cfg.tolerance) {
      final t = (distance - cfg.lockRange) / (cfg.tolerance - cfg.lockRange);
      opacity = 1.0 - t * 0.7; // 1.0 → 0.3
      distortion = t; // 0 → 1
    } else {
      opacity = 0.0;
      distortion = 0.0;
    }

    // Only attach the heavy glitch animations when there's actually
    // distortion to render — keeps the idle (clean-lock) panel free of
    // running animations.
    final animated = isVisible && distortion > 0.02;
    // Faster animation periods when distortion is high → more chaotic.
    final tearDur = (2.8 - distortion * 1.6).toStringAsFixed(2);
    final jitterDur = (0.6 - distortion * 0.4).toStringAsFixed(2);
    final flickerDur = (1.4 - distortion * 0.9).toStringAsFixed(2);

    // Station colour propagated through the subtree as CSS custom
    // properties so labels / titles / pills / cards can all glow with
    // it without each needing an inline style.
    final sc = station.color;
    final scGlow = '${sc}55'; // ~33% alpha — primary glow
    final scGlowDim = '${sc}26'; // ~15% alpha — soft halo

    return div(
      classes: 'station-panel station-${station.callSign.toLowerCase()} '
          'band-${station.band.name}'
          '${isVisible ? ' is-visible' : ''}',
      styles: Styles(
        opacity: opacity,
        raw: {
          '--distortion': distortion.toStringAsFixed(3),
          '--sc': sc,
          '--sc-glow': scGlow,
          '--sc-glow-dim': scGlowDim,
          'visibility': isVisible ? 'visible' : 'hidden',
          'transform': 'translate(-50%, -50%)',
        },
      ),
      [
        // Inner wrapper takes the tear + flicker + jitter animations.
        // Keeping them off the outer panel lets the outer opacity and
        // centring transform stay stable during fades.
        div(
          classes: 'panel-fx',
          styles: Styles(
            raw: animated
                ? {
                    'animation':
                        'content-tear ${tearDur}s steps(60, end) infinite, '
                            'content-jitter-x ${jitterDur}s steps(8, end) infinite, '
                            'content-flicker ${flickerDur}s steps(8, end) infinite',
                  }
                : {'animation': 'none'},
          ),
          [_contentFor(station, lang)],
        ),
      ],
    );
  }

  // ── per-station content ──

  Component _contentFor(Station s, Lang lang) {
    switch (s.callSign) {
      case 'WHO':
        return _aboutPanel(s, lang);
      case 'UIS':
        return _detodouisPanel(s, lang);
      case 'NET':
        return _connectPanel(s, lang);
      case 'ITN':
        return _itnwPanel(s, lang);
      case 'BBL':
        return _bblPanel(s, lang);
      case 'TRP':
        return _tropPanel(s, lang);
      case 'AWS':
        return _awsPanel(s, lang);
      case 'NFT':
        return _nftPanel(s, lang);
      case 'PNK':
        return _pnkPanel(s, lang);
    }
    return div([]);
  }

  /// Uniform station label ("FM 95.7 — decoded transmission" /
  /// "AM 620 — decoded transmission") derived from the station's band
  /// and frequency. Keeps per-panel boilerplate minimal and ensures
  /// labels update automatically if a station moves on the band plan.
  String _stationLabel(Station s, Lang lang) {
    final unit = s.band == Band.fm ? 'MHz' : 'kHz';
    final freq = s.band == Band.fm
        ? s.frequency.toStringAsFixed(1)
        : s.frequency.toInt().toString();
    final bandStr = s.band.name.toUpperCase();
    final suffix = lang == Lang.es
        ? 'transmisión decodificada'
        : 'decoded transmission';
    return '$bandStr $freq $unit — $suffix';
  }

  Component _aboutPanel(Station s, Lang lang) {
    final body = lang == Lang.es
        ? 'Ingeniero de software con más de 8 años de experiencia. '
            'Construyo cosas — como este sitio. Este sitio fue construido '
            'completamente en Dart, compilado a HTML estático con el '
            'framework Jaspr. Sin frameworks de JavaScript. '
            'Sin librerías externas.'
        : 'Software engineer with 8+ years of experience. '
            'I build things — like this. This site was built entirely '
            'in Dart, compiled to static HTML through the Jaspr '
            'framework. No JavaScript frameworks. No external libraries.';
    return _panelShell(
      color: s.color,
      label: _stationLabel(s, lang),
      title: 'Rafael Camargo',
      children: [
        p(classes: 'panel-body', [text(body)]),
      ],
    );
  }

  Component _detodouisPanel(Station s, Lang lang) {
    final body = lang == Lang.es
        ? 'La app de la comunidad UIS. Puntajes de corte, profesores, '
            'materias, el Oráculo y más.'
        : 'The UIS community app. Cut scores, professors, subjects, the '
            'Oracle and more.';
    return _panelShell(
      color: s.color,
      label: _stationLabel(s, lang),
      title: 'DeTodoUIS',
      children: [
        p(classes: 'panel-body', [text(body)]),
        div(classes: 'pill-row', [
          _pill(
            'App Store',
            href:
                'https://apps.apple.com/co/app/detodouis/id1640902049',
          ),
          _pill(
            'Google Play',
            href:
                'https://play.google.com/store/apps/details?id=com.rafahcf.detodouisapp',
          ),
        ]),
      ],
    );
  }

  Component _connectPanel(Station s, Lang lang) {
    final title = lang == Lang.es ? 'Conectar' : 'Connect';
    return _panelShell(
      color: s.color,
      label: _stationLabel(s, lang),
      title: title,
      children: [
        div(classes: 'pill-row', [
          _pill('GitHub', href: 'https://github.com/mrleisen'),
          _pill(
            'LinkedIn',
            href: 'https://www.linkedin.com/in/rafael-c-a6132982/',
          ),
        ]),
      ],
    );
  }

  Component _itnwPanel(Station s, Lang lang) {
    final subtitle = lang == Lang.es
        ? 'Canal de YouTube — audio inmersivo'
        : 'YouTube channel — immersive audio';
    final body = lang == Lang.es
        ? 'Exploraciones sonoras inmersivas de realidades imaginadas. '
            'Paisajes en capas, texturas narrativas y experimentos sonoros.'
        : 'Immersive audio explorations of imagined realities. '
            'Layered soundscapes, narrative textures, and sonic experiments.';
    return _panelShell(
      color: s.color,
      label: _stationLabel(s, lang),
      title: 'In This New World',
      children: [
        div(classes: 'panel-subtitle', [text(subtitle)]),
        p(classes: 'panel-body', [text(body)]),
        div(classes: 'pill-row', [
          _pill('YouTube', href: 'https://www.youtube.com/@InThisNewWorld'),
        ]),
      ],
    );
  }

  Component _tropPanel(Station s, Lang lang) {
    final subtitle = lang == Lang.es
        ? 'Personaje y universo — en desarrollo'
        : 'Character and universe — a work in progress';
    final body = lang == Lang.es
        ? 'Un personaje y su universo. Cómics, juegos, apps — lo que la '
            'historia quiera ser después.'
        : 'A character and a universe of their own. Comics, games, apps — '
            'whatever the story wants to become next.';
    return _panelShell(
      color: s.color,
      label: _stationLabel(s, lang),
      title: 'Tropelorio',
      children: [
        div(classes: 'panel-subtitle', [text(subtitle)]),
        p(classes: 'panel-body', [text(body)]),
        div(classes: 'pill-row', [
          _pill('Instagram', href: 'https://www.instagram.com/tropelorio'),
        ]),
      ],
    );
  }

  // ── AM idea-stage panels (lo-fi shell) ──

  /// Minimal AM panel: label, small title, subtitle, one-line
  /// description, optional link pill. No grids, no cards — the layout
  /// is intentionally bare to match the "unfinished idea" vibe.
  Component _amPanel({
    required Station s,
    required Lang lang,
    required String title,
    required String subtitle,
    required String body,
    String? href,
  }) {
    return div(classes: 'am-shell', [
      div(classes: 'panel-label am-label', [text(_stationLabel(s, lang))]),
      h2(classes: 'am-title', [text(title)]),
      div(classes: 'am-subtitle', [text(subtitle)]),
      p(classes: 'am-body', [text(body)]),
      if (href != null)
        div(classes: 'pill-row', [_pill('SoundCloud', href: href)]),
    ]);
  }

  Component _bblPanel(Station s, Lang lang) => _amPanel(
        s: s,
        lang: lang,
        title: 'Boom Boom Lottery',
        subtitle: lang == Lang.es ? 'Gestor de loterías' : 'Lottery manager',
        body: lang == Lang.es
            ? 'Gestor de tiquetes de lotería para MiLoto'
            : 'Lottery ticket manager for MiLoto',
      );

  Component _awsPanel(Station s, Lang lang) => _amPanel(
        s: s,
        lang: lang,
        title: 'A Wired Spine',
        subtitle:
            lang == Lang.es ? 'Experimento musical' : 'Musical experiment',
        body: lang == Lang.es
            ? 'Canciones originales'
            : 'Original music tracks',
        href: 'https://soundcloud.com/awiredspine',
      );

  Component _nftPanel(Station s, Lang lang) => _amPanel(
        s: s,
        lang: lang,
        title: 'MyNFTGenerator',
        subtitle: lang == Lang.es ? 'Concepto' : 'Concept',
        body: lang == Lang.es
            ? 'Herramienta de generación de NFTs'
            : 'NFT generation tool',
      );

  Component _pnkPanel(Station s, Lang lang) => _amPanel(
        s: s,
        lang: lang,
        title: 'PunkLLM',
        subtitle: lang == Lang.es ? 'Experimento' : 'Experiment',
        body: lang == Lang.es
            ? 'Un intento de crear un LLM punk'
            : 'An attempt to create a punk LLM',
      );

  // ── shared building blocks ──

  Component _panelShell({
    required String color,
    required String label,
    required String title,
    required List<Component> children,
  }) {
    // `color` kept in the signature for future use, but the actual
    // value propagates through the subtree as the `--sc` custom
    // property set on `.station-panel` — CSS picks it up.
    return div(classes: 'panel-shell', [
      div(classes: 'panel-label', [text(label)]),
      h2(classes: 'panel-title', [text(title)]),
      ...children,
    ]);
  }

  /// External-link pill. `href == null` means "not a real link" and
  /// renders a `#` anchor without new-tab attributes (used only as a
  /// fallback; all current pills have real URLs).
  Component _pill(String label, {String? href}) {
    if (href == null) {
      return a(classes: 'pill', href: '#', [text(label)]);
    }
    return a(
      classes: 'pill',
      href: href,
      target: Target.blank,
      attributes: {'rel': 'noopener noreferrer'},
      [text(label)],
    );
  }

  // ── styles ──

  @css
  static List<StyleRule> get styles => [
    // Container — sits in the same vertical band as the idle hero text.
    css('.station-display').styles(
      position: Position.absolute(
        top: Unit.expression('calc(50% - 100px)'),
        left: 50.percent,
      ),
      width: 100.percent,
      pointerEvents: PointerEvents.none,
      raw: {'transform': 'translateX(-50%)'},
    ),

    // Each panel is absolutely positioned within the container so all
    // five live in the same slot. Hidden panels use visibility:hidden
    // so they don't catch pointer events but also don't trigger reflow.
    // Default transition = *outgoing* (quick fade, no delay). The
    // `.is-visible` rule below overrides with a delayed fade-in so the
    // previous panel gets out of the way first.
    css('.station-panel').styles(
      position: Position.absolute(top: 50.percent, left: 50.percent),
      width: 100.percent,
      maxWidth: 560.px,
      raw: {
        'transform': 'translate(-50%, -50%)',
        'transition':
            'opacity 0.3s ease 0s, transform 0.3s ease 0s, visibility 0s linear 0.3s',
        'text-align': 'center',
        'visibility': 'hidden',
      },
    ),
    css('.station-panel.is-visible').styles(
      pointerEvents: PointerEvents.auto,
      raw: {
        'visibility': 'visible',
        // Incoming: wait for the outgoing panel to fade, then fade in.
        'transition':
            'opacity 0.5s ease 0.25s, transform 0.5s ease 0.25s, visibility 0s linear 0s',
      },
    ),

    // Inner shell.
    css('.panel-shell').styles(
      display: Display.flex,
      flexDirection: FlexDirection.column,
      alignItems: AlignItems.center,
      gap: Gap(row: 18.px),
      padding: Padding.symmetric(horizontal: 24.px),
    ),

    // Label — reads like a small secondary LED readout above the title.
    css('.panel-label').styles(
      fontFamily: const FontFamily.list([
        FontFamily('IBM Plex Mono'),
        FontFamilies.monospace,
      ]),
      fontSize: Unit.pixels(10),
      fontWeight: FontWeight.w500,
      letterSpacing: 0.4.em,
      textTransform: TextTransform.upperCase,
      raw: {
        'color': 'var(--sc, #E8A035)',
        'opacity': '0.75',
        'text-shadow':
            '0 0 2px var(--sc-glow, rgba(232,160,53,0.35))',
      },
    ),

    // Title — dim illuminated text on a dark panel, in the station
    // colour. Chromatic glitch split still scales with --distortion.
    css('.panel-title').styles(
      fontFamily: const FontFamily.list([
        FontFamily('Orbitron'),
        FontFamilies.sansSerif,
      ]),
      fontSize: 2.2.rem,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.05.em,
      raw: {
        'color': 'var(--sc, #E8A035)',
        'opacity': '0.92',
        'margin': '0',
        'line-height': '1.15',
        'text-shadow':
            '0 0 6px var(--sc-glow, rgba(232,160,53,0.3)), '
                '0 0 16px var(--sc-glow-dim, rgba(232,160,53,0.15)), '
                'calc(var(--distortion, 0) * 2px) 0 rgba(255,0,0,0.55), '
                'calc(var(--distortion, 0) * -2px) 0 rgba(0,255,255,0.55)',
      },
    ),

    // Subtitle — small uppercase descriptor sitting under the title.
    // Uses the same letterspaced mono treatment as .panel-label but a
    // touch less dim so it reads as a caption rather than metadata.
    css('.panel-subtitle').styles(
      fontFamily: const FontFamily.list([
        FontFamily('IBM Plex Mono'),
        FontFamilies.monospace,
      ]),
      fontSize: Unit.pixels(11),
      fontWeight: FontWeight.w500,
      letterSpacing: 0.3.em,
      textTransform: TextTransform.upperCase,
      raw: {
        'color':
            'color-mix(in srgb, var(--sc, #E8A035) 80%, #cfc9b8)',
        'opacity': '0.8',
        'text-shadow':
            '0 0 3px var(--sc-glow, rgba(232,160,53,0.3))',
      },
    ),

    // Body — dim printed-on-dark-plastic feel, warm amber/green tint.
    css('.panel-body').styles(
      fontFamily: const FontFamily.list([
        FontFamily('IBM Plex Mono'),
        FontFamilies.monospace,
      ]),
      fontSize: Unit.pixels(12),
      fontWeight: FontWeight.w400,
      color: const Color('#c5b994'),
      maxWidth: 400.px,
      raw: {
        'opacity': '0.55',
        'line-height': '1.55',
        'letter-spacing': '0.02em',
        'margin': '0 auto',
        'text-shadow':
            'calc(var(--distortion, 0) * 1.5px) 0 rgba(255,0,0,0.45), '
                'calc(var(--distortion, 0) * -1.5px) 0 rgba(0,255,255,0.45)',
      },
    ),

    // Wrapper that takes the tear / flicker / jitter animations. The
    // blur filter scales continuously with --distortion so an out-of-
    // focus signal sharpens into clean content as you tune in.
    css('.panel-fx').styles(
      raw: {
        'will-change': 'transform, clip-path, opacity, filter',
        'filter': 'blur(calc(var(--distortion, 0) * 4px))',
        'transition': 'filter 0.15s ease',
      },
    ),

    // Pill links — subtle bordered, hover lifts opacity.
    css('.pill-row').styles(
      display: Display.flex,
      flexDirection: FlexDirection.row,
      flexWrap: FlexWrap.wrap,
      justifyContent: JustifyContent.center,
      gap: Gap(row: 8.px, column: 8.px),
    ),
    // Pills render as physical stereo buttons: raised plastic with an
    // upper highlight + lower drop, a tiny illuminated LED dot in the
    // station colour, and station-coloured glowing text. Hover =
    // "pressed": inset shadow flip + slight darker face.
    css('.pill', [
      css('&').styles(
        fontFamily: const FontFamily.list([
          FontFamily('IBM Plex Mono'),
          FontFamilies.monospace,
        ]),
        fontSize: Unit.pixels(11),
        fontWeight: FontWeight.w500,
        letterSpacing: 0.15.em,
        textTransform: TextTransform.upperCase,
        padding: Padding.symmetric(horizontal: 16.px, vertical: 8.px),
        cursor: Cursor.pointer,
        textDecoration: const TextDecoration(line: TextDecorationLine.none),
        raw: {
          'color': 'var(--sc, #E8A035)',
          'display': 'inline-flex',
          'align-items': 'center',
          'gap': '8px',
          'border': '1px solid rgba(255,255,255,0.09)',
          'border-radius': '99px',
          // Raised-plastic faceplate: soft dark gradient body, tiny
          // light highlight up top, dark drop below.
          'background':
              'linear-gradient(180deg, #1a1a1f 0%, #111115 100%)',
          'box-shadow':
              'inset 0 1px 0 rgba(255,255,255,0.06), '
                  '0 1px 0 rgba(0,0,0,0.6), '
                  '0 2px 6px rgba(0,0,0,0.35)',
          'text-shadow':
              '0 0 3px var(--sc-glow, rgba(232,160,53,0.3))',
          'transition': 'border-color 0.15s ease, background 0.15s ease, '
              'box-shadow 0.15s ease, color 0.15s ease',
        },
      ),
      // Tiny LED dot ::before — lit in the station colour with glow.
      css('&::before').styles(
        raw: {
          'content': '""',
          'display': 'inline-block',
          'width': '5px',
          'height': '5px',
          'border-radius': '50%',
          'background': 'var(--sc, #E8A035)',
          'box-shadow':
              '0 0 4px var(--sc, #E8A035), '
                  '0 0 1px rgba(0,0,0,0.8)',
        },
      ),
      // Pressed-in state on hover / active — inverts the bevel and
      // darkens the face slightly.
      css('&:hover').styles(
        raw: {
          'background':
              'linear-gradient(180deg, #121216 0%, #0d0d10 100%)',
          'border-color': 'rgba(255,255,255,0.18)',
          'box-shadow':
              'inset 0 1px 3px rgba(0,0,0,0.7), '
                  'inset 0 -1px 0 rgba(255,255,255,0.04)',
        },
      ),
      css('&:active').styles(
        raw: {
          'box-shadow':
              'inset 0 2px 4px rgba(0,0,0,0.85), '
                  'inset 0 -1px 0 rgba(255,255,255,0.04)',
        },
      ),
    ]),

    // ── AM lo-fi panel aesthetic ──
    // AM is for idea-stage projects, so the panels are intentionally
    // less polished than the FM ones: default body font (no Orbitron),
    // lighter weights, dashed border, desaturated station-colour
    // accent, and a subtle grain overlay.
    css('.am-shell').styles(
      position: Position.relative(),
      display: Display.flex,
      flexDirection: FlexDirection.column,
      alignItems: AlignItems.center,
      gap: Gap(row: 10.px),
      padding: Padding.symmetric(horizontal: 22.px, vertical: 18.px),
      maxWidth: 420.px,
      raw: {
        'margin': '0 auto',
        'border': '1px dashed rgba(255,255,255,0.10)',
        'border-color':
            'color-mix(in srgb, var(--sc, #888) 35%, rgba(255,255,255,0.10))',
        'border-radius': '3px',
        'background': 'rgba(10, 10, 14, 0.4)',
        'overflow': 'hidden',
      },
    ),
    // Grain overlay via a repeating inline SVG noise filter, stacked
    // at ~10% opacity. Sits above the background but below content.
    css('.am-shell::before').styles(
      position: Position.absolute(
        top: Unit.zero,
        left: Unit.zero,
      ),
      width: 100.percent,
      height: 100.percent,
      pointerEvents: PointerEvents.none,
      raw: {
        'content': '""',
        'background':
            'url("data:image/svg+xml;utf8,<svg xmlns=\'http://www.w3.org/2000/svg\' width=\'120\' height=\'120\'><filter id=\'n\'><feTurbulence type=\'fractalNoise\' baseFrequency=\'0.9\' numOctaves=\'2\' stitchTiles=\'stitch\'/><feColorMatrix values=\'0 0 0 0 0.7  0 0 0 0 0.65  0 0 0 0 0.55  0 0 0 0.6 0\'/></filter><rect width=\'100%\' height=\'100%\' filter=\'url(%23n)\'/></svg>")',
        'opacity': '0.10',
        'mix-blend-mode': 'screen',
      },
    ),
    // Keep content above the grain overlay.
    css('.am-shell > *').styles(
      position: Position.relative(),
      raw: {'z-index': '1'},
    ),
    // Label: dimmer than the FM version.
    css('.am-label').styles(
      raw: {
        'opacity': '0.55',
        'letter-spacing': '0.3em',
      },
    ),
    // Title: default body font (NOT Orbitron), lighter weight,
    // understated letter-spacing. The station colour carries through
    // but the glow is dialled back.
    css('.am-title').styles(
      fontFamily: const FontFamily.list([
        FontFamily('IBM Plex Mono'),
        FontFamilies.monospace,
      ]),
      fontSize: 1.4.rem,
      fontWeight: FontWeight.w500,
      letterSpacing: 0.02.em,
      raw: {
        'color':
            'color-mix(in srgb, var(--sc, #E8A035) 85%, #cfc9b8)',
        'opacity': '0.9',
        'margin': '0',
        'line-height': '1.2',
        'text-shadow':
            '0 0 4px color-mix(in srgb, var(--sc, #E8A035) 40%, transparent)',
      },
    ),
    css('.am-subtitle').styles(
      fontFamily: const FontFamily.list([
        FontFamily('IBM Plex Mono'),
        FontFamilies.monospace,
      ]),
      fontSize: Unit.pixels(11),
      fontWeight: FontWeight.w300,
      color: const Color('#a89a78'),
      raw: {
        'opacity': '0.7',
        'letter-spacing': '0.04em',
        'text-transform': 'uppercase',
      },
    ),
    css('.am-body').styles(
      fontFamily: const FontFamily.list([
        FontFamily('IBM Plex Mono'),
        FontFamilies.monospace,
      ]),
      fontSize: Unit.pixels(12),
      fontWeight: FontWeight.w300,
      color: const Color('#b8ac90'),
      raw: {
        'opacity': '0.72',
        'line-height': '1.55',
        'margin': '0',
        'text-align': 'center',
      },
    ),

    // Mobile sizing.
    css.media(MediaQuery.screen(maxWidth: 600.px), [
      // Track the same vertical offset as the idle content so we don't
      // overlap the mobile radio panel (height 180 px → shift content
      // up by ~half the panel height so its vertical centre lands in
      // the free space above the faceplate).
      css('.station-display').styles(
        position: Position.absolute(
          top: Unit.expression('calc(50% - 90px)'),
          left: 50.percent,
        ),
      ),
      css('.panel-title').styles(fontSize: 1.7.rem),
      css('.panel-body').styles(fontSize: Unit.pixels(12)),
      css('.panel-shell').styles(gap: Gap(row: 12.px)),
      css('.station-panel').styles(maxWidth: 92.percent),
      // Pills wrap tighter and use a smaller hit area on phones.
      css('.pill').styles(
        fontSize: Unit.pixels(11),
        padding: Padding.symmetric(horizontal: 14.px, vertical: 6.px),
      ),
      // AM panels tighten a touch on small screens.
      css('.am-shell').styles(
        padding: Padding.symmetric(horizontal: 16.px, vertical: 14.px),
        maxWidth: 90.percent,
      ),
      css('.am-title').styles(fontSize: 1.15.rem),
      css('.am-body').styles(fontSize: Unit.pixels(11)),
    ]),
  ];
}

