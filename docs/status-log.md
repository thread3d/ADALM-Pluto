# Status log

Dated observations, newest last. The point of this file is that a later session can tell what was
actually seen from what was assumed — so entries record the command and its output, not a summary
written from memory.

---

## 2026-11-10 — repository created; the radio falls off the bus

### What is in place

`~/projects/ADALM-Pluto/adalm-pluto` is a git repository holding the tooling and documents for the
Pluto bring-up, and `~/projects/ADALM-Pluto/ogn-rf` is a clone of `thread3d/ogn-rf` with an
`adalm-pluto` branch for the code changes. The sibling projects (`RSPduo`, `LimeSDR`, `KrakenSDR`)
set this shape: one repository per radio for scripts and measurements, one device branch in ogn-rf
for the backend.

Host recon at the time of writing:

```
$ uname -sr            Linux 5.10.104-tegra      (aarch64)
$ dpkg -l libiio0     ii  libiio0:arm64   0.19-1
$ dpkg -l libiio-dev  ii  libiio-dev:arm64 0.19-1
$ ls /usr/bin/iio*    ls: cannot access '/usr/bin/iio*': No such file or directory
$ grep -ril 0456 /lib/udev/rules.d/ /etc/udev/rules.d/    (no output)
```

So: the library and its headers are there, the command-line tools are not, and nothing grants a
non-root user access to the USB device.

### The device was present for four seconds

`lsusb` shows no Analog Devices device now, but the kernel log has it:

```
Nov 10 10:44:55 xavieragx kernel: usb 1-4.4.3: new high-speed USB device number 21 using tegra-xusb
Nov 10 10:44:55 xavieragx kernel: usb 1-4.4.3: New USB device found, idVendor=0456, idProduct=b673, bcdDevice= 6.01
Nov 10 10:44:55 xavieragx kernel: usb 1-4.4.3: New USB device strings: Mfr=1, Product=2, SerialNumber=3
Nov 10 10:44:55 xavieragx kernel: usb 1-4.4.3: Product: PlutoSDR (ADALM-PLUTO)
Nov 10 10:44:55 xavieragx kernel: usb 1-4.4.3: Manufacturer: Analog Devices Inc.
Nov 10 10:44:55 xavieragx kernel: usb 1-4.4.3: SerialNumber: 104473ae73930001fdff27009d682d6d06
Nov 10 10:44:55 xavieragx kernel: usb-storage 1-4.4.3:1.2: USB Mass Storage device detected
Nov 10 10:44:55 xavieragx kernel: scsi host0: usb-storage 1-4.4.3:1.2
Nov 10 10:44:56 xavieragx kernel: scsi 0:0:0:0: Direct-Access     Linux    File-Stor Gadget 0601 PQ: 0 ANSI: 2
Nov 10 10:44:56 xavieragx kernel: sd 0:0:0:0: Power-on or device reset occurred
Nov 10 10:44:59 xavieragx kernel: usb 1-4.4.3: USB disconnect, device number 21
```

Four readings of that sequence:

1. **The device and the cable are not dead.** It enumerated at high speed, gave its strings and a
   serial number, and bound a driver. A broken cable or an unpowered device does not get that far.
2. **It presented mass storage, not IIO.** `usb-storage` claimed interface 2. That is the firmware
   volume, which is how a Pluto is reflashed — it is not the face libiio opens over USB. Whether the
   IIO function was also present but simply unclaimed is unknown: the device left before anything
   could ask it.
3. **The device reset itself.** `Power-on or device reset occurred` is the SCSI layer reporting that
   the target went away and came back at the same address, immediately before the USB disconnect.
   That is a device-side event, not a host-side unplug.
4. **It never came back.** Nothing has enumerated on `1-4.4.3` since, and `lsusb` at 10:51 shows no
   `0456:` device on any bus.

### Candidate causes, and the test that tells them apart

| Cause | Consistent with the log? | Discriminating test |
|---|---|---|
| **Brown-out / insufficient current** | **Yes** — bus-powered device, three hubs deep, reset 1 s after the FAT volume was scanned, then gone | Move it to a **direct** port on the Xavier, or a powered hub. If it stays up, it was power. |
| Cable marginal or charge-only data path | Yes — it did enumerate, so the data lines work; a marginal cable can still drop under load | Try a known-good short cable |
| Firmware configured for mass-storage boot | Partly — explains the mass-storage face, not the reset and disconnect | Read the FAT volume's config; but it has to stay up long enough to mount |
| USB port or hub fault on the host | Possible — the RTL-SDR bank sits on the neighbouring hub (`1-4.3`) | Move to a different physical port and watch the log |
| Device hardware fault | Possible, least pleasant, and not yet excluded | A powered port plus a good cable, and see whether it enumerates elsewhere |

The order above is the order to try them, because the first is both the most likely and the cheapest
to test. Watching for the re-appearance is one command:

```bash
journalctl -kf | grep -E "usb 1-|0456|b673"
```

A healthy outcome looks like the enumeration above followed by **no** disconnect line, plus an
`iio:deviceN` under `/sys/bus/iio/devices/` and — if the ethernet function is up — an interface with
`192.168.2.x`.

### What is blocked, and what is not

Blocked until the link is stable: reading `sampling_frequency_available` and the real gain range,
measuring the gain law, running the receive probe, and writing the actual `plutosdr.h` backend.

Not blocked, and done: the repository, the diagnosis tooling, the udev rule, and the design for the
backend with its open questions stated. The probe in `src/pluto_probe.c` compiles against this
board's libiio 0.19 today, so the day the device stays connected, the first measurement is one
command away.

### What was actually verified, and what was not

Being precise about this is the point of the section, because "it compiles" and "it works" are
different claims:

| Claim | Status |
|---|---|
| `src/pluto_probe.c` builds against this board's libiio 0.19 | **verified** — `gcc -O2 -Wall -Wextra`, exit 0, no warnings |
| It fails cleanly when no radio is present | **verified** — scans, finds only `local:`, refuses it, names the three causes, exit 1 |
| It fails cleanly on an unopenable context | **verified** — `-u usb:9.9.9` exits 1 with the reason |
| `scripts/probe-pluto.sh` diagnoses the current state | **verified** — reproduces the failure above and names it |
| Its `--brief` mode emits one line and nothing else | **verified** — `FAIL`, exit 1; refuses `--brief --capture` with exit 2 |
| `config/ogn-rf-pluto.conf` is syntactically valid and its keys resolve | **verified** — parsed with the KrakenSDR prefix's libconfig; the RSPduo config parsed as a control |
| Any of it receives a signal | **not verified** — no radio |
| `sampling_frequency_available`, the gain range, the rate floor | **not read** — these come from the device |
| `plutosdr.h` exists at all | **no** — design only, deliberately |

One more finding from the same session, because it will bite later: this board has **no
`libconfig-dev` and no `librtlsdr-dev`**. The existing ogn-rf binaries link against a prefix built
from source by the KrakenSDR work at `~/projects/KrakenSDR/krakensdr/deps/prefix`. `libiio` 0.19, by
contrast, *is* a system library. `docs/ogn-rf-integration.md` records the build line that follows
from that.

---

## 2026-11-10 11:02 — the radio comes back, and fails earlier

Re-plugged by hand at 11:02:31 while the repository was being written. It enumerated again, on the
**same port**, and this time it did not even get as far as configuring:

```
Nov 10 11:02:31 xavieragx kernel: usb 1-4.4.3: new high-speed USB device number 22 using tegra-xusb
Nov 10 11:02:32 xavieragx kernel: usb 1-4.4.3: New USB device found, idVendor=0456, idProduct=b673, bcdDevice= 6.01
Nov 10 11:02:32 xavieragx kernel: usb 1-4.4.3: New USB device strings: Mfr=1, Product=2, SerialNumber=3
Nov 10 11:02:32 xavieragx kernel: usb 1-4.4.3: can't set config #1, error -71
```

`-71` is `EPROTO`, a protocol error on the control transfer. The device is on the bus and
unconfigured: `/sys/bus/usb/devices/1-4.4.3/bConfigurationValue` is **empty**, no interface bound, no
IIO device, no storage volume, no `ttyACM`, and — unlike the 10:44 attempt — the sysfs entries for
`product`, `manufacturer` and `serial` are **absent**, so the string descriptors never came back
either.

### This revises the earlier entry

The first entry called a brown-out on a bus-powered hub "the leading suspect". Reading the
configuration descriptors says that story does not hold as written:

| Device / hub | Port | Config `bmAttributes` | Declares |
|---|---|---|---|
| `USB2.1 Hub` (0bda:5411) | `1-4` | `0xE0` | **self-powered** |
| `USB2.1 Hub` (0bda:5411) | `1-4.4` | `0xE0` | **self-powered** |
| `Microchip Hub` (0424:2517) | `1-4.3` | `0xE0` | **self-powered** |
| `LimeSDR-USB` | `1-4.4.1` | `0x80` | bus-powered, 100 mA |
| `RSPduo` | `1-4.4.2` | `0x80` | bus-powered, 400 mA |
| **`PlutoSDR`** | `1-4.4.3` | `0x80` | bus-powered, **500 mA** |

Both hub levels above the Pluto declare themselves self-powered with `bMaxPower` 0, so they claim not
to be drawing their budget from the host — which means the port should be able to give the Pluto the
500 mA it asks for, and a shared-current story at the hub is **not supported by the descriptors**.

Worth keeping in mind, honestly: cheap hubs are known to set the self-powered bit while actually
running off upstream VBUS, and nothing here can measure the port. So this is "the descriptors do not
support the hypothesis", not "power is ruled out".

### What the two failures have in common

| | 10:44:55 | 11:02:32 |
|---|---|---|
| Enumerated at high speed | yes | yes |
| String descriptors read | **yes** (product, manufacturer, serial) | **no** (absent from sysfs) |
| Reached SET_CONFIGURATION | **yes** — `usb-storage` bound interface 2 | **no** — `EPROTO` |
| Survived | 4 s, then reset and dropped | never configured |

Two different failure points on the same port, both intermittent, with the device getting *worse* on
the second attempt. That pattern — intermittency plus an early protocol error plus progressively
degraded enumeration — is what a **marginal physical connection** looks like: a cable, a connector, or
a solder joint that makes contact differently each time it is plugged in.

### Recommended order of tests, cheapest first

1. **A different cable.** Now the leading suspect rather than the fallback. It has to be a real data
   cable, short, and known good.
2. **A different port — and there is a good one free.** The USB3.2 hubs on bus 002 (`2-4` and
   `2-4.4`) are self-powered and have **all four ports each unused**. A USB 2.0 device works normally
   in a USB 3.x hub port. This also takes the Pluto off the hub it shares with the RSPduo and the
   LimeSDR.
3. **Power-cycle the Pluto properly.** Its only power source is that USB port, so unplugging it is
   the power cycle; give it at least 15 s for the bulk capacitance to drain before replugging.
4. **If it configures and then drops at ~4 s again**, the remaining suspect is the Pluto's own 5 V to
   core supply — a board fault, not a host one.

None of these need root, and `probe-pluto.sh` reports the result of each in one line:

```bash
./scripts/probe-pluto.sh --brief     # OK / FAIL
./scripts/probe-pluto.sh             # and, when FAIL, which of the modes it is
```

### What is still blocked

Everything in `docs/ogn-rf-integration.md`'s "Open questions" list, for the same reason as before:
`sampling_frequency_available`, the gain range and the conversion scale all live on the device, and
the device has to survive configuration before any of them can be read. The tooling to read them the
moment it does — `probe-pluto.sh --capture` — is written, compiled and waiting.

---

## 2026-11-10 11:09 — re-seated with the rest of the bus emptied

By hand: RTL-SDR bank, LimeSDR and RSPduo unplugged, then the Pluto re-seated. It failed again, and
the failure is now much better constrained.

```
Nov 10 11:09:14 xavieragx kernel: usb 1-4.3.5: new high-speed USB device number 27 ... RTL2838UHIDIR
Nov 10 11:09:23 xavieragx kernel: usb 1-4.3:   USB disconnect, device number 23   <- RTL bank gone
Nov 10 11:09:25 xavieragx kernel: usb 1-4.4.1: USB disconnect, device number 8    <- LimeSDR gone
Nov 10 11:09:27 xavieragx kernel: usb 1-4.4.2: USB disconnect, device number 14   <- RSPduo gone
Nov 10 11:09:42 xavieragx kernel: usb 1-4.4.3: USB disconnect, device number 22   <- Pluto unplugged
Nov 10 11:09:57 xavieragx kernel: usb 1-4.4.3: new high-speed USB device number 29 using tegra-xusb
Nov 10 11:09:58 xavieragx kernel: usb 1-4.4.3: New USB device found, idVendor=0456, idProduct=b673, bcdDevice= 6.01
Nov 10 11:09:58 xavieragx kernel: usb 1-4.4.3: Product: PlutoSDR (ADALM-PLUTO)
Nov 10 11:09:58 xavieragx kernel: usb 1-4.4.3: Manufacturer: Analog Devices Inc.
Nov 10 11:09:58 xavieragx kernel: usb 1-4.4.3: SerialNumber: 104473ae73930001fdff27009d682d6d06
Nov 10 11:09:58 xavieragx kernel: usb-storage 1-4.4.3:1.2: USB Mass Storage device detected
Nov 10 11:09:58 xavieragx kernel: scsi host0: usb-storage 1-4.4.3:1.2
Nov 10 11:09:59 xavieragx kernel: usb 1-4.4.3: USB disconnect, device number 29
```

| | 10:44:55 | 11:02:32 | **11:09:58** |
|---|---|---|---|
| Other devices on the bus | 5 RTL-SDRs, LimeSDR, RSPduo | same | **none — keyboard and mouse only** |
| String descriptors read | yes | no | **yes** |
| Configured | yes, storage bound | no, `EPROTO` | **yes, storage bound** |
| Survived | ~4 s | never | **~1 s** |

### What this settles

The shared-current explanation is now dead. At 11:09 the radio had the whole bus to itself — no
RSPduo, no LimeSDR, five fewer dongles — and it still fell off, faster than before. Whatever is wrong
does not depend on what else is plugged in, so the host's power budget is not the cause and no amount
of freeing up ports will fix it by itself.

What remains is a short list, and it is no longer about the host at all:

1. **The cable**, still untested — everything so far used the same one.
2. **The radio's own 5 V rail or USB PHY**, which would explain a reset that arrives sooner as the
   board gets less stable rather than later.
3. **The firmware on the device** — it consistently reaches the point of presenting its mass-storage
   volume and then restarts, which is also what a half-broken boot looks like.

All three are physical. Note also that the port has not changed across any of the three attempts:
`1-4.4.3`, behind two Realtek hubs. A **direct root port** has not actually been tried yet, and the
bus is now clear enough that one is free — bus 001 port 3, where the RTL-SDR hub used to be.

### New tooling for a device that lives one second

`scripts/watch-pluto.sh` polls the USB, IIO, serial and block layers five times a second, logs every
state change with a timestamp, and dumps the descriptors and interface map each time the device
appears. One to two seconds is far too short to inspect by hand, and this makes the next replug
produce evidence instead of another shrug:

```bash
./scripts/watch-pluto.sh -d 300      # then replug the radio while it runs
grep -A6 "device appeared" pluto-watch-*.log
```

---

## 2026-11-10 11:12 — external power. It works.

The radio was given **external power** and re-seated. It has not dropped since.

```
Nov 10 11:12:30 xavieragx kernel: usb 1-4.4.3: new high-speed USB device number 30 ...
Nov 10 11:12:30 xavieragx kernel: usb 1-4.4.3: Product: PlutoSDR (ADALM-PLUTO)
Nov 10 11:12:31 xavieragx kernel: usb 1-4.4.3: USB disconnect, device number 30
Nov 10 11:12:41 xavieragx kernel: usb 1-4.4.3: new high-speed USB device number 31 ...
Nov 10 11:12:41 xavieragx kernel: usb 1-4.4.3: Product: PlutoSDR (ADALM-PLUTO)
            <- and nothing since: no reset, no disconnect
```

`watch-pluto.sh` recorded it going from `cfg=UNCONFIGURED` to `CONFIGURED as value 1` at 11:12:41.976,
and then **no further state change at all** — the log's last line is that moment. Two minutes later
it is still up, still configured, no disconnect in the kernel log.

That is the first time this radio has ever stayed: every previous plug died in one to four seconds,
once without even finishing configuration (`EPROTO` on SET_CONFIGURATION).

### What the four attempts add up to

| # | Time | Power | Outcome |
|---|---|---|---|
| 1 | 10:44:55 | bus | configured, then reset and dropped after ~4 s |
| 2 | 11:02:32 | bus | `can't set config #1, error -71`, never configured |
| 3 | 11:09:58 | bus, and the bus otherwise empty | configured, dropped after ~1 s |
| 4 | 11:12:41 | **external** | **configured and stable** |

So the cause was the radio's own supply. Note how the earlier reasoning arrived there: attempt 3
was the one that mattered, because removing every other device and still failing ruled out the
host's budget, which made "the radio cannot run on what the port gives it" the surviving
explanation. Attempts 1 and 2 would have supported either story; attempt 3 decided it. The cable
was never changed and did not need to be.

The 500 mA the device asks for is more than a bus-powered port behind two hubs ended up delivering,
and external power settled it. That is worth writing down plainly, because the intermediate theory
in this file - "a shared budget on a bus-powered hub" - was wrong in its mechanism even though the
answer was power.

### A bug in this project's own tooling, found by the same test

With the radio healthy and configured, `probe-pluto.sh` still said **FAIL**, because it judged health
by `/sys/bus/iio/devices/iio:device*`. **A Pluto on USB never has a kernel IIO device**: the IIO
protocol runs over libusb in user space, so that directory is empty even when everything works. The
check was measuring the wrong thing and would have reported a working radio as broken forever.

Corrected in both tools: the test is now **"can libiio produce a `usb:` context?"**
(`pluto_probe --scan`, which exits 0 only if one exists). The verdict distinguishes the three
states that used to be collapsed into one:

| State | What it means |
|---|---|
| libiio can open a `usb:` context | working — go and capture |
| device present, `bConfigurationValue` empty | never configured — power or firmware |
| device present and configured, node not writable | **permissions** — install the udev rule |
| device present, configured, node writable, still no context | the IIO function itself is not answering |

Right now the radio is in the third state. `/dev/bus/usb/001/031` is `crw-rw-r-- root root`, and
libusb needs write access, so `libiio` sees nothing. That is what `scripts/install-pluto-udev.sh` is
for, and it needs one `sudo` run.

### Next, once the udev rule is in

`./scripts/probe-pluto.sh --capture -v` — which prints, for the first time, the answers this whole
design has been waiting on: `sampling_frequency_available` (the rate floor), `hardwaregain` and its
range, and a real capture with crest factor and clipping counts.

---

## 2026-11-10 11:16 — it works, and everything below was measured

The udev rule went in (`sudo scripts/install-pluto-udev.sh`), the radio was power-cycled, and
**libiio opened it first time**:

```
$ ./pluto_probe --scan
libiio 0.19 (git v0.19) sees 2 context(s):
  local:                   Local devices
  usb:1.32.5               0456:b673 (Analog Devices Inc. PlutoSDR (ADALM-PLUTO)), serial=104473ae73930001fdff27009d682d6d06
```

`/dev/bus/usb/001/032` became `root:plugdev`, writable by `threaded`. That was the last blocker.
Note the URI shape: **`usb:<bus>.<address>.<interface>`, where the address changes on every replug**
(30, 31, 32 so far) and the IIO function is **interface 5**. So a fixed `usb:` URI is not a stable
configuration value; the backend has to select the context by the device's serial number.

### The measurements this project was waiting for

| Question | Answer |
|---|---|
| Rate floor | `sampling_frequency_available = [2083333 1 61440000]`. 2083333 itself is **rejected** (the real divider gives 2 083 333.33); **2083334 works and applies 2 083 333**. 1.0 and 2.048 MSPS rejected |
| 4.0 MSPS, the design default | applied **3 999 999 Hz** |
| Firmware default at power-up | 30 719 999 Hz, 18 MHz bandwidth, `slow_attack` |
| Gain range | `hardwaregain_available = [-1 1 73]` in manual mode — −1…73 dB, 1 dB steps |
| Sample format | **12-bit signed, shift 0** on `cf-ad9361-lpc` voltage0/voltage1 → the 8-bit conversion is a shift of 4 and must be calibrated |
| LO resolution | 868 400 000 requested → **868 399 998** applied (2 Hz low) |
| Frequency correction | `xo_correction` = 39 999 890 Hz, range `[39991891 1 40007889]` — a **real** trim of ±200 ppm at 1 Hz (0.025 ppm) resolution |

### Three corrections to earlier claims in this repository

1. **There IS a hardware ppm control.** An earlier version of `docs/ogn-rf-integration.md` said the
   AD9363 has "no ppm register" and that `FreqCorr` would have to be a software offset on the LO.
   Wrong: `xo_correction` is a device attribute and does exactly this properly. `FreqCorr` maps onto
   it as `xo = 40e6 + 40 × ppm` (1 ppm = 40 Hz at the 40 MHz XO).
2. **`gain_control_mode` is a channel attribute**, on `voltage0` (input) of `ad9361-phy` — not a
   device attribute. The device's 19 attributes do not include it. Writing it to the device fails
   silently and leaves the radio in `slow_attack` while the tool reports a gain it never applied.
3. **The crest factor figure imported from the RSPduo work does not transfer.** 4.2–5.2 here is a
   textbook Gaussian maximum-over-rms for 300k samples, not evidence of compression.

Two of those were bugs in this repository's own code, both found only because the radio finally
worked and the numbers could be compared with what was expected. The probe now enumerates device
*and* channel attributes in verbose mode for exactly this reason, and it had an inverted success
check that printed "could not select manual gain" on success.

### The radio receives real RF

| Frequency | rms %FS | peak %FS | what it is |
|---|---|---|---|
| 100.000 MHz | **12.8** | 67.2 | FM broadcast |
| 100.500 MHz | **13.6** | 65.0 | FM broadcast |
| 433.920 MHz | **8.9** | 50.9 | ISM |
| 868.400 MHz | **0.9** | 4.4 | the OGN channel |

**+23 dB** of FM at 100 MHz over the OGN noise floor. The receive chain is verified end to end. The
868 MHz band is quiet here, as it was for the RSPduo and the LimeSDR, so this says nothing yet about
hearing aircraft — and nothing needs to be fixed about that.

### What this unblocks

The rate, the gain range, the format and the frequency trim are now measured rather than inferred,
which is everything the `plutosdr.h` design was waiting on. The next piece of work is the backend
itself, and the first thing it does when it runs is compare its own output with the numbers above.

---

## 2026-11-10 (later) — let the radio do all the decimation

Asked whether the Pluto could decimate harder so that only ~2 MSPS ever crosses USB. The answer is
yes, and it is now the shipped configuration — but the measurement took three attempts to get right,
and the corrections are more useful than the number.

### What the chip does on its own

`ChipRate = 2083334`, `Decimate = 1`: the AD9363 runs its ADC at **25 MHz** and decimates by 12
internally (`R2 ÷3, R1 ÷2, RFIR ÷2`), so:

```
applied   868399998 Hz at 2083333 Hz
RX path rates: ADC 25000007  R2 8333335  R1 4166667  RF 2083333  RXSAMP 2083333
4194304 samples (2.013 s), chip rate 99.9% delivered, overhead +3 ms
throughput 2.080 Msps sustained (8.3 MB/s)
rms 0.6 %FS, crest 5.57, clipped 0  -> PASS
```

**No software resampling at all, and the lightest USB load of any ~2 MSPS configuration.** The host
receives 2.081 MSPS and ogn-rf's DSP consumes it directly. The only cost is that 2.0833 ≠ 2.000:
`SpectrogramFFTsize = 8·2083333/15625` is 1066 rather than 1024.

### Why "60 MSPS into the chip, 2 MSPS out" is not reachable

Not a tuning problem — a structural one. `sampling_frequency` *is* the post-decimation rate, so the
mechanism is right, but **the ADC clock is not independently settable**: the driver derives it from the
requested output rate at a fixed ÷8, and ÷12 only at the floor. Measured: 25 MHz ADC for 2.083 MSPS
out, 32 for 4, 48 for 6, 64 for 8, 491.52 for 61.44. There is no ÷30 chain, so 60 MSPS of converter
cannot feed a 2 MSPS output; and asking for 60 MSPS *output* needs 245 MB/s from a link that measures
~31.

It would buy nothing either. At maximum gain the noise is rms 12–18 counts of a 2048 full scale, while
12-bit quantisation noise is ~0.29 counts: the chain is analogue-noise-limited by ~50×, so extra
oversampling and on-chip decimation recover no SNR.

### Three measurement bugs in this repository's own probe

Every one of them made a *good* configuration look bad, and all three surfaced only because the
numbers were cross-checked against each other:

1. **A single huge `iio_buffer`** made the probe report throughput *above* the requested rate — 145 %
   of 4 MSPS. `iio_buffer_end()` marks the end of the allocation, not what a refill filled, so the
   walk read stale samples past the valid region. Now it reads 262144-sample blocks and refills,
   which is also how ogn-rf will read.
2. **Buffering latency was reported as sample loss.** A short capture reads below 100 % for reasons
   that are not loss. The probe now reports overhead in milliseconds and only declares loss when the
   capture is long enough for a fixed latency to be a small part of it.
3. **The tail block was charged as loss.** `want` was not a multiple of the block size, so the last
   refill transferred a full block while only its remainder was counted — one block-time of
   unaccounted transfer, which at 2.083 MSPS is 126 ms and at 8 MSPS only 33 ms. It therefore
   penalised exactly the *lightest* USB load most, and made 2.083 MSPS read 94 % (FAIL) while 23 MB/s
   read 99 %. Captures are now a whole number of blocks.

With all three fixed, the corrected grid (three repeats per row, ≥2 s of data):

```
2.083 MSPS /1 : 99.8%/+4ms   99.9%/+2ms   99.9%/+2ms    clean    8.3 MB/s
4 MSPS     /2 : 99.9%/+3ms   99.9%/+2ms   99.9%/+2ms    clean   15.0 MB/s
6 MSPS     /3 : 99.9%/+3ms   99.9%/+3ms   99.9%/+2ms    clean   23.0 MB/s
8 MSPS     /4 : 95.2%        95.6%        95.3%         DROPS SAMPLES
10 MSPS    /5 : 78.8%   -> real output collapses to 1.58 MSPS
16 MSPS    /8 : 49.5%   -> real output collapses to 0.99 MSPS
```

**This overturns the previous entry's conclusion.** 6 MSPS ÷ 3 was reported as "the ceiling, and best
on every criterion" on a metric that was penalising the low-rate rows. On the corrected metric the
three clean rows are indistinguishable at 99.9 %, so the choice is not about delivery at all — it is
about *where the last factor happens*: on the chip (2.083 MSPS, 8.3 MB/s, no software) or in software
(exactly 2.0 MSPS, 15–23 MB/s). 8 MSPS, previously called "clean" in one run at 98.3 %, is flaky and
drops 2–5 %.

The shipped config now takes the first option, since it is both the lightest load and the one that
asks least of the host. It costs a 4 % difference in rate, and if ogn-rf's demodulator turns out to
want exactly 2.000 MSPS the fallback is one line: `ChipRate = 4000000`, `Decimate = 2`,
`SampleRate = 2000000`.

---

## 2026-11-10 (later still) — the chip reaches exactly 2.0 MSPS after all

Reading `ogn-rf.cc` properly overturned two conclusions in this file, and both were mine.

### The FFT size is 8192, not 1024

`Inp_FFT::Preset()` — the OGN demodulator path — computes

```cpp
FFTsize = (8*8*SampleRate)/15625;      // 8*8, not 8
```

so at 2.000 MSPS the transform is **8192 = 2¹³**. Two earlier entries in this file compared 1024 with
1066; those are `GSM_FFT` sizes, the GSM calibration spectrogram, which really does use
`8*SampleRate/15625`. The numbers that decide the rate are these:

| SampleRate | OGN FFTsize | factorisation |
|---|---|---|
| 1 000 000 | 4096 | 2¹² |
| **2 000 000** | **8192** | **2¹³** |
| 2 048 000 | 8388 | 2²·3²·**233** |
| 2 083 333 | 8533 | 7·**23**·**53** |

Exactly 2.000 MSPS gives a power of two; 2.0833 gives 8533 = 7×23×53, which FFTW has to run through
generic codelets. That is a far better reason to want 2.000 than anything about USB rates.

### 2.0 MSPS is reachable — just not through `sampling_frequency`

The pasted `PlutoSDR` class calls `ad9361_set_bb_rate(phy, DEFAULT_SAMPLE_RATE)`, and that is a
different thing from writing the attribute: it designs and loads an **RX FIR** with decimation, in
addition to the HB stages. The 2.083 MSPS floor applies only to the attribute-only path. Measured
here, **libad9361-0 / libad9361-dev 0.2-1** is installed (`/usr/include/ad9361.h`, `libad9361.so.0.2`):

| `ad9361_set_bb_rate()` | Applied | ADC clock | Chain |
|---|---|---|---|
| 1 000 000 | **999 999 Hz** | 32 MHz | R2 ÷2 → 16 M, R1 ÷2 → 8 M, FIR ÷4 → 1 M |
| **2 000 000** | **1 999 999 Hz** | **64 MHz** | R2 ÷2 → 32 M, R1 ÷2 → 16 M, FIR ÷4 → 2 M |
| 2 083 333 | 2 083 332 Hz | 66.7 MHz | FIR ÷2 instead |

So the earlier claim in this file — "2.000 MSPS cannot come out of the chip at all, a software step is
unavoidable" — was **wrong**. It was true of the attribute and false of the chip. The converter runs
at 64 MHz, every decimation stage is on-chip, and the host does nothing.

End to end at exactly 2.0 MSPS: **99.9 % delivered, +2 ms overhead, 1.998 Msps sustained, 8.0 MB/s,
rms 0.7 %FS, crest 5.34, nothing clipped, PASS**, with `filter_fir_en = 1`.

### The 56 MHz bandwidth in that class costs about 5 dB

`DEFAULT_BANDWIDTH 56000000` is commented "as wide as possible to encourage a high sample rate and
then decimation". The premise is unnecessary — the ADC already runs at 64 MHz — and the cost is real.
Measured at 100 MHz FM, 2 MSPS, gain 73 dB:

| `rf_bandwidth` | rms %FS | peak %FS |
|---|---|---|
| 1 MHz (what `ad9361_set_bb_rate` picks alone) | 8.8 | 61.0 |
| 2 MHz | 11.1 | 71.9 |
| **4 MHz** | **11.5** | **73.8** |
| 8 MHz | 11.5 | 69.1 |
| 18 MHz (driver default) | 9.0 | 52.1 |
| 56 MHz | 6.5 | 47.3 |

4 MHz — about twice the output rate — is the peak, and 56 MHz is 5 dB below it.

### Three things in the pasted class that will not work as written

1. **`#define DEFAULT_URI "ip:pluto.local"`** — the network transport is not available on this board:
   `rndis_host` and `cdc_acm` are modules that are not loaded, so the Pluto never creates a `usb0` or
   a `ttyACM`, and there is nothing for libiio's network backend to talk to. It has to be `usb:`.
   (Which in turn needs the udev rule, and the URI's device address changes on every replug, so the
   context must be found by serial.)
2. **`setFreqCorrection()` returns 0** — a silent no-op. `xo_correction` exists as a device attribute
   (measured 39 999 890 Hz, range 39 991 891–40 007 889, i.e. ±200 ppm at 1 Hz resolution) and this
   is where a ppm correction belongs.
3. **`getTunerBandwidths()`** assigns to its `const int *Bandwidth` parameter —
   `Bandwidth = {new int[8]{...}}` — which cannot compile as intended and would leak if it did. The
   bandwidths should be written into the caller's array.

Also worth noting for the backend: `ad9361_set_bb_rate()` must not be followed by a
`sampling_frequency` write, which would undo the FIR configuration it just set up.
