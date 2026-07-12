/// OFDM numerology for the HamChannel acoustic modem.
///
/// The modem runs at a fixed 48 kHz sample rate and uses a 1024-point FFT,
/// giving a subcarrier spacing of 46.875 Hz. An OFDM symbol with its 1/8
/// cyclic prefix is 1152 samples (24 ms) long.
///
/// Two channel profiles are provided:
///  * narrow — audio energy confined to a 12 kHz channel
///  * wide   — audio energy confined to a 24 kHz channel
library;

import 'dart:math' as math;

enum ChannelWidth { narrow, wide }

enum SubcarrierModulation { bpsk, qpsk, qam16, qam64 }

enum LdpcRate { half, twoThirds, threeQuarters, fiveSixths }

extension SubcarrierModulationX on SubcarrierModulation {
  int get bitsPerSymbol => switch (this) {
        SubcarrierModulation.bpsk => 1,
        SubcarrierModulation.qpsk => 2,
        SubcarrierModulation.qam16 => 4,
        SubcarrierModulation.qam64 => 6,
      };

  String get label => switch (this) {
        SubcarrierModulation.bpsk => 'BPSK',
        SubcarrierModulation.qpsk => 'QPSK',
        SubcarrierModulation.qam16 => '16-QAM',
        SubcarrierModulation.qam64 => '64-QAM',
      };
}

extension LdpcRateX on LdpcRate {
  /// Numerator / denominator of the code rate.
  (int, int) get fraction => switch (this) {
        LdpcRate.half => (1, 2),
        LdpcRate.twoThirds => (2, 3),
        LdpcRate.threeQuarters => (3, 4),
        LdpcRate.fiveSixths => (5, 6),
      };

  double get value {
    final (n, d) = fraction;
    return n / d;
  }

  String get label {
    final (n, d) = fraction;
    return '$n/$d';
  }
}

/// Static numerology shared by transmitter and receiver.
class ModemParams {
  ModemParams({required this.width});

  final ChannelWidth width;

  static const int sampleRate = 48000;
  static const int fftSize = 1024;
  static const int cpLen = 128;
  static const int symbolLen = fftSize + cpLen; // 1152 samples = 24 ms

  static const double binHz = sampleRate / fftSize; // 46.875 Hz

  /// First active FFT bin (750 Hz) — keeps clear of DC and hum.
  static const int firstBin = 16;

  /// Number of active subcarriers. Narrow: 240 (750 Hz .. 12 kHz);
  /// wide: 480 (750 Hz .. 23.25 kHz).
  int get activeCarriers => width == ChannelWidth.narrow ? 240 : 480;

  /// Pilot every [pilotSpacing]-th active carrier.
  static const int pilotSpacing = 8;

  int get pilotCount => activeCarriers ~/ pilotSpacing;
  int get dataCarriers => activeCarriers - pilotCount;

  /// Active bin index list (FFT bin numbers).
  List<int> get activeBins =>
      List<int>.generate(activeCarriers, (i) => firstBin + i);

  /// Indices (within the active-carrier array) that hold pilots.
  List<int> get pilotIdx => List<int>.generate(
      pilotCount, (i) => i * pilotSpacing + pilotSpacing ~/ 2);

  List<int> get dataIdx {
    final p = pilotIdx.toSet();
    return [
      for (var i = 0; i < activeCarriers; i++)
        if (!p.contains(i)) i
    ];
  }

  /// Occupied audio bandwidth in Hz (top active bin edge).
  double get occupiedHz => (firstBin + activeCarriers) * binHz;

  /// Coded bits carried by one OFDM data symbol.
  int bitsPerOfdmSymbol(SubcarrierModulation mod) =>
      dataCarriers * mod.bitsPerSymbol;

  /// Raw (pre-FEC) bit rate in bit/s.
  double rawBitRate(SubcarrierModulation mod) =>
      bitsPerOfdmSymbol(mod) * sampleRate / symbolLen;

  /// Net user bit rate after LDPC in bit/s.
  double netBitRate(SubcarrierModulation mod, LdpcRate rate) =>
      rawBitRate(mod) * rate.value;

  @override
  String toString() =>
      'ModemParams(${width.name}: $activeCarriers carriers, '
      '${occupiedHz.toStringAsFixed(0)} Hz occupied)';
}

/// Deterministic PRNG (xorshift32) used everywhere both ends must agree
/// (LDPC graph, interleaver, preamble PN sequence).
class DetRng {
  DetRng(int seed) : _s = seed == 0 ? 0x9E3779B9 : seed;
  int _s;

  int nextInt(int bound) {
    var x = _s;
    x ^= (x << 13) & 0xFFFFFFFF;
    x ^= x >>> 17;
    x ^= (x << 5) & 0xFFFFFFFF;
    _s = x & 0xFFFFFFFF;
    return _s % bound;
  }

  /// Random bit (0/1).
  int nextBit() => nextInt(2);

  double nextDouble() => nextInt(1 << 30) / (1 << 30);

  /// Standard normal via Box-Muller (for tests / noise shaping).
  double nextGaussian() {
    final u1 = math.max(nextDouble(), 1e-12);
    final u2 = nextDouble();
    return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2);
  }
}
