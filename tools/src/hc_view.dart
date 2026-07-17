// hc_view — render a constellation diagram PNG from a HamChannel PCM
// capture, mirroring the app's Signal Quality tab: the constellation on
// the left half of the image and the signal-quality figures as text on
// the right half.
//
// Usage:
//   hc_view [--width hf|narrow|wide|auto] [--burst N] [-o <out.png>]
//           [<capture.f64>]
//
// Reads f64le PCM (mono, 48 kHz) from the file or from stdin when no
// filename is given. With several bursts in the capture, the last one is
// rendered (like the app's "last received transmission"); pick another
// with --burst N (1-based, in time order). Default output file is the
// input name with .png appended (constellation.png for stdin).
//
// Example:
//   hc_gen -m "test" | hc_ruin --snr 8 | hc_view -o quality.png

import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as im;

import 'package:hamchannel/dsp/constellation.dart';
import 'package:hamchannel/dsp/modem_params.dart';
import 'package:hamchannel/modem/modem.dart';

const sampleRate = ModemParams.sampleRate;

Never _usage(int code) {
  final out = code == 0 ? stdout : stderr;
  out.writeln('usage: hc_view [--width hf|narrow|wide|auto] [--burst N] '
      '[-o <out.png>] [<capture.f64>]');
  out.writeln('       (reads stdin when no filename is given)');
  exit(code);
}

Future<void> main(List<String> argv) async {
  String widthArg = 'auto';
  int? burstSel;
  String? outPath;
  String? inPath;

  for (var i = 0; i < argv.length; i++) {
    switch (argv[i]) {
      case '--help' || '-h':
        _usage(0);
      case '--width':
        if (i + 1 >= argv.length) _usage(2);
        widthArg = argv[++i];
      case '--burst':
        if (i + 1 >= argv.length) _usage(2);
        burstSel = int.tryParse(argv[++i]);
        if (burstSel == null || burstSel! < 1) _usage(2);
      case '-o' || '--output':
        if (i + 1 >= argv.length) _usage(2);
        outPath = argv[++i];
      default:
        if (argv[i].startsWith('-')) {
          stderr.writeln('unknown option: ${argv[i]}');
          _usage(2);
        }
        inPath = argv[i];
    }
  }
  final widths = switch (widthArg) {
    'hf' => [ChannelWidth.hf],
    'narrow' => [ChannelWidth.narrow],
    'wide' => [ChannelWidth.wide],
    'auto' => ChannelWidth.values,
    _ => _usage(2),
  };

  // ---- read samples ----
  final Uint8List bytes;
  if (inPath == null) {
    final bb = BytesBuilder(copy: false);
    await for (final chunk in stdin) {
      bb.add(chunk);
    }
    bytes = bb.takeBytes();
  } else {
    final f = File(inPath!);
    if (!f.existsSync()) {
      stderr.writeln('hc_view: no such file: $inPath');
      exit(1);
    }
    bytes = f.readAsBytesSync();
  }
  final n = bytes.length ~/ 8;
  final bd = ByteData.sublistView(bytes);
  final samples = Float64List(n);
  for (var i = 0; i < n; i++) {
    samples[i] = bd.getFloat64(i * 8, Endian.little);
  }

  // ---- demodulate with constellation capture ----
  final found =
      <(ChannelWidth, ReceivedBurst, ConstellationSnapshot?)>[];
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
    rx.addSamples(Float64List(ModemParams.symbolLen * 2));
  }
  found.sort((a, b) => a.$2.startSample.compareTo(b.$2.startSample));

  if (found.isEmpty) {
    stderr.writeln('hc_view: no bursts found in the capture');
    exit(1);
  }
  final withCc = found.where((f) => f.$3 != null).toList();
  if (withCc.isEmpty) {
    stderr.writeln('hc_view: bursts found but none carried payload symbols');
    exit(1);
  }
  final idx = burstSel != null
      ? (burstSel! - 1).clamp(0, withCc.length - 1)
      : withCc.length - 1;
  final (width, burst, snapMaybe) = withCc[idx];
  final snap = snapMaybe!;

  // ---- render ----
  final img = _render(
    snap: snap,
    burst: burst,
    width: width,
    fileLabel: inPath ?? '<stdin>',
    burstIndex: idx + 1,
    burstCount: withCc.length,
  );

  outPath ??= inPath != null ? '$inPath.png' : 'constellation.png';
  File(outPath!).writeAsBytesSync(im.encodePng(img));
  stderr.writeln('hc_view: burst ${idx + 1}/${withCc.length} '
      '(${burst.header.mod.label}, ${snap.totalPoints} symbols) -> $outPath');
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

const _range = 1.6; // constellation plot spans +-range

im.Image _render({
  required ConstellationSnapshot snap,
  required ReceivedBurst burst,
  required ChannelWidth width,
  required String fileLabel,
  required int burstIndex,
  required int burstCount,
}) {
  const imgW = 1240, imgH = 660;
  const plotX = 24, plotY = 24, plotSize = 600;

  final bg = im.ColorRgb8(13, 23, 32); // 0x0D1720
  final gridC = im.ColorRgb8(0x29, 0x43, 0x5C);
  final axisC = im.ColorRgb8(0x3E, 0x5A, 0x75);
  final borderC = im.ColorRgb8(0x3E, 0x5A, 0x75);
  final labelC = im.ColorRgb8(150, 165, 180);
  final valueC = im.ColorRgb8(235, 240, 245);
  final titleC = im.ColorRgb8(120, 220, 170);
  final okC = im.ColorRgb8(140, 220, 120);
  final badC = im.ColorRgb8(240, 110, 110);

  final img = im.Image(width: imgW, height: imgH);
  im.fill(img, color: bg);

  // ---- constellation plot (left) ----
  final cx = plotX + plotSize / 2;
  final cy = plotY + plotSize / 2;
  final scale = plotSize / (2 * _range);
  (int, int) map(double i, double q) =>
      ((cx + i * scale).round(), (cy - q * scale).round());

  for (final v in [-1.0, -0.5, 0.5, 1.0]) {
    final (gx, _) = map(v, 0);
    final (_, gy) = map(0, v);
    im.drawLine(img,
        x1: gx, y1: plotY, x2: gx, y2: plotY + plotSize, color: gridC);
    im.drawLine(img,
        x1: plotX, y1: gy, x2: plotX + plotSize, y2: gy, color: gridC);
  }
  im.drawLine(img,
      x1: (cx).round(),
      y1: plotY,
      x2: (cx).round(),
      y2: plotY + plotSize,
      color: axisC);
  im.drawLine(img,
      x1: plotX,
      y1: (cy).round(),
      x2: plotX + plotSize,
      y2: (cy).round(),
      color: axisC);

  // Received points: manual alpha blend, small round dots.
  void blendPx(int x, int y, int r, int g, int b, double a) {
    if (x < plotX || y < plotY || x >= plotX + plotSize ||
        y >= plotY + plotSize) {
      return;
    }
    final p = img.getPixel(x, y);
    img.setPixelRgb(
      x,
      y,
      (p.r * (1 - a) + r * a).round(),
      (p.g * (1 - a) + g * a).round(),
      (p.b * (1 - a) + b * a).round(),
    );
  }

  void dot(int x, int y) {
    const offsets = [
      (0, 0, 0.40),
      (1, 0, 0.30), (-1, 0, 0.30), (0, 1, 0.30), (0, -1, 0.30),
      (1, 1, 0.15), (-1, 1, 0.15), (1, -1, 0.15), (-1, -1, 0.15),
    ];
    for (final (dx, dy, a) in offsets) {
      blendPx(x + dx, y + dy, 62, 207, 142, a);
    }
  }

  final nPts = snap.xy.length ~/ 2;
  for (var k = 0; k < nPts; k++) {
    final i = snap.xy[2 * k].clamp(-_range, _range).toDouble();
    final q = snap.xy[2 * k + 1].clamp(-_range, _range).toDouble();
    final (x, y) = map(i, q);
    dot(x, y);
  }

  // Ideal constellation points as white crosshairs.
  final ideal = im.ColorRgb8(255, 255, 255);
  for (final (pi, pq) in Constellation(snap.mod).allPoints()) {
    final (x, y) = map(pi, pq);
    im.drawLine(img, x1: x - 6, y1: y, x2: x + 6, y2: y, color: ideal);
    im.drawLine(img, x1: x, y1: y - 6, x2: x, y2: y + 6, color: ideal);
  }

  // Plot border.
  im.drawRect(img,
      x1: plotX,
      y1: plotY,
      x2: plotX + plotSize,
      y2: plotY + plotSize,
      color: borderC);

  // ---- signal quality text (right) ----
  const tx = 660;
  var ty = 30;
  im.drawString(img, 'HamChannel — Signal Quality',
      font: im.arial24, x: tx, y: ty, color: titleC);
  ty += 44;

  final bw = switch (width) {
    ChannelWidth.hf => '2.8 kHz',
    ChannelWidth.narrow => '12 kHz',
    ChannelWidth.wide => '24 kHz',
  };
  final carriers = ModemParams(width: width).activeCarriers;
  final h = burst.header;
  final t = snap.at;
  String two(int v) => v.toString().padLeft(2, '0');

  final crcTotal =
      snap.blocksOk + snap.blocksCrcFailed + snap.blocksUncorrectable;
  final crcText = crcTotal == 0
      ? 'no payload blocks'
      : snap.allBlocksOk
          ? 'all ${snap.blocksOk} blocks OK'
          : '${snap.blocksOk} OK, ${snap.blocksCrcFailed} CRC fail, '
              '${snap.blocksUncorrectable} uncorrectable';
  final berText = snap.fecCodedBits == 0
      ? 'n/a (no decoded blocks)'
      : snap.fecCorrectedBits == 0
          ? '0 (no bit errors)'
          : snap.ber.toStringAsExponential(2);

  void row(String label, String value, {im.Color? color}) {
    im.drawString(img, label,
        font: im.arial24, x: tx, y: ty, color: labelC);
    im.drawString(img, value,
        font: im.arial24, x: tx + 240, y: ty, color: color ?? valueC);
    ty += 34;
  }

  row('From', h.srcCall);
  row('To', h.dstCall);
  row('Bandwidth', '$bw  (OFDM-$carriers)');
  row('Modulation', h.mod.label);
  row('LDPC rate', h.rate.label);
  row('Burst', '$burstIndex of $burstCount  '
      '@ ${(burst.startSample / sampleRate).toStringAsFixed(2)} s');
  row('Symbols', '${snap.totalPoints}');
  ty += 12;
  row('SNR', '${snap.snrDb.toStringAsFixed(1)} dB');
  row('EVM (RMS)', '${snap.evmRmsPct.toStringAsFixed(2)} %');
  row('EVM (max)', '${snap.evmMaxPct.toStringAsFixed(2)} %');
  row('EVM (std dev)', '${snap.evmStdPct.toStringAsFixed(2)} %');
  ty += 12;
  row('Pre-FEC BER', berText);
  row('Bits corrected',
      '${snap.fecCorrectedBits} of ${snap.fecCodedBits}');
  row('CRC status', crcText, color: snap.allBlocksOk ? okC : badC);
  ty += 20;
  im.drawString(
      img,
      'Rendered ${t.year}-${two(t.month)}-${two(t.day)} '
      '${two(t.hour)}:${two(t.minute)}:${two(t.second)} from $fileLabel',
      font: im.arial14,
      x: tx,
      y: imgH - 34,
      color: labelC);

  return img;
}
