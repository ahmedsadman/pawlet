import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/battery_prompt_policy.dart';
import '../state/providers.dart';
import 'widgets/sheet_parts.dart';

/// Per-app guard so a second resume (one fires when the system dialog closes)
/// can't stack another sheet.
final _guardProvider = Provider<_Guard>((_) => _Guard());

class _Guard {
  bool busy = false;
}

/// Looks for missed bank SMS and, when the OS is shown to be holding Pawlet
/// back, offers to lift battery optimization. Resolves true when the sheet
/// went up.
///
/// [canPrompt] says whether a sheet may go up now: unlocked, nothing else on
/// top, no inbox import running. It is read before the scan and again right
/// before showing, since the scan awaits the inbox. The snooze is written
/// before the sheet shows, so a swipe-away counts as "Not now".
Future<bool> runBatteryPromptCheck(
  BuildContext context,
  WidgetRef ref, {
  required bool Function() canPrompt,
  int Function()? clock,
}) async {
  final guard = ref.read(_guardProvider);
  if (guard.busy || !canPrompt()) return false;

  // Read providers before the first await.
  final store = ref.read(deliveryHealthStoreProvider);
  final power = ref.read(powerStatusProvider);
  final detector = ref.read(missedSmsDetectorProvider);
  final messenger = ScaffoldMessenger.of(context);
  final now = clock ?? () => DateTime.now().millisecondsSinceEpoch;

  guard.busy = true;
  try {
    await detector.scanIfDue();
    final verdict = BatteryPromptPolicy.decide(
      exempt: await power.isBatteryExempt(),
      restricted: await power.isBackgroundRestricted(),
      missedAt: store.missedAt,
      snoozedUntil: store.promptSnoozedUntil,
      now: now(),
    );
    if (verdict == BatteryPromptVerdict.none) return false;
    if (!context.mounted || !canPrompt()) return false;

    await store.setPromptSnoozedUntil(
      now() + BatteryPromptPolicy.snooze.inMilliseconds,
    );
    if (!context.mounted) return false;
    final accepted = await confirmBatteryPrompt(context, verdict);
    if (!accepted) return true;

    if (verdict == BatteryPromptVerdict.openSettings) {
      await power.openSettings();
    } else if (await power.requestExemption() && messenger.mounted) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Battery optimization disabled for Pawlet'),
        ),
      );
    }
    return true;
  } finally {
    guard.busy = false;
  }
}

/// The battery offer. Resolves true when the user taps the primary button;
/// dismissing the sheet counts as "Not now".
Future<bool> confirmBatteryPrompt(
  BuildContext context,
  BatteryPromptVerdict verdict,
) async {
  final accepted = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _BatteryPromptSheet(verdict),
  );
  return accepted ?? false;
}

class _BatteryPromptSheet extends StatelessWidget {
  const _BatteryPromptSheet(this.verdict);

  final BatteryPromptVerdict verdict;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final restricted = verdict == BatteryPromptVerdict.openSettings;
    return SheetBody(
      children: [
        const SheetIcon(Icons.battery_alert_rounded),
        const SizedBox(height: 16),
        Text(
          'Pawlet is missing messages',
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          restricted
              ? "Pawlet's battery usage is set to Restricted, so it can't run "
                    'in the background. Set it to Unrestricted in app settings.'
              : "Your phone's battery saver stopped Pawlet from catching some "
                    'bank SMS in the background. Turn off battery optimization '
                    'so new messages are recorded as they arrive.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.outline,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(restricted ? 'Open settings' : 'Turn off optimization'),
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
