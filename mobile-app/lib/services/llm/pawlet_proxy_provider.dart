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
  }) : _attestation = attestation,
       _client = client ?? http.Client(),
       _ownsClient = client == null;

  final String apiBase;
  final AttestationService _attestation;
  final http.Client _client;
  final bool _ownsClient;

  /// The server's own OpenRouter call is capped at two minutes; the margin
  /// covers the hop to the server. Must stay below
  /// ProcessingService.staleAfter so a slow call is never reclaimed.
  static const Duration timeout = Duration(minutes: 2, seconds: 15);

  void close() {
    if (_ownsClient) _client.close();
  }

  @override
  Future<ClassifyResult> classifyAndExtract({
    required String content,
    required String sender,
    required String currency,
  }) async {
    final body = jsonEncode({
      'sender': sender,
      'content': content,
      'currency': currency,
    });

    var resp = await _post(body, await _token());
    if (resp.statusCode == 401) {
      resp = await _post(body, await _token(forceRefresh: true));
      if (resp.statusCode == 401) {
        throw const LlmException(
          'session rejected after refresh',
          retryable: false,
        );
      }
    }
    return _handle(resp);
  }

  Future<String> _token({bool forceRefresh = false}) async {
    try {
      return await _attestation.token(forceRefresh: forceRefresh);
    } on AttestationException catch (e) {
      // Retryable even when ineligible: the row stays queued, and once the
      // flag moves the install to byok/none it is reprocessed on that path
      // rather than failing here.
      throw LlmException('attestation: ${e.message}', retryable: true);
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
      throw const LlmException('install rejected by server', retryable: false);
    }
    final retryable = code == 429 || code == 408 || code >= 500;
    throw LlmException(
      'HTTP $code',
      retryable: retryable,
      retryAfter: parseRetryAfter(resp.headers['retry-after']),
      resetAtEpochMs: parseResetAt(resp.headers['x-ratelimit-reset']),
    );
  }
}
