import 'dart:math' as math;
import 'dart:ui' show FrameTiming;

/// A five-second window of frame timings, summarized without keeping the
/// callback alive or scheduling any frame of its own.
///
/// The probe reports both thread durations and total spans. A frame is counted
/// as janky when the UI build or raster work alone exceeds [budgetMicros];
/// [spanOverBudget] is informational because it also includes the wait for
/// vsync and the compositor's presentation cadence.
class FrameBudgetWindow {
  FrameBudgetWindow({this.budgetMicros = 16667});

  final int budgetMicros;

  final List<int> _buildUs = [];
  final List<int> _rasterUs = [];
  final List<int> _spanUs = [];
  int _buildOverBudget = 0;
  int _rasterOverBudget = 0;
  int _spanOverBudget = 0;
  int _jankyFrames = 0;

  int get frameCount => _buildUs.length;

  void add(FrameTiming timing) => addAll([timing]);

  void addAll(Iterable<FrameTiming> timings) {
    for (final timing in timings) {
      final buildUs = timing.buildDuration.inMicroseconds;
      final rasterUs = timing.rasterDuration.inMicroseconds;
      final spanUs = timing.totalSpan.inMicroseconds;
      _buildUs.add(buildUs);
      _rasterUs.add(rasterUs);
      _spanUs.add(spanUs);
      final buildOver = buildUs > budgetMicros;
      final rasterOver = rasterUs > budgetMicros;
      if (buildOver) _buildOverBudget++;
      if (rasterOver) _rasterOverBudget++;
      if (spanUs > budgetMicros) _spanOverBudget++;
      if (buildOver || rasterOver) _jankyFrames++;
    }
  }

  /// Returns the current window and starts a new one. Empty windows are valid:
  /// an idle app delivers no frame timings.
  FrameBudgetSnapshot snapshot() {
    final snapshot = FrameBudgetSnapshot(
      budgetMicros: budgetMicros,
      frameCount: frameCount,
      buildUs: _percentiles(_buildUs),
      rasterUs: _percentiles(_rasterUs),
      spanUs: _percentiles(_spanUs),
      buildOverBudget: _buildOverBudget,
      rasterOverBudget: _rasterOverBudget,
      spanOverBudget: _spanOverBudget,
      jankyFrames: _jankyFrames,
    );
    _buildUs.clear();
    _rasterUs.clear();
    _spanUs.clear();
    _buildOverBudget = 0;
    _rasterOverBudget = 0;
    _spanOverBudget = 0;
    _jankyFrames = 0;
    return snapshot;
  }

  static List<int> _percentiles(List<int> values) {
    if (values.isEmpty) return const [0, 0, 0, 0];
    final sorted = [...values]..sort();
    return [_percentile(sorted, 50), _percentile(sorted, 95), _percentile(sorted, 99), sorted.last];
  }

  static int _percentile(List<int> sorted, int percent) {
    if (sorted.isEmpty) return 0;
    if (percent >= 100) return sorted.last;
    final index = (percent / 100 * (sorted.length - 1)).ceil();
    return sorted[math.min(index, sorted.length - 1)];
  }
}

class FrameBudgetSnapshot {
  const FrameBudgetSnapshot({
    required this.budgetMicros,
    required this.frameCount,
    required this.buildUs,
    required this.rasterUs,
    required this.spanUs,
    required this.buildOverBudget,
    required this.rasterOverBudget,
    required this.spanOverBudget,
    required this.jankyFrames,
  });

  final int budgetMicros;
  final int frameCount;

  /// `[p50, p95, p99, max]`, in microseconds.
  final List<int> buildUs;
  final List<int> rasterUs;
  final List<int> spanUs;
  final int buildOverBudget;
  final int rasterOverBudget;
  final int spanOverBudget;
  final int jankyFrames;

  double get jankRatio => frameCount == 0 ? 0 : jankyFrames / frameCount;

  Map<String, Object> toJson() => {
    'budgetUs': budgetMicros,
    'count': frameCount,
    'buildUs': _statsJson(buildUs),
    'rasterUs': _statsJson(rasterUs),
    'spanUs': _statsJson(spanUs),
    'overBudget': {'build': buildOverBudget, 'raster': rasterOverBudget, 'span': spanOverBudget, 'frame': jankyFrames},
    'jankRatio': jankRatio,
  };

  static Map<String, int> _statsJson(List<int> values) => {
    'p50': values[0],
    'p95': values[1],
    'p99': values[2],
    'max': values[3],
  };
}
