import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/bulk_import/bulk_import_service.dart';
import '../state/bulk_import_providers.dart';
import '../state/finance_providers.dart';
import '../state/messages_providers.dart';
import '../state/providers.dart';
import 'banks_page.dart';
import 'widgets/sheet_parts.dart';

/// Offers the inbox import. Resolves true when the user accepts.
Future<bool> confirmBulkImport(BuildContext context) async {
  final accepted = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => const _ImportOfferSheet(),
  );
  return accepted ?? false;
}

/// Runs the import behind a blocking progress dialog, then shows the summary.
///
/// The queue is paused for the duration and the dialog is barrier-locked with
/// back disabled, so this really is the only thing happening in the app.
Future<void> runBulkImport(BuildContext context, WidgetRef ref) async {
  final progress = ValueNotifier<_Progress>(const _Progress(0, 0));
  var cancelled = false;

  // Captured before the dialog goes up, so the pop below doesn't depend on the
  // caller's context still being mounted.
  final navigator = Navigator.of(context, rootNavigator: true);
  final processing = ref.read(processingServiceProvider)..pause();
  // showDialog pushes synchronously, so the route is on the stack before the
  // first await below — the pop in `finally` can never hit the wrong route.
  //
  // whenComplete fires at the pop, NOT after the exit animation, so the
  // ValueListenableBuilder is still mounted when dispose runs. That is safe on
  // two counts: ChangeNotifier.removeListener is explicitly documented to
  // tolerate a disposed instance, and nothing writes progress.value once run()
  // has returned.
  unawaited(
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ImportProgressDialog(
        progress: progress,
        onCancel: () => cancelled = true,
      ),
    ).whenComplete(progress.dispose),
  );

  // Null when the pass threw. Per-message errors are already absorbed inside
  // run(), so reaching here means something pass-level failed (reading the
  // inbox, the bank list, the closing matcher sweep).
  BulkImportResult? result;
  try {
    result = await ref
        .read(bulkImportServiceProvider)
        .run(
          onProgress: (done, total) => progress.value = _Progress(done, total),
          isCancelled: () => cancelled,
        );
  } catch (_) {
    // Swallowed deliberately: the message could quote SMS content, which must
    // not reach a screenshot. The user gets a generic sheet below.
  } finally {
    processing.resume();
    // A resume/incoming-SMS trigger that fired while we held the pause was
    // dropped by process()'s early return, so nothing would re-arm the queue
    // until the next one. Kick it once; process() swallows its own errors.
    unawaited(processing.process());
    navigator.pop();
  }

  // The import wrote straight to the database from outside the pipeline, so the
  // read-once finance/messages providers have to be told — including on the
  // failure path, where a partial pass still left rows behind.
  refreshAllFinance(ref);
  ref.invalidate(queuedProvider);
  ref.invalidate(historyProvider);
  ref.read(dataRevisionProvider.notifier).bump();

  if (!context.mounted) return;
  if (result == null) {
    await showBulkImportError(context);
    return;
  }
  await showBulkImportSummary(context, result);
}

/// Shown when the pass itself failed. Public so it can be tested on its own.
Future<void> showBulkImportError(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => const _ImportErrorSheet(),
  );
}

/// Shows the post-import summary sheet. Public so it can be tested on its own.
Future<void> showBulkImportSummary(
  BuildContext context,
  BulkImportResult result,
) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _ImportSummarySheet(result: result),
  );
}

class _Progress {
  const _Progress(this.done, this.total);

  final int done;
  final int total;
}

class _ImportOfferSheet extends StatelessWidget {
  const _ImportOfferSheet();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SheetBody(
      children: [
        const SheetIcon(Icons.inbox_outlined),
        const SizedBox(height: 16),
        Text(
          'Import existing messages',
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Do you want Pawlet to read your existing messages and create '
          'financial records now?',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.outline,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 20),
        const SheetNoteRow(
          icon: Icons.phone_android,
          text:
              'This pass uses only the on-device model. Messages with low '
              'confidence score will be skipped.',
        ),
        const SizedBox(height: 10),
        const SheetNoteRow(
          icon: Icons.credit_card_outlined,
          text:
              'Pawlet does its best to create bank accounts as it goes, '
              'but never credit cards. Transactions are recorded either '
              'way — only balances and card bills need the account to '
              'exist. Add yours under "Manage Banks & Cards" and run this '
              'again any time.',
        ),
        const SizedBox(height: 10),
        const SheetNoteRow(
          icon: Icons.hourglass_empty,
          text:
              'Keep Pawlet open while it runs; the rest of the app pauses '
              'until it finishes.',
        ),
        const SizedBox(height: 10),
        const SheetNoteRow(
          icon: Icons.settings_outlined,
          text:
              'Find this again under Settings → Data → Import existing '
              'messages.',
        ),
        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Import now'),
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

class _ImportProgressDialog extends StatefulWidget {
  const _ImportProgressDialog({required this.progress, required this.onCancel});

  final ValueListenable<_Progress> progress;
  final VoidCallback onCancel;

  @override
  State<_ImportProgressDialog> createState() => _ImportProgressDialogState();
}

class _ImportProgressDialogState extends State<_ImportProgressDialog> {
  bool _stopping = false;

  void _stop() {
    setState(() => _stopping = true);
    widget.onCancel();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      canPop: false,
      child: Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 32),
        backgroundColor: theme.colorScheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
          child: ValueListenableBuilder<_Progress>(
            valueListenable: widget.progress,
            builder: (context, value, _) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Reading your messages',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  value.total == 0
                      ? 'Opening the inbox…'
                      : '${value.done} of ${value.total} messages',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
                const SizedBox(height: 16),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                    // Indeterminate until the inbox size is known.
                    value: value.total == 0 ? null : value.done / value.total,
                    minHeight: 8,
                    backgroundColor: theme.colorScheme.surfaceContainerHighest,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Keep Pawlet open. Everything else is paused until this '
                  'finishes.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                    height: 1.4,
                  ),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: _stopping ? null : _stop,
                    child: Text(_stopping ? 'Stopping…' : 'Stop'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ImportSummarySheet extends StatelessWidget {
  const _ImportSummarySheet({required this.result});

  final BulkImportResult result;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SheetBody(
      children: [
        SheetIcon(
          result.cancelled ? Icons.pause_circle_outline : Icons.task_alt,
        ),
        const SizedBox(height: 16),
        Text(
          result.cancelled ? 'Import stopped' : 'Import complete',
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: _StatTile(
                label: 'Messages processed',
                value: '${result.scanned}',
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _StatTile(
                label: 'Records saved',
                value: '${result.saved}',
                highlight: true,
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        const SheetNoteRow(
          icon: Icons.memory,
          text:
              'Only the on-device model was used, no LLM. Some messages '
              'might get dropped due to lower confidence.',
        ),
        const SizedBox(height: 10),
        const SheetNoteRow(
          icon: Icons.credit_card_off_outlined,
          text:
              'Credit card linking with non-existent credit accounts was '
              'skipped. Please add all your credit cards under "Manage '
              'Banks & Cards" for the best experience.',
        ),
        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Done'),
          ),
        ),
        const SizedBox(height: 4),
        SizedBox(
          width: double.infinity,
          child: TextButton(
            onPressed: () {
              // Captured before the pop, since this context dies with it.
              final navigator = Navigator.of(context);
              navigator.pop();
              navigator.push(
                MaterialPageRoute<void>(builder: (_) => const BanksPage()),
              );
            },
            child: const Text('Manage Banks & Cards'),
          ),
        ),
      ],
    );
  }
}

class _ImportErrorSheet extends StatelessWidget {
  const _ImportErrorSheet();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SheetBody(
      children: [
        const SheetIcon(Icons.error_outline),
        const SizedBox(height: 16),
        Text(
          "Import couldn't finish",
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Something went wrong partway through. Everything imported '
          'before that point has been kept, and running the import again '
          'will carry on from where it stopped.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.outline,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Done'),
          ),
        ),
      ],
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.label,
    required this.value,
    this.highlight = false,
  });

  final String label;
  final String value;

  /// Tints the number with the accent — used for the figure that matters.
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w600,
              color: highlight ? theme.colorScheme.primary : null,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ],
      ),
    );
  }
}
