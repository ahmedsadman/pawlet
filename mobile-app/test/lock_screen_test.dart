import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pawlet/state/auth_providers.dart';
import 'package:pawlet/theme/catppuccin_theme.dart';
import 'package:pawlet/ui/security/lock_screen.dart';

import 'support/auth_test_overrides.dart';

Future<ProviderContainer> _pumpLock(
  WidgetTester tester,
  List<Override> overrides,
) async {
  final container = ProviderContainer(overrides: overrides);
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(theme: AppTheme.theme, home: const LockScreen()),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

Future<void> _enter(WidgetTester tester, String pin) async {
  for (final d in pin.split('')) {
    await tester.tap(find.text(d));
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('unlocks after the correct PIN', (tester) async {
    final t = authTestOverrides(hasPin: true);
    when(() => t.repo.verifyPin(any())).thenAnswer((_) async => true);
    final container = await _pumpLock(tester, t.overrides);

    expect(container.read(authControllerProvider).status, AuthStatus.locked);
    await _enter(tester, '1234');
    expect(container.read(authControllerProvider).status, AuthStatus.unlocked);
  });

  testWidgets('shows an error on the wrong PIN', (tester) async {
    final t = authTestOverrides(hasPin: true);
    when(() => t.repo.verifyPin(any())).thenAnswer((_) async => false);
    final container = await _pumpLock(tester, t.overrides);

    await _enter(tester, '0000');
    expect(find.text('Incorrect PIN. Try again.'), findsOneWidget);
    expect(container.read(authControllerProvider).status, AuthStatus.locked);
  });

  testWidgets('auto-prompts biometrics on open when enabled', (tester) async {
    final t = authTestOverrides(
      hasPin: true,
      biometricAvailable: true,
      biometricEnabled: true,
    );
    when(t.biometric.authenticate).thenAnswer((_) async => false);
    await _pumpLock(tester, t.overrides);

    verify(t.biometric.authenticate).called(1);
    expect(find.byIcon(Icons.fingerprint), findsOneWidget);
  });

  testWidgets('does not prompt biometrics when disabled', (tester) async {
    final t = authTestOverrides(hasPin: true, biometricAvailable: false);
    await _pumpLock(tester, t.overrides);

    verifyNever(t.biometric.authenticate);
    expect(find.byIcon(Icons.fingerprint), findsNothing);
  });
}
