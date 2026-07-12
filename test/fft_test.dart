import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hamchannel/dsp/fft.dart';

void main() {
  test('FFT of a pure tone concentrates energy in one bin', () {
    const n = 1024;
    final fft = Fft(n);
    final re = Float64List(n);
    final im = Float64List(n);
    const bin = 37;
    for (var i = 0; i < n; i++) {
      re[i] = math.cos(2 * math.pi * bin * i / n);
    }
    fft.forward(re, im);
    // Expect n/2 at +bin and n/2 at n-bin.
    expect(re[bin], closeTo(n / 2, 1e-6));
    expect(re[n - bin], closeTo(n / 2, 1e-6));
    for (var k = 0; k < n; k++) {
      if (k == bin || k == n - bin) continue;
      expect(re[k].abs() + im[k].abs(), lessThan(1e-6));
    }
  });

  test('inverse(forward(x)) == x', () {
    const n = 256;
    final fft = Fft(n);
    final rng = math.Random(7);
    final re = Float64List.fromList(
        List.generate(n, (_) => rng.nextDouble() * 2 - 1));
    final im = Float64List.fromList(
        List.generate(n, (_) => rng.nextDouble() * 2 - 1));
    final re0 = Float64List.fromList(re);
    final im0 = Float64List.fromList(im);
    fft.forward(re, im);
    fft.inverse(re, im);
    for (var i = 0; i < n; i++) {
      expect(re[i], closeTo(re0[i], 1e-9));
      expect(im[i], closeTo(im0[i], 1e-9));
    }
  });

  test('Parseval energy conservation', () {
    const n = 512;
    final fft = Fft(n);
    final rng = math.Random(3);
    final re = Float64List.fromList(
        List.generate(n, (_) => rng.nextDouble() * 2 - 1));
    final im = Float64List(n);
    var eTime = 0.0;
    for (var i = 0; i < n; i++) {
      eTime += re[i] * re[i];
    }
    fft.forward(re, im);
    var eFreq = 0.0;
    for (var i = 0; i < n; i++) {
      eFreq += re[i] * re[i] + im[i] * im[i];
    }
    expect(eFreq / n, closeTo(eTime, 1e-6));
  });
}
