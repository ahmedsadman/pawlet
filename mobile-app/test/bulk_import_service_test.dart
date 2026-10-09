import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/data/banks_repository.dart';
import 'package:pawlet/data/sms_repository.dart';
import 'package:pawlet/models/sms_record.dart';
import 'package:pawlet/services/bulk_import/bulk_import_service.dart';
import 'package:pawlet/services/bulk_import/inbox_reader.dart';
import 'package:pawlet/services/classification/local_classifier.dart';
import 'package:pawlet/services/classification/local_model.dart';
import 'package:pawlet/services/finance/finance_matcher.dart';
import 'package:pawlet/services/finance/finance_writer.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/db_test_helpers.dart';

/// Returns a canned inbox, recording how many times it was read.
class _FakeInbox implements InboxReader {
  _FakeInbox(this.messages);
  final List<InboxMessage> messages;
  int reads = 0;

  @override
  Future<List<InboxMessage>> readAll() async {
    reads++;
    return List.of(messages);
  }
}

/// Canned predictions keyed by message body; an absent key means "the model had
/// nothing for this message" (null), i.e. the model-unavailable state.
class _FakeLocal implements LocalClassifier {
  _FakeLocal(this.byContent);
  final Map<String, LocalPrediction> byContent;
  final List<String> calls = [];

  @override
  Future<LocalPrediction?> infer(String content) async {
    calls.add(content);
    return byContent[content];
  }
}

/// Blows up on every message, standing in for a platform/model failure midway
/// through a pass.
class _ThrowingLocal implements LocalClassifier {
  @override
  Future<LocalPrediction?> infer(String content) async =>
      throw StateError('model exploded');
}

/// A confident single-span prediction whose span points at [value] inside
/// [content], mirroring what the real model emits.
LocalPrediction _pred(
  String label,
  String entity,
  String content,
  String value,
) {
  final start = content.indexOf(value);
  return LocalPrediction(
    classLabel: label,
    classConfidence: 0.99,
    spans: [
      LocalSpan(
        entity: entity,
        text: value,
        confidence: 0.99,
        start: start,
        end: start + value.length,
      ),
    ],
  );
}

InboxMessage _msg(String sender, String content, int ts) =>
    InboxMessage(sender: sender, content: content, timestamp: ts);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  late SmsRepository sms;
  late BanksRepository banks;

  /// A realistic "today". It has to be realistic: FinanceMatcher's default
  /// look-back is measured back from here, and an epoch-zero clock would make
  /// every row look recent, hiding the very bug the historical test checks.
  final now = DateTime(2026, 9, 30).millisecondsSinceEpoch;

  setUp(() async {
    db = await openTestDb();
    sms = SmsRepository(db);
    banks = BanksRepository(db, nowMs: () => now);
  });

  tearDown(() => db.close());

  BulkImportService service(_FakeInbox inbox, LocalClassifier local) =>
      BulkImportService(
        inbox: inbox,
        smsRepository: sms,
        banksRepository: banks,
        local: local,
        financeWriter: FinanceWriter(db, nowMs: () => now),
        financeMatcher: FinanceMatcher(db, nowMs: () => now),
        currency: () => 'BDT',
        usdRate: () async => null,
        clock: () => now,
      );

  Future<int> count(String table) async =>
      (await db.rawQuery('SELECT COUNT(*) AS c FROM $table')).first['c'] as int;

  const expenseBody = 'Purchase of 1250.00 at a shop';
  const billBody = 'Statement total due 5000.00 for card 4238****3241';

  test('creates the bank from the catalog and saves the transaction', () async {
    final inbox = _FakeInbox([_msg('EBL', expenseBody, 1000)]);
    final local = _FakeLocal({
      expenseBody: _pred('expense', 'AMOUNT', expenseBody, '1250.00'),
    });

    final result = await service(inbox, local).run();

    expect(result.scanned, 1);
    expect(result.saved, 1);
    expect(result.cancelled, isFalse);

    final created = await banks.list();
    expect(created.single.name, 'EBL');
    expect(created.single.accountType, 'deposit');
    expect(created.single.matchers, ['ebl', 'eastern bank limited']);

    final tx = (await db.query('transactions')).single;
    expect(tx['normalized_amount'], '1250.00');
    expect(tx['type'], 'expense');
    expect(tx['bank_id'], created.single.id);

    final row = (await db.query('sms_records')).single;
    expect(row['status'], 'success');
    expect(row['category'], 'transaction');
    expect(row['parse_source'], 'local');
  });

  test('drops unknown senders without touching the database', () async {
    final inbox = _FakeInbox([_msg('16247', 'Your OTP is 4321', 1000)]);
    final local = _FakeLocal(const {});

    final result = await service(inbox, local).run();

    expect(result.scanned, 1);
    expect(result.saved, 0);
    expect(await count('sms_records'), 0);
    // The model is the expensive part — it must never see a gate reject.
    expect(local.calls, isEmpty);
  });

  test('is idempotent: a second run adds no rows', () async {
    final inbox = _FakeInbox([_msg('EBL', expenseBody, 1000)]);
    final local = _FakeLocal({
      expenseBody: _pred('expense', 'AMOUNT', expenseBody, '1250.00'),
    });

    await service(inbox, local).run();
    final second = await service(inbox, local).run();

    expect(second.saved, 0);
    expect(await count('transactions'), 1);
    expect(await count('banks'), 1);
    expect(await count('sms_records'), 1);
  });

  test('leaves a message the live queue still owns alone', () async {
    // Captured by the listener and awaiting its LLM call: the import must not
    // race the queue for it.
    final id = (await sms.insertIfNew(
      SmsRecord(
        sender: 'EBL',
        content: expenseBody,
        timestamp: 1000,
        updatedAt: 1000,
      ),
    ))!;

    final inbox = _FakeInbox([_msg('EBL', expenseBody, 1000)]);
    final local = _FakeLocal({
      expenseBody: _pred('expense', 'AMOUNT', expenseBody, '1250.00'),
    });

    final result = await service(inbox, local).run();

    expect(result.saved, 0);
    expect(local.calls, isEmpty);
    expect(await count('transactions'), 0);
    expect(
      (await db.query(
        'sms_records',
        where: 'id = ?',
        whereArgs: [id],
      )).first['status'],
      'queued',
    );
  });

  test('a message the model is unsure about is ignored, not queued', () async {
    const body = 'Your EBL balance may have changed';
    final inbox = _FakeInbox([_msg('EBL', body, 1000)]);
    final local = _FakeLocal({
      body: const LocalPrediction(
        classLabel: 'expense',
        classConfidence: 0.42,
        spans: [],
      ),
    });

    final result = await service(inbox, local).run();

    expect(result.saved, 0);
    final row = (await db.query('sms_records')).single;
    expect(row['status'], 'ignored');
    expect(row['ignore_reason'], 'local_low_confidence');
    // Nothing is left for the LLM queue to pick up.
    expect(row['next_attempt_at'], isNull);
    expect(await count('transactions'), 0);
    // A bill/transaction was never written, so no account was invented either.
    expect(await count('banks'), 0);
  });

  test('a message the model never read is tagged as such', () async {
    // Separated from local_low_confidence so a model that failed to load —
    // which ignores the whole inbox — is diagnosable after the fact instead of
    // looking like thousands of individually hard messages.
    const body = 'Your EBL balance may have changed';
    final inbox = _FakeInbox([_msg('EBL', body, 1000)]);
    final local = _FakeLocal(const {}); // infers null for everything

    final result = await service(inbox, local).run();

    expect(result.saved, 0);
    final row = (await db.query('sms_records')).single;
    expect(row['status'], 'ignored');
    expect(row['ignore_reason'], 'local_unavailable');
    expect(row['next_attempt_at'], isNull);
  });

  test('never leaves a row the LLM queue could claim', () async {
    // The whole on-device promise rests on this: a row visible to
    // dueForDelivery (status 'queued') can be claimed by the background-SMS or
    // WorkManager isolate, which build their own ProcessingService and never
    // see pause() — and would then post the message body to OpenRouter.
    final inbox = _FakeInbox([
      _msg('EBL', expenseBody, 1000),
      _msg('EBL', 'Your EBL balance may have changed', 2000),
    ]);
    final local = _FakeLocal({
      expenseBody: _pred('expense', 'AMOUNT', expenseBody, '1250.00'),
    });

    await service(inbox, local).run();

    expect(await sms.dueForDelivery(now), isEmpty);
    expect(await sms.countQueued(), 0);
  });

  test('an interrupted row is left re-attemptable, not queued', () async {
    // The model throws partway, so the row never reaches markBulkProcessed.
    final inbox = _FakeInbox([_msg('EBL', expenseBody, 1000)]);
    final local = _ThrowingLocal();

    final result = await service(inbox, local).run();

    // The pass survived the throw and still reported honestly.
    expect(result.scanned, 1);
    expect(result.saved, 0);

    final row = (await db.query('sms_records')).single;
    expect(row['status'], 'ignored');
    expect(row['ignore_reason'], isNull);
    expect(await sms.dueForDelivery(now), isEmpty);

    // A later run picks exactly that row back up.
    final retryLocal = _FakeLocal({
      expenseBody: _pred('expense', 'AMOUNT', expenseBody, '1250.00'),
    });
    final second = await service(inbox, retryLocal).run();
    expect(second.saved, 1);
    expect(await count('transactions'), 1);
  });

  test('picks up messages the live pipeline gated out', () async {
    // Before any bank exists the live gate rejects everything as `gated`. The
    // bulk gate knows the catalog, so those are exactly the rows an import is
    // for — skipping them would make Settings → Data a no-op on a fresh
    // install, which is the main way this feature gets used.
    final id = (await sms.insertIfNew(
      SmsRecord(
        sender: 'EBL',
        content: expenseBody,
        timestamp: 1000,
        updatedAt: 1000,
      ),
    ))!;
    await sms.updateStatus(
      id,
      SmsStatus.ignored,
      updatedAt: 1000,
      ignoreReason: IgnoreReason.gated,
    );

    final inbox = _FakeInbox([_msg('EBL', expenseBody, 1000)]);
    final local = _FakeLocal({
      expenseBody: _pred('expense', 'AMOUNT', expenseBody, '1250.00'),
    });

    final result = await service(inbox, local).run();

    expect(result.saved, 1);
    expect(await count('transactions'), 1);
  });

  test('does not re-infer what a model already called non-financial', () async {
    const body = 'EBL wishes you a happy new year';
    final inbox = _FakeInbox([_msg('EBL', body, 1000)]);
    final local = _FakeLocal({
      body: const LocalPrediction(
        classLabel: 'null',
        classConfidence: 0.98,
        spans: [],
      ),
    });

    await service(inbox, local).run();
    expect(local.calls, [body]);

    // Same model, same text, a confident verdict — nothing to gain.
    await service(inbox, local).run();
    expect(local.calls, [body]);
  });

  test('a confident non-financial message is ignored as such', () async {
    const body = 'EBL wishes you a happy new year';
    final inbox = _FakeInbox([_msg('EBL', body, 1000)]);
    final local = _FakeLocal({
      body: const LocalPrediction(
        classLabel: 'null',
        classConfidence: 0.98,
        spans: [],
      ),
    });

    await service(inbox, local).run();

    expect(
      (await db.query('sms_records')).single['ignore_reason'],
      'local_none',
    );
    expect(await count('banks'), 0);
  });

  test(
    'a card bill with no matching card creates neither bill nor card',
    () async {
      final inbox = _FakeInbox([_msg('City Bank', billBody, 1000)]);
      final local = _FakeLocal({
        billBody: _pred('bill', 'DUE', billBody, '5000.00'),
      });

      final result = await service(inbox, local).run();

      expect(result.saved, 0);
      expect(await count('bills'), 0);
      expect(await count('banks'), 0);
      expect(
        (await db.query('sms_records')).single['ignore_reason'],
        'no_record',
      );
    },
  );

  test('re-running after the card is added back-fills the bill once', () async {
    final inbox = _FakeInbox([_msg('City Bank', billBody, 1000)]);
    final local = _FakeLocal({
      billBody: _pred('bill', 'DUE', billBody, '5000.00'),
    });

    await service(inbox, local).run();
    expect(await count('bills'), 0);

    await banks.create(
      name: 'City Bank',
      accountType: 'credit',
      cardDigits: '4238|3241',
    );

    final second = await service(inbox, local).run();
    expect(second.saved, 1);
    expect(await count('bills'), 1);
    expect((await db.query('sms_records')).single['status'], 'success');

    // And a third run must not duplicate it.
    await service(inbox, local).run();
    expect(await count('bills'), 1);
  });

  test('stopping early keeps what already landed', () async {
    const second = 'Purchase of 99.00 at a cafe';
    final inbox = _FakeInbox([
      _msg('EBL', expenseBody, 1000),
      _msg('EBL', second, 2000),
    ]);
    final local = _FakeLocal({
      expenseBody: _pred('expense', 'AMOUNT', expenseBody, '1250.00'),
      second: _pred('expense', 'AMOUNT', second, '99.00'),
    });

    var seen = 0;
    final result = await service(inbox, local).run(
      // Cancels after the first message has been handed back.
      isCancelled: () => seen++ > 0,
    );

    expect(result.cancelled, isTrue);
    expect(result.scanned, 1);
    expect(result.saved, 1);
    expect(await count('transactions'), 1);
  });

  test('never invents a deposit account from a card message', () async {
    // "City Bank" matches the catalog exactly as a deposit alert would, but
    // this is a card purchase. Creating a deposit here would both fabricate an
    // account and weld the card spend to it, and neither unwinds when the user
    // later adds the real card.
    const cardBody = 'Your card 4238****3241 was used for 1250.00 at a shop';
    final inbox = _FakeInbox([_msg('City Bank', cardBody, 1000)]);
    final local = _FakeLocal({
      cardBody: _pred('expense', 'AMOUNT', cardBody, '1250.00'),
    });

    final result = await service(inbox, local).run();

    expect(await count('banks'), 0);
    // The spend is still captured, just unattributed.
    expect(result.saved, 1);
    expect((await db.query('transactions')).single['bank_id'], isNull);
  });

  test('creates the deposit from a masked account alert', () async {
    // The local deposit format masks the account number in exactly a card's
    // shape. Treating masking as "this is a card" blocked essentially every
    // real deposit, so only the word "card" may block creation.
    const acBody = 'AC 123***456 is credited with BDT 1250.00. Balance 9000.00';
    final inbox = _FakeInbox([_msg('EBL', acBody, 1000)]);
    final local = _FakeLocal({
      acBody: LocalPrediction(
        classLabel: 'income',
        classConfidence: 0.99,
        spans: [
          LocalSpan(
            entity: 'AMOUNT',
            text: '1250.00',
            confidence: 0.99,
            start: acBody.indexOf('1250.00'),
            end: acBody.indexOf('1250.00') + 7,
          ),
          LocalSpan(
            entity: 'BALANCE',
            text: '9000.00',
            confidence: 0.99,
            start: acBody.indexOf('9000.00'),
            end: acBody.indexOf('9000.00') + 7,
          ),
        ],
      ),
    });

    final result = await service(inbox, local).run();

    expect(result.saved, 1);
    final bank = (await banks.list()).single;
    expect(bank.name, 'EBL');
    expect(bank.accountType, 'deposit');
    // Linked, and the balance actually landed.
    expect((await db.query('transactions')).single['bank_id'], bank.id);
    expect(bank.lastBalance, '9000.00');
  });

  test('relinks rows written before their account existed', () async {
    // Oldest-first: the card message arrives before the deposit alert that
    // creates the account, so it is written unlinked. Once "EBL" exists the
    // closing relink must claim it.
    const cardBody = 'EBL card purchase of 300.00 at a shop';
    const acBody = 'AC 123***456 is credited with BDT 1250.00';
    final inbox = _FakeInbox([
      _msg('EBL', cardBody, 1000),
      _msg('EBL', acBody, 2000),
    ]);
    final local = _FakeLocal({
      cardBody: _pred('expense', 'AMOUNT', cardBody, '300.00'),
      acBody: _pred('income', 'AMOUNT', acBody, '1250.00'),
    });

    final result = await service(inbox, local).run();

    expect(result.saved, 2);
    final bank = (await banks.list()).single;
    final linked = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM transactions WHERE bank_id = ?',
      [bank.id],
    );
    expect(linked.first['c'], 2);
  });

  test('relinks a card transaction once the card is added', () async {
    // The user imports, then adds the card, then re-runs. The card's rows are
    // already `success` so they are never re-processed — only the relink can
    // rescue them.
    const cardBody = 'Your card 4238****3241 was charged 300.00';
    final inbox = _FakeInbox([_msg('City Bank', cardBody, 1000)]);
    final local = _FakeLocal({
      cardBody: _pred('expense', 'AMOUNT', cardBody, '300.00'),
    });

    await service(inbox, local).run();
    expect((await db.query('transactions')).single['bank_id'], isNull);

    final card = await banks.create(
      name: 'City Bank',
      accountType: 'credit',
      cardDigits: '4238|3241',
    );
    await service(inbox, local).run();

    expect((await db.query('transactions')).single['bank_id'], card.id);
  });

  test('leaves an orphan alone when no account fits', () async {
    const cardBody = 'Your card 4238****3241 was charged 300.00';
    final inbox = _FakeInbox([_msg('City Bank', cardBody, 1000)]);
    final local = _FakeLocal({
      cardBody: _pred('expense', 'AMOUNT', cardBody, '300.00'),
    });
    // An unrelated account exists, so the relink runs but must not grab this.
    await banks.create(name: 'MTB', matchers: const ['mtb']);

    await service(inbox, local).run();

    expect((await db.query('transactions')).single['bank_id'], isNull);
  });

  test('two senders of the same catalog bank share one account', () async {
    const second = 'Purchase of 99.00 at a cafe';
    final inbox = _FakeInbox([
      _msg('EBL', expenseBody, 1000),
      _msg('EBL-ALERT', second, 2000),
    ]);
    final local = _FakeLocal({
      expenseBody: _pred('expense', 'AMOUNT', expenseBody, '1250.00'),
      second: _pred('expense', 'AMOUNT', second, '99.00'),
    });

    final result = await service(inbox, local).run();

    expect(result.saved, 2);
    expect(await count('banks'), 1);
  });

  test('links a years-old bill to its payment', () async {
    await banks.create(
      name: 'City Bank',
      accountType: 'credit',
      cardDigits: '4238|3241',
    );
    // Two and a half years before `now` — far outside FinanceMatcher's default
    // look-back, so this only passes if the import floors the sweep itself.
    final billAt = DateTime(2024, 3, 1).millisecondsSinceEpoch;
    final paidAt = DateTime(2024, 3, 11).millisecondsSinceEpoch;
    const payBody = 'Payment of 5000.00 received for card 4238****3241';

    final inbox = _FakeInbox([
      _msg('City Bank', billBody, billAt),
      _msg('City Bank', payBody, paidAt),
    ]);
    final local = _FakeLocal({
      billBody: _pred('bill', 'DUE', billBody, '5000.00'),
      payBody: _pred('transfer', 'AMOUNT', payBody, '5000.00'),
    });

    final result = await service(inbox, local).run();

    expect(result.saved, 2);
    final bill = (await db.query('bills')).single;
    expect(bill['paid_at'], paidAt);
    expect((await db.query('transactions')).single['bill_id'], bill['id']);
  });

  test('replays oldest-first so the newest balance wins', () async {
    const older = 'Debit 100.00 leaves balance 900.00';
    const newer = 'Debit 100.00 leaves balance 800.00';
    // Handed over newest-first to prove the service sorts rather than trusting
    // the reader's order.
    final inbox = _FakeInbox([
      _msg('EBL', newer, 2000),
      _msg('EBL', older, 1000),
    ]);
    final local = _FakeLocal({
      older: LocalPrediction(
        classLabel: 'expense',
        classConfidence: 0.99,
        spans: [
          LocalSpan(
            entity: 'AMOUNT',
            text: '100.00',
            confidence: 0.99,
            start: older.indexOf('100.00'),
            end: older.indexOf('100.00') + 6,
          ),
          LocalSpan(
            entity: 'BALANCE',
            text: '900.00',
            confidence: 0.99,
            start: older.indexOf('900.00'),
            end: older.indexOf('900.00') + 6,
          ),
        ],
      ),
      newer: LocalPrediction(
        classLabel: 'expense',
        classConfidence: 0.99,
        spans: [
          LocalSpan(
            entity: 'AMOUNT',
            text: '100.00',
            confidence: 0.99,
            start: newer.indexOf('100.00'),
            end: newer.indexOf('100.00') + 6,
          ),
          LocalSpan(
            entity: 'BALANCE',
            text: '800.00',
            confidence: 0.99,
            start: newer.indexOf('800.00'),
            end: newer.indexOf('800.00') + 6,
          ),
        ],
      ),
    });

    await service(inbox, local).run();

    final bank = (await banks.list()).single;
    expect(bank.lastBalance, '800.00');
  });

  test('reads the inbox once per run', () async {
    final inbox = _FakeInbox([_msg('EBL', expenseBody, 1000)]);
    final local = _FakeLocal({
      expenseBody: _pred('expense', 'AMOUNT', expenseBody, '1250.00'),
    });

    await service(inbox, local).run();

    expect(inbox.reads, 1);
  });

  test('reports progress and finishes on the true total', () async {
    final inbox = _FakeInbox([
      _msg('EBL', expenseBody, 1000),
      _msg('16247', 'Your OTP is 4321', 2000),
    ]);
    final local = _FakeLocal({
      expenseBody: _pred('expense', 'AMOUNT', expenseBody, '1250.00'),
    });

    final seen = <String>[];
    await service(
      inbox,
      local,
    ).run(onProgress: (done, total) => seen.add('$done/$total'));

    // Fewer messages than the report interval, so only the final call lands.
    expect(seen, ['2/2']);
  });

  test('an empty inbox is a clean no-op', () async {
    final result = await service(_FakeInbox([]), _FakeLocal(const {})).run();

    expect(result.scanned, 0);
    expect(result.saved, 0);
    expect(result.cancelled, isFalse);
    expect(await count('sms_records'), 0);
  });

  test('skips blank senders and bodies', () async {
    final inbox = _FakeInbox([
      _msg('', expenseBody, 1000),
      _msg('EBL', '   ', 2000),
    ]);
    final local = _FakeLocal(const {});

    final result = await service(inbox, local).run();

    expect(result.saved, 0);
    expect(await count('sms_records'), 0);
    expect(local.calls, isEmpty);
  });

  test(
    'normalizes CRLF so a listener-captured message is recognized',
    () async {
      const stored = 'Purchase of 1250.00\nat a shop';
      final id = (await sms.insertIfNew(
        SmsRecord(
          sender: 'EBL',
          content: stored,
          timestamp: 1000,
          updatedAt: 1000,
        ),
      ))!;
      // Mark it done, as the live pipeline would have.
      await sms.markBulkProcessed(
        id,
        status: SmsStatus.success,
        now: 1000,
        category: 'transaction',
      );

      // The inbox hands back the same message with CRLF line endings.
      final inbox = _FakeInbox([
        _msg('EBL', 'Purchase of 1250.00\r\nat a shop', 1000),
      ]);
      final local = _FakeLocal(const {});

      final result = await service(inbox, local).run();

      expect(result.saved, 0);
      // Recognized as the same message rather than inserted a second time.
      expect(await count('sms_records'), 1);
      expect(local.calls, isEmpty);
    },
  );

  test('skips a message the live listener already captured', () async {
    // The exact scenario that produced 153 duplicates on a real device: the
    // live path stored the carrier's whole-second stamp, the inbox reports
    // Android's receipt time 876ms later.
    const carrierTs = 1782209211000;
    const inboxTs = 1782209211876;

    await sms.insertIfNew(
      SmsRecord(
        sender: 'EBL',
        content: expenseBody,
        timestamp: carrierTs,
        status: SmsStatus.success,
        category: 'transaction',
        parseSource: ParseSource.llm,
        updatedAt: carrierTs,
      ),
    );

    final inbox = _FakeInbox([_msg('EBL', expenseBody, inboxTs)]);
    final local = _FakeLocal({
      expenseBody: _pred('expense', 'AMOUNT', expenseBody, '1250.00'),
    });

    final result = await service(inbox, local).run();

    expect(result.scanned, 1);
    expect(result.saved, 0);
    expect(await count('sms_records'), 1);
    expect(await count('transactions'), 0);
    // The on-device model must not even run for a message already handled.
    expect(local.calls, isEmpty);
  });

  test('still imports a distinct message from the same sender', () async {
    // Guards against the window being so wide it swallows real messages.
    const other = 'Purchase of 99.00 at another shop';
    await sms.insertIfNew(
      SmsRecord(
        sender: 'EBL',
        content: expenseBody,
        timestamp: 1782209211000,
        status: SmsStatus.success,
        updatedAt: 1782209211000,
      ),
    );

    final inbox = _FakeInbox([_msg('EBL', other, 1782209211876)]);
    final local = _FakeLocal({
      other: _pred('expense', 'AMOUNT', other, '99.00'),
    });

    final result = await service(inbox, local).run();

    expect(result.saved, 1);
    expect(await count('sms_records'), 2);
  });

  test('the inbox import never counts toward the model stats', () async {
    final inbox = _FakeInbox([_msg('EBL', expenseBody, 1000)]);
    final local = _FakeLocal({
      expenseBody: _pred('expense', 'AMOUNT', expenseBody, '1250.00'),
    });

    final result = await service(inbox, local).run();

    expect(result.saved, 1); // the model did run and accept it
    expect(await count('model_stats'), 0);
    final row = (await db.query('sms_records')).single;
    expect(row['local_verdict'], isNull);
  });
}
