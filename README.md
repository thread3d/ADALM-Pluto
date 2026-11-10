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

Read this before anything else. **The radio works.** It opens through libiio over USB, tunes, and
captures 12-bit I/Q — verified by reading FM broadcast +23 dB above the noise floor it sees on the
868.4 MHz OGN channel. The numbers the ogn-rf backend design was waiting on are now measured.

| Item | State |
|---|---|
| Device identified | **confirmed, four times** — USB `0456:B673`, product `PlutoSDR (ADALM-PLUTO)`, serial `104473ae73930001fdff27009d682d6d06` |
| Current USB link | **stable** — on **external power**. It had failed on all three bus-powered attempts, in three different ways. See [`docs/status-log.md`](docs/status-log.md) |
| Device configured | **yes** — `bConfigurationValue = 1` |
| **libiio can open it** | **yes** — `usb:1.32.5`, `0456:b673`, serial `104473ae…`. Note the address changes on every replug: select by serial |
| **Receive verified** | **yes** — 100 MHz FM reads 12.8 %FS against 0.9 %FS at 868.4 MHz (+23 dB), no clipping at any gain |
| Rate floor (the key constraint) | **measured 2 083 333 Hz** — 1.0, 2.048 and even 2 083 333 are rejected; 2 083 334 is the number that works; 4 MSPS applies 3 999 999 |
| Gain | **measured −1…73 dB**, 1 dB steps, and not linear in dB; 73 dB clips nothing here |
| Frequency trim | **`xo_correction` exists** — ±200 ppm at 1 Hz resolution on a 40 MHz XO |
| `libiio` runtime | **present** — 0.19-1 (Ubuntu 20.04), libusb backend compiled in |
| `libiio` headers | **present** — `libiio-dev` 0.19-1, so a backend can be built here |
| udev rule for non-root USB access | **installed** — `scripts/install-pluto-udev.sh`; the node becomes `root:plugdev` and libusb can open it |
| `iio-utils` (`iio_info`, `iio_attr`) | **missing** — not installed; the tools here do not need it |
| Probe (device-level, independent of ogn-rf) | **exercised against a live radio** — which found and fixed a bug in it: it judged health by `/sys/bus/iio/devices`, always empty for a USB Pluto |
| `adalm-pluto` branch of ogn-rf | **created and pushed** — `thread3d/ogn-rf@cbc2759`, design document only |
| The backend itself (`plutosdr.h`) | **not started** — design only, in [`docs/ogn-rf-integration.md`](docs/ogn-rf-integration.md) |
| The 8-bit conversion shift | **not calibrated** — a shift of 4 is the arithmetic default, still to be measured |
| Live OGN packet decoding | **not started** |

The honest summary: the hardware works, the tooling is verified against it, and the remaining work is
the ogn-rf backend itself. Everything that says "measured" was measured; where something is still an
assumption, it says so.

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

## The USB problem, and what fixed it

The radio is now **stable**: it has been up and configured since 11:12:41 after being given
**external power**. Before that it failed on three consecutive plugs, differently each time — and
the third failure is the one that solved it.

At 10:44:55 it identified itself, configured, presented its firmware volume, then reported
`Power-on or device reset occurred` and dropped four seconds later. At 11:02:32 it enumerated and
could not configure at all (`can't set config #1, error -71`, `EPROTO`). At 11:09:58, **with the
RSPduo, the LimeSDR and all five RTL-SDRs unplugged**, it configured and dropped again inside a
second.

That third attempt was the decisive one: with the radio alone on the bus it still fell off, which
ruled out the host's power budget and left the radio's own supply as the surviving explanation. On
external power it has not dropped once. The cable was never changed and did not need to be.

Two intermediate theories are recorded in `docs/status-log.md` rather than deleted, because both
looked right at the time: that the hub was bus-powered (it declares `bmAttributes 0xE0`,
self-powered, at every level), and that the port shared a current budget with the other SDRs (an
empty bus did not help). The mechanism was not shared current — it was that this port, behind two
hubs, could not feed the 500 mA the radio asks for. `scripts/watch-pluto.sh` exists because the
failing device lived one to four seconds, which is far too short to inspect by hand; it sampled ten
times a second and is what showed the transition from `UNCONFIGURED` to `CONFIGURED as value 1`.

The last blocker was neither the radio nor the cable but permissions: the USB node is `root:root`
`0664`, so libusb could not open it and libiio saw no context. One `sudo` run of
`scripts/install-pluto-udev.sh` fixed that — the node becomes `root:plugdev`, and since `threaded` is
already in `plugdev` it worked immediately.

That same episode exposed a bug in this repository's own probe, now fixed: it judged health by
`/sys/bus/iio/devices`, which for a USB Pluto is **always empty**, because IIO-over-USB is a
user-space protocol and no kernel driver is involved. It would have called a working radio broken
forever. The test is now whether libiio can produce a `usb:` context.

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
| `scripts/watch-pluto.sh` | Samples the USB/IIO/serial/block state five times a second — for a device that lives one second |
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

## Working on this from two machines

The repository is published at [`thread3d/ADALM-Pluto`](https://github.com/thread3d/ADALM-Pluto) and
also lives on the board at `~/projects/ADALM-Pluto/adalm-pluto`. Pushes are made from the machine
that has `gh` authenticated for `thread3d`; the board has no `gh` and no deploy key, so it can
**pull** (the repository is public) but cannot push.

```bash
# on the board, to pick up a change pushed elsewhere
cd ~/projects/ADALM-Pluto/adalm-pluto && git pull --ff-only
```

If that ever needs to change, a deploy key on the board is the way — but it should be a decision
someone makes deliberately, not something a script leaves behind.
