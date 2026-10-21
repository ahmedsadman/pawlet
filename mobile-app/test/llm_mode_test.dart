import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/services/llm/llm_mode.dart';

void main() {
  group('resolveLlmMode', () {
    test('Play install with a server configured uses the proxy', () {
      expect(
        resolveLlmMode(
          fromPlay: true,
          proxyConfigured: true,
          hasKey: false,
          attestationIneligible: false,
          llmEnabled: true,
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
          proxyConfigured: true,
          hasKey: true,
          attestationIneligible: false,
          llmEnabled: true,
        ),
        LlmMode.proxy,
      );
    });

    test('a build with no server never reaches the proxy', () {
      expect(
        resolveLlmMode(
          fromPlay: true,
          proxyConfigured: false,
          hasKey: false,
          attestationIneligible: false,
          llmEnabled: true,
        ),
        LlmMode.none,
      );
    });

    test('an attestation-ineligible Play install falls back to the key', () {
      expect(
        resolveLlmMode(
          fromPlay: true,
          proxyConfigured: true,
          hasKey: true,
          attestationIneligible: true,
          llmEnabled: true,
        ),
        LlmMode.byok,
      );
    });

    test('an attestation-ineligible Play install with no key has no LLM', () {
      expect(
        resolveLlmMode(
          fromPlay: true,
          proxyConfigured: true,
          hasKey: false,
          attestationIneligible: true,
          llmEnabled: true,
        ),
        LlmMode.none,
      );
    });

    test('a sideload install with a key calls OpenRouter directly', () {
      expect(
        resolveLlmMode(
          fromPlay: false,
          proxyConfigured: true,
          hasKey: true,
          attestationIneligible: false,
          llmEnabled: true,
        ),
        LlmMode.byok,
      );
    });

    test('a sideload install with no key has no LLM', () {
      expect(
        resolveLlmMode(
          fromPlay: false,
          proxyConfigured: true,
          hasKey: false,
          attestationIneligible: false,
          llmEnabled: true,
        ),
        LlmMode.none,
      );
    });

    test('resolves optedOut when proxy-eligible and llmEnabled is false', () {
      expect(
        resolveLlmMode(
          fromPlay: true,
          proxyConfigured: true,
          hasKey: true,
          attestationIneligible: false,
          llmEnabled: false,
        ),
        LlmMode.optedOut,
      );
    });

    test('llmEnabled is ignored outside proxy eligibility', () {
      // The switch belongs to the proxy session; a BYOK user turns the LLM
      // off by removing the key.
      for (final (fromPlay, ineligible, hasKey, expected) in const [
        (false, false, true, LlmMode.byok),
        (false, false, false, LlmMode.none),
        (true, true, true, LlmMode.byok),
        (true, true, false, LlmMode.none),
      ]) {
        expect(
          resolveLlmMode(
            fromPlay: fromPlay,
            proxyConfigured: true,
            hasKey: hasKey,
            attestationIneligible: ineligible,
            llmEnabled: false,
          ),
          expected,
        );
      }
    });
  });

  group('showsByokSection', () {
    test('hidden in proxy mode', () {
      expect(LlmMode.proxy.showsByokSection, isFalse);
      expect(LlmMode.byok.showsByokSection, isTrue);
      expect(LlmMode.none.showsByokSection, isTrue);
    });

    test('optedOut hides the BYOK section', () {
      expect(LlmMode.optedOut.showsByokSection, isFalse);
    });
  });

  test('heartbeatGroup maps every mode', () {
    expect(
      {for (final m in LlmMode.values) m: m.heartbeatGroup},
      {
        LlmMode.proxy: 'on',
        LlmMode.optedOut: 'off',
        LlmMode.byok: 'byok',
        LlmMode.none: 'none',
      },
    );
  });
}
