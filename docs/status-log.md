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
