import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/utils/currency_format.dart';

void main() {
  group('formatAmount', () {
    test('groups thousands and forces two decimals with the currency', () {
      expect(formatAmount('1234.5', 'BDT'), '1,234.50 BDT');
      expect(formatAmount('1234567.89', 'USD'), '1,234,567.89 USD');
      expect(formatAmount('50', 'EUR'), '50.00 EUR');
    });

    test('handles negatives', () {
      expect(formatAmount('-1234.5', 'BDT'), '-1,234.50 BDT');
    });

    test('returns a placeholder for null or unparseable input', () {
      expect(formatAmount(null, 'BDT'), '—');
      expect(formatAmount('abc', 'BDT'), '—');
    });

    test('masks the value but keeps the currency when hidden', () {
      expect(formatAmount('1234.5', 'BDT', hidden: true), '**** BDT');
      // Even unparseable/null input masks (never leaks the placeholder).
      expect(formatAmount(null, 'USD', hidden: true), '**** USD');
    });
  });

  group('formatMoney', () {
    test('formats a numeric value with its currency', () {
      expect(formatMoney(1234.5, 'BDT'), '1,234.50 BDT');
    });

    test('masks the value but keeps the currency when hidden', () {
      expect(formatMoney(1234.5, 'BDT', hidden: true), '**** BDT');
    });
  });

  group('maskAmount', () {
    test('is the fixed four-star mask with the currency', () {
      expect(maskAmount('BDT'), '**** BDT');
      expect(maskedValue, '****');
    });
  });

  group('formatNumber', () {
    test('formats zero and grouped values', () {
      expect(formatNumber(0), '0.00');
      expect(formatNumber(1000000), '1,000,000.00');
    });
  });

  group('formatCompact', () {
    test('abbreviates thousands, millions and billions', () {
      expect(formatCompact(999), '999');
      expect(formatCompact(5000), '5K');
      expect(formatCompact(1200), '1.2K');
      expect(formatCompact(3400000), '3.4M');
      expect(formatCompact(2000000000), '2B');
    });
  });
}
