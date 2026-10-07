import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'classify_result_parser.dart';
import 'llm_provider.dart';
import 'prompts.dart';

/// [LlmProvider] backed by OpenRouter's chat-completions API. One call both
/// classifies the SMS and extracts its metadata (fused prompt). Output is forced
/// to JSON, validated, and mapped to [ClassifyResult].
///
/// A single attempt is made per call — there is no internal retry loop. Transient
/// failures (429/5xx/network/timeout/malformed JSON) surface as retryable
/// [LlmException]s so the processing pipeline owns retry/backoff (persistent and
/// visible via `attempts`/`next_attempt_at`); fatal failures (bad key / bad
/// request) surface as non-retryable. Keeping retry in one layer avoids a slow
/// provider blocking the single-flight queue while retrying invisibly.
class OpenRouterProvider implements LlmProvider {
  OpenRouterProvider({
    required this.apiKey,
    required this.models,
    http.Client? client,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null;

  final String apiKey;

  /// Ordered fallback list. OpenRouter tries these in order within one request,
  /// falling through on any error (429/5xx/downtime/moderation/context).
  final List<String> models;
  final http.Client _client;
  final bool _ownsClient;

  /// Closes the internally-created HTTP client. No-op when the caller injected
  /// their own client (they own its lifecycle).
  void close() {
    if (_ownsClient) _client.close();
  }

  static const String endpoint =
      'https://openrouter.ai/api/v1/chat/completions';
  // Generous single-attempt ceiling: free models can be slow, so give the one
  // request room to finish rather than failing fast and deferring to a backoff.
  // This is a foreground ceiling, not a background guarantee — under Doze the OS
  // may end a wake window sooner, which surfaces as a transient retry (by
  // design). Must stay below ProcessingService.staleAfter so a slow in-flight
  // call is never reclaimed as orphaned.
  static const Duration timeout = Duration(minutes: 2);

  @override
  Future<ClassifyResult> classifyAndExtract({
    required String content,
    required String sender,
    required String currency,
  }) async {
    final body = jsonEncode({
      'models': models,
      'messages': [
        {'role': 'system', 'content': fusedSystemPrompt},
        {
          'role': 'user',
          'content': buildUserContent(
            sender: sender,
            content: content,
            currency: currency,
          ),
        },
      ],
      // Strict structured output. require_parameters keeps every fallback hop on
      // a provider that actually enforces the schema (else it would be silently
      // dropped and we'd be back to prose/null output).
      'response_format': {
        'type': 'json_schema',
        'json_schema': fusedJsonSchema,
      },
      'provider': {'require_parameters': true},
    });

    // One attempt; retryable/fatal LlmExceptions propagate to the pipeline.
    return _parse(await _post(body));
  }

  Future<String> _post(String body) async {
    http.Response resp;
    try {
      resp = await _client
          .post(
            Uri.parse(endpoint),
            headers: {
              'Authorization': 'Bearer $apiKey',
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

    final code = resp.statusCode;
    if (code >= 200 && code < 300) return resp.body;
    // Rate limits (429), request timeout (408) and server errors are transient;
    // other 4xx (bad key / bad request) are fatal.
    final retryable = code == 429 || code == 408 || code >= 500;
    // Carry any server retry hint through to the pipeline. OpenRouter sends one
    // of these per 429/503; both are parsed clock-free (Retry-After is relative,
    // X-RateLimit-Reset is an absolute epoch normalized to ms).
    throw LlmException(
      'HTTP $code',
      retryable: retryable,
      retryAfter: parseRetryAfter(resp.headers['retry-after']),
      resetAtEpochMs: parseResetAt(resp.headers['x-ratelimit-reset']),
    );
  }

  ClassifyResult _parse(String raw) {
    final Map<String, dynamic> obj;
    try {
      final outer = jsonDecode(raw) as Map<String, dynamic>;
      final choices = outer['choices'] as List;
      final message = (choices.first as Map)['message'] as Map;
      obj =
          jsonDecode(_stripJsonFence(message['content'] as String))
              as Map<String, dynamic>;
    } catch (e) {
      throw LlmException('malformed response: $e', retryable: true);
    }

    return parseClassifyObject(obj);
  }

  /// Free models sometimes ignore `response_format` and wrap the JSON in a
  /// ```json ... ``` fence; strip it before decoding.
  String _stripJsonFence(String content) {
    var t = content.trim();
    if (t.startsWith('```')) {
      final firstNewline = t.indexOf('\n');
      if (firstNewline != -1) t = t.substring(firstNewline + 1);
      if (t.endsWith('```')) t = t.substring(0, t.length - 3);
    }
    return t.trim();
  }
}
