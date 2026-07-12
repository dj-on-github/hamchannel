/// OFDM symbol construction and demodulation primitives shared by the
/// transmitter and receiver.
library;

import 'dart:typed_data';

import 'fft.dart';
import 'modem_params.dart';

/// Known reference waveforms (preamble, channel-estimation symbol, pilot
/// sequences) for one channel profile. Both stations derive identical
/// waveforms from fixed seeds.
class OfdmWaveforms {
  OfdmWaveforms(this.p)
      : fft = Fft(ModemParams.fftSize),
        syncBits = _pn(0x51AC0000 ^ p.activeCarriers, p.activeCarriers),
        chanestBits = _pn(0xC4A57000 ^ p.activeCarriers, p.activeCarriers) {
    syncSymbol = _buildKnownSymbol(syncBits);
    chanestSymbol = _buildKnownSymbol(chanestBits);
    // Precompute template energy for normalized correlation.
    var e = 0.0;
    for (final v in syncSymbol) {
      e += v * v;
    }
    syncEnergy = e;
  }

  final ModemParams p;
  final Fft fft;
  final Uint8List syncBits;
  final Uint8List chanestBits;
  late final Float64List syncSymbol; // symbolLen samples, unit-ish RMS
  late final Float64List chanestSymbol;
  late final double syncEnergy;

  static Uint8List _pn(int seed, int len) {
    final rng = DetRng(seed);
    return Uint8List.fromList(List.generate(len, (_) => rng.nextBit()));
  }

  /// Pilot BPSK value (+1/-1) for active-carrier index [carrier] in OFDM
  /// symbol number [symIdx] (payload symbol counter, chanest = -1).
  double pilotValue(int symIdx, int carrier) {
    final rng = DetRng(0x917070 ^ (symIdx + 7) * 2654435761 ^ carrier * 40503);
    return rng.nextBit() == 0 ? 1.0 : -1.0;
  }

  /// Build a full known BPSK symbol (used for sync + channel estimation).
  Float64List _buildKnownSymbol(Uint8List bits) {
    final re = Float64List(ModemParams.fftSize);
    final im = Float64List(ModemParams.fftSize);
    final bins = p.activeBins;
    for (var i = 0; i < bins.length; i++) {
      final v = bits[i] == 0 ? 1.0 : -1.0;
      re[bins[i]] = v;
      // Random-ish phase to lower PAPR: rotate every other carrier.
      if (i.isOdd) {
        im[bins[i]] = re[bins[i]];
        re[bins[i]] = 0;
      }
    }
    _mirror(re, im);
    fft.inverse(re, im);
    return _addCp(re);
  }

  /// Enforce Hermitian symmetry so the IFFT output is real.
  static void _mirror(Float64List re, Float64List im) {
    final n = re.length;
    for (var k = 1; k < n ~/ 2; k++) {
      re[n - k] = re[k];
      im[n - k] = -im[k];
    }
    im[0] = 0;
    im[n ~/ 2] = 0;
  }

  static Float64List _addCp(Float64List body) {
    final out = Float64List(ModemParams.symbolLen);
    const cp = ModemParams.cpLen;
    final n = body.length;
    for (var i = 0; i < cp; i++) {
      out[i] = body[n - cp + i];
    }
    out.setRange(cp, cp + n, body);
    return out;
  }

  /// Modulate one OFDM symbol from complex data-carrier values.
  /// [dataRe]/[dataIm] hold `p.dataCarriers` points; pilots are inserted
  /// according to [symIdx].
  Float64List modulateSymbol(
      Float64List dataRe, Float64List dataIm, int symIdx) {
    final re = Float64List(ModemParams.fftSize);
    final im = Float64List(ModemParams.fftSize);
    final bins = p.activeBins;
    final dataIdx = p.dataIdx;
    final pilotIdx = p.pilotIdx;
    for (var i = 0; i < dataIdx.length; i++) {
      re[bins[dataIdx[i]]] = dataRe[i];
      im[bins[dataIdx[i]]] = dataIm[i];
    }
    for (final pi in pilotIdx) {
      re[bins[pi]] = pilotValue(symIdx, pi);
      im[bins[pi]] = 0;
    }
    _mirror(re, im);
    fft.inverse(re, im);
    return _addCp(re);
  }

  /// Frequency-domain values (per active carrier) of a known BPSK symbol —
  /// used by the receiver for channel estimation.
  (Float64List, Float64List) knownFreq(Uint8List bits) {
    final re = Float64List(p.activeCarriers);
    final im = Float64List(p.activeCarriers);
    for (var i = 0; i < p.activeCarriers; i++) {
      final v = bits[i] == 0 ? 1.0 : -1.0;
      if (i.isOdd) {
        im[i] = v;
      } else {
        re[i] = v;
      }
    }
    return (re, im);
  }

  /// FFT of one received symbol body (no CP) -> complex bins of the active
  /// carriers written into [outRe]/[outIm] (length activeCarriers).
  void demodSymbol(Float64List samples, int start, Float64List outRe,
      Float64List outIm) {
    final n = ModemParams.fftSize;
    final re = Float64List(n);
    final im = Float64List(n);
    for (var i = 0; i < n; i++) {
      re[i] = samples[start + i];
    }
    fft.forward(re, im);
    final bins = p.activeBins;
    for (var i = 0; i < bins.length; i++) {
      outRe[i] = re[bins[i]];
      outIm[i] = im[bins[i]];
    }
  }
}
