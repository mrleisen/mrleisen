import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../models/station.dart';
import '../utils/keyboard.dart';

/// Currently-supported UI languages.
enum Lang { es, en }

/// "Decoded" content panel that fades in when the dial locks onto a
/// station. Every panel for the active band lives in the same absolute
/// slot; hidden ones sit at `visibility: hidden; opacity: 0`, so
/// switching stations never causes a reflow.
///
/// Transitions are deliberately asymmetric, and in the direction a
/// receiver actually behaves: **arriving is quick (0.28 s), leaving
/// drifts (0.85 s)**. Catching a carrier is abrupt; losing one is the
/// signal decaying, not a panel being switched off.
///
/// Inside a panel the blocks then stagger ~70 ms apart in reading order,
/// so a transmission resolves progressively rather than appearing whole.
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
    this.onOpenTech,
    this.techTriggerId = 'tech-trigger',
    this.onOpenCase,
    this.caseTriggerId = 'case-trigger',
    super.key,
  });

  final double frequency;
  final Band band;
  final Lang lang;

  /// When false every panel collapses to opacity 0 and skips the
  /// distortion animations so nothing runs behind the CRT-off overlay.
  final bool isPowered;

  /// Opens the technical-transmission dialog. Owned by `AppState`
  /// because the dialog overlays everything and needs document-level
  /// Escape handling.
  final VoidCallback? onOpenTech;

  /// Id stamped on the trigger so the dialog can hand focus back to it.
  final String techTriggerId;

  /// Opens the DeTodoUIS extended transmission, the one station told at
  /// length. Owned by `AppState` for the same reasons as [onOpenTech].
  final VoidCallback? onOpenCase;

  /// Id stamped on that trigger, so focus returns to it on close.
  final String caseTriggerId;

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
      // Only render panels for stations on the active band - switching
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
    // distortion to render - keeps the idle (clean-lock) panel free of
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
    final scGlow = '${sc}55'; // ~33% alpha - primary glow
    final scGlowDim = '${sc}26'; // ~15% alpha - soft halo

    return div(
      classes:
          'station-panel station-${station.callSign.toLowerCase()} '
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
      case 'DTU':
        return _detodouisPanel(s, lang);
      case 'NET':
        return _connectPanel(s, lang);
      case 'ITNW':
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
      case 'NUM':
        return _numeloroPanel(s, lang);
      case 'AYU':
        return _ayuwokiPanel(s, lang);
      case 'CSP':
        return _conspiranoicoPanel(s, lang);
    }
    return div([]);
  }

  /// How badly out of tune [s] currently is, 0 (clean) to 1 (edge of
  /// range). Mirrors the curve in [_stationPanel] so the title's glyph
  /// noise stays in step with the panel's blur.
  double _distortionFor(Station s) {
    final cfg = configFor(s.band);
    final d = (frequency - s.frequency).abs();
    if (d <= cfg.lockRange) return 0.0;
    if (d >= cfg.tolerance) return 1.0;
    return (d - cfg.lockRange) / (cfg.tolerance - cfg.lockRange);
  }

  /// Glyphs the title decays into while the signal is unresolved.
  /// Block and hatch characters rather than random letters: the point is
  /// that the receiver has *not decoded* a character yet, not that it
  /// decoded the wrong one.
  static const String _noiseGlyphs = '▚▞▓▒░█▌▐╳╱╲┼';

  /// Renders [text] with a share of its characters replaced by noise,
  /// proportional to how far off station the dial is.
  ///
  /// This is the half of the approach the blur cannot do. A blurred
  /// title is *the same title, softened* - you can still read it from
  /// the far edge of the range, which quietly removes the reason to keep
  /// tuning. Substituting glyphs makes the title genuinely unreadable
  /// until you are close, so the letters resolve as you home in.
  ///
  /// Deterministic on (index, quantised distortion) rather than random:
  /// a `Random` here would produce different output on the server and on
  /// hydration, and would also churn every frame instead of stepping as
  /// the dial moves. Quantising to twelve buckets means the glyphs
  /// change *because you tuned*, and hold still when you stop.
  Component _resolvingTitle(String text, double distortion) {
    if (distortion < 0.06) return Component.text(text);
    final bucket = (distortion * 12).floor();
    final out = StringBuffer();
    for (var i = 0; i < text.length; i++) {
      final ch = text[i];
      if (ch == ' ') {
        out.write(ch);
        continue;
      }
      // Cheap deterministic hash of (character position, tuning bucket).
      final h = (i * 2654435761 + bucket * 40503) & 0x7fffffff;
      if ((h % 1000) / 1000.0 < distortion) {
        out.write(_noiseGlyphs[h % _noiseGlyphs.length]);
      } else {
        out.write(ch);
      }
    }
    return Component.text(out.toString());
  }

  /// Uniform station label ("FM 95.7 - decoded transmission" /
  /// "AM 620 - decoded transmission") derived from the station's band
  /// and frequency. Keeps per-panel boilerplate minimal and ensures
  /// labels update automatically if a station moves on the band plan.
  String _stationLabel(Station s, Lang lang) {
    final unit = s.band == Band.fm ? 'MHz' : 'kHz';
    final freq = s.band == Band.fm ? s.frequency.toStringAsFixed(1) : s.frequency.toInt().toString();
    final bandStr = s.band.name.toUpperCase();
    final suffix = lang == Lang.es ? 'transmisión decodificada' : 'decoded transmission';
    return '$bandStr $freq $unit - $suffix';
  }

  /// The operator's own station, and the most important panel here: it
  /// answers the one question a visitor actually has. It used to read
  /// like a LinkedIn summary, which made it the least interesting thing
  /// on an otherwise unusual site.
  ///
  /// Carries its own label ("origin signal" rather than "decoded
  /// transmission") so tuning into it feels like arriving somewhere
  /// rather than passing another project.
  Component _aboutPanel(Station s, Lang lang) {
    final es = lang == Lang.es;
    final unit = s.band == Band.fm ? 'MHz' : 'kHz';
    final label =
        '${s.band.name.toUpperCase()} ${s.frequency.toStringAsFixed(1)} $unit '
        '- ${es ? 'señal de origen' : 'origin signal'}';

    final intro = es
        ? 'Llevo más de diez años construyendo productos digitales, casi '
              'siempre solo y de punta a punta: la idea, la app, el backend, '
              'la ficha en la tienda y el soporte a la mañana siguiente. Me '
              'interesa lo que la gente termina usando de verdad, no lo que '
              'se demuestra bien.'
        : 'I have spent more than ten years building digital products, '
              'mostly alone and end to end: the idea, the app, the backend, '
              'the store listing and the support ticket the next morning. I '
              'care about what people keep using, not about what demos well.';

    final note = es
        ? 'Este receptor es un ejemplo de eso. Todo lo que oyes está '
              'sintetizado en el navegador y todo lo que ves es CSS.'
        : 'This receiver is an example of that. Everything you hear is '
              'synthesised in the browser and everything you see is CSS.';

    return div(classes: 'panel-shell panel-origin', [
      div(classes: 'panel-label', [Component.text(label)]),
      _title('panel-title', 'Rafael Camargo', s),
      div(classes: 'panel-subtitle', [
        Component.text(
          es ? 'Ingeniero de software · Bucaramanga, Colombia' : 'Software engineer · Bucaramanga, Colombia',
        ),
      ]),
      p(classes: 'panel-body', [Component.text(intro)]),
      _transmissionData([
        (es ? 'CONSTRUYENDO DESDE' : 'BUILDING SINCE', '2015'),
        (
          es ? 'ENFOQUE' : 'FOCUS',
          es ? 'Apps multiplataforma · Web experimental' : 'Cross-platform apps · Experimental web',
        ),
        (
          es ? 'MODO' : 'MODE',
          es ? 'Productos independientes' : 'Independent products',
        ),
      ]),
      p(classes: 'panel-body', [Component.text(note)]),
      div(classes: 'pill-row', [
        _techPill(lang),
        _pill(
          'LinkedIn',
          href: 'https://www.linkedin.com/in/rafael-c-a6132982/',
        ),
        _pill('GitHub', href: 'https://github.com/mrleisen'),
      ]),
    ]);
  }

  /// Pill that opens a long-form printout. Rendered as a button rather
  /// than a link: it navigates nowhere, so it must not claim to.
  Component _actionPill(String label, {required String id, VoidCallback? onTap}) {
    return span(
      classes: 'pill pill-action',
      id: id,
      events: onTap == null
          ? const {}
          : {
              'click': (_) => onTap(),
              'keydown': onActivateKey((_) => onTap()),
            },
      attributes: {
        'role': 'button',
        'tabindex': '0',
        'aria-haspopup': 'dialog',
      },
      [Component.text(label)],
    );
  }

  Component _techPill(Lang lang) => _actionPill(
    lang == Lang.es ? 'Transmisión técnica' : 'Technical transmission',
    id: techTriggerId,
    onTap: onOpenTech,
  );

  Component _detodouisPanel(Station s, Lang lang) {
    final subtitle = lang == Lang.es ? 'App de comunidad universitaria' : 'University community app';
    // The single mention of UIS anywhere on the site, and it says exactly
    // one thing: who the app is for. This is an independent project and
    // always has been, so nothing here may read as institutional - no
    // full university name, no crest-adjacent phrasing, no implied
    // endorsement. "Independent" is stated outright rather than left to
    // be inferred, because an app named after a community is precisely
    // the case where a reader would otherwise assume affiliation.
    final body = lang == Lang.es
        ? 'Un proyecto independiente hecho para la comunidad UIS desde '
              '2015. Puntajes de corte, profesores, materias, el Oráculo y '
              'más. Nació de la necesidad de centralizar información que '
              'estaba dispersa entre foros, grupos de chat y el boca a '
              'boca. La comunidad ha aportado más de 6.000 reseñas de '
              'profesores, que es lo que permite armar horario sin '
              'sorpresas.'
        : 'An independent project built for the UIS community since 2015. '
              'Cut scores, professors, subjects, the Oracle and more. It '
              'started because the information students actually needed '
              'was scattered across forums, chat groups and word of '
              'mouth. The community has contributed over 6,000 professor '
              'reviews, which is what makes it possible to build a '
              'timetable with no surprises.';
    return _panelShell(
      station: s,
      label: _stationLabel(s, lang),
      title: 'DeTodoUIS',
      children: [
        div(classes: 'panel-subtitle', [Component.text(subtitle)]),
        p(classes: 'panel-body', [Component.text(body)]),
        // Figures as published on the project's own landing
        // (detodouis.com, `detodouis_web_landing/lib/components/home/
        // home_hero.dart`). This is the one station with real reach
        // behind it, and the numbers are the fastest way to say so.
        _transmissionData([
          (_key(lang, 'since'), '2015'),
          (_key(lang, 'downloads'), '70k+'),
          (_key(lang, 'registered'), '28k+'),
          (_key(lang, 'rating'), '4.9 ★'),
          (_key(lang, 'platforms'), 'iOS / Android / Web'),
          (_key(lang, 'stack'), 'Flutter · Laravel · Firebase'),
          (
            _key(lang, 'role'),
            lang == Lang.es ? 'Creador / Mantenedor' : 'Creator / Maintainer',
          ),
          (_key(lang, 'status'), _status(lang, 'active')),
        ]),
        div(classes: 'pill-row', [
          // The one station that carries a long-form broadcast. Every
          // other panel stops at its data card on purpose; this project
          // has ten years and real users behind it, and a portfolio where
          // nothing can be read in depth reads as a visual experiment
          // rather than as work.
          _actionPill(
            lang == Lang.es ? 'Transmisión extendida' : 'Extended transmission',
            id: caseTriggerId,
            onTap: onOpenCase,
          ),
          _pill('Web', href: 'https://detodouis.com'),
          _pill(
            'App Store',
            href: 'https://apps.apple.com/co/app/detodouis/id1640902049',
          ),
          _pill(
            'Google Play',
            href: 'https://play.google.com/store/apps/details?id=com.rafahcf.detodouisapp',
          ),
        ]),
      ],
    );
  }

  /// Not a project: the operator's own contact frequency, the station
  /// you tune to in order to reach whoever is broadcasting the rest.
  Component _connectPanel(Station s, Lang lang) {
    final title = lang == Lang.es ? 'Contacto' : 'Contact';
    final subtitle = lang == Lang.es ? 'Frecuencia del operador' : 'Operator frequency';
    final body = lang == Lang.es
        ? 'Para trabajo, preguntas sobre cualquiera de estas señales, o '
              'simplemente para decir que pasaste por aquí.'
        : 'For work, questions about any of these signals, or simply to '
              'say you passed through.';
    return _panelShell(
      station: s,
      label: _stationLabel(s, lang),
      title: title,
      children: [
        div(classes: 'panel-subtitle', [Component.text(subtitle)]),
        p(classes: 'panel-body', [Component.text(body)]),
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
    final subtitle = lang == Lang.es ? 'Canal de YouTube - audio inmersivo' : 'YouTube channel - immersive audio';
    final body = lang == Lang.es
        ? 'Cada episodio parte de una sola regla - una condición especial - '
              'y construye un mundo entero a partir de ella. El narrador '
              'habla desde adentro, como alguien que siempre vivió ahí: no '
              'hay explicación ni origen, el mundo simplemente es. Detrás '
              'hay una herramienta propia que lleva un mundo del concepto '
              'al video publicado, entera en local y sin nube.'
        : 'Each episode starts from a single rule - one special condition - '
              'and builds an entire world out of it. The narrator speaks '
              'from inside, as someone who has always lived there: no '
              'explanation, no origin story, the world simply is. Behind it '
              'is a purpose-built tool that carries a world from concept to '
              'published video, entirely local, with no cloud.';
    return _panelShell(
      station: s,
      label: _stationLabel(s, lang),
      title: 'In This New World',
      children: [
        div(classes: 'panel-subtitle', [Component.text(subtitle)]),
        p(classes: 'panel-body', [Component.text(body)]),
        _transmissionData([
          (
            _key(lang, 'format'),
            lang == Lang.es ? 'Narración inmersiva larga' : 'Long-form immersive narration',
          ),
          (
            _key(lang, 'episodes'),
            lang == Lang.es ? 'EP01 publicado · más en producción' : 'EP01 published · more in production',
          ),
          (
            _key(lang, 'stack'),
            lang == Lang.es ? 'Monorepo propio · local-first' : 'In-house monorepo · local-first',
          ),
          (_key(lang, 'status'), _status(lang, 'production')),
        ]),
        div(classes: 'pill-row', [
          _pill('YouTube', href: 'https://www.youtube.com/@InThisNewWorld'),
        ]),
      ],
    );
  }

  Component _tropPanel(Station s, Lang lang) {
    final subtitle = lang == Lang.es ? 'Universo narrativo en expansión' : 'An expanding narrative universe';
    final body = lang == Lang.es
        ? 'Un personaje y el universo que se le fue formando alrededor. '
              'Empezó en 2017 como dibujos sueltos y con los años acumuló '
              'lore, capítulos y apariciones en otros proyectos míos. No '
              'tiene final planeado: se sigue expandiendo por donde pida.'
        : 'A character, and the universe that grew around him. It started '
              'in 2017 as loose drawings and has since accumulated lore, '
              'chapters and cameos across my other projects. There is no '
              'planned ending: it keeps expanding wherever it asks to.';
    return _panelShell(
      station: s,
      label: _stationLabel(s, lang),
      title: 'Tropelorio',
      children: [
        div(classes: 'panel-subtitle', [Component.text(subtitle)]),
        p(classes: 'panel-body', [Component.text(body)]),
        _transmissionData([
          (_key(lang, 'origin'), '2017'),
          (
            _key(lang, 'format'),
            lang == Lang.es ? 'Cómics · Juegos · Relatos' : 'Comics · Games · Stories',
          ),
          (_key(lang, 'status'), _status(lang, 'expanding')),
        ]),
        div(classes: 'pill-row', [
          _pill('Instagram', href: 'https://www.instagram.com/tropelorio'),
        ]),
      ],
    );
  }

  // ── AM idea-stage panels (lo-fi shell) ──

  /// Minimal AM panel: label, small title, subtitle, one-line
  /// description, optional link pill. No grids, no cards - the layout
  /// is intentionally bare to match the "unfinished idea" vibe.
  Component _amPanel({
    required Station s,
    required Lang lang,
    required String title,
    required String subtitle,
    required String body,
    required String status,
    List<(String, String)> data = const [],
    String? href,
    String? websiteHref,
  }) {
    return div(classes: 'am-shell', [
      div(classes: 'panel-label am-label', [Component.text(_stationLabel(s, lang))]),
      _title('am-title', title, s),
      div(classes: 'am-subtitle', [Component.text(subtitle)]),
      p(classes: 'am-body', [Component.text(body)]),
      // STATUS is what turns an unfinished idea into a deliberate draft.
      // "STATUS: ABANDONED" is both more honest and more interesting than
      // a one-line description that reads like a placeholder nobody got
      // around to filling in.
      _transmissionData([
        ...data,
        (_key(lang, 'status'), status),
      ]),
      if (href != null || websiteHref != null)
        div(classes: 'pill-row', [
          if (websiteHref != null) _pill('Web', href: websiteHref),
          if (href != null) _pill('SoundCloud', href: href),
        ]),
    ]);
  }

  Component _bblPanel(Station s, Lang lang) {
    final subtitle = lang == Lang.es ? 'Copiloto de lotería' : 'Lottery copilot';
    final body = lang == Lang.es
        ? 'Un acompañante para quien juega lotería en Colombia y quiere '
              'control de sus tiquetes sin cuenta, sin anuncios y sin '
              'entregar sus datos. Registras el tiquete, ocurre el sorteo, '
              'la app trae el resultado oficial y lo verifica en el propio '
              'teléfono. Nunca vende tiquetes ni mueve dinero.'
        : 'A companion for Colombian lottery players who want control of '
              'their tickets without an account, ads, or handing over their '
              'data. Register a ticket, the draw happens, the app fetches '
              'the official result and checks it on the device itself. It '
              'never sells tickets or handles money.';
    return _panelShell(
      station: s,
      label: _stationLabel(s, lang),
      title: 'Boom Boom Lotter',
      children: [
        div(classes: 'panel-subtitle', [Component.text(subtitle)]),
        p(classes: 'panel-body', [Component.text(body)]),
        _transmissionData([
          (_key(lang, 'games'), 'MiLoto · Baloto + Revancha · ColorLoto'),
          (_key(lang, 'stack'), 'Flutter · BLoC · Laravel'),
          (
            _key(lang, 'privacy'),
            lang == Lang.es ? 'Sin cuenta · Offline-first' : 'No account · Offline-first',
          ),
          (
            _key(lang, 'role'),
            lang == Lang.es ? 'Creador' : 'Creator',
          ),
          (_key(lang, 'status'), _status(lang, 'prelaunch')),
        ]),
        div(classes: 'pill-row', [
          _pill('Web', href: 'https://boomboomlotter.com'),
        ]),
      ],
    );
  }

  /// The one AM station with a finished body of work behind it. It sits
  /// on AM anyway because AM is the side of the dial for things that are
  /// not the current job - and a record you closed in 2012 belongs there
  /// as squarely as an idea you never started.
  Component _awsPanel(Station s, Lang lang) => _amPanel(
    s: s,
    lang: lang,
    title: 'A Wired Spine',
    subtitle: lang == Lang.es ? 'Proyecto musical' : 'Music project',
    body: lang == Lang.es
        ? 'Electrónica instrumental, sin voces: ambient, ruido, rock '
              'hipnótico. Algunas pistas usan grabaciones cortas de casete '
              '(lluvia, pasos, agua, carros de noche) como textura. Todo '
              'hecho en FL Studio y autoeditado.'
        : 'Instrumental electronic, no vocals: ambient, noise, hypnotic '
              'rock. A few tracks use short cassette recordings - rain, '
              'steps, water, cars at night - as texture. All made in FL '
              'Studio and self-released.',
    data: [
      (
        _key(lang, 'records'),
        'INTERRUPTOR (2006) · PLEASE, PLEASE!!! (2010) · ROUTINE (2012)',
      ),
      (_key(lang, 'recorded'), '2004 – 2012'),
    ],
    status: _status(lang, 'archived'),
    href: 'https://soundcloud.com/awiredspine',
    websiteHref: 'https://awiredspine.com',
  );

  Component _nftPanel(Station s, Lang lang) => _amPanel(
    s: s,
    lang: lang,
    title: 'MyNFTGenerator',
    subtitle: lang == Lang.es ? 'Herramienta' : 'Tool',
    body: lang == Lang.es
        ? 'Una herramienta para generar colecciones a partir de capas de '
              'arte y reglas de rareza. Se quedó en el camino junto con el '
              'entusiasmo general por el tema, y no me arrepiento de no '
              'haberla terminado.'
        : 'A tool for generating collections from art layers and rarity '
              'rules. It stalled along with the general enthusiasm for the '
              'whole subject, and I do not regret leaving it unfinished.',
    status: _status(lang, 'abandoned'),
  );

  Component _pnkPanel(Station s, Lang lang) => _amPanel(
    s: s,
    lang: lang,
    title: 'PunkLLM',
    subtitle: lang == Lang.es ? 'Experimento' : 'Experiment',
    body: lang == Lang.es
        ? 'La idea: un modelo de lenguaje que no fuera servicial. Que '
              'contestara mal, que se negara, que tuviera opiniones '
              'incómodas. Casi todo el trabajo de alineamiento va en la '
              'dirección contraria, así que resultó ser más un experimento '
              'sobre qué esperamos de estas cosas que sobre el modelo.'
        : 'The idea: a language model that is not helpful. One that talks '
              'back, refuses, holds inconvenient opinions. Nearly all '
              'alignment work pulls the other way, so it turned out to be '
              'less an experiment about the model than about what we '
              'expect from these things.',
    status: _status(lang, 'concept'),
  );

  Component _numeloroPanel(Station s, Lang lang) => _amPanel(
    s: s,
    lang: lang,
    title: 'Numeloro',
    subtitle: lang == Lang.es ? 'Patio de números' : 'Number playground',
    body: lang == Lang.es
        ? 'Un patio donde los números salen a pasear y a charlar como '
              'loros en el numeloro. La idea es enseñar aritmética temprana '
              'sin que parezca una tarea: cada número es un personaje con '
              'carácter propio y las operaciones son conversaciones entre '
              'ellos.'
        : 'A playground where numbers hang out and chat away like parrots '
              'on the numeloro. The idea is to teach early arithmetic '
              'without it feeling like homework: every number is a '
              'character with its own temperament, and operations are '
              'conversations between them.',
    status: _status(lang, 'concept'),
  );

  Component _ayuwokiPanel(Station s, Lang lang) => _amPanel(
    s: s,
    lang: lang,
    title: 'Ayuwoki',
    subtitle: lang == Lang.es ? 'Homenaje' : 'Tribute',
    body: lang == Lang.es
        ? 'Un homenaje al meme que aterrorizó al internet hispanohablante '
              'sin proponérselo. Me interesa menos el susto que cómo una '
              'imagen mal comprimida se convierte en folclore compartido '
              'por millones de personas que nunca se pusieron de acuerdo.'
        : 'A tribute to the meme that terrified the Spanish-speaking '
              'internet without meaning to. The scare interests me less '
              'than how a badly compressed image becomes folklore shared '
              'by millions of people who never agreed on anything.',
    status: _status(lang, 'concept'),
  );

  Component _conspiranoicoPanel(Station s, Lang lang) => _amPanel(
    s: s,
    lang: lang,
    title: 'Conspiranoico',
    subtitle: lang == Lang.es ? 'Lugar curioso' : 'A curious place',
    body: lang == Lang.es
        ? 'Un archivo de teorías conspirativas: no para creerlas, sino '
              'para conocerlas. La pregunta que me interesa no es si son '
              'ciertas, sino por qué resultan tan atractivas y qué dice de '
              'nosotros que lo sean. Catalogar sin avalar es la parte '
              'difícil, y es la razón por la que sigue siendo una idea.'
        : 'An archive of conspiracy theories: not to believe them, but to '
              'know them. The question that interests me is not whether '
              'they are true, but why they are so appealing and what it '
              'says about us that they are. Cataloguing without endorsing '
              'is the hard part, and the reason this is still an idea.',
    status: _status(lang, 'concept'),
  );

  // ── shared building blocks ──

  /// A block of station telemetry: label on the left, value on the
  /// right, in the receiver's own microtype.
  ///
  /// The point is depth without turning a station into a case study.
  /// A conventional project page would break the conceit - the whole
  /// piece only works while it reads as a receiver - so the extra
  /// substance arrives as a data card the hardware could plausibly be
  /// printing, not as a section of a portfolio site.
  ///
  /// Every value here is verified against the project's own repo or its
  /// store listing. Nothing is estimated; a plausible-looking number
  /// nobody checked is worse than no number.
  Component _transmissionData(List<(String, String)> rows) {
    return div(classes: 'tx-data', [
      for (final (label, value) in rows) ...[
        div(classes: 'tx-key', [Component.text(label)]),
        div(classes: 'tx-val', [Component.text(value)]),
      ],
    ]);
  }

  /// Localised `STATUS` value. AM stations lean on this heavily: it is
  /// the field that makes an unfinished idea legible as a deliberate
  /// draft instead of an empty panel.
  String _status(Lang lang, String key) {
    const table = {
      'active': ('ACTIVO', 'ACTIVE'),
      'prelaunch': ('PRE-LANZAMIENTO', 'PRE-LAUNCH'),
      'production': ('EN PRODUCCIÓN', 'IN PRODUCTION'),
      'expanding': ('EN EXPANSIÓN', 'EXPANDING'),
      'archived': ('ARCHIVADO', 'ARCHIVED'),
      'concept': ('CONCEPTO', 'CONCEPT'),
      'abandoned': ('ABANDONADO', 'ABANDONED'),
    };
    final pair = table[key]!;
    return lang == Lang.es ? pair.$1 : pair.$2;
  }

  /// Shared telemetry label vocabulary, so two panels never disagree on
  /// what the same field is called.
  String _key(Lang lang, String k) {
    const table = {
      'since': ('EN LÍNEA DESDE', 'ONLINE SINCE'),
      'platforms': ('PLATAFORMAS', 'PLATFORMS'),
      'stack': ('STACK', 'STACK'),
      'role': ('ROL', 'ROLE'),
      'status': ('ESTADO', 'STATUS'),
      'games': ('JUEGOS', 'GAMES'),
      'format': ('FORMATO', 'FORMAT'),
      'records': ('DISCOS', 'RECORDS'),
      'recorded': ('GRABADO', 'RECORDED'),
      'origin': ('ORIGEN', 'ORIGIN'),
      'episodes': ('EPISODIOS', 'EPISODES'),
      'privacy': ('PRIVACIDAD', 'PRIVACY'),
      'downloads': ('DESCARGAS', 'DOWNLOADS'),
      'registered': ('REGISTRADOS', 'REGISTERED'),
      'rating': ('CALIFICACIÓN', 'RATING'),
    };
    final pair = table[k]!;
    return lang == Lang.es ? pair.$1 : pair.$2;
  }

  Component _panelShell({
    required Station station,
    required String label,
    required String title,
    required List<Component> children,
  }) {
    // The station's colour propagates through the subtree as the `--sc`
    // custom property set on `.station-panel`, so it is not passed here;
    // what the station *is* needed for is how far off the dial sits,
    // which is what decides how much of this title has resolved yet.
    return div(classes: 'panel-shell', [
      div(classes: 'panel-label', [Component.text(label)]),
      _title('panel-title', title, station),
      ...children,
    ]);
  }

  /// A station title, resolved as far as the tuning currently allows.
  ///
  /// The glyph substitution is the half of the approach the blur cannot
  /// do - see [_resolvingTitle] - and it had been written, documented and
  /// then never actually called: every title rendered as clean text and
  /// only the blur ever ran. This is where it gets connected.
  ///
  /// The real title always ships as text, in a `visually-hidden` span
  /// beside the corrupted one.
  ///
  /// Two audiences would otherwise lose it. A screen reader would be
  /// handed block glyphs to read aloud, which is the point for someone
  /// looking at the screen and pure hostility for someone listening to
  /// it. And a crawler would too: these panels are prerendered, the dial
  /// starts on dead air, so **every** title would have gone into the
  /// served HTML as noise - the station names are most of the indexable
  /// prose this page has.
  ///
  /// Note the noise glyphs live outside the latin subset the display face
  /// ships, so they render from a system fallback. That is fine, and
  /// arguably right: an undecoded cell has no business matching the type
  /// around it.
  Component _title(String cls, String text, Station station) {
    final d = _distortionFor(station);
    if (d <= 0.06) return h2(classes: cls, [Component.text(text)]);
    return h2(classes: cls, [
      span(classes: 'visually-hidden', [Component.text(text)]),
      span(
        attributes: const {'aria-hidden': 'true'},
        [_resolvingTitle(text, d)],
      ),
    ]);
  }

  /// External-link pill. `href == null` means "not a real link" and
  /// renders a `#` anchor without new-tab attributes (used only as a
  /// fallback; all current pills have real URLs).
  Component _pill(String label, {String? href}) {
    if (href == null) {
      return a(classes: 'pill', href: '#', [Component.text(label)]);
    }
    return a(
      classes: 'pill',
      href: href,
      target: Target.blank,
      attributes: {'rel': 'noopener noreferrer'},
      [Component.text(label)],
    );
  }

  // ── styles ──

  @css
  static List<StyleRule> get styles => [
    // Container - sits in the same vertical band as the idle hero text.
    css('.station-display').styles(
      position: Position.absolute(
        // Same anchor as the idle carrier monitor: the middle of whatever
        // room the faceplate leaves, measured at runtime. See `--free-h`
        // in `app.dart`.
        top: Unit.expression('calc(var(--free-h) / 2)'),
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
        // Outgoing: slow. Losing a station should feel like the signal
        // decaying, not like a panel being switched off. This used to be
        // the *fast* side (0.3s, no delay) while entry was slow, which
        // is exactly backwards from how a receiver behaves - arriving is
        // abrupt, leaving drifts.
        'transition': 'opacity 0.85s ease-in 0s, transform 0.85s ease-in 0s, visibility 0s linear 0.85s',
        'text-align': 'center',
        'visibility': 'hidden',
        // A panel taller than the space above the faceplate used to be
        // simply unreachable: `html`, `body` and `.signal-app` are all
        // `overflow: hidden` by design (the dial is dragged, the page is
        // never scrolled), so anything past the viewport was clipped with
        // no way to get at it. On a phone the DeTodoUIS panel - the
        // longest one, with eight telemetry rows and four 44 px pills -
        // ran off both ends.
        //
        // The panel now scrolls inside itself rather than the page
        // scrolling. The height available is the free space above the
        // faceplate, measured at runtime, minus a little air so the copy
        // never touches either edge. It is centred on the midpoint of
        // that space, so the 24 px lands as 12 above and 12 below.
        'max-height': 'calc(var(--free-h) - 24px)',
        'overflow-y': 'auto',
        // Pinned rather than left to compute. A box with one axis
        // `visible` and the other not turns the visible one into `auto`,
        // so `overflow-y` alone would have handed the title glows a
        // horizontal scrollbar of their own. The shell's 24 px of inner
        // padding keeps those glows off this edge.
        'overflow-x': 'hidden',
        // Keeps a swipe that runs past the end of the panel from chaining
        // into the document, where it would fight `overscroll-behavior`
        // and read as the whole receiver coming loose.
        'overscroll-behavior': 'contain',
        // Vertical panning only. A horizontal swipe here still belongs to
        // nothing, but saying so explicitly stops a browser from waiting
        // to find out before it starts scrolling.
        'touch-action': 'pan-y',
      },
    ),
    // The scrollbar is instrumentation, not chrome: a hairline amber
    // track that reads as part of the panel. Left visible on purpose -
    // hiding it entirely is what made the overflow undiscoverable in the
    // first place, and a bar that only appears when there is more to read
    // is the affordance itself.
    css('.station-panel').styles(
      raw: {
        'scrollbar-width': 'thin',
        'scrollbar-color': 'color-mix(in srgb, var(--sc, #E8A035) 45%, transparent) transparent',
      },
    ),
    css('.station-panel::-webkit-scrollbar').styles(width: 4.px),
    css('.station-panel::-webkit-scrollbar-track').styles(
      raw: {'background': 'transparent'},
    ),
    css('.station-panel::-webkit-scrollbar-thumb').styles(
      raw: {
        'background': 'color-mix(in srgb, var(--sc, #E8A035) 45%, transparent)',
        'border-radius': '2px',
      },
    ),
    css('.station-panel.is-visible').styles(
      pointerEvents: PointerEvents.auto,
      raw: {
        'visibility': 'visible',
        // Incoming: quick, and no longer waiting on the outgoing panel.
        // The stations are far enough apart that two are never in range
        // at once, so the hand-off delay was buying nothing and costing
        // a quarter second of dead screen on every lock.
        'transition': 'opacity 0.28s ease-out 0s, transform 0.28s ease-out 0s, visibility 0s linear 0s',
      },
    ),

    // ── layered reveal ──
    // Once locked, the panel's blocks arrive in reading order rather
    // than all at once, ~70ms apart: label, title, subtitle, body, data,
    // links. A receiver resolves a transmission progressively, and a
    // block that appears whole reads as a web page swapping content.
    //
    // Applied only to the visible panel, and only to its direct
    // children, so the stagger can never fight the panel's own fade.
    css('.station-panel .panel-shell > *, .station-panel .am-shell > *').styles(
      raw: {
        'opacity': '0',
        'transform': 'translateY(4px)',
      },
    ),
    css(
      '.station-panel.is-visible .panel-shell > *, '
      '.station-panel.is-visible .am-shell > *',
    ).styles(
      raw: {
        'opacity': '1',
        'transform': 'translateY(0)',
        'transition': 'opacity 0.32s ease-out, transform 0.32s ease-out',
      },
    ),
    for (var i = 1; i <= 6; i++)
      css(
        '.station-panel.is-visible .panel-shell > *:nth-child($i), '
        '.station-panel.is-visible .am-shell > *:nth-child($i)',
      ).styles(
        raw: {'transition-delay': '${((i - 1) * 0.07).toStringAsFixed(2)}s'},
      ),

    // Inner shell.
    css('.panel-shell').styles(
      display: Display.flex,
      flexDirection: FlexDirection.column,
      alignItems: AlignItems.center,
      gap: Gap(row: 16.px),
      padding: Padding.symmetric(horizontal: 24.px),
    ),

    // Label - reads like a small secondary LED readout above the title.
    css('.panel-label').styles(
      fontFamily: const FontFamily.list([
        FontFamily('IBM Plex Mono'),
        FontFamilies.monospace,
      ]),
      fontSize: Unit.pixels(11),
      fontWeight: FontWeight.w500,
      letterSpacing: 0.4.em,
      textTransform: TextTransform.upperCase,
      raw: {
        // Mixed toward a warm neutral rather than tinted with opacity.
        // The station colours span a wide luminance range (#E05050 is
        // roughly half as bright as #5BC8A0), so dimming them uniformly
        // dropped the darkest ones under AA. Mixing lifts every station
        // onto the same floor while keeping its hue legible: the worst
        // case is now 6.78:1 against #050507, the best 10.73:1.
        'color': 'color-mix(in srgb, var(--sc, #E8A035) 70%, #d8d2c4)',
        'text-shadow': '0 0 2px var(--sc-glow, rgba(232,160,53,0.35))',
      },
    ),

    // Title - dim illuminated text on a dark panel, in the station
    // colour. Chromatic glitch split still scales with --distortion.
    css('.panel-title').styles(
      fontFamily: const FontFamily.list([
        FontFamily('Space Grotesk'),
        FontFamilies.sansSerif,
      ]),
      fontWeight: FontWeight.w700,
      raw: {
        // The single biggest thing holding Design back was that nothing
        // on this page was ever *large*. Every element lived between 8px
        // and 35px, so there was no focal point and no hierarchy - just
        // a uniform field of small type. The station name is the one
        // thing that earns scale, so it gets it.
        //
        // Fluid rather than stepped: `clamp` covers 360px to ultrawide
        // in one declaration and removes the separate mobile override
        // that used to drift out of sync with this value.
        // Space Grotesk carries roughly 0.52em of average advance
        // against Orbitron's ~0.66, so the same title needs about a
        // quarter less width. That headroom goes back into size: the
        // ceiling moves from 3.2rem to 3.4rem, which still leaves the
        // 17-character worst case ("In This New World") inside the
        // panel's 512px of usable width.
        'font-size': 'clamp(1.85rem, 5.2vw, 3.4rem)',
        // Slightly negative at display size. Space Grotesk is already
        // generously spaced by default, and large type needs less
        // tracking, not more - the positive value tuned for 35px
        // Orbitron reads as loose here.
        'letter-spacing': '-0.01em',
        'color': 'var(--sc, #E8A035)',
        'opacity': '0.92',
        'margin': '0',
        'line-height': '1.05',
        'text-shadow':
            '0 0 6px var(--sc-glow, rgba(232,160,53,0.3)), '
            '0 0 16px var(--sc-glow-dim, rgba(232,160,53,0.15)), '
            'calc(var(--distortion, 0) * 2px) 0 rgba(255,0,0,0.55), '
            'calc(var(--distortion, 0) * -2px) 0 rgba(0,255,255,0.55)',
      },
    ),

    // Subtitle - small uppercase descriptor sitting under the title.
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
        'color': 'color-mix(in srgb, var(--sc, #E8A035) 80%, #cfc9b8)',
        'opacity': '0.8',
        'text-shadow': '0 0 3px var(--sc-glow, rgba(232,160,53,0.3))',
      },
    ),

    // Body - dim printed-on-dark-plastic feel, warm amber/green tint.
    css('.panel-body').styles(
      fontFamily: const FontFamily.list([
        FontFamily('IBM Plex Mono'),
        FontFamilies.monospace,
      ]),
      fontSize: Unit.pixels(14),
      fontWeight: FontWeight.w400,
      // Was #c5b994 at opacity 0.55, which composited to 3.67:1 against
      // #050507 - under AA, and that was before the noise and scanline
      // layers stacked on top. Baking the dimness into the colour rather
      // than the alpha keeps the printed-on-plastic look at 6.51:1.
      color: const Color('#9c9174'),
      maxWidth: 440.px,
      raw: {
        'line-height': '1.55',
        'letter-spacing': '0.02em',
        'margin': '0 auto',
        'text-shadow':
            'calc(var(--distortion, 0) * 1.5px) 0 rgba(255,0,0,0.45), '
            'calc(var(--distortion, 0) * -1.5px) 0 rgba(0,255,255,0.45)',
      },
    ),

    // ── transmission data block ──
    // Two-column key/value card, deliberately built to read as something
    // the receiver is printing rather than as a spec table on a product
    // page. Labels are dim and heavily tracked like instrument legends;
    // values carry the weight.
    css('.tx-data').styles(
      display: Display.grid,
      justifyContent: JustifyContent.center,
      gap: Gap(row: 8.px, column: 16.px),
      maxWidth: 440.px,
      raw: {
        // Label column sizes to its content, value column takes what is
        // left, so the two stay aligned down the block no matter how
        // long any individual label is.
        'grid-template-columns': 'auto minmax(0, 1fr)',
        'margin': '2px auto 0',
        'text-align': 'left',
        'padding-top': '12px',
        'border-top': '1px solid rgba(255,255,255,0.07)',
        'width': '100%',
      },
    ),
    css('.tx-key').styles(
      fontFamily: const FontFamily.list([
        FontFamily('IBM Plex Mono'),
        FontFamilies.monospace,
      ]),
      fontSize: Unit.pixels(11),
      fontWeight: FontWeight.w500,
      letterSpacing: 0.16.em,
      textTransform: TextTransform.upperCase,
      color: const Color('#938d81'),
      raw: {'line-height': '1.45', 'white-space': 'nowrap'},
    ),
    css('.tx-val').styles(
      fontFamily: const FontFamily.list([
        FontFamily('IBM Plex Mono'),
        FontFamilies.monospace,
      ]),
      fontSize: Unit.pixels(11),
      fontWeight: FontWeight.w500,
      letterSpacing: 0.02.em,
      raw: {
        'color': 'color-mix(in srgb, var(--sc, #E8A035) 45%, #d8d2c4)',
        'line-height': '1.45',
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

    // Pill links - subtle bordered, hover lifts opacity.
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
          // Raised plastic, lit from the upper left: highlight on the
          // top-left inner edge, shade on the bottom-right, and a short
          // cast shadow falling down and to the right.
          'background': 'linear-gradient(160deg, #1c1c22 0%, #111115 100%)',
          'box-shadow':
              'inset 1px 1px 0 rgba(255,255,255,0.07), '
              'inset -1px -1px 0 rgba(0,0,0,0.55), '
              '1px 2px 6px rgba(0,0,0,0.38)',
          'text-shadow': '0 0 3px var(--sc-glow, rgba(232,160,53,0.3))',
          // Plastic: quick, settled. The colour is a lamp behind it, so
          // it keeps the phosphor decay.
          'transition':
              'border-color var(--dur-plastic) var(--ease-plastic), '
              'background var(--dur-plastic) var(--ease-plastic), '
              'box-shadow var(--dur-plastic) var(--ease-plastic), '
              'color var(--dur-glow-off) var(--ease-phosphor)',
        },
      ),
      // Tiny LED dot ::before - lit in the station colour with glow.
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
      // Pressed-in state on hover / active - inverts the bevel and
      // darkens the face slightly.
      css('&:hover').styles(
        raw: {
          'background': 'linear-gradient(160deg, #121216 0%, #0d0d10 100%)',
          'border-color': 'rgba(255,255,255,0.18)',
          'box-shadow':
              'inset 2px 2px 3px rgba(0,0,0,0.7), '
              'inset -1px -1px 0 rgba(255,255,255,0.04)',
        },
      ),
      css('&:active').styles(
        raw: {
          'box-shadow':
              'inset 3px 3px 4px rgba(0,0,0,0.85), '
              'inset -1px -1px 0 rgba(255,255,255,0.04)',
        },
      ),
    ]),

    // The technical-transmission trigger. Same physical pill as the
    // links around it, but with an amber cast and no LED dot, so it
    // reads as a control on the panel rather than as a way off the site.
    css('.pill.pill-action', [
      css('&').styles(
        raw: {
          'color': '#E8A035',
          'border-color': 'rgba(232,160,53,0.30)',
          'text-shadow': '0 0 4px rgba(232,160,53,0.35)',
        },
      ),
      css('&::before').styles(
        raw: {
          'background': '#E8A035',
          'box-shadow': '0 0 5px #E8A035, 0 0 1px rgba(0,0,0,0.8)',
        },
      ),
      css('&:hover').styles(
        raw: {'border-color': 'rgba(232,160,53,0.55)'},
      ),
    ]),

    // The origin station gets a touch more air between blocks than the
    // project panels: it is the one people stop and read.
    css('.panel-origin').styles(gap: Gap(row: 16.px)),

    // ── AM lo-fi panel aesthetic ──
    // AM is for idea-stage projects, so the panels are intentionally
    // less polished than the FM ones: default body font (not the
    // lighter weights, dashed border, desaturated station-colour
    // accent, and a subtle grain overlay.
    css('.am-shell').styles(
      position: Position.relative(),
      display: Display.flex,
      flexDirection: FlexDirection.column,
      alignItems: AlignItems.center,
      gap: Gap(row: 12.px),
      padding: Padding.symmetric(horizontal: 16.px, vertical: 16.px),
      maxWidth: 420.px,
      raw: {
        'margin': '0 auto',
        'border': '1px dashed rgba(255,255,255,0.10)',
        'border-color': 'color-mix(in srgb, var(--sc, #888) 35%, rgba(255,255,255,0.10))',
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
    // Label: still reads dimmer than the FM version, but the dimness now
    // comes from a heavier neutral mix instead of opacity 0.55, which put
    // four of the six AM stations under AA.
    css('.am-label').styles(
      raw: {
        'color': 'color-mix(in srgb, var(--sc, #E8A035) 60%, #d8d2c4)',
        'letter-spacing': '0.3em',
      },
    ),
    // Title: default body font (NOT the instrument face), lighter weight,
    // understated letter-spacing. The station colour carries through
    // but the glow is dialled back.
    css('.am-title').styles(
      fontFamily: const FontFamily.list([
        FontFamily('IBM Plex Mono'),
        FontFamilies.monospace,
      ]),
      fontWeight: FontWeight.w500,
      letterSpacing: 0.02.em,
      raw: {
        // Scales with the FM titles but stays deliberately smaller: AM
        // is the draft band, and its panels should never shout as loudly
        // as a finished project.
        'font-size': 'clamp(1.2rem, 3vw, 1.85rem)',
        'color': 'color-mix(in srgb, var(--sc, #E8A035) 85%, #cfc9b8)',
        'opacity': '0.9',
        'margin': '0',
        'line-height': '1.15',
        'text-shadow': '0 0 4px color-mix(in srgb, var(--sc, #E8A035) 40%, transparent)',
      },
    ),
    css('.am-subtitle').styles(
      fontFamily: const FontFamily.list([
        FontFamily('IBM Plex Mono'),
        FontFamilies.monospace,
      ]),
      fontSize: Unit.pixels(11),
      fontWeight: FontWeight.w400,
      // Was #a89a78 at 0.7 → 3.98:1. Now 5.50:1.
      color: const Color('#8f8468'),
      raw: {
        'letter-spacing': '0.04em',
        'text-transform': 'uppercase',
      },
    ),
    css('.am-body').styles(
      fontFamily: const FontFamily.list([
        FontFamily('IBM Plex Mono'),
        FontFamilies.monospace,
      ]),
      fontSize: Unit.pixels(13),
      fontWeight: FontWeight.w400,
      // Was #b8ac90 at 0.72, which scraped past at 5.00:1 but only
      // because the alpha happened to land well. Pinned to 5.69:1 with
      // no alpha so it can't drift. Still reads dimmer than the FM body
      // (6.51:1), preserving the deliberate AM/FM hierarchy.
      color: const Color('#8f8770'),
      raw: {
        'line-height': '1.55',
        'margin': '0',
        'text-align': 'center',
      },
    ),

    // Mobile sizing.
    css.media(MediaQuery.screen(maxWidth: 600.px), [
      // No `.panel-title` / `.am-title` size override here: both are
      // `clamp()`ed, so a second value at this breakpoint would only be
      // something to forget to update later.
      // Body copy holds at 13 px on phones. It used to drop to 12 px,
      // but nothing informative goes below 11 px anywhere now, and body
      // text in particular has no business being the smallest thing on
      // the screen.
      css('.panel-body').styles(fontSize: Unit.pixels(13)),
      css('.panel-shell').styles(gap: Gap(row: 12.px)),
      css('.station-panel').styles(maxWidth: 92.percent),
      // These are the only outbound links in the whole piece, and they
      // were ~25px tall on a phone. Given a real minimum height instead
      // of a pseudo-element hit area: the pills wrap onto multiple rows
      // 8px apart, so an invisible 44px box on a 25px pill would overlap
      // the row above and start stealing its taps.
      css('.pill').styles(
        fontSize: Unit.pixels(12),
        minHeight: 44.px,
        padding: Padding.symmetric(horizontal: 16.px, vertical: 8.px),
      ),
      css('.pill-row').styles(
        gap: Gap(row: 10.px, column: 10.px),
      ),
      // AM panels tighten a touch on small screens.
      css('.am-shell').styles(
        padding: Padding.symmetric(horizontal: 12.px, vertical: 12.px),
        maxWidth: 90.percent,
      ),
      css('.am-body').styles(fontSize: Unit.pixels(12)),
    ]),
  ];
}
