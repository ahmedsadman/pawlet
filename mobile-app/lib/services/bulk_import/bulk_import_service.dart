import 'package:decimal/decimal.dart';

import '../../data/bank_catalog.dart';
import '../../data/banks_repository.dart';
import '../../data/sms_repository.dart';
import '../../models/finance/bank.dart';
import '../../models/sms_record.dart';
import '../classification/classifier.dart';
import '../classification/local_classifier.dart';
import '../classification/local_gate.dart';
import '../classification/sender_matcher.dart';
import '../finance/finance_matcher.dart';
import '../finance/finance_writer.dart';
import '../llm/llm_provider.dart';
import 'bulk_gate.dart';
import 'inbox_reader.dart';

/// Totals for the post-import summary.
class BulkImportResult {
  const BulkImportResult({
    required this.scanned,
    required this.saved,
    required this.cancelled,
  });

  /// Inbox messages walked — the denominator the user sees.
  final int scanned;

  /// Finance rows (transactions + bills) written by this run.
  final int saved;

  /// True when the user stopped the pass early, in which case [scanned] and
  /// [saved] cover only the part that ran.
  final bool cancelled;
}

/// One-shot back-fill of Pawlet from the device SMS inbox.
///
/// Deliberately bypasses the `sms_records` queue and its processing service:
/// this is a synchronous, user-visible pass that must finish while the progress
/// window is up, and it must never spend an LLM call on a backlog that can run
/// to thousands of messages. It therefore drives [LocalClassifier] and
/// [decideLocal] directly — there is no code path from here to the LLM — and
/// writes terminal rows itself via [SmsRepository.markBulkProcessed].
///
/// Re-running is safe and useful. Messages already stored are skipped unless a
/// previous pass left them `ignored` (which means no finance row exists for
/// them), so adding a credit card and importing again back-fills that card's
/// bills; `UNIQUE (message_id)` on `transactions`/`bills` is the backstop.
class BulkImportService {
  BulkImportService({
    required this.inbox,
    required this.smsRepository,
    required this.banksRepository,
    required this.local,
    required this.financeWriter,
    required this.financeMatcher,
    required this.currency,
    required this.usdRate,
    int Function()? clock,
  }) : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  final InboxReader inbox;
  final SmsRepository smsRepository;
  final BanksRepository banksRepository;
  final LocalClassifier local;
  final FinanceWriter financeWriter;
  final FinanceMatcher financeMatcher;
  final String Function() currency;
  final Future<Decimal?> Function() usdRate;
  final int Function() _clock;

  /// Messages between progress reports, and between yields to the event loop.
  /// A long run of gate-rejected messages never awaits anything, so without the
  /// yield the progress dialog would not repaint for whole seconds at a time.
  static const int reportEvery = 100;

  /// Walks the inbox oldest-first. [onProgress] fires every [reportEvery]
  /// messages and once at the end; [isCancelled] is polled between messages.
  Future<BulkImportResult> run({
    void Function(int done, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final messages = await inbox.readAll();
    // Oldest first. FinanceWriter only advances a deposit's stored balance for
    // a message newer than the one behind it, so replaying in receive order
    // lands on the real latest balance instead of whichever row came last.
    messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));

    final total = messages.length;
    // Mutable: an account created mid-pass has to be visible to the messages
    // that follow, otherwise the next message from that sender creates another.
    final banks = [...await banksRepository.list()];
    final cur = currency();
    final rate = await usdRate();

    var scanned = 0;
    var saved = 0;
    var cancelled = false;
    // Receive time of the first record written. Messages are walked oldest
    // first, so the first save is the oldest one.
    int? oldestSaved;

    for (final message in messages) {
      if (isCancelled?.call() ?? false) {
        cancelled = true;
        break;
      }
      if (await _importOne(message, banks, cur, rate)) {
        saved++;
        oldestSaved ??= message.timestamp;
      }
      scanned++;
      if (scanned % reportEvery == 0) {
        onProgress?.call(scanned, total);
        await Future<void>.delayed(Duration.zero);
      }
    }
    onProgress?.call(scanned, total);

    // Transfer pairing and bill linking are cross-row, so they run once over
    // everything the pass wrote rather than per message.
    //
    // The sweep has to be floored explicitly: its default look-back is 45 days
    // back from now, which would skip every historical row this pass just
    // wrote. Backing the floor off by the bill window lets a payment still
    // reach a statement that arrived up to 45 days before it.
    if (oldestSaved != null) {
      await financeMatcher.runPending(
        since: oldestSaved - FinanceMatcher.billWindow.inMilliseconds,
      );
    }
    if (scanned > 0) await smsRepository.bumpDataRevision();

    return BulkImportResult(
      scanned: scanned,
      saved: saved,
      cancelled: cancelled,
    );
  }

  /// Imports one inbox message. Returns true when a finance row was written.
  Future<bool> _importOne(
    InboxMessage message,
    List<Bank> banks,
    String cur,
    Decimal? rate,
  ) async {
    final sender = message.sender.trim();
    // Identical normalization to the live capture path, so a message the
    // listener already stored produces the same dedup key and is recognized.
    final content = message.content
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .trim();
    if (sender.isEmpty || content.isEmpty) return false;

    final gate = bulkGate(sender, content, banks);
    if (gate == null) return false;

    final now = _clock();
    var id = await smsRepository.insertIfNew(
      SmsRecord(
        sender: sender,
        content: content,
        timestamp: message.timestamp,
        updatedAt: now,
      ),
    );
    if (id == null) {
      // Already stored. Re-attempt only rows that hold no finance record;
      // success rows are done, and queued/sending/failure rows belong to the
      // live queue, which must stay the single writer for them.
      final existing = await smsRepository.findByIdentity(
        sender: sender,
        timestamp: message.timestamp,
        content: content,
      );
      if (existing?.id == null || existing!.status != SmsStatus.ignored) {
        return false;
      }
      id = existing.id!;
    }

    final prediction = await local.infer(content);
    final decision = prediction == null
        ? const LocalGateResult.reject()
        : decideLocal(
            prediction,
            currency: cur,
            content: content,
            usdToBdtRate: rate,
          );
    if (!decision.accepted) {
      // A rejection here would send the live pipeline to the LLM. This pass has
      // no LLM, so the message is dropped and the user is told so afterwards.
      await smsRepository.markBulkProcessed(
        id,
        status: SmsStatus.ignored,
        now: now,
        ignoreReason: IgnoreReason.localLowConfidence,
      );
      return false;
    }

    final result = decision.result!;
    if (result.category == SmsCategory.transaction) {
      await _ensureBank(gate.catalogEntry, sender, banks);
    }

    final label = await financeWriter.apply(
      record: SmsRecord(
        id: id,
        sender: sender,
        content: content,
        timestamp: message.timestamp,
        updatedAt: now,
      ),
      outcome: ClassificationOutcome(
        category: result.category,
        transaction: result.transaction,
        bill: result.bill,
        llmInvoked: false,
        parseSource: ParseSource.local,
      ),
      banks: banks,
      currency: cur,
    );

    if (label == 'ignored') {
      await smsRepository.markBulkProcessed(
        id,
        status: SmsStatus.ignored,
        now: now,
        ignoreReason: result.category == SmsCategory.none
            ? IgnoreReason.localNone
            : IgnoreReason.noRecord,
      );
      return false;
    }
    await smsRepository.markBulkProcessed(
      id,
      status: SmsStatus.success,
      now: now,
      category: label,
    );
    return true;
  }

  /// Creates the deposit account for a catalog-recognized sender, at most once.
  ///
  /// Credit cards are never auto-created: a card is identified only by digits
  /// in the message body, so inventing one would attach records to an account
  /// the user never confirmed. A card bill whose card is missing is therefore
  /// dropped, and the summary asks the user to add their cards.
  Future<void> _ensureBank(
    BankCatalogEntry? entry,
    String sender,
    List<Bank> banks,
  ) async {
    if (entry == null) return;
    if (singleSenderMatch(sender, banks) != null) return;
    // Guards the partial unique index on (name) WHERE account_type = 'deposit':
    // a same-named deposit whose matchers were edited away would collide.
    if (banks.any((b) => b.isDeposit && b.name == entry.label)) return;
    banks.add(
      await banksRepository.create(name: entry.label, matchers: entry.matchers),
    );
  }
}
