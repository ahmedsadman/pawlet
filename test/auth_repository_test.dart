import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pawlet/data/auth_repository.dart';

class _MockStorage extends Mock implements FlutterSecureStorage {}

void main() {
  late _MockStorage storage;
  late AuthRepository repo;
  final store = <String, String>{};

  setUp(() {
    storage = _MockStorage();
    store.clear();
    when(
      () => storage.write(
        key: any(named: 'key'),
        value: any(named: 'value'),
      ),
    ).thenAnswer((inv) async {
      store[inv.namedArguments[#key] as String] =
          inv.namedArguments[#value] as String;
    });
    when(
      () => storage.read(key: any(named: 'key')),
    ).thenAnswer((inv) async => store[inv.namedArguments[#key] as String]);
    repo = AuthRepository(storage);
  });

  test('hasPin flips once a PIN is stored', () async {
    expect(await repo.hasPin(), isFalse);
    await repo.setPin('1234');
    expect(await repo.hasPin(), isTrue);
  });

  test('verifyPin accepts the right PIN and rejects the wrong one', () async {
    await repo.setPin('1234');
    expect(await repo.verifyPin('1234'), isTrue);
    expect(await repo.verifyPin('0000'), isFalse);
  });

  test('never stores the PIN in plaintext', () async {
    await repo.setPin('1234');
    expect(store.values.any((v) => v.contains('1234')), isFalse);
  });

  test('uses a random salt so the same PIN hashes differently', () async {
    await repo.setPin('1234');
    final first = store['pin_hash'];
    await repo.setPin('1234');
    expect(first, isNotNull);
    expect(first, isNot(store['pin_hash']));
  });

  test('biometricEnabled round-trips', () async {
    expect(await repo.biometricEnabled, isFalse);
    await repo.setBiometricEnabled(true);
    expect(await repo.biometricEnabled, isTrue);
  });
}
