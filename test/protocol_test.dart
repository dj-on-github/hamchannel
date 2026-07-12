import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hamchannel/dsp/modem_params.dart';
import 'package:hamchannel/modem/modem.dart';
import 'package:hamchannel/proto/link.dart';

/// Two LinkManagers wired back-to-back through a simulated block channel.
/// The channel mimics the modem's framing: payload split into
/// (infoBytes-4)-byte blocks, each of which can be dropped to simulate an
/// LDPC decode failure.
class Station {
  Station(this.call, Directory tmp)
      : store = FileStore(
          sharedDir: Directory('${tmp.path}/$call/shared'),
          recvDir: Directory('${tmp.path}/$call/received'),
        );

  final String call;
  final FileStore store;
  late LinkManager link;
  Station? peer;
  final events = <LinkEvent>[];
  int burstsSent = 0;

  /// Returns true if [blockIdx] of burst number [burstNo] should be lost.
  bool Function(int burstNo, int blockIdx) lossFn = (_, __) => false;

  static const rate = LdpcRate.half;
  static int get userBytes => ModemTransmitter.blockUserBytes(rate);

  void init() {
    link = LinkManager(
      cfg: LinkConfig()
        ..myCall = call
        ..remoteCall = peer!.call
        ..maxChunksPerBurst = 8
        ..turnaroundMs = 60
        ..ackTimeoutMs = 900
        ..maxRetries = 6,
      store: store,
      sendBurst: _sendBurst,
      blockUserBytes: () => userBytes,
      channelBusy: () => false,
      servicePeriodMs: 40,
    );
    link.events.listen(events.add);
  }

  Future<void> _sendBurst(
      int type, int flags, String dst, Uint8List payload) async {
    final burstNo = burstsSent++;
    final user = userBytes;
    final blockCount =
        payload.isEmpty ? 0 : (payload.length + user - 1) ~/ user;
    var lost = 0;
    final blocks = List<Uint8List?>.generate(blockCount, (i) {
      if (lossFn(burstNo, i)) {
        lost++;
        return null;
      }
      final s = i * user;
      final e = math.min(s + user, payload.length);
      return Uint8List.fromList(payload.sublist(s, e));
    });
    final header = BurstHeader(
      type: type,
      srcCall: call,
      dstCall: dst,
      burstId: burstNo,
      mod: SubcarrierModulation.qpsk,
      rate: rate,
      blockCount: blockCount,
      payloadBytes: payload.length,
      flags: flags,
    );
    final rx = ReceivedBurst(
        header: header, blocks: blocks, snrDb: 20, blockErrors: lost);
    // Simulated propagation delay.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    peer!.link.onBurstReceived(rx);
  }

  void dispose() => link.dispose();
}

Future<T?> waitFor<T extends LinkEvent>(
    Station s, bool Function(T) pred, Duration timeout) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    for (final e in s.events) {
      if (e is T && pred(e)) return e;
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  return null;
}

void main() {
  late Directory tmp;
  late Station a, b;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('hamchan_test');
    a = Station('W1AW', tmp);
    b = Station('KD2XYZ', tmp);
    a.peer = b;
    b.peer = a;
    a.init();
    b.init();
  });

  tearDown(() {
    a.dispose();
    b.dispose();
    tmp.deleteSync(recursive: true);
  });

  test('text message is delivered and acked', () async {
    final id = a.link.sendMessage('Hello from W1AW via OFDM');
    final got = await waitFor<ChatEvent>(
        b, (e) => !e.outgoing && e.text.contains('Hello'),
        const Duration(seconds: 5));
    expect(got, isNotNull, reason: 'message should arrive at B');
    final ack = await waitFor<MsgStatusEvent>(
        a, (e) => e.msgId == id && e.status == 'acked',
        const Duration(seconds: 5));
    expect(ack, isNotNull, reason: 'A should see the ACK');
  });

  test('file transfer completes over a clean channel', () async {
    final data =
        Uint8List.fromList(List.generate(2500, (i) => (i * 13 + 5) & 0xFF));
    a.link.sendFile('test.bin', data);
    final done = await waitFor<TransferEvent>(
        b, (e) => e.incoming && e.done, const Duration(seconds: 20));
    expect(done, isNotNull, reason: 'B should complete the transfer');
    final files = b.store.receivedFiles();
    expect(files, hasLength(1));
    expect(files.first.readAsBytesSync(), equals(data));
    // Sender learns of completion.
    final sDone = await waitFor<TransferEvent>(
        a, (e) => !e.incoming && e.done, const Duration(seconds: 10));
    expect(sDone, isNotNull);
  });

  test('file transfer recovers from lost blocks via NAK', () async {
    // Drop two payload blocks of the first data burst A sends.
    var armed = true;
    a.lossFn = (burstNo, blockIdx) {
      if (armed && (blockIdx == 2 || blockIdx == 4)) {
        return true;
      }
      return false;
    };
    final data =
        Uint8List.fromList(List.generate(1400, (i) => (i * 7 + 1) & 0xFF));
    a.link.sendFile('recover.bin', data);
    final done = await waitFor<TransferEvent>(
        b, (e) => e.incoming && e.done, const Duration(seconds: 25));
    armed = false;
    expect(done, isNotNull, reason: 'transfer should recover from NAKs');
    final files = b.store.receivedFiles();
    expect(files, hasLength(1));
    expect(files.first.readAsBytesSync(), equals(data));
  });

  test('remote file request round-trip', () async {
    final content = Uint8List.fromList(
        List.generate(900, (i) => (i * 3 + 11) & 0xFF));
    File('${b.store.sharedDir.path}/manual.pdf').writeAsBytesSync(content);

    a.link.requestFile('manual.pdf');
    final done = await waitFor<TransferEvent>(
        a, (e) => e.incoming && e.done, const Duration(seconds: 25));
    expect(done, isNotNull, reason: 'requested file should arrive at A');
    final files = a.store.receivedFiles();
    expect(files, hasLength(1));
    expect(files.first.readAsBytesSync(), equals(content));
  });

  test('file listing request', () async {
    File('${b.store.sharedDir.path}/one.txt').writeAsStringSync('x' * 10);
    File('${b.store.sharedDir.path}/two.txt').writeAsStringSync('y' * 20);
    a.link.requestListing();
    final ev = await waitFor<FileListEvent>(
        a, (e) => e.listing.contains('one.txt'), const Duration(seconds: 8));
    expect(ev, isNotNull);
    expect(ev!.listing, contains('two.txt'));
    expect(ev.listing, contains('\t20'));
  });

  test('request for a missing file is refused politely', () async {
    a.link.requestFile('nope.bin');
    final log = await waitFor<LogEvent>(
        a, (e) => e.line.contains('refused'), const Duration(seconds: 8));
    expect(log, isNotNull);
  });
}
