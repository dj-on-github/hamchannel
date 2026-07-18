/// ModemService — owns the audio backend, transmitter, receiver and link
/// manager; exposes everything the UI needs as a ChangeNotifier.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../audio/audio_backend.dart';
import '../audio/real_audio.dart';
import '../dsp/modem_params.dart';
import '../proto/link.dart';
import '../proto/packets.dart';
import 'modem.dart';

class AppConfig {
  ChannelWidth width = ChannelWidth.narrow;
  SubcarrierModulation modulation = SubcarrierModulation.qpsk;
  LdpcRate ldpcRate = LdpcRate.half;
  String myCall = 'NOCALL';
  String remoteCall = 'CQ';
  double txLevel = 0.5;
  int leaderSymbols = 15; // VOX leader, 24 ms each
  int maxChunksPerBurst = 24;
  int ackTimeoutSec = 15;
  bool useLoopback = false;

  /// Audio device selection; null = system default.
  String? inputDeviceId;
  String inputDeviceLabel = '';
  String? outputDeviceName;

  /// Last directory used in a file open/save dialog; file browsers reopen
  /// here on the next use, including across app restarts.
  String? lastDir;

  /// FCC Logging (station log per FCC Part 97 recommendations).
  bool fccLogEnabled = false;
  String? fccLogPath;

  Map<String, Object?> toJson() => {
        'width': width.name,
        'modulation': modulation.name,
        'ldpcRate': ldpcRate.name,
        'myCall': myCall,
        'remoteCall': remoteCall,
        'txLevel': txLevel,
        'leaderSymbols': leaderSymbols,
        'maxChunksPerBurst': maxChunksPerBurst,
        'ackTimeoutSec': ackTimeoutSec,
        'useLoopback': useLoopback,
        'inputDeviceId': inputDeviceId,
        'inputDeviceLabel': inputDeviceLabel,
        'outputDeviceName': outputDeviceName,
        'lastDir': lastDir,
        'fccLogEnabled': fccLogEnabled,
        'fccLogPath': fccLogPath,
      };

  static AppConfig fromJson(Map<String, Object?> j) {
    final c = AppConfig();
    c.width = ChannelWidth.values
        .firstWhere((v) => v.name == j['width'], orElse: () => c.width);
    c.modulation = SubcarrierModulation.values.firstWhere(
        (v) => v.name == j['modulation'],
        orElse: () => c.modulation);
    c.ldpcRate = LdpcRate.values
        .firstWhere((v) => v.name == j['ldpcRate'], orElse: () => c.ldpcRate);
    c.myCall = (j['myCall'] as String?) ?? c.myCall;
    c.remoteCall = (j['remoteCall'] as String?) ?? c.remoteCall;
    c.txLevel = (j['txLevel'] as num?)?.toDouble() ?? c.txLevel;
    c.leaderSymbols = (j['leaderSymbols'] as num?)?.toInt() ?? c.leaderSymbols;
    c.maxChunksPerBurst =
        (j['maxChunksPerBurst'] as num?)?.toInt() ?? c.maxChunksPerBurst;
    c.ackTimeoutSec = (j['ackTimeoutSec'] as num?)?.toInt() ?? c.ackTimeoutSec;
    c.useLoopback = (j['useLoopback'] as bool?) ?? c.useLoopback;
    c.inputDeviceId = j['inputDeviceId'] as String?;
    c.inputDeviceLabel = (j['inputDeviceLabel'] as String?) ?? '';
    c.outputDeviceName = j['outputDeviceName'] as String?;
    c.lastDir = j['lastDir'] as String?;
    c.fccLogEnabled = (j['fccLogEnabled'] as bool?) ?? false;
    c.fccLogPath = j['fccLogPath'] as String?;
    return c;
  }
}

/// One FCC-log line: direction, UTC date and time, sender, recipient,
/// bandwidth, modulation format (OFDM-<subcarriers>), LDPC rate, content.
String formatFccLogLine({
  required bool tx,
  required DateTime whenUtc,
  required String from,
  required String to,
  required ChannelWidth width,
  required LdpcRate rate,
  required String content,
}) {
  String two(int v) => v.toString().padLeft(2, '0');
  final d = whenUtc;
  final bw = switch (width) {
    ChannelWidth.hf => '2.8kHz',
    ChannelWidth.narrow => '12kHz',
    ChannelWidth.wide => '24kHz',
  };
  final carriers = ModemParams(width: width).activeCarriers;
  return '${tx ? 'Tx' : 'Rx'} '
      '${d.year}-${two(d.month)}-${two(d.day)} '
      '${two(d.hour)}:${two(d.minute)}:${two(d.second)}Z '
      '$from $to $bw OFDM-$carriers LDPC-${rate.label} $content';
}

class ChatLine {
  ChatLine(this.from, this.text,
      {required this.outgoing, this.msgId, this.status = ''});
  final String from;
  final String text;
  final bool outgoing;
  final int? msgId;
  String status;
  final DateTime at = DateTime.now();
}

class TransferView {
  TransferView(this.ev);
  TransferEvent ev;
}

class ModemService extends ChangeNotifier {
  ModemService({
    required this.config,
    required AudioBackend Function(AppConfig) backendFactory,
    required Directory sharedDir,
    required Directory recvDir,
    this.onPersistConfig,
  })  : _backendFactory = backendFactory,
        store = FileStore(sharedDir: sharedDir, recvDir: recvDir);

  final AppConfig config;
  final AudioBackend Function(AppConfig) _backendFactory;
  final FileStore store;
  final void Function()? onPersistConfig;

  AudioBackend? _audio;
  ModemTransmitter? _tx;
  ModemReceiver? _rx;
  LinkManager? _link;
  StreamSubscription<Float64List>? _rxSub;
  StreamSubscription<LinkEvent>? _linkSub;

  bool running = false;
  bool transmitting = false;
  String statusLine = 'stopped';
  String lastError = '';
  final List<ChatLine> chat = [];
  final List<String> log = [];
  final Map<String, TransferEvent> transfers = {};
  String remoteListing = '';

  /// Signal-quality capture (Signal Quality tab). Off by default; when
  /// enabled, the receiver records the equalized payload constellation of
  /// each received burst.
  bool _sigQuality = false;
  bool get signalQualityEnabled => _sigQuality;
  set signalQualityEnabled(bool v) {
    _sigQuality = v;
    _rx?.captureConstellation = v;
    notifyListeners();
  }

  /// Constellation of the last received transmission (null until one is
  /// received with capture enabled).
  ConstellationSnapshot? lastConstellation;

  /// Available audio devices (filled by [refreshAudioDevices]).
  List<AudioDeviceInfo> inputDevices = [];
  List<AudioDeviceInfo> outputDevices = [];
  bool enumeratingDevices = false;

  Future<void> refreshAudioDevices() async {
    if (enumeratingDevices) return;
    enumeratingDevices = true;
    notifyListeners();
    try {
      final lists = await RealAudioBackend.enumerateDevices();
      inputDevices = lists.inputs;
      outputDevices = lists.outputs;
      if (RealAudioBackend.enumerationNote.isNotEmpty) {
        _addLog('audio devices: ${RealAudioBackend.enumerationNote}');
      }
    } catch (e) {
      _addLog('audio device enumeration failed: $e');
    } finally {
      enumeratingDevices = false;
      notifyListeners();
    }
  }
  /// True while the one-click audio self-test tone is playing.
  bool audioTesting = false;

  /// Play a short 1 kHz test tone through the selected output device so
  /// audio routing can be verified with one click. Uses the running
  /// backend when the modem is up; otherwise starts a temporary
  /// output-only backend with the current output selection.
  Future<void> audioSelfTest() async {
    if (audioTesting) return;
    audioTesting = true;
    notifyListeners();
    try {
      final tone = _buildTestTone();
      if (running && _audio != null) {
        if (config.useLoopback) {
          _addLog('loopback mode: the test tone is not sent to a speaker');
        } else {
          _addLog('playing test tone on the current output');
          await _audio!.playBurst(tone);
        }
      } else {
        if (config.useLoopback) {
          _addLog('loopback mode: the test tone is not sent to a speaker');
          return;
        }
        _addLog('playing test tone on the selected output');
        final backend =
            RealAudioBackend(outputDeviceName: config.outputDeviceName);
        try {
          await backend.start(capture: false);
          await backend.playBurst(tone);
          if (backend.lastError != null) {
            _addLog('audio: ${backend.lastError}');
          }
        } finally {
          await backend.stop();
        }
      }
    } catch (e) {
      _addLog('audio self-test failed: $e');
    } finally {
      audioTesting = false;
      notifyListeners();
    }
  }

  /// 0.75 s of 1 kHz sine at 50% amplitude with 10 ms raised-cosine
  /// edges (click-free), 48 kHz mono floats like the modem bursts.
  static Float64List _buildTestTone() {
    const sr = ModemParams.sampleRate;
    final n = sr * 3 ~/ 4;
    final ramp = sr ~/ 100;
    final out = Float64List(n);
    for (var i = 0; i < n; i++) {
      var env = 1.0;
      if (i < ramp) {
        env = 0.5 - 0.5 * cos(pi * i / ramp);
      } else if (i >= n - ramp) {
        env = 0.5 - 0.5 * cos(pi * (n - i) / ramp);
      }
      out[i] = 0.5 * env * sin(2 * pi * 1000 * i / sr);
    }
    return out;
  }

  double get rxLevel => _rx?.rxRms ?? 0;
  double get lastSnrDb => _rx?.lastSnrDb ?? 0;
  RxState get rxState => _rx?.state ?? RxState.searching;

  ModemParams get params => ModemParams(width: config.width);

  /// Net user data rate for the current configuration, bit/s.
  double get netBitRate =>
      params.netBitRate(config.modulation, config.ldpcRate);

  Future<void> start() async {
    if (running) return;
    lastError = '';
    try {
      final p = params;
      _audio = _backendFactory(config);
      _tx = ModemTransmitter(p)..leaderSymbols = config.leaderSymbols;
      _rx = ModemReceiver(p, onBurst: _onBurst, onStatus: _onRxStatus)
        ..captureConstellation = _sigQuality;
      _link = LinkManager(
        cfg: LinkConfig()
          ..myCall = config.myCall
          ..remoteCall = config.remoteCall
          ..maxChunksPerBurst = config.maxChunksPerBurst
          ..ackTimeoutMs = config.ackTimeoutSec * 1000,
        store: store,
        sendBurst: _sendBurst,
        blockUserBytes: () => ModemTransmitter.blockUserBytes(config.ldpcRate),
        channelBusy: () =>
            transmitting || (_rx?.state == RxState.collecting),
      );
      _linkSub = _link!.events.listen(_onLinkEvent);
      await _audio!.start();
      final audioBackend = _audio;
      if (audioBackend is RealAudioBackend &&
          audioBackend.lastError != null) {
        _addLog('audio: ${audioBackend.lastError}');
      }
      _rxSub = _audio!.rx.listen((chunk) {
        _rx?.addSamples(chunk);
        notifyListeners();
      });
      running = true;
      statusLine = 'listening (${p.width.name}, '
          '${config.modulation.label}, LDPC ${config.ldpcRate.label}, '
          '${(netBitRate / 1000).toStringAsFixed(1)} kbit/s)';
    } catch (e) {
      lastError = 'start failed: $e';
      _addLog(lastError);
      statusLine = 'error';
      await stop();
    }
    notifyListeners();
  }

  bool _disposed = false;

  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  /// Ask the UI to re-read derived state (e.g. after the shared folder
  /// changed on disk).
  void refresh() => notifyListeners();

  /// Directory to open file browsers in (last one used, if it still exists).
  String? get lastDir {
    final d = config.lastDir;
    if (d == null || d.isEmpty) return null;
    return Directory(d).existsSync() ? d : null;
  }

  /// Remember the directory containing [filePath] for future file dialogs
  /// and persist it with the rest of the configuration.
  void rememberDir(String filePath) {
    try {
      config.lastDir = File(filePath).parent.path;
      onPersistConfig?.call();
    } catch (_) {}
  }

  Future<void> stop() async {
    running = false;
    await _rxSub?.cancel();
    _rxSub = null;
    await _linkSub?.cancel();
    _linkSub = null;
    _link?.dispose();
    _link = null;
    try {
      await _audio?.stop();
    } catch (_) {}
    _audio = null;
    _tx = null;
    _rx = null;
    statusLine = 'stopped';
    notifyListeners();
  }

  /// Restart with (possibly) changed channel configuration.
  Future<void> applyConfig() async {
    onPersistConfig?.call();
    if (running) {
      await stop();
      await start();
    }
    notifyListeners();
  }

  // ------------------------------ FCC Logging -----------------------------
  //
  // When enabled, every transmission and reception is appended as one line
  // to the chosen log file (FCC Part 97 station-log recommendation).

  void setFccLogging({bool? enabled, String? path}) {
    if (enabled != null) config.fccLogEnabled = enabled;
    if (path != null) config.fccLogPath = path;
    onPersistConfig?.call();
    notifyListeners();
  }

  void _fccWrite({
    required bool tx,
    required String from,
    required String to,
    required LdpcRate rate,
    required String content,
  }) {
    if (!config.fccLogEnabled) return;
    final path = config.fccLogPath;
    if (path == null || path.isEmpty) return;
    try {
      final line = formatFccLogLine(
        tx: tx,
        whenUtc: DateTime.now().toUtc(),
        from: from,
        to: to,
        width: config.width,
        rate: rate,
        content: content,
      );
      File(path).writeAsStringSync('$line\n',
          mode: FileMode.append, flush: true);
    } catch (e) {
      _addLog('FCC log write failed: $e');
    }
  }

  /// Human-readable one-line summary of a burst payload's packets.
  static String summarizePayload(Uint8List payload) {
    String q(String s) =>
        '"${s.replaceAll('"', r'\"').replaceAll('\n', r'\n')}"';
    final parts = <String>[];
    var chunks = 0;
    for (final p in Pkt.parseAll(payload)) {
      switch (p.type) {
        case PktType.msg:
          final (_, text) = parseMsg(p);
          parts.add('MSG ${q(text)}');
        case PktType.msgAck:
          parts.add('MSG_ACK');
        case PktType.fileMeta:
          final m = FileMetaPkt.fromPkt(p);
          parts.add('FILE ${q(m.name)} (${m.size} B, ${m.chunkCount} chunks)');
        case PktType.fileData:
          chunks++;
        case PktType.fileNak:
          parts.add('NAK ${FileNak.parse(p).missing.length} missing');
        case PktType.fileDone:
          parts.add('FILE_DONE');
        case PktType.fileReq:
          final (_, name) = parseFileReq(p);
          parts.add('FILE_REQ ${q(name)}');
        case PktType.fileReqNak:
          parts.add('FILE_REQ_NAK');
        case PktType.listReq:
          parts.add('LIST_REQ');
        case PktType.listResp:
          parts.add('LIST_RESP');
        case PktType.beacon:
          parts.add('BEACON ${q(parseBeacon(p))}');
      }
    }
    if (chunks > 0) parts.add('FILE_DATA x$chunks');
    return parts.isEmpty ? '(no payload)' : parts.join('; ');
  }

  /// Summary for a received burst (parses runs of good blocks, notes
  /// losses).
  static String summarizeBlocks(List<Uint8List?> blocks, int blockErrors) {
    if (blocks.isEmpty) return '(header only)';
    final parts = <String>[];
    final run = BytesBuilder();
    void flush() {
      if (run.length == 0) return;
      final s = summarizePayload(run.takeBytes());
      if (s != '(no payload)') parts.add(s);
    }

    for (final b in blocks) {
      if (b == null) {
        flush();
      } else {
        run.add(b);
      }
    }
    flush();
    var out = parts.isEmpty ? '(no payload)' : parts.join('; ');
    if (blockErrors > 0) out += ' [$blockErrors block(s) lost]';
    return out;
  }

  // --------------------------- PCM file capture ---------------------------
  //
  // Offline-analysis support: transmitted bursts can be appended to a raw
  // PCM file (mono, 48 kHz, 64-bit IEEE 754 little-endian floats). Only
  // transmissions are written; nothing is appended while the transmitter
  // is idle. A PCM file can also be played back into the receiver as if it
  // had arrived from the audio interface.

  IOSink? _pcmSink;
  String pcmWritePath = '';
  bool get pcmWriting => _pcmSink != null;
  bool pcmReading = false;

  Future<void> startPcmWrite(String path) async {
    await stopPcmWrite();
    _pcmSink = File(path).openWrite();
    pcmWritePath = path;
    _addLog('writing TX audio to $path (f64le, 48 kHz mono)');
    notifyListeners();
  }

  Future<void> stopPcmWrite() async {
    final sink = _pcmSink;
    _pcmSink = null;
    if (sink != null) {
      await sink.flush();
      await sink.close();
      _addLog('closed PCM file $pcmWritePath');
    }
    pcmWritePath = '';
    notifyListeners();
  }

  void _pcmCapture(Float64List wave) {
    final sink = _pcmSink;
    if (sink == null) return;
    final bytes = Uint8List(wave.length * 8);
    final bd = ByteData.sublistView(bytes);
    for (var i = 0; i < wave.length; i++) {
      bd.setFloat64(i * 8, wave[i], Endian.little);
    }
    sink.add(bytes);
  }

  /// Read a raw f64le PCM file and feed it to the receiver exactly as if
  /// the samples had arrived from the audio interface.
  Future<void> readPcmFile(String path) async {
    final rx = _rx;
    if (rx == null) {
      lastError = 'start the modem before reading a PCM file';
      notifyListeners();
      return;
    }
    if (pcmReading) return;
    pcmReading = true;
    notifyListeners();
    try {
      final bytes = await File(path).readAsBytes();
      final n = bytes.length ~/ 8;
      final bd = ByteData.sublistView(bytes);
      _addLog('reading PCM file $path '
          '(${(n / ModemParams.sampleRate).toStringAsFixed(1)} s of audio)');
      const chunk = 4800; // 100 ms
      final buf = Float64List(chunk);
      var filled = 0;
      for (var i = 0; i < n; i++) {
        buf[filled++] = bd.getFloat64(i * 8, Endian.little);
        if (filled == chunk) {
          rx.addSamples(buf);
          filled = 0;
          // Yield so the UI and link timers keep running.
          await Future<void>.delayed(Duration.zero);
        }
      }
      if (filled > 0) {
        rx.addSamples(Float64List.sublistView(buf, 0, filled));
      }
      // Trailing silence flushes any burst that ends exactly at EOF.
      rx.addSamples(Float64List(ModemParams.symbolLen * 2));
      _addLog('finished PCM file $path');
    } catch (e) {
      lastError = 'PCM read failed: $e';
      _addLog(lastError);
    } finally {
      pcmReading = false;
      notifyListeners();
    }
  }

  // ------------------------------- TX path --------------------------------

  int _burstId = 1;

  Future<void> _sendBurst(
      int type, int flags, String dst, Uint8List payload) async {
    final tx = _tx;
    final audio = _audio;
    if (tx == null || audio == null) throw StateError('modem not running');
    final wave = tx.buildBurst(
      type: type,
      srcCall: config.myCall,
      dstCall: dst,
      burstId: _burstId++,
      mod: config.modulation,
      rate: config.ldpcRate,
      payload: payload,
      level: config.txLevel,
      flags: flags,
    );
    _pcmCapture(wave);
    transmitting = true;
    _rx?.muted = true;
    statusLine =
        'transmitting ${(wave.length / ModemParams.sampleRate).toStringAsFixed(1)} s burst to $dst';
    notifyListeners();
    try {
      await audio.playBurst(wave);
      _fccWrite(
        tx: true,
        from: config.myCall,
        to: dst,
        rate: config.ldpcRate,
        content: summarizePayload(payload),
      );
    } finally {
      transmitting = false;
      _rx?.muted = false;
      statusLine = 'listening';
      notifyListeners();
    }
  }

  // ------------------------------- RX path --------------------------------

  void _onBurst(ReceivedBurst b) {
    final cc = _rx?.lastConstellation;
    if (cc != null) lastConstellation = cc;
    _fccWrite(
      tx: false,
      from: b.header.srcCall,
      to: b.header.dstCall,
      rate: b.header.rate,
      content: summarizeBlocks(b.blocks, b.blockErrors),
    );
    _link?.onBurstReceived(b);
    notifyListeners();
  }

  void _onRxStatus(String s) {
    _addLog('rx: $s');
  }

  void _onLinkEvent(LinkEvent ev) {
    switch (ev) {
      case ChatEvent e:
        if (!e.outgoing) {
          chat.add(ChatLine(e.from, e.text, outgoing: false));
        }
      case MsgStatusEvent e:
        for (final c in chat) {
          if (c.msgId == e.msgId) c.status = e.status;
        }
      case TransferEvent e:
        transfers[e.key] = e;
      case FileListEvent e:
        remoteListing = e.listing;
        _addLog('file list from ${e.peer} received');
      case ReceivedFilesChangedEvent _:
        break;
      case LogEvent e:
        _addLog(e.line);
    }
    notifyListeners();
  }

  void _addLog(String s) {
    final t = DateTime.now();
    final ts =
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
    log.add('[$ts] $s');
    if (log.length > 500) log.removeRange(0, log.length - 500);
  }

  // ------------------------------ user actions ----------------------------

  void sendMessage(String text) {
    final link = _link;
    if (link == null) return;
    final id = link.sendMessage(text);
    chat.add(ChatLine(config.myCall, text,
        outgoing: true, msgId: id, status: 'queued'));
    notifyListeners();
  }

  void sendFile(String name, Uint8List bytes) {
    _link?.sendFile(name, bytes);
    notifyListeners();
  }

  void requestFile(String name) {
    _link?.requestFile(name);
    notifyListeners();
  }

  void requestListing() {
    _link?.requestListing();
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    stopPcmWrite();
    stop();
    super.dispose();
  }
}
