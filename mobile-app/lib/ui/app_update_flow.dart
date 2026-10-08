import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/app_update_service.dart';
import '../state/providers.dart';
import 'widgets/sheet_parts.dart';

/// Per-app guard so a resume or a second tap can't stack another sheet.
final _flowGuardProvider = Provider<_FlowGuard>((_) => _FlowGuard());

class _FlowGuard {
  bool busy = false;
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
  final guard = ref.read(_flowGuardProvider);
  if (guard.busy) return;
  guard.busy = true;
  try {
    final service = ref.read(appUpdateServiceProvider);
    // Captured up front: the download below can outlive this context.
    final messenger = ScaffoldMessenger.of(context);
    final status = await service.check();
    if (!context.mounted) return;
    switch (status) {
      case UpdateStatus.downloaded:
        _showRestartSnackBar(messenger, service);
      case UpdateStatus.inProgress:
        if (manual) _toast(messenger, 'The update is downloading');
      case UpdateStatus.upToDate:
        if (manual) _toast(messenger, "You're on the latest version");
      case UpdateStatus.unsupported:
        if (manual) _toast(messenger, "Couldn't reach Google Play");
      case UpdateStatus.available:
        if (!manual && service.isSnoozed) return;
        if (canPrompt != null && !canPrompt()) return;
        final accepted = await confirmAppUpdate(context);
        // Release the guard before starting the download. Play may never
        // resolve the future (download cancelled from Play's notification, app
        // killed), and while it runs, check() reports inProgress so nothing
        // re-offers it anyway.
        guard.busy = false;
        if (!accepted) {
          await service.snooze();
          return;
        }
        switch (await service.start()) {
          case UpdateStartResult.downloaded:
            _showRestartSnackBar(messenger, service);
          case UpdateStartResult.declined:
            await service.snooze();
          case UpdateStartResult.failed:
            _toast(
              messenger,
              "The update couldn't download. Try again from Settings.",
            );
        }
        return; // Guard already released above.
    }
  } finally {
    guard.busy = false;
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

/// Stays up until acted on: a downloaded update does nothing until the app
/// restarts into it.
void _showRestartSnackBar(
  ScaffoldMessengerState messenger,
  AppUpdateService service,
) {
  final scheme = Theme.of(messenger.context).colorScheme;
  messenger
    // A resume re-checks and lands here again; replace, don't queue.
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.primaryContainer,
        duration: const Duration(days: 1),
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
}

void _toast(ScaffoldMessengerState messenger, String message) =>
    messenger.showSnackBar(SnackBar(content: Text(message)));

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
