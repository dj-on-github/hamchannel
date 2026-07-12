/// Link manager: half-duplex ARQ over the burst modem.
///
/// Responsibilities:
///  * queues outgoing text messages and file transfers,
///  * chunks files into LDPC-block-aligned FILE_DATA packets,
///  * requests / grants retransmissions with NAK bitmaps,
///  * answers file requests and listing requests from the remote station,
///  * emits UI events (messages, progress, log lines).
///
/// Every burst carries the local callsign in its header (FCC Part 97
/// station identification).
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../dsp/modem_params.dart';
import '../modem/modem.dart';
import 'packets.dart';

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

sealed class LinkEvent {}

class ChatEvent extends LinkEvent {
  ChatEvent(this.from, this.to, this.text, {required this.outgoing, this.status = ''});
  final String from, to, text;
  final bool outgoing;
  final String status;
}

class MsgStatusEvent extends LinkEvent {
  MsgStatusEvent(this.msgId, this.status);
  final int msgId;
  final String status; // sent/acked/failed
}

class TransferEvent extends LinkEvent {
  TransferEvent({
    required this.key,
    required this.name,
    required this.incoming,
    required this.done,
    required this.failed,
    required this.chunksDone,
    required this.chunksTotal,
    this.peer = '',
    this.savedPath,
  });
  final String key;
  final String name;
  final bool incoming;
  final bool done;
  final bool failed;
  final int chunksDone;
  final int chunksTotal;
  final String peer;
  final String? savedPath;
}

class FileListEvent extends LinkEvent {
  FileListEvent(this.peer, this.listing);
  final String peer;
  final String listing;
}

class ReceivedFilesChangedEvent extends LinkEvent {}

class LogEvent extends LinkEvent {
  LogEvent(this.line);
  final String line;
}

// ---------------------------------------------------------------------------
// File store
// ---------------------------------------------------------------------------

class FileStore {
  FileStore({required this.sharedDir, required this.recvDir}) {
    sharedDir.createSync(recursive: true);
    recvDir.createSync(recursive: true);
  }

  final Directory sharedDir;
  final Directory recvDir;

  List<File> sharedFiles() => sharedDir
      .listSync()
      .whereType<File>()
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  List<File> receivedFiles() => recvDir
      .listSync()
      .whereType<File>()
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  File? findShared(String name) {
    final clean = _sanitize(name);
    for (final f in sharedFiles()) {
      if (f.uri.pathSegments.last == clean) return f;
    }
    return null;
  }

  String saveReceived(String name, Uint8List bytes) {
    var clean = _sanitize(name);
    var f = File('${recvDir.path}/$clean');
    var n = 1;
    while (f.existsSync()) {
      final dot = clean.lastIndexOf('.');
      final stem = dot > 0 ? clean.substring(0, dot) : clean;
      final ext = dot > 0 ? clean.substring(dot) : '';
      f = File('${recvDir.path}/$stem($n)$ext');
      n++;
    }
    f.writeAsBytesSync(bytes);
    return f.path;
  }

  static String _sanitize(String name) {
    var s = name.split('/').last.split('\\').last;
    s = s.replaceAll(RegExp(r'[\x00-\x1f:*?"<>|]'), '_');
    if (s.isEmpty || s == '.' || s == '..') s = 'file';
    return s;
  }
}

// ---------------------------------------------------------------------------
// Transfers
// ---------------------------------------------------------------------------

class _Outgoing {
  _Outgoing({
    required this.fileId,
    required this.name,
    required this.bytes,
    required this.chunkBytes,
    required this.dst,
  })  : sha = Uint8List.fromList(crypto.sha256.convert(bytes).bytes),
        chunkCount = (bytes.length + chunkBytes - 1) ~/ chunkBytes {
    toSend = List<int>.generate(chunkCount, (i) => i);
  }

  final int fileId;
  final String name;
  final Uint8List bytes;
  final int chunkBytes;
  final String dst;
  final Uint8List sha;
  final int chunkCount;
  late List<int> toSend; // chunk indices still needing transmission
  bool awaitingAck = false;
  int deadlineMs = 0;
  int retries = 0;
  bool done = false, failed = false;

  Uint8List chunk(int i) {
    final s = i * chunkBytes;
    final e = (s + chunkBytes).clamp(0, bytes.length);
    return Uint8List.sublistView(bytes, s, e);
  }

  FileMetaPkt meta() => FileMetaPkt(
        fileId: fileId,
        name: name,
        size: bytes.length,
        sha256: sha,
        chunkBytes: chunkBytes,
        chunkCount: chunkCount,
      );
}

class _Incoming {
  _Incoming(this.peer, this.fileId);
  final String peer;
  final int fileId;
  FileMetaPkt? meta;
  final Map<int, Uint8List> chunks = {};
  bool done = false, failed = false;
  int lastTouchedMs = 0;

  int get total => meta?.chunkCount ?? 0;
  List<int> missing() {
    final m = meta;
    if (m == null) return const [];
    return [
      for (var i = 0; i < m.chunkCount; i++)
        if (!chunks.containsKey(i)) i
    ];
  }
}

class _OutMsg {
  _OutMsg(this.id, this.dst, this.text);
  final int id;
  final String dst;
  final String text;
  bool awaitingAck = false;
  int deadlineMs = 0;
  int retries = 0;
}

// ---------------------------------------------------------------------------
// Link manager
// ---------------------------------------------------------------------------

/// Burst frame types (header.type).
class FrameType {
  static const int data = 0;
  static const int response = 1;
  static const int beacon = 2;
}

/// Header flag bits.
class FrameFlags {
  static const int ackReq = 0x01;
}

typedef SendBurstFn = Future<void> Function(
    int type, int flags, String dst, Uint8List payload);

class LinkConfig {
  String myCall = 'NOCALL';
  String remoteCall = 'CQ';
  int maxChunksPerBurst = 24;
  int turnaroundMs = 800;
  int ackTimeoutMs = 12000;
  int maxRetries = 6;
}

class LinkManager {
  LinkManager({
    required this.cfg,
    required this.store,
    required this.sendBurst,
    required this.blockUserBytes,
    required bool Function() channelBusy,
    int servicePeriodMs = 200,
  }) : _channelBusy = channelBusy {
    _timer = Timer.periodic(Duration(milliseconds: servicePeriodMs), (_) {
      _service();
    });
  }

  final LinkConfig cfg;
  final FileStore store;
  final SendBurstFn sendBurst;

  /// User bytes per LDPC block for the *current* TX configuration.
  final int Function() blockUserBytes;
  final bool Function() _channelBusy;

  final _events = StreamController<LinkEvent>.broadcast();
  Stream<LinkEvent> get events => _events.stream;

  late Timer _timer;
  bool _txBusy = false;
  int _msgSeq = 1;
  int _fileSeq = 1;
  int _reqSeq = 1;
  int _burstSeq = 1;

  final List<_OutMsg> _msgs = [];
  final List<_Outgoing> _outgoing = [];
  final Map<String, _Incoming> _incoming = {}; // key: peer/fileId
  final List<Uint8List> _respPackets = [];
  String _respDst = 'CQ';
  int _respDueMs = 0;
  final List<Uint8List> _userReqPackets = [];
  bool _reqAwaiting = false;
  int _reqDeadlineMs = 0;
  int _reqRetries = 0;
  List<Uint8List> _lastReqPackets = [];

  int get _nowMs => DateTime.now().millisecondsSinceEpoch;

  void _log(String s) => _events.add(LogEvent(s));

  void dispose() {
    _timer.cancel();
    _events.close();
  }

  // ------------------------------ user API --------------------------------

  int sendMessage(String text, {String? dst}) {
    final m = _OutMsg(_msgSeq++, dst ?? cfg.remoteCall, text);
    _msgs.add(m);
    _events.add(ChatEvent(cfg.myCall, m.dst, text, outgoing: true, status: 'queued'));
    return m.id;
  }

  void sendFile(String name, Uint8List bytes, {String? dst}) {
    final chunkBytes = blockUserBytes() - 7;
    final t = _Outgoing(
      fileId: _fileSeq++,
      name: name,
      bytes: bytes,
      chunkBytes: chunkBytes,
      dst: dst ?? cfg.remoteCall,
    );
    _outgoing.add(t);
    _emitOutProgress(t);
    _log('queued file "${t.name}" (${bytes.length} B, ${t.chunkCount} chunks)');
  }

  void requestFile(String name) {
    _userReqPackets.add(buildFileReq(_reqSeq++, name));
    _log('requesting file "$name" from ${cfg.remoteCall}');
  }

  void requestListing() {
    _userReqPackets.add(Uint8List.fromList([PktType.listReq, 0, _reqSeq++ & 0xFF]));
    _log('requesting file list from ${cfg.remoteCall}');
  }

  void sendBeacon(String text) {
    _respPackets.add(buildBeacon(text));
    _respDst = 'CQ';
    _respDueMs = _nowMs;
  }

  // --------------------------- burst reception ----------------------------

  /// Feed every decoded burst here.
  void onBurstReceived(ReceivedBurst b) {
    final h = b.header;
    final forMe = h.dstCall == cfg.myCall || h.dstCall == 'CQ';
    _log('rx burst from ${h.srcCall} to ${h.dstCall} '
        '(${b.blocks.length} blocks, ${b.blockErrors} bad, '
        'SNR ${b.snrDb.toStringAsFixed(1)} dB)');
    if (!forMe) return;

    final peer = h.srcCall;
    var needResponse = (h.flags & FrameFlags.ackReq) != 0;
    final touchedIncoming = <_Incoming>{};

    // Parse maximal runs of consecutive good blocks.
    final runs = <Uint8List>[];
    if (b.blocks.isEmpty) {
      // header-only burst
    } else {
      final bb = BytesBuilder();
      for (var i = 0; i < b.blocks.length; i++) {
        final blk = b.blocks[i];
        if (blk != null) {
          bb.add(blk);
        } else if (bb.length > 0) {
          runs.add(bb.takeBytes());
        }
      }
      if (bb.length > 0) runs.add(bb.takeBytes());
    }

    for (final run in runs) {
      for (final p in Pkt.parseAll(run)) {
        switch (p.type) {
          case PktType.msg:
            final (id, text) = parseMsg(p);
            // Always re-ack (the previous ack may have been lost) but only
            // display a retransmitted message once.
            _respPackets.add(buildMsgAck(id));
            final seenKey = '$peer/$id';
            if (!_seenMsgs.contains(seenKey)) {
              _seenMsgs.add(seenKey);
              if (_seenMsgs.length > 128) {
                _seenMsgs.remove(_seenMsgs.first);
              }
              _events.add(ChatEvent(peer, h.dstCall, text, outgoing: false));
            }
          case PktType.msgAck:
            final id = parseU16Id(p);
            for (final m in _msgs.toList()) {
              if (m.id == id) {
                _msgs.remove(m);
                _events.add(MsgStatusEvent(id, 'acked'));
              }
            }
          case PktType.fileMeta:
            final meta = FileMetaPkt.fromPkt(p);
            final key = '$peer/${meta.fileId}';
            final inc = _incoming.putIfAbsent(key, () => _Incoming(peer, meta.fileId));
            inc.meta ??= meta;
            inc.lastTouchedMs = _nowMs;
            touchedIncoming.add(inc);
          case PktType.fileData:
            final (fileId, chunkIdx, data) = parseFileData(p);
            final key = '$peer/$fileId';
            final inc = _incoming.putIfAbsent(key, () => _Incoming(peer, fileId));
            if (!inc.done) {
              inc.chunks[chunkIdx] = Uint8List.fromList(data);
              inc.lastTouchedMs = _nowMs;
              touchedIncoming.add(inc);
            }
          case PktType.fileNak:
            final nak = FileNak.parse(p);
            for (final t in _outgoing) {
              if (t.fileId == nak.fileId && !t.done) {
                t.awaitingAck = false;
                t.retries = 0;
                t.toSend = nak.missing.toList();
                _log('NAK from $peer: ${nak.missing.length} chunks missing');
                if (nak.missing.isEmpty) {
                  // Peer has everything but hasn't verified yet; wait for DONE.
                }
              }
            }
          case PktType.fileDone:
            final id = parseU16Id(p);
            for (final t in _outgoing.toList()) {
              if (t.fileId == id) {
                t.done = true;
                t.awaitingAck = false;
                _outgoing.remove(t);
                _emitOutProgress(t);
                _log('file "${t.name}" delivered to $peer');
              }
            }
          case PktType.fileReq:
            final (reqId, name) = parseFileReq(p);
            _handleFileRequest(peer, reqId, name);
          case PktType.fileReqNak:
            final (_, reason) = parseTextPkt(p);
            _reqAwaiting = false;
            _lastReqPackets = [];
            _log('file request refused by $peer: $reason');
          case PktType.listReq:
            _respPackets.add(buildTextPkt(PktType.listResp, 0, _makeListing()));
          case PktType.listResp:
            final (_, listing) = parseTextPkt(p);
            _reqAwaiting = false;
            _lastReqPackets = [];
            _events.add(FileListEvent(peer, listing));
          case PktType.beacon:
            _events.add(ChatEvent(peer, 'CQ', parseBeacon(p), outgoing: false));
        }
      }
    }

    // A response to our request-burst counts even without explicit packets.
    if (h.type == FrameType.response && _reqAwaiting) {
      _reqAwaiting = false;
      _lastReqPackets = [];
    }

    // Build transfer status responses.
    for (final inc in touchedIncoming) {
      _serviceIncoming(inc, respond: needResponse);
    }
    if (needResponse || _respPackets.isNotEmpty) {
      _respDst = peer;
      _respDueMs = _nowMs + cfg.turnaroundMs;
      if (needResponse && _respPackets.isEmpty) {
        // Header-only "heard you" response.
        _respPackets.add(Uint8List.fromList([PktType.pad1]));
      }
    }
  }

  void _serviceIncoming(_Incoming inc, {required bool respond}) {
    final meta = inc.meta;
    if (meta == null) {
      if (respond) {
        _respPackets.add(FileNak(inc.fileId, true, const [], 0).build());
      }
      return;
    }
    final missing = inc.missing();
    if (missing.isEmpty && !inc.done) {
      // Assemble and verify.
      final out = BytesBuilder();
      for (var i = 0; i < meta.chunkCount; i++) {
        out.add(inc.chunks[i]!);
      }
      var bytes = out.takeBytes();
      if (bytes.length > meta.size) {
        bytes = Uint8List.sublistView(Uint8List.fromList(bytes), 0, meta.size);
      }
      final sha = crypto.sha256.convert(bytes).bytes;
      var ok = bytes.length == meta.size;
      for (var i = 0; ok && i < 32; i++) {
        if (sha[i] != meta.sha256[i]) ok = false;
      }
      if (ok) {
        inc.done = true;
        final path = store.saveReceived(meta.name, Uint8List.fromList(bytes));
        _respPackets.add(buildFileDone(inc.fileId));
        _events.add(ReceivedFilesChangedEvent());
        _emitInProgress(inc, savedPath: path);
        _log('received file "${meta.name}" (${meta.size} B) -> $path');
      } else {
        inc.failed = true;
        inc.chunks.clear();
        inc.failed = false; // restart transfer from scratch
        _respPackets.add(
            FileNak(inc.fileId, false, List.generate(meta.chunkCount, (i) => i),
                meta.chunkCount)
                .build());
        _log('checksum mismatch on "${meta.name}", requesting resend');
      }
    } else if (inc.done) {
      _respPackets.add(buildFileDone(inc.fileId));
    } else if (respond) {
      _respPackets.add(FileNak(inc.fileId, false, missing, meta.chunkCount).build());
      _emitInProgress(inc);
    } else {
      _emitInProgress(inc);
    }
  }

  final Set<String> _handledReqs = {};
  final Set<String> _seenMsgs = {};

  void _handleFileRequest(String peer, int reqId, String name) {
    // Retransmitted requests (our response got lost) must not queue the
    // file twice.
    final key = '$peer/$reqId/$name';
    if (_handledReqs.contains(key)) return;
    _handledReqs.add(key);
    if (_handledReqs.length > 64) {
      _handledReqs.remove(_handledReqs.first);
    }
    final f = store.findShared(name);
    if (f == null) {
      _respPackets.add(buildTextPkt(PktType.fileReqNak, reqId, 'not found: $name'));
      _log('$peer requested "$name" — not in shared folder');
      return;
    }
    final bytes = f.readAsBytesSync();
    sendFile(f.uri.pathSegments.last, bytes, dst: peer);
    _log('$peer requested "$name" — sending (${bytes.length} B)');
  }

  String _makeListing() {
    final sb = StringBuffer();
    for (final f in store.sharedFiles()) {
      final line = '${f.uri.pathSegments.last}\t${f.lengthSync()}\n';
      if (sb.length + line.length > 1800) break;
      sb.write(line);
    }
    return sb.toString();
  }

  // ------------------------------ TX service ------------------------------

  Future<void> _service() async {
    if (_txBusy || _channelBusy()) return;
    final now = _nowMs;

    // 1. Response bursts (acks/naks/answers) — highest priority.
    if (_respPackets.isNotEmpty && now >= _respDueMs) {
      final pkts = _respPackets.toList();
      _respPackets.clear();
      await _tx(FrameType.response, 0, _respDst, pkts, alignChunks: false);
      return;
    }

    // 2. Stay quiet while a data burst of ours awaits its ACK — the remote
    //    is about to transmit and we must not collide with it.
    for (final t in _outgoing) {
      if (!t.done && !t.failed && t.awaitingAck && now < t.deadlineMs) {
        return;
      }
    }

    // 3. Text messages (bundle everything due). Small and quick, they get
    //    priority over bulk file chunks.
    final due = _msgs
        .where((m) =>
            !m.awaitingAck || now >= m.deadlineMs)
        .toList();
    if (due.isNotEmpty) {
      final sendable = <_OutMsg>[];
      for (final m in due) {
        if (m.awaitingAck) {
          m.retries++;
          if (m.retries > cfg.maxRetries) {
            _msgs.remove(m);
            _events.add(MsgStatusEvent(m.id, 'failed'));
            continue;
          }
        }
        sendable.add(m);
      }
      if (sendable.isNotEmpty) {
        final dst = sendable.first.dst;
        final batch = sendable.where((m) => m.dst == dst).toList();
        final wantAck = dst != 'CQ';
        await _tx(FrameType.data, wantAck ? FrameFlags.ackReq : 0, dst,
            [for (final m in batch) buildMsg(m.id, m.text)],
            alignChunks: false);
        for (final m in batch) {
          if (!wantAck) {
            _msgs.remove(m);
            _events.add(MsgStatusEvent(m.id, 'sent'));
          } else {
            m.awaitingAck = true;
            m.deadlineMs = _nowMs + cfg.ackTimeoutMs;
            _events.add(MsgStatusEvent(m.id, m.retries == 0 ? 'sent' : 'retry ${m.retries}'));
          }
        }
        return;
      }
    }

    // 4. Active outgoing file transfer.
    for (final t in _outgoing) {
      if (t.done || t.failed) continue;
      if (t.awaitingAck) {
        // Deadline passed (checked above) — this is a retry.
        t.retries++;
        if (t.retries > cfg.maxRetries) {
          t.failed = true;
          _emitOutProgress(t);
          _log('file "${t.name}" failed after ${cfg.maxRetries} retries');
          continue;
        }
        t.awaitingAck = false;
      }
      final n = t.toSend.length.clamp(0, cfg.maxChunksPerBurst);
      final send = t.toSend.take(n).toList();
      final rest = t.toSend.skip(n).toList();
      await _tx(FrameType.data, FrameFlags.ackReq, t.dst, [
        t.meta().build(),
        for (final i in send) buildFileData(t.fileId, i, t.chunk(i)),
      ], alignChunks: true, chunkStartIndex: 1);
      t.toSend = rest;
      t.awaitingAck = true;
      t.deadlineMs = _nowMs + cfg.ackTimeoutMs;
      _emitOutProgress(t);
      return;
    }

    // 5. User requests (file / listing).
    if (_userReqPackets.isNotEmpty && !_reqAwaiting) {
      final pkts = _userReqPackets.toList();
      _userReqPackets.clear();
      _lastReqPackets = pkts;
      _reqRetries = 0;
      await _tx(FrameType.data, FrameFlags.ackReq, cfg.remoteCall, pkts,
          alignChunks: false);
      _reqAwaiting = true;
      _reqDeadlineMs = _nowMs + cfg.ackTimeoutMs;
      return;
    }
    if (_reqAwaiting && now >= _reqDeadlineMs) {
      _reqRetries++;
      if (_reqRetries > cfg.maxRetries) {
        _reqAwaiting = false;
        _lastReqPackets = [];
        _log('request failed: no response from ${cfg.remoteCall}');
      } else if (_lastReqPackets.isNotEmpty) {
        await _tx(FrameType.data, FrameFlags.ackReq, cfg.remoteCall,
            _lastReqPackets, alignChunks: false);
        _reqDeadlineMs = _nowMs + cfg.ackTimeoutMs;
      }
    }
  }

  Future<void> _tx(int type, int flags, String dst, List<Uint8List> pkts,
      {required bool alignChunks, int chunkStartIndex = 0}) async {
    final builder = BurstPayloadBuilder(blockUserBytes());
    for (var i = 0; i < pkts.length; i++) {
      if (alignChunks && i == chunkStartIndex) builder.alignToBlock();
      builder.add(pkts[i]);
    }
    final payload = builder.take();
    _txBusy = true;
    try {
      await sendBurst(type, flags, dst, payload);
    } catch (e) {
      _log('tx error: $e');
    } finally {
      _txBusy = false;
    }
  }

  void _emitOutProgress(_Outgoing t) {
    _events.add(TransferEvent(
      key: 'out/${t.fileId}',
      name: t.name,
      incoming: false,
      done: t.done,
      failed: t.failed,
      chunksDone: t.chunkCount - t.toSend.length,
      chunksTotal: t.chunkCount,
      peer: t.dst,
    ));
  }

  void _emitInProgress(_Incoming inc, {String? savedPath}) {
    final meta = inc.meta;
    _events.add(TransferEvent(
      key: 'in/${inc.peer}/${inc.fileId}',
      name: meta?.name ?? '#${inc.fileId}',
      incoming: true,
      done: inc.done,
      failed: inc.failed,
      chunksDone: inc.chunks.length,
      chunksTotal: meta?.chunkCount ?? 0,
      peer: inc.peer,
      savedPath: savedPath,
    ));
  }
}
