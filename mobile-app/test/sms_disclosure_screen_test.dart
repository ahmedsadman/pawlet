import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/services/privacy_policy.dart';
import 'package:pawlet/theme/catppuccin_theme.dart';
import 'package:pawlet/ui/privacy/sms_disclosure_screen.dart';

Widget _host(void Function(BuildContext) onTap) => MaterialApp(
  theme: AppTheme.theme,
  home: Builder(
    builder: (context) => Scaffold(
      body: Center(
        child: ElevatedButton(
          onPressed: () => onTap(context),
          child: const Text('open'),
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('states what is read, why, and that it may leave the device', (
    tester,
  ) async {
    await tester.pumpWidget(_host((context) => showSmsDisclosure(context)));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Pawlet reads your bank messages'), findsOneWidget);
    expect(
      find.textContaining('read the SMS messages on this'),
      findsOneWidget,
    );
    expect(find.textContaining('stays on your device'), findsOneWidget);
    expect(find.textContaining('sent for AI classification'), findsOneWidget);
    expect(find.text('Continue'), findsOneWidget);
    expect(find.text('Not now'), findsOneWidget);
  });

  testWidgets('Continue resolves true', (tester) async {
    bool? answer;
    await tester.pumpWidget(
      _host((context) async => answer = await showSmsDisclosure(context)),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(answer, isTrue);
  });

  testWidgets('Not now resolves false', (tester) async {
    bool? answer;
    await tester.pumpWidget(
      _host((context) async => answer = await showSmsDisclosure(context)),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();

    expect(answer, isFalse);
  });

  testWidgets('back-dismissing counts as declining', (tester) async {
    bool? answer;
    await tester.pumpWidget(
      _host((context) async => answer = await showSmsDisclosure(context)),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final NavigatorState navigator = tester.state(find.byType(Navigator));
    navigator.pop();
    await tester.pumpAndSettle();

    expect(answer, isFalse);
  });

  testWidgets('the policy link opens the hosted policy', (tester) async {
    Uri? launched;
    PrivacyPolicy.launcher = (uri) async {
      launched = uri;
      return true;
    };
    addTearDown(PrivacyPolicy.resetLauncher);

    await tester.pumpWidget(_host((context) => showSmsDisclosure(context)));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Read the privacy policy'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Read the privacy policy'));
    await tester.pumpAndSettle();

    expect(launched, Uri.parse(PrivacyPolicy.url));
  });
}
