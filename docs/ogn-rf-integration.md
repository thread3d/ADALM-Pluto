# The `adalm-pluto` branch: what it will contain and why

The code changes for this radio live in branch **`adalm-pluto`** of
[`thread3d/ogn-rf`](https://github.com/thread3d/ogn-rf), the same way `limesdr`, `rspduo` and
`krakensdr` hold theirs. This document is the design, written before the code, so that the shape is
agreed while it is still cheap to change.

It is deliberately **design only at this point**. A backend cannot be verified without a radio, and
this radio currently drops off the bus four seconds after it enumerates (see `status-log.md`). The
one thing worse than a backend that does not work is a backend that was never run but reads as if it
had been.

## What ogn-rf looks like, and where a radio plugs in

Upstream `master` knows exactly one radio. `ogn-rf.cc` declares `RTLSDR SDR;` and calls
`SDR.Open(Index, Freq, SampleRate)`, `SDR.Read(*Buffer, Samples)`, `SDR.setCenterFreq()`,
`SDR.setTunerGain()` and so on, and `rtlsdr.h` implements all of it by forwarding to librtlsdr.

Each device branch inserts one file between those two things: `sdr.h`, a `SDR_Device` class that
keeps the identical method names and forwards to whichever backend is selected. It is a hand-written
switch, not virtual inheritance, and the reason is stated in the file itself — the classes are cheap,
only one is ever open, and every call site keeps saying `SDR.something(...)` with no allocation to
reason about. A backend that is not compiled in is `typedef`'d to `RTLSDR` as an inert placeholder,
so a plain RTL-SDR build is unaffected.

The dispatch layer has five places that know the list of radios:

| Place | Shape today | What the Pluto adds |
|---|---|---|
| `enum` | `{ RTL_SDR=0, LIME_SDR=1, RSP_DUO=2 }` | `PLUTO_SDR=3` |
| members | `RTLSDR RTL; LimeSDR Lms; RSPDuo Rsp;` | `PlutoSDR Pluto;` |
| guard | `HaveLimeSDR()`, `HaveRSPDuo()` | `HavePlutoSDR()`, true iff `USE_PLUTOSDR` |
| `getTypeName()` | `"RTL-SDR"`, `"LimeSDR"`, `"RSPduo"` | `"PlutoSDR"` — this is what the status page prints |
| `getTypeByString()` | parses `RF.DeviceType` | `"pluto"`, `"plutosdr"`, `"adalm-pluto"` |

and then one `if` per method, in the same style as the existing ones:

```cpp
int setCenterFreq(uint32_t Frequency)
{ if(Type==LIME_SDR)  return Lms.setCenterFreq(Frequency);
  if(Type==RSP_DUO)   return Rsp.setCenterFreq(Frequency);
  if(Type==PLUTO_SDR) return Pluto.setCenterFreq(Frequency);
  return RTL.setCenterFreq(Frequency); }
```

## Files

| File | Status | Contents |
|---|---|---|
| `sdr.h` | new to `master`, already on the device branches | the dispatch layer above, plus the Pluto arm |
| `plutosdr.h` | **new** | the libiio backend: a class with the same method names as `RTLSDR` |
| `Makefile` | edit | `USE_PLUTOSDR` autodetected from `libiio.h`, in the shape the `USE_RSPDUO` block already established |
| `ogn-rf.cc`, `gsm_scan.cc` | edit | `#include "sdr.h"` and the `SDR` member, exactly as the other branches did |
| `docs/adalm-pluto.md` | **new** | the branch's own document, in the style of `docs/rspduo.md` |

The Makefile block follows `USE_RSPDUO` literally, including its reason for keeping the defines in a
separate variable:

```make
# ADALM-PLUTO support through libiio (see plutosdr.h and sdr.h). Auto-detected from the libiio
# headers, so any other build is unaffected; force it either way with USE_PLUTOSDR=1 or 0.
ifndef USE_PLUTOSDR
ifneq ("$(wildcard /usr/include/iio.h)","")
USE_PLUTOSDR = 1
endif
endif

ifeq ($(USE_PLUTOSDR),1)
# Separate from FLAGS for the same reason as SDR_FLAGS above: a "make FLAGS=..." override on the
# command line would otherwise drop the define and produce a binary that cannot select a Pluto.
PLUTO_FLAGS = -DUSE_PLUTOSDR
PLUTO_LIBS  = -liio
endif
```

## Building it on this board

Verified on `xavieragx.local`, 2026-11-10, because it is not what one would assume:

| Dependency | Where it is |
|---|---|
| `libiio` 0.19 | **system** — `/usr/include/iio.h`, `/usr/lib/aarch64-linux-gnu/libiio.so`, so `-liio` just works |
| `libconfig` / `librtlsdr` | **not system packages** — built from source by the KrakenSDR work into `~/projects/KrakenSDR/krakensdr/deps/prefix` |
| `libconfig.so.15`, `librtlsdr.so.0.8git` | that prefix's `lib/`, with headers in its `include/` |
| `libfftw3-dev`, `libjpeg-dev` | system, installed |
| `librtlsdr-dev`, `libconfig-dev` | **not installed** — `apt` cannot supply them without root, and the prefix is the working substitute |

The existing RSPduo `ogn-rf` binary proves the arrangement works: `ldd` on it resolves
`libconfig.so.15` and `librtlsdr.so.0` out of that prefix by absolute path.

Two consequences for the branch:

1. A Pluto build still needs **librtlsdr's headers**, even though it will never open an RTL-SDR,
   because `sdr.h` includes `rtlsdr.h` unconditionally and the Makefile links `-lrtlsdr` in every
   device configuration. That is why the prefix cannot simply be dropped from the build line.
2. The build therefore looks like this, and this line has been checked for the pieces that exist:

```bash
PREFIX=$HOME/projects/KrakenSDR/krakensdr/deps/prefix
make USE_PLUTOSDR=1 \
     FLAGS="-Wall -O3 -ffast-math -I$PREFIX/include" \
     LIBS="-lpthread -lm -ljpeg -lconfig -lrt -L$PREFIX/lib -Wl,-rpath,$PREFIX/lib"
```

`config/ogn-rf-pluto.conf` in this repository was parsed with that prefix's `libconfig` and its keys
resolve as intended (`RF.DeviceType = "pluto"`, `RF.SampleRate = 2000000`, `RF.OGN.Gain = 40`,
`RF.DeviceUri = "usb:1.4.4.3"`). The same checker parses the RSPduo configuration, which is the
control that says the checker itself is right.

## Contract: what `plutosdr.h` has to provide

Every method below is already called by `ogn-rf.cc` or by the status page through the dispatch layer,
so the backend has to answer all of them or the branch does not link.

| Method | IIO equivalent |
|---|---|
| `int Open(idx, Freq, SampleRate)` | create the context, find `ad9361-phy` and `cf-ad9361-lpc`, tune, set rate and bandwidth, create the buffer |
| `void Close()` | destroy buffer, destroy context |
| `bool isOpen()` | context != NULL and the buffer exists |
| `int Read(uint8_t *Buf, int Samples)` | `iio_buffer_refill()` then convert — see the format note |
| `int ResetBuffer()` | discard what is already queued: refill and drop, until the buffer is empty |
| `int setCenterFreq(uint32_t)` / `getCenterFreq()` | write/read `altvoltage0` → `frequency` on `ad9361-phy` |
| `int setSampleRate(uint32_t)` / `getSampleRate()` | write/read `voltage0` → `sampling_frequency` |
| `int setFreqCorrection(int PPM)` / `getFreqCorrection()` | device attribute `xo_correction` — a **real** ppm trim, measured ±200 ppm at 1 Hz resolution on a 40 MHz XO, so `xo = 40e6 + 40 x ppm` |
| `int setTunerGain(int)` / `getTunerGain()` / `getTunerGains()` | `voltage0` → `hardwaregain`, with `gain_control_mode` = `manual` |
| `int setTunerGainMode(int Manual)` | `gain_control_mode` — **a channel attribute of `voltage0` (input)**, not a device attribute; values `manual fast_attack slow_attack hybrid`. Writing it to the device fails silently |
| `int setOffsetTuning(int)` | accepted and ignored, like the RSPduo: there is no offset-tuning trick here |
| `int setBiasTee(int)` | **not available.** The Pluto has no bias tee; the call is accepted and ignored, and says so once |
| `void setOversample(int Ratio)` | sets the chip rate to `Ratio ×` the requested rate — the core of the rate design below |
| `double getTime()` | `clock_gettime()`, unchanged from `rtlsdr.h` |
| `int getTunerType()` / `getDeviceName()` / `getUsbStrings()` | from the IIO context and the device's own strings; the status page prints these |
| `int getDeviceIndexBySerial(const char *)` | index a list of `usb:` contexts by the ADI serial, which is `104473ae73930001fdff27009d682d6d06` here |

Two methods deserve their own notes.

### Format: 12 bits in, 8 bits out

`ogn-rf`'s DSP was written for the RTL-SDR's stream: **unsigned 8-bit I/Q, interleaved, 128 = zero**.
The AD9363 produces 12-bit signed samples, and libiio hands them over as 16-bit little-endian with
the 12 significant bits aligned by the driver.

So `Read()` is not a copy, it is a conversion, and the scale is a decision with consequences:

- shift right by 4 to map 12 bits onto 8 (`>>4`), then add 128 to make it unsigned;
- or multiply by a calibrated factor, which is what the RSPduo work ended up doing — its conversion
  scale was measured, not assumed, and settled at a shift of 8 with peak −3.0 dBFS and no clipping.

The right value for this radio is a **measurement**, to be made with `src/pluto_probe.c` and the
existing `tools/spectrum.py`: inject a known-level signal, sweep gain, and pick the shift that uses
the full 8-bit range without clipping. Until then the backend takes a constant, and the constant is
documented at its definition as provisional.

### Rate: the chip decimates on-chip already, and USB is the real ceiling

The intuition worth correcting here: it is natural to think the right move is to run the Pluto at its
maximum sample rate and let its internal decimator hand 2 MSPS to ogn-rf. Measured, that is backwards
on both counts, and `docs/hardware.md` has the tables.

**`sampling_frequency` is the post-decimation output rate, and the chip filters on every setting.**
`rx_path_rates` shows the chain it picks: at 4 MSPS the ADC runs at 32 MHz with HB3 ÷2, HB2 ÷2 and the
RX FIR ÷2 (÷8 overall); at 61.44 MSPS the ADC runs at 491.52 MHz with the *same* ÷8. Only the minimum
data rate gets the extra ÷12. So a higher rate raises the ADC clock and the USB traffic and changes
nothing else.

**USB saturates near 8 MSPS / 31 MB/s.** Measured sustained: 2.03 Msps for a 2.08 MSPS request,
3.85 for 4, 7.66 for 8 — and requests for 15.36, 30.72 and 61.44 MSPS all delivered about 8 Msps and
31 MB/s. The chip accepts the rate; the link drops the rest. USB 2.0's theoretical 60 MB/s, halved by
protocol overhead and two hubs, is the ceiling.

So `setOversample()` is not about buying headroom from the chip's decimator — it is about landing on
the rate ogn-rf's DSP wants while staying well inside what USB can carry:

| Chip data rate | On-chip | Software | Into ogn-rf | USB | Verdict |
|---|---|---|---|---|---|
| 2 083 333 | **÷12** | none, but the rate is 2.0833 | 2 083 333 | 8 MB/s | `SpectrogramFFTsize` becomes 1066 and every rate-dependent constant shifts 4 % |
| **4 000 000** | ÷8 | **÷2 box** | **2 000 000** | **15 MB/s** | **the choice** — exact rate, 4x USB headroom |
| 8 000 000 | ÷8 | ÷4 box | 2 000 000 | 31 MB/s | at the USB ceiling for no gain |
| 61 440 000 | ÷8 | ÷32 box | 2 000 000 | impossible | the link delivers 8 MSPS |

The tie-breaker is arithmetic that is not arbitrary: **8 x 2 000 000 / 15 625 = 1024 exactly**, so
ogn-rf's spectrogram is the power-of-two FFT it was written for. At 2 083 333 the same expression gives
1066, and at the RTL-SDR's 2 048 000 it gives 1048 — so 2.0 MSPS is the rate ogn-rf actually wants,
and hitting it exactly is worth one box filter.

Validated with the ÷2 stage implemented in the probe (`-r 4000000 -D 2`): 1 000 000 samples out at
exactly 2 000 000 Hz; rms 0.7 %FS against 0.8 %FS undecimated (the ~1/√2 a box filter over
independent noise should give), crest 5.02, nothing clipped. The filter is the same shape as ogn-rf's
own `boxfilter.h`.

## Configuration

Two new keys, both following the existing `RF.*` conventions:

| Key | Meaning |
|---|---|
| `RF.DeviceType = "pluto"` | selects the backend; needs a binary built with `USE_PLUTOSDR=1`, and says so if not |
| `RF.DeviceUri = "usb:1.4.4.3"` | the libiio context. `usb:` bus/port, `ip:192.168.2.1` over the network gadget, or `local:` if ogn-rf ever runs on the Pluto itself |

`config/ogn-rf-pluto.conf` in this repository is the reference configuration; it marks every value
that is not yet measured as such.

## What hardware has now answered

Five questions were open when this document was written. Four are answered, and the answers moved the
design rather than confirming it casually.

| Question | Answer | Consequence |
|---|---|---|
| **The rate floor** | `sampling_frequency_available = [2083333 1 61440000]`; 2083333 itself is rejected, **2083334 works and applies 2 083 333**; 1.0 and 2.048 MSPS rejected; 4.0 MSPS applies 3 999 999 | **decimation is required, not preferred** — `setOversample(2)` at a 4 MSPS chip rate giving 2.0 MSPS is right |
| **The gain law** | range `[-1 1 73]`, 1 dB steps; the law is **not** 1 dB per dB (staged LNA/mixer/TIA/digital); nothing clips at 73 dB, where the floor is 0.9 %FS | use the measured table in `docs/hardware.md`; `Gain = 73` in the shipped config |
| **Sample format** | 12-bit signed, shift 0 | the 8-bit conversion is a shift of 4, still to be calibrated against a known level |
| **Which USB face** | interface 5 carries IIO; a `usb:` context opens reliably. The network gadget is **not** up: `rndis_host` and `cdc_acm` are modules that are not loaded, so no `usb0`, no `ttyACM` | USB is the transport; `ip:192.168.2.1` would need those modules first |
| **Attribute locations** | `gain_control_mode` and `hardwaregain` are **channel** attributes of `voltage0` (input); `xo_correction` and `ensm_mode` are device attributes | this one cost an afternoon of a backend setting a gain the radio never applied |

Hardware also taught something no document would have: **the libiio USB URI is not stable.** It is
`usb:<bus>.<address>.<interface>`, and the address changed on every replug (30, 31, 32) during the
bring-up. The backend must select the context **by serial number**, not a pinned URI — which is why
`config/ogn-rf-pluto.conf` now carries `DeviceSerial` and comments out `DeviceUri`.

## What is still open

These need the backend to exist before they can be answered:

1. **`ResetBuffer()` semantics.** libiio is a blocking read, closer to the RTL-SDR model than the
   RSPduo's callback API, but how much stale data a refill can hand over after a retune is exactly
   what produces a "Half time slot" warning when it is wrong.
2. **The conversion shift.** The format says 12 bits, shift 0; the right 8-bit scale is still a
   calibration against a known level, the way the RSPduo work settled on a shift of 8.
3. **ogn-rf's rate assumptions at a decimated 2.0 MSPS.** The spectrogram size is
   `(8*SampleRate)/15625`, which is not a power of two at these rates and has never been exercised.
   This is the item most likely to need a change in ogn-rf itself rather than in the backend.
4. **Sustained USB throughput.** A 0.5 s capture at 4 MSPS is 16 MB and works. Whether a
   one-second-every-thirty-seconds duty cycle is comfortable over 480 Mbit/s behind two hubs is a
   different question, and it is what `SensTime` will exercise.

## Why the branch still holds only this document

Not for want of hardware any more — the radio works and its numbers are measured. It holds it because
the next commit should be `plutosdr.h`, written against those measurements in one pass, rather than
another draft produced while the answers were still moving. This document has already been rewritten
three times for that reason; a fourth draft of prose is worth less than one first draft of code.

To read the branch itself:

```bash
cd ~/projects/ADALM-Pluto/ogn-rf
git checkout adalm-pluto
git log --oneline
```
