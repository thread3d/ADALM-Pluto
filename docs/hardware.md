# Hardware, host and the USB layer

What the radio is, what this board provides, and which of the Pluto's several USB faces you are
looking at. Everything marked *observed* was read off this machine; everything marked *measured* was
read back from the radio itself on 2026-11-10 and is no longer a datasheet claim.

## Host

| | |
|---|---|
| Board | NVIDIA Jetson AGX Xavier (`xavieragx`, `xavieragx.local` = 192.168.0.81) |
| Architecture | `aarch64` |
| Kernel | `5.10.104-tegra` |
| Distribution | Ubuntu 20.04 (focal), gcc 9.4.0, GNU Make 4.2.1 |
| USB controllers | `tegra-xusb`: bus 1 at 480 Mbit/s, bus 2 at 10000 Mbit/s |

The bus matters. `lsusb -t` on this board shows bus 1 with a chain of four-port hubs hanging off
port 4, and *observed* the Pluto enumerated at **`1-4.4.3`** — port 4, then hub port 4, then hub port
3. Three hubs between the SoC and the radio, on the 480 Mbit/s bus.

## The radio

| | |
|---|---|
| Model | ADALM-PLUTO (PlutoSDR), Analog Devices |
| USB ID | `0456:B673` *(observed)* |
| bcdDevice | `6.01` *(observed)* |
| Serial | `104473ae73930001fdff27009d682d6d06` *(observed)* |
| Manufacturer string | `Analog Devices Inc.` *(observed)* |
| Product string | `PlutoSDR (ADALM-PLUTO)` *(observed)* |
| Transceiver | AD9363 — 2 RX, 2 TX, full duplex, 12-bit ADC and DAC *(datasheet)* |
| Tuning | 325 MHz to 3.8 GHz, stock *(datasheet)*; OGN lives at 868.2 / 868.4 MHz, comfortably inside |
| Sample rate | `sampling_frequency_available = [2083333 1 61440000]` *(measured)* — floor 2.083333 MSPS, ceiling 61.44 MSPS, step 1 Hz |
| RX gain | `hardwaregain_available = [-1 1 73]` in manual mode *(measured)* — −1 to 73 dB, 1 dB steps |
| Sample format | 12-bit signed, shift 0, on `cf-ad9361-lpc` voltage0/voltage1 *(measured)* |
| Frequency control | `xo_correction` = 39 999 890 Hz, range `[39991891 1 40007889]` *(measured)* — a real ppm trim, ±200 ppm with 1 Hz (0.025 ppm) resolution |
| IIO interface | interface 5 of the composite gadget *(measured)* |
| Host link | USB 2.0 OTG, 480 Mbit/s |
| Power | bus-powered from the USB port; no separate DC input |

### The 2.083 MSPS floor is real — but only for the plain attribute

`sampling_frequency` on `voltage0` reports `[2083333 1 61440000]`, and 1.0, 2.0 and 2.048 MSPS are
all rejected through it. **That is what the HB decimator chain alone can do, not what the chip can
do.**

`ad9361_set_bb_rate()` from libad9361 designs and loads an RX FIR with decimation up to ÷4 *in
addition* to the HB stages, and reaches far below the attribute's floor. Measured on this board:

| `ad9361_set_bb_rate()` | Applied | ADC clock | HB | FIR | Out |
|---|---|---|---|---|---|
| 1 000 000 | **999 999 Hz** | 32 MHz | ÷2 ÷2 → 8 M | ÷4 | 1.0 MSPS |
| **2 000 000** | **1 999 999 Hz** | **64 MHz** | ÷2 ÷2 → 16 M | ÷4 | **2.0 MSPS** |
| 2 083 333 | 2 083 332 Hz | 66.7 MHz | ÷2 ÷2 → 16.7 M | ÷2 | 2.083 MSPS |

So exactly 2.0 MSPS **is** available from the chip, with the converter running at 64 MHz and every
decimation stage on-chip. An earlier version of this file claimed 2.0 MSPS was impossible; that was
true only of the attribute, and wrong about the chip. (The library is installed here:
`/usr/include/ad9361.h`, `libad9361.so`.)

### Why exactly 2.000 MSPS decides itself: the FFT size

`Inp_FFT::Preset()` in `ogn-rf.cc` computes

```cpp
FFTsize = (8*8*SampleRate)/15625;      // note 8*8, not 8
```

| ogn-rf `SampleRate` | OGN FFTsize | factorisation | FFTW |
|---|---|---|---|
| 1 000 000 | 4096 | 2¹² | fast |
| **2 000 000** | **8192** | **2¹³** | **fastest** |
| 2 048 000 | 8388 | 2²·3²·**233** | slow |
| 2 083 333 | 8533 | 7·**23**·**53** | slow |

At exactly 2.0 MSPS the transform is a power of two; at 2.0833 it is 8533 = 7×23×53, which FFTW must
run through generic codelets. That settles the rate question on grounds that have nothing to do with
USB or the ADC — and it is the argument for `ad9361_set_bb_rate(2000000)`.

(An earlier entry here compared 1024 with 1066. Those are `GSM_FFT` sizes — the GSM calibration
spectrogram, which does use `8*SampleRate/15625`. The OGN demodulator path uses `8*8*`.)

### Bandwidth: 4 MHz, not 56

Measured at 100 MHz (FM broadcast), 2.0 MSPS, gain 73 dB:

| `rf_bandwidth` | rms %FS | peak %FS |
|---|---|---|
| 1 MHz — what `ad9361_set_bb_rate` picks unaided | 8.8 | 61.0 |
| 2 MHz | 11.1 | 71.9 |
| **4 MHz** | **11.5** | **73.8** |
| 8 MHz | 11.5 | 69.1 |
| 18 MHz — the driver default | 9.0 | 52.1 |
| 56 MHz | 6.5 | 47.3 |

4 MHz, about twice the output rate, recovers ~5 dB over 56 MHz. A wider analog filter does not
preserve the signal here, it loses it — so a configuration that sets the bandwidth wide "to encourage
a high sample rate" is costing signal for nothing, because the ADC already runs at 64 MHz.

### Measured end to end at exactly 2.0 MSPS

```
ad9361_set_bb_rate(2000000) applied;  RX FIR enabled = 1
RX path rates: ADC 63999999  R2/2 31999999  R1/2 15999999  FIR/4 1999999
4194304 samples (2.097 s): 99.9 % delivered, overhead +2 ms
throughput 1.998 Msps sustained (8.0 MB/s), rms 0.7 %FS, crest 5.34, clipped 0  -> PASS
```

**No software resampling, 8 MB/s of a ~31 MB/s link, and ogn-rf gets a 8192-point FFT.**

### The software decimation option, if it is ever wanted

Still measured, still valid as a fallback (for instance if a future ogn-rf wants a rate the FIR
cannot make). Whole blocks, ≥2 s of data, three repeats per row:

| Chip rate | Decim | Delivered | Into ogn-rf | USB |
|---|---|---|---|---|
| 2 083 334 | ÷1 | 99.8–99.9 % | 2.081 MSPS | 8.3 MB/s |
| 4 000 000 | ÷2 | 99.9 % | 1.998 MSPS | 15.0 MB/s |
| 6 000 000 | ÷3 | 99.9 % | 1.998 MSPS | 23.0 MB/s |
| 8 000 000 | ÷4 | 95.2–95.6 % | ~1.95 MSPS | 31.0 MB/s |
| 10 000 000 | ÷5 | 78.8 % | 1.58 MSPS | over capacity |
| 16 000 000 | ÷8 | 49.5 % | 0.99 MSPS | over capacity |

Above ~7 MSPS the link cannot carry the stream, the device drops samples, and the decimated output
rate falls *below* what was asked for. Whatever the rate, USB saturates near 31 MB/s.

### Gain: measured, and the law is not a straight line

The AD9363's receive gain is one `hardwaregain` attribute in manual mode. **Measured range: −1 to
73 dB in 1 dB steps** (`hardwaregain_available = [-1 1 73]`). One trap: the range reported depends
on the gain mode — read in `slow_attack` it reported `[-3 1 71]`, so read it *after* selecting
`manual` or the numbers move under you.

Where the attribute lives is the other trap. On this firmware **`gain_control_mode` is a channel
attribute of `voltage0` (input) on `ad9361-phy`, not a device attribute.** The device exposes 19
attributes and gain mode is not among them, so code that writes it to the device fails silently and
the radio stays in `slow_attack` while reporting a gain it never applied. (This cost an afternoon.
The probe now tries the channel first and falls back to the device.)

Swept at 868.400 MHz, 4 MSPS, 300 000 samples, 12-bit full scale 2048:

| `hardwaregain` | rms %FS | peak %FS | crest | clipped |
|---|---|---|---|---|
| 0 | 0.2 | 0.7 | 4.20 | 0 |
| 10 | 0.1 | 0.6 | 4.24 | 0 |
| 20 | 0.1 | 0.7 | 4.96 | 0 |
| 30 | 0.1 | 0.7 | 5.15 | 0 |
| 40 | 0.1 | 0.7 | 4.97 | 0 |
| 50 | 0.2 | 0.9 | 4.64 | 0 |
| 60 | 0.3 | 1.3 | 4.58 | 0 |
| 70 | 0.6 | 3.1 | 4.79 | 0 |
| 73 | 0.9 | 4.2 | 4.75 | 0 |

Two things to read carefully in that table:

1. **The law is not 1 dB per dB.** Level barely moves between 0 and 50 dB and then grows from 50 to
   73. The AD9361's gain is staged (LNA, mixer, TIA, digital), so the total is not linear in the
   single number the driver exposes. Anyone expecting `total = a − gRdB` as on the RSPduo will not
   find it here; the table *is* the law.
2. **Nothing clips, even at maximum.** At 73 dB the noise floor is 0.9 %FS. That is a quiet 868 MHz
   and no LNA in the chain — the same conclusion the LimeSDR and RSPduo work reached on this site.

A crest factor of 4.2–5.2 through that sweep is **normal, not compression**: it is the maximum of a
Gaussian sample divided by its rms over 300k samples, which sits near 4.5. The RSPduo repository's
"9–11 is healthy, 3–5 is folding" figure came from a different measurement and does not transfer.

### Real RF, verified

The radio is not merely delivering noise. At maximum gain, 4 MSPS, 300 000 samples:

| Frequency | What is there | rms %FS | peak %FS |
|---|---|---|---|
| 100.000 MHz | FM broadcast | **12.8** | 67.2 |
| 100.500 MHz | FM broadcast | **13.6** | 65.0 |
| 433.920 MHz | ISM band | **8.9** | 50.9 |
| 868.400 MHz | the OGN channel | **0.9** | 4.4 |

That is **+23 dB** of real signal at 100 MHz over the OGN noise floor, which settles the question of
whether the RF path works. What it does not settle is hearing an aircraft: 868.4 MHz measures as
quiet, exactly as it did for the RSPduo and the LimeSDR on this site. A receiver that works and a
sky that is empty look identical from here.

## The Pluto's several USB faces

A Pluto does not present one device, it presents a gadget that can carry several functions. Which
ones are live is a firmware configuration choice:

| Function | What it gives you | Useful for ogn-rf? |
|---|---|---|
| IIO (via libusb) | `ad9361-phy` and the DMA device, reached through libiio over USB | **this is the one** |
| Network (USB Ethernet) | the box at `192.168.2.1`, host at `192.168.2.10`; the same IIO devices over IP | alternative transport, `ip:192.168.2.1` |
| Mass storage | a FAT volume carrying the boot files, used for firmware updates | no — and a warning sign, see below |
| Serial console | a `ttyACM` port into the Pluto's own Linux | handy for diagnosis, not for data |

The *observed* first enumeration bound **mass storage** (`usb-storage 1-4.4.3:1.2`,
`Linux File-Stor Gadget`), not IIO. On its own that is not a fault: the volume is part of how the
device boots and how its firmware is replaced, and a composite gadget can expose it alongside the
others. What made that enumeration a failure was the disconnect four seconds later, before anything
could be read out of it.

The reason to care about which function is up: **libiio over USB needs the IIO function**, and the
network transport needs the ethernet function. If only mass storage is present, `iio_create_context`
has nothing to open, and no amount of rebuilding ogn-rf will change that. `scripts/probe-pluto.sh`
reports which face is showing.

## libiio on this host

*Observed:*

| Component | State | Consequence |
|---|---|---|
| `libiio0` | **0.19-1** installed | runtime present |
| libusb backend | **compiled in** (libusb symbols inside `libiio.so.0`) | USB transport works without a rebuild |
| `libiio-dev` | **0.19-1** installed | a backend and the probe can be compiled here |
| `libusb-1.0-0-dev` | 2:1.0.23-2build1 installed | link with `-liio` only |
| `iio-utils` | **not installed** | no `iio_info` / `iio_attr`; `scripts/probe-pluto.sh` avoids depending on them |
| Python `iio` bindings | **not installed** | no scripting route; the probe is C |
| udev rule for `0456` | **absent** | opening the radio as `threaded` will fail with a permission error |

The udev gap is the same class of problem the RSPduo repo solved with `install-sdrplay-api.sh`:
without a rule, the USB device node is root-owned and `libusb` cannot claim it, so every tool has to
run as root. `scripts/install-pluto-udev.sh` installs the rule in `config/90-libiio-pluto.rules`,
which grants the `plugdev` group access to vendor `0456` and tags it for the active seat.

One version note worth carrying forward: 0.19 is older than the libiio the current ADI docs are
written against (their examples show 0.26). The IIO wire protocol it speaks is stable and the vendor
keeps the Pluto's firmware backward-compatible, but if the context refuses to open while the device
is demonstrably present, an upgraded libiio is the first thing to try — and that needs root, so it is
listed as a decision, not performed.

## Where the OGN signal is, and what "it works" will mean

The European OGN channels are **868.200 and 868.400 MHz**, 200 kHz apart. One 2 MSPS capture covers
both with room to spare, which is why the earlier radios settled on a 2 MSPS stream and a hopping
frequency plan rather than two receivers.

A Pluto bring-up is complete when, on this board:

1. `probe-pluto.sh` reports the device present with the IIO function up;
2. `probe-pluto.sh --capture` produces a spectrum with a real noise floor and no clipping;
3. `ogn-rf` starts, reports the Pluto as its radio, and its status page shows 868.x MHz at the
   configured rate;
4. the gain is set from the measured table above, not guessed.

Note what is *not* on that list: decoding live OGN packets. On this site both OGN channels measured
as noise floor with the RSPduo and the LimeSDR as well, so a quiet sky is the normal result here and
is not evidence about the hardware. A working receiver and a heard aircraft are two different
milestones, and only the first is in our hands.
