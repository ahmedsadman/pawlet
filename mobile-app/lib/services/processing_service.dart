import 'dart:math';

import '../data/banks_repository.dart';
import '../data/sms_repository.dart';
import '../models/finance/bank.dart';
import '../models/sms_record.dart';
import 'classification/classifier.dart';
import 'finance/finance_writer.dart';
import 'llm/llm_provider.dart';

/// Outcome of processing one record, telling the drain loop whether to continue.
enum _PassStep {
  /// Reached a terminal state or was rescheduled; the slot is free — continue.
  processed,

  /// Device went offline; the row is left due — stop the pass.
  offline,

  /// Couldn't claim: the single global in-flight slot is held elsewhere (or the
  /// row was taken by another isolate) — stop and let that isolate drain.
  contended,
}

/// Drains the SMS queue, processing each due record atomically: Layer-1 gate +
/// single fused LLM call + finance write. Failures are rescheduled with a
/// capped-exponential backoff persisted in `next_attempt_at`; the existing
/// triggers (foreground resume, incoming-SMS isolate, WorkManager tick) drive
/// later retries.
class ProcessingService {
  ProcessingService({
    required this.smsRepository,
    required this.banksRepository,
    required this.classifier,
    required this.financeWriter,
    required this.isOnline,
    required this.currency,
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
  /// requeued. Kept comfortably above the provider's single-attempt HTTP timeout
  /// (OpenRouterProvider.timeout, 2 min) so a genuinely slow in-flight call is
  /// never reclaimed mid-flight — which could otherwise cause duplicate
  /// processing across isolates. See the guard in processing_service_test.
  static const Duration staleAfter = Duration(minutes: 3);

  bool _running = false;

  /// Processes every due record. Safe to call concurrently within one isolate
  /// (overlaps are ignored); cross-isolate safety comes from the atomic claim.
  Future<void> process() async {
    if (_running) return;
    _running = true;
    try {
      if (!await isOnline()) {
        // Still (re)schedule so an offline backlog gets a connectivity-gated
        // catch-up, then bail.
        await _rescheduleNext();
        return;
      }

      await smsRepository.reclaimStale(_clock() - staleAfter.inMilliseconds);

      final banks = await banksRepository.list();
      final cur = currency();

      final due = await smsRepository.dueForDelivery(_clock());
      var processedAny = false;
      for (final record in due) {
        final step = await _processOne(record, banks, cur);
        if (step == _PassStep.processed) {
          processedAny = true;
          continue;
        }
        // Offline (resume later) or contended — another isolate holds the single
        // global slot, so back off and let that isolate drain the queue.
        break;
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

  /// Processes [record] once, returning how the pass should proceed:
  /// - [_PassStep.offline]: went offline (row left queued and due) — stop.
  /// - [_PassStep.contended]: couldn't claim — the single global slot is held by
  ///   another isolate (or the row was taken) — stop and let that isolate drain.
  /// - [_PassStep.processed]: reached a terminal state or was rescheduled —
  ///   the slot is free again, so the caller may continue to the next record.
  Future<_PassStep> _processOne(
    SmsRecord record,
    List<Bank> banks,
    String cur,
  ) async {
    if (!await isOnline()) return _PassStep.offline;

    final id = record.id!;
    if (!await smsRepository.claim(id, _clock())) return _PassStep.contended;

    try {
      final outcome = await classifier.classify(
        sender: record.sender,
        content: record.content,
        banks: banks,
        currency: cur,
      );
      final label = await financeWriter.apply(
        record: record,
        outcome: outcome,
        banks: banks,
        currency: cur,
      );
      if (label == 'ignored') {
        // Terminal ignored: no category, tagged with an internal reason.
        // - gate rejected it (no model ran)               → gated
        // - on-device model said "not financial"          → localNone
        // - LLM ran and said "not financial"              → llmNone
        // - classified financial but no row was written   → noRecord
        //   (missing metadata, unmatched card, or a dupe — FinanceWriter
        //   returns a bare 'ignored' without saying which; lumped here).
        final IgnoreReason reason;
        if (outcome.parseSource == null) {
          // Layer-1 gate rejected it; no model ran.
          reason = IgnoreReason.gated;
        } else if (outcome.category == SmsCategory.none) {
          reason = outcome.parseSource == ParseSource.local
              ? IgnoreReason.localNone
              : IgnoreReason.llmNone;
        } else {
          reason = IgnoreReason.noRecord;
        }
        await smsRepository.updateStatus(
          id,
          SmsStatus.ignored,
          attempts: record.attempts,
          updatedAt: _clock(),
          nextAttemptAt: null,
          ignoreReason: reason,
          parseSource: outcome.parseSource,
          processedAt: _clock(),
        );
      } else {
        await smsRepository.updateStatus(
          id,
          SmsStatus.success,
          attempts: record.attempts,
          updatedAt: _clock(),
          nextAttemptAt: null,
          category: label,
          parseSource: outcome.parseSource,
          processedAt: _clock(),
        );
      }
      return _PassStep.processed;
    } on LlmException catch (e) {
      if (!e.retryable) {
        // Fatal (bad key / bad request): fail immediately with a clear error.
        await smsRepository.updateStatus(
          id,
          SmsStatus.failure,
          attempts: record.attempts + 1,
          failureReason: FailureReason.llmError,
          lastError: _truncate(e.message),
          updatedAt: _clock(),
          nextAttemptAt: null,
        );
        return _PassStep.processed;
      }
      return _rescheduleStep(
        record,
        e.message,
        retryAfter: e.retryAfter,
        resetAtEpochMs: e.resetAtEpochMs,
      );
    } catch (e) {
      // Unexpected (e.g. a DB error): treat as transient and back off.
      return _rescheduleStep(record, e.toString());
    }
  }

  /// Wraps [_reschedule] into a [_PassStep]: a reschedule while offline leaves the
  /// row due and stops the pass; otherwise the row backed off and the pass may
  /// continue to the next record.
  Future<_PassStep> _rescheduleStep(
    SmsRecord record,
    String error, {
    Duration? retryAfter,
    int? resetAtEpochMs,
  }) async {
    final rescheduled = await _reschedule(
      record,
      error,
      retryAfter: retryAfter,
      resetAtEpochMs: resetAtEpochMs,
    );
    return rescheduled ? _PassStep.processed : _PassStep.offline;
  }

  Future<bool> _reschedule(
    SmsRecord record,
    String error, {
    Duration? retryAfter,
    int? resetAtEpochMs,
  }) async {
    final id = record.id!;
    // A failure while offline is a transport drop, not a real attempt: release
    // the row unchanged (still due) so the next online pass retries it.
    if (!await isOnline()) {
      await smsRepository.updateStatus(
        id,
        SmsStatus.queued,
        attempts: record.attempts,
        updatedAt: _clock(),
        nextAttemptAt: record.nextAttemptAt,
      );
      return false;
    }

    final attempts = record.attempts + 1;
    if (attempts >= maxAttempts) {
      await smsRepository.updateStatus(
        id,
        SmsStatus.failure,
        attempts: attempts,
        failureReason: FailureReason.retryExhausted,
        lastError: _truncate(error),
        updatedAt: _clock(),
        nextAttemptAt: null,
      );
      return true;
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

    await smsRepository.updateStatus(
      id,
      SmsStatus.queued,
      attempts: attempts,
      lastError: error,
      updatedAt: now,
      nextAttemptAt: now + delay.inMilliseconds,
    );
    return true;
  }

  /// Computes the next background catch-up and hands it to [reschedule]: a delay
  /// until the soonest thing that needs a pass, or null (cancel) when nothing is
  /// pending. Two sources feed the wake time:
  /// - the soonest queued retry (`next_attempt_at`), and
  /// - the stale-reclaim time of any in-flight row (`updated_at + staleAfter`).
  ///
  /// The second source is essential under the single global slot: an orphaned
  /// `sending` row (holder isolate died) blocks *every* other message, and if no
  /// queued rows remain there'd otherwise be nothing scheduled to run
  /// [SmsRepository.reclaimStale] — the whole queue would stall until the user
  /// manually reopened the app. Due-now rows (or an offline backlog) yield zero.
  Future<void> _rescheduleNext() async {
    final cb = reschedule;
    if (cb == null) return;
    final now = _clock();

    final wakeTimes = <int>[];
    final soonestQueued = await smsRepository.soonestQueuedAttempt();
    if (soonestQueued != null) wakeTimes.add(soonestQueued);
    final oldestSending = await smsRepository.oldestSendingAt();
    if (oldestSending != null) {
      wakeTimes.add(oldestSending + staleAfter.inMilliseconds);
    }

    if (wakeTimes.isEmpty) {
      await cb(null);
      return;
    }
    final wake = wakeTimes.reduce((a, b) => a < b ? a : b);
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
