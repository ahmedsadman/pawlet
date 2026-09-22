import 'package:flutter_test/flutter_test.dart';
import 'package:meowni/data/banks_repository.dart';
import 'package:meowni/data/sms_repository.dart';
import 'package:meowni/models/sms_record.dart';
import 'package:meowni/services/classification/classifier.dart';
import 'package:meowni/services/finance/finance_writer.dart';
import 'package:meowni/services/llm/llm_provider.dart';
import 'package:meowni/services/processing_service.dart';
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
    required List<String> bankNames,
    required String currency,
  }) async {
    calls++;
    if (error != null) throw error!;
    return result ?? const ClassifyResult.none();
  }
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
    // A bank whose alternate name "CHK" lets sender "CHK" pass Layer 1.
    await banks.create(name: 'Checking', alternateNames: 'CHK');
  });

  ProcessingService service(
    _FakeLlm llm, {
    bool online = true,
    Future<bool> Function()? isOnline,
    Future<void> Function(int failed, int retrying)? onCounts,
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

  Future<int> queue(String sender, {String content = 'debit 50', int attempts = 0}) async {
    final id = (await sms.insertIfNew(
      SmsRecord(sender: sender, content: content, timestamp: now, updatedAt: now),
    ))!;
    if (attempts != 0) {
      await sms.updateStatus(id, SmsStatus.queued, attempts: attempts, updatedAt: now);
    }
    return id;
  }

  test('processes a matching SMS into a transaction', () async {
    final id = await queue('CHK');
    final llm = _FakeLlm(
      result: const ClassifyResult(
        category: SmsCategory.transaction,
        transaction: MetadataResult(
          bank: 'Checking',
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

  test('gates out an unregistered sender with no LLM call', () async {
    final id = await queue('DARAZ', content: 'win a prize');
    final llm = _FakeLlm(result: const ClassifyResult.none());
    await service(llm).process();

    final r = await row(id);
    expect(r['status'], 'success');
    expect(r['category'], 'ignored');
    expect(llm.calls, 0);
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

  test('fails immediately on a fatal error', () async {
    final id = await queue('CHK');
    final llm = _FakeLlm(error: const LlmException('bad key', retryable: false));
    await service(llm).process();

    final r = await row(id);
    expect(r['status'], 'failure');
    expect(r['last_error'], 'bad key');
    await db.close();
  });

  test('exhausts maxAttempts into failure', () async {
    final id = await queue('CHK', attempts: ProcessingService.maxAttempts - 1);
    final llm = _FakeLlm(error: const LlmException('rate', retryable: true));
    await service(llm).process();

    final r = await row(id);
    expect(r['status'], 'failure');
    expect(r['attempts'], ProcessingService.maxAttempts);
    await db.close();
  });

  test('reports failed/retrying counts via onCounts', () async {
    await queue('CHK');
    int? failed;
    int? retrying;
    final llm = _FakeLlm(error: const LlmException('bad key', retryable: false));
    await service(
      llm,
      onCounts: (f, r) async {
        failed = f;
        retrying = r;
      },
    ).process();
    expect(failed, 1);
    expect(retrying, 0);
    await db.close();
  });

  test('releases the row unchanged if it goes offline mid-processing', () async {
    final id = await queue('CHK');
    // Online for process()+_processOne checks, offline by the reschedule check.
    var checks = 0;
    final llm = _FakeLlm(error: const LlmException('rate', retryable: true));
    await service(llm, isOnline: () async {
      checks++;
      return checks <= 2;
    }).process();

    final r = await row(id);
    expect(r['status'], 'queued');
    expect(r['attempts'], 0); // transport drop, not a real attempt
    expect(r['next_attempt_at'], isNull);
    await db.close();
  });

  test('schedules the next catch-up at the backoff time after a retry', () async {
    await queue('CHK');
    Duration? scheduled;
    var calls = 0;
    final llm = _FakeLlm(error: const LlmException('rate', retryable: true));
    await service(llm, reschedule: (d) async {
      scheduled = d;
      calls++;
    }).process();
    expect(calls, 1);
    expect(scheduled, const Duration(seconds: 15)); // baseBackoff
    await db.close();
  });

  test('cancels the catch-up when the queue drains', () async {
    await queue('CHK');
    var cancelled = false;
    final llm = _FakeLlm(result: const ClassifyResult.none());
    await service(llm, reschedule: (d) async => cancelled = d == null).process();
    expect(cancelled, isTrue);
    await db.close();
  });

  test('offline still schedules a catch-up for the due backlog', () async {
    await queue('CHK'); // due now
    Duration? scheduled;
    final llm = _FakeLlm(result: const ClassifyResult.none());
    await service(llm, online: false, reschedule: (d) async => scheduled = d)
        .process();
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
}
