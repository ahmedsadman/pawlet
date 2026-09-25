import 'dart:math';

import '../data/banks_repository.dart';
import '../data/sms_repository.dart';
import '../models/finance/bank.dart';
import '../models/sms_record.dart';
import 'classification/classifier.dart';
import 'finance/finance_writer.dart';
import 'llm/llm_provider.dart';

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
    this.onChanged,
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

  /// Optional hook fired once after a pass that attempted at least one record,
  /// so the UI isolate can refresh views. Null in background isolates.
  final void Function()? onChanged;

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
      for (final record in due) {
        final proceeded = await _processOne(record, banks, cur);
        if (!proceeded) break; // went offline — resume later
      }

      final after = afterPass;
      if (after != null) {
        try {
          await after();
        } catch (_) {
          // A matcher error must not skip the counts reconcile below.
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

      // A pass that touched records likely changed queue/history/finance state;
      // signal the UI isolate to re-read. Cheap no-op in background isolates.
      if (due.isNotEmpty) onChanged?.call();

      await _rescheduleNext();
    } catch (_) {
      // Best-effort background drain: per-record failures are already handled
      // inside the loop; swallow any pass-level error (reclaim/list/counts) so
      // fire-and-forget callers (app resume / bootstrap) never see it throw.
    } finally {
      _running = false;
    }
  }

  /// Processes [record] once. Returns false only when abandoned because the
  /// device went offline (left queued and due); true once it reached a terminal
  /// state, was rescheduled, was claimed by another isolate, or was skipped.
  Future<bool> _processOne(
    SmsRecord record,
    List<Bank> banks,
    String cur,
  ) async {
    if (!await isOnline()) return false;

    final id = record.id!;
    if (!await smsRepository.claim(id, _clock())) return true; // lost the claim

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
        // - gate rejected it (LLM never ran)              → gated
        // - LLM ran and said "not financial"             → llmNone
        // - LLM said financial but no row was written     → noRecord
        //   (missing metadata, unmatched card, or a dupe — FinanceWriter
        //   returns a bare 'ignored' without saying which; lumped here).
        final IgnoreReason reason;
        if (!outcome.llmInvoked) {
          reason = IgnoreReason.gated;
        } else if (outcome.category == SmsCategory.none) {
          reason = IgnoreReason.llmNone;
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
          processedAt: _clock(),
        );
      }
      return true;
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
        return true;
      }
      return _reschedule(
        record,
        e.message,
        retryAfter: e.retryAfter,
        resetAtEpochMs: e.resetAtEpochMs,
      );
    } catch (e) {
      // Unexpected (e.g. a DB error): treat as transient and back off.
      return _reschedule(record, e.toString());
    }
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

  /// Computes the next background catch-up from the queue state and hands it to
  /// [reschedule]: a delay until the soonest pending retry, or null (cancel) when
  /// nothing is queued. Due-now rows (or an offline backlog) yield zero delay.
  Future<void> _rescheduleNext() async {
    final cb = reschedule;
    if (cb == null) return;
    final soonest = await smsRepository.soonestQueuedAttempt();
    if (soonest == null) {
      await cb(null);
      return;
    }
    final delayMs = soonest - _clock();
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
