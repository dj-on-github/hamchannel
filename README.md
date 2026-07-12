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
4. **Channel** — narrow/wide, subcarrier modulation, LDPC rate, callsigns,
   audio input/output device selection, TX level, VOX leader length,
   loopback test mode.

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
`pipewire-pulse`); install it with:

```bash
sudo apt install pulseaudio-utils
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

## Quick start without a radio

Channel tab → enable **Loopback test mode** → Start. Anything you transmit
is decoded by your own receiver, which exercises the whole chain.
