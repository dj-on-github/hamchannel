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
      // switches the card profile at start. The card list is parsed from
      // pactl's *text* output — its JSON shape for cards varies between
      // pactl versions.
      try {
        // Ports already offered by an existing sink.
        final presentPorts = <String>{};
        for (final e in jsonDecode(snk.stdout as String) as List) {
          for (final p in ((e as Map)['ports'] as List? ?? const [])) {
            final n = (p as Map)['name'] as String?;
            if (n != null) presentPorts.add(n);
          }
        }
        outputs.addAll(await _cardOutputPortsFromText(presentPorts));
      } catch (_) {
        // Card enumeration is best-effort; sinks alone still work.
      }

      if (inputs.isEmpty && outputs.isEmpty) return null;
      return AudioDeviceLists(inputs: inputs, outputs: outputs);
    } catch (_) {
      return null;
    }
  }

  /// Parse `pactl list cards` (text output, LC_ALL=C) and return output
  /// entries for card ports not currently offered by any sink. The text
  /// format is stable across pactl versions:
  ///
  ///   Name: alsa_card.usb-...
  ///     device.description = "CUBILUX CB5"
  ///   Profiles:
  ///     output:analog-stereo+input:analog-stereo: ... (sinks: 1, ...,
  ///         priority: 6565, available: no)
  ///   Ports:
  ///     analog-output-headphones: Headphones (type: Headphones, ...)
  ///       Part of profile(s): output:analog-stereo, output:analog-...
  static Future<List<AudioDeviceInfo>> _cardOutputPortsFromText(
      Set<String> presentPorts) async {
    final out = <AudioDeviceInfo>[];
    try {
      final r = await Process.run('pactl', ['list', 'cards'],
          environment: {'LC_ALL': 'C'});
      if (r.exitCode != 0) return out;

      // Profile names contain colons (output:analog-stereo+input:...), so
      // match the full non-space token before ': '.
      final profileRe =
          RegExp(r'^(\S+): .*\(sinks: \d+, sources: \d+, priority: (\d+)');
      final portRe = RegExp(r'^([A-Za-z0-9._+\-]+): (.*) \(type: ');

      String cardName = '';
      String cardDesc = '';
      final profPriority = <String, num>{};
      String section = '';
      String pendingPortName = '';
      String pendingPortDesc = '';

      void emitPort(List<String> profs) {
        final pName = pendingPortName;
        pendingPortName = '';
        if (pName.isEmpty || cardName.isEmpty) return;
        if (!pName.contains('output')) return; // inputs come from sources
        if (presentPorts.contains(pName)) return;
        final candidates =
            profs.where((s) => s.contains('output')).toList();
        if (candidates.isEmpty) return;
        // Prefer a profile that keeps analog input alive, then priority.
        candidates.sort((a, b) {
          final ai = a.contains('input:analog') ? 1 : 0;
          final bi = b.contains('input:analog') ? 1 : 0;
          if (ai != bi) return bi - ai;
          return ((profPriority[b] ?? 0) - (profPriority[a] ?? 0))
              .sign
              .toInt();
        });
        out.add(AudioDeviceInfo(
          id: 'card:$cardName$portSep${candidates.first}$portSep$pName',
          label: '$cardDesc — $pendingPortDesc',
        ));
      }

      for (final raw in '${r.stdout}'.split('\n')) {
        final line = raw.trim();
        if (line.startsWith('Name: ')) {
          cardName = line.substring(6).trim();
          cardDesc = cardName;
          profPriority.clear();
          section = '';
          pendingPortName = '';
        } else if (line.startsWith('device.description = "')) {
          cardDesc = line.substring(22, line.length - 1);
        } else if (line == 'Profiles:') {
          section = 'profiles';
        } else if (line == 'Ports:') {
          section = 'ports';
        } else if (line.startsWith('Active Profile:')) {
          section = '';
        } else if (section == 'profiles') {
          final m = profileRe.firstMatch(line);
          if (m != null) {
            profPriority[m.group(1)!] = num.tryParse(m.group(2)!) ?? 0;
          }
        } else if (section == 'ports') {
          if (line.startsWith('Part of profile(s): ')) {
            emitPort(line.substring(20).split(',').map((s) => s.trim()).toList());
          } else {
            final m = portRe.firstMatch(line);
            if (m != null) {
              pendingPortName = m.group(1)!;
              pendingPortDesc = m.group(2)!;
            }
          }
        }
      }
    } catch (_) {}
    return out;
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
      // WirePlumber can take a while to re-probe the card after a profile
      // switch; wait up to 6 s for the new sink to appear.
      for (var attempt = 0; attempt < 24; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
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

  /// Diagnostics from the last [enumerateDevices] call: which enumeration
  /// path was used and why it fell back to a poorer one. Surfaced in the
  /// app log so Linux audio problems are visible to the user.
  static String enumerationNote = '';

  /// Enumerate capture and playback devices. Safe to call while the modem
  /// is stopped.
  static Future<AudioDeviceLists> enumerateDevices() async {
    enumerationNote = '';
    if (Platform.isLinux) {
      // Port-aware enumeration so line-in/line-out jacks are selectable.
      final pulse = await _enumeratePulsePorts();
      if (pulse != null) return pulse;
      // Older pactl (< 15.0) has no --format=json; parse the text output
      // instead so jacks/ports stay individually selectable.
      final text = await _enumeratePulseText();
      if (text != null) {
        enumerationNote =
            'pactl JSON mode unavailable; used text-mode parsing.';
        return text;
      }
      enumerationNote = 'pactl enumeration failed; using plugin fallback '
          '(no per-jack entries — is pulseaudio-utils installed?)';
    }
    // Last-resort plugin enumeration (no port/jack granularity).
    final inputs = <AudioDeviceInfo>[];
    final outputs = <AudioDeviceInfo>[];
    final rec = AudioRecorder();
    try {
      for (final d in await rec.listInputDevices()) {
        // record_linux leaves the surrounding quotes of node.name in the
        // device id; strip them so the id is accepted by parecord again.
        inputs.add(
            AudioDeviceInfo(id: d.id.replaceAll('"', ''), label: d.label));
      }
    } catch (_) {
      // Leave the list empty; UI falls back to "System default".
    } finally {
      await rec.dispose();
    }
    try {
      // listPlaybackDevices creates its own miniaudio context, so the
      // engine does not need to be (temporarily) initialized for this.
      for (final d in SoLoud.instance.listPlaybackDevices()) {
        outputs.add(AudioDeviceInfo(
          id: d.name,
          label: d.isDefault ? '${d.name} (default)' : d.name,
        ));
      }
    } catch (_) {}
    return AudioDeviceLists(inputs: inputs, outputs: outputs);
  }

  /// Text-mode fallback for [_enumeratePulsePorts], parsing
  /// `pactl list sources` / `pactl list sinks` (LC_ALL=C). Produces the
  /// same id encoding as the JSON path, so [start] works unchanged.
  static Future<AudioDeviceLists?> _enumeratePulseText() async {
    try {
      final src = await Process.run('pactl', ['list', 'sources'],
          environment: {'LC_ALL': 'C'});
      final snk = await Process.run('pactl', ['list', 'sinks'],
          environment: {'LC_ALL': 'C'});
      if (src.exitCode != 0 || snk.exitCode != 0) return null;

      final portRe = RegExp(r'^([A-Za-z0-9._+\-]+): (.*) \(type: ');

      // Parses one pactl list output. Returns the device entries plus the
      // set of port names seen (the port set is only used for sinks, to
      // drive the card-level output scan below).
      (List<AudioDeviceInfo>, Set<String>) parse(String text,
          {required bool isSink}) {
        final out = <AudioDeviceInfo>[];
        final portNames = <String>{};
        var name = '';
        var desc = '';
        final ports = <(String, String)>[];
        var inPorts = false;

        void flush() {
          final n = name;
          final d = desc.isEmpty ? name : desc;
          final ps = List<(String, String)>.from(ports);
          name = '';
          desc = '';
          ports.clear();
          inPorts = false;
          if (n.isEmpty) return;
          if (!isSink && n.endsWith('.monitor')) return;
          if (ps.length <= 1) {
            out.add(AudioDeviceInfo(
              id: isSink ? '$n$portSep$portSep$d' : n,
              label: d,
            ));
          } else {
            for (final p in ps) {
              out.add(AudioDeviceInfo(
                id: isSink
                    ? '$n$portSep${p.$1}$portSep$d'
                    : '$n$portSep${p.$1}',
                label: '$d — ${p.$2}',
              ));
            }
          }
        }

        for (final raw in text.split('\n')) {
          final line = raw.trim();
          if (line.startsWith('Source #') || line.startsWith('Sink #')) {
            flush();
          } else if (line.startsWith('Name: ')) {
            name = line.substring(6).trim();
          } else if (line.startsWith('Description: ')) {
            desc = line.substring(13).trim();
          } else if (line == 'Ports:') {
            inPorts = true;
          } else if (line.startsWith('Active Port:')) {
            inPorts = false;
          } else if (inPorts) {
            final m = portRe.firstMatch(line);
            if (m != null) {
              ports.add((m.group(1)!, m.group(2)!));
              portNames.add(m.group(1)!);
            }
          }
        }
        flush();
        return (out, portNames);
      }

      final inputs = parse('${src.stdout}', isSink: false).$1;
      final sinkResult = parse('${snk.stdout}', isSink: true);
      final outputs = sinkResult.$1;

      // Card-level output ports that exist only under a different card
      // profile (same treatment as the JSON path).
      try {
        outputs.addAll(await _cardOutputPortsFromText(sinkResult.$2));
      } catch (_) {
        // Card enumeration is best-effort; sinks alone still work.
      }

      if (inputs.isEmpty && outputs.isEmpty) return null;
      return AudioDeviceLists(inputs: inputs, outputs: outputs);
    } catch (_) {
      return null;
    }
  }

  /// Find the playback device whose Pulse/PipeWire sink description is
  /// [desc]: exact match first, then a unique prefix match (miniaudio and
  /// pactl occasionally disagree by trailing characters). Returns null
  /// when the description is absent or ambiguous.
  static PlaybackDevice? _findPlaybackDevice(
      List<PlaybackDevice> devs, String desc) {
    for (final d in devs) {
      if (d.name == desc) return d;
    }
    final approx = devs
        .where((d) => d.name.startsWith(desc) || desc.startsWith(d.name))
        .toList();
    return approx.length == 1 ? approx.first : null;
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
  Future<void> start({bool capture = true}) async {
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
        if (parts.length > 2) {
          outName = await _activateCardOutput(parts[0], parts[1], parts[2]);
          if (outName == null) {
            throw StateError(lastError ??
                'could not activate the selected card output');
          }
        } else {
          outName = null;
        }
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
    //
    // The selected sink is opened directly (miniaudio's PulseAudio backend
    // names devices by sink description, so the description carried in the
    // selection id identifies it). The system default sink is deliberately
    // left untouched: rerouting it is global to the whole desktop, races
    // with PipeWire's asynchronous default handling, and stays behind if
    // the app crashes.
    final so = SoLoud.instance;
    PlaybackDevice? selected;
    if (outName != null) {
      // listPlaybackDevices uses its own miniaudio context and works
      // while the engine is stopped.
      final devs = so.listPlaybackDevices();
      selected = _findPlaybackDevice(devs, outName);
      if (selected == null) {
        throw StateError('selected output "$outName" not found among the '
            '${devs.length} playback device(s); re-scan the audio devices '
            'in Settings and pick the output again');
      }
    }
    if (!so.isInitialized) {
      await so.init(
          sampleRate: sampleRate,
          channels: Channels.stereo,
          device: selected);
    } else if (selected != null) {
      so.changeDevice(newDevice: selected);
    }

    // --- capture ---
    if (!capture) {
      // Output-only use (audio self-test): skip opening the microphone.
      _started = true;
      return;
    }
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
