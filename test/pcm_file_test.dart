import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hamchannel/audio/audio_backend.dart';
import 'package:hamchannel/dsp/modem_params.dart';
import 'package:hamchannel/modem/modem_service.dart';

/// Station A transmits with PCM capture enabled; the resulting f64le file is
/// then read into station B's receiver as if it came from the sound card.
void main() {
  late Directory tmp;
  late ModemService a, b;

  AppConfig mkCfg(String call, String remote) => AppConfig()
    ..myCall = call
    ..remoteCall = remote
    ..width = ChannelWidth.narrow
    ..modulation = SubcarrierModulation.qpsk
    ..ldpcRate = LdpcRate.half
    ..leaderSymbols = 8
    ..ackTimeoutSec = 3;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('hamchan_pcm');
    a = ModemService(
      config: mkCfg('W1AW', 'KD2XYZ'),
      backendFactory: (_) => LoopbackAudioBackend(),
      sharedDir: Directory('${tmp.path}/a/shared'),
      recvDir: Directory('${tmp.path}/a/received'),
    );
    b = ModemService(
      config: mkCfg('KD2XYZ', 'W1AW'),
      backendFactory: (_) => LoopbackAudioBackend(),
      sharedDir: Directory('${tmp.path}/b/shared'),
      recvDir: Directory('${tmp.path}/b/received'),
    );
    await a.start();
    await b.start();
    expect(a.running, isTrue, reason: a.lastError);
    expect(b.running, isTrue, reason: b.lastError);
  });

  tearDown(() async {
    await a.stop();
    await b.stop();
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

  test('TX capture to f64le PCM file replays into another receiver',
      () async {
    final pcmPath = '${tmp.path}/capture.f64';
    await a.startPcmWrite(pcmPath);

    a.sendMessage('PCM offline test de W1AW');
    // Wait for at least one burst to be written to the file.
    final wrote = await waitUntil(
        () =>
            File(pcmPath).existsSync() && File(pcmPath).lengthSync() > 100000,
        const Duration(seconds: 15));
    expect(wrote, isTrue, reason: 'a log: ${a.log.join(' | ')}');
    await a.stopPcmWrite();
    expect(a.pcmWriting, isFalse);

    // File length must be a whole number of float64 samples.
    expect(File(pcmPath).lengthSync() % 8, 0);

    // Replay into station B.
    await b.readPcmFile(pcmPath);
    final got = await waitUntil(
        () => b.chat.any((c) => !c.outgoing && c.text.contains('PCM offline')),
        const Duration(seconds: 10));
    expect(got, isTrue, reason: 'b log: ${b.log.join(' | ')}');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('reading a PCM file requires a running modem', () async {
    final path = '${tmp.path}/none.f64';
    File(path).writeAsBytesSync(List.filled(800, 0));
    await b.stop();
    await b.readPcmFile(path);
    expect(b.lastError, contains('start the modem'));
  });
}
