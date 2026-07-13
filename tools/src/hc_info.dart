// hc_info — inspect a HamChannel PCM capture file.
//
// Reads a raw PCM file (mono, 48 kHz, float64 little-endian — the format
// written by the app's "Write PCM" feature), runs the real HamChannel
// demodulator and LDPC decoder over it, and prints the burst headers and
// the format/contents of every packet found.
//
// Usage:
//   hc_info [options] [<capture.f64>]
//     --width narrow|wide|auto   channel profile to demodulate (default auto)
//     --verbose, -v              full message text, NAK lists, hashes
//     --help, -h                 this text
//
// With no filename, samples are read from stdin, so hc_gen can pipe
// straight in:  hc_gen -m "test" | hc_info
//
// Build: see the Makefile in this directory (compiles against the main
// application's lib/ sources, so the demodulation here is byte-identical
// to the app's).

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:hamchannel/dsp/modem_params.dart';
import 'package:hamchannel/modem/modem.dart';
import 'package:hamchannel/proto/packets.dart';

const sampleRate = ModemParams.sampleRate;

bool verbose = false;

Future<void> main(List<String> argv) async {
  String? widthArg = 'auto';
  String? path;
  for (var i = 0; i < argv.length; i++) {
    final a = argv[i];
    switch (a) {
      case '--help' || '-h':
        _usage(0);
      case '--verbose' || '-v':
        verbose = true;
      case '--width':
        if (i + 1 >= argv.length) _usage(2);
        widthArg = argv[++i];
      default:
        if (a.startsWith('-')) {
          stderr.writeln('unknown option: $a');
          _usage(2);
        }
        path = a;
    }
  }
  final widths = switch (widthArg) {
    'narrow' => [ChannelWidth.narrow],
    'wide' => [ChannelWidth.wide],
    'auto' => ChannelWidth.values,
    _ => _usage(2),
  };

  final Uint8List bytes;
  if (path == null) {
    // No filename: read the samples from stdin (e.g. piped from hc_gen).
    final bb = BytesBuilder(copy: false);
    await for (final chunk in stdin) {
      bb.add(chunk);
    }
    bytes = bb.takeBytes();
    path = '<stdin>';
  } else {
    final f = File(path!);
    if (!f.existsSync()) {
      stderr.writeln('hc_info: no such file: $path');
      exit(1);
    }
    bytes = f.readAsBytesSync();
  }
  if (bytes.length % 8 != 0) {
    stderr.writeln('warning: file length ${bytes.length} is not a multiple '
        'of 8; trailing ${bytes.length % 8} bytes ignored');
  }
  final n = bytes.length ~/ 8;
  final bd = ByteData.sublistView(bytes);
  final samples = Float64List(n);
  var peak = 0.0;
  var sumSq = 0.0;
  for (var i = 0; i < n; i++) {
    final v = bd.getFloat64(i * 8, Endian.little);
    samples[i] = v;
    final a = v.abs();
    if (a > peak) peak = a;
    sumSq += v * v;
  }
  final rms = n == 0 ? 0.0 : math.sqrt(sumSq / n);

  print('hc_info — HamChannel PCM capture inspector');
  print('File: $path');
  print('  $n samples · ${_secs(n)} @ $sampleRate Hz · f64le mono · '
      'peak ${peak.toStringAsFixed(3)} · rms ${rms.toStringAsFixed(3)}');
  print('');

  // Demodulate with a receiver per channel width; only the matching width
  // will synchronize (the preambles differ), so auto mode is safe.
  final found = <(ChannelWidth, ReceivedBurst, ConstellationSnapshot?)>[];
  for (final w in widths) {
    final p = ModemParams(width: w);
    late ModemReceiver rx;
    rx = ModemReceiver(p, onBurst: (b) {
      found.add((w, b, rx.lastConstellation));
    })
      ..captureConstellation = true;
    const chunk = 48000;
    for (var o = 0; o < n; o += chunk) {
      final e = o + chunk > n ? n : o + chunk;
      rx.addSamples(Float64List.sublistView(samples, o, e));
    }
    // Flush: trailing silence lets a burst ending at EOF complete.
    rx.addSamples(Float64List(ModemParams.symbolLen * 2));
  }
  found.sort((a, b) => a.$2.startSample.compareTo(b.$2.startSample));

  if (found.isEmpty) {
    print('No bursts found.');
    if (widthArg != 'auto') {
      print('(Try --width auto in case the capture uses the other profile.)');
    }
    exit(0);
  }

  for (var i = 0; i < found.length; i++) {
    final (w, b, cc) = found[i];
    _printBurst(i + 1, w, b, cc);
  }

  print('Summary: ${found.length} burst(s)'
      '${widths.length > 1 ? ' — narrow: ${found.where((x) => x.$1 == ChannelWidth.narrow).length}, wide: ${found.where((x) => x.$1 == ChannelWidth.wide).length}' : ''}');
}

Never _usage(int code) {
  final out = code == 0 ? stdout : stderr;
  out.writeln('usage: hc_info [--width narrow|wide|auto] [--verbose] '
      '[<capture.f64>]');
  out.writeln('       (reads stdin when no filename is given)');
  exit(code);
}

void _printBurst(
    int idx, ChannelWidth w, ReceivedBurst b, ConstellationSnapshot? cc) {
  final h = b.header;
  final typeName = switch (h.type) {
    0 => 'data',
    1 => 'response',
    2 => 'beacon',
    _ => 'unknown',
  };
  final flags = <String>[
    if (h.flags & 0x01 != 0) 'ACK_REQ',
    if (h.flags & ~0x01 != 0)
      'other=0x${(h.flags & ~0x01).toRadixString(16)}',
  ];
  print('Burst $idx at ${_secs(b.startSample)}  [${w.name}]');
  print('  Header : type=$typeName(${h.type})  src=${h.srcCall}  '
      'dst=${h.dstCall}  burstId=${h.burstId}  '
      'flags=${flags.isEmpty ? 'none' : flags.join('|')}');
  print('           mod=${h.mod.label}  ldpc=${h.rate.label}  '
      'blocks=${h.blockCount}  payloadBytes=${h.payloadBytes}');
  final ok = b.blocks.where((x) => x != null).length;
  final fec = cc == null
      ? ''
      : '  ·  pre-FEC BER ${cc.fecCorrectedBits == 0 ? '0' : cc.ber.toStringAsExponential(2)} '
          '(${cc.fecCorrectedBits}/${cc.fecCodedBits})'
          '  ·  EVM rms ${cc.evmRmsPct.toStringAsFixed(1)}%';
  print('  Decode : $ok/${b.blocks.length} blocks OK'
      '  ·  SNR ${b.snrDb.toStringAsFixed(1)} dB$fec');

  if (b.blocks.isEmpty) {
    print('  Payload: (header-only burst)');
    print('');
    return;
  }

  // Parse maximal runs of consecutive good blocks (as the app does).
  var anyPkt = false;
  var badBlocks = 0;
  final run = BytesBuilder();
  void flushRun() {
    if (run.length == 0) return;
    final pkts = Pkt.parseAll(run.takeBytes());
    for (final p in pkts) {
      print('    ${_describePacket(p)}');
      anyPkt = true;
    }
  }

  print('  Packets:');
  for (final blk in b.blocks) {
    if (blk == null) {
      badBlocks++;
      flushRun();
    } else {
      run.add(blk);
    }
  }
  flushRun();
  if (badBlocks > 0) {
    print('    ($badBlocks undecodable block(s) — packets in them are lost)');
  }
  if (!anyPkt && badBlocks == 0) {
    print('    (padding only)');
  }
  print('');
}

String _describePacket(Pkt p) {
  switch (p.type) {
    case PktType.msg:
      final (id, text) = parseMsg(p);
      return 'MSG          id=$id  len=${utf8.encode(text).length}  '
          'text=${_text(text)}';
    case PktType.msgAck:
      return 'MSG_ACK      id=${parseU16Id(p)}';
    case PktType.fileMeta:
      final m = FileMetaPkt.fromPkt(p);
      final sha = m.sha256.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
      return 'FILE_META    id=${m.fileId}  name=${_text(m.name)}  '
          'size=${m.size} B  chunks=${m.chunkCount} x ${m.chunkBytes} B  '
          'sha256=${verbose ? sha : '${sha.substring(0, 16)}…'}';
    case PktType.fileData:
      final (fileId, chunkIdx, data) = parseFileData(p);
      return 'FILE_DATA    id=$fileId  chunk=$chunkIdx  (${data.length} B)';
    case PktType.fileNak:
      final nak = FileNak.parse(p);
      final miss = nak.missing;
      final list = verbose || miss.length <= 12
          ? miss.join(',')
          : '${miss.take(12).join(',')},… (+${miss.length - 12} more)';
      return 'FILE_NAK     id=${nak.fileId}  totalChunks=${nak.totalChunks}  '
          'missing=${miss.length}${miss.isEmpty ? '' : ' [$list]'}'
          '${nak.needMeta ? '  needMeta' : ''}';
    case PktType.fileDone:
      return 'FILE_DONE    id=${parseU16Id(p)}';
    case PktType.fileReq:
      final (reqId, name) = parseFileReq(p);
      return 'FILE_REQ     reqId=$reqId  name=${_text(name)}';
    case PktType.fileReqNak:
      final (reqId, reason) = parseTextPkt(p);
      return 'FILE_REQ_NAK reqId=$reqId  reason=${_text(reason)}';
    case PktType.listReq:
      return 'LIST_REQ     reqId=${parseU16Id(p)}';
    case PktType.listResp:
      final (reqId, listing) = parseTextPkt(p);
      final lines = listing.trim().isEmpty
          ? 0
          : listing.trim().split('\n').length;
      return 'LIST_RESP    reqId=$reqId  entries=$lines'
          '${verbose ? '\n${listing.trimRight().split('\n').map((l) => '                 $l').join('\n')}' : ''}';
    case PktType.beacon:
      return 'BEACON       text=${_text(parseBeacon(p))}';
    default:
      return 'UNKNOWN      type=0x${p.type.toRadixString(16).padLeft(2, '0')} '
          '(${p.body.length} B)';
  }
}

String _text(String s) {
  final clean = s.replaceAll('\n', '\\n').replaceAll('\r', '\\r');
  if (verbose || clean.length <= 48) return '"$clean"';
  return '"${clean.substring(0, 48)}…" (${clean.length} chars)';
}

String _secs(int sampleIndex) =>
    '${(sampleIndex / sampleRate).toStringAsFixed(3)} s';
