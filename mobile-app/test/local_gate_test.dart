import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/services/classification/local_classifier.dart';
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

  test(
    'bill: spurious low-conf span drops NERc and rejects (issue example)',
    () {
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
    },
  );

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
        spans: [
          _span('PERIOD', 'AUG2026', 0.99, start: content.indexOf('AUG')),
        ],
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

  test('non-BDT/USD foreign currency (EUR) also rejects', () {
    const content = 'Charged EUR 100 at store';
    final r = decideLocal(
      LocalPrediction(
        classLabel: 'expense',
        classConfidence: 0.95,
        spans: [_span('AMOUNT', '100', 0.99, start: content.indexOf('100'))],
      ),
      currency: bdt,
      content: content,
    );
    expect(r.accepted, isFalse);
  });

  test('bill: out-of-range year drops the whole period, still accepts', () {
    const content = 'Total Due: BDT 4924.35 AUG 1899';
    final r = decideLocal(
      LocalPrediction(
        classLabel: 'bill',
        classConfidence: 0.99,
        spans: [
          _span('DUE', '4924.35', 0.98, start: content.indexOf('4924.35')),
          _span('PERIOD', 'AUG 1899', 0.95, start: content.indexOf('AUG 1899')),
        ],
      ),
      currency: bdt,
      content: content,
    );
    expect(r.accepted, isTrue);
    expect(r.result!.bill!.statementMonth, isNull);
    expect(r.result!.bill!.statementYear, isNull);
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

  test('USD transaction converts to BDT when a rate is provided', () {
    const content = 'POS Transaction USD 100';
    final r = decideLocal(
      LocalPrediction(
        classLabel: 'expense',
        classConfidence: 0.95,
        spans: [_span('AMOUNT', '100', 0.99, start: content.indexOf('100'))],
      ),
      currency: bdt,
      content: content,
      usdToBdtRate: Decimal.parse('120'),
    );
    expect(r.accepted, isTrue);
    expect(r.result!.transaction!.amount, '12000');
    expect(r.result!.transaction!.originalAmount, '100');
    expect(r.result!.transaction!.originalCurrency, 'USD');
  });

  test('USD bill converts to BDT when a rate is provided', () {
    const content = 'Total Due: USD 50.5 AUG2026';
    final r = decideLocal(
      LocalPrediction(
        classLabel: 'bill',
        classConfidence: 0.99,
        spans: [
          _span('DUE', '50.5', 0.99, start: content.indexOf('50.5')),
          _span('PERIOD', 'AUG2026', 0.99, start: content.indexOf('AUG2026')),
        ],
      ),
      currency: bdt,
      content: content,
      usdToBdtRate: Decimal.parse('120'),
    );
    expect(r.accepted, isTrue);
    expect(r.result!.bill!.normalizedTotalDue, '6060');
    expect(r.result!.bill!.originalAmount, '50.5');
    expect(r.result!.bill!.originalCurrency, 'USD');
    expect(r.result!.bill!.statementMonth, 8);
  });

  test('USD still rejects when no rate is available (LLM fallback)', () {
    const content = 'POS Transaction USD 100';
    final r = decideLocal(
      LocalPrediction(
        classLabel: 'expense',
        classConfidence: 0.95,
        spans: [_span('AMOUNT', '100', 0.99, start: content.indexOf('100'))],
      ),
      currency: bdt,
      content: content,
      // usdToBdtRate omitted → null.
    );
    expect(r.accepted, isFalse);
  });

  test('EUR rejects even when a USD rate is available', () {
    const content = 'Charged EUR 100 at store';
    final r = decideLocal(
      LocalPrediction(
        classLabel: 'expense',
        classConfidence: 0.95,
        spans: [_span('AMOUNT', '100', 0.99, start: content.indexOf('100'))],
      ),
      currency: bdt,
      content: content,
      usdToBdtRate: Decimal.parse('120'),
    );
    expect(r.accepted, isFalse);
  });

  test('USD conversion keeps cents and rounds to 2 dp', () {
    const content = 'POS Transaction USD 10.5';
    final r = decideLocal(
      LocalPrediction(
        classLabel: 'expense',
        classConfidence: 0.95,
        spans: [_span('AMOUNT', '10.5', 0.99, start: content.indexOf('10.5'))],
      ),
      currency: bdt,
      content: content,
      usdToBdtRate: Decimal.parse('120.75'),
    );
    expect(r.accepted, isTrue);
    // 10.5 * 120.75 = 1267.875 → 1267.88 (round half-up to 2 dp).
    expect(r.result!.transaction!.amount, '1267.88');
    expect(r.result!.transaction!.originalAmount, '10.5');
  });

  test('BDT still converts to itself unchanged when a rate is present', () {
    const content = 'Debited BDT 100';
    final r = decideLocal(
      LocalPrediction(
        classLabel: 'expense',
        classConfidence: 0.95,
        spans: [_span('AMOUNT', '100', 0.99, start: content.indexOf('100'))],
      ),
      currency: bdt,
      content: content,
      usdToBdtRate: Decimal.parse('120'),
    );
    expect(r.accepted, isTrue);
    expect(r.result!.transaction!.amount, '100');
    expect(r.result!.transaction!.originalCurrency, 'BDT');
  });

  group('runLocalModel', () {
    test('is unavailable, not a rejection, when no model is wired', () async {
      final r = await runLocalModel('debit 50', local: null, currency: 'BDT');
      expect(r.accepted, isFalse);
      expect(r.ran, isFalse);
      expect(r.declined, isFalse);
    });

    test(
      'is unavailable, not a rejection, when the model returns null',
      () async {
        final r = await runLocalModel(
          'debit 50',
          local: _StubLocal(null),
          currency: 'BDT',
        );
        expect(r.accepted, isFalse);
        expect(r.ran, isFalse);
        expect(r.declined, isFalse);
      },
    );

    test('a low-confidence prediction declines — the model ran', () async {
      final r = await runLocalModel(
        'debit 50',
        local: _StubLocal(
          const LocalPrediction(
            classLabel: 'expense',
            classConfidence: 0.4,
            spans: [],
          ),
        ),
        currency: 'BDT',
      );
      expect(r.accepted, isFalse);
      expect(r.ran, isTrue);
      expect(r.declined, isTrue);
    });

    test('accepts a confident prediction', () async {
      const content = 'debit 50 BDT';
      final r = await runLocalModel(
        content,
        local: _StubLocal(
          LocalPrediction(
            classLabel: 'expense',
            classConfidence: 0.97,
            spans: [_span('AMOUNT', '50', 0.96, start: content.indexOf('50'))],
          ),
        ),
        currency: 'BDT',
      );
      expect(r.accepted, isTrue);
      expect(r.declined, isFalse);
      expect(r.result!.transaction!.amount, '50');
    });

    test('threads the USD rate through to the conversion', () async {
      const content = 'POS Transaction USD 100';
      final r = await runLocalModel(
        content,
        local: _StubLocal(
          LocalPrediction(
            classLabel: 'expense',
            classConfidence: 0.97,
            spans: [
              _span('AMOUNT', '100', 0.96, start: content.indexOf('100')),
            ],
          ),
        ),
        currency: 'BDT',
        usdRate: Decimal.parse('120'),
      );
      expect(r.accepted, isTrue);
      expect(r.result!.transaction!.amount, '12000');
      expect(r.result!.transaction!.originalCurrency, 'USD');
    });
  });

  group('GateAcceptance.ungated', () {
    test('accepts a prediction below the class-confidence threshold', () {
      final r = decideLocal(
        LocalPrediction(
          classLabel: 'expense',
          classConfidence: 0.10,
          spans: [_span('AMOUNT', '50', 0.95, start: 6)],
        ),
        currency: 'BDT',
        content: 'debit 50 BDT',
        acceptance: GateAcceptance.ungated,
      );
      expect(r.accepted, isTrue);
      expect(r.result!.transaction!.amount, '50');
    });

    test('accepts a prediction whose weakest span is below threshold', () {
      final r = decideLocal(
        LocalPrediction(
          classLabel: 'expense',
          classConfidence: 0.99,
          spans: [_span('AMOUNT', '50', 0.05, start: 6)],
        ),
        currency: 'BDT',
        content: 'debit 50 BDT',
        acceptance: GateAcceptance.ungated,
      );
      expect(r.accepted, isTrue);
    });

    test('an unconfident null label still means ignore', () {
      final r = decideLocal(
        LocalPrediction(
          classLabel: 'null',
          classConfidence: 0.02,
          spans: const [],
        ),
        currency: 'BDT',
        content: 'your OTP is 1234',
        acceptance: GateAcceptance.ungated,
      );
      expect(r.accepted, isTrue);
      expect(r.result!.category, SmsCategory.none);
    });

    test(
      'still rejects a missing AMOUNT span — structural, not confidence',
      () {
        final r = decideLocal(
          LocalPrediction(
            classLabel: 'expense',
            classConfidence: 0.99,
            spans: [_span('BALANCE', '900', 0.99, start: 20)],
          ),
          currency: 'BDT',
          content: 'debit done, balance 900',
          acceptance: GateAcceptance.ungated,
        );
        expect(r.accepted, isFalse);
        expect(r.declined, isTrue);
      },
    );

    test('still rejects an unparseable amount', () {
      final r = decideLocal(
        LocalPrediction(
          classLabel: 'expense',
          classConfidence: 0.99,
          spans: [_span('AMOUNT', 'lots', 0.99, start: 6)],
        ),
        currency: 'BDT',
        content: 'debit lots BDT',
        acceptance: GateAcceptance.ungated,
      );
      expect(r.accepted, isFalse);
    });

    test('still rejects a foreign currency with no conversion path', () {
      final r = decideLocal(
        LocalPrediction(
          classLabel: 'expense',
          classConfidence: 0.99,
          spans: [_span('AMOUNT', '50', 0.99, start: 6)],
        ),
        currency: 'BDT',
        content: 'debit 50 EUR',
        acceptance: GateAcceptance.ungated,
      );
      expect(r.accepted, isFalse);
    });

    test('runLocalModel forwards the acceptance', () async {
      final r = await runLocalModel(
        'debit 50 BDT',
        local: _StubLocal(
          LocalPrediction(
            classLabel: 'expense',
            classConfidence: 0.10,
            spans: [_span('AMOUNT', '50', 0.10, start: 6)],
          ),
        ),
        currency: 'BDT',
        acceptance: GateAcceptance.ungated,
      );
      expect(r.accepted, isTrue);
    });
  });
}

class _StubLocal implements LocalClassifier {
  _StubLocal(this.prediction);
  final LocalPrediction? prediction;

  @override
  Future<LocalPrediction?> infer(String content) async => prediction;
}
