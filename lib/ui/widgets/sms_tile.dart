import 'package:flutter/material.dart';

import '../../models/sms_record.dart';
import '../../services/processing_service.dart';
import 'category_label.dart';
import 'status_badge.dart';

int _defaultNow() => DateTime.now().millisecondsSinceEpoch;

/// A single SMS row used in both the Queue and History lists. In the Queue it
/// shows the processing status; in History it shows the read-only classification
/// label (Transaction / Bill).
class SmsTile extends StatelessWidget {
  const SmsTile(
    this.record, {
    this.showCategory = false,
    this.now = _defaultNow,
    this.onRetry,
    super.key,
  });

  final SmsRecord record;

  /// When true, render the category label instead of the status badge.
  final bool showCategory;

  /// Injectable clock (epoch ms) for deciding whether a scheduled next-attempt
  /// time is still upcoming. Defaults to the wall clock; overridden in tests.
  final int Function() now;

  /// Tapped by the per-row retry icon on a Failed history row. Null hides it.
  final VoidCallback? onRetry;

  String get _title {
    final name = record.contactName;
    return (name != null && name.isNotEmpty)
        ? '$name (${record.sender})'
        : record.sender;
  }

  String _formatTime(int millis) {
    final dt = DateTime.fromMillisecondsSinceEpoch(millis);
    String two(int n) => n.toString().padLeft(2, '0');
    final hour12 = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final period = dt.hour < 12 ? 'AM' : 'PM';
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} $hour12:${two(dt.minute)} $period';
  }

  /// Time-only clock in the same 12-hour AM/PM style as [_formatTime].
  String _formatClock(int millis) {
    final dt = DateTime.fromMillisecondsSinceEpoch(millis);
    final hour12 = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final period = dt.hour < 12 ? 'AM' : 'PM';
    return '$hour12:${dt.minute.toString().padLeft(2, '0')} $period';
  }

  /// Retry-progress line for a queued row that has already failed at least once.
  /// Appends the scheduled next-attempt time only while it is still upcoming
  /// (compared to [now]); an overdue/just-due row shows only the counter.
  String get _retryLine {
    final base = 'Retry ${record.attempts}/${ProcessingService.maxAttempts}';
    final next = record.nextAttemptAt;
    if (next != null && next > now()) {
      return '$base · Next attempt at ${_formatClock(next)}';
    }
    return base;
  }

  Widget _trailing() {
    final category = record.category;
    if (showCategory && category != null && category != 'ignored') {
      return CategoryLabel(category);
    }
    return StatusBadge(record.status);
  }

  /// Short, user-facing reason a History row failed. The internal `last_error`
  /// is never surfaced here (ADB/debug only). Null legacy rows read as the
  /// generic extraction hint.
  String get _failureHint => switch (record.failureReason) {
    FailureReason.retryExhausted => 'Retries exhausted',
    FailureReason.llmError => 'Extraction error',
    null => 'Extraction error',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    _title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                _trailing(),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              record.content,
              style: theme.textTheme.bodyMedium,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 6),
            Text(
              _formatTime(record.timestamp),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
            // Queue: show retry progress once a row has failed at least once
            // (a fresh, never-tried row shows only its status badge). The raw
            // internal error is deliberately not surfaced here — it stays in
            // the DB for debug only.
            if (!showCategory && record.attempts >= 1) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  Icon(
                    Icons.schedule,
                    size: 14,
                    color: theme.colorScheme.outline,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      _retryLine,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            // History failure rows: short hint (never the raw error) + an
            // optional per-message retry affordance.
            if (showCategory && record.status == SmsStatus.failure) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _failureHint,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ),
                  if (onRetry != null)
                    IconButton(
                      icon: const Icon(Icons.refresh, size: 18),
                      tooltip: 'Retry',
                      visualDensity: VisualDensity.compact,
                      onPressed: onRetry,
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
