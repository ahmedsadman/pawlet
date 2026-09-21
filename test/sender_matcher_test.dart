import 'package:flutter_test/flutter_test.dart';
import 'package:meowni/models/finance/bank.dart';
import 'package:meowni/services/classification/sender_matcher.dart';
import 'package:meowni/utils/bank_tokens.dart';

Bank _bank(
  String name, {
  String accountType = 'deposit',
  String alternates = '',
  String? cardDigits,
}) => Bank(
  id: name.hashCode,
  name: name,
  accountType: accountType,
  cardDigits: cardDigits,
  matchTokens: buildMatchTokens(name, alternates),
  createdAt: DateTime(2026, 1, 1),
);

void main() {
  final unity = _bank('Unity Commercial', alternates: 'UCB, Unity Bank');
  final ebl = _bank('EBL Credit Card', accountType: 'credit', cardDigits: '4238|3241');

  group('senderMatchesBank', () {
    test('matches when a sender word overlaps a bank token', () {
      expect(senderMatchesBank('UCB', unity), isTrue);
      expect(senderMatchesBank('Unity Bank', unity), isTrue);
      expect(senderMatchesBank('AD-UCB', unity), isTrue); // split on '-'
    });

    test('does not match unrelated or concatenated senders', () {
      expect(senderMatchesBank('Daraz', unity), isFalse);
      expect(senderMatchesBank('+8801234', unity), isFalse);
      // "BRACBANK" is one token; it only matches if registered as an alternate.
      expect(senderMatchesBank('BRACBANK', unity), isFalse);
    });
  });

  group('contentMatchesCardDigits', () {
    test('matches masked and spaced card numbers within the window', () {
      expect(contentMatchesCardDigits('bill 4238****3241 due', '4238|3241'), isTrue);
      expect(contentMatchesCardDigits('4238 12 3241', '4238|3241'), isTrue);
      expect(contentMatchesCardDigits('42383241', '4238|3241'), isTrue);
    });

    test('rejects a wrong tail or a too-long gap', () {
      expect(contentMatchesCardDigits('4238****9999', '4238|3241'), isFalse);
      expect(
        contentMatchesCardDigits('4238 aaaaaaaaaaaaaaaaaaaa 3241', '4238|3241'),
        isFalse, // gap > 16 chars
      );
    });

    test('null / malformed card digits never match', () {
      expect(contentMatchesCardDigits('4238 3241', null), isFalse);
      expect(contentMatchesCardDigits('4238 3241', '4238'), isFalse);
    });
  });

  group('gateBanks / matchCreditCardInContent', () {
    test('gates in by sender token', () {
      expect(gateBanks('UCB', 'anything', [unity, ebl]), [unity]);
    });

    test('gates in a credit card by digits in content even if sender differs', () {
      final gated = gateBanks('RANDOM', 'stmt 4238****3241', [unity, ebl]);
      expect(gated, [ebl]);
      expect(matchCreditCardInContent('stmt 4238****3241', [unity, ebl]), ebl);
    });

    test('gates out when nothing matches', () {
      expect(gateBanks('Daraz', 'win a prize', [unity, ebl]), isEmpty);
    });

    test('empty banks list gates nothing in', () {
      expect(gateBanks('UCB', '4238****3241', const []), isEmpty);
    });

    test('a bank with no match tokens never matches by sender', () {
      final blank = _bank('Nameless'); // buildMatchTokens still yields "nameless"
      expect(senderMatchesBank('UCB', blank), isFalse);
      expect(gateBanks('UCB', 'x', [blank]), isEmpty);
    });

    test('a deposit bank carrying card digits is not gated by content', () {
      final depositWithDigits = _bank(
        'Odd Deposit',
        cardDigits: '4238|3241', // deposit type → card fallback must not apply
      );
      expect(matchCreditCardInContent('4238****3241', [depositWithDigits]), isNull);
      expect(gateBanks('RANDOM', '4238****3241', [depositWithDigits]), isEmpty);
    });
  });
}
