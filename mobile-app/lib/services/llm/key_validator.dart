import 'dart:async';

import 'package:http/http.dart' as http;

/// Outcome of checking a user-supplied OpenRouter key.
enum KeyCheck {
  /// OpenRouter accepted it.
  valid,

  /// OpenRouter rejected it.
  invalid,

  /// The check never got an answer. Kept separate so a bad connection is never
  /// reported to the user as a bad key.
  unreachable,
}

/// Validates an OpenRouter key against the key-metadata endpoint, which returns
/// the key's own limits. A chat completion would also prove the key works, but
/// it would spend a request and take seconds behind a button the user is
/// watching.
class OpenRouterKeyValidator {
  OpenRouterKeyValidator({http.Client? client})
    : _client = client ?? http.Client(),
      _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;

  static const String endpoint = 'https://openrouter.ai/api/v1/key';

  /// Deliberately far shorter than the classify timeout: this runs in the
  /// foreground with a spinner on screen.
  static const Duration timeout = Duration(seconds: 15);

  /// Closes the internally-created client. No-op when the caller injected one.
  void close() {
    if (_ownsClient) _client.close();
  }

  Future<KeyCheck> check(String key) async {
    final trimmed = key.trim();
    if (trimmed.isEmpty) return KeyCheck.invalid;

    final http.Response resp;
    try {
      resp = await _client
          .get(
            Uri.parse(endpoint),
            headers: {'Authorization': 'Bearer $trimmed'},
          )
          .timeout(timeout);
    } on TimeoutException {
      return KeyCheck.unreachable;
    } catch (_) {
      return KeyCheck.unreachable;
    }

    if (resp.statusCode == 200) return KeyCheck.valid;
    if (resp.statusCode == 401 || resp.statusCode == 403) {
      return KeyCheck.invalid;
    }
    // A rate limit or a server error is a statement about OpenRouter, not
    // about the key.
    return KeyCheck.unreachable;
  }
}
