import 'dart:math';

import 'package:decimal/decimal.dart';

import '../data/banks_repository.dart';
import '../data/sms_repository.dart';
import '../models/finance/bank.dart';
import '../models/sms_record.dart';
import 'classification/classifier.dart';
import 'classification/sender_matcher.dart';
import 'finance/finance_writer.dart';
import 'llm/llm_provider.dart';

Future<Decimal?> _noRate() async => null;

/// Drains the SMS queue, resolving each due record through three layers and
/// writing the finance record for whichever one decides it:
/// 1. the Layer-1 sender/card gate — a miss is terminal `ignored`;
/// 2. the on-device model — a confident verdict is terminal;
/// 3. the cloud LLM, for anything the first two could not settle — when one is
///    configured. With no LLM the on-device model runs ungated instead, and
///    anything it cannot build becomes a terminal `failure`.
///
/// The first two touch no network, so the pass runs offline and still drains
/// everything they can decide. A record that reaches the third layer while
/// offline, or while another isolate holds the single global LLM slot, is left
/// `queued` and still due — unchanged apart from the `needs_llm` flag, which is
/// set only when the model actually ran and declined, and tells later passes to
/// skip an inference whose answer is already known.
///
/// Failures are rescheduled with a capped-exponential backoff persisted in
/// `next_attempt_at`; the existing triggers (foreground resume, incoming-SMS
/// isolate, WorkManager tick) drive later retries.
class ProcessingService {
  ProcessingService({
    required this.smsRepository,
    required this.banksRepository,
    required this.classifier,
    required this.financeWriter,
    required this.isOnline,
    required this.currency,
    this.usdBdtRate = _noRate,
    int Function()? clock,
    this.onCounts,
    this.afterPass,
    this.reschedule,
  }) : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  final SmsRepository smsRepository;
  final BanksRepository banksRepository;
  final Classifier classifier;
  final FinanceWriter financeWriter;
  final Future<bool> Function() isOnline;
  final String Function() currency;

  /// Supplies the current USD→BDT rate (cached; null when unavailable). Called
  /// once per pass and threaded into classification so a confident USD message
  /// is converted on-device instead of falling back to the LLM.
  final Future<Decimal?> Function() usdBdtRate;

  final int Function() _clock;

  /// Optional hook fired after a pass with the current failed count
  /// (used to reconcile notifications).
  final Future<void> Function(int failed)? onCounts;

  /// Optional hook run after the queue is drained (used to run the deferred
  /// transfer / bill-payment matchers).
  final Future<void> Function()? afterPass;

  /// Optional hook to (re)schedule the next background catch-up. Called after
  /// every pass with the delay until the soonest pending retry, or null when
  /// nothing is queued (so the background job can be cancelled — no idle wakes).
  final Future<void> Function(Duration? delay)? reschedule;

  /// Max attempts before a record is marked failed.
  static const int maxAttempts = 10;

  /// First retry delay; each subsequent retry multiplies by 4 up to [maxBackoff].
  static const Duration baseBackoff = Duration(seconds: 15);

  /// Ceiling for a single backoff step (~23.7h total across [maxAttempts]).
  static const Duration maxBackoff = Duration(hours: 6);

  /// Ceiling for a server-supplied retry hint (Retry-After / X-RateLimit-Reset).
  /// Independent of [maxBackoff]: a legitimate daily-cap reset can be ~24h out,
  /// so hints get a wider cap — which also bounds clock skew or a ms/seconds
  /// misparse from parking a row absurdly far in the future.
  static const Duration maxRetryAfter = Duration(hours: 24);

  /// A `sending` row untouched for longer than this is treated as orphaned and
  /// requeued. Kept comfortably above the providers' slow-call bounds
  /// (OpenRouterProvider.timeout, 2 min; PawletProxyProvider.callBudget,
  /// 2 min 45 s) so a genuinely slow in-flight call is
  /// never reclaimed mid-flight — which could otherwise cause duplicate
  /// processing across isolates. See the guard in processing_service_test.
  static const Duration staleAfter = Duration(minutes: 3);

  bool _running = false;
  bool _paused = false;

  /// Whether a pass is in flight in this isolate. The UI checks it before
  /// moving the LLM mode, since that rebuilds (and disposes) this service.
  bool get isRunning => _running;

  /// Suspends the drain. The bulk inbox import holds this for the length of its
  /// pass so an LLM round-trip can't compete with the on-device model for the
  /// database and the CPU while the user is watching a progress bar.
  ///
  /// UI-isolate only: the background-SMS and WorkManager isolates build their
  /// own bundle and won't see it. That's acceptable — the import writes terminal
  /// rows directly and never takes the queue's single in-flight slot, so a
  /// concurrent background pass is wasteful, not incorrect.
  void pause() => _paused = true;

  void resume() => _paused = false;

  /// Processes every due record. Safe to call concurrently within one isolate
  /// (overlaps are ignored); cross-isolate safety comes from the atomic claim.
  Future<void> process() async {
    if (_paused || _running) return;
    _running = true;
    try {
      await smsRepository.reclaimStale(_clock() - staleAfter.inMilliseconds);

      final banks = await banksRepository.list();
      final cur = currency();
      final rate = await usdBdtRate();
      // Read once for the cheap pre-claim skip below; the decision to actually
      // call out is re-checked per record, since a pass can span several
      // two-minute LLM calls and lose the network partway through.
      final online = await isOnline();

      final due = await smsRepository.dueForDelivery(_clock());
      var processedAny = false;
      for (final record in due) {
        // Never break: a row another isolate claimed, or one parked waiting for
        // the LLM, says nothing about the rows behind it — those may still be
        // resolvable entirely on-device.
        if (await _processOne(record, banks, cur, rate, online)) {
          processedAny = true;
        }
      }

      // Only the isolate that actually processed something runs the deferred
      // matchers and later signals the UI; a fully contended pass does neither.
      if (processedAny) {
        final after = afterPass;
        if (after != null) {
          try {
            await after();
          } catch (_) {
            // A matcher error must not skip the counts reconcile below.
          }
        }
      }

      final counts = onCounts;
      if (counts != null) {
        try {
          await counts(await smsRepository.countFailed());
        } catch (_) {
          // A notifications-reconcile error must not skip the data-changed
          // signal or the reschedule below (mirrors the afterPass guard).
        }
      }

      // Throttled cleanup (≤1 real prune / 24h across all triggers and both
      // isolates, via a single DB row) — deletes only aged ignored rows.
      await smsRepository.pruneIfDue(now: _clock());

      // A pass that touched records likely changed queue/history/finance state.
      // Bump the DB change-token so the UI (which polls it) re-reads — this works
      // from ANY isolate, including the WorkManager / background-SMS isolates the
      // UI can't otherwise hear from.
      if (processedAny) await smsRepository.bumpDataRevision();

      await _rescheduleNext();
    } catch (_) {
      // Best-effort background drain: per-record failures are already handled
      // inside the loop; swallow any pass-level error (reclaim/list/counts) so
      // fire-and-forget callers (app resume / bootstrap) never see it throw.
    } finally {
      _running = false;
    }
  }

  /// Runs [record] through the three layers, returning whether it reached a
  /// terminal state or was rescheduled. False means the pass decided nothing
  /// about it: another isolate holds the row, or only the LLM can answer it and
  /// the LLM is out of reach (offline, or its single slot is taken).
  ///
  /// [online] is the pass-level reading, used only to skip a row nothing
  /// on-device can advance; the tier-3 branch re-reads connectivity itself.
  Future<bool> _processOne(
    SmsRecord record,
    List<Bank> banks,
    String cur,
    Decimal? usdRate,
    bool online,
  ) async {
    final hasLlm = classifier.hasLlm;

    // A row the model already declined has nothing left to try offline, so drop
    // it before claiming and save two writes plus the gate. The gate still runs
    // on it the moment we are online again, so a bank deleted meanwhile is
    // honoured then.
    //
    // Guarded on [hasLlm]: with no LLM the flag is stale history rather than a
    // reason to wait, and skipping on it would park the row forever.
    if (hasLlm && record.needsLlm && !online) return false;

    final id = record.id!;
    // The fencing token for every write below: the `updated_at` this caller
    // last wrote. It has to be carried forward because each guarded write —
    // and [SmsRepository.acquireLlmSlot] — rebases it.
    var heldSince = _clock();
    if (!await smsRepository.claimLocal(id, heldSince)) return false;

    try {
      // Layer 1. Re-run even for a `needs_llm` row: the user may since have
      // deleted the bank that let it through.
      if (gateBanks(record.sender, record.content, banks).isEmpty) {
        return smsRepository.updateStatus(
          id,
          SmsStatus.ignored,
          attempts: record.attempts,
          updatedAt: _clock(),
          nextAttemptAt: null,
          ignoreReason: IgnoreReason.gated,
          processedAt: _clock(),
          heldSince: heldSince,
        );
      }

      // Layer 2. Skipped once flagged: the model has already seen this exact
      // content and declined it, and `content` never changes.
      //
      // Deliberately unbounded — do not wrap this in `.timeout()`. Abandoning
      // the wait does not cancel the inference: the interpreter isolate stays
      // latched mid-run and every later call returns unfilled output buffers,
      // whose uniform softmax never clears the confidence threshold, so ONE
      // stall would silently downgrade every later message in the process to
      // LLM-only. Treating the timeout as a decline would also set `needs_llm`,
      // which is never cleared, permanently sending a free message to a paid
      // call. A run that overruns [staleAfter] is handled safely for the ROW —
      // reclaimed, and the `heldSince` token makes late writes no-ops — but not
      // for the PASS: `infer` never returns, so `process()` never returns,
      // `_running` stays true for this isolate's lifetime, and `_rescheduleNext`
      // never fires. The isolate's drain is wedged until app restart; other
      // isolates still drain.

      // The flag is honoured only when an LLM can act on it. With no LLM it
      // records that the GATED gate declined, which says nothing about the
      // ungated pass [Classifier] now runs — and re-running it is also how
      // legacy flagged rows drain without a migration.
      final skipInference = hasLlm && record.needsLlm;
      var declined = skipInference;
      if (!skipInference) {
        final local = await classifier.classifyLocal(
          content: record.content,
          currency: cur,
          usdRate: usdRate,
        );
        final localOutcome = local.outcome;
        if (localOutcome != null) {
          return _finish(record, localOutcome, banks, cur, heldSince);
        }
        declined = local.declined;
      }

      // No LLM: the on-device pass is the whole pipeline, so a rejection is
      // terminal rather than a deferral — there is nothing left to defer to.
      // Surfaced as a failure so it appears in Messages with the Retry action
      // already offered there, which is what makes it recoverable once a key
      // is added.
      //
      // `needs_llm` is deliberately left alone. It is never cleared, and the
      // two readers above would then drop this row while offline and skip its
      // inference for good.
      if (!hasLlm) {
        return smsRepository.updateStatus(
          id,
          SmsStatus.failure,
          attempts: record.attempts + 1,
          failureReason: FailureReason.localOnly,
          lastError: 'on-device model produced no usable record',
          updatedAt: _clock(),
          nextAttemptAt: null,
          heldSince: heldSince,
        );
      }

      // Layer 3.
      if (!await isOnline()) {
        return _deferForLlm(record, heldSince, declined: declined);
      }
      final slotAt = _clock();
      if (!await smsRepository.acquireLlmSlot(id, slotAt)) {
        return _deferForLlm(record, heldSince, declined: declined);
      }
      heldSince = slotAt; // the promotion rewrote `updated_at`

      final outcome = await classifier.classifyRemote(
        sender: record.sender,
        content: record.content,
        currency: cur,
      );
      return _finish(record, outcome, banks, cur, heldSince);
    } on LlmException catch (e) {
      if (!e.retryable) {
        // Fatal (bad key / bad request): fail immediately with a clear error.
        return smsRepository.updateStatus(
          id,
          SmsStatus.failure,
          attempts: record.attempts + 1,
          failureReason: FailureReason.llmError,
          lastError: _truncate(e.message),
          updatedAt: _clock(),
          nextAttemptAt: null,
          heldSince: heldSince,
        );
      }
      return _reschedule(
        record,
        e.message,
        retryAfter: e.retryAfter,
        resetAtEpochMs: e.resetAtEpochMs,
        heldSince: heldSince,
      );
    } catch (e) {
      // Unexpected (e.g. a DB error): treat as transient and back off.
      return _reschedule(record, e.toString(), heldSince: heldSince);
    }
  }

  /// Writes the finance record for a decided [outcome] and closes the row out.
  /// Returns whether persistent state changed: true when the terminal status
  /// write landed OR when FinanceWriter.apply actually wrote a finance row.
  ///
  /// The claim is re-checked BEFORE [FinanceWriter.apply], not left to the
  /// guarded status write alone, because `apply` is irreversible: it inserts
  /// into `transactions`/`bills` and can move a bank balance, none of which a
  /// rejected status write undoes. Discovering the loss afterwards would strand
  /// a real transaction on a row the next holder settles as `ignored/no_record`
  /// (its own `apply` dedupes on `message_id`) — counted in finance totals,
  /// missing from History, and deleted by the ignored-row prune a week later,
  /// leaving `transactions.message_id` dangling.
  Future<bool> _finish(
    SmsRecord record,
    ClassificationOutcome outcome,
    List<Bank> banks,
    String cur,
    int heldSince,
  ) async {
    final id = record.id!;
    if (!await smsRepository.stillHeld(id, heldSince)) return false;

    final label = await financeWriter.apply(
      record: record,
      outcome: outcome,
      banks: banks,
      currency: cur,
    );
    if (label == 'ignored') {
      // Terminal ignored: no category, tagged with an internal reason.
      // - on-device model said "not financial"          → localNone
      // - LLM ran and said "not financial"              → llmNone
      // - classified financial but no row was written   → noRecord
      //   (missing metadata, unmatched card, or a dupe — FinanceWriter
      //   returns a bare 'ignored' without saying which; lumped here).
      // A gate miss never reaches here: it is terminal before any model runs.
      final IgnoreReason reason;
      if (outcome.category == SmsCategory.none) {
        reason = outcome.parseSource == ParseSource.local
            ? IgnoreReason.localNone
            : IgnoreReason.llmNone;
      } else {
        reason = IgnoreReason.noRecord;
      }
      return smsRepository.updateStatus(
        id,
        SmsStatus.ignored,
        attempts: record.attempts,
        updatedAt: _clock(),
        nextAttemptAt: null,
        ignoreReason: reason,
        parseSource: outcome.parseSource,
        processedAt: _clock(),
        heldSince: heldSince,
      );
    }
    final statusWritten = await smsRepository.updateStatus(
      id,
      SmsStatus.success,
      attempts: record.attempts,
      updatedAt: _clock(),
      nextAttemptAt: null,
      category: label,
      parseSource: outcome.parseSource,
      processedAt: _clock(),
      heldSince: heldSince,
    );
    // Count as progress when either the status write landed OR a finance row
    // was committed: a written transaction/bill is persistent state change even
    // if the status write was rejected, and must trigger the dataRevision bump
    // so the UI re-reads and shows the new row. The retry's apply dedupes it to
    // ignored/noRecord, so the SMS row eventually settles to match.
    return statusWritten || label != 'ignored';
  }

  /// Releases a claimed row back to the queue, unchanged and still due.
  ///
  /// [declined] is flagged onto the row so later passes skip the on-device
  /// inference that already turned it down. It is false when the model never
  /// produced a prediction — there is no verdict to remember, and stamping the
  /// permanent flag on a model that failed to load would send every message
  /// deferred during that pass to the paid LLM forever. Retrying inference next
  /// pass costs almost nothing: a model that failed to load stays failed for
  /// the isolate and returns immediately.
  ///
  /// Waiting for connectivity, or for the single LLM slot, is not a failed
  /// attempt: `attempts` and `next_attempt_at` are preserved, so a message that
  /// arrives mid-flight does not burn its retry budget before anyone has tried
  /// it. Always returns false — the pass decided nothing about this row.
  Future<bool> _deferForLlm(
    SmsRecord record,
    int heldSince, {
    required bool declined,
  }) async {
    await smsRepository.releaseLocal(record.id!, heldSince, needsLlm: declined);
    return false;
  }

  Future<bool> _reschedule(
    SmsRecord record,
    String error, {
    Duration? retryAfter,
    int? resetAtEpochMs,
    required int heldSince,
  }) async {
    final id = record.id!;
    // A failure while offline is a transport drop, not a real attempt: release
    // the row unchanged (still due) so the next online pass retries it.
    //
    // Deliberately no `needsLlm`: this path also catches a DB error raised
    // while writing a row the on-device model resolved, and flagging that row
    // would send a future pass to the LLM for a message the model answers for
    // free. A row that is only waiting for the LLM is flagged by
    // [_deferForLlm] instead.
    //
    // Uses the guarded [SmsRepository.updateStatus] rather than
    // [SmsRepository.releaseLocal] because the row may be in `sending` here.
    if (!await isOnline()) {
      // Offline release: still returns false (not progress) even if the status
      // write lands — the row is unchanged, still due, exactly as it was.
      await smsRepository.updateStatus(
        id,
        SmsStatus.queued,
        attempts: record.attempts,
        updatedAt: _clock(),
        nextAttemptAt: record.nextAttemptAt,
        heldSince: heldSince,
      );
      return false;
    }

    final attempts = record.attempts + 1;
    if (attempts >= maxAttempts) {
      return smsRepository.updateStatus(
        id,
        SmsStatus.failure,
        attempts: attempts,
        failureReason: FailureReason.retryExhausted,
        lastError: _truncate(error),
        updatedAt: _clock(),
        nextAttemptAt: null,
        heldSince: heldSince,
      );
    }

    // Fold any server hints into a single clamped floor, then take the max with
    // our backoff: honor "don't retry before" while preserving escalation and
    // never hammering faster than the backoff would.
    final now = _clock();
    var hint = Duration.zero;
    if (retryAfter != null && retryAfter > hint) hint = retryAfter;
    if (resetAtEpochMs != null) {
      final d = Duration(
        milliseconds: resetAtEpochMs - now,
      ); // absolute → delay
      if (d > hint) hint = d; // past/negative delta stays below zero → ignored
    }
    if (hint > maxRetryAfter) hint = maxRetryAfter; // clamp skew / ms-misparse
    final backoff = _backoff(attempts);
    final delay = hint > backoff ? hint : backoff;

    return smsRepository.updateStatus(
      id,
      SmsStatus.queued,
      attempts: attempts,
      lastError: error,
      updatedAt: now,
      nextAttemptAt: now + delay.inMilliseconds,
      heldSince: heldSince,
    );
  }

  /// Computes the next background catch-up and hands it to [reschedule]: a delay
  /// until the soonest thing that needs a pass, or null (cancel) when nothing is
  /// pending. Two sources feed the wake time:
  /// - the soonest queued retry (`next_attempt_at`), and
  /// - the stale-reclaim time of any in-flight row (`updated_at + staleAfter`).
  ///
  /// The second source is essential: a row orphaned by a dead holder is never
  /// returned to the queue unless some later pass runs
  /// [SmsRepository.reclaimStale] on it, and with nothing queued there would be
  /// nothing left to schedule that pass — an orphan in the LLM slot would also
  /// block *every* other message. Due-now rows yield a zero delay.
  Future<void> _rescheduleNext() async {
    final cb = reschedule;
    if (cb == null) return;
    final now = _clock();

    // The earliest anything blocked on the single LLM slot can move: the slot
    // holder's own stale-reclaim time. Null when the slot is free.
    final slotHeldAt = await smsRepository.oldestSendingAt();
    final slotFloor = slotHeldAt == null
        ? null
        : slotHeldAt + staleAfter.inMilliseconds;

    int? wake;

    final soonestQueued = await smsRepository.soonestQueuedAttempt();
    if (soonestQueued != null) {
      // A due-now queued row is either LLM-bound — and then it cannot run while
      // the single LLM slot is held — or locally solvable, in which case the
      // pass that just ran already handled it. Either way, scheduling at its raw
      // due time hands WorkManager a ~0 delay it re-runs back-to-back (every
      // pass reschedules itself), a livelock that pegs the device. Wait for the
      // slot's stale-reclaim time instead.
      wake = slotFloor == null ? soonestQueued : max(soonestQueued, slotFloor);
    }

    // Safety net for a claimed row whose holder died. With nothing queued,
    // nothing else would ever schedule the pass that calls reclaimStale on it,
    // and the row would sit in `processing`/`sending` until the user reopened
    // the app.
    final inFlightAt = await smsRepository.oldestInFlightAt();
    if (inFlightAt != null) {
      final reclaimAt = inFlightAt + staleAfter.inMilliseconds;
      wake = wake == null ? reclaimAt : min(wake, reclaimAt);
      // ...but never below the slot floor. `oldestInFlightAt` spans `processing`
      // too, so it can be older than the slot holder — and reclaiming a
      // `processing` row frees no slot, so it is no reason to wake earlier.
      // Without this clamp a live LLM call with an older local row alongside it
      // yields the ~0-delay busy-loop the floor exists to prevent.
      if (slotFloor != null && wake < slotFloor) wake = slotFloor;
    }

    if (wake == null) {
      await cb(null);
      return;
    }
    final delayMs = wake - now;
    await cb(Duration(milliseconds: delayMs < 0 ? 0 : delayMs));
  }

  /// Trims a terminal-failure error string to fit the internal `last_error`
  /// column (read via ADB/debug only, never shown in the UI).
  String _truncate(String s, [int max = 100]) =>
      s.length <= max ? s : s.substring(0, max);

  /// Capped exponential backoff. [attempt] is the already-incremented count, so
  /// attempt 1 -> 15s, 2 -> 1m, 3 -> 4m, ... capped at [maxBackoff].
  Duration _backoff(int attempt) {
    final seconds = min(
      maxBackoff.inSeconds,
      baseBackoff.inSeconds * pow(4, attempt - 1).toInt(),
    );
    return Duration(seconds: seconds);
  }
}
