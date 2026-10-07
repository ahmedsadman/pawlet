// Private fields fed by named constructor params are assigned explicitly, as
// elsewhere in the app.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../auth/attestation_service.dart';
import 'classify_result_parser.dart';
import 'llm_provider.dart';

/// [LlmProvider] for `proxy` mode: Pawlet's server holds the OpenRouter key,
/// applies the prompt, and returns an already-normalised result.
///
/// One attempt per call, like [OpenRouterProvider]: retry and backoff belong
/// to ProcessingService. The only extra request is a single re-attest after a
/// 401, because a revoked or rotated session is not a message failure.
class PawletProxyProvider implements LlmProvider {
  PawletProxyProvider({
    required this.apiBase,
    required AttestationService attestation,
    http.Client? client,
    Duration callBudget = callBudget,
  }) : _attestation = attestation,
       _client = client ?? http.Client(),
       _ownsClient = client == null,
       _callBudget = callBudget;

  final String apiBase;
  final AttestationService _attestation;
  final http.Client _client;
  final bool _ownsClient;
  final Duration _callBudget;

  /// The server's own OpenRouter call is capped at two minutes; the margin
  /// covers the hop to the server. Must stay below
  /// ProcessingService.staleAfter so a slow call is never reclaimed.
  static const Duration timeout = Duration(minutes: 2, seconds: 15);

  /// Whole classify flow must complete before this. Must stay below
  /// ProcessingService.staleAfter (3 min) so a slow call cannot be reclaimed
  /// and charged twice from another isolate.
  static const Duration callBudget = Duration(minutes: 2, seconds: 45);

  /// Server limit on content length in bytes. See
  /// `server/internal/httpapi/classify.go`.
  static const int maxContentBytes = 2048;

  void close() {
    if (_ownsClient) _client.close();
  }

  @override
  Future<ClassifyResult> classifyAndExtract({
    required String content,
    required String sender,
    required String currency,
  }) async {
    if (utf8.encode(content).length > maxContentBytes) {
      throw const LlmException(
        'message too long for Pawlet\'s service',
        retryable: false,
      );
    }

    try {
      return await _classifyWithBudget(content, sender, currency);
    } on TimeoutException {
      throw const LlmException('request timed out', retryable: true);
    }
  }

  Future<ClassifyResult> _classifyWithBudget(
    String content,
    String sender,
    String currency,
  ) async {
    return Future(() async {
      final body = jsonEncode({
        'sender': sender,
        'content': content,
        'currency': currency,
      });

      var resp = await _post(body, await _token());
      if (resp.statusCode == 401) {
        resp = await _post(body, await _token(forceRefresh: true));
        if (resp.statusCode == 401) {
          // A fresh session rejected too points at the server (e.g. a
          // rotated signing key), not the message. Retryable so it cannot
          // fail every queued message; the retry budget bounds it.
          throw const LlmException(
            'session rejected after refresh',
            retryable: true,
          );
        }
      }
      return _handle(resp);
    }).timeout(_callBudget);
  }

  Future<String> _token({bool forceRefresh = false}) async {
    try {
      return await _attestation.token(forceRefresh: forceRefresh);
    } on AttestationException catch (e) {
      // Retryable even when ineligible: the row stays queued, and once the
      // flag moves the install to byok/none it is reprocessed on that path
      // rather than failing here. A background isolate that cannot mint
      // passes that on, so the row waits for the foreground uncharged.
      throw LlmException(
        'attestation: ${e.message}',
        retryable: true,
        needsForeground: e.needsForeground,
      );
    }
  }

  Future<http.Response> _post(String body, String token) async {
    try {
      return await _client
          .post(
            Uri.parse('$apiBase/v1/classify'),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
            body: body,
          )
          .timeout(timeout);
    } on TimeoutException {
      throw const LlmException('request timed out', retryable: true);
    } catch (e) {
      throw LlmException('network error: $e', retryable: true);
    }
  }

  String? _parseErrorCode(http.Response resp) {
    try {
      final obj = jsonDecode(resp.body) as Map<String, dynamic>;
      return obj['error'] as String?;
    } catch (_) {
      return null;
    }
  }

  Future<ClassifyResult> _handle(http.Response resp) async {
    final code = resp.statusCode;
    if (code == 200) {
      final Map<String, dynamic> obj;
      try {
        obj = jsonDecode(resp.body) as Map<String, dynamic>;
      } catch (e) {
        throw LlmException('malformed response: $e', retryable: true);
      }
      return parseClassifyObject(obj);
    }
    if (code == 403) {
      await _attestation.reportRejected();
      // Retryable, as for an ineligible attestation in [_token]: the row stays
      // queued and is reprocessed on the byok/none path once the flag moves
      // the mode.
      throw const LlmException('install rejected by server', retryable: true);
    }

    final errorCode = _parseErrorCode(resp);
    final message = errorCode != null ? 'HTTP $code $errorCode' : 'HTTP $code';

    // upstream_rejected means the server's own OpenRouter key/credits are
    // failing — must not permanently fail every queued message;
    // ProcessingService's retry budget bounds it. Other 400s (bad_request,
    // malformed inputs) are the client's fault and stay fatal.
    var retryable = code == 429 || code == 408 || code >= 500;
    if (code == 400 && errorCode == 'upstream_rejected') {
      retryable = true;
    }

    throw LlmException(
      message,
      retryable: retryable,
      retryAfter: parseRetryAfter(resp.headers['retry-after']),
      resetAtEpochMs: parseResetAt(resp.headers['x-ratelimit-reset']),
    );
  }
}
