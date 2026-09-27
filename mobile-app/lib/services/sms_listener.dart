import 'dart:ui';

import 'package:another_telephony/telephony.dart';
import 'package:flutter/widgets.dart';

import 'app_services.dart';

/// Runs in a separate background isolate when an SMS arrives while the app is
/// killed or backgrounded. Must be a top-level function.
@pragma('vm:entry-point')
Future<void> backgroundSmsHandler(SmsMessage message) async {
  WidgetsFlutterBinding.ensureInitialized();
  // A fresh background isolate must register plugins itself, otherwise sqflite /
  // shared_preferences channels throw MissingPluginException.
  DartPluginRegistrant.ensureInitialized();
  final services = await AppServices.bootstrap();
  try {
    await services.handleIncomingSms(message);
  } finally {
    // Release the isolate-local http client + DB handle.
    await services.disposeStandalone();
  }
}

/// Registers foreground + background incoming-SMS handlers.
class SmsListener {
  SmsListener(this._services, {Telephony? telephony})
    : _telephony = telephony ?? Telephony.instance;

  final AppServices _services;
  final Telephony _telephony;

  void start() {
    _telephony.listenIncomingSms(
      onNewMessage: _services.handleIncomingSms,
      onBackgroundMessage: backgroundSmsHandler,
      listenInBackground: true,
    );
  }
}
