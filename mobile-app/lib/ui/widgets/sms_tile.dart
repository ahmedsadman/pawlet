import 'package:flutter/material.dart';

import '../../models/sms_record.dart';
import '../../services/processing_service.dart';
import 'category_label.dart';
import 'status_badge.dart';

int _defaultNow() => DateTime.now().millisecondsSinceEpoch;

/// A single SMS row used in both the Queue and History lists.
///
/// Queue (showCategory == false): full inline layout with the processing
/// status badge and retry progress — unchanged.
///
/// History (showCategory == true): a compact card. Line 1 shows the sender, an
/// optional muted `LLM` marker, the category/status trailing, a retry icon for
/// failed rows, and a caret. Line 2 shows the timestamp. Tapping anywhere
/// toggles a collapsible body (the failure hint, if any, plus the message text).
class SmsTile extends StatefulWidget {
  const SmsTile(
    this.record, {
    this.showCategory = false,
    this.now = _defaultNow,
    this.onRetry,
    super.key,
  });

  final SmsRecord record;

  /// When true, render the History (compact, expandable) layout.
  final bool showCategory;

  /// Injectable clock (epoch ms) for deciding whether a scheduled next-attempt
  /// time is still upcoming. Defaults to the wall clock; overridden in tests.
  final int Function() now;

  /// Tapped by the per-row retry icon on a Failed history row. Null hides it.
  final VoidCallback? onRetry;

  @override
  State<SmsTile> createState() => _SmsTileState();
}

class _SmsTileState extends State<SmsTile> {
  bool _expanded = false;

  SmsRecord get record => widget.record;
  bool get showCategory => widget.showCategory;
  VoidCallback? get onRetry => widget.onRetry;

  String get _title => record.sender;

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
  String get _retryLine {
    final base = 'Retry ${record.attempts}/${ProcessingService.maxAttempts}';
    final next = record.nextAttemptAt;
    if (next != null && next > widget.now()) {
      return '$base · Next attempt at ${_formatClock(next)}';
    }
    return base;
  }

  Widget _trailing() {
    final category = record.category;
    if (showCategory && category != null && category != 'ignored') {
      if (record.parseSource == ParseSource.llm) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const _LlmBadge(),
            const SizedBox(width: 6),
            CategoryLabel(category, type: record.transactionType),
          ],
        );
      }
      return CategoryLabel(category, type: record.transactionType);
    }
    return StatusBadge(record.status);
  }

  /// Short, user-facing reason a History row failed. The internal `last_error`
  /// is never surfaced here (ADB/debug only).
  String get _failureHint => switch (record.failureReason) {
    FailureReason.retryExhausted => 'Retries exhausted',
    FailureReason.llmError => 'Extraction error',
    FailureReason.localOnly => 'Could not read the amount',
    null => 'Extraction error',
  };

  @override
  Widget build(BuildContext context) {
    return showCategory ? _buildHistory(context) : _buildQueue(context);
  }

  // ---- History: compact + expandable -------------------------------------

  Widget _buildHistory(BuildContext context) {
    final theme = Theme.of(context);
    final isFailure = record.status == SmsStatus.failure;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: InkWell(
        onTap: () => setState(() => _expanded = !_expanded),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Line 1: sender · (LLM) · category/status · retry · caret.
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
                  if (isFailure && onRetry != null)
                    IconButton(
                      icon: const Icon(Icons.refresh, size: 18),
                      tooltip: 'Retry',
                      visualDensity: VisualDensity.compact,
                      onPressed: onRetry,
                    ),
                  const SizedBox(width: 4),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 20,
                    color: theme.colorScheme.outline,
                  ),
                ],
              ),
              const SizedBox(height: 4),
              // Line 2: timestamp.
              Text(
                _formatTime(record.timestamp),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
              // Collapsible body: failure hint (if any) + message text. Built
              // only while expanded so it is truly absent (not just hidden)
              // from the tree when collapsed; AnimatedSize animates the height.
              AnimatedSize(
                duration: const Duration(milliseconds: 180),
                alignment: Alignment.topCenter,
                child: _expanded
                    ? Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (isFailure) ...[
                              Text(
                                _failureHint,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.error,
                                ),
                              ),
                              const SizedBox(height: 6),
                            ],
                            Text(
                              record.content,
                              style: theme.textTheme.bodyMedium,
                            ),
                          ],
                        ),
                      )
                    : const SizedBox(width: double.infinity),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---- Queue: unchanged full inline layout -------------------------------

  Widget _buildQueue(BuildContext context) {
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
            if (record.attempts >= 1) ...[
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
          ],
        ),
      ),
    );
  }
}

/// Muted, low-emphasis marker shown on History rows that fell back to the LLM
/// (the on-device model was not confident enough). Intentionally subtle.
class _LlmBadge extends StatelessWidget {
  const _LlmBadge();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      'LLM',
      style: theme.textTheme.labelSmall?.copyWith(
        color: theme.colorScheme.outline,
        fontSize: 10,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.5,
      ),
    );
  }
}
