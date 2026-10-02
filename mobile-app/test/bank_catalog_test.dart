import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/data/bank_catalog.dart';

void main() {
  test('catalog exposes labels with lowercase matchers', () {
    expect(kBankCatalog, isNotEmpty);
    // Labels are short display names; matchers (not the label) drive routing.
    final ebl = bankCatalogByLabel('EBL');
    expect(ebl, isNotNull);
    expect(ebl!.matchers, ['ebl', 'eastern bank limited']);
    expect(bankCatalogByLabel('MTB')!.matchers, [
      'mtb',
      '01401-195498',
      '01401195498',
    ]);
    expect(bankCatalogByLabel('StanChart (SCB)')!.matchers, [
      'scb',
      'stanchart',
    ]);
    expect(bankCatalogByLabel('BRAC Bank')!.matchers, ['brac', 'brac-bank']);
    expect(
      bankCatalogByLabel('Eastern Bank Limited'),
      isNull,
    ); // old label gone
    expect(bankCatalogByLabel('Not A Bank'), isNull);
  });

  test('matchers column round-trips (matchers may contain spaces)', () {
    const matchers = ['scb', 'stanchart'];
    expect(matchersFromColumn(matchersToColumn(matchers)), matchers);

    const spaced = ['eastern bank limited', 'ebl'];
    expect(matchersFromColumn(matchersToColumn(spaced)), spaced);

    expect(matchersFromColumn(null), isEmpty);
    expect(matchersFromColumn(''), isEmpty);
  });

  test('singleCatalogMatch finds the bank behind a sender', () {
    expect(singleCatalogMatch('EBL')?.label, 'EBL');
    expect(singleCatalogMatch('city bank alert')?.label, 'City Bank');
    expect(singleCatalogMatch('CityTouch')?.label, 'City Bank');
    expect(singleCatalogMatch('CITYBANK')?.label, 'City Bank');
    expect(singleCatalogMatch('City_Amex')?.label, 'City Bank');
    // Trailing dot is part of the sender, not the matcher.
    expect(singleCatalogMatch('City Amex.')?.label, 'City Bank');
    expect(singleCatalogMatch('01401-195498')?.label, 'MTB');
    expect(singleCatalogMatch('01401195498')?.label, 'MTB');
    // Matching is case-insensitive on the sender side.
    expect(singleCatalogMatch('BRAC-BANK')?.label, 'BRAC Bank');
    // A matcher containing spaces still works as a substring.
    expect(singleCatalogMatch('EASTERN BANK LIMITED')?.label, 'EBL');
  });

  test('singleCatalogMatch is null for unknown senders', () {
    expect(singleCatalogMatch('16247'), isNull);
    expect(singleCatalogMatch('Amazon'), isNull);
    expect(singleCatalogMatch(''), isNull);
  });

  test('singleCatalogMatch refuses to guess when two banks match', () {
    // Contains both "mtb" and "scb" — no basis to pick one, so neither.
    expect(singleCatalogMatch('mtb-scb-gateway'), isNull);
  });

  test('singleCatalogMatch counts one entry once, not per matcher', () {
    // Both EBL matchers are present; that is still a single bank, not an
    // ambiguity.
    expect(singleCatalogMatch('EBL (Eastern Bank Limited)')?.label, 'EBL');
  });
}
