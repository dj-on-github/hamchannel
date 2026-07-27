/// Bluetooth handy-talkie audio backend.
///
/// Connects to a compatible HT radio (UV-Pro / GA-5WB / VR-N76 family) over
/// Bluetooth Classic and uses the radio's vendor audio RFCOMM channel in
/// place of audio cables: received SBC audio becomes the modem's RX stream,
/// and transmitted bursts are SBC-encoded and streamed to the radio, which
/// keys its transmitter automatically while audio frames arrive (no VOX or
/// PTT wiring needed).
///
/// Wire format and pacing follow HTCommander
/// (https://github.com/Ylianst/HTCommander, Apache-2.0, Ylian Saint-Hilaire;
/// reused with the author's permission):
///  * 0x7e-delimited frames, 0x7d escape (next byte XOR 0x20);
///  * first byte = command: 0x00/0x03 received SBC audio, 0x01 audio end,
///    0x02 ack, 0x09 transmit echo; transmit frames use command 0x00;
///  * SBC: 32 kHz, mono, 16 blocks, 8 subbands, bitpool 40, loudness bit
///    allocation (the HTCommander-proven configuration; some radio firmware
///    mis-decodes SNR-allocated frames);
///  * a fixed end-frame tells the radio to stop transmitting.
///
/// The modem runs at 48 kHz; this backend resamples 48↔32 kHz (2/3 ratio).
library;

import 'dart:async';
import 'dart:typed_data';

import '../sbc/sbc_decoder.dart';
import '../sbc/sbc_encoder.dart';
import '../sbc/sbc_enums.dart';
import '../sbc/sbc_frame.dart';
import 'audio_backend.dart';
import 'bt_classic.dart';
import 'resample.dart';

/// 0x7e/0x7d framing helpers (public for tests).
class BtAudioFraming {
  /// Frame [payload] with start/end 0x7e markers and a leading command byte,
  /// escaping 0x7d/0x7e bytes.
  static Uint8List escape(int cmd, Uint8List payload) {
    final out = BytesBuilder(copy: false);
    out.addByte(0x7e);
    out.addByte(cmd);
    for (final b in payload) {
      if (b == 0x7d || b == 0x7e) {
        out.addByte(0x7d);
        out.addByte(b ^ 0x20);
      } else {
        out.addByte(b);
      }
    }
    out.addByte(0x7e);
    return out.toBytes();
  }

  /// Unescape 0x7d-escaped bytes.
  static Uint8List unescape(Uint8List buffer) {
    if (buffer.isEmpty) return buffer;
    final out = Uint8List(buffer.length);
    var dst = 0, src = 0;
    while (src < buffer.length) {
      if (buffer[src] == 0x7d) {
        src++;
        if (src < buffer.length) out[dst++] = buffer[src] ^ 0x20;
      } else {
        out[dst++] = buffer[src];
      }
      src++;
    }
    return Uint8List.sublistView(out, 0, dst);
  }
}

/// Incremental extractor of 0x7e-delimited frames (port of HTCommander's
/// accumulator logic; public for tests).
class BtFrameExtractor {
  final List<int> _acc = <int>[];
  static const int _maxAccumulatorSize = 64 * 1024;

  /// Add bytes and return every complete, unescaped frame now available.
  List<Uint8List> add(Uint8List data) {
    _acc.addAll(data);
    if (_acc.length > _maxAccumulatorSize) _acc.clear();
    final frames = <Uint8List>[];
    Uint8List? f;
    while ((f = _extract()) != null) {
      final u = BtAudioFraming.unescape(f!);
      if (u.isNotEmpty) frames.add(u);
    }
    return frames;
  }

  Uint8List? _extract() {
    while (true) {
      final len = _acc.length;
      if (len < 2) return null;
      var scanFrom = 0;
      if (_acc[0] == 0x7e && _acc[1] == 0x7e) scanFrom = 1;
      var start = -1, end = -1;
      for (var i = scanFrom; i < len; i++) {
        if (_acc[i] == 0x7e) {
          if (start == -1) {
            start = i;
          } else {
            end = i;
            break;
          }
        }
      }
      if (start != -1 && end != -1 && end > start + 1) {
        final out = Uint8List.fromList(_acc.sublist(start + 1, end));
        _acc.removeRange(0, end + 1);
        return out;
      } else if (start != -1 && end != -1 && end == start + 1) {
        _acc.removeRange(0, end);
        continue;
      } else if (start > 0) {
        _acc.removeRange(0, start);
        continue;
      } else if (start == -1) {
        _acc.clear();
        return null;
      } else {
        return null;
      }
    }
  }
}

class BtRadioAudioBackend implements AudioBackend {
  BtRadioAudioBackend({required this.macAddress, this.onLog});

  /// The radio's audio stream format.
  static const int radioSampleRate = 32000;

  /// PCM bytes consumed per encoded SBC frame: blocks * subbands * 2.
  static const int _pcmPerFrame = 16 * 8 * 2;

  /// Transmit pacing lead (ms): how far ahead of real time the encoder may
  /// run. The native plugins provide real backpressure (Linux blocks on the
  /// RFCOMM socket; macOS answers each write only on rfcommChannelWriteComplete),
  /// so this bounds how much audio sits queued in the OS + radio. It must
  /// stay UNDER the radio's internal audio FIFO depth — over-delivering
  /// during the lead build-up overflows it and the dropped frames stutter
  /// the start of the transmission. 1 s matches HTCommander's field-proven
  /// voice lead.
  static const int _txLeadMs = 1000;

  /// Silence prepended to every burst (ms of audio). The radio keys its
  /// transmitter when audio frames arrive; key-up, buffer settling and any
  /// early frame drops then land on silence instead of eating the burst's
  /// leader/chanest — the part the receiver cannot synchronize without.
  static const int _txPrerollMs = 1500;

  /// Trailing silence (ms) so the end-of-audio marker never clips the
  /// postamble while the radio drains its buffer.
  static const int _txTailMs = 250;

  /// Retries when the native layer refuses an audio write (e.g. a
  /// momentarily full outbound queue) before declaring the burst lost.
  static const int _txWriteRetries = 50;

  /// Frame that tells the radio to stop transmitting.
  static final Uint8List _endAudioFrame = Uint8List.fromList(
      <int>[0x7e, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x7e]);

  final String macAddress;
  final void Function(String)? onLog;

  final _rx = StreamController<Float64List>.broadcast();
  final _extractor = BtFrameExtractor();
  final SbcDecoder _dec = SbcDecoder();
  final SbcEncoder _enc = SbcEncoder();
  late final StreamingResampler _up32to48 = StreamingResampler(3, 2);

  StreamSubscription<Uint8List>? _dataSub;
  StreamSubscription<BluetoothClassicEvent>? _connSub;
  bool _started = false;
  bool _openedControl = false;
  bool _playing = false;
  String? lastError;

  late final SbcFrame _encoderFrame = SbcFrame()
    ..frequency = SbcFrequency.freq32K
    ..blocks = 16
    ..mode = SbcMode.mono
    // Loudness, NOT snr: although SNR allocation is theoretically better for
    // a modem waveform (and is what HTCommander's DART mode selects), some
    // radio firmware decodes SNR-allocated frames incorrectly, producing
    // heavily distorted transmit audio. Loudness at bitpool 40 is the
    // configuration proven clean over the air by HTCommander voice, and the
    // radios' own encoders use it for the receive direction — measured good
    // enough for the OFDM profiles that fit the Bluetooth path.
    ..allocationMethod = SbcBitAllocationMethod.loudness
    ..subbands = 8
    ..bitpool = 40;

  void _log(String s) => onLog?.call('[BT radio] $s');

  @override
  Stream<Float64List> get rx => _rx.stream;

  @override
  bool get isPlaying => _playing;

  /// List compatible radios (falls back to all paired devices so the user
  /// can still pick a radio whose SDP cache is incomplete).
  static Future<List<BluetoothClassicDevice>> listRadios() async {
    final bridge = BluetoothClassicBridge.instance;
    final compatible = await bridge.findCompatibleDevices();
    if (compatible.isNotEmpty) return compatible;
    return bridge.getPairedDevices();
  }

  @override
  Future<void> start() async {
    if (_started) return;
    if (macAddress.isEmpty) {
      throw StateError('No Bluetooth radio selected (Settings tab).');
    }
    final bridge = BluetoothClassicBridge.instance;

    _connSub = bridge.audioConnectionEvents.listen((e) {
      final a = e.address.toUpperCase().replaceAll('-', ':');
      final b = macAddress.toUpperCase().replaceAll('-', ':');
      if (a != b) return;
      if (e.type == BluetoothClassicEventType.disconnected) {
        lastError = 'Bluetooth radio audio channel disconnected';
        _log(lastError!);
      }
    });

    // Bring the channels up in HTCommander's field-proven order: the control
    // (SPP) channel first — the radio expects its command side connected —
    // then the audio channel. Running audio without the control channel is an
    // untested radio state and was implicated in distorted transmit audio.
    _openedControl = await bridge.connect(macAddress);
    if (!_openedControl) {
      _log('control channel connect failed — trying audio anyway');
    }
    var ok = await bridge.connectAudio(macAddress);
    for (var attempt = 0; attempt < 3 && !ok; attempt++) {
      _log('audio channel refused; retrying');
      await Future<void>.delayed(const Duration(milliseconds: 700));
      ok = await bridge.connectAudio(macAddress);
    }
    if (!ok) {
      await _connSub?.cancel();
      _connSub = null;
      if (_openedControl) await bridge.disconnect(macAddress);
      throw StateError(
          'Could not open the Bluetooth audio channel to $macAddress — '
          'is the radio paired and in range?');
    }

    _dataSub = bridge.getAudioDataStream(macAddress).listen(_onAudioBytes,
        onError: (Object e) {
      lastError = 'BT audio stream error: $e';
    });
    _started = true;
    _log('audio channel connected to $macAddress');
  }

  void _onAudioBytes(Uint8List data) {
    for (final frame in _extractor.add(data)) {
      switch (frame[0]) {
        case 0x00: // received audio
        case 0x03:
          _decodeAndEmit(frame, 1, frame.length - 1);
        case 0x01: // audio end
        case 0x02: // ack
        case 0x09: // transmit echo — ignored (modem RX is muted during TX)
          break;
        default:
          break;
      }
    }
  }

  void _decodeAndEmit(Uint8List buf, int start, int length) {
    var offset = start;
    var remaining = length;
    final samples = <int>[];
    while (remaining > 0) {
      final sync = buf[offset];
      if (sync != 0x9C && sync != 0xAD) break;
      if (remaining < SbcFrame.headerSize) break;
      final header =
          Uint8List.sublistView(buf, offset, offset + SbcFrame.headerSize);
      final probed = _dec.probe(header);
      if (probed == null) break;
      final frameSize = probed.getFrameSize();
      if (frameSize <= 0 || frameSize > remaining) break;
      final result =
          _dec.decode(Uint8List.sublistView(buf, offset, offset + frameSize));
      if (!result.success) break;
      samples.addAll(result.pcmLeft);
      offset += frameSize;
      remaining -= frameSize;
    }
    if (samples.isEmpty) return;
    // int16 @32k -> float @48k
    final f32k = Float64List(samples.length);
    for (var i = 0; i < samples.length; i++) {
      f32k[i] = samples[i] / 32768.0;
    }
    final f48k = _up32to48.process(f32k);
    if (f48k.isNotEmpty) _rx.add(f48k);
  }

  @override
  Future<void> playBurst(Float64List samples) async {
    if (!_started) throw StateError('Bluetooth radio not connected');
    _playing = true;
    final bridge = BluetoothClassicBridge.instance;
    try {
      // Wrap the burst in silence: preroll for radio key-up/buffer settling,
      // a short tail so the end marker doesn't clip the postamble.
      const preroll = 48 * _txPrerollMs; // samples @48 kHz
      const tail = 48 * _txTailMs;
      final padded = Float64List(preroll + samples.length + tail);
      padded.setRange(preroll, preroll + samples.length, samples);

      // 48 kHz float -> 32 kHz int16 bytes.
      final r32 = StreamingResampler.resampleAll(padded, 2, 3);
      final pcm = Uint8List(2 * r32.length);
      final bd = ByteData.sublistView(pcm);
      for (var i = 0; i < r32.length; i++) {
        var v = (r32[i] * 32767.0).round();
        if (v > 32767) v = 32767;
        if (v < -32768) v = -32768;
        bd.setInt16(2 * i, v, Endian.little);
      }

      // Paced transmit loop (HTCommander pacing, deep data lead).
      const bytesPerSecond = radioSampleRate * 2;
      final stopwatch = Stopwatch()..start();
      var offset = 0;
      var sentBytes = 0;
      while (pcm.length - offset >= _pcmPerFrame) {
        final (encoded, consumed) = _encodeSbcFrames(pcm, offset);
        if (encoded == null || consumed <= 0) break;
        // Never silently drop a refused write — a missing bundle tears a
        // hole in the OFDM waveform the receiver cannot ride over.
        final framed = BtAudioFraming.escape(0, encoded);
        var sent = false;
        for (var attempt = 0; attempt < _txWriteRetries && !sent; attempt++) {
          sent = await bridge.sendAudio(macAddress, framed);
          if (!sent) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
        }
        if (!sent) {
          lastError = 'Bluetooth audio write kept failing — burst aborted';
          _log(lastError!);
          break;
        }
        offset += consumed;
        sentBytes += consumed;
        final expectedElapsedMs =
            (sentBytes * 1000) ~/ bytesPerSecond - _txLeadMs;
        final waitMs = expectedElapsedMs - stopwatch.elapsedMilliseconds;
        if (waitMs > 0) {
          await Future<void>.delayed(
              Duration(milliseconds: waitMs < 100 ? waitMs : 100));
        }
      }

      // Delivery diagnostic: audio seconds handed to the radio vs wall time.
      // Wall ≈ audio − lead means pacing tracked real time; wall well below
      // that means the link outran the radio (overflow risk); wall above
      // audio means the link couldn't keep up (starvation/stutter).
      _log('burst: ${(sentBytes / bytesPerSecond).toStringAsFixed(1)} s audio '
          'delivered in ${(stopwatch.elapsedMilliseconds / 1000).toStringAsFixed(1)} s '
          '(lead ${_txLeadMs / 1000} s)');

      // Stop-transmitting marker (delivered in stream order after the audio).
      for (var attempt = 0; attempt < 5; attempt++) {
        if (await bridge.sendAudio(macAddress, _endAudioFrame)) break;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }

      // Hold until the radio has actually played the burst out, so the modem
      // only unmutes / starts ACK timers once the channel is clear again.
      final totalMs = (pcm.length ~/ 2) * 1000 ~/ radioSampleRate + 250;
      final remainMs = totalMs - stopwatch.elapsedMilliseconds;
      if (remainMs > 0) {
        await Future<void>.delayed(Duration(milliseconds: remainMs));
      }
    } finally {
      _playing = false;
    }
  }

  (Uint8List?, int) _encodeSbcFrames(Uint8List pcm, int offset) {
    var available = pcm.length - offset;
    var consumed = 0;
    var generated = 0;
    final builder = BytesBuilder(copy: false);
    while (available >= _pcmPerFrame && generated < 300) {
      final chunk =
          Uint8List.sublistView(pcm, offset + consumed, offset + consumed + _pcmPerFrame);
      final int16 = Int16List(_pcmPerFrame ~/ 2);
      final bd = ByteData.sublistView(chunk);
      for (var i = 0; i < int16.length; i++) {
        int16[i] = bd.getInt16(2 * i, Endian.little);
      }
      final frame = _enc.encode(int16, null, _encoderFrame);
      if (frame == null || frame.isEmpty) break;
      builder.add(frame);
      consumed += _pcmPerFrame;
      available -= _pcmPerFrame;
      generated += frame.length;
    }
    if (generated == 0) return (null, 0);
    return (builder.toBytes(), consumed);
  }

  @override
  Future<void> stop() async {
    if (!_started) {
      await _connSub?.cancel();
      _connSub = null;
      return;
    }
    _started = false;
    await _dataSub?.cancel();
    _dataSub = null;
    await _connSub?.cancel();
    _connSub = null;
    final bridge = BluetoothClassicBridge.instance;
    try {
      await bridge.disconnectAudio(macAddress);
    } catch (_) {}
    if (_openedControl) {
      try {
        await bridge.disconnect(macAddress);
      } catch (_) {}
      _openedControl = false;
    }
    _log('disconnected');
  }
}
