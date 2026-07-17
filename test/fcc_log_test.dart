import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hamchannel/audio/audio_backend.dart';
import 'package:hamchannel/dsp/modem_params.dart';
import 'package:hamchannel/modem/modem_service.dart';
import 'package:hamchannel/proto/packets.dart';

void main() {
  test('formatFccLogLine has all required fields in order', () {
    final line = formatFccLogLine(
      tx: true,
      whenUtc: DateTime.utc(2026, 7, 15, 21, 4, 3),
      from: 'W1AW',
      to: 'KD2XYZ',
      width: ChannelWidth.narrow,
      rate: LdpcRate.half,
      content: 'MSG "hello"',
    );
    expect(line,
        'Tx 2026-07-15 21:04:03Z W1AW KD2XYZ 12kHz OFDM-240 LDPC-1/2 MSG "hello"');

    final rx = formatFccLogLine(
      tx: false,
      whenUtc: DateTime.utc(2026, 1, 2, 3, 4, 5),
      from: 'KD2XYZ',
      to: 'CQ',
      width: ChannelWidth.hf,
      rate: LdpcRate.fiveSixths,
      content: 'BEACON "hi"',
    );
    expect(rx, startsWith('Rx 2026-01-02 03:04:05Z KD2XYZ CQ 2.8kHz '
        'OFDM-52 LDPC-5/6 '));
  });

  test('summarizePayload describes packets', () {
    final payload = BytesBuilder()
      ..add(buildMsg(1, 'test message'))
      ..add(buildMsgAck(2))
      ..add(buildFileData(3, 0, Uint8List(10)))
      ..add(buildFileData(3, 1, Uint8List(10)));
    final s = ModemService.summarizePayload(payload.takeBytes());
    expect(s, contains('MSG "test message"'));
    expect(s, contains('MSG_ACK'));
    expect(s, contains('FILE_DATA x2'));
  });

  test('Tx and Rx lines are written through the loopback modem', () async {
    final tmp = Directory.systemTemp.createTempSync('hamchan_fcc');
    final logPath = '${tmp.path}/fcc.log';
    // Two crossed services so a real reception occurs.
    final cfgA = AppConfig()
      ..myCall = 'W1AW'
      ..remoteCall = 'CQ' // broadcast: no ack cycle needed
      ..width = ChannelWidth.narrow
      ..modulation = SubcarrierModulation.qpsk
      ..ldpcRate = LdpcRate.half
      ..leaderSymbols = 8
      ..fccLogEnabled = true
      ..fccLogPath = logPath;
    final a = ModemService(
      config: cfgA,
      backendFactory: (_) => LoopbackAudioBackend(),
      sharedDir: Directory('${tmp.path}/shared'),
      recvDir: Directory('${tmp.path}/received'),
    );
    await a.start();
    expect(a.running, isTrue, reason: a.lastError);
    a.sendMessage('FCC log test de W1AW');

    // Wait for the Tx line to appear.
    final end = DateTime.now().add(const Duration(seconds: 15));
    while (DateTime.now().isBefore(end)) {
      if (File(logPath).existsSync() &&
          File(logPath).readAsStringSync().contains('Tx ')) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    await a.stop();
    final text = File(logPath).readAsStringSync();
    expect(text, contains('Tx '));
    expect(text, contains('W1AW CQ 12kHz OFDM-240 LDPC-1/2'));
    expect(text, contains('MSG "FCC log test de W1AW"'));
    tmp.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 1)));
}
