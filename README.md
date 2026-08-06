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

## Download

Grab the latest build for your platform from the
[releases page](https://github.com/dj-on-github/hamchannel/releases/latest):

- [Windows (x64) (.zip)](https://github.com/dj-on-github/hamchannel/releases/latest/download/hamchannel-windows-x64.zip) — 64-bit Windows 10/11 (audio cables only; no Bluetooth radio support on Windows yet).
- [macOS (.dmg)](https://github.com/dj-on-github/hamchannel/releases/latest/download/hamchannel-macos.dmg) — unsigned; on first launch right-click the app and choose **Open**.
- [Linux (x64) (.tar.gz)](https://github.com/dj-on-github/hamchannel/releases/latest/download/hamchannel-linux-x64.tar.gz) — extract and run `hamchannel` (needs `pulseaudio-utils`; see [Building & running](#building--running)).
- [Android (.apk)](https://github.com/dj-on-github/hamchannel/releases/latest/download/hamchannel-android.apk) — enable "install from unknown sources" to sideload.
- [iOS (.ipa)](https://github.com/dj-on-github/hamchannel/releases/latest/download/hamchannel-ios.ipa) — unsigned; install with a sideloading tool such as AltStore or Sideloadly.

Desktop builds are the primary target for on-air use. The macOS and iOS
builds are unsigned, and the Android APK is signed with a debug key.

## Physical layer

| Profile | Occupancy | Subcarriers | Audio span | Net @ QPSK 1/2 |
|---|---|---|---|---|
| HF | 2.8 kHz (SSB) | 52 | 375 Hz – 2.81 kHz | 1.9 kbit/s |
| 4 kHz | 4 kHz | 64 | 750 Hz – 3.75 kHz | 2.3 kbit/s |
| 6 kHz | 6 kHz | 112 | 750 Hz – 6.0 kHz | 4.1 kbit/s |
| 8 kHz | 8 kHz | 152 | 750 Hz – 7.9 kHz | 5.5 kbit/s |
| 10 kHz | 10 kHz | 192 | 750 Hz – 9.75 kHz | 7.0 kbit/s |
| Narrow | 12 kHz | 240 | 750 Hz – 12 kHz | 8.75 kbit/s |
| Wide | 24 kHz | 480 | 750 Hz – 23.25 kHz | 17.5 kbit/s |

All profiles share the modulations, LDPC codes and frame format — only
the subcarrier count differs. The 4–10 kHz ladder exists to find how much
bandwidth a given radio's audio path actually passes cleanly; step down
until the link is solid. On SSB (HF profile), both stations must be tuned
within a few hertz — the modem has no carrier-frequency search.

* 48 kHz sample rate, 1024-point FFT (46.875 Hz spacing), 1/8 cyclic prefix,
  24 ms symbols.
* Subcarrier modulation: **BPSK, QPSK, 16-QAM or 64-QAM** (Settings tab).
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
5. **Settings** — channel width (HF/narrow/wide), subcarrier modulation,
   LDPC rate, callsigns, audio input/output device selection, TX level,
   VOX leader length, PCM capture, FCC Logging, loopback test mode.

## FCC Logging

FCC Part 97 does not generally require a station log, but keeping one that
can be produced on request is a long-standing recommendation. Enable **FCC
Logging** in the Settings tab, choose a log file (remembered across
restarts), and the app appends one line for every transmission and
reception:

```
Tx 2026-07-15 21:04:03Z W1AW KD2XYZ 12kHz OFDM-240 LDPC-1/2 MSG "hello"
Rx 2026-07-15 21:04:11Z KD2XYZ W1AW 12kHz OFDM-240 LDPC-1/2 MSG_ACK
```

Fields: direction (Tx/Rx), UTC date and time, sender callsign, recipient
callsign, channel bandwidth, modulation format (`OFDM-<subcarriers>`),
LDPC code rate, and the content (message text, or a summary of file
transfer / control packets).

## Radio wiring (VOX keying)

```
laptop headphone out ──[attenuator 10:1 or isolation transformer]──▶ radio mic in
radio speaker/data out ──────────────────────────────────────────▶ laptop mic in
```

* Enable VOX on the radio. Increase **VOX leader** (Settings tab) if the
  start of bursts is clipped; 360 ms suits most HTs.
* Set radio and laptop volumes so the **RX meter moves to mid-scale without
  clipping**; keep **TX level** low enough that the FM deviation stays clean
  — overdriving the mic input is the most common cause of decode failures.
* 12 kHz mode fits a 12.5 kHz channel only through a flat "9600-baud" data
  port; through ordinary mic/speaker paths expect the upper carriers to be
  attenuated (the equalizer copes with moderate roll-off, but narrow +
  lower-order modulation is the robust choice).

## Bluetooth handy-talkie radios (no cables)

Radios in the Benshi family (BTech **UV-Pro**, **GA-5WB**, Vero **VR-N76**,
RadioOddity and compatible models) expose their audio path over Bluetooth
Classic. HamChannel can use that instead of audio cables:

* Pair the radio in the **system Bluetooth settings** first.
* In the **Settings** tab set **Audio connection** to *Bluetooth
  handy-talkie radio* and pick the radio from the pulldown (Rescan re-reads
  the paired list).
* Press **Start** as usual. Received audio arrives over the radio's
  Bluetooth audio channel, and transmitted bursts are streamed to the radio,
  which **keys its own transmitter** while audio frames arrive — no VOX and
  no PTT wiring (the VOX leader setting is not used in this mode).

The radio's Bluetooth audio uses the SBC codec (32 kHz mono); the modem
resamples between its native 48 kHz and the radio's 32 kHz. All bandwidth
profiles up to 12 kHz work through this path; the 24 kHz wide profile does
not fit in the radio's audio passband.

Supported on **macOS** (IOBluetooth) and **Linux** (BlueZ; the build needs
`libbluetooth-dev` and GLib/GIO, see below). Windows is not wired up yet —
use audio cables there.

**If transmit audio stutters** (most often seen on macOS): the radio also
registers as a Bluetooth *headset* with the OS, and our audio shares the
2.4 GHz link with everything else on it. Make sure the radio is never
selected as the system sound input/output, disconnect other Bluetooth audio
devices (especially anything with an active microphone — headset SCO mode
reserves radio slots), prefer 5 GHz Wi-Fi or none during operation, and
keep the radio away from USB-3 hubs. HamChannel transmits SBC at the
radio's native bitpool 18 with loudness allocation — the firmware's
most-tested format and half the airtime of higher bitpools; raising the
bitpool in `bt_radio_backend.dart` buys codec SNR only on a clean link.
Note that voice apps can sound fine over a link that still glitches too
often for OFDM bursts — speech hides 20 ms dropouts, a modem doesn't.

The Bluetooth transport (RFCOMM channel handling, SBC codec, frame pacing)
is adapted from [HTCommander](https://github.com/Ylianst/HTCommander) by
Ylian Saint-Hilaire (Apache-2.0), reused with the author's permission.

## Building & running

```bash
flutter pub get
flutter run -d macos      # or -d linux / -d windows
```

macOS: microphone permission is requested on first start
(`NSMicrophoneUsageDescription` is set in `macos/Runner/Info.plist`; the
`com.apple.security.device.audio-input` entitlement must be present in
`DebugProfile.entitlements` / `Release.entitlements`).

Linux: the device pulldowns list each PulseAudio/PipeWire **port**
separately (e.g. "CUBILUX CB5 Analog Stereo — Line In" vs "… — Microphone"),
because Pulse models physical jacks as ports of one device; selecting an
entry switches the port automatically (`pactl set-source-port` /
`set-sink-port`) when the modem starts. Audio capture uses PulseAudio's
`parecord` (works under PipeWire via `pipewire-pulse`), and building the
playback engine (flutter_soloud / miniaudio) needs the ALSA development
headers:

```bash
sudo apt install pulseaudio-utils libasound2-dev
```

Bluetooth radio support on Linux additionally needs the BlueZ and GIO
development packages at build time:

```bash
sudo apt install libbluetooth-dev libglib2.0-dev
```

Note the `bluez` package alone is **not** enough — it only contains the
daemon and tools. The headers and `bluez.pc` file CMake looks for are in
`libbluetooth-dev` (Fedora: `bluez-libs-devel`, Arch: `bluez-libs`).

## Tests

`./run_checks.sh` (or `flutter test`) runs:

* FFT correctness (tone, round-trip, Parseval),
* LDPC encode/decode incl. AWGN at Eb/N0 ≈ 2.5 dB,
* full modem loopback through an impaired channel (noise, gain, delay,
  ±50 ppm sample-clock offset, all four constellations, both widths,
  back-to-back bursts),
* the ARQ protocol (message ack, file transfer, NAK recovery, file
  request, listing) over a simulated block-loss channel,
* a complete two-station end-to-end exchange over the simulated audio path,
* the Bluetooth audio chain: 0x7e framing, the 48↔32 kHz resampler, an SBC
  codec round trip, and full modem bursts pushed through the exact
  SBC/framing path the Bluetooth backend uses.

## Offline analysis (PCM files)

For demod testing and offline analysis, transmissions can be captured to a
raw PCM file: **Settings tab → Write PCM…** picks the file, **Close** ends
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
tools/hc_gen --mod 16-qam --ldpc 3/4 -m "hi" | tools/hc_info
```

**hc_ruin** applies channel defects to a capture, in three stages:
Rician/Rayleigh fading (`--fade-rate`, `--fade-k`), additive Gaussian noise
(`--snr` or `--noise`), and sampling phase noise via 16× oversampled
sample-position jitter (`--pn-sigma` in 1/16-sample steps, `--pn-corr`).
It reads a file or stdin and writes `-o <file>` or stdout, so the three
tools chain into a full offline test bench:

```bash
tools/hc_gen -m "test" | tools/hc_ruin --fade-rate 2 --fade-k 4 \
    --snr 10 --pn-sigma 3 | tools/hc_info
```

**hc_view** renders a constellation-diagram PNG from a capture, mirroring
the app's Signal Quality tab: constellation on the left, the SNR/EVM/BER
and CRC figures as text on the right. With multiple bursts in the file it
renders the last one (`--burst N` selects another):

```bash
tools/hc_gen -m "test" | tools/hc_ruin --snr 8 | tools/hc_view -o quality.png
```

All tools build from the same Makefile in `tools/src` (committed as
`hc_info.mk`; rename to `Makefile` or run `make -f hc_info.mk`).

## Quick start without a radio

Settings tab → enable **Loopback test mode** → Start. Anything you transmit
is decoded by your own receiver, which exercises the whole chain.
