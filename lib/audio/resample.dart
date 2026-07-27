/// Rational-ratio polyphase resampler (windowed-sinc).
///
/// Used by the Bluetooth-radio audio backend to convert between the modem's
/// 48 kHz sample rate and the radio's 32 kHz SBC stream: 48→32 kHz is
/// up=2/down=3, 32→48 kHz is up=3/down=2.
library;

import 'dart:math' as math;
import 'dart:typed_data';

class StreamingResampler {
  StreamingResampler(this.up, this.down, {int halfTapsPerPhase = 12}) {
    final maxUd = math.max(up, down);
    // Prototype low-pass at the tighter of the two Nyquists, designed at the
    // upsampled rate fs_in * up. Cutoff (cycles/upsampled-sample):
    final f = 1.0 / maxUd;
    final half = halfTapsPerPhase * maxUd;
    final n = 2 * half + 1;
    _h = Float64List(n);
    for (var i = 0; i < n; i++) {
      final x = (i - half).toDouble();
      final sinc = x == 0 ? 1.0 : math.sin(math.pi * f * x) / (math.pi * f * x);
      final win = 0.5 + 0.5 * math.cos(math.pi * x / (half + 1)); // Hann
      _h[i] = up * f * sinc * win;
    }
    _hLen = n;
  }

  final int up;
  final int down;
  late final Float64List _h;
  late final int _hLen;

  // Input samples kept for filtering, with absolute indexing.
  Float64List _buf = Float64List(1 << 12);
  int _len = 0;
  int _startAbs = 0; // absolute input index of _buf[0]
  int _outIdx = 0; // next output sample index

  /// Feed a chunk; returns the newly available output samples.
  Float64List process(Float64List chunk) {
    // Append.
    if (_len + chunk.length > _buf.length) {
      var cap = _buf.length;
      while (cap < _len + chunk.length) {
        cap <<= 1;
      }
      final nb = Float64List(cap);
      nb.setRange(0, _len, _buf);
      _buf = nb;
    }
    _buf.setRange(_len, _len + chunk.length, chunk);
    _len += chunk.length;

    final availAbs = _startAbs + _len; // inputs [0, availAbs)
    final out = <double>[];
    while (true) {
      // Output _outIdx sits at upsampled position m; the causal FIR needs
      // input index floor(m/up) to be available.
      final m = _outIdx * down;
      final needInput = m ~/ up;
      if (needInput >= availAbs) break;
      var acc = 0.0;
      // xup[m-n] is nonzero when (m-n) % up == 0.
      final r = m % up;
      var n0 = r; // smallest n >= 0 with (m-n) % up == 0
      for (var n = n0; n < _hLen; n += up) {
        final xi = (m - n) ~/ up;
        if (xi < 0) break;
        if (xi < _startAbs) break; // beyond retained history (shouldn't happen)
        acc += _h[n] * _buf[xi - _startAbs];
      }
      out.add(acc);
      _outIdx++;
    }

    // Trim history: keep enough inputs for the filter span of the next output.
    final nextNeedOldest =
        ((_outIdx * down) - (_hLen - 1)) ~/ up - 1;
    final keepFrom = math.max(nextNeedOldest, _startAbs);
    final cut = keepFrom - _startAbs;
    if (cut > 4096) {
      _buf.setRange(0, _len - cut, _buf, cut);
      _len -= cut;
      _startAbs += cut;
    }
    return Float64List.fromList(out);
  }

  /// Flush remaining output by feeding silence covering the filter tail.
  Float64List flush() => process(Float64List((_hLen ~/ up) + 2));

  /// One-shot convenience: resample a whole buffer (includes tail flush).
  static Float64List resampleAll(Float64List x, int up, int down) {
    final r = StreamingResampler(up, down);
    final a = r.process(x);
    final b = r.flush();
    final out = Float64List(a.length + b.length);
    out.setRange(0, a.length, a);
    out.setRange(a.length, out.length, b);
    return out;
  }
}
