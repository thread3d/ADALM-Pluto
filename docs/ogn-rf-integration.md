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
| `int setFreqCorrection(int PPM)` / `getFreqCorrection()` | no ppm register: apply as an offset on the LO, which is what a ppm figure is |
| `int setTunerGain(int)` / `getTunerGain()` / `getTunerGains()` | `voltage0` → `hardwaregain`, with `gain_control_mode` = `manual` |
| `int setTunerGainMode(int Manual)` | device attribute `gain_control_mode` (`manual` / `slow_attack` / `fast_attack`) |
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

### Rate: the AD9363 will not go where ogn-rf wants to go

This is the constraint that shapes the backend. The chip's decimating filters bottom out at about
2.08 MSPS, while ogn-rf asks for 1.0 MSPS by default and 2.048 MSPS by inheritance from the RTL-SDR.
Neither is reachable.

The `setOversample()` hook already exists on the RSPduo branch for exactly this class of problem, so
the design is to use it:

| ogn-rf asks for | chip runs at | software decimation | USB traffic | notes |
|---|---|---|---|---|
| 2 000 000 | 4 000 000 | ÷2 | 16 MB/s | **the intended default** — clean integer ratio, comfortable on 480 Mbit/s |
| 2 000 000 | 8 000 000 | ÷4 | 32 MB/s | more headroom against aliasing, more than half of USB2 |
| 1 000 000 | 8 000 000 | ÷8 | 32 MB/s | only if 1 Msps is actually wanted |
| 2 083 333 | 2 083 333 | ÷1 | 8 MB/s | ask ogn-rf to match the chip instead; least USB pressure, non-integer relationship to the OGN symbol clock |

The first row is the recommendation: it lands on the **same 2.0 MSPS the RSPduo work settled on**, so
the frequency plan and the gain measurements from that work stay comparable, and the decimation is a
2-tap box filter — `boxfilter.h` is already in the tree.

Which of these is right is not settled, and cannot be settled without a radio: it depends on the
chip's actual rate floor on this firmware and on what the decimator does to the OGN pulse shape.

## Configuration

Two new keys, both following the existing `RF.*` conventions:

| Key | Meaning |
|---|---|
| `RF.DeviceType = "pluto"` | selects the backend; needs a binary built with `USE_PLUTOSDR=1`, and says so if not |
| `RF.DeviceUri = "usb:1.4.4.3"` | the libiio context. `usb:` bus/port, `ip:192.168.2.1` over the network gadget, or `local:` if ogn-rf ever runs on the Pluto itself |

`config/ogn-rf-pluto.conf` in this repository is the reference configuration; it marks every value
that is not yet measured as such.

## Open questions to settle on hardware

Ordered by how much they change the design:

1. **The real rate floor.** `sampling_frequency_available` on `voltage0` — if it permits 2.0 MSPS
   directly, the whole decimation design collapses into a pass-through and the work gets simpler.
2. **The gain law.** Sweep `hardwaregain`, measure RMS and crest factor, write the law down the way
   the RSPduo repository did (`total = 115.8 − gRdB`). Until then no gain figure is meaningful.
3. **Which USB face the firmware offers,** and whether USB or the network gadget is the better
   transport for a 1-second burst every 30 seconds. USB avoids depending on a DHCP lease.
4. **`ResetBuffer()` semantics.** The RSPDuo backend needed a real ring-buffer bridge because the API
   is callback-driven. libiio is blocking-read, which is closer to the RTL-SDR model, but how much
   stale data a refill can hand over after a retune is exactly the kind of thing that produces a
   half-time-slot warning if it is wrong.
5. **Whether the 2.083 MSPS chip minimum and ogn-rf's 15 625 Hz-bin assumptions agree** — the
   spectrogram size is computed as `(8*SampleRate)/15625`, which is not a power of two at any of
   these rates, and has not been exercised.

## Why nothing is committed yet

Each of the five questions above changes code. Writing the backend first would mean guessing at the
answers and then discovering which guesses were wrong from a receiver that half-works — the failure
mode the other device branches spent their time chasing. The branch is created and holds this design;
`plutosdr.h` starts the day the radio stays on the bus.

To read the branch itself:

```bash
cd ~/projects/ADALM-Pluto/ogn-rf
git checkout adalm-pluto
git log --oneline
```
