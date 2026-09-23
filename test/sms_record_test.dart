import 'package:flutter_test/flutter_test.dart';
import 'package:meowni/models/sms_record.dart';

void main() {
  group('IgnoreReason.fromValue', () {
    test('round-trips every value', () {
      for (final r in IgnoreReason.values) {
        expect(IgnoreReason.fromValue(r.value), r);
      }
    });

    test('returns null for null or unknown', () {
      expect(IgnoreReason.fromValue(null), isNull);
      expect(IgnoreReason.fromValue('nope'), isNull);
    });

    test('uses the expected snake_case backing values', () {
      expect(IgnoreReason.gated.value, 'gated');
      expect(IgnoreReason.llmNone.value, 'llm_none');
      expect(IgnoreReason.noRecord.value, 'no_record');
    });
  });

  group('FailureReason.fromValue', () {
    test('round-trips every value', () {
      for (final r in FailureReason.values) {
        expect(FailureReason.fromValue(r.value), r);
      }
    });

    test('returns null for null or unknown', () {
      expect(FailureReason.fromValue(null), isNull);
      expect(FailureReason.fromValue('nope'), isNull);
    });

    test('uses the expected snake_case backing values', () {
      expect(FailureReason.retryExhausted.value, 'retry_exhausted');
      expect(FailureReason.llmError.value, 'llm_error');
    });
  });

  test('SmsStatus.ignored round-trips by name', () {
    expect(SmsStatus.fromName('ignored'), SmsStatus.ignored);
    expect(SmsStatus.ignored.name, 'ignored');
  });

  group('SmsRecord db mapping', () {
    test('toDbMap serializes reason enums to their backing values', () {
      const record = SmsRecord(
        sender: 'CHK',
        content: 'x',
        timestamp: 1,
        status: SmsStatus.ignored,
        ignoreReason: IgnoreReason.gated,
        failureReason: FailureReason.llmError,
      );
      final map = record.toDbMap();
      expect(map['ignore_reason'], 'gated');
      expect(map['failure_reason'], 'llm_error');
    });

    test('null reasons serialize to null', () {
      const record = SmsRecord(sender: 'CHK', content: 'x', timestamp: 1);
      final map = record.toDbMap();
      expect(map['ignore_reason'], isNull);
      expect(map['failure_reason'], isNull);
    });

    test('fromDbMap parses reason enums back', () {
      final record = SmsRecord.fromDbMap({
        'id': 1,
        'sender': 'CHK',
        'content': 'x',
        'timestamp': 1,
        'status': 'ignored',
        'ignore_reason': 'llm_none',
        'failure_reason': 'retry_exhausted',
      });
      expect(record.status, SmsStatus.ignored);
      expect(record.ignoreReason, IgnoreReason.llmNone);
      expect(record.failureReason, FailureReason.retryExhausted);
    });

    test('fromDbMap tolerates missing/unknown reasons as null', () {
      final record = SmsRecord.fromDbMap({
        'sender': 'CHK',
        'content': 'x',
        'timestamp': 1,
        'status': 'success',
      });
      expect(record.ignoreReason, isNull);
      expect(record.failureReason, isNull);
    });

    test('copyWith carries reasons through', () {
      const base = SmsRecord(sender: 'CHK', content: 'x', timestamp: 1);
      final copy = base.copyWith(
        status: SmsStatus.failure,
        failureReason: FailureReason.llmError,
      );
      expect(copy.failureReason, FailureReason.llmError);
      expect(copy.ignoreReason, isNull);
    });
  });
}
