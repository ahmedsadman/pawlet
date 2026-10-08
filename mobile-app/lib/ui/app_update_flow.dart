import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/app_update_service.dart';
import '../state/providers.dart';
import 'widgets/sheet_parts.dart';

/// How long the restart bar shows before auto-hiding.
const restartBarDuration = Duration(seconds: 10);

/// Per-app guard so a resume or a second tap can't stack another sheet.
final _flowGuardProvider = Provider<_FlowGuard>((_) => _FlowGuard());

class _FlowGuard {
  bool busy = false;
  bool restartBarShowing = false;
}

/// Asks Play whether there is an update and walks the user through it.
///
/// [manual] is the Settings button: it ignores the "Not now" snooze and says
/// what it found. The automatic check stays silent unless it has something to
/// offer.
///
/// [canPrompt] is read again right before the sheet goes up. The automatic
/// check passes "is the app still unlocked", because a modal sheet would
/// otherwise cover the lock screen.
Future<void> runAppUpdateCheck(
  BuildContext context,
  WidgetRef ref, {
  bool manual = false,
  bool Function()? canPrompt,
}) async {
  // Read providers before acquiring the guard.
  final service = ref.read(appUpdateServiceProvider);
  final messenger = ScaffoldMessenger.of(context);
  final guard = ref.read(_flowGuardProvider);

  if (guard.busy) return;

  // For automatic checks: if a download is known, show the restart bar
  // without asking Play; if the last check was recent, skip.
  if (!manual) {
    if (service.isDownloaded) {
      _showRestartSnackBar(guard, messenger, service);
      return;
    }
    if (!service.takeAutomaticCheck()) return;
  }

  guard.busy = true;
  bool? updateAccepted;

  try {
    final status = await service.check();
    if (!context.mounted) return;
    switch (status) {
      case UpdateStatus.downloaded:
        _showRestartSnackBar(guard, messenger, service);
      case UpdateStatus.inProgress:
        if (manual) _toast(messenger, 'The update is downloading');
      case UpdateStatus.upToDate:
        if (manual) _toast(messenger, "You're on the latest version");
      case UpdateStatus.unsupported:
        if (manual) _toast(messenger, "Couldn't check for updates right now");
      case UpdateStatus.available:
        if (!manual && service.isSnoozed) return;
        if (canPrompt != null && !canPrompt()) return;
        updateAccepted = await confirmAppUpdate(context);
    }
  } finally {
    guard.busy = false;
  }

  // Handle the update decision outside the guard. Play may never resolve the
  // download (cancelled from Play's notification, app killed), and while it
  // runs, check() reports inProgress so nothing re-offers it anyway.
  if (updateAccepted == true) {
    switch (await service.start()) {
      case UpdateStartResult.downloaded:
        _showRestartSnackBar(guard, messenger, service);
      case UpdateStartResult.declined:
        await service.snooze();
      case UpdateStartResult.failed:
        _toast(
          messenger,
          "The update couldn't download. Try again from Settings.",
        );
    }
  } else if (updateAccepted == false) {
    await service.snooze();
  }
}

/// The update offer. Resolves true when the user taps Update; dismissing the
/// sheet counts as "Not now".
Future<bool> confirmAppUpdate(BuildContext context) async {
  final accepted = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => const _UpdateOfferSheet(),
  );
  return accepted ?? false;
}

/// Shows the restart bar. Returns to foreground after a check reminds
/// the user, and it does not block other snackbars.
void _showRestartSnackBar(
  _FlowGuard guard,
  ScaffoldMessengerState messenger,
  AppUpdateService service,
) {
  if (!messenger.mounted) return;

  // Skip if we're already showing a restart bar (avoids queueing duplicates).
  if (guard.restartBarShowing) return;
  guard.restartBarShowing = true;

  final scheme = Theme.of(messenger.context).colorScheme;
  final controller = messenger.showSnackBar(
    SnackBar(
      behavior: SnackBarBehavior.floating,
      backgroundColor: scheme.primaryContainer,
      duration: restartBarDuration,
      content: Row(
        children: [
          Icon(Icons.download_done_rounded, color: scheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Update downloaded',
              style: TextStyle(color: scheme.onPrimaryContainer),
            ),
          ),
        ],
      ),
      action: SnackBarAction(
        label: 'Restart',
        textColor: scheme.primary,
        onPressed: service.restart,
      ),
    ),
  );
  controller.closed.then((_) => guard.restartBarShowing = false);
}

void _toast(ScaffoldMessengerState messenger, String message) {
  if (!messenger.mounted) return;
  messenger.showSnackBar(SnackBar(content: Text(message)));
}

class _UpdateOfferSheet extends StatelessWidget {
  const _UpdateOfferSheet();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SheetBody(
      children: [
        const SheetIcon(Icons.system_update_alt_rounded),
        const SizedBox(height: 16),
        Text(
          'A new version is ready',
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Get the latest fixes and improvements from Google Play.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.outline,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 20),
        const SheetNoteRow(
          icon: Icons.download_outlined,
          text: 'Downloads in the background. Keep using Pawlet meanwhile.',
        ),
        const SizedBox(height: 10),
        const SheetNoteRow(
          icon: Icons.restart_alt_rounded,
          text:
              "When it's ready, tap Restart to finish. It takes a few "
              'seconds.',
        ),
        const SizedBox(height: 10),
        const SheetNoteRow(
          icon: Icons.lock_outline,
          text:
              'Your records stay on your phone. Updating does not touch '
              'them.',
        ),
        const SizedBox(height: 10),
        const SheetNoteRow(
          icon: Icons.settings_outlined,
          text: 'Check again any time under Settings → Check for updates.',
        ),
        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Update'),
          ),
        ),
        const SizedBox(height: 4),
        SizedBox(
          width: double.infinity,
          child: TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Not now'),
          ),
        ),
      ],
    );
  }
}
