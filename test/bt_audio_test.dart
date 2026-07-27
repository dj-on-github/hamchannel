/// Tests for the Bluetooth handy-talkie audio path: 0x7e framing, the
/// 48 kHz ↔ 32 kHz resampler, the SBC codec round trip, and a full modem
/// burst pushed through the exact chain the BT backend uses
/// (48k float → 32k int16 → SBC → framing → unframing → SBC decode →
/// 48k float → ModemReceiver).
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hamchannel/audio/bt_radio_backend.dart';
import 'package:hamchannel/audio/resample.dart';
import 'package:hamchannel/dsp/modem_params.dart';
import 'package:hamchannel/modem/modem.dart';
import 'package:hamchannel/sbc/sbc_decoder.dart';
import 'package:hamchannel/sbc/sbc_encoder.dart';
import 'package:hamchannel/sbc/sbc_enums.dart';
import 'package:hamchannel/sbc/sbc_frame.dart';

/// Encoder configuration used by the backend (32 kHz mono modem waveform;
/// loudness allocation, bitpool 18 — see BtRadioAudioBackend for why).
SbcFrame btEncoderFrame() => SbcFrame()
  ..frequency = SbcFrequency.freq32K
  ..blocks = 16
  ..mode = SbcMode.mono
  ..allocationMethod = SbcBitAllocationMethod.loudness
  ..subbands = 8
  ..bitpool = 18;

/// PCM samples consumed per SBC frame (blocks × subbands).
const int samplesPerSbcFrame = 16 * 8;

/// Goertzel power of [x] at frequency [hz] (sample rate [fs]).
double goertzel(Float64List x, double hz, double fs) {
  final w = 2 * math.pi * hz / fs;
  final c = 2 * math.cos(w);
  var s0 = 0.0, s1 = 0.0, s2 = 0.0;
  for (final v in x) {
    s0 = v + c * s1 - s2;
    s2 = s1;
    s1 = s0;
  }
  return (s1 * s1 + s2 * s2 - c * s1 * s2) / (x.length * x.length / 4);
}

Float64List sine(double hz, double fs, int n, {double amp = 0.5}) {
  final x = Float64List(n);
  for (var i = 0; i < n; i++) {
    x[i] = amp * math.sin(2 * math.pi * hz * i / fs);
  }
  return x;
}

void main() {
  group('BtAudioFraming', () {
    test('escape/unescape round-trips, including 0x7d/0x7e bytes', () {
      final payload = Uint8List.fromList([
        0x00, 0x7e, 0x7d, 0xff, 0x7e, 0x7e, 0x7d, 0x01, 0x5d, 0x5e,
      ]);
      final framed = BtAudioFraming.escape(3, payload);
      expect(framed.first, 0x7e);
      expect(framed.last, 0x7e);
      // No unescaped 0x7e inside the frame body.
      for (var i = 1; i < framed.length - 1; i++) {
        expect(framed[i], isNot(0x7e));
      }
      final inner = Uint8List.sublistView(framed, 1, framed.length - 1);
      final restored = BtAudioFraming.unescape(inner);
      expect(restored[0], 3); // command byte
      expect(restored.sublist(1), payload);
    });

    test('extractor finds frames across arbitrary chunk boundaries', () {
      final p1 = Uint8List.fromList(List.generate(60, (i) => (i * 7) & 0xff));
      final p2 = Uint8List.fromList([0x7e, 0x7d, 0x20, 0x00]);
      final stream = BytesBuilder()
        ..add([0x13, 0x37]) // leading garbage (no 0x7e)
        ..add(BtAudioFraming.escape(0, p1))
        ..add(BtAudioFraming.escape(2, p2));
      final bytes = stream.toBytes();

      final ex = BtFrameExtractor();
      final frames = <Uint8List>[];
      // Feed 3 bytes at a time to exercise partial-frame accumulation.
      for (var o = 0; o < bytes.length; o += 3) {
        final end = math.min(o + 3, bytes.length);
        frames.addAll(ex.add(Uint8List.sublistView(bytes, o, end)));
      }
      expect(frames, hasLength(2));
      expect(frames[0][0], 0);
      expect(frames[0].sublist(1), p1);
      expect(frames[1][0], 2);
      expect(frames[1].sublist(1), p2);
    });

    test('extractor handles back-to-back frames sharing a 0x7e', () {
      final p = Uint8List.fromList([1, 2, 3, 4]);
      final a = BtAudioFraming.escape(0, p);
      final b = BtAudioFraming.escape(0, p);
      final joined = Uint8List.fromList([...a, ...b]);
      final frames = BtFrameExtractor().add(joined);
      expect(frames, hasLength(2));
      for (final f in frames) {
        expect(f[0], 0);
        expect(f.sublist(1), p);
      }
    });
  });

  group('StreamingResampler', () {
    test('48k→32k→48k round trip preserves a 1 kHz tone', () {
      final x = sine(1000, 48000, 48000);
      final down = StreamingResampler.resampleAll(x, 2, 3);
      // Rate ratio: 2/3 of the input length (± filter tail).
      expect(down.length, closeTo(x.length * 2 / 3, 200));
      final up = StreamingResampler.resampleAll(down, 3, 2);
      expect(up.length, closeTo(x.length, 300));

      // Analyze the steady-state middle of the result.
      final mid = Float64List.sublistView(up, 4800, up.length - 4800);
      var peak = 0.0, p = 0.0;
      for (final v in mid) {
        peak = math.max(peak, v.abs());
        p += v * v;
      }
      final rms = math.sqrt(p / mid.length);
      expect(peak, closeTo(0.5, 0.03), reason: 'amplitude preserved');
      // Tone stays at 1 kHz: Goertzel power ≈ (amp)^2, and it accounts for
      // essentially all the signal power.
      final tone = goertzel(mid, 1000, 48000);
      expect(tone, closeTo(0.25, 0.03));
      // For a pure tone, Goertzel power == 2·rms² — all power is at 1 kHz.
      expect(tone / (2 * rms * rms), closeTo(1.0, 0.02),
          reason: 'no images/aliases');
    });

    test('streaming chunks equal one-shot output', () {
      final x = sine(700, 48000, 9600);
      final oneShot = StreamingResampler.resampleAll(x, 2, 3);
      final r = StreamingResampler(2, 3);
      final acc = <double>[];
      for (var o = 0; o < x.length; o += 480) {
        acc.addAll(r.process(Float64List.sublistView(x, o, o + 480)));
      }
      acc.addAll(r.flush());
      expect(acc.length, oneShot.length);
      for (var i = 0; i < acc.length; i++) {
        expect(acc[i], closeTo(oneShot[i], 1e-12));
      }
    });
  });

  group('SBC codec', () {
    test('encode/decode round-trips a 600 Hz tone at 32 kHz', () {
      const n = samplesPerSbcFrame * 60; // 7680 samples = 240 ms
      final pcm = Int16List(n);
      for (var i = 0; i < n; i++) {
        pcm[i] = (8000 * math.sin(2 * math.pi * 600 * i / 32000)).round();
      }

      final enc = SbcEncoder();
      final dec = SbcDecoder();
      final cfg = btEncoderFrame();
      final out = <int>[];
      for (var o = 0; o + samplesPerSbcFrame <= n; o += samplesPerSbcFrame) {
        final frame = enc.encode(
            Int16List.sublistView(pcm, o, o + samplesPerSbcFrame), null, cfg);
        expect(frame, isNotNull);
        final r = dec.decode(frame);
        expect(r.success, isTrue);
        out.addAll(r.pcmLeft);
      }
      expect(out.length, n);

      // Codec delay: align by searching the best lag, then measure SNR.
      var bestLag = 0;
      var bestCorr = -double.infinity;
      for (var lag = 0; lag < 300; lag++) {
        var c = 0.0;
        for (var i = 0; i < 2000; i++) {
          c += pcm[i].toDouble() * out[i + lag];
        }
        if (c > bestCorr) {
          bestCorr = c;
          bestLag = lag;
        }
      }
      var sig = 0.0, err = 0.0;
      final m = n - bestLag - samplesPerSbcFrame;
      for (var i = samplesPerSbcFrame; i < m; i++) {
        final e = pcm[i] - out[i + bestLag];
        sig += pcm[i].toDouble() * pcm[i];
        err += e.toDouble() * e;
      }
      final snrDb = 10 * math.log(sig / err) / math.ln10;
      // Bitpool 18 is coarser than 40; ~10+ dB is expected and sufficient
      // (the full modem-chain tests below are the real gate).
      expect(snrDb, greaterThan(10),
          reason: 'SBC round-trip SNR was ${snrDb.toStringAsFixed(1)} dB');
    });
  });

  group('modem burst through the Bluetooth audio chain', () {
    /// Runs a burst through exactly what BtRadioAudioBackend does:
    /// TX: 48k float → 32k float → int16 → SBC frames → escape(0, …)
    /// RX: extractor → SBC decode → int16 → float → 48k float → receiver.
    List<ReceivedBurst> viaBtChain({
      required ChannelWidth width,
      required SubcarrierModulation mod,
      required LdpcRate rate,
      required Uint8List payload,
    }) {
      final p = ModemParams(width: width);
      final tx = ModemTransmitter(p);
      final wave = tx.buildBurst(
        type: 0,
        srcCall: 'W1AW',
        dstCall: 'KD2XYZ',
        burstId: 9,
        mod: mod,
        rate: rate,
        payload: payload,
        level: 0.5,
      );

      // Silence padding as the radio would give us around the burst.
      final padded = Float64List(4800 + wave.length + 9600);
      padded.setRange(4800, 4800 + wave.length, wave);

      // --- transmit side ---
      final f32 = StreamingResampler.resampleAll(padded, 2, 3);
      final nFrames = f32.length ~/ samplesPerSbcFrame;
      final enc = SbcEncoder();
      final cfg = btEncoderFrame();
      final onAir = BytesBuilder();
      for (var f = 0; f < nFrames; f++) {
        final int16 = Int16List(samplesPerSbcFrame);
        for (var i = 0; i < samplesPerSbcFrame; i++) {
          var v = (f32[f * samplesPerSbcFrame + i] * 32767.0).round();
          if (v > 32767) v = 32767;
          if (v < -32768) v = -32768;
          int16[i] = v;
        }
        final frame = enc.encode(int16, null, cfg);
        expect(frame, isNotNull);
        onAir.add(BtAudioFraming.escape(0, frame!));
      }
      final bytes = onAir.toBytes();

      // --- receive side ---
      final ex = BtFrameExtractor();
      final dec = SbcDecoder();
      final up = StreamingResampler(3, 2);
      final got = <ReceivedBurst>[];
      final rx = ModemReceiver(p, onBurst: got.add);
      const chunk = 500; // odd size to force frame splits
      for (var o = 0; o < bytes.length; o += chunk) {
        final end = math.min(o + chunk, bytes.length);
        for (final frame in ex.add(Uint8List.sublistView(bytes, o, end))) {
          if (frame[0] != 0x00 && frame[0] != 0x03) continue;
          // Decode every SBC frame in the payload (mirrors _decodeAndEmit).
          var off = 1;
          final samples = <int>[];
          while (off < frame.length) {
            final sync = frame[off];
            if (sync != 0x9c && sync != 0xad) break;
            final probed = dec.probe(Uint8List.sublistView(
                frame, off, math.min(off + SbcFrame.headerSize, frame.length)));
            if (probed == null) break;
            final size = probed.getFrameSize();
            if (size <= 0 || off + size > frame.length) break;
            final r =
                dec.decode(Uint8List.sublistView(frame, off, off + size));
            if (!r.success) break;
            samples.addAll(r.pcmLeft);
            off += size;
          }
          if (samples.isEmpty) continue;
          final f = Float64List(samples.length);
          for (var i = 0; i < samples.length; i++) {
            f[i] = samples[i] / 32768.0;
          }
          final f48 = up.process(f);
          if (f48.isNotEmpty) rx.addSamples(f48);
        }
      }
      // Flush resampler tail + trailing silence for burst end detection.
      rx.addSamples(up.flush());
      rx.addSamples(Float64List(ModemParams.symbolLen * 2));
      return got;
    }

    final payload =
        Uint8List.fromList(List.generate(400, (i) => (i * 13 + 5) & 0xff));

    test('HF 2.8 kHz QPSK r1/2 survives the SBC codec', () {
      final got = viaBtChain(
        width: ChannelWidth.hf,
        mod: SubcarrierModulation.qpsk,
        rate: LdpcRate.half,
        payload: payload,
      );
      expect(got, hasLength(1));
      expect(got.first.header.srcCall, 'W1AW');
      expect(got.first.payload, equals(payload));
    });

    test('narrow 12 kHz QPSK r1/2 survives the SBC codec', () {
      final got = viaBtChain(
        width: ChannelWidth.narrow,
        mod: SubcarrierModulation.qpsk,
        rate: LdpcRate.half,
        payload: payload,
      );
      expect(got, hasLength(1));
      expect(got.first.payload, equals(payload));
    });
  });
}
