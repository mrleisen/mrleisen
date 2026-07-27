/// Runtime access to the user's reduced-motion preference.
library;

import 'package:jaspr/jaspr.dart';
import 'package:universal_web/web.dart' as web;

/// Whether the user has asked their OS for reduced motion.
///
/// Most of the radio's motion is CSS, and the `(prefers-reduced-motion:
/// reduce)` block in `main.server.dart` handles all of it. A couple of
/// effects are driven from Dart instead - the LCD digit scramble and the
/// power-on signal sweep - because they swap rendered values rather than
/// animate a property, so no stylesheet can switch them off. Those check
/// this getter and skip straight to the settled state.
///
/// Always false during SSR: the server has no window to ask, and the
/// client re-reads the preference on hydration anyway.
bool get prefersReducedMotion {
  if (!kIsWeb) return false;
  try {
    return web.window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  } catch (_) {
    // matchMedia is missing on some very old or embedded browsers.
    // Falling back to "full motion" matches the historical behaviour.
    return false;
  }
}
