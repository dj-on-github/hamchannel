import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hamchannel/dsp/modem_params.dart';
import 'package:hamchannel/modem/modem.dart';

/// Channel impairments used across the loopback tests.
///
/// [snrDb] is the true time-domain SNR (burst RMS vs noise RMS). The
/// per-carrier SNR is ~3 dB higher in narrow mode (signal occupies about
/// half the Nyquist band) and about equal in wide mode.
Float64List impair(
  Float64List x, {
  double gain = 0.5,
  double snrDb = 30,
  double sfoPpm = 0,
  int delaySamples = 313,
  int seed = 1234,
  double clip = 1.0,
}) {
  final rng = math.Random(seed);
  // Sample-frequency offset via linear-interpolation resampling.
  final ratio = 1 + sfoPpm * 1e-6;
  final outLen = (x.length / ratio).floor() - 1;
  final y = Float64List(delaySamples + outLen + 4800);
  var p = 0.0;
  final sigLen = x.length - 4800; // exclude the silent tail
  for (var i = 0; i < sigLen; i++) {
    p += x[i] * x[i];
  }
  final sigRms = gain * math.sqrt(p / sigLen);
  final noise = sigRms * math.pow(10, -snrDb / 20).toDouble();
  for (var i = 0; i < y.length; i++) {
    y[i] = noise * _gauss(rng);
  }
  for (var i = 0; i < outLen; i++) {
    final srcPos = i * ratio;
    final i0 = srcPos.floor();
    final frac = srcPos - i0;
    if (i0 + 1 >= x.length) break;
    final v = x[i0] * (1 - frac) + x[i0 + 1] * frac;
    var g = v * gain;
    if (g > clip) g = clip;
    if (g < -clip) g = -clip;
    y[delaySamples + i] += g;
  }
  return y;
}

double _gauss(math.Random rng) {
  final u1 = math.max(rng.nextDouble(), 1e-12);
  final u2 = rng.nextDouble();
  return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2);
}

/// Modulate a payload, push the impaired waveform through the receiver in
/// small chunks, and return the received bursts.
List<ReceivedBurst> runOnce({
  required ChannelWidth width,
  required SubcarrierModulation mod,
  required LdpcRate rate,
  required Uint8List payload,
  double snrDb = 30,
  double sfoPpm = 0,
  double gain = 0.5,
  int seed = 99,
}) {
  final p = ModemParams(width: width);
  final tx = ModemTransmitter(p);
  final wave = tx.buildBurst(
    type: 0,
    srcCall: 'W1AW',
    dstCall: 'KD2XYZ',
    burstId: 7,
    mod: mod,
    rate: rate,
    payload: payload,
    level: 0.8,
  );
  final rxWave = impair(wave,
      gain: gain, snrDb: snrDb, sfoPpm: sfoPpm, seed: seed);
  final got = <ReceivedBurst>[];
  final rx = ModemReceiver(p, onBurst: got.add);
  const chunk = 1600;
  for (var o = 0; o < rxWave.length; o += chunk) {
    final e = math.min(o + chunk, rxWave.length);
    rx.addSamples(Float64List.sublistView(rxWave, o, e));
  }
  return got;
}

void main() {
  final payload = Uint8List.fromList(
      List.generate(700, (i) => (i * 31 + 7) & 0xFF));

  test('narrow QPSK r1/2: clean channel', () {
    final got = runOnce(
      width: ChannelWidth.narrow,
      mod: SubcarrierModulation.qpsk,
      rate: LdpcRate.half,
      payload: payload,
      snrDb: 30,
    );
    expect(got, hasLength(1));
    final b = got.first;
    expect(b.header.srcCall, 'W1AW');
    expect(b.header.dstCall, 'KD2XYZ');
    expect(b.blockErrors, 0);
    expect(b.payload, isNotNull);
    expect(b.payload, equals(payload));
  });

  test('narrow BPSK r1/2 survives low SNR (3 dB)', () {
    final got = runOnce(
      width: ChannelWidth.narrow,
      mod: SubcarrierModulation.bpsk,
      rate: LdpcRate.half,
      payload: payload,
      snrDb: 3,
      gain: 0.4,
    );
    expect(got, hasLength(1));
    expect(got.first.payload, equals(payload));
  });

  test('narrow QPSK r1/2 at 6 dB', () {
    final got = runOnce(
      width: ChannelWidth.narrow,
      mod: SubcarrierModulation.qpsk,
      rate: LdpcRate.half,
      payload: payload,
      snrDb: 6,
    );
    expect(got, hasLength(1));
    expect(got.first.payload, equals(payload));
  });

  test('wide 16-QAM r3/4 at 14 dB', () {
    final got = runOnce(
      width: ChannelWidth.wide,
      mod: SubcarrierModulation.qam16,
      rate: LdpcRate.threeQuarters,
      payload: payload,
      snrDb: 14,
    );
    expect(got, hasLength(1));
    expect(got.first.payload, equals(payload));
  });

  test('sample clock offset +-50 ppm is tracked', () {
    for (final ppm in [-50.0, 50.0]) {
      final got = runOnce(
        width: ChannelWidth.narrow,
        mod: SubcarrierModulation.qpsk,
        rate: LdpcRate.half,
        payload: payload,
        snrDb: 15,
        sfoPpm: ppm,
        seed: 5,
      );
      expect(got, hasLength(1), reason: 'sfo $ppm ppm: burst detected');
      expect(got.first.payload, equals(payload),
          reason: 'sfo $ppm ppm: payload intact');
    }
  });

  test('long burst with multiple timing slips (5 kB, +80 ppm)', () {
    final big =
        Uint8List.fromList(List.generate(5000, (i) => (i * 17 + 3) & 0xFF));
    final got = runOnce(
      width: ChannelWidth.narrow,
      mod: SubcarrierModulation.qpsk,
      rate: LdpcRate.half,
      payload: big,
      snrDb: 15,
      sfoPpm: 80,
    );
    expect(got, hasLength(1));
    expect(got.first.payload, equals(big));
  });

  test('64-QAM r5/6 wide (fast mode) at 22 dB', () {
    final got = runOnce(
      width: ChannelWidth.wide,
      mod: SubcarrierModulation.qam64,
      rate: LdpcRate.fiveSixths,
      payload: payload,
      snrDb: 22,
      gain: 0.6,
    );
    expect(got, hasLength(1));
    expect(got.first.payload, equals(payload));
  });

  test('empty payload (header-only burst) round-trips', () {
    final got = runOnce(
      width: ChannelWidth.narrow,
      mod: SubcarrierModulation.qpsk,
      rate: LdpcRate.half,
      payload: Uint8List(0),
      snrDb: 30,
    );
    expect(got, hasLength(1));
    expect(got.first.header.blockCount, 0);
  });

  test('back-to-back bursts are both received', () {
    final p = ModemParams(width: ChannelWidth.narrow);
    final tx = ModemTransmitter(p);
    final w1 = tx.buildBurst(
        type: 0,
        srcCall: 'W1AW',
        dstCall: 'CQ',
        burstId: 1,
        mod: SubcarrierModulation.qpsk,
        rate: LdpcRate.half,
        payload: Uint8List.fromList(List.filled(100, 0xA5)));
    final w2 = tx.buildBurst(
        type: 1,
        srcCall: 'KD2XYZ',
        dstCall: 'CQ',
        burstId: 2,
        mod: SubcarrierModulation.qpsk,
        rate: LdpcRate.half,
        payload: Uint8List.fromList(List.filled(80, 0x5A)));
    final gap = Float64List(9600);
    final all = Float64List(w1.length + gap.length + w2.length);
    all.setRange(0, w1.length, impairInPlace(w1));
    all.setRange(w1.length, w1.length + gap.length, gap);
    all.setRange(w1.length + gap.length, all.length, impairInPlace(w2));

    final got = <ReceivedBurst>[];
    final rx = ModemReceiver(p, onBurst: got.add);
    const chunk = 2400;
    for (var o = 0; o < all.length; o += chunk) {
      final e = math.min(o + chunk, all.length);
      rx.addSamples(Float64List.sublistView(all, o, e));
    }
    expect(got, hasLength(2));
    expect(got[0].header.burstId, 1);
    expect(got[1].header.burstId, 2);
  });
}

/// Light noise + gain, no resample/delay (for concatenation tests).
Float64List impairInPlace(Float64List x) {
  final rng = math.Random(3);
  final y = Float64List(x.length);
  for (var i = 0; i < x.length; i++) {
    y[i] = 0.5 * x[i] + 0.003 * _gauss(rng);
  }
  return y;
}
