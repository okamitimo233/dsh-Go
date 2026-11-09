import 'dart:ui' show FrameTiming;

import 'package:dsh_app/dev/frame_budget.dart';
import 'package:flutter_test/flutter_test.dart';

FrameTiming _timing(int buildUs, int rasterUs) => FrameTiming(
  vsyncStart: 0,
  buildStart: 0,
  buildFinish: buildUs,
  rasterStart: buildUs,
  rasterFinish: buildUs + rasterUs,
  rasterFinishWallTime: buildUs + rasterUs,
);

void main() {
  test('a window reports percentiles, over-budget frames, and jank ratio', () {
    final window = FrameBudgetWindow(budgetMicros: 16000)
      ..add(_timing(10000, 10000))
      ..add(_timing(5000, 20000))
      ..add(_timing(20000, 1000));

    final snapshot = window.snapshot();

    expect(snapshot.frameCount, 3);
    expect(snapshot.buildUs, [10000, 20000, 20000, 20000]);
    expect(snapshot.rasterUs, [10000, 20000, 20000, 20000]);
    expect(snapshot.spanUs, [21000, 25000, 25000, 25000]);
    expect(snapshot.buildOverBudget, 1);
    expect(snapshot.rasterOverBudget, 1);
    expect(snapshot.spanOverBudget, 3);
    expect(snapshot.jankyFrames, 2);
    expect(snapshot.jankRatio, closeTo(2 / 3, 1e-12));
    expect(snapshot.toJson(), containsPair('count', 3));
    expect(snapshot.toJson(), containsPair('budgetUs', 16000));
  });

  test('snapshot clears the window; an idle window is all zeroes', () {
    final window = FrameBudgetWindow(budgetMicros: 16000)..add(_timing(1000, 1000));
    expect(window.snapshot().frameCount, 1);

    final idle = window.snapshot();
    expect(idle.frameCount, 0);
    expect(idle.buildUs, [0, 0, 0, 0]);
    expect(idle.rasterUs, [0, 0, 0, 0]);
    expect(idle.spanUs, [0, 0, 0, 0]);
    expect(idle.jankyFrames, 0);
    expect(idle.jankRatio, 0);
  });

  test('exactly at the budget is not over budget', () {
    final snapshot = (FrameBudgetWindow(budgetMicros: 16000)..add(_timing(16000, 16000))).snapshot();
    expect(snapshot.buildOverBudget, 0);
    expect(snapshot.rasterOverBudget, 0);
    expect(snapshot.jankyFrames, 0);
    expect(snapshot.spanOverBudget, 1);
  });
}
