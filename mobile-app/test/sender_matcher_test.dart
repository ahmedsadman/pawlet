import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/models/finance/bank.dart';
import 'package:pawlet/services/classification/sender_matcher.dart';

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
      expect(contentMatchesCardDigits('42 41', '42|41'), isFalse);
    });
  });

  group('contentLooselyMatchesCardDigits', () {
    test('matches a 3-digit-masked card against stored 4-digit groups', () {
      expect(
        contentLooselyMatchesCardDigits('bill 000***111 due', '0009|4111'),
        isTrue,
      );
    });

    test('matches a 6-digit BIN against a stored 4-digit prefix', () {
      expect(
        contentLooselyMatchesCardDigits('123465****1212', '1234|1212'),
        isTrue,
      );
    });

    test('matches a fully masked 4-digit card too', () {
      expect(
        contentLooselyMatchesCardDigits('stmt 4238****3241', '4238|3241'),
        isTrue,
      );
    });

    test('rejects a card differing at the 4th digit', () {
      // "0001" is not a prefix of the stored "0009" (nor the reverse), so this
      // is a different card and must not be attributed.
      expect(
        contentLooselyMatchesCardDigits('0001***4111', '0009|4111'),
        isFalse,
      );
    });

    test('rejects a wrong tail', () {
      expect(
        contentLooselyMatchesCardDigits('000***999', '0009|4111'),
        isFalse,
      );
    });

    test('rejects digit runs with no mask character', () {
      // Amounts and reference numbers must never read as a card.
      expect(
        contentLooselyMatchesCardDigits('Bal 1000 111.50', '0009|4111'),
        isFalse,
      );
      expect(
        contentLooselyMatchesCardDigits('4238 12 3241', '4238|3241'),
        isFalse, // the strict matcher already covers this form
      );
    });

    test('matches wherever the mask sits inside the gap', () {
      // Same gap width, mask at opposite ends: both are the same card.
      expect(
        contentLooselyMatchesCardDigits('card 000*1234567 111', '0009|4111'),
        isTrue,
      );
      expect(
        contentLooselyMatchesCardDigits('card 000 1234567*111', '0009|4111'),
        isTrue,
      );
    });

    test('finds the card when another number follows it', () {
      // The gap must not run past the card's own tail to a later number.
      expect(
        contentLooselyMatchesCardDigits('stmt 000***111 222', '0009|4111'),
        isTrue,
      );
    });

    test('finds the card when another number precedes it', () {
      // An unrelated leading number must not consume the card's head.
      for (final content in const [
        'Trx 500 000***111',
        'Due 8020 000***111',
        'Ref 123456 000***111',
        'BDT 1,250 000***111',
      ]) {
        expect(
          contentLooselyMatchesCardDigits(content, '0009|4111'),
          isTrue,
          reason: content,
        );
      }
    });

    test('finds the card across intermediate digit groups', () {
      expect(
        contentLooselyMatchesCardDigits('000-1234-XXXX-111', '0009|4111'),
        isTrue,
      );
      expect(
        contentLooselyMatchesCardDigits('000***1234***111', '0009|4111'),
        isTrue,
      );
    });

    test('does not pair digits across prose', () {
      // The gap may only hold digits, mask characters and separators. Without
      // that, a head and tail sitting on either side of words would pair up.
      expect(
        contentLooselyMatchesCardDigits('Card 000 ending *** 111', '0009|4111'),
        isFalse,
      );
    });

    test('requires the visible groups to align with the stored ends', () {
      // Containment means prefix/suffix, not "appears somewhere in". "009" sits
      // inside "0009" and "411" inside "4111", but neither is at the right end.
      expect(
        contentLooselyMatchesCardDigits('009***111', '0009|4111'),
        isFalse,
      );
      expect(
        contentLooselyMatchesCardDigits('000***411', '0009|4111'),
        isFalse,
      );
    });

    test('does not read a head out of the middle of a longer run', () {
      // "3456" sits inside "12345678"; treating it as a BIN would attribute a
      // card that is not there.
      expect(
        contentLooselyMatchesCardDigits('12345678****1212', '3456|1212'),
        isFalse,
      );
    });

    test('honours the 16-char gap window at its boundary', () {
      // Gap is everything between the two digit groups: "*" + 14 digits + " ".
      expect(
        contentLooselyMatchesCardDigits('000*12345678901234 111', '0009|4111'),
        isTrue, // gap is exactly 16
      );
      expect(
        contentLooselyMatchesCardDigits('000*123456789012345 111', '0009|4111'),
        isFalse, // gap is 17
      );
    });

    test('does not match a suffix-only message (out of scope)', () {
      expect(
        contentLooselyMatchesCardDigits(
          'Your card ****1234 charged',
          '0009|1234',
        ),
        isFalse,
      );
    });

    test('does not match a head longer than a 6-digit BIN', () {
      expect(
        contentLooselyMatchesCardDigits('1234567****1212', '1234|1212'),
        isFalse,
      );
    });

    test('stored digits that are not two 4-digit groups never match', () {
      // The UI enforces 4 digits per side, but backup-restored and legacy rows
      // reach this parser unchecked, and a short group would act as a wildcard.
      expect(contentLooselyMatchesCardDigits('999***888', '9|8'), isFalse);
      expect(contentLooselyMatchesCardDigits('000***111', '00|11'), isFalse);
      expect(
        contentLooselyMatchesCardDigits('000***111', '00099|41111'),
        isFalse,
      );
    });

    test('rejects fewer than 3 visible digits on either side', () {
      expect(contentLooselyMatchesCardDigits('00***111', '0009|4111'), isFalse);
      expect(contentLooselyMatchesCardDigits('000***11', '0009|4111'), isFalse);
    });

    test('null / malformed card digits never match', () {
      expect(contentLooselyMatchesCardDigits('000***111', null), isFalse);
      expect(contentLooselyMatchesCardDigits('000***111', '0009'), isFalse);
      expect(contentLooselyMatchesCardDigits('000***111', '|4111'), isFalse);
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

    test('attaches a 3-digit-masked card to the one card it fits', () {
      final card = _bank(
        'Brac Card',
        accountType: 'credit',
        cardDigits: '0009|4111',
      );
      expect(matchCreditCardInContent('stmt 000***111 due', [mtb, card]), card);
      expect(gateBanks('RANDOM', 'stmt 000***111 due', [mtb, card]), [card]);
    });

    test('prefers an exact 4-digit match over a loose one', () {
      final loose = _bank(
        'Brac Card',
        accountType: 'credit',
        cardDigits: '0009|4111',
      );
      // Content carries a loose "000***111" and an exact "4238 12 3241". The
      // exact card's form is deliberately mask-free so it does NOT also match
      // loosely — otherwise the loose pass would see two candidates and return
      // null on ambiguity, and this test would pass without the exact pass
      // having won anything.
      const content = 'card 000***111 paid via 4238 12 3241';
      expect(matchCreditCardInContent(content, [loose, ebl]), ebl);
      expect(matchCreditCardInContent(content, [ebl, loose]), ebl);
    });

    test('refuses to guess when two cards both loosely match', () {
      final a = _bank('A', accountType: 'credit', cardDigits: '0009|4111');
      final b = _bank('B', accountType: 'credit', cardDigits: '0008|3111');
      expect(matchCreditCardInContent('stmt 000***111', [a, b]), isNull);
    });

    test('the gate stays permissive where the writer refuses to guess', () {
      // A false positive at the gate costs one LLM call; a false negative loses
      // the bill. So the gate lets an ambiguous card through even though
      // matchCreditCardInContent declines to attribute it.
      final a = _bank('A', accountType: 'credit', cardDigits: '0009|4111');
      final b = _bank('B', accountType: 'credit', cardDigits: '0008|3111');
      expect(gateBanks('RANDOM', 'stmt 000***111', [a, b]), [a, b]);
      expect(matchCreditCardInContent('stmt 000***111', [a, b]), isNull);
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
