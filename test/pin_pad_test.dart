import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meowni/theme/catppuccin_theme.dart';
import 'package:meowni/ui/security/pin_pad.dart';

Future<void> _pumpPad(
  WidgetTester tester, {
  ValueChanged<String>? onDigit,
  VoidCallback? onBackspace,
  IconData? leadingIcon,
  VoidCallback? onLeading,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.theme,
      home: Scaffold(
        body: PinPad(
          onDigit: onDigit ?? (_) {},
          onBackspace: onBackspace ?? () {},
          leadingIcon: leadingIcon,
          onLeading: onLeading,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('emits tapped digits', (tester) async {
    final taps = <String>[];
    await _pumpPad(tester, onDigit: taps.add);
    await tester.tap(find.text('1'));
    await tester.tap(find.text('9'));
    await tester.tap(find.text('0'));
    expect(taps, ['1', '9', '0']);
  });

  testWidgets('fires backspace', (tester) async {
    var count = 0;
    await _pumpPad(tester, onBackspace: () => count++);
    await tester.tap(find.byIcon(Icons.backspace_outlined));
    expect(count, 1);
  });

  testWidgets('shows the leading action only when provided', (tester) async {
    await _pumpPad(tester);
    expect(find.byIcon(Icons.fingerprint), findsNothing);

    var pressed = 0;
    await _pumpPad(
      tester,
      leadingIcon: Icons.fingerprint,
      onLeading: () => pressed++,
    );
    await tester.tap(find.byIcon(Icons.fingerprint));
    expect(pressed, 1);
  });

  testWidgets('PinDots renders one dot per slot', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: PinDots(length: 4, filled: 2))),
    );
    expect(find.byType(AnimatedContainer), findsNWidgets(4));
  });
}
