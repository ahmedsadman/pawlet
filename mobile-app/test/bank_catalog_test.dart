import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/data/bank_catalog.dart';

void main() {
  test('catalog exposes labels with lowercase matchers', () {
    expect(kBankCatalog, isNotEmpty);
    // Labels are short display names; matchers (not the label) drive routing.
    final ebl = bankCatalogByLabel('EBL');
    expect(ebl, isNotNull);
    expect(ebl!.matchers, ['ebl', 'eastern bank limited']);
    expect(bankCatalogByLabel('MTB')!.matchers, ['mtb']);
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
}
