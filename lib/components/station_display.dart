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
    required this.lang,
    super.key,
  });

  final double frequency;
  final Lang lang;

  /// Identify which (if any) station's panel should be active. Stations
  /// sit >3 MHz apart, so at most one is ever within [stationTolerance]
  /// of the dial.
  Station? _pickVisible() {
    Station? best;
    var bestDist = double.infinity;
    for (final s in stations) {
      final d = (frequency - s.frequency).abs();
      if (d < bestDist && d < stationTolerance) {
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
      for (final s in stations)
        _stationPanel(
          station: s,
          isVisible: visible?.callSign == s.callSign,
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
    //   d ≤ 0.2        → opacity 1.0, distortion 0 (clean lock)
    //   0.2 < d < 1.5  → opacity 1.0→0.3, distortion 0→1 (glitch zone)
    //   d ≥ 1.5        → panel hidden
    double opacity;
    double distortion;
    if (distance <= stationLockRange) {
      opacity = 1.0;
      distortion = 0.0;
    } else if (distance < stationTolerance) {
      final t = (distance - stationLockRange) /
          (stationTolerance - stationLockRange);
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
      classes:
          'station-panel station-${station.callSign.toLowerCase()}${isVisible ? ' is-visible' : ''}',
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
      case 'DEV':
        return _projectsPanel(s, lang);
      case 'NET':
        return _connectPanel(s, lang);
      default:
        return _classifiedPanel(s, lang);
    }
  }

  Component _aboutPanel(Station s, Lang lang) {
    final label = lang == Lang.es
        ? 'FM 95.7 — transmisión decodificada'
        : 'FM 95.7 — decoded transmission';
    final body = lang == Lang.es
        ? 'Flutter developer. Android, iOS, Web. Bucaramanga, Colombia. '
            'Construyo experiencias digitales con Dart.'
        : 'Flutter developer. Android, iOS, Web. Bucaramanga, Colombia. '
            'Building digital experiences with Dart.';
    return _panelShell(
      color: s.color,
      label: label,
      title: 'Rafael Camargo',
      children: [
        p(classes: 'panel-body', [text(body)]),
      ],
    );
  }

  Component _detodouisPanel(Station s, Lang lang) {
    final label = lang == Lang.es
        ? 'FM 91.3 — señal interceptada'
        : 'FM 91.3 — intercepted signal';
    final body = lang == Lang.es
        ? 'La app de la comunidad UIS. Puntajes de corte, profesores, '
            'materias, el Oráculo y más.'
        : 'The UIS community app. Cut scores, professors, subjects, the '
            'Oracle and more.';
    return _panelShell(
      color: s.color,
      label: label,
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

  Component _projectsPanel(Station s, Lang lang) {
    final label = lang == Lang.es
        ? 'FM 87.5 — señales débiles'
        : 'FM 87.5 — weak signals';
    final title = lang == Lang.es ? 'Proyectos' : 'Projects';

    final projects = <_ProjectEntry>[
      _ProjectEntry(
        name: 'ITNW Machine',
        subtitle: 'In This New World',
        descEn: 'Immersive audio exploration of imagined realities',
        descEs: 'Exploración sonora inmersiva de realidades imaginadas',
      ),
      _ProjectEntry(
        name: 'BBL',
        subtitle: 'Boom Boom Lottery',
        descEn: 'Lottery ticket manager for MiLoto',
        descEs: 'Gestor de boletos de lotería para MiLoto',
      ),
      _ProjectEntry(
        name: 'Tropelorio',
        subtitle: 'Character universe',
        descEn: 'A character and universe. Comics, games, apps.',
        descEs: 'Un personaje y universo. Cómics, juegos, apps.',
      ),
      _ProjectEntry(
        name: 'A Wired Spine',
        subtitle: 'Music',
        descEn: 'Original music tracks',
        descEs: 'Tracks de música originales',
        href: 'https://soundcloud.com/awiredspine',
      ),
      _ProjectEntry(
        name: 'MyNFTGenerator',
        subtitle: 'Concept',
        descEn: 'NFT generation tool',
        descEs: 'Herramienta de generación de NFTs',
      ),
      _ProjectEntry(
        name: 'PunkLLM',
        subtitle: 'Experiment',
        descEn: 'An attempt to create a punk LLM',
        descEs: 'Un intento de crear un LLM punk',
      ),
    ];

    return _panelShell(
      color: s.color,
      label: label,
      title: title,
      children: [
        div(classes: 'project-grid', [
          for (final p in projects) _projectCard(p, s.color, lang),
        ]),
      ],
    );
  }

  Component _connectPanel(Station s, Lang lang) {
    final label = lang == Lang.es
        ? 'FM 99.1 — canales abiertos'
        : 'FM 99.1 — open channels';
    final title = lang == Lang.es ? 'Conectar' : 'Connect';
    return _panelShell(
      color: s.color,
      label: label,
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

  Component _classifiedPanel(Station s, Lang lang) {
    final label = lang == Lang.es
        ? 'FM 103.5 — frecuencia clasificada'
        : 'FM 103.5 — classified frequency';
    final body = lang == Lang.es
        ? 'Esta frecuencia aún no ha sido decodificada.'
        : 'This frequency has not been decoded yet.';
    return div(classes: 'panel-shell', [
      div(classes: 'panel-label', [text(label)]),
      // Glitched title — re-uses the existing `glitch` / `glitch-alt`
      // keyframes from main.server.dart.
      div(classes: 'glitch-title-wrapper', [
        h2(classes: 'panel-title glitch-title', [text('???')]),
        h2(
          classes: 'panel-title glitch-title glitch-title-alt',
          attributes: {'aria-hidden': 'true'},
          [text('???')],
        ),
      ]),
      p(classes: 'panel-body', [text(body)]),
    ]);
  }

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

  Component _projectCard(_ProjectEntry p, String color, Lang lang) {
    final desc = lang == Lang.es ? p.descEs : p.descEn;
    final children = <Component>[
      div(classes: 'project-name', [text(p.name)]),
      div(classes: 'project-subtitle', [text(p.subtitle)]),
      div(classes: 'project-desc', [text(desc)]),
    ];

    if (p.href == null) {
      return div(classes: 'project-card', children);
    }
    return a(
      classes: 'project-card project-card-link',
      href: p.href!,
      target: Target.blank,
      attributes: {'rel': 'noopener noreferrer'},
      children,
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

    // Projects — responsive grid: 3 cols desktop, 2 cols mobile.
    css('.project-grid').styles(
      width: 100.percent,
      raw: {
        'display': 'grid',
        'grid-template-columns': 'repeat(3, minmax(0, 1fr))',
        'gap': '10px',
      },
    ),
    // Project cards look like debossed sections milled into the
    // stereo faceplate: dark recessed body, inset shadow for the
    // depth, station-colour title, monospace description.
    css('.project-card', [
      css('&').styles(
        padding: Padding.symmetric(horizontal: 14.px, vertical: 11.px),
        textDecoration: const TextDecoration(line: TextDecorationLine.none),
        raw: {
          'border': '1px solid rgba(0,0,0,0.65)',
          'border-radius': '5px',
          'background':
              'linear-gradient(180deg, #0b0b0e 0%, #0d0d11 100%)',
          'box-shadow':
              'inset 0 1px 2px rgba(0,0,0,0.7), '
                  'inset 0 -1px 0 rgba(255,255,255,0.03), '
                  '0 1px 0 rgba(255,255,255,0.04)',
          'text-align': 'left',
          'display': 'block',
          'color': 'inherit',
          'transition': 'border-color 0.2s ease, box-shadow 0.2s ease, '
              'transform 0.2s ease',
        },
      ),
      css('&.project-card-link').styles(cursor: Cursor.pointer),
      css('&.project-card-link:hover').styles(
        raw: {
          'border-color': 'rgba(0,0,0,0.8)',
          'box-shadow':
              'inset 0 1px 2px rgba(0,0,0,0.7), '
                  'inset 0 -1px 0 rgba(255,255,255,0.03), '
                  '0 0 10px var(--sc-glow-dim, rgba(232,160,53,0.15))',
          'transform': 'translateY(-1px)',
        },
      ),
    ]),
    // Name: station colour with faint glow, feels like a label milled
    // into the faceplate and lit from behind.
    css('.project-name').styles(
      fontFamily: const FontFamily.list([
        FontFamily('Orbitron'),
        FontFamilies.sansSerif,
      ]),
      fontSize: Unit.pixels(12),
      fontWeight: FontWeight.w700,
      letterSpacing: 0.06.em,
      textTransform: TextTransform.upperCase,
      raw: {
        'color': 'var(--sc, #E8A035)',
        'text-shadow':
            '0 0 3px var(--sc-glow, rgba(232,160,53,0.3))',
      },
    ),
    css('.project-subtitle').styles(
      fontFamily: const FontFamily.list([
        FontFamily('IBM Plex Mono'),
        FontFamilies.monospace,
      ]),
      fontSize: Unit.pixels(10),
      fontWeight: FontWeight.w400,
      color: const Color('#b8a97c'),
      raw: {
        'margin-top': '3px',
        'opacity': '0.7',
        'letter-spacing': '0.04em',
      },
    ),
    css('.project-desc').styles(
      fontFamily: const FontFamily.list([
        FontFamily('IBM Plex Mono'),
        FontFamilies.monospace,
      ]),
      fontSize: Unit.pixels(10),
      color: const Color('#8a8570'),
      raw: {
        'margin-top': '7px',
        'opacity': '0.75',
        'line-height': '1.5',
        'letter-spacing': '0.01em',
      },
    ),

    // Glitch title (used by the "???" station).
    css('.glitch-title-wrapper').styles(
      position: Position.relative(),
      display: Display.inlineBlock,
    ),
    css('.glitch-title').styles(
      raw: {'animation': 'glitch 4s infinite'},
    ),
    css('.glitch-title-alt').styles(
      position: Position.absolute(top: Unit.zero, left: Unit.zero),
      width: 100.percent,
      raw: {
        'animation': 'glitch-alt 4s infinite 200ms',
        'opacity': '0.8',
      },
    ),

    // Mobile sizing.
    css.media(MediaQuery.screen(maxWidth: 600.px), [
      // Track the same vertical offset as the idle content so we don't
      // overlap the shorter mobile radio panel.
      css('.station-display').styles(
        position: Position.absolute(
          top: Unit.expression('calc(50% - 70px)'),
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
      // Projects: 2 columns instead of 3.
      css('.project-grid').styles(
        raw: {
          'grid-template-columns': 'repeat(2, minmax(0, 1fr))',
          'gap': '8px',
        },
      ),
      css('.project-card').styles(
        padding: Padding.symmetric(horizontal: 12.px, vertical: 10.px),
      ),
      css('.project-name').styles(fontSize: Unit.pixels(12)),
      css('.project-subtitle').styles(fontSize: Unit.pixels(10)),
      css('.project-desc').styles(fontSize: Unit.pixels(9)),
    ]),
  ];
}

/// Plain data class for a project card.
class _ProjectEntry {
  const _ProjectEntry({
    required this.name,
    required this.subtitle,
    required this.descEn,
    required this.descEs,
    this.href,
  });

  final String name;
  final String subtitle;
  final String descEn;
  final String descEs;
  final String? href;
}
