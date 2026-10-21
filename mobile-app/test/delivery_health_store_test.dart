import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/data/delivery_health_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late DeliveryHealthStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = DeliveryHealthStore(await SharedPreferences.getInstance());
  });

  test('starts empty', () {
    expect(store.watermark, isNull);
    expect(store.lastScanAt, isNull);
    expect(store.missedAt, isEmpty);
    expect(store.promptSnoozedUntil, isNull);
  });

  test('ensureWatermark sets it once and never moves it', () async {
    await store.ensureWatermark(100);
    await store.ensureWatermark(200);
    expect(store.watermark, 100);
  });

  test('setWatermark moves it', () async {
    await store.ensureWatermark(100);
    await store.setWatermark(300);
    expect(store.watermark, 300);
  });

  test('round-trips last scan, misses and snooze', () async {
    await store.setLastScanAt(5);
    await store.setMissedAt([1, 2, 3]);
    await store.setPromptSnoozedUntil(9);
    expect(store.lastScanAt, 5);
    expect(store.missedAt, [1, 2, 3]);
    expect(store.promptSnoozedUntil, 9);
  });
}
