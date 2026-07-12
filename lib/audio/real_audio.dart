/// Real sound-card backend: `record` for capture, `mp_audio_stream` for
/// playback. Both run at 48 kHz mono.
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
import 'dart:typed_data';

import 'package:mp_audio_stream/mp_audio_stream.dart';
import 'package:record/record.dart';

import 'audio_backend.dart';

class RealAudioBackend implements AudioBackend {
  RealAudioBackend();

  static const int sampleRate = 48000;

  final AudioRecorder _rec = AudioRecorder();
  AudioStream? _out;
  final _rx = StreamController<Float64List>.broadcast();
  StreamSubscription<Uint8List>? _recSub;
  bool _playing = false;
  bool _started = false;
  String? lastError;

  @override
  Stream<Float64List> get rx => _rx.stream;

  @override
  bool get isPlaying => _playing;

  @override
  Future<void> start() async {
    if (_started) return;
    // --- playback ---
    final out = getAudioStream();
    out.init(
      sampleRate: sampleRate,
      channels: 1,
      bufferMilliSec: 4000,
      waitingBufferMilliSec: 60,
    );
    _out = out;

    // --- capture ---
    if (!await _rec.hasPermission()) {
      throw StateError('Microphone permission denied');
    }
    final stream = await _rec.startStream(RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: sampleRate,
      numChannels: 1,
      echoCancel: false,
      noiseSuppress: false,
      autoGain: false,
    ));
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
    final out = _out;
    if (out == null) throw StateError('audio not started');
    _playing = true;
    try {
      final f32 = Float32List(samples.length);
      for (var i = 0; i < samples.length; i++) {
        final v = samples[i];
        f32[i] = v > 1.0
            ? 1.0
            : v < -1.0
                ? -1.0
                : v.toDouble();
      }
      out.push(f32);
      // Wait for the burst duration plus a small guard.
      final ms = (samples.length * 1000 / sampleRate).ceil() + 150;
      await Future<void>.delayed(Duration(milliseconds: ms));
    } finally {
      _playing = false;
    }
  }

  @override
  Future<void> stop() async {
    await _recSub?.cancel();
    await _rec.stop();
    await _rec.dispose();
    _out?.uninit();
    _started = false;
  }
}
