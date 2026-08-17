import 'dart:async';
import 'dart:math' as math;

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:universal_web/js_interop.dart';
import 'package:universal_web/web.dart' as web;

import '../models/pixel_art.dart';
import '../models/pixel_art_shadows.dart' deferred as pixel_shadows;
import '../models/station.dart';
import '../utils/keyboard.dart';
import 'rx_chrome.dart';
import 'station_display.dart' show Lang;

/// The pieces are untitled on purpose - they never had names, and
/// inventing them here would be captioning somebody else's art. The
/// visible identifier is `pixel-art-N`, N being rail order.
String pixelArtName(PixelSprite sprite) => 'pixel-art-${pixelArtPieces.indexOf(sprite) + 1}';

// ── deferred sprite data ──
//
// The shadow strings are ~2 MB of generated text, which is most of the
// client bundle. They ship as their own dart2js part file behind the
// `deferred` import above, and nothing downloads it until the dial
// actually approaches AM 1440 - `AppState._recalc` calls
// [loadPixelShadows] as the carrier comes into reach, so by the time
// the rails are on screen the art is usually already there. Until it
// is, the rails show their empty frames and fill in on arrival.

Future<void>? _shadowsRequest;
bool _shadowsReady = false;

/// Fetches the sprite part file once; safe to call repeatedly. A failed
/// fetch (offline, interrupted) clears the request so the next approach
/// to the station simply tries again.
Future<void> loadPixelShadows() async {
  if (_shadowsReady) return;
  try {
    await (_shadowsRequest ??= pixel_shadows.loadLibrary());
    _shadowsReady = true;
  } catch (_) {
    _shadowsRequest = null;
  }
}

/// The box-shadow string for [id], or null while the sprite data has
/// not arrived yet.
String? pixelShadowFor(String id) => _shadowsReady ? pixel_shadows.pixelShadows[id] : null;

/// The two vertical rails of artwork that appear at the sides of the
/// screen while the dial is on (or near) PIX, AM 1440.
///
/// They fade with the same curve as the station panel - full inside
/// lockRange, decaying to 30% at the tolerance edge - so the frames read
/// as part of the transmission, not as site chrome that happens to know
/// about a station. Selecting a piece opens its puzzle, which is owned
/// by `AppState` because it rides the shared printout-dialog state (one
/// Escape handler, one focus trap - see `_openDialog` in `app.dart`).
///
/// Sprites are applied as *inline* box-shadows and only while the rails
/// are visible: the shadow strings are large, and this keeps them out of
/// both the stylesheet and the prerendered HTML - they ship once, in the
/// client bundle, and materialise in the DOM only on this station.
///
/// NOTE: deliberately NOT marked `@client` - the parent `App` is already
/// the hydration island, same as every other content layer.
class PixelRails extends StatelessComponent {
  const PixelRails({
    required this.frequency,
    required this.band,
    required this.lang,
    required this.isPowered,
    required this.solved,
    required this.onOpenPuzzle,
    super.key,
  });

  final double frequency;
  final Band band;
  final Lang lang;
  final bool isPowered;

  /// Ids of pieces whose puzzle has been completed, in discovery order.
  final Set<String> solved;

  final void Function(String pieceId) onOpenPuzzle;

  /// Id stamped on each piece so the dialog can hand focus back to the
  /// exact thumbnail that opened it.
  static String thumbId(String pieceId) => 'pix-thumb-$pieceId';

  @override
  Component build(BuildContext context) {
    final pix = stationsFor(band).where((st) => st.callSign == 'PIX').firstOrNull;
    var opacity = 0.0;
    var visible = false;
    if (isPowered && pix != null) {
      final cfg = configFor(band);
      final d = (frequency - pix.frequency).abs();
      if (d <= cfg.lockRange) {
        opacity = 1.0;
        visible = true;
      } else if (d < cfg.tolerance) {
        opacity = 1.0 - ((d - cfg.lockRange) / (cfg.tolerance - cfg.lockRange)) * 0.7;
        visible = true;
      }
    }

    // Alternate pieces across the two rails so both columns carry the
    // whole range of sizes and the numbering walks left-right-left.
    Component rail(String side, bool Function(int index) takes) => div(
      classes: 'pix-rail pix-rail-$side',
      styles: Styles(
        opacity: opacity,
        raw: {
          '--sc': pix?.color ?? '#7B8FE8',
          'visibility': visible ? 'visible' : 'hidden',
        },
      ),
      [
        for (var i = 0; i < pixelArtPieces.length; i++)
          if (takes(i)) _thumb(pixelArtPieces[i], i, visible),
      ],
    );

    return div(classes: 'pix-rails', [
      rail('left', (n) => n.isEven),
      rail('right', (n) => n.isOdd),
    ]);
  }

  Component _thumb(PixelSprite sp, int index, bool visible) {
    final es = lang == Lang.es;
    final shadow = pixelShadowFor(sp.id);
    final isSolved = solved.contains(sp.id);
    final name = 'pixel-art-${index + 1}';
    final label = isSolved
        ? (es ? '$name - obra completa, armar de nuevo' : '$name - complete, assemble again')
        : (es ? '$name - armar rompecabezas' : '$name - assemble puzzle');
    return div(
      classes: 'pix-thumb${isSolved ? ' pix-thumb-solved' : ''}',
      attributes: {
        'id': thumbId(sp.id),
        'role': 'button',
        // Hidden rails are already out of the tab order via
        // `visibility: hidden`; the explicit -1 covers the fade zone
        // where the rail is technically visible but on its way out.
        'tabindex': visible ? '0' : '-1',
        'aria-label': label,
      },
      events: {
        'click': (_) => onOpenPuzzle(sp.id),
        'keydown': onActivateKey((_) => onOpenPuzzle(sp.id)),
      },
      [
        div(
          classes: 'pix-thumb-art',
          attributes: const {'aria-hidden': 'true'},
          styles: Styles(raw: {'--gw': '${sp.gridW}', '--gh': '${sp.gridH}'}),
          [
            div(classes: 'pix-frame', [
              // The sprite exists only while the rails do, and only
              // once the deferred sprite data has arrived - until then
              // the frame is an empty slot the art tunes into.
              if (visible && shadow != null)
                span(
                  classes: 'pix-sprite',
                  styles: Styles(raw: {'box-shadow': shadow}),
                  [],
                ),
            ]),
          ],
        ),
        if (isSolved)
          span(
            classes: 'pix-thumb-check',
            attributes: const {'aria-hidden': 'true'},
            [Component.text('✓')],
          ),
      ],
    );
  }

  // ── styles ──

  @css
  static List<StyleRule> get styles => [
    // The wrapper exists only so `App.build` can mount both rails as one
    // component; it must not introduce a box of its own.
    css('.pix-rails').styles(raw: {'display': 'contents'}),
    css('.pix-rail').styles(
      display: Display.flex,
      position: Position.absolute(
        // Same anchor as the carrier monitor and the station display:
        // the middle of whatever room the faceplate leaves.
        top: Unit.expression('calc(var(--free-h) / 2)'),
      ),
      zIndex: ZIndex(32),
      flexDirection: FlexDirection.column,
      gap: Gap(row: 14.px),
      raw: {
        'max-height': 'calc(var(--free-h) - 24px)',
        'overflow-y': 'auto',
        'padding': '12px 4px',
        'transform': 'translateY(-50%)',
        'transition': 'opacity 0.4s ease',
        // The column scrolls; its edges dissolve instead of clipping,
        // which both hints at more pieces and swallows the scrollbar.
        'mask-image': 'linear-gradient(transparent, #000 14px, #000 calc(100% - 14px), transparent)',
        '-webkit-mask-image': 'linear-gradient(transparent, #000 14px, #000 calc(100% - 14px), transparent)',
        'scrollbar-width': 'none',
      },
    ),
    css('.pix-rail::-webkit-scrollbar').styles(raw: {'display': 'none'}),
    css('.pix-rail-left').styles(raw: {'left': '14px'}),
    css('.pix-rail-right').styles(raw: {'right': '14px'}),
    css('.pix-thumb').styles(
      position: Position.relative(),
      padding: Padding.all(7.px),
      cursor: Cursor.pointer,
      raw: {
        'flex-shrink': '0',
        'border': '1px dashed color-mix(in srgb, var(--sc, #7B8FE8) 35%, rgba(255,255,255,0.10))',
        'border-radius': '3px',
        'background': 'rgba(10, 10, 14, 0.55)',
        'transition': 'border-color 0.2s ease, box-shadow 0.2s ease',
        'touch-action': 'manipulation',
        '-webkit-tap-highlight-color': 'transparent',
        'user-select': 'none',
        '-webkit-user-select': 'none',
      },
    ),
    css('.pix-thumb:focus-visible').styles(
      raw: {
        'outline': '2px solid color-mix(in srgb, var(--sc, #7B8FE8) 70%, #ffffff)',
        'outline-offset': '2px',
      },
    ),
    css('.pix-thumb-solved').styles(
      raw: {
        'border-style': 'solid',
        'border-color': 'color-mix(in srgb, var(--sc, #7B8FE8) 55%, rgba(255,255,255,0.10))',
      },
    ),
    // Inside the thumb's border: the rail scrolls, so anything hanging
    // outside the thumb would be clipped by the scroll container.
    css('.pix-thumb-check').styles(
      display: Display.flex,
      position: Position.absolute(top: 3.px, right: 3.px),
      width: 14.px,
      height: 14.px,
      justifyContent: JustifyContent.center,
      alignItems: AlignItems.center,
      color: const Color('#050507'),
      fontSize: 9.px,
      fontWeight: FontWeight.w700,
      raw: {
        'background': '#E8A035',
        'border-radius': '50%',
        'line-height': '1',
      },
    ),
    // The art scales through font-size: one CSS pixel of the piece is
    // 1em. Snapped to whole CSS pixels where `round()` exists (the
    // second rule): at a fractional pixel size adjacent box-shadows
    // don't quite abut and the art comes out pinstriped; a browser
    // without `round()` keeps the fractional (striped but present)
    // first rule. Grids up to 64 render crisp at an integer size; a
    // bigger grid draws at 1px per pixel and the *frame* is
    // transform-scaled into the 64px column - a resampled shrink,
    // slightly soft, which at thumbnail size reads better than
    // dropping every other pixel would.
    css('.pix-thumb-art').styles(
      raw: {
        'font-size': 'calc(64px / var(--gw, 48))',
        'width': 'min(calc(var(--gw, 48) * 1em), 64px)',
        'height': 'min(calc(var(--gh, 48) * 1em), calc(var(--gh, 48) * 64px / var(--gw, 48)))',
        'overflow': 'hidden',
        'transition': 'filter 0.5s ease',
      },
    ),
    // An unassembled piece broadcasts in grayscale; completing its
    // puzzle is what brings the colour in. The reward reads on the rail
    // itself, not just in the check chip.
    css('.pix-thumb:not(.pix-thumb-solved) .pix-thumb-art').styles(
      raw: {'filter': 'grayscale(1)'},
    ),
    css('.pix-thumb-art').styles(
      raw: {'font-size': 'max(1px, round(down, calc(64px / var(--gw, 48)), 1px))'},
    ),
    css('.pix-thumb-art .pix-frame').styles(
      raw: {
        'transform': 'scale(min(1, calc(64 / var(--gw, 48))))',
        'transform-origin': 'top left',
      },
    ),
    css('.pix-frame').styles(
      position: Position.relative(),
      raw: {
        'width': 'calc(var(--gw, 48) * 1em)',
        'height': 'calc(var(--gh, 48) * 1em)',
      },
    ),
    // The sprite element itself: every opaque pixel is a box-shadow at
    // (x+1)em (y+1)em, so the element sits one pixel up-left of where
    // the artwork should start. See `tool/generate_pixel_css.dart`.
    css('.pix-sprite').styles(
      display: Display.block,
      position: Position.absolute(top: (-1).em, left: (-1).em),
      width: 1.em,
      height: 1.em,
    ),

    // ── the puzzle ──
    css('.pz-stage').styles(
      position: Position.relative(),
      raw: {
        'margin': '4px auto 0',
        'width': 'fit-content',
      },
    ),
    css('.pz-grid').styles(
      display: Display.grid,
      justifyContent: JustifyContent.center,
      raw: {
        'grid-template-columns': 'repeat(3, auto)',
        'gap': '2px',
        // Sized to fit the printout on either axis, whichever bites
        // first - several pieces are taller than they are wide.
        'font-size': 'min(calc(min(56vw, 300px) / var(--gw, 48)), calc(min(44vh, 340px) / var(--gh, 48)))',
        'transition': 'gap 0.35s ease, filter 0.6s ease',
      },
    ),
    // Grey until first assembled - the colour arriving with the last
    // swap is the moment the puzzle pays off. Only ever-unsolved pieces
    // carry this class; replays after SCRAMBLE stay in colour.
    css('.pz-grid.pz-gray').styles(
      raw: {'filter': 'grayscale(1)'},
    ),
    // Same whole-pixel snap as `.pix-thumb-art`, same fallback rationale.
    css('.pz-grid').styles(
      raw: {
        'font-size':
            'max(1px, round(down, min(calc(min(56vw, 300px) / var(--gw, 48)), calc(min(44vh, 340px) / var(--gh, 48))), 1px))',
      },
    ),
    css('.pz-grid.pz-solved').styles(
      raw: {'gap': '0px'},
    ),
    css('.pz-tile').styles(
      position: Position.relative(),
      cursor: Cursor.pointer,
      raw: {
        'width': 'calc(var(--gw, 48) * 1em / 3)',
        'height': 'calc(var(--gh, 48) * 1em / 3)',
        'overflow': 'hidden',
        // A faint seam so a transparent piece still reads as nine
        // tiles while scrambled.
        'box-shadow': 'inset 0 0 0 1px rgba(255,255,255,0.06)',
        'touch-action': 'manipulation',
        '-webkit-tap-highlight-color': 'transparent',
      },
    ),
    css('.pz-grid.pz-solved .pz-tile').styles(
      cursor: Cursor.defaultCursor,
      raw: {'box-shadow': 'none'},
    ),
    css('.pz-tile:focus-visible').styles(
      raw: {
        'outline': '2px solid color-mix(in srgb, var(--sc, #7B8FE8) 70%, #ffffff)',
        'outline-offset': '-2px',
      },
    ),
    // Selection ring as an overlay rather than an inset shadow on the
    // tile: the sprite is a child element and paints over the tile's own
    // box-shadow, so an inset ring only showed through transparent
    // pixels - invisible on a fully opaque piece.
    css('.pz-tile-sel::after').styles(
      position: Position.absolute(
        top: Unit.zero,
        left: Unit.zero,
      ),
      zIndex: ZIndex(1),
      width: 100.percent,
      height: 100.percent,
      pointerEvents: PointerEvents.none,
      raw: {
        'content': '""',
        // Explicit rather than inherited from a global reset: with
        // content-box sizing the 2px border would land outside the
        // 100% box and the tile's `overflow: hidden` would clip the
        // right and bottom edges of the ring.
        'box-sizing': 'border-box',
        'border': '2px solid #E8A035',
        'box-shadow': '0 0 8px rgba(232, 160, 53, 0.45), inset 0 0 6px rgba(232, 160, 53, 0.35)',
      },
    ),
    // The reward: the full-quality original (gif or png), revealed over
    // the completed grid once the file has actually arrived - a broken
    // image would be a poor prize, so the sprite keeps showing until
    // `load` fires.
    css('.pz-reward').styles(
      position: Position.absolute(
        top: Unit.zero,
        left: Unit.zero,
      ),
      width: 100.percent,
      height: 100.percent,
      opacity: 0.0,
      raw: {
        'object-fit': 'contain',
        'image-rendering': 'pixelated',
        'transition': 'opacity 0.45s ease',
      },
    ),
    css('.pz-reward-on').styles(opacity: 1.0),
    // Completion line. Reserved height whether empty or filled, so the
    // printout doesn't jump when the artwork comes together.
    css('.pz-state').styles(
      minHeight: 18.px,
      color: const Color('#E8A035'),
      fontSize: 11.px,
      fontWeight: FontWeight.w500,
      letterSpacing: 0.3.em,
      raw: {
        'text-align': 'center',
        'text-transform': 'uppercase',
      },
    ),
    css('.pz-actions').styles(
      display: Display.flex,
      justifyContent: JustifyContent.center,
    ),
    // The SCRAMBLE control, in the printouts' pill vocabulary.
    css('.pz-reset').styles(
      padding: Padding.symmetric(horizontal: 14.px, vertical: 5.px),
      cursor: Cursor.pointer,
      color: const Color('#E8A035'),
      fontSize: 11.px,
      fontWeight: FontWeight.w500,
      letterSpacing: 0.16.em,
      raw: {
        'border': '1px solid rgba(232, 160, 53, 0.35)',
        'border-radius': '999px',
        'text-transform': 'uppercase',
        'transition': 'border-color 0.2s ease, box-shadow 0.2s ease',
        'user-select': 'none',
        '-webkit-user-select': 'none',
        'touch-action': 'manipulation',
        '-webkit-tap-highlight-color': 'transparent',
      },
    ),
    css('.pz-reset:focus-visible').styles(
      raw: {
        'outline': '2px solid #E8A035',
        'outline-offset': '2px',
      },
    ),

    css.media(const MediaQuery.raw('(hover: hover)'), [
      css('.pix-thumb:hover').styles(
        raw: {
          'border-color': 'color-mix(in srgb, var(--sc, #7B8FE8) 70%, rgba(255,255,255,0.10))',
          'box-shadow': '0 0 10px color-mix(in srgb, var(--sc, #7B8FE8) 25%, transparent)',
        },
      ),
      css('.pz-reset:hover').styles(
        raw: {
          'border-color': 'rgba(232, 160, 53, 0.75)',
          'box-shadow': '0 0 8px rgba(232, 160, 53, 0.25)',
        },
      ),
    ]),
    css.media(MediaQuery.screen(maxWidth: 600.px), [
      // The AM card is 420px wide and centred; on a phone the rails
      // share the same horizontal space, so they shrink and hug the
      // edges. The PIX card itself narrows via `.station-pix` below.
      css('.pix-rail').styles(gap: Gap(row: 10.px)),
      css('.pix-rail-left').styles(raw: {'left': '6px'}),
      css('.pix-rail-right').styles(raw: {'right': '6px'}),
      css('.pix-thumb').styles(padding: Padding.all(5.px)),
      // On a phone the em-snap approach fails: under 1px per pixel the
      // floor would render every large piece at its native size, wide
      // enough to land on top of the card. Instead the art draws at
      // 1 CSS pixel per pixel and the *frame* is transform-scaled down
      // to a 44px column - a resampled shrink, slightly soft, which at
      // thumbnail size reads better than stripes ever did. Small pieces
      // (grid ≤ 44) stay 1:1 and crisp; min() keeps them from being
      // blurred *up*.
      css('.pix-thumb-art').styles(
        raw: {
          'font-size': '1px',
          'width': 'min(calc(var(--gw, 48) * 1px), 44px)',
          'height': 'min(calc(var(--gh, 48) * 1px), calc(var(--gh, 48) * 44px / var(--gw, 48)))',
          'overflow': 'hidden',
        },
      ),
      css('.pix-thumb-art .pix-frame').styles(
        raw: {
          'transform': 'scale(min(1, calc(44 / var(--gw, 48))))',
          'transform-origin': 'top left',
        },
      ),
    ]),
    // The PIX card leaves room for the rails at every width: the rails
    // are part of this station's transmission, and the card conceding
    // the sides is what keeps the two from overlapping on a phone.
    // 148px = two 56px thumb columns plus their edge offsets and air.
    css('.station-pix .am-shell').styles(
      raw: {'max-width': 'min(420px, calc(100vw - 148px))'},
    ),
    css.media(const MediaQuery.raw('(prefers-reduced-motion: reduce)'), [
      css('.pix-rail').styles(raw: {'transition': 'none'}),
      css('.pix-thumb-art').styles(raw: {'transition': 'none'}),
      css('.pz-grid').styles(raw: {'transition': 'none'}),
      css('.pz-reward').styles(raw: {'transition': 'none'}),
    ]),
  ];
}

/// The puzzle: the selected artwork, cut 3×3 and shuffled, printed in
/// the same `.rx-*` chrome as the other printouts. Swap two tiles at a
/// time until the piece comes back together; completing it reveals the
/// animated original (`web/pixel/<id>.gif`) when one exists - the only
/// image files on the site, each one earned.
///
/// A swap puzzle rather than a slide puzzle on purpose: every shuffle is
/// trivially solvable (swaps generate the whole permutation group), and
/// tap-tap-swap works identically with a finger, a mouse and a keyboard.
///
/// The dial stays live behind the printout, so the carrier this artwork
/// rode in on can be tuned away while it is open - [signal] drives the
/// same weak/lost states as the other printouts.
class PixelPuzzleDialog extends StatefulComponent {
  const PixelPuzzleDialog({
    required this.pieceId,
    required this.lang,
    required this.dialogId,
    required this.onClose,
    required this.onSolved,
    required this.signal,
    this.alreadySolved = false,
    super.key,
  });

  final String pieceId;
  final Lang lang;

  /// The piece has been completed before (this visit or a past one).
  /// A completed piece opens already assembled, in colour, with the
  /// SCRAMBLE control offering a replay - and grayscale never applies
  /// to it again: grey is only for art nobody has assembled yet.
  final bool alreadySolved;

  /// Id stamped on the panel so `AppState` can focus it and trap Tab.
  final String dialogId;

  final VoidCallback onClose;
  final void Function(String pieceId) onSolved;
  final RxSignalState signal;

  static const String titleId = 'pz-title';

  @override
  State<PixelPuzzleDialog> createState() => PixelPuzzleDialogState();
}

class PixelPuzzleDialogState extends State<PixelPuzzleDialog> {
  static const int _side = 3;
  static const int _cells = _side * _side;

  /// `_order[slot]` is which home tile is currently sitting in [slot].
  late List<int> _order;
  int? _selected;
  bool _solved = false;

  /// The full-quality reward file has finished loading and can replace
  /// the sprite.
  bool _rewardReady = false;

  final math.Random _rng = math.Random();

  @override
  void initState() {
    super.initState();
    _order = List<int>.generate(_cells, (n) => n);
    // A piece completed before opens assembled; the board only starts
    // scrambled while there is still something to earn (or after a
    // deliberate SCRAMBLE).
    if (component.alreadySolved) {
      _solved = true;
    } else {
      _scramble();
    }
    // Normally already fetched by the approach to the station; this is
    // the belt-and-braces path (e.g. a preset recall straight into the
    // puzzle) - repaint when the sprite data lands.
    if (pixelShadowFor(component.pieceId) == null) {
      loadPixelShadows().then((_) {
        if (mounted) setState(() {});
      });
    }
  }

  /// Random swaps from solved, redrawn on the vanishingly small chance
  /// the shuffle lands back on the identity.
  void _scramble() {
    do {
      for (var i = 0; i < 24; i++) {
        _swap(_rng.nextInt(_cells), _rng.nextInt(_cells));
      }
    } while (_isSolved);
  }

  /// The SCRAMBLE control: back to a shuffled board for a replay. The
  /// earned state is untouched - colour stays, the rail check stays -
  /// so this is play, not un-solving.
  void _reset() {
    setState(() {
      _scramble();
      _selected = null;
      _solved = false;
      _rewardReady = false;
    });
    if (!kIsWeb) return;
    // The control the user just pressed is about to disappear; hand
    // focus to the first tile so a keyboard replay starts where the
    // game is.
    Timer(Duration.zero, () {
      if (!mounted) return;
      final el = web.document.querySelector('.pz-tile');
      if (el.isA<web.HTMLElement>()) (el as web.HTMLElement).focus();
    });
  }

  bool get _isSolved {
    for (var i = 0; i < _cells; i++) {
      if (_order[i] != i) return false;
    }
    return true;
  }

  void _swap(int a, int b) {
    final t = _order[a];
    _order[a] = _order[b];
    _order[b] = t;
  }

  void _tap(int slot) {
    if (_solved) return;
    final sel = _selected;
    if (sel == null || sel == slot) {
      setState(() => _selected = sel == null ? slot : null);
      return;
    }
    setState(() {
      _swap(sel, slot);
      _selected = null;
      _solved = _isSolved;
    });
    if (_solved) component.onSolved(component.pieceId);
  }

  @override
  Component build(BuildContext context) {
    final es = component.lang == Lang.es;
    final piece = pixelArtPieces.where((pc) => pc.id == component.pieceId).firstOrNull;
    if (piece == null) return div([]);
    final sig = component.signal;
    final tw = piece.gridW / _side;
    final th = piece.gridH / _side;

    return div(
      classes: 'rx-overlay',
      events: {
        // Backdrop press closes; guarded on the target so a press
        // inside the panel doesn't dismiss it.
        'click': (web.Event e) {
          final t = e.target;
          if (t.isA<web.Element>() && (t as web.Element).classList.contains('rx-overlay')) {
            component.onClose();
          }
        },
      },
      [
        div(
          classes: 'rx-panel${sig.panelClass}',
          styles: Styles(
            raw: {
              '--distortion': sig.distortion.toStringAsFixed(3),
              '--sc': '#7B8FE8',
            },
          ),
          attributes: {
            'id': component.dialogId,
            'role': 'dialog',
            'aria-modal': 'true',
            'aria-labelledby': PixelPuzzleDialog.titleId,
            'tabindex': '-1',
          },
          [
            rxHead(
              label: es ? 'ROMPECABEZAS' : 'PUZZLE',
              lang: component.lang,
              state: sig,
              onClose: component.onClose,
            ),
            if (sig.lost) rxLostPlate(lang: component.lang, state: sig),
            h2(classes: 'rx-title', id: PixelPuzzleDialog.titleId, [
              Component.text(pixelArtName(piece)),
            ]),
            p(classes: 'rx-body', [
              Component.text(
                es
                    ? 'Arma la obra pieza por pieza: dos casillas se '
                          'intercambian con cada toque.'
                    : 'Assemble the artwork piece by piece: two tiles '
                          'swap with each tap.',
              ),
            ]),
            div(classes: 'pz-stage', [
              div(
                // pz-gray only while the piece has never been assembled:
                // grey is the unearned state, and a replay after
                // SCRAMBLE plays in colour.
                classes:
                    'pz-grid'
                    '${_solved ? ' pz-solved' : ''}'
                    '${!_solved && !component.alreadySolved ? ' pz-gray' : ''}',
                styles: Styles(raw: {'--gw': '${piece.gridW}', '--gh': '${piece.gridH}'}),
                attributes: {
                  'role': 'group',
                  'aria-label': es ? 'Rompecabezas de 9 casillas' : '9-tile puzzle',
                },
                [for (var slot = 0; slot < _cells; slot++) _tile(slot, piece, tw, th, es)],
              ),
              // Every completion reveals the full-quality original -
              // animated gif when one exists, the source png otherwise.
              // The shipped sprite may be decimated for weight, and the
              // finished artwork is the one moment that must not show it.
              if (_solved)
                img(
                  classes: 'pz-reward${_rewardReady ? ' pz-reward-on' : ''}',
                  src: 'pixel/${piece.id}.${piece.hasGif ? 'gif' : 'png'}',
                  alt: '',
                  attributes: const {'aria-hidden': 'true'},
                  events: {'load': (_) => setState(() => _rewardReady = true)},
                ),
            ]),
            div(
              classes: 'pz-state',
              attributes: const {'role': 'status', 'aria-live': 'polite'},
              [if (_solved) Component.text(es ? 'Obra completa' : 'Artwork complete')],
            ),
            if (_solved)
              div(classes: 'pz-actions', [
                span(
                  classes: 'pz-reset',
                  attributes: const {'role': 'button', 'tabindex': '0'},
                  events: {
                    'click': (_) => _reset(),
                    'keydown': onActivateKey((_) => _reset()),
                  },
                  [Component.text(es ? 'Desarmar' : 'Scramble')],
                ),
              ]),
            rxHint(component.lang),
          ],
        ),
      ],
    );
  }

  Component _tile(int slot, PixelSprite piece, double tw, double th, bool es) {
    final v = _order[slot];
    final r = v ~/ _side;
    final c = v % _side;
    final selected = _selected == slot;
    return div(
      classes: 'pz-tile${selected ? ' pz-tile-sel' : ''}',
      attributes: {
        'role': 'button',
        'tabindex': _solved ? '-1' : '0',
        'aria-pressed': '$selected',
        'aria-label': es ? 'Casilla ${slot + 1} de 9' : 'Tile ${slot + 1} of 9',
      },
      events: {
        'click': (_) => _tap(slot),
        'keydown': onActivateKey((_) => _tap(slot)),
      },
      [
        // The full sprite, shifted so this tile's third shows through
        // the viewport. The extra -1em is the sprite's own offset - see
        // `.pix-sprite`. Empty until the deferred sprite data arrives.
        if (pixelShadowFor(piece.id) case final String shadow)
          span(
            classes: 'pix-sprite',
            styles: Styles(
              raw: {
                'box-shadow': shadow,
                'top': '${(-1 - r * th).toStringAsFixed(4)}em',
                'left': '${(-1 - c * tw).toStringAsFixed(4)}em',
              },
            ),
            [],
          ),
      ],
    );
  }
}
