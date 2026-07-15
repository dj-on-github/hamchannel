/// Real sound-card backend: `record` for capture, `flutter_soloud`
/// (miniaudio) for playback. Both run at 48 kHz mono, and both directions
/// support selecting a specific audio device from the Settings tab.
///
/// Wiring to the radio:
///   * laptop headphone out  -> radio mic input (through an attenuator or
///     isolation transformer; start with TX level ~20%)
///   * radio speaker/data out -> laptop mic/line input
///
/// VOX: the burst leader (~360 ms of preamble tone) keys the radio before
/// the payload starts, so no PTT wiring is required.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_soloud/flutter_soloud.dart';
import 'package:record/record.dart';

import 'audio_backend.dart';

/// A selectable audio device (either direction).
class AudioDeviceInfo {
  const AudioDeviceInfo({required this.id, required this.label});

  /// Platform device identifier (input: record's device id; output: the
  /// device name, which is stabler across restarts than soloud's index).
  final String id;
  final String label;
}

class AudioDeviceLists {
  const AudioDeviceLists({required this.inputs, required this.outputs});
  final List<AudioDeviceInfo> inputs;
  final List<AudioDeviceInfo> outputs;
}

class RealAudioBackend implements AudioBackend {
  RealAudioBackend({
    this.inputDeviceId,
    this.inputDeviceLabel = '',
    this.outputDeviceName,
  });

  static const int sampleRate = 48000;

  /// Requested devices; null = system default.
  final String? inputDeviceId;
  final String inputDeviceLabel;
  final String? outputDeviceName;

  final AudioRecorder _rec = AudioRecorder();
  final _rx = StreamController<Float64List>.broadcast();
  StreamSubscription<Uint8List>? _recSub;
  bool _playing = false;
  bool _started = false;
  String? lastError;

  @override
  Stream<Float64List> get rx => _rx.stream;

  @override
  bool get isPlaying => _playing;

  /// Separator used on Linux to encode a PulseAudio/PipeWire device+port
  /// selection in one id: `deviceName<sep>portName[<sep>description]`.
  /// Pulse models physical jacks (mic vs line-in, headphone vs line-out)
  /// as *ports* of a single device, so each port gets its own pulldown
  /// entry.
  static const String portSep = '\t';

  /// Linux: enumerate Pulse/PipeWire sources and sinks with their ports so
  /// each physical jack is individually selectable. Returns null when
  /// pactl (or its JSON output mode) is unavailable — callers then fall
  /// back to the plain plugin enumeration.
  static Future<AudioDeviceLists?> _enumeratePulsePorts() async {
    try {
      final src =
          await Process.run('pactl', ['--format=json', 'list', 'sources']);
      final snk =
          await Process.run('pactl', ['--format=json', 'list', 'sinks']);
      if (src.exitCode != 0 || snk.exitCode != 0) return null;

      List<AudioDeviceInfo> parse(String jsonText, {required bool isSink}) {
        final out = <AudioDeviceInfo>[];
        for (final e in jsonDecode(jsonText) as List) {
          final m = e as Map<String, dynamic>;
          final name = m['name'] as String? ?? '';
          if (name.isEmpty) continue;
          if (!isSink && name.endsWith('.monitor')) continue;
          final desc = m['description'] as String? ?? name;
          final ports = (m['ports'] as List?) ?? const [];
          if (ports.length <= 1) {
            out.add(AudioDeviceInfo(
              // Sinks carry their description so the playback engine
              // (which names Pulse devices by description) can be matched.
              id: isSink ? '$name$portSep$portSep$desc' : name,
              label: desc,
            ));
          } else {
            for (final p in ports) {
              final pm = p as Map<String, dynamic>;
              final pName = pm['name'] as String? ?? '';
              final pDesc = pm['description'] as String? ?? pName;
              out.add(AudioDeviceInfo(
                id: isSink
                    ? '$name$portSep$pName$portSep$desc'
                    : '$name$portSep$pName',
                label: '$desc — $pDesc',
              ));
            }
          }
        }
        return out;
      }

      final inputs = parse(src.stdout as String, isSink: false);
      final outputs = parse(snk.stdout as String, isSink: true);

      // Card-level output ports that exist only under a different card
      // profile (e.g. a USB codec whose active profile is S/PDIF: its
      // analog output ports have no sink yet). Selecting such an entry
      // switches the card profile at start.
      //
      // Note: pactl's JSON encodes a *card's* ports/profiles as objects
      // keyed by name (unlike sinks, which use arrays); accept both.
      try {
        // Ports already offered by an existing sink.
        final presentPorts = <String>{};
        for (final e in jsonDecode(snk.stdout as String) as List) {
          for (final p in ((e as Map)['ports'] as List? ?? const [])) {
            final n = (p as Map)['name'] as String?;
            if (n != null) presentPorts.add(n);
          }
        }

        final crd =
            await Process.run('pactl', ['--format=json', 'list', 'cards']);
        if (crd.exitCode == 0) {
          for (final e in jsonDecode(crd.stdout as String) as List) {
            final m = e as Map<String, dynamic>;
            final cardName = m['name'] as String? ?? '';
            if (cardName.isEmpty) continue;
            final props =
                (m['properties'] as Map?)?.cast<String, dynamic>() ?? {};
            final cardDesc = (props['device.description'] as String?) ??
                (props['device.nick'] as String?) ??
                cardName;
            // Profile name -> priority (map- or list-shaped JSON).
            final profPriority = <String, num>{};
            final profJson = m['profiles'];
            if (profJson is Map) {
              profJson.forEach((k, v) {
                profPriority['$k'] = ((v as Map)['priority'] as num?) ?? 0;
              });
            } else if (profJson is List) {
              for (final p in profJson) {
                final pm = p as Map;
                profPriority['${pm['name']}'] =
                    (pm['priority'] as num?) ?? 0;
              }
            }
            // Ports (map- or list-shaped JSON) -> (name, details).
            final portEntries = <MapEntry<String, Map>>[];
            final portJson = m['ports'];
            if (portJson is Map) {
              portJson.forEach(
                  (k, v) => portEntries.add(MapEntry('$k', v as Map)));
            } else if (portJson is List) {
              for (final p in portJson) {
                final pm = p as Map;
                portEntries.add(MapEntry('${pm['name']}', pm));
              }
            }
            for (final entry in portEntries) {
              final pName = entry.key;
              final pm = entry.value;
              final direction =
                  ('${pm['direction'] ?? ''}').toLowerCase();
              final isOutput = direction == 'output' ||
                  (direction.isEmpty && pName.contains('output'));
              if (!isOutput) continue;
              if (presentPorts.contains(pName)) continue;
              final pProfiles = (pm['profiles'] as List? ?? const [])
                  .map((x) => '$x')
                  .where((s) => s.contains('output'))
                  .toList();
              if (pProfiles.isEmpty) continue;
              // Prefer a profile that keeps analog input alive, then the
              // highest-priority one.
              pProfiles.sort((a, b) {
                final ai = a.contains('input:analog') ? 1 : 0;
                final bi = b.contains('input:analog') ? 1 : 0;
                if (ai != bi) return bi - ai;
                return ((profPriority[b] ?? 0) - (profPriority[a] ?? 0))
                    .sign
                    .toInt();
              });
              final pDesc = '${pm['description'] ?? pName}';
              outputs.add(AudioDeviceInfo(
                id: 'card:$cardName$portSep${pProfiles.first}$portSep$pName',
                label: '$cardDesc — $pDesc',
              ));
            }
          }
        }
      } catch (_) {
        // Card enumeration is best-effort; sinks alone still work.
      }

      if (inputs.isEmpty && outputs.isEmpty) return null;
      return AudioDeviceLists(inputs: inputs, outputs: outputs);
    } catch (_) {
      return null;
    }
  }

  /// Activate a `card:`-encoded output selection: switch the card profile,
  /// wait for the sink to appear, select its port, and return the sink
  /// description (for playback-engine device matching) or null.
  Future<String?> _activateCardOutput(
      String cardName, String profile, String portName) async {
    try {
      final r = await Process.run(
          'pactl', ['set-card-profile', cardName, profile]);
      if (r.exitCode != 0) {
        lastError = 'set-card-profile: ${'${r.stderr}'.trim()}';
        return null;
      }
      for (var attempt = 0; attempt < 10; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 150));
        final snk =
            await Process.run('pactl', ['--format=json', 'list', 'sinks']);
        if (snk.exitCode != 0) continue;
        for (final e in jsonDecode(snk.stdout as String) as List) {
          final m = e as Map<String, dynamic>;
          final props =
              (m['properties'] as Map?)?.cast<String, dynamic>() ?? {};
          if (props['device.name'] != cardName) continue;
          final ports = (m['ports'] as List? ?? const [])
              .map((p) => (p as Map)['name'] as String? ?? '');
          if (!ports.contains(portName)) continue;
          final sinkName = m['name'] as String? ?? '';
          await Process.run(
              'pactl', ['set-sink-port', sinkName, portName]);
          return m['description'] as String? ?? sinkName;
        }
      }
      lastError = 'sink for $portName did not appear after profile switch';
    } catch (e) {
      lastError = 'card profile switch failed: $e';
    }
    return null;
  }

  /// Enumerate capture and playback devices. Safe to call while the modem
  /// is stopped; initializes the playback engine temporarily if needed.
  static Future<AudioDeviceLists> enumerateDevices() async {
    if (Platform.isLinux) {
      // Port-aware enumeration so line-in/line-out jacks are selectable.
      final pulse = await _enumeratePulsePorts();
      if (pulse != null) return pulse;
    }
    final inputs = <AudioDeviceInfo>[];
    final outputs = <AudioDeviceInfo>[];
    final rec = AudioRecorder();
    try {
      for (final d in await rec.listInputDevices()) {
        inputs.add(AudioDeviceInfo(id: d.id, label: d.label));
      }
    } catch (_) {
      // Leave the list empty; UI falls back to "System default".
    } finally {
      await rec.dispose();
    }
    final so = SoLoud.instance;
    final wasInited = so.isInitialized;
    try {
      if (!wasInited) {
        await so.init(sampleRate: sampleRate, channels: Channels.stereo);
      }
      for (final d in so.listPlaybackDevices()) {
        outputs.add(AudioDeviceInfo(
          id: d.name,
          label: d.isDefault ? '${d.name} (default)' : d.name,
        ));
      }
      if (!wasInited) so.deinit();
    } catch (_) {}
    return AudioDeviceLists(inputs: inputs, outputs: outputs);
  }

  /// Switch a Pulse device to the requested port ([setCmd] is
  /// `set-source-port` or `set-sink-port`) and return the id parts.
  Future<List<String>> _applyPulsePort(String encoded, String setCmd) async {
    final parts = encoded.split(portSep);
    if (parts.length > 1 && parts[1].isNotEmpty) {
      try {
        final r = await Process.run('pactl', [setCmd, parts[0], parts[1]]);
        if (r.exitCode != 0) {
          lastError = '$setCmd ${parts[1]}: ${'${r.stderr}'.trim()}';
        }
      } catch (e) {
        lastError = '$setCmd failed: $e';
      }
    }
    return parts;
  }

  @override
  Future<void> start() async {
    if (_started) return;

    // --- Linux jack/port selection (mic vs line-in, phones vs line-out) ---
    var recDeviceId = inputDeviceId;
    var outName = outputDeviceName;
    if (Platform.isLinux) {
      if (recDeviceId != null && recDeviceId.contains(portSep)) {
        final parts = await _applyPulsePort(recDeviceId, 'set-source-port');
        recDeviceId = parts[0];
      }
      if (outName != null && outName.startsWith('card:')) {
        // Port only exists under a different card profile: switch it.
        final parts = outName.substring(5).split(portSep);
        outName = parts.length > 2
            ? await _activateCardOutput(parts[0], parts[1], parts[2])
            : null;
      } else if (outName != null && outName.contains(portSep)) {
        final parts = await _applyPulsePort(outName, 'set-sink-port');
        // The playback engine (miniaudio) names Pulse devices by their
        // description, carried as the third encoded part.
        outName = parts.length > 2 && parts[2].isNotEmpty ? parts[2] : null;
      }
    }

    // --- playback ---
    // The engine runs stereo and the burst is duplicated onto both
    // channels, so left and right always carry the identical signal
    // regardless of how the device/OS would up-mix mono.
    final so = SoLoud.instance;
    if (!so.isInitialized) {
      await so.init(sampleRate: sampleRate, channels: Channels.stereo);
    }
    if (outName != null) {
      try {
        final devs = so.listPlaybackDevices();
        for (final d in devs) {
          if (d.name == outName) {
            so.changeDevice(newDevice: d);
            break;
          }
        }
      } catch (e) {
        lastError = 'output device select failed: $e';
      }
    }

    // --- capture ---
    if (!await _rec.hasPermission()) {
      throw StateError('Microphone permission denied');
    }
    final Stream<Uint8List> stream;
    try {
      stream = await _rec.startStream(RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: sampleRate,
        numChannels: 1,
        device: recDeviceId == null
            ? null
            : InputDevice(id: recDeviceId, label: inputDeviceLabel),
        echoCancel: false,
        noiseSuppress: false,
        autoGain: false,
      ));
    } catch (e) {
      final msg = '$e';
      if (msg.contains('parecord') || msg.contains('pulse')) {
        // The record plugin's Linux backend shells out to PulseAudio's
        // parecord (also provided by pipewire-pulse setups).
        throw StateError(
            'Audio capture on Linux needs the PulseAudio tools: '
            'install them with "sudo apt install pulseaudio-utils" '
            'and press Start again. ($e)');
      }
      rethrow;
    }
    _recSub = stream.listen((bytes) {
      // pcm16 little-endian -> float
      final n = bytes.length ~/ 2;
      final bd = ByteData.sublistView(bytes);
      final f = Float64List(n);
      for (var i = 0; i < n; i++) {
        f[i] = bd.getInt16(i * 2, Endian.little) / 32768.0;
      }
      _rx.add(f);
    }, onError: (Object e) {
      lastError = '$e';
    });
    _started = true;
  }

  @override
  Future<void> playBurst(Float64List samples) async {
    final so = SoLoud.instance;
    if (!so.isInitialized) throw StateError('audio not started');
    _playing = true;
    AudioSource? src;
    try {
      // Interleaved stereo with L = R (same signal on both paths).
      final f32 = Float32List(samples.length * 2);
      for (var i = 0; i < samples.length; i++) {
        final v = samples[i];
        final c = v > 1.0
            ? 1.0
            : v < -1.0
                ? -1.0
                : v.toDouble();
        f32[2 * i] = c;
        f32[2 * i + 1] = c;
      }
      src = so.setBufferStream(
        maxBufferSizeBytes: f32.length * 4 + 4096,
        bufferingType: BufferingType.released,
        bufferingTimeNeeds: 0,
        sampleRate: sampleRate,
        channels: Channels.stereo,
        format: BufferType.f32le,
      );
      so.addAudioDataStream(src, f32.buffer.asUint8List());
      so.setDataIsEnded(src);
      so.play(src);
      // Wait for the burst duration plus a small guard.
      final ms = (samples.length * 1000 / sampleRate).ceil() + 150;
      await Future<void>.delayed(Duration(milliseconds: ms));
    } finally {
      if (src != null) {
        try {
          await so.disposeSource(src);
        } catch (_) {}
      }
      _playing = false;
    }
  }

  @override
  Future<void> stop() async {
    await _recSub?.cancel();
    try {
      await _rec.stop();
      await _rec.dispose();
    } catch (_) {}
    try {
      final so = SoLoud.instance;
      if (so.isInitialized) so.deinit();
    } catch (_) {}
    _started = false;
  }
}
