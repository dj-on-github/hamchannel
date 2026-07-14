/// Burst modem: assembles complete OFDM bursts on transmit and recovers
/// them from a continuous audio sample stream on receive.
///
/// Burst layout (all units of one OFDM symbol = 1152 samples @ 48 kHz):
///
///   [ leader: L x sync symbol ][ chanest ][ header syms ][ payload syms ]
///
/// * leader     — repeated known symbol; doubles as VOX keying tone and
///                synchronisation preamble.
///   chanest    — known symbol for least-squares channel estimation.
///   header     — 32 info bytes, BPSK, short LDPC (512,256), tells the
///                receiver everything needed to demodulate the payload.
///   payload    — blockCount LDPC(2048) blocks at the configured
///                constellation / code rate. Each block's info part ends
///                with a CRC-32.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../dsp/constellation.dart';
import '../dsp/modem_params.dart';
import '../dsp/ofdm.dart';
import '../fec/crc.dart';
import '../fec/ldpc.dart';

// ---------------------------------------------------------------------------
// Header
// ---------------------------------------------------------------------------

class BurstHeader {
  BurstHeader({
    required this.type,
    required this.srcCall,
    required this.dstCall,
    required this.burstId,
    required this.mod,
    required this.rate,
    required this.blockCount,
    required this.payloadBytes,
    this.flags = 0,
  });

  static const int magic0 = 0x48, magic1 = 0x43; // 'H','C'
  static const int version = 2; // v2: PRBS scrambling of LDPC info bytes
  static const int packedLength = 32;

  final int type; // protocol frame type
  final String srcCall;
  final String dstCall;
  final int burstId;
  final SubcarrierModulation mod;
  final LdpcRate rate;
  final int blockCount;
  final int payloadBytes;
  final int flags;

  Uint8List pack() {
    final b = Uint8List(packedLength);
    final bd = ByteData.sublistView(b);
    b[0] = magic0;
    b[1] = magic1;
    b[2] = version;
    b[3] = type;
    _putCall(b, 4, srcCall);
    _putCall(b, 10, dstCall);
    bd.setUint16(16, burstId);
    b[18] = mod.index;
    b[19] = rate.index;
    bd.setUint16(20, blockCount);
    bd.setUint32(22, payloadBytes);
    b[26] = flags;
    bd.setUint16(30, crc16(b, 0, 30));
    return b;
  }

  static BurstHeader? unpack(Uint8List b) {
    if (b.length < packedLength) return null;
    if (b[0] != magic0 || b[1] != magic1 || b[2] != version) return null;
    final bd = ByteData.sublistView(b);
    if (bd.getUint16(30) != crc16(b, 0, 30)) return null;
    if (b[18] >= SubcarrierModulation.values.length ||
        b[19] >= LdpcRate.values.length) {
      return null;
    }
    return BurstHeader(
      type: b[3],
      srcCall: _getCall(b, 4),
      dstCall: _getCall(b, 10),
      burstId: bd.getUint16(16),
      mod: SubcarrierModulation.values[b[18]],
      rate: LdpcRate.values[b[19]],
      blockCount: bd.getUint16(20),
      payloadBytes: bd.getUint32(22),
      flags: b[26],
    );
  }

  static void _putCall(Uint8List b, int off, String call) {
    final s = call.toUpperCase().padRight(6).codeUnits;
    for (var i = 0; i < 6; i++) {
      b[off + i] = s[i] & 0x7F;
    }
  }

  static String _getCall(Uint8List b, int off) =>
      String.fromCharCodes(b.sublist(off, off + 6)).trim();

  @override
  String toString() =>
      'BurstHeader(type:$type $srcCall->$dstCall id:$burstId '
      '${mod.label} r${rate.label} blocks:$blockCount bytes:$payloadBytes)';
}

// ---------------------------------------------------------------------------
// Scrambler
// ---------------------------------------------------------------------------

/// Deterministic PRBS scrambler.
///
/// The transmitter XORs each LDPC block's info bytes (user data + CRC, and
/// the packed header likewise) with a PRBS *before* encoding; the receiver
/// XORs with the same sequence *after* decoding. This whitens the
/// systematic bits so the transmitted symbol distribution is random even
/// for repetitive payloads (zero padding, long runs), keeping the spectrum
/// flat and the constellation exercised.
///
/// The sequence is derived from [DetRng] and the block's position: payload
/// blocks use their index within the burst as [tag]; the header uses
/// [headerTag]. XOR twice with the same tag is the identity.
class Scrambler {
  static const int _seedBase = 0x5C7AB1E5;

  /// Tag used for the burst header block.
  static const int headerTag = 0x10000;

  static void apply(Uint8List data, int tag) {
    final rng = DetRng(_seedBase ^ (tag + 1) * 2654435761);
    for (var i = 0; i < data.length; i++) {
      data[i] ^= rng.nextInt(256);
    }
  }
}

// ---------------------------------------------------------------------------
// Interleaver
// ---------------------------------------------------------------------------

class Interleaver {
  Interleaver(this.n) {
    perm = Uint32List(n);
    for (var i = 0; i < n; i++) {
      perm[i] = i;
    }
    final rng = DetRng(0x1EAF0000 ^ n);
    for (var i = n - 1; i > 0; i--) {
      final j = rng.nextInt(i + 1);
      final t = perm[i];
      perm[i] = perm[j];
      perm[j] = t;
    }
  }

  final int n;
  late final Uint32List perm;

  Uint8List interleaveBits(Uint8List bits) {
    final out = Uint8List(n);
    for (var i = 0; i < n; i++) {
      out[perm[i]] = bits[i];
    }
    return out;
  }

  Float64List deinterleaveLlr(Float64List llr) {
    final out = Float64List(n);
    for (var i = 0; i < n; i++) {
      out[i] = llr[perm[i]];
    }
    return out;
  }
}

// ---------------------------------------------------------------------------
// Transmitter
// ---------------------------------------------------------------------------

class ModemTransmitter {
  ModemTransmitter(this.p)
      : wf = OfdmWaveforms(p),
        _hdrCode = LdpcCode.header(),
        _hdrIl = Interleaver(LdpcCode.header().n),
        _payIl = Interleaver(2048);

  final ModemParams p;
  final OfdmWaveforms wf;
  final LdpcCode _hdrCode;
  final Interleaver _hdrIl;
  final Interleaver _payIl;

  /// Number of leader (sync) symbols; >= 4. Longer leaders give VOX more
  /// time to key the transmitter.
  int leaderSymbols = 15;

  /// Extra silence appended after the burst (samples).
  int tailSamples = 4800; // 100 ms

  /// User bytes that fit in one LDPC payload block (after 4-byte CRC).
  static int blockUserBytes(LdpcRate rate) =>
      LdpcCode.payload(rate).infoBytes - 4;

  /// Build the complete audio waveform for one burst.
  ///
  /// [payload] is split into LDPC blocks of [blockUserBytes] each; the last
  /// block is zero padded. Header [payloadBytes] preserves the exact length.
  Float64List buildBurst({
    required int type,
    required String srcCall,
    required String dstCall,
    required int burstId,
    required SubcarrierModulation mod,
    required LdpcRate rate,
    required Uint8List payload,
    double level = 0.7,
    int flags = 0,
  }) {
    final code = LdpcCode.payload(rate);
    final userPerBlock = code.infoBytes - 4;
    final blockCount =
        payload.isEmpty ? 0 : (payload.length + userPerBlock - 1) ~/ userPerBlock;

    final header = BurstHeader(
      type: type,
      srcCall: srcCall,
      dstCall: dstCall,
      burstId: burstId,
      mod: mod,
      rate: rate,
      blockCount: blockCount,
      payloadBytes: payload.length,
      flags: flags,
    );

    // ---- header coded bits (BPSK) ----
    final hdrInfo = Uint8List(_hdrCode.infoBytes)..setRange(0, 32, header.pack());
    Scrambler.apply(hdrInfo, Scrambler.headerTag);
    final hdrBits = _hdrIl.interleaveBits(_hdrCode.encode(hdrInfo));

    // ---- payload coded bits ----
    final payBits = Uint8List(blockCount * code.n);
    for (var blk = 0; blk < blockCount; blk++) {
      final info = Uint8List(code.infoBytes);
      final off = blk * userPerBlock;
      final take = math.min(userPerBlock, payload.length - off);
      if (take > 0) info.setRange(0, take, payload, off);
      final c = crc32(info, 0, code.infoBytes - 4);
      ByteData.sublistView(info).setUint32(code.infoBytes - 4, c);
      Scrambler.apply(info, blk);
      payBits.setRange(
          blk * code.n, (blk + 1) * code.n, _payIl.interleaveBits(code.encode(info)));
    }

    // ---- map bits onto OFDM symbols ----
    final bpsHdr = p.dataCarriers; // BPSK
    final hdrSyms = (hdrBits.length + bpsHdr - 1) ~/ bpsHdr;
    final bpsPay = p.bitsPerOfdmSymbol(mod);
    final paySyms = blockCount == 0 ? 0 : (payBits.length + bpsPay - 1) ~/ bpsPay;

    final totalSyms = leaderSymbols + 1 + hdrSyms + paySyms + 1; // +postamble
    final out = Float64List(totalSyms * ModemParams.symbolLen + tailSamples);
    var o = 0;
    for (var i = 0; i < leaderSymbols; i++) {
      out.setRange(o, o + ModemParams.symbolLen, wf.syncSymbol);
      o += ModemParams.symbolLen;
    }
    out.setRange(o, o + ModemParams.symbolLen, wf.chanestSymbol);
    o += ModemParams.symbolLen;

    final fill = DetRng(0xF111 ^ burstId);
    final bpskC = Constellation(SubcarrierModulation.bpsk);
    final dataRe = Float64List(p.dataCarriers);
    final dataIm = Float64List(p.dataCarriers);
    var symIdx = 0;

    void emitSymbol(Constellation c, Uint8List bits, int bitOff, int nBits) {
      final bps = c.bitsPerSymbol;
      final nPts = p.dataCarriers;
      final padded = Uint8List(nPts * bps);
      for (var i = 0; i < nPts * bps; i++) {
        padded[i] = (bitOff + i < bitOff + nBits && bitOff + i < bits.length)
            ? bits[bitOff + i]
            : fill.nextBit();
      }
      c.map(padded, 0, nPts, dataRe, dataIm, 0);
      final s = wf.modulateSymbol(dataRe, dataIm, symIdx);
      out.setRange(o, o + ModemParams.symbolLen, s);
      o += ModemParams.symbolLen;
      symIdx++;
    }

    for (var i = 0; i < hdrSyms; i++) {
      emitSymbol(bpskC, hdrBits, i * bpsHdr, bpsHdr);
    }
    final payC = Constellation(mod);
    for (var i = 0; i < paySyms; i++) {
      emitSymbol(payC, payBits, i * bpsPay, bpsPay);
    }
    // Postamble: one filler symbol so the closing amplitude ramp never
    // touches payload-bearing samples.
    emitSymbol(bpskC, Uint8List(0), 0, 0);

    // ---- ramps + normalisation ----
    const ramp = 240; // 5 ms
    final burstLen = totalSyms * ModemParams.symbolLen;
    for (var i = 0; i < ramp; i++) {
      final g = 0.5 * (1 - math.cos(math.pi * i / ramp));
      out[i] *= g;
      out[burstLen - 1 - i] *= g;
    }
    var peak = 1e-9;
    for (var i = 0; i < burstLen; i++) {
      final a = out[i].abs();
      if (a > peak) peak = a;
    }
    final g = 0.95 * level.clamp(0.0, 1.0) / peak;
    for (var i = 0; i < burstLen; i++) {
      out[i] *= g;
    }
    return out;
  }

  /// Duration in seconds of the burst that [buildBurst] would produce.
  double burstSeconds(
      SubcarrierModulation mod, LdpcRate rate, int payloadLen) {
    final code = LdpcCode.payload(rate);
    final userPerBlock = code.infoBytes - 4;
    final blocks =
        payloadLen == 0 ? 0 : (payloadLen + userPerBlock - 1) ~/ userPerBlock;
    final hdrSyms = (_hdrCode.n + p.dataCarriers - 1) ~/ p.dataCarriers;
    final paySyms = blocks == 0
        ? 0
        : (blocks * code.n + p.bitsPerOfdmSymbol(mod) - 1) ~/
            p.bitsPerOfdmSymbol(mod);
    final samples = (leaderSymbols + 1 + hdrSyms + paySyms + 1) *
            ModemParams.symbolLen +
        tailSamples;
    return samples / ModemParams.sampleRate;
  }
}

// ---------------------------------------------------------------------------
// Receiver
// ---------------------------------------------------------------------------

class ReceivedBurst {
  ReceivedBurst({
    required this.header,
    required this.blocks,
    required this.snrDb,
    required this.blockErrors,
    this.startSample = 0,
  });

  final BurstHeader header;

  /// Absolute sample index (in the receiver's input stream) of the burst's
  /// channel-estimation symbol.
  final int startSample;

  /// Per-block user data (CRC-verified); null where decode failed.
  final List<Uint8List?> blocks;
  final double snrDb;
  final int blockErrors;

  /// Concatenated payload of the good blocks, trimmed to header length,
  /// only meaningful when every block decoded.
  Uint8List? get payload {
    if (blocks.any((b) => b == null)) return null;
    final all = BytesBuilder();
    for (final b in blocks) {
      all.add(b!);
    }
    final v = all.takeBytes();
    return Uint8List.sublistView(v, 0, math.min(header.payloadBytes, v.length));
  }
}

/// Equalized payload symbols and error-vector statistics captured from one
/// received burst, for the Signal Quality display.
class ConstellationSnapshot {
  ConstellationSnapshot({
    required this.xy,
    required this.mod,
    required this.snrDb,
    required this.evmRmsPct,
    required this.evmMaxPct,
    required this.evmStdPct,
    required this.totalPoints,
    required this.srcCall,
    required this.fecCorrectedBits,
    required this.fecCodedBits,
    required this.blocksOk,
    required this.blocksCrcFailed,
    required this.blocksUncorrectable,
  }) : at = DateTime.now();

  /// Interleaved (I, Q) pairs of the plotted points (capped subset).
  final Float32List xy;
  final SubcarrierModulation mod;
  final double snrDb;

  /// EVM in percent of the RMS constellation power (which is 1).
  final double evmRmsPct;
  final double evmMaxPct;
  final double evmStdPct;

  /// Total measured points (may exceed the plotted subset).
  final int totalPoints;
  final String srcCall;
  final DateTime at;

  /// Raw channel bit errors corrected by the LDPC decoder, over the coded
  /// bits of the successfully decoded payload blocks.
  final int fecCorrectedBits;
  final int fecCodedBits;

  /// Pre-FEC channel bit-error rate (over successfully decoded blocks).
  double get ber => fecCodedBits == 0 ? 0 : fecCorrectedBits / fecCodedBits;

  /// Per-block CRC outcome counts for the burst.
  final int blocksOk;
  final int blocksCrcFailed; // LDPC converged but CRC-32 mismatched
  final int blocksUncorrectable; // LDPC failed to converge

  bool get allBlocksOk => blocksCrcFailed == 0 && blocksUncorrectable == 0;
}

enum RxState { searching, leader, collecting }

class ModemReceiver {
  ModemReceiver(this.p, {required this.onBurst, this.onStatus})
      : wf = OfdmWaveforms(p),
        _hdrCode = LdpcCode.header(),
        _hdrIl = Interleaver(LdpcCode.header().n),
        _payIl = Interleaver(2048) {
    _tmpl = wf.syncSymbol;
    _tmplE = wf.syncEnergy;
    _chTmpl = wf.chanestSymbol;
    var e = 0.0;
    for (final v in _chTmpl) {
      e += v * v;
    }
    _chTmplE = e;
  }

  final ModemParams p;
  final OfdmWaveforms wf;
  final void Function(ReceivedBurst) onBurst;
  final void Function(String)? onStatus;

  final LdpcCode _hdrCode;
  final Interleaver _hdrIl;
  final Interleaver _payIl;

  late final Float64List _tmpl;
  late final double _tmplE;
  late final Float64List _chTmpl;
  late final double _chTmplE;

  static const int _symLen = ModemParams.symbolLen;
  // Stride 5 is coprime with the symbol length (1152), so the scan grid's
  // offset relative to the correlation peak rotates across leader repeats —
  // some repeat always lands within one sample of the peak.
  static const int _coarseStride = 5;
  static const double _coarseThresh = 0.30;
  static const double _fineThresh = 0.40;

  // --- sample buffer (absolute indexing) ---
  Float64List _buf = Float64List(1 << 18);
  int _bufLen = 0;
  int _bufStartAbs = 0; // absolute index of _buf[0]
  int _absIn = 0; // total samples ever written

  // --- search state ---
  RxState state = RxState.searching;
  int _scanAbs = 0;
  int _t0 = -1; // abs start of a confirmed sync symbol
  int _syncProbe = 0;
  int _misses = 0;

  // --- burst collection state ---
  BurstHeader? _hdr;
  int _chanestAbs = -1;
  int _symCursor = 0; // symbol index being collected (0=chanest)
  late Float64List _hRe, _hIm; // channel estimate per active carrier
  double _noiseVar = 1e-3;
  double _meanH2 = 1.0;
  double _slipAcc = 0;
  int _slip = 0;
  Float64List _hdrLlr = Float64List(0);
  int _hdrBitsGot = 0;
  Float64List _payLlr = Float64List(0);
  int _payBitsGot = 0;
  List<Uint8List?> _blocks = [];
  int _blockErrors = 0;
  double _snrAcc = 0;
  int _snrN = 0;

  /// UI meter: recent RMS input level (0..1-ish).
  double rxRms = 0;
  double lastSnrDb = 0;

  /// Signal-quality capture (off by default: zero cost when disabled).
  bool captureConstellation = false;
  ConstellationSnapshot? lastConstellation;
  static const int _ccMaxPlotted = 12000;
  final List<double> _ccXY = [];
  int _ccCount = 0;
  double _ccSum = 0, _ccSum2 = 0, _ccMax = 0;

  // Per-burst FEC / CRC statistics (always collected — cheap).
  int _fecCorrected = 0;
  int _fecCoded = 0;
  int _blkOk = 0;
  int _blkCrcFail = 0;
  int _blkUncorrectable = 0;

  /// When true, incoming samples are discarded (used while transmitting).
  bool muted = false;

  int get absPosition => _absIn;

  void addSamples(Float64List chunk) {
    if (muted) {
      // Discard input and drop the buffer so absolute indexing stays
      // contiguous when reception resumes.
      _absIn += chunk.length;
      _bufLen = 0;
      _bufStartAbs = _absIn;
      _resetSearch(_absIn);
      return;
    }
    _append(chunk);
    var r = 0.0;
    for (final v in chunk) {
      r += v * v;
    }
    if (chunk.isNotEmpty) {
      rxRms = 0.8 * rxRms + 0.2 * math.sqrt(r / chunk.length);
    }
    var progress = true;
    while (progress) {
      progress = switch (state) {
        RxState.searching => _search(),
        RxState.leader => _trackLeader(),
        RxState.collecting => _collect(),
      };
    }
    _compact();
  }

  void _append(Float64List c) {
    if (_bufLen + c.length > _buf.length) {
      var cap = _buf.length;
      while (cap < _bufLen + c.length) {
        cap <<= 1;
      }
      final nb = Float64List(cap);
      nb.setRange(0, _bufLen, _buf);
      _buf = nb;
    }
    _buf.setRange(_bufLen, _bufLen + c.length, c);
    _bufLen += c.length;
    _absIn += c.length;
  }

  void _compact() {
    // Keep everything the current state might still need.
    final keepFrom = switch (state) {
      RxState.searching => _scanAbs - _symLen,
      RxState.leader => _t0,
      RxState.collecting =>
        _chanestAbs + _symCursor * _symLen + _slip - 2 * _symLen,
    };
    final cut = (keepFrom - _bufStartAbs).clamp(0, _bufLen);
    if (cut > 1 << 15) {
      _buf.setRange(0, _bufLen - cut, _buf, cut);
      _bufLen -= cut;
      _bufStartAbs += cut;
    }
    // Hard cap so a stuck state can't hoard memory.
    if (_bufLen > (1 << 21)) {
      _resetSearch(_absIn);
    }
  }

  void _resetSearch(int fromAbs) {
    state = RxState.searching;
    _scanAbs = math.max(fromAbs, _bufStartAbs);
    _t0 = -1;
    _hdr = null;
  }

  double _sample(int abs) => _buf[abs - _bufStartAbs];

  bool _have(int absEnd) => absEnd <= _bufStartAbs + _bufLen;

  /// Normalized cross-correlation of the buffer at absolute position [absPos]
  /// against [tmpl] with given [stride].
  double _ncc(int absPos, Float64List tmpl, double tmplE, int stride) {
    var c = 0.0, e = 0.0;
    for (var i = 0; i < tmpl.length; i += stride) {
      final x = _sample(absPos + i);
      c += x * tmpl[i];
      e += x * x;
    }
    // tmplE is full-rate energy; the strided template energy is ~tmplE/stride.
    final te = tmplE / stride;
    return c / (math.sqrt(e * te) + 1e-12);
  }

  bool _search() {
    while (_have(_scanAbs + _symLen + _coarseStride)) {
      final v = _ncc(_scanAbs, _tmpl, _tmplE, _coarseStride);
      if (v > _coarseThresh) {
        // Fine search around the coarse hit.
        if (!_have(_scanAbs + _symLen + 16)) return false;
        var best = -1.0;
        var bestAt = _scanAbs;
        for (var d = -12; d <= 12; d++) {
          final at = _scanAbs + d;
          if (at < _bufStartAbs || !_have(at + _symLen)) continue;
          final f = _ncc(at, _tmpl, _tmplE, 1);
          if (f > best) {
            best = f;
            bestAt = at;
          }
        }
        if (best > _fineThresh) {
          _t0 = bestAt;
          _syncProbe = 1;
          _misses = 0;
          state = RxState.leader;
          return true;
        }
      }
      _scanAbs += _coarseStride;
    }
    return false;
  }

  bool _trackLeader() {
    while (true) {
      final at = _t0 + _syncProbe * _symLen;
      if (!_have(at + _symLen + 12)) return false;
      // Micro-adjust for drift. The correlation main lobe is ~1 sample
      // wide, so the chanest template must be searched over its own window
      // (not evaluated at the sync template's argmax).
      var best = -1.0;
      var bestAt = at;
      var chBest = -1.0;
      var chAt = at;
      for (var d = -2; d <= 2; d++) {
        final f = _ncc(at + d, _tmpl, _tmplE, 1);
        if (f > best) {
          best = f;
          bestAt = at + d;
        }
        final g = _ncc(at + d, _chTmpl, _chTmplE, 1);
        if (g > chBest) {
          chBest = g;
          chAt = at + d;
        }
      }
      if (chBest > best && chBest > 0.30) {
        // Found the channel-estimation symbol.
        _beginCollect(chAt);
        return true;
      }
      if (best > 0.30) {
        _t0 = bestAt - _syncProbe * _symLen; // re-anchor
        _syncProbe++;
        _misses = 0;
        if (_syncProbe > 64) {
          _resetSearch(bestAt + _symLen);
          return true;
        }
        continue;
      }
      _misses++;
      if (_misses >= 2) {
        _resetSearch(_t0 + _symLen);
        return true;
      }
      _syncProbe++;
    }
  }

  void _beginCollect(int chanestAbs) {
    _chanestAbs = chanestAbs;
    _symCursor = 0;
    _hdr = null;
    _slipAcc = 0;
    _slip = 0;
    _hdrBitsGot = 0;
    _hdrLlr = Float64List(_hdrCode.n);
    _payBitsGot = 0;
    _blocks = [];
    _blocksDecoded = 0;
    _blockErrors = 0;
    _snrAcc = 0;
    _snrN = 0;
    _ccXY.clear();
    _ccCount = 0;
    _ccSum = 0;
    _ccSum2 = 0;
    _ccMax = 0;
    _fecCorrected = 0;
    _fecCoded = 0;
    _blkOk = 0;
    _blkCrcFail = 0;
    _blkUncorrectable = 0;
    state = RxState.collecting;
    onStatus?.call('sync');
  }

  static const int _winBackoff = 32;

  bool _collect() {
    final hdrSyms = (_hdrCode.n + p.dataCarriers - 1) ~/ p.dataCarriers;
    while (true) {
      final symStart = _chanestAbs + _symCursor * _symLen + _slip;
      if (!_have(symStart + _symLen)) return false;
      final winStart = symStart + ModemParams.cpLen - _winBackoff;
      final nA = p.activeCarriers;
      final yRe = Float64List(nA), yIm = Float64List(nA);
      _demodAt(winStart, yRe, yIm);

      if (_symCursor == 0) {
        _estimateChannel(yRe, yIm);
      } else if (_symCursor <= hdrSyms) {
        _processDataSymbol(
            yRe, yIm, SubcarrierModulation.bpsk, _hdrLlr, _hdrBitsGot);
        _hdrBitsGot =
            math.min(_hdrBitsGot + p.dataCarriers, _hdrCode.n);
        if (_symCursor == hdrSyms) {
          if (!_finishHeader()) {
            _resetSearch(_chanestAbs + _symLen);
            return true;
          }
          if (_hdr!.blockCount == 0) {
            _emitBurst();
            _resetSearch(symStart + _symLen);
            return true;
          }
        }
      } else {
        final h = _hdr!;
        final code = LdpcCode.payload(h.rate);
        final totalBits = h.blockCount * code.n;
        final bps = p.bitsPerOfdmSymbol(h.mod);
        _processDataSymbol(yRe, yIm, h.mod, _payLlr, _payBitsGot,
            capture: captureConstellation);
        _payBitsGot = math.min(_payBitsGot + bps, totalBits);
        _decodeReadyBlocks(code);
        if (_payBitsGot >= totalBits) {
          _emitBurst();
          _resetSearch(symStart + _symLen);
          return true;
        }
      }
      _symCursor++;
      // Safety: bail out of absurdly long collections. (The HF profile
      // carries few bits per symbol, so legitimate bursts can be long.)
      if (_symCursor > 12000) {
        _resetSearch(_chanestAbs + _symLen);
        return true;
      }
    }
  }

  void _demodAt(int absWinStart, Float64List outRe, Float64List outIm) {
    final n = ModemParams.fftSize;
    final re = Float64List(n), im = Float64List(n);
    for (var i = 0; i < n; i++) {
      re[i] = _sample(absWinStart + i);
    }
    wf.fft.forward(re, im);
    final bins = p.activeBins;
    for (var i = 0; i < bins.length; i++) {
      outRe[i] = re[bins[i]];
      outIm[i] = im[bins[i]];
    }
  }

  void _estimateChannel(Float64List yRe, Float64List yIm) {
    final (xRe, xIm) = wf.knownFreq(wf.chanestBits);
    final nA = p.activeCarriers;
    final rawRe = Float64List(nA);
    final rawIm = Float64List(nA);
    for (var i = 0; i < nA; i++) {
      // H = Y * conj(X) / |X|^2 ; |X| = 1.
      rawRe[i] = yRe[i] * xRe[i] + yIm[i] * xIm[i];
      rawIm[i] = yIm[i] * xRe[i] - yRe[i] * xIm[i];
    }
    // Smooth across frequency: the acoustic channel's impulse response is
    // much shorter than the CP, so H varies slowly on the scale of a few
    // bins; a 5-tap average cuts estimation noise by ~7 dB.
    _hRe = Float64List(nA);
    _hIm = Float64List(nA);
    var h2 = 0.0;
    for (var i = 0; i < nA; i++) {
      final lo = i - 2 < 0 ? 0 : i - 2;
      final hi = i + 3 > nA ? nA : i + 3;
      var sr = 0.0, si = 0.0;
      for (var j = lo; j < hi; j++) {
        sr += rawRe[j];
        si += rawIm[j];
      }
      _hRe[i] = sr / (hi - lo);
      _hIm[i] = si / (hi - lo);
      h2 += _hRe[i] * _hRe[i] + _hIm[i] * _hIm[i];
    }
    _meanH2 = h2 / nA;
    // Noise variance lives in the *equalized* (unit-signal) domain; start
    // optimistic and let the per-symbol pilot EMA converge.
    _noiseVar = 1e-3;
  }

  /// Equalize one symbol, run pilot phase tracking, produce LLRs into
  /// [llrOut] starting at bit offset [bitsSoFar].
  void _processDataSymbol(Float64List yRe, Float64List yIm,
      SubcarrierModulation mod, Float64List llrOut, int bitsSoFar,
      {bool capture = false}) {
    final nA = p.activeCarriers;
    final pilotIdx = p.pilotIdx;
    final dataIdx = p.dataIdx;
    final symIdx = _symCursor - 1; // matches TX symIdx counter

    // --- pilot phase fit: residual rotation vs current H ---
    // z_k = (Y_k / H_k) * pilot_k  (pilot is +-1)
    final zr = Float64List(pilotIdx.length);
    final zi = Float64List(pilotIdx.length);
    for (var j = 0; j < pilotIdx.length; j++) {
      final i = pilotIdx[j];
      final hr = _hRe[i], hi = _hIm[i];
      final h2 = hr * hr + hi * hi + 1e-15;
      var er = (yRe[i] * hr + yIm[i] * hi) / h2;
      var ei = (yIm[i] * hr - yRe[i] * hi) / h2;
      final pv = wf.pilotValue(symIdx, i);
      zr[j] = er * pv;
      zi[j] = ei * pv;
    }
    // Stage 1: coarse slope (wrap-free) via adjacent-pilot
    // delay-and-multiply.
    var sr = 0.0, si = 0.0;
    for (var j = 0; j + 1 < pilotIdx.length; j++) {
      sr += zr[j + 1] * zr[j] + zi[j + 1] * zi[j];
      si += zi[j + 1] * zr[j] - zr[j + 1] * zi[j];
    }
    var slopePerCarrier =
        math.atan2(si, sr + 1e-15) / ModemParams.pilotSpacing;
    // Common phase after removing the coarse slope.
    var cr = 0.0, ci = 0.0;
    for (var j = 0; j < pilotIdx.length; j++) {
      final a = -slopePerCarrier * pilotIdx[j];
      final wr = math.cos(a), wi = math.sin(a);
      cr += zr[j] * wr - zi[j] * wi;
      ci += zr[j] * wi + zi[j] * wr;
    }
    var theta = math.atan2(ci, cr + 1e-15);

    // Stage 2: least-squares refinement on the residual angles. The coarse
    // estimator's noise scales with carrier index and would dominate the
    // symbol EVM; the LS fit on the (small, independent) residuals removes
    // that.
    var kSum = 0.0;
    for (final k in pilotIdx) {
      kSum += k;
    }
    final kBar = kSum / pilotIdx.length;
    var lsNum = 0.0, lsDen = 0.0, residSum = 0.0;
    final resid = Float64List(pilotIdx.length);
    for (var j = 0; j < pilotIdx.length; j++) {
      final a = theta + slopePerCarrier * pilotIdx[j];
      final wr = math.cos(a), wi = math.sin(a);
      final er = zr[j] * wr + zi[j] * wi;
      final ei = zi[j] * wr - zr[j] * wi;
      resid[j] = math.atan2(ei, er + 1e-15);
      residSum += resid[j];
      final dk = pilotIdx[j] - kBar;
      lsNum += dk * resid[j];
      lsDen += dk * dk;
    }
    final dSlope = lsDen > 0 ? lsNum / lsDen : 0.0;
    slopePerCarrier += dSlope;
    theta += residSum / pilotIdx.length - dSlope * kBar;

    // Fold (theta, slope) into H so the correction persists.
    for (var i = 0; i < nA; i++) {
      final a = theta + slopePerCarrier * i;
      final wr = math.cos(a), wi = math.sin(a);
      final hr = _hRe[i] * wr - _hIm[i] * wi;
      final hi = _hRe[i] * wi + _hIm[i] * wr;
      _hRe[i] = hr;
      _hIm[i] = hi;
    }

    // --- noise estimate from corrected pilots ---
    var nv = 0.0;
    for (var j = 0; j < pilotIdx.length; j++) {
      final a = theta + slopePerCarrier * pilotIdx[j];
      final wr = math.cos(a), wi = math.sin(a);
      // corrected z = z * e^{-ja}
      final er = zr[j] * wr + zi[j] * wi;
      final ei = zi[j] * wr - zr[j] * wi;
      final dr = er - 1.0;
      nv += dr * dr + ei * ei;
    }
    nv = math.max(nv / pilotIdx.length, 1e-9);
    _noiseVar = 0.7 * _noiseVar.clamp(1e-9, 1e9) + 0.3 * nv;
    final snr = 1.0 / _noiseVar;
    _snrAcc += 10 * math.log(snr) / math.ln10;
    _snrN++;
    lastSnrDb = _snrAcc / _snrN;

    // --- equalize data carriers & LLRs ---
    // This must happen BEFORE any slip rotation of H: the slip compensation
    // belongs to the *next* symbol's shifted window, not this one.
    final c = Constellation(mod);
    final bps = c.bitsPerSymbol;
    final tmp = Float64List(bps);
    for (var j = 0; j < dataIdx.length; j++) {
      final i = dataIdx[j];
      final hr = _hRe[i], hi = _hIm[i];
      final h2 = hr * hr + hi * hi + 1e-15;
      final er = (yRe[i] * hr + yIm[i] * hi) / h2;
      final ei = (yIm[i] * hr - yRe[i] * hi) / h2;
      if (capture) {
        final (pr, pi) = c.nearestPoint(er, ei);
        final dr = er - pr, di = ei - pi;
        final e = math.sqrt(dr * dr + di * di);
        _ccCount++;
        _ccSum += e;
        _ccSum2 += e * e;
        if (e > _ccMax) _ccMax = e;
        if (_ccXY.length < 2 * _ccMaxPlotted) {
          _ccXY.add(er);
          _ccXY.add(ei);
        }
      }
      // Per-carrier noise after equalization.
      final nvk = _noiseVar * _meanH2 / math.max(h2, _meanH2 * 1e-3);
      final bit0 = bitsSoFar + j * bps;
      if (bit0 + bps > llrOut.length) {
        // Last symbol may carry filler bits beyond the coded stream.
        if (bit0 >= llrOut.length) break;
        c.llr(er, ei, nvk, tmp, 0);
        for (var b = 0; b < bps && bit0 + b < llrOut.length; b++) {
          llrOut[bit0 + b] = tmp[b];
        }
      } else {
        c.llr(er, ei, nvk, llrOut, bit0);
      }
    }

    // --- timing slip tracking (applies from the next symbol onward) ---
    // slope (rad/carrier) corresponds to a window delay of
    // slope * N / (2*pi) samples per symbol; accumulate and correct.
    _slipAcc += slopePerCarrier * ModemParams.fftSize / (2 * math.pi);
    if (_slipAcc.abs() >= 1.5) {
      final s = _slipAcc.round();
      _slip -= s;
      _slipAcc -= s;
      // Shifting the window by -s samples multiplies each bin k by
      // e^{-j 2 pi k s / N} relative to before; pre-compensate in H.
      for (var i = 0; i < nA; i++) {
        final k = p.firstBin + i;
        final a = -2 * math.pi * k * s / ModemParams.fftSize;
        final wr = math.cos(a), wi = math.sin(a);
        final hr = _hRe[i] * wr - _hIm[i] * wi;
        final hi = _hRe[i] * wi + _hIm[i] * wr;
        _hRe[i] = hr;
        _hIm[i] = hi;
      }
    }
  }

  bool _finishHeader() {
    final llr = _hdrIl.deinterleaveLlr(_hdrLlr);
    final info = _hdrCode.decode(llr, maxIter: 50);
    if (info == null) {
      onStatus?.call('header decode failed');
      return false;
    }
    Scrambler.apply(info, Scrambler.headerTag);
    final hdr = BurstHeader.unpack(Uint8List.sublistView(info, 0, 32));
    if (hdr == null) {
      onStatus?.call('header CRC failed');
      return false;
    }
    if (hdr.blockCount > 4096) return false;
    _hdr = hdr;
    final code = LdpcCode.payload(hdr.rate);
    _payLlr = Float64List(hdr.blockCount * code.n);
    _blocks = List<Uint8List?>.filled(hdr.blockCount, null, growable: false);
    onStatus?.call('header ok: $hdr');
    return true;
  }

  int _blocksDecoded = 0;

  void _decodeReadyBlocks(LdpcCode code) {
    while (_blocksDecoded < _blocks.length &&
        (_blocksDecoded + 1) * code.n <= _payBitsGot) {
      final blk = _blocksDecoded;
      final llr = Float64List(code.n);
      llr.setRange(0, code.n, _payLlr, blk * code.n);
      final de = _payIl.deinterleaveLlr(llr);
      final stats = LdpcDecodeStats();
      final info = code.decode(de, stats: stats);
      if (info != null) {
        Scrambler.apply(info, blk);
        final want = ByteData.sublistView(info).getUint32(code.infoBytes - 4);
        if (crc32(info, 0, code.infoBytes - 4) == want) {
          _blocks[blk] = Uint8List.sublistView(info, 0, code.infoBytes - 4);
          _blkOk++;
          _fecCoded += code.n;
          _fecCorrected += stats.correctedBits;
        } else {
          _blockErrors++;
          _blkCrcFail++;
        }
      } else {
        _blockErrors++;
        _blkUncorrectable++;
      }
      _blocksDecoded++;
    }
  }

  void _emitBurst() {
    final h = _hdr;
    if (h == null) return;
    // Trim per-block user data to the payload length from the header.
    final code = LdpcCode.payload(h.rate);
    final user = code.infoBytes - 4;
    final blocks = List<Uint8List?>.generate(_blocks.length, (i) {
      final b = _blocks[i];
      if (b == null) return null;
      final start = i * user;
      final remain = h.payloadBytes - start;
      if (remain <= 0) return Uint8List(0);
      return remain >= user ? b : Uint8List.sublistView(b, 0, remain);
    });
    _blocksDecoded = 0;
    if (captureConstellation && _ccCount > 0) {
      final mean = _ccSum / _ccCount;
      final variance = math.max(_ccSum2 / _ccCount - mean * mean, 0.0);
      lastConstellation = ConstellationSnapshot(
        xy: Float32List.fromList(_ccXY),
        mod: h.mod,
        snrDb: lastSnrDb,
        evmRmsPct: math.sqrt(_ccSum2 / _ccCount) * 100,
        evmMaxPct: _ccMax * 100,
        evmStdPct: math.sqrt(variance) * 100,
        totalPoints: _ccCount,
        srcCall: h.srcCall,
        fecCorrectedBits: _fecCorrected,
        fecCodedBits: _fecCoded,
        blocksOk: _blkOk,
        blocksCrcFailed: _blkCrcFail,
        blocksUncorrectable: _blkUncorrectable,
      );
    }
    onBurst(ReceivedBurst(
      header: h,
      blocks: blocks,
      snrDb: lastSnrDb,
      blockErrors: _blockErrors,
      startSample: _chanestAbs,
    ));
  }
}
