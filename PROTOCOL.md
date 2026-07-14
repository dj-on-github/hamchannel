# HamChannel On-Air Protocol Specification

**Version 2 · protocol as implemented in `lib/dsp`, `lib/fec`, `lib/modem`, `lib/proto`**
*(v2 adds PRBS scrambling of all LDPC info bytes; v1 receivers reject v2
bursts at the header check and vice versa.)*

This document specifies the complete on-air protocol of HamChannel, an
acoustic-coupled OFDM data modem for VHF/UHF FM amateur radio. It covers the
physical layer (OFDM numerology, waveforms, synchronization, channel
tracking), the forward-error-correction layer (LDPC code construction,
encoding, decoding, interleaving), the burst format, and the link layer
(packets and ARQ procedures). Two independent implementations built from
this document should interoperate.

All multi-byte integer fields are **big-endian** unless stated otherwise.
Bit 0 of a flags byte is the least-significant bit.

---

## 1. System overview

HamChannel transmits data as audio through the microphone/speaker path of an
FM transceiver. The transmitter is keyed by VOX: every transmission begins
with a leader of repeated synchronization symbols that both keys the radio
and lets the receiver acquire timing. Transmissions are **bursts** — fully
self-describing, half-duplex, one direction at a time. Reliability is
layered:

1. **LDPC** forward error correction corrects channel errors within a burst.
2. **CRC-32** per code block detects residual errors; a failed block is
   discarded, not the whole burst.
3. **Selective-repeat ARQ** at the link layer retransmits only the file
   chunks that were lost.

Because an FM audio channel translates no frequencies, the receiver only
needs to track sound-card sample-clock offset (tens of ppm) and slow phase
drift; there is no carrier-frequency-offset problem as in RF-coupled OFDM.

## 2. Deterministic PRNG (`DetRng`)

Both stations derive every shared pseudo-random object (preamble bits, pilot
polarities, LDPC graph, interleaver permutation, filler bits) from a common
32-bit xorshift generator, so nothing but the configuration needs to agree
in advance.

State update (32-bit wraparound arithmetic):

```
x ^= x << 13   (mod 2^32)
x ^= x >> 17
x ^= x << 5    (mod 2^32)
```

`nextInt(b)` returns `x mod b` after one update; `nextBit()` is
`nextInt(2)`. A seed of 0 is replaced by `0x9E3779B9`. Seeds used:

| Object                    | Seed                                            |
|---------------------------|-------------------------------------------------|
| Sync-symbol PN bits       | `0x51AC0000 XOR A` (A = active carrier count)   |
| Chanest-symbol PN bits    | `0xC4A57000 XOR A`                              |
| Pilot polarity            | `0x917070 XOR (symIdx+7)·2654435761 XOR carrier·40503` |
| LDPC graph                | `0xC0DE0000 XOR (n<<8) XOR (num<<4) XOR den`    |
| Interleaver               | `0x1EAF0000 XOR n`                              |
| Filler bits               | `0xF111 XOR burstId`                            |
| Scrambler PRBS            | `0x5C7AB1E5 XOR (tag+1)·2654435761` — tag = payload block index, or 0x10000 for the header |

## 3. OFDM physical layer

### 3.1 Numerology

| Parameter            | Value                          |
|----------------------|--------------------------------|
| Sample rate          | 48 000 Hz                      |
| FFT size N           | 1024                           |
| Subcarrier spacing   | 46.875 Hz                      |
| Cyclic prefix        | 128 samples (1/8)              |
| Symbol length        | 1152 samples = 24 ms           |
| Symbol rate          | 41.667 symbols/s               |
| First active bin     | profile-dependent (see below)  |

Three channel profiles (both stations must use the same one):

| Profile | Active carriers A | Audio span        | Occupied BW | Pilots | Data carriers |
|---------|-------------------|-------------------|-------------|--------|---------------|
| HF      | 52 (bins 8–59)    | 375 Hz – 2812 Hz  | ≤ 2.8 kHz   | 6      | 46            |
| Narrow  | 240 (bins 16–255) | 750 Hz – 12.0 kHz | ≤ 12 kHz    | 30     | 210           |
| Wide    | 480 (bins 16–495) | 750 Hz – 23.25 kHz| ≤ 24 kHz    | 60     | 420           |

The HF profile fits a 2.8 kHz SSB channel and uses the identical burst
format, modulations and LDPC codes — only the carrier count and first bin
(8 instead of 16) differ. Note that SSB translates audio frequencies by
any transceiver mistuning, and this protocol performs no
carrier-frequency-offset search: the pilot phase tracker absorbs constant
offsets of only a few hertz, so HF stations must be tuned within roughly
±3 Hz of each other. FM channels (narrow/wide) have no such constraint.

Active carriers are indexed `i = 0 … A-1` (FFT bin = firstBin + i). **Pilot
positions** are `i = 8j + 4` for `j = 0 … A/8-1` (i.e. carriers 4, 12, 20,
…). All other active carriers are data carriers, filled in ascending order.

### 3.2 Symbol construction

For each OFDM symbol, complex values are placed on the active bins, the
spectrum is made Hermitian-symmetric (`X[N-k] = conj(X[k])`, `X[0] =
X[N/2] = 0` for the imaginary part) so the 1024-point inverse FFT (with 1/N
scaling) yields a real waveform, and the last 128 time samples are copied in
front as the cyclic prefix.

Pilot carriers carry BPSK values ±1 whose polarity comes from the pilot
PRNG seeded with the **data-symbol index** (0 = first header symbol; the
chanest symbol carries no pilots) and the carrier index, so pilots look like
noise rather than steady tones.

### 3.3 Known symbols (preamble)

Two full-band known symbols are derived from PN bit sequences over the
active carriers: bit 0 → +1, bit 1 → −1, and every odd-indexed carrier is
rotated to the imaginary axis (value ±j) to reduce PAPR:

* **Sync symbol** — repeated L times as the burst leader (default L = 15 ≈
  360 ms; configurable 6–42). Serves as VOX keying tone, energy detector
  target, and timing reference.
* **Chanest symbol** — transmitted once after the leader; the receiver's
  least-squares channel estimate reference.

### 3.4 Constellations and bit mapping

All constellations are Gray-mapped with unit average energy:

| Modulation | Bits/carrier | Axis scale       |
|------------|--------------|------------------|
| BPSK       | 1            | ±1 (real axis)   |
| QPSK       | 2            | ±1/√2 per axis   |
| 16-QAM     | 4            | odd·1/√10        |
| 64-QAM     | 6            | odd·1/√42        |

Bit order per constellation point: BPSK — bit 0 = 0 maps to +1. QPSK — first
bit selects the I sign, second the Q sign (0 → positive). Square QAM — the
first half of the bits (MSB first) Gray-encode the I level, the second half
the Q level. The Gray value is decoded to a level index `idx`
(binary-reflected), and the amplitude is `-(2·idx - (m-1))·scale` where `m`
is levels per axis — hence a Gray MSB of 0 selects the positive side of the
axis, and adjacent levels differ in exactly one bit.

The coded bit stream of a burst section (header or payload) is written
across the data carriers of consecutive OFDM symbols in carrier order,
`bitsPerSymbol` per carrier. Slots after the end of the stream in the final
symbol are filled with PRNG filler bits so the spectrum stays flat.

### 3.5 Burst structure

```
| L × sync | chanest | header symbols | payload symbols | postamble |  tail |
|  leader  |    1    |  3 (narrow) /  |  ceil(bits/bps) |     1     | 100 ms|
|          |         |    2 (wide)    |                 |           |silence|
```

* **Postamble** — one filler-only OFDM symbol appended so the closing
  amplitude ramp never touches payload samples.
* **Ramps** — 240-sample (5 ms) raised-cosine amplitude ramps at burst start
  and end.
* **Normalization** — the whole burst is scaled so its peak is
  `0.95 × txLevel`.
* **Tail** — 4800 samples of silence hold VOX through the radio's tx tail.

### 3.6 Header

The header is always transmitted in the most robust mode: **BPSK, LDPC
(512, 256), rate 1/2**, bit-interleaved. It occupies
`ceil(512 / dataCarriers)` symbols (3 narrow, 2 wide). Header info content
(32 bytes = the full k of the header code):

| Offset | Size | Field                                              |
|--------|------|----------------------------------------------------|
| 0      | 2    | Magic `0x48 0x43` ("HC")                           |
| 2      | 1    | Protocol version = 2                               |
| 3      | 1    | Frame type (0 data, 1 response, 2 beacon)          |
| 4      | 6    | Source callsign, ASCII, space-padded, upper-case   |
| 10     | 6    | Destination callsign ("CQ    " for broadcast)      |
| 16     | 2    | Burst ID (sender's counter)                        |
| 18     | 1    | Payload modulation (0 BPSK, 1 QPSK, 2 16-QAM, 3 64-QAM) |
| 19     | 1    | Payload LDPC rate (0 = 1/2, 1 = 2/3, 2 = 3/4, 3 = 5/6) |
| 20     | 2    | Payload block count                                |
| 22     | 4    | Exact payload byte count                           |
| 26     | 1    | Flags — bit 0: ACK requested                       |
| 27     | 3    | Reserved (0)                                       |
| 30     | 2    | CRC-16/CCITT-FALSE over bytes 0–29                 |

The packed 32-byte header is **scrambled** (§3.8) with the header tag
before LDPC encoding; the receiver descrambles the decoded bytes before
checking magic and CRC.

The station callsign in every header satisfies the digital station
identification requirement (FCC Part 97.119 via data emission).

### 3.7 Payload blocks

The link-layer payload byte stream is split into LDPC blocks. Each block's
info part is:

```
| user data (k/8 − 4 bytes, zero-padded in the last block) | CRC-32 (4B) |
```

CRC-32 is the reflected IEEE 802.3 polynomial (0xEDB88320), computed over
the user-data portion. The complete info block (data + CRC) is then
**scrambled** (§3.8) with the block's index as tag, LDPC-encoded to 2048
coded bits, and bit-interleaved (§5); the blocks are concatenated into the
payload bit stream. On receive, each block is decoded, descrambled, and
CRC-checked independently; a failed block leaves a hole that the ARQ layer
repairs.

### 3.8 Scrambler

To keep the transmitted symbol distribution random regardless of payload
content (zero padding, repeated bytes), every LDPC info block is XORed
with a deterministic PRBS before encoding, and XORed with the same
sequence after decoding. The sequence is the successive `nextInt(256)`
outputs of a DetRng (§2) seeded with
`0x5C7AB1E5 XOR (tag+1)·2654435761` (32-bit wraparound), where `tag` is
the block's index within the burst's payload (0-based) or `0x10000` for
the header block. Scrambling is applied after the CRC is computed, so the
CRC check on receive happens on descrambled bytes. XOR being an
involution, applying the same sequence twice restores the data.

## 4. LDPC coding

### 4.1 Code family

Systematic **irregular repeat-accumulate (IRA)** codes with parity-check
matrix `H = [A | P]` (m rows = n−k):

* `A` (m × k): every information column has weight 3. For each column the
  three row indices are drawn from the graph PRNG (§2); a candidate row is
  rejected while the attempt count is below 60 if it would duplicate a
  row-pair already used by another column (best-effort 4-cycle avoidance),
  and duplicate rows within a column are always rejected (up to 200
  attempts). The three rows are sorted ascending before use — this ordering
  is part of the specification because it fixes the PRNG consumption order.
* `P` (m × m): dual-diagonal accumulator — `P[i][i] = 1` and
  `P[i][i-1] = 1`.

Code sizes (k is rounded **down** to a whole byte):

| Code            | n    | k    | Info bytes | Used for        |
|-----------------|------|------|------------|-----------------|
| Header          | 512  | 256  | 32         | burst header    |
| Payload r = 1/2 | 2048 | 1024 | 128        | payload blocks  |
| Payload r = 2/3 | 2048 | 1360 | 170        | payload blocks  |
| Payload r = 3/4 | 2048 | 1536 | 192        | payload blocks  |
| Payload r = 5/6 | 2048 | 1704 | 213        | payload blocks  |

### 4.2 Encoding

Information bits are taken MSB-first from the info bytes. Because of the
accumulator structure, encoding is a single O(edges) pass:

```
acc = 0
for row = 0 … m-1:
    s = XOR of info bits referenced by row      (columns of A)
    acc = acc XOR s
    parity[row] = acc
```

The codeword is `[info bits | parity bits]`.

### 4.3 Decoding

Normalized min-sum belief propagation with **row-serial (layered)**
scheduling and posterior tracking:

* Input: one LLR per coded bit, **positive = bit 0**.
* Per check row: compute variable-to-check messages `q = posterior − r`,
  find the two smallest magnitudes and the sign product; each new
  check-to-variable message is `sign · α · min` (excluding self), with
  normalization factor **α = 0.8**; the posterior is updated in place
  (`post += r_new − r_old`), so later rows in the same iteration benefit
  from earlier updates.
* Hard decisions are checked against all parity equations after every
  iteration; decoding stops on success. Iteration limits: 40 (payload),
  50 (header). Failure (no valid codeword) marks the block bad.
* Rows with fewer than two edges are skipped.

### 4.4 Interleaving

Each coded block is bit-interleaved by a fixed Fisher–Yates permutation of
its n positions generated from the interleaver PRNG (walking `i = n−1 … 1`,
swapping with `j = nextInt(i+1)`). The transmitted bit at position
`perm[i]` is coded bit `i`. The header (n = 512) and payload (n = 2048)
codes have their own permutations. Interleaving spreads each parity
equation across the band so a notch or interference tone doesn't
concentrate errors in few equations.

## 5. Receiver procedures (informative)

A conforming receiver may use any method; this describes the reference
implementation.

**Search.** The incoming stream is cross-correlated with the known sync
waveform (all 1152 samples) using normalized correlation evaluated every 5
samples (5 is coprime to 1152, so the scan grid precesses across leader
repeats and some repeat always lands within one sample of a grid point —
important because the correlation main lobe of this near-full-band signal is
only ~1 sample wide). A coarse hit (NCC > 0.30) triggers a full-rate fine
search over ±12 samples; NCC > 0.40 locks.

**Leader tracking.** Successive sync repeats are verified at 1152-sample
spacing with ±2-sample micro-adjustment. At each position the chanest
template is also correlated over its own ±2 window; when the chanest
correlation exceeds the sync correlation (and 0.30), the chanest symbol has
been found and its position defines the burst's symbol grid. Two
consecutive correlation misses abandon the acquisition.

**Demodulation window.** Every symbol is FFT-windowed at
`symbolStart + CP − 32` (a 32-sample back-off into the cyclic prefix). The
constant phase ramp this introduces is absorbed into the channel estimate.

**Channel estimation.** From the chanest symbol: `H = Y · conj(X)` per
active carrier, then smoothed across frequency with a 5-tap moving average
(valid because the acoustic channel's delay spread is far shorter than the
CP).

**Pilot tracking (per symbol).** Equalized pilots `z = (Y/H)·pilot` are
fit with a two-stage phase model `θ + slope·carrier`:
stage 1 — wrap-free coarse slope from adjacent-pilot delay-and-multiply
(phase of `Σ z[j+1]·conj(z[j])` divided by the pilot spacing 8) and common
phase θ; stage 2 — least-squares refinement on the (small, independent)
residual angles, which removes the coarse estimator's carrier-index-scaled
noise. The fitted rotation is folded into H each symbol, making the tracker
a first-order loop.

**Sample-clock (SFO) tracking.** The per-symbol slope corresponds to a
window drift of `slope·N/2π` samples; the drift is accumulated, and when it
exceeds ±1.5 samples the window position is slipped by the rounded amount
and H is rotated by the matching per-bin phase `e^{-j2πks/N}`. The slip
takes effect **from the next symbol** — the current symbol is equalized
first. This tracks at least ±80 ppm clock offset over multi-thousand-sample
bursts.

**LLRs.** Noise variance is estimated from corrected pilot residuals
(EMA, weights 0.7/0.3) and scaled per carrier by `mean|H|² / |H_k|²`, so
attenuated carriers (e.g. sound-card roll-off at the band edge) produce
appropriately weak LLRs. Max-log per-axis LLRs feed the deinterleaver and
LDPC decoder.

## 6. Link layer

### 6.1 Payload packet formats

A burst payload is a concatenation of packets. Every packet begins with a
1-byte type. Types 0x00/0x01 are padding used to align file chunks to LDPC
block boundaries, which makes each chunk's fate independent of neighboring
blocks and lets the receiver resynchronize parsing at any block boundary
after a lost block.

| Type | Name        | Body                                                             |
|------|-------------|------------------------------------------------------------------|
| 0x00 | PAD1        | (single padding byte)                                            |
| 0x01 | PADBLK      | u16 len, then `len` ignored bytes                                |
| 0x10 | MSG         | u16 msgId · u16 len · UTF-8 text                                 |
| 0x11 | MSG_ACK     | u16 msgId                                                        |
| 0x20 | FILE_META   | u16 fileId · u8 nameLen · name · u32 size · 32 B SHA-256 · u16 chunkBytes · u16 chunkCount |
| 0x21 | FILE_DATA   | u16 fileId · u16 chunkIdx · u16 len · data                       |
| 0x22 | FILE_NAK    | u16 fileId · u8 needMeta · u16 nBits · bitmap ⌈nBits/8⌉ B        |
| 0x23 | FILE_DONE   | u16 fileId                                                       |
| 0x30 | FILE_REQ    | u16 reqId · u8 nameLen · name (UTF-8)                            |
| 0x31 | FILE_REQ_NAK| u16 reqId · u16 len · UTF-8 reason                               |
| 0x32 | LIST_REQ    | u16 reqId                                                        |
| 0x33 | LIST_RESP   | u16 reqId · u16 len · UTF-8 listing (`name<TAB>size<LF>` lines)  |
| 0x40 | BEACON      | u16 len · UTF-8 text                                             |

FILE_NAK bitmap bit order: chunk `i` missing ⇔ byte `i >> 3` bit `i & 7`
(**LSB-first within each byte**) is 1. `nBits` equals the transfer's total
chunk count. `needMeta = 1` asks the sender to (re)send FILE_META.

An unknown packet type aborts parsing of the remainder of that block run
(forward compatibility relies on the version byte in the header).

### 6.2 Block alignment and parsing after loss

Small packets (MSG, META, ACKs, requests) are packed first; padding then
aligns the stream to the next LDPC block boundary, and each FILE_DATA chunk
is sized to exactly fill one block: `chunkBytes = k/8 − 4 − 7` (block user
bytes minus the 7-byte FILE_DATA header). On receive, consecutive
successfully-decoded blocks are concatenated into runs and each run is
parsed independently, so one bad block costs at most the packets inside it
plus any packet straddling the run edge.

### 6.3 ARQ procedures

Half-duplex with implicit turn-taking; all timing values are configurable.

* **Carrier sense** — a station never transmits while its receiver is
  collecting a burst or while it awaits an ACK it has solicited.
* **Response solicitation** — a burst with header flag ACK_REQ obliges the
  addressed station to reply after the turnaround delay (default 800 ms)
  with a `response` frame containing MSG_ACKs, FILE_NAK/FILE_DONE for every
  transfer touched, and answers to requests. A response with nothing to say
  carries a single PAD1 byte.
* **Messages** — sent bundled in one burst with ACK_REQ (unless addressed
  to CQ); retransmitted on timeout (default 12–15 s) up to `maxRetries`
  (default 6). Receivers de-duplicate on (peer, msgId) but always re-ack.
* **File send** — each data burst carries FILE_META plus up to
  `maxChunksPerBurst` (default 24) chunks, ACK_REQ set. The receiver NAKs
  the complete missing-chunk bitmap; the sender's send-set is replaced by
  it, so only losses are retransmitted. A NAK resets the retry counter; a
  timeout sends a META-only probe. When all chunks are present the receiver
  verifies length and SHA-256, saves the file, and replies FILE_DONE
  (repeated if the sender's META arrives again). SHA-256 mismatch restarts
  the transfer with a full NAK.
* **File request / listing** — FILE_REQ names a file in the remote's shared
  folder; the remote either starts a normal file send to the requester or
  replies FILE_REQ_NAK. LIST_REQ yields LIST_RESP (listing truncated to
  ~1800 bytes). Handled request IDs are cached against duplicate delivery.
* **Beacon** — broadcast text to CQ, never acknowledged.

## 7. Throughput

Raw bit rate = dataCarriers × bits/carrier × 41.667 sym/s; net = raw × code
rate. Per-block overhead (4 B CRC of 128–213 B info) and per-burst overhead
(leader + chanest + header + postamble ≈ 0.46 s at default leader) come out
of the net figure.

| Mode (narrow)   | Raw kbit/s | Net kbit/s | | Mode (wide)     | Raw kbit/s | Net kbit/s |
|-----------------|-----------:|-----------:|-|-----------------|-----------:|-----------:|
| BPSK 1/2        |       8.75 |       4.38 | | BPSK 1/2        |      17.50 |       8.75 |
| QPSK 1/2        |      17.50 |       8.75 | | QPSK 1/2        |      35.00 |      17.50 |
| QPSK 3/4        |      17.50 |      13.13 | | 16-QAM 3/4      |      70.00 |      52.50 |
| 16-QAM 3/4      |      35.00 |      26.25 | | 64-QAM 5/6      |     105.00 |      87.50 |
| 64-QAM 5/6      |      52.50 |      43.75 | |                 |            |            |

| Mode (HF, 2.8 kHz) | Raw kbit/s | Net kbit/s |
|--------------------|-----------:|-----------:|
| BPSK 1/2           |       1.92 |       0.96 |
| QPSK 1/2           |       3.83 |       1.92 |
| QPSK 3/4           |       3.83 |       2.88 |
| 16-QAM 3/4         |       7.67 |       5.75 |
| 64-QAM 5/6         |      11.50 |       9.58 |

Measured decode thresholds through the simulated AWGN channel (time-domain
SNR over the occupied band): BPSK 1/2 ≈ 3 dB, QPSK 1/2 ≈ 6 dB, 16-QAM 3/4 ≈
14 dB, 64-QAM 5/6 ≈ 22 dB, each with margin for the ±50 ppm clock-offset
tracker engaged.

## 8. Interoperability checklist

Two stations interoperate when they agree on: channel profile
(narrow/wide); everything else is announced per burst. A conforming
implementation must reproduce exactly: the DetRng update and every seed in
§2, the carrier/pilot layout (§3.1), the known-symbol construction
including the odd-carrier j-rotation (§3.3), the Gray mapping conventions
(§3.4), the header layout and CRC-16/CCITT-FALSE (§3.6), the LDPC graph
construction order (§4.1) and accumulator encoding (§4.2), the interleaver
permutation (§4.4), the per-block CRC-32 framing (§3.7), the info-block
scrambler and its tags (§3.8), and the packet wire formats (§6.1)
including the FILE_NAK bitmap bit order.

## 9. Glossary

**ACK / NAK** — Acknowledgement / negative acknowledgement. An ACK confirms
receipt; a NAK reports what is missing so the sender retransmits only that
(see FILE_NAK, §6.1).

**Accumulator (dual-diagonal)** — The parity part `P` of the LDPC
parity-check matrix, with ones on the main diagonal and the diagonal below
it. It makes each parity bit the running XOR of everything before it, which
is what allows single-pass encoding (§4.2).

**Active carrier** — A subcarrier that actually carries energy (pilot or
data), i.e. FFT bins 16 … 16+A−1. All other bins are transmitted empty.

**ARQ (Automatic Repeat reQuest)** — A link-layer scheme in which the
receiver's feedback (ACK/NAK) triggers retransmission of lost data.
HamChannel uses *selective-repeat* ARQ: only missing chunks are resent.

**AWGN (Additive White Gaussian Noise)** — The noise model used for the
validation figures in §7: noise with a flat spectrum and Gaussian amplitude
added to the signal.

**Bin** — One output index of the FFT; equivalently a frequency slot
46.875 Hz wide. "Bin k" is centered at k × 46.875 Hz.

**BPSK (Binary Phase-Shift Keying)** — Modulation carrying 1 bit per
carrier as one of two opposite phases (+1 / −1).

**Burst** — One complete transmission (one VOX keying): leader, chanest,
header, payload, postamble (§3.5). The unit of the on-air protocol.

**Callsign** — The station identifier issued with an amateur licence,
carried in every burst header (§3.6).

**Carrier sense** — Refraining from transmitting while a signal is being
received, to avoid collisions on the shared half-duplex channel (§6.3).

**Chanest (channel-estimation symbol)** — The known OFDM symbol sent once
after the leader from which the receiver measures the channel response H
(§3.3, §5).

**Chunk** — The fixed-size slice of a file carried by one FILE_DATA packet,
sized to exactly fill one LDPC block (§6.2).

**CP (cyclic prefix)** — A copy of the last 128 samples of an OFDM symbol
prepended to it. It absorbs multipath/filter dispersion and small timing
errors so subcarriers stay orthogonal.

**CQ** — Amateur-radio convention for "calling any station"; used as the
destination callsign for broadcast bursts.

**CRC (Cyclic Redundancy Check)** — A checksum for error *detection*.
CRC-16/CCITT-FALSE protects the header; CRC-32 (IEEE 802.3, reflected)
protects each payload block.

**Data carrier** — An active carrier that is not a pilot; carries
constellation symbols.

**DetRng** — This protocol's deterministic 32-bit xorshift pseudo-random
generator (§2). Both stations run it with fixed seeds to derive identical
preambles, pilots, LDPC graphs, and interleavers.

**EMA (Exponentially-weighted Moving Average)** — A smoothing filter
(`new = a·old + (1−a)·measurement`); used for the receiver's noise-variance
estimate (§5).

**Equalization** — Dividing each received carrier by the channel estimate
(`Y/H`) to undo the channel's amplitude and phase response.

**FEC (Forward Error Correction)** — Redundancy added at the transmitter
(here LDPC parity bits) that lets the receiver correct errors without a
retransmission.

**FFT / IFFT (Fast Fourier Transform / its inverse)** — The transform
between the time-domain waveform and its subcarrier amplitudes. The
transmitter uses the IFFT (with 1/N scaling), the receiver the FFT.

**FM (Frequency Modulation)** — The voice mode of the radios this modem is
designed to feed audio through. FM preserves audio frequencies, which is
why no carrier-frequency-offset tracking is needed.

**Gray code / Gray mapping** — An ordering of bit patterns in which
adjacent constellation points differ in exactly one bit, minimizing bit
errors from small symbol errors (§3.4). *Binary-reflected* Gray decoding
maps the pattern back to a level index.

**Half-duplex** — Transmit and receive alternate on one channel; never both
at once.

**Hermitian symmetry** — The spectrum constraint `X[N−k] = conj(X[k])`
that forces the IFFT output to be a real (audio) waveform.

**IRA (Irregular Repeat-Accumulate)** — The LDPC code family used here:
a sparse random part plus an accumulator, giving linear-time encoding with
belief-propagation decodability (§4.1).

**Interleaver** — A fixed permutation applied to each block's coded bits so
that frequency-localized channel damage spreads evenly across the
codeword's parity equations (§4.4).

**LDPC (Low-Density Parity-Check) code** — A linear FEC code whose
parity-check matrix is sparse, decoded iteratively by message passing.
The workhorse FEC of this protocol (§4).

**Leader** — The run of repeated sync symbols at the start of every burst;
keys VOX and gives the receiver time and material to synchronize (§3.3).

**LLR (Log-Likelihood Ratio)** — The decoder's soft input for one coded
bit: `log P(bit=0)/P(bit=1)` given the received sample. Positive means
"probably 0"; the magnitude expresses confidence. *Max-log* LLRs
approximate the sum over constellation points by the nearest point only.

**LS (Least Squares)** — Fitting model parameters by minimizing squared
error; used for the channel estimate and the stage-2 pilot phase fit (§5).

**LSB / MSB** — Least / most significant bit (or byte) of a value.

**Min-sum (normalized)** — A simplified belief-propagation check-node rule
that replaces the exact update with the minimum input magnitude, scaled by
a factor α (= 0.8) to compensate the approximation's optimism (§4.3).

**NCC (Normalized Cross-Correlation)** — Correlation between the received
samples and a known template, divided by both energies, yielding a value in
[−1, 1] independent of signal level; the sync detector's metric (§5).

**OFDM (Orthogonal Frequency-Division Multiplexing)** — Modulation that
splits the channel into many narrow subcarriers spaced so they don't
interfere, each carrying a low-rate constellation symbol; robust against
frequency-selective channels.

**PAPR (Peak-to-Average Power Ratio)** — How much a waveform's peaks exceed
its average level. OFDM has high PAPR; the odd-carrier rotation in the
known symbols reduces theirs.

**Pilot** — An active carrier with a known (PRNG-derived) value inserted in
every data symbol, from which the receiver tracks phase, timing drift, and
noise level (§3.1, §5).

**PN (Pseudo-Noise) sequence** — A deterministic bit sequence with
noise-like statistics, produced by DetRng; used for preamble bits, pilots
and filler.

**PRBS (Pseudo-Random Binary Sequence)** — A PN sequence used as a
scrambling mask; see Scrambler.

**Postamble** — The final filler-only OFDM symbol of a burst, present so
the closing amplitude ramp damages no payload (§3.5).

**ppm (parts per million)** — Relative frequency error unit. Sound-card
clocks typically differ by tens of ppm, causing the timing drift the slip
tracker corrects (§5).

**PRNG (Pseudo-Random Number Generator)** — See DetRng.

**PTT (Push-To-Talk)** — The transmitter keying line of a radio. This
protocol avoids PTT wiring by using VOX.

**QAM (Quadrature Amplitude Modulation)** — Modulation using both amplitude
and phase; 16-QAM carries 4 bits per carrier, 64-QAM carries 6.

**QPSK (Quadrature Phase-Shift Keying)** — Four-phase modulation carrying
2 bits per carrier.

**Raised cosine (ramp)** — The smooth half-cosine amplitude taper applied
to the first and last 5 ms of a burst to avoid clicks and spectral splatter.

**Scrambler** — The deterministic XOR of each LDPC info block with a PRBS
(§3.8), applied before encoding and removed after decoding, which whitens
the transmitted bits so repetitive payloads still produce random-looking
symbols.

**SFO (Sampling-Frequency Offset)** — The mismatch between transmitter and
receiver sound-card sample clocks; manifests as steadily drifting symbol
timing (see slip, §5).

**SHA-256** — The 256-bit cryptographic hash used to verify a completed
file transfer end-to-end (§6.1, FILE_META).

**Slip** — A deliberate ±n-sample shift of the receiver's FFT window,
applied when accumulated SFO drift exceeds ±1.5 samples, with a matching
phase correction to H (§5).

**SNR (Signal-to-Noise Ratio)** — Signal power over noise power, in dB.
This document quotes time-domain SNR over the occupied band unless stated
otherwise.

**Subcarrier** — One of the narrow orthogonal tones an OFDM signal is
built from; synonymous with "carrier" in this document.

**Sync symbol** — The known OFDM symbol repeated as the leader; the
receiver's timing-acquisition template (§3.3).

**Turnaround** — The pause (default 800 ms) between receiving a burst that
requests an ACK and transmitting the response, giving the sender's radio
time to unkey.

**u8 / u16 / u32** — Unsigned integer field of 8/16/32 bits (multi-byte
fields big-endian).

**UTF-8** — The Unicode text encoding used for all text fields (messages,
filenames, listings).

**VHF / UHF** — Very/Ultra High Frequency amateur bands (30–300 MHz /
300 MHz–3 GHz) where the FM radios this modem targets operate.

**VOX (Voice-Operated eXchange)** — A radio feature that keys the
transmitter automatically when audio is present; the burst leader serves as
its trigger.

**Xorshift** — The class of fast PRNGs based on XOR and bit shifts; DetRng
is a 32-bit xorshift generator.
