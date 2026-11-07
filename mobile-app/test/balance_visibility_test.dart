import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/state/providers.dart';

void main() {
  ProviderContainer container() {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    return c;
  }

  testWidgets('starts hidden', (tester) async {
    expect(container().read(balanceHiddenProvider), isTrue);
  });

  testWidgets('toggle flips the value', (tester) async {
    final c = container();
    c.read(balanceHiddenProvider.notifier).toggle();
    expect(c.read(balanceHiddenProvider), isFalse);
    c.read(balanceHiddenProvider.notifier).toggle();
    expect(c.read(balanceHiddenProvider), isTrue);
  });

  testWidgets('re-hides when the app goes to the background', (tester) async {
    final c = container();
    c.read(balanceHiddenProvider.notifier).toggle();

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    expect(c.read(balanceHiddenProvider), isTrue);

    // Coming back keeps them hidden until the user reveals them again.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(c.read(balanceHiddenProvider), isTrue);
  });

  testWidgets('a transient inactive state (e.g. notification shade) keeps '
      'balances shown', (tester) async {
    final c = container();
    c.read(balanceHiddenProvider.notifier).toggle();

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(c.read(balanceHiddenProvider), isFalse);
  });
}
