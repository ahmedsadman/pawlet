import 'package:flutter_test/flutter_test.dart';
import 'package:meowni/utils/bank_tokens.dart';

void main() {
  group('tokenize', () {
    test('lowercases and splits on non-alphanumeric separators', () {
      expect(tokenize('Unity Commercial Bank'), {'unity', 'commercial', 'bank'});
      expect(tokenize('AD-UCBL'), {'ad', 'ucbl'});
      expect(tokenize('  '), isEmpty);
    });
  });

  group('buildMatchTokens', () {
    test('merges main name and alternate names into a sorted token set', () {
      // "Unity Commercial Bank" registered as name="Unity Commercial",
      // matchers="UCB, Unity Bank".
      final tokens = buildMatchTokens('Unity Commercial', 'UCB, Unity Bank');
      expect(tokens, ['bank', 'commercial', 'ucb', 'unity']);
    });

    test('handles empty alternate names', () {
      expect(buildMatchTokens('City Bank', ''), ['bank', 'city']);
    });
  });

  group('senderMatchesTokens', () {
    final tokens = buildMatchTokens('Unity Commercial', 'UCB, Unity Bank');

    test('passes when any single sender word matches', () {
      expect(senderMatchesTokens('UCB', tokens), isTrue);
      expect(senderMatchesTokens('Unity Bank', tokens), isTrue);
      expect(senderMatchesTokens('AD-UCB', tokens), isTrue);
    });

    test('fails when no word matches', () {
      expect(senderMatchesTokens('Daraz', tokens), isFalse);
      expect(senderMatchesTokens('+8801234', tokens), isFalse);
    });

    test('empty token set never matches', () {
      expect(senderMatchesTokens('UCB', const []), isFalse);
    });
  });

  group('matchTokensFromColumn', () {
    test('round-trips the stored space-joined form', () {
      final tokens = buildMatchTokens('Unity Commercial', 'UCB, Unity Bank');
      expect(matchTokensFromColumn(tokens.join(' ')), tokens);
      expect(matchTokensFromColumn(null), isEmpty);
      expect(matchTokensFromColumn(''), isEmpty);
    });
  });
}
