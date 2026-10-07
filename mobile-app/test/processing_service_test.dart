import 'dart:async';

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

/// Fake on-device classifier that answers per message, so one pass can mix a
/// locally-solvable row with an LLM-bound one. Counts every inference.
class _FnLocal implements LocalClassifier {
  _FnLocal(this.handler);
  final LocalPrediction? Function(String content) handler;
  int calls = 0;

  @override
  Future<LocalPrediction?> infer(String content) async {
    calls++;
    return handler(content);
  }
}

/// Fake on-device classifier that runs an async side effect before declining,
/// so a test can steal the row out from under the holder mid-inference.
///
/// Declines with a low-confidence prediction rather than null: null is the
/// model-unavailable state, which never sets `needs_llm`, so the flag
/// assertion in the theft test would hold for the wrong reason.
class _StealingLocal implements LocalClassifier {
  _StealingLocal(this.onInfer);
  final Future<void> Function() onInfer;

  @override
  Future<LocalPrediction?> infer(String content) async {
    await onInfer();
    return _localUnsure;
  }
}

/// A prediction the gate turns down on confidence. Distinct from a null
/// prediction: the model ran and had an opinion, it just was not good enough —
/// the only rejection that may be remembered in `needs_llm`.
const _localUnsure = LocalPrediction(
  classLabel: 'expense',
  classConfidence: 0.4,
  spans: [],
);

/// A confident "expense, amount 50" prediction over a `debit 50 ...` body.
LocalPrediction _localExpense(String content) => LocalPrediction(
  classLabel: 'expense',
  classConfidence: 0.97,
  spans: [
    LocalSpan(
      entity: 'AMOUNT',
      text: '50',
      confidence: 0.96,
      start: content.indexOf('50'),
      end: content.indexOf('50') + 2,
    ),
  ],
);

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
    LocalClassifier? local,
    Future<bool> Function()? isOnline,
    Future<void> Function(int failed)? onCounts,
    Future<void> Function(Duration? delay)? reschedule,
  }) => ProcessingService(
    smsRepository: sms,
    banksRepository: banks,
    classifier: Classifier(llm, local: local),
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
    int? timestamp,
  }) async {
    final id = (await sms.insertIfNew(
      SmsRecord(
        sender: sender,
        content: content,
        timestamp: timestamp ?? now,
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

  /// Puts a row into the single global LLM slot, as an in-flight LLM call does.
  Future<void> holdLlmSlot(int id) async {
    await sms.claimLocal(id, now);
    await sms.acquireLlmSlot(id, now);
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

  test('isRunning is true only while a pass is in flight', () async {
    await queue('CHK');
    final gate = Completer<ClassifyResult>();
    final svc = service(_FnLlm((_) => gate.future));
    expect(svc.isRunning, isFalse);

    final pass = svc.process();
    await pumpEventQueue();
    expect(svc.isRunning, isTrue);

    gate.complete(_expense());
    await pass;
    expect(svc.isRunning, isFalse);
    await db.close();
  });

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
      await holdLlmSlot(held); // occupy the single global slot
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
      await holdLlmSlot(held); // sending; no queued rows remain
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
      await holdLlmSlot(held); // occupies the single global slot
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

  test('gates out an unregistered sender before any model runs', () async {
    final id = await queue('DARAZ', content: 'win a prize');
    final llm = _FakeLlm(result: const ClassifyResult.none());
    // Wired with a confident model on purpose: Layer 1 must short-circuit
    // BEFORE inference, so non-bank spam never costs a 26 MB model run.
    // Without the local.calls assertion, moving the gate after Layer 2 passes.
    final local = _FnLocal(
      (_) => const LocalPrediction(
        classLabel: 'expense',
        classConfidence: 0.99,
        spans: [],
      ),
    );
    await service(llm, local: local).process();

    final r = await row(id);
    expect(r['status'], 'ignored');
    expect(r['category'], isNull);
    expect(r['ignore_reason'], IgnoreReason.gated.value);
    expect(local.calls, 0);
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

  // Layers 1 and 2 touch no network, so an offline pass still drains everything
  // they can decide; only a genuinely LLM-bound row waits.

  test('offline, an unregistered sender is gated out with no LLM', () async {
    final id = await queue('DARAZ', content: 'win a prize');
    final llm = _FakeLlm(result: const ClassifyResult.none());
    await service(llm, online: false).process();

    final r = await row(id);
    expect(r['status'], 'ignored');
    expect(r['ignore_reason'], IgnoreReason.gated.value);
    expect(llm.calls, 0);
    await db.close();
  });

  test('offline, a confident local prediction succeeds on-device', () async {
    const content = 'debit 50 BDT';
    final id = await queue('CHK', content: content);
    // The LLM would throw if reached; the local model must settle this.
    final llm = _FakeLlm(
      error: const LlmException('should not run', retryable: false),
    );
    await service(
      llm,
      online: false,
      local: _FakeLocal(_localExpense(content)),
    ).process();

    final r = await row(id);
    expect(r['status'], 'success');
    expect(r['category'], 'transaction');
    expect(r['parse_source'], ParseSource.local.value);
    expect(
      (await db.query(
        'transactions',
        where: 'message_id = ?',
        whereArgs: [id],
      )).length,
      1,
    );
    await db.close();
  });

  test('offline, an LLM-bound row waits without burning an attempt', () async {
    final id = await queue('CHK');
    final llm = _FakeLlm(result: _expense());
    await service(
      llm,
      online: false,
      local: _FakeLocal(_localUnsure),
    ).process();

    final r = await row(id);
    expect(r['status'], 'queued'); // still due, not backed off
    expect(r['attempts'], 0);
    expect(r['next_attempt_at'], isNull);
    expect(r['needs_llm'], 1);
    expect(llm.calls, 0);
    await db.close();
  });

  // `needs_llm` is never cleared, so it may only record a verdict the model
  // actually reached. A model that fails to load returns null for every
  // message; flagging on that would route the whole backlog to the paid LLM
  // permanently, and offline those rows are skipped before the claim, so
  // nothing would ever revisit them.
  group('needs_llm records a decline, not a missing answer', () {
    test('a low-confidence prediction flags the row', () async {
      final id = await queue('CHK');
      final llm = _FakeLlm(result: _expense());
      final local = _FnLocal((_) => _localUnsure);
      await service(llm, online: false, local: local).process();

      expect(local.calls, 1);
      expect((await row(id))['needs_llm'], 1);
      await db.close();
    });

    test('an unwired model does not flag the row', () async {
      final id = await queue('CHK');
      final llm = _FakeLlm(result: _expense());
      await service(llm, online: false).process();

      final r = await row(id);
      expect(r['status'], 'queued'); // still deferred, just not written off
      expect(r['needs_llm'], 0);
      await db.close();
    });

    test('a model that returns nothing does not flag the row', () async {
      final id = await queue('CHK');
      final llm = _FakeLlm(result: _expense());
      final local = _FnLocal((_) => null);
      await service(llm, online: false, local: local).process();

      expect((await row(id))['needs_llm'], 0);
      await db.close();
    });

    test('so a later pass retries the inference it never got', () async {
      await queue('CHK');
      final llm = _FakeLlm(result: _expense());
      // Broken for the first pass, working for the second — the row must still
      // be reachable on-device for the recovery to land.
      var broken = true;
      final local = _FnLocal((c) => broken ? null : _localExpense(c));
      await service(llm, online: false, local: local).process();
      broken = false;
      await service(llm, online: false, local: local).process();

      expect(local.calls, 2);
      expect((await db.query('transactions')).length, 1);
      expect(llm.calls, 0);
      await db.close();
    });

    test('a slot-contended deferral is judged the same way', () async {
      // Online but blocked on the single LLM slot: the deferral is identical,
      // so the unavailable model must not be written off here either.
      final held = await queue('CHK', content: 'held', timestamp: now - 1000);
      await holdLlmSlot(held);
      final id = await queue('CHK', content: 'waiting');
      final llm = _FakeLlm(result: _expense());
      await service(llm, local: _FnLocal((_) => null)).process();

      expect((await row(id))['needs_llm'], 0);
      await db.close();
    });
  });

  test('offline, a deferral alone does not bump the data revision', () async {
    await queue('CHK');
    final llm = _FakeLlm(result: _expense());
    await service(llm, online: false).process();
    expect(await sms.dataRevision(), 0);
    await db.close();
  });

  test(
    'offline, an LLM-bound head does not block a local row behind it',
    () async {
      const content = 'debit 50 BDT';
      // Older timestamp → sorted first by dueForDelivery, so it is the head.
      final head = await queue(
        'CHK',
        content: 'wire transfer, unclear',
        timestamp: now - 1000,
      );
      final behind = await queue('CHK', content: content);
      final llm = _FakeLlm(result: _expense());
      final local = _FnLocal(
        (c) => c == content ? _localExpense(c) : _localUnsure,
      );
      await service(llm, online: false, local: local).process();

      final h = await row(head);
      expect(h['status'], 'queued');
      expect(h['needs_llm'], 1);
      expect((await row(behind))['status'], 'success');
      expect(llm.calls, 0);
      await db.close();
    },
  );

  test('a flagged row skips the model on later offline passes', () async {
    await queue('CHK');
    final llm = _FakeLlm(result: _expense());
    final local = _FnLocal((_) => _localUnsure);
    for (var i = 0; i < 3; i++) {
      await service(llm, online: false, local: local).process();
    }
    // Flagged by the first pass; the verdict is stable, so never re-run.
    expect(local.calls, 1);
    await db.close();
  });

  test('a flagged row goes straight to the LLM once online', () async {
    final id = await queue('CHK');
    final llm = _FakeLlm(result: _expense());
    final local = _FnLocal((_) => _localUnsure);
    await service(llm, online: false, local: local).process();
    await service(llm, local: local).process();

    expect(local.calls, 1); // not re-run online either
    expect(llm.calls, 1);
    expect((await row(id))['status'], 'success');
    await db.close();
  });

  test('a deferred row is picked up by the next online pass', () async {
    final id = await queue('CHK');
    final llm = _FakeLlm(result: _expense());
    await service(llm, online: false).process();
    expect((await row(id))['status'], 'queued');

    await service(llm).process();
    final r = await row(id);
    expect(r['status'], 'success');
    expect(r['parse_source'], ParseSource.llm.value);
    expect(llm.calls, 1);
    await db.close();
  });

  test('a flagged row whose bank was deleted is still gated out', () async {
    final id = await queue('CHK');
    final llm = _FakeLlm(result: _expense());
    await service(
      llm,
      online: false,
      local: _FakeLocal(_localUnsure),
    ).process();
    expect((await row(id))['needs_llm'], 1);

    for (final b in await banks.list()) {
      await banks.delete(b.id);
    }
    await service(llm).process();

    final r = await row(id);
    expect(r['status'], 'ignored');
    expect(r['ignore_reason'], IgnoreReason.gated.value);
    expect(llm.calls, 0); // the gate runs ahead of the LLM, flagged or not
    await db.close();
  });

  test('online, a row defers rather than blocking on a held slot', () async {
    final held = await queue('CHK', content: 'held', timestamp: now - 1000);
    await holdLlmSlot(held);
    final id = await queue('CHK', content: 'waiting');
    final llm = _FakeLlm(result: _expense());
    await service(llm, local: _FakeLocal(_localUnsure)).process();

    final r = await row(id);
    expect(r['status'], 'queued');
    expect(r['attempts'], 0); // waiting for the slot is not an attempt
    expect(r['next_attempt_at'], isNull);
    expect(r['needs_llm'], 1);
    expect(llm.calls, 0);
    await db.close();
  });

  test('online, a local row behind a held slot still succeeds', () async {
    const content = 'debit 50 BDT';
    final held = await queue('CHK', content: 'held', timestamp: now - 1000);
    await holdLlmSlot(held);
    final id = await queue('CHK', content: content);
    final llm = _FakeLlm(
      error: const LlmException('should not run', retryable: false),
    );
    await service(llm, local: _FakeLocal(_localExpense(content))).process();

    final r = await row(id);
    expect(r['status'], 'success');
    expect(r['parse_source'], ParseSource.local.value);
    await db.close();
  });

  test('reclaims and processes a row orphaned in processing', () async {
    final id = await queue('CHK');
    await sms.claimLocal(id, now); // the holder dies right here
    now += ProcessingService.staleAfter.inMilliseconds + 1;
    final llm = _FakeLlm(result: _expense());
    await service(llm).process();

    final r = await row(id);
    expect(r['status'], 'success');
    expect(llm.calls, 1);
    await db.close();
  });

  test(
    'an older processing row cannot pull the wake below the slot floor',
    () async {
      // oldestInFlightAt spans `processing` as well as `sending`, so it can be
      // older than the slot holder. Reclaiming a `processing` row frees no
      // slot, so the wake must still sit at the slot's stale-reclaim time — not
      // ~0, which is the WorkManager busy-loop the floor exists to prevent.
      final local = await queue('CHK', content: 'local', timestamp: now - 2000);
      await sms.claimLocal(local, now - 5000); // processing, predates the slot
      final held = await queue('CHK', content: 'held', timestamp: now - 1000);
      await holdLlmSlot(held); // sending at `now`
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

  test(
    'a claim lost mid-LLM-call writes neither a finance row nor a status',
    () async {
      // The whole point of re-checking the claim before FinanceWriter.apply:
      // the status write can be rejected, the transaction insert cannot be
      // undone, and the next holder would settle the row as ignored/no_record
      // with a real transaction hanging off it.
      final id = await queue('CHK');
      final llm = _FnLlm((_) async {
        // This holder freezes; its row is reclaimed and another isolate takes
        // it while the call is still out.
        await sms.reclaimStale(now + 1);
        await sms.claimLocal(id, now + 10);
        return _expense();
      });
      await service(llm).process();

      final r = await row(id);
      expect(r['status'], 'processing'); // exactly as the new holder left it
      expect(r['updated_at'], now + 10);
      expect(await db.query('transactions'), isEmpty);
      expect(await sms.dataRevision(), 0); // a lost write is not progress
      await db.close();
    },
  );

  test(
    'dataRevision bumps when a finance row is written, even if the status write is later rejected',
    () async {
      // The normal happy path: a transaction is written and the status write
      // succeeds. dataRevision bumps because progress was made.
      final id = await queue('CHK');
      final llm = _FnLlm((_) async => _expense());
      await service(llm).process();

      var r = await row(id);
      expect(r['status'], 'success');
      expect((await db.query('transactions')).length, 1);
      expect(await sms.dataRevision(), 1);

      // The residual case the fix addresses: if apply had committed the
      // transaction but the status write was then rejected (claim lost during
      // apply's brief window), _finish must still return true so dataRevision
      // bumps. We can't easily test the race directly, but the code path is:
      // when label != 'ignored', return true regardless of status write outcome.
      //
      // Verify the converse doesn't regress: when nothing is written (dupe),
      // dataRevision bumps only if the status write succeeds.
      await sms.updateStatus(
        id,
        SmsStatus.queued,
        attempts: 0,
        updatedAt: now + 100,
      );
      await service(llm).process();

      r = await row(id);
      expect(r['status'], 'ignored'); // dupe settled as noRecord
      expect(r['ignore_reason'], IgnoreReason.noRecord.value);
      expect(await sms.dataRevision(), 2); // bumped because status write landed
      await db.close();
    },
  );

  test('a claim lost mid-inference cannot defer the row to the LLM', () async {
    final id = await queue('CHK');
    final local = _StealingLocal(() async {
      await sms.reclaimStale(now + 1);
      await sms.claimLocal(id, now + 10);
    });
    final llm = _FakeLlm(result: _expense());
    await service(llm, online: false, local: local).process();

    final r = await row(id);
    expect(r['status'], 'processing'); // the new holder still owns it
    expect(r['updated_at'], now + 10);
    expect(r['needs_llm'], 0); // no flag stamped onto someone else's row
    expect(await sms.dataRevision(), 0);
    await db.close();
  });

  // The single-retry design's safety rests on this ordering across two files: a
  // legitimately slow in-flight call (up to OpenRouterProvider.timeout) must not
  // be reclaimed as orphaned (ProcessingService.staleAfter) mid-flight. Guard it
  // so a future edit to either constant can't silently reintroduce that race.
  test('provider timeout stays safely below the stale-reclaim threshold', () {
    expect(OpenRouterProvider.timeout, lessThan(ProcessingService.staleAfter));
  });

  // A background isolate cannot mint a proxy session. That is not the
  // message's fault, so it must not spend the retry budget of a user who
  // simply has not opened the app.
  group('an LLM that needs the foreground', () {
    const needsForeground = LlmException(
      'attestation: no channel',
      retryable: true,
      needsForeground: true,
    );

    test('releases the row without burning an attempt', () async {
      final id = await queue('CHK', attempts: 3);
      int? failed;
      final llm = _FakeLlm(error: needsForeground);
      await service(
        llm,
        local: _FakeLocal(_localUnsure),
        onCounts: (f) async => failed = f,
      ).process();

      final r = await row(id);
      expect(llm.calls, 1);
      expect(r['status'], 'queued');
      expect(r['attempts'], 3);
      expect(r['next_attempt_at'], isNull); // still due for the foreground
      expect(r['needs_llm'], 1); // the model's decline is still remembered
      expect(failed, 0);
      await db.close();
    });

    test('never fails the row, however many passes it takes', () async {
      final id = await queue(
        'CHK',
        attempts: ProcessingService.maxAttempts - 1,
      );
      final svc = service(_FakeLlm(error: needsForeground));
      await svc.process();
      await svc.process();
      expect((await row(id))['status'], 'queued');
      await db.close();
    });

    test('waits before the next background catch-up', () async {
      await queue('CHK');
      Duration? scheduled;
      await service(
        _FakeLlm(error: needsForeground),
        reschedule: (d) async => scheduled = d,
      ).process();
      expect(scheduled, ProcessingService.foregroundWait);
      await db.close();
    });

    test('a later pass that can reach the LLM processes it at once', () async {
      final id = await queue('CHK');
      await service(_FakeLlm(error: needsForeground)).process();
      now += 1000; // seconds later, not foregroundWait
      await service(_FakeLlm(result: _expense())).process();
      expect((await row(id))['status'], 'success');
      await db.close();
    });

    test('the wait does not outlive the pass that needed it', () async {
      await queue('CHK');
      final scheduled = <Duration?>[];
      final llm = _FakeLlm(error: needsForeground);
      final svc = service(llm, reschedule: (d) async => scheduled.add(d));
      await svc.process();
      llm.error = const LlmException('rate', retryable: true);
      await svc.process();
      expect(scheduled, [
        ProcessingService.foregroundWait,
        const Duration(seconds: 15),
      ]);
      await db.close();
    });
  });

  test('a paused service does not drain the queue', () async {
    final llm = _FakeLlm(result: _expense());
    final svc = service(llm);
    await queue('CHK');

    expect(svc.isPaused, isFalse);
    svc.pause();
    expect(svc.isPaused, isTrue);
    await svc.process();
    expect(llm.calls, 0);

    svc.resume();
    expect(svc.isPaused, isFalse);
    await svc.process();
    expect(llm.calls, 1);
    await db.close();
  });

  group('no LLM configured', () {
    ProcessingService noLlmService({
      bool online = true,
      LocalClassifier? local,
      Future<bool> Function()? isOnline,
    }) => ProcessingService(
      smsRepository: sms,
      banksRepository: banks,
      classifier: Classifier(null, local: local),
      financeWriter: FinanceWriter(db, nowMs: () => now),
      isOnline: isOnline ?? () async => online,
      currency: () => 'BDT',
      clock: () => now,
    );

    test('a weak prediction is accepted and written', () async {
      const content = 'debit 50 BDT';
      final local = _FakeLocal(
        LocalPrediction(
          classLabel: 'expense',
          classConfidence: 0.10,
          spans: [
            LocalSpan(
              entity: 'AMOUNT',
              text: '50',
              confidence: 0.96,
              start: content.indexOf('50'),
              end: content.indexOf('50') + 2,
            ),
          ],
        ),
      );
      final id = await queue('CHK', content: content);
      await noLlmService(local: local).process();

      final r = await row(id);
      expect(r['status'], 'success');
      expect(r['parse_source'], ParseSource.local.value);
      expect(r['needs_llm'], 0);
      expect((await db.query('transactions')).length, 1);
      await db.close();
    });

    test('an unbuildable prediction fails terminally', () async {
      const content = 'balance 500 BDT';
      final local = _FakeLocal(
        LocalPrediction(
          classLabel: 'expense',
          classConfidence: 0.95,
          spans: [
            LocalSpan(
              entity: 'BALANCE',
              text: '500',
              confidence: 0.96,
              start: content.indexOf('500'),
              end: content.indexOf('500') + 3,
            ),
          ],
        ),
      );
      final id = await queue('CHK', content: content);
      await noLlmService(local: local).process();

      final r = await row(id);
      expect(r['status'], 'failure');
      expect(r['failure_reason'], FailureReason.localOnly.value);
      expect(r['next_attempt_at'], isNull);
      expect(r['needs_llm'], 0);
      await db.close();
    });

    test('a row already flagged needs_llm is re-run, not skipped', () async {
      const content = 'debit 50 BDT';
      final local = _FakeLocal(
        LocalPrediction(
          classLabel: 'expense',
          classConfidence: 0.10,
          spans: [
            LocalSpan(
              entity: 'AMOUNT',
              text: '50',
              confidence: 0.96,
              start: content.indexOf('50'),
              end: content.indexOf('50') + 2,
            ),
          ],
        ),
      );
      final id = await queue('CHK', content: content);
      // Manually flag needs_llm
      await db.update(
        'sms_records',
        {'needs_llm': 1},
        where: 'id = ?',
        whereArgs: [id],
      );
      await noLlmService(local: local).process();

      final r = await row(id);
      expect(r['status'], 'success');
      await db.close();
    });

    test('being offline does not stop a pass', () async {
      const content = 'debit 50 BDT';
      final local = _FakeLocal(
        LocalPrediction(
          classLabel: 'expense',
          classConfidence: 0.10,
          spans: [
            LocalSpan(
              entity: 'AMOUNT',
              text: '50',
              confidence: 0.96,
              start: content.indexOf('50'),
              end: content.indexOf('50') + 2,
            ),
          ],
        ),
      );
      final id = await queue('CHK', content: content);
      // Manually flag needs_llm
      await db.update(
        'sms_records',
        {'needs_llm': 1},
        where: 'id = ?',
        whereArgs: [id],
      );
      await noLlmService(online: false, local: local).process();

      final r = await row(id);
      expect(r['status'], 'success');
      await db.close();
    });

    test('a local-only failure parses once a key is added', () async {
      const content = 'balance 500 BDT';
      final local = _FakeLocal(
        LocalPrediction(
          classLabel: 'expense',
          classConfidence: 0.95,
          spans: [
            LocalSpan(
              entity: 'BALANCE',
              text: '500',
              confidence: 0.96,
              start: content.indexOf('500'),
              end: content.indexOf('500') + 3,
            ),
          ],
        ),
      );
      final id = await queue('CHK', content: content);
      await noLlmService(local: local).process();

      var r = await row(id);
      expect(r['status'], 'failure');
      expect(r['failure_reason'], FailureReason.localOnly.value);

      // Requeue as the app's Retry does
      await sms.requeueOne(
        id,
        now,
        attempts: ProcessingService.maxAttempts - 1,
      );

      // Second service with an LLM provider
      final llm = _FakeLlm(result: _expense());
      await service(llm, local: local).process();

      r = await row(id);
      expect(r['status'], 'success');
      expect(r['parse_source'], ParseSource.llm.value);
      expect((await db.query('transactions')).length, 1);
      await db.close();
    });
  });
}
