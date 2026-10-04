import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/services/llm/llm_mode.dart';

void main() {
  group('resolveLlmMode', () {
    test('Play install with a server configured uses the proxy', () {
      expect(
        resolveLlmMode(
          fromPlay: true,
          apiBaseConfigured: true,
          hasKey: false,
          attestationIneligible: false,
        ),
        LlmMode.proxy,
      );
    });

    test('a stored key does not override the proxy', () {
      // The proxy already has an LLM; a personal key would be spent for
      // nothing and the section that sets it is hidden in this mode anyway.
      expect(
        resolveLlmMode(
          fromPlay: true,
          apiBaseConfigured: true,
          hasKey: true,
          attestationIneligible: false,
        ),
        LlmMode.proxy,
      );
    });

    test('a build with no server never reaches the proxy', () {
      expect(
        resolveLlmMode(
          fromPlay: true,
          apiBaseConfigured: false,
          hasKey: false,
          attestationIneligible: false,
        ),
        LlmMode.none,
      );
    });

    test('an attestation-ineligible Play install falls back to the key', () {
      expect(
        resolveLlmMode(
          fromPlay: true,
          apiBaseConfigured: true,
          hasKey: true,
          attestationIneligible: true,
        ),
        LlmMode.byok,
      );
    });

    test('an attestation-ineligible Play install with no key has no LLM', () {
      expect(
        resolveLlmMode(
          fromPlay: true,
          apiBaseConfigured: true,
          hasKey: false,
          attestationIneligible: true,
        ),
        LlmMode.none,
      );
    });

    test('a sideload install with a key calls OpenRouter directly', () {
      expect(
        resolveLlmMode(
          fromPlay: false,
          apiBaseConfigured: true,
          hasKey: true,
          attestationIneligible: false,
        ),
        LlmMode.byok,
      );
    });

    test('a sideload install with no key has no LLM', () {
      expect(
        resolveLlmMode(
          fromPlay: false,
          apiBaseConfigured: true,
          hasKey: false,
          attestationIneligible: false,
        ),
        LlmMode.none,
      );
    });
  });

  group('showsByokSection', () {
    test('hidden only in proxy mode', () {
      expect(LlmMode.proxy.showsByokSection, isFalse);
      expect(LlmMode.byok.showsByokSection, isTrue);
      expect(LlmMode.none.showsByokSection, isTrue);
    });
  });
}
