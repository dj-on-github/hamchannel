/// Gray-mapped constellations and max-log LLR demapping.
///
/// All constellations are normalised to unit average energy.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'modem_params.dart';

class Constellation {
  Constellation(this.mod) {
    switch (mod) {
      case SubcarrierModulation.bpsk:
        _levels = Float64List.fromList([1.0]); // re axis only
      case SubcarrierModulation.qpsk:
        _levels = Float64List.fromList([1 / math.sqrt(2)]);
      case SubcarrierModulation.qam16:
        final s = 1 / math.sqrt(10);
        _levels = Float64List.fromList([s, 3 * s]);
      case SubcarrierModulation.qam64:
        final s = 1 / math.sqrt(42);
        _levels = Float64List.fromList([s, 3 * s, 5 * s, 7 * s]);
    }
  }

  final SubcarrierModulation mod;
  late final Float64List _levels;

  int get bitsPerSymbol => mod.bitsPerSymbol;

  /// Gray map bits of one axis (MSB first) to an amplitude.
  /// bitsPerAxis = bitsPerSymbol/2 for QAM, 1 for BPSK (re), 1 for QPSK.
  double _axis(int grayBits, int bitsPerAxis) {
    // Gray-decode to level index.
    var b = grayBits;
    var idx = b;
    while (b > 0) {
      b >>= 1;
      idx ^= b;
    }
    final m = 1 << bitsPerAxis; // levels per axis
    // idx 0..m-1 -> amplitude -(m-1)..(m-1) step 2, times base scale.
    final amp = (2 * idx - (m - 1)).toDouble();
    return amp * _levels[0];
  }

  /// Map [bits] (0/1 values, length multiple of bitsPerSymbol) to complex
  /// points appended into [re]/[im] starting at [outOffset].
  void map(Uint8List bits, int bitOffset, int nSymbols, Float64List re,
      Float64List im, int outOffset) {
    final bps = bitsPerSymbol;
    for (var s = 0; s < nSymbols; s++) {
      final o = bitOffset + s * bps;
      switch (mod) {
        case SubcarrierModulation.bpsk:
          re[outOffset + s] = bits[o] == 0 ? 1.0 : -1.0;
          im[outOffset + s] = 0.0;
        case SubcarrierModulation.qpsk:
          re[outOffset + s] = (bits[o] == 0 ? 1.0 : -1.0) * _levels[0];
          im[outOffset + s] = (bits[o + 1] == 0 ? 1.0 : -1.0) * _levels[0];
        case SubcarrierModulation.qam16:
        case SubcarrierModulation.qam64:
          final half = bps ~/ 2;
          var gi = 0, gq = 0;
          for (var b = 0; b < half; b++) {
            gi = (gi << 1) | bits[o + b];
            gq = (gq << 1) | bits[o + half + b];
          }
          re[outOffset + s] = _axisGray(gi, half);
          im[outOffset + s] = _axisGray(gq, half);
      }
    }
  }

  /// Amplitude for a gray-coded axis value with sign convention:
  /// first bit 0 => positive side (matches LLR sign convention below).
  double _axisGray(int gray, int bitsPerAxis) {
    // Interpret 'gray' MSB-first; bit0 = sign (0 -> +).
    // Build amplitude via reflected mapping so adjacent levels differ by
    // exactly one bit.
    var v = _axis(gray, bitsPerAxis);
    // _axis maps gray 0 -> most negative; flip so bit pattern 0.. -> +max.
    return -v;
  }

  /// Max-log LLRs for one received point (r, i) with noise variance nv
  /// (per complex dimension). Positive LLR means bit = 0.
  /// Writes bitsPerSymbol values into [out] at [outOffset].
  void llr(double r, double i, double nv, Float64List out, int outOffset) {
    final scale = 2.0 / (nv <= 1e-9 ? 1e-9 : nv);
    switch (mod) {
      case SubcarrierModulation.bpsk:
        out[outOffset] = scale * r; // +1 -> bit0
      case SubcarrierModulation.qpsk:
        out[outOffset] = scale * r * _levels[0] * 2;
        out[outOffset + 1] = scale * i * _levels[0] * 2;
      case SubcarrierModulation.qam16:
      case SubcarrierModulation.qam64:
        final half = bitsPerSymbol ~/ 2;
        _axisLlr(r, nv, out, outOffset, half);
        _axisLlr(i, nv, out, outOffset + half, half);
    }
  }

  /// Exact max-log LLR per axis by scanning the (few) levels.
  void _axisLlr(
      double y, double nv, Float64List out, int off, int bitsPerAxis) {
    final m = 1 << bitsPerAxis;
    // Precompute distance to each level (levels indexed by gray value).
    for (var b = 0; b < bitsPerAxis; b++) {
      var best0 = double.infinity, best1 = double.infinity;
      for (var g = 0; g < m; g++) {
        final a = _axisGray(g, bitsPerAxis);
        final d = (y - a) * (y - a);
        final bit = (g >> (bitsPerAxis - 1 - b)) & 1;
        if (bit == 0) {
          if (d < best0) best0 = d;
        } else {
          if (d < best1) best1 = d;
        }
      }
      out[off + b] = (best1 - best0) / (nv <= 1e-9 ? 1e-9 : nv);
    }
  }

  /// Hard-decision helper used in tests.
  void hardDecide(double r, double i, Uint8List outBits, int off) {
    final tmp = Float64List(bitsPerSymbol);
    llr(r, i, 1.0, tmp, 0);
    for (var b = 0; b < bitsPerSymbol; b++) {
      outBits[off + b] = tmp[b] >= 0 ? 0 : 1;
    }
  }

  /// The ideal constellation point nearest to the received point (r, i) —
  /// used for error-vector-magnitude measurement.
  (double, double) nearestPoint(double r, double i) {
    final bits = Uint8List(bitsPerSymbol);
    hardDecide(r, i, bits, 0);
    final re = Float64List(1), im = Float64List(1);
    map(bits, 0, 1, re, im, 0);
    return (re[0], im[0]);
  }

  /// Every ideal point of this constellation (for plotting).
  List<(double, double)> allPoints() {
    final out = <(double, double)>[];
    final bits = Uint8List(bitsPerSymbol);
    final re = Float64List(1), im = Float64List(1);
    for (var v = 0; v < (1 << bitsPerSymbol); v++) {
      for (var b = 0; b < bitsPerSymbol; b++) {
        bits[b] = (v >> (bitsPerSymbol - 1 - b)) & 1;
      }
      map(bits, 0, 1, re, im, 0);
      out.add((re[0], im[0]));
    }
    return out;
  }
}
