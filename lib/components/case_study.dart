import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:universal_web/js_interop.dart';
import 'package:universal_web/web.dart' as web;

import 'rx_chrome.dart';
import 'station_display.dart' show Lang;

/// The one station that gets told at length: DeTodoUIS, call sign DTU,
/// FM 101.8.
///
/// DeTodoUIS is an independent project and has always been one. The site
/// therefore makes exactly one reference to the university community, in
/// the station panel, and it says only who the app is for. Nothing in
/// this long form may add a second: no full institution name, no
/// phrasing that could read as official or endorsed. The station's call
/// sign is DTU rather than UIS for the same reason - a bare "UIS" sitting
/// on the dial is an implied claim of affiliation that nobody made.
///
/// Every other station is deliberately a data card. A receiver that
/// opened a case-study page per project would stop being a receiver, and
/// the conceit is the whole piece. But a portfolio with twelve one-screen
/// entries and nothing behind any of them reads as a visual experiment,
/// not as a body of work - so exactly one signal carries a long-form
/// broadcast, and it is the one with ten years and real users behind it.
///
/// Framed as an extended transmission rather than as a case study:
/// numbered programme segments, instrument microtype, the same dark
/// plastic and hairline borders as the rest of the hardware. It reuses
/// the `.rx-*` dialog chrome that the technical transmission already
/// established (defined in `app.dart`), because both are the same object -
/// something the receiver decoded and printed.
///
/// Every figure here is measured from the project's own repositories, not
/// remembered:
///   - reach figures (70k / 28k / 4.9 / 22 languages) are the ones
///     published on detodouis.com's own hero
///     (`detodouis_web_landing/lib/components/home/home_hero.dart`)
///   - app version from `DeTodoUIS_flutter/pubspec.yaml` (5.3.1)
///   - local schema version and table count from `app_database.dart`
///     (`schemaVersion => 16`, 31 `Table` subclasses)
///   - the 22 interface languages are 22 `.arb` files in
///     `detodouis_core`, two of which (`vo`, `io`) are the joke locales
///   - the empty-response cache contract is visible in every
///     `*_repository_impl.dart` (`getLatestModifiedAt` → remote call)
///   - the shared-database migration rules and the inverted soft-delete
///     audit are recorded in `DeTodoUIS_flutter/CLAUDE.md`
///   - the professor-review count is the one figure with no repo behind
///     it: the reviews live in the production MySQL database, so the
///     operator is the source. 6,000+ as of 27 July 2026. It only ever
///     goes up, so an out-of-date floor stays true; it is written as a
///     floor for exactly that reason.
///
/// NOTE: deliberately NOT marked `@client`, for the same reason as
/// `StationDisplay` - the parent `App` is already the hydration island.
class CaseStudyDialog extends StatelessComponent {
  const CaseStudyDialog({
    required this.lang,
    required this.onClose,
    required this.dialogId,
    required this.signal,
    super.key,
  });

  final Lang lang;
  final VoidCallback onClose;

  /// How the DTU carrier that produced this printout is doing right now.
  /// The dial stays live behind the panel, so it can be tuned away while
  /// this is still open - see `rx_chrome.dart`.
  final RxSignalState signal;

  /// Id stamped on the panel so `AppState` can focus it and trap Tab
  /// inside it.
  final String dialogId;

  static const String titleId = 'case-title';

  @override
  Component build(BuildContext context) {
    final es = lang == Lang.es;
    return div(
      classes: 'rx-overlay',
      events: {
        // Backdrop press closes; guarded on the target being the backdrop
        // itself so a press inside the panel doesn't dismiss it.
        'click': (web.Event e) {
          final t = e.target;
          if (t.isA<web.Element>() && (t as web.Element).classList.contains('rx-overlay')) {
            onClose();
          }
        },
      },
      [
        div(
          classes: 'rx-panel rx-panel-wide${signal.panelClass}',
          styles: Styles(raw: {'--distortion': signal.distortion.toStringAsFixed(3)}),
          attributes: {
            'id': dialogId,
            'role': 'dialog',
            'aria-modal': 'true',
            'aria-labelledby': titleId,
            'tabindex': '-1',
          },
          [
            rxHead(
              label: es ? 'TRANSMISIÓN EXTENDIDA · FM 101.8' : 'EXTENDED TRANSMISSION · FM 101.8',
              lang: lang,
              state: signal,
              onClose: onClose,
            ),
            if (signal.lost) rxLostPlate(lang: lang, state: signal),
            h2(classes: 'rx-title', id: titleId, [
              Component.text('DeTodoUIS'),
            ]),
            div(classes: 'rx-subtitle', [
              Component.text(
                // Not "a university app": the project is independent, and
                // that phrasing invites exactly the wrong inference.
                es ? 'Diez años en el aire' : 'Ten years on air',
              ),
            ]),

            // The reach figures, at a size the rest of the piece never
            // uses. This is the only station with numbers worth stating
            // plainly, and stating them plainly is faster than any
            // paragraph about impact.
            div(classes: 'case-figures', [
              _figure('70k+', es ? 'descargas' : 'downloads'),
              _figure('28k+', es ? 'registrados' : 'registered'),
              _figure('4.9★', es ? 'calificación' : 'rating'),
              _figure('22', es ? 'idiomas' : 'languages'),
            ]),

            ..._segments(es),

            _data(es),

            rxHint(lang),
          ],
        ),
      ],
    );
  }

  Component _figure(String value, String label) => div(classes: 'case-figure', [
    div(classes: 'case-figure-val', [Component.text(value)]),
    div(classes: 'case-figure-key', [Component.text(label)]),
  ]);

  /// One numbered programme segment: marker, heading, prose.
  Component _segment(String no, String heading, List<String> paragraphs) {
    return div(classes: 'case-seg', [
      div(classes: 'case-seg-head', [
        span(classes: 'case-seg-no', [Component.text(no)]),
        span(classes: 'case-seg-title', [Component.text(heading)]),
      ]),
      for (final t in paragraphs) p(classes: 'rx-body', [Component.text(t)]),
    ]);
  }

  List<Component> _segments(bool es) {
    if (es) {
      return [
        _segment('01', 'Origen · 2015', [
          'Lo que un estudiante necesitaba saber existía, pero repartido: '
              'los puntajes de corte en un PDF, qué profesor toma qué '
              'materia en un grupo de chat, cómo funciona un examen de '
              'suficiencia en el boca a boca de la cafetería. DeTodoUIS '
              'empezó como el lugar donde todo eso vivía junto, y la '
              'comunidad terminó de llenarlo: hoy lleva más de 6.000 '
              'reseñas de profesores escritas por estudiantes.',
        ]),
        _segment('02', 'Qué transmite', [
          'Para quien todavía no entra: histórico de puntajes con '
              'gráficas, criterios de admisión y el Oráculo, un '
              'recomendador que pregunta por intereses y devuelve carreras '
              'con la razón por la que encajan. Para quien ya está dentro: '
              'reseñas de profesores y materias, mural de anuncios, '
              'calculadora de promedio, mapa del campus, diccionario del '
              'argot local.',
          'Y una capa que no es académica en absoluto: seis minijuegos con '
              'tabla de posiciones, wallpapers, memes. Está ahí a '
              'propósito. Una app que solo sirve para consultar se abre en '
              'época de matrículas y se olvida el resto del semestre.',
        ]),
        _segment('03', 'Cómo está construida', [
          'Flutter sobre Clean Architecture: data, domain y presentation '
              'separadas de verdad, BLoC para el estado, GetIt e '
              'Injectable para la inyección de dependencias, GoRouter para '
              'la navegación. Debajo hay SQLite a través de Drift, con 31 '
              'tablas y el esquema en su versión 16: dieciséis migraciones '
              'ejecutadas en el bolsillo de gente real, cada una obligada '
              'a no perder un solo dato de nadie.',
          'Los temas, las traducciones y los widgets compartidos viven en '
              'un paquete aparte, para que la app no sea el único sitio '
              'donde puedan usarse.',
        ]),
        _segment('04', 'Offline primero', [
          'El contrato con el servidor está al revés de lo habitual: el '
              'cliente manda la fecha de lo último que tiene y el backend '
              'responde con una lista vacía cuando no hay nada nuevo. '
              'Vacío no es un error. El repositorio conserva su cache '
              'local y solo borra y reescribe cuando de verdad llegaron '
              'datos.',
          'La consecuencia es la que importa: la app abre y funciona sin '
              'conexión, y la red solo se usa cuando hay algo que traer.',
        ]),
        _segment('05', 'Cambiar el motor en vuelo', [
          'El backend original era PHP heredado. La migración a Laravel 12 '
              'con panel Filament se hizo sobre la misma base de datos '
              'MySQL que los usuarios de la versión anterior seguían '
              'escribiendo en ese momento. Ninguna migración podía correr '
              'sin contestar antes tres preguntas: qué tabla toca, qué '
              'columnas cambia y si el backend viejo sigue funcionando '
              'después.',
          'Una auditoría de la base encontró que el borrado lógico tenía '
              'dos convenciones opuestas conviviendo. En doce tablas, '
              'deleted = 1 significa borrado. En dos - las reseñas de '
              'profesores y las de materias - significa exactamente lo '
              'contrario, y consultarlas con la convención normal devuelve '
              'el conjunto invertido: todo lo borrado y nada de lo vivo. '
              'No estaba documentado en ninguna parte. Ese tipo de '
              'hallazgo es el trabajo real de sostener algo durante diez '
              'años.',
        ]),
        _segment('06', 'Lo que la mantiene en el aire', [
          '22 idiomas de interfaz, veinte reales y dos de broma. Ocho '
              'temas, incluidos dos monocromos. Firebase para '
              'autenticación, notificaciones, reporte de fallos y '
              'banderas de funcionalidad: se puede apagar una sección, '
              'poner la app entera en mantenimiento u obligar a actualizar '
              'sin pasar por la tienda ni esperar una revisión.',
          'La gamificación - experiencia, insignias, perfil - está '
              'construida y esperando detrás de una de esas banderas. '
              'Poder terminar algo y no encenderlo todavía es, a esta '
              'escala, tan importante como poder construirlo.',
        ]),
      ];
    }
    return [
      _segment('01', 'Origin · 2015', [
        'What a student needed to know already existed, but scattered: '
            'the cut-off scores in a PDF, which professor teaches which '
            'subject in a chat group, how a proficiency exam works in '
            'cafeteria hearsay. DeTodoUIS started as the place where all of '
            'it lived together, and the community filled it in: it now '
            'carries over 6,000 professor reviews written by students.',
      ]),
      _segment('02', 'What it broadcasts', [
        'For applicants: historical cut-off scores with charts, admission '
            'criteria, and the Oracle - a recommender that asks about '
            'interests and returns degrees along with why each one fits. '
            'For students already inside: professor and subject reviews, a '
            'community board, a grade calculator, a campus map, a '
            'dictionary of local slang.',
        'And a layer that is not academic at all: six mini games with '
            'leaderboards, wallpapers, memes. That is deliberate. An app '
            'that is only good for lookups gets opened during enrolment '
            'and forgotten for the rest of the term.',
      ]),
      _segment('03', 'How it is built', [
        'Flutter on Clean Architecture: data, domain and presentation '
            'genuinely separated, BLoC for state, GetIt and Injectable for '
            'dependency injection, GoRouter for navigation. Underneath is '
            'SQLite through Drift, with 31 tables and the schema at version '
            "16: sixteen migrations run inside real people's pockets, "
            'each one required not to lose a single record belonging to '
            'anyone.',
        'Themes, translations and shared widgets live in a separate '
            'package, so the app is not the only place they can ever be '
            'used.',
      ]),
      _segment('04', 'Offline first', [
        'The contract with the server runs the other way round from the '
            'usual one: the client sends the timestamp of the newest thing '
            'it holds, and the backend answers with an empty list when '
            'there is nothing new. Empty is not an error. The repository '
            'keeps its local cache and only wipes and rewrites when data '
            'actually arrived.',
        'The consequence is the part that matters: the app opens and works '
            'with no connection, and the network is used only when there is '
            'something to fetch.',
      ]),
      _segment('05', 'Changing the engine mid-flight', [
        'The original backend was inherited PHP. The move to Laravel 12 '
            'with a Filament admin panel happened on the same MySQL '
            'database that users of the previous release were still writing '
            'to at that moment. No migration could run without answering '
            'three questions first: which table it touches, which columns '
            'it changes, and whether the old backend still works '
            'afterwards.',
        'An audit of the database found two opposite soft-delete '
            'conventions living side by side. In twelve tables, deleted = 1 '
            'means deleted. In two of them - professor reviews and subject '
            'reviews - it means exactly the opposite, so querying those '
            'with the normal convention returns the inverted set: '
            'everything deleted and nothing alive. It was documented '
            'nowhere. That kind of find is the actual work of keeping '
            'something running for ten years.',
      ]),
      _segment('06', 'What keeps it on air', [
        '22 interface languages, twenty real and two as a joke. Eight '
            'themes, two of them monochrome. Firebase for authentication, '
            'notifications, crash reporting and feature flags: a section '
            'can be switched off, the whole app put into maintenance, or an '
            'update forced, without going through a store or waiting on a '
            'review.',
        'The gamification layer - experience, badges, profile - is built '
            'and waiting behind one of those flags. At this scale, being '
            'able to finish something and not turn it on yet matters as '
            'much as being able to build it.',
      ]),
    ];
  }

  /// Closing telemetry, in the same key/value shape the station panels
  /// use, so the long form ends back in the receiver's own language.
  Component _data(bool es) {
    final rows = <(String, String)>[
      (es ? 'VERSIÓN' : 'VERSION', '5.3.1'),
      (
        es ? 'PLATAFORMAS' : 'PLATFORMS',
        'iOS · Android · Web',
      ),
      (es ? 'CLIENTE' : 'CLIENT', 'Flutter · BLoC · Drift'),
      (
        es ? 'ESQUEMA LOCAL' : 'LOCAL SCHEMA',
        es ? 'v16 · 31 tablas' : 'v16 · 31 tables',
      ),
      (es ? 'SERVIDOR' : 'SERVER', 'Laravel 12 · Filament · MySQL'),
      (
        es ? 'PLATAFORMA' : 'PLATFORM',
        es ? 'Firebase · auth, push, flags' : 'Firebase · auth, push, flags',
      ),
      (
        es ? 'ROL' : 'ROLE',
        es ? 'Creador / Mantenedor · desde 2015' : 'Creator / Maintainer · since 2015',
      ),
    ];
    return div(classes: 'rx-data', [
      for (final (k, v) in rows) ...[
        div(classes: 'rx-key', [Component.text(k)]),
        div(classes: 'rx-val', [Component.text(v)]),
      ],
    ]);
  }

  // ── styles ──
  //
  // Only the case-study-specific pieces live here. The dialog chrome
  // (`.rx-overlay`, `.rx-panel`, `.rx-head`, `.rx-body`, `.rx-data`…) is
  // shared with the technical transmission and defined once in
  // `app.dart`: the two panels are the same printout with different
  // contents, and letting them drift apart visually would break that.

  @css
  static List<StyleRule> get styles => [
    // The long form needs more measure than the technical panel: seven
    // segments of prose at 560px would run tall enough to lose the reader
    // inside the scroll.
    css('.rx-panel-wide').styles(maxWidth: 720.px),

    css('.rx-subtitle').styles(
      color: const Color('#938d81'),
      fontFamily: const FontFamily.list([
        FontFamily('IBM Plex Mono'),
        FontFamilies.monospace,
      ]),
      fontSize: Unit.pixels(11),
      fontWeight: FontWeight.w500,
      textTransform: TextTransform.upperCase,
      letterSpacing: 0.24.em,
      raw: {'margin': '-8px 0 16px'},
    ),

    // ── reach figures ──
    // The only place in the piece where a number is allowed to be large.
    // Wraps rather than scrolls, and each figure keeps its unit label
    // underneath so a bare "28k+" never floats without meaning.
    css('.case-figures').styles(
      display: Display.flex,
      padding: Padding.symmetric(vertical: 16.px),
      flexDirection: FlexDirection.row,
      flexWrap: FlexWrap.wrap,
      gap: Gap(row: 12.px, column: 24.px),
      raw: {
        'border-top': '1px solid rgba(255,255,255,0.07)',
        'border-bottom': '1px solid rgba(255,255,255,0.07)',
        'margin-bottom': '24px',
      },
    ),
    css('.case-figure').styles(
      display: Display.flex,
      flexDirection: FlexDirection.column,
      gap: Gap(row: 4.px),
    ),
    css('.case-figure-val').styles(
      color: const Color('#E8944A'),
      fontFamily: const FontFamily.list([
        FontFamily('Space Grotesk'),
        FontFamilies.sansSerif,
      ]),
      fontWeight: FontWeight.w700,
      raw: {
        'font-size': 'clamp(1.5rem, 4.5vw, 2.3rem)',
        'line-height': '1',
        'letter-spacing': '-0.01em',
        'text-shadow': '0 0 10px rgba(232,148,74,0.28)',
      },
    ),
    css('.case-figure-key').styles(
      color: const Color('#938d81'),
      fontFamily: const FontFamily.list([
        FontFamily('IBM Plex Mono'),
        FontFamilies.monospace,
      ]),
      fontSize: Unit.pixels(11),
      fontWeight: FontWeight.w500,
      textTransform: TextTransform.upperCase,
      letterSpacing: 0.16.em,
    ),

    // ── programme segments ──
    // Numbered like the rundown of a broadcast rather than titled like
    // sections of an article. The marker sits in its own column so the
    // headings line up down the left edge and the block scans as a list
    // of segments even before any of it is read.
    css('.case-seg').styles(raw: {'margin-bottom': '24px'}),
    css('.case-seg-head').styles(
      display: Display.flex,
      flexDirection: FlexDirection.row,
      alignItems: AlignItems.baseline,
      gap: Gap(column: 12.px),
      raw: {'margin-bottom': '8px'},
    ),
    css('.case-seg-no').styles(
      // #7a6a4e was the first choice and measured 3.65:1 against the
      // panel, under AA. A segment marker is not decoration - it is how
      // you keep your place in a long read - so it gets a real contrast
      // budget: 5.27:1, still clearly subordinate to the heading beside
      // it.
      color: const Color('#97845f'),
      fontFamily: const FontFamily.list([
        FontFamily('Chakra Petch'),
        FontFamilies.monospace,
      ]),
      fontSize: Unit.pixels(11),
      fontWeight: FontWeight.w700,
      letterSpacing: 0.1.em,
      raw: {'flex-shrink': '0'},
    ),
    css('.case-seg-title').styles(
      color: const Color('#d8c9a4'),
      fontFamily: const FontFamily.list([
        FontFamily('IBM Plex Mono'),
        FontFamilies.monospace,
      ]),
      fontSize: Unit.pixels(12),
      fontWeight: FontWeight.w600,
      textTransform: TextTransform.upperCase,
      letterSpacing: 0.2.em,
    ),
    // Paragraphs inside a segment sit closer to each other than segments
    // do to one another, so the block groups by eye without any rules or
    // boxes doing the work.
    css('.case-seg .rx-body').styles(raw: {'margin': '0 0 10px'}),
    css('.case-seg .rx-body:last-child').styles(raw: {'margin-bottom': '0'}),

    css.media(MediaQuery.screen(maxWidth: 600.px), [
      css('.case-figures').styles(
        gap: Gap(row: 12.px, column: 16.px),
      ),
      css('.case-seg-head').styles(gap: Gap(column: 8.px)),
      css('.case-seg-title').styles(letterSpacing: 0.12.em),
    ]),
  ];
}
