import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/models/finance/bank.dart';
import 'package:pawlet/services/bulk_import/bulk_gate.dart';

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
  createdAt: DateTime(2024),
);

void main() {
  test('a catalog sender passes even with no banks set up', () {
    final match = bulkGate('EBL', 'Your a/c debited 500', const []);
    expect(match, isNotNull);
    expect(match!.catalogEntry?.label, 'EBL');
  });

  test('an unknown sender does not pass', () {
    expect(bulkGate('16247', 'Your OTP is 4321', const []), isNull);
  });

  test('an existing bank sender passes with no catalog entry attached', () {
    final banks = [
      _bank('My Credit Union', matchers: const ['mycu']),
    ];
    final match = bulkGate('MYCU-ALERT', 'debited 100', banks);
    expect(match, isNotNull);
    // Already a known bank — nothing to create.
    expect(match!.catalogEntry, isNull);
  });

  test('a card whose digits appear in the body passes', () {
    final banks = [
      _bank('City Bank', accountType: 'credit', cardDigits: '4238|3241'),
    ];
    final match = bulkGate(
      'BANKMSG',
      'Card 4238****3241 used for 90.00',
      banks,
    );
    expect(match, isNotNull);
    expect(match!.catalogEntry, isNull);
  });

  test('a partially masked card still passes the gate', () {
    final banks = [
      _bank('City Bank', accountType: 'credit', cardDigits: '0009|4111'),
    ];
    expect(bulkGate('BANKMSG', 'Trx on 000***111 for 90.00', banks), isNotNull);
  });

  test('an existing bank wins over the catalog so no duplicate is created', () {
    // The user already added EBL (perhaps renamed); the gate must not hand back
    // a catalog entry that would trigger a second account.
    final banks = [
      _bank('EBL', matchers: const ['ebl']),
    ];
    expect(bulkGate('EBL', 'debited 500', banks)!.catalogEntry, isNull);
  });

  test('an unrelated existing bank does not mask a catalog sender', () {
    final banks = [
      _bank('My Credit Union', matchers: const ['mycu']),
    ];
    expect(bulkGate('EBL', 'debited 500', banks)!.catalogEntry?.label, 'EBL');
  });

  test('an ambiguous catalog sender does not pass', () {
    expect(bulkGate('mtb-scb-gateway', 'debited 500', const []), isNull);
  });
}
