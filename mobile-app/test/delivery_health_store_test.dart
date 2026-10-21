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

  test('restartFrom resets watermark and clears misses', () async {
    await store.setWatermark(100);
    await store.setMissedAt([50, 60, 70]);
    await store.setLastScanAt(90);

    await store.restartFrom(200);

    expect(store.watermark, 200);
    expect(store.missedAt, isEmpty);
    // lastScanAt is untouched by restartFrom.
    expect(store.lastScanAt, 90);
  });

  test('advanceWatermark does nothing when watermark is null', () async {
    expect(store.watermark, isNull);
    await store.advanceWatermark(100);
    expect(store.watermark, isNull);
  });

  test('advanceWatermark does nothing when watermark is ahead', () async {
    await store.setWatermark(200);
    await store.advanceWatermark(100);
    expect(store.watermark, 200);
  });

  test('advanceWatermark moves when behind', () async {
    await store.setWatermark(100);
    await store.advanceWatermark(200);
    expect(store.watermark, 200);
  });
}
