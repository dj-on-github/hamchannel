import 'package:flutter/material.dart';

import '../dsp/constellation.dart';
import '../dsp/modem_params.dart';
import '../modem/modem.dart';
import '../modem/modem_service.dart';

/// Signal Quality: constellation diagram of the last received transmission
/// plus numerical EVM/SNR measures. Capture is off by default.
class SignalQualityTab extends StatelessWidget {
  const SignalQualityTab({super.key, required this.service});

  final ModemService service;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final s = service;
        final snap = s.lastConstellation;
        return Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SwitchListTile(
                title: const Text('Capture signal quality'),
                subtitle: const Text(
                    'Records the equalized constellation of each received '
                    'transmission. Off by default to save CPU.'),
                value: s.signalQualityEnabled,
                onChanged: (v) => s.signalQualityEnabled = v,
              ),
              const SizedBox(height: 8),
              Expanded(
                child: snap == null
                    ? Center(
                        child: Text(
                          s.signalQualityEnabled
                              ? 'Waiting for a transmission…'
                              : 'Enable capture, then receive a transmission '
                                  'to see its constellation.',
                          textAlign: TextAlign.center,
                        ),
                      )
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // ---------------- constellation ----------------
                          AspectRatio(
                            aspectRatio: 1,
                            child: Container(
                              decoration: BoxDecoration(
                                color: const Color(0xFF0D1720),
                                border: Border.all(
                                    color:
                                        Theme.of(context).colorScheme.outline),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: CustomPaint(
                                  painter: _ConstellationPainter(
                                    snap: snap,
                                    dotColor: Theme.of(context)
                                        .colorScheme
                                        .primary,
                                  ),
                                  size: Size.infinite,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 20),
                          // ---------------- numbers ----------------
                          Expanded(
                            child: DefaultTextStyle(
                              style: const TextStyle(
                                  fontFamily: 'monospace', fontSize: 14),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Last transmission',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium,
                                  ),
                                  const SizedBox(height: 12),
                                  _row('From', snap.srcCall),
                                  _row('Modulation', snap.mod.label),
                                  _row('Received',
                                      _fmtTime(snap.at)),
                                  _row('Symbols measured',
                                      '${snap.totalPoints}'),
                                  const Divider(),
                                  _row('SNR',
                                      '${snap.snrDb.toStringAsFixed(1)} dB'),
                                  _row('EVM (RMS)',
                                      '${snap.evmRmsPct.toStringAsFixed(2)} %'),
                                  _row('EVM (max)',
                                      '${snap.evmMaxPct.toStringAsFixed(2)} %'),
                                  _row('EVM (std dev)',
                                      '${snap.evmStdPct.toStringAsFixed(2)} %'),
                                  const Divider(),
                                  _row('Pre-FEC BER', _fmtBer(snap)),
                                  _row('Bits corrected',
                                      '${snap.fecCorrectedBits} of ${snap.fecCodedBits} coded'),
                                  _row(
                                    'CRC status',
                                    snap.blocksOk +
                                                snap.blocksCrcFailed +
                                                snap.blocksUncorrectable ==
                                            0
                                        ? 'no payload blocks'
                                        : snap.allBlocksOk
                                            ? 'all ${snap.blocksOk} blocks OK'
                                            : '${snap.blocksOk} OK · '
                                                '${snap.blocksCrcFailed} CRC fail · '
                                                '${snap.blocksUncorrectable} uncorrectable',
                                    color: snap.allBlocksOk
                                        ? Colors.lightGreen
                                        : Colors.redAccent,
                                  ),
                                  const SizedBox(height: 12),
                                  Text(
                                    'EVM is the error-vector magnitude of '
                                    'each equalized symbol relative to its '
                                    'nearest constellation point, in percent '
                                    'of the RMS constellation power. '
                                    'Pre-FEC BER is the fraction of coded '
                                    'bits the LDPC decoder corrected, over '
                                    'the blocks it decoded successfully.',
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _row(String label, String value, {Color? color}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            SizedBox(width: 170, child: Text(label)),
            Expanded(
              child: Text(value,
                  style:
                      TextStyle(fontWeight: FontWeight.bold, color: color)),
            ),
          ],
        ),
      );

  static String _fmtBer(ConstellationSnapshot s) {
    if (s.fecCodedBits == 0) return 'n/a (no decoded blocks)';
    if (s.fecCorrectedBits == 0) return '0 (no bit errors)';
    return s.ber.toStringAsExponential(2);
  }

  static String _fmtTime(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}:'
      '${t.second.toString().padLeft(2, '0')}';
}

class _ConstellationPainter extends CustomPainter {
  _ConstellationPainter({required this.snap, required this.dotColor});

  final ConstellationSnapshot snap;
  final Color dotColor;

  static const double _range = 1.6; // plot spans +-range on both axes

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2, cy = size.height / 2;
    final scale = size.shortestSide / (2 * _range);

    Offset map(double i, double q) => Offset(cx + i * scale, cy - q * scale);

    // Grid: axes plus lines at +-0.5 and +-1.
    final grid = Paint()
      ..color = const Color(0xFF29435C)
      ..strokeWidth = 1;
    final axis = Paint()
      ..color = const Color(0xFF3E5A75)
      ..strokeWidth = 1.4;
    for (final v in [-1.0, -0.5, 0.5, 1.0]) {
      canvas.drawLine(map(v, -_range), map(v, _range), grid);
      canvas.drawLine(map(-_range, v), map(_range, v), grid);
    }
    canvas.drawLine(map(0, -_range), map(0, _range), axis);
    canvas.drawLine(map(-_range, 0), map(_range, 0), axis);

    // Received points.
    final dot = Paint()
      ..color = dotColor.withValues(alpha: 0.35)
      ..style = PaintingStyle.fill;
    final n = snap.xy.length ~/ 2;
    for (var k = 0; k < n; k++) {
      final i = snap.xy[2 * k].clamp(-_range, _range).toDouble();
      final q = snap.xy[2 * k + 1].clamp(-_range, _range).toDouble();
      canvas.drawCircle(map(i, q), 1.6, dot);
    }

    // Ideal constellation points as crosshairs on top.
    final ideal = Paint()
      ..color = Colors.white.withValues(alpha: 0.85)
      ..strokeWidth = 1.6;
    const arm = 5.0;
    for (final (pi, pq) in Constellation(snap.mod).allPoints()) {
      final o = map(pi, pq);
      canvas.drawLine(o.translate(-arm, 0), o.translate(arm, 0), ideal);
      canvas.drawLine(o.translate(0, -arm), o.translate(0, arm), ideal);
    }
  }

  @override
  bool shouldRepaint(_ConstellationPainter old) =>
      old.snap != snap || old.dotColor != dotColor;
}
