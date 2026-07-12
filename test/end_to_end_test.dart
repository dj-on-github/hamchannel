import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hamchannel/audio/audio_backend.dart';
import 'package:hamchannel/dsp/modem_params.dart';
import 'package:hamchannel/modem/modem_service.dart';

/// Two full modem stacks (audio -> OFDM -> LDPC -> ARQ) wired speaker-to-mic
/// with additive noise, exactly like two laptops + two radios would be.
class CrossedBackend implements AudioBackend {
  CrossedBackend(this.seed);

  final int seed;
  CrossedBackend? partner;
  final _rx = StreamController<Float64List>.broadcast();
  bool _playing = false;

  @override
  Stream<Float64List> get rx => _rx.stream;

  @override
  bool get isPlaying => _playing;

  @override
  Future<void> start() async {}

  @override
  Future<void> playBurst(Float64List samples) async {
    _playing = true;
    try {
      final rng = math.Random(seed);
      final y = Float64List(samples.length + 2400);
      for (var i = 0; i < y.length; i++) {
        y[i] = 0.002 * _gauss(rng);
      }
      for (var i = 0; i < samples.length; i++) {
        y[1200 + i] += 0.5 * samples[i];
      }
      const chunk = 2400;
      for (var o = 0; o < y.length; o += chunk) {
        final e = math.min(o + chunk, y.length);
        partner!._rx.add(Float64List.sublistView(y, o, e));
        await Future<void>.delayed(Duration.zero);
      }
    } finally {
      _playing = false;
    }
  }

  @override
  Future<void> stop() async {}

  static double _gauss(math.Random rng) {
    final u1 = math.max(rng.nextDouble(), 1e-12);
    final u2 = rng.nextDouble();
    return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2);
  }
}

void main() {
  late Directory tmp;
  late ModemService alice, bob;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('hamchan_e2e');
    final ba = CrossedBackend(1);
    final bb = CrossedBackend(2);
    ba.partner = bb;
    bb.partner = ba;

    AppConfig mkCfg(String call, String remote) => AppConfig()
      ..myCall = call
      ..remoteCall = remote
      ..width = ChannelWidth.narrow
      ..modulation = SubcarrierModulation.qpsk
      ..ldpcRate = LdpcRate.half
      ..leaderSymbols = 8
      ..ackTimeoutSec = 4;

    alice = ModemService(
      config: mkCfg('W1AW', 'KD2XYZ'),
      backendFactory: (_) => ba,
      sharedDir: Directory('${tmp.path}/a/shared'),
      recvDir: Directory('${tmp.path}/a/received'),
    );
    bob = ModemService(
      config: mkCfg('KD2XYZ', 'W1AW'),
      backendFactory: (_) => bb,
      sharedDir: Directory('${tmp.path}/b/shared'),
      recvDir: Directory('${tmp.path}/b/received'),
    );
    await alice.start();
    await bob.start();
    expect(alice.running, isTrue, reason: alice.lastError);
    expect(bob.running, isTrue, reason: bob.lastError);
  });

  tearDown(() async {
    await alice.stop();
    await bob.stop();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<bool> waitUntil(bool Function() pred, Duration timeout) async {
    final end = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(end)) {
      if (pred()) return true;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return pred();
  }

  test('message travels over the simulated audio channel and is acked',
      () async {
    alice.sendMessage('CQ CQ de W1AW — OFDM test 73');
    final arrived = await waitUntil(
        () => bob.chat.any((c) => !c.outgoing && c.text.contains('W1AW')),
        const Duration(seconds: 20));
    expect(arrived, isTrue,
        reason: 'bob log: ${bob.log.join(' | ')}');
    final acked = await waitUntil(
        () => alice.chat.any((c) => c.outgoing && c.status == 'acked'),
        const Duration(seconds: 20));
    expect(acked, isTrue,
        reason: 'alice log: ${alice.log.join(' | ')}');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('file transfer end-to-end through the audio channel', () async {
    final data =
        Uint8List.fromList(List.generate(1800, (i) => (i * 29 + 3) & 0xFF));
    alice.sendFile('photo.jpg', data);
    final done = await waitUntil(
        () => bob.store.receivedFiles().isNotEmpty,
        const Duration(seconds: 60));
    expect(done, isTrue, reason: 'bob log: ${bob.log.join(' | ')}');
    final f = bob.store.receivedFiles().first;
    expect(f.readAsBytesSync(), equals(data));
  }, timeout: const Timeout(Duration(minutes: 3)));
}
