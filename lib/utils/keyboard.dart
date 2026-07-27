/// Shared keyboard helpers for the faceplate's custom controls.
library;

import 'package:universal_web/web.dart' as web;

/// Wraps [handler] so it fires on Enter or Space, the way a native
/// `<button>` would.
///
/// Every control on the faceplate is a styled `span` or `div` carrying
/// `role="button"` / `role="switch"`, because none of them can be a real
/// `<button>` without inheriting a user-agent appearance that fights the
/// hardware look. That trade means the keyboard behaviour a native
/// button gives away for free has to be added back by hand, and it is
/// easy to add `tabindex` to something and then forget this half - which
/// produces a control you can focus but not operate.
///
/// [handler] receives the original event so callers can `preventDefault`
/// or reuse the same function they pass to `click`.
///
/// Space is intercepted rather than allowed through: on a control with
/// `tabindex`, the default action is to scroll the page.
void Function(web.Event) onActivateKey(void Function(web.Event) handler) {
  return (web.Event e) {
    final ke = e as web.KeyboardEvent;
    // 'Spacebar' is the legacy IE/Edge spelling; harmless to accept.
    if (ke.key == 'Enter' || ke.key == ' ' || ke.key == 'Spacebar') {
      ke.preventDefault();
      handler(e);
    }
  };
}
