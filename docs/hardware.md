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

### The sample-rate floor is the defining constraint

The AD9361/AD9363 family cannot produce sample rates below roughly **2.08 MSPS**: the on-chip
decimating filters run out of decimation before that. This is not a Pluto firmware quirk, it is the
chip.

That collides head-on with ogn-rf's habits:

| Wanted | Where it comes from | Reachable on an AD9363? |
|---|---|---|
| 2 048 000 Hz | the RTL-SDR default hard-coded in `rtlsdr.h` and `sdr.h` | **No** — below the floor |
| 1 000 000 Hz | `ogn-rf.cc`'s built-in default `SampleRate`, and the shipped RTL-SDR configs | **No** — below the floor |
| 2 000 000 Hz | what the RSPduo work settled on, and the only rate its ADC offers | Yes, but only by decimating to it |

So the Pluto backend cannot simply pass the requested rate down and expect it back. The shape of the
answer is the `setOversample()` hook that `sdr.h` already carries for the RSPduo: run the AD9363 at a
legal rate and decimate in software to the rate ogn-rf asked for. `docs/ogn-rf-integration.md` works
through the choices; the short version is that **4.0 MSPS on chip, ÷2 in software, gives exactly
2.0 MSPS** with clean integer arithmetic, and 8.0 ÷ 4 or 8.0 ÷ 8 give the same for more USB pressure.

**Measured on 2026-11-10, and the table above is now fact rather than inference:**

| Requested | Result |
|---|---|
| 1 000 000 | **rejected** |
| 2 000 000 | **rejected** |
| 2 083 333 | **rejected** — this is the trap: it is the advertised minimum, but the real divider gives 2 083 333.33 Hz, so asking for the truncated value fails |
| 2 083 334 | accepted, applied **2 083 333 Hz** ← the true floor, and the number to ask for |
| 2 400 000 | applied 2 400 000 Hz |
| 4 000 000 | applied 3 999 999 Hz |
| 30 720 000 | the firmware's own default at power-up |

So `sampling_frequency_available` reporting a minimum of 2083333 is slightly misleading: the value
that works is **2083334**, and everything below it is genuinely impossible. This is why the
decimation design is not a preference — 2.0 MSPS, ogn-rf's default 1.0 MSPS and the RTL-SDR's
2.048 MSPS are all unreachable on this chip.

Read it yourself with:

```bash
./scripts/probe-pluto.sh --capture -v      # prints rate available, gain available and the format
```

### The decimation chain is on-chip already, and USB is the real ceiling

The natural reading of "the Pluto samples fast and decimates internally, so run it fast and hand
2 MSPS to ogn-rf" is that a higher sample rate buys something. Measured, it does not. Two facts
settle it.

**First: `sampling_frequency` is the post-decimation output rate, and the chip decimates on every
setting.** `rx_path_rates` shows the internal chain it picks (BBPLL, ADC clock, HB3 `R2`, HB2 `R1`,
the RX FIR, then the DMA rate), and the ADC clock simply rises with the requested data rate while
the filter chain stays at ÷8:

| Data rate out | ADC clock | R2 | R1 | RX FIR | Out | ADC ÷ out |
|---|---|---|---|---|---|---|
| 2 083 333 | 25.0 MHz | ÷3 → 8.33 M | ÷2 → 4.17 M | ÷2 → 2.08 M | 2 083 333 | **÷12** |
| 4 000 000 | 32.0 MHz | ÷2 → 16 M | ÷2 → 8 M | ÷2 → 4 M | 3 999 999 | ÷8 |
| 8 000 000 | 64.0 MHz | ÷2 → 32 M | ÷2 → 16 M | ÷2 → 8 M | 7 999 999 | ÷8 |
| 15 360 000 | 122.88 MHz | ÷2 → 61.4 M | ÷2 → 30.7 M | ÷2 → 15.36 M | 15 359 999 | ÷8 |
| 61 440 000 | 491.52 MHz | ÷2 → 245.8 M | ÷2 → 122.9 M | ÷2 → 61.44 M | 61 439 999 | ÷8 |

So asking for a **higher** rate does not offload more work onto the chip; it raises the ADC clock,
keeps the same ÷8 filtering, and multiplies what has to cross the USB cable. Only the minimum data
rate gets the extra ÷12.

**Second: the USB link saturates at about 8 MSPS.** Sustained rate actually achieved, 1 000 000
samples per run:

| Requested | Applied | Sustained | USB |
|---|---|---|---|
| 2 083 334 | 2 083 333 | **2.03 Msps** | 8.1 MB/s |
| 4 000 000 | 3 999 999 | **3.85 Msps** | 15.4 MB/s |
| 8 000 000 | 7 999 999 | **7.66 Msps** | 30.6 MB/s |
| 15 360 000 | 15 359 999 | 7.67 Msps | 30.7 MB/s |
| 30 720 000 | 30 719 999 | 8.02 Msps | 32.1 MB/s |
| 61 440 000 | 61 439 999 | 7.94 Msps | 31.7 MB/s |

The chip accepts 61.44 MSPS and the link delivers **8**. Everything above 8 MSPS is accepted and
then silently dropped at ~31 MB/s, which is USB 2.0's real-world ceiling (480 Mbit/s theoretical,
60 MB/s, halved by protocol overhead and two hubs). So "maximum sample rate" on this transport means
**about 8 MSPS**, and running there would throw away three quarters of the samples.

### What to actually configure for 2 MSPS into ogn-rf

**2.000 MSPS cannot come out of the chip at all** — the floor is 2 083 333 Hz, 4 % above it. So a
software step is unavoidable if ogn-rf is to run at exactly 2.0. The cost of each option:

| Chip data rate | On-chip | Software | Into ogn-rf | USB | Verdict |
|---|---|---|---|---|---|
| 2 083 333 | **÷12** | none — but the rate is 2.0833, not 2.0 | 2 083 333 | 8 MB/s | needs ogn-rf at a non-round rate: `SpectrogramFFTsize` becomes 1066, not 1024 |
| **4 000 000** | ÷8 | **÷2 box** | **2 000 000** | **15 MB/s** | safest — most USB headroom for other radios |
| **6 000 000** | ÷8 | **÷3 box** | **2 000 000** | **23 MB/s** | **highest decimation that works** — see below |
| 8 000 000 | ÷8 | ÷4 box | 2 000 000 | 31 MB/s | **loses ~4 % of samples** — see the measured grid below |
| 61 440 000 | ÷8 | ÷32 box | 2 000 000 | impossible | link delivers 8 MSPS, not 61 |

Any of these lands on ogn-rf's natural rate for a reason that is not arbitrary: **8 × 2 000 000 /
15 625 = 1024 exactly**, so the spectrogram is a power-of-two FFT as its author intended. At
2.0833 MSPS the same expression gives 1066, and at the RTL-SDR's 2.048 it gives 1048.

Which chip rate to use within that group is a measured question, not a stylistic one — and the answer
turned out to be the *higher* one, up to a hard ceiling. See the next section.

**Measured, with the ÷2 stage implemented in `pluto_probe -D 2`:**

```
chip 3 999 999 Hz  ->  1 000 000 samples out at exactly 2 000 000 Hz
  undecimated: rms 0.8 %FS, peak 4.1 %FS, crest 5.21, clipped 0
  decimated:   rms 0.7 %FS, peak 3.3 %FS, crest 5.02, clipped 0
```

The averaged stream is ~1/√2 of the input as a box filter over independent noise should be, the
crest factor holds, and nothing clips. The box filter is the same shape as ogn-rf's own
`boxfilter.h`.

### How far the decimation can go: 6 MSPS ÷ 3 is the ceiling

Every chip rate that divides exactly to 2.0 MSPS, each captured for at least 2 seconds of data:

| Chip rate | Decim | Delivered | Overhead | Real output rate | Verdict |
|---|---|---|---|---|---|
| 4 000 000 | ÷2 | 98.4 % | +33 ms | 1.968 MSPS | clean |
| **6 000 000** | **÷3** | **99.4 %** | **+12 ms** | **1.988 MSPS** | **clean — the best of them** |
| 8 000 000 | ÷4 | 95.8 % | +86 ms | 1.930 MSPS | **loses ~4 %** |
| 10 000 000 | ÷5 | 78.0 % | +563 ms | 1.561 MSPS | loses 22 % |
| 12 000 000 | ÷6 | 65.3 % | +1063 ms | 1.306 MSPS | loses 35 % |
| 16 000 000 | ÷8 | 48.6 % | +2113 ms | 0.973 MSPS | loses 51 % |

The borderline three repeated three times each, because one run is not evidence:

```
4 MSPS /2 : 98.4%/+33ms ok    98.3%/+34ms ok    98.4%/+33ms ok
6 MSPS /3 : 99.4%/+12ms ok    99.4%/+12ms ok    99.4%/+12ms ok
8 MSPS /4 : 96.1%/+81ms LOSS  95.9%/+85ms LOSS  95.6%/+92ms LOSS
```

So **6 MSPS ÷ 3 is the highest decimation that still delivers exactly 2.0 MSPS**, and it is not a
marginal case: 99.4 % delivered with 12 ms of overhead, reproducible. 8 MSPS sits on the edge of what
the link carries and drops about 4 % of samples — and a stream with holes in it is worse for ogn-rf
than a slower one, because a time slot that is missing samples does not decode.

Above 8 MSPS the requested rate is simply not delivered: the real output rate falls to 1.56 / 1.31 /
0.97 MSPS for requests of 10 / 12 / 16 MSPS. Asking for a higher rate makes the receiver *slower*,
which is the opposite of the intuition that started this test.

### Telling buffering latency from lost samples

A short capture reads below 100 % for a reason that is not loss, and getting this wrong makes a
healthy link look broken — the probe did exactly that for a while:

```
wall = n / rate + L          L is a fixed startup latency  -> the shortfall SHRINKS with length
wall = n / (k x rate)        k < 1, samples dropped        -> the shortfall is CONSTANT
```

Measured at 4 MSPS: 95.2 % over 0.5 s and 98.4 % over 2 s — the same ~33 ms of latency, not a bigger
loss. At 10 MSPS the excess *grew* with length (0.162 s over 0.6 s of data, 0.328 s over 1.2 s),
which is loss. So the probe now reports overhead in milliseconds and only declares loss when the
capture is long enough (≥1.5 s of data) for a fixed latency to be small.

One more caveat worth carrying: **that ~31 MB/s ceiling is shared with every other SDR on this
board.** The RSPduo, the LimeSDR and five RTL-SDRs were unplugged for these measurements. 6 MSPS
÷ 3 uses 23 MB/s of the ~31, leaving little room for anything else; 4 MSPS ÷ 2 uses 15 MB/s and
leaves twice the headroom for the same 2.0 MSPS output. If other radios are streaming at the same
time, 4 ÷ 2 is the safer choice.

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
