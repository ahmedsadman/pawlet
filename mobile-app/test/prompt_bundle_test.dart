import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pawlet/data/settings_repository.dart';
import 'package:pawlet/services/llm/prompt_bundle.dart';
import 'package:pawlet/services/llm/prompts.dart';
import 'package:shared_preferences/shared_preferences.dart';

String _bundleJson({
  int schemaVersion = 1,
  String system = 'server prompt',
  List<String> models = const ['srv/a'],
}) => jsonEncode({
  'bundleVersion': 1,
  'schemaVersion': schemaVersion,
  'systemPrompt': system,
  'userTemplate': PromptBundle.baked.userTemplate,
  'models': models,
  'jsonSchema': fusedJsonSchema,
});

void main() {
  group('PromptBundle', () {
    test('the baked copy is exactly what the app shipped with', () {
      final b = PromptBundle.baked;
      expect(b.systemPrompt, fusedSystemPrompt);
      expect(b.models, SettingsRepository.defaultLlmModels);
      expect(b.jsonSchema, fusedJsonSchema);
      expect(
        b.userContent(sender: 'EBL', content: 'debit 50', currency: 'BDT'),
        buildUserContent(sender: 'EBL', content: 'debit 50', currency: 'BDT'),
      );
    });

    test('placeholders inside the message are not substituted again', () {
      const tricky = 'pay {currency} to {sender}';
      expect(
        PromptBundle.baked.userContent(
          sender: 'EBL',
          content: tricky,
          currency: 'BDT',
        ),
        buildUserContent(sender: 'EBL', content: tricky, currency: 'BDT'),
      );
    });

    test('fromJson rejects what this build cannot use', () {
      expect(PromptBundle.fromJson(jsonDecode(_bundleJson())), isNotNull);
      expect(
        PromptBundle.fromJson(jsonDecode(_bundleJson(schemaVersion: 2))),
        isNull,
      );
      expect(
        PromptBundle.fromJson(jsonDecode(_bundleJson(models: const []))),
        isNull,
      );
      expect(PromptBundle.fromJson({'schemaVersion': 1}), isNull);
      expect(PromptBundle.fromJson('nope'), isNull);
    });
  });

  group('PromptBundleStore', () {
    late DateTime clock;
    late List<http.Request> requests;

    setUp(() => clock = DateTime(2026, 10, 8, 12));

    Future<PromptBundleStore> store(
      List<http.Response Function(http.Request)> answers, {
      String apiBase = 'https://api.test',
      Map<String, Object> prefs = const {},
    }) async {
      SharedPreferences.setMockInitialValues(prefs);
      requests = [];
      var i = 0;
      return PromptBundleStore(
        prefs: await SharedPreferences.getInstance(),
        apiBase: apiBase,
        now: () => clock,
        client: MockClient((req) async {
          requests.add(req);
          return answers[i++](req);
        }),
      );
    }

    http.Response ok(http.Request _) =>
        http.Response(_bundleJson(), 200, headers: {'etag': '"v1"'});

    test('serves the baked copy before anything was fetched', () async {
      final s = await store([]);
      expect(s.current().systemPrompt, fusedSystemPrompt);
    });

    test('a build with no server never fetches', () async {
      final s = await store([], apiBase: '');
      await s.refresh();
      expect(requests, isEmpty);
    });

    test('a fetched bundle is stored and served', () async {
      final s = await store([ok]);
      await s.refresh();
      expect(s.current().systemPrompt, 'server prompt');
      expect(s.current().models, ['srv/a']);
    });

    test('a fresh bundle is not fetched again', () async {
      final s = await store([ok]);
      await s.refresh();
      await s.refresh();
      expect(requests, hasLength(1));
    });

    test(
      'a stale bundle is revalidated with its ETag, and 304 keeps it',
      () async {
        final s = await store([ok, (_) => http.Response('', 304)]);
        await s.refresh();
        clock = clock.add(const Duration(hours: 25));
        await s.refresh();

        expect(requests.last.headers['If-None-Match'], '"v1"');
        expect(s.current().systemPrompt, 'server prompt');

        // The 304 restarted the TTL.
        await s.refresh();
        expect(requests, hasLength(2));
      },
    );

    test('an unknown schema version is not stored', () async {
      final s = await store([
        (_) => http.Response(_bundleJson(schemaVersion: 2), 200),
      ]);
      await s.refresh();
      expect(s.current().systemPrompt, fusedSystemPrompt);
    });

    test('a failed refresh keeps serving the cached bundle', () async {
      final s = await store([ok, (_) => throw http.ClientException('down')]);
      await s.refresh();
      clock = clock.add(const Duration(hours: 25));
      await s.refresh();
      expect(s.current().systemPrompt, 'server prompt');
    });

    test('a corrupt cached body falls back to the baked copy', () async {
      final s = await store([], prefs: {'prompt_bundle_body': '{not json'});
      expect(s.current().systemPrompt, fusedSystemPrompt);
    });
  });
}
