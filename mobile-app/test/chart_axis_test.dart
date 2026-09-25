import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/utils/chart_axis.dart';

void main() {
  test('rounds up to a clean max with headroom above the data', () {
    final axis = niceAxis(407500);
    expect(axis.step, 100000);
    expect(axis.max, 500000); // ceil(407500/100000)*100000, already > dataMax
    expect(axis.max, greaterThan(407500));
  });

  test('adds a step of headroom when the data max lands on a gridline', () {
    final axis = niceAxis(400000);
    expect(axis.step, 100000);
    // 400000 is a multiple of the step, so add one step so the peak/label are
    // never flush against the top edge.
    expect(axis.max, 500000);
  });

  test('gridlines divide the axis evenly', () {
    final axis = niceAxis(1234);
    expect(axis.max % axis.step, 0);
    expect(axis.max, greaterThan(1234));
  });

  test('handles a zero/empty data max safely', () {
    final axis = niceAxis(0);
    expect(axis.max, greaterThan(0));
    expect(axis.step, greaterThan(0));
  });
}
