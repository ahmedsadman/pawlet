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
}
