// One-Euro Filter (Casiez et al.).
//
// A low-latency adaptive low-pass filter ideal for stylus / mouse input:
// - At low velocities, smoothing cutoff is low (heavy smoothing → no jitter).
// - At high velocities, cutoff rises (light smoothing → no lag).
//
// Reference: http://cristal.univ-lille.fr/~casiez/1euro/
//
// Usage:
//   final f = OneEuroFilter();
//   final y = f.filter(rawX, tSeconds);

import 'dart:math' as math;

class OneEuroFilter {
  OneEuroFilter({
    this.minCutoff = 1.0,
    this.beta = 0.007,
    this.dCutoff = 1.0,
  });

  /// Minimum cutoff frequency (Hz). Lower = more smoothing.
  final double minCutoff;

  /// Speed coefficient. Higher = the cutoff rises faster with speed.
  final double beta;

  /// Cutoff for the derivative filter (Hz).
  final double dCutoff;

  double? _xPrev;
  double _dxPrev = 0;
  double? _tPrev;

  /// Reset internal state. Call between separate strokes.
  void reset() {
    _xPrev = null;
    _dxPrev = 0;
    _tPrev = null;
  }

  /// Filter [x] sampled at time [tSec] (seconds since some epoch).
  double filter(double x, double tSec) {
    if (_xPrev == null || _tPrev == null) {
      _xPrev = x;
      _tPrev = tSec;
      return x;
    }
    final dt = math.max(tSec - _tPrev!, 1e-6);
    final dx = (x - _xPrev!) / dt;

    final aD = _alpha(dt, dCutoff);
    final dxHat = aD * dx + (1 - aD) * _dxPrev;

    final cutoff = minCutoff + beta * dxHat.abs();
    final a = _alpha(dt, cutoff);
    final xHat = a * x + (1 - a) * _xPrev!;

    _xPrev = xHat;
    _dxPrev = dxHat;
    _tPrev = tSec;
    return xHat;
  }

  static double _alpha(double dt, double cutoff) {
    final tau = 1.0 / (2 * math.pi * cutoff);
    return 1.0 / (1.0 + tau / dt);
  }
}
