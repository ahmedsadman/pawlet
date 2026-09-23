import 'package:flutter_test/flutter_test.dart';
import 'package:meowni/models/finance/bank.dart';
import 'package:meowni/services/classification/sender_matcher.dart';

Bank _bank(
  String name, {
  String accountType = 'deposit',
  List<String> matchers = const [],
  String? cardDigits,
}) => Bank(
  id: name.hashCode,
  name: name,
  accountType: accountType,
  cardDigits: cardDigits,
  matchers: matchers,
  createdAt: DateTime(2026, 1, 1),
);

void main() {
  // Mutual Trust Bank ("mtb") and Eastern Bank Limited ("ebl","eastern bank limited").
  final mtb = _bank('Mutual Trust Bank', matchers: const ['mtb']);
  final ebl = _bank(
    'Eastern Bank Limited',
    accountType: 'credit',
    cardDigits: '4238|3241',
    matchers: const ['ebl', 'eastern bank limited'],
  );

  group('senderMatchesBank', () {
    test('matches when a matcher is a substring of the sender', () {
      expect(senderMatchesBank('MTBLBD', mtb), isTrue); // contains "mtb"
      expect(senderMatchesBank('AD-EBL', ebl), isTrue); // contains "ebl"
      expect(
        senderMatchesBank('EASTERN BANK LIMITED', ebl),
        isTrue, // the longer matcher too
      );
      expect(senderMatchesBank('ebl', ebl), isTrue); // case-insensitive
    });

    test('does not match unrelated senders', () {
      expect(senderMatchesBank('Daraz', mtb), isFalse);
      expect(senderMatchesBank('+8801234', ebl), isFalse);
      expect(senderMatchesBank('SCB', mtb), isFalse);
    });
  });

  group('contentMatchesCardDigits', () {
    test('matches masked and spaced card numbers within the window', () {
      expect(
        contentMatchesCardDigits('bill 4238****3241 due', '4238|3241'),
        isTrue,
      );
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

  group('singleSenderMatch', () {
    test('returns the one bank whose matcher hits the sender', () {
      expect(singleSenderMatch('AD-MTB', [mtb, ebl]), mtb);
    });

    test('returns null when nothing matches', () {
      expect(singleSenderMatch('Daraz', [mtb, ebl]), isNull);
    });

    test('returns null when the sender is ambiguous (multiple matches)', () {
      final eblTwin = _bank('EBL Savings', matchers: const ['ebl']);
      expect(singleSenderMatch('EBL', [ebl, eblTwin]), isNull);
    });
  });

  group('gateBanks / matchCreditCardInContent', () {
    test('gates in by a sender substring match', () {
      expect(gateBanks('AD-MTB', 'anything', [mtb, ebl]), [mtb]);
    });

    test(
      'gates in a credit card by digits in content even if sender differs',
      () {
        final gated = gateBanks('RANDOM', 'stmt 4238****3241', [mtb, ebl]);
        expect(gated, [ebl]);
        expect(matchCreditCardInContent('stmt 4238****3241', [mtb, ebl]), ebl);
      },
    );

    test('gates out when nothing matches', () {
      expect(gateBanks('Daraz', 'win a prize', [mtb, ebl]), isEmpty);
    });

    test('empty banks list gates nothing in', () {
      expect(gateBanks('MTB', '4238****3241', const []), isEmpty);
    });

    test('a bank with no matchers never matches by sender', () {
      final blank = _bank('Nameless');
      expect(senderMatchesBank('MTB', blank), isFalse);
      expect(gateBanks('MTB', 'x', [blank]), isEmpty);
    });

    test('a deposit bank carrying card digits is not gated by content', () {
      final depositWithDigits = _bank(
        'Odd Deposit',
        cardDigits: '4238|3241', // deposit type → card fallback must not apply
      );
      expect(
        matchCreditCardInContent('4238****3241', [depositWithDigits]),
        isNull,
      );
      expect(gateBanks('RANDOM', '4238****3241', [depositWithDigits]), isEmpty);
    });
  });
}
