// Date/time label helpers for the UI.
//
// Every label is in the phone's local time zone. "Today" and "Yesterday" are
// calendar days (since local midnight), not rolling 24-hour windows. A
// timestamp later than `now` (clock drift) is treated as `now`. Each helper
// takes an injectable `now` for tests.

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

/// e.g. `Oct 2026` (bill statement period).
String monthYearLabel(DateTime date) =>
    '${_months[date.month - 1]} ${date.year}';

/// e.g. `Oct '26` (compact chart axis label).
String monthYearShort(DateTime date) {
  final yy = (date.year % 100).toString().padLeft(2, '0');
  return "${_months[date.month - 1]} '$yy";
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

/// Resolves [time] and [now] to local wall-clock values, pulling a [time]
/// later than [now] back to [now].
(DateTime, DateTime) _resolve(DateTime time, DateTime? now) {
  final n = (now ?? DateTime.now()).toLocal();
  final t = time.toLocal();
  return (t.isAfter(n) ? n : t, n);
}

/// Whole calendar days from [time]'s date to [now]'s date (0 = same day).
/// Compared as UTC dates so a daylight-saving shift cannot skew the count.
int _calendarDaysBefore(DateTime time, DateTime now) => DateTime.utc(
  now.year,
  now.month,
  now.day,
).difference(DateTime.utc(time.year, time.month, time.day)).inDays;

/// 12-hour clock: `9:05 AM`, `12:00 AM` (midnight), `12:00 PM` (noon).
String _clock(DateTime t) {
  final hour12 = t.hour % 12 == 0 ? 12 : t.hour % 12;
  final period = t.hour < 12 ? 'AM' : 'PM';
  return '$hour12:${t.minute.toString().padLeft(2, '0')} $period';
}

/// Day part shared by [dateLabel] and [dateTimeLabel]. Both arguments must
/// already be resolved by [_resolve].
String _day(DateTime t, DateTime now) => switch (_calendarDaysBefore(t, now)) {
  0 => 'Today',
  1 => 'Yesterday',
  _ when t.year == now.year => '${t.day} ${_months[t.month - 1]}',
  _ => '${t.day} ${_months[t.month - 1]} ${t.year}',
};

/// `Today`, `Yesterday`, `6 Oct`, or `14 Dec 2025` (year only when it is not
/// the current one).
String dateLabel(DateTime time, {DateTime? now}) {
  final (t, n) = _resolve(time, now);
  return _day(t, n);
}

/// [dateLabel] plus the time: `Today · 3:42 PM`, `Yesterday · 9:05 AM`,
/// `6 Oct · 3:42 PM`, `14 Dec 2025 · 3:42 PM`.
String dateTimeLabel(DateTime time, {DateTime? now}) {
  final (t, n) = _resolve(time, now);
  return '${_day(t, n)} · ${_clock(t)}';
}

/// "Updated …" label: relative while still today (`just now` under a minute,
/// then `5m ago`, then `2h ago`, at most `23h ago`); from yesterday back it is
/// identical to [dateTimeLabel].
String updatedLabel(DateTime time, {DateTime? now}) {
  final (t, n) = _resolve(time, now);
  if (_calendarDaysBefore(t, n) > 0) return dateTimeLabel(t, now: n);
  final elapsed = n.difference(t);
  if (elapsed.inMinutes < 1) return 'just now';
  if (elapsed.inHours < 1) return '${elapsed.inMinutes}m ago';
  // A same-day gap is under 24 h except on a 25-hour daylight-saving day.
  return '${elapsed.inHours.clamp(1, 23)}h ago';
}
