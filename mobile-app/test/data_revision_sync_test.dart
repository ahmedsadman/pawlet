import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/state/providers.dart';

void main() {
  test('bumps once on the first read, then only when the token changes', () async {
    var token = 5;
    var bumps = 0;
    // Long interval so the internal timer never fires during the test; we drive
    // syncOnce() manually.
    final sync = DataRevisionSync(
      () async => token,
      () => bumps++,
      interval: const Duration(hours: 1),
    );
    addTearDown(sync.dispose);

    // First observation establishes a baseline AND refreshes once (covers any
    // write that landed between app load and the first tick).
    await sync.syncOnce();
    expect(bumps, 1);

    // Unchanged token → no bump.
    await sync.syncOnce();
    expect(bumps, 1);

    // Token moved (a background isolate committed a write) → bump.
    token = 6;
    await sync.syncOnce();
    expect(bumps, 2);

    // Stable again → no further bump.
    await sync.syncOnce();
    expect(bumps, 2);
  });
}
