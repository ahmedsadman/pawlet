import 'package:flutter_test/flutter_test.dart';
import 'package:meowni/services/llm/prompts.dart';

void main() {
  test('fusedJsonSchema is strict and pins the exact output shape', () {
    expect(fusedJsonSchema['strict'], true);
    expect(fusedJsonSchema['name'], isA<String>());

    final schema = fusedJsonSchema['schema'] as Map<String, Object?>;
    expect(schema['type'], 'object');
    expect(schema['additionalProperties'], false);
    expect(
      schema['required'],
      containsAll(<String>['category', 'transaction', 'bill']),
    );

    final props = schema['properties'] as Map<String, Object?>;
    final tx = props['transaction'] as Map<String, Object?>;
    expect(tx['additionalProperties'], false);
    expect(
      tx['required'],
      containsAll(<String>[
        'balance',
        'amount',
        'original_amount',
        'transaction_type',
        'original_currency',
      ]),
    );
  });
}
