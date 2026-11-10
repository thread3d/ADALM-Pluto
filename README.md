# ADALM-PLUTO on the XavierAGX — OGN receiver backend

Working repository for getting an **Analog Devices ADALM-PLUTO** (PlutoSDR) to act as the radio for
[`ogn-rf`](https://github.com/thread3d/ogn-rf), the Open Glider Network RF front end. It holds the
tooling, the measurements and the notes; the source changes themselves live in the **`adalm-pluto`**
branch of the ogn-rf repository.

Hardware: a PlutoSDR on `xavieragx.local` (Jetson AGX Xavier, aarch64, Ubuntu 20.04).
Target use: receive the European OGN channels at 868.200 / 868.400 MHz.

This is the fourth radio in this series, after the
[RSPduo](https://github.com/thread3d/RSPduo), [LimeSDR](https://github.com/thread3d/LimeSDR) and
[KrakenSDR](https://github.com/thread3d/KrakenSDR), and it reuses their shape: a device repo that
holds the scripts, measurements and documents, and one device branch in ogn-rf that holds the code.

## Status

Read this before anything else. **The device is not currently usable, and nothing below has yet been
verified against live hardware.**

| Item | State |
|---|---|
| Device identified | **seen once** — USB `0456:B673`, product `PlutoSDR (ADALM-PLUTO)`, serial `104473ae73930001fdff27009d682d6d06` |
| Current USB link | **failing** — enumerates, then disappears ~4 s later. See [`docs/status-log.md`](docs/status-log.md) |
| `libiio` runtime | **present** — 0.19-1 (Ubuntu 20.04), libusb backend compiled in |
| `libiio` headers | **present** — `libiio-dev` 0.19-1, so a backend can be built here |
| `iio-utils` (`iio_info`, `iio_attr`) | **missing** — not installed; `probe-pluto.sh` works without it |
| udev rule for non-root USB access | **written, not installed** — needs one `sudo` run of `scripts/install-pluto-udev.sh` |
| Probe (device-level, independent of ogn-rf) | **written, compiled and exercised** — fails correctly against no device; **never yet against a radio** |
| `adalm-pluto` branch of ogn-rf | **created and pushed** — `thread3d/ogn-rf@cbc2759`, design document only |
| The backend itself (`plutosdr.h`) | **not started** — design only, in [`docs/ogn-rf-integration.md`](docs/ogn-rf-integration.md) |
| Live OGN packet decoding | **not started** — cannot begin until the USB link is stable |

The honest summary: the repository, the tooling and the design are in place, and the hardware is not.
Everything that says "measured" will say so only once it was measured; nothing here is copied from a
press release and presented as observation.

## Start here

```bash
# 1. Is the device actually on the bus, and if not, why not?
~/projects/ADALM-Pluto/adalm-pluto/scripts/probe-pluto.sh

# 2. Once it stays connected, give your own user access to it (one-time, needs root):
sudo ~/projects/ADALM-Pluto/adalm-pluto/scripts/install-pluto-udev.sh

# 3. Talk to the radio without involving ogn-rf at all:
~/projects/ADALM-Pluto/adalm-pluto/scripts/probe-pluto.sh --capture
```

Step 1 is the one to run first, and it is the one that currently fails. It is deliberately read-only
and needs no root: it reads the USB tree, the kernel log and the IIO sysfs, and tells you which of
the failure modes in `docs/hardware.md` you are looking at.

## The USB problem, in one paragraph

The Pluto was plugged in on 2026-11-10 at 10:44:55 and identified correctly, then fell off the bus at
10:44:59 with `Power-on or device reset occurred` from the SCSI layer. It has not re-appeared. The
port it was on (`1-4.4.3`) is three hubs deep on a 480 Mbit/s bus, and the Pluto is bus-powered, so
the leading suspect is a brown-out rather than a driver problem; the fix being tested first is a
direct port or a powered hub. `docs/status-log.md` has the exact kernel lines and what each
candidate cause would look like.

## Why this radio is different

Four properties of the Pluto shape everything here, and none of them applied to the earlier radios:

1. **It is a libiio device, not a driver.** There is no `rtlsdr_open()` and no vendor SDK to install:
   the radio exposes itself as an IIO device (`ad9361-phy` plus a DMA device), and `libiio` is the
   whole interface. That is good news — 0.19 is already on this board — but it means the backend
   speaks attributes, not functions, and the useful truth comes from `sampling_frequency_available`
   and `hardwaregain` on the device rather than from a datasheet.
2. **It is a transceiver, not a receiver.** 2 RX and 2 TX, full duplex, with two independent
   synthesisers. ogn-rf only ever wants one RX channel, so most of the chip is deliberately idle.
3. **12-bit I/Q, and no 2.048 MSPS.** ogn-rf grew up on RTL-SDR dongles that hand over 8-bit
   unsigned I/Q at 2.048 MSPS. The AD9363 gives 12-bit samples and cannot produce rates below about
   2.08 MSPS, so the backend has to both convert the number format and settle the rate question.
   `sdr.h` already has the `setOversample()` hook the RSPduo work added, and that is where this
   belongs.
4. **The default transport is a network gadget.** A stock Pluto comes up as a USB Ethernet device on
   `192.168.2.1` with the host at `192.168.2.10`, and it *also* offers a USB mass-storage volume and
   a serial console. Which of those you get depends on the firmware's USB mode, so "the device is
   plugged in" and "the device is usable over USB" are two different statements. The first link we
   observed came up as **mass storage**, which is a firmware/volume mode, not the IIO mode.

## Layout

| Path | What it holds |
|---|---|
| `docs/hardware.md` | The board, the radio, the USB modes, and what `libiio` on this host can and cannot do |
| `docs/status-log.md` | Dated observations, including the USB failure of 2026-11-10 |
| `docs/ogn-rf-integration.md` | The design for the `adalm-pluto` branch: the contract, the mapping, the open questions |
| `scripts/probe-pluto.sh` | Read-only diagnosis of the link; then, with `--capture`, a live receive check |
| `scripts/install-pluto-udev.sh` | One-time root install of the udev rule that lets `threaded` open the radio |
| `config/90-libiio-pluto.rules` | The udev rule itself |
| `config/ogn-rf-pluto.conf` | An ogn-rf configuration for this board, with the reasons for each value |
| `src/pluto_probe.c` | The libiio receive checker behind `--capture`; the analogue of `rspduo_probe.c` |

## The ogn-rf side

The source changes live in branch **`adalm-pluto`** of [`thread3d/ogn-rf`](https://github.com/thread3d/ogn-rf),
alongside the existing `limesdr`, `rspduo` and `krakensdr` branches. Nothing has been committed to it
yet beyond the design document, because writing a backend that cannot be run against a radio would
be speculation with a file name. `docs/ogn-rf-integration.md` records what it will contain and why.

On this board:

```bash
cd ~/projects/ADALM-Pluto/ogn-rf
git checkout adalm-pluto
```
