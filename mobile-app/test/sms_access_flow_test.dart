import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/theme/catppuccin_theme.dart';
import 'package:pawlet/ui/privacy/sms_access_flow.dart';

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
  testWidgets('already-granted skips the disclosure entirely', (tester) async {
    var disclosed = false;
    var requested = false;
    bool? granted;

    await tester.pumpWidget(
      _host(
        (context) async => granted = await ensureSmsAccess(
          context,
          hasSms: () async => true,
          disclose: (_) async {
            disclosed = true;
            return true;
          },
          requestSms: () async => requested = true,
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(granted, isTrue);
    expect(disclosed, isFalse);
    expect(requested, isFalse);
  });

  testWidgets('declining the disclosure never requests the permission', (
    tester,
  ) async {
    var requested = false;
    bool? granted;

    await tester.pumpWidget(
      _host(
        (context) async => granted = await ensureSmsAccess(
          context,
          hasSms: () async => false,
          disclose: (_) async => false,
          requestSms: () async => requested = true,
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(granted, isFalse);
    expect(requested, isFalse);
  });

  testWidgets('accepting the disclosure requests the permission', (
    tester,
  ) async {
    var requested = false;
    var calls = 0;
    bool? granted;

    await tester.pumpWidget(
      _host(
        (context) async => granted = await ensureSmsAccess(
          context,
          // Ungranted on the pre-check, granted after the request.
          hasSms: () async => calls++ > 0,
          disclose: (_) async => true,
          requestSms: () async => requested = true,
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(requested, isTrue);
    expect(granted, isTrue);
  });

  testWidgets('accepting but denying the system prompt reports false', (
    tester,
  ) async {
    bool? granted;

    await tester.pumpWidget(
      _host(
        (context) async => granted = await ensureSmsAccess(
          context,
          hasSms: () async => false,
          disclose: (_) async => true,
          requestSms: () async {},
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(granted, isFalse);
  });
}
