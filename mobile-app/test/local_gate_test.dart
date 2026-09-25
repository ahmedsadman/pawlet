import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/services/classification/local_gate.dart';
import 'package:pawlet/services/classification/local_model.dart';
import 'package:pawlet/services/llm/llm_provider.dart';

LocalSpan _span(String ent, String text, double conf, {int start = 0}) =>
    LocalSpan(
      entity: ent,
      text: text,
      confidence: conf,
      start: start,
      end: start + text.length,
    );

void main() {
  const bdt = 'BDT';

  test('low class confidence rejects', () {
    final r = decideLocal(
      const LocalPrediction(
        classLabel: 'expense',
        classConfidence: 0.5,
        spans: [],
      ),
      currency: bdt,
      content: 'debit 50 BDT',
    );
    expect(r.accepted, isFalse);
  });

  test('confident null accepts as none (no LLM)', () {
    final r = decideLocal(
      const LocalPrediction(
        classLabel: 'null',
        classConfidence: 0.97,
        spans: [],
      ),
      currency: bdt,
      content: 'Your OTP is 1234',
    );
    expect(r.accepted, isTrue);
    expect(r.result!.category, SmsCategory.none);
  });

  test('confident transaction with strong AMOUNT accepts', () {
    const content = 'Debited BDT 50 Balance BDT 2000';
    final r = decideLocal(
      LocalPrediction(
        classLabel: 'expense',
        classConfidence: 0.95,
        spans: [
          _span('AMOUNT', '50', 0.98, start: content.indexOf('50')),
          _span('BALANCE', '2000', 0.92, start: content.indexOf('2000')),
        ],
      ),
      currency: bdt,
      content: content,
    );
    expect(r.accepted, isTrue);
    expect(r.result!.category, SmsCategory.transaction);
    expect(r.result!.transaction!.amount, '50');
    expect(r.result!.transaction!.balance, '2000');
    expect(r.result!.transaction!.transactionType, 'expense');
    expect(r.result!.transaction!.originalCurrency, bdt);
    expect(r.result!.transaction!.originalAmount, '50');
  });

  test('NERc below threshold (weak span) rejects', () {
    const content = 'Debited BDT 50 Balance BDT 2000';
    final r = decideLocal(
      LocalPrediction(
        classLabel: 'expense',
        classConfidence: 0.95,
        spans: [
          _span('AMOUNT', '50', 0.98, start: content.indexOf('50')),
          _span('BALANCE', '2000', 0.60, start: content.indexOf('2000')),
        ],
      ),
      currency: bdt,
      content: content,
    );
    expect(r.accepted, isFalse);
  });

  test('bill: spurious low-conf span drops NERc and rejects (issue example)', () {
    // Mirrors the plan's [224] example: NERc = 0.76 < 0.90.
    const content =
        'Monthly bill 423800******3241 AUG2026; Total Due: BDT 4924.35, '
        'Min Due: BDT 4833.35';
    final r = decideLocal(
      LocalPrediction(
        classLabel: 'bill',
        classConfidence: 0.99,
        spans: [
          _span('BALANCE', '4833', 0.76, start: content.indexOf('4833')),
          _span('DUE', '4924.35', 1.00, start: content.indexOf('4924.35')),
          _span('PERIOD', 'AUG2026', 1.00, start: content.indexOf('AUG2026')),
        ],
      ),
      currency: bdt,
      content: content,
    );
    expect(r.accepted, isFalse);
  });

  test('bill: multiple DUE spans -> highest confidence wins', () {
    const content = 'Total Due: BDT 4924.35 AUG2026';
    final r = decideLocal(
      LocalPrediction(
        classLabel: 'bill',
        classConfidence: 0.99,
        spans: [
          _span('DUE', '4924.35', 1.00, start: content.indexOf('4924.35')),
          _span('DUE', '.35', 0.95, start: content.indexOf('.35')),
          _span('PERIOD', 'AUG2026', 0.99, start: content.indexOf('AUG2026')),
        ],
      ),
      currency: bdt,
      content: content,
    );
    expect(r.accepted, isTrue);
    expect(r.result!.bill!.normalizedTotalDue, '4924.35');
    expect(r.result!.bill!.statementMonth, 8);
    expect(r.result!.bill!.statementYear, 2026);
    expect(r.result!.bill!.originalCurrency, bdt);
  });

  test('bill: unparseable period is dropped but bill still accepts', () {
    const content = 'Total Due: BDT 4924.35 for last cycle';
    final r = decideLocal(
      LocalPrediction(
        classLabel: 'bill',
        classConfidence: 0.99,
        spans: [
          _span('DUE', '4924.35', 0.98, start: content.indexOf('4924.35')),
          _span('PERIOD', 'last cycle', 0.95, start: content.indexOf('last')),
        ],
      ),
      currency: bdt,
      content: content,
    );
    expect(r.accepted, isTrue);
    expect(r.result!.bill!.normalizedTotalDue, '4924.35');
    expect(r.result!.bill!.statementMonth, isNull);
    expect(r.result!.bill!.statementYear, isNull);
  });

  test('transaction missing AMOUNT rejects', () {
    const content = 'Balance BDT 2000';
    final r = decideLocal(
      LocalPrediction(
        classLabel: 'income',
        classConfidence: 0.95,
        spans: [_span('BALANCE', '2000', 0.99, start: content.indexOf('2000'))],
      ),
      currency: bdt,
      content: content,
    );
    expect(r.accepted, isFalse);
  });

  test('bill missing DUE rejects', () {
    const content = 'Statement ready AUG2026';
    final r = decideLocal(
      LocalPrediction(
        classLabel: 'bill',
        classConfidence: 0.99,
        spans: [_span('PERIOD', 'AUG2026', 0.99, start: content.indexOf('AUG'))],
      ),
      currency: bdt,
      content: content,
    );
    expect(r.accepted, isFalse);
  });

  test('empty spans on transaction rejects', () {
    final r = decideLocal(
      const LocalPrediction(
        classLabel: 'expense',
        classConfidence: 0.99,
        spans: [],
      ),
      currency: bdt,
      content: 'some debit',
    );
    expect(r.accepted, isFalse);
  });

  test('foreign currency rejects (local cannot convert FX)', () {
    const content = 'POS Transaction USD 100';
    final r = decideLocal(
      LocalPrediction(
        classLabel: 'expense',
        classConfidence: 0.95,
        spans: [_span('AMOUNT', '100', 0.99, start: content.indexOf('100'))],
      ),
      currency: bdt, // user currency BDT, SMS is USD
      content: content,
    );
    expect(r.accepted, isFalse);
  });

  test('same currency accepts (no FX conversion needed)', () {
    const content = 'Debited BDT 100';
    final r = decideLocal(
      LocalPrediction(
        classLabel: 'expense',
        classConfidence: 0.95,
        spans: [_span('AMOUNT', '100', 0.99, start: content.indexOf('100'))],
      ),
      currency: bdt,
      content: content,
    );
    expect(r.accepted, isTrue);
  });
}
