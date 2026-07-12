/// Audio backend abstraction.
///
/// The modem needs mono float samples at 48 kHz in both directions. The
/// real backend (see real_audio.dart) uses the `record` plugin for capture
/// and `mp_audio_stream` for playback. The loopback backend wires TX
/// straight back into RX (optionally through an impairment function) and is
/// used by tests and by the in-app "Loopback (test)" audio mode.
library;

import 'dart:async';
import 'dart:typed_data';

abstract class AudioBackend {
  /// Continuous capture stream of mono 48 kHz float samples.
  Stream<Float64List> get rx;

  /// Start capture/playback machinery.
  Future<void> start();

  /// Play a complete burst; completes when the last sample has left the
  /// speaker (plus a small guard interval).
  Future<void> playBurst(Float64List samples);

  Future<void> stop();

  bool get isPlaying;
}

/// Test/loopback backend: bursts appear on the rx stream after an optional
/// impairment function and delay.
class LoopbackAudioBackend implements AudioBackend {
  LoopbackAudioBackend({this.impair, this.chunkSize = 2400});

  /// Optional channel model applied to played bursts.
  Float64List Function(Float64List)? impair;
  final int chunkSize;

  final _rx = StreamController<Float64List>.broadcast();
  bool _playing = false;

  @override
  Stream<Float64List> get rx => _rx.stream;

  @override
  bool get isPlaying => _playing;

  @override
  Future<void> start() async {}

  @override
  Future<void> playBurst(Float64List samples) async {
    _playing = true;
    try {
      final s = impair?.call(samples) ?? samples;
      // Deliver in chunks like a real capture device would.
      for (var o = 0; o < s.length; o += chunkSize) {
        final end = (o + chunkSize).clamp(0, s.length);
        _rx.add(Float64List.sublistView(s, o, end));
        // Yield to the event loop so listeners process incrementally.
        await Future<void>.delayed(Duration.zero);
      }
    } finally {
      _playing = false;
    }
  }

  /// Inject raw samples (e.g. silence/noise between bursts in tests).
  void inject(Float64List samples) => _rx.add(samples);

  @override
  Future<void> stop() async {
    await _rx.close();
  }
}
