import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/services/classification/local_parsers.dart';

void main() {
  group('parseLocalAmount', () {
    test('strips commas but keeps the decimal', () {
      expect(parseLocalAmount('85,000'), '85000');
      expect(parseLocalAmount('4,924.35'), '4924.35');
    });

    test('strips currency symbols and letters', () {
      expect(parseLocalAmount('85,000Tk.'), '85000');
      expect(parseLocalAmount('BDT 4,924.35'), '4924.35');
      expect(parseLocalAmount('14500.5'), '14500.5');
    });

    test('collapses multiple dots to the first', () {
      expect(parseLocalAmount('1.234.56'), '1.23456');
    });

    test('returns null when no digits remain', () {
      expect(parseLocalAmount('BDT'), isNull);
      expect(parseLocalAmount(''), isNull);
      expect(parseLocalAmount('.'), isNull);
    });
  });

  group('parseStatementPeriod', () {
    test('real formats: MON YYYY and MONYYYY', () {
      expect(parseStatementPeriod('AUG 2026')!.month, 8);
      expect(parseStatementPeriod('AUG 2026')!.year, 2026);
      expect(parseStatementPeriod('AUG2026')!.month, 8);
      expect(parseStatementPeriod('JUL 2026')!.month, 7);
      expect(parseStatementPeriod('SEP2026')!.month, 9);
    });

    test('full month names', () {
      expect(parseStatementPeriod('September 2026')!.month, 9);
      expect(parseStatementPeriod('June 2026')!.month, 6);
    });

    test('numeric forms', () {
      expect(parseStatementPeriod('07-2026')!.month, 7);
      expect(parseStatementPeriod('10/2026')!.month, 10);
      expect(parseStatementPeriod('2026-09')!.month, 9);
      expect(parseStatementPeriod('04.2026')!.month, 4);
    });

    test('reversed alphabetic form', () {
      final p = parseStatementPeriod('2026 Jan');
      expect(p!.month, 1);
      expect(p.year, 2026);
    });

    test('unparseable returns null', () {
      expect(parseStatementPeriod('last month'), isNull);
      expect(parseStatementPeriod('13-2026'), isNull);
    });
  });

  group('currency detection', () {
    test('currencyToIso maps common tokens', () {
      expect(currencyToIso('Tk'), 'BDT');
      expect(currencyToIso('Tk.'), 'BDT');
      expect(currencyToIso('BDT'), 'BDT');
      expect(currencyToIso('USD'), 'USD');
      expect(currencyToIso(r'$'), 'USD');
      expect(currencyToIso('EUR'), isNull);
    });

    test('sniffCurrencyIso finds the token nearest the amount', () {
      const text = 'Total Due: BDT 4924.35';
      final start = text.indexOf('4924.35');
      expect(sniffCurrencyIso(text, start, start + 7), 'BDT');
    });

    test('sniffCurrencyIso finds USD symbol', () {
      const text = r'POS purchase $100 done';
      final start = text.indexOf('100');
      expect(sniffCurrencyIso(text, start, start + 3), 'USD');
    });

    test('sniffCurrencyIso returns null when no currency token is near', () {
      const text = 'Total Due 4924.35 only';
      final start = text.indexOf('4924.35');
      expect(sniffCurrencyIso(text, start, start + 7), isNull);
    });
  });
}
