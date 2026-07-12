/// ModemService — owns the audio backend, transmitter, receiver and link
/// manager; exposes everything the UI needs as a ChangeNotifier.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../audio/audio_backend.dart';
import '../dsp/modem_params.dart';
import '../proto/link.dart';
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
    return c;
  }
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
      _rx = ModemReceiver(p, onBurst: _onBurst, onStatus: _onRxStatus);
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
    transmitting = true;
    _rx?.muted = true;
    statusLine =
        'transmitting ${(wave.length / ModemParams.sampleRate).toStringAsFixed(1)} s burst to $dst';
    notifyListeners();
    try {
      await audio.playBurst(wave);
    } finally {
      transmitting = false;
      _rx?.muted = false;
      statusLine = 'listening';
      notifyListeners();
    }
  }

  // ------------------------------- RX path --------------------------------

  void _onBurst(ReceivedBurst b) {
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
    stop();
    super.dispose();
  }
}
