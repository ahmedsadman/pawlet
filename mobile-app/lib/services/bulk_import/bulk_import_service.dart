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

/// Marks a message as being about a card rather than a deposit account. Word
/// boundaries keep "Mastercard" and "scorecard" out.
final _cardWord = RegExp(r'\bcards?\b', caseSensitive: false);

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
/// to thousands of messages. It therefore drives [runLocalModel] directly —
/// there is no code path from here to the LLM — and writes terminal rows itself
/// via [SmsRepository.markBulkProcessed].
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
      try {
        if (await _importOne(message, banks, cur, rate)) {
          saved++;
          oldestSaved ??= message.timestamp;
        }
      } catch (_) {
        // One malformed message must not cost the rest of the inbox. The row
        // was inserted `ignored`, so the next run re-attempts exactly this one
        // while everything already imported stays put.
      }
      scanned++;
      if (scanned % reportEvery == 0) {
        onProgress?.call(scanned, total);
        await Future<void>.delayed(Duration.zero);
      }
    }
    onProgress?.call(scanned, total);

    // Accounts created during the walk did not exist for the messages that
    // preceded them, so catch those up before anything reads bank_id.
    await _relinkOrphans(banks);

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
    // Only a written record changes anything the UI shows: ignored rows appear
    // in neither History nor the Queue, so a pass that saved nothing has no
    // reason to wake every isolate's poller.
    if (saved > 0) await smsRepository.bumpDataRevision();

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
    // Look for an existing capture BEFORE inserting. The live listener records
    // the carrier's timestamp and the inbox gives Android's receipt time, so
    // the same SMS arrives here with a timestamp a second or so off the stored
    // one and an exact-key lookup never matches. See [kSmsDedupWindow].
    final existing = await smsRepository.findNearDuplicate(
      sender: sender,
      timestamp: message.timestamp,
      content: content,
    );

    final int id;
    // The timestamp the row actually carries, so finance rows written below
    // agree with the `sms_records` row they reference.
    final int timestamp;
    if (existing != null) {
      // Already stored. Success rows are done; queued/sending/failure rows
      // belong to the live queue, which must stay their single writer. What is
      // left — the ignored ones — is filtered by [_isReattemptable].
      if (existing.id == null || !_isReattemptable(existing)) return false;
      id = existing.id!;
      timestamp = existing.timestamp;
    } else {
      final inserted = await smsRepository.insertIfNew(
        SmsRecord(
          sender: sender,
          content: content,
          timestamp: message.timestamp,
          // Born terminal, NOT queued. `dueForDelivery` only selects `queued`,
          // so this row is invisible to every isolate for the whole inference
          // window that follows. A `queued` row would be claimable the moment
          // it lands: the background-SMS and WorkManager isolates build their
          // own ProcessingService and never see our pause(), and
          // `dueForDelivery` orders by timestamp ASC, which puts a
          // just-imported 2024 message at the FRONT of their next pass —
          // sending it to the LLM and breaking the on-device-only promise this
          // whole feature is sold on. It would also outlive a crash: an
          // abandoned `queued` row is LLM'd forever after. `ignored` with no
          // reason is the correct resting state for a half-imported row — the
          // next run re-attempts exactly those.
          status: SmsStatus.ignored,
          updatedAt: now,
        ),
      );
      // Null means a row with this exact (sender, timestamp, content) landed
      // between the lookup above and here. The window lookup already caught
      // the live listener's copy, which carries a different clock's timestamp,
      // so this is the narrower case of an identical key — a concurrent pass,
      // or the same message twice in the inbox. Either way it is not ours.
      if (inserted == null) return false;
      id = inserted;
      timestamp = message.timestamp;
    }

    final decision = await runLocalModel(
      content,
      local: local,
      currency: cur,
      usdRate: rate,
    );
    if (!decision.accepted) {
      // A rejection here would send the live pipeline to the LLM. This pass has
      // no LLM, so the message is dropped and the user is told so afterwards.
      //
      // Both reasons re-attempt on the next run, so the distinction buys no
      // behaviour — it buys a diagnosis. A model that fails to load ignores the
      // entire inbox, and tagging that as "low confidence" would blame the
      // model's judgement for a message it never read.
      await smsRepository.markBulkProcessed(
        id,
        status: SmsStatus.ignored,
        now: now,
        ignoreReason: decision.declined
            ? IgnoreReason.localLowConfidence
            : IgnoreReason.localUnavailable,
      );
      return false;
    }

    final result = decision.result!;
    if (result.category == SmsCategory.transaction) {
      await _ensureBank(gate.catalogEntry, content, banks);
    }

    final label = await financeWriter.apply(
      record: SmsRecord(
        id: id,
        sender: sender,
        content: content,
        timestamp: timestamp,
        updatedAt: now,
      ),
      outcome: ClassificationOutcome(
        category: result.category,
        transaction: result.transaction,
        bill: result.bill,
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

  /// Attaches transactions that were written with no bank to an account that
  /// exists now, using the writer's own resolution order.
  ///
  /// Two things leave rows orphaned. An account is created partway through an
  /// oldest-first walk, so every earlier message from that sender was written
  /// before it existed; and a card added *after* an import can never claim its
  /// rows, because those messages are `success` and so are never re-processed.
  /// Both are repaired here rather than by re-running the model.
  ///
  /// Balances are deliberately not recomputed: the extracted figure is not kept
  /// on the transaction row, so there is nothing to replay. A deposit linked up
  /// this way carries whatever balance later messages give it.
  Future<void> _relinkOrphans(List<Bank> banks) async {
    if (banks.isEmpty) return;
    final orphans = await smsRepository.unlinkedTransactions();
    for (final orphan in orphans) {
      final bank = resolveTransactionBank(orphan.sender, orphan.content, banks);
      if (bank == null) continue;
      await smsRepository.setTransactionBank(orphan.transactionId, bank.id);
    }
  }

  /// Whether an already-stored row is worth running through the model again.
  ///
  /// Stated as an exclusion so the safe default for any reason added later is
  /// "retry": the cost of retrying needlessly is inference, the cost of wrongly
  /// skipping is a financial record the user never gets. Only the two verdicts
  /// that mean *a model already read this and said it isn't financial* are
  /// skipped — same model plus same text gives the same answer, and `llmNone`
  /// came from a stronger model than this pass has.
  ///
  /// Everything else can genuinely flip:
  /// - `gated`: the live gate rejected it for want of a matching bank, and the
  ///   bulk gate is strictly wider (it knows the catalog). On an install with
  ///   no banks this is *every* message the pipeline has seen.
  /// - `noRecord`: the card may exist now.
  /// - `localLowConfidence`: `decideLocal` rejects a USD amount when no
  ///   exchange rate is available, which is simply the offline case.
  /// - `localUnavailable`: the model never ran, so there is no verdict at all.
  /// - null: an earlier pass was interrupted before it recorded a verdict.
  static bool _isReattemptable(SmsRecord record) =>
      record.status == SmsStatus.ignored &&
      record.ignoreReason != IgnoreReason.localNone &&
      record.ignoreReason != IgnoreReason.llmNone;

  /// Creates the deposit account for a catalog-recognized sender, at most once.
  ///
  /// Credit cards are never auto-created: a card is identified only by digits
  /// in the message body, so inventing one would attach records to an account
  /// the user never confirmed. A card bill whose card is missing is therefore
  /// dropped, and the offer and summary both ask the user to add their cards.
  ///
  /// A body mentioning a card blocks creation. A card purchase SMS from, say,
  /// "City Bank" matches the catalog exactly like a deposit alert does, and
  /// creating a *deposit* for it would be worse than creating nothing:
  /// `FinanceWriter`'s sender fallback would weld every card spend to a
  /// phantom account, and a BALANCE span would record the card's available
  /// limit as a cash balance. Neither undoes itself once the real card exists.
  ///
  /// The word is the discriminator rather than the presence of a masked number:
  /// local deposit alerts print the account masked in exactly the card's shape
  /// ("AC 123***456 is credited..."), so keying on masking blocks almost every
  /// genuine deposit. Checked against this user's inbox, the word separates all
  /// seven real senders correctly.
  Future<void> _ensureBank(
    BankCatalogEntry? entry,
    String content,
    List<Bank> banks,
  ) async {
    if (entry == null) return;
    if (_cardWord.hasMatch(content)) return;
    // Guards the partial unique index on (name) WHERE account_type = 'deposit':
    // a same-named deposit whose matchers were edited away would collide.
    if (banks.any((b) => b.isDeposit && b.name == entry.label)) return;
    banks.add(
      await banksRepository.create(name: entry.label, matchers: entry.matchers),
    );
  }
}
