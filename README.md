# HamChannel

An OFDM soundcard data modem for VHF/UHF FM ham radios, built in Flutter for
desktop (macOS / Linux / Windows). It sends text messages and files between
two stations using the laptop's headphone and microphone jacks wired to the
radio, with LDPC forward error correction and a selective-repeat ARQ layer
for reliable file delivery.

> **You are responsible for operating within your licence.** The app embeds
> your callsign in every transmitted frame header (FCC Part 97 station ID for
> digital modes), but transmitting requires a valid amateur licence and a
> band/mode where data emission is permitted.

The complete on-air protocol (OFDM numerology, LDPC construction, burst
format, packet wire formats, ARQ procedures) is specified in
[PROTOCOL.md](PROTOCOL.md).

## Physical layer

| Property | Narrow | Wide |
|---|---|---|
| Channel occupancy | 12 kHz | 24 kHz |
| Active subcarriers | 240 | 480 |
| Audio span | 750 Hz – 12 kHz | 750 Hz – 23.25 kHz |

* 48 kHz sample rate, 1024-point FFT (46.875 Hz spacing), 1/8 cyclic prefix,
  24 ms symbols.
* Subcarrier modulation: **BPSK, QPSK, 16-QAM or 64-QAM** (Channel tab).
* FEC: systematic IRA-type **LDPC (n = 2048)** at rates **1/2, 2/3, 3/4,
  5/6**, normalized min-sum decoder; every block carries a CRC-32.
* Burst = VOX leader (repeated sync symbol) + channel-estimation symbol +
  BPSK rate-1/2 header + payload blocks. Pilot tones (every 8th carrier)
  track phase and sample-clock drift through the burst.
* Net throughput ranges from ~4.3 kbit/s (narrow BPSK 1/2) to
  ~85 kbit/s (wide 64-QAM 5/6, needs an excellent link and a sound path
  flat to 23 kHz — most FM radios will not pass that; start narrow).

## Link layer

* Half-duplex ARQ: data bursts request an ACK; the receiver answers with a
  NAK bitmap of missing chunks, the sender resends only those.
* Files are chunked to align exactly one chunk per LDPC block, SHA-256
  verified on completion, then saved under `Documents/hamchannel/received`.
* The remote station can request any file in your
  `Documents/hamchannel/shared` folder (Files tab → fetch list / request).
* Text messages are acknowledged and retried automatically.

## UI tabs

1. **Messages** — terminal-style messaging; the text is sent as one burst.
   The small terminal icon toggles the modem log.
2. **Send Files** — local file browser to pick and queue files; progress per
   transfer; add files to the shared folder.
3. **Files** — files received from the other end, plus "request from
   remote": fetch the remote shared-folder listing or request by name.
4. **Signal Quality** — constellation diagram of the equalized symbols from
   the last received transmission, with SNR and EVM statistics (RMS, max,
   standard deviation). Capture is off by default; enable it with the
   switch at the top of the tab.
5. **Channel** — narrow/wide, subcarrier modulation, LDPC rate, callsigns,
   audio input/output device selection, TX level, VOX leader length,
   PCM capture, loopback test mode.

## Radio wiring (VOX keying)

```
laptop headphone out ──[attenuator 10:1 or isolation transformer]──▶ radio mic in
radio speaker/data out ──────────────────────────────────────────▶ laptop mic in
```

* Enable VOX on the radio. Increase **VOX leader** (Channel tab) if the
  start of bursts is clipped; 360 ms suits most HTs.
* Set radio and laptop volumes so the **RX meter moves to mid-scale without
  clipping**; keep **TX level** low enough that the FM deviation stays clean
  — overdriving the mic input is the most common cause of decode failures.
* 12 kHz mode fits a 12.5 kHz channel only through a flat "9600-baud" data
  port; through ordinary mic/speaker paths expect the upper carriers to be
  attenuated (the equalizer copes with moderate roll-off, but narrow +
  lower-order modulation is the robust choice).

## Building & running

```bash
flutter pub get
flutter run -d macos      # or -d linux / -d windows
```

macOS: microphone permission is requested on first start
(`NSMicrophoneUsageDescription` is set in `macos/Runner/Info.plist`; the
`com.apple.security.device.audio-input` entitlement must be present in
`DebugProfile.entitlements` / `Release.entitlements`).

Linux: audio capture uses PulseAudio's `parecord` (works under PipeWire via
`pipewire-pulse`), and building the playback engine (flutter_soloud /
miniaudio) needs the ALSA development headers:

```bash
sudo apt install pulseaudio-utils libasound2-dev
```

## Tests

`./run_checks.sh` (or `flutter test`) runs:

* FFT correctness (tone, round-trip, Parseval),
* LDPC encode/decode incl. AWGN at Eb/N0 ≈ 2.5 dB,
* full modem loopback through an impaired channel (noise, gain, delay,
  ±50 ppm sample-clock offset, all four constellations, both widths,
  back-to-back bursts),
* the ARQ protocol (message ack, file transfer, NAK recovery, file
  request, listing) over a simulated block-loss channel,
* a complete two-station end-to-end exchange over the simulated audio path.

## Offline analysis (PCM files)

For demod testing and offline analysis, transmissions can be captured to a
raw PCM file: **Channel tab → Write PCM…** picks the file, **Close** ends
the capture. The format is mono, 48 kHz, 64-bit IEEE 754 little-endian
floats (`.f64`); only transmitted bursts are written — idle time adds
nothing, so a capture of N bursts is simply the N waveforms back to back.
Load one in Python with `numpy.fromfile(path, dtype='<f8')`, or play it
with `sox -t f64 -r 48000 -c 1 capture.f64 -d`.

**Read PCM** (next to Start/Stop in the status bar) does the reverse: it
feeds a chosen PCM file into the receiver exactly as if the samples had
arrived from the audio interface — sync, decode, ARQ responses and all.

**hc_info** (`tools/`) is a command-line inspector for capture files: it
demodulates every burst with the same DSP/LDPC code as the app and prints
the burst headers (callsigns, modulation, code rate, flags, block counts)
plus the type and fields of every packet inside. Build it with `make` in
`tools/src` (needs dart/flutter on PATH, or pass `DART=`/`FLUTTER=`), then:

```bash
tools/hc_info capture.f64            # auto-detects narrow/wide
tools/hc_info -v --width narrow capture.f64
```

**hc_gen** (`tools/`) is its counterpart: it generates a complete message
burst as PCM using the app's own modulator — handy for producing known-good
test vectors for demod work. Without `-o` the samples go to stdout:

```bash
tools/hc_gen --call W1AW --dest KD2XYZ -m "test message" -o test.f64
tools/hc_gen --mod 16-qam --ldpc 3/4 -m "hi" | tools/hc_info /dev/stdin
```

Both tools build from the same Makefile in `tools/src` (committed as
`hc_info.mk`; rename to `Makefile` or run `make -f hc_info.mk`).

## Quick start without a radio

Channel tab → enable **Loopback test mode** → Start. Anything you transmit
is decoded by your own receiver, which exercises the whole chain.
