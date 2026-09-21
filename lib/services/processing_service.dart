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
/// later retries. Ports Textgenie's FlushService, swapping webhook delivery for
/// the classification pipeline.
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
  }) : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  final SmsRepository smsRepository;
  final BanksRepository banksRepository;
  final Classifier classifier;
  final FinanceWriter financeWriter;
  final Future<bool> Function() isOnline;
  final String Function() currency;
  final int Function() _clock;

  /// Optional hook fired after a pass with the current failed / retrying counts
  /// (used to reconcile notifications).
  final Future<void> Function(int failed, int retrying)? onCounts;

  /// Max attempts before a record is marked failed.
  static const int maxAttempts = 10;

  /// First retry delay; each subsequent retry multiplies by 4 up to [maxBackoff].
  static const Duration baseBackoff = Duration(seconds: 15);

  /// Ceiling for a single backoff step (~23.7h total across [maxAttempts]).
  static const Duration maxBackoff = Duration(hours: 6);

  /// A `sending` row untouched for longer than this is treated as orphaned.
  static const Duration staleAfter = Duration(seconds: 150);

  bool _running = false;

  /// Processes every due record. Safe to call concurrently within one isolate
  /// (overlaps are ignored); cross-isolate safety comes from the atomic claim.
  Future<void> process() async {
    if (_running) return;
    _running = true;
    try {
      if (!await isOnline()) return;

      await smsRepository.reclaimStale(
        _clock() - staleAfter.inMilliseconds,
      );

      final banks = await banksRepository.list();
      final cur = currency();

      for (final record in await smsRepository.dueForDelivery(_clock())) {
        final proceeded = await _processOne(record, banks, cur);
        if (!proceeded) break; // went offline — resume later
      }

      final counts = onCounts;
      if (counts != null) {
        await counts(
          await smsRepository.countFailed(),
          await smsRepository.countRetrying(),
        );
      }
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
      final category = await financeWriter.apply(
        record: record,
        outcome: outcome,
        banks: banks,
        currency: cur,
      );
      await smsRepository.updateStatus(
        id,
        SmsStatus.success,
        attempts: record.attempts,
        updatedAt: _clock(),
        nextAttemptAt: null,
        category: category,
        processedAt: _clock(),
      );
      return true;
    } on LlmException catch (e) {
      if (!e.retryable) {
        // Fatal (bad key / bad request): fail immediately with a clear error.
        await smsRepository.updateStatus(
          id,
          SmsStatus.failure,
          attempts: record.attempts + 1,
          lastError: e.message,
          updatedAt: _clock(),
          nextAttemptAt: null,
        );
        return true;
      }
      return _reschedule(record, e.message);
    } catch (e) {
      // Unexpected (e.g. a DB error): treat as transient and back off.
      return _reschedule(record, e.toString());
    }
  }

  Future<bool> _reschedule(SmsRecord record, String error) async {
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
        lastError: error,
        updatedAt: _clock(),
        nextAttemptAt: null,
      );
      return true;
    }

    await smsRepository.updateStatus(
      id,
      SmsStatus.queued,
      attempts: attempts,
      lastError: error,
      updatedAt: _clock(),
      nextAttemptAt: _clock() + _backoff(attempts).inMilliseconds,
    );
    return true;
  }

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
