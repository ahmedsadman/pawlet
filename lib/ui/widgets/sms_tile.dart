import 'package:flutter/material.dart';

import '../../models/sms_record.dart';
import 'category_label.dart';
import 'status_badge.dart';

/// A single SMS row used in both the Queue and History lists. In the Queue it
/// shows the processing status; in History it shows the read-only classification
/// label (Transaction / Bill).
class SmsTile extends StatelessWidget {
  const SmsTile(this.record, {this.showCategory = false, super.key});

  final SmsRecord record;

  /// When true, render the category label instead of the status badge.
  final bool showCategory;

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

  Widget _trailing() {
    final category = record.category;
    if (showCategory && category != null && category != 'ignored') {
      return CategoryLabel(category);
    }
    return StatusBadge(record.status);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final error = record.lastError;
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
            if (!showCategory && error != null && error.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                error,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
