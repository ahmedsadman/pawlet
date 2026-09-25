import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/state/providers.dart';

void main() {
  test('bump increments the revision', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(dataRevisionProvider), 0);
    container.read(dataRevisionProvider.notifier).bump();
    expect(container.read(dataRevisionProvider), 1);
    container.read(dataRevisionProvider.notifier).bump();
    expect(container.read(dataRevisionProvider), 2);
  });

  test(
    'a FutureProvider that watches the revision re-executes on bump',
    () async {
      var reads = 0;
      final probe = FutureProvider<int>((ref) async {
        ref.watch(dataRevisionProvider);
        return ++reads;
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);

      // Keep the provider alive so it recomputes on dependency change.
      final sub = container.listen(probe, (_, _) {});
      addTearDown(sub.close);

      expect(await container.read(probe.future), 1);
      container.read(dataRevisionProvider.notifier).bump();
      // Allow the microtask that reschedules the future to run.
      await container.read(probe.future);
      expect(reads, 2);
    },
  );
}
