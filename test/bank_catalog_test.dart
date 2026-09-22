import 'package:flutter_test/flutter_test.dart';
import 'package:meowni/data/bank_catalog.dart';

void main() {
  test('catalog exposes labels with lowercase matchers', () {
    expect(kBankCatalog, isNotEmpty);
    final ebl = bankCatalogByLabel('Eastern Bank Limited');
    expect(ebl, isNotNull);
    expect(ebl!.matchers, ['ebl', 'eastern bank limited']);
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
