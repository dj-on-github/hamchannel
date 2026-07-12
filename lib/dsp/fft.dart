/// In-place iterative radix-2 complex FFT on split re/im Float64Lists.
library;

import 'dart:math' as math;
import 'dart:typed_data';

class Fft {
  Fft(this.n)
      : assert((n & (n - 1)) == 0, 'FFT size must be a power of two'),
        _cos = Float64List(n ~/ 2),
        _sin = Float64List(n ~/ 2),
        _rev = Uint32List(n) {
    for (var i = 0; i < n ~/ 2; i++) {
      final a = -2 * math.pi * i / n;
      _cos[i] = math.cos(a);
      _sin[i] = math.sin(a);
    }
    var j = 0;
    for (var i = 0; i < n; i++) {
      _rev[i] = j;
      var bit = n >> 1;
      while (j & bit != 0) {
        j ^= bit;
        bit >>= 1;
      }
      j |= bit;
    }
  }

  final int n;
  final Float64List _cos;
  final Float64List _sin;
  final Uint32List _rev;

  /// Forward FFT, in place.
  void forward(Float64List re, Float64List im) => _run(re, im, false);

  /// Inverse FFT, in place, includes 1/n scaling.
  void inverse(Float64List re, Float64List im) {
    _run(re, im, true);
    final s = 1.0 / n;
    for (var i = 0; i < n; i++) {
      re[i] *= s;
      im[i] *= s;
    }
  }

  void _run(Float64List re, Float64List im, bool inv) {
    for (var i = 0; i < n; i++) {
      final r = _rev[i];
      if (r > i) {
        var t = re[i];
        re[i] = re[r];
        re[r] = t;
        t = im[i];
        im[i] = im[r];
        im[r] = t;
      }
    }
    for (var len = 2; len <= n; len <<= 1) {
      final half = len >> 1;
      final step = n ~/ len;
      for (var i = 0; i < n; i += len) {
        for (var k = 0; k < half; k++) {
          final tw = k * step;
          final wr = _cos[tw];
          final wi = inv ? -_sin[tw] : _sin[tw];
          final a = i + k, b = i + k + half;
          final tr = re[b] * wr - im[b] * wi;
          final ti = re[b] * wi + im[b] * wr;
          re[b] = re[a] - tr;
          im[b] = im[a] - ti;
          re[a] += tr;
          im[a] += ti;
        }
      }
    }
  }
}
