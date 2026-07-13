// hc_gen — generate a HamChannel message burst as PCM sample data.
//
// Builds a complete on-air burst (leader, chanest, header, LDPC-coded
// payload carrying one MSG packet) using the main application's modulator,
// and emits the waveform as raw PCM: mono, 48 kHz, float64 little-endian —
// the same format the app's "Write PCM" capture produces and that both
// "Read PCM" and hc_info consume.
//
// Usage:
//   hc_gen [--width narrow|wide] [--mod bpsk|qpsk|16-qam|64-qam]
//          [--ldpc 1/2|2/3|3/4|5/6] [--call <callsign>]
//          [--dest <destination callsign or CQ>]
//          --message|-m <message contents> [-o <filename>]
//
// Without -o the samples are written to stdout (pipe or redirect them);
// status information always goes to stderr.
//
// Examples:
//   hc_gen -m "CQ CQ de W1AW" -o cq.f64
//   hc_gen --mod 16-qam --ldpc 3/4 --call W1AW --dest KD2XYZ \
//          -m "hello" | tools/hc_info /dev/stdin

import 'dart:io';
import 'dart:typed_data';

import 'package:hamchannel/dsp/modem_params.dart';
import 'package:hamchannel/modem/modem.dart';
import 'package:hamchannel/proto/link.dart' show FrameFlags;
import 'package:hamchannel/proto/packets.dart';

Never _usage(int code) {
  final out = code == 0 ? stdout : stderr;
  out.writeln(
      'usage: hc_gen [--width narrow|wide] [--mod bpsk|qpsk|16-qam|64-qam]\n'
      '              [--ldpc 1/2|2/3|3/4|5/6] [--call <callsign>]\n'
      '              [--dest <destination callsign or CQ>]\n'
      '              --message|-m <message contents> [-o <filename>]');
  exit(code);
}

Future<void> main(List<String> argv) async {
  var width = ChannelWidth.narrow;
  var mod = SubcarrierModulation.qpsk;
  var rate = LdpcRate.half;
  var call = 'NOCALL';
  var dest = 'CQ';
  String? message;
  String? outPath;

  String next(int i) {
    if (i + 1 >= argv.length) _usage(2);
    return argv[i + 1];
  }

  for (var i = 0; i < argv.length; i++) {
    switch (argv[i]) {
      case '--help' || '-h':
        _usage(0);
      case '--width':
        width = switch (next(i++).toLowerCase()) {
          'narrow' => ChannelWidth.narrow,
          'wide' => ChannelWidth.wide,
          _ => _usage(2),
        };
      case '--mod':
        mod = switch (next(i++).toLowerCase()) {
          'bpsk' => SubcarrierModulation.bpsk,
          'qpsk' => SubcarrierModulation.qpsk,
          '16-qam' || '16qam' || 'qam16' => SubcarrierModulation.qam16,
          '64-qam' || '64qam' || 'qam64' => SubcarrierModulation.qam64,
          _ => _usage(2),
        };
      case '--ldpc':
        rate = switch (next(i++)) {
          '1/2' => LdpcRate.half,
          '2/3' => LdpcRate.twoThirds,
          '3/4' => LdpcRate.threeQuarters,
          '5/6' => LdpcRate.fiveSixths,
          _ => _usage(2),
        };
      case '--call':
        call = next(i++).trim().toUpperCase();
      case '--dest':
        dest = next(i++).trim().toUpperCase();
      case '--message' || '-m':
        message = next(i++);
      case '-o' || '--output':
        outPath = next(i++);
      default:
        stderr.writeln('unknown option: ${argv[i]}');
        _usage(2);
    }
  }

  if (message == null || message.isEmpty) {
    stderr.writeln('hc_gen: --message is required');
    _usage(2);
  }
  for (final c in [call, dest]) {
    if (c.isEmpty || c.length > 6) {
      stderr.writeln('hc_gen: callsign "$c" must be 1-6 characters');
      exit(2);
    }
  }

  // One MSG packet, exactly as the app's link layer would send it. The
  // ACK-request flag is set for directed messages, matching app behavior.
  final payload = buildMsg(1, message!);
  final flags = dest == 'CQ' ? 0 : FrameFlags.ackReq;

  final p = ModemParams(width: width);
  final tx = ModemTransmitter(p);
  final wave = tx.buildBurst(
    type: 0, // data frame
    srcCall: call,
    dstCall: dest,
    burstId: 1,
    mod: mod,
    rate: rate,
    payload: payload,
    flags: flags,
    level: 0.8,
  );

  final bytes = Uint8List(wave.length * 8);
  final bd = ByteData.sublistView(bytes);
  for (var i = 0; i < wave.length; i++) {
    bd.setFloat64(i * 8, wave[i], Endian.little);
  }

  if (outPath != null) {
    File(outPath!).writeAsBytesSync(bytes);
  } else {
    stdout.add(bytes);
    await stdout.flush();
  }

  stderr.writeln('hc_gen: ${width.name} ${mod.label} LDPC ${rate.label}  '
      '$call -> $dest  msg ${message!.length} chars');
  stderr.writeln('hc_gen: ${wave.length} samples '
      '(${(wave.length / ModemParams.sampleRate).toStringAsFixed(2)} s '
      '@ ${ModemParams.sampleRate} Hz, f64le mono)'
      '${outPath != null ? ' -> $outPath' : ' -> stdout'}');
}
