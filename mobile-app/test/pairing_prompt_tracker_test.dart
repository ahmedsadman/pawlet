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
    final t = PairingPromptTracker()..beginReview();
    expect(t.shouldPrompt(const ['1-2']), isFalse);
    t.endReview();
    expect(t.shouldPrompt(const ['1-2']), isFalse);
  });

  test('stays reviewing until every review has ended', () {
    final t = PairingPromptTracker()
      ..beginReview()
      ..beginReview();
    expect(t.reviewing, isTrue);
    t.endReview();
    expect(t.reviewing, isTrue);
    expect(t.shouldPrompt(const ['1-2']), isFalse);
    t.endReview();
    expect(t.reviewing, isFalse);
    expect(t.shouldPrompt(const ['3-4']), isTrue);
  });

  test('beginning a review calls the dismiss hook', () {
    final t = PairingPromptTracker();
    var dismissed = 0;
    t.dismissPrompt = () => dismissed++;
    t.beginReview();
    expect(dismissed, 1);
    expect(t.reviewing, isTrue);
  });

  test('beginning a review without a hook is fine', () {
    final t = PairingPromptTracker()..beginReview();
    expect(t.reviewing, isTrue);
  });
}
