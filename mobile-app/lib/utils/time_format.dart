// Compact date/time formatting helpers for the finance UI.

const List<String> _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

String monthShort(DateTime date) => _months[date.month - 1];

/// e.g. `Jan 25`.
String monthYearLabel(DateTime date) {
  final yy = (date.year % 100).toString().padLeft(2, '0');
  return '${_months[date.month - 1]} $yy';
}

/// e.g. `Jan 15, 2025`.
String fullDateLabel(DateTime date) =>
    '${_months[date.month - 1]} ${date.day}, ${date.year}';

/// Coarse relative time: `just now`, `5m ago`, `3d ago`, `2mo ago`, `1y ago`.
/// [now] is injectable for tests.
String relativeTime(DateTime time, {DateTime? now}) {
  final delta = (now ?? DateTime.now()).difference(time);
  if (delta.isNegative) return 'just now';
  if (delta.inSeconds < 60) return 'just now';
  if (delta.inMinutes < 60) return '${delta.inMinutes}m ago';
  if (delta.inHours < 24) return '${delta.inHours}h ago';
  if (delta.inDays < 30) return '${delta.inDays}d ago';
  if (delta.inDays < 365) return '${(delta.inDays / 30).floor()}mo ago';
  return '${(delta.inDays / 365).floor()}y ago';
}
