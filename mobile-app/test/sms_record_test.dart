import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/models/sms_record.dart';

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
      expect(IgnoreReason.localNone.value, 'local_none');
      expect(IgnoreReason.llmNone.value, 'llm_none');
      expect(IgnoreReason.noRecord.value, 'no_record');
    });
  });

  group('ParseSource', () {
    test('round-trips every value', () {
      for (final s in ParseSource.values) {
        expect(ParseSource.fromValue(s.value), s);
      }
    });

    test('returns null for null or unknown', () {
      expect(ParseSource.fromValue(null), isNull);
      expect(ParseSource.fromValue('nope'), isNull);
    });

    test('uses the expected backing values', () {
      expect(ParseSource.local.value, 'local');
      expect(ParseSource.llm.value, 'llm');
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
      expect(FailureReason.localOnly.value, 'local_only');
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

    test('parseSource round-trips through the DB map', () {
      const rec = SmsRecord(
        sender: 'MTB',
        content: 'debit 50',
        timestamp: 1,
        parseSource: ParseSource.llm,
      );
      final map = rec.toDbMap();
      expect(map['parse_source'], 'llm');
      final back = SmsRecord.fromDbMap(map);
      expect(back.parseSource, ParseSource.llm);
    });

    test('null parseSource serializes to null and reads back null', () {
      const rec = SmsRecord(sender: 'MTB', content: 'x', timestamp: 1);
      expect(rec.toDbMap()['parse_source'], isNull);
      final back = SmsRecord.fromDbMap({
        'sender': 'MTB',
        'content': 'x',
        'timestamp': 1,
        'status': 'success',
      });
      expect(back.parseSource, isNull);
    });

    test('copyWith carries parseSource through', () {
      const base = SmsRecord(sender: 'CHK', content: 'x', timestamp: 1);
      final copy = base.copyWith(parseSource: ParseSource.local);
      expect(copy.parseSource, ParseSource.local);
    });
  });

  group('SmsStatus.processing', () {
    test('round-trips through fromName', () {
      expect(SmsStatus.fromName('processing'), SmsStatus.processing);
    });

    test('counts as queued for the Queue section', () {
      const r = SmsRecord(
        sender: 'A',
        content: 'x',
        timestamp: 1,
        status: SmsStatus.processing,
      );
      expect(r.isQueued, isTrue);
    });
  });

  group('needsLlm', () {
    test('defaults to false and round-trips through the DB map', () {
      const off = SmsRecord(sender: 'A', content: 'x', timestamp: 1);
      expect(off.needsLlm, isFalse);
      expect(off.toDbMap()['needs_llm'], 0);

      const on = SmsRecord(
        sender: 'A',
        content: 'x',
        timestamp: 1,
        needsLlm: true,
      );
      expect(on.toDbMap()['needs_llm'], 1);
      expect(SmsRecord.fromDbMap(on.toDbMap()).needsLlm, isTrue);
    });

    test('copyWith carries the flag', () {
      const r = SmsRecord(sender: 'A', content: 'x', timestamp: 1);
      expect(r.copyWith(needsLlm: true).needsLlm, isTrue);
    });
  });

  group('llmMessageKey', () {
    SmsRecord rec({int? id = 7, int timestamp = 1700000000000}) => SmsRecord(
      id: id,
      sender: 'BANK',
      content: 'debit 50',
      timestamp: timestamp,
      updatedAt: 0,
    );

    test('is 32 lowercase hex characters', () {
      expect(rec().llmMessageKey, matches(RegExp(r'^[0-9a-f]{32}$')));
    });

    test('stays the same as the row moves through the queue', () {
      final queued = rec();
      final retried = SmsRecord(
        id: 7,
        sender: 'BANK',
        content: 'debit 50',
        timestamp: 1700000000000,
        updatedAt: 99,
        status: SmsStatus.queued,
        attempts: 3,
      );
      expect(retried.llmMessageKey, queued.llmMessageKey);
    });

    test('differs per row and per timestamp', () {
      expect(rec(id: 8).llmMessageKey, isNot(rec().llmMessageKey));
      expect(rec(timestamp: 1).llmMessageKey, isNot(rec().llmMessageKey));
    });

    test('is null for a row not yet stored', () {
      expect(rec(id: null).llmMessageKey, isNull);
    });
  });

  test('normalizeSmsContent folds CRLF/CR to LF and trims the edges', () {
    expect(normalizeSmsContent('  a\r\nb\rc \n'), 'a\nb\nc');
    expect(normalizeSmsContent('plain'), 'plain');
    expect(normalizeSmsContent(' \r\n '), '');
  });
}
