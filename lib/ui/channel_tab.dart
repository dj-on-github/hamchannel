import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../audio/real_audio.dart';
import '../dsp/modem_params.dart';
import '../modem/modem_service.dart';

/// Channel configuration: width, subcarrier modulation, LDPC strength,
/// callsigns, audio levels.
class ChannelTab extends StatefulWidget {
  const ChannelTab({super.key, required this.service});

  final ModemService service;

  @override
  State<ChannelTab> createState() => _ChannelTabState();
}

class _ChannelTabState extends State<ChannelTab> {
  late final TextEditingController _myCall =
      TextEditingController(text: widget.service.config.myCall);
  late final TextEditingController _remoteCall =
      TextEditingController(text: widget.service.config.remoteCall);

  @override
  void initState() {
    super.initState();
    // Populate the audio device pulldowns once on first open.
    if (widget.service.inputDevices.isEmpty &&
        widget.service.outputDevices.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.service.refreshAudioDevices();
      });
    }
  }

  @override
  void dispose() {
    _myCall.dispose();
    _remoteCall.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.service;
    final cfg = s.config;
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        final p = ModemParams(width: cfg.width);
        final raw = p.rawBitRate(cfg.modulation);
        final net = p.netBitRate(cfg.modulation, cfg.ldpcRate);
        return SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Station', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 8),
                  Row(children: [
                    Expanded(
                      child: TextField(
                        controller: _myCall,
                        textCapitalization: TextCapitalization.characters,
                        decoration: const InputDecoration(
                          labelText: 'My callsign (sent in every frame)',
                          border: OutlineInputBorder(),
                        ),
                        onChanged: (v) => cfg.myCall = v.trim().toUpperCase(),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _remoteCall,
                        textCapitalization: TextCapitalization.characters,
                        decoration: const InputDecoration(
                          labelText: 'Remote callsign (or CQ)',
                          border: OutlineInputBorder(),
                        ),
                        onChanged: (v) =>
                            cfg.remoteCall = v.trim().toUpperCase(),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 24),
                  Text('Channel', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 8),
                  Row(children: [
                    Expanded(
                      child: _drop<ChannelWidth>(
                        label: 'Channel width',
                        value: cfg.width,
                        items: const {
                          ChannelWidth.narrow: 'Narrow — 12 kHz',
                          ChannelWidth.wide: 'Wide — 24 kHz',
                        },
                        onChanged: (v) => setState(() => cfg.width = v),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _drop<SubcarrierModulation>(
                        label: 'Subcarrier modulation',
                        value: cfg.modulation,
                        items: {
                          for (final m in SubcarrierModulation.values)
                            m: m.label
                        },
                        onChanged: (v) => setState(() => cfg.modulation = v),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _drop<LdpcRate>(
                        label: 'LDPC code rate (lower = stronger)',
                        value: cfg.ldpcRate,
                        items: {
                          LdpcRate.half: '1/2 — strongest',
                          LdpcRate.twoThirds: '2/3',
                          LdpcRate.threeQuarters: '3/4',
                          LdpcRate.fiveSixths: '5/6 — fastest',
                        },
                        onChanged: (v) => setState(() => cfg.ldpcRate = v),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 12),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        '${p.activeCarriers} subcarriers '
                        '(${ModemParams.firstBin * ModemParams.binHz ~/ 1} Hz – '
                        '${p.occupiedHz.toStringAsFixed(0)} Hz audio), '
                        '${p.pilotCount} pilots, 46.875 Hz spacing, 24 ms symbols\n'
                        'Raw ${(raw / 1000).toStringAsFixed(2)} kbit/s → '
                        'net ${(net / 1000).toStringAsFixed(2)} kbit/s after LDPC ${cfg.ldpcRate.label}',
                        style: const TextStyle(fontFamily: 'monospace'),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text('Audio / PTT',
                      style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 8),
                  Row(children: [
                    Expanded(
                      child: _deviceDrop(
                        label: 'Audio input (from radio)',
                        value: cfg.inputDeviceId,
                        devices: s.inputDevices,
                        onChanged: (id, label) => setState(() {
                          cfg.inputDeviceId = id;
                          cfg.inputDeviceLabel = label;
                        }),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _deviceDrop(
                        label: 'Audio output (to radio)',
                        value: cfg.outputDeviceName,
                        devices: s.outputDevices,
                        onChanged: (id, _) => setState(() {
                          cfg.outputDeviceName = id;
                        }),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      tooltip: 'Rescan audio devices',
                      onPressed:
                          s.enumeratingDevices ? null : s.refreshAudioDevices,
                      icon: s.enumeratingDevices
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.refresh),
                    ),
                  ]),
                  const SizedBox(height: 8),
                  Row(children: [
                    const SizedBox(width: 4),
                    const Text('TX level'),
                    Expanded(
                      child: Slider(
                        value: cfg.txLevel,
                        min: 0.05,
                        max: 1.0,
                        divisions: 19,
                        label: '${(cfg.txLevel * 100).round()}%',
                        onChanged: (v) => setState(() => cfg.txLevel = v),
                      ),
                    ),
                    SizedBox(
                        width: 48,
                        child: Text('${(cfg.txLevel * 100).round()}%')),
                  ]),
                  Row(children: [
                    const SizedBox(width: 4),
                    const Text('VOX leader'),
                    Expanded(
                      child: Slider(
                        value: cfg.leaderSymbols.toDouble(),
                        min: 6,
                        max: 42,
                        divisions: 36,
                        label:
                            '${(cfg.leaderSymbols * ModemParams.symbolLen * 1000 / ModemParams.sampleRate).round()} ms',
                        onChanged: (v) =>
                            setState(() => cfg.leaderSymbols = v.round()),
                      ),
                    ),
                    SizedBox(
                      width: 64,
                      child: Text(
                          '${(cfg.leaderSymbols * ModemParams.symbolLen * 1000 / ModemParams.sampleRate).round()} ms'),
                    ),
                  ]),
                  const SizedBox(height: 8),
                  Row(children: [
                    OutlinedButton.icon(
                      onPressed: s.pcmWriting ? null : () => _pickPcmOut(s),
                      icon: const Icon(Icons.fiber_manual_record),
                      label: const Text('Write PCM…'),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed:
                          s.pcmWriting ? () => s.stopPcmWrite() : null,
                      icon: const Icon(Icons.stop_circle_outlined),
                      label: const Text('Close'),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        s.pcmWriting
                            ? 'Capturing transmissions to ${s.pcmWritePath}'
                            : 'Capture transmitted audio to a raw PCM file '
                                '(mono 48 kHz, float64 little-endian). Only '
                                'transmissions are written; idle time is not.',
                        style: Theme.of(context).textTheme.bodySmall,
                        overflow: TextOverflow.ellipsis,
                        maxLines: 2,
                      ),
                    ),
                  ]),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    title: const Text('Loopback test mode (no sound card)'),
                    subtitle: const Text(
                        'TX audio is fed straight back into the receiver — '
                        'useful for testing the modem without a radio'),
                    value: cfg.useLoopback,
                    onChanged: (v) => setState(() => cfg.useLoopback = v),
                  ),
                  const SizedBox(height: 16),
                  Text('Link', style: Theme.of(context).textTheme.titleLarge),
                  Row(children: [
                    Expanded(
                      child: _intField(
                        label: 'ACK timeout (s)',
                        value: cfg.ackTimeoutSec,
                        onChanged: (v) => cfg.ackTimeoutSec = v.clamp(3, 120),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _intField(
                        label: 'File chunks per burst',
                        value: cfg.maxChunksPerBurst,
                        onChanged: (v) =>
                            cfg.maxChunksPerBurst = v.clamp(1, 128),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      FilledButton.icon(
                        onPressed: () => s.applyConfig(),
                        icon: const Icon(Icons.check),
                        label: Text(s.running
                            ? 'Apply & restart modem'
                            : 'Save configuration'),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        'Both stations must use the same bandwidth. ',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _pickPcmOut(ModemService s) async {
    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'Write transmitted PCM to…',
      fileName: 'hamchannel_tx.f64',
      initialDirectory: s.lastDir,
    );
    if (path != null) {
      s.rememberDir(path);
      await s.startPcmWrite(path);
    }
  }

  /// Device pulldown: null value = system default. Keeps a stale saved
  /// selection visible even if the device is currently unplugged.
  Widget _deviceDrop({
    required String label,
    required String? value,
    required List<AudioDeviceInfo> devices,
    required void Function(String? id, String label) onChanged,
  }) {
    final ids = devices.map((d) => d.id).toSet();
    return InputDecorator(
      decoration:
          InputDecoration(labelText: label, border: const OutlineInputBorder()),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String?>(
          value: value,
          isExpanded: true,
          items: [
            const DropdownMenuItem<String?>(
              value: null,
              child: Text('System default'),
            ),
            for (final d in devices)
              DropdownMenuItem<String?>(
                value: d.id,
                child: Text(d.label, overflow: TextOverflow.ellipsis),
              ),
            if (value != null && !ids.contains(value))
              DropdownMenuItem<String?>(
                value: value,
                child: Text('$value (not connected)',
                    overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: (id) {
            String lbl = '';
            for (final d in devices) {
              if (d.id == id) lbl = d.label;
            }
            onChanged(id, lbl);
          },
        ),
      ),
    );
  }

  Widget _drop<T>({
    required String label,
    required T value,
    required Map<T, String> items,
    required void Function(T) onChanged,
  }) {
    return InputDecorator(
      decoration:
          InputDecoration(labelText: label, border: const OutlineInputBorder()),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isExpanded: true,
          items: [
            for (final e in items.entries)
              DropdownMenuItem(value: e.key, child: Text(e.value)),
          ],
          onChanged: (v) {
            if (v != null) onChanged(v);
          },
        ),
      ),
    );
  }

  Widget _intField({
    required String label,
    required int value,
    required void Function(int) onChanged,
  }) {
    return TextFormField(
      initialValue: '$value',
      keyboardType: TextInputType.number,
      decoration:
          InputDecoration(labelText: label, border: const OutlineInputBorder()),
      onChanged: (v) {
        final n = int.tryParse(v);
        if (n != null) onChanged(n);
      },
    );
  }
}
