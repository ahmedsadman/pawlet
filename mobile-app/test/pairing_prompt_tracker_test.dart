import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/state/pairing_providers.dart';

void main() {
  test('prompts on the first non-empty list, not on an empty one', () {
    final t = PairingPromptTracker();
    expect(t.shouldPrompt(const []), isFalse);
    expect(t.shouldPrompt(const ['1-2']), isTrue);
  });

  test('prompts again only when a new key appears', () {
    final t = PairingPromptTracker();
    expect(t.shouldPrompt(const ['1-2']), isTrue);
    expect(t.shouldPrompt(const ['1-2']), isFalse);
    expect(t.shouldPrompt(const []), isFalse);
    expect(t.shouldPrompt(const ['1-2']), isFalse);
    expect(t.shouldPrompt(const ['1-2', '3-4']), isTrue);
  });

  test('absorbs new keys silently while reviewing', () {
    final t = PairingPromptTracker()..reviewing = true;
    expect(t.shouldPrompt(const ['1-2']), isFalse);
    t.reviewing = false;
    expect(t.shouldPrompt(const ['1-2']), isFalse);
  });
}
