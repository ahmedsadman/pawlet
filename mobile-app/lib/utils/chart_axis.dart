import 'dart:math';

/// A resolved chart value-axis: a rounded [max] and a [step] between gridlines.
class ChartAxis {
  const ChartAxis({required this.max, required this.step});

  final double max;
  final double step;
}

/// Rounds [value] to a "nice" number (1, 2, 5 × 10^n). When [round] is false it
/// rounds up so the result covers [value]; when true it picks the closest nice
/// number (used for the step so gridlines land on readable values).
double _niceNum(double value, {required bool round}) {
  if (value <= 0) return 1;
  final exponent = (log(value) / ln10).floor();
  final fraction = value / pow(10, exponent);
  double niceFraction;
  if (round) {
    if (fraction < 1.5) {
      niceFraction = 1;
    } else if (fraction < 3) {
      niceFraction = 2;
    } else if (fraction < 7) {
      niceFraction = 5;
    } else {
      niceFraction = 10;
    }
  } else {
    if (fraction <= 1) {
      niceFraction = 1;
    } else if (fraction <= 2) {
      niceFraction = 2;
    } else if (fraction <= 5) {
      niceFraction = 5;
    } else {
      niceFraction = 10;
    }
  }
  return niceFraction * pow(10, exponent);
}

/// Computes a rounded axis [max] and gridline [step] for a value axis anchored
/// at 0, targeting ~[ticks] gridlines. The max always sits strictly above
/// [dataMax] so a curved line's peak (and its label) never touches the top edge.
ChartAxis niceAxis(double dataMax, {int ticks = 4}) {
  if (dataMax <= 0) return const ChartAxis(max: 1, step: 1);
  final range = _niceNum(dataMax, round: false);
  final step = _niceNum(range / ticks, round: true);
  final max = (dataMax / step).ceilToDouble() * step;
  return ChartAxis(max: max <= dataMax ? max + step : max, step: step);
}
