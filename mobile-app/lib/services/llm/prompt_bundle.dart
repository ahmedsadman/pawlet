// Private fields fed by named constructor params are assigned explicitly, as
// elsewhere in the app.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/settings_repository.dart';
import 'prompts.dart';

/// The prompt, model list and output schema a `byok` install calls OpenRouter
/// with. The server publishes the current one at `/v1/prompt-bundle`, so
/// prompt fixes reach sideload users without an app release.
class PromptBundle {
  const PromptBundle({
    required this.systemPrompt,
    required this.userTemplate,
    required this.models,
    required this.jsonSchema,
  });

  /// The only `schemaVersion` this build understands.
  static const int supportedSchemaVersion = 1;

  final String systemPrompt;

  /// User content with `{sender}`, `{content}` and `{currency}` placeholders.
  final String userTemplate;
  final List<String> models;
  final Map<String, Object?> jsonSchema;

  /// Shipped copy: first launch with no network, a build with no server, or a
  /// server bundle this build cannot read.
  static final PromptBundle baked = PromptBundle(
    systemPrompt: fusedSystemPrompt,
    userTemplate: buildUserContent(
      sender: '{sender}',
      content: '{content}',
      currency: '{currency}',
    ),
    models: SettingsRepository.defaultLlmModels,
    jsonSchema: fusedJsonSchema,
  );

  static final RegExp _placeholder = RegExp(r'\{(sender|content|currency)\}');

  /// One pass over the template, so a message that itself contains
  /// "{currency}" is never substituted a second time.
  String userContent({
    required String sender,
    required String content,
    required String currency,
  }) => userTemplate.replaceAllMapped(
    _placeholder,
    (m) => switch (m[1]) {
      'sender' => sender,
      'content' => content,
      _ => currency,
    },
  );

  /// Null for anything this build cannot use.
  static PromptBundle? fromJson(Object? raw) {
    if (raw is! Map) return null;
    if (raw['schemaVersion'] != supportedSchemaVersion) return null;
    final system = raw['systemPrompt'];
    final template = raw['userTemplate'];
    final models = raw['models'];
    final schema = raw['jsonSchema'];
    if (system is! String || template is! String) return null;
    if (models is! List || schema is! Map) return null;
    final modelList = models.whereType<String>().toList();
    if (modelList.isEmpty || modelList.length != models.length) return null;
    return PromptBundle(
      systemPrompt: system,
      userTemplate: template,
      models: modelList,
      jsonSchema: Map<String, Object?>.from(schema),
    );
  }
}

/// Fetches and caches the server's [PromptBundle] in SharedPreferences —
/// nothing in it is secret.
///
/// A classify never waits on this: [current] is synchronous and always
/// answers, with a stale bundle if need be, indefinitely while offline.
class PromptBundleStore {
  PromptBundleStore({
    required SharedPreferences prefs,
    required this.apiBase,
    http.Client? client,
    DateTime Function()? now,
  }) : _prefs = prefs,
       _client = client ?? http.Client(),
       _ownsClient = client == null,
       _now = now ?? DateTime.now;

  final SharedPreferences _prefs;
  final String apiBase;
  final http.Client _client;
  final bool _ownsClient;
  final DateTime Function() _now;

  static const Duration ttl = Duration(hours: 24);
  static const Duration fetchTimeout = Duration(seconds: 15);

  static const _kBody = 'prompt_bundle_body';
  static const _kEtag = 'prompt_bundle_etag';
  static const _kFetchedAt = 'prompt_bundle_fetched_at';

  void close() {
    if (_ownsClient) _client.close();
  }

  PromptBundle current() {
    final body = _prefs.getString(_kBody);
    if (body == null) return PromptBundle.baked;
    try {
      return PromptBundle.fromJson(jsonDecode(body)) ?? PromptBundle.baked;
    } catch (_) {
      return PromptBundle.baked;
    }
  }

  bool get _fresh {
    final at = _prefs.getInt(_kFetchedAt);
    if (at == null) return false;
    final age = _now().difference(DateTime.fromMillisecondsSinceEpoch(at));
    return age >= Duration.zero && age < ttl;
  }

  /// Background refresh. A no-op while the cached bundle is under [ttl] old.
  /// Never throws: any failure leaves the cached (or baked) bundle in place.
  Future<void> refresh() async {
    if (apiBase.isEmpty) return;
    try {
      if (_fresh) return;
      final etag = _prefs.getString(_kEtag);
      final body = _prefs.getString(_kBody);
      var canRevalidate = false;
      if (etag != null && body != null) {
        try {
          canRevalidate = PromptBundle.fromJson(jsonDecode(body)) != null;
        } catch (_) {
          // Corrupt cached body: fetch without revalidation.
        }
      }
      final resp = await _client
          .get(
            Uri.parse('$apiBase/v1/prompt-bundle'),
            headers: {if (canRevalidate) 'If-None-Match': etag!},
          )
          .timeout(fetchTimeout);

      if (resp.statusCode == 304) {
        await _markFetched();
        return;
      }
      if (resp.statusCode != 200) return;

      // Stored only if this build can read it, so a newer schema never
      // replaces a usable bundle.
      if (PromptBundle.fromJson(jsonDecode(resp.body)) != null) {
        await _prefs.setString(_kBody, resp.body);
        final newEtag = resp.headers['etag'];
        if (newEtag != null) {
          await _prefs.setString(_kEtag, newEtag);
        } else {
          await _prefs.remove(_kEtag);
        }
      }
      await _markFetched();
    } catch (_) {
      // Offline or the server is down: keep serving what we have.
    }
  }

  Future<void> _markFetched() =>
      _prefs.setInt(_kFetchedAt, _now().millisecondsSinceEpoch);
}
