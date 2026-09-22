import 'dart:async';
import 'dart:convert';

import 'package:decimal/decimal.dart';
import 'package:http/http.dart' as http;

import 'llm_provider.dart';
import 'prompts.dart';

/// [LlmProvider] backed by OpenRouter's chat-completions API. One call both
/// classifies the SMS and extracts its metadata (fused prompt). Output is forced
/// to JSON, validated, and mapped to [ClassifyResult]. Transient failures
/// (429/5xx/network/timeout/malformed JSON) are retried with capped-exponential
/// backoff; fatal failures (bad key / bad request) surface immediately.
class OpenRouterProvider implements LlmProvider {
  OpenRouterProvider({
    required this.apiKey,
    required this.model,
    http.Client? client,
    Future<void> Function(Duration)? sleep,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       _sleep = sleep ?? Future<void>.delayed;

  final String apiKey;
  final String model;
  final http.Client _client;
  final bool _ownsClient;
  final Future<void> Function(Duration) _sleep;

  /// Closes the internally-created HTTP client. No-op when the caller injected
  /// their own client (they own its lifecycle).
  void close() {
    if (_ownsClient) _client.close();
  }

  static const String endpoint =
      'https://openrouter.ai/api/v1/chat/completions';
  static const int maxCycles = 3;
  static const Duration baseBackoff = Duration(seconds: 10);
  static const Duration timeout = Duration(seconds: 30);

  @override
  Future<ClassifyResult> classifyAndExtract({
    required String content,
    required String sender,
    required String currency,
  }) async {
    final body = jsonEncode({
      'model': model,
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
      'response_format': {'type': 'json_object'},
    });

    LlmException? last;
    for (var cycle = 0; cycle < maxCycles; cycle++) {
      try {
        final raw = await _post(body);
        return _parse(raw);
      } on LlmException catch (e) {
        if (!e.retryable) rethrow;
        last = e;
        if (cycle < maxCycles - 1) {
          await _sleep(baseBackoff * (1 << cycle)); // 10s, 20s, 40s
        }
      }
    }
    throw last!;
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
    throw LlmException('HTTP $code', retryable: retryable);
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

    // `category` is authoritative: the matching block is read and the other is
    // intentionally ignored (spec/04). Absent/null → neither; any other
    // unexpected value is malformed and retried rather than silently ignored.
    final category = obj['category'];
    if (category == 'transaction') {
      return ClassifyResult(
        category: SmsCategory.transaction,
        transaction: _metadata(obj['transaction']),
      );
    }
    if (category == 'bill') {
      return ClassifyResult(
        category: SmsCategory.bill,
        bill: _bill(obj['bill']),
      );
    }
    if (category == null) return const ClassifyResult.none();
    throw LlmException('unexpected category: $category', retryable: true);
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

  MetadataResult _metadata(Object? raw) {
    if (raw is! Map) return const MetadataResult();
    final balance = _numStr(raw['balance']);

    var amount = _numStr(raw['amount']);
    var originalAmount = _numStr(raw['original_amount']);
    var type = _txType(raw['transaction_type']);
    // amount / original_amount / transaction_type are all-or-nothing.
    if (amount == null || originalAmount == null || type == null) {
      amount = null;
      originalAmount = null;
      type = null;
    }

    // original_currency is only meaningful alongside a number (amount/balance).
    var currency = _currency(raw['original_currency']);
    if (amount == null && balance == null) currency = null;

    return MetadataResult(
      balance: balance,
      amount: amount,
      originalAmount: originalAmount,
      transactionType: type,
      originalCurrency: currency,
    );
  }

  BillMetadataResult _bill(Object? raw) {
    if (raw is! Map) return const BillMetadataResult();

    // normalized_total_due / original_amount / original_currency are
    // all-or-nothing; the statement period components stay independent.
    var total = _numStr(raw['normalized_total_due']);
    var originalAmount = _numStr(raw['original_amount']);
    var currency = _currency(raw['original_currency']);
    if (total == null || originalAmount == null || currency == null) {
      total = null;
      originalAmount = null;
      currency = null;
    }

    return BillMetadataResult(
      normalizedTotalDue: total,
      originalAmount: originalAmount,
      originalCurrency: currency,
      statementMonth: _month(raw['statement_month']),
      statementYear: _year(raw['statement_year']),
    );
  }

  // ---- validation helpers -------------------------------------------------

  /// Returns a decimal-as-string when [value] parses as a number, else null.
  String? _numStr(Object? value) {
    if (value == null) return null;
    final s = value.toString();
    return Decimal.tryParse(s) == null ? null : s;
  }

  String? _currency(Object? value) {
    if (value is! String) return null;
    return RegExp(r'^[A-Za-z]{3}$').hasMatch(value) ? value.toUpperCase() : null;
  }

  String? _txType(Object? value) {
    if (value is! String) return null;
    return const {'income', 'expense', 'transfer'}.contains(value)
        ? value
        : null;
  }

  int? _month(Object? value) {
    final n = value is num ? value.toInt() : int.tryParse('$value');
    return (n != null && n >= 1 && n <= 12) ? n : null;
  }

  int? _year(Object? value) {
    final n = value is num ? value.toInt() : int.tryParse('$value');
    return (n != null && n >= 2000 && n <= 2100) ? n : null;
  }
}
