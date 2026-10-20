import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/ui/widgets/expand_reveal.dart';

Future<void> _pump(WidgetTester tester, {required bool expanded}) =>
    tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              ExpandReveal(
                expanded: expanded,
                child: const SizedBox(height: 100, child: Text('body')),
              ),
            ],
          ),
        ),
      ),
    );

double _height(WidgetTester tester) =>
    tester.getSize(find.byType(ExpandReveal)).height;

/// Stands in for content that loads after it is first built (e.g.
/// `BackingMessage`: a short skeleton, then the full text a moment later).
class _LoadsLate extends StatefulWidget {
  const _LoadsLate();

  @override
  State<_LoadsLate> createState() => _LoadsLateState();
}

class _LoadsLateState extends State<_LoadsLate> {
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    Future<void>.delayed(const Duration(milliseconds: 16), () {
      if (mounted) setState(() => _loaded = true);
    });
  }

  @override
  Widget build(BuildContext context) =>
      SizedBox(height: _loaded ? 100 : 20, child: const Text('late'));
}

void main() {
  testWidgets('builds the child only while expanded', (tester) async {
    await _pump(tester, expanded: false);
    expect(find.text('body'), findsNothing);

    await _pump(tester, expanded: true);
    await tester.pumpAndSettle();
    expect(find.text('body'), findsOneWidget);

    await _pump(tester, expanded: false);
    await tester.pumpAndSettle();
    expect(find.text('body'), findsNothing);
  });

  testWidgets('grows to the child height over its duration', (tester) async {
    await _pump(tester, expanded: false);
    expect(_height(tester), 0);

    await _pump(tester, expanded: true);
    await tester.pump(ExpandReveal.duration ~/ 2);
    final mid = _height(tester);
    expect(mid, greaterThan(0));
    expect(mid, lessThan(100));

    await tester.pumpAndSettle();
    expect(_height(tester), 100);
  });

  testWidgets('spans the full width in both states', (tester) async {
    await _pump(tester, expanded: false);
    expect(tester.getSize(find.byType(ExpandReveal)).width, 800);

    await _pump(tester, expanded: true);
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(ExpandReveal)).width, 800);
  });

  testWidgets('still animates when the content resizes while expanding', (
    tester,
  ) async {
    Future<void> pumpLate({required bool expanded}) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              ExpandReveal(expanded: expanded, child: const _LoadsLate()),
            ],
          ),
        ),
      ),
    );

    await pumpLate(expanded: false);
    await pumpLate(expanded: true);
    // The content grows from 20 to 100 a frame in; half-way through the
    // reveal the box must still be part-way open, not snapped to full.
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(
      ExpandReveal.duration ~/ 2 - const Duration(milliseconds: 32),
    );
    final mid = _height(tester);
    expect(mid, greaterThan(0));
    expect(mid, lessThan(100));

    await tester.pumpAndSettle();
    expect(_height(tester), 100);
  });

  testWidgets('collapse drops the content at once and shrinks its space', (
    tester,
  ) async {
    await _pump(tester, expanded: true);
    await tester.pumpAndSettle();
    expect(_height(tester), 100);

    await _pump(tester, expanded: false);
    // Content is gone immediately (privacy: nothing lingers while closing)...
    expect(find.text('body'), findsNothing);
    // ...while its empty space animates away.
    await tester.pump(ExpandReveal.duration ~/ 2);
    final mid = _height(tester);
    expect(mid, greaterThan(0));
    expect(mid, lessThan(100));

    await tester.pumpAndSettle();
    expect(_height(tester), 0);
  });
}
