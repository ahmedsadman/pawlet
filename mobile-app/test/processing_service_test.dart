import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/data/banks_repository.dart';
import 'package:pawlet/data/sms_repository.dart';
import 'package:pawlet/models/sms_record.dart';
import 'package:pawlet/services/classification/classifier.dart';
import 'package:pawlet/services/classification/local_classifier.dart';
import 'package:pawlet/services/classification/local_model.dart';
import 'package:pawlet/services/finance/finance_writer.dart';
import 'package:pawlet/services/llm/llm_provider.dart';
import 'package:pawlet/services/llm/openrouter_provider.dart';
import 'package:pawlet/services/processing_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/db_test_helpers.dart';

/// Fake LLM: returns a canned result, or throws a canned error.
class _FakeLlm implements LlmProvider {
  _FakeLlm({this.result, this.error});
  ClassifyResult? result;
  LlmException? error;
  int calls = 0;

  @override
  Future<ClassifyResult> classifyAndExtract({
    required String content,
    required String sender,
    required String currency,
  }) async {
    calls++;
    if (error != null) throw error!;
    return result ?? const ClassifyResult.none();
  }
}

/// Fake LLM that runs a caller-supplied handler per call (keyed off content), so
/// a test can route different messages to success/failure or observe overlap.
class _FnLlm implements LlmProvider {
  _FnLlm(this.handler);
  final Future<ClassifyResult> Function(String content) handler;

  @override
  Future<ClassifyResult> classifyAndExtract({
    required String content,
    required String sender,
    required String currency,
  }) => handler(content);
}

ClassifyResult _expense() => const ClassifyResult(
  category: SmsCategory.transaction,
  transaction: MetadataResult(
    amount: '50',
    originalAmount: '50',
    transactionType: 'expense',
    originalCurrency: 'BDT',
  ),
);

/// Fake on-device classifier returning a canned prediction (or null).
class _FakeLocal implements LocalClassifier {
  _FakeLocal(this.prediction);
  final LocalPrediction? prediction;

  @override
  Future<LocalPrediction?> infer(String content) async => prediction;
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  late SmsRepository sms;
  late BanksRepository banks;
  int now = 1_000_000;

  setUp(() async {
    db = await openTestDb();
    sms = SmsRepository(db);
    banks = BanksRepository(db);
    now = 1_000_000;
    // A bank whose matcher "chk" lets sender "CHK" pass Layer 1.
    await banks.create(name: 'Checking', matchers: const ['chk']);
  });

  ProcessingService service(
    LlmProvider llm, {
    bool online = true,
    Future<bool> Function()? isOnline,
    Future<void> Function(int failed)? onCounts,
    Future<void> Function(Duration? delay)? reschedule,
  }) => ProcessingService(
    smsRepository: sms,
    banksRepository: banks,
    classifier: Classifier(llm),
    financeWriter: FinanceWriter(db, nowMs: () => now),
    isOnline: isOnline ?? () async => online,
    currency: () => 'BDT',
    clock: () => now,
    onCounts: onCounts,
    reschedule: reschedule,
  );

  Future<Map<String, Object?>> row(int id) async =>
      (await db.query('sms_records', where: 'id = ?', whereArgs: [id])).first;

  Future<int> queue(
    String sender, {
    String content = 'debit 50',
    int attempts = 0,
  }) async {
    final id = (await sms.insertIfNew(
      SmsRecord(
        sender: sender,
        content: content,
        timestamp: now,
        updatedAt: now,
      ),
    ))!;
    if (attempts != 0) {
      await sms.updateStatus(
        id,
        SmsStatus.queued,
        attempts: attempts,
        updatedAt: now,
      );
    }
    return id;
  }

  test(
    'threads the USD->BDT rate so a USD message converts on-device',
    () async {
      const content = 'POS Transaction USD 100';
      final llm = _FakeLlm(result: _expense());
      var rateCalls = 0;
      final local = _FakeLocal(
        LocalPrediction(
          classLabel: 'expense',
          classConfidence: 0.95,
          spans: [
            LocalSpan(
              entity: 'AMOUNT',
              text: '100',
              confidence: 0.97,
              start: content.indexOf('100'),
              end: content.indexOf('100') + 3,
            ),
          ],
        ),
      );
      final svc = ProcessingService(
        smsRepository: sms,
        banksRepository: banks,
        classifier: Classifier(llm, local: local),
        financeWriter: FinanceWriter(db, nowMs: () => now),
        isOnline: () async => true,
        currency: () => 'BDT',
        usdBdtRate: () async {
          rateCalls++;
          return Decimal.parse('120');
        },
        clock: () => now,
      );
      final id = await queue('CHK', content: content);
      await svc.process();

      expect(rateCalls, 1); // fetched once for the pass
      expect(llm.calls, 0); // converted on-device, no LLM
      final tx = (await db.query(
        'transactions',
        where: 'message_id = ?',
        whereArgs: [id],
      )).first;
      expect(tx['normalized_amount'], '12000');
      expect(tx['normalized_currency'], 'BDT');
      expect(tx['original_currency'], 'USD');
      expect(tx['original_amount'], '100');
      await db.close();
    },
  );

  test('processes a matching SMS into a transaction', () async {
    final id = await queue('CHK');
    final llm = _FakeLlm(
      result: const ClassifyResult(
        category: SmsCategory.transaction,
        transaction: MetadataResult(
          amount: '50',
          originalAmount: '50',
          transactionType: 'expense',
          originalCurrency: 'BDT',
        ),
      ),
    );
    await service(llm).process();

    final r = await row(id);
    expect(r['status'], 'success');
    expect(r['category'], 'transaction');
    expect(llm.calls, 1);
    expect((await db.query('transactions')).length, 1);
    await db.close();
  });

  test(
    'bumps the data revision after a pass that processed a record',
    () async {
      await queue('CHK');
      final llm = _FakeLlm(
        result: const ClassifyResult(
          category: SmsCategory.transaction,
          transaction: MetadataResult(
            amount: '50',
            originalAmount: '50',
            transactionType: 'expense',
            originalCurrency: 'BDT',
          ),
        ),
      );
      expect(await sms.dataRevision(), 0);
      await service(llm).process();
      expect(await sms.dataRevision(), 1);
      await db.close();
    },
  );

  test('does not bump the data revision when the queue is empty', () async {
    final llm = _FakeLlm(result: const ClassifyResult.none());
    await service(llm).process();
    expect(await sms.dataRevision(), 0);
    await db.close();
  });

  test('still bumps the data revision when onCounts throws', () async {
    await queue('DARAZ', content: 'win a prize'); // gated, offline-safe
    final llm = _FakeLlm(result: const ClassifyResult.none());
    await service(
      llm,
      onCounts: (_) async => throw StateError('notifications down'),
    ).process();
    expect(await sms.dataRevision(), 1);
    await db.close();
  });

  test('does not bump the data revision when offline (pass bails)', () async {
    await queue('CHK');
    final llm = _FakeLlm(result: const ClassifyResult.none());
    await service(llm, online: false).process();
    expect(await sms.dataRevision(), 0);
    await db.close();
  });

  test(
    'never runs more than one LLM call at once across two isolates',
    () async {
      for (var i = 0; i < 3; i++) {
        await queue('CHK', content: 'debit $i');
      }
      var active = 0, maxActive = 0;
      final llm = _FnLlm((_) async {
        active++;
        if (active > maxActive) maxActive = active;
        await Future<void>.delayed(const Duration(milliseconds: 15));
        active--;
        return _expense();
      });
      // Two ProcessingService instances over the same shared DB stand in for two
      // isolates; the single-slot claim must serialize them.
      await Future.wait([service(llm).process(), service(llm).process()]);
      expect(maxActive, 1);
      expect(
        (await db.query('sms_records', where: "status = 'success'")).length,
        3,
      );
      await db.close();
    },
  );

  test(
    'a failing head item does not block later items; it retries later',
    () async {
      final first = await queue('CHK', content: 'first');
      final second = await queue('CHK', content: 'second');
      final llm = _FnLlm((content) async {
        if (content.contains('first')) {
          throw const LlmException('transient', retryable: true);
        }
        return _expense();
      });
      await service(llm).process();

      final r1 = await row(first);
      final r2 = await row(second);
      // The failed head is rescheduled to a future backoff (not stuck sending)...
      expect(r1['status'], 'queued');
      expect(r1['next_attempt_at'], isNotNull);
      // ...and the next item was still processed in the same pass.
      expect(r2['status'], 'success');
      await db.close();
    },
  );

  test(
    'a fully contended pass skips afterPass and the change signal',
    () async {
      final held = await queue('CHK', content: 'held');
      await sms.claim(held, now); // occupy the single global slot
      await queue('CHK', content: 'waiting'); // due, but the slot is busy
      var afterPassRuns = 0;
      final llm = _FnLlm((_) async => _expense());
      await ProcessingService(
        smsRepository: sms,
        banksRepository: banks,
        classifier: Classifier(llm),
        financeWriter: FinanceWriter(db, nowMs: () => now),
        isOnline: () async => true,
        currency: () => 'BDT',
        clock: () => now,
        afterPass: () async => afterPassRuns++,
      ).process();
      // Claimed nothing, so no matcher run and no data-change bump.
      expect(afterPassRuns, 0);
      expect(await sms.dataRevision(), 0);
      await db.close();
    },
  );

  test(
    'schedules a reclaim catch-up when only an orphaned sending row remains',
    () async {
      final held = await queue('CHK', content: 'held');
      await sms.claim(held, now); // sending; no queued rows remain
      Duration? scheduled;
      var calls = 0;
      await service(
        _FakeLlm(result: const ClassifyResult.none()),
        reschedule: (d) async {
          scheduled = d;
          calls++;
        },
      ).process();
      // A sole in-flight row must NOT cancel the catch-up; it schedules a wake at
      // ~staleAfter so a later pass can reclaim it if its holder died.
      expect(calls, 1);
      expect(scheduled, ProcessingService.staleAfter);
      await db.close();
    },
  );

  test(
    'blocked queued rows wake at stale-reclaim, not immediately (no WM busy-loop)',
    () async {
      // The single slot is held by an in-flight row, and a due-now queued row is
      // waiting behind it. The queued row CANNOT be claimed until the holder is
      // reclaimed as stale, so the next catch-up must be scheduled at ~staleAfter
      // — NOT at ~0. A ~0 delay makes WorkManager re-run the catch-up back-to-back
      // (it reschedules itself every pass), a livelock that janks the whole app.
      final held = await queue('CHK', content: 'held');
      await sms.claim(held, now); // sending; occupies the single global slot
      await queue('CHK', content: 'waiting'); // queued, due now, but blocked
      Duration? scheduled;
      var calls = 0;
      await service(
        _FakeLlm(result: const ClassifyResult.none()),
        reschedule: (d) async {
          scheduled = d;
          calls++;
        },
      ).process();
      expect(calls, 1);
      expect(scheduled, ProcessingService.staleAfter);
      await db.close();
    },
  );

  test('gates out an unregistered sender as ignored/gated, no LLM', () async {
    final id = await queue('DARAZ', content: 'win a prize');
    final llm = _FakeLlm(result: const ClassifyResult.none());
    await service(llm).process();

    final r = await row(id);
    expect(r['status'], 'ignored');
    expect(r['category'], isNull);
    expect(r['ignore_reason'], IgnoreReason.gated.value);
    expect(llm.calls, 0);
    await db.close();
  });

  test('stores parse_source=llm for an LLM-parsed success row', () async {
    final id = await queue('CHK');
    final llm = _FakeLlm(result: _expense());
    await service(llm).process();

    final r = await row(id);
    expect(r['status'], 'success');
    expect(r['parse_source'], ParseSource.llm.value);
    await db.close();
  });

  test(
    'stores parse_source=local when the on-device model parsed it',
    () async {
      final id = await queue('CHK', content: 'debit 50 BDT');
      // LLM would throw if called; the confident local model must handle it.
      final llm = _FakeLlm(
        error: const LlmException('should not run', retryable: false),
      );
      final local = _FakeLocal(
        const LocalPrediction(
          classLabel: 'expense',
          classConfidence: 0.97,
          spans: [
            LocalSpan(
              entity: 'AMOUNT',
              text: '50',
              confidence: 0.96,
              start: 6,
              end: 8,
            ),
          ],
        ),
      );
      await ProcessingService(
        smsRepository: sms,
        banksRepository: banks,
        classifier: Classifier(llm, local: local),
        financeWriter: FinanceWriter(db, nowMs: () => now),
        isOnline: () async => true,
        currency: () => 'BDT',
        clock: () => now,
      ).process();

      final r = await row(id);
      expect(r['status'], 'success');
      expect(r['category'], 'transaction');
      expect(r['parse_source'], ParseSource.local.value);
      await db.close();
    },
  );

  test(
    'confident local null marks the row ignored/local_none, no LLM',
    () async {
      final id = await queue('CHK', content: 'Your OTP is 1234');
      final llm = _FakeLlm(
        error: const LlmException('should not run', retryable: false),
      );
      final local = _FakeLocal(
        const LocalPrediction(
          classLabel: 'null',
          classConfidence: 0.98,
          spans: [],
        ),
      );
      await ProcessingService(
        smsRepository: sms,
        banksRepository: banks,
        classifier: Classifier(llm, local: local),
        financeWriter: FinanceWriter(db, nowMs: () => now),
        isOnline: () async => true,
        currency: () => 'BDT',
        clock: () => now,
      ).process();

      final r = await row(id);
      expect(r['status'], 'ignored');
      expect(r['ignore_reason'], IgnoreReason.localNone.value);
      expect(r['parse_source'], ParseSource.local.value);
      await db.close();
    },
  );

  test('LLM "none" marks the row ignored/llm_none', () async {
    final id = await queue('CHK', content: 'hello');
    final llm = _FakeLlm(result: const ClassifyResult.none());
    await service(llm).process();

    final r = await row(id);
    expect(r['status'], 'ignored');
    expect(r['category'], isNull);
    expect(r['ignore_reason'], IgnoreReason.llmNone.value);
    expect(llm.calls, 1); // gate passed, LLM ran
    await db.close();
  });

  test('financial but unwritten marks the row ignored/no_record', () async {
    final id = await queue('CHK');
    // LLM says transaction, but no amount/type → FinanceWriter writes nothing.
    final llm = _FakeLlm(
      result: const ClassifyResult(category: SmsCategory.transaction),
    );
    await service(llm).process();

    final r = await row(id);
    expect(r['status'], 'ignored');
    expect(r['ignore_reason'], IgnoreReason.noRecord.value);
    expect((await db.query('transactions')), isEmpty);
    await db.close();
  });

  test('reschedules a retryable failure with backoff', () async {
    final id = await queue('CHK');
    final llm = _FakeLlm(error: const LlmException('rate', retryable: true));
    await service(llm).process();

    final r = await row(id);
    expect(r['status'], 'queued');
    expect(r['attempts'], 1);
    expect(r['next_attempt_at'], now + 15000); // baseBackoff 15s
    await db.close();
  });

  // Server retry hints fold into a single clamped floor, then take the max with
  // our backoff: honor "don't retry before" without ever hammering faster than
  // our own escalation.
  test('honors Retry-After when it exceeds the backoff', () async {
    final id = await queue('CHK');
    final llm = _FakeLlm(
      error: const LlmException(
        'rate',
        retryable: true,
        retryAfter: Duration(seconds: 120),
      ),
    );
    await service(llm).process();

    final r = await row(id);
    expect(r['next_attempt_at'], now + 120000); // hint 120s > 15s backoff
    await db.close();
  });

  test('backoff wins when Retry-After is shorter', () async {
    final id = await queue('CHK');
    final llm = _FakeLlm(
      error: const LlmException(
        'rate',
        retryable: true,
        retryAfter: Duration(seconds: 5),
      ),
    );
    await service(llm).process();

    final r = await row(id);
    expect(r['next_attempt_at'], now + 15000); // 15s backoff > 5s hint
    await db.close();
  });

  test('clamps an over-long Retry-After to 24h', () async {
    final id = await queue('CHK');
    final llm = _FakeLlm(
      error: const LlmException(
        'rate',
        retryable: true,
        retryAfter: Duration(hours: 30),
      ),
    );
    await service(llm).process();

    final r = await row(id);
    expect(r['next_attempt_at'], now + 86400000); // clamped to 24h
    await db.close();
  });

  test('honors an absolute X-RateLimit-Reset in the future', () async {
    final id = await queue('CHK');
    final llm = _FakeLlm(
      error: LlmException(
        'rate',
        retryable: true,
        resetAtEpochMs: now + 120000,
      ),
    );
    await service(llm).process();

    final r = await row(id);
    expect(r['next_attempt_at'], now + 120000); // absolute honored
    await db.close();
  });

  test('ignores a past X-RateLimit-Reset (floors to backoff)', () async {
    final id = await queue('CHK');
    final llm = _FakeLlm(
      error: LlmException('rate', retryable: true, resetAtEpochMs: now - 5000),
    );
    await service(llm).process();

    final r = await row(id);
    expect(r['next_attempt_at'], now + 15000); // past → floored → backoff wins
    await db.close();
  });

  test('clamps an over-long X-RateLimit-Reset to 24h', () async {
    final id = await queue('CHK');
    final llm = _FakeLlm(
      error: LlmException(
        'rate',
        retryable: true,
        resetAtEpochMs: now + Duration(hours: 30).inMilliseconds,
      ),
    );
    await service(llm).process();

    final r = await row(id);
    expect(r['next_attempt_at'], now + 86400000); // clamped to 24h
    await db.close();
  });

  test('takes the larger of both hints vs backoff', () async {
    final id = await queue('CHK');
    final llm = _FakeLlm(
      error: LlmException(
        'rate',
        retryable: true,
        retryAfter: const Duration(seconds: 120),
        resetAtEpochMs: now + 300000,
      ),
    );
    await service(llm).process();

    final r = await row(id);
    expect(
      r['next_attempt_at'],
      now + 300000,
    ); // reset 300s > retryAfter 120s > backoff
    await db.close();
  });

  test('Retry-After wins over a smaller X-RateLimit-Reset', () async {
    final id = await queue('CHK');
    final llm = _FakeLlm(
      error: LlmException(
        'rate',
        retryable: true,
        retryAfter: const Duration(seconds: 300),
        resetAtEpochMs: now + 120000,
      ),
    );
    await service(llm).process();

    final r = await row(id);
    expect(
      r['next_attempt_at'],
      now + 300000,
    ); // retryAfter 300s > reset 120s (fold symmetric)
    await db.close();
  });

  test('fails immediately on a fatal error (llm_error)', () async {
    final id = await queue('CHK');
    final llm = _FakeLlm(
      error: const LlmException('bad key', retryable: false),
    );
    await service(llm).process();

    final r = await row(id);
    expect(r['status'], 'failure');
    expect(r['failure_reason'], FailureReason.llmError.value);
    expect(r['last_error'], 'bad key');
    await db.close();
  });

  test('truncates a long fatal error to 100 chars', () async {
    final id = await queue('CHK');
    final long = 'x' * 250;
    final llm = _FakeLlm(error: LlmException(long, retryable: false));
    await service(llm).process();

    final r = await row(id);
    expect((r['last_error'] as String).length, 100);
    expect(r['last_error'], 'x' * 100);
    await db.close();
  });

  test('exhausts maxAttempts into failure (retry_exhausted)', () async {
    final id = await queue('CHK', attempts: ProcessingService.maxAttempts - 1);
    final llm = _FakeLlm(error: const LlmException('rate', retryable: true));
    await service(llm).process();

    final r = await row(id);
    expect(r['status'], 'failure');
    expect(r['attempts'], ProcessingService.maxAttempts);
    expect(r['failure_reason'], FailureReason.retryExhausted.value);
    await db.close();
  });

  test('process() prunes an aged ignored row (pruneIfDue)', () async {
    // An old ignored row plus an empty due-queue: the pass-level pruneIfDue
    // should delete it (last_prune_at is unset → due immediately).
    final id = (await sms.insertIfNew(
      SmsRecord(sender: 'OLD', content: 'x', timestamp: now, updatedAt: now),
    ))!;
    await sms.updateStatus(
      id,
      SmsStatus.ignored,
      updatedAt: now - const Duration(days: 8).inMilliseconds,
      ignoreReason: IgnoreReason.gated,
    );
    final llm = _FakeLlm(result: const ClassifyResult.none());
    await service(llm).process();

    final rows = await db.query(
      'sms_records',
      where: 'id = ?',
      whereArgs: [id],
    );
    expect(rows, isEmpty);
    await db.close();
  });

  test('reports the failed count via onCounts', () async {
    await queue('CHK');
    int? failed;
    final llm = _FakeLlm(
      error: const LlmException('bad key', retryable: false),
    );
    await service(llm, onCounts: (f) async => failed = f).process();
    expect(failed, 1);
    await db.close();
  });

  test('releases the row unchanged if it goes offline mid-processing', () async {
    final id = await queue('CHK');
    // Online for process()+_processOne checks, offline by the reschedule check.
    var checks = 0;
    final llm = _FakeLlm(error: const LlmException('rate', retryable: true));
    await service(
      llm,
      isOnline: () async {
        checks++;
        return checks <= 2;
      },
    ).process();

    final r = await row(id);
    expect(r['status'], 'queued');
    expect(r['attempts'], 0); // transport drop, not a real attempt
    expect(r['next_attempt_at'], isNull);
    await db.close();
  });

  test(
    'schedules the next catch-up at the backoff time after a retry',
    () async {
      await queue('CHK');
      Duration? scheduled;
      var calls = 0;
      final llm = _FakeLlm(error: const LlmException('rate', retryable: true));
      await service(
        llm,
        reschedule: (d) async {
          scheduled = d;
          calls++;
        },
      ).process();
      expect(calls, 1);
      expect(scheduled, const Duration(seconds: 15)); // baseBackoff
      await db.close();
    },
  );

  test('cancels the catch-up when the queue drains', () async {
    await queue('CHK');
    var cancelled = false;
    final llm = _FakeLlm(result: const ClassifyResult.none());
    await service(
      llm,
      reschedule: (d) async => cancelled = d == null,
    ).process();
    expect(cancelled, isTrue);
    await db.close();
  });

  test('offline still schedules a catch-up for the due backlog', () async {
    await queue('CHK'); // due now
    Duration? scheduled;
    final llm = _FakeLlm(result: const ClassifyResult.none());
    await service(
      llm,
      online: false,
      reschedule: (d) async => scheduled = d,
    ).process();
    expect(scheduled, Duration.zero);
    await db.close();
  });

  test('does nothing while offline', () async {
    final id = await queue('CHK');
    final llm = _FakeLlm(result: const ClassifyResult.none());
    await service(llm, online: false).process();

    final r = await row(id);
    expect(r['status'], 'queued'); // untouched
    expect(llm.calls, 0);
    await db.close();
  });

  // The single-retry design's safety rests on this ordering across two files: a
  // legitimately slow in-flight call (up to OpenRouterProvider.timeout) must not
  // be reclaimed as orphaned (ProcessingService.staleAfter) mid-flight. Guard it
  // so a future edit to either constant can't silently reintroduce that race.
  test('provider timeout stays safely below the stale-reclaim threshold', () {
    expect(OpenRouterProvider.timeout, lessThan(ProcessingService.staleAfter));
  });
}
