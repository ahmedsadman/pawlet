import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pawlet/services/auth/attestation_service.dart';
import 'package:pawlet/services/llm/llm_mode.dart';
import 'package:pawlet/services/llm/llm_network_refresh.dart';
import 'package:pawlet/services/llm/prompt_bundle.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeAttestation implements AttestationService {
  int warmUps = 0;

  @override
  String get apiBase => 'https://api.test';

  @override
  Future<String> token({bool forceRefresh = false}) async => 'jwt';

  @override
  Future<void> warmUp() async => warmUps++;

  @override
  Future<void> reportRejected() async {}

  @override
  void close() {}
}

void main() {
  late _FakeAttestation attestation;
  late int bundleFetches;
  late int syncs;
  late PromptBundleStore bundles;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    attestation = _FakeAttestation();
    bundleFetches = 0;
    syncs = 0;
    bundles = PromptBundleStore(
      prefs: await SharedPreferences.getInstance(),
      apiBase: 'https://api.test',
      client: MockClient((_) async {
        bundleFetches++;
        return http.Response('', 503);
      }),
    );
  });

  Future<void> run(LlmMode mode) => refreshLlmNetworkState(
    mode: mode,
    attestation: attestation,
    promptBundles: bundles,
    syncIneligible: () async {
      // Yields first, so the count only lands if the sync is awaited.
      await Future<void>.delayed(Duration.zero);
      syncs++;
    },
  );

  test('proxy warms the session and syncs the ineligible flag', () async {
    await run(LlmMode.proxy);
    expect(attestation.warmUps, 1);
    expect(syncs, 1);
    expect(bundleFetches, 0);
  });

  test('byok refreshes the prompt bundle and never attests', () async {
    await run(LlmMode.byok);
    expect(bundleFetches, 1);
    expect(attestation.warmUps, 0);
  });

  test('none makes no network call at all', () async {
    await run(LlmMode.none);
    expect(bundleFetches, 0);
    expect(attestation.warmUps, 0);
    expect(syncs, 0);
  });
}
