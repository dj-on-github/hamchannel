import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hamchannel/dsp/modem_params.dart';
import 'package:hamchannel/fec/crc.dart';
import 'package:hamchannel/fec/ldpc.dart';

void main() {
  test('CRC32 known vector', () {
    // "123456789" -> 0xCBF43926
    final d = Uint8List.fromList('123456789'.codeUnits);
    expect(crc32(d), 0xCBF43926);
  });

  test('CRC16/CCITT-FALSE known vector', () {
    final d = Uint8List.fromList('123456789'.codeUnits);
    expect(crc16(d), 0x29B1);
  });

  test('encode produces valid parity for all rates', () {
    for (final rate in LdpcRate.values) {
      final code = LdpcCode.payload(rate);
      final rng = math.Random(11);
      final info = Uint8List.fromList(
          List.generate(code.infoBytes, (_) => rng.nextInt(256)));
      final bits = code.encode(info);
      expect(bits.length, code.n);
      // Round-trip through a noiseless "channel": LLR = +-4.
      final llr = Float64List(code.n);
      for (var i = 0; i < code.n; i++) {
        llr[i] = bits[i] == 0 ? 4.0 : -4.0;
      }
      final dec = code.decode(llr);
      expect(dec, isNotNull, reason: 'rate ${rate.label} clean decode');
      expect(dec, equals(info), reason: 'rate ${rate.label} data');
    }
  });

  test('decodes through an AWGN channel near threshold', () {
    final code = LdpcCode.payload(LdpcRate.half);
    final rng = math.Random(42);
    var failures = 0;
    const trials = 12;
    for (var t = 0; t < trials; t++) {
      final info = Uint8List.fromList(
          List.generate(code.infoBytes, (_) => rng.nextInt(256)));
      final bits = code.encode(info);
      // BPSK over AWGN at Eb/N0 ~ 2.5 dB (rate 1/2 -> Es/N0 ~ -0.5 dB).
      const ebN0Db = 2.5;
      final ebN0 = math.pow(10, ebN0Db / 10).toDouble();
      final sigma = math.sqrt(1 / (2 * 0.5 * ebN0));
      final llr = Float64List(code.n);
      for (var i = 0; i < code.n; i++) {
        final x = bits[i] == 0 ? 1.0 : -1.0;
        final y = x + sigma * _gauss(rng);
        llr[i] = 2 * y / (sigma * sigma);
      }
      final dec = code.decode(llr, maxIter: 60);
      if (dec == null || !_eq(dec, info)) failures++;
    }
    // The deterministic IRA code should handle this comfortably.
    expect(failures, lessThanOrEqualTo(1),
        reason: '$failures/$trials blocks failed at Eb/N0=2.5 dB');
  });

  test('header code round-trips', () {
    final code = LdpcCode.header();
    expect(code.n, 512);
    expect(code.k, 256);
    final info = Uint8List.fromList(List.generate(32, (i) => i * 7 & 0xFF));
    final bits = code.encode(info);
    final llr = Float64List(code.n);
    for (var i = 0; i < code.n; i++) {
      llr[i] = bits[i] == 0 ? 3.0 : -3.0;
    }
    expect(code.decode(llr), equals(info));
  });

  test('graph construction is deterministic', () {
    final a = LdpcCode.payload(LdpcRate.threeQuarters);
    final b = LdpcCode.payload(LdpcRate.threeQuarters);
    identical(a, b); // cached
    final info = Uint8List(a.infoBytes);
    expect(a.encode(info), equals(b.encode(info)));
  });
}

bool _eq(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

double _gauss(math.Random rng) {
  final u1 = math.max(rng.nextDouble(), 1e-12);
  final u2 = rng.nextDouble();
  return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2);
}
