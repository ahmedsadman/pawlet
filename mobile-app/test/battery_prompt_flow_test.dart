import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/data/delivery_health_store.dart';
import 'package:pawlet/services/battery_prompt_policy.dart';
import 'package:pawlet/services/missed_sms_detector.dart';
import 'package:pawlet/services/power_status.dart';
import 'package:pawlet/state/providers.dart';
import 'package:pawlet/theme/catppuccin_theme.dart';
import 'package:pawlet/ui/battery_prompt_flow.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _now = DateTime(2026, 10, 21, 12).millisecondsSinceEpoch;
const _day = 24 * 60 * 60 * 1000;

class _FakePower implements PowerStatus {
  bool exempt = false;
  bool restricted = false;
  bool grant = true;
  int requestCalls = 0;
  int settingsCalls = 0;

  @override
  Future<bool> isBatteryExempt() async => exempt;
  @override
  Future<bool> isBackgroundRestricted() async => restricted;
  @override
  Future<bool> requestExemption() async {
    requestCalls++;
    return grant;
  }

  @override
  Future<bool> openSettings() async {
    settingsCalls++;
    return true;
  }
}

class _FakeDetector implements MissedSmsDetector {
  int scans = 0;
  void Function()? onScan;
  @override
  Future<void> scanIfDue() async {
    scans++;
    onScan?.call();
  }
}

class _Harness {
  _Harness(this.store, this.power, this.detector);
  final DeliveryHealthStore store;
  final _FakePower power;
  final _FakeDetector detector;
  late BuildContext context;
  late WidgetRef ref;

  Future<bool> run({bool canPrompt = true, bool hasSms = true}) =>
      runBatteryPromptCheck(
        context,
        ref,
        canPrompt: () => canPrompt,
        hasSms: () async => hasSms,
        clock: () => _now,
      );
}

Future<_Harness> _pump(
  WidgetTester tester, {
  List<int> misses = const [],
}) async {
  SharedPreferences.setMockInitialValues({});
  final store = DeliveryHealthStore(await SharedPreferences.getInstance());
  await store.setMissedAt(misses);
  final harness = _Harness(store, _FakePower(), _FakeDetector());
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        deliveryHealthStoreProvider.overrideWithValue(store),
        powerStatusProvider.overrideWithValue(harness.power),
        missedSmsDetectorProvider.overrideWithValue(harness.detector),
      ],
      child: MaterialApp(
        theme: AppTheme.theme,
        home: Consumer(
          builder: (context, ref, _) {
            harness
              ..context = context
              ..ref = ref;
            return const Scaffold(body: SizedBox.expand());
          },
        ),
      ),
    ),
  );
  return harness;
}

void main() {
  const title = 'Pawlet is missing messages';
  final twoMisses = [_now - _day, _now - 2 * _day];

  setUp(() => WidgetController.hitTestWarningShouldBeFatal = true);
  tearDown(() => WidgetController.hitTestWarningShouldBeFatal = false);

  testWidgets('offers the exemption after two misses and grants it', (
    tester,
  ) async {
    final h = await _pump(tester, misses: twoMisses);
    final shown = h.run();
    await tester.pumpAndSettle();

    expect(find.text(title), findsOneWidget);
    expect(h.detector.scans, 1);
    expect(
      h.store.promptSnoozedUntil,
      _now + BatteryPromptPolicy.snooze.inMilliseconds,
    );

    await tester.tap(find.text('Turn off optimization'));
    await tester.pumpAndSettle();

    expect(h.power.requestCalls, 1);
    expect(
      find.text('Battery optimization disabled for Pawlet'),
      findsOneWidget,
    );
    expect(await shown, isTrue);
  });

  testWidgets('a declined exemption shows no confirmation', (tester) async {
    final h = await _pump(tester, misses: twoMisses);
    h.power.grant = false;
    final shown = h.run();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Turn off optimization'));
    await tester.pumpAndSettle();

    expect(h.power.requestCalls, 1);
    expect(find.text('Battery optimization disabled for Pawlet'), findsNothing);
    expect(await shown, isTrue);
  });

  testWidgets('restricted offers app settings', (tester) async {
    final h = await _pump(tester);
    h.power.restricted = true;
    final shown = h.run();
    await tester.pumpAndSettle();

    expect(find.text("Pawlet can't run in the background"), findsOneWidget);
    expect(find.textContaining('Restricted'), findsOneWidget);
    await tester.tap(find.text('Open settings'));
    await tester.pumpAndSettle();

    expect(h.power.settingsCalls, 1);
    expect(h.power.requestCalls, 0);
    expect(await shown, isTrue);
  });

  testWidgets('restricted without SMS permission shows no sheet', (
    tester,
  ) async {
    final h = await _pump(tester);
    h.power.restricted = true;
    final shown = h.run(hasSms: false);
    await tester.pumpAndSettle();

    expect(find.text("Pawlet can't run in the background"), findsNothing);
    expect(h.detector.scans, 1);
    expect(await shown, isFalse);
  });

  testWidgets('Not now closes the sheet and keeps the snooze', (tester) async {
    final h = await _pump(tester, misses: twoMisses);
    final shown = h.run();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();

    expect(find.text(title), findsNothing);
    expect(h.power.requestCalls, 0);
    expect(h.store.promptSnoozedUntil, isNotNull);
    expect(await shown, isTrue);
  });

  testWidgets('no evidence, no sheet', (tester) async {
    final h = await _pump(tester, misses: [_now - _day]);
    final shown = h.run();
    await tester.pumpAndSettle();

    expect(find.text(title), findsNothing);
    expect(h.store.promptSnoozedUntil, isNull);
    expect(await shown, isFalse);
  });

  testWidgets('an exempt app is not asked', (tester) async {
    final h = await _pump(tester, misses: twoMisses);
    h.power.exempt = true;
    final shown = h.run();
    await tester.pumpAndSettle();

    expect(find.text(title), findsNothing);
    expect(await shown, isFalse);
  });

  testWidgets('a snoozed prompt stays hidden', (tester) async {
    final h = await _pump(tester, misses: twoMisses);
    await h.store.setPromptSnoozedUntil(_now + 1);
    final shown = h.run();
    await tester.pumpAndSettle();

    expect(find.text(title), findsNothing);
    expect(await shown, isFalse);
  });

  testWidgets('does nothing, not even a scan, when it may not prompt', (
    tester,
  ) async {
    final h = await _pump(tester, misses: twoMisses);
    final shown = h.run(canPrompt: false);
    await tester.pumpAndSettle();

    expect(find.text(title), findsNothing);
    expect(h.detector.scans, 0);
    expect(await shown, isFalse);
  });

  testWidgets('a second check while the sheet is up does not stack', (
    tester,
  ) async {
    final h = await _pump(tester, misses: twoMisses);
    final first = h.run();
    await tester.pumpAndSettle();
    final second = await h.run();
    await tester.pumpAndSettle();

    expect(second, isFalse);
    expect(find.text(title), findsOneWidget);
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(await first, isTrue);
  });

  testWidgets('canPrompt flips to false during scan: no sheet', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = DeliveryHealthStore(await SharedPreferences.getInstance());
    await store.setMissedAt(twoMisses);
    var allowed = true;
    final detector = _FakeDetector()..onScan = () => allowed = false;
    final harness = _Harness(store, _FakePower(), detector);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          deliveryHealthStoreProvider.overrideWithValue(store),
          powerStatusProvider.overrideWithValue(harness.power),
          missedSmsDetectorProvider.overrideWithValue(detector),
        ],
        child: MaterialApp(
          theme: AppTheme.theme,
          home: Consumer(
            builder: (context, ref, _) {
              harness
                ..context = context
                ..ref = ref;
              return const Scaffold(body: SizedBox.expand());
            },
          ),
        ),
      ),
    );

    final shown = runBatteryPromptCheck(
      harness.context,
      harness.ref,
      canPrompt: () => allowed,
      clock: () => _now,
      hasSms: () async => true,
    );
    await tester.pumpAndSettle();

    expect(find.text(title), findsNothing);
    expect(detector.scans, 1);
    expect(await shown, isFalse);
  });
}
