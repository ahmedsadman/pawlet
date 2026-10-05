import 'package:flutter/material.dart';

import '../../services/permissions.dart';
import 'sms_disclosure_screen.dart';

/// The only sanctioned route to SMS permission.
///
/// Google Play treats SMS as a restricted permission and requires a prominent
/// in-app disclosure *before* the system prompt — calling
/// [AppPermissions.requestSms] directly is a policy violation. Returns whether
/// SMS access is granted once the flow settles.
///
/// Declining is not persisted: the app is close to useless without SMS, so the
/// disclosure is offered again on the next launch.
///
/// The named parameters exist so tests can drive the flow without plugins.
Future<bool> ensureSmsAccess(
  BuildContext context, {
  Future<bool> Function() hasSms = AppPermissions.hasSms,
  Future<void> Function() requestSms = AppPermissions.requestSms,
  Future<bool> Function(BuildContext context) disclose = showSmsDisclosure,
}) async {
  if (await hasSms()) return true;
  if (!context.mounted) return false;
  if (!await disclose(context)) return false;
  await requestSms();
  return hasSms();
}
