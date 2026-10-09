import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/utils/time_format.dart';

void main() {
  // All DateTimes below are local (DateTime(...) constructor), matching how the
  // helpers interpret time: the phone's own time zone.
  final now = DateTime(2026, 10, 10, 15, 0);

  group('dateLabel', () {
    test('Today for any time since local midnight', () {
      expect(dateLabel(DateTime(2026, 10, 10), now: now), 'Today');
      expect(dateLabel(DateTime(2026, 10, 10, 14, 59), now: now), 'Today');
    });

    test('Yesterday is the previous calendar day, not the last 24 h', () {
      expect(
        dateLabel(DateTime(2026, 10, 9, 23, 59, 59), now: now),
        'Yesterday',
      );
      expect(dateLabel(DateTime(2026, 10, 9), now: now), 'Yesterday');
    });

    test('midnight edge: one minute apart, different days', () {
      final justAfterMidnight = DateTime(2026, 10, 10, 0, 0, 30);
      expect(
        dateLabel(DateTime(2026, 10, 9, 23, 59), now: justAfterMidnight),
        'Yesterday',
      );
      expect(
        dateLabel(DateTime(2026, 10, 10), now: justAfterMidnight),
        'Today',
      );
    });

    test('two or more days back shows day and short month', () {
      expect(dateLabel(DateTime(2026, 10, 8, 23, 59), now: now), '8 Oct');
      expect(dateLabel(DateTime(2026, 1, 6), now: now), '6 Jan');
    });

    test('Yesterday across a month boundary', () {
      final nov1 = DateTime(2026, 11, 1, 9, 0);
      expect(dateLabel(DateTime(2026, 10, 31, 22, 0), now: nov1), 'Yesterday');
      expect(dateLabel(DateTime(2026, 10, 30, 22, 0), now: nov1), '30 Oct');
    });

    test('Yesterday across a year boundary; older shows the year', () {
      final jan1 = DateTime(2026, 1, 1, 0, 5);
      expect(dateLabel(DateTime(2025, 12, 31, 23, 50), now: jan1), 'Yesterday');
      expect(dateLabel(DateTime(2025, 12, 30, 12), now: jan1), '30 Dec 2025');
    });

    test('a past year always shows the year', () {
      expect(dateLabel(DateTime(2025, 10, 10), now: now), '10 Oct 2025');
      expect(dateLabel(DateTime(2025, 12, 14), now: now), '14 Dec 2025');
    });

    test('a future timestamp (clock drift) is Today', () {
      expect(dateLabel(now.add(const Duration(minutes: 5)), now: now), 'Today');
      expect(dateLabel(DateTime(2026, 10, 11, 9), now: now), 'Today');
    });
  });

  group('clockLabel', () {
    test('12-hour format with AM/PM', () {
      expect(clockLabel(DateTime(2026, 10, 10, 9, 5)), '9:05 AM');
      expect(clockLabel(DateTime(2026, 10, 10, 15, 42)), '3:42 PM');
      expect(clockLabel(DateTime(2026, 10, 10, 0, 0)), '12:00 AM');
      expect(clockLabel(DateTime(2026, 10, 10, 12, 0)), '12:00 PM');
      expect(clockLabel(DateTime(2026, 10, 10, 0, 30)), '12:30 AM');
      expect(clockLabel(DateTime(2026, 10, 10, 23, 59)), '11:59 PM');
    });
  });

  group('dateTimeLabel', () {
    final evening = DateTime(2026, 10, 10, 18, 0);

    test('day part plus 12-hour clock, middle-dot separated', () {
      expect(
        dateTimeLabel(DateTime(2026, 10, 10, 15, 42), now: evening),
        'Today · 3:42 PM',
      );
      expect(
        dateTimeLabel(DateTime(2026, 10, 9, 9, 5), now: evening),
        'Yesterday · 9:05 AM',
      );
      expect(
        dateTimeLabel(DateTime(2026, 10, 6, 15, 42), now: evening),
        '6 Oct · 3:42 PM',
      );
      expect(
        dateTimeLabel(DateTime(2025, 12, 14, 15, 42), now: evening),
        '14 Dec 2025 · 3:42 PM',
      );
    });

    test('midnight is 12:00 AM and noon is 12:00 PM', () {
      expect(
        dateTimeLabel(DateTime(2026, 10, 10, 0, 0), now: evening),
        'Today · 12:00 AM',
      );
      expect(
        dateTimeLabel(DateTime(2026, 10, 10, 12, 0), now: evening),
        'Today · 12:00 PM',
      );
      expect(
        dateTimeLabel(DateTime(2026, 10, 10, 0, 30), now: evening),
        'Today · 12:30 AM',
      );
      expect(
        dateTimeLabel(DateTime(2026, 10, 9, 23, 59), now: evening),
        'Yesterday · 11:59 PM',
      );
    });

    test('minutes are zero-padded, hours are not', () {
      expect(
        dateTimeLabel(DateTime(2026, 10, 10, 9, 5), now: evening),
        'Today · 9:05 AM',
      );
    });

    test('a future timestamp is shown as now', () {
      final lateNight = DateTime(2026, 10, 10, 23, 58);
      expect(
        dateTimeLabel(DateTime(2026, 10, 11, 0, 5), now: lateNight),
        'Today · 11:58 PM',
      );
    });

    test('a UTC instant is shown in local time', () {
      final instant = DateTime.utc(2026, 10, 10, 9, 0);
      final local = instant.toLocal();
      expect(
        dateTimeLabel(instant, now: local.add(const Duration(minutes: 1))),
        dateTimeLabel(local, now: local.add(const Duration(minutes: 1))),
      );
    });
  });

  group('updatedLabel', () {
    test('under a minute ago is just now', () {
      expect(updatedLabel(now, now: now), 'just now');
      expect(
        updatedLabel(now.subtract(const Duration(seconds: 59)), now: now),
        'just now',
      );
    });

    test('minutes ago from one minute up to the hour', () {
      expect(
        updatedLabel(now.subtract(const Duration(minutes: 1)), now: now),
        '1m ago',
      );
      expect(
        updatedLabel(now.subtract(const Duration(minutes: 5)), now: now),
        '5m ago',
      );
      expect(
        updatedLabel(
          now.subtract(const Duration(minutes: 59, seconds: 59)),
          now: now,
        ),
        '59m ago',
      );
    });

    test('hours ago for the rest of today', () {
      expect(
        updatedLabel(now.subtract(const Duration(hours: 1)), now: now),
        '1h ago',
      );
      expect(
        updatedLabel(now.subtract(const Duration(hours: 2)), now: now),
        '2h ago',
      );
    });

    test('at most 23h ago (still today)', () {
      final lastMinute = DateTime(2026, 10, 10, 23, 59);
      expect(updatedLabel(DateTime(2026, 10, 10), now: lastMinute), '23h ago');
    });

    test('before local midnight switches to the calendar label', () {
      // Only 40 minutes elapsed, but it was yesterday.
      final justAfterMidnight = DateTime(2026, 10, 10, 0, 30);
      expect(
        updatedLabel(DateTime(2026, 10, 9, 23, 50), now: justAfterMidnight),
        'Yesterday · 11:50 PM',
      );
    });

    test('older days match dateTimeLabel', () {
      expect(
        updatedLabel(DateTime(2026, 10, 9, 9, 5), now: now),
        'Yesterday · 9:05 AM',
      );
      expect(
        updatedLabel(DateTime(2026, 10, 6, 15, 42), now: now),
        '6 Oct · 3:42 PM',
      );
      expect(
        updatedLabel(DateTime(2025, 12, 14, 15, 42), now: now),
        '14 Dec 2025 · 3:42 PM',
      );
    });

    test('a future timestamp is just now', () {
      expect(
        updatedLabel(now.add(const Duration(minutes: 3)), now: now),
        'just now',
      );
    });
  });

  group('month labels', () {
    test('monthYearLabel uses the full year', () {
      expect(monthYearLabel(DateTime(2026, 10, 1)), 'Oct 2026');
      expect(monthYearLabel(DateTime(2025, 1, 15)), 'Jan 2025');
    });

    test('monthYearShort uses an apostrophe two-digit year', () {
      expect(monthYearShort(DateTime(2026, 10, 1)), "Oct '26");
      expect(monthYearShort(DateTime(2005, 3, 1)), "Mar '05");
    });
  });
}
