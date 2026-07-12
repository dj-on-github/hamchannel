/// Application packets carried inside burst payloads.
///
/// Wire format: every packet starts with a 1-byte type. Fixed fields are
/// big-endian. A burst payload is a concatenation of packets; padding
/// packets align file chunks to LDPC block boundaries so a failed block
/// costs exactly one chunk.
library;

import 'dart:convert';
import 'dart:typed_data';

class PktType {
  static const int pad1 = 0x00; // single padding byte
  static const int padBlk = 0x01; // u16 len, then len ignored bytes
  static const int msg = 0x10; // u16 msgId, u16 len, utf8 text
  static const int msgAck = 0x11; // u16 msgId
  static const int fileMeta = 0x20; // meta, see FileMetaPkt
  static const int fileData = 0x21; // u16 fileId, u16 chunkIdx, rest = data
  static const int fileNak = 0x22; // u16 fileId, u8 flags, u16 nBits, bitmap
  static const int fileDone = 0x23; // u16 fileId
  static const int fileReq = 0x30; // u16 reqId, u8 nameLen, name
  static const int fileReqNak = 0x31; // u16 reqId, u16 len, utf8 reason
  static const int listReq = 0x32; // u16 reqId
  static const int listResp = 0x33; // u16 reqId, u16 len, utf8 listing
  static const int beacon = 0x40; // u16 len, utf8 text
}

class Pkt {
  Pkt(this.type, this.body);
  final int type;
  final Uint8List body; // fields after the type byte

  static List<Pkt> parseAll(Uint8List buf) {
    final out = <Pkt>[];
    var o = 0;
    ByteData bd = ByteData.sublistView(buf);
    while (o < buf.length) {
      final t = buf[o];
      switch (t) {
        case PktType.pad1:
          o += 1;
        case PktType.padBlk:
          if (o + 3 > buf.length) return out;
          o += 3 + bd.getUint16(o + 1);
        case PktType.msg:
        case PktType.listResp:
        case PktType.fileReqNak:
          if (o + 5 > buf.length) return out;
          final len = bd.getUint16(o + 3);
          if (o + 5 + len > buf.length) return out;
          out.add(Pkt(t, Uint8List.sublistView(buf, o + 1, o + 5 + len)));
          o += 5 + len;
        case PktType.beacon:
          if (o + 3 > buf.length) return out;
          final len = bd.getUint16(o + 1);
          if (o + 3 + len > buf.length) return out;
          out.add(Pkt(t, Uint8List.sublistView(buf, o + 1, o + 3 + len)));
          o += 3 + len;
        case PktType.msgAck:
        case PktType.fileDone:
        case PktType.listReq:
          if (o + 3 > buf.length) return out;
          out.add(Pkt(t, Uint8List.sublistView(buf, o + 1, o + 3)));
          o += 3;
        case PktType.fileMeta:
          final p = FileMetaPkt.tryParse(buf, o);
          if (p == null) return out;
          out.add(Pkt(t, Uint8List.sublistView(buf, o + 1, o + p.wireLen)));
          o += p.wireLen;
        case PktType.fileData:
          // FILE_DATA: u16 fileId, u16 chunkIdx, u16 dataLen, data
          if (o + 7 > buf.length) return out;
          final len = bd.getUint16(o + 5);
          if (o + 7 + len > buf.length) return out;
          out.add(Pkt(t, Uint8List.sublistView(buf, o + 1, o + 7 + len)));
          o += 7 + len;
        case PktType.fileNak:
          if (o + 6 > buf.length) return out;
          final nBits = bd.getUint16(o + 4);
          final nBytes = (nBits + 7) ~/ 8;
          if (o + 6 + nBytes > buf.length) return out;
          out.add(Pkt(t, Uint8List.sublistView(buf, o + 1, o + 6 + nBytes)));
          o += 6 + nBytes;
        case PktType.fileReq:
          if (o + 4 > buf.length) return out;
          final nameLen = buf[o + 3];
          if (o + 4 + nameLen > buf.length) return out;
          out.add(Pkt(t, Uint8List.sublistView(buf, o + 1, o + 4 + nameLen)));
          o += 4 + nameLen;
        default:
          // Unknown type: cannot delimit — stop parsing this burst.
          return out;
      }
    }
    return out;
  }
}

// --------------------------- builders / views -----------------------------

Uint8List buildMsg(int msgId, String text) {
  final t = utf8.encode(text);
  final b = BytesBuilder();
  b.addByte(PktType.msg);
  b.add(_u16(msgId));
  b.add(_u16(t.length));
  b.add(t);
  return b.takeBytes();
}

(int, String) parseMsg(Pkt p) {
  final bd = ByteData.sublistView(p.body);
  final len = bd.getUint16(2);
  return (bd.getUint16(0), utf8.decode(p.body.sublist(4, 4 + len)));
}

Uint8List buildMsgAck(int msgId) =>
    Uint8List.fromList([PktType.msgAck, ..._u16(msgId)]);

int parseU16Id(Pkt p) => ByteData.sublistView(p.body).getUint16(0);

class FileMetaPkt {
  FileMetaPkt({
    required this.fileId,
    required this.name,
    required this.size,
    required this.sha256,
    required this.chunkBytes,
    required this.chunkCount,
  });

  final int fileId;
  final String name;
  final int size;
  final Uint8List sha256; // 32 bytes
  final int chunkBytes;
  final int chunkCount;

  int get wireLen => 1 + 2 + 1 + utf8.encode(name).length + 4 + 32 + 2 + 2;

  Uint8List build() {
    final n = utf8.encode(name);
    final b = BytesBuilder();
    b.addByte(PktType.fileMeta);
    b.add(_u16(fileId));
    b.addByte(n.length);
    b.add(n);
    b.add(_u32(size));
    b.add(sha256);
    b.add(_u16(chunkBytes));
    b.add(_u16(chunkCount));
    return b.takeBytes();
  }

  /// Parse from a full buffer at offset [o] (pointing at the type byte).
  static FileMetaPkt? tryParse(Uint8List buf, int o) {
    if (o + 4 > buf.length) return null;
    final nameLen = buf[o + 3];
    final total = 1 + 2 + 1 + nameLen + 4 + 32 + 2 + 2;
    if (o + total > buf.length) return null;
    final bd = ByteData.sublistView(buf);
    var q = o + 1;
    final fileId = bd.getUint16(q);
    q += 2;
    q += 1;
    final name = utf8.decode(buf.sublist(q, q + nameLen), allowMalformed: true);
    q += nameLen;
    final size = bd.getUint32(q);
    q += 4;
    final sha = Uint8List.fromList(buf.sublist(q, q + 32));
    q += 32;
    final chunkBytes = bd.getUint16(q);
    q += 2;
    final chunkCount = bd.getUint16(q);
    return FileMetaPkt(
      fileId: fileId,
      name: name,
      size: size,
      sha256: sha,
      chunkBytes: chunkBytes,
      chunkCount: chunkCount,
    );
  }

  static FileMetaPkt fromPkt(Pkt p) {
    final buf = Uint8List(p.body.length + 1);
    buf[0] = PktType.fileMeta;
    buf.setRange(1, buf.length, p.body);
    return tryParse(buf, 0)!;
  }
}

Uint8List buildFileData(int fileId, int chunkIdx, Uint8List data) {
  final b = BytesBuilder();
  b.addByte(PktType.fileData);
  b.add(_u16(fileId));
  b.add(_u16(chunkIdx));
  b.add(_u16(data.length));
  b.add(data);
  return b.takeBytes();
}

(int, int, Uint8List) parseFileData(Pkt p) {
  final bd = ByteData.sublistView(p.body);
  final len = bd.getUint16(4);
  return (
    bd.getUint16(0),
    bd.getUint16(2),
    Uint8List.sublistView(p.body, 6, 6 + len)
  );
}

class FileNak {
  FileNak(this.fileId, this.needMeta, this.missing, this.totalChunks);
  final int fileId;
  final bool needMeta;
  final List<int> missing; // chunk indices
  final int totalChunks;

  Uint8List build() {
    final bits = Uint8List((totalChunks + 7) ~/ 8);
    for (final m in missing) {
      if (m < totalChunks) bits[m >> 3] |= 1 << (m & 7);
    }
    final b = BytesBuilder();
    b.addByte(PktType.fileNak);
    b.add(_u16(fileId));
    b.addByte(needMeta ? 1 : 0);
    b.add(_u16(totalChunks));
    b.add(bits);
    return b.takeBytes();
  }

  static FileNak parse(Pkt p) {
    final bd = ByteData.sublistView(p.body);
    final fileId = bd.getUint16(0);
    final needMeta = p.body[2] != 0;
    final nBits = bd.getUint16(3);
    final missing = <int>[];
    for (var i = 0; i < nBits; i++) {
      if ((p.body[5 + (i >> 3)] >> (i & 7)) & 1 != 0) missing.add(i);
    }
    return FileNak(fileId, needMeta, missing, nBits);
  }
}

Uint8List buildFileDone(int fileId) =>
    Uint8List.fromList([PktType.fileDone, ..._u16(fileId)]);

Uint8List buildFileReq(int reqId, String name) {
  final n = utf8.encode(name);
  final b = BytesBuilder();
  b.addByte(PktType.fileReq);
  b.add(_u16(reqId));
  b.addByte(n.length > 255 ? 255 : n.length);
  b.add(n.length > 255 ? n.sublist(0, 255) : n);
  return b.takeBytes();
}

(int, String) parseFileReq(Pkt p) {
  final reqId = ByteData.sublistView(p.body).getUint16(0);
  final nameLen = p.body[2];
  return (reqId, utf8.decode(p.body.sublist(3, 3 + nameLen), allowMalformed: true));
}

Uint8List buildTextPkt(int type, int reqId, String text) {
  final t = utf8.encode(text);
  final b = BytesBuilder();
  b.addByte(type);
  b.add(_u16(reqId));
  b.add(_u16(t.length));
  b.add(t);
  return b.takeBytes();
}

(int, String) parseTextPkt(Pkt p) {
  final bd = ByteData.sublistView(p.body);
  final len = bd.getUint16(2);
  return (bd.getUint16(0), utf8.decode(p.body.sublist(4, 4 + len)));
}

Uint8List buildBeacon(String text) {
  final t = utf8.encode(text);
  final b = BytesBuilder();
  b.addByte(PktType.beacon);
  b.add(_u16(t.length));
  b.add(t);
  return b.takeBytes();
}

String parseBeacon(Pkt p) {
  final len = ByteData.sublistView(p.body).getUint16(0);
  return utf8.decode(p.body.sublist(2, 2 + len));
}

List<int> _u16(int v) => [(v >> 8) & 0xFF, v & 0xFF];
List<int> _u32(int v) =>
    [(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF];

/// Packs packets into a burst payload, aligning selected packets to LDPC
/// block boundaries with padding.
class BurstPayloadBuilder {
  BurstPayloadBuilder(this.blockUserBytes);
  final int blockUserBytes;
  final BytesBuilder _b = BytesBuilder();

  int get length => _b.length;

  void add(Uint8List pkt) => _b.add(pkt);

  /// Pad to the next block boundary (no-op if already aligned).
  void alignToBlock() {
    final rem = blockUserBytes - (_b.length % blockUserBytes);
    if (rem == blockUserBytes) return;
    if (rem < 3) {
      for (var i = 0; i < rem; i++) {
        _b.addByte(PktType.pad1);
      }
    } else {
      _b.addByte(PktType.padBlk);
      _b.add(_u16(rem - 3));
      _b.add(Uint8List(rem - 3));
    }
  }

  Uint8List take() => _b.takeBytes();
}
