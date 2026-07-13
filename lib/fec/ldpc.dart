/// Systematic IRA-style LDPC codes with deterministic construction and a
/// normalized min-sum belief-propagation decoder.
///
/// Code structure: H = [A | P] where A is an m x k sparse matrix with
/// column weight 3 (info part) and P is the m x m dual-diagonal
/// "accumulator" (P[i][i] = 1, P[i][i-1] = 1). Encoding is O(edges):
///   p_0 = sum(row 0 info bits), p_i = p_{i-1} + sum(row i info bits).
///
/// Both stations build identical graphs from the same (n, rate) seed, so no
/// matrices are ever transmitted.
library;

import 'dart:typed_data';

import '../dsp/modem_params.dart';

class LdpcCode {
  LdpcCode._(this.n, this.k, this.rate);

  /// Coded length in bits.
  final int n;

  /// Info length in bits.
  final int k;
  final LdpcRate rate;

  int get m => n - k;

  // Compressed graph: for each check row, the list of variable indices
  // (info columns 0..k-1, parity columns k..n-1).
  late final List<Int32List> _rows;
  // Edge arrays for the decoder.
  late final Int32List _edgeVar; // variable index of each edge
  late final Int32List _rowStart; // row -> first edge index
  late final int _edgeCount;

  static final Map<String, LdpcCode> _cache = {};

  /// Payload code: n = 2048 coded bits at the requested rate.
  static LdpcCode payload(LdpcRate rate) => _get(2048, rate);

  /// Header code: short, always rate 1/2 (n = 512, k = 256).
  static LdpcCode header() => _get(512, LdpcRate.half);

  static LdpcCode _get(int n, LdpcRate rate) {
    final key = '$n/${rate.name}';
    return _cache.putIfAbsent(key, () => _build(n, rate));
  }

  static LdpcCode _build(int n, LdpcRate rate) {
    final (num_, den) = rate.fraction;
    // k rounded down to a whole byte so info blocks are byte aligned.
    final k = ((n * num_ ~/ den) ~/ 8) * 8;
    final c = LdpcCode._(n, k, rate);
    final m = c.m;
    final rng = DetRng(0xC0DE0000 ^ (n << 8) ^ (num_ << 4) ^ den);

    final rows = List<List<int>>.generate(m, (_) => <int>[]);
    // Track pairs of rows already sharing a column to reduce 4-cycles.
    final pairSeen = <int>{};

    // Info columns: weight 3, rows spread deterministically.
    for (var col = 0; col < k; col++) {
      final picked = <int>[];
      var guard = 0;
      while (picked.length < 3 && guard < 200) {
        guard++;
        final r = rng.nextInt(m);
        if (picked.contains(r)) continue;
        // 4-cycle avoidance (best effort): reject if this row already
        // pairs with one of the picked rows through another column.
        var bad = false;
        for (final p in picked) {
          final a = p < r ? p : r, b = p < r ? r : p;
          if (pairSeen.contains(a * m + b)) {
            bad = true;
            break;
          }
        }
        if (bad && guard < 60) continue;
        picked.add(r);
      }
      picked.sort();
      for (var i = 0; i < picked.length; i++) {
        for (var j = i + 1; j < picked.length; j++) {
          pairSeen.add(picked[i] * m + picked[j]);
        }
        rows[picked[i]].add(col);
      }
    }
    // Parity accumulator columns.
    for (var i = 0; i < m; i++) {
      rows[i].add(k + i);
      if (i > 0) rows[i].add(k + i - 1);
    }

    c._rows = [for (final r in rows) Int32List.fromList(r)];
    var edges = 0;
    for (final r in c._rows) {
      edges += r.length;
    }
    c._edgeCount = edges;
    c._edgeVar = Int32List(edges);
    c._rowStart = Int32List(m + 1);
    var e = 0;
    for (var i = 0; i < m; i++) {
      c._rowStart[i] = e;
      for (final v in c._rows[i]) {
        c._edgeVar[e++] = v;
      }
    }
    c._rowStart[m] = e;
    return c;
  }

  /// Info bytes per block.
  int get infoBytes => k ~/ 8;

  /// Encode [info] (k bits as bytes, MSB first) -> n coded bits (0/1).
  Uint8List encodeBits(Uint8List infoBytesIn) {
    assert(infoBytesIn.length == infoBytes);
    final bits = Uint8List(n);
    for (var i = 0; i < k; i++) {
      bits[i] = (infoBytesIn[i >> 3] >> (7 - (i & 7))) & 1;
    }
    var acc = 0;
    for (var row = 0; row < m; row++) {
      var s = 0;
      final r = _rows[row];
      // Last one or two entries are parity columns; info entries first.
      for (final v in r) {
        if (v < k) s ^= bits[v];
      }
      acc ^= s; // p_row = p_{row-1} + row_sum
      bits[k + row] = acc;
    }
    return bits;
  }

  /// Decode LLRs (positive = bit 0) into info bytes, or null on failure.
  ///
  /// Normalized min-sum with a layered (row-serial) schedule. When [stats]
  /// is provided and decoding succeeds, it is filled with the number of
  /// channel hard-decision errors the decoder corrected (input LLR sign vs
  /// final codeword) and the iteration count.
  Uint8List? decode(Float64List llr,
      {int maxIter = 40, double alpha = 0.8, LdpcDecodeStats? stats}) {
    assert(llr.length == n);
    final ec = _edgeCount;
    final r = Float64List(ec); // check -> var messages
    final post = Float64List.fromList(llr); // posterior LLRs
    final hard = Uint8List(n);

    for (var iter = 0; iter <= maxIter; iter++) {
      // Hard decision + parity check.
      for (var v = 0; v < n; v++) {
        hard[v] = post[v] < 0 ? 1 : 0;
      }
      var ok = true;
      for (var row = 0; row < m && ok; row++) {
        var s = 0;
        for (var e = _rowStart[row]; e < _rowStart[row + 1]; e++) {
          s ^= hard[_edgeVar[e]];
        }
        if (s != 0) ok = false;
      }
      if (ok) {
        if (stats != null) {
          var corrected = 0;
          for (var v = 0; v < n; v++) {
            if ((llr[v] < 0 ? 1 : 0) != hard[v]) corrected++;
          }
          stats.correctedBits = corrected;
          stats.iterations = iter;
        }
        return _packInfo(hard);
      }
      if (iter == maxIter) break;

      // Check-node update using q = post - r (variable-to-check).
      for (var row = 0; row < m; row++) {
        final start = _rowStart[row], end = _rowStart[row + 1];
        if (end - start < 2) continue; // degenerate row carries no info
        var min1 = double.infinity, min2 = double.infinity;
        var minIdx = -1;
        var sign = 1.0;
        for (var e = start; e < end; e++) {
          final q = post[_edgeVar[e]] - r[e];
          final a = q.abs();
          if (a < min1) {
            min2 = min1;
            min1 = a;
            minIdx = e;
          } else if (a < min2) {
            min2 = a;
          }
          if (q < 0) sign = -sign;
        }
        for (var e = start; e < end; e++) {
          final q = post[_edgeVar[e]] - r[e];
          final mag = (e == minIdx ? min2 : min1) * alpha;
          final s = (q < 0 ? -sign : sign) * mag;
          // Update posterior incrementally: remove old r, add new.
          post[_edgeVar[e]] += s - r[e];
          r[e] = s;
        }
      }
    }
    return null;
  }

  Uint8List _packInfo(Uint8List hard) {
    final out = Uint8List(infoBytes);
    for (var i = 0; i < k; i++) {
      if (hard[i] != 0) out[i >> 3] |= 1 << (7 - (i & 7));
    }
    return out;
  }

  /// Convenience: encode bytes and return coded bits.
  Uint8List encode(Uint8List info) => encodeBits(info);
}

/// Filled by [LdpcCode.decode] on success.
class LdpcDecodeStats {
  /// Coded bits whose channel hard decision the decoder flipped — i.e. the
  /// raw channel bit errors within this (successfully decoded) block.
  int correctedBits = 0;
  int iterations = 0;
}
