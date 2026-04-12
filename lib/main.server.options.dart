// dart format off
// ignore_for_file: type=lint

// GENERATED FILE, DO NOT MODIFY
// Generated with jaspr_builder

import 'package:jaspr/server.dart';
import 'package:radio/components/radio_dial.dart' as _radio_dial;
import 'package:radio/components/scanlines.dart' as _scanlines;
import 'package:radio/components/signal_bars.dart' as _signal_bars;
import 'package:radio/components/static_noise.dart' as _static_noise;
import 'package:radio/components/station_display.dart' as _station_display;
import 'package:radio/components/vignette.dart' as _vignette;
import 'package:radio/app.dart' as _app;

/// Default [ServerOptions] for use with your Jaspr project.
///
/// Use this to initialize Jaspr **before** calling [runApp].
///
/// Example:
/// ```dart
/// import 'main.server.options.dart';
///
/// void main() {
///   Jaspr.initializeApp(
///     options: defaultServerOptions,
///   );
///
///   runApp(...);
/// }
/// ```
ServerOptions get defaultServerOptions => ServerOptions(
  clientId: 'main.client.dart.js',
  clients: {_app.App: ClientTarget<_app.App>('app')},
  styles: () => [
    ..._radio_dial.RadioDialState.styles,
    ..._scanlines.Scanlines.styles,
    ..._signal_bars.SignalBars.styles,
    ..._static_noise.StaticNoise.styles,
    ..._station_display.StationDisplay.styles,
    ..._vignette.Vignette.styles,
    ..._app.AppState.styles,
  ],
);
